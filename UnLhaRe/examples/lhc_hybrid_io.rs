//! 実選択込みのrevision2をbinary IOで測る。paid=adaptive、low=trial。
use std::io::{self, Read, Write};
use unlhare::lhc::{BlockStrategy, compress_block_with_strategy, decompress_block};
fn execute() -> Result<(), String> {
    let mode = std::env::args().nth(1).ok_or("missing mode")?;
    if !matches!(mode.as_str(), "paid" | "low" | "decode") {
        return Err("unknown mode".into());
    }
    let maximum = (1 << 20) + usize::from(mode == "decode") * 40;
    let mut input = Vec::new();
    input
        .try_reserve_exact(maximum + 1)
        .map_err(|_| "input allocation")?;
    io::stdin()
        .lock()
        .take((maximum + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    if input.len() > maximum {
        return Err("input bound".into());
    }
    let output = match mode.as_str() {
        "decode" => decompress_block(&input),
        "low" => compress_block_with_strategy(&input, BlockStrategy::HybridTrial),
        _ => compress_block_with_strategy(&input, BlockStrategy::BinaryAdaptive),
    }
    .map_err(|e| e.to_string())?;
    if output.len() > (1 << 20) + usize::from(mode != "decode") * 40 {
        return Err("output bound".into());
    }
    io::stdout()
        .lock()
        .write_all(&output)
        .map_err(|e| e.to_string())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("lhc_hybrid_io: {error}");
        std::process::exit(1);
    }
}
