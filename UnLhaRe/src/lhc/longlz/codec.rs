//! 長距離LZ（LLZ1BLK）の本体：LZMA と同じ記号・文脈（lc=3, lp=0, pb=2）の model、逐次復号器、
//! 符号化器と、7-Zip の optimum に倣った価格つき最適parse。
//! 出力は `.lzma` 単体形式（props 0x5D、辞書長、生データ長）で、xz でも展開できる。
//! これにより自前の復号器と独立な実装の両方で、符号化結果の正しさを確かめられる。

use super::mf::{Finder, MAX_LEN, Match, Scope, common};
use super::mix::LitMix;
use super::rc::{BIT_PRICE, Coder, PROB_INIT, Prices, RangeDec, RangeEnc};

const LC: u32 = 3;
const POS_STATES: usize = 4;
const PB_MASK: usize = POS_STATES - 1;
const STATES: usize = 12;
const LIT_SIZE: usize = 0x300;
const FULL_DISTANCES: usize = 128;
const END_POS_MODEL: usize = 14;
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

    fn encode<R: Coder>(&mut self, rc: &mut R, len: u32, ps: usize) {
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
    /// 距離 slot の確率。行 0..4 が min(長さ-2, 3) の文脈（revision 12〜14）。revision 15 は長さ-2 の 8 区分
    /// （`wide_row`）で 8 行すべてを使う。
    pos_slot: [[u16; 64]; 8],
    pos_special: [u16; 1 + FULL_DISTANCES - END_POS_MODEL],
    align: [u16; 16],
    len: LenModel,
    rep_len: LenModel,
    /// literal の混合（revision 15 だけ。revision 12〜14 は None で、LZMA と同じ literal 符号）。
    lit_mix: Option<Box<LitMix>>,
    // 近傍距離符号（frame revision 2 だけが使う。revision 1 では初期値のまま触らない）。
    /// 近傍で書くか（文脈は更新前の state）。
    near_flag: [u16; STATES],
    /// どの rep 距離との差か。文脈は min(長さ-2, 3)、2bit の木。
    near_sel: [[u16; 4]; 4],
    /// 差の符号（負なら 1）。文脈は選んだ rep の番号。
    near_sign: [u16; 4],
    /// 差-1 の slot（5bit の木）。文脈は選んだ rep の番号。
    near_gap: [[u16; 32]; 4],
}

/// 近傍距離で書く一致の符号：選んだ rep の番号、差の向き（負なら true）、差-1。
#[derive(Clone, Copy)]
struct NearCode {
    i: usize,
    neg: bool,
    g: u32,
}

/// 近傍の差（距離と rep 距離の差の絶対値）の上限。差-1 が 16bit（slot 0..31）に収まる範囲。
const NEAR_MAX_DIFF: u32 = 1 << 16;

impl Model {
    /// `lit_mix` は literal の混合（revision 15 の method 2 の復号と、2 本の符号器で書く encoder）を使うか。
    /// slot 文脈の行数は model の大きさに影響しない（常に 8 行を持ち、使う行だけが変わる）。
    fn new(lit_mix: bool) -> Self {
        Self {
            literal: vec![PROB_INIT; LIT_SIZE << LC],
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
            lit_mix: lit_mix.then(|| Box::new(LitMix::new())),
            near_flag: [PROB_INIT; STATES],
            near_sel: [[PROB_INIT; 4]; 4],
            near_sign: [PROB_INIT; 4],
            near_gap: [[PROB_INIT; 32]; 4],
        }
    }
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
fn lit_base(prev: u8) -> usize {
    LIT_SIZE * (prev as usize >> (8 - LC))
}

/// revision 15 の距離 slot の文脈：長さ-2（v）を 8 区分（0、1、2、3、4〜5、6〜9、10〜21、22 以上）にする。
/// 近傍の基準番号（`near_sel`）の文脈は従来どおり min(v, 3) のまま。
#[inline(always)]
fn wide_row(v: usize) -> usize {
    match v {
        0..=3 => v,
        4..=5 => 4,
        6..=9 => 5,
        10..=21 => 6,
        _ => 7,
    }
}

/// 復号に使う履歴（file の byte 位置 start()..end() を読める）。
pub trait Base {
    fn start(&self) -> usize;
    fn end(&self) -> usize;
    /// 位置 s（start() <= s < end()）の byte。
    fn byte(&self, s: usize) -> u8;
    /// 位置 from から len byte を own の末尾へ写す（範囲は呼び出し側で確かめ済み）。
    fn copy_to(&self, own: &mut Vec<u8>, from: usize, len: usize);
}

/// 連続した slice の履歴（試験で使う）。
#[cfg(test)]
pub struct SliceBase<'a> {
    pub data: &'a [u8],
    pub start: usize,
}

#[cfg(test)]
impl Base for SliceBase<'_> {
    fn start(&self) -> usize {
        self.start
    }
    fn end(&self) -> usize {
        self.start + self.data.len()
    }
    #[inline(always)]
    fn byte(&self, s: usize) -> u8 {
        self.data[s - self.start]
    }
    fn copy_to(&self, own: &mut Vec<u8>, from: usize, len: usize) {
        own.extend_from_slice(&self.data[from - self.start..from - self.start + len]);
    }
}

/// 同じ長さ（segment、2 の冪）の block を並べた履歴（並列の復号で使う。64MiB を写して連続にしない）。
/// block i は file の byte 位置 (first + i) << shift から始まる。位置の分解は除算でなく shift と mask で行う。
pub struct BlocksBase<'a, T: AsRef<[u8]>> {
    pub blocks: &'a [T],
    pub first: usize,
    /// segment 長の 2 を底とする対数。
    pub shift: u32,
}

impl<T: AsRef<[u8]>> Base for BlocksBase<'_, T> {
    fn start(&self) -> usize {
        self.first << self.shift
    }
    fn end(&self) -> usize {
        (self.first + self.blocks.len()) << self.shift
    }
    #[inline(always)]
    fn byte(&self, s: usize) -> u8 {
        let i = (s >> self.shift) - self.first;
        self.blocks[i].as_ref()[s & ((1usize << self.shift) - 1)]
    }
    fn copy_to(&self, own: &mut Vec<u8>, from: usize, len: usize) {
        let segment = 1usize << self.shift;
        let mut at = from;
        let end = from + len;
        while at < end {
            let i = (at >> self.shift) - self.first;
            let off = at & (segment - 1);
            let take = (segment - off).min(end - at);
            own.extend_from_slice(&self.blocks[i].as_ref()[off..off + take]);
            at += take;
        }
    }
}

/// 参照元 s から len byte を写してよいか（segment 内、または wave 開始より前で完結する範囲）。
#[inline(always)]
fn source_ok(scope: &Scope, s: usize, len: usize) -> bool {
    s >= scope.seg_start || s + len <= scope.wave_start
}

/// 1 segment（scope.seg_start から scope.end まで）を own へ復号する。
/// base は file の byte 位置 base.start() から wave 開始までの履歴、own はこの segment の出力（空から始める）。
/// 同じ wave の他 segment（wave_start..seg_start）は読まないので、並列に復号できる。
/// 距離は window 未満に限り、base より前（file 先頭より前・保持外）を指す参照は誤りとして拒否する。
/// `NEAR` は frame revision 2 以降（近傍距離符号あり）か。`WIDE` は frame revision 4（距離 slot の文脈が
/// 長さ 8 区分）か。`LITMIX` は frame revision 4 の method 2（literal の混合あり）か。const generic で単相化
/// するので、revision 1〜3 と revision 4 の method 1 の経路は literal の混合の分岐・model を一切持たず、
/// 従来（revision 14）と同じ速度で復号する。
pub fn decode_segment<const NEAR: bool, const WIDE: bool, const LITMIX: bool>(
    body: &[u8],
    base: &impl Base,
    own: &mut Vec<u8>,
    scope: &Scope,
    window: usize,
) -> Result<(), &'static str> {
    let seg = scope.seg_start;
    let base_start = base.start();
    if base.end() != scope.wave_start || base_start > scope.wave_start {
        return Err("LLZ history does not end at the wave start");
    }
    // 窓の中で base が足りない（保持が窓より短い）ときは、その範囲を参照した時点で拒否する。
    let known = true;
    let size = scope.end - seg;
    let mut rc = RangeDec::new(body).map_err(|_| "LLZ range coder header")?;
    let mut m = Model::new(LITMIX);
    let (mut rep0, mut rep1, mut rep2, mut rep3) = (0usize, 0usize, 0usize, 0usize);
    let mut state = 0usize;
    // 絶対位置 s の byte（自 segment なら own、wave より前なら base）。
    let at = |own: &Vec<u8>, s: usize| {
        if s >= seg { own[s - seg] } else { base.byte(s) }
    };
    // 参照元 s から len byte を写せるか（規則・窓・保持範囲のすべて）。
    let usable = |s: usize, len: usize, dist0: usize| {
        dist0 < window && s >= base_start && source_ok(scope, s, len)
    };
    while own.len() < size {
        let pos = seg + own.len();
        let ps = pos & PB_MASK;
        if rc.bit(&mut m.is_match[state * POS_STATES + ps]) == 0 {
            // segment 先頭の直前 byte は他 segment のものなので 0 とみなす。
            let prev = if pos > seg { own[pos - seg - 1] } else { 0 };
            let lb = lit_base(prev);
            // 一致byte文脈は、その byte を読める場合だけ使う（符号化側と同じ規則）。
            let use_match = state >= 7 && rep0 < pos && usable(pos - rep0 - 1, 1, rep0);
            if LITMIX {
                // revision 15 の method 2：LZMA の確率と直前 byte の文脈を混合する（`LitMix` が符号化側と同じ手順で読む）。
                let probs: &mut [u16; LIT_SIZE] = (&mut m.literal[lb..lb + LIT_SIZE])
                    .try_into()
                    .map_err(|_| "LLZ literal table")?;
                let mb = use_match.then(|| at(own, pos - rep0 - 1));
                let lx = m.lit_mix.as_mut().ok_or("LLZ literal mix model")?;
                own.push(lx.decode(probs, &mut rc, prev, mb));
                state = lit_next(state);
                continue;
            }
            let probs = &mut m.literal[lb..lb + LIT_SIZE];
            let mut sym = 1usize;
            if use_match {
                let mut match_byte = at(own, pos - rep0 - 1) as usize;
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
            state = lit_next(state);
            continue;
        }
        let len;
        if rc.bit(&mut m.is_rep[state]) != 0 {
            if pos == 0 {
                return Err("LLZ rep at file start");
            }
            if rc.bit(&mut m.g0[state]) == 0 {
                if rc.bit(&mut m.rep0_long[state * POS_STATES + ps]) == 0 {
                    if rep0 >= pos || !usable(pos - rep0 - 1, 1, rep0) {
                        return Err("LLZ short rep source outside the segment scope");
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
                } else {
                    if rc.bit(&mut m.g2[state]) == 0 {
                        dist = rep2;
                    } else {
                        dist = rep3;
                        rep3 = rep2;
                    }
                    rep2 = rep1;
                }
                rep1 = rep0;
                rep0 = dist;
            }
            len = m.rep_len.decode(&mut rc, ps) as usize;
            state = rep_next(state);
        } else {
            // 近傍 flag の文脈は更新前の state、近傍が基準にする rep も更新前の値なので先に退避する。
            let old = [rep0, rep1, rep2, rep3];
            let use_near = NEAR && rc.bit(&mut m.near_flag[state]) != 0;
            rep3 = rep2;
            rep2 = rep1;
            rep1 = rep0;
            len = m.len.decode(&mut rc, ps) as usize;
            state = match_next(state);
            if use_near {
                let i = rc.tree(&mut m.near_sel[len.min(3)], 2) as usize;
                // 同じ距離の rep が先にある番号は符号化側が選ばない（正規形）。
                if old[..i].contains(&old[i]) {
                    return Err("LLZ non-canonical near selector");
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
                    old[i]
                        .checked_sub(diff)
                        .ok_or("LLZ near distance below zero")?
                } else {
                    old[i] + diff
                };
                // rep と等しい距離は rep 記号で書く（正規形）。
                if old.contains(&dist) {
                    return Err("LLZ near distance equals a rep");
                }
                rep0 = dist;
            } else {
                // len は長さ-2。revision 15 は 8 区分（`wide_row`）、それ以前は min(len, 3)。
                let row = if WIDE { wide_row(len) } else { len.min(3) };
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
                    return Err("LLZ unexpected end marker");
                }
                break;
            }
        }
        let len = len + 2;
        if rep0 >= pos {
            return Err("LLZ distance beyond output");
        }
        if known && own.len() + len > size {
            return Err("LLZ match beyond block size");
        }
        let from = pos - rep0 - 1;
        if !usable(from, len, rep0) {
            return Err("LLZ match source outside the segment scope or window");
        }
        if from < seg {
            // wave より前で完結する参照（usable で保証）は一括で写す。
            base.copy_to(own, from, len);
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
        return Err("LLZ truncated stream");
    }
    Ok(())
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
    /// 近傍距離符号を使う（frame revision 2）。false なら従来（revision 1）と同じ符号になる。
    pub near: bool,
    /// 距離 slot の文脈を長さ 8 区分にする（frame revision 4。near も true であること）。
    pub wide: bool,
    /// literal の混合なし・ありの 2 つの body を 1 回の parse で同時に作る（frame revision 4。wide も true）。
    /// false なら単一の符号器で、literal は LZMA と同じ符号になる（revision 12〜14）。
    pub dual: bool,
}

/// 1 segment の符号化結果。`plain` は literal の混合なしの body、`mix` は 2 本の符号器で書いたときの
/// literal の混合ありの body（同じ記号列）、`literals` は segment の literal の数（診断用）。
pub struct SegOut {
    pub plain: Vec<u8>,
    pub mix: Option<Vec<u8>>,
    pub literals: usize,
}

/// k 番目の segment の範囲と参照規則（segment 長・wave 幅は形式の値）。
pub fn segment_scope(n: usize, segment: usize, wave: usize, k: usize) -> Scope {
    Scope {
        end: ((k + 1) * segment).min(n),
        seg_start: k * segment,
        wave_start: k / wave * wave * segment,
    }
}

pub struct Encoder<'a, F: Finder, R: Coder = RangeEnc> {
    data: &'a [u8],
    m: Model,
    rc: R,
    /// segment の literal の数（診断用）。
    literals: usize,
    pr: Prices,
    mf: F,
    nice: usize,
    state: usize,
    reps: [u32; 4],
    len_prices: Box<[[u32; MAX_LEN - 1]; POS_STATES]>,
    rep_len_prices: Box<[[u32; MAX_LEN - 1]; POS_STATES]>,
    /// 距離 slot・距離の価格。行は slot の文脈（revision 12〜14 は 4 行、revision 15 は 8 行）。
    slot_prices: [[u32; 64]; 8],
    dist_prices: [[u32; FULL_DISTANCES]; 8],
    align_prices: [u32; 16],
    /// 距離 slot の文脈が長さ 8 区分（revision 15）か。parse の価格は LZMA と同じ model で近似する
    /// （literal の価格は LZMA の確率、混合する入力の効果は価格に入れない）。
    wide: bool,
    /// slot の文脈の行数（wide なら 8、そうでなければ 4）。
    rows: usize,
    since_refresh: u32,
    opts: Vec<Opt>,
    first: Vec<Match>,
    cur_matches: Vec<Match>,
    /// 先読みを長い一致で打ち切った位置の一致候補（その位置は索引へ挿入済み）。
    cached: Option<usize>,
    path: Vec<(u32, u32)>,
    scope: Scope,
    /// 近傍距離符号を使う（emit が近傍を選べ、parse の価格にも近傍を入れる）。
    near: bool,
    /// 近傍の価格表（refresh で作る）。flag は文脈 state ごとの [通常, 近傍]、
    /// sel は [長さ文脈][rep 番号]、sign は [rep 番号][負か]、gap は [rep 番号][slot]（footer の平坦 bit 込み）。
    flag_price: [[u32; 2]; STATES],
    sel_price: [[u32; 4]; 4],
    sign_price: [[u32; 2]; 4],
    gap_price: [[u32; 32]; 4],
    /// dist_costs の覚え（価格表を作り直すと memo_epoch を進めて無効にする）。
    dist_memo: Vec<DistMemo>,
    memo_epoch: u32,
    /// tail_rep0 の覚え（続きの位置 q, 距離, 共通長）。segment の始めに空にする（q = usize::MAX）。
    tail_memo: Vec<(usize, u32, u32)>,
}

/// dist_costs の flag を除いた部分の覚え（dist と更新前の rep 距離が同じなら同じ値）。
#[derive(Clone, Copy, Default)]
struct DistMemo {
    epoch: u32,
    dist: u32,
    reps: [u32; 4],
    /// 通常の距離の価格（slot の文脈の行ごと。revision 12〜14 は先頭 4 つだけ使う）。
    normal: [u32; 8],
    /// 近傍で書く場合の sel+sign+gap の最小（基準番号の文脈 min(長さ-2, 3) ごと）。
    near: [u32; 4],
}

/// tail_rep0 の覚えの大きさ（2 の冪の bit 数）。
const TAIL_MEMO_BITS: u32 = 6;

/// dist_costs の覚えの大きさ（2 の冪の bit 数）。
const DIST_MEMO_BITS: u32 = 6;

impl<'a, F: Finder, R: Coder> Encoder<'a, F, R> {
    /// 一致探索器を指定して作る（並列探索の結果を読み出す場合など）。
    pub fn with_finder(data: &'a [u8], s: &Settings, mf: F) -> Self {
        let mut e = Self {
            data,
            m: Model::new(R::DUAL),
            literals: 0,
            // 出力の見込み（segment 単位で符号化するので segment 長を上限に見積もる）。
            rc: R::new(
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
            align_prices: [0; 16],
            wide: s.wide,
            rows: if s.wide { 8 } else { 4 },
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
            near: s.near,
            flag_price: [[0; 2]; STATES],
            sel_price: [[0; 4]; 4],
            sign_price: [[0; 2]; 4],
            gap_price: [[0; 32]; 4],
            dist_memo: vec![DistMemo::default(); 1 << DIST_MEMO_BITS],
            memo_epoch: 0,
            tail_memo: vec![(usize::MAX, 0, 0); 1 << TAIL_MEMO_BITS],
        };
        e.refresh();
        e
    }

    fn refresh(&mut self) {
        self.m.len.fill(&self.pr, &mut self.len_prices);
        self.m.rep_len.fill(&self.pr, &mut self.rep_len_prices);
        for ls in 0..self.rows {
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
        // 価格表が変わったので覚えを無効にする（epoch 0 の空の項目と取り違えないよう 1 から数える）。
        self.memo_epoch = self.memo_epoch.wrapping_add(1).max(1);
    }

    /// 近傍距離の価格表を作る。
    fn refresh_near(&mut self) {
        let pr = &self.pr;
        let m = &self.m;
        for st in 0..STATES {
            self.flag_price[st] = [pr.bit(m.near_flag[st], 0), pr.bit(m.near_flag[st], 1)];
        }
        for ls in 0..4 {
            for (i, slot) in self.sel_price[ls].iter_mut().enumerate() {
                *slot = pr.tree(&m.near_sel[ls], 2, i as u32);
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
    }

    #[inline(always)]
    fn dist_price(&self, dist: u32, len: usize) -> u32 {
        self.dist_price_ls(dist, self.row_of(len))
    }

    /// 長さ len（2 以上）の一致の、距離 slot の文脈の行（wide なら 8 区分、そうでなければ min(長さ-2, 3)）。
    #[inline(always)]
    fn row_of(&self, len: usize) -> usize {
        if self.wide {
            wide_row(len - 2)
        } else {
            (len - 2).min(3)
        }
    }

    /// slot の文脈の行 ls（wide なら 8 区分、そうでなければ min(長さ-2, 3)）での、通常の距離符号の価格。
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
        // 規則B：更新前の rep と等しい距離は rep 記号で書くので近傍にしない。
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

    /// parse 用：距離 dist（0始まり）の通常一致の距離部分の価格を、slot の文脈の行 ls（`row_of`。revision 12〜14 は
    /// min(長さ-2, 3) の 4 行、revision 15 は長さ 8 区分の 8 行）ごとに返す。
    /// 近傍を使う符号なら通常側の flag の価格を足し、近傍で書く場合の価格（flag 込み）と比べて小さい方を採る。
    /// 近傍側の基準番号の文脈は、どの revision でも min(長さ-2, 3)（行 ls ≥ 3 は文脈 3 を使う）。
    /// r は更新前の rep 距離、st は更新前の state。
    /// flag を除いた部分（通常の距離の価格と、近傍の sel+sign+gap の最小）は dist と r だけで決まるので、
    /// 価格表を作り直すまで小さな表に覚えておく（同じ一致が続く位置で同じ dist・r が繰り返し現れる）。
    /// すべての行を求める（呼び出し側は一致の長さの範囲に当たる行だけを引く）。
    #[inline(always)]
    fn dist_costs(&mut self, st: usize, dist: u32, r: &[u32; 4]) -> [u32; 8] {
        if !self.near {
            let mut out = [0; 8];
            for (ls, o) in out.iter_mut().enumerate().take(self.rows) {
                *o = self.dist_price_ls(dist, ls);
            }
            return out;
        }
        let slot = ((dist ^ r[0].rotate_left(11) ^ r[1].rotate_left(23)).wrapping_mul(0x9E37_79B1)
            >> (32 - DIST_MEMO_BITS)) as usize;
        let e = &self.dist_memo[slot];
        let (normal, near) = if e.epoch == self.memo_epoch && e.dist == dist && e.reps == *r {
            (e.normal, e.near)
        } else {
            let v = self.dist_parts(dist, r);
            self.dist_memo[slot] = DistMemo {
                epoch: self.memo_epoch,
                dist,
                reps: *r,
                normal: v.0,
                near: v.1,
            };
            v
        };
        let [f0, f1] = self.flag_price[st];
        let mut out = [0; 8];
        for ls in 0..self.rows {
            out[ls] = (normal[ls] + f0).min(f1.saturating_add(near[ls.min(3)]));
        }
        out
    }

    /// dist_costs の flag を除いた部分：通常の距離の価格（行ごと）と、近傍で書く場合の sel+sign+gap の最小
    /// （基準番号の文脈 min(長さ-2, 3) ごと。使えなければ INF）。
    fn dist_parts(&self, dist: u32, r: &[u32; 4]) -> ([u32; 8], [u32; 4]) {
        let mut normal = [0; 8];
        for (ls, o) in normal.iter_mut().enumerate().take(self.rows) {
            *o = self.dist_price_ls(dist, ls);
        }
        let mut near = [INF; 4];
        // 規則B：更新前の rep と等しい距離は近傍にしない。
        if r.contains(&dist) {
            return (normal, near);
        }
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
        if np.iter().all(|&p| p == INF) {
            return (normal, near);
        }
        for (ls, o) in near.iter_mut().enumerate() {
            *o = (0..4)
                .map(|i| np[i].saturating_add(self.sel_price[ls][i]))
                .min()
                .unwrap_or(INF);
        }
        (normal, near)
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
        let probs = &self.m.literal[lit_base(self.prev_byte(pos))..];
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

    /// 1 segment を初期状態の model から符号化し、range 符号の body を返す。
    /// 一致探索器は segment の先頭から順に呼ぶ（逐次の BT4 ではそれ以前の位置が索引済みであること）。
    pub fn encode_segment(&mut self, scope: Scope) -> SegOut {
        self.scope = scope;
        self.m = Model::new(R::DUAL);
        self.literals = 0;
        self.state = 0;
        self.reps = [0; 4];
        self.cached = None;
        // 規則の範囲（room）は segment ごとに違うので、覚えを空にする。
        self.tail_memo.fill((usize::MAX, 0, 0));
        self.refresh();
        let mut pos = scope.seg_start;
        while pos < scope.end {
            if self.since_refresh >= REFRESH {
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
        let rc = std::mem::replace(&mut self.rc, R::new((scope.end - scope.seg_start) / 3 + 64));
        let (plain, mix) = rc.finish();
        SegOut {
            plain,
            mix,
            literals: self.literals,
        }
    }

    fn emit(&mut self, pos: usize, len: usize, back: u32) {
        let ps = pos & PB_MASK;
        let st = self.state;
        self.since_refresh += 1;
        if back == LIT {
            self.rc.bit(&mut self.m.is_match[st * POS_STATES + ps], 0);
            let byte = self.data[pos];
            let prev1 = self.prev_byte(pos);
            let base = lit_base(prev1);
            let mb = self.match_byte(pos, self.reps[0]).filter(|_| st >= 7);
            self.literals += 1;
            // 符号器が書く（単一なら LZMA の literal 符号、`DualEnc` なら混合なし・ありの両方）。
            let probs: &mut [u16; LIT_SIZE] = (&mut self.m.literal[base..base + LIT_SIZE])
                .try_into()
                .expect("literal table is LIT_SIZE long");
            self.rc
                .literal(probs, self.m.lit_mix.as_deref_mut(), prev1, mb, byte);
            self.state = lit_next(st);
            return;
        }
        self.rc.bit(&mut self.m.is_match[st * POS_STATES + ps], 1);
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
            self.m.rep_len.encode(&mut self.rc, len as u32 - 2, ps);
            self.state = rep_next(st);
            return;
        }
        self.rc.bit(&mut self.m.is_rep[st], 0);
        let dist = back - 4;
        let old = self.reps;
        // 近傍で書くかは emit が決める（parse の価格が近傍を見込んでいてもいなくても同じ規則）。
        let nc = if self.near {
            self.near_code(dist, &old, len, st)
        } else {
            None
        };
        if self.near {
            self.rc.bit(&mut self.m.near_flag[st], nc.is_some() as u32);
        }
        self.m.len.encode(&mut self.rc, len as u32 - 2, ps);
        let ls = (len - 2).min(3);
        if let Some(c) = nc {
            // 近傍：どの rep か、向き、差-1 の slot と、slot 4 以上の下位 bit（平坦）。
            self.rc.tree(&mut self.m.near_sel[ls], 2, c.i as u32);
            self.rc.bit(&mut self.m.near_sign[c.i], c.neg as u32);
            let gs = pos_slot(c.g);
            self.rc.tree(&mut self.m.near_gap[c.i], 5, gs);
            if gs >= 4 {
                let footer = (gs >> 1) - 1;
                self.rc.direct(c.g - ((2 | (gs & 1)) << footer), footer);
            }
            self.reps = [dist, old[0], old[1], old[2]];
            self.state = match_next(st);
            return;
        }
        let slot = pos_slot(dist);
        let row = self.row_of(len);
        self.rc.tree(&mut self.m.pos_slot[row], 6, slot);
        if slot >= 4 {
            let footer = (slot >> 1) - 1;
            let base = (2 | (slot & 1)) << footer;
            let reduced = dist - base;
            if (slot as usize) < END_POS_MODEL {
                self.rc.reverse(
                    &mut self.m.pos_special[(base - slot) as usize..],
                    footer,
                    reduced,
                );
            } else {
                self.rc.direct(reduced >> 4, footer - 4);
                self.rc.reverse(&mut self.m.align, 4, reduced & 15);
            }
        }
        self.reps = [dist, self.reps[0], self.reps[1], self.reps[2]];
        self.state = match_next(st);
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
        for opt in &mut self.opts[2..=len_end] {
            opt.price = INF;
        }
        for (i, &rl) in rep_lens.iter().enumerate() {
            if rl < 2 {
                continue;
            }
            let base = rep_match_price + self.rep_price(i, state, ps);
            for l in 2..=rl {
                let p = base + self.rep_len_prices[ps][l - 2];
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
            let mut dc = self.dist_costs(state, self.first[k].dist, &reps);
            for l in start..=main_len {
                let m = self.first[k];
                let p = normal + self.len_prices[ps][l - 2] + dc[self.row_of(l)];
                if p < self.opts[l].price {
                    self.set(l, p, 0, m.dist + 4);
                }
                if l == m.len as usize {
                    k += 1;
                    if l < main_len {
                        dc = self.dist_costs(state, self.first[k].dist, &reps);
                    }
                }
            }
        }

        let mut cur = 0usize;
        loop {
            cur += 1;
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
            if !next_is_lit && match_byte != Some(cur_byte) {
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
                    let pr = base + self.rep_len_prices[ps][l - 2];
                    if pr < self.opts[cur + l].price {
                        self.set(cur + l, pr, cur as u32, i as u32);
                    }
                }
                if i == 0 {
                    start_len = rl + 1;
                }
                if rl + 1 < avail {
                    // rep の後に literal、さらに同じ距離（rep0 になる）で続く連結記号。
                    let l2 = self.tail_rep0(p + rl, rep, avail - rl);
                    if l2 >= 2 {
                        let q = p + rl;
                        let st2 = rep_next(st);
                        let psq = q & PB_MASK;
                        let st3 = lit_next(st2);
                        let psn = (q + 1) & PB_MASK;
                        let price = base
                            + self.rep_len_prices[ps][rl - 2]
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
                let mut dc = self.dist_costs(st, self.cur_matches[k].dist, &r);
                for l in start_len..=nl {
                    let m = self.cur_matches[k];
                    let pr = normal + self.len_prices[ps][l - 2] + dc[self.row_of(l)];
                    if pr < self.opts[cur + l].price {
                        self.set(cur + l, pr, cur as u32, m.dist + 4);
                    }
                    if l == m.len as usize {
                        if l + 1 < avail {
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
                        dc = self.dist_costs(st, self.cur_matches[k].dist, &r);
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
    fn rep0_long_price(&self, len: usize, state: usize, ps: usize) -> u32 {
        self.rep_price(0, state, ps) + self.rep_len_prices[ps][len - 2]
    }

    /// pos の literal の後、rep0（距離 rep+1）で続く一致長（2未満なら0）。limit は literal を含めた残り。
    /// 一致の続きの位置 q と距離が同じなら、limit を除いた部分（nice と規則の範囲で測った共通長）は同じなので、
    /// segment の中では小さな表に覚えておく（一致が続く間、先読みの各位置で同じ終端が繰り返し現れる）。
    /// 共通長は上限を縮めると min を取るだけなので、limit で切り詰めた値は覚えずに測った値と同じ。
    #[inline(always)]
    fn tail_rep0(&mut self, pos: usize, rep: u32, limit: usize) -> usize {
        if limit < 3 {
            return 0;
        }
        let q = pos + 1;
        let slot = ((q as u32 ^ rep.rotate_left(16)).wrapping_mul(0x9E37_79B1)
            >> (32 - TAIL_MEMO_BITS)) as usize;
        let e = self.tail_memo[slot];
        let raw = if e.0 == q && e.1 == rep {
            e.2 as usize
        } else {
            let room = self.room(q, rep);
            let raw = if room == 0 {
                0
            } else {
                common(
                    self.data,
                    q - rep as usize - 1,
                    &self.data[q..],
                    0,
                    self.nice.min(room),
                )
            };
            self.tail_memo[slot] = (q, rep, raw as u32);
            raw
        };
        let l = raw.min(limit - 1);
        if l >= 2 { l } else { 0 }
    }

    fn skip(&mut self, from: usize, to: usize) {
        for p in from..to {
            self.mf.skip(self.data, p);
        }
    }
}

/// 試験用の記号列 emitter。符号化器の最適 parse を通さず、正規形に反する符号（別名の選択、
/// rep と等しくなる距離、下溢れなど）を直接作って復号器の拒否を確かめる。
/// 一致の前に literal だけが並ぶ記号列（state < 7 の間の literal）に限る。
#[cfg(test)]
pub(super) mod sym {
    use super::*;

    /// 近傍符号で書く値（正規形の検査を通らない値も書ける）。
    #[derive(Clone, Copy)]
    pub struct NearSpec {
        pub i: usize,
        pub neg: bool,
        pub g: u32,
    }

    pub enum Sym {
        Lit(u8),
        /// 通常の一致。`near` が Some なら近傍の flag=1 とその値で書く（距離は復号側が求める）。
        /// None なら、通常の距離符号で `dist`（0始まり）を書く。
        Match {
            len: usize,
            dist: u32,
            near: Option<NearSpec>,
        },
    }

    /// `start` は segment の先頭位置（pos_state の文脈に使う）。`near_stream` は frame revision 2 以降か
    /// （通常の一致にも flag=0 を書く）。`wide` は frame revision 4 か（slot 文脈の長さ 8 区分）、`litmix` は
    /// frame revision 4 の method 2 か（literal の混合）。
    pub fn encode(
        syms: &[Sym],
        start: usize,
        near_stream: bool,
        wide: bool,
        litmix: bool,
    ) -> Vec<u8> {
        let mut m = Model::new(litmix);
        let mut rc = RangeEnc::new(1024);
        let mut state = 0usize;
        let mut pos = start;
        let mut prev = 0u8;
        let mut matched = false;
        for s in syms {
            let ps = pos & PB_MASK;
            match *s {
                Sym::Lit(byte) => {
                    assert!(!matched, "literal after a match is not supported");
                    rc.bit(&mut m.is_match[state * POS_STATES + ps], 0);
                    let base = lit_base(prev);
                    let probs = &mut m.literal[base..base + LIT_SIZE];
                    if let Some(lx) = m.lit_mix.as_mut() {
                        let probs: &mut [u16; LIT_SIZE] = probs.try_into().unwrap();
                        lx.encode(probs, &mut rc, prev, None, byte);
                    } else {
                        let mut ctx = 1usize;
                        for i in (0..8).rev() {
                            let bit = ((byte >> i) & 1) as u32;
                            rc.bit(&mut probs[ctx], bit);
                            ctx = (ctx << 1) | bit as usize;
                        }
                    }
                    state = lit_next(state);
                    prev = byte;
                    pos += 1;
                }
                Sym::Match { len, dist, near } => {
                    matched = true;
                    rc.bit(&mut m.is_match[state * POS_STATES + ps], 1);
                    rc.bit(&mut m.is_rep[state], 0);
                    if near_stream {
                        rc.bit(&mut m.near_flag[state], near.is_some() as u32);
                    } else {
                        assert!(near.is_none(), "near symbol in a revision 1 stream");
                    }
                    m.len.encode(&mut rc, len as u32 - 2, ps);
                    let ls = (len - 2).min(3);
                    if let Some(c) = near {
                        rc.tree(&mut m.near_sel[ls], 2, c.i as u32);
                        rc.bit(&mut m.near_sign[c.i], c.neg as u32);
                        let gs = pos_slot(c.g);
                        rc.tree(&mut m.near_gap[c.i], 5, gs);
                        if gs >= 4 {
                            let footer = (gs >> 1) - 1;
                            rc.direct(c.g - ((2 | (gs & 1)) << footer), footer);
                        }
                    } else {
                        let slot = pos_slot(dist);
                        let row = if wide { wide_row(len - 2) } else { ls };
                        rc.tree(&mut m.pos_slot[row], 6, slot);
                        if slot >= 4 {
                            let footer = (slot >> 1) - 1;
                            let base = (2 | (slot & 1)) << footer;
                            let reduced = dist - base;
                            if (slot as usize) < END_POS_MODEL {
                                rc.reverse(
                                    &mut m.pos_special[(base - slot) as usize..],
                                    footer,
                                    reduced,
                                );
                            } else {
                                rc.direct(reduced >> 4, footer - 4);
                                rc.reverse(&mut m.align, 4, reduced & 15);
                            }
                        }
                    }
                    state = match_next(state);
                    pos += len;
                }
            }
        }
        rc.finish()
    }
}
