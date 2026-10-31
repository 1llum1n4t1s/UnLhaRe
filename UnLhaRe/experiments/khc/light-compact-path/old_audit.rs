//! 観測数に基づいて1個のsuffix KT expertを選ぶ別形式の研究モデル。
#[path = "../causal-bayes-q32-kt-reciprocal/exact_kt.rs"]
mod exact_kt;

const DEPTH: usize = 16;
const LEVELS: usize = DEPTH + 1;
const NODES: usize = (1 << LEVELS) - 1;
const CLASSES: usize = 7;
const MIN_OBSERVATIONS: u32 = 32;
const MAX_OBSERVATIONS: u32 = 562_036_803;
const Q: u64 = 1 << 32;
type Result<T> = super::Result<T>;

#[derive(Clone, Copy)]
#[repr(C)]
struct Node {
    zero: u32,
    one: u32,
}
const _: () = assert!(std::mem::size_of::<Node>() == 8);

struct Tree {
    nodes: Vec<Node>,
    history: u16,
    observations: u32,
}
pub(super) struct Prediction {
    indexes: [usize; LEVELS],
    zero: u64,
    history: u16,
    observations: u32,
    class: u32,
}
impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        ((self.zero + (1 << 16)) >> 17).clamp(1, 32767) as u16
    }
}
impl Tree {
    fn new() -> Result<Self> {
        Ok(Self {
            nodes: super::filled(NODES, Node { zero: 0, one: 0 })?,
            history: 0,
            observations: 0,
        })
    }

    // 現bitは引数に含めず、過去historyだけから元と同じheap pathを作る。
    fn predict(&self, table: &exact_kt::KtTable, class: u32) -> Result<Prediction> {
        let mut indexes = [0usize; LEVELS];
        for level in 1..LEVELS {
            indexes[level] = indexes[level - 1]
                .checked_mul(2)
                .and_then(|n| n.checked_add(1 + usize::from((self.history >> (level - 1)) & 1)))
                .ok_or("suffix path index overflow")?;
        }
        let mut selected = 0;
        for level in (1..LEVELS).rev() {
            let node = self
                .nodes
                .get(indexes[level])
                .ok_or("suffix node outside bounds")?;
            let total = node
                .zero
                .checked_add(node.one)
                .ok_or("suffix node total overflow")?;
            if total > MAX_OBSERVATIONS {
                return Err("suffix node observation cap exceeded".into());
            }
            if total >= MIN_OBSERVATIONS {
                selected = level;
                break;
            }
        }
        let node = self
            .nodes
            .get(indexes[selected])
            .ok_or("suffix node outside bounds")?;
        let (zero, _, _) = table.kt(node.zero, node.one).map_err(|e| e.to_string())?;
        if !(1..Q).contains(&zero) {
            return Err("suffix Q32 probability outside bounds".into());
        }
        #[cfg(khc_light_path_audit)]
        LAST_SELECTED.with(|slot| slot.set(selected));
        Ok(Prediction {
            indexes,
            zero,
            history: self.history,
            observations: self.observations,
            class,
        })
    }

    fn update(&mut self, prediction: &Prediction, bit: bool) -> Result<()> {
        if prediction.history != self.history || prediction.observations != self.observations {
            return Err("suffix stale prediction".into());
        }
        let after = self
            .observations
            .checked_add(1)
            .ok_or("suffix class observation overflow")?;
        if after > MAX_OBSERVATIONS {
            return Err("suffix class observation cap exceeded".into());
        }
        // 全contextは観測後に進める。選択されたexpertだけを学習する方式ではない。
        for level in (0..LEVELS).rev() {
            let node = self
                .nodes
                .get_mut(prediction.indexes[level])
                .ok_or("suffix update node outside bounds")?;
            let count = if bit { &mut node.one } else { &mut node.zero };
            *count = count.checked_add(1).ok_or("suffix node count overflow")?;
            let total = node
                .zero
                .checked_add(node.one)
                .ok_or("suffix updated node total overflow")?;
            if total > MAX_OBSERVATIONS {
                return Err("suffix node observation cap exceeded".into());
            }
        }
        self.observations = after;
        self.history = (self.history << 1) | u16::from(bit);
        Ok(())
    }
}

pub(super) struct Model {
    trees: [Tree; CLASSES],
    table: exact_kt::KtTable,
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
            table: exact_kt::KtTable::new().map_err(|e| e.to_string())?,
        })
    }
    pub(super) fn predict(&self, class: u32) -> Result<Prediction> {
        self.trees
            .get(class as usize)
            .ok_or("suffix class outside bounds")?
            .predict(&self.table, class)
    }
    pub(super) fn update(&mut self, class: u32, prediction: &Prediction, bit: bool) -> Result<()> {
        if prediction.class != class {
            return Err("suffix prediction class mismatch".into());
        }
        self.trees
            .get_mut(class as usize)
            .ok_or("suffix class outside bounds")?
            .update(prediction, bit)
    }
}

#[cfg(khc_light_path_audit)]
std::thread_local! { static LAST_SELECTED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) }; }
#[cfg(khc_light_path_audit)]
pub(super) fn audit_index(history: u16, level: usize) -> Result<usize> {
    if level > DEPTH { return Err("suffix level outside bounds".into()); }
    let mut index = 0_usize;
    for bit in 0..level {
        index = index.checked_mul(2).and_then(|n| n.checked_add(1 + usize::from((history >> bit) & 1)))
            .ok_or("suffix path index overflow")?;
    }
    Ok(index)
}
#[cfg(khc_light_path_audit)]
impl Model {
    pub(super) fn audit_layout() -> (usize, usize) {
        (std::mem::size_of::<Prediction>(), std::mem::size_of::<Node>())
    }
    pub(super) fn audit_step(&mut self, class: u32, bit: bool) -> Result<[u64; 72]> {
        let p = self.predict(class)?;
        let selected = LAST_SELECTED.with(|slot| slot.get());
        self.update(class, &p, bit)?;
        let tree = self.trees.get(class as usize).ok_or("suffix class outside bounds")?;
        let mut state = [0; 72];
        for level in 0..LEVELS {
            let index = p.indexes[level];
            let node = tree.nodes.get(index).ok_or("suffix node outside bounds")?;
            let zero = node.zero;
            let total = node.zero.checked_add(node.one).ok_or("suffix node total overflow")?;
            state[level * 4..level * 4 + 4].copy_from_slice(&[
                index as u64, u64::from(zero), u64::from(node.one), u64::from(total)]);
        }
        state[68..].copy_from_slice(&[p.zero, u64::from(tree.history), u64::from(tree.observations), selected as u64]);
        Ok(state)
    }
    pub(super) fn audit_snapshot(&self, class: u32) -> Result<[u64; 70]> {
        let tree = self.trees.get(class as usize).ok_or("suffix class outside bounds")?;
        let mut state = [0; 70];
        for level in 0..LEVELS {
            let index = audit_index(tree.history, level)?;
            let node = tree.nodes.get(index).ok_or("suffix node outside bounds")?;
            let zero = node.zero;
            let total = node.zero.checked_add(node.one).ok_or("suffix node total overflow")?;
            state[level * 4..level * 4 + 4].copy_from_slice(&[index as u64, u64::from(zero), u64::from(node.one), u64::from(total)]);
        }
        state[68..].copy_from_slice(&[u64::from(tree.history), u64::from(tree.observations)]);
        Ok(state)
    }
    pub(super) fn audit_set_class_cap(&mut self, class: u32) -> Result<()> {
        self.trees.get_mut(class as usize).ok_or("suffix class outside bounds")?.observations = MAX_OBSERVATIONS;
        Ok(())
    }
}
