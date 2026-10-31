//! BoundProgram: 同wire有限契約と構築込みpaired全復号。
mod boundary;
#[allow(dead_code)]
#[path = "candidate_block.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod old;
use std::{fmt::Write, fs::File, io::Read, path::Path, time::Instant};
use unlhare::{Limits, khc};
fn exact(frame: &[u8], raw: &[u8]) -> Result<(), String> {
    let (a, sa) = old::decode(frame)?;
    let (b, mut sb) = new::decode(frame)?;
    if a != raw || b != raw || khc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
        return Err("decoder bytes".into());
    }
    if sb.phase_capacity_bound > 67108864 {
        return Err("candidate RAM gate".into());
    }
    sb.forest_capacity = sa.forest_capacity;
    sb.phase_capacity_bound = sa.phase_capacity_bound;
    if format!("{sa:?}") != format!("{sb:?}") {
        return Err("nonRAM stats drift".into());
    }
    Ok(())
}
fn malformed(frame: &[u8], raw: &[u8]) -> Result<(usize, usize), String> {
    let mut checks = 0;
    let mut rejects = 0;
    let mut check = |bytes: &[u8]| -> Result<(), String> {
        let a = old::decode(bytes).map(|r| r.0);
        let b = new::decode(bytes).map(|r| r.0);
        let c = khc::decompress_block(bytes).map_err(|e| e.to_string());
        if a != b || a.is_ok() != c.is_ok() {
            return Err("malformed drift".into());
        }
        for r in [a, b, c] {
            checks += 1;
            match r {
                Ok(p) if p == raw => (),
                Ok(_) => return Err("wrong-byte acceptance".into()),
                Err(_) => rejects += 1,
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
    Ok((checks, rejects))
}
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
fn get32(b: &[u8], at: usize) -> usize {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if !(3..=4).contains(&args.len()) {
        return Err("archive/corpus[/reverse]".into());
    }
    let reversed = args.len() == 4;
    let (boundary, mut geometry_states, mut cdf_rows) = boundary::run()?;
    let mut finite = 0;
    let mut checks = 0;
    let mut rejects = 0;
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
            let frame = khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                .map_err(|e| e.to_string())?;
            if old::encode_hybrid(&raw, true)?.0 != frame
                || new::encode_hybrid(&raw, true)?.0 != frame
            {
                return Err("encoder byte drift".into());
            }
            exact(&frame, &raw)?;
            finite += 1;
            if n == 4096 && pattern == 1 {
                let (c, r) = malformed(&frame, &raw)?;
                checks += c;
                rejects += r;
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
    let mut pos = 32 + get32(&bytes, 20);
    let mut report = format!(
        "{{\"boundary_cases\":{boundary},\"finite\":{finite},\"decoder_checks\":{checks},\"rejected\":{rejects},\"byte_exact\":true,\"encoder_unchanged\":true,\"reversed\":{reversed},\"rows\":["
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
        let length = get32(&bytes, pos);
        pos += 4;
        let frame = bytes.get(pos..pos + length).ok_or("frame extent")?;
        pos += length + 4;
        exact(frame, &raw)?;
        if frame[10] == 1 {
            let (geometry, rows) = new::binding_contract(frame)?;
            if (geometry, rows) != (72846, 872448) {
                return Err("binding finite contract".into());
            }
            geometry_states += geometry;
            cdf_rows += rows;
        }
        let a = old::encode_hybrid(&raw, true)?.0;
        let b = new::encode_hybrid(&raw, true)?.0;
        if a != b
            || a != khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                .map_err(|e| e.to_string())?
        {
            return Err("real encoder drift".into());
        }
        drop(a);
        drop(b);
        let mut old_ns = [0u128; 9];
        let mut new_ns = [0u128; 9];
        let mut old_inv = [0u128; 9];
        let mut new_inv = [0u128; 9];
        let mut old_cap = 0;
        let mut new_cap = 0;
        for round in 0..10 {
            for newer in if reversed {
                [true, false]
            } else {
                [false, true]
            } {
                let begin = Instant::now();
                let (plain, inverse, capacity, bound) = if newer {
                    let (p, s) = new::decode(std::hint::black_box(frame))?;
                    (p, 0u128, s.inverse_capacity, s.phase_capacity_bound)
                } else {
                    let (p, s) = old::decode(std::hint::black_box(frame))?;
                    (p, 0u128, s.inverse_capacity, s.phase_capacity_bound)
                };
                let total = begin.elapsed().as_nanos();
                if plain != raw || inverse > total || bound > 67108864 {
                    return Err("timed bytes/capacity".into());
                }
                if newer {
                    new_cap = capacity
                } else {
                    old_cap = capacity
                }
                if round > 0 {
                    if newer {
                        new_ns[round - 1] = total;
                        new_inv[round - 1] = inverse
                    } else {
                        old_ns[round - 1] = total;
                        old_inv[round - 1] = inverse
                    }
                }
            }
        }
        if index > 0 {
            report.push(',');
        }
        write!(&mut report,"{{\"name\":{:?},\"method\":{},\"raw\":{},\"frame\":{},\"old_ns\":{:?},\"new_ns\":{:?},\"old_inverse_ns\":{:?},\"new_inverse_ns\":{:?},\"old_inverse_bytes\":{},\"new_inverse_peak_bytes\":{}}}",entry.name,frame[10],raw.len(),frame.len(),old_ns,new_ns,old_inv,new_inv,old_cap,new_cap).map_err(|_|"report")?;
    }
    if bytes.get(pos..) != Some(&b"KHC1END\0"[..]) || report.len() > 32768 {
        return Err("archive/report final".into());
    }
    write!(
        &mut report,
        "],\"geometry_states\":{geometry_states},\"cdf_rows\":{cdf_rows}}}"
    )
    .map_err(|_| "report")?;
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
