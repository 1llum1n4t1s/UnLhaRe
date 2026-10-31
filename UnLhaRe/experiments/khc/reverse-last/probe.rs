//! 逆last走査の独立実frame。サイズのみ、速度測定はしない。
#[allow(dead_code)]
#[path = "candidate_block.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod old;
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
fn encode(raw: &[u8], hybrid: bool, newer: bool) -> Result<(Vec<u8>, usize), String> {
    let (frame, stats) = if newer {
        if hybrid {
            new::encode_hybrid(raw, true)?
        } else {
            new::encode(raw)?
        }
    } else if hybrid {
        old::encode_hybrid(raw, true)?
    } else {
        old::encode(raw)?
    };
    if stats.phase_capacity_bound > 67108864 {
        return Err("encoder RAM gate".into());
    }
    Ok((frame, stats.phase_capacity_bound))
}
fn verify_pair(old_frame: &[u8], new_frame: &[u8], raw: &[u8]) -> Result<(), String> {
    if old::decode(old_frame)?.0 != raw
        || khc::decompress_block(old_frame).map_err(|e| e.to_string())? != raw
    {
        return Err("baseline bytes".into());
    }
    let (plain, stats) = new::decode(new_frame)?;
    if plain != raw || stats.phase_capacity_bound > 67108864 {
        return Err("new decoder bytes/capacity".into());
    }
    if new::decode(old_frame).is_ok()
        || old::decode(new_frame).is_ok()
        || khc::decompress_block(new_frame).is_ok()
    {
        return Err("magic mutual acceptance".into());
    }
    if new_frame[10] != 1 {
        let mut normalized = new_frame.to_vec();
        normalized[..8].copy_from_slice(&old_frame[..8]);
        old::reseal(&mut normalized)?;
        if normalized != old_frame {
            return Err("nonMDL drift beyond magic/CRC".into());
        }
    }
    Ok(())
}
fn malformed(frame: &[u8], raw: &[u8]) -> Result<(usize, usize), String> {
    let mut checks = 0;
    let mut rejects = 0;
    let mut check = |bytes: &[u8]| -> Result<(), String> {
        match new::decode(bytes) {
            Ok((p, s)) => {
                if p != raw || s.phase_capacity_bound > 67108864 {
                    return Err("malformed wrong-byte acceptance".into());
                }
            }
            Err(_) => rejects += 1,
        }
        checks += 1;
        if new::decode(frame)?.0 != raw {
            return Err("recovery bytes".into());
        }
        Ok(())
    };
    for n in 0..40 {
        check(&frame[..n])?;
    }
    for at in 0..40 {
        let mut bad = frame.to_vec();
        bad[at] ^= 128;
        new::reseal(&mut bad)?;
        check(&bad)?;
    }
    for i in 0..16 {
        check(&frame[..40 + (frame.len() - 40) * i / 16])?;
    }
    for i in 0..16 {
        let mut bad = frame.to_vec();
        let at = 40 + (frame.len() - 41) * i / 15;
        bad[at] ^= 1;
        new::reseal(&mut bad)?;
        check(&bad)?;
    }
    let mut extra = frame.to_vec();
    extra.push(0);
    check(&extra)?;
    Ok((checks, rejects))
}
fn digest(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for &b in bytes {
        hash = (hash ^ u64::from(b)).wrapping_mul(0x100000001b3);
    }
    format!("{hash:016X}")
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus arguments".into());
    }
    let mut finite = 0;
    let mut column_cases = 0;
    let mut checks = 0;
    let mut rejects = 0;
    let mut max_bound = 0;
    for n in [0, 1, 255, 256, 257, 4096, 4097, 65536, 1048576] {
        for pattern in 0..3 {
            let mut state = 0x735194afu32;
            let raw: Vec<u8> = (0..n)
                .map(|i| match pattern {
                    0 => b'a',
                    1 => 128 + (i % 64) as u8,
                    _ => {
                        state ^= state << 13;
                        state ^= state >> 17;
                        state ^= state << 5;
                        state as u8
                    }
                })
                .collect();
            new::column_contract(&raw)?;
            column_cases += 1;
            for hybrid in [false, true] {
                let (a, old_bound) = encode(&raw, hybrid, false)?;
                let (b, new_bound) = encode(&raw, hybrid, true)?;
                max_bound = max_bound.max(old_bound).max(new_bound);
                let strategy = if hybrid {
                    khc::BlockStrategy::BinaryAdaptive
                } else {
                    khc::BlockStrategy::Mdl
                };
                if a != khc::compress_block_with_strategy(&raw, strategy)
                    .map_err(|e| e.to_string())?
                {
                    return Err("public encoder baseline".into());
                }
                verify_pair(&a, &b, &raw)?;
                if n == 4096 && b[10] == 1 {
                    let (c, r) = malformed(&b, &raw)?;
                    checks += c;
                    rejects += r;
                }
                finite += 1;
            }
        }
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
    let mut old_total = 0;
    let mut new_total = 0;
    let mut old_mdl = 0;
    let mut new_mdl = 0;
    let mut report = format!(
        "{{\"finite_encodings\":{finite},\"column_cases\":{column_cases},\"byte_exact\":true,\"mutual_magic_rejection\":true,\"public_baseline_exact\":true,\"speed_evidence\":false,\"rows\":["
    );
    for (index, entry) in entries.iter().enumerate() {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry contract".into());
        }
        let raw = bounded(&corpus.join(&entry.name), 1048576)?;
        let length = get32(&bytes, position)?;
        position += 4;
        let saved = bytes
            .get(position..position.checked_add(length).ok_or("frame overflow")?)
            .ok_or("frame extent")?;
        position += length + 4;
        let mut sizes = [0usize; 4];
        let mut methods = [0u8; 4];
        let mut hashes = Vec::new();
        for (hybrid, offset) in [(false, 0), (true, 2)] {
            let (a, old_bound) = encode(&raw, hybrid, false)?;
            let (b, new_bound) = encode(&raw, hybrid, true)?;
            max_bound = max_bound.max(old_bound).max(new_bound);
            let strategy = if hybrid {
                khc::BlockStrategy::BinaryAdaptive
            } else {
                khc::BlockStrategy::Mdl
            };
            if a != khc::compress_block_with_strategy(&raw, strategy).map_err(|e| e.to_string())?
                || (hybrid && a != saved)
            {
                return Err("real baseline frame drift".into());
            }
            verify_pair(&a, &b, &raw)?;
            if encode(&raw, hybrid, true)?.0 != b {
                return Err("new frame nondeterminism".into());
            }
            if b[10] == 1 {
                let (c, r) = malformed(&b, &raw)?;
                checks += c;
                rejects += r;
            }
            sizes[offset] = a.len();
            sizes[offset + 1] = b.len();
            methods[offset] = a[10];
            methods[offset + 1] = b[10];
            hashes.push(digest(&a));
            hashes.push(digest(&b));
        }
        old_mdl += sizes[0];
        new_mdl += sizes[1];
        old_total += sizes[2];
        new_total += sizes[3];
        if index > 0 {
            report.push(',');
        }
        write!(&mut report,"{{\"name\":{:?},\"raw\":{},\"old_mdl\":{},\"new_mdl\":{},\"old_adaptive\":{},\"new_adaptive\":{},\"methods\":{:?},\"digests\":{:?}}}",entry.name,raw.len(),sizes[0],sizes[1],sizes[2],sizes[3],methods,hashes).map_err(|_|"report")?;
    }
    if bytes.get(position..) != Some(&b"KHC1END\0"[..])
        || old_total != 465951
        || checks == 0
        || report.len() > 16384
    {
        return Err("archive/finite final".into());
    }
    write!(&mut report,"],\"old_adaptive_bytes\":{old_total},\"new_adaptive_bytes\":{new_total},\"old_mdl_bytes\":{old_mdl},\"new_mdl_bytes\":{new_mdl},\"decoder_checks\":{checks},\"rejected\":{rejects},\"logical_encode_max\":{max_bound}}}").map_err(|_|"report")?;
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("{error}");
        std::process::exit(1)
    }
}
