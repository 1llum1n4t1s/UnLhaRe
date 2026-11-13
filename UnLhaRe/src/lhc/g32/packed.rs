use super::{MAX_INPUT, Result, allocate};

const LANES: usize = 32;
const THRESHOLD: usize = 65536;
const INDEX_MASK: u32 = (1 << 23) - 1;

pub struct Output {
    pub plain: Vec<u8>,
    pub route: &'static str,
    pub scratch_capacity_words: usize,
    pub result_capacity: usize,
}

fn valid_length(n: usize, primary: usize) -> Result<()> {
    if n == 0 || n > MAX_INPUT + 1 || n - 1 > INDEX_MASK as usize {
        return Err("gather transform length outside bounds".into());
    }
    if primary >= n {
        return Err("gather primary outside rows".into());
    }
    Ok(())
}

fn index_bits(n: usize) -> usize {
    (usize::BITS - (n - 1).leading_zeros()) as usize
}

pub fn auxiliary_len(n: usize) -> usize {
    if n < THRESHOLD {
        0
    } else {
        (31 * index_bits(n)).div_ceil(8)
    }
}

fn validate_anchors(anchors: &[u32; LANES], n: usize, primary: usize) -> Result<()> {
    valid_length(n, primary)?;
    if n < THRESHOLD {
        return Err("gather anchors require a large block".into());
    }
    if anchors[0] as usize != primary {
        return Err("gather anchor zero differs from primary".into());
    }
    for (lane, &row) in anchors.iter().enumerate() {
        if row as usize >= n {
            return Err("gather anchor outside rows".into());
        }
        if anchors[..lane].contains(&row) {
            return Err("gather duplicate anchor".into());
        }
    }
    Ok(())
}

pub fn encode_anchors(anchors: &[u32; LANES], n: usize, primary: usize) -> Result<Vec<u8>> {
    validate_anchors(anchors, n, primary)?;
    let width = index_bits(n);
    let mut bytes = allocate(auxiliary_len(n), 0u8)?;
    for (lane, &row) in anchors[1..].iter().enumerate() {
        for bit in 0..width {
            let offset = lane * width + bit;
            bytes[offset / 8] |= (((row >> bit) & 1) as u8) << (offset % 8);
        }
    }
    Ok(bytes)
}

pub fn decode_anchors(bytes: &[u8], n: usize, primary: usize) -> Result<[u32; LANES]> {
    valid_length(n, primary)?;
    if n < THRESHOLD || bytes.len() != auxiliary_len(n) {
        return Err("gather auxiliary length/threshold mismatch".into());
    }
    let width = index_bits(n);
    let used = 31 * width;
    if !used.is_multiple_of(8) && bytes[bytes.len() - 1] >> (used % 8) != 0 {
        return Err("gather auxiliary nonzero padding".into());
    }
    let mut anchors = [0u32; LANES];
    anchors[0] = primary as u32;
    for (lane, row) in anchors[1..].iter_mut().enumerate() {
        for bit in 0..width {
            let offset = lane * width + bit;
            *row |= (((bytes[offset / 8] >> (offset % 8)) & 1) as u32) << bit;
        }
    }
    validate_anchors(&anchors, n, primary)?;
    Ok(anchors)
}

fn build_table(
    last: &[u16],
    primary: usize,
    alphabet: &[u16],
    counts: &[usize; 257],
) -> Result<Vec<u32>> {
    let n = last.len();
    valid_length(n, primary)?;
    if last[primary] != 0 {
        return Err("gather primary is not sentinel".into());
    }
    if counts[0] != 1 {
        return Err("gather sentinel count".into());
    }
    // alphabet の順序は既存フレームの初出順契約に従う。
    let mut seen = [false; 257];
    for &symbol in alphabet {
        if symbol > 256 || seen[symbol as usize] {
            return Err("gather alphabet outside range or duplicated".into());
        }
        seen[symbol as usize] = true;
    }
    if counts
        .iter()
        .zip(seen)
        .any(|(&count, present)| (count != 0) != present)
    {
        return Err("gather alphabet mismatch".into());
    }
    let mut starts = [0usize; 257];
    let mut total = 0usize;
    for (symbol, &count) in counts.iter().enumerate() {
        starts[symbol] = total;
        total += count;
    }
    if total != n {
        return Err("gather BWT count mismatch".into());
    }
    let mut occurrence = [0usize; 257];
    let mut words = allocate(n, 0u32)?;
    for (row, &symbol) in last.iter().enumerate() {
        if symbol > 256 {
            return Err("gather BWT symbol outside range".into());
        }
        let symbol = symbol as usize;
        let next = starts[symbol] + occurrence[symbol];
        if next >= n {
            return Err("gather LF next outside rows".into());
        }
        let byte = if symbol == 0 { 0 } else { (symbol - 1) as u8 };
        words[row] = (next as u32) | ((byte as u32) << 23);
        occurrence[symbol] += 1;
    }
    // 記号ごとの連続区間を初出順に一度ずつ埋めるので LF は置換になる。
    // 全 next < n の検証が終了してから、この不変な表を走査する。
    Ok(words)
}

fn small_walk(words: &[u32], primary: usize, plain: &mut [u8]) -> Result<()> {
    let n = words.len();
    let mut row = primary;
    for global in 0..n {
        if global > 0 && row == primary {
            return Err("gather LF returned to primary early".into());
        }
        let word = words[row];
        if global > 0 {
            plain[n - 1 - global] = (word >> 23) as u8;
        }
        row = (word & INDEX_MASK) as usize;
    }
    if row != primary {
        return Err("gather small LF endpoint mismatch".into());
    }
    Ok(())
}

fn finish_lanes(
    words: &[u32],
    primary: usize,
    anchors: &[u32; LANES],
    rows: &[u32; LANES],
    plain: &mut [u8],
) -> Result<()> {
    let n = words.len();
    for lane in 0..LANES - 1 {
        if rows[lane] != anchors[lane + 1] {
            return Err("gather LF lane endpoint mismatch".into());
        }
    }
    let q = n / LANES;
    let mut row = rows[LANES - 1] as usize;
    // 剰余は最後のレーンだけを進め、非アクティブな gather は行わない。
    for tail in 0..n % LANES {
        let global = LANES * q + tail;
        if row == primary {
            return Err("gather LF tail returned to primary early".into());
        }
        let word = words[row];
        plain[n - 1 - global] = (word >> 23) as u8;
        row = (word & INDEX_MASK) as usize;
    }
    if row != primary {
        return Err("gather LF final endpoint mismatch".into());
    }
    // 32 区間は終点で連結でき、総歩数は 32*q+n%32=n。
    // LF は置換であり、途中の primary 再訪を拒否したので n-cycle が成立する。
    Ok(())
}

fn scalar_lanes(
    words: &[u32],
    primary: usize,
    anchors: &[u32; LANES],
    plain: &mut [u8],
) -> Result<()> {
    let n = words.len();
    let q = n / LANES;
    let mut rows = *anchors;
    for round in 0..q {
        for (lane, row) in rows.iter_mut().enumerate() {
            let global = lane * q + round;
            let index = *row as usize;
            if global > 0 && index == primary {
                return Err("gather LF lane returned to primary early".into());
            }
            let word = words[index];
            if global > 0 {
                plain[n - 1 - global] = (word >> 23) as u8;
            }
            *row = word & INDEX_MASK;
        }
    }
    finish_lanes(words, primary, anchors, &rows, plain)
}

#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
#[target_feature(enable = "avx2")]
unsafe fn avx2_lanes(
    words: &[u32],
    primary: usize,
    anchors: &[u32; LANES],
    plain: &mut [u8],
) -> Result<()> {
    let n = words.len();
    let q = n / LANES;
    // 安全条件は呼出し元が確立する: AVX2 検出済み、全 anchors/next < n、
    // n <= MAX_INPUT+1 <= 1048577、表は不変。帰納的に全 SIMD 添字は範囲内で
    // i32 の正値として表現できる。scale=4 は u32 の要素幅に一致する。
    unsafe {
        let ap = anchors.as_ptr();
        let base = words.as_ptr().cast::<i32>();
        let mut r0 = _mm256_loadu_si256(ap.cast::<__m256i>());
        let mut r1 = _mm256_loadu_si256(ap.add(8).cast::<__m256i>());
        let mut r2 = _mm256_loadu_si256(ap.add(16).cast::<__m256i>());
        let mut r3 = _mm256_loadu_si256(ap.add(24).cast::<__m256i>());
        let mask = _mm256_set1_epi32(INDEX_MASK as i32);
        let p = _mm256_set1_epi32(primary as i32);
        let mut gathered = [0u32; LANES];
        for round in 0..q {
            let hit0 = _mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpeq_epi32(r0, p)));
            let hit1 = _mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpeq_epi32(r1, p)));
            let hit2 = _mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpeq_epi32(r2, p)));
            let hit3 = _mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpeq_epi32(r3, p)));
            let hits =
                hit0 as u32 | ((hit1 as u32) << 8) | ((hit2 as u32) << 16) | ((hit3 as u32) << 24);
            if hits != if round == 0 { 1 } else { 0 } {
                return Err("gather AVX2 returned to primary early".into());
            }
            let w0 = _mm256_i32gather_epi32::<4>(base, r0);
            let w1 = _mm256_i32gather_epi32::<4>(base, r1);
            let w2 = _mm256_i32gather_epi32::<4>(base, r2);
            let w3 = _mm256_i32gather_epi32::<4>(base, r3);
            // 4 回の各ストアは stack 配列内の非重複 8 要素だけを書く。
            let gp = gathered.as_mut_ptr();
            _mm256_storeu_si256(gp.cast::<__m256i>(), w0);
            _mm256_storeu_si256(gp.add(8).cast::<__m256i>(), w1);
            _mm256_storeu_si256(gp.add(16).cast::<__m256i>(), w2);
            _mm256_storeu_si256(gp.add(24).cast::<__m256i>(), w3);
            r0 = _mm256_and_si256(w0, mask);
            r1 = _mm256_and_si256(w1, mask);
            r2 = _mm256_and_si256(w2, mask);
            r3 = _mm256_and_si256(w3, mask);
            for (lane, &word) in gathered.iter().enumerate() {
                let global = lane * q + round;
                if global > 0 {
                    plain[n - 1 - global] = (word >> 23) as u8;
                }
            }
        }
        let mut rows = [0u32; LANES];
        let rp = rows.as_mut_ptr();
        _mm256_storeu_si256(rp.cast::<__m256i>(), r0);
        _mm256_storeu_si256(rp.add(8).cast::<__m256i>(), r1);
        _mm256_storeu_si256(rp.add(16).cast::<__m256i>(), r2);
        _mm256_storeu_si256(rp.add(24).cast::<__m256i>(), r3);
        finish_lanes(words, primary, anchors, &rows, plain)
    }
}

#[inline(never)]
pub fn inverse(
    last: &[u16],
    counts: &[usize; 257],
    primary: usize,
    alphabet: &[u16],
    anchors: Option<&[u32; LANES]>,
    avx2: bool,
) -> Result<Output> {
    let n = last.len();
    valid_length(n, primary)?;
    if n < THRESHOLD {
        if anchors.is_some() {
            return Err("gather small block has anchors".into());
        }
    } else {
        validate_anchors(
            anchors.ok_or("gather large block missing anchors")?,
            n,
            primary,
        )?;
    }
    let words = build_table(last, primary, alphabet, counts)?;
    let scratch_capacity_words = words.capacity();
    let mut plain = allocate(n - 1, 0u8)?;
    let result_capacity = plain.capacity();
    let route;
    if n < THRESHOLD {
        small_walk(&words, primary, &mut plain)?;
        route = "gather-small";
    } else {
        let anchors = anchors.ok_or("gather large block missing anchors")?;
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        let use_avx2 = avx2 && std::is_x86_feature_detected!("avx2");
        #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
        let use_avx2 = {
            let _ = avx2;
            false
        };
        if use_avx2 {
            #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
            // 全表と anchors を検証済みで、検出された CPU に限定する。
            unsafe {
                avx2_lanes(&words, primary, anchors, &mut plain)?;
            }
            route = "gather32-avx2";
        } else {
            scalar_lanes(&words, primary, anchors, &mut plain)?;
            route = "gather32-scalar";
        }
    }
    Ok(Output {
        plain,
        route,
        scratch_capacity_words,
        result_capacity,
    })
}
