//! 既存MDLの工程費用だけを測る。採用や性能優位の証拠ではない。
#![allow(dead_code)]
#[path = "block_profile.rs"]
mod block;
use std::{path::Path, time::Instant};
type Result<T> = std::result::Result<T, String>;
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn median(v: &[f64]) -> f64 {
    let mut x = v.to_vec();
    x.sort_by(f64::total_cmp);
    x[x.len() / 2]
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus required".into());
    }
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if entries.len() != 11 || saved.len() != 466395 {
        return Err("saved corpus coverage".into());
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
        let len = num(&saved, at)?;
        at += 4;
        let frame = saved.get(at..at + len).ok_or("frame")?;
        at += len + 4;
        let raw =
            std::fs::read(Path::new(&args[2]).join(&entry.name)).map_err(|e| e.to_string())?;
        if unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
            return Err("public full bytes".into());
        }
        if frame[10] != 1 {
            rows.push(serde_json::json!({"name":entry.name,"raw":raw.len(),"method":frame[10],"profiled":false,"byte_exact":true}));
            continue;
        }
        mdl += 1;
        let (warm, _) = block::decode(frame)?;
        if warm != raw {
            return Err("profile warm bytes".into());
        }
        drop(warm);
        let mut profile_ms = Vec::new();
        let mut public_ms = Vec::new();
        let mut phases: Vec<Vec<f64>> = vec![Vec::new(); 6];
        let mut logical = 0;
        let mut branches = 0;
        let mut implicit = 0;
        let mut runs = 0;
        for _ in 0..9 {
            let clock = Instant::now();
            let (out, s) = block::decode(frame)?;
            profile_ms.push(clock.elapsed().as_secs_f64() * 1000.0);
            if out != raw {
                return Err("profile whole bytes".into());
            }
            logical = logical.max(
                s.phase_capacity_bound
                    + saved.capacity()
                    + raw.capacity()
                    + out.capacity()
                    + 1048576,
            );
            if logical > 64 * 1048576 {
                return Err("profile caller full fees".into());
            }
            for (i, value) in s.profile_ms.iter().enumerate() {
                phases[i].push(*value);
            }
            let clock = Instant::now();
            let native = unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())?;
            public_ms.push(clock.elapsed().as_secs_f64() * 1000.0);
            if native != raw {
                return Err("paired public bytes".into());
            }
            branches = s.branches;
            implicit = s.implicit;
            runs = s.runs;
        }
        rows.push(serde_json::json!({"name":entry.name,"raw":raw.len(),"method":1,"profiled":true,"byte_exact":true,"private_median_ms":median(&profile_ms),"public_median_ms":median(&public_ms),"phase_median_ms":phases.iter().map(|v|median(v)).collect::<Vec<_>>(),"private_ms":profile_ms,"public_ms":public_ms,"logical_peak":logical,"branches":branches,"implicit":implicit,"runs":runs}));
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("tail").map_err(Into::into);
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"complete_inputs":11,"MDL_inputs":mdl,"phases":["header_CRC_alphabet","model_parse","program_range_last_setup","entropy_and_active","inverse_and_drop_forest","final_checks_CRC"],"warm":1,"rounds":9,"speed_evidence":false,"known_development":true,"native_changes":false})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
