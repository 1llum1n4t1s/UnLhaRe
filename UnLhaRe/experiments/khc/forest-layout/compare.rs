//! 全CDFと正常・破損frameを旧新で逐次比較する。namespace時間はscreen専用。
#[allow(dead_code)]
#[path = "compact_codec.rs"]
mod new;
#[allow(dead_code)]
#[path = "codec.rs"]
mod old;
use std::{fs::File, io::Read, time::Instant};

fn execute() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("input")?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(old::MAX_INPUT + 1)
        .map_err(|_| "input allocation")?;
    match path.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(path)
                .map_err(|e| e.to_string())?
                .take((old::MAX_INPUT + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > old::MAX_INPUT {
        return Err("input bound".into());
    }
    let (frame, stats) = old::encode_hybrid(&raw, true)?;
    if new::encode_hybrid(&raw, true)?.0 != frame {
        return Err("frame changed".into());
    }
    if old::decode(&frame)?.0 != raw || new::decode(&frame)?.0 != raw {
        return Err("plain mismatch".into());
    }
    let mut constant = 0usize;
    let mut varying = 0usize;
    let mut comparisons = 0usize;
    let mut old_capacity = 0usize;
    let mut new_capacity = 0usize;
    let mut transient = 0usize;
    if stats.method == 1 {
        let start = old::HEADER + stats.alphabet;
        let model = &frame[start..start + stats.metadata];
        let before = old::packet::Forest::parse(model)?;
        let after = new::packet::Forest::parse(model)?;
        old_capacity = before.capacity_bytes();
        new_capacity = after.capacity_bytes();
        transient = after.parse_dispatch_peak + after.parse_reader_capacity;
        for c in 0..2 {
            for node in 0..142 {
                for k in 2..=4 {
                    let first = before.lookup(c, node, k, 0)?;
                    let mut same = true;
                    for history in 0..1024u16 {
                        let a = before.lookup(c, node, k, history)?;
                        if after.lookup(c, node, k, history)? != a {
                            return Err("CDF mismatch".into());
                        }
                        same &= a == first;
                        comparisons += 1;
                    }
                    if same {
                        constant += 1;
                    } else {
                        varying += 1;
                    }
                    for history in [1024u16, 65535] {
                        if before.lookup(c, node, k, history)?
                            != after.lookup(c, node, k, history)?
                        {
                            return Err("history mask mismatch".into());
                        }
                    }
                }
            }
        }
        for (c, node, k) in [(2, 0, 2), (0, 142, 2), (0, 0, 1), (0, 0, 5)] {
            if before.lookup(c, node, k, 0) != after.lookup(c, node, k, 0) {
                return Err("lookup rejection mismatch".into());
            }
        }
    }
    let mut cases = 0usize;
    let mut rejected = 0usize;
    let mut compare = |bytes: &[u8]| -> Result<(), String> {
        let a = old::decode(bytes).map(|p| p.0);
        let b = new::decode(bytes).map(|p| p.0);
        if a != b {
            return Err("malformed result/error mismatch".into());
        }
        rejected += usize::from(a.is_err());
        cases += 1;
        Ok(())
    };
    for end in 0..40 {
        compare(&frame[..end])?;
    }
    for at in 0..40 {
        let mut bad = frame.clone();
        bad[at] ^= 128;
        old::reseal(&mut bad)?;
        compare(&bad)?;
    }
    for i in 0..16 {
        let end = 40 + (frame.len() - 40) * i / 16;
        compare(&frame[..end])?;
    }
    if frame.len() > 40 {
        for i in 0..16 {
            let mut bad = frame.clone();
            let at = 40 + (frame.len() - 40 - 1) * i / 15;
            bad[at] ^= 1;
            old::reseal(&mut bad)?;
            compare(&bad)?;
        }
    }
    let mut old_ns = Vec::with_capacity(9);
    let mut new_ns = Vec::with_capacity(9);
    for round in 0..10 {
        for which in if round % 2 == 0 {
            [false, true]
        } else {
            [true, false]
        } {
            let start = Instant::now();
            let plain = if which {
                new::decode(&frame)?.0
            } else {
                old::decode(&frame)?.0
            };
            let ns = start.elapsed().as_nanos();
            if plain != raw {
                return Err("recovery mismatch".into());
            }
            if round != 0 {
                if which {
                    new_ns.push(ns);
                } else {
                    old_ns.push(ns);
                }
            }
        }
    }
    let logical = if stats.method == 1 {
        10224 + varying * 8192
    } else {
        0
    };
    println!(
        "{{\"raw_bytes\":{},\"frame_bytes\":{},\"method\":{},\"byte_exact\":true,\"constant_roots\":{},\"varying_roots\":{},\"row_comparisons\":{},\"current_forest_capacity\":{},\"compact_forest_capacity\":{},\"parse_transient\":{},\"proposed_logical_bytes\":{},\"malformed_cases\":{},\"rejected\":{},\"old_ns\":{:?},\"new_ns\":{:?}}}",
        raw.len(),
        frame.len(),
        stats.method,
        constant,
        varying,
        comparisons,
        old_capacity,
        new_capacity,
        transient,
        logical,
        cases,
        rejected,
        old_ns,
        new_ns
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("compact_forest: {error}");
        std::process::exit(1);
    }
}
