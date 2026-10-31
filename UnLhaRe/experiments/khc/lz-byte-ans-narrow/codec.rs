//! private候補。旧LZの意味tokenをbyte CDF/rANSへ移し、探索器は触らない。
#[path = "../mdl-rans/entropy.rs"]
mod ans;
#[path = "../../../src/khc/block/multi_range.rs"]
mod legacy_range;

pub type Result<T> = std::result::Result<T, String>;
pub const MAX_RAW: usize = 1 << 20;
pub const RAM_LIMIT: usize = 64 << 20;
const HEADER: usize = 40;
const MAGIC: &[u8; 8] = b"KAB1BLK\0";
const BIT_COUNT: usize = 2132;
const TOTAL: u32 = 32768;

#[derive(Clone, Debug, Default)]
pub struct Stats {
    pub raw: usize,
    pub frame: usize,
    pub payload: usize,
    pub context: u8,
    pub literals: usize,
    pub matches: usize,
    pub events: usize,
    /// 借用sliceのextent。背後Vecの余剰capacityはdriverで別途加算する。
    pub caller_slice_fee: usize,
    pub library_capacity_bound: usize,
    pub peak_capacity_bound: usize,
    pub model_capacity: usize,
    pub output_capacity: usize,
    pub journal_capacity: usize,
    pub journal_transient: usize,
}
fn gate(s: &mut Stats, library: usize) -> Result<()> {
    let total = library
        .checked_add(s.caller_slice_fee)
        .ok_or("RAM overflow")?;
    s.library_capacity_bound = s.library_capacity_bound.max(library);
    s.peak_capacity_bound = s.peak_capacity_bound.max(total);
    if total > RAM_LIMIT {
        return Err("codec RAM bound".into());
    }
    Ok(())
}
fn allocate<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| "allocation failed")?;
    if v.capacity() != n {
        return Err("allocation capacity bound".into());
    }
    v.resize(n, value);
    Ok(v)
}
fn get32(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("header truncated")?
            .try_into()
            .map_err(|_| "header field")?,
    ) as usize)
}
fn put32(b: &mut [u8], at: usize, value: usize) -> Result<()> {
    let value = u32::try_from(value).map_err(|_| "header field overflow")?;
    b[at..at + 4].copy_from_slice(&value.to_le_bytes());
    Ok(())
}
const fn crc_table() -> [u32; 256] {
    let mut table = [0; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut j = 0;
        while j < 8 {
            c = (c >> 1) ^ (0xedb88320u32.wrapping_mul(c & 1));
            j += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}
const CRC_TABLE: [u32; 256] = crc_table();
fn crc(parts: &[&[u8]]) -> u32 {
    let mut c = !0u32;
    for part in parts {
        for &b in *part {
            c = CRC_TABLE[((c as u8) ^ b) as usize] ^ (c >> 8);
        }
    }
    !c
}

trait Reader {
    fn slot(&self, total: u32) -> std::result::Result<u32, &'static str>;
    fn consume(&mut self, c: u32, f: u32, total: u32) -> std::result::Result<(), &'static str>;
}
impl Reader for legacy_range::Decoder<'_> {
    fn slot(&self, total: u32) -> std::result::Result<u32, &'static str> {
        self.slot(total)
    }
    fn consume(&mut self, c: u32, f: u32, total: u32) -> std::result::Result<(), &'static str> {
        self.consume(c, f, total)
    }
}
impl Reader for ans::Decoder<'_> {
    fn slot(&self, total: u32) -> std::result::Result<u32, &'static str> {
        self.slot(total)
    }
    fn consume(&mut self, c: u32, f: u32, total: u32) -> std::result::Result<(), &'static str> {
        self.consume(c, f, total)
    }
}
/// 旧bitモデル。literal prefixを除いた新モデルはbase=0。
struct Bits {
    p: Vec<u16>,
    base: usize,
}
impl Bits {
    fn new(base: usize) -> Result<Self> {
        Ok(Self {
            p: allocate(base + BIT_COUNT, 16384)?,
            base,
        })
    }
    fn capacity_bytes(&self) -> usize {
        self.p.capacity() * 2
    }
    fn update(&mut self, index: usize, bit: u32) {
        let p = u32::from(self.p[index]);
        self.p[index] = if bit == 0 {
            p + ((TOTAL - p) >> 5)
        } else {
            p - (p >> 5)
        } as u16;
    }
    fn read<R: Reader>(&mut self, r: &mut R, index: usize) -> Result<u32> {
        let p = u32::from(self.p[index]);
        let bit = u32::from(r.slot(TOTAL)? >= p);
        r.consume(
            if bit == 0 { 0 } else { p },
            if bit == 0 { p } else { TOTAL - p },
            TOTAL,
        )?;
        self.update(index, bit);
        Ok(bit)
    }
    fn tree_read<R: Reader>(&mut self, r: &mut R, base: usize, bits: usize) -> Result<u32> {
        let mut prefix = 1;
        for _ in 0..bits {
            prefix = prefix * 2 + self.read(r, base + prefix)? as usize;
        }
        Ok((prefix - (1 << bits)) as u32)
    }
    fn number_read<R: Reader>(&mut self, r: &mut R, class: usize, max: usize) -> Result<usize> {
        let base = self.base + 20 + class * 1056;
        let log = self.tree_read(r, base, 5)? as usize;
        if log > 20 {
            return Err("number log bound".into());
        }
        let mut value = 1usize << log;
        for b in (0..log).rev() {
            value |= (self.read(r, base + 32 + log * 32 + b)? as usize) << b;
        }
        if value > max {
            return Err("number value bound".into());
        }
        Ok(value)
    }
    fn write(&mut self, j: &mut Journal, index: usize, bit: u32) -> Result<()> {
        let p = u32::from(self.p[index]);
        j.interval(
            if bit == 0 { 0 } else { p },
            if bit == 0 { p } else { TOTAL - p },
        )?;
        self.update(index, bit);
        Ok(())
    }
    fn tree_write(&mut self, j: &mut Journal, base: usize, value: u32, bits: usize) -> Result<()> {
        let mut prefix = 1;
        for b in (0..bits).rev() {
            let bit = (value >> b) & 1;
            self.write(j, base + prefix, bit)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok(())
    }
    fn number_write(&mut self, j: &mut Journal, class: usize, value: usize) -> Result<()> {
        if value == 0 || value > MAX_RAW || class > 1 {
            return Err("number value bound".into());
        }
        let log = usize::BITS as usize - 1 - value.leading_zeros() as usize;
        let base = self.base + 20 + class * 1056;
        self.tree_write(j, base, log as u32, 5)?;
        for b in (0..log).rev() {
            self.write(j, base + 32 + log * 32 + b, ((value >> b) & 1) as u32)?;
        }
        Ok(())
    }
}
struct Literals {
    cdf: Vec<u16>,
    context: u8,
}
impl Literals {
    fn bytes(context: u8) -> Result<usize> {
        if !matches!(context, 3 | 8) {
            return Err("literal context".into());
        }
        Ok((1usize << context) * 257 * 2)
    }
    fn new(context: u8) -> Result<Self> {
        let bytes = Self::bytes(context)?;
        let mut cdf = allocate(bytes / 2, 0u16)?;
        for row in cdf.chunks_exact_mut(257) {
            for (i, v) in row.iter_mut().enumerate() {
                *v = (i * 128) as u16;
            }
        }
        Ok(Self { cdf, context })
    }
    fn base(&self, previous: u8) -> usize {
        usize::from(previous >> (8 - self.context)) * 257
    }
    fn update(row: &mut [u16], symbol: usize) {
        // 二つの単純loopに分け、LLVMのvectorizationを妨げる分岐を避ける。
        for (i, v) in row.iter_mut().enumerate().take(symbol + 1).skip(1) {
            let part = *v - i as u16;
            *v -= part >> 5;
        }
        for (i, v) in row.iter_mut().enumerate().take(256).skip(symbol + 1) {
            let part = *v - i as u16;
            *v += (32512u16 - part) >> 5;
        }
    }
    fn write(&mut self, j: &mut Journal, previous: u8, byte: u8) -> Result<()> {
        let base = self.base(previous);
        let row = &mut self.cdf[base..base + 257];
        let symbol = usize::from(byte);
        j.interval(
            u32::from(row[symbol]),
            u32::from(row[symbol + 1] - row[symbol]),
        )?;
        Self::update(row, symbol);
        Ok(())
    }
    fn read(&mut self, r: &mut ans::Decoder<'_>, previous: u8) -> Result<u8> {
        let base = self.base(previous);
        let row = &mut self.cdf[base..base + 257];
        let slot = r.slot(TOTAL)? as u16;
        let mut symbol = 0;
        let mut step = 128;
        // 256 symbolなので常に8回。cdf[256]は探索候補にしない。
        for _ in 0..8 {
            if slot >= row[symbol + step] {
                symbol += step;
            }
            step >>= 1;
        }
        r.consume(
            u32::from(row[symbol]),
            u32::from(row[symbol + 1] - row[symbol]),
            TOTAL,
        )?;
        Self::update(row, symbol);
        Ok(symbol as u8)
    }
}
struct Journal {
    encoder: Option<ans::Encoder>,
    events: usize,
    capacity: usize,
    transient: usize,
}
fn journal_growth_guard(events: usize, capacity: usize) -> Result<()> {
    if events > ans::MAX_EVENTS || capacity > ans::MAX_RETAINED_BYTES || capacity % 6 != 0 {
        return Err("ANS journal capacity contract".into());
    }
    // 実capacityがtargetより大きくても、次のreallocの旧+新予約を先に制限する。
    // MAX_EVENTSで満杯ならbackendはallocationなしのlimitを返す。
    if events == capacity / 6
        && events < ans::MAX_EVENTS
        && capacity > ans::MAX_LIVE_BYTES - ans::MAX_RETAINED_BYTES
    {
        return Err("ANS preallocation live bound".into());
    }
    Ok(())
}
impl Journal {
    fn new(limit: usize) -> Result<Self> {
        Ok(Self {
            encoder: Some(ans::Encoder::with_limit(limit)?),
            events: 0,
            capacity: 0,
            transient: 0,
        })
    }
    fn interval(&mut self, c: u32, f: u32) -> Result<()> {
        if let Some(e) = &mut self.encoder {
            journal_growth_guard(e.event_count(), e.capacity_bytes())?;
            match e.interval(c, f, TOTAL) {
                Ok(()) => {
                    self.events = e.event_count();
                    self.capacity = e.capacity_bytes();
                    self.transient = e.transient_bytes();
                    if self.capacity + self.transient > ans::MAX_LIVE_BYTES {
                        return Err("ANS actual live bound".into());
                    }
                }
                Err("ANS journal limit") => self.encoder = None,
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}
fn remember(reps: &mut [usize; 4], distance: usize) {
    let index = reps.iter().position(|&v| v == distance).unwrap_or(3);
    reps.copy_within(0..index, 1);
    reps[0] = distance;
}
fn copy_match(out: &mut Vec<u8>, raw: usize, distance: usize, length: usize) -> Result<()> {
    if out.len() > raw
        || distance == 0
        || distance > out.len()
        || !(3..=4096).contains(&length)
        || length > raw - out.len()
    {
        return Err("match offset/extent".into());
    }
    for _ in 0..length {
        let byte = out[out.len() - distance];
        out.push(byte);
    }
    Ok(())
}
struct LegacyHeader {
    method: u8,
    raw: usize,
    context: u8,
}
fn legacy_header(b: &[u8]) -> Result<LegacyHeader> {
    if b.len() < HEADER {
        return Err("legacy header truncated".into());
    }
    if &b[..8] != b"KHC1BLK\0" {
        return Err("legacy magic".into());
    }
    let revision = u16::from_le_bytes([b[8], b[9]]);
    let method = b[10];
    if !((revision == 1 && method <= 1) || (revision == 2 && method <= 3)) {
        return Err("legacy revision/method".into());
    }
    if b[11] != 0 || b[30..32] != [0, 0] {
        return Err("legacy reserved".into());
    }
    let raw = get32(b, 12)?;
    let primary = get32(b, 16)?;
    let model = get32(b, 20)?;
    let payload = get32(b, 24)?;
    let alphabet = usize::from(u16::from_le_bytes([b[28], b[29]]));
    if raw > MAX_RAW || alphabet > 257 {
        return Err("legacy raw/alphabet bound".into());
    }
    let body = alphabet
        .checked_mul(2)
        .and_then(|v| v.checked_add(model))
        .and_then(|v| v.checked_add(payload))
        .ok_or("legacy extent overflow")?;
    if b.len() != HEADER + body || b.len() > HEADER + raw {
        return Err("legacy extent".into());
    }
    if crc(&[&b[..36], &b[40..]]) as usize != get32(b, 36)? {
        return Err("legacy wire CRC".into());
    }
    if method == 0 {
        if primary != 0 || model != 0 || alphabet != 0 || payload != raw {
            return Err("legacy stored fields".into());
        }
        if crc(&[&b[40..]]) as usize != get32(b, 32)? {
            return Err("legacy raw CRC".into());
        }
    } else if method >= 2 {
        if revision != 2
            || primary != 0
            || model != 0
            || alphabet != 0
            || payload < 5
            || payload >= raw
        {
            return Err("legacy LZ fields".into());
        }
    } else if body >= raw
        || primary > raw
        || !(2..=257).contains(&alphabet)
        || model < 241
        || payload < 5
    {
        return Err("legacy MDL fields".into());
    }
    Ok(LegacyHeader {
        method,
        raw,
        context: if method == 2 { 3 } else { 8 },
    })
}
fn seal(frame: &mut [u8]) {
    let wire = crc(&[&frame[..28], &frame[32..]]);
    frame[28..32].copy_from_slice(&wire.to_le_bytes());
}
fn make_frame(raw: &[u8], payload: &[u8], context: u8, coded: bool) -> Result<Vec<u8>> {
    if raw.len() > MAX_RAW {
        return Err("raw bound".into());
    }
    if coded && (payload.len() < 5 || payload.len() >= raw.len() || !matches!(context, 3 | 8)) {
        return Err("coded extent/context".into());
    }
    if !coded && (context != 0 || payload != raw) {
        return Err("stored fields".into());
    }
    let mut frame = allocate(HEADER + payload.len(), 0u8)?;
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[10] = u8::from(coded);
    frame[11] = context;
    put32(&mut frame, 12, raw.len())?;
    put32(&mut frame, 20, payload.len())?;
    frame[24..28].copy_from_slice(&crc(&[raw]).to_le_bytes());
    frame[40..].copy_from_slice(payload);
    seal(&mut frame);
    Ok(frame)
}

pub fn encode_from_legacy(raw: &[u8], legacy: &[u8]) -> Result<Option<(Vec<u8>, Stats)>> {
    if raw.len() > MAX_RAW {
        return Err("raw bound".into());
    }
    let h = legacy_header(legacy)?;
    if h.raw != raw.len() || crc(&[raw]) as usize != get32(legacy, 32)? {
        return Err("legacy caller raw length/CRC".into());
    }
    if h.method < 2 {
        if h.method == 0 && &legacy[40..] != raw {
            return Err("legacy stored caller mismatch".into());
        }
        return Ok(None);
    }
    let limit = legacy.len() - HEADER - 1;
    let mut stats = Stats {
        raw: raw.len(),
        context: h.context,
        caller_slice_fee: raw.len() + legacy.len(),
        ..Stats::default()
    };
    let old_base = (1usize << h.context) * 256;
    let model_bound = (old_base + BIT_COUNT + BIT_COUNT) * 2 + Literals::bytes(h.context)?;
    // Backendの全retained/transientを、最初のjournal reallocより前から課金。
    let fixed = model_bound + raw.len();
    gate(
        &mut stats,
        fixed + ans::MAX_LIVE_BYTES + limit + HEADER + limit,
    )?;
    let mut old = Bits::new(old_base)?;
    let mut bits = Bits::new(0)?;
    let mut literals = Literals::new(h.context)?;
    let mut out = allocate(raw.len(), 0u8)?;
    out.clear();
    stats.model_capacity =
        old.capacity_bytes() + bits.capacity_bytes() + literals.cdf.capacity() * 2;
    if stats.model_capacity != model_bound {
        return Err("model capacity bound".into());
    }
    let live_models = stats.model_capacity + out.capacity();
    gate(
        &mut stats,
        live_models + ans::MAX_LIVE_BYTES + limit + HEADER + limit,
    )?;
    let mut journal = Journal::new(limit)?;
    let mut range = legacy_range::Decoder::new(&legacy[40..])?;
    let mut reps = [1, 4, 8, 16];
    let mut previous_match = false;
    while out.len() < raw.len() {
        let flag = (out.len() & 7) + usize::from(previous_match) * 8;
        let matched = old.read(&mut range, old_base + flag)?;
        bits.write(&mut journal, flag, matched)?;
        if matched == 1 {
            let fresh = old.read(&mut range, old_base + 16)?;
            bits.write(&mut journal, 16, fresh)?;
            let distance = if fresh == 0 {
                let index = old.tree_read(&mut range, old_base + 16, 2)?;
                bits.tree_write(&mut journal, 16, index, 2)?;
                reps[index as usize]
            } else {
                let value = old.number_read(&mut range, 1, MAX_RAW)?;
                bits.number_write(&mut journal, 1, value)?;
                value
            };
            let number = old.number_read(&mut range, 0, 4094)?;
            bits.number_write(&mut journal, 0, number)?;
            copy_match(&mut out, raw.len(), distance, number + 2)?;
            remember(&mut reps, distance);
            previous_match = true;
            stats.matches += 1;
        } else {
            let previous = out.last().copied().unwrap_or(0);
            let base = usize::from(previous >> (8 - h.context)) * 256;
            let byte = old.tree_read(&mut range, base, 8)? as u8;
            literals.write(&mut journal, previous, byte)?;
            out.push(byte);
            previous_match = false;
            stats.literals += 1;
        }
    }
    range.finish()?;
    if crc(&[&out]) as usize != get32(legacy, 32)? || out != raw {
        return Err("legacy reconstructed raw mismatch".into());
    }
    stats.events = journal.events;
    stats.journal_capacity = journal.capacity;
    stats.journal_transient = journal.transient;
    let Some(encoder) = journal.encoder else {
        return Ok(None);
    };
    let payload = match encoder.finish() {
        Ok(payload) => payload,
        Err("range output limit") => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if payload.capacity() > limit {
        return Err("ANS output capacity".into());
    }
    if payload.len() >= legacy.len() - HEADER {
        return Ok(None);
    }
    gate(
        &mut stats,
        fixed + ans::MAX_LIVE_BYTES + payload.capacity() + HEADER + payload.len(),
    )?;
    let frame = make_frame(raw, &payload, h.context, true)?;
    gate(
        &mut stats,
        fixed + ans::MAX_LIVE_BYTES + payload.capacity() + frame.capacity(),
    )?;
    stats.frame = frame.len();
    stats.payload = payload.len();
    stats.output_capacity = frame.capacity();
    Ok(Some((frame, stats)))
}

pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < HEADER {
        return Err("header truncated".into());
    }
    if &frame[..8] != MAGIC {
        return Err("frame magic".into());
    }
    if frame[8..10] != 1u16.to_le_bytes() {
        return Err("frame revision".into());
    }
    let method = frame[10];
    let context = frame[11];
    if method > 1 || (method == 0 && context != 0) || (method == 1 && !matches!(context, 3 | 8)) {
        return Err("frame method/context".into());
    }
    if get32(frame, 16)? != 0 || frame[32..40] != [0; 8] {
        return Err("frame model/reserved".into());
    }
    let raw = get32(frame, 12)?;
    let payload = get32(frame, 20)?;
    if raw > MAX_RAW || frame.len() != HEADER + payload || frame.len() > HEADER + raw {
        return Err("frame extent/raw bound".into());
    }
    if (method == 0 && payload != raw) || (method == 1 && (payload < 5 || payload >= raw)) {
        return Err("frame canonical size".into());
    }
    if crc(&[&frame[..28], &frame[32..]]) as usize != get32(frame, 28)? {
        return Err("frame wire CRC".into());
    }
    let mut stats = Stats {
        raw,
        frame: frame.len(),
        payload,
        context,
        caller_slice_fee: frame.len(),
        ..Stats::default()
    };
    let model_bound = if method == 1 {
        BIT_COUNT * 2 + Literals::bytes(context)?
    } else {
        0
    };
    gate(&mut stats, model_bound + raw)?;
    let mut out = allocate(raw, 0u8)?;
    stats.output_capacity = out.capacity();
    if method == 0 {
        out.copy_from_slice(&frame[40..]);
    } else {
        out.clear();
        let mut bits = Bits::new(0)?;
        let mut literals = Literals::new(context)?;
        stats.model_capacity = bits.capacity_bytes() + literals.cdf.capacity() * 2;
        let live_models = stats.model_capacity + out.capacity();
        gate(&mut stats, live_models)?;
        let mut r = ans::Decoder::new(&frame[40..])?;
        let mut reps = [1, 4, 8, 16];
        let mut previous_match = false;
        while out.len() < raw {
            let flag = (out.len() & 7) + usize::from(previous_match) * 8;
            if bits.read(&mut r, flag)? == 1 {
                let distance = if bits.read(&mut r, 16)? == 0 {
                    let index = bits.tree_read(&mut r, 16, 2)? as usize;
                    reps[index]
                } else {
                    bits.number_read(&mut r, 1, MAX_RAW)?
                };
                let length = bits.number_read(&mut r, 0, 4094)? + 2;
                copy_match(&mut out, raw, distance, length)?;
                remember(&mut reps, distance);
                previous_match = true;
                stats.matches += 1;
            } else {
                let byte = literals.read(&mut r, out.last().copied().unwrap_or(0))?;
                out.push(byte);
                previous_match = false;
                stats.literals += 1;
            }
        }
        r.finish()?;
    }
    if crc(&[&out]) as usize != get32(frame, 24)? {
        return Err("frame raw CRC".into());
    }
    Ok((out, stats))
}

/// 実行者が結果を記録する有限E2E入口。#[test]・ファイル書込みなし。
#[derive(Clone, Debug, Default)]
pub struct ContractReport {
    pub checks: usize,
    pub contexts: usize,
}
fn check(report: &mut ContractReport, condition: bool, name: &str) -> Result<()> {
    if !condition {
        return Err(format!("finite contract: {name}"));
    }
    report.checks += 1;
    Ok(())
}
fn cdf_valid(row: &[u16]) -> bool {
    row.len() == 257 && row[0] == 0 && row[256] == 32768 && row.windows(2).all(|p| p[0] < p[1])
}
fn fixture(context: u8) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut bits = Bits::new(0)?;
    let mut literals = Literals::new(context)?;
    let mut j = Journal::new(1024)?;
    let mut raw = allocate(1024, 0u8)?;
    raw.clear();
    let mut previous_match = false;
    for byte in 0..32u8 {
        bits.write(&mut j, (raw.len() & 7) + usize::from(previous_match) * 8, 0)?;
        literals.write(&mut j, raw.last().copied().unwrap_or(0), byte)?;
        raw.push(byte);
        previous_match = false;
    }
    let mut reps = [1, 4, 8, 16];
    for distance in [1, 4, 8, 16, 1, 4, 8, 16] {
        let index = reps
            .iter()
            .position(|&d| d == distance)
            .ok_or("fixture rep")?;
        bits.write(&mut j, (raw.len() & 7) + usize::from(previous_match) * 8, 1)?;
        bits.write(&mut j, 16, 0)?;
        bits.tree_write(&mut j, 16, index as u32, 2)?;
        bits.number_write(&mut j, 0, 62)?;
        copy_match(&mut raw, 1024, distance, 64)?;
        remember(&mut reps, distance);
        previous_match = true;
    }
    // fresh-distance経路も含める。
    bits.write(&mut j, (raw.len() & 7) + usize::from(previous_match) * 8, 1)?;
    bits.write(&mut j, 16, 1)?;
    bits.number_write(&mut j, 1, 17)?;
    bits.number_write(&mut j, 0, 62)?;
    copy_match(&mut raw, 1024, 17, 64)?;
    let payload = j.encoder.ok_or("fixture journal")?.finish()?;
    let frame = make_frame(&raw, &payload, context, true)?;
    Ok((raw, frame))
}
fn invalid_match_payload(
    distance: usize,
    length_number: usize,
    log: Option<u32>,
    rep: bool,
) -> Result<Vec<u8>> {
    let mut bits = Bits::new(0)?;
    let mut j = Journal::new(1024)?;
    bits.write(&mut j, 0, 1)?;
    bits.write(&mut j, 16, u32::from(!rep))?;
    if rep {
        bits.tree_write(&mut j, 16, 0, 2)?;
    } else if let Some(log) = log {
        bits.tree_write(&mut j, 20 + 1056, log, 5)?;
    } else {
        bits.number_write(&mut j, 1, distance)?;
    }
    if log.is_none() {
        bits.number_write(&mut j, 0, length_number)?;
    }
    Ok(j.encoder.ok_or("invalid fixture journal")?.finish()?)
}
fn legacy_stored(raw: &[u8]) -> Result<Vec<u8>> {
    let mut frame = allocate(40 + raw.len(), 0u8)?;
    frame[..8].copy_from_slice(b"KHC1BLK\0");
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    put32(&mut frame, 12, raw.len())?;
    put32(&mut frame, 24, raw.len())?;
    frame[32..36].copy_from_slice(&crc(&[raw]).to_le_bytes());
    frame[40..].copy_from_slice(raw);
    let wire = crc(&[&frame[..36], &frame[40..]]);
    frame[36..40].copy_from_slice(&wire.to_le_bytes());
    Ok(frame)
}
/// 有限の正常/異常契約。親harnessから呼び、結果を成果物へ記録する。
pub fn finite_contract() -> Result<ContractReport> {
    let mut report = finite_narrow_contract()?;
    for events in [
        0,
        1024,
        ans::MAX_EVENTS / 2,
        ans::MAX_EVENTS / 2 + 1,
        ans::MAX_EVENTS - 1,
        ans::MAX_EVENTS,
    ] {
        let must_reject = events > ans::MAX_EVENTS / 2 && events < ans::MAX_EVENTS;
        check(
            &mut report,
            journal_growth_guard(events, events * 6).is_err() == must_reject,
            "journal actual-capacity before-realloc guard",
        )?;
    }
    check(
        &mut report,
        journal_growth_guard(ans::MAX_EVENTS / 2, (ans::MAX_EVENTS / 2 + 1) * 6).is_ok(),
        "non-full oversized capacity does not reallocate",
    )?;
    check(
        &mut report,
        crc(&[b"123456789"]) == 0xcbf43926,
        "CRC known vector",
    )?;
    check(
        &mut report,
        Literals::new(0).is_err() && Literals::new(7).is_err(),
        "invalid context",
    )?;
    for context in [3, 8] {
        let mut literal = Literals::new(context)?;
        let initial = Literals::new(context)?;
        for symbol in 0..256 {
            let mut row = [0u16; 257];
            for (i, v) in row.iter_mut().enumerate() {
                *v = (i * 128) as u16;
            }
            Literals::update(&mut row, symbol);
            check(&mut report, cdf_valid(&row), "all symbol CDF")?;
        }
        // 各symbolとslotを実rANS経由で通し、8step探索とupdateの同期を確認する。
        let mut all_encoder = Literals::new(context)?;
        let mut journal = Journal::new(8192)?;
        for previous in [0, 255] {
            for symbol in 0..=255u8 {
                all_encoder.write(&mut journal, previous, symbol)?;
            }
        }
        let payload = journal.encoder.ok_or("all-symbol journal")?.finish()?;
        let mut entropy = ans::Decoder::new(&payload)?;
        let mut all_decoder = Literals::new(context)?;
        for previous in [0, 255] {
            for symbol in 0..=255u8 {
                check(
                    &mut report,
                    all_decoder.read(&mut entropy, previous)? == symbol,
                    "all symbol ANS binary search",
                )?;
            }
        }
        entropy.finish()?;
        check(
            &mut report,
            all_encoder.cdf == all_decoder.cdf,
            "CDF encoder/decoder synchronization",
        )?;
        for symbol in [0, 255] {
            let mut row = [0u16; 257];
            for (i, v) in row.iter_mut().enumerate() {
                *v = (i * 128) as u16;
            }
            for _ in 0..32768 {
                Literals::update(&mut row, symbol);
            }
            check(
                &mut report,
                cdf_valid(&row),
                "long consecutive edge-symbol minimum frequency",
            )?;
        }
        let mut rng = 0x12345678u32;
        for mode in 0..4 {
            for i in 0..4096usize {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                let symbol = match mode {
                    0 => 0,
                    1 => 255,
                    2 => (i & 1) * 255,
                    _ => (rng & 255) as usize,
                };
                let previous = (rng >> 8) as u8;
                let base = literal.base(previous);
                let row = &mut literal.cdf[base..base + 257];
                Literals::update(row, symbol);
                check(
                    &mut report,
                    cdf_valid(row),
                    "CDF minfreq/endpoints/monotonic",
                )?;
            }
        }
        let reset = Literals::new(context)?;
        check(
            &mut report,
            reset.cdf == initial.cdf && reset.cdf != literal.cdf,
            "block reset",
        )?;
        let (raw, frame) = fixture(context)?;
        let (decoded, s) = decode(&frame)?;
        check(
            &mut report,
            decoded == raw && s.matches == 9 && s.literals == 32,
            "coded rep1/4/8/16 overlap + fresh",
        )?;
        check(
            &mut report,
            s.peak_capacity_bound <= RAM_LIMIT,
            "decode RAM",
        )?;
        // headerの独立field破壊。wireCRC以外は再sealしてfield検証へ到達する。
        for at in [0, 8, 10, 11, 16, 32, 39, 24, 28] {
            let mut bad = frame.clone();
            bad[at] ^= if at == 11 { 1 } else { 0x80 };
            if at != 28 {
                seal(&mut bad);
            }
            check(
                &mut report,
                decode(&bad).is_err(),
                "header/magic/revision/reserved/raw/wire CRC",
            )?;
        }
        for extent in [0, 1, 8, 39, 40, frame.len() - 1] {
            check(&mut report, decode(&frame[..extent]).is_err(), "truncation")?;
        }
        let mut trailing = frame.clone();
        trailing.push(0);
        check(&mut report, decode(&trailing).is_err(), "frame trailing")?;
        let mut trailing_ans = frame.clone();
        trailing_ans.push(0);
        put32(&mut trailing_ans, 20, frame.len() - HEADER + 1)?;
        seal(&mut trailing_ans);
        check(&mut report, decode(&trailing_ans).is_err(), "ANS trailing")?;
        let mut bad_prefix = frame.clone();
        bad_prefix[40] = 1;
        seal(&mut bad_prefix);
        check(&mut report, decode(&bad_prefix).is_err(), "ANS prefix")?;
        let mut bad_state = frame.clone();
        bad_state[41..45].fill(0);
        seal(&mut bad_state);
        check(&mut report, decode(&bad_state).is_err(), "ANS state")?;
        check(
            &mut report,
            decode(&frame)?.0 == raw,
            "fresh invocation after errors",
        )?;
        report.contexts += 1;
    }
    for raw in [&b""[..], &b"x"[..], &b"stored block"[..]] {
        let frame = make_frame(raw, raw, 0, false)?;
        check(
            &mut report,
            decode(&frame)?.0 == raw,
            "empty/stored/one byte",
        )?;
        check(
            &mut report,
            encode_from_legacy(raw, &legacy_stored(raw)?)?.is_none(),
            "inapplicable None",
        )?;
    }
    let dummy = [0u8; 1024];
    for (distance, length_number, log, rep) in [
        (1, 1, None, false),
        (1, 1, None, true),
        (1, 1, Some(21), false),
    ] {
        let payload = invalid_match_payload(distance, length_number, log, rep)?;
        let frame = make_frame(&dummy, &payload, 3, true)?;
        check(
            &mut report,
            decode(&frame).is_err(),
            "past distance/rep bounds/log>20",
        )?;
    }
    let mut out = allocate(32, 0u8)?;
    out.clear();
    out.push(1);
    check(
        &mut report,
        copy_match(&mut out, 32, 0, 3).is_err(),
        "distance zero",
    )?;
    check(
        &mut report,
        copy_match(&mut out, 32, 2, 3).is_err(),
        "distance past output",
    )?;
    check(
        &mut report,
        copy_match(&mut out, 2, 1, 3).is_err(),
        "length remaining",
    )?;
    check(
        &mut report,
        copy_match(&mut out, 32, 1, 4097).is_err(),
        "length 4096 bound",
    )?;
    let mut bits = Bits::new(0)?;
    let mut j = Journal::new(1024)?;
    check(
        &mut report,
        bits.number_write(&mut j, 0, 0).is_err(),
        "number zero",
    )?;
    check(
        &mut report,
        bits.number_write(&mut j, 0, MAX_RAW + 1).is_err(),
        "number oversize",
    )?;
    check(
        &mut report,
        ans::Encoder::with_limit(MAX_RAW + 1).is_err(),
        "ANS output bound",
    )?;
    let mut too_small = Journal::new(4)?;
    too_small.interval(0, 16384)?;
    check(
        &mut report,
        too_small
            .encoder
            .ok_or("finite output encoder")?
            .finish()
            .is_err(),
        "ANS output limit",
    )?;
    let mut full = Journal::new(1024)?;
    for _ in 0..=ans::MAX_EVENTS {
        full.interval(0, 16384)?;
    }
    check(
        &mut report,
        full.encoder.is_none() && full.events == ans::MAX_EVENTS,
        "journal bounded fallback",
    )?;
    check(
        &mut report,
        full.capacity + full.transient <= ans::MAX_LIVE_BYTES,
        "journal actual realloc fee",
    )?;
    let mut s = Stats {
        caller_slice_fee: 1,
        ..Stats::default()
    };
    check(
        &mut report,
        gate(&mut s, RAM_LIMIT).is_err(),
        "RAM preallocation gate",
    )?;
    let mut oversize = make_frame(&[], &[], 0, false)?;
    put32(&mut oversize, 12, MAX_RAW + 1)?;
    seal(&mut oversize);
    check(&mut report, decode(&oversize).is_err(), "raw oversize")?;
    let mut noncanonical = ans::Encoder::with_limit(5)?.finish()?;
    noncanonical[1..5].copy_from_slice(&((1u32 << 23) + 1).to_le_bytes());
    check(
        &mut report,
        ans::Decoder::new(&noncanonical)?.finish().is_err(),
        "ANS terminal state",
    )?;
    Ok(report)
}
/// 実legacy fixture毎の有限E2E。Noneでも旧frame検証を通過していることを確認。
pub fn finite_legacy_contract(raw: &[u8], legacy: &[u8]) -> Result<ContractReport> {
    let mut report = ContractReport::default();
    if let Some((frame, s)) = encode_from_legacy(raw, legacy)? {
        check(
            &mut report,
            frame.len() < legacy.len(),
            "strict all-frame benefit",
        )?;
        check(
            &mut report,
            decode(&frame)?.0 == raw,
            "legacy candidate roundtrip",
        )?;
        check(
            &mut report,
            s.peak_capacity_bound <= RAM_LIMIT,
            "encode RAM",
        )?;
    } else {
        report.checks += 1;
    }
    if legacy.len() >= 40 {
        for at in [0, 8, 11, 30, 32, 36] {
            let mut bad = legacy.to_vec();
            bad[at] ^= 0x80;
            check(
                &mut report,
                encode_from_legacy(raw, &bad).is_err(),
                "legacy field/CRC corruption",
            )?;
        }
        check(
            &mut report,
            encode_from_legacy(raw, &legacy[..legacy.len() - 1]).is_err(),
            "legacy truncation",
        )?;
        let mut bad = legacy.to_vec();
        bad.push(0);
        check(
            &mut report,
            encode_from_legacy(raw, &bad).is_err(),
            "legacy trailing",
        )?;
    }
    // エラー後の再呼出しでfresh stateと決定性を確認。
    let first = encode_from_legacy(raw, legacy)?.map(|v| v.0);
    let second = encode_from_legacy(raw, legacy)?.map(|v| v.0);
    check(
        &mut report,
        first == second,
        "legacy fresh-call determinism",
    )?;
    Ok(report)
}

/// 親が指定する非利益LZ fixtureを有限検証する。適用外を非利益扱いしない。
pub fn finite_nonbenefit_contract(raw: &[u8], legacy: &[u8]) -> Result<ContractReport> {
    if legacy_header(legacy)?.method < 2 {
        return Err("nonbenefit requires legacy LZ".into());
    }
    let mut report = ContractReport::default();
    check(
        &mut report,
        encode_from_legacy(raw, legacy)?.is_none(),
        "nonbenefit/journal-output None",
    )?;
    Ok(report)
}

fn usize_update_oracle(row: &mut [u16; 257], symbol: usize) {
    for (i, v) in row.iter_mut().enumerate().take(symbol + 1).skip(1) {
        let part = usize::from(*v) - i;
        *v = (i + part - (part >> 5)) as u16;
    }
    for (i, v) in row.iter_mut().enumerate().take(256).skip(symbol + 1) {
        let part = usize::from(*v) - i;
        *v = (i + part + ((32512 - part) >> 5)) as u16;
    }
}
/// 固定初期rowと64合法random rowの全symbolを旧usize式へ照合する有限入口。
pub fn finite_narrow_contract() -> Result<ContractReport> {
    let mut report = ContractReport::default();
    let mut seed = 0x6d2b79f5u32;
    for row_id in 0..65 {
        let mut original = [0u16; 257];
        if row_id == 0 {
            for (i, value) in original.iter_mut().enumerate() {
                *value = (i * 128) as u16;
            }
        } else {
            for value in &mut original[1..256] {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                *value = (seed % 32513) as u16;
            }
            original[1..256].sort_unstable();
            for (i, value) in original.iter_mut().enumerate().take(256).skip(1) {
                *value += i as u16;
            }
            original[256] = 32768;
        }
        check(
            &mut report,
            cdf_valid(&original),
            "narrow oracle legal input",
        )?;
        for symbol in 0..256 {
            let mut expected = original;
            let mut actual = original;
            usize_update_oracle(&mut expected, symbol);
            Literals::update(&mut actual, symbol);
            check(
                &mut report,
                actual == expected,
                "narrow complete CDF equals usize oracle",
            )?;
            check(
                &mut report,
                cdf_valid(&actual),
                "narrow endpoints and minimum frequency",
            )?;
        }
    }
    Ok(report)
}
