//! 有界LZ＋整数適応range。初段の独立試作を採用前の明示経路へ統合する。
//! LZMA等に近い既存技術の組合せであり、新圧縮原理ではない。
use super::{MAX_INPUT as MAX, Result, allocate as allocated, multi_range as range};
struct Models {
    p: Vec<u16>,
    base: usize,
    context: u8,
}
impl Models {
    fn new(context: u8) -> Result<Self> {
        if !matches!(context, 3 | 8) {
            return Err("literal context".into());
        }
        let base = (1usize << context) * 256;
        Ok(Self {
            p: allocated(base + 20 + 2 * 1056, 16384)?,
            base,
            context,
        })
    }
    fn update(&mut self, index: usize, bit: u32) {
        let p = u32::from(self.p[index]);
        self.p[index] = if bit == 0 {
            p + ((32768 - p) >> 5)
        } else {
            p - (p >> 5)
        } as u16;
    }
    fn write(&mut self, r: &mut range::Encoder, index: usize, bit: u32) -> Result<()> {
        let p = u32::from(self.p[index]);
        let (c, f) = if bit == 0 { (0, p) } else { (p, 32768 - p) };
        r.interval(c, f, 32768)?;
        self.update(index, bit);
        Ok(())
    }
    fn read(&mut self, r: &mut range::Decoder<'_>, index: usize) -> Result<u32> {
        let p = u32::from(self.p[index]);
        let bit = u32::from(r.slot(32768)? >= p);
        let (c, f) = if bit == 0 { (0, p) } else { (p, 32768 - p) };
        r.consume(c, f, 32768)?;
        self.update(index, bit);
        Ok(bit)
    }
    fn tree_write(
        &mut self,
        r: &mut range::Encoder,
        base: usize,
        value: u32,
        bits: usize,
    ) -> Result<()> {
        let mut prefix = 1;
        for b in (0..bits).rev() {
            let bit = (value >> b) & 1;
            self.write(r, base + prefix, bit)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok(())
    }
    fn tree_read(&mut self, r: &mut range::Decoder<'_>, base: usize, bits: usize) -> Result<u32> {
        let mut prefix = 1;
        for _ in 0..bits {
            let bit = self.read(r, base + prefix)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok((prefix - (1 << bits)) as u32)
    }
    fn number_write(&mut self, r: &mut range::Encoder, class: usize, value: usize) -> Result<()> {
        let log = usize::BITS as usize - 1 - value.leading_zeros() as usize;
        let base = self.base + 20 + class * 1056;
        self.tree_write(r, base, log as u32, 5)?;
        for b in (0..log).rev() {
            self.write(r, base + 32 + log * 32 + b, ((value >> b) & 1) as u32)?;
        }
        Ok(())
    }
    fn number_read(
        &mut self,
        r: &mut range::Decoder<'_>,
        class: usize,
        maximum: usize,
    ) -> Result<usize> {
        let base = self.base + 20 + class * 1056;
        let log = self.tree_read(r, base, 5)? as usize;
        if log > 20 {
            return Err("number log bound".into());
        }
        let mut value = 1usize << log;
        for b in (0..log).rev() {
            value |= (self.read(r, base + 32 + log * 32 + b)? as usize) << b;
        }
        if value > maximum {
            return Err("number value bound".into());
        }
        Ok(value)
    }
    fn literal_write(&mut self, r: &mut range::Encoder, previous: u8, byte: u8) -> Result<()> {
        let base = usize::from(previous >> (8 - self.context)) * 256;
        self.tree_write(r, base, u32::from(byte), 8)
    }
    fn literal_read(&mut self, r: &mut range::Decoder<'_>, previous: u8) -> Result<u8> {
        let base = usize::from(previous >> (8 - self.context)) * 256;
        Ok(self.tree_read(r, base, 8)? as u8)
    }
}
// COST HELPERS BEGIN
std::thread_local! {
    static TRACE: std::cell::Cell<[usize; 7]> = const { std::cell::Cell::new([0; 7]) };
}
pub(super) fn reset_trace() {
    TRACE.with(|t| t.set([0; 7]));
}
pub(super) fn trace() -> [usize; 7] {
    TRACE.with(std::cell::Cell::get)
}
const fn entropy_q8(f: u32) -> u16 {
    if f == 0 {
        return u16::MAX;
    }
    let exponent = 31 - f.leading_zeros();
    let mut x = (f as u64) << (31 - exponent);
    let mut fraction = 0u32;
    let mut i = 0;
    while i < 8 {
        x = (x * x) >> 31;
        fraction <<= 1;
        if x >= (1u64 << 32) {
            x >>= 1;
            fraction |= 1;
        }
        i += 1;
    }
    ((15 - exponent) * 256 - fraction) as u16
}
const fn table() -> [u16; 32768] {
    let mut out = [0; 32768];
    let mut i = 0;
    while i < out.len() {
        out[i] = entropy_q8(i as u32);
        i += 1;
    }
    out
}
static COST: [u16; 32768] = table();
fn prefer(cost: u32, length: usize, previous_cost: u32, previous_length: usize) -> Result<bool> {
    if length < 3 || length > 4096 || previous_length < 3 || previous_length > 4096 {
        return Err("cost match length".into());
    }
    let a = u64::from(cost) * previous_length as u64;
    let b = u64::from(previous_cost) * length as u64;
    Ok(a < b || (a == b && length > previous_length))
}
impl Models {
    fn cost_bit(&self, index: usize, bit: u32) -> Result<u32> {
        if bit > 1 {
            return Err("cost bit".into());
        }
        let p = u32::from(*self.p.get(index).ok_or("cost model index")?);
        let f = if bit == 0 { p } else { 32768 - p };
        if !(1..32768).contains(&f) {
            return Err("cost probability".into());
        }
        Ok(u32::from(COST[f as usize]))
    }
    fn cost_tree(&self, base: usize, value: u32, bits: usize) -> Result<u32> {
        let mut prefix = 1;
        let mut cost = 0;
        for b in (0..bits).rev() {
            let bit = (value >> b) & 1;
            cost += self.cost_bit(base + prefix, bit)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok(cost)
    }
    fn cost_number(&self, class: usize, value: usize) -> Result<u32> {
        if value == 0 || value > MAX || class > 1 {
            return Err("cost number".into());
        }
        let log = usize::BITS as usize - 1 - value.leading_zeros() as usize;
        let base = self.base + 20 + class * 1056;
        let mut cost = self.cost_tree(base, log as u32, 5)?;
        for b in (0..log).rev() {
            cost += self.cost_bit(base + 32 + log * 32 + b, ((value >> b) & 1) as u32)?;
        }
        Ok(cost)
    }
    fn cost_match(
        &self,
        at: usize,
        previous_match: bool,
        reps: &[usize; 4],
        length: usize,
        distance: usize,
    ) -> Result<u32> {
        if length < 3 || length > 4096 || distance == 0 || distance > at {
            return Err("cost match extent".into());
        }
        let mut cost = self.cost_bit(self.base + (at & 7) + usize::from(previous_match) * 8, 1)?;
        let rep = reps.iter().position(|&d| d == distance);
        cost += self.cost_bit(self.base + 16, u32::from(rep.is_none()))?;
        cost += if let Some(index) = rep {
            self.cost_tree(self.base + 16, index as u32, 2)?
        } else {
            self.cost_number(1, distance)?
        };
        cost += self.cost_number(0, length - 2)?;
        Ok(cost)
    }
}
pub(super) fn contract() -> Result<usize> {
    for f in 1..32768usize {
        let reference = (32768.0 / f as f64).log2() * 256.0;
        let error = f64::from(COST[f]) - reference;
        if error < -0.0001 || error > 1.0001 || (f > 1 && COST[f] > COST[f - 1]) {
            return Err("integer log oracle/monotonicity".into());
        }
    }
    if COST[1] != 3840
        || COST[16384] != 256
        || COST[0] != u16::MAX
        || prefer(200, 10, 200, 10)?
        || !prefer(400, 20, 200, 10)?
        || !prefer(199, 10, 200, 10)?
        || prefer(201, 10, 200, 10)?
        || prefer(1, 2, 2, 3).is_ok()
        || prefer(1, 4097, 2, 3).is_ok()
    {
        return Err("cost ties/boundaries".into());
    }
    let models = Models::new(8)?;
    let before = models.p.clone();
    let reps = [1, 4, 8, 16];
    for length in [3, 4, 255, 256, 257, 4096] {
        for distance in [1, 4, 8, 16, 17, 65536, MAX] {
            let cost = models.cost_match(MAX, false, &reps, length, distance)?;
            if cost == 0 || cost > 45 * 3840 {
                return Err("cost bound".into());
            }
        }
    }
    if models.p != before
        || models.cost_bit(0, 2).is_ok()
        || models.cost_bit(models.p.len(), 0).is_ok()
        || models.cost_match(0, false, &reps, 3, 1).is_ok()
    {
        return Err("cost purity/rejection".into());
    }
    Ok(32767 + 9 + 42 + 4)
}
// COST HELPERS END

fn hash(raw: &[u8], i: usize) -> usize {
    let v = u32::from(raw[i]) | u32::from(raw[i + 1]) << 8 | u32::from(raw[i + 2]) << 16;
    (v.wrapping_mul(0x1e35a7bd) >> 16) as usize
}
fn remember(reps: &mut [usize; 4], distance: usize) {
    let index = reps.iter().position(|&v| v == distance).unwrap_or(3);
    reps.copy_within(0..index, 1);
    reps[0] = distance;
}
pub(super) fn encode(raw: &[u8], context: u8) -> Result<Option<Vec<u8>>> {
    if raw.len() > MAX {
        return Err("raw bound".into());
    }
    let mut models = Models::new(context)?;
    let mut r = range::Encoder::with_limit(MAX * 2 + 64)?;
    let mut heads = allocated(65536, u32::MAX)?;
    let mut chain = allocated(raw.len(), u32::MAX)?;
    let mut reps = [1, 4, 8, 16];
    let mut at = 0;
    let mut previous_match = false;
    let mut comparisons = 0;
    let budget = raw.len() * 64;
    // COST TRACE BEGIN
    let mut observed = [0usize; 7];
    observed[1] = raw.len();
    // COST TRACE END
    let trial = (|| -> Result<Vec<u8>> {
        while at < raw.len() {
            let mut best = 0;
            let mut distance = 0;
            // COST OFFERS BEGIN
            let mut offers = [(0usize, 0usize); 36];
            let mut offer_count = 0;
            // COST OFFERS END
            if at + 3 <= raw.len() {
                let mut candidates = [u32::MAX; 36];
                let mut count = 0;
                for &d in &reps {
                    if d <= at {
                        candidates[count] = (at - d) as u32;
                        count += 1;
                    }
                }
                let mut p = heads[hash(raw, at)];
                for _ in 0..32 {
                    if p == u32::MAX {
                        break;
                    }
                    candidates[count] = p;
                    count += 1;
                    p = chain[p as usize];
                }
                let cap = (raw.len() - at).min(4096);
                for &p in &candidates[..count] {
                    let p = p as usize;
                    if p >= at {
                        return Err("match chain order".into());
                    }
                    let mut len = 0;
                    while len < cap && comparisons < budget {
                        comparisons += 1;
                        if raw[p + len] != raw[at + len] {
                            break;
                        }
                        len += 1;
                    }
                    // COST COLLECT BEGIN
                    if len >= 3 {
                        offers[offer_count] = (len, at - p);
                        offer_count += 1;
                    }
                    // COST COLLECT END
                    if len > best && len >= 3 {
                        best = len;
                        distance = at - p;
                    }
                    if best == cap || comparisons == budget {
                        break;
                    }
                }
            }
            // COST SELECT BEGIN
            if comparisons == budget && observed[1] == raw.len() {
                observed[1] = at;
            }
            if best >= 3 {
                let greedy = (best, distance);
                let mut cheapest = models.cost_match(at, previous_match, &reps, best, distance)?;
                observed[2] += 1;
                for &(length, candidate_distance) in &offers[..offer_count] {
                    let cost =
                        models.cost_match(at, previous_match, &reps, length, candidate_distance)?;
                    observed[5] += 1;
                    if prefer(cost, length, cheapest, best)? {
                        best = length;
                        distance = candidate_distance;
                        cheapest = cost;
                    }
                }
                if (best, distance) != greedy {
                    observed[3] += 1;
                }
                if best < greedy.0 {
                    observed[4] += 1;
                }
                observed[6] += 1;
            }
            // COST SELECT END
            let flag = models.base + (at & 7) + usize::from(previous_match) * 8;
            models.write(&mut r, flag, u32::from(best >= 3))?;
            let step = if best >= 3 {
                let rep = reps.iter().position(|&d| d == distance);
                models.write(&mut r, models.base + 16, u32::from(rep.is_none()))?;
                if let Some(index) = rep {
                    models.tree_write(&mut r, models.base + 16, index as u32, 2)?;
                } else {
                    models.number_write(&mut r, 1, distance)?;
                }
                models.number_write(&mut r, 0, best - 2)?;
                remember(&mut reps, distance);
                previous_match = true;
                best
            } else {
                models.literal_write(&mut r, if at == 0 { 0 } else { raw[at - 1] }, raw[at])?;
                previous_match = false;
                1
            };
            for (i, previous) in chain.iter_mut().enumerate().skip(at).take(step) {
                if i + 3 <= raw.len() {
                    let h = hash(raw, i);
                    *previous = heads[h];
                    heads[h] = i as u32;
                }
            }
            at += step;
        }
        Ok(r.finish()?)
    })();
    // COST STORE BEGIN
    observed[0] = comparisons;
    TRACE.with(|t| t.set(observed));
    // COST STORE END
    match trial {
        Ok(payload) if payload.len() < raw.len() => Ok(Some(payload)),
        Ok(_) => Ok(None),
        Err(e) if e == "range output limit" => Ok(None),
        Err(e) => Err(e),
    }
}

pub(super) fn decode(payload: &[u8], raw: usize, context: u8) -> Result<Vec<u8>> {
    if raw > MAX || payload.len() < 5 || payload.len() >= raw {
        return Err("LZ payload/raw extent".into());
    }
    let mut out = Vec::new();
    out.try_reserve_exact(raw)
        .map_err(|_| "LZ output allocation")?;
    let mut m = Models::new(context)?;
    let mut r = range::Decoder::new(payload)?;
    let mut reps = [1, 4, 8, 16];
    let mut previous_match = false;
    while out.len() < raw {
        let flag = m.base + (out.len() & 7) + usize::from(previous_match) * 8;
        if m.read(&mut r, flag)? == 1 {
            let distance = if m.read(&mut r, m.base + 16)? == 0 {
                let index = m.tree_read(&mut r, m.base + 16, 2)? as usize;
                reps[index]
            } else {
                m.number_read(&mut r, 1, MAX)?
            };
            let length = m.number_read(&mut r, 0, 4094)? + 2;
            if distance == 0 || distance > out.len() || length > raw - out.len() {
                return Err("match offset/extent".into());
            }
            for _ in 0..length {
                let byte = out[out.len() - distance];
                out.push(byte);
            }
            remember(&mut reps, distance);
            previous_match = true;
        } else {
            let byte = m.literal_read(&mut r, out.last().copied().unwrap_or(0))?;
            out.push(byte);
            previous_match = false;
        }
    }
    r.finish()?;
    Ok(out)
}
