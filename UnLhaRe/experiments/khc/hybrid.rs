//! 研究用beamの近距離ring＋疎な遠距離索引match finder。
//!
//! 近距離側は入力全体のlinkを持たず、直近4 MiBだけを`u32` ringへ保持する。
//! 遠距離側は絶対位置16 byte境界だけを4-way bucketへ入れ、query側の16通りの
//! alignmentを補正する。候補は実byte列を照合してから距離順に統合する。

use super::{Error, MAX_INPUT, bt, buffer, check};

pub(super) const NEAR_WINDOW: usize = 4 * 1024 * 1024;
const NEAR_RING: usize = NEAR_WINDOW + 1;
const NEAR_HASH_BITS: usize = 19;
const NEAR_HASH_SIZE: usize = 1 << NEAR_HASH_BITS;
const NEAR_HASH_BYTES: usize = 5;
const NEAR_CHAIN: usize = 64;
const NEAR_SNAPSHOT: usize = bt::MAX_DEPTH;
const FAR_KEY_BYTES: usize = 16;
const FAR_SAMPLE: usize = 16;
const FAR_WAYS: usize = 4;
const FAR_CANDIDATES: usize = FAR_SAMPLE * FAR_WAYS;
const MIN_FAR_MATCH: usize = 64;
const MAX_MATCH: usize = 1 << 16;
const MAX_COMPARE: usize = 1 << 16;
const COMPARE_CHUNK: usize = 8;
const NONE: u32 = u32::MAX;

/// 既存BTと同じ48件のnear候補と、各alignmentのfar 4-wayを同時に保持できる。
pub(super) const SNAPSHOT_DEPTH: usize = NEAR_SNAPSHOT + FAR_CANDIDATES;

const _: () = assert!(MAX_INPUT < u32::MAX as usize);
const _: () = assert!(MAX_MATCH - 1 <= u16::MAX as usize);
const _: () = assert!(NEAR_RING <= u32::MAX as usize);

#[repr(C)]
#[derive(Clone, Copy)]
struct FarBucket {
    positions: [u32; FAR_WAYS],
}

impl FarBucket {
    const EMPTY: Self = Self {
        positions: [NONE; FAR_WAYS],
    };
}

struct FarIndex {
    buckets: Vec<FarBucket>,
    next_sample: usize,
}

impl FarIndex {
    fn with_bucket_count(bucket_count: usize) -> Result<Self, Error> {
        if bucket_count == 0 || !bucket_count.is_power_of_two() {
            return Err(Error::Limit);
        }
        Ok(Self {
            buckets: buffer(bucket_count, FarBucket::EMPTY)?,
            next_sample: 0,
        })
    }

    fn insert(
        &mut self,
        input: &[u8],
        sample: usize,
        current: usize,
        dictionary: usize,
    ) -> Result<(), Error> {
        if !sample.is_multiple_of(FAR_SAMPLE) || input.len().saturating_sub(sample) < FAR_KEY_BYTES
        {
            return Ok(());
        }
        let key = far_hash(input, sample) & (self.buckets.len() - 1);
        let bucket = &mut self.buckets[key];
        let oldest = current.saturating_sub(dictionary);
        for position in &mut bucket.positions {
            if *position != NONE && (*position as usize) < oldest {
                *position = NONE;
            }
        }
        if bucket.positions[0] == NONE
            && let Some((oldest_slot, _)) = bucket.positions[1..]
                .iter()
                .enumerate()
                .filter(|(_, position)| **position != NONE)
                .min_by_key(|(_, position)| **position)
        {
            bucket.positions.swap(0, oldest_slot + 1);
        }
        if bucket.positions.contains(&(sample as u32)) {
            return Ok(());
        }
        let slot = bucket
            .positions
            .iter()
            .position(|&position| position == NONE)
            .unwrap_or_else(|| {
                // far indexは近距離ringを補う。最古の1件をanchorとして残し、残り3枠の
                // 最古を置換して辞書端と比較的新しいfar履歴の両方を保持する。
                bucket.positions[1..]
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, position)| **position)
                    .map(|(slot, _)| slot + 1)
                    .unwrap()
            });
        bucket.positions[slot] = u32::try_from(sample).map_err(|_| Error::Limit)?;
        Ok(())
    }

    /// `sample - alignment`がfarになり得るsampleまでを、query前に一度だけ挿入する。
    fn age_for(
        &mut self,
        input: &[u8],
        pos: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        let Some(max_sample) = pos
            .checked_add(FAR_SAMPLE - 1)
            .and_then(|value| value.checked_sub(NEAR_WINDOW + 1))
        else {
            return Ok(());
        };
        let maximum = max_sample.min(input.len().saturating_sub(FAR_KEY_BYTES));
        while self.next_sample <= maximum {
            let sample = self.next_sample;
            if sample & 0xffff == 0 {
                check(cancel)?;
            }
            self.insert(input, sample, pos, dictionary)?;
            self.next_sample = self
                .next_sample
                .checked_add(FAR_SAMPLE)
                .ok_or(Error::Limit)?;
        }
        Ok(())
    }
}

pub(super) struct Matcher {
    near_heads: Vec<u32>,
    near_previous: Vec<u32>,
    far: FarIndex,
    next_pos: usize,
    dictionary: usize,
}

impl Matcher {
    pub(super) fn new(length: usize, dictionary: usize) -> Result<Self, Error> {
        if length > MAX_INPUT || dictionary == 0 || dictionary > MAX_INPUT {
            return Err(Error::Limit);
        }
        Ok(Self {
            near_heads: buffer(NEAR_HASH_SIZE, NONE)?,
            near_previous: buffer(NEAR_RING, NONE)?,
            far: FarIndex::with_bucket_count(far_bucket_count(dictionary).ok_or(Error::Limit)?)?,
            next_pos: 0,
            dictionary,
        })
    }

    #[cfg(test)]
    fn prepare_block(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        self.prepare_start(block, input, start, end, dictionary, cancel)?;
        self.prepare_rest(block, input, start, end, dictionary, cancel)
    }

    pub(super) fn prepare_start(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        if start < self.next_pos
            || end <= start
            || end > input.len()
            || dictionary != self.dictionary
        {
            return Err(Error::Format("hybrid positions are not monotonic"));
        }
        if block.scratch_mut().len() < SNAPSHOT_DEPTH {
            return Err(Error::Limit);
        }
        block.begin(start, end - start)?;
        while self.next_pos < start {
            if self.next_pos & 0xffff == 0 {
                check(cancel)?;
            }
            self.process_position(None, input, self.next_pos, end, false, dictionary, cancel)?;
            self.next_pos += 1;
        }
        self.capture_position(block, input, start, end, true, dictionary, cancel)?;
        self.next_pos += 1;
        Ok(())
    }

    pub(super) fn prepare_rest(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        start: usize,
        end: usize,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        if self.next_pos != start + 1
            || end <= start
            || end > input.len()
            || !block.covers(start, end - start)
        {
            return Err(Error::Format("hybrid block continuation is invalid"));
        }
        for pos in start + 1..end {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            self.capture_position(block, input, pos, end, false, dictionary, cancel)?;
            self.next_pos += 1;
        }
        Ok(())
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "研究用比較の入力と状態を独立した引数として保持する"
    )]
    fn capture_position(
        &mut self,
        block: &mut bt::Block,
        input: &[u8],
        pos: usize,
        end: usize,
        full_query: bool,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<(), Error> {
        let count = {
            let output = block.scratch_mut();
            self.process_position(
                Some(output),
                input,
                pos,
                end,
                full_query,
                dictionary,
                cancel,
            )?
        };
        debug_assert!(
            block.scratch_mut()[..count]
                .windows(2)
                .all(|pair| pair[0].distance() < pair[1].distance())
        );
        block.store_position(pos, count)?;
        Ok(())
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "研究用比較の入力と状態を独立した引数として保持する"
    )]
    fn process_position(
        &mut self,
        mut output: Option<&mut [bt::Candidate]>,
        input: &[u8],
        pos: usize,
        block_end: usize,
        full_query: bool,
        dictionary: usize,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        self.far.age_for(input, pos, dictionary, cancel)?;
        let query_limit = if output.is_some() && full_query {
            MAX_MATCH.min(input.len() - pos)
        } else if output.is_some() {
            MAX_MATCH.min(block_end - pos)
        } else {
            0
        };
        let snapshot_limit = block_end.saturating_sub(pos).min(query_limit);
        let mut count = 0usize;
        let mut best = 3usize;
        let mut near_full_match = false;

        if query_limit >= NEAR_HASH_BYTES {
            let key = near_hash(input, pos);
            let mut candidate = self.near_heads[key];
            let mut compared = 0usize;
            for chain in 0..NEAR_CHAIN {
                if candidate == NONE {
                    break;
                }
                let source = candidate as usize;
                if source >= pos {
                    break;
                }
                let distance = pos - source;
                if distance > NEAR_WINDOW || distance > dictionary {
                    break;
                }
                if chain & 31 == 0 {
                    check(cancel)?;
                }
                if let Some(values) = output.as_deref_mut() {
                    let length =
                        match_length(input, source, pos, query_limit, &mut compared, cancel)?;
                    if length >= NEAR_HASH_BYTES {
                        let previous_best = best;
                        if keep_candidate(&mut best, length, snapshot_limit) {
                            let value = bt::Candidate::new(distance, length)?;
                            if count < NEAR_SNAPSHOT {
                                values[count] = value;
                                count += 1;
                            } else if best > previous_best {
                                // bounded snapshotが満杯でも、後方の新しい最長だけは失わない。
                                values[NEAR_SNAPSHOT - 1] = value;
                            }
                        }
                    }
                    near_full_match |= length == query_limit;
                    if length == query_limit || compared >= MAX_COMPARE {
                        break;
                    }
                }
                candidate = self.near_previous[source % NEAR_RING];
            }
        }

        if let Some(values) = output
            && query_limit >= MIN_FAR_MATCH
            && dictionary > NEAR_WINDOW
            && pos > NEAR_WINDOW
            && !near_full_match
        {
            let mut far = [bt::Candidate::EMPTY; FAR_CANDIDATES];
            let mut far_count = 0usize;
            for alignment in 0..FAR_SAMPLE {
                if alignment & 3 == 0 {
                    check(cancel)?;
                }
                let query = pos + alignment;
                if input.len().saturating_sub(query) < FAR_KEY_BYTES {
                    break;
                }
                let key = far_hash(input, query) & (self.far.buckets.len() - 1);
                for &encoded in &self.far.buckets[key].positions {
                    if encoded == NONE {
                        continue;
                    }
                    let sample = encoded as usize;
                    if sample < alignment
                        || input[sample..sample + FAR_KEY_BYTES]
                            != input[query..query + FAR_KEY_BYTES]
                    {
                        continue;
                    }
                    let source = sample - alignment;
                    if source >= pos {
                        continue;
                    }
                    let distance = pos - source;
                    if distance <= NEAR_WINDOW || distance > dictionary {
                        continue;
                    }
                    far[far_count] = bt::Candidate::new(distance, 0)?;
                    far_count += 1;
                }
            }
            far[..far_count].sort_unstable_by_key(|candidate| candidate.distance());
            let mut previous_distance = 0usize;
            let mut compared = 0usize;
            for candidate in far[..far_count].iter().copied() {
                let distance = candidate.distance();
                if distance == previous_distance {
                    continue;
                }
                previous_distance = distance;
                if compared >= MAX_COMPARE {
                    break;
                }
                let source = pos - distance;
                let length = match_length(input, source, pos, query_limit, &mut compared, cancel)?;
                if length >= MIN_FAR_MATCH && keep_candidate(&mut best, length, snapshot_limit) {
                    values[count] = bt::Candidate::new(distance, length)?;
                    count += 1;
                }
            }
        }

        if input.len().saturating_sub(pos) >= NEAR_HASH_BYTES {
            let key = near_hash(input, pos);
            let previous = self.near_heads[key];
            self.near_previous[pos % NEAR_RING] = previous;
            self.near_heads[key] = u32::try_from(pos).map_err(|_| Error::Limit)?;
        }
        Ok(count)
    }
}

fn keep_candidate(best: &mut usize, length: usize, maximum: usize) -> bool {
    let effective = length.min(maximum);
    if effective < *best {
        return false;
    }
    *best = (*best).max(effective);
    true
}

#[inline(always)]
fn match_length(
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
        if remaining >= COMPARE_CHUNK
            && budget >= COMPARE_CHUNK
            && (*compared & 0xfff) <= 0xfff - COMPARE_CHUNK
        {
            let left = u64::from_le_bytes(
                input[source + length..source + length + COMPARE_CHUNK]
                    .try_into()
                    .unwrap(),
            );
            let right = u64::from_le_bytes(
                input[pos + length..pos + length + COMPARE_CHUNK]
                    .try_into()
                    .unwrap(),
            );
            let difference = left ^ right;
            if difference == 0 {
                length += COMPARE_CHUNK;
                *compared += COMPARE_CHUNK;
                continue;
            }
            let prefix = (difference.trailing_zeros() / 8) as usize;
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

fn near_hash(input: &[u8], pos: usize) -> usize {
    let low = u32::from_le_bytes(input[pos..pos + 4].try_into().unwrap()) as u64;
    let value = low | ((input[pos + 4] as u64) << 32);
    (value.wrapping_mul(0x9e37_79b1_85eb_ca87) >> (64 - NEAR_HASH_BITS)) as usize
}

fn far_hash(input: &[u8], pos: usize) -> usize {
    let first = u64::from_le_bytes(input[pos..pos + 8].try_into().unwrap());
    let second = u64::from_le_bytes(input[pos + 8..pos + 16].try_into().unwrap());
    let mixed = first.wrapping_mul(0x9e37_79b1_85eb_ca87).rotate_left(23)
        ^ second.wrapping_mul(0xc2b2_ae3d_27d4_eb4f);
    (mixed ^ (mixed >> 29)) as usize
}

fn far_bucket_count(dictionary: usize) -> Option<usize> {
    if dictionary == 0 || dictionary > MAX_INPUT {
        return None;
    }
    let samples = dictionary.saturating_sub(NEAR_WINDOW).div_ceil(FAR_SAMPLE);
    samples
        .div_ceil(FAR_WAYS)
        .max(1)
        .checked_next_power_of_two()
}

pub(super) fn extra_memory(block: usize, dictionary: usize) -> Option<usize> {
    NEAR_HASH_SIZE
        .checked_mul(std::mem::size_of::<u32>())?
        .checked_add(NEAR_RING.checked_mul(std::mem::size_of::<u32>())?)?
        .checked_add(far_bucket_count(dictionary)?.checked_mul(std::mem::size_of::<FarBucket>())?)?
        .checked_add(bt::block_memory(block, SNAPSHOT_DEPTH)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn random(size: usize) -> Vec<u8> {
        let mut state = 0x31f2_9a07u32;
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
    fn chunked_match_lengths_preserve_scalar_counts_and_cancellation() {
        let source = 16usize;
        let target = 160usize;
        let limit = 80usize;
        let mismatch_positions = [0usize, 7, 8, 15, 31, 63, 79, limit];
        let initial_counts = [0usize, 4087, 4088, 4094, 4095, MAX_COMPARE - 9];

        for mismatch in mismatch_positions {
            let mut input = random(256);
            let pattern = input[source..source + limit].to_vec();
            input[target..target + limit].copy_from_slice(&pattern);
            if mismatch < limit {
                input[target + mismatch] ^= 0xff;
            }

            for initial in initial_counts {
                let mut actual_count = initial;
                let mut expected_count = initial;
                let mut actual_checks = 0usize;
                let mut expected_checks = 0usize;
                let actual = match_length(
                    &input,
                    source,
                    target,
                    limit,
                    &mut actual_count,
                    &mut || {
                        actual_checks += 1;
                        false
                    },
                )
                .unwrap();
                let mut expected = 0usize;
                while expected < limit && expected_count < MAX_COMPARE {
                    expected_count += 1;
                    if expected_count & 0xfff == 0 {
                        expected_checks += 1;
                    }
                    if input[source + expected] != input[target + expected] {
                        break;
                    }
                    expected += 1;
                }
                assert_eq!(actual, expected);
                assert_eq!(actual_count, expected_count);
                assert_eq!(actual_checks, expected_checks);
            }
        }

        let mut actual_count = 4095usize;
        let mut actual_checks = 0usize;
        assert_eq!(
            match_length(
                &random(256),
                source,
                target,
                limit,
                &mut actual_count,
                &mut || {
                    actual_checks += 1;
                    true
                },
            ),
            Err(Error::Cancelled)
        );
        assert_eq!(actual_count, 4096);
        assert_eq!(actual_checks, 1);
    }

    #[test]
    fn far_bucket_is_four_way_and_evicts_the_oldest_collision() {
        let input = vec![7; 256];
        let mut index = FarIndex::with_bucket_count(1).unwrap();
        for sample in (0..=64).step_by(16) {
            index.insert(&input, sample, sample, input.len()).unwrap();
        }
        let positions = index.buckets[0].positions;
        assert!(positions.contains(&0));
        assert_eq!(
            positions
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>(),
            [0, 32, 48, 64].into_iter().collect()
        );
    }

    #[test]
    fn far_bucket_promotes_oldest_active_entry_when_anchor_expires() {
        let input = vec![7; 256];
        let dictionary = NEAR_WINDOW + 64;
        let mut index = FarIndex::with_bucket_count(1).unwrap();
        for sample in (0..=96).step_by(FAR_SAMPLE) {
            let current = NEAR_WINDOW + sample - 14;
            index.insert(&input, sample, current, dictionary).unwrap();
        }
        let positions = index.buckets[0].positions;
        assert_eq!(positions[0], 32);
        assert_eq!(
            positions
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>(),
            [32, 64, 80, 96].into_iter().collect()
        );
    }

    #[test]
    fn sixteen_source_alignments_recover_exact_far_matches() {
        let distance = NEAR_WINDOW + 257;
        let first = 512usize;
        let last = first + 15 * 192;
        let mut input = random(last + distance + 192);
        for alignment in 0..FAR_SAMPLE {
            let source = first + alignment * 192 + alignment;
            let target = source + distance;
            let pattern: Vec<u8> = (0..128)
                .map(|at| (at as u8).wrapping_mul(37).wrapping_add(alignment as u8))
                .collect();
            input[source..source + pattern.len()].copy_from_slice(&pattern);
            input[target..target + pattern.len()].copy_from_slice(&pattern);
        }
        let start = first + distance;
        let end = (last + distance + 160).min(input.len());
        let mut matcher = Matcher::new(input.len(), input.len()).unwrap();
        let mut block = bt::Block::new_with_depth(end - start, SNAPSHOT_DEPTH).unwrap();
        matcher
            .prepare_block(&mut block, &input, start, end, input.len(), &mut || false)
            .unwrap();
        for alignment in 0..FAR_SAMPLE {
            let source = first + alignment * 192 + alignment;
            let target = source + distance;
            assert!(
                block
                    .candidates_local(target - start)
                    .iter()
                    .any(|candidate| {
                        candidate.distance() == distance && candidate.length() >= 128
                    })
            );
        }
    }

    #[test]
    fn candidates_obey_distance_dictionary_and_exact_bytes() {
        let distance = NEAR_WINDOW + 65;
        let source = 32usize;
        let target = source + distance;
        let mut input = random(target + 256);
        let pattern = b"hybrid-far-pattern-0123456789abcdef".repeat(4);
        input[source..source + pattern.len()].copy_from_slice(&pattern);
        input[target..target + pattern.len()].copy_from_slice(&pattern);
        for dictionary in [NEAR_WINDOW, distance, distance + 1] {
            let mut matcher = Matcher::new(input.len(), dictionary).unwrap();
            let mut block = bt::Block::new_with_depth(128, SNAPSHOT_DEPTH).unwrap();
            matcher
                .prepare_block(
                    &mut block,
                    &input,
                    target,
                    target + 128,
                    dictionary,
                    &mut || false,
                )
                .unwrap();
            let candidates = block.candidates_local(0);
            assert_eq!(
                candidates.iter().any(|value| value.distance() == distance),
                dictionary >= distance
            );
            for candidate in candidates {
                assert!((1..=dictionary).contains(&candidate.distance()));
                assert!(candidate.distance() <= target);
                assert!(candidate.length() <= MAX_MATCH);
                assert_eq!(
                    &input[target - candidate.distance()
                        ..target - candidate.distance() + candidate.length()],
                    &input[target..target + candidate.length()]
                );
            }
        }
    }

    #[test]
    fn exact_near_and_far_boundaries_include_alignment_fifteen() {
        let pattern: Vec<u8> = (0..128).map(|at| (at * 71 + 19) as u8).collect();

        let near_target = NEAR_WINDOW;
        let mut near_input = random(near_target + pattern.len());
        near_input[..pattern.len()].copy_from_slice(&pattern);
        near_input[near_target..near_target + pattern.len()].copy_from_slice(&pattern);
        let mut near_matcher = Matcher::new(near_input.len(), NEAR_WINDOW).unwrap();
        let mut near_block = bt::Block::new_with_depth(128, SNAPSHOT_DEPTH).unwrap();
        near_matcher
            .prepare_block(
                &mut near_block,
                &near_input,
                near_target,
                near_target + 128,
                NEAR_WINDOW,
                &mut || false,
            )
            .unwrap();
        assert!(near_block.candidates_local(0).iter().any(|candidate| {
            candidate.distance() == NEAR_WINDOW && candidate.length() >= pattern.len()
        }));

        // source=1では次のabsolute sampleが16なのでalignment=15。distance=W+1の
        // query時点でsample=16をage済みにする閾値を独立に確認する。
        let far_source = 1usize;
        let far_distance = NEAR_WINDOW + 1;
        let far_target = far_source + far_distance;
        let mut far_input = random(far_target + pattern.len());
        far_input[far_source..far_source + pattern.len()].copy_from_slice(&pattern);
        far_input[far_target..far_target + pattern.len()].copy_from_slice(&pattern);
        let mut far_matcher = Matcher::new(far_input.len(), far_distance).unwrap();
        let mut far_block = bt::Block::new_with_depth(128, SNAPSHOT_DEPTH).unwrap();
        far_matcher
            .prepare_block(
                &mut far_block,
                &far_input,
                far_target,
                far_target + 128,
                far_distance,
                &mut || false,
            )
            .unwrap();
        assert!(far_block.candidates_local(0).iter().any(|candidate| {
            candidate.distance() == far_distance && candidate.length() >= pattern.len()
        }));
    }

    #[test]
    fn expired_anchor_is_reused_with_an_eight_mib_dictionary() {
        let dictionary = 8 * 1024 * 1024;
        let distance = NEAR_WINDOW + 1024;
        let target = dictionary + NEAR_WINDOW + 4096;
        let source = target - distance;
        let mut input = random(target + 256);
        let pattern: Vec<u8> = (0..192).map(|at| (at * 43 + 7) as u8).collect();
        input[source..source + pattern.len()].copy_from_slice(&pattern);
        input[target..target + pattern.len()].copy_from_slice(&pattern);
        let mut matcher = Matcher::new(input.len(), dictionary).unwrap();
        let mut block = bt::Block::new_with_depth(192, SNAPSHOT_DEPTH).unwrap();
        matcher
            .prepare_block(
                &mut block,
                &input,
                target,
                target + 192,
                dictionary,
                &mut || false,
            )
            .unwrap();
        assert!(block.candidates_local(0).iter().any(|candidate| {
            candidate.distance() == distance && candidate.length() >= pattern.len()
        }));
    }

    #[test]
    fn far_anchor_reaches_the_end_of_the_sixty_four_mib_dictionary() {
        let target = MAX_INPUT - 256;
        let mut input = vec![0u8; MAX_INPUT];
        let pattern: Vec<u8> = (0..256).map(|at| (at * 29 + 3) as u8).collect();
        input[..pattern.len()].copy_from_slice(&pattern);
        input[target..target + pattern.len()].copy_from_slice(&pattern);
        let mut matcher = Matcher::new(input.len(), MAX_INPUT).unwrap();
        let mut block = bt::Block::new_with_depth(128, SNAPSHOT_DEPTH).unwrap();
        matcher
            .prepare_block(
                &mut block,
                &input,
                target,
                target + 128,
                MAX_INPUT,
                &mut || false,
            )
            .unwrap();
        assert!(block.candidates_local(0).iter().any(|candidate| {
            candidate.distance() == target && candidate.length() >= pattern.len()
        }));
    }

    #[test]
    fn skipped_positions_are_caught_up_and_can_be_near_sources() {
        let mut input = random(200_000);
        let source = 120_000usize;
        let target = 180_000usize;
        let pattern = b"catch-up positions remain searchable after a bypass".repeat(4);
        input[source..source + pattern.len()].copy_from_slice(&pattern);
        input[target..target + pattern.len()].copy_from_slice(&pattern);
        let mut matcher = Matcher::new(input.len(), input.len()).unwrap();
        let mut first = bt::Block::new_with_depth(1, SNAPSHOT_DEPTH).unwrap();
        matcher
            .prepare_block(&mut first, &input, 0, 1, input.len(), &mut || false)
            .unwrap();
        let mut later = bt::Block::new_with_depth(128, SNAPSHOT_DEPTH).unwrap();
        matcher
            .prepare_block(
                &mut later,
                &input,
                target,
                target + 128,
                input.len(),
                &mut || false,
            )
            .unwrap();
        assert_eq!(matcher.next_pos, target + 128);
        assert!(later.candidates_local(0).iter().any(|candidate| {
            candidate.distance() == target - source && candidate.length() >= pattern.len()
        }));
    }

    #[test]
    fn cancellation_is_checked_while_advancing_to_the_requested_block() {
        let input = vec![b'x'; 200_000];
        let mut matcher = Matcher::new(input.len(), input.len()).unwrap();
        let mut block = bt::Block::new_with_depth(64, SNAPSHOT_DEPTH).unwrap();
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
                    calls == 2
                }
            ),
            Err(Error::Cancelled)
        );
    }
}
