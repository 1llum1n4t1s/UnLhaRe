//! 完全private frameの有限E2Eとサイズscreen。採用・総合性能の証拠ではない。
mod adversarial;
mod happy;
mod implicit;
use implicit::Result;
use std::path::Path;
fn ram(caller: usize) -> Result<()> {
    if caller.checked_add(56 << 20).ok_or("caller overflow")? > 64 << 20 {
        Err("whole caller/native envelope".into())
    } else {
        Ok(())
    }
}
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at.checked_add(4).ok_or("field overflow")?)
            .ok_or("field extent")?
            .try_into()
            .map_err(|_| "field")?,
    ) as usize)
}
fn run() -> Result<()> {
    ram(4 << 20)?;
    let normal = happy::run()?;
    let invalid = adversarial::run()?;
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive corpus".into());
    }
    ram(2 << 20)?;
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if saved.len() != 457017 || entries.len() != 11 {
        return Err("fixed archive".into());
    }
    let names = [
        "alice29.txt",
        "asyoulik.txt",
        "cp.html",
        "fields.c",
        "grammar.lsp",
        "kennedy.xls",
        "lcet10.txt",
        "plrabn12.txt",
        "ptt5",
        "sum",
        "xargs.1",
    ];
    let mut seen = Vec::new();
    let mut rows = Vec::new();
    let mut at = 32usize.checked_add(num(&saved, 20)?).ok_or("manifest")?;
    let (mut native_sum, mut selected_sum, mut raw_sum, mut peak) = (0usize, 0usize, 0usize, 0usize);
    for e in entries {
        if e.is_directory || !names.contains(&e.name.as_str()) || seen.contains(&e.name) || e.original_size > implicit::MAX_RAW as u64 {
            return Err("entry scope".into());
        }
        let n = num(&saved, at)?;
        at = at.checked_add(4).ok_or("prefix")?;
        if !(40..=implicit::MAX_RAW + 80).contains(&n) {
            return Err("frame length".into());
        }
        let end = at.checked_add(n).ok_or("frame end")?;
        let old = saved.get(at..end).ok_or("frame extent")?;
        at = end;
        let checksum = num(&saved, at)? as u32;
        at = at.checked_add(4).ok_or("file CRC")?;
        ram(saved.capacity() + e.original_size as usize + (1 << 20))?;
        let raw = std::fs::read(Path::new(&args[2]).join(&e.name)).map_err(|e| e.to_string())?;
        let caller = saved.capacity() + raw.capacity() + (1 << 20);
        ram(caller)?;
        if raw.len() as u64 != e.original_size || implicit::crc(&raw) != checksum {
            return Err("raw length/CRC".into());
        }
        ram(caller + raw.len())?;
        let original = unlhare::lhc::decompress_block(old).map_err(|e| e.to_string())?;
        ram(caller + original.capacity())?;
        if original != raw {
            return Err("native byte equality".into());
        }
        drop(original);
        let clock = std::time::Instant::now();
        let (frame, enc) = implicit::encode(&raw, caller)?;
        let construction_ms = clock.elapsed().as_secs_f64() * 1000.0;
        ram(caller + frame.capacity() + raw.len())?;
        let (decoded, dec) = implicit::decode(&frame, caller + frame.capacity())?;
        if decoded != raw || enc.logical_peak > 64 << 20 || dec.logical_peak > 64 << 20 || frame.len() > raw.len() + 40 {
            return Err("private codec bytes/bound".into());
        }
        drop(decoded);
        let selected = old.len().min(frame.len());
        peak = peak.max(enc.logical_peak).max(dec.logical_peak);
        raw_sum += raw.len();
        native_sum += old.len();
        selected_sum += selected;
        rows.push(
            serde_json::json!({"name":e.name,"raw_bytes":raw.len(),"native_frame_bytes":old.len(),"private_frame_bytes":frame.len(),
            "selected_bytes":selected,"method":enc.method,"dictionary":enc.dictionary,"stream_bytes":enc.stream,
            "construction_ms_diagnostic_only":construction_ms,"encode_requested_peak":enc.logical_peak,"decode_requested_peak":dec.logical_peak,
            "byte_exact":true,"native_byte_exact":true}),
        );
        seen.push(e.name);
    }
    if saved.get(at..) != Some(b"KHC1END\0".as_slice()) || raw_sum != 2810784 || seen.len() != 11 {
        return Err("fixed totals/footer".into());
    }
    let overhead = saved.len().checked_sub(native_sum).ok_or("container fees")?;
    if overhead != 444 {
        return Err("actual container overhead".into());
    }
    let fee = overhead + selected_sum + 256;
    println!(
        "{}",
        serde_json::json!({"codec_implemented":true,"size_screen_only":false,"stage":"private_codec_E2E_and_component_oracle_size",
        "native_integrated":false,"RAW_input_encoding_executed":true,"paired_RAW_encode_timing":false,"timing_is_speed_evidence":false,
        "final_7zip_gate":false,"complete_inputs":11,"normal_checks":normal,"invalid_checks":invalid,"raw_bytes":raw_sum,
        "current_native_bytes":saved.len(),"actual_container_overhead":overhead,"integration_reserve":256,
        "all_fee":fee,"size_pass":fee<=457415 && fee<457273,"caller_plus_requested_peak":peak,"rows":rows})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
