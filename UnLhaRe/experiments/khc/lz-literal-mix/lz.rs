//! KHC mode 2 用の LZ/range 実験器。
//!
//! このモジュールはフレームではなく range payload だけを扱う。encoder の出力上限は
//! 常に元入力長であり、上限へ達した場合だけ [`Error::CandidateFull`] を返す。呼び出し元は
//! その場合に stored を選べる。割当失敗・資源上限・キャンセルを stored へ読み替えない。
//!
//! token は `is_match` から始まる。literal は rep0 が復元済み範囲を指す場合、その位置の
//! byte を予測値に使う。直前 byte 上位3bitの8文脈ごとに、通常の完全binary tree 256要素と
//! 予測bit別のtree 256要素×2を持つ。復元済みprefixが予測と一致している間だけ予測treeを
//! 使い、最初の不一致後は通常treeへ戻る。match は通常距離または直近4距離の rep で、
//! rep0 だけは1 byteのshort-repを持つ。repの通常長は2以上、通常距離matchは3以上である。
//! rep1..3 を使うと選んだ距離を先頭へ移し、通常距離は先頭へ追加する。
//!
//! 長さは `0..7`、`8..15`、それ以上の3帯を token状態×出力位置mod 4 の文脈で符号化する。
//! 高位帯は floor(log2) と残りbitからなる number を同じ文脈で符号化する。通常距離も
//! number とし、その slot tree と下位bitはmatch長の4帯を文脈にする。整数・treeのbitは
//! MSBから送る。全確率は15bitの0確率、初期値16384、更新率1/32である。
//!
//! matchfinder は4 byte hashの全位置について直前位置をu32で保持する。各探索は最大256
//! chain、合計65536 logical byte比較、match長65536に制限する。実比較は範囲内のimmutable
//! sliceを最大8 byte先読みするが、予算・候補・callbackはscalarのlogical比較単位を維持する。
//! 近距離から見て長さが更新された
//! Pareto候補を保持する。parser は各候補とrep0..3について、同じ適応modelから見積もった
//! token価格を、その区間をliteralにした価格と比較する。さらに1 byte先の最大差益が現在の
//! matchを上回ればliteralを1つ出す有限先読みを行うため、単純な最長一致greedyではない。

use super::{
    BeamMatches, BeamModel, Error, HEADER, MAX_INPUT, Options, bt, buffer, check, hybrid,
    profile::{Phase, Scope},
    range, row,
};

const HASH_BITS: usize = 20;
const HASH_SIZE: usize = 1 << HASH_BITS;
const NONE: u32 = u32::MAX;
const MAX_CHAIN: usize = 256;
const MAX_COMPARE: usize = 1 << 16;
const MAX_MATCH: usize = 1 << 16;
const MAX_DISTANCE_DELTA: usize = 16;
const SEGMENT_MIN_SPAN: usize = 256;
const SEGMENT_MAX_SPAN: usize = 1 << 16;
const SEGMENT_MAX_GAP_COMPARE_BYTES: usize = 64 * 1024 * 1024;
pub(super) const MAX_SELECTED_TOKEN_TRACE_ITEMS: usize = 1 << 22;
const MAX_DICTIONARY: usize = MAX_INPUT;
const FRONTIER: usize = 24;
const LITERAL_STRIDE: usize = 3 * 256;
const LITERAL_CONTEXTS: usize = 8 * LITERAL_STRIDE;
const TOKEN_CONTEXTS: usize = 2 * 4;
const LENGTH_CONTEXTS: usize = TOKEN_CONTEXTS;
const DISTANCE_CONTEXTS: usize = 4;
const NUMBER_MODELS: usize = 64;
#[cfg(not(khc_literal_mix))]
const MODEL_MEMORY: usize = 128 * 1024;
#[cfg(khc_literal_mix)]
const MODEL_MEMORY: usize = 128 * 1024 + 524288;
#[cfg(khc_literal_mix)]
const LITERAL_ORDER2_ENTRIES: usize = 512 * 256;
const FIXED_MEMORY: usize = 64 * 1024;
const BEAM_FIXED_WORKING_MEMORY: usize = 5 * 1024;
const MAX_BEAM_WIDTH: usize = 16;
const MAX_BEAM_BLOCK: usize = 8192;
const MAX_BEAM_PARENT_INDEX: usize = (MAX_BEAM_BLOCK + 1) * MAX_BEAM_WIDTH - 1;
const HISTORY_SEEDED_CHUNK: usize = 512 * 1024;
const HISTORY_SEED_BYTES: usize = 64 * 1024;
const LONG_MATCH_SHORTCUT: usize = 128;
const COMPARE_CHUNK: usize = 8;
const WIDE_COMPARE_CHUNK: usize = 32;

const _: () = assert!(usize::BITS >= 32);
const _: () = assert!(MAX_INPUT <= u32::MAX as usize);
const _: () = assert!(MAX_DICTIONARY <= u32::MAX as usize);
const _: () = assert!(MAX_MATCH <= u32::MAX as usize);
const _: () = assert!(MAX_MATCH - 1 <= u16::MAX as usize);
// u32::MAXはroot sentinel専用なので、最大の実parent indexは必ずその手前に置く。
const _: () = assert!(MAX_BEAM_PARENT_INDEX < u32::MAX as usize);

fn valid_beam_width(width: usize) -> bool {
    width <= MAX_BEAM_WIDTH && matches!(width, 1 | 2 | 3 | 4 | 8 | 16)
}

fn valid_beam_block(block: usize) -> bool {
    block <= MAX_BEAM_BLOCK && matches!(block, 64 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 8192)
}

#[inline(always)]
fn load_u64_le(bytes: &[u8]) -> u64 {
    debug_assert!(bytes.len() >= COMPARE_CHUNK);
    // 呼び出し側は入力範囲を確認済み。非アライン入力でもWindows x64を含む
    // 対応targetで安全に読み、little-endianへ正規化する。
    u64::from_le(unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<u64>()) })
}

/// 8 byteをlittle-endian整数として比較し、先頭から一致するbyte数を返す。
#[inline(always)]
fn matching_prefix8(left: &[u8], right: &[u8]) -> usize {
    debug_assert!(left.len() >= COMPARE_CHUNK && right.len() >= COMPARE_CHUNK);
    let left = load_u64_le(left);
    let right = load_u64_le(right);
    let difference = left ^ right;
    if difference == 0 {
        COMPARE_CHUNK
    } else {
        (difference.trailing_zeros() / 8) as usize
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn matching_prefix32_avx2(left: &[u8], right: &[u8]) -> usize {
    use std::arch::x86_64::{__m256i, _mm256_cmpeq_epi8, _mm256_loadu_si256, _mm256_movemask_epi8};

    debug_assert!(left.len() >= WIDE_COMPARE_CHUNK && right.len() >= WIDE_COMPARE_CHUNK);
    let left = unsafe { _mm256_loadu_si256(left.as_ptr().cast::<__m256i>()) };
    let right = unsafe { _mm256_loadu_si256(right.as_ptr().cast::<__m256i>()) };
    let equal = _mm256_cmpeq_epi8(left, right);
    let mask = _mm256_movemask_epi8(equal) as u32;
    ((!mask).trailing_zeros() as usize).min(WIDE_COMPARE_CHUNK)
}

#[inline(always)]
fn matching_prefix32_portable(left: &[u8], right: &[u8]) -> usize {
    debug_assert!(left.len() >= WIDE_COMPARE_CHUNK && right.len() >= WIDE_COMPARE_CHUNK);
    for offset in (0..WIDE_COMPARE_CHUNK).step_by(COMPARE_CHUNK) {
        let prefix = matching_prefix8(&left[offset..], &right[offset..]);
        if prefix != COMPARE_CHUNK {
            return offset + prefix;
        }
    }
    WIDE_COMPARE_CHUNK
}

#[inline(always)]
fn matching_prefix32(left: &[u8], right: &[u8]) -> usize {
    #[cfg(target_arch = "x86_64")]
    if std::arch::is_x86_feature_detected!("avx2") {
        return unsafe { matching_prefix32_avx2(left, right) };
    }
    matching_prefix32_portable(left, right)
}

fn finder_match_length(
    input: &[u8],
    source: usize,
    pos: usize,
    limit: usize,
    compared: &mut usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    let mut length = 0usize;
    while length < limit && *compared < MAX_COMPARE {
        let remaining = limit - length;
        let budget = MAX_COMPARE - *compared;
        if remaining >= WIDE_COMPARE_CHUNK
            && budget >= WIDE_COMPARE_CHUNK
            && (*compared & 0xfff) <= 0xfff - WIDE_COMPARE_CHUNK
        {
            let left = &input[source + length..source + length + WIDE_COMPARE_CHUNK];
            let right = &input[pos + length..pos + length + WIDE_COMPARE_CHUNK];
            let prefix = matching_prefix32(left, right);
            if prefix == WIDE_COMPARE_CHUNK {
                length += WIDE_COMPARE_CHUNK;
                *compared += WIDE_COMPARE_CHUNK;
                continue;
            }
            *compared += prefix + 1;
            return Ok(length + prefix);
        }
        // 次の4096比較境界を跨がない範囲だけまとめる。境界byteは従来どおり
        // scalar経路でcallback後に比較し、キャンセル位置を変えない。
        if remaining >= COMPARE_CHUNK
            && budget >= COMPARE_CHUNK
            && (*compared & 0xfff) <= 0xfff - COMPARE_CHUNK
        {
            let left = &input[source + length..source + length + COMPARE_CHUNK];
            let right = &input[pos + length..pos + length + COMPARE_CHUNK];
            let prefix = matching_prefix8(left, right);
            if prefix == COMPARE_CHUNK {
                length += COMPARE_CHUNK;
                *compared += COMPARE_CHUNK;
                continue;
            }
            *compared += prefix + 1;
            return Ok(length + prefix);
        }

        *compared += 1;
        if *compared & 0xfff == 0 {
            check(cancel)?;
        }
        if input[source + length] != input[pos + length] {
            break;
        }
        length += 1;
    }
    Ok(length)
}

fn repetition_match_length(
    input: &[u8],
    source: usize,
    pos: usize,
    limit: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    let mut length = 0usize;
    while length < limit {
        let remaining = limit - length;
        if remaining >= WIDE_COMPARE_CHUNK && (length & 0xfff) <= 0xfff - WIDE_COMPARE_CHUNK {
            let left = &input[source + length..source + length + WIDE_COMPARE_CHUNK];
            let right = &input[pos + length..pos + length + WIDE_COMPARE_CHUNK];
            let prefix = matching_prefix32(left, right);
            let residue = length & 0xfff;
            let boundary = if residue == 0 { 0 } else { 0x1000 - residue };
            // 4096境界を跨がないwide chunkは、先頭が境界なら従来どおり
            // 比較後にcallbackする。相違がchunk内にあればscalarと同じ位置で返す。
            if boundary < prefix {
                check(cancel)?;
            }
            if prefix == WIDE_COMPARE_CHUNK {
                length += WIDE_COMPARE_CHUNK;
                continue;
            }
            return Ok(length + prefix);
        }
        if remaining >= COMPARE_CHUNK {
            let left = &input[source + length..source + length + COMPARE_CHUNK];
            let right = &input[pos + length..pos + length + COMPARE_CHUNK];
            let prefix = matching_prefix8(left, right);
            let residue = length & 0xfff;
            let boundary = if residue == 0 { 0 } else { 0x1000 - residue };
            // scalar経路は不一致判定の後にcallbackする。したがって一致prefix内に
            // 境界byteがある場合だけcheckし、先頭不一致では呼ばない。
            if boundary < prefix {
                check(cancel)?;
            }
            if prefix == COMPARE_CHUNK {
                length += COMPARE_CHUNK;
                continue;
            }
            return Ok(length + prefix);
        }

        if input[source + length] != input[pos + length] {
            break;
        }
        if length & 0xfff == 0 {
            check(cancel)?;
        }
        length += 1;
    }
    Ok(length)
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Match {
    length: usize,
    distance: usize,
}

struct Matches {
    values: [Match; FRONTIER],
    length: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SelectedMatch {
    pub(crate) offset: usize,
    pub(crate) length: usize,
    pub(crate) distance: usize,
}

/// Beam parseが実際に選んだcopy tokenを、Rep解決後の距離で記録するscreen用trace。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SelectedCopy {
    pub(crate) offset: u32,
    pub(crate) length: u32,
    pub(crate) distance: u32,
    /// 1=normal match、2=rep、3=short-rep。
    pub(crate) kind: u8,
}

/// Beam parseが選んだ全token。kindは0=literal、1=short-rep、2=rep、3=normal match。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SelectedToken {
    pub(crate) offset: u32,
    pub(crate) length: u32,
    /// Literalでは0。copy tokenではRep解決後の実距離。
    pub(crate) distance: u32,
    pub(crate) kind: u8,
    /// kind=2の場合の元Rep index。それ以外では0。
    pub(crate) rep_index: u8,
}

/// Beamの実plan境界で観測したRange状態。prefix値は境界で終端した累積長で、
/// 独立block長やplanごとの加算costではない。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct BeamPlanRangeRecord {
    pub(crate) plain_start: usize,
    pub(crate) plain_bytes: usize,
    pub(crate) emitted_bytes_total: usize,
    pub(crate) emitted_bytes_since_previous_plan: usize,
    pub(crate) pending_bytes: usize,
    pub(crate) prefix_payload_bytes_if_terminated: usize,
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct DistanceDeltaScreen {
    pub(crate) baseline_frame_bytes: usize,
    pub(crate) candidate_frame_bytes: usize,
    pub(crate) token_count: usize,
    pub(crate) normal_match_events: usize,
    pub(crate) delta_events: usize,
    pub(crate) absolute_escape_events: usize,
    pub(crate) round_trip_verified: bool,
    pub(crate) deterministic: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct SegmentRewriteStats {
    pub(crate) eligible_candidates: usize,
    pub(crate) covered_bytes: usize,
    pub(crate) patch_bytes: usize,
    pub(crate) selected_segments: usize,
    pub(crate) baseline_tokens: usize,
    pub(crate) rewritten_tokens: usize,
    segments: Vec<CopySegment>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct FindTraceEntry {
    distance: u32,
    length: u32,
}

impl FindTraceEntry {
    fn new(distance: usize, length: usize) -> Self {
        Self {
            distance: compact_usize(distance),
            length: compact_usize(length),
        }
    }

    fn as_match(self) -> Match {
        Match {
            distance: expand_u32(self.distance),
            length: expand_u32(self.length),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FindTraceRecord {
    pos: u32,
    dictionary: u32,
    limit: u32,
    trace_start: u32,
    trace_length: u32,
    check_count: u32,
}

impl FindTraceRecord {
    const EMPTY: Self = Self {
        pos: 0,
        dictionary: 0,
        limit: 0,
        trace_start: 0,
        trace_length: u32::MAX,
        check_count: 0,
    };

    fn is_empty(self) -> bool {
        self.trace_length == u32::MAX
    }
}

struct FindTraceCache {
    enabled: bool,
    block_start: usize,
    records: Vec<FindTraceRecord>,
    trace: Vec<FindTraceEntry>,
    trace_capacity: usize,
}

impl FindTraceCache {
    fn new(enabled: bool, block: usize) -> Result<Self, Error> {
        if !enabled {
            return Ok(Self {
                enabled: false,
                block_start: 0,
                records: Vec::new(),
                trace: Vec::new(),
                trace_capacity: 0,
            });
        }
        let trace_capacity = block.checked_mul(MAX_CHAIN).ok_or(Error::Limit)?;
        let records = buffer(block, FindTraceRecord::EMPTY)?;
        let mut trace = Vec::new();
        trace
            .try_reserve_exact(trace_capacity)
            .map_err(|_| Error::Limit)?;
        Ok(Self {
            enabled: true,
            block_start: 0,
            records,
            trace,
            trace_capacity,
        })
    }

    fn start_block(&mut self, start: usize) {
        self.block_start = start;
        self.records.fill(FindTraceRecord::EMPTY);
        self.trace.clear();
    }

    fn record_index(&self, pos: usize) -> Option<usize> {
        pos.checked_sub(self.block_start)
            .filter(|&local| local < self.records.len())
    }

    fn can_capture(&self, pos: usize) -> bool {
        self.enabled
            && self
                .record_index(pos)
                .is_some_and(|index| self.records[index].is_empty())
            && self.trace_capacity.saturating_sub(self.trace.len()) >= MAX_CHAIN
    }

    fn effective_limit(input: &[u8], pos: usize, max_length: usize) -> usize {
        MAX_MATCH.min(max_length).min(input.len() - pos)
    }

    fn capture(
        &mut self,
        finder: &Finder,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        max_length: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Matches, Error> {
        if !self.can_capture(pos) {
            return finder.find_limited(input, pos, dictionary, max_length, cancel);
        }

        let trace_start = self.trace.len();
        let mut check_count = 0usize;
        let result = finder.find_limited_core(
            input,
            pos,
            dictionary,
            max_length,
            Some(&mut self.trace),
            &mut || {
                check_count += 1;
                cancel()
            },
        );
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                self.trace.truncate(trace_start);
                return Err(error);
            }
        };
        let index = self.record_index(pos).unwrap();
        self.records[index] = FindTraceRecord {
            pos: compact_usize(pos),
            dictionary: compact_usize(dictionary),
            limit: compact_usize(Self::effective_limit(input, pos, max_length)),
            trace_start: compact_usize(trace_start),
            trace_length: compact_usize(self.trace.len() - trace_start),
            check_count: compact_usize(check_count),
        };
        Ok(result)
    }

    fn replay(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        max_length: usize,
        models: Option<&Models>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Option<Matches>, Error> {
        if !self.enabled {
            return Ok(None);
        }
        let Some(index) = self.record_index(pos) else {
            return Ok(None);
        };
        let record = self.records[index];
        if record.is_empty()
            || expand_u32(record.pos) != pos
            || expand_u32(record.dictionary) != dictionary
            || expand_u32(record.limit) != Self::effective_limit(input, pos, max_length)
        {
            return Ok(None);
        }

        for _ in 0..expand_u32(record.check_count) {
            check(cancel)?;
        }
        let start = expand_u32(record.trace_start);
        let end = start + expand_u32(record.trace_length);
        let mut result = Matches::new();
        let mut best_length = 3usize;
        let mut best_price = None;
        for entry in &self.trace[start..end] {
            let candidate = entry.as_match();
            if candidate.length > best_length {
                best_length = candidate.length;
                result.push(candidate);
                best_price = None;
            } else if candidate.length == best_length
                && let Some(models) = models
            {
                let last_index = result.length - 1;
                let last = result.values[last_index];
                let last_price = *best_price
                    .get_or_insert_with(|| distance_price(models, last.distance, last.length));
                let candidate_price = distance_price(models, candidate.distance, candidate.length);
                if candidate_price < last_price {
                    result.values[last_index] = candidate;
                    best_price = Some(candidate_price);
                }
            }
        }
        Ok(Some(result))
    }
}

impl Matches {
    fn new() -> Self {
        Self {
            values: [Match::default(); FRONTIER],
            length: 0,
        }
    }

    fn push(&mut self, value: Match) {
        if self.length < FRONTIER {
            self.values[self.length] = value;
            self.length += 1;
        } else {
            // chain後方の候補は必ずより遠い。上限到達後も最長候補だけは失わない。
            self.values[FRONTIER - 1] = value;
        }
    }

    #[cfg(test)]
    fn values(&self) -> Vec<Match> {
        self.iter().collect()
    }

    fn iter(&self) -> impl Iterator<Item = Match> + '_ {
        self.values[..self.length].iter().copied()
    }
}

fn bt_matches(block: &bt::Block, local: usize) -> impl Iterator<Item = Match> + '_ {
    block
        .candidates_local(local)
        .iter()
        .copied()
        .map(|candidate| Match {
            distance: candidate.distance(),
            length: candidate.length(),
        })
}

fn bt_frontier(
    block: &bt::Block,
    local: usize,
    maximum: usize,
    models: &Models,
    distance_table: Option<&DistancePriceTable>,
) -> Matches {
    let mut result = Matches::new();
    let mut best_length = 3usize;
    let mut best_price = None;
    for mut candidate in bt_matches(block, local) {
        candidate.length = candidate.length.min(maximum);
        if candidate.length > best_length {
            best_length = candidate.length;
            result.push(candidate);
            best_price = None;
        } else if candidate.length == best_length && candidate.length >= 4 {
            let last_index = result.length - 1;
            let last = result.values[last_index];
            let last_price = *best_price.get_or_insert_with(|| {
                distance_table.map_or_else(
                    || distance_price(models, last.distance, last.length),
                    |table| table.price(last.distance, last.length),
                )
            });
            let candidate_price = distance_table.map_or_else(
                || distance_price(models, candidate.distance, candidate.length),
                |table| table.price(candidate.distance, candidate.length),
            );
            if candidate_price < last_price {
                result.values[last_index] = candidate;
                best_price = Some(candidate_price);
            }
        }
    }
    result
}

struct Finder {
    previous4: Vec<u32>,
}

impl Finder {
    fn new(input: &[u8], cancel: &mut impl FnMut() -> bool) -> Result<Self, Error> {
        let _profile = Scope::new(Phase::Index);
        let mut heads4 = buffer(HASH_SIZE, NONE)?;
        let mut previous4 = buffer(input.len(), NONE)?;
        for (pos, link4) in previous4.iter_mut().enumerate() {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            if input.len() - pos >= 4 {
                let key = hash4(input, pos);
                *link4 = heads4[key];
                heads4[key] = pos as u32;
            }
        }
        Ok(Self { previous4 })
    }

    fn find(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Matches, Error> {
        self.find_limited(input, pos, dictionary, MAX_MATCH, cancel)
    }

    fn find_limited(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        max_length: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Matches, Error> {
        self.find_limited_core(input, pos, dictionary, max_length, None, cancel)
    }

    fn find_limited_core(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        max_length: usize,
        mut trace: Option<&mut Vec<FindTraceEntry>>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Matches, Error> {
        let _profile = Scope::new(Phase::FindMatches);
        let mut result = Matches::new();
        if input.len().saturating_sub(pos) < 4 || max_length < 4 {
            return Ok(result);
        }

        let limit = MAX_MATCH.min(max_length).min(input.len() - pos);
        let mut candidate = self.previous4[pos];
        let mut best_length = 3;
        let mut compared = 0usize;
        for chain in 0..MAX_CHAIN {
            if candidate == NONE {
                break;
            }
            let source = candidate as usize;
            let distance = pos - source;
            if distance > dictionary {
                break;
            }
            if chain & 31 == 0 {
                check(cancel)?;
            }

            // 同じ20bit bucketでも4 byte値は同一とは限らない。先頭から照合し、
            // hash衝突をmatchとして出力しない。先頭4 byteも比較予算へ含める。
            let length = finder_match_length(input, source, pos, limit, &mut compared, cancel)?;
            if length > best_length {
                best_length = length;
                result.push(Match { length, distance });
                if let Some(trace) = trace.as_mut() {
                    trace.push(FindTraceEntry::new(distance, length));
                }
            } else if length == best_length
                && length >= 4
                && let Some(trace) = trace.as_mut()
            {
                trace.push(FindTraceEntry::new(distance, length));
            }
            if length == limit || compared >= MAX_COMPARE {
                break;
            }
            candidate = self.previous4[source];
        }

        Ok(result)
    }

    /// frozen modelで同長候補の距離価格だけを比較する研究用探索。
    /// chain・比較予算・早期終了は [`Self::find_limited`] と同一に保つ。
    fn find_limited_priced(
        &self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        max_length: usize,
        models: &Models,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Matches, Error> {
        let _profile = Scope::new(Phase::FindMatches);
        let mut result = Matches::new();
        if input.len().saturating_sub(pos) < 4 || max_length < 4 {
            return Ok(result);
        }

        let limit = MAX_MATCH.min(max_length).min(input.len() - pos);
        let mut candidate = self.previous4[pos];
        let mut best_length = 3;
        let mut best_price = None;
        let mut compared = 0usize;
        for chain in 0..MAX_CHAIN {
            if candidate == NONE {
                break;
            }
            let source = candidate as usize;
            let distance = pos - source;
            if distance > dictionary {
                break;
            }
            if chain & 31 == 0 {
                check(cancel)?;
            }

            let length = finder_match_length(input, source, pos, limit, &mut compared, cancel)?;
            if length > best_length {
                best_length = length;
                result.push(Match { length, distance });
                // pushが空きへの追加でもfull frontier末尾の置換でも、新しい最長候補の
                // 距離価格は必要になるまで計算しない。
                best_price = None;
            } else if length == best_length && length >= 4 {
                let last_index = result.length - 1;
                let last = result.values[last_index];
                let last_price = *best_price
                    .get_or_insert_with(|| distance_price(models, last.distance, last.length));
                let candidate_price = distance_price(models, distance, length);
                if candidate_price < last_price {
                    result.values[last_index] = Match { length, distance };
                    best_price = Some(candidate_price);
                }
            }
            if length == limit || compared >= MAX_COMPARE {
                break;
            }
            candidate = self.previous4[source];
        }

        Ok(result)
    }
}

fn hash4(input: &[u8], pos: usize) -> usize {
    let value = u32::from_le_bytes(input[pos..pos + 4].try_into().unwrap());
    (value.wrapping_mul(0x9e37_79b1) >> (32 - HASH_BITS)) as usize
}

fn update(probability: &mut u16, bit: bool) {
    let value = u32::from(*probability);
    let mask = 0u32.wrapping_sub(u32::from(bit));
    let zero_delta = (32768 - value) >> 5;
    let one_delta = 0u32.wrapping_sub(value >> 5);
    let delta = (zero_delta & !mask) | (one_delta & mask);
    *probability = value.wrapping_add(delta) as u16;
}

#[derive(PartialEq, Eq)]
struct LengthModels {
    first: [u16; LENGTH_CONTEXTS],
    second: [u16; LENGTH_CONTEXTS],
    low: Vec<u16>,
    middle: Vec<u16>,
    high: Vec<u16>,
}

impl LengthModels {
    fn new() -> Result<Self, Error> {
        Ok(Self {
            first: [16384; LENGTH_CONTEXTS],
            second: [16384; LENGTH_CONTEXTS],
            low: buffer(LENGTH_CONTEXTS * 8, 16384)?,
            middle: buffer(LENGTH_CONTEXTS * 8, 16384)?,
            high: buffer(LENGTH_CONTEXTS * NUMBER_MODELS, 16384)?,
        })
    }
}

#[derive(PartialEq, Eq)]
struct Models {
    literal: Vec<u16>,
    #[cfg(khc_literal_mix)]
    literal_order2: Vec<u16>,
    #[cfg(khc_literal_mix)]
    literal_weights: Vec<u16>,
    is_match: [u16; TOKEN_CONTEXTS],
    is_rep: [u16; TOKEN_CONTEXTS],
    is_rep0: [u16; TOKEN_CONTEXTS],
    is_short_rep: [u16; TOKEN_CONTEXTS],
    is_rep1: [u16; TOKEN_CONTEXTS],
    is_rep2: [u16; TOKEN_CONTEXTS],
    match_length: LengthModels,
    rep_length: LengthModels,
    distance_slot: Vec<u16>,
    distance_footer: Vec<u16>,
}

impl Models {
    fn new() -> Result<Self, Error> {
        Ok(Self {
            literal: buffer(LITERAL_CONTEXTS, 16384)?,
            #[cfg(khc_literal_mix)]
            literal_order2: buffer(LITERAL_ORDER2_ENTRIES, 16384)?,
            #[cfg(khc_literal_mix)]
            literal_weights: buffer(LITERAL_ORDER2_ENTRIES, 16384)?,
            is_match: [16384; TOKEN_CONTEXTS],
            is_rep: [16384; TOKEN_CONTEXTS],
            is_rep0: [16384; TOKEN_CONTEXTS],
            is_short_rep: [16384; TOKEN_CONTEXTS],
            is_rep1: [16384; TOKEN_CONTEXTS],
            is_rep2: [16384; TOKEN_CONTEXTS],
            match_length: LengthModels::new()?,
            rep_length: LengthModels::new()?,
            distance_slot: buffer(DISTANCE_CONTEXTS * 32, 16384)?,
            distance_footer: buffer(DISTANCE_CONTEXTS * 32, 16384)?,
        })
    }

    fn try_clone(&self) -> Result<Self, Error> {
        fn clone_slice<T: Clone>(source: &[T]) -> Result<Vec<T>, Error> {
            let mut result = Vec::new();
            result
                .try_reserve_exact(source.len())
                .map_err(|_| Error::Limit)?;
            result.extend_from_slice(source);
            Ok(result)
        }

        fn clone_length(source: &LengthModels) -> Result<LengthModels, Error> {
            Ok(LengthModels {
                first: source.first,
                second: source.second,
                low: clone_slice(&source.low)?,
                middle: clone_slice(&source.middle)?,
                high: clone_slice(&source.high)?,
            })
        }

        Ok(Self {
            literal: clone_slice(&self.literal)?,
            #[cfg(khc_literal_mix)]
            literal_order2: clone_slice(&self.literal_order2)?,
            #[cfg(khc_literal_mix)]
            literal_weights: clone_slice(&self.literal_weights)?,
            is_match: self.is_match,
            is_rep: self.is_rep,
            is_rep0: self.is_rep0,
            is_short_rep: self.is_short_rep,
            is_rep1: self.is_rep1,
            is_rep2: self.is_rep2,
            match_length: clone_length(&self.match_length)?,
            rep_length: clone_length(&self.rep_length)?,
            distance_slot: clone_slice(&self.distance_slot)?,
            distance_footer: clone_slice(&self.distance_footer)?,
        })
    }

    fn blend_with(&mut self, initial: &Self) {
        fn blend(target: &mut [u16], source: &[u16]) {
            debug_assert_eq!(target.len(), source.len());
            for (target, source) in target.iter_mut().zip(source) {
                *target = ((u32::from(*target) + u32::from(*source)) / 2) as u16;
            }
        }

        fn blend_length(target: &mut LengthModels, source: &LengthModels) {
            blend(&mut target.first, &source.first);
            blend(&mut target.second, &source.second);
            blend(&mut target.low, &source.low);
            blend(&mut target.middle, &source.middle);
            blend(&mut target.high, &source.high);
        }

        blend(&mut self.literal, &initial.literal);
        #[cfg(khc_literal_mix)]
        {
            blend(&mut self.literal_order2, &initial.literal_order2);
            blend(&mut self.literal_weights, &initial.literal_weights);
        }
        blend(&mut self.is_match, &initial.is_match);
        blend(&mut self.is_rep, &initial.is_rep);
        blend(&mut self.is_rep0, &initial.is_rep0);
        blend(&mut self.is_short_rep, &initial.is_short_rep);
        blend(&mut self.is_rep1, &initial.is_rep1);
        blend(&mut self.is_rep2, &initial.is_rep2);
        blend_length(&mut self.match_length, &initial.match_length);
        blend_length(&mut self.rep_length, &initial.rep_length);
        blend(&mut self.distance_slot, &initial.distance_slot);
        blend(&mut self.distance_footer, &initial.distance_footer);
    }
}

/// Research-only probability state for the extended token grammar.
struct PatchedCopyModels {
    is_patch: [u16; TOKEN_CONTEXTS],
    patch_count: [u16; NUMBER_MODELS],
    patch_gap: [u16; NUMBER_MODELS],
}

impl PatchedCopyModels {
    fn new() -> Self {
        Self {
            is_patch: [16384; TOKEN_CONTEXTS],
            patch_count: [16384; NUMBER_MODELS],
            patch_gap: [16384; NUMBER_MODELS],
        }
    }
}

fn token_context(previous_match: bool, pos: usize) -> usize {
    usize::from(previous_match) * 4 + (pos & 3)
}

fn distance_context(length: usize) -> usize {
    match length {
        0..=4 => 0,
        5..=8 => 1,
        9..=16 => 2,
        _ => 3,
    }
}

fn encode_error(error: &'static str) -> Error {
    match error {
        "range output limit" => Error::CandidateFull,
        "range allocation failed"
        | "rANS allocation failed"
        | "rANS event limit"
        | "rANS segment plain limit" => Error::Limit,
        "rANS cancelled" => Error::Cancelled,
        _ => Error::Format(error),
    }
}

trait BitSink {
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error>;

    fn end_plan(
        &mut self,
        _plain_bytes: usize,
        _cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        Ok(())
    }

    /// trueを返すと、このbitの確率更新はsink側が窓境界まで保留する。
    /// 既定は即時更新。通常encoderの単型化では呼ばれない。
    fn defer_update(&mut self, probability: &mut u16, bit: bool) -> bool {
        let _ = (probability, bit);
        false
    }
}

impl BitSink for range::Encoder {
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.bit_unchecked(probability, bit).map_err(encode_error)
    }
}

impl BitSink for super::rans::SegmentedEncoder {
    #[inline(always)]
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.bit(probability, bit).map_err(encode_error)
    }

    fn end_plan(
        &mut self,
        plain_bytes: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        self.end_plan(plain_bytes, cancel).map_err(encode_error)
    }
}

struct FastRangeSink<'a>(&'a mut range::Encoder);

impl BitSink for FastRangeSink<'_> {
    #[inline(always)]
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.0.bit_unchecked_fast(probability, bit);
        Ok(())
    }
}

const MAX_BEAM_PLAN_RANGE_RECORDS: usize = 1 << 16;

struct PlanRangeSink<'a> {
    coder: &'a mut range::Encoder,
    records: &'a mut Vec<BeamPlanRangeRecord>,
    input_len: usize,
    plain_end: usize,
    previous_emitted_bytes: usize,
    base_memory: usize,
    memory_budget: usize,
}

impl BitSink for PlanRangeSink<'_> {
    #[inline(always)]
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.coder.bit_unchecked_fast(probability, bit);
        Ok(())
    }

    fn end_plan(
        &mut self,
        plain_bytes: usize,
        _cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        if plain_bytes == 0 || self.records.len() >= MAX_BEAM_PLAN_RANGE_RECORDS {
            return Err(Error::Limit);
        }
        let plain_end = self
            .plain_end
            .checked_add(plain_bytes)
            .filter(|end| *end <= self.input_len)
            .ok_or(Error::Format("beam plan census input range"))?;

        if self.records.len() == self.records.capacity() {
            let minimum_capacity = self.records.len().checked_add(1).ok_or(Error::Limit)?;
            let target_capacity = if self.records.capacity() == 0 {
                minimum_capacity
            } else {
                self.records
                    .capacity()
                    .checked_mul(2)
                    .ok_or(Error::Limit)?
                    .min(MAX_BEAM_PLAN_RANGE_RECORDS)
                    .max(minimum_capacity)
            };
            let estimated_bytes = target_capacity
                .checked_mul(std::mem::size_of::<BeamPlanRangeRecord>())
                .and_then(|bytes| self.base_memory.checked_add(bytes))
                .ok_or(Error::Limit)?;
            if estimated_bytes > self.memory_budget {
                return Err(Error::Limit);
            }
            self.records
                .try_reserve_exact(target_capacity - self.records.len())
                .map_err(|_| Error::Limit)?;
            let actual_bytes = self
                .records
                .capacity()
                .checked_mul(std::mem::size_of::<BeamPlanRangeRecord>())
                .and_then(|bytes| self.base_memory.checked_add(bytes))
                .ok_or(Error::Limit)?;
            if actual_bytes > self.memory_budget
                || self.records.capacity() > MAX_BEAM_PLAN_RANGE_RECORDS
            {
                return Err(Error::Limit);
            }
        }

        let emitted_bytes_total = self.coder.emitted_bytes();
        let emitted_bytes_since_previous_plan = emitted_bytes_total
            .checked_sub(self.previous_emitted_bytes)
            .ok_or(Error::Format("beam plan census range output"))?;
        let prefix_payload_bytes_if_terminated =
            self.coder.finish_len_preview().ok_or(Error::Limit)?;
        if prefix_payload_bytes_if_terminated < emitted_bytes_total {
            return Err(Error::Format("beam plan census range preview"));
        }

        self.records.push(BeamPlanRangeRecord {
            plain_start: self.plain_end,
            plain_bytes,
            emitted_bytes_total,
            emitted_bytes_since_previous_plan,
            pending_bytes: self.coder.pending_bytes(),
            prefix_payload_bytes_if_terminated,
        });
        self.plain_end = plain_end;
        self.previous_emitted_bytes = emitted_bytes_total;
        Ok(())
    }
}

struct LearningSink;

// 診断専用。range出力byte数ではなく、実更新順の確率に対する近似bit価格を数える。
#[derive(Default)]
struct PriceSink(u64);

impl BitSink for PriceSink {
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.0 = self
            .0
            .checked_add(bit_price(probability, bit))
            .ok_or(Error::Limit)?;
        Ok(())
    }
}

impl BitSink for LearningSink {
    fn bit(&mut self, _probability: u16, _bit: bool) -> Result<(), Error> {
        Ok(())
    }
}

fn put(sink: &mut impl BitSink, probability: &mut u16, bit: bool) -> Result<(), Error> {
    sink.bit(*probability, bit)?;
    if !sink.defer_update(probability, bit) {
        update(probability, bit);
    }
    Ok(())
}

const FAST_TOKEN_INPUT_MARGIN: usize = 128;
#[cfg(debug_assertions)]
const MAX_FAST_TOKEN_BITS: usize = 55;

trait BitSource {
    fn bit(&mut self, probability: u16) -> Result<bool, Error>;
}

trait DecoderSource: BitSource {
    fn input_remaining(&self) -> usize;
    fn bit_calls(&self) -> u64;
    fn renorm_byte_events(&self) -> [u64; 3] {
        [0; 3]
    }
    fn advance_output(&mut self, plain_bytes: usize) -> Result<(), &'static str>;
    fn finish(&self) -> Result<(), &'static str>;
    unsafe fn bit_unchecked_fast(&mut self, probability: u16) -> bool;
}

impl<const PROFILE: bool> BitSource for range::Decoder<'_, PROFILE> {
    #[inline(always)]
    fn bit(&mut self, probability: u16) -> Result<bool, Error> {
        self.bit_unchecked(probability).map_err(Error::Format)
    }
}

impl<const PROFILE: bool> DecoderSource for range::Decoder<'_, PROFILE> {
    fn input_remaining(&self) -> usize {
        range::Decoder::input_remaining(self)
    }

    fn bit_calls(&self) -> u64 {
        range::Decoder::bit_calls(self)
    }

    fn renorm_byte_events(&self) -> [u64; 3] {
        range::Decoder::renorm_byte_events(self)
    }

    fn advance_output(&mut self, _plain_bytes: usize) -> Result<(), &'static str> {
        Ok(())
    }

    fn finish(&self) -> Result<(), &'static str> {
        range::Decoder::finish(self)
    }

    unsafe fn bit_unchecked_fast(&mut self, probability: u16) -> bool {
        // SAFETY: DecoderSourceの呼び出し元がFastTokenRangeのtoken契約を満たす。
        unsafe { range::Decoder::bit_unchecked_fast(self, probability) }
    }
}

impl<const PROFILE: bool> BitSource for super::rans::SegmentedDecoder<'_, PROFILE> {
    #[inline(always)]
    fn bit(&mut self, probability: u16) -> Result<bool, Error> {
        super::rans::SegmentedDecoder::bit(self, probability).map_err(Error::Format)
    }
}

impl<const PROFILE: bool> DecoderSource for super::rans::SegmentedDecoder<'_, PROFILE> {
    fn input_remaining(&self) -> usize {
        super::rans::SegmentedDecoder::input_remaining(self)
    }

    fn bit_calls(&self) -> u64 {
        super::rans::SegmentedDecoder::bit_calls(self)
    }

    fn advance_output(&mut self, plain_bytes: usize) -> Result<(), &'static str> {
        super::rans::SegmentedDecoder::advance_output(self, plain_bytes)
    }

    fn finish(&self) -> Result<(), &'static str> {
        super::rans::SegmentedDecoder::finish(self)
    }

    unsafe fn bit_unchecked_fast(&mut self, probability: u16) -> bool {
        // SAFETY: DecoderSourceの呼び出し元がFastTokenRangeのtoken契約を満たす。
        unsafe { super::rans::SegmentedDecoder::bit_unchecked_fast(self, probability) }
    }
}

struct FastTokenRange<'decoder, C: DecoderSource> {
    inner: &'decoder mut C,
    #[cfg(debug_assertions)]
    bits: usize,
}

impl<'decoder, C: DecoderSource> FastTokenRange<'decoder, C> {
    /// token境界での入力余裕と最大bit数を呼び出し側が証明したときだけ作る。
    ///
    /// # Safety
    /// `inner`の現在位置に128 byte以上の入力が残り、このreaderを使う間は
    /// 最大55 bitだけを復号してdropすること。渡す確率はすべて `1..32768` であること。
    /// この範囲は内部モデルの初期値16384と更新が保つ値域で、`bit_unchecked_fast`は
    /// 確率の範囲を検査しない。
    unsafe fn new(inner: &'decoder mut C) -> Self {
        debug_assert!(inner.input_remaining() >= FAST_TOKEN_INPUT_MARGIN);
        Self {
            inner,
            #[cfg(debug_assertions)]
            bits: 0,
        }
    }
}

impl<C: DecoderSource> BitSource for FastTokenRange<'_, C> {
    #[inline(always)]
    fn bit(&mut self, probability: u16) -> Result<bool, Error> {
        #[cfg(debug_assertions)]
        {
            assert!(self.bits < MAX_FAST_TOKEN_BITS);
            self.bits += 1;
        }
        // SAFETY: newの契約は確率1..32768、token当たり55 bit以下、開始時128 byte以上。
        // SAFETY: newの契約は128 byte余裕と最大55 bitのtoken境界を満たす。
        Ok(unsafe { self.inner.bit_unchecked_fast(probability) })
    }
}

#[inline(always)]
fn get(coder: &mut impl BitSource, probability: &mut u16) -> Result<bool, Error> {
    // 全モデルは16384で初期化され、updateは有効範囲1..32768を維持する。
    let bit = coder.bit(*probability)?;
    update(probability, bit);
    Ok(bit)
}

fn get_defer(coder: &mut range::Decoder<'_>, probability: &mut u16) -> Result<bool, Error> {
    let bit = coder.bit_unchecked(*probability).map_err(Error::Format)?;
    defer_adapt_push(probability, bit)?;
    Ok(bit)
}

fn put_tree(
    sink: &mut impl BitSink,
    model: &mut [u16],
    value: usize,
    bits: usize,
) -> Result<(), Error> {
    let mut node = 1usize;
    for shift in (0..bits).rev() {
        let bit = value & (1 << shift) != 0;
        put(sink, &mut model[node], bit)?;
        node = node * 2 + usize::from(bit);
    }
    debug_assert_eq!(node - (1 << bits), value);
    Ok(())
}

fn get_tree(coder: &mut impl BitSource, model: &mut [u16], bits: usize) -> Result<usize, Error> {
    let mut node = 1usize;
    for _ in 0..bits {
        node = node * 2 + usize::from(get(coder, &mut model[node])?);
    }
    Ok(node - (1 << bits))
}

fn get_tree_defer(
    coder: &mut range::Decoder<'_>,
    model: &mut [u16],
    bits: usize,
) -> Result<usize, Error> {
    let mut node = 1usize;
    for _ in 0..bits {
        node = node * 2 + usize::from(get_defer(coder, &mut model[node])?);
    }
    Ok(node - (1 << bits))
}

fn put_number(sink: &mut impl BitSink, model: &mut [u16], value: usize) -> Result<(), Error> {
    debug_assert!(value > 0);
    let slot = value.ilog2() as usize;
    put_tree(sink, &mut model[..32], slot, 5)?;
    for shift in (0..slot).rev() {
        put(sink, &mut model[32 + shift], value & (1 << shift) != 0)?;
    }
    Ok(())
}

fn get_number(
    coder: &mut impl BitSource,
    model: &mut [u16],
    maximum: usize,
) -> Result<usize, Error> {
    let slot = get_tree(coder, &mut model[..32], 5)?;
    if slot > maximum.ilog2() as usize {
        return Err(Error::Format("integer exceeds bound"));
    }
    let mut value = 1usize << slot;
    for shift in (0..slot).rev() {
        value |= usize::from(get(coder, &mut model[32 + shift])?) << shift;
    }
    if value > maximum {
        return Err(Error::Format("integer exceeds bound"));
    }
    Ok(value)
}

fn put_length(
    sink: &mut impl BitSink,
    model: &mut LengthModels,
    context: usize,
    length: usize,
    minimum: usize,
) -> Result<(), Error> {
    let value = length - minimum;
    let high = value >= 8;
    put(sink, &mut model.first[context], high)?;
    if !high {
        return put_tree(sink, &mut model.low[context * 8..context * 8 + 8], value, 3);
    }
    let very_high = value >= 16;
    put(sink, &mut model.second[context], very_high)?;
    if !very_high {
        return put_tree(
            sink,
            &mut model.middle[context * 8..context * 8 + 8],
            value - 8,
            3,
        );
    }
    put_number(
        sink,
        &mut model.high[context * NUMBER_MODELS..(context + 1) * NUMBER_MODELS],
        value - 15,
    )
}

fn get_length(
    coder: &mut impl BitSource,
    model: &mut LengthModels,
    context: usize,
    minimum: usize,
) -> Result<usize, Error> {
    let value = if !get(coder, &mut model.first[context])? {
        get_tree(coder, &mut model.low[context * 8..context * 8 + 8], 3)?
    } else if !get(coder, &mut model.second[context])? {
        8 + get_tree(coder, &mut model.middle[context * 8..context * 8 + 8], 3)?
    } else {
        15 + get_number(
            coder,
            &mut model.high[context * NUMBER_MODELS..(context + 1) * NUMBER_MODELS],
            MAX_MATCH - minimum - 15,
        )?
    };
    let length = minimum
        .checked_add(value)
        .ok_or(Error::Format("match length overflow"))?;
    if length > MAX_MATCH {
        return Err(Error::Format("match length exceeds bound"));
    }
    Ok(length)
}

fn put_distance(
    sink: &mut impl BitSink,
    models: &mut Models,
    distance: usize,
    length: usize,
) -> Result<(), Error> {
    let context = distance_context(length);
    let start = context * 32;
    let slot = distance.ilog2() as usize;
    put_tree(sink, &mut models.distance_slot[start..start + 32], slot, 5)?;
    for shift in (0..slot).rev() {
        put(
            sink,
            &mut models.distance_footer[start + shift],
            distance & (1 << shift) != 0,
        )?;
    }
    Ok(())
}

fn small_distance_delta(distance: usize, rep0: usize) -> Option<usize> {
    if distance < rep0 {
        let magnitude = rep0 - distance;
        (1..=MAX_DISTANCE_DELTA)
            .contains(&magnitude)
            .then_some(MAX_DISTANCE_DELTA - magnitude)
    } else {
        let magnitude = distance - rep0;
        (1..=MAX_DISTANCE_DELTA)
            .contains(&magnitude)
            .then_some(MAX_DISTANCE_DELTA - 1 + magnitude)
    }
}

fn put_fixed_tree(sink: &mut impl BitSink, value: usize, bits: usize) -> Result<(), Error> {
    let mut node = 1usize;
    for shift in (0..bits).rev() {
        let bit = value & (1 << shift) != 0;
        sink.bit(16384, bit)?;
        node = node * 2 + usize::from(bit);
    }
    debug_assert_eq!(node - (1 << bits), value);
    Ok(())
}

fn put_distance_delta(
    sink: &mut impl BitSink,
    models: &mut Models,
    delta_models: &mut [u16; DISTANCE_CONTEXTS],
    distance: usize,
    rep0: usize,
    length: usize,
    stats: &mut DistanceDeltaScreen,
) -> Result<(), Error> {
    let context = distance_context(length);
    let code = small_distance_delta(distance, rep0);
    put(sink, &mut delta_models[context], code.is_some())?;
    stats.normal_match_events = stats
        .normal_match_events
        .checked_add(1)
        .ok_or(Error::Limit)?;
    if let Some(code) = code {
        put_fixed_tree(sink, code, 5)?;
        stats.delta_events = stats.delta_events.checked_add(1).ok_or(Error::Limit)?;
    } else {
        put_distance(sink, models, distance, length)?;
        stats.absolute_escape_events = stats
            .absolute_escape_events
            .checked_add(1)
            .ok_or(Error::Limit)?;
    }
    Ok(())
}

fn get_fixed_tree(coder: &mut impl BitSource, bits: usize) -> Result<usize, Error> {
    let mut value = 0usize;
    for _ in 0..bits {
        value = (value << 1) | usize::from(coder.bit(16384)?);
    }
    Ok(value)
}

fn get_distance_delta(
    coder: &mut impl BitSource,
    models: &mut Models,
    delta_models: &mut [u16; DISTANCE_CONTEXTS],
    length: usize,
    maximum: usize,
    rep0: usize,
) -> Result<usize, Error> {
    let context = distance_context(length);
    let distance = if get(coder, &mut delta_models[context])? {
        let code = get_fixed_tree(coder, 5)?;
        if code < MAX_DISTANCE_DELTA {
            rep0.checked_sub(MAX_DISTANCE_DELTA - code)
        } else {
            rep0.checked_add(code - (MAX_DISTANCE_DELTA - 1))
        }
        .ok_or(Error::Format("distance delta is outside the valid range"))?
    } else {
        get_distance(coder, models, length, maximum)?
    };
    if distance == 0 || distance > maximum {
        return Err(Error::Format("distance delta exceeds bound"));
    }
    Ok(distance)
}

fn get_distance(
    coder: &mut impl BitSource,
    models: &mut Models,
    length: usize,
    maximum: usize,
) -> Result<usize, Error> {
    let context = distance_context(length);
    let start = context * 32;
    let slot = get_tree(coder, &mut models.distance_slot[start..start + 32], 5)?;
    if slot > maximum.ilog2() as usize {
        return Err(Error::Format("distance exceeds bound"));
    }
    let mut distance = 1usize << slot;
    for shift in (0..slot).rev() {
        distance |= usize::from(get(coder, &mut models.distance_footer[start + shift])?) << shift;
    }
    if distance == 0 || distance > maximum {
        return Err(Error::Format("distance exceeds bound"));
    }
    Ok(distance)
}

// 新しいliteral expertだけを研究cloneへ接続する。過去raw bytesからのみ予測。
#[cfg(khc_literal_mix)]
#[inline(always)]
fn order2_literal_index(bytes: &[u8], pos: usize, symbol: usize) -> usize {
    let previous1 = pos.checked_sub(1).map_or(0, |at| bytes[at]);
    let previous2 = pos.checked_sub(2).map_or(0, |at| bytes[at]);
    let context = (usize::from(previous2) * 257 + usize::from(previous1)) & 511;
    context * 256 + symbol
}
#[inline(always)]
fn literal_probability(models: &Models, bytes: &[u8], pos: usize, old_index: usize, symbol: usize) -> u16 {
    #[cfg(khc_literal_mix)]
    {
        let index = order2_literal_index(bytes, pos, symbol);
        let weight = u64::from(models.literal_weights[index]);
        let old = u64::from(models.literal[old_index]);
        let new = u64::from(models.literal_order2[index]);
        return ((weight * old + (32768 - weight) * new + 16384) >> 15).clamp(1, 32767) as u16;
    }
    #[cfg(not(khc_literal_mix))]
    {
        let _ = (bytes, pos, symbol);
        models.literal[old_index]
    }
}
#[cfg(khc_literal_mix)]
#[inline(always)]
fn update_literal_experts(models: &mut Models, bytes: &[u8], pos: usize, old_index: usize, symbol: usize, bit: bool) {
    let index = order2_literal_index(bytes, pos, symbol);
    let old = u64::from(models.literal[old_index]);
    let new = u64::from(models.literal_order2[index]);
    let weight = u64::from(models.literal_weights[index]);
    let observed_old = if bit { 32768 - old } else { old };
    let observed_new = if bit { 32768 - new } else { new };
    let denominator = weight * observed_old + (32768 - weight) * observed_new;
    // 全probabilityは1..32768内。分母正、numerator<2^45なのでu64へ収まる。
    let posterior = (32768 * weight * observed_old) / denominator;
    let next = 256 + ((32256 * posterior) >> 15);
    update(&mut models.literal[old_index], bit);
    update(&mut models.literal_order2[index], bit);
    models.literal_weights[index] = next as u16;
}
fn put_literal_model(sink: &mut impl BitSink, models: &mut Models, bytes: &[u8], pos: usize, index: usize, symbol: usize, bit: bool) -> Result<(), Error> {
    #[cfg(khc_literal_mix)]
    {
        sink.bit(literal_probability(models, bytes, pos, index, symbol), bit)?;
        update_literal_experts(models, bytes, pos, index, symbol, bit);
        Ok(())
    }
    #[cfg(not(khc_literal_mix))]
    {
        let _ = (bytes, pos, symbol);
        put(sink, &mut models.literal[index], bit)
    }
}
fn get_literal_model(coder: &mut impl BitSource, models: &mut Models, bytes: &[u8], pos: usize, index: usize, symbol: usize) -> Result<bool, Error> {
    #[cfg(khc_literal_mix)]
    {
        let bit = coder.bit(literal_probability(models, bytes, pos, index, symbol))?;
        update_literal_experts(models, bytes, pos, index, symbol, bit);
        Ok(bit)
    }
    #[cfg(not(khc_literal_mix))]
    {
        let _ = (bytes, pos, symbol);
        get(coder, &mut models.literal[index])
    }
}

fn put_literal(
    sink: &mut impl BitSink,
    models: &mut Models,
    input: &[u8],
    pos: usize,
    reps: [usize; 4],
) -> Result<(), Error> {
    let previous = pos.checked_sub(1).map_or(0, |at| input[at]);
    let base = usize::from(previous >> 5) * LITERAL_STRIDE;
    let mut matched = reps[0] <= pos;
    let prediction = if matched { input[pos - reps[0]] } else { 0 };
    let value = input[pos];
    let mut symbol = 1usize;
    for shift in (0..8).rev() {
        let predicted_bit = prediction & (1 << shift) != 0;
        let bit = value & (1 << shift) != 0;
        let index = if matched {
            base + 256 * (1 + usize::from(predicted_bit)) + symbol
        } else {
            base + symbol
        };
        put_literal_model(sink, models, input, pos, index, symbol, bit)?;
        symbol = symbol * 2 + usize::from(bit);
        matched &= bit == predicted_bit;
    }
    Ok(())
}

fn get_literal(
    coder: &mut impl BitSource,
    models: &mut Models,
    output: &[u8],
    pos: usize,
    reps: [usize; 4],
) -> Result<u8, Error> {
    let previous = pos.checked_sub(1).map_or(0, |at| output[at]);
    let base = usize::from(previous >> 5) * LITERAL_STRIDE;
    let mut matched = reps[0] <= pos;
    let prediction = if matched { output[pos - reps[0]] } else { 0 };
    let mut symbol = 1usize;
    let mut remaining = 8usize;
    while remaining != 0 {
        let shift = 7 - symbol.ilog2() as usize;
        let predicted_bit = prediction & (1 << shift) != 0;
        let index = if matched {
            base + 256 * (1 + usize::from(predicted_bit)) + symbol
        } else {
            base + symbol
        };
        let bit = get_literal_model(coder, models, output, pos, index, symbol)?;
        symbol = symbol * 2 + usize::from(bit);
        matched &= bit == predicted_bit;
        remaining -= 1;
    }
    Ok((symbol - 256) as u8)
}

fn get_number_defer(
    coder: &mut range::Decoder<'_>,
    model: &mut [u16],
    maximum: usize,
) -> Result<usize, Error> {
    let slot = get_tree_defer(coder, &mut model[..32], 5)?;
    if slot > maximum.ilog2() as usize {
        return Err(Error::Format("integer exceeds bound"));
    }
    let mut value = 1usize << slot;
    for shift in (0..slot).rev() {
        value |= usize::from(get_defer(coder, &mut model[32 + shift])?) << shift;
    }
    if value > maximum {
        return Err(Error::Format("integer exceeds bound"));
    }
    Ok(value)
}

fn get_length_defer(
    coder: &mut range::Decoder<'_>,
    model: &mut LengthModels,
    context: usize,
    minimum: usize,
) -> Result<usize, Error> {
    let value = if !get_defer(coder, &mut model.first[context])? {
        get_tree_defer(coder, &mut model.low[context * 8..context * 8 + 8], 3)?
    } else if !get_defer(coder, &mut model.second[context])? {
        8 + get_tree_defer(coder, &mut model.middle[context * 8..context * 8 + 8], 3)?
    } else {
        15 + get_number_defer(
            coder,
            &mut model.high[context * NUMBER_MODELS..(context + 1) * NUMBER_MODELS],
            MAX_MATCH - minimum - 15,
        )?
    };
    let length = minimum
        .checked_add(value)
        .ok_or(Error::Format("match length overflow"))?;
    if length > MAX_MATCH {
        return Err(Error::Format("match length exceeds bound"));
    }
    Ok(length)
}

fn get_distance_defer(
    coder: &mut range::Decoder<'_>,
    models: &mut Models,
    length: usize,
    maximum: usize,
) -> Result<usize, Error> {
    let context = distance_context(length);
    let start = context * 32;
    let slot = get_tree_defer(coder, &mut models.distance_slot[start..start + 32], 5)?;
    if slot > maximum.ilog2() as usize {
        return Err(Error::Format("distance exceeds bound"));
    }
    let mut distance = 1usize << slot;
    for shift in (0..slot).rev() {
        distance |= usize::from(get_defer(
            coder,
            &mut models.distance_footer[start + shift],
        )?) << shift;
    }
    if distance == 0 || distance > maximum {
        return Err(Error::Format("distance exceeds bound"));
    }
    Ok(distance)
}

fn get_literal_defer(
    coder: &mut range::Decoder<'_>,
    models: &mut Models,
    output: &[u8],
    pos: usize,
    reps: [usize; 4],
) -> Result<u8, Error> {
    #[cfg(khc_literal_mix)]
    {
        let _ = (coder, models, output, pos, reps);
        return Err(Error::Format("literal mix does not support deferred adaptation"));
    }
    #[cfg(not(khc_literal_mix))]
    {
    let previous = pos.checked_sub(1).map_or(0, |at| output[at]);
    let base = usize::from(previous >> 5) * LITERAL_STRIDE;
    let mut matched = reps[0] <= pos;
    let prediction = if matched { output[pos - reps[0]] } else { 0 };
    let mut symbol = 1usize;
    let mut remaining = 8usize;
    while remaining != 0 {
        let shift = 7 - symbol.ilog2() as usize;
        let predicted_bit = prediction & (1 << shift) != 0;
        let index = if matched {
            base + 256 * (1 + usize::from(predicted_bit)) + symbol
        } else {
            base + symbol
        };
        let bit = get_defer(coder, &mut models.literal[index])?;
        symbol = symbol * 2 + usize::from(bit);
        matched &= bit == predicted_bit;
        remaining -= 1;
    }
    Ok((symbol - 256) as u8)
    }
}

fn bit_price(probability: u16, bit: bool) -> u64 {
    super::prices::bit_price(probability, bit)
}

fn tree_price(model: &[u16], value: usize, bits: usize) -> u64 {
    let mut node = 1usize;
    let mut price = 0u64;
    for shift in (0..bits).rev() {
        let bit = value & (1 << shift) != 0;
        price += bit_price(model[node], bit);
        node = node * 2 + usize::from(bit);
    }
    price
}

fn number_price(model: &[u16], value: usize) -> u64 {
    let slot = value.ilog2() as usize;
    let mut price = tree_price(&model[..32], slot, 5);
    for shift in (0..slot).rev() {
        price += bit_price(model[32 + shift], value & (1 << shift) != 0);
    }
    price
}

fn length_price(model: &LengthModels, context: usize, length: usize, minimum: usize) -> u64 {
    let value = length - minimum;
    let mut price = bit_price(model.first[context], value >= 8);
    if value < 8 {
        price += tree_price(&model.low[context * 8..context * 8 + 8], value, 3);
    } else {
        price += bit_price(model.second[context], value >= 16);
        if value < 16 {
            price += tree_price(&model.middle[context * 8..context * 8 + 8], value - 8, 3);
        } else {
            price += number_price(
                &model.high[context * NUMBER_MODELS..(context + 1) * NUMBER_MODELS],
                value - 15,
            );
        }
    }
    price
}

fn distance_price(models: &Models, distance: usize, length: usize) -> u64 {
    let start = distance_context(length) * 32;
    let slot = distance.ilog2() as usize;
    let mut price = tree_price(&models.distance_slot[start..start + 32], slot, 5);
    for shift in (0..slot).rev() {
        price += bit_price(
            models.distance_footer[start + shift],
            distance & (1 << shift) != 0,
        );
    }
    price
}

fn literal_price(
    models: &Models,
    input: &[u8],
    pos: usize,
    reps: [usize; 4],
    previous_match: bool,
) -> u64 {
    let context = token_context(previous_match, pos);
    let mut price = bit_price(models.is_match[context], false);
    let previous = pos.checked_sub(1).map_or(0, |at| input[at]);
    let base = usize::from(previous >> 5) * LITERAL_STRIDE;
    let mut matched = reps[0] <= pos;
    let prediction = if matched { input[pos - reps[0]] } else { 0 };
    let value = input[pos];
    let mut symbol = 1usize;
    while symbol < 256 {
        let shift = 7 - symbol.ilog2() as usize;
        let predicted_bit = prediction & (1 << shift) != 0;
        let bit = value & (1 << shift) != 0;
        let index = if matched {
            base + 256 * (1 + usize::from(predicted_bit)) + symbol
        } else {
            base + symbol
        };
        price += bit_price(literal_probability(models, input, pos, index, symbol), bit);
        symbol = symbol * 2 + usize::from(bit);
        matched &= bit == predicted_bit;
    }
    price
}

fn literal_span_price(
    models: &Models,
    input: &[u8],
    pos: usize,
    length: usize,
    reps: [usize; 4],
    previous_match: bool,
) -> u64 {
    // 長大matchで価格計算自体が二次化しないよう先頭8 byteの平均を使う。
    let samples = length.min(8);
    let mut total = 0u64;
    for offset in 0..samples {
        total += literal_price(
            models,
            input,
            pos + offset,
            reps,
            previous_match && offset == 0,
        );
    }
    total.saturating_mul(length as u64) / samples as u64
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Token {
    Literal,
    ShortRep,
    Rep { index: usize, length: usize },
    Match { distance: usize, length: usize },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AbsoluteToken {
    Literal,
    Copy { distance: usize, length: usize },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ParseState {
    reps: [usize; 4],
    previous_match: bool,
}

impl Token {
    fn length(self) -> usize {
        match self {
            Self::Literal | Self::ShortRep => 1,
            Self::Rep { length, .. } | Self::Match { length, .. } => length,
        }
    }
}

fn resolve_absolute_plan(
    plan: &[Token],
    initial_state: ParseState,
    start: usize,
) -> Result<Vec<AbsoluteToken>, Error> {
    let mut resolved = Vec::new();
    resolved
        .try_reserve_exact(plan.len())
        .map_err(|_| Error::Limit)?;
    let mut reps = initial_state.reps;
    let mut position = start;
    for &token in plan {
        let (absolute, length) = match token {
            Token::Literal => (AbsoluteToken::Literal, 1),
            Token::ShortRep => (
                AbsoluteToken::Copy {
                    distance: reps[0],
                    length: 1,
                },
                1,
            ),
            Token::Rep { index, length } => {
                let distance = *reps
                    .get(index)
                    .ok_or(Error::Format("invalid speculative rep index"))?;
                move_rep(&mut reps, index);
                (AbsoluteToken::Copy { distance, length }, length)
            }
            Token::Match { distance, length } => {
                add_distance(&mut reps, distance);
                (AbsoluteToken::Copy { distance, length }, length)
            }
        };
        if let AbsoluteToken::Copy { distance, .. } = absolute
            && (distance == 0 || distance > position)
        {
            return Err(Error::Format("invalid speculative copy distance"));
        }
        resolved.push(absolute);
        position = position
            .checked_add(length)
            .ok_or(Error::Format("speculative plan position overflow"))?;
    }
    Ok(resolved)
}

fn concretize_absolute_plan(
    plan: &[AbsoluteToken],
    initial_state: ParseState,
    start: usize,
) -> Result<Vec<Token>, Error> {
    let mut concrete = Vec::new();
    concrete
        .try_reserve_exact(plan.len().checked_mul(2).ok_or(Error::Limit)?)
        .map_err(|_| Error::Limit)?;
    let mut reps = initial_state.reps;
    let mut position = start;
    for &token in plan {
        match token {
            AbsoluteToken::Literal => {
                concrete.push(Token::Literal);
                position = position.checked_add(1).ok_or(Error::Limit)?;
            }
            AbsoluteToken::Copy { distance, length } => {
                if distance == 0 || distance > position || length == 0 {
                    return Err(Error::Format("invalid speculative copy"));
                }
                if length == 1 {
                    if reps[0] == distance {
                        concrete.push(Token::ShortRep);
                    } else {
                        concrete.push(Token::Literal);
                    }
                } else if let Some(index) = reps.iter().position(|&rep| rep == distance) {
                    concrete.push(Token::Rep { index, length });
                    move_rep(&mut reps, index);
                } else if length >= 3 {
                    concrete.push(Token::Match { distance, length });
                    add_distance(&mut reps, distance);
                } else {
                    // 2 byte copyは実Repにないとwire上のMatchへ変換できない。
                    concrete.push(Token::Literal);
                    concrete.push(Token::Literal);
                }
                position = position
                    .checked_add(length)
                    .ok_or(Error::Format("speculative plan position overflow"))?;
            }
        }
    }
    Ok(concrete)
}

fn match_price(models: &Models, pos: usize, previous_match: bool, token: Token) -> u64 {
    let context = token_context(previous_match, pos);
    let mut price = bit_price(models.is_match[context], true);
    match token {
        Token::ShortRep => {
            price += bit_price(models.is_rep[context], true);
            price += bit_price(models.is_rep0[context], true);
            price += bit_price(models.is_short_rep[context], true);
        }
        Token::Rep { index, length } => {
            price += bit_price(models.is_rep[context], true);
            price += bit_price(models.is_rep0[context], index == 0);
            if index == 0 {
                price += bit_price(models.is_short_rep[context], false);
            } else {
                price += bit_price(models.is_rep1[context], index == 1);
                if index != 1 {
                    price += bit_price(models.is_rep2[context], index == 2);
                }
            }
            price += length_price(&models.rep_length, context, length, 2);
        }
        Token::Match { distance, length } => {
            price += bit_price(models.is_rep[context], false);
            price += length_price(&models.match_length, context, length, 3);
            price += distance_price(models, distance, length);
        }
        Token::Literal => unreachable!(),
    }
    price
}

fn rep_length_limited(
    input: &[u8],
    pos: usize,
    distance: usize,
    max_length: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    let _profile = Scope::sampled_rep_length(pos);
    let _expand_profile = Scope::sampled_expand_rep_length(pos);
    if distance == 0 || distance > pos {
        return Ok(0);
    }
    let limit = MAX_MATCH.min(max_length).min(input.len() - pos);
    let source = pos - distance;
    repetition_match_length(input, source, pos, limit, cancel)
}

fn rep_length(
    input: &[u8],
    pos: usize,
    distance: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    rep_length_limited(input, pos, distance, MAX_MATCH, cancel)
}

fn consider(
    best: &mut Option<(Token, u64)>,
    models: &Models,
    input: &[u8],
    pos: usize,
    reps: [usize; 4],
    previous_match: bool,
    token: Token,
) {
    let length = token.length();
    let literals = literal_span_price(models, input, pos, length, reps, previous_match);
    let token_cost = match_price(models, pos, previous_match, token);
    if token_cost >= literals {
        return;
    }
    let saving = literals - token_cost;
    match best {
        Some((current, current_saving))
            if *current_saving > saving
                || (*current_saving == saving && current.length() >= length) => {}
        _ => *best = Some((token, saving)),
    }
}

fn choose_match(
    finder: &Finder,
    models: &Models,
    input: &[u8],
    pos: usize,
    dictionary: usize,
    state: ParseState,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Option<(Token, u64)>, Error> {
    choose_match_limited(
        finder, models, input, pos, dictionary, state, MAX_MATCH, cancel,
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn choose_match_limited(
    finder: &Finder,
    models: &Models,
    input: &[u8],
    pos: usize,
    dictionary: usize,
    state: ParseState,
    max_length: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Option<(Token, u64)>, Error> {
    let max_length = MAX_MATCH
        .min(max_length)
        .min(input.len().saturating_sub(pos));
    if max_length == 0 {
        return Ok(None);
    }
    let mut best = None;
    for (index, distance) in state.reps.into_iter().enumerate() {
        if distance > dictionary {
            continue;
        }
        let length = rep_length_limited(input, pos, distance, max_length, cancel)?;
        if index == 0 && length >= 1 {
            consider(
                &mut best,
                models,
                input,
                pos,
                state.reps,
                state.previous_match,
                Token::ShortRep,
            );
        }
        if length >= 2 {
            consider(
                &mut best,
                models,
                input,
                pos,
                state.reps,
                state.previous_match,
                Token::Rep { index, length },
            );
        }
    }

    for candidate in finder
        .find_limited(input, pos, dictionary, max_length, cancel)?
        .iter()
    {
        if state.reps.contains(&candidate.distance) {
            continue;
        }
        consider(
            &mut best,
            models,
            input,
            pos,
            state.reps,
            state.previous_match,
            Token::Match {
                distance: candidate.distance,
                length: candidate.length,
            },
        );
    }
    Ok(best)
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn choose_bt_lz_token(
    block: &bt::Block,
    local: usize,
    models: &Models,
    input: &[u8],
    pos: usize,
    dictionary: usize,
    state: ParseState,
    max_length: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Option<(Token, u64)>, Error> {
    let max_length = MAX_MATCH
        .min(max_length)
        .min(input.len().saturating_sub(pos));
    if max_length == 0 {
        return Ok(None);
    }
    let mut best = None;
    for (index, distance) in state.reps.into_iter().enumerate() {
        if distance > dictionary {
            continue;
        }
        let length = rep_length_limited(input, pos, distance, max_length, cancel)?;
        if index == 0 && length >= 1 {
            consider(
                &mut best,
                models,
                input,
                pos,
                state.reps,
                state.previous_match,
                Token::ShortRep,
            );
        }
        if length >= 2 {
            consider(
                &mut best,
                models,
                input,
                pos,
                state.reps,
                state.previous_match,
                Token::Rep { index, length },
            );
        }
    }
    for candidate in bt_matches(block, local) {
        if candidate.distance > dictionary || state.reps.contains(&candidate.distance) {
            continue;
        }
        let length = candidate.length.min(max_length);
        if length < 3 {
            continue;
        }
        consider(
            &mut best,
            models,
            input,
            pos,
            state.reps,
            state.previous_match,
            Token::Match {
                distance: candidate.distance,
                length,
            },
        );
    }
    Ok(best)
}

fn move_rep(reps: &mut [usize; 4], index: usize) {
    let distance = reps[index];
    for at in (1..=index).rev() {
        reps[at] = reps[at - 1];
    }
    reps[0] = distance;
}

fn add_distance(reps: &mut [usize; 4], distance: usize) {
    reps[3] = reps[2];
    reps[2] = reps[1];
    reps[1] = reps[0];
    reps[0] = distance;
}

// beam入口で距離はMAX_INPUT、長さはMAX_MATCH、親indexは
// MAX_BEAM_PARENT_INDEX以下に制限される。repは1で始まり、通常match距離の追加か既存値の
// 並べ替えしか行わない。上のconst assertionに加え保存時もchecked変換する。
fn compact_usize(value: usize) -> u32 {
    u32::try_from(value).expect("beam value must fit in u32")
}

fn expand_u32(value: u32) -> usize {
    // usize::BITS >= 32は上のconst assertionで固定済み。
    value as usize
}

type BeamCost = u32;
const EMPTY_BEAM_COST: BeamCost = BeamCost::MAX;
const PARENT_INDEX_MASK: u32 = 0x7fff_ffff;
const PARENT_PREVIOUS_MATCH: u32 = 0x8000_0000;
const PARENT_NONE_INDEX: u32 = PARENT_INDEX_MASK;

// 1 tokenあたりの価格は、is-match/rep・長さ・距離の各木を安全側に64 bit分とする。
// tokenは最低1 byteを消費するため、最大8192 byte blockの累積でもu32へ収まる。
const MAX_BEAM_TOKEN_PRICE: u64 = 64 * 15 * 256;
const _: () = assert!(MAX_BEAM_BLOCK as u64 * MAX_BEAM_TOKEN_PRICE < BeamCost::MAX as u64);
const _: () = assert!(MAX_BEAM_PARENT_INDEX < PARENT_INDEX_MASK as usize);

#[inline(always)]
fn encode_parent(parent: Option<u32>, previous_match: bool) -> u32 {
    let index = parent.unwrap_or(PARENT_NONE_INDEX);
    debug_assert!(index <= PARENT_INDEX_MASK);
    index
        | if previous_match {
            PARENT_PREVIOUS_MATCH
        } else {
            0
        }
}

#[inline(always)]
fn parent_has_index(parent: u32) -> bool {
    (parent & PARENT_INDEX_MASK) != PARENT_NONE_INDEX
}

#[inline(always)]
fn parent_index(parent: u32) -> usize {
    expand_u32(parent & PARENT_INDEX_MASK)
}

#[inline(always)]
fn parent_previous_match(parent: u32) -> bool {
    parent & PARENT_PREVIOUS_MATCH != 0
}

#[inline(always)]
fn add_beam_cost(cost: BeamCost, price: u64) -> BeamCost {
    let price = BeamCost::try_from(price).expect("beam token price must fit in u32");
    // 実経路はconst上限でoverflowしない。番兵近傍を通すテストでは、旧u64の
    // saturating_addと同じく空slot番兵へ飽和させる。
    cost.saturating_add(price)
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CompactState {
    reps: [u32; 4],
}

impl CompactState {
    const EMPTY: Self = Self { reps: [0; 4] };

    fn from_parse(state: ParseState) -> Self {
        Self {
            reps: state.reps.map(compact_usize),
        }
    }

    #[cfg(test)]
    fn to_parse(self, previous_match: bool) -> ParseState {
        ParseState {
            reps: self.reps.map(expand_u32),
            previous_match,
        }
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CompactToken {
    Literal,
    ShortRep,
    Rep {
        index: u8,
        length: u32,
    },
    // 長さを1引いて保存し、65536もu16で表現する。短いfieldを先に置く。
    Match {
        length_minus_one: u16,
        distance: u32,
    },
}

impl CompactToken {
    fn from_token(token: Token) -> Self {
        match token {
            Token::Literal => Self::Literal,
            Token::ShortRep => Self::ShortRep,
            Token::Rep { index, length } => Self::Rep {
                index: u8::try_from(index).expect("rep index must fit in u8"),
                length: compact_usize(length),
            },
            Token::Match { distance, length } => Self::Match {
                distance: compact_usize(distance),
                length_minus_one: u16::try_from(length.checked_sub(1).expect("nonempty match"))
                    .expect("match length must fit in compact token"),
            },
        }
    }

    fn to_token(self) -> Token {
        match self {
            Self::Literal => Token::Literal,
            Self::ShortRep => Token::ShortRep,
            Self::Rep { index, length } => Token::Rep {
                index: usize::from(index),
                length: expand_u32(length),
            },
            Self::Match {
                distance,
                length_minus_one,
            } => Token::Match {
                distance: expand_u32(distance),
                length: usize::from(length_minus_one) + 1,
            },
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BeamNode {
    cost: BeamCost,
    state: CompactState,
    parent: u32,
    token: CompactToken,
}

impl BeamNode {
    const EMPTY: Self = Self {
        cost: EMPTY_BEAM_COST,
        state: CompactState::EMPTY,
        parent: PARENT_NONE_INDEX,
        token: CompactToken::Literal,
    };

    #[inline(always)]
    fn previous_match(self) -> bool {
        parent_previous_match(self.parent)
    }
}

// 展開中に参照する費用・rep状態・直前token種別と、終端からの復元だけで
// 使うtoken本体を分離した幅2専用の研究backend。通常のBeamNodeは参照実装
// とprofile経路に残し、出力・親index・tie規則は共通化する。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BeamActiveNode {
    cost: BeamCost,
    state: CompactState,
    parent: u32,
}

impl BeamActiveNode {
    #[inline(always)]
    fn previous_match(self) -> bool {
        parent_previous_match(self.parent)
    }
}

#[derive(Clone, Copy)]
struct BeamActiveCandidate {
    node: BeamActiveNode,
    token: CompactToken,
}

struct BeamActiveStorage {
    nodes: Vec<BeamActiveNode>,
    tokens: Vec<CompactToken>,
}

impl BeamActiveStorage {
    fn new(length: usize) -> Result<Self, Error> {
        Ok(Self {
            nodes: buffer(
                length,
                BeamActiveNode {
                    cost: EMPTY_BEAM_COST,
                    state: CompactState::EMPTY,
                    parent: PARENT_NONE_INDEX,
                },
            )?,
            tokens: buffer(length, CompactToken::Literal)?,
        })
    }

    #[inline(always)]
    fn active(&self, index: usize) -> BeamActiveNode {
        debug_assert!(index < self.nodes.len());
        // SAFETY: planner bucket/terminal indices are derived from the checked storage length.
        unsafe { *self.nodes.get_unchecked(index) }
    }

    #[inline(always)]
    fn token(&self, index: usize) -> CompactToken {
        debug_assert!(index < self.tokens.len());
        // SAFETY: every token index comes from a stored parent edge in the same storage.
        unsafe { *self.tokens.get_unchecked(index) }
    }

    #[inline(always)]
    #[cfg(test)]
    fn insert_lazy<F>(&mut self, start: usize, end: usize, cost: BeamCost, make: F)
    where
        F: FnOnce() -> BeamActiveCandidate,
    {
        let (worst_index, worst_cost) = self.nodes[start..end]
            .iter()
            .enumerate()
            .max_by_key(|(_, node)| node.cost)
            .map(|(index, node)| (index, node.cost))
            .unwrap();
        if worst_cost != EMPTY_BEAM_COST && cost >= worst_cost {
            return;
        }

        let candidate = make();
        debug_assert_eq!(candidate.node.cost, cost);
        let target = if let Some((index, _)) =
            self.nodes[start..end].iter().enumerate().find(|(_, node)| {
                node.cost != EMPTY_BEAM_COST
                    && node.state == candidate.node.state
                    && node.previous_match() == candidate.node.previous_match()
            }) {
            if cost < self.nodes[start + index].cost {
                Some(start + index)
            } else {
                None
            }
        } else if let Some((index, _)) = self.nodes[start..end]
            .iter()
            .enumerate()
            .find(|(_, node)| node.cost == EMPTY_BEAM_COST)
        {
            Some(start + index)
        } else if cost < worst_cost {
            Some(start + worst_index)
        } else {
            None
        };
        if let Some(index) = target {
            self.nodes[index] = candidate.node;
            self.tokens[index] = candidate.token;
        }
    }

    #[inline(always)]
    fn insert_lazy_width2<F>(&mut self, start: usize, cost: BeamCost, make: F)
    where
        F: FnOnce() -> BeamActiveCandidate,
    {
        debug_assert!(start + 1 < self.nodes.len());
        // SAFETY: active width2 callers pass the start of a two-slot bucket.
        let (first, second) = unsafe {
            (
                *self.nodes.get_unchecked(start),
                *self.nodes.get_unchecked(start + 1),
            )
        };
        // max_by_keyは同costなら最後のslotを返す。
        let (worst_index, worst_cost) = if first.cost > second.cost {
            (start, first.cost)
        } else {
            (start + 1, second.cost)
        };
        if worst_cost != EMPTY_BEAM_COST && cost >= worst_cost {
            return;
        }

        let candidate = make();
        debug_assert_eq!(candidate.node.cost, cost);
        let same_state = |node: BeamActiveNode| {
            node.cost != EMPTY_BEAM_COST
                && node.state == candidate.node.state
                && node.previous_match() == candidate.node.previous_match()
        };
        let target = if same_state(first) {
            (cost < first.cost).then_some(start)
        } else if same_state(second) {
            (cost < second.cost).then_some(start + 1)
        } else if first.cost == EMPTY_BEAM_COST {
            Some(start)
        } else if second.cost == EMPTY_BEAM_COST {
            Some(start + 1)
        } else if cost < worst_cost {
            Some(worst_index)
        } else {
            None
        };
        if let Some(index) = target {
            // SAFETY: target is one of the two validated bucket slots above.
            unsafe {
                *self.nodes.get_unchecked_mut(index) = candidate.node;
                *self.tokens.get_unchecked_mut(index) = candidate.token;
            }
        }
    }
}

#[derive(Clone, Copy)]
struct BeamParent {
    index: usize,
    compact_index: u32,
    cost: BeamCost,
    compact_state: CompactState,
    previous_match: bool,
}

impl BeamParent {
    fn new(index: usize, node: BeamNode) -> Self {
        Self {
            index,
            compact_index: compact_usize(index),
            cost: node.cost,
            compact_state: node.state,
            previous_match: node.previous_match(),
        }
    }

    #[inline(always)]
    fn from_active(index: usize, node: BeamActiveNode) -> Self {
        Self {
            index,
            compact_index: compact_usize(index),
            cost: node.cost,
            compact_state: node.state,
            previous_match: node.previous_match(),
        }
    }
}

struct BeamContext<'a> {
    models: &'a Models,
    distance_table: Option<&'a DistancePriceTable>,
    input: &'a [u8],
    start: usize,
    end: usize,
    width: usize,
}

#[derive(Clone, Copy)]
struct BeamParseConfig {
    dictionary: usize,
    initial_state: ParseState,
    cache_prices: bool,
    width: usize,
    block: usize,
    model: BeamModel,
    matches: BeamMatches,
    rep_diverse_third_parent: bool,
    fixed_rep_history: bool,
}

const REP_DIVERSE_THIRD_PARENT_MAX_GAP: BeamCost = 128;

/// W3の親を価格順に2つ残し、第3親だけRep履歴の多様性と価格差で制限する。
/// 同価格では既存bucket順を維持する。
fn rep_diverse_parent_mask(bucket: &[BeamNode]) -> [bool; 3] {
    debug_assert_eq!(bucket.len(), 3);
    let mut ranked = [0usize, 1, 2];
    ranked.sort_by_key(|&slot| bucket[slot].cost);

    let mut selected = [false; 3];
    let best = bucket[ranked[0]];
    if best.cost == EMPTY_BEAM_COST {
        return selected;
    }
    selected[ranked[0]] = true;

    let second = bucket[ranked[1]];
    if second.cost == EMPTY_BEAM_COST {
        return selected;
    }
    selected[ranked[1]] = true;

    let third = bucket[ranked[2]];
    if third.cost != EMPTY_BEAM_COST
        && third.cost - best.cost <= REP_DIVERSE_THIRD_PARENT_MAX_GAP
        && third.state.reps != best.state.reps
        && third.state.reps != second.state.reps
    {
        selected[ranked[2]] = true;
    }
    selected
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DistancePriceEntry {
    distance: u32,
    context: u8,
    price: u32,
    used: bool,
}

const DISTANCE_PRICE_SLOTS: usize = 32;
const DISTANCE_PRICE_NIBBLES: usize = DISTANCE_PRICE_SLOTS.div_ceil(4);
const DISTANCE_PRICE_NIBBLE_VALUES: usize = 16;
type CachedDistanceBase = u32;
type CachedDistanceDelta = i16;
const _: () = assert!((5 + 31) * 15 * 256 < CachedDistanceBase::MAX as usize);
const _: () = assert!(4 * 15 * 256 < CachedDistanceDelta::MAX as usize);
const DISTANCE_PRICE_TABLE_MEMORY: usize = DISTANCE_CONTEXTS
    * (DISTANCE_PRICE_SLOTS * std::mem::size_of::<CachedDistanceBase>()
        + DISTANCE_PRICE_NIBBLES
            * DISTANCE_PRICE_NIBBLE_VALUES
            * std::mem::size_of::<CachedDistanceDelta>());

struct DistancePriceTable {
    base: Vec<CachedDistanceBase>,
    nibble_delta: Vec<CachedDistanceDelta>,
}

impl DistancePriceTable {
    fn new(models: &Models) -> Result<Self, Error> {
        let mut result = Self {
            base: buffer(
                DISTANCE_CONTEXTS * DISTANCE_PRICE_SLOTS,
                CachedDistanceBase::MAX,
            )?,
            nibble_delta: buffer(
                DISTANCE_CONTEXTS * DISTANCE_PRICE_NIBBLES * DISTANCE_PRICE_NIBBLE_VALUES,
                0,
            )?,
        };
        for context in 0..DISTANCE_CONTEXTS {
            let start = context * DISTANCE_PRICE_SLOTS;
            for slot in 0..DISTANCE_PRICE_SLOTS {
                let mut price = tree_price(
                    &models.distance_slot[start..start + DISTANCE_PRICE_SLOTS],
                    slot,
                    5,
                );
                for shift in 0..slot {
                    price += bit_price(models.distance_footer[start + shift], false);
                }
                result.base[start + slot] = CachedDistanceBase::try_from(price)
                    .expect("distance base price must fit its proven bound");
            }
            for nibble in 0..DISTANCE_PRICE_NIBBLES {
                for value in 0..DISTANCE_PRICE_NIBBLE_VALUES {
                    let mut delta = 0i64;
                    for bit in 0..4 {
                        if value & (1 << bit) == 0 {
                            continue;
                        }
                        let shift = nibble * 4 + bit;
                        let probability = models.distance_footer[start + shift];
                        delta += bit_price(probability, true) as i64
                            - bit_price(probability, false) as i64;
                    }
                    let index = (context * DISTANCE_PRICE_NIBBLES + nibble)
                        * DISTANCE_PRICE_NIBBLE_VALUES
                        + value;
                    result.nibble_delta[index] = CachedDistanceDelta::try_from(delta)
                        .expect("distance nibble delta must fit its proven bound");
                }
            }
        }
        Ok(result)
    }

    fn price(&self, distance: usize, length: usize) -> u64 {
        let context = distance_context(length);
        let slot = distance.ilog2() as usize;
        let mut price = i64::from(self.base[context * DISTANCE_PRICE_SLOTS + slot]);
        let lower = distance & ((1usize << slot) - 1);
        for nibble in 0..slot.div_ceil(4) {
            let value = (lower >> (nibble * 4)) & (DISTANCE_PRICE_NIBBLE_VALUES - 1);
            let index =
                (context * DISTANCE_PRICE_NIBBLES + nibble) * DISTANCE_PRICE_NIBBLE_VALUES + value;
            price += i64::from(self.nibble_delta[index]);
        }
        u64::try_from(price).expect("distance price must remain nonnegative")
    }
}

impl DistancePriceEntry {
    const EMPTY: Self = Self {
        distance: 0,
        context: 0,
        price: 0,
        used: false,
    };
}

struct DistancePriceCache {
    entries: [DistancePriceEntry; 64],
}

impl DistancePriceCache {
    fn new() -> Self {
        Self {
            entries: [DistancePriceEntry::EMPTY; 64],
        }
    }

    fn price(
        &mut self,
        models: &Models,
        table: Option<&DistancePriceTable>,
        distance: usize,
        length: usize,
    ) -> u64 {
        let context = distance_context(length);
        let first = distance
            .wrapping_mul(0x9e37_79b1)
            .wrapping_add(context * 0x85eb_ca6b)
            & (self.entries.len() - 1);
        // 衝突時のlookupを4枠に制限する。missは正確な価格を再計算して置換する。
        for offset in 0..4 {
            let index = (first + offset) & (self.entries.len() - 1);
            let entry = self.entries[index];
            if entry.used
                && entry.distance == compact_usize(distance)
                && usize::from(entry.context) == context
            {
                return u64::from(entry.price);
            }
            if !entry.used {
                let price = table.map_or_else(
                    || distance_price(models, distance, length),
                    |table| table.price(distance, length),
                );
                self.entries[index] = DistancePriceEntry {
                    distance: compact_usize(distance),
                    context: u8::try_from(context).expect("distance context must fit in u8"),
                    price: u32::try_from(price).expect("distance price must fit in u32"),
                    used: true,
                };
                return price;
            }
        }
        let price = table.map_or_else(
            || distance_price(models, distance, length),
            |table| table.price(distance, length),
        );
        self.entries[first] = DistancePriceEntry {
            distance: compact_usize(distance),
            context: u8::try_from(context).expect("distance context must fit in u8"),
            price: u32::try_from(price).expect("distance price must fit in u32"),
            used: true,
        };
        price
    }
}

#[derive(Clone, Copy)]
struct RepLengthEntry {
    distance: usize,
    length: usize,
}

impl RepLengthEntry {
    const EMPTY: Self = Self {
        distance: 0,
        length: 0,
    };
}

struct RepLengthCache<const CAPACITY: usize = 16> {
    entries: [RepLengthEntry; CAPACITY],
    used: usize,
}

impl<const CAPACITY: usize> RepLengthCache<CAPACITY> {
    fn new() -> Self {
        Self {
            entries: [RepLengthEntry::EMPTY; CAPACITY],
            used: 0,
        }
    }

    #[inline(always)]
    fn length(
        &mut self,
        input: &[u8],
        pos: usize,
        distance: usize,
        maximum: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        if let Some(entry) = self.entries[..self.used]
            .iter()
            .find(|entry| entry.distance == distance)
        {
            return Ok(entry.length);
        }
        let length = rep_length_limited(input, pos, distance, maximum, cancel)?;
        if self.used < self.entries.len() {
            self.entries[self.used] = RepLengthEntry { distance, length };
            self.used += 1;
        }
        Ok(length)
    }

    #[inline(always)]
    fn length_fast_zero(
        &mut self,
        input: &[u8],
        pos: usize,
        distance: usize,
        maximum: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        // 幅4では1位置の異なるRep距離がcache容量16件を超えない。
        // 先頭byte不一致の0長を保存せず、線形lookupと一致比較を避ける。
        if distance != 0
            && distance <= pos
            && maximum != 0
            && pos < input.len()
            && input[pos - distance] != input[pos]
        {
            return Ok(0);
        }
        self.length(input, pos, distance, maximum, cancel)
    }
}

const LITERAL_PRICE_KEYS: usize = 10;
const UNMATCHED_LITERAL_PRICE_KEY: usize = 9;
const LITERAL_BYTE_CONTEXTS: usize = 8;
const LITERAL_PAYLOAD_CACHE_ENTRIES: usize =
    LITERAL_BYTE_CONTEXTS * (u8::MAX as usize + 1) * LITERAL_PRICE_KEYS;
type CachedLiteralPrice = u16;
const _: () = assert!(8 * 15 * 256 < CachedLiteralPrice::MAX);

fn literal_price_key(input: &[u8], pos: usize, rep0: usize) -> usize {
    match pos.checked_sub(rep0) {
        Some(source) => (input[source] ^ input[pos]).leading_zeros() as usize,
        None => UNMATCHED_LITERAL_PRICE_KEY,
    }
}

fn literal_payload_cache_index(input: &[u8], pos: usize, key: usize) -> usize {
    let previous = pos.checked_sub(1).map_or(0, |at| input[at]);
    (usize::from(previous >> 5) * (u8::MAX as usize + 1) + usize::from(input[pos]))
        * LITERAL_PRICE_KEYS
        + key
}

fn literal_payload_price(models: &Models, input: &[u8], pos: usize, key: usize) -> u64 {
    debug_assert!(key < LITERAL_PRICE_KEYS);
    let previous = pos.checked_sub(1).map_or(0, |at| input[at]);
    let base = usize::from(previous >> 5) * LITERAL_STRIDE;
    let value = input[pos];
    let mut symbol = 1usize;
    let mut price = 0u64;
    for depth in 0..8usize {
        let bit = value & (1 << (7 - depth)) != 0;
        let index = if key != UNMATCHED_LITERAL_PRICE_KEY && depth <= key {
            // key<8ではdepth==keyが最初の不一致。key==8は8 bitすべて一致する。
            let predicted_bit = bit ^ (key < 8 && depth == key);
            base + 256 * (1 + usize::from(predicted_bit)) + symbol
        } else {
            base + symbol
        };
        price += bit_price(literal_probability(models, input, pos, index, symbol), bit);
        symbol = symbol * 2 + usize::from(bit);
    }
    price
}

struct LiteralPriceCache {
    payload: Vec<CachedLiteralPrice>,
}

impl LiteralPriceCache {
    fn new(enabled: bool) -> Result<Self, Error> {
        Ok(Self {
            payload: if enabled {
                buffer(LITERAL_PAYLOAD_CACHE_ENTRIES, CachedLiteralPrice::MAX)?
            } else {
                Vec::new()
            },
        })
    }

    fn price(
        &mut self,
        enabled: bool,
        models: &Models,
        input: &[u8],
        pos: usize,
        reps: [usize; 4],
        previous_match: bool,
    ) -> u64 {
        if !enabled {
            return literal_price(models, input, pos, reps, previous_match);
        }

        self.cached_price(models, input, pos, reps, previous_match)
    }

    #[inline(always)]
    fn cached_price(
        &mut self,
        models: &Models,
        input: &[u8],
        pos: usize,
        reps: [usize; 4],
        previous_match: bool,
    ) -> u64 {
        let context = token_context(previous_match, pos);
        let is_match = bit_price(models.is_match[context], false);
        let key = literal_price_key(input, pos, reps[0]);
        let payload_index = literal_payload_cache_index(input, pos, key);
        if self.payload[payload_index] == CachedLiteralPrice::MAX {
            // 共通prefix長からmatched木と通常木の境界を直接復元する。
            self.payload[payload_index] =
                CachedLiteralPrice::try_from(literal_payload_price(models, input, pos, key))
                    .expect("literal payload price must fit its proven bound");
        }
        is_match + u64::from(self.payload[payload_index])
    }
}

type CachedLengthPrice = u32;
// 長さ符号は分岐2 bit、slot木5 bit、最大log2(block) bit。
// 各bitは最大15*256。空値のu32::MAXへ到達しない上限を固定する。
const _: () = assert!((7 + MAX_BEAM_BLOCK.ilog2()) * 15 * 256 < CachedLengthPrice::MAX);

struct BeamPriceCache {
    enabled: bool,
    normal_base: [u64; TOKEN_CONTEXTS],
    short_rep: [u64; TOKEN_CONTEXTS],
    rep_base: [[u64; 4]; TOKEN_CONTEXTS],
    match_length: Vec<CachedLengthPrice>,
    rep_length: Vec<CachedLengthPrice>,
    stride: usize,
}

impl BeamPriceCache {
    fn new(models: &Models, enabled: bool, block: usize) -> Result<Self, Error> {
        let stride = block.checked_add(1).ok_or(Error::Limit)?;
        let entries = TOKEN_CONTEXTS.checked_mul(stride).ok_or(Error::Limit)?;
        let mut result = Self {
            enabled,
            normal_base: [0; TOKEN_CONTEXTS],
            short_rep: [0; TOKEN_CONTEXTS],
            rep_base: [[0; 4]; TOKEN_CONTEXTS],
            match_length: buffer(entries, CachedLengthPrice::MAX)?,
            rep_length: buffer(entries, CachedLengthPrice::MAX)?,
            stride,
        };
        for context in 0..TOKEN_CONTEXTS {
            let match_bit = bit_price(models.is_match[context], true);
            result.normal_base[context] = match_bit + bit_price(models.is_rep[context], false);
            result.short_rep[context] = match_bit
                + bit_price(models.is_rep[context], true)
                + bit_price(models.is_rep0[context], true)
                + bit_price(models.is_short_rep[context], true);
            for index in 0..4 {
                let mut price = match_bit
                    + bit_price(models.is_rep[context], true)
                    + bit_price(models.is_rep0[context], index == 0);
                if index == 0 {
                    price += bit_price(models.is_short_rep[context], false);
                } else {
                    price += bit_price(models.is_rep1[context], index == 1);
                    if index != 1 {
                        price += bit_price(models.is_rep2[context], index == 2);
                    }
                }
                result.rep_base[context][index] = price;
            }
        }
        Ok(result)
    }

    fn length(
        entries: &mut [CachedLengthPrice],
        stride: usize,
        model: &LengthModels,
        context: usize,
        length: usize,
        minimum: usize,
    ) -> u64 {
        let index = context * stride + length;
        if entries[index] == CachedLengthPrice::MAX {
            entries[index] =
                CachedLengthPrice::try_from(length_price(model, context, length, minimum))
                    .expect("beam length price must fit its proven bound");
        }
        u64::from(entries[index])
    }

    #[cfg(test)]
    fn price(
        &mut self,
        models: &Models,
        distance_cache: &mut DistancePriceCache,
        distance_table: Option<&DistancePriceTable>,
        pos: usize,
        previous_match: bool,
        token: Token,
    ) -> u64 {
        if !self.enabled {
            return match_price(models, pos, previous_match, token);
        }
        let context = token_context(previous_match, pos);
        match token {
            Token::ShortRep => self.short_rep[context],
            Token::Rep { index, length } => {
                self.rep_base[context][index]
                    + Self::length(
                        &mut self.rep_length,
                        self.stride,
                        &models.rep_length,
                        context,
                        length,
                        2,
                    )
            }
            Token::Match { distance, length } => {
                self.normal_base[context]
                    + Self::length(
                        &mut self.match_length,
                        self.stride,
                        &models.match_length,
                        context,
                        length,
                        3,
                    )
                    + distance_cache.price(models, distance_table, distance, length)
            }
            Token::Literal => unreachable!(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[inline(always)]
    fn match_token_price(
        &mut self,
        models: &Models,
        distance_cache: &mut DistancePriceCache,
        distance_table: Option<&DistancePriceTable>,
        pos: usize,
        previous_match: bool,
        distance: usize,
        length: usize,
    ) -> u64 {
        if !self.enabled {
            return match_price(
                models,
                pos,
                previous_match,
                Token::Match { distance, length },
            );
        }
        self.match_token_price_cached(
            models,
            distance_cache,
            distance_table,
            pos,
            previous_match,
            distance,
            length,
        )
    }

    #[allow(clippy::too_many_arguments)]
    #[inline(always)]
    fn match_token_price_cached(
        &mut self,
        models: &Models,
        distance_cache: &mut DistancePriceCache,
        distance_table: Option<&DistancePriceTable>,
        pos: usize,
        previous_match: bool,
        distance: usize,
        length: usize,
    ) -> u64 {
        let context = token_context(previous_match, pos);
        self.normal_base[context]
            + Self::length(
                &mut self.match_length,
                self.stride,
                &models.match_length,
                context,
                length,
                3,
            )
            + distance_cache.price(models, distance_table, distance, length)
    }
}

fn advance_state(mut state: CompactState, token: CompactToken) -> CompactState {
    match token {
        CompactToken::Rep { index, .. } => {
            let index = usize::from(index);
            let distance = state.reps[index];
            for at in (1..=index).rev() {
                state.reps[at] = state.reps[at - 1];
            }
            state.reps[0] = distance;
        }
        CompactToken::Match { distance, .. } => {
            state.reps[3] = state.reps[2];
            state.reps[2] = state.reps[1];
            state.reps[1] = state.reps[0];
            state.reps[0] = distance;
        }
        CompactToken::Literal | CompactToken::ShortRep => {}
    }
    state
}

#[cfg(test)]
fn insert_beam(bucket: &mut [BeamNode], candidate: BeamNode) {
    // max_by_keyは同価格なら最後の要素を返す。従来の置換tie規則を保ったまま、
    // 満杯bucketで改善不能な候補だけstate比較前に捨てる。
    let (worst_index, worst_cost) = bucket
        .iter()
        .enumerate()
        .max_by_key(|(_, node)| node.cost)
        .map(|(index, node)| (index, node.cost))
        .unwrap();
    if worst_cost != EMPTY_BEAM_COST && candidate.cost >= worst_cost {
        return;
    }
    if let Some(existing) = bucket.iter_mut().find(|node| {
        node.cost != EMPTY_BEAM_COST
            && node.state == candidate.state
            && node.previous_match() == candidate.previous_match()
    }) {
        if candidate.cost < existing.cost {
            *existing = candidate;
        }
        return;
    }
    if let Some(empty) = bucket.iter_mut().find(|node| node.cost == EMPTY_BEAM_COST) {
        *empty = candidate;
        return;
    }
    if candidate.cost < worst_cost {
        bucket[worst_index] = candidate;
    }
}

macro_rules! insert_beam_lazy {
    ($bucket:expr, $cost:expr, $candidate:expr $(,)?) => {{
        let bucket = $bucket;
        let cost = $cost;
        let (worst_index, worst_cost) = bucket
            .iter()
            .enumerate()
            .max_by_key(|(_, node)| node.cost)
            .map(|(index, node)| (index, node.cost))
            .unwrap();
        if worst_cost == EMPTY_BEAM_COST || cost < worst_cost {
            let candidate = $candidate;
            debug_assert_eq!(candidate.cost, cost);
            if let Some(existing) = bucket.iter_mut().find(|node| {
                node.cost != EMPTY_BEAM_COST
                    && node.state == candidate.state
                    && node.previous_match() == candidate.previous_match()
            }) {
                if candidate.cost < existing.cost {
                    *existing = candidate;
                }
            } else if let Some(empty) = bucket.iter_mut().find(|node| node.cost == EMPTY_BEAM_COST)
            {
                *empty = candidate;
            } else if candidate.cost < worst_cost {
                bucket[worst_index] = candidate;
            }
        }
    }};
}

#[inline(always)]
fn beam_child_with_cost(
    node: BeamParent,
    cost: BeamCost,
    state: CompactState,
    token: CompactToken,
) -> BeamNode {
    BeamNode {
        cost,
        state,
        parent: encode_parent(
            Some(node.compact_index),
            !matches!(token, CompactToken::Literal),
        ),
        token,
    }
}

#[cfg(test)]
fn push_beam_edge_reference(
    storage: &mut [BeamNode],
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &mut BeamPriceCache,
    distance_prices: &mut DistancePriceCache,
    literal_prices: &mut LiteralPriceCache,
    token: Token,
) {
    let pos = context.start + node.index / context.width;
    let end = pos + token.length();
    if end > context.end {
        return;
    }
    let price = if matches!(token, Token::Literal) {
        literal_prices.price(
            prices.enabled,
            context.models,
            context.input,
            pos,
            node.compact_state.reps.map(expand_u32),
            node.previous_match,
        )
    } else {
        prices.price(
            context.models,
            distance_prices,
            context.distance_table,
            pos,
            node.previous_match,
            token,
        )
    };
    let compact_token = CompactToken::from_token(token);
    let candidate = BeamNode {
        cost: add_beam_cost(node.cost, price),
        state: advance_state(node.compact_state, compact_token),
        parent: encode_parent(
            Some(node.compact_index),
            !matches!(compact_token, CompactToken::Literal),
        ),
        token: compact_token,
    };
    let local_end = end - context.start;
    insert_beam(
        &mut storage[local_end * context.width..(local_end + 1) * context.width],
        candidate,
    );
}

fn push_literal_edge(
    storage: &mut [BeamNode],
    node: BeamParent,
    context: &BeamContext<'_>,
    cache_prices: bool,
    literal_prices: &mut LiteralPriceCache,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price = literal_prices.price(
        cache_prices,
        context.models,
        context.input,
        pos,
        node.compact_state.reps.map(expand_u32),
        node.previous_match,
    );
    let cost = add_beam_cost(node.cost, price);
    let child_state = node.compact_state;
    insert_beam_lazy!(
        &mut storage[(local + 1) * context.width..(local + 2) * context.width],
        cost,
        beam_child_with_cost(node, cost, child_state, CompactToken::Literal),
    );
}

fn push_short_rep_edge(
    storage: &mut [BeamNode],
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &BeamPriceCache,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price = if prices.enabled {
        prices.short_rep[token_context(node.previous_match, pos)]
    } else {
        match_price(context.models, pos, node.previous_match, Token::ShortRep)
    };
    let cost = add_beam_cost(node.cost, price);
    let child_state = node.compact_state;
    insert_beam_lazy!(
        &mut storage[(local + 1) * context.width..(local + 2) * context.width],
        cost,
        beam_child_with_cost(node, cost, child_state, CompactToken::ShortRep),
    );
}

fn push_match_edge(
    storage: &mut [BeamNode],
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &mut BeamPriceCache,
    distance_prices: &mut DistancePriceCache,
    distance: usize,
    length: usize,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    if pos + length > context.end {
        return;
    }
    let price = prices.match_token_price(
        context.models,
        distance_prices,
        context.distance_table,
        pos,
        node.previous_match,
        distance,
        length,
    );
    let cost = add_beam_cost(node.cost, price);
    insert_beam_lazy!(
        &mut storage[(local + length) * context.width..(local + length + 1) * context.width],
        cost,
        {
            let compact_distance = compact_usize(distance);
            let compact_token = CompactToken::Match {
                distance: compact_distance,
                length_minus_one: u16::try_from(length.checked_sub(1).expect("nonempty match"))
                    .expect("match length must fit in compact token"),
            };
            let mut child_state = node.compact_state;
            child_state.reps[3] = child_state.reps[2];
            child_state.reps[2] = child_state.reps[1];
            child_state.reps[1] = child_state.reps[0];
            child_state.reps[0] = compact_distance;
            beam_child_with_cost(node, cost, child_state, compact_token)
        },
    );
}

#[inline(always)]
fn push_rep_edges(
    storage: &mut [BeamNode],
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &mut BeamPriceCache,
    index: usize,
    lengths: &[usize],
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price_context = token_context(node.previous_match, pos);
    let compact_index = u8::try_from(index).expect("rep index must fit in u8");
    // Repの子stateは選んだ履歴indexだけで決まり、長さには依存しない。
    let child_state = advance_state(
        node.compact_state,
        CompactToken::Rep {
            index: compact_index,
            length: 2,
        },
    );
    let base = prices.rep_base[price_context][index];

    if prices.enabled {
        for &length in lengths {
            let end = pos + length;
            if end > context.end {
                continue;
            }
            let price = base
                + BeamPriceCache::length(
                    &mut prices.rep_length,
                    prices.stride,
                    &context.models.rep_length,
                    price_context,
                    length,
                    2,
                );
            let cost = add_beam_cost(node.cost, price);
            insert_beam_lazy!(
                &mut storage
                    [(local + length) * context.width..(local + length + 1) * context.width],
                cost,
                {
                    let compact_token = CompactToken::Rep {
                        index: compact_index,
                        length: compact_usize(length),
                    };
                    beam_child_with_cost(node, cost, child_state, compact_token)
                },
            );
        }
    } else {
        for &length in lengths {
            let end = pos + length;
            if end > context.end {
                continue;
            }
            let token = Token::Rep { index, length };
            let price = match_price(context.models, pos, node.previous_match, token);
            let cost = add_beam_cost(node.cost, price);
            insert_beam_lazy!(
                &mut storage
                    [(local + length) * context.width..(local + length + 1) * context.width],
                cost,
                {
                    let compact_token = CompactToken::from_token(token);
                    beam_child_with_cost(node, cost, child_state, compact_token)
                },
            );
        }
    }
}

#[inline(always)]
fn beam_active_child_with_cost(
    node: BeamParent,
    cost: BeamCost,
    state: CompactState,
    token: CompactToken,
) -> BeamActiveCandidate {
    BeamActiveCandidate {
        node: BeamActiveNode {
            cost,
            state,
            parent: encode_parent(
                Some(node.compact_index),
                !matches!(token, CompactToken::Literal),
            ),
        },
        token,
    }
}

#[inline(always)]
fn push_literal_edge_active(
    storage: &mut BeamActiveStorage,
    node: BeamParent,
    context: &BeamContext<'_>,
    literal_prices: &mut LiteralPriceCache,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price = literal_prices.cached_price(
        context.models,
        context.input,
        pos,
        node.compact_state.reps.map(expand_u32),
        node.previous_match,
    );
    let cost = add_beam_cost(node.cost, price);
    let child_state = node.compact_state;
    storage.insert_lazy_width2((local + 1) * context.width, cost, || {
        beam_active_child_with_cost(node, cost, child_state, CompactToken::Literal)
    });
}

#[inline(always)]
fn push_short_rep_edge_active(
    storage: &mut BeamActiveStorage,
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &BeamPriceCache,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price = prices.short_rep[token_context(node.previous_match, pos)];
    let cost = add_beam_cost(node.cost, price);
    let child_state = node.compact_state;
    storage.insert_lazy_width2((local + 1) * context.width, cost, || {
        beam_active_child_with_cost(node, cost, child_state, CompactToken::ShortRep)
    });
}

#[inline(always)]
fn push_match_edge_active(
    storage: &mut BeamActiveStorage,
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &mut BeamPriceCache,
    distance_prices: &mut DistancePriceCache,
    distance: usize,
    length: usize,
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    if pos + length > context.end {
        return;
    }
    let price = prices.match_token_price_cached(
        context.models,
        distance_prices,
        context.distance_table,
        pos,
        node.previous_match,
        distance,
        length,
    );
    let cost = add_beam_cost(node.cost, price);
    storage.insert_lazy_width2((local + length) * context.width, cost, || {
        let compact_distance = compact_usize(distance);
        let compact_token = CompactToken::Match {
            distance: compact_distance,
            length_minus_one: u16::try_from(length.checked_sub(1).expect("nonempty match"))
                .expect("match length must fit in compact token"),
        };
        let mut child_state = node.compact_state;
        child_state.reps[3] = child_state.reps[2];
        child_state.reps[2] = child_state.reps[1];
        child_state.reps[1] = child_state.reps[0];
        child_state.reps[0] = compact_distance;
        beam_active_child_with_cost(node, cost, child_state, compact_token)
    });
}

#[inline(always)]
fn push_rep_edges_active(
    storage: &mut BeamActiveStorage,
    node: BeamParent,
    context: &BeamContext<'_>,
    prices: &mut BeamPriceCache,
    index: usize,
    lengths: &[usize],
) {
    let local = node.index / context.width;
    let pos = context.start + local;
    let price_context = token_context(node.previous_match, pos);
    let compact_index = u8::try_from(index).expect("rep index must fit in u8");
    let child_state = advance_state(
        node.compact_state,
        CompactToken::Rep {
            index: compact_index,
            length: 2,
        },
    );
    let base = prices.rep_base[price_context][index];

    for &length in lengths {
        let end = pos + length;
        if end > context.end {
            continue;
        }
        let price = base
            + BeamPriceCache::length(
                &mut prices.rep_length,
                prices.stride,
                &context.models.rep_length,
                price_context,
                length,
                2,
            );
        let cost = add_beam_cost(node.cost, price);
        storage.insert_lazy_width2((local + length) * context.width, cost, || {
            let compact_token = CompactToken::Rep {
                index: compact_index,
                length: compact_usize(length),
            };
            beam_active_child_with_cost(node, cost, child_state, compact_token)
        });
    }
}

struct BeamActiveCaches {
    prices: BeamPriceCache,
    literal_prices: LiteralPriceCache,
    distance_prices: DistancePriceCache,
}

fn beam_plan_bt4_active(
    candidate_block: &bt::Block,
    config: BeamParseConfig,
    boundaries: &[u64],
    context: &BeamContext<'_>,
    storage_length: usize,
    caches: BeamActiveCaches,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let BeamActiveCaches {
        mut prices,
        mut literal_prices,
        mut distance_prices,
    } = caches;
    let measure_greedy = super::profile::diagnostics_enabled();
    if measure_greedy {
        super::profile::record_active_width2_block();
    }
    let block_length = context.end - context.start;
    let mut greedy_screen = super::profile::GreedySkipBlock {
        input_bytes: block_length,
        ..Default::default()
    };
    let mut covered_until = [0usize; 6];
    let mut storage = BeamActiveStorage::new(storage_length)?;
    storage.nodes[0] = BeamActiveNode {
        cost: 0,
        state: CompactState::from_parse(config.initial_state),
        parent: encode_parent(None, config.initial_state.previous_match),
    };
    {
        let _profile = Scope::new(Phase::ExpandNodes);
        for local in 0..block_length {
            check(cancel)?;
            let first_node = storage.active(local * 2);
            let second_node = storage.active(local * 2 + 1);
            let first = first_node.cost;
            let second = second_node.cost;
            if !measure_greedy && first == EMPTY_BEAM_COST && second == EMPTY_BEAM_COST {
                continue;
            }
            let pos = context.start + local;
            let remaining = context.end - pos;
            let at_boundary = boundaries[local / 64] & (1u64 << (local % 64)) != 0;
            // 幅2の1位置では親2×履歴4を超える異なる距離を参照しない。
            let mut rep_lengths = RepLengthCache::<8>::new();
            let normal_parent = usize::from(second < first);
            let matches = bt_frontier(
                candidate_block,
                local,
                context.end - pos,
                context.models,
                context.distance_table,
            );
            let longest = matches.iter().last();
            let mut longest_available =
                longest.map_or(0, |candidate| candidate.length.min(remaining));
            if measure_greedy && first != EMPTY_BEAM_COST && second != EMPTY_BEAM_COST {
                let normal_node = if normal_parent == 0 {
                    first_node
                } else {
                    second_node
                };
                for distance in normal_node.state.reps.map(expand_u32) {
                    if distance <= config.dictionary {
                        longest_available = longest_available.max(rep_lengths.length(
                            context.input,
                            pos,
                            distance,
                            remaining,
                            cancel,
                        )?);
                    }
                }
            }
            for slot in 0..2 {
                let node_index = local * 2 + slot;
                let stored = storage.active(node_index);
                if stored.cost == EMPTY_BEAM_COST {
                    continue;
                }
                if slot != normal_parent && !at_boundary {
                    continue;
                }
                let node = BeamParent::from_active(node_index, stored);
                push_literal_edge_active(&mut storage, node, context, &mut literal_prices);

                let rep_distances = node.compact_state.reps.map(expand_u32);
                for (index, distance) in rep_distances.into_iter().enumerate() {
                    if index >= 3 && !at_boundary {
                        continue;
                    }
                    if distance > config.dictionary {
                        continue;
                    }
                    let maximum =
                        rep_lengths.length(context.input, pos, distance, remaining, cancel)?;
                    if index == 0 && maximum >= 1 {
                        push_short_rep_edge_active(&mut storage, node, context, &prices);
                    }
                    if maximum >= 2 {
                        let generated;
                        let (tail, first) = rep_tail_lengths(maximum);
                        let lengths = if !at_boundary {
                            &tail[first..]
                        } else {
                            generated = rep_sparse_boundary_lengths(maximum);
                            &generated.0[..generated.1]
                        };
                        push_rep_edges_active(
                            &mut storage,
                            node,
                            context,
                            &mut prices,
                            index,
                            lengths,
                        );
                    }
                }

                if slot != normal_parent {
                    continue;
                }
                for candidate in matches.iter() {
                    if node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                    {
                        continue;
                    }
                    let length = candidate.length.min(remaining);
                    if length >= 3 {
                        push_match_edge_active(
                            &mut storage,
                            node,
                            context,
                            &mut prices,
                            &mut distance_prices,
                            candidate.distance,
                            length,
                        );
                    }
                }
                if let Some(candidate) = longest
                    && !node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                {
                    let maximum = candidate.length.min(remaining);
                    if maximum >= 3 {
                        for &length in cached_match_candidate_lengths(maximum) {
                            if length == maximum {
                                continue;
                            }
                            push_match_edge_active(
                                &mut storage,
                                node,
                                context,
                                &mut prices,
                                &mut distance_prices,
                                candidate.distance,
                                length,
                            );
                        }
                    }
                }
            }
            if measure_greedy && first != EMPTY_BEAM_COST && second != EMPTY_BEAM_COST {
                greedy_screen.two_parent_positions += 1;
                let margin = u64::from(first.abs_diff(second));
                if margin >= 128 {
                    greedy_screen.margin_ge_128_positions += 1;
                }
                if margin >= 512 {
                    greedy_screen.margin_ge_512_positions += 1;
                }
                for (margin_index, minimum_margin) in [128u64, 512].into_iter().enumerate() {
                    if margin < minimum_margin {
                        continue;
                    }
                    for (length_index, minimum_length) in [32usize, 64, 128].into_iter().enumerate()
                    {
                        if longest_available < minimum_length {
                            continue;
                        }
                        let gate_index = margin_index * 3 + length_index;
                        let gate = &mut greedy_screen.gates[gate_index];
                        gate.qualified_positions += 1;
                        gate.potential_bytes += longest_available;
                        if local >= covered_until[gate_index] {
                            gate.covered_bytes += longest_available;
                            covered_until[gate_index] = local + longest_available;
                        }
                    }
                }
            }
        }
        if measure_greedy {
            super::profile::record_greedy_skip_screen(greedy_screen);
        }
    }

    let target_start = block_length * 2;
    if measure_greedy {
        let active_nodes = storage.nodes[..target_start + 2]
            .iter()
            .filter(|node| node.cost != EMPTY_BEAM_COST)
            .count();
        let mut rep_tuples = Vec::new();
        rep_tuples
            .try_reserve_exact(active_nodes)
            .map_err(|_| Error::Limit)?;
        rep_tuples.extend(
            storage.nodes[..target_start + 2]
                .iter()
                .filter(|node| node.cost != EMPTY_BEAM_COST)
                .map(|node| node.state.reps),
        );
        rep_tuples.sort_unstable();
        rep_tuples.dedup();
        super::profile::record_rep_state_census(active_nodes, rep_tuples.len());
    }
    let (slot, _) = (0..2)
        .map(|slot| (slot, storage.active(target_start + slot)))
        .filter(|(_, node)| node.cost != EMPTY_BEAM_COST)
        .min_by_key(|(_, node)| node.cost)
        .ok_or(Error::Format("beam parser lost literal path"))?;
    let mut current = target_start + slot;
    let mut plan = Vec::new();
    plan.try_reserve_exact(block_length)
        .map_err(|_| Error::Limit)?;
    while parent_has_index(storage.active(current).parent) {
        plan.push(storage.token(current).to_token());
        current = parent_index(storage.active(current).parent);
    }
    plan.reverse();
    Ok(plan)
}

#[derive(Clone, Copy)]
struct FixedHistoryNode {
    cost: BeamCost,
    parent: usize,
    token: AbsoluteToken,
}

impl FixedHistoryNode {
    const EMPTY: Self = Self {
        cost: EMPTY_BEAM_COST,
        parent: usize::MAX,
        token: AbsoluteToken::Literal,
    };
}

#[inline(always)]
fn insert_fixed_history_edge(
    storage: &mut [FixedHistoryNode],
    end: usize,
    parent: usize,
    cost: BeamCost,
    token: AbsoluteToken,
) {
    // 同価格は先に生成したedgeを残し、実験出力の決定性を保つ。
    if cost < storage[end].cost {
        storage[end] = FixedHistoryNode {
            cost,
            parent,
            token,
        };
    }
}

/// greedy先行parseから位置ごとのRep履歴を固定し、1状態/位置で価格を求める。
/// Rep indexは価格近似にしか使わず、選択結果を絶対距離にした後、実経路の
/// Rep状態でwire tokenへ再構成する。
#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn fixed_rep_history_plan(
    candidate_block: &bt::Block,
    config: BeamParseConfig,
    boundaries: &[u64],
    context: &BeamContext<'_>,
    fixed_states: &[ParseState],
    mut prices: BeamPriceCache,
    mut literal_prices: LiteralPriceCache,
    mut distance_prices: DistancePriceCache,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let block_length = context.end - context.start;
    if fixed_states.len() != block_length + 1 {
        return Err(Error::Format("fixed Rep history has invalid length"));
    }
    let mut storage = buffer(block_length + 1, FixedHistoryNode::EMPTY)?;
    storage[0].cost = 0;

    for local in 0..block_length {
        check(cancel)?;
        let node = storage[local];
        if node.cost == EMPTY_BEAM_COST {
            return Err(Error::Format("fixed Rep history parser lost literal path"));
        }
        let pos = context.start + local;
        let remaining = context.end - pos;
        let state = fixed_states[local];
        let price_context = token_context(state.previous_match, pos);

        let literal = literal_prices.price(
            config.cache_prices,
            context.models,
            context.input,
            pos,
            state.reps,
            state.previous_match,
        );
        insert_fixed_history_edge(
            &mut storage,
            local + 1,
            local,
            add_beam_cost(node.cost, literal),
            AbsoluteToken::Literal,
        );

        let at_boundary = boundaries[local / 64] & (1u64 << (local % 64)) != 0;
        let mut rep_lengths = RepLengthCache::<4>::new();
        for (index, distance) in state.reps.into_iter().enumerate() {
            if state.reps[..index].contains(&distance) || distance > config.dictionary {
                continue;
            }
            let maximum = rep_lengths.length(context.input, pos, distance, remaining, cancel)?;
            if index == 0 && maximum >= 1 {
                let price = if prices.enabled {
                    prices.short_rep[price_context]
                } else {
                    match_price(context.models, pos, state.previous_match, Token::ShortRep)
                };
                insert_fixed_history_edge(
                    &mut storage,
                    local + 1,
                    local,
                    add_beam_cost(node.cost, price),
                    AbsoluteToken::Copy {
                        distance,
                        length: 1,
                    },
                );
            }
            if maximum < 2 {
                continue;
            }
            let generated;
            let (tail, first) = rep_tail_lengths(maximum);
            let lengths = if at_boundary {
                generated = rep_sparse_boundary_lengths(maximum);
                &generated.0[..generated.1]
            } else {
                &tail[first..]
            };
            for &length in lengths {
                let price = if prices.enabled {
                    prices.rep_base[price_context][index]
                        + BeamPriceCache::length(
                            &mut prices.rep_length,
                            prices.stride,
                            &context.models.rep_length,
                            price_context,
                            length,
                            2,
                        )
                } else {
                    match_price(
                        context.models,
                        pos,
                        state.previous_match,
                        Token::Rep { index, length },
                    )
                };
                insert_fixed_history_edge(
                    &mut storage,
                    local + length,
                    local,
                    add_beam_cost(node.cost, price),
                    AbsoluteToken::Copy { distance, length },
                );
            }
        }

        let matches = bt_frontier(
            candidate_block,
            local,
            remaining,
            context.models,
            context.distance_table,
        );
        let longest = matches.iter().last();
        for candidate in matches.iter() {
            if state.reps.contains(&candidate.distance) || candidate.length < 3 {
                continue;
            }
            let price = prices.match_token_price(
                context.models,
                &mut distance_prices,
                context.distance_table,
                pos,
                state.previous_match,
                candidate.distance,
                candidate.length,
            );
            insert_fixed_history_edge(
                &mut storage,
                local + candidate.length,
                local,
                add_beam_cost(node.cost, price),
                AbsoluteToken::Copy {
                    distance: candidate.distance,
                    length: candidate.length,
                },
            );
        }
        if let Some(candidate) = longest
            && !state.reps.contains(&candidate.distance)
            && candidate.length >= 3
        {
            for &length in cached_match_candidate_lengths(candidate.length) {
                if length == candidate.length {
                    continue;
                }
                let price = prices.match_token_price(
                    context.models,
                    &mut distance_prices,
                    context.distance_table,
                    pos,
                    state.previous_match,
                    candidate.distance,
                    length,
                );
                insert_fixed_history_edge(
                    &mut storage,
                    local + length,
                    local,
                    add_beam_cost(node.cost, price),
                    AbsoluteToken::Copy {
                        distance: candidate.distance,
                        length,
                    },
                );
            }
        }
    }

    let mut current = block_length;
    let mut absolute = Vec::new();
    absolute
        .try_reserve_exact(block_length)
        .map_err(|_| Error::Limit)?;
    while current != 0 {
        let node = storage[current];
        if node.cost == EMPTY_BEAM_COST || node.parent >= current {
            return Err(Error::Format("invalid fixed Rep history parent"));
        }
        absolute.push(node.token);
        current = node.parent;
    }
    absolute.reverse();
    concretize_absolute_plan(&absolute, config.initial_state, context.start)
}

fn candidate_lengths(minimum: usize, maximum: usize) -> ([usize; 12], usize) {
    let mut values = [0usize; 12];
    let mut count = 0usize;
    let mut add = |value: usize| {
        if value >= minimum && value <= maximum && !values[..count].contains(&value) {
            values[count] = value;
            count += 1;
        }
    };
    for value in minimum..=minimum.saturating_add(4).min(maximum) {
        add(value);
    }
    for value in [8, 16, 32] {
        add(value);
    }
    for value in maximum.saturating_sub(2)..=maximum {
        add(value);
    }
    (values, count)
}

type MatchCandidateTable = [([usize; 12], usize); MAX_BEAM_BLOCK + 1];
const MATCH_CANDIDATE_MEMORY: usize = std::mem::size_of::<MatchCandidateTable>();

fn cached_match_candidate_lengths(maximum: usize) -> &'static [usize] {
    const fn build() -> MatchCandidateTable {
        let mut table = [([0; 12], 0); MAX_BEAM_BLOCK + 1];
        let mut maximum = 0;
        while maximum <= MAX_BEAM_BLOCK {
            let mut length = 3;
            while length <= 7 && length <= maximum {
                table[maximum].0[table[maximum].1] = length;
                table[maximum].1 += 1;
                length += 1;
            }
            let fixed = [8, 16, 32];
            let mut fixed_index = 0;
            while fixed_index < fixed.len() {
                let value = fixed[fixed_index];
                if value <= maximum {
                    table[maximum].0[table[maximum].1] = value;
                    table[maximum].1 += 1;
                }
                fixed_index += 1;
            }
            let mut tail = maximum.saturating_sub(2);
            while tail <= maximum {
                if tail >= 3 {
                    let mut seen = false;
                    let mut at = 0;
                    while at < table[maximum].1 {
                        if table[maximum].0[at] == tail {
                            seen = true;
                            break;
                        }
                        at += 1;
                    }
                    if !seen {
                        table[maximum].0[table[maximum].1] = tail;
                        table[maximum].1 += 1;
                    }
                }
                tail += 1;
            }
            maximum += 1;
        }
        table
    }
    static TABLE: MatchCandidateTable = build();
    let (values, count) = &TABLE[maximum];
    &values[..*count]
}

fn rep_boundary_lengths(maximum: usize) -> ([usize; 12], usize) {
    let mut values = [0usize; 12];
    let mut count = 0usize;
    // 固定候補は互いに異なる。末尾3長だけ固定集合との重複を除く。
    for length in [2, 3, 4, 5, 6, 9, 17, 32] {
        if length <= maximum {
            values[count] = length;
            count += 1;
        }
    }
    for length in maximum.saturating_sub(2).max(2)..=maximum {
        if !matches!(length, 2..=6 | 9 | 17 | 32) {
            values[count] = length;
            count += 1;
        }
    }
    (values, count)
}

fn rep_sparse_boundary_lengths(maximum: usize) -> ([usize; 12], usize) {
    let mut values = [0usize; 12];
    let mut count = 0usize;
    // 幅2では符号木の節目2/9/17と末尾2長だけを残す。32は開発solidで
    // サイズと時間の両方を悪化させたため含めない。
    for length in [2, 9, 17] {
        if length <= maximum {
            values[count] = length;
            count += 1;
        }
    }
    for length in maximum.saturating_sub(1).max(2)..=maximum {
        if !matches!(length, 2 | 9 | 17) {
            values[count] = length;
            count += 1;
        }
    }
    (values, count)
}

type RepBoundaryTable = [([usize; 12], usize); MAX_BEAM_BLOCK + 1];
const REP_BOUNDARY_MEMORY: usize = std::mem::size_of::<RepBoundaryTable>();

fn cached_rep_boundary_lengths(maximum: usize) -> &'static [usize] {
    const fn build() -> RepBoundaryTable {
        let mut table = [([0; 12], 0); MAX_BEAM_BLOCK + 1];
        let fixed = [2, 3, 4, 5, 6, 9, 17, 32];
        let mut maximum = 0;
        while maximum <= MAX_BEAM_BLOCK {
            let mut at = 0;
            while at < fixed.len() {
                if fixed[at] <= maximum {
                    table[maximum].0[table[maximum].1] = fixed[at];
                    table[maximum].1 += 1;
                }
                at += 1;
            }
            let mut length = if maximum > 4 { maximum - 2 } else { 2 };
            while length <= maximum {
                if !matches!(length, 2..=6 | 9 | 17 | 32) {
                    table[maximum].0[table[maximum].1] = length;
                    table[maximum].1 += 1;
                }
                length += 1;
            }
            maximum += 1;
        }
        table
    }
    static TABLE: RepBoundaryTable = build();
    let (values, count) = &TABLE[maximum];
    &values[..*count]
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn longest_token(
    matches: impl Iterator<Item = Match>,
    models: &Models,
    input: &[u8],
    pos: usize,
    dictionary: usize,
    state: ParseState,
    maximum: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Option<Token>, Error> {
    let mut best = None;
    let mut accept = |token: Token| {
        if token.length() < LONG_MATCH_SHORTCUT {
            return;
        }
        match best {
            None => best = Some(token),
            Some(current)
                if token.length() > current.length()
                    || (token.length() == current.length()
                        && match_price(models, pos, state.previous_match, token)
                            < match_price(models, pos, state.previous_match, current)) =>
            {
                best = Some(token);
            }
            _ => {}
        }
    };
    for (index, distance) in state.reps.into_iter().enumerate() {
        if distance <= dictionary {
            let length = rep_length(input, pos, distance, cancel)?.min(maximum);
            if length >= 2 {
                accept(Token::Rep { index, length });
            }
        }
    }
    for candidate in matches {
        if !state.reps.contains(&candidate.distance) {
            accept(Token::Match {
                distance: candidate.distance,
                length: candidate.length.min(maximum),
            });
        }
    }
    Ok(best)
}

fn prefer_greedy_token(
    models: &Models,
    pos: usize,
    previous_match: bool,
    current: Option<Token>,
    candidate: Token,
) -> bool {
    current.is_none_or(|current| {
        candidate.length() > current.length()
            || (candidate.length() == current.length()
                && match_price(models, pos, previous_match, candidate)
                    < match_price(models, pos, previous_match, current))
    })
}

struct WarmContext<'a> {
    finder: &'a Finder,
    initial_models: &'a Models,
    input: &'a [u8],
    start: usize,
    end: usize,
    dictionary: usize,
    initial_state: ParseState,
    first_matches: &'a Matches,
}

/// block内だけで使う暫定greedy parse。長さを優先し、同長だけを現在の学習model価格で選ぶ。
fn greedy_block_token(
    context: &WarmContext<'_>,
    models: &Models,
    pos: usize,
    state: ParseState,
    match_cache: &mut FindTraceCache,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Token, Error> {
    let remaining = context.end - pos;
    let mut best = None;
    let mut short_rep_matches = false;
    for (index, distance) in state.reps.into_iter().enumerate() {
        if distance > context.dictionary {
            continue;
        }
        let length = rep_length_limited(context.input, pos, distance, remaining, cancel)?;
        if index == 0 {
            short_rep_matches = length >= 1;
        }
        if length >= 2 {
            let candidate = Token::Rep { index, length };
            if prefer_greedy_token(models, pos, state.previous_match, best, candidate) {
                best = Some(candidate);
            }
        }
    }

    let owned_matches;
    let matches = if pos == context.start {
        context.first_matches
    } else {
        owned_matches = match_cache.capture(
            context.finder,
            context.input,
            pos,
            context.dictionary,
            remaining,
            cancel,
        )?;
        &owned_matches
    };
    for candidate in matches.iter() {
        if state.reps.contains(&candidate.distance) {
            continue;
        }
        let candidate = Token::Match {
            distance: candidate.distance,
            length: candidate.length.min(remaining),
        };
        if candidate.length() >= 3
            && prefer_greedy_token(models, pos, state.previous_match, best, candidate)
        {
            best = Some(candidate);
        }
    }
    if let Some(token) = best {
        return Ok(token);
    }

    let short_rep = Token::ShortRep;
    if short_rep_matches
        && match_price(models, pos, state.previous_match, short_rep)
            < literal_price(models, context.input, pos, state.reps, state.previous_match)
    {
        Ok(short_rep)
    } else {
        Ok(Token::Literal)
    }
}

/// 実符号化modelを複製し、現在blockの暫定parseだけで価格用modelを学習する。
fn warm_block_models(
    context: &WarmContext<'_>,
    blended: bool,
    match_cache: &mut FindTraceCache,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Models, Error> {
    let _profile = Scope::new(Phase::WarmModel);
    let mut warmed = context.initial_models.try_clone()?;
    let mut sink = LearningSink;
    let mut state = context.initial_state;
    let mut pos = context.start;
    while pos < context.end {
        check(cancel)?;
        let token = greedy_block_token(context, &warmed, pos, state, match_cache, cancel)?;
        put_token(
            &mut sink,
            &mut warmed,
            context.input,
            pos,
            &mut state.reps,
            state.previous_match,
            token,
        )?;
        pos += token.length();
        state.previous_match = !matches!(token, Token::Literal);
    }
    if blended {
        warmed.blend_with(context.initial_models);
    }
    Ok(warmed)
}

struct WarmBtContext<'a> {
    initial_models: &'a Models,
    input: &'a [u8],
    start: usize,
    end: usize,
    dictionary: usize,
    initial_state: ParseState,
    candidates: &'a bt::Block,
}

fn greedy_bt_block_token(
    context: &WarmBtContext<'_>,
    models: &Models,
    pos: usize,
    state: ParseState,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Token, Error> {
    let remaining = context.end - pos;
    let mut best = None;
    let mut short_rep_matches = false;
    for (index, distance) in state.reps.into_iter().enumerate() {
        if distance > context.dictionary {
            continue;
        }
        let length = rep_length_limited(context.input, pos, distance, remaining, cancel)?;
        if index == 0 {
            short_rep_matches = length >= 1;
        }
        if length >= 2 {
            let candidate = Token::Rep { index, length };
            if prefer_greedy_token(models, pos, state.previous_match, best, candidate) {
                best = Some(candidate);
            }
        }
    }
    for candidate in bt_matches(context.candidates, pos - context.start) {
        if state.reps.contains(&candidate.distance) {
            continue;
        }
        let candidate = Token::Match {
            distance: candidate.distance,
            length: candidate.length.min(remaining),
        };
        if candidate.length() >= 3
            && prefer_greedy_token(models, pos, state.previous_match, best, candidate)
        {
            best = Some(candidate);
        }
    }
    if let Some(token) = best {
        return Ok(token);
    }
    if short_rep_matches
        && match_price(models, pos, state.previous_match, Token::ShortRep)
            < literal_price(models, context.input, pos, state.reps, state.previous_match)
    {
        Ok(Token::ShortRep)
    } else {
        Ok(Token::Literal)
    }
}

type BoundaryMask = [u64; (MAX_BEAM_BLOCK + 1).div_ceil(64)];

fn rep_tail_lengths(maximum: usize) -> ([usize; 2], usize) {
    debug_assert!(maximum >= 2);
    ([maximum - 1, maximum], 3usize.saturating_sub(maximum))
}

fn mark_boundary(mask: &mut BoundaryMask, local: usize, length: usize) {
    for at in local.saturating_sub(2)..=local.saturating_add(2).min(length) {
        mask[at / 64] |= 1u64 << (at % 64);
    }
}

fn greedy_bt_block_seed_with_states(
    context: &WarmBtContext<'_>,
    mut boundaries: Option<&mut BoundaryMask>,
    mut fixed_states: Option<&mut [ParseState]>,
    mut selected_tokens: Option<&mut Vec<SelectedToken>>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Models, ParseState), Error> {
    let _profile = Scope::new(Phase::WarmModel);
    let mut warmed = context.initial_models.try_clone()?;
    let mut sink = LearningSink;
    let mut state = context.initial_state;
    let mut pos = context.start;
    if let Some(states) = fixed_states.as_deref_mut() {
        if states.len() != context.end - context.start + 1 {
            return Err(Error::Format("fixed Rep history has invalid length"));
        }
        states[0] = state;
    }
    while pos < context.end {
        check(cancel)?;
        let local = pos - context.start;
        let token = greedy_bt_block_token(context, &warmed, pos, state, cancel)?;
        if token.length() >= 2
            && let Some(mask) = boundaries.as_deref_mut()
        {
            mark_boundary(mask, pos - context.start, context.end - context.start);
        }
        if let Some(tokens) = selected_tokens.as_deref_mut() {
            if tokens.len() == MAX_SELECTED_TOKEN_TRACE_ITEMS {
                return Err(Error::Limit);
            }
            tokens.try_reserve(1).map_err(|_| Error::Limit)?;
            let (kind, distance, rep_index) = match token {
                Token::Literal => (0, 0, 0),
                Token::ShortRep => (1, state.reps[0], 0),
                Token::Rep { index, .. } => (
                    2,
                    *state
                        .reps
                        .get(index)
                        .ok_or(Error::Format("invalid rep index"))?,
                    u8::try_from(index).map_err(|_| Error::Limit)?,
                ),
                Token::Match { distance, .. } => (3, distance, 0),
            };
            tokens.push(SelectedToken {
                offset: compact_usize(pos),
                length: compact_usize(token.length()),
                distance: compact_usize(distance),
                kind,
                rep_index,
            });
        }
        put_token(
            &mut sink,
            &mut warmed,
            context.input,
            pos,
            &mut state.reps,
            state.previous_match,
            token,
        )?;
        pos += token.length();
        state.previous_match = !matches!(token, Token::Literal);
        if let Some(states) = fixed_states.as_deref_mut() {
            states[local + 1..=pos - context.start].fill(state);
        }
    }
    if let Some(mask) = boundaries {
        mark_boundary(
            mask,
            context.end - context.start,
            context.end - context.start,
        );
    }
    Ok((warmed, state))
}

fn greedy_bt_block_seed(
    context: &WarmBtContext<'_>,
    boundaries: Option<&mut BoundaryMask>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Models, ParseState), Error> {
    greedy_bt_block_seed_with_states(context, boundaries, None, None, cancel)
}

/// 研究用screen向けに、BT5 greedy tokenを1回parseして記録する。
/// tokenを適応modelへ即時反映し、Rep履歴とprevious-matchをそのまま次tokenへ渡す。
pub(super) fn trace_greedy_bt5_tokens(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<SelectedToken>, Error> {
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || options.beam_block < 64
        || options.beam_block > MAX_BEAM_BLOCK
        || !options.beam_block.is_power_of_two()
        || options.beam_batch_blocks != 1
    {
        return Err(Error::Limit);
    }
    if input.is_empty() {
        return Ok(Vec::new());
    }

    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(options.bt_nice_len)?;
    let mut candidates = bt::Block::new(options.beam_block)?;
    let mut models = Models::new()?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut selected = Vec::new();
    let mut start = 0usize;
    while start < input.len() {
        check(cancel)?;
        let end = start.saturating_add(options.beam_block).min(input.len());
        matcher.prepare_start(
            &mut candidates,
            input,
            start,
            end,
            options.dictionary,
            cancel,
        )?;
        matcher.prepare_rest(
            &mut candidates,
            input,
            start,
            end,
            options.dictionary,
            cancel,
        )?;
        let context = WarmBtContext {
            initial_models: &models,
            input,
            start,
            end,
            dictionary: options.dictionary,
            initial_state: state,
            candidates: &candidates,
        };
        let (warmed, next_state) =
            greedy_bt_block_seed_with_states(&context, None, None, Some(&mut selected), cancel)?;
        models = warmed;
        state = next_state;
        start = end;
    }
    Ok(selected)
}

fn warm_bt_block_models(
    context: &WarmBtContext<'_>,
    blended: bool,
    boundaries: Option<&mut BoundaryMask>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Models, Error> {
    let (mut warmed, _) = greedy_bt_block_seed(context, boundaries, cancel)?;
    if blended {
        warmed.blend_with(context.initial_models);
    }
    Ok(warmed)
}

/// Screen the increasing-cost premise used by bit-optimal LZ parsers against the exact
/// first-block BT5/Blended price model and BT candidates used by the fixed KHC baseline.
/// This diagnoses applicability only; it does not construct a parse graph or encode a frame.
pub(super) fn screen_fsg_price_monotonicity(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<super::FsgPriceMonotonicityReport, Error> {
    const INPUT_BYTES: usize = 2_811_006;
    const FIRST_BLOCK_BYTES: usize = MAX_BEAM_BLOCK;
    const DICTIONARY_BYTES: usize = 64 * 1024 * 1024;
    if input.len() != INPUT_BYTES
        || !matches!(options.algorithm, super::Algorithm::Beam)
        || options.entropy_backend != super::EntropyBackend::Range
        || options.dictionary != DICTIONARY_BYTES
        || options.beam_width != 2
        || options.beam_block != FIRST_BLOCK_BYTES
        || !matches!(options.beam_model, BeamModel::Blended)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
    {
        return Err(Error::Format(
            "FSG price screen requires the fixed Canterbury Range/Blended/W2/BT5/B8192/64MiB baseline",
        ));
    }

    check(cancel)?;
    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(options.bt_nice_len)?;
    let mut candidates = bt::Block::new(FIRST_BLOCK_BYTES)?;
    matcher.prepare_start(
        &mut candidates,
        input,
        0,
        FIRST_BLOCK_BYTES,
        options.dictionary,
        cancel,
    )?;
    matcher.prepare_rest(
        &mut candidates,
        input,
        0,
        FIRST_BLOCK_BYTES,
        options.dictionary,
        cancel,
    )?;

    let initial_models = Models::new()?;
    let context = WarmBtContext {
        initial_models: &initial_models,
        input,
        start: 0,
        end: FIRST_BLOCK_BYTES,
        dictionary: options.dictionary,
        initial_state: ParseState {
            reps: [1usize; 4],
            previous_match: false,
        },
        candidates: &candidates,
    };
    let mut boundaries = [0u64; (MAX_BEAM_BLOCK + 1).div_ceil(64)];
    let warmed = warm_bt_block_models(&context, true, Some(&mut boundaries), cancel)?;

    #[expect(
        clippy::too_many_arguments,
        reason = "研究用比較の入力と状態を独立した引数として保持する"
    )]
    fn record_drop(
        drops: &mut Vec<super::FsgPriceDrop>,
        kind: &'static str,
        token_context: Option<usize>,
        length_context: Option<usize>,
        distance: Option<usize>,
        previous_symbol: usize,
        symbol: usize,
        previous_price: u64,
        price: u64,
    ) -> Result<(), Error> {
        if drops.iter().filter(|drop| drop.kind == kind).count()
            < super::FSG_MAX_RECORDED_DROPS_PER_KIND
        {
            drops.try_reserve(1).map_err(|_| Error::Limit)?;
            drops.push(super::FsgPriceDrop {
                kind,
                token_context,
                length_context,
                distance,
                previous_symbol,
                symbol,
                previous_price,
                price,
            });
        }
        Ok(())
    }

    // Keep only the distances that actually occur in this first block's BT5 snapshot,
    // together with the longest legal prefix for that distance anywhere in the block.
    let mut reachable = Vec::<(usize, usize)>::new();
    let mut candidate_edges = 0usize;
    let mut candidate_positions = 0usize;
    for local in 0..FIRST_BLOCK_BYTES {
        check(cancel)?;
        let mut position_has_candidate = false;
        let remaining = FIRST_BLOCK_BYTES - local;
        for candidate in bt_matches(&candidates, local) {
            if candidate.distance == 0 || candidate.distance > local {
                return Err(Error::Format(
                    "BT5 screen produced an invalid first-block distance",
                ));
            }
            let length = candidate.length.min(remaining).min(MAX_MATCH);
            if length < 3 {
                continue;
            }
            candidate_edges = candidate_edges.checked_add(1).ok_or(Error::Limit)?;
            position_has_candidate = true;
            reachable.try_reserve(1).map_err(|_| Error::Limit)?;
            reachable.push((candidate.distance, length));
        }
        candidate_positions += usize::from(position_has_candidate);
    }
    reachable.sort_unstable_by_key(|&(distance, length)| (distance, std::cmp::Reverse(length)));
    let mut unique_reachable = Vec::<(usize, usize)>::new();
    unique_reachable
        .try_reserve(reachable.len())
        .map_err(|_| Error::Limit)?;
    for (distance, length) in reachable {
        if let Some((last_distance, last_length)) = unique_reachable.last_mut()
            && *last_distance == distance
        {
            *last_length = (*last_length).max(length);
        } else {
            unique_reachable.push((distance, length));
        }
    }
    let maximum_match_length = unique_reachable
        .iter()
        .map(|&(_, length)| length)
        .max()
        .unwrap_or(0);

    let mut report = super::FsgPriceMonotonicityReport {
        input_bytes: input.len(),
        first_block_bytes: FIRST_BLOCK_BYTES,
        candidate_positions,
        candidate_edges,
        reachable_distances: unique_reachable.len(),
        maximum_match_length,
        match_length_checks: 0,
        match_length_decreases: 0,
        distance_checks: 0,
        distance_decreases: 0,
        length_distance_boundary_checks: 0,
        length_distance_boundary_decreases: 0,
        first_decreases: Vec::new(),
    };

    if maximum_match_length >= 3 {
        for token_context in 0..TOKEN_CONTEXTS {
            let mut previous_price = length_price(&warmed.match_length, token_context, 3, 3);
            for length in 4..=maximum_match_length {
                check(cancel)?;
                let price = length_price(&warmed.match_length, token_context, length, 3);
                report.match_length_checks += 1;
                if price < previous_price {
                    report.match_length_decreases += 1;
                    record_drop(
                        &mut report.first_decreases,
                        "match_length",
                        Some(token_context),
                        None,
                        None,
                        length - 1,
                        length,
                        previous_price,
                        price,
                    )?;
                }
                previous_price = price;
            }
        }
    }

    let distance_context_representatives = [3usize, 5, 9, 17];
    for (length_context, representative_length) in
        distance_context_representatives.into_iter().enumerate()
    {
        let mut previous = None;
        for &(distance, maximum_length) in &unique_reachable {
            if maximum_length < representative_length {
                continue;
            }
            check(cancel)?;
            let price = distance_price(&warmed, distance, representative_length);
            if let Some((previous_distance, previous_price)) = previous {
                report.distance_checks += 1;
                if price < previous_price {
                    report.distance_decreases += 1;
                    record_drop(
                        &mut report.first_decreases,
                        "distance",
                        None,
                        Some(length_context),
                        Some(distance),
                        previous_distance,
                        distance,
                        previous_price,
                        price,
                    )?;
                }
            }
            previous = Some((distance, price));
        }
    }

    // Distance price is constant within each match-length context. Only compare exact
    // total edge prices at the three boundaries where that context changes.
    for &(distance, maximum_length) in &unique_reachable {
        for boundary in [5usize, 9, 17] {
            if maximum_length < boundary {
                continue;
            }
            check(cancel)?;
            for token_context in 0..TOKEN_CONTEXTS {
                let previous_length = boundary - 1;
                let previous_price =
                    length_price(&warmed.match_length, token_context, previous_length, 3)
                        + distance_price(&warmed, distance, previous_length);
                let price = length_price(&warmed.match_length, token_context, boundary, 3)
                    + distance_price(&warmed, distance, boundary);
                report.length_distance_boundary_checks += 1;
                if price < previous_price {
                    report.length_distance_boundary_decreases += 1;
                    record_drop(
                        &mut report.first_decreases,
                        "length_distance_boundary",
                        Some(token_context),
                        Some(distance_context(boundary)),
                        Some(distance),
                        previous_length,
                        boundary,
                        previous_price,
                        price,
                    )?;
                }
            }
        }
    }

    Ok(report)
}

/// Currentは現在model、Warm/Blendedはblock内の暫定学習modelを凍結して使うbounded beam。
/// いずれも全体最適化ではなく、実符号化modelはblock境界まで更新しない。
#[cfg(test)]
fn beam_plan(
    finder: &Finder,
    models: &Models,
    input: &[u8],
    start: usize,
    config: BeamParseConfig,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let mut match_cache =
        FindTraceCache::new(!matches!(config.model, BeamModel::Current), config.block)?;
    beam_plan_mode::<false>(
        finder,
        models,
        input,
        start,
        config,
        &mut match_cache,
        cancel,
    )
}

fn beam_plan_mode<const KEEP_DUPLICATE_MAXIMUM: bool>(
    finder: &Finder,
    models: &Models,
    input: &[u8],
    start: usize,
    config: BeamParseConfig,
    match_cache: &mut FindTraceCache,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let _profile = Scope::new(Phase::BeamPlan);
    match_cache.start_block(start);
    let first_matches = if matches!(config.model, BeamModel::Current) {
        finder.find(input, start, config.dictionary, cancel)?
    } else {
        match_cache.capture(finder, input, start, config.dictionary, MAX_MATCH, cancel)?
    };
    if let Some(token) = longest_token(
        first_matches.iter(),
        models,
        input,
        start,
        config.dictionary,
        config.initial_state,
        MAX_MATCH,
        cancel,
    )? {
        let mut plan = Vec::new();
        plan.try_reserve_exact(1).map_err(|_| Error::Limit)?;
        plan.push(token);
        return Ok(plan);
    }

    let end = start.saturating_add(config.block).min(input.len());
    let block_length = end - start;
    let warm_context = WarmContext {
        finder,
        initial_models: models,
        input,
        start,
        end,
        dictionary: config.dictionary,
        initial_state: config.initial_state,
        first_matches: &first_matches,
    };
    let pricing_models = match config.model {
        BeamModel::Current => None,
        BeamModel::Warm => Some(warm_block_models(
            &warm_context,
            false,
            match_cache,
            cancel,
        )?),
        BeamModel::Blended => Some(warm_block_models(&warm_context, true, match_cache, cancel)?),
    };
    let price_models = pricing_models.as_ref().unwrap_or(models);
    // long-match shortcutとWarm暫定parseは従来のnearest frontierを使う。
    // PricedTieだけは価格model確定後にlocal0を同じfull上限で再探索する。
    let priced_first_matches = match config.matches {
        BeamMatches::Nearest => None,
        BeamMatches::PricedTie => Some(
            match match_cache.replay(
                input,
                start,
                config.dictionary,
                MAX_MATCH,
                Some(price_models),
                cancel,
            )? {
                Some(matches) => matches,
                None => finder.find_limited_priced(
                    input,
                    start,
                    config.dictionary,
                    MAX_MATCH,
                    price_models,
                    cancel,
                )?,
            },
        ),
        BeamMatches::Bt4
        | BeamMatches::Bt5
        | BeamMatches::Exact4
        | BeamMatches::Hybrid
        | BeamMatches::R4
        | BeamMatches::R5 => {
            unreachable!("BT matchers use their dedicated monotonic planner")
        }
    };
    let beam_first_matches = priced_first_matches.as_ref().unwrap_or(&first_matches);
    let context = BeamContext {
        models: price_models,
        distance_table: None,
        input,
        start,
        end,
        width: config.width,
    };
    let storage_length = block_length
        .checked_add(1)
        .and_then(|buckets| buckets.checked_mul(config.width))
        .ok_or(Error::Limit)?;
    let mut storage = buffer(storage_length, BeamNode::EMPTY)?;
    storage[0] = BeamNode {
        cost: 0,
        state: CompactState::from_parse(config.initial_state),
        parent: encode_parent(None, config.initial_state.previous_match),
        token: CompactToken::Literal,
    };
    let mut prices = BeamPriceCache::new(price_models, config.cache_prices, config.block)?;
    let mut literal_prices = LiteralPriceCache::new(config.cache_prices)?;

    for local in 0..block_length {
        check(cancel)?;
        let pos = start + local;
        let mut distance_prices = DistancePriceCache::new();
        let mut rep_lengths = RepLengthCache::<16>::new();
        let owned_matches = if local == 0 {
            None
        } else {
            let replayed = match_cache.replay(
                input,
                pos,
                config.dictionary,
                end - pos,
                matches!(config.matches, BeamMatches::PricedTie).then_some(price_models),
                cancel,
            )?;
            Some(match replayed {
                Some(matches) => matches,
                None => match config.matches {
                    BeamMatches::Nearest => {
                        finder.find_limited(input, pos, config.dictionary, end - pos, cancel)?
                    }
                    BeamMatches::PricedTie => finder.find_limited_priced(
                        input,
                        pos,
                        config.dictionary,
                        end - pos,
                        price_models,
                        cancel,
                    )?,
                    BeamMatches::Bt4
                    | BeamMatches::Bt5
                    | BeamMatches::Exact4
                    | BeamMatches::Hybrid
                    | BeamMatches::R4
                    | BeamMatches::R5 => {
                        unreachable!("BT matchers use their dedicated monotonic planner")
                    }
                },
            })
        };
        let matches = owned_matches.as_ref().unwrap_or(beam_first_matches);
        {
            // match探索とbeam配列の確保は含めず、node展開中のrep長計算は含める。
            let _profile = Scope::new(Phase::ExpandNodes);
            for slot in 0..config.width {
                let node_index = local * config.width + slot;
                let stored = storage[node_index];
                if stored.cost == EMPTY_BEAM_COST {
                    continue;
                }
                let node = BeamParent::new(node_index, stored);
                push_literal_edge(
                    &mut storage,
                    node,
                    &context,
                    prices.enabled,
                    &mut literal_prices,
                );

                let remaining = end - pos;
                for (index, compact_distance) in node.compact_state.reps.into_iter().enumerate() {
                    let distance = expand_u32(compact_distance);
                    if distance > config.dictionary {
                        continue;
                    }
                    let maximum = rep_lengths.length(input, pos, distance, remaining, cancel)?;
                    if index == 0 && maximum >= 1 {
                        push_short_rep_edge(&mut storage, node, &context, &prices);
                    }
                    if maximum >= 2 {
                        let (lengths, count) = candidate_lengths(2, maximum);
                        push_rep_edges(
                            &mut storage,
                            node,
                            &context,
                            &mut prices,
                            index,
                            &lengths[..count],
                        );
                    }
                }

                let longest = matches.iter().last();
                for candidate in matches.iter() {
                    if node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                    {
                        continue;
                    }
                    let length = candidate.length.min(remaining);
                    if length >= 3 {
                        push_match_edge(
                            &mut storage,
                            node,
                            &context,
                            &mut prices,
                            &mut distance_prices,
                            candidate.distance,
                            length,
                        );
                    }
                }
                if let Some(candidate) = longest
                    && !node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                {
                    let maximum = candidate.length.min(remaining);
                    if maximum >= 3 {
                        for &length in cached_match_candidate_lengths(maximum) {
                            // maximumは直前のfrontier列挙で同じnodeから同じbucketへ
                            // 挿入済み。途中の短長edgeは別bucketなので二重挿入を省く。
                            if !KEEP_DUPLICATE_MAXIMUM && length == maximum {
                                continue;
                            }
                            push_match_edge(
                                &mut storage,
                                node,
                                &context,
                                &mut prices,
                                &mut distance_prices,
                                candidate.distance,
                                length,
                            );
                        }
                    }
                }
            }
        }
    }

    let target = &storage[block_length * config.width..(block_length + 1) * config.width];
    let (slot, _) = target
        .iter()
        .enumerate()
        .filter(|(_, node)| node.cost != EMPTY_BEAM_COST)
        .min_by_key(|(_, node)| node.cost)
        .ok_or(Error::Format("beam parser lost literal path"))?;
    let mut current = block_length * config.width + slot;
    let mut plan = Vec::new();
    plan.try_reserve_exact(block_length)
        .map_err(|_| Error::Limit)?;
    while parent_has_index(storage[current].parent) {
        plan.push(storage[current].token.to_token());
        current = parent_index(storage[current].parent);
    }
    plan.reverse();
    Ok(plan)
}

/// BT4は木を入力順に更新し、Warmと本beamへは同じblock snapshotを渡す。
trait CandidateProvider {
    fn prepare_start(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error>;

    fn prepare_rest(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error>;
}

struct PreparedCandidateProvider;

impl CandidateProvider for PreparedCandidateProvider {
    fn prepare_start(
        &mut self,
        _block: &mut bt::Block,
        _input: &[u8],
        _start: usize,
        _end: usize,
        _dictionary: usize,
        _cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        Ok(())
    }

    fn prepare_rest(
        &mut self,
        _block: &mut bt::Block,
        _input: &[u8],
        _start: usize,
        _end: usize,
        _dictionary: usize,
        _cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        Ok(())
    }
}

impl CandidateProvider for bt::Matcher {
    fn prepare_start(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        bt::Matcher::prepare_start(self, block, input, start, end, dictionary, cancel)
    }

    fn prepare_rest(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        bt::Matcher::prepare_rest(self, block, input, start, end, dictionary, cancel)
    }
}

enum DedicatedMatcher {
    Bt(bt::Matcher),
    Exact4(bt::Matcher),
    Exact4Fallback(bt::Matcher),
    HybridFallback(bt::Matcher),
    Hybrid(hybrid::Matcher),
    Row(row::Matcher),
}

impl CandidateProvider for DedicatedMatcher {
    fn prepare_start(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        match self {
            Self::Bt(matcher)
            | Self::Exact4(matcher)
            | Self::Exact4Fallback(matcher)
            | Self::HybridFallback(matcher) => {
                matcher.prepare_start(block, input, start, end, dictionary, cancel)
            }
            Self::Hybrid(matcher) => {
                matcher.prepare_start(block, input, start, end, dictionary, cancel)
            }
            Self::Row(matcher) => {
                matcher.prepare_start(block, input, start, end, dictionary, cancel)
            }
        }
    }

    fn prepare_rest(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        match self {
            Self::Bt(matcher)
            | Self::Exact4(matcher)
            | Self::Exact4Fallback(matcher)
            | Self::HybridFallback(matcher) => {
                matcher.prepare_rest(block, input, start, end, dictionary, cancel)
            }
            Self::Hybrid(matcher) => {
                matcher.prepare_rest(block, input, start, end, dictionary, cancel)
            }
            Self::Row(matcher) => {
                matcher.prepare_rest(block, input, start, end, dictionary, cancel)
            }
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn beam_plan_bt4<M: CandidateProvider>(
    matcher: &mut M,
    candidate_block: &mut bt::Block,
    models: &Models,
    input: &[u8],
    start: usize,
    config: BeamParseConfig,
    end_limit: Option<usize>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let _profile = Scope::new(Phase::BeamPlan);
    if config.fixed_rep_history
        && (config.width != 2
            || config.block != 8192
            || !matches!(config.model, BeamModel::Blended)
            || !matches!(config.matches, BeamMatches::Bt5))
    {
        return Err(Error::Format("unsupported fixed Rep history configuration"));
    }
    let end = start
        .saturating_add(config.block)
        .min(input.len())
        .min(end_limit.unwrap_or(input.len()));
    {
        let _profile = Scope::new(Phase::FindMatches);
        matcher.prepare_start(
            candidate_block,
            input,
            start,
            end,
            config.dictionary,
            cancel,
        )?;
    }
    if let Some(plan) = beam_plan_bt4_bypass(
        candidate_block,
        models,
        input,
        start,
        end,
        config,
        end_limit,
        cancel,
    )? {
        return Ok(plan);
    }

    {
        let _profile = Scope::new(Phase::FindMatches);
        matcher.prepare_rest(
            candidate_block,
            input,
            start,
            end,
            config.dictionary,
            cancel,
        )?;
    }
    beam_plan_bt4_prepared(
        candidate_block,
        models,
        input,
        start,
        config,
        end_limit,
        cancel,
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn beam_plan_bt4_bypass(
    candidate_block: &bt::Block,
    models: &Models,
    input: &[u8],
    start: usize,
    end: usize,
    config: BeamParseConfig,
    end_limit: Option<usize>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Option<Vec<Token>>, Error> {
    if let Some(token) = longest_token(
        bt_matches(candidate_block, 0),
        models,
        input,
        start,
        config.dictionary,
        config.initial_state,
        end_limit.map_or(MAX_MATCH, |limit| limit - start),
        cancel,
    )? && (end_limit.is_none() || token.length() == end - start)
    {
        if super::profile::diagnostics_enabled() {
            super::profile::record_beam_bypass(token.length());
        }
        let mut plan = Vec::new();
        plan.try_reserve_exact(1).map_err(|_| Error::Limit)?;
        plan.push(token);
        return Ok(Some(plan));
    }
    Ok(None)
}

fn beam_plan_bt4_prepared(
    candidate_block: &bt::Block,
    models: &Models,
    input: &[u8],
    start: usize,
    config: BeamParseConfig,
    end_limit: Option<usize>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let end = start
        .saturating_add(config.block)
        .min(input.len())
        .min(end_limit.unwrap_or(input.len()));
    let block_length = end - start;
    let warm_context = WarmBtContext {
        initial_models: models,
        input,
        start,
        end,
        dictionary: config.dictionary,
        initial_state: config.initial_state,
        candidates: candidate_block,
    };
    let mut boundaries = [u64::MAX; (MAX_BEAM_BLOCK + 1).div_ceil(64)];
    let mut fixed_states = Vec::new();
    let pricing_models = match config.model {
        BeamModel::Current => None,
        BeamModel::Warm => Some(warm_bt_block_models(&warm_context, false, None, cancel)?),
        BeamModel::Blended => {
            let selected = if matches!(config.width, 2..=4) {
                boundaries.fill(0);
                Some(&mut boundaries)
            } else {
                None
            };
            if config.fixed_rep_history {
                fixed_states = buffer(block_length + 1, config.initial_state)?;
                let (mut warmed, _) = greedy_bt_block_seed_with_states(
                    &warm_context,
                    selected,
                    Some(&mut fixed_states),
                    None,
                    cancel,
                )?;
                warmed.blend_with(models);
                Some(warmed)
            } else {
                Some(warm_bt_block_models(&warm_context, true, selected, cancel)?)
            }
        }
    };
    let price_models = pricing_models.as_ref().unwrap_or(models);
    let distance_table = DistancePriceTable::new(price_models)?;
    let context = BeamContext {
        models: price_models,
        distance_table: Some(&distance_table),
        input,
        start,
        end,
        width: config.width,
    };
    let storage_length = block_length
        .checked_add(1)
        .and_then(|buckets| buckets.checked_mul(config.width))
        .ok_or(Error::Limit)?;
    let mut prices = BeamPriceCache::new(price_models, config.cache_prices, config.block)?;
    let mut literal_prices = LiteralPriceCache::new(config.cache_prices)?;
    // BT4の価格modelはblock内で不変。距離/長さ文脈だけのcacheを位置間で共有する。
    let mut distance_prices = DistancePriceCache::new();
    if config.fixed_rep_history {
        return fixed_rep_history_plan(
            candidate_block,
            config,
            &boundaries,
            &context,
            &fixed_states,
            prices,
            literal_prices,
            distance_prices,
            cancel,
        );
    }
    // 通常の幅2だけtokenをsidecarへ分離し、展開中のnodeを32 byteから24 byteへ
    // 縮める。計測時も通常encodeと同じparser経路を通し、storage差で候補選択を変えない。
    let split_storage = config.cache_prices
        && config.width == 2
        && config.block == 8192
        && matches!(config.model, BeamModel::Blended)
        && matches!(
            config.matches,
            BeamMatches::Bt5 | BeamMatches::Exact4 | BeamMatches::R4 | BeamMatches::R5
        );
    if split_storage {
        let caches = BeamActiveCaches {
            prices,
            literal_prices,
            distance_prices,
        };
        return beam_plan_bt4_active(
            candidate_block,
            config,
            &boundaries,
            &context,
            storage_length,
            caches,
            cancel,
        );
    }
    let mut storage = buffer(storage_length, BeamNode::EMPTY)?;
    storage[0] = BeamNode {
        cost: 0,
        state: CompactState::from_parse(config.initial_state),
        parent: encode_parent(None, config.initial_state.previous_match),
        token: CompactToken::Literal,
    };
    let filter_non_normal = matches!(config.width, 2 | 3)
        && matches!(config.block, 2048 | 4096 | 8192)
        && matches!(config.model, BeamModel::Blended)
        && matches!(
            config.matches,
            BeamMatches::Bt5 | BeamMatches::Exact4 | BeamMatches::R4 | BeamMatches::R5
        );
    let fast_rep_lengths = config.width == 4;

    for local in 0..block_length {
        check(cancel)?;
        let pos = start + local;
        let remaining = end - pos;
        let at_boundary = boundaries[local / 64] & (1u64 << (local % 64)) != 0;
        let mut rep_lengths = RepLengthCache::<16>::new();
        // snapshotの全候補は価格model確定後、位置ごとに一度だけ既存frontierへ絞る。
        // nodeごとの展開数をhash-chain経路と同じ上限へ戻し、matcher差だけを比較する。
        let matches = bt_frontier(
            candidate_block,
            local,
            end - pos,
            price_models,
            Some(&distance_table),
        );

        let longest = matches.iter().last();
        // 通常一致だけ最安の親に限定する近似。Rep/Literalの状態多様性は維持する。
        let normal_parent = if filter_non_normal && config.width == 2 {
            let first = storage[local * 2].cost;
            let second = storage[local * 2 + 1].cost;
            usize::from(second < first)
        } else {
            storage[local * config.width..(local + 1) * config.width]
                .iter()
                .enumerate()
                .min_by_key(|(_, node)| node.cost)
                .map(|(slot, _)| slot)
                .unwrap()
        };
        let rep_diverse_parent_mask = (config.rep_diverse_third_parent && at_boundary).then(|| {
            rep_diverse_parent_mask(&storage[local * config.width..(local + 1) * config.width])
        });
        {
            let _profile = Scope::new(Phase::ExpandNodes);
            for slot in 0..config.width {
                let node_index = local * config.width + slot;
                let stored = storage[node_index];
                if stored.cost == EMPTY_BEAM_COST {
                    continue;
                }
                if slot != normal_parent && filter_non_normal && !at_boundary {
                    continue;
                }
                if rep_diverse_parent_mask.is_some_and(|selected| !selected[slot]) {
                    continue;
                }
                let node = BeamParent::new(node_index, stored);
                push_literal_edge(
                    &mut storage,
                    node,
                    &context,
                    prices.enabled,
                    &mut literal_prices,
                );

                for (index, compact_distance) in node.compact_state.reps.into_iter().enumerate() {
                    let distance = expand_u32(compact_distance);
                    if distance > config.dictionary {
                        continue;
                    }
                    let maximum = if fast_rep_lengths {
                        rep_lengths.length_fast_zero(input, pos, distance, remaining, cancel)?
                    } else {
                        rep_lengths.length(input, pos, distance, remaining, cancel)?
                    };
                    if index == 0 && maximum >= 1 {
                        push_short_rep_edge(&mut storage, node, &context, &prices);
                    }
                    if maximum >= 2 {
                        // Blended幅2/4は暫定parse境界付近だけ候補を広げる。幅4は既存の
                        // 全境界候補表、幅2は2/9/17と末尾2長をその場で生成する。
                        let generated;
                        let (tail, first) = rep_tail_lengths(maximum);
                        let lengths = if !at_boundary {
                            &tail[first..]
                        } else if fast_rep_lengths {
                            cached_rep_boundary_lengths(maximum)
                        } else {
                            generated = if config.width == 2
                                && matches!(config.model, BeamModel::Blended)
                            {
                                rep_sparse_boundary_lengths(maximum)
                            } else {
                                rep_boundary_lengths(maximum)
                            };
                            &generated.0[..generated.1]
                        };
                        push_rep_edges(&mut storage, node, &context, &mut prices, index, lengths);
                    }
                }

                if slot != normal_parent {
                    continue;
                }
                for candidate in matches.iter() {
                    if node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                    {
                        continue;
                    }
                    let length = candidate.length.min(remaining);
                    if length >= 3 {
                        push_match_edge(
                            &mut storage,
                            node,
                            &context,
                            &mut prices,
                            &mut distance_prices,
                            candidate.distance,
                            length,
                        );
                    }
                }
                if let Some(candidate) = longest
                    && !node
                        .compact_state
                        .reps
                        .contains(&compact_usize(candidate.distance))
                {
                    let maximum = candidate.length.min(remaining);
                    if maximum >= 3 {
                        for &length in cached_match_candidate_lengths(maximum) {
                            if length == maximum {
                                continue;
                            }
                            push_match_edge(
                                &mut storage,
                                node,
                                &context,
                                &mut prices,
                                &mut distance_prices,
                                candidate.distance,
                                length,
                            );
                        }
                    }
                }
            }
        }
    }

    let target = &storage[block_length * config.width..(block_length + 1) * config.width];
    let (slot, _) = target
        .iter()
        .enumerate()
        .filter(|(_, node)| node.cost != EMPTY_BEAM_COST)
        .min_by_key(|(_, node)| node.cost)
        .ok_or(Error::Format("beam parser lost literal path"))?;
    let mut current = block_length * config.width + slot;
    let mut plan = Vec::new();
    plan.try_reserve_exact(block_length)
        .map_err(|_| Error::Limit)?;
    while parent_has_index(storage[current].parent) {
        plan.push(storage[current].token.to_token());
        current = parent_index(storage[current].parent);
    }
    plan.reverse();
    if super::profile::diagnostics_enabled() {
        let mut competition = super::profile::BeamCompetitionBlock {
            input_bytes: block_length,
            terminal_second_best_gap: target
                .iter()
                .enumerate()
                .filter(|(other_slot, node)| *other_slot != slot && node.cost != EMPTY_BEAM_COST)
                .map(|(_, node)| u64::from(node.cost - target[slot].cost))
                .min(),
            ..Default::default()
        };
        let mut cursor = block_length * config.width + slot;
        while parent_has_index(storage[cursor].parent) {
            let selected = storage[cursor];
            let token = selected.token.to_token();
            let parent = parent_index(selected.parent);
            competition.path_tokens = competition.path_tokens.saturating_add(1);
            let parent_local = parent / config.width;
            let bucket_start = parent_local * config.width;
            let parent_bucket = &storage[bucket_start..bucket_start + config.width];
            let (best_slot, best) = parent_bucket
                .iter()
                .enumerate()
                .filter(|(_, node)| node.cost != EMPTY_BEAM_COST)
                .min_by_key(|(_, node)| node.cost)
                .expect("selected beam parent bucket must have a finite state");
            if parent != bucket_start + best_slot {
                competition.nonfirst_parent_tokens =
                    competition.nonfirst_parent_tokens.saturating_add(1);
                competition.nonfirst_parent_bytes = competition
                    .nonfirst_parent_bytes
                    .saturating_add(token.length());
                match token {
                    Token::Literal => {
                        competition.nonfirst_literal_tokens =
                            competition.nonfirst_literal_tokens.saturating_add(1);
                    }
                    Token::ShortRep => {
                        competition.nonfirst_short_rep_tokens =
                            competition.nonfirst_short_rep_tokens.saturating_add(1);
                    }
                    Token::Rep { .. } => {
                        competition.nonfirst_rep_tokens =
                            competition.nonfirst_rep_tokens.saturating_add(1);
                    }
                    Token::Match { .. } => {
                        competition.nonfirst_match_tokens =
                            competition.nonfirst_match_tokens.saturating_add(1);
                    }
                }
            }
            let gap = u64::from(storage[parent].cost - best.cost);
            if gap != 0 {
                competition.strict_parent_tokens =
                    competition.strict_parent_tokens.saturating_add(1);
                competition.strict_parent_bytes = competition
                    .strict_parent_bytes
                    .saturating_add(token.length());
                competition.strict_parent_gap = competition
                    .strict_parent_gap
                    .saturating_add(u128::from(gap));
                competition.max_strict_parent_gap = competition.max_strict_parent_gap.max(gap);
            }
            cursor = parent;
        }
        debug_assert!(competition.nonfirst_parent_bytes <= block_length);
        debug_assert!(competition.strict_parent_tokens <= competition.nonfirst_parent_tokens);
        debug_assert!(competition.strict_parent_bytes <= competition.nonfirst_parent_bytes);
        super::profile::record_beam_competition(start, competition);
        let adaptive = replay_plan_price(models, input, start, config.initial_state, &plan)?;
        super::profile::record_price_gap(
            start,
            block_length,
            plan.len(),
            u64::from(target[slot].cost),
            adaptive,
        );
        let mut candidates = 1usize;
        let mut best_adaptive = adaptive;
        let mut alternative = Vec::new();
        alternative
            .try_reserve_exact(block_length)
            .map_err(|_| Error::Limit)?;
        for (other_slot, node) in target.iter().enumerate() {
            if other_slot == slot || node.cost == EMPTY_BEAM_COST {
                continue;
            }
            candidates += 1;
            alternative.clear();
            let mut cursor = block_length * config.width + other_slot;
            while parent_has_index(storage[cursor].parent) {
                alternative.push(storage[cursor].token.to_token());
                cursor = parent_index(storage[cursor].parent);
            }
            alternative.reverse();
            best_adaptive = best_adaptive.min(replay_plan_price(
                models,
                input,
                start,
                config.initial_state,
                &alternative,
            )?);
        }
        super::profile::record_terminal_ranking(start, candidates, adaptive - best_adaptive);
    }
    Ok(plan)
}

/// 採取済みtoken列を同じRange符号器で再生し、指定した平文終端での終端payload長を返す。
/// 通常encodeの経路には入らない。最後のpreviewはfinish後のpayload長と一致しなければならない。
pub(crate) fn replay_boundary_previews(
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
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut models = Models::new()?;
    let mut reps = [1usize; 4];
    let mut previous_match = false;
    let mut pos = 0usize;
    let mut next_boundary = 0usize;
    let mut previews = Vec::new();
    previews
        .try_reserve_exact(boundary_ends.len())
        .map_err(|_| Error::Limit)?;
    for token in tokens {
        let start = usize::try_from(token.offset).map_err(|_| Error::Limit)?;
        let length = usize::try_from(token.length).map_err(|_| Error::Limit)?;
        if start != pos || length == 0 {
            return Err(Error::Format("boundary replay token is not contiguous"));
        }
        let decoded = match token.kind {
            0 if length == 1 && token.distance == 0 => Token::Literal,
            1 if length == 1 => Token::ShortRep,
            2 if token.rep_index < 4 && length >= 2 => Token::Rep {
                index: usize::from(token.rep_index),
                length,
            },
            3 if length >= 3 && token.distance != 0 => Token::Match {
                distance: usize::try_from(token.distance).map_err(|_| Error::Limit)?,
                length,
            },
            _ => return Err(Error::Format("boundary replay token kind")),
        };
        put_token(
            &mut coder,
            &mut models,
            input,
            pos,
            &mut reps,
            previous_match,
            decoded,
        )?;
        pos += length;
        previous_match = !matches!(decoded, Token::Literal);
        while next_boundary < boundary_ends.len() && boundary_ends[next_boundary] <= pos {
            previews.push(coder.finish_len_preview().ok_or(Error::Limit)?);
            next_boundary += 1;
        }
    }
    if pos != input.len() || next_boundary != boundary_ends.len() {
        return Err(Error::Format("boundary replay did not cover the input"));
    }
    let payload = coder.finish().map_err(encode_error)?;
    if previews.last().copied() != Some(payload.len()) {
        return Err(Error::Format(
            "boundary preview does not match the finished payload",
        ));
    }
    Ok((payload, previews))
}

fn replay_plan_price(
    initial: &Models,
    input: &[u8],
    start: usize,
    mut state: ParseState,
    plan: &[Token],
) -> Result<u64, Error> {
    let mut models = initial.try_clone()?;
    let mut sink = PriceSink::default();
    let mut pos = start;
    for &token in plan {
        put_token(
            &mut sink,
            &mut models,
            input,
            pos,
            &mut state.reps,
            state.previous_match,
            token,
        )?;
        pos += token.length();
        state.previous_match = !matches!(token, Token::Literal);
    }
    Ok(sink.0)
}

fn put_token(
    sink: &mut impl BitSink,
    models: &mut Models,
    input: &[u8],
    pos: usize,
    reps: &mut [usize; 4],
    previous_match: bool,
    token: Token,
) -> Result<(), Error> {
    let context = token_context(previous_match, pos);
    let is_match = !matches!(token, Token::Literal);
    put(sink, &mut models.is_match[context], is_match)?;
    match token {
        Token::Literal => put_literal(sink, models, input, pos, *reps),
        Token::ShortRep => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], true)?;
            put(sink, &mut models.is_short_rep[context], true)
        }
        Token::Rep { index, length } => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], index == 0)?;
            if index == 0 {
                put(sink, &mut models.is_short_rep[context], false)?;
            } else {
                put(sink, &mut models.is_rep1[context], index == 1)?;
                if index != 1 {
                    put(sink, &mut models.is_rep2[context], index == 2)?;
                }
            }
            put_length(sink, &mut models.rep_length, context, length, 2)?;
            move_rep(reps, index);
            Ok(())
        }
        Token::Match { distance, length } => {
            put(sink, &mut models.is_rep[context], false)?;
            put_length(sink, &mut models.match_length, context, length, 3)?;
            put_distance(sink, models, distance, length)?;
            add_distance(reps, distance);
            Ok(())
        }
    }
}

fn history_seeded_models(
    history: &[u8],
    chunk_start: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Models, Error> {
    if chunk_start > history.len() {
        return Err(Error::Format("history seed exceeds available prefix"));
    }
    let seed_start = chunk_start.saturating_sub(HISTORY_SEED_BYTES);
    let mut models = Models::new()?;
    let mut sink = LearningSink;
    let mut reps = [1usize; 4];
    for pos in seed_start..chunk_start {
        if (pos - seed_start) & 0xfff == 0 {
            check(cancel)?;
        }
        put_token(
            &mut sink,
            &mut models,
            history,
            pos,
            &mut reps,
            false,
            Token::Literal,
        )?;
    }
    check(cancel)?;
    Ok(models)
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn put_token_distance_delta(
    sink: &mut impl BitSink,
    models: &mut Models,
    delta_models: &mut [u16; DISTANCE_CONTEXTS],
    stats: &mut DistanceDeltaScreen,
    input: &[u8],
    pos: usize,
    reps: &mut [usize; 4],
    previous_match: bool,
    token: Token,
) -> Result<(), Error> {
    let context = token_context(previous_match, pos);
    let is_match = !matches!(token, Token::Literal);
    put(sink, &mut models.is_match[context], is_match)?;
    match token {
        Token::Literal => put_literal(sink, models, input, pos, *reps),
        Token::ShortRep => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], true)?;
            put(sink, &mut models.is_short_rep[context], true)
        }
        Token::Rep { index, length } => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], index == 0)?;
            if index == 0 {
                put(sink, &mut models.is_short_rep[context], false)?;
            } else {
                put(sink, &mut models.is_rep1[context], index == 1)?;
                if index != 1 {
                    put(sink, &mut models.is_rep2[context], index == 2)?;
                }
            }
            put_length(sink, &mut models.rep_length, context, length, 2)?;
            move_rep(reps, index);
            Ok(())
        }
        Token::Match { distance, length } => {
            put(sink, &mut models.is_rep[context], false)?;
            put_length(sink, &mut models.match_length, context, length, 3)?;
            put_distance_delta(sink, models, delta_models, distance, reps[0], length, stats)?;
            add_distance(reps, distance);
            Ok(())
        }
    }
}

/// mode 2 の range payload を作る。出力容量は必ず `input.len()` 以下に制限する。
pub(super) fn encode(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_with_token_trace::<false>(input, options, &mut Vec::new(), cancel)
}

pub(super) fn encode_with_token_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    let mut selected = Vec::new();
    let payload = encode_with_token_trace::<true>(input, options, &mut selected, cancel)?;
    Ok((payload, selected))
}

fn encode_with_token_trace<const CAPTURE_TRACE: bool>(
    input: &[u8],
    options: Options,
    selected: &mut Vec<SelectedToken>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_memory(input.len(), options.dictionary)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    let finder = Finder::new(input, cancel)?;
    let mut models = Models::new()?;
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut pos = 0usize;
    while pos < input.len() {
        check(cancel)?;
        let current = choose_match(
            &finder,
            &models,
            input,
            pos,
            options.dictionary,
            state,
            cancel,
        )?;
        let token = if let Some((token, saving)) = current {
            // 現在のmodelは更新せず、literal後の状態だけを反映して1 byte先を比較する。
            let defer = if pos + 1 < input.len() {
                choose_match(
                    &finder,
                    &models,
                    input,
                    pos + 1,
                    options.dictionary,
                    ParseState {
                        previous_match: false,
                        ..state
                    },
                    cancel,
                )?
                .is_some_and(|(_, next_saving)| next_saving > saving + 64)
            } else {
                false
            };
            if defer { Token::Literal } else { token }
        } else {
            Token::Literal
        };
        if CAPTURE_TRACE {
            capture_selected_token(selected, pos, state, token)?;
        }
        put_token(
            &mut coder,
            &mut models,
            input,
            pos,
            &mut state.reps,
            state.previous_match,
            token,
        )?;
        pos += token.length();
        state.previous_match = !matches!(token, Token::Literal);
    }
    check(cancel)?;
    coder.finish().map_err(encode_error)
}

fn capture_selected_token(
    selected: &mut Vec<SelectedToken>,
    pos: usize,
    state: ParseState,
    token: Token,
) -> Result<(), Error> {
    if selected.len() == MAX_SELECTED_TOKEN_TRACE_ITEMS {
        return Err(Error::Limit);
    }
    let (kind, distance, rep_index) = match token {
        Token::Literal => (0, 0, 0),
        Token::ShortRep => (1, state.reps[0], 0),
        Token::Rep { index, .. } => (
            2,
            *state
                .reps
                .get(index)
                .ok_or(Error::Format("invalid rep index"))?,
            u8::try_from(index).map_err(|_| Error::Limit)?,
        ),
        Token::Match { distance, .. } => (3, distance, 0),
    };
    if kind != 0 && (distance == 0 || distance > pos) {
        return Err(Error::Format("invalid selected copy distance"));
    }
    selected.try_reserve(1).map_err(|_| Error::Limit)?;
    selected.push(SelectedToken {
        offset: u32::try_from(pos).map_err(|_| Error::Limit)?,
        length: u32::try_from(token.length()).map_err(|_| Error::Limit)?,
        distance: u32::try_from(distance).map_err(|_| Error::Limit)?,
        kind,
        rep_index,
    });
    Ok(())
}

/// mode 2 と同じwireを、block内の凍結確率によるbounded beamで作る研究候補。
/// 現行lazy encoderとの実測比較用であり、全体最適性は主張しない。
pub(super) fn encode_beam(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_beam_with_price_cache_mode::<false>(input, options, true, true, cancel)
}

/// 固定した区間だけBT候補上のlazy parseへ切り替えるsingle-pass研究経路。
/// Rangeモデル、Rep履歴、BT matcher履歴は全区間で共有する。
pub(super) fn encode_beam_lz_regions(
    input: &[u8],
    options: Options,
    lz_regions: &[(usize, usize)],
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    let _profile = Scope::new(Phase::Encode);
    if !matches!(options.algorithm, super::Algorithm::Beam)
        || options.entropy_backend != super::EntropyBackend::Range
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
            "hybrid lazy regions require the plain Range/Blended/W2/BT5/B8192 baseline",
        ));
    }
    if input.len() > MAX_INPUT || options.dictionary == 0 || options.dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }
    let mut previous_end = 0usize;
    for &(start, end) in lz_regions {
        if start >= end || end > input.len() || start < previous_end {
            return Err(Error::Format("hybrid lazy regions are invalid or overlap"));
        }
        previous_end = end;
    }
    if encode_beam_required_memory(input.len(), options)
        .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }
    check(cancel)?;

    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(options.bt_nice_len)?;
    let mut candidate_block = bt::Block::new(options.beam_block)?;
    let mut models = Models::new()?;
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut pos = 0usize;
    let mut region_index = 0usize;
    while pos < input.len() {
        check(cancel)?;
        let next_region = lz_regions.get(region_index).copied();
        if let Some((_, region_end)) = next_region
            && pos > region_end
        {
            return Err(Error::Format("hybrid parser passed an LZ region boundary"));
        }
        if let Some((_, region_end)) = next_region
            && pos == region_end
        {
            region_index += 1;
            continue;
        }
        if let Some((region_start, region_end)) = next_region
            && pos >= region_start
        {
            let block_start = pos;
            let block_end = block_start
                .saturating_add(options.beam_block)
                .min(region_end);
            matcher.prepare_start(
                &mut candidate_block,
                input,
                block_start,
                block_end,
                options.dictionary,
                cancel,
            )?;
            matcher.prepare_rest(
                &mut candidate_block,
                input,
                block_start,
                block_end,
                options.dictionary,
                cancel,
            )?;
            while pos < block_end {
                check(cancel)?;
                let maximum = region_end - pos;
                let current = choose_bt_lz_token(
                    &candidate_block,
                    pos - block_start,
                    &models,
                    input,
                    pos,
                    options.dictionary,
                    state,
                    maximum,
                    cancel,
                )?;
                let token = if let Some((token, saving)) = current {
                    let next_pos = pos + 1;
                    let defer = if next_pos < block_end && next_pos < region_end {
                        choose_bt_lz_token(
                            &candidate_block,
                            next_pos - block_start,
                            &models,
                            input,
                            next_pos,
                            options.dictionary,
                            ParseState {
                                previous_match: false,
                                ..state
                            },
                            region_end - next_pos,
                            cancel,
                        )?
                        .is_some_and(|(_, next_saving)| next_saving > saving + 64)
                    } else {
                        false
                    };
                    if defer { Token::Literal } else { token }
                } else {
                    Token::Literal
                };
                let length = token.length();
                if length > region_end - pos {
                    return Err(Error::Format("hybrid token crosses an LZ region boundary"));
                }
                put_token(
                    &mut coder,
                    &mut models,
                    input,
                    pos,
                    &mut state.reps,
                    state.previous_match,
                    token,
                )?;
                pos += length;
                state.previous_match = !matches!(token, Token::Literal);
            }
            if pos == region_end {
                region_index += 1;
            }
            continue;
        }

        let end_limit = next_region.map(|(region_start, _)| region_start);
        let boundary_end = end_limit.unwrap_or(input.len());
        let config = BeamParseConfig {
            dictionary: options.dictionary,
            initial_state: state,
            cache_prices: true,
            width: options.beam_width,
            block: options.beam_block,
            model: options.beam_model,
            matches: options.beam_matches,
            rep_diverse_third_parent: false,
            fixed_rep_history: false,
        };
        let expected_end = pos
            .saturating_add(options.beam_block)
            .min(input.len())
            .min(boundary_end);
        let plan_start = pos;
        let plan = beam_plan_bt4(
            &mut matcher,
            &mut candidate_block,
            &models,
            input,
            pos,
            config,
            end_limit,
            cancel,
        )?;
        if plan.is_empty() {
            return Err(Error::Format("hybrid beam parser returned an empty plan"));
        }
        for token in plan {
            let length = token.length();
            if length > input.len() - pos || length > boundary_end - pos {
                return Err(Error::Format(
                    "hybrid Beam token crosses an LZ region boundary",
                ));
            }
            put_token(
                &mut coder,
                &mut models,
                input,
                pos,
                &mut state.reps,
                state.previous_match,
                token,
            )?;
            pos += length;
            state.previous_match = !matches!(token, Token::Literal);
        }
        if pos == plan_start {
            return Err(Error::Format("hybrid Beam plan did not advance"));
        }
        if end_limit.is_some() && pos != expected_end {
            return Err(Error::Format(
                "hybrid Beam plan ended at an unexpected position",
            ));
        }
    }
    if pos != input.len() {
        return Err(Error::Format("hybrid parser stopped before the input end"));
    }
    check(cancel)?;
    coder.finish_fast().map_err(encode_error)
}

/// 通常Range bitstreamのまま、Beamが実際に出したplan境界の状態だけを採取する。
pub(crate) fn encode_beam_with_plan_range_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<BeamPlanRangeRecord>), Error> {
    if !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.entropy_backend != super::EntropyBackend::Range
        || options.beam_batch_blocks != 1
        || options.beam_block == 0
        || input.is_empty()
        || input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
    {
        return Err(Error::Format(
            "unsupported beam plan Range census configuration",
        ));
    }
    let base_memory = encode_beam_required_memory(input.len(), options).ok_or(Error::Limit)?;
    if base_memory > options.memory_budget {
        return Err(Error::Limit);
    }

    let mut records = Vec::new();
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let plain_end;
    {
        let mut sink = PlanRangeSink {
            coder: &mut coder,
            records: &mut records,
            input_len: input.len(),
            plain_end: 0,
            previous_emitted_bytes: 0,
            base_memory,
            memory_budget: options.memory_budget,
        };
        encode_beam_bt4_process::<false, false, false>(
            input,
            options,
            true,
            &mut Vec::new(),
            &mut Vec::new(),
            &mut Vec::new(),
            &mut sink,
            cancel,
        )?;
        plain_end = sink.plain_end;
    }
    if plain_end != input.len() {
        return Err(Error::Format("beam plan census does not cover input"));
    }
    let payload = coder.finish_fast().map_err(encode_error)?;
    if records
        .last()
        .is_none_or(|record| record.prefix_payload_bytes_if_terminated != payload.len())
    {
        return Err(Error::Format("beam plan census final Range preview"));
    }
    Ok((payload, records))
}

/// 現行BT5 beamの選択Matchだけを記録する研究診断経路。
pub(crate) fn encode_beam_with_selected_match_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedMatch>), Error> {
    if !matches!(options.beam_matches, BeamMatches::Bt5)
        || input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_beam_required_memory(input.len(), options)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    let mut selected = Vec::new();
    let payload = encode_beam_bt4_inner::<true, false, false>(
        input,
        options,
        true,
        &mut selected,
        &mut Vec::new(),
        &mut Vec::new(),
        cancel,
    )?;
    Ok((payload, selected))
}

/// 通常MatchとRepを実距離へ解決して記録する、重い研究用診断経路。
pub(crate) type CopyCapture = (Vec<u8>, Vec<SelectedCopy>, Vec<SelectedToken>);

pub(crate) fn encode_beam_with_selected_copy_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<CopyCapture, Error> {
    if !matches!(options.beam_matches, BeamMatches::Bt5)
        || input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_beam_required_memory(input.len(), options)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    let mut selected = Vec::new();
    let mut selected_tokens = Vec::new();
    let payload = encode_beam_bt4_inner::<false, true, true>(
        input,
        options,
        true,
        &mut Vec::new(),
        &mut selected,
        &mut selected_tokens,
        cancel,
    )?;
    Ok((payload, selected, selected_tokens))
}

/// Beamが選んだ全tokenだけを記録する、parser census向け診断経路。
pub(crate) fn encode_beam_with_token_capture(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    if !matches!(options.beam_matches, BeamMatches::Bt5)
        || input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_beam_required_memory(input.len(), options)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    let mut selected = Vec::new();
    let payload = encode_beam_bt4_inner::<false, false, true>(
        input,
        options,
        true,
        &mut Vec::new(),
        &mut Vec::new(),
        &mut selected,
        cancel,
    )?;
    Ok((payload, selected))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CopySegment {
    start: usize,
    end: usize,
    distance: usize,
    patches: usize,
}

/// Baseline traceをsame-distance copy segmentへ置き換え、実range coderでpayloadを測る。
/// これは候補のサイズ検証専用で、parse時間短縮を測るものではない。
pub(crate) fn rewrite_selected_copy_segments(
    input: &[u8],
    dictionary: usize,
    selected: &[SelectedToken],
    max_patch_bytes: usize,
) -> Result<(Vec<u8>, SegmentRewriteStats), Error> {
    if input.len() > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }

    // traceがinput全域を正確に覆い、baseline Rep状態から距離が解決されていることを確認。
    let mut baseline_reps = [1usize; 4];
    let mut expected_offset = 0usize;
    let mut by_distance = std::collections::BTreeMap::<usize, Vec<(usize, usize)>>::new();
    for item in selected {
        let start = expand_u32(item.offset);
        let length = expand_u32(item.length);
        let distance = expand_u32(item.distance);
        let end = start.checked_add(length).ok_or(Error::Limit)?;
        if start != expected_offset || length == 0 || end > input.len() || item.kind > 3 {
            return Err(Error::Format("invalid selected token trace"));
        }
        match item.kind {
            0 => {
                if length != 1 || distance != 0 {
                    return Err(Error::Format("invalid selected literal trace"));
                }
            }
            1 => {
                if length != 1 || distance == 0 || distance > start || distance > dictionary {
                    return Err(Error::Format("invalid selected short-rep trace"));
                }
                if baseline_reps[0] != distance {
                    return Err(Error::Format("short-rep trace distance mismatch"));
                }
                if input[start] != input[start - distance] {
                    return Err(Error::Format("selected short-rep does not match input"));
                }
                by_distance.entry(distance).or_default().push((start, end));
            }
            2 => {
                let rep_index = usize::from(item.rep_index);
                if length < 2
                    || distance == 0
                    || distance > start
                    || distance > dictionary
                    || rep_index >= baseline_reps.len()
                    || baseline_reps[rep_index] != distance
                {
                    return Err(Error::Format("invalid selected rep trace"));
                }
                for position in start..end {
                    if input[position] != input[position - distance] {
                        return Err(Error::Format("selected rep does not match input"));
                    }
                }
                by_distance.entry(distance).or_default().push((start, end));
                move_rep(&mut baseline_reps, rep_index);
            }
            3 => {
                if length < 3 || distance == 0 || distance > start || distance > dictionary {
                    return Err(Error::Format("invalid selected match trace"));
                }
                for position in start..end {
                    if input[position] != input[position - distance] {
                        return Err(Error::Format("selected match does not match input"));
                    }
                }
                by_distance.entry(distance).or_default().push((start, end));
                add_distance(&mut baseline_reps, distance);
            }
            _ => unreachable!(),
        }
        expected_offset = end;
    }
    if expected_offset != input.len() {
        return Err(Error::Format("selected token trace does not cover input"));
    }

    let mut candidates = Vec::<CopySegment>::new();
    let mut gap_compare_bytes = 0usize;
    for (&distance, events) in &by_distance {
        let mut first_eligible = 0usize;
        let mut mismatch_window = 0usize;
        let mut gap_mismatches = Vec::with_capacity(events.len());
        gap_mismatches.push(0usize);
        for index in 0..events.len() {
            if index != 0 {
                let gap_start = events[index - 1].1;
                let gap_end = events[index].0;
                if gap_end - gap_start > SEGMENT_MAX_SPAN {
                    first_eligible = index;
                    mismatch_window = 0;
                    gap_mismatches.push(0);
                } else {
                    let mut current_gap_mismatches = 0usize;
                    for position in gap_start..gap_end {
                        gap_compare_bytes = gap_compare_bytes.checked_add(1).ok_or(Error::Limit)?;
                        if gap_compare_bytes > SEGMENT_MAX_GAP_COMPARE_BYTES {
                            return Err(Error::Limit);
                        }
                        if input[position] != input[position - distance] {
                            current_gap_mismatches += 1;
                            if current_gap_mismatches > max_patch_bytes {
                                break;
                            }
                        }
                    }
                    if current_gap_mismatches > max_patch_bytes {
                        // このgapを含む候補はすべて過上限。次の候補は現eventから始める。
                        first_eligible = index;
                        mismatch_window = 0;
                        gap_mismatches.push(0);
                    } else {
                        mismatch_window = mismatch_window
                            .checked_add(current_gap_mismatches)
                            .ok_or(Error::Limit)?;
                        gap_mismatches.push(current_gap_mismatches);
                    }
                }
            }

            let end = events[index].1;
            while first_eligible < index
                && (end - events[first_eligible].0 > SEGMENT_MAX_SPAN
                    || mismatch_window > max_patch_bytes)
            {
                mismatch_window =
                    mismatch_window.saturating_sub(gap_mismatches[first_eligible + 1]);
                first_eligible += 1;
            }
            if first_eligible < index {
                let start = events[first_eligible].0;
                if end - start >= SEGMENT_MIN_SPAN {
                    candidates.try_reserve(1).map_err(|_| Error::Limit)?;
                    candidates.push(CopySegment {
                        start,
                        end,
                        distance,
                        patches: mismatch_window,
                    });
                }
            }
        }
    }

    // 候補区間の重なりを避け、被覆byte合計が最大となる集合を選ぶ。
    candidates.sort_unstable_by_key(|candidate| (candidate.end, candidate.start));
    let mut previous_counts = Vec::new();
    previous_counts
        .try_reserve_exact(candidates.len())
        .map_err(|_| Error::Limit)?;
    let mut best_coverage = vec![0usize; candidates.len() + 1];
    let mut take_candidate = vec![false; candidates.len() + 1];
    for (index, candidate) in candidates.iter().enumerate() {
        let previous_count =
            candidates[..index].partition_point(|prior| prior.end <= candidate.start);
        previous_counts.push(previous_count);
        let include = best_coverage[previous_count]
            .checked_add(candidate.end - candidate.start)
            .ok_or(Error::Limit)?;
        let exclude = best_coverage[index];
        if include > exclude {
            best_coverage[index + 1] = include;
            take_candidate[index + 1] = true;
        } else {
            best_coverage[index + 1] = exclude;
        }
    }
    let mut segments = Vec::<CopySegment>::new();
    let mut index = candidates.len();
    while index != 0 {
        if take_candidate[index] {
            let candidate = candidates[index - 1];
            segments.push(candidate);
            index = previous_counts[index - 1];
        } else {
            index -= 1;
        }
    }
    segments.reverse();

    let mut tokens = Vec::<Token>::new();
    tokens
        .try_reserve(selected.len())
        .map_err(|_| Error::Limit)?;
    let mut rewrite_reps = [1usize; 4];
    let mut source_token = 0usize;
    let mut position = 0usize;
    let mut segment_index = 0usize;
    while position < input.len() {
        if let Some(segment) = segments.get(segment_index)
            && position == segment.start
        {
            let mut scan = segment.start;
            let mut actual_patches = 0usize;
            while scan < segment.end {
                if input[scan] == input[scan - segment.distance] {
                    let run_start = scan;
                    scan += 1;
                    while scan < segment.end && input[scan] == input[scan - segment.distance] {
                        scan += 1;
                    }
                    if scan - run_start >= 3 {
                        append_resolved_copy(
                            &mut tokens,
                            &mut rewrite_reps,
                            segment.distance,
                            scan - run_start,
                        )?;
                    } else {
                        for _ in run_start..scan {
                            tokens.try_reserve(1).map_err(|_| Error::Limit)?;
                            tokens.push(Token::Literal);
                        }
                    }
                } else {
                    actual_patches += 1;
                    tokens.try_reserve(1).map_err(|_| Error::Limit)?;
                    tokens.push(Token::Literal);
                    scan += 1;
                }
            }
            if actual_patches != segment.patches {
                return Err(Error::Format("copy segment patch count mismatch"));
            }
            position = segment.end;
            while source_token < selected.len()
                && expand_u32(selected[source_token].offset) < position
            {
                source_token += 1;
            }
            segment_index += 1;
            continue;
        }

        let Some(item) = selected.get(source_token) else {
            return Err(Error::Format("selected token trace ended early"));
        };
        let start = expand_u32(item.offset);
        let length = expand_u32(item.length);
        if start != position {
            return Err(Error::Format(
                "copy segment does not align to token boundary",
            ));
        }
        match item.kind {
            0 => {
                tokens.try_reserve(1).map_err(|_| Error::Limit)?;
                tokens.push(Token::Literal);
            }
            1..=3 => append_resolved_copy(
                &mut tokens,
                &mut rewrite_reps,
                expand_u32(item.distance),
                length,
            )?,
            _ => return Err(Error::Format("invalid selected token kind")),
        }
        position += length;
        source_token += 1;
    }
    if segment_index != segments.len() || source_token != selected.len() {
        return Err(Error::Format("copy segment rewrite did not consume trace"));
    }

    let covered_bytes = segments
        .iter()
        .map(|segment| segment.end - segment.start)
        .sum();
    let patch_bytes = segments.iter().map(|segment| segment.patches).sum();
    let mut models = Models::new()?;
    let output_limit = input
        .len()
        .checked_mul(2)
        .and_then(|limit| limit.checked_add(16))
        .ok_or(Error::Limit)?;
    let mut coder = range::Encoder::with_limit(output_limit).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1; 4],
        previous_match: false,
    };
    let mut token_offset = 0usize;
    for token in &tokens {
        if token.length() > input.len() - token_offset {
            return Err(Error::Format("rewritten token exceeds input"));
        }
        put_token(
            &mut coder,
            &mut models,
            input,
            token_offset,
            &mut state.reps,
            state.previous_match,
            *token,
        )?;
        token_offset += token.length();
        state.previous_match = !matches!(token, Token::Literal);
    }
    if token_offset != input.len() {
        return Err(Error::Format("rewritten tokens do not cover input"));
    }
    let payload = coder.finish().map_err(encode_error)?;
    if decode(&payload, input.len(), dictionary, &mut || false)? != input {
        return Err(Error::Format("copy segment rewrite round-trip mismatch"));
    }

    Ok((
        payload,
        SegmentRewriteStats {
            eligible_candidates: candidates.len(),
            covered_bytes,
            patch_bytes,
            selected_segments: segments.len(),
            baseline_tokens: selected.len(),
            rewritten_tokens: tokens.len(),
            segments,
        },
    ))
}

fn append_resolved_copy(
    tokens: &mut Vec<Token>,
    reps: &mut [usize; 4],
    distance: usize,
    length: usize,
) -> Result<(), Error> {
    if distance == 0 || length == 0 {
        return Err(Error::Format("invalid resolved copy"));
    }
    if length == 1 {
        if reps[0] == distance {
            tokens.try_reserve(1).map_err(|_| Error::Limit)?;
            tokens.push(Token::ShortRep);
        } else {
            tokens.try_reserve(1).map_err(|_| Error::Limit)?;
            tokens.push(Token::Literal);
        }
        return Ok(());
    }
    if let Some(index) = reps.iter().position(|&rep| rep == distance)
        && length >= 2
    {
        tokens.try_reserve(1).map_err(|_| Error::Limit)?;
        tokens.push(Token::Rep { index, length });
        move_rep(reps, index);
        return Ok(());
    }
    if !(3..=MAX_MATCH).contains(&length) {
        for _ in 0..length {
            tokens.try_reserve(1).map_err(|_| Error::Limit)?;
            tokens.push(Token::Literal);
        }
    } else {
        tokens.try_reserve(1).map_err(|_| Error::Limit)?;
        tokens.push(Token::Match { distance, length });
        add_distance(reps, distance);
    }
    Ok(())
}

enum PatchedCopyPlanToken {
    Ordinary(Token),
    Patched(CopySegment),
}

/// Research-only extended grammar: a sparse patched-copy is one token with a delta-coded patch list.
pub(crate) fn encode_patched_copy_segments(
    input: &[u8],
    dictionary: usize,
    selected: &[SelectedToken],
    max_patch_bytes: usize,
) -> Result<(Vec<u8>, SegmentRewriteStats), Error> {
    // Reuse the validated, priced mode-2 candidate selector; its output is a correctness control.
    let (_, mut stats) =
        rewrite_selected_copy_segments(input, dictionary, selected, max_patch_bytes)?;
    let mut segments = stats.segments.clone();
    segments.retain(|segment| segment.patches != 0);

    let mut plan = Vec::<PatchedCopyPlanToken>::new();
    plan.try_reserve(selected.len()).map_err(|_| Error::Limit)?;
    let mut ordinary_scratch = Vec::<Token>::new();
    let mut planning_reps = [1usize; 4];
    let mut source_token = 0usize;
    let mut position = 0usize;
    let mut segment_index = 0usize;
    while position < input.len() {
        if let Some(segment) = segments.get(segment_index)
            && position == segment.start
        {
            plan.try_reserve(1).map_err(|_| Error::Limit)?;
            plan.push(PatchedCopyPlanToken::Patched(*segment));
            add_distance(&mut planning_reps, segment.distance);
            position = segment.end;
            while source_token < selected.len()
                && expand_u32(selected[source_token].offset) < position
            {
                source_token += 1;
            }
            segment_index += 1;
            continue;
        }

        let Some(item) = selected.get(source_token) else {
            return Err(Error::Format("selected token trace ended early"));
        };
        if expand_u32(item.offset) != position {
            return Err(Error::Format(
                "patched-copy segment does not align to token boundary",
            ));
        }
        let length = expand_u32(item.length);
        if item.kind == 0 {
            plan.try_reserve(1).map_err(|_| Error::Limit)?;
            plan.push(PatchedCopyPlanToken::Ordinary(Token::Literal));
        } else {
            ordinary_scratch.clear();
            append_resolved_copy(
                &mut ordinary_scratch,
                &mut planning_reps,
                expand_u32(item.distance),
                length,
            )?;
            plan.try_reserve(ordinary_scratch.len())
                .map_err(|_| Error::Limit)?;
            plan.extend(
                ordinary_scratch
                    .iter()
                    .copied()
                    .map(PatchedCopyPlanToken::Ordinary),
            );
        }
        position += length;
        source_token += 1;
    }
    if segment_index != segments.len() || source_token != selected.len() {
        return Err(Error::Format("patched-copy plan did not consume trace"));
    }

    let mut models = Models::new()?;
    let mut patch_models = PatchedCopyModels::new();
    let output_limit = input
        .len()
        .checked_mul(2)
        .and_then(|limit| limit.checked_add(16))
        .ok_or(Error::Limit)?;
    let mut coder = range::Encoder::with_limit(output_limit).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1; 4],
        previous_match: false,
    };
    let mut token_offset = 0usize;
    for item in &plan {
        match item {
            PatchedCopyPlanToken::Ordinary(token) => {
                put_patched_copy_plain_token(
                    &mut coder,
                    &mut models,
                    &mut patch_models,
                    input,
                    token_offset,
                    &mut state.reps,
                    state.previous_match,
                    *token,
                )?;
                token_offset += token.length();
                state.previous_match = !matches!(token, Token::Literal);
            }
            PatchedCopyPlanToken::Patched(segment) => {
                put_patched_copy_token(
                    &mut coder,
                    &mut models,
                    &mut patch_models,
                    input,
                    token_offset,
                    &mut state.reps,
                    state.previous_match,
                    *segment,
                )?;
                token_offset = segment.end;
                state.previous_match = true;
            }
        }
    }
    if token_offset != input.len() {
        return Err(Error::Format("patched-copy tokens do not cover input"));
    }
    let payload = coder.finish().map_err(encode_error)?;
    if decode_patched_copy(&payload, input.len(), dictionary, &mut || false)? != input {
        return Err(Error::Format("patched-copy round-trip mismatch"));
    }

    stats.covered_bytes = segments
        .iter()
        .map(|segment| segment.end - segment.start)
        .sum();
    stats.patch_bytes = segments.iter().map(|segment| segment.patches).sum();
    stats.selected_segments = segments.len();
    stats.rewritten_tokens = plan.len();
    stats.segments.clear();
    Ok((payload, stats))
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn put_patched_copy_plain_token(
    sink: &mut impl BitSink,
    models: &mut Models,
    patch_models: &mut PatchedCopyModels,
    input: &[u8],
    pos: usize,
    reps: &mut [usize; 4],
    previous_match: bool,
    token: Token,
) -> Result<(), Error> {
    let context = token_context(previous_match, pos);
    if matches!(token, Token::Literal) {
        put(sink, &mut models.is_match[context], false)?;
        return put_literal(sink, models, input, pos, *reps);
    }
    put(sink, &mut models.is_match[context], true)?;
    put(sink, &mut patch_models.is_patch[context], false)?;
    match token {
        Token::Literal => unreachable!(),
        Token::ShortRep => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], true)?;
            put(sink, &mut models.is_short_rep[context], true)
        }
        Token::Rep { index, length } => {
            put(sink, &mut models.is_rep[context], true)?;
            put(sink, &mut models.is_rep0[context], index == 0)?;
            if index == 0 {
                put(sink, &mut models.is_short_rep[context], false)?;
            } else {
                put(sink, &mut models.is_rep1[context], index == 1)?;
                if index != 1 {
                    put(sink, &mut models.is_rep2[context], index == 2)?;
                }
            }
            put_length(sink, &mut models.rep_length, context, length, 2)?;
            move_rep(reps, index);
            Ok(())
        }
        Token::Match { distance, length } => {
            put(sink, &mut models.is_rep[context], false)?;
            put_length(sink, &mut models.match_length, context, length, 3)?;
            put_distance(sink, models, distance, length)?;
            add_distance(reps, distance);
            Ok(())
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn put_patched_copy_token(
    sink: &mut impl BitSink,
    models: &mut Models,
    patch_models: &mut PatchedCopyModels,
    input: &[u8],
    pos: usize,
    reps: &mut [usize; 4],
    previous_match: bool,
    segment: CopySegment,
) -> Result<(), Error> {
    let length = segment.end - segment.start;
    if segment.start != pos
        || !(SEGMENT_MIN_SPAN..=SEGMENT_MAX_SPAN).contains(&length)
        || length > input.len() - pos
        || segment.distance == 0
        || segment.distance > pos
    {
        return Err(Error::Format("invalid patched-copy segment"));
    }
    let context = token_context(previous_match, pos);
    put(sink, &mut models.is_match[context], true)?;
    put(sink, &mut patch_models.is_patch[context], true)?;
    put_length(sink, &mut models.match_length, context, length, 3)?;
    put_distance(sink, models, segment.distance, length)?;
    put_number(sink, &mut patch_models.patch_count, segment.patches)?;
    add_distance(reps, segment.distance);

    let mut scan = segment.start;
    let mut cursor = segment.start;
    let mut patch_count = 0usize;
    while scan < segment.end {
        if input[scan] != input[scan - segment.distance] {
            let gap = scan - cursor;
            put_number(sink, &mut patch_models.patch_gap, gap + 1)?;
            put_literal(sink, models, input, scan, *reps)?;
            cursor = scan + 1;
            patch_count += 1;
        }
        scan += 1;
    }
    if patch_count != segment.patches || patch_count == 0 {
        return Err(Error::Format("patched-copy count mismatch"));
    }
    Ok(())
}

/// Decoder for the experimental patched-copy payload. It is not a product frame decoder.
pub(crate) fn decode_patched_copy(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if size > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }
    let mut output = buffer(size, 0u8)?;
    let mut models = Models::new()?;
    let mut patch_models = PatchedCopyModels::new();
    let mut coder = range::Decoder::<false>::new(payload).map_err(Error::Format)?;
    let mut reps = [1usize; 4];
    let mut previous_match = false;
    let mut pos = 0usize;
    while pos < size {
        check(cancel)?;
        let context = token_context(previous_match, pos);
        if !get(&mut coder, &mut models.is_match[context])? {
            output[pos] = get_literal(&mut coder, &mut models, &output, pos, reps)?;
            pos += 1;
            previous_match = false;
            continue;
        }

        if get(&mut coder, &mut patch_models.is_patch[context])? {
            let length = get_length(&mut coder, &mut models.match_length, context, 3)?;
            if length > size - pos {
                return Err(Error::Format("patched-copy exceeds output"));
            }
            let maximum = dictionary.min(pos);
            if maximum == 0 {
                return Err(Error::Format("patched-copy before history"));
            }
            let distance = get_distance(&mut coder, &mut models, length, maximum)?;
            let patch_count = get_number(&mut coder, &mut patch_models.patch_count, length)?;
            add_distance(&mut reps, distance);
            let end = pos + length;
            for _ in 0..patch_count {
                let remaining = end - pos;
                let gap_plus_one = get_number(&mut coder, &mut patch_models.patch_gap, remaining)?;
                let gap = gap_plus_one - 1;
                if gap != 0 {
                    copy_match_bytes(&mut output, pos, distance, gap, cancel)?;
                    pos += gap;
                }
                output[pos] = get_literal(&mut coder, &mut models, &output, pos, reps)?;
                pos += 1;
            }
            if pos < end {
                copy_match_bytes(&mut output, pos, distance, end - pos, cancel)?;
                pos = end;
            }
            previous_match = true;
            continue;
        }

        let (distance, length, rep_index) = if get(&mut coder, &mut models.is_rep[context])? {
            let index = if get(&mut coder, &mut models.is_rep0[context])? {
                if get(&mut coder, &mut models.is_short_rep[context])? {
                    0
                } else {
                    usize::MAX
                }
            } else if get(&mut coder, &mut models.is_rep1[context])? {
                1
            } else if get(&mut coder, &mut models.is_rep2[context])? {
                2
            } else {
                3
            };
            if index == 0 {
                (reps[0], 1, None)
            } else {
                let actual = if index == usize::MAX { 0 } else { index };
                let length = get_length(&mut coder, &mut models.rep_length, context, 2)?;
                (reps[actual], length, Some(actual))
            }
        } else {
            let length = get_length(&mut coder, &mut models.match_length, context, 3)?;
            let maximum = dictionary.min(pos);
            if maximum == 0 {
                return Err(Error::Format("match before dictionary"));
            }
            let distance = get_distance(&mut coder, &mut models, length, maximum)?;
            (distance, length, Some(4))
        };

        if distance == 0 || distance > dictionary || distance > pos || length > size - pos {
            return Err(Error::Format("invalid patched-copy stream match"));
        }
        copy_match_bytes(&mut output, pos, distance, length, cancel)?;
        match rep_index {
            Some(index @ 0..=3) => move_rep(&mut reps, index),
            Some(4) => add_distance(&mut reps, distance),
            _ => {}
        }
        pos += length;
        previous_match = true;
    }
    coder.finish().map_err(Error::Format)?;
    check(cancel)?;
    Ok(output)
}

#[cfg(test)]
fn encode_beam_with_price_cache(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_beam_with_price_cache_mode::<false>(input, options, cache_prices, true, cancel)
}

#[cfg(test)]
fn encode_beam_with_match_trace(
    input: &[u8],
    options: Options,
    cache_match_traces: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_beam_with_price_cache_mode::<false>(input, options, true, cache_match_traces, cancel)
}

fn encode_beam_with_price_cache_mode<const KEEP_DUPLICATE_MAXIMUM: bool>(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    cache_match_traces: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_beam_required_memory(input.len(), options)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    if matches!(
        options.beam_matches,
        BeamMatches::Bt4
            | BeamMatches::Bt5
            | BeamMatches::Exact4
            | BeamMatches::Hybrid
            | BeamMatches::R4
            | BeamMatches::R5
    ) {
        return encode_beam_bt4(input, options, cache_prices, cancel);
    }

    let finder = Finder::new(input, cancel)?;
    let mut models = Models::new()?;
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut match_cache = FindTraceCache::new(
        cache_match_traces && !matches!(options.beam_model, BeamModel::Current),
        options.beam_block,
    )?;
    let mut pos = 0usize;
    while pos < input.len() {
        check(cancel)?;
        let plan = beam_plan_mode::<KEEP_DUPLICATE_MAXIMUM>(
            &finder,
            &models,
            input,
            pos,
            BeamParseConfig {
                dictionary: options.dictionary,
                initial_state: state,
                cache_prices,
                width: options.beam_width,
                block: options.beam_block,
                model: options.beam_model,
                matches: options.beam_matches,
                rep_diverse_third_parent: options.beam_rep_diverse_third_parent,
                fixed_rep_history: false,
            },
            &mut match_cache,
            cancel,
        )?;
        if plan.is_empty() {
            return Err(Error::Format("beam parser returned empty plan"));
        }
        {
            let _profile = Scope::new(Phase::EmitTokens);
            for token in plan {
                check(cancel)?;
                if token.length() > input.len() - pos {
                    return Err(Error::Format("beam token exceeds input"));
                }
                put_token(
                    &mut coder,
                    &mut models,
                    input,
                    pos,
                    &mut state.reps,
                    state.previous_match,
                    token,
                )?;
                pos += token.length();
                state.previous_match = !matches!(token, Token::Literal);
            }
        }
    }
    check(cancel)?;
    coder.finish().map_err(encode_error)
}

fn encode_beam_bt4(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_beam_bt4_inner::<false, false, false>(
        input,
        options,
        cache_prices,
        &mut Vec::new(),
        &mut Vec::new(),
        &mut Vec::new(),
        cancel,
    )
}

fn encode_beam_bt4_inner<
    const CAPTURE_MATCH_TRACE: bool,
    const CAPTURE_COPY_TRACE: bool,
    const CAPTURE_TOKEN_TRACE: bool,
>(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    selected: &mut Vec<SelectedMatch>,
    selected_copies: &mut Vec<SelectedCopy>,
    selected_tokens: &mut Vec<SelectedToken>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    if options.bt_nice_len != 0
        && (!matches!(options.beam_matches, BeamMatches::Bt5) || options.beam_batch_blocks != 1)
    {
        return Err(Error::Format(
            "BT nice length requires unbatched beam with BT5",
        ));
    }
    if options.beam_batch_blocks > 1 {
        if CAPTURE_MATCH_TRACE || CAPTURE_COPY_TRACE || CAPTURE_TOKEN_TRACE {
            return Err(Error::Format(
                "speculative beam batches do not support trace capture",
            ));
        }
        return encode_beam_bt4_batched(input, options, cache_prices, cancel);
    }
    if options.entropy_backend == super::EntropyBackend::Rans {
        let mut coder =
            super::rans::SegmentedEncoder::new(input.len(), input.len()).map_err(encode_error)?;
        encode_beam_bt4_process::<CAPTURE_MATCH_TRACE, CAPTURE_COPY_TRACE, CAPTURE_TOKEN_TRACE>(
            input,
            options,
            cache_prices,
            selected,
            selected_copies,
            selected_tokens,
            &mut coder,
            cancel,
        )?;
        coder
            .finish_with_check(input.len(), cancel)
            .map_err(encode_error)
    } else {
        let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
        {
            let mut sink = FastRangeSink(&mut coder);
            encode_beam_bt4_process::<CAPTURE_MATCH_TRACE, CAPTURE_COPY_TRACE, CAPTURE_TOKEN_TRACE>(
                input,
                options,
                cache_prices,
                selected,
                selected_copies,
                selected_tokens,
                &mut sink,
                cancel,
            )?;
        }
        let payload = coder.finish_fast().map_err(encode_error)?;
        Ok(payload)
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn encode_beam_bt4_process<
    const CAPTURE_MATCH_TRACE: bool,
    const CAPTURE_COPY_TRACE: bool,
    const CAPTURE_TOKEN_TRACE: bool,
>(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    selected: &mut Vec<SelectedMatch>,
    selected_copies: &mut Vec<SelectedCopy>,
    selected_tokens: &mut Vec<SelectedToken>,
    sink: &mut impl BitSink,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(), Error> {
    let mut matcher = match options.beam_matches {
        BeamMatches::Bt4 => DedicatedMatcher::Bt(bt::Matcher::new(input.len(), 4)?),
        BeamMatches::Bt5 => {
            let mut matcher = bt::Matcher::new(input.len(), 5)?;
            matcher.set_nice_len(options.bt_nice_len)?;
            DedicatedMatcher::Bt(matcher)
        }
        BeamMatches::Exact4 => match bt::Matcher::new_exact4(input, cancel)? {
            Some(matcher) => DedicatedMatcher::Exact4(matcher),
            None => DedicatedMatcher::Exact4Fallback(bt::Matcher::new(input.len(), 5)?),
        },
        BeamMatches::Hybrid
            if input.len() <= hybrid::NEAR_WINDOW || options.dictionary <= hybrid::NEAR_WINDOW =>
        {
            DedicatedMatcher::HybridFallback(bt::Matcher::new(input.len(), 5)?)
        }
        BeamMatches::Hybrid => {
            DedicatedMatcher::Hybrid(hybrid::Matcher::new(input.len(), options.dictionary)?)
        }
        BeamMatches::R4 => DedicatedMatcher::Row(row::Matcher::new(row::Config::R4)?),
        BeamMatches::R5 => DedicatedMatcher::Row(row::Matcher::new(row::Config::R5)?),
        BeamMatches::Nearest | BeamMatches::PricedTie => {
            return Err(Error::Format(
                "dedicated matcher selected for hash-chain mode",
            ));
        }
    };
    let mut candidate_block = match options.beam_matches {
        BeamMatches::Hybrid
            if input.len() > hybrid::NEAR_WINDOW && options.dictionary > hybrid::NEAR_WINDOW =>
        {
            bt::Block::new_with_depth(options.beam_block, hybrid::SNAPSHOT_DEPTH)?
        }
        BeamMatches::R4 | BeamMatches::R5 => {
            bt::Block::new_with_depth(options.beam_block, row::SLOTS)?
        }
        _ => bt::Block::new(options.beam_block)?,
    };
    let mut models = Models::new()?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut pos = 0usize;
    while pos < input.len() {
        check(cancel)?;
        let config = BeamParseConfig {
            dictionary: options.dictionary,
            initial_state: state,
            cache_prices,
            width: options.beam_width,
            block: options.beam_block,
            model: options.beam_model,
            matches: options.beam_matches,
            rep_diverse_third_parent: options.beam_rep_diverse_third_parent,
            fixed_rep_history: options.beam_fixed_rep_history,
        };
        let plan = beam_plan_bt4(
            &mut matcher,
            &mut candidate_block,
            &models,
            input,
            pos,
            config,
            options
                .beam_fixed_boundaries
                .then(|| pos.saturating_add(options.beam_block)),
            cancel,
        )?;
        if plan.is_empty() {
            return Err(Error::Format("beam parser returned empty plan"));
        }
        {
            let _profile = Scope::new(Phase::EmitTokens);
            let mut plan_plain_bytes = 0usize;
            for token in plan {
                check(cancel)?;
                let token_length = token.length();
                if token_length > input.len() - pos {
                    return Err(Error::Format("beam token exceeds input"));
                }
                if CAPTURE_COPY_TRACE {
                    let copy = match token {
                        Token::Literal => None,
                        Token::ShortRep => Some((state.reps[0], 3)),
                        Token::Rep { index, .. } => Some((
                            *state
                                .reps
                                .get(index)
                                .ok_or(Error::Format("invalid rep index"))?,
                            2,
                        )),
                        Token::Match { distance, .. } => Some((distance, 1)),
                    };
                    if let Some((distance, kind)) = copy {
                        if distance == 0 || distance > pos {
                            return Err(Error::Format("invalid selected copy distance"));
                        }
                        selected_copies.try_reserve(1).map_err(|_| Error::Limit)?;
                        selected_copies.push(SelectedCopy {
                            offset: compact_usize(pos),
                            length: compact_usize(token.length()),
                            distance: compact_usize(distance),
                            kind,
                        });
                    }
                }
                if CAPTURE_TOKEN_TRACE {
                    let (kind, distance, rep_index) = match token {
                        Token::Literal => (0, 0, 0),
                        Token::ShortRep => (1, state.reps[0], 0),
                        Token::Rep { index, .. } => (
                            2,
                            *state
                                .reps
                                .get(index)
                                .ok_or(Error::Format("invalid rep index"))?,
                            u8::try_from(index).map_err(|_| Error::Limit)?,
                        ),
                        Token::Match { distance, .. } => (3, distance, 0),
                    };
                    if selected_tokens.len() == MAX_SELECTED_TOKEN_TRACE_ITEMS {
                        return Err(Error::Limit);
                    }
                    selected_tokens.try_reserve(1).map_err(|_| Error::Limit)?;
                    selected_tokens.push(SelectedToken {
                        offset: compact_usize(pos),
                        length: compact_usize(token.length()),
                        distance: compact_usize(distance),
                        kind,
                        rep_index,
                    });
                }
                if CAPTURE_MATCH_TRACE && let Token::Match { distance, length } = token {
                    selected.try_reserve(1).map_err(|_| Error::Limit)?;
                    selected.push(SelectedMatch {
                        offset: pos,
                        length,
                        distance,
                    });
                }
                put_token(
                    sink,
                    &mut models,
                    input,
                    pos,
                    &mut state.reps,
                    state.previous_match,
                    token,
                )?;
                pos += token_length;
                plan_plain_bytes = plan_plain_bytes
                    .checked_add(token_length)
                    .ok_or(Error::Limit)?;
                state.previous_match = !matches!(token, Token::Literal);
            }
            sink.end_plan(plan_plain_bytes, cancel)?;
        }
    }
    check(cancel)?;
    Ok(())
}

/// 直前のraw履歴だけで確率modelをseedし、各512 KiB chunkを独立Range streamにする。
/// match finderと辞書は全入力で連続させるため、copyは過去chunkも参照できる。
pub(super) fn encode_history_seeded_chunks(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if options.entropy_backend != super::EntropyBackend::Range
        || options.beam_width != 2
        || options.beam_block != MAX_BEAM_BLOCK
        || !matches!(options.beam_model, BeamModel::Blended)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err(Error::Format(
            "history-seeded chunks require Range/Blended/W2/BT5/B8192 without batching",
        ));
    }
    if input.len() > MAX_INPUT
        || options.dictionary == 0
        || options.dictionary > MAX_DICTIONARY
        || encode_beam_required_memory(input.len(), options)
            .is_none_or(|required| required > options.memory_budget)
    {
        return Err(Error::Limit);
    }

    let chunk_count = input.len().div_ceil(HISTORY_SEEDED_CHUNK);
    let table_bytes = chunk_count.checked_mul(8).ok_or(Error::Limit)?;
    let maximum_payload = input
        .len()
        .checked_add(table_bytes)
        .and_then(|bytes| bytes.checked_add(4))
        .ok_or(Error::Limit)?;
    let mut payload = Vec::new();
    payload
        .try_reserve_exact(maximum_payload)
        .map_err(|_| Error::Limit)?;
    payload.extend_from_slice(
        &u32::try_from(chunk_count)
            .map_err(|_| Error::Limit)?
            .to_le_bytes(),
    );

    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    let mut candidate_block = bt::Block::new(MAX_BEAM_BLOCK)?;
    for chunk_index in 0..chunk_count {
        check(cancel)?;
        let chunk_start = chunk_index
            .checked_mul(HISTORY_SEEDED_CHUNK)
            .ok_or(Error::Limit)?;
        let chunk_end = chunk_start
            .saturating_add(HISTORY_SEEDED_CHUNK)
            .min(input.len());
        let chunk_length = chunk_end
            .checked_sub(chunk_start)
            .ok_or(Error::Format("history-seeded chunk bounds"))?;
        if chunk_length == 0 {
            return Err(Error::Format("history-seeded zero-length chunk"));
        }

        let mut models = history_seeded_models(input, chunk_start, cancel)?;
        let mut state = ParseState {
            reps: [1usize; 4],
            previous_match: false,
        };
        let mut coder = range::Encoder::with_limit(chunk_length).map_err(encode_error)?;
        let mut pos = chunk_start;
        {
            let mut sink = FastRangeSink(&mut coder);
            while pos < chunk_end {
                check(cancel)?;
                let block_end = pos.saturating_add(MAX_BEAM_BLOCK).min(chunk_end);
                let plan = beam_plan_bt4(
                    &mut matcher,
                    &mut candidate_block,
                    &models,
                    input,
                    pos,
                    BeamParseConfig {
                        dictionary: options.dictionary,
                        initial_state: state,
                        cache_prices: true,
                        width: 2,
                        block: MAX_BEAM_BLOCK,
                        model: BeamModel::Blended,
                        matches: BeamMatches::Bt5,
                        rep_diverse_third_parent: false,
                        fixed_rep_history: false,
                    },
                    Some(block_end),
                    cancel,
                )?;
                if plan.is_empty() {
                    return Err(Error::Format(
                        "history-seeded beam parser returned empty plan",
                    ));
                }
                let plan_start = pos;
                for token in plan {
                    check(cancel)?;
                    let token_length = token.length();
                    if token_length == 0 || token_length > block_end - pos {
                        return Err(Error::Format("history-seeded token crosses block boundary"));
                    }
                    put_token(
                        &mut sink,
                        &mut models,
                        input,
                        pos,
                        &mut state.reps,
                        state.previous_match,
                        token,
                    )?;
                    pos += token_length;
                    state.previous_match = !matches!(token, Token::Literal);
                }
                if pos != block_end {
                    return Err(Error::Format(
                        "history-seeded plan does not cover its block",
                    ));
                }
                sink.end_plan(pos - plan_start, cancel)?;
            }
        }
        if pos != chunk_end {
            return Err(Error::Format(
                "history-seeded plan does not cover its chunk",
            ));
        }
        let packed = coder.finish_fast().map_err(encode_error)?;
        if packed.is_empty() || packed.len() > chunk_length {
            return Err(Error::CandidateFull);
        }
        payload.extend_from_slice(
            &u32::try_from(chunk_length)
                .map_err(|_| Error::Limit)?
                .to_le_bytes(),
        );
        payload.extend_from_slice(
            &u32::try_from(packed.len())
                .map_err(|_| Error::Limit)?
                .to_le_bytes(),
        );
        payload.extend_from_slice(&packed);
        if payload.len() > maximum_payload {
            return Err(Error::Limit);
        }
    }
    check(cancel)?;
    Ok(payload)
}

fn encode_beam_bt4_batched(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(options.bt_nice_len)?;
    let mut models = Models::new()?;
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut pos = 0usize;
    let mut prepared = PreparedCandidateProvider;
    let result = {
        let mut sink = FastRangeSink(&mut coder);
        while pos < input.len() {
            check(cancel)?;
            let batch_start = pos;
            let block_count = ((input.len() - batch_start).div_ceil(options.beam_block))
                .min(options.beam_batch_blocks);
            let mut candidate_blocks = Vec::new();
            candidate_blocks
                .try_reserve_exact(block_count)
                .map_err(|_| Error::Limit)?;
            for index in 0..block_count {
                check(cancel)?;
                let start = batch_start
                    .checked_add(index.checked_mul(options.beam_block).ok_or(Error::Limit)?)
                    .ok_or(Error::Limit)?;
                let end = start.saturating_add(options.beam_block).min(input.len());
                let mut candidate_block = bt::Block::new(options.beam_block)?;
                matcher.prepare_start(
                    &mut candidate_block,
                    input,
                    start,
                    end,
                    options.dictionary,
                    cancel,
                )?;
                matcher.prepare_rest(
                    &mut candidate_block,
                    input,
                    start,
                    end,
                    options.dictionary,
                    cancel,
                )?;
                candidate_blocks.push(candidate_block);
            }

            let mut greedy_seeds = Vec::new();
            if options.beam_greedy_seeds {
                greedy_seeds
                    .try_reserve_exact(block_count)
                    .map_err(|_| Error::Limit)?;
                let mut seed_models = models.try_clone()?;
                let mut seed_state = state;
                for (index, candidate_block) in
                    candidate_blocks.iter().enumerate().take(block_count)
                {
                    let next_seed = if index + 1 < block_count {
                        let start = batch_start
                            .checked_add(index.checked_mul(options.beam_block).ok_or(Error::Limit)?)
                            .ok_or(Error::Limit)?;
                        let end = start.saturating_add(options.beam_block).min(input.len());
                        let context = WarmBtContext {
                            initial_models: &seed_models,
                            input,
                            start,
                            end,
                            dictionary: options.dictionary,
                            initial_state: seed_state,
                            candidates: candidate_block,
                        };
                        Some(greedy_bt_block_seed(&context, None, cancel)?)
                    } else {
                        None
                    };
                    greedy_seeds.push((seed_models.try_clone()?, seed_state));
                    if let Some((next_models, next_state)) = next_seed {
                        seed_models = next_models;
                        seed_state = next_state;
                    }
                }
            }

            let mut plans = Vec::new();
            plans
                .try_reserve_exact(block_count)
                .map_err(|_| Error::Limit)?;
            for (index, candidate_block) in candidate_blocks.iter_mut().enumerate() {
                check(cancel)?;
                let start = batch_start
                    .checked_add(index.checked_mul(options.beam_block).ok_or(Error::Limit)?)
                    .ok_or(Error::Limit)?;
                let end = start.saturating_add(options.beam_block).min(input.len());
                let (seed_models, seed_state) = if options.beam_greedy_seeds {
                    (&greedy_seeds[index].0, greedy_seeds[index].1)
                } else {
                    (&models, state)
                };
                let config = BeamParseConfig {
                    dictionary: options.dictionary,
                    initial_state: seed_state,
                    cache_prices,
                    width: options.beam_width,
                    block: options.beam_block,
                    model: options.beam_model,
                    matches: options.beam_matches,
                    rep_diverse_third_parent: options.beam_rep_diverse_third_parent,
                    fixed_rep_history: false,
                };
                let planned = beam_plan_bt4(
                    &mut prepared,
                    candidate_block,
                    seed_models,
                    input,
                    start,
                    config,
                    Some(end),
                    cancel,
                )?;
                if planned.is_empty()
                    || planned.iter().map(|token| token.length()).sum::<usize>() != end - start
                {
                    return Err(Error::Format("speculative plan crossed its fixed boundary"));
                }
                plans.push(resolve_absolute_plan(&planned, seed_state, start)?);
            }

            for plan in plans {
                let concrete = concretize_absolute_plan(&plan, state, pos)?;
                for token in concrete {
                    check(cancel)?;
                    if token.length() > input.len() - pos {
                        return Err(Error::Format("speculative token exceeds input"));
                    }
                    put_token(
                        &mut sink,
                        &mut models,
                        input,
                        pos,
                        &mut state.reps,
                        state.previous_match,
                        token,
                    )?;
                    pos += token.length();
                    state.previous_match = !matches!(token, Token::Literal);
                }
            }
        }
        check(cancel)?;
        Ok::<(), Error>(())
    };
    result?;
    coder.finish_fast().map_err(encode_error)
}

#[cfg(test)]
fn encode_beam_with_duplicate_maximum(
    input: &[u8],
    options: Options,
    cache_prices: bool,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    encode_beam_with_price_cache_mode::<true>(input, options, cache_prices, true, cancel)
}

/// mode 2 の range payload を `size` byteへ復元する。
const DECODE_MATCH_COPY_CHUNK: usize = 4096;

fn copy_match_bytes(
    output: &mut [u8],
    position: usize,
    distance: usize,
    length: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(), Error> {
    debug_assert!(distance > 0 && distance <= position);
    debug_assert!(
        position
            .checked_add(length)
            .is_some_and(|end| end <= output.len())
    );

    let mut copied = 0usize;
    let mut next_cancel_check = 0usize;
    while copied < length {
        if copied == next_cancel_check {
            check(cancel)?;
            next_cancel_check += DECODE_MATCH_COPY_CHUNK;
        }
        let remaining = length - copied;
        let cancel_budget = next_cancel_check - copied;
        let (source, count) = if distance >= length {
            let count = remaining.min(cancel_budget);
            (position - distance + copied, count)
        } else if distance > DECODE_MATCH_COPY_CHUNK {
            let count = remaining.min(cancel_budget);
            (position + copied - distance, count)
        } else if copied < distance {
            let count = (distance - copied).min(cancel_budget).min(remaining);
            (position - distance + copied, count)
        } else if remaining < distance {
            (position + copied - distance, remaining.min(cancel_budget))
        } else if copied.is_multiple_of(distance) {
            let maximum = copied.min(cancel_budget).min(remaining);
            let count = maximum - maximum % distance;
            if count == 0 {
                let count = distance.min(cancel_budget).min(remaining);
                (position + copied - distance, count)
            } else {
                (position + copied - count, count)
            }
        } else {
            let count = (distance - copied % distance)
                .min(cancel_budget)
                .min(remaining);
            (position + copied - distance, count)
        };
        debug_assert!(count > 0 && count <= DECODE_MATCH_COPY_CHUNK);
        output.copy_within(source..source + count, position + copied);
        copied += count;
    }
    Ok(())
}

enum DecodedToken {
    Literal(u8),
    Match {
        distance: usize,
        length: usize,
        rep_index: Option<usize>,
    },
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn decode_token<const DISTANCE_DELTA: bool>(
    coder: &mut impl BitSource,
    models: &mut Models,
    delta_models: &mut [u16; DISTANCE_CONTEXTS],
    output: &[u8],
    pos: usize,
    reps: [usize; 4],
    previous_match: bool,
    dictionary: usize,
) -> Result<DecodedToken, Error> {
    let context = token_context(previous_match, pos);
    if !get(coder, &mut models.is_match[context])? {
        return Ok(DecodedToken::Literal(get_literal(
            coder, models, output, pos, reps,
        )?));
    }

    let (distance, length, rep_index) = if get(coder, &mut models.is_rep[context])? {
        let index = if get(coder, &mut models.is_rep0[context])? {
            if get(coder, &mut models.is_short_rep[context])? {
                0
            } else {
                usize::MAX
            }
        } else if get(coder, &mut models.is_rep1[context])? {
            1
        } else if get(coder, &mut models.is_rep2[context])? {
            2
        } else {
            3
        };
        if index == 0 {
            (reps[0], 1, None)
        } else {
            let actual = if index == usize::MAX { 0 } else { index };
            let length = get_length(coder, &mut models.rep_length, context, 2)?;
            (reps[actual], length, Some(actual))
        }
    } else {
        let length = get_length(coder, &mut models.match_length, context, 3)?;
        let maximum = dictionary.min(pos);
        if maximum == 0 {
            return Err(Error::Format("match before dictionary"));
        }
        let distance = if DISTANCE_DELTA {
            get_distance_delta(coder, models, delta_models, length, maximum, reps[0])?
        } else {
            get_distance(coder, models, length, maximum)?
        };
        (distance, length, Some(4))
    };

    Ok(DecodedToken::Match {
        distance,
        length,
        rep_index,
    })
}

#[derive(Default)]
pub(crate) struct DecodeProfile {
    pub(crate) range_bit_calls: u64,
    pub(crate) match_copy_bytes: u64,
    pub(crate) decoded_tokens: u64,
    /// 1 bitあたりの正規化byte数。添字2は2 byte以上。RangeのPROFILE復号だけが非ゼロ。
    pub(crate) renorm_byte_events: [u64; 3],
}

pub(super) fn decode(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    decode_impl::<false, false>(payload, size, dictionary, cancel).map(|(output, _)| output)
}

/// `encode_history_seeded_chunks`のchunk表と独立Range streamを復元する。
/// 確率modelとRepはchunkごとにresetするが、copy元には復元済みglobal prefixを使う。
pub(super) fn decode_history_seeded_chunks(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if size > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }
    let count_bytes = payload
        .get(..4)
        .ok_or(Error::Format("truncated history-seeded chunk count"))?;
    let chunk_count = u32::from_le_bytes(
        count_bytes
            .try_into()
            .map_err(|_| Error::Format("history-seeded chunk count"))?,
    ) as usize;
    let expected_chunk_count = size.div_ceil(HISTORY_SEEDED_CHUNK);
    if chunk_count != expected_chunk_count {
        return Err(Error::Format("history-seeded chunk count mismatch"));
    }

    let mut output = buffer(size, 0u8)?;
    let mut cursor = 4usize;
    let mut chunk_start = 0usize;
    for chunk_index in 0..chunk_count {
        check(cancel)?;
        let header_end = cursor.checked_add(8).ok_or(Error::Limit)?;
        let header = payload
            .get(cursor..header_end)
            .ok_or(Error::Format("truncated history-seeded chunk header"))?;
        let plain_length = u32::from_le_bytes(
            header[..4]
                .try_into()
                .map_err(|_| Error::Format("history-seeded plain length"))?,
        ) as usize;
        let packed_length = u32::from_le_bytes(
            header[4..]
                .try_into()
                .map_err(|_| Error::Format("history-seeded packed length"))?,
        ) as usize;
        let expected_plain_length = if chunk_index + 1 == chunk_count {
            size.checked_sub(chunk_start).ok_or(Error::Limit)?
        } else {
            HISTORY_SEEDED_CHUNK
        };
        if plain_length == 0 || plain_length != expected_plain_length {
            return Err(Error::Format("history-seeded plain length mismatch"));
        }
        if packed_length == 0 || packed_length > plain_length {
            return Err(Error::Format("history-seeded packed length mismatch"));
        }
        let packed_end = header_end.checked_add(packed_length).ok_or(Error::Limit)?;
        let packed = payload
            .get(header_end..packed_end)
            .ok_or(Error::Format("truncated history-seeded chunk payload"))?;
        let chunk_end = chunk_start
            .checked_add(plain_length)
            .filter(|&end| end <= size)
            .ok_or(Error::Format("history-seeded plain total mismatch"))?;

        let mut models = history_seeded_models(&output, chunk_start, cancel)?;
        let mut coder = range::Decoder::<false>::new(packed).map_err(Error::Format)?;
        let mut reps = [1usize; 4];
        let mut previous_match = false;
        let mut delta_models = [16384u16; DISTANCE_CONTEXTS];
        let mut pos = chunk_start;
        while pos < chunk_end {
            check(cancel)?;
            let decoded = if coder.input_remaining() >= FAST_TOKEN_INPUT_MARGIN {
                // SAFETY: decode_implと同じ確率値域・token最大bit数・入力余裕を満たす。
                let mut fast = unsafe { FastTokenRange::new(&mut coder) };
                decode_token::<false>(
                    &mut fast,
                    &mut models,
                    &mut delta_models,
                    &output,
                    pos,
                    reps,
                    previous_match,
                    dictionary,
                )?
            } else {
                decode_token::<false>(
                    &mut coder,
                    &mut models,
                    &mut delta_models,
                    &output,
                    pos,
                    reps,
                    previous_match,
                    dictionary,
                )?
            };

            let (distance, length, rep_index) = match decoded {
                DecodedToken::Literal(value) => {
                    output[pos] = value;
                    pos += 1;
                    previous_match = false;
                    coder.advance_output(1).map_err(Error::Format)?;
                    continue;
                }
                DecodedToken::Match {
                    distance,
                    length,
                    rep_index,
                } => (distance, length, rep_index),
            };
            if distance == 0 || distance > dictionary || distance > pos {
                return Err(Error::Format("invalid history-seeded repeat distance"));
            }
            if length == 0 || length > chunk_end - pos {
                return Err(Error::Format("history-seeded token crosses chunk boundary"));
            }
            copy_match_bytes(&mut output, pos, distance, length, cancel)?;
            match rep_index {
                Some(index @ 0..=3) => move_rep(&mut reps, index),
                Some(4) => add_distance(&mut reps, distance),
                _ => {}
            }
            pos += length;
            previous_match = true;
            coder.advance_output(length).map_err(Error::Format)?;
        }
        if pos != chunk_end {
            return Err(Error::Format("history-seeded chunk output mismatch"));
        }
        coder.finish().map_err(Error::Format)?;
        cursor = packed_end;
        chunk_start = chunk_end;
    }
    if chunk_start != size || cursor != payload.len() {
        return Err(Error::Format("history-seeded payload totals mismatch"));
    }
    check(cancel)?;
    Ok(output)
}

pub(crate) fn decode_distance_delta(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    decode_impl::<false, true>(payload, size, dictionary, cancel).map(|(output, _)| output)
}

pub(super) fn decode_profile(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DecodeProfile), Error> {
    decode_impl::<true, false>(payload, size, dictionary, cancel)
}

pub(super) fn decode_rans(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    decode_rans_impl::<false>(payload, size, dictionary, cancel).map(|(output, _)| output)
}

pub(super) fn decode_rans_profile(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DecodeProfile), Error> {
    decode_rans_impl::<true>(payload, size, dictionary, cancel)
}

fn decode_impl<const PROFILE: bool, const DISTANCE_DELTA: bool>(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DecodeProfile), Error> {
    let coder = range::Decoder::<PROFILE>::new(payload).map_err(Error::Format)?;
    decode_impl_with::<PROFILE, DISTANCE_DELTA, _>(coder, size, dictionary, cancel)
}

fn decode_rans_impl<const PROFILE: bool>(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DecodeProfile), Error> {
    let coder =
        super::rans::SegmentedDecoder::<PROFILE>::new(payload, size).map_err(Error::Format)?;
    decode_impl_with::<PROFILE, false, _>(coder, size, dictionary, cancel)
}

fn decode_impl_with<const PROFILE: bool, const DISTANCE_DELTA: bool, C: DecoderSource>(
    mut coder: C,
    size: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DecodeProfile), Error> {
    check(cancel)?;
    if size > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }
    let mut output = buffer(size, 0u8)?;
    let mut models = Models::new()?;
    let mut profile = DecodeProfile::default();
    let mut reps = [1usize; 4];
    let mut delta_models = [16384u16; DISTANCE_CONTEXTS];
    let mut previous_match = false;
    let mut pos = 0usize;
    while pos < size {
        check(cancel)?;
        let decoded = if coder.input_remaining() >= FAST_TOKEN_INPUT_MARGIN {
            // SAFETY: モデル確率は1..32768。通常matchはis-match/repの2 bit、
            // 最大22 bitのlength、最大31 bitのdistanceで55 bit。どちらのcoderも
            // bitごとのrenormalization読取りは最大2 byteなので、128 byte余裕で足りる。
            let mut fast = unsafe { FastTokenRange::new(&mut coder) };
            decode_token::<DISTANCE_DELTA>(
                &mut fast,
                &mut models,
                &mut delta_models,
                &output,
                pos,
                reps,
                previous_match,
                dictionary,
            )?
        } else {
            decode_token::<DISTANCE_DELTA>(
                &mut coder,
                &mut models,
                &mut delta_models,
                &output,
                pos,
                reps,
                previous_match,
                dictionary,
            )?
        };
        profile.decoded_tokens = profile.decoded_tokens.saturating_add(1);

        let (distance, length, rep_index) = match decoded {
            DecodedToken::Literal(value) => {
                output[pos] = value;
                pos += 1;
                previous_match = false;
                coder.advance_output(1).map_err(Error::Format)?;
                continue;
            }
            DecodedToken::Match {
                distance,
                length,
                rep_index,
            } => (distance, length, rep_index),
        };

        if distance == 0 || distance > dictionary || distance > pos {
            return Err(Error::Format("invalid repeat distance"));
        }
        if length > size - pos {
            return Err(Error::Format("match exceeds output"));
        }
        copy_match_bytes(&mut output, pos, distance, length, cancel)?;
        if PROFILE {
            profile.match_copy_bytes = profile.match_copy_bytes.saturating_add(length as u64);
        }
        match rep_index {
            Some(index @ 0..=3) => move_rep(&mut reps, index),
            Some(4) => add_distance(&mut reps, distance),
            _ => {}
        }
        pos += length;
        previous_match = true;
        coder.advance_output(length).map_err(Error::Format)?;
    }
    profile.range_bit_calls = coder.bit_calls();
    profile.renorm_byte_events = coder.renorm_byte_events();
    coder.finish().map_err(Error::Format)?;
    check(cancel)?;
    Ok((output, profile))
}

/// 同じtoken列のまま、入力位置 `pos / interval` が変わるまで確率更新を保留する。
/// 窓の開始時に直前の窓の更新を順に適用する。token列とwireの意味は変えず、
/// 適応のタイミングだけを止めるsize screenである。
struct DeferredRange<'a> {
    inner: FastRangeSink<'a>,
    interval: usize,
    bucket: usize,
    pending: Vec<(*mut u16, bool)>,
}

impl BitSink for DeferredRange<'_> {
    fn bit(&mut self, probability: u16, bit: bool) -> Result<(), Error> {
        self.inner.bit(probability, bit)
    }

    fn defer_update(&mut self, probability: &mut u16, bit: bool) -> bool {
        self.pending.push((probability as *mut u16, bit));
        true
    }
}

impl DeferredRange<'_> {
    fn note(&mut self, pos: usize) -> Result<(), Error> {
        let bucket = pos / self.interval;
        if bucket == self.bucket {
            return Ok(());
        }
        self.bucket = bucket;
        self.flush()
    }

    fn flush(&mut self) -> Result<(), Error> {
        let pending = std::mem::take(&mut self.pending);
        for (cell, bit) in pending {
            // SAFETY: pointerはいまのemit呼出しが所有するModelsのセル。
            // put_tokenの参照が終わったあと、Modelsを動かさない間だけ適用する。
            unsafe { update(&mut *cell, bit) };
        }
        Ok(())
    }
}

fn tokens_from_selected(tokens: &[SelectedToken]) -> Result<Vec<Token>, Error> {
    let mut plan = Vec::new();
    plan.try_reserve_exact(tokens.len())
        .map_err(|_| Error::Limit)?;
    let mut pos = 0usize;
    for token in tokens {
        let offset = expand_u32(token.offset);
        let length = expand_u32(token.length);
        if offset != pos || length == 0 {
            return Err(Error::Format("selected token trace is not contiguous"));
        }
        let decoded = match token.kind {
            0 if length == 1 => Token::Literal,
            1 if length == 1 => Token::ShortRep,
            2 if length >= 2 => Token::Rep {
                index: usize::from(token.rep_index),
                length,
            },
            3 if length >= 3 => Token::Match {
                distance: expand_u32(token.distance),
                length,
            },
            _ => return Err(Error::Format("selected token trace has an invalid token")),
        };
        if let Token::Rep { index, .. } = decoded
            && index > 3
        {
            return Err(Error::Format("selected token trace has an invalid rep"));
        }
        plan.push(decoded);
        pos = pos
            .checked_add(length)
            .ok_or(Error::Format("selected token trace overflows"))?;
    }
    Ok(plan)
}

/// 元のtraceを一度だけ検証・変換し、parser外のcoder replay用に保持する。
pub(crate) struct PreparedTokenReplay {
    tokens: Vec<Token>,
    plain_bytes: usize,
}

pub(crate) fn prepare_token_replay(
    plain_bytes: usize,
    tokens: &[SelectedToken],
) -> Result<PreparedTokenReplay, Error> {
    let plan = tokens_from_selected(tokens)?;
    let mut covered = 0usize;
    for token in &plan {
        covered = covered
            .checked_add(token.length())
            .ok_or(Error::Format("selected token trace overflows"))?;
    }
    if covered != plain_bytes {
        return Err(Error::Format(
            "selected token trace does not cover the input",
        ));
    }
    Ok(PreparedTokenReplay {
        tokens: plan,
        plain_bytes,
    })
}

pub(crate) fn emit_prepared_token_replay(
    input: &[u8],
    plan: &PreparedTokenReplay,
    interval: Option<usize>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    if input.len() != plan.plain_bytes {
        return Err(Error::Format(
            "prepared token trace belongs to a different input length",
        ));
    }
    let mut coder = range::Encoder::with_limit(input.len()).map_err(encode_error)?;
    let mut models = Models::new()?;
    let mut state = ParseState {
        reps: [1usize; 4],
        previous_match: false,
    };
    let mut pos = 0usize;
    if let Some(interval) = interval {
        if interval == 0 {
            return Err(Error::Format("adapt freeze interval is invalid"));
        }
        let mut sink = DeferredRange {
            inner: FastRangeSink(&mut coder),
            interval,
            bucket: 0,
            pending: Vec::new(),
        };
        sink.pending
            .try_reserve(interval.saturating_mul(8).max(64))
            .map_err(|_| Error::Limit)?;
        for &token in &plan.tokens {
            check(cancel)?;
            sink.note(pos)?;
            put_token(
                &mut sink,
                &mut models,
                input,
                pos,
                &mut state.reps,
                state.previous_match,
                token,
            )?;
            pos += token.length();
            state.previous_match = !matches!(token, Token::Literal);
        }
    } else {
        let mut sink = FastRangeSink(&mut coder);
        for &token in &plan.tokens {
            check(cancel)?;
            put_token(
                &mut sink,
                &mut models,
                input,
                pos,
                &mut state.reps,
                state.previous_match,
                token,
            )?;
            pos += token.length();
            state.previous_match = !matches!(token, Token::Literal);
        }
    }
    check(cancel)?;
    coder.finish_fast().map_err(encode_error)
}

fn emit_selected_tokens(
    input: &[u8],
    tokens: &[SelectedToken],
    interval: Option<usize>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    let plan = prepare_token_replay(input.len(), tokens)?;
    emit_prepared_token_replay(input, &plan, interval, cancel)
}

/// Standardの絶対距離copy traceを、parseを変えずにmethod-2 Rep4 grammarで再符号化する。
/// 研究screen専用であり、通常encoderの選択経路には入らない。
pub(crate) fn reencode_standard_trace_as_method2(
    input: &[u8],
    dictionary: usize,
    memory_budget: usize,
    mut selected: Vec<SelectedToken>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, Vec<SelectedToken>), Error> {
    if input.len() > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY {
        return Err(Error::Limit);
    }
    let required_memory = input
        .len()
        .checked_mul(4)
        .and_then(|bytes| {
            selected
                .capacity()
                .checked_mul(std::mem::size_of::<SelectedToken>())
                .and_then(|trace_bytes| bytes.checked_add(trace_bytes))
        })
        .and_then(|bytes| {
            selected
                .len()
                .checked_mul(std::mem::size_of::<Token>())
                .and_then(|plan_bytes| bytes.checked_add(plan_bytes))
        })
        .and_then(|bytes| bytes.checked_add(8 * 1024 * 1024))
        .ok_or(Error::Limit)?;
    if required_memory > memory_budget {
        return Err(Error::Limit);
    }
    let mut reps = [1usize; 4];
    let mut expected_offset = 0usize;
    for (index, item) in selected.iter_mut().enumerate() {
        if index & 0x3ff == 0 {
            check(cancel)?;
        }
        let start = usize::try_from(item.offset).map_err(|_| Error::Limit)?;
        let length = usize::try_from(item.length).map_err(|_| Error::Limit)?;
        let distance = usize::try_from(item.distance).map_err(|_| Error::Limit)?;
        let end = start.checked_add(length).ok_or(Error::Limit)?;
        if start != expected_offset || length == 0 || end > input.len() || item.rep_index != 0 {
            return Err(Error::Format(
                "standard token trace is invalid or non-contiguous",
            ));
        }
        match item.kind {
            0 if length == 1 && distance == 0 => {}
            3 if length >= 3 && distance != 0 && distance <= start && distance <= dictionary => {
                for offset in 0..length {
                    if input[start + offset] != input[start + offset - distance] {
                        return Err(Error::Format(
                            "standard copy trace does not reconstruct input",
                        ));
                    }
                }
                if let Some(rep_index) = reps.iter().position(|&rep| rep == distance) {
                    item.kind = 2;
                    item.rep_index = u8::try_from(rep_index).map_err(|_| Error::Limit)?;
                    move_rep(&mut reps, rep_index);
                } else {
                    item.kind = 3;
                    item.rep_index = 0;
                    add_distance(&mut reps, distance);
                }
            }
            _ => return Err(Error::Format("standard token trace has an invalid token")),
        }
        expected_offset = end;
    }
    if expected_offset != input.len() {
        return Err(Error::Format(
            "standard token trace does not cover the input",
        ));
    }
    check(cancel)?;
    let payload = emit_selected_tokens(input, &selected, None, cancel)?;
    Ok((payload, selected))
}

fn emit_selected_tokens_distance_delta(
    input: &[u8],
    tokens: &[SelectedToken],
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u8>, DistanceDeltaScreen), Error> {
    let plan = tokens_from_selected(tokens)?;
    let mut covered = 0usize;
    for token in &plan {
        covered = covered
            .checked_add(token.length())
            .ok_or(Error::Format("selected token trace overflows"))?;
    }
    if covered != input.len() {
        return Err(Error::Format(
            "selected token trace does not cover the input",
        ));
    }

    let limit = input.len().checked_mul(2).ok_or(Error::Limit)?;
    let mut coder = range::Encoder::with_limit(limit).map_err(encode_error)?;
    let mut models = Models::new()?;
    let mut delta_models = [16384u16; DISTANCE_CONTEXTS];
    let mut stats = DistanceDeltaScreen {
        token_count: plan.len(),
        ..DistanceDeltaScreen::default()
    };
    let mut reps = [1usize; 4];
    let mut previous_match = false;
    let mut pos = 0usize;
    let mut sink = FastRangeSink(&mut coder);
    for token in plan {
        check(cancel)?;
        put_token_distance_delta(
            &mut sink,
            &mut models,
            &mut delta_models,
            &mut stats,
            input,
            pos,
            &mut reps,
            previous_match,
            token,
        )?;
        pos += token.length();
        previous_match = !matches!(token, Token::Literal);
    }
    check(cancel)?;
    Ok((coder.finish_fast().map_err(encode_error)?, stats))
}

pub(crate) fn screen_distance_delta(
    input: &[u8],
    options: Options,
    cancel: &mut impl FnMut() -> bool,
) -> Result<DistanceDeltaScreen, Error> {
    if options.entropy_backend != super::EntropyBackend::Range {
        return Err(Error::Format(
            "distance-delta screen requires range entropy backend",
        ));
    }
    if !matches!(options.algorithm, super::Algorithm::Beam)
        || !matches!(options.beam_model, super::BeamModel::Blended)
        || !matches!(options.beam_matches, BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err(Error::Format(
            "distance-delta screen requires Blended/W2/B8192/BT5 baseline options",
        ));
    }

    let baseline_frame = super::encode(input, options, cancel)?;
    let (baseline_payload, _, selected) =
        encode_beam_with_selected_copy_capture(input, options, cancel)?;
    if baseline_frame.get(super::HEADER..) != Some(baseline_payload.as_slice()) {
        return Err(Error::Format(
            "capture payload differs from normal beam output",
        ));
    }
    let baseline_replay = emit_selected_tokens(input, &selected, None, cancel)?;
    if baseline_replay != baseline_payload {
        return Err(Error::Format("baseline token replay diverged"));
    }

    let (candidate_payload, mut stats) =
        emit_selected_tokens_distance_delta(input, &selected, cancel)?;
    let repeated_payload = emit_selected_tokens_distance_delta(input, &selected, cancel)?.0;
    if repeated_payload != candidate_payload {
        return Err(Error::Format(
            "distance-delta encoding is not deterministic",
        ));
    }
    let decoded =
        decode_distance_delta(&candidate_payload, input.len(), options.dictionary, cancel)?;
    if decoded != input {
        return Err(Error::Format("distance-delta round-trip mismatch"));
    }

    stats.baseline_frame_bytes = baseline_frame.len();
    stats.candidate_frame_bytes = super::HEADER
        .checked_add(candidate_payload.len())
        .ok_or(Error::Limit)?;
    stats.round_trip_verified = true;
    stats.deterministic = true;
    if stats.delta_events + stats.absolute_escape_events != stats.normal_match_events {
        return Err(Error::Format("distance-delta event accounting mismatch"));
    }
    Ok(stats)
}

struct DeferredAdapt {
    interval: usize,
    bucket: usize,
    pending: Vec<(*mut u16, bool)>,
}

std::thread_local! {
    static DEFER_ADAPT: std::cell::RefCell<Option<DeferredAdapt>> =
        const { std::cell::RefCell::new(None) };
}

struct DeferredAdaptGuard;

impl Drop for DeferredAdaptGuard {
    fn drop(&mut self) {
        DEFER_ADAPT.with(|slot| slot.borrow_mut().take());
    }
}

fn install_deferred_adapt(interval: usize) -> Result<DeferredAdaptGuard, Error> {
    if interval == 0 {
        return Err(Error::Format("adapt freeze interval is invalid"));
    }
    DEFER_ADAPT.with(|slot| {
        *slot.borrow_mut() = Some(DeferredAdapt {
            interval,
            bucket: 0,
            pending: Vec::new(),
        });
    });
    Ok(DeferredAdaptGuard)
}

fn defer_adapt_push(cell: &mut u16, bit: bool) -> Result<(), Error> {
    DEFER_ADAPT.with(|slot| {
        let mut guard = slot.borrow_mut();
        let state = guard
            .as_mut()
            .ok_or(Error::Format("deferred adapt is not active"))?;
        state.pending.try_reserve(1).map_err(|_| Error::Limit)?;
        state.pending.push((cell as *mut u16, bit));
        Ok(())
    })
}

fn note_deferred_position(pos: usize) -> Result<(), Error> {
    let pending = DEFER_ADAPT.with(|slot| {
        let mut guard = slot.borrow_mut();
        let state = guard
            .as_mut()
            .ok_or(Error::Format("deferred adapt is not active"))?;
        let bucket = pos / state.interval;
        if bucket == state.bucket {
            return Ok(None);
        }
        state.bucket = bucket;
        Ok(Some(std::mem::take(&mut state.pending)))
    })?;
    if let Some(pending) = pending {
        for (cell, bit) in pending {
            // SAFETY: decode_deferredが所有するModelsのセル。getの参照終了後、
            // Modelsを動かさない間だけ更新を再生する。
            unsafe { update(&mut *cell, bit) };
        }
    }
    Ok(())
}

pub(crate) fn screen_adapt_freeze(
    input: &[u8],
    options: Options,
    intervals: &[usize],
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<(usize, usize)>, Error> {
    if options.entropy_backend != super::EntropyBackend::Range {
        return Err(Error::Format(
            "adapt-freeze screen requires range entropy backend",
        ));
    }
    let (payload, _, tokens) = encode_beam_with_selected_copy_capture(input, options, cancel)?;
    let replay = emit_selected_tokens(input, &tokens, None, cancel)?;
    if replay != payload {
        return Err(Error::Format("token replay diverged from beam payload"));
    }
    let mut frames = Vec::new();
    frames
        .try_reserve_exact(intervals.len())
        .map_err(|_| Error::Limit)?;
    for &interval in intervals {
        check(cancel)?;
        let deferred = emit_selected_tokens(input, &tokens, Some(interval), cancel)?;
        let decoded =
            decode_deferred(&deferred, input.len(), options.dictionary, interval, cancel)?;
        if decoded != input {
            return Err(Error::Format("deferred adapt decoder mismatch"));
        }
        let frame_bytes = HEADER.checked_add(deferred.len()).ok_or(Error::Limit)?;
        frames.push((interval, frame_bytes));
    }
    Ok(frames)
}

fn decode_deferred(
    payload: &[u8],
    size: usize,
    dictionary: usize,
    interval: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if size > MAX_INPUT || dictionary == 0 || dictionary > MAX_DICTIONARY || interval == 0 {
        return Err(Error::Limit);
    }
    let _guard = install_deferred_adapt(interval)?;
    let mut output = buffer(size, 0u8)?;
    let mut models = Models::new()?;
    let mut coder = range::Decoder::<false>::new(payload).map_err(Error::Format)?;
    let mut reps = [1usize; 4];
    let mut previous_match = false;
    let mut pos = 0usize;
    while pos < size {
        check(cancel)?;
        note_deferred_position(pos)?;
        let context = token_context(previous_match, pos);
        if !get_defer(&mut coder, &mut models.is_match[context])? {
            let value = get_literal_defer(&mut coder, &mut models, &output, pos, reps)?;
            output[pos] = value;
            pos += 1;
            previous_match = false;
            continue;
        }

        let (distance, length, rep_index) = if get_defer(&mut coder, &mut models.is_rep[context])? {
            let index = if get_defer(&mut coder, &mut models.is_rep0[context])? {
                if get_defer(&mut coder, &mut models.is_short_rep[context])? {
                    0
                } else {
                    usize::MAX
                }
            } else if get_defer(&mut coder, &mut models.is_rep1[context])? {
                1
            } else if get_defer(&mut coder, &mut models.is_rep2[context])? {
                2
            } else {
                3
            };
            if index == 0 {
                (reps[0], 1, None)
            } else {
                let actual = if index == usize::MAX { 0 } else { index };
                let length = get_length_defer(&mut coder, &mut models.rep_length, context, 2)?;
                (reps[actual], length, Some(actual))
            }
        } else {
            let length = get_length_defer(&mut coder, &mut models.match_length, context, 3)?;
            let maximum = dictionary.min(pos);
            if maximum == 0 {
                return Err(Error::Format("match before dictionary"));
            }
            let distance = get_distance_defer(&mut coder, &mut models, length, maximum)?;
            (distance, length, Some(4))
        };

        if distance == 0 || distance > dictionary || distance > pos {
            return Err(Error::Format("invalid repeat distance"));
        }
        if length > size - pos {
            return Err(Error::Format("match exceeds output"));
        }
        copy_match_bytes(&mut output, pos, distance, length, cancel)?;
        match rep_index {
            Some(index @ 0..=3) => move_rep(&mut reps, index),
            Some(4) => add_distance(&mut reps, distance),
            _ => {}
        }
        pos += length;
        previous_match = true;
    }
    coder.finish().map_err(Error::Format)?;
    check(cancel)?;
    Ok(output)
}

/// 親frame、借用入力、range候補、hash索引とmodelを含む保守的な要求容量。
pub(super) fn encode_memory(input_size: usize, dictionary: usize) -> Option<usize> {
    if dictionary == 0 || dictionary > MAX_DICTIONARY || input_size > MAX_INPUT {
        return None;
    }
    input_size
        .checked_mul(7)?
        .checked_add(HASH_SIZE.checked_mul(4)?)?
        .checked_add(MODEL_MEMORY)?
        .checked_add(FIXED_MEMORY)?
        .checked_add(super::prices::MEMORY_BYTES)?
        .checked_add(HEADER)
}

fn find_trace_memory(block: usize) -> Option<usize> {
    block
        .checked_mul(std::mem::size_of::<FindTraceRecord>())?
        .checked_add(
            block
                .checked_mul(MAX_CHAIN)?
                .checked_mul(std::mem::size_of::<FindTraceEntry>())?,
        )
}

/// lazy encoderの資源式へ、指定幅のbeam表と指定block分のbacktrack列を加えた要求容量。
pub(super) fn encode_beam_memory(
    input_size: usize,
    dictionary: usize,
    width: usize,
    block: usize,
    model: BeamModel,
    matches: BeamMatches,
) -> Option<usize> {
    if !valid_beam_width(width) || !valid_beam_block(block) {
        return None;
    }
    let beam_nodes = block
        .checked_add(1)?
        .checked_mul(width)?
        .checked_mul(std::mem::size_of::<BeamNode>())?;
    let plan = block.checked_mul(std::mem::size_of::<Token>())?;
    let price_cache = TOKEN_CONTEXTS
        .checked_mul(block.checked_add(1)?)?
        .checked_mul(2)?
        .checked_mul(std::mem::size_of::<CachedLengthPrice>())?;
    let literal_price_cache =
        LITERAL_PAYLOAD_CACHE_ENTRIES.checked_mul(std::mem::size_of::<CachedLiteralPrice>())?;
    let learned_model_and_trace = match (model, matches) {
        (BeamModel::Current, _) => 0,
        (
            BeamModel::Warm | BeamModel::Blended,
            BeamMatches::Bt4
            | BeamMatches::Bt5
            | BeamMatches::Exact4
            | BeamMatches::Hybrid
            | BeamMatches::R4
            | BeamMatches::R5,
        ) => MODEL_MEMORY,
        (BeamModel::Warm | BeamModel::Blended, _) => {
            MODEL_MEMORY.checked_add(find_trace_memory(block)?)?
        }
    };
    let dedicated = if matches!(matches, BeamMatches::Bt4 | BeamMatches::Bt5) {
        bt::extra_memory(input_size, block)?
            .checked_add(DISTANCE_PRICE_TABLE_MEMORY)?
            .checked_add(MATCH_CANDIDATE_MEMORY)?
            .checked_add(if width == 4 { REP_BOUNDARY_MEMORY } else { 0 })?
    } else if matches!(matches, BeamMatches::Exact4) {
        bt::exact4_extra_memory(input_size, block)?
            .checked_add(DISTANCE_PRICE_TABLE_MEMORY)?
            .checked_add(MATCH_CANDIDATE_MEMORY)?
            .checked_add(if width == 4 { REP_BOUNDARY_MEMORY } else { 0 })?
    } else if matches!(matches, BeamMatches::Hybrid)
        && (input_size <= hybrid::NEAR_WINDOW || dictionary <= hybrid::NEAR_WINDOW)
    {
        bt::extra_memory(input_size, block)?
            .checked_add(DISTANCE_PRICE_TABLE_MEMORY)?
            .checked_add(MATCH_CANDIDATE_MEMORY)?
            .checked_add(if width == 4 { REP_BOUNDARY_MEMORY } else { 0 })?
    } else if matches!(matches, BeamMatches::Hybrid) {
        hybrid::extra_memory(block, dictionary)?
            .checked_add(DISTANCE_PRICE_TABLE_MEMORY)?
            .checked_add(MATCH_CANDIDATE_MEMORY)?
            .checked_add(if width == 4 { REP_BOUNDARY_MEMORY } else { 0 })?
    } else if matches!(matches, BeamMatches::R4 | BeamMatches::R5) {
        let config = if matches!(matches, BeamMatches::R4) {
            row::Config::R4
        } else {
            row::Config::R5
        };
        row::extra_memory(block, config)?
            .checked_add(DISTANCE_PRICE_TABLE_MEMORY)?
            .checked_add(MATCH_CANDIDATE_MEMORY)?
            .checked_add(if width == 4 { REP_BOUNDARY_MEMORY } else { 0 })?
    } else {
        0
    };
    encode_memory(input_size, dictionary)?
        .checked_add(beam_nodes)?
        .checked_add(plan)?
        .checked_add(price_cache)?
        .checked_add(literal_price_cache)?
        .checked_add(learned_model_and_trace)?
        .checked_add(dedicated)?
        .checked_add(BEAM_FIXED_WORKING_MEMORY)
}

/// 連続blockを同一の開始stateから投機parseする実験用の追加要求容量。
#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
pub(super) fn encode_beam_batch_memory(
    input_size: usize,
    dictionary: usize,
    width: usize,
    block: usize,
    model: BeamModel,
    matches: BeamMatches,
    batch_blocks: usize,
    greedy_seeds: bool,
) -> Option<usize> {
    if batch_blocks == 1 {
        return encode_beam_memory(input_size, dictionary, width, block, model, matches);
    }
    if !(2..=4).contains(&batch_blocks) || !matches!(matches, BeamMatches::Bt5) {
        return None;
    }

    let baseline = encode_beam_memory(input_size, dictionary, width, block, model, matches)?;
    let baseline_plan = block.checked_mul(std::mem::size_of::<Token>())?;
    let batched_plans = block.checked_mul(
        batch_blocks
            .checked_mul(std::mem::size_of::<AbsoluteToken>())?
            .checked_add(std::mem::size_of::<Token>())?
            .checked_add(std::mem::size_of::<Token>())?
            .checked_add(std::mem::size_of::<AbsoluteToken>())?,
    )?;
    let extra_snapshots = batch_blocks
        .checked_sub(1)?
        .checked_mul(bt::block_memory(block, bt::MAX_DEPTH)?)?
        .checked_add(batch_blocks.checked_mul(std::mem::size_of::<bt::Block>())?)?
        .checked_add(batch_blocks.checked_mul(std::mem::size_of::<Vec<AbsoluteToken>>())?)?;
    let extra_models = if greedy_seeds {
        batch_blocks.checked_add(1)?.checked_mul(MODEL_MEMORY)?
    } else {
        0
    };
    baseline
        .checked_sub(baseline_plan)?
        .checked_add(batched_plans)?
        .checked_add(extra_snapshots)?
        .checked_add(extra_models)
}

pub(super) fn encode_beam_required_memory(input_size: usize, options: Options) -> Option<usize> {
    let base = encode_beam_batch_memory(
        input_size,
        options.dictionary,
        options.beam_width,
        options.beam_block,
        options.beam_model,
        options.beam_matches,
        options.beam_batch_blocks,
        options.beam_greedy_seeds,
    )?;
    let journal = match options.entropy_backend {
        super::EntropyBackend::Range => 0,
        super::EntropyBackend::Rans => input_size.min(super::rans::MAX_SEGMENT_PLAIN).checked_mul(
            super::rans::MAX_EVENTS_PER_INPUT_BYTE.checked_mul(std::mem::size_of::<u16>())?,
        )?,
    };
    // 通常Beamのbaseは入力長相当のRange候補を1本含む。history-seeded形式では
    // それを蓄積済みpayloadとみなし、同時に生存する作成中chunkとchunk表だけを足す。
    let history_seeded = if options.beam_history_seeded {
        let chunk_count = input_size.div_ceil(HISTORY_SEEDED_CHUNK);
        chunk_count
            .checked_mul(8)?
            .checked_add(4)?
            .checked_add(input_size.min(HISTORY_SEEDED_CHUNK))?
    } else {
        0
    };
    base.checked_add(journal)?
        .checked_add(if options.beam_fixed_rep_history {
            fixed_rep_history_extra_memory(options.beam_block)?
        } else {
            0
        })
        .and_then(|required| required.checked_add(history_seeded))
}

pub(super) fn fixed_rep_history_extra_memory(block: usize) -> Option<usize> {
    block.checked_add(1)?.checked_mul(
        std::mem::size_of::<ParseState>().checked_add(std::mem::size_of::<FixedHistoryNode>())?,
    )
}

/// 最悪payload、親frame、復号出力とmodelを含む保守的な要求容量。
pub(super) fn decode_memory(size: usize) -> Option<usize> {
    if size > MAX_INPUT {
        return None;
    }
    size.checked_mul(3)?
        .checked_add(MODEL_MEMORY)?
        .checked_add(FIXED_MEMORY)?
        .checked_add(HEADER)
}

