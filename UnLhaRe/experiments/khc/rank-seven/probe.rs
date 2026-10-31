//! 現書庫の全復元と7bin区間数census。新codecや速度の証拠ではない。
#[allow(dead_code)]
#[path = "../binary-threshold/baseline_block.rs"]
mod baseline;
#[allow(dead_code)]
#[path = "census_block.rs"]
mod census;
use std::{fmt::Write, fs::File, io::Read, path::Path};
use unlhare::{Limits, khc};
fn bounded(path: &Path, max: usize) -> Result<Vec<u8>, String> {
    let f = File::open(path).map_err(|e| e.to_string())?;
    if f.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("file bound".into());
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(max + 1)
        .map_err(|_| "input allocation")?;
    f.take((max + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > max {
        return Err("changed file bound".into());
    }
    Ok(bytes)
}
fn get32(bytes: &[u8], at: usize) -> Result<usize, String> {
    Ok(u32::from_le_bytes(
        bytes
            .get(at..at.checked_add(4).ok_or("offset")?)
            .ok_or("u32 extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus arguments".into());
    }
    let (pairs, histories, tail) = census::rank_geometry()?;
    if pairs != 33153 || histories != 7168 {
        return Err("geometry count".into());
    }
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11
        || khc::verify_archive(archive, &Limits::default())
            .map_err(|e| e.to_string())?
            .bytes
            != 2810784
    {
        return Err("archive contract".into());
    }
    let bytes = bounded(archive, 1048576)?;
    if bytes.len() != 466395 {
        return Err("archive extent".into());
    }
    let mut position = 32 + get32(&bytes, 20)?;
    let mut report = format!(
        "{{\"geometry_pairs\":{pairs},\"history_cases\":{histories},\"derived_tail\":{tail},\"byte_exact\":true,\"stats_exact\":true,\"census_repeat_exact\":true,\"histogram_direct_equal\":true,\"speed_evidence\":false,\"model_fitted\":false,\"rows\":["
    );
    for (index, entry) in entries.iter().enumerate() {
        if entry.is_directory
            || entry.original_size > 1048576
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry contract".into());
        }
        let raw = bounded(&corpus.join(&entry.name), 1048576)?;
        if raw.len() as u64 != entry.original_size {
            return Err("source extent".into());
        }
        let length = get32(&bytes, position)?;
        position += 4;
        let frame = bytes
            .get(position..position.checked_add(length).ok_or("frame overflow")?)
            .ok_or("frame extent")?;
        position += length + 4;
        if khc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
            return Err("public byte mismatch".into());
        }
        let (before, old_stats) = baseline::decode(frame)?;
        if before != raw {
            return Err("baseline byte mismatch".into());
        }
        drop(before);
        let (plain, stats) = census::decode(frame)?;
        if plain != raw || format!("{stats:?}") != format!("{old_stats:?}") {
            return Err("census byte/stats".into());
        }
        drop(plain);
        let counts = census::rank_counts();
        let info = census::rank_info();
        let leaf = census::rank_histogram();
        let (again, again_stats) = census::decode(frame)?;
        if again != raw
            || counts != census::rank_counts()
            || info.map(f64::to_bits) != census::rank_info().map(f64::to_bits)
            || leaf != census::rank_histogram()
            || format!("{stats:?}") != format!("{again_stats:?}")
        {
            return Err("repeat/full histogram equality".into());
        }
        drop(again);
        if stats.method == 1 {
            if counts[0] != stats.runs
                || counts[4] != stats.branches - stats.implicit
                || counts[5] != stats.escapes
                || counts[7] != 1536
                || counts[8] != 2097152
                || counts[9] != tail
                || counts[1] + counts[6] != stats.runs
                || counts[2] > counts[1]
                || counts[4] < counts[2]
                || leaf.len() != 1536
                || stats.phase_capacity_bound + counts[8] > 67108864
            {
                return Err("census/resource contract".into());
            }
            let total = leaf
                .iter()
                .flat_map(|row| row.iter())
                .map(|&n| n as usize)
                .sum::<usize>();
            if total != counts[1] {
                return Err("histogram count sum".into());
            }
        } else if counts != [0; 10] || info != [0.0; 2] || !leaf.is_empty() {
            return Err("nonMDL reset".into());
        }
        let mut digest = 0xcbf29ce484222325u64;
        for byte in leaf
            .iter()
            .flat_map(|row| row.iter())
            .flat_map(|n| n.to_le_bytes())
        {
            digest = (digest ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
        if index > 0 {
            report.push(',');
        }
        write!(&mut report,"{{\"name\":{:?},\"raw\":{},\"frame\":{},\"method\":{},\"runs\":{},\"branches\":{},\"implicit\":{},\"phase_capacity_bound\":{},\"rank_counts\":{:?},\"old_root_tail_loss\":{},\"root_model_bits\":{},\"leaf_digest\":\"{digest:016X}\"}}",entry.name,raw.len(),frame.len(),stats.method,stats.runs,stats.branches,stats.implicit,stats.phase_capacity_bound,counts,info[0],info[1]).map_err(|_|"report")?;
    }
    if bytes.get(position..) != Some(&b"KHC1END\0"[..]) || report.len() > 16384 {
        return Err("archive/report final".into());
    }
    report.push_str("]}");
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("{error}");
        std::process::exit(1)
    }
}
