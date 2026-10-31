const MAX_SIZE: usize = 64 * 1024 * 1024;
const PROBABILITY_TOTAL: u64 = 1 << 15;
const NORMALIZE_THRESHOLD: u64 = 1 << 24;
const INITIAL_PROBABILITY: u64 = PROBABILITY_TOTAL / 2;
const TOKEN_CONTEXTS: usize = 8;
const LITERAL_CONTEXTS: usize = 8;
const LITERAL_MODEL_SIZE: usize = 768;

pub(super) fn decode(
    payload: &[u8],
    output_size: usize,
    dictionary: usize,
) -> Result<Vec<u8>, &'static str> {
    if output_size > MAX_SIZE {
        return Err("output size exceeds the mode 2 limit");
    }
    if !(1..=MAX_SIZE).contains(&dictionary) {
        return Err("dictionary size is outside the mode 2 limits");
    }
    if payload.len() > output_size {
        return Err("payload is larger than the decoded output");
    }

    let mut output = Vec::new();
    output
        .try_reserve_exact(output_size)
        .map_err(|_| "failed to reserve the decoded output")?;

    let mut decoder = ScalarRangeDecoder::new(payload)?;
    let mut models = TokenModels::new();
    let mut state = TokenState::new();

    while output.len() < output_size {
        let token_context = state.context(output.len());
        if decoder.bit(&mut models.is_match[token_context])? == 0 {
            let byte = decode_literal(
                &mut decoder,
                &mut models.literal,
                &output,
                state.repetitions[0],
            )?;
            output.push(byte);
            state.previous_was_match = false;
            continue;
        }

        let (distance, length, selected_rep) =
            if decoder.bit(&mut models.is_rep[token_context])? == 0 {
                let remaining = output_size - output.len();
                let length = decode_length(
                    &mut decoder,
                    &mut models.normal_length[token_context],
                    3,
                    remaining.min(65_536),
                )?;
                let distance_limit = dictionary.min(output.len());
                let distance_context = length_context(length);
                let distance = decode_number(
                    &mut decoder,
                    &mut models.distance[distance_context],
                    distance_limit,
                )?;
                (distance, length, None)
            } else {
                decode_repetition(
                    &mut decoder,
                    &mut models,
                    &state,
                    token_context,
                    output_size - output.len(),
                    dictionary,
                    output.len(),
                )?
            };

        copy_match(&mut output, output_size, dictionary, distance, length)?;
        match selected_rep {
            None => state.insert_distance(distance),
            Some(index) if length >= 2 => state.promote_distance(index),
            Some(_) => {}
        }
        state.previous_was_match = true;
    }

    if decoder.consumed() != payload.len() {
        return Err("range payload has trailing bytes");
    }
    if decoder.code() != 0 {
        return Err("range decoder did not finish at code zero");
    }
    Ok(output)
}

fn decode_literal(
    decoder: &mut ScalarRangeDecoder<'_>,
    probabilities: &mut [u64; LITERAL_CONTEXTS * LITERAL_MODEL_SIZE],
    output: &[u8],
    rep0: usize,
) -> Result<u8, &'static str> {
    let previous = output.last().copied().unwrap_or(0);
    let context_base = usize::from(previous >> 5) * LITERAL_MODEL_SIZE;
    let prediction = rep0
        .checked_sub(1)
        .and_then(|offset| output.len().checked_sub(offset + 1))
        .map(|position| output[position]);

    let mut symbol = 1usize;
    let mut prediction_matches = prediction.is_some();
    for depth in 0..8 {
        let predicted_bit = prediction.map_or(0, |byte| (byte >> (7 - depth)) & 1);
        let model_offset = if prediction_matches {
            256 * (1 + usize::from(predicted_bit))
        } else {
            0
        };
        let bit = decoder.bit(&mut probabilities[context_base + model_offset + symbol])?;
        if prediction_matches && bit != predicted_bit {
            prediction_matches = false;
        }
        symbol = (symbol << 1) | usize::from(bit);
    }

    Ok((symbol - 256) as u8)
}

fn decode_repetition(
    decoder: &mut ScalarRangeDecoder<'_>,
    models: &mut TokenModels,
    state: &TokenState,
    token_context: usize,
    remaining: usize,
    dictionary: usize,
    produced: usize,
) -> Result<(usize, usize, Option<usize>), &'static str> {
    let rep_index = if decoder.bit(&mut models.is_rep0[token_context])? != 0 {
        if decoder.bit(&mut models.is_short_rep[token_context])? != 0 {
            let distance = state.repetitions[0];
            validate_distance(distance, dictionary, produced)?;
            return Ok((distance, 1, Some(0)));
        }
        0
    } else if decoder.bit(&mut models.is_rep1[token_context])? != 0 {
        1
    } else if decoder.bit(&mut models.is_rep2[token_context])? != 0 {
        2
    } else {
        3
    };

    let length = decode_length(
        decoder,
        &mut models.repetition_length[token_context],
        2,
        remaining.min(65_536),
    )?;
    let distance = state.repetitions[rep_index];
    validate_distance(distance, dictionary, produced)?;
    Ok((distance, length, Some(rep_index)))
}

fn decode_length(
    decoder: &mut ScalarRangeDecoder<'_>,
    model: &mut LengthModel,
    minimum: usize,
    maximum: usize,
) -> Result<usize, &'static str> {
    if maximum < minimum {
        return Err("match length exceeds the remaining output");
    }
    let maximum_value = maximum - minimum;

    let value = if decoder.bit(&mut model.first)? == 0 {
        let value = decode_three_bit_tree(decoder, &mut model.low)?;
        if value > maximum_value {
            return Err("match length exceeds its semantic limit");
        }
        value
    } else if decoder.bit(&mut model.second)? == 0 {
        let value = 8 + decode_three_bit_tree(decoder, &mut model.middle)?;
        if value > maximum_value {
            return Err("match length exceeds its semantic limit");
        }
        value
    } else {
        if maximum_value < 16 {
            return Err("match length category exceeds its semantic limit");
        }
        15 + decode_number(decoder, &mut model.large, maximum_value - 15)?
    };

    minimum
        .checked_add(value)
        .ok_or("decoded match length overflowed")
}

fn decode_three_bit_tree(
    decoder: &mut ScalarRangeDecoder<'_>,
    probabilities: &mut [u64; 8],
) -> Result<usize, &'static str> {
    decode_tree(decoder, probabilities, 3)
}

fn decode_number(
    decoder: &mut ScalarRangeDecoder<'_>,
    model: &mut NumberModel,
    maximum: usize,
) -> Result<usize, &'static str> {
    if maximum == 0 {
        return Err("positive number has a zero semantic limit");
    }

    let slot = decode_tree(decoder, &mut model.probabilities, 5)?;
    let maximum_slot = (usize::BITS - 1 - maximum.leading_zeros()) as usize;
    if slot > maximum_slot {
        return Err("number slot exceeds its semantic limit");
    }

    let mut value = 1usize << slot;
    for bit_position in (0..slot).rev() {
        let bit = decoder.bit(&mut model.probabilities[32 + bit_position])?;
        value |= usize::from(bit) << bit_position;
    }
    if value > maximum {
        return Err("number exceeds its semantic limit");
    }
    Ok(value)
}

fn decode_tree(
    decoder: &mut ScalarRangeDecoder<'_>,
    probabilities: &mut [u64],
    bits: usize,
) -> Result<usize, &'static str> {
    let mut symbol = 1usize;
    for _ in 0..bits {
        let bit = decoder.bit(&mut probabilities[symbol])?;
        symbol = (symbol << 1) | usize::from(bit);
    }
    Ok(symbol - (1 << bits))
}

fn copy_match(
    output: &mut Vec<u8>,
    output_size: usize,
    dictionary: usize,
    distance: usize,
    length: usize,
) -> Result<(), &'static str> {
    validate_distance(distance, dictionary, output.len())?;
    if !(1..=65_536).contains(&length) || length > output_size - output.len() {
        return Err("match length is outside the allowed output");
    }

    for _ in 0..length {
        let source = output.len() - distance;
        output.push(output[source]);
    }
    Ok(())
}

fn validate_distance(
    distance: usize,
    dictionary: usize,
    produced: usize,
) -> Result<(), &'static str> {
    if distance == 0 || distance > dictionary || distance > produced {
        return Err("match distance is outside the available dictionary");
    }
    Ok(())
}

fn length_context(length: usize) -> usize {
    match length {
        0..=4 => 0,
        5..=8 => 1,
        9..=16 => 2,
        _ => 3,
    }
}

struct ScalarRangeDecoder<'a> {
    payload: &'a [u8],
    position: usize,
    range: u64,
    code: u64,
}

impl<'a> ScalarRangeDecoder<'a> {
    fn new(payload: &'a [u8]) -> Result<Self, &'static str> {
        if payload.len() < 5 {
            return Err("range payload is shorter than its prefix");
        }
        if payload[0] != 0 {
            return Err("range payload does not start with zero");
        }

        let code = payload[1..5]
            .iter()
            .fold(0u64, |value, &byte| (value << 8) | u64::from(byte));
        Ok(Self {
            payload,
            position: 5,
            range: u64::from(u32::MAX),
            code,
        })
    }

    fn bit(&mut self, probability: &mut u64) -> Result<u8, &'static str> {
        let split = (self.range >> 15) * *probability;
        let bit = if self.code < split {
            self.range = split;
            *probability += (PROBABILITY_TOTAL - *probability) >> 5;
            0
        } else {
            self.code -= split;
            self.range -= split;
            *probability -= *probability >> 5;
            1
        };

        while self.range < NORMALIZE_THRESHOLD {
            let byte = self
                .payload
                .get(self.position)
                .copied()
                .ok_or("range payload ended during normalization")?;
            self.position += 1;
            self.range <<= 8;
            self.code = (self.code << 8) | u64::from(byte);
        }
        Ok(bit)
    }

    fn consumed(&self) -> usize {
        self.position
    }

    fn code(&self) -> u64 {
        self.code
    }
}

#[derive(Clone, Copy)]
struct NumberModel {
    probabilities: [u64; 64],
}

impl NumberModel {
    const fn new() -> Self {
        Self {
            probabilities: [INITIAL_PROBABILITY; 64],
        }
    }
}

#[derive(Clone, Copy)]
struct LengthModel {
    first: u64,
    second: u64,
    low: [u64; 8],
    middle: [u64; 8],
    large: NumberModel,
}

impl LengthModel {
    const fn new() -> Self {
        Self {
            first: INITIAL_PROBABILITY,
            second: INITIAL_PROBABILITY,
            low: [INITIAL_PROBABILITY; 8],
            middle: [INITIAL_PROBABILITY; 8],
            large: NumberModel::new(),
        }
    }
}

struct TokenModels {
    is_match: [u64; TOKEN_CONTEXTS],
    is_rep: [u64; TOKEN_CONTEXTS],
    is_rep0: [u64; TOKEN_CONTEXTS],
    is_short_rep: [u64; TOKEN_CONTEXTS],
    is_rep1: [u64; TOKEN_CONTEXTS],
    is_rep2: [u64; TOKEN_CONTEXTS],
    literal: [u64; LITERAL_CONTEXTS * LITERAL_MODEL_SIZE],
    normal_length: [LengthModel; TOKEN_CONTEXTS],
    repetition_length: [LengthModel; TOKEN_CONTEXTS],
    distance: [NumberModel; 4],
}

impl TokenModels {
    fn new() -> Self {
        Self {
            is_match: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            is_rep: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            is_rep0: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            is_short_rep: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            is_rep1: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            is_rep2: [INITIAL_PROBABILITY; TOKEN_CONTEXTS],
            literal: [INITIAL_PROBABILITY; LITERAL_CONTEXTS * LITERAL_MODEL_SIZE],
            normal_length: [LengthModel::new(); TOKEN_CONTEXTS],
            repetition_length: [LengthModel::new(); TOKEN_CONTEXTS],
            distance: [NumberModel::new(); 4],
        }
    }
}

struct TokenState {
    previous_was_match: bool,
    repetitions: [usize; 4],
}

impl TokenState {
    fn new() -> Self {
        Self {
            previous_was_match: false,
            repetitions: [1; 4],
        }
    }

    fn context(&self, output_position: usize) -> usize {
        4 * usize::from(self.previous_was_match) + (output_position & 3)
    }

    fn insert_distance(&mut self, distance: usize) {
        self.repetitions.copy_within(0..3, 1);
        self.repetitions[0] = distance;
    }

    fn promote_distance(&mut self, index: usize) {
        let distance = self.repetitions[index];
        self.repetitions.copy_within(0..index, 1);
        self.repetitions[0] = distance;
    }
}
