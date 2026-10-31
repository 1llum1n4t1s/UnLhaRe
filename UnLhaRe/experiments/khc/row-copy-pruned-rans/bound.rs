//! scale15・固定scalar rANS専用の保守的整数下界。PLAN.mdの条件外には使わない。
pub type Result<T> = std::result::Result<T, String>;
pub const MAX_FIELDS: usize = 2 * 1024 * 1024;
#[derive(Debug)]
pub struct Decision {
    pub minimum_bits: u64,
    pub fields: usize,
    pub q32: i64,
    pub prune: bool,
}
pub fn impossible(
    counts: &[[u32; 256]; 4],
    frequencies: &[[u16; 256]; 4],
    fields: usize,
    limit: usize,
) -> Result<Decision> {
    if fields > MAX_FIELDS || !(5..=1 << 20).contains(&limit) {
        return Err("bound fields/output limit".into());
    }
    let mut counted = 0u64;
    let mut bits = 0u64;
    for class in 0..4 {
        let sum: u32 = frequencies[class].iter().map(|&f| u32::from(f)).sum();
        if sum != 0 && sum != 32768 {
            return Err("bound CDF total".into());
        }
        for symbol in 0..256 {
            let count = u64::from(counts[class][symbol]);
            counted = counted.checked_add(count).ok_or("bound count overflow")?;
            if count == 0 {
                continue;
            }
            let f = u32::from(frequencies[class][symbol]);
            if !(1..=32768).contains(&f) || sum != 32768 {
                return Err("bound unused frequency".into());
            }
            let ceil = if f == 1 {
                0
            } else {
                32 - (f - 1).leading_zeros()
            };
            let minimum = u64::from(15 - ceil);
            bits = bits
                .checked_add(count.checked_mul(minimum).ok_or("bound info overflow")?)
                .ok_or("bound info sum overflow")?;
        }
    }
    if counted != fields as u64 {
        return Err("bound field count mismatch".into());
    }
    let q32 = i64::try_from(bits)
        .map_err(|_| "bound signed info")?
        .checked_mul(32)
        .and_then(|n| n.checked_sub(fields as i64))
        .and_then(|n| n.checked_sub(256))
        .ok_or("bound signed overflow")?;
    let available = i64::try_from(limit - 5)
        .map_err(|_| "bound signed limit")?
        .checked_mul(256)
        .ok_or("bound output overflow")?;
    Ok(Decision {
        minimum_bits: bits,
        fields,
        q32,
        prune: q32 >= available,
    })
}
