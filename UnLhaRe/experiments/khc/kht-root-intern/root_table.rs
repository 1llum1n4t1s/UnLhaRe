//! Forestの寿命に束縛された、完全一致辞書とsupport別のroot端点表。
use super::{
    Result,
    packet::Forest,
    program::{Instruction, Program},
};
use std::mem::size_of;

const HISTORIES: usize = 1024;
const SUPPORTS: usize = 258;
const MAX_SUPPORTS: usize = 513;
const Q: u32 = 1 << 18;
const BRANCH_TOTAL: u32 = 1 << 15;
type Frequency = [u16; 4];
type Endpoints = [u32; 4];
type HistoryRow = (Frequency, u16);

// 前候補の予約値を維持する。新managerのsizeofへ置き換えて予約を増やさない。
pub(crate) const ROOT_TABLE_CAPACITY_BOUND: usize = 8_466_536;
const DICTIONARY_HEAP_BOUND: usize = 6 * HISTORIES * size_of::<Frequency>();
const ENDPOINT_HEAP_BOUND: usize = (511 * HISTORIES + 2) * size_of::<Endpoints>();
const SORT_HEAP_BOUND: usize = HISTORIES * size_of::<HistoryRow>();
const DICTIONARY_TRANSIENT: usize = size_of::<[[Dictionary; 3]; 2]>() + size_of::<Vec<HistoryRow>>();
const ENDPOINT_TRANSIENT: usize = size_of::<Vec<Endpoints>>();
const DICTIONARY_BUILD_BOUND: usize = size_of::<RootTables<'static>>() + DICTIONARY_HEAP_BOUND + SORT_HEAP_BOUND + DICTIONARY_TRANSIENT;
const ENDPOINT_BUILD_BOUND: usize = size_of::<RootTables<'static>>() + DICTIONARY_HEAP_BOUND + ENDPOINT_HEAP_BOUND + ENDPOINT_TRANSIENT;

// 辞書は全6組をtransactionalに作り、scratchを解放してから端点表を作る。
// 二つのphaseの上限を実型サイズで証明する。sort_unstableは追加heapを使わない。
const _: () = {
    assert!(size_of::<Frequency>() == 8);
    assert!(size_of::<Endpoints>() == 16);
    assert!(size_of::<HistoryRow>() == 10);
    assert!(DICTIONARY_BUILD_BOUND <= ROOT_TABLE_CAPACITY_BOUND);
    assert!(ENDPOINT_BUILD_BOUND <= ROOT_TABLE_CAPACITY_BOUND);
};

struct Dictionary {
    rows: Vec<Frequency>,
    ids: [u16; HISTORIES],
}
impl Dictionary {
    fn empty() -> Self {
        Self {
            rows: Vec::new(),
            ids: [u16::MAX; HISTORIES],
        }
    }
}

pub(crate) struct RootTables<'f> {
    forest: &'f Forest,
    tables: [[Vec<Endpoints>; SUPPORTS]; 2],
    dictionaries: [[Dictionary; 3]; 2],
    peak_capacity: usize,
}

fn dictionary_heap(groups: &[[Dictionary; 3]; 2]) -> usize {
    groups.iter().flatten().map(|d| d.rows.capacity() * size_of::<Frequency>()).sum()
}

fn validate_row(row: Frequency, k: usize) -> Result<()> {
    if !(1..=4).contains(&k)
        || row[k..].iter().any(|&f| f != 0)
        || (k > 1 && row[..k].iter().any(|&f| f < 2))
        || row[..k].iter().map(|&f| u32::from(f)).sum::<u32>() != BRANCH_TOTAL
    {
        return Err("root dictionary frequency/total/tail".into());
    }
    Ok(())
}

impl<'f> RootTables<'f> {
    pub(crate) fn new(forest: &'f Forest) -> Self {
        Self {
            forest,
            tables: std::array::from_fn(|_| std::array::from_fn(|_| Vec::new())),
            dictionaries: std::array::from_fn(|_| std::array::from_fn(|_| Dictionary::empty())),
            peak_capacity: size_of::<Self>(),
        }
    }

    pub(crate) fn forest(&self) -> &'f Forest {
        self.forest
    }

    pub(crate) fn frequencies(&self, c: usize, node: usize, k: usize, history: u16) -> Result<Frequency> {
        if c >= 2 || node >= 142 || !(1..=4).contains(&k) || history >= 1024 {
            return Err("root table component/node/prefix/history".into());
        }
        if k == 1 {
            Ok([32768, 0, 0, 0])
        } else {
            self.forest.lookup(c, node, k, history)
        }
    }

    // retained manager、全live heap、構築中managerを予約前・予約後とも課金する。
    fn note_live(&mut self, transient: usize) -> Result<()> {
        let live = self.capacity_bytes().checked_add(transient).ok_or("root table live capacity overflow")?;
        if live > ROOT_TABLE_CAPACITY_BOUND {
            return Err("root table live capacity bound".into());
        }
        self.peak_capacity = self.peak_capacity.max(live);
        Ok(())
    }

    fn build_dictionaries(&mut self) -> Result<()> {
        // scratchとsupport表の同時生存を拒否し、phase別の上限を成立させる。
        if self.built_supports() != 0 || self.dictionaries.iter().flatten().any(|d| !d.rows.is_empty()) {
            return Err("root dictionary partial state".into());
        }
        self.validate_capacity()?;
        let mut pending: [[Dictionary; 3]; 2] = std::array::from_fn(|_| std::array::from_fn(|_| Dictionary::empty()));
        let mut pairs: Vec<HistoryRow> = Vec::new();
        self.note_live(DICTIONARY_TRANSIENT + SORT_HEAP_BOUND)?;
        pairs.try_reserve_exact(HISTORIES).map_err(|_| "root dictionary sort allocation")?;
        self.note_live(DICTIONARY_TRANSIENT + pairs.capacity() * size_of::<HistoryRow>())?;
        if pairs.capacity() != HISTORIES {
            return Err("root dictionary sort exact capacity".into());
        }
        for c in 0..2 {
            for k in 2..=4 {
                pairs.clear();
                for history in 0..HISTORIES {
                    let row = self.frequencies(c, 0, k, history as u16)?;
                    validate_row(row, k)?;
                    // capacity=1024を検査済み、pushは1024回だけでgrowthしない。
                    pairs.push((row, history as u16));
                }
                // historyも比較する全順序。等しい頻度の順序も決定的にする。
                pairs.sort_unstable();
                let distinct = 1 + pairs.windows(2).filter(|p| p[0].0 != p[1].0).count();
                if distinct == 0 || distinct > HISTORIES || distinct > usize::from(u16::MAX) {
                    return Err("root dictionary distinct/ID overflow".into());
                }
                let base = DICTIONARY_TRANSIENT + SORT_HEAP_BOUND + dictionary_heap(&pending);
                self.note_live(base + distinct * size_of::<Frequency>())?;
                let d = &mut pending[c][k - 2];
                d.rows.try_reserve_exact(distinct).map_err(|_| "root dictionary row allocation")?;
                self.note_live(base + d.rows.capacity() * size_of::<Frequency>())?;
                if d.rows.capacity() != distinct {
                    return Err("root dictionary row exact capacity".into());
                }
                for &(row, history) in &pairs {
                    if d.rows.last().copied() != Some(row) {
                        d.rows.push(row);
                    }
                    let id = u16::try_from(d.rows.len() - 1).map_err(|_| "root dictionary row ID overflow")?;
                    let slot = d.ids.get_mut(usize::from(history)).ok_or("root dictionary history")?;
                    if *slot != u16::MAX {
                        return Err("root dictionary history collision".into());
                    }
                    *slot = id;
                }
                if d.rows.len() != distinct || d.rows.capacity() != distinct || d.rows.windows(2).any(|p| p[0] >= p[1]) {
                    return Err("root dictionary canonical rows".into());
                }
                // sorted rowsとIDを全historyでForestに再照合。未割当もここで拒否。
                for history in 0..HISTORIES {
                    let actual = d.rows.get(usize::from(d.ids[history])).ok_or("root dictionary missing ID")?;
                    if *actual != self.frequencies(c, 0, k, history as u16)? {
                        return Err("root dictionary exact Forest identity".into());
                    }
                }
            }
        }
        self.note_live(DICTIONARY_TRANSIENT + SORT_HEAP_BOUND + dictionary_heap(&pending))?;
        // 全6組成功後だけcommit。関数終了でpairsと局所managerは生存しなくなる。
        self.dictionaries = pending;
        self.validate_capacity()?;
        Ok(())
    }

    pub(crate) fn lookup(&mut self, c: usize, limit: usize, history: u16) -> Result<(Endpoints, usize)> {
        // 無効入力では辞書、support、peakを一切変更しない。
        if c >= 2 || limit == 0 || limit > if c == 0 { 257 } else { 256 } || history >= 1024 {
            return Err("root table component/support/history".into());
        }
        let (instruction, k) = Program::new().node(c, 0, limit)?;
        if instruction.class != 0 || !(1..=4).contains(&k) {
            return Err("root table class/prefix".into());
        }
        if self.dictionaries[0][0].rows.is_empty() {
            self.build_dictionaries()?;
        }
        let (row_count, id) = if k == 1 {
            (1, 0)
        } else {
            let d = &self.dictionaries[c][k - 2];
            (d.rows.len(), usize::from(d.ids[usize::from(history)]))
        };
        if self.tables[c][limit].is_empty() {
            self.build_table(c, limit, instruction, k, row_count)?;
        }
        let table = &self.tables[c][limit];
        if table.len() != row_count || table.capacity() != row_count {
            return Err("root table retained capacity".into());
        }
        Ok((*table.get(id).ok_or("root table row ID")?, k))
    }

    // 初使用supportだけが全表のcapacity検査と端点構築を行う。
    fn build_table(&mut self, c: usize, limit: usize, instruction: &Instruction, k: usize, row_count: usize) -> Result<()> {
        self.validate_capacity()?;
        if self.built_supports() >= MAX_SUPPORTS || row_count == 0 || row_count > HISTORIES {
            return Err("root table support/row limit".into());
        }
        let mut table: Vec<Endpoints> = Vec::new();
        self.note_live(ENDPOINT_TRANSIENT + row_count * size_of::<Endpoints>())?;
        table.try_reserve_exact(row_count).map_err(|_| "root table allocation")?;
        self.note_live(ENDPOINT_TRANSIENT + table.capacity() * size_of::<Endpoints>())?;
        if table.capacity() != row_count {
            return Err("root table exact capacity".into());
        }
        for row_id in 0..row_count {
            let row = if k == 1 { [32768, 0, 0, 0] } else { self.dictionaries[c][k - 2].rows[row_id] };
            validate_row(row, k)?;
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
                    b as u32 + ((u64::from(Q - limit as u32) * u64::from(cumulative)) >> 15) as u32
                };
                let oracle = b as u128 + u128::from(Q - limit as u32) * u128::from(cumulative) / u128::from(BRANCH_TOTAL);
                if end <= previous_end || end > Q || end - previous_end < (b - a) as u32 || u128::from(end) != oracle {
                    return Err("root table endpoint/quota/oracle".into());
                }
                ends[child] = end;
                previous_ordinal = b;
                previous_end = end;
            }
            if previous_ordinal != limit || previous_end != Q {
                return Err("root table terminal".into());
            }
            // exact capacityを先に検査済み、pushはrow_count回だけ。
            table.push(ends);
        }
        self.tables[c][limit] = table;
        self.validate_capacity()?;
        Ok(())
    }

    pub(crate) fn dictionary_rows(&self, c: usize, k: usize) -> Result<usize> {
        if c >= 2 || !(1..=4).contains(&k) {
            return Err("root dictionary component/prefix".into());
        }
        Ok(if k == 1 { 1 } else { self.dictionaries[c][k - 2].rows.len() })
    }

    pub(crate) fn dictionary_row(&self, c: usize, k: usize, history: u16) -> Result<(Frequency, u16)> {
        if c >= 2 || !(1..=4).contains(&k) || history >= 1024 {
            return Err("root dictionary component/prefix/history".into());
        }
        if k == 1 {
            return Ok(([32768, 0, 0, 0], 0));
        }
        let d = &self.dictionaries[c][k - 2];
        let id = d.ids[usize::from(history)];
        Ok((*d.rows.get(usize::from(id)).ok_or("root dictionary missing ID")?, id))
    }

    pub(crate) fn dictionary_capacity_bytes(&self) -> usize {
        dictionary_heap(&self.dictionaries)
    }
    pub(crate) fn endpoint_rows(&self) -> usize {
        self.tables.iter().flatten().map(Vec::len).sum()
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        size_of::<Self>() + self.dictionary_capacity_bytes() + self.tables.iter().flatten().map(|t| t.capacity() * size_of::<Endpoints>()).sum::<usize>()
    }
    pub(crate) fn peak_capacity_bytes(&self) -> usize {
        self.peak_capacity
    }
    pub(crate) fn built_supports(&self) -> usize {
        self.tables.iter().flatten().filter(|t| !t.is_empty()).count()
    }

    pub(crate) fn validate_capacity(&self) -> Result<()> {
        let built = self.dictionaries.iter().flatten().filter(|d| !d.rows.is_empty()).count();
        if built != 0 && built != 6 {
            return Err("root dictionary partial commit".into());
        }
        for d in self.dictionaries.iter().flatten() {
            if d.rows.len() > HISTORIES || d.rows.capacity() != d.rows.len() {
                return Err("root dictionary retained capacity".into());
            }
        }
        for c in 0..2 {
            for limit in 0..SUPPORTS {
                let table = &self.tables[c][limit];
                if table.is_empty() {
                    if table.capacity() != 0 {
                        return Err("root table empty allocation".into());
                    }
                    continue;
                }
                if built != 6 {
                    return Err("root table missing dictionaries".into());
                }
                let (_, k) = Program::new().node(c, 0, limit)?;
                let expected = self.dictionary_rows(c, k)?;
                if table.len() != expected || table.capacity() != expected {
                    return Err("root table retained row count".into());
                }
            }
        }
        let retained = self.capacity_bytes();
        if self.built_supports() > MAX_SUPPORTS
            || self.endpoint_rows() > 511 * HISTORIES + 2
            || self.dictionary_capacity_bytes() > DICTIONARY_HEAP_BOUND
            || retained > ROOT_TABLE_CAPACITY_BOUND
            || self.peak_capacity < retained
            || self.peak_capacity > ROOT_TABLE_CAPACITY_BOUND
        {
            return Err("root table retained/peak capacity bound".into());
        }
        Ok(())
    }
}
