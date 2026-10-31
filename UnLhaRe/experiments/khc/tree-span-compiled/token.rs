//! 固定木を葉の最小quota付き整数区間へ投影する、KHT1専用CDF。
use super::{Result, packet::Forest, program::Program};

pub(crate) const TOTAL: u32 = 1 << 18;
const BRANCH_TOTAL: u32 = 1 << 15;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Token {
    pub symbol: usize,
    pub cumulative: u32,
    pub frequency: u32,
    pub branches: usize,
    pub implicit: usize,
}

fn validate(c: usize, limit: usize, histories: &[u16; 6]) -> Result<()> {
    if c >= 2 || limit == 0 || limit > if c == 0 { 257 } else { 256 } {
        return Err("tree span component/support".into());
    }
    if histories.iter().any(|&h| h > 1023) {
        return Err("tree span history".into());
    }
    Ok(())
}

fn frequencies(forest: &Forest, c: usize, node: usize, k: usize, history: u16) -> Result<[u16; 4]> {
    if !(1..=4).contains(&k) {
        return Err("tree span prefix".into());
    }
    // k1にはForestの表がないが、そのclassの履歴は毎回更新する。
    if k == 1 {
        Ok([32768, 0, 0, 0])
    } else {
        // raw Forestのprivate fieldsは成功したparseのみが生成し、全履歴の
        // f>=2/合計32768/tail0を検査済み。ここで同じ検査を繰り返さない。
        // into_decodeは別型なので、累積CDFをraw rowとして渡すことはできない。
        forest.lookup(c, node, k, history)
    }
}

// DECODEでslot探索と既知symbol探索を別の機械コードへ専用化する。
fn walk<const DECODE: bool>(forest: &Forest, program: &Program, c: usize, limit: usize, histories: &mut [u16; 6], target: usize) -> Result<Token> {
    validate(c, limit, histories)?;
    if (DECODE && target >= TOTAL as usize) || (!DECODE && target >= limit) {
        return Err("tree span target".into());
    }
    let mut local = *histories;
    let (mut node, mut lo, mut hi) = (0usize, 0usize, limit);
    let (mut start, mut end) = (0u32, TOTAL);
    let mut implicit = 0;
    for depth in 0..8 {
        // 選択した経路の入力windowは引き続き検査する。
        if lo >= hi || hi > limit || start >= end || end > TOTAL || end - start < (hi - lo) as u32 {
            return Err("tree span subtree/window".into());
        }
        let extra = end - start - (hi - lo) as u32;
        let (instruction, k) = program.node(c, node, limit)?;
        let class = c * 3 + usize::from(instruction.class);
        let row = frequencies(forest, c, node, k, local[class])?;
        let mut cumulative = 0u32;
        let mut previous_end = start;
        let mut chosen = None;
        for (child, &frequency) in row.iter().enumerate().take(k) {
            let (a, b, next) = instruction.child(child, limit);
            let after = cumulative + u32::from(frequency);
            // immutable Programの完全被覆/昇順と検査済みrowからquota/単調性が成立。
            let project = |ordinal: usize, prefix: u32| start + (ordinal - lo) as u32 + ((u64::from(extra) * u64::from(prefix)) >> 15) as u32;
            let interval = if DECODE {
                let child_end = if child + 1 == k { end } else { project(b, after) };
                let child_start = previous_end;
                previous_end = child_end;
                (target < child_end as usize).then_some((child_start, child_end))
            } else if a <= target && target < b {
                Some((
                    if child == 0 { start } else { project(a, cumulative) },
                    if child + 1 == k { end } else { project(b, after) },
                ))
            } else {
                None
            };
            if let Some((child_start, child_end)) = interval {
                chosen = Some((child, a, b, next, child_start, child_end));
                break;
            }
            cumulative = after;
        }
        let (child, a, b, next, child_start, child_end) = chosen.ok_or("tree span child selection")?;
        local[class] = ((local[class] << 2) | child as u16) & 1023;
        implicit += usize::from(k == 1);
        match next {
            Some(next) => {
                if next <= node || next >= 142 || depth == 7 {
                    return Err("tree span forward node/depth".into());
                }
                node = next;
                lo = a;
                hi = b;
                start = child_start;
                end = child_end;
            }
            None => {
                // terminalの単位区間はconst構築でassert済み、slotは入口と親選択で保持。
                *histories = local;
                return Ok(Token {
                    symbol: a,
                    cumulative: child_start,
                    frequency: child_end - child_start,
                    branches: depth + 1,
                    implicit,
                });
            }
        }
    }
    Err("tree span depth".into())
}

pub(crate) fn encode(forest: &Forest, program: &Program, c: usize, limit: usize, symbol: usize, histories: &mut [u16; 6]) -> Result<Token> {
    walk::<false>(forest, program, c, limit, histories, symbol)
}

pub(crate) fn decode(forest: &Forest, program: &Program, c: usize, limit: usize, histories: &mut [u16; 6], slot: u32) -> Result<Token> {
    walk::<true>(forest, program, c, limit, histories, slot as usize)
}

// Programの命令表とu64 shift式から独立した、Tree辺とu128除算のoracle。
fn reference(forest: &Forest, tree: &super::grammar::Tree, c: usize, limit: usize, symbol: usize, histories: &mut [u16; 6]) -> Result<Token> {
    let (mut node, mut lo, mut hi) = (0usize, 0usize, limit);
    let (mut start, mut end) = (0u128, u128::from(TOTAL));
    let mut implicit = 0;
    for depth in 0..8 {
        if lo >= hi || hi > limit || start >= end || end > u128::from(TOTAL) || end - start < (hi - lo) as u128 {
            return Err("tree span reference subtree/window".into());
        }
        let k = tree.prefix(node, limit)?;
        let child = tree.known_child(node, symbol, limit)?;
        let edge = tree.edge(node, child, k)?;
        let a = edge.lo;
        let b = edge.hi.min(limit);
        let class = tree.class(node)?;
        if class >= 3 || tree.edge(node, 0, k)?.lo != lo || a < lo || a >= b || b > hi {
            return Err("tree span reference class/geometry".into());
        }
        let class = c * 3 + class;
        let row = frequencies(forest, c, node, k, histories[class])?;
        let cumulative = row[..child].iter().map(|&f| u128::from(f)).sum::<u128>();
        let after = cumulative + u128::from(row[child]);
        let extra = end - start - (hi - lo) as u128;
        let child_start = start + (a - lo) as u128 + extra * cumulative / u128::from(BRANCH_TOTAL);
        let child_end = start + (b - lo) as u128 + extra * after / u128::from(BRANCH_TOTAL);
        if child_start < start || child_start >= child_end || child_end > end || child_end - child_start < (b - a) as u128 {
            return Err("tree span reference child window".into());
        }
        histories[class] = ((histories[class] << 2) | child as u16) & 1023;
        implicit += usize::from(k == 1);
        match edge.node {
            Some(next) => {
                if next <= node || next >= tree.node_count() || depth == 7 {
                    return Err("tree span reference forward/depth".into());
                }
                node = next;
                lo = a;
                hi = b;
                start = child_start;
                end = child_end;
            }
            None => {
                if a != symbol || b != symbol + 1 {
                    return Err("tree span reference leaf".into());
                }
                return Ok(Token {
                    symbol,
                    cumulative: u32::try_from(child_start).map_err(|_| "tree span reference start")?,
                    frequency: u32::try_from(child_end - child_start).map_err(|_| "tree span reference frequency")?,
                    branches: depth + 1,
                    implicit,
                });
            }
        }
    }
    Err("tree span reference depth".into())
}

/// 全葉のoracle一致、隣接性、両端slotと履歴を検証する。速度の証拠にはしない。
pub(crate) fn finite_partition(forest: &Forest, program: &Program, c: usize, limit: usize, initial: [u16; 6]) -> Result<usize> {
    validate(c, limit, &initial)?;
    if limit == 1 {
        let mut history = initial;
        if decode(forest, program, c, limit, &mut history, TOTAL).is_ok()
            || history != initial
            || encode(forest, program, c, limit, limit, &mut history).is_ok()
            || history != initial
            || decode(forest, program, 2, limit, &mut history, 0).is_ok()
            || decode(forest, program, c, 0, &mut history, 0).is_ok()
            || decode(forest, program, c, 258, &mut history, 0).is_ok()
        {
            return Err("compiled walk entry guard/history commit".into());
        }
        let mut invalid_history = [1024; 6];
        if decode(forest, program, c, limit, &mut invalid_history, 0).is_ok() || invalid_history != [1024; 6] {
            return Err("compiled walk invalid history accepted/mutated".into());
        }
    }
    let tree = super::grammar::Tree::new(if c == 0 { 257 } else { 256 });
    let mut previous_end = 0;
    for symbol in 0..limit {
        let mut encoded_history = initial;
        let encoded = encode(forest, program, c, limit, symbol, &mut encoded_history)?;
        let mut reference_history = initial;
        let expected = reference(forest, &tree, c, limit, symbol, &mut reference_history)?;
        if encoded != expected || encoded_history != reference_history {
            return Err(format!("tree span independent leaf/history {c}/{limit}/{symbol}"));
        }
        if encoded.cumulative != previous_end || encoded.frequency == 0 {
            return Err(format!("tree span partition adjacency {c}/{limit}/{symbol}"));
        }
        previous_end = encoded.cumulative.checked_add(encoded.frequency).ok_or("tree span partition overflow")?;
        if previous_end > TOTAL {
            return Err("tree span partition extent".into());
        }
        for slot in [encoded.cumulative, previous_end - 1] {
            let mut decoded_history = initial;
            let decoded = decode(forest, program, c, limit, &mut decoded_history, slot)?;
            if decoded != encoded || decoded_history != reference_history {
                return Err(format!("tree span endpoint/history {c}/{limit}/{symbol}/{slot}"));
            }
        }
    }
    if previous_end != TOTAL {
        return Err("tree span partition terminal".into());
    }
    Ok(limit)
}
