//! 長距離LZ試作の range 符号器・復号器と、確率から符号長を見積もる価格表。
//! 符号の規則は LZMA と同じ（11bit 確率、移動量5、上位8bit正規化）。
//! 価格は「bit数×16」の整数で、最適parseの比較だけに使う。

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

/// 符号長の内訳の分類（計測用）。
pub const CATS: [&str; 10] = [
    "match flag",
    "literal",
    "literal(matched)",
    "rep select",
    "rep length",
    "match length",
    "dist slot",
    "dist low(tree)",
    "dist direct",
    "dist align",
];

/// range 符号器。low は桁上がりを持てる 33bit 以上で扱い、cache で遅延出力する。
pub struct RangeEnc {
    low: u64,
    range: u32,
    cache: u8,
    cache_size: u64,
    pub out: Vec<u8>,
    /// 計測を有効にすると、bit ごとの -log2(確率) を cat の分類へ足す。
    pub stats: Option<Box<[f64; 10]>>,
    pub cat: usize,
}

impl RangeEnc {
    pub fn new(capacity: usize) -> Self {
        Self {
            low: 0,
            range: u32::MAX,
            cache: 0,
            cache_size: 1,
            out: Vec::with_capacity(capacity),
            stats: std::env::var("LLZ_STATS")
                .is_ok_and(|v| v == "1")
                .then(|| Box::new([0.0; 10])),
            cat: 0,
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

    #[inline(always)]
    pub fn bit(&mut self, p: &mut u16, bit: u32) {
        if let Some(st) = self.stats.as_mut() {
            let q = if bit == 0 {
                *p as f64
            } else {
                (MODEL_TOTAL - *p as u32) as f64
            };
            st[self.cat] -= (q / MODEL_TOTAL as f64).log2();
        }
        let bound = (self.range >> 11) * (*p as u32);
        if bit == 0 {
            self.range = bound;
            *p += ((MODEL_TOTAL - *p as u32) >> MOVE_BITS) as u16;
        } else {
            self.low += bound as u64;
            self.range -= bound;
            *p -= *p >> MOVE_BITS;
        }
        while self.range < TOP {
            self.range <<= 8;
            self.shift_low();
        }
    }

    pub fn direct(&mut self, value: u32, count: u32) {
        if let Some(st) = self.stats.as_mut() {
            st[self.cat] += count as f64;
        }
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

    pub fn tree(&mut self, probs: &mut [u16], bits: u32, symbol: u32) {
        let mut m = 1usize;
        for i in (0..bits).rev() {
            let b = (symbol >> i) & 1;
            self.bit(&mut probs[m], b);
            m = (m << 1) | b as usize;
        }
    }

    pub fn reverse(&mut self, probs: &mut [u16], bits: u32, symbol: u32) {
        let mut m = 1usize;
        for i in 0..bits {
            let b = (symbol >> i) & 1;
            self.bit(&mut probs[m], b);
            m = (m << 1) | b as usize;
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
