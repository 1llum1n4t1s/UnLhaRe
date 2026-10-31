//! full-token CDFの整数arith witness。実codec／速度証拠ではない。
type Result<T> = std::result::Result<T, &'static str>;
const D: u128 = 1u128 << 120;
const Q: u32 = 1 << 18;
fn mul_shift(p: u128, m: u32) -> Result<u32> {
    if p > D || m >= Q {
        return Err("mass/multiplier");
    }
    let lo = p as u64;
    let hi = p >> 64;
    let carry = (u128::from(lo) * u128::from(m)) >> 64;
    let t = hi * u128::from(m) + carry;
    u32::try_from(t >> 56).map_err(|_| "shift conversion")
}
fn oracle(p: u128, m: u32) -> u32 {
    let mut remainder = 0u128;
    let mut quotient = 0u32;
    for bit in (0..18).rev() {
        remainder *= 2;
        if m & (1 << bit) != 0 {
            remainder += p;
        }
        quotient = quotient * 2 + (remainder >> 120) as u32;
        remainder &= D - 1;
    }
    quotient
}
fn endpoint(ordinal: usize, n: usize, p: u128) -> Result<u32> {
    if !(1..=257).contains(&n) || ordinal > n {
        return Err("leaf support/ordinal");
    }
    let scaled = mul_shift(p, Q - n as u32)?;
    (ordinal as u32)
        .checked_add(scaled)
        .ok_or("CDF add overflow")
}
fn run() -> Result<()> {
    let mut compared = 0usize;
    let mut positive = 0usize;
    for n in 1..=257 {
        let m = Q - n as u32;
        for k in (0u32..=Q).step_by(257) {
            let p = u128::from(k) << 102;
            if mul_shift(p, m)? != oracle(p, m) {
                return Err("independent oracle mismatch");
            }
            compared += 1;
        }
        for power in 0..=120 {
            let p = 1u128 << power;
            for v in [p.saturating_sub(1), p, p.saturating_add(1).min(D)] {
                if mul_shift(v, m)? != oracle(v, m) {
                    return Err("power boundary mismatch");
                }
                compared += 1;
            }
        }
        if endpoint(0, n, 0)? != 0 || endpoint(n, n, D)? != Q {
            return Err("CDF terminal");
        }
        let mut previous = 0;
        for ordinal in 1..=n {
            let p = if ordinal == n {
                D
            } else {
                (D / n as u128) * ordinal as u128
            };
            let next = endpoint(ordinal, n, p)?;
            if next <= previous || next > Q {
                return Err("nonpositive leaf frequency");
            }
            previous = next;
            positive += 1;
        }
    }
    let invalid = [
        mul_shift(D + 1, 1).is_err(),
        mul_shift(0, Q).is_err(),
        endpoint(0, 0, 0).is_err(),
        endpoint(0, 258, 0).is_err(),
        endpoint(2, 1, 0).is_err(),
        endpoint(0, 1, D + 1).is_err(),
    ];
    if invalid.iter().any(|&v| !v) {
        return Err("invalid accepted");
    }
    // 旧scale15の全freqでroot branch mass計算がoverflowせずDへpartitionする。
    let mut partitions = 0usize;
    for frequency in 1u128..=32768 {
        let a = (D >> 15) * frequency;
        let b = (D >> 15) * (32768 - frequency);
        if a + b != D || a == 0 || a > D {
            return Err("root mass partition");
        }
        for n in [1, 2, 256, 257] {
            if mul_shift(a, Q - n)? != oracle(a, Q - n) {
                return Err("root scaled partition");
            }
            partitions += 1;
        }
    }
    println!(
        "{{\"wide_shift_oracle_checks\":{compared},\"positive_leaf_checks\":{positive},\"root_mass_partition_checks\":{partitions},\"invalid_rejects\":6,\"all_supports_1_to_257\":true,\"Q\":262144,\"exact_integer\":true,\"real_codec\":false,\"speed_evidence\":false}}"
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
