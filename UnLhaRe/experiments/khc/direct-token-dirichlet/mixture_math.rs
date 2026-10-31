const PRECISION: u64 = 32768;
const STRENGTH: u64 = 64;

pub(crate) struct MixtureScale {
    root_total: u32,
    local_total: u32,
    denominator: u64,
    reciprocal: u64,
}

impl MixtureScale {
    pub(crate) fn new(root_total: u32, local_total: u32) -> Result<Self, &'static str> {
        if !(1..=16383).contains(&root_total) || local_total > 16383 {
            return Err("mixture totals out of bounds");
        }
        let denominator = u64::from(root_total)
            .checked_mul(STRENGTH + u64::from(local_total)).ok_or("denominator overflow")?;
        let reciprocal = (u64::MAX / denominator)
            .checked_add(u64::from(u64::MAX % denominator == denominator - 1))
            .ok_or("reciprocal overflow")?;
        Ok(Self { root_total, local_total, denominator, reciprocal })
    }

    fn floor_mass(&self, mass: u64) -> Result<u32, &'static str> {
        if mass > self.denominator { return Err("mixture mass out of bounds"); }
        let numerator = mass.checked_mul(PRECISION).ok_or("mixture numerator overflow")?;
        let mut quotient = ((u128::from(numerator) * u128::from(self.reciprocal)) >> 64) as u64;
        let product = quotient.checked_mul(self.denominator).ok_or("quotient overflow")?;
        let remainder = numerator.checked_sub(product).ok_or("quotient too large")?;
        if remainder >= self.denominator { quotient += 1; }
        let final_product = quotient.checked_mul(self.denominator).ok_or("quotient overflow")?;
        if quotient > PRECISION || final_product > numerator || numerator - final_product >= self.denominator {
            return Err("quotient certificate");
        }
        Ok(quotient as u32)
    }

    pub(crate) fn floor(&self, root_prefix: u32, local_prefix: u32) -> Result<u32, &'static str> {
        if root_prefix > self.root_total || local_prefix > self.local_total {
            return Err("mixture prefix out of bounds");
        }
        let mass = STRENGTH.checked_mul(u64::from(root_prefix))
            .and_then(|root| u64::from(self.root_total).checked_mul(u64::from(local_prefix))
                .and_then(|local| root.checked_add(local))).ok_or("mixture mass overflow")?;
        self.floor_mass(mass)
    }

    #[cfg(model_audit)]
    pub(crate) fn audit_parameters(&self) -> (u32, u32, u64, u64) {
        (self.root_total, self.local_total, self.denominator, self.reciprocal)
    }

    #[cfg(model_audit)]
    pub(crate) fn audit_floor_mass(&self, mass: u64) -> Result<u32, &'static str> {
        self.floor_mass(mass)
    }
}

