//! 独立pixel参照、有限E2E、実保存frame一致、実サイズscreen。速度計測ではない。
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod baseline;
#[allow(dead_code)]
#[path = "codec.rs"]
mod record;
use std::{fmt::Write, fs::File, io::Read, path::Path};
use unlhare::{Limits, khc};
type Result<T> = std::result::Result<T, String>;
fn read(path: &Path, max: usize) -> Result<Vec<u8>> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("file extent".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(max + 1)
        .map_err(|_| "input allocation")?;
    file.take((max + 1) as u64)
        .read_to_end(&mut v)
        .map_err(|e| e.to_string())?;
    if v.len() > max {
        return Err("file changed extent".into());
    }
    Ok(v)
}
fn get32(v: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        v.get(at..at + 4)
            .ok_or("u32 extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn pixel(v: &[u8], width: usize, row: isize, col: isize, before: usize) -> Result<usize> {
    if row < 0 || col < 0 || col as usize >= width {
        return Ok(0);
    }
    let p = row as usize * width + col as usize;
    if p >= before {
        return Err("reference future bit".into());
    }
    Ok(usize::from((v[p / 8] >> (7 - p % 8)) & 1))
}
fn windows_contract(v: &[u8], stride: usize) -> Result<usize> {
    let width = stride * 8;
    let mut left = 0;
    let mut cases = 0;
    for (i, &byte) in v.iter().enumerate() {
        if i % stride == 0 {
            left = 0
        }
        let (a, b) = record::windows(v, i, stride)?;
        for shift in (0..8).rev() {
            let at = i * 8 + 7 - shift;
            let row = (at / width) as isize;
            let col = (at % width) as isize;
            let mut expected = 0;
            for k in 1..=4 {
                expected |= pixel(v, width, row, col - k, at)? << (k - 1)
            }
            for k in -2..=3 {
                expected |= pixel(v, width, row - 1, col + k, at)? << (4 + 3 - k)
            }
            for k in 0..=1 {
                expected |= pixel(v, width, row - 2, col + k, at)? << (10 + 1 - k)
            }
            if expected != record::context(left, a, b, shift) {
                return Err("independent pixel context".into());
            }
            left = ((left << 1) | usize::from((byte >> shift) & 1)) & 15;
            cases += 1;
        }
    }
    Ok(cases)
}
fn selector_reference(v: &[u8]) -> (usize, usize) {
    let n = v.len().min(16384);
    let max = n.saturating_sub(1).min(1024);
    if max == 0 {
        return (1, 0);
    }
    let mut best = 1;
    let mut minimum = usize::MAX;
    let mut work = 0;
    for lag in 1..=max {
        let mut cost = 0;
        for at in max..n {
            if v[at] != 0 && v[at] != 255 {
                for bit in 0..8 {
                    cost += usize::from((v[at] >> bit) & 1 != (v[at - lag] >> bit) & 1)
                }
                work += 1;
            }
        }
        if cost < minimum {
            minimum = cost;
            best = lag
        }
    }
    (best, work)
}
fn malformed(frame: &[u8], raw: &[u8]) -> Result<(usize, usize)> {
    let mut cases = 0;
    let mut rejects = 0;
    let mut check = |bad: &[u8]| -> Result<()> {
        match record::decode(bad) {
            Ok((v, s)) => {
                if v != raw || s.phase > 67108864 {
                    return Err("wrong-byte malformed acceptance".into());
                }
            }
            Err(_) => rejects += 1,
        }
        cases += 1;
        if raw.len() <= 4096 && record::decode(frame)?.0 != raw {
            return Err("small recovery".into());
        }
        Ok(())
    };
    let cuts = if raw.len() <= 4096 { 40 } else { 6 };
    for n in 0..cuts {
        check(&frame[..n])?
    }
    let positions: Vec<usize> = if raw.len() <= 4096 {
        (0..40).collect()
    } else {
        vec![0, 8, 10, 11, 12, 16, 20, 22, 24, 26, 28, 36]
    };
    for at in positions {
        let mut bad = frame.to_vec();
        bad[at] ^= 128;
        record::reseal(&mut bad)?;
        check(&bad)?
    }
    let samples = if raw.len() <= 4096 { 16 } else { 3 };
    for i in 0..samples {
        let at = 40 + (frame.len() - 40) * i / samples;
        check(&frame[..at])?;
        if frame.len() > 40 {
            let mut bad = frame.to_vec();
            let at = 40 + (frame.len() - 41) * i / samples;
            bad[at] ^= 1;
            record::reseal(&mut bad)?;
            check(&bad)?
        }
    }
    for at in 32..36 {
        let mut bad = frame.to_vec();
        bad[at] ^= 1;
        check(&bad)?
    }
    let mut extra = frame.to_vec();
    extra.push(0);
    check(&extra)?;
    extra[16..20].copy_from_slice(&((frame.len() - 40 + 1) as u32).to_le_bytes());
    record::reseal(&mut extra)?;
    check(&extra)?;
    if record::decode(frame)?.0 != raw {
        return Err("final recovery".into());
    }
    Ok((cases, rejects))
}
fn verify(old: &[u8], new: &[u8], raw: &[u8]) -> Result<()> {
    if baseline::decode(old)?.0 != raw
        || khc::decompress_block(old).map_err(|e| e.to_string())? != raw
    {
        return Err("baseline bytes".into());
    }
    let (v, s) = record::decode(new)?;
    if v != raw
        || s.phase > 67108864
        || record::decode(old).is_ok()
        || baseline::decode(new).is_ok()
        || khc::decompress_block(new).is_ok()
    {
        return Err("record bytes/capacity/magic".into());
    }
    if new[10] == 2 && &new[40..] != old {
        return Err("legacy nested frame differs".into());
    }
    Ok(())
}
fn wrap_legacy(raw: &[u8], body: &[u8]) -> Result<Vec<u8>> {
    let mut f = vec![0u8; 40];
    f[..8].copy_from_slice(record::MAGIC);
    f[8..10].copy_from_slice(&1u16.to_le_bytes());
    f[10] = 2;
    f[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    f[16..20].copy_from_slice(&(body.len() as u32).to_le_bytes());
    f[28..32].copy_from_slice(&baseline::crc32(raw).to_le_bytes());
    f.extend_from_slice(body);
    record::reseal(&mut f)?;
    Ok(f)
}
fn pattern(n: usize, p: usize) -> Vec<u8> {
    let mut state = 0x713549abu32;
    (0..n)
        .map(|i| match p {
            0 => 0,
            1 => (i % 256) as u8,
            _ => {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            }
        })
        .collect()
}
fn execute() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus arguments".into());
    }
    let mut probability_cases = 0;
    for p in 1..32768u32 {
        for one in [false, true] {
            let expected = if one {
                p - (p + 31) / 32
            } else {
                p + (32768 - p + 31) / 32
            };
            if record::update(p as u16, one) != expected.clamp(1, 32767) as u16 {
                return Err("integer update reference".into());
            }
            probability_cases += 1
        }
    }
    let mut contexts = 0;
    let mut selectors = 0;
    for n in [0, 1, 2, 7, 8, 9, 255, 256, 257, 1023, 1024, 1025, 2049] {
        let v = pattern(n, 2);
        for stride in [1, 2, 3, 7, 16, 255, 256, 1023, 1024] {
            contexts += windows_contract(&v, stride)?
        }
        let actual = record::select_stride(&v)?;
        let expected = selector_reference(&v);
        if (actual.0, actual.1) != expected {
            return Err("selector independent reference".into());
        }
        selectors += 1;
    }
    for n in [0, 1, 257, 4096] {
        for byte in [0, 255] {
            if record::select_stride(&vec![byte; n])?.0 != 1 {
                return Err("selector tie/default".into());
            }
            selectors += 1
        }
    }
    let oversized = vec![0; 1048577];
    let mut oversize = 0;
    for rejected in [
        record::encode(&oversized).is_err(),
        record::encode_record(&oversized, 1).is_err(),
        record::select_stride(&oversized).is_err(),
        record::encode_record(b"x", 0).is_err(),
        record::encode_record(b"x", 1025).is_err(),
    ] {
        if !rejected {
            return Err("input/stride bound".into());
        }
        oversize += 1
    }
    drop(oversized);
    let mut finite = 0;
    let mut forced = 0;
    let mut checks = 0;
    let mut rejects = 0;
    let mut bound = 0;
    let mut modes = [false; 3];
    for n in [
        0, 1, 2, 255, 256, 257, 1023, 1024, 1025, 4096, 65536, 1048576,
    ] {
        for p in 0..3 {
            let raw = pattern(n, p);
            let (old, old_s) = baseline::encode_hybrid(&raw, true)?;
            if old
                != khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                    .map_err(|e| e.to_string())?
            {
                return Err("finite public encoder".into());
            }
            let (new, s) = record::encode(&raw)?;
            verify(&old, &new, &raw)?;
            if s.phase > 67108864 || s.comparisons > 16384 * 1024 {
                return Err("finite resource".into());
            }
            bound = bound.max(s.phase).max(old_s.phase_capacity_bound);
            modes[s.method as usize] = true;
            let (c, r) = malformed(&new, &raw)?;
            checks += c;
            rejects += r;
            finite += 1;
        }
    }
    for stride in [1, 2, 7, 1024] {
        for p in 0..2 {
            let raw = pattern(4097, p);
            let (new, s) = record::encode_record(&raw, stride)?;
            if record::decode(&new)?.0 != raw {
                return Err("forced record bytes".into());
            }
            modes[s.method as usize] = true;
            bound = bound.max(s.phase);
            forced += 1;
            let (c, r) = malformed(&new, &raw)?;
            checks += c;
            rejects += r;
        }
    }
    let raw = b"legacy arithmetic grammar\n".repeat(200);
    let (old, _) = baseline::encode_hybrid(&raw, true)?;
    let wrapped = wrap_legacy(&raw, &old)?;
    verify(&old, &wrapped, &raw)?;
    modes[2] = true;
    if modes != [true; 3] {
        return Err("all wire methods untested".into());
    }
    let corpus = Path::new(&args[2]);
    let archive = Path::new(&args[1]);
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11
        || khc::verify_archive(archive, &Limits::default())
            .map_err(|e| e.to_string())?
            .bytes
            != 2810784
    {
        return Err("native archive contract".into());
    }
    let bytes = read(archive, 1048576)?;
    if bytes.len() != 466395 {
        return Err("archive extent".into());
    }
    let mut position = 32 + get32(&bytes, 20)?;
    let mut old_total = 0;
    let mut new_total = 0;
    let mut report = format!(
        "{{\"byte_exact\":true,\"public_baseline_exact\":true,\"finite_encodings\":{finite},\"forced_encodings\":{forced},\"probability_cases\":{probability_cases},\"pixel_context_cases\":{contexts},\"selector_cases\":{selectors},\"bound_rejects\":{oversize},\"all_methods\":true,\"speed_evidence\":false,\"rows\":["
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
        let raw = read(&corpus.join(&entry.name), 1048576)?;
        let length = get32(&bytes, position)?;
        position += 4;
        let saved = bytes
            .get(position..position + length)
            .ok_or("saved frame")?;
        position += length + 4;
        let (old, old_s) = baseline::encode_hybrid(&raw, true)?;
        if old != saved
            || old
                != khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                    .map_err(|e| e.to_string())?
        {
            return Err("actual saved/public frame drift".into());
        }
        let (new, s) = record::encode(&raw)?;
        verify(&old, &new, &raw)?;
        if record::encode(&raw)?.0 != new {
            return Err("candidate nondeterminism".into());
        }
        if new.len() > raw.len() + 80 || s.phase > 67108864 || s.comparisons > 16384 * 1024 {
            return Err("real resource".into());
        }
        bound = bound.max(s.phase).max(old_s.phase_capacity_bound);
        let (c, r) = malformed(&new, &raw)?;
        checks += c;
        rejects += r;
        old_total += old.len();
        new_total += new.len();
        if index > 0 {
            report.push(',')
        }
        write!(&mut report,"{{\"name\":{:?},\"raw\":{},\"old_bytes\":{},\"new_bytes\":{},\"old_method\":{},\"new_method\":{},\"stride\":{},\"selector_positions\":{},\"comparisons\":{},\"bits_encoded\":{},\"phase\":{},\"reason\":{:?}}}",entry.name,raw.len(),old.len(),new.len(),old_s.method,s.method,s.stride,s.positions,s.comparisons,s.bits,s.phase,s.reason).map_err(|_|"report")?;
    }
    if bytes.get(position..) != Some(&b"KHC1END\0"[..]) || old_total != 465951 {
        return Err("archive/baseline total".into());
    }
    let full = new_total + 444 + 256;
    write!(&mut report,"],\"old_frame_bytes\":{old_total},\"new_frame_bytes\":{new_total},\"reserved_archive_estimate\":{full},\"size_gate\":{},\"decoder_checks\":{checks},\"rejected\":{rejects},\"logical_bound\":{bound}}}",full<=457415).map_err(|_|"report")?;
    if report.len() > 16384 {
        return Err("report size".into());
    }
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("record_bit: {e}");
        std::process::exit(1)
    }
}
