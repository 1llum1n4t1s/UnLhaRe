//! 独立KCS1実験。copy中は投票のみ、literal中だけ空間bit確率を更新する。
#[path = "../../../src/khc/block/multi_range.rs"]
pub mod range;
#[path = "../causal-record-vote/voter.rs"]
mod voter;
pub type Result<T> = std::result::Result<T, String>;
pub const MAX: usize = 1 << 20;
pub const HEADER: usize = 40;
pub const MAGIC: &[u8; 8] = b"KCS1BLK\0";
pub const MODEL_MAX: usize = 770;
const TOTAL: u32 = 32768;
#[derive(Default, Clone, Debug, PartialEq, Eq)]
pub struct Stats {
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
pub fn crc(parts: &[&[u8]]) -> u32 {
    let mut c = !0;
    for p in parts {
        for &b in *p {
            c = (c >> 8) ^ CRC[((c as u8) ^ b) as usize];
        }
    }
    !c
}
pub fn reseal(frame: &mut [u8]) {
    let c = crc(&[&frame[..28], &frame[32..]]);
    frame[28..32].copy_from_slice(&c.to_le_bytes());
}
pub fn field(b: &[u8], p: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(p..p + 4)
            .ok_or("u32 extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
pub fn put(b: &mut [u8], p: usize, n: usize) {
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
pub struct CountModel {
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
        let mut residues = Vec::with_capacity(support);
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
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(MODEL_MAX);
        let support = self.freq.iter().filter(|&&n| n != 0).count();
        out.extend_from_slice(&(support as u16).to_le_bytes());
        for i in 0..256 {
            if self.freq[i] != 0 {
                out.push(i as u8);
                out.extend_from_slice(&self.freq[i].to_le_bytes());
            }
        }
        out
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
        for entry in b[2..].chunks_exact(3) {
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
    pub fn encode(&self, b: u8, enc: &mut range::Encoder) -> Result<()> {
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
pub fn update(p: u16, one: bool) -> u16 {
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
pub fn key(left: usize, first: u32, second: u32, shift: usize) -> usize {
    (left & 15)
        | (((first >> (shift + 5)) as usize & 63) << 4)
        | (((second >> (shift + 7)) as usize & 3) << 10)
}
enum Event {
    Count(u8),
    Literal {
        at: usize,
        width: usize,
        residual: u8,
    },
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
pub fn pack(raw: &[u8], model: &[u8], payload: &[u8], method: u8) -> Result<Vec<u8>> {
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
pub fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    let mut hist = [0; 256];
    let stats = walk(raw, |event| {
        if let Event::Count(b) = event {
            hist[b as usize] += 1;
        }
        Ok(())
    })?;
    if raw.len() > 10 {
        let model = CountModel::normalize(&hist)?;
        let meta = model.serialize();
        if let Some(limit) = raw.len().checked_sub(meta.len() + 1).filter(|&n| n >= 5) {
            let mut enc = range::Encoder::with_limit(limit).map_err(str::to_owned)?;
            let mut table = [16384; 4096];
            let coded = walk(raw, |event| {
                match event {
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
            .and_then(|_| enc.finish().map_err(str::to_owned));
            match coded {
                Ok(payload) => return Ok((pack(raw, &meta, &payload, 1)?, stats)),
                Err(e) if e == "range output limit" => {}
                Err(e) => return Err(e),
            }
        }
    }
    Ok((pack(raw, &[], raw, 0)?, stats))
}
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
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
        || model_len > MODEL_MAX
        || model_len + payload_len > raw
        || HEADER + model_len + payload_len != frame.len()
    {
        return Err("frame lengths".into());
    }
    if crc(&[&frame[..28], &frame[32..]]) as usize != field(frame, 28)? {
        return Err("wire CRC".into());
    }
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
