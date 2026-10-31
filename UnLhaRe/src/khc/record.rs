//! KRS1の因果幅copy、幅変更位置を保存するKRS2、適応CDFのKRS3候補。
use super::block as baseline;
#[path = "record_entropy.rs"]
pub mod entropy;
#[path = "record_bound.rs"]
mod information_bound;
#[path = "record_voter.rs"]
pub(super) mod voter;
pub type Result<T> = std::result::Result<T, String>;
pub const MAX_RAW: usize = 1 << 20;
pub const HEADER: usize = 40;
pub const MAGIC: &[u8; 8] = b"KRS1BLK\0";
pub const FAST_MAGIC: &[u8; 8] = b"KRS2BLK\0";
pub const ADAPTIVE_MAGIC: &[u8; 8] = b"KRS3BLK\0";
pub const MODEL_BOUND: usize = 3080;
pub const TABLE_BOUND: usize = 131072;
const FIXED: usize = 32768 + 78000 + 65536;
#[derive(Default, Clone, Debug)]
pub struct Stats {
    pub method: u8,
    pub metadata: usize,
    pub pruned: bool,
    pub fields: usize,
    pub tokens: usize,
    pub copied: usize,
    pub literals: usize,
    pub width: usize,
    pub journal: usize,
    pub transient: usize,
    pub logical_bound: usize,
    pub reason: &'static str,
}
fn gate(s: &mut Stats, size: usize) -> Result<()> {
    s.logical_bound = s.logical_bound.max(size);
    if s.logical_bound > 64 * 1024 * 1024 {
        return Err("copy memory bound".into());
    }
    Ok(())
}
fn bytes(n: usize) -> Result<Vec<u8>> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| "copy allocation failed")?;
    if v.capacity() > n {
        return Err("copy allocation capacity".into());
    }
    Ok(v)
}
pub fn u32_at(b: &[u8], i: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(i..i + 4)
            .ok_or("copy truncated u32")?
            .try_into()
            .map_err(|_| "copy u32")?,
    ) as usize)
}
fn u16_at(b: &[u8], i: usize) -> Result<usize> {
    Ok(u16::from_le_bytes(
        b.get(i..i + 2)
            .ok_or("copy truncated u16")?
            .try_into()
            .map_err(|_| "copy u16")?,
    ) as usize)
}
pub fn wire_crc(frame: &[u8]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..28]);
    digest.update(&frame[32..]);
    digest.finalize() as u32
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub freq: [u16; 256],
    pub cum: [u16; 256],
    pub support: usize,
}
impl Model {
    pub fn normalize(counts: &[u32; 256]) -> Result<Self> {
        let support = counts.iter().filter(|&&x| x != 0).count();
        let total: u64 = counts.iter().map(|&x| u64::from(x)).sum();
        let mut freq = [0u16; 256];
        let mut residues = [(0u64, 0usize); 256];
        let mut used = 0usize;
        let mut at = 0;
        if total != 0 {
            let remaining = 32768 - support;
            for (symbol, &count) in counts.iter().enumerate() {
                if count != 0 {
                    let product = u64::from(count) * remaining as u64;
                    freq[symbol] =
                        (1 + product.checked_div(total).ok_or("copy normalization sum")?) as u16;
                    used += usize::from(freq[symbol]);
                    residues[at] = (product % total, symbol);
                    at += 1;
                }
            }
            residues[..support].sort_unstable_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
            let extra = 32768usize
                .checked_sub(used)
                .ok_or("copy normalization sum")?;
            if extra > support {
                return Err("copy normalization remainder".into());
            }
            for &(_, symbol) in &residues[..extra] {
                freq[symbol] += 1;
            }
        }
        Self::from_freq(freq)
    }
    pub fn from_freq(freq: [u16; 256]) -> Result<Self> {
        let support = freq.iter().filter(|&&x| x != 0).count();
        let mut cum = [0u16; 256];
        let mut sum = 0u32;
        for symbol in 0..256 {
            if sum > 32768 {
                return Err("copy CDF overflow".into());
            }
            cum[symbol] = sum as u16;
            sum += u32::from(freq[symbol]);
        }
        if sum != (if support == 0 { 0 } else { 32768 }) {
            return Err("copy CDF total".into());
        }
        Ok(Self { freq, cum, support })
    }
    fn write(&self, output: &mut Vec<u8>) {
        output.extend_from_slice(&(self.support as u16).to_le_bytes());
        for symbol in 0..256 {
            if self.freq[symbol] != 0 {
                output.push(symbol as u8);
                output.extend_from_slice(&self.freq[symbol].to_le_bytes());
            }
        }
    }
    fn parse(input: &[u8], at: &mut usize) -> Result<Self> {
        let support = u16_at(input, *at)?;
        *at += 2;
        if support > 256 {
            return Err("copy model support".into());
        }
        let mut freq = [0u16; 256];
        let mut previous = None;
        for _ in 0..support {
            let symbol = usize::from(*input.get(*at).ok_or("copy model truncated")?);
            let value = u16_at(input, *at + 1)?;
            *at += 3;
            if value == 0 || previous.is_some_and(|p| symbol <= p) {
                return Err("copy model order/frequency".into());
            }
            freq[symbol] = value as u16;
            previous = Some(symbol);
        }
        Self::from_freq(freq)
    }
    pub fn lut(&self) -> Result<Vec<u8>> {
        let mut v = bytes(32768)?;
        v.resize(32768, 0);
        for symbol in 0..256 {
            let begin = usize::from(self.cum[symbol]);
            let end = begin + usize::from(self.freq[symbol]);
            v[begin..end].fill(symbol as u8);
        }
        Ok(v)
    }
    pub fn put(&self, symbol: u8, encoder: &mut entropy::Encoder) -> Result<()> {
        // 再確保前に旧領域<=6MiBを保証する。allocatorの過剰capacityを想定する。
        if encoder.event_count() * 6 == encoder.capacity_bytes()
            && encoder.event_count() < entropy::MAX_EVENTS
            && encoder.capacity_bytes() > entropy::MAX_RETAINED_BYTES / 2
        {
            return Err("copy journal transient capacity".into());
        }
        let symbol = usize::from(symbol);
        encoder
            .interval(
                u32::from(self.cum[symbol]),
                u32::from(self.freq[symbol]),
                32768,
            )
            .map_err(str::to_owned)
    }
    fn get(&self, lut: &[u8], decoder: &mut entropy::Decoder<'_>) -> Result<u8> {
        if self.support == 0 {
            return Err("copy empty model read".into());
        }
        let symbol = lut[decoder.slot(32768).map_err(str::to_owned)? as usize];
        let index = usize::from(symbol);
        decoder
            .consume(
                u32::from(self.cum[index]),
                u32::from(self.freq[index]),
                32768,
            )
            .map_err(str::to_owned)?;
        Ok(symbol)
    }
}
struct AdaptiveState {
    counts: [[u32; 256]; 4],
    events: [u32; 4],
}
// 初期化・戻り値の一時コピーとnormalizeのresidue/model作業領域も課金する。
const ADAPTIVE_BOUND: usize = 4 * std::mem::size_of::<AdaptiveState>()
    + 8 * std::mem::size_of::<Model>()
    + 2 * std::mem::size_of::<[(u64, usize); 256]>();
impl AdaptiveState {
    fn new(models: &[Model; 4]) -> Self {
        Self {
            // encoder/decoderともwireへ保存した量子化済み頻度から開始する。
            counts: std::array::from_fn(|class| models[class].freq.map(u32::from)),
            events: [0; 4],
        }
    }
    fn observe(&mut self, models: &mut [Model; 4], class: usize, symbol: u8) -> Result<bool> {
        let count = &mut self.counts[class][usize::from(symbol)];
        *count = count.checked_add(1).ok_or("copy adaptive count overflow")?;
        self.events[class] = self.events[class]
            .checked_add(1)
            .ok_or("copy adaptive event overflow")?;
        if !self.events[class].is_multiple_of(1024) {
            return Ok(false);
        }
        for count in &mut self.counts[class] {
            if *count != 0 {
                *count = (*count / 2) + (*count % 2);
            }
        }
        models[class] = Model::normalize(&self.counts[class])?;
        Ok(true)
    }
}
fn scheduled_symbol(
    models: &mut [Model; 4],
    luts: &mut [Vec<u8>; 4],
    adaptive: Option<&mut AdaptiveState>,
    class: usize,
    decoder: &mut entropy::Decoder<'_>,
) -> Result<u8> {
    let symbol = models[class].get(&luts[class], decoder)?;
    if let Some(state) = adaptive
        && state.observe(models, class, symbol)?
    {
        // 既存LUTを上書きし、再構築用の追加LUTを確保しない。
        let model = &models[class];
        for symbol in 0..256 {
            let begin = usize::from(model.cum[symbol]);
            let end = begin + usize::from(model.freq[symbol]);
            luts[class][begin..end].fill(symbol as u8);
        }
    }
    Ok(symbol)
}
pub fn serialize(models: &[Model; 4]) -> Result<Vec<u8>> {
    let mut out = bytes(MODEL_BOUND)?;
    for m in models {
        m.write(&mut out);
    }
    Ok(out)
}
pub fn parse_models(input: &[u8]) -> Result<[Model; 4]> {
    if !(8..=MODEL_BOUND).contains(&input.len()) {
        return Err("copy model extent".into());
    }
    let mut at = 0;
    let a = Model::parse(input, &mut at)?;
    let b = Model::parse(input, &mut at)?;
    let c = Model::parse(input, &mut at)?;
    let d = Model::parse(input, &mut at)?;
    if at != input.len() || a.support == 0 || b.freq[0] != 0 || c.freq[0] != 0 || d.freq[0] != 0 {
        return Err("copy model fields".into());
    }
    Ok([a, b, c, d])
}
pub fn residual_class(pred: u8) -> usize {
    if pred == 0 {
        1
    } else if pred == 255 {
        2
    } else {
        3
    }
}
pub fn scan(raw: &[u8], mut field: impl FnMut(usize, u8) -> Result<()>) -> Result<Stats> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let mut voter = voter::Voter::new()?;
    if voter.capacity() > voter::BOUND {
        return Err("copy voter capacity".into());
    }
    let mut s = Stats::default();
    let mut at = 0;
    while at < raw.len() {
        let begin = at;
        while at < raw.len() {
            let pred = at.checked_sub(voter.best()).map_or(0, |i| raw[i]);
            if pred != raw[at] {
                break;
            }
            voter.observe(raw[at])?;
            at += 1;
        }
        let mut count = at - begin;
        s.copied += count;
        s.tokens += 1;
        loop {
            let byte = (count & 127) as u8;
            count >>= 7;
            field(0, byte | if count != 0 { 128 } else { 0 })?;
            s.fields += 1;
            if count == 0 {
                break;
            }
        }
        if at < raw.len() {
            let pred = at.checked_sub(voter.best()).map_or(0, |i| raw[i]);
            let residual = raw[at] ^ pred;
            if residual == 0 {
                return Err("copy maximal grammar".into());
            }
            field(residual_class(pred), residual)?;
            s.fields += 1;
            s.literals += 1;
            voter.observe(raw[at])?;
            at += 1;
        }
    }
    s.width = voter.best();
    Ok(s)
}
fn packed_len(raw_len: usize, model_len: usize, payload_len: usize) -> Result<usize> {
    if raw_len > MAX_RAW || model_len > MODEL_BOUND || model_len + payload_len > raw_len + 40 {
        return Err("copy pack bound".into());
    }
    Ok(HEADER + model_len + payload_len)
}
pub fn pack(raw: &[u8], model: &[u8], payload: &[u8], method: u8) -> Result<Vec<u8>> {
    let mut frame = pack_unsealed(raw, model, payload, method)?;
    let crc = wire_crc(&frame);
    frame[28..32].copy_from_slice(&crc.to_le_bytes());
    Ok(frame)
}
// scheduled経路の中間frameは公開せず、schedule追加後に一度だけwire CRCを確定する。
fn pack_unsealed(raw: &[u8], model: &[u8], payload: &[u8], method: u8) -> Result<Vec<u8>> {
    let mut frame = bytes(packed_len(raw.len(), model.len(), payload.len())?)?;
    frame.resize(HEADER, 0);
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&1u16.to_le_bytes());
    frame[10] = method;
    frame[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    frame[16..20].copy_from_slice(&(model.len() as u32).to_le_bytes());
    frame[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[24..28].copy_from_slice(&baseline::crc32(raw).to_le_bytes());
    frame.extend_from_slice(model);
    frame.extend_from_slice(payload);
    Ok(frame)
}
pub fn record(raw: &[u8], bound: usize, s: &mut Stats, retained: usize) -> Result<Vec<u8>> {
    record_with_adaptation(raw, bound, s, retained, false)
}
struct RecordPreparation {
    histogram: [[u32; 256]; 4],
    observed: Stats,
    metadata: Vec<u8>,
}
#[derive(Clone, Copy)]
enum RecordOutputMode {
    Materialize,
    LengthOnly,
}
enum RecordOutput {
    Frame(Vec<u8>),
    Length(usize),
}
impl RecordOutput {
    fn len(&self) -> usize {
        match self {
            Self::Frame(frame) => frame.len(),
            Self::Length(length) => *length,
        }
    }
    fn capacity(&self) -> usize {
        match self {
            Self::Frame(frame) => frame.capacity(),
            Self::Length(length) => *length,
        }
    }
    fn into_frame(self) -> Result<Vec<u8>> {
        match self {
            Self::Frame(frame) => Ok(frame),
            Self::Length(_) => Err("copy record output mode".into()),
        }
    }
}
struct RecordSource<'a> {
    raw: &'a [u8],
    scheduled: Option<&'a ScheduledPreparation>,
}
impl RecordSource<'_> {
    fn scan(&self, field: impl FnMut(usize, u8) -> Result<()>) -> Result<Stats> {
        if let Some(prepared) = self.scheduled {
            scan_scheduled(self.raw, prepared, field)
        } else {
            scan(self.raw, field)
        }
    }
}
impl RecordPreparation {
    fn new(raw: &[u8]) -> Result<(Self, [Model; 4])> {
        Self::from_source(&RecordSource {
            raw,
            scheduled: None,
        })
    }
    fn from_source(source: &RecordSource<'_>) -> Result<(Self, [Model; 4])> {
        let mut histogram = [[0u32; 256]; 4];
        let observed = source.scan(|class, byte| {
            histogram[class][usize::from(byte)] += 1;
            Ok(())
        })?;
        let models = [
            Model::normalize(&histogram[0])?,
            Model::normalize(&histogram[1])?,
            Model::normalize(&histogram[2])?,
            Model::normalize(&histogram[3])?,
        ];
        let metadata = serialize(&models)?;
        Ok((
            Self {
                histogram,
                observed,
                metadata,
            },
            models,
        ))
    }
}
fn record_with_adaptation(
    raw: &[u8],
    bound: usize,
    s: &mut Stats,
    retained: usize,
    adaptive: bool,
) -> Result<Vec<u8>> {
    let scratch = if adaptive { ADAPTIVE_BOUND } else { 0 };
    gate(
        s,
        raw.len() + retained + FIXED + MODEL_BOUND + voter::BOUND + scratch,
    )?;
    let (prepared, models) = RecordPreparation::new(raw)?;
    encode_prepared_record(raw, bound, s, retained, adaptive, &prepared, models)
}
fn encode_prepared_record(
    raw: &[u8],
    bound: usize,
    s: &mut Stats,
    retained: usize,
    adaptive: bool,
    prepared: &RecordPreparation,
    models: [Model; 4],
) -> Result<Vec<u8>> {
    encode_prepared_record_source(
        &RecordSource {
            raw,
            scheduled: None,
        },
        bound,
        s,
        retained,
        adaptive,
        (prepared, models),
        RecordOutputMode::Materialize,
    )?
    .into_frame()
}
fn encode_prepared_record_source(
    source: &RecordSource<'_>,
    bound: usize,
    s: &mut Stats,
    retained: usize,
    adaptive: bool,
    preparation: (&RecordPreparation, [Model; 4]),
    output_mode: RecordOutputMode,
) -> Result<RecordOutput> {
    let (prepared, mut models) = preparation;
    let raw = source.raw;
    let observed = &prepared.observed;
    let metadata = &prepared.metadata;
    let scratch = if adaptive { ADAPTIVE_BOUND } else { 0 };
    s.metadata = metadata.len();
    if bound <= metadata.len() + 5 {
        return Err("range output limit".into());
    }
    let limit = bound - metadata.len() - 1;
    if !adaptive {
        let frequencies = [
            models[0].freq,
            models[1].freq,
            models[2].freq,
            models[3].freq,
        ];
        let lower = information_bound::impossible(
            &prepared.histogram,
            &frequencies,
            observed.fields,
            limit,
        )?;
        if lower.prune {
            s.pruned = true;
            s.fields = observed.fields;
            s.tokens = observed.tokens;
            s.copied = observed.copied;
            s.literals = observed.literals;
            s.width = observed.width;
            return Err("record information lower bound".into());
        }
    }
    let phase = raw.len() + retained + FIXED + MODEL_BOUND + voter::BOUND + scratch;
    gate(s, phase + entropy::MAX_LIVE_BYTES + limit + HEADER + bound)?;
    let mut encoder = entropy::Encoder::with_limit(limit).map_err(str::to_owned)?;
    let mut state = adaptive.then(|| AdaptiveState::new(&models));
    let encoded = source.scan(|class, byte| {
        models[class].put(byte, &mut encoder)?;
        if let Some(state) = &mut state {
            state.observe(&mut models, class, byte)?;
        }
        Ok(())
    })?;
    if observed.tokens != encoded.tokens
        || observed.fields != encoded.fields
        || observed.width != encoded.width
    {
        return Err("copy scan drift".into());
    }
    s.fields = encoded.fields;
    s.tokens = encoded.tokens;
    s.copied = encoded.copied;
    s.literals = encoded.literals;
    s.width = encoded.width;
    s.journal = encoder.capacity_bytes();
    s.transient = encoder.transient_bytes();
    if encoder.event_count() != s.fields
        || s.journal > entropy::MAX_RETAINED_BYTES
        || s.transient > entropy::MAX_LIVE_BYTES - entropy::MAX_RETAINED_BYTES
    {
        return Err("copy journal bound".into());
    }
    match output_mode {
        RecordOutputMode::Materialize => {
            let payload = encoder.finish().map_err(str::to_owned)?;
            s.method = 1;
            let frame = if source.scheduled.is_some() {
                pack_unsealed(raw, metadata, &payload, 1)?
            } else {
                pack(raw, metadata, &payload, 1)?
            };
            Ok(RecordOutput::Frame(frame))
        }
        RecordOutputMode::LengthOnly => {
            let payload_len = encoder.finish_len().map_err(str::to_owned)?;
            s.method = 1;
            Ok(RecordOutput::Length(packed_len(
                raw.len(),
                metadata.len(),
                payload_len,
            )?))
        }
    }
}
pub fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    encode_with_baseline(raw, |raw| {
        let (frame, stats) = baseline::encode_hybrid(raw, true)?;
        Ok((frame, stats.phase_capacity_bound))
    })
}
pub(super) fn encode_with_baseline(
    raw: &[u8],
    baseline: impl FnOnce(&[u8]) -> Result<(Vec<u8>, usize)>,
) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let (legacy, phase_capacity_bound) = baseline(raw)?;
    let mut s = Stats::default();
    gate(&mut s, phase_capacity_bound + raw.len() + FIXED)?;
    if raw.len() > 5 {
        match record(raw, raw.len().min(legacy.len()), &mut s, legacy.capacity()) {
            Ok(frame) => return Ok((frame, s)),
            Err(e) if e == "record information lower bound" => {
                s.reason = "information lower bound";
            }
            Err(e) if e == "range output limit" || e == "ANS journal limit" => {
                s.reason = "record output/journal limit"
            }
            Err(e) => return Err(e),
        }
    }
    if legacy.len() < raw.len() {
        s.method = 2;
        let frame = pack(raw, &[], &legacy, 2)?;
        Ok((frame, s))
    } else {
        s.method = 0;
        let frame = pack(raw, &[], raw, 0)?;
        Ok((frame, s))
    }
}
pub fn read_count(mut get: impl FnMut() -> Result<u8>, remaining: usize) -> Result<usize> {
    let mut count = 0usize;
    for index in 0..3 {
        let byte = get()?;
        let part = usize::from(byte & 127);
        count |= part << (index * 7);
        if byte & 128 == 0 {
            if index > 0 && part == 0 {
                return Err("copy noncanonical ULEB".into());
            }
            if count > remaining {
                return Err("copy run bound".into());
            }
            return Ok(count);
        }
    }
    Err("copy ULEB fourth byte".into())
}
pub fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < HEADER
        || frame.len() > MAX_RAW + 80
        || &frame[..8] != MAGIC
        || u16_at(frame, 8)? != 1
    {
        return Err("copy header/version".into());
    }
    if frame[11] != 0 || frame[32..40] != [0; 8] {
        return Err("copy reserved".into());
    }
    let raw = u32_at(frame, 12)?;
    let model = u32_at(frame, 16)?;
    let payload = u32_at(frame, 20)?;
    if raw > MAX_RAW
        || model > MODEL_BOUND
        || payload > raw + 40
        || HEADER
            .checked_add(model)
            .and_then(|v| v.checked_add(payload))
            != Some(frame.len())
        || frame.len() > raw + 80
    {
        return Err("copy lengths".into());
    }
    if wire_crc(frame) as usize != u32_at(frame, 28)? {
        return Err("copy wire CRC".into());
    }
    let mut s = Stats {
        method: frame[10],
        metadata: model,
        ..Stats::default()
    };
    gate(
        &mut s,
        frame.len() + raw + FIXED + TABLE_BOUND + voter::BOUND,
    )?;
    let body = &frame[HEADER + model..];
    let output = match s.method {
        0 => {
            if model != 0 || payload != raw {
                return Err("copy stored fields".into());
            }
            let mut v = bytes(raw)?;
            v.extend_from_slice(body);
            v
        }
        2 => {
            if model != 0
                || payload < 40
                || body.get(..8) != Some(&b"KHC1BLK\0"[..])
                || u32_at(body, 12)? != raw
            {
                return Err("copy legacy fields".into());
            }
            let (v, old) = baseline::decode(body)?;
            gate(&mut s, old.phase_capacity_bound + frame.len() + FIXED)?;
            v
        }
        1 => {
            if payload < 5 || model + payload >= raw {
                return Err("copy coded fields".into());
            }
            let models = parse_models(&frame[HEADER..HEADER + model])?;
            let luts = [
                models[0].lut()?,
                models[1].lut()?,
                models[2].lut()?,
                models[3].lut()?,
            ];
            let mut decoder = entropy::Decoder::new(body).map_err(str::to_owned)?;
            let mut voter = voter::Voter::new()?;
            if voter.capacity() > voter::BOUND {
                return Err("copy voter capacity".into());
            }
            let mut out = bytes(raw)?;
            while out.len() < raw {
                let count = read_count(
                    || {
                        s.fields += 1;
                        models[0].get(&luts[0], &mut decoder)
                    },
                    raw - out.len(),
                )?;
                s.tokens += 1;
                s.copied += count;
                for _ in 0..count {
                    let pred = out.len().checked_sub(voter.best()).map_or(0, |i| out[i]);
                    out.push(pred);
                    voter.observe(pred)?;
                }
                if out.len() < raw {
                    let predictor = out.len().checked_sub(voter.best()).map_or(0, |i| out[i]);
                    let class = residual_class(predictor);
                    let residual = models[class].get(&luts[class], &mut decoder)?;
                    if residual == 0 {
                        return Err("copy zero residual".into());
                    }
                    let pred = out.len().checked_sub(voter.best()).map_or(0, |i| out[i]);
                    let byte = pred ^ residual;
                    out.push(byte);
                    voter.observe(byte)?;
                    s.fields += 1;
                    s.literals += 1;
                }
            }
            s.width = voter.best();
            decoder.finish().map_err(str::to_owned)?;
            out
        }
        _ => return Err("copy unknown method".into()),
    };
    if output.len() != raw || baseline::crc32(&output) as usize != u32_at(frame, 24)? {
        return Err("copy raw CRC/length".into());
    }
    Ok((output, s))
}
/// 復元を行わない一覧経路の構造検査。確保前のextent検査はarchive側の責務。
pub(super) fn validate_frame(frame: &[u8], expected: usize) -> Result<()> {
    if frame.len() < HEADER
        || frame.len() > MAX_RAW + 80
        || frame.get(..8) != Some(&MAGIC[..])
        || u16_at(frame, 8)? != 1
        || frame[11] != 0
        || frame[32..40] != [0; 8]
    {
        return Err("copy header/version/reserved".into());
    }
    let raw = u32_at(frame, 12)?;
    let model = u32_at(frame, 16)?;
    let payload = u32_at(frame, 20)?;
    if raw != expected
        || raw > MAX_RAW
        || model > MODEL_BOUND
        || payload > raw + 40
        || HEADER
            .checked_add(model)
            .and_then(|v| v.checked_add(payload))
            != Some(frame.len())
        || frame.len() > raw + 80
        || wire_crc(frame) as usize != u32_at(frame, 28)?
    {
        return Err("copy lengths/expected/wire CRC".into());
    }
    let body = &frame[HEADER + model..];
    match frame[10] {
        0 if model == 0 && payload == raw => Ok(()),
        1 if payload >= 5 && model + payload < raw => {
            parse_models(&frame[HEADER..HEADER + model])?;
            Ok(())
        }
        2 if model == 0 && payload >= 40 && body.get(..8) == Some(&baseline::MAGIC[..]) => {
            super::validate_legacy_frame(body, raw, 2).map_err(|e| e.to_string())
        }
        _ => Err("copy canonical method fields".into()),
    }
}

/// KRS1と同じfield列を使い、復号時のvoter再計算を位置scheduleへ置換する。
pub(super) fn encode_fast(raw: &[u8]) -> Result<Vec<u8>> {
    encode_scheduled(raw, false)
}

pub(super) fn encode_adaptive(raw: &[u8]) -> Result<Vec<u8>> {
    encode_scheduled(raw, true)
}

fn encode_scheduled(raw: &[u8], adaptive: bool) -> Result<Vec<u8>> {
    let prepared = prepare_scheduled(raw)?;
    match encode_prepared_scheduled(raw, &prepared, None, adaptive)? {
        Some(frame) => Ok(frame),
        None => Ok(prepared.legacy),
    }
}

pub(super) fn scheduled_lengths(raw: &[u8]) -> Result<(usize, usize)> {
    let mut prepared = prepare_scheduled(raw)?;
    let candidate_bound = prepared
        .bound
        .saturating_sub(HEADER + prepared.schedule.len());
    let shared = if prepared.complete && raw.len() > 5 && candidate_bound > 0 {
        let mut stats = Stats {
            logical_bound: prepared.logical_bound,
            ..Stats::default()
        };
        let phase = raw.len()
            + prepared.legacy.capacity()
            + prepared.schedule.capacity()
            + FIXED
            + MODEL_BOUND
            + voter::BOUND;
        gate(&mut stats, phase + SHARED_RECORD_BUILD_BOUND)?;
        let (record, models) = RecordPreparation::from_source(&RecordSource {
            raw,
            scheduled: Some(&prepared),
        })?;
        let shared = SharedRecordPreparation { record, models };
        gate(&mut stats, phase + shared.retained_bytes())?;
        prepared.logical_bound = stats.logical_bound;
        Some(shared)
    } else {
        None
    };
    // 内側frameから完成長だけを求め、schedule挿入・外側CRCを省く。
    // frameは長さの算出後に破棄し、次のcoderと同時保持しない。
    let fast = scheduled_record_candidate(
        raw,
        &prepared,
        shared.as_ref(),
        false,
        RecordOutputMode::LengthOnly,
    )?
    .map_or(prepared.legacy.len(), |record| {
        record.len() + prepared.schedule.len()
    });
    let adaptive = scheduled_record_candidate(
        raw,
        &prepared,
        shared.as_ref(),
        true,
        RecordOutputMode::LengthOnly,
    )?
    .map_or(prepared.legacy.len(), |record| {
        record.len() + prepared.schedule.len()
    });
    Ok((fast, adaptive))
}

struct SharedRecordPreparation {
    record: RecordPreparation,
    models: [Model; 4],
}
// 構築・戻り値の一時コピー、normalizeのmodel/residue作業領域も保守的に課金する。
const SHARED_RECORD_BUILD_BOUND: usize = 4 * std::mem::size_of::<SharedRecordPreparation>()
    + MODEL_BOUND
    + 8 * std::mem::size_of::<Model>()
    + 2 * std::mem::size_of::<[(u64, usize); 256]>();
impl SharedRecordPreparation {
    fn retained_bytes(&self) -> usize {
        std::mem::size_of::<Self>() + self.record.metadata.capacity()
    }
}

struct ScheduledPreparation {
    legacy: Vec<u8>,
    schedule: Vec<u8>,
    final_width: usize,
    bound: usize,
    complete: bool,
    logical_bound: usize,
}

fn prepare_scheduled(raw: &[u8]) -> Result<ScheduledPreparation> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let (legacy, old) = baseline::encode_hybrid(raw, true)?;
    let mut stats = Stats::default();
    gate(&mut stats, old.phase_capacity_bound + raw.len() + FIXED)?;
    let bound = raw.len().min(legacy.len());
    // scheduleもfallbackより小さいbody予算へ課金し、再確保しない。
    let mut schedule = bytes(bound)?;
    gate(
        &mut stats,
        raw.len() + legacy.capacity() + schedule.capacity() + voter::BOUND + FIXED,
    )?;
    let mut voter = voter::Voter::new()?;
    if voter.capacity() > voter::BOUND {
        return Err("copy voter capacity".into());
    }
    let mut previous = 0;
    let mut complete = true;
    for (index, &byte) in raw.iter().enumerate() {
        let before = voter.best();
        voter.observe(byte)?;
        let position = index + 1;
        if voter.best() != before && position < raw.len() {
            let mut delta = position - previous;
            let mut event = [0u8; 5];
            let mut length = 0;
            loop {
                let part = (delta & 127) as u8;
                delta >>= 7;
                event[length] = part | if delta != 0 { 128 } else { 0 };
                length += 1;
                if delta == 0 {
                    break;
                }
            }
            event[length..length + 2].copy_from_slice(&(voter.best() as u16).to_le_bytes());
            length += 2;
            if schedule.len() + length >= bound {
                complete = false;
                break;
            }
            schedule.extend_from_slice(&event[..length]);
            previous = position;
        }
    }
    // 最後のbyte後の幅変更はwire scheduleへ書かないが、scanの統計には必要。
    let final_width = voter.best();
    drop(voter);
    Ok(ScheduledPreparation {
        legacy,
        schedule,
        final_width,
        bound,
        complete,
        logical_bound: stats.logical_bound,
    })
}

fn scan_scheduled(
    raw: &[u8],
    prepared: &ScheduledPreparation,
    mut field: impl FnMut(usize, u8) -> Result<()>,
) -> Result<Stats> {
    if raw.len() > MAX_RAW {
        return Err("copy input bound".into());
    }
    let mut events = Schedule::new(&prepared.schedule, raw.len());
    let mut next = events.next()?;
    let mut width = 1;
    let mut s = Stats::default();
    let mut at = 0;
    while at < raw.len() {
        let begin = at;
        while at < raw.len() {
            // copy runの途中でも、予測するbyteの位置で幅変更を適用する。
            apply_width(&mut events, &mut next, at, &mut width)?;
            let pred = at.checked_sub(width).map_or(0, |i| raw[i]);
            if pred != raw[at] {
                break;
            }
            at += 1;
        }
        let mut count = at - begin;
        s.copied += count;
        s.tokens += 1;
        loop {
            let byte = (count & 127) as u8;
            count >>= 7;
            field(0, byte | if count != 0 { 128 } else { 0 })?;
            s.fields += 1;
            if count == 0 {
                break;
            }
        }
        if at < raw.len() {
            let pred = at.checked_sub(width).map_or(0, |i| raw[i]);
            let residual = raw[at] ^ pred;
            if residual == 0 {
                return Err("copy maximal grammar".into());
            }
            field(residual_class(pred), residual)?;
            s.fields += 1;
            s.literals += 1;
            at += 1;
        }
    }
    if next.is_some() || events.at != events.bytes.len() {
        return Err("copy schedule unconsumed".into());
    }
    s.width = prepared.final_width;
    Ok(s)
}

fn encode_prepared_scheduled(
    raw: &[u8],
    prepared: &ScheduledPreparation,
    shared: Option<&SharedRecordPreparation>,
    adaptive: bool,
) -> Result<Option<Vec<u8>>> {
    let Some(frame) = scheduled_record_candidate(
        raw,
        prepared,
        shared,
        adaptive,
        RecordOutputMode::Materialize,
    )?
    else {
        return Ok(None);
    };
    let frame = frame.into_frame()?;
    let schedule = &prepared.schedule;
    let mut output = bytes(frame.len() + schedule.len())?;
    output.extend_from_slice(&frame[..HEADER]);
    let model = u32_at(&frame, 16)?;
    output.extend_from_slice(&frame[HEADER..HEADER + model]);
    output.extend_from_slice(schedule);
    output.extend_from_slice(&frame[HEADER + model..]);
    scheduled_header(&mut output, schedule.len(), adaptive);
    Ok(Some(output))
}

fn scheduled_record_candidate(
    raw: &[u8],
    prepared: &ScheduledPreparation,
    shared: Option<&SharedRecordPreparation>,
    adaptive: bool,
    output_mode: RecordOutputMode,
) -> Result<Option<RecordOutput>> {
    let legacy = &prepared.legacy;
    let schedule = &prepared.schedule;
    let bound = prepared.bound;
    let mut stats = Stats {
        logical_bound: prepared.logical_bound,
        ..Stats::default()
    };
    let candidate_bound = bound.saturating_sub(HEADER + schedule.len());
    if prepared.complete && raw.len() > 5 && candidate_bound > 0 {
        let shared_retained = shared.map_or(0, SharedRecordPreparation::retained_bytes);
        let retained = legacy.capacity() + schedule.capacity() + shared_retained;
        let source = RecordSource {
            raw,
            scheduled: Some(prepared),
        };
        let scratch = if adaptive { ADAPTIVE_BOUND } else { 0 };
        gate(
            &mut stats,
            raw.len() + retained + FIXED + MODEL_BOUND + voter::BOUND + scratch,
        )?;
        let record = if let Some(shared) = shared {
            // 各候補はwireと同じ初期CDFの独立コピーから開始する。
            encode_prepared_record_source(
                &source,
                candidate_bound,
                &mut stats,
                retained,
                adaptive,
                (&shared.record, shared.models.clone()),
                output_mode,
            )
        } else {
            let (record, models) = RecordPreparation::from_source(&source)?;
            encode_prepared_record_source(
                &source,
                candidate_bound,
                &mut stats,
                retained,
                adaptive,
                (&record, models),
                output_mode,
            )
        };
        match record {
            Ok(record) => {
                // recordのboundは外側headerを含まないため、完全なscheduled frameでも厳密に比較する。
                if record.len() + schedule.len() >= bound {
                    // fallbackへ戻り、余分なframeを組み立てない。
                } else {
                    // 長さ評価でも、実出力の内外frame同時保持に必要なgateを維持する。
                    gate(
                        &mut stats,
                        raw.len()
                            + legacy.capacity()
                            + schedule.capacity()
                            + shared_retained
                            + record.capacity()
                            + HEADER
                            + schedule.len()
                            + record.len()
                            + FIXED,
                    )?;
                    return Ok(Some(record));
                }
            }
            Err(e)
                if e == "record information lower bound"
                    || e == "range output limit"
                    || e == "ANS journal limit" => {}
            Err(e) => return Err(e),
        }
    }
    Ok(None)
}

fn scheduled_header(frame: &mut [u8], schedule: usize, adaptive: bool) {
    frame[..8].copy_from_slice(if adaptive { ADAPTIVE_MAGIC } else { FAST_MAGIC });
    let version = if adaptive { 3u16 } else { 2u16 };
    frame[8..10].copy_from_slice(&version.to_le_bytes());
    frame[32..36].copy_from_slice(&(schedule as u32).to_le_bytes());
    let crc = wire_crc(frame);
    frame[28..32].copy_from_slice(&crc.to_le_bytes());
}

struct Schedule<'a> {
    bytes: &'a [u8],
    at: usize,
    position: usize,
    raw: usize,
}
impl<'a> Schedule<'a> {
    fn new(bytes: &'a [u8], raw: usize) -> Self {
        Self {
            bytes,
            at: 0,
            position: 0,
            raw,
        }
    }
    fn next(&mut self) -> Result<Option<(usize, usize)>> {
        if self.at == self.bytes.len() {
            return Ok(None);
        }
        let delta = read_count(
            || {
                let byte = *self.bytes.get(self.at).ok_or("copy schedule truncated")?;
                self.at += 1;
                Ok(byte)
            },
            MAX_RAW,
        )?;
        if delta == 0 {
            return Err("copy schedule zero delta".into());
        }
        self.position = self
            .position
            .checked_add(delta)
            .ok_or("copy schedule overflow")?;
        if self.position >= self.raw {
            return Err("copy schedule position".into());
        }
        let width = u16_at(self.bytes, self.at)?;
        self.at += 2;
        if !(1..=1024).contains(&width) {
            return Err("copy schedule width".into());
        }
        Ok(Some((self.position, width)))
    }
}

pub(super) fn validate_fast_frame(frame: &[u8], expected: usize) -> Result<()> {
    validate_scheduled_frame(frame, expected, false)
}

pub(super) fn validate_adaptive_frame(frame: &[u8], expected: usize) -> Result<()> {
    validate_scheduled_frame(frame, expected, true)
}

fn validate_scheduled_frame(frame: &[u8], expected: usize, adaptive: bool) -> Result<()> {
    let magic = if adaptive { ADAPTIVE_MAGIC } else { FAST_MAGIC };
    let version = if adaptive { 3 } else { 2 };
    if frame.len() < HEADER
        || frame.len() > MAX_RAW + 40
        || frame.get(..8) != Some(&magic[..])
        || u16_at(frame, 8)? != version
        || frame[11] != 0
        || frame[36..40] != [0; 4]
    {
        return Err("copy fast header/version/reserved".into());
    }
    let raw = u32_at(frame, 12)?;
    let model = u32_at(frame, 16)?;
    let payload = u32_at(frame, 20)?;
    let schedule = u32_at(frame, 32)?;
    if raw != expected
        || raw > MAX_RAW
        || model > MODEL_BOUND
        || payload > raw + 40
        || schedule > raw
        || HEADER
            .checked_add(model)
            .and_then(|v| v.checked_add(schedule))
            .and_then(|v| v.checked_add(payload))
            != Some(frame.len())
        || frame.len() > raw + 40
        || wire_crc(frame) as usize != u32_at(frame, 28)?
    {
        return Err("copy fast lengths/expected/wire CRC".into());
    }
    match frame[10] {
        1 if payload >= 5 && model + schedule + payload < raw => {
            parse_models(&frame[HEADER..HEADER + model])?;
            let mut events = Schedule::new(&frame[HEADER + model..HEADER + model + schedule], raw);
            while events.next()?.is_some() {}
            Ok(())
        }
        _ => Err("copy fast coded method fields".into()),
    }
}

pub(super) fn decode_fast(frame: &[u8]) -> Result<Vec<u8>> {
    decode_scheduled(frame, false)
}

pub(super) fn decode_adaptive(frame: &[u8]) -> Result<Vec<u8>> {
    decode_scheduled(frame, true)
}

fn decode_scheduled(frame: &[u8], adaptive: bool) -> Result<Vec<u8>> {
    let raw = u32_at(frame, 12)?;
    validate_scheduled_frame(frame, raw, adaptive)?;
    let model = u32_at(frame, 16)?;
    let schedule = u32_at(frame, 32)?;
    let body = &frame[HEADER + model + schedule..];
    let mut stats = Stats::default();
    gate(
        &mut stats,
        frame.len() + raw + FIXED + TABLE_BOUND + if adaptive { ADAPTIVE_BOUND } else { 0 },
    )?;
    let output = match frame[10] {
        1 => {
            let mut models = parse_models(&frame[HEADER..HEADER + model])?;
            let mut state = adaptive.then(|| AdaptiveState::new(&models));
            let mut luts = [
                models[0].lut()?,
                models[1].lut()?,
                models[2].lut()?,
                models[3].lut()?,
            ];
            let mut decoder = entropy::Decoder::new(body).map_err(str::to_owned)?;
            let mut events = Schedule::new(&frame[HEADER + model..HEADER + model + schedule], raw);
            let mut next = events.next()?;
            let mut width = 1;
            let mut output = bytes(raw)?;
            while output.len() < raw {
                let mut count = read_count(
                    || scheduled_symbol(&mut models, &mut luts, state.as_mut(), 0, &mut decoder),
                    raw - output.len(),
                )?;
                while count != 0 {
                    apply_width(&mut events, &mut next, output.len(), &mut width)?;
                    let stop = next.map_or(raw, |event| event.0);
                    let take = count.min(stop - output.len());
                    copy_run(&mut output, width, take);
                    count -= take;
                }
                if output.len() < raw {
                    apply_width(&mut events, &mut next, output.len(), &mut width)?;
                    let pred = output.len().checked_sub(width).map_or(0, |i| output[i]);
                    let class = residual_class(pred);
                    let residual = scheduled_symbol(
                        &mut models,
                        &mut luts,
                        state.as_mut(),
                        class,
                        &mut decoder,
                    )?;
                    if residual == 0 {
                        return Err("copy zero residual".into());
                    }
                    output.push(pred ^ residual);
                }
            }
            if next.is_some() || events.at != events.bytes.len() {
                return Err("copy schedule unconsumed".into());
            }
            decoder.finish().map_err(str::to_owned)?;
            output
        }
        _ => return Err("copy fast unknown method".into()),
    };
    if output.len() != raw || baseline::crc32(&output) as usize != u32_at(frame, 24)? {
        return Err("copy raw CRC/length".into());
    }
    Ok(output)
}

fn apply_width(
    events: &mut Schedule<'_>,
    next: &mut Option<(usize, usize)>,
    position: usize,
    width: &mut usize,
) -> Result<()> {
    if let Some((at, value)) = *next {
        if at < position {
            return Err("copy schedule missed position".into());
        }
        if at == position {
            *width = value;
            *next = events.next()?;
        }
    }
    Ok(())
}

fn copy_run(output: &mut Vec<u8>, width: usize, mut count: usize) {
    if output.len() < width {
        let zeros = count.min(width - output.len());
        output.resize(output.len() + zeros, 0);
        count -= zeros;
    }
    let start = output.len().saturating_sub(width);
    while count != 0 {
        let take = count.min(output.len() - start);
        output.extend_from_within(start..start + take);
        count -= take;
    }
}
