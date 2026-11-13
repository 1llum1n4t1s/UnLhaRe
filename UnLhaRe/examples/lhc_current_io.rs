//! 現行研究方式の有限RAM比較。製品APIや旧実験の仕様は変更しない。
#[allow(dead_code, unused_imports)]
#[path = "../experiments/khc/mod.rs"]
mod current;
use std::io::{self, Read, Write};
const MAX_INPUT: usize = 1 << 20;
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 2 || !matches!(args[1].as_str(), "encode" | "decode") {
        return Err("usage: lhc_current_io encode|decode".into());
    }
    let decoding = args[1] == "decode";
    let limit = MAX_INPUT + if decoding { current::HEADER } else { 0 };
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
    let options = current::Options {
        algorithm: current::Algorithm::Standard,
        dictionary: MAX_INPUT,
        max_output: MAX_INPUT,
        memory_budget: 64 << 20,
        ..current::Options::default()
    };
    let output = if decoding {
        current::decode(&input, options, &mut || false)
    } else {
        current::encode(&input, options, &mut || false)
    }
    .map_err(|e| e.to_string())?;
    let output_limit = MAX_INPUT + if decoding { 0 } else { current::HEADER };
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
        eprintln!("lhc_current_io: {error}");
        std::process::exit(1);
    }
}
