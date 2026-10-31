//! 研究example専用の区間計測。区間は入れ子を含むinclusive時間で、合計は加算できない。
//! 有効時は計測自体の負担を含む。通常の性能比較は無効状態で行う。

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

#[derive(Clone, Copy)]
#[repr(usize)]
pub(crate) enum Phase {
    Encode,
    Index,
    BeamPlan,
    WarmModel,
    FindMatches,
    ExpandNodes,
    RepLength,
    ExpandRepLength,
    EmitTokens,
}

const NAMES: [&str; 9] = [
    "encode",
    "index",
    "beam_plan",
    "warm_model",
    "find_matches",
    "expand_nodes",
    "rep_length",
    "expand_rep_length",
    "emit_tokens",
];
const REP_LENGTH_SAMPLE_STRIDE: usize = 256;
const DEFAULT_EXPAND_REP_SAMPLE_STRIDE: usize = 16;

#[derive(Clone, Copy, Default)]
struct Measurement {
    calls: u64,
    nanos: u128,
}

#[derive(Clone, Copy, Default)]
struct PricePrediction {
    blocks: u64,
    bytes: u128,
    tokens: u128,
    frozen_cost: u128,
    adaptive_cost: u128,
    adaptive_minus_frozen: i128,
    absolute_error: u128,
    max_absolute_block_gap: u64,
    max_absolute_block_gap_input_offset: usize,
    adaptive_over_frozen_blocks: u64,
    adaptive_under_frozen_blocks: u64,
    adaptive_equal_frozen_blocks: u64,
    ranked_blocks: u64,
    terminal_candidates: u128,
    rank_reversals: u64,
    rank_saving: u128,
    max_rank_saving: u64,
    max_rank_saving_offset: usize,
}

#[derive(Clone, Copy, Default)]
struct BeamCompetition {
    blocks: u64,
    input_bytes: u128,
    path_tokens: u128,
    nonfirst_parent_tokens: u128,
    nonfirst_parent_bytes: u128,
    strict_parent_tokens: u128,
    strict_parent_bytes: u128,
    strict_parent_gap: u128,
    max_strict_parent_gap: u64,
    max_strict_parent_gap_input_offset: usize,
    nonfirst_literal_tokens: u128,
    nonfirst_short_rep_tokens: u128,
    nonfirst_rep_tokens: u128,
    nonfirst_match_tokens: u128,
    blocks_with_nonfirst_parent: u64,
    sequence_starts: u64,
    previous_had_nonfirst_parent: Option<bool>,
    previous_false_current_false: u64,
    previous_false_current_true: u64,
    previous_true_current_false: u64,
    previous_true_current_true: u64,
    terminal_multi_candidate_blocks: u64,
    terminal_second_best_gap: u128,
    max_terminal_second_best_gap: u64,
    max_terminal_second_best_gap_input_offset: usize,
    bypass_blocks: u64,
    bypass_bytes: u128,
}

#[derive(Clone, Copy, Default)]
struct GreedySkipGate {
    qualified_positions: u128,
    potential_bytes: u128,
    covered_bytes: u128,
}

#[derive(Clone, Copy, Default)]
struct GreedySkipScreen {
    input_bytes: u128,
    two_parent_positions: u128,
    margin_ge_512_positions: u128,
    margin_ge_128_positions: u128,
    gates: [GreedySkipGate; 6],
}

#[derive(Clone, Copy, Default)]
struct RepStateCensus {
    blocks: u64,
    active_nodes: u128,
    unique_rep_tuples: u128,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct GreedySkipGateBlock {
    pub(crate) qualified_positions: usize,
    pub(crate) potential_bytes: usize,
    pub(crate) covered_bytes: usize,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct GreedySkipBlock {
    pub(crate) input_bytes: usize,
    pub(crate) two_parent_positions: usize,
    pub(crate) margin_ge_512_positions: usize,
    pub(crate) margin_ge_128_positions: usize,
    pub(crate) gates: [GreedySkipGateBlock; 6],
}

#[derive(Clone, Copy, Default)]
pub(crate) struct BeamCompetitionBlock {
    pub(crate) input_bytes: usize,
    pub(crate) path_tokens: usize,
    pub(crate) nonfirst_parent_tokens: usize,
    pub(crate) nonfirst_parent_bytes: usize,
    pub(crate) strict_parent_tokens: usize,
    pub(crate) strict_parent_bytes: usize,
    pub(crate) strict_parent_gap: u128,
    pub(crate) max_strict_parent_gap: u64,
    pub(crate) nonfirst_literal_tokens: usize,
    pub(crate) nonfirst_short_rep_tokens: usize,
    pub(crate) nonfirst_rep_tokens: usize,
    pub(crate) nonfirst_match_tokens: usize,
    pub(crate) terminal_second_best_gap: Option<u64>,
}

struct State {
    generation: u64,
    measurements: Option<[Measurement; 9]>,
    diagnostics_enabled: bool,
    expand_depth: usize,
    price_prediction: Option<PricePrediction>,
    beam_competition: Option<BeamCompetition>,
    active_width2_blocks: Option<u64>,
    greedy_skip_screen: Option<GreedySkipScreen>,
    rep_state_census: Option<RepStateCensus>,
}

thread_local! {
    static STATE: RefCell<State> = const { RefCell::new(State {
        generation: 0,
        measurements: None,
        diagnostics_enabled: false,
        expand_depth: 0,
        price_prediction: None,
        beam_competition: None,
        active_width2_blocks: None,
        greedy_skip_screen: None,
        rep_state_census: None,
    }) };
    static EXPAND_REP_SAMPLE_OFFSET: Cell<usize> = const { Cell::new(0) };
    static EXPAND_REP_SAMPLE_STRIDE: Cell<usize> = const { Cell::new(DEFAULT_EXPAND_REP_SAMPLE_STRIDE) };
}

// 通常のencodeでは計測を無効にしたScopeが非常に高頻度で作られる。別threadを含め
// captureが1件もなければ、TLSのRefCellへ触れずに無効guardを返す。
static ACTIVE_CAPTURES: AtomicUsize = AtomicUsize::new(0);

#[cfg(test)]
pub(crate) fn enabled() -> bool {
    if ACTIVE_CAPTURES.load(Ordering::Acquire) == 0 {
        return false;
    }
    STATE.with_borrow(|state| state.measurements.is_some())
}

pub(crate) fn diagnostics_enabled() -> bool {
    if ACTIVE_CAPTURES.load(Ordering::Acquire) == 0 {
        return false;
    }
    STATE.with_borrow(|state| state.measurements.is_some() && state.diagnostics_enabled)
}

/// 保存済み終点だけの局所再評価。推定差を実圧縮byteの削減と解釈しない。
pub(crate) fn record_terminal_ranking(start: usize, candidates: usize, saving: u64) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.price_prediction else {
            return;
        };
        value.ranked_blocks = value.ranked_blocks.saturating_add(1);
        value.terminal_candidates = value.terminal_candidates.saturating_add(candidates as u128);
        if saving > 0 {
            value.rank_reversals = value.rank_reversals.saturating_add(1);
            value.rank_saving = value.rank_saving.saturating_add(u128::from(saving));
            if saving > value.max_rank_saving {
                value.max_rank_saving = saving;
                value.max_rank_saving_offset = start;
            }
        }
    });
}

/// capture中だけ、選択済み経路が各位置の先頭最安親以外へ依存した量を集計する。
/// block完走後の回顧値なので、同じblockの幅選択へは利用できない。
pub(crate) fn record_beam_competition(start: usize, block: BeamCompetitionBlock) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.beam_competition else {
            return;
        };

        let had_nonfirst = block.nonfirst_parent_tokens != 0;
        value.blocks = value.blocks.saturating_add(1);
        value.input_bytes = value.input_bytes.saturating_add(block.input_bytes as u128);
        value.path_tokens = value.path_tokens.saturating_add(block.path_tokens as u128);
        value.nonfirst_parent_tokens = value
            .nonfirst_parent_tokens
            .saturating_add(block.nonfirst_parent_tokens as u128);
        value.nonfirst_parent_bytes = value
            .nonfirst_parent_bytes
            .saturating_add(block.nonfirst_parent_bytes as u128);
        value.strict_parent_tokens = value
            .strict_parent_tokens
            .saturating_add(block.strict_parent_tokens as u128);
        value.strict_parent_bytes = value
            .strict_parent_bytes
            .saturating_add(block.strict_parent_bytes as u128);
        value.strict_parent_gap = value
            .strict_parent_gap
            .saturating_add(block.strict_parent_gap);
        if block.max_strict_parent_gap > value.max_strict_parent_gap {
            value.max_strict_parent_gap = block.max_strict_parent_gap;
            value.max_strict_parent_gap_input_offset = start;
        }
        value.nonfirst_literal_tokens = value
            .nonfirst_literal_tokens
            .saturating_add(block.nonfirst_literal_tokens as u128);
        value.nonfirst_short_rep_tokens = value
            .nonfirst_short_rep_tokens
            .saturating_add(block.nonfirst_short_rep_tokens as u128);
        value.nonfirst_rep_tokens = value
            .nonfirst_rep_tokens
            .saturating_add(block.nonfirst_rep_tokens as u128);
        value.nonfirst_match_tokens = value
            .nonfirst_match_tokens
            .saturating_add(block.nonfirst_match_tokens as u128);
        if had_nonfirst {
            value.blocks_with_nonfirst_parent = value.blocks_with_nonfirst_parent.saturating_add(1);
        }
        match (value.previous_had_nonfirst_parent, had_nonfirst) {
            (None, _) => value.sequence_starts = value.sequence_starts.saturating_add(1),
            (Some(false), false) => {
                value.previous_false_current_false =
                    value.previous_false_current_false.saturating_add(1);
            }
            (Some(false), true) => {
                value.previous_false_current_true =
                    value.previous_false_current_true.saturating_add(1);
            }
            (Some(true), false) => {
                value.previous_true_current_false =
                    value.previous_true_current_false.saturating_add(1);
            }
            (Some(true), true) => {
                value.previous_true_current_true =
                    value.previous_true_current_true.saturating_add(1);
            }
        }
        value.previous_had_nonfirst_parent = Some(had_nonfirst);

        if let Some(gap) = block.terminal_second_best_gap {
            let first_terminal_gap = value.terminal_multi_candidate_blocks == 0;
            value.terminal_multi_candidate_blocks =
                value.terminal_multi_candidate_blocks.saturating_add(1);
            value.terminal_second_best_gap = value
                .terminal_second_best_gap
                .saturating_add(u128::from(gap));
            if first_terminal_gap || gap > value.max_terminal_second_best_gap {
                value.max_terminal_second_best_gap = gap;
                value.max_terminal_second_best_gap_input_offset = start;
            }
        }
    });
}

pub(crate) fn record_active_width2_block() {
    STATE.with_borrow_mut(|state| {
        if let Some(value) = &mut state.active_width2_blocks {
            *value = value.saturating_add(1);
        }
    });
}

/// Capture-only census of the rep tuples retained in one active Beam block.
pub(crate) fn record_rep_state_census(active_nodes: usize, unique_rep_tuples: usize) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.rep_state_census else {
            return;
        };
        value.blocks = value.blocks.saturating_add(1);
        value.active_nodes = value.active_nodes.saturating_add(active_nodes as u128);
        value.unique_rep_tuples = value
            .unique_rep_tuples
            .saturating_add(unique_rep_tuples as u128);
    });
}

/// Profile-only upper-bound screen for long-token greedy commitments inside a Beam block.
pub(crate) fn record_greedy_skip_screen(block: GreedySkipBlock) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.greedy_skip_screen else {
            return;
        };
        value.input_bytes = value.input_bytes.saturating_add(block.input_bytes as u128);
        value.two_parent_positions = value
            .two_parent_positions
            .saturating_add(block.two_parent_positions as u128);
        value.margin_ge_512_positions = value
            .margin_ge_512_positions
            .saturating_add(block.margin_ge_512_positions as u128);
        value.margin_ge_128_positions = value
            .margin_ge_128_positions
            .saturating_add(block.margin_ge_128_positions as u128);
        for (aggregate, current) in value.gates.iter_mut().zip(block.gates) {
            aggregate.qualified_positions = aggregate
                .qualified_positions
                .saturating_add(current.qualified_positions as u128);
            aggregate.potential_bytes = aggregate
                .potential_bytes
                .saturating_add(current.potential_bytes as u128);
            aggregate.covered_bytes = aggregate
                .covered_bytes
                .saturating_add(current.covered_bytes as u128);
        }
    });
}

/// 最長一致shortcutはbeam状態競合を観測しないため、別計上して時系列を切る。
pub(crate) fn record_beam_bypass(bytes: usize) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.beam_competition else {
            return;
        };
        value.bypass_blocks = value.bypass_blocks.saturating_add(1);
        value.bypass_bytes = value.bypass_bytes.saturating_add(bytes as u128);
        value.previous_had_nonfirst_parent = None;
    });
}

/// capture中だけ、選択済みblockに対する2種類の概算bit-priceを集計する。
/// costの単位は1/256 bitで、range coderが実際に出力したbit数ではない。
pub(crate) fn record_price_gap(
    start: usize,
    bytes: usize,
    tokens: usize,
    frozen: u64,
    adaptive: u64,
) {
    STATE.with_borrow_mut(|state| {
        let Some(value) = &mut state.price_prediction else {
            return;
        };

        let gap = i128::from(adaptive) - i128::from(frozen);
        let absolute_gap = adaptive.abs_diff(frozen);
        let first_block = value.blocks == 0;
        value.blocks = value.blocks.saturating_add(1);
        value.bytes = value.bytes.saturating_add(bytes as u128);
        value.tokens = value.tokens.saturating_add(tokens as u128);
        value.frozen_cost = value.frozen_cost.saturating_add(u128::from(frozen));
        value.adaptive_cost = value.adaptive_cost.saturating_add(u128::from(adaptive));
        value.adaptive_minus_frozen = value.adaptive_minus_frozen.saturating_add(gap);
        value.absolute_error = value
            .absolute_error
            .saturating_add(u128::from(absolute_gap));
        // 同値では更新せず、最大差が最初に現れた入力位置を保持する。
        if first_block || absolute_gap > value.max_absolute_block_gap {
            value.max_absolute_block_gap = absolute_gap;
            value.max_absolute_block_gap_input_offset = start;
        }
        match adaptive.cmp(&frozen) {
            std::cmp::Ordering::Greater => {
                value.adaptive_over_frozen_blocks =
                    value.adaptive_over_frozen_blocks.saturating_add(1);
            }
            std::cmp::Ordering::Less => {
                value.adaptive_under_frozen_blocks =
                    value.adaptive_under_frozen_blocks.saturating_add(1);
            }
            std::cmp::Ordering::Equal => {
                value.adaptive_equal_frozen_blocks =
                    value.adaptive_equal_frozen_blocks.saturating_add(1);
            }
        }
    });
}

pub(crate) struct Scope {
    phase: Phase,
    generation: Option<u64>,
    started: Option<(u64, Instant)>,
    nested_phase: Option<Phase>,
    entered_expand: bool,
    // guardを別スレッドへ持ち出して、そのスレッドの計測へ混入させない。
    _thread_bound: std::marker::PhantomData<std::rc::Rc<()>>,
}

impl Scope {
    pub(crate) fn new(phase: Phase) -> Self {
        let generation = if ACTIVE_CAPTURES.load(Ordering::Acquire) == 0 {
            None
        } else {
            STATE.with_borrow(|state| state.measurements.is_some().then_some(state.generation))
        };
        let entered_expand = generation.is_some() && matches!(phase, Phase::ExpandNodes);
        let started = generation.map(|generation| (generation, Instant::now()));
        if let Some(generation) = generation.filter(|_| entered_expand) {
            STATE.with_borrow_mut(|state| {
                if state.generation == generation && state.measurements.is_some() {
                    state.expand_depth = state.expand_depth.saturating_add(1);
                }
            });
        }
        Self {
            phase,
            generation,
            started,
            nested_phase: None,
            entered_expand,
            _thread_bound: std::marker::PhantomData,
        }
    }

    #[inline(always)]
    pub(crate) fn sampled_rep_length(position: usize) -> Self {
        let generation = if ACTIVE_CAPTURES.load(Ordering::Acquire) == 0
            || position & (REP_LENGTH_SAMPLE_STRIDE - 1) != 0
        {
            None
        } else {
            STATE.with_borrow(|state| {
                (state.measurements.is_some() && state.diagnostics_enabled)
                    .then_some(state.generation)
            })
        };
        Self {
            phase: Phase::RepLength,
            generation,
            started: generation.map(|generation| (generation, Instant::now())),
            nested_phase: None,
            entered_expand: false,
            _thread_bound: std::marker::PhantomData,
        }
    }

    #[inline(always)]
    pub(crate) fn sampled_expand_rep_length(position: usize) -> Self {
        let sample_stride = EXPAND_REP_SAMPLE_STRIDE.with(Cell::get);
        if EXPAND_REP_SAMPLE_OFFSET.with(Cell::get) != (position & (sample_stride - 1)) {
            return Self {
                phase: Phase::ExpandRepLength,
                generation: None,
                started: None,
                nested_phase: None,
                entered_expand: false,
                _thread_bound: std::marker::PhantomData,
            };
        }
        let generation = STATE.with_borrow(|state| {
            (state.measurements.is_some() && state.expand_depth != 0).then_some(state.generation)
        });
        Self {
            phase: Phase::ExpandRepLength,
            generation,
            started: generation.map(|generation| (generation, Instant::now())),
            nested_phase: None,
            entered_expand: false,
            _thread_bound: std::marker::PhantomData,
        }
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        let elapsed = self.started.take().map(|(_, start)| start.elapsed());
        let Some(generation) = self.generation else {
            return;
        };
        STATE.with_borrow_mut(|state| {
            if state.generation == generation {
                if let Some(measurements) = &mut state.measurements {
                    let value = &mut measurements[self.phase as usize];
                    value.calls = value.calls.saturating_add(1);
                    if let Some(elapsed) = elapsed {
                        value.nanos = value.nanos.saturating_add(elapsed.as_nanos());
                    }
                    if let Some(phase) = self.nested_phase {
                        let nested = &mut measurements[phase as usize];
                        nested.calls = nested.calls.saturating_add(1);
                        if let Some(elapsed) = elapsed {
                            nested.nanos = nested.nanos.saturating_add(elapsed.as_nanos());
                        }
                    }
                }
                if self.entered_expand {
                    state.expand_depth = state.expand_depth.saturating_sub(1);
                }
            }
        });
    }
}

struct Session(u64);

impl Drop for Session {
    fn drop(&mut self) {
        STATE.with_borrow_mut(|state| {
            if state.generation == self.0 {
                state.measurements = None;
                state.diagnostics_enabled = false;
                state.expand_depth = 0;
                state.price_prediction = None;
                state.beam_competition = None;
                state.active_width2_blocks = None;
                state.greedy_skip_screen = None;
                state.rep_state_census = None;
            }
        });
        let previous = ACTIVE_CAPTURES.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous != 0, "profiling capture count underflow");
        EXPAND_REP_SAMPLE_OFFSET.with(|offset| offset.set(0));
        EXPAND_REP_SAMPLE_STRIDE.with(|stride| stride.set(DEFAULT_EXPAND_REP_SAMPLE_STRIDE));
    }
}

pub(crate) struct Report {
    elapsed_ms: f64,
    measurements: [Measurement; 9],
    diagnostics_enabled: bool,
    expand_rep_sample_offset: usize,
    expand_rep_sample_stride: usize,
    price_prediction: PricePrediction,
    beam_competition: BeamCompetition,
    active_width2_blocks: u64,
    greedy_skip_screen: GreedySkipScreen,
    rep_state_census: RepStateCensus,
}

impl Report {
    pub(crate) fn json(&self) -> serde_json::Value {
        fn unsigned(value: u128) -> serde_json::Value {
            u64::try_from(value).map_or_else(
                |_| serde_json::Value::String(value.to_string()),
                serde_json::Value::from,
            )
        }

        fn signed(value: i128) -> serde_json::Value {
            i64::try_from(value).map_or_else(
                |_| serde_json::Value::String(value.to_string()),
                serde_json::Value::from,
            )
        }

        let phases: Vec<_> = NAMES
            .iter()
            .zip(self.measurements)
            .enumerate()
            .map(|(index, (name, value))| {
                let (sampled, sample_weight) = if index == Phase::RepLength as usize {
                    (true, REP_LENGTH_SAMPLE_STRIDE)
                } else if index == Phase::ExpandRepLength as usize {
                    (true, self.expand_rep_sample_stride)
                } else {
                    (false, 1)
                };
                let inclusive_ms = value.nanos as f64 / 1_000_000.0;
                serde_json::json!({
                    "phase": name,
                    "calls": value.calls,
                    "calls_are_sampled": sampled,
                    "sample_weight": sample_weight,
                    "inclusive_ms": inclusive_ms,
                    "estimated_inclusive_ms": inclusive_ms * sample_weight as f64,
                })
            })
            .collect();
        let expand_inclusive_ms =
            self.measurements[Phase::ExpandNodes as usize].nanos as f64 / 1_000_000.0;
        let nested_rep_sample = self.measurements[Phase::ExpandRepLength as usize];
        let nested_rep_sample_ms = nested_rep_sample.nanos as f64 / 1_000_000.0;
        let nested_rep_estimated_ms = nested_rep_sample_ms * self.expand_rep_sample_stride as f64;
        let expand_without_nested_rep_estimate_ms = expand_inclusive_ms - nested_rep_estimated_ms;
        let prediction = self.price_prediction;
        let competition = self.beam_competition;
        let greedy = self.greedy_skip_screen;
        let rep_states = self.rep_state_census;
        let rep_state_reuse_fraction = if rep_states.active_nodes == 0 {
            0.0
        } else {
            1.0 - rep_states.unique_rep_tuples as f64 / rep_states.active_nodes as f64
        };
        let greedy_gates: Vec<_> = [128u64, 512]
            .into_iter()
            .flat_map(|margin| [32usize, 64, 128].map(move |length| (margin, length)))
            .zip(greedy.gates)
            .map(|((margin, length), gate)| {
                serde_json::json!({
                    "margin_units_1_256_bit": margin,
                    "minimum_match_bytes": length,
                    "qualified_positions": unsigned(gate.qualified_positions),
                    "potential_bytes_overlapping": unsigned(gate.potential_bytes),
                    "covered_bytes_nonoverlapping": unsigned(gate.covered_bytes),
                })
            })
            .collect();
        serde_json::json!({
            "elapsed_ms": self.elapsed_ms,
            "note": "instrumented inclusive wall time; nested phases overlap; not a speed comparison",
            "diagnostics_enabled": self.diagnostics_enabled,
            "phases": phases,
            "expand_without_nested_rep_screen": {
                "note": "expand_nodes inclusive minus position-sampled rep_length_limited calls nested only inside ExpandNodes; estimate under instrumentation, not a normal-Release time or savings claim",
                "sample_offset": self.expand_rep_sample_offset,
                "sample_stride": self.expand_rep_sample_stride,
                "expand_nodes_inclusive_ms": expand_inclusive_ms,
                "nested_rep_sample_calls": nested_rep_sample.calls,
                "nested_rep_sample_inclusive_ms": nested_rep_sample_ms,
                "nested_rep_estimated_inclusive_ms": nested_rep_estimated_ms,
                "expand_without_nested_rep_estimate_ms": if expand_without_nested_rep_estimate_ms >= 0.0 {
                    serde_json::Value::from(expand_without_nested_rep_estimate_ms)
                } else {
                    serde_json::Value::Null
                },
                "nonnegative_estimate": expand_without_nested_rep_estimate_ms >= 0.0,
            },
            "active_width2_blocks": self.active_width2_blocks,
            "rep_state_census": {
                "note": "profile-only count of nonempty final Beam slots per block; unique Rep tuples are summed per block and exclude cost, previous-match flag, parent, and token; not a speed or memory benchmark",
                "blocks": rep_states.blocks,
                "active_nodes": unsigned(rep_states.active_nodes),
                "unique_rep_tuples_summed_per_block": unsigned(rep_states.unique_rep_tuples),
                "duplicate_rep_tuple_fraction": rep_state_reuse_fraction,
            },
            "confident_greedy_screen": {
                "note": "profile-only proxy: current two-parent cumulative Beam cost gap and longest available Rep/Match token; thresholds sweep 0.5/2 bits and 32/64/128 bytes; covered bytes are a non-overlapping union within each block, not measured savings or evidence of parse quality",
                "input_bytes": unsigned(greedy.input_bytes),
                "two_parent_positions": unsigned(greedy.two_parent_positions),
                "margin_ge_512_positions": unsigned(greedy.margin_ge_512_positions),
                "margin_ge_128_positions": unsigned(greedy.margin_ge_128_positions),
                "gates": greedy_gates,
            },
            "price_prediction": {
                "note": "approximate bit-price estimates in 1/256-bit units; not actual range-coder output bits; not a speed measurement",
                "blocks": prediction.blocks,
                "input_bytes": unsigned(prediction.bytes),
                "tokens": unsigned(prediction.tokens),
                "approximate_frozen_bit_price_units_1_256_bit": unsigned(prediction.frozen_cost),
                "approximate_adaptive_bit_price_units_1_256_bit": unsigned(prediction.adaptive_cost),
                "approximate_adaptive_minus_frozen_units_1_256_bit": signed(prediction.adaptive_minus_frozen),
                "approximate_sum_absolute_error_units_1_256_bit": unsigned(prediction.absolute_error),
                "approximate_max_absolute_block_gap_units_1_256_bit": prediction.max_absolute_block_gap,
                "max_absolute_block_gap_input_offset": prediction.max_absolute_block_gap_input_offset,
                "adaptive_over_frozen_blocks": prediction.adaptive_over_frozen_blocks,
                "adaptive_under_frozen_blocks": prediction.adaptive_under_frozen_blocks,
                "adaptive_equal_frozen_blocks": prediction.adaptive_equal_frozen_blocks,
                "terminal_ranking": {
                    "note": "surviving terminal plans only; approximate adaptive price; hypothetical local saving, not actual output savings or a globally optimal parse",
                    "blocks": prediction.ranked_blocks,
                    "candidates": unsigned(prediction.terminal_candidates),
                    "strict_rank_reversals": prediction.rank_reversals,
                    "hypothetical_saving_units_1_256_bit": unsigned(prediction.rank_saving),
                    "max_hypothetical_saving_units_1_256_bit": prediction.max_rank_saving,
                    "max_hypothetical_saving_input_offset": prediction.max_rank_saving_offset,
                },
            },
            "beam_competition": {
                "note": "retrospective selected-path diagnostic; nonfirst means a parent other than the first minimum-cost state at that position; unavailable for choosing the same block width",
                "blocks": competition.blocks,
                "input_bytes": unsigned(competition.input_bytes),
                "path_tokens": unsigned(competition.path_tokens),
                "blocks_with_nonfirst_parent": competition.blocks_with_nonfirst_parent,
                "nonfirst_parent_tokens": unsigned(competition.nonfirst_parent_tokens),
                "nonfirst_parent_bytes": unsigned(competition.nonfirst_parent_bytes),
                "strictly_more_expensive_parent_tokens": unsigned(competition.strict_parent_tokens),
                "strictly_more_expensive_parent_bytes": unsigned(competition.strict_parent_bytes),
                "strictly_more_expensive_parent_gap_units_1_256_bit": unsigned(competition.strict_parent_gap),
                "max_strictly_more_expensive_parent_gap_units_1_256_bit": competition.max_strict_parent_gap,
                "max_strictly_more_expensive_parent_gap_input_offset": competition.max_strict_parent_gap_input_offset,
                "nonfirst_parent_token_kinds": {
                    "literal": unsigned(competition.nonfirst_literal_tokens),
                    "short_rep": unsigned(competition.nonfirst_short_rep_tokens),
                    "rep": unsigned(competition.nonfirst_rep_tokens),
                    "match": unsigned(competition.nonfirst_match_tokens),
                },
                "adjacent_analyzed_block_transitions": {
                    "note": "bypass blocks reset the sequence; current values are observable only after that block completes",
                    "sequence_starts": competition.sequence_starts,
                    "previous_false_current_false": competition.previous_false_current_false,
                    "previous_false_current_true": competition.previous_false_current_true,
                    "previous_true_current_false": competition.previous_true_current_false,
                    "previous_true_current_true": competition.previous_true_current_true,
                },
                "terminal_second_best": {
                    "blocks_with_multiple_candidates": competition.terminal_multi_candidate_blocks,
                    "gap_units_1_256_bit": unsigned(competition.terminal_second_best_gap),
                    "max_gap_units_1_256_bit": competition.max_terminal_second_best_gap,
                    "max_gap_input_offset": competition.max_terminal_second_best_gap_input_offset,
                },
                "long_match_bypass": {
                    "blocks": competition.bypass_blocks,
                    "input_bytes": unsigned(competition.bypass_bytes),
                },
            },
        })
    }
}

/// 1スレッド・1回の呼び出しだけを計測する。nested captureはプログラム上の誤用。
/// 失敗Resultやpanicでも状態を次回へ残さず、他スレッドの計測とは分離する。
pub(crate) fn capture<T>(action: impl FnOnce() -> T) -> (T, Report) {
    capture_inner(action, true, 0, DEFAULT_EXPAND_REP_SAMPLE_STRIDE)
}

/// Capture phase timings without profile-only parse probes or diagnostic counters.
pub(crate) fn capture_timing<T>(
    action: impl FnOnce() -> T,
    expand_rep_sample_offset: usize,
    expand_rep_sample_stride: usize,
) -> (T, Report) {
    capture_inner(
        action,
        false,
        expand_rep_sample_offset,
        expand_rep_sample_stride,
    )
}

fn capture_inner<T>(
    action: impl FnOnce() -> T,
    diagnostics_enabled: bool,
    expand_rep_sample_offset: usize,
    expand_rep_sample_stride: usize,
) -> (T, Report) {
    assert!(
        matches!(
            expand_rep_sample_stride,
            1 | DEFAULT_EXPAND_REP_SAMPLE_STRIDE
        ) && expand_rep_sample_offset < expand_rep_sample_stride,
        "unsupported Rep sample offset/stride"
    );
    let generation = STATE.with_borrow_mut(|state| {
        assert!(state.measurements.is_none(), "nested profiling capture");
        state.generation = state.generation.wrapping_add(1);
        state.measurements = Some([Measurement::default(); 9]);
        state.diagnostics_enabled = diagnostics_enabled;
        state.expand_depth = 0;
        state.price_prediction = diagnostics_enabled.then_some(PricePrediction::default());
        state.beam_competition = diagnostics_enabled.then_some(BeamCompetition::default());
        state.active_width2_blocks = diagnostics_enabled.then_some(0);
        state.greedy_skip_screen = diagnostics_enabled.then_some(GreedySkipScreen::default());
        state.rep_state_census = diagnostics_enabled.then_some(RepStateCensus::default());
        state.generation
    });
    EXPAND_REP_SAMPLE_OFFSET.with(|offset| offset.set(expand_rep_sample_offset));
    EXPAND_REP_SAMPLE_STRIDE.with(|stride| stride.set(expand_rep_sample_stride));
    ACTIVE_CAPTURES.fetch_add(1, Ordering::AcqRel);
    let _session = Session(generation);
    let start = Instant::now();
    let result = action();
    let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
    let (
        measurements,
        price_prediction,
        beam_competition,
        active_width2_blocks,
        greedy_skip_screen,
        rep_state_census,
    ) = STATE.with_borrow_mut(|state| {
        (
            state.measurements.take().unwrap(),
            state.price_prediction.take().unwrap_or_default(),
            state.beam_competition.take().unwrap_or_default(),
            state.active_width2_blocks.take().unwrap_or_default(),
            state.greedy_skip_screen.take().unwrap_or_default(),
            state.rep_state_census.take().unwrap_or_default(),
        )
    });
    (
        result,
        Report {
            elapsed_ms,
            measurements,
            diagnostics_enabled,
            expand_rep_sample_offset,
            expand_rep_sample_stride,
            price_prediction,
            beam_competition,
            active_width2_blocks,
            greedy_skip_screen,
            rep_state_census,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_ranking_counts_only_strict_savings_and_resets() {
        record_terminal_ranking(0, 2, 999);
        let (_, report) = capture(|| {
            record_terminal_ranking(0, 1, 0);
            record_terminal_ranking(64, 2, 17);
            record_terminal_ranking(128, 4, 17);
        });
        let value = report.json();
        let rank = &value["price_prediction"]["terminal_ranking"];
        assert_eq!(rank["blocks"], 3);
        assert_eq!(rank["candidates"], 7);
        assert_eq!(rank["strict_rank_reversals"], 2);
        assert_eq!(rank["hypothetical_saving_units_1_256_bit"], 34);
        assert_eq!(rank["max_hypothetical_saving_input_offset"], 64);
        let (_, next) = capture(|| {});
        assert_eq!(next.price_prediction.ranked_blocks, 0);
    }

    #[test]
    fn beam_competition_tracks_selected_parents_transitions_and_bypasses() {
        record_beam_bypass(999);
        record_beam_competition(
            0,
            BeamCompetitionBlock {
                input_bytes: 999,
                nonfirst_parent_tokens: 99,
                ..Default::default()
            },
        );
        let (_, report) = capture(|| {
            record_beam_competition(
                10,
                BeamCompetitionBlock {
                    input_bytes: 100,
                    path_tokens: 3,
                    terminal_second_best_gap: Some(7),
                    ..Default::default()
                },
            );
            record_beam_competition(
                110,
                BeamCompetitionBlock {
                    input_bytes: 200,
                    path_tokens: 4,
                    nonfirst_parent_tokens: 2,
                    nonfirst_parent_bytes: 30,
                    strict_parent_tokens: 1,
                    strict_parent_bytes: 20,
                    strict_parent_gap: 40,
                    max_strict_parent_gap: 40,
                    nonfirst_literal_tokens: 1,
                    nonfirst_rep_tokens: 1,
                    terminal_second_best_gap: Some(3),
                    ..Default::default()
                },
            );
            record_beam_competition(
                310,
                BeamCompetitionBlock {
                    input_bytes: 300,
                    path_tokens: 5,
                    nonfirst_parent_tokens: 1,
                    nonfirst_parent_bytes: 2,
                    strict_parent_tokens: 1,
                    strict_parent_bytes: 2,
                    strict_parent_gap: 10,
                    max_strict_parent_gap: 10,
                    nonfirst_short_rep_tokens: 1,
                    ..Default::default()
                },
            );
            record_beam_bypass(64);
            record_beam_competition(
                674,
                BeamCompetitionBlock {
                    input_bytes: 50,
                    path_tokens: 2,
                    ..Default::default()
                },
            );
        });

        let value = report.beam_competition;
        assert_eq!(value.blocks, 4);
        assert_eq!(value.input_bytes, 650);
        assert_eq!(value.path_tokens, 14);
        assert_eq!(value.blocks_with_nonfirst_parent, 2);
        assert_eq!(value.nonfirst_parent_tokens, 3);
        assert_eq!(value.nonfirst_parent_bytes, 32);
        assert_eq!(value.strict_parent_tokens, 2);
        assert_eq!(value.strict_parent_bytes, 22);
        assert_eq!(value.strict_parent_gap, 50);
        assert_eq!(value.max_strict_parent_gap, 40);
        assert_eq!(value.max_strict_parent_gap_input_offset, 110);
        assert_eq!(value.nonfirst_literal_tokens, 1);
        assert_eq!(value.nonfirst_short_rep_tokens, 1);
        assert_eq!(value.nonfirst_rep_tokens, 1);
        assert_eq!(value.nonfirst_match_tokens, 0);
        assert_eq!(value.sequence_starts, 2);
        assert_eq!(value.previous_false_current_true, 1);
        assert_eq!(value.previous_true_current_true, 1);
        assert_eq!(value.previous_true_current_false, 0);
        assert_eq!(value.terminal_multi_candidate_blocks, 2);
        assert_eq!(value.terminal_second_best_gap, 10);
        assert_eq!(value.max_terminal_second_best_gap, 7);
        assert_eq!(value.max_terminal_second_best_gap_input_offset, 10);
        assert_eq!(value.bypass_blocks, 1);
        assert_eq!(value.bypass_bytes, 64);

        let json = report.json();
        let competition = &json["beam_competition"];
        assert!(
            competition["note"]
                .as_str()
                .unwrap()
                .contains("unavailable for choosing the same block width")
        );
        assert_eq!(
            competition["adjacent_analyzed_block_transitions"]["previous_false_current_true"],
            1
        );

        let (_, next) = capture(|| {});
        assert_eq!(next.beam_competition.blocks, 0);
        assert_eq!(next.beam_competition.bypass_blocks, 0);

        let (_, zero_gap) = capture(|| {
            record_beam_competition(
                77,
                BeamCompetitionBlock {
                    terminal_second_best_gap: Some(0),
                    ..Default::default()
                },
            );
        });
        assert_eq!(zero_gap.beam_competition.max_terminal_second_best_gap, 0);
        assert_eq!(
            zero_gap
                .beam_competition
                .max_terminal_second_best_gap_input_offset,
            77
        );
    }

    #[test]
    fn disabled_scopes_and_capture_counts_are_isolated() {
        assert!(!enabled());
        assert!(Scope::new(Phase::Index).started.is_none());
        let (_, report) = capture(|| {
            let _outer = Scope::new(Phase::Encode);
            let _inner = Scope::new(Phase::Index);
        });
        assert_eq!(report.measurements[Phase::Encode as usize].calls, 1);
        assert_eq!(report.measurements[Phase::Index as usize].calls, 1);
        assert!(!enabled());
        assert!(Scope::new(Phase::Index).started.is_none());
        let (_, next) = capture(|| {});
        assert!(next.measurements.iter().all(|v| v.calls == 0));
    }

    #[test]
    fn rep_length_profile_samples_every_256th_input_position() {
        let (_, report) = capture(|| {
            for position in 0..1024 {
                let _scope = Scope::sampled_rep_length(position);
            }
        });
        let json = report.json();
        let phases = json["phases"].as_array().unwrap();
        let rep_length = phases
            .iter()
            .find(|phase| phase["phase"] == "rep_length")
            .unwrap();
        assert_eq!(rep_length["calls"], 4);
        assert_eq!(rep_length["calls_are_sampled"], true);
        assert_eq!(rep_length["sample_weight"], 256);
        assert_eq!(
            rep_length["estimated_inclusive_ms"],
            rep_length["inclusive_ms"].as_f64().unwrap() * 256.0
        );
    }

    #[test]
    fn panic_threads_and_escaped_guards_do_not_leak_measurements() {
        assert!(std::panic::catch_unwind(|| capture(|| panic!("test panic"))).is_err());
        let (old_guard, _) = capture(|| Scope::new(Phase::Index));
        let (_, report) = capture(|| {
            drop(old_guard);
            std::thread::spawn(|| {
                let (_, report) = capture(|| {
                    let _scope = Scope::new(Phase::Index);
                });
                assert_eq!(report.measurements[Phase::Index as usize].calls, 1);
            })
            .join()
            .unwrap();
        });
        assert!(report.measurements.iter().all(|v| v.calls == 0));
    }

    #[test]
    fn price_prediction_preserves_signed_sums_and_first_maximum() {
        let (_, report) = capture(|| {
            assert!(enabled());
            record_price_gap(10, 100, 3, 100, 130);
            record_price_gap(20, 200, 4, 200, 150);
            record_price_gap(30, 300, 5, 42, 42);
            record_price_gap(40, 400, 6, 0, 50);
        });
        let value = report.price_prediction;
        assert_eq!(value.blocks, 4);
        assert_eq!(value.bytes, 1_000);
        assert_eq!(value.tokens, 18);
        assert_eq!(value.frozen_cost, 342);
        assert_eq!(value.adaptive_cost, 372);
        assert_eq!(value.adaptive_minus_frozen, 30);
        assert_eq!(value.absolute_error, 130);
        assert_eq!(value.max_absolute_block_gap, 50);
        assert_eq!(value.max_absolute_block_gap_input_offset, 20);
        assert_eq!(value.adaptive_over_frozen_blocks, 2);
        assert_eq!(value.adaptive_under_frozen_blocks, 1);
        assert_eq!(value.adaptive_equal_frozen_blocks, 1);

        let json = report.json();
        let note = json["price_prediction"]["note"].as_str().unwrap();
        assert!(note.contains("approximate bit-price estimates"));
        assert!(note.contains("not actual range-coder output bits"));
        assert!(note.contains("not a speed measurement"));

        let (_, equal_only) = capture(|| record_price_gap(77, 1, 1, 9, 9));
        assert_eq!(
            equal_only
                .price_prediction
                .max_absolute_block_gap_input_offset,
            77
        );
    }

    #[test]
    fn price_prediction_is_disabled_reset_and_isolated_from_panics_and_threads() {
        record_price_gap(1, 2, 3, 4, 5);
        let (_, empty) = capture(|| {});
        assert_eq!(empty.price_prediction.blocks, 0);

        assert!(
            std::panic::catch_unwind(|| {
                capture(|| {
                    record_price_gap(10, 20, 30, 40, 50);
                    panic!("price prediction panic");
                })
            })
            .is_err()
        );
        assert!(!enabled());

        let (_, report) = capture(|| {
            record_price_gap(100, 2, 3, 10, 20);
            assert!(std::panic::catch_unwind(|| capture(|| {})).is_err());
            record_price_gap(200, 2, 3, 30, 20);
            std::thread::spawn(|| record_price_gap(300, 100, 100, 0, 100))
                .join()
                .unwrap();
        });
        assert_eq!(report.price_prediction.blocks, 2);
        assert_eq!(report.price_prediction.adaptive_minus_frozen, 0);
        assert_eq!(
            report.price_prediction.max_absolute_block_gap_input_offset,
            100
        );

        let (_, next) = capture(|| {});
        assert_eq!(next.price_prediction.blocks, 0);
    }
}
