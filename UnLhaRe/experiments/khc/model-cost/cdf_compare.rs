//! 整数CDF・mode契約とframe/encoder時間を独立比較する。
#[allow(dead_code)]
#[path = "cdf_codec.rs"]
mod new;
#[allow(dead_code)]
#[path = "cdf_base_codec.rs"]
mod old;
use std::{fs::File, io::Read, time::Instant};

fn numeric_contract() -> Result<(), String> {
    let mut quantize_cases = 0usize;
    let mut quantize_rejections = 0usize;
    let mut valid_modes = 0usize;
    let mut compare = |counts: [u32; 4], k: usize| -> Result<(), String> {
        let before = old::model::quantize(counts, k);
        let after = new::model::quantize(counts, k);
        if before != after {
            return Err(format!("quantize k={k} counts={counts:?}"));
        }
        quantize_cases += 1;
        match before {
            Ok(f) => {
                if old::model::leaf_mode(f, k) != new::model::leaf_mode(f, k)
                    || old::model::compact_frequency(f, k) != new::model::compact_frequency(f, k)
                {
                    return Err("mode/compact CDF".into());
                }
                valid_modes += 1;
            }
            Err(_) => quantize_rejections += 1,
        }
        Ok(())
    };
    for k in 2..=4 {
        compare([0; 4], k)?;
        for values in [
            [0, 1, 2, 3, 4, 5, 6, 7],
            [
                0,
                1,
                2,
                127,
                65535,
                old::model::CAP,
                old::model::CAP + 1,
                u32::MAX,
            ],
        ] {
            for code in 0..8usize.pow(k as u32) {
                let mut counts = [0; 4];
                for (i, count) in counts.iter_mut().enumerate().take(k) {
                    *count = values[(code / 8usize.pow(i as u32)) % 8];
                }
                compare(counts, k)?;
            }
        }
        let mut state = 0x73a419b2u32;
        for sample in 0..4096 {
            let mut counts = [0; 4];
            for count in counts.iter_mut().take(k) {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                *count = match sample % 4 {
                    0 => state % 129,
                    1 => state % (old::model::CAP / k as u32 + 1),
                    2 => state,
                    _ => 0,
                };
            }
            compare(counts, k)?;
        }
        for tail in k..4 {
            let mut bad = [0; 4];
            bad[tail] = 1;
            compare(bad, k)?;
        }
    }
    for k in [0, 1, 5, usize::MAX] {
        for counts in [[0; 4], [1; 4], [old::model::CAP; 4], [u32::MAX; 4]] {
            compare(counts, k)?;
        }
    }
    let mut cdf_rejections = 0usize;
    for (f, k) in [
        ([32768, 0, 0, 0], 1),
        ([8192; 4], 5),
        ([1, 32767, 0, 0], 2),
        ([16384, 16384, 1, 0], 2),
        ([16384, 16383, 0, 0], 2),
        ([10922, 10922, 10922, 0], 3),
        ([0; 4], 4),
    ] {
        let before = old::model::leaf_mode(f, k);
        let after = new::model::leaf_mode(f, k);
        let compact_before = old::model::compact_frequency(f, k);
        let compact_after = new::model::compact_frequency(f, k);
        if before.is_ok()
            || before != after
            || compact_before.is_ok()
            || compact_before != compact_after
        {
            return Err("CDF rejection".into());
        }
        cdf_rejections += 1;
    }
    println!(
        "{{\"bit_exact\":true,\"quantize_cases\":{},\"quantize_rejections\":{},\"valid_modes\":{},\"cdf_rejections\":{},\"uniform_vectors\":3}}",
        quantize_cases, quantize_rejections, valid_modes, cdf_rejections
    );
    Ok(())
}

fn execute() -> Result<(), String> {
    let argument = std::env::args().nth(1).ok_or("input")?;
    if argument == "--contract" {
        return numeric_contract();
    }
    let reversed = std::env::args().nth(2).as_deref() == Some("--reverse");
    let mut raw = Vec::new();
    raw.try_reserve_exact(old::MAX_INPUT + 1)
        .map_err(|_| "input allocation")?;
    match argument.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(argument)
                .map_err(|e| e.to_string())?
                .take((old::MAX_INPUT + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > old::MAX_INPUT {
        return Err("input bound".into());
    }
    let (reference, stats) = old::encode_hybrid(&raw, true)?;
    if new::encode_hybrid(&raw, true)?.0 != reference
        || old::decode(&reference)?.0 != raw
        || new::decode(&reference)?.0 != raw
    {
        return Err("warm frame/roundtrip".into());
    }
    let mut old_ns = [0u128; 9];
    let mut new_ns = [0u128; 9];
    for round in 0..9 {
        let order = if (round % 2 == 0) ^ reversed {
            [false, true]
        } else {
            [true, false]
        };
        for candidate in order {
            let started = Instant::now();
            let (frame, current) = if candidate {
                new::encode_hybrid(&raw, true).map(|(frame, stats)| (frame, stats.method))?
            } else {
                old::encode_hybrid(&raw, true).map(|(frame, stats)| (frame, stats.method))?
            };
            let ns = started.elapsed().as_nanos();
            if candidate {
                new_ns[round] = ns;
            } else {
                old_ns[round] = ns;
            }
            if frame != reference || current != stats.method {
                return Err("measured frame/method".into());
            }
            if old::decode(&frame)?.0 != raw || new::decode(&frame)?.0 != raw {
                return Err("self/cross roundtrip".into());
            }
        }
    }
    let mut cases = 0usize;
    let mut rejected = 0usize;
    let mut compare = |bytes: &[u8]| -> Result<(), String> {
        let before = old::decode(bytes).map(|p| p.0);
        let after = new::decode(bytes).map(|p| p.0);
        if before != after {
            return Err("malformed acceptance/error".into());
        }
        cases += 1;
        rejected += usize::from(before.is_err());
        Ok(())
    };
    for end in 0..40 {
        compare(&reference[..end])?;
    }
    for at in 0..40 {
        let mut bad = reference.clone();
        bad[at] ^= 128;
        old::reseal(&mut bad)?;
        compare(&bad)?;
    }
    for index in 0..16 {
        let end = 40 + (reference.len() - 40) * index / 16;
        compare(&reference[..end])?;
    }
    if reference.len() > 40 {
        for index in 0..16 {
            let mut bad = reference.clone();
            let at = 40 + (reference.len() - 40 - 1) * index / 15;
            bad[at] ^= 1;
            old::reseal(&mut bad)?;
            compare(&bad)?;
        }
    }
    println!(
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"old_ns\":{:?},\"new_ns\":{:?},\"malformed_cases\":{},\"rejected\":{},\"reversed\":{}}}",
        raw.len(),
        reference.len(),
        stats.method,
        old_ns,
        new_ns,
        cases,
        rejected,
        reversed
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("cdf_compare: {error}");
        std::process::exit(1);
    }
}
