//! 固定D16/Q48 CTSの独立診断。classの過去bitだけで予測する。
use std::cell::RefCell;
use std::fmt::Write;

const DEPTH: usize = 16;
const LEVELS: usize = DEPTH + 1;
const CLASSES: usize = 7;
const NODES: usize = (1 << LEVELS) - 1;
const Q: u64 = 1 << 48;
type Result<T> = super::Result<T>;

#[derive(Clone, Copy)]
struct Node {
    zero: u32,
    one: u32,
    weight: u64,
}
impl Node {
    fn fresh() -> Self {
        Self {
            zero: 0,
            one: 0,
            weight: Q / 2,
        }
    }
    fn kt(&self) -> Result<u64> {
        let total = self
            .zero
            .checked_add(self.one)
            .ok_or("CTS node total overflow")?;
        probability(ratio(
            Q,
            2 * u64::from(self.zero) + 1,
            2 * (u64::from(total) + 1),
        )?)
    }
}

fn ratio(a: u64, b: u64, denominator: u64) -> Result<u64> {
    if denominator == 0 {
        return Err("CTS zero denominator".into());
    }
    let product = u128::from(a)
        .checked_mul(u128::from(b))
        .ok_or("CTS product overflow")?;
    u64::try_from(product / u128::from(denominator)).map_err(|_| "CTS quotient overflow".into())
}
fn probability(p: u64) -> Result<u64> {
    if !(1..Q).contains(&p) {
        return Err("CTS Q48 probability outside bounds".into());
    }
    Ok(p)
}
fn mixture(weight: u64, kt: u64, child: u64) -> Result<u64> {
    if weight > Q {
        return Err("CTS weight outside bounds".into());
    }
    probability(kt)?;
    probability(child)?;
    let a = u128::from(weight)
        .checked_mul(u128::from(kt))
        .ok_or("CTS mixture product overflow")?;
    let b = u128::from(Q - weight)
        .checked_mul(u128::from(child))
        .ok_or("CTS mixture product overflow")?;
    let sum = a.checked_add(b).ok_or("CTS mixture sum overflow")?;
    probability(u64::try_from(sum / u128::from(Q)).map_err(|_| "CTS mixture quotient overflow")?)
}

struct Prediction {
    indexes: [usize; LEVELS],
    kt: [u64; LEVELS],
    zero: [u64; LEVELS],
}
struct Tree {
    nodes: Vec<Node>,
    history: u16,
    observations: u32,
}
impl Tree {
    fn new() -> Result<Self> {
        let nodes = super::filled(NODES, Node::fresh())?;
        if nodes.capacity() != NODES || std::mem::size_of::<Node>() != 16 {
            return Err("CTS node capacity/layout mismatch".into());
        }
        Ok(Self {
            nodes,
            history: 0,
            observations: 0,
        })
    }
    // current bitは引数にも含めず、最新の過去bitから木をたどる。
    fn predict(&self) -> Result<Prediction> {
        let mut prediction = Prediction {
            indexes: [0; LEVELS],
            kt: [0; LEVELS],
            zero: [0; LEVELS],
        };
        for level in 0..LEVELS {
            if level != 0 {
                prediction.indexes[level] = prediction.indexes[level - 1]
                    .checked_mul(2)
                    .and_then(|n| n.checked_add(1 + usize::from((self.history >> (level - 1)) & 1)))
                    .ok_or("CTS path index overflow")?;
            }
            prediction.kt[level] = self
                .nodes
                .get(prediction.indexes[level])
                .ok_or("CTS node outside bounds")?
                .kt()?;
        }
        prediction.zero[DEPTH] = prediction.kt[DEPTH];
        for level in (0..DEPTH).rev() {
            prediction.zero[level] = mixture(
                self.nodes[prediction.indexes[level]].weight,
                prediction.kt[level],
                prediction.zero[level + 1],
            )?;
        }
        Ok(prediction)
    }
    fn update(&mut self, prediction: &Prediction, bit: bool) -> Result<()> {
        let after = self
            .observations
            .checked_add(1)
            .ok_or("CTS class observation overflow")?;
        let alpha = Q / (u64::from(after) + 1);
        let retained = Q
            .checked_sub(alpha.checked_mul(2).ok_or("CTS switch overflow")?)
            .ok_or("CTS switch outside bounds")?;
        // childの予測は更新前に保存済み。posterior/countはleafからrootの順。
        for level in (0..LEVELS).rev() {
            let node = self
                .nodes
                .get_mut(prediction.indexes[level])
                .ok_or("CTS update node outside bounds")?;
            if node.weight > Q {
                return Err("CTS update weight outside bounds".into());
            }
            if level != DEPTH {
                let pk = if bit {
                    Q - prediction.kt[level]
                } else {
                    prediction.kt[level]
                };
                let q = if bit {
                    Q - prediction.zero[level]
                } else {
                    prediction.zero[level]
                };
                let posterior = ratio(node.weight, pk, probability(q)?)?;
                if posterior > Q {
                    return Err("CTS posterior outside bounds".into());
                }
                node.weight = alpha
                    .checked_add(ratio(retained, posterior, Q)?)
                    .ok_or("CTS next weight overflow")?;
                if node.weight > Q {
                    return Err("CTS next weight outside bounds".into());
                }
            }
            let count = if bit { &mut node.one } else { &mut node.zero };
            *count = count.checked_add(1).ok_or("CTS node count overflow")?;
            node.zero
                .checked_add(node.one)
                .ok_or("CTS updated node total overflow")?;
        }
        self.observations = after;
        self.history = (self.history << 1) | u16::from(bit);
        Ok(())
    }
}

#[derive(Clone, Copy, Default)]
struct Loss {
    raw: f64,
    q15: f64,
    root: f64,
}
fn loss(p: u64, total: u64, bit: bool) -> Result<f64> {
    if p == 0 || p >= total {
        return Err("CTS loss probability outside bounds".into());
    }
    let observed = if bit { total - p } else { p };
    let result = -(observed as f64 / total as f64).log2();
    if !result.is_finite() || result < 0.0 {
        return Err("CTS loss not finite/nonnegative".into());
    }
    Ok(result)
}
fn add_loss(target: &mut f64, value: f64) -> Result<()> {
    let next = *target + value;
    if !next.is_finite() || next < 0.0 {
        return Err("CTS loss total not finite/nonnegative".into());
    }
    *target = next;
    Ok(())
}

// 整数実装のpath配列を使わず、全treeで予測と更新を再帰計算する対照。
#[derive(Clone, Copy)]
struct FloatNode {
    zero: u32,
    one: u32,
    weight: f64,
}
struct FloatTree {
    nodes: Vec<FloatNode>,
    history: u16,
    observations: u32,
}
impl FloatTree {
    fn new() -> Result<Self> {
        Ok(Self {
            nodes: super::filled(
                NODES,
                FloatNode {
                    zero: 0,
                    one: 0,
                    weight: 0.5,
                },
            )?,
            history: 0,
            observations: 0,
        })
    }
    fn predict_node(&self, index: usize, level: usize) -> f64 {
        let node = self.nodes[index];
        let kt = (f64::from(node.zero) + 0.5) / (f64::from(node.zero) + f64::from(node.one) + 1.0);
        if level == DEPTH {
            return kt;
        }
        let child = index * 2 + 1 + usize::from((self.history >> level) & 1);
        node.weight * kt + (1.0 - node.weight) * self.predict_node(child, level + 1)
    }
    fn observe_node(&mut self, index: usize, level: usize, bit: bool, alpha: f64) -> f64 {
        let node = self.nodes[index];
        let kt = (f64::from(node.zero) + 0.5) / (f64::from(node.zero) + f64::from(node.one) + 1.0);
        let zero = if level == DEPTH {
            kt
        } else {
            let child = index * 2 + 1 + usize::from((self.history >> level) & 1);
            let child_zero = self.observe_node(child, level + 1, bit, alpha);
            let zero = node.weight * kt + (1.0 - node.weight) * child_zero;
            let pk = if bit { 1.0 - kt } else { kt };
            let q = if bit { 1.0 - zero } else { zero };
            self.nodes[index].weight = alpha + (1.0 - 2.0 * alpha) * node.weight * pk / q;
            zero
        };
        if bit {
            self.nodes[index].one += 1;
        } else {
            self.nodes[index].zero += 1;
        }
        zero
    }
    fn update(&mut self, bit: bool) {
        let alpha = 1.0 / (f64::from(self.observations) + 2.0);
        self.observe_node(0, 0, bit, alpha);
        self.observations += 1;
        self.history = (self.history << 1) | u16::from(bit);
    }
}
struct SelfChecks {
    cases: usize,
    checks: u64,
    prediction_error: f64,
    weight_error: f64,
}
fn self_checks() -> Result<SelfChecks> {
    let mut result = SelfChecks {
        cases: 6,
        checks: 0,
        prediction_error: 0.0,
        weight_error: 0.0,
    };
    for case in 0..result.cases {
        let mut integer = Tree::new()?;
        let mut float = FloatTree::new()?;
        let length = match case {
            0 => 0,
            1 => 2,
            _ => 64,
        };
        for step in 0..=length {
            let prediction = integer.predict()?;
            let expected = float.predict_node(0, 0);
            let error = (prediction.zero[0] as f64 / Q as f64 - expected).abs();
            if !error.is_finite() || error > 1e-6 {
                return Err("CTS self-check prediction mismatch".into());
            }
            result.prediction_error = result.prediction_error.max(error);
            result.checks += 1;
            // 再帰対照と独立した、初期historyから1,1を観測した既知値。
            if case == 1 {
                let known = [0.5, 0.375, 19.0 / 72.0][step];
                if (prediction.zero[0] as f64 / Q as f64 - known).abs() > 1e-6 {
                    return Err("CTS self-check known prediction mismatch".into());
                }
                if step == 2
                    && (integer.nodes[0].weight as f64 / Q as f64 - 8.0 / 15.0).abs() > 1e-6
                {
                    return Err("CTS self-check known posterior mismatch".into());
                }
                result.checks += 1;
            }
            if step == 0 && prediction.zero.iter().any(|&p| p != Q / 2) {
                return Err("CTS self-check initial half mismatch".into());
            }
            if step == length {
                break;
            }
            let bit = match case {
                2 => false,
                1 | 3 => true,
                4 => step % 2 != 0,
                _ => ((0xd3a5_7906_c218_f04b_u64 >> step) & 1) != 0,
            };
            integer.update(&prediction, bit)?;
            float.update(bit);
            for &index in &prediction.indexes {
                let i = integer.nodes[index];
                let f = float.nodes[index];
                let error = (i.weight as f64 / Q as f64 - f.weight).abs();
                if !error.is_finite() || error > 1e-6 || i.zero != f.zero || i.one != f.one {
                    return Err("CTS self-check posterior/count mismatch".into());
                }
                result.weight_error = result.weight_error.max(error);
                result.checks += 1;
                if step == 0 && i.weight != Q / 2 {
                    return Err("CTS self-check first switch mismatch".into());
                }
            }
            if integer.history != float.history || integer.observations != float.observations {
                return Err("CTS self-check history/time mismatch".into());
            }
        }
    }
    Ok(result)
}

struct State {
    trees: Vec<Tree>,
    losses: [Loss; CLASSES],
    writer: Option<super::range::Encoder>,
    total_bits: u32,
    clamp_low: u64,
    clamp_high: u64,
    checks: SelfChecks,
}
impl State {
    fn new() -> Result<Self> {
        // 自己検査が失敗した場合、実stream観測/符号化を始めない。
        let checks = self_checks()?;
        let mut trees = Vec::new();
        trees
            .try_reserve_exact(CLASSES)
            .map_err(|_| "CTS class allocation failed")?;
        for _ in 0..CLASSES {
            trees.push(Tree::new()?);
        }
        Ok(Self {
            trees,
            losses: [Loss::default(); CLASSES],
            writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
            total_bits: 0,
            clamp_low: 0,
            clamp_high: 0,
            checks,
        })
    }
    fn record(&mut self, class: u32, bit: bool) -> Result<u16> {
        let tree = self
            .trees
            .get_mut(class as usize)
            .ok_or("CTS class outside bounds")?;
        let prediction = tree.predict()?;
        let rounded = prediction.zero[0]
            .checked_add(1 << 32)
            .ok_or("CTS Q15 rounding overflow")?
            >> 33;
        if rounded == 0 {
            self.clamp_low = self
                .clamp_low
                .checked_add(1)
                .ok_or("CTS clamp count overflow")?;
        }
        if rounded >= 32768 {
            self.clamp_high = self
                .clamp_high
                .checked_add(1)
                .ok_or("CTS clamp count overflow")?;
        }
        let zero =
            u16::try_from(rounded.clamp(1, 32767)).map_err(|_| "CTS Q15 conversion failed")?;
        if !(1..32768).contains(&zero) {
            return Err("CTS Q15 outside bounds".into());
        }
        let total_bits = self
            .total_bits
            .checked_add(1)
            .ok_or("CTS total bit count overflow")?;
        // bitへの最初の参照は、更新前predictionとQ15確率の確定後。
        let losses = &mut self.losses[class as usize];
        add_loss(&mut losses.raw, loss(prediction.zero[0], Q, bit)?)?;
        add_loss(&mut losses.q15, loss(u64::from(zero), 32768, bit)?)?;
        add_loss(&mut losses.root, loss(prediction.kt[0], Q, bit)?)?;
        self.writer
            .as_mut()
            .ok_or("CTS writer already finished")?
            .bit(zero, bit)?;
        tree.update(&prediction, bit)?;
        self.total_bits = total_bits;
        Ok(zero)
    }
    fn finish_json(&mut self, alphabet: usize) -> Result<String> {
        if !(1..=257).contains(&alphabet) {
            return Err("CTS alphabet outside bounds".into());
        }
        let mut classes = String::from("[");
        let mut totals = Loss::default();
        let mut bits = 0_u32;
        let mut active = 0_usize;
        let mut visits = 0_u32;
        for (class, (tree, losses)) in self.trees.iter().zip(self.losses).enumerate() {
            let mut node_visits = 0_u32;
            let mut active_nodes = 0_usize;
            for node in &tree.nodes {
                let count = node
                    .zero
                    .checked_add(node.one)
                    .ok_or("CTS final node count overflow")?;
                if node.weight > Q {
                    return Err("CTS final node weight outside bounds".into());
                }
                node_visits = node_visits
                    .checked_add(count)
                    .ok_or("CTS final class visits overflow")?;
                if count != 0 {
                    active_nodes = active_nodes
                        .checked_add(1)
                        .ok_or("CTS active node overflow")?;
                }
            }
            if tree.nodes.len() != NODES
                || tree.nodes.capacity() != NODES
                || node_visits
                    != tree
                        .observations
                        .checked_mul(LEVELS as u32)
                        .ok_or("CTS expected visits overflow")?
                || tree.nodes[0].zero.checked_add(tree.nodes[0].one) != Some(tree.observations)
            {
                return Err("CTS final capacity/count/visits mismatch".into());
            }
            bits = bits
                .checked_add(tree.observations)
                .ok_or("CTS final bits overflow")?;
            active = active
                .checked_add(active_nodes)
                .ok_or("CTS final active overflow")?;
            visits = visits
                .checked_add(node_visits)
                .ok_or("CTS final visits overflow")?;
            add_loss(&mut totals.raw, losses.raw)?;
            add_loss(&mut totals.q15, losses.q15)?;
            add_loss(&mut totals.root, losses.root)?;
            if class != 0 {
                classes.push(',');
            }
            let _ = write!(
                classes,
                "{{\"class\":{class},\"bits\":{},\"raw_ideal_bits\":{:.12},\"q15_ideal_bits\":{:.12},\"root_kt_ideal_bits\":{:.12},\"active_nodes\":{active_nodes},\"node_visits\":{node_visits}}}",
                tree.observations, losses.raw, losses.q15, losses.root
            );
        }
        classes.push(']');
        if bits != self.total_bits
            || visits
                != bits
                    .checked_mul(LEVELS as u32)
                    .ok_or("CTS total expected visits overflow")?
        {
            return Err("CTS aggregate mismatch".into());
        }
        let total_node_capacity = NODES
            .checked_mul(CLASSES)
            .ok_or("CTS total capacity overflow")?;
        let node_state_bytes = std::mem::size_of::<Node>();
        let state_capacity_bytes = total_node_capacity
            .checked_mul(node_state_bytes)
            .ok_or("CTS state bytes overflow")?;
        let payload_bytes = self
            .writer
            .take()
            .ok_or("CTS writer already finished")?
            .finish()?
            .len();
        let estimated_frame_bytes = alphabet
            .checked_mul(2)
            .and_then(|n| n.checked_add(36))
            .and_then(|n| n.checked_add(payload_bytes))
            .ok_or("CTS frame bytes overflow")?;
        Ok(format!(
            "{{\"depth\":{DEPTH},\"precision_bits\":48,\"nodes_per_class\":{NODES},\"total_node_capacity\":{total_node_capacity},\"node_state_bytes\":{node_state_bytes},\"state_capacity_bytes\":{state_capacity_bytes},\"total_bits_calls\":{bits},\"node_visits\":{visits},\"active_nodes\":{active},\"classes\":{classes},\"raw_ideal_bits_total\":{:.12},\"q15_ideal_bits_total\":{:.12},\"root_kt_ideal_bits_total\":{:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes},\"q15_clamp_low\":{},\"q15_clamp_high\":{},\"self_checks\":{{\"passed\":true,\"cases\":{},\"checks\":{},\"max_abs_prediction_error\":{:.16},\"max_abs_weight_error\":{:.16}}}}}",
            totals.raw,
            totals.q15,
            totals.root,
            self.clamp_low,
            self.clamp_high,
            self.checks.cases,
            self.checks.checks,
            self.checks.prediction_error,
            self.checks.weight_error
        ))
    }
}
thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }
pub(super) fn record(class: u32, bit: bool) -> Result<u16> {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if state.is_none() {
            *state = Some(State::new()?);
        }
        state
            .as_mut()
            .ok_or("CTS state missing")?
            .record(class, bit)
    })
}
pub(super) fn finish_json(alphabet: usize) -> Result<String> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("CTS state missing")?
            .finish_json(alphabet)
    })
}
