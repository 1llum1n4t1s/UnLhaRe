//! Q32可変分母: 16bit整数seed、2段Newton更新、整数残余certificate。
pub const Q: u64 = 1 << 32;
pub const SHIFT: u8 = 1;
pub const REFINED: u8 = 2;
pub const UP: u8 = 4;
pub const FALLBACK: u8 = 8;
pub const CERTIFICATE_FALLBACK: u8 = 16;
const B: u128 = 1 << 64;
const FIRST: usize = 32768;
const SEEDS: usize = 32768;

pub struct RatioTable {
    seeds: Vec<u64>,
}

impl RatioTable {
    pub fn new() -> Result<Self, &'static str> {
        let mut seeds = Vec::new();
        seeds
            .try_reserve_exact(SEEDS)
            .map_err(|_| "seed allocation failed")?;
        for i in FIRST..FIRST + SEEDS {
            seeds.push((1_u64 << 48) / (i as u64 + 1));
        }
        Ok(Self { seeds })
    }

    pub fn bytes(&self) -> usize {
        self.seeds.len() * std::mem::size_of::<u64>()
    }

    #[inline(always)]
    pub fn ratio(&self, a: u64, b: u64, d: u64) -> Result<(u64, u8), &'static str> {
        if d == 0 {
            return Err("zero denominator");
        }
        let n = a.checked_mul(b).ok_or("product overflow")?;
        if d.is_power_of_two() {
            return Ok((n >> d.trailing_zeros(), SHIFT));
        }
        // 想定domain外でも全u64の元の商を維持する。
        if d >= Q || (n >> 32) >= d {
            return Ok((n / d, FALLBACK));
        }
        let s = d.leading_zeros() - 32;
        let normalized = d << s;
        let index = (normalized >> 16) as usize - FIRST;
        let mut reciprocal = u128::from(self.seeds[index]);
        for _ in 0..2 {
            // lower bound r<=B/Dより差は非負。積は2^97未満。
            let residual = B - u128::from(normalized) * reciprocal;
            reciprocal += (reciprocal * residual) >> 64;
        }
        let mut quotient = ((u128::from(n) * reciprocal) >> (64 - s)) as u64;
        let mut product = u128::from(quotient) * u128::from(d);
        let mut flags = REFINED;
        if product <= u128::from(n) && u128::from(n) - product >= u128::from(d) {
            quotient += 1;
            product += u128::from(d);
            flags |= UP;
        }
        // table/refinementの正しさを未検証のまま商として返さない。
        if product <= u128::from(n) && u128::from(n) - product < u128::from(d) {
            return Ok((quotient, flags));
        }
        Ok((n / d, flags | CERTIFICATE_FALLBACK))
    }
}
