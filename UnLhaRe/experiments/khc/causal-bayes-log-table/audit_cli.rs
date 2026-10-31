//! 実Modelを通す、最大65536観測の独立数値監査CLI。
#[cfg(all(khc_bayes_lut_audit, not(khc_bayes_lut_reference)))]
mod bayes_model;
#[cfg(all(khc_bayes_lut_reference, not(khc_bayes_lut_audit)))]
#[path = "../causal-bayes-packed/bayes_model.rs"]
mod bayes_model;
#[cfg(any(
    all(khc_bayes_lut_audit, khc_bayes_lut_reference),
    not(any(khc_bayes_lut_audit, khc_bayes_lut_reference))
))]
compile_error!("select exactly one Bayes audit backend");

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

type Result<T> = std::result::Result<T, String>;
const MAX_RECORDS: usize = 65536;
const RECORD_BYTES: usize = 6;
const OUTPUT_BYTES: usize = 18;

fn read_input(path: &Path) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| format!("input open: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("input metadata: {e}"))?;
    let limit = MAX_RECORDS * RECORD_BYTES;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(meta.len() as usize)
        .map_err(|_| "input allocation failed")?;
    f.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("input read: {e}"))?;
    if bytes.len() > limit || bytes.len() % RECORD_BYTES != 0 {
        return Err("input length outside record bounds".into());
    }
    // 全入力の検査を終えるまでModelの構築・更新・出力公開をしない。
    for record in bytes.chunks_exact(RECORD_BYTES) {
        let primary = u16::from_le_bytes([record[2], record[3]]);
        let cts = u16::from_le_bytes([record[4], record[5]]);
        if record[0] >= 7
            || record[1] >= 2
            || !(1..32768).contains(&primary)
            || !(1..32768).contains(&cts)
        {
            return Err("audit record outside bounds".into());
        }
    }
    Ok(bytes)
}

fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(e) = f.write_all(bytes).and_then(|()| f.sync_all()) {
        drop(f);
        // 今回create_newで作った出力だけを、I/O失敗時に清掃する。
        let _ = std::fs::remove_file(path);
        return Err(format!("output write: {e}"));
    }
    Ok(())
}

fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: khc_bayes_log_audit input output".into());
    }
    let input = read_input(Path::new(&args[1]))?;
    let observations = input.len() / RECORD_BYTES;
    let mut output = Vec::new();
    output
        .try_reserve_exact(observations * OUTPUT_BYTES)
        .map_err(|_| "output allocation failed")?;
    #[cfg(khc_bayes_lut_audit)]
    let mut model = bayes_model::Model::new()?;
    #[cfg(khc_bayes_lut_reference)]
    let mut model = bayes_model::Model::new();
    for record in input.chunks_exact(RECORD_BYTES) {
        let class = u32::from(record[0]);
        let bit = record[1] != 0;
        let primary = u16::from_le_bytes([record[2], record[3]]);
        let cts = u16::from_le_bytes([record[4], record[5]]);
        let prediction = model.predict(class, primary, cts)?;
        #[cfg(khc_bayes_lut_audit)]
        let (primary_log2, cts_log2) = model.component_log2(&prediction, bit);
        #[cfg(khc_bayes_lut_reference)]
        let (primary_log2, cts_log2) = {
            // 凍結referenceのobserveと同じ直接式。Model本体は変更しない。
            let observed = |q: u16| {
                let zero = f64::from(q) / 32768.0;
                (if bit { 1.0 - zero } else { zero }).log2()
            };
            (observed(primary), observed(cts))
        };
        output.extend_from_slice(&primary_log2.to_bits().to_le_bytes());
        output.extend_from_slice(&cts_log2.to_bits().to_le_bytes());
        output.extend_from_slice(&prediction.zero().to_le_bytes());
        model.update(class, &prediction, bit)?;
    }
    publish(Path::new(&args[2]), &output)?;
    #[cfg(khc_bayes_lut_audit)]
    let backend = "table";
    #[cfg(khc_bayes_lut_reference)]
    let backend = "direct";
    println!(
        "{{\"operation\":\"bayes-log-audit\",\"observations\":{observations},\"backend\":\"{backend}\"}}"
    );
    Ok(())
}

fn main() {
    if let Err(error) = main_run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
