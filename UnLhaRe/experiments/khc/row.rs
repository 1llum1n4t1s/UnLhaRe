//! 研究用beamだけで使うrow/tag match finder。
//!
//! 5-byte hashをrow indexと8-bit tagへ分け、各rowの固定16位置だけを調べる。
//! Warm/Blendedの暫定parseと本beamが同じ候補列を見るよう、結果は既存のblock
//! snapshotへ保存する。

use super::{Error, bt, buffer, check};

pub(super) const SLOTS: usize = 16;
const NONE: u32 = u32::MAX;
const MAX_MATCH: usize = 1 << 16;
const HASH_BYTES: usize = 5;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Config {
    R4,
    R5,
}

impl Config {
    const fn row_bits(self) -> usize {
        match self {
            Self::R4 => 16,
            Self::R5 => 18,
        }
    }

    const fn rows(self) -> usize {
        1usize << self.row_bits()
    }
}

pub(super) struct Matcher {
    config: Config,
    positions: Vec<u32>,
    tags: Vec<u8>,
    next_slots: Vec<u8>,
    next_pos: usize,
}

#[derive(Clone, Copy)]
struct CaptureRequest {
    pos: usize,
    dictionary: usize,
    query_limit: usize,
    snapshot_limit: usize,
}

impl Matcher {
    pub(super) fn new(config: Config) -> Result<Self, Error> {
        let rows = config.rows();
        let entries = rows.checked_mul(SLOTS).ok_or(Error::Limit)?;
        Ok(Self {
            config,
            positions: buffer(entries, NONE)?,
            tags: buffer(entries, 0)?,
            next_slots: buffer(rows, 0)?,
            next_pos: 0,
        })
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
        if start < self.next_pos || end < start || end > input.len() {
            return Err(Error::Format("row matcher positions are not monotonic"));
        }
        if start == end {
            return Err(Error::Format("row matcher block is empty"));
        }
        block.begin(start, end - start)?;

        // 長いtokenで飛ばした位置もrowへ順に登録する。
        while self.next_pos < start {
            if self.next_pos & 0xffff == 0 {
                check(cancel)?;
            }
            self.capture(
                input,
                CaptureRequest {
                    pos: self.next_pos,
                    dictionary,
                    query_limit: 0,
                    snapshot_limit: 0,
                },
                None,
                cancel,
            )?;
            self.next_pos += 1;
        }

        let query = MAX_MATCH.min(input.len() - start);
        let count = self.capture(
            input,
            CaptureRequest {
                pos: start,
                dictionary,
                query_limit: query,
                snapshot_limit: end - start,
            },
            Some(block.scratch_mut()),
            cancel,
        )?;
        block.store_position(start, count)?;
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
        if !block.covers(start, end - start) || self.next_pos != start + 1 || end > input.len() {
            return Err(Error::Format("row matcher block continuation is invalid"));
        }
        for pos in start + 1..end {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            let count = self.capture(
                input,
                CaptureRequest {
                    pos,
                    dictionary,
                    query_limit: end - pos,
                    snapshot_limit: end - pos,
                },
                Some(block.scratch_mut()),
                cancel,
            )?;
            block.store_position(pos, count)?;
            self.next_pos += 1;
        }
        Ok(())
    }

    fn capture(
        &mut self,
        input: &[u8],
        request: CaptureRequest,
        output: Option<&mut [bt::Candidate]>,
        cancel: &mut impl FnMut() -> bool,
    ) -> Result<usize, Error> {
        let CaptureRequest {
            pos,
            dictionary,
            query_limit,
            snapshot_limit,
        } = request;
        if input.len() - pos < HASH_BYTES {
            return Ok(0);
        }

        let (row, tag) = hash_parts(input, pos, self.config);
        let base = row * SLOTS;
        let mut sources = [NONE; SLOTS];
        let mut source_count = 0usize;
        if output.is_some() {
            for slot in 0..SLOTS {
                let index = base + slot;
                let source = self.positions[index];
                if source == NONE || self.tags[index] != tag {
                    continue;
                }
                let source = source as usize;
                if source >= pos {
                    continue;
                }
                let distance = pos - source;
                if distance > dictionary {
                    continue;
                }
                // tag衝突は候補にせず、実際の5 byte一致を必ず確認する。
                if input[source..source + HASH_BYTES] != input[pos..pos + HASH_BYTES] {
                    continue;
                }
                sources[source_count] = source as u32;
                source_count += 1;
            }
            sources[..source_count].sort_unstable_by_key(|&source| pos - source as usize);
        }

        let slot = usize::from(self.next_slots[row]);
        let index = base + slot;
        self.positions[index] = u32::try_from(pos).map_err(|_| Error::Limit)?;
        self.tags[index] = tag;
        self.next_slots[row] = ((slot + 1) & (SLOTS - 1)) as u8;

        let mut count = 0usize;
        let mut best = 3usize;
        if let Some(values) = output {
            for &source in &sources[..source_count] {
                check(cancel)?;
                let source = source as usize;
                let maximum = query_limit.min(input.len() - pos);
                let mut length = HASH_BYTES.min(maximum);
                while length < maximum && input[source + length] == input[pos + length] {
                    length += 1;
                    if length & 0xfff == 0 {
                        check(cancel)?;
                    }
                }
                let effective = length.min(snapshot_limit);
                if effective < best {
                    continue;
                }
                best = best.max(effective);
                values[count] = bt::Candidate::new(pos - source, length)?;
                count += 1;
            }
        }
        Ok(count)
    }
}

fn hash_parts(input: &[u8], pos: usize, config: Config) -> (usize, u8) {
    let low = u32::from_le_bytes(input[pos..pos + 4].try_into().unwrap()) as u64;
    let value = low | (u64::from(input[pos + 4]) << 32);
    let mixed = value.wrapping_mul(0x9e37_79b1_85eb_ca87);
    let row_bits = config.row_bits();
    let row = (mixed >> (64 - row_bits)) as usize;
    let tag = (mixed >> (64 - row_bits - 8)) as u8;
    (row, tag)
}

pub(super) fn extra_memory(block: usize, config: Config) -> Option<usize> {
    let rows = config.rows();
    rows.checked_mul(SLOTS)?
        .checked_mul(std::mem::size_of::<u32>())?
        .checked_add(
            rows.checked_mul(SLOTS)?
                .checked_mul(std::mem::size_of::<u8>())?,
        )?
        .checked_add(rows.checked_mul(std::mem::size_of::<u8>())?)?
        .checked_add(bt::block_memory(block, SLOTS)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prepare(input: &[u8], config: Config, block_size: usize) -> bt::Block {
        let mut matcher = Matcher::new(config).unwrap();
        let mut block = bt::Block::new_with_depth(block_size, SLOTS).unwrap();
        matcher
            .prepare_start(
                &mut block,
                input,
                0,
                input.len().min(block_size),
                input.len(),
                &mut || false,
            )
            .unwrap();
        matcher
            .prepare_rest(
                &mut block,
                input,
                0,
                input.len().min(block_size),
                input.len(),
                &mut || false,
            )
            .unwrap();
        block
    }

    #[test]
    fn tag_and_exact_prefix_filter_hash_collisions() {
        for config in [Config::R4, Config::R5] {
            let first = [0u8; 5];
            let (wanted_row, wanted_tag) = hash_parts(&first, 0, config);
            let mut tag_collision: Option<[u8; 5]> = None;
            for value in 1u64..8_000_000 {
                let bytes = value.to_le_bytes();
                let candidate = &bytes[..5];
                let (row, tag) = hash_parts(candidate, 0, config);
                if row == wanted_row && tag != wanted_tag && tag_collision.is_none() {
                    tag_collision = Some(candidate.try_into().unwrap());
                    break;
                }
            }
            let tag_collision = tag_collision.expect("deterministic row collision");
            let mut input = Vec::new();
            input.extend_from_slice(&tag_collision);
            input.extend_from_slice(&first);

            let mut matcher = Matcher::new(config).unwrap();
            matcher
                .capture(
                    &input,
                    CaptureRequest {
                        pos: 0,
                        dictionary: input.len(),
                        query_limit: 0,
                        snapshot_limit: 0,
                    },
                    None,
                    &mut || false,
                )
                .unwrap();
            let mut scratch = [bt::Candidate::EMPTY; SLOTS];
            assert_eq!(
                matcher
                    .capture(
                        &input,
                        CaptureRequest {
                            pos: 5,
                            dictionary: input.len(),
                            query_limit: 5,
                            snapshot_limit: 5,
                        },
                        Some(&mut scratch),
                        &mut || false
                    )
                    .unwrap(),
                0,
                "different tag must reject a row collision"
            );

            // tag表が衝突した状態を直接作り、5-byte実値の再検証も候補を拒否することを確認する。
            let collision_slot = matcher.positions[wanted_row * SLOTS..(wanted_row + 1) * SLOTS]
                .iter()
                .position(|&position| position == 0)
                .unwrap();
            matcher.tags[wanted_row * SLOTS + collision_slot] = wanted_tag;
            assert_eq!(
                matcher
                    .capture(
                        &input,
                        CaptureRequest {
                            pos: 5,
                            dictionary: input.len(),
                            query_limit: 5,
                            snapshot_limit: 5,
                        },
                        Some(&mut scratch),
                        &mut || false
                    )
                    .unwrap(),
                0,
                "equal tag must still byte-verify the five-byte key"
            );
        }
    }

    #[test]
    fn row_wrap_evicts_the_oldest_slot() {
        let mut input = Vec::new();
        for _ in 0..=SLOTS + 1 {
            input.extend_from_slice(b"abcde");
        }
        let block = prepare(&input, Config::R4, input.len());
        let candidates = block.candidates((SLOTS + 1) * 5);
        assert_eq!(candidates.len(), SLOTS);
        assert!(
            candidates
                .iter()
                .all(|candidate| candidate.distance() <= SLOTS * 5)
        );
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.distance() == SLOTS * 5)
        );
        assert!(
            !candidates
                .iter()
                .any(|candidate| candidate.distance() == (SLOTS + 1) * 5),
            "oldest position must be gone after the seventeenth insertion"
        );
    }

    #[test]
    fn candidates_are_sorted_legal_and_byte_verified() {
        let input = b"abcde-abcdeXabcdeXYabcdeXYZtail";
        for config in [Config::R4, Config::R5] {
            let block = prepare(input, config, input.len());
            for pos in 0..input.len() {
                let candidates = block.candidates(pos);
                assert!(
                    candidates
                        .windows(2)
                        .all(|pair| pair[0].distance() < pair[1].distance())
                );
                for candidate in candidates {
                    let distance = candidate.distance();
                    let length = candidate.length();
                    assert!((1..=pos).contains(&distance));
                    assert!((HASH_BYTES..=input.len() - pos).contains(&length));
                    assert_eq!(
                        &input[pos - distance..pos - distance + length],
                        &input[pos..pos + length]
                    );
                    if pos + length < input.len() {
                        assert_ne!(input[pos - distance + length], input[pos + length]);
                    }
                }
            }
        }
    }

    #[test]
    fn block_boundaries_and_skipped_positions_remain_monotonic() {
        let input = b"01234abcde01234abcde01234abcde01234abcde";
        let mut matcher = Matcher::new(Config::R4).unwrap();
        let mut block = bt::Block::new_with_depth(8, SLOTS).unwrap();
        matcher
            .prepare_start(&mut block, input, 10, 18, 64, &mut || false)
            .unwrap();
        matcher
            .prepare_rest(&mut block, input, 10, 18, 64, &mut || false)
            .unwrap();
        assert!(
            block
                .candidates(10)
                .iter()
                .all(|candidate| candidate.distance() <= 10)
        );
        matcher
            .prepare_start(&mut block, input, 25, 33, 64, &mut || false)
            .unwrap();
        matcher
            .prepare_rest(&mut block, input, 25, 33, 64, &mut || false)
            .unwrap();
        assert!(
            block
                .candidates(25)
                .iter()
                .any(|candidate| candidate.distance() == 10)
        );
        assert_eq!(
            matcher.prepare_start(&mut block, input, 24, 32, 64, &mut || false),
            Err(Error::Format("row matcher positions are not monotonic"))
        );
    }
}
