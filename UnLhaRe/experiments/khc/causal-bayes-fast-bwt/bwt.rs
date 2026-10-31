//! 一意最小sentinel付き循環prefix-doubling。研究用の同値BWT。

pub const MAX_INPUT: usize = 8 * 1024 * 1024;
type Result<T> = std::result::Result<T, String>;

fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values
        .try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    values.resize(length, value);
    Ok(values)
}

pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize)> {
    if input.len() > MAX_INPUT {
        return Err("input exceeds BWT limit".into());
    }
    let n = input.len().checked_add(1).ok_or("length overflow")?;
    let n32 = u32::try_from(n).map_err(|_| "BWT length exceeds u32")?;
    let mut symbols = filled(n, 0_u16)?;
    for (symbol, &byte) in symbols.iter_mut().zip(input) {
        *symbol = u16::from(byte) + 1;
    }
    // n配列はこの5本のみ。初期alphabetのcountは固定長stackに置く。
    let mut sa = filled(n, 0_u32)?;
    let mut ranks = filled(n, 0_u32)?;
    let mut scratch = filled(n, 0_u32)?;
    let mut new_ranks = filled(n, 0_u32)?;
    let mut counts = filled(n, 0_u32)?;
    let mut initial_counts = [0_u32; 257];
    for &symbol in &symbols {
        initial_counts[usize::from(symbol)] += 1;
    }
    let mut sum = 0_u32;
    for count in &mut initial_counts {
        let old = *count;
        *count = sum;
        sum = sum.checked_add(old).ok_or("initial count sum overflow")?;
    }
    if sum != n32 {
        return Err("initial count sum inconsistent".into());
    }
    for (i, &symbol) in symbols.iter().enumerate() {
        let count = &mut initial_counts[usize::from(symbol)];
        sa[*count as usize] = u32::try_from(i).map_err(|_| "BWT index exceeds u32")?;
        *count += 1;
    }
    let mut class = 0_u32;
    ranks[sa[0] as usize] = 0;
    for pair in sa.windows(2) {
        if symbols[pair[0] as usize] != symbols[pair[1] as usize] {
            class += 1;
        }
        ranks[pair[1] as usize] = class;
    }
    let mut classes = class as usize + 1;
    let mut step = 1_usize;
    // 空入力(n=1)は初期symbol-sortだけで完成する。
    while classes < n {
        if classes == 0 || step == 0 || step >= n {
            return Err("BWT step/classes outside bounds".into());
        }
        for (out, &start) in scratch.iter_mut().zip(&sa) {
            let start = start as usize;
            *out = if start >= step {
                start - step
            } else {
                start + (n - step)
            } as u32;
        }
        counts[..classes].fill(0);
        for &start in &scratch {
            // ranksは初期dense rank、以後は下の再rankで0..classesに限定。
            counts[ranks[start as usize] as usize] += 1;
        }
        sum = 0;
        for count in &mut counts[..classes] {
            let old = *count;
            *count = sum;
            sum = sum.checked_add(old).ok_or("BWT count sum overflow")?;
        }
        if sum != n32 {
            return Err("BWT count sum inconsistent".into());
        }
        // shiftした旧SAは第2rank順なので第1rankのstable sortだけでよい。
        for &start in &scratch {
            let count = &mut counts[ranks[start as usize] as usize];
            sa[*count as usize] = start;
            *count += 1;
        }
        class = 0;
        new_ranks[sa[0] as usize] = 0;
        for pair in sa.windows(2) {
            let a = pair[0] as usize;
            let b = pair[1] as usize;
            let second_a = if a < n - step {
                a + step
            } else {
                a - (n - step)
            };
            let second_b = if b < n - step {
                b + step
            } else {
                b - (n - step)
            };
            if ranks[a] != ranks[b] || ranks[second_a] != ranks[second_b] {
                class += 1;
            }
            new_ranks[b] = class;
        }
        std::mem::swap(&mut ranks, &mut new_ranks);
        classes = class as usize + 1;
        if classes == n {
            break;
        }
        step = step.checked_mul(2).ok_or("BWT step overflow")?;
    }
    if classes != n || sa[0] as usize != n - 1 {
        return Err("sentinel suffix order/classes inconsistent".into());
    }
    let mut transformed = filled(n, 0_u16)?;
    let mut primary = None;
    for (row, &start) in sa.iter().enumerate() {
        let start = start as usize;
        if start == 0 && primary.replace(row).is_some() {
            return Err("duplicate primary".into());
        }
        transformed[row] = symbols[if start == 0 { n - 1 } else { start - 1 }];
    }
    let primary = primary.ok_or("missing primary")?;
    if transformed[primary] != 0 {
        return Err("primary sentinel inconsistent".into());
    }
    Ok((transformed, primary))
}
