//! 長距離LZ試作の一致探索（BT4：2/3byte hash の候補＋4byte hash から辿る二分木）。
//! 二分木は窓長の巡回配列に置き、位置は「絶対位置+1」（0は空）で持つ。
//! 絶対位置で持つため、巡回で上書きされた古い節も距離検査だけで窓外として切れる。

/// 1回の一致の最大長（LZMA と同じ 273）。
pub const MAX_LEN: usize = 273;

/// 1 位置で parse へ渡す一致の最大数（長い方から）。製品の `src/lhc/longlz/par.rs` と同じ値。
pub const MAX_PAIRS: usize = 16;

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

impl Finder for Bt4 {
    fn find(&mut self, data: &[u8], pos: usize, scope: &Scope, out: &mut Vec<Match>) {
        Bt4::find(self, data, pos, scope, out);
    }

    fn skip(&mut self, data: &[u8], pos: usize) {
        Bt4::skip(self, data, pos);
    }
}

/// 定数 d での余りを乗算2回で求める（Lemire の fastmod、a と d は 2^32 未満）。
/// 巡回配列の長さは2の冪とは限らないため、除算命令を避けるのに使う。
#[derive(Clone, Copy)]
pub struct FastMod {
    d: u64,
    m: u64,
}

impl FastMod {
    pub fn new(d: usize) -> Self {
        let d = d as u64;
        assert!(d > 0 && d < 1 << 32, "FastMod needs 0 < d < 2^32");
        Self {
            d,
            m: (u64::MAX / d).wrapping_add(1),
        }
    }

    /// a % d（a < 2^32）。
    #[inline(always)]
    pub fn rem(&self, a: usize) -> usize {
        let low = self.m.wrapping_mul(a as u64);
        ((low as u128 * self.d as u128) >> 64) as usize
    }
}

pub struct Bt4 {
    window: usize,
    modw: FastMod,
    son: Vec<u32>,
    head2: Vec<u32>,
    head3: Vec<u32>,
    head4: Vec<u32>,
    hash_bits: u32,
    cut: u32,
}

pub const HASH3_BITS: u32 = 18;
pub const MUL: u32 = 0x9E37_79B1;

impl Bt4 {
    /// window: 参照できる最大距離（byte）。cut: 二分木で辿る節の上限。
    pub fn new(window: usize, cut: u32) -> Self {
        // 4byte hash の表は窓の半分程度（最大 2^24）に抑える。
        let hash_bits = hash_bits_for(window);
        Self {
            window,
            modw: FastMod::new(window),
            son: vec![0; window * 2],
            head2: vec![0; 1 << 16],
            head3: vec![0; 1 << HASH3_BITS],
            head4: vec![0; 1 << hash_bits],
            hash_bits,
            cut,
        }
    }

    /// pos の一致候補を長さの昇順で out へ入れ、pos を索引へ加える。
    pub fn find(&mut self, data: &[u8], pos: usize, scope: &Scope, out: &mut Vec<Match>) {
        out.clear();
        self.step(data, pos, Some((out, scope)));
        // 製品と同じく、parse へ渡す一致は長い方から MAX_PAIRS 個まで。
        if out.len() > MAX_PAIRS {
            out.drain(..out.len() - MAX_PAIRS);
        }
    }

    /// pos を索引へ加えるだけ（一致は求めない）。
    pub fn skip(&mut self, data: &[u8], pos: usize) {
        self.step(data, pos, None);
    }

    #[inline(always)]
    fn step(&mut self, data: &[u8], pos: usize, mut out: Option<(&mut Vec<Match>, &Scope)>) {
        let avail = data.len() - pos;
        let ci = self.modw.rem(pos);
        if avail < 4 {
            // 末尾の3byte未満は索引に入れない。節は空にして古い枝を残さない。
            self.son[2 * ci] = 0;
            self.son[2 * ci + 1] = 0;
            return;
        }
        let limit = avail.min(MAX_LEN);
        let cur = &data[pos..];
        let w = u32::from_le_bytes([cur[0], cur[1], cur[2], cur[3]]);
        let h2 = (w & 0xFFFF) as usize;
        let h3 = ((w & 0x00FF_FFFF).wrapping_mul(MUL) >> (32 - HASH3_BITS)) as usize;
        let h4 = (w.wrapping_mul(MUL) >> (32 - self.hash_bits)) as usize;
        let c2 = self.head2[h2];
        let c3 = self.head3[h3];
        let me = pos as u32 + 1;
        if is_run_inside(data, pos, w) {
            // run の内側：木と 4byte hash の先頭は変えず、距離1の一致だけを報告する。
            self.head2[h2] = me;
            self.head3[h3] = me;
            if let Some((out, scope)) = out.as_mut() {
                out.extend(run_match(data, pos, limit, scope));
            }
            return;
        }
        let c4 = self.head4[h4];
        self.head2[h2] = me;
        self.head3[h3] = me;
        self.head4[h4] = me;

        // best は規則で切り詰めた後の長さ。木の組み替えは切り詰め前の長さで行う。
        let mut best = 1usize;
        let mut room = limit;
        if let Some((out, scope)) = out.as_mut() {
            room = limit.min(scope.end - pos);
            for (i, c) in [c2, c3].into_iter().enumerate() {
                if c == 0 || (i == 1 && c == c2) {
                    continue;
                }
                let p = c as usize - 1;
                let d = pos - p;
                if d >= self.window {
                    continue;
                }
                let len = scope.clip(pos, p, common(data, p, cur, 0, limit));
                if len > best {
                    best = len;
                    out.push(Match {
                        len: len as u32,
                        dist: (d - 1) as u32,
                    });
                }
            }
        }
        let collect = out.is_some() && best < room;

        // 二分木を辿り、pos を根として木を組み替える。
        let mut ptr0 = 2 * ci + 1;
        let mut ptr1 = 2 * ci;
        let (mut len0, mut len1) = (0usize, 0usize);
        let mut cut = self.cut;
        let mut cm = c4;
        loop {
            if cm == 0 || cut == 0 {
                self.son[ptr0] = 0;
                self.son[ptr1] = 0;
                return;
            }
            let p = cm as usize - 1;
            let d = pos - p;
            if d >= self.window {
                self.son[ptr0] = 0;
                self.son[ptr1] = 0;
                return;
            }
            cut -= 1;
            let pair = 2 * self.modw.rem(p);
            let mut len = len0.min(len1);
            if data[p + len] == cur[len] {
                len = common(data, p, cur, len + 1, limit);
                if collect && let Some((out, scope)) = out.as_mut() {
                    let eff = scope.clip(pos, p, len);
                    if eff > best {
                        best = eff;
                        out.push(Match {
                            len: eff as u32,
                            dist: (d - 1) as u32,
                        });
                    }
                }
                if len == limit {
                    self.son[ptr1] = self.son[pair];
                    self.son[ptr0] = self.son[pair + 1];
                    return;
                }
            }
            if data[p + len] < cur[len] {
                self.son[ptr1] = cm;
                ptr1 = pair + 1;
                cm = self.son[ptr1];
                len1 = len;
            } else {
                self.son[ptr0] = cm;
                ptr0 = pair;
                cm = self.son[ptr0];
                len0 = len;
            }
        }
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

/// 4byte hash の幅（窓の半分程度、最大 2^24）。計測用に環境変数 LLZ_HASH_BITS で上書きできる。
pub fn hash_bits_for(window: usize) -> u32 {
    std::env::var("LLZ_HASH_BITS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| window.max(1 << 16).ilog2())
        .clamp(16, 24)
}

/// data[p..] と cur の共通長（from から数え始め、limit で打ち切る）。
#[inline(always)]
pub fn common(data: &[u8], p: usize, cur: &[u8], from: usize, limit: usize) -> usize {
    let a = &data[p..p + limit];
    let b = &cur[..limit];
    let mut len = from;
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
