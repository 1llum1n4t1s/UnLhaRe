//! 窓共有segment並列LZの試作計測（研究専用、LONG_RANGE_LZ_20261113.md）。製品APIには接続しない。
//!
//! 入力を `--segment-mib` ごとのsegmentへ分け、各segmentは直前 `--dictionary-mib` の生データを
//! 符号化しない前置として参照する。segmentはそれぞれ新しい確率modelで、`--threads` 個のworkerが
//! 並列に符号化する。復号は前置が必要なので逐次で行い、全byte一致を確認する。
//! 出力は1行のJSON（サイズ、作成・復号の壁時計、segment数）。frame・CRC・segment表は持たないので、
//! 実書庫のサイズは segment ごとに表の数 byte と header が加わる（`table_bytes` に見積りを出す）。
//! 使い方: cargo run --release --example lhc_window_lab -- <file> [--segment-mib 16] [--dictionary-mib 48] [--threads 4]
#[path = "../experiments/khc/bench_clock.rs"]
#[allow(dead_code)]
mod bench_clock;
#[path = "../experiments/khc/mod.rs"]
#[allow(dead_code, unused_imports)]
mod lhc;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let mut path = None;
    let (mut segment_mib, mut dictionary_mib, mut threads) = (16usize, 48usize, 4usize);
    while let Some(arg) = args.next() {
        let mut value = || -> Result<usize, String> {
            args.next()
                .and_then(|v| v.parse().ok())
                .ok_or(format!("{arg} needs a number"))
        };
        match arg.as_str() {
            "--segment-mib" => segment_mib = value()?,
            "--dictionary-mib" => dictionary_mib = value()?,
            "--threads" => threads = value()?.max(1),
            _ => path = Some(arg),
        }
    }
    let path = path.ok_or("input file is required")?;
    let input = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
    let segment = segment_mib << 20;
    let dictionary = dictionary_mib << 20;
    if segment == 0 || dictionary == 0 || segment + dictionary > lhc::MAX_INPUT {
        return Err("segment + dictionary must be within the research MAX_INPUT (64 MiB)".into());
    }
    let ranges: Vec<(usize, usize, usize)> = (0..input.len().div_ceil(segment))
        .map(|k| {
            let start = k * segment;
            let end = (start + segment).min(input.len());
            (start.saturating_sub(dictionary), start, end)
        })
        .collect();

    // 作成: segment を長い順ではなく書庫順に配り、各workerが前置ごとBTを作って符号化する。
    let next = AtomicUsize::new(0);
    let mut packed: Vec<Option<Vec<u8>>> = vec![None; ranges.len()];
    let started = Instant::now();
    std::thread::scope(|scope| -> Result<(), String> {
        let mut handles = Vec::new();
        for _ in 0..threads.min(ranges.len()) {
            let (next, ranges, input) = (&next, &ranges, &input);
            let handle = std::thread::Builder::new()
                .stack_size(64 << 20)
                .spawn_scoped(scope, move || -> Result<Vec<(usize, Vec<u8>)>, String> {
                    let mut done = Vec::new();
                    loop {
                        let k = next.fetch_add(1, Ordering::Relaxed);
                        let Some(&(window_start, start, end)) = ranges.get(k) else {
                            return Ok(done);
                        };
                        let bytes = lhc::encode_window_segment(
                            &input[window_start..end],
                            start - window_start,
                            dictionary,
                            &mut || false,
                        )
                        .map_err(|e| format!("segment {k}: {e:?}"))?;
                        done.push((k, bytes));
                    }
                })
                .map_err(|e| e.to_string())?;
            handles.push(handle);
        }
        for handle in handles {
            for (k, bytes) in handle.join().map_err(|_| "worker panicked")?? {
                packed[k] = Some(bytes);
            }
        }
        Ok(())
    })?;
    let create_ms = started.elapsed().as_secs_f64() * 1e3;
    let packed: Vec<Vec<u8>> = packed.into_iter().map(Option::unwrap).collect();
    let payload: usize = packed.iter().map(Vec::len).sum();

    // 復号: segment k は k より前の出力を参照するので逐次。entropy復号だけを並列化する2段方式は未実装。
    let started = Instant::now();
    let mut output = vec![0u8; input.len()];
    for (k, &(window_start, start, end)) in ranges.iter().enumerate() {
        lhc::decode_window_segment(
            &mut output[window_start..end],
            start - window_start,
            &packed[k],
            dictionary,
            &mut || false,
        )
        .map_err(|e| format!("decode segment {k}: {e:?}"))?;
    }
    let decode_ms = started.elapsed().as_secs_f64() * 1e3;
    if output != input {
        return Err("round trip mismatch".into());
    }
    println!(
        "{{\"file\":{:?},\"bytes\":{},\"segment_mib\":{segment_mib},\"dictionary_mib\":{dictionary_mib},\"threads\":{threads},\"segments\":{},\"payload\":{payload},\"table_bytes\":{},\"create_ms\":{create_ms:.0},\"decode_sequential_ms\":{decode_ms:.0}}}",
        path,
        input.len(),
        ranges.len(),
        8 * ranges.len() + 4
    );
    Ok(())
}
