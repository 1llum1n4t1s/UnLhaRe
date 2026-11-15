//! 長さの混合 model の整数試作（LLZ 長さ混合の go/no-go 判定用。製品には未接続）。
//!
//! - 確率は「bit が 0 である確率」を 16bit で持つ counter（回数つきの適応速度、上限あり）。
//! - 混合は lpaq 型：12bit 確率の stretch（表引き、±2047）を重みつきで足し、squash（区分線形の表）で戻す。
//!   すべて整数演算なので、符号化側と復号側で同じ値になる。
//! - range 符号には 12bit 確率（[1, 4095]）で渡す（`RangeEnc::bit12` / `RangeDec::bit12`）。
//!
//! 長さの木は LZMA と同じ分解（choice、choice2、low 3bit、mid 3bit、high 8bit）を 274 節で表し、
//! 分割案（V5）の先頭 2bit（長さ区分 ls）の木を 274..277 節に置く。

#![allow(clippy::needless_range_loop, clippy::too_many_arguments)] // 計測用の試作。

use super::rc::{BIT_PRICE, RangeDec, RangeEnc};

/// lpaq1 の squash の補間点（d/256 の logistic を 12bit で表したもの）。
const SQ: [i32; 33] = [
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348,
    3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094,
];

/// d（8bit 小数の対数オッズ、±2047）から 12bit 確率へ。
#[inline(always)]
pub fn squash(d: i32) -> i32 {
    if d > 2047 {
        return 4095;
    }
    if d < -2047 {
        return 1;
    }
    let w = d & 127;
    let i = ((d >> 7) + 16) as usize;
    (SQ[i] * (128 - w) + SQ[i + 1] * w + 64) >> 7
}

/// stretch の表（squash の逆、12bit 確率→対数オッズ）。
pub struct Tables {
    /// 固定長の配列にして、添字を 4095 で masked すれば境界検査を省けるようにする。
    stretch: Box<[i16; 4096]>,
    /// squash(d) の表（d = -2047..=2047 を 0..=4094 に置き、[1, 4095] に収めた値。末尾 1 つは詰め物）。
    squash: Box<[i16; 4096]>,
    /// 1/(n+1.5) を 16bit で表した適応速度（回数 n ごと）。
    rate: [u32; 256],
    /// 16bit 確率の上位8bitから価格（-log2 × BIT_PRICE）を引く表。
    price: [u32; 256],
}

impl Tables {
    pub fn new() -> Self {
        let mut stretch = Box::new([0i16; 4096]);
        let mut pi = 0usize;
        for x in -2047..=2047 {
            let v = squash(x) as usize;
            for s in stretch.iter_mut().take(v + 1).skip(pi) {
                *s = x as i16;
            }
            pi = pi.max(v + 1);
        }
        for s in stretch.iter_mut().skip(pi) {
            *s = 2047;
        }
        let mut rate = [0u32; 256];
        for (n, r) in rate.iter_mut().enumerate() {
            *r = (65536.0 / (n as f64 + 1.5)) as u32;
        }
        let mut price = [0u32; 256];
        for (i, p) in price.iter_mut().enumerate() {
            let q = (i as f64 + 0.5) / 256.0;
            *p = (-q.log2() * BIT_PRICE as f64).round() as u32;
        }
        let mut squash_t = Box::new([4095i16; 4096]);
        for (s, d) in squash_t.iter_mut().zip(-2047..=2047) {
            *s = squash(d).clamp(1, 4095) as i16;
        }
        Self {
            stretch,
            squash: squash_t,
            rate,
            price,
        }
    }

    #[inline(always)]
    pub fn st(&self, p12: i32) -> i32 {
        self.stretch[p12 as usize] as i32
    }

    /// squash の表引き版（d は任意の値、±2047 で飽和。結果は 1..=4095）。
    #[inline(always)]
    pub fn sq(&self, d: i32) -> i32 {
        self.squash[(d.clamp(-2047, 2047) + 2047) as usize] as i32
    }

    /// 16bit 確率 p0（0 の確率）の counter で bit を送る価格。
    #[inline(always)]
    pub fn bit_price(&self, p0: u16, bit: u32) -> u32 {
        let q = if bit == 0 { p0 } else { 65535 - p0 };
        self.price[(q >> 8) as usize]
    }
}

/// 回数つき適応の counter。p は bit=0 の確率（16bit）、n は更新回数（上限で止める）。
#[derive(Clone, Copy)]
pub struct Cnt {
    pub p: u16,
    pub n: u16,
}

impl Cnt {
    pub const INIT: Cnt = Cnt { p: 32768, n: 0 };

    #[inline(always)]
    pub fn p12(self) -> i32 {
        ((self.p >> 4) as i32).clamp(1, 4095)
    }

    #[inline(always)]
    fn update(&mut self, t: &Tables, bit: u32, limit: u16) {
        // (target-p)×rate は i32 を超えうる（65535×43690）ので i64 で計算する。
        let r = t.rate[self.n as usize] as i64;
        let p = self.p as i64;
        let target = if bit == 0 { 65535 } else { 0 };
        let np = p + (((target - p) * r) >> 16);
        self.p = np.clamp(32, 65503) as u16;
        if self.n < limit {
            self.n += 1;
        }
    }
}

/// literal の混合（L1/L3 の試作）。
///
/// - mode 1：LZMA の literal 確率（直前 byte の上位3bit、一致中は一致 bit も含む節）と、直前 1 byte 全体の
///   文脈（一致 bit は含めない）の2入力を混合する。
/// - mode 2：同じく、2入力目を直前 2 byte の hash にする。
/// - mode 4：混合せず、直前 2 byte の hash の単一文脈だけで送る（一致中も一致 bit を使わない）。
/// - mode 5：mode 1 と同じ入力で、重みを固定（0.7 と 0.5、学習しない）。
/// - mode 6：mode 1 と同じ入力の確率の単純平均。
///
/// 2入力目は 16bit 確率の固定速度（移動量 shift）の counter。1 byte の木 256 節を1区画に置き、
/// 区画を文脈で選ぶので、1 literal の参照は 512 byte の範囲に収まる。
#[derive(Clone)]
pub struct LitMix {
    pub mode: u8,
    /// 混合する上位 bit 数（1..=8）。下位は LZMA の確率だけで送る。
    pub top: u8,
    /// 一致byte文脈の literal は混合しない。
    pub nomatch: bool,
    bits: u32,
    shift: u32,
    lr: i32,
    t1: Vec<u16>,
    /// 重みの組（一致中か×bit の位置の 16 組）。固定長にして境界検査を省く。
    w: [[i32; 3]; 16],
}

impl LitMix {
    pub fn new(mode: u8, bits: u8, shift: u8, lr: u8, top: u8, nomatch: bool) -> Self {
        let bits = if mode == 1 || mode >= 5 {
            8
        } else {
            bits as u32
        };
        Self {
            mode,
            top: top.clamp(1, 8),
            nomatch,
            bits,
            shift: shift as u32,
            lr: lr as i32,
            t1: vec![32768; 256 << bits],
            // 最初は LZMA の確率を主に信じる（重み 0.8 と 0.3）。
            // mode 5（固定の重み）は 0.7 と 0.5。
            w: [if mode == 5 {
                [45875, 32768, 0]
            } else {
                [52429, 19661, 0]
            }; 16],
        }
    }

    /// 復号の専用経路を使えるか（mode 1、全 bit 混合、一致byte文脈も混合、移動量5・学習率12）。
    pub fn fast_o1(&self) -> bool {
        self.mode == 1 && self.top == 8 && !self.nomatch && self.shift == 5 && self.lr == 12
    }

    /// L2（mode 1）の literal 1 byte を復号する専用経路。`lzma::lit_code` と同じ演算・同じ順序で、
    /// mode の分岐・closure・境界検査をなくし、一致byte文脈の区間と通常の区間を別の loop にした。
    /// probs は LZMA の literal 確率の 1 文脈分（0x300 節）、prev1 は直前 byte、mb は一致 byte。
    #[inline(always)]
    pub fn decode_o1(
        &mut self,
        t: &Tables,
        probs: &mut [u16; 0x300],
        rc: &mut RangeDec,
        prev1: u8,
        mb: Option<u8>,
    ) -> u8 {
        let b = (prev1 as usize) << 8;
        let t1: &mut [u16; 256] = (&mut self.t1[b..b + 256]).try_into().unwrap();
        let st = &*t.stretch;
        let sq = &*t.squash;
        let w = &mut self.w;
        // 1 bit：node は LZMA 側の節、sym は木の節（1..=255）、ws は重みの組。
        // 子2つの予測を先に作って依存の連鎖を短くする版も試したが、1 thread で english 1.10→1.16、
        // linux 1.32→1.46 と遅くなったので採らない。
        let mut step = |node: usize, sym: usize, ws: usize, rc: &mut RangeDec| -> u32 {
            let node = node.min(0x2FF);
            let plz = probs[node];
            let c1 = t1[sym & 255];
            let s0 = st[((plz as usize) << 1) & 4095] as i32;
            let s1 = st[((c1 >> 4).max(1) as usize) & 4095] as i32;
            let wv = &mut w[ws & 15];
            let dot = wv[0] * s0 + wv[1] * s1 + wv[2] * 256;
            let p = sq[((dot >> 16).clamp(-2047, 2047) + 2047) as usize & 4095] as i32;
            let bit = rc.bit12(p as u32);
            let (q, c, err) = if bit == 0 {
                (
                    plz + ((2048 - plz) >> 5),
                    c1 + ((65535 - c1) >> 5),
                    4095 - p,
                )
            } else {
                (plz - (plz >> 5), c1 - (c1 >> 5), -p)
            };
            probs[node] = q;
            t1[sym & 255] = c;
            let lim = 1 << 18;
            wv[0] = (wv[0] + ((s0 * err + 2048) >> 12)).clamp(-lim, lim);
            wv[1] = (wv[1] + ((s1 * err + 2048) >> 12)).clamp(-lim, lim);
            wv[2] = (wv[2] + ((256 * err + 2048) >> 12)).clamp(-lim, lim);
            bit
        };
        let mut sym = 1usize;
        let mut i = 8usize;
        if let Some(m) = mb {
            let mut mbyte = m as usize;
            while i > 0 {
                i -= 1;
                let mbit = (mbyte >> 7) & 1;
                mbyte <<= 1;
                let bit = step(((1 + mbit) << 8) + sym, sym, 8 + i, rc) as usize;
                sym = (sym << 1) | bit;
                if mbit != bit {
                    break;
                }
            }
        }
        while i > 0 {
            i -= 1;
            sym = (sym << 1) | step(sym, sym, i, rc) as usize;
        }
        sym as u8
    }

    /// 2入力目の区画の先頭（直前 byte、または直前 2 byte の hash）。
    #[inline(always)]
    pub fn base(&self, prev1: u8, prev2: u8) -> usize {
        let b = if self.mode == 1 || self.mode >= 5 {
            prev1 as usize
        } else {
            let h = ((prev1 as u32) | ((prev2 as u32) << 8)).wrapping_mul(0x9E37_79B1);
            (h >> (32 - self.bits)) as usize
        };
        b << 8
    }

    /// 1 bit の 12bit 確率（bit=0 の確率）。plz は LZMA の 11bit 確率、i1 は 2入力目の添字、ws は重みの組。
    #[inline(always)]
    pub fn predict(&self, t: &Tables, plz: u16, i1: usize, ws: usize) -> (i32, [i32; 3]) {
        let q1 = ((self.t1[i1] >> 4) as i32).clamp(1, 4095);
        if self.mode == 4 {
            return (q1, [0; 3]);
        }
        if self.mode == 6 {
            // 確率の単純平均（stretch・squash・重みなし）。
            return (((plz as i32) + (q1 >> 1)).clamp(1, 4095), [0; 3]);
        }
        // LZMA の確率は 31..=2017 程度（移動量5の 11bit）なので、2倍しても 12bit の範囲に収まる。
        let s = [t.st((plz as i32) << 1), t.st(q1), 256];
        let w = &self.w[ws];
        // 重みは ±2^18 に抑えるので、積の和は i32 に収まる（2047×2^18×3 < 2^31）。
        let dot = w[0] * s[0] + w[1] * s[1] + w[2] * s[2];
        (t.sq(dot >> 16), s)
    }

    #[inline(always)]
    pub fn update(&mut self, i1: usize, ws: usize, s: [i32; 3], p: i32, bit: u32) {
        let c = &mut self.t1[i1];
        if bit == 0 {
            *c += (65535 - *c) >> self.shift;
        } else {
            *c -= *c >> self.shift;
        }
        if self.mode == 4 || self.mode >= 5 {
            // mode 5 は重みを固定（学習しない）、mode 6 は平均。
            return;
        }
        let err = if bit == 0 { 4095 - p } else { -p };
        let sh = self.lr;
        let w = &mut self.w[ws];
        for j in 0..3 {
            w[j] = (w[j] + ((s[j] * err + (1 << (sh - 1))) >> sh)).clamp(-(1 << 18), 1 << 18);
        }
    }
}

/// 長さ木の節数（LZMA の長さ符号 274 節＋分割案の先頭 2bit 木 4 節）。
pub const NODES: usize = 278;
/// 分割案の先頭 2bit 木の節の開始位置。
pub const HEAD: usize = 274;
/// 長さ文脈の距離区分の数（0..11 通常 slot/6、11..15 近傍、15..19 rep 番号、19 は予備）。
pub const NDC: usize = 20;
/// 重みの組：節の群 17 × 種類 3（通常・近傍・rep）。
const GROUPS: usize = 17;
const WSETS: usize = GROUPS * 3;
/// 直前の長さ区分の数。
pub const NPL: usize = 32;

/// 長さの混合 coder の設定（容器に記録し、復号側も同じ値を使う）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LenCfg {
    /// 入力の数（1：ps×dc の単一文脈、2：＋直前の長さ、3：＋state）。
    pub k: u8,
    /// 主入力の counter の回数上限（適応速度の下限 1/(lim+1.5)）。
    pub lim0: u8,
    /// 他の入力の counter の回数上限。
    pub lim1: u8,
    /// 重みの学習率の shift（大きいほど遅い）。
    pub lr: u8,
    /// 主入力の節の共有（bit の組）。bit0：high 木（8bit）で ps を使わない。bit1（診断）：主入力の counter を
    /// 最初から一定速度 1/(lim0+1.5) にする。bit2：choice・choice2 で ps を使わない。
    /// 測定では 5（bit0＋bit2、LZMA と同じ共有）が必要だった（ps で割ると長さの符号が約1%悪化）。
    pub high_coarse: u8,
    /// 診断用：1 なら通常・近傍の距離区分を主入力に使わない（ps だけの文脈になる）。
    pub reserved: u8,
}

#[derive(Clone)]
pub struct LenMix {
    pub cfg: LenCfg,
    t0: Vec<Cnt>,
    t1: Vec<Cnt>,
    t2: Vec<Cnt>,
    w: Vec<[i32; 4]>,
}

/// 1回の長さ符号化の文脈：ps（pos&3）、dc（距離区分）、kind（0 通常・1 近傍・2 rep）、pl（直前の長さ区分）、st（state）。
#[derive(Clone, Copy)]
pub struct LenCtx {
    pub ps: usize,
    pub dc: usize,
    pub kind: usize,
    pub pl: usize,
    pub st: usize,
}

#[inline(always)]
fn group(node: usize) -> usize {
    // 0 choice、1 choice2、2..10 low（深さ 0..2 → 2..4）、10..18 mid（5..7）、18.. high（8..15）、HEAD..（16）。
    if node >= HEAD {
        16
    } else if node < 2 {
        node
    } else if node < 10 {
        2 + depth(node - 2)
    } else if node < 18 {
        5 + depth(node - 10)
    } else {
        8 + depth(node - 18)
    }
}

/// 木の節番号（1 始まり）の深さ。
#[inline(always)]
fn depth(m: usize) -> usize {
    (usize::BITS - 1 - m.leading_zeros()) as usize
}

impl LenMix {
    pub fn new(cfg: LenCfg) -> Self {
        let k = cfg.k.max(1) as usize;
        // 診断用（high_coarse の bit1）：主入力の counter を最初から一定の速度 1/(lim0+1.5) にする
        // （LZMA の移動量 5 の counter に近い）。
        let init0 = if cfg.high_coarse & 2 != 0 {
            Cnt {
                p: 32768,
                n: cfg.lim0 as u16,
            }
        } else {
            Cnt::INIT
        };
        Self {
            cfg,
            t0: vec![init0; 4 * NDC * NODES],
            t1: if k >= 2 {
                vec![Cnt::INIT; NPL * 3 * NODES]
            } else {
                Vec::new()
            },
            t2: if k >= 3 {
                vec![Cnt::INIT; 12 * 3 * NODES]
            } else {
                Vec::new()
            },
            w: vec![[26214, 26214, 26214, 0]; WSETS],
        }
    }

    #[inline(always)]
    fn idx0(&self, c: &LenCtx, node: usize) -> usize {
        // high_coarse の bit0：high 木（8bit）、bit2：choice・choice2 の節で ps を使わない（LZMA と同じ共有）。
        let hc = self.cfg.high_coarse;
        let ps = if (hc & 1 != 0 && (18..HEAD).contains(&node)) || (hc & 4 != 0 && node < 2) {
            0
        } else {
            c.ps
        };
        // 診断用（reserved=1）：通常・近傍の距離区分を使わない（LZMA と同じ ps だけの文脈になる）。
        let dc = if self.cfg.reserved == 1 && c.dc < 15 {
            0
        } else {
            c.dc
        };
        (ps * NDC + dc) * NODES + node
    }

    /// 節 node の 12bit 確率（bit=0 の確率）と、更新に使う入力の値。
    #[inline(always)]
    fn predict(&self, t: &Tables, c: &LenCtx, node: usize) -> (i32, [usize; 3], [i32; 4], usize) {
        let k = self.cfg.k.max(1) as usize;
        let i0 = self.idx0(c, node);
        if k == 1 {
            return (self.t0[i0].p12(), [i0, 0, 0], [0; 4], 0);
        }
        let i1 = (c.pl * 3 + c.kind) * NODES + node;
        let i2 = if k >= 3 {
            (c.st * 3 + c.kind) * NODES + node
        } else {
            0
        };
        let mut s = [0i32; 4];
        s[0] = t.st(self.t0[i0].p12());
        s[1] = t.st(self.t1[i1].p12());
        if k >= 3 {
            s[2] = t.st(self.t2[i2].p12());
        }
        s[3] = 256;
        let ws = c.kind * GROUPS + group(node);
        let w = &self.w[ws];
        let dot: i64 = (0..4).map(|j| w[j] as i64 * s[j] as i64).sum();
        let p = squash((dot >> 16).clamp(-2047, 2047) as i32).clamp(1, 4095);
        (p, [i0, i1, i2], s, ws)
    }

    #[inline(always)]
    fn update(&mut self, t: &Tables, ix: [usize; 3], s: [i32; 4], ws: usize, p: i32, bit: u32) {
        let k = self.cfg.k.max(1) as usize;
        self.t0[ix[0]].update(t, bit, self.cfg.lim0 as u16);
        if k == 1 {
            return;
        }
        self.t1[ix[1]].update(t, bit, self.cfg.lim1 as u16);
        if k >= 3 {
            self.t2[ix[2]].update(t, bit, self.cfg.lim1 as u16);
        }
        let err = if bit == 0 { 4095 - p } else { -p };
        let sh = self.cfg.lr as i32;
        let w = &mut self.w[ws];
        for j in 0..4 {
            w[j] += (s[j] * err + (1 << (sh - 1))) >> sh;
        }
    }

    #[inline(always)]
    fn enc_bit(&mut self, t: &Tables, rc: &mut RangeEnc, c: &LenCtx, node: usize, bit: u32) {
        let (p, ix, s, ws) = self.predict(t, c, node);
        rc.bit12(p as u32, bit);
        self.update(t, ix, s, ws, p, bit);
    }

    #[inline(always)]
    fn dec_bit(&mut self, t: &Tables, rc: &mut RangeDec, c: &LenCtx, node: usize) -> u32 {
        let (p, ix, s, ws) = self.predict(t, c, node);
        let bit = rc.bit12(p as u32);
        self.update(t, ix, s, ws, p, bit);
        bit
    }

    /// v（0..=271）を LZMA と同じ分解で送る。
    pub fn encode(&mut self, t: &Tables, rc: &mut RangeEnc, c: &LenCtx, v: u32) {
        let (base, nb, sym) = if v < 8 {
            self.enc_bit(t, rc, c, 0, 0);
            (2, 3, v)
        } else if v < 16 {
            self.enc_bit(t, rc, c, 0, 1);
            self.enc_bit(t, rc, c, 1, 0);
            (10, 3, v - 8)
        } else {
            self.enc_bit(t, rc, c, 0, 1);
            self.enc_bit(t, rc, c, 1, 1);
            (18, 8, v - 16)
        };
        let mut m = 1usize;
        for i in (0..nb).rev() {
            let b = (sym >> i) & 1;
            self.enc_bit(t, rc, c, base + m, b);
            m = (m << 1) | b as usize;
        }
    }

    pub fn decode(&mut self, t: &Tables, rc: &mut RangeDec, c: &LenCtx) -> u32 {
        let (base, nb, off) = if self.dec_bit(t, rc, c, 0) == 0 {
            (2, 3, 0)
        } else if self.dec_bit(t, rc, c, 1) == 0 {
            (10, 3, 8)
        } else {
            (18, 8, 16)
        };
        let mut m = 1usize;
        for _ in 0..nb {
            m = (m << 1) | self.dec_bit(t, rc, c, base + m) as usize;
        }
        off + (m - (1 << nb)) as u32
    }

    /// 分割案の先頭：長さ区分 ls（0..=3）を 2bit の木で送る。
    pub fn encode_head(&mut self, t: &Tables, rc: &mut RangeEnc, c: &LenCtx, ls: u32) {
        let b1 = ls >> 1;
        self.enc_bit(t, rc, c, HEAD + 1, b1);
        self.enc_bit(t, rc, c, HEAD + 2 + b1 as usize, ls & 1);
    }

    pub fn decode_head(&mut self, t: &Tables, rc: &mut RangeDec, c: &LenCtx) -> u32 {
        let b1 = self.dec_bit(t, rc, c, HEAD + 1);
        let b0 = self.dec_bit(t, rc, c, HEAD + 2 + b1 as usize);
        (b1 << 1) | b0
    }

    /// 主入力の counter だけで、v（0..=271）の価格表を作る（parse の近似価格）。
    pub fn fill_row(&self, t: &Tables, ps: usize, dc: usize, out: &mut [u32]) {
        let c = LenCtx {
            ps,
            dc,
            kind: 0,
            pl: 0,
            st: 0,
        };
        let bp = |node: usize, bit: u32| t.bit_price(self.t0[self.idx0(&c, node)].p, bit);
        let c0 = bp(0, 0);
        let c10 = bp(0, 1) + bp(1, 0);
        let c11 = bp(0, 1) + bp(1, 1);
        // 木の各節までの価格を前から積む（節 m の子は 2m, 2m+1）。
        let mut acc = [0u32; 512];
        let mut sub = |base: usize, nb: u32, start: u32, outv: &mut [u32], first: usize| {
            acc[1] = start;
            for m in 1usize..(1 << nb) {
                let a = acc[m];
                acc[2 * m] = a + bp(base + m, 0);
                acc[2 * m + 1] = a + bp(base + m, 1);
            }
            for s in 0..(1usize << nb) {
                if first + s < outv.len() {
                    outv[first + s] = acc[(1 << nb) + s];
                }
            }
        };
        sub(2, 3, c0, out, 0);
        sub(10, 3, c10, out, 8);
        sub(18, 8, c11, out, 16);
    }

    /// 分割案の先頭（ls）の価格 4 値。
    pub fn head_prices(&self, t: &Tables, ps: usize, dc: usize) -> [u32; 4] {
        let c = LenCtx {
            ps,
            dc,
            kind: 0,
            pl: 0,
            st: 0,
        };
        let bp = |node: usize, bit: u32| t.bit_price(self.t0[self.idx0(&c, node)].p, bit);
        let mut o = [0u32; 4];
        for (ls, v) in o.iter_mut().enumerate() {
            let b1 = (ls >> 1) as u32;
            *v = bp(HEAD + 1, b1) + bp(HEAD + 2 + b1 as usize, (ls & 1) as u32);
        }
        o
    }
}
