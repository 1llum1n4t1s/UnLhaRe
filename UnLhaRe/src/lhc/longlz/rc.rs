//! 長距離LZ（LLZ1BLK）の range 符号器・復号器と、確率から符号長を見積もる価格表。
//! 符号の規則は LZMA と同じ（11bit 確率、移動量5、上位8bit正規化）。
//! 価格は「bit数×16」の整数で、最適parseの比較だけに使う。

use super::mix::LitMix;

pub const TOP: u32 = 1 << 24;
pub const PROB_INIT: u16 = 1024;
const MOVE_BITS: u32 = 5;
const MODEL_TOTAL: u32 = 1 << 11;

/// 価格の単位：1bit = 16。
pub const BIT_PRICE: u32 = 16;

/// 確率 p（0..2048、上位7bitで引く）から -log2 を引く表。
pub struct Prices {
    table: [u32; 128],
}

impl Prices {
    pub fn new() -> Self {
        let mut table = [0u32; 128];
        for (i, slot) in table.iter_mut().enumerate() {
            let p = (i as f64 * 16.0 + 8.0) / MODEL_TOTAL as f64;
            *slot = (-p.log2() * BIT_PRICE as f64).round() as u32;
        }
        Self { table }
    }

    /// 確率 p の bit を符号化する価格。
    #[inline(always)]
    pub fn bit(&self, p: u16, bit: u32) -> u32 {
        let q = if bit == 0 {
            p as u32
        } else {
            MODEL_TOTAL - p as u32
        };
        self.table[(q >> 4) as usize]
    }

    /// 上位から bits 本の木符号の価格。
    #[inline(always)]
    pub fn tree(&self, probs: &[u16], bits: u32, symbol: u32) -> u32 {
        let mut price = 0;
        let mut m = 1usize;
        for i in (0..bits).rev() {
            let b = (symbol >> i) & 1;
            price += self.bit(probs[m], b);
            m = (m << 1) | b as usize;
        }
        price
    }

    /// 下位から bits 本の逆順木符号の価格。
    #[inline(always)]
    pub fn reverse(&self, probs: &[u16], bits: u32, symbol: u32) -> u32 {
        let mut price = 0;
        let mut m = 1usize;
        for i in 0..bits {
            let b = (symbol >> i) & 1;
            price += self.bit(probs[m], b);
            m = (m << 1) | b as usize;
        }
        price
    }
}

/// 確率 p（11bit、bit=0 の確率）を bit で更新する（LZMA と同じ移動量 5）。符号器・復号器・混合 literal が共有する。
#[inline(always)]
pub fn adapt(p: &mut u16, bit: u32) {
    if bit == 0 {
        *p += ((MODEL_TOTAL - *p as u32) >> MOVE_BITS) as u16;
    } else {
        *p -= *p >> MOVE_BITS;
    }
}

/// range 符号器。low は桁上がりを持てる 33bit 以上で扱い、cache で遅延出力する。
pub struct RangeEnc {
    low: u64,
    range: u32,
    cache: u8,
    cache_size: u64,
    pub out: Vec<u8>,
}

impl RangeEnc {
    pub fn new(capacity: usize) -> Self {
        Self {
            low: 0,
            range: u32::MAX,
            cache: 0,
            cache_size: 1,
            out: Vec::with_capacity(capacity),
        }
    }

    #[inline(always)]
    fn shift_low(&mut self) {
        if (self.low as u32) < 0xFF00_0000 || (self.low >> 32) != 0 {
            let carry = (self.low >> 32) as u8;
            let mut temp = self.cache;
            loop {
                self.out.push(temp.wrapping_add(carry));
                temp = 0xFF;
                self.cache_size -= 1;
                if self.cache_size == 0 {
                    break;
                }
            }
            self.cache = (self.low >> 24) as u8;
        }
        self.cache_size += 1;
        self.low = ((self.low as u32) << 8) as u64;
    }

    /// 確率 p（11bit、bit=0 の確率）で 1bit を送る。確率は更新しない（2 本の符号器へ同じ確率で書くときに使う）。
    #[inline(always)]
    pub fn bit_fixed(&mut self, p: u16, bit: u32) {
        let bound = (self.range >> 11) * (p as u32);
        if bit == 0 {
            self.range = bound;
        } else {
            self.low += bound as u64;
            self.range -= bound;
        }
        while self.range < TOP {
            self.range <<= 8;
            self.shift_low();
        }
    }

    #[inline(always)]
    pub fn bit(&mut self, p: &mut u16, bit: u32) {
        self.bit_fixed(*p, bit);
        adapt(p, bit);
    }

    /// 外で決めた 12bit 確率（bit=0 の確率、1..=4095）で 1bit を送る（literal の混合。確率の更新は呼び出し側）。
    #[inline(always)]
    pub fn bit12(&mut self, p0: u32, bit: u32) {
        let bound = (self.range >> 12) * p0;
        if bit == 0 {
            self.range = bound;
        } else {
            self.low += bound as u64;
            self.range -= bound;
        }
        while self.range < TOP {
            self.range <<= 8;
            self.shift_low();
        }
    }

    pub fn direct(&mut self, value: u32, count: u32) {
        for i in (0..count).rev() {
            self.range >>= 1;
            if (value >> i) & 1 != 0 {
                self.low += self.range as u64;
            }
            while self.range < TOP {
                self.range <<= 8;
                self.shift_low();
            }
        }
    }

    pub fn finish(mut self) -> Vec<u8> {
        for _ in 0..5 {
            self.shift_low();
        }
        self.out
    }
}

/// range 復号器。入力末尾を越えた読み出しは 0 を補い、長さの整合は呼び出し側で検査する。
pub struct RangeDec<'a> {
    input: &'a [u8],
    pos: usize,
    range: u32,
    code: u32,
}

impl<'a> RangeDec<'a> {
    pub fn new(input: &'a [u8]) -> Result<Self, String> {
        if input.len() < 5 || input[0] != 0 {
            return Err("range coder header".into());
        }
        let code = u32::from_be_bytes([input[1], input[2], input[3], input[4]]);
        Ok(Self {
            input,
            pos: 5,
            range: u32::MAX,
            code,
        })
    }

    #[inline(always)]
    fn normalize(&mut self) {
        if self.range < TOP {
            self.range <<= 8;
            let b = self.input.get(self.pos).copied().unwrap_or(0);
            self.pos += 1;
            self.code = (self.code << 8) | b as u32;
        }
    }

    #[inline(always)]
    pub fn bit(&mut self, p: &mut u16) -> u32 {
        let bound = (self.range >> 11) * (*p as u32);
        let bit = if self.code < bound {
            self.range = bound;
            *p += ((MODEL_TOTAL - *p as u32) >> MOVE_BITS) as u16;
            0
        } else {
            self.range -= bound;
            self.code -= bound;
            *p -= *p >> MOVE_BITS;
            1
        };
        self.normalize();
        bit
    }

    /// 12bit 確率（bit=0 の確率、1..=4095）で 1bit を読む（符号化側の `bit12` と対）。
    /// 確率が 1/4096 まで小さくなりうるので、range は最大 2 byte 分縮む。符号化側の while と同じ結果になるよう
    /// 正規化を 2 回行う（1 回目で足りれば 2 回目は何もしない）。
    #[inline(always)]
    pub fn bit12(&mut self, p0: u32) -> u32 {
        let bound = (self.range >> 12) * p0;
        let bit = if self.code < bound {
            self.range = bound;
            0
        } else {
            self.range -= bound;
            self.code -= bound;
            1
        };
        self.normalize();
        self.normalize();
        bit
    }

    #[inline(always)]
    pub fn direct(&mut self, count: u32) -> u32 {
        let mut res = 0u32;
        for _ in 0..count {
            self.range >>= 1;
            let t = if self.code >= self.range {
                self.code -= self.range;
                1
            } else {
                0
            };
            res = (res << 1) | t;
            self.normalize();
        }
        res
    }

    #[inline(always)]
    pub fn tree(&mut self, probs: &mut [u16], bits: u32) -> u32 {
        let mut m = 1usize;
        for _ in 0..bits {
            m = (m << 1) | self.bit(&mut probs[m]) as usize;
        }
        (m - (1 << bits)) as u32
    }

    #[inline(always)]
    pub fn reverse(&mut self, probs: &mut [u16], bits: u32) -> u32 {
        let mut m = 1usize;
        let mut sym = 0u32;
        for i in 0..bits {
            let b = self.bit(&mut probs[m]);
            m = (m << 1) | b as usize;
            sym |= b << i;
        }
        sym
    }

    /// 消費した入力 byte 数（末尾の検査用）。
    pub fn consumed(&self) -> usize {
        self.pos
    }
}

/// encoder が使う符号器の抽象。revision 12〜14 は単一の `RangeEnc`、revision 15 は 2 本の符号器を同時に書く
/// `DualEnc`（literal の混合なし・ありの 2 つの body を 1 回の parse で作る）。単相化されるので、
/// 単一の符号器の経路は従来と同じ code・同じ byte になる。
pub trait Coder {
    /// 2 本の符号器で書き、literal の混合を使うか。
    const DUAL: bool;
    /// capacity は出力の見込み（byte）。
    fn new(capacity: usize) -> Self;
    fn bit(&mut self, p: &mut u16, bit: u32);
    fn direct(&mut self, value: u32, count: u32);
    /// literal 1 byte を送る。`probs` は LZMA の literal 確率（直前 byte の文脈 1 つ分）、`mb` は一致byte文脈に
    /// 使う byte。`DualEnc` は混合なし側へ LZMA の確率で、混合あり側へ `lx` で書く（確率の更新は 1 回）。
    fn literal(
        &mut self,
        probs: &mut [u16; 0x300],
        lx: Option<&mut LitMix>,
        prev1: u8,
        mb: Option<u8>,
        byte: u8,
    );
    /// 混合なしの body と、あれば混合ありの body。
    fn finish(self) -> (Vec<u8>, Option<Vec<u8>>);

    #[inline(always)]
    fn tree(&mut self, probs: &mut [u16], bits: u32, symbol: u32) {
        let mut m = 1usize;
        for i in (0..bits).rev() {
            let b = (symbol >> i) & 1;
            self.bit(&mut probs[m], b);
            m = (m << 1) | b as usize;
        }
    }

    #[inline(always)]
    fn reverse(&mut self, probs: &mut [u16], bits: u32, symbol: u32) {
        let mut m = 1usize;
        for i in 0..bits {
            let b = (symbol >> i) & 1;
            self.bit(&mut probs[m], b);
            m = (m << 1) | b as usize;
        }
    }
}

impl Coder for RangeEnc {
    const DUAL: bool = false;

    fn new(capacity: usize) -> Self {
        RangeEnc::new(capacity)
    }

    #[inline(always)]
    fn bit(&mut self, p: &mut u16, bit: u32) {
        RangeEnc::bit(self, p, bit);
    }

    #[inline(always)]
    fn direct(&mut self, value: u32, count: u32) {
        RangeEnc::direct(self, value, count);
    }

    /// LZMA の literal 符号（一致byte文脈があれば、一致 bit が違うまで一致 byte の bit で分けた節を使う）。
    #[inline(always)]
    fn literal(
        &mut self,
        probs: &mut [u16; 0x300],
        _lx: Option<&mut LitMix>,
        _prev1: u8,
        mb: Option<u8>,
        byte: u8,
    ) {
        let byte = u32::from(byte);
        let mut matching = mb.is_some();
        let match_byte = u32::from(mb.unwrap_or(0));
        let mut ctx = 1usize;
        for i in (0..8).rev() {
            let bit = (byte >> i) & 1;
            if matching {
                let mbit = ((match_byte >> i) & 1) as usize;
                self.bit(&mut probs[((1 + mbit) << 8) + ctx], bit);
                matching = mbit as u32 == bit;
            } else {
                self.bit(&mut probs[ctx], bit);
            }
            ctx = (ctx << 1) | bit as usize;
        }
    }

    fn finish(self) -> (Vec<u8>, Option<Vec<u8>>) {
        (RangeEnc::finish(self), None)
    }
}

/// 混合なし（`plain`）と混合あり（`mix`）の 2 本の符号器へ同じ記号列を書く（revision 15 の encoder）。
/// literal 以外の記号は同じ 11bit 確率で両方へ書き、確率の更新は 1 回だけ行う。literal は混合なし側へ
/// LZMA の確率で 8bit を書いてから、混合あり側へ `LitMix::encode`（LZMA の確率の更新を含む）で書く。
/// どちらの側の model・価格・記号列も同一なので、parse は 1 回で済む。
pub struct DualEnc {
    plain: RangeEnc,
    mix: RangeEnc,
}

impl Coder for DualEnc {
    const DUAL: bool = true;

    fn new(capacity: usize) -> Self {
        Self {
            plain: RangeEnc::new(capacity),
            mix: RangeEnc::new(capacity),
        }
    }

    #[inline(always)]
    fn bit(&mut self, p: &mut u16, bit: u32) {
        self.plain.bit_fixed(*p, bit);
        self.mix.bit_fixed(*p, bit);
        adapt(p, bit);
    }

    #[inline(always)]
    fn direct(&mut self, value: u32, count: u32) {
        self.plain.direct(value, count);
        self.mix.direct(value, count);
    }

    fn literal(
        &mut self,
        probs: &mut [u16; 0x300],
        lx: Option<&mut LitMix>,
        prev1: u8,
        mb: Option<u8>,
        byte: u8,
    ) {
        // 混合なし側：LZMA の確率で 8bit を書く。節は bit ごとに違うので、更新前の確率をまとめて読んでよい
        // （更新は混合あり側の `LitMix::encode` が、同じ式で 1 回だけ行う）。
        let mut matching = mb.is_some();
        let match_byte = usize::from(mb.unwrap_or(0));
        let mut ctx = 1usize;
        for i in (0..8).rev() {
            let bit = u32::from((byte >> i) & 1);
            let mbit = (match_byte >> i) & 1;
            let node = if matching {
                ((1 + mbit) << 8) + ctx
            } else {
                ctx
            };
            self.plain.bit_fixed(probs[node], bit);
            matching = matching && mbit as u32 == bit;
            ctx = (ctx << 1) | bit as usize;
        }
        // 混合あり側。`DualEnc` を使う encoder は必ず `LitMix` を持つ（`Model::new` が確保する）。
        debug_assert!(lx.is_some(), "DualEnc needs the literal mixer");
        if let Some(lx) = lx {
            lx.encode(probs, &mut self.mix, prev1, mb, byte);
        }
    }

    fn finish(self) -> (Vec<u8>, Option<Vec<u8>>) {
        (self.plain.finish(), Some(self.mix.finish()))
    }
}
