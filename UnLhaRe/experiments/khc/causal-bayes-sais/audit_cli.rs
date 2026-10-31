//! BWT同値性の独立照合専用。製品CLIではない。
mod bwt;

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

type Result<T> = std::result::Result<T, String>;

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: audit input output".into());
    }
    let file = File::open(Path::new(&args[1])).map_err(|e| format!("input open: {e}"))?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("input metadata: {e}"))?;
    if !metadata.is_file() || metadata.len() > bwt::MAX_INPUT as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut input = Vec::new();
    input
        .try_reserve_exact(usize::try_from(metadata.len()).map_err(|_| "input length overflow")?)
        .map_err(|_| "input allocation failed")?;
    file.take(bwt::MAX_INPUT as u64 + 1)
        .read_to_end(&mut input)
        .map_err(|e| format!("input read: {e}"))?;
    let (last, primary) = bwt::bwt(&input)?;
    let primary = u32::try_from(primary).map_err(|_| "primary overflow")?;
    let n = u32::try_from(last.len()).map_err(|_| "symbol count overflow")?;
    let size = last
        .len()
        .checked_mul(2)
        .and_then(|n| n.checked_add(8))
        .ok_or("audit size overflow")?;
    let mut output = Vec::new();
    output
        .try_reserve_exact(size)
        .map_err(|_| "audit allocation failed")?;
    output.extend_from_slice(&primary.to_le_bytes());
    output.extend_from_slice(&n.to_le_bytes());
    for symbol in last {
        output.extend_from_slice(&symbol.to_le_bytes());
    }
    let path = Path::new(&args[2]);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(error) = file.write_all(&output).and_then(|()| file.sync_all()) {
        drop(file);
        // 外部置換を誤削除しない。I/O失敗時はpartial出力を残す。
        return Err(format!("output write: {error}"));
    }
    println!(
        "{{\"input_bytes\":{},\"primary\":{primary},\"symbols\":{n}}}",
        input.len()
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
