//! 数学モデルの量子化・zero経路・leaf mode呼出し数の診断。
#[allow(dead_code)]
#[path = "uniform_count_codec.rs"]
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
    let (reference, stats) = block::encode_hybrid(&raw, true)?;
    let counts = block::profile_result();
    if counts[1] > counts[0] || block::decode(&reference)?.0 != raw {
        return Err("warm contract".into());
    }
    let mut encode_ns = [0u128; 9];
    for round in &mut encode_ns {
        block::profile_reset();
        let start = Instant::now();
        let (frame, current) = block::encode_hybrid(&raw, true)?;
        *round = start.elapsed().as_nanos();
        if frame != reference
            || current.method != stats.method
            || block::profile_result() != counts
            || block::decode(&frame)?.0 != raw
        {
            return Err("frame/counter/roundtrip".into());
        }
    }
    println!(
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"encode_ns\":{:?},\"quantize_calls\":{},\"zero_quantize_calls\":{},\"leaf_mode_calls\":{},\"floor_calls\":{},\"phase_capacity_bound\":{}}}",
        raw.len(),
        reference.len(),
        stats.method,
        encode_ns,
        counts[0],
        counts[1],
        counts[2],
        counts[3],
        stats.phase_capacity_bound
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("uniform_count: {error}");
        std::process::exit(1);
    }
}
