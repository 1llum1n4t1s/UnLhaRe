//! cfg限定の論理回数。予測・演算を診断のために再実行しない。
use std::cell::RefCell;
use std::fmt::Write;

#[derive(Clone, Copy)]
struct Count {
    bayes: [u64; 4],
    light_depth: [u64; 17],
    light_probes: u64,
    light_nodes: u64,
    heavy_predicts: u64,
    heavy_updates: u64,
    heavy_kt: [u64; 4],
    heavy_mixtures: u64,
    heavy_nodes: u64,
    ratio_wrapper: u64,
    ratio_flags: [u64; 32],
}
impl Count {
    const fn new() -> Self {
        Self { bayes: [0; 4], light_depth: [0; 17], light_probes: 0, light_nodes: 0,
            heavy_predicts: 0, heavy_updates: 0, heavy_kt: [0; 4], heavy_mixtures: 0,
            heavy_nodes: 0, ratio_wrapper: 0, ratio_flags: [0; 32] }
    }
}
struct State {
    phase: usize,
    class: usize,
    overflow: bool,
    counts: [[Count; 7]; 4],
}
impl State {
    const fn new() -> Self {
        Self { phase: 0, class: 0, overflow: false, counts: [[Count::new(); 7]; 4] }
    }
}
thread_local! {
    static STATE: RefCell<State> = const { RefCell::new(State::new()) };
}
pub struct Scope(usize, usize);
pub fn scope(phase: usize, class: usize) -> Scope {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        let previous = Scope(state.phase, state.class);
        if phase < 4 && class < 7 { state.phase = phase; state.class = class; }
        else { state.overflow = true; }
        previous
    })
}
impl Drop for Scope {
    fn drop(&mut self) {
        STATE.with(|state| { let mut state = state.borrow_mut(); state.phase = self.0; state.class = self.1; });
    }
}
fn add(value: &mut u64, amount: u64, overflow: &mut bool) {
    if let Some(next) = value.checked_add(amount) { *value = next; }
    else { *overflow = true; }
}
fn record(f: impl FnOnce(&mut Count, &mut bool)) {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        let phase = state.phase;
        let class = state.class;
        let State { counts, overflow, .. } = &mut *state;
        f(&mut counts[phase][class], overflow);
    });
}
pub fn bayes(branch: usize) {
    record(|count, overflow| { if branch < 4 { add(&mut count.bayes[branch], 1, overflow); } else { *overflow = true; } });
}
pub fn light_predict(depth: usize) {
    record(|count, overflow| {
        if depth < 17 {
            add(&mut count.light_depth[depth], 1, overflow);
            add(&mut count.light_probes, (17 - depth).min(16) as u64, overflow);
        } else { *overflow = true; }
    });
}
pub fn light_update() { record(|count, overflow| add(&mut count.light_nodes, 17, overflow)); }
pub fn heavy_predict() {
    record(|count, overflow| { add(&mut count.heavy_predicts, 1, overflow); add(&mut count.heavy_mixtures, 16, overflow); });
}
pub fn heavy_update() {
    record(|count, overflow| { add(&mut count.heavy_updates, 1, overflow); add(&mut count.heavy_nodes, 17, overflow); });
}
pub fn heavy_kt(method: u64) {
    record(|count, overflow| { if method < 4 { add(&mut count.heavy_kt[method as usize], 1, overflow); } else { *overflow = true; } });
}
pub fn ratio_wrapper() { record(|count, overflow| add(&mut count.ratio_wrapper, 1, overflow)); }
pub fn ratio_flags(flags: u8) {
    record(|count, overflow| { if flags < 32 { add(&mut count.ratio_flags[usize::from(flags)], 1, overflow); } else { *overflow = true; } });
}
pub fn dump() {
    STATE.with(|state| {
        let state = state.borrow();
        let mut output = format!("{{\"operation_counts\":true,\"overflow\":{},\"phase_restored\":{},\"counter_state_bytes\":{},\"stages\":[", state.overflow, state.phase == 0 && state.class == 0, std::mem::size_of::<State>());
        for (phase, name) in ["light", "active", "replay", "reference"].iter().enumerate() {
            if phase != 0 { output.push(','); }
            write!(output, "{{\"stage\":\"{name}\",\"classes\":[").unwrap();
            for (class, count) in state.counts[phase].iter().enumerate() {
                if class != 0 { output.push(','); }
                write!(output, "{{\"bayes\":{:?},\"light_depth\":{:?},\"light_probes\":{},\"light_nodes\":{},\"heavy_predicts\":{},\"heavy_updates\":{},\"heavy_kt\":{:?},\"heavy_mixtures\":{},\"heavy_nodes\":{},\"ratio_wrapper\":{},\"ratio_flags\":{:?}}}", count.bayes, count.light_depth, count.light_probes, count.light_nodes, count.heavy_predicts, count.heavy_updates, count.heavy_kt, count.heavy_mixtures, count.heavy_nodes, count.ratio_wrapper, count.ratio_flags).unwrap();
            }
            output.push_str("]}");
        }
        output.push_str("]}");
        println!("{output}");
    });
}
