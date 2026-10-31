//! root共同区間の成立率を実復号で数える。時間は性能証拠にしない。
#[allow(dead_code)]
#[path = "../binary-threshold/baseline_block.rs"]
mod baseline;
#[allow(dead_code)]
#[path = "census_block_b.rs"]
mod census;
use std::{fmt::Write, fs::File, io::Read, path::Path};
use unlhare::{Limits, khc};
fn bounded(path: &Path, max: usize) -> Result<Vec<u8>, String> {
    let f = File::open(path).map_err(|e| e.to_string())?;
    if f.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("file bound".into());
    }
    let mut b = Vec::new();
    b.try_reserve_exact(max + 1)
        .map_err(|_| "input allocation")?;
    f.take((max + 1) as u64)
        .read_to_end(&mut b)
        .map_err(|e| e.to_string())?;
    if b.len() > max {
        return Err("changed file bound".into());
    }
    Ok(b)
}
fn get32(b: &[u8], at: usize) -> Result<usize, String> {
    Ok(u32::from_le_bytes(
        b.get(at..at.checked_add(4).ok_or("offset")?)
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
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let geometry = census::root_geometry()?;
    if geometry != 797 {
        return Err("geometry coverage".into());
    }
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    let summary = khc::verify_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11 || summary.bytes != 2810784 {
        return Err("archive contract".into());
    }
    let bytes = bounded(archive, 1048576)?;
    if bytes.len() != 466395 || bytes.get(..8) != Some(&b"KHC1ARC\0"[..]) {
        return Err("archive extent".into());
    }
    let mut pos = 32 + get32(&bytes, 20)?;
    let mut output = format!(
        "{{\"geometry\":{geometry},\"byte_exact\":true,\"stats_exact\":true,\"census_repeat_exact\":true,\"speed_evidence\":false,\"rows\":["
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
        let length = get32(&bytes, pos)?;
        pos += 4;
        let frame = bytes
            .get(pos..pos.checked_add(length).ok_or("frame overflow")?)
            .ok_or("frame extent")?;
        pos += length + 4;
        let public = khc::decompress_block(frame).map_err(|e| e.to_string())?;
        if public != raw {
            return Err("public byte mismatch".into());
        }
        drop(public);
        let (old, old_stats) = baseline::decode(frame)?;
        if old != raw {
            return Err("baseline byte mismatch".into());
        }
        drop(old);
        let (plain, stats) = census::decode(frame)?;
        if plain != raw || format!("{stats:?}") != format!("{old_stats:?}") {
            return Err("census byte/stats mismatch".into());
        }
        drop(plain);
        let counts = census::root_census();
        let info = census::joint_info();
        let (again, again_stats) = census::decode(frame)?;
        if again != raw
            || census::root_census() != counts
            || census::joint_info().map(f64::to_bits) != info.map(f64::to_bits)
            || format!("{stats:?}") != format!("{again_stats:?}")
        {
            return Err("repeat census/stats mismatch".into());
        }
        drop(again);
        if stats.method == 1 {
            if counts[0] != stats.runs
                || counts[1] > stats.runs
                || counts[2] > counts[1]
                || counts[3] > 2 * stats.runs
                || counts[4] > 3073
                || counts[5] > 3073
                || counts[6] != counts[4] * counts[5]
                || counts[7] != counts[6] * 32
                || stats.phase_capacity_bound + counts[8] > 67108864
            {
                return Err("census/resource contract".into());
            }
        } else if counts != [0; 10] {
            return Err("nonMDL census reset".into());
        }
        if index > 0 {
            output.push(',');
        }
        write!(&mut output,"{{\"name\":{:?},\"raw\":{},\"frame\":{},\"method\":{},\"runs\":{},\"branches\":{},\"implicit\":{},\"phase_capacity_bound\":{},\"root_counts\":{:?},\"joint_info\":{:?}}}", entry.name, raw.len(), frame.len(), stats.method, stats.runs, stats.branches, stats.implicit, stats.phase_capacity_bound, counts, info).map_err(|_| "report")?;
    }
    if bytes.get(pos..) != Some(&b"KHC1END\0"[..]) || output.len() > 16384 {
        return Err("archive/report final".into());
    }
    output.push_str("]}");
    println!("{output}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
