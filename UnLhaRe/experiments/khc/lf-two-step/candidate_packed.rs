use super::{MAX_INPUT, Result};
fn validate(last: &[u16], alphabet: &[u16]) -> Result<()> {
    if last.is_empty() || last.len() > MAX_INPUT + 1 {
        return Err("transform length outside bounds".into());
    }
    if alphabet.iter().any(|&s| s > 256) {
        return Err("raw alphabet outside header bounds".into());
    }
    Ok(())
}
pub const INDEX_MASK: u32 = (1 << 23) - 1;
pub const VISITED: u32 = 1 << 31;
pub const PACKED_MAX_N: usize = 1 << 23;
pub struct Output {
    pub plain: Vec<u8>,
    pub route: &'static str,
    pub scratch_capacity_words: usize,
    pub result_capacity: usize,
}
pub fn pack(next: usize, byte: u8) -> Result<u32> {
    if next > INDEX_MASK as usize {
        return Err("packed next index exceeds 23 bits".into());
    }
    Ok((next as u32) | ((byte as u32) << 23))
}
pub fn mark(word: &mut u32) -> Result<()> {
    if *word & VISITED != 0 {
        return Err("LF cycle inconsistent".into());
    }
    *word |= VISITED;
    Ok(())
}
#[inline(never)]
pub fn inverse(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Output> {
    validate(last, alphabet)?;
    let n = last.len();
    if n > PACKED_MAX_N {
        return Err("transform exceeds packed23 index".into());
    }
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] = counts[s as usize]
            .checked_add(1)
            .ok_or("BWT count overflow")?;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &count) in counts.iter().enumerate() {
        if (count != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0usize; 257];
    let mut total = 0usize;
    for (i, &count) in counts.iter().enumerate() {
        starts[i] = total;
        total = total.checked_add(count).ok_or("BWT starts overflow")?;
    }
    if total != n {
        return Err("BWT total".into());
    }
    let mut occurrence = [0usize; 257];
    let mut words = super::allocate(n, 0u32)?;
    let scratch_capacity_words = words.capacity();
    for (row, &symbol) in last.iter().enumerate() {
        let s = symbol as usize;
        let next = starts[s]
            .checked_add(occurrence[s])
            .ok_or("LF next overflow")?;
        if next >= n {
            return Err("LF next outside rows".into());
        }
        let byte = if row == primary {
            0
        } else {
            u8::try_from(symbol.checked_sub(1).ok_or("nonprimary sentinel")?)
                .map_err(|_| "packed byte range")?
        };
        words[row] = pack(next, byte)?;
        occurrence[s] = occurrence[s]
            .checked_add(1)
            .ok_or("LF occurrence overflow")?;
    }
    let mut jumps = prepare(&words, primary)?;
    let scratch_capacity_words = scratch_capacity_words + jumps.capacity() * 2;
    drop(words);
    let plain = walk(&mut jumps, primary).map_err(|(error, _)| error.to_owned())?;
    let result_capacity = plain.capacity();
    Ok(Output {
        plain,
        route: "packed23",
        scratch_capacity_words,
        result_capacity,
    })
}
fn prepare(words: &[u32], primary: usize) -> Result<Vec<u64>> {
    let n = words.len();
    let mut jumps = super::allocate(n, 0u64)?;
    for (row, &first) in words.iter().enumerate() {
        let next1 = (first & INDEX_MASK) as usize;
        let second = *words.get(next1).ok_or("packed next outside rows")?;
        let next2 = second & INDEX_MASK;
        if next2 as usize >= n {
            return Err("packed next outside rows".into());
        }
        let low = next2 | (first & (255 << 23));
        let high =
            next1 as u32 | (second & (255 << 23)) | if next1 == primary { VISITED } else { 0 };
        jumps[row] = u64::from(low) | (u64::from(high) << 32);
    }
    Ok(jumps)
}
fn walk(jumps: &mut [u64], primary: usize) -> std::result::Result<Vec<u8>, (&'static str, usize)> {
    let n = jumps.len();
    let mut plain = super::allocate(n - 1, 0u8).map_err(|_| ("frame allocation", 0))?;
    let mut row = primary;
    let mut step = 0;
    while step + 1 < n {
        let word = jumps.get_mut(row).ok_or(("LF row outside bounds", step))?;
        if *word & u64::from(VISITED) != 0 || (step > 0 && row == primary) {
            return Err(("LF cycle inconsistent", step));
        }
        *word |= u64::from(VISITED);
        let next2 = (*word as u32 & INDEX_MASK) as usize;
        if next2 >= n {
            return Err(("packed next outside rows", step));
        }
        if step > 0 {
            plain[n - 1 - step] = ((*word >> 23) & 255) as u8;
        }
        if *word & (u64::from(VISITED) << 32) != 0 {
            return Err(("LF cycle inconsistent", step + 1));
        }
        plain[n - 2 - step] = ((*word >> 55) & 255) as u8;
        row = next2;
        step += 2;
    }
    if step < n {
        let word = jumps.get_mut(row).ok_or(("LF row outside bounds", step))?;
        if *word & u64::from(VISITED) != 0 || (step > 0 && row == primary) {
            return Err(("LF cycle inconsistent", step));
        }
        *word |= u64::from(VISITED);
        let next1 = ((*word >> 32) as u32 & INDEX_MASK) as usize;
        if next1 >= n {
            return Err(("packed next outside rows", step));
        }
        if step > 0 {
            plain[n - 1 - step] = ((*word >> 23) & 255) as u8;
        }
        row = next1;
    }
    if row != primary {
        return Err(("LF cycle/sentinel inconsistent", n));
    }
    Ok(plain)
}
// GRAPH_DIAGNOSTIC_BEGIN
pub(crate) fn graph(
    next: &[usize],
    primary: usize,
) -> std::result::Result<Vec<u8>, (&'static str, usize)> {
    let words: Vec<u32> = next
        .iter()
        .enumerate()
        .map(|(row, &successor)| {
            pack(successor, if row % 2 == 0 { 255 } else { (row * 47) as u8 }).unwrap()
        })
        .collect();
    let mut jumps = prepare(&words, primary).map_err(|_| ("graph prepare", 0))?;
    walk(&mut jumps, primary)
}
// GRAPH_DIAGNOSTIC_END
