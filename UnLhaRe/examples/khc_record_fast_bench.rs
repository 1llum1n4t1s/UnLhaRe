//! KRS1/KRS2/KRS3の単一block比較。入力hashは実行前に別途記録し、出力JSONと合わせて保存する。
//! 想定失敗: 引数/strategy/round数不正、入力読取失敗、block上限超過、非決定出力、往復不一致。
use serde::Serialize;
use std::{env, error::Error, fs, io, io::Write, process, time::Instant};
use unlhare::khc::{self, BlockStrategy};

#[derive(Serialize)]
struct Report {
    schema: u32,
    strategy: String,
    input_source: String,
    input_bytes: usize,
    input_crc32: u32,
    frame_bytes: usize,
    frame_crc32: u32,
    frame_format: String,
    coded_method: Option<u8>,
    schedule_bytes: usize,
    rounds: usize,
    median_encode_ns: u128,
    median_decode_ns: u128,
    encode_samples_ns: Vec<u128>,
    decode_samples_ns: Vec<u128>,
}

fn median_ns(samples: &mut [u128]) -> u128 {
    samples.sort_unstable();
    samples[samples.len() / 2]
}

fn switching_pair_corpus() -> Vec<u8> {
    let mut state = 0x6d2b79f5u32;
    (0..khc::BLOCK_BYTES)
        .map(|i| {
            let (base, period) = if i < khc::BLOCK_BYTES / 2 {
                (0, 16)
            } else {
                (khc::BLOCK_BYTES / 2, 8)
            };
            match (i - base) % period {
                0 => 33,
                1 => 52,
                _ => {
                    state ^= state << 13;
                    state ^= state >> 17;
                    state ^= state << 5;
                    (state % 254 + 1) as u8
                }
            }
        })
        .collect()
}

fn compress(input: &[u8], strategy: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let frame = match strategy {
        "mdl" => khc::compress_block(input)?,
        "record-trial" => khc::compress_block_with_strategy(input, BlockStrategy::RecordTrial)?,
        "record-fast-trial" => {
            khc::compress_block_with_strategy(input, BlockStrategy::RecordFastTrial)?
        }
        "record-adaptive-trial" => {
            khc::compress_block_with_strategy(input, BlockStrategy::RecordAdaptiveTrial)?
        }
        "binary-adaptive" => {
            khc::compress_block_with_strategy(input, BlockStrategy::BinaryAdaptive)?
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "strategy must be mdl, record-trial, record-fast-trial, record-adaptive-trial, or binary-adaptive",
            )
            .into());
        }
    };
    Ok(frame)
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().collect();
    if !(4..=5).contains(&args.len()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: khc_record_fast_bench <strategy> <input-file|--synthetic-switching-pair-v1> <rounds: 3..=100> [frame-output-file]",
        )
        .into());
    }
    let strategy = &args[1];
    let (input, input_source) = if args[2] == "--synthetic-switching-pair-v1" {
        (
            switching_pair_corpus(),
            "synthetic-switching-pair-v1".to_owned(),
        )
    } else {
        (fs::read(&args[2])?, "file".to_owned())
    };
    if input.len() > khc::BLOCK_BYTES {
        return Err(
            io::Error::new(io::ErrorKind::InvalidInput, "input exceeds KHC block limit").into(),
        );
    }
    let rounds: usize = args[3].parse()?;
    if !(3..=100).contains(&rounds) {
        return Err(
            io::Error::new(io::ErrorKind::InvalidInput, "round count outside 3..=100").into(),
        );
    }

    for _ in 0..3 {
        let frame = compress(&input, strategy)?;
        if khc::decompress_block(&frame)? != input {
            return Err(io::Error::other("warmup roundtrip mismatch").into());
        }
    }

    let mut frame: Option<Vec<u8>> = None;
    let mut encode_samples_ns = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let started = Instant::now();
        let next = compress(&input, strategy)?;
        encode_samples_ns.push(started.elapsed().as_nanos());
        if frame.as_ref().is_some_and(|previous| previous != &next) {
            return Err(io::Error::other("encoder output is not deterministic").into());
        }
        frame = Some(next);
    }
    let frame = frame.ok_or_else(|| io::Error::other("no encoded frame"))?;
    let frame_format = if frame.starts_with(b"KRS2BLK\0") {
        "KRS2"
    } else if frame.starts_with(b"KRS3BLK\0") {
        "KRS3"
    } else if frame.starts_with(b"KRS1BLK\0") {
        "KRS1"
    } else if frame.starts_with(b"KHC1BLK\0") {
        "KHC1"
    } else {
        "other"
    }
    .to_owned();
    let coded_method = matches!(frame_format.as_str(), "KRS1" | "KRS2" | "KRS3")
        .then(|| frame.get(10).copied())
        .flatten();
    let schedule_bytes = if matches!(frame_format.as_str(), "KRS2" | "KRS3") && frame.len() >= 36 {
        u32::from_le_bytes(frame[32..36].try_into().expect("four-byte header field")) as usize
    } else {
        0
    };

    let mut decode_samples_ns = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let started = Instant::now();
        let decoded = khc::decompress_block(&frame)?;
        decode_samples_ns.push(started.elapsed().as_nanos());
        if decoded != input {
            return Err(io::Error::other("decode roundtrip mismatch").into());
        }
    }
    let median_encode_ns = median_ns(&mut encode_samples_ns.clone());
    let median_decode_ns = median_ns(&mut decode_samples_ns.clone());
    if let Some(output_path) = args.get(4) {
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(output_path)?;
        output.write_all(&frame)?;
        output.sync_all()?;
    }
    let report = Report {
        schema: 2,
        strategy: strategy.clone(),
        input_source,
        input_bytes: input.len(),
        input_crc32: crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, &input) as u32,
        frame_bytes: frame.len(),
        frame_crc32: crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, &frame) as u32,
        frame_format,
        coded_method,
        schedule_bytes,
        rounds,
        median_encode_ns,
        median_decode_ns,
        encode_samples_ns,
        decode_samples_ns,
    };
    println!("{}", serde_json::to_string(&report)?);
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("benchmark failed: {error}");
        process::exit(1);
    }
}
