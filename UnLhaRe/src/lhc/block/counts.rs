type Result<T> = std::result::Result<T, String>;
pub const NODE_COUNT: usize = 142;
pub const HISTORIES: usize = 1024;
pub const CAP: u32 = 3825340;
pub const ROWS: usize = 2 * NODE_COUNT * 3 * HISTORIES;
pub struct Dense {
    /// History pages are materialized on first observation; absent pages are all zero.
    pub rows: Vec<Vec<[u32; 4]>>,
}
fn index(c: usize, node: usize, k: usize, history: u16) -> Result<usize> {
    if c >= 2 || node >= NODE_COUNT || !(2..=4).contains(&k) {
        return Err("dense component/node/prefix".into());
    }
    Ok(((c * NODE_COUNT + node) * 3 + k - 2) * HISTORIES + (history as usize & 1023))
}
impl Dense {
    pub fn new() -> Result<Self> {
        let mut rows = Vec::new();
        rows.try_reserve_exact(ROWS / HISTORIES)
            .map_err(|_| "dense allocation")?;
        rows.resize_with(ROWS / HISTORIES, Vec::new);
        Ok(Self { rows })
    }
    pub fn record(
        &mut self,
        c: usize,
        node: usize,
        k: usize,
        history: u16,
        child: usize,
    ) -> Result<()> {
        let i = index(c, node, k, history)?;
        if child >= k || self.rows.len() != ROWS / HISTORIES {
            return Err("dense child/shape".into());
        }
        let table_index = i / HISTORIES;
        let history_index = i % HISTORIES;
        let table = &mut self.rows[table_index];
        if table.is_empty() {
            table
                .try_reserve_exact(HISTORIES)
                .map_err(|_| "dense allocation")?;
            table.resize(HISTORIES, [0; 4]);
        }
        if table.len() != HISTORIES {
            return Err("dense history shape".into());
        }
        let row = table[history_index];
        if row[k..].iter().any(|&v| v != 0)
            || row.iter().map(|&v| u64::from(v)).sum::<u64>() >= u64::from(CAP)
        {
            return Err("dense tail/CAP".into());
        }
        let next = row[child].checked_add(1).ok_or("dense overflow")?;
        table[history_index][child] = next;
        Ok(())
    }
    pub fn row(&self, c: usize, node: usize, k: usize, history: u16) -> Result<[u32; 4]> {
        let i = index(c, node, k, history)?;
        if self.rows.len() != ROWS / HISTORIES {
            return Err("dense shape".into());
        }
        let table = &self.rows[i / HISTORIES];
        if table.is_empty() {
            return Ok([0; 4]);
        }
        if table.len() != HISTORIES {
            return Err("dense history shape".into());
        }
        let row = table[i % HISTORIES];
        if row[k..].iter().any(|&v| v != 0)
            || row.iter().map(|&v| u64::from(v)).sum::<u64>() > u64::from(CAP)
        {
            return Err("dense stored tail/CAP".into());
        }
        Ok(row)
    }
    pub fn class_empty(&self, c: usize, node: usize) -> Result<bool> {
        let start = index(c, node, 2, 0)? / HISTORIES;
        if self.rows.len() != ROWS / HISTORIES {
            return Err("dense shape".into());
        }
        let tables = &self.rows[start..start + 3];
        if tables
            .iter()
            .any(|table| !table.is_empty() && table.len() != HISTORIES)
        {
            return Err("dense history shape".into());
        }
        Ok(tables
            .iter()
            .flat_map(|table| table.iter())
            .all(|row| row.iter().all(|&v| v == 0)))
    }
    pub fn capacity_bytes(&self) -> usize {
        self.rows.capacity() * std::mem::size_of::<Vec<[u32; 4]>>()
            + self
                .rows
                .iter()
                .map(|table| table.capacity() * std::mem::size_of::<[u32; 4]>())
                .sum::<usize>()
            + std::mem::size_of::<Self>()
    }
}
