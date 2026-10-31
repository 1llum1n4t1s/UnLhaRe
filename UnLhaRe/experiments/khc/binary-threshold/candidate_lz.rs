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
        let bit = r.binary(p)?;
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
    let trial = (|| -> Result<Vec<u8>> {
        while at < raw.len() {
            let mut best = 0;
            let mut distance = 0;
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
                    if len > best && len >= 3 {
                        best = len;
                        distance = at - p;
                    }
                    if best == cap || comparisons == budget {
                        break;
                    }
                }
            }
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
