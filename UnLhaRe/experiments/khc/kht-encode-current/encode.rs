//! RAWから全trialを実行する開発入力専用screen。採用・7-Zip gateではない。
#![allow(dead_code)]
#[path = "../../../src/lhc/block/mod.rs"]
mod block;
#[path = "../../../src/lhc/record.rs"]
mod record;
#[path = "../kht-root-table/codec.rs"]
mod root;
use std::{fs::File, io::Read, path::Path, time::Instant};
type Result<T> = std::result::Result<T, String>;
const DRIVER: usize = 1 << 20;
const NATIVE_PROOF_BOUND: usize = 51654872;
#[derive(Clone, Copy, Default)]
struct ProofRow {
    raw: usize,
    logical: usize,
    frame: usize,
}
const NAMES: [&str; 11] =
    ["alice29.txt", "asyoulik.txt", "cp.html", "fields.c", "grammar.lsp", "kennedy.xls", "lcet10.txt", "plrabn12.txt", "ptt5", "sum", "xargs.1"];
fn sum(parts: &[usize]) -> Result<usize> {
    parts.iter().try_fold(0usize, |a, b| a.checked_add(*b).ok_or("capacity overflow".into()))
}
fn gate(parts: &[usize], peak: &mut usize) -> Result<()> {
    let n = sum(parts)?;
    *peak = (*peak).max(n);
    if n > root::RAM_LIMIT {
        return Err(format!("whole caller RAM {n} > {}", root::RAM_LIMIT));
    }
    Ok(())
}
fn read_raw(dir: &Path, name: &str, peak: &mut usize) -> Result<Vec<u8>> {
    if name.contains(['/', '\\', ':']) || name == "." || name == ".." {
        return Err("unsafe corpus name".into());
    }
    let path = dir.join(name);
    let m = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if !m.is_file() || m.file_type().is_symlink() {
        return Err("corpus regular file".into());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if m.file_attributes() & 0x400 != 0 {
            return Err("corpus reparse point".into());
        }
    }
    let n = usize::try_from(m.len()).map_err(|_| "input extent")?;
    if n > root::MAX_INPUT {
        return Err("input MAX_INPUT".into());
    }
    gate(&[DRIVER, n + 1], peak)?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(n + 1).map_err(|_| "input allocation")?;
    gate(&[DRIVER, raw.capacity()], peak)?;
    File::open(path).map_err(|e| e.to_string())?.take((n + 1) as u64).read_to_end(&mut raw).map_err(|e| e.to_string())?;
    if raw.len() != n || raw.capacity() > root::MAX_INPUT + 1 {
        return Err("input changed/capacity".into());
    }
    Ok(raw)
}
// 親controllerがproof/source/raw/depsのSHAを固定しreadlockを維持する条件付き予約。
// 固定known11の以前の実証上界。未見入力へ適用できる一般APIではない。
fn proof_rows(path: &Path) -> Result<[ProofRow; 11]> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > 65536 {
        return Err("proof JSON extent".into());
    }
    let mut text = String::new();
    file.take(65537).read_to_string(&mut text).map_err(|e| e.to_string())?;
    if text.len() > 65536 {
        return Err("proof JSON changed".into());
    }
    let proof: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let data = &proof["data"];
    if proof["status"].as_str() != Some("completed")
        || proof["live_pins_unchanged"].as_bool() != Some(true)
        || data["logical_bound"].as_u64() != Some(NATIVE_PROOF_BOUND as u64)
        || ["native_trial_frame_exact", "public_baseline_exact", "full_trial_frame_exact"].iter().any(|key| data[*key].as_bool() != Some(true))
    {
        return Err("fixed native proof flags/bound".into());
    }
    let rows = data["rows"].as_array().ok_or("proof rows")?;
    if rows.len() != 11 {
        return Err("proof rows11".into());
    }
    let mut result = [ProofRow::default(); 11];
    for (i, row) in rows.iter().enumerate() {
        if row["name"].as_str() != Some(NAMES[i]) {
            return Err("proof fixed order/name".into());
        }
        let number = |key: &str| -> Result<usize> { usize::try_from(row[key].as_u64().ok_or("proof integer")?).map_err(|_| "proof integer overflow".into()) };
        result[i] = ProofRow { raw: number("raw")?, logical: number("logical_bound")?, frame: number("new_frame")? };
        if result[i].raw > root::MAX_INPUT || result[i].logical > 29214581 || result[i].logical == 0 || result[i].frame > result[i].raw + 40 {
            return Err("proof fixed row domain".into());
        }
    }
    Ok(result)
}
fn native(raw: &Vec<u8>, held: usize, proof: &ProofRow, peak: &mut usize) -> Result<Vec<u8>> {
    if raw.len() != proof.raw {
        return Err("RAW/proof bytes mismatch".into());
    }
    let extra = raw.capacity().checked_sub(raw.len()).ok_or("raw capacity")?;
    gate(&[NATIVE_PROOF_BOUND, extra, held, DRIVER, raw.len() + 40], peak)?;
    let (frame, s) = record::encode(raw)?;
    if s.logical_bound > NATIVE_PROOF_BOUND || s.logical_bound != proof.logical || frame.len() != proof.frame || frame.capacity() > raw.len() + 40 {
        return Err("native proof bound/frame drift".into());
    }
    // logical_boundはraw.len込み。packが返す最終Vecは別途保守課金する。
    gate(&[s.logical_bound, extra, held, DRIVER, frame.capacity()], peak)?;
    Ok(frame)
}
fn candidate(raw: &Vec<u8>, held: usize, proof: &ProofRow, peak: &mut usize) -> Result<Vec<u8>> {
    let native = native(raw, held, proof, peak)?;
    if native.get(..8) != Some(&record::MAGIC[..]) || native.get(10) != Some(&2) {
        return Ok(native);
    }
    let inner = native.get(40..).ok_or("KRS payload")?;
    if inner.get(..8) != Some(&b"KHC1BLK\0"[..]) || inner.get(10) != Some(&1) {
        return Ok(native);
    }
    let extra = raw.capacity() - raw.len();
    let reservation = sum(&[root::encoder_reserve(raw.len()), raw.len(), inner.len(), native.capacity(), extra, held, DRIVER])?;
    gate(&[reservation], peak)?;
    match root::encode_from_legacy(raw, inner)? {
        Some((new, s)) => {
            gate(&[s.peak_capacity_bound, native.capacity(), extra, held, DRIVER, new.capacity()], peak)?;
            if new.len() < native.len() { Ok(new) } else { Ok(native) }
        }
        None => {
            gate(&[reservation], peak)?;
            Ok(native)
        }
    }
}
fn verify(raw: &Vec<u8>, frame: &Vec<u8>, other: usize, peak: &mut usize) -> Result<()> {
    let held = sum(&[DRIVER, raw.capacity(), frame.capacity(), other])?;
    let out = if frame.get(..8) == Some(&root::MAGIC[..]) {
        gate(&[root::decoder_reserve(raw.len()), held], peak)?;
        let (out, s) = root::decode(frame)?;
        gate(&[s.peak_capacity_bound, held, out.capacity()], peak)?;
        out
    } else {
        gate(&[NATIVE_PROOF_BOUND, held, raw.len()], peak)?;
        // 同じsourceのStatsでpublic decoderの呼び出しも予約する。
        let (checked, s) = record::decode(frame)?;
        if s.logical_bound > NATIVE_PROOF_BOUND {
            return Err("native decode proof bound drift".into());
        }
        gate(&[s.logical_bound, held, checked.capacity()], peak)?;
        drop(checked);
        let out = unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())?;
        gate(&[s.logical_bound, held, out.capacity()], peak)?;
        if out.capacity() > raw.len() {
            return Err("public decode capacity drift".into());
        }
        out
    };
    if out != *raw {
        return Err("full decoded bytes differ".into());
    }
    Ok(())
}
fn measure(raw: &Vec<u8>, expected: &Vec<u8>, other: &Vec<u8>, new: bool, proof: &ProofRow, peak: &mut usize) -> Result<f64> {
    let held = sum(&[expected.capacity(), other.capacity()])?;
    let clock = Instant::now();
    let frame = if new { candidate(raw, held, proof, peak)? } else { native(raw, held, proof, peak)? };
    let ns = clock.elapsed().as_nanos() as f64;
    if frame != *expected {
        return Err("frame/size nondeterminism".into());
    }
    verify(raw, &frame, held, peak)?;
    Ok(ns)
}
fn median(mut values: [f64; 9]) -> f64 {
    values.sort_by(f64::total_cmp);
    values[4]
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if !(3..=4).contains(&args.len()) {
        return Err("corpus-directory proof-json [normal|reverse]".into());
    }
    if args.iter().map(|arg| arg.capacity()).sum::<usize>() > DRIVER / 16 {
        return Err("driver argument capacity".into());
    }
    let proof = proof_rows(Path::new(&args[2]))?;
    let order = args.get(3).map_or("normal", String::as_str);
    if !matches!(order, "normal" | "reverse") {
        return Err("order normal/reverse".into());
    }
    let dir = Path::new(&args[1]);
    let mut peak = DRIVER;
    let mut rows = Vec::with_capacity(11);
    let mut totals_a = [0.0; 9];
    let mut totals_b = [0.0; 9];
    let mut native_size = 700usize;
    let mut new_size = 700usize;
    let mut improved = 0usize;
    for step in 0..11 {
        let index = if order == "normal" { step } else { 10 - step };
        let name = NAMES[index];
        let raw = read_raw(dir, name, &mut peak)?;
        let row_proof = &proof[index];
        let baseline = native(&raw, 0, row_proof, &mut peak)?;
        gate(&[NATIVE_PROOF_BOUND, raw.capacity() - raw.len(), baseline.capacity(), DRIVER, raw.len() + 40], &mut peak)?;
        let public = unlhare::lhc::compress_block_with_strategy(&raw, unlhare::lhc::BlockStrategy::RecordTrial).map_err(|e| e.to_string())?;
        gate(&[row_proof.logical, raw.capacity() - raw.len(), DRIVER, baseline.capacity(), public.capacity()], &mut peak)?;
        if public.capacity() > raw.len() + 40 {
            return Err("public native capacity drift".into());
        }
        if public != baseline {
            return Err("checked source/public native frame differ".into());
        }
        drop(public);
        let new = candidate(&raw, baseline.capacity(), row_proof, &mut peak)?;
        verify(&raw, &baseline, new.capacity(), &mut peak)?;
        verify(&raw, &new, baseline.capacity(), &mut peak)?;
        measure(&raw, &baseline, &new, false, row_proof, &mut peak)?;
        measure(&raw, &new, &baseline, true, row_proof, &mut peak)?;
        let mut a = [0.0; 9];
        let mut b = [0.0; 9];
        for pair in 0..9 {
            if pair % 2 == 0 {
                a[pair] = measure(&raw, &baseline, &new, false, row_proof, &mut peak)?;
                b[pair] = measure(&raw, &new, &baseline, true, row_proof, &mut peak)?;
            } else {
                b[pair] = measure(&raw, &new, &baseline, true, row_proof, &mut peak)?;
                a[pair] = measure(&raw, &baseline, &new, false, row_proof, &mut peak)?;
            }
            totals_a[pair] += a[pair];
            totals_b[pair] += b[pair];
        }
        native_size += baseline.len();
        new_size += new.len();
        improved += usize::from(new.len() < baseline.len());
        rows.push(serde_json::json!({"manifest_index":index,"name":name,"raw":raw.len(),
            "raw_capacity":raw.capacity(),"native_size":baseline.len(),"new_size":new.len(),
            "native_ns":a,"candidate_ns":b,"warm":1,"pairs":9,"byte_exact":true}));
        // 各入力の全frames/rawをここで破棄。次の入力へ学習/modelを持ち越さない。
    }
    rows.sort_by_key(|r| r["manifest_index"].as_u64().unwrap_or(u64::MAX));
    let a = median(totals_a);
    let b = median(totals_b);
    let screen = a > 0.0 && b <= 1.10 * a && new_size <= 457415 && improved > 0;
    let report = serde_json::json!({"rows":rows,"known_development":true,"order":order,
        "all_fee_selection":true,"archive_fee":700,"native_size":native_size,
        "new_size":new_size,"actual_improved":improved,"native_total_ns":totals_a,
        "candidate_total_ns":totals_b,"native_median_ns":a,"candidate_median_ns":b,
        "pairs":9,"warm":1,"encode_screen_pass":screen,"byte_exact":true,
        "real_raw_encoder":true,"native_integrated":false,"final_7zip_gate":false,
        "ram_max_logical":peak,"checked_source_native_byte_equal":true,
        "native_preflight_scope":"proof-pinned current-source known11 only",
        "native_preflight_proof_bound":NATIVE_PROOF_BOUND,"general_native_reserve_api":false});
    let json = serde_json::to_string(&report).map_err(|e| e.to_string())?;
    if json.capacity() > DRIVER / 2 {
        return Err("driver JSON capacity".into());
    }
    println!("{json}");
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
