//! PRIVATE KWI1BLK v1。初出の最大ASCII単語をliteralで送り、閉じた順で辞書を学習する。
//! 失敗先行: 短いheader、未来ID、非canonical varint、語境界の結合、長さ/CRC不一致、予約超過を拒否する。
//! callerは借用raw/frameのbackingを含む、呼出側が独立計測した保持capacityの合計。
//! logical_peakはcaller込みのrequested/reserved上界。RSSや任意allocatorの物理容量を保証しない。

use crc_fast::{CrcAlgorithm, Digest, checksum};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::mem::size_of;

pub const MAX_RAW: usize = 1 << 20;
pub const MAX_STREAM: usize = 512 << 10;
pub const HEADER: usize = 40;
pub type Result<T> = std::result::Result<T, String>;

const MAGIC: &[u8; 8] = b"KWI1BLK\0";
const NATIVE_MAGIC: &[u8; 8] = b"KHC1BLK\0";
const DICTIONARY: usize = 16384;
const WORK_RESERVE: usize = 8 << 20;
const NATIVE_RESERVE: usize = 56 << 20;
const MEMORY_LIMIT: usize = 64 << 20;
const SMALL_STATE: usize = 4096;

#[derive(Debug)]
pub struct Stats {
    pub method: u8,
    pub dictionary: usize,
    pub stream: usize,
    pub logical_peak: usize,
}

struct Budget {
    caller: usize,
    peak: usize,
}

impl Budget {
    fn new(caller: usize) -> Result<Self> {
        if caller > MEMORY_LIMIT {
            return Err("caller memory exceeds 64MiB".into());
        }
        Ok(Self { caller, peak: caller })
    }

    fn charge(&mut self, local: usize) -> Result<()> {
        let total = self.caller.checked_add(local).ok_or("memory sum overflow")?;
        if total > MEMORY_LIMIT {
            return Err("caller-included memory exceeds 64MiB".into());
        }
        self.peak = self.peak.max(total);
        Ok(())
    }

    // このphaseの8MiBには辞書・出力・小さな状態を含み、別phaseのnative scratchは生存しない。
    fn work(&mut self, retained: usize) -> Result<()> {
        self.charge(retained.checked_add(WORK_RESERVE).ok_or("work reserve overflow")?)
    }

    fn live(&mut self, retained: usize, local: usize) -> Result<()> {
        if local > WORK_RESERVE {
            return Err("transform retained capacities exceed 8MiB".into());
        }
        self.charge(retained.checked_add(local).ok_or("live capacity overflow")?)
    }

    // nativeを呼ぶ前に、保持streamとnative返却bufferのrequested上界を追加予約する。
    fn native(&mut self, retained: usize, returned: usize) -> Result<()> {
        let local = NATIVE_RESERVE
            .checked_add(retained)
            .and_then(|n| n.checked_add(returned))
            .ok_or("native reserve overflow")?;
        self.charge(local)
    }
}

#[derive(Clone, Copy)]
struct Word {
    bytes: [u8; 64],
    len: u8,
}

impl Word {
    fn new(bytes: &[u8]) -> Self {
        let mut word = Self {
            bytes: [0; 64],
            len: bytes.len() as u8,
        };
        word.bytes[..bytes.len()].copy_from_slice(bytes);
        word
    }

    fn bytes(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}

impl PartialEq for Word {
    fn eq(&self, other: &Self) -> bool {
        self.bytes() == other.bytes()
    }
}
impl Eq for Word {}
impl Hash for Word {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.bytes().hash(state);
    }
}

struct Dictionary {
    ids: HashMap<Word, u16>,
    words: Vec<Word>,
    entries_reserved: usize,
    hash_capacity_max: usize,
    word_capacity_max: usize,
}

impl Dictionary {
    fn new(raw_len: usize, output_capacity: usize, retained: usize, budget: &mut Budget) -> Result<Self> {
        let entries = DICTIONARY.min(raw_len / 3);
        // HashMapは一度だけreserve。通常std tableのcapacity/bucket比を余分な2倍で事前課金する。
        let buckets = if entries == 0 { 0 } else { (entries + 1).next_power_of_two() * 2 };
        let predicted = buckets
            .checked_mul(size_of::<(Word, u16)>() + 1)
            .and_then(|n| n.checked_add(entries * size_of::<Word>()))
            .and_then(|n| n.checked_add(output_capacity + SMALL_STATE))
            .ok_or("dictionary reserve overflow")?;
        budget.live(retained, predicted)?;
        let mut ids = HashMap::new();
        ids.try_reserve(entries).map_err(|_| "dictionary hash allocation")?;
        let mut words = Vec::new();
        words.try_reserve_exact(entries).map_err(|_| "dictionary word allocation")?;
        let dictionary = Self {
            hash_capacity_max: ids.capacity(),
            word_capacity_max: words.capacity(),
            ids,
            words,
            entries_reserved: entries,
        };
        budget.live(retained, dictionary.live(output_capacity)?)?;
        Ok(dictionary)
    }

    fn live(&self, output_capacity: usize) -> Result<usize> {
        // capacityはusable entries。次のpower-of-two bucket数+control bytesとalignment余白を課金。
        let buckets = if self.hash_capacity_max == 0 {
            0
        } else {
            self.hash_capacity_max
                .checked_add(1)
                .ok_or("hash capacity overflow")?
                .checked_next_power_of_two()
                .ok_or("hash bucket overflow")?
        };
        buckets
            .checked_mul(size_of::<(Word, u16)>() + 1)
            .and_then(|n| n.checked_add(self.word_capacity_max.checked_mul(size_of::<Word>())?))
            .and_then(|n| n.checked_add(output_capacity))
            .and_then(|n| n.checked_add(SMALL_STATE))
            .ok_or_else(|| "dictionary live capacity overflow".into())
    }

    fn learn(&mut self, word: Word) -> Result<()> {
        if self.words.len() == DICTIONARY || self.ids.contains_key(&word) {
            return Ok(());
        }
        // 暗黙growを禁止し、再hashのold/new同時保持を作らない。最短単語3Bよりentries予約は十分。
        if self.words.len() >= self.entries_reserved || self.words.len() >= self.words.capacity() || self.ids.len() >= self.ids.capacity() {
            return Err("dictionary prepaid capacity exhausted".into());
        }
        let id = u16::try_from(self.words.len()).map_err(|_| "dictionary ID overflow")?;
        if self.ids.insert(word, id).is_some() {
            return Err("dictionary duplicate state".into());
        }
        self.words.push(word);
        self.hash_capacity_max = self.hash_capacity_max.max(self.ids.capacity());
        self.word_capacity_max = self.word_capacity_max.max(self.words.capacity());
        Ok(())
    }
}

fn letter(byte: u8) -> bool {
    byte.is_ascii_alphabetic()
}

fn buffer(capacity: usize) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    output.try_reserve_exact(capacity).map_err(|_| "output allocation")?;
    Ok(output)
}

fn write_literal(stream: &mut Vec<u8>, byte: u8) -> bool {
    let required = if byte == 0 { 2 } else { 1 };
    if stream.len() > MAX_STREAM - required {
        return false;
    }
    stream.push(byte);
    if byte == 0 {
        stream.push(0);
    }
    true
}

fn write_reference(stream: &mut Vec<u8>, id: u16) -> bool {
    let mut value = u32::from(id) + 1;
    let mut bytes = [0u8; 4];
    let mut len = 1;
    loop {
        bytes[len] = (value & 127) as u8;
        value >>= 7;
        if value != 0 {
            bytes[len] |= 128;
        }
        len += 1;
        if value == 0 {
            break;
        }
    }
    if stream.len() > MAX_STREAM - len {
        return false;
    }
    stream.extend_from_slice(&bytes[..len]);
    true
}

fn transform_inner(raw: &[u8], budget: &mut Budget) -> Result<Option<(Vec<u8>, usize)>> {
    if raw.len() > MAX_RAW {
        return Err("raw exceeds 1MiB".into());
    }
    budget.work(0)?;
    let mut dictionary = Dictionary::new(raw.len(), MAX_STREAM, 0, budget)?;
    let mut stream = buffer(MAX_STREAM)?;
    budget.live(0, dictionary.live(stream.capacity())?)?;
    let mut at = 0;
    while at < raw.len() {
        if !letter(raw[at]) {
            if !write_literal(&mut stream, raw[at]) {
                return Ok(None);
            }
            at += 1;
            continue;
        }
        let start = at;
        while at < raw.len() && letter(raw[at]) {
            at += 1;
        }
        let word_bytes = &raw[start..at];
        if (3..=64).contains(&word_bytes.len()) {
            let word = Word::new(word_bytes);
            if let Some(&id) = dictionary.ids.get(&word) {
                if !write_reference(&mut stream, id) {
                    return Ok(None);
                }
            } else {
                if word_bytes.len() > MAX_STREAM - stream.len() {
                    return Ok(None);
                }
                stream.extend_from_slice(word_bytes);
                // 最大単語の終端を確認した後だけ登録。Hash seed/iterationはID順に使わない。
                dictionary.learn(word)?;
            }
        } else {
            if word_bytes.len() > MAX_STREAM - stream.len() {
                return Ok(None);
            }
            stream.extend_from_slice(word_bytes);
        }
    }
    budget.live(0, dictionary.live(stream.capacity())?)?;
    Ok(Some((stream, dictionary.words.len())))
}

pub fn transform(raw: &[u8], caller: usize) -> Result<Option<(Vec<u8>, usize)>> {
    transform_inner(raw, &mut Budget::new(caller)?)
}

fn read_code(stream: &[u8], at: &mut usize) -> Result<usize> {
    let mut code = 0usize;
    for byte_index in 0..3 {
        let byte = *stream.get(*at).ok_or("truncated escape varint")?;
        *at += 1;
        code |= usize::from(byte & 127) << (7 * byte_index);
        if byte & 128 == 0 {
            if (byte_index != 0 && byte & 127 == 0) || code > DICTIONARY {
                return Err("noncanonical/out-of-range escape varint".into());
            }
            return Ok(code);
        }
    }
    Err("escape varint exceeds three bytes".into())
}

fn append(output: &mut Vec<u8>, bytes: &[u8], raw_len: usize) -> Result<()> {
    let end = output.len().checked_add(bytes.len()).ok_or("restored length overflow")?;
    if end > raw_len || end > output.capacity() {
        return Err("restored output overrun".into());
    }
    output.extend_from_slice(bytes);
    Ok(())
}

fn close_word(dictionary: &mut Dictionary, pending: &[u8; 64], pending_len: &mut usize) -> Result<()> {
    if (3..=64).contains(pending_len) {
        dictionary.learn(Word::new(&pending[..*pending_len]))?;
    }
    *pending_len = 0;
    Ok(())
}

fn restore_inner(stream: &[u8], raw_len: usize, retained: usize, budget: &mut Budget) -> Result<(Vec<u8>, usize)> {
    if raw_len > MAX_RAW || stream.len() > MAX_STREAM {
        return Err("restore raw/stream limit".into());
    }
    budget.work(retained)?;
    let mut dictionary = Dictionary::new(raw_len, raw_len, retained, budget)?;
    let mut output = buffer(raw_len)?;
    budget.live(retained, dictionary.live(output.capacity())?)?;
    let mut at = 0;
    let mut pending = [0u8; 64];
    let mut pending_len = 0usize;
    let mut after_reference = false;
    while at < stream.len() {
        let mut byte = stream[at];
        at += 1;
        if byte == 0 {
            let code = read_code(stream, &mut at)?;
            if code != 0 {
                if pending_len != 0 || after_reference {
                    return Err("word reference has no left boundary".into());
                }
                let word = dictionary.words.get(code - 1).ok_or("word reference to future ID")?;
                append(&mut output, word.bytes(), raw_len)?;
                after_reference = true;
                continue;
            }
            byte = 0;
        }
        if letter(byte) {
            if after_reference {
                return Err("literal letter joins referenced word".into());
            }
            if pending_len < 64 {
                pending[pending_len] = byte;
            }
            pending_len = (pending_len + 1).min(65);
        } else {
            close_word(&mut dictionary, &pending, &mut pending_len)?;
            after_reference = false;
        }
        append(&mut output, &[byte], raw_len)?;
    }
    close_word(&mut dictionary, &pending, &mut pending_len)?;
    if output.len() != raw_len {
        return Err("restored output underflow".into());
    }
    budget.live(retained, dictionary.live(output.capacity())?)?;
    Ok((output, dictionary.words.len()))
}

pub fn restore(stream: &[u8], raw_len: usize, caller: usize) -> Result<(Vec<u8>, usize)> {
    restore_inner(stream, raw_len, 0, &mut Budget::new(caller)?)
}

pub fn crc(raw: &[u8]) -> u32 {
    checksum(CrcAlgorithm::Crc32IsoHdlc, raw) as u32
}

fn wire_crc(frame: &[u8]) -> u32 {
    let mut digest = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..28]);
    digest.update(&frame[32..]);
    digest.finalize() as u32
}

// 意図的にsemantic fieldは検査しない。親の破損frame検証でwire CRCだけを再計算する。
pub fn seal(frame: &mut [u8]) -> Result<()> {
    if frame.len() < HEADER {
        return Err("private header truncated".into());
    }
    let value = wire_crc(frame);
    frame[28..32].copy_from_slice(&value.to_le_bytes());
    Ok(())
}

fn get32(bytes: &[u8], at: usize) -> Result<usize> {
    let field = bytes.get(at..at + 4).ok_or("private u32 truncated")?;
    Ok(u32::from_le_bytes(field.try_into().map_err(|_| "private u32 field")?) as usize)
}

fn put32(bytes: &mut [u8], at: usize, value: usize) -> Result<()> {
    let value = u32::try_from(value).map_err(|_| "private u32 overflow")?;
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
    Ok(())
}

fn make_frame(raw: &[u8], stream_len: usize, body: &[u8], method: u8, retained: usize, budget: &mut Budget) -> Result<Vec<u8>> {
    let length = HEADER.checked_add(body.len()).ok_or("private frame length overflow")?;
    if length > MAX_RAW + HEADER {
        return Err("private frame limit".into());
    }
    budget.work(retained)?;
    budget.live(retained, length + SMALL_STATE)?;
    let mut frame = buffer(length)?;
    budget.live(retained, frame.capacity() + SMALL_STATE)?;
    frame.resize(HEADER, 0);
    frame[..8].copy_from_slice(MAGIC);
    frame[8] = 1;
    frame[9] = method;
    put32(&mut frame, 12, raw.len())?;
    put32(&mut frame, 16, stream_len)?;
    put32(&mut frame, 20, body.len())?;
    put32(&mut frame, 24, crc(raw) as usize)?;
    put32(&mut frame, 32, DICTIONARY)?;
    frame.extend_from_slice(body);
    seal(&mut frame)?;
    Ok(frame)
}

fn stored(raw: &[u8], budget: &mut Budget) -> Result<(Vec<u8>, Stats)> {
    let frame = make_frame(raw, 0, raw, 0, 0, budget)?;
    Ok((
        frame,
        Stats {
            method: 0,
            dictionary: 0,
            stream: 0,
            logical_peak: budget.peak,
        },
    ))
}

pub fn encode(raw: &[u8], caller: usize) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_RAW {
        return Err("raw exceeds 1MiB".into());
    }
    let mut budget = Budget::new(caller)?;
    let Some((stream, dictionary)) = transform_inner(raw, &mut budget)? else {
        return stored(raw, &mut budget);
    };
    let stream_len = stream.len();
    let inner_bound = stream_len.checked_add(HEADER).ok_or("native frame bound overflow")?;
    budget.native(stream.capacity(), inner_bound)?;
    let inner = unlhare::lhc::compress_block(&stream).map_err(|error| format!("native encode: {error}"))?;
    budget.native(stream.capacity(), inner.capacity())?;
    if inner.len() < HEADER || inner.len() > inner_bound || inner.get(..8) != Some(NATIVE_MAGIC.as_slice()) || get32(&inner, 12)? != stream_len {
        return Err("native encoder frame invariant".into());
    }
    drop(stream);
    // 圧縮失敗は伝播する。stored選択はtransform cap到達か、完全frameにサイズ利益がない場合だけ。
    if inner.len() >= raw.len() {
        drop(inner);
        return stored(raw, &mut budget);
    }
    let frame = make_frame(raw, stream_len, &inner, 1, inner.capacity(), &mut budget)?;
    Ok((
        frame,
        Stats {
            method: 1,
            dictionary,
            stream: stream_len,
            logical_peak: budget.peak,
        },
    ))
}

pub fn decode(frame: &[u8], caller: usize) -> Result<(Vec<u8>, Stats)> {
    let mut budget = Budget::new(caller)?;
    if frame.len() < HEADER || frame.len() > MAX_RAW + HEADER {
        return Err("private frame extent limit".into());
    }
    if frame.get(..8) != Some(MAGIC.as_slice()) || frame[8] != 1 {
        return Err("private magic/version".into());
    }
    if frame[9] > 1 || frame[10..12] != [0, 0] || get32(frame, 32)? != DICTIONARY || get32(frame, 36)? != 0 {
        return Err("private method/flags/cap/reserved".into());
    }
    let raw_len = get32(frame, 12)?;
    let stream_len = get32(frame, 16)?;
    let body_len = get32(frame, 20)?;
    if raw_len > MAX_RAW || HEADER.checked_add(body_len) != Some(frame.len()) {
        return Err("private declared length".into());
    }
    if wire_crc(frame) != get32(frame, 28)? as u32 {
        return Err("private wire CRC".into());
    }
    let body = &frame[HEADER..];
    if frame[9] == 0 {
        if stream_len != 0 || body_len != raw_len {
            return Err("stored private lengths".into());
        }
        if crc(body) != get32(frame, 24)? as u32 {
            return Err("private raw CRC".into());
        }
        budget.work(0)?;
        budget.live(0, raw_len + SMALL_STATE)?;
        let mut raw = buffer(raw_len)?;
        budget.live(0, raw.capacity() + SMALL_STATE)?;
        raw.extend_from_slice(body);
        return Ok((
            raw,
            Stats {
                method: 0,
                dictionary: 0,
                stream: 0,
                logical_peak: budget.peak,
            },
        ));
    }
    if stream_len > MAX_STREAM
        || body.len() < HEADER
        || body.len() > stream_len + HEADER
        || body.get(..8) != Some(NATIVE_MAGIC.as_slice())
        || get32(body, 12)? != stream_len
    {
        return Err("coded private/native lengths or magic".into());
    }
    // Inner revision/flags/method/exact extent/CRCは変更していないnative decoderが検査する。
    budget.native(0, stream_len)?;
    let stream = unlhare::lhc::decompress_block(body).map_err(|error| format!("native decode: {error}"))?;
    budget.native(0, stream.capacity())?;
    if stream.len() != stream_len {
        return Err("native decoded stream length".into());
    }
    let (raw, dictionary) = restore_inner(&stream, raw_len, stream.capacity(), &mut budget)?;
    if crc(&raw) != get32(frame, 24)? as u32 {
        return Err("private raw CRC".into());
    }
    Ok((
        raw,
        Stats {
            method: 1,
            dictionary,
            stream: stream_len,
            logical_peak: budget.peak,
        },
    ))
}
