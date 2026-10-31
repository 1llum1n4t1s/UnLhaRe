//! 整数逆表の全u16・frame・拒否契約とencoder時間を独立比較する。
#[allow(dead_code)]
#[path = "floor_codec.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_codec.rs"]
mod old;
use std::{fs::File, io::Read, time::Instant};

fn execute() -> Result<(), String> {
    let argument = std::env::args().nth(1).ok_or("input")?;
    let reversed = std::env::args().nth(2).as_deref() == Some("--reverse");
    for value in 0..=u16::MAX {
        if old::model::floor_code(value) != new::model::floor_code(value) {
            return Err(format!("floor contract {value}"));
        }
    }
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
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"floor_values\":65536,\"old_ns\":{:?},\"new_ns\":{:?},\"malformed_cases\":{},\"rejected\":{},\"static_table_bytes\":16384,\"reversed\":{}}}",
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
        eprintln!("floor_compare: {error}");
        std::process::exit(1);
    }
}
