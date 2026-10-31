//! 実保存書庫frameの復号内訳。製品/7Zipの速度優位を主張しない。
#[allow(dead_code)]
#[path = "profile_block.rs"]
mod profile;
use std::{fmt::Write, fs::File, io::Read, path::Path, time::Instant};
use unlhare::{Limits, khc};
fn bounded(path: &Path, max: usize) -> Result<Vec<u8>, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("input file bound".into());
    }
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(max + 1).map_err(|_| "input allocation")?;
    file.take((max + 1) as u64).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() > max { return Err("input changed/bound".into()); }
    Ok(bytes)
}
fn get32(bytes: &[u8], at: usize) -> Result<usize, String> {
    Ok(u32::from_le_bytes(bytes.get(at..at.checked_add(4).ok_or("offset")?)
        .ok_or("u32 extent")?.try_into().map_err(|_| "u32")?) as usize)
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 { return Err("archive and source root arguments".into()); }
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let summary = khc::verify_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11 || summary.bytes != 2810784 { return Err("native archive contract".into()); }
    let bytes = bounded(archive, 1048576)?;
    if bytes.len() != 466395 || bytes.get(..8) != Some(&b"KHC1ARC\0"[..]) { return Err("archive extent".into()); }
    let mut pos = 32usize.checked_add(get32(&bytes, 20)?).ok_or("manifest extent")?;
    let mut report = String::from("{\"byte_exact\":true,\"public_archive_verified\":true,\"phase_names\":[\"wire\",\"alphabet_forest\",\"grammar_setup\",\"token_runs\",\"inverse\",\"CRC_capacity\"],\"rows\":[");
    let mut count = 0;
    for entry in entries {
        if entry.is_directory || entry.original_size > 1048576 ||
            !entry.name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
            return Err("fixed corpus entry contract".into());
        }
        let raw = bounded(&corpus.join(&entry.name), 1048576)?;
        if raw.len() as u64 != entry.original_size || raw.is_empty() { return Err("source extent".into()); }
        let length = get32(&bytes, pos)?;
        pos = pos.checked_add(4).ok_or("prefix overflow")?;
        if !(40..=raw.len()+40).contains(&length) { return Err("frame extent".into()); }
        let end = pos.checked_add(length).ok_or("frame overflow")?;
        let frame = bytes.get(pos..end).ok_or("frame unavailable")?;
        if get32(frame, 12)? != raw.len() { return Err("frame raw extent".into()); }
        for round in 0..10 {
            let started = Instant::now();
            let public = khc::decompress_block(frame).map_err(|e| e.to_string())?;
            let public_ns = started.elapsed().as_nanos();
            if public != raw { return Err("public byte mismatch".into()); }
            drop(public);
            let started = Instant::now();
            let (plain, stats) = profile::decode(frame)?;
            let total_ns = started.elapsed().as_nanos();
            let phases = profile::decode_phases();
            if plain != raw || phases.iter().sum::<u128>() > total_ns ||
                (stats.method != 1 && phases != [0; 6]) || stats.raw != raw.len() {
                return Err("profile byte/phase contract".into());
            }
            if round > 0 {
                if count > 0 { report.push(','); }
                write!(&mut report, "{{\"name\":{:?},\"iteration\":{},\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"public_ns\":{},\"total_ns\":{},\"phase_ns\":{:?},\"runs\":{},\"branches\":{},\"forest_capacity\":{},\"phase_capacity_bound\":{}}}",
                    entry.name,round,raw.len(),frame.len(),stats.method,public_ns,total_ns,phases,
                    stats.runs,stats.branches,stats.forest_capacity,stats.phase_capacity_bound).map_err(|_| "report")?;
                count += 1;
                if report.len() > 32700 { return Err("report output bound".into()); }
            }
        }
        pos = end.checked_add(4).ok_or("file CRC extent")?;
        if pos > bytes.len() { return Err("file CRC extent".into()); }
    }
    if count != 99 || bytes.get(pos..) != Some(&b"KHC1END\0"[..]) { return Err("archive final extent".into()); }
    report.push_str("]}");
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("native_profile: {error}");
        std::process::exit(1);
    }
}

