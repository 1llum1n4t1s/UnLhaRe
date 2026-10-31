//! 同wireの整数CDF閾値選択：有限E2Eと同条件9paired測定。
#[allow(dead_code)]
#[path = "candidate_block_v2.rs"]
mod new;
#[allow(dead_code)]
#[path = "../mdl-rans/baseline_block.rs"]
mod old;
use std::{fs::File, io::Read};
fn encoded(raw: &[u8]) -> Result<(Vec<u8>, Vec<u8>, [usize; 7]), String> {
    let before = old::encode_hybrid(raw, true)?.0;
    let after = new::encode_hybrid(raw, true)?.0;
    let trace = [0usize; 7];
    for frame in [&before, &after] {
        if old::decode(frame)?.0 != raw
            || new::decode(frame)?.0 != raw
            || unlhare::khc::decompress_block(frame).map_err(|e| e.to_string())? != raw
        {
            return Err("self/cross/public byte restoration".into());
        }
    }
    if before != after {
        return Err("encoder frame changed".into());
    }
    if trace[0] > raw.len() * 64
        || trace[1] > raw.len()
        || trace[4] > trace[3]
        || trace[3] > trace[2]
    {
        return Err("parse/budget trace".into());
    }
    Ok((before, after, trace))
}
fn malformed(raw: &[u8], frame: &[u8]) -> Result<(usize, usize), String> {
    let mut cases = 0;
    let mut rejects = 0;
    let mut check = |bytes: &[u8]| -> Result<(), String> {
        let a = old::decode(bytes).map(|r| r.0);
        let b = new::decode(bytes).map(|r| r.0);
        let c = unlhare::khc::decompress_block(bytes).map_err(|e| e.to_string());
        if a.is_ok() != b.is_ok() || a.is_ok() != c.is_ok() {
            return Err("decoder rejection drift".into());
        }
        for result in [a, b, c] {
            if let Ok(plain) = result {
                if plain != raw {
                    return Err("corrupt wrong-byte acceptance".into());
                }
            } else {
                rejects += 1;
            }
            cases += 1;
        }
        if old::decode(frame)?.0 != raw
            || new::decode(frame)?.0 != raw
            || unlhare::khc::decompress_block(frame).map_err(|e| e.to_string())? != raw
        {
            return Err("same-process recovery".into());
        }
        Ok(())
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
    Ok((cases, rejects))
}
fn contract() -> Result<(usize, usize, usize, usize), String> {
    let numeric = new::cost_contract()?;
    let mut vectors = 0;
    let mut cases = 0;
    let mut rejects = 0;
    for n in [0, 1, 2, 3, 255, 256, 257, 4095, 4096, 4097, 65536, 1 << 20] {
        for pattern in 0..4 {
            let mut state = 0x735194afu32;
            let raw: Vec<u8> = (0..n)
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
            encoded(&raw)?;
            vectors += 1;
        }
    }
    // 15byte bodyと一度ずつのseparatorで、short-root/window末尾を実codec経路へ通す。
    let mut short = Vec::new();
    for separator in 0..128u8 {
        short.extend((0..15).map(|i| 128 + ((i * 37 + 19) % 128) as u8));
        short.push(separator);
    }
    let (_, _, trace) = encoded(&short)?;
    let _ = trace;
    vectors += 1;
    for raw in [
        vec![b'a'; 4096],
        (0..4096).map(|i| b'A' + (i % 26) as u8).collect(),
    ] {
        let (_, frame, _) = encoded(&raw)?;
        if frame[10] != 1 || frame.len() <= 40 {
            return Err("compressed witnesses".into());
        }
        let (n, r) = malformed(&raw, &frame)?;
        cases += n;
        rejects += r;
    }
    if new::encode_hybrid(&vec![128; (1 << 20) + 1], true).is_ok() {
        return Err("oversized encoded".into());
    }
    Ok((numeric, vectors, cases, rejects))
}
fn finite() -> Result<(), String> {
    let paths: Vec<_> = std::env::args().skip(1).collect();
    if paths.len() != 11 {
        return Err("11 fixed inputs".into());
    }
    let (numeric, vectors, cases, rejects) = contract()?;
    let mut rows = Vec::new();
    rows.try_reserve_exact(11)
        .map_err(|_| "result allocation")?;
    let mut old_sum = 0usize;
    let mut new_sum = 0usize;
    let mut changed = 0usize;
    for (index, path) in paths.iter().enumerate() {
        let file = File::open(path).map_err(|e| e.to_string())?;
        let size = usize::try_from(file.metadata().map_err(|e| e.to_string())?.len())
            .map_err(|_| "file extent")?;
        if size > 1 << 20 {
            return Err("input bound".into());
        }
        let mut raw = Vec::new();
        raw.try_reserve_exact(size + 1)
            .map_err(|_| "input allocation")?;
        file.take((size + 1) as u64)
            .read_to_end(&mut raw)
            .map_err(|e| e.to_string())?;
        if raw.len() != size {
            return Err("source changed".into());
        }
        let (before, after, trace) = encoded(&raw)?;
        old_sum += before.len();
        new_sum += after.len();
        changed += trace[3];
        rows.push(format!("{{\"index\":{index},\"raw\":{size},\"old_bytes\":{},\"new_bytes\":{},\"old_method\":{},\"new_method\":{},\"comparisons\":{},\"first_budget_position\":{},\"choices\":{},\"changed\":{},\"shorter\":{},\"cost_evaluations\":{},\"match_tokens\":{}}}",before.len(),after.len(),before[10],after[10],trace[0],trace[1],trace[2],trace[3],trace[4],trace[5],trace[6]));
    }
    println!(
        "{{\"byte_exact\":true,\"numeric_contracts\":{numeric},\"finite_raw_cases\":{vectors},\"malformed_decoder_checks\":{cases},\"rejected_decoder_checks\":{rejects},\"files\":11,\"old_frames\":{old_sum},\"new_frames\":{new_sum},\"changed\":{changed},\"timing_evidence\":false,\"rows\":[{}]}}",
        rows.join(",")
    );
    Ok(())
}
fn timed_encode(raw: &[u8], newer: bool) -> Result<(Vec<u8>, u128), String> {
    let start = std::time::Instant::now();
    let frame = if newer {
        new::encode_hybrid(std::hint::black_box(raw), true)?.0
    } else {
        old::encode_hybrid(std::hint::black_box(raw), true)?.0
    };
    let time = start.elapsed().as_nanos();
    Ok((frame, time))
}
fn timed_decode(frame: &[u8], newer: bool) -> Result<(Vec<u8>, u128), String> {
    let start = std::time::Instant::now();
    let plain = if newer {
        new::decode(std::hint::black_box(frame))?.0
    } else {
        old::decode(std::hint::black_box(frame))?.0
    };
    let time = start.elapsed().as_nanos();
    Ok((plain, time))
}
fn measure(path: &str, reverse: bool) -> Result<(), String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let size =
        usize::try_from(file.metadata().map_err(|e| e.to_string())?.len()).map_err(|_| "size")?;
    if size == 0 || size > 1 << 20 {
        return Err("timing input extent".into());
    }
    let mut raw = Vec::new();
    raw.try_reserve_exact(size + 1)
        .map_err(|_| "timing allocation")?;
    file.take((size + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    if raw.len() != size {
        return Err("timing source drift".into());
    }
    let (before, after, _) = encoded(&raw)?;
    // 同じEXE・入力・モデルでwarm1。検査/破棄は時計の外、測定順はpairごとに交互。
    for newer in [false, true] {
        let (frame, _) = timed_encode(&raw, newer)?;
        let (plain, _) = timed_decode(&frame, newer)?;
        if frame != before || plain != raw {
            return Err("warm drift".into());
        }
    }
    let mut oe = [0u128; 9];
    let mut ne = [0u128; 9];
    let mut od = [0u128; 9];
    let mut nd = [0u128; 9];
    for pair in 0..9 {
        let first = (pair % 2 == 0) ^ reverse;
        for newer in [!first, first] {
            let (frame, elapsed) = timed_encode(&raw, newer)?;
            if frame != before {
                return Err("timed frame drift".into());
            }
            if newer {
                ne[pair] = elapsed;
            } else {
                oe[pair] = elapsed;
            }
        }
        for newer in [!first, first] {
            let frame = if newer { &after } else { &before };
            let (plain, elapsed) = timed_decode(frame, newer)?;
            if plain != raw {
                return Err("timed restore drift".into());
            }
            if newer {
                nd[pair] = elapsed;
            } else {
                od[pair] = elapsed;
            }
        }
    }
    if [oe, ne, od, nd].iter().flatten().any(|&n| n == 0) {
        return Err("timing resolution".into());
    }
    println!(
        "{{\"byte_exact\":true,\"raw\":{size},\"bytes\":{},\"method\":{},\"reversed\":{reverse},\"old_encode_ns\":{:?},\"new_encode_ns\":{:?},\"old_decode_ns\":{:?},\"new_decode_ns\":{:?}}}",
        before.len(),
        before[10],
        oe,
        ne,
        od,
        nd
    );
    Ok(())
}
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|v| v == "--measure") {
        if args.len() != 3 || !matches!(args[2].as_str(), "normal" | "reverse") {
            return Err("measure arguments".into());
        }
        measure(&args[1], args[2] == "reverse")
    } else {
        finite()
    }
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
