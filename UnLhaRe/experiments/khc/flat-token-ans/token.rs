//! 固定木の条件付き確率を、履歴を保ったまま葉の単一区間へ合成する。
use super::{Result, packet::Forest, program::Program};

pub(crate) const TOTAL: u32 = 1 << 18;
const MASS: u128 = 1u128 << 120;
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
        return Err("flat token component/support".into());
    }
    if histories.iter().any(|&h| h > 1023) {
        return Err("flat token history".into());
    }
    Ok(())
}

fn frequencies(forest: &Forest, c: usize, node: usize, k: usize, history: u16) -> Result<[u16; 4]> {
    if !(1..=4).contains(&k) {
        return Err("flat token prefix".into());
    }
    // Forest は k>=2 の表だけを持つ。k1 も通常どおり履歴を更新する。
    let row = if k == 1 {
        [32768, 0, 0, 0]
    } else {
        forest.lookup(c, node, k, history)?
    };
    if row[..k].contains(&0)
        || row[k..].iter().any(|&f| f != 0)
        || row.iter().map(|&f| u32::from(f)).sum::<u32>() != BRANCH_TOTAL
    {
        return Err("flat token frequency support/total/tail".into());
    }
    Ok(row)
}

fn cut(ordinal: usize, limit: usize, num: u128, bits: usize) -> Result<u32> {
    if limit == 0
        || limit > 257
        || ordinal > limit
        || !(15..=120).contains(&bits)
        || bits % 15 != 0
        || num > 1u128 << bits
    {
        return Err("flat token cut bounds".into());
    }
    let multiplier = TOTAL - limit as u32;
    // 積は順に63bit未満、123bit未満。120bit分母だけcarry式を使う。
    let scaled = if bits <= 45 {
        u128::from((num as u64 * u64::from(multiplier)) >> bits)
    } else if bits <= 105 {
        (num * u128::from(multiplier)) >> bits
    } else {
        let multiplier = u128::from(multiplier);
        let carry = (u128::from(num as u64) * multiplier) >> 64;
        let top = (num >> 64) * multiplier + carry;
        top >> (bits - 64)
    };
    let scaled = u32::try_from(scaled).map_err(|_| "flat token cut conversion")?;
    let result = (ordinal as u32)
        .checked_add(scaled)
        .ok_or("flat token cut overflow")?;
    if result > TOTAL {
        return Err("flat token cut total".into());
    }
    Ok(result)
}

#[derive(Clone, Copy)]
enum Target {
    Symbol(usize),
    Slot(u32),
}

fn walk(
    forest: &Forest,
    program: &Program,
    c: usize,
    limit: usize,
    histories: &mut [u16; 6],
    target: Target,
) -> Result<Token> {
    validate(c, limit, histories)?;
    match target {
        Target::Symbol(symbol) if symbol >= limit => {
            return Err("flat token symbol".into());
        }
        Target::Slot(slot) if slot >= TOTAL => return Err("flat token slot".into()),
        _ => {}
    }
    // 失敗時には呼び出し側の履歴を変更しない。
    let mut local = *histories;
    let (mut node, mut lo, mut hi) = (0usize, 0usize, limit);
    let (mut before, mut amount) = (0u128, 1u128);
    let mut implicit = 0;
    for depth in 0..8 {
        let denominator = 1u128 << (depth * 15);
        if lo >= hi
            || hi > limit
            || amount == 0
            || amount > denominator
            || before > denominator - amount
        {
            return Err("flat token subtree bounds".into());
        }
        let (instruction, k) = program.node(c, node, limit)?;
        let class = usize::from(instruction.class);
        if class >= 3 || instruction.step(0)?.0 != lo {
            return Err("flat token class/geometry".into());
        }
        let class = c * 3 + class;
        let row = frequencies(forest, c, node, k, local[class])?;
        let bits = (depth + 1) * 15;
        let child_denominator = denominator << 15;
        let mut prefix = 0u32;
        let mut chosen = None;
        for (child, &frequency) in row.iter().enumerate().take(k) {
            let (child_lo, next) = instruction.step(child)?;
            let child_hi = if child + 1 < k {
                instruction.step(child + 1)?.0
            } else {
                hi
            };
            if child_lo < lo || child_lo >= child_hi || child_hi > hi {
                return Err("flat token child geometry".into());
            }
            // 分母も15bit増やす。深さ4までは各分子と和が2^60以下。
            let (child_before, child_amount) = if depth < 4 {
                (
                    u128::from(((before as u64) << 15) + amount as u64 * u64::from(prefix)),
                    u128::from(amount as u64 * u64::from(frequency)),
                )
            } else {
                (
                    (before << 15) + amount * u128::from(prefix),
                    amount * u128::from(frequency),
                )
            };
            if child_amount == 0
                || child_amount > child_denominator
                || child_before > child_denominator - child_amount
            {
                return Err("flat token child mass".into());
            }
            let selected = match target {
                Target::Symbol(symbol) => child_lo <= symbol && symbol < child_hi,
                Target::Slot(slot) => {
                    let start = cut(child_lo, limit, child_before, bits)?;
                    let end = cut(child_hi, limit, child_before + child_amount, bits)?;
                    if start >= end {
                        return Err("flat token subtree interval".into());
                    }
                    start <= slot && slot < end
                }
            };
            if selected {
                chosen = Some((child, child_lo, child_hi, next, child_before, child_amount));
                break;
            }
            prefix += u32::from(frequency);
        }
        let (child, child_lo, child_hi, next, child_before, child_amount) =
            chosen.ok_or("flat token child selection")?;
        local[class] = ((local[class] << 2) | child as u16) & 1023;
        implicit += usize::from(k == 1);
        match next {
            Some(next) => {
                if next <= node || next >= 142 || depth == 7 {
                    return Err("flat token forward node/depth".into());
                }
                node = next;
                lo = child_lo;
                hi = child_hi;
                before = child_before;
                amount = child_amount;
            }
            None => {
                if child_hi != child_lo + 1 {
                    return Err("flat token terminal geometry".into());
                }
                let start = cut(child_lo, limit, child_before, bits)?;
                let end = cut(child_hi, limit, child_before + child_amount, bits)?;
                if start >= end {
                    return Err("flat token leaf interval".into());
                }
                if let Target::Slot(slot) = target {
                    if slot < start || slot >= end {
                        return Err("flat token leaf slot".into());
                    }
                }
                *histories = local;
                return Ok(Token {
                    symbol: child_lo,
                    cumulative: start,
                    frequency: end - start,
                    branches: depth + 1,
                    implicit,
                });
            }
        }
    }
    Err("flat token depth".into())
}

pub(crate) fn encode(
    forest: &Forest,
    program: &Program,
    c: usize,
    limit: usize,
    symbol: usize,
    histories: &mut [u16; 6],
) -> Result<Token> {
    walk(forest, program, c, limit, histories, Target::Symbol(symbol))
}

pub(crate) fn decode(
    forest: &Forest,
    program: &Program,
    c: usize,
    limit: usize,
    histories: &mut [u16; 6],
    slot: u32,
) -> Result<Token> {
    walk(forest, program, c, limit, histories, Target::Slot(slot))
}

// wide limb 式に依存しない既存 arithmetic witness の double/add/divide oracle。
fn slow_scaled(mass: u128, multiplier: u32) -> Result<u32> {
    if mass > MASS || multiplier >= TOTAL {
        return Err("flat token oracle bounds".into());
    }
    let (mut remainder, mut quotient) = (0u128, 0u32);
    for bit in (0..18).rev() {
        remainder *= 2;
        if multiplier & (1 << bit) != 0 {
            remainder += mass;
        }
        quotient = quotient * 2 + (remainder >> 120) as u32;
        remainder &= MASS - 1;
    }
    Ok(quotient)
}

fn reference(
    forest: &Forest,
    tree: &super::grammar::Tree,
    c: usize,
    limit: usize,
    symbol: usize,
    histories: &mut [u16; 6],
) -> Result<Token> {
    let (mut before, mut amount) = (0u128, MASS);
    let (mut node, mut implicit) = (0usize, 0usize);
    for depth in 0..8 {
        let k = tree.prefix(node, limit)?;
        let child = tree.known_child(node, symbol, limit)?;
        let edge = tree.edge(node, child, k)?;
        let class = tree.class(node)?;
        if class >= 3 || amount & (u128::from(BRANCH_TOTAL) - 1) != 0 {
            return Err("flat token reference class/divisibility".into());
        }
        let class = c * 3 + class;
        let row = frequencies(forest, c, node, k, histories[class])?;
        let cumulative = row[..child].iter().map(|&f| u32::from(f)).sum::<u32>();
        let scale = amount / u128::from(BRANCH_TOTAL);
        before += scale * u128::from(cumulative);
        amount = scale * u128::from(row[child]);
        if amount == 0 || before > MASS - amount {
            return Err("flat token reference mass".into());
        }
        histories[class] = ((histories[class] << 2) | child as u16) & 1023;
        implicit += usize::from(k == 1);
        match edge.node {
            Some(next) => {
                if next <= node || depth == 7 {
                    return Err("flat token reference forward/depth".into());
                }
                node = next;
            }
            None => {
                if edge.lo != symbol || edge.hi != symbol + 1 {
                    return Err("flat token reference leaf".into());
                }
                let multiplier = TOTAL - limit as u32;
                let start = symbol as u32 + slow_scaled(before, multiplier)?;
                let end = symbol as u32 + 1 + slow_scaled(before + amount, multiplier)?;
                if start >= end || end > TOTAL {
                    return Err("flat token reference interval".into());
                }
                return Ok(Token {
                    symbol,
                    cumulative: start,
                    frequency: end - start,
                    branches: depth + 1,
                    implicit,
                });
            }
        }
    }
    Err("flat token reference depth".into())
}

/// その support の全葉を検証し、検証済み葉数を返す。速度の証拠にはしない。
pub(crate) fn finite_partition(
    forest: &Forest,
    program: &Program,
    c: usize,
    limit: usize,
    initial: [u16; 6],
) -> Result<usize> {
    validate(c, limit, &initial)?;
    let tree = super::grammar::Tree::new(if c == 0 { 257 } else { 256 });
    let mut previous_end = 0;
    for symbol in 0..limit {
        let mut encoded_history = initial;
        let encoded = encode(forest, program, c, limit, symbol, &mut encoded_history)?;
        let mut reference_history = initial;
        let expected = reference(forest, &tree, c, limit, symbol, &mut reference_history)?;
        if encoded != expected || encoded_history != reference_history {
            return Err(format!(
                "flat token independent leaf/history {c}/{limit}/{symbol}"
            ));
        }
        if encoded.cumulative != previous_end || encoded.frequency == 0 {
            return Err(format!(
                "flat token partition adjacency {c}/{limit}/{symbol}"
            ));
        }
        previous_end = encoded
            .cumulative
            .checked_add(encoded.frequency)
            .ok_or("flat token partition overflow")?;
        if previous_end > TOTAL {
            return Err("flat token partition extent".into());
        }
        for slot in [encoded.cumulative, previous_end - 1] {
            let mut decoded_history = initial;
            let decoded = decode(forest, program, c, limit, &mut decoded_history, slot)?;
            if decoded != encoded || decoded_history != reference_history {
                return Err(format!(
                    "flat token endpoint/history {c}/{limit}/{symbol}/{slot}"
                ));
            }
        }
    }
    if previous_end != TOTAL {
        return Err("flat token partition terminal".into());
    }
    Ok(limit)
}
