//! 独立数値実験。guarded64/32経路、診断flagsは製品へ導入しない。
pub const Q: u64 = 1 << 32;
pub const SHIFT: u8 = 1;
pub const DOWN: u8 = 2;
pub const UP: u8 = 4;
pub const FALLBACK: u8 = 8;
pub const GUESS_OVERFLOW: u8 = 16;
pub const NATIVE32: u8 = 32;

#[inline(always)]
fn native32(n: u64, d: u64) -> Option<(u64, u64)> {
    #[cfg(all(target_arch = "x86_64", not(khc_force_portable)))]
    if d != 0 && d < Q && (n >> 32) < d {
        let quotient: u32;
        let remainder: u32;
        // 除数が非zeroでhigh<divisorなので、DIVの商はu32に収まり#DEにならない。
        // 入出力のEAX/EDXを予約し、除数を別registerへ置く。flags保存は仮定しない。
        unsafe {
            core::arch::asm!(
                "div {divisor:e}",
                divisor = in(reg) d as u32,
                inout("eax") n as u32 => quotient,
                inout("edx") (n >> 32) as u32 => remainder,
                options(pure, nomem, nostack),
            );
        }
        return Some((u64::from(quotient), u64::from(remainder)));
    }
    #[cfg(any(not(target_arch = "x86_64"), khc_force_portable))]
    let _ = (n, d);
    None
}

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
    if let Some((quotient, _remainder)) = native32(n, d) {
        return Ok((quotient, NATIVE32));
    }
    let mut guess = if n <= i64::MAX as u64 {
        (((n as i64) as f64) / (d as f64)) as i64 as u64
    } else {
        estimate_unsigned(n, d)
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

#[inline(never)]
fn estimate_unsigned(n: u64, d: u64) -> u64 {
    ((n as f64) / (d as f64)) as u64
}

#[cfg(khc_native32_audit)]
pub fn audit(a: u64, b: u64, d: u64) -> Result<(u64, u64, u64, u64), &'static str> {
    match ratio(a, b, d) {
        Ok((q, flags)) => {
            let n = a.checked_mul(b).ok_or("audit product inconsistent")?;
            let remainder = if flags == NATIVE32 {
                // ordinary ratioと同じguard/primitiveの実EDXを保存する。無条件asm入口なし。
                let (actual, remainder) =
                    native32(n, d).ok_or("audit native guard inconsistent")?;
                if actual != q {
                    return Err("audit native quotient inconsistent");
                }
                remainder
            } else {
                n % d
            };
            Ok((q, remainder, 0, u64::from(flags)))
        }
        Err("zero denominator") => Ok((0, 0, 1, 0)),
        Err("product overflow") => Ok((0, 0, 2, 0)),
        Err(error) => Err(error),
    }
}
