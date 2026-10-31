//! 凍結cts_probe.rsの整数CTS数学を抽出。診断writer/損失/selfcheckは含めない。
const DEPTH: usize = 16;
const LEVELS: usize = DEPTH + 1;
const CLASSES: usize = 7;
const NODES: usize = (1 << LEVELS) - 1;
const Q: u64 = 1 << 48;
type Result<T> = super::Result<T>;

#[derive(Clone, Copy, Default)]
pub(super) struct Stats {
    pub(super) cts_predict_bits: u64,
    pub(super) cts_update_bits: u64,
    pub(super) cts_kt_calls: u64,
    pub(super) cts_kt_fresh: u64,
    pub(super) cts_mixture_calls: u64,
    pub(super) cts_mixture_equal: u64,
    pub(super) cts_posterior_calls: u64,
    pub(super) cts_posterior_equal: u64,
    pub(super) cts_retained_calls: u64,
    pub(super) cts_retained_half: u64,
}
impl Stats {
    fn checked_add(self, other: Self) -> Result<Self> {
        Ok(Self {
            cts_predict_bits: self
                .cts_predict_bits
                .checked_add(other.cts_predict_bits)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_update_bits: self
                .cts_update_bits
                .checked_add(other.cts_update_bits)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_kt_calls: self
                .cts_kt_calls
                .checked_add(other.cts_kt_calls)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_kt_fresh: self
                .cts_kt_fresh
                .checked_add(other.cts_kt_fresh)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_mixture_calls: self
                .cts_mixture_calls
                .checked_add(other.cts_mixture_calls)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_mixture_equal: self
                .cts_mixture_equal
                .checked_add(other.cts_mixture_equal)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_posterior_calls: self
                .cts_posterior_calls
                .checked_add(other.cts_posterior_calls)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_posterior_equal: self
                .cts_posterior_equal
                .checked_add(other.cts_posterior_equal)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_retained_calls: self
                .cts_retained_calls
                .checked_add(other.cts_retained_calls)
                .ok_or("CTS diagnostic counter overflow")?,
            cts_retained_half: self
                .cts_retained_half
                .checked_add(other.cts_retained_half)
                .ok_or("CTS diagnostic counter overflow")?,
        })
    }
    fn validate(&self) -> Result<()> {
        let kt_calls = self
            .cts_predict_bits
            .checked_mul(LEVELS as u64)
            .ok_or("CTS diagnostic expected KT count overflow")?;
        let inner_calls = self
            .cts_update_bits
            .checked_mul(DEPTH as u64)
            .ok_or("CTS diagnostic expected inner count overflow")?;
        if self.cts_predict_bits != self.cts_update_bits
            || self.cts_kt_calls != kt_calls
            || self.cts_mixture_calls != inner_calls
            || self.cts_posterior_calls != inner_calls
            || self.cts_retained_calls != inner_calls
            || self.cts_kt_fresh > self.cts_kt_calls
            || self.cts_mixture_equal > self.cts_mixture_calls
            || self.cts_posterior_equal > self.cts_posterior_calls
            || self.cts_retained_half > self.cts_retained_calls
        {
            return Err("CTS diagnostic counter invariant failed".into());
        }
        Ok(())
    }
}
fn increment(counter: &mut u64) -> Result<()> {
    *counter = counter
        .checked_add(1)
        .ok_or("CTS diagnostic counter overflow")?;
    Ok(())
}

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
    super::exact_div::ratio(a, b, denominator)
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

pub(super) struct Prediction {
    indexes: [usize; LEVELS],
    kt: [u64; LEVELS],
    zero: [u64; LEVELS],
}
struct Tree {
    nodes: Vec<Node>,
    history: u16,
    observations: u32,
    stats: Stats,
}
impl Tree {
    fn new() -> Result<Self> {
        let nodes = super::filled(NODES, Node::fresh())?;
        Ok(Self {
            nodes,
            history: 0,
            observations: 0,
            stats: Stats::default(),
        })
    }
    // current bitは引数にも含めず、最新の過去bitから木をたどる。
    fn predict(&mut self) -> Result<Prediction> {
        let mut event = Stats::default();
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
            let node = self
                .nodes
                .get(prediction.indexes[level])
                .ok_or("CTS node outside bounds")?;
            prediction.kt[level] = node.kt()?;
            increment(&mut event.cts_kt_calls)?;
            if node.zero == 0 && node.one == 0 {
                increment(&mut event.cts_kt_fresh)?;
            }
        }
        prediction.zero[DEPTH] = prediction.kt[DEPTH];
        for level in (0..DEPTH).rev() {
            prediction.zero[level] = mixture(
                self.nodes[prediction.indexes[level]].weight,
                prediction.kt[level],
                prediction.zero[level + 1],
            )?;
            increment(&mut event.cts_mixture_calls)?;
            if prediction.kt[level] == prediction.zero[level + 1] {
                increment(&mut event.cts_mixture_equal)?;
            }
        }
        increment(&mut event.cts_predict_bits)?;
        self.stats = self.stats.checked_add(event)?;
        Ok(prediction)
    }
    fn update(&mut self, prediction: &Prediction, bit: bool) -> Result<()> {
        let mut event = Stats::default();
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
                increment(&mut event.cts_posterior_calls)?;
                if pk == q {
                    increment(&mut event.cts_posterior_equal)?;
                }
                increment(&mut event.cts_retained_calls)?;
                if posterior == Q / 2 {
                    increment(&mut event.cts_retained_half)?;
                }
            }
            let count = if bit { &mut node.one } else { &mut node.zero };
            *count = count.checked_add(1).ok_or("CTS node count overflow")?;
            node.zero
                .checked_add(node.one)
                .ok_or("CTS updated node total overflow")?;
        }
        increment(&mut event.cts_update_bits)?;
        self.stats = self.stats.checked_add(event)?;
        self.observations = after;
        self.history = (self.history << 1) | u16::from(bit);
        Ok(())
    }
}

impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        // 凍結CTSのQ48→Q15丸めと補数を維持する。
        ((self.zero[0] + (1 << 32)) >> 33).clamp(1, 32767) as u16
    }
}

pub(super) struct Model {
    trees: [Tree; CLASSES],
}
impl Model {
    pub(super) fn stats(&self) -> Result<Stats> {
        let mut total = Stats::default();
        for tree in &self.trees {
            tree.stats.validate()?;
            total = total.checked_add(tree.stats)?;
        }
        total.validate()?;
        Ok(total)
    }
    pub(super) fn new() -> Result<Self> {
        Ok(Self {
            trees: [
                Tree::new()?,
                Tree::new()?,
                Tree::new()?,
                Tree::new()?,
                Tree::new()?,
                Tree::new()?,
                Tree::new()?,
            ],
        })
    }
    pub(super) fn predict(&mut self, class: u32) -> Result<Prediction> {
        self.trees
            .get_mut(class as usize)
            .ok_or("CTS class outside bounds")?
            .predict()
    }
    pub(super) fn update(&mut self, class: u32, prediction: &Prediction, bit: bool) -> Result<()> {
        self.trees
            .get_mut(class as usize)
            .ok_or("CTS class outside bounds")?
            .update(prediction, bit)
    }
}
