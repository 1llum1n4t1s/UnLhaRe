//! private scalar32 rANS。Cコードの移植ではない。
//! 数学的方式: Fabian Giesen, rans_byte.h (2014, public domain):
//! https://github.com/rygorous/ryg_rans/blob/master/rans_byte.h
const LOWER: u32 = 1 << 23;
const UPPER: u32 = 1 << 31;
const Q: u32 = 1 << 18;
const C_MASK: u64 = (1 << 18) - 1;
const F_MASK: u64 = (1 << 19) - 1;
const USED_MASK: u64 = (1 << 38) - 1;
pub(crate) const MAX_EVENTS: usize = 2 * 1024 * 1024;
pub(crate) const MAX_RETAINED_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const MAX_LIVE_BYTES: usize = 24 * 1024 * 1024;

#[derive(Clone, Copy)]
struct Event(u64);
const _: () = assert!(std::mem::size_of::<Event>() == 8);
fn scale(total: u32) -> Result<u32, &'static str> {
    match total {
        256 => Ok(8),
        Q => Ok(18),
        _ => Err("invalid ANS total"),
    }
}
fn valid(c: u32, f: u32, total: u32) -> Result<u32, &'static str> {
    let bits = scale(total)?;
    if f == 0 || c.checked_add(f).is_none_or(|end| end > total) {
        return Err("invalid ANS interval");
    }
    Ok(bits)
}
impl Event {
    fn pack(c: u32, f: u32, total: u32) -> Result<Self, &'static str> {
        let bits = valid(c, f, total)?;
        Ok(Self(
            u64::from(c) | (u64::from(f) << 18) | (u64::from(bits == 18) << 37),
        ))
    }
    fn unpack(self) -> Result<(u32, u32, u32), &'static str> {
        if self.0 & !USED_MASK != 0 {
            return Err("invalid ANS packed event");
        }
        let c = (self.0 & C_MASK) as u32;
        let f = ((self.0 >> 18) & F_MASK) as u32;
        let total = if self.0 & (1 << 37) == 0 { 256 } else { Q };
        valid(c, f, total)?;
        Ok((c, f, total))
    }
}
fn growth(len: usize, cap: usize) -> Result<Option<usize>, &'static str> {
    if len > cap || cap > MAX_EVENTS {
        return Err("ANS journal capacity contract");
    }
    if len == MAX_EVENTS {
        return Err("ANS journal limit");
    }
    if len < cap {
        return Ok(None);
    }
    // cap<=MAX_EVENTSを確認済みなので、以下の容量演算はoverflowしない。
    let old = cap * 8;
    if old > MAX_LIVE_BYTES - MAX_RETAINED_BYTES {
        return Err("ANS preallocation live bound");
    }
    let target = (cap * 2).max(1024).min(MAX_EVENTS);
    if target * 8 > MAX_RETAINED_BYTES || target * 8 + old > MAX_LIVE_BYTES {
        return Err("ANS preallocation live bound");
    }
    Ok(Some(target))
}
pub(crate) struct Encoder {
    events: Vec<Event>,
    limit: usize,
    old_capacity_peak: usize,
}
impl Encoder {
    pub(crate) fn with_limit(limit: usize) -> Result<Self, &'static str> {
        if limit > 1 << 20 {
            return Err("ANS output bound");
        }
        Ok(Self {
            events: Vec::new(),
            limit,
            old_capacity_peak: 0,
        })
    }
    pub(crate) fn interval(&mut self, c: u32, f: u32, total: u32) -> Result<(), &'static str> {
        let event = Event::pack(c, f, total)?;
        if f == total {
            return Ok(());
        }
        if let Some(target) = growth(self.events.len(), self.events.capacity())? {
            let old = self.events.capacity();
            let additional = target
                .checked_sub(self.events.len())
                .ok_or("ANS capacity overflow")?;
            self.events
                .try_reserve_exact(additional)
                .map_err(|_| "ANS allocation failed")?;
            self.old_capacity_peak = self.old_capacity_peak.max(old);
            if self.events.capacity() != target {
                return Err("ANS journal capacity contract");
            }
        }
        if self.capacity_bytes() > MAX_RETAINED_BYTES
            || self
                .capacity_bytes()
                .checked_add(self.transient_bytes())
                .is_none_or(|n| n > MAX_LIVE_BYTES)
        {
            return Err("ANS actual live bound");
        }
        self.events.push(event);
        Ok(())
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        self.events.capacity().saturating_mul(8)
    }
    pub(crate) fn transient_bytes(&self) -> usize {
        self.old_capacity_peak.saturating_mul(8)
    }
    pub(crate) fn event_count(&self) -> usize {
        self.events.len()
    }
    pub(crate) fn finish(self) -> Result<Vec<u8>, &'static str> {
        let body_limit = self.limit.checked_sub(5).ok_or("range output limit")?;
        let mut output = Vec::new();
        output
            .try_reserve_exact(self.limit)
            .map_err(|_| "ANS allocation failed")?;
        if output.capacity() > self.limit {
            return Err("ANS output capacity");
        }
        let mut state = LOWER;
        for event in self.events.iter().rev() {
            let (c, f, total) = event.unpack()?;
            let bits = scale(total)?;
            let maximum = (LOWER >> bits)
                .checked_mul(256)
                .and_then(|n| n.checked_mul(f))
                .ok_or("ANS state overflow")?;
            // Q18/freq1では3byteを要し得る。固定2byte制限を設けない。
            while state >= maximum {
                if output.len() >= body_limit {
                    return Err("range output limit");
                }
                output.push(state as u8);
                state >>= 8;
            }
            let next = (u64::from(state / f) << bits)
                .checked_add(u64::from(state % f))
                .and_then(|n| n.checked_add(u64::from(c)))
                .ok_or("ANS state overflow")?;
            if !(u64::from(LOWER)..u64::from(UPPER)).contains(&next) {
                return Err("ANS encoder state");
            }
            state = next as u32;
        }
        output.reverse();
        output.push(0);
        output.extend_from_slice(&state.to_le_bytes());
        output.rotate_right(5);
        Ok(output)
    }
}
pub(crate) struct Decoder<'a> {
    input: &'a [u8],
    position: usize,
    state: u32,
}
impl<'a> Decoder<'a> {
    pub(crate) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 5 || input[0] != 0 {
            return Err("invalid ANS prefix");
        }
        let state = u32::from_le_bytes(input[1..5].try_into().map_err(|_| "ANS initial state")?);
        if !(LOWER..UPPER).contains(&state) {
            return Err("invalid ANS initial state");
        }
        Ok(Self {
            input,
            position: 5,
            state,
        })
    }
    pub(crate) fn slot(&self, total: u32) -> Result<u32, &'static str> {
        scale(total)?;
        Ok(self.state & (total - 1))
    }
    #[inline(always)]
    fn consume_fixed<const BITS: u32>(&mut self, c: u32, f: u32) -> Result<(), &'static str> {
        // private callersは8/18のみ。interval/state不変条件でu32上限を証明済み。
        if BITS != 8 && BITS != 18 {
            return Err("invalid ANS total");
        }
        let total = 1u32 << BITS;
        if c > total || f == 0 || f > total - c {
            return Err("invalid ANS interval");
        }
        let slot = self.state & (total - 1);
        if slot < c || slot >= c + f {
            return Err("ANS slot outside interval");
        }
        // r=slot-c<f、q=x>>BITS: f*q+r<=total*(q+1)-1<=UPPER-1。
        let mut state = f * (self.state >> BITS) + (slot - c);
        let mut position = self.position;
        while state < LOWER {
            let byte = *self.input.get(position).ok_or("truncated ANS stream")?;
            // get成功でposition<len。state<2^23なのでshift/OR結果<2^31。
            position += 1;
            state = (state << 8) | u32::from(byte);
        }
        if state >= UPPER {
            return Err("ANS decoded state");
        }
        // Decoder state/positionは成功時だけcommit。呼出元historyのatomicityとは別。
        self.state = state;
        self.position = position;
        Ok(())
    }
    #[inline]
    pub(crate) fn consume_q18(&mut self, c: u32, f: u32) -> Result<(), &'static str> {
        self.consume_fixed::<18>(c, f)
    }
    #[inline]
    pub(crate) fn consume_byte(&mut self, c: u32, f: u32) -> Result<(), &'static str> {
        self.consume_fixed::<8>(c, f)
    }
    pub(crate) fn consume(&mut self, c: u32, f: u32, total: u32) -> Result<(), &'static str> {
        match total {
            Q => self.consume_q18(c, f),
            256 => self.consume_byte(c, f),
            _ => Err("invalid ANS total"),
        }
    }
    pub(crate) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() {
            return Err("trailing ANS bytes");
        }
        if self.state != LOWER {
            return Err("noncanonical ANS termination");
        }
        Ok(())
    }
}

/// 有限E2E入口。allocation failure注入は対象外。
pub(crate) fn finite_contract() -> Result<usize, &'static str> {
    let mut n = 0;
    let mut ck = |ok: bool| -> Result<(), &'static str> {
        if !ok {
            return Err("ANS finite contract");
        }
        n += 1;
        Ok(())
    };
    ck(Encoder::with_limit((1 << 20) + 1).is_err())?;
    for t in [256, Q] {
        for f in 1..=t {
            for c in [0, t - f] {
                let v = Event::pack(c, f, t)?;
                ck(v.0 & !USED_MASK == 0 && v.unpack()? == (c, f, t))?;
            }
        }
        for (c, f) in [(0, 0), (1, t), (t, 1), (u32::MAX, 2), (0, t + 1)] {
            ck(Event::pack(c, f, t).is_err())?;
        }
        let mut e = Encoder::with_limit(5)?;
        e.interval(0, t, t)?;
        ck(e.event_count() == 0 && e.capacity_bytes() == 0)?;
        ck(e.interval(1, t, t).is_err())?;
        let b = e.finish()?;
        let mut d = Decoder::new(&b)?;
        d.consume(0, t, t)?;
        d.finish()?;
        ck(d.state == LOWER && d.position == 5 && d.consume(1, t, t).is_err())?;
    }
    for bit in 38..64 {
        ck(Event(1 << bit).unpack().is_err())?;
    }
    for v in [0, F_MASK << 18] {
        ck(Event(v).unpack().is_err())?;
    }
    for t in [0, 1, 255, 257, 32768, u32::MAX] {
        ck(Event::pack(0, 1, t).is_err())?;
    }
    // 独立した有限整数witness: 8回中2回は3byte renormを要する。
    let mut e = Encoder::with_limit(23)?;
    for _ in 0..8 {
        e.interval(Q - 1, 1, Q)?;
    }
    let witness = e.finish()?;
    ck(witness.len() == 23 && witness[1..5] == ((33 * Q) - 1).to_le_bytes())?;
    let mut d = Decoder::new(&witness)?;
    for _ in 0..8 {
        d.consume(Q - 1, 1, Q)?;
    }
    d.finish()?;
    let mut ivs = vec![(Q - 1, 1, Q); 8];
    for i in 0..128u32 {
        let t = if i & 1 == 0 { Q } else { 256 };
        let f = [1, 2, t / 2, t - 1, t][i as usize % 5];
        ivs.push((if i & 2 == 0 { 0 } else { t - f }, f, t));
    }
    let encode = |limit| -> Result<Vec<u8>, &'static str> {
        let mut e = Encoder::with_limit(limit)?;
        for &(c, f, t) in &ivs {
            e.interval(c, f, t)?;
        }
        e.finish()
    };
    let decode = |b: &[u8]| -> Result<(), &'static str> {
        let mut d = Decoder::new(b)?;
        for &(c, f, t) in &ivs {
            let s = d.slot(t)?;
            if s < c || s >= c + f {
                return Err("ANS finite slot");
            }
            d.consume(c, f, t)?;
        }
        d.finish()
    };
    let b = encode(4096)?;
    decode(&b)?;
    for length in 0..b.len() {
        ck(decode(&b[..length]).is_err())?;
    }
    ck(encode(b.len() - 1) == Err("range output limit") && encode(b.len())? == b)?;
    let mut tail = b.clone();
    tail.push(0);
    ck(decode(&tail) == Err("trailing ANS bytes"))?;
    let mut h = [0u8; 5];
    for s in [0, LOWER - 1, UPPER, u32::MAX] {
        h[1..].copy_from_slice(&s.to_le_bytes());
        ck(Decoder::new(&h).is_err())?;
    }
    h[1..].copy_from_slice(&LOWER.to_le_bytes());
    h[0] = 1;
    ck(Decoder::new(&h).is_err())?;
    h[0] = 0;
    let mut d = Decoder::new(&h)?;
    ck(d.slot(32768).is_err() && d.consume(1, 1, Q).is_err() && d.consume(0, 1, Q).is_err())?;
    ck(d.state == LOWER && d.position == 5)?;
    h[1..].copy_from_slice(&(LOWER + 1).to_le_bytes());
    ck(Decoder::new(&h)?.finish() == Err("noncanonical ANS termination"))?;
    for l in 0..5 {
        ck(Encoder::with_limit(l)?.finish() == Err("range output limit"))?;
    }
    ck(growth(0, 0)? == Some(1024) && growth(2, 1).is_err() && growth(0, MAX_EVENTS + 1).is_err())?;
    ck(growth(MAX_EVENTS / 2 + 1, MAX_EVENTS / 2 + 1) == Err("ANS preallocation live bound"))?;
    let mut e = Encoder::with_limit(5)?;
    for _ in 0..MAX_EVENTS {
        e.interval(0, 1, 256)?;
    }
    ck(e.capacity_bytes() == MAX_RETAINED_BYTES && e.transient_bytes() == 8 * 1024 * 1024)?;
    ck(e.interval(0, 1, 256) == Err("ANS journal limit") && e.interval(1, Q, Q).is_err())?;
    e.interval(0, Q, Q)?;
    ck(e.event_count() == MAX_EVENTS)?;
    Ok(n + fixed_contract()?)
}

#[path = "../flat-token-ans/entropy.rs"]
mod old_backend;
// 旧checked実装とruntime/固定入口の結果、境界state、切断時commitを比較。
fn fixed_contract() -> Result<usize, &'static str> {
    let mut count = 0;
    for total in [256u32, Q] {
        for initial in [LOWER, LOWER + 1, UPPER - 1] {
            for f in [1, 2, total / 2, total - 1, total] {
                for c in [0, total - f] {
                    for extra in 0..=3 {
                        let mut bytes = [0u8; 8];
                        bytes[1..5].copy_from_slice(&initial.to_le_bytes());
                        let input = &bytes[..5 + extra];
                        let mut direct = Decoder::new(input)?;
                        let mut runtime = Decoder::new(input)?;
                        let mut old = old_backend::Decoder::new(input)?;
                        let before = (direct.state, direct.position);
                        let expected = old.consume(c, f, total);
                        let got = if total == Q {
                            direct.consume_q18(c, f)
                        } else {
                            direct.consume_byte(c, f)
                        };
                        let via_runtime = runtime.consume(c, f, total);
                        if got != expected
                            || via_runtime != expected
                            || (direct.state, direct.position) != (runtime.state, runtime.position)
                            || direct.slot(total)? != old.slot(total)?
                            || direct.finish() != old.finish()
                            || (got.is_err() && (direct.state, direct.position) != before)
                        {
                            return Err("fixed ANS old/runtime/state/atomicity");
                        }
                        count += 1;
                    }
                }
            }
            for (c, f) in [
                (0, 0),
                (total, 1),
                (1, total),
                (u32::MAX, 1),
                (0, total + 1),
            ] {
                let mut bytes = [0u8; 8];
                bytes[1..5].copy_from_slice(&initial.to_le_bytes());
                let mut d = Decoder::new(&bytes)?;
                let before = (d.state, d.position);
                if d.consume(c, f, total) != Err("invalid ANS interval")
                    || (d.state, d.position) != before
                {
                    return Err("fixed ANS invalid/atomicity");
                }
                count += 1;
            }
        }
    }
    let mut intervals = vec![(Q - 1, 1, Q); 8];
    for i in 0..128usize {
        let total = if i & 1 == 0 { Q } else { 256 };
        let f = [1, 2, total / 2, total - 1, total][i % 5];
        intervals.push((if i & 2 == 0 { 0 } else { total - f }, f, total));
    }
    let mut old = old_backend::Encoder::with_limit(4096)?;
    let mut new = Encoder::with_limit(4096)?;
    for &(c, f, total) in &intervals {
        old.interval(c, f, total)?;
        new.interval(c, f, total)?;
    }
    let bytes = old.finish()?;
    if new.finish()? != bytes {
        return Err("fixed ANS encoder payload changed");
    }
    for length in 0..=bytes.len() {
        let input = &bytes[..length];
        let old = old_backend::Decoder::new(input);
        let new = Decoder::new(input);
        match (old, new) {
            (Err(a), Err(b)) if a == b => (),
            (Ok(mut old), Ok(mut new)) => {
                let mut truncated = false;
                for &(c, f, total) in &intervals {
                    if old.slot(total)? != new.slot(total)? {
                        return Err("fixed ANS replay slot");
                    }
                    let before = (new.state, new.position);
                    let expected = old.consume(c, f, total);
                    let got = if total == Q {
                        new.consume_q18(c, f)
                    } else {
                        new.consume_byte(c, f)
                    };
                    if got != expected || (got.is_err() && (new.state, new.position) != before) {
                        return Err("fixed ANS replay errors/atomicity");
                    }
                    if got.is_err() {
                        truncated = true;
                        break;
                    }
                }
                if !truncated && old.finish() != new.finish() {
                    return Err("fixed ANS replay finish");
                }
            }
            _ => return Err("fixed ANS replay constructor"),
        }
        count += 1;
    }
    Ok(count)
}
