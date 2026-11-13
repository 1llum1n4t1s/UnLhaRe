//! 保存済みframeと実原文を通る観察E2E。速度証拠ではない。
#![allow(dead_code)]
mod baseline_census;
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("archive extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus required".into());
    }
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let entries = unlhare::lhc::list_archive(archive, &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    if entries.len() != 11 {
        return Err("corpus entry coverage".into());
    }
    let saved = std::fs::read(archive).map_err(|e| e.to_string())?;
    if saved.len() != 466395 {
        return Err("saved old archive size".into());
    }
    let mut at = 32 + num(&saved, 20)?;
    let mut rows = Vec::new();
    let finite = baseline_census::finite_memo_contract()?;
    for entry in entries {
        if entry.is_directory
            || entry.original_size > 1048576
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry extent/name".into());
        }
        let length = num(&saved, at)?;
        at += 4;
        let frame = saved.get(at..at + length).ok_or("saved frame")?;
        at += length + 4;
        let raw = std::fs::read(corpus.join(&entry.name)).map_err(|e| e.to_string())?;
        let (decoded, s) = baseline_census::decode(frame)?;
        if decoded != raw
            || unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())? != raw
        {
            return Err("observed/public whole bytes".into());
        }
        let logical = s.phase_capacity_bound + saved.capacity() + raw.capacity() + 1048576;
        if logical > 64 * 1048576 {
            return Err("observational peak/caller bound".into());
        }
        if s.method == 1 && s.memo.calls.iter().sum::<usize>() != s.runs * 2 {
            return Err("token coverage".into());
        }
        rows.push(serde_json::json!({"name":entry.name,"raw":raw.len(),"method":s.method,"frame":frame.len(),"metadata":s.metadata,"runs":s.runs,"branches":s.branches,"implicit":s.implicit,"logical_peak":logical,"forest":s.forest_capacity,"parse_transient":s.parse_transient,"inverse":s.inverse_capacity,"calls":s.memo.calls,"hits":s.memo.hits,"collisions":s.memo.collisions,"paid":s.memo.paid,"hit_paid":s.memo.hit_paid,"hit_branches":s.memo.hit_branches,"singleton":s.memo.singleton,"byte_exact":true}));
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("saved tail".into());
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"complete_inputs":11,"finite_memo_checks":finite,"cache_bytes":baseline_census::MEMO_BYTES,"observational_only":true,"speed_evidence":false,"changes_wire_or_decode":false,"input_known_development":true})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
