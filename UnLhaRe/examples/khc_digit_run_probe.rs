//! Canterbury開発入力を使うASCII digit-run分離のsize-first E2E probe。

use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

use unlhare::khc::{self, BlockStrategy};

const MAGIC: &[u8; 4] = b"KDR1";
const VERSION: u8 = 1;
const HEADER_BYTES: usize = 16;
const MIN_RUN: usize = 8;
const MAX_BLOCK_BYTES: usize = 1024 * 1024;
const EXPECTED_INPUT_BYTES: usize = 24_603;

type Run = (usize, usize);

fn fail(message: impl Into<String>) -> String {
    message.into()
}

fn check(condition: bool, message: &str) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(fail(message))
    }
}

fn is_digit(byte: u8) -> bool {
    (b'0'..=b'9').contains(&byte)
}

fn discover_runs(input: &[u8]) -> Vec<Run> {
    let mut runs = Vec::new();
    let mut position = 0;
    while position < input.len() {
        if !is_digit(input[position]) {
            position += 1;
            continue;
        }
        let start = position;
        while position < input.len() && is_digit(input[position]) {
            position += 1;
        }
        if position - start >= MIN_RUN {
            runs.push((start, position));
        }
    }
    runs
}

/// 最大1MiB block内の長いASCII数字列を位置付きside streamへ移す。
fn encode_transform(input: &[u8]) -> Result<Option<Vec<u8>>, String> {
    if input.len() > MAX_BLOCK_BYTES {
        return Err(fail("input exceeds KHC block limit"));
    }
    let runs = discover_runs(input);
    if runs.is_empty() {
        return Ok(None);
    }

    let removed_bytes = runs
        .iter()
        .try_fold(0usize, |sum, (start, end)| sum.checked_add(end - start));
    let removed_bytes = removed_bytes.ok_or_else(|| fail("removed-byte count overflow"))?;
    let mut frame_bytes = HEADER_BYTES
        .checked_add(input.len() - removed_bytes)
        .ok_or_else(|| fail("frame length overflow"))?;
    for (start, end) in &runs {
        let packed_bytes = (end - start).div_ceil(2);
        frame_bytes = frame_bytes
            .checked_add(8)
            .and_then(|value| value.checked_add(packed_bytes))
            .ok_or_else(|| fail("frame length overflow"))?;
    }
    if frame_bytes > MAX_BLOCK_BYTES {
        return Ok(None);
    }

    let mut frame = Vec::with_capacity(frame_bytes);
    frame.extend_from_slice(MAGIC);
    frame.push(VERSION);
    frame.extend_from_slice(&[0, 0, 0]);
    frame.extend_from_slice(&(input.len() as u32).to_le_bytes());
    frame.extend_from_slice(&(runs.len() as u32).to_le_bytes());

    for (start, end) in &runs {
        let length = end - start;
        frame.extend_from_slice(&(*start as u32).to_le_bytes());
        frame.extend_from_slice(&(length as u32).to_le_bytes());
        for pair_start in (*start..*end).step_by(2) {
            let high = input[pair_start] - b'0';
            let low = if pair_start + 1 < *end {
                input[pair_start + 1] - b'0'
            } else {
                0
            };
            frame.push((high << 4) | low);
        }
    }

    let mut literal_cursor = 0;
    for (start, end) in &runs {
        frame.extend_from_slice(&input[literal_cursor..*start]);
        literal_cursor = *end;
    }
    frame.extend_from_slice(&input[literal_cursor..]);
    check(
        frame.len() == frame_bytes,
        "encoded transform length mismatch",
    )?;
    Ok(Some(frame))
}

fn read_u32(frame: &[u8], position: &mut usize) -> Result<u32, String> {
    let end = position
        .checked_add(4)
        .ok_or_else(|| fail("integer position overflow"))?;
    let bytes = frame
        .get(*position..end)
        .ok_or_else(|| fail("truncated integer"))?;
    *position = end;
    Ok(u32::from_le_bytes(
        bytes.try_into().expect("four-byte slice"),
    ))
}

/// KDR1を厳密に読み、非canonical・範囲外・切断・余剰データを拒否する。
fn decode_transform(frame: &[u8]) -> Result<Vec<u8>, String> {
    if frame.len() < HEADER_BYTES || frame.len() > MAX_BLOCK_BYTES {
        return Err(fail("KDR1 frame size is invalid"));
    }
    if frame.get(..4) != Some(MAGIC.as_slice()) {
        return Err(fail("KDR1 magic mismatch"));
    }
    if frame[4] != VERSION || frame[5..8] != [0, 0, 0] {
        return Err(fail("KDR1 version or reserved bytes are invalid"));
    }

    let mut position = 8;
    let raw_length = read_u32(frame, &mut position)? as usize;
    let run_count = read_u32(frame, &mut position)? as usize;
    if raw_length > MAX_BLOCK_BYTES || run_count == 0 || run_count > raw_length / MIN_RUN {
        return Err(fail("KDR1 header limits are invalid"));
    }

    let mut runs: Vec<(usize, Vec<u8>)> = Vec::with_capacity(run_count);
    let mut previous_end = 0usize;
    let mut removed_bytes = 0usize;
    for index in 0..run_count {
        let offset = read_u32(frame, &mut position)? as usize;
        let length = read_u32(frame, &mut position)? as usize;
        if length < MIN_RUN {
            return Err(fail("KDR1 run is shorter than the minimum"));
        }
        if (index == 0 && offset < previous_end) || (index > 0 && offset <= previous_end) {
            return Err(fail("KDR1 runs overlap, are adjacent, or are unordered"));
        }
        let end = offset
            .checked_add(length)
            .ok_or_else(|| fail("KDR1 run end overflow"))?;
        if end > raw_length {
            return Err(fail("KDR1 run is outside the original input"));
        }
        let packed_length = length
            .checked_add(1)
            .ok_or_else(|| fail("KDR1 packed length overflow"))?
            / 2;
        let packed_end = position
            .checked_add(packed_length)
            .ok_or_else(|| fail("KDR1 packed range overflow"))?;
        let packed = frame
            .get(position..packed_end)
            .ok_or_else(|| fail("KDR1 digit stream is truncated"))?;
        position = packed_end;

        let mut digits = Vec::with_capacity(length);
        for byte in packed {
            let high = byte >> 4;
            let low = byte & 0x0f;
            if high > 9 {
                return Err(fail("KDR1 high BCD nibble is invalid"));
            }
            digits.push(b'0' + high);
            if digits.len() < length {
                if low > 9 {
                    return Err(fail("KDR1 low BCD nibble is invalid"));
                }
                digits.push(b'0' + low);
            } else if low != 0 {
                return Err(fail("KDR1 odd-run padding is not zero"));
            }
        }

        removed_bytes = removed_bytes
            .checked_add(length)
            .ok_or_else(|| fail("KDR1 removed-byte count overflow"))?;
        previous_end = end;
        runs.push((offset, digits));
    }

    let literal_length = raw_length
        .checked_sub(removed_bytes)
        .ok_or_else(|| fail("KDR1 run lengths exceed the original input"))?;
    if frame.len().checked_sub(position) != Some(literal_length) {
        return Err(fail("KDR1 literal length or trailing bytes are invalid"));
    }

    let literal = &frame[position..];
    let mut output = Vec::with_capacity(raw_length);
    let mut literal_position = 0usize;
    let mut raw_position = 0usize;
    for (offset, digits) in &runs {
        let gap = offset
            .checked_sub(raw_position)
            .ok_or_else(|| fail("KDR1 run offset moved backwards"))?;
        let literal_end = literal_position
            .checked_add(gap)
            .ok_or_else(|| fail("KDR1 literal position overflow"))?;
        output.extend_from_slice(
            literal
                .get(literal_position..literal_end)
                .ok_or_else(|| fail("KDR1 literal bytes are truncated"))?,
        );
        output.extend_from_slice(digits);
        raw_position = offset + digits.len();
        literal_position = literal_end;
    }
    output.extend_from_slice(
        literal
            .get(literal_position..)
            .ok_or_else(|| fail("KDR1 trailing literal bytes are truncated"))?,
    );
    if output.len() != raw_length
        || discover_runs(&output)
            != runs
                .iter()
                .map(|(offset, digits)| (*offset, *offset + digits.len()))
                .collect::<Vec<_>>()
    {
        return Err(fail("KDR1 reconstruction is not canonical"));
    }
    Ok(output)
}

fn expect_rejected(frame: &[u8], label: &str) -> Result<usize, String> {
    if decode_transform(frame).is_ok() {
        return Err(fail(format!("corrupt KDR1 input was accepted: {label}")));
    }
    Ok(1)
}

fn expect_fixture(input: &[u8], label: &str) -> Result<usize, String> {
    let encoded = encode_transform(input)?;
    if let Some(frame) = encoded {
        let decoded = decode_transform(&frame)?;
        check(decoded == input, &format!("fixture byte mismatch: {label}"))?;
        check(
            encode_transform(input)?.as_deref() == Some(frame.as_slice()),
            &format!("fixture determinism mismatch: {label}"),
        )?;
    } else if !discover_runs(input).is_empty() {
        return Err(fail(format!("eligible run unexpectedly skipped: {label}")));
    }
    Ok(1)
}

fn run_e2e_checks() -> Result<usize, String> {
    let mut checks = 0usize;
    for (label, input) in [
        ("empty", Vec::new()),
        ("tiny", b"42".to_vec()),
        ("seven-digit-no-run", b"1234567".to_vec()),
        ("eight-digit-boundary", b"12345678".to_vec()),
        ("odd-digit-run", b"012345678".to_vec()),
        ("mixed-two-runs", b"12345678x87654321".to_vec()),
        ("alternating", b"1x2x3x4x5x6x7x8x9x".to_vec()),
        ("high-bytes", vec![0xff, 0x80, 0x00, 0x31, 0x32, 0x33]),
        ("all-digits", vec![b'7'; MAX_BLOCK_BYTES]),
        ("block-edge-run", {
            let mut value = vec![b'x'; MAX_BLOCK_BYTES - 4];
            value.extend_from_slice(b"1234");
            value
        }),
    ] {
        checks += expect_fixture(&input, label)?;
    }

    let left_block = {
        let mut value = vec![b'x'; MAX_BLOCK_BYTES - 4];
        value.extend_from_slice(b"1234");
        value
    };
    let right_block = b"5678xxxx";
    check(
        encode_transform(&left_block)?.is_none() && encode_transform(right_block)?.is_none(),
        "a digit run was incorrectly carried across a block boundary",
    )?;
    checks += 1;
    checks += expect_rejected(&vec![b'x'; MAX_BLOCK_BYTES + 1], "over-limit input")?;

    let two_runs = encode_transform(b"12345678x87654321")?
        .ok_or_else(|| fail("two-run fixture was not transformed"))?;
    for prefix in 0..two_runs.len() {
        checks += expect_rejected(&two_runs[..prefix], "every truncated prefix")?;
    }
    let mut trailing = two_runs.clone();
    trailing.push(0);
    checks += expect_rejected(&trailing, "trailing byte")?;

    let mut unknown_version = two_runs.clone();
    unknown_version[4] = VERSION + 1;
    checks += expect_rejected(&unknown_version, "unknown version")?;
    let mut reserved = two_runs.clone();
    reserved[5] = 1;
    checks += expect_rejected(&reserved, "reserved byte")?;
    let mut huge_raw_length = two_runs.clone();
    huge_raw_length[8..12].copy_from_slice(&u32::MAX.to_le_bytes());
    checks += expect_rejected(&huge_raw_length, "oversized raw length")?;
    let mut huge_count = two_runs.clone();
    huge_count[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
    checks += expect_rejected(&huge_count, "oversized run count")?;
    let mut out_of_range_offset = two_runs.clone();
    out_of_range_offset[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    checks += expect_rejected(&out_of_range_offset, "out-of-range offset")?;
    let mut short_run = two_runs.clone();
    short_run[20..24].copy_from_slice(&((MIN_RUN as u32) - 1).to_le_bytes());
    checks += expect_rejected(&short_run, "short run")?;
    let mut oversized_run = two_runs.clone();
    oversized_run[20..24].copy_from_slice(&u32::MAX.to_le_bytes());
    checks += expect_rejected(&oversized_run, "oversized run")?;
    let second_descriptor = HEADER_BYTES + 8 + 4;
    let mut overlap = two_runs.clone();
    overlap[second_descriptor..second_descriptor + 4].copy_from_slice(&0u32.to_le_bytes());
    checks += expect_rejected(&overlap, "overlapping run")?;
    let mut invalid_bcd = two_runs.clone();
    invalid_bcd[24] = 0xa0;
    checks += expect_rejected(&invalid_bcd, "invalid BCD digit")?;

    let odd_run = encode_transform(b"123456789")?
        .ok_or_else(|| fail("odd-run fixture was not transformed"))?;
    let mut bad_padding = odd_run;
    let last_packed_byte = HEADER_BYTES + 8 + (9usize.div_ceil(2) - 1);
    bad_padding[last_packed_byte] |= 1;
    checks += expect_rejected(&bad_padding, "nonzero odd-run padding")?;
    Ok(checks)
}

fn run() -> Result<(), String> {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    if arguments.len() != 2 {
        return Err(fail("usage: khc_digit_run_probe <input> <report.json>"));
    }
    let input_path = Path::new(&arguments[0]);
    let report_path = Path::new(&arguments[1]);
    let input = fs::read(input_path).map_err(|error| fail(format!("read input: {error}")))?;
    check(
        input.len() == EXPECTED_INPUT_BYTES,
        "source input length does not match preregistration",
    )?;
    let e2e_checks = run_e2e_checks()?;

    let baseline = khc::compress_block_with_strategy(&input, BlockStrategy::BinaryAdaptive)
        .map_err(|error| fail(format!("baseline encode: {error:?}")))?;
    let baseline_repeat = khc::compress_block_with_strategy(&input, BlockStrategy::BinaryAdaptive)
        .map_err(|error| fail(format!("baseline repeat encode: {error:?}")))?;
    check(
        baseline == baseline_repeat,
        "baseline encoding is nondeterministic",
    )?;
    let baseline_decoded = khc::decompress_block(&baseline)
        .map_err(|error| fail(format!("baseline decode: {error:?}")))?;
    check(baseline_decoded == input, "baseline bytes differ")?;
    check(
        khc::decompress_block(&baseline[..baseline.len() - 1]).is_err(),
        "truncated baseline frame was accepted",
    )?;

    let transformed = encode_transform(&input)?;
    let (candidate_frame_bytes, candidate_gain_pct, candidate_gate_passed, candidate_reason) =
        if let Some(transformed) = transformed {
            let candidate =
                khc::compress_block_with_strategy(&transformed, BlockStrategy::BinaryAdaptive)
                    .map_err(|error| fail(format!("candidate encode: {error:?}")))?;
            let repeated =
                khc::compress_block_with_strategy(&transformed, BlockStrategy::BinaryAdaptive)
                    .map_err(|error| fail(format!("candidate repeat encode: {error:?}")))?;
            check(
                candidate == repeated,
                "candidate encoding is nondeterministic",
            )?;
            let decoded_transform = khc::decompress_block(&candidate)
                .map_err(|error| fail(format!("candidate frame decode: {error:?}")))?;
            let candidate_decoded = decode_transform(&decoded_transform)?;
            check(candidate_decoded == input, "candidate bytes differ")?;
            check(
                khc::decompress_block(&candidate[..candidate.len() - 1]).is_err(),
                "truncated candidate frame was accepted",
            )?;
            let gain =
                (baseline.len() as f64 - candidate.len() as f64) * 100.0 / baseline.len() as f64;
            let passed = (candidate.len() as u128) * 100 <= (baseline.len() as u128) * 95;
            (Some(candidate.len()), Some(gain), passed, None)
        } else {
            (
                None,
                None,
                false,
                Some("no eligible run or transformed frame exceeded 1 MiB"),
            )
        };

    let status = if candidate_gate_passed {
        "candidate-size-gate-pass"
    } else {
        "no-go"
    };
    let report = serde_json::json!({
        "schema": 1,
        "scope": "size-first KHC block pilot; not a product archive benchmark",
        "status": status,
        "input_bytes": input.len(),
        "e2e_checks_passed": e2e_checks,
        "codec": "BinaryAdaptive",
        "transform": "KDR1 ASCII decimal runs length >= 8 separated into a packed side stream",
        "baseline_frame_bytes": baseline.len(),
        "candidate_frame_bytes": candidate_frame_bytes,
        "candidate_gain_percent": candidate_gain_pct,
        "candidate_continue_threshold_percent": 5.0,
        "candidate_size_gate_passed": candidate_gate_passed,
        "candidate_no_go_reason": candidate_reason,
        "timing_measured": false,
        "memory_measured": false,
        "seven_zip_compared": false
    });
    let json = serde_json::to_vec_pretty(&report)
        .map_err(|error| fail(format!("serialize report: {error}")))?;
    if json.len() > 32 * 1024 {
        return Err(fail("report exceeds 32 KiB"));
    }
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(report_path)
        .map_err(|error| fail(format!("create report: {error}")))?;
    output
        .write_all(&json)
        .map_err(|error| fail(format!("write report: {error}")))?;
    println!(
        "{}",
        String::from_utf8(json).map_err(|error| fail(format!("report UTF-8: {error}")))?
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
