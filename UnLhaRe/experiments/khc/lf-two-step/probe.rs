//! LF二歩：独立cycle oracle・有限実last・同EXE paired復号。
mod boundary;
#[allow(dead_code)]
#[path = "candidate_block.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod old;
use std::{fmt::Write, fs::File, io::Read, path::Path, time::Instant};
use unlhare::{Limits, khc};
fn oracle(next: &[usize], primary: usize) -> std::result::Result<Vec<u8>, (&'static str, usize)> {
    let mut seen = [false; 8];
    let n = next.len();
    let mut row = primary;
    let mut plain = vec![0; n - 1];
    for step in 0..n {
        if seen[row] {
            return Err(("LF cycle inconsistent", step));
        }
        seen[row] = true;
        if step > 0 {
            plain[n - 1 - step] = if row % 2 == 0 { 255 } else { (row * 47) as u8 };
        }
        row = next[row];
    }
    if row != primary {
        return Err(("LF cycle/sentinel inconsistent", n));
    }
    Ok(plain)
}
fn permutations(
    next: &mut [usize],
    at: usize,
    count: &mut usize,
    rejects: &mut usize,
) -> Result<(), String> {
    if at == next.len() {
        for primary in 0..next.len() {
            let a = oracle(next, primary);
            let b = new::graph(next, primary);
            if a != b {
                return Err(format!("graph step/bytes drift {next:?}/{primary}"));
            }
            if a.is_err() {
                *rejects += 1;
            }
            *count += 1;
        }
    } else {
        for other in at..next.len() {
            next.swap(at, other);
            permutations(next, at + 1, count, rejects)?;
            next.swap(at, other);
        }
    }
    Ok(())
}
fn primitive_case(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<bool, String> {
    let a = old::primitive(last, primary, alphabet);
    let b = new::primitive(last, primary, alphabet);
    if a.as_ref().map(|r| &r.0) != b.as_ref().map(|r| &r.0) {
        return Err("primitive accept/bytes/error drift".into());
    }
    if let (Ok(a), Ok(b)) = (&a, &b) {
        if b.1 != a.1 * 3 {
            return Err("primitive peak capacity".into());
        }
    }
    Ok(a.is_ok())
}
fn primitive_contract() -> Result<(usize, usize, usize, usize), String> {
    let mut graphs = 0;
    let mut short = 0;
    for n in 1..=8 {
        let mut next: Vec<_> = (0..n).collect();
        permutations(&mut next, 0, &mut graphs, &mut short)?;
    }
    if graphs != 362879 {
        return Err("permutation coverage".into());
    }
    let mut columns = 0;
    let mut accepted = 0;
    for n in 1..=8 {
        for code in 0..3usize.pow(n as u32) {
            let mut value = code;
            let mut last = vec![0; n];
            let mut present = [false; 257];
            for symbol in &mut last {
                *symbol = [0, 1, 256][value % 3];
                value /= 3;
                present[*symbol as usize] = true;
            }
            let alphabet: Vec<_> = (0..=256)
                .filter(|&s| present[s])
                .map(|s| s as u16)
                .collect();
            for primary in 0..n {
                accepted += usize::from(primitive_case(&last, primary, &alphabet)?);
                columns += 1;
            }
        }
    }
    for (last, primary, alphabet) in [
        (&[][..], 0, &[][..]),
        (&[0][..], 0, &[0][..]),
        (&[0, 257][..], 0, &[0, 256][..]),
        (&[0, 1][..], 2, &[0, 1][..]),
        (&[0, 1][..], 1, &[0, 1][..]),
        (&[0, 1][..], 0, &[0][..]),
        (&[0, 1][..], 0, &[0, 257][..]),
    ] {
        primitive_case(last, primary, alphabet)?;
    }
    let mut largest = vec![1; (1 << 20) + 1];
    largest[1 << 20] = 0;
    if !primitive_case(&largest, 1 << 20, &[0, 1])? {
        return Err("maximum inverse".into());
    }
    largest.push(1);
    if primitive_case(&largest, 1 << 20, &[0, 1])? {
        return Err("oversize inverse accepted".into());
    }
    Ok((graphs, short, columns, accepted))
}
fn exact(frame: &[u8], raw: &[u8]) -> Result<(), String> {
    let (a, sa) = old::decode(frame)?;
    let (b, mut sb) = new::decode(frame)?;
    if a != raw || b != raw || khc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
        return Err("decoder bytes".into());
    }
    if sb.phase_capacity_bound > 67108864 {
        return Err("candidate RAM gate".into());
    }
    sb.inverse_capacity = sa.inverse_capacity;
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
    let (graphs, short, columns, accepted) = primitive_contract()?;
    let boundary = boundary::run()?;
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
        "{{\"graphs\":{graphs},\"short_rejected\":{short},\"columns\":{columns},\"columns_accepted\":{accepted},\"boundary_cases\":{boundary},\"finite\":{finite},\"decoder_checks\":{checks},\"rejected\":{rejects},\"byte_exact\":true,\"encoder_unchanged\":true,\"reversed\":{reversed},\"rows\":["
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
                    (
                        p,
                        new::inverse_time(),
                        s.inverse_capacity,
                        s.phase_capacity_bound,
                    )
                } else {
                    let (p, s) = old::decode(std::hint::black_box(frame))?;
                    (
                        p,
                        old::inverse_time(),
                        s.inverse_capacity,
                        s.phase_capacity_bound,
                    )
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
    report.push_str("]}");
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
