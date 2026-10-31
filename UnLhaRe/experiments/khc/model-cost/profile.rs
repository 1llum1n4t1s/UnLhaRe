//! 現本線のFit時間と計算回数を診断する。性能優位の判定には使用しない。
#[allow(dead_code)]
#[path = "profile_codec.rs"]
mod block;
use std::{fs::File, io::Read, time::Instant};

fn execute() -> Result<(), String> {
    let argument = std::env::args().nth(1).ok_or("input")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(block::MAX_INPUT + 1)
        .map_err(|_| "input allocation")?;
    match argument.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(argument)
                .map_err(|e| e.to_string())?
                .take((block::MAX_INPUT + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > block::MAX_INPUT {
        return Err("input bound".into());
    }
    block::profile_reset();
    let (reference, reference_stats) = block::encode_hybrid(&raw, true)?;
    let reference_counts = block::profile_result();
    if block::decode(&reference)?.0 != raw {
        return Err("warm roundtrip".into());
    }
    let mut encode_ns = [0u128; 9];
    let mut fit_ns = [0u128; 9];
    for round in 0..9 {
        block::profile_reset();
        let started = Instant::now();
        let (frame, stats) = block::encode_hybrid(&raw, true)?;
        encode_ns[round] = started.elapsed().as_nanos();
        let counts = block::profile_result();
        fit_ns[round] = counts[0];
        if frame != reference
            || stats.method != reference_stats.method
            || counts[1..] != reference_counts[1..]
            || counts[0] > encode_ns[round]
        {
            return Err("frame/method/counter stability".into());
        }
        if block::decode(&frame)?.0 != raw {
            return Err("measured roundtrip".into());
        }
    }
    println!(
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"encode_ns\":{:?},\"fit_ns\":{:?},\"fit_calls\":{},\"log2_calls\":{},\"floor_calls\":{},\"phase_capacity_bound\":{},\"fit_capacity\":{}}}",
        raw.len(),
        reference.len(),
        reference_stats.method,
        encode_ns,
        fit_ns,
        reference_counts[1],
        reference_counts[2],
        reference_counts[3],
        reference_stats.phase_capacity_bound,
        reference_stats.fit_capacity
    );
    Ok(())
}

fn main() {
    if let Err(error) = execute() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
