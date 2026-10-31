//! Dense17段/Q16の別仕様CTS。min switchとexact 48bit reciprocalを使う。
#[path = "ratio_table.rs"]
mod exact_kt;

const DEPTH: usize = 16;
const LEVELS: usize = DEPTH + 1;
const CLASSES: usize = 7;
const NODES: usize = (1 << LEVELS) - 1;
const Q: u64 = 1 << 16;
const MAX_OBSERVATIONS: u32 = 562_036_803;
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
    fn kt(&self, table: &exact_kt::KtTable) -> Result<u64> {
        table
            .kt(self.zero, self.one)
            .map(|(probability, _, _)| probability)
            .map_err(|e| e.into())
    }
}

#[inline(always)]
fn ratio(table: &exact_kt::KtTable, a: u64, b: u64, denominator: u64) -> Result<u64> {
    if denominator == 0 {
        return Err("CTS zero denominator".into());
    }
    table.ratio(a, b, denominator)
        .map_err(|_| "CTS ratio product overflow".into())
}
fn probability(p: u64) -> Result<u64> {
    if !(1..Q).contains(&p) {
        return Err("CTS Q16 probability outside bounds".into());
    }
    Ok(p)
}
fn weighted_sum(weight: u64, kt: u64, child: u64) -> Result<u64> {
    if weight > Q {
        return Err("CTS weight outside bounds".into());
    }
    probability(kt)?;
    probability(child)?;
    let complement = Q
        .checked_sub(weight)
        .ok_or("CTS weight complement underflow")?;
    let a = weight
        .checked_mul(kt)
        .ok_or("CTS mixture product overflow")?;
    let b = complement
        .checked_mul(child)
        .ok_or("CTS mixture product overflow")?;
    a.checked_add(b)
        .ok_or_else(|| "CTS mixture sum overflow".into())
}
pub(super) fn mixture_snapshot(weight: u64, kt: u64, child: u64) -> Result<(u64, bool)> {
    let sum = weighted_sum(weight, kt, child)?;
    Ok((probability(sum / Q)?, sum % Q != 0))
}

// zero/remainderは同じsnapshot weight・KT・childからmixture_snapshotで得た値。
// 任意に捏造したzero/remainderへの旧式同値は、このprivate helperの契約に含めない。
pub(super) fn cached_ceiling(
    weight: u64,
    snapshot: u64,
    pk: u64,
    child: u64,
    zero: u64,
    remainder: bool,
    bit: bool,
) -> Result<u64> {
    if weight > Q {
        return Err("CTS weight outside bounds".into());
    }
    probability(pk)?;
    probability(child)?;
    if weight == snapshot {
        if bit {
            Q.checked_sub(zero)
                .ok_or_else(|| "CTS cached ceiling complement underflow".into())
        } else {
            zero.checked_add(u64::from(remainder))
                .ok_or_else(|| "CTS cached ceiling overflow".into())
        }
    } else {
        Ok(weighted_sum(weight, pk, child)?
            .checked_add(Q.checked_sub(1).ok_or("CTS ceiling offset underflow")?)
            .ok_or("CTS ceiling sum overflow")?
            / Q)
    }
}

pub(super) fn posterior_ratio(table: &exact_kt::KtTable, weight: u64, pk: u64, ceiling: u64) -> Result<u64> {
    let posterior = ratio(table, weight, probability(pk)?, ceiling)?;
    if posterior > Q {
        return Err("CTS posterior outside bounds".into());
    }
    Ok(posterior)
}

pub(super) fn next_weight(table: &exact_kt::KtTable, alpha: u64, retained: u64, posterior: u64) -> Result<u64> {
    let weight = alpha
        .checked_add(ratio(table, retained, posterior, Q)?)
        .ok_or("CTS next weight overflow")?;
    if weight > Q {
        return Err("CTS next weight outside bounds".into());
    }
    Ok(weight)
}

pub(super) struct Prediction {
    indexes: [usize; LEVELS],
    kt: [u64; LEVELS],
    zero: [u64; LEVELS],
    weights: [u64; DEPTH],
    remainder: u16,
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
    fn predict(&self, table: &exact_kt::KtTable) -> Result<Prediction> {
        let mut prediction = Prediction {
            indexes: [0; LEVELS],
            kt: [0; LEVELS],
            zero: [0; LEVELS],
            weights: [0; DEPTH],
            remainder: 0,
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
                .kt(table)?;
        }
        prediction.zero[DEPTH] = prediction.kt[DEPTH];
        for level in (0..DEPTH).rev() {
            prediction.weights[level] = self.nodes[prediction.indexes[level]].weight;
            let (zero, remainder) = mixture_snapshot(
                prediction.weights[level],
                prediction.kt[level],
                prediction.zero[level + 1],
            )?;
            prediction.zero[level] = zero;
            prediction.remainder |= u16::from(remainder) << level;
        }
        Ok(prediction)
    }
    fn update(&mut self, prediction: &Prediction, bit: bool, table: &exact_kt::KtTable) -> Result<()> {
        let after = self
            .observations
            .checked_add(1)
            .ok_or("CTS class observation overflow")?;
        if after > MAX_OBSERVATIONS {
            return Err("CTS class observation cap exceeded".into());
        }
        let denominator = u64::from(after)
            .checked_add(1)
            .ok_or("CTS switch denominator overflow")?;
        let alpha = ratio(table, Q, 1, denominator)?.max(1);
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
                    Q.checked_sub(prediction.kt[level])
                        .ok_or("CTS KT complement underflow")?
                } else {
                    prediction.kt[level]
                };
                let child = if bit {
                    Q.checked_sub(prediction.zero[level + 1])
                        .ok_or("CTS child complement underflow")?
                } else {
                    prediction.zero[level + 1]
                };
                // 観測側の上側丸めはzero予測floorとは別のcanonical仕様。
                let ceiling = cached_ceiling(
                    node.weight,
                    prediction.weights[level],
                    pk,
                    child,
                    prediction.zero[level],
                    (prediction.remainder >> level) & 1 != 0,
                    bit,
                )?;
                let posterior = posterior_ratio(table, node.weight, pk, ceiling)?;
                node.weight = next_weight(table, alpha, retained, posterior)?;
            }
            let count = if bit { &mut node.one } else { &mut node.zero };
            *count = count.checked_add(1).ok_or("CTS node count overflow")?;
            let total = node
                .zero
                .checked_add(node.one)
                .ok_or("CTS updated node total overflow")?;
            if total > MAX_OBSERVATIONS {
                return Err("CTS node observation cap exceeded".into());
            }
        }
        self.observations = after;
        self.history = (self.history << 1) | u16::from(bit);
        Ok(())
    }
}

impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        // 検査済みroot probabilityはQ未満であり、丸め加算はu64内。
        ((self.zero[0] + 1) >> 1).clamp(1, 32767) as u16
    }
}

pub(super) struct Model {
    trees: [Tree; CLASSES],
    kt_table: exact_kt::KtTable,
}
impl Model {
    #[cfg(khc_mixture_reuse_audit)]
    pub(super) fn audit_table_bytes(&self) -> usize {
        self.kt_table.audit_bytes()
    }

    #[cfg(khc_mixture_reuse_audit)]
    pub(super) fn audit_layout() -> (usize, usize) {
        (
            std::mem::size_of::<Prediction>(),
            std::mem::size_of::<Node>(),
        )
    }

    #[cfg(khc_mixture_reuse_audit)]
    pub(super) fn audit_step(&mut self, class: u32, bit: bool) -> Result<[u64; LEVELS * 5]> {
        let prediction = self.predict(class)?;
        self.update(class, &prediction, bit)?;
        let tree = self
            .trees
            .get(class as usize)
            .ok_or("CTS class outside bounds")?;
        let mut raw = [0; LEVELS * 5];
        for level in 0..LEVELS {
            let node = tree
                .nodes
                .get(prediction.indexes[level])
                .ok_or("CTS node outside bounds")?;
            raw[level * 5..level * 5 + 5].copy_from_slice(&[
                prediction.kt[level],
                prediction.zero[level],
                u64::from(node.zero),
                u64::from(node.one),
                node.weight,
            ]);
        }
        Ok(raw)
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
            kt_table: exact_kt::KtTable::new().map_err(|e| e.to_string())?,
        })
    }
    pub(super) fn predict(&self, class: u32) -> Result<Prediction> {
        self.trees
            .get(class as usize)
            .ok_or("CTS class outside bounds")?
            .predict(&self.kt_table)
    }
    pub(super) fn update(&mut self, class: u32, prediction: &Prediction, bit: bool) -> Result<()> {
        self.trees
            .get_mut(class as usize)
            .ok_or("CTS class outside bounds")?
            .update(prediction, bit, &self.kt_table)
    }
}
#[cfg(khc_balanced_kt_audit)]
pub(super) fn audit_kt_table() -> Result<exact_kt::KtTable> {
    exact_kt::KtTable::new().map_err(|e| e.to_string())
}
#[cfg(khc_balanced_kt_audit)]
pub(super) fn audit_kt(table: &exact_kt::KtTable, zero: u32, one: u32) -> Result<(u64, u64)> {
    match (Node { zero, one, weight: Q / 2 }).kt(table) {
        Ok(p) => Ok((p, 0)),
        Err(e) if e == "CTS node total overflow" => Ok((0, 1)),
        Err(e) if e == "CTS node observation cap exceeded" => Ok((0, 2)),
        Err(e) => Err(e),
    }
}
