//! 有限整数検証＋実rANS bytesへの安全なreject判定照合。新unit testではない。
#![allow(dead_code)]
mod bound;
#[path = "../mdl-rans/entropy.rs"]
mod entropy;
type Result<T> = std::result::Result<T, String>;
fn run() -> Result<String> {
    const L: u64 = 1 << 23;
    const U: u64 = L * 256;
    let mut inequalities = 0usize;
    let mut frames = 0usize;
    let mut checks = 0usize;
    let mut shifts = [0usize; 3];
    for f in 1u64..=32768 {
        let maximum = 65536 * f;
        for original in [
            L,
            L + 1,
            U - 1,
            maximum.saturating_sub(1),
            maximum,
            maximum + 1,
            maximum * 256 - 1,
            maximum * 256,
            maximum * 256 + 1,
        ] {
            if !(L..U).contains(&original) {
                continue;
            }
            for cumulative in [0, 32768 - f] {
                let mut x = original;
                let mut emitted = 0;
                while x >= maximum {
                    let before = x;
                    x /= 256;
                    emitted += 1;
                    if x * 256 * 256 < before * 255 {
                        return Err("shift-floor loss bound".into());
                    }
                    inequalities += 1;
                }
                if emitted > 2 || x < 256 * f {
                    return Err("renorm count/post-state".into());
                }
                shifts[emitted] += 1;
                let next = (x / f) * 32768 + x % f + cumulative;
                if !(L..U).contains(&next) || next * f * 256 < x * 32768 * 255 {
                    return Err("expansion loss/state bound".into());
                }
                inequalities += 1;
            }
        }
        let mut frequencies = [[0u16; 256]; 4];
        frequencies[0][0] = f as u16;
        if f != 32768 {
            frequencies[0][1] = (32768 - f) as u16;
        }
        let mut counts = [[0u32; 256]; 4];
        let mut encoder = entropy::Encoder::with_limit(1024).map_err(str::to_owned)?;
        for at in 0..64 {
            let symbol = usize::from(f != 32768 && (at % 7 < 3));
            counts[0][symbol] += 1;
            let cumulative = if symbol == 0 { 0 } else { f as u32 };
            let frequency = u32::from(frequencies[0][symbol]);
            encoder
                .interval(cumulative, frequency, 32768)
                .map_err(str::to_owned)?;
        }
        let payload = encoder.finish().map_err(str::to_owned)?;
        // 実payloadが収まる全limitで誤ってpruneしてはならない。prefixも課金。
        for limit in [
            5,
            payload.len().saturating_sub(1).max(5),
            payload.len(),
            payload.len() + 1,
            1024,
        ] {
            let decision = bound::impossible(&counts, &frequencies, 64, limit)?;
            if decision.prune && payload.len() <= limit {
                return Err("unsafe prune of real ANS frame".into());
            }
            checks += 1;
        }
        let mut decoder = entropy::Decoder::new(&payload).map_err(str::to_owned)?;
        for at in 0..64 {
            let expected = usize::from(f != 32768 && (at % 7 < 3));
            let slot = decoder.slot(32768).map_err(str::to_owned)?;
            let symbol = usize::from(slot >= f as u32);
            if symbol != expected {
                return Err("real frame symbol mismatch".into());
            }
            decoder
                .consume(
                    if symbol == 0 { 0 } else { f as u32 },
                    u32::from(frequencies[0][symbol]),
                    32768,
                )
                .map_err(str::to_owned)?;
        }
        decoder.finish().map_err(str::to_owned)?;
        frames += 1;
    }
    let mut frequencies = [[0u16; 256]; 4];
    frequencies[0][0] = 32768;
    let mut counts = [[0u32; 256]; 4];
    // 無eventのempty modelsとsingleton、signed negativeは有効。
    if bound::impossible(&counts, &[[0; 256]; 4], 0, 5)?.prune {
        return Err("empty lower bound".into());
    }
    counts[0][0] = bound::MAX_FIELDS as u32;
    if bound::impossible(&counts, &frequencies, bound::MAX_FIELDS, 5)?.prune {
        return Err("singleton lower bound".into());
    }
    let mut invalid = 0;
    for (fields, limit) in [
        (bound::MAX_FIELDS + 1, 5),
        (bound::MAX_FIELDS, 4),
        (bound::MAX_FIELDS, 1048577),
        (1, 5),
    ] {
        if bound::impossible(&counts, &frequencies, fields, limit).is_ok() {
            return Err("invalid fields/output accepted".into());
        }
        invalid += 1;
    }
    if bound::impossible(&counts, &[[0; 256]; 4], bound::MAX_FIELDS, 5).is_ok() {
        return Err("unused frequency accepted".into());
    }
    invalid += 1;
    frequencies[0][0] = 32767;
    if bound::impossible(&counts, &frequencies, bound::MAX_FIELDS, 5).is_ok() {
        return Err("invalid CDF total accepted".into());
    }
    invalid += 1;
    if shifts.iter().any(|&n| n == 0) || frames != 32768 || checks != 163840 || invalid != 6 {
        return Err("finite proof coverage".into());
    }
    Ok(format!(
        "{{\"status\":\"completed\",\"integer_inequalities\":{inequalities},\"real_frames\":{frames},\"real_limit_checks\":{checks},\"invalid_rejects\":{invalid},\"renorm_counts\":{:?},\"byte_exact_symbols\":true,\"speed_evidence\":false,\"full_codec_pruning_verified\":false}}",
        shifts
    ))
}
fn main() {
    match run() {
        Ok(r) => println!("{r}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
