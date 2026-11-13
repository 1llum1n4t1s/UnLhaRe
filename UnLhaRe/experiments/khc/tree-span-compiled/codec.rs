//! private KHT1: 固定MDL treeの意味tokenを局所整数区間へ投影する。
#![allow(dead_code)]
#[path = "../../../src/lhc/block/bundle.rs"]
mod bundle;
#[path = "../../../src/lhc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/lhc/block/codebook.rs"]
mod codebook;
#[path = "../../../src/lhc/block/counts.rs"]
mod counts;
#[path = "../flat-token-ans/entropy.rs"]
mod entropy;
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
mod program;
mod token;
pub type Result<T> = std::result::Result<T, String>;
pub const MAX_INPUT: usize = 1 << 20;
pub const RAM_LIMIT: usize = 64 << 20;
pub const MAGIC: &[u8; 8] = b"KHT1BLK\0";
const MODEL_RESERVE: usize = 16 << 20;
#[derive(Default, Clone, Debug)]
pub struct Stats {
    pub raw: usize,
    pub frame: usize,
    pub metadata: usize,
    pub events: usize,
    pub branches: usize,
    pub implicit: usize,
    pub runs: usize,
    pub escapes: usize,
    pub forest_capacity: usize,
    pub journal_capacity: usize,
    pub journal_transient: usize,
    pub library_capacity_bound: usize,
    pub caller_slice_fee: usize,
    pub peak_capacity_bound: usize,
}
fn gate(s: &mut Stats, library: usize) -> Result<()> {
    s.library_capacity_bound = s.library_capacity_bound.max(library);
    let full = library
        .checked_add(s.caller_slice_fee)
        .ok_or("capacity overflow")?;
    s.peak_capacity_bound = s.peak_capacity_bound.max(full);
    if full > RAM_LIMIT {
        return Err("codec RAM bound".into());
    }
    Ok(())
}
fn allocate<T: Clone>(n: usize, v: T) -> Result<Vec<T>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| "allocation failed")?;
    if out.capacity() != n {
        return Err("actual allocation capacity".into());
    }
    out.resize(n, v);
    Ok(out)
}
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("header extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn crc(b: &[u8]) -> u32 {
    crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, b) as u32
}
fn wire_crc(b: &[u8]) -> u32 {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[..36]);
    d.update(&b[40..]);
    d.finalize() as u32
}
#[derive(Clone, Copy)]
struct Header {
    method: u8,
    raw: usize,
    primary: usize,
    model: usize,
    payload: usize,
    alphabet: usize,
}
fn header(b: &[u8], legacy: bool) -> Result<Header> {
    if b.len() < 40 {
        return Err("header truncated".into());
    }
    let revision = u16::from_le_bytes([b[8], b[9]]);
    if &b[..8] != if legacy { b"KHC1BLK\0" } else { MAGIC }
        || (if legacy {
            !matches!(revision, 1 | 2)
        } else {
            revision != 1
        })
    {
        return Err("magic/revision".into());
    }
    let h = Header {
        method: b[10],
        raw: num(b, 12)?,
        primary: num(b, 16)?,
        model: num(b, 20)?,
        payload: num(b, 24)?,
        alphabet: u16::from_le_bytes([b[28], b[29]]) as usize,
    };
    if h.method > 1 || b[11] != 0 || b[30..32] != [0, 0] || h.raw > MAX_INPUT {
        return Err("method/flags/raw bound".into());
    }
    let body = h
        .alphabet
        .checked_mul(2)
        .and_then(|n| n.checked_add(h.model))
        .and_then(|n| n.checked_add(h.payload))
        .ok_or("body overflow")?;
    if 40usize.checked_add(body) != Some(b.len()) {
        return Err("exact frame extent".into());
    }
    if h.method == 0 {
        if h.primary != 0 || h.model != 0 || h.alphabet != 0 || h.payload != h.raw {
            return Err("stored canonical fields".into());
        }
    } else if body >= h.raw
        || h.primary > h.raw
        || !(2..=257).contains(&h.alphabet)
        || !(241..=packet::MAX_BUNDLE_BYTES).contains(&h.model)
        || h.payload < 5
    {
        return Err("MDL canonical fields".into());
    }
    if wire_crc(b) != num(b, 36)? as u32 {
        return Err("wire CRC".into());
    }
    Ok(h)
}
fn alphabet(b: &[u8], h: Header) -> Result<[u16; 257]> {
    let mut a = [0u16; 257];
    let mut seen = [false; 257];
    for (i, v) in a.iter_mut().take(h.alphabet).enumerate() {
        let at = 40 + i * 2;
        *v = u16::from_le_bytes(b[at..at + 2].try_into().map_err(|_| "alphabet")?);
        if *v > 256 || seen[*v as usize] {
            return Err("alphabet range/duplicate".into());
        }
        seen[*v as usize] = true;
    }
    if !seen[0] {
        return Err("alphabet sentinel absent".into());
    }
    Ok(a)
}
trait Source {
    fn token(&mut self, c: usize, limit: usize, hist: &mut [u16; 6]) -> Result<token::Token>;
    fn byte(&mut self) -> Result<u8>;
    fn finish(&self) -> Result<()>;
}
struct Legacy<'a> {
    decoder: multi_range::Decoder<'a>,
    forest: &'a packet::Forest,
    program: &'static program::Program,
    flat_hist: [u16; 6],
    encoder: Option<entropy::Encoder>,
    capacity: usize,
    transient: usize,
    events: usize,
}
impl Legacy<'_> {
    fn event(&mut self, c: u32, f: u32, total: u32) -> Result<()> {
        if let Some(e) = &mut self.encoder {
            match e.interval(c, f, total) {
                Ok(()) => {
                    self.capacity = self.capacity.max(e.capacity_bytes());
                    self.transient = self.transient.max(e.transient_bytes());
                    self.events = e.event_count();
                }
                Err("ANS journal limit") => self.encoder = None,
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }
}
impl Source for Legacy<'_> {
    fn token(&mut self, c: usize, limit: usize, hist: &mut [u16; 6]) -> Result<token::Token> {
        let mut n = 0;
        let mut depth = 0;
        let symbol = loop {
            depth += 1;
            if depth > 8 {
                return Err("legacy tree depth".into());
            }
            let (ins, k) = self.program.node(c, n, limit)?;
            let class = c * 3 + ins.class as usize;
            let child = if k == 1 {
                0
            } else {
                let freq = self.forest.lookup(c, n, k, hist[class])?;
                let slot = self.decoder.slot(32768).map_err(str::to_owned)?;
                let mut cumulative = 0u32;
                let mut found = None;
                for (j, &f) in freq.iter().take(k).enumerate() {
                    let f = u32::from(f);
                    if slot < cumulative + f {
                        self.decoder
                            .consume(cumulative, f, 32768)
                            .map_err(str::to_owned)?;
                        found = Some(j);
                        break;
                    }
                    cumulative += f;
                }
                found.ok_or("legacy CDF child")?
            };
            hist[class] = ((hist[class] << 2) | child as u16) & 1023;
            let (lo, next) = ins.step(child)?;
            match next {
                Some(next) => n = next,
                None => break lo,
            }
        };
        let t = token::encode(
            self.forest,
            self.program,
            c,
            limit,
            symbol,
            &mut self.flat_hist,
        )?;
        if *hist != self.flat_hist {
            return Err("legacy/joint all histories differ".into());
        }
        self.event(t.cumulative, t.frequency, token::TOTAL)?;
        Ok(t)
    }
    fn byte(&mut self) -> Result<u8> {
        let b = self.decoder.slot(256).map_err(str::to_owned)?;
        self.decoder.consume(b, 1, 256).map_err(str::to_owned)?;
        self.event(b, 1, 256)?;
        Ok(b as u8)
    }
    fn finish(&self) -> Result<()> {
        self.decoder.finish().map_err(str::to_owned)
    }
}
struct Flat<'a> {
    decoder: entropy::Decoder<'a>,
    forest: &'a packet::Forest,
    program: &'static program::Program,
}
impl Source for Flat<'_> {
    fn token(&mut self, c: usize, limit: usize, hist: &mut [u16; 6]) -> Result<token::Token> {
        let slot = self.decoder.slot(token::TOTAL).map_err(str::to_owned)?;
        let t = token::decode(self.forest, self.program, c, limit, hist, slot)?;
        self.decoder
            .consume(t.cumulative, t.frequency, token::TOTAL)
            .map_err(str::to_owned)?;
        Ok(t)
    }
    fn byte(&mut self) -> Result<u8> {
        let b = self.decoder.slot(256).map_err(str::to_owned)?;
        self.decoder.consume(b, 1, 256).map_err(str::to_owned)?;
        Ok(b as u8)
    }
    fn finish(&self) -> Result<()> {
        self.decoder.finish().map_err(str::to_owned)
    }
}
fn escape(src: &mut impl Source, remaining: usize, s: &mut Stats) -> Result<usize> {
    let mut value = 0usize;
    for i in 0..3 {
        let b = src.byte()?;
        s.escapes += 1;
        let part = usize::from(b & 127);
        value |= part << (i * 7);
        if b & 128 == 0 {
            if i != 0 && part == 0 {
                return Err("noncanonical escape".into());
            }
            let length = value.checked_add(256).ok_or("escape overflow")?;
            if length > remaining {
                return Err("escape remaining".into());
            }
            return Ok(length);
        }
    }
    Err("escape length overflow".into())
}
fn reconstruct(
    src: &mut impl Source,
    h: Header,
    a: &[u16; 257],
    s: &mut Stats,
) -> Result<Vec<u16>> {
    let mut active = *a;
    let mut active_len = h.alphabet;
    let mut histories = [0u16; 6];
    let mut remaining = h.raw + 1;
    let mut last = allocate(remaining, 0u16)?;
    let mut written = 0;
    let mut encountered = [false; 257];
    let mut count = 0;
    while remaining != 0 {
        if active_len == 0 || s.runs > h.raw {
            return Err("active/runs terminal".into());
        }
        let symbol = active[0];
        if !encountered[symbol as usize] {
            if a[count] != symbol {
                return Err("alphabet first occurrence order".into());
            }
            encountered[symbol as usize] = true;
            count += 1;
        }
        let rank = src.token(0, active_len, &mut histories)?;
        let length = src.token(1, remaining.min(256), &mut histories)?;
        s.branches += rank.branches + length.branches;
        s.implicit += rank.implicit + length.implicit;
        let length = if length.symbol == 255 {
            escape(src, remaining, s)?
        } else {
            length.symbol + 1
        };
        if length > remaining || (symbol == 0 && length != 1) {
            return Err("run/sentinel length".into());
        }
        last[written..written + length].fill(symbol);
        written += length;
        remaining -= length;
        s.runs += 1;
        active.copy_within(1..active_len, 0);
        active_len -= 1;
        if rank.symbol != 0 {
            if rank.symbol > active_len {
                return Err("active insertion rank".into());
            }
            active.copy_within(rank.symbol..active_len, rank.symbol + 1);
            active[rank.symbol] = symbol;
            active_len += 1;
        }
    }
    if active_len != 0 || count != h.alphabet {
        return Err("active/alphabet terminal".into());
    }
    src.finish()?;
    Ok(last)
}
fn inverse(last: &[u16], h: Header, a: &[u16; 257]) -> Result<Vec<u8>> {
    let result = packed::inverse(last, h.primary, &a[..h.alphabet])?;
    if result.route != "packed23" || result.plain.len() != h.raw {
        return Err("inverse route/length".into());
    }
    Ok(result.plain)
}
pub fn encode_from_legacy(raw: &[u8], legacy: &[u8]) -> Result<Option<(Vec<u8>, Stats)>> {
    if raw.len() > MAX_INPUT {
        return Err("raw bound".into());
    }
    // この変換APIの入力は旧KHC1 blockのみ。別のpublic形式の暗黙受理を
    // 避け、nativeへ渡す前に入力extentとcaller分を含む予約を検査する。
    if legacy.len() < 40
        || legacy.len() > MAX_INPUT + 40
        || &legacy[..8] != b"KHC1BLK\0"
        || !matches!(u16::from_le_bytes([legacy[8], legacy[9]]), 1 | 2)
        || legacy[10] > 3
        || num(legacy, 12)? != raw.len()
    {
        return Err("legacy conversion input domain".into());
    }
    if legacy.get(10).copied() != Some(1) {
        let mut s = Stats {
            caller_slice_fee: raw.len() + legacy.len(),
            ..Stats::default()
        };
        gate(&mut s, 12 * MAX_INPUT)?;
        if unlhare::lhc::decompress_block(legacy).map_err(|e| e.to_string())? != raw {
            return Err("non-MDL legacy raw mismatch".into());
        }
        return Ok(None);
    }
    let h = header(legacy, true)?;
    if h.raw != raw.len() || crc(raw) != num(legacy, 32)? as u32 {
        return Err("legacy caller raw length/CRC".into());
    }
    let prefix_len = h.alphabet * 2 + h.model;
    let limit = h.raw - prefix_len - 1;
    let mut s = Stats {
        raw: h.raw,
        metadata: h.model,
        caller_slice_fee: raw.len() + legacy.len(),
        ..Stats::default()
    };
    // 全forest/parse16MiB、journal24MiB、last2N/inverse4N/rawN/payloadN/frameNを先に課金。
    let reserve = MODEL_RESERVE + entropy::MAX_LIVE_BYTES + 9 * (h.raw + 1) + 131072 + 40;
    gate(&mut s, reserve)?;
    let a = alphabet(legacy, h)?;
    let at = 40 + h.alphabet * 2;
    let forest = packet::Forest::parse(&legacy[at..at + h.model])?;
    s.forest_capacity = forest.capacity_bytes();
    let mut src = Legacy {
        decoder: multi_range::Decoder::new(&legacy[at + h.model..]).map_err(str::to_owned)?,
        forest: &forest,
        program: program::Program::new(),
        flat_hist: [0; 6],
        encoder: Some(entropy::Encoder::with_limit(limit).map_err(str::to_owned)?),
        capacity: 0,
        transient: 0,
        events: 0,
    };
    let last = reconstruct(&mut src, h, &a, &mut s)?;
    s.events = src.events;
    s.journal_capacity = src.capacity;
    s.journal_transient = src.transient;
    let encoder = src.encoder.take();
    drop(src);
    drop(forest);
    let plain = inverse(&last, h, &a)?;
    if plain != raw || crc(&plain) != num(legacy, 32)? as u32 {
        return Err("legacy reconstructed raw mismatch".into());
    }
    drop(plain);
    drop(last);
    let Some(encoder) = encoder else {
        return Ok(None);
    };
    let payload = match encoder.finish() {
        Ok(p) => p,
        Err("range output limit") => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    if prefix_len + payload.len() >= h.raw {
        return Ok(None);
    }
    let mut frame = allocate(40 + prefix_len + payload.len(), 0u8)?;
    frame[..40].copy_from_slice(&legacy[..40]);
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[24..28].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[40..40 + prefix_len].copy_from_slice(&legacy[40..40 + prefix_len]);
    frame[40 + prefix_len..].copy_from_slice(&payload);
    let wire = wire_crc(&frame);
    frame[36..40].copy_from_slice(&wire.to_le_bytes());
    s.frame = frame.len();
    if payload.capacity() > limit || frame.capacity() != frame.len() {
        return Err("payload/frame capacity".into());
    }
    Ok(Some((frame, s)))
}
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    let h = header(frame, false)?;
    let mut s = Stats {
        raw: h.raw,
        frame: frame.len(),
        metadata: h.model,
        caller_slice_fee: frame.len(),
        ..Stats::default()
    };
    if h.method == 0 {
        gate(&mut s, h.raw)?;
        let mut out = allocate(h.raw, 0u8)?;
        out.copy_from_slice(&frame[40..]);
        if crc(&out) != num(frame, 32)? as u32 {
            return Err("raw CRC".into());
        }
        return Ok((out, s));
    }
    gate(&mut s, MODEL_RESERVE + 7 * (h.raw + 1) + 131072)?;
    let a = alphabet(frame, h)?;
    let at = 40 + h.alphabet * 2;
    let forest = packet::Forest::parse(&frame[at..at + h.model])?;
    s.forest_capacity = forest.capacity_bytes();
    let mut src = Flat {
        decoder: entropy::Decoder::new(&frame[at + h.model..]).map_err(str::to_owned)?,
        forest: &forest,
        program: program::Program::new(),
    };
    let last = reconstruct(&mut src, h, &a, &mut s)?;
    drop(src);
    drop(forest);
    let out = inverse(&last, h, &a)?;
    if crc(&out) != num(frame, 32)? as u32 {
        return Err("raw CRC".into());
    }
    Ok((out, s))
}
pub fn stored(raw: &[u8]) -> Result<Vec<u8>> {
    if raw.len() > MAX_INPUT {
        return Err("raw bound".into());
    }
    let mut out = allocate(40 + raw.len(), 0u8)?;
    out[..8].copy_from_slice(MAGIC);
    out[8..10].copy_from_slice(&1u16.to_le_bytes());
    out[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    out[24..28].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    out[32..36].copy_from_slice(&crc(raw).to_le_bytes());
    out[40..].copy_from_slice(raw);
    let wire = wire_crc(&out);
    out[36..40].copy_from_slice(&wire.to_le_bytes());
    Ok(out)
}
pub fn finite_backend_contract() -> Result<usize> {
    entropy::finite_contract().map_err(str::to_owned)
}
pub fn finite_partition_legacy(legacy: &[u8], histories: &[[u16; 6]]) -> Result<usize> {
    let h = header(legacy, true)?;
    if h.method != 1 {
        return Err("partition MDL required".into());
    }
    let at = 40 + h.alphabet * 2;
    let forest = packet::Forest::parse(&legacy[at..at + h.model])?;
    let mut checks = 0;
    for &hist in histories {
        for c in 0..2 {
            for limit in 1..=if c == 0 { 257 } else { 256 } {
                checks +=
                    token::finite_partition(&forest, program::Program::new(), c, limit, hist)?;
            }
        }
    }
    Ok(checks)
}
