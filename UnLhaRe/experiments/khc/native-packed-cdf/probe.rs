//! 同wireのprivate decoderを全raw復元・CDF oracle・破損後回復・両順pairedで検証する。
#![allow(dead_code)]
mod block;
#[path = "../../../src/khc/record.rs"]
mod record;
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
// private block32MiBに、KRS外側frame(最大raw+80)と既存FIXEDを含めても36MiB内。
const WHOLE_LIBRARY_RESERVE: usize = 36 << 20;
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(b.get(at..at + 4).ok_or("u32 extent")?.try_into().map_err(|_| "u32")?) as usize)
}
fn ram(caller: usize) -> Result<()> {
    if caller.checked_add(WHOLE_LIBRARY_RESERVE).ok_or("caller overflow")? > 64 * 1048576 {
        return Err("whole caller/library bound".into());
    }
    Ok(())
}
fn scalar(row: [u16; 4], k: usize, slot: u32) -> Result<(usize, u32, u32)> {
    if !(2..=4).contains(&k) || row[k..].iter().any(|&f| f != 0) || row[..k].iter().any(|&f| f < 2) || row.iter().map(|&f| u32::from(f)).sum::<u32>() != 32768 {
        return Err("wire CDF support/total/tail".into());
    }
    let mut prefix = 0u32;
    for (child, &f) in row[..k].iter().enumerate() {
        let frequency = u32::from(f);
        if slot < prefix + frequency {
            return Ok((child, prefix, frequency));
        }
        prefix += frequency;
    }
    Err("range CDF child".into())
}
fn finite() -> Result<usize> {
    let mut checked = 0;
    let mut seed = 0x68319c7421u64;
    for k in 2..=4 {
        for case in 0..(65 + k) {
            let mut row = [0u16; 4];
            row[..k].fill(2);
            let mut remaining = 32768 - 2 * k;
            if case == 0 {
                for i in 0..k {
                    row[i] = (32768 / k + usize::from(i < 32768 % k)) as u16;
                }
            } else if case <= k {
                row[case - 1] += remaining as u16;
            } else {
                for i in 0..k - 1 {
                    seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                    let part = (seed as usize) % (remaining + 1);
                    row[i] += part as u16;
                    remaining -= part;
                }
                row[k - 1] += remaining as u16;
            }
            for slot in 0..32768u32 {
                if block::diagnostic_choose(row, k, slot) != scalar(row, k, slot) {
                    return Err("packed/scalar finite differs".into());
                }
                checked += 1;
            }
            for slot in [32768, 65535, u32::MAX] {
                if block::diagnostic_choose(row, k, slot) != scalar(row, k, slot) {
                    return Err("invalid slot differs".into());
                }
                checked += 1;
            }
        }
    }
    for (row, k) in [
        ([16384, 16384, 0, 0], 0),
        ([16384, 16384, 0, 0], 1),
        ([8192; 4], 5),
        ([0; 4], 2),
        ([32767, 1, 0, 0], 2),
        ([16384, 16384, 1, 0], 2),
    ] {
        if block::diagnostic_choose(row, k, 0) != scalar(row, k, 0) {
            return Err("invalid row/support differs".into());
        }
        checked += 1;
    }
    Ok(checked)
}
struct Row<'a> {
    name: String,
    raw: Vec<u8>,
    frame: &'a [u8],
}
fn timed(rows: &[Row<'_>], new: bool, caller: usize) -> Result<Vec<f64>> {
    let mut result = Vec::new();
    for row in rows {
        ram(caller)?;
        let clock = std::time::Instant::now();
        let output = if new {
            let (v, s) = record::decode(row.frame)?;
            if s.logical_bound > WHOLE_LIBRARY_RESERVE || s.logical_bound + caller > 64 * 1048576 {
                return Err("actual caller/library bound".into());
            }
            v
        } else {
            unlhare::khc::decompress_block(row.frame).map_err(|e| e.to_string())?
        };
        let ms = clock.elapsed().as_secs_f64() * 1000.;
        if output != row.raw {
            return Err("paired full bytes".into());
        }
        std::hint::black_box(&output);
        result.push(ms);
    }
    Ok(result)
}
fn median(v: &[f64]) -> f64 {
    let mut v = v.to_vec();
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 || !matches!(args[3].as_str(), "e2e" | "normal" | "reverse") {
        return Err("args archive corpus mode".into());
    }
    let entries = unlhare::khc::list_archive(Path::new(&args[1]), &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if saved.len() != 457017 || entries.len() != 11 {
        return Err("fixed archive".into());
    }
    let mut at = 32 + num(&saved, 20)?;
    let mut rows = Vec::new();
    for entry in entries {
        if entry.is_directory || !entry.name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
            return Err("entry".into());
        }
        let len = num(&saved, at)?;
        at = at.checked_add(4).ok_or("frame prefix")?;
        if len < 40 || len > record::MAX_RAW + 80 {
            return Err("frame prefix extent".into());
        }
        let frame = saved.get(at..at.checked_add(len).ok_or("frame length")?).ok_or("frame extent")?;
        at += len + 4;
        let raw = std::fs::read(Path::new(&args[2]).join(&entry.name)).map_err(|e| e.to_string())?;
        if raw.len() as u64 != entry.original_size {
            return Err("raw size".into());
        }
        rows.push(Row { name: entry.name, raw, frame });
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("footer".into());
    }
    let caller = saved.capacity() + rows.iter().map(|r| r.raw.capacity()).sum::<usize>() + 1048576;
    ram(caller)?;
    if args[3] == "e2e" {
        timed(&rows, false, caller)?;
        timed(&rows, true, caller)?;
        let numeric = finite()?;
        let (mut parsed_rows, mut parsed_checks, mut malformed) = (0, 0, 0);
        let mut mdl = 0;
        for row in &rows {
            if row.frame[10] == 2 && row.frame.get(50) == Some(&1) {
                let (r, c) = block::finite_metadata(&row.frame[40..])?;
                parsed_rows += r;
                parsed_checks += c;
                mdl += 1;
            }
            ram(caller + row.frame.len())?;
            let mut bad = row.frame.to_vec();
            bad[28] ^= 1;
            if record::decode(&bad).is_ok() {
                return Err("wire CRC accepted".into());
            }
            malformed += 1;
            for end in 0..row.frame.len() {
                if record::decode(&row.frame[..end]).is_ok() {
                    return Err("truncated frame accepted".into());
                }
                malformed += 1;
            }
            bad = row.frame.to_vec();
            bad.push(0);
            if record::decode(&bad).is_ok() {
                return Err("trailing frame accepted".into());
            }
            malformed += 1;
            if record::decode(row.frame)?.0 != row.raw {
                return Err("malformed recovery".into());
            }
        }
        let mut synthetic = 0;
        for n in [0, 1, 256, 4096, 1048576] {
            ram(caller + 3 * (n + 40))?;
            let raw: Vec<_> = (0..n).map(|i| (i as u8).wrapping_mul(53)).collect();
            let frame = record::pack(&raw, &[], &raw, 0)?;
            if record::decode(&frame)?.0 != raw || unlhare::khc::decompress_block(&frame).map_err(|e| e.to_string())? != raw {
                return Err("stored boundary".into());
            }
            synthetic += 1;
        }
        if mdl != 8 || parsed_rows != 8 * 872448 {
            return Err("parsed coverage".into());
        }
        println!(
            "{}",
            serde_json::json!({"complete_inputs":11,"MDL_inputs":mdl,"numeric_checks":numeric,"parsed_rows":parsed_rows,"parsed_checks":parsed_checks,"malformed_checks":malformed,"stored_boundaries":synthetic,"full_archive_bytes":saved.len(),"wire_changed":false,"native_integrated":false,"speed_evidence":false,"byte_exact":true,"caller_capacity":caller})
        );
    } else {
        if args[3] == "reverse" {
            rows.reverse();
        }
        let (mut old, mut new) = (Vec::new(), Vec::new());
        let (mut od, mut nd) = (vec![Vec::new(); 11], vec![Vec::new(); 11]);
        timed(&rows, false, caller)?;
        timed(&rows, true, caller)?;
        for pair in 0..9 {
            let (a, b) = if pair % 2 == 0 {
                let a = timed(&rows, false, caller)?;
                let b = timed(&rows, true, caller)?;
                (a, b)
            } else {
                let b = timed(&rows, true, caller)?;
                let a = timed(&rows, false, caller)?;
                (a, b)
            };
            old.push(a.iter().sum::<f64>());
            new.push(b.iter().sum::<f64>());
            for i in 0..11 {
                od[i].push(a[i]);
                nd[i].push(b[i]);
            }
        }
        let detail: Vec<_> = rows
            .iter()
            .enumerate()
            .map(|(i, r)| serde_json::json!({"name":r.name,"old_ms":median(&od[i]),"new_ms":median(&nd[i]),"byte_exact":true}))
            .collect();
        let pass = median(&new) <= 0.85 * median(&old) && (0..11).all(|i| median(&nd[i]) <= 1.10 * median(&od[i]));
        println!(
            "{}",
            serde_json::json!({"order":args[3],"pairs":9,"warm":1,"old_median_ms":median(&old),"new_median_ms":median(&new),"old_group_ms":old,"new_group_ms":new,"rows":detail,"diagnostic_pass":pass,"wire_changed":false,"full_archive_bytes":saved.len(),"final_7zip_gate":false,"native_integrated":false,"byte_exact":true})
        );
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("packed CDF: {e}");
        std::process::exit(1)
    }
}

// recordの軽量validatorが要求する親関数。原src/khc/mod.rsの検査を省略せず再現する。
fn validate_legacy_frame(frame: &[u8], expected: usize, archive_revision: u8) -> unlhare::Result<()> {
    use unlhare::Error;
    if expected > block::MAX_INPUT || frame.len() < block::HEADER || frame.len() > expected + block::HEADER {
        return Err(Error::Format("KHC block extent".into()));
    }
    if &frame[..8] != block::MAGIC
        || !block::revision_method_valid(frame)
        || (archive_revision == 1 && frame[8..10] != 1u16.to_le_bytes())
        || frame[11] != 0
        || frame[30..32] != [0; 2]
        || num(frame, 12).map_err(Error::Format)? != expected
    {
        return Err(Error::Format("KHC block header/expected length".into()));
    }
    let primary = num(frame, 16).map_err(Error::Format)?;
    let metadata = num(frame, 20).map_err(Error::Format)?;
    let payload = num(frame, 24).map_err(Error::Format)?;
    let alphabet = usize::from(u16::from_le_bytes([frame[28], frame[29]]));
    let body = alphabet * 2 + metadata + payload;
    if body + block::HEADER != frame.len()
        || (frame[10] >= 2 && (primary != 0 || metadata != 0 || alphabet != 0 || payload < 5 || payload >= expected))
        || (frame[10] == 0 && (primary != 0 || metadata != 0 || alphabet != 0 || payload != expected))
        || (frame[10] == 1 && (body >= expected || primary > expected || !(2..=257).contains(&alphabet) || metadata < 241 || payload < 5))
    {
        return Err(Error::Format("KHC block canonical fields".into()));
    }
    let mut wire = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    wire.update(&frame[..36]);
    wire.update(&frame[40..]);
    if wire.finalize() as u32 != num(frame, 36).map_err(Error::Format)? as u32 {
        return Err(Error::Format("KHC block wire CRC".into()));
    }
    Ok(())
}
