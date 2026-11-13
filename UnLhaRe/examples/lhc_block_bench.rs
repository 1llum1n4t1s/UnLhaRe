//! LHC の block 単位の圧縮・復号時間をプロセス内で測る開発用 example。
//! プロセス起動・ファイル公開・fsync を除いた codec だけの費用を、戦略ごとに比べる。
//! 使い方: cargo run --release --example lhc_block_bench -- <file>... [--repeat N]
//! 出力は 1 行 1 file・戦略の TSV（最小時間 ms、frame byte）。正式な比較計測ではない。
use std::time::Instant;
use unlhare::lhc::{BlockStrategy, compress_block_with_strategy, decompress_block};

const STRATEGIES: &[(&str, BlockStrategy)] = &[
    ("mdl", BlockStrategy::Mdl),
    ("spatial-mdl", BlockStrategy::SpatialMdlTrial),
    ("record-fast", BlockStrategy::RecordFastTrial),
    ("record-adaptive", BlockStrategy::RecordAdaptiveTrial),
    ("portfolio", BlockStrategy::PortfolioTrial),
    ("portfolio-ppm", BlockStrategy::PortfolioPpmTrial),
];

fn main() -> Result<(), String> {
    let mut repeat = 3usize;
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--repeat" {
            repeat = args
                .next()
                .and_then(|v| v.parse().ok())
                .ok_or("--repeat needs a number")?;
        } else {
            files.push(arg);
        }
    }
    let only = std::env::var("LHC_BENCH_ONLY").ok();
    println!("file\tstrategy\tbytes\tframe\tencode_ms\tdecode_ms");
    for path in files {
        let data = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
        // 1MiB block 単位に分け、block ごとの合計を出す（製品の書庫と同じ分割）。
        for (name, strategy) in STRATEGIES {
            if only.as_deref().is_some_and(|o| o != *name) {
                continue;
            }
            let mut best_encode = f64::MAX;
            let mut best_decode = f64::MAX;
            let mut frame_bytes = 0usize;
            for _ in 0..repeat.max(1) {
                let mut encode = 0f64;
                let mut decode = 0f64;
                frame_bytes = 0;
                for block in data.chunks(unlhare::lhc::BLOCK_BYTES) {
                    let t = Instant::now();
                    let frame = compress_block_with_strategy(block, *strategy)
                        .map_err(|e| e.to_string())?;
                    encode += t.elapsed().as_secs_f64() * 1e3;
                    let t = Instant::now();
                    let raw = decompress_block(&frame).map_err(|e| e.to_string())?;
                    decode += t.elapsed().as_secs_f64() * 1e3;
                    if raw != block {
                        return Err(format!("{path} {name}: round trip mismatch"));
                    }
                    frame_bytes += frame.len();
                }
                best_encode = best_encode.min(encode);
                best_decode = best_decode.min(decode);
            }
            let file = std::path::Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or(path.clone());
            println!(
                "{file}\t{name}\t{}\t{frame_bytes}\t{best_encode:.2}\t{best_decode:.2}",
                data.len()
            );
        }
    }
    Ok(())
}
