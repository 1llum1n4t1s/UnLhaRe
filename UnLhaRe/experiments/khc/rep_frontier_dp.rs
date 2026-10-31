//! Rep履歴を運ぶ、BT5 frontier限定の理想長screen。
//!
//! 各位置の状態は最良経路が運んだRep4本だけである。通常Copyは保存frontierの
//! block内clamp長まで。測定値は実frameではない。

use super::{Error, MAX_INPUT, bt, buffer, check};

const HEADER_BYTES: usize = super::HEADER;
const MIN_MATCH: usize = 4;
const MIN_REP: usize = 2;
const CLASS_CONTEXTS: usize = 8;
const LENGTH_SLOTS: usize = 16;
const DISTANCE_SLOTS: usize = usize::BITS as usize;
const LITERAL_CONTEXTS: usize = 33;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Literal = 0,
    Short = 1,
    Rep = 2,
    Match = 3,
}

#[derive(Clone, Copy)]
struct Token {
    offset: usize,
    length: usize,
    distance: usize,
    kind: Kind,
    rep_index: u8,
}

#[derive(Clone, Copy)]
struct Arrive {
    cost: f64,
    prev: u32,
    length: u32,
    distance: u32,
    reps: [u32; 4],
    kind: u8,
    rep_index: u8,
    prev_copy: u8,
}

pub(crate) struct Estimate {
    pub shannon_ideal_bits: f64,
    pub raw_extra_bits: u64,
    pub estimate_bytes: usize,
    pub greedy_estimate_bytes: usize,
    pub token_count: usize,
    pub literal_count: usize,
    pub short_count: usize,
    pub rep_count: usize,
    pub match_count: usize,
    pub field_bits: [f64; 5],
}

struct Prices {
    class: [[f64; 4]; CLASS_CONTEXTS],
    rep_index: [[f64; 4]; CLASS_CONTEXTS],
    literal: [[f64; 256]; LITERAL_CONTEXTS],
    length: [[f64; LENGTH_SLOTS]; 8],
    distance: [[f64; DISTANCE_SLOTS]; 4],
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
    verify(input, dictionary, block, &greedy)?;
    let prices = Prices::learn(input, &greedy);
    let selected = parse(input, dictionary, block, Some(&prices), cancel)?;
    verify(input, dictionary, block, &selected)?;
    let greedy_estimate = measure(input, &greedy).estimate_bytes;
    let mut estimate = measure(input, &selected);
    estimate.greedy_estimate_bytes = greedy_estimate;
    Ok(estimate)
}

fn parse(
    input: &[u8],
    dictionary: usize,
    block: usize,
    prices: Option<&Prices>,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<Token>, Error> {
    if input.is_empty() {
        return Ok(Vec::new());
    }
    let mut matcher = bt::Matcher::new(input.len(), 5)?;
    matcher.set_nice_len(0)?;
    let mut snapshot = bt::Block::new(block)?;
    let mut arrive = buffer(
        input.len() + 1,
        Arrive {
            cost: f64::INFINITY,
            prev: u32::MAX,
            length: 0,
            distance: 0,
            reps: [1; 4],
            kind: 0,
            rep_index: 0,
            prev_copy: 0,
        },
    )?;
    arrive[0].cost = 0.0;
    let mut greedy_tokens = Vec::new();
    let mut start = 0usize;
    while start < input.len() {
        check(cancel)?;
        let end = start.saturating_add(block).min(input.len());
        matcher.prepare_start(&mut snapshot, input, start, end, dictionary, cancel)?;
        matcher.prepare_rest(&mut snapshot, input, start, end, dictionary, cancel)?;
        if prices.is_none() {
            let mut pos = start;
            while pos < end {
                if pos & 0xffff == 0 {
                    check(cancel)?;
                }
                let state = arrive[pos];
                if !state.cost.is_finite() {
                    return Err(Error::Format("greedy rep path lost its carried state"));
                }
                let token = greedy_token(
                    input,
                    dictionary,
                    &snapshot,
                    pos - start,
                    pos,
                    end - pos,
                    &state,
                );
                let dest = pos + token.length;
                if dest > end {
                    return Err(Error::Format("greedy rep token crossed the block"));
                }
                let mut next = next_arrive(&state, pos, token);
                next.cost = 0.0;
                arrive[dest] = next;
                greedy_tokens.push(token);
                pos = dest;
            }
            start = end;
            continue;
        }
        let prices = prices.unwrap();
        for local in 0..end - start {
            if local & 0xffff == 0 {
                check(cancel)?;
            }
            let pos = start + local;
            let state = arrive[pos];
            if !state.cost.is_finite() {
                return Err(Error::Format("rep frontier DP left a position unreachable"));
            }
            let room = end - pos;
            relax_literal(&mut arrive, input, prices, &state, pos)?;
            relax_reps(&mut arrive, input, dictionary, prices, &state, pos, room)?;
            relax_matches(
                &mut arrive,
                prices,
                &snapshot,
                local,
                &state,
                pos,
                room,
                dictionary,
            )?;
        }
        start = end;
    }
    if prices.is_none() {
        return Ok(greedy_tokens);
    }
    traceback(input.len(), &arrive)
}

fn greedy_token(
    input: &[u8],
    dictionary: usize,
    snapshot: &bt::Block,
    local: usize,
    pos: usize,
    room: usize,
    state: &Arrive,
) -> Token {
    let mut best_len = 0usize;
    let mut best_rep = None;
    for index in 0..4 {
        let distance = state.reps[index] as usize;
        let length = matched_length(input, pos, distance, room.min(dictionary), dictionary);
        if length >= MIN_REP && length > best_len {
            best_len = length;
            best_rep = Some(index);
        }
    }
    let mut best_match: Option<(usize, usize)> = None;
    for candidate in snapshot.candidates_local(local) {
        let distance = candidate.distance();
        let length = candidate.length().min(room);
        if length >= MIN_MATCH
            && length > best_len
            && distance > 0
            && distance <= pos
            && distance <= dictionary
        {
            best_len = length;
            best_rep = None;
            best_match = Some((distance, length));
        }
    }
    if let Some(index) = best_rep {
        return Token {
            offset: pos,
            length: best_len,
            distance: state.reps[index] as usize,
            kind: Kind::Rep,
            rep_index: index as u8,
        };
    }
    if let Some((distance, length)) = best_match {
        return Token {
            offset: pos,
            length,
            distance,
            kind: Kind::Match,
            rep_index: 0,
        };
    }
    if matched_length(input, pos, state.reps[0] as usize, 1, dictionary) == 1 {
        return Token {
            offset: pos,
            length: 1,
            distance: state.reps[0] as usize,
            kind: Kind::Short,
            rep_index: 0,
        };
    }
    Token {
        offset: pos,
        length: 1,
        distance: 0,
        kind: Kind::Literal,
        rep_index: 0,
    }
}

fn relax_literal(
    arrive: &mut [Arrive],
    input: &[u8],
    prices: &Prices,
    state: &Arrive,
    pos: usize,
) -> Result<(), Error> {
    let context = class_context(state.prev_copy != 0, pos);
    offer(
        arrive,
        pos + 1,
        state,
        Token {
            offset: pos,
            length: 1,
            distance: 0,
            kind: Kind::Literal,
            rep_index: 0,
        },
        state.cost
            + prices.class[context][Kind::Literal as usize]
            + prices.literal[literal_context(input, pos)][usize::from(input[pos])],
    )
}

fn relax_reps(
    arrive: &mut [Arrive],
    input: &[u8],
    dictionary: usize,
    prices: &Prices,
    state: &Arrive,
    pos: usize,
    room: usize,
) -> Result<(), Error> {
    let context = class_context(state.prev_copy != 0, pos);
    if matched_length(input, pos, state.reps[0] as usize, 1, dictionary) == 1 {
        offer(
            arrive,
            pos + 1,
            state,
            Token {
                offset: pos,
                length: 1,
                distance: state.reps[0] as usize,
                kind: Kind::Short,
                rep_index: 0,
            },
            state.cost + prices.class[context][Kind::Short as usize],
        )?;
    }
    for index in 0..4 {
        let distance = state.reps[index] as usize;
        let max_length = matched_length(input, pos, distance, room, dictionary);
        if max_length < MIN_REP {
            continue;
        }
        let mut length = MIN_REP;
        while length <= max_length {
            let last = interval_last(length, max_length);
            let cost = state.cost
                + prices.class[context][Kind::Rep as usize]
                + prices.rep_index[context][index]
                + prices.length[length_context(pos, false)][length_slot(last)]
                + raw_length_bits(last) as f64;
            if cost.is_finite() {
                offer(
                    arrive,
                    pos + last,
                    state,
                    Token {
                        offset: pos,
                        length: last,
                        distance,
                        kind: Kind::Rep,
                        rep_index: index as u8,
                    },
                    cost,
                )?;
            }
            length = last + 1;
        }
    }
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn relax_matches(
    arrive: &mut [Arrive],
    prices: &Prices,
    snapshot: &bt::Block,
    local: usize,
    state: &Arrive,
    pos: usize,
    room: usize,
    dictionary: usize,
) -> Result<(), Error> {
    let context = class_context(state.prev_copy != 0, pos);
    for candidate in snapshot.candidates_local(local) {
        let distance = candidate.distance();
        let max_length = candidate.length().min(room);
        if max_length < MIN_MATCH || distance == 0 || distance > pos || distance > dictionary {
            continue;
        }
        let mut length = MIN_MATCH;
        while length <= max_length {
            let last = interval_last(length, max_length);
            let slot = distance_slot(distance);
            let cost = state.cost
                + prices.class[context][Kind::Match as usize]
                + prices.length[length_context(pos, true)][length_slot(last)]
                + raw_length_bits(last) as f64
                + prices.distance[length_bucket(last)][slot]
                + raw_distance_bits(distance) as f64;
            if cost.is_finite() {
                offer(
                    arrive,
                    pos + last,
                    state,
                    Token {
                        offset: pos,
                        length: last,
                        distance,
                        kind: Kind::Match,
                        rep_index: 0,
                    },
                    cost,
                )?;
            }
            length = last + 1;
        }
    }
    Ok(())
}

fn offer(
    arrive: &mut [Arrive],
    dest: usize,
    state: &Arrive,
    token: Token,
    cost: f64,
) -> Result<(), Error> {
    if dest >= arrive.len() || !cost.is_finite() {
        return Err(Error::Format("rep frontier edge leaves the input"));
    }
    if cost < arrive[dest].cost {
        arrive[dest] = next_arrive(state, token.offset, token);
        arrive[dest].cost = cost;
        arrive[dest].prev = u32::try_from(token.offset).map_err(|_| Error::Limit)?;
    }
    Ok(())
}

fn next_arrive(state: &Arrive, pos: usize, token: Token) -> Arrive {
    let mut reps = state.reps;
    match token.kind {
        Kind::Rep => {
            let chosen = reps[usize::from(token.rep_index)];
            reps.copy_within(0..usize::from(token.rep_index), 1);
            reps[0] = chosen;
        }
        Kind::Match => {
            reps.copy_within(0..3, 1);
            reps[0] = token.distance as u32;
        }
        Kind::Literal | Kind::Short => {}
    }
    Arrive {
        cost: 0.0,
        prev: u32::try_from(pos).unwrap_or(u32::MAX),
        length: token.length as u32,
        distance: token.distance as u32,
        reps,
        kind: token.kind as u8,
        rep_index: token.rep_index,
        prev_copy: u8::from(token.kind != Kind::Literal),
    }
}

fn traceback(end: usize, arrive: &[Arrive]) -> Result<Vec<Token>, Error> {
    let mut reversed = Vec::new();
    let mut pos = end;
    while pos > 0 {
        let link = arrive[pos];
        let prev = link.prev as usize;
        let length = link.length as usize;
        if prev >= pos || prev + length != pos || length == 0 {
            return Err(Error::Format("rep frontier traceback is not contiguous"));
        }
        reversed.push(Token {
            offset: prev,
            length,
            distance: link.distance as usize,
            kind: match link.kind {
                1 => Kind::Short,
                2 => Kind::Rep,
                3 => Kind::Match,
                _ => Kind::Literal,
            },
            rep_index: link.rep_index,
        });
        pos = prev;
    }
    reversed.reverse();
    Ok(reversed)
}

fn verify(input: &[u8], dictionary: usize, block: usize, tokens: &[Token]) -> Result<(), Error> {
    let mut reps = [1u32; 4];
    let mut pos = 0usize;
    for token in tokens {
        if token.offset != pos
            || token.length == 0
            || pos / block != (pos + token.length - 1) / block
        {
            return Err(Error::Format(
                "rep frontier token leaves its block or breaks contiguity",
            ));
        }
        match token.kind {
            Kind::Literal => {
                if token.length != 1 {
                    return Err(Error::Format("rep frontier literal is not one byte"));
                }
            }
            Kind::Short => {
                if token.length != 1 || token.distance != reps[0] as usize {
                    return Err(Error::Format("short rep does not use rep0"));
                }
                replay(input, pos, token.distance, 1)?;
            }
            Kind::Rep => {
                let index = usize::from(token.rep_index);
                if index > 3 || token.length < MIN_REP || token.distance != reps[index] as usize {
                    return Err(Error::Format("rep token does not match carried history"));
                }
                replay(input, pos, token.distance, token.length)?;
                let chosen = reps[index];
                reps.copy_within(0..index, 1);
                reps[0] = chosen;
            }
            Kind::Match => {
                if token.length < MIN_MATCH
                    || token.distance == 0
                    || token.distance > dictionary
                    || token.distance > pos
                {
                    return Err(Error::Format(
                        "absolute match is outside the frontier rules",
                    ));
                }
                replay(input, pos, token.distance, token.length)?;
                reps.copy_within(0..3, 1);
                reps[0] = token.distance as u32;
            }
        }
        if token.kind != Kind::Rep && token.kind != Kind::Match {
            // ShortRep keeps the rep list. Literal keeps it too.
        }
        if token.distance > dictionary {
            return Err(Error::Format("copy distance exceeds the dictionary"));
        }
        pos += token.length;
    }
    if pos != input.len() {
        return Err(Error::Format("rep frontier tokens do not cover the input"));
    }
    Ok(())
}

fn replay(input: &[u8], pos: usize, distance: usize, length: usize) -> Result<(), Error> {
    if distance == 0 || distance > pos || pos + length > input.len() {
        return Err(Error::Format("copy is outside the input"));
    }
    if input[pos..pos + length] != input[pos - distance..pos - distance + length] {
        return Err(Error::Format("copy does not replay the input"));
    }
    Ok(())
}

fn matched_length(
    input: &[u8],
    pos: usize,
    distance: usize,
    limit: usize,
    dictionary: usize,
) -> usize {
    if distance == 0 || distance > pos || distance > dictionary || limit == 0 {
        return 0;
    }
    let limit = limit.min(input.len() - pos);
    let mut length = 0usize;
    while length < limit && input[pos - distance + length] == input[pos + length] {
        length += 1;
    }
    length
}

fn interval_last(length: usize, max_length: usize) -> usize {
    let slot = length_slot(length);
    let slot_last = if slot == 0 {
        3
    } else {
        (1usize << (slot + 1)) + 1
    };
    let bucket_last = match length_bucket(length) {
        0 => 4,
        1 => 8,
        2 => 16,
        _ => usize::MAX,
    };
    slot_last.min(bucket_last).min(max_length)
}

impl Prices {
    fn learn(input: &[u8], tokens: &[Token]) -> Self {
        let mut class = [[0u64; 4]; CLASS_CONTEXTS];
        let mut rep_index = [[0u64; 4]; CLASS_CONTEXTS];
        let mut literal = [[0u64; 256]; LITERAL_CONTEXTS];
        let mut length = [[0u64; LENGTH_SLOTS]; 8];
        let mut distance = [[0u64; DISTANCE_SLOTS]; 4];
        let mut prev_copy = false;
        for token in tokens {
            let context = class_context(prev_copy, token.offset);
            class[context][token.kind as usize] += 1;
            match token.kind {
                Kind::Literal => {
                    literal[literal_context(input, token.offset)]
                        [usize::from(input[token.offset])] += 1;
                }
                Kind::Short => {}
                Kind::Rep => {
                    rep_index[context][usize::from(token.rep_index)] += 1;
                    length[length_context(token.offset, false)][length_slot(token.length)] += 1;
                }
                Kind::Match => {
                    length[length_context(token.offset, true)][length_slot(token.length)] += 1;
                    distance[length_bucket(token.length)][distance_slot(token.distance)] += 1;
                }
            }
            prev_copy = token.kind != Kind::Literal;
        }
        let class_price = std::array::from_fn(|context| {
            let total = class[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| laplace(class[context][symbol], total, 4))
        });
        let rep_price = std::array::from_fn(|context| {
            let total = rep_index[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| laplace(rep_index[context][symbol], total, 4))
        });
        let literal_price = std::array::from_fn(|context| {
            let total = literal[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| laplace(literal[context][symbol], total, 256))
        });
        let length_price = std::array::from_fn(|context| {
            let total = length[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| {
                laplace(length[context][symbol], total, LENGTH_SLOTS as u64)
            })
        });
        let distance_price = std::array::from_fn(|context| {
            let total = distance[context].iter().sum::<u64>();
            std::array::from_fn(|symbol| {
                laplace(distance[context][symbol], total, DISTANCE_SLOTS as u64)
            })
        });
        Self {
            class: class_price,
            rep_index: rep_price,
            literal: literal_price,
            length: length_price,
            distance: distance_price,
        }
    }
}

fn measure(input: &[u8], tokens: &[Token]) -> Estimate {
    let mut class = [[0u64; 4]; CLASS_CONTEXTS];
    let mut rep_index = [[0u64; 4]; CLASS_CONTEXTS];
    let mut literal = [[0u64; 256]; LITERAL_CONTEXTS];
    let mut length = [[0u64; LENGTH_SLOTS]; 8];
    let mut distance = [[0u64; DISTANCE_SLOTS]; 4];
    let mut raw_extra_bits = 0u64;
    let mut counts = [0usize; 4];
    let mut prev_copy = false;
    for token in tokens {
        let context = class_context(prev_copy, token.offset);
        class[context][token.kind as usize] += 1;
        counts[token.kind as usize] += 1;
        match token.kind {
            Kind::Literal => {
                literal[literal_context(input, token.offset)][usize::from(input[token.offset])] +=
                    1;
            }
            Kind::Short => {}
            Kind::Rep => {
                rep_index[context][usize::from(token.rep_index)] += 1;
                length[length_context(token.offset, false)][length_slot(token.length)] += 1;
                raw_extra_bits += raw_length_bits(token.length);
            }
            Kind::Match => {
                length[length_context(token.offset, true)][length_slot(token.length)] += 1;
                distance[length_bucket(token.length)][distance_slot(token.distance)] += 1;
                raw_extra_bits += raw_length_bits(token.length) + raw_distance_bits(token.distance);
            }
        }
        prev_copy = token.kind != Kind::Literal;
    }
    let mut field_bits = [0.0; 5];
    field_bits[0] = class.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[1] = rep_index.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[2] = literal.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[3] = length.iter().map(|histogram| shannon(histogram)).sum();
    field_bits[4] = distance.iter().map(|histogram| shannon(histogram)).sum();
    let shannon_ideal_bits = field_bits.iter().sum::<f64>();
    let payload = ((shannon_ideal_bits + raw_extra_bits as f64) / 8.0).ceil() as usize;
    Estimate {
        shannon_ideal_bits,
        raw_extra_bits,
        estimate_bytes: payload + HEADER_BYTES,
        greedy_estimate_bytes: 0,
        token_count: tokens.len(),
        literal_count: counts[0],
        short_count: counts[1],
        rep_count: counts[2],
        match_count: counts[3],
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

fn laplace(count: u64, total: u64, alphabet: u64) -> f64 {
    ((total + alphabet) as f64 / (count + 1) as f64).log2()
}

fn class_context(prev_copy: bool, pos: usize) -> usize {
    usize::from(prev_copy) * 4 + (pos & 3)
}

fn length_context(pos: usize, is_match: bool) -> usize {
    (pos & 3) * 2 + usize::from(is_match)
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

fn length_slot(length: usize) -> usize {
    length.saturating_sub(2).max(1).ilog2() as usize
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
