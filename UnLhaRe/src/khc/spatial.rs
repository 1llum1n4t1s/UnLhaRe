//! KCS1: 因果copyとliteral XOR残差の空間bit符号。revision 7専用。
use super::{block::multi_range as range, record::voter};
pub type Result<T> = std::result::Result<T, String>;
pub const MAX: usize = 1 << 20;
pub const HEADER: usize = 40;
pub const MAGIC: &[u8; 8] = b"KCS1BLK\0";
pub const MODEL_MAX: usize = 770;
const TOTAL: u32 = 32768;
#[derive(Default, Clone, Debug, PartialEq, Eq)]
pub(super) struct Stats {
    pub tokens: usize,
    pub copied: usize,
    pub literals: usize,
    pub count_bytes: usize,
    pub final_width: usize,
}
const fn crc_table() -> [u32; 256] {
    let mut out = [0; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut n = 0;
        while n < 8 {
            c = (c >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(c & 1));
            n += 1;
        }
        out[i] = c;
        i += 1;
    }
    out
}
const CRC: [u32; 256] = crc_table();
fn crc(parts: &[&[u8]]) -> u32 {
    let mut c = !0;
    for p in parts {
        for &b in *p {
            c = (c >> 8) ^ CRC[((c as u8) ^ b) as usize];
        }
    }
    !c
}
fn reseal(frame: &mut [u8]) {
    let c = crc(&[&frame[..28], &frame[32..]]);
    frame[28..32].copy_from_slice(&c.to_le_bytes());
}
pub(super) fn field(b: &[u8], p: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(p..p + 4)
            .ok_or("u32 extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn put(b: &mut [u8], p: usize, n: usize) {
    b[p..p + 4].copy_from_slice(&(n as u32).to_le_bytes());
}
fn alloc(n: usize) -> Result<Vec<u8>> {
    if n > MAX + HEADER {
        return Err("allocation extent".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| "allocation")?;
    if v.capacity() > MAX + HEADER {
        return Err("allocation capacity".into());
    }
    Ok(v)
}
#[derive(Clone, PartialEq, Eq)]
struct CountModel {
    pub freq: [u16; 256],
    cum: [u16; 256],
}
impl CountModel {
    pub fn normalize(count: &[u32; 256]) -> Result<Self> {
        let support = count.iter().filter(|&&n| n != 0).count();
        let sum: u64 = count.iter().map(|&n| u64::from(n)).sum();
        if sum == 0 {
            return Err("empty count model".into());
        }
        let mut freq = [0u16; 256];
        let mut residues = Vec::new();
        residues
            .try_reserve_exact(support)
            .map_err(|_| "model allocation")?;
        if residues.capacity() > 256 {
            return Err("model residue capacity".into());
        }
        let mut used = 0;
        for (symbol, &n) in count.iter().enumerate() {
            if n != 0 {
                let product = u64::from(n) * (TOTAL as usize - support) as u64;
                freq[symbol] = (1 + product / sum) as u16;
                used += usize::from(freq[symbol]);
                residues.push((product % sum, symbol));
            }
        }
        residues.sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        for &(_, symbol) in residues.iter().take(TOTAL as usize - used) {
            freq[symbol] += 1;
        }
        Self::from_freq(freq)
    }
    fn from_freq(freq: [u16; 256]) -> Result<Self> {
        let mut cum = [0; 256];
        let mut sum = 0u32;
        for i in 0..256 {
            if sum > TOTAL {
                return Err("CDF overflow".into());
            }
            cum[i] = sum as u16;
            sum += u32::from(freq[i]);
        }
        if sum != TOTAL {
            return Err("CDF total".into());
        }
        Ok(Self { freq, cum })
    }
    pub fn serialize(&self) -> Result<Vec<u8>> {
        let mut out = alloc(MODEL_MAX)?;
        let support = self.freq.iter().filter(|&&n| n != 0).count();
        out.extend_from_slice(&(support as u16).to_le_bytes());
        for i in 0..256 {
            if self.freq[i] != 0 {
                out.push(i as u8);
                out.extend_from_slice(&self.freq[i].to_le_bytes());
            }
        }
        Ok(out)
    }
    fn parse(b: &[u8]) -> Result<Self> {
        if !(5..=MODEL_MAX).contains(&b.len()) {
            return Err("model extent".into());
        }
        let support = u16::from_le_bytes(b[..2].try_into().unwrap()) as usize;
        if support == 0 || support > 256 || b.len() != 2 + 3 * support {
            return Err("model support".into());
        }
        let mut f = [0; 256];
        let mut previous = None;
        for entry in b[2..].as_chunks::<3>().0 {
            let i = entry[0] as usize;
            let n = u16::from_le_bytes(entry[1..].try_into().unwrap());
            if n == 0 || previous.is_some_and(|p| i <= p) {
                return Err("model order/frequency".into());
            }
            f[i] = n;
            previous = Some(i);
        }
        Self::from_freq(f)
    }
    pub fn encode<const COUNT_ONLY: bool>(
        &self,
        b: u8,
        enc: &mut range::Encoder<COUNT_ONLY>,
    ) -> Result<()> {
        let i = b as usize;
        enc.interval(u32::from(self.cum[i]), u32::from(self.freq[i]), TOTAL)
            .map_err(str::to_owned)
    }
    fn lookup(&self) -> Vec<u8> {
        let mut out = vec![0; TOTAL as usize];
        for i in 0..256 {
            out[usize::from(self.cum[i])..usize::from(self.cum[i]) + usize::from(self.freq[i])]
                .fill(i as u8);
        }
        out
    }
    fn decode(&self, lut: &[u8], dec: &mut range::Decoder<'_>) -> Result<u8> {
        let slot = dec.slot(TOTAL).map_err(str::to_owned)?;
        let b = lut[slot.value() as usize];
        let i = b as usize;
        dec.consume(slot, u32::from(self.cum[i]), u32::from(self.freq[i]), TOTAL)
            .map_err(str::to_owned)?;
        Ok(b)
    }
}
fn update(p: u16, one: bool) -> u16 {
    let p = u32::from(p);
    (if one {
        p - p.div_ceil(32)
    } else {
        p + (32768 - p).div_ceil(32)
    })
    .clamp(1, 32767) as u16
}
fn windows(raw: &[u8], i: usize, w: usize) -> (u32, u32) {
    let col = i % w;
    let mut first = 0;
    let mut second = 0;
    if i >= w {
        let up = i - w;
        let l = if col > 0 { raw[up - 1] } else { 0 };
        let r = if col + 1 < w { raw[up + 1] } else { 0 };
        first = (u32::from(l) << 16) | (u32::from(raw[up]) << 8) | u32::from(r);
    }
    if i >= w * 2 {
        let up = i - w * 2;
        let r = if col + 1 < w { raw[up + 1] } else { 0 };
        second = (u32::from(raw[up]) << 8) | u32::from(r);
    }
    (first, second)
}
fn key(left: usize, first: u32, second: u32, shift: usize) -> usize {
    (left & 15)
        | (((first >> (shift + 5)) as usize & 63) << 4)
        | (((second >> (shift + 7)) as usize & 3) << 10)
}
#[derive(Clone, Copy)]
enum Event {
    Count(u8),
    Literal {
        at: usize,
        width: usize,
        residual: u8,
    },
}
// Countのbit15とbyte、Literalの幅-1と直前Count0のbit14を最大MAX件・2MiBで保存。
struct ReplayEvent(u16);
const _: () = assert!(std::mem::size_of::<ReplayEvent>() == 2);
impl ReplayEvent {
    fn new(event: Event, zero_count: bool) -> Result<Self> {
        Ok(match event {
            Event::Count(value) if !zero_count && value != 0 => Self(0x8000 | u16::from(value)),
            Event::Literal { width, .. } if (1..=1024).contains(&width) => {
                Self((width - 1) as u16 | if zero_count { 0x4000 } else { 0 })
            }
            _ => return Err("event width".into()),
        })
    }
    fn zero_count(&self) -> bool {
        self.0 & 0xc000 == 0x4000
    }
}
#[derive(Default)]
struct ReplayPosition {
    at: usize,
    count: usize,
    count_bytes: usize,
}
impl ReplayPosition {
    fn event(&mut self, record: &ReplayEvent, raw: &[u8]) -> Result<Event> {
        if record.0 & 0x8000 != 0 {
            if record.0 & 0x7f00 != 0 || self.count_bytes >= 3 {
                return Err("event count encoding".into());
            }
            let byte = record.0 as u8;
            self.count |= usize::from(byte & 127) << (7 * self.count_bytes);
            self.count_bytes += 1;
            if self.count > raw.len().saturating_sub(self.at) {
                return Err("event copy extent".into());
            }
            if byte & 128 == 0 {
                self.at = self.at.checked_add(self.count).ok_or("event position")?;
                self.count = 0;
                self.count_bytes = 0;
            } else if self.count_bytes == 3 {
                return Err("event count continuation".into());
            }
            Ok(Event::Count(byte))
        } else {
            if record.0 & !0x43ff != 0 || self.count_bytes != 0 || self.at >= raw.len() {
                return Err("event literal extent".into());
            }
            let at = self.at;
            let width = usize::from(record.0 & 1023) + 1;
            let pred = at.checked_sub(width).map_or(0, |p| raw[p]);
            self.at += 1;
            Ok(Event::Literal {
                at,
                width,
                residual: raw[at] ^ pred,
            })
        }
    }
    fn finish(&self, length: usize) -> Result<()> {
        if self.at != length || self.count_bytes != 0 || self.count != 0 {
            return Err("event completion".into());
        }
        Ok(())
    }
}
fn walk(raw: &[u8], mut event: impl FnMut(Event) -> Result<()>) -> Result<Stats> {
    if raw.len() > MAX {
        return Err("input bound".into());
    }
    let mut v = voter::Voter::new()?;
    if v.capacity() > voter::BOUND {
        return Err("voter capacity".into());
    }
    let mut s = Stats::default();
    let mut at = 0;
    while at < raw.len() {
        let begin = at;
        while at < raw.len() {
            let pred = at.checked_sub(v.best()).map_or(0, |p| raw[p]);
            if raw[at] != pred {
                break;
            }
            v.observe(raw[at])?;
            at += 1;
        }
        let mut n = at - begin;
        s.copied += n;
        s.tokens += 1;
        loop {
            let b = (n & 127) as u8;
            n >>= 7;
            event(Event::Count(b | if n != 0 { 128 } else { 0 }))?;
            s.count_bytes += 1;
            if n == 0 {
                break;
            }
        }
        if at < raw.len() {
            let width = v.best();
            let pred = at.checked_sub(width).map_or(0, |p| raw[p]);
            event(Event::Literal {
                at,
                width,
                residual: raw[at] ^ pred,
            })?;
            s.literals += 1;
            v.observe(raw[at])?;
            at += 1;
        }
    }
    s.final_width = v.best();
    Ok(s)
}
fn pack(raw: &[u8], model: &[u8], payload: &[u8], method: u8) -> Result<Vec<u8>> {
    if raw.len() > MAX || model.len() > MODEL_MAX || model.len() + payload.len() > raw.len() {
        return Err("pack extent".into());
    }
    let mut frame = alloc(HEADER + model.len() + payload.len())?;
    frame.resize(HEADER, 0);
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[10] = method;
    put(&mut frame, 12, raw.len());
    put(&mut frame, 16, model.len());
    put(&mut frame, 20, payload.len());
    frame[24..28].copy_from_slice(&crc(&[raw]).to_le_bytes());
    frame.extend_from_slice(model);
    frame.extend_from_slice(payload);
    reseal(&mut frame);
    Ok(frame)
}
pub(super) fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    encode_inner::<false>(raw).map(|(frame, _, stats)| (frame, stats))
}
pub(super) fn encoded_len(raw: &[u8]) -> Result<usize> {
    encode_inner::<true>(raw).map(|(_, length, _)| length)
}
// 計数時もmodel・一度だけのwalk・range上限を共用し、frameの実体化だけを省く。
fn encode_inner<const COUNT_ONLY: bool>(raw: &[u8]) -> Result<(Vec<u8>, usize, Stats)> {
    if raw.len() > MAX {
        return Err("input bound".into());
    }
    let collect = raw.len() > 10;
    let event_limit = raw.len();
    let mut events = Vec::new();
    if collect {
        events
            .try_reserve_exact(event_limit)
            .map_err(|_| "event allocation")?;
        if events.capacity() > event_limit {
            return Err("event capacity".into());
        }
    }
    let mut hist = [0; 256];
    let mut zero_count = false;
    let stats = walk(raw, |event| {
        if let Event::Count(b) = event {
            hist[b as usize] += 1;
        }
        if collect {
            if let Event::Count(0) = event {
                if zero_count {
                    return Err("event pending zero count".into());
                }
                zero_count = true;
                return Ok(());
            }
            // 正数copy長cのvarint件数<=c。Count0は次のLiteralへ併合し、
            // copy総数+Literal数=N以下。pushで再確保させない。
            if events.len() == event_limit {
                return Err("event count bound".into());
            }
            events.push(ReplayEvent::new(event, zero_count)?);
            zero_count = false;
        }
        Ok(())
    })?;
    if zero_count {
        return Err("event pending zero count".into());
    }
    if raw.len() > 10 {
        let model = CountModel::normalize(&hist)?;
        let meta = if COUNT_ONLY {
            Vec::new()
        } else {
            model.serialize()?
        };
        if meta.capacity() > MODEL_MAX {
            return Err("model capacity".into());
        }
        let model_len = 2 + 3 * model.freq.iter().filter(|&&n| n != 0).count();
        if let Some(limit) = raw.len().checked_sub(model_len + 1).filter(|&n| n >= 5) {
            let mut enc = range::Encoder::<COUNT_ONLY>::with_limit(limit).map_err(str::to_owned)?;
            // limit<=MAXで初回に全量を予約するため、以後のintervalは再確保しない。
            if enc.allocated_bytes() > MAX {
                return Err("range capacity".into());
            }
            let mut table = [16384; 4096];
            let mut position = ReplayPosition::default();
            let coded = events
                .iter()
                .try_for_each(|event| {
                    let replayed = position.event(event, raw)?;
                    if event.zero_count() {
                        model.encode(0, &mut enc)?;
                    }
                    match replayed {
                        Event::Count(b) => model.encode(b, &mut enc)?,
                        Event::Literal {
                            at,
                            width,
                            residual,
                        } => {
                            let (first, second) = windows(raw, at, width);
                            let mut left = if at % width == 0 {
                                0
                            } else {
                                usize::from(raw[at - 1] & 15)
                            };
                            for shift in (0..8).rev() {
                                let k = key(left, first, second, shift);
                                let p = u32::from(table[k]);
                                let one = residual & (1 << shift) != 0;
                                let (c, f) = if one { (p, TOTAL - p) } else { (0, p) };
                                enc.interval(c, f, TOTAL).map_err(str::to_owned)?;
                                table[k] = update(table[k], one);
                                left = ((left << 1) | usize::from(one)) & 15;
                            }
                        }
                    }
                    Ok(())
                })
                // range出力上限で途中終了した場合は位置検査をせず、従来のstoredへ戻す。
                .and_then(|_| position.finish(raw.len()))
                .and_then(|_| enc.finish_with_length().map_err(str::to_owned));
            // 完成frameの確保やraw fallbackとtranscriptを重ねない。
            drop(std::mem::take(&mut events));
            match coded {
                Ok((payload, payload_len)) => {
                    let frame = if COUNT_ONLY {
                        Vec::new()
                    } else {
                        pack(raw, &meta, &payload, 1)?
                    };
                    return Ok((frame, HEADER + model_len + payload_len, stats));
                }
                Err(e) if e == "range output limit" => {}
                Err(e) => return Err(e),
            }
        }
    }
    drop(events);
    let frame = if COUNT_ONLY {
        Vec::new()
    } else {
        pack(raw, &[], raw, 0)?
    };
    Ok((frame, HEADER + raw.len(), stats))
}
pub(super) fn validate_frame(frame: &[u8], expected: usize) -> Result<()> {
    if frame.len() < HEADER
        || frame.len() > MAX + HEADER
        || &frame[..8] != MAGIC
        || frame[8..10] != [1, 0]
        || frame[11] != 0
        || frame[32..40] != [0; 8]
    {
        return Err("header/version/reserved".into());
    }
    let raw = field(frame, 12)?;
    let model_len = field(frame, 16)?;
    let payload_len = field(frame, 20)?;
    if raw > MAX
        || raw != expected
        || model_len > MODEL_MAX
        || model_len + payload_len > raw
        || HEADER + model_len + payload_len != frame.len()
    {
        return Err("frame lengths".into());
    }
    if crc(&[&frame[..28], &frame[32..]]) as usize != field(frame, 28)? {
        return Err("wire CRC".into());
    }
    match frame[10] {
        0 if model_len == 0 && payload_len == raw => {}
        1 if raw != 0 && model_len + payload_len < raw && payload_len >= 5 => {
            CountModel::parse(&frame[HEADER..HEADER + model_len])?;
        }
        _ => return Err("method fields".into()),
    }
    Ok(())
}

// frame + out + voter + lookup + tables/model/stacks stay below this fixed bound.
// Caller input/output and manifest are separately accounted by the archive layer.
pub(super) const MEMORY_BOUND: usize = 2 * (MAX + HEADER) + voter::BOUND + 32768 + 65536 + MAX * 2;
const _: () = assert!(MEMORY_BOUND <= super::CODEC_MEMORY_BYTES as usize);

pub(super) fn decode(frame: &[u8], expected: usize) -> Result<(Vec<u8>, Stats)> {
    validate_frame(frame, expected)?;
    let raw = field(frame, 12)?;
    let model_len = field(frame, 16)?;
    let payload_len = field(frame, 20)?;
    let mut out = alloc(raw)?;
    let mut stats = Stats::default();
    match frame[10] {
        0 => {
            if model_len != 0 || payload_len != raw {
                return Err("stored fields".into());
            }
            out.extend_from_slice(&frame[HEADER..]);
        }
        1 => {
            if raw == 0 || model_len + payload_len >= raw || payload_len < 5 {
                return Err("coded fields".into());
            }
            let model = CountModel::parse(&frame[HEADER..HEADER + model_len])?;
            let lut = model.lookup();
            let mut histogram = [0; 256];
            let mut dec =
                range::Decoder::new(&frame[HEADER + model_len..]).map_err(str::to_owned)?;
            let mut v = voter::Voter::new()?;
            if v.capacity() > voter::BOUND {
                return Err("voter capacity".into());
            }
            let mut table = [16384; 4096];
            while out.len() < raw {
                let mut count = 0;
                for n in 0..3 {
                    let b = model.decode(&lut, &mut dec)?;
                    histogram[b as usize] += 1;
                    stats.count_bytes += 1;
                    count |= usize::from(b & 127) << (7 * n);
                    if b & 128 == 0 {
                        if n != 0 && b == 0 {
                            return Err("overlong count".into());
                        }
                        break;
                    }
                    if n == 2 {
                        return Err("count width".into());
                    }
                }
                if count > raw - out.len() {
                    return Err("count remaining".into());
                }
                stats.tokens += 1;
                stats.copied += count;
                for _ in 0..count {
                    let pred = out.len().checked_sub(v.best()).map_or(0, |p| out[p]);
                    out.push(pred);
                    v.observe(pred)?;
                }
                if out.len() == raw {
                    break;
                }
                let at = out.len();
                let width = v.best();
                let pred = at.checked_sub(width).map_or(0, |p| out[p]);
                // windowsは完成済みbyteしか読まない。現在byte用のplaceholderは不要。
                let (first, second) = windows(&out, at, width);
                let mut left = if at % width == 0 {
                    0
                } else {
                    usize::from(out[at - 1] & 15)
                };
                let mut residual = 0u8;
                for shift in (0..8).rev() {
                    let k = key(left, first, second, shift);
                    let p = u32::from(table[k]);
                    let slot = dec.slot(TOTAL).map_err(str::to_owned)?;
                    let one = slot.value() >= p;
                    let (c, f) = if one { (p, TOTAL - p) } else { (0, p) };
                    dec.consume(slot, c, f, TOTAL).map_err(str::to_owned)?;
                    if one {
                        residual |= 1 << shift;
                    }
                    table[k] = update(table[k], one);
                    left = ((left << 1) | usize::from(one)) & 15;
                }
                if residual == 0 {
                    return Err("zero residual/nonmaximal copy".into());
                }
                let plain = pred ^ residual;
                out.push(plain);
                v.observe(plain)?;
                stats.literals += 1;
            }
            dec.finish().map_err(str::to_owned)?;
            if CountModel::normalize(&histogram)? != model {
                return Err("noncanonical count CDF".into());
            }
            stats.final_width = v.best();
        }
        _ => return Err("unknown method".into()),
    }
    if crc(&[&out]) as usize != field(frame, 24)? {
        return Err("raw CRC".into());
    }
    Ok((out, stats))
}
