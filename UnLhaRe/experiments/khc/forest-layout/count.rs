//! CDFの履歴方向の重複を数える診断。速度比較には使用しない。
#[allow(dead_code)]
#[path = "codec.rs"]
mod block;
use std::{fs::File, io::Read};

fn execute() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("input")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(block::MAX_INPUT + 1)
        .map_err(|_| "input allocation")?;
    match path.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(path)
                .map_err(|e| e.to_string())?
                .take((block::MAX_INPUT + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > block::MAX_INPUT {
        return Err("input bound".into());
    }
    let (frame, stats) = block::encode_hybrid(&raw, true)?;
    if block::decode(&frame)?.0 != raw {
        return Err("round trip".into());
    }
    let mut constant = 0usize;
    let mut varying = 0usize;
    let mut comparisons = 0usize;
    let mut forest_bytes = 0usize;
    if stats.method == 1 {
        let start = block::HEADER + stats.alphabet;
        let forest = block::packet::Forest::parse(&frame[start..start + stats.metadata])?;
        forest_bytes = forest.capacity_bytes();
        for c in 0..2 {
            for node in 0..142 {
                for k in 2..=4 {
                    let first = forest.lookup(c, node, k, 0)?;
                    let mut same = true;
                    for history in 0..1024u16 {
                        same &= forest.lookup(c, node, k, history)? == first;
                        comparisons += 1;
                    }
                    if same {
                        constant += 1;
                    } else {
                        varying += 1;
                    }
                }
            }
        }
        if constant + varying != 852 || comparisons != 852 * 1024 {
            return Err("full history coverage".into());
        }
    }
    let logical = if stats.method == 1 {
        852 * 12 + varying * 8192
    } else {
        0
    };
    println!(
        "{{\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"byte_exact\":true,\"constant_roots\":{},\"varying_roots\":{},\"row_comparisons\":{},\"current_forest_capacity\":{},\"proposed_logical_bytes\":{}}}",
        raw.len(),
        frame.len(),
        stats.method,
        constant,
        varying,
        comparisons,
        forest_bytes,
        logical
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("forest_layout: {error}");
        std::process::exit(1);
    }
}
