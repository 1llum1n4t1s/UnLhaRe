//! 固定開発入力に対する suffix-array 近傍候補の診断用実装。

use super::{Error, SelectedMatch, check};

const MAX_PROBE_INPUT: usize = 8 * 1024 * 1024;
const K_VALUES: [usize; 5] = [1, 2, 4, 8, 16];

fn zeroed_u32(length: usize) -> Result<Vec<u32>, &'static str> {
    let mut values = Vec::new();
    values
        .try_reserve_exact(length)
        .map_err(|_| "suffix probe allocation failed")?;
    values.resize(length, 0);
    Ok(values)
}

fn zeroed_usize(length: usize) -> Result<Vec<usize>, &'static str> {
    let mut values = Vec::new();
    values
        .try_reserve_exact(length)
        .map_err(|_| "suffix probe allocation failed")?;
    values.resize(length, 0);
    Ok(values)
}

fn suffix_pair(position: usize, ranks: &[u32], step: usize) -> (u32, u32) {
    (
        ranks[position],
        position
            .checked_add(step)
            .filter(|&next| next < ranks.len())
            .map_or(u32::MAX, |next| ranks[next]),
    )
}

#[derive(Clone, Copy)]
struct SortKey {
    step: usize,
    second_key: bool,
    classes: usize,
}

fn counting_sort(
    source: &[u32],
    destination: &mut [u32],
    ranks: &[u32],
    sort_key: SortKey,
    counts: &mut [usize],
    cancel: &mut impl FnMut() -> bool,
) -> Result<(), Error> {
    counts[..=sort_key.classes].fill(0);
    for (index, &position) in source.iter().enumerate() {
        if index & 0xffff == 0 {
            check(cancel)?;
        }
        let position = position as usize;
        let key = if sort_key.second_key {
            position
                .checked_add(sort_key.step)
                .filter(|&next| next < ranks.len())
                .map_or(0, |next| ranks[next] as usize + 1)
        } else {
            ranks[position] as usize + 1
        };
        counts[key] += 1;
    }

    let mut prefix = 0usize;
    for count in &mut counts[..=sort_key.classes] {
        let frequency = *count;
        *count = prefix;
        prefix += frequency;
    }
    for (index, &position) in source.iter().enumerate() {
        if index & 0xffff == 0 {
            check(cancel)?;
        }
        let position_usize = position as usize;
        let key = if sort_key.second_key {
            position_usize
                .checked_add(sort_key.step)
                .filter(|&next| next < ranks.len())
                .map_or(0, |next| ranks[next] as usize + 1)
        } else {
            ranks[position_usize] as usize + 1
        };
        destination[counts[key]] = position;
        counts[key] += 1;
    }
    Ok(())
}

/// Prefix doubling with stable counting sorts. The gate is intentionally capped at 8 MiB.
fn build_suffix_array(
    input: &[u8],
    cancel: &mut impl FnMut() -> bool,
) -> Result<(Vec<u32>, Vec<u32>), Error> {
    let length = input.len();
    let mut suffixes = zeroed_u32(length).map_err(|_| Error::Limit)?;
    for (position, suffix) in suffixes.iter_mut().enumerate() {
        if position & 0xffff == 0 {
            check(cancel)?;
        }
        *suffix = u32::try_from(position).map_err(|_| Error::Limit)?;
    }
    if length == 0 {
        return Ok((suffixes, Vec::new()));
    }

    let mut scratch = zeroed_u32(length).map_err(|_| Error::Limit)?;
    let mut ranks = zeroed_u32(length).map_err(|_| Error::Limit)?;
    let mut next_ranks = zeroed_u32(length).map_err(|_| Error::Limit)?;
    for (rank, &byte) in ranks.iter_mut().zip(input) {
        *rank = u32::from(byte);
    }
    let mut counts = zeroed_usize(length.max(257)).map_err(|_| Error::Limit)?;
    let mut classes = 256usize;
    let mut step = 1usize;

    while step < length {
        counting_sort(
            &suffixes,
            &mut scratch,
            &ranks,
            SortKey {
                step,
                second_key: true,
                classes,
            },
            &mut counts,
            cancel,
        )?;
        counting_sort(
            &scratch,
            &mut suffixes,
            &ranks,
            SortKey {
                step,
                second_key: false,
                classes,
            },
            &mut counts,
            cancel,
        )?;

        let mut next_classes = 1usize;
        next_ranks[suffixes[0] as usize] = 0;
        let mut previous = suffix_pair(suffixes[0] as usize, &ranks, step);
        for (index, &suffix) in suffixes[1..].iter().enumerate() {
            if index & 0xffff == 0 {
                check(cancel)?;
            }
            let current = suffix_pair(suffix as usize, &ranks, step);
            if current != previous {
                next_classes += 1;
                previous = current;
            }
            next_ranks[suffix as usize] = (next_classes - 1) as u32;
        }
        std::mem::swap(&mut ranks, &mut next_ranks);
        classes = next_classes;
        if classes == length {
            break;
        }
        step = step.checked_mul(2).ok_or(Error::Limit)?;
    }

    // Replace class ids with inverse suffix-array ranks; scratch vectors are released on return.
    drop(scratch);
    drop(ranks);
    drop(next_ranks);
    drop(counts);
    let mut inverse = zeroed_u32(length).map_err(|_| Error::Limit)?;
    for (rank, &suffix) in suffixes.iter().enumerate() {
        if rank & 0xffff == 0 {
            check(cancel)?;
        }
        inverse[suffix as usize] = rank as u32;
    }
    Ok((suffixes, inverse))
}

struct ActiveRanks {
    levels: Vec<Vec<u64>>,
}

impl ActiveRanks {
    fn new(length: usize) -> Result<Self, &'static str> {
        let mut levels = Vec::new();
        let mut words = length.div_ceil(64);
        loop {
            let mut level = Vec::new();
            level
                .try_reserve_exact(words)
                .map_err(|_| "suffix probe allocation failed")?;
            level.resize(words, 0u64);
            levels.push(level);
            if words <= 1 {
                break;
            }
            words = words.div_ceil(64);
        }
        Ok(Self { levels })
    }

    fn insert(&mut self, mut index: usize) {
        for level in &mut self.levels {
            let word_index = index / 64;
            let mask = 1u64 << (index % 64);
            let word = &mut level[word_index];
            if *word & mask != 0 {
                return;
            }
            let was_empty = *word == 0;
            *word |= mask;
            if !was_empty {
                return;
            }
            index = word_index;
        }
    }

    fn remove(&mut self, mut index: usize) {
        for level in &mut self.levels {
            let word_index = index / 64;
            let mask = 1u64 << (index % 64);
            let word = &mut level[word_index];
            if *word & mask == 0 {
                return;
            }
            *word &= !mask;
            if *word != 0 {
                return;
            }
            index = word_index;
        }
    }

    fn previous(&self, exclusive: usize) -> Option<usize> {
        Self::previous_at(&self.levels, 0, exclusive)
    }

    fn previous_at(levels: &[Vec<u64>], level: usize, exclusive: usize) -> Option<usize> {
        if exclusive == 0 {
            return None;
        }
        let word_index = (exclusive - 1) / 64;
        let included = (exclusive - 1) % 64 + 1;
        let mask = if included == 64 {
            u64::MAX
        } else {
            (1u64 << included) - 1
        };
        if let Some(&word) = levels.get(level)?.get(word_index) {
            let candidates = word & mask;
            if candidates != 0 {
                return Some(word_index * 64 + (63 - candidates.leading_zeros() as usize));
            }
        }
        let previous_word = Self::previous_at(levels, level + 1, word_index)?;
        let word = *levels.get(level)?.get(previous_word)?;
        Some(previous_word * 64 + (63 - word.leading_zeros() as usize))
    }

    fn next(&self, inclusive: usize) -> Option<usize> {
        Self::next_at(&self.levels, 0, inclusive)
    }

    fn next_at(levels: &[Vec<u64>], level: usize, inclusive: usize) -> Option<usize> {
        let words = levels.get(level)?;
        let word_index = inclusive / 64;
        let skipped = inclusive % 64;
        if let Some(&word) = words.get(word_index) {
            let candidates = word & (u64::MAX << skipped);
            if candidates != 0 {
                return Some(word_index * 64 + candidates.trailing_zeros() as usize);
            }
        }
        let next_word = Self::next_at(levels, level + 1, word_index + 1)?;
        let word = *words.get(next_word)?;
        Some(next_word * 64 + word.trailing_zeros() as usize)
    }
}

fn token_is_covered(input: &[u8], offset: usize, length: usize, source: usize) -> bool {
    input.get(offset..offset + length) == input.get(source..source + length)
}

/// Measures how often a selected BT5 match is represented by the K nearest active suffix ranks.
pub(crate) fn measure(
    input: &[u8],
    selected: &[SelectedMatch],
    dictionary: usize,
    maximum_k: usize,
) -> Result<serde_json::Value, &'static str> {
    if input.len() > MAX_PROBE_INPUT {
        return Err("suffix probe is capped at 8 MiB for this development gate");
    }
    if !K_VALUES.contains(&maximum_k) {
        return Err("suffix probe K must be one of 1, 2, 4, 8, or 16");
    }
    if selected
        .windows(2)
        .any(|pair| pair[0].offset >= pair[1].offset)
        || selected.iter().any(|item| {
            item.offset >= input.len()
                || item.distance == 0
                || item.distance > item.offset
                || item.length < 3
                || item.length > input.len() - item.offset
        })
    {
        return Err("selected match trace is invalid or unordered");
    }

    let (suffixes, inverse) =
        build_suffix_array(input, &mut || false).map_err(|_| "suffix array construction failed")?;
    let mut active = ActiveRanks::new(input.len())?;
    let mut coverage = [[0u64; 3]; K_VALUES.len()];
    let mut total = 0u64;
    let mut selected_index = 0usize;
    let effective_dictionary = dictionary.min(input.len());

    for offset in 0..input.len() {
        if offset > 0 {
            let source = offset - 1;
            active.insert(inverse[source] as usize);
        }
        if offset > effective_dictionary {
            let expired = offset - effective_dictionary - 1;
            active.remove(inverse[expired] as usize);
        }

        while selected
            .get(selected_index)
            .is_some_and(|item| item.offset == offset)
        {
            let item = selected[selected_index];
            let source = offset - item.distance;
            let query_rank = inverse[offset] as usize;
            let mut exact = [false; K_VALUES.len()];
            let mut length = [false; K_VALUES.len()];
            let mut no_farther = [false; K_VALUES.len()];

            for predecessor in [true, false] {
                let mut cursor = if predecessor {
                    query_rank
                } else {
                    query_rank + 1
                };
                for neighbor_index in 0..maximum_k {
                    let rank = if predecessor {
                        active.previous(cursor)
                    } else {
                        active.next(cursor)
                    };
                    let Some(rank) = rank else { break };
                    cursor = if predecessor { rank } else { rank + 1 };
                    let candidate_source = suffixes[rank] as usize;
                    if candidate_source >= offset {
                        return Err("suffix probe active set contains a future position");
                    }
                    let same_source = candidate_source == source;
                    let matches_length =
                        token_is_covered(input, offset, item.length, candidate_source);
                    let distance_not_greater = offset - candidate_source <= item.distance;
                    for (index, k) in K_VALUES.iter().enumerate() {
                        if *k <= maximum_k && neighbor_index < *k {
                            exact[index] |= same_source;
                            length[index] |= matches_length;
                            no_farther[index] |= matches_length && distance_not_greater;
                        }
                    }
                }
            }

            total += 1;
            for (index, k) in K_VALUES.iter().enumerate() {
                if *k <= maximum_k {
                    coverage[index][0] += u64::from(exact[index]);
                    coverage[index][1] += u64::from(length[index]);
                    coverage[index][2] += u64::from(no_farther[index]);
                }
            }
            selected_index += 1;
        }
    }
    if selected_index != selected.len() {
        return Err("selected match offset exceeds input");
    }

    let results = K_VALUES
        .iter()
        .enumerate()
        .filter(|(_, k)| **k <= maximum_k)
        .map(|(index, k)| {
            let (exact, length, no_farther) =
                (coverage[index][0], coverage[index][1], coverage[index][2]);
            serde_json::json!({
                "k_each_side": k,
                "selected_match_count": total,
                "same_source_available": exact,
                "same_source_percent": percentage(exact, total),
                "selected_length_available": length,
                "selected_length_percent": percentage(length, total),
                "selected_length_with_distance_no_greater": no_farther,
                "selected_length_with_distance_no_greater_percent": percentage(no_farther, total),
            })
        })
        .collect::<Vec<_>>();

    Ok(serde_json::json!({
        "method": "prefix-doubling suffix array; K nearest active suffix ranks on each lexicographic side",
        "note": "Coverage is a candidate-retention screen, not a parse or compression result. Distance no-greater is only a conservative heuristic for distance price; it does not establish identical model cost.",
        "input_bytes": input.len(),
        "dictionary_bytes": dictionary,
        "selected_match_count": total,
        "max_k_each_side": maximum_k,
        "measurements": results,
    }))
}

fn percentage(value: u64, total: u64) -> f64 {
    if total == 0 {
        100.0
    } else {
        value as f64 * 100.0 / total as f64
    }
}

#[cfg(test)]
mod tests {
    use super::{ActiveRanks, build_suffix_array};
    use std::collections::BTreeSet;

    fn naive_suffix_array(input: &[u8]) -> Vec<u32> {
        let mut suffixes: Vec<u32> = (0..input.len() as u32).collect();
        suffixes.sort_by(|&left, &right| input[left as usize..].cmp(&input[right as usize..]));
        suffixes
    }

    #[test]
    fn prefix_doubling_matches_naive_suffix_order() {
        for input in [
            b"".as_slice(),
            b"a",
            b"banana",
            b"mississippi",
            b"aaaaaaa",
            b"ababababac",
            &[0, 255, 0, 255, 1, 0],
        ] {
            let (actual, inverse) = build_suffix_array(input, &mut || false).unwrap();
            assert_eq!(actual, naive_suffix_array(input), "input={input:?}");
            for (rank, &position) in actual.iter().enumerate() {
                assert_eq!(inverse[position as usize] as usize, rank);
            }
        }
    }

    #[test]
    fn active_rank_bitmap_matches_ordered_set_across_insertions_and_removals() {
        let mut active = ActiveRanks::new(513).unwrap();
        let mut oracle = BTreeSet::new();
        for index in [0, 1, 63, 64, 127, 128, 255, 256, 511, 512] {
            active.insert(index);
            oracle.insert(index);
        }
        for query in 0..=513 {
            assert_eq!(
                active.previous(query),
                oracle.range(..query).next_back().copied()
            );
            assert_eq!(active.next(query), oracle.range(query..).next().copied());
        }
        for index in [0, 64, 128, 256, 512] {
            active.remove(index);
            oracle.remove(&index);
        }
        for query in 0..=513 {
            assert_eq!(
                active.previous(query),
                oracle.range(..query).next_back().copied()
            );
            assert_eq!(active.next(query), oracle.range(query..).next().copied());
        }
    }
}
