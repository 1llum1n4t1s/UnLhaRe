//! 起動/圧縮/IOを除いた復号batch。照合と解放は両側へ同じく課金する。
#[allow(dead_code)]
#[path = "../experiments/khc/active-rotation/baseline_block.rs"]
mod khc;
use khc as baseline;
use std::{fs::File, io::Read, time::Instant};
use unlhare::khc::{self as product_khc, BlockStrategy};
fn execute() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("input file")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(product_khc::BLOCK_BYTES + 1)
        .map_err(|_| "input allocation")?;
    File::open(path)
        .map_err(|e| e.to_string())?
        .take((product_khc::BLOCK_BYTES + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    if raw.len() > product_khc::BLOCK_BYTES {
        return Err("input bound".into());
    }
    let wire = product_khc::compress_block_with_strategy(&raw, BlockStrategy::BinaryAdaptive)
        .map_err(|e| e.to_string())?;
    let mut rows = Vec::new();
    for round in 0..10 {
        let mut ns = [0u128; 2];
        for side in if round % 2 == 0 { [0, 1] } else { [1, 0] } {
            let time = Instant::now();
            for _ in 0..4 {
                let plain = if side == 0 {
                    baseline::decode(&wire)?.0
                } else {
                    product_khc::decompress_block(&wire).map_err(|e| e.to_string())?
                };
                if plain != raw {
                    return Err("byte mismatch".into());
                }
                drop(plain);
            }
            ns[side] = time.elapsed().as_nanos();
        }
        rows.push(
            serde_json::json!({"round":round,"warm":round==0,"old_ns":ns[0],
            "new_ns":ns[1],"batch":4,"bytes":wire.len(),"method":wire[10],"byte_exact":true}),
        );
    }
    println!("{}", serde_json::json!({"raw_bytes":raw.len(),"rows":rows}));
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("khc_rotation_batch: {error}");
        std::process::exit(1);
    }
}
