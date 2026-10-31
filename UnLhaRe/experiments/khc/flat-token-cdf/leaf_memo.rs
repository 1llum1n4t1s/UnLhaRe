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
pub struct Memo {
    table: Vec<Cell>,
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
    pub fn new() -> Result<Self> {
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
        paid: usize,
        implicit: usize,
    ) -> Result<()> {
        let key = key(c, limit, start)?;
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
            if old.history != end {
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
            history: end,
            reserved: [0; 2],
        };
        Ok(())
    }
}
pub fn finite_contract() -> Result<usize> {
    let mut count = 0;
    let mut memo = Memo::new()?;
    for (c, n, h) in [
        (2, 1, [0; 3]),
        (0, 0, [0; 3]),
        (0, 258, [0; 3]),
        (1, 257, [0; 3]),
        (0, 1, [1024, 0, 0]),
    ] {
        if key(c, n, h).is_ok() {
            return Err("memo invalid key accepted".into());
        }
        count += 1;
    }
    let key0 = key(0, 257, [1023; 3])?;
    let key1 = key(1, 256, [1023; 3])?;
    if key0 == 0 || key0 == key1 {
        return Err("memo key collision encoding".into());
    }
    count += 1;
    memo.observe(0, 257, [7, 8, 9], 42, [28, 32, 36], 2, 1)?;
    memo.observe(0, 257, [7, 8, 9], 42, [28, 32, 36], 2, 1)?;
    if memo.stats.calls[0] != 2 || memo.stats.hits[0] != 1 {
        return Err("memo repeated identity".into());
    }
    count += 1;
    if memo
        .observe(0, 257, [7, 8, 9], 42, [29, 32, 36], 2, 1)
        .is_ok()
    {
        return Err("memo false final history".into());
    }
    count += 1;
    // 同じslotになる別keyを有限走査で作り、誤hitしないことを確かめる。
    let prior = key(0, 257, [7, 8, 9])?;
    let target = slot(prior);
    let mut collision = None;
    for h in 0..1024 {
        for j in 0..1024 {
            let k = key(0, 257, [h, j, 1])?;
            if k != prior && slot(k) == target {
                collision = Some([h, j, 1]);
                break;
            }
        }
        if collision.is_some() {
            break;
        }
    }
    let h = collision.ok_or("no finite collision found")?;
    memo.observe(0, 257, h, 42, [1, 2, 3], 2, 1)?;
    if memo.stats.hits[0] != 1 || memo.stats.collisions[0] != 1 {
        return Err("hash collision false hit".into());
    }
    count += 1;
    let fresh = Memo::new()?;
    if fresh.stats.calls != [0; 2] || fresh.table.iter().any(|c| c.key != 0) {
        return Err("forest reset".into());
    }
    count += 1;
    Ok(count)
}
