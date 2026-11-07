//! Experimental, self-contained two-version binary archive using KHC blocks.
//! This probe is intentionally separate from the stable LHA APIs.

use crc_fast::{CrcAlgorithm, checksum};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
    time::Instant,
};
use unlhare::khc::{BLOCK_BYTES, compress_block, decompress_block};

const MAGIC: &[u8; 8] = b"KHCDLT1\0";
const HEADER_BYTES: usize = 48;
const MIN_MATCH: usize = 16;
const HASH_BYTES: usize = 8;
const MAX_HASH_CANDIDATES: usize = 16;
const MAX_NESTED_FRAME_BYTES: usize = BLOCK_BYTES * 2;

#[derive(Clone, Copy)]
struct HashPosition {
    hash: u64,
    offset: u32,
}

fn crc32(bytes: &[u8]) -> u32 {
    checksum(CrcAlgorithm::Crc32IsoHdlc, bytes) as u32
}

fn hash_window(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for &byte in &bytes[..HASH_BYTES] {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3);
    }
    hash
}

fn put_u16(output: &mut [u8], offset: usize, value: u16) {
    output[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn put_u32(output: &mut [u8], offset: usize, value: u32) {
    output[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn get_u16(input: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = input
        .get(offset..offset + 2)
        .ok_or_else(|| "truncated u16".to_owned())?;
    Ok(u16::from_le_bytes(
        bytes.try_into().map_err(|_| "u16 width")?,
    ))
}

fn get_u32(input: &[u8], offset: usize) -> Result<u32, String> {
    let bytes = input
        .get(offset..offset + 4)
        .ok_or_else(|| "truncated u32".to_owned())?;
    Ok(u32::from_le_bytes(
        bytes.try_into().map_err(|_| "u32 width")?,
    ))
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name
            .chars()
            .any(|character| matches!(character, '/' | '\\' | ':') || character.is_control())
}

fn header_crc(header_prefix: &[u8], names: &[u8]) -> u32 {
    let mut bytes = Vec::with_capacity(header_prefix.len() + names.len());
    bytes.extend_from_slice(header_prefix);
    bytes.extend_from_slice(names);
    crc32(&bytes)
}

fn assemble_frame(
    base_name: &str,
    target_name: &str,
    base_len: usize,
    target_len: usize,
    base_crc: u32,
    target_crc: u32,
    mode: u8,
    operation_count: u32,
    base_frame: &[u8],
    body_frame: &[u8],
) -> Result<Vec<u8>, String> {
    if !valid_name(base_name) || !valid_name(target_name) {
        return Err("unsafe or oversized member name".into());
    }
    if base_len > BLOCK_BYTES || target_len > BLOCK_BYTES {
        return Err("member exceeds KHC block limit".into());
    }
    if base_frame.len() > MAX_NESTED_FRAME_BYTES || body_frame.len() > MAX_NESTED_FRAME_BYTES {
        return Err("nested frame exceeds container limit".into());
    }
    if !matches!(mode, 0 | 1) || (mode == 0 && operation_count != 0) {
        return Err("invalid body mode".into());
    }
    let base_name_bytes = base_name.as_bytes();
    let target_name_bytes = target_name.as_bytes();
    let base_name_len = u16::try_from(base_name_bytes.len()).map_err(|_| "base name length")?;
    let target_name_len =
        u16::try_from(target_name_bytes.len()).map_err(|_| "target name length")?;
    let base_len = u32::try_from(base_len).map_err(|_| "base length")?;
    let target_len = u32::try_from(target_len).map_err(|_| "target length")?;
    let base_frame_len = u32::try_from(base_frame.len()).map_err(|_| "base frame length")?;
    let body_frame_len = u32::try_from(body_frame.len()).map_err(|_| "body frame length")?;

    let mut frame = vec![0u8; HEADER_BYTES];
    frame[..8].copy_from_slice(MAGIC);
    put_u16(&mut frame, 8, 1);
    frame[10] = mode;
    put_u32(&mut frame, 12, base_len);
    put_u32(&mut frame, 16, target_len);
    put_u32(&mut frame, 20, base_crc);
    put_u32(&mut frame, 24, target_crc);
    put_u32(&mut frame, 28, base_frame_len);
    put_u32(&mut frame, 32, body_frame_len);
    put_u32(&mut frame, 36, operation_count);
    put_u16(&mut frame, 40, base_name_len);
    put_u16(&mut frame, 42, target_name_len);
    frame.extend_from_slice(base_name_bytes);
    frame.extend_from_slice(target_name_bytes);
    let names_end = frame.len();
    let checksum = header_crc(&frame[..44], &frame[HEADER_BYTES..names_end]);
    put_u32(&mut frame, 44, checksum);
    frame.extend_from_slice(base_frame);
    frame.extend_from_slice(body_frame);
    Ok(frame)
}

fn append_operation_header(output: &mut Vec<u8>, kind: u8, offset: u32, length: u32) {
    output.push(kind);
    output.extend_from_slice(&offset.to_le_bytes());
    output.extend_from_slice(&length.to_le_bytes());
}

fn emit_gap(
    output: &mut Vec<u8>,
    operation_count: &mut u32,
    base: &[u8],
    target: &[u8],
    target_start: usize,
    target_end: usize,
    base_cursor: usize,
) -> Result<bool, String> {
    let gap_len = target_end.saturating_sub(target_start);
    let diff_len = gap_len.min(base.len().saturating_sub(base_cursor));
    let literal_len = gap_len - diff_len;
    let diff_bytes = if diff_len > 0 {
        9usize
            .checked_add(diff_len)
            .ok_or_else(|| "delta command length overflow".to_owned())?
    } else {
        0
    };
    let literal_bytes = if literal_len > 0 {
        5usize
            .checked_add(literal_len)
            .ok_or_else(|| "delta command length overflow".to_owned())?
    } else {
        0
    };
    let next_len = output
        .len()
        .checked_add(diff_bytes)
        .and_then(|length| length.checked_add(literal_bytes))
        .ok_or_else(|| "delta command length overflow".to_owned())?;
    if next_len > BLOCK_BYTES {
        return Ok(false);
    }
    if diff_len > 0 {
        append_operation_header(
            output,
            1,
            u32::try_from(base_cursor).map_err(|_| "diff base offset")?,
            u32::try_from(diff_len).map_err(|_| "diff length")?,
        );
        for index in 0..diff_len {
            output.push(target[target_start + index].wrapping_sub(base[base_cursor + index]));
        }
        *operation_count = operation_count
            .checked_add(1)
            .ok_or_else(|| "too many operations".to_owned())?;
    }
    if literal_len > 0 {
        output.push(2);
        output.extend_from_slice(
            &u32::try_from(literal_len)
                .map_err(|_| "literal length")?
                .to_le_bytes(),
        );
        output.extend_from_slice(&target[target_start + diff_len..target_end]);
        *operation_count = operation_count
            .checked_add(1)
            .ok_or_else(|| "too many operations".to_owned())?;
    }
    Ok(true)
}

fn build_delta(base: &[u8], target: &[u8]) -> Result<Option<(Vec<u8>, u32)>, String> {
    if target.is_empty() {
        return Ok(Some((Vec::new(), 0)));
    }
    if base.len() < HASH_BYTES || target.len() < HASH_BYTES {
        return Ok(None);
    }
    let mut index = Vec::with_capacity(base.len() - HASH_BYTES + 1);
    for offset in 0..=base.len() - HASH_BYTES {
        index.push(HashPosition {
            hash: hash_window(&base[offset..offset + HASH_BYTES]),
            offset: u32::try_from(offset).map_err(|_| "base index offset")?,
        });
    }
    index.sort_unstable_by(|left, right| {
        left.hash
            .cmp(&right.hash)
            .then_with(|| left.offset.cmp(&right.offset))
    });

    let mut patch = Vec::with_capacity(target.len().min(BLOCK_BYTES));
    let mut operations = 0u32;
    let mut target_cursor = 0usize;
    let mut base_cursor = 0usize;
    let mut position = 0usize;
    while position + HASH_BYTES <= target.len() {
        let hash = hash_window(&target[position..position + HASH_BYTES]);
        let first = index.partition_point(|entry| entry.hash < hash);
        let mut best_offset = 0usize;
        let mut best_length = 0usize;
        for entry in index[first..]
            .iter()
            .take_while(|entry| entry.hash == hash)
            .take(MAX_HASH_CANDIDATES)
        {
            let base_offset = entry.offset as usize;
            if base.get(base_offset..base_offset + HASH_BYTES)
                != target.get(position..position + HASH_BYTES)
            {
                continue;
            }
            let maximum = (base.len() - base_offset).min(target.len() - position);
            let mut length = HASH_BYTES;
            while length < maximum && base[base_offset + length] == target[position + length] {
                length += 1;
            }
            if length > best_length {
                best_offset = base_offset;
                best_length = length;
            }
        }

        if best_length >= MIN_MATCH {
            if !emit_gap(
                &mut patch,
                &mut operations,
                base,
                target,
                target_cursor,
                position,
                base_cursor,
            )? {
                return Ok(None);
            }
            append_operation_header(
                &mut patch,
                0,
                u32::try_from(best_offset).map_err(|_| "copy base offset")?,
                u32::try_from(best_length).map_err(|_| "copy length")?,
            );
            operations = operations
                .checked_add(1)
                .ok_or_else(|| "too many operations".to_owned())?;
            target_cursor = position + best_length;
            base_cursor = best_offset + best_length;
            position = target_cursor;
            if patch.len() > BLOCK_BYTES {
                return Ok(None);
            }
        } else {
            position += 1;
        }
    }
    if !emit_gap(
        &mut patch,
        &mut operations,
        base,
        target,
        target_cursor,
        target.len(),
        base_cursor,
    )? {
        return Ok(None);
    }
    Ok(Some((patch, operations)))
}

fn encode_pair(
    base_name: &str,
    target_name: &str,
    base: &[u8],
    target: &[u8],
) -> Result<(Vec<u8>, u8, u32, usize, usize), String> {
    if base.len() > BLOCK_BYTES || target.len() > BLOCK_BYTES {
        return Err("input exceeds the 1 MiB experimental block limit".into());
    }
    if !valid_name(base_name) || !valid_name(target_name) {
        return Err("input file name is not a safe single path component".into());
    }
    let base_frame = compress_block(base).map_err(|error| format!("KHC base encode: {error}"))?;
    let direct_frame =
        compress_block(target).map_err(|error| format!("KHC target encode: {error}"))?;
    let (mode, operation_count, body_frame, patch_bytes) = match build_delta(base, target)? {
        Some((patch, operation_count)) => {
            let patch_frame =
                compress_block(&patch).map_err(|error| format!("KHC patch encode: {error}"))?;
            if patch_frame.len() < direct_frame.len() {
                (1, operation_count, patch_frame, patch.len())
            } else {
                (0, 0, direct_frame.clone(), target.len())
            }
        }
        None => (0, 0, direct_frame.clone(), target.len()),
    };
    let frame = assemble_frame(
        base_name,
        target_name,
        base.len(),
        target.len(),
        crc32(base),
        crc32(target),
        mode,
        operation_count,
        &base_frame,
        &body_frame,
    )?;
    Ok((frame, mode, operation_count, base_frame.len(), patch_bytes))
}

fn decode_delta(
    base: &[u8],
    patch: &[u8],
    target_len: usize,
    operation_count: u32,
) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(target_len);
    let mut cursor = 0usize;
    for _ in 0..operation_count {
        let kind = *patch
            .get(cursor)
            .ok_or_else(|| "truncated delta operation".to_owned())?;
        cursor += 1;
        let offset = if kind == 2 {
            None
        } else {
            let value = get_u32(patch, cursor)?;
            cursor = cursor
                .checked_add(4)
                .ok_or_else(|| "patch cursor overflow".to_owned())?;
            Some(value as usize)
        };
        let length = get_u32(patch, cursor)? as usize;
        cursor = cursor
            .checked_add(4)
            .ok_or_else(|| "patch cursor overflow".to_owned())?;
        if length == 0 {
            return Err("zero-length delta operation".into());
        }
        let output_end = output
            .len()
            .checked_add(length)
            .ok_or_else(|| "target extent overflow".to_owned())?;
        if output_end > target_len {
            return Err("delta operations exceed target length".into());
        }
        match kind {
            0 => {
                let base_offset = offset.ok_or_else(|| "copy offset missing".to_owned())?;
                let base_end = base_offset
                    .checked_add(length)
                    .ok_or_else(|| "copy extent overflow".to_owned())?;
                let source = base
                    .get(base_offset..base_end)
                    .ok_or_else(|| "copy outside base".to_owned())?;
                output.extend_from_slice(source);
            }
            1 => {
                let base_offset = offset.ok_or_else(|| "diff offset missing".to_owned())?;
                let base_end = base_offset
                    .checked_add(length)
                    .ok_or_else(|| "diff extent overflow".to_owned())?;
                let source = base
                    .get(base_offset..base_end)
                    .ok_or_else(|| "diff outside base".to_owned())?;
                let residual_end = cursor
                    .checked_add(length)
                    .ok_or_else(|| "diff payload overflow".to_owned())?;
                let residual = patch
                    .get(cursor..residual_end)
                    .ok_or_else(|| "truncated diff payload".to_owned())?;
                output.extend(
                    source
                        .iter()
                        .zip(residual)
                        .map(|(&byte, &delta)| byte.wrapping_add(delta)),
                );
                cursor = residual_end;
            }
            2 => {
                if offset.is_some() {
                    return Err("literal carries a base offset".into());
                }
                let literal_end = cursor
                    .checked_add(length)
                    .ok_or_else(|| "literal extent overflow".to_owned())?;
                let literal = patch
                    .get(cursor..literal_end)
                    .ok_or_else(|| "truncated literal payload".to_owned())?;
                output.extend_from_slice(literal);
                cursor = literal_end;
            }
            _ => return Err("unknown delta operation".into()),
        }
    }
    if cursor != patch.len() || output.len() != target_len {
        return Err("delta stream has trailing bytes or wrong target length".into());
    }
    Ok(output)
}

fn decode_pair(frame: &[u8]) -> Result<(String, String, Vec<u8>, Vec<u8>), String> {
    if frame.len() < HEADER_BYTES || frame.len() > HEADER_BYTES + 510 + 4 * MAX_NESTED_FRAME_BYTES {
        return Err("container extent limit".into());
    }
    if frame.get(..8) != Some(MAGIC) || get_u16(frame, 8)? != 1 {
        return Err("container magic/version".into());
    }
    let mode = frame[10];
    if !matches!(mode, 0 | 1) || frame[11] != 0 {
        return Err("container mode/reserved".into());
    }
    let base_len = get_u32(frame, 12)? as usize;
    let target_len = get_u32(frame, 16)? as usize;
    let base_crc = get_u32(frame, 20)?;
    let target_crc = get_u32(frame, 24)?;
    let base_frame_len = get_u32(frame, 28)? as usize;
    let body_frame_len = get_u32(frame, 32)? as usize;
    let operation_count = get_u32(frame, 36)?;
    let base_name_len = get_u16(frame, 40)? as usize;
    let target_name_len = get_u16(frame, 42)? as usize;
    if base_len > BLOCK_BYTES
        || target_len > BLOCK_BYTES
        || base_frame_len > MAX_NESTED_FRAME_BYTES
        || body_frame_len > MAX_NESTED_FRAME_BYTES
        || (mode == 0 && operation_count != 0)
    {
        return Err("container declared extent limit".into());
    }
    let names_end = HEADER_BYTES
        .checked_add(base_name_len)
        .and_then(|value| value.checked_add(target_name_len))
        .ok_or_else(|| "member-name extent overflow".to_owned())?;
    let base_end = names_end
        .checked_add(base_frame_len)
        .ok_or_else(|| "base-frame extent overflow".to_owned())?;
    let frame_end = base_end
        .checked_add(body_frame_len)
        .ok_or_else(|| "body-frame extent overflow".to_owned())?;
    if names_end > frame.len() || frame_end != frame.len() {
        return Err("container lengths/trailing bytes".into());
    }
    let names = &frame[HEADER_BYTES..names_end];
    if header_crc(&frame[..44], names) != get_u32(frame, 44)? {
        return Err("container header CRC".into());
    }
    let base_name =
        std::str::from_utf8(&names[..base_name_len]).map_err(|_| "base member name UTF-8")?;
    let target_name =
        std::str::from_utf8(&names[base_name_len..]).map_err(|_| "target member name UTF-8")?;
    if !valid_name(base_name) || !valid_name(target_name) {
        return Err("unsafe member name".into());
    }

    let base_frame = &frame[names_end..base_end];
    let body_frame = &frame[base_end..frame_end];
    let base = decompress_block(base_frame).map_err(|error| format!("KHC base decode: {error}"))?;
    if base.len() != base_len || crc32(&base) != base_crc {
        return Err("base content length/CRC".into());
    }
    let body = decompress_block(body_frame).map_err(|error| format!("KHC body decode: {error}"))?;
    if body.len() > BLOCK_BYTES {
        return Err("decoded body exceeds block limit".into());
    }
    let target = if mode == 0 {
        if body.len() != target_len {
            return Err("direct target length".into());
        }
        body
    } else {
        decode_delta(&base, &body, target_len, operation_count)?
    };
    if crc32(&target) != target_crc {
        return Err("target content CRC".into());
    }
    Ok((base_name.to_owned(), target_name.to_owned(), base, target))
}

fn ensure_rejected(label: &str, bytes: &[u8]) -> Result<(), String> {
    if decode_pair(bytes).is_ok() {
        return Err(format!("malformed frame accepted: {label}"));
    }
    Ok(())
}

fn self_check() -> Result<usize, String> {
    let base: Vec<u8> = (0..65_536usize)
        .map(|index| ((index.wrapping_mul(73) ^ (index >> 3) ^ (index >> 11)) & 0xff) as u8)
        .collect();
    let mut edited = base.clone();
    for (offset, byte) in edited.iter_mut().enumerate().skip(4096).take(96) {
        *byte = byte.wrapping_add((offset % 7) as u8);
    }
    edited.splice(12_000..12_000, [0xa5; 23]);
    edited.drain(31_000..31_019);
    let fixtures = [
        ("same.bin", base.clone(), base.clone()),
        ("edited.bin", base.clone(), edited),
        ("unrelated.bin", vec![0x31; 4096], vec![0x72; 4096]),
        ("empty.bin", Vec::new(), Vec::new()),
        ("empty-target.bin", base.clone(), Vec::new()),
    ];
    let mut cases = 0usize;
    let mut valid_frame = Vec::new();
    for (name, source, target) in fixtures {
        let (frame, _, _, _, _) = encode_pair("base.bin", name, &source, &target)?;
        let decoded = decode_pair(&frame)?;
        if decoded.0 != "base.bin"
            || decoded.1 != name
            || decoded.2 != source
            || decoded.3 != target
        {
            return Err(format!("roundtrip mismatch: {name}"));
        }
        cases += 1;
        if name == "edited.bin" {
            valid_frame = frame;
        }
    }
    let exact_limit_base = vec![0u8; BLOCK_BYTES];
    let (limit_frame, _, _, _, _) = encode_pair("limit.bin", "empty.bin", &exact_limit_base, &[])?;
    if decode_pair(&limit_frame)?.2 != exact_limit_base {
        return Err("exact block-limit roundtrip mismatch".into());
    }
    cases += 1;

    let oversized_gap_base = vec![0u8; BLOCK_BYTES];
    let oversized_gap_target = vec![1u8; BLOCK_BYTES];
    let (fallback_frame, fallback_mode, _, _, _) = encode_pair(
        "base.bin",
        "fallback.bin",
        &oversized_gap_base,
        &oversized_gap_target,
    )?;
    if fallback_mode != 0 || decode_pair(&fallback_frame)?.3 != oversized_gap_target {
        return Err("oversized delta gap did not fall back to a valid direct frame".into());
    }
    cases += 1;

    ensure_rejected("truncation", &valid_frame[..valid_frame.len() - 1])?;
    let mut trailing = valid_frame.clone();
    trailing.push(0);
    ensure_rejected("trailing byte", &trailing)?;
    let mut broken_body = valid_frame.clone();
    let body_start = broken_body.len() - 1;
    broken_body[body_start] ^= 0x80;
    ensure_rejected("nested body corruption", &broken_body)?;
    let mut wrong_version = valid_frame.clone();
    put_u16(&mut wrong_version, 8, 2);
    let names_end = HEADER_BYTES
        + get_u16(&wrong_version, 40)? as usize
        + get_u16(&wrong_version, 42)? as usize;
    let crc = header_crc(
        &wrong_version[..44],
        &wrong_version[HEADER_BYTES..names_end],
    );
    put_u32(&mut wrong_version, 44, crc);
    ensure_rejected("unknown version", &wrong_version)?;

    let small_base = b"valid base";
    let base_frame = compress_block(small_base).map_err(|error| format!("KHC base: {error}"))?;
    let invalid_copy = [0u8, 250, 0, 0, 0, 1, 0, 0, 0];
    let invalid_body =
        compress_block(&invalid_copy).map_err(|error| format!("KHC body: {error}"))?;
    let bad_range = assemble_frame(
        "base.bin",
        "target.bin",
        small_base.len(),
        1,
        crc32(small_base),
        crc32(&[0]),
        1,
        1,
        &base_frame,
        &invalid_body,
    )?;
    ensure_rejected("copy out of range", &bad_range)?;
    cases += 5;

    if decode_pair(&valid_frame)?.3 != fixtures_target_for_followup() {
        return Err("normal decode failed after malformed frames".into());
    }
    Ok(cases)
}

fn fixtures_target_for_followup() -> Vec<u8> {
    let base: Vec<u8> = (0..65_536usize)
        .map(|index| ((index.wrapping_mul(73) ^ (index >> 3) ^ (index >> 11)) & 0xff) as u8)
        .collect();
    let mut edited = base;
    for (offset, byte) in edited.iter_mut().enumerate().skip(4096).take(96) {
        *byte = byte.wrapping_add((offset % 7) as u8);
    }
    edited.splice(12_000..12_000, [0xa5; 23]);
    edited.drain(31_000..31_019);
    edited
}

fn input_name(path: &Path) -> Result<String, String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "input basename is not UTF-8".to_owned())?;
    if !valid_name(name) {
        return Err("input basename is unsafe or longer than 255 bytes".into());
    }
    Ok(name.to_owned())
}

fn read_input(path: &Path) -> Result<Vec<u8>, String> {
    let metadata = fs::metadata(path).map_err(|error| format!("input metadata: {error}"))?;
    if !metadata.is_file() || metadata.len() > BLOCK_BYTES as u64 {
        return Err("input must be a regular file no larger than 1 MiB".into());
    }
    fs::read(path).map_err(|error| format!("read input: {error}"))
}

fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| format!("create-new output: {error}"))?;
    file.write_all(bytes)
        .map_err(|error| format!("write output: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("flush output: {error}"))?;
    Ok(())
}

fn write_replace(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)
        .map_err(|error| format!("replace output: {error}"))?;
    file.write_all(bytes)
        .map_err(|error| format!("write output: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("flush output: {error}"))?;
    Ok(())
}

fn encode_to_file(
    base_path: &Path,
    target_path: &Path,
    output_path: &Path,
    replace: bool,
) -> Result<(), String> {
    let base_name = input_name(base_path)?;
    let target_name = input_name(target_path)?;
    let base = read_input(base_path)?;
    let target = read_input(target_path)?;
    let started = Instant::now();
    let (frame, mode, operations, base_frame_bytes, patch_bytes) =
        encode_pair(&base_name, &target_name, &base, &target)?;
    if replace {
        write_replace(output_path, &frame)?;
    } else {
        write_new(output_path, &frame)?;
    }
    println!(
        "{{\"frame_bytes\":{},\"mode\":{},\"operations\":{},\"base_bytes\":{},\"target_bytes\":{},\"base_frame_bytes\":{},\"encoded_body_bytes\":{},\"patch_stream_bytes\":{},\"encode_ms\":{:.3}}}",
        frame.len(),
        mode,
        operations,
        base.len(),
        target.len(),
        base_frame_bytes,
        frame
            .len()
            .saturating_sub(HEADER_BYTES + base_name.len() + target_name.len() + base_frame_bytes),
        patch_bytes,
        started.elapsed().as_secs_f64() * 1000.0,
    );
    Ok(())
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("self-check") if arguments.len() == 1 => {
            let cases = self_check()?;
            println!("{{\"self_check\":\"passed\",\"checks\":{cases}}}");
        }
        Some("encode") if arguments.len() == 4 => {
            encode_to_file(Path::new(&arguments[1]), Path::new(&arguments[2]), Path::new(&arguments[3]), false)?;
        }
        Some("encode-overwrite") if arguments.len() == 4 => {
            encode_to_file(Path::new(&arguments[1]), Path::new(&arguments[2]), Path::new(&arguments[3]), true)?;
        }
        Some("decode") if arguments.len() == 4 => {
            let frame = fs::read(&arguments[1]).map_err(|error| format!("read frame: {error}"))?;
            let started = Instant::now();
            let (base_name, target_name, base, target) = decode_pair(&frame)?;
            write_new(Path::new(&arguments[2]), &base)?;
            write_new(Path::new(&arguments[3]), &target)?;
            println!(
                "{{\"base_name\":\"{base_name}\",\"target_name\":\"{target_name}\",\"base_bytes\":{},\"target_bytes\":{},\"decode_ms\":{:.3}}}",
                base.len(), target.len(), started.elapsed().as_secs_f64() * 1000.0,
            );
        }
        Some("decode-stdout") if arguments.len() == 2 => {
            let frame = fs::read(&arguments[1]).map_err(|error| format!("read frame: {error}"))?;
            let (_, _, base, target) = decode_pair(&frame)?;
            let mut stdout = io::stdout().lock();
            stdout
                .write_all(&base)
                .map_err(|error| format!("write decoded base to stdout: {error}"))?;
            stdout
                .write_all(&target)
                .map_err(|error| format!("write decoded target to stdout: {error}"))?;
            stdout
                .flush()
                .map_err(|error| format!("flush decoded stdout: {error}"))?;
        }
        Some("verify") if arguments.len() == 4 => {
            let frame = fs::read(&arguments[1]).map_err(|error| format!("read frame: {error}"))?;
            let expected_base = read_input(Path::new(&arguments[2]))?;
            let expected_target = read_input(Path::new(&arguments[3]))?;
            let started = Instant::now();
            let (_, _, base, target) = decode_pair(&frame)?;
            if base != expected_base || target != expected_target {
                return Err("decoded pair differs from the supplied originals".into());
            }
            println!(
                "{{\"verified\":true,\"base_bytes\":{},\"target_bytes\":{},\"decode_ms\":{:.3}}}",
                base.len(), target.len(), started.elapsed().as_secs_f64() * 1000.0,
            );
        }
        _ => return Err("usage: khc-version-delta self-check | encode <base> <target> <new-frame> | encode-overwrite <base> <target> <frame> | decode <frame> <base-out> <target-out> | decode-stdout <frame> | verify <frame> <base> <target>".into()),
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}
