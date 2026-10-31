//! 検査済みKTだけの厳密reciprocal table。速度採用は別途必要。
#[path = "../native32-quotient/exact_div.rs"]
mod exact_div;

pub const TABLE_MAX: usize = 65536;
const MAX_OBSERVATIONS: u32 = 562_036_803;
const Q: u64 = 1 << 32;
type Result<T> = std::result::Result<T, &'static str>;

pub struct KtTable {
    reciprocals: Vec<u64>,
}
impl KtTable {
    pub fn new() -> Result<Self> {
        let mut reciprocals = Vec::new();
        reciprocals
            .try_reserve_exact(TABLE_MAX + 1)
            .map_err(|_| "KT reciprocal allocation failed")?;
        reciprocals.resize(TABLE_MAX + 1, 0);
        let base = 1_u128 << 64;
        for (d, reciprocal) in reciprocals.iter_mut().enumerate().skip(2) {
            *reciprocal = ((base + d as u128 - 1) / d as u128) as u64;
        }
        Ok(Self { reciprocals })
    }

    // domain検査を同関数へ局所化し、unchecked helperを公開しない。
    #[inline(always)]
    pub fn kt(&self, zero: u32, one: u32) -> Result<(u64, u64, u64)> {
        let total = zero.checked_add(one).ok_or("CTS node total overflow")?;
        if total > MAX_OBSERVATIONS {
            return Err("CTS node observation cap exceeded");
        }
        if zero == one {
            return Ok((Q / 2, 1, 0));
        }
        let denominator = u64::from(total) + 1;
        let (quotient, method, reciprocal) = if denominator <= TABLE_MAX as u64 {
            let reciprocal = self.reciprocals[denominator as usize];
            let numerator = (u64::from(zero) << 32) + Q / 2;
            // n<Q*d, d<=sqrt(Q)なのでceil逆数の誤差は残余の1/d刻み未満。
            // 汎用u64商へこの補正省略を流用しない。
            let quotient = ((u128::from(numerator) * u128::from(reciprocal)) >> 64) as u64;
            (quotient, 2, reciprocal)
        } else {
            let (quotient, _) = exact_div::ratio(Q / 2, 2 * u64::from(zero) + 1, denominator)
                .map_err(|_| "CTS ratio product overflow")?;
            (quotient, 3, 0)
        };
        if !(1..Q).contains(&quotient) {
            return Err("CTS Q32 probability outside bounds");
        }
        Ok((quotient, method, reciprocal))
    }

    #[cfg(khc_kt_reciprocal_audit)]
    pub fn audit(&self, zero: u32, one: u32) -> Result<[u64; 4]> {
        match self.kt(zero, one) {
            Ok((quotient, method, reciprocal)) => Ok([quotient, 0, method, reciprocal]),
            Err("CTS node total overflow") => Ok([0, 1, 0, 0]),
            Err("CTS node observation cap exceeded") => Ok([0, 2, 0, 0]),
            Err(e) => Err(e),
        }
    }

    #[cfg(any(khc_kt_reciprocal_audit, khc_mixture_reuse_audit))]
    pub fn audit_bytes(&self) -> usize {
        self.reciprocals.len() * std::mem::size_of::<u64>()
    }
}
