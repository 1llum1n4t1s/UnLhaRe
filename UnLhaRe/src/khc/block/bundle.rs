use super::model;
type Result<T> = std::result::Result<T, String>;
pub fn ingest(hist: &mut model::Hist, k: usize, history: u16, row: [u32; 4]) -> Result<()> {
    if !(2..=4).contains(&k) || hist.counts.len() != model::GROUPS * model::NODES {
        return Err("weighted shape/prefix".into());
    }
    let added = row.iter().map(|&v| u64::from(v)).sum::<u64>();
    if row[k..].iter().any(|&v| v != 0) || added > u64::from(model::CAP) {
        return Err("weighted tail/CAP".into());
    }
    let mut ids = [0usize; 6];
    let mut next = [[0u32; 4]; 6];
    let mut id = 0;
    for depth in 0..=5 {
        let index = (k - 2) * model::NODES + id;
        ids[depth] = index;
        let current = hist.counts[index];
        if current[k..].iter().any(|&v| v != 0)
            || current.iter().map(|&v| u64::from(v)).sum::<u64>() > u64::from(model::CAP)
        {
            return Err("weighted existing tail/CAP".into());
        }
        for j in 0..4 {
            next[depth][j] = current[j]
                .checked_add(row[j])
                .ok_or("weighted count overflow")?;
        }
        if next[depth].iter().map(|&v| u64::from(v)).sum::<u64>() > u64::from(model::CAP) {
            return Err("weighted updated CAP".into());
        }
        if depth < 5 {
            id = 4 * id + 1 + ((history >> (2 * depth)) & 3) as usize;
        }
    }
    for depth in 0..6 {
        hist.counts[ids[depth]] = next[depth];
    }
    Ok(())
}
