//! 現KHT1と同じ復号を、token loop外の6区間で計測する。
#![allow(dead_code)]
#[path = "../tree-span-compiled/codec.rs"]
mod current;
mod profile_codec;
use std::{path::Path, time::Instant};
type Result<T> = std::result::Result<T, String>;
fn num(bytes: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        bytes
            .get(at..at + 4)
            .ok_or("extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn median(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[sorted.len() / 2]
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("saved archive/corpus required".into());
    }
    let entries = unlhare::khc::list_archive(Path::new(&args[1]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if entries.len() != 11 || saved.len() != 466395 {
        return Err("fixed inputs".into());
    }
    let mut at = 32 + num(&saved, 20)?;
    let mut rows = Vec::new();
    let mut mdl = 0;
    for entry in entries {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry name/type".into());
        }
        let length = num(&saved, at)?;
        at += 4;
        let legacy = saved.get(at..at + length).ok_or("frame extent")?;
        at += length + 4;
        let raw =
            std::fs::read(Path::new(&args[2]).join(&entry.name)).map_err(|e| e.to_string())?;
        if unlhare::khc::decompress_block(legacy).map_err(|e| e.to_string())? != raw {
            return Err("native original whole bytes".into());
        }
        if legacy[10] != 1 {
            rows.push(serde_json::json!({"name":entry.name,"raw":raw.len(),"method":legacy[10],"profiled":false,"byte_exact":true}));
            continue;
        }
        mdl += 1;
        let (frame, encode) =
            current::encode_from_legacy(&raw, legacy)?.ok_or("KHT MDL candidate absent")?;
        if frame[10] != 1
            || encode.peak_capacity_bound
                + saved.capacity()
                + raw.capacity().saturating_sub(raw.len())
                + 1048576
                > current::RAM_LIMIT
        {
            return Err("preparation method/full fees".into());
        }
        let caller = saved.capacity() + raw.capacity() + frame.capacity() + 1048576;
        let (warm, ws) = profile_codec::decode(&frame)?;
        if warm != raw || ws.peak_capacity_bound + caller + warm.capacity() > current::RAM_LIMIT {
            return Err("warm profile bytes/full fees".into());
        }
        drop(warm);
        let (warm, ws) = current::decode(&frame)?;
        if warm != raw || ws.peak_capacity_bound + caller + warm.capacity() > current::RAM_LIMIT {
            return Err("warm current bytes/full fees".into());
        }
        drop(warm);
        let mut instrumented = Vec::new();
        let mut ordinary = Vec::new();
        let mut phases: Vec<Vec<f64>> = vec![Vec::new(); 6];
        let mut peak = 0;
        for round in 0..9 {
            // AB/BAを交互にし、各呼出の比較・dropは計時区間外。
            for order in 0..2 {
                let clock = Instant::now();
                if (round + order) % 2 == 0 {
                    let (out, s) = profile_codec::decode(&frame)?;
                    instrumented.push(clock.elapsed().as_secs_f64() * 1000.0);
                    if out != raw {
                        return Err("profile whole bytes".into());
                    }
                    let logical = s.peak_capacity_bound + caller + out.capacity();
                    if logical > current::RAM_LIMIT {
                        return Err("profile full fees".into());
                    }
                    peak = peak.max(logical);
                    for (i, &value) in s.profile_ms.iter().enumerate() {
                        if !value.is_finite() || value < 0.0 {
                            return Err("invalid phase".into());
                        }
                        phases[i].push(value);
                    }
                } else {
                    let (out, s) = current::decode(&frame)?;
                    ordinary.push(clock.elapsed().as_secs_f64() * 1000.0);
                    if out != raw {
                        return Err("current whole bytes".into());
                    }
                    let logical = s.peak_capacity_bound + caller + out.capacity();
                    if logical > current::RAM_LIMIT {
                        return Err("current full fees".into());
                    }
                    peak = peak.max(logical);
                }
            }
        }
        let ratio = median(&instrumented) / median(&ordinary);
        rows.push(serde_json::json!({"name":entry.name,"raw":raw.len(),"method":1,"profiled":true,"byte_exact":true,"frame":frame.len(),"profile_median_ms":median(&instrumented),"current_median_ms":median(&ordinary),"profile_ms":instrumented,"current_ms":ordinary,"phase_median_ms":phases.iter().map(|p|median(p)).collect::<Vec<_>>(),"phase_samples_ms":phases,"logical_peak":peak,"instrumentation_ratio":ratio,"instrumentation_within_10pct":(0.9..=1.1).contains(&ratio)}));
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) || mdl != 8 {
        return Err("tail/MDL coverage".into());
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"complete_inputs":11,"MDL_inputs":mdl,"phases":["header_CRC_alphabet_gate","model_parse","ANS_program_setup","reconstruct_entropy_active_last","forest_drop_inverse","final_rawCRC"],"warm":1,"rounds":9,"speed_evidence":false,"known_development":true,"native_changes":false,"raw_frame_disk":0})
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
