//! 型/辞書/nativeモデル/CRC込み。構築と比較はdecode clock外、RAW encode性能の証拠ではない。
mod implicit;
use implicit::Result;
use std::path::Path;
struct Row<'a> {
    name: String,
    raw: Vec<u8>,
    old: &'a [u8],
    selected: Vec<u8>,
}
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(b.get(at..at.checked_add(4).ok_or("extent")?).ok_or("field")?.try_into().map_err(|_| "field")?) as usize)
}
fn ram(caller: usize) -> Result<()> {
    if caller.checked_add(56 << 20).ok_or("overflow")? > 64 << 20 {
        Err("caller/library bound".into())
    } else {
        Ok(())
    }
}
fn median(v: &[f64]) -> f64 {
    let mut a = v.to_vec();
    a.sort_by(f64::total_cmp);
    a[a.len() / 2]
}
fn decode(row: &Row<'_>, candidate: bool, caller: usize) -> Result<Vec<u8>> {
    if candidate && !row.selected.is_empty() {
        implicit::decode(&row.selected, caller).map(|x| x.0)
    } else {
        unlhare::lhc::decompress_block(row.old).map_err(|e| e.to_string())
    }
}
fn timed(row: &Row<'_>, candidate: bool, caller: usize) -> Result<f64> {
    ram(caller)?;
    let clock = std::time::Instant::now();
    let out = decode(row, candidate, caller)?;
    let ms = clock.elapsed().as_secs_f64() * 1000.;
    ram(caller + out.capacity())?;
    if out != row.raw {
        return Err("paired full raw byte mismatch".into());
    }
    Ok(ms)
}
fn run() -> Result<()> {
    ram(6 << 20)?;
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 || !matches!(args[3].as_str(), "normal" | "reverse") {
        return Err("archive corpus order".into());
    }
    let reverse = args[3] == "reverse";
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if saved.len() != 457017 || entries.len() != 11 {
        return Err("fixed source archive".into());
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
    let mut at = 32 + num(&saved, 20)?;
    let mut rows: Vec<Row<'_>> = Vec::new();
    let mut raw_sum = 0;
    for e in entries {
        if e.is_directory || !names.contains(&e.name.as_str()) || rows.iter().any(|r| r.name == e.name) || e.original_size > implicit::MAX_RAW as u64 {
            return Err("entry scope".into());
        }
        let n = num(&saved, at)?;
        at += 4;
        if !(40..=implicit::MAX_RAW + 80).contains(&n) {
            return Err("extent bound".into());
        }
        let end = at.checked_add(n).ok_or("overflow")?;
        let old = saved.get(at..end).ok_or("frame")?;
        at = end;
        ram(saved.capacity() + raw_sum + e.original_size as usize + (1 << 20))?;
        let raw = std::fs::read(Path::new(&args[2]).join(&e.name)).map_err(|e| e.to_string())?;
        if raw.len() as u64 != e.original_size || implicit::crc(&raw) != num(&saved, at)? as u32 {
            return Err("raw CRC/length".into());
        }
        at += 4;
        raw_sum += raw.capacity();
        rows.push(Row {
            name: e.name,
            raw,
            old,
            selected: Vec::new(),
        });
    }
    if saved.get(at..) != Some(b"KHC1END\0".as_slice()) || rows.iter().map(|r| r.raw.len()).sum::<usize>() != 2810784 {
        return Err("fixed footer/totals".into());
    }
    let mut caller = saved.capacity() + raw_sum + (1 << 20);
    ram(caller)?;
    let mut changed = 0;
    let mut selected_sum = 0;
    for row in &mut rows {
        let (frame, _) = implicit::encode(&row.raw, caller)?;
        ram(caller + frame.capacity() + row.raw.len())?;
        let decoded = implicit::decode(&frame, caller + frame.capacity())?.0;
        if decoded != row.raw {
            return Err("constructed private bytes".into());
        }
        drop(decoded);
        if frame.len() < row.old.len() {
            caller += frame.capacity();
            row.selected = frame;
            changed += 1;
        }
        selected_sum += if row.selected.is_empty() { row.old.len() } else { row.selected.len() };
        ram(caller)?;
    }
    let native_sum: usize = rows.iter().map(|r| r.old.len()).sum();
    if saved.len() - native_sum != 444 {
        return Err("container fee".into());
    }
    let fee = 444 + selected_sum + 256;
    if fee != 456816 || changed != 1 || fee > 457415 || fee >= 457273 {
        return Err("E2E selection prerequisite changed".into());
    }
    let mut a_group = [0f64; 9];
    let mut b_group = [0f64; 9];
    let mut result = Vec::new();
    let mut files_pass = true;
    for row in &rows {
        let order = if reverse { [true, false] } else { [false, true] };
        for mode in order {
            timed(row, mode, caller)?;
        }
        let mut aa = Vec::new();
        let mut bb = Vec::new();
        for i in 0..9 {
            for mode in order {
                let ms = timed(row, mode, caller)?;
                if mode {
                    bb.push(ms);
                    b_group[i] += ms;
                } else {
                    aa.push(ms);
                    a_group[i] += ms;
                }
            }
        }
        let a = median(&aa);
        let b = median(&bb);
        let pass = b <= 1.10 * a;
        files_pass &= pass;
        result.push(
            serde_json::json!({"name":row.name,"changed":!row.selected.is_empty(),"native_ms":aa,"candidate_ms":bb,
            "native_median_ms":a,"candidate_median_ms":b,"ratio":b/a,"file_pass":pass,"byte_exact":true}),
        );
    }
    let a = median(&a_group);
    let b = median(&b_group);
    println!(
        "{}",
        serde_json::json!({"order":args[3],"pairs":9,"warm":1,"complete_inputs":11,"changed":changed,"all_fee":fee,
        "native_group_ms":a_group,"candidate_group_ms":b_group,"native_median_ms":a,"candidate_median_ms":b,"ratio":b/a,
        "group_pass":b<=0.85*a,"files_pass":files_pass,"diagnostic_pass":b<=0.85*a && files_pass,
        "group_metric":"median of aligned pair-index summed per-file decode times; not whole CLI wall time",
        "codec_implemented":true,"native_integrated":false,"paired_RAW_encode_timing":false,"final_7zip_gate":false,
        "construction_clock_included":false,"model_dictionary_CRC_clock_included":true,"rows":result})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
