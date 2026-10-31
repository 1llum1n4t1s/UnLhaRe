//! 実CTS mixtureの独立数値照合専用。製品CLIではない。
#[allow(dead_code)]
mod cts_model;
#[allow(dead_code)]
#[path = "../causal-bayes-exact-div/exact_div.rs"]
mod exact_div;

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

type Result<T> = std::result::Result<T, String>;
const MAX_CASES: usize = 65536;
const RECORD_SIZE: usize = 24;
const MAX_INPUT: usize = MAX_CASES * RECORD_SIZE;

#[allow(dead_code)]
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values
        .try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    values.resize(length, value);
    Ok(values)
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: cts-mixture-audit input output".into());
    }
    let file = File::open(Path::new(&args[1])).map_err(|e| format!("input open: {e}"))?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("input metadata: {e}"))?;
    if !metadata.is_file() || metadata.len() > MAX_INPUT as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut input = Vec::new();
    input
        .try_reserve_exact(usize::try_from(metadata.len()).map_err(|_| "input length overflow")?)
        .map_err(|_| "input allocation failed")?;
    file.take(MAX_INPUT as u64 + 1)
        .read_to_end(&mut input)
        .map_err(|e| format!("input read: {e}"))?;
    if input.len() > MAX_INPUT {
        return Err("input exceeds limit".into());
    }
    if input.len() % RECORD_SIZE != 0 {
        return Err("audit input length mismatch".into());
    }
    let count = input.len() / RECORD_SIZE;
    let output_size = count.checked_mul(16).ok_or("audit output size overflow")?;
    let mut output = Vec::new();
    output
        .try_reserve_exact(output_size)
        .map_err(|_| "audit output allocation failed")?;
    for triple in input.chunks_exact(RECORD_SIZE) {
        let weight = u64::from_le_bytes(triple[..8].try_into().unwrap());
        let kt = u64::from_le_bytes(triple[8..16].try_into().unwrap());
        let child = u64::from_le_bytes(triple[16..24].try_into().unwrap());
        let (status, value) = match cts_model::audit_mixture(weight, kt, child) {
            Ok(value) => (0_u64, value),
            Err(error) if error == "CTS weight outside bounds" => (1, 0),
            Err(error) if error == "CTS Q48 probability outside bounds" => (2, 0),
            Err(error) => return Err(error),
        };
        output.extend_from_slice(&status.to_le_bytes());
        output.extend_from_slice(&value.to_le_bytes());
    }
    let path = Path::new(&args[2]);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(error) = file.write_all(&output).and_then(|()| file.sync_all()) {
        drop(file);
        // 外部の同時置換を削除しないため、I/O失敗時も出力パスを保持する。
        // 部分生成物が残り得るが、CLIは失敗を返す。
        return Err(format!("output write: {error}"));
    }
    println!("{{\"operation\":\"cts-mixture-audit\",\"cases\":{count}}}");
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
