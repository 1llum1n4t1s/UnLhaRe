//! バイナリ向け独立LZ試作。既存形式ではなく、採用前の実験用CLI。
#[path = "../src/khc/block/multi_range.rs"]
#[expect(
    dead_code,
    reason = "共有range実装のallocated_bytesは製品の容量検査用で、この独立LZ probeでは使用しない"
)]
mod range;
use crc_fast::{CrcAlgorithm, Digest};
use serde_json::json;
use std::{fs::File, io::Read, time::Instant};
use unlhare::khc;
const MAX: usize = 1 << 20;
const MAGIC: &[u8; 8] = b"KHLZP1\0\0";
type Result<T> = std::result::Result<T, String>;
fn crc(bytes: &[u8]) -> u32 {
    let mut d = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    d.update(bytes);
    d.finalize() as u32
}
fn allocated<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n)
        .map_err(|_| "prototype allocation")?;
    out.resize(n, value);
    Ok(out)
}
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
        let slot = r.slot(32768)?;
        let value = slot.value();
        let bit = u32::from(value >= p);
        let (c, f) = if bit == 0 { (0, p) } else { (p, 32768 - p) };
        r.consume(slot, c, f, 32768)?;
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
fn header(raw: &[u8], payload: &[u8], context: u8, method: u8) -> Vec<u8> {
    let mut wire = Vec::with_capacity(32 + payload.len());
    wire.extend_from_slice(MAGIC);
    wire.extend_from_slice(&[1, method, context, 0]);
    wire.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    wire.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    wire.extend_from_slice(&crc(raw).to_le_bytes());
    wire.extend_from_slice(&crc(payload).to_le_bytes());
    wire.extend_from_slice(&crc(&wire).to_le_bytes());
    wire.extend_from_slice(payload);
    wire
}
fn encode(raw: &[u8], context: u8) -> Result<(Vec<u8>, usize)> {
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
        Ok(payload) if payload.len() < raw.len() => {
            Ok((header(raw, &payload, context, 1), comparisons))
        }
        Ok(_) => Ok((header(raw, raw, context, 0), comparisons)),
        Err(e) if e == "range output limit" => Ok((header(raw, raw, context, 0), comparisons)),
        Err(e) => Err(e),
    }
}
fn decode(wire: &[u8]) -> Result<Vec<u8>> {
    if wire.len() < 32 || wire.len() > MAX + 32 || &wire[..8] != MAGIC {
        return Err("frame magic/extent".into());
    }
    if wire[8] != 1 || wire[9] > 1 || wire[11] != 0 || !matches!(wire[10], 3 | 8) {
        return Err("frame revision/method/context/flags".into());
    }
    let get = |i| u32::from_le_bytes(wire[i..i + 4].try_into().unwrap()) as usize;
    let raw = get(12);
    let payload = get(16);
    if raw > MAX
        || payload > raw
        || wire.len() != 32 + payload
        || crc(&wire[..28]) != get(28) as u32
        || crc(&wire[32..]) != get(24) as u32
    {
        return Err("frame lengths/header/wire CRC".into());
    }
    let mut out = Vec::new();
    out.try_reserve_exact(raw)
        .map_err(|_| "decode allocation")?;
    if wire[9] == 0 {
        if payload != raw {
            return Err("stored extent".into());
        }
        out.extend_from_slice(&wire[32..]);
    } else {
        if payload >= raw {
            return Err("compressed extent".into());
        }
        let mut m = Models::new(wire[10])?;
        let mut r = range::Decoder::new(&wire[32..])?;
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
    }
    if crc(&out) != get(20) as u32 {
        return Err("plain CRC".into());
    }
    Ok(out)
}
fn measure(raw: &[u8]) -> Result<serde_json::Value> {
    let mut rows = Vec::new();
    for context in [0, 3, 8] {
        let t = Instant::now();
        let (wire, comparisons) = if context == 0 {
            (khc::compress_block(raw).map_err(|e| e.to_string())?, 0)
        } else {
            encode(raw, context)?
        };
        let enc = t.elapsed().as_nanos();
        let t = Instant::now();
        let out = if context == 0 {
            khc::decompress_block(&wire).map_err(|e| e.to_string())?
        } else {
            decode(&wire)?
        };
        let dec = t.elapsed().as_nanos();
        if out != raw {
            return Err("prototype byte mismatch".into());
        }
        rows.push(json!({"context":context,"bytes":wire.len(),"encode_ns":enc,"decode_ns":dec,"comparisons":comparisons,"byte_exact":true}));
    }
    Ok(json!({"raw_bytes":raw.len(),"raw_crc":crc(raw),"rows":rows}))
}
fn reseal(wire: &mut [u8]) {
    let wire_crc = crc(&wire[32..]);
    wire[24..28].copy_from_slice(&wire_crc.to_le_bytes());
    let h = crc(&wire[..28]);
    wire[28..32].copy_from_slice(&h.to_le_bytes());
}
fn self_check() -> Result<serde_json::Value> {
    let mut vectors = 0;
    let mut rejected = 0;
    for n in [
        0,
        1,
        2,
        3,
        4,
        255,
        256,
        257,
        4095,
        4096,
        4097,
        65536,
        MAX - 1,
        MAX,
    ] {
        for pattern in 0..4 {
            let mut raw = allocated(n, 0u8)?;
            let mut state = 0x6d2b79f5u32;
            for (i, b) in raw.iter_mut().enumerate() {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *b = match pattern {
                    0 => 7,
                    1 => i as u8,
                    2 => ((i * 173 + i * i * 13) & 255) as u8,
                    _ => state as u8,
                };
            }
            for context in [3, 8] {
                let (wire, _) = encode(&raw, context)?;
                if decode(&wire)? != raw {
                    return Err("self-check byte mismatch".into());
                }
            }
            vectors += 1;
        }
    }
    for context in [3, 8] {
        let raw = vec![7; 4096];
        let (wire, _) = encode(&raw, context)?;
        if wire[9] != 1 {
            return Err("compressed witness absent".into());
        }
        for offset in [0, 8, 9, 10, 11, 12, 16, 20, 24, 28, 32, wire.len() - 1] {
            let mut bad = wire.clone();
            bad[offset] ^= 128;
            if offset >= 8 && offset != 24 && offset != 28 {
                reseal(&mut bad);
            }
            if decode(&bad).is_ok() {
                return Err(format!("corruption accepted {offset}"));
            }
            rejected += 1;
        }
        for length in 0..wire.len() {
            if decode(&wire[..length]).is_ok() {
                return Err("truncation accepted".into());
            }
            rejected += 1;
        }
        let mut bad = wire.clone();
        bad.push(0);
        if decode(&bad).is_ok() {
            return Err("trailing accepted".into());
        }
        rejected += 1;
        // CRCを満たすが、初手から過去を参照する意味不正なtoken。
        let mut m = Models::new(context)?;
        let mut r = range::Encoder::with_limit(128)?;
        m.write(&mut r, m.base, 1)?;
        m.write(&mut r, m.base + 16, 1)?;
        m.number_write(&mut r, 1, 1)?;
        m.number_write(&mut r, 0, 1)?;
        let payload = r.finish()?;
        let bad = header(&[0; 32], &payload, context, 1);
        if decode(&bad).is_ok() {
            return Err("invalid past match accepted".into());
        }
        rejected += 1;
        if decode(&wire)? != raw {
            return Err("recovery".into());
        }
    }
    if encode(&vec![0; MAX + 1], 3).is_ok() {
        return Err("oversize accepted".into());
    }
    Ok(
        json!({"self_check":true,"vectors":vectors,"variants":2,"rejected":rejected,"oversize_rejected":true,"recovery":true}),
    )
}
fn execute() -> Result<()> {
    let arg = std::env::args()
        .nth(1)
        .ok_or("input path or --self-check")?;
    if arg == "--self-check" {
        println!("{}", self_check()?);
    } else {
        let mut raw = Vec::new();
        raw.try_reserve_exact(MAX + 1)
            .map_err(|_| "input allocation")?;
        File::open(arg)
            .map_err(|e| e.to_string())?
            .take((MAX + 1) as u64)
            .read_to_end(&mut raw)
            .map_err(|e| e.to_string())?;
        if raw.len() > MAX {
            return Err("input bound".into());
        }
        println!("{}", measure(&raw)?);
    }
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("khc_lz_probe: {e}");
        std::process::exit(1);
    }
}
