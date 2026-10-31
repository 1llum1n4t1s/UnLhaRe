//! 実CTSモデルの更新前Q15予測を独立照合する研究用CLI。
mod cts_model;

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

const MAX_RECORDS: usize = 4096;
const MAX_INPUT: usize = MAX_RECORDS * 2;
type Result<T> = std::result::Result<T, String>;

fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}

fn read_records(path: &Path) -> Result<Vec<u8>> {
    let file = File::open(path).map_err(|e| format!("input open: {e}"))?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("input metadata: {e}"))?;
    if !metadata.is_file() || metadata.len() > MAX_INPUT as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut input = Vec::new();
    // read_to_endの暗黙拡張を避けるため、上限検出用1byteも先に確保する。
    input
        .try_reserve_exact(MAX_INPUT + 1)
        .map_err(|_| "input allocation failed")?;
    file.take(MAX_INPUT as u64 + 1)
        .read_to_end(&mut input)
        .map_err(|e| format!("input read: {e}"))?;
    if input.len() > MAX_INPUT {
        return Err("input exceeds limit".into());
    }
    if input.len() % 2 != 0 {
        return Err("input has incomplete record".into());
    }
    // 全recordを検査し終えてからモデル計算と出力作成へ進む。
    for record in input.chunks_exact(2) {
        if record[0] > 6 || record[1] > 1 {
            return Err("record class/bit outside bounds".into());
        }
    }
    Ok(input)
}

fn predictions(input: &[u8]) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(input.len())
        .map_err(|_| "output allocation failed")?;
    let mut model = cts_model::Model::new()?;
    for record in input.chunks_exact(2) {
        let class = u32::from(record[0]);
        let prediction = model.predict(class)?;
        output.extend_from_slice(&prediction.zero().to_le_bytes());
        model.update(class, &prediction, record[1] != 0)?;
    }
    Ok(output)
}

fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(e) = file.write_all(bytes).and_then(|()| file.sync_all()) {
        // I/O故障時は今回create_newした部分出力が残る可能性を明示する。
        return Err(format!(
            "output write: {e}; partial newly-created output may remain"
        ));
    }
    Ok(())
}

fn main_run() -> Result<()> {
    let mut args = std::env::args_os();
    let _program = args.next();
    let input_path = args.next().ok_or("usage: khc_cts_q32_audit input output")?;
    let output_path = args.next().ok_or("usage: khc_cts_q32_audit input output")?;
    if args.next().is_some() {
        return Err("usage: khc_cts_q32_audit input output".into());
    }
    let input = read_records(Path::new(&input_path))?;
    let output = predictions(&input)?;
    publish(Path::new(&output_path), &output)?;
    println!(
        "{{\"operation\":\"cts-q32-audit\",\"observations\":{}}}",
        input.len() / 2
    );
    Ok(())
}

fn main() {
    if let Err(error) = main_run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
