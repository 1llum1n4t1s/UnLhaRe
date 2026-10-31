//! 独立SA-ISによる研究用BWT。一意最小sentinelで非循環suffix順と循環順が一致する。
pub const MAX_INPUT: usize = 8 * 1024 * 1024;
const EMPTY: u32 = u32::MAX;
const MAX_DEPTH: usize = 24;
type Result<T> = std::result::Result<T, String>;

fn filled<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    let mut result = Vec::new();
    result
        .try_reserve_exact(n)
        .map_err(|_| "allocation failed")?;
    result.resize(n, value);
    Ok(result)
}

fn is_lms(types: &[bool], i: usize) -> bool {
    i > 0 && types[i] && !types[i - 1]
}

// 桶は半開区間[start,end)。配置ごとにcursorを再初期化する。
fn induce(
    text: &[u32],
    types: &[bool],
    lms: &[u32],
    starts: &[usize],
    ends: &[usize],
    cursor: &mut [usize],
    sa: &mut [u32],
) -> Result<()> {
    sa.fill(EMPTY);
    cursor.copy_from_slice(ends);
    // 末尾から配置するため、入力LMS順を桶内で保持する。
    for &position in lms.iter().rev() {
        let p = position as usize;
        if p >= text.len() || !is_lms(types, p) {
            return Err("invalid LMS position".into());
        }
        let c = text[p] as usize;
        if cursor[c] <= starts[c] {
            return Err("LMS bucket underflow".into());
        }
        cursor[c] -= 1;
        sa[cursor[c]] = position;
    }
    cursor.copy_from_slice(starts);
    // L型の直前suffixは前向きに桶先頭へ誘導する。
    for row in 0..sa.len() {
        let position = sa[row];
        if position == EMPTY || position == 0 {
            continue;
        }
        let previous = position as usize - 1;
        if !types[previous] {
            let c = text[previous] as usize;
            if cursor[c] >= ends[c] {
                return Err("L bucket overflow".into());
            }
            sa[cursor[c]] = previous as u32;
            cursor[c] += 1;
        }
    }
    cursor.copy_from_slice(ends);
    // S型は逆向きに桶末尾へ誘導する。EMPTYとsuffix 0は別値。
    for row in (0..sa.len()).rev() {
        let position = sa[row];
        if position == EMPTY || position == 0 {
            continue;
        }
        let previous = position as usize - 1;
        if types[previous] {
            let c = text[previous] as usize;
            if cursor[c] <= starts[c] {
                return Err("S bucket underflow".into());
            }
            cursor[c] -= 1;
            sa[cursor[c]] = previous as u32;
        }
    }
    if sa.first().copied() != Some((text.len() - 1) as u32) || sa.contains(&EMPTY) {
        return Err("induced sentinel/completeness inconsistent".into());
    }
    Ok(())
}

fn same_lms(text: &[u32], types: &[bool], a: usize, b: usize) -> bool {
    if a == b {
        return true;
    }
    let mut offset = 0;
    loop {
        // sentinelの次は参照しない。異なる長さも異なる名前にする。
        if offset >= text.len() - a || offset >= text.len() - b {
            return false;
        }
        let x = a + offset;
        let y = b + offset;
        if text[x] != text[y] || types[x] != types[y] {
            return false;
        }
        let end_x = is_lms(types, x);
        let end_y = is_lms(types, y);
        // 次のLMSを含むsubstring。開始位置のLMSでは止めない。
        if offset > 0 && (end_x || end_y) {
            return end_x && end_y;
        }
        offset += 1;
    }
}

fn suffix_array(text: &[u32], alphabet: usize, depth: usize) -> Result<Vec<u32>> {
    let n = text.len();
    if n == 0
        || n > MAX_INPUT + 1
        || depth > MAX_DEPTH
        || alphabet == 0
        || alphabet > MAX_INPUT + 1
        || text[n - 1] != 0
    {
        return Err("SA-IS length/alphabet/depth/sentinel outside bounds".into());
    }
    let mut counts = filled(alphabet, 0_usize)?;
    for (i, &symbol) in text.iter().enumerate() {
        let c = symbol as usize;
        if c >= alphabet || (symbol == 0 && i != n - 1) {
            return Err("SA-IS symbol/sentinel inconsistent".into());
        }
        counts[c] = counts[c].checked_add(1).ok_or("bucket count overflow")?;
    }
    if n == 1 {
        return filled(1, 0_u32);
    }
    let mut types = filled(n, false)?;
    types[n - 1] = true;
    // 等値は右隣の型を伝播。sentinelはS型で、その直前は必ずL型。
    for i in (0..n - 1).rev() {
        types[i] = text[i] < text[i + 1] || (text[i] == text[i + 1] && types[i + 1]);
    }
    let m = (1..n).filter(|&i| is_lms(&types, i)).count();
    if m == 0 || m > n / 2 {
        return Err("LMS reduction does not shrink".into());
    }
    let mut lms = filled(m, 0_u32)?;
    let mut next = 0;
    for i in 1..n {
        if is_lms(&types, i) {
            lms[next] = i as u32;
            next += 1;
        }
    }
    let mut starts = filled(alphabet, 0_usize)?;
    let mut sum = 0_usize;
    for (start, count) in starts.iter_mut().zip(&mut counts) {
        *start = sum;
        sum = sum.checked_add(*count).ok_or("bucket sum overflow")?;
        *count = sum;
    }
    if sum != n {
        return Err("bucket sum inconsistent".into());
    }
    let ends = counts;
    let mut cursor = filled(alphabet, 0_usize)?;
    let mut sa = filled(n, EMPTY)?;
    induce(text, &types, &lms, &starts, &ends, &mut cursor, &mut sa)?;

    // LMSは隣接しないためposition/2は一意。元位置順の名前へ戻す。
    let mut names = filled(n / 2 + 1, EMPTY)?;
    let mut previous = None;
    let mut name = 0_u32;
    let mut found = 0;
    for &position in &sa {
        let p = position as usize;
        if is_lms(&types, p) {
            if let Some(old) = previous {
                if !same_lms(text, &types, old, p) {
                    name = name.checked_add(1).ok_or("LMS name overflow")?;
                }
            }
            names[p / 2] = name;
            previous = Some(p);
            found += 1;
        }
    }
    if found != m || names[(n - 1) / 2] != 0 {
        return Err("LMS naming/sentinel inconsistent".into());
    }
    let classes = name as usize + 1;
    let mut reduced = filled(m, 0_u32)?;
    for (out, &position) in reduced.iter_mut().zip(&lms) {
        *out = names[position as usize / 2];
        if *out == EMPTY {
            return Err("missing LMS name".into());
        }
    }
    drop(names);
    let reduced_sa = if classes == m {
        // 名前がすべて一意なら、名前を順位として逆置換する。
        let mut order = filled(m, EMPTY)?;
        for (i, &rank) in reduced.iter().enumerate() {
            let slot = order.get_mut(rank as usize).ok_or("invalid reduced rank")?;
            if *slot != EMPTY {
                return Err("duplicate unique LMS name".into());
            }
            *slot = i as u32;
        }
        order
    } else {
        // m<=n/2、末尾の唯一0を維持し、同名を必ず再帰で分離する。
        suffix_array(&reduced, classes, depth + 1)?
    };
    drop(reduced);
    let mut ordered = filled(m, 0_u32)?;
    for (out, &index) in ordered.iter_mut().zip(&reduced_sa) {
        *out = *lms
            .get(index as usize)
            .ok_or("reduced suffix outside bounds")?;
    }
    drop(reduced_sa);
    drop(lms);
    induce(text, &types, &ordered, &starts, &ends, &mut cursor, &mut sa)?;
    Ok(sa)
}

pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize)> {
    // 上限と整数幅は、入力サイズに比例する割当ての前に検査する。
    if input.len() > MAX_INPUT {
        return Err("input exceeds BWT limit".into());
    }
    let n = input.len().checked_add(1).ok_or("length overflow")?;
    u32::try_from(n).map_err(|_| "BWT length exceeds u32")?;
    let mut text = filled(n, 0_u32)?;
    for (symbol, &byte) in text.iter_mut().zip(input) {
        *symbol = u32::from(byte) + 1;
    }
    let sa = suffix_array(&text, 257, 0)?;
    let mut last = filled(n, 0_u16)?;
    let mut primary = None;
    for (row, &position) in sa.iter().enumerate() {
        let p = position as usize;
        if p >= n {
            return Err("suffix outside bounds".into());
        }
        if p == 0 && primary.replace(row).is_some() {
            return Err("duplicate primary".into());
        }
        last[row] = text[if p == 0 { n - 1 } else { p - 1 }] as u16;
    }
    let primary = primary.ok_or("missing primary")?;
    if last[primary] != 0 {
        return Err("primary sentinel inconsistent".into());
    }
    Ok((last, primary))
}
