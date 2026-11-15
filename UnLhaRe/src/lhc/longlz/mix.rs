//! literal の混合（archive revision 15、LLZ1BLK の frame revision 4）。
//!
//! literal の各 bit の確率を、2 つの予測の logistic 混合で決める（lpaq 型、整数だけ）。
//! - 入力 0：LZMA と同じ literal 確率（直前 byte の上位 3bit の文脈。一致byte文脈なら一致 bit で分けた節）。
//!   11bit・移動量 5 の確率で、更新も LZMA と同じ。
//! - 入力 1：直前 1 byte 全体の文脈の確率（一致 bit は含めない）。16bit・移動量 5 の確率。
//! - 重みは「一致byte文脈か × bit の位置」の 16 組。重みの初期値は 0.8、0.3、bias 0。
//!
//! 予測・符号化・更新の演算は符号化側（`LitMix::encode`）と復号側（`LitMix::decode`）で同じ関数 `bit` を
//! 通すので、2 つの結果は構造上一致する。確率は 12bit（1..=4095）で range 符号器の `bit12` へ渡す。
//! 演算はすべて整数で、表は初回に作って共有する。

use super::rc::{RangeDec, RangeEnc};
use std::sync::OnceLock;

/// lpaq1 の squash の補間点（d/256 の logistic を 12bit で表したもの）。
const SQ: [i32; 33] = [
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348,
    3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094,
];

/// d（8bit 小数の対数オッズ、±2047）から 12bit 確率へ（表の作成にだけ使う）。
fn squash_calc(d: i32) -> i32 {
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

/// stretch（12bit 確率→対数オッズ）と squash（対数オッズ→12bit 確率）の表。添字は 4095 で mask して引く。
pub struct Tables {
    stretch: Box<[i16; 4096]>,
    /// squash(d) の表（d = -2047..=2047 を 0..=4094 に置き、[1, 4095] に収めた値。末尾 1 つは詰め物）。
    squash: Box<[i16; 4096]>,
}

impl Tables {
    fn new() -> Self {
        let mut stretch = Box::new([0i16; 4096]);
        let mut pi = 0usize;
        for x in -2047..=2047 {
            let v = squash_calc(x) as usize;
            for s in stretch.iter_mut().take(v + 1).skip(pi) {
                *s = x as i16;
            }
            pi = pi.max(v + 1);
        }
        for s in stretch.iter_mut().skip(pi) {
            *s = 2047;
        }
        let mut squash = Box::new([4095i16; 4096]);
        for (s, d) in squash.iter_mut().zip(-2047..=2047) {
            *s = squash_calc(d).clamp(1, 4095) as i16;
        }
        Self { stretch, squash }
    }
}

/// 共有の表（初回の呼び出しで作る）。
pub fn tables() -> &'static Tables {
    static TABLES: OnceLock<Tables> = OnceLock::new();
    TABLES.get_or_init(Tables::new)
}

/// 重みの組の数（一致byte文脈か × bit の位置 8）。
const WEIGHT_SETS: usize = 16;
/// 重みの絶対値の上限（積和が i32 に収まる範囲：2^18 × 2047 × 2 ＋ 2^18 × 256 < 2^31）。
const WEIGHT_LIMIT: i32 = 1 << 18;

/// literal の混合の model（segment ごとに作り直す）。LZMA 側の確率は `Model::literal` が持ち、
/// 呼び出し側から `probs` として渡す。
#[derive(Clone)]
pub struct LitMix {
    /// 直前 byte ごとに 256 節（木の節 1..=255）の確率（bit=0 の確率、16bit）。
    t1: Vec<u16>,
    w: [[i32; 3]; WEIGHT_SETS],
}

impl LitMix {
    pub fn new() -> Self {
        Self {
            t1: vec![32768; 256 * 256],
            w: [[52429, 19661, 0]; WEIGHT_SETS],
        }
    }

    /// 1 bit を、予測→（符号化または復号）→更新の順に処理して bit を返す。
    /// `code` は 12bit 確率（bit=0 の確率）を受け取り、符号化なら既知の bit を送って返し、復号なら読んで返す。
    /// probs は LZMA の literal 確率（1 文脈分）、node はその節、at は 2 入力目の確率の位置（直前 byte の区画の先頭
    /// ＋木の節 1..=255）、ws は重みの組。
    #[inline(always)]
    fn bit<F: FnOnce(u32) -> u32>(
        &mut self,
        tb: &Tables,
        probs: &mut [u16; 0x300],
        node: usize,
        at: usize,
        ws: usize,
        code: F,
    ) -> u32 {
        let node = node.min(0x2FF);
        let plz = probs[node];
        let c1 = self.t1[at];
        // 入力の対数オッズ。LZMA の確率は 11bit なので 2 倍して 12bit にそろえる。
        let s0 = i32::from(tb.stretch[((plz as usize) << 1) & 4095]);
        let s1 = i32::from(tb.stretch[((c1 >> 4).max(1) as usize) & 4095]);
        let wv = &mut self.w[ws & (WEIGHT_SETS - 1)];
        let dot = wv[0] * s0 + wv[1] * s1 + wv[2] * 256;
        let p = i32::from(tb.squash[((dot >> 16).clamp(-2047, 2047) + 2047) as usize & 4095]);
        let bit = code(p as u32);
        // LZMA の確率・2 入力目の確率・重みを更新する。
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
        self.t1[at] = c;
        wv[0] = (wv[0] + ((s0 * err + 2048) >> 12)).clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        wv[1] = (wv[1] + ((s1 * err + 2048) >> 12)).clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        wv[2] = (wv[2] + ((256 * err + 2048) >> 12)).clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        bit
    }

    /// literal 1 byte を符号化する。mb は一致byte文脈に使う byte（使えなければ None）。
    pub fn encode(
        &mut self,
        probs: &mut [u16; 0x300],
        rc: &mut RangeEnc,
        prev1: u8,
        mb: Option<u8>,
        byte: u8,
    ) {
        let tb = tables();
        let ctx = (prev1 as usize) << 8;
        let mbyte = mb.map_or(0, |m| m as usize);
        let mut matching = mb.is_some();
        let mut sym = 1usize;
        for i in (0..8usize).rev() {
            let mbit = (mbyte >> i) & 1;
            let node = if matching {
                ((1 + mbit) << 8) + sym
            } else {
                sym
            };
            let want = u32::from((byte >> i) & 1);
            let ws = usize::from(matching) * 8 + i;
            let bit = self.bit(tb, probs, node, ctx + sym, ws, |p| {
                rc.bit12(p, want);
                want
            });
            matching = matching && bit as usize == mbit;
            sym = (sym << 1) | bit as usize;
        }
    }

    /// literal 1 byte を復号する（`encode` と同じ手順・同じ `bit`）。復号は一致byte文脈の区間（最初の bit から、
    /// 一致 byte と違う bit が出るまで）と通常の区間を別の loop にして、bit ごとの「一致中か」の分岐を
    /// なくす（`encode` の `matching` と同じ値の重みの組・節を使う）。
    pub fn decode(
        &mut self,
        probs: &mut [u16; 0x300],
        rc: &mut RangeDec,
        prev1: u8,
        mb: Option<u8>,
    ) -> u8 {
        let tb = tables();
        let ctx = (prev1 as usize) << 8;
        let mut sym = 1usize;
        // 残りの bit 数（i は次に読む bit の位置 + 1）。
        let mut i = 8usize;
        if let Some(m) = mb {
            let mut mbyte = m as usize;
            while i > 0 {
                i -= 1;
                let mbit = (mbyte >> 7) & 1;
                mbyte <<= 1;
                let node = ((1 + mbit) << 8) + sym;
                let bit = self.bit(tb, probs, node, ctx + sym, 8 + i, |p| rc.bit12(p)) as usize;
                sym = (sym << 1) | bit;
                if mbit != bit {
                    break;
                }
            }
        }
        while i > 0 {
            i -= 1;
            let bit = self.bit(tb, probs, sym, ctx + sym, i, |p| rc.bit12(p)) as usize;
            sym = (sym << 1) | bit;
        }
        sym as u8
    }
}

#[cfg(test)]
mod tests {
    use super::super::rc::PROB_INIT;
    use super::*;

    /// literal の LZMA 側の確率表（直前 byte の上位 3bit ごとに 0x300 節）。
    fn literal_table() -> Vec<u16> {
        vec![PROB_INIT; 0x300 << 3]
    }

    /// 符号化と復号が同じ手順で往復する。一致byte文脈なし・あり（一致 byte と同じ／違う bit が出る）、
    /// 確率が極端に偏る長い繰り返し（range の 2 byte 分の正規化）を含む。
    #[test]
    fn literal_mix_round_trips_with_and_without_match_bytes() {
        let mut x = 0x2545_f491u32;
        let mut next = move || {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x
        };
        // (一致 byte、符号化する byte) の列。先頭は 0 の長い繰り返し（確率が 1/4096 側へ張り付く）。
        let mut items: Vec<(Option<u8>, u8)> = (0..40_000).map(|_| (Some(0), 0)).collect();
        for _ in 0..60_000 {
            let r = next();
            let byte = match r % 4 {
                0 => (r >> 8) as u8,
                1 => b"abcd"[(r >> 8) as usize % 4],
                _ => 0x20 + ((r >> 8) % 8) as u8,
            };
            let mb = match (r >> 20) % 3 {
                0 => None,
                1 => Some(byte),
                _ => Some((r >> 12) as u8),
            };
            items.push((mb, byte));
        }
        let mut enc_probs = literal_table();
        let mut enc = LitMix::new();
        let mut rc = RangeEnc::new(1 << 16);
        let mut prev = 0u8;
        for &(mb, byte) in &items {
            let lb = 0x300 * (prev as usize >> 5);
            let probs: &mut [u16; 0x300] = (&mut enc_probs[lb..lb + 0x300]).try_into().unwrap();
            enc.encode(probs, &mut rc, prev, mb, byte);
            prev = byte;
        }
        let body = rc.finish();
        assert!(body.len() < items.len(), "a skewed source must compress");

        let mut dec_probs = literal_table();
        let mut dec = LitMix::new();
        let mut rd = RangeDec::new(&body).unwrap();
        let mut prev = 0u8;
        for (i, &(mb, byte)) in items.iter().enumerate() {
            let lb = 0x300 * (prev as usize >> 5);
            let probs: &mut [u16; 0x300] = (&mut dec_probs[lb..lb + 0x300]).try_into().unwrap();
            let got = dec.decode(probs, &mut rd, prev, mb);
            assert_eq!(got, byte, "literal {i}");
            prev = got;
        }
        assert_eq!(enc_probs, dec_probs, "LZMA-side probabilities must agree");
        assert_eq!(enc.t1, dec.t1, "context probabilities must agree");
        assert_eq!(enc.w, dec.w, "weights must agree");
        assert!(rd.consumed() <= body.len(), "no read beyond the payload");
    }

    /// 入力が壊れていても（乱数列を復号させても）panic や溢れを起こさない。
    #[test]
    fn literal_mix_decodes_garbage_without_panic() {
        let mut x = 0x9e37_79b9u32;
        let mut garbage = vec![0u8];
        for _ in 0..20_000 {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            garbage.push((x >> 8) as u8);
        }
        let mut probs_all = literal_table();
        let mut dec = LitMix::new();
        let mut rd = RangeDec::new(&garbage).unwrap();
        let mut prev = 0u8;
        for i in 0..30_000usize {
            let lb = 0x300 * (prev as usize >> 5);
            let probs: &mut [u16; 0x300] = (&mut probs_all[lb..lb + 0x300]).try_into().unwrap();
            let mb = (i % 3 != 0).then_some((i >> 3) as u8);
            prev = dec.decode(probs, &mut rd, prev, mb);
        }
    }
}
