//! 既存filterの独立prototype。製品形式は変更せず実際のenvelopeから復元する。
use crc_fast::{CrcAlgorithm, Digest};
use serde_json::json;
use std::{fs::File, io::Read, time::Instant};
use unlhare::khc::{compress_block, decompress_block};
const MAX: usize = 1 << 20;
const MAGIC: &[u8; 8] = b"KHFXP1\0\0";
fn crc(bytes: &[u8]) -> u32 {
    let mut digest = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    digest.update(bytes);
    digest.finalize() as u32
}
fn transform(bytes: &[u8], id: u8, inverse: bool) -> Vec<u8> {
    let mut out = bytes.to_vec();
    if inverse && matches!(id, 1 | 4) {
        let mut at = 0;
        for lane in 0..8 {
            for i in (lane..bytes.len()).step_by(8) {
                out[i] = bytes[at];
                at += 1;
            }
        }
    }
    if matches!(id, 2..=4) {
        let lag = if id == 2 { 1 } else { 8 };
        if inverse {
            for i in lag..out.len() {
                out[i] = out[i].wrapping_add(out[i - lag]);
            }
        } else {
            for i in (lag..out.len()).rev() {
                out[i] = out[i].wrapping_sub(out[i - lag]);
            }
        }
    }
    if !inverse && matches!(id, 1 | 4) {
        let source = out;
        out = Vec::with_capacity(bytes.len());
        for lane in 0..8 {
            for i in (lane..bytes.len()).step_by(8) {
                out.push(source[i]);
            }
        }
    }
    out
}
fn encode(raw: &[u8], id: u8) -> Result<Vec<u8>, String> {
    if raw.len() > MAX || id > 4 {
        return Err("prototype input/id bound".into());
    }
    let transformed = transform(raw, id, false);
    let frame = compress_block(&transformed).map_err(|e| e.to_string())?;
    if id == 0 {
        return Ok(frame);
    }
    let mut out = Vec::with_capacity(frame.len() + 20);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&[id, if id == 2 { 1 } else { 8 }, 0, 0]);
    out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    out.extend_from_slice(&crc(raw).to_le_bytes());
    out.extend_from_slice(&frame);
    Ok(out)
}
fn decode(wire: &[u8], enveloped: bool) -> Result<Vec<u8>, String> {
    if !enveloped {
        return decompress_block(wire).map_err(|e| e.to_string());
    }
    if wire.len() < 60 || wire.len() > MAX + 60 || &wire[..8] != MAGIC {
        return Err("prototype magic/extent".into());
    }
    let id = wire[8];
    if !(1..=4).contains(&id) || wire[9] != if id == 2 { 1 } else { 8 } || wire[10..12] != [0, 0] {
        return Err("prototype id/stride/reserved".into());
    }
    let raw = u32::from_le_bytes(wire[12..16].try_into().unwrap()) as usize;
    if raw > MAX {
        return Err("prototype raw bound".into());
    }
    let transformed = decompress_block(&wire[20..]).map_err(|e| e.to_string())?;
    if transformed.len() != raw {
        return Err("prototype raw length".into());
    }
    let plain = transform(&transformed, id, true);
    if crc(&plain) != u32::from_le_bytes(wire[16..20].try_into().unwrap()) {
        return Err("prototype plain CRC".into());
    }
    Ok(plain)
}
fn measure(raw: &[u8]) -> Result<serde_json::Value, String> {
    let mut rows = Vec::new();
    for id in 0..=4 {
        let t = Instant::now();
        let wire = encode(raw, id)?;
        let encode_ns = t.elapsed().as_nanos();
        let t = Instant::now();
        let plain = decode(&wire, id != 0)?;
        let decode_ns = t.elapsed().as_nanos();
        if plain != raw {
            return Err("prototype byte mismatch".into());
        }
        rows.push(json!({"id":id,"bytes":wire.len(),"encode_ns":encode_ns,"decode_ns":decode_ns,"byte_exact":true}));
    }
    Ok(
        json!({"raw_bytes":raw.len(),"raw_crc":crc(raw),"rows":rows,"timing":"one-pass in-process, NOT comparable to process benchmark"}),
    )
}
fn execute() -> Result<(), String> {
    let arg = std::env::args()
        .nth(1)
        .ok_or("input path or --self-check")?;
    if arg == "--self-check" {
        let mut vectors = 0;
        let mut rejected = 0;
        for len in [0, 1, 7, 8, 9, 15, 16, 17, 255, 256, 257, 760, 4096] {
            for pattern in 0..3 {
                let raw: Vec<u8> = (0..len)
                    .map(|i| match pattern {
                        0 => 7,
                        1 => i as u8,
                        _ => ((i * 173 + i * i * 13) & 255) as u8,
                    })
                    .collect();
                measure(&raw)?;
                vectors += 1;
                let wire = encode(&raw, 4)?;
                for offset in [0, 8, 9, 10, 12, 16, 20] {
                    let mut bad = wire.clone();
                    bad[offset] ^= 128;
                    if decode(&bad, true).is_ok() {
                        return Err("prototype corruption accepted".into());
                    }
                    rejected += 1;
                }
                if decode(&wire[..wire.len() - 1], true).is_ok() || decode(&wire, true)? != raw {
                    return Err("prototype truncation/recovery".into());
                }
                rejected += 1;
            }
        }
        println!(
            "{}",
            json!({"self_check":true,"vectors":vectors,"rejected":rejected,"recovery":true})
        );
    } else {
        let mut raw = Vec::new();
        raw.try_reserve_exact(MAX + 1)
            .map_err(|_| "prototype input allocation")?;
        File::open(arg)
            .map_err(|e| e.to_string())?
            .take((MAX + 1) as u64)
            .read_to_end(&mut raw)
            .map_err(|e| e.to_string())?;
        if raw.len() > MAX {
            return Err("prototype input bound".into());
        }
        println!("{}", measure(&raw)?);
    }
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("khc_filter_probe: {e}");
        std::process::exit(1);
    }
}
