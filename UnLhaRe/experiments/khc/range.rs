const PROBABILITY_BITS: u32 = 15;
const PROBABILITY_TOTAL: u32 = 1 << PROBABILITY_BITS;
const NORMALIZE_THRESHOLD: u32 = 1 << 24;

/// KHC実験で使うbyte正規化binary range符号器。
///
/// `zero_probability`は`1..32768`の整数。0側の区間幅は
/// `(range >> 15) * zero_probability`で、`false`はその区間、`true`は残りを選ぶ。
/// 初期値は`low = 0`, `range = u32::MAX`。`range < 1 << 24`で正規化する。
///
/// 正規化はcarryを遅延する`ShiftLow`を使い、最後の5回で終端する。
/// 先頭は0のcarry byteで、decoderはそれを含む5 byteから32bit codeを初期化する。
pub(super) struct Encoder {
    low: u64,
    range: u32,
    cache: u8,
    cache_size: usize,
    output: Vec<u8>,
    max_bytes: usize,
    fast_overflow: bool,
    #[cfg(test)]
    saw_carry: bool,
    #[cfg(test)]
    max_cache_size: usize,
}

impl Encoder {
    /// 出力を`max_bytes`以下に制限し、符号化前に予約する。
    /// `shift_low`では追加の割当を行わない。
    pub(super) fn with_limit(max_bytes: usize) -> Result<Self, &'static str> {
        let mut output = Vec::new();
        output
            .try_reserve_exact(max_bytes)
            .map_err(|_| "range allocation failed")?;

        Ok(Self {
            low: 0,
            range: u32::MAX,
            cache: 0,
            cache_size: 1,
            output,
            max_bytes,
            fast_overflow: false,
            #[cfg(test)]
            saw_carry: false,
            #[cfg(test)]
            max_cache_size: 1,
        })
    }

    /// 1 bitを符号化する。falseが0、trueが1。範囲外の確率は処理前に拒否する。
    pub(super) fn bit(&mut self, zero_probability: u16, bit: bool) -> Result<(), &'static str> {
        if !(1..PROBABILITY_TOTAL as u16).contains(&zero_probability) {
            return Err("zero probability must be in 1..32768");
        }

        self.bit_unchecked(zero_probability, bit)
    }

    /// 確率の範囲検査を呼び出し側で済ませたencoder専用のhot path。
    #[inline(always)]
    pub(super) fn bit_unchecked(
        &mut self,
        zero_probability: u16,
        bit: bool,
    ) -> Result<(), &'static str> {
        debug_assert!((1..PROBABILITY_TOTAL as u16).contains(&zero_probability));

        let zero_range = (self.range >> PROBABILITY_BITS) * u32::from(zero_probability);
        if bit {
            self.low += u64::from(zero_range);
            self.range -= zero_range;
        } else {
            self.range = zero_range;
        }

        while self.range < NORMALIZE_THRESHOLD {
            self.range <<= 8;
            self.shift_low()?;
        }
        Ok(())
    }

    /// Beamの出力専用。確率検査と正規化ごとの`Result`伝播を外し、上限超過だけを
    /// encoder内へ遅延記録する。上限を超えた候補は`finish_fast`で従来と同じ
    /// `range output limit`へ変換されるため、成功時のbitstreamは`bit_unchecked`と同じ。
    #[inline(always)]
    pub(super) fn bit_unchecked_fast(&mut self, zero_probability: u16, bit: bool) {
        debug_assert!((1..PROBABILITY_TOTAL as u16).contains(&zero_probability));
        if self.fast_overflow {
            return;
        }

        let zero_range = (self.range >> PROBABILITY_BITS) * u32::from(zero_probability);
        if bit {
            self.low += u64::from(zero_range);
            self.range -= zero_range;
        } else {
            self.range = zero_range;
        }

        while self.range < NORMALIZE_THRESHOLD {
            self.range <<= 8;
            self.shift_low_fast();
            if self.fast_overflow {
                return;
            }
        }
    }

    pub(super) fn finish(mut self) -> Result<Vec<u8>, &'static str> {
        // 最終区間の下端を選び、decoderの5 byte初期化と対応させる。
        for _ in 0..5 {
            self.shift_low()?;
        }
        Ok(self.output)
    }

    pub(super) fn emitted_bytes(&self) -> usize {
        self.output.len()
    }

    pub(super) fn pending_bytes(&self) -> usize {
        self.cache_size
    }

    /// 現在の区間をここで終端した場合のbyte長を、scalar stateだけで予測する。
    /// encoder自身のoutputやcarry状態は変更しない。
    pub(super) fn finish_len_preview(&self) -> Option<usize> {
        let mut low = self.low;
        let mut cache_size = self.cache_size;
        let mut output_len = self.output.len();
        for _ in 0..5 {
            let low32 = low as u32;
            let carry = (low >> 32) as u8;
            if low32 < 0xff00_0000 || carry != 0 {
                output_len = output_len.checked_add(cache_size)?;
                cache_size = 0;
            }
            cache_size = cache_size.checked_add(1)?;
            low = u64::from((low32 & 0x00ff_ffff) << 8);
        }
        Some(output_len)
    }

    pub(super) fn finish_fast(mut self) -> Result<Vec<u8>, &'static str> {
        if self.fast_overflow {
            return Err("range output limit");
        }
        for _ in 0..5 {
            self.shift_low_fast();
            if self.fast_overflow {
                return Err("range output limit");
            }
        }
        Ok(self.output)
    }

    fn shift_low(&mut self) -> Result<(), &'static str> {
        let low = self.low as u32;
        let carry = (self.low >> 32) as u8;

        // 最上位が0xffなら後続carryで0へ戻り得るので保留する。
        // それ以外、またはcarry確定時に保留byteをまとめて確定する。
        if low < 0xff00_0000 || carry != 0 {
            let new_len = self
                .output
                .len()
                .checked_add(self.cache_size)
                .ok_or("range output limit")?;
            if new_len > self.max_bytes {
                return Err("range output limit");
            }

            #[cfg(test)]
            {
                self.saw_carry |= carry != 0;
            }

            let mut cached = self.cache;
            loop {
                self.output.push(cached.wrapping_add(carry));
                cached = 0xff;
                self.cache_size -= 1;
                if self.cache_size == 0 {
                    break;
                }
            }
            self.cache = (low >> 24) as u8;
        }

        self.cache_size += 1;
        #[cfg(test)]
        {
            self.max_cache_size = self.max_cache_size.max(self.cache_size);
        }
        self.low = u64::from((low & 0x00ff_ffff) << 8);
        Ok(())
    }

    #[inline(always)]
    fn shift_low_fast(&mut self) {
        let low = self.low as u32;
        let carry = (self.low >> 32) as u8;

        if low < 0xff00_0000 || carry != 0 {
            if self
                .output
                .len()
                .checked_add(self.cache_size)
                .is_none_or(|length| length > self.max_bytes)
            {
                self.fast_overflow = true;
                return;
            }

            let mut cached = self.cache;
            loop {
                self.output.push(cached.wrapping_add(carry));
                cached = 0xff;
                self.cache_size -= 1;
                if self.cache_size == 0 {
                    break;
                }
            }
            self.cache = (low >> 24) as u8;
        }

        self.cache_size += 1;
        self.low = u64::from((low & 0x00ff_ffff) << 8);
    }
}

pub(super) struct Decoder<'a, const PROFILE: bool = false> {
    input: &'a [u8],
    position: usize,
    range: u32,
    code: u32,
    bit_calls: u64,
    /// PROFILE時だけ数える。添字は1 bitの正規化で読んだbyte数で、2は2 byte以上。
    renorm_byte_events: [u64; 3],
}

impl<'a, const PROFILE: bool> Decoder<'a, PROFILE> {
    pub(super) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 5 {
            return Err("truncated range stream");
        }
        if input[0] != 0 {
            return Err("invalid range stream prefix");
        }

        let mut code = 0_u32;
        for &byte in &input[..5] {
            code = (code << 8) | u32::from(byte);
        }

        Ok(Self {
            input,
            position: 5,
            range: u32::MAX,
            code,
            bit_calls: 0,
            renorm_byte_events: [0; 3],
        })
    }

    pub(super) fn bit_calls(&self) -> u64 {
        self.bit_calls
    }

    pub(super) fn renorm_byte_events(&self) -> [u64; 3] {
        self.renorm_byte_events
    }

    #[inline(always)]
    fn record_renorm(&mut self, start: usize) {
        if !PROFILE {
            return;
        }
        let taken = self.position.saturating_sub(start).min(2);
        self.renorm_byte_events[taken] = self.renorm_byte_events[taken].saturating_add(1);
    }

    /// Encoderと同じ15bitの0確率で1 bitを復号する。
    pub(super) fn bit(&mut self, zero_probability: u16) -> Result<bool, &'static str> {
        if !(1..PROBABILITY_TOTAL as u16).contains(&zero_probability) {
            return Err("zero probability must be in 1..32768");
        }

        self.bit_unchecked(zero_probability)
    }

    /// 確率がKHCの内部モデルで有効範囲に保たれることを前提にするhot path。
    #[inline(always)]
    pub(super) fn bit_unchecked(&mut self, zero_probability: u16) -> Result<bool, &'static str> {
        debug_assert!((1..PROBABILITY_TOTAL as u16).contains(&zero_probability));
        if PROFILE {
            self.bit_calls = self.bit_calls.saturating_add(1);
        }

        let zero_range = (self.range >> PROBABILITY_BITS) * u32::from(zero_probability);
        let bit = if self.code < zero_range {
            self.range = zero_range;
            false
        } else {
            self.code -= zero_range;
            self.range -= zero_range;
            true
        };

        let renorm_start = if PROFILE { self.position } else { 0 };
        while self.range < NORMALIZE_THRESHOLD {
            let byte = self
                .input
                .get(self.position)
                .copied()
                .ok_or("truncated range stream")?;
            self.position += 1;
            self.range <<= 8;
            self.code = (self.code << 8) | u32::from(byte);
        }
        if PROFILE {
            self.record_renorm(renorm_start);
        }
        debug_assert!(self.range >= NORMALIZE_THRESHOLD);

        Ok(bit)
    }

    pub(super) fn input_remaining(&self) -> usize {
        debug_assert!(self.position <= self.input.len());
        self.input.len() - self.position
    }

    /// token開始時に128 bytes以上の入力余裕がある場合の境界検査なしbit復号。
    ///
    /// # Safety
    /// 呼び出し側は、確率を `1..32768` に保ち、この呼び出しを含むtoken全体で高々55 bitを
    /// 復号すること。rangeの各bitは最大2 byteを正規化で消費するため、token開始時に
    /// 128 byte以上あれば全readが入力内に収まる。
    #[inline(always)]
    pub(super) unsafe fn bit_unchecked_fast(&mut self, zero_probability: u16) -> bool {
        debug_assert!((1..PROBABILITY_TOTAL as u16).contains(&zero_probability));
        if PROFILE {
            self.bit_calls = self.bit_calls.saturating_add(1);
        }

        let zero_range = (self.range >> PROBABILITY_BITS) * u32::from(zero_probability);
        let bit = if self.code < zero_range {
            self.range = zero_range;
            false
        } else {
            self.code -= zero_range;
            self.range -= zero_range;
            true
        };

        let renorm_start = if PROFILE { self.position } else { 0 };
        while self.range < NORMALIZE_THRESHOLD {
            // SAFETY: 上の呼び出し側契約がtoken中の正規化byteをすべて入力内に保つ。
            let byte = unsafe { *self.input.get_unchecked(self.position) };
            self.position += 1;
            self.range <<= 8;
            self.code = (self.code << 8) | u32::from(byte);
        }
        if PROFILE {
            self.record_renorm(renorm_start);
        }
        debug_assert!(self.range >= NORMALIZE_THRESHOLD);

        bit
    }

    /// 指定bit列による厳密な消費長と正準終端を要求する。
    /// 正規化byteの欠落は先行するbit処理で検出する。
    pub(super) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() {
            return Err("trailing bytes in range stream");
        }
        // 実験形式は区間の下端で終端する。未使用bitによる別表現を受理しない。
        if self.code != 0 {
            return Err("non-canonical range termination");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Decoder, Encoder, NORMALIZE_THRESHOLD, PROBABILITY_TOTAL};

    const FIXED_CASE: &[(u16, bool)] = &[
        (16_384, false),
        (16_384, true),
        (1, false),
        (32_767, true),
        (7_321, false),
        (25_000, true),
        (12_345, true),
        (30_000, false),
        (2, true),
        (32_766, false),
        (9_999, true),
        (20_001, false),
    ];

    fn encode(symbols: &[(u16, bool)]) -> Vec<u8> {
        let mut encoder = Encoder::with_limit(1_000_000).unwrap();
        for &(probability, bit) in symbols {
            encoder.bit(probability, bit).unwrap();
        }
        encoder.finish().unwrap()
    }

    fn encode_fast(symbols: &[(u16, bool)], max_bytes: usize) -> Result<Vec<u8>, &'static str> {
        let mut encoder = Encoder::with_limit(max_bytes)?;
        for &(probability, bit) in symbols {
            encoder.bit_unchecked_fast(probability, bit);
        }
        encoder.finish_fast()
    }

    fn assert_round_trip(symbols: &[(u16, bool)], bytes: &[u8]) {
        let mut decoder = Decoder::<false>::new(bytes).unwrap();
        let mut fast_decoder = Decoder::<false>::new(bytes).unwrap();
        for &(probability, expected) in symbols {
            assert_eq!(decoder.bit(probability).unwrap(), expected);
            assert_eq!(fast_decoder.bit_unchecked(probability).unwrap(), expected);
        }
        decoder.finish().unwrap();
        fast_decoder.finish().unwrap();
    }

    /// 固定vector用に分離したscalar参照decoder。
    /// 本体のu32状態遷移とは別に、u64演算と明示的なmodulo 2^32更新を使う。
    fn scalar_decode(input: &[u8], probabilities: &[u16]) -> Result<Vec<bool>, &'static str> {
        if input.len() < 5 || input[0] != 0 {
            return Err("bad prefix");
        }

        let mut position = 5;
        let mut code = input[..5].iter().fold(0_u64, |value, &byte| {
            ((value << 8) | u64::from(byte)) & 0xffff_ffff
        });
        let mut range = u64::from(u32::MAX);
        let mut decoded = Vec::with_capacity(probabilities.len());

        for &probability in probabilities {
            if !(1..PROBABILITY_TOTAL as u16).contains(&probability) {
                return Err("bad probability");
            }
            let split = (range / u64::from(PROBABILITY_TOTAL)) * u64::from(probability);
            let bit = code >= split;
            if bit {
                code -= split;
                range -= split;
            } else {
                range = split;
            }
            while range < u64::from(NORMALIZE_THRESHOLD) {
                let byte = *input.get(position).ok_or("truncated")?;
                position += 1;
                range *= 256;
                code = ((code * 256) | u64::from(byte)) & 0xffff_ffff;
            }
            decoded.push(bit);
        }

        if position != input.len() {
            return Err("trailing");
        }
        Ok(decoded)
    }

    #[test]
    fn empty_stream_has_canonical_five_byte_termination() {
        let bytes = Encoder::with_limit(5).unwrap().finish().unwrap();
        assert_eq!(bytes, [0, 0, 0, 0, 0]);
        Decoder::<false>::new(&bytes).unwrap().finish().unwrap();
        assert_eq!(
            Decoder::<false>::new(&[0, 0, 0, 0, 1]).unwrap().finish(),
            Err("non-canonical range termination")
        );
    }

    #[test]
    fn fixed_vector_matches_independent_scalar_decoder() {
        // encoder変更で実験bitstreamが暗黙に変わらないよう期待byteを固定する。
        let golden = [0x00, 0x40, 0x00, 0x3f, 0xff, 0x33, 0x1a, 0xc7, 0x37];
        assert_eq!(encode(FIXED_CASE), golden);

        let probabilities: Vec<_> = FIXED_CASE.iter().map(|&(p, _)| p).collect();
        let expected: Vec<_> = FIXED_CASE.iter().map(|&(_, bit)| bit).collect();
        assert_eq!(scalar_decode(&golden, &probabilities).unwrap(), expected);
        assert_round_trip(FIXED_CASE, &golden);
    }

    #[test]
    fn fast_encoder_matches_checked_bitstream_and_limit() {
        assert_eq!(
            encode_fast(FIXED_CASE, 1_000_000).unwrap(),
            encode(FIXED_CASE)
        );

        let mut symbols = Vec::with_capacity(100_000);
        let mut state = 0x6a09_e667_u32;
        for index in 0..100_000_u32 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let probability = match index % 3 {
                0 => 1,
                1 => 32_767,
                _ => ((state >> 16) as u16 % 32_767).max(1),
            };
            symbols.push((probability, state & 0x8000_0000 != 0));
        }

        let checked = encode(&symbols);
        assert_eq!(encode_fast(&symbols, checked.len()).unwrap(), checked);
        assert_eq!(
            encode_fast(&symbols, checked.len() - 1),
            Err("range output limit")
        );
    }

    #[test]
    fn probability_extremes_and_long_carries_round_trip() {
        let mut encoder = Encoder::with_limit(1_000_000).unwrap();
        let mut symbols = Vec::with_capacity(100_000);
        let mut state = 0x6a09_e667_u32;
        for index in 0..100_000_u32 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let probability = match index % 3 {
                0 => 1,
                1 => 32_767,
                _ => ((state >> 16) as u16 % 32_767).max(1),
            };
            let bit = (state & 0x8000_0000) != 0;
            symbols.push((probability, bit));
            encoder.bit(probability, bit).unwrap();
        }

        assert!(encoder.saw_carry, "test stream did not exercise a carry");
        assert!(
            encoder.max_cache_size > 1,
            "test stream did not exercise delayed 0xff bytes"
        );
        let bytes = encoder.finish().unwrap();
        assert_round_trip(&symbols, &bytes);
    }

    #[test]
    fn malformed_streams_are_rejected_without_indexing_past_input() {
        assert!(Decoder::<false>::new(&[]).is_err());
        assert!(Decoder::<false>::new(&[0, 0, 0, 0]).is_err());
        assert!(Decoder::<false>::new(&[1, 0, 0, 0, 0]).is_err());

        let mut bytes = encode(FIXED_CASE);
        bytes.push(0x5a);
        let mut decoder = Decoder::<false>::new(&bytes).unwrap();
        for &(probability, _) in FIXED_CASE {
            decoder.bit(probability).unwrap();
        }
        assert_eq!(decoder.finish(), Err("trailing bytes in range stream"));

        let mut bytes = encode(FIXED_CASE);
        bytes.pop();
        let mut decoder = Decoder::<false>::new(&bytes).unwrap();
        let result = FIXED_CASE
            .iter()
            .try_for_each(|&(probability, _)| decoder.bit(probability).map(|_| ()));
        assert_eq!(result, Err("truncated range stream"));
    }

    #[test]
    fn invalid_probability_is_a_checked_decoder_error() {
        let bytes = Encoder::with_limit(5).unwrap().finish().unwrap();
        let mut encoder = Encoder::with_limit(5).unwrap();
        assert!(encoder.bit(0, false).is_err());
        assert!(encoder.bit(32_768, true).is_err());
        let mut decoder = Decoder::<false>::new(&bytes).unwrap();
        assert!(decoder.bit(0).is_err());
        assert!(decoder.bit(32_768).is_err());
    }

    #[test]
    fn encoder_enforces_output_limit_during_finalization() {
        assert_eq!(
            Encoder::with_limit(4).unwrap().finish(),
            Err("range output limit")
        );

        let mut encoder = Encoder::with_limit(8).unwrap();
        for &(probability, bit) in FIXED_CASE {
            encoder.bit(probability, bit).unwrap();
        }
        assert_eq!(encoder.finish(), Err("range output limit"));

        let mut encoder = Encoder::with_limit(9).unwrap();
        for &(probability, bit) in FIXED_CASE {
            encoder.bit(probability, bit).unwrap();
        }
        assert_eq!(encoder.finish().unwrap().len(), 9);
    }

    #[test]
    fn encoder_checks_limit_before_single_and_delayed_flushes() {
        let mut encoder = Encoder::with_limit(0).unwrap();
        assert_eq!(encoder.bit(1, false), Err("range output limit"));
        assert!(encoder.output.is_empty());

        let mut encoder = Encoder::with_limit(100_000).unwrap();
        let mut state = 0xbb67_ae85_u32;
        for _ in 0..100_000 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let probability = ((state >> 16) as u16 % 32_767).max(1);
            encoder.bit(probability, state & 1 != 0).unwrap();
            if encoder.cache_size > 1 {
                break;
            }
        }
        assert!(encoder.cache_size > 1, "no delayed bytes were produced");

        // 試験専用に上限を保留flushより小さくする。
        // 最初のbyteをpushする前に保留group全体を拒否することを確認する。
        encoder.max_bytes = encoder.output.len() + encoder.cache_size - 1;
        for _ in 0..100_000 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let probability = ((state >> 16) as u16 % 32_767).max(1);
            let old_len = encoder.output.len();
            if let Err(error) = encoder.bit(probability, state & 1 != 0) {
                assert_eq!(error, "range output limit");
                assert_eq!(encoder.output.len(), old_len);
                return;
            }
        }
        panic!("delayed bytes were never flushed");
    }
}
