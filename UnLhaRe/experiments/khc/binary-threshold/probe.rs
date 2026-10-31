//! 製品method2/3の二値threshold：有限照合と同EXEのpaired復号。
#[allow(dead_code)]
#[path = "candidate_block.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod old;
use std::{fmt::Write, fs::File, io::Read, path::Path, time::Instant};
use unlhare::{Limits, khc};
fn bounded(path: &Path, maximum: usize) -> Result<Vec<u8>, String> {
    let mut f = File::open(path).map_err(|e| e.to_string())?;
    if f.metadata().map_err(|e| e.to_string())?.len() > maximum as u64 {
        return Err("input bound".into());
    }
    let mut b = Vec::new();
    f.read_to_end(&mut b).map_err(|e| e.to_string())?;
    if b.len() > maximum {
        return Err("changed input".into());
    }
    Ok(b)
}
fn exact(frame: &[u8], raw: &[u8]) -> Result<(), String> {
    if old::decode(frame)?.0 != raw
        || new::decode(frame)?.0 != raw
        || khc::decompress_block(frame).map_err(|e| e.to_string())? != raw
    {
        return Err("restore drift".into());
    }
    Ok(())
}
fn seal(frame: &mut [u8]) {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&frame[..36]);
    d.update(&frame[40..]);
    frame[36..40].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
}
fn malformed(frame: &[u8], raw: &[u8]) -> Result<(usize, usize), String> {
    let mut checks = 0;
    let mut rejected = 0;
    let mut check = |bytes: &[u8]| -> Result<(), String> {
        let a = old::decode(bytes).map(|r| r.0);
        let b = new::decode(bytes).map(|r| r.0);
        let c = khc::decompress_block(bytes).map_err(|e| e.to_string());
        if a != b || a.is_ok() != c.is_ok() {
            return Err("rejection/result drift".into());
        }
        for r in [a, b, c] {
            checks += 1;
            match r {
                Ok(p) if p == raw => (),
                Ok(_) => return Err("wrong-byte acceptance".into()),
                Err(_) => rejected += 1,
            }
        }
        exact(frame, raw)
    };
    for end in 0..40 {
        check(&frame[..end])?;
    }
    for at in 0..40 {
        let mut bad = frame.to_vec();
        bad[at] ^= 128;
        seal(&mut bad);
        check(&bad)?;
    }
    for i in 0..16 {
        check(&frame[..40 + (frame.len() - 40) * i / 16])?;
    }
    for i in 0..16 {
        let mut bad = frame.to_vec();
        let at = 40 + (frame.len() - 41) * i / 15;
        bad[at] ^= 1;
        seal(&mut bad);
        check(&bad)?;
    }
    let mut gap = frame.to_vec();
    gap[41..45].fill(255);
    seal(&mut gap);
    if old::decode(&gap).err().as_deref() != Some("range rounding gap")
        || new::decode(&gap).err().as_deref() != Some("range rounding gap")
    {
        return Err("gap witness".into());
    }
    check(&gap)?;
    let mut cut = frame[..frame.len() - 1].to_vec();
    let n = (cut.len() - 40) as u32;
    cut[24..28].copy_from_slice(&n.to_le_bytes());
    seal(&mut cut);
    if old::decode(&cut).err().as_deref() != Some("truncated range stream")
        || new::decode(&cut).err().as_deref() != Some("truncated range stream")
    {
        return Err("normalize witness".into());
    }
    check(&cut)?;
    let mut extra = frame.to_vec();
    extra.push(0);
    let n = (extra.len() - 40) as u32;
    extra[24..28].copy_from_slice(&n.to_le_bytes());
    seal(&mut extra);
    check(&extra)?;
    Ok((checks, rejected))
}
fn get32(b: &[u8], at: usize) -> usize {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if !(3..=4).contains(&args.len()) {
        return Err("archive/corpus[/reverse]".into());
    }
    let reversed = args.len() == 4;
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let numeric = new::numeric()?;
    let mut finite = 0;
    let mut forced = 0;
    let mut checks = 0;
    let mut rejects = 0;
    let mut witnesses = 0;
    for n in [0, 1, 2, 3, 255, 256, 257, 4095, 4096, 4097, 65536, 1 << 20] {
        for pattern in 0..4 {
            let mut state = 0x735194afu32;
            let raw: Vec<_> = (0..n)
                .map(|i| match pattern {
                    0 => b'a',
                    1 => (i % 256) as u8,
                    2 => {
                        state ^= state << 13;
                        state ^= state >> 17;
                        state ^= state << 5;
                        state as u8
                    }
                    _ => 128 + (i % 64) as u8,
                })
                .collect();
            let before =
                khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                    .map_err(|e| e.to_string())?;
            let after = new::encode_hybrid(&raw, true)?.0;
            if before != after {
                return Err("encoder byte drift".into());
            }
            exact(&before, &raw)?;
            finite += 1;
            for context in [3, 8] {
                if let Some(frame) = new::forced(&raw, context)? {
                    exact(&frame, &raw)?;
                    forced += 1;
                    if n == 4096 && pattern == 1 {
                        let (c, r) = malformed(&frame, &raw)?;
                        checks += c;
                        rejects += r;
                        witnesses += 1;
                    }
                }
            }
        }
    }
    if witnesses != 2 {
        return Err("both method witnesses".into());
    }
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    let summary = khc::verify_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11 || summary.bytes != 2810784 {
        return Err("archive contract".into());
    }
    let bytes = bounded(archive, 1048576)?;
    if bytes.len() != 466395 {
        return Err("archive extent".into());
    }
    let mut pos = 32 + get32(&bytes, 20);
    let mut output = format!(
        "{{\"numeric\":{numeric},\"finite\":{finite},\"forced\":{forced},\"decoder_checks\":{checks},\"rejected\":{rejects},\"gap_normalize_witnesses\":{witnesses},\"byte_exact\":true,\"encoder_byte_unchanged\":true,\"reversed\":{reversed},\"rows\":["
    );
    for (entry_index, entry) in entries.iter().enumerate() {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry contract".into());
        }
        let raw = bounded(&corpus.join(&entry.name), 1048576)?;
        let len = get32(&bytes, pos);
        pos += 4;
        let frame = bytes.get(pos..pos + len).ok_or("frame extent")?;
        pos += len + 4;
        exact(frame, &raw)?;
        let mut old_times = [0u128; 9];
        let mut new_times = [0u128; 9];
        for round in 0..10 {
            let sides = if reversed {
                [true, false]
            } else {
                [false, true]
            };
            for newer in sides {
                let begin = Instant::now();
                let plain = if newer {
                    new::decode(std::hint::black_box(frame))?.0
                } else {
                    old::decode(std::hint::black_box(frame))?.0
                };
                let elapsed = begin.elapsed().as_nanos();
                if plain != raw {
                    return Err("timed fullbyte".into());
                }
                if round > 0 {
                    if newer {
                        new_times[round - 1] = elapsed
                    } else {
                        old_times[round - 1] = elapsed
                    }
                }
            }
        }
        if entry_index > 0 {
            output.push(',');
        }
        write!(&mut output,"{{\"name\":{:?},\"method\":{},\"raw\":{},\"frame\":{},\"old_ns\":{:?},\"new_ns\":{:?}}}",entry.name,frame[10],raw.len(),frame.len(),old_times,new_times).map_err(|_|"report")?;
    }
    if bytes.get(pos..) != Some(&b"KHC1END\0"[..]) {
        return Err("archive final".into());
    }
    output.push_str("]}");
    if output.len() > 32768 {
        return Err("report bound".into());
    }
    println!("{output}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
