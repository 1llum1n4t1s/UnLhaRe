//! KRS1のnormal入口全費用を現Program baselineとpaired測定。
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod baseline;
#[allow(dead_code)]
#[path = "codec.rs"]
mod candidate;
use std::{fs::File, io::Read, time::Instant};
type Result<T> = std::result::Result<T, String>;
fn encode(raw: &[u8], newer: bool) -> Result<(Vec<u8>, usize)> {
    if newer {
        let (v, s) = candidate::encode(raw)?;
        Ok((v, s.logical_bound + 3 * 1048576 + 160))
    } else {
        let (v, s) = baseline::encode_hybrid(raw, true)?;
        Ok((v, s.phase_capacity_bound))
    }
}
fn decode(frame: &[u8], newer: bool) -> Result<(Vec<u8>, usize)> {
    if newer {
        let (v, s) = candidate::decode(frame)?;
        Ok((v, s.logical_bound + 3 * 1048576 + 160))
    } else {
        let (v, s) = baseline::decode(frame)?;
        Ok((v, s.phase_capacity_bound))
    }
}
fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() < 2 || args.len() > 3 {
        return Err("input/order".into());
    }
    let reversed = args.get(2).is_some_and(|x| x == "--reverse");
    let file = File::open(&args[1]).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > 1048576 {
        return Err("input extent".into());
    }
    let mut raw = Vec::new();
    raw.try_reserve_exact(1048577)
        .map_err(|_| "read allocation")?;
    file.take(1048577)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    if raw.len() > 1048576 {
        return Err("read bound".into());
    }
    let (before, old_bound) = encode(&raw, false)?;
    let (after, new_bound) = encode(&raw, true)?;
    if before
        != unlhare::lhc::compress_block_with_strategy(
            &raw,
            unlhare::lhc::BlockStrategy::BinaryAdaptive,
        )
        .map_err(|e| e.to_string())?
        || decode(&before, false)?.0 != raw
        || decode(&after, true)?.0 != raw
    {
        return Err("warm frame/public bytes".into());
    }
    let mut old_encode = [0u128; 9];
    let mut new_encode = [0u128; 9];
    let mut old_decode = [0u128; 9];
    let mut new_decode = [0u128; 9];
    let mut peak = old_bound.max(new_bound);
    for round in 0..9 {
        let order = if (round % 2 == 0) ^ reversed {
            [false, true]
        } else {
            [true, false]
        };
        for newer in order {
            let start = Instant::now();
            let (frame, bound) = encode(&raw, newer)?;
            let elapsed = start.elapsed().as_nanos();
            if frame != *(if newer { &after } else { &before }) {
                return Err("encoder drift".into());
            }
            if newer {
                new_encode[round] = elapsed
            } else {
                old_encode[round] = elapsed
            }
            peak = peak.max(bound);
            let start = Instant::now();
            let (plain, bound) = decode(&frame, newer)?;
            let elapsed = start.elapsed().as_nanos();
            if plain != raw || bound > 67108864 {
                return Err("decode byte/RAM".into());
            }
            peak = peak.max(bound);
            if newer {
                new_decode[round] = elapsed
            } else {
                old_decode[round] = elapsed
            }
        }
    }
    if peak > 67108864 {
        return Err("whole phase bound".into());
    }
    println!(
        "{{\"byte_exact\":true,\"public_baseline_exact\":true,\"raw_bytes\":{},\"old_bytes\":{},\"new_bytes\":{},\"old_method\":{},\"new_method\":{},\"old_encode_ns\":{:?},\"new_encode_ns\":{:?},\"old_decode_ns\":{:?},\"new_decode_ns\":{:?},\"logical_peak\":{},\"reversed\":{}}}",
        raw.len(),
        before.len(),
        after.len(),
        before[10],
        after[10],
        old_encode,
        new_encode,
        old_decode,
        new_decode,
        peak,
        reversed
    );
    Ok(())
}
fn main() {
    if let Err(error) = main_run() {
        eprintln!("causal_speed: {error}");
        std::process::exit(1)
    }
}
