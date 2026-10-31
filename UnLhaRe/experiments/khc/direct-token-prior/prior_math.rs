const PRIOR_MASS: u32 = 256;

pub(crate) struct PriorScale { total: u32, reciprocal: u64 }
impl PriorScale {
    pub(crate) fn new(total: u32) -> Result<Self, &'static str> {
        if !(1..=16383).contains(&total) { return Err("prior total outside bounds"); }
        Ok(Self { total, reciprocal: (1u64 << 32) / u64::from(total) })
    }

    pub(crate) fn floor(&self, prefix: u32) -> Result<u32, &'static str> {
        if prefix > self.total { return Err("prior prefix outside bounds"); }
        let numerator = prefix.checked_mul(PRIOR_MASS).ok_or("prior numerator overflow")?;
        // prefix<=Dよりproduct<=256*2^32。下向きreciprocalの誤差は1未満。
        let product = u64::from(numerator).checked_mul(self.reciprocal).ok_or("prior product overflow")?;
        let mut quotient = (product >> 32) as u32;
        let consumed = quotient.checked_mul(self.total).ok_or("prior quotient overflow")?;
        let remainder = numerator.checked_sub(consumed).ok_or("prior overestimate")?;
        if remainder >= self.total { quotient = quotient.checked_add(1).ok_or("prior correction overflow")?; }
        let consumed = quotient.checked_mul(self.total).ok_or("prior certificate overflow")?;
        if quotient > PRIOR_MASS || consumed > numerator || numerator - consumed >= self.total {
            return Err("prior floor certificate failed");
        }
        Ok(quotient)
    }

    #[cfg(model_audit)]
    pub(crate) fn audit_parameters(&self) -> (u32, u64) { (self.total, self.reciprocal) }
}
