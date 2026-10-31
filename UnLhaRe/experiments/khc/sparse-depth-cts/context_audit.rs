#![allow(dead_code)]
use std::io::Write;
#[path = "cts_model.rs"]
mod heavy;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values.try_reserve_exact(length)?;
    values.resize(length, value);
    Ok(values)
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let argv: Vec<_> = std::env::args_os().collect();
    if argv.len() != 2 {
        return Err("usage: context-audit <new-records-output>".into());
    }
    let file = std::fs::OpenOptions::new().create_new(true).write(true).open(&argv[1])?;
    let mut output = std::io::BufWriter::new(file);
    let depths = [0usize, 1, 2, 4, 8, 16];
    let offsets = [0usize, 1, 3, 7, 23, 279];
    let mut records = 0usize;
    for history in 0..=u16::MAX {
        let mut legacy = 0usize;
        for depth in 0..=16 {
            if depth > 0 {
                let bit = usize::from((history >> (depth - 1)) & 1);
                legacy = legacy.checked_mul(2).and_then(|index| index.checked_add(1 + bit))
                    .ok_or("legacy tree index overflow")?;
            }
            if let Some(level) = depths.iter().position(|&selected| selected == depth) {
                // 元treeを1bitずつ辿った結果を、新context_indexとは別の計算で照合。
                let key = legacy.checked_sub((1usize << depth) - 1).ok_or("legacy block underflow")?;
                if key >= 1usize << depth {
                    return Err("legacy key outside depth".into());
                }
                let expected = offsets[level] + key;
                let actual = heavy::audit_context(history, level)?;
                if actual != expected {
                    return Err(format!("context mismatch: history={history}, level={level}").into());
                }
                output.write_all(&history.to_le_bytes())?;
                output.write_all(&[level as u8, depth as u8])?;
                output.write_all(&(expected as u32).to_le_bytes())?;
                output.write_all(&(actual as u32).to_le_bytes())?;
                records += 1;
            }
        }
    }
    if heavy::audit_context(0, 6).is_ok() || heavy::audit_context(u16::MAX, usize::MAX).is_ok() {
        return Err("invalid context level accepted".into());
    }
    output.flush()?;
    let (nodes, levels, node_bytes, prediction_bytes) = heavy::audit_sparse_layout();
    if records != 393216 || nodes != 65815 || levels != 6 || node_bytes != 16 || prediction_bytes != 192 {
        return Err("sparse context count/layout differs".into());
    }
    println!("{{\"histories\":65536,\"records\":{records},\"record_bytes\":12,\"nodes\":{nodes},\"levels\":{levels},\"node_bytes\":{node_bytes},\"prediction_bytes\":{prediction_bytes},\"invalid_levels_rejected\":2}}");
    Ok(())
}
