//! private native wire互換: packed-word CDF診断。encoder/defaultは元実装を参照する。
#![allow(dead_code)]
#[path = "../../../src/lhc/block/mod.rs"]
mod original;
pub(crate) use original::{HEADER, MAGIC, MAX_INPUT, SCRATCH_BOUND, Stats, crc32, encode_hybrid, revision_method_valid};
pub(crate) type Result<T> = std::result::Result<T, String>;
#[path = "../../../src/lhc/block/bundle.rs"]
mod bundle;
#[path = "../../../src/lhc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/lhc/block/codebook.rs"]
mod codebook;
#[path = "../../../src/lhc/block/counts.rs"]
mod counts;
#[path = "../../../src/lhc/block/frontend.rs"]
mod frontend;
#[path = "../../../src/lhc/block/grammar.rs"]
mod grammar;
#[path = "../../../src/lhc/block/histogram.rs"]
mod histogram;
#[path = "../../../src/lhc/block/lz.rs"]
mod lz;
#[path = "../../../src/lhc/block/model.rs"]
mod model;
#[path = "../../../src/lhc/block/multi_range.rs"]
mod multi_range;
#[path = "../../../src/lhc/block/packed.rs"]
mod packed;
#[path = "packet.rs"]
mod packet;
#[path = "../../../src/lhc/block/paid_model.rs"]
mod paid_model;
#[path = "../../../src/lhc/block/program.rs"]
mod program;
const MODEL_RESERVE: usize = 16 << 20;
const MODEL_AUX: usize = 262144;
pub(crate) const DECODER_RESERVE: usize = 32 << 20;
fn crc_parts(parts: &[&[u8]]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    for p in parts {
        digest.update(p);
    }
    digest.finalize() as u32
}
fn get32(b: &[u8], i: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(b.get(i..i + 4).ok_or("header truncated")?.try_into().map_err(|_| "header u32")?) as usize)
}
fn allocate<T: Clone>(n: usize, v: T) -> Result<Vec<T>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| "frame allocation")?;
    if out.capacity() != n {
        return Err("actual allocation capacity".into());
    }
    out.resize(n, v);
    Ok(out)
}
fn gate(s: &mut Stats, bound: usize) -> Result<()> {
    s.phase_capacity_bound = s.phase_capacity_bound.max(bound);
    s.scratch_capacity_bound = SCRATCH_BOUND;
    if s.phase_capacity_bound > DECODER_RESERVE {
        return Err("codec RAM bound".into());
    }
    Ok(())
}
fn token(
    dec: &mut multi_range::Decoder<'_>,
    forest: &packet::DecodeForest,
    program: &program::Program,
    c: usize,
    limit: usize,
    histories: &mut [u16; 6],
    s: &mut Stats,
) -> Result<usize> {
    let mut n = 0;
    // private programのforward edge/depth8証明、remaining進捗により有限。
    loop {
        let (instruction, k) = program.node(c, n, limit)?;
        let class = c * 3 + instruction.class as usize;
        let child = if k == 1 {
            s.implicit += 1;
            0
        } else {
            let cdf = forest.cdf(c, n, k, histories[class])?;
            let slot = dec.slot(32768).map_err(str::to_owned)?;
            let (child, cumulative, frequency) = cdf.choose(slot)?;
            dec.consume(cumulative, frequency, 32768).map_err(str::to_owned)?;
            child
        };
        histories[class] = ((histories[class] << 2) | child as u16) & 1023;
        s.branches += 1;
        let (lo, next) = instruction.step(child)?;
        if let Some(next) = next {
            n = next;
        } else {
            if lo >= limit {
                return Err("decoded token limit".into());
            }
            return Ok(lo);
        }
    }
}
fn escape_read(dec: &mut multi_range::Decoder<'_>, remaining: usize, s: &mut Stats) -> Result<usize> {
    let mut value = 0usize;
    for i in 0..3 {
        let b = dec.slot(256).map_err(str::to_owned)? as u8;
        dec.consume(u32::from(b), 1, 256).map_err(str::to_owned)?;
        s.escapes += 1;
        let part = usize::from(b & 127);
        value = value
            .checked_add(part.checked_shl((7 * i) as u32).ok_or("escape overflow")?)
            .ok_or("escape overflow")?;
        if b & 128 == 0 {
            if i != 0 && part == 0 {
                return Err("noncanonical escape".into());
            }
            let length = value.checked_add(256).ok_or("escape overflow")?;
            if length > remaining {
                return Err("escape remaining".into());
            }
            return Ok(length);
        }
    }
    Err("escape length overflow".into())
}
pub(crate) fn decode(bytes: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if bytes.len() < HEADER {
        return Err("header truncated".into());
    }
    if &bytes[..8] != MAGIC {
        return Err("frame magic".into());
    }
    if !matches!(u16::from_le_bytes([bytes[8], bytes[9]]), 1 | 2) {
        return Err("frame revision".into());
    }
    let method = bytes[10];
    if !revision_method_valid(bytes) {
        return Err("frame method".into());
    }
    if bytes[11] != 0 || bytes[30..32] != [0, 0] {
        return Err("frame flags/reserved".into());
    }
    let raw = get32(bytes, 12)?;
    if raw > MAX_INPUT {
        return Err("raw exceeds block limit".into());
    }
    let primary = get32(bytes, 16)?;
    let model_len = get32(bytes, 20)?;
    let payload_len = get32(bytes, 24)?;
    let alphabet_len = u16::from_le_bytes(bytes[28..30].try_into().map_err(|_| "alphabet length")?) as usize;
    let body = alphabet_len
        .checked_mul(2)
        .and_then(|n| n.checked_add(model_len))
        .and_then(|n| n.checked_add(payload_len))
        .ok_or("frame length overflow")?;
    if HEADER.checked_add(body).ok_or("frame length overflow")? != bytes.len() {
        return Err("frame exact extent".into());
    }
    if (method == 0 && (primary != 0 || model_len != 0 || alphabet_len != 0 || payload_len != raw))
        || (method >= 2 && (primary != 0 || model_len != 0 || alphabet_len != 0 || payload_len < 5 || payload_len >= raw))
        || (method == 1
            && (body >= raw
                || primary > raw
                || !(2..=257).contains(&alphabet_len)
                || !(241..=packet::MAX_BUNDLE_BYTES).contains(&model_len)
                || payload_len < 5))
    {
        return Err("frame canonical fields".into());
    }
    if crc_parts(&[&bytes[..36], &bytes[40..]]) != get32(bytes, 36)? as u32 {
        return Err("wire CRC".into());
    }
    let mut s = Stats {
        method,
        raw,
        frame: bytes.len(),
        alphabet: alphabet_len * 2,
        metadata: model_len,
        payload: payload_len,
        ..Stats::default()
    };
    // 全familyのallocation前に固定library予約を検査する。外部caller分はdriver側で加算。
    gate(&mut s, DECODER_RESERVE)?;
    if method == 0 {
        let mut plain = allocate(raw, 0u8)?;
        plain.copy_from_slice(&bytes[40..]);
        if crc32(&plain) != get32(bytes, 32)? as u32 {
            return Err("plain CRC".into());
        }
        s.output_capacity = plain.capacity();
        gate(&mut s, bytes.len() + plain.capacity() + SCRATCH_BOUND)?;
        return Ok((plain, s));
    }
    if method >= 2 {
        gate(&mut s, 12 * MAX_INPUT + bytes.len())?;
        let plain = lz::decode(&bytes[40..], raw, if method == 2 { 3 } else { 8 })?;
        if crc32(&plain) != get32(bytes, 32)? as u32 {
            return Err("plain CRC".into());
        }
        s.output_capacity = plain.capacity();
        return Ok((plain, s));
    }
    let mut alphabet = [0u16; 257];
    let mut active = [0u16; 257];
    let mut seen = [false; 257];
    for i in 0..alphabet_len {
        let off = 40 + i * 2;
        let v = u16::from_le_bytes(bytes[off..off + 2].try_into().map_err(|_| "alphabet field")?);
        if v > 256 || seen[v as usize] {
            return Err("alphabet range/duplicate".into());
        }
        seen[v as usize] = true;
        alphabet[i] = v;
        active[i] = v;
    }
    if !seen[0] {
        return Err("alphabet sentinel absent".into());
    }
    let model_start = 40 + alphabet_len * 2;
    let forest = packet::Forest::parse(&bytes[model_start..model_start + model_len])?.into_decode()?;
    let model_peak = forest
        .capacity_bytes()
        .checked_add(forest.parse_transient())
        .and_then(|n| n.checked_add(MODEL_AUX))
        .ok_or("model phase overflow")?;
    if model_peak > MODEL_RESERVE {
        return Err("model phase reservation".into());
    }
    let before_program = bytes.len()
        + forest.capacity_bytes()
        + forest.parse_transient()
        + program::RETAINED_BOUND
        + program::TRANSIENT_BOUND
        + (raw + 1) * 2
        + SCRATCH_BOUND
        + 4 * 1024 * 1024;
    gate(&mut s, before_program)?;
    let program = program::Program::new();
    s.forest_capacity = forest.capacity_bytes() + program.capacity_bytes();
    s.parse_transient = forest.parse_transient() + MODEL_AUX + program::TRANSIENT_BOUND;
    let mut dec = multi_range::Decoder::new(&bytes[model_start + model_len..]).map_err(str::to_owned)?;
    // 固定Treeはprogramへコンパイル済み。
    let mut histories = [0u16; 6];
    let mut remaining = raw + 1;
    let mut active_len = alphabet_len;
    let mut last = allocate(raw + 1, 0u16)?;
    let mut written = 0;
    let mut encountered = [false; 257];
    let mut encounter_count = 0;
    while remaining != 0 {
        if active_len == 0 || s.runs > raw {
            return Err("active/runs terminal".into());
        }
        let symbol = active[0];
        if !encountered[symbol as usize] {
            if alphabet[encounter_count] != symbol {
                return Err("alphabet first occurrence order".into());
            }
            encountered[symbol as usize] = true;
            encounter_count += 1;
        }
        let rank = token(&mut dec, &forest, program, 0, active_len, &mut histories, &mut s)?;
        let length_token = token(&mut dec, &forest, program, 1, remaining.min(256), &mut histories, &mut s)?;
        let length = if length_token == 255 {
            escape_read(&mut dec, remaining, &mut s)?
        } else {
            length_token + 1
        };
        if length > remaining || (symbol == 0 && length != 1) {
            return Err("run/sentinel length".into());
        }
        last[written..written + length].fill(symbol);
        written += length;
        remaining -= length;
        s.runs += 1;
        active.copy_within(1..active_len, 0);
        active_len -= 1;
        if rank != 0 {
            if rank > active_len {
                return Err("active insertion rank".into());
            }
            active.copy_within(rank..active_len, rank + 1);
            active[rank] = symbol;
            active_len += 1;
        }
    }
    if active_len != 0 || encounter_count != alphabet_len {
        return Err("active/alphabet terminal".into());
    }
    dec.finish().map_err(str::to_owned)?;
    drop(forest);
    let inverse = packed::inverse(&last, primary, &alphabet[..alphabet_len])?;
    if inverse.route != "packed23" || inverse.plain.len() != raw {
        return Err("inverse route/length".into());
    }
    s.inverse_capacity = inverse.scratch_capacity_words * 4;
    s.output_capacity = inverse.result_capacity;
    let decode_bound =
        bytes.len() + s.forest_capacity + s.parse_transient + last.capacity() * 2 + s.inverse_capacity + s.output_capacity + SCRATCH_BOUND + 1048576;
    gate(&mut s, decode_bound)?;
    let plain = inverse.plain;
    if crc32(&plain) != get32(bytes, 32)? as u32 {
        return Err("plain CRC".into());
    }
    Ok((plain, s))
}

pub(crate) fn diagnostic_choose(row: [u16; 4], k: usize, slot: u32) -> Result<(usize, u32, u32)> {
    packet::diagnostic_choose(row, k, slot)
}

pub(crate) fn finite_metadata(frame: &[u8]) -> Result<(usize, usize)> {
    if frame.len() < 40 || &frame[..8] != MAGIC || frame[10] != 1 {
        return Err("finite metadata input family".into());
    }
    let at = 40 + usize::from(u16::from_le_bytes([frame[28], frame[29]])) * 2;
    let model_len = get32(frame, 20)?;
    let metadata = frame
        .get(at..at.checked_add(model_len).ok_or("finite metadata extent")?)
        .ok_or("finite metadata extent")?;
    // raw oracle pool + 第二parse/conversionを含めても32MiB予約内。callerは外部bufferを先に課金。
    let raw = packet::Forest::parse(metadata)?;
    let compiled = packet::Forest::parse(metadata)?.into_decode()?;
    let peak = raw
        .capacity_bytes()
        .checked_add(compiled.capacity_bytes())
        .and_then(|n| n.checked_add(compiled.parse_transient()))
        .and_then(|n| n.checked_add(2 * MODEL_AUX))
        .ok_or("finite model capacity")?;
    if peak > DECODER_RESERVE {
        return Err("finite model capacity".into());
    }
    let (mut rows, mut checks) = (0usize, 0usize);
    for c in 0..2 {
        for node in 0..142 {
            for k in 2..=4 {
                for history in 0..1024u16 {
                    let freq = raw.lookup(c, node, k, history)?;
                    let cdf = compiled.cdf(c, node, k, history)?;
                    let mut cumulative = 0u32;
                    for (child, &f) in freq[..k].iter().enumerate() {
                        let frequency = u32::from(f);
                        if frequency < 2 {
                            return Err("finite frequency support".into());
                        }
                        for slot in [cumulative, cumulative + frequency - 1] {
                            if cdf.choose(slot)? != (child, cumulative, frequency) {
                                return Err("parsed raw/packed CDF differs".into());
                            }
                            checks += 1;
                        }
                        cumulative += frequency;
                    }
                    if cumulative != 32768 || cdf.choose(32768).is_ok() {
                        return Err("parsed CDF total/invalid slot".into());
                    }
                    rows += 1;
                }
            }
        }
    }
    Ok((rows, checks))
}
