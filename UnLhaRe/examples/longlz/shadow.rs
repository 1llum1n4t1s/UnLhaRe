//! literal の model を強くしたときの符号長を見積もる「影の model」（計測用、出力 stream は変えない）。
//!
//! 実際の符号化は LZMA と同じ literal model のまま行い、同じ literal の各 bit について、
//! 複数の文脈の予測を logistic 混合した確率で -log2 を足す。parse は変えないので、
//! 「同じ記号列を、強い literal model で符号化したら何 bit になるか」の見積もりになる。
//!
//! 入力にする予測（各 bit、二分木の節 ctx ごと）：
//!   0. LZMA と同じ文脈（直前 byte の上位3bit）。一致byte文脈では一致 bit も含める。
//!   1. 直前 byte 全体（order-1）。
//!   2. 直前 2 byte の hash（order-2）。
//!   3. 一致 byte 全体（一致byte文脈を使える場合。使えなければ「なし」の値）。
//!
//! 混合の重みは「一致byte文脈か・bit 位置」の 16 組で学習する。

const NODES: usize = 0x300;
const O2_BITS: u32 = 22;

/// 適応速度を回数で下げる確率（f32、計測用）。
#[derive(Clone, Copy)]
pub struct Counter {
    pub p: f32,
    pub n: f32,
}

impl Counter {
    pub const INIT: Counter = Counter { p: 0.5, n: 0.0 };

    #[inline(always)]
    pub fn update(&mut self, bit: u32, limit: f32) {
        let target = if bit == 0 { 1.0 } else { 0.0 };
        let rate = 1.0 / (self.n + 1.5);
        self.p += (target - self.p) * rate.max(1.0 / limit);
        self.n += 1.0;
    }
}

#[inline(always)]
pub fn stretch(p: f32) -> f32 {
    let p = p.clamp(1.0 / 4096.0, 4095.0 / 4096.0);
    (p / (1.0 - p)).ln()
}

#[inline(always)]
pub fn squash(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

pub struct Shadow {
    m0: Vec<Counter>,
    m1: Vec<Counter>,
    m2: Vec<Counter>,
    m3: Vec<Counter>,
    weights: [[f32; 5]; 16],
    /// 使う予測の bit 集合（計測用、LLZ_SHADOW_MASK。bit0..3 が予測 0..3）。
    mask: u32,
    /// 見積もった literal の符号長（bit）。
    pub bits: f64,
}

impl Shadow {
    pub fn new() -> Self {
        Self {
            m0: vec![Counter::INIT; NODES * 8],
            m1: vec![Counter::INIT; NODES * 256],
            m2: vec![Counter::INIT; 1 << O2_BITS],
            m3: vec![Counter::INIT; 257 * 256],
            weights: [[0.3; 5]; 16],
            mask: std::env::var("LLZ_SHADOW_MASK")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(15),
            bits: 0.0,
        }
    }

    /// 1 literal を見積もる。prev1/prev2 は直前の byte（segment 先頭では 0）、
    /// mb は一致byte文脈に使う byte（使えなければ None）。
    pub fn literal(&mut self, prev1: u8, prev2: u8, mb: Option<u8>, byte: u8) {
        let mut node = 1usize;
        let mut matching = mb.is_some();
        let mbyte = mb.unwrap_or(0) as usize;
        let h2 = ((prev1 as u32) | ((prev2 as u32) << 8)).wrapping_mul(0x9E37_79B1);
        let mctx = mb.map_or(256, |b| b as usize);
        for i in (0..8).rev() {
            let bit = ((byte >> i) & 1) as u32;
            // LZMA と同じ節（一致中は一致 bit で 0x100/0x200 側を使う）。
            let lz_node = if matching {
                ((1 + ((mbyte >> i) & 1)) << 8) + node
            } else {
                node
            };
            let i0 = (prev1 as usize >> 5) * NODES + lz_node;
            let i1 = prev1 as usize * NODES + lz_node;
            let i2 = ((h2 >> (32 - O2_BITS)) as usize ^ (lz_node * 0x9E5)) & ((1 << O2_BITS) - 1);
            let i3 = mctx * 256 + node;
            let on = |k: u32| if self.mask >> k & 1 == 1 { 1.0 } else { 0.0 };
            let s = [
                stretch(self.m0[i0].p) * on(0),
                stretch(self.m1[i1].p) * on(1),
                stretch(self.m2[i2].p) * on(2),
                stretch(self.m3[i3].p) * on(3),
                0.25,
            ];
            let set = (matching as usize) * 8 + i;
            let w = &mut self.weights[set];
            let dot: f32 = w.iter().zip(s.iter()).map(|(a, b)| a * b).sum();
            let p = squash(dot).clamp(1.0 / 4096.0, 4095.0 / 4096.0);
            let q = if bit == 0 { p } else { 1.0 - p };
            self.bits -= (q as f64).log2();
            // 混合の重みを誤差で更新し、各予測も更新する。
            let err = (if bit == 0 { 1.0 } else { 0.0 }) - p;
            for (wi, si) in w.iter_mut().zip(s.iter()) {
                *wi += 0.02 * err * si;
            }
            self.m0[i0].update(bit, 32.0);
            self.m1[i1].update(bit, 64.0);
            self.m2[i2].update(bit, 64.0);
            self.m3[i3].update(bit, 64.0);
            if matching && ((mbyte >> i) & 1) as u32 != bit {
                matching = false;
            }
            node = (node << 1) | bit as usize;
        }
    }
}
