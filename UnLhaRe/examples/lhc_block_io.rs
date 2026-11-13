//! 比較harness専用。stdin/stdoutの二進数のみ、進捗は出力しない。
use std::io::{self, Read, Write};
use unlhare::lhc::{HistoryMode, compress_block_with_history_mode, decompress_block};
const MAX_INPUT: usize = 1 << 20;
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 2 || !matches!(args[1].as_str(), "paid" | "low" | "decode") {
        return Err("usage: lhc_block_io paid|low|decode".into());
    }
    let limit = if args[1] == "decode" {
        MAX_INPUT + 40
    } else {
        MAX_INPUT
    };
    let mut input = Vec::new();
    input
        .try_reserve_exact(limit + 1)
        .map_err(|_| "input allocation")?;
    io::stdin()
        .lock()
        .take((limit + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    if input.len() > limit {
        return Err("helper input bound".into());
    }
    let output = if args[1] == "decode" {
        decompress_block(&input).map_err(|e| e.to_string())?
    } else {
        let mode = if args[1] == "paid" {
            HistoryMode::PaidHistoryOrder
        } else {
            HistoryMode::LowHistoryOnly
        };
        compress_block_with_history_mode(&input, mode).map_err(|e| e.to_string())?
    };
    let output_limit = if args[1] == "decode" {
        MAX_INPUT
    } else {
        MAX_INPUT + 40
    };
    if output.len() > output_limit {
        return Err("helper output bound".into());
    }
    io::stdout()
        .lock()
        .write_all(&output)
        .map_err(|e| e.to_string())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("lhc_block_io: {error}");
        std::process::exit(1);
    }
}
