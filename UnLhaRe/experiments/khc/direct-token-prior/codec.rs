//! next-use rank/run lengthをmulti-symbol intervalへまとめる別研究形式。
//! KHNPR001 / 36-byte LE header / 正準packed alphabet / integer CDF。
//! 製品wireや旧研究形式との互換性は主張しない。
#[path = "../causal-bayes-sais/bwt.rs"]
mod bwt;
use bwt::bwt;
#[allow(dead_code)]
#[path = "../rejected-binary-mix/packed_alphabet.rs"]
mod packed_alphabet;
mod cdf_model;
mod prior_math;
#[path = "../direct-token/multi_range.rs"]
mod multi_range;
use cdf_model::ContextModel;
use multi_range::{Encoder, Decoder};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD: usize = (MAX_INPUT + 1) * 8 + 32;
const MAX_FRAME: usize = MAX_PAYLOAD + 281;
const MAGIC: &[u8; 8] = b"KHNPR001";
type Result<T> = std::result::Result<T, String>;
fn payload_limit(n: usize) -> Result<usize> {
    if n == 0 || n > MAX_INPUT + 1 { return Err("transform length outside bounds".into()); }
    n.checked_mul(8).and_then(|n| n.checked_add(32)).ok_or("payload bound overflow".into())
}

fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}

fn crc_table() -> [u32; 256] {
    std::array::from_fn(|i| {
        let mut c = i as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ if c & 1 != 0 { 0xedb8_8320 } else { 0 };
        }
        c
    })
}

fn crc_parts(parts: &[&[u8]]) -> u32 {
    let table = crc_table();
    let mut c = u32::MAX;
    for part in parts {
        for &b in *part {
            c = (c >> 8) ^ table[((c as u8) ^ b) as usize];
        }
    }
    !c
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| format!("input open: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("input metadata: {e}"))?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(meta.len() as usize)
        .map_err(|_| "input allocation failed")?;
    f.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("input read: {e}"))?;
    if bytes.len() > limit {
        return Err("input exceeds limit".into());
    }
    Ok(bytes)
}

fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(e) = f.write_all(bytes).and_then(|()| f.sync_all()) {
        drop(f);
        // 今回create_newで作った出力だけを、I/O失敗時に清掃する。
        let _ = std::fs::remove_file(path);
        return Err(format!("output write: {e}"));
    }
    Ok(())
}

fn inverse_bwt(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Vec<u8>> {
    let n = last.len();
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0_usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] += 1;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &c) in counts.iter().enumerate() {
        if (c != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0_usize; 257];
    let mut total = 0;
    for (i, &c) in counts.iter().enumerate() {
        starts[i] = total;
        total += c;
    }
    let mut occurrence = [0_usize; 257];
    let mut lf = filled(n, 0_usize)?;
    for (i, &s) in last.iter().enumerate() {
        let s = s as usize;
        lf[i] = starts[s] + occurrence[s];
        occurrence[s] += 1;
    }
    let mut visited = filled(n, false)?;
    let mut text = filled(n, 0_u16)?;
    let mut row = primary;
    for out in text.iter_mut().rev() {
        if row >= n || visited[row] {
            return Err("LF cycle inconsistent".into());
        }
        visited[row] = true;
        *out = last[row];
        row = lf[row];
    }
    if row != primary
        || !visited.iter().all(|&v| v)
        || text[n - 1] != 0
        || text[..n - 1].contains(&0)
    {
        return Err("LF cycle/sentinel inconsistent".into());
    }
    let mut result = filled(n - 1, 0_u8)?;
    for (out, &s) in result.iter_mut().zip(&text) {
        *out = (s - 1) as u8;
    }
    Ok(result)
}


#[derive(Clone, Copy, Default)]
struct TokenAudit { rank_intervals: usize, length_intervals: usize, escape_bytes: usize }
enum Coder<'a> { Encode(Encoder), Decode(Decoder<'a>) }
struct Stream<'a> {
    coder: Coder<'a>,
    ranks: ContextModel,
    lengths: ContextModel,
    previous: [u16; 257],
    audit: TokenAudit,
}
impl<'a> Stream<'a> {
    fn new(coder: Coder<'a>) -> Result<Self> {
        Ok(Self {
            coder, ranks: ContextModel::new(257, 257 * 4)?,
            lengths: ContextModel::new(256, 257 * 9)?,
            previous: [0; 257], audit: TokenAudit::default(),
        })
    }
    fn token(coder: &mut Coder<'a>, model: &mut ContextModel, key: usize,
        desired: usize, limit: usize) -> Result<usize>
    {
        let token = match coder {
            Coder::Encode(encoder) => {
                let (c, f, t) = model.interval(key, desired, limit)?;
                encoder.interval(c, f, t)?;
                desired
            }
            Coder::Decode(decoder) => {
                let total = model.interval(key, 0, limit)?.2;
                let slot = decoder.slot(total)?;
                let (token, c, f, t) = model.select(key, slot, limit)?;
                decoder.consume(c, f, t)?;
                token
            }
        };
        model.update(key, token)?;
        Ok(token)
    }
    fn rank(&mut self, symbol: u16, desired: usize, active: usize) -> Result<usize> {
        let key = usize::from(symbol) * 4 + usize::from(self.previous[usize::from(symbol)].min(3));
        let rank = Self::token(&mut self.coder, &mut self.ranks, key, desired, active)?;
        self.audit.rank_intervals += 1;
        Ok(rank)
    }
    fn byte(&mut self, desired: u8) -> Result<u8> {
        let byte = match &mut self.coder {
            Coder::Encode(encoder) => {
                encoder.interval(u32::from(desired), 1, 256)?;
                desired
            }
            Coder::Decode(decoder) => {
                let byte = decoder.slot(256)?;
                decoder.consume(byte, 1, 256)?;
                u8::try_from(byte).map_err(|_| "uniform byte outside bounds")?
            }
        };
        self.audit.escape_bytes += 1;
        Ok(byte)
    }
    fn length(&mut self, symbol: u16, desired: usize, rank: usize, remaining: usize) -> Result<usize> {
        if remaining == 0 { return Err("no remaining transform symbols".into()); }
        if matches!(self.coder, Coder::Encode(_)) && (desired == 0 || desired > remaining) {
            return Err("run length outside remaining bound".into());
        }
        let rank_context = (usize::BITS - 1 - (rank + 1).leading_zeros()) as usize;
        let key = usize::from(symbol) * 9 + rank_context;
        let token = Self::token(&mut self.coder, &mut self.lengths, key,
            desired.saturating_sub(1).min(255), remaining.min(256))?;
        self.audit.length_intervals += 1;
        if token < 255 { return Ok(token + 1); }
        if matches!(self.coder, Coder::Encode(_)) {
            let mut value = u32::try_from(desired - 256).map_err(|_| "length escape overflow")?;
            loop {
                let mut byte = (value & 127) as u8;
                value >>= 7;
                if value != 0 { byte |= 128; }
                self.byte(byte)?;
                if value == 0 { break; }
            }
            Ok(desired)
        } else {
            let mut value = 0u32;
            for index in 0..4 {
                let byte = self.byte(0)?;
                let group = u32::from(byte & 127);
                value |= group << (index * 7);
                if byte & 128 == 0 {
                    if index != 0 && group == 0 { return Err("noncanonical length escape".into()); }
                    let length = (value as usize).checked_add(256).ok_or("length escape overflow")?;
                    if length > remaining { return Err("run length outside remaining bound".into()); }
                    return Ok(length);
                }
            }
            Err("length escape exceeds four bytes".into())
        }
    }
    fn run_done(&mut self, symbol: u16, rank: usize) {
        self.previous[usize::from(symbol)] = rank as u16;
    }
}

#[derive(Clone, Copy)]
struct Run { symbol: u16, length: u32, next: u32 }
const _: () = assert!(std::mem::size_of::<Run>() == 12);

fn encode_payload(last: &[u16]) -> Result<(Vec<u8>, Vec<u16>, usize, TokenAudit)> {
    let limit = payload_limit(last.len())?;
    let run_count = last.iter().enumerate()
        .filter(|&(i, symbol)| i == 0 || last[i - 1] != *symbol).count();
    let mut runs: Vec<Run> = Vec::new();
    runs.try_reserve_exact(run_count).map_err(|_| "run allocation failed")?;
    for &symbol in last {
        if let Some(run) = runs.last_mut().filter(|run| run.symbol == symbol) {
            run.length = run.length.checked_add(1).ok_or("run length overflow")?;
        } else { runs.push(Run { symbol, length: 1, next: u32::MAX }); }
    }
    let mut next = [u32::MAX; 257];
    for (index, run) in runs.iter_mut().enumerate().rev() {
        run.next = next[usize::from(run.symbol)];
        next[usize::from(run.symbol)] = u32::try_from(index).map_err(|_| "run index overflow")?;
    }
    let mut alphabet = Vec::new();
    alphabet.try_reserve_exact(257).map_err(|_| "alphabet allocation failed")?;
    for run in &runs { if !alphabet.contains(&run.symbol) { alphabet.push(run.symbol); } }
    let mut active = filled(alphabet.len(), 0u16)?;
    active.copy_from_slice(&alphabet);
    let mut stream = Stream::new(Coder::Encode(Encoder::with_limit(limit)?))?;
    let mut consumed = 0usize;
    for (index, run) in runs.iter().enumerate() {
        if active.first() != Some(&run.symbol) || next[usize::from(run.symbol)] as usize != index {
            return Err("next-use head inconsistent".into());
        }
        let symbol = active.remove(0);
        next[usize::from(symbol)] = run.next;
        let rank = if run.next == u32::MAX { 0 } else {
            let rank = active.iter().position(|&s| next[usize::from(s)] > run.next).unwrap_or(active.len());
            if rank == 0 { return Err("adjacent run symbol".into()); }
            rank
        };
        stream.rank(symbol, rank, active.len() + 1)?;
        let length = run.length as usize;
        stream.length(symbol, length, rank, last.len() - consumed)?;
        consumed = consumed.checked_add(length).ok_or("run sum overflow")?;
        stream.run_done(symbol, rank);
        if rank != 0 { active.insert(rank, symbol); }
    }
    if !active.is_empty() || consumed != last.len() { return Err("remaining next-use symbols".into()); }
    let Coder::Encode(encoder) = stream.coder else { unreachable!() };
    Ok((encoder.finish()?, alphabet, runs.len(), stream.audit))
}

fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize) -> Result<(Vec<u16>, usize, TokenAudit)> {
    payload_limit(n)?;
    let mut active = filled(alphabet.len(), 0u16)?;
    active.copy_from_slice(alphabet);
    let mut last = Vec::new();
    last.try_reserve_exact(n).map_err(|_| "BWT allocation failed")?;
    let mut stream = Stream::new(Coder::Decode(Decoder::new(payload)?))?;
    let mut runs = 0usize;
    while last.len() < n {
        let symbol = *active.first().ok_or("active list exhausted before declared length")?;
        let rank = stream.rank(symbol, 0, active.len())?;
        let length = stream.length(symbol, 1, rank, n - last.len())?;
        if last.last() == Some(&symbol) { return Err("non-maximal adjacent run".into()); }
        let end = last.len().checked_add(length).ok_or("run sum overflow")?;
        if end > n { return Err("run length outside remaining bound".into()); }
        last.resize(end, symbol);
        active.remove(0);
        if rank != 0 { active.insert(rank, symbol); }
        stream.run_done(symbol, rank);
        runs += 1;
    }
    if !active.is_empty() { return Err("active list not empty at end".into()); }
    let Coder::Decode(decoder) = stream.coder else { unreachable!() };
    decoder.finish()?;
    Ok((last, runs, stream.audit))
}

fn field(frame: &[u8], offset: usize) -> usize {
    u32::from_le_bytes(frame[offset..offset + 4].try_into().unwrap()) as usize
}
struct Stats {
    runs: usize,
    primary: usize,
    alphabet: usize,
    payload: usize,
    plain_crc: u32,
    payload_crc: u32,
    tokens: TokenAudit,
}

fn encode(input: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if input.len() > MAX_INPUT { return Err("input exceeds limit".into()); }
    let (last, primary) = bwt(input)?;
    let (payload, alphabet, runs, tokens) = encode_payload(&last)?;
    let plain_crc = crc_parts(&[input]);
    let payload_crc = crc_parts(&[&payload]);
    let metadata = packed_alphabet::encode(&alphabet)?;
    let header_len = 36_usize
        .checked_add(metadata.len())
        .ok_or("header overflow")?;
    let frame_len = header_len
        .checked_add(payload.len())
        .ok_or("frame overflow")?;
    let mut frame = Vec::new();
    frame
        .try_reserve_exact(frame_len)
        .map_err(|_| "frame allocation failed")?;
    frame.extend_from_slice(MAGIC);
    for value in [
        input.len(),
        primary,
        alphabet.len(),
        payload.len(),
        plain_crc as usize,
        payload_crc as usize,
        0,
    ] {
        frame.extend_from_slice(
            &u32::try_from(value)
                .map_err(|_| "frame field overflow")?
                .to_le_bytes(),
        );
    }
    frame.extend_from_slice(&metadata);
    let header_crc = crc_parts(&[&frame[..32], &frame[36..header_len]]);
    frame[32..36].copy_from_slice(&header_crc.to_le_bytes());
    frame.extend_from_slice(&payload);
    Ok((
        frame,
        Stats {
            runs,
            primary,
            alphabet: alphabet.len(),
            payload: payload.len(),
            plain_crc,
            payload_crc,
            tokens,
        },
    ))
}

fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < 36 || &frame[..8] != MAGIC {
        return Err("bad frame magic/header".into());
    }
    let length = field(frame, 8);
    let primary = field(frame, 12);
    let alphabet_len = field(frame, 16);
    let payload_len = field(frame, 20);
    let plain_crc = field(frame, 24) as u32;
    let payload_crc = field(frame, 28) as u32;
    if length > MAX_INPUT
        || primary > length
        || !(1..=257).contains(&alphabet_len)
        || !(5..=MAX_PAYLOAD).contains(&payload_len)
    {
        return Err("frame fields outside bounds".into());
    }
    if payload_len > payload_limit(length + 1)? { return Err("payload exceeds transformed bound".into()); }
    // payload長からmetadata境界を求め、凍結decoderで正準幅と順位を検査する。
    let header_len = frame
        .len()
        .checked_sub(payload_len)
        .ok_or("frame length mismatch")?;
    if !(69..=281).contains(&header_len) {
        return Err("packed header length outside bounds".into());
    }
    let full_len = header_len
        .checked_add(payload_len)
        .ok_or("frame overflow")?;
    if full_len != frame.len() {
        return Err("frame length mismatch".into());
    }
    if crc_parts(&[&frame[..32], &frame[36..header_len]]) != field(frame, 32) as u32 {
        return Err("header CRC mismatch".into());
    }
    let alphabet = packed_alphabet::decode(&frame[36..header_len])?;
    if alphabet.len() != alphabet_len {
        return Err("packed alphabet count mismatch".into());
    }
    let payload = &frame[header_len..];
    if crc_parts(&[payload]) != payload_crc {
        return Err("payload CRC mismatch".into());
    }
    let (last, runs, tokens) = decode_payload(
        payload,
        &alphabet,
        length.checked_add(1).ok_or("transform length overflow")?,
    )?;
    let plain = inverse_bwt(&last, primary, &alphabet)?;
    if plain.len() != length || crc_parts(&[&plain]) != plain_crc {
        return Err("plain length/CRC mismatch".into());
    }
    Ok((
        plain,
        Stats {
            runs,
            primary,
            alphabet: alphabet_len,
            payload: payload_len,
            plain_crc,
            payload_crc,
            tokens,
        },
    ))
}


fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 4 { return Err("usage: khc_normalized_prior_lab encode|decode input output".into()); }
    let operation = args[1].to_str().ok_or("invalid operation")?;
    let limit = match operation { "encode" => MAX_INPUT, "decode" => MAX_FRAME, _ => return Err("unknown operation".into()) };
    let input = read_bounded(Path::new(&args[2]), limit)?;
    let (output, stats) = if operation == "encode" { encode(&input)? } else { decode(&input)? };
    publish(Path::new(&args[3]), &output)?;
    println!(
        "{{\"operation\":\"{operation}\",\"input_bytes\":{},\"output_bytes\":{},\"runs\":{},\"primary\":{},\"alphabet_symbols\":{},\"payload_bytes\":{},\"plain_crc\":{},\"payload_crc\":{},\"rank_intervals\":{},\"length_intervals\":{},\"escape_bytes\":{},\"run_storage_bytes\":{}}}",
        input.len(), output.len(), stats.runs, stats.primary, stats.alphabet, stats.payload,
        stats.plain_crc, stats.payload_crc, stats.tokens.rank_intervals, stats.tokens.length_intervals,
        stats.tokens.escape_bytes, stats.runs * std::mem::size_of::<Run>()
    );
    Ok(())
}
fn main() {
    if let Err(error) = main_run() { eprintln!("rejected: {error}"); std::process::exit(1); }
}


