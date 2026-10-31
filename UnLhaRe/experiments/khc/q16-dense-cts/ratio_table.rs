#![allow(dead_code)]
#[path = "../native32-quotient/exact_div.rs"]
mod legacy;
pub const Q: u64 = 1 << 16;
pub const MAX_OBSERVATIONS: u32 = 562_036_803;
type Result<T> = std::result::Result<T, &'static str>;
pub struct KtTable {
    reciprocals: Vec<u64>,
}
impl KtTable {
    pub fn new() -> Result<Self> {
        let mut reciprocals = Vec::new();
        reciprocals.try_reserve_exact(Q as usize + 1)
            .map_err(|_| "Q16 reciprocal allocation failed")?;
        reciprocals.resize(Q as usize + 1, 0);
        for (d, value) in reciprocals.iter_mut().enumerate().skip(1) {
            *value = (((1u64 << 48) - 1) / d as u64) + 1;
        }
        Ok(Self { reciprocals })
    }
    #[inline(always)]
    pub fn ratio(&self, a: u64, b: u64, d: u64) -> Result<u64> {
        if d == 0 {
            return Err("zero denominator");
        }
        let n = a.checked_mul(b).ok_or("product overflow")?;
        if d == Q {
            return Ok(n >> 16);
        }
        if d < Q {
            let bound = Q * d;
            if n == bound {
                // 等号ではreciprocal積が2^64以上となる。乗算する前に返す。
                return Ok(Q);
            }
            if n < bound {
                let r = self.reciprocals[d as usize];
                let product = n.checked_mul(r).ok_or("reciprocal product overflow")?;
                return Ok(product >> 48);
            }
        }
        legacy::ratio(a, b, d).map(|(quotient, _)| quotient)
    }
    #[inline(always)]
    pub fn kt(&self, zero: u32, one: u32) -> Result<(u64, u64, u64)> {
        let total = zero.checked_add(one).ok_or("CTS node total overflow")?;
        if total > MAX_OBSERVATIONS {
            return Err("CTS node observation cap exceeded");
        }
        if zero == one {
            return Ok((Q / 2, 1, 0));
        }
        let d = u64::from(total) + 1;
        let n = (u64::from(zero) << 16) + Q / 2;
        let quotient = self.ratio(n, 1, d)?.clamp(1, Q - 1);
        let method = if d <= Q { 2 } else { 3 };
        let reciprocal = if d <= Q { self.reciprocals[d as usize] } else { 0 };
        Ok((quotient, method, reciprocal))
    }
    pub fn audit_bytes(&self) -> usize {
        self.reciprocals.len() * std::mem::size_of::<u64>()
    }
}
