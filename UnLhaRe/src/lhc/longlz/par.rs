//! 長距離LZ（LLZ1BLK）の並列作成：4byte hash で分担した BT4 の並列探索と、segment 単位の並列 parse。
//!
//! 一致探索の結果（各位置の一致候補）はデータ・窓長・cut だけで決まり、parse の結果に依存しない。
//! そこで file を探索単位（`Plan::find_unit`）ごとに進め、
//!   0. 前処理（1 thread）が単位の全位置で 2/3byte hash の表を位置順に進め、4byte hash の区分を
//!      thread へ割り当てて、各位置の値（2/3byte の候補・4byte hash）を担当 thread ごとに位置順に並べる。
//!      前処理は木を触らないので、次の単位の前処理を今の単位の探索と同時に行う。
//!   1. 各 thread が自分の分担の位置だけを位置順に辿り、二分木を組み替えて一致を出す（木の節は同じ
//!      hash の節としかつながらないので、書込みは分担ごとに分かれる）。
//!   2. 探索が終わった segment が `Plan::batch` 個たまったら（または一致置き場が予算に迫ったら）、
//!      それらの segment を並列に parse・符号化し、body を順に sink へ渡して置き場を解放する。
//!
//! この2段を繰り返す。逐次の BT4 と同じ一致が得られるため、出力 byte は逐次版と一致する。
//! 探索単位・batch の大きさ・置き場の予算は出力 byte に影響しない（各 segment の parse は
//! 自分の位置の一致だけを読み、一致は探索単位の切り方によらず同じため）。
//!
//! 巡回配列は thread 間で共有する。thread は探索単位の終わりでそろうので、遅れは単位長 L 以下になる。
//! 配列長を「窓長＋L」にすると、遅れた thread がまだ読む節（距離が窓長未満）を、
//! 先行する thread が巡回で上書きすることはない。遅れの上限は parse の batch の大きさと無関係なので、
//! 探索単位を小さく（revision 14 は 1MiB）しても batch は大きく（4 segment＝16MiB）できる。
//!
//! 一致置き場は (thread, segment 用の slot) ごとの固定長 chunk の列で、chunk は全 thread で共有する
//! 空き列から取る。parse を終えた segment の chunk は空き列へ戻して再利用する。
use std::sync::{
    Mutex,
    atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering::Relaxed},
};

use super::codec::{Encoder, SegOut, Settings, segment_scope};
use super::mf::{
    FastMod, Finder, HASH3_BITS, MAX_LEN, MUL, Match, Scope, common, hash_bits_for, is_run_inside,
    run_match,
};
use super::rc::{Coder, DualEnc, RangeEnc};

/// 全 thread で共有する木と 4byte hash の先頭。
struct Shared {
    window: usize,
    /// 巡回配列の長さ（窓長＋探索単位）での余り。
    modc: FastMod,
    /// 巡回配列の長さ（窓長＋探索単位）。
    cyc: usize,
    son: Vec<AtomicU32>,
    head4: Vec<AtomicU32>,
    hash_bits: u32,
    cut: u32,
}

/// thread ごとの一致候補の置き場。
struct Local {
    /// slot ごとの chunk 列（slot は segment 番号 % batch）。
    slots: Vec<Vec<Vec<Match>>>,
    /// chunk を確保できなかった。作成全体を失敗させる。
    failed: bool,
}

/// 一致置き場の chunk（容量 `cl` 個の Match）の共有の空き列。
struct Chunks {
    cl: usize,
    free: Mutex<Vec<Vec<Match>>>,
    created: AtomicUsize,
}

impl Chunks {
    /// 空き列にあれば再利用し、なければ新しく確保する（確保に失敗したら None）。
    fn take(&self) -> Option<Vec<Match>> {
        if let Some(c) = self.free.lock().unwrap_or_else(|e| e.into_inner()).pop() {
            return Some(c);
        }
        let mut c: Vec<Match> = Vec::new();
        c.try_reserve_exact(self.cl).ok()?;
        self.created.fetch_add(1, Relaxed);
        Some(c)
    }

    fn give(&self, mut c: Vec<Match>) {
        c.clear();
        self.free.lock().unwrap_or_else(|e| e.into_inner()).push(c);
    }

    /// 使用中の chunk 数（thread が動いていない時点で呼ぶ）。
    fn in_use(&self) -> usize {
        self.created.load(Relaxed) - self.free.lock().unwrap_or_else(|e| e.into_inner()).len()
    }
}

impl Local {
    /// slot の置き場へ一致を追加し、位置の所在（chunk 番号 × cl ＋ chunk 内の位置）を返す。
    /// 1 位置の一致は chunk をまたがない。確保に失敗したら failed を立てて 0 を返す。
    #[inline(always)]
    fn store(&mut self, slot: usize, keep: &[Match], chunks: &Chunks) -> usize {
        if keep.is_empty() {
            return 0;
        }
        let list = &mut self.slots[slot];
        if list.last().is_none_or(|c| c.len() + keep.len() > chunks.cl) {
            match chunks.take() {
                Some(c) => list.push(c),
                None => {
                    self.failed = true;
                    return 0;
                }
            }
        }
        let at = list.len() - 1;
        let c = &mut list[at];
        let start = at * chunks.cl + c.len();
        c.extend_from_slice(keep);
        start
    }
}

/// 位置索引と置き場の配置（run_region が位置から所在を引く）。
struct Geom<'a> {
    /// slot ごとに seg_len 個の索引（slot の中は segment 内の位置）。
    index: &'a [AtomicU64],
    seg_shift: u32,
    seg_mask: usize,
    seg_len: usize,
    slots: usize,
    chunks: &'a Chunks,
}

impl Geom<'_> {
    #[inline(always)]
    fn slot_of(&self, pos: usize) -> usize {
        (pos >> self.seg_shift) % self.slots
    }

    #[inline(always)]
    fn entry(&self, pos: usize) -> &AtomicU64 {
        &self.index[self.slot_of(pos) * self.seg_len + (pos & self.seg_mask)]
    }
}

fn atomics(n: usize) -> Vec<AtomicU32> {
    (0..n).map(|_| AtomicU32::new(0)).collect()
}

/// 位置 pos の木探索の開始に要る値。探索単位ごとに前処理で求め、担当 thread ごとに位置順に並べる。
#[derive(Clone, Copy, Default)]
struct Pending {
    pos: u32,
    h4: u32,
    c2: u32,
    c3: u32,
}

/// 2/3byte hash の表（全位置を位置順に進める。前処理を行う1 thread だけが持つ）。
struct Hasher {
    head2: Vec<u32>,
    head3: Vec<u32>,
}

/// 探索単位の前処理の結果：thread ごとに、分担の位置の Pending を位置順に並べたもの。
#[derive(Default)]
struct Prep {
    items: Vec<Pending>,
    /// thread t の分担は items[starts[t]..starts[t + 1]]。
    starts: Vec<usize>,
}

/// 進行中の1位置の木探索。1節ずつ進める状態機械で、異なる木の探索を交互に進めて memory 待ちを重ねる。
#[derive(Default)]
struct Walk {
    pos: usize,
    /// pos の巡回配列での位置（pos % cyc）。辿る節の位置は距離を引いて求め、除算を避ける。
    cip: usize,
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
}

impl Shared {
    /// 探索単位 [r0, r1) の前処理。4byte hash の区分（4byte hash % CLASSES）を位置数が均等になるよう
    /// threads 本へ割り当て（多い区分から順に、その時点で最も軽い thread へ）、2/3byte hash の表を
    /// 位置順に進めながら、各位置の値を担当 thread ごとに位置順に並べる。同じ木（同じ 4byte hash）の位置は
    /// 同じ thread に入る。末尾の3byte未満の位置は含めない（節を空にする処理は `clear_tail` が行う）。
    /// 木は触らないので、前の単位の探索と同時に行える。2/3byte の候補は全位置で同じ表を進めた値なので、
    /// どの thread が担当しても一致の結果は変わらない。
    fn prepare(
        &self,
        data: &[u8],
        (r0, r1): (usize, usize),
        threads: usize,
        hs: &mut Hasher,
        prep: &mut Prep,
    ) {
        let end = r1.min(data.len().saturating_sub(3)).max(r0);
        let mut count = [0usize; CLASSES];
        for pos in r0..end {
            if let Some(h) = self.hash4(data, pos) {
                count[h % CLASSES] += 1;
            }
        }
        let mut order: Vec<usize> = (0..CLASSES).collect();
        order.sort_by_key(|&c| std::cmp::Reverse(count[c]));
        let mut load = vec![0usize; threads];
        let mut owner = [0u8; CLASSES];
        for c in order {
            let t = (0..threads).min_by_key(|&t| load[t]).unwrap_or(0);
            owner[c] = t as u8;
            load[t] += count[c];
        }
        prep.starts.clear();
        prep.starts.push(0);
        let mut acc = 0usize;
        for l in &load {
            acc += l;
            prep.starts.push(acc);
        }
        prep.items.clear();
        prep.items.resize(acc, Pending::default());
        let mut fill: Vec<usize> = prep.starts[..threads].to_vec();
        for pos in r0..end {
            let cur = &data[pos..];
            let w = u32::from_le_bytes([cur[0], cur[1], cur[2], cur[3]]);
            let h2 = (w & 0xFFFF) as usize;
            let h3 = ((w & 0x00FF_FFFF).wrapping_mul(MUL) >> (32 - HASH3_BITS)) as usize;
            let h4 = (w.wrapping_mul(MUL) >> (32 - self.hash_bits)) as usize;
            let me = pos as u32 + 1;
            let c2 = hs.head2[h2];
            let c3 = hs.head3[h3];
            hs.head2[h2] = me;
            hs.head3[h3] = me;
            let f = &mut fill[owner[h4 % CLASSES] as usize];
            prep.items[*f] = Pending {
                pos: pos as u32,
                h4: h4 as u32,
                c2,
                c3,
            };
            *f += 1;
        }
    }

    /// 探索単位 [r0, r1) のうち末尾の3byte未満の位置を、索引に入れず（逐次版と同じく節を空にして）
    /// 空の一致として記録する。その単位の探索の worker を動かす前に呼ぶ。
    fn clear_tail(&self, data: &[u8], (r0, r1): (usize, usize), geom: &Geom) {
        for pos in r0.max(data.len().saturating_sub(3))..r1 {
            let ci = self.modc.rem(pos);
            self.son[2 * ci].store(0, Relaxed);
            self.son[2 * ci + 1].store(0, Relaxed);
            geom.entry(pos).store(pack(0, 0, 0), Relaxed);
        }
    }

    /// 木探索を始める（4byte hash の先頭を更新し、2/3byte 候補を報告する）。
    /// 同じ木（同じ h4）の前の探索が終わってから呼ぶこと。
    #[inline(always)]
    /// run の内側の位置は木を触らずにその場で終わり、true を返す。
    fn start(&self, data: &[u8], pd: &Pending, scope: Scope, w: &mut Walk) -> bool {
        let pos = pd.pos as usize;
        let h4 = pd.h4 as usize;
        let limit = (data.len() - pos).min(MAX_LEN);
        let cur = &data[pos..];
        let word = u32::from_le_bytes([cur[0], cur[1], cur[2], cur[3]]);
        if is_run_inside(data, pos, word) {
            w.matches.clear();
            w.matches.extend(run_match(data, pos, limit, &scope));
            w.pos = pos;
            w.h4 = h4;
            return true;
        }
        let c4 = self.head4[h4].load(Relaxed);
        self.head4[h4].store(pos as u32 + 1, Relaxed);
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
        w.cip = ci;
        w.h4 = h4;
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
        let pair = 2 * self.cyc_index(w.cip, d);
        let mut len = w.len0.min(w.len1);
        if data[p + len] == cur[len] {
            len = common(data, p, cur, len + 1, w.limit);
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
            let nd = pos - next;
            if nd < self.window {
                prefetch(&son[2 * self.cyc_index(w.cip, nd)]);
                prefetch(&data[next + w.len0.min(w.len1)]);
            }
        }
        false
    }

    /// 探索単位の前処理 prep のうち thread t の分担の位置を位置順に探索する。
    /// 最大 inflight 本の木探索を交互に進める。
    #[allow(clippy::too_many_arguments)]
    fn run_owned(
        &self,
        data: &[u8],
        prep: &Prep,
        (segment, wave): (usize, usize),
        local: &mut Local,
        t: usize,
        geom: &Geom,
        inflight: usize,
    ) {
        let n = data.len();
        let mut slots: Vec<Walk> = (0..inflight).map(|_| Walk::default()).collect();
        let mut busy = vec![false; inflight];
        // 終わった探索の一致を置き場へ移し、位置の所在を記録する。
        let finish = |w: &Walk, local: &mut Local| {
            let keep = &w.matches[w.matches.len().saturating_sub(MAX_PAIRS)..];
            let slot = geom.slot_of(w.pos);
            let start = local.store(slot, keep, geom.chunks);
            geom.entry(w.pos).store(pack(t, start, keep.len()), Relaxed);
        };
        let mut rr = 0usize;
        let mut scope = segment_scope(n, segment, wave, 0);
        let items = &prep.items[prep.starts[t]..prep.starts[t + 1]];
        for (j, &pd) in items.iter().enumerate() {
            // 少し先の位置の 4byte hash の先頭を先に読み込ませる（結果は変えない）。
            if let Some(a) = items.get(j + AHEAD_FAR) {
                prefetch(&self.head4[a.h4 as usize]);
            }
            let pos = pd.pos as usize;
            // 同じ木の探索が進行中なら、先に終わらせる（木の組み替えは位置順でなければならない）。
            // 待つ間も他の探索を1節ずつ進め、memory 待ちを重ねる（各探索の結果は進め方によらない）。
            if let Some(c) = (0..inflight).find(|&i| busy[i] && slots[i].h4 == pd.h4 as usize) {
                while busy[c] {
                    for i in 0..inflight {
                        if busy[i] && self.advance(data, &mut slots[i]) {
                            finish(&slots[i], local);
                            busy[i] = false;
                        }
                    }
                }
            }
            // 空きが出るまで、進行中の探索を順に1節ずつ進める。
            let free = loop {
                if let Some(i) = busy.iter().position(|b| !b) {
                    break i;
                }
                if self.advance(data, &mut slots[rr]) {
                    finish(&slots[rr], local);
                    busy[rr] = false;
                }
                rr = (rr + 1) % inflight;
            };
            // segment の範囲は segment が変わったときだけ求め直す（位置ごとの除算を避ける）。
            if pos >= scope.end || pos < scope.seg_start {
                scope = segment_scope(n, segment, wave, pos / segment);
            }
            if self.start(data, &pd, scope, &mut slots[free]) {
                finish(&slots[free], local);
            } else {
                busy[free] = true;
            }
            // 進行中の探索をそれぞれ1節進める。
            for i in 0..inflight {
                if busy[i] && self.advance(data, &mut slots[i]) {
                    finish(&slots[i], local);
                    busy[i] = false;
                }
            }
        }
        for i in 0..inflight {
            if busy[i] {
                while !self.advance(data, &mut slots[i]) {}
                finish(&slots[i], local);
                busy[i] = false;
            }
        }
    }
}

/// 4byte hash の区分数。区分ごとの位置数を数え、探索単位ごとに thread へ割り当てる。
const CLASSES: usize = 256;

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
    /// 巡回配列で pos（位置 cip）から距離 d（1..窓長）だけ前の位置。cip - d を巡回させる。
    #[inline(always)]
    fn cyc_index(&self, cip: usize, d: usize) -> usize {
        if cip >= d {
            cip - d
        } else {
            cip + self.cyc - d
        }
    }

    #[inline(always)]
    fn hash4(&self, data: &[u8], pos: usize) -> Option<usize> {
        let b = data.get(pos..pos + 4)?;
        let w = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
        Some((w.wrapping_mul(MUL) >> (32 - self.hash_bits)) as usize)
    }
}

/// 位置ごとの一致の所在（thread 8bit | 個数 16bit | 開始 40bit）。
#[inline(always)]
fn pack(t: usize, start: usize, count: usize) -> u64 {
    ((t as u64) << 56) | ((count as u64) << 40) | start as u64
}

/// 並列探索で求めた一致を、encoder へ位置順に渡す探索器（1 segment 分）。
struct Pre<'r> {
    seg_start: usize,
    /// この segment の slot の索引の先頭。
    base: usize,
    slot: usize,
    cl_shift: u32,
    index: &'r [AtomicU64],
    locals: &'r [Local],
}

impl Finder for Pre<'_> {
    fn find(&mut self, _data: &[u8], pos: usize, _scope: &Scope, out: &mut Vec<Match>) {
        out.clear();
        let e = self.index[self.base + pos - self.seg_start].load(Relaxed);
        let t = (e >> 56) as usize;
        let count = ((e >> 40) & 0xFFFF) as usize;
        if count == 0 {
            return;
        }
        let start = (e & ((1 << 40) - 1)) as usize;
        let chunk = &self.locals[t].slots[self.slot][start >> self.cl_shift];
        let off = start & ((1 << self.cl_shift) - 1);
        out.extend_from_slice(&chunk[off..off + count]);
    }

    fn skip(&mut self, _data: &[u8], _pos: usize) {}
}

/// 1 thread が同時に進める木探索の数。
const INFLIGHT: usize = 8;

/// 1 位置で parse へ渡す一致の最大数（長い方から）。一致置き場の上限を決める。
/// 最悪でも 位置数 × MAX_PAIRS × 8B に収まる（通常はその 1/4 未満）。
pub const MAX_PAIRS: usize = 16;

/// 並列作成の配分（形式ではなく、出力 byte に影響しない資源の割り当て）。
#[derive(Clone, Copy, Debug)]
pub struct Plan {
    /// 探索の同期単位（byte）。巡回配列は窓長＋この長さ。segment の約数、または batch 個以下の
    /// segment の整数倍。
    pub find_unit: usize,
    /// 同時に置き場を持ち、並列に parse する segment の最大数。
    pub batch: usize,
    /// 一致置き場の確保量の目標上限（byte）。usize::MAX なら制限しない。
    pub pool_budget: usize,
    /// 置き場の 1 chunk の Match 数（2 の冪）。
    pub chunk_matches: usize,
}

/// 作成の実測値（試験と計測用）。
#[derive(Clone, Copy, Debug, Default)]
pub struct Stats {
    /// 一致置き場として使用中だった chunk の最大 byte 数（探索単位の終わりで測る）。
    pub peak_pool_bytes: usize,
    /// 予算が迫って segment の完成前に行った parse の回数。
    pub early_parses: usize,
    /// parse の batch 数。
    pub batches: usize,
}

/// 探索を終えた segment を並列に parse し、body を番号順に sink へ渡して置き場を解放する。
#[allow(clippy::too_many_arguments)]
fn parse_batch<R: Coder>(
    data: &[u8],
    s: &Settings,
    geom: &Geom,
    cl_shift: u32,
    locals: &mut [Local],
    ks: &[usize],
    threads: usize,
    sink: &mut dyn FnMut(usize, SegOut) -> Result<(), String>,
) -> Result<(), String> {
    let n = data.len();
    let (segment, wave) = (s.segment, s.wave.max(1));
    let per = ks.len().div_ceil(threads).max(1);
    let shared: &[Local] = locals;
    let mut parts: Vec<(usize, SegOut)> =
        std::thread::scope(|sc| -> Result<Vec<(usize, SegOut)>, String> {
            let handles: Vec<_> = ks
                .chunks(per)
                .map(|group| {
                    sc.spawn(move || {
                        group
                            .iter()
                            .map(|&k| {
                                let slot = k % geom.slots;
                                let pre = Pre {
                                    seg_start: k * segment,
                                    base: slot * geom.seg_len,
                                    slot,
                                    cl_shift,
                                    index: geom.index,
                                    locals: shared,
                                };
                                let mut enc: Encoder<_, R> = Encoder::with_finder(data, s, pre);
                                (k, enc.encode_segment(segment_scope(n, segment, wave, k)))
                            })
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            let mut all = Vec::new();
            for h in handles {
                all.extend(h.join().map_err(|_| "LLZ parse worker panicked")?);
            }
            Ok(all)
        })?;
    parts.sort_by_key(|(k, _)| *k);
    for (k, out) in parts {
        sink(k, out)?;
    }
    // parse を終えた segment の置き場を空き列へ戻す。
    for local in locals.iter_mut() {
        for &k in ks {
            for c in local.slots[k % geom.slots].drain(..) {
                geom.chunks.give(c);
            }
        }
    }
    Ok(())
}

/// file 全体を segment ごとの range 符号 body に符号化し、segment 番号順に sink へ渡す。
/// threads 本で並列化し、body は thread 数・plan によらず同じ byte になる。data は 4GiB 未満であること。
pub fn encode_bodies(
    data: &[u8],
    s: &Settings,
    plan: &Plan,
    threads: usize,
    sink: &mut dyn FnMut(usize, SegOut) -> Result<(), String>,
) -> Result<Stats, String> {
    // revision 15 は混合なし・ありの 2 本の符号器で同時に書く。それ以外は単一の符号器（従来と同じ code）。
    if s.dual {
        encode_bodies_with::<DualEnc>(data, s, plan, threads, sink)
    } else {
        encode_bodies_with::<RangeEnc>(data, s, plan, threads, sink)
    }
}

fn encode_bodies_with<R: Coder>(
    data: &[u8],
    s: &Settings,
    plan: &Plan,
    threads: usize,
    sink: &mut dyn FnMut(usize, SegOut) -> Result<(), String>,
) -> Result<Stats, String> {
    let n = data.len();
    if n >= u32::MAX as usize {
        return Err("LLZ input exceeds 4GiB".into());
    }
    let threads = threads.clamp(1, 255);
    let segment = s.segment.max(1);
    let unit = plan.find_unit;
    let batch = plan.batch.max(1);
    let cl = plan.chunk_matches;
    if !segment.is_power_of_two()
        || !cl.is_power_of_two()
        || unit == 0
        || !(segment.is_multiple_of(unit)
            || (unit.is_multiple_of(segment) && unit / segment <= batch))
    {
        return Err("LLZ plan is inconsistent with the segment length".into());
    }
    let wave = s.wave.max(1);
    let window = s.window;
    let cyc = window + unit;
    let hash_bits = hash_bits_for(window);
    let shared = Shared {
        window,
        cyc,
        modc: FastMod::new(cyc)?,
        son: atomics(cyc * 2),
        head4: atomics(1 << hash_bits),
        hash_bits,
        cut: s.cut,
    };
    let mut locals: Vec<Local> = (0..threads)
        .map(|_| Local {
            slots: (0..batch).map(|_| Vec::new()).collect(),
            failed: false,
        })
        .collect();
    // 2/3byte hash の表は前処理だけが持つ。前処理の結果は2組を交互に使い、次の単位の前処理を
    // 今の単位の探索と同時に行う（前処理は木を触らず、2/3byte の表は位置順に進めるだけ）。
    let mut hasher = Hasher {
        head2: vec![0; 1 << 16],
        head3: vec![0; 1 << HASH3_BITS],
    };
    let mut preps = [Prep::default(), Prep::default()];
    shared.prepare(data, (0, unit.min(n)), threads, &mut hasher, &mut preps[0]);
    let mut cur_prep = 0usize;
    let seg_len = segment.min(n.max(1));
    let index: Vec<AtomicU64> = (0..batch * seg_len).map(|_| AtomicU64::new(0)).collect();
    let chunks = Chunks {
        cl,
        free: Mutex::new(Vec::new()),
        created: AtomicUsize::new(0),
    };
    let geom = Geom {
        index: &index,
        seg_shift: segment.trailing_zeros(),
        seg_mask: segment - 1,
        seg_len,
        slots: batch,
        chunks: &chunks,
    };
    let cl_shift = cl.trailing_zeros();
    let chunk_bytes = cl * std::mem::size_of::<Match>();
    // 次の探索単位が置き場を最大でどれだけ増やすか（全位置が MAX_PAIRS 個、各 thread の端数の chunk）。
    let growth = unit
        .saturating_mul(MAX_PAIRS * std::mem::size_of::<Match>())
        .saturating_add(threads * chunk_bytes);
    let limited = plan.pool_budget != usize::MAX;
    let over = |chunks: &Chunks| {
        limited
            && chunks
                .in_use()
                .saturating_mul(chunk_bytes)
                .saturating_add(growth)
                > plan.pool_budget
    };
    let nseg = n.div_ceil(segment);
    let mut stats = Stats::default();
    let mut pending: Vec<usize> = Vec::new();
    let mut next_seg = 0usize;
    let mut r0 = 0usize;
    while r0 < n {
        let r1 = (r0 + unit).min(n);
        // 次の単位で置き場が予算を超えるおそれがあれば、完成した segment を先に parse して解放する。
        if over(&chunks) && !pending.is_empty() {
            parse_batch::<R>(
                data,
                s,
                &geom,
                cl_shift,
                &mut locals,
                &pending,
                threads,
                sink,
            )?;
            pending.clear();
            stats.early_parses += 1;
            stats.batches += 1;
        }
        if over(&chunks) {
            return Err("LLZ match store exceeds the memory budget".into());
        }
        // 1. 並列探索。
        shared.clear_tail(data, (r0, r1), &geom);
        let (a, b) = preps.split_at_mut(1);
        let (prep, prep_next) = if cur_prep == 0 {
            (&a[0], &mut b[0])
        } else {
            (&b[0], &mut a[0])
        };
        let hasher = &mut hasher;
        std::thread::scope(|sc| -> Result<(), &'static str> {
            let handles: Vec<_> = locals
                .iter_mut()
                .enumerate()
                .map(|(t, local)| {
                    let shared = &shared;
                    let geom = &geom;
                    sc.spawn(move || {
                        shared.run_owned(data, prep, (segment, wave), local, t, geom, INFLIGHT)
                    })
                })
                .collect();
            // 探索の間に、次の単位の前処理をこの thread で行う。
            if r1 < n {
                shared.prepare(data, (r1, (r1 + unit).min(n)), threads, hasher, prep_next);
            }
            for h in handles {
                h.join().map_err(|_| "LLZ find worker panicked")?;
            }
            Ok(())
        })?;
        cur_prep ^= 1;
        if locals.iter().any(|l| l.failed) {
            return Err("LLZ match store allocation".into());
        }
        stats.peak_pool_bytes = stats
            .peak_pool_bytes
            .max(chunks.in_use().saturating_mul(chunk_bytes));
        // 探索を終えた segment を待ち行列へ。batch 個たまったら並列に parse する。
        while next_seg < nseg && ((next_seg + 1) * segment).min(n) <= r1 {
            pending.push(next_seg);
            next_seg += 1;
        }
        if pending.len() >= batch {
            parse_batch::<R>(
                data,
                s,
                &geom,
                cl_shift,
                &mut locals,
                &pending,
                threads,
                sink,
            )?;
            pending.clear();
            stats.batches += 1;
        }
        r0 = r1;
    }
    if !pending.is_empty() {
        parse_batch::<R>(
            data,
            s,
            &geom,
            cl_shift,
            &mut locals,
            &pending,
            threads,
            sink,
        )?;
        stats.batches += 1;
    }
    Ok(stats)
}
