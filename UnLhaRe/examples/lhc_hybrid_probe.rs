//! 製品APIの既定/trial/adaptive実選択を費用込みで測る。
use std::{fs::File, io::Read, time::Instant};
use unlhare::lhc::{self, BlockStrategy};
fn execute() -> Result<(), String> {
    let arg = std::env::args().nth(1).ok_or("input file")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(lhc::BLOCK_BYTES + 1)
        .map_err(|_| "input allocation")?;
    File::open(arg)
        .map_err(|e| e.to_string())?
        .take((lhc::BLOCK_BYTES + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    if raw.len() > lhc::BLOCK_BYTES {
        return Err("input bound".into());
    }
    let mut rows = Vec::new();
    for (variant, name, strategy) in [
        (0, "mdl", BlockStrategy::Mdl),
        (3, "hybrid-trial", BlockStrategy::HybridTrial),
        (8, "binary-adaptive", BlockStrategy::BinaryAdaptive),
    ] {
        let time = Instant::now();
        let wire = lhc::compress_block_with_strategy(&raw, strategy).map_err(|e| e.to_string())?;
        let enc = time.elapsed().as_nanos();
        let time = Instant::now();
        let plain = lhc::decompress_block(&wire).map_err(|e| e.to_string())?;
        let dec = time.elapsed().as_nanos();
        if plain != raw {
            return Err("byte mismatch".into());
        }
        rows.push(serde_json::json!({"variant":variant,"strategy":name,"bytes":wire.len(),"method":wire[10],"revision":wire[8],"encode_ns":enc,"decode_ns":dec,"byte_exact":true}));
    }
    println!("{}", serde_json::json!({"raw_bytes":raw.len(),"rows":rows}));
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("lhc_hybrid_probe: {e}");
        std::process::exit(1);
    }
}
