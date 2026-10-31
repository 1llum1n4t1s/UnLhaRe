//! 独立数値実験。診断flagsは製品モデルに導入しない。
pub const Q: u64 = 1 << 32;
pub const SHIFT: u8 = 1;
pub const DOWN: u8 = 2;
pub const UP: u8 = 4;
pub const FALLBACK: u8 = 8;
pub const GUESS_OVERFLOW: u8 = 16;

#[inline(always)]
pub fn ratio(a: u64, b: u64, d: u64) -> Result<(u64, u8), &'static str> {
    if d == 0 {
        return Err("zero denominator");
    }
    let n = a.checked_mul(b).ok_or("product overflow")?;
    if d == Q {
        return Ok((n >> 32, SHIFT));
    }
    // 想定範囲外はnative商へ落とす。全u64入力の正確さを維持する。
    if d > Q {
        return Ok((n / d, FALLBACK));
    }
    let mut guess = if n <= i64::MAX as u64 {
        (((n as i64) as f64) / (d as f64)) as i64 as u64
    } else {
        ((n as f64) / (d as f64)) as u64
    };
    let mut flags = 0;
    let mut product = guess.checked_mul(d);
    if product.is_none() {
        flags |= GUESS_OVERFLOW;
        // 真の積より大きい推定。減算も積もcheckedで一回だけ試す。
        if let Some(lower) = guess.checked_sub(1) {
            guess = lower;
            flags |= DOWN;
            product = guess.checked_mul(d);
        }
    } else if product.is_some_and(|p| p > n) {
        if let Some(lower) = guess.checked_sub(1) {
            guess = lower;
            flags |= DOWN;
            product = guess.checked_mul(d);
        }
    }
    if let Some(p) = product {
        if p <= n && n - p >= d {
            if let Some(higher) = guess.checked_add(1) {
                guess = higher;
                flags |= UP;
                product = guess.checked_mul(d);
            }
        }
    }
    // binary64の誤差上限を仮定せず整数残余で証明する。
    if product.is_some_and(|p| p <= n && n - p < d) {
        return Ok((guess, flags));
    }
    Ok((n / d, flags | FALLBACK))
}
