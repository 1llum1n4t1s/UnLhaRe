type Result<T> = std::result::Result<T, String>;
pub const NODES: usize = 1365;
pub const GROUPS: usize = 3;
pub const HISTORIES: usize = 1024;
pub const CAP: u32 = 3825340;
pub const MAX_BITS: usize = 142338;
pub const MAX_BYTES: usize = 17793;
fn allocated<T: Clone>(len: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(len).map_err(|_| "model allocation")?;
    v.resize(len, value);
    Ok(v)
}

fn valid_frequency(f: [u16; 4], k: usize) -> Result<()> {
    if !(2..=4).contains(&k)
        || f[..k].iter().any(|&v| v < 2)
        || f[k..].iter().any(|&v| v != 0)
        || f[..k].iter().map(|&v| u32::from(v)).sum::<u32>() != 32768
    {
        return Err("CDF support/total/tail".into());
    }
    Ok(())
}
pub struct Hist {
    pub counts: Vec<[u32; 4]>,
}
impl Hist {
    pub fn new() -> Result<Self> {
        Ok(Self {
            counts: allocated(GROUPS * NODES, [0; 4])?,
        })
    }

    pub fn capacity_bytes(&self) -> usize {
        self.counts.capacity() * std::mem::size_of::<[u32; 4]>() + std::mem::size_of::<Self>()
    }
}
pub fn quantize(counts: [u32; 4], k: usize) -> Result<[u16; 4]> {
    if !(2..=4).contains(&k) || counts[k..].iter().any(|&v| v != 0) {
        return Err("quantization prefix/tail".into());
    }
    let raw = counts.iter().map(|&v| u64::from(v)).sum::<u64>();
    if raw > u64::from(CAP) {
        return Err("quantization raw CAP".into());
    }
    let weights = if raw == 0 { [1u32; 4] } else { counts };
    let total = if raw == 0 { k as u64 } else { raw };
    let budget = 32768 - 2 * k as u64;
    let mut result = [0u16; 4];
    let mut remainders = [0u64; 4];
    let mut used = 0u64;
    for i in 0..k {
        let product = budget
            .checked_mul(u64::from(weights[i]))
            .ok_or("Hamilton product overflow")?;
        let floor = product / total;
        remainders[i] = product % total;
        result[i] = u16::try_from(floor + 2).map_err(|_| "Hamilton frequency range")?;
        used += floor;
    }
    let left = usize::try_from(budget - used).map_err(|_| "Hamilton leftover")?;
    if left >= k {
        return Err("Hamilton leftover bound".into());
    }
    let mut order = [0usize, 1, 2, 3];
    order[..k].sort_by(|&a, &b| remainders[b].cmp(&remainders[a]).then(a.cmp(&b)));
    for &i in &order[..left] {
        result[i] = result[i].checked_add(1).ok_or("Hamilton add overflow")?;
    }
    valid_frequency(result, k)?;
    Ok(result)
}

// 固定整数LUT。float生成・精度sweepは行わない。
const fn make_lut() -> [u16; 256] {
    let mut v = [0u16; 256];
    let mut i = 0;
    while i < 64 {
        v[i] = (i + 2) as u16;
        i += 1;
    }
    let mut e = 6;
    while e <= 13 {
        let base = 1u32 << e;
        let mut j = 1;
        while j <= 24 {
            let value = base + (j * base).div_ceil(24);
            v[i] = if value > 16383 { 16383 } else { value as u16 };
            i += 1;
            j += 1;
        }
        e += 1;
    }
    v
}
pub const MINOR_LUT: [u16; 256] = make_lut();

pub fn floor_code(value: u16) -> Result<u8> {
    if !(2..=16383).contains(&value) {
        return Err("minor range".into());
    }
    let i = MINOR_LUT.partition_point(|&v| v <= value) - 1;
    u8::try_from(i).map_err(|_| "minor code".into())
}
fn largest(f: [u16; 4], k: usize) -> usize {
    let mut d = 0;
    for i in 1..k {
        if f[i] > f[d] {
            d = i;
        }
    }
    d
}
pub fn compact_frequency(original: [u16; 4], k: usize) -> Result<[u16; 4]> {
    valid_frequency(original, k)?;
    let (mode, _) = leaf_mode(original, k)?;
    if mode < 2 {
        return Ok(original);
    }
    let dominant = largest(original, k);
    let mut f = [0u16; 4];
    let mut sum = 0u32;
    for i in 0..k {
        if i != dominant {
            f[i] = MINOR_LUT[usize::from(floor_code(original[i])?)];
            sum = sum
                .checked_add(u32::from(f[i]))
                .ok_or("minor sum overflow")?;
        }
    }
    f[dominant] = u16::try_from(
        32768u32
            .checked_sub(sum)
            .ok_or("minor residual underflow")?,
    )
    .map_err(|_| "minor residual range")?;
    valid_frequency(f, k)?;
    if f[dominant] < original[dominant] || f[..k].iter().any(|&v| v > f[dominant]) {
        return Err("minor dominant invariant".into());
    }
    Ok(f)
}
// minor leafの厳密mode：uniform優先、pure完全一致、それ以外はcompact。
pub fn leaf_mode(f: [u16; 4], k: usize) -> Result<(u32, usize)> {
    valid_frequency(f, k)?;
    if f == quantize([0; 4], k)? {
        return Ok((0, 0));
    }
    for dominant in 0..k {
        let mut p = [0u16; 4];
        p[..k].fill(2);
        p[dominant] = 32768 - 2 * (k as u16 - 1);
        if f == p {
            return Ok((1, dominant));
        }
    }
    Ok((2, largest(f, k)))
}
pub fn reverse_history(history: u16) -> u16 {
    let mut result = 0;
    for d in 0..5 {
        result |= ((history >> (2 * d)) & 3) << (2 * (4 - d));
    }
    result
}
