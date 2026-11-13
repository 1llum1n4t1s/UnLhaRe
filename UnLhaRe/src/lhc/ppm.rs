//! LPM1BLK: PPMII（PPMd var.H 相当）による block 単位の符号化。
//!
//! テキストでは文脈を直接持つ PPM 系が BWT 系 MDL より強い（experiments/khc/MODEL_STRENGTH_20261113.md）。
//! アルゴリズムは LZMA SDK（public domain）の Ppmd7 / Ppmd7z range coder の手順に従うが、
//! ポインタと sub-allocator の代わりに添字で参照する arena を使う独自の safe Rust 実装で、
//! 7-Zip の PPMd 書庫との互換性はない（frame は LHC 独自）。
//!
//! 配置: arena は 8B の cell の配列で、2 cell を 1 unit とする。context は 1 unit を使い、
//! 先頭 cell に (NumStats, 容量, Suffix)、次の cell に「単一状態」か (SummFreq, Stats) を置く。
//! PPMd と同じく単一状態を context に同居させ、高次で多い 2 値 context の参照を 1 回にする。
//!
//! 安全性: 復号は任意の byte 列を受ける。破損は range decoder が選ぶ symbol を変えるだけで、
//! モデルは復号済み symbol から符号化と同じ手順で更新されるため、添字の不変条件は入力に依存しない。
//! 入力に依存する検査（範囲外の count、root での escape、payload 不足）は Err を返す。万一の実装上の
//! 不変条件違反は添字の境界検査で止まり、`guarded` が panic を Err に変える。メモリは frame に
//! 記録した上限（units）を超えると PPMd と同じくモデルを初期化し直す（restart）。
use super::block::crc32;

type Result<T> = std::result::Result<T, String>;

pub const MAGIC: &[u8; 8] = b"LPM1BLK\0";
pub const HEADER: usize = 40;
const FRAME_REVISION: u16 = 1;
/// 既定の最大次数。Calgary/Canterbury のテキストで order 6〜8 が最良だった。
pub const DEFAULT_ORDER: u8 = 6;
/// モデル用 arena の上限（MiB）。1 unit = 16B（state 2 個、または context 1 個）。
pub const MODEL_MIB: u32 = 40;
const MIN_ORDER: u8 = 2;
const MAX_ORDER: u8 = 16;
const UNIT_BYTES: usize = 16;
/// 復号時の作業メモリの見積もり（model arena 上限 + text 履歴 + 出力）。codec gate の課金に使う。
pub const MEMORY_BOUND: usize = (MODEL_MIB as usize) * 1024 * 1024 + 2 * (super::BLOCK_BYTES + 2);
// portfolio は PPM 符号化中も MDL frame（<=1MiB+header）を保持する。合計で codec gate 内に収める。
const _: () = assert!(
    MEMORY_BOUND + super::BLOCK_BYTES + super::block::HEADER + (1 << 20)
        <= super::CODEC_MEMORY_BYTES as usize
);

const MAX_FREQ: u16 = 124;
const PERIOD_BITS: u8 = 7;
const BIN_SCALE: u32 = 1 << 14;
const TOP: u32 = 1 << 24;
const K_INIT_BIN_ESC: [u16; 8] = [
    0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051,
];
const EXP_ESCAPE: [u8; 16] = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2];

// successor の表現: 0 = なし、TEXT_FLAG|pos = text 履歴の位置、それ以外 = context の cell 添字。
const TEXT_FLAG: u32 = 1 << 31;
fn is_text(successor: u32) -> bool {
    successor & TEXT_FLAG != 0
}

/// arena の 8B cell。state としては (symbol, freq, successor)、context の先頭 cell としては
/// (NumStats, stats block の容量 unit 数, Suffix)、多状態 context の 2 番目の cell としては
/// (SummFreq, 0, Stats) と読む。
#[derive(Clone, Copy, Default)]
struct Cell {
    a: u16,
    b: u16,
    c: u32,
}

#[derive(Clone, Copy, Default)]
struct See {
    summ: u16,
    shift: u8,
    count: u8,
}
impl See {
    fn update(&mut self) {
        if self.shift < PERIOD_BITS {
            self.count = self.count.wrapping_sub(1);
            if self.count == 0 {
                self.summ = self.summ.wrapping_shl(1);
                self.count = (3u32 << self.shift) as u8;
                self.shift += 1;
            }
        }
    }
}

struct Tables {
    ns2indx: [u8; 256],
    ns2bsindx: [u8; 256],
    hb2flag: [u8; 256],
}
fn tables() -> &'static Tables {
    static TABLES: std::sync::OnceLock<Tables> = std::sync::OnceLock::new();
    TABLES.get_or_init(|| {
        let mut ns2bsindx = [6u8; 256];
        ns2bsindx[0] = 0;
        ns2bsindx[1] = 2;
        ns2bsindx[2..11].fill(4);
        let mut ns2indx = [0u8; 256];
        for (i, v) in ns2indx.iter_mut().enumerate().take(3) {
            *v = i as u8;
        }
        let (mut m, mut k) = (3u32, 1u32);
        for v in ns2indx.iter_mut().skip(3) {
            *v = m as u8;
            k -= 1;
            if k == 0 {
                m += 1;
                k = m - 2;
            }
        }
        let mut hb2flag = [0u8; 256];
        hb2flag[0x40..].fill(8);
        Tables {
            ns2indx,
            ns2bsindx,
            hb2flag,
        }
    })
}

fn invariant(what: &str) -> String {
    format!("ppm model invariant: {what}")
}

/// 実装上の不変条件違反（境界検査の panic）を Err に変える安全網。入力由来の異常は通常の Err で返る。
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
        .unwrap_or_else(|_| Err(invariant("internal panic")))
}

/// 適応モデル本体。符号化・復号で共有する。
struct Model {
    max_order: i32,
    max_units: usize,
    cells: Vec<Cell>,
    /// unit 数ごとの空き block（先頭 cell 添字）。
    free: Vec<Vec<u32>>,
    text: Vec<u8>,
    text_pos: usize,
    min_ctx: u32,
    max_ctx: u32,
    found: u32,
    order_fall: i32,
    run_length: i32,
    init_rl: i32,
    prev_success: u32,
    init_esc: u32,
    hi_bits_flag: u32,
    bin_summ: Box<[[u16; 64]; 128]>,
    see: [[See; 16]; 25],
    dummy_see: See,
    tables: &'static Tables,
    /// escape で除外した symbol の印（stamp 方式で毎回の全消去を避ける）。
    mask: [u32; 256],
    stamp: u32,
    /// 上限到達による restart の回数（初期化は数えない）。試験と診断用。
    restarts: u32,
}

impl Model {
    fn new(max_order: u8, text_capacity: usize) -> Result<Self> {
        if !(MIN_ORDER..=MAX_ORDER).contains(&max_order) {
            return Err("ppm order".into());
        }
        let mut text = Vec::new();
        text.try_reserve_exact(text_capacity + 2)
            .map_err(|_| "ppm text allocation")?;
        text.resize(text_capacity + 2, 0);
        let mut model = Self {
            max_order: i32::from(max_order),
            max_units: MODEL_MIB as usize * 1024 * 1024 / UNIT_BYTES,
            cells: Vec::new(),
            free: vec![Vec::new(); 129],
            text,
            text_pos: 0,
            min_ctx: 0,
            max_ctx: 0,
            found: 0,
            order_fall: 0,
            run_length: 0,
            init_rl: 0,
            prev_success: 0,
            init_esc: 0,
            hi_bits_flag: 0,
            bin_summ: Box::new([[0; 64]; 128]),
            see: [[See::default(); 16]; 25],
            dummy_see: See {
                summ: 0,
                shift: PERIOD_BITS,
                count: 64,
            },
            tables: tables(),
            mask: [0; 256],
            stamp: 0,
            restarts: 0,
        };
        model.reset()?;
        Ok(model)
    }

    // --- cell の読み書き（添字は内部不変条件で正しい。違反は境界検査で止まる） ---
    #[inline]
    fn ns(&self, c: u32) -> u32 {
        u32::from(self.cells[c as usize].a)
    }
    #[inline]
    fn capacity(&self, c: u32) -> u32 {
        u32::from(self.cells[c as usize].b)
    }
    #[inline]
    fn suffix(&self, c: u32) -> u32 {
        self.cells[c as usize].c
    }
    #[inline]
    fn summ(&self, c: u32) -> u32 {
        u32::from(self.cells[c as usize + 1].a)
    }
    #[inline]
    fn set_summ(&mut self, c: u32, value: u32) {
        // PPMd と同じく SummFreq は 16bit で保持する。
        self.cells[c as usize + 1].a = value as u16;
    }
    #[inline]
    fn stats(&self, c: u32) -> u32 {
        self.cells[c as usize + 1].c
    }
    #[inline]
    fn sym(&self, s: u32) -> u8 {
        self.cells[s as usize].a as u8
    }
    #[inline]
    fn freq(&self, s: u32) -> u32 {
        u32::from(self.cells[s as usize].b)
    }
    #[inline]
    fn set_freq(&mut self, s: u32, value: u32) {
        self.cells[s as usize].b = value as u16;
    }
    #[inline]
    fn succ(&self, s: u32) -> u32 {
        self.cells[s as usize].c
    }
    #[inline]
    fn set_succ(&mut self, s: u32, value: u32) {
        self.cells[s as usize].c = value;
    }
    // 多状態 context 内で symbol の state を探す（線形）。見つからないのは実装の不変条件違反。
    fn find(&self, c: u32, symbol: u8) -> u32 {
        let stats = self.stats(c) as usize;
        let n = self.ns(c) as usize;
        let i = self.cells[stats..stats + n]
            .iter()
            .position(|s| s.a == u16::from(symbol))
            .expect("ppm: symbol in context");
        (stats + i) as u32
    }

    // block を確保する。上限を超える場合は None（呼出し側が restart する）。
    fn alloc_units(&mut self, units: usize) -> Result<Option<u32>> {
        if let Some(index) = self.free[units].pop() {
            return Ok(Some(index));
        }
        let start = self.cells.len();
        if start / 2 + units > self.max_units {
            return Ok(None);
        }
        if start + 2 * units > self.cells.capacity() {
            // 倍々に伸ばすが、上限の cell 数を超えては確保しない。
            let limit = 2 * self.max_units;
            let grow = self
                .cells
                .capacity()
                .max(1 << 16)
                .min(limit - start)
                .max(2 * units);
            self.cells
                .try_reserve_exact(grow)
                .map_err(|_| "ppm arena allocation")?;
        }
        self.cells.resize(start + 2 * units, Cell::default());
        Ok(Some(start as u32))
    }
    fn free_units(&mut self, index: u32, units: usize) {
        if (1..=128).contains(&units) {
            self.free[units].push(index);
        }
    }

    fn restart(&mut self) -> Result<()> {
        self.restarts += 1;
        self.reset()
    }
    fn reset(&mut self) -> Result<()> {
        self.cells.clear();
        for list in &mut self.free {
            list.clear();
        }
        self.text_pos = 0;
        // unit 0 は「なし」を表す番兵。
        self.cells.resize(2, Cell::default());
        let root = self
            .alloc_units(1)?
            .ok_or_else(|| invariant("root context"))?;
        let stats = self
            .alloc_units(128)?
            .ok_or_else(|| invariant("root allocation"))?;
        for i in 0..256u16 {
            self.cells[stats as usize + usize::from(i)] = Cell { a: i, b: 1, c: 0 };
        }
        self.cells[root as usize] = Cell {
            a: 256,
            b: 128,
            c: 0,
        };
        self.cells[root as usize + 1] = Cell {
            a: 257,
            b: 0,
            c: stats,
        };
        self.min_ctx = root;
        self.max_ctx = root;
        self.found = stats;
        self.order_fall = self.max_order;
        self.init_rl = -self.max_order.min(12) - 1;
        self.run_length = self.init_rl;
        self.prev_success = 0;
        for (i, row) in self.bin_summ.iter_mut().enumerate() {
            for (k, &esc) in K_INIT_BIN_ESC.iter().enumerate() {
                let value = (BIN_SCALE - u32::from(esc) / (i as u32 + 2)) as u16;
                for m in (0..64).step_by(8) {
                    row[k + m] = value;
                }
            }
        }
        for (i, row) in self.see.iter_mut().enumerate() {
            for see in row.iter_mut() {
                see.shift = PERIOD_BITS - 4;
                see.summ = ((5 * i as u32 + 10) << see.shift) as u16;
                see.count = 4;
            }
        }
        Ok(())
    }

    fn bin_summ_index(&mut self) -> (usize, usize) {
        let c = self.min_ctx;
        let one = c + 1;
        let suffix_ns = self.ns(self.suffix(c)) as usize;
        let t = self.tables;
        self.hi_bits_flag = u32::from(t.hb2flag[usize::from(self.sym(self.found))]);
        let row = (self.freq(one).max(1) - 1).min(127) as usize;
        let column = self.prev_success as usize
            + usize::from(t.ns2bsindx[suffix_ns - 1])
            + self.hi_bits_flag as usize
            + 2 * usize::from(t.hb2flag[usize::from(self.sym(one))])
            + ((self.run_length >> 26) & 0x20) as usize;
        (row, column)
    }

    fn make_esc_freq(&mut self, num_masked: u32) -> (Option<(usize, usize)>, u32) {
        let c = self.min_ctx;
        let ns = self.ns(c);
        if ns == 256 {
            return (None, 1);
        }
        let non_masked = ns - num_masked;
        let suffix_ns = self.ns(self.suffix(c));
        let row = usize::from(self.tables.ns2indx[(non_masked - 1) as usize]);
        let column = usize::from(non_masked < suffix_ns.wrapping_sub(ns))
            + 2 * usize::from(self.summ(c) < 11 * ns)
            + 4 * usize::from(num_masked > non_masked)
            + self.hi_bits_flag as usize;
        let see = &mut self.see[row][column];
        let r = see.summ >> see.shift;
        see.summ = see.summ.wrapping_sub(r);
        (Some((row, column)), u32::from(r) + u32::from(r == 0))
    }
    fn see_mut(&mut self, see: Option<(usize, usize)>) -> &mut See {
        match see {
            Some((row, column)) => &mut self.see[row][column],
            None => &mut self.dummy_see,
        }
    }

    fn create_successors(&mut self, skip: bool) -> Result<Option<u32>> {
        let mut c = self.min_ctx;
        let up_branch = self.succ(self.found);
        let found_symbol = self.sym(self.found);
        let mut ps = [0u32; MAX_ORDER as usize + 1];
        let mut num_ps = 0usize;
        if !skip {
            ps[num_ps] = self.found;
            num_ps += 1;
        }
        while self.suffix(c) != 0 {
            c = self.suffix(c);
            let s = if self.ns(c) != 1 {
                self.find(c, found_symbol)
            } else {
                c + 1
            };
            let successor = self.succ(s);
            if successor != up_branch {
                c = successor;
                if num_ps == 0 {
                    return Ok(Some(c));
                }
                break;
            }
            ps[num_ps] = s;
            num_ps += 1;
        }
        let position = (up_branch & !TEXT_FLAG) as usize;
        let symbol = self.text[position];
        let freq = if self.ns(c) == 1 {
            self.freq(c + 1)
        } else {
            let s = self.find(c, symbol);
            let cf = self.freq(s) - 1;
            let s0 = self
                .summ(c)
                .wrapping_sub(self.ns(c))
                .wrapping_sub(cf)
                .max(1);
            let extra = if 2 * cf <= s0 {
                u32::from(5 * cf > s0)
            } else {
                (2 * cf + 3 * s0 - 1) / (2 * s0)
            };
            (1 + extra).min(u32::from(MAX_FREQ))
        };
        let up_state = Cell {
            a: u16::from(symbol),
            b: freq as u16,
            c: TEXT_FLAG | (position as u32 + 1),
        };
        while num_ps != 0 {
            let Some(c1) = self.alloc_units(1)? else {
                return Ok(None);
            };
            self.cells[c1 as usize] = Cell { a: 1, b: 0, c };
            self.cells[c1 as usize + 1] = up_state;
            num_ps -= 1;
            self.set_succ(ps[num_ps], c1);
            c = c1;
        }
        Ok(Some(c))
    }

    fn update_model(&mut self) -> Result<()> {
        let found = self.found;
        let found_symbol = self.sym(found);
        let found_freq = self.freq(found);
        let mut f_successor = self.succ(found);
        let min = self.min_ctx;
        let min_suffix = self.suffix(min);
        if found_freq < u32::from(MAX_FREQ / 4) && min_suffix != 0 {
            let c = min_suffix;
            if self.ns(c) == 1 {
                let s = c + 1;
                if self.freq(s) < 32 {
                    self.set_freq(s, self.freq(s) + 1);
                }
            } else {
                let mut s = self.stats(c);
                if self.sym(s) != found_symbol {
                    s = self.find(c, found_symbol);
                    if self.freq(s) >= self.freq(s - 1) {
                        self.cells.swap(s as usize, s as usize - 1);
                        s -= 1;
                    }
                }
                if self.freq(s) < u32::from(MAX_FREQ - 9) {
                    self.set_freq(s, self.freq(s) + 2);
                    self.set_summ(c, self.summ(c) + 2);
                }
            }
        }
        if self.order_fall == 0 {
            let Some(c) = self.create_successors(true)? else {
                return self.restart();
            };
            self.min_ctx = c;
            self.max_ctx = c;
            self.set_succ(self.found, c);
            return Ok(());
        }
        if self.text_pos + 1 >= self.text.len() {
            return self.restart();
        }
        self.text[self.text_pos] = found_symbol;
        self.text_pos += 1;
        let mut successor = TEXT_FLAG | self.text_pos as u32;
        if f_successor != 0 {
            if is_text(f_successor) {
                let Some(cs) = self.create_successors(false)? else {
                    return self.restart();
                };
                f_successor = cs;
            }
            self.order_fall -= 1;
            if self.order_fall == 0 {
                successor = f_successor;
                if self.max_ctx != self.min_ctx {
                    self.text_pos -= 1;
                }
            }
        } else {
            self.set_succ(self.found, successor);
            f_successor = self.min_ctx;
        }
        let ns = self.ns(min);
        let s0 = self
            .summ(min)
            .wrapping_sub(ns)
            .wrapping_sub(found_freq.wrapping_sub(1));
        let mut c = self.max_ctx;
        while c != min {
            let ns1 = self.ns(c);
            let mut summ;
            if ns1 != 1 {
                let capacity = self.capacity(c);
                if ns1 >= 2 * capacity {
                    // stats block が満杯なので 1 unit 大きい block へ移す。
                    let Some(new) = self.alloc_units(capacity as usize + 1)? else {
                        return self.restart();
                    };
                    let old = self.stats(c);
                    self.cells
                        .copy_within(old as usize..(old + ns1) as usize, new as usize);
                    self.free_units(old, capacity as usize);
                    self.cells[c as usize + 1].c = new;
                    self.cells[c as usize].b = (capacity + 1) as u16;
                }
                summ = self.summ(c);
                summ +=
                    u32::from(2 * ns1 < ns) + 2 * u32::from((4 * ns1 <= ns) & (summ <= 8 * ns1));
            } else {
                // 単一状態の context を多状態へ移す（同居していた state を新しい block へ）。
                let Some(new) = self.alloc_units(1)? else {
                    return self.restart();
                };
                let mut one = self.cells[c as usize + 1];
                one.b = if one.b < MAX_FREQ / 4 - 1 {
                    one.b << 1
                } else {
                    MAX_FREQ - 4
                };
                self.cells[new as usize] = one;
                self.cells[c as usize].b = 1;
                self.cells[c as usize + 1] = Cell { a: 0, b: 0, c: new };
                summ = u32::from(one.b) + self.init_esc + u32::from(ns > 3);
            }
            let mut cf = 2 * found_freq * (summ + 6);
            let sf = s0.wrapping_add(summ);
            if cf < 6 * sf {
                cf = 1 + u32::from(cf > sf) + u32::from(cf >= 4 * sf);
                summ += 3;
            } else {
                cf = 4
                    + u32::from(cf >= 9 * sf)
                    + u32::from(cf >= 12 * sf)
                    + u32::from(cf >= 15 * sf);
                summ += cf;
            }
            let slot = (self.stats(c) + ns1) as usize;
            self.cells[slot] = Cell {
                a: u16::from(found_symbol),
                b: cf as u16,
                c: successor,
            };
            self.cells[c as usize].a = (ns1 + 1) as u16;
            self.set_summ(c, summ);
            c = self.suffix(c);
        }
        self.max_ctx = f_successor;
        self.min_ctx = f_successor;
        Ok(())
    }

    fn rescale(&mut self) {
        let mc = self.min_ctx;
        let stats = self.stats(mc) as usize;
        let ns = self.ns(mc) as usize;
        let found = self.found as usize;
        let cells = &mut self.cells;
        // 見つかった state を先頭へ移す。
        let tmp = cells[found];
        cells.copy_within(stats..found, stats + 1);
        cells[stats] = tmp;
        let mut esc = u32::from(self.cells[mc as usize + 1].a).wrapping_sub(u32::from(tmp.b));
        let adder = u16::from(self.order_fall != 0);
        let cells = &mut self.cells;
        cells[stats].b = (cells[stats].b + 4 + adder) >> 1;
        let mut sum = u32::from(cells[stats].b);
        for s in stats + 1..stats + ns {
            esc = esc.wrapping_sub(u32::from(cells[s].b));
            cells[s].b = (cells[s].b + adder) >> 1;
            sum += u32::from(cells[s].b);
            if cells[s].b > cells[s - 1].b {
                let tmp = cells[s];
                let mut s1 = s;
                loop {
                    cells[s1] = cells[s1 - 1];
                    s1 -= 1;
                    if s1 == stats || tmp.b <= cells[s1 - 1].b {
                        break;
                    }
                }
                cells[s1] = tmp;
            }
        }
        let mut s = stats + ns - 1;
        if cells[s].b == 0 {
            let mut zeros = 0u32;
            loop {
                zeros += 1;
                s -= 1;
                if cells[s].b != 0 {
                    break;
                }
            }
            esc = esc.wrapping_add(zeros);
            let new_ns = ns as u32 - zeros;
            let capacity = self.capacity(mc);
            if new_ns == 1 {
                // 単一状態へ戻す。stats block を返し、state を context へ同居させる。
                let mut tmp = self.cells[stats];
                loop {
                    tmp.b -= tmp.b >> 1;
                    esc >>= 1;
                    if esc <= 1 {
                        break;
                    }
                }
                self.free_units(stats as u32, capacity as usize);
                self.cells[mc as usize] = Cell {
                    a: 1,
                    b: 0,
                    c: self.suffix(mc),
                };
                self.cells[mc as usize + 1] = tmp;
                self.found = mc + 1;
                return;
            }
            self.cells[mc as usize].a = new_ns as u16;
            let n0 = (ns as u32 + 1) >> 1;
            let n1 = (new_ns + 1) >> 1;
            if n0 != n1 {
                // stats block の末尾 unit を返して容量を縮める（PPMd の ShrinkUnits に相当）。
                if n1 < capacity {
                    self.free_units(stats as u32 + 2 * n1, (capacity - n1) as usize);
                }
                self.cells[mc as usize].b = n1 as u16;
            }
        }
        self.set_summ(mc, sum + esc - (esc >> 1));
        self.found = stats as u32;
    }

    fn next_context(&mut self) -> Result<()> {
        let successor = self.succ(self.found);
        if self.order_fall == 0 && successor != 0 && !is_text(successor) {
            self.min_ctx = successor;
            self.max_ctx = successor;
            Ok(())
        } else {
            self.update_model()
        }
    }
    fn update1(&mut self) -> Result<()> {
        let s = self.found;
        self.set_freq(s, self.freq(s) + 4);
        self.set_summ(self.min_ctx, self.summ(self.min_ctx) + 4);
        if self.freq(s) > self.freq(s - 1) {
            self.cells.swap(s as usize, s as usize - 1);
            self.found = s - 1;
            if self.freq(self.found) > u32::from(MAX_FREQ) {
                self.rescale();
            }
        }
        self.next_context()
    }
    fn update1_0(&mut self) -> Result<()> {
        let freq = self.freq(self.found);
        let summ = self.summ(self.min_ctx);
        self.prev_success = u32::from(2 * freq > summ);
        self.run_length += self.prev_success as i32;
        self.set_summ(self.min_ctx, summ + 4);
        self.set_freq(self.found, freq + 4);
        if freq + 4 > u32::from(MAX_FREQ) {
            self.rescale();
        }
        self.next_context()
    }
    fn update_bin(&mut self) -> Result<()> {
        let freq = self.freq(self.found);
        if freq < 128 {
            self.set_freq(self.found, freq + 1);
        }
        self.prev_success = 1;
        self.run_length += 1;
        self.next_context()
    }
    fn update2(&mut self) -> Result<()> {
        let freq = self.freq(self.found) + 4;
        self.set_freq(self.found, freq);
        self.set_summ(self.min_ctx, self.summ(self.min_ctx) + 4);
        if freq > u32::from(MAX_FREQ) {
            self.rescale();
        }
        self.run_length = self.init_rl;
        self.update_model()
    }

    fn next_stamp(&mut self) {
        self.stamp = self.stamp.wrapping_add(1);
        if self.stamp == 0 {
            self.mask = [0; 256];
            self.stamp = 1;
        }
    }
    // escape 後、現在の context の全 symbol を除外する。
    fn mask_context(&mut self, c: u32) {
        let stats = self.stats(c) as usize;
        let n = self.ns(c) as usize;
        for cell in &self.cells[stats..stats + n] {
            self.mask[usize::from(cell.a as u8)] = self.stamp;
        }
    }
    // 除外済みでない symbol を持つ context まで suffix を辿る。root で尽きたら Err（破損入力）。
    fn escape_to_suffix(&mut self, num_masked: u32) -> Result<()> {
        loop {
            self.order_fall += 1;
            let suffix = self.suffix(self.min_ctx);
            if suffix == 0 {
                return Err("ppm escape at root".into());
            }
            self.min_ctx = suffix;
            if self.ns(suffix) != num_masked {
                return Ok(());
            }
        }
    }

    // 2 値 context（単一状態）の bit を処理した後の共通更新。hit なら true。
    fn binary_after(&mut self, row: usize, column: usize, prob: u16, hit: bool) -> Result<bool> {
        if hit {
            self.bin_summ[row][column] = update_prob_0(prob);
            self.found = self.min_ctx + 1;
            self.update_bin()?;
            return Ok(true);
        }
        let prob = update_prob_1(prob);
        self.bin_summ[row][column] = prob;
        self.init_esc = u32::from(EXP_ESCAPE[usize::from(prob >> 10)]);
        let symbol = self.sym(self.min_ctx + 1);
        self.mask[usize::from(symbol)] = self.stamp;
        self.prev_success = 0;
        Ok(false)
    }

    fn encode_symbol(&mut self, rc: &mut Encoder, symbol: u8) -> Result<()> {
        self.next_stamp();
        let c = self.min_ctx;
        let target = u16::from(symbol);
        if self.ns(c) != 1 {
            let stats = self.stats(c) as usize;
            let n = self.ns(c) as usize;
            let total = self.summ(c);
            let first = self.cells[stats];
            if first.a == target {
                rc.encode(0, u32::from(first.b), total);
                self.found = stats as u32;
                return self.update1_0();
            }
            self.prev_success = 0;
            let mut low = u32::from(first.b);
            for i in 1..n {
                let state = self.cells[stats + i];
                if state.a == target {
                    rc.encode(low, u32::from(state.b), total);
                    self.found = (stats + i) as u32;
                    return self.update1();
                }
                low += u32::from(state.b);
            }
            self.hi_bits_flag = u32::from(self.tables.hb2flag[usize::from(self.sym(self.found))]);
            self.mask_context(c);
            rc.encode(low, total - low, total);
        } else {
            let (row, column) = self.bin_summ_index();
            let prob = self.bin_summ[row][column];
            let hit = self.sym(c + 1) == symbol;
            rc.encode_bit(prob, !hit);
            if self.binary_after(row, column, prob, hit)? {
                return Ok(());
            }
        }
        loop {
            let num_masked = self.ns(self.min_ctx);
            self.escape_to_suffix(num_masked)?;
            let (see, esc_freq) = self.make_esc_freq(num_masked);
            let c = self.min_ctx;
            let stats = self.stats(c) as usize;
            let n = self.ns(c) as usize;
            let mut sum = 0u32;
            let mut hit = None;
            for i in 0..n {
                let state = self.cells[stats + i];
                if self.mask[usize::from(state.a as u8)] == self.stamp {
                    continue;
                }
                if state.a == target {
                    hit = Some((stats + i, sum, u32::from(state.b)));
                }
                sum += u32::from(state.b);
            }
            if let Some((s, low, freq)) = hit {
                rc.encode(low, freq, sum + esc_freq);
                self.see_mut(see).update();
                self.found = s as u32;
                return self.update2();
            }
            rc.encode(sum, esc_freq, sum + esc_freq);
            let see = self.see_mut(see);
            see.summ = see.summ.wrapping_add((sum + esc_freq) as u16);
            self.mask_context(c);
        }
    }

    fn decode_symbol(&mut self, rc: &mut Decoder<'_>) -> Result<u8> {
        self.next_stamp();
        let c = self.min_ctx;
        if self.ns(c) != 1 {
            let stats = self.stats(c) as usize;
            let n = self.ns(c) as usize;
            let total = self.summ(c);
            let count = rc.threshold(total)?;
            let first = self.cells[stats];
            let mut hi = u32::from(first.b);
            if count < hi {
                rc.decode(0, hi)?;
                self.found = stats as u32;
                self.update1_0()?;
                return Ok(first.a as u8);
            }
            self.prev_success = 0;
            for i in 1..n {
                let state = self.cells[stats + i];
                hi += u32::from(state.b);
                if hi > count {
                    rc.decode(hi - u32::from(state.b), u32::from(state.b))?;
                    self.found = (stats + i) as u32;
                    self.update1()?;
                    return Ok(state.a as u8);
                }
            }
            if hi > total {
                return Err("ppm escape count".into());
            }
            self.hi_bits_flag = u32::from(self.tables.hb2flag[usize::from(self.sym(self.found))]);
            rc.decode(hi, total - hi)?;
            self.mask_context(c);
        } else {
            let (row, column) = self.bin_summ_index();
            let prob = self.bin_summ[row][column];
            let symbol = self.sym(c + 1);
            let hit = !rc.decode_bit(prob)?;
            if self.binary_after(row, column, prob, hit)? {
                return Ok(symbol);
            }
        }
        loop {
            let num_masked = self.ns(self.min_ctx);
            self.escape_to_suffix(num_masked)?;
            let (see, esc_freq) = self.make_esc_freq(num_masked);
            let c = self.min_ctx;
            let stats = self.stats(c) as usize;
            let n = self.ns(c) as usize;
            let mut hi = 0u32;
            for state in &self.cells[stats..stats + n] {
                if self.mask[usize::from(state.a as u8)] != self.stamp {
                    hi += u32::from(state.b);
                }
            }
            let total = hi + esc_freq;
            let count = rc.threshold(total)?;
            if count < hi {
                let mut acc = 0u32;
                for i in 0..n {
                    let state = self.cells[stats + i];
                    if self.mask[usize::from(state.a as u8)] == self.stamp {
                        continue;
                    }
                    acc += u32::from(state.b);
                    if acc > count {
                        rc.decode(acc - u32::from(state.b), u32::from(state.b))?;
                        self.see_mut(see).update();
                        self.found = (stats + i) as u32;
                        self.update2()?;
                        return Ok(state.a as u8);
                    }
                }
                return Err(invariant("escape candidate"));
            }
            rc.decode(hi, esc_freq)?;
            let see = self.see_mut(see);
            see.summ = see.summ.wrapping_add(total as u16);
            self.mask_context(c);
        }
    }
}

fn update_prob_0(prob: u16) -> u16 {
    prob.wrapping_add(1 << 7)
        .wrapping_sub((prob.wrapping_add(1 << (PERIOD_BITS - 2))) >> PERIOD_BITS)
}
fn update_prob_1(prob: u16) -> u16 {
    prob.wrapping_sub((prob.wrapping_add(1 << (PERIOD_BITS - 2))) >> PERIOD_BITS)
}

/// 7-Zip PPMd（Ppmd7z）と同じ手順の range encoder。出力が上限に達したら以後は書かず印だけ残す。
struct Encoder {
    low: u64,
    range: u32,
    cache: u8,
    cache_size: u64,
    out: Vec<u8>,
    limit: usize,
    overflow: bool,
}
impl Encoder {
    fn new(limit: usize) -> Result<Self> {
        let mut out = Vec::new();
        out.try_reserve_exact(limit.min(1 << 20) + 16)
            .map_err(|_| "ppm output allocation")?;
        Ok(Self {
            low: 0,
            range: u32::MAX,
            cache: 0,
            cache_size: 1,
            out,
            limit,
            overflow: false,
        })
    }
    fn shift_low(&mut self) {
        if (self.low as u32) < 0xFF00_0000 || (self.low >> 32) != 0 {
            let mut temp = self.cache;
            loop {
                if self.out.len() < self.limit {
                    self.out.push(temp.wrapping_add((self.low >> 32) as u8));
                } else {
                    self.overflow = true;
                }
                temp = 0xFF;
                self.cache_size -= 1;
                if self.cache_size == 0 {
                    break;
                }
            }
            self.cache = ((self.low as u32) >> 24) as u8;
        }
        self.cache_size += 1;
        self.low = u64::from((self.low as u32) << 8);
    }
    #[inline]
    fn normalize(&mut self) {
        while self.range < TOP {
            self.range <<= 8;
            self.shift_low();
        }
    }
    #[inline]
    fn encode(&mut self, start: u32, size: u32, total: u32) {
        self.range /= total;
        self.low += u64::from(start) * u64::from(self.range);
        self.range *= size;
        self.normalize();
    }
    #[inline]
    fn encode_bit(&mut self, size0: u16, bit: bool) {
        let bound = (self.range >> 14) * u32::from(size0);
        if bit {
            self.low += u64::from(bound);
            self.range -= bound;
        } else {
            self.range = bound;
        }
        self.normalize();
    }
    fn finish(mut self) -> Option<Vec<u8>> {
        for _ in 0..5 {
            self.shift_low();
        }
        (!self.overflow).then_some(self.out)
    }
}

struct Decoder<'a> {
    code: u32,
    range: u32,
    data: &'a [u8],
    position: usize,
}
impl<'a> Decoder<'a> {
    fn new(data: &'a [u8]) -> Result<Self> {
        if data.len() < 5 || data[0] != 0 {
            return Err("ppm range header".into());
        }
        let code = u32::from_be_bytes(data[1..5].try_into().unwrap());
        if code == u32::MAX {
            return Err("ppm range code".into());
        }
        Ok(Self {
            code,
            range: u32::MAX,
            data,
            position: 5,
        })
    }
    #[inline]
    fn normalize(&mut self) -> Result<()> {
        while self.range < TOP {
            let byte = *self
                .data
                .get(self.position)
                .ok_or("ppm payload truncated")?;
            self.position += 1;
            self.code = (self.code << 8) | u32::from(byte);
            self.range <<= 8;
        }
        Ok(())
    }
    #[inline]
    fn threshold(&mut self, total: u32) -> Result<u32> {
        self.range /= total;
        let count = self.code / self.range;
        if count >= total {
            return Err("ppm range count".into());
        }
        Ok(count)
    }
    #[inline]
    fn decode(&mut self, start: u32, size: u32) -> Result<()> {
        self.code -= start * self.range;
        self.range *= size;
        self.normalize()
    }
    #[inline]
    fn decode_bit(&mut self, size0: u16) -> Result<bool> {
        let bound = (self.range >> 14) * u32::from(size0);
        let bit = if self.code < bound {
            self.range = bound;
            false
        } else {
            self.code -= bound;
            self.range -= bound;
            true
        };
        self.normalize()?;
        Ok(bit)
    }
}

fn put32(frame: &mut [u8], at: usize, value: usize) -> Result<()> {
    let value = u32::try_from(value).map_err(|_| "ppm header field")?;
    frame[at..at + 4].copy_from_slice(&value.to_le_bytes());
    Ok(())
}
fn get32(frame: &[u8], at: usize) -> usize {
    u32::from_le_bytes(frame[at..at + 4].try_into().unwrap()) as usize
}
fn wire_crc(frame: &[u8]) -> u32 {
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..28]);
    digest.update(&frame[32..]);
    digest.finalize() as u32
}

// raw を PPM payload にする。payload が raw 以上になる（利得がない）場合は None。
fn encode_payload(raw: &[u8], order: u8) -> Result<Option<Vec<u8>>> {
    let mut model = Model::new(order, raw.len())?;
    // payload は raw 未満でなければ採用しないので、上限を raw 長にして早めに打ち切る。
    let mut rc = Encoder::new(raw.len())?;
    for chunk in raw.chunks(4096) {
        for &symbol in chunk {
            model.encode_symbol(&mut rc, symbol)?;
        }
        if rc.overflow {
            return Ok(None);
        }
    }
    Ok(rc.finish().filter(|payload| payload.len() < raw.len()))
}

/// PPM frame を作る。payload が raw 以上になる（利得がない）場合は `Ok(None)`。
pub(super) fn encode(raw: &[u8], order: u8) -> Result<Option<Vec<u8>>> {
    if raw.len() > super::BLOCK_BYTES {
        return Err("ppm input bound".into());
    }
    if raw.is_empty() {
        return Ok(None);
    }
    let Some(payload) = guarded(|| encode_payload(raw, order))? else {
        return Ok(None);
    };
    let mut frame = Vec::new();
    frame
        .try_reserve_exact(HEADER + payload.len())
        .map_err(|_| "ppm frame allocation")?;
    frame.resize(HEADER, 0);
    frame[..8].copy_from_slice(MAGIC);
    frame[8..10].copy_from_slice(&FRAME_REVISION.to_le_bytes());
    frame[10] = 1;
    frame[11] = order;
    put32(&mut frame, 12, raw.len())?;
    put32(&mut frame, 16, MODEL_MIB as usize)?;
    put32(&mut frame, 20, payload.len())?;
    put32(&mut frame, 24, crc32(raw) as usize)?;
    frame.extend_from_slice(&payload);
    let crc = wire_crc(&frame);
    frame[28..32].copy_from_slice(&crc.to_le_bytes());
    Ok(Some(frame))
}

/// header・長さ・CRC を確保前に検査する（`expected` は manifest 上の raw 長）。
pub(super) fn validate_frame(frame: &[u8], expected: usize) -> Result<()> {
    if frame.len() < HEADER + 5 || &frame[..8] != MAGIC {
        return Err("ppm frame family/extent".into());
    }
    if frame[8..10] != FRAME_REVISION.to_le_bytes()
        || frame[10] != 1
        || !(MIN_ORDER..=MAX_ORDER).contains(&frame[11])
        || get32(frame, 16) != MODEL_MIB as usize
        || frame[32..40] != [0; 8]
    {
        return Err("ppm frame header".into());
    }
    let raw = get32(frame, 12);
    let payload = get32(frame, 20);
    if raw != expected || raw == 0 || raw > super::BLOCK_BYTES || payload >= raw {
        return Err("ppm frame lengths".into());
    }
    if HEADER + payload != frame.len() {
        return Err("ppm frame extent".into());
    }
    if wire_crc(frame) != get32(frame, 28) as u32 {
        return Err("ppm frame wire CRC".into());
    }
    Ok(())
}

fn decode_payload(frame: &[u8], raw_len: usize) -> Result<Vec<u8>> {
    let mut model = Model::new(frame[11], raw_len)?;
    let mut rc = Decoder::new(&frame[HEADER..])?;
    let mut out = Vec::new();
    out.try_reserve_exact(raw_len)
        .map_err(|_| "ppm output allocation")?;
    for _ in 0..raw_len {
        out.push(model.decode_symbol(&mut rc)?);
    }
    if rc.position != rc.data.len() || rc.code != 0 {
        return Err("ppm payload trailing/noncanonical".into());
    }
    Ok(out)
}

/// 自己完結した PPM frame を厳密に復号する（余剰・非正準な終端は拒否）。
pub(super) fn decode(frame: &[u8]) -> Result<Vec<u8>> {
    if frame.len() < 16 {
        return Err("ppm frame family/extent".into());
    }
    let raw_len = get32(frame, 12);
    validate_frame(frame, raw_len)?;
    let out = guarded(|| decode_payload(frame, raw_len))?;
    if crc32(&out) != get32(frame, 24) as u32 {
        return Err("ppm raw CRC".into());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(len: usize) -> Vec<u8> {
        let words = [
            "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog.\n",
        ];
        let mut out = Vec::new();
        let mut i = 0usize;
        while out.len() < len {
            out.extend_from_slice(words[(i * 5 + i / 7) % words.len()].as_bytes());
            i += 1;
        }
        out.truncate(len);
        out
    }
    fn pseudo(len: usize) -> Vec<u8> {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        (0..len)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    #[test]
    fn round_trips_text_and_mixed_inputs() {
        let mut mixed = text(30_000);
        mixed.extend(pseudo(2_000));
        mixed.extend(text(10_000));
        let all: Vec<u8> = (0..=255u8).cycle().take(5_000).collect();
        for order in [2u8, 6, 8, 16] {
            for raw in [text(1), text(200), text(50_000), mixed.clone(), all.clone()] {
                if let Some(frame) = encode(&raw, order).unwrap() {
                    validate_frame(&frame, raw.len()).unwrap();
                    assert_eq!(
                        decode(&frame).unwrap(),
                        raw,
                        "order {order} len {}",
                        raw.len()
                    );
                }
            }
        }
        // テキストは十分に縮む。
        let raw = text(50_000);
        let frame = encode(&raw, DEFAULT_ORDER).unwrap().unwrap();
        assert!(frame.len() < raw.len() / 10, "{}", frame.len());
    }

    #[test]
    fn incompressible_input_reports_no_benefit() {
        assert!(encode(&pseudo(4_000), DEFAULT_ORDER).unwrap().is_none());
        assert!(encode(&[], DEFAULT_ORDER).unwrap().is_none());
    }

    #[test]
    fn restart_under_tiny_memory_still_round_trips() {
        // 上限に達したときの restart 経路を、上限を小さくした model で通す。
        let mut raw = text(150_000);
        raw.extend(pseudo(30_000));
        let tiny = |len| {
            let mut model = Model::new(16, len).unwrap();
            model.max_units = 3_000;
            model.reset().unwrap();
            model
        };
        let mut model = tiny(raw.len());
        let mut rc = Encoder::new(usize::MAX).unwrap();
        for &b in &raw {
            model.encode_symbol(&mut rc, b).unwrap();
        }
        assert!(model.restarts > 0, "restart path was not exercised");
        let payload = rc.finish().unwrap();
        let mut model = tiny(raw.len());
        let mut dec = Decoder::new(&payload).unwrap();
        let out: Vec<u8> = (0..raw.len())
            .map(|_| model.decode_symbol(&mut dec).unwrap())
            .collect();
        assert_eq!(out, raw);
        assert_eq!(dec.position, payload.len());
        assert_eq!(dec.code, 0);
    }

    /// 開発用の内訳計測: `LHC_PPM_FILE=<path> cargo test --release --lib ppm_profile -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn ppm_profile() {
        let path = std::env::var("LHC_PPM_FILE").expect("LHC_PPM_FILE");
        let data = std::fs::read(path).unwrap();
        let raw = &data[..data.len().min(super::super::BLOCK_BYTES)];
        for order in [6u8, 8] {
            let t = std::time::Instant::now();
            let mut model = Model::new(order, raw.len()).unwrap();
            let setup = t.elapsed();
            let mut rc = Encoder::new(usize::MAX).unwrap();
            for &b in raw {
                model.encode_symbol(&mut rc, b).unwrap();
            }
            let encode = t.elapsed();
            let units = model.cells.len() / 2;
            let restarts = model.restarts;
            let payload = rc.finish().unwrap();
            let t = std::time::Instant::now();
            let mut model = Model::new(order, raw.len()).unwrap();
            let mut dec = Decoder::new(&payload).unwrap();
            for _ in 0..raw.len() {
                std::hint::black_box(model.decode_symbol(&mut dec).unwrap());
            }
            let decode = t.elapsed();
            println!(
                "order {order}: payload {} units {units} ({} MiB) restarts {restarts} setup {setup:?} encode {encode:?} decode {decode:?}",
                payload.len(),
                (units * UNIT_BYTES) >> 20
            );
        }
    }

    #[test]
    fn corrupt_frames_are_rejected_without_panic() {
        let raw = text(20_000);
        let frame = encode(&raw, DEFAULT_ORDER).unwrap().unwrap();
        // header・CRC・切断・末尾付加は拒否する。
        let mut truncated = frame.clone();
        truncated.pop();
        assert!(decode(&truncated).is_err());
        let mut extended = frame.clone();
        extended.push(0);
        assert!(decode(&extended).is_err());
        assert!(validate_frame(&frame, raw.len() + 1).is_err());
        let mut order = frame.clone();
        order[11] = 1;
        assert!(decode(&order).is_err());
        // payload を壊し wire CRC を付け直しても、panic せず Err か元と同じ出力になる。
        let mut state = 1u64;
        for _ in 0..300 {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let mut broken = frame.clone();
            let at = HEADER + (state >> 33) as usize % (broken.len() - HEADER);
            broken[at] ^= 1 << ((state >> 20) % 8);
            let crc = wire_crc(&broken);
            broken[28..32].copy_from_slice(&crc.to_le_bytes());
            if let Ok(out) = decode(&broken) {
                assert_eq!(out, raw, "accepted a different payload");
            }
        }
    }
}
