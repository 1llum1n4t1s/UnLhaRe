//! 係数・leaf・Fit bit契約とframe/encoder時間を独立比較する。
#[allow(dead_code)]
#[path = "log_codec.rs"]
mod new;
#[allow(dead_code)]
#[path = "log_base_codec.rs"]
mod old;
use std::{fs::File, io::Read, time::Instant};

fn numeric_contract() -> Result<(), String> {
    let mut coefficient_vectors = 0usize;
    let mut leaf_cases = 0usize;
    for k in 2..=4 {
        let uniform = old::paid_model::uniform(k)?;
        let mut frequencies = vec![uniform];
        for dominant in 0..k {
            let mut pure = [0u16; 4];
            pure[..k].fill(2);
            pure[dominant] = 32768 - 2 * (k as u16 - 1);
            frequencies.push(pure);
            if old::paid_model::probe_coefficients(k, true, dominant)?
                != new::paid_model::probe_coefficients(k, true, dominant)?
            {
                return Err("pure coefficient bit".into());
            }
            coefficient_vectors += 1;
        }
        if old::paid_model::probe_coefficients(k, false, 0)?
            != new::paid_model::probe_coefficients(k, false, 0)?
        {
            return Err("uniform coefficient bit".into());
        }
        coefficient_vectors += 1;
        let mut weights = [0u32; 4];
        for (i, weight) in weights.iter_mut().enumerate().take(k) {
            *weight = 1 << (i * 2);
        }
        frequencies.push(old::model::compact_frequency(
            old::model::quantize(weights, k)?,
            k,
        )?);
        for frequency in frequencies {
            for sample in 0..96u32 {
                let boundary = [
                    0,
                    1,
                    2,
                    127,
                    65535,
                    old::model::CAP,
                    old::model::CAP + 1,
                    u32::MAX,
                ];
                let mut counts = [0u32; 4];
                for (i, count) in counts.iter_mut().enumerate().take(k) {
                    *count = if sample < 8 {
                        boundary[sample as usize]
                    } else {
                        sample.wrapping_mul(2654435761).rotate_left((i * 7) as u32)
                    };
                    if sample >= 8 && sample & (1 << i) != 0 {
                        *count = 0;
                    }
                }
                for depth in [0, 1, 5] {
                    if old::paid_model::probe_leaf(counts, frequency, k, depth)
                        != new::paid_model::probe_leaf(counts, frequency, k, depth)
                    {
                        return Err(format!("leaf bit k={k} sample={sample} depth={depth}"));
                    }
                    leaf_cases += 1;
                }
            }
        }
    }
    let mut leaf_rejections = 0usize;
    let mut coefficient_rejections = 0usize;
    for k in [0, 1, 5, usize::MAX] {
        for pure in [false, true] {
            let before = old::paid_model::probe_coefficients(k, pure, 0);
            let after = new::paid_model::probe_coefficients(k, pure, 0);
            if before.is_ok() || before != after {
                return Err("coefficient rejection".into());
            }
            coefficient_rejections += 1;
        }
    }
    for (frequency, k) in [
        ([32768, 0, 0, 0], 1),
        ([8192; 4], 5),
        ([1, 32767, 0, 0], 2),
        ([16384, 16384, 1, 0], 2),
        ([16384, 16383, 0, 0], 2),
        ([10922, 10922, 10922, 0], 3),
        ([0; 4], 4),
    ] {
        let before = old::paid_model::probe_leaf([1; 4], frequency, k, 0);
        let after = new::paid_model::probe_leaf([1; 4], frequency, k, 0);
        if before.is_ok() || before != after {
            return Err("leaf rejection".into());
        }
        leaf_rejections += 1;
    }
    let extent = old::model::GROUPS * old::model::NODES;
    let mut fit_nodes = 0usize;
    let mut fit_rejections = 0usize;
    for seed in 0..4u32 {
        let mut rows = vec![[0u32; 4]; extent];
        let mut state = 0x73a419b2u32;
        for group in 0..3 {
            let k = group + 2;
            for id in 341..1365 {
                for i in 0..k {
                    state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                    rows[group * 1365 + id][i] = match seed {
                        0 => 0,
                        1 => state % 3,
                        2 => state % 129,
                        _ => {
                            if i == id % k {
                                1000
                            } else {
                                2
                            }
                        }
                    };
                }
            }
            for id in (0..341).rev() {
                for digit in 0..4 {
                    let child = rows[group * 1365 + 4 * id + 1 + digit];
                    for (i, count) in child.iter().enumerate() {
                        rows[group * 1365 + id][i] += count;
                    }
                }
            }
        }
        for high in [false, true] {
            let before = old::paid_model::probe_fit(&rows, high)?;
            let after = new::paid_model::probe_fit(&rows, high)?;
            if before.len() != extent || before != after {
                return Err("Fit node bit/CDF/split".into());
            }
            fit_nodes += before.len();
        }
        if seed == 2 {
            for variant in 0..5 {
                let mut bad = rows.clone();
                match variant {
                    0 => {
                        bad.pop();
                    }
                    1 => bad[0][0] += 1,
                    2 => bad[0] = [0; 4],
                    3 => bad[0][2] = 1,
                    _ => bad[0] = [old::model::CAP + 1, 0, 0, 0],
                }
                for high in [false, true] {
                    let before = old::paid_model::probe_fit(&bad, high);
                    let after = new::paid_model::probe_fit(&bad, high);
                    if before.is_ok() || before != after {
                        return Err("Fit rejection".into());
                    }
                    fit_rejections += 1;
                }
            }
        }
    }
    if new::paid_model::probe_cost_capacity() != 144 {
        return Err("cache stack cost".into());
    }
    println!(
        "{{\"bit_exact\":true,\"coefficient_vectors\":{},\"coefficient_slots\":{},\"coefficient_rejections\":{},\"leaf_cases\":{},\"leaf_rejections\":{},\"fit_nodes\":{},\"fit_rejections\":{},\"stack_cost\":144}}",
        coefficient_vectors,
        coefficient_vectors * 4,
        coefficient_rejections,
        leaf_cases,
        leaf_rejections,
        fit_nodes,
        fit_rejections
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
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"old_ns\":{:?},\"new_ns\":{:?},\"malformed_cases\":{},\"rejected\":{},\"cache_stack_bytes\":144,\"reversed\":{}}}",
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
        eprintln!("log_compare: {error}");
        std::process::exit(1);
    }
}
