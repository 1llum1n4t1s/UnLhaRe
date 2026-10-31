//! root端点lookupと、固定木の葉quota付き整数区間によるKHT1専用CDF。
use super::{Result, packet::Forest, program::Program, root_table::RootTables};

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

// DECODEでslot探索と既知symbol探索を別の機械コードへ専用化する。
fn walk<const DECODE: bool>(roots: &mut RootTables<'_>, program: &Program, c: usize, limit: usize, histories: &mut [u16; 6], target: usize) -> Result<Token> {
    validate(c, limit, histories)?;
    if (DECODE && target >= TOTAL as usize) || (!DECODE && target >= limit) {
        return Err("tree span target".into());
    }
    let mut local = *histories;
    let (instruction, k) = program.node(c, 0, limit)?;
    if instruction.class >= 3 || !(1..=4).contains(&k) {
        return Err("tree span class/prefix".into());
    }
    let class = c * 3 + usize::from(instruction.class);
    let (ends, root_k) = roots.lookup(c, limit, local[class])?;
    if root_k != k || class != c * 3 {
        return Err("tree span root class/prefix".into());
    }
    // 固定Programのroot child0/1は本来の葉。supportで切られた内部辺とは区別する。
    let child = if DECODE {
        if target < ends[0] as usize {
            0
        } else if k > 1 && target < ends[1] as usize {
            1
        } else {
            (2..k).find(|&child| target < ends[child] as usize).ok_or("tree span child selection")?
        }
    } else if target < 2 {
        target
    } else {
        (2..k)
            .find(|&child| {
                let (a, b, _) = instruction.child(child, limit);
                a <= target && target < b
            })
            .ok_or("tree span child selection")?
    };
    let child_start = if child == 0 { 0 } else { ends[child - 1] };
    let child_end = ends[child];
    local[class] = ((local[class] << 2) | child as u16) & 1023;
    let mut implicit = usize::from(k == 1);
    if child < 2 {
        *histories = local;
        return Ok(Token {
            symbol: child,
            cumulative: child_start,
            frequency: child_end - child_start,
            branches: 1,
            implicit,
        });
    }
    let (mut lo, mut hi, next) = instruction.child(child, limit);
    let mut node = next.ok_or("tree span forward node/depth")?;
    if node == 0 || node >= 142 {
        return Err("tree span forward node/depth".into());
    }
    let (mut start, mut end) = (child_start, child_end);
    // rootで更新した履歴とwindowをdepth1へ渡す。単位区間へのclippingでもnextを辿る。
    for depth in 1..8 {
        if lo >= hi || hi > limit || start >= end || end > TOTAL || end - start < (hi - lo) as u32 {
            return Err("tree span subtree/window".into());
        }
        let extra = end - start - (hi - lo) as u32;
        let (instruction, k) = program.node(c, node, limit)?;
        if instruction.class >= 3 || !(1..=4).contains(&k) {
            return Err("tree span class/prefix".into());
        }
        let class = c * 3 + usize::from(instruction.class);
        let mut chosen = None;
        let row = roots.frequencies(c, node, k, local[class])?;
        let mut cumulative = 0u32;
        let mut previous_end = start;
        for (child, &frequency) in row.iter().enumerate().take(k) {
            let (a, b, next) = instruction.child(child, limit);
            let after = cumulative + u32::from(frequency);
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
        // clipping後に単位区間になっても元のnextを保持し、k1履歴更新を省かない。
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

pub(crate) fn encode(roots: &mut RootTables<'_>, program: &Program, c: usize, limit: usize, symbol: usize, histories: &mut [u16; 6]) -> Result<Token> {
    walk::<false>(roots, program, c, limit, histories, symbol)
}

pub(crate) fn decode(roots: &mut RootTables<'_>, program: &Program, c: usize, limit: usize, histories: &mut [u16; 6], slot: u32) -> Result<Token> {
    walk::<true>(roots, program, c, limit, histories, slot as usize)
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
        let row = if k == 1 {
            [32768, 0, 0, 0]
        } else {
            forest.lookup(c, node, k, histories[class])?
        };
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

/// 全葉の独立oracle一致、隣接性、両端slotと履歴を検証する。
pub(crate) fn finite_partition(roots: &mut RootTables<'_>, program: &Program, c: usize, limit: usize, initial: [u16; 6]) -> Result<usize> {
    validate(c, limit, &initial)?;
    if limit == 1 {
        let mut history = initial;
        if decode(roots, program, c, limit, &mut history, TOTAL).is_ok()
            || history != initial
            || encode(roots, program, c, limit, limit, &mut history).is_ok()
            || history != initial
            || decode(roots, program, 2, limit, &mut history, 0).is_ok()
            || history != initial
            || decode(roots, program, c, 0, &mut history, 0).is_ok()
            || history != initial
            || decode(roots, program, c, 258, &mut history, 0).is_ok()
            || history != initial
        {
            return Err("compiled walk entry guard/history commit".into());
        }
        let mut invalid_history = [1024; 6];
        if decode(roots, program, c, limit, &mut invalid_history, 0).is_ok() || invalid_history != [1024; 6] {
            return Err("compiled walk invalid history accepted/mutated".into());
        }
        let before = (roots.built_supports(), roots.capacity_bytes());
        if roots.lookup(2, limit, 0).is_ok()
            || roots.lookup(c, 0, 0).is_ok()
            || roots.lookup(c, 258, 0).is_ok()
            || roots.lookup(c, limit, 1024).is_ok()
            || (roots.built_supports(), roots.capacity_bytes()) != before
        {
            return Err("root table invalid lookup accepted/mutated".into());
        }
    }
    let tree = super::grammar::Tree::new(if c == 0 { 257 } else { 256 });
    let before = roots.built_supports();
    let (_, root_k) = roots.lookup(c, limit, initial[c * 3])?;
    if roots.built_supports() != before {
        // 初使用supportの全1024historyを、Programとは独立したTree辺で検証する。
        let expected_k = tree.prefix(0, limit)?;
        if root_k != expected_k || tree.class(0)? != 0 {
            return Err("root table independent root class/prefix".into());
        }
        for history in 0..1024u16 {
            let (actual, k) = roots.lookup(c, limit, history)?;
            if k != expected_k {
                return Err("root table independent prefix".into());
            }
            let row = if k == 1 {
                [32768, 0, 0, 0]
            } else {
                {
                    let expected_row = roots.forest().lookup(c, 0, k, history)?;
                    let (interned_row, row_id) = roots.dictionary_row(c, k, history)?;
                    if interned_row != expected_row || usize::from(row_id) >= roots.dictionary_rows(c, k)? {
                        return Err("exact root dictionary row/ID mismatch".into());
                    }
                    expected_row
                }
            };
            let mut expected = [0u32; 4];
            let mut cumulative = 0u128;
            for child in 0..k {
                let edge = tree.edge(0, child, k)?;
                cumulative += u128::from(row[child]);
                expected[child] = u32::try_from(edge.hi.min(limit) as u128 + (u128::from(TOTAL) - limit as u128) * cumulative / u128::from(BRANCH_TOTAL))
                    .map_err(|_| "root table independent endpoint overflow")?;
            }
            if actual != expected {
                return Err(format!("root table independent row {c}/{limit}/{history}"));
            }
        }
    }
    roots.validate_capacity()?;
    let expected_capacity = std::mem::size_of::<RootTables<'_>>() + roots.dictionary_capacity_bytes() + roots.endpoint_rows() * std::mem::size_of::<[u32; 4]>();
    if roots.capacity_bytes() != expected_capacity
        || roots.peak_capacity_bytes() < expected_capacity
        || roots.peak_capacity_bytes() > super::root_table::ROOT_TABLE_CAPACITY_BOUND
    {
        return Err("root table actual capacity/bound".into());
    }
    let mut previous_end = 0;
    for symbol in 0..limit {
        let mut encoded_history = initial;
        let encoded = encode(roots, program, c, limit, symbol, &mut encoded_history)?;
        let mut reference_history = initial;
        let expected = reference(roots.forest(), &tree, c, limit, symbol, &mut reference_history)?;
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
            let decoded = decode(roots, program, c, limit, &mut decoded_history, slot)?;
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
