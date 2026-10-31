//! 15bit確率の符号費用を1/256 bit単位で保持する、encoder専用の整数表。
//!
//! 実行時は従来の一次近似と同値の表を使い、token選択を変えずに再計算を省く。
//! 比較用の高精度表はQ31の二乗で生成するが、固定blockの凍結モデルでは出力が
//! 悪化したため試験用だけに残す。浮動小数点は独立検証だけに使う。

const TOTAL: usize = 1 << 15;
pub(crate) const MEMORY_BYTES: usize = TOTAL * std::mem::size_of::<u16>();

const fn fractional_log2(mut normalized: u64) -> u16 {
    let mut result = 0u16;
    let mut mask = 128;
    while mask != 0 {
        // 正規化値は [2^31, 2^32) なので、二乗はu64内に収まる。
        normalized = (normalized * normalized) >> 31;
        if normalized >= 1u64 << 32 {
            normalized >>= 1;
            result |= mask;
        }
        mask >>= 1;
    }
    result
}

const fn make_prices(precise: bool) -> [u16; TOTAL] {
    // 頻度0はモデルから到達しない。誤用時に無料tokenにならない番兵とする。
    let mut result = [u16::MAX; TOTAL];
    let mut frequency = 1usize;
    while frequency < TOTAL {
        let exponent = frequency.ilog2();
        result[frequency] = if precise {
            let normalized = (frequency as u64) << (31 - exponent);
            ((15 - exponent) * 256) as u16 - fractional_log2(normalized)
        } else {
            let normalized = (frequency as u32) << (15 - exponent);
            let fraction = ((normalized - 32768) * 256) >> 15;
            ((15 - exponent) * 256 - fraction) as u16
        };
        frequency += 1;
    }
    result
}

static PRICES: [u16; TOTAL] = make_prices(false);

pub(crate) fn bit_price(probability_zero: u16, bit: bool) -> u64 {
    debug_assert!((1..TOTAL).contains(&usize::from(probability_zero)));
    let frequency = if bit {
        TOTAL - usize::from(probability_zero)
    } else {
        usize::from(probability_zero)
    };
    u64::from(PRICES[frequency])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_preserves_the_original_integer_formula_for_every_frequency() {
        for frequency in 1..TOTAL as u32 {
            let exponent = frequency.ilog2();
            let normalized = frequency << (15 - exponent);
            let fraction = ((normalized - 32768) * 256) >> 15;
            let expected = (15 - exponent) * 256 - fraction;
            assert_eq!(bit_price(frequency as u16, false), u64::from(expected));
        }
    }

    #[test]
    fn costs_are_monotone_symmetric_and_exact_at_powers_of_two() {
        assert_eq!(MEMORY_BYTES, 65536);
        for exponent in 0..15 {
            assert_eq!(bit_price(1 << exponent, false), (15 - exponent) * 256);
        }
        for frequency in 1..TOTAL {
            assert_eq!(
                bit_price(frequency as u16, true),
                bit_price((TOTAL - frequency) as u16, false)
            );
            if frequency > 1 {
                assert!(PRICES[frequency] <= PRICES[frequency - 1]);
            }
        }
    }
}
