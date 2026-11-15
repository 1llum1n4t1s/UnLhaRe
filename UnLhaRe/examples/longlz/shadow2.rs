//! 一致（距離・長さ）の model を強くしたときの符号長を見積もる「影の model」（計測用、出力は変えない）。
//!
//! 実際の符号化・parse は LZMA と同じ model のまま行い、同じ記号列を強い model で符号化したら何 bit に
//! なるかを、複数文脈の予測の logistic 混合で見積もる（literal の影 model と同じ方法）。
//! 見積もる対象（LLZ_SHADOW2=1 のときだけ有効）：
//!   - slot：len の文脈なし／あり
//!   - 長さ：現在の slot の文脈なし／あり
//!   - 直接 bit の上位 K bit を文脈つきに
//!   - align 4bit を pos の下位 4bit などの文脈で
//!   - 近傍距離：rep 距離との差が小さい距離を、差で符号化する案
//!
//! counter は f32 で適応速度を回数で下げるため、実際の整数 model より楽観側。比較は「同じ仕組みで
//! 先頭の文脈だけを使った値（base）」と行い、実際の符号長との差も併記する。

#![allow(clippy::needless_range_loop, clippy::too_many_arguments)] // 計測用の試作。可読性より見積もりの追いやすさを優先する。

use super::shadow::{Counter, squash, stretch};

const MAX_IN: usize = 8;

/// 二分木の節ごとに、複数文脈の counter を logistic 混合する符号長の見積もり器。
struct MixTree {
    tabs: Vec<Vec<Counter>>,
    nodes: usize,
    weights: Vec<[f32; MAX_IN + 1]>,
    /// 先頭の文脈だけで符号化した場合の符号長（bit）。
    base: f64,
    /// 混合した符号長（bit）。
    mixed: f64,
}

impl MixTree {
    fn new(ctx_counts: &[usize], nodes: usize, wsets: usize) -> Self {
        Self {
            tabs: ctx_counts
                .iter()
                .map(|&c| vec![Counter::INIT; c * nodes])
                .collect(),
            nodes,
            weights: vec![[0.4; MAX_IN + 1]; wsets],
            base: 0.0,
            mixed: 0.0,
        }
    }

    /// 1 bit を符号化した場合の符号長を足し、counter と重みを更新する。
    fn bit(&mut self, ctx: &[usize], node: usize, wset: usize, bit: u32) {
        let k = self.tabs.len();
        let mut s = [0f32; MAX_IN + 1];
        for i in 0..k {
            s[i] = stretch(self.tabs[i][ctx[i] * self.nodes + node].p);
        }
        s[k] = 0.25;
        let p0 = self.tabs[0][ctx[0] * self.nodes + node]
            .p
            .clamp(1.0 / 4096.0, 4095.0 / 4096.0);
        self.base -= (if bit == 0 { p0 } else { 1.0 - p0 } as f64).log2();
        let w = &mut self.weights[wset];
        let dot: f32 = (0..=k).map(|i| w[i] * s[i]).sum();
        let p = squash(dot).clamp(1.0 / 4096.0, 4095.0 / 4096.0);
        self.mixed -= (if bit == 0 { p } else { 1.0 - p } as f64).log2();
        let err = (if bit == 0 { 1.0 } else { 0.0 }) - p;
        for i in 0..=k {
            w[i] += 0.02 * err * s[i];
        }
        for i in 0..k {
            let lim = if i == 0 { 32.0 } else { 64.0 };
            self.tabs[i][ctx[i] * self.nodes + node].update(bit, lim);
        }
    }

    /// 上位から nbits 本の木符号。
    fn tree(&mut self, ctx: &[usize], nbits: u32, symbol: u32) {
        let mut node = 1usize;
        for i in (0..nbits).rev() {
            let b = (symbol >> i) & 1;
            self.bit(ctx, node, (nbits - 1 - i) as usize, b);
            node = (node << 1) | b as usize;
        }
    }

    /// 下位から nbits 本の逆順木符号。
    fn reverse(&mut self, ctx: &[usize], nbits: u32, symbol: u32) {
        let mut node = 1usize;
        for i in 0..nbits {
            let b = (symbol >> i) & 1;
            self.bit(ctx, node, i as usize, b);
            node = (node << 1) | b as usize;
        }
    }
}

fn pos_slot(d: u32) -> u32 {
    if d < 4 {
        d
    } else {
        let n = 31 - d.leading_zeros();
        (n << 1) | ((d >> (n - 1)) & 1)
    }
}

/// LZMA の長さ符号と同じ分解（choice、choice2、low 3bit、mid 3bit、high 8bit）で 274 節。
const LEN_NODES: usize = 274;
const LEN_WSETS: usize = 16;

fn len_code(m: &mut MixTree, ctx: &[usize], v: u32) {
    if v < 8 {
        m.bit(ctx, 0, 0, 0);
        let mut node = 1usize;
        for i in (0..3).rev() {
            let b = (v >> i) & 1;
            m.bit(ctx, 2 + node, 2 + (2 - i as usize), b);
            node = (node << 1) | b as usize;
        }
    } else if v < 16 {
        m.bit(ctx, 0, 0, 1);
        m.bit(ctx, 1, 1, 0);
        let mut node = 1usize;
        for i in (0..3).rev() {
            let b = ((v - 8) >> i) & 1;
            m.bit(ctx, 10 + node, 5 + (2 - i as usize), b);
            node = (node << 1) | b as usize;
        }
    } else {
        m.bit(ctx, 0, 0, 1);
        m.bit(ctx, 1, 1, 1);
        let mut node = 1usize;
        for i in (0..8).rev() {
            let b = ((v - 16) >> i) & 1;
            m.bit(ctx, 18 + node, 8 + (7 - i as usize), b);
            node = (node << 1) | b as usize;
        }
    }
}

const TOPK: u32 = 6;

pub struct MatchShadow {
    slot_nolen: MixTree,
    slot_len: MixTree,
    len_noslot: MixTree,
    len_slot: MixTree,
    len_slot6: MixTree,
    len_slot6_only: MixTree,
    len_pl_only: MixTree,
    len_mix2: MixTree,
    len_mix3: MixTree,
    len_state_only: MixTree,
    dtop: MixTree,
    align: MixTree,
    /// 直接 bit の本数の合計（平坦に 1bit ずつ送る場合の符号長）。
    direct_flat: f64,
    direct_modeled: f64,
    /// 近傍距離の案：現在の model での距離の符号長の合計と、近傍距離を使えるとして選んだ場合の合計。
    near_base: f64,
    near_new: f64,
    near_used: u64,
    near_total: u64,
    near_flag: Vec<Counter>,
    near_max: u32,
    al_flag: Counter,
    al_base: f64,
    al_new: f64,
    al_pos: u64,
    al_hit: u64,
    al512_any: u64,
    near_sel: Vec<Counter>,
    near_sign: Vec<Counter>,
    near_gamma: Vec<Counter>,
    prev_slot: usize,
    prev_len: usize,
    prev_low4: usize,
    prev_top: usize,
    prev_top_slot: usize,
}

impl MatchShadow {
    pub fn new() -> Self {
        Self {
            slot_nolen: MixTree::new(&[4, 64, 48], 64, 6),
            slot_len: MixTree::new(&[4, 64, 48, 64], 64, 6),
            len_noslot: MixTree::new(&[4, 32, 12, 64], LEN_NODES, LEN_WSETS),
            len_slot: MixTree::new(&[4, 32, 12, 64], LEN_NODES, LEN_WSETS),
            len_slot6: MixTree::new(&[4, 32, 12, 11], LEN_NODES, LEN_WSETS),
            len_slot6_only: MixTree::new(&[44], LEN_NODES, LEN_WSETS),
            len_pl_only: MixTree::new(&[32 * 11], LEN_NODES, LEN_WSETS),
            len_mix2: MixTree::new(&[44, 32], LEN_NODES, LEN_WSETS),
            len_mix3: MixTree::new(&[44, 32, 12], LEN_NODES, LEN_WSETS),
            len_state_only: MixTree::new(&[12 * 11], LEN_NODES, LEN_WSETS),
            dtop: MixTree::new(&[64, 64 * 17], 1 << TOPK, TOPK as usize),
            align: MixTree::new(&[1, 16, 16, 64], 16, 4),
            direct_flat: 0.0,
            direct_modeled: 0.0,
            near_base: 0.0,
            near_new: 0.0,
            near_used: 0,
            near_total: 0,
            near_flag: vec![Counter::INIT; 12],
            near_max: std::env::var("LLZ_NEAR_MAX")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(12),
            al_flag: Counter::INIT,
            al_base: 0.0,
            al_new: 0.0,
            al_pos: 0,
            al_hit: 0,
            al512_any: 0,
            near_sel: vec![Counter::INIT; 4 * 4],
            near_sign: vec![Counter::INIT; 4],
            near_gamma: vec![Counter::INIT; 4 * 64],
            prev_slot: 0,
            prev_len: 0,
            prev_low4: 0,
            prev_top: 16,
            prev_top_slot: 0,
        }
    }

    /// rep 一致（長さ len）。長さ文脈の更新だけ。
    pub fn rep(&mut self, len: usize) {
        self.prev_len = len;
    }

    /// 通常の一致。state は一致前の状態、ps は pos&3、reps は更新前の距離（0 始まり）。
    /// cur_bits は現在の model での距離（slot＋下位）の符号長（bit）。
    pub fn matched(
        &mut self,
        pos: usize,
        state: usize,
        ps: usize,
        len: usize,
        dist: u32,
        reps: [u32; 4],
        cur_bits: f64,
    ) {
        let ls = (len - 2).min(3);
        let slot = pos_slot(dist) as usize;
        let lexact = (len - 2).min(63);
        // slot（長さの文脈なし／あり）。
        let pl = (self.prev_len.max(2) - 2).min(31);
        self.slot_nolen
            .tree(&[ls, self.prev_slot, state * 4 + ls], 6, slot as u32);
        self.slot_len.tree(
            &[ls, self.prev_slot, state * 4 + ls, lexact],
            6,
            slot as u32,
        );
        // 長さ（現在の slot の文脈なし／あり）。
        len_code(
            &mut self.len_noslot,
            &[ps, pl, state, self.prev_slot],
            len as u32 - 2,
        );
        len_code(&mut self.len_slot, &[ps, pl, state, slot], len as u32 - 2);
        len_code(
            &mut self.len_slot6,
            &[ps, pl, state, slot / 6],
            len as u32 - 2,
        );
        len_code(
            &mut self.len_slot6_only,
            &[ps * 11 + slot / 6],
            len as u32 - 2,
        );
        len_code(
            &mut self.len_mix2,
            &[ps * 11 + slot / 6, pl],
            len as u32 - 2,
        );
        len_code(
            &mut self.len_mix3,
            &[ps * 11 + slot / 6, pl, state],
            len as u32 - 2,
        );
        len_code(&mut self.len_pl_only, &[pl * 11 + slot / 6], len as u32 - 2);
        len_code(
            &mut self.len_state_only,
            &[state * 11 + slot / 6],
            len as u32 - 2,
        );
        // 直接 bit（slot >= 14）と align。
        let mut top = 16usize;
        if slot >= 14 {
            let footer = (slot as u32 >> 1) - 1;
            let base = (2 | (slot as u32 & 1)) << footer;
            let reduced = dist - base;
            let direct = reduced >> 4;
            let n = footer - 4;
            self.direct_flat += n as f64;
            let k = n.min(TOPK);
            let top_sym = direct >> (n - k);
            let prev_ctx = if self.prev_top_slot == slot {
                self.prev_top
            } else {
                16
            };
            let before = self.dtop.mixed;
            self.dtop.tree(&[slot, slot * 17 + prev_ctx], k, top_sym);
            self.direct_modeled += (self.dtop.mixed - before) + (n - k) as f64;
            top = (top_sym & 15) as usize;
            self.prev_top_slot = slot;
            self.prev_top = top;
            let low4 = (reduced & 15) as usize;
            self.align
                .reverse(&[0, pos & 15, self.prev_low4, slot], 4, low4 as u32);
            self.prev_low4 = low4;
        }
        let _ = top;
        // 512 byte 境界（tar の file 先頭）から始まる一致の、境界を指す距離。
        if (dist + 1) & 511 == 0 {
            self.al512_any += 1;
        }
        if pos & 511 == 0 {
            self.al_pos += 1;
            let aligned = (dist + 1) & 511 == 0;
            let (c_yes, c_no) = (cost(self.al_flag.p, 0), cost(self.al_flag.p, 1));
            self.al_base += cur_bits;
            if aligned {
                self.al_hit += 1;
                self.al_new += (c_yes + (cur_bits - 9.0).max(3.0)).min(c_no + cur_bits);
            } else {
                self.al_new += c_no + cur_bits;
            }
            self.al_flag.update(!aligned as u32, 64.0);
        }
        // 近傍距離。
        self.near_total += 1;
        self.near_base += cur_bits;
        let flag = &mut self.near_flag[state];
        let (c_no, c_yes) = (cost(flag.p, 1), cost(flag.p, 0));
        // flag の符号：0 が「近傍を使う」。
        let mut best: Option<(usize, f64, bool, u32)> = None;
        for (i, &r) in reps.iter().enumerate() {
            if r == dist {
                continue;
            }
            let d = dist.abs_diff(r);
            if d > 1u32 << self.near_max {
                continue;
            }
            let neg = dist < r;
            let g = d - 1;
            let gs = pos_slot(g) as usize;
            let mut bits =
                cost(self.near_sel[ls * 4 + i].p, 0) + cost(self.near_sign[i].p, neg as u32);
            // 選択 i は 4 値の 2 段の近似：i の一致確率の対数を単純に 2 bit とする代わりに
            // counter 1 つ分（i を選ぶ確率）で見積もる。
            bits += tree_cost(&self.near_gamma[i * 64..(i + 1) * 64], 6, gs as u32);
            if gs >= 4 {
                bits += ((gs as u32 >> 1) - 1) as f64;
            }
            if best.is_none_or(|b| bits < b.1) {
                best = Some((i, bits, neg, g));
            }
        }
        let mut used = false;
        if let Some((i, bits, neg, g)) = best
            && c_yes + bits < c_no + cur_bits
        {
            used = true;
            self.near_used += 1;
            self.near_new += c_yes + bits;
            // 更新。
            for j in 0..4 {
                self.near_sel[ls * 4 + j].update((j != i) as u32, 64.0);
            }
            self.near_sign[i].update(neg as u32, 64.0);
            let gs = pos_slot(g);
            let mut node = 1usize;
            for b in (0..6).rev() {
                let bit = (gs >> b) & 1;
                self.near_gamma[i * 64 + node].update(bit, 64.0);
                node = (node << 1) | bit as usize;
            }
        } else {
            self.near_new += c_no + cur_bits;
        }
        self.near_flag[state].update(!used as u32, 64.0);
        self.prev_slot = slot;
        self.prev_len = len;
    }

    /// 見積もりを (名前, bit) で返す。
    pub fn report(&self) -> Vec<(&'static str, f64)> {
        vec![
            ("slot base", self.slot_nolen.base),
            ("slot mixed (no len ctx)", self.slot_nolen.mixed),
            ("slot mixed (len ctx)", self.slot_len.mixed),
            ("len base", self.len_noslot.base),
            ("len mixed (no slot ctx)", self.len_noslot.mixed),
            ("len mixed (slot ctx)", self.len_slot.mixed),
            ("len mixed (slot/6 ctx)", self.len_slot6.mixed),
            (
                "len mixed 2 inputs (ps*slot6, prevlen)",
                self.len_mix2.mixed,
            ),
            ("len mixed 3 inputs (+state)", self.len_mix3.mixed),
            ("len single ctx ps*slot/6", self.len_slot6_only.base),
            ("len single ctx prevlen*slot/6", self.len_pl_only.base),
            ("len single ctx state*slot/6", self.len_state_only.base),
            (
                "direct top single-ctx",
                self.dtop.base + (self.direct_modeled - self.dtop.mixed),
            ),
            ("direct flat", self.direct_flat),
            ("direct top-modeled", self.direct_modeled),
            ("align base", self.align.base),
            ("align mixed", self.align.mixed),
            ("near base (cur dist bits)", self.near_base),
            ("near new", self.near_new),
            ("near used", self.near_used as f64),
            ("near total", self.near_total as f64),
            ("align512 base (pos%512==0)", self.al_base),
            ("align512 new", self.al_new),
            ("align512 pos count", self.al_pos as f64),
            ("align512 hit count", self.al_hit as f64),
            ("dist+1 %512==0 any pos", self.al512_any as f64),
        ]
    }
}

fn cost(p0: f32, bit: u32) -> f64 {
    let p = p0.clamp(1.0 / 4096.0, 4095.0 / 4096.0) as f64;
    -(if bit == 0 { p } else { 1.0 - p }).log2()
}

fn tree_cost(tab: &[Counter], nbits: u32, symbol: u32) -> f64 {
    let mut node = 1usize;
    let mut bits = 0.0;
    for i in (0..nbits).rev() {
        let b = (symbol >> i) & 1;
        bits += cost(tab[node].p, b);
        node = (node << 1) | b as usize;
    }
    bits
}
