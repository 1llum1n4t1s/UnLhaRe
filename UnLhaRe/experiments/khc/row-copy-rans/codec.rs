//! 私的KRP1：因果幅の最大copy文法＋保存済み2byte CDF。製品形式ではない。
use super::baseline;
#[path = "../mdl-rans/entropy.rs"]
pub mod entropy;
#[path = "../causal-record-vote/voter.rs"]
mod voter;
pub type Result<T> = std::result::Result<T, String>;
pub const MAX_RAW: usize = 1 << 20;
pub const HEADER: usize = 40;
pub const MAGIC: &[u8; 8] = b"KRP1BLK\0";
pub const MODEL_BOUND: usize = 1540;
pub const TABLE_BOUND: usize = 65536;
const FIXED: usize = 16384 + 78000 + 65536;
#[derive(Default, Clone, Debug)]
pub struct Stats {
    pub method: u8,
    pub metadata: usize,
    pub fields: usize,
    pub tokens: usize,
    pub copied: usize,
    pub literals: usize,
    pub width: usize,
    pub journal: usize,
    pub transient: usize,
    pub logical_bound: usize,
    pub reason: &'static str,
}
fn gate(s: &mut Stats, size: usize) -> Result<()> {
    s.logical_bound = s.logical_bound.max(size);
    if s.logical_bound > 64 * 1024 * 1024 {
        return Err("copy memory bound".into());
    }
    Ok(())
}
fn bytes(n: usize) -> Result<Vec<u8>> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| "copy allocation failed")?;
    if v.capacity() > n {
        return Err("copy allocation capacity".into());
    }
    Ok(v)
}
pub fn u32_at(b: &[u8], i: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(i..i + 4)
            .ok_or("copy truncated u32")?
            .try_into()
            .map_err(|_| "copy u32")?,
    ) as usize)
}
fn u16_at(b: &[u8], i: usize) -> Result<usize> {
    Ok(u16::from_le_bytes(
        b.get(i..i + 2)
            .ok_or("copy truncated u16")?
            .try_into()
            .map_err(|_| "copy u16")?,
    ) as usize)
}
pub fn wire_crc(frame: &[u8]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..28]);
    digest.update(&frame[32..]);
    digest.finalize() as u32
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub freq: [u16; 256],
    pub cum: [u16; 256],
    pub support: usize,
}
impl Model {
    pub fn normalize(counts: &[u32; 256]) -> Result<Self> {
        let support = counts.iter().filter(|&&x| x != 0).count();
        let total: u64 = counts.iter().map(|&x| u64::from(x)).sum();
        let mut freq = [0u16; 256];
        let mut residues = [(0u64, 0usize); 256];
        let mut used = 0usize;
        let mut at = 0;
        if total != 0 {
            let remaining = 32768 - support;
            for (symbol, &count) in counts.iter().enumerate() {
                if count != 0 {
                    let product = u64::from(count) * remaining as u64;
                    freq[symbol] = (1 + product / total) as u16;
                    used += usize::from(freq[symbol]);
                    residues[at] = (product % total, symbol);
                    at += 1;
                }
            }
            residues[..support].sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
            let extra = 32768usize
                .checked_sub(used)
                .ok_or("copy normalization sum")?;
            if extra > support {
                return Err("copy normalization remainder".into());
            }
            for &(_, symbol) in &residues[..extra] {
                freq[symbol] += 1;
            }
        }
        Self::from_freq(freq)
    }
    pub fn from_freq(freq: [u16; 256]) -> Result<Self> {
        let support = freq.iter().filter(|&&x| x != 0).count();
        let mut cum = [0u16; 256];
        let mut sum = 0u32;
        for symbol in 0..256 {
            if sum > 32768 {
                return Err("copy CDF overflow".into());
            }
            cum[symbol] = sum as u16;
            sum += u32::from(freq[symbol]);
        }
        if sum != (if support == 0 { 0 } else { 32768 }) {
            return Err("copy CDF total".into());
        }
        Ok(Self { freq, cum, support })
    }
    fn write(&self, output: &mut Vec<u8>) {
        output.extend_from_slice(&(self.support as u16).to_le_bytes());
        for symbol in 0..256 {
            if self.freq[symbol] != 0 {
                output.push(symbol as u8);
                output.extend_from_slice(&self.freq[symbol].to_le_bytes());
            }
        }
    }
    fn parse(input: &[u8], at: &mut usize) -> Result<Self> {
        let support = u16_at(input, *at)?;
        *at += 2;
        if support > 256 {
            return Err("copy model support".into());
        }
        let mut freq = [0u16; 256];
        let mut previous = None;
        for _ in 0..support {
            let symbol = usize::from(*input.get(*at).ok_or("copy model truncated")?);
            let value = u16_at(input, *at + 1)?;
            *at += 3;
            if value == 0 || previous.is_some_and(|p| symbol <= p) {
                return Err("copy model order/frequency".into());
            }
            freq[symbol] = value as u16;
            previous = Some(symbol);
        }
        Self::from_freq(freq)
    }
    pub fn lut(&self) -> Result<Vec<u8>> {
        let mut v = bytes(32768)?;
        v.resize(32768, 0);
        for symbol in 0..256 {
            let begin = usize::from(self.cum[symbol]);
            let end = begin + usize::from(self.freq[symbol]);
            v[begin..end].fill(symbol as u8);
        }
        Ok(v)
    }
    pub fn put(&self, symbol: u8, encoder: &mut entropy::Encoder) -> Result<()> {
        // 再確保前に旧領域<=6MiBを保証する。allocatorの過剰capacityを想定する。
        if encoder.event_count() * 6 == encoder.capacity_bytes()
            && encoder.event_count() < entropy::MAX_EVENTS
            && encoder.capacity_bytes() > entropy::MAX_RETAINED_BYTES / 2
        {
            return Err("copy journal transient capacity".into());
        }
        let symbol = usize::from(symbol);
        encoder
            .interval(
                u32::from(self.cum[symbol]),
                u32::from(self.freq[symbol]),
                32768,
            )
            .map_err(str::to_owned)
    }
    fn get(&self, lut: &[u8], decoder: &mut entropy::Decoder<'_>) -> Result<u8> {
        if self.support == 0 {
            return Err("copy empty model read".into());
        }
        let symbol = lut[decoder.slot(32768).map_err(str::to_owned)? as usize];
        let index = usize::from(symbol);
        decoder
            .consume(
                u32::from(self.cum[index]),
                u32::from(self.freq[index]),
                32768,
            )
            .map_err(str::to_owned)?;
        Ok(symbol)
    }
}
pub fn serialize(models: &[Model; 2]) -> Result<Vec<u8>> {
    let mut out = bytes(MODEL_BOUND)?;
    for m in models {
        m.write(&mut out);
    }
    Ok(out)
}
pub fn parse_models(input: &[u8]) -> Result<[Model; 2]> {
    if !(4..=MODEL_BOUND).contains(&input.len()) {
        return Err("copy model extent".into());
    }
    let mut at = 0;
    let a = Model::parse(input, &mut at)?;
    let b = Model::parse(input, &mut at)?;
    if at != input.len() || a.support == 0 || b.freq[0] != 0 {
        return Err("copy model fields".into());
    }
    Ok([a, b])
}
pub fn scan(raw: &[u8], mut field: impl FnMut(usize, u8) -> Result<()>) -> Result<Stats> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let mut voter = voter::Voter::new()?;
    if voter.capacity() > voter::BOUND {
        return Err("copy voter capacity".into());
    }
    let mut s = Stats::default();
    let mut at = 0;
    while at < raw.len() {
        let begin = at;
        while at < raw.len() {
            let pred = at.checked_sub(voter.best()).map_or(0, |i| raw[i]);
            if pred != raw[at] {
                break;
            }
            voter.observe(raw[at])?;
            at += 1;
        }
        let mut count = at - begin;
        s.copied += count;
        s.tokens += 1;
        loop {
            let byte = (count & 127) as u8;
            count >>= 7;
            field(0, byte | if count != 0 { 128 } else { 0 })?;
            s.fields += 1;
            if count == 0 {
                break;
            }
        }
        if at < raw.len() {
            let pred = at.checked_sub(voter.best()).map_or(0, |i| raw[i]);
            let residual = raw[at] ^ pred;
            if residual == 0 {
                return Err("copy maximal grammar".into());
            }
            field(1, residual)?;
            s.fields += 1;
            s.literals += 1;
            voter.observe(raw[at])?;
            at += 1;
        }
    }
    s.width = voter.best();
    Ok(s)
}
pub fn pack(raw: &[u8], model: &[u8], payload: &[u8], method: u8) -> Result<Vec<u8>> {
    if raw.len() > MAX_RAW
        || model.len() > MODEL_BOUND
        || model.len() + payload.len() > raw.len() + 40
    {
        return Err("copy pack bound".into());
    }
    let mut frame = bytes(HEADER + model.len() + payload.len())?;
    frame.resize(HEADER, 0);
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[10] = method;
    frame[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    frame[16..20].copy_from_slice(&(model.len() as u32).to_le_bytes());
    frame[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[24..28].copy_from_slice(&baseline::crc32(raw).to_le_bytes());
    frame.extend_from_slice(model);
    frame.extend_from_slice(payload);
    let crc = wire_crc(&frame);
    frame[28..32].copy_from_slice(&crc.to_le_bytes());
    Ok(frame)
}
pub fn record(raw: &[u8], bound: usize, s: &mut Stats, retained: usize) -> Result<Vec<u8>> {
    let mut histogram = [[0u32; 256]; 2];
    let observed = scan(raw, |class, byte| {
        histogram[class][usize::from(byte)] += 1;
        Ok(())
    })?;
    let models = [
        Model::normalize(&histogram[0])?,
        Model::normalize(&histogram[1])?,
    ];
    let metadata = serialize(&models)?;
    s.metadata = metadata.len();
    if bound <= metadata.len() + 5 {
        return Err("range output limit".into());
    }
    let limit = bound - metadata.len() - 1;
    let phase = raw.len() + retained + FIXED + MODEL_BOUND + voter::BOUND;
    gate(s, phase + entropy::MAX_LIVE_BYTES + limit + HEADER + bound)?;
    let mut encoder = entropy::Encoder::with_limit(limit).map_err(str::to_owned)?;
    let encoded = scan(raw, |class, byte| models[class].put(byte, &mut encoder))?;
    if observed.tokens != encoded.tokens
        || observed.fields != encoded.fields
        || observed.width != encoded.width
    {
        return Err("copy scan drift".into());
    }
    s.fields = encoded.fields;
    s.tokens = encoded.tokens;
    s.copied = encoded.copied;
    s.literals = encoded.literals;
    s.width = encoded.width;
    s.journal = encoder.capacity_bytes();
    s.transient = encoder.transient_bytes();
    if encoder.event_count() != s.fields
        || s.journal > entropy::MAX_RETAINED_BYTES
        || s.transient > entropy::MAX_LIVE_BYTES - entropy::MAX_RETAINED_BYTES
    {
        return Err("copy journal bound".into());
    }
    let payload = encoder.finish().map_err(str::to_owned)?;
    s.method = 1;
    pack(raw, &metadata, &payload, 1)
}
pub fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let (legacy, old) = baseline::encode_hybrid(raw, true)?;
    let mut s = Stats::default();
    gate(&mut s, old.phase_capacity_bound + raw.len() + FIXED)?;
    if raw.len() > 5 {
        match record(raw, raw.len().min(legacy.len()), &mut s, legacy.capacity()) {
            Ok(frame) => return Ok((frame, s)),
            Err(e) if e == "range output limit" || e == "ANS journal limit" => {
                s.reason = "record output/journal limit"
            }
            Err(e) => return Err(e),
        }
    }
    if legacy.len() < raw.len() {
        s.method = 2;
        let frame = pack(raw, &[], &legacy, 2)?;
        Ok((frame, s))
    } else {
        s.method = 0;
        let frame = pack(raw, &[], raw, 0)?;
        Ok((frame, s))
    }
}
pub fn read_count(mut get: impl FnMut() -> Result<u8>, remaining: usize) -> Result<usize> {
    let mut count = 0usize;
    for index in 0..3 {
        let byte = get()?;
        let part = usize::from(byte & 127);
        count |= part << (index * 7);
        if byte & 128 == 0 {
            if index > 0 && part == 0 {
                return Err("copy noncanonical ULEB".into());
            }
            if count > remaining {
                return Err("copy run bound".into());
            }
            return Ok(count);
        }
    }
    Err("copy ULEB fourth byte".into())
}
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < HEADER
        || frame.len() > MAX_RAW + 80
        || &frame[..8] != MAGIC
        || u16_at(frame, 8)? != 1
    {
        return Err("copy header/version".into());
    }
    if frame[11] != 0 || frame[32..40] != [0; 8] {
        return Err("copy reserved".into());
    }
    let raw = u32_at(frame, 12)?;
    let model = u32_at(frame, 16)?;
    let payload = u32_at(frame, 20)?;
    if raw > MAX_RAW
        || model > MODEL_BOUND
        || payload > raw + 40
        || HEADER
            .checked_add(model)
            .and_then(|v| v.checked_add(payload))
            != Some(frame.len())
        || frame.len() > raw + 80
    {
        return Err("copy lengths".into());
    }
    if wire_crc(frame) as usize != u32_at(frame, 28)? {
        return Err("copy wire CRC".into());
    }
    let mut s = Stats {
        method: frame[10],
        metadata: model,
        ..Stats::default()
    };
    gate(
        &mut s,
        frame.len() + raw + FIXED + TABLE_BOUND + voter::BOUND,
    )?;
    let body = &frame[HEADER + model..];
    let output = match s.method {
        0 => {
            if model != 0 || payload != raw {
                return Err("copy stored fields".into());
            }
            let mut v = bytes(raw)?;
            v.extend_from_slice(body);
            v
        }
        2 => {
            if model != 0
                || payload < 40
                || body.get(..8) != Some(&b"KHC1BLK\0"[..])
                || u32_at(body, 12)? != raw
            {
                return Err("copy legacy fields".into());
            }
            let (v, old) = baseline::decode(body)?;
            gate(&mut s, old.phase_capacity_bound + frame.len() + FIXED)?;
            v
        }
        1 => {
            if payload < 5 || model + payload >= raw {
                return Err("copy coded fields".into());
            }
            let models = parse_models(&frame[HEADER..HEADER + model])?;
            let luts = [models[0].lut()?, models[1].lut()?];
            let mut decoder = entropy::Decoder::new(body).map_err(str::to_owned)?;
            let mut voter = voter::Voter::new()?;
            if voter.capacity() > voter::BOUND {
                return Err("copy voter capacity".into());
            }
            let mut out = bytes(raw)?;
            while out.len() < raw {
                let count = read_count(
                    || {
                        s.fields += 1;
                        models[0].get(&luts[0], &mut decoder)
                    },
                    raw - out.len(),
                )?;
                s.tokens += 1;
                s.copied += count;
                for _ in 0..count {
                    let pred = out.len().checked_sub(voter.best()).map_or(0, |i| out[i]);
                    out.push(pred);
                    voter.observe(pred)?;
                }
                if out.len() < raw {
                    let residual = models[1].get(&luts[1], &mut decoder)?;
                    if residual == 0 {
                        return Err("copy zero residual".into());
                    }
                    let pred = out.len().checked_sub(voter.best()).map_or(0, |i| out[i]);
                    let byte = pred ^ residual;
                    out.push(byte);
                    voter.observe(byte)?;
                    s.fields += 1;
                    s.literals += 1;
                }
            }
            s.width = voter.best();
            decoder.finish().map_err(str::to_owned)?;
            out
        }
        _ => return Err("copy unknown method".into()),
    };
    if output.len() != raw || baseline::crc32(&output) as usize != u32_at(frame, 24)? {
        return Err("copy raw CRC/length".into());
    }
    Ok((output, s))
}
