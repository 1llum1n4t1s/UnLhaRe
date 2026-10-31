//! CTSの整数式を維持する、u64商に限定した正確な除算。

pub fn ratio(a: u64, b: u64, denominator: u64) -> super::Result<u64> {
    if denominator == 0 {
        return Err("CTS zero denominator".into());
    }
    let product = u128::from(a)
        .checked_mul(u128::from(b))
        .ok_or("CTS product overflow")?;
    if denominator == 1 << 48 {
        return u64::try_from(product >> 48).map_err(|_| "CTS quotient overflow".into());
    }
    let hi = (product >> 64) as u64;
    if hi >= denominator {
        return Err("CTS quotient overflow".into());
    }
    #[cfg(all(target_arch = "x86_64", not(khc_portable_div)))]
    {
        let quotient: u64;
        // product = hi*2^64+lo。d>0のとき商<2^64とhi<dは同値であり、
        // 上の検査でDIVのゼロ除算・商overflowによる例外を除外済み。
        // 通常のinoutは入力と出力のregister重複を禁じ、divisorをRAX/RDX
        // と分離する。メモリ・stackアクセスはなく、結果は入力だけに依存する。
        // DIV後のFLAGSは未定義なのでpreserves_flagsは指定しない。
        unsafe {
            std::arch::asm!(
                "div {divisor}",
                divisor = in(reg) denominator,
                inout("rax") product as u64 => quotient,
                inout("rdx") hi => _,
                options(pure, nomem, nostack)
            );
        }
        Ok(quotient)
    }
    #[cfg(any(not(target_arch = "x86_64"), khc_portable_div))]
    {
        u64::try_from(product / u128::from(denominator)).map_err(|_| "CTS quotient overflow".into())
    }
}
