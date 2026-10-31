//! D16/7クラスのCTS。正規化だけをf64で行う隔離研究候補。
const DEPTH: usize = 16;
const LEVELS: usize = DEPTH + 1;
const CLASSES: usize = 7;
const NODES: usize = (1 << LEVELS) - 1;
type Result<T> = super::Result<T>;

#[derive(Clone, Copy)]
struct Node {
    zero: u32,
    one: u32,
    weight: f64,
}
impl Node {
    fn fresh() -> Self {
        Self {
            zero: 0,
            one: 0,
            weight: 0.5,
        }
    }
    fn kt(&self) -> Result<f64> {
        let total = self
            .zero
            .checked_add(self.one)
            .ok_or("CTS node total overflow")?;
        probability((f64::from(self.zero) + 0.5) / (f64::from(total) + 1.0))
    }
}

fn probability(p: f64) -> Result<f64> {
    if !p.is_finite() || p <= 0.0 || p >= 1.0 {
        return Err("CTS f64 probability outside bounds".into());
    }
    Ok(p)
}
fn bounded(value: f64, error: &str) -> Result<f64> {
    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
        return Err(error.into());
    }
    Ok(value)
}
fn mixture(weight: f64, kt: f64, child: f64) -> Result<f64> {
    bounded(weight, "CTS weight outside bounds")?;
    probability(kt)?;
    probability(child)?;
    // 観測後のposteriorと同じweight*KTを先に計算し、非負の子項を加える。
    let local = weight * kt;
    let descendant = (1.0 - weight) * child;
    probability(local + descendant)
}

pub(super) struct Prediction {
    indexes: [usize; LEVELS],
    kt: [f64; LEVELS],
    zero: [f64; LEVELS],
    one: [f64; LEVELS],
}
struct Tree {
    nodes: Vec<Node>,
    history: u16,
    observations: u32,
}
impl Tree {
    fn new() -> Result<Self> {
        let nodes = super::filled(NODES, Node::fresh())?;
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
            kt: [0.0; LEVELS],
            zero: [0.0; LEVELS],
            one: [0.0; LEVELS],
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
        prediction.one[DEPTH] = probability(1.0 - prediction.kt[DEPTH])?;
        // leafからrootへ両側を独立に加重和で保存する。1側のqを補数から作らない。
        for level in (0..DEPTH).rev() {
            let weight = self
                .nodes
                .get(prediction.indexes[level])
                .ok_or("CTS node outside bounds")?
                .weight;
            prediction.zero[level] =
                mixture(weight, prediction.kt[level], prediction.zero[level + 1])?;
            prediction.one[level] = mixture(
                weight,
                probability(1.0 - prediction.kt[level])?,
                prediction.one[level + 1],
            )?;
        }
        Ok(prediction)
    }
    fn update(&mut self, prediction: &Prediction, bit: bool) -> Result<()> {
        let after = self
            .observations
            .checked_add(1)
            .ok_or("CTS class observation overflow")?;
        let alpha = bounded(1.0 / (f64::from(after) + 1.0), "CTS alpha outside bounds")?;
        let retained = bounded(1.0 - 2.0 * alpha, "CTS retained outside bounds")?;
        // childの予測は更新前に保存済み。posterior/countはleafからrootの順。
        for level in (0..LEVELS).rev() {
            let node = self
                .nodes
                .get_mut(prediction.indexes[level])
                .ok_or("CTS update node outside bounds")?;
            bounded(node.weight, "CTS update weight outside bounds")?;
            if level != DEPTH {
                let pk = probability(if bit {
                    1.0 - prediction.kt[level]
                } else {
                    prediction.kt[level]
                })?;
                let q = probability(if bit {
                    prediction.one[level]
                } else {
                    prediction.zero[level]
                })?;
                // 予測時と同じ積を保存された観測側qで割り、switch項を最後に加える。
                let local = node.weight * pk;
                let posterior = bounded(local / q, "CTS posterior outside bounds")?;
                node.weight = bounded(
                    alpha + retained * posterior,
                    "CTS next weight outside bounds",
                )?;
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

impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        // strict検査済みroot-zeroだけを正準の半切上げでQ15に変換する。
        (self.zero[0] * 32768.0 + 0.5).floor().clamp(1.0, 32767.0) as u16
    }
}

pub(super) struct Model {
    trees: [Tree; CLASSES],
}
impl Model {
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
    pub(super) fn predict(&self, class: u32) -> Result<Prediction> {
        self.trees
            .get(class as usize)
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
