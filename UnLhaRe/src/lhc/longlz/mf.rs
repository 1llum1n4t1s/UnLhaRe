//! 長距離LZ（LLZ1BLK）の一致探索（BT4：2/3byte hash の候補＋4byte hash から辿る二分木）。
//! 二分木は窓長の巡回配列に置き、位置は「絶対位置+1」（0は空）で持つ。
//! 絶対位置で持つため、巡回で上書きされた古い節も距離検査だけで窓外として切れる。

/// 1回の一致の最大長（LZMA と同じ 273）。
pub const MAX_LEN: usize = 273;

/// 一致を報告してよい範囲。end は一致の終端上限（segment 末尾）、
/// 参照元 s は「s >= seg_start」か「s < wave_start（このとき s+len <= wave_start）」のときだけ使える。
#[derive(Clone, Copy, Debug)]
pub struct Scope {
    pub end: usize,
    pub seg_start: usize,
    pub wave_start: usize,
}

impl Scope {
    /// pos で参照元 s の一致長 len を、規則に合う長さへ切り詰める（使えなければ 0）。
    #[inline(always)]
    pub fn clip(&self, pos: usize, s: usize, len: usize) -> usize {
        let len = len.min(self.end - pos);
        if s >= self.seg_start {
            len
        } else if s < self.wave_start {
            len.min(self.wave_start - s)
        } else {
            0
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Match {
    /// 一致長（2..=273）。
    pub len: u32,
    /// 距離-1（LZMA の rep0 と同じ表し方）。
    pub dist: u32,
}

/// encoder が使う一致探索の口。逐次の BT4 と、並列に求めておいた一致の読み出しを差し替える。
pub trait Finder {
    /// pos の一致候補（長さ昇順、規則で切り詰め済み）を out へ入れる。pos は昇順に呼ばれる。
    fn find(&mut self, data: &[u8], pos: usize, scope: &Scope, out: &mut Vec<Match>);
    /// pos の一致は使わないが、索引は進める。
    fn skip(&mut self, data: &[u8], pos: usize);
}

pub const HASH3_BITS: u32 = 18;
pub const MUL: u32 = 0x9E37_79B1;

/// 定数 d での余りを乗算2回で求める（Lemire の fastmod、a と d は 2^32 未満）。
/// 巡回配列の長さは2の冪とは限らないため、除算命令を避けるのに使う。
#[derive(Clone, Copy)]
pub struct FastMod {
    d: u64,
    m: u64,
}

impl FastMod {
    pub fn new(d: usize) -> Result<Self, &'static str> {
        let d = d as u64;
        if d == 0 || d >= 1 << 32 {
            return Err("LLZ cyclic size out of range");
        }
        Ok(Self {
            d,
            m: (u64::MAX / d).wrapping_add(1),
        })
    }

    /// a % d（a < 2^32）。
    #[inline(always)]
    pub fn rem(&self, a: usize) -> usize {
        let low = self.m.wrapping_mul(a as u64);
        ((low as u128 * self.d as u128) >> 64) as usize
    }
}

/// pos が同じ byte の連続の内側か（直前 byte と続く 4byte がすべて同じ）。
/// 内側の位置は木へ入れない。どの連続も先頭の位置は木に入るため、後の位置からは先頭を通して見つかる。
#[inline(always)]
pub fn is_run_inside(data: &[u8], pos: usize, w: u32) -> bool {
    pos > 0 && w == (data[pos - 1] as u32).wrapping_mul(0x0101_0101)
}

/// run の内側の位置の一致（距離1、規則で切り詰めた長さが2以上なら）。
#[inline(always)]
pub fn run_match(data: &[u8], pos: usize, limit: usize, scope: &Scope) -> Option<Match> {
    let len = scope.clip(pos, pos - 1, common(data, pos - 1, &data[pos..], 0, limit));
    (len >= 2).then_some(Match {
        len: len as u32,
        dist: 0,
    })
}

/// 4byte hash の幅（窓長の log2、16〜24）。
pub fn hash_bits_for(window: usize) -> u32 {
    window.max(1 << 16).ilog2().clamp(16, 24)
}

/// data[p..] と cur の共通長（from から数え始め、limit で打ち切る）。
#[inline(always)]
pub fn common(data: &[u8], p: usize, cur: &[u8], from: usize, limit: usize) -> usize {
    let a = &data[p..p + limit];
    let b = &cur[..limit];
    let mut len = from;
    // 16byte ずつ SSE2 で比べ、違う位置は一致 mask の最下位の 0 で求める（結果は 8byte 比較と同じ）。
    #[cfg(target_arch = "x86_64")]
    while len + 16 <= limit {
        use std::arch::x86_64::{_mm_cmpeq_epi8, _mm_loadu_si128, _mm_movemask_epi8};
        // SAFETY: len + 16 <= limit = a.len() = b.len() なので 16byte の読み出しは両 slice の内側。
        // SSE2 は x86_64 の必須機能。
        let eq = unsafe {
            let x = _mm_loadu_si128(a.as_ptr().add(len).cast());
            let y = _mm_loadu_si128(b.as_ptr().add(len).cast());
            _mm_movemask_epi8(_mm_cmpeq_epi8(x, y)) as u32
        };
        if eq != 0xFFFF {
            return len + (!eq).trailing_zeros() as usize;
        }
        len += 16;
    }
    // 8byte ずつ比べ、違う位置は xor の下位 0 bit 数で求める。
    while len + 8 <= limit {
        let x = u64::from_le_bytes(a[len..len + 8].try_into().unwrap())
            ^ u64::from_le_bytes(b[len..len + 8].try_into().unwrap());
        if x != 0 {
            return len + (x.trailing_zeros() / 8) as usize;
        }
        len += 8;
    }
    while len < limit && a[len] == b[len] {
        len += 1;
    }
    len
}
