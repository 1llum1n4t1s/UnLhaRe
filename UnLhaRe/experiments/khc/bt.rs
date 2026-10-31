//! 研究用beamだけで使う増分BT4 match finder。
//!
//! 木は入力位置の昇順に一度だけ更新する。Warm/Blendedの暫定parseと本beamは同じ位置を
//! 複数回参照するため、探索結果はblock単位のimmutable snapshotへ保存する。

use super::{Error, buffer, check};

const HASH_BITS: usize = 19;
const HASH_SIZE: usize = 1 << HASH_BITS;
const NONE: u32 = u32::MAX;
const EXACT4_UNSEEN: u32 = u32::MAX - 1;
const EXACT4_MAX_OCCUPIED: usize = HASH_SIZE * 7 / 10;
pub(super) const MAX_DEPTH: usize = 48;
const MAX_COMPARE: usize = 1 << 16;
const MAX_MATCH: usize = 1 << 16;
const COMPARE_CHUNK: usize = 8;
// 木の大小関係はquery上限に依存させず、固定prefixで決める。完全一致prefixは同値として
// 子を引き継ぐ。実際の候補長だけを、その位置のquery上限まで別に延長する。
const STRUCTURAL_PREFIX: usize = 128;

#[derive(Clone, Copy)]
struct MatchLimits {
    query: usize,
    snapshot: usize,
}

impl MatchLimits {
    const NONE: Self = Self {
        query: 0,
        snapshot: 0,
    };
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Candidate {
    distance: u32,
    length: u32,
}

impl Candidate {
    pub(super) const EMPTY: Self = Self {
        distance: 0,
        length: 0,
    };

    pub(super) fn new(distance: usize, length: usize) -> Result<Self, Error> {
        Ok(Self {
            distance: u32::try_from(distance).map_err(|_| Error::Limit)?,
            length: u32::try_from(length).map_err(|_| Error::Limit)?,
        })
    }

    pub(super) fn distance(self) -> usize {
        self.distance as usize
    }

    pub(super) fn length(self) -> usize {
        self.length as usize
    }
}

/// block末尾で切った長さが、それ以前の最大長と同じか更新するときだけ保存する。
/// 同長候補は価格model確定後の距離選択に必要なので全て残す。
fn keep_candidate(best_length: &mut usize, length: usize, maximum: usize) -> bool {
    let effective = length.min(maximum);
    if effective < *best_length {
        return false;
    }
    *best_length = (*best_length).max(effective);
    true
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Record {
    start: u32,
    length: u32,
}

/// 4-byte値を衝突なく識別する研究用directory。`root`は構築中だけ出現数、構築後は
/// `EXACT4_UNSEEN`または最後に登録した入力位置を表す。全u32 keyを受け付けるため、
/// 空slotはrootの`NONE`で区別する。
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Exact4Root {
    key: u32,
    root: u32,
}

impl Exact4Root {
    const EMPTY: Self = Self { key: 0, root: NONE };
}

const _: () = assert!(std::mem::size_of::<Exact4Root>() == 8);

pub(super) struct Block {
    start: usize,
    length: usize,
    records: Vec<Record>,
    candidates: Vec<Candidate>,
    capacity: usize,
    raw: [Candidate; MAX_DEPTH],
    expanded_raw: Vec<Candidate>,
}

impl Block {
    pub(super) fn new(block: usize) -> Result<Self, Error> {
        Self::new_with_depth(block, MAX_DEPTH)
    }

    pub(super) fn new_with_depth(block: usize, depth: usize) -> Result<Self, Error> {
        let capacity = block.checked_mul(depth).ok_or(Error::Limit)?;
        let records = buffer(block, Record::default())?;
        let mut candidates = Vec::new();
        candidates
            .try_reserve_exact(capacity)
            .map_err(|_| Error::Limit)?;
        let expanded_raw = if depth > MAX_DEPTH {
            buffer(depth, Candidate::EMPTY)?
        } else {
            Vec::new()
        };
        Ok(Self {
            start: 0,
            length: 0,
            records,
            candidates,
            capacity,
            raw: [Candidate::EMPTY; MAX_DEPTH],
            expanded_raw,
        })
    }

    #[cfg(test)]
    pub(super) fn candidates(&self, pos: usize) -> &[Candidate] {
        let Some(local) = pos.checked_sub(self.start) else {
            return &[];
        };
        self.candidates_local(local)
    }

    #[cfg(test)]
    pub(super) fn test_snapshot(
        start: usize,
        entries: &[(usize, usize)],
        maximum: Option<usize>,
    ) -> Self {
        assert!(entries.windows(2).all(|pair| pair[0].0 < pair[1].0));
        let mut result = Self::new(1).unwrap();
        result.begin(start, 1).unwrap();
        let mut best = 3usize;
        for &(distance, length) in entries {
            if maximum.is_none_or(|maximum| keep_candidate(&mut best, length, maximum)) {
                result.candidates.push(Candidate {
                    distance: u32::try_from(distance).unwrap(),
                    length: u32::try_from(length).unwrap(),
                });
            }
        }
        result.capacity = result.capacity.max(result.candidates.len());
        result.records[0] = Record {
            start: 0,
            length: u32::try_from(result.candidates.len()).unwrap(),
        };
        result
    }

    pub(super) fn candidates_local(&self, local: usize) -> &[Candidate] {
        if local >= self.length {
            return &[];
        }
        let Some(record) = self.records.get(local).copied() else {
            return &[];
        };
        let start = record.start as usize;
        let end = start + record.length as usize;
        &self.candidates[start..end]
    }

    pub(super) fn begin(&mut self, start: usize, length: usize) -> Result<(), Error> {
        if length > self.records.len() {
            return Err(Error::Limit);
        }
        self.start = start;
        self.length = length;
        self.records[..length].fill(Record::default());
        self.candidates.clear();
        Ok(())
    }

    pub(super) fn store(&mut self, local: usize, count: usize) -> Result<(), Error> {
        // insertが今回書き込んだprefixだけを公開し、古いsuffixは参照しない。
        let values = if self.expanded_raw.is_empty() {
            &self.raw[..count]
        } else {
            &self.expanded_raw[..count]
        };
        if self.capacity.saturating_sub(self.candidates.len()) < values.len() {
            return Err(Error::Limit);
        }
        let start = self.candidates.len();
        self.candidates.extend_from_slice(values);
        self.records[local] = Record {
            start: u32::try_from(start).map_err(|_| Error::Limit)?,
            length: u32::try_from(values.len()).map_err(|_| Error::Limit)?,
        };
        Ok(())
    }

    pub(super) fn scratch_mut(&mut self) -> &mut [Candidate] {
        if self.expanded_raw.is_empty() {
            &mut self.raw
        } else {
            &mut self.expanded_raw
        }
    }

    pub(super) fn store_position(&mut self, pos: usize, count: usize) -> Result<(), Error> {
        let local = pos.checked_sub(self.start).ok_or(Error::Limit)?;
        if local >= self.length {
            return Err(Error::Limit);
        }
        self.store(local, count)
    }

    pub(super) fn covers(&self, start: usize, length: usize) -> bool {
        self.start == start && self.length == length
    }
}

pub(super) struct Matcher {
    roots: Vec<u32>,
    exact4_roots: Vec<Exact4Root>,
    children: Vec<[u32; 2]>,
    next_pos: usize,
    hash_bytes: usize,
    /// 0は従来の深さ48・構造prefix 128。64のときだけ、構造prefix未満でも
    /// その長さに達した候補で木の分割を打ち切る研究用近似。
    nice_len: usize,
    #[cfg(test)]
    nice_cutoffs: [usize; 2],
}

impl Matcher {
    pub(super) fn new(length: usize, hash_bytes: usize) -> Result<Self, Error> {
        if !matches!(hash_bytes, 4 | 5) {
            return Err(Error::Format("BT hash width must be 4 or 5"));
        }
        Ok(Self {
            roots: buffer(HASH_SIZE, NONE)?,
            exact4_roots: Vec::new(),
            children: buffer(length, [NONE; 2])?,
            next_pos: 0,
            hash_bytes,
            nice_len: 0,
            #[cfg(test)]
            nice_cutoffs: [0; 2],
        })
    }

    /// LZMAのfast bytesに相当する研究スイッチ。0か64以外は拒否し、閾値探索をしない。
    pub(super) fn set_nice_len(&mut self, nice_len: usize) -> Result<(), Error> {
        if !matches!(nice_len, 0 | 64) {
            return Err(Error::Format("BT nice length must be 0 or 64"));
        }
        self.nice_len = nice_len;
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn nice_cutoff_counts(&self) -> [usize; 2] {
        self.nice_cutoffs
    }

    /// exact-4 directoryを先に全入力から作る。70%負荷を超える入力はprobe長を
    /// 無制限にせず`None`を返し、呼出し側が既存BT5へフォールバックする。
    pub(super) fn new_exact4(
        input: &[u8],
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<Option<Self>, Error> {
        let mut exact4_roots = buffer(HASH_SIZE, Exact4Root::EMPTY)?;
        let mut occupied = 0usize;
        for pos in 0..input.len().saturating_sub(3) {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            let key = exact4_key(input, pos);
            let mut slot = hash4_key(key);
            loop {
                let entry = &mut exact4_roots[slot];
                if entry.root == NONE {
                    if occupied == EXACT4_MAX_OCCUPIED {
                        return Ok(None);
                    }
                    *entry = Exact4Root { key, root: 1 };
                    occupied += 1;
                    break;
                }
                if entry.key == key {
                    entry.root = entry.root.checked_add(1).ok_or(Error::Limit)?;
                    break;
                }
                slot = (slot + 1) & (HASH_SIZE - 1);
            }
        }
        for entry in &mut exact4_roots {
            if entry.root != NONE {
                entry.root = EXACT4_UNSEEN;
            }
        }
        Ok(Some(Self {
            roots: Vec::new(),
            exact4_roots,
            children: buffer(input.len(), [NONE; 2])?,
            next_pos: 0,
            hash_bytes: 4,
            nice_len: 0,
            #[cfg(test)]
            nice_cutoffs: [0; 2],
        }))
    }

    #[cfg(test)]
    pub(super) fn prepare_block(
        &mut self,
        block: &mut Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        self.prepare_start(block, input, start, end, dictionary, cancel)?;
        self.prepare_rest(block, input, start, end, dictionary, cancel)
    }

    #[cfg(test)]
    pub(super) fn insert_for_nice_test(
        &mut self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        limit: usize,
    ) -> Result<(), Error> {
        self.insert(
            input,
            pos,
            dictionary,
            MatchLimits {
                query: limit,
                snapshot: limit,
            },
            None,
            &mut || false,
        )?;
        Ok(())
    }

    pub(super) fn prepare_start(
        &mut self,
        block: &mut Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        if start < self.next_pos || end < start || end > input.len() {
            return Err(Error::Format("BT4 positions are not monotonic"));
        }
        if start == end {
            return Err(Error::Format("BT4 block is empty"));
        }
        block.begin(start, end - start)?;

        // 長いtokenで飛ばした位置も順に挿入し、未来位置を木へ混入させない。
        while self.next_pos < start {
            if self.next_pos & 0xffff == 0 {
                check(cancel)?;
            }
            match (self.exact4_roots.is_empty(), self.hash_bytes) {
                (false, 4) => self.insert_exact4::<false, 4>(
                    input,
                    self.next_pos,
                    dictionary,
                    MatchLimits::NONE,
                    None,
                    cancel,
                )?,
                (true, 4) => self.insert_const::<false, 4>(
                    input,
                    self.next_pos,
                    dictionary,
                    MatchLimits::NONE,
                    None,
                    cancel,
                )?,
                (true, 5) => self.insert_const::<false, 5>(
                    input,
                    self.next_pos,
                    dictionary,
                    MatchLimits::NONE,
                    None,
                    cancel,
                )?,
                _ => unreachable!("validated BT root strategy"),
            };
            self.next_pos += 1;
        }

        self.capture_position(block, input, start, end, dictionary, cancel)?;
        self.next_pos += 1;
        Ok(())
    }

    pub(super) fn prepare_rest(
        &mut self,
        block: &mut Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        if block.start != start
            || block.length != end - start
            || self.next_pos != start + 1
            || end > input.len()
        {
            return Err(Error::Format("BT4 block continuation is invalid"));
        }
        for pos in start + 1..end {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            self.capture_position(block, input, pos, end, dictionary, cancel)?;
            self.next_pos += 1;
        }
        Ok(())
    }

    fn capture_position(
        &mut self,
        block: &mut Block,
        input: &[u8],
        pos: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        let query_limit = if pos == block.start {
            MAX_MATCH.min(input.len() - pos)
        } else {
            end - pos
        };
        let limits = MatchLimits {
            query: query_limit,
            snapshot: end - pos,
        };
        let count = match (self.exact4_roots.is_empty(), self.hash_bytes) {
            (false, 4) => self.insert_exact4::<true, 4>(
                input,
                pos,
                dictionary,
                limits,
                Some(&mut block.raw),
                cancel,
            )?,
            (true, 4) => self.insert_const::<true, 4>(
                input,
                pos,
                dictionary,
                limits,
                Some(&mut block.raw),
                cancel,
            )?,
            (true, 5) => self.insert_const::<true, 5>(
                input,
                pos,
                dictionary,
                limits,
                Some(&mut block.raw),
                cancel,
            )?,
            _ => unreachable!("validated BT root strategy"),
        };

        // childは必ず親より古い位置を指すため、探索候補は既に距離の昇順。
        // 価格・block末尾でのclampが未確定な間は全候補を保持する。
        // ここでfrontier化すると、例えば
        // 700/1000 byte候補がblock末尾で同じ長さへ縮んだ後の安い距離を失い得る。
        debug_assert!(
            block.raw[..count]
                .windows(2)
                .all(|pair| pair[0].distance < pair[1].distance)
        );
        block.store(pos - block.start, count)?;
        Ok(())
    }

    fn insert_const<const CAPTURE: bool, const HASH_BYTES: usize>(
        &mut self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        limits: MatchLimits,
        mut output: Option<&mut [Candidate]>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        // `pos`は単調に入力範囲内、root keyは`HASH_BITS`で配列内、childは
        // 既に挿入済みの位置だけを指す。BTのhot loopではこの不変条件を呼出し側と
        // 下記の距離検査で維持し、配列境界検査を一致探索から外す。
        unsafe {
            *self.children.get_unchecked_mut(pos) = [NONE; 2];
        }
        if input.len() - pos < HASH_BYTES {
            return Ok(0);
        }

        let key = if HASH_BYTES == 4 {
            hash4(input, pos)
        } else {
            hash5(input, pos)
        };
        let mut candidate = unsafe { *self.roots.get_unchecked(key) };
        unsafe {
            *self.roots.get_unchecked_mut(key) = pos as u32;
        }
        let mut smaller_link = (pos, 0usize);
        let mut larger_link = (pos, 1usize);
        let mut smaller_lcp = 0usize;
        let mut larger_lcp = 0usize;
        let structural_limit = STRUCTURAL_PREFIX.min(input.len() - pos);
        let mut compared = 0usize;
        let mut output_len = 0usize;
        let mut best_snapshot = 3usize;
        let mut best_visible = 0usize;
        let mut stagnant = 0usize;

        for depth in 0..MAX_DEPTH {
            if candidate == NONE {
                break;
            }
            let source = candidate as usize;
            if source >= pos {
                break;
            }
            let distance = pos - source;
            if distance == 0 || distance > dictionary {
                break;
            }
            if depth & 31 == 0 {
                check(cancel)?;
            }

            let length = unsafe {
                extend_match_fast(
                    input.as_ptr(),
                    source,
                    pos,
                    smaller_lcp.min(larger_lcp),
                    structural_limit,
                    &mut compared,
                    cancel,
                )?
            };

            let mut visible_length = length.min(limits.query);
            if length == structural_limit && visible_length < limits.query {
                visible_length = unsafe {
                    extend_match_fast(
                        input.as_ptr(),
                        source,
                        pos,
                        visible_length,
                        limits.query,
                        &mut compared,
                        cancel,
                    )?
                };
            }
            if CAPTURE
                && visible_length >= 4
                && let Some(values) = output.as_deref_mut()
                && keep_candidate(&mut best_snapshot, visible_length, limits.snapshot)
            {
                values[output_len] = Candidate {
                    distance: distance as u32,
                    length: visible_length as u32,
                };
                output_len += 1;
            }

            if length == structural_limit || compared >= MAX_COMPARE {
                if length == structural_limit {
                    let children = unsafe { *self.children.get_unchecked(source) };
                    unsafe {
                        *self
                            .children
                            .get_unchecked_mut(smaller_link.0)
                            .get_unchecked_mut(smaller_link.1) = children[0];
                        *self
                            .children
                            .get_unchecked_mut(larger_link.0)
                            .get_unchecked_mut(larger_link.1) = children[1];
                    }
                    return Ok(output_len);
                }
                break;
            }

            // 構造prefixより短いがnice length以上の一致では、残り候補の探索だけを
            // やめる。不一致側へ現在の節を残し、反対側はここで閉じる。
            if self.nice_len != 0 && length >= self.nice_len {
                let source_byte = unsafe { *input.as_ptr().add(source + length) };
                let query_byte = unsafe { *input.as_ptr().add(pos + length) };
                #[cfg(test)]
                {
                    self.nice_cutoffs[usize::from(source_byte >= query_byte)] += 1;
                }
                unsafe {
                    if source_byte < query_byte {
                        *self
                            .children
                            .get_unchecked_mut(smaller_link.0)
                            .get_unchecked_mut(smaller_link.1) = candidate;
                        *self
                            .children
                            .get_unchecked_mut(larger_link.0)
                            .get_unchecked_mut(larger_link.1) = NONE;
                    } else {
                        *self
                            .children
                            .get_unchecked_mut(larger_link.0)
                            .get_unchecked_mut(larger_link.1) = candidate;
                        *self
                            .children
                            .get_unchecked_mut(smaller_link.0)
                            .get_unchecked_mut(smaller_link.1) = NONE;
                    }
                }
                return Ok(output_len);
            }

            // 同長の距離候補も残し、16訪問連続で長さが改善しない枝を打ち切る近似。
            if CAPTURE && limits.query > 0 {
                if visible_length > best_visible {
                    best_visible = visible_length;
                    stagnant = 0;
                } else {
                    stagnant += 1;
                }
                if stagnant >= 16 {
                    break;
                }
            }

            let source_byte = unsafe { *input.as_ptr().add(source + length) };
            let query_byte = unsafe { *input.as_ptr().add(pos + length) };
            if source_byte < query_byte {
                unsafe {
                    *self
                        .children
                        .get_unchecked_mut(smaller_link.0)
                        .get_unchecked_mut(smaller_link.1) = candidate;
                }
                smaller_link = (source, 1);
                candidate = unsafe { self.children.get_unchecked(source)[1] };
                smaller_lcp = length;
            } else {
                unsafe {
                    *self
                        .children
                        .get_unchecked_mut(larger_link.0)
                        .get_unchecked_mut(larger_link.1) = candidate;
                }
                larger_link = (source, 0);
                candidate = unsafe { self.children.get_unchecked(source)[0] };
                larger_lcp = length;
            }
        }
        unsafe {
            *self
                .children
                .get_unchecked_mut(smaller_link.0)
                .get_unchecked_mut(smaller_link.1) = NONE;
            *self
                .children
                .get_unchecked_mut(larger_link.0)
                .get_unchecked_mut(larger_link.1) = NONE;
        }
        Ok(output_len)
    }

    fn insert_exact4<const CAPTURE: bool, const START: usize>(
        &mut self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        limits: MatchLimits,
        mut output: Option<&mut [Candidate]>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        debug_assert!(matches!(START, 0 | 4));
        unsafe {
            *self.children.get_unchecked_mut(pos) = [NONE; 2];
        }
        if input.len() - pos < 4 {
            return Ok(0);
        }

        let key = exact4_key(input, pos);
        let mut slot = hash4_key(key);
        let candidate = loop {
            let entry = unsafe { self.exact4_roots.get_unchecked_mut(slot) };
            if entry.root == NONE {
                return Err(Error::Format("exact-4 directory lost a registered key"));
            }
            if entry.key == key {
                let candidate = if entry.root == EXACT4_UNSEEN {
                    NONE
                } else {
                    entry.root
                };
                entry.root = u32::try_from(pos).map_err(|_| Error::Limit)?;
                break candidate;
            }
            slot = (slot + 1) & (HASH_SIZE - 1);
        };

        let mut candidate = candidate;
        let mut smaller_link = (pos, 0usize);
        let mut larger_link = (pos, 1usize);
        let mut smaller_lcp = START;
        let mut larger_lcp = START;
        let structural_limit = STRUCTURAL_PREFIX.min(input.len() - pos);
        let mut compared = 0usize;
        let mut output_len = 0usize;
        let mut best_snapshot = 3usize;
        let mut best_visible = 0usize;
        let mut stagnant = 0usize;

        for depth in 0..MAX_DEPTH {
            if candidate == NONE {
                break;
            }
            let source = candidate as usize;
            if source >= pos {
                break;
            }
            let distance = pos - source;
            // 同じrootの子はさらに古いため、辞書外rootなら全枝が辞書外になる。
            if distance == 0 || distance > dictionary {
                break;
            }
            if depth & 31 == 0 {
                check(cancel)?;
            }

            let length = unsafe {
                extend_match_fast(
                    input.as_ptr(),
                    source,
                    pos,
                    smaller_lcp.min(larger_lcp),
                    structural_limit,
                    &mut compared,
                    cancel,
                )?
            };
            let mut visible_length = length.min(limits.query);
            if length == structural_limit && visible_length < limits.query {
                visible_length = unsafe {
                    extend_match_fast(
                        input.as_ptr(),
                        source,
                        pos,
                        visible_length,
                        limits.query,
                        &mut compared,
                        cancel,
                    )?
                };
            }
            if CAPTURE
                && visible_length >= 4
                && let Some(values) = output.as_deref_mut()
                && keep_candidate(&mut best_snapshot, visible_length, limits.snapshot)
            {
                values[output_len] = Candidate {
                    distance: distance as u32,
                    length: visible_length as u32,
                };
                output_len += 1;
            }

            // 完全一致prefixは既存BTと同じく両childを引き継ぐ。巨大な同一prefix群でも
            // 1回で接続を終え、それ以外は深さ48・停滞16・比較64 KiBで打ち切る。
            if length == structural_limit || compared >= MAX_COMPARE {
                if length == structural_limit {
                    let children = unsafe { *self.children.get_unchecked(source) };
                    unsafe {
                        *self
                            .children
                            .get_unchecked_mut(smaller_link.0)
                            .get_unchecked_mut(smaller_link.1) = children[0];
                        *self
                            .children
                            .get_unchecked_mut(larger_link.0)
                            .get_unchecked_mut(larger_link.1) = children[1];
                    }
                    return Ok(output_len);
                }
                break;
            }

            if CAPTURE && limits.query > 0 {
                if visible_length > best_visible {
                    best_visible = visible_length;
                    stagnant = 0;
                } else {
                    stagnant += 1;
                }
                if stagnant >= 16 {
                    break;
                }
            }

            let source_byte = unsafe { *input.as_ptr().add(source + length) };
            let query_byte = unsafe { *input.as_ptr().add(pos + length) };
            if source_byte < query_byte {
                unsafe {
                    *self
                        .children
                        .get_unchecked_mut(smaller_link.0)
                        .get_unchecked_mut(smaller_link.1) = candidate;
                }
                smaller_link = (source, 1);
                candidate = unsafe { self.children.get_unchecked(source)[1] };
                smaller_lcp = length;
            } else {
                unsafe {
                    *self
                        .children
                        .get_unchecked_mut(larger_link.0)
                        .get_unchecked_mut(larger_link.1) = candidate;
                }
                larger_link = (source, 0);
                candidate = unsafe { self.children.get_unchecked(source)[0] };
                larger_lcp = length;
            }
        }
        unsafe {
            *self
                .children
                .get_unchecked_mut(smaller_link.0)
                .get_unchecked_mut(smaller_link.1) = NONE;
            *self
                .children
                .get_unchecked_mut(larger_link.0)
                .get_unchecked_mut(larger_link.1) = NONE;
        }
        Ok(output_len)
    }

    #[cfg(test)]
    fn insert(
        &mut self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        limits: MatchLimits,
        output: Option<&mut [Candidate]>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        let capture = output.is_some();
        match (self.hash_bytes, capture) {
            (4, false) => {
                self.insert_const::<false, 4>(input, pos, dictionary, limits, output, cancel)
            }
            (5, false) => {
                self.insert_const::<false, 5>(input, pos, dictionary, limits, output, cancel)
            }
            (4, true) => {
                self.insert_const::<true, 4>(input, pos, dictionary, limits, output, cancel)
            }
            (5, true) => {
                self.insert_const::<true, 5>(input, pos, dictionary, limits, output, cancel)
            }
            _ => unreachable!("validated BT hash width"),
        }
    }
}

/// 既知の一致長から8 byteずつ延長し、scalar経路の比較数と取消境界を保つ。
#[cfg(test)]
fn matching_prefix8(left: &[u8], right: &[u8]) -> usize {
    debug_assert!(left.len() >= COMPARE_CHUNK && right.len() >= COMPARE_CHUNK);
    let left = u64::from_le_bytes(left[..COMPARE_CHUNK].try_into().unwrap());
    let right = u64::from_le_bytes(right[..COMPARE_CHUNK].try_into().unwrap());
    let difference = left ^ right;
    if difference == 0 {
        COMPARE_CHUNK
    } else {
        (difference.trailing_zeros() / 8) as usize
    }
}

#[cfg(test)]
#[inline(always)]
fn extend_match(
    input: &[u8],
    source: usize,
    pos: usize,
    mut length: usize,
    limit: usize,
    compared: &mut usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    while length < limit && *compared < MAX_COMPARE {
        let remaining = limit - length;
        let budget = MAX_COMPARE - *compared;
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

/// `insert_const`が保証する入力範囲内で一致を延長するunchecked経路。
///
/// # Safety
/// `source < pos`、`limit <= input_len - pos`、かつ`source + limit <= input_len`を
/// 呼出し側が保証する。比較予算・取消境界・論理比較数はchecked経路と同じに保つ。
#[inline(always)]
unsafe fn extend_match_fast(
    input: *const u8,
    source: usize,
    pos: usize,
    mut length: usize,
    limit: usize,
    compared: &mut usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<usize, Error> {
    while length < limit && *compared < MAX_COMPARE {
        let remaining = limit - length;
        let budget = MAX_COMPARE - *compared;

        if remaining >= COMPARE_CHUNK
            && budget >= COMPARE_CHUNK
            && (*compared & 0xfff) <= 0xfff - COMPARE_CHUNK
        {
            let left =
                unsafe { std::ptr::read_unaligned(input.add(source + length).cast::<u64>()) };
            let right = unsafe { std::ptr::read_unaligned(input.add(pos + length).cast::<u64>()) };
            let difference = left ^ right;
            let prefix = if difference == 0 {
                COMPARE_CHUNK
            } else {
                (difference.trailing_zeros() / 8) as usize
            };
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
        let left = unsafe { *input.add(source + length) };
        let right = unsafe { *input.add(pos + length) };
        if left != right {
            break;
        }
        length += 1;
    }
    Ok(length)
}

fn hash5(input: &[u8], pos: usize) -> usize {
    let low = u32::from_le_bytes(input[pos..pos + 4].try_into().unwrap()) as u64;
    let value = low | ((input[pos + 4] as u64) << 32);
    (value.wrapping_mul(0x9e37_79b1_85eb_ca87) >> (64 - HASH_BITS)) as usize
}

fn hash4(input: &[u8], pos: usize) -> usize {
    hash4_key(exact4_key(input, pos))
}

fn exact4_key(input: &[u8], pos: usize) -> u32 {
    u32::from_le_bytes(input[pos..pos + 4].try_into().unwrap())
}

fn hash4_key(value: u32) -> usize {
    (value.wrapping_mul(0x9e37_79b1) >> (32 - HASH_BITS)) as usize
}

pub(super) fn extra_memory(input_size: usize, block: usize) -> Option<usize> {
    // 既存Finderのu32 link/positionを2本のBT childへ置換する差分に、block snapshotを加える。
    input_size
        .checked_mul(std::mem::size_of::<u32>())?
        .checked_add(block_memory(block, MAX_DEPTH)?)
}

pub(super) fn exact4_extra_memory(input_size: usize, block: usize) -> Option<usize> {
    // lazy Finderの2 MiB hash rootを4 MiB exact directoryへ置換する差分も数える。
    extra_memory(input_size, block)?.checked_add(
        HASH_SIZE
            .checked_mul(std::mem::size_of::<Exact4Root>())?
            .checked_sub(HASH_SIZE.checked_mul(std::mem::size_of::<u32>())?)?,
    )
}

pub(super) fn block_memory(block: usize, depth: usize) -> Option<usize> {
    let expanded_scratch = if depth > MAX_DEPTH {
        depth.checked_mul(std::mem::size_of::<Candidate>())?
    } else {
        0
    };
    block
        .checked_mul(std::mem::size_of::<Record>())?
        .checked_add(
            block
                .checked_mul(depth)?
                .checked_mul(std::mem::size_of::<Candidate>())?,
        )?
        .checked_add(expanded_scratch)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scalar_extend_match(
        input: &[u8],
        source: usize,
        pos: usize,
        mut length: usize,
        limit: usize,
        compared: &mut usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        while length < limit && *compared < MAX_COMPARE {
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

    #[test]
    fn chunked_extension_matches_scalar_results_counts_and_cancellation() {
        for initial_compared in [0, 1, 4087, 4088, 4094, 4095, MAX_COMPARE - 9] {
            for start in [0, 1, 7, 8, 15] {
                for mismatch in start..=160 {
                    let mut input = vec![0x5a; 384];
                    let source = 0;
                    let pos = 192;
                    if mismatch < 160 {
                        input[pos + mismatch] ^= 0xff;
                    }
                    let limit = 160;
                    let mut scalar_compared = initial_compared;
                    let mut chunked_compared = initial_compared;
                    let mut scalar_calls = 0usize;
                    let scalar = scalar_extend_match(
                        &input,
                        source,
                        pos,
                        start,
                        limit,
                        &mut scalar_compared,
                        &mut || {
                            scalar_calls += 1;
                            false
                        },
                    );
                    let mut chunked_calls = 0usize;
                    let chunked = extend_match(
                        &input,
                        source,
                        pos,
                        start,
                        limit,
                        &mut chunked_compared,
                        &mut || {
                            chunked_calls += 1;
                            false
                        },
                    );
                    assert_eq!(chunked, scalar);
                    assert_eq!(chunked_compared, scalar_compared);
                    assert_eq!(chunked_calls, scalar_calls);

                    for cancel_at in 1..=scalar_calls + 1 {
                        let mut scalar_compared = initial_compared;
                        let mut scalar_calls = 0usize;
                        let scalar = scalar_extend_match(
                            &input,
                            source,
                            pos,
                            start,
                            limit,
                            &mut scalar_compared,
                            &mut || {
                                scalar_calls += 1;
                                scalar_calls == cancel_at
                            },
                        );
                        let mut chunked_compared = initial_compared;
                        let mut chunked_calls = 0usize;
                        let chunked = extend_match(
                            &input,
                            source,
                            pos,
                            start,
                            limit,
                            &mut chunked_compared,
                            &mut || {
                                chunked_calls += 1;
                                chunked_calls == cancel_at
                            },
                        );
                        assert_eq!(chunked, scalar);
                        assert_eq!(chunked_compared, scalar_compared);
                        assert_eq!(chunked_calls, scalar_calls);
                    }
                }
            }
        }
    }

    #[test]
    fn unchecked_extension_matches_checked_results_counts_and_cancellation() {
        for initial_compared in [0, 4088, 4094, 4095, MAX_COMPARE - 9] {
            for start in [0, 7, 8, 15] {
                for mismatch in start..=96 {
                    let mut input = vec![0x5a; 384];
                    let source = 0;
                    let pos = 192;
                    if mismatch < 96 {
                        input[pos + mismatch] ^= 0xff;
                    }
                    let limit = 96;
                    let mut checked_compared = initial_compared;
                    let mut checked_calls = 0usize;
                    let checked = extend_match(
                        &input,
                        source,
                        pos,
                        start,
                        limit,
                        &mut checked_compared,
                        &mut || {
                            checked_calls += 1;
                            false
                        },
                    );
                    let mut fast_compared = initial_compared;
                    let mut fast_calls = 0usize;
                    let fast = unsafe {
                        extend_match_fast(
                            input.as_ptr(),
                            source,
                            pos,
                            start,
                            limit,
                            &mut fast_compared,
                            &mut || {
                                fast_calls += 1;
                                false
                            },
                        )
                    };
                    assert_eq!(fast, checked);
                    assert_eq!(fast_compared, checked_compared);
                    assert_eq!(fast_calls, checked_calls);

                    for cancel_at in 1..=checked_calls + 1 {
                        let mut checked_compared = initial_compared;
                        let mut checked_calls = 0usize;
                        let checked = extend_match(
                            &input,
                            source,
                            pos,
                            start,
                            limit,
                            &mut checked_compared,
                            &mut || {
                                checked_calls += 1;
                                checked_calls == cancel_at
                            },
                        );
                        let mut fast_compared = initial_compared;
                        let mut fast_calls = 0usize;
                        let fast = unsafe {
                            extend_match_fast(
                                input.as_ptr(),
                                source,
                                pos,
                                start,
                                limit,
                                &mut fast_compared,
                                &mut || {
                                    fast_calls += 1;
                                    fast_calls == cancel_at
                                },
                            )
                        };
                        assert_eq!(fast, checked);
                        assert_eq!(fast_compared, checked_compared);
                        assert_eq!(fast_calls, checked_calls);
                    }
                }
            }
        }
    }

    #[test]
    fn stagnant_search_stops_after_sixteen_visits_and_resets_on_improvement() {
        // 同じhashで右の古いchildへ進む木を直接組み、停止位置を独立に確認する。
        let pos = 80 * 8;
        for (limit, improving, expected_visits, expected_output) in [
            (8, false, 17, 17),
            (8, true, 27, 11),
            (4, true, 17, 17),
            (0, true, MAX_DEPTH, 0),
        ] {
            let mut input = vec![0; pos + 8];
            for at in (0..=pos).step_by(8) {
                input[at..at + 4].copy_from_slice(b"abcd");
            }
            input[pos + 4..pos + 8].fill(255);
            if improving {
                input[(79 - 10) * 8 + 4] = 255;
            }
            let mut matcher = Matcher::new(input.len(), 4).unwrap();
            matcher.roots[hash4(&input, pos)] = 79 * 8;
            for index in 1..80 {
                matcher.children[index * 8][1] = ((index - 1) * 8) as u32;
            }
            let mut raw = [Candidate::EMPTY; MAX_DEPTH];
            let count = matcher
                .insert(
                    &input,
                    pos,
                    pos,
                    MatchLimits {
                        query: limit,
                        snapshot: limit,
                    },
                    Some(&mut raw),
                    &mut || false,
                )
                .unwrap();
            assert_eq!(count, expected_output);
            // 停滞でbreakした訪問候補は木へまだ接続していない。改善後の短い候補は
            // snapshotへ保存しないが、木の訪問数と停止位置は変えない。
            let last_linked = if limit == 0 {
                80 - expected_visits
            } else {
                81 - expected_visits
            };
            assert_eq!(matcher.children[last_linked * 8][1], NONE);
            for (index, candidate) in raw[..count].iter().enumerate() {
                assert_eq!(candidate.distance(), (index + 1) * 8);
                assert_eq!(
                    candidate.length(),
                    if improving && index == 10 {
                        5.min(limit)
                    } else {
                        4
                    }
                );
            }
        }
    }

    #[test]
    fn reused_scratch_matches_fresh_arrays_and_ignores_stale_suffixes() {
        let mut seed = 0x1234_5678u32;
        let input: Vec<u8> = (0..1027)
            .map(|at| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                if at % 8 < 4 {
                    b"abcd"[at % 8]
                } else {
                    (seed % 8) as u8
                }
            })
            .collect();
        let mut actual = Matcher::new(input.len(), 4).unwrap();
        let mut reference = Matcher::new(input.len(), 4).unwrap();
        let mut block = Block::new(64).unwrap();
        let mut actual_calls = 0;
        let mut reference_calls = 0;
        for start in (0..input.len()).step_by(64) {
            let end = (start + 64).min(input.len());
            block.raw.fill(Candidate {
                distance: u32::MAX,
                length: u32::MAX,
            });
            actual
                .prepare_block(&mut block, &input, start, end, 1024, &mut || {
                    actual_calls += 1;
                    false
                })
                .unwrap();
            for pos in start..end {
                let mut fresh = [Candidate::EMPTY; MAX_DEPTH];
                let limit = if pos == start {
                    MAX_MATCH.min(input.len() - pos)
                } else {
                    end - pos
                };
                let count = reference
                    .insert(
                        &input,
                        pos,
                        1024,
                        MatchLimits {
                            query: limit,
                            snapshot: end - pos,
                        },
                        Some(&mut fresh),
                        &mut || {
                            reference_calls += 1;
                            false
                        },
                    )
                    .unwrap();
                assert_eq!(block.candidates(pos), &fresh[..count]);
            }
            assert_eq!(actual.children, reference.children);
            assert_eq!(actual.roots, reference.roots);
            assert_eq!(actual_calls, reference_calls);
        }
        // 最大件数から0へ減っても、storeは今回のprefix以外を公開しない。
        for count in (0..=MAX_DEPTH).rev() {
            block.begin(0, 1).unwrap();
            block.store(0, count).unwrap();
            assert_eq!(block.candidates(0), &block.raw[..count]);
        }
    }

    #[test]
    fn candidate_compaction_keeps_every_clamped_maximum_tie_and_raw_length() {
        let original = [
            Candidate {
                distance: 1,
                length: 700,
            },
            Candidate {
                distance: 2,
                length: 1000,
            },
            Candidate {
                distance: 3,
                length: 511,
            },
            Candidate {
                distance: 4,
                length: 512,
            },
            Candidate {
                distance: 5,
                length: 900,
            },
        ];
        let mut compacted = [Candidate::EMPTY; 5];
        let mut count = 0usize;
        let mut best = 3usize;
        for candidate in original {
            if keep_candidate(&mut best, candidate.length(), 512) {
                compacted[count] = candidate;
                count += 1;
            }
        }
        assert_eq!(
            &compacted[..count],
            &[original[0], original[1], original[3], original[4]]
        );
        assert_eq!(compacted[0].length(), 700);
        assert_eq!(compacted[1].length(), 1000);

        // 任意の長さ列とclampで、保持列はrunning maximumの更新と全tieに一致する。
        for encoded in 0usize..5usize.pow(6) {
            let mut value = encoded;
            let mut input = [Candidate::EMPTY; 6];
            for (distance, candidate) in input.iter_mut().enumerate() {
                *candidate = Candidate {
                    distance: (distance + 1) as u32,
                    length: (4 + value % 5) as u32,
                };
                value /= 5;
            }
            for maximum in 4..=8 {
                let mut actual = [Candidate::EMPTY; 6];
                let mut count = 0usize;
                let mut actual_best = 3usize;
                for candidate in input {
                    if keep_candidate(&mut actual_best, candidate.length(), maximum) {
                        actual[count] = candidate;
                        count += 1;
                    }
                }
                let mut expected = Vec::new();
                let mut best = 3usize;
                for candidate in input {
                    let length = candidate.length().min(maximum);
                    if length >= best {
                        best = best.max(length);
                        expected.push(candidate);
                    }
                }
                assert_eq!(&actual[..count], expected);
            }
        }
    }

    #[test]
    fn insertion_visits_older_children_and_emits_sorted_distances() {
        let mut multi_candidate_positions = 0;
        for style in 0..3 {
            let mut seed = 0x1234_5678u32;
            let input: Vec<u8> = (0..2048)
                .map(|at| {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    match style {
                        0 => (at % 17) as u8,
                        1 if at % 8 < 4 => b"abcd"[at % 8],
                        1 => seed as u8,
                        _ => (seed % 4) as u8,
                    }
                })
                .collect();
            for dictionary in [7, 64, 2048] {
                let mut matcher = Matcher::new(input.len(), 4).unwrap();
                for pos in 0..input.len() {
                    let mut raw = [Candidate::EMPTY; MAX_DEPTH];
                    let count = matcher
                        .insert(
                            &input,
                            pos,
                            dictionary,
                            MatchLimits {
                                query: 256.min(input.len() - pos),
                                snapshot: 256.min(input.len() - pos),
                            },
                            Some(&mut raw),
                            &mut || false,
                        )
                        .unwrap();
                    multi_candidate_positions += usize::from(count > 1);
                    assert!(
                        raw[..count]
                            .windows(2)
                            .all(|pair| pair[0].distance < pair[1].distance)
                    );
                    if pos % 32 == 0 || pos + 1 == input.len() {
                        for (parent, children) in matcher.children[..=pos].iter().enumerate() {
                            for &child in children {
                                assert!(child == NONE || (child as usize) < parent);
                            }
                        }
                    }
                }
            }
        }
        assert!(multi_candidate_positions > 100);
    }

    #[test]
    fn snapshots_only_contain_valid_backreferences_and_never_future_positions() {
        let input = b"0123abcd0123abcdX0123abcd0123abcdYtail";
        let mut matcher = Matcher::new(input.len(), 4).unwrap();
        let mut block = Block::new(16).unwrap();
        matcher
            .prepare_block(&mut block, input, 8, 24, 12, &mut || false)
            .unwrap();
        for pos in 8..24 {
            for candidate in block.candidates(pos).iter().copied() {
                let distance = candidate.distance();
                let length = candidate.length();
                assert!((1..=12).contains(&distance));
                assert!(distance <= pos, "future/underflow at {pos}: {candidate:?}");
                assert!((4..=input.len() - pos).contains(&length));
                assert_eq!(
                    &input[pos - distance..pos - distance + length],
                    &input[pos..pos + length]
                );
            }
        }

        // 前blockより後ろだけを受け付け、4 byte未満のtailは空候補のまま挿入できる。
        matcher
            .prepare_block(&mut block, input, 24, input.len(), input.len(), &mut || {
                false
            })
            .unwrap();
        for pos in input.len() - 3..input.len() {
            assert!(block.candidates(pos).is_empty());
        }
        assert!(block.candidates(input.len()).is_empty());
    }

    #[test]
    fn cancellation_during_catchup_is_reported() {
        let input = vec![b'x'; 200_000];
        let mut matcher = Matcher::new(input.len(), 4).unwrap();
        let mut block = Block::new(64).unwrap();
        let mut calls = 0usize;
        assert_eq!(
            matcher.prepare_block(
                &mut block,
                &input,
                100_000,
                100_064,
                input.len(),
                &mut || {
                    calls += 1;
                    calls == 9
                }
            ),
            Err(Error::Cancelled)
        );
    }

    #[test]
    fn exact4_suffix_start_matches_zero_start_and_emits_valid_sorted_candidates() {
        let mut seed = 0x6d2b_79f5u32;
        let mut input = Vec::new();
        for index in 0..4096 {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            input.extend_from_slice(b"same");
            input.push((seed as usize % 17) as u8);
            input.push((index % 251) as u8);
        }
        let mut suffix = Matcher::new_exact4(&input, &mut || false).unwrap().unwrap();
        let mut zero = Matcher::new_exact4(&input, &mut || false).unwrap().unwrap();
        for pos in 0..input.len() {
            let limit = 256.min(input.len() - pos);
            let limits = MatchLimits {
                query: limit,
                snapshot: limit,
            };
            let mut suffix_raw = [Candidate::EMPTY; MAX_DEPTH];
            let suffix_count = suffix
                .insert_exact4::<true, 4>(
                    &input,
                    pos,
                    input.len(),
                    limits,
                    Some(&mut suffix_raw),
                    &mut || false,
                )
                .unwrap();
            let mut zero_raw = [Candidate::EMPTY; MAX_DEPTH];
            let zero_count = zero
                .insert_exact4::<true, 0>(
                    &input,
                    pos,
                    input.len(),
                    limits,
                    Some(&mut zero_raw),
                    &mut || false,
                )
                .unwrap();
            assert_eq!(&suffix_raw[..suffix_count], &zero_raw[..zero_count]);
            assert!(
                suffix_raw[..suffix_count]
                    .windows(2)
                    .all(|pair| pair[0].distance() < pair[1].distance())
            );
            for candidate in &suffix_raw[..suffix_count] {
                let source = pos - candidate.distance();
                assert_eq!(
                    &input[source..source + candidate.length()],
                    &input[pos..pos + candidate.length()]
                );
            }
        }
        assert_eq!(suffix.children, zero.children);
        assert_eq!(suffix.exact4_roots, zero.exact4_roots);
    }

    #[test]
    fn exact4_directory_falls_back_before_probe_load_becomes_degenerate() {
        // group sizeはdirectory負荷ではない。screenで観測した409,349件級の
        // 同一prefixも1 slotとして受け付け、探索側の既存depth capへ委ねる。
        assert!(
            Matcher::new_exact4(&vec![0; 409_349 + 3], &mut || false)
                .unwrap()
                .is_some()
        );

        let mut seed = 0x1234_5678u32;
        let input: Vec<u8> = (0..EXACT4_MAX_OCCUPIED + 32_768)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                seed as u8
            })
            .collect();
        assert!(
            Matcher::new_exact4(&input, &mut || false)
                .unwrap()
                .is_none()
        );

        let mut calls = 0usize;
        assert!(matches!(
            Matcher::new_exact4(&vec![0; 200_000], &mut || {
                calls += 1;
                calls == 3
            }),
            Err(Error::Cancelled)
        ));
    }
}
