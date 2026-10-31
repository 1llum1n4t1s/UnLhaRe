//! 観察専用。復号をskipせず、完全key/symbol一致の可能性だけを数える。
use super::Result;
pub const CELLS: usize = 65536;
pub const BYTES: usize = CELLS * 24;
#[derive(Default, Clone, Debug)]
pub struct Stats {
    pub calls: [usize; 2],
    pub hits: [usize; 2],
    pub collisions: [usize; 2],
    pub paid: [usize; 2],
    pub implicit: [usize; 2],
    pub hit_paid: [usize; 2],
    pub hit_branches: [usize; 2],
    pub singleton: [usize; 2],
}
#[derive(Clone, Copy, Default)]
#[repr(C)]
struct Cell {
    key: u64,
    symbol: u16,
    history: [u16; 3],
    reserved: [u32; 2],
}
const _: () = assert!(std::mem::size_of::<Cell>() == 24);
pub type MaskTable = [[[u16; 3]; 258]; 2];
pub struct Memo {
    table: Vec<Cell>,
    masks: MaskTable,
    pub stats: Stats,
}
pub fn key(c: usize, limit: usize, history: [u16; 3]) -> Result<u64> {
    if c > 1
        || !(1..=if c == 0 { 257 } else { 256 }).contains(&limit)
        || history.iter().any(|&h| h >= 1024)
    {
        return Err("memo component/support/history".into());
    }
    Ok(1 | ((c as u64) << 1)
        | (((limit - 1) as u64) << 2)
        | (u64::from(history[0]) << 11)
        | (u64::from(history[1]) << 21)
        | (u64::from(history[2]) << 31))
}
fn slot(mut key: u64) -> usize {
    key ^= key >> 30;
    key = key.wrapping_mul(0xbf58476d1ce4e5b9);
    key ^= key >> 27;
    key = key.wrapping_mul(0x94d049bb133111eb);
    key ^= key >> 31;
    (key as usize) & (CELLS - 1)
}
impl Memo {
    pub fn new(masks: MaskTable) -> Result<Self> {
        if masks.iter().flatten().flatten().any(|&m| m > 1023) {
            return Err("mask unknown bits".into());
        }
        let mut table = Vec::new();
        table
            .try_reserve_exact(CELLS)
            .map_err(|_| "memo allocation")?;
        if table.capacity() != CELLS {
            return Err("memo capacity".into());
        }
        table.resize(CELLS, Cell::default());
        Ok(Self {
            table,
            masks,
            stats: Stats::default(),
        })
    }
    pub fn capacity(&self) -> usize {
        self.table.capacity() * std::mem::size_of::<Cell>()
    }
    pub fn observe(
        &mut self,
        c: usize,
        limit: usize,
        start: [u16; 3],
        symbol: usize,
        end: [u16; 3],
        transform: [u16; 3],
        paid: usize,
        implicit: usize,
    ) -> Result<()> {
        let _ = key(c, limit, start)?;
        let mask = self.masks[c][limit];
        let masked = [start[0] & mask[0], start[1] & mask[1], start[2] & mask[2]];
        let key = key(c, limit, masked)?;
        if apply(start, transform)? != end {
            return Err("transform history witness".into());
        }
        if symbol >= limit || end.iter().any(|&h| h >= 1024) {
            return Err("memo result/history".into());
        }
        let at = slot(key);
        let old = self.table[at];
        self.stats.calls[c] += 1;
        self.stats.paid[c] += paid;
        self.stats.implicit[c] += implicit;
        if limit == 1 {
            self.stats.singleton[c] += 1;
        }
        if old.key == key && usize::from(old.symbol) == symbol {
            if apply(start, old.history)? != end || old.history != transform {
                return Err("memo deterministic history mismatch".into());
            }
            self.stats.hits[c] += 1;
            self.stats.hit_paid[c] += paid;
            self.stats.hit_branches[c] += paid + implicit;
        } else if old.key != 0 && old.key != key {
            self.stats.collisions[c] += 1;
        }
        self.table[at] = Cell {
            key,
            symbol: symbol as u16,
            history: transform,
            reserved: [0; 2],
        };
        Ok(())
    }
}

pub fn apply(start: [u16; 3], transform: [u16; 3]) -> Result<[u16; 3]> {
    let mut end = [0u16; 3];
    for c in 0..3 {
        let visits = transform[c] >> 10;
        let suffix = transform[c] & 1023;
        if start[c] > 1023 || visits > 8 {
            return Err("transform range".into());
        }
        end[c] = if visits >= 5 {
            suffix
        } else {
            ((start[c] << (2 * visits)) | suffix) & 1023
        };
    }
    Ok(end)
}
pub fn finite_contract() -> Result<usize> {
    let mut count = 0;
    for c in 0..3 {
        for visits in 0..=8u16 {
            for start in 0..1024u16 {
                let mut literal = start;
                let mut suffix = 0u16;
                for step in 0..visits {
                    let child = (step + c as u16) & 3;
                    literal = ((literal << 2) | child) & 1023;
                    suffix = ((suffix << 2) | child) & 1023;
                }
                let mut t = [0u16; 3];
                let mut h = [0u16; 3];
                t[c] = (visits << 10) | suffix;
                h[c] = start;
                if apply(h, t)?[c] != literal {
                    return Err("independent transform".into());
                }
                count += 1;
            }
        }
    }
    for (c, n, h) in [
        (2, 1, [0; 3]),
        (0, 0, [0; 3]),
        (0, 258, [0; 3]),
        (1, 257, [0; 3]),
        (0, 1, [1024, 0, 0]),
    ] {
        if key(c, n, h).is_ok() {
            return Err("invalid key".into());
        }
        count += 1;
    }
    if apply([0; 3], [9 << 10, 0, 0]).is_ok() {
        return Err("transform overflow accepted".into());
    }
    count += 1;
    let mut masks = [[[1023u16; 3]; 258]; 2];
    masks[0][257] = [3, 0, 0];
    let mut memo = Memo::new(masks)?;
    let transform = [1 << 10, 0, 0];
    let h1 = [7, 8, 9];
    let h2 = [11, 25, 35];
    let e1 = apply(h1, transform)?;
    let e2 = apply(h2, transform)?;
    memo.observe(0, 257, h1, 0, e1, transform, 1, 0)?;
    memo.observe(0, 257, h2, 0, e2, transform, 1, 0)?;
    if memo.stats.hits[0] != 1 || e1 == e2 {
        return Err("masked history update lost hidden bits".into());
    }
    count += 1;
    if memo.observe(0, 257, h2, 0, e1, transform, 1, 0).is_ok() {
        return Err("stale history accepted".into());
    }
    count += 1;
    let fresh = Memo::new([[[0; 3]; 258]; 2])?;
    if fresh.table.iter().any(|v| v.key != 0) {
        return Err("forest reset".into());
    }
    count += 1;
    Ok(count)
}
