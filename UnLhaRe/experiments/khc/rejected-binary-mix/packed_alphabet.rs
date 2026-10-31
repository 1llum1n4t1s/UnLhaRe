//! 診断専用の正準 bitmap + Lehmer rank。製品の wire format ではない。

use std::cmp::Ordering;
use std::fmt::Write;

type Result<T> = super::Result<T>;
const SYMBOLS: usize = 257;
const BITMAP_BYTES: usize = 33;
// 257! とその直下の順位は 212 bytes に収まる。演算中もこの上限を守る。
const LIMBS: usize = 53;

#[derive(Clone, PartialEq, Eq)]
struct Integer([u32; LIMBS]);

impl Integer {
    fn zero() -> Self {
        Self([0; LIMBS])
    }

    fn one() -> Self {
        let mut value = Self::zero();
        value.0[0] = 1;
        value
    }

    fn compare(&self, other: &Self) -> Ordering {
        self.0.iter().rev().cmp(other.0.iter().rev())
    }

    fn multiply_small(&mut self, factor: u32) -> Result<()> {
        let mut carry = 0u64;
        for limb in &mut self.0 {
            let value = u64::from(*limb) * u64::from(factor) + carry;
            *limb = value as u32;
            carry = value >> 32;
        }
        if carry != 0 {
            return Err("packed alphabet integer multiplication overflow".into());
        }
        Ok(())
    }

    fn add_small(&mut self, value: u32) -> Result<()> {
        let mut carry = u64::from(value);
        for limb in &mut self.0 {
            let sum = u64::from(*limb) + carry;
            *limb = sum as u32;
            carry = sum >> 32;
        }
        if carry != 0 {
            return Err("packed alphabet integer addition overflow".into());
        }
        Ok(())
    }

    fn subtract_small(&mut self, value: u32) -> Result<()> {
        let mut borrow = u64::from(value);
        for limb in &mut self.0 {
            let old = u64::from(*limb);
            *limb = old.wrapping_sub(borrow) as u32;
            borrow = u64::from(old < borrow);
        }
        if borrow != 0 {
            return Err("packed alphabet integer subtraction underflow".into());
        }
        Ok(())
    }

    fn divide_small(&mut self, divisor: u32) -> Result<u32> {
        if divisor == 0 {
            return Err("packed alphabet integer division by zero".into());
        }
        let mut remainder = 0u64;
        for limb in self.0.iter_mut().rev() {
            let value = (remainder << 32) | u64::from(*limb);
            *limb = (value / u64::from(divisor)) as u32;
            remainder = value % u64::from(divisor);
        }
        Ok(remainder as u32)
    }

    fn byte_width(&self) -> usize {
        for (index, &limb) in self.0.iter().enumerate().rev() {
            if limb != 0 {
                let bits = index * 32 + (32 - limb.leading_zeros()) as usize;
                return bits.div_ceil(8);
            }
        }
        0
    }

    fn from_le_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > LIMBS * 4 {
            return Err("packed alphabet integer byte bound exceeded".into());
        }
        let mut value = Self::zero();
        for (index, &byte) in bytes.iter().enumerate() {
            value.0[index / 4] |= u32::from(byte) << ((index % 4) * 8);
        }
        Ok(value)
    }

    fn append_le_bytes(&self, bytes: &mut Vec<u8>, width: usize) -> Result<()> {
        if width > LIMBS * 4 || self.byte_width() > width {
            return Err("packed alphabet integer does not fit width".into());
        }
        for index in 0..width {
            bytes.push((self.0[index / 4] >> ((index % 4) * 8)) as u8);
        }
        Ok(())
    }
}

fn factorial(k: usize) -> Result<Integer> {
    if !(1..=SYMBOLS).contains(&k) {
        return Err("packed alphabet size outside 1..257".into());
    }
    let mut value = Integer::one();
    for factor in 2..=k {
        value.multiply_small(factor as u32)?;
    }
    Ok(value)
}

fn rank_width(factorial: &Integer) -> Result<usize> {
    let mut maximum = factorial.clone();
    maximum.subtract_small(1)?;
    Ok(maximum.byte_width())
}

pub(super) fn encode(order: &[u16]) -> Result<Vec<u8>> {
    let limit = factorial(order.len())?;
    let mut bitmap = [0u8; BITMAP_BYTES];
    for &symbol in order {
        let symbol = usize::from(symbol);
        if symbol >= SYMBOLS {
            return Err("packed alphabet symbol outside 0..256".into());
        }
        let mask = 1 << (symbol % 8);
        if bitmap[symbol / 8] & mask != 0 {
            return Err("packed alphabet duplicate symbol".into());
        }
        bitmap[symbol / 8] |= mask;
    }
    if bitmap[0] & 1 == 0 {
        return Err("packed alphabet sentinel 0 missing".into());
    }
    let mut remaining: Vec<u16> = (0..SYMBOLS as u16)
        .filter(|&symbol| bitmap[usize::from(symbol) / 8] & (1 << (symbol % 8)) != 0)
        .collect();
    let mut rank = Integer::zero();
    for &symbol in order {
        let digit = remaining
            .iter()
            .position(|&candidate| candidate == symbol)
            .ok_or("packed alphabet rank symbol missing")?;
        rank.multiply_small(remaining.len() as u32)?;
        rank.add_small(digit as u32)?;
        remaining.remove(digit);
    }
    if rank.compare(&limit) != Ordering::Less {
        return Err("packed alphabet rank outside factorial".into());
    }
    let width = rank_width(&limit)?;
    let mut bytes = Vec::with_capacity(BITMAP_BYTES + width);
    bytes.extend_from_slice(&bitmap);
    rank.append_le_bytes(&mut bytes, width)?;
    Ok(bytes)
}

pub(super) fn decode(bytes: &[u8]) -> Result<Vec<u16>> {
    if bytes.len() < BITMAP_BYTES || bytes.len() > BITMAP_BYTES + LIMBS * 4 {
        return Err("packed alphabet byte size outside bounds".into());
    }
    let bitmap = &bytes[..BITMAP_BYTES];
    if bitmap[32] & 0xfe != 0 {
        return Err("packed alphabet high bitmap padding nonzero".into());
    }
    if bitmap[0] & 1 == 0 {
        return Err("packed alphabet sentinel 0 missing".into());
    }
    let k = bitmap.iter().map(|byte| byte.count_ones() as usize).sum();
    let limit = factorial(k)?;
    let width = rank_width(&limit)?;
    if bytes.len() != BITMAP_BYTES + width {
        return Err("packed alphabet rank byte width not canonical".into());
    }
    let mut rank = Integer::from_le_bytes(&bytes[BITMAP_BYTES..])?;
    if rank.compare(&limit) != Ordering::Less {
        return Err("packed alphabet rank outside factorial".into());
    }
    let mut digits = vec![0usize; k];
    for radix in 1..=k {
        digits[k - radix] = rank.divide_small(radix as u32)? as usize;
    }
    if rank != Integer::zero() {
        return Err("packed alphabet rank has residual quotient".into());
    }
    let mut remaining: Vec<u16> = (0..SYMBOLS as u16)
        .filter(|&symbol| bitmap[usize::from(symbol) / 8] & (1 << (symbol % 8)) != 0)
        .collect();
    let mut order = Vec::with_capacity(k);
    for digit in digits {
        if digit >= remaining.len() {
            return Err("packed alphabet factoradic digit outside bounds".into());
        }
        order.push(remaining.remove(digit));
    }
    Ok(order)
}

#[derive(Default)]
struct SelfChecks {
    cases: usize,
    checks: usize,
    tiny_permutations: usize,
    full_alphabet_cases: usize,
    min_max_cases: usize,
    adversarial_cases: usize,
}

impl SelfChecks {
    fn require(&mut self, condition: bool, message: &str) -> Result<()> {
        self.checks += 1;
        if !condition {
            return Err(format!("packed alphabet self-check: {message}"));
        }
        Ok(())
    }

    fn roundtrip(&mut self, order: &[u16]) -> Result<Vec<u8>> {
        self.cases += 1;
        let encoded = encode(order)?;
        let decoded = decode(&encoded)?;
        self.require(decoded == order, "order roundtrip")?;
        self.require(encode(&decoded)? == encoded, "actual byte roundtrip")?;
        Ok(encoded)
    }

    fn reject_bytes(&mut self, bytes: &[u8]) -> Result<()> {
        self.cases += 1;
        self.adversarial_cases += 1;
        self.require(decode(bytes).is_err(), "invalid bytes accepted")
    }

    fn reject_order(&mut self, order: &[u16]) -> Result<()> {
        self.cases += 1;
        self.adversarial_cases += 1;
        self.require(encode(order).is_err(), "invalid order accepted")
    }
}

// 小さい順列の独立 oracle: 各位置の右側の逆転数 × 残りの階乗。
fn tiny_rank(order: &[u16]) -> u64 {
    let mut result = 0;
    for (index, &symbol) in order.iter().enumerate() {
        let inversions = order[index + 1..]
            .iter()
            .filter(|&&right| right < symbol)
            .count() as u64;
        let weight = (1..order.len() - index).fold(1u64, |product, n| product * n as u64);
        result += inversions * weight;
    }
    result
}

fn tiny_permutations(order: &mut [u16], index: usize, checks: &mut SelfChecks) -> Result<()> {
    if index == order.len() {
        let bytes = checks.roundtrip(order)?;
        let mut rank_bytes = [0u8; 8];
        let rank = &bytes[BITMAP_BYTES..];
        rank_bytes[..rank.len()].copy_from_slice(rank);
        checks.require(
            u64::from_le_bytes(rank_bytes) == tiny_rank(order),
            "tiny rank oracle",
        )?;
        checks.tiny_permutations += 1;
        return Ok(());
    }
    for next in index..order.len() {
        order.swap(index, next);
        tiny_permutations(order, index + 1, checks)?;
        order.swap(index, next);
    }
    Ok(())
}

fn self_checks() -> Result<SelfChecks> {
    let mut checks = SelfChecks::default();
    for k in 1..=6 {
        tiny_permutations(&mut (0..k as u16).collect::<Vec<_>>(), 0, &mut checks)?;
    }
    // 全ての k の最小・最大順位と固定幅を検査し、両端の 257-symbol 表も復元する。
    for k in 1..=SYMBOLS {
        let mut order: Vec<u16> = (0..k as u16).collect();
        let minimum = checks.roundtrip(&order)?;
        let limit = factorial(k)?;
        let width = rank_width(&limit)?;
        checks.require(minimum.len() == BITMAP_BYTES + width, "minimum fixed width")?;
        checks.require(
            minimum[BITMAP_BYTES..].iter().all(|&byte| byte == 0),
            "minimum rank zero",
        )?;
        order.reverse();
        let maximum = checks.roundtrip(&order)?;
        let mut expected = limit.clone();
        expected.subtract_small(1)?;
        checks.require(
            Integer::from_le_bytes(&maximum[BITMAP_BYTES..])? == expected,
            "maximum rank factorial minus one",
        )?;
        checks.min_max_cases += 2;
        if k == SYMBOLS {
            checks.full_alphabet_cases += 2;
            checks.require(
                width == 212 && maximum.len() == 245,
                "full alphabet exact width",
            )?;
        }
        // k! 自体は無効。k=1 は rank が 0 bytes なので余分な byte として拒否。
        let mut invalid_rank = minimum[..BITMAP_BYTES].to_vec();
        limit.append_le_bytes(&mut invalid_rank, width.max(limit.byte_width()))?;
        checks.reject_bytes(&invalid_rank)?;
    }
    checks.require(
        encode(&[0])?.len() == BITMAP_BYTES,
        "singleton rank zero bytes",
    )?;
    checks.reject_order(&[])?;
    checks.reject_order(&[1])?;
    checks.reject_order(&[0, 0])?;
    checks.reject_order(&[0, 257])?;
    checks.reject_order(&vec![0; 258])?;
    checks.reject_bytes(&[])?;
    checks.reject_bytes(&[0; BITMAP_BYTES - 1])?;
    checks.reject_bytes(&[0; BITMAP_BYTES])?;
    let valid = encode(&[256, 0, 128, 1])?;
    let mut short = valid.clone();
    short.pop();
    checks.reject_bytes(&short)?;
    let mut long = valid.clone();
    long.push(0);
    checks.reject_bytes(&long)?;
    let mut no_sentinel = valid.clone();
    no_sentinel[0] &= !1;
    checks.reject_bytes(&no_sentinel)?;
    for bit in 1..8 {
        let mut padding = valid.clone();
        padding[32] |= 1 << bit;
        checks.reject_bytes(&padding)?;
    }
    let mut changed_k = encode(&[0])?;
    changed_k[0] |= 2;
    checks.reject_bytes(&changed_k)?;
    let mut out_of_rank = valid.clone();
    out_of_rank[BITMAP_BYTES] = 255;
    checks.reject_bytes(&out_of_rank)?;
    checks.reject_bytes(&vec![0; BITMAP_BYTES + LIMBS * 4 + 1])?;
    checks.roundtrip(&[256, 0])?;
    checks.roundtrip(&[128, 256, 0, 1, 255, 127])?;
    Ok(checks)
}

pub(super) fn report_json(order: &[u16]) -> Result<String> {
    let bytes = encode(order)?;
    let restored = decode(&bytes)?;
    if restored != order || encode(&restored)? != bytes {
        return Err("packed alphabet actual metadata roundtrip failed".into());
    }
    let checks = self_checks()?;
    let mut byte_json = String::from("[");
    for (index, byte) in bytes.iter().enumerate() {
        if index != 0 {
            byte_json.push(',');
        }
        write!(byte_json, "{byte}").map_err(|error| error.to_string())?;
    }
    byte_json.push(']');
    Ok(format!(
        "{{\"bitmap_bytes\":{BITMAP_BYTES},\"rank_bytes\":{},\"k\":{},\"metadata_bytes\":{},\"bytes\":{byte_json},\"roundtrip\":true,\"self_checks\":{{\"passed\":true,\"cases\":{},\"checks\":{},\"tiny_permutations\":{},\"full_alphabet_cases\":{},\"min_max_cases\":{},\"adversarial_cases\":{}}}}}",
        bytes.len() - BITMAP_BYTES,
        order.len(),
        bytes.len(),
        checks.cases,
        checks.checks,
        checks.tiny_permutations,
        checks.full_alphabet_cases,
        checks.min_max_cases,
        checks.adversarial_cases,
    ))
}
