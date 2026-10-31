//! 四つの推定商を同時計算し、各整数残余certificateで確定する研究helper。
pub const Q: u64 = 1 << 32;
pub const SHIFT: u8 = 1;
pub const ESTIMATED: u8 = 2;
pub const DOWN: u8 = 4;
pub const UP: u8 = 8;
pub const NATIVE: u8 = 16;
pub const CERTIFICATE_FALLBACK: u8 = 32;
pub const COMPACT: u8 = 64;
pub type Ratio = Result<(u64, u8), &'static str>;

#[derive(Clone, Copy)]
pub enum Backend { Scalar, Avx2 }
pub struct BatchEngine { backend: Backend }
pub fn avx2_available() -> bool {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    { std::is_x86_feature_detected!("avx2") }
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    { false }
}
impl BatchEngine {
    pub fn new(backend: Backend) -> Result<Self, &'static str> {
        if matches!(backend, Backend::Avx2) && !avx2_available() {
            return Err("AVX2 backend unavailable");
        }
        Ok(Self { backend })
    }
    #[allow(dead_code)]
    pub fn auto() -> Self {
        #[cfg(khc_force_scalar_batch)]
        { Self { backend: Backend::Scalar } }
        #[cfg(not(khc_force_scalar_batch))]
        { Self { backend: if avx2_available() { Backend::Avx2 } else { Backend::Scalar } } }
    }
    #[allow(dead_code)]
    pub fn ratio(&self, a: u64, b: u64, d: u64) -> Ratio {
        self.ratio4([a, 0, 0, 0], [b, 1, 1, 1], [d, 1, 1, 1])[0]
    }
    // 診断flags/個別Resultを通常kernelへ持ち込まない。Noneは旧経路へ戻す合図。
    #[inline(always)]
    pub fn try_nonzero4(&self, n: [u64; 4], d: [u64; 4]) -> Option<[u64; 4]> {
        for lane in 0..4 {
            if d[lane] == 0 || d[lane] >= Q || (n[lane] >> 32) >= d[lane] {
                return None;
            }
        }
        let nf = n.map(|value| value as f64);
        let df = d.map(|value| value as f64);
        let guesses = match self.backend {
            Backend::Scalar => std::array::from_fn(|lane| nf[lane] / df[lane]),
            Backend::Avx2 => {
                #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
                // new/autoで証明済み。4doubleの配列境界も維持する。
                { unsafe { divide4_avx2(nf, df) } }
                #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
                { std::array::from_fn(|lane| nf[lane] / df[lane]) }
            }
        };
        let mut output = [0; 4];
        for lane in 0..4 {
            let estimate = guesses[lane];
            if !estimate.is_finite() || estimate < 0.0 || estimate > Q as f64 + 1.0 {
                return None;
            }
            let mut q = estimate as i64 as u64;
            let mut p = q.checked_mul(d[lane])?;
            // p=q*dの恒等式をchecked加減で保存し、最後に厳密な余りを検査する。
            if p > n[lane] {
                q = q.checked_sub(1)?;
                p = p.checked_sub(d[lane])?;
            }
            if n[lane].checked_sub(p)? >= d[lane] {
                q = q.checked_add(1)?;
                p = p.checked_add(d[lane])?;
            }
            if p > n[lane] || n[lane] - p >= d[lane] { return None; }
            output[lane] = q;
        }
        Some(output)
    }

    // 数値E2Eは実try_nonzero4を呼ぶ。無効batchでは元のlane別拒否順を維持。
    #[allow(dead_code)]
    pub fn audit_ratio4(&self, a: [u64; 4], b: [u64; 4], d: [u64; 4]) -> [Ratio; 4] {
        let product: Option<[u64; 4]> = (|| {
            Some([a[0].checked_mul(b[0])?, a[1].checked_mul(b[1])?,
                  a[2].checked_mul(b[2])?, a[3].checked_mul(b[3])?])
        })();
        if let Some(n) = product {
            if let Some(q) = self.try_nonzero4(n, d) {
                return std::array::from_fn(|lane| Ok((q[lane], COMPACT)));
            }
        }
        self.ratio4(a, b, d)
    }

    pub fn ratio4(&self, a: [u64; 4], b: [u64; 4], d: [u64; 4]) -> [Ratio; 4] {
        let mut output = [Ok((0, 0)); 4];
        let mut numerator = [0_u64; 4];
        let mut eligible = [false; 4];
        let mut nf = [0.0_f64; 4];
        let mut df = [1.0_f64; 4];
        for lane in 0..4 {
            if d[lane] == 0 { output[lane] = Err("zero denominator"); continue; }
            let Some(n) = a[lane].checked_mul(b[lane]) else {
                output[lane] = Err("product overflow"); continue;
            };
            if d[lane].is_power_of_two() {
                output[lane] = Ok((n >> d[lane].trailing_zeros(), SHIFT)); continue;
            }
            if d[lane] >= Q || (n >> 32) >= d[lane] {
                output[lane] = Ok((n / d[lane], NATIVE)); continue;
            }
            numerator[lane] = n;
            eligible[lane] = true;
            // unsigned変換。nをi64として再解釈してはならない。
            nf[lane] = n as f64;
            df[lane] = d[lane] as f64;
        }
        if !eligible.iter().any(|value| *value) { return output; }
        let guesses = match self.backend {
            Backend::Scalar => std::array::from_fn(|lane| nf[lane] / df[lane]),
            Backend::Avx2 => {
                #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
                // new/autoでCPUとOSのAVX2使用可能性を確認済み。
                { unsafe { divide4_avx2(nf, df) } }
                #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
                { std::array::from_fn(|lane| nf[lane] / df[lane]) }
            }
        };
        for lane in 0..4 {
            if eligible[lane] { output[lane] = certify(numerator[lane], d[lane], guesses[lane]); }
        }
        output
    }
}

#[inline(always)]
fn certify(n: u64, d: u64, estimate: f64) -> Ratio {
    // 想定商は0..Q、境界がQへ丸められてもi64域内。bad estimateも検算で拒否する。
    if !estimate.is_finite() || estimate < 0.0 || estimate > Q as f64 + 1.0 {
        return Ok((n / d, ESTIMATED | CERTIFICATE_FALLBACK));
    }
    let mut q = estimate as i64 as u64;
    let mut flags = ESTIMATED;
    let mut product = q.checked_mul(d);
    if product.is_none() || product.is_some_and(|value| value > n) {
        if let Some(lower) = q.checked_sub(1) {
            q = lower;
            flags |= DOWN;
            product = q.checked_mul(d);
        }
    }
    if let Some(value) = product {
        if value <= n && n - value >= d {
            if let Some(higher) = q.checked_add(1) {
                q = higher;
                flags |= UP;
                product = q.checked_mul(d);
            }
        }
    }
    if product.is_some_and(|value| value <= n && n - value < d) { return Ok((q, flags)); }
    Ok((n / d, flags | CERTIFICATE_FALLBACK))
}

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::{_mm256_div_pd, _mm256_setr_pd, _mm256_storeu_pd};
#[cfg(target_arch = "x86")]
use std::arch::x86::{_mm256_div_pd, _mm256_setr_pd, _mm256_storeu_pd};

#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
#[target_feature(enable = "avx2")]
unsafe fn divide4_avx2(n: [f64; 4], d: [f64; 4]) -> [f64; 4] {
    let left = _mm256_setr_pd(n[0], n[1], n[2], n[3]);
    let right = _mm256_setr_pd(d[0], d[1], d[2], d[3]);
    let result = _mm256_div_pd(left, right);
    let mut output = [0.0; 4];
    // outputは正確に4doubleを収める。storeuはalignmentを要求しない。
    unsafe { _mm256_storeu_pd(output.as_mut_ptr(), result); }
    output
}
