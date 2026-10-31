use super::{bwt, histogram};
#[derive(Clone, Copy)]
pub struct Run {
    pub symbol: u32,
    pub length: u32,
    pub next: u32,
}
const _: () = assert!(std::mem::size_of::<Run>() == 12);
pub struct Front {
    pub runs: Vec<Run>,
    pub primary: usize,
    pub last_len: usize,
}
impl Front {
    pub fn new(plain: &[u8]) -> Result<Self, String> {
        if plain.len() > 8 * 1024 * 1024 {
            return Err("frontend input bound".into());
        }
        let (last, primary) = bwt::bwt(plain)?;
        Self::from_transformed(&last, primary)
    }
    pub(in crate::khc) fn from_transformed(last: &[u16], primary: usize) -> Result<Self, String> {
        let mut runs: Vec<Run> = Vec::new();
        for &symbol in last {
            if let Some(r) = runs.last_mut()
                && r.symbol == symbol as u32
            {
                r.length = r.length.checked_add(1).ok_or("run length overflow")?;
                continue;
            }
            runs.push(Run {
                symbol: symbol as u32,
                length: 1,
                next: u32::MAX,
            });
        }
        let mut next = [u32::MAX; 257];
        for i in (0..runs.len()).rev() {
            let s = runs[i].symbol as usize;
            if s >= 257 {
                return Err("BWT symbol".into());
            }
            runs[i].next = next[s];
            next[s] = u32::try_from(i).map_err(|_| "run index overflow")?;
        }
        if last.iter().filter(|&&x| x == 0).count() != 1 {
            return Err("sentinel count".into());
        }
        Ok(Self {
            runs,
            primary,
            last_len: last.len(),
        })
    }
    pub fn walk(
        &self,
        mut event: impl FnMut(usize, usize, usize, usize, usize, usize, usize) -> Result<(), String>,
    ) -> Result<usize, String> {
        let mut next = [u32::MAX; 257];
        let mut present = [false; 257];
        for (i, r) in self.runs.iter().enumerate().rev() {
            next[r.symbol as usize] = i as u32;
            present[r.symbol as usize] = true;
        }
        // head以外のnextは各runで不変。整列順から同じhead/rankを求める。
        let mut order = [0u16; 257];
        let mut active = 0;
        for (symbol, &is_present) in present.iter().enumerate() {
            if is_present {
                order[active] = symbol as u16;
                active += 1;
            }
        }
        order[..active].sort_unstable_by_key(|&symbol| next[usize::from(symbol)]);
        let mut previous_rank = [0usize; 257];
        let mut previous_length = [0usize; 257];
        let mut consumed = 0usize;
        let mut escapes = 0usize;
        for (i, r) in self.runs.iter().enumerate() {
            let s = r.symbol as usize;
            let length = r.length as usize;
            if active == 0 || usize::from(order[0]) != s || !present[s] || next[s] != i as u32 {
                return Err("next-use head".into());
            }
            next[s] = r.next;
            let rank = if r.next == u32::MAX {
                0
            } else {
                order[1..active].partition_point(|&symbol| next[usize::from(symbol)] < r.next)
            };
            if r.next != u32::MAX && rank == 0 {
                return Err("adjacent run rank".into());
            }
            event(
                0,
                s,
                0,
                previous_rank[s].min(3),
                rank,
                active,
                previous_rank[s],
            )?;
            let remaining = self
                .last_len
                .checked_sub(consumed)
                .ok_or("remaining underflow")?;
            if length == 0 || length > remaining {
                return Err("run length range".into());
            }
            event(
                1,
                s,
                histogram::exponent(rank + 1),
                previous_length[s],
                (length - 1).min(255),
                remaining.min(256),
                previous_rank[s],
            )?;
            if length >= 256 {
                let mut value = length - 256;
                loop {
                    escapes = escapes.checked_add(1).ok_or("escape overflow")?;
                    value >>= 7;
                    if value == 0 {
                        break;
                    }
                }
            }
            if rank == 0 {
                order.copy_within(1..active, 0);
                present[s] = false;
                active -= 1;
            } else {
                order.copy_within(1..=rank, 0);
                order[rank] = s as u16;
            }
            previous_rank[s] = rank;
            previous_length[s] = histogram::length_bucket(length);
            consumed = consumed.checked_add(length).ok_or("consumed overflow")?;
        }
        if active != 0 || consumed != self.last_len {
            return Err("frontend terminal".into());
        }
        Ok(escapes)
    }
}
