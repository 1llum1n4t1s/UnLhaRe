//! KHC の研究用 scalar codec。製品 API・永続保存用の形式ではない。

mod bt;
mod context;
mod frontier_dp;
mod hybrid;
mod lz;
mod prices;
pub(crate) mod profile;
mod range;
mod rans;
mod rep_frontier_dp;
mod row;
pub(crate) mod suffix_probe;
pub(crate) use lz::{
    BeamPlanRangeRecord, DistanceDeltaScreen, SegmentRewriteStats, SelectedCopy, SelectedMatch,
    SelectedToken,
};
#[cfg(test)]
mod reference_lz;

use crc_fast::{CrcAlgorithm, checksum};

pub const MAX_INPUT: usize = 64 * 1024 * 1024;
pub const HEADER: usize = 40;
const REVISION: u8 = 1;
const MAGIC: &[u8; 8] = b"KHC0LAB\0";
const HASH_SIZE: usize = 1 << 16;
const LITERALS: usize = 256 * 256;
const MAX_MATCH: usize = 1 << 16;
const NONE: u32 = u32::MAX;
const FIXED_MEMORY: usize = HASH_SIZE * 4 + LITERALS * 2 + 4096;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("compressed candidate exceeds stored size")]
    CandidateFull,
    #[error("experimental resource limit exceeded")]
    Limit,
    #[error("cancelled")]
    Cancelled,
    #[error("invalid experimental frame: {0}")]
    Format(&'static str),
}

pub(crate) const FSG_MAX_RECORDED_DROPS_PER_KIND: usize = 8;

#[derive(Debug)]
pub(crate) struct FsgPriceDrop {
    pub(crate) kind: &'static str,
    pub(crate) token_context: Option<usize>,
    pub(crate) length_context: Option<usize>,
    pub(crate) distance: Option<usize>,
    pub(crate) previous_symbol: usize,
    pub(crate) symbol: usize,
    pub(crate) previous_price: u64,
    pub(crate) price: u64,
}

#[derive(Debug)]
pub(crate) struct FsgPriceMonotonicityReport {
    pub(crate) input_bytes: usize,
    pub(crate) first_block_bytes: usize,
    pub(crate) candidate_positions: usize,
    pub(crate) candidate_edges: usize,
    pub(crate) reachable_distances: usize,
    pub(crate) maximum_match_length: usize,
    pub(crate) match_length_checks: usize,
    pub(crate) match_length_decreases: usize,
    pub(crate) distance_checks: usize,
    pub(crate) distance_decreases: usize,
    pub(crate) length_distance_boundary_checks: usize,
    pub(crate) length_distance_boundary_decreases: usize,
    pub(crate) first_decreases: Vec<FsgPriceDrop>,
}

#[derive(Clone, Copy)]
pub enum Algorithm {
    Standard,
    Lz,
    Beam,
    Context,
    Auto,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EntropyBackend {
    #[default]
    Range,
    Rans,
}

#[derive(Clone, Copy, Debug)]
pub enum BeamModel {
    Current,
    Warm,
    Blended,
}

#[derive(Clone, Copy, Debug)]
pub enum BeamMatches {
    Nearest,
    PricedTie,
    Bt4,
    Bt5,
    Exact4,
    Hybrid,
    R4,
    R5,
}

#[derive(Clone, Copy)]
pub struct Options {
    pub algorithm: Algorithm,
    pub entropy_backend: EntropyBackend,
    pub dictionary: usize,
    /// encoderだけの探索予算。復号形式やdecoderのメモリ量は変えない。
    pub beam_width: usize,
    pub beam_block: usize,
    pub beam_model: BeamModel,
    pub beam_matches: BeamMatches,
    /// 実験用。beam plan を固定した区間末で終端し、長いtokenによる境界移動を禁止する。
    pub beam_fixed_boundaries: bool,
    /// 実験用。開始stateを共有する連続blockの投機parse数。1 は通常の逐次parse。
    pub beam_batch_blocks: usize,
    /// 実験用。batch内の後続blockをgreedy予測stateからparseする。
    pub beam_greedy_seeds: bool,
    /// 実験用。W3の学習境界で、第3親をRep履歴の多様性と価格差で制限する。
    pub beam_rep_diverse_third_parent: bool,
    /// 実験用。greedy先行parseのRep履歴を価格近似だけに使う単一状態DP。
    pub beam_fixed_rep_history: bool,
    /// 実験用。直前履歴をliteral再学習してRange chunkを独立させる。
    pub beam_history_seeded: bool,
    /// 実験用。BT挿入を打ち切るnice length。0は従来、64だけを研究候補にする。
    pub bt_nice_len: usize,
    pub max_output: usize,
    /// 呼び出し元の入力と要求容量を含む予算。OS の RSS 上限ではない。
    pub memory_budget: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            algorithm: Algorithm::Lz,
            entropy_backend: EntropyBackend::Range,
            dictionary: 8 * 1024 * 1024,
            beam_width: 4,
            beam_block: 512,
            beam_model: BeamModel::Current,
            beam_matches: BeamMatches::Nearest,
            beam_fixed_boundaries: false,
            beam_batch_blocks: 1,
            beam_greedy_seeds: false,
            beam_rep_diverse_third_parent: false,
            beam_fixed_rep_history: false,
            beam_history_seeded: false,
            bt_nice_len: 0,
            max_output: MAX_INPUT,
            memory_budget: 1024 * 1024 * 1024,
        }
    }
}

fn encode_memory(length: usize, options: Options) -> Option<usize> {
    let standard = || length.checked_mul(8)?.checked_add(FIXED_MEMORY);
    let lz = || lz::encode_memory(length, options.dictionary);
    let beam = || lz::encode_beam_required_memory(length, options);
    let context = || {
        length
            .checked_mul(3)?
            .checked_add(context::memory_bytes() + HEADER + 4096)
    };
    match options.algorithm {
        Algorithm::Standard => standard(),
        Algorithm::Lz => lz(),
        Algorithm::Beam => beam(),
        Algorithm::Context => context(),
        // 候補は逐次評価するが、その間の最良payloadも生存している。
        Algorithm::Auto => standard()?
            .max(lz()?)
            .max(beam()?)
            .max(context()?)
            .checked_add(length),
    }
}

fn check(cancel: &mut impl FnMut() -> bool) -> Result<(), Error> {
    if cancel() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}

fn buffer<T: Clone>(length: usize, value: T) -> Result<Vec<T>, Error> {
    let mut data = Vec::new();
    data.try_reserve_exact(length).map_err(|_| Error::Limit)?;
    data.resize(length, value);
    Ok(data)
}

fn crc(data: &[u8]) -> u32 {
    checksum(CrcAlgorithm::Crc32IsoHdlc, data) as u32
}

/// Replay payloadから研究用frameを再構築する。payload長とheader CRCを更新する。
pub(crate) fn frame_with_payload(template: &[u8], payload: &[u8]) -> Result<Vec<u8>, Error> {
    if template.len() < HEADER || &template[..8] != MAGIC || !matches!(template[9], 2 | 4) {
        return Err(Error::Format("unsupported frame template"));
    }
    let packed = u64::try_from(payload.len()).map_err(|_| Error::Limit)?;
    let frame_len = HEADER.checked_add(payload.len()).ok_or(Error::Limit)?;
    let mut frame = buffer(frame_len, 0u8)?;
    frame[..HEADER].copy_from_slice(&template[..HEADER]);
    frame[24..32].copy_from_slice(&packed.to_le_bytes());
    let header_crc = crc(&frame[..36]);
    frame[36..40].copy_from_slice(&header_crc.to_le_bytes());
    frame[HEADER..].copy_from_slice(payload);
    Ok(frame)
}

/// Validated Beam token plan retained for exact parser-free coder timing.
pub(crate) struct PreparedBeamTokenReplay(lz::PreparedTokenReplay);

pub(crate) fn prepare_beam_token_replay(
    input: &[u8],
    tokens: &[SelectedToken],
) -> Result<PreparedBeamTokenReplay, Error> {
    if input.len() > MAX_INPUT {
        return Err(Error::Limit);
    }
    Ok(PreparedBeamTokenReplay(lz::prepare_token_replay(
        input.len(),
        tokens,
    )?))
}

pub(crate) fn replay_beam_token_frame(
    input: &[u8],
    template: &[u8],
    replay: &PreparedBeamTokenReplay,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    let payload = lz::emit_prepared_token_replay(input, &replay.0, None, cancel)?;
    let frame = frame_with_payload(template, &payload)?;
    check(cancel)?;
    Ok(frame)
}

fn model_update(probability: &mut u16, bit: bool) {
    if bit {
        *probability -= *probability >> 5;
    } else {
        *probability += (32768 - *probability) >> 5;
    }
}

struct Models {
    literal: Vec<u16>,
    kind: [u16; 2],
    repeat: u16,
    length: [u16; 64],
    distance: [u16; 64],
}

impl Models {
    fn new() -> Result<Self, Error> {
        Ok(Self {
            literal: buffer(LITERALS, 16384)?,
            kind: [16384; 2],
            repeat: 16384,
            length: [16384; 64],
            distance: [16384; 64],
        })
    }
}

fn put(coder: &mut range::Encoder, p: &mut u16, bit: bool) -> Result<(), Error> {
    coder.bit(*p, bit).map_err(|e| {
        if e == "range output limit" {
            Error::CandidateFull
        } else {
            Error::Format(e)
        }
    })?;
    model_update(p, bit);
    Ok(())
}

fn get(coder: &mut range::Decoder<'_>, p: &mut u16) -> Result<bool, Error> {
    let bit = coder.bit(*p).map_err(Error::Format)?;
    model_update(p, bit);
    Ok(bit)
}

fn put_tree(
    coder: &mut range::Encoder,
    model: &mut [u16],
    value: u32,
    bits: u32,
) -> Result<(), Error> {
    let mut node = 1;
    for shift in (0..bits).rev() {
        let bit = value & (1 << shift) != 0;
        put(coder, &mut model[node], bit)?;
        node = node * 2 + usize::from(bit);
    }
    Ok(())
}

fn get_tree(coder: &mut range::Decoder<'_>, model: &mut [u16], bits: u32) -> Result<u32, Error> {
    let mut node = 1;
    for _ in 0..bits {
        node = node * 2 + usize::from(get(coder, &mut model[node])?);
    }
    Ok((node - (1 << bits)) as u32)
}

fn put_number(
    coder: &mut range::Encoder,
    model: &mut [u16; 64],
    value: usize,
) -> Result<(), Error> {
    let slot = value.ilog2();
    put_tree(coder, &mut model[..32], slot, 5)?;
    for bit in (0..slot).rev() {
        put(
            coder,
            &mut model[32 + bit as usize],
            value & (1 << bit) != 0,
        )?;
    }
    Ok(())
}

fn get_number(
    coder: &mut range::Decoder<'_>,
    model: &mut [u16; 64],
    max: usize,
) -> Result<usize, Error> {
    let slot = get_tree(coder, &mut model[..32], 5)?;
    if slot > max.ilog2() {
        return Err(Error::Format("integer exceeds bound"));
    }
    let mut value = 1usize << slot;
    for bit in (0..slot).rev() {
        value |= usize::from(get(coder, &mut model[32 + bit as usize])?) << bit;
    }
    if value > max {
        return Err(Error::Format("integer exceeds bound"));
    }
    Ok(value)
}

fn hash(input: &[u8], pos: usize) -> usize {
    let key = u32::from(input[pos])
        | (u32::from(input[pos + 1]) << 8)
        | (u32::from(input[pos + 2]) << 16);
    (key.wrapping_mul(0x9e37_79b1) >> 16) as usize
}

struct Finder {
    heads: Vec<u32>,
    previous: Vec<u32>,
}

impl Finder {
    fn new(length: usize) -> Result<Self, Error> {
        Ok(Self {
            heads: buffer(HASH_SIZE, NONE)?,
            previous: buffer(length, NONE)?,
        })
    }

    fn insert(&mut self, input: &[u8], pos: usize) {
        if input.len() - pos >= 3 {
            let key = hash(input, pos);
            self.previous[pos] = self.heads[key];
            self.heads[key] = pos as u32;
        }
    }

    fn find(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(usize, usize), Error> {
        if input.len() - pos < 3 {
            return Ok((0, 0));
        }
        let mut candidate = self.heads[hash(input, pos)];
        let limit = MAX_MATCH.min(input.len() - pos);
        let mut best = (0, 0);
        let mut compared = 0;
        for _ in 0..256 {
            if candidate == NONE || pos - candidate as usize > dictionary {
                break;
            }
            let source = candidate as usize;
            let mut length = 0;
            while length < limit && compared < MAX_MATCH {
                if compared & 4095 == 0 {
                    check(cancel)?;
                }
                compared += 1;
                if input[source + length] != input[pos + length] {
                    break;
                }
                length += 1;
            }
            if length >= 3 && length > best.0 {
                best = (length, pos - source);
            }
            if length == limit || compared == MAX_MATCH {
                break;
            }
            candidate = self.previous[source];
        }
        Ok(best)
    }
}

fn compress(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    compress_with_token_trace::<false>(input, options, &mut Vec::new(), cancel)
}

fn compress_with_token_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    let mut selected = Vec::new();
    let payload = compress_with_token_trace::<true>(input, options, &mut selected, cancel)?;
    Ok((payload, selected))
}

fn compress_with_token_trace<const CAPTURE_TRACE: bool>(
    input: &[u8],
    options: Options,
    selected: &mut Vec<SelectedToken>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    let mut coder = range::Encoder::with_limit(input.len()).map_err(|_| Error::Limit)?;
    let mut model = Models::new()?;
    let mut finder = Finder::new(input.len())?;
    let mut pos = 0;
    let mut last_match = 0;
    let mut last_distance = 1;
    while pos < input.len() {
        check(cancel)?;
        let (length, distance) = finder.find(input, pos, options.dictionary, cancel)?;
        let is_match = length >= 3;
        put(&mut coder, &mut model.kind[last_match], is_match)?;
        if is_match {
            put(&mut coder, &mut model.repeat, distance == last_distance)?;
            if distance != last_distance {
                put_number(&mut coder, &mut model.distance, distance)?;
            }
            put_number(&mut coder, &mut model.length, length - 2)?;
            last_distance = distance;
        } else {
            let context = if pos == 0 { 0 } else { input[pos - 1] as usize };
            put_tree(
                &mut coder,
                &mut model.literal[context * 256..(context + 1) * 256],
                u32::from(input[pos]),
                8,
            )?;
        }
        let count = if is_match { length } else { 1 };
        if CAPTURE_TRACE {
            if selected.len() == lz::MAX_SELECTED_TOKEN_TRACE_ITEMS {
                return Err(Error::Limit);
            }
            selected.try_reserve(1).map_err(|_| Error::Limit)?;
            selected.push(SelectedToken {
                offset: u32::try_from(pos).map_err(|_| Error::Limit)?,
                length: u32::try_from(count).map_err(|_| Error::Limit)?,
                distance: if is_match {
                    u32::try_from(distance).map_err(|_| Error::Limit)?
                } else {
                    0
                },
                kind: if is_match { 3 } else { 0 },
                rep_index: 0,
            });
        }
        for offset in 0..count {
            if offset & 4095 == 0 {
                check(cancel)?;
            }
            finder.insert(input, pos + offset);
        }
        last_match = usize::from(is_match);
        pos += count;
    }
    coder.finish().map_err(|_| Error::CandidateFull)
}

fn check_trace_input(input: &[u8], options: Options) -> Result<(), Error> {
    let trace_bytes = input
        .len()
        .min(lz::MAX_SELECTED_TOKEN_TRACE_ITEMS)
        .checked_mul(std::mem::size_of::<SelectedToken>())
        .ok_or(Error::Limit)?;
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_INPUT
        || encode_memory(input.len(), options)
            .and_then(|required| required.checked_add(trace_bytes))
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }
    Ok(())
}

/// 実際のStandard parserが選んだtokenとrange payloadを記録するcensus経路。
pub(crate) fn trace_standard_tokens(
    input: &[u8],
    mut options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    options.algorithm = Algorithm::Standard;
    check_trace_input(input, options)?;
    check(cancel)?;
    compress_with_token_capture(input, options, cancel)
}

/// Standardの固定traceを変更せず、method-2のRep4 grammarと適応modelで再符号化するscreen。
pub(crate) fn reencode_standard_trace_as_method2(
    input: &[u8],
    options: Options,
    tokens: Vec<SelectedToken>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    if !matches!(options.algorithm, Algorithm::Standard)
        || input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_INPUT
    {
        return Err(Error::Format(
            "fixed-parse method-2 replay requires a valid Standard trace and dictionary",
        ));
    }
    lz::reencode_standard_trace_as_method2(
        input,
        options.dictionary,
        options.memory_budget,
        tokens,
        cancel,
    )
}

/// 実際のlazy LZ parserが選んだtokenとrange payloadを記録するcensus経路。
pub(crate) fn trace_lz_tokens(
    input: &[u8],
    mut options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    options.algorithm = Algorithm::Lz;
    check_trace_input(input, options)?;
    check(cancel)?;
    lz::encode_with_token_capture(input, options, cancel)
}

/// 指定済みbaseline設定のBT5 Beam parserが選んだtokenとpayloadを記録する経路。
pub(crate) fn trace_beam_tokens(
    input: &[u8],
    mut options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    options.algorithm = Algorithm::Beam;
    if !matches!(options.beam_matches, BeamMatches::Bt5) {
        return Err(Error::Format("parser census requires Beam with BT5"));
    }
    check_trace_input(input, options)?;
    check(cancel)?;
    lz::encode_beam_with_token_capture(input, options, cancel)
}

/// Mode 1の採取済みtokenを、同じkind/repeat文法で再生する。通常encodeは呼さない。
pub(crate) fn replay_standard_boundary_previews(
    input: &[u8],
    tokens: &[SelectedToken],
    boundary_ends: &[usize],
) -> Result<(Vec<u8>, Vec<usize>), Error> {
    if input.len() > MAX_INPUT {
        return Err(Error::Limit);
    }
    if boundary_ends.is_empty()
        || boundary_ends.windows(2).any(|pair| pair[0] >= pair[1])
        || boundary_ends.last().copied() != Some(input.len())
    {
        return Err(Error::Format(
            "boundary ends must increase and finish at the input length",
        ));
    }
    let mut coder = range::Encoder::with_limit(input.len()).map_err(|_| Error::Limit)?;
    let mut model = Models::new()?;
    let mut pos = 0usize;
    let mut last_match = 0usize;
    let mut last_distance = 1usize;
    let mut next_boundary = 0usize;
    let mut previews = Vec::new();
    previews
        .try_reserve_exact(boundary_ends.len())
        .map_err(|_| Error::Limit)?;
    for token in tokens {
        let start = usize::try_from(token.offset).map_err(|_| Error::Limit)?;
        let length = usize::try_from(token.length).map_err(|_| Error::Limit)?;
        if start != pos || length == 0 || start >= input.len() {
            return Err(Error::Format("standard boundary replay is not contiguous"));
        }
        let is_match = match token.kind {
            0 if length == 1 && token.distance == 0 => false,
            3 if length >= 3 => true,
            _ => return Err(Error::Format("standard boundary replay token kind")),
        };
        put(&mut coder, &mut model.kind[last_match], is_match)?;
        if is_match {
            let distance = usize::try_from(token.distance).map_err(|_| Error::Limit)?;
            put(&mut coder, &mut model.repeat, distance == last_distance)?;
            if distance != last_distance {
                put_number(&mut coder, &mut model.distance, distance)?;
            }
            put_number(&mut coder, &mut model.length, length - 2)?;
            last_distance = distance;
        } else {
            let context = if pos == 0 { 0 } else { input[pos - 1] as usize };
            put_tree(
                &mut coder,
                &mut model.literal[context * 256..(context + 1) * 256],
                u32::from(input[pos]),
                8,
            )?;
        }
        pos += length;
        last_match = usize::from(is_match);
        while next_boundary < boundary_ends.len() && boundary_ends[next_boundary] <= pos {
            previews.push(coder.finish_len_preview().ok_or(Error::Limit)?);
            next_boundary += 1;
        }
    }
    if pos != input.len() || next_boundary != boundary_ends.len() {
        return Err(Error::Format(
            "standard boundary replay did not cover the input",
        ));
    }
    let payload = coder.finish().map_err(|_| Error::CandidateFull)?;
    if previews.last().copied() != Some(payload.len()) {
        return Err(Error::Format(
            "standard boundary preview does not match the finished payload",
        ));
    }
    Ok((payload, previews))
}

/// 採取済みtokenをRangeで再生し、平文終端ごとの終端payload長を返す。通常encodeは呼さない。
pub(crate) fn replay_boundary_previews(
    input: &[u8],
    tokens: &[SelectedToken],
    boundary_ends: &[usize],
) -> Result<(Vec<u8>, Vec<usize>), Error> {
    lz::replay_boundary_previews(input, tokens, boundary_ends)
}

/// 通常Beam frameとのpayload一致を検証し、診断用に実plan境界のRange状態を記録する。
pub(crate) fn trace_beam_plan_ranges(
    input: &[u8],
    mut options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<BeamPlanRangeRecord>), Error> {
    options.algorithm = Algorithm::Beam;
    if options.entropy_backend != EntropyBackend::Range
        || options.beam_width != 2
        || options.beam_block != 8192
        || !matches!(options.beam_model, BeamModel::Blended)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err(Error::Format(
            "beam plan Range census requires current unbatched baseline settings",
        ));
    }

    let frame = encode(input, options, cancel)?;
    if frame.get(9) != Some(&2) {
        return Err(Error::Format("beam plan Range census used stored fallback"));
    }
    let mut census_options = options;
    census_options.memory_budget = options
        .memory_budget
        .checked_sub(frame.len())
        .ok_or(Error::Limit)?;
    let (payload, records) =
        lz::encode_beam_with_plan_range_capture(input, census_options, cancel)?;
    if frame.get(HEADER..) != Some(payload.as_slice()) {
        return Err(Error::Format(
            "beam plan Range census changed normal payload",
        ));
    }
    Ok((frame, records))
}

/// 単一バイト列の実験フレームを作る。ファイルシステムへの公開は行わない。
pub fn encode(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    let _profile = profile::Scope::new(profile::Phase::Encode);
    check(cancel)?;
    if options.bt_nice_len != 0
        && (!matches!(options.algorithm, Algorithm::Beam)
            || !matches!(options.beam_matches, BeamMatches::Bt5)
            || options.beam_batch_blocks != 1)
    {
        return Err(Error::Format(
            "BT nice length requires unbatched beam with BT5",
        ));
    }
    if options.beam_rep_diverse_third_parent
        && (!matches!(options.algorithm, Algorithm::Beam | Algorithm::Auto)
            || options.beam_width != 3
            || options.beam_block != 8192
            || !matches!(options.beam_model, BeamModel::Blended)
            || !matches!(options.beam_matches, BeamMatches::Bt5))
    {
        return Err(Error::Format(
            "rep-diverse third parent requires W3/BT5/Blended/B8192",
        ));
    }
    if options.beam_fixed_rep_history
        && (!matches!(options.algorithm, Algorithm::Beam)
            || options.beam_width != 2
            || options.beam_block != 8192
            || !matches!(options.beam_model, BeamModel::Blended)
            || !matches!(options.beam_matches, BeamMatches::Bt5)
            || options.beam_batch_blocks != 1
            || options.beam_greedy_seeds
            || options.beam_rep_diverse_third_parent)
    {
        return Err(Error::Format(
            "fixed Rep history requires beam W2/BT5/Blended/B8192 without batching",
        ));
    }
    if options.beam_history_seeded
        && (!matches!(options.algorithm, Algorithm::Beam)
            || options.entropy_backend != EntropyBackend::Range
            || options.beam_width != 2
            || options.beam_block != 8192
            || !matches!(options.beam_model, BeamModel::Blended)
            || !matches!(options.beam_matches, BeamMatches::Bt5)
            || options.beam_fixed_boundaries
            || options.beam_batch_blocks != 1
            || options.beam_greedy_seeds
            || options.beam_rep_diverse_third_parent
            || options.beam_fixed_rep_history
            || options.bt_nice_len != 0)
    {
        return Err(Error::Format(
            "history-seeded chunks require unbatched Beam/Range/Blended/W2/BT5/B8192 baseline settings",
        ));
    }
    if options.entropy_backend == EntropyBackend::Rans
        && (!matches!(options.algorithm, Algorithm::Beam)
            || options.beam_width != 2
            || options.beam_block != 8192
            || !matches!(options.beam_model, BeamModel::Blended)
            || !matches!(options.beam_matches, BeamMatches::Bt5)
            || options.beam_fixed_boundaries
            || options.beam_batch_blocks != 1
            || options.beam_greedy_seeds
            || options.beam_rep_diverse_third_parent
            || options.beam_fixed_rep_history
            || options.bt_nice_len != 0)
    {
        return Err(Error::Format(
            "rANS requires unbatched Beam/Blended/W2/BT5/B8192 baseline settings",
        ));
    }
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_INPUT
        || encode_memory(input.len(), options).is_none_or(|n| n > options.memory_budget)
    {
        return Err(Error::Limit);
    }
    // 出力サイズ上限に到達した圧縮候補だけを捨てる。キャンセルは成功へ変換しない。
    let algorithms: &[Algorithm] = match options.algorithm {
        Algorithm::Auto => &[
            Algorithm::Standard,
            Algorithm::Lz,
            Algorithm::Beam,
            Algorithm::Context,
        ],
        _ => std::slice::from_ref(&options.algorithm),
    };
    let mut compressed: Option<Vec<u8>> = None;
    let mut method = 0;
    for &algorithm in algorithms {
        check(cancel)?;
        let (mode, result) = match algorithm {
            Algorithm::Standard => (1, compress(input, options, cancel)),
            Algorithm::Lz => (2, lz::encode(input, options, cancel)),
            Algorithm::Beam if options.beam_history_seeded => {
                (4, lz::encode_history_seeded_chunks(input, options, cancel))
            }
            Algorithm::Beam => (2, lz::encode_beam(input, options, cancel)),
            Algorithm::Context => (3, context::encode(input, cancel)),
            Algorithm::Auto => unreachable!(),
        };
        match result {
            Ok(bytes)
                if options.beam_history_seeded
                    || bytes.len() < compressed.as_ref().map_or(input.len(), Vec::len) =>
            {
                compressed = Some(bytes);
                method = mode;
            }
            Ok(_) | Err(Error::CandidateFull) => {}
            Err(error) => return Err(error),
        }
    }
    check(cancel)?;
    let payload = compressed.as_deref().unwrap_or(input);
    let mut frame = buffer(HEADER + payload.len(), 0u8)?;
    frame[..8].copy_from_slice(MAGIC);
    frame[8] = REVISION;
    frame[9] = method;
    frame[12..16].copy_from_slice(&(options.dictionary as u32).to_le_bytes());
    frame[16..24].copy_from_slice(&(input.len() as u64).to_le_bytes());
    frame[24..32].copy_from_slice(&(payload.len() as u64).to_le_bytes());
    frame[32..36].copy_from_slice(&crc(input).to_le_bytes());
    let header_crc = crc(&frame[..36]);
    frame[36..40].copy_from_slice(&header_crc.to_le_bytes());
    for (source, dest) in payload.chunks(65536).zip(frame[HEADER..].chunks_mut(65536)) {
        check(cancel)?;
        dest.copy_from_slice(source);
    }
    check(cancel)?;
    Ok(frame)
}

/// 既存Beam stateを保ったまま固定区間だけlazy parseへ切り替える研究用入口。
pub(crate) fn encode_beam_lz_regions(
    input: &[u8],
    options: Options,
    regions: &[(usize, usize)],
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    lz::encode_beam_lz_regions(input, options, regions, cancel)
}

/// BT5 beamが選んだ通常Matchを記録する、開発用の診断入口。
pub(crate) fn trace_beam_matches(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<lz::SelectedMatch>), Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
    {
        return Err(Error::Format("match trace requires beam with BT5"));
    }
    lz::encode_beam_with_selected_match_capture(input, options, cancel)
}

/// Check the FSG increasing-cost premise using the exact first-block BT5/Blended prices.
/// The result is diagnostic only and does not alter encoding or build a parse graph.
pub(crate) fn screen_fsg_price_monotonicity(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<FsgPriceMonotonicityReport, Error> {
    check(cancel)?;
    lz::screen_fsg_price_monotonicity(input, options, cancel)
}

/// 同じBT5 token列で、適応更新を入力窓ごとに遅延したときのframeサイズを測る。
/// 返値は `(interval, HEADER込みframe bytes)`。parseは現行beamのままである。
pub(crate) fn screen_adapt_freeze(
    input: &[u8],
    options: Options,
    intervals: &[usize],
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<(usize, usize)>, Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
    {
        return Err(Error::Format("adapt freeze screen requires beam with BT5"));
    }
    lz::screen_adapt_freeze(input, options, intervals, cancel)
}

/// BT5 beamのcopy tokenを実距離へ解決し、Rep編集付きcopyの機会をscreenするtrace。
pub(crate) fn trace_beam_copies(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<lz::CopyCapture, Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
    {
        return Err(Error::Format("copy trace requires beam with BT5"));
    }
    lz::encode_beam_with_selected_copy_capture(input, options, cancel)
}

/// 選択済みBT5 token列をrep0差分距離文法で実range符号化し、候補decoderで照合する。
pub(crate) fn screen_distance_delta(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<DistanceDeltaScreen, Error> {
    check(cancel)?;
    lz::screen_distance_delta(input, options, cancel)
}

/// BT5 frontier上のLiteral／絶対距離CopyだけをDPした理想長screen。実frameは作らない。
pub(crate) fn screen_frontier_literal_copy_dp(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<frontier_dp::Estimate, Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.bt_nice_len != 0
        || options.beam_fixed_rep_history
        || options.beam_batch_blocks != 1
        || options.beam_fixed_boundaries
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
    {
        return Err(Error::Format(
            "frontier literal-copy DP screen requires plain BT5 options and nice length 0",
        ));
    }
    frontier_dp::screen(input, options.dictionary, options.beam_block, cancel)
}

/// BT5 frontier上のLiteral／絶対距離Copyを全合法prefix長でDPする理想長screen。
pub(crate) fn screen_frontier_literal_copy_all_lengths_dp(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<frontier_dp::AllLengthsEstimate, Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.bt_nice_len != 0
        || options.beam_fixed_rep_history
        || options.beam_batch_blocks != 1
        || options.beam_fixed_boundaries
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
    {
        return Err(Error::Format(
            "all-length frontier DP screen requires plain BT5 options and nice length 0",
        ));
    }
    frontier_dp::screen_all_lengths(input, options.dictionary, options.beam_block, cancel)
}

/// Repを運ぶBT5 frontier DPの理想長screen。実frameは作らない。
pub(crate) fn screen_rep_frontier_dp(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<rep_frontier_dp::Estimate, Error> {
    check(cancel)?;
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.bt_nice_len != 0
        || options.beam_fixed_rep_history
        || options.beam_batch_blocks != 1
        || options.beam_fixed_boundaries
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
    {
        return Err(Error::Format(
            "rep frontier DP screen requires plain BT5 options and nice length 0",
        ));
    }
    rep_frontier_dp::screen(input, options.dictionary, options.beam_block, cancel)
}

/// BT5 greedy tokenを一度だけ選び、固定field grammarのentropy下限screenへ渡すtrace。
pub(crate) fn trace_greedy_bt5_tokens(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<lz::SelectedToken>, Error> {
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.beam_width != 4
        || !matches!(options.beam_model, BeamModel::Current)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
    {
        return Err(Error::Format(
            "greedy static entropy screen requires plain BT5 beam options",
        ));
    }
    let trace_bytes = input
        .len()
        .checked_mul(std::mem::size_of::<lz::SelectedToken>())
        .and_then(|bytes| bytes.checked_mul(2))
        .ok_or(Error::Limit)?;
    if encode_memory(input.len(), options)
        .and_then(|required| required.checked_add(trace_bytes))
        .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }
    check(cancel)?;
    lz::trace_greedy_bt5_tokens(input, options, cancel)
}

/// 検証済みbaseline token traceを差分付きsame-distance copyへ再構成してサイズscreenする。
pub(crate) fn rewrite_beam_copy_segments(
    input: &[u8],
    options: Options,
    selected: &[SelectedToken],
    max_patch_bytes: usize,
) -> Result<(Vec<u8>, SegmentRewriteStats), Error> {
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
    {
        return Err(Error::Format("copy segment rewrite requires beam with BT5"));
    }
    lz::rewrite_selected_copy_segments(input, options.dictionary, selected, max_patch_bytes)
}

/// Experimental patched-copy token encoder/decoder is intentionally isolated from product frames.
pub(crate) fn encode_patched_copy_segments(
    input: &[u8],
    options: Options,
    selected: &[SelectedToken],
    max_patch_bytes: usize,
) -> Result<(Vec<u8>, SegmentRewriteStats), Error> {
    if !matches!(options.algorithm, Algorithm::Beam)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
    {
        return Err(Error::Format("patched-copy encoder requires beam with BT5"));
    }
    lz::encode_patched_copy_segments(input, options.dictionary, selected, max_patch_bytes)
}

pub(crate) fn decode_patched_copy_payload(
    payload: &[u8],
    size: usize,
    dictionary: usize,
) -> Result<Vec<u8>, Error> {
    lz::decode_patched_copy(payload, size, dictionary, &mut || false)
}

pub fn decode(
    frame: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    decode_impl::<false>(frame, options, cancel).map(|(output, _)| output)
}

pub(crate) fn decode_profile(
    frame: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, lz::DecodeProfile), Error> {
    let (output, profile) = decode_impl::<true>(frame, options, cancel)?;
    let profile = profile.ok_or(Error::Format("decode profiling requires mode 2"))?;
    Ok((output, profile))
}

fn decode_impl<const PROFILE: bool>(
    frame: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Option<lz::DecodeProfile>), Error> {
    check(cancel)?;
    if frame.len() < HEADER
        || &frame[..8] != MAGIC
        || (frame[8] != REVISION && !(frame[8] == 0 && frame[9] <= 1))
        || frame[9] > 4
        || frame[10..12] != [0, 0]
    {
        return Err(Error::Format("header"));
    }
    let u32_at = |at| u32::from_le_bytes(frame[at..at + 4].try_into().unwrap());
    let u64_at = |at| u64::from_le_bytes(frame[at..at + 8].try_into().unwrap());
    if crc(&frame[..36]) != u32_at(36) {
        return Err(Error::Format("header checksum"));
    }
    let dictionary = u32_at(12) as usize;
    let size = usize::try_from(u64_at(16)).map_err(|_| Error::Limit)?;
    let packed = usize::try_from(u64_at(24)).map_err(|_| Error::Limit)?;
    let decode_memory = match frame[9] {
        2 => lz::decode_memory(size),
        4 => lz::decode_memory(size)
            .and_then(|required| required.checked_add(packed.saturating_sub(size))),
        3 => frame
            .len()
            .checked_add(size)
            .and_then(|n| n.checked_add(context::memory_bytes() + 4096)),
        _ => frame
            .len()
            .checked_add(size)
            .and_then(|n| n.checked_add(FIXED_MEMORY)),
    };
    if size > MAX_INPUT
        || size > options.max_output
        || dictionary == 0
        || dictionary > MAX_INPUT
        || decode_memory.is_none_or(|n| n > options.memory_budget)
    {
        return Err(Error::Limit);
    }
    if (frame[9] != 4 && packed > size)
        || packed.checked_add(HEADER) != Some(frame.len())
        || (frame[9] == 0 && packed != size)
    {
        return Err(Error::Format("payload size"));
    }
    let (mut output, decode_profile) = match frame[9] {
        2 if options.entropy_backend == EntropyBackend::Rans && PROFILE => {
            let (output, profile) =
                lz::decode_rans_profile(&frame[HEADER..], size, dictionary, cancel)?;
            (output, Some(profile))
        }
        2 if options.entropy_backend == EntropyBackend::Rans => (
            lz::decode_rans(&frame[HEADER..], size, dictionary, cancel)?,
            None,
        ),
        2 if PROFILE => {
            let (output, profile) = lz::decode_profile(&frame[HEADER..], size, dictionary, cancel)?;
            (output, Some(profile))
        }
        2 => (
            lz::decode(&frame[HEADER..], size, dictionary, cancel)?,
            None,
        ),
        3 => (context::decode(&frame[HEADER..], size, cancel)?, None),
        4 => (
            lz::decode_history_seeded_chunks(&frame[HEADER..], size, dictionary, cancel)?,
            None,
        ),
        _ => (buffer(size, 0u8)?, None),
    };
    if frame[9] == 0 {
        for (source, dest) in frame[HEADER..].chunks(65536).zip(output.chunks_mut(65536)) {
            check(cancel)?;
            dest.copy_from_slice(source);
        }
    } else if frame[9] == 1 {
        let mut coder = range::Decoder::<false>::new(&frame[HEADER..]).map_err(Error::Format)?;
        let mut model = Models::new()?;
        let mut pos = 0;
        let mut last_match = 0;
        let mut last_distance = 1;
        while pos < size {
            check(cancel)?;
            let is_match = get(&mut coder, &mut model.kind[last_match])?;
            if is_match {
                let repeat = get(&mut coder, &mut model.repeat)?;
                let distance = if repeat {
                    last_distance
                } else {
                    get_number(&mut coder, &mut model.distance, dictionary)?
                };
                let length = get_number(&mut coder, &mut model.length, MAX_MATCH - 2)? + 2;
                if distance > pos || distance > dictionary || length > size - pos {
                    return Err(Error::Format("match outside history or output"));
                }
                for offset in 0..length {
                    if offset & 4095 == 0 {
                        check(cancel)?;
                    }
                    output[pos] = output[pos - distance];
                    pos += 1;
                }
                last_distance = distance;
            } else {
                let context = if pos == 0 {
                    0
                } else {
                    output[pos - 1] as usize
                };
                output[pos] = get_tree(
                    &mut coder,
                    &mut model.literal[context * 256..(context + 1) * 256],
                    8,
                )? as u8;
                pos += 1;
            }
            last_match = usize::from(is_match);
        }
        coder.finish().map_err(Error::Format)?;
    }
    check(cancel)?;
    if crc(&output) != u32_at(32) {
        return Err(Error::Format("content checksum"));
    }
    check(cancel)?;
    Ok((output, decode_profile))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(input: &[u8]) -> Vec<u8> {
        let options = Options::default();
        let packed = encode(input, options, &mut || false).unwrap();
        assert!(packed.len() <= HEADER + input.len());
        assert_eq!(decode(&packed, options, &mut || false).unwrap(), input);
        assert_eq!(encode(input, options, &mut || false).unwrap(), packed);
        packed
    }

    fn random(size: usize) -> Vec<u8> {
        let mut state = 0x12345678u32;
        (0..size)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect()
    }

    #[test]
    fn empty_short_and_stored_inputs() {
        for length in 0..32 {
            roundtrip(&random(length));
        }
        let frame = roundtrip(&random(32768));
        assert_eq!(frame[9], 0);
    }

    #[test]
    fn repeated_and_multibyte_inputs() {
        for input in [
            vec![0; 150000],
            b"abcabcabcabc".repeat(20000),
            "\u{65e5}\u{672c}\u{8a9e} KHC round trip\n"
                .repeat(8000)
                .into_bytes(),
        ] {
            assert_ne!(roundtrip(&input)[9], 0);
        }
    }

    #[test]
    fn long_distance_and_dictionary_boundary() {
        let mut input = random(32768);
        input.extend_from_within(..);
        for dictionary in [1, 3, 32767, 32768, MAX_INPUT] {
            let options = Options {
                dictionary,
                ..Options::default()
            };
            let packed = encode(&input, options, &mut || false).unwrap();
            assert_eq!(decode(&packed, options, &mut || false).unwrap(), input);
        }
    }

    #[test]
    fn content_corruption_and_frame_truncation_rejected() {
        let frame = roundtrip(&b"repeat data".repeat(100));
        for end in 0..frame.len() {
            assert!(decode(&frame[..end], Options::default(), &mut || false).is_err());
        }
        let mut changed = frame.clone();
        changed[32] ^= 1;
        let value = crc(&changed[..36]);
        changed[36..40].copy_from_slice(&value.to_le_bytes());
        assert_eq!(
            decode(&changed, Options::default(), &mut || false),
            Err(Error::Format("content checksum"))
        );
        let mut trailing = frame;
        trailing.push(0);
        assert!(decode(&trailing, Options::default(), &mut || false).is_err());
    }

    #[test]
    fn limits_are_checked_before_output_allocation() {
        let frame = roundtrip(&vec![42; 1024]);
        for options in [
            Options {
                max_output: 1023,
                ..Options::default()
            },
            Options {
                memory_budget: 1,
                ..Options::default()
            },
        ] {
            assert_eq!(decode(&frame, options, &mut || false), Err(Error::Limit));
        }
        for dictionary in [0, MAX_INPUT + 1] {
            assert_eq!(
                encode(
                    b"abc",
                    Options {
                        dictionary,
                        ..Options::default()
                    },
                    &mut || false
                ),
                Err(Error::Limit)
            );
        }
        assert_eq!(
            encode(
                b"abc",
                Options {
                    memory_budget: 1,
                    ..Options::default()
                },
                &mut || false
            ),
            Err(Error::Limit)
        );
    }

    #[test]
    fn cancellation_is_never_a_successful_fallback() {
        let input = vec![3; 200000];
        assert_eq!(
            encode(&input, Options::default(), &mut || true),
            Err(Error::Cancelled)
        );
        let mut calls = 0;
        assert_eq!(
            encode(&input, Options::default(), &mut || {
                calls += 1;
                calls == 12
            }),
            Err(Error::Cancelled)
        );
        let frame = roundtrip(&input);
        calls = 0;
        assert_eq!(
            decode(&frame, Options::default(), &mut || {
                calls += 1;
                calls == 12
            }),
            Err(Error::Cancelled)
        );
    }

    #[test]
    fn maximum_input_and_exact_budget_round_trip() {
        let input = vec![0; MAX_INPUT];
        let options = Options {
            algorithm: Algorithm::Standard,
            memory_budget: 8 * input.len() + FIXED_MEMORY,
            ..Options::default()
        };
        assert_eq!(
            encode(
                &input,
                Options {
                    memory_budget: options.memory_budget - 1,
                    ..options
                },
                &mut || false
            ),
            Err(Error::Limit)
        );
        let packed = encode(&input, options, &mut || false).unwrap();
        let decode_options = Options {
            memory_budget: packed.len() + input.len() + FIXED_MEMORY,
            ..options
        };
        assert_eq!(
            decode(&packed, decode_options, &mut || false).unwrap(),
            input
        );
        assert_eq!(
            decode(
                &packed,
                Options {
                    memory_budget: decode_options.memory_budget - 1,
                    ..decode_options
                },
                &mut || false
            ),
            Err(Error::Limit)
        );
        let too_large = vec![0; MAX_INPUT + 1];
        assert_eq!(
            encode(&too_large, options, &mut || false),
            Err(Error::Limit)
        );
    }

    #[test]
    fn advanced_modes_and_auto_select_actual_smallest_frame() {
        let input = "one sample, two samples, three samples\n日本語の文脈も完全復元する。\n"
            .repeat(600)
            .into_bytes();
        let mut lengths = Vec::new();
        for algorithm in [
            Algorithm::Standard,
            Algorithm::Lz,
            Algorithm::Beam,
            Algorithm::Context,
            Algorithm::Auto,
        ] {
            let options = Options {
                algorithm,
                ..Options::default()
            };
            let packed = encode(&input, options, &mut || false).unwrap();
            assert_eq!(decode(&packed, options, &mut || false).unwrap(), input);
            assert_eq!(encode(&input, options, &mut || false).unwrap(), packed);
            lengths.push(packed.len());
        }
        assert_eq!(lengths[4], *lengths[..4].iter().min().unwrap());
    }

    #[test]
    fn maximum_lz_input_and_beam_budget_round_trip() {
        let input = vec![b'x'; MAX_INPUT];
        for algorithm in [Algorithm::Lz, Algorithm::Beam] {
            let mut options = Options {
                algorithm,
                ..Options::default()
            };
            let required = encode_memory(input.len(), options).unwrap();
            options.memory_budget = required - 1;
            assert_eq!(encode(&input, options, &mut || false), Err(Error::Limit));
            options.memory_budget = required;
            let packed = encode(&input, options, &mut || false).unwrap();
            assert_eq!(packed[9], 2);
            let decode_required = lz::decode_memory(input.len()).unwrap();
            options.memory_budget = decode_required - 1;
            assert_eq!(decode(&packed, options, &mut || false), Err(Error::Limit));
            options.memory_budget = decode_required;
            assert_eq!(decode(&packed, options, &mut || false).unwrap(), input);
        }
    }

    #[test]
    fn beam_settings_are_encoder_only_and_checked_before_allocation() {
        let input = b"profile boundaries; shared mode-two decoder;\n".repeat(64);
        for (width, block) in [
            (1, 64),
            (3, 512),
            (4, 512),
            (16, 1024),
            (2, 2048),
            (2, 4096),
        ] {
            let options = Options {
                algorithm: Algorithm::Beam,
                beam_width: width,
                beam_block: block,
                ..Options::default()
            };
            let required = encode_memory(input.len(), options).unwrap();
            assert_eq!(
                encode(
                    &input,
                    Options {
                        memory_budget: required - 1,
                        ..options
                    },
                    &mut || false
                ),
                Err(Error::Limit)
            );
            let packed = encode(
                &input,
                Options {
                    memory_budget: required,
                    ..options
                },
                &mut || false,
            )
            .unwrap();
            assert_eq!(packed[9], 2);
            assert_eq!(
                reference_lz::decode(&packed[HEADER..], input.len(), options.dictionary).unwrap(),
                input
            );
            assert_eq!(
                decode(
                    &packed,
                    Options {
                        beam_width: 0,
                        beam_block: 0,
                        ..Options::default()
                    },
                    &mut || false
                )
                .unwrap(),
                input
            );
        }
        for algorithm in [Algorithm::Beam, Algorithm::Auto] {
            for (width, block) in [
                (0, 512),
                (5, 512),
                (32, 512),
                (4, 0),
                (4, 63),
                (4, 65),
                (4, 16384),
                (usize::MAX, usize::MAX),
            ] {
                assert_eq!(
                    encode(
                        &input,
                        Options {
                            algorithm,
                            beam_width: width,
                            beam_block: block,
                            ..Options::default()
                        },
                        &mut || false
                    ),
                    Err(Error::Limit)
                );
            }
        }
        // 使わない探索設定を無関係なcodecの拒否理由にしない。
        for algorithm in [Algorithm::Standard, Algorithm::Lz, Algorithm::Context] {
            let options = Options {
                algorithm,
                beam_width: 0,
                beam_block: 0,
                ..Options::default()
            };
            let packed = encode(&input, options, &mut || false).unwrap();
            assert_eq!(decode(&packed, options, &mut || false).unwrap(), input);
        }
    }

    #[test]
    fn beam_models_and_matches_keep_the_existing_wire_and_enforce_their_budget() {
        let mut input = Vec::new();
        for index in 0..256u32 {
            input.extend_from_slice(b"first repeated context / second repeated context / ");
            input.extend_from_slice(&index.to_le_bytes());
            input.push((index.wrapping_mul(13) % 251) as u8);
        }
        for (model, matches) in [BeamModel::Current, BeamModel::Warm, BeamModel::Blended]
            .into_iter()
            .flat_map(|model| {
                [
                    BeamMatches::Nearest,
                    BeamMatches::PricedTie,
                    BeamMatches::Bt4,
                    BeamMatches::Bt5,
                    BeamMatches::Exact4,
                    BeamMatches::Hybrid,
                    BeamMatches::R4,
                    BeamMatches::R5,
                ]
                .map(|matches| (model, matches))
            })
        {
            let options = Options {
                algorithm: Algorithm::Beam,
                beam_model: model,
                beam_matches: matches,
                ..Options::default()
            };
            let required = encode_memory(input.len(), options).unwrap();
            assert_eq!(
                encode(
                    &input,
                    Options {
                        memory_budget: required - 1,
                        ..options
                    },
                    &mut || false
                ),
                Err(Error::Limit)
            );
            let options = Options {
                memory_budget: required,
                ..options
            };
            let frame = encode(&input, options, &mut || false).unwrap();
            assert_eq!(frame[9], 2);
            assert_eq!(encode(&input, options, &mut || false).unwrap(), frame);
            assert_eq!(
                decode(&frame, Options::default(), &mut || false).unwrap(),
                input
            );
            assert_eq!(
                reference_lz::decode(&frame[HEADER..], input.len(), options.dictionary).unwrap(),
                input
            );
            let mut callbacks = 0;
            assert_eq!(
                encode(&input, options, &mut || {
                    callbacks += 1;
                    callbacks >= 7
                }),
                Err(Error::Cancelled)
            );
        }
    }

    #[test]
    fn hybrid_beam_is_deterministic_round_trips_and_checks_budget_before_indexes() {
        let mut input = random(96 * 1024);
        let repeated = b"hybrid near ring deterministic round trip / ".repeat(512);
        input[4096..4096 + repeated.len()].copy_from_slice(&repeated);
        input[64 * 1024..64 * 1024 + repeated.len()].copy_from_slice(&repeated);
        let options = Options {
            algorithm: Algorithm::Beam,
            dictionary: 8 * 1024 * 1024,
            beam_width: 2,
            beam_block: 512,
            beam_model: BeamModel::Blended,
            beam_matches: BeamMatches::Hybrid,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        let required = encode_memory(input.len(), options).unwrap();
        assert_eq!(
            encode(
                &input,
                Options {
                    memory_budget: required - 1,
                    ..options
                },
                &mut || false,
            ),
            Err(Error::Limit)
        );
        let exact = Options {
            memory_budget: required,
            ..options
        };
        let first = encode(&input, exact, &mut || false).unwrap();
        let second = encode(&input, exact, &mut || false).unwrap();
        assert_eq!(first, second);
        let bt5 = Options {
            beam_matches: BeamMatches::Bt5,
            ..exact
        };
        assert_eq!(
            encode_memory(input.len(), exact),
            encode_memory(input.len(), bt5)
        );
        assert_eq!(first, encode(&input, bt5, &mut || false).unwrap());
        assert_eq!(decode(&first, exact, &mut || false).unwrap(), input);
    }

    #[test]
    fn hybrid_beam_round_trips_a_far_match_through_the_codec() {
        let source = 128 * 1024;
        let target = 4 * 1024 * 1024 + 256 * 1024;
        let length = 4096;
        let mut input = vec![0u8; target + length + 8192];
        let pattern = random(length);
        input[source..source + length].copy_from_slice(&pattern);
        input[target..target + length].copy_from_slice(&pattern);
        let options = Options {
            algorithm: Algorithm::Beam,
            dictionary: 8 * 1024 * 1024,
            beam_width: 1,
            beam_block: 8192,
            beam_model: BeamModel::Blended,
            beam_matches: BeamMatches::Hybrid,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        let frame = encode(&input, options, &mut || false).unwrap();
        assert_eq!(frame[9], 2);
        assert!(frame.len() < input.len());
        let mut no_far_copy = input.clone();
        for (value, source) in no_far_copy[target..target + length]
            .iter_mut()
            .zip(&pattern)
        {
            *value = !*source;
        }
        let no_far_frame = encode(&no_far_copy, options, &mut || false).unwrap();
        assert_eq!(no_far_frame[9], 2);
        assert!(frame.len() < no_far_frame.len());
        assert_eq!(decode(&frame, options, &mut || false).unwrap(), input);
        assert_eq!(
            reference_lz::decode(&frame[HEADER..], input.len(), options.dictionary).unwrap(),
            input
        );
    }

    #[test]
    fn hybrid_uses_bt5_when_dictionary_cannot_reach_the_far_window() {
        let input = vec![0u8; hybrid::NEAR_WINDOW + 8192];
        let options = Options {
            algorithm: Algorithm::Beam,
            dictionary: hybrid::NEAR_WINDOW,
            beam_width: 1,
            beam_block: 8192,
            beam_model: BeamModel::Blended,
            beam_matches: BeamMatches::Hybrid,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        let bt5 = Options {
            beam_matches: BeamMatches::Bt5,
            ..options
        };
        assert_eq!(
            encode_memory(input.len(), options),
            encode_memory(input.len(), bt5)
        );
        assert_eq!(
            encode(&input, options, &mut || false).unwrap(),
            encode(&input, bt5, &mut || false).unwrap()
        );
    }

    #[test]
    fn mode_specific_budgets_and_revision_are_validated() {
        let input = b"resource boundary test input\n".repeat(128);
        for algorithm in [
            Algorithm::Standard,
            Algorithm::Lz,
            Algorithm::Beam,
            Algorithm::Context,
            Algorithm::Auto,
        ] {
            let mut options = Options {
                algorithm,
                ..Options::default()
            };
            let required = encode_memory(input.len(), options).unwrap();
            options.memory_budget = required - 1;
            assert_eq!(encode(&input, options, &mut || false), Err(Error::Limit));
            options.memory_budget = required;
            let mut frame = encode(&input, options, &mut || false).unwrap();
            assert_eq!(frame[8], REVISION);
            assert_eq!(
                decode(&frame, Options::default(), &mut || false).unwrap(),
                input
            );
            frame[8] = 255;
            assert!(decode(&frame, Options::default(), &mut || false).is_err());
        }
        // 初版で作ったstored/greedy frameだけは復号可能。途中のmode2/3試作は対象外。
        let mut old = encode(
            &input,
            Options {
                algorithm: Algorithm::Standard,
                ..Options::default()
            },
            &mut || false,
        )
        .unwrap();
        old[8] = 0;
        let value = crc(&old[..36]);
        old[36..40].copy_from_slice(&value.to_le_bytes());
        assert_eq!(
            decode(&old, Options::default(), &mut || false).unwrap(),
            input
        );
    }

    #[test]
    fn rep_diverse_third_parent_requires_its_bounded_w3_parser() {
        let input = b"rep-diverse parent validation\n".repeat(8);
        let invalid = Options {
            algorithm: Algorithm::Beam,
            beam_width: 2,
            beam_rep_diverse_third_parent: true,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        assert!(matches!(
            encode(&input, invalid, &mut || false),
            Err(Error::Format(_))
        ));

        let valid = Options {
            algorithm: Algorithm::Beam,
            beam_width: 3,
            beam_block: 8192,
            beam_model: BeamModel::Blended,
            beam_matches: BeamMatches::Bt5,
            beam_rep_diverse_third_parent: true,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        let frame = encode(&input, valid, &mut || false).unwrap();
        assert_eq!(decode(&frame, valid, &mut || false).unwrap(), input);
    }

    #[test]
    fn nice_length_is_rejected_before_non_bt5_encoders_can_ignore_it() {
        let input = b"nice length validation\n".repeat(8);
        for invalid in [
            Options {
                bt_nice_len: 64,
                ..Options::default()
            },
            Options {
                algorithm: Algorithm::Beam,
                beam_matches: BeamMatches::Nearest,
                bt_nice_len: 64,
                memory_budget: usize::MAX,
                ..Options::default()
            },
            Options {
                algorithm: Algorithm::Auto,
                beam_matches: BeamMatches::Bt5,
                bt_nice_len: 64,
                memory_budget: usize::MAX,
                ..Options::default()
            },
            Options {
                algorithm: Algorithm::Beam,
                beam_matches: BeamMatches::Bt5,
                beam_batch_blocks: 2,
                bt_nice_len: 64,
                memory_budget: usize::MAX,
                ..Options::default()
            },
        ] {
            assert_eq!(
                encode(&input, invalid, &mut || false),
                Err(Error::Format(
                    "BT nice length requires unbatched beam with BT5",
                ))
            );
        }
    }

    #[test]
    fn fixed_rep_history_reconcretizes_against_the_emitted_state() {
        let input = b"abcabcabdabcabcabe fixed history\n".repeat(64);
        let options = Options {
            algorithm: Algorithm::Beam,
            dictionary: 64 * 1024,
            beam_width: 2,
            beam_block: 8192,
            beam_model: BeamModel::Blended,
            beam_matches: BeamMatches::Bt5,
            beam_fixed_rep_history: true,
            memory_budget: usize::MAX,
            ..Options::default()
        };
        let frame = encode(&input, options, &mut || false).unwrap();
        assert_eq!(decode(&frame, options, &mut || false).unwrap(), input);
        assert_eq!(encode(&input, options, &mut || false).unwrap(), frame);
    }

    #[test]
    fn mode_two_matches_independent_specification_decoder() {
        let mut distant = random(32768);
        distant.extend_from_within(..);
        let mut changing = Vec::new();
        for index in 0..256u32 {
            changing.extend_from_slice(&index.to_le_bytes());
            changing.extend_from_slice(b"one-shared-prefix/second-shared-prefix/");
            changing.push((index.wrapping_mul(17) % 251) as u8);
        }
        let samples = [
            vec![0; 70000],
            (0..=255u8).cycle().take(8192).collect(),
            "日本語の文脈 / repeated context\n".repeat(128).into_bytes(),
            distant,
            changing,
        ];
        let mut checked = 0;
        for algorithm in [Algorithm::Lz, Algorithm::Beam] {
            for input in &samples {
                for dictionary in [1, 31, 256, 32768, MAX_INPUT] {
                    let options = Options {
                        algorithm,
                        dictionary,
                        ..Options::default()
                    };
                    let frame = encode(input, options, &mut || false).unwrap();
                    if frame[9] == 0 {
                        continue;
                    }
                    assert_eq!(frame[9], 2);
                    let payload = &frame[HEADER..];
                    assert_eq!(
                        reference_lz::decode(payload, input.len(), dictionary).unwrap(),
                        *input
                    );
                    checked += 1;
                }
            }
        }
        assert!(
            checked >= 20,
            "stored fallback must not bypass decoder coverage"
        );
    }

    #[test]
    fn mode_two_decoders_agree_on_bounded_payload_mutations() {
        let input = b"same state, distinct independent implementation\n".repeat(128);
        let frame = encode(&input, Options::default(), &mut || false).unwrap();
        assert_eq!(frame[9], 2);
        let payload = &frame[HEADER..];
        let dictionary = Options::default().dictionary;
        let compare = |bytes: &[u8]| {
            let actual = lz::decode(bytes, input.len(), dictionary, &mut || false);
            let reference = reference_lz::decode(bytes, input.len(), dictionary);
            match (actual, reference) {
                (Ok(left), Ok(right)) => assert_eq!(left, right),
                (Err(_), Err(_)) => {}
                _ => panic!("decoder acceptance differed"),
            }
        };
        for end in 0..payload.len() {
            compare(&payload[..end]);
        }
        for at in 0..payload.len() {
            let mut changed = payload.to_vec();
            changed[at] ^= 1 << (at % 8);
            compare(&changed);
        }
        let mut trailing = payload.to_vec();
        trailing.push(0);
        compare(&trailing);
    }
}
