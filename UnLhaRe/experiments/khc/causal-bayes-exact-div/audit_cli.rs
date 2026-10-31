//! exact quotientの独立数値照合専用。製品CLIではない。
mod exact_div;

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

type Result<T> = std::result::Result<T, String>;
const MAX_CASES: usize = 65536;
const MAX_INPUT: usize = 16 + MAX_CASES * 24;

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: ratio-audit input output".into());
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
    if input.len() < 16 || &input[..8] != b"KHCDIV0\0" {
        return Err("bad audit magic/header".into());
    }
    let count = u32::from_le_bytes(input[8..12].try_into().unwrap()) as usize;
    let flags = u32::from_le_bytes(input[12..16].try_into().unwrap());
    if count > MAX_CASES || flags != 0 {
        return Err("audit count/flags outside bounds".into());
    }
    let input_size = count
        .checked_mul(24)
        .and_then(|n| n.checked_add(16))
        .ok_or("audit input size overflow")?;
    if input.len() != input_size {
        return Err("audit input length mismatch".into());
    }
    let output_size = count
        .checked_mul(16)
        .and_then(|n| n.checked_add(16))
        .ok_or("audit output size overflow")?;
    let mut output = Vec::new();
    output
        .try_reserve_exact(output_size)
        .map_err(|_| "audit output allocation failed")?;
    output.extend_from_slice(b"KHCDVO0\0");
    output.extend_from_slice(&(count as u32).to_le_bytes());
    output.extend_from_slice(&0_u32.to_le_bytes());
    let (mut success, mut zero, mut overflow) = (0_usize, 0_usize, 0_usize);
    for triple in input[16..].chunks_exact(24) {
        let a = u64::from_le_bytes(triple[..8].try_into().unwrap());
        let b = u64::from_le_bytes(triple[8..16].try_into().unwrap());
        let d = u64::from_le_bytes(triple[16..24].try_into().unwrap());
        let (tag, quotient) = match exact_div::ratio(a, b, d) {
            Ok(q) => {
                success += 1;
                (0_u64, q)
            }
            Err(error) if error == "CTS zero denominator" => {
                zero += 1;
                (1, 0)
            }
            Err(error) if error == "CTS quotient overflow" => {
                overflow += 1;
                (2, 0)
            }
            Err(error) => return Err(error),
        };
        output.extend_from_slice(&tag.to_le_bytes());
        output.extend_from_slice(&quotient.to_le_bytes());
    }
    let path = Path::new(&args[2]);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(error) = file.write_all(&output).and_then(|()| file.sync_all()) {
        drop(file);
        // この実行がcreate_newした出力だけをI/O失敗時に清掃する。
        // 既存研究CLIと同じ公開設計で、競合する外部置換の万能保証ではない。
        let _ = std::fs::remove_file(path);
        return Err(format!("output write: {error}"));
    }
    println!(
        "{{\"operation\":\"ratio-audit\",\"cases\":{count},\"success\":{success},\"zero\":{zero},\"overflow\":{overflow},\"portable\":{}}}",
        cfg!(any(not(target_arch = "x86_64"), khc_portable_div))
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
