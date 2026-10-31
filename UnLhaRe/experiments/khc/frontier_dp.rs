//! BT5候補frontierに限ったLiteral／絶対距離Copyの研究screen。
//!
//! Rep履歴は使わない。greedyは最長frontier copyを一度だけ選び、その出現回数から
//! 固定価格を作る。DPはその価格でparseを一度だけ選ぶ。測定値は実frameではない。

use std::cmp::Ordering;
use std::collections::BinaryHeap;

use super::{Error, MAX_INPUT, bt, buffer, check};

const HEADER_BYTES: usize = super::HEADER;
const MIN_COPY: usize = 4;
const LENGTH_CONTEXTS: usize = 4;
const SLOT_CONTEXTS: usize = 4;
const LENGTH_SLOTS: usize = 16;
const DISTANCE_SLOTS: usize = usize::BITS as usize;
const LITERAL_CONTEXTS: usize = 33;
const LITERAL_ALPHABET: u64 = 256;
const MAX_COPY_LENGTH: usize = 1 << 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Token {
    offset: usize,
    length: usize,
    /// 0はLiteral。Copyは1以上の絶対距離。
    distance: usize,
}

#[derive(Debug, PartialEq)]
pub(crate) struct Estimate {
    pub shannon_ideal_bits: f64,
    pub raw_extra_bits: u64,
    pub header_bytes: usize,
    pub estimate_bytes: usize,
    pub greedy_shannon_ideal_bits: f64,
    pub greedy_raw_extra_bits: u64,
    pub greedy_estimate_bytes: usize,
    pub greedy_token_count: usize,
    pub token_count: usize,
    pub literal_count: usize,
    pub copy_count: usize,
    pub field_bits: [f64; 4],
}

#[derive(Debug, PartialEq)]
pub(crate) struct AllLengthsEstimate {
    pub estimate: Estimate,
    pub fixed_price_cost: f64,
    pub retained_candidate_count: u64,
    pub range_interval_count: u64,
    pub implicit_copy_length_count: u64,
}

struct Counts {
    choice: [[u64; 2]; LENGTH_CONTEXTS],
    literal: [[u64; 256]; LITERAL_CONTEXTS],
    length: [[u64; LENGTH_SLOTS]; LENGTH_CONTEXTS],
    distance_slot: [[u64; DISTANCE_SLOTS]; SLOT_CONTEXTS],
}

impl Counts {
    fn new() -> Self {
        Self {
            choice: [[0; 2]; LENGTH_CONTEXTS],
            literal: [[0; 256]; LITERAL_CONTEXTS],
            length: [[0; LENGTH_SLOTS]; LENGTH_CONTEXTS],
            distance_slot: [[0; DISTANCE_SLOTS]; SLOT_CONTEXTS],
        }
    }

    fn observe(&mut self, input: &[u8], token: Token) {
        let choice = usize::from(token.distance != 0);
        self.choice[token.offset & 3][choice] += 1;
        if token.distance == 0 {
            self.literal[literal_context(input, token.offset)][usize::from(input[token.offset])] +=
                1;
            return;
        }
        self.length[token.offset & 3][length_slot(token.length)] += 1;
        self.distance_slot[length_bucket(token.length)][distance_slot(token.distance)] += 1;
    }
}

struct Frozen {
    choice: [[f64; 2]; LENGTH_CONTEXTS],
    literal: [[f64; 256]; LITERAL_CONTEXTS],
    length: [[f64; LENGTH_SLOTS]; LENGTH_CONTEXTS],
    distance_slot: [[f64; DISTANCE_SLOTS]; SLOT_CONTEXTS],
}

impl Frozen {
    fn learn(input: &[u8], tokens: &[Token], max_length: usize, max_distance: usize) -> Self {
        let mut counts = Counts::new();
        for &token in tokens {
            counts.observe(input, token);
        }
        let minimum_length_slot = length_slot(MIN_COPY);
        let maximum_length_slot = length_slot(max_length.max(MIN_COPY));
        let length_alphabet = (maximum_length_slot - minimum_length_slot + 1) as u64;
        let maximum_distance_slot = distance_slot(max_distance.max(1));
        let distance_alphabet = (maximum_distance_slot + 1) as u64;
        let choice = std::array::from_fn(|context| {
            let total = counts.choice[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| laplace(counts.choice[context][symbol], total, 2))
        });
        let literal = std::array::from_fn(|context| {
            let total = counts.literal[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| {
                laplace(counts.literal[context][symbol], total, LITERAL_ALPHABET)
            })
        });
        let length = std::array::from_fn(|context| {
            let total = counts.length[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| {
                if (minimum_length_slot..=maximum_length_slot).contains(&symbol) {
                    laplace(counts.length[context][symbol], total, length_alphabet)
                } else {
                    f64::INFINITY
                }
            })
        });
        let distance_slot = std::array::from_fn(|context| {
            let total = counts.distance_slot[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| {
                if symbol <= maximum_distance_slot {
                    laplace(
                        counts.distance_slot[context][symbol],
                        total,
                        distance_alphabet,
                    )
                } else {
                    f64::INFINITY
                }
            })
        });
        Self {
            choice,
            literal,
            length,
            distance_slot,
        }
    }

    fn literal_bits(&self, input: &[u8], pos: usize) -> f64 {
        self.choice[pos & 3][0] + self.literal[literal_context(input, pos)][usize::from(input[pos])]
    }

    fn copy_bits(&self, pos: usize, distance: usize, length: usize) -> f64 {
        let context = pos & 3;
        let length_code = length_slot(length);
        let distance_code = distance_slot(distance);
        self.choice[context][1]
            + self.length[context][length_code]
            + raw_length_bits(length) as f64
            + self.distance_slot[length_bucket(length)][distance_code]
            + raw_distance_bits(distance) as f64
    }
}

pub(crate) fn screen(
    input: &[u8],
    dictionary: usize,
    block: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Estimate, Error> {
    if input.len() > MAX_INPUT
        || dictionary == 0
        || dictionary > MAX_INPUT
        || !(64..=8192).contains(&block)
        || !block.is_power_of_two()
    {
        return Err(Error::Limit);
    }
    let greedy = parse(input, dictionary, block, None, cancel)?;
    let max_length = input.len().min(block).min(MAX_COPY_LENGTH);
    let max_distance = dictionary.min(input.len().saturating_sub(1)).max(1);
    let prices = Frozen::learn(input, &greedy, max_length, max_distance);
    let selected = parse(input, dictionary, block, Some(&prices), cancel)?;
    verify(input, dictionary, &selected)?;
    let greedy_measure = measure_tokens(input, &greedy, greedy.len());
    let mut estimate = measure_tokens(input, &selected, greedy.len());
    estimate.greedy_shannon_ideal_bits = greedy_measure.shannon_ideal_bits;
    estimate.greedy_raw_extra_bits = greedy_measure.raw_extra_bits;
    estimate.greedy_estimate_bytes = greedy_measure.estimate_bytes;
    Ok(estimate)
}

pub(crate) fn screen_all_lengths(
    input: &[u8],
    dictionary: usize,
    block: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<AllLengthsEstimate, Error> {
    if input.len() > MAX_INPUT
        || dictionary == 0
        || dictionary > MAX_INPUT
        || !(64..=8192).contains(&block)
        || !block.is_power_of_two()
    {
        return Err(Error::Limit);
    }
    let greedy = parse(input, dictionary, block, None, cancel)?;
    let max_length = input.len().min(block).min(MAX_COPY_LENGTH);
    let max_distance = dictionary.min(input.len().saturating_sub(1)).max(1);
    let prices = Frozen::learn(input, &greedy, max_length, max_distance);
    let parsed = parse_all_lengths(input, dictionary, block, &prices, cancel)?;
    verify(input, dictionary, &parsed.tokens)?;
    let greedy_measure = measure_tokens(input, &greedy, greedy.len());
    let mut estimate = measure_tokens(input, &parsed.tokens, greedy.len());
    estimate.greedy_shannon_ideal_bits = greedy_measure.shannon_ideal_bits;
    estimate.greedy_raw_extra_bits = greedy_measure.raw_extra_bits;
    estimate.greedy_estimate_bytes = greedy_measure.estimate_bytes;
    Ok(AllLengthsEstimate {
        estimate,
        fixed_price_cost: parsed.fixed_price_cost,
        retained_candidate_count: parsed.retained_candidate_count,
        range_interval_count: parsed.range_interval_count,
        implicit_copy_length_count: parsed.implicit_copy_length_count,
    })
}

fn parse(
    input: &[u8],
    dictionary: usize,
    block: usize,
    prices: Option<&Frozen>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    if input.is_empty() {
        return Ok(Vec::new());
    }
    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(0)?;
    let mut snapshot = bt::Block::new(block)?;
    if prices.is_none() {
        return greedy_parse(
            input,
            dictionary,
            block,
            &mut matcher,
            &mut snapshot,
            cancel,
        );
    }
    let prices = prices.unwrap();
    let mut cost = buffer(input.len() + 1, f64::INFINITY)?;
    let mut back = buffer(
        input.len() + 1,
        Back {
            prev: u32::MAX,
            distance: 0,
            length: 0,
        },
    )?;
    cost[0] = 0.0;
    let mut start = 0usize;
    while start < input.len() {
        check(cancel)?;
        let end = start.saturating_add(block).min(input.len());
        prepare(
            &mut matcher,
            &mut snapshot,
            input,
            start,
            end,
            dictionary,
            cancel,
        )?;
        for local in 0..end - start {
            if local & 0xffff == 0 {
                check(cancel)?;
            }
            let pos = start + local;
            let base = cost[pos];
            if !base.is_finite() {
                return Err(Error::Format("frontier DP left a position unreachable"));
            }
            relax(
                &mut cost,
                &mut back,
                pos + 1,
                pos,
                0,
                1,
                base + prices.literal_bits(input, pos),
            )?;
            for candidate in snapshot.candidates_local(local) {
                let distance = candidate.distance();
                let length = candidate.length().min(end - pos);
                let dest = pos.checked_add(length).ok_or(Error::Limit)?;
                if length < MIN_COPY
                    || distance == 0
                    || distance > dictionary
                    || distance > pos
                    || dest > input.len()
                {
                    continue;
                }
                relax(
                    &mut cost,
                    &mut back,
                    dest,
                    pos,
                    distance,
                    length,
                    base + prices.copy_bits(pos, distance, length),
                )?;
            }
        }
        start = end;
    }
    traceback(input.len(), &back)
}

struct AllLengthsParse {
    tokens: Vec<Token>,
    fixed_price_cost: f64,
    retained_candidate_count: u64,
    range_interval_count: u64,
    implicit_copy_length_count: u64,
}

#[derive(Clone, Copy, Debug)]
struct Offer {
    cost: f64,
    source: u32,
    distance: u32,
    last: u32,
    candidate_order: u8,
    segment_order: u8,
}

impl PartialEq for Offer {
    fn eq(&self, other: &Self) -> bool {
        self.cost.to_bits() == other.cost.to_bits()
            && self.source == other.source
            && self.distance == other.distance
            && self.last == other.last
            && self.candidate_order == other.candidate_order
            && self.segment_order == other.segment_order
    }
}

impl Eq for Offer {}

impl PartialOrd for Offer {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Offer {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.source.cmp(&self.source))
            .then_with(|| other.candidate_order.cmp(&self.candidate_order))
            .then_with(|| other.segment_order.cmp(&self.segment_order))
            .then_with(|| other.last.cmp(&self.last))
            .then_with(|| other.distance.cmp(&self.distance))
    }
}

const _: () = assert!(std::mem::size_of::<Offer>() == 24);

fn parse_all_lengths(
    input: &[u8],
    dictionary: usize,
    block: usize,
    prices: &Frozen,
    cancel: &mut impl FnMut() -> bool,
) -> Result<AllLengthsParse, Error> {
    if input.is_empty() {
        return Ok(AllLengthsParse {
            tokens: Vec::new(),
            fixed_price_cost: 0.0,
            retained_candidate_count: 0,
            range_interval_count: 0,
            implicit_copy_length_count: 0,
        });
    }

    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(0)?;
    let mut snapshot = bt::Block::new(block)?;
    let mut cost = buffer(input.len() + 1, f64::INFINITY)?;
    let mut back = buffer(
        input.len() + 1,
        Back {
            prev: u32::MAX,
            distance: 0,
            length: 0,
        },
    )?;
    cost[0] = 0.0;

    let mut retained_candidate_count = 0u64;
    let mut range_interval_count = 0u64;
    let mut implicit_copy_length_count = 0u64;
    let mut start = 0usize;
    while start < input.len() {
        check(cancel)?;
        let end = start.saturating_add(block).min(input.len());
        let block_length = end - start;
        prepare(
            &mut matcher,
            &mut snapshot,
            input,
            start,
            end,
            dictionary,
            cancel,
        )?;
        let mut pending: Vec<Vec<Offer>> = Vec::new();
        pending
            .try_reserve_exact(block_length + 1)
            .map_err(|_| Error::Limit)?;
        pending.resize_with(block_length + 1, Vec::new);
        let mut active = BinaryHeap::<Offer>::new();
        let mut expiration_pops = 0usize;

        for local in 0..=block_length {
            if local & 0x3f == 0 {
                check(cancel)?;
            }
            let pos = start + local;
            if local > 0 {
                let scheduled = std::mem::take(&mut pending[local]);
                active
                    .try_reserve(scheduled.len())
                    .map_err(|_| Error::Limit)?;
                active.extend(scheduled);
                while active
                    .peek()
                    .is_some_and(|offer| (offer.last as usize) < pos)
                {
                    active.pop();
                    expiration_pops += 1;
                    if expiration_pops & 0xfff == 0 {
                        check(cancel)?;
                    }
                }

                if let Some(offer) = active.peek().copied() {
                    cost[pos] = offer.cost;
                    back[pos] = Back {
                        prev: offer.source,
                        distance: offer.distance,
                        length: u32::try_from(pos - offer.source as usize)
                            .map_err(|_| Error::Limit)?,
                    };
                }

                let previous = pos - 1;
                let literal_cost = cost[previous] + prices.literal_bits(input, previous);
                if !literal_cost.is_finite() {
                    return Err(Error::Format("all-length frontier DP cost is not finite"));
                }
                if literal_cost < cost[pos] {
                    cost[pos] = literal_cost;
                    back[pos] = Back {
                        prev: u32::try_from(previous).map_err(|_| Error::Limit)?,
                        distance: 0,
                        length: 1,
                    };
                }
            }

            if local == block_length {
                break;
            }
            let base = cost[pos];
            if !base.is_finite() {
                return Err(Error::Format(
                    "all-length frontier DP left a position unreachable",
                ));
            }

            for (candidate_order, candidate) in
                snapshot.candidates_local(local).iter().copied().enumerate()
            {
                let distance = candidate.distance();
                let max_length = candidate.length().min(end - pos).min(MAX_COPY_LENGTH);
                if max_length < MIN_COPY || distance == 0 || distance > dictionary || distance > pos
                {
                    continue;
                }
                retained_candidate_count = retained_candidate_count
                    .checked_add(1)
                    .ok_or(Error::Limit)?;
                let candidate_order = u8::try_from(candidate_order).map_err(|_| Error::Limit)?;
                let mut first_length = MIN_COPY;
                let mut segment_order = 0u8;
                while first_length <= max_length {
                    let last_length = price_segment_end(first_length, max_length);
                    let first_target = pos + first_length;
                    let last_target = pos + last_length;
                    let copy_cost = base + prices.copy_bits(pos, distance, first_length);
                    if !copy_cost.is_finite() {
                        return Err(Error::Format("all-length frontier copy cost is not finite"));
                    }
                    let offer = Offer {
                        cost: copy_cost,
                        source: u32::try_from(pos).map_err(|_| Error::Limit)?,
                        distance: u32::try_from(distance).map_err(|_| Error::Limit)?,
                        last: u32::try_from(last_target).map_err(|_| Error::Limit)?,
                        candidate_order,
                        segment_order,
                    };
                    let target_local = first_target - start;
                    pending[target_local]
                        .try_reserve(1)
                        .map_err(|_| Error::Limit)?;
                    pending[target_local].push(offer);
                    range_interval_count =
                        range_interval_count.checked_add(1).ok_or(Error::Limit)?;
                    implicit_copy_length_count = implicit_copy_length_count
                        .checked_add((last_length - first_length + 1) as u64)
                        .ok_or(Error::Limit)?;
                    segment_order = segment_order.checked_add(1).ok_or(Error::Limit)?;
                    first_length = last_length + 1;
                }
            }
        }
        start = end;
    }

    Ok(AllLengthsParse {
        tokens: traceback(input.len(), &back)?,
        fixed_price_cost: cost[input.len()],
        retained_candidate_count,
        range_interval_count,
        implicit_copy_length_count,
    })
}

fn greedy_parse(
    input: &[u8],
    dictionary: usize,
    block: usize,
    matcher: &mut bt::Matcher,
    snapshot: &mut bt::Block,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    let mut tokens = Vec::new();
    tokens
        .try_reserve(input.len().min(4096))
        .map_err(|_| Error::Limit)?;
    let mut start = 0usize;
    while start < input.len() {
        check(cancel)?;
        let end = start.saturating_add(block).min(input.len());
        prepare(matcher, snapshot, input, start, end, dictionary, cancel)?;
        let mut pos = start;
        while pos < end {
            if pos & 0xffff == 0 {
                check(cancel)?;
            }
            let mut best: Option<(usize, usize)> = None;
            for candidate in snapshot.candidates_local(pos - start) {
                let distance = candidate.distance();
                let length = candidate.length().min(end - pos);
                if length < MIN_COPY
                    || distance == 0
                    || distance > dictionary
                    || distance > pos
                    || pos + length > input.len()
                {
                    continue;
                }
                let replace = match best {
                    None => true,
                    Some((best_length, best_distance)) => {
                        length > best_length || (length == best_length && distance < best_distance)
                    }
                };
                if replace {
                    best = Some((length, distance));
                }
            }
            let token = if let Some((length, distance)) = best {
                Token {
                    offset: pos,
                    length,
                    distance,
                }
            } else {
                Token {
                    offset: pos,
                    length: 1,
                    distance: 0,
                }
            };
            pos += token.length;
            push_token(&mut tokens, token)?;
        }
        start = pos;
    }
    Ok(tokens)
}

fn prepare(
    matcher: &mut bt::Matcher,
    snapshot: &mut bt::Block,
    input: &[u8],
    start: usize,
    end: usize,
    dictionary: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<(), Error> {
    matcher.prepare_start(snapshot, input, start, end, dictionary, cancel)?;
    matcher.prepare_rest(snapshot, input, start, end, dictionary, cancel)
}

#[derive(Clone, Copy)]
struct Back {
    prev: u32,
    distance: u32,
    length: u32,
}

fn relax(
    cost: &mut [f64],
    back: &mut [Back],
    dest: usize,
    pos: usize,
    distance: usize,
    length: usize,
    proposed: f64,
) -> Result<(), Error> {
    if dest >= cost.len() || !proposed.is_finite() {
        return Err(Error::Format("frontier DP edge is outside the input"));
    }
    if proposed < cost[dest] {
        cost[dest] = proposed;
        back[dest] = Back {
            prev: u32::try_from(pos).map_err(|_| Error::Limit)?,
            distance: u32::try_from(distance).map_err(|_| Error::Limit)?,
            length: u32::try_from(length).map_err(|_| Error::Limit)?,
        };
    }
    Ok(())
}

fn traceback(end: usize, back: &[Back]) -> Result<Vec<Token>, Error> {
    let mut reversed = Vec::new();
    reversed
        .try_reserve(end.min(4096))
        .map_err(|_| Error::Limit)?;
    let mut pos = end;
    while pos > 0 {
        let link = back[pos];
        let prev = link.prev as usize;
        let length = link.length as usize;
        if prev >= pos || prev + length != pos || length == 0 {
            return Err(Error::Format("frontier DP traceback is not contiguous"));
        }
        push_token(
            &mut reversed,
            Token {
                offset: prev,
                length,
                distance: link.distance as usize,
            },
        )?;
        pos = prev;
    }
    reversed.reverse();
    Ok(reversed)
}

fn push_token(tokens: &mut Vec<Token>, token: Token) -> Result<(), Error> {
    if tokens.len() == tokens.capacity() {
        tokens.try_reserve(256).map_err(|_| Error::Limit)?;
    }
    tokens.push(token);
    Ok(())
}

fn verify(input: &[u8], dictionary: usize, tokens: &[Token]) -> Result<(), Error> {
    let mut pos = 0usize;
    for token in tokens {
        if token.offset != pos || token.length == 0 || pos + token.length > input.len() {
            return Err(Error::Format("frontier DP token is not contiguous"));
        }
        if token.distance == 0 {
            if token.length != 1 {
                return Err(Error::Format("frontier literal is not one byte"));
            }
        } else if token.length < MIN_COPY
            || token.distance > dictionary
            || token.distance > pos
            || input[pos..pos + token.length]
                != input[pos - token.distance..pos - token.distance + token.length]
        {
            return Err(Error::Format("frontier copy does not replay the input"));
        }
        pos += token.length;
    }
    if pos != input.len() {
        return Err(Error::Format("frontier DP tokens do not cover the input"));
    }
    Ok(())
}

fn measure_tokens(input: &[u8], tokens: &[Token], greedy_token_count: usize) -> Estimate {
    let mut choice = [[0u64; 2]; LENGTH_CONTEXTS];
    let mut literal = [[0u64; 256]; LITERAL_CONTEXTS];
    let mut length = [[0u64; LENGTH_SLOTS]; LENGTH_CONTEXTS];
    let mut distance_histograms = [[0u64; DISTANCE_SLOTS]; SLOT_CONTEXTS];
    let mut raw_extra_bits = 0u64;
    let mut literal_count = 0usize;
    let mut copy_count = 0usize;
    for &token in tokens {
        let is_copy = usize::from(token.distance != 0);
        choice[token.offset & 3][is_copy] += 1;
        if token.distance == 0 {
            literal_count += 1;
            literal[literal_context(input, token.offset)][usize::from(input[token.offset])] += 1;
        } else {
            copy_count += 1;
            length[token.offset & 3][length_slot(token.length)] += 1;
            distance_histograms[length_bucket(token.length)][distance_slot(token.distance)] += 1;
            raw_extra_bits += raw_length_bits(token.length) + raw_distance_bits(token.distance);
        }
    }
    let mut field_bits = [0.0; 4];
    field_bits[0] = choice
        .iter()
        .map(|histogram| shannon(histogram))
        .sum::<f64>();
    field_bits[1] = literal.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[2] = length.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[3] = distance_histograms
        .iter()
        .map(|histogram| shannon(histogram))
        .sum();
    let shannon_ideal_bits = field_bits.iter().sum::<f64>();
    let payload_bytes = ((shannon_ideal_bits + raw_extra_bits as f64) / 8.0).ceil() as usize;
    Estimate {
        shannon_ideal_bits,
        raw_extra_bits,
        header_bytes: HEADER_BYTES,
        estimate_bytes: payload_bytes + HEADER_BYTES,
        greedy_shannon_ideal_bits: 0.0,
        greedy_raw_extra_bits: 0,
        greedy_estimate_bytes: 0,
        greedy_token_count,
        token_count: tokens.len(),
        literal_count,
        copy_count,
        field_bits,
    }
}

fn shannon(histogram: &[u64]) -> f64 {
    let total = histogram.iter().sum::<u64>();
    if total == 0 {
        return 0.0;
    }
    histogram
        .iter()
        .copied()
        .filter(|count| *count > 0)
        .map(|count| count as f64 * (total as f64 / count as f64).log2())
        .sum()
}

fn length_slot(length: usize) -> usize {
    length.saturating_sub(2).max(1).ilog2() as usize
}

fn laplace(count: u64, total: u64, alphabet: u64) -> f64 {
    ((total + alphabet) as f64 / (count + 1) as f64).log2()
}

fn literal_context(input: &[u8], pos: usize) -> usize {
    if pos == 0 {
        32
    } else {
        usize::from(input[pos - 1] >> 4)
    }
}

fn length_bucket(length: usize) -> usize {
    match length {
        0..=4 => 0,
        5..=8 => 1,
        9..=16 => 2,
        _ => 3,
    }
}

fn distance_slot(distance: usize) -> usize {
    distance.ilog2() as usize
}

fn raw_length_bits(length: usize) -> u64 {
    length_slot(length) as u64
}

fn raw_distance_bits(distance: usize) -> u64 {
    u64::from(distance.ilog2())
}

fn price_segment_end(first_length: usize, max_length: usize) -> usize {
    let slot_end = (1usize << (length_slot(first_length) + 1)) + 1;
    let bucket_end = match length_bucket(first_length) {
        0 => 4,
        1 => 8,
        2 => 16,
        _ => MAX_COPY_LENGTH,
    };
    max_length.min(slot_end).min(bucket_end)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_input_replays_contiguous_frontier_copies_and_counts_header() {
        let pattern = b"abcdefghijklmnopqrstuvwxyz012345";
        let mut input = Vec::new();
        for _ in 0..48 {
            input.extend_from_slice(pattern);
        }
        let estimate = screen(&input, input.len(), 256, &mut || false).unwrap();
        let repeated = screen(&input, input.len(), 256, &mut || false).unwrap();
        assert_eq!(estimate, repeated);
        assert!(estimate.copy_count > 0);
        assert_eq!(
            estimate.literal_count + estimate.copy_count,
            estimate.token_count
        );
        assert_eq!(estimate.header_bytes, 40);
        assert!(estimate.estimate_bytes >= 40);
        assert!(estimate.shannon_ideal_bits.is_finite());
        assert!(estimate.raw_extra_bits > 0);
    }

    #[test]
    fn greedy_and_dp_edges_are_clamped_at_block_boundaries() {
        let pattern = b"abcdefgh01234567";
        let mut input = Vec::new();
        for _ in 0..40 {
            input.extend_from_slice(pattern);
        }
        let block = 128;
        let greedy = parse(&input, input.len(), block, None, &mut || false).unwrap();
        assert!(
            greedy
                .iter()
                .all(|token| { token.offset / block == (token.offset + token.length - 1) / block })
        );
        let prices = Frozen::learn(
            &input,
            &greedy,
            block.min(input.len()).min(MAX_COPY_LENGTH),
            input.len() - 1,
        );
        let selected = parse(&input, input.len(), block, Some(&prices), &mut || false).unwrap();
        verify(&input, input.len(), &selected).unwrap();
        assert!(
            selected
                .iter()
                .all(|token| { token.offset / block == (token.offset + token.length - 1) / block })
        );
    }

    #[test]
    fn empty_input_is_only_the_header_allowance() {
        let estimate = screen(&[], 1024, 64, &mut || false).unwrap();
        assert_eq!(estimate.token_count, 0);
        assert_eq!(estimate.greedy_token_count, 0);
        assert_eq!(estimate.shannon_ideal_bits, 0.0);
        assert_eq!(estimate.raw_extra_bits, 0);
        assert_eq!(estimate.estimate_bytes, 40);
    }

    #[test]
    fn length_and_distance_slots_have_exact_residual_widths() {
        for slot in 1..LENGTH_SLOTS {
            let first = (1usize << slot) + 2;
            let last = (1usize << (slot + 1)) + 1;
            assert_eq!(length_slot(first), slot);
            assert_eq!(length_slot(last), slot);
            assert_eq!(raw_length_bits(first), slot as u64);
        }
        assert_eq!(length_slot(4), 1);
        assert_eq!(length_slot(MAX_COPY_LENGTH), 15);

        for slot in 0..26 {
            let first = 1usize << slot;
            let last = (1usize << (slot + 1)) - 1;
            assert_eq!(distance_slot(first), slot);
            assert_eq!(distance_slot(last), slot);
            assert_eq!(raw_distance_bits(first), slot as u64);
        }
    }

    #[test]
    fn add_one_price_tables_normalize_over_legal_symbols() {
        let input = b"abcdabcdabcd";
        let tokens = [
            Token {
                offset: 0,
                length: 1,
                distance: 0,
            },
            Token {
                offset: 1,
                length: 1,
                distance: 0,
            },
            Token {
                offset: 2,
                length: 1,
                distance: 0,
            },
            Token {
                offset: 3,
                length: 1,
                distance: 0,
            },
            Token {
                offset: 4,
                length: 4,
                distance: 4,
            },
            Token {
                offset: 8,
                length: 4,
                distance: 4,
            },
        ];
        let prices = Frozen::learn(input, &tokens, 12, 64);
        let probability = |bits: f64| 2.0f64.powf(-bits);
        let close_to_one = |sum: f64| assert!((sum - 1.0).abs() < 1e-12, "{sum}");

        for context in 0..LENGTH_CONTEXTS {
            close_to_one(
                prices.choice[context]
                    .iter()
                    .copied()
                    .map(probability)
                    .sum(),
            );
            close_to_one(
                prices.literal[context]
                    .iter()
                    .copied()
                    .map(probability)
                    .sum(),
            );
            close_to_one(
                prices.length[context][1..=length_slot(12)]
                    .iter()
                    .copied()
                    .map(probability)
                    .sum(),
            );
        }
        for context in 0..SLOT_CONTEXTS {
            close_to_one(
                prices.distance_slot[context][..=distance_slot(64)]
                    .iter()
                    .copied()
                    .map(probability)
                    .sum(),
            );
        }
    }

    fn slow_all_lengths_parse(
        input: &[u8],
        dictionary: usize,
        block: usize,
        prices: &Frozen,
    ) -> Vec<Token> {
        let mut matcher = bt::Matcher::new(input.len(), 5).unwrap();
        matcher.set_nice_len(0).unwrap();
        let mut snapshot = bt::Block::new(block).unwrap();
        let mut cost = vec![f64::INFINITY; input.len() + 1];
        let mut back = vec![
            Back {
                prev: u32::MAX,
                distance: 0,
                length: 0,
            };
            input.len() + 1
        ];
        cost[0] = 0.0;
        let mut start = 0usize;
        while start < input.len() {
            let end = start.saturating_add(block).min(input.len());
            prepare(
                &mut matcher,
                &mut snapshot,
                input,
                start,
                end,
                dictionary,
                &mut || false,
            )
            .unwrap();
            for local in 0..end - start {
                let pos = start + local;
                let base = cost[pos];
                relax(
                    &mut cost,
                    &mut back,
                    pos + 1,
                    pos,
                    0,
                    1,
                    base + prices.literal_bits(input, pos),
                )
                .unwrap();
                for candidate in snapshot.candidates_local(local) {
                    let distance = candidate.distance();
                    let max_length = candidate.length().min(end - pos).min(MAX_COPY_LENGTH);
                    if max_length < MIN_COPY
                        || distance == 0
                        || distance > dictionary
                        || distance > pos
                    {
                        continue;
                    }
                    for length in MIN_COPY..=max_length {
                        relax(
                            &mut cost,
                            &mut back,
                            pos + length,
                            pos,
                            distance,
                            length,
                            base + prices.copy_bits(pos, distance, length),
                        )
                        .unwrap();
                    }
                }
            }
            start = end;
        }
        traceback(input.len(), &back).unwrap()
    }

    #[test]
    fn interval_dp_matches_brute_force_for_every_legal_prefix() {
        let pattern = (0..64).map(|value| (value * 73) as u8).collect::<Vec<_>>();
        let mut input = Vec::new();
        for _ in 0..12 {
            input.extend_from_slice(&pattern);
        }
        let block = 128;
        let greedy = parse(&input, 128, block, None, &mut || false).unwrap();
        let prices = Frozen::learn(&input, &greedy, block, 128);
        let actual = parse_all_lengths(&input, 128, block, &prices, &mut || false).unwrap();
        let expected = slow_all_lengths_parse(&input, 128, block, &prices);
        assert_eq!(actual.tokens, expected);
        verify(&input, 128, &actual.tokens).unwrap();
        assert!(actual.range_interval_count > actual.retained_candidate_count);
        assert!(actual.implicit_copy_length_count >= actual.range_interval_count);
        assert!(
            actual
                .tokens
                .iter()
                .all(|token| { token.offset / block == (token.offset + token.length - 1) / block })
        );
        let replayed_price = actual
            .tokens
            .iter()
            .map(|token| {
                if token.distance == 0 {
                    prices.literal_bits(&input, token.offset)
                } else {
                    prices.copy_bits(token.offset, token.distance, token.length)
                }
            })
            .sum::<f64>();
        assert!((actual.fixed_price_cost - replayed_price).abs() < 1e-9);
    }

    #[test]
    fn constant_price_intervals_cover_each_legal_length_once() {
        let mut next = MIN_COPY;
        let mut covered = 0usize;
        let mut intervals = 0usize;
        while next <= MAX_COPY_LENGTH {
            let end = price_segment_end(next, MAX_COPY_LENGTH);
            assert!(end >= next);
            for length in next..=end {
                assert_eq!(length_slot(length), length_slot(next));
                assert_eq!(length_bucket(length), length_bucket(next));
            }
            covered += end - next + 1;
            intervals += 1;
            next = end + 1;
        }
        assert_eq!(covered, MAX_COPY_LENGTH - MIN_COPY + 1);
        assert!(intervals < 32);
    }

    #[test]
    fn all_length_screen_is_deterministic_and_observes_cancellation() {
        let input = b"abcdeabcdeabcdeabcdeabcdeabcdeabcde";
        let first = screen_all_lengths(input, 64, 64, &mut || false).unwrap();
        let second = screen_all_lengths(input, 64, 64, &mut || false).unwrap();
        assert_eq!(first, second);
        assert!(first.estimate.copy_count > 0);
        assert!(matches!(
            screen_all_lengths(input, 64, 64, &mut || true),
            Err(Error::Cancelled)
        ));
    }

    #[test]
    fn invalid_configuration_and_cancellation_return_errors() {
        assert!(matches!(
            screen(b"short input", 32, 63, &mut || false),
            Err(Error::Limit)
        ));
        assert!(matches!(
            screen(b"some input to scan", 32, 64, &mut || true),
            Err(Error::Cancelled)
        ));
    }
}
