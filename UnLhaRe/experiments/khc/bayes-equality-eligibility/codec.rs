//! 凍結primary/BWT/grammarとD16/Q32 CTS、因果的Bayesの全frame研究codec。
//! 元実装: ../rejected-binary-mix/{codec,cts_probe,bayes_probe}.rs。
//! KHBAYQ32 / 36-byte LE header / 正準packed alphabet / 単一Q15 range payload。
//! float決定性は検証したWindows/toolchain範囲のみ。製品wireではない。

#[path = "../causal-bayes-packed/bayes_model.rs"]
mod bayes_model;
#[path = "../causal-bayes-sais/bwt.rs"]
mod bwt;
#[path = "../causal-bayes-q32/cts_model.rs"]
mod cts_model;
use bwt::bwt;
#[allow(dead_code)]
#[path = "../rejected-binary-mix/packed_alphabet.rs"]
mod packed_alphabet;
#[allow(dead_code)]
#[path = "../range.rs"]
mod range;

use std::sync::atomic::{AtomicU64, Ordering};
static TOTAL_BITS: [AtomicU64; 7] = [const { AtomicU64::new(0) }; 7];
static EQUAL_BITS: [AtomicU64; 7] = [const { AtomicU64::new(0) }; 7];

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD: usize = MAX_INPUT * 16 + 1024;
const MAX_FRAME: usize = MAX_PAYLOAD + 281;
const MAGIC: &[u8; 8] = b"KHBAYQ32";
type Result<T> = std::result::Result<T, String>;

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

#[derive(Clone, Copy)]
struct Bernoulli {
    p: i32,
    count: u16,
}
impl Bernoulli {
    fn fresh(p: i32) -> Self {
        Self { p, count: 0 }
    }
    fn update(&mut self, bit: bool) {
        let shift = match self.count {
            0..=15 => 2,
            16..=63 => 3,
            64..=255 => 4,
            256..=1023 => 5,
            _ => 6,
        };
        self.p = (self.p + (((if bit { 4096 } else { 0 }) - self.p) >> shift)).clamp(1, 4095);
        self.count = self.count.saturating_add(1);
    }
}

fn hash(mut x: u32) -> usize {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    (x ^ (x >> 16)) as usize
}

struct Model {
    global: Vec<Bernoulli>,
    symbol: Vec<Bernoulli>,
    history: Vec<Bernoulli>,
    joint: Vec<Bernoulli>,
    logit: Vec<i32>,
    sigmoid: Vec<i32>,
    weights: [i32; 4],
    calibration: [Bernoulli; 129],
    recent: u32,
    previous: [(u8, u8); 257],
}
struct Prediction {
    indexes: [usize; 4],
    stretch: [i32; 4],
    raw: i32,
    p: i32,
}
impl Model {
    fn new() -> Result<Self> {
        let mut logit = filled(4096, 0)?;
        for (p, v) in logit.iter_mut().enumerate() {
            let p = p.clamp(1, 4095) as f64 / 4096.0;
            *v = ((p / (1.0 - p)).ln() * 256.0).round() as i32;
        }
        let mut sigmoid = filled(8193, 0)?;
        for (i, v) in sigmoid.iter_mut().enumerate() {
            *v = (4096.0 / (1.0 + (-((i as f64 - 4096.0) / 256.0)).exp())).round() as i32;
        }
        Ok(Self {
            global: filled(1 << 12, Bernoulli::fresh(2048))?,
            symbol: filled(1 << 18, Bernoulli::fresh(2048))?,
            history: filled(1 << 18, Bernoulli::fresh(2048))?,
            joint: filled(1 << 18, Bernoulli::fresh(2048))?,
            logit,
            sigmoid,
            weights: [16384; 4],
            calibration: std::array::from_fn(|i| Bernoulli::fresh(i as i32 * 32)),
            recent: 0,
            previous: [(0, 0); 257],
        })
    }
    fn predict(&self, symbol: u16, node: u32) -> Prediction {
        let s = symbol as u32;
        let (pr, pl) = self.previous[symbol as usize];
        let indexes = [
            hash(node) & ((1 << 12) - 1),
            hash(node ^ s.wrapping_mul(0x9e37_79b9)) & ((1 << 18) - 1),
            hash(node ^ self.recent.rotate_left(11)) & ((1 << 18) - 1),
            hash(
                node ^ s.wrapping_mul(0x85eb_ca6b) ^ (u32::from(pr) << 24) ^ (u32::from(pl) << 16),
            ) & ((1 << 18) - 1),
        ];
        let ps = [
            self.global[indexes[0]].p,
            self.symbol[indexes[1]].p,
            self.history[indexes[2]].p,
            self.joint[indexes[3]].p,
        ];
        let stretch = ps.map(|p| self.logit[p as usize]);
        let z = stretch
            .iter()
            .zip(self.weights)
            .map(|(&s, w)| i64::from(s) * i64::from(w))
            .sum::<i64>()
            >> 16;
        let raw = self.sigmoid[(z.clamp(-4096, 4096) + 4096) as usize].clamp(1, 4095);
        let bin = (raw / 32) as usize;
        let fraction = raw % 32;
        let calibrated = (self.calibration[bin].p * (32 - fraction)
            + self.calibration[bin + 1].p * fraction
            + 16)
            / 32;
        let p = ((raw + calibrated + 1) / 2).clamp(1, 4095);
        Prediction {
            indexes,
            stretch,
            raw,
            p,
        }
    }
    fn update(&mut self, prediction: Prediction, bit: bool) {
        let target = if bit { 4096 } else { 0 };
        for (weight, stretch) in self.weights.iter_mut().zip(prediction.stretch) {
            let delta = (i64::from(target - prediction.p) * i64::from(stretch)) >> 16;
            *weight = (i64::from(*weight) + delta).clamp(0, 131072) as i32;
        }
        let i = prediction.indexes;
        self.global[i[0]].update(bit);
        self.symbol[i[1]].update(bit);
        self.history[i[2]].update(bit);
        self.joint[i[3]].update(bit);
        let bin = (prediction.raw / 32) as usize;
        self.calibration[bin].update(bit);
        self.calibration[bin + 1].update(bit);
    }
    fn run_done(&mut self, symbol: u16, rank: usize, length: usize) {
        self.history_done(symbol, rank, length);
    }
    // 凍結primaryの履歴更新。
    fn history_done(&mut self, symbol: u16, rank: usize, length: usize) {
        let r = exponent(rank.saturating_sub(1));
        let l = exponent(length - 1);
        self.previous[symbol as usize] = (r as u8, l as u8);
        // 直近4runだけを保持し、同じ履歴は同じcontextへ戻る。
        let rank_class = rank.min(3) as u32;
        let length_class = match length {
            1 => 0,
            2 => 1,
            3..=4 => 2,
            _ => 3,
        };
        self.recent = ((self.recent << 4) | rank_class | (length_class << 2)) & 0xffff;
    }
}

fn exponent(v: usize) -> usize {
    if v == 0 {
        0
    } else {
        (usize::BITS - 1 - v.leading_zeros()) as usize
    }
}
// node: class / bit position / low 8 preceding bits / current rank exponent for length。
fn node(class: u32, position: usize, prefix: u32, rank_context: usize) -> u32 {
    (class << 28) | ((rank_context as u32) << 20) | ((position as u32) << 12) | (prefix & 255)
}

enum Coder<'a> {
    Encode(range::Encoder),
    Decode(range::Decoder<'a>),
}
struct Stream<'a> {
    coder: Coder<'a>,
    model: Model,
    cts: cts_model::Model,
    bayes: bayes_model::Model,
}
impl Stream<'_> {
    fn bit(&mut self, symbol: u16, node: u32, expected: bool) -> Result<bool> {
        let p = self.model.predict(symbol, node);
        let primary_zero = ((4096 - p.p) * 8) as u16;
        let class = node >> 28;
        let cts = self.cts.predict(class)?;
        TOTAL_BITS[class as usize].fetch_add(1, Ordering::Relaxed);
        if primary_zero == cts.zero() {
            EQUAL_BITS[class as usize].fetch_add(1, Ordering::Relaxed);
        }
        let bayes = self.bayes.predict(class, primary_zero, cts.zero())?;
        let zero = bayes.zero();
        let bit = match &mut self.coder {
            Coder::Encode(e) => {
                e.bit(zero, expected)?;
                expected
            }
            Coder::Decode(d) => d.bit(zero)?,
        };
        self.bayes.update(class, &bayes, bit)?;
        self.cts.update(class, &cts, bit)?;
        self.model.update(p, bit);
        Ok(bit)
    }
    fn integer(
        &mut self,
        symbol: u16,
        value: usize,
        exp_class: u32,
        mant_class: u32,
        max_exp: usize,
        rank_context: usize,
    ) -> Result<usize> {
        let desired_exp = exponent(value);
        let mut e = 0;
        while self.bit(symbol, node(exp_class, e, 0, rank_context), e < desired_exp)? {
            e += 1;
            if e > max_exp {
                return Err("integer exponent exceeds bounds".into());
            }
        }
        let mut decoded = 1_usize;
        let mut prefix = 1;
        // encodeのdesired_expではなく、指数bit列から確定したeだけを渡す。
        for position in 0..e {
            let desired = (value >> (e - position - 1)) & 1 != 0;
            let b = self.bit(
                symbol,
                node(mant_class, position, prefix, rank_context),
                desired,
            )?;
            decoded = (decoded << 1) | usize::from(b);
            prefix = (prefix << 1) | u32::from(b);
        }
        Ok(decoded)
    }
    fn rank(&mut self, symbol: u16, desired: usize, active: usize) -> Result<usize> {
        if self.bit(symbol, node(0, 0, 0, 0), desired == 0)? {
            return Ok(0);
        }
        let rank = if self.bit(symbol, node(1, 0, 0, 0), desired == 1)? {
            1
        } else {
            self.integer(symbol, desired.saturating_sub(1), 2, 3, 8, 0)?
                .checked_add(1)
                .ok_or("rank overflow")?
        };
        if rank >= active {
            return Err("rank outside active list".into());
        }
        Ok(rank)
    }
    fn length(
        &mut self,
        symbol: u16,
        desired: usize,
        rank: usize,
        remaining: usize,
    ) -> Result<usize> {
        let context = exponent(rank.saturating_add(1));
        let length = if self.bit(symbol, node(4, 0, 0, context), desired == 1)? {
            1
        } else {
            self.integer(symbol, desired.saturating_sub(1), 5, 6, 23, context)?
                .checked_add(1)
                .ok_or("run length overflow")?
        };
        if length > remaining {
            return Err("run length exceeds declared length".into());
        }
        Ok(length)
    }
}

#[derive(Clone, Copy)]
struct Run {
    symbol: u16,
    length: usize,
    next: usize,
}

fn encode_payload(last: &[u16]) -> Result<(Vec<u8>, Vec<u16>, usize)> {
    let mut runs: Vec<Run> = Vec::new();
    runs.try_reserve_exact(last.len())
        .map_err(|_| "run allocation failed")?;
    for &s in last {
        if let Some(r) = runs.last_mut().filter(|r| r.symbol == s) {
            r.length += 1;
        } else {
            runs.push(Run {
                symbol: s,
                length: 1,
                next: usize::MAX,
            });
        }
    }
    let mut next = [usize::MAX; 257];
    for (i, run) in runs.iter_mut().enumerate().rev() {
        run.next = next[run.symbol as usize];
        next[run.symbol as usize] = i;
    }
    let mut alphabet = Vec::new();
    alphabet
        .try_reserve_exact(257)
        .map_err(|_| "alphabet allocation failed")?;
    for run in &runs {
        if !alphabet.contains(&run.symbol) {
            alphabet.push(run.symbol);
        }
    }
    let mut active = filled(alphabet.len(), 0_u16)?;
    active.copy_from_slice(&alphabet);
    let mut stream = Stream {
        coder: Coder::Encode(range::Encoder::with_limit(MAX_PAYLOAD)?),
        model: Model::new()?,
        cts: cts_model::Model::new()?,
        bayes: bayes_model::Model::new(),
    };
    for (i, run) in runs.iter().enumerate() {
        if active.first() != Some(&run.symbol) || next[run.symbol as usize] != i {
            return Err("next-use head inconsistent".into());
        }
        let symbol = active.remove(0);
        next[symbol as usize] = run.next;
        let rank = if run.next == usize::MAX {
            0
        } else {
            let index = active
                .iter()
                .position(|&s| next[s as usize] > run.next)
                .unwrap_or(active.len());
            if index == 0 {
                return Err("adjacent run symbol".into());
            }
            index
        };
        stream.rank(symbol, rank, active.len() + 1)?;
        stream.length(symbol, run.length, rank, last.len())?;
        stream.model.run_done(symbol, rank, run.length);
        if rank != 0 {
            active.insert(rank, symbol);
        }
    }
    if !active.is_empty() {
        return Err("remaining next-use symbols".into());
    }
    let Coder::Encode(e) = stream.coder else {
        unreachable!()
    };
    Ok((e.finish()?, alphabet, runs.len()))
}

fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize) -> Result<(Vec<u16>, usize)> {
    let mut active = filled(alphabet.len(), 0_u16)?;
    active.copy_from_slice(alphabet);
    let mut last = Vec::new();
    last.try_reserve_exact(n)
        .map_err(|_| "BWT allocation failed")?;
    let mut stream = Stream {
        coder: Coder::Decode(range::Decoder::<false>::new(payload)?),
        model: Model::new()?,
        cts: cts_model::Model::new()?,
        bayes: bayes_model::Model::new(),
    };
    let mut runs = 0;
    while last.len() < n {
        let symbol = *active
            .first()
            .ok_or("active list exhausted before declared length")?;
        let rank = stream.rank(symbol, 0, active.len())?;
        let length = stream.length(symbol, 1, rank, n - last.len())?;
        if last.last() == Some(&symbol) {
            return Err("non-maximal adjacent run".into());
        }
        last.resize(
            last.len().checked_add(length).ok_or("run sum overflow")?,
            symbol,
        );
        active.remove(0);
        if rank != 0 {
            active.insert(rank, symbol);
        }
        stream.model.run_done(symbol, rank, length);
        runs += 1;
    }
    if !active.is_empty() {
        return Err("active list not empty at end".into());
    }
    let Coder::Decode(d) = stream.coder else {
        unreachable!()
    };
    d.finish()?;
    Ok((last, runs))
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
}

fn encode(input: &[u8]) -> Result<(Vec<u8>, Stats)> {
    let (last, primary) = bwt(input)?;
    let (payload, alphabet, runs) = encode_payload(&last)?;
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
    let (last, runs) = decode_payload(
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
        },
    ))
}

fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 4 {
        return Err("usage: khc_bwt_causal_bayes_lab encode|decode input output".into());
    }
    let operation = args[1].to_str().ok_or("invalid operation")?;
    let limit = match operation {
        "encode" => MAX_INPUT,
        "decode" => MAX_FRAME,
        _ => return Err("unknown operation".into()),
    };
    let input = read_bounded(Path::new(&args[2]), limit)?;
    let (output, s) = if operation == "encode" {
        encode(&input)?
    } else {
        decode(&input)?
    };
    publish(Path::new(&args[3]), &output)?;
    println!(
        "{{\"operation\":\"{operation}\",\"input_bytes\":{},\"output_bytes\":{},\"runs\":{},\"primary\":{},\"alphabet_symbols\":{},\"payload_bytes\":{},\"plain_crc\":{},\"payload_crc\":{}}}",
        input.len(),
        output.len(),
        s.runs,
        s.primary,
        s.alphabet,
        s.payload,
        s.plain_crc,
        s.payload_crc
    );
    Ok(())
}

fn main() {
    if let Err(error) = main_run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
    let total: [u64; 7] = std::array::from_fn(|i| TOTAL_BITS[i].load(Ordering::Relaxed));
    let equal: [u64; 7] = std::array::from_fn(|i| EQUAL_BITS[i].load(Ordering::Relaxed));
    println!(
        "{{\"operation\":\"bayes-equality-eligibility\",\"total\":{total:?},\"equal\":{equal:?}}}"
    );
}
