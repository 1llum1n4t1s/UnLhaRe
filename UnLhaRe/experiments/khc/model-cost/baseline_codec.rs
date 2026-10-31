//! 自己完結block。検証済みframeを製品内部namespaceへ移植する。
#[path = "../../../src/khc/block/bundle.rs"]
mod bundle;
#[path = "../../../src/khc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/khc/block/codebook.rs"]
mod codebook;
#[path = "../../../src/khc/block/counts.rs"]
mod counts;
#[path = "../../../src/khc/block/frontend.rs"]
mod frontend;
#[path = "../../../src/khc/block/grammar.rs"]
mod grammar;
#[path = "../../../src/khc/block/histogram.rs"]
mod histogram;
#[path = "../../../src/khc/block/lz.rs"]
mod lz;
#[path = "baseline_model.rs"]
pub(crate) mod model;
#[path = "../../../src/khc/block/multi_range.rs"]
mod multi_range;
#[path = "../../../src/khc/block/packed.rs"]
mod packed;
#[path = "../../../src/khc/block/packet.rs"]
mod packet;
#[path = "../../../src/khc/block/paid_model.rs"]
mod paid_model;
pub(crate) type Result<T> = std::result::Result<T, String>;
pub(crate) const MAX_INPUT: usize = 1 << 20;
pub(crate) const HEADER: usize = 40;
pub(crate) const MAGIC: &[u8; 8] = b"KHC1BLK\0";
pub(crate) const SCRATCH_BOUND: usize = 32768 + 65536;
#[derive(Default, Clone, Debug)]
pub(crate) struct Stats {
    pub method: u8,
    pub raw: usize,
    pub frame: usize,
    pub alphabet: usize,
    pub metadata: usize,
    pub payload: usize,
    pub bwt: usize,
    pub walks: usize,
    pub fits: usize,
    pub roots: usize,
    pub root_cdfs: usize,
    pub branches: usize,
    pub implicit: usize,
    pub escapes: usize,
    pub runs: usize,
    pub front_capacity: usize,
    pub dense_capacity: usize,
    pub hist_capacity: usize,
    pub fit_capacity: usize,
    pub packet_capacity: usize,
    pub forest_capacity: usize,
    pub parse_transient: usize,
    pub range_capacity_bound: usize,
    pub output_capacity: usize,
    pub inverse_capacity: usize,
    pub phase_capacity_bound: usize,
    pub scratch_capacity_bound: usize,
    pub stored_reason: &'static str,
}
pub(crate) fn crc32(bytes: &[u8]) -> u32 {
    crc_parts(&[bytes])
}
fn crc_parts(parts: &[&[u8]]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    for p in parts {
        digest.update(p);
    }
    digest.finalize() as u32
}
fn get32(b: &[u8], i: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(i..i + 4)
            .ok_or("header truncated")?
            .try_into()
            .map_err(|_| "header u32")?,
    ) as usize)
}
fn put32(b: &mut [u8], i: usize, v: usize) -> Result<()> {
    b[i..i + 4].copy_from_slice(
        &u32::try_from(v)
            .map_err(|_| "header u32 overflow")?
            .to_le_bytes(),
    );
    Ok(())
}
pub(crate) fn reseal(frame: &mut [u8]) -> Result<()> {
    if frame.len() < HEADER {
        return Err("header truncated".into());
    }
    let c = crc_parts(&[&frame[..36], &frame[40..]]);
    frame[36..40].copy_from_slice(&c.to_le_bytes());
    Ok(())
}
fn allocate<T: Clone>(n: usize, v: T) -> Result<Vec<T>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| "frame allocation")?;
    out.resize(n, v);
    Ok(out)
}
fn gate(s: &mut Stats, bound: usize) -> Result<()> {
    s.phase_capacity_bound = s.phase_capacity_bound.max(bound);
    s.scratch_capacity_bound = SCRATCH_BOUND;
    if s.phase_capacity_bound > 64 * 1024 * 1024 {
        return Err("codec RAM bound".into());
    }
    Ok(())
}
fn frame(
    raw: &[u8],
    primary: usize,
    alphabet: &[u16],
    metadata: &[u8],
    payload: &[u8],
    method: u8,
    s: &mut Stats,
) -> Result<Vec<u8>> {
    let body = alphabet
        .len()
        .checked_mul(2)
        .and_then(|n| n.checked_add(metadata.len()))
        .and_then(|n| n.checked_add(payload.len()))
        .ok_or("frame length overflow")?;
    if (method == 0 && body != raw.len()) || (method != 0 && body >= raw.len()) {
        return Err("frame canonical size".into());
    }
    let mut out = allocate(
        HEADER.checked_add(body).ok_or("frame length overflow")?,
        0u8,
    )?;
    out[..8].copy_from_slice(MAGIC);
    out[8..10].copy_from_slice(&(if method >= 2 { 2u16 } else { 1u16 }).to_le_bytes());
    out[10] = method;
    put32(&mut out, 12, raw.len())?;
    put32(&mut out, 16, primary)?;
    put32(&mut out, 20, metadata.len())?;
    put32(&mut out, 24, payload.len())?;
    out[28..30].copy_from_slice(&(alphabet.len() as u16).to_le_bytes());
    out[32..36].copy_from_slice(&crc32(raw).to_le_bytes());
    let mut at = HEADER;
    for &v in alphabet {
        out[at..at + 2].copy_from_slice(&v.to_le_bytes());
        at += 2;
    }
    out[at..at + metadata.len()].copy_from_slice(metadata);
    at += metadata.len();
    out[at..].copy_from_slice(payload);
    reseal(&mut out)?;
    s.method = method;
    s.raw = raw.len();
    s.frame = out.len();
    s.alphabet = alphabet.len() * 2;
    s.metadata = metadata.len();
    s.payload = payload.len();
    s.output_capacity = out.capacity();
    Ok(out)
}
fn stored(raw: &[u8], mut s: Stats, reason: &'static str) -> Result<(Vec<u8>, Stats)> {
    s.stored_reason = reason;
    let out = frame(raw, 0, &[], &[], raw, 0, &mut s)?;
    gate(&mut s, raw.len() + out.capacity() + SCRATCH_BOUND)?;
    Ok((out, s))
}
fn encode_interval(
    enc: &mut multi_range::Encoder,
    f: [u16; 4],
    k: usize,
    child: usize,
) -> Result<()> {
    if child >= k {
        return Err("encode child".into());
    }
    let cumulative = f[..child].iter().map(|&v| u32::from(v)).sum();
    enc.interval(cumulative, u32::from(f[child]), 32768)
        .map_err(str::to_owned)
}
fn escape_write(enc: &mut multi_range::Encoder, mut value: usize, s: &mut Stats) -> Result<()> {
    loop {
        let mut b = (value & 127) as u8;
        value >>= 7;
        if value != 0 {
            b |= 128;
        }
        enc.interval(u32::from(b), 1, 256).map_err(str::to_owned)?;
        s.escapes += 1;
        if value == 0 {
            return Ok(());
        }
    }
}
pub(crate) fn encode(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    encode_mode(raw, false)
}
pub(crate) fn encode_low_history_only(raw: &[u8]) -> Result<(Vec<u8>, Stats)> {
    encode_mode(raw, true)
}
/// 選択に使った全圧縮試行をこの呼出し内で実行する。既定経路とは分離する。
pub(crate) fn encode_hybrid(raw: &[u8], adaptive: bool) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_INPUT {
        return Err("input exceeds block limit".into());
    }
    let text = raw
        .iter()
        .filter(|&&b| matches!(b, 9 | 10 | 13 | 32..=126))
        .count();
    let use_mdl = !adaptive || text * 10 >= raw.len() * 9;
    let (mut best, mut s) = if use_mdl {
        encode(raw)?
    } else {
        stored(raw, Stats::default(), "LZ fallback")?
    };
    if !adaptive || !use_mdl {
        // 既存MDLのphaseは終了済み。best frameを保持したLZの最大live容量を課金する。
        gate(&mut s, 12 * MAX_INPUT + best.capacity())?;
        for context in if adaptive { &[8u8][..] } else { &[3u8, 8][..] } {
            if let Some(payload) = lz::encode(raw, *context)?
                && HEADER + payload.len() < best.len()
            {
                best = frame(
                    raw,
                    0,
                    &[],
                    &[],
                    &payload,
                    if *context == 3 { 2 } else { 3 },
                    &mut s,
                )?;
            }
        }
    }
    best[8..10].copy_from_slice(&2u16.to_le_bytes());
    reseal(&mut best)?;
    Ok((best, s))
}

pub(crate) fn revision_method_valid(bytes: &[u8]) -> bool {
    bytes.len() >= 12
        && match u16::from_le_bytes([bytes[8], bytes[9]]) {
            1 => bytes[10] <= 1,
            2 => bytes[10] <= 3,
            _ => false,
        }
}
fn encode_mode(raw: &[u8], low_only: bool) -> Result<(Vec<u8>, Stats)> {
    if raw.len() > MAX_INPUT {
        return Err("input exceeds block limit".into());
    }
    let mut s = Stats {
        raw: raw.len(),
        ..Stats::default()
    };
    // 最小packet241+alphabet4+range5=250B。raw<=250ではstrict利益なし。
    if raw.len() <= 250 {
        return stored(raw, s, "minimum body");
    }
    // SA-ISの幾何級数縮小workspaceとFront形成の保守的上界。入力1MiB限定。
    gate(
        &mut s,
        40 * (raw.len() + 1) + 8 * 1024 * 1024 + SCRATCH_BOUND,
    )?;
    let front = frontend::Front::new(raw)?;
    s.bwt = 1;
    s.front_capacity = front.runs.capacity() * 12 + std::mem::size_of::<frontend::Front>();
    s.runs = front.runs.len();
    let mut alphabet = [0u16; 257];
    let mut seen = [false; 257];
    let mut alphabet_len = 0;
    for r in &front.runs {
        let symbol = r.symbol as usize;
        if symbol > 256 {
            return Err("front symbol".into());
        }
        if !seen[symbol] {
            seen[symbol] = true;
            alphabet[alphabet_len] = symbol as u16;
            alphabet_len += 1;
        }
    }
    let mut dense = counts::Dense::new()?;
    let trained = grammar::walk(&front, |c, n, _class, k, h, ch| {
        if k > 1 {
            dense.record(c, n, k, h, ch)?;
        }
        Ok(())
    })?;
    s.walks += 1;
    s.dense_capacity = dense.capacity_bytes();
    let book = codebook::Encoder::new(codebook::LENGTHS)?;
    let decoder = codebook::Decoder::new(codebook::LENGTHS)?;
    let codec_capacity = book.capacity_bytes() + decoder.capacity_bytes();
    let mut packet = packet::Packet::new(&book)?;
    let mut empty_fit: Option<paid_model::Fit> = None;
    let mut checked_defaults = [false; 3];
    for c in 0..2 {
        for n in 0..142 {
            // 全値ゼロだけを共有する。非ゼロuniformモデルは通常経路で構築する。
            let active = if dense.class_empty(c, n)? {
                if empty_fit.is_none() {
                    let hist = model::Hist::new()?;
                    s.hist_capacity = s.hist_capacity.max(hist.capacity_bytes());
                    empty_fit = Some(paid_model::Fit::build(&hist)?);
                    s.fits += 1;
                }
                None
            } else {
                let mut low = model::Hist::new()?;
                let mut high = if low_only {
                    None
                } else {
                    Some(model::Hist::new()?)
                };
                for k in 2..=4 {
                    for h in 0..1024u16 {
                        let row = dense.row(c, n, k, h)?;
                        // rowの検査は残す。ゼロ初期化＋検査付き加算だけのHistへ0を加えない。
                        if row == [0; 4] {
                            continue;
                        }
                        bundle::ingest(&mut low, k, h, row)?;
                        if let Some(high) = high.as_mut() {
                            bundle::ingest(high, k, model::reverse_history(h), row)?;
                        }
                    }
                }
                s.hist_capacity = s.hist_capacity.max(
                    low.capacity_bytes() + high.as_ref().map_or(0, model::Hist::capacity_bytes),
                );
                let l = paid_model::Fit::build(&low)?;
                let r = high.as_ref().map(paid_model::Fit::build_high).transpose()?;
                s.fits += 1 + usize::from(r.is_some());
                Some((l, r))
            };
            // 共有Fitと活動クラスFitが同時生存する容量も上限へ含める。
            s.fit_capacity = s.fit_capacity.max(
                empty_fit
                    .as_ref()
                    .map_or(0, paid_model::Fit::capacity_bytes)
                    + active.as_ref().map_or(0, |(l, r)| {
                        l.capacity_bytes() + r.as_ref().map_or(0, paid_model::Fit::capacity_bytes)
                    }),
            );
            let selected = match active.as_ref() {
                Some((l, Some(r))) => paid_model::Selected::new(l, r)?,
                Some((l, None)) => paid_model::Selected::low_only(l)?,
                None => {
                    paid_model::Selected::low_only(empty_fit.as_ref().ok_or("empty fit state")?)?
                }
            };
            for k in 2..=4 {
                let default = selected.root_default(k)?;
                // nosplit uniform rootのwire/CDFはkだけで決まる。block内で1回検証する。
                if !default || !checked_defaults[k - 2] {
                    let (bytes, bits) = selected.root_wire(k, &book)?;
                    let d = paid_model::parse_root(&bytes, bits, k, &decoder)?;
                    s.parse_transient = s
                        .parse_transient
                        .max(d.capacity_bytes() + bytes.capacity() + codec_capacity);
                    for h in 0..1024u16 {
                        if d.lookup(0, k, h)? != selected.lookup(0, k, h)? {
                            return Err("frame root wire CDF".into());
                        }
                        s.root_cdfs += 1;
                    }
                    drop(d);
                    drop(bytes);
                    checked_defaults[k - 2] |= default;
                }
                packet.append_root(&selected, k)?;
                s.roots += 1;
            }
        }
    }
    let metadata = packet.finish()?;
    drop(empty_fit);
    s.packet_capacity = metadata.capacity();
    drop(dense);
    drop(decoder);
    let model_bound = raw.len()
        + s.front_capacity
        + s.dense_capacity
        + s.hist_capacity
        + s.fit_capacity
        + s.packet_capacity
        + s.parse_transient
        + SCRATCH_BOUND
        + 4 * 1024 * 1024;
    gate(&mut s, model_bound)?;
    let prefix = alphabet_len * 2 + metadata.len();
    if prefix.checked_add(5).ok_or("body length overflow")? >= raw.len() {
        drop(metadata);
        drop(front);
        return stored(raw, s, "metadata no benefit");
    }
    let forest = packet::Forest::parse(&metadata)?;
    s.forest_capacity = forest.capacity_bytes();
    s.parse_transient = s
        .parse_transient
        .max(forest.parse_dispatch_peak + forest.parse_reader_capacity);
    let limit = raw.len() - prefix - 1;
    s.range_capacity_bound = limit;
    let mut enc = multi_range::Encoder::with_limit(limit).map_err(str::to_owned)?;
    let mut run = 0;
    let encoded = grammar::walk_with_terminal(&front, |c, n, _class, k, h, ch, terminal| {
        s.branches += 1;
        if k == 1 {
            s.implicit += 1;
        } else {
            encode_interval(&mut enc, forest.lookup(c, n, k, h)?, k, ch)?;
        }
        if c == 1 && terminal {
            let r = front.runs.get(run).ok_or("encode run")?;
            if r.length >= 256 {
                escape_write(&mut enc, r.length as usize - 256, &mut s)?;
            }
            run += 1;
        }
        Ok(())
    });
    s.walks += 1;
    // 唯一許可するfallback error。allocation/model/state errorは伝播する。
    let encoded = match encoded {
        Ok(m) => m,
        Err(e) if e == "range output limit" => {
            drop(enc);
            drop(forest);
            drop(metadata);
            drop(front);
            return stored(raw, s, "range no benefit");
        }
        Err(e) => return Err(e),
    };
    if encoded != trained || run != front.runs.len() || s.escapes != trained.escapes {
        return Err("frame whole Meta encode equality".into());
    }
    let payload = match enc.finish() {
        Ok(p) => p,
        Err("range output limit") => {
            drop(forest);
            drop(metadata);
            drop(front);
            return stored(raw, s, "range finish no benefit");
        }
        Err(e) => return Err(e.into()),
    };
    s.range_capacity_bound = s.range_capacity_bound.max(payload.capacity());
    let encode_bound = raw.len()
        + s.front_capacity
        + s.dense_capacity
        + s.hist_capacity
        + s.fit_capacity
        + s.packet_capacity
        + s.forest_capacity
        + s.parse_transient
        + s.range_capacity_bound
        + HEADER
        + raw.len()
        + SCRATCH_BOUND
        + 4 * 1024 * 1024;
    gate(&mut s, encode_bound)?;
    drop(forest);
    let out = frame(
        raw,
        front.primary,
        &alphabet[..alphabet_len],
        &metadata,
        &payload,
        1,
        &mut s,
    )?;
    drop(front);
    drop(metadata);
    drop(payload);
    Ok((out, s))
}
fn decode_interval(dec: &mut multi_range::Decoder<'_>, f: [u16; 4], k: usize) -> Result<usize> {
    if f[..k].iter().any(|&v| v < 2)
        || f[k..].iter().any(|&v| v != 0)
        || f.iter().map(|&v| u32::from(v)).sum::<u32>() != 32768
    {
        return Err("wire CDF support/total/tail".into());
    }
    let slot = dec.slot(32768).map_err(str::to_owned)?;
    let mut sum = 0;
    for (i, &frequency) in f.iter().enumerate().take(k) {
        let v = u32::from(frequency);
        if slot < sum + v {
            dec.consume(sum, v, 32768).map_err(str::to_owned)?;
            return Ok(i);
        }
        sum += v;
    }
    Err("range CDF child".into())
}
fn token(
    dec: &mut multi_range::Decoder<'_>,
    forest: &packet::Forest,
    tree: &grammar::CompactTree,
    c: usize,
    limit: usize,
    histories: &mut [u16; 6],
    s: &mut Stats,
) -> Result<usize> {
    let mut n = 0;
    let mut depth = 0;
    loop {
        depth += 1;
        if depth > 16 || s.branches > 16 * (s.raw + 1) * 2 {
            return Err("branch limit".into());
        }
        let (node, k) = tree.node(n, limit)?;
        let class = c * 3 + node.class as usize;
        let ch = if k == 1 {
            s.implicit += 1;
            0
        } else {
            decode_interval(dec, forest.lookup(c, n, k, histories[class])?, k)?
        };
        histories[class] = ((histories[class] << 2) | ch as u16) & 1023;
        s.branches += 1;
        let (lo, next) = node.edge(ch, k)?;
        if let Some(next) = next {
            n = next;
        } else {
            if lo >= limit {
                return Err("decoded token limit".into());
            }
            return Ok(lo);
        }
    }
}
fn escape_read(
    dec: &mut multi_range::Decoder<'_>,
    remaining: usize,
    s: &mut Stats,
) -> Result<usize> {
    let mut value = 0usize;
    for i in 0..3 {
        let b = dec.slot(256).map_err(str::to_owned)? as u8;
        dec.consume(u32::from(b), 1, 256).map_err(str::to_owned)?;
        s.escapes += 1;
        let part = usize::from(b & 127);
        value = value
            .checked_add(part.checked_shl((7 * i) as u32).ok_or("escape overflow")?)
            .ok_or("escape overflow")?;
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
pub(crate) fn decode(bytes: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if bytes.len() < HEADER {
        return Err("header truncated".into());
    }
    if &bytes[..8] != MAGIC {
        return Err("frame magic".into());
    }
    if !matches!(u16::from_le_bytes([bytes[8], bytes[9]]), 1 | 2) {
        return Err("frame revision".into());
    }
    let method = bytes[10];
    if !revision_method_valid(bytes) {
        return Err("frame method".into());
    }
    if bytes[11] != 0 || bytes[30..32] != [0, 0] {
        return Err("frame flags/reserved".into());
    }
    let raw = get32(bytes, 12)?;
    if raw > MAX_INPUT {
        return Err("raw exceeds block limit".into());
    }
    let primary = get32(bytes, 16)?;
    let model_len = get32(bytes, 20)?;
    let payload_len = get32(bytes, 24)?;
    let alphabet_len =
        u16::from_le_bytes(bytes[28..30].try_into().map_err(|_| "alphabet length")?) as usize;
    let body = alphabet_len
        .checked_mul(2)
        .and_then(|n| n.checked_add(model_len))
        .and_then(|n| n.checked_add(payload_len))
        .ok_or("frame length overflow")?;
    if HEADER.checked_add(body).ok_or("frame length overflow")? != bytes.len() {
        return Err("frame exact extent".into());
    }
    if (method == 0 && (primary != 0 || model_len != 0 || alphabet_len != 0 || payload_len != raw))
        || (method >= 2
            && (primary != 0
                || model_len != 0
                || alphabet_len != 0
                || payload_len < 5
                || payload_len >= raw))
        || (method == 1
            && (body >= raw
                || primary > raw
                || !(2..=257).contains(&alphabet_len)
                || !(241..=packet::MAX_BUNDLE_BYTES).contains(&model_len)
                || payload_len < 5))
    {
        return Err("frame canonical fields".into());
    }
    if crc_parts(&[&bytes[..36], &bytes[40..]]) != get32(bytes, 36)? as u32 {
        return Err("wire CRC".into());
    }
    let mut s = Stats {
        method,
        raw,
        frame: bytes.len(),
        alphabet: alphabet_len * 2,
        metadata: model_len,
        payload: payload_len,
        ..Stats::default()
    };
    if method == 0 {
        let mut plain = allocate(raw, 0u8)?;
        plain.copy_from_slice(&bytes[40..]);
        if crc32(&plain) != get32(bytes, 32)? as u32 {
            return Err("plain CRC".into());
        }
        s.output_capacity = plain.capacity();
        gate(&mut s, bytes.len() + plain.capacity() + SCRATCH_BOUND)?;
        return Ok((plain, s));
    }
    if method >= 2 {
        gate(&mut s, 12 * MAX_INPUT + bytes.len())?;
        let plain = lz::decode(&bytes[40..], raw, if method == 2 { 3 } else { 8 })?;
        if crc32(&plain) != get32(bytes, 32)? as u32 {
            return Err("plain CRC".into());
        }
        s.output_capacity = plain.capacity();
        return Ok((plain, s));
    }
    let mut alphabet = [0u16; 257];
    let mut active = [0u16; 257];
    let mut seen = [false; 257];
    for i in 0..alphabet_len {
        let off = 40 + i * 2;
        let v = u16::from_le_bytes(
            bytes[off..off + 2]
                .try_into()
                .map_err(|_| "alphabet field")?,
        );
        if v > 256 || seen[v as usize] {
            return Err("alphabet range/duplicate".into());
        }
        seen[v as usize] = true;
        alphabet[i] = v;
        active[i] = v;
    }
    if !seen[0] {
        return Err("alphabet sentinel absent".into());
    }
    let model_start = 40 + alphabet_len * 2;
    let forest = packet::Forest::parse(&bytes[model_start..model_start + model_len])?;
    s.forest_capacity = forest.capacity_bytes();
    s.parse_transient = forest.parse_dispatch_peak + forest.parse_reader_capacity;
    let mut dec =
        multi_range::Decoder::new(&bytes[model_start + model_len..]).map_err(str::to_owned)?;
    let trees = [
        grammar::CompactTree::new(257)?,
        grammar::CompactTree::new(256)?,
    ];
    let mut histories = [0u16; 6];
    let mut remaining = raw + 1;
    let mut active_len = alphabet_len;
    let mut last = allocate(raw + 1, 0u16)?;
    let mut written = 0;
    let mut encountered = [false; 257];
    let mut encounter_count = 0;
    while remaining != 0 {
        if active_len == 0 || s.runs > raw {
            return Err("active/runs terminal".into());
        }
        let symbol = active[0];
        if !encountered[symbol as usize] {
            if alphabet[encounter_count] != symbol {
                return Err("alphabet first occurrence order".into());
            }
            encountered[symbol as usize] = true;
            encounter_count += 1;
        }
        let rank = token(
            &mut dec,
            &forest,
            &trees[0],
            0,
            active_len,
            &mut histories,
            &mut s,
        )?;
        let length_token = token(
            &mut dec,
            &forest,
            &trees[1],
            1,
            remaining.min(256),
            &mut histories,
            &mut s,
        )?;
        let length = if length_token == 255 {
            escape_read(&mut dec, remaining, &mut s)?
        } else {
            length_token + 1
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
        if rank != 0 {
            if rank > active_len {
                return Err("active insertion rank".into());
            }
            active.copy_within(rank..active_len, rank + 1);
            active[rank] = symbol;
            active_len += 1;
        }
    }
    if active_len != 0 || encounter_count != alphabet_len {
        return Err("active/alphabet terminal".into());
    }
    dec.finish().map_err(str::to_owned)?;
    drop(forest);
    let inverse = packed::inverse(&last, primary, &alphabet[..alphabet_len])?;
    if inverse.route != "packed23" || inverse.plain.len() != raw {
        return Err("inverse route/length".into());
    }
    s.inverse_capacity = inverse.scratch_capacity_words * 4;
    s.output_capacity = inverse.result_capacity;
    let decode_bound = bytes.len()
        + s.forest_capacity
        + s.parse_transient
        + last.capacity() * 2
        + s.inverse_capacity
        + s.output_capacity
        + SCRATCH_BOUND
        + 1048576;
    gate(&mut s, decode_bound)?;
    let plain = inverse.plain;
    if crc32(&plain) != get32(bytes, 32)? as u32 {
        return Err("plain CRC".into());
    }
    Ok((plain, s))
}
