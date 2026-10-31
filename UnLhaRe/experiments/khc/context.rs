//! 固定メモリの混合文脈による、KHC研究用のbyte列codec。
//!
//! 各byteをMSBから8 bitの二分木として符号化する。order-0は木のnode、order-1は
//! 直前byteとnodeを直接表で保持し、order-2/order-4は履歴、履歴長、nodeを固定長表へ
//! hashする。hash衝突は同じ状態を共有し、置換や追加割当は行わない。各状態は0の確率、
//! 飽和観測回数、予測誤差の1/16移動平均を持ち、確率は初期の高速学習から1/32学習へ
//! 段階的に遷移する。
//!
//! さらに直前2〜4 byteの文脈ごとに最後に続いたbyteをタグ付き表で保持する。同じbyteが
//! 続くほど0/1予測を1回あたり496/32768、混合重みを4ずつ（信頼度32まで）増し、外れた
//! 時は新しいbyte、信頼度1へ置き換える。これにより繰り返し確認された決定的な継続を
//! 最大32256/32768で予測しつつ、最初の一致や外れ直後は弱い予測に留める。
//!
//! bit確率はorder-0からorder-1、order-2、order-4へ順に混合する。各上位状態の重みは
//! `min(count, cap) * max(128-error, 0) / 8`、下位へのbackoff重みは32で、capは順に
//! 16、32、48である。役立つ上位文脈は支配的になり、未観測または1/2より悪い文脈は
//! 下位へ戻る。継続byte予測は同じbackoff重み32に対し`confidence^2`で最後に混合する。
//! すべての演算は固定幅整数だけで行う。モデルはframeごとにresetされ、encoderと
//! decoderの更新順は同一である。
//!
//! モデル使用量は[`memory_bytes`]で一定。これとは別にencoderは入力長までの候補出力、
//! decoderは指定された復元長の出力を1つ確保する。候補出力の上限到達だけを
//! [`Error::CandidateFull`]とし、割当失敗は[`Error::Limit`]とする。

use super::{Error, buffer, check, range};
use core::mem::size_of;

const ORDER1_STATES: usize = 256 * 256;
const ORDER2_STATES: usize = 1 << 17;
const ORDER4_STATES: usize = 1 << 19;
const RUN_STATES: usize = 1 << 17;
const PROBABILITY_TOTAL: u32 = 1 << 15;
const INITIAL_PROBABILITY: u16 = (PROBABILITY_TOTAL / 2) as u16;
const RUN_CONFIDENCE_LIMIT: u8 = 32;
const RUN_STRENGTH_STEP: u32 = 496;
const BACKOFF_WEIGHT: u32 = 32;

#[derive(Clone, Copy)]
#[repr(C)]
struct BitState {
    probability: u16,
    count: u8,
    error: u8,
}

impl BitState {
    const INITIAL: Self = Self {
        probability: INITIAL_PROBABILITY,
        count: 0,
        error: 128,
    };

    fn update(&mut self, bit: bool) {
        let wrong_probability = if bit {
            u32::from(self.probability)
        } else {
            PROBABILITY_TOTAL - u32::from(self.probability)
        };
        let sample = (wrong_probability >> 7) as u8;
        if sample > self.error {
            self.error += (sample - self.error).div_ceil(16);
        } else if sample < self.error {
            self.error -= (self.error - sample).div_ceil(16);
        }

        let shift = match self.count {
            0..=3 => 2,
            4..=15 => 3,
            16..=63 => 4,
            _ => 5,
        };
        if bit {
            self.probability -= self.probability >> shift;
        } else {
            self.probability += ((PROBABILITY_TOTAL as u16) - self.probability) >> shift;
        }
        self.count = self.count.saturating_add(1);
    }
}

#[derive(Clone, Copy)]
#[repr(C)]
struct RunState {
    tag: u32,
    value: u8,
    confidence: u8,
    reserved: [u8; 2],
}

impl RunState {
    const EMPTY: Self = Self {
        tag: 0,
        value: 0,
        confidence: 0,
        reserved: [0; 2],
    };
}

/// モデル本体が要求する固定byte数。候補入力・出力と`Vec`管理領域は含まない。
pub(super) const fn memory_bytes() -> usize {
    256 * size_of::<BitState>()
        + ORDER1_STATES * size_of::<BitState>()
        + ORDER2_STATES * size_of::<BitState>()
        + ORDER4_STATES * size_of::<BitState>()
        + RUN_STATES * size_of::<RunState>()
}

struct Models {
    order0: [BitState; 256],
    order1: Vec<BitState>,
    order2: Vec<BitState>,
    order4: Vec<BitState>,
    runs: Vec<RunState>,
}

impl Models {
    fn new() -> Result<Self, Error> {
        Ok(Self {
            order0: [BitState::INITIAL; 256],
            order1: buffer(ORDER1_STATES, BitState::INITIAL)?,
            order2: buffer(ORDER2_STATES, BitState::INITIAL)?,
            order4: buffer(ORDER4_STATES, BitState::INITIAL)?,
            runs: buffer(RUN_STATES, RunState::EMPTY)?,
        })
    }

    fn indices(history: u32, seen: u8, node: usize) -> (usize, usize, usize, usize) {
        let last = (history & 0xff) as usize;
        let order1 = last * 256 + node;
        let length = u32::from(seen) << 24;
        let order2_key =
            (history & 0xffff) ^ (node as u32).wrapping_mul(0x9e37_79b1) ^ length ^ 0x243f_6a88;
        let order4_key =
            history ^ (node as u32).wrapping_mul(0x85eb_ca6b) ^ length.rotate_left(7) ^ 0xb7e1_5163;
        (
            node,
            order1,
            (mix32(order2_key) as usize) & (ORDER2_STATES - 1),
            (mix32(order4_key) as usize) & (ORDER4_STATES - 1),
        )
    }

    fn probability(
        &self,
        history: u32,
        seen: u8,
        node: usize,
        run: Option<(u8, u8)>,
        shift: u32,
    ) -> u16 {
        let (order0, order1, order2, order4) = Self::indices(history, seen, node);
        let mut probability = self.order0[order0].probability;
        if seen >= 1 {
            probability = blend_state(probability, self.order1[order1], 16);
        }
        if seen >= 2 {
            probability = blend_state(probability, self.order2[order2], 32);
        }
        if seen >= 4 {
            probability = blend_state(probability, self.order4[order4], 48);
        }
        if let Some((value, confidence)) = run {
            let expected_one = value & (1 << shift) != 0;
            let confidence = confidence.min(RUN_CONFIDENCE_LIMIT);
            let strength = u32::from(confidence) * RUN_STRENGTH_STEP;
            let run_probability = if expected_one {
                u32::from(INITIAL_PROBABILITY) - strength
            } else {
                u32::from(INITIAL_PROBABILITY) + strength
            };
            let run_weight = u32::from(confidence).pow(2);
            probability = blend(
                probability,
                run_probability as u16,
                run_weight,
                BACKOFF_WEIGHT,
            );
        }
        probability.clamp(1, (PROBABILITY_TOTAL - 1) as u16)
    }

    fn update_bit(&mut self, history: u32, seen: u8, node: usize, bit: bool) {
        let (order0, order1, order2, order4) = Self::indices(history, seen, node);
        self.order0[order0].update(bit);
        if seen >= 1 {
            self.order1[order1].update(bit);
        }
        if seen >= 2 {
            self.order2[order2].update(bit);
        }
        if seen >= 4 {
            self.order4[order4].update(bit);
        }
    }

    fn run_prediction(&self, history: u32, seen: u8) -> Option<(u8, u8)> {
        let (index, tag) = run_slot(history, seen)?;
        let state = self.runs[index];
        (state.tag == tag).then_some((state.value, state.confidence))
    }

    fn update_run(&mut self, history: u32, seen: u8, value: u8) {
        let Some((index, tag)) = run_slot(history, seen) else {
            return;
        };
        let state = &mut self.runs[index];
        if state.tag != tag {
            *state = RunState {
                tag,
                value,
                confidence: 1,
                reserved: [0; 2],
            };
        } else if state.value == value {
            state.confidence = state.confidence.saturating_add(1);
        } else {
            state.value = value;
            state.confidence = 1;
        }
    }
}

fn blend_state(lower: u16, higher: BitState, count_cap: u8) -> u16 {
    let skill = u32::from(128_u8.saturating_sub(higher.error));
    let weight = u32::from(higher.count.min(count_cap)) * skill / 8;
    blend(lower, higher.probability, weight, BACKOFF_WEIGHT)
}

fn blend(lower: u16, higher: u16, higher_weight: u32, lower_weight: u32) -> u16 {
    if higher_weight == 0 {
        return lower;
    }
    let weighted =
        u64::from(lower) * u64::from(lower_weight) + u64::from(higher) * u64::from(higher_weight);
    (weighted / u64::from(lower_weight + higher_weight)) as u16
}

fn mix32(mut value: u32) -> u32 {
    value ^= value >> 16;
    value = value.wrapping_mul(0x7feb_352d);
    value ^= value >> 15;
    value = value.wrapping_mul(0x846c_a68b);
    value ^ (value >> 16)
}

fn run_slot(history: u32, seen: u8) -> Option<(usize, u32)> {
    if seen < 2 {
        return None;
    }
    let key = history ^ (u32::from(seen) << 24) ^ 0xa409_3822;
    let hash = mix32(key);
    let index = (hash as usize) & (RUN_STATES - 1);
    // 0 is the empty marker. A second mix leaves the table index independent from the tag.
    let tag = mix32(hash ^ key.rotate_left(13) ^ 0x299f_31d0) | 1;
    Some((index, tag))
}

fn encode_bit(coder: &mut range::Encoder, probability: u16, bit: bool) -> Result<(), Error> {
    coder.bit(probability, bit).map_err(|error| match error {
        "range output limit" => Error::CandidateFull,
        _ => Error::Format(error),
    })
}

fn decode_bit(coder: &mut range::Decoder<'_>, probability: u16) -> Result<bool, Error> {
    coder.bit(probability).map_err(Error::Format)
}

/// `input.len()`を上限とするheaderなしの圧縮候補を作る。
///
/// 上限へ達した候補は`CandidateFull`、モデルまたは候補の割当失敗は`Limit`となる。
pub(super) fn encode(input: &[u8], cancel: &mut impl FnMut() -> bool) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if input.len() > super::MAX_INPUT {
        return Err(Error::Limit);
    }
    let mut coder = range::Encoder::with_limit(input.len()).map_err(|error| match error {
        "range allocation failed" => Error::Limit,
        "range output limit" => Error::CandidateFull,
        _ => Error::Format(error),
    })?;
    let mut models = Models::new()?;
    let mut history = 0_u32;
    let mut seen = 0_u8;
    for (position, &value) in input.iter().enumerate() {
        if position & 4095 == 0 {
            check(cancel)?;
        }
        let run = models.run_prediction(history, seen);
        let mut node = 1_usize;
        for shift in (0..8).rev() {
            let probability = models.probability(history, seen, node, run, shift);
            let bit = value & (1 << shift) != 0;
            encode_bit(&mut coder, probability, bit)?;
            models.update_bit(history, seen, node, bit);
            node = node * 2 + usize::from(bit);
        }
        models.update_run(history, seen, value);
        history = (history << 8) | u32::from(value);
        seen = seen.saturating_add(1).min(4);
    }
    check(cancel)?;
    let output = coder.finish().map_err(|error| match error {
        "range output limit" => Error::CandidateFull,
        _ => Error::Format(error),
    })?;
    check(cancel)?;
    Ok(output)
}

/// headerなしの`payload`からちょうど`size` byteを復元する。
///
/// range streamの不足、余剰、非正準終端は`Format`として拒否する。内容checksumは親frameの
/// 責務であり、この関数単体では破損していても正準なstreamの内容までは判定しない。
pub(super) fn decode(
    payload: &[u8],
    size: usize,
    cancel: &mut impl FnMut() -> bool,
) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    if size > super::MAX_INPUT {
        return Err(Error::Limit);
    }
    if payload.len() > size {
        return Err(Error::Format("context payload exceeds output"));
    }
    let mut coder = range::Decoder::<false>::new(payload).map_err(Error::Format)?;
    let mut models = Models::new()?;
    let mut output = buffer(size, 0_u8)?;
    let mut history = 0_u32;
    let mut seen = 0_u8;
    for (position, value) in output.iter_mut().enumerate() {
        if position & 4095 == 0 {
            check(cancel)?;
        }
        let run = models.run_prediction(history, seen);
        let mut decoded = 0_u8;
        let mut node = 1_usize;
        for shift in (0..8).rev() {
            let probability = models.probability(history, seen, node, run, shift);
            let bit = decode_bit(&mut coder, probability)?;
            decoded |= u8::from(bit) << shift;
            models.update_bit(history, seen, node, bit);
            node = node * 2 + usize::from(bit);
        }
        *value = decoded;
        models.update_run(history, seen, decoded);
        history = (history << 8) | u32::from(decoded);
        seen = seen.saturating_add(1).min(4);
    }
    coder.finish().map_err(Error::Format)?;
    check(cancel)?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(input: &[u8]) -> Vec<u8> {
        let packed = encode(input, &mut || false).unwrap();
        assert!(packed.len() <= input.len());
        assert_eq!(decode(&packed, input.len(), &mut || false).unwrap(), input);
        assert_eq!(encode(input, &mut || false).unwrap(), packed);
        packed
    }

    #[test]
    fn compressible_binary_and_text_round_trip_deterministically() {
        let zeros = vec![0; 64 * 1024];
        let zero_packed = round_trip(&zeros);
        assert!(
            zero_packed.len() < zeros.len() / 20,
            "zero context payload was {} bytes",
            zero_packed.len()
        );

        let text = "KHCの混合文脈モデルは決定的に往復します。 context model round trip.\n"
            .repeat(4000)
            .into_bytes();
        let text_packed = round_trip(&text);
        assert!(
            text_packed.len() < text.len() / 2,
            "text context payload was {} of {} bytes",
            text_packed.len(),
            text.len()
        );
    }

    #[test]
    fn incompressible_and_too_short_candidates_hit_only_the_size_limit() {
        assert_eq!(encode(&[], &mut || false), Err(Error::CandidateFull));
        let mut state = 0x1234_5678_u32;
        let random: Vec<_> = (0..32768)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect();
        assert_eq!(encode(&random, &mut || false), Err(Error::CandidateFull));
    }

    #[test]
    fn truncation_and_trailing_data_are_rejected() {
        let input = b"tagged higher order context ".repeat(4000);
        let packed = round_trip(&input);
        for end in [0, 1, 4, packed.len() / 2, packed.len() - 1] {
            assert!(decode(&packed[..end], input.len(), &mut || false).is_err());
        }
        let mut trailing = packed.clone();
        trailing.push(0);
        assert!(decode(&trailing, input.len(), &mut || false).is_err());
    }

    #[test]
    fn cancellation_and_memory_bound_are_explicit() {
        assert_eq!(memory_bytes(), 3_933_184);
        assert_eq!(encode(b"cancel", &mut || true), Err(Error::Cancelled));

        let input = vec![42; 16 * 1024];
        let packed = encode(&input, &mut || false).unwrap();
        let mut calls = 0;
        assert_eq!(
            decode(&packed, input.len(), &mut || {
                calls += 1;
                calls == 3
            }),
            Err(Error::Cancelled)
        );
    }
}
