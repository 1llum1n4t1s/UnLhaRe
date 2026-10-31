//! 整数サイズ screen。frontend/dictionary 検証は entropy codec E2E ではない。
mod adversarial;
mod happy;
mod lexeme;
mod bwt;
mod bwt_happy;
mod bwt_adversarial;
use lexeme::{LIBRARY_RESERVE, MAX_RAW, Result};
use std::path::Path;

fn ram(caller: usize) -> Result<()> {
    if caller.checked_add(LIBRARY_RESERVE).ok_or("caller overflow")? > 64 << 20 {
        return Err("caller/library envelope".into());
    }
    Ok(())
}
fn num(bytes: &[u8], at: usize) -> Result<usize> {
    let end = at.checked_add(4).ok_or("field overflow")?;
    Ok(u32::from_le_bytes(bytes.get(at..end).ok_or("field extent")?.try_into().map_err(|_| "field size")?) as usize)
}
fn crc(bytes: &[u8]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(bytes);
    digest.finalize() as u32
}

fn run() -> Result<()> {
    // 最大 test fixture の caller は4MiB以内。演算側56MiBの先払いと物理監視を区別する。
    ram(4 << 20)?;
    let args: Vec<_> = std::env::args().collect();
    if !(3..=4).contains(&args.len()) || (args.len()==4 && args[3]!="bwt") {
        return Err("archive corpus arguments".into());
    }
    let word_bwt=args.len()==4;
    let normal=happy::run()?+if word_bwt { bwt_happy::run()? } else { 0 };
    let invalid=adversarial::run()?+if word_bwt { bwt_adversarial::run()? } else { 0 };
    ram(2 << 20)?;
    let entries = unlhare::khc::list_archive(Path::new(&args[1]), &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if saved.len() != 457017 || entries.len() != 11 {
        return Err("fixed archive".into());
    }
    let allowed = [
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
    let mut at = 32usize.checked_add(num(&saved, 20)?).ok_or("manifest extent")?;
    let mut rows = Vec::new();
    let (mut native_sum, mut selected_sum, mut raw_sum, mut logical_peak) = (0usize, 0usize, 0usize, 0usize);
    let allowance = 1 << 20; // entry/report/arguments/stack and pinned manifest allowance。
    for e in entries {
        if e.is_directory || !allowed.contains(&e.name.as_str()) || seen.contains(&e.name) || e.original_size > MAX_RAW as u64 {
            return Err("entry scope or size".into());
        }
        let length = num(&saved, at)?;
        at = at.checked_add(4).ok_or("frame prefix overflow")?;
        if !(40..=MAX_RAW + 80).contains(&length) {
            return Err("frame length bound".into());
        }
        let end = at.checked_add(length).ok_or("frame end overflow")?;
        let old = saved.get(at..end).ok_or("frame extent")?;
        at = end;
        let expected_crc = num(&saved, at)? as u32;
        at = at.checked_add(4).ok_or("file CRC overflow")?;
        ram(saved.capacity() + e.original_size as usize + allowance)?;
        let raw = std::fs::read(Path::new(&args[2]).join(&e.name)).map_err(|e| e.to_string())?;
        let caller = saved.capacity() + raw.capacity() + allowance;
        ram(caller)?;
        if raw.len() as u64 != e.original_size || crc(&raw) != expected_crc {
            return Err("raw entry CRC/length".into());
        }
        // native 出力の保持費も復号前に払う。辞書学習とは同時に保持しない。
        ram(caller + raw.len())?;
        let recovered = unlhare::khc::decompress_block(old).map_err(|e| e.to_string())?;
        ram(caller + recovered.capacity())?;
        if recovered != raw {
            return Err("fixed native raw mismatch".into());
        }
        drop(recovered);
        ram(caller)?;
        let (estimate,bound,details)=if word_bwt { let (size,bound,details)=bwt::measure(&raw,caller)?; (size.unwrap_or(old.len()),bound,details) }
        else { let a=lexeme::analyze(&raw)?;
            if !a.frontend_exact || !a.dict_exact || a.logical_bound>LIBRARY_RESERVE { return Err("screen roundtrip/bound".into()); }
            (a.estimated_frame_bytes,a.logical_bound,serde_json::json!({"vocab":a.vocab,"phrases":a.phrases,"symbols":a.symbols,
                "dict_raw_bytes":a.dict_raw_bytes,"dict_box_bytes":a.dict_box_bytes,"model_bytes":a.model_bytes,"ans_bytes":a.ans_bytes})) };
        if caller+bound>64<<20 { return Err("whole screen bound".into()); }
        let selected=old.len().min(estimate);
        raw_sum += raw.len();
        native_sum += old.len();
        selected_sum += selected;
        logical_peak = logical_peak.max(caller + bound);
        rows.push(serde_json::json!({"name":e.name,"raw_bytes":raw.len(),"native_frame_bytes":old.len(),
            "estimated_word_frame_bytes":estimate,"selected_estimate":selected,"details":details,
            "library_logical_bound":bound,"frontend_exact":true,"dict_exact":true,"native_byte_exact":true}));
        seen.push(e.name);
    }
    if saved.get(at..) != Some(b"KHC1END\0".as_slice()) || raw_sum != 2810784 || seen.len() != 11 {
        return Err("fixed footer/raw total".into());
    }
    let overhead = saved.len().checked_sub(native_sum).ok_or("container overhead")?;
    if overhead != 444 {
        return Err("actual container overhead".into());
    }
    let fee = overhead + selected_sum + 256;
    println!(
        "{}",
        serde_json::json!({"codec_implemented":false,"size_screen_only":true,"native_integrated":false,
        "true_RAW_encode_evidence":false,"timing_is_speed_evidence":false,"final_7zip_gate":false,
        "backend":if word_bwt {"native_byte_BWT"} else {"static_word_rANS"},
        "complete_inputs":11,"normal_checks":normal,"invalid_checks":invalid,"raw_bytes":raw_sum,
        "container_overhead":overhead,"integration_reserve":256,"current_native_bytes":saved.len(),
        "estimated_all_fee":fee,"size_pass":fee <= 457415 && fee < 457273,"caller_plus_logical_peak":logical_peak,
        "library_prepaid":LIBRARY_RESERVE,"process_RAM_bound":64<<20,"rows":rows})
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
