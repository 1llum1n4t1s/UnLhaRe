//! Forestの寿命に束縛された、supportごとに連続するroot端点表。
use super::{Result, packet::Forest, program::Program};

const HISTORIES: usize = 1024;
const SUPPORTS: usize = 258;
const Q: u32 = 1 << 18;
const BRANCH_TOTAL: u32 = 1 << 15;

pub(crate) const ROOT_TABLE_CAPACITY_BOUND: usize =
    2 * SUPPORTS * HISTORIES * std::mem::size_of::<[u32; 4]>()
        + std::mem::size_of::<RootTables<'static>>();

pub(crate) struct RootTables<'f> {
    forest: &'f Forest,
    tables: [[Vec<[u32; 4]>; SUPPORTS]; 2],
}

impl<'f> RootTables<'f> {
    pub(crate) fn new(forest: &'f Forest) -> Self {
        Self {
            forest,
            tables: std::array::from_fn(|_| std::array::from_fn(|_| Vec::new())),
        }
    }

    pub(crate) fn forest(&self) -> &'f Forest {
        self.forest
    }

    pub(crate) fn frequencies(
        &self,
        c: usize,
        node: usize,
        k: usize,
        history: u16,
    ) -> Result<[u16; 4]> {
        if c >= 2 || node >= 142 || !(1..=4).contains(&k) || history >= 1024 {
            return Err("root table component/node/prefix/history".into());
        }
        if k == 1 {
            Ok([32768, 0, 0, 0])
        } else {
            self.forest.lookup(c, node, k, history)
        }
    }

    pub(crate) fn lookup(
        &mut self,
        c: usize,
        limit: usize,
        history: u16,
    ) -> Result<([u32; 4], usize)> {
        if c >= 2 || limit == 0 || limit > if c == 0 { 257 } else { 256 } || history >= 1024 {
            return Err("root table component/support/history".into());
        }
        let (instruction, k) = Program::new().node(c, 0, limit)?;
        if instruction.class != 0 || !(1..=4).contains(&k) {
            return Err("root table class/prefix".into());
        }
        if self.tables[c][limit].is_empty() {
            let mut table = Vec::new();
            table
                .try_reserve_exact(HISTORIES)
                .map_err(|_| "root table allocation")?;
            if table.capacity() != HISTORIES {
                return Err("root table exact capacity".into());
            }
            for history in 0..HISTORIES {
                let row = self.frequencies(c, 0, k, history as u16)?;
                if row[k..].iter().any(|&f| f != 0)
                    || (k > 1 && row[..k].iter().any(|&f| f < 2))
                    || row[..k].iter().map(|&f| u32::from(f)).sum::<u32>() != BRANCH_TOTAL
                {
                    return Err("root table frequency/total/tail".into());
                }
                let mut ends = [0u32; 4];
                let mut cumulative = 0u32;
                let (mut previous_ordinal, mut previous_end) = (0usize, 0u32);
                for child in 0..k {
                    let (a, b, _) = instruction.child(child, limit);
                    if a != previous_ordinal || a >= b || b > limit {
                        return Err("root table child geometry".into());
                    }
                    cumulative += u32::from(row[child]);
                    let end = if child + 1 == k {
                        Q
                    } else {
                        b as u32
                            + ((u64::from(Q - limit as u32) * u64::from(cumulative)) >> 15) as u32
                    };
                    // 全1024rowのquota、単調性、Q終端とu128除算による丸めを検査する。
                    let oracle = b as u128
                        + u128::from(Q - limit as u32) * u128::from(cumulative)
                            / u128::from(BRANCH_TOTAL);
                    if end <= previous_end
                        || end > Q
                        || end - previous_end < (b - a) as u32
                        || u128::from(end) != oracle
                    {
                        return Err("root table endpoint/quota/oracle".into());
                    }
                    ends[child] = end;
                    previous_ordinal = b;
                    previous_end = end;
                }
                if previous_ordinal != limit || previous_end != Q {
                    return Err("root table terminal".into());
                }
                // exact capacityを先に検査済み。pushは1024回だけでgrowthしない。
                table.push(ends);
            }
            self.tables[c][limit] = table;
        }
        let table = &self.tables[c][limit];
        if table.len() != HISTORIES || table.capacity() != HISTORIES {
            return Err("root table retained capacity".into());
        }
        Ok((table[usize::from(history)], k))
    }

    pub(crate) fn capacity_bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self
                .tables
                .iter()
                .flatten()
                .map(|table| table.capacity() * std::mem::size_of::<[u32; 4]>())
                .sum::<usize>()
    }

    pub(crate) fn built_supports(&self) -> usize {
        self.tables
            .iter()
            .flatten()
            .filter(|table| !table.is_empty())
            .count()
    }
}
