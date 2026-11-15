//! 長距離LZ試作の並列作成：4byte hash で分担した BT4 の並列探索と、segment 単位の並列 parse。
//!
//! 一致探索の結果（各位置の一致候補）はデータ・窓長・cut だけで決まり、parse の結果に依存しない。
//! そこで領域（wave の整数倍）ごとに、
//!   1. 全 thread が領域の全位置を走査し、2/3byte hash の表は各自で更新、4byte hash が自分の分担の
//!      位置だけ二分木を組み替えて一致を出す（木の節は同じ hash の節としかつながらないので、
//!      書込みは分担ごとに分かれる）。
//!   2. 求めた一致を使い、領域内の segment を並列に parse・符号化する。
//!
//! この2段を繰り返す。逐次の BT4 と同じ一致が得られるため、出力 byte は逐次版と一致する。
//!
//! 巡回配列は thread 間で共有する。thread は領域の終わりでそろうので、遅れは領域長 L 以下になる。
//! 配列長を「窓長＋L」にすると、遅れた thread がまだ読む節（距離が窓長未満）を、
//! 先行する thread が巡回で上書きすることはない。
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering::Relaxed};

use super::lzma::{Encoder, Settings, assemble, segment_scope};
use super::mf::{
    FastMod, Finder, HASH3_BITS, MAX_LEN, MAX_PAIRS, MUL, Match, Scope, common, hash_bits_for,
    is_run_inside, run_match,
};

/// 全 thread で共有する木と 4byte hash の先頭。
struct Shared {
    window: usize,
    /// 巡回配列の長さ（窓長＋領域長）での余り。
    modc: FastMod,
    son: Vec<AtomicU32>,
    head4: Vec<AtomicU32>,
    hash_bits: u32,
    cut: u32,
}

/// thread ごとの 2/3byte hash の表と、一致候補の置き場。
struct Local {
    head2: Vec<u32>,
    head3: Vec<u32>,
    pool: Vec<Match>,
    visits: u64,
    cmp_bytes: u64,
}

fn atomics(n: usize) -> Vec<AtomicU32> {
    (0..n).map(|_| AtomicU32::new(0)).collect()
}

/// 位置 pos の走査結果。分担の位置なら木探索の開始に要る値を持つ。
struct Pending {
    pos: usize,
    h4: usize,
    c2: u32,
    c3: u32,
}

/// 進行中の1位置の木探索。1節ずつ進める状態機械で、異なる木の探索を交互に進めて memory 待ちを重ねる。
#[derive(Default)]
struct Walk {
    pos: usize,
    h4: usize,
    limit: usize,
    ptr0: usize,
    ptr1: usize,
    len0: usize,
    len1: usize,
    cut: u32,
    cm: u32,
    best: usize,
    collect: bool,
    scope: Option<Scope>,
    matches: Vec<Match>,
    /// 計測用：辿った節の数と、比較で進んだ byte 数（slot を使い回しても累積する）。
    visits: u64,
    cmp_bytes: u64,
}

impl Shared {
    /// 全 thread が全位置で呼ぶ。2/3byte hash の表を進め、分担の位置なら Pending を返す。
    /// 末尾の3byte未満の位置は thread 0 が節を空にして、空の一致として Some(Err(())) を返す。
    #[inline(always)]
    fn scan(
        &self,
        data: &[u8],
        pos: usize,
        local: &mut Local,
        t: usize,
        owner: &[u8; CLASSES],
    ) -> Option<Result<Pending, ()>> {
        let avail = data.len() - pos;
        if avail < 4 {
            // 末尾の3byte未満は索引に入れない（逐次版と同じく節を空にする）。担当は thread 0。
            if t != 0 {
                return None;
            }
            let ci = self.modc.rem(pos);
            self.son[2 * ci].store(0, Relaxed);
            self.son[2 * ci + 1].store(0, Relaxed);
            return Some(Err(()));
        }
        let cur = &data[pos..];
        let w = u32::from_le_bytes([cur[0], cur[1], cur[2], cur[3]]);
        let h2 = (w & 0xFFFF) as usize;
        let h3 = ((w & 0x00FF_FFFF).wrapping_mul(MUL) >> (32 - HASH3_BITS)) as usize;
        let h4 = (w.wrapping_mul(MUL) >> (32 - self.hash_bits)) as usize;
        let me = pos as u32 + 1;
        let c2 = local.head2[h2];
        let c3 = local.head3[h3];
        local.head2[h2] = me;
        local.head3[h3] = me;
        if owner[h4 % CLASSES] as usize != t {
            return None;
        }
        Some(Ok(Pending { pos, h4, c2, c3 }))
    }

    /// 木探索を始める（4byte hash の先頭を更新し、2/3byte 候補を報告する）。
    /// 同じ木（同じ h4）の前の探索が終わってから呼ぶこと。
    #[inline(always)]
    /// run の内側の位置は木を触らずにその場で終わり、true を返す。
    fn start(&self, data: &[u8], pd: &Pending, scope: Scope, w: &mut Walk) -> bool {
        let pos = pd.pos;
        let limit = (data.len() - pos).min(MAX_LEN);
        let cur = &data[pos..];
        let word = u32::from_le_bytes([cur[0], cur[1], cur[2], cur[3]]);
        if is_run_inside(data, pos, word) {
            w.matches.clear();
            w.matches.extend(run_match(data, pos, limit, &scope));
            w.pos = pos;
            w.h4 = pd.h4;
            return true;
        }
        let c4 = self.head4[pd.h4].load(Relaxed);
        self.head4[pd.h4].store(pos as u32 + 1, Relaxed);
        w.matches.clear();
        let mut best = 1usize;
        let room = limit.min(scope.end - pos);
        for (i, c) in [pd.c2, pd.c3].into_iter().enumerate() {
            if c == 0 || (i == 1 && c == pd.c2) {
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
                w.matches.push(Match {
                    len: len as u32,
                    dist: (d - 1) as u32,
                });
            }
        }
        let ci = self.modc.rem(pos);
        w.pos = pos;
        w.h4 = pd.h4;
        w.limit = limit;
        w.ptr0 = 2 * ci + 1;
        w.ptr1 = 2 * ci;
        w.len0 = 0;
        w.len1 = 0;
        w.cut = self.cut;
        w.cm = c4;
        w.best = best;
        w.collect = best < room;
        w.scope = Some(scope);
        if c4 != 0 {
            prefetch(&self.son[2 * (self.modc.rem(c4 as usize - 1))]);
            prefetch(&data[c4 as usize - 1]);
        }
        false
    }

    /// 木探索を1節進める（逐次の Bt4 と同じ規則）。終われば true。
    #[inline(always)]
    fn advance(&self, data: &[u8], w: &mut Walk) -> bool {
        let son = &self.son;
        if w.cm == 0 || w.cut == 0 {
            son[w.ptr0].store(0, Relaxed);
            son[w.ptr1].store(0, Relaxed);
            return true;
        }
        let pos = w.pos;
        let cur = &data[pos..];
        let p = w.cm as usize - 1;
        let d = pos - p;
        if d >= self.window {
            son[w.ptr0].store(0, Relaxed);
            son[w.ptr1].store(0, Relaxed);
            return true;
        }
        w.cut -= 1;
        w.visits += 1;
        let pair = 2 * (self.modc.rem(p));
        let mut len = w.len0.min(w.len1);
        if data[p + len] == cur[len] {
            let from = len + 1;
            len = common(data, p, cur, from, w.limit);
            w.cmp_bytes += (len + 1 - from) as u64;
            if w.collect
                && let Some(scope) = w.scope
            {
                let eff = scope.clip(pos, p, len);
                if eff > w.best {
                    w.best = eff;
                    w.matches.push(Match {
                        len: eff as u32,
                        dist: (d - 1) as u32,
                    });
                }
            }
            if len == w.limit {
                son[w.ptr1].store(son[pair].load(Relaxed), Relaxed);
                son[w.ptr0].store(son[pair + 1].load(Relaxed), Relaxed);
                return true;
            }
        }
        if data[p + len] < cur[len] {
            son[w.ptr1].store(w.cm, Relaxed);
            w.ptr1 = pair + 1;
            w.cm = son[w.ptr1].load(Relaxed);
            w.len1 = len;
        } else {
            son[w.ptr0].store(w.cm, Relaxed);
            w.ptr0 = pair;
            w.cm = son[w.ptr0].load(Relaxed);
            w.len0 = len;
        }
        // 次に辿る節と、その位置の data を先に読み込ませる。
        if w.cm != 0 {
            let next = w.cm as usize - 1;
            prefetch(&son[2 * (self.modc.rem(next))]);
            prefetch(&data[next + w.len0.min(w.len1)]);
        }
        false
    }

    /// 領域 [r0, r1) を thread t の分担で探索する。最大 inflight 本の木探索を交互に進める。
    /// 返り値は分担した位置数。
    #[allow(clippy::too_many_arguments)]
    fn run_region(
        &self,
        data: &[u8],
        (r0, r1): (usize, usize),
        (segment, wave): (usize, usize),
        local: &mut Local,
        t: usize,
        owner: &[u8; CLASSES],
        index: &[AtomicU64],
        inflight: usize,
    ) -> u64 {
        let n = data.len();
        let mut slots: Vec<Walk> = (0..inflight).map(|_| Walk::default()).collect();
        let mut busy = vec![false; inflight];
        let mut owned = 0u64;
        local.pool.clear();
        // 終わった探索の一致を pool へ移し、位置の所在を記録する。
        let finish = |w: &Walk, pool: &mut Vec<Match>| {
            let start = pool.len();
            let keep = &w.matches[w.matches.len().saturating_sub(MAX_PAIRS)..];
            pool.extend_from_slice(keep);
            index[w.pos - r0].store(pack(t, start, keep.len()), Relaxed);
        };
        let mut rr = 0usize;
        // 計測用：木を辿らない（一致は不完全になる）。探索以外の費用を切り分けるため。
        let nowalk = std::env::var("LLZ_NOWALK").is_ok_and(|v| v == "1");
        let mut scope = segment_scope(n, segment, wave, r0 / segment);
        for pos in r0..r1 {
            self.prefetch_ahead(data, pos, t, owner);
            let Some(scanned) = self.scan(data, pos, local, t, owner) else {
                continue;
            };
            owned += 1;
            let Ok(pd) = scanned else {
                index[pos - r0].store(pack(t, local.pool.len(), 0), Relaxed);
                continue;
            };
            // 同じ木の探索が進行中なら、先に終わらせる（木の組み替えは位置順でなければならない）。
            for i in 0..inflight {
                if busy[i] && slots[i].h4 == pd.h4 {
                    while !self.advance(data, &mut slots[i]) {}
                    finish(&slots[i], &mut local.pool);
                    busy[i] = false;
                }
            }
            // 空きが出るまで、進行中の探索を順に1節ずつ進める。
            let free = loop {
                if let Some(i) = busy.iter().position(|b| !b) {
                    break i;
                }
                if self.advance(data, &mut slots[rr]) {
                    finish(&slots[rr], &mut local.pool);
                    busy[rr] = false;
                }
                rr = (rr + 1) % inflight;
            };
            // segment の範囲は segment が変わったときだけ求め直す（位置ごとの除算を避ける）。
            if pos >= scope.end || pos < scope.seg_start {
                scope = segment_scope(n, segment, wave, pos / segment);
            }
            if self.start(data, &pd, scope, &mut slots[free]) || nowalk {
                finish(&slots[free], &mut local.pool);
            } else {
                busy[free] = true;
            }
            // 進行中の探索をそれぞれ1節進める。
            for i in 0..inflight {
                if busy[i] && self.advance(data, &mut slots[i]) {
                    finish(&slots[i], &mut local.pool);
                    busy[i] = false;
                }
            }
        }
        for i in 0..inflight {
            if busy[i] {
                while !self.advance(data, &mut slots[i]) {}
                finish(&slots[i], &mut local.pool);
                busy[i] = false;
            }
        }
        for w in &slots {
            local.visits += w.visits;
            local.cmp_bytes += w.cmp_bytes;
        }
        owned
    }
}

/// 4byte hash の区分数。区分ごとの位置数を数え、領域ごとに thread へ割り当てる。
const CLASSES: usize = 256;

/// 領域 [r0, r1) の位置数が均等になるよう、hash 区分を thread へ割り当てる（多い区分から順に、
/// その時点で最も軽い thread へ）。どの thread が担当しても一致の結果は変わらない。
fn assign(shared: &Shared, data: &[u8], r0: usize, r1: usize, threads: usize) -> [u8; CLASSES] {
    let mut count = [0u64; CLASSES];
    for pos in r0..r1 {
        if let Some(h) = shared.hash4(data, pos) {
            count[h % CLASSES] += 1;
        }
    }
    let mut order: Vec<usize> = (0..CLASSES).collect();
    order.sort_by_key(|&c| std::cmp::Reverse(count[c]));
    let mut load = vec![0u64; threads];
    let mut owner = [0u8; CLASSES];
    for c in order {
        let t = (0..threads).min_by_key(|&t| load[t]).unwrap_or(0);
        owner[c] = t as u8;
        load[t] += count[c];
    }
    owner
}

/// hash 先頭を先読みする距離（位置数）。
const AHEAD_FAR: usize = 24;

/// cache へ読み込むよう CPU へ伝えるだけで、値も索引の状態も変えない。
#[inline(always)]
fn prefetch<T>(r: &T) {
    // SAFETY: prefetch は番地を読み書きせず、無効な番地でも例外を起こさない。x86_64 は SSE を常に持つ。
    #[cfg(target_arch = "x86_64")]
    unsafe {
        std::arch::x86_64::_mm_prefetch::<{ std::arch::x86_64::_MM_HINT_T0 }>(
            (r as *const T).cast::<i8>(),
        );
    }
    #[cfg(not(target_arch = "x86_64"))]
    let _ = r;
}

impl Shared {
    #[inline(always)]
    fn hash4(&self, data: &[u8], pos: usize) -> Option<usize> {
        let b = data.get(pos..pos + 4)?;
        let w = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
        Some((w.wrapping_mul(MUL) >> (32 - self.hash_bits)) as usize)
    }

    /// 少し先の分担位置について、4byte hash の先頭を先に読み込ませる（結果は変えない）。
    #[inline(always)]
    fn prefetch_ahead(&self, data: &[u8], pos: usize, t: usize, owner: &[u8; CLASSES]) {
        if let Some(h) = self.hash4(data, pos + AHEAD_FAR)
            && owner[h % CLASSES] as usize == t
        {
            prefetch(&self.head4[h]);
        }
    }
}

/// 位置ごとの一致の所在（thread 8bit | 個数 16bit | 開始 40bit）。
#[inline(always)]
fn pack(t: usize, start: usize, count: usize) -> u64 {
    ((t as u64) << 56) | ((count as u64) << 40) | start as u64
}

/// 並列探索で求めた一致を、encoder へ位置順に渡す探索器。
struct Pre<'r> {
    region_start: usize,
    index: &'r [AtomicU64],
    pools: &'r [&'r [Match]],
}

impl Finder for Pre<'_> {
    fn find(&mut self, _data: &[u8], pos: usize, _scope: &Scope, out: &mut Vec<Match>) {
        out.clear();
        let e = self.index[pos - self.region_start].load(Relaxed);
        let t = (e >> 56) as usize;
        let count = ((e >> 40) & 0xFFFF) as usize;
        let start = (e & ((1 << 40) - 1)) as usize;
        out.extend_from_slice(&self.pools[t][start..start + count]);
    }

    fn skip(&mut self, _data: &[u8], _pos: usize) {}
}

/// 計測用の内訳（探索と parse の壁時計）。
#[derive(Default, Debug)]
pub struct Timing {
    pub find_secs: f64,
    pub parse_secs: f64,
    /// thread ごとの探索時間の合計と、分担した位置数（偏りの確認用）。
    pub thread_secs: Vec<f64>,
    pub thread_owned: Vec<u64>,
    /// 全 thread の、辿った節の数と比較で進んだ byte 数。
    pub visits: u64,
    pub cmp_bytes: u64,
}

/// segment 形式を threads 本で並列に作る。出力は逐次の Encoder::encode と同じ byte になる。
pub fn encode_parallel(data: &[u8], s: &Settings, threads: usize) -> (Vec<u8>, Timing) {
    let n = data.len();
    let threads = threads.clamp(1, 255);
    let segment = if s.segment == 0 { n.max(1) } else { s.segment };
    let wave = s.wave.max(1);
    // 領域は wave の整数倍で、約 4MiB。
    let unit = segment * wave;
    let region = unit * ((4usize << 20) / unit).max(1);
    let window = s.window;
    let cyc = window + region;
    let hash_bits = hash_bits_for(window);
    let shared = Shared {
        window,
        modc: FastMod::new(cyc),
        son: atomics(cyc * 2),
        head4: atomics(1 << hash_bits),
        hash_bits,
        cut: s.cut,
    };
    // 1 thread が同時に進める木探索の数（計測用に LLZ_INFLIGHT で変えられる。1 なら交互に進めない）。
    let inflight = std::env::var("LLZ_INFLIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8usize)
        .clamp(1, 64);
    let mut locals: Vec<Local> = (0..threads)
        .map(|_| Local {
            head2: vec![0; 1 << 16],
            head3: vec![0; 1 << HASH3_BITS],
            pool: Vec::new(),
            visits: 0,
            cmp_bytes: 0,
        })
        .collect();
    let index: Vec<AtomicU64> = (0..region.min(n.max(1)))
        .map(|_| AtomicU64::new(0))
        .collect();
    let mut bodies: Vec<Vec<u8>> = Vec::new();
    let mut timing = Timing {
        thread_secs: vec![0.0; threads],
        thread_owned: vec![0; threads],
        ..Timing::default()
    };
    let mut r0 = 0usize;
    while r0 < n || bodies.is_empty() {
        let r1 = (r0 + region).min(n);
        // 1. 並列探索。
        let t0 = std::time::Instant::now();
        let owner = &assign(&shared, data, r0, r1, threads);
        let stats: Vec<(f64, u64)> = std::thread::scope(|sc| {
            let handles: Vec<_> = locals
                .iter_mut()
                .enumerate()
                .map(|(t, local)| {
                    let shared = &shared;
                    let index = &index;
                    sc.spawn(move || {
                        let tt = std::time::Instant::now();
                        let owned = shared.run_region(
                            data,
                            (r0, r1),
                            (segment, wave),
                            local,
                            t,
                            owner,
                            index,
                            inflight,
                        );
                        (tt.elapsed().as_secs_f64(), owned)
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().expect("find worker panicked"))
                .collect()
        });
        for (t, (secs, owned)) in stats.into_iter().enumerate() {
            timing.thread_secs[t] += secs;
            timing.thread_owned[t] += owned;
        }
        let t1 = std::time::Instant::now();
        timing.find_secs += (t1 - t0).as_secs_f64();
        // 2. segment 単位の並列 parse。
        let pools: Vec<&[Match]> = locals.iter().map(|l| l.pool.as_slice()).collect();
        let first = r0 / segment;
        let last = r1.div_ceil(segment).max(first + 1);
        let ks: Vec<usize> = (first..last).collect();
        let per = ks.len().div_ceil(threads).max(1);
        let mut parts: Vec<(usize, Vec<u8>)> = std::thread::scope(|sc| {
            let handles: Vec<_> = ks
                .chunks(per)
                .map(|group| {
                    let pools = &pools;
                    let index = &index;
                    sc.spawn(move || {
                        group
                            .iter()
                            .map(|&k| {
                                let pre = Pre {
                                    region_start: r0,
                                    index,
                                    pools,
                                };
                                let mut enc = Encoder::with_finder(data, s, pre);
                                (k, enc.encode_segment(segment_scope(n, segment, wave, k)))
                            })
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|h| h.join().expect("parse worker panicked"))
                .collect()
        });
        parts.sort_by_key(|(k, _)| *k);
        bodies.extend(parts.into_iter().map(|(_, b)| b));
        timing.parse_secs += t1.elapsed().as_secs_f64();
        r0 = r1;
        if n == 0 {
            break;
        }
    }
    timing.visits = locals.iter().map(|l| l.visits).sum();
    timing.cmp_bytes = locals.iter().map(|l| l.cmp_bytes).sum();
    (
        assemble(n, segment, wave, window, s.near, &s.var, bodies),
        timing,
    )
}
