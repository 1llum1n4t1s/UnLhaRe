//! 因果的な12bit空間文脈の独立研究codec。既知技術の再実装で、新原理ではない。
use super::baseline;
#[path = "../../../src/khc/block/multi_range.rs"]
mod range;
pub const MAX_RAW: usize = 1 << 20;
pub const HEADER: usize = 40;
pub const MAGIC: &[u8; 8] = b"KRB1BLK\0";
type Result<T> = std::result::Result<T, String>;
const TABLE_BYTES: usize = 4096 * 2;
#[derive(Default, Debug)]
pub struct Stats {
    pub method: u8,
    pub stride: usize,
    pub comparisons: usize,
    pub positions: usize,
    pub selector_capacity: usize,
    pub bits: usize,
    pub phase: usize,
    pub legacy_frame: usize,
    pub reason: &'static str,
}
fn gate(s: &mut Stats, amount: usize) -> Result<()> {
    s.phase = s.phase.max(amount);
    if s.phase > 64 * 1024 * 1024 {
        return Err("record RAM bound".into());
    }
    Ok(())
}
fn bytes(n: usize) -> Result<Vec<u8>> {
    if n > MAX_RAW + 80 {
        return Err("record allocation extent".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| "record allocation")?;
    if v.capacity() > MAX_RAW + 80 {
        return Err("record allocation capacity".into());
    }
    Ok(v)
}
fn crc_parts(parts: &[&[u8]]) -> u32 {
    let mut crc = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    for part in parts {
        crc.update(part)
    }
    crc.finalize() as u32
}
pub fn reseal(v: &mut [u8]) -> Result<()> {
    if v.len() < HEADER {
        return Err("record short header".into());
    }
    let crc = crc_parts(&[&v[..32], &v[36..]]);
    v[32..36].copy_from_slice(&crc.to_le_bytes());
    Ok(())
}
fn u32_at(v: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        v.get(at..at + 4)
            .ok_or("record u32")?
            .try_into()
            .map_err(|_| "record u32 field")?,
    ) as usize)
}
fn u16_at(v: &[u8], at: usize) -> Result<usize> {
    Ok(u16::from_le_bytes(
        v.get(at..at + 2)
            .ok_or("record u16")?
            .try_into()
            .map_err(|_| "record u16 field")?,
    ) as usize)
}
fn pack(raw: &[u8], body: &[u8], method: u8, stride: usize, s: &mut Stats) -> Result<Vec<u8>> {
    let total = HEADER.checked_add(body.len()).ok_or("record total")?;
    if total > raw.len() + 80 || total > MAX_RAW + 80 {
        return Err("record total bound".into());
    }
    let mut v = bytes(total)?;
    v.resize(HEADER, 0);
    v[..8].copy_from_slice(MAGIC);
    v[8..10].copy_from_slice(&1u16.to_le_bytes());
    v[10] = method;
    v[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    v[16..20].copy_from_slice(&(body.len() as u32).to_le_bytes());
    if method == 1 {
        v[20..22].copy_from_slice(&(stride as u16).to_le_bytes());
        v[22..24].copy_from_slice(&1u16.to_le_bytes());
        v[24..26].copy_from_slice(&1u16.to_le_bytes());
    }
    v[28..32].copy_from_slice(&baseline::crc32(raw).to_le_bytes());
    v.extend_from_slice(body);
    reseal(&mut v)?;
    s.method = method;
    gate(
        s,
        raw.len() + body.len() + v.capacity() + TABLE_BYTES + s.selector_capacity,
    )?;
    Ok(v)
}
pub fn select_stride(raw: &[u8]) -> Result<(usize, usize, usize, usize)> {
    if raw.len() > MAX_RAW {
        return Err("record input bound".into());
    }
    let n = raw.len().min(16384);
    let max = n.saturating_sub(1).min(1024);
    if max == 0 {
        return Ok((1, 0, 0, 0));
    }
    let mut positions = Vec::<u16>::new();
    positions
        .try_reserve_exact(n - max)
        .map_err(|_| "record selector allocation")?;
    if positions.capacity() * 2 > 32768 {
        return Err("record selector capacity".into());
    }
    for (i, &byte) in raw.iter().enumerate().take(n).skip(max) {
        if byte != 0 && byte != 255 {
            positions.push(i as u16)
        }
    }
    let mut best = 1;
    let mut cost = u64::MAX;
    for lag in 1..=max {
        let mut sum = 0u64;
        for &i in &positions {
            sum += u64::from((raw[usize::from(i)] ^ raw[usize::from(i) - lag]).count_ones())
        }
        if sum < cost {
            cost = sum;
            best = lag
        }
    }
    Ok((
        best,
        max * positions.len(),
        positions.len(),
        positions.capacity() * 2,
    ))
}
/// 窓の全source byteは現在byteより前。row外の近傍は0。
pub fn windows(raw: &[u8], i: usize, stride: usize) -> Result<(u32, u32)> {
    if !(1..=1024).contains(&stride) || i >= raw.len() {
        return Err("record window extent".into());
    }
    let col = i % stride;
    let mut first = 0u32;
    let mut second = 0u32;
    if i >= stride {
        let up = i - stride;
        let left = if col > 0 { raw[up - 1] } else { 0 };
        let right = if col + 1 < stride { raw[up + 1] } else { 0 };
        first = (u32::from(left) << 16) | (u32::from(raw[up]) << 8) | u32::from(right);
    }
    if i >= stride * 2 {
        let up = i - stride * 2;
        let right = if col + 1 < stride { raw[up + 1] } else { 0 };
        second = (u32::from(raw[up]) << 8) | u32::from(right);
    }
    Ok((first, second))
}
pub fn context(left: usize, first: u32, second: u32, shift: usize) -> usize {
    (left & 15)
        | (((first >> (shift + 5)) as usize & 63) << 4)
        | (((second >> (shift + 7)) as usize & 3) << 10)
}
pub fn update(p: u16, one: bool) -> u16 {
    let value = u32::from(p);
    let next = if one {
        value - value.div_ceil(32)
    } else {
        value + (32768 - value).div_ceil(32)
    };
    next.clamp(1, 32767) as u16
}
fn payload(raw: &[u8], stride: usize, limit: usize, s: &mut Stats) -> Result<Vec<u8>> {
    let mut table = [16384u16; 4096];
    let mut coder = range::Encoder::with_limit(limit).map_err(str::to_owned)?;
    let mut left = 0;
    for (i, &byte) in raw.iter().enumerate() {
        if i % stride == 0 {
            left = 0
        }
        let (first, second) = windows(raw, i, stride)?;
        for shift in (0..8).rev() {
            let key = context(left, first, second, shift);
            let p = u32::from(table[key]);
            let one = byte & (1 << shift) != 0;
            let (c, f) = if one { (p, 32768 - p) } else { (0, p) };
            coder.interval(c, f, 32768).map_err(str::to_owned)?;
            table[key] = update(table[key], one);
            left = ((left << 1) | usize::from(one)) & 15;
            s.bits += 1;
        }
    }
    coder.finish().map_err(str::to_owned)
}
pub fn encode_record(raw: &[u8], stride: usize) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_RAW || !(1..=1024).contains(&stride) {
        return Err("record input/stride bound".into());
    }
    let mut s = Stats {
        stride,
        ..Stats::default()
    };
    gate(&mut s, 3 * raw.len() + TABLE_BYTES + HEADER)?;
    if raw.len() <= 5 {
        s.reason = "tiny";
        return Ok((pack(raw, raw, 0, 0, &mut s)?, s));
    }
    match payload(raw, stride, raw.len() - 1, &mut s) {
        Ok(p) => Ok((pack(raw, &p, 1, stride, &mut s)?, s)),
        Err(e) if e == "range output limit" => {
            s.reason = "record no benefit";
            Ok((pack(raw, raw, 0, 0, &mut s)?, s))
        }
        Err(e) => Err(e),
    }
}
pub fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_RAW {
        return Err("record input bound".into());
    }
    let (legacy, old) = baseline::encode_hybrid(raw, true)?;
    let (stride, comparisons, positions, selector_capacity) = select_stride(raw)?;
    let mut s = Stats {
        stride,
        comparisons,
        positions,
        selector_capacity,
        legacy_frame: legacy.len(),
        ..Stats::default()
    };
    // 旧model等は既に解放済みだが、旧peakに新temp全量を保守的に加算する。
    gate(
        &mut s,
        old.phase_capacity_bound + 2 * raw.len() + TABLE_BYTES + selector_capacity + 80,
    )?;
    if raw.len() > 5 {
        let limit = raw.len().min(legacy.len()) - 1;
        match payload(raw, stride, limit, &mut s) {
            Ok(p) => return Ok((pack(raw, &p, 1, stride, &mut s)?, s)),
            Err(e) if e == "range output limit" => {}
            Err(e) => return Err(e),
        }
    }
    if legacy.len() < raw.len() {
        s.reason = "legacy smaller";
        Ok((pack(raw, &legacy, 2, 0, &mut s)?, s))
    } else {
        s.reason = "stored smaller";
        Ok((pack(raw, raw, 0, 0, &mut s)?, s))
    }
}
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < HEADER
        || frame.len() > MAX_RAW + 80
        || &frame[..8] != MAGIC
        || u16_at(frame, 8)? != 1
    {
        return Err("record header/version".into());
    }
    if frame[11] != 0 || frame[26..28] != [0; 2] || frame[36..40] != [0; 4] {
        return Err("record reserved".into());
    }
    let raw = u32_at(frame, 12)?;
    let length = u32_at(frame, 16)?;
    let stride = u16_at(frame, 20)?;
    let cid = u16_at(frame, 22)?;
    let sid = u16_at(frame, 24)?;
    if raw > MAX_RAW || length > raw + 40 || HEADER.checked_add(length) != Some(frame.len()) {
        return Err("record lengths".into());
    }
    if crc_parts(&[&frame[..32], &frame[36..]]) as usize != u32_at(frame, 32)? {
        return Err("record wire CRC".into());
    }
    let body = &frame[HEADER..];
    let mut s = Stats {
        method: frame[10],
        stride,
        ..Stats::default()
    };
    gate(&mut s, frame.len() + raw + TABLE_BYTES)?;
    let plain = match frame[10] {
        0 => {
            if stride != 0 || cid != 0 || sid != 0 || length != raw {
                return Err("record stored fields".into());
            }
            let mut v = bytes(raw)?;
            v.extend_from_slice(body);
            v
        }
        1 => {
            if !(1..=1024).contains(&stride) || cid != 1 || sid != 1 || length < 5 || length >= raw
            {
                return Err("record coded fields".into());
            }
            let mut table = [16384u16; 4096];
            let mut dec = range::Decoder::new(body).map_err(str::to_owned)?;
            let mut v = bytes(raw)?;
            v.resize(raw, 0);
            let mut left = 0;
            for i in 0..raw {
                if i % stride == 0 {
                    left = 0
                }
                let (first, second) = windows(&v, i, stride)?;
                for shift in (0..8).rev() {
                    let key = context(left, first, second, shift);
                    let p = u32::from(table[key]);
                    let one = dec.slot(32768).map_err(str::to_owned)? >= p;
                    let (c, f) = if one { (p, 32768 - p) } else { (0, p) };
                    dec.consume(c, f, 32768).map_err(str::to_owned)?;
                    if one {
                        v[i] |= 1 << shift
                    }
                    table[key] = update(table[key], one);
                    left = ((left << 1) | usize::from(one)) & 15;
                    s.bits += 1;
                }
            }
            dec.finish().map_err(str::to_owned)?;
            v
        }
        2 => {
            if stride != 0
                || cid != 0
                || sid != 0
                || length < 40
                || body.get(..8) != Some(&b"KHC1BLK\0"[..])
            {
                return Err("record legacy fields".into());
            }
            let (v, old) = baseline::decode(body)?;
            gate(&mut s, old.phase_capacity_bound + frame.len() + TABLE_BYTES)?;
            v
        }
        _ => return Err("record unknown method".into()),
    };
    if plain.len() != raw || baseline::crc32(&plain) as usize != u32_at(frame, 28)? {
        return Err("record raw CRC/length".into());
    }
    Ok((plain, s))
}
