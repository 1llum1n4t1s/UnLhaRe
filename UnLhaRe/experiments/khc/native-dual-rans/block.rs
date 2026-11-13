//! private診断: native Q15モデルを保ち、rank/lengthの各段を交互に復号する。
//! failure-first: 旧CRC/終端・implicit段位置・不等深度・escape順序・全history・容量を保持。
//! 新magic/revision/extent/予約/モデル/alphabet/run/sentinel/LF/CRCの失敗は成功に変換しない。
//! 因果検証: const専門化で復号の区間記録を省く。wire/model/gate不変。
#![allow(dead_code)]
pub(crate) use super::original::{HEADER, MAX_INPUT, SCRATCH_BOUND, Stats, crc32, revision_method_valid};
pub(crate) type Result<T> = std::result::Result<T, String>;
pub const MAGIC: &[u8; 8] = b"KDB1BLK\0";
#[path = "../../../src/lhc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/lhc/block/codebook.rs"]
mod codebook;
#[path = "dual.rs"]
mod dual;
#[path = "../../../src/lhc/block/frontend.rs"]
mod frontend;
#[path = "../../../src/lhc/block/grammar.rs"]
mod grammar;
#[path = "../../../src/lhc/block/histogram.rs"]
mod histogram;
#[path = "../../../src/lhc/block/model.rs"]
mod model;
#[path = "../../../src/lhc/block/multi_range.rs"]
mod multi_range;
#[path = "../../../src/lhc/block/packed.rs"]
mod packed;
#[path = "../../../src/lhc/block/packet.rs"]
mod packet;
#[path = "../../../src/lhc/block/paid_model.rs"]
mod paid_model;
#[path = "../../../src/lhc/block/program.rs"]
mod program;

pub const DECODER_RESERVE: usize = 54 << 20;
const MODEL_RESERVE: usize = 16 << 20;
const MODEL_AUX: usize = 262144;
type Interval = (u32, u32, u32);
#[derive(Default, Debug)]
pub struct TranscodeStats {
    pub events: usize,
    pub grammar_steps: usize,
    pub implicit: usize,
    pub phase_bound: usize,
    pub model_capacity: usize,
    pub journal_capacity: usize,
    pub journal_transient: usize,
}
fn crc_parts(parts: &[&[u8]]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    for part in parts {
        digest.update(part);
    }
    digest.finalize() as u32
}
fn require(valid: bool, message: &'static str) -> Result<()> {
    if valid { Ok(()) } else { Err(message.into()) }
}
fn get32(bytes: &[u8], offset: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(bytes.get(offset..offset + 4).ok_or("header truncated")?.try_into().map_err(|_| "header u32")?) as usize)
}
fn allocate<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    // packed::inverseもこの入口を使う。各reserve前に要求byte数、直後に実容量を検査する。
    let max = 4 * (MAX_INPUT + 1);
    require(n.checked_mul(std::mem::size_of::<T>()).ok_or("allocation overflow")? <= max, "allocation bound")?;
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| "allocation failed")?;
    require(
        out.capacity().checked_mul(std::mem::size_of::<T>()).ok_or("capacity overflow")? <= max,
        "allocation actual bound",
    )?;
    out.resize(n, value);
    Ok(out)
}
fn gate(s: &mut Stats, bound: usize) -> Result<()> {
    require(bound <= DECODER_RESERVE, "dual whole phase reservation")?;
    s.phase_capacity_bound = s.phase_capacity_bound.max(bound);
    s.scratch_capacity_bound = SCRATCH_BOUND;
    Ok(())
}
struct Header {
    raw: usize,
    primary: usize,
    alphabet: usize,
    model: usize,
    payload: usize,
    data: usize,
}
fn header(bytes: &[u8], legacy: bool) -> Result<Header> {
    require(bytes.len() >= HEADER, "header truncated")?;
    let magic = if legacy { super::original::MAGIC } else { MAGIC };
    require(&bytes[..8] == magic, "frame magic")?;
    let revision = u16::from_le_bytes([bytes[8], bytes[9]]);
    require(
        if legacy {
            matches!(revision, 1 | 2) && revision_method_valid(bytes)
        } else {
            revision == 1
        },
        "frame revision/method",
    )?;
    require(bytes[10] == 1 && bytes[11] == 0 && bytes[30..32] == [0, 0], "frame method/flags/reserved")?;
    let h = Header {
        raw: get32(bytes, 12)?,
        primary: get32(bytes, 16)?,
        model: get32(bytes, 20)?,
        payload: get32(bytes, 24)?,
        alphabet: u16::from_le_bytes([bytes[28], bytes[29]]) as usize,
        data: 0,
    };
    require(h.raw <= MAX_INPUT, "raw exceeds block limit")?;
    let data = HEADER
        .checked_add(h.alphabet.checked_mul(2).ok_or("frame length overflow")?)
        .and_then(|n| n.checked_add(h.model))
        .ok_or("frame length overflow")?;
    require(data.checked_add(h.payload).ok_or("frame length overflow")? == bytes.len(), "frame exact extent")?;
    require(
        bytes.len() - HEADER < h.raw
            && h.primary <= h.raw
            && (2..=257).contains(&h.alphabet)
            && (241..=packet::MAX_BUNDLE_BYTES).contains(&h.model)
            && h.payload >= if legacy { 5 } else { 8 },
        "frame canonical fields",
    )?;
    require(crc_parts(&[&bytes[..36], &bytes[HEADER..]]) == get32(bytes, 36)? as u32, "wire CRC")?;
    Ok(Header { data, ..h })
}
enum Stream<'a> {
    Legacy(multi_range::Decoder<'a>),
    Dual(dual::Decoder<'a>),
}
impl Stream<'_> {
    fn slot(&self, lane: usize, total: u32) -> Result<u32> {
        match self {
            Self::Legacy(d) => d.slot(total).map_err(str::to_owned),
            Self::Dual(d) => d.slot(lane, total).map_err(str::to_owned),
        }
    }
    fn consume(&mut self, lane: usize, c: u32, f: u32, total: u32) -> Result<()> {
        match self {
            Self::Legacy(d) => d.consume(c, f, total).map_err(str::to_owned),
            Self::Dual(d) => d.consume(lane, c, f, total).map_err(str::to_owned),
        }
    }
    fn finish(&self) -> Result<()> {
        match self {
            Self::Legacy(d) => d.finish().map_err(str::to_owned),
            Self::Dual(d) => d.finish().map_err(str::to_owned),
        }
    }
}
#[derive(Default)]
struct Token {
    node: usize,
    done: Option<usize>,
    steps: usize,
    intervals: [Option<Interval>; 8],
}
fn one_step<const L: bool>(t: &mut Token, c: usize, limit: usize, d: &mut Stream<'_>, forest: &packet::DecodeForest, histories: &mut [u16; 6], s: &mut Stats) -> Result<()> {
    if t.done.is_some() {
        return Ok(());
    }
    require(t.steps < 8, "token depth bound")?;
    let (instruction, k) = program::Program::new().node(c, t.node, limit)?;
    let class = c * 3 + instruction.class as usize;
    let child = if k == 1 {
        s.implicit += 1;
        0
    } else {
        let cdf = forest.cdf(c, t.node, k, histories[class])?;
        let (child, cumulative, frequency) = cdf.choose(d.slot(c, 32768)?)?;
        d.consume(c, cumulative, frequency, 32768)?;
        if L { t.intervals[t.steps] = Some((cumulative, frequency, 32768)); }
        child
    };
    histories[class] = ((histories[class] << 2) | child as u16) & 1023;
    s.branches += 1;
    t.steps += 1;
    let (lo, next) = instruction.step(child)?;
    if let Some(next) = next {
        t.node = next;
    } else {
        require(lo < limit, "decoded token limit")?;
        t.done = Some(lo);
    }
    Ok(())
}
fn append(e: &mut dual::Encoder, lane: usize, interval: Interval) -> Result<()> {
    e.interval(lane, interval.0, interval.1, interval.2).map_err(str::to_owned)
}
fn escape(d: &mut Stream<'_>, remaining: usize, s: &mut Stats, journal: &mut Option<dual::Encoder>) -> Result<usize> {
    let mut value = 0usize;
    for i in 0..3 {
        let b = d.slot(1, 256)? as u8;
        d.consume(1, u32::from(b), 1, 256)?;
        if let Some(e) = journal {
            append(e, 1, (u32::from(b), 1, 256))?;
        }
        s.escapes += 1;
        let part = usize::from(b & 127);
        value = value
            .checked_add(part.checked_shl((7 * i) as u32).ok_or("escape overflow")?)
            .ok_or("escape overflow")?;
        if b & 128 == 0 {
            require(i == 0 || part != 0, "noncanonical escape")?;
            let length = value.checked_add(256).ok_or("escape overflow")?;
            require(length <= remaining, "escape remaining")?;
            return Ok(length);
        }
    }
    Err("escape length overflow".into())
}
fn engine<const L: bool>(bytes: &[u8]) -> Result<(Vec<u8>, Stats, Option<dual::Encoder>)> {
    let h = header(bytes, L)?;
    let mut s = Stats {
        method: 1,
        raw: h.raw,
        frame: bytes.len(),
        alphabet: h.alphabet * 2,
        metadata: h.model,
        payload: h.payload,
        ..Stats::default()
    };
    // callerがconstruction前に54MiBを予約する契約。parseの固定ROWS/成長重複を含め16MiBを先払いする。
    gate(&mut s, DECODER_RESERVE)?;
    let mut alphabet = [0u16; 257];
    let mut active = [0u16; 257];
    let mut seen = [false; 257];
    for i in 0..h.alphabet {
        let off = HEADER + i * 2;
        let v = u16::from_le_bytes([bytes[off], bytes[off + 1]]);
        require(v <= 256 && !seen[v as usize], "alphabet range/duplicate")?;
        seen[v as usize] = true;
        alphabet[i] = v;
        active[i] = v;
    }
    require(seen[0], "alphabet sentinel absent")?;
    let construction = 3 * bytes.len()
        + MODEL_RESERVE
        + dual::MAX_LIVE_BYTES
        + (h.raw + 1) * 7
        + program::RETAINED_BOUND
        + program::TRANSIENT_BOUND
        + SCRATCH_BOUND
        + MODEL_AUX;
    gate(&mut s, construction)?;
    let forest = packet::Forest::parse(&bytes[HEADER + h.alphabet * 2..h.data])?.into_decode()?;
    let model_peak = forest
        .capacity_bytes()
        .checked_add(forest.parse_transient())
        .and_then(|n| n.checked_add(MODEL_AUX))
        .ok_or("model phase overflow")?;
    require(model_peak <= MODEL_RESERVE, "model phase reservation")?;
    s.forest_capacity = forest.capacity_bytes() + program::Program::new().capacity_bytes();
    s.parse_transient = forest.parse_transient() + MODEL_AUX + program::TRANSIENT_BOUND;
    let mut d = if L {
        Stream::Legacy(multi_range::Decoder::new(&bytes[h.data..]).map_err(str::to_owned)?)
    } else {
        Stream::Dual(dual::Decoder::new(&bytes[h.data..]).map_err(str::to_owned)?)
    };
    let mut journal = if L {
        Some(dual::Encoder::with_limit(MAX_INPUT).map_err(str::to_owned)?)
    } else {
        None
    };
    let mut histories = [0u16; 6];
    let mut remaining = h.raw + 1;
    let mut active_len = h.alphabet;
    let mut last = allocate(remaining, 0u16)?;
    let mut written = 0;
    let mut encountered = [false; 257];
    let mut encounter_count = 0;
    while remaining != 0 {
        require(active_len != 0 && s.runs <= h.raw, "active/runs terminal")?;
        let symbol = active[0];
        if !encountered[symbol as usize] {
            require(
                encounter_count < h.alphabet && alphabet[encounter_count] == symbol,
                "alphabet first occurrence order",
            )?;
            encountered[symbol as usize] = true;
            encounter_count += 1;
        }
        let limits = [active_len, remaining.min(256)];
        let mut tokens = [Token::default(), Token::default()];
        if L {
            for c in 0..2 {
                while tokens[c].done.is_none() {
                    one_step::<L>(&mut tokens[c], c, limits[c], &mut d, &forest, &mut histories, &mut s)?;
                }
            }
            // Noneはimplicit段を占める。非implicit eventの番号で交互化してはいけない。
            if let Some(e) = &mut journal {
                for i in 0..tokens[0].steps.max(tokens[1].steps) {
                    for c in 0..2 {
                        if let Some(interval) = tokens[c].intervals[i] {
                            append(e, c, interval)?;
                        }
                    }
                }
            }
        } else {
            while tokens[0].done.is_none() || tokens[1].done.is_none() {
                for c in 0..2 {
                    one_step::<L>(&mut tokens[c], c, limits[c], &mut d, &forest, &mut histories, &mut s)?;
                }
            }
        }
        let rank = tokens[0].done.ok_or("rank terminal")?;
        let length_token = tokens[1].done.ok_or("length terminal")?;
        let length = if length_token == 255 {
            escape(&mut d, remaining, &mut s, &mut journal)?
        } else {
            length_token + 1
        };
        require(length <= remaining && (symbol != 0 || length == 1), "run/sentinel length")?;
        last[written..written + length].fill(symbol);
        written += length;
        remaining -= length;
        s.runs += 1;
        active.copy_within(1..active_len, 0);
        active_len -= 1;
        if rank != 0 {
            require(rank <= active_len, "active insertion rank")?;
            active.copy_within(rank..active_len, rank + 1);
            active[rank] = symbol;
            active_len += 1;
        }
    }
    require(active_len == 0 && encounter_count == h.alphabet, "active/alphabet terminal")?;
    d.finish()?;
    let journal_peak = journal.as_ref().map_or(0, |e| e.capacity_bytes() + e.allocation_transient());
    require(journal_peak <= dual::MAX_LIVE_BYTES, "journal phase reservation")?;
    s.range_capacity_bound = journal_peak;
    drop(forest);
    // inverse allocationの前に、rawと確定したjournalの次phaseを先払いする。
    gate(
        &mut s,
        bytes.len() + last.capacity() * 2 + journal_peak + (h.raw + 1) * 5 + SCRATCH_BOUND + MODEL_AUX,
    )?;
    let inverse = packed::inverse(&last, h.primary, &alphabet[..h.alphabet])?;
    require(inverse.route == "packed23" && inverse.plain.len() == h.raw, "inverse route/length")?;
    s.inverse_capacity = inverse.scratch_capacity_words * 4;
    s.output_capacity = inverse.result_capacity;
    let bound = bytes.len() + last.capacity() * 2 + journal_peak + s.inverse_capacity + s.output_capacity + SCRATCH_BOUND + MODEL_AUX;
    gate(&mut s, bound)?;
    require(crc32(&inverse.plain) == get32(bytes, 32)? as u32, "plain CRC")?;
    Ok((inverse.plain, s, journal))
}
pub fn decode(bytes: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if bytes.get(..8) == Some(super::original::MAGIC.as_slice()) {
        return super::original::decode(bytes);
    }
    let (plain, stats, _) = engine::<false>(bytes)?;
    Ok((plain, stats))
}
pub fn transcode(frame: &[u8]) -> Result<(Vec<u8>, TranscodeStats)> {
    let (plain, source, journal) = engine::<true>(frame)?;
    let h = header(frame, true)?;
    let e = journal.ok_or("legacy journal absent")?;
    let stats = TranscodeStats {
        events: e.event_count(),
        grammar_steps: source.branches,
        implicit: source.implicit,
        phase_bound: source.phase_capacity_bound,
        model_capacity: source.forest_capacity,
        journal_capacity: e.capacity_bytes(),
        journal_transient: e.allocation_transient(),
    };
    drop(plain);
    let payload = e.finish().map_err(str::to_owned)?;
    let body = h.data - HEADER + payload.len();
    require(body < h.raw, "unprofitable dual body")?;
    require(payload.len() >= 8 && payload.capacity() <= MAX_INPUT, "dual payload capacity/extent")?;
    let mut out = allocate(HEADER + body, 0u8)?;
    require(
        out.capacity() + frame.len() + payload.capacity() + SCRATCH_BOUND <= DECODER_RESERVE,
        "frame phase reservation",
    )?;
    out[..h.data].copy_from_slice(&frame[..h.data]);
    out[..8].copy_from_slice(MAGIC);
    out[8..10].copy_from_slice(&1u16.to_le_bytes());
    out[24..28].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    out[h.data..].copy_from_slice(&payload);
    let wire = crc_parts(&[&out[..36], &out[HEADER..]]);
    out[36..40].copy_from_slice(&wire.to_le_bytes());
    Ok((out, stats))
}
pub fn finite_backend() -> Result<(usize, usize, usize)> {
    dual::finite().map_err(str::to_owned)
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Witness {
    c: usize,
    node: usize,
    class: usize,
    k: usize,
    history: u16,
    child: usize,
    terminal: bool,
    interval: Option<Interval>,
}
fn witness(c: usize, node: usize, class: usize, k: usize, history: u16, child: usize, terminal: bool) -> Witness {
    // 独立grammar証人のtinyな固定Q15区間。implicitを必ずNoneとして段に残す。
    let interval = (k > 1).then(|| {
        let lo = child as u32 * 32768 / k as u32;
        let hi = (child + 1) as u32 * 32768 / k as u32;
        (lo, hi - lo, 32768)
    });
    Witness {
        c,
        node,
        class,
        k,
        history,
        child,
        terminal,
        interval,
    }
}
fn tree_trace(tree: &grammar::Tree, c: usize, token: usize, limit: usize, histories: &mut [u16; 6]) -> Result<Vec<Witness>> {
    let mut out = Vec::with_capacity(8);
    let mut node = 0;
    loop {
        if out.len() == 8 {
            return Err("finite Tree depth".into());
        }
        let k = tree.prefix(node, limit)?;
        let class = c * 3 + tree.class(node)?;
        let child = tree.known_child(node, token, limit)?;
        let edge = tree.edge(node, child, k)?;
        out.push(witness(c, node, class, k, histories[class], child, edge.node.is_none()));
        histories[class] = ((histories[class] << 2) | child as u16) & 1023;
        if let Some(next) = edge.node {
            node = next;
        } else {
            if edge.lo != token {
                return Err("finite Tree terminal".into());
            }
            return Ok(out);
        }
    }
}
fn program_witness(c: usize, node: &mut usize, token: usize, limit: usize, histories: &mut [u16; 6]) -> Result<Witness> {
    let (instruction, k) = program::Program::new().node(c, *node, limit)?;
    let mut child = 0;
    for i in 0..k {
        if instruction.step(i)?.0 <= token {
            child = i;
        }
    }
    let (lo, next) = instruction.step(child)?;
    let class = c * 3 + instruction.class as usize;
    let w = witness(c, *node, class, k, histories[class], child, next.is_none());
    histories[class] = ((histories[class] << 2) | child as u16) & 1023;
    if let Some(next) = next {
        *node = next;
    } else if lo != token {
        return Err("finite Program terminal".into());
    }
    Ok(w)
}
pub fn finite_schedule() -> Result<usize> {
    let trees = [grammar::Tree::new(257), grammar::Tree::new(256)];
    let mut cases = 0;
    // 全prefix/tokenについて独立Treeと固定Programの経路/全historyを比較する。
    for c in 0..2 {
        for limit in 1..=if c == 0 { 257 } else { 256 } {
            for token in 0..limit {
                let mut a = [1, 3, 1023, 7, 511, 1022];
                let mut b = a;
                let expected = tree_trace(&trees[c], c, token, limit, &mut a)?;
                let mut node = 0;
                let mut actual = Vec::with_capacity(8);
                loop {
                    if actual.len() == 8 {
                        return Err("finite Program depth".into());
                    }
                    let w = program_witness(c, &mut node, token, limit, &mut b)?;
                    let done = w.terminal;
                    actual.push(w);
                    if done {
                        break;
                    }
                }
                if expected != actual || a != b {
                    return Err("finite Tree/Program mismatch".into());
                }
                cases += 1;
            }
        }
    }
    let ranks = [(0, 1), (1, 2), (3, 4), (4, 5), (31, 32), (32, 33), (255, 256), (256, 257)];
    let lengths = [(0, 1), (1, 2), (3, 4), (4, 5), (31, 32), (32, 33), (127, 128), (255, 256)];
    let mut serial_history = [1023, 3, 511, 7, 1022, 255];
    let mut paired_history = serial_history;
    let mut implicit = false;
    let mut unequal = false;
    for &(rt, rl) in &ranks {
        for &(lt, ll) in &lengths {
            let tokens = [rt, lt];
            let limits = [rl, ll];
            let paths = [
                tree_trace(&trees[0], 0, rt, rl, &mut serial_history)?,
                tree_trace(&trees[1], 1, lt, ll, &mut serial_history)?,
            ];
            unequal |= paths[0].len() != paths[1].len();
            let mut expected = Vec::with_capacity(16);
            for i in 0..paths[0].len().max(paths[1].len()) {
                for path in &paths {
                    if let Some(w) = path.get(i) {
                        implicit |= w.interval.is_none();
                        expected.push(w.clone());
                    }
                }
            }
            let mut actual = Vec::with_capacity(16);
            let mut nodes = [0, 0];
            let mut done = [false; 2];
            while !done[0] || !done[1] {
                for c in 0..2 {
                    if !done[c] {
                        if actual.len() == 16 {
                            return Err("finite paired depth".into());
                        }
                        let w = program_witness(c, &mut nodes[c], tokens[c], limits[c], &mut paired_history)?;
                        done[c] = w.terminal;
                        actual.push(w);
                    }
                }
            }
            if expected != actual || serial_history != paired_history {
                return Err("finite paired schedule/history mismatch".into());
            }
            cases += 1;
        }
    }
    if !implicit || !unequal {
        return Err("finite missing implicit/unequal witness".into());
    }
    Ok(cases)
}
