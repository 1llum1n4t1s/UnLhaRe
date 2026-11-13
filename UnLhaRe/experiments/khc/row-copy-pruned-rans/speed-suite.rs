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
        Ok((v, s.phase_capacity_bound + 3 * 1048576 + 160))
    }
}
fn decode(frame: &[u8], newer: bool) -> Result<(Vec<u8>, usize)> {
    if newer {
        let (v, s) = candidate::decode(frame)?;
        Ok((v, s.logical_bound + 3 * 1048576 + 160))
    } else {
        let (v, s) = baseline::decode(frame)?;
        Ok((v, s.phase_capacity_bound + 3 * 1048576 + 160))
    }
}
fn measure(path: &str, reversed: bool) -> Result<String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
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
    let mut peak = old_bound.max(new_bound) + 65536;
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
            peak = peak.max(bound + 65536);
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
    Ok(format!(
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
    ))
}
fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 13 || !matches!(args[1].as_str(), "normal" | "reverse") {
        return Err("suite args".into());
    }
    let reversed = args[1] == "reverse";
    let mut report = String::from("{\"rows\":[");
    for (i, path) in args[2..].iter().enumerate() {
        let name = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or("suite filename")?;
        if !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("suite filename characters".into());
        }
        let data = measure(path, reversed)?;
        if i != 0 {
            report.push(',');
        }
        report.push_str(&format!("{{\"name\":\"{name}\",\"measurement\":{data}}}"));
        if report.len() > 32768 {
            return Err("suite output bound".into());
        }
    }
    report.push_str("],\"complete_inputs\":11}");
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(error) = main_run() {
        eprintln!("causal_speed: {error}");
        std::process::exit(1)
    }
}
