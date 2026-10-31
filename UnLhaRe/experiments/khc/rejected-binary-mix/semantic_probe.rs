//! XOR前の既存context tupleだけを完全識別する独立診断。
//! 元nodeのprefix切詰めは維持。fold後u32の集合は観測にだけ使う。
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fmt::Write;
use std::hash::Hash;

const MAX_KEYS: usize = 2_000_000;

struct Table<K> {
    states: HashMap<K, super::Bernoulli>,
    folded: HashSet<u32>,
}

impl<K: Copy + Eq + Hash> Table<K> {
    fn new() -> Self {
        Self {
            states: HashMap::new(),
            folded: HashSet::new(),
        }
    }

    fn prepare(&mut self, key: K, folded: u32) -> super::Result<i32> {
        if !self.states.contains_key(&key) {
            self.states
                .try_reserve(1)
                .map_err(|_| "semantic diagnostic map allocation failed")?;
            if !self.folded.contains(&folded) {
                self.folded
                    .try_reserve(1)
                    .map_err(|_| "semantic diagnostic folded set allocation failed")?;
            }
            self.states.insert(key, super::Bernoulli::fresh(2048));
            self.folded.insert(folded);
        }
        Ok(self
            .states
            .get(&key)
            .ok_or("semantic diagnostic prepared key missing")?
            .p)
    }

    fn update(&mut self, key: K, bit: bool) -> super::Result<()> {
        self.states
            .get_mut(&key)
            .ok_or("semantic diagnostic update key missing")?
            .update(bit);
        Ok(())
    }
}

#[derive(Clone, Copy, Default)]
struct ClassLoss {
    bits: u64,
    ideal_bits: f64,
}

struct State {
    global: Table<u32>,
    symbol: Table<(u32, u16)>,
    history: Table<(u32, u32)>,
    joint: Table<(u32, u16, u8, u8)>,
    total_keys: usize,
    weights: [i32; 4],
    calibration: [super::Bernoulli; 129],
    classes: [ClassLoss; 7],
    writer: Option<super::range::Encoder>,
}

impl State {
    fn new() -> super::Result<Self> {
        Ok(Self {
            global: Table::new(),
            symbol: Table::new(),
            history: Table::new(),
            joint: Table::new(),
            total_keys: 0,
            weights: [16384; 4],
            calibration: std::array::from_fn(|i| super::Bernoulli::fresh(i as i32 * 32)),
            classes: [ClassLoss::default(); 7],
            writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
        })
    }

    fn record(
        &mut self,
        symbol: u16,
        node: u32,
        recent: u32,
        previous: (u8, u8),
        logit: &[i32],
        sigmoid: &[i32],
        bit: bool,
    ) -> super::Result<()> {
        let class = (node >> 28) as usize;
        let (pr, pl) = previous;
        if symbol > 256 || class >= 7 || recent > 0xffff || pr > 8 || pl > 23 {
            return Err("semantic diagnostic context outside bounds".into());
        }
        let symbol_key = (node, symbol);
        let history_key = (node, recent);
        let joint_key = (node, symbol, pr, pl);
        let added = usize::from(!self.global.states.contains_key(&node))
            + usize::from(!self.symbol.states.contains_key(&symbol_key))
            + usize::from(!self.history.states.contains_key(&history_key))
            + usize::from(!self.joint.states.contains_key(&joint_key));
        let total_keys = self
            .total_keys
            .checked_add(added)
            .ok_or("semantic diagnostic key count overflow")?;
        if total_keys > MAX_KEYS {
            return Err("semantic diagnostic distinct tuple limit exceeded".into());
        }
        // 型付きtupleの完全一致だけが予測状態を決める。元u32式は別の観測集合に残す。
        let s = u32::from(symbol);
        let ps = [
            self.global.prepare(node, node)?,
            self.symbol
                .prepare(symbol_key, node ^ s.wrapping_mul(0x9e37_79b9))?,
            self.history
                .prepare(history_key, node ^ recent.rotate_left(11))?,
            self.joint.prepare(
                joint_key,
                node ^ s.wrapping_mul(0x85eb_ca6b) ^ (u32::from(pr) << 24) ^ (u32::from(pl) << 16),
            )?,
        ];
        self.total_keys = total_keys;
        let mut stretch = [0_i32; 4];
        for (out, p) in stretch.iter_mut().zip(ps) {
            if !(1..4096).contains(&p) {
                return Err("semantic diagnostic expert probability outside bounds".into());
            }
            *out = *logit
                .get(p as usize)
                .ok_or("semantic diagnostic logit table bounds")?;
        }
        let z = stretch
            .iter()
            .zip(self.weights)
            .map(|(&s, w)| i64::from(s) * i64::from(w))
            .sum::<i64>()
            >> 16;
        let raw = sigmoid
            .get((z.clamp(-4096, 4096) + 4096) as usize)
            .copied()
            .ok_or("semantic diagnostic sigmoid table bounds")?
            .clamp(1, 4095);
        let bin = (raw / 32) as usize;
        let fraction = raw % 32;
        let calibrated = (self.calibration[bin].p * (32 - fraction)
            + self.calibration[bin + 1].p * fraction
            + 16)
            / 32;
        let p = ((raw + calibrated + 1) / 2).clamp(1, 4095);
        let zero = ((4096 - p) * 8) as u16;
        let observed = if bit {
            32768 - u32::from(zero)
        } else {
            u32::from(zero)
        };
        if !(1..32768).contains(&observed) {
            return Err("semantic diagnostic probability outside bounds".into());
        }
        let loss = -(f64::from(observed) / 32768.0).log2();
        let ideal_bits = self.classes[class].ideal_bits + loss;
        if !ideal_bits.is_finite() || loss < 0.0 {
            return Err("semantic diagnostic loss not finite/nonnegative".into());
        }
        let bits = self.classes[class]
            .bits
            .checked_add(1)
            .ok_or("semantic diagnostic bit count overflow")?;
        // 予測→元と同じ実bit順のaux符号化→global混合器/各tuple状態の更新。
        self.writer
            .as_mut()
            .ok_or("semantic diagnostic writer already finished")?
            .bit(zero, bit)?;
        self.classes[class] = ClassLoss { bits, ideal_bits };
        let target = if bit { 4096 } else { 0 };
        for (weight, s) in self.weights.iter_mut().zip(stretch) {
            let delta = (i64::from(target - p) * i64::from(s)) >> 16;
            *weight = (i64::from(*weight) + delta).clamp(0, 131072) as i32;
        }
        self.global.update(node, bit)?;
        self.symbol.update(symbol_key, bit)?;
        self.history.update(history_key, bit)?;
        self.joint.update(joint_key, bit)?;
        self.calibration[bin].update(bit);
        self.calibration[bin + 1].update(bit);
        Ok(())
    }

    fn finish_json(&mut self, alphabet: usize) -> super::Result<String> {
        if !(1..=257).contains(&alphabet) {
            return Err("semantic diagnostic alphabet outside bounds".into());
        }
        let mut bits = 0_u64;
        let mut ideal = 0.0;
        let mut classes = String::from("[");
        for (class, loss) in self.classes.iter().enumerate() {
            bits = bits
                .checked_add(loss.bits)
                .ok_or("semantic diagnostic total bit count overflow")?;
            ideal += loss.ideal_bits;
            if class != 0 {
                classes.push(',');
            }
            let _ = write!(
                classes,
                "{{\"class\":{class},\"bits\":{},\"ideal_bits\":{:.12}}}",
                loss.bits, loss.ideal_bits
            );
        }
        if !ideal.is_finite() || ideal < 0.0 {
            return Err("semantic diagnostic total loss not finite/nonnegative".into());
        }
        classes.push(']');
        let counts = [
            (self.global.states.len(), self.global.folded.len()),
            (self.symbol.states.len(), self.symbol.folded.len()),
            (self.history.states.len(), self.history.folded.len()),
            (self.joint.states.len(), self.joint.folded.len()),
        ];
        let mut total_keys = 0_usize;
        let mut tables = String::from("[");
        for (table, &(semantic, folded)) in counts.iter().enumerate() {
            total_keys = total_keys
                .checked_add(semantic)
                .ok_or("semantic diagnostic final key total overflow")?;
            let additional = semantic
                .checked_sub(folded)
                .ok_or("semantic diagnostic folded count inconsistent")?;
            if table != 0 {
                tables.push(',');
            }
            let _ = write!(
                tables,
                "{{\"table\":{table},\"distinct_semantic_keys\":{semantic},\"distinct_folded_keys\":{folded},\"additional_semantic_keys\":{additional}}}"
            );
        }
        if total_keys != self.total_keys || total_keys > MAX_KEYS {
            return Err("semantic diagnostic final key count mismatch".into());
        }
        tables.push(']');
        let payload_bytes = self
            .writer
            .take()
            .ok_or("semantic diagnostic writer already finished")?
            .finish()?
            .len();
        let header_bytes = 36_usize
            .checked_add(
                alphabet
                    .checked_mul(2)
                    .ok_or("semantic diagnostic alphabet overflow")?,
            )
            .ok_or("semantic diagnostic header overflow")?;
        let estimated_frame_bytes = payload_bytes
            .checked_add(header_bytes)
            .ok_or("semantic diagnostic frame overflow")?;
        Ok(format!(
            "{{\"classes\":{classes},\"total_bits_calls\":{bits},\"ideal_bits_total\":{ideal:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes},\"max_distinct_keys\":{MAX_KEYS},\"total_distinct_keys\":{total_keys},\"tables\":{tables}}}"
        ))
    }
}

thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

pub(super) fn record(
    symbol: u16,
    node: u32,
    recent: u32,
    previous: (u8, u8),
    logit: &[i32],
    sigmoid: &[i32],
    bit: bool,
) -> super::Result<()> {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if state.is_none() {
            *state = Some(State::new()?);
        }
        state
            .as_mut()
            .ok_or("semantic diagnostic state missing")?
            .record(symbol, node, recent, previous, logit, sigmoid, bit)
    })
}

pub(super) fn finish_json(alphabet: usize) -> super::Result<String> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("semantic diagnostic state missing")?
            .finish_json(alphabet)
    })
}
