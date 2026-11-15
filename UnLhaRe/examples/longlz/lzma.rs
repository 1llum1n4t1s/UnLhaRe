//! 長距離LZ試作の本体：LZMA と同じ記号・文脈（lc=3, lp=0, pb=2）の model、逐次復号器、
//! 符号化器と、7-Zip の optimum に倣った価格つき最適parse。
//! 出力は `.lzma` 単体形式（props 0x5D、辞書長、生データ長）で、xz でも展開できる。
//! これにより自前の復号器と独立な実装の両方で、符号化結果の正しさを確かめられる。

use super::mf::{Bt4, Finder, MAX_LEN, Match, Scope, common};
use super::mix::{LenCfg, LenCtx, LenMix, LitMix, NDC, NPL, Tables};
use super::rc::{BIT_PRICE, PROB_INIT, Prices, RangeDec, RangeEnc};
use super::shadow::Shadow;
use super::shadow2::MatchShadow;

const LC: u32 = 3;
const POS_STATES: usize = 4;
const PB_MASK: usize = POS_STATES - 1;
const STATES: usize = 12;
const LIT_SIZE: usize = 0x300;
const FULL_DISTANCES: usize = 128;
const END_POS_MODEL: usize = 14;
/// lc=3, lp=0, pb=2 の props byte。
pub const PROPS: u8 = 0x5D;

/// 長さ符号の model（low/mid は pos_state ごと）。
#[derive(Clone)]
struct LenModel {
    choice: u16,
    choice2: u16,
    low: [[u16; 8]; POS_STATES],
    mid: [[u16; 8]; POS_STATES],
    high: [u16; 256],
}

impl LenModel {
    fn new() -> Self {
        Self {
            choice: PROB_INIT,
            choice2: PROB_INIT,
            low: [[PROB_INIT; 8]; POS_STATES],
            mid: [[PROB_INIT; 8]; POS_STATES],
            high: [PROB_INIT; 256],
        }
    }

    #[inline(always)]
    fn decode(&mut self, rc: &mut RangeDec, ps: usize) -> u32 {
        if rc.bit(&mut self.choice) == 0 {
            return rc.tree(&mut self.low[ps], 3);
        }
        if rc.bit(&mut self.choice2) == 0 {
            return 8 + rc.tree(&mut self.mid[ps], 3);
        }
        16 + rc.tree(&mut self.high, 8)
    }

    fn encode(&mut self, rc: &mut RangeEnc, len: u32, ps: usize) {
        if len < 8 {
            rc.bit(&mut self.choice, 0);
            rc.tree(&mut self.low[ps], 3, len);
        } else if len < 16 {
            rc.bit(&mut self.choice, 1);
            rc.bit(&mut self.choice2, 0);
            rc.tree(&mut self.mid[ps], 3, len - 8);
        } else {
            rc.bit(&mut self.choice, 1);
            rc.bit(&mut self.choice2, 1);
            rc.tree(&mut self.high, 8, len - 16);
        }
    }

    /// pos_state ごとに、長さ 2..=273 の価格表を作る。
    fn fill(&self, pr: &Prices, out: &mut [[u32; MAX_LEN - 1]; POS_STATES]) {
        let c0 = pr.bit(self.choice, 0);
        let c1 = pr.bit(self.choice, 1);
        let c10 = c1 + pr.bit(self.choice2, 0);
        let c11 = c1 + pr.bit(self.choice2, 1);
        let mut high = [0u32; 256];
        for (i, h) in high.iter_mut().enumerate() {
            *h = c11 + pr.tree(&self.high, 8, i as u32);
        }
        for (ps, row) in out.iter_mut().enumerate() {
            for (l, slot) in row.iter_mut().enumerate() {
                *slot = if l < 8 {
                    c0 + pr.tree(&self.low[ps], 3, l as u32)
                } else if l < 16 {
                    c10 + pr.tree(&self.mid[ps], 3, l as u32 - 8)
                } else {
                    high[l - 16]
                };
            }
        }
    }
}

/// 長さ混合の試作の案（容器 `LLZSEGX` に記録し、復号側も同じ値で読む）。既定値は今の revision 14（V0）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Var {
    /// 通常一致の記号の順序。0：今の順序（flag→長さ→距離）、1：距離を先に送る（flag→距離→長さ）、
    /// 2：分割（flag→長さ区分 ls→距離→ls==3 なら残りの長さ）。
    pub order: u8,
    /// 長さの coder。k=0 は LZMA の長さ model（order 0 だけ）、1 以上は `LenMix`。
    pub len: LenCfg,
    /// rep 一致の長さも `LenMix` で送る（距離区分は 15＋rep 番号）。
    pub rep_new: u8,
    /// order 0 で、slot の文脈を長さの 8 区分にする（V4）。
    pub wide_slot: u8,
    /// order 1 の slot・近傍番号の文脈。0：state の 4 区分、1：定数。
    pub sctx: u8,
    /// literal の案。0：LZMA（lc=3）、1：LZMA＋直前1byte の混合、2：LZMA＋直前2byte hash の混合、
    /// 3：LZMA の lc=8（単一文脈、直前 byte 全体）、4：直前2byte hash の単一文脈、
    /// 5：mode 1 の重みを固定（0.7/0.5、学習なし）、6：mode 1 の2確率の単純平均。
    /// 2入力目はどの mode でも一致 bit を含めない（一致の情報は LZMA 側の入力だけが持つ）。
    pub lit: u8,
    /// literal の hash 区画数の bit 数（mode 2/4）。
    pub lit_bits: u8,
    /// literal の2入力目の counter の移動量。
    pub lit_shift: u8,
    /// literal の重みの学習率の shift。
    pub lit_lr: u8,
    /// 混合する literal の上位 bit 数（1..=8）。
    pub lit_top: u8,
    /// 1 なら一致byte文脈の literal は混合しない。
    pub lit_nomatch: u8,
}

impl Var {
    pub fn is_base(&self) -> bool {
        *self == Var::default()
    }

    pub fn to_bytes(self) -> [u8; 16] {
        let l = self.len;
        [
            self.order,
            l.k,
            l.lim0,
            l.lim1,
            l.lr,
            l.high_coarse,
            l.reserved,
            self.rep_new,
            self.wide_slot,
            self.sctx,
            self.lit,
            self.lit_bits,
            self.lit_shift,
            self.lit_lr,
            self.lit_top,
            self.lit_nomatch,
        ]
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self, String> {
        let v = Var {
            order: b[0],
            len: LenCfg {
                k: b[1],
                lim0: b[2],
                lim1: b[3],
                lr: b[4],
                high_coarse: b[5],
                reserved: b[6],
            },
            rep_new: b[7],
            wide_slot: b[8],
            sctx: b[9],
            lit: b[10],
            lit_bits: b[11],
            lit_shift: b[12],
            lit_lr: b[13],
            lit_top: b[14],
            lit_nomatch: b[15],
        };
        v.check()?;
        Ok(v)
    }

    pub fn check(&self) -> Result<(), String> {
        let k = self.len.k;
        if self.order > 2 || k > 3 || self.sctx > 1 {
            return Err("variant fields".into());
        }
        if (self.order != 0 || self.rep_new != 0) && k == 0 {
            return Err("variant needs the mixed length coder (k >= 1)".into());
        }
        if k > 0 && (self.len.lr < 4 || self.len.lr > 20) {
            return Err("variant learning-rate shift".into());
        }
        if self.wide_slot != 0 && self.order != 0 {
            return Err("wide slot context is for order 0".into());
        }
        let mixed_lit = matches!(self.lit, 1 | 2 | 4 | 5 | 6);
        if self.lit > 6
            || (mixed_lit
                && (!(1..=12).contains(&self.lit_shift)
                    || (matches!(self.lit, 1 | 2) && !(4..=20).contains(&self.lit_lr))
                    || (matches!(self.lit, 2 | 4) && !(8..=18).contains(&self.lit_bits))))
        {
            return Err("literal variant fields".into());
        }
        Ok(())
    }

    /// slot の文脈の行数（order 0 で wide なら 8、それ以外は 4）。
    fn slot_rows(&self) -> usize {
        if self.wide_slot != 0 { 8 } else { 4 }
    }
}

/// V4 の slot 文脈：長さ-2 を 8 区分（0,1,2,3,4-5,6-9,10-21,22+）。
#[inline(always)]
fn len_wide(len: usize) -> usize {
    match len - 2 {
        v @ 0..=3 => v,
        4..=5 => 4,
        6..=9 => 5,
        10..=21 => 6,
        _ => 7,
    }
}

/// order 1 の slot・近傍番号の文脈：state を 4 区分（literal 続き、literal 後、通常一致後、rep 後）。
#[inline(always)]
fn state_class(st: usize, mode: u8) -> usize {
    if mode == 1 {
        return 0;
    }
    match st {
        0..=3 => 0,
        4..=6 => 1,
        7 | 10 => 2,
        _ => 3,
    }
}

/// 長さ文脈の距離区分：通常一致は slot/6（0..=10）、近傍は 11＋番号、rep は 15＋番号、分割案の先頭は 19。
const DC_NEAR: usize = 11;
const DC_REP: usize = 15;
const DC_HEAD: usize = 19;

/// 長さ混合の表（stretch・価格・速度）。全 thread で共有する。
fn tables() -> &'static Tables {
    static T: std::sync::OnceLock<Tables> = std::sync::OnceLock::new();
    T.get_or_init(Tables::new)
}

/// 直前の長さの区分（長さ混合の入力）。
#[inline(always)]
fn pl_class(prev_len: usize) -> usize {
    (prev_len.max(2) - 2).min(NPL - 1)
}

/// 符号化器・復号器が同じ規則で更新する確率の全体。
#[derive(Clone)]
struct Model {
    literal: Vec<u16>,
    is_match: [u16; STATES * POS_STATES],
    is_rep: [u16; STATES],
    g0: [u16; STATES],
    g1: [u16; STATES],
    g2: [u16; STATES],
    rep0_long: [u16; STATES * POS_STATES],
    /// 行 0..4 が今の文脈（min(長さ-2,3)）。V4 は 8 行、order 1 は state 区分の 4 行を使う。
    pos_slot: [[u16; 64]; 8],
    pos_special: [u16; 1 + FULL_DISTANCES - END_POS_MODEL],
    align: [u16; 16],
    len: LenModel,
    rep_len: LenModel,
    // 近傍距離符号（LLZSEG2 だけが使う。使わない場合も確率は初期値のまま触らない）。
    /// 近傍で書くか（文脈は更新前の state）。
    near_flag: [u16; STATES],
    /// どの rep 距離との差か。文脈は min(長さ-2, 3)、2bit の木。
    near_sel: [[u16; 4]; 4],
    /// 差の符号（負なら 1）。文脈は選んだ rep の番号。
    near_sign: [u16; 4],
    /// 差-1 の slot（5bit の木）。文脈は選んだ rep の番号。
    near_gap: [[u16; 32]; 4],
    /// 長さ混合の試作の coder（Var の len.k >= 1 のときだけ）。
    lm: Option<Box<LenMix>>,
    /// literal の文脈 bit 数（LZMA の lc。lit=3 なら 8）。
    lc: u32,
    /// literal 混合の試作（lit=1/2/4 のときだけ）。
    lx: Option<Box<LitMix>>,
}

impl Model {
    fn new(var: &Var) -> Self {
        let lc = if var.lit == 3 { 8 } else { LC };
        Self {
            lc,
            lx: matches!(var.lit, 1 | 2 | 4 | 5 | 6).then(|| {
                Box::new(LitMix::new(
                    var.lit,
                    var.lit_bits,
                    var.lit_shift,
                    var.lit_lr,
                    var.lit_top,
                    var.lit_nomatch != 0,
                ))
            }),
            literal: vec![PROB_INIT; LIT_SIZE << lc],
            is_match: [PROB_INIT; STATES * POS_STATES],
            is_rep: [PROB_INIT; STATES],
            g0: [PROB_INIT; STATES],
            g1: [PROB_INIT; STATES],
            g2: [PROB_INIT; STATES],
            rep0_long: [PROB_INIT; STATES * POS_STATES],
            pos_slot: [[PROB_INIT; 64]; 8],
            pos_special: [PROB_INIT; 1 + FULL_DISTANCES - END_POS_MODEL],
            align: [PROB_INIT; 16],
            len: LenModel::new(),
            rep_len: LenModel::new(),
            near_flag: [PROB_INIT; STATES],
            near_sel: [[PROB_INIT; 4]; 4],
            near_sign: [PROB_INIT; 4],
            near_gap: [[PROB_INIT; 32]; 4],
            lm: (var.len.k > 0).then(|| Box::new(LenMix::new(var.len))),
        }
    }
}

/// 近傍距離で書く一致の符号：選んだ rep の番号、差の向き（負なら true）、差-1。
#[derive(Clone, Copy)]
struct NearCode {
    i: usize,
    neg: bool,
    g: u32,
}

/// 近傍の差（距離-rep 距離の絶対値）の上限。差-1 が 16bit（slot 0..31）に収まる範囲。
const NEAR_MAX_DIFF: u32 = 1 << 16;

/// 混合長さの価格表の1行の長さ（v = 長さ-2 の 0..=271）。
const LP_ROW: usize = MAX_LEN - 1;

/// parse 用：通常一致1つ（距離ごと）の、長さに依らない価格の前計算。
#[derive(Clone, Copy)]
struct MatchCost {
    st: usize,
    dist: u32,
    /// 近傍の価格（flag 込み、長さ区分 ls ごと）。order 0/2 用。
    nc: [u32; 4],
    /// 通常の距離の価格（order 1）または flag の通常側の価格（order 0/2）。
    far: u32,
    /// 近傍の価格（order 1、flag 込み）。
    near: u32,
    /// 長さの価格表の行（通常・近傍）。
    row_far: usize,
    row_near: usize,
}

#[inline(always)]
fn lit_next(s: usize) -> usize {
    if s < 4 {
        0
    } else if s < 10 {
        s - 3
    } else {
        s - 6
    }
}
#[inline(always)]
fn match_next(s: usize) -> usize {
    if s < 7 { 7 } else { 10 }
}
#[inline(always)]
fn rep_next(s: usize) -> usize {
    if s < 7 { 8 } else { 11 }
}
#[inline(always)]
fn short_next(s: usize) -> usize {
    if s < 7 { 9 } else { 11 }
}

#[inline(always)]
fn pos_slot(dist: u32) -> u32 {
    if dist < 4 {
        dist
    } else {
        let n = 31 - dist.leading_zeros();
        (n << 1) | ((dist >> (n - 1)) & 1)
    }
}

#[inline(always)]
fn lit_base(prev: u8, lc: u32) -> usize {
    LIT_SIZE * (prev as usize >> (8 - lc))
}

/// literal 1 byte を送る・読む共通の手順（LZMA の木と一致byte文脈の規則は同じ）。
/// code(prob, p12) は 1bit を送るか読み、その bit を返す。p12 が 0 なら LZMA の確率 prob で（prob の更新込み）、
/// 0 でなければ混合した 12bit 確率 p12 で符号化し、prob は触らない（ここで更新する）。
/// keep_lz が false なら mode 4 で LZMA の確率の更新を省く（復号側。符号化側は parse の価格に使うので更新する）。
#[inline(always)]
fn lit_code<F: FnMut(&mut u16, u32) -> u32>(
    m: &mut Model,
    prev1: u8,
    prev2: u8,
    mb: Option<u8>,
    keep_lz: bool,
    mut code: F,
) -> u8 {
    let lb = lit_base(prev1, m.lc);
    let probs = &mut m.literal[lb..lb + LIT_SIZE];
    let mut sym = 1usize;
    let mut matching = mb.is_some();
    let mbyte = mb.unwrap_or(0) as usize;
    let Some(lx) = m.lx.as_mut() else {
        for i in (0..8).rev() {
            let node = if matching {
                ((1 + ((mbyte >> i) & 1)) << 8) + sym
            } else {
                sym
            };
            let bit = code(&mut probs[node], 0);
            if matching && ((mbyte >> i) & 1) as u32 != bit {
                matching = false;
            }
            sym = (sym << 1) | bit as usize;
        }
        return sym as u8;
    };
    let tb = tables();
    // 区画の先読み（_mm_prefetch）も試したが、展開時間は変わらなかった（english・linux・dblp）ので入れない。
    let b1 = lx.base(prev1, prev2);
    // 混合する bit の範囲：上位 top bit だけ。nomatch なら一致byte文脈の literal は混合しない。
    let low = 8 - lx.top as usize;
    let skip_all = lx.nomatch && mb.is_some();
    for i in (0..8).rev() {
        let mbit = (mbyte >> i) & 1;
        let node = if matching {
            ((1 + mbit) << 8) + sym
        } else {
            sym
        };
        if skip_all || i < low {
            let bit = code(&mut probs[node], 0);
            if matching && mbit as u32 != bit {
                matching = false;
            }
            sym = (sym << 1) | bit as usize;
            continue;
        }
        // 2入力目は一致 bit を含めない（一致の情報は LZMA 側の入力だけが持つ）。
        let i1 = b1 + sym;
        let ws = (matching as usize) * 8 + i;
        let (p, s) = lx.predict(tb, probs[node], i1, ws);
        let bit = code(&mut probs[node], p as u32);
        if keep_lz || lx.mode != 4 {
            let q = &mut probs[node];
            if bit == 0 {
                *q += (2048 - *q) >> 5;
            } else {
                *q -= *q >> 5;
            }
        }
        lx.update(i1, ws, s, p, bit);
        if matching && mbit as u32 != bit {
            matching = false;
        }
        sym = (sym << 1) | bit as usize;
    }
    sym as u8
}

/// `.lzma` 単体形式の stream を復号する（props は 0x5D のみ）。
pub fn decode(stream: &[u8]) -> Result<Vec<u8>, String> {
    if stream.len() < 13 || stream[0] != PROPS {
        return Err("header or properties".into());
    }
    let size = u64::from_le_bytes(stream[5..13].try_into().unwrap());
    // 長さ不明（xz -F lzma の既定）は終端記号まで復号する。
    let known = size != u64::MAX;
    let size = if known {
        usize::try_from(size).map_err(|_| "size")?
    } else {
        usize::MAX
    };
    let mut out: Vec<u8> = Vec::with_capacity(if known { size } else { stream.len() * 16 });
    let scope = Scope {
        end: size,
        seg_start: 0,
        wave_start: 0,
    };
    decode_segment(
        &stream[13..],
        &[],
        &mut out,
        &scope,
        known,
        false,
        &Var::default(),
    )?;
    Ok(out)
}

/// 参照元 s から len byte を写してよいか（segment 内、または wave 開始より前で完結する範囲）。
#[inline(always)]
fn source_ok(scope: &Scope, s: usize, len: usize) -> bool {
    s >= scope.seg_start || s + len <= scope.wave_start
}

/// 1 segment（scope.seg_start から scope.end まで）を own へ復号する。
/// base は wave 開始より前の出力全体、own はこの segment の出力（空から始める）。
/// 同じ wave の他 segment（wave_start..seg_start）は読まないので、並列に復号できる。
pub fn decode_segment(
    body: &[u8],
    base: &[u8],
    own: &mut Vec<u8>,
    scope: &Scope,
    known: bool,
    near: bool,
    var: &Var,
) -> Result<(), String> {
    let seg = scope.seg_start;
    if base.len() < scope.wave_start {
        return Err("missing data before the wave".into());
    }
    let size = scope.end - seg;
    let mut rc = RangeDec::new(body)?;
    let mut m = Model::new(var);
    let tb = tables();
    // 長さ混合の入力「直前の長さ」。通常・近傍・rep（長さ2以上）の一致で更新し、短 rep では変えない。
    let mut prev_len = 2usize;
    let (mut rep0, mut rep1, mut rep2, mut rep3) = (0usize, 0usize, 0usize, 0usize);
    let mut state = 0usize;
    // 絶対位置 s の byte（自 segment なら own、wave より前なら base）。
    let at = |own: &Vec<u8>, s: usize| if s >= seg { own[s - seg] } else { base[s] };
    while own.len() < size {
        let pos = seg + own.len();
        let ps = pos & PB_MASK;
        if rc.bit(&mut m.is_match[state * POS_STATES + ps]) == 0 {
            // segment 先頭の直前 byte は他 segment のものなので 0 とみなす。
            let prev = if pos > seg { own[pos - seg - 1] } else { 0 };
            // 一致byte文脈は、その byte を読める場合だけ使う（符号化側と同じ規則）。
            let mb = (state >= 7 && rep0 < pos && source_ok(scope, pos - rep0 - 1, 1))
                .then(|| at(own, pos - rep0 - 1));
            if m.lx.is_none() && m.lc == LC {
                // 今の revision 14 の経路（変更前と同じ処理）。
                let lb = lit_base(prev, LC);
                let probs = &mut m.literal[lb..lb + LIT_SIZE];
                let mut sym = 1usize;
                if let Some(mbv) = mb {
                    let mut match_byte = mbv as usize;
                    while sym < 0x100 {
                        let match_bit = (match_byte >> 7) & 1;
                        match_byte <<= 1;
                        let bit = rc.bit(&mut probs[((1 + match_bit) << 8) + sym]) as usize;
                        sym = (sym << 1) | bit;
                        if match_bit != bit {
                            break;
                        }
                    }
                }
                while sym < 0x100 {
                    sym = (sym << 1) | rc.bit(&mut probs[sym]) as usize;
                }
                own.push(sym as u8);
            } else if let Some(lx) = m.lx.as_mut().filter(|lx| lx.fast_o1()) {
                // L2 の専用経路（lit_code と同じ演算、bit 列は同じ）。
                let lb = lit_base(prev, LC);
                let probs: &mut [u16; LIT_SIZE] = (&mut m.literal[lb..lb + LIT_SIZE])
                    .try_into()
                    .map_err(|_| "literal table")?;
                own.push(lx.decode_o1(tb, probs, &mut rc, prev, mb));
            } else {
                let prev2 = if pos > seg + 1 { own[pos - seg - 2] } else { 0 };
                let b = lit_code(&mut m, prev, prev2, mb, false, |q, p12| {
                    if p12 == 0 { rc.bit(q) } else { rc.bit12(p12) }
                });
                own.push(b);
            }
            state = lit_next(state);
            continue;
        }
        let len;
        if rc.bit(&mut m.is_rep[state]) != 0 {
            if pos == 0 {
                return Err("rep at start".into());
            }
            let mut ri = 0usize;
            if rc.bit(&mut m.g0[state]) == 0 {
                if rc.bit(&mut m.rep0_long[state * POS_STATES + ps]) == 0 {
                    if rep0 >= pos || !source_ok(scope, pos - rep0 - 1, 1) {
                        return Err("short rep source outside the segment scope".into());
                    }
                    state = short_next(state);
                    let b = at(own, pos - rep0 - 1);
                    own.push(b);
                    continue;
                }
            } else {
                let dist;
                if rc.bit(&mut m.g1[state]) == 0 {
                    dist = rep1;
                    ri = 1;
                } else {
                    if rc.bit(&mut m.g2[state]) == 0 {
                        dist = rep2;
                        ri = 2;
                    } else {
                        dist = rep3;
                        rep3 = rep2;
                        ri = 3;
                    }
                    rep2 = rep1;
                }
                rep1 = rep0;
                rep0 = dist;
            }
            len = match m.lm.as_mut().filter(|_| var.rep_new != 0) {
                Some(lm) => {
                    let c = LenCtx {
                        ps,
                        dc: DC_REP + ri,
                        kind: 2,
                        pl: pl_class(prev_len),
                        st: state,
                    };
                    lm.decode(tb, &mut rc, &c) as usize
                }
                None => m.rep_len.decode(&mut rc, ps) as usize,
            };
            state = rep_next(state);
        } else if var.order != 0 {
            // 長さ混合の試作（order 1：距離→長さ、order 2：長さ区分→距離→残りの長さ）。
            let old = [rep0, rep1, rep2, rep3];
            let st0 = state;
            let use_near = near && rc.bit(&mut m.near_flag[state]) != 0;
            let mut c = LenCtx {
                ps,
                dc: DC_HEAD,
                kind: use_near as usize,
                pl: pl_class(prev_len),
                st: st0,
            };
            // order 2 の長さ区分（order 1 では距離の文脈に使わない）。
            let ls = if var.order == 2 {
                let lm = m.lm.as_mut().ok_or("length coder")?;
                lm.decode_head(tb, &mut rc, &c) as usize
            } else {
                0
            };
            let ctx = if var.order == 2 {
                ls
            } else {
                state_class(st0, var.sctx)
            };
            let dc;
            if use_near {
                let i = rc.tree(&mut m.near_sel[ctx], 2) as usize;
                if old[..i].contains(&old[i]) {
                    return Err("non-canonical near selector".into());
                }
                let neg = rc.bit(&mut m.near_sign[i]) != 0;
                let gs = rc.tree(&mut m.near_gap[i], 5);
                let g = if gs < 4 {
                    gs
                } else {
                    let footer = (gs >> 1) - 1;
                    ((2 | (gs & 1)) << footer) + rc.direct(footer)
                } as usize;
                let diff = g + 1;
                let dist = if neg {
                    old[i].checked_sub(diff).ok_or("near distance below zero")?
                } else {
                    old[i] + diff
                };
                if old.contains(&dist) {
                    return Err("near distance equals a rep".into());
                }
                rep0 = dist;
                dc = DC_NEAR + i;
            } else {
                let slot = rc.tree(&mut m.pos_slot[ctx], 6) as usize;
                if slot < 4 {
                    rep0 = slot;
                } else {
                    let direct = ((slot >> 1) - 1) as u32;
                    let mut dist = (2 | (slot & 1)) << direct;
                    if slot < END_POS_MODEL {
                        let b = dist - slot;
                        dist += rc.reverse(&mut m.pos_special[b..], direct) as usize;
                    } else {
                        dist += (rc.direct(direct - 4) as usize) << 4;
                        dist += rc.reverse(&mut m.align, 4) as usize;
                    }
                    rep0 = dist;
                }
                dc = slot / 6;
            }
            rep1 = old[0];
            rep2 = old[1];
            rep3 = old[2];
            c.dc = dc;
            let lm = m.lm.as_mut().ok_or("length coder")?;
            len = if var.order == 1 {
                lm.decode(tb, &mut rc, &c) as usize
            } else if ls == 3 {
                3 + lm.decode(tb, &mut rc, &c) as usize
            } else {
                ls
            };
            if len > MAX_LEN - 2 {
                return Err("length beyond the maximum".into());
            }
            state = match_next(state);
        } else {
            // 近傍 flag の文脈は更新前の state。rep 履歴も更新前の値で選ぶので先に退避する。
            let old = [rep0, rep1, rep2, rep3];
            let st0 = state;
            let use_near = near && rc.bit(&mut m.near_flag[state]) != 0;
            rep3 = rep2;
            rep2 = rep1;
            rep1 = rep0;
            len = match m.lm.as_mut() {
                // V4：順序は今のまま、長さを混合で送る（距離区分は通常 0・近傍 11）。
                Some(lm) => {
                    let c = LenCtx {
                        ps,
                        dc: if use_near { DC_NEAR } else { 0 },
                        kind: use_near as usize,
                        pl: pl_class(prev_len),
                        st: st0,
                    };
                    lm.decode(tb, &mut rc, &c) as usize
                }
                None => m.len.decode(&mut rc, ps) as usize,
            };
            state = match_next(state);
            if use_near {
                let i = rc.tree(&mut m.near_sel[len.min(3)], 2) as usize;
                // 同じ距離の rep が先にある番号は符号化側が選ばない（正規形）。
                if old[..i].contains(&old[i]) {
                    return Err("non-canonical near selector".into());
                }
                let neg = rc.bit(&mut m.near_sign[i]) != 0;
                let gs = rc.tree(&mut m.near_gap[i], 5);
                let g = if gs < 4 {
                    gs
                } else {
                    let footer = (gs >> 1) - 1;
                    ((2 | (gs & 1)) << footer) + rc.direct(footer)
                } as usize;
                let diff = g + 1;
                let dist = if neg {
                    old[i].checked_sub(diff).ok_or("near distance below zero")?
                } else {
                    old[i] + diff
                };
                // rep と等しい距離は rep 記号で書く（正規形）。
                if old.contains(&dist) {
                    return Err("near distance equals a rep".into());
                }
                rep0 = dist;
            } else {
                let row = if var.wide_slot != 0 {
                    len_wide(len + 2)
                } else {
                    len.min(3)
                };
                let slot = rc.tree(&mut m.pos_slot[row], 6) as usize;
                if slot < 4 {
                    rep0 = slot;
                } else {
                    let direct = ((slot >> 1) - 1) as u32;
                    let mut dist = (2 | (slot & 1)) << direct;
                    if slot < END_POS_MODEL {
                        let b = dist - slot;
                        dist += rc.reverse(&mut m.pos_special[b..], direct) as usize;
                    } else {
                        dist += (rc.direct(direct - 4) as usize) << 4;
                        dist += rc.reverse(&mut m.align, 4) as usize;
                    }
                    rep0 = dist;
                }
            }
            if rep0 == u32::MAX as usize {
                if known {
                    return Err("unexpected end marker".into());
                }
                break;
            }
        }
        let len = len + 2;
        prev_len = len;
        if rep0 >= pos {
            return Err("distance beyond output".into());
        }
        if known && own.len() + len > size {
            return Err("match beyond declared size".into());
        }
        let from = pos - rep0 - 1;
        if !source_ok(scope, from, len) {
            return Err("match source outside the segment scope".into());
        }
        if from < seg {
            // wave より前で完結する参照（source_ok で保証）は一括で写す。
            own.extend_from_slice(&base[from..from + len]);
        } else {
            let f = from - seg;
            if rep0 + 1 >= len {
                own.extend_from_within(f..f + len);
            } else {
                for i in 0..len {
                    let b = own[f + i];
                    own.push(b);
                }
            }
        }
    }
    if known && rc.consumed() > body.len() {
        return Err("truncated stream".into());
    }
    Ok(())
}

/// segment 容器を復号する。同じ wave の segment は threads 本まで並列に復号する。
pub fn decode_container(data: &[u8], threads: usize) -> Result<Vec<u8>, String> {
    let rd32 = |o: usize| -> Result<usize, String> {
        data.get(o..o + 4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
            .ok_or_else(|| "short container".to_string())
    };
    if data.len() < 32 || !is_container(data) {
        return Err("container magic".into());
    }
    let xvar = &data[..8] == SEG_MAGICX;
    let near = &data[..8] == SEG_MAGIC2 || xvar;
    // `LLZSEGX` は 32 byte の header の後に案の設定 16 byte を置く（近傍は常にあり）。
    let (var, hdr) = if xvar {
        (
            Var::from_bytes(data.get(32..48).ok_or("short container")?)?,
            48,
        )
    } else {
        (Var::default(), 32)
    };
    let n =
        usize::try_from(u64::from_le_bytes(data[8..16].try_into().unwrap())).map_err(|_| "size")?;
    let segment = rd32(16)?;
    let wave = rd32(20)?;
    let count = rd32(28)?;
    if segment == 0 || wave == 0 || count != n.div_ceil(segment).max(1) {
        return Err("container geometry".into());
    }
    let mut bodies = Vec::with_capacity(count);
    let mut off = hdr + 4 * count;
    for i in 0..count {
        let len = rd32(hdr + 4 * i)?;
        let b = data.get(off..off + len).ok_or("body beyond container")?;
        bodies.push(b);
        off += len;
    }
    let mut out = Vec::with_capacity(n);
    for wave_first in (0..count).step_by(wave) {
        let wave_start = wave_first * segment;
        let members: Vec<usize> = (wave_first..(wave_first + wave).min(count)).collect();
        let base = &out[..];
        let decode_one = |k: usize| -> Result<Vec<u8>, String> {
            let scope = Scope {
                end: ((k + 1) * segment).min(n),
                seg_start: k * segment,
                wave_start,
            };
            let mut own = Vec::with_capacity(scope.end - scope.seg_start);
            decode_segment(bodies[k], base, &mut own, &scope, true, near, &var)?;
            Ok(own)
        };
        let parts: Vec<Result<Vec<u8>, String>> = if threads <= 1 {
            members.iter().map(|&k| decode_one(k)).collect()
        } else {
            std::thread::scope(|sc| {
                let handles: Vec<_> = members
                    .chunks(members.len().div_ceil(threads.min(members.len())))
                    .map(|ks| {
                        sc.spawn(move || ks.iter().map(|&k| decode_one(k)).collect::<Vec<_>>())
                    })
                    .collect();
                handles
                    .into_iter()
                    .flat_map(|h| {
                        h.join()
                            .unwrap_or_else(|_| vec![Err("worker panicked".into())])
                    })
                    .collect()
            })
        };
        for part in parts {
            out.extend_from_slice(&part?);
        }
    }
    Ok(out)
}

/// 最適parseの1節点。back は LIT、rep 番号（0..4）、または 距離-1 + 4。
#[derive(Clone, Copy)]
struct Opt {
    price: u32,
    pos_prev: u32,
    back: u32,
    state: u8,
    reps: [u32; 4],
    /// 0: 単独の記号。1: pos_prev-1 からの literal の後に rep0（back=0）。
    /// 2: さらに pos_prev2 からの記号（back_prev2）が literal の前にある。
    combo: u8,
    pos_prev2: u32,
    back_prev2: u32,
}

const LIT: u32 = u32::MAX;
const INF: u32 = u32::MAX / 2;
/// 1回の最適parseで先読みする最大の位置数。
const OPTS: usize = 1 << 12;
/// この長さ以上の一致は先読みせずそのまま採る（7-Zip の fb に当たる）。
pub const NICE: usize = MAX_LEN;
/// 価格表を作り直す間隔（符号化した記号数）。
const REFRESH: u32 = 256;

pub struct Settings {
    pub window: usize,
    pub cut: u32,
    pub nice: usize,
    /// segment 長（0 なら全体を1 segment とし `.lzma` 単体形式で出す）。
    pub segment: usize,
    /// 同時に復号する segment 数（wave 幅）。
    pub wave: usize,
    /// 近傍距離符号を使う（容器は `LLZSEG2`。segment 指定が必要で、`.lzma` 単体形式とは両立しない）。
    pub near: bool,
    /// 長さ混合の試作の案（既定は今の revision 14）。
    pub var: Var,
}

/// 全 segment の符号長の内訳（bit）。LLZ_STATS=1 のときだけ集める。
static STATS: std::sync::Mutex<[f64; 10]> = std::sync::Mutex::new([0.0; 10]);

fn add_stats(st: &[f64; 10]) {
    if let Ok(mut all) = STATS.lock() {
        for (a, b) in all.iter_mut().zip(st.iter()) {
            *a += b;
        }
    }
}

/// parse の手間の計数（計測用）：optimum の呼出し数、先読みの節点数、一致の長さを試した回数。
pub static OPTIMUM_CALLS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static DP_NODES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static LEN_STEPS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 近傍距離の計数（LLZ_STATS 用）：parse が近傍の価格を計算した回数、通常一致の記号数、近傍で書いた数。
pub static NEAR_EVALS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static NORMAL_MATCHES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static NEAR_USED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 影の literal model の見積もり（bit）。
static SHADOW_BITS: std::sync::Mutex<f64> = std::sync::Mutex::new(0.0);

/// 一致の影 model の見積もりの合計（名前ごと、LLZ_SHADOW2=1 のとき）。
static SHADOW2: std::sync::Mutex<Vec<(&'static str, f64)>> = std::sync::Mutex::new(Vec::new());

/// 一致の影 model の見積もりを返す。
pub fn shadow2_report() -> Vec<(&'static str, f64)> {
    SHADOW2.lock().map(|g| g.clone()).unwrap_or_default()
}

/// 影の literal model の見積もり（bit）を返す。
pub fn shadow_bits() -> f64 {
    SHADOW_BITS.lock().map(|g| *g).unwrap_or(0.0)
}

/// 集めた内訳（bit）を返す。
pub fn stats() -> [f64; 10] {
    STATS.lock().map(|g| *g).unwrap_or([0.0; 10])
}

/// k 番目の segment の範囲と参照規則（segment 長・wave 幅は形式の値）。
pub fn segment_scope(n: usize, segment: usize, wave: usize, k: usize) -> Scope {
    Scope {
        end: ((k + 1) * segment).min(n),
        seg_start: k * segment,
        wave_start: k / wave * wave * segment,
    }
}

/// segment の body 列を容器へ組む。1 segment だけなら `.lzma` 単体形式にする。
pub fn assemble(
    n: usize,
    segment: usize,
    wave: usize,
    window: usize,
    near: bool,
    var: &Var,
    mut bodies: Vec<Vec<u8>>,
) -> Vec<u8> {
    // 近傍ありは body が1つでも容器にする（`.lzma` 単体形式は近傍を表せない）。
    if bodies.len() > 1 || near {
        // segment 容器: magic, 生データ長, segment 長, wave 幅, 窓長, 個数, [案の設定], 各 body 長, body 列。
        let mut out = Vec::new();
        out.extend_from_slice(if !var.is_base() {
            SEG_MAGICX
        } else if near {
            SEG_MAGIC2
        } else {
            SEG_MAGIC
        });
        out.extend_from_slice(&(n as u64).to_le_bytes());
        out.extend_from_slice(&(segment as u32).to_le_bytes());
        out.extend_from_slice(&(wave as u32).to_le_bytes());
        out.extend_from_slice(&(window as u32).to_le_bytes());
        out.extend_from_slice(&(bodies.len() as u32).to_le_bytes());
        if !var.is_base() {
            out.extend_from_slice(&var.to_bytes());
        }
        for b in &bodies {
            out.extend_from_slice(&(b.len() as u32).to_le_bytes());
        }
        for b in &bodies {
            out.extend_from_slice(b);
        }
        return out;
    }
    let body = bodies.pop().unwrap_or_default();
    let mut out = Vec::with_capacity(13 + body.len());
    out.push(PROPS);
    // xz は辞書長が 2^n（または 2^n+2^(n-1)）でないと単体形式として認めないため、2^n へ切り上げる。
    out.extend_from_slice(&(window.next_power_of_two() as u32).to_le_bytes());
    out.extend_from_slice(&(n as u64).to_le_bytes());
    out.extend_from_slice(&body);
    out
}

/// segment 形式の容器の magic。
pub const SEG_MAGIC: &[u8; 8] = b"LLZSEG1\0";
/// 近傍距離符号を使う segment 容器の magic（形式の他の部分は `LLZSEG1` と同じ）。
pub const SEG_MAGIC2: &[u8; 8] = b"LLZSEG2\0";

/// 長さ混合の試作の segment 容器の magic（近傍あり、header の後に案の設定 16 byte）。
pub const SEG_MAGICX: &[u8; 8] = b"LLZSEGX\0";

/// segment 容器（近傍の有無を問わない）か。
pub fn is_container(data: &[u8]) -> bool {
    data.starts_with(SEG_MAGIC) || data.starts_with(SEG_MAGIC2) || data.starts_with(SEG_MAGICX)
}

pub struct Encoder<'a, F: Finder = Bt4> {
    data: &'a [u8],
    m: Model,
    rc: RangeEnc,
    pr: Prices,
    mf: F,
    nice: usize,
    state: usize,
    reps: [u32; 4],
    len_prices: Box<[[u32; MAX_LEN - 1]; POS_STATES]>,
    rep_len_prices: Box<[[u32; MAX_LEN - 1]; POS_STATES]>,
    slot_prices: [[u32; 64]; 8],
    dist_prices: [[u32; FULL_DISTANCES]; 8],
    /// 長さ混合の試作の案。
    var: Var,
    /// 価格表を作り直す間隔（計測用に LLZ_REFRESH で変えられる。既定 256）。
    refresh_every: u32,
    /// 診断（LLZ_DIAG_LZPRICE=1）：order 0 の混合長さで、parse の長さ価格を LZMA の model から取る。
    diag_lzprice: bool,
    /// 直前の一致の長さ（長さ混合の入力。復号側と同じ規則で更新）。
    prev_len: usize,
    /// 混合長さの価格表：行 (ps×NDC＋dc) ごとに v=0..272 の価格。使うときに世代を見て作り直す。
    lp: Vec<u32>,
    lp_gen: Vec<u32>,
    gen_no: u32,
    /// 分割案の先頭（長さ区分 ls）の価格（ps ごと）。
    hp: [[u32; 4]; POS_STATES],
    align_prices: [u32; 16],
    since_refresh: u32,
    opts: Vec<Opt>,
    first: Vec<Match>,
    cur_matches: Vec<Match>,
    /// 先読みを長い一致で打ち切った位置の一致候補（その位置は索引へ挿入済み）。
    cached: Option<usize>,
    path: Vec<(u32, u32)>,
    scope: Scope,
    segment: usize,
    wave: usize,
    /// literal を強い model で符号化した場合の見積もり（LLZ_SHADOW=1 のときだけ）。
    shadow: Option<Box<Shadow>>,
    /// 距離・長さの影 model（LLZ_SHADOW2=1 のときだけ）。
    shadow2: Option<Box<MatchShadow>>,
    /// 連結記号（literal＋rep0 など）を試すか（計測用に LLZ_NOCOMBO=1 で切れる）。
    combos: bool,
    /// 近傍距離符号を使う（emit が近傍を選べる）。
    near: bool,
    /// parse の価格にも近傍を入れる（LLZ_NEAR_PARSE=0 なら false：parse は従来の価格で、emit だけが近傍を選ぶ）。
    near_parse: bool,
    /// 近傍の価格表（refresh で作る）。flag は文脈 state ごとの [通常, 近傍]、
    /// sel は [長さ文脈][rep 番号]、sign は [rep 番号][負か]、gap は [rep 番号][slot]（footer の平坦 bit 込み）。
    flag_price: [[u32; 2]; STATES],
    sel_price: [[u32; 4]; 4],
    sign_price: [[u32; 2]; 4],
    gap_price: [[u32; 32]; 4],
    /// 近傍の価格（sel+sign+gap）の下界。flag の価格を足して通常の価格以上なら近傍の計算を省ける。
    near_floor: u32,
    /// 計数（segment ごとに数え、終了時に static へ足す）。
    near_evals: u64,
    normal_matches: u64,
    near_used: u64,
}

impl<'a> Encoder<'a, Bt4> {
    /// 逐次の BT4 を使う encoder。
    pub fn new(data: &'a [u8], s: &Settings) -> Self {
        Self::with_finder(data, s, Bt4::new(s.window, s.cut))
    }
}

impl<'a, F: Finder> Encoder<'a, F> {
    /// 一致探索器を指定して作る（並列探索の結果を読み出す場合など）。
    pub fn with_finder(data: &'a [u8], s: &Settings, mf: F) -> Self {
        let mut e = Self {
            data,
            m: Model::new(&s.var),
            // 出力の見込み（segment 単位で符号化するので segment 長を上限に見積もる）。
            rc: RangeEnc::new(
                if s.segment == 0 {
                    data.len()
                } else {
                    s.segment.min(data.len())
                } / 3
                    + 64,
            ),
            pr: Prices::new(),
            mf,
            nice: s.nice.clamp(8, MAX_LEN),
            state: 0,
            reps: [0; 4],
            len_prices: Box::new([[0; MAX_LEN - 1]; POS_STATES]),
            rep_len_prices: Box::new([[0; MAX_LEN - 1]; POS_STATES]),
            slot_prices: [[0; 64]; 8],
            dist_prices: [[0; FULL_DISTANCES]; 8],
            var: s.var,
            refresh_every: std::env::var("LLZ_REFRESH")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(REFRESH),
            diag_lzprice: std::env::var("LLZ_DIAG_LZPRICE").is_ok_and(|v| v == "1"),
            prev_len: 2,
            lp: vec![0; POS_STATES * NDC * LP_ROW],
            lp_gen: vec![0; POS_STATES * NDC],
            gen_no: 1,
            hp: [[0; 4]; POS_STATES],
            align_prices: [0; 16],
            since_refresh: 0,
            opts: vec![
                Opt {
                    price: INF,
                    pos_prev: 0,
                    back: LIT,
                    state: 0,
                    reps: [0; 4],
                    combo: 0,
                    pos_prev2: 0,
                    back_prev2: 0,
                };
                OPTS + 1
            ],
            first: Vec::with_capacity(MAX_LEN),
            cur_matches: Vec::with_capacity(MAX_LEN),
            cached: None,
            path: Vec::with_capacity(OPTS),
            scope: Scope {
                end: data.len(),
                seg_start: 0,
                wave_start: 0,
            },
            segment: if s.segment == 0 {
                data.len().max(1)
            } else {
                s.segment
            },
            wave: s.wave.max(1),
            shadow: None,
            shadow2: None,
            combos: !std::env::var("LLZ_NOCOMBO").is_ok_and(|v| v == "1"),
            near: s.near,
            near_parse: s.near && !std::env::var("LLZ_NEAR_PARSE").is_ok_and(|v| v == "0"),
            flag_price: [[0; 2]; STATES],
            sel_price: [[0; 4]; 4],
            sign_price: [[0; 2]; 4],
            gap_price: [[0; 32]; 4],
            near_floor: 0,
            near_evals: 0,
            normal_matches: 0,
            near_used: 0,
        };
        e.refresh();
        e
    }

    fn refresh(&mut self) {
        self.m.len.fill(&self.pr, &mut self.len_prices);
        self.m.rep_len.fill(&self.pr, &mut self.rep_len_prices);
        // 混合長さの行は次に使うときに作り直す。分割案の先頭はここで作る。
        self.gen_no = self.gen_no.wrapping_add(1).max(1);
        if self.var.order == 2
            && let Some(lm) = self.m.lm.as_ref()
        {
            for ps in 0..POS_STATES {
                self.hp[ps] = lm.head_prices(tables(), ps, DC_HEAD);
            }
        }
        for ls in 0..self.var.slot_rows() {
            for s in 0..64u32 {
                let mut p = self.pr.tree(&self.m.pos_slot[ls], 6, s);
                if s as usize >= END_POS_MODEL {
                    p += ((s >> 1) - 1 - 4) * BIT_PRICE;
                }
                self.slot_prices[ls][s as usize] = p;
            }
            for d in 0..FULL_DISTANCES as u32 {
                let s = pos_slot(d);
                let mut p = self.slot_prices[ls][s as usize];
                if s >= 4 {
                    let footer = (s >> 1) - 1;
                    let base = (2 | (s & 1)) << footer;
                    p += self.pr.reverse(
                        &self.m.pos_special[(base - s) as usize..],
                        footer,
                        d - base,
                    );
                }
                self.dist_prices[ls][d as usize] = p;
            }
        }
        for i in 0..16 {
            self.align_prices[i] = self.pr.reverse(&self.m.align, 4, i as u32);
        }
        if self.near {
            self.refresh_near();
        }
        self.since_refresh = 0;
    }

    /// 近傍距離の価格表を作る。
    fn refresh_near(&mut self) {
        let pr = &self.pr;
        let m = &self.m;
        for st in 0..STATES {
            self.flag_price[st] = [pr.bit(m.near_flag[st], 0), pr.bit(m.near_flag[st], 1)];
        }
        for ls in 0..4 {
            for i in 0..4 {
                self.sel_price[ls][i] = pr.tree(&m.near_sel[ls], 2, i as u32);
            }
        }
        for i in 0..4 {
            self.sign_price[i] = [pr.bit(m.near_sign[i], 0), pr.bit(m.near_sign[i], 1)];
            for gs in 0..32u32 {
                let mut p = pr.tree(&m.near_gap[i], 5, gs);
                if gs >= 4 {
                    p += ((gs >> 1) - 1) * BIT_PRICE;
                }
                self.gap_price[i][gs as usize] = p;
            }
        }
        // rep 番号ごとの最小値の和の最小。どの組合せの価格もこれ以上になる。
        self.near_floor = (0..4)
            .map(|i| {
                let sel = (0..4).map(|ls| self.sel_price[ls][i]).min().unwrap_or(0);
                let sign = self.sign_price[i][0].min(self.sign_price[i][1]);
                let gap = self.gap_price[i].iter().copied().min().unwrap_or(0);
                sel + sign + gap
            })
            .min()
            .unwrap_or(0);
    }

    #[inline(always)]
    fn dist_price(&self, dist: u32, len: usize) -> u32 {
        let row = if self.var.wide_slot != 0 {
            len_wide(len)
        } else {
            (len - 2).min(3)
        };
        self.dist_price_ls(dist, row)
    }

    /// 混合長さの価格表の行 (ps, dc) の先頭位置。古ければ主入力の counter から作り直す。
    #[inline(always)]
    fn lrow(&mut self, ps: usize, dc: usize) -> usize {
        let r = ps * NDC + dc;
        if self.lp_gen[r] != self.gen_no {
            self.lp_gen[r] = self.gen_no;
            if let Some(lm) = self.m.lm.as_ref() {
                lm.fill_row(tables(), ps, dc, &mut self.lp[r * LP_ROW..(r + 1) * LP_ROW]);
            }
        }
        r * LP_ROW
    }

    /// rep 一致（番号 i）の長さ l の価格。
    #[inline(always)]
    fn rep_lp(&mut self, ps: usize, i: usize, l: usize) -> u32 {
        if self.var.rep_new != 0 {
            let r = self.lrow(ps, DC_REP + i);
            self.lp[r + l - 2]
        } else {
            self.rep_len_prices[ps][l - 2]
        }
    }

    /// 長さ混合の文脈（ps, dc, kind は呼び出し側、pl と state はこの encoder の値）。
    #[inline(always)]
    fn lctx(&self, ps: usize, dc: usize, kind: usize, st: usize) -> LenCtx {
        LenCtx {
            ps,
            dc,
            kind,
            pl: pl_class(self.prev_len),
            st,
        }
    }

    /// parse 用：通常一致（距離 dist）の、長さに依らない部分の価格を前計算する。
    fn match_costs(&mut self, st: usize, ps: usize, dist: u32, r: &[u32; 4]) -> MatchCost {
        let mut mc = MatchCost {
            st,
            dist,
            nc: [INF; 4],
            far: 0,
            near: INF,
            row_far: 0,
            row_near: 0,
        };
        let f0 = if self.near_parse {
            self.flag_price[st][0]
        } else {
            0
        };
        match self.var.order {
            0 => {
                mc.nc = self.near_costs(st, dist, r);
                if self.m.lm.is_some() {
                    mc.far = f0;
                    mc.row_far = self.lrow(ps, 0);
                    mc.row_near = self.lrow(ps, DC_NEAR);
                }
            }
            1 => {
                let sc = state_class(st, self.var.sctx);
                mc.far = f0 + self.dist_price_ls(dist, sc);
                let slot = pos_slot(dist) as usize;
                mc.row_far = self.lrow(ps, slot / 6);
                if let Some((p, i)) = self.near_best(st, dist, r, sc) {
                    mc.near = p;
                    mc.row_near = self.lrow(ps, DC_NEAR + i);
                }
            }
            _ => {
                mc.nc = self.near_costs(st, dist, r);
                mc.far = f0;
                let slot = pos_slot(dist) as usize;
                mc.row_far = self.lrow(ps, slot / 6);
                if let Some((_, i)) = self.near_best(st, dist, r, 3) {
                    mc.row_near = self.lrow(ps, DC_NEAR + i);
                }
            }
        }
        mc
    }

    /// parse 用：通常一致の長さ l の価格（長さ＋距離、is_match・is_rep は含まない）。
    #[inline(always)]
    fn match_price(&self, mc: &MatchCost, ps: usize, l: usize) -> u32 {
        match self.var.order {
            0 => {
                if self.m.lm.is_none() {
                    return self.len_prices[ps][l - 2] + self.dist_cost(mc.st, mc.dist, l, &mc.nc);
                }
                if self.diag_lzprice {
                    // 診断：長さの価格だけ LZMA の model（符号化には使わず更新だけする）から取る。
                    return self.len_prices[ps][l - 2] + self.dist_cost(mc.st, mc.dist, l, &mc.nc);
                }
                let far = mc.far + self.dist_price(mc.dist, l) + self.lp[mc.row_far + l - 2];
                let near = mc.nc[(l - 2).min(3)].saturating_add(self.lp[mc.row_near + l - 2]);
                far.min(near)
            }
            1 => {
                let far = mc.far + self.lp[mc.row_far + l - 2];
                let near = mc.near.saturating_add(self.lp[mc.row_near + l - 2]);
                far.min(near)
            }
            _ => {
                let ls = (l - 2).min(3);
                let (tf, tn) = if ls == 3 {
                    (self.lp[mc.row_far + l - 5], self.lp[mc.row_near + l - 5])
                } else {
                    (0, 0)
                };
                let far = mc.far + self.dist_price_ls(mc.dist, ls) + tf;
                let near = mc.nc[ls].saturating_add(tn);
                self.hp[ps][ls] + far.min(near)
            }
        }
    }

    /// 近傍で書く場合の最良（flag 込みの価格、番号）。sel の文脈は ctx。使えなければ None。
    fn near_best(&self, st: usize, dist: u32, r: &[u32; 4], ctx: usize) -> Option<(u32, usize)> {
        if !self.near || r.contains(&dist) {
            return None;
        }
        let mut best: Option<(u32, usize)> = None;
        for i in 0..4 {
            if r[..i].contains(&r[i]) {
                continue;
            }
            let d = dist.abs_diff(r[i]);
            if d > NEAR_MAX_DIFF {
                continue;
            }
            let p = self.sel_price[ctx][i]
                + self.sign_price[i][(dist < r[i]) as usize]
                + self.gap_price[i][pos_slot(d - 1) as usize];
            if best.is_none_or(|b| p < b.0) {
                best = Some((p, i));
            }
        }
        best.map(|(p, i)| (p + self.flag_price[st][1], i))
    }

    /// 長さの文脈 ls（min(長さ-2, 3)）での、通常の距離符号の価格。
    #[inline(always)]
    fn dist_price_ls(&self, dist: u32, ls: usize) -> u32 {
        if (dist as usize) < FULL_DISTANCES {
            self.dist_prices[ls][dist as usize]
        } else {
            self.slot_prices[ls][pos_slot(dist) as usize] + self.align_prices[(dist & 15) as usize]
        }
    }

    /// 距離 dist（0始まり）の通常一致を近傍で書くか決める（emit 用）。
    /// r は更新前の rep 距離、st は更新前の state。同価格は小さい i、近傍が厳密に安いときだけ採る。
    fn near_code(&self, dist: u32, r: &[u32; 4], len: usize, st: usize) -> Option<NearCode> {
        // 規則B：rep と等しい距離は rep 記号で書くので近傍にしない。
        if r.contains(&dist) {
            return None;
        }
        let ls = (len - 2).min(3);
        let mut best: Option<(u32, NearCode)> = None;
        for i in 0..4 {
            // 規則A：同じ距離の rep が先にある番号は選べない。
            if r[..i].contains(&r[i]) {
                continue;
            }
            let d = dist.abs_diff(r[i]);
            if d > NEAR_MAX_DIFF {
                continue;
            }
            let neg = dist < r[i];
            let g = d - 1;
            let p = self.sel_price[ls][i]
                + self.sign_price[i][neg as usize]
                + self.gap_price[i][pos_slot(g) as usize];
            if best.is_none_or(|b| p < b.0) {
                best = Some((p, NearCode { i, neg, g }));
            }
        }
        let (p, code) = best?;
        (self.flag_price[st][1] + p < self.flag_price[st][0] + self.dist_price(dist, len))
            .then_some(code)
    }

    /// parse 用：距離 dist の通常一致を近傍で書く場合の価格（flag 込み）を長さの文脈 ls ごとに返す。
    /// 使えない（規則A・B・差の上限）なら INF。近傍が通常の価格に届かないと分かる場合は計算を省いて INF のまま
    /// （最小を取る用途なので結果は変わらない）。r は更新前の rep 距離、st は更新前の state。
    fn near_costs(&mut self, st: usize, dist: u32, r: &[u32; 4]) -> [u32; 4] {
        let mut out = [INF; 4];
        if !self.near_parse || r.contains(&dist) {
            return out;
        }
        let f1 = self.flag_price[st][1];
        let f0 = self.flag_price[st][0];
        let floor = f1 + self.near_floor;
        // 通常側の価格の行は、slot の文脈が長さ8区分（--wide 1）なら 8 行すべてを見る（製品の dist_parts は
        // 省略を持たない厳密な最小なので、試作の省略が一部の行で外れると parse が分かれてしまう）。
        if (0..self.var.slot_rows()).all(|ls| floor >= f0 + self.dist_price_ls(dist, ls)) {
            return out;
        }
        self.near_evals += 1;
        // rep 番号ごとの sign+gap（使えない番号は INF）。
        let mut np = [INF; 4];
        for i in 0..4 {
            if r[..i].contains(&r[i]) {
                continue;
            }
            let d = dist.abs_diff(r[i]);
            if d > NEAR_MAX_DIFF {
                continue;
            }
            np[i] = self.sign_price[i][(dist < r[i]) as usize]
                + self.gap_price[i][pos_slot(d - 1) as usize];
        }
        for (ls, o) in out.iter_mut().enumerate() {
            let best = (0..4)
                .map(|i| np[i] + self.sel_price[ls][i])
                .min()
                .unwrap_or(INF);
            if best < INF {
                *o = f1 + best;
            }
        }
        out
    }

    /// parse 用：通常一致の距離部分の価格。近傍を使わない場合は flag の通常側の価格を足す。
    #[inline(always)]
    fn dist_cost(&self, st: usize, dist: u32, len: usize, nc: &[u32; 4]) -> u32 {
        let far = self.dist_price(dist, len)
            + if self.near_parse {
                self.flag_price[st][0]
            } else {
                0
            };
        far.min(nc[(len - 2).min(3)])
    }

    #[inline(always)]
    fn rep_price(&self, i: usize, state: usize, ps: usize) -> u32 {
        let pr = &self.pr;
        let m = &self.m;
        match i {
            0 => pr.bit(m.g0[state], 0) + pr.bit(m.rep0_long[state * POS_STATES + ps], 1),
            1 => pr.bit(m.g0[state], 1) + pr.bit(m.g1[state], 0),
            2 => pr.bit(m.g0[state], 1) + pr.bit(m.g1[state], 1) + pr.bit(m.g2[state], 0),
            _ => pr.bit(m.g0[state], 1) + pr.bit(m.g1[state], 1) + pr.bit(m.g2[state], 1),
        }
    }

    #[inline(always)]
    fn short_price(&self, state: usize, ps: usize) -> u32 {
        self.pr.bit(self.m.g0[state], 0) + self.pr.bit(self.m.rep0_long[state * POS_STATES + ps], 0)
    }

    /// pos の byte を、state（7以上なら一致byte文脈）で literal として送る価格。
    #[inline(always)]
    fn lit_price(&self, pos: usize, state: usize, match_byte: Option<u8>) -> u32 {
        let byte = self.data[pos] as u32;
        // 試作の literal 混合でも、parse の価格は LZMA の確率（符号化側で更新し続ける）で近似する。
        let probs = &self.m.literal[lit_base(self.prev_byte(pos), self.m.lc)..];
        let Some(match_byte) = match_byte.filter(|_| state >= 7) else {
            return self.pr.tree(probs, 8, byte);
        };
        let mut price = 0;
        let mut ctx = 1usize;
        let mut matching = true;
        for i in (0..8).rev() {
            let bit = (byte >> i) & 1;
            if matching {
                let mbit = ((match_byte >> i) & 1) as usize;
                price += self.pr.bit(probs[((1 + mbit) << 8) + ctx], bit);
                matching = mbit as u32 == bit;
            } else {
                price += self.pr.bit(probs[ctx], bit);
            }
            ctx = (ctx << 1) | bit as usize;
        }
        price
    }

    /// literal 文脈の直前 byte（segment 先頭では 0）。
    #[inline(always)]
    fn prev_byte(&self, pos: usize) -> u8 {
        if pos > self.scope.seg_start {
            self.data[pos - 1]
        } else {
            0
        }
    }

    /// pos から距離 rep+1 で写せる最大長（規則で使えなければ 0）。
    #[inline(always)]
    fn room(&self, pos: usize, rep: u32) -> usize {
        let r = rep as usize;
        if r >= pos {
            return 0;
        }
        self.scope.clip(pos, pos - r - 1, usize::MAX)
    }

    /// 一致byte文脈に使える byte（読めない参照元なら None）。
    #[inline(always)]
    fn match_byte(&self, pos: usize, rep: u32) -> Option<u8> {
        (self.room(pos, rep) > 0).then(|| self.data[pos - rep as usize - 1])
    }

    fn rep_len_at(&self, pos: usize, rep: u32, limit: usize) -> usize {
        let room = self.room(pos, rep);
        if room == 0 {
            return 0;
        }
        common(
            self.data,
            pos - rep as usize - 1,
            &self.data[pos..],
            0,
            limit.min(room),
        )
    }

    /// 全体を符号化する。segment が全体なら `.lzma` 単体形式、そうでなければ segment 容器を返す。
    /// segment ごとに model・state・rep 履歴・range 符号器を初期化する。一致探索の索引は全体で1つ。
    pub fn encode(mut self, window: usize) -> Vec<u8> {
        let n = self.data.len();
        let mut bodies = Vec::new();
        let mut seg_start = 0usize;
        while seg_start < n || bodies.is_empty() {
            let scope = segment_scope(n, self.segment, self.wave, seg_start / self.segment);
            bodies.push(self.encode_segment(scope));
            seg_start = scope.end;
        }
        assemble(
            n,
            self.segment,
            self.wave,
            window,
            self.near,
            &self.var,
            bodies,
        )
    }

    /// 1 segment を初期状態の model から符号化し、range 符号の body を返す。
    /// 一致探索器は segment の先頭から順に呼ぶ（逐次の BT4 ではそれ以前の位置が索引済みであること）。
    pub fn encode_segment(&mut self, scope: Scope) -> Vec<u8> {
        self.scope = scope;
        self.m = Model::new(&self.var);
        self.prev_len = 2;
        self.state = 0;
        self.reps = [0; 4];
        self.cached = None;
        self.refresh();
        if std::env::var("LLZ_SHADOW").is_ok_and(|v| v == "1") {
            self.shadow = Some(Box::new(Shadow::new()));
        }
        if std::env::var("LLZ_SHADOW2").is_ok_and(|v| v == "1") {
            self.shadow2 = Some(Box::new(MatchShadow::new()));
        }
        let mut pos = scope.seg_start;
        while pos < scope.end {
            if self.since_refresh >= self.refresh_every {
                self.refresh();
            }
            self.optimum(pos);
            let path = std::mem::take(&mut self.path);
            for &(len, back) in &path {
                self.emit(pos, len as usize, back);
                pos += len as usize;
            }
            self.path = path;
        }
        let mut rc = std::mem::replace(
            &mut self.rc,
            RangeEnc::new((scope.end - scope.seg_start) / 3 + 64),
        );
        if let Some(st) = rc.stats.take() {
            add_stats(&st);
        }
        use std::sync::atomic::Ordering::Relaxed;
        NEAR_EVALS.fetch_add(std::mem::take(&mut self.near_evals), Relaxed);
        NORMAL_MATCHES.fetch_add(std::mem::take(&mut self.normal_matches), Relaxed);
        NEAR_USED.fetch_add(std::mem::take(&mut self.near_used), Relaxed);
        if let Some(sh) = self.shadow.take()
            && let Ok(mut b) = SHADOW_BITS.lock()
        {
            *b += sh.bits;
        }
        if let Some(sh) = self.shadow2.take()
            && let Ok(mut all) = SHADOW2.lock()
        {
            for (name, v) in sh.report() {
                if let Some(e) = all.iter_mut().find(|e| e.0 == name) {
                    e.1 += v;
                } else {
                    all.push((name, v));
                }
            }
        }
        rc.finish()
    }

    fn emit(&mut self, pos: usize, len: usize, back: u32) {
        let ps = pos & PB_MASK;
        let st = self.state;
        self.since_refresh += 1;
        self.rc.cat = 0;
        if back == LIT {
            self.rc.bit(&mut self.m.is_match[st * POS_STATES + ps], 0);
            let byte = self.data[pos] as u32;
            let base = lit_base(self.prev_byte(pos), LC);
            let mb = self.match_byte(pos, self.reps[0]).filter(|_| st >= 7);
            let mut matching = mb.is_some();
            self.rc.cat = if matching { 2 } else { 1 };
            if self.shadow.is_some() {
                let prev1 = self.prev_byte(pos);
                let prev2 = if pos > self.scope.seg_start + 1 {
                    self.data[pos - 2]
                } else {
                    0
                };
                if let Some(sh) = self.shadow.as_mut() {
                    sh.literal(prev1, prev2, mb, byte as u8);
                }
            }
            if self.m.lx.is_some() || self.m.lc != LC {
                // literal の試作（混合・lc=8・hash 単一文脈）。
                let prev1 = self.prev_byte(pos);
                let prev2 = if pos > self.scope.seg_start + 1 {
                    self.data[pos - 2]
                } else {
                    0
                };
                let rc = &mut self.rc;
                let mut i = 8u32;
                lit_code(&mut self.m, prev1, prev2, mb, true, |q, p12| {
                    i -= 1;
                    let bit = (byte >> i) & 1;
                    if p12 == 0 {
                        rc.bit(q, bit);
                    } else {
                        rc.bit12(p12, bit);
                    }
                    bit
                });
                self.state = lit_next(st);
                return;
            }
            let match_byte = mb.unwrap_or(0) as u32;
            let probs = &mut self.m.literal[base..base + LIT_SIZE];
            let mut ctx = 1usize;
            for i in (0..8).rev() {
                let bit = (byte >> i) & 1;
                if matching {
                    let mbit = ((match_byte >> i) & 1) as usize;
                    self.rc.bit(&mut probs[((1 + mbit) << 8) + ctx], bit);
                    matching = mbit as u32 == bit;
                } else {
                    self.rc.bit(&mut probs[ctx], bit);
                }
                ctx = (ctx << 1) | bit as usize;
            }
            self.state = lit_next(st);
            return;
        }
        self.rc.bit(&mut self.m.is_match[st * POS_STATES + ps], 1);
        self.rc.cat = 3;
        if back < 4 {
            self.rc.bit(&mut self.m.is_rep[st], 1);
            if back == 0 {
                self.rc.bit(&mut self.m.g0[st], 0);
                if len == 1 {
                    self.rc.bit(&mut self.m.rep0_long[st * POS_STATES + ps], 0);
                    self.state = short_next(st);
                    return;
                }
                self.rc.bit(&mut self.m.rep0_long[st * POS_STATES + ps], 1);
            } else {
                self.rc.bit(&mut self.m.g0[st], 1);
                if back == 1 {
                    self.rc.bit(&mut self.m.g1[st], 0);
                } else {
                    self.rc.bit(&mut self.m.g1[st], 1);
                    self.rc.bit(&mut self.m.g2[st], (back == 3) as u32);
                }
                let b = back as usize;
                let r = self.reps[b];
                for j in (1..=b).rev() {
                    self.reps[j] = self.reps[j - 1];
                }
                self.reps[0] = r;
            }
            self.rc.cat = 4;
            if let Some(sh) = self.shadow2.as_mut() {
                sh.rep(len);
            }
            if self.var.rep_new != 0 {
                let c = self.lctx(ps, DC_REP + back as usize, 2, st);
                if let Some(lm) = self.m.lm.as_mut() {
                    lm.encode(tables(), &mut self.rc, &c, len as u32 - 2);
                }
            } else {
                self.m.rep_len.encode(&mut self.rc, len as u32 - 2, ps);
            }
            self.prev_len = len;
            self.state = rep_next(st);
            return;
        }
        self.rc.bit(&mut self.m.is_rep[st], 0);
        let dist = back - 4;
        let old = self.reps;
        // 近傍で書くかは emit が決める（parse の価格が近傍を見込んでいてもいなくても同じ規則）。
        let nc = if !self.near {
            None
        } else if self.var.order == 0 && self.m.lm.is_none() {
            self.near_code(dist, &old, len, st)
        } else {
            self.near_code_var(dist, &old, len, st, ps)
        };
        self.normal_matches += 1;
        if self.shadow2.is_some() {
            let cur = self.dist_price(dist, len) as f64 / BIT_PRICE as f64;
            let reps = self.reps;
            if let Some(sh) = self.shadow2.as_mut() {
                sh.matched(pos, st, ps, len, dist, reps, cur);
            }
        }
        if self.near {
            self.rc.cat = 6;
            self.rc.bit(&mut self.m.near_flag[st], nc.is_some() as u32);
        }
        if self.var.order != 0 {
            self.emit_reordered(len, dist, st, ps, nc);
            self.prev_len = len;
            return;
        }
        self.rc.cat = 5;
        if self.m.lm.is_some() {
            // V4：順序は今のまま、長さを混合で送る。
            let c = self.lctx(
                ps,
                if nc.is_some() { DC_NEAR } else { 0 },
                nc.is_some() as usize,
                st,
            );
            if let Some(lm) = self.m.lm.as_mut() {
                lm.encode(tables(), &mut self.rc, &c, len as u32 - 2);
            }
            if self.diag_lzprice {
                let mut sink = RangeEnc::new(0);
                self.m.len.encode(&mut sink, len as u32 - 2, ps);
            }
        } else {
            self.m.len.encode(&mut self.rc, len as u32 - 2, ps);
        }
        self.prev_len = len;
        let ls = (len - 2).min(3);
        let row = if self.var.wide_slot != 0 {
            len_wide(len)
        } else {
            ls
        };
        if let Some(c) = nc {
            // 近傍：どの rep か、向き、差-1 の slot と、slot 4 以上の下位 bit（平坦）。
            self.near_used += 1;
            self.rc.cat = 6;
            self.rc.tree(&mut self.m.near_sel[ls], 2, c.i as u32);
            self.rc.bit(&mut self.m.near_sign[c.i], c.neg as u32);
            let gs = pos_slot(c.g);
            self.rc.tree(&mut self.m.near_gap[c.i], 5, gs);
            if gs >= 4 {
                let footer = (gs >> 1) - 1;
                self.rc.cat = 8;
                self.rc.direct(c.g - ((2 | (gs & 1)) << footer), footer);
            }
            self.reps = [dist, old[0], old[1], old[2]];
            self.state = match_next(st);
            return;
        }
        self.put_far(dist, row);
        self.reps = [dist, self.reps[0], self.reps[1], self.reps[2]];
        self.state = match_next(st);
    }

    /// 近傍の距離符号（番号 i、向き、差-1）を送る。sel の文脈は ctx。
    fn put_near(&mut self, c: NearCode, ctx: usize) {
        self.near_used += 1;
        self.rc.cat = 6;
        self.rc.tree(&mut self.m.near_sel[ctx], 2, c.i as u32);
        self.rc.bit(&mut self.m.near_sign[c.i], c.neg as u32);
        let gs = pos_slot(c.g);
        self.rc.tree(&mut self.m.near_gap[c.i], 5, gs);
        if gs >= 4 {
            let footer = (gs >> 1) - 1;
            self.rc.cat = 8;
            self.rc.direct(c.g - ((2 | (gs & 1)) << footer), footer);
        }
    }

    /// order 1/2 の通常一致（flag の後）：距離（と長さ区分）と長さを送り、rep・state を更新する。
    fn emit_reordered(
        &mut self,
        len: usize,
        dist: u32,
        st: usize,
        ps: usize,
        nc: Option<NearCode>,
    ) {
        let old = self.reps;
        let kind = nc.is_some() as usize;
        let ls = (len - 2).min(3);
        let mut c = self.lctx(ps, DC_HEAD, kind, st);
        let tb = tables();
        let ctx = if self.var.order == 2 {
            self.rc.cat = 5;
            if let Some(lm) = self.m.lm.as_mut() {
                lm.encode_head(tb, &mut self.rc, &c, ls as u32);
            }
            ls
        } else {
            state_class(st, self.var.sctx)
        };
        c.dc = match nc {
            Some(code) => {
                self.put_near(code, ctx);
                DC_NEAR + code.i
            }
            None => {
                self.put_far(dist, ctx);
                pos_slot(dist) as usize / 6
            }
        };
        self.rc.cat = 5;
        if let Some(lm) = self.m.lm.as_mut() {
            if self.var.order == 1 {
                lm.encode(tb, &mut self.rc, &c, len as u32 - 2);
            } else if ls == 3 {
                lm.encode(tb, &mut self.rc, &c, len as u32 - 5);
            }
        }
        self.reps = [dist, old[0], old[1], old[2]];
        self.state = match_next(st);
    }

    /// 案ごとの価格で、通常一致を近傍で書くか決める（emit 用、長さの価格の差も含める）。
    fn near_code_var(
        &mut self,
        dist: u32,
        r: &[u32; 4],
        len: usize,
        st: usize,
        ps: usize,
    ) -> Option<NearCode> {
        if r.contains(&dist) {
            return None;
        }
        let ls = (len - 2).min(3);
        let order = self.var.order;
        // 長さ（と距離区分）に依る部分の価格。v は長さ表の添字。
        let (sel_ctx, v) = match order {
            0 => (ls, len - 2),
            1 => (state_class(st, self.var.sctx), len - 2),
            _ => (ls, len.saturating_sub(5)),
        };
        let use_len = order != 2 || ls == 3;
        let far_dist = match order {
            0 => self.dist_price(dist, len),
            1 => self.dist_price_ls(dist, sel_ctx),
            _ => self.dist_price_ls(dist, ls),
        };
        let row_far = match order {
            0 => self.lrow(ps, 0),
            _ => self.lrow(ps, pos_slot(dist) as usize / 6),
        };
        let lf = if use_len { self.lp[row_far + v] } else { 0 };
        let far = self.flag_price[st][0] + far_dist + lf;
        let mut best: Option<(u32, NearCode)> = None;
        for i in 0..4 {
            if r[..i].contains(&r[i]) {
                continue;
            }
            let d = dist.abs_diff(r[i]);
            if d > NEAR_MAX_DIFF {
                continue;
            }
            let neg = dist < r[i];
            let g = d - 1;
            let row = self.lrow(ps, if order == 0 { DC_NEAR } else { DC_NEAR + i });
            let ln = if use_len { self.lp[row + v] } else { 0 };
            let p = self.sel_price[sel_ctx][i]
                + self.sign_price[i][neg as usize]
                + self.gap_price[i][pos_slot(g) as usize]
                + ln;
            if best.is_none_or(|b| p < b.0) {
                best = Some((p, NearCode { i, neg, g }));
            }
        }
        let (p, code) = best?;
        (self.flag_price[st][1] + p < far).then_some(code)
    }

    /// 通常の距離符号（slot、下位 bit、align）を送る。slot の文脈は row。
    fn put_far(&mut self, dist: u32, row: usize) {
        let slot = pos_slot(dist);
        self.rc.cat = 6;
        self.rc.tree(&mut self.m.pos_slot[row], 6, slot);
        if slot >= 4 {
            let footer = (slot >> 1) - 1;
            let base = (2 | (slot & 1)) << footer;
            let reduced = dist - base;
            if (slot as usize) < END_POS_MODEL {
                self.rc.cat = 7;
                self.rc.reverse(
                    &mut self.m.pos_special[(base - slot) as usize..],
                    footer,
                    reduced,
                );
            } else {
                self.rc.cat = 8;
                self.rc.direct(reduced >> 4, footer - 4);
                self.rc.cat = 9;
                self.rc.reverse(&mut self.m.align, 4, reduced & 15);
            }
        }
    }

    /// pos からの記号列を価格つきの最短路で決め、self.path に前から順に入れる。
    /// pos 以降で一致を求めた位置はすべて索引へ挿入済みにする。
    fn optimum(&mut self, pos: usize) {
        self.path.clear();
        let data = self.data;
        let n = self.scope.end;
        if self.cached != Some(pos) {
            self.mf.find(data, pos, &self.scope, &mut self.first);
        } else {
            std::mem::swap(&mut self.first, &mut self.cur_matches);
        }
        self.cached = None;
        let avail = n - pos;
        if avail < 2 {
            self.path.push((1, LIT));
            return;
        }
        let limit = avail.min(MAX_LEN);
        let main_len = self.first.last().map_or(0, |m| m.len as usize);
        let mut rep_lens = [0usize; 4];
        let mut rep_max = 0usize;
        for i in 0..4 {
            rep_lens[i] = self.rep_len_at(pos, self.reps[i], limit);
            if rep_lens[i] > rep_lens[rep_max] {
                rep_max = i;
            }
        }
        if rep_lens[rep_max] >= self.nice {
            let len = rep_lens[rep_max];
            self.path.push((len as u32, rep_max as u32));
            self.skip(pos + 1, pos + len);
            return;
        }
        if main_len >= self.nice {
            let m = *self.first.last().unwrap();
            self.path.push((m.len, m.dist + 4));
            self.skip(pos + 1, pos + m.len as usize);
            return;
        }
        let state = self.state;
        let reps = self.reps;
        let cur_byte = data[pos];
        let match_byte = self.match_byte(pos, reps[0]);
        if main_len < 2 && match_byte != Some(cur_byte) && rep_lens[rep_max] < 2 {
            self.path.push((1, LIT));
            return;
        }
        let ps = pos & PB_MASK;
        let pr = &self.pr;
        self.opts[0] = Opt {
            price: 0,
            pos_prev: 0,
            back: LIT,
            state: state as u8,
            reps,
            combo: 0,
            pos_prev2: 0,
            back_prev2: 0,
        };
        self.opts[1] = Opt {
            price: pr.bit(self.m.is_match[state * POS_STATES + ps], 0)
                + self.lit_price(pos, state, match_byte),
            pos_prev: 0,
            back: LIT,
            state: 0,
            reps,
            combo: 0,
            pos_prev2: 0,
            back_prev2: 0,
        };
        let match_price = pr.bit(self.m.is_match[state * POS_STATES + ps], 1);
        let rep_match_price = match_price + pr.bit(self.m.is_rep[state], 1);
        if match_byte == Some(cur_byte) {
            let p = rep_match_price + self.short_price(state, ps);
            if p < self.opts[1].price {
                self.opts[1].price = p;
                self.opts[1].back = 0;
            }
        }
        let mut len_end = main_len.max(rep_lens[rep_max]);
        if len_end < 2 {
            self.path.push((1, self.opts[1].back));
            return;
        }
        for l in 2..=len_end {
            self.opts[l].price = INF;
        }
        for (i, &rl) in rep_lens.iter().enumerate() {
            if rl < 2 {
                continue;
            }
            let base = rep_match_price + self.rep_price(i, state, ps);
            for l in 2..=rl {
                let p = base + self.rep_lp(ps, i, l);
                if p < self.opts[l].price {
                    self.set(l, p, 0, i as u32);
                }
            }
        }
        let normal = match_price + self.pr.bit(self.m.is_rep[state], 0);
        let start = if rep_lens[0] >= 2 { rep_lens[0] + 1 } else { 2 };
        if start <= main_len {
            let mut k = 0;
            while (self.first[k].len as usize) < start {
                k += 1;
            }
            let mut mc = self.match_costs(state, ps, self.first[k].dist, &reps);
            for l in start..=main_len {
                let m = self.first[k];
                let p = normal + self.match_price(&mc, ps, l);
                if p < self.opts[l].price {
                    self.set(l, p, 0, m.dist + 4);
                }
                if l == m.len as usize {
                    k += 1;
                    if l < main_len {
                        mc = self.match_costs(state, ps, self.first[k].dist, &reps);
                    }
                }
            }
        }

        let mut cur = 0usize;
        OPTIMUM_CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        loop {
            cur += 1;
            DP_NODES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if cur == len_end {
                break;
            }
            // cur へ至る最良路から state と rep 履歴を決める。
            let o = self.opts[cur];
            let prev = o.pos_prev as usize;
            let mut st;
            let mut r;
            if o.combo != 0 {
                // [前の記号] → literal → rep0。rep0 は rep 履歴を変えない。
                if o.combo == 2 {
                    let p2 = o.pos_prev2 as usize;
                    st = self.opts[p2].state as usize;
                    r = self.opts[p2].reps;
                    let b2 = o.back_prev2;
                    if b2 < 4 {
                        st = rep_next(st);
                        let b = b2 as usize;
                        let d = r[b];
                        for j in (1..=b).rev() {
                            r[j] = r[j - 1];
                        }
                        r[0] = d;
                    } else {
                        st = match_next(st);
                        r = [b2 - 4, r[0], r[1], r[2]];
                    }
                } else {
                    st = self.opts[prev - 1].state as usize;
                    r = self.opts[prev - 1].reps;
                }
                st = rep_next(lit_next(st));
            } else {
                st = self.opts[prev].state as usize;
                r = self.opts[prev].reps;
                if o.back == LIT {
                    st = lit_next(st);
                } else if o.back == 0 && prev + 1 == cur {
                    st = short_next(st);
                } else if o.back < 4 {
                    st = rep_next(st);
                    let b = o.back as usize;
                    let d = r[b];
                    for j in (1..=b).rev() {
                        r[j] = r[j - 1];
                    }
                    r[0] = d;
                } else {
                    st = match_next(st);
                    r = [o.back - 4, r[0], r[1], r[2]];
                }
            }
            self.opts[cur].state = st as u8;
            self.opts[cur].reps = r;

            let p = pos + cur;
            self.mf.find(data, p, &self.scope, &mut self.cur_matches);
            let new_len = self.cur_matches.last().map_or(0, |m| m.len as usize);
            if new_len >= self.nice {
                // 長い一致が見つかった位置で区切り、その一致候補は次回へ持ち越す。
                self.cached = Some(p);
                len_end = cur;
                break;
            }
            let cur_price = self.opts[cur].price;
            let ps = p & PB_MASK;
            let cur_byte = data[p];
            let match_byte = self.match_byte(p, r[0]);
            let lit = cur_price
                + self.pr.bit(self.m.is_match[st * POS_STATES + ps], 0)
                + self.lit_price(p, st, match_byte);
            let next_is_lit = lit < self.opts[cur + 1].price;
            if next_is_lit {
                self.set(cur + 1, lit, cur as u32, LIT);
            }
            let match_price = cur_price + self.pr.bit(self.m.is_match[st * POS_STATES + ps], 1);
            let rep_match_price = match_price + self.pr.bit(self.m.is_rep[st], 1);
            if match_byte == Some(cur_byte)
                && !(self.opts[cur + 1].pos_prev as usize == cur && self.opts[cur + 1].back == 0)
            {
                let sp = rep_match_price + self.short_price(st, ps);
                if sp <= self.opts[cur + 1].price {
                    self.set(cur + 1, sp, cur as u32, 0);
                }
            }
            let avail = (n - p).min(OPTS - 1 - cur);
            if avail < 2 {
                continue;
            }
            if self.combos && !next_is_lit && match_byte != Some(cur_byte) {
                // literal の後に rep0 で続く連結記号。
                let l2 = self.tail_rep0(p, r[0], avail);
                if l2 >= 2 {
                    let st2 = lit_next(st);
                    let psn = (p + 1) & PB_MASK;
                    let price = lit
                        + self.pr.bit(self.m.is_match[st2 * POS_STATES + psn], 1)
                        + self.pr.bit(self.m.is_rep[st2], 1)
                        + self.rep0_long_price(l2, st2, psn);
                    let off = cur + 1 + l2;
                    self.extend(&mut len_end, off);
                    if price < self.opts[off].price {
                        self.set_combo(off, price, cur, None);
                    }
                }
            }
            let limit = avail.min(MAX_LEN);
            let mut start_len = 2usize;
            for (i, &rep) in r.iter().enumerate() {
                let rl = self.rep_len_at(p, rep, limit);
                if rl < 2 {
                    continue;
                }
                while len_end < cur + rl {
                    len_end += 1;
                    self.opts[len_end].price = INF;
                }
                let base = rep_match_price + self.rep_price(i, st, ps);
                for l in 2..=rl {
                    let pr = base + self.rep_lp(ps, i, l);
                    if pr < self.opts[cur + l].price {
                        self.set(cur + l, pr, cur as u32, i as u32);
                    }
                }
                if i == 0 {
                    start_len = rl + 1;
                }
                if self.combos && rl + 1 < avail {
                    // rep の後に literal、さらに同じ距離（rep0 になる）で続く連結記号。
                    let l2 = self.tail_rep0(p + rl, rep, avail - rl);
                    if l2 >= 2 {
                        let q = p + rl;
                        let st2 = rep_next(st);
                        let psq = q & PB_MASK;
                        let st3 = lit_next(st2);
                        let psn = (q + 1) & PB_MASK;
                        let price = base
                            + self.rep_lp(ps, i, rl)
                            + self.pr.bit(self.m.is_match[st2 * POS_STATES + psq], 0)
                            + self.lit_price(q, st2, self.match_byte(q, rep))
                            + self.pr.bit(self.m.is_match[st3 * POS_STATES + psn], 1)
                            + self.pr.bit(self.m.is_rep[st3], 1)
                            + self.rep0_long_price(l2, st3, psn);
                        let off = cur + rl + 1 + l2;
                        self.extend(&mut len_end, off);
                        if price < self.opts[off].price {
                            self.set_combo(off, price, cur + rl, Some((cur, i as u32)));
                        }
                    }
                }
            }
            let nl = new_len.min(limit);
            if nl >= start_len {
                let normal = match_price + self.pr.bit(self.m.is_rep[st], 0);
                while len_end < cur + nl {
                    len_end += 1;
                    self.opts[len_end].price = INF;
                }
                let mut k = 0;
                while (self.cur_matches[k].len as usize) < start_len {
                    k += 1;
                }
                let mut mc = self.match_costs(st, ps, self.cur_matches[k].dist, &r);
                LEN_STEPS.fetch_add(
                    (nl + 1 - start_len) as u64,
                    std::sync::atomic::Ordering::Relaxed,
                );
                for l in start_len..=nl {
                    let m = self.cur_matches[k];
                    let pr = normal + self.match_price(&mc, ps, l);
                    if pr < self.opts[cur + l].price {
                        self.set(cur + l, pr, cur as u32, m.dist + 4);
                    }
                    if l == m.len as usize {
                        if self.combos && l + 1 < avail {
                            // 一致の後に literal、さらに同じ距離（rep0 になる）で続く連結記号。
                            let l2 = self.tail_rep0(p + l, m.dist, avail - l);
                            if l2 >= 2 {
                                let q = p + l;
                                let st2 = match_next(st);
                                let psq = q & PB_MASK;
                                let st3 = lit_next(st2);
                                let psn = (q + 1) & PB_MASK;
                                let price = pr
                                    + self.pr.bit(self.m.is_match[st2 * POS_STATES + psq], 0)
                                    + self.lit_price(q, st2, self.match_byte(q, m.dist))
                                    + self.pr.bit(self.m.is_match[st3 * POS_STATES + psn], 1)
                                    + self.pr.bit(self.m.is_rep[st3], 1)
                                    + self.rep0_long_price(l2, st3, psn);
                                let off = cur + l + 1 + l2;
                                self.extend(&mut len_end, off);
                                if price < self.opts[off].price {
                                    self.set_combo(off, price, cur + l, Some((cur, m.dist + 4)));
                                }
                            }
                        }
                        k += 1;
                        if k == self.cur_matches.len() {
                            break;
                        }
                        mc = self.match_costs(st, ps, self.cur_matches[k].dist, &r);
                    }
                }
            }
        }
        // 終点から pos_prev を辿って記号列を復元する。
        let mut c = len_end;
        while c > 0 {
            let o = self.opts[c];
            let prev = o.pos_prev as usize;
            self.path.push(((c - prev) as u32, o.back));
            if o.combo == 0 {
                c = prev;
                continue;
            }
            self.path.push((1, LIT));
            if o.combo == 2 {
                let p2 = o.pos_prev2 as usize;
                self.path.push(((prev - 1 - p2) as u32, o.back_prev2));
                c = p2;
            } else {
                c = prev - 1;
            }
        }
        self.path.reverse();
    }

    /// 先読みの終点を off まで伸ばし、新しい節点を未到達にする。
    #[inline(always)]
    fn extend(&mut self, len_end: &mut usize, off: usize) {
        while *len_end < off {
            *len_end += 1;
            self.opts[*len_end].price = INF;
        }
    }

    /// 単独の記号で節点 i へ至る路を記録する。
    #[inline(always)]
    fn set(&mut self, i: usize, price: u32, pos_prev: u32, back: u32) {
        let o = &mut self.opts[i];
        o.price = price;
        o.pos_prev = pos_prev;
        o.back = back;
        o.combo = 0;
    }

    /// 連結記号（[前の記号] + literal + rep0 長さ len2）で節点 i へ至る路を記録する。
    #[inline(always)]
    fn set_combo(&mut self, i: usize, price: u32, lit_at: usize, prev2: Option<(usize, u32)>) {
        let o = &mut self.opts[i];
        o.price = price;
        o.pos_prev = lit_at as u32 + 1;
        o.back = 0;
        match prev2 {
            Some((p2, b2)) => {
                o.combo = 2;
                o.pos_prev2 = p2 as u32;
                o.back_prev2 = b2;
            }
            None => o.combo = 1,
        }
    }

    /// rep0 を長さ2以上で使う価格（rep 判定の後の部分と長さ）。
    #[inline(always)]
    fn rep0_long_price(&mut self, len: usize, state: usize, ps: usize) -> u32 {
        self.rep_price(0, state, ps) + self.rep_lp(ps, 0, len)
    }

    /// pos の literal の後、rep0（距離 rep+1）で続く一致長（2未満なら0）。limit は literal を含めた残り。
    #[inline(always)]
    fn tail_rep0(&self, pos: usize, rep: u32, limit: usize) -> usize {
        let q = pos + 1;
        let room = if limit < 3 { 0 } else { self.room(q, rep) };
        if room == 0 {
            return 0;
        }
        let l = common(
            self.data,
            q - rep as usize - 1,
            &self.data[q..],
            0,
            (limit - 1).min(self.nice).min(room),
        );
        if l >= 2 { l } else { 0 }
    }

    fn skip(&mut self, from: usize, to: usize) {
        for p in from..to {
            self.mf.skip(self.data, p);
        }
    }
}
