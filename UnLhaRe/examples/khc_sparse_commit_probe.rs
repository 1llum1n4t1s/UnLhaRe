//! 製品MDLとのframe一致を保ったphase診断。時間は優位判定へ使わない。
#[allow(dead_code)]
#[path = "../experiments/khc/mdl-phase/profile_block.rs"]
mod profile;
use std::{fs::File, io::Read, time::Instant};
use unlhare::khc;
fn execute() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("input file")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(khc::BLOCK_BYTES + 1)
        .map_err(|_| "input allocation")?;
    File::open(path)
        .map_err(|e| e.to_string())?
        .take((khc::BLOCK_BYTES + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    if raw.len() > khc::BLOCK_BYTES {
        return Err("input bound".into());
    }
    let mut rows = Vec::new();
    for round in 0..4 {
        let mut measured = None;
        let mut product = None;
        for side in if round % 2 == 0 { [0, 1] } else { [1, 0] } {
            let time = Instant::now();
            if side == 0 {
                let wire = khc::compress_block(&raw).map_err(|e| e.to_string())?;
                let ns = time.elapsed().as_nanos();
                product = Some((wire, ns));
            } else {
                let (wire, stats) = profile::encode(&raw)?;
                let ns = time.elapsed().as_nanos();
                measured = Some((wire, stats, ns));
            }
        }
        let (wire, product_ns) = product.ok_or("product state")?;
        let (other, stats, total_ns) = measured.ok_or("profile state")?;
        if wire != other
            || khc::decompress_block(&other).map_err(|e| e.to_string())? != raw
            || profile::decode(&wire)?.0 != raw
        {
            return Err("frame/decode mismatch".into());
        }
        let sum: u128 = stats.profile_ns.iter().sum();
        if sum > total_ns {
            return Err("overlapping phases".into());
        }
        rows.push(
            serde_json::json!({"round":round,"warm":round==0,"bytes":wire.len(),
            "byte_exact":true,"frame_equal":true,"phase_ns":stats.profile_ns,
            "total_ns":total_ns,"unattributed_ns":total_ns-sum,"product_ns":product_ns,
            "zero_rows":stats.zero_rows,"nonzero_rows":stats.nonzero_rows,
            "nondefault_roots":stats.nondefault_roots,"fits":stats.fits,"runs":stats.runs}),
        );
    }
    println!("{}", serde_json::json!({"raw_bytes":raw.len(),"rows":rows}));
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("khc_sparse_commit_probe: {error}");
        std::process::exit(1);
    }
}
