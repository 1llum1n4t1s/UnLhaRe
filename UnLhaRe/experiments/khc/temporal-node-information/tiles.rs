use crate::{counts, model};
type Result<T> = std::result::Result<T, String>;
pub const WIDTH: usize = 65536;
pub const TILES: usize = 14;
pub const MAX_RUNS: usize = 889227;

#[derive(Clone, Copy, Default)]
pub struct Loss { pub sum: f64, correction: f64 }
impl Loss {
    pub fn add(&mut self, value: f64) -> Result<()> {
        if !value.is_finite() || value < 0.0 { return Err("loss finite/range".into()); }
        let y = value - self.correction;
        let next = self.sum + y;
        if !next.is_finite() { return Err("loss total finite".into()); }
        self.correction = (next - self.sum) - y;
        self.sum = next;
        Ok(())
    }
}
#[derive(Clone, Copy, Default)]
pub struct Stat {
    pub count: u64, pub active: u64, pub pure: u64, pub cells: u64,
    pub empirical: Loss, pub quantized: Loss,
}
impl Stat {
    pub fn merge(&mut self, other: Self) -> Result<()> {
        self.count = self.count.checked_add(other.count).ok_or("stat count overflow")?;
        self.active = self.active.checked_add(other.active).ok_or("stat active overflow")?;
        self.pure = self.pure.checked_add(other.pure).ok_or("stat pure overflow")?;
        self.cells = self.cells.checked_add(other.cells).ok_or("stat cells overflow")?;
        self.empirical.add(other.empirical.sum)?;
        self.quantized.add(other.quantized.sum)
    }
}
pub fn frequency(row: [u32; 4], k: usize) -> Result<[u16; 4]> {
    let q = model::quantize(row, k)?;
    if q[..k].iter().any(|&v| v < 2) || q[k..].iter().any(|&v| v != 0)
        || q[..k].iter().map(|&v| u32::from(v)).sum::<u32>() != 32768 {
        return Err("Q support/total/tail".into());
    }
    Ok(q)
}
pub fn row_stat(row: [u32; 4], k: usize) -> Result<Stat> {
    if !(2..=4).contains(&k) || row[k..].iter().any(|&v| v != 0) {
        return Err("row prefix/tail".into());
    }
    let total = row.iter().map(|&v| u64::from(v)).sum::<u64>();
    if total > u64::from(counts::CAP) { return Err("row CAP".into()); }
    let q = frequency(row, k)?;
    let support = row[..k].iter().filter(|&&v| v != 0).count();
    let mut stat = Stat { count: total, active: u64::from(total != 0),
        pure: u64::from(support == 1), cells: support as u64, ..Stat::default() };
    for child in 0..k {
        let n = f64::from(row[child]);
        if n != 0.0 {
            stat.empirical.add(n * (total as f64 / n).log2())?;
            stat.quantized.add(n * (32768.0 / f64::from(q[child])).log2())?;
        }
    }
    Ok(stat)
}
#[derive(Clone, Copy)]
pub struct Summary {
    pub components: [Stat; 2], pub nodes: [[Stat; counts::NODE_COUNT]; 2],
    pub whole: Stat, pub implicit: [u64; 2], pub maximum_row_total: u64,
}
impl Default for Summary {
    fn default() -> Self { Self { components: [Stat::default(); 2],
        nodes: [[Stat::default(); counts::NODE_COUNT]; 2], whole: Stat::default(),
        implicit: [0; 2], maximum_row_total: 0 } }
}
pub fn close(a: f64, b: f64) -> bool { a.is_finite() && b.is_finite() && (a-b).abs() <= 1e-6 }
pub fn same(a: Stat, b: Stat) -> bool {
    a.count == b.count && a.active == b.active && a.pure == b.pure && a.cells == b.cells
        && close(a.empirical.sum, b.empirical.sum) && close(a.quantized.sum, b.quantized.sum)
}
impl Summary {
    pub fn validate(&self) -> Result<()> {
        let mut whole = Stat::default();
        for c in 0..2 {
            let mut sum = Stat::default();
            for stat in self.nodes[c] { sum.merge(stat)?; }
            if !same(sum, self.components[c]) { return Err("node/component aggregate".into()); }
            whole.merge(sum)?;
        }
        if !same(whole, self.whole) { return Err("component/whole aggregate".into()); }
        Ok(())
    }
    fn merge(&mut self, other: &Self) -> Result<()> {
        for c in 0..2 {
            self.components[c].merge(other.components[c])?;
            self.implicit[c] += other.implicit[c];
            for node in 0..counts::NODE_COUNT { self.nodes[c][node].merge(other.nodes[c][node])?; }
        }
        self.whole.merge(other.whole)?;
        self.maximum_row_total = self.maximum_row_total.max(other.maximum_row_total);
        self.validate()
    }
}
// 旧Dense1個と固定配列のみ。observerは先行有限oracle用、実入力では保存しない。
pub struct Accumulator {
    pub dense: counts::Dense, pub tiles: Vec<Summary>, pub whole: Summary,
    pub flushes: usize, pub scans: usize, pub coded: u64, pub implicit: u64,
    pub history: [u16; 6], pub finished: bool,
    expected_runs: usize, current_tile: usize, last_run: Option<usize>, last_component: usize,
    tile_coded: u64, tile_implicit: [u64; 2],
}
impl Accumulator {
    pub fn new(expected_runs: usize) -> Result<Self> {
        if expected_runs == 0 || expected_runs > MAX_RUNS { return Err("expected run range".into()); }
        let mut tiles=Vec::new();
        tiles.try_reserve_exact(TILES).map_err(|_|"tile summary allocation")?;
        tiles.resize_with(TILES,Summary::default);
        Ok(Self { dense: counts::Dense::new()?, tiles,
            whole: Summary::default(), flushes: 0, scans: 0, coded: 0, implicit: 0,
            history: [0; 6], finished: false, expected_runs, current_tile: 0,
            last_run: None, last_component: 0, tile_coded: 0, tile_implicit: [0; 2] })
    }
    pub fn record(&mut self, c: usize, node: usize, class: usize, k: usize,
        history: u16, child: usize, run: usize,
        observer: &mut impl FnMut(usize, usize, [u32; 4]) -> Result<()>) -> Result<()> {
        if self.finished || c >= 2 || node >= counts::NODE_COUNT || class >= 6
            || class / 3 != c || !(1..=4).contains(&k) || child >= k
            || history > 1023 || run >= self.expected_runs || run / WIDTH >= TILES {
            return Err("event component/node/class/prefix/child/history/run".into());
        }
        if self.dense.rows.len() != counts::ROWS || history != self.history[class]
            || self.coded + self.implicit >= u64::from(counts::CAP) {
            return Err("event shape/history/CAP".into());
        }
        match self.last_run {
            None if run != 0 || c != 0 => return Err("first run/component".into()),
            Some(old) if run == old && c < self.last_component => return Err("same run component order".into()),
            Some(old) if run != old && (run != old + 1 || self.last_component != 1 || c != 0) => return Err("run sequence/component order".into()),
            _ => (),
        }
        if run / WIDTH != self.current_tile {
            self.flush(observer)?;
            self.current_tile = run / WIDTH;
        }
        if k == 1 { self.implicit += 1; self.tile_implicit[c] += 1; }
        else { self.dense.record(c, node, k, history, child)?; self.coded += 1; self.tile_coded += 1; }
        self.history[class] = ((history << 2) | child as u16) & 1023;
        self.last_run = Some(run);
        self.last_component = c;
        Ok(())
    }
    fn flush(&mut self, observer: &mut impl FnMut(usize, usize, [u32; 4]) -> Result<()>) -> Result<()> {
        if self.flushes != self.current_tile || self.tile_coded + self.tile_implicit.iter().sum::<u64>() == 0
            || self.dense.rows.len() != counts::ROWS { return Err("flush sequence/empty/shape".into()); }
        let mut summary = Summary { implicit: self.tile_implicit, ..Summary::default() };
        for index in 0..counts::ROWS {
            let row = self.dense.rows[index];
            let c = index / (counts::NODE_COUNT * 3 * counts::HISTORIES);
            let node = (index / (3 * counts::HISTORIES)) % counts::NODE_COUNT;
            let k = (index / counts::HISTORIES) % 3 + 2;
            let stat = row_stat(row, k)?;
            observer(self.current_tile, index, row)?;
            summary.maximum_row_total = summary.maximum_row_total.max(stat.count);
            summary.nodes[c][node].merge(stat)?;
            summary.components[c].merge(stat)?;
            summary.whole.merge(stat)?;
            self.dense.rows[index] = [0; 4];
        }
        if summary.whole.count != self.tile_coded { return Err("tile row/event count".into()); }
        summary.validate()?;
        self.whole.merge(&summary)?;
        self.tiles[self.current_tile] = summary;
        self.flushes += 1;
        self.scans += counts::ROWS;
        self.tile_coded = 0;
        self.tile_implicit = [0; 2];
        Ok(())
    }
    pub fn finish(&mut self, observer: &mut impl FnMut(usize, usize, [u32; 4]) -> Result<()>) -> Result<()> {
        if self.finished || self.last_run != Some(self.expected_runs - 1) || self.last_component != 1 {
            return Err("finish duplicate/missing run/length".into());
        }
        self.flush(observer)?;
        if self.flushes != self.expected_runs.div_ceil(WIDTH) || self.whole.whole.count != self.coded
            || self.whole.implicit.iter().sum::<u64>() != self.implicit { return Err("finish whole count/flush".into()); }
        self.finished = true;
        Ok(())
    }
    pub fn capacity_bytes(&self) -> usize {
        self.dense.capacity_bytes() + std::mem::size_of::<Self>() - std::mem::size_of::<counts::Dense>()
            + self.tiles.capacity()*std::mem::size_of::<Summary>()
    }
}
