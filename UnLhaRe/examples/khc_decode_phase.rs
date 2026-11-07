//! 移植前CompactTreeの復号phase診断。現製品Programの時間や7-Zip優位の証拠ではない。
#[allow(dead_code)]
#[path = "../experiments/khc/compiled-program/pre_port_profile.rs"]
mod khc;
use khc as profile;
use std::{fs::File, io::Read, time::Instant};
use unlhare::khc::{self as product_khc, BlockStrategy};

fn execute() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("input file")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(product_khc::BLOCK_BYTES + 1)
        .map_err(|_| "input allocation")?;
    match path.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(path)
                .map_err(|e| e.to_string())?
                .take((product_khc::BLOCK_BYTES + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > product_khc::BLOCK_BYTES {
        return Err("input bound".into());
    }
    let frame = product_khc::compress_block_with_strategy(&raw, BlockStrategy::BinaryAdaptive)
        .map_err(|e| e.to_string())?;
    if product_khc::decompress_block(&frame).map_err(|e| e.to_string())? != raw {
        return Err("public decode mismatch".into());
    }
    let mut rows = Vec::with_capacity(9);
    for round in 0..10 {
        let started = Instant::now();
        let (plain, stats) = profile::decode(&frame)?;
        let total_ns = started.elapsed().as_nanos();
        let phases = profile::decode_phases();
        if plain != raw || (stats.method == 1 && phases.iter().sum::<u128>() > total_ns) {
            return Err("profile output or timer extent mismatch".into());
        }
        if round != 0 {
            rows.push(serde_json::json!({
                "byte_exact": true, "bytes": frame.len(), "method": stats.method,
                "MDL_phases_applicable": stats.method == 1,
                "total_ns": total_ns, "phase_ns": phases,
                "runs": stats.runs, "branches": stats.branches,
                "forest_capacity": stats.forest_capacity,
                "phase_capacity_bound": stats.phase_capacity_bound
            }));
        }
    }
    let result = serde_json::json!({"raw_bytes": raw.len(), "rows": rows,
        "phase_names": ["wire", "alphabet_forest", "grammar_setup", "token_runs", "inverse", "CRC_capacity"],
        "decoder": "pre-port CompactTree baseline",
        "scope": "pre-port instrumented namespace diagnostic; NOT current Program/public codec speed or seven_zip_superiority"});
    let output = serde_json::to_string(&result).map_err(|e| e.to_string())?;
    if output.len() > 32768 {
        return Err("report bound".into());
    }
    println!("{output}");
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("khc_decode_phase: {error}");
        std::process::exit(1);
    }
}
