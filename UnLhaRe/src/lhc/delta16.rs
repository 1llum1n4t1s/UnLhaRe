//! u16 LE 差分を zigzag と二つの byte plane に変換する独立試行フレーム。
// 実装前の失敗計画: carry/borrow と全 u16 値、奇数末尾、空入力、上限超過、
// nested 長不一致、CRC 破損、reserved/filter/mode、確保前の extent 検査を確認する。
// 資源契約: plain 試行終了後に変換し、MDL 対象の変換候補は試行しない。
// mode 2 の子は record のみ許可し、legacy MDL と変換の再帰を検証段階で拒否する。

pub(super) const HEADER: usize = 40;
pub(super) const MAGIC: &[u8; 8] = b"LHC6Z16\0";
const MAX: usize = super::BLOCK_BYTES;
type Result<T> = std::result::Result<T, String>;

fn buffer(length: usize) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    output
        .try_reserve_exact(length)
        .map_err(|_| "delta16 allocation".to_string())?;
    output.resize(length, 0);
    Ok(output)
}

// 既存の ISO-HDLC 実装を使う。反射 IEEE のプロトタイプと同じ wire CRC になる。
fn crc_parts(parts: &[&[u8]]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    for part in parts {
        digest.update(part);
    }
    digest.finalize() as u32
}

fn get32(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}

fn put32(bytes: &mut [u8], at: usize, value: u32) {
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

fn transform(raw: &[u8]) -> Result<Vec<u8>> {
    let mut output = buffer(raw.len())?;
    let words = raw.len() / 2;
    let mut previous = 0u16;
    for index in 0..words {
        let word = u16::from_le_bytes([raw[2 * index], raw[2 * index + 1]]);
        let delta = word.wrapping_sub(previous);
        let folded = delta.wrapping_shl(1) ^ 0u16.wrapping_sub(delta >> 15);
        output[index] = folded as u8;
        output[words + index] = (folded >> 8) as u8;
        previous = word;
    }
    if !raw.len().is_multiple_of(2) {
        output[raw.len() - 1] = raw[raw.len() - 1];
    }
    Ok(output)
}

fn inverse(transformed: &[u8]) -> Result<Vec<u8>> {
    let mut output = buffer(transformed.len())?;
    let words = transformed.len() / 2;
    let mut previous = 0u16;
    for index in 0..words {
        let folded = u16::from_le_bytes([transformed[index], transformed[words + index]]);
        let delta = (folded >> 1) ^ 0u16.wrapping_sub(folded & 1);
        previous = previous.wrapping_add(delta);
        output[2 * index..2 * index + 2].copy_from_slice(&previous.to_le_bytes());
    }
    if !transformed.len().is_multiple_of(2) {
        output[transformed.len() - 1] = transformed[transformed.len() - 1];
    }
    Ok(output)
}

fn wrap(raw: &[u8], mode: u8, payload: &[u8]) -> Result<Vec<u8>> {
    if raw.len() > MAX
        || mode > 2
        || (mode == 0 && payload != raw)
        || (mode != 0 && (payload.len() < HEADER || payload.len() >= raw.len()))
    {
        return Err("delta16 encode bounds".into());
    }
    let mut frame = buffer(HEADER + payload.len())?;
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[10] = mode;
    frame[11] = if mode == 2 { 2 } else { 0 };
    put32(&mut frame, 12, raw.len() as u32);
    put32(&mut frame, 16, payload.len() as u32);
    put32(&mut frame, 20, crc_parts(&[raw]));
    frame[HEADER..].copy_from_slice(payload);
    let wire_crc = crc_parts(&[&frame[..24], &frame[28..]]);
    put32(&mut frame, 24, wire_crc);
    Ok(frame)
}

fn encode_plain(raw: &[u8]) -> Result<Vec<u8>> {
    let child = super::g32::encode_trial(raw)?;
    if child.len() >= raw.len() {
        wrap(raw, 0, raw)
    } else {
        wrap(raw, 1, &child)
    }
}

/// plain と許可された変換候補の全試行費用を、この呼び出し内で払う。
pub(super) fn encode_selected(raw: &[u8]) -> Result<Vec<u8>> {
    if raw.len() > MAX {
        return Err("delta16 raw limit".into());
    }
    // child の workspace と出力を解放してから、変換 buffer を生成する。
    let plain = encode_plain(raw)?;
    let transformed = transform(raw)?;
    let text = transformed
        .iter()
        .filter(|&&byte| matches!(byte, 9 | 10 | 13 | 32..=126))
        .count();
    // g32::encode_hybrid(adaptive=true) の use_mdl 条件と完全一致する固定 admission。
    if text * 10 >= transformed.len() * 9 {
        return Ok(plain);
    }
    let child = super::g32::encode_trial(&transformed)?;
    if child.get(..8) != Some(&super::record::MAGIC[..]) {
        return Err("delta16 candidate resource contract: record child required".into());
    }
    if child.len() >= raw.len() {
        return Ok(plain);
    }
    super::validate_gather32_frame(&child, raw.len()).map_err(|error| error.to_string())?;
    let candidate = wrap(raw, 2, &child)?;
    // 同サイズなら既存 plain を選び、選択基準は完全フレームサイズのままにする。
    if candidate.len() < plain.len() {
        Ok(candidate)
    } else {
        Ok(plain)
    }
}

/// 外側の extent/CRC と子の構造を、展開用の確保・metadata 読み取り前に検査する。
pub(super) fn validate_frame(frame: &[u8], expected: usize) -> Result<()> {
    if expected > MAX || frame.len() < HEADER || frame.len() > MAX + HEADER {
        return Err("delta16 extent limit".into());
    }
    if frame.get(..8) != Some(&MAGIC[..])
        || frame[8..10] != 1u16.to_le_bytes()
        || frame[10] > 2
        || frame[11] != if frame[10] == 2 { 2 } else { 0 }
        || frame[28..HEADER].iter().any(|&byte| byte != 0)
    {
        return Err("delta16 header/version/reserved/filter".into());
    }
    let raw = get32(frame, 12);
    let payload_length = get32(frame, 16);
    let mode = frame[10];
    if raw != expected
        || raw > MAX
        || payload_length > MAX
        || payload_length.checked_add(HEADER) != Some(frame.len())
        || (mode == 0 && payload_length != raw)
        || (mode != 0 && (payload_length < HEADER || payload_length >= raw))
    {
        return Err("delta16 bounds/expected length".into());
    }
    if crc_parts(&[&frame[..24], &frame[28..]]) != get32(frame, 24) as u32 {
        return Err("delta16 wire CRC".into());
    }
    let payload = &frame[HEADER..];
    if mode == 0 {
        if crc_parts(&[payload]) != get32(frame, 20) as u32 {
            return Err("delta16 plain CRC".into());
        }
        return Ok(());
    }
    if get32(payload, 12) != raw {
        return Err("delta16 nested raw mismatch".into());
    }
    if mode == 2 && payload.get(..8) != Some(&super::record::MAGIC[..]) {
        return Err("delta16 transformed child must be record".into());
    }
    super::validate_gather32_frame(payload, raw).map_err(|error| error.to_string())
}

pub(super) fn decode(frame: &[u8]) -> Result<Vec<u8>> {
    if frame.len() < HEADER {
        return Err("delta16 header truncated".into());
    }
    let raw = get32(frame, 12);
    validate_frame(frame, raw)?;
    let payload = &frame[HEADER..];
    if frame[10] == 0 {
        let mut output = buffer(raw)?;
        output.copy_from_slice(payload);
        return Ok(output);
    }
    // 検証済み Gather32/record だけが到達し、Delta16 への再帰は生じない。
    let decoded = super::decompress_block(payload).map_err(|error| error.to_string())?;
    if decoded.len() != raw {
        return Err("delta16 decoded length".into());
    }
    let output = if frame[10] == 2 {
        inverse(&decoded)?
    } else {
        decoded
    };
    if crc_parts(&[&output]) != get32(frame, 20) as u32 {
        return Err("delta16 plain CRC".into());
    }
    Ok(output)
}
