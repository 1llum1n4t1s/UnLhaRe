type Result<T> = std::result::Result<T, String>;

pub fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}

pub fn inverse_bwt(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Vec<u8>> {
    let n = last.len();
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0_usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] += 1;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &c) in counts.iter().enumerate() {
        if (c != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0_usize; 257];
    let mut total = 0;
    for (i, &c) in counts.iter().enumerate() {
        starts[i] = total;
        total += c;
    }
    let mut occurrence = [0_usize; 257];
    let mut lf = filled(n, 0_usize)?;
    for (i, &s) in last.iter().enumerate() {
        let s = s as usize;
        lf[i] = starts[s] + occurrence[s];
        occurrence[s] += 1;
    }
    let mut visited = filled(n, false)?;
    let mut text = filled(n, 0_u16)?;
    let mut row = primary;
    for out in text.iter_mut().rev() {
        if row >= n || visited[row] {
            return Err("LF cycle inconsistent".into());
        }
        visited[row] = true;
        *out = last[row];
        row = lf[row];
    }
    if row != primary
        || !visited.iter().all(|&v| v)
        || text[n - 1] != 0
        || text[..n - 1].contains(&0)
    {
        return Err("LF cycle/sentinel inconsistent".into());
    }
    let mut result = filled(n - 1, 0_u8)?;
    for (out, &s) in result.iter_mut().zip(&text) {
        *out = (s - 1) as u8;
    }
    Ok(result)
}
