//! 長距離LZ（LLZ1BLK、archive revision 12・13・14）。大きな file の segment（revision 12・13 は 1MiB、
//! 14 は 4MiB）を、同じ file の過去 64MiB までを参照できる LZMA 系の記号で符号化する。
//!
//! 形式の定数（`LHC_FORMAT.md` に記す。worker 数などから決めない）:
//! - segment は revision 12・13 では既存の block（1MiB）と同じ、revision 14 では 4MiB。wave は 2 segment。
//!   segment 長・近傍符号の有無は archive revision ごとの `Layout`（`layout_for`）で決まる。
//! - segment k（file 内の番号）は、自分の segment と、wave の開始（k を 2 で切り捨てた segment の先頭）
//!   より前の同じ file のデータだけを参照できる。同じ wave の他 segment は参照しない。
//!   これにより、同じ wave の 2 segment は並列に復号できる。
//! - 参照距離は 64MiB 未満。参照は file を越えない（block の復号には同じ file の履歴だけを使う）。
//! - LLZ1BLK は 8MiB 以上の entry にだけ現れてよい。読み手はその entry についてだけ履歴を保持する。
//! - segment ごとに model・状態・rep 履歴・range 符号器を初期化する。符号化で縮まない segment は
//!   無圧縮（method 0）で格納する。
//!
//! frame（32B の header ＋ payload）:
//!   0..8 magic、8..10 frame revision（archive revision 12 は 1、13 は 2、14 は 3。1 対 1）、10 method（0 無圧縮／1 LZ）、11 予約0、
//!   12..16 生データ長、16..20 payload 長、20..24 生データの CRC32、
//!   24..28 wire CRC（header の 0..24 と 28..32、payload を通した CRC32）、28..32 予約0。
//!
//! frame revision 2（archive revision 13）は、通常の一致の距離を更新前の rep 距離との差で書く近傍符号を
//! 加える。配置は frame revision 1 と同じで、header の frame revision と body の bit 列だけが違う。
//!
//! frame revision 3（archive revision 14）は、body の bit 列は frame revision 2 と同じで、segment を 4MiB に
//! 広げる（生データ長は 1..=4MiB。最後の端数 segment も可）。wave は 8MiB、参照は自 segment と
//! wave 開始より前 64MiB の同じ file のデータだけ。
//!
//! 作成時は file 全体を memory に置き、窓長＋探索単位（1MiB）の二分木（約 520MiB）を
//! 使う。これは製品の codec 予算（64MiB）を超えるため、2026-11-14 に本人が大きな file に限って許可した。
mod codec;
mod mf;
mod par;
mod rc;

use crc_fast::{CrcAlgorithm, Digest, checksum};

pub const MAGIC: &[u8; 8] = b"LLZ1BLK\0";
pub const HEADER: usize = 32;
/// 同時に復号できる segment の数（wave 幅）。
pub const WAVE: usize = 2;
/// 参照できる最大距離（この値未満）。
pub const WINDOW: usize = 64 << 20;
/// LLZ1BLK を使ってよい entry の最小長。
pub const MIN_ENTRY: u64 = 8 << 20;
/// 符号化器が LLZ1BLK を使う entry の最大長（file 全体を memory に置くための上限）。
/// これを超える entry は従来の block（revision 11 の候補）で格納する。読み手の制約ではない。
pub const MAX_ENCODE_ENTRY: u64 = 512 << 20;
/// 作成時に必要な codec memory の見積もり（木 520MiB（窓 64MiB＋探索単位 1MiB の二分木）、hash 先頭 64MiB、
/// 一致置き場の上限 512MiB、位置索引 32MiB、探索単位の前処理 32MiB（1Mi 位置 × 16B の2組）の合計 1160MiB。
/// file 自体の buffer は別に entry 長だけ要る）。revision 12・13 用。
pub const CREATE_MEMORY_BYTES: u64 = (520 + 64 + 512 + 32 + 32) << 20;
/// revision 14（segment 4MiB、探索単位 1MiB）の見積もり：木 520MiB（窓 64MiB＋単位 1MiB の二分木）、
/// hash 先頭 64MiB、位置索引 128MiB（4 segment × 4Mi × 8B）、一致置き場の目標上限 `POOL_BUDGET`（640MiB）、
/// 探索単位の前処理 32MiB（1Mi 位置 × 16B の2組）、2/3byte hash 表・encoder・処理中の body と frame の
/// 余裕 64MiB の合計（1448MiB）。file 自体の buffer（最大 512MiB）は別に要る。
pub const CREATE_MEMORY_BYTES_WIDE: u64 = (520 + 64 + 128 + 640 + 32 + 64) << 20;
/// 一致探索の深さと、先読みを打ち切る一致長（7-Zip の mx9・fb273 に当たる）。
const CUT: u32 = 152;
const NICE: usize = 273;

/// frame revision 1（archive revision 12）：従来の距離符号。
pub const FRAME_REV_1: u16 = 1;
/// frame revision 2（archive revision 13）：近傍距離符号を加える。frame の配置は revision 1 と同じで、
/// header の 8..10 の値だけが違う。読み手は archive revision と frame revision を 1 対 1 に対応づけ、
/// 一致しない frame（旧読取器が新 frame を、新読取器が旧 frame を取り違える形）を受け入れない。
pub const FRAME_REV_2: u16 = 2;
/// frame revision 3（archive revision 14）：bit 列は frame revision 2 と同じで、segment を 4MiB にする。
pub const FRAME_REV_3: u16 = 3;

/// archive revision ごとの LLZ1BLK の形式（frame revision・segment 長・近傍符号）。
/// segment 長は 2 の冪で、復号器の位置計算を shift と mask で行う。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub frame_rev: u16,
    pub segment: usize,
    pub near: bool,
}

pub const LAYOUT_12: Layout = Layout {
    frame_rev: FRAME_REV_1,
    segment: 1 << 20,
    near: false,
};
pub const LAYOUT_13: Layout = Layout {
    frame_rev: FRAME_REV_2,
    segment: 1 << 20,
    near: true,
};
pub const LAYOUT_14: Layout = Layout {
    frame_rev: FRAME_REV_3,
    segment: 4 << 20,
    near: true,
};

/// archive revision に対応する形式（LLZ1BLK を持てない revision は None）。
pub fn layout_for(archive_revision: u8) -> Option<Layout> {
    match archive_revision {
        12 => Some(LAYOUT_12),
        13 => Some(LAYOUT_13),
        14 => Some(LAYOUT_14),
        _ => None,
    }
}

impl Layout {
    fn shift(self) -> u32 {
        self.segment.trailing_zeros()
    }
}

fn crc32(bytes: &[u8]) -> u32 {
    checksum(CrcAlgorithm::Crc32IsoHdlc, bytes) as u32
}

fn field(frame: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(frame[at..at + 4].try_into().unwrap())
}

/// 履歴なしでできる検査（header の正規性・長さ・wire CRC）。一覧や事前走査でも使う。
/// `layout` は書庫の revision が許す形式（`layout_for`）。生データ長は `expected`（1..=segment）と一致する。
pub fn validate_frame(frame: &[u8], expected: usize, layout: Layout) -> Result<(), String> {
    if frame.len() < HEADER || frame.get(..8) != Some(&MAGIC[..]) {
        return Err("LLZ1BLK header".into());
    }
    if u16::from_le_bytes([frame[8], frame[9]]) != layout.frame_rev
        || frame[10] > 1
        || frame[11] != 0
        || frame[28..32] != [0; 4]
    {
        return Err("LLZ1BLK revision/method/reserved".into());
    }
    let raw = field(frame, 12) as usize;
    let payload = field(frame, 16) as usize;
    if raw != expected || raw == 0 || raw > layout.segment || HEADER + payload != frame.len() {
        return Err("LLZ1BLK lengths".into());
    }
    // 無圧縮は payload が生データそのもの。LZ は生データより短い場合だけ（そうでなければ無圧縮にする）。
    if (frame[10] == 0 && payload != raw) || (frame[10] == 1 && (payload < 5 || payload >= raw)) {
        return Err("LLZ1BLK canonical method".into());
    }
    let mut wire = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    wire.update(&frame[..24]);
    wire.update(&frame[28..]);
    if wire.finalize() as u32 != field(frame, 24) {
        return Err("LLZ1BLK wire CRC".into());
    }
    Ok(())
}

/// segment の wave 開始位置（file 内の byte 位置）。
pub fn wave_start(block: usize, layout: Layout) -> usize {
    block / WAVE * WAVE * layout.segment
}

/// 履歴として必要な範囲の先頭（wave 開始から窓長だけ前、file 先頭より前には出ない）。
pub fn history_start(block: usize, layout: Layout) -> usize {
    wave_start(block, layout).saturating_sub(WINDOW)
}

/// file 内の segment 番号 `block` の frame を復号する。`base` は file の byte 位置
/// `base_start..wave_start(block)` の履歴（`base_start <= history_start(block)` なら十分）。
/// 窓・規則の外を指す参照、壊れた payload、CRC の不一致は誤りとして返す。
#[cfg(test)]
pub fn decode_frame(
    frame: &[u8],
    expected: usize,
    block: usize,
    base: &[u8],
    base_start: usize,
    layout: Layout,
) -> Result<Vec<u8>, String> {
    decode_with(
        frame,
        expected,
        block,
        &codec::SliceBase {
            data: base,
            start: base_start,
        },
        layout,
    )
}

/// `decode_frame` と同じだが、履歴を segment の列（segment 番号 `first` から wave 開始まで、各 segment 長）で渡す。
pub fn decode_frame_blocks<T: AsRef<[u8]>>(
    frame: &[u8],
    expected: usize,
    block: usize,
    blocks: &[T],
    first: usize,
    layout: Layout,
) -> Result<Vec<u8>, String> {
    if blocks.iter().any(|b| b.as_ref().len() != layout.segment) {
        return Err("LLZ1BLK history block size".into());
    }
    decode_with(
        frame,
        expected,
        block,
        &codec::BlocksBase {
            blocks,
            first,
            shift: layout.shift(),
        },
        layout,
    )
}

fn decode_with(
    frame: &[u8],
    expected: usize,
    block: usize,
    base: &impl codec::Base,
    layout: Layout,
) -> Result<Vec<u8>, String> {
    validate_frame(frame, expected, layout)?;
    let payload = &frame[HEADER..];
    let raw = if frame[10] == 0 {
        payload.to_vec()
    } else {
        let start = block * layout.segment;
        let scope = mf::Scope {
            end: start + expected,
            seg_start: start,
            wave_start: wave_start(block, layout),
        };
        let mut own = Vec::new();
        own.try_reserve_exact(expected)
            .map_err(|_| "LLZ1BLK allocation".to_string())?;
        // 近傍符号の有無（frame revision 1 だけ無し）で単相化した復号器を選ぶ。
        if layout.near {
            codec::decode_segment::<true>(payload, base, &mut own, &scope, WINDOW)?;
        } else {
            codec::decode_segment::<false>(payload, base, &mut own, &scope, WINDOW)?;
        }
        if own.len() != expected {
            return Err("LLZ1BLK decoded size".into());
        }
        own
    };
    if crc32(&raw) != field(frame, 20) {
        return Err("LLZ1BLK raw CRC".into());
    }
    Ok(raw)
}

fn frame(method: u8, raw: &[u8], payload: &[u8], frame_rev: u16) -> Vec<u8> {
    let mut f = Vec::with_capacity(HEADER + payload.len());
    f.extend_from_slice(MAGIC);
    f.extend_from_slice(&frame_rev.to_le_bytes());
    f.push(method);
    f.push(0);
    f.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    f.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    f.extend_from_slice(&crc32(raw).to_le_bytes());
    f.extend_from_slice(&[0; 8]);
    f.extend_from_slice(payload);
    let mut wire = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    wire.update(&f[..24]);
    wire.update(&f[28..]);
    let value = wire.finalize() as u32;
    f[24..28].copy_from_slice(&value.to_le_bytes());
    f
}

/// 一致置き場の確保量の目標上限（revision 14）。1 segment（4MiB）の置き場は通常 100MiB 前後で、
/// 4 segment の batch と探索単位の増分（`MAX_PAIRS` × 1MiB × 8B ＝ 128MiB）が収まる。
pub const POOL_BUDGET: usize = 640 << 20;

/// 作成の配分（形式ではなく、出力 byte に影響しない資源の割り当て）。
/// 探索単位はどの revision も 1MiB（thread 同期の単位。前処理の大きさと木の余白を決める）。
/// revision 12・13 は 4 segment（4MiB）を一度に parse し、置き場に上限を設けない。
/// revision 14 は parse の batch は最大 4 segment（16MiB）で、置き場は `POOL_BUDGET` に収める。
fn plan_for(layout: Layout, threads: usize) -> par::Plan {
    if layout == LAYOUT_14 {
        par::Plan {
            find_unit: 1 << 20,
            batch: threads.clamp(1, 4),
            pool_budget: POOL_BUDGET,
            chunk_matches: (1 << 20) / 8,
        }
    } else {
        par::Plan {
            find_unit: 1 << 20,
            batch: 4,
            pool_budget: usize::MAX,
            chunk_matches: (1 << 20) / 8,
        }
    }
}

/// file 全体を segment ごとの LLZ1BLK frame にし、segment 番号順に sink へ渡す。threads 本で
/// 並列化するが、frame の byte は thread 数によらず同じ。frame は batch ごとに順に渡すので、
/// 全 frame を溜めない。
pub fn encode_file(
    data: &[u8],
    threads: usize,
    layout: Layout,
    sink: &mut dyn FnMut(&[u8]) -> Result<(), String>,
) -> Result<(), String> {
    if (data.len() as u64) < MIN_ENTRY || data.len() as u64 > MAX_ENCODE_ENTRY {
        return Err("LLZ1BLK entry size outside the encoder range".into());
    }
    encode_blocks_with(data, threads, layout, &plan_for(layout, threads), sink).map(|_| ())
}

/// 長さの範囲を確かめずに frame を sink へ渡す（試験で小さな入力・小さな plan を使うため）。
fn encode_blocks_with(
    data: &[u8],
    threads: usize,
    layout: Layout,
    plan: &par::Plan,
    sink: &mut dyn FnMut(&[u8]) -> Result<(), String>,
) -> Result<par::Stats, String> {
    if !matches!(layout, LAYOUT_12 | LAYOUT_13 | LAYOUT_14) {
        return Err("LLZ1BLK unknown layout".into());
    }
    if data.len() >= u32::MAX as usize {
        return Err("LLZ1BLK entry exceeds 4GiB".into());
    }
    // 窓は file 長以下に抑える（木の大きさを決める。距離は常に WINDOW 未満）。
    let window = WINDOW.min(data.len().max(1 << 16));
    let settings = codec::Settings {
        window,
        cut: CUT,
        nice: NICE,
        segment: layout.segment,
        wave: WAVE,
        near: layout.near,
    };
    let mut emitted = 0usize;
    let stats = par::encode_bodies(data, &settings, plan, threads, &mut |k, body| {
        if k != emitted {
            return Err("LLZ1BLK segment order".into());
        }
        emitted += 1;
        let from = k * layout.segment;
        let raw = &data[from..(from + layout.segment).min(data.len())];
        if body.len() < raw.len() && body.len() >= 5 {
            sink(&frame(1, raw, &body, layout.frame_rev))
        } else {
            sink(&frame(0, raw, raw, layout.frame_rev))
        }
    })?;
    if emitted != data.len().div_ceil(layout.segment) {
        return Err("LLZ1BLK segment count".into());
    }
    Ok(stats)
}

/// frame 列を集めて返す（試験用。製品は `encode_file` の sink へ逐次渡す）。
#[cfg(test)]
fn encode_blocks(data: &[u8], threads: usize, layout: Layout) -> Result<Vec<Vec<u8>>, String> {
    let mut frames = Vec::new();
    encode_blocks_with(
        data,
        threads,
        layout,
        &plan_for(layout, threads),
        &mut |f| {
            frames.push(f.to_vec());
            Ok(())
        },
    )?;
    Ok(frames)
}

#[cfg(test)]
mod tests {
    use super::*;
    use codec::sym::{NearSpec, Sym, encode as emit_symbols};

    /// revision 12・13 の segment 長（1MiB）。revision 14 の試験は `LAYOUT_14.segment` を使う。
    const SEGMENT: usize = 1 << 20;

    /// frame revision から形式を引く（試験の短縮）。
    fn lay(frame_rev: u16) -> Layout {
        match frame_rev {
            1 => LAYOUT_12,
            2 => LAYOUT_13,
            _ => LAYOUT_14,
        }
    }

    /// 決定的な疑似乱数で、長距離の重複を含むテキスト風データを作る。
    fn sample(len: usize) -> Vec<u8> {
        let words: Vec<&[u8]> = vec![
            b"alpha ",
            b"beta ",
            b"gamma ",
            b"delta ",
            b"<page>",
            b"</page>\n",
            b"the ",
            b"of ",
            b"compression ",
            b"archive ",
            b"0123456789",
            b"\n",
        ];
        let mut x = 0x1234_5678u32;
        let mut out = Vec::with_capacity(len);
        while out.len() < len {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            if x.is_multiple_of(97) && out.len() > 3 << 20 {
                // 遠い過去（約2〜3MiB前、別の wave）の断片を写し、長距離の一致を作る。
                let from = out.len() - (2 << 20) - (x as usize % (1 << 20));
                let piece: Vec<u8> = out[from..from + 200].to_vec();
                out.extend_from_slice(&piece);
            } else {
                out.extend_from_slice(words[x as usize % words.len()]);
            }
        }
        out.truncate(len);
        out
    }

    /// rep からわずかにずれた距離の一致が続くデータ。先頭は圧縮できない乱数で、その後は
    /// 約 100000 byte 前（±200）から 48 byte を写し、3 byte の乱数で区切る。距離が毎回少しずつ
    /// 違うので、通常の距離符号（約 17bit）より近傍符号（差の slot と下位 bit）が安い。
    fn jittered(len: usize) -> Vec<u8> {
        let mut x = 0x2468_ace1u32;
        let mut next = move || {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x
        };
        let mut out: Vec<u8> = (0..200_000).map(|_| next() as u8).collect();
        while out.len() < len {
            let d = 100_000 + (next() % 400) as usize;
            let from = out.len() - d;
            let piece: Vec<u8> = out[from..from + 48].to_vec();
            out.extend_from_slice(&piece);
            for _ in 0..3 {
                out.push(next() as u8);
            }
        }
        out.truncate(len);
        out
    }

    /// file 全体を逐次に復号する（履歴は file 先頭から全部渡す）。
    fn decode_all(frames: &[Vec<u8>], len: usize, rev: u16) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        for (k, f) in frames.iter().enumerate() {
            let segment = lay(rev).segment;
            let expected = (len - k * segment).min(segment);
            let ws = wave_start(k, lay(rev));
            let raw = decode_frame(f, expected, k, &out[..ws], 0, lay(rev))?;
            out.extend_from_slice(&raw);
        }
        Ok(out)
    }

    /// wire CRC を付け直す（header や payload を書き換えた frame を構造検査まで届かせる）。
    fn reseal(frame: &mut [u8]) {
        let mut wire = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
        wire.update(&frame[..24]);
        wire.update(&frame[28..]);
        let value = wire.finalize() as u32;
        frame[24..28].copy_from_slice(&value.to_le_bytes());
    }

    #[test]
    fn llz_round_trip_and_thread_independence() {
        // 6 block（3 wave）。debug の試験でも時間がかからない長さにする。
        let data = sample((5 << 20) + 12_345);
        for rev in [FRAME_REV_1, FRAME_REV_2] {
            let one = encode_blocks(&data, 1, lay(rev)).unwrap();
            let four = encode_blocks(&data, 4, lay(rev)).unwrap();
            assert_eq!(
                one, four,
                "frames must not depend on the thread count (rev {rev})"
            );
            assert_eq!(decode_all(&one, data.len(), rev).unwrap(), data);
            let total: usize = one.iter().map(Vec::len).sum();
            assert!(total < data.len() / 2, "sample should compress: {total}");
            // 同じ wave の2つ目の block は、wave 開始までの履歴だけで復号できる（並列復号の前提）。
            let k = 3;
            let ws = wave_start(k, lay(rev));
            let decoded = decode_all(&one[..k], k * SEGMENT, rev).unwrap();
            let raw = decode_frame(&one[k], SEGMENT, k, &decoded[..ws], 0, lay(rev)).unwrap();
            assert_eq!(raw, data[k * SEGMENT..(k + 1) * SEGMENT]);
            // 窓分だけ残した短い履歴でも復号できる。
            let hs = history_start(k, lay(rev));
            let raw = decode_frame(&one[k], SEGMENT, k, &decoded[hs..ws], hs, lay(rev)).unwrap();
            assert_eq!(raw, data[k * SEGMENT..(k + 1) * SEGMENT]);
            // block の列で渡しても同じ結果になる。
            let blocks: Vec<&[u8]> = decoded[..ws].chunks(SEGMENT).collect();
            let raw = decode_frame_blocks(&one[k], SEGMENT, k, &blocks, 0, lay(rev)).unwrap();
            assert_eq!(raw, data[k * SEGMENT..(k + 1) * SEGMENT]);
            // 履歴から block 0 を欠くと、block 0 を参照する一致は範囲外として拒否する。
            assert!(decode_frame_blocks(&one[k], SEGMENT, k, &blocks[1..], 1, lay(rev)).is_err());
        }
    }

    /// frame revision 1 の frame は、近傍符号を足す前の製品と byte 単位で同じ（回帰の基準）。
    /// 長さと CRC32 は、変更前の製品で `encode_blocks(sample(5MiB+12345), 1)` の frame を連結して記録した値。
    #[test]
    fn llz_rev1_frames_match_the_pre_near_baseline() {
        let data = sample((5 << 20) + 12_345);
        let all = encode_blocks(&data, 1, lay(FRAME_REV_1)).unwrap().concat();
        assert_eq!(all.len(), 504_020);
        assert_eq!(crc32(&all), 0x22d9_3d12);
    }

    /// frame revision 2 の frame は、frame revision 3（archive revision 14）を足す前の製品と byte 単位で同じ
    /// （回帰の基準）。値は変更前の製品で `encode_blocks(sample(5MiB+12345), 1, 2)` の frame を連結して記録した。
    #[test]
    fn llz_rev2_frames_match_the_pre_rev14_baseline() {
        let data = sample((5 << 20) + 12_345);
        let all = encode_blocks(&data, 1, lay(FRAME_REV_2)).unwrap().concat();
        assert_eq!(all.len(), 504_817);
        assert_eq!(crc32(&all), 0xd9d2_d5d3);
    }

    #[test]
    fn llz_near_codes_shrink_jittered_distances() {
        let data = jittered((1 << 20) + (1 << 19));
        let one = encode_blocks(&data, 1, lay(FRAME_REV_1)).unwrap();
        let two = encode_blocks(&data, 1, lay(FRAME_REV_2)).unwrap();
        let four = encode_blocks(&data, 4, lay(FRAME_REV_2)).unwrap();
        assert_eq!(
            two, four,
            "rev 2 frames must not depend on the thread count"
        );
        assert_eq!(decode_all(&one, data.len(), FRAME_REV_1).unwrap(), data);
        assert_eq!(decode_all(&two, data.len(), FRAME_REV_2).unwrap(), data);
        let rev1: usize = one.iter().map(Vec::len).sum();
        let rev2: usize = two.iter().map(Vec::len).sum();
        assert!(
            rev2 * 100 < rev1 * 99,
            "near codes should save at least 1%: rev1 {rev1}, rev2 {rev2}"
        );
        // frame の配置は同じで、header の frame revision だけが違う。
        assert_eq!(&two[0][8..10], &FRAME_REV_2.to_le_bytes());
        assert_eq!(&one[0][8..10], &FRAME_REV_1.to_le_bytes());
    }

    #[test]
    fn llz_rejects_corruption_and_missing_history() {
        let data = sample(6 << 20);
        for rev in [FRAME_REV_1, FRAME_REV_2] {
            let frames = encode_blocks(&data, 2, lay(rev)).unwrap();
            let k = 4;
            let decoded = decode_all(&frames[..k], k * SEGMENT, rev).unwrap();
            let ws = wave_start(k, lay(rev));
            // 履歴が足りない（base_start が後ろすぎる）と、範囲外参照として拒否する。
            let short = ws - (1 << 20);
            assert!(
                decode_frame(&frames[k], SEGMENT, k, &decoded[short..ws], short, lay(rev)).is_err()
            );
            // 履歴の終わりが wave 開始と合わなければ拒否する。
            assert!(decode_frame(&frames[k], SEGMENT, k, &decoded[..ws - 1], 0, lay(rev)).is_err());
            // payload を壊すと wire CRC で拒否する。
            let mut bad = frames[k].clone();
            let last = bad.len() - 1;
            bad[last] ^= 0x40;
            assert!(validate_frame(&bad, SEGMENT, lay(rev)).is_err());
            // 生データ長が違えば拒否する。
            assert!(validate_frame(&frames[k], SEGMENT - 1, lay(rev)).is_err());
            // 無圧縮 frame も正しく往復する。
            let raw = vec![7u8; 1000];
            let stored = frame(0, &raw, &raw, rev);
            assert_eq!(
                decode_frame(&stored, 1000, 0, &[], 0, lay(rev)).unwrap(),
                raw
            );
        }
    }

    /// archive revision と frame revision は 1 対 1（12 は 1、13 は 2）で、取り違えた frame は拒否する。
    #[test]
    fn llz_frame_revision_boundaries() {
        assert_eq!(layout_for(12), Some(LAYOUT_12));
        assert_eq!(layout_for(13), Some(LAYOUT_13));
        assert_eq!(layout_for(14), Some(LAYOUT_14));
        assert_eq!(layout_for(11), None);
        assert_eq!(layout_for(15), None);

        let data = jittered((1 << 20) + 5000);
        let rev1 = encode_blocks(&data, 1, lay(FRAME_REV_1)).unwrap();
        let rev2 = encode_blocks(&data, 1, lay(FRAME_REV_2)).unwrap();
        let expected = SEGMENT;
        assert_eq!(rev1[0][10], 1, "LZ frame");
        assert_eq!(rev2[0][10], 1, "LZ frame");
        assert!(validate_frame(&rev1[0], expected, lay(FRAME_REV_1)).is_ok());
        assert!(validate_frame(&rev2[0], expected, lay(FRAME_REV_2)).is_ok());
        assert!(validate_frame(&rev1[0], expected, lay(FRAME_REV_2)).is_err());
        assert!(validate_frame(&rev2[0], expected, lay(FRAME_REV_1)).is_err());
        // 無圧縮（method 0）の frame も同じ規則。
        let raw = vec![9u8; 500];
        let stored1 = frame(0, &raw, &raw, FRAME_REV_1);
        let stored2 = frame(0, &raw, &raw, FRAME_REV_2);
        assert!(validate_frame(&stored1, 500, lay(FRAME_REV_1)).is_ok());
        assert!(validate_frame(&stored2, 500, lay(FRAME_REV_2)).is_ok());
        assert!(validate_frame(&stored1, 500, lay(FRAME_REV_2)).is_err());
        assert!(validate_frame(&stored2, 500, lay(FRAME_REV_1)).is_err());
        // 未知の frame revision は書き手も読み手も拒否する。
        let unknown = Layout {
            frame_rev: 4,
            ..LAYOUT_14
        };
        assert!(encode_blocks(&data, 1, unknown).is_err());
        assert!(validate_frame(&rev2[0], expected, unknown).is_err());
        // frame revision 3 の形式は、frame revision 2 の frame を受け入れない（逆も同じ）。
        assert!(validate_frame(&rev2[0], expected, LAYOUT_14).is_err());
        let mut as3 = rev2[0].clone();
        as3[8..10].copy_from_slice(&FRAME_REV_3.to_le_bytes());
        reseal(&mut as3);
        assert!(validate_frame(&as3, expected, LAYOUT_13).is_err());
        assert!(validate_frame(&as3, expected, LAYOUT_14).is_ok());

        // frame revision を書き換えて wire CRC を付け直しても、期待する revision と合わなければ拒否する。
        // 書き換えた revision に合わせて復号しても、bit 列が違うので誤りとして落ちる（panic しない）。
        let mut as1 = rev2[0].clone();
        as1[8..10].copy_from_slice(&FRAME_REV_1.to_le_bytes());
        reseal(&mut as1);
        assert!(validate_frame(&as1, expected, lay(FRAME_REV_2)).is_err());
        assert!(decode_frame(&as1, expected, 0, &[], 0, lay(FRAME_REV_2)).is_err());
        assert!(decode_frame(&as1, expected, 0, &[], 0, lay(FRAME_REV_1)).is_err());
        let mut as2 = rev1[0].clone();
        as2[8..10].copy_from_slice(&FRAME_REV_2.to_le_bytes());
        reseal(&mut as2);
        assert!(validate_frame(&as2, expected, lay(FRAME_REV_1)).is_err());
        assert!(decode_frame(&as2, expected, 0, &[], 0, lay(FRAME_REV_1)).is_err());
        assert!(decode_frame(&as2, expected, 0, &[], 0, lay(FRAME_REV_2)).is_err());
    }

    /// 近傍符号の正規形に反する記号列を直接作り、wire CRC を付けた frame として復号器へ流す。
    /// byte の反転では wire CRC や生データ CRC で先に落ちるので、構造の検査はこの方法で確かめる。
    #[test]
    fn llz_rejects_noncanonical_near_symbols() {
        let lits =
            |n: usize| -> Vec<Sym> { (0..n).map(|i| Sym::Lit(b'a' + (i % 20) as u8)).collect() };
        let normal = |len, dist| Sym::Match {
            len,
            dist,
            near: None,
        };
        let near = |i, neg, g| Sym::Match {
            len: 2,
            dist: 0,
            near: Some(NearSpec { i, neg, g }),
        };
        // 符号を frame に包んで block `block` として復号する（raw は復号結果と一致しなくてよい）。
        // 失敗は一致の検査で起きるので、生データ長は十分大きい 4096 にする。
        let run = |syms: Vec<Sym>, block: usize, rev: u16| -> Result<Vec<u8>, String> {
            let body = emit_symbols(&syms, block * SEGMENT, true);
            let raw = vec![0u8; 4096];
            let f = frame(1, &raw, &body, rev);
            decode_frame(&f, 4096, block, &[], 0, lay(rev))
        };
        let err = |r: Result<Vec<u8>, String>, what: &str| {
            let e = r.expect_err(what);
            assert!(e.contains(what), "expected {what:?}, got {e:?}");
        };

        // 別名の選択：初期 rep はすべて 0 なので、i=1 や i=3 は i=0 の別名。
        for i in [1, 3] {
            let mut s = lits(8);
            s.push(near(i, false, 0));
            err(run(s, 0, FRAME_REV_2), "non-canonical near selector");
        }

        // 結果が更新前の rep と等しい距離（rep=[3,0,0,0]、i=0 から差 3 を引くと 0 で rep1 と等しい）。
        let mut s = lits(8);
        s.push(normal(2, 3));
        s.push(near(0, true, 2));
        err(run(s, 0, FRAME_REV_2), "near distance equals a rep");

        // 負方向で rep 距離より大きい差（3 から差 4 を引くと 0 を下回る）。
        let mut s = lits(8);
        s.push(normal(2, 3));
        s.push(near(0, true, 3));
        err(run(s, 0, FRAME_REV_2), "near distance below zero");

        // 出力位置以上の距離（pos=8 で距離 20）。
        let mut s = lits(8);
        s.push(near(0, false, 19));
        err(run(s, 0, FRAME_REV_2), "distance beyond output");

        // 同じ wave の他 block を指す距離（block 1 の wave 開始は 0 で、block 1 の先頭より前は読めない）。
        let mut s = lits(8);
        s.push(normal(2, 3));
        s.push(near(0, false, 199));
        err(
            run(s, 1, FRAME_REV_2),
            "match source outside the segment scope or window",
        );

        // revision 1 の復号器は近傍の bit を読まないので、同じ記号列は別の意味になり、誤りとして落ちる。
        let mut s = lits(8);
        s.push(near(0, false, 19));
        assert!(run(s, 0, FRAME_REV_1).is_err());
    }

    /// 窓の外を指す近傍距離は拒否する（窓を小さくした復号器で直接確かめる）。
    #[test]
    fn llz_near_distance_outside_the_window_is_rejected() {
        let mut syms: Vec<Sym> = (0..6000).map(|i| Sym::Lit((i * 7 % 251) as u8)).collect();
        syms.push(Sym::Match {
            len: 2,
            dist: 4000,
            near: None,
        });
        syms.push(Sym::Match {
            len: 2,
            dist: 0,
            // rep0=4000 から差 200 で距離 4200（窓 4096 の外）。
            near: Some(NearSpec {
                i: 0,
                neg: false,
                g: 199,
            }),
        });
        let body = emit_symbols(&syms, 0, true);
        let scope = mf::Scope {
            end: 7000,
            seg_start: 0,
            wave_start: 0,
        };
        let base = codec::SliceBase {
            data: &[],
            start: 0,
        };
        let mut own = Vec::new();
        let e = codec::decode_segment::<true>(&body, &base, &mut own, &scope, 4096).unwrap_err();
        assert!(e.contains("outside the segment scope or window"), "{e}");
        // 窓を広げれば同じ記号列は窓の理由では拒否されない（窓の検査が効いていること）。
        let mut own = Vec::new();
        let e = codec::decode_segment::<true>(&body, &base, &mut own, &scope, 8192);
        assert!(
            !matches!(e, Err(m) if m.contains("outside the segment scope or window")),
            "{e:?}"
        );
    }

    /// 正規形の近傍記号は復号できる（emitter と復号器の対照）。
    #[test]
    fn llz_valid_near_symbols_decode() {
        let text = b"abcdefghijklmnop";
        let mut syms: Vec<Sym> = text.iter().map(|&b| Sym::Lit(b)).collect();
        // 距離 15（16 byte 前）で 16 byte を写す。rep=[15,0,0,0]。
        syms.push(Sym::Match {
            len: 16,
            dist: 15,
            near: None,
        });
        // rep0=15 から正の差 3 -> 距離 18。
        syms.push(Sym::Match {
            len: 8,
            dist: 0,
            near: Some(NearSpec {
                i: 0,
                neg: false,
                g: 2,
            }),
        });
        // 更新前の rep=[18,15,0,0]。rep1=15 から負の差 4 -> 距離 11。
        syms.push(Sym::Match {
            len: 5,
            dist: 0,
            near: Some(NearSpec {
                i: 1,
                neg: true,
                g: 3,
            }),
        });
        // 更新前の rep=[11,18,15,0]。rep2=15 から正の差 17 -> 距離 32（slot 8、平坦な下位 bit を使う）。
        syms.push(Sym::Match {
            len: 6,
            dist: 0,
            near: Some(NearSpec {
                i: 2,
                neg: false,
                g: 16,
            }),
        });
        let mut want = text.to_vec();
        for (len, dist) in [(16usize, 15usize), (8, 18), (5, 11), (6, 32)] {
            for _ in 0..len {
                let b = want[want.len() - dist - 1];
                want.push(b);
            }
        }
        let body = emit_symbols(&syms, 0, true);
        let scope = mf::Scope {
            end: want.len(),
            seg_start: 0,
            wave_start: 0,
        };
        let base = codec::SliceBase {
            data: &[],
            start: 0,
        };
        let mut own = Vec::new();
        codec::decode_segment::<true>(&body, &base, &mut own, &scope, WINDOW).unwrap();
        assert_eq!(own, want);
    }

    /// frame revision 3 の長さ規則：生データは 1..=4MiB（method 0 も可）。1MiB 形式との取り違えは拒否する。
    #[test]
    fn llz_rev3_frame_lengths() {
        let seg = LAYOUT_14.segment;
        assert_eq!(seg, 4 << 20);
        let full = vec![5u8; seg];
        let stored = frame(0, &full, &full, FRAME_REV_3);
        assert!(validate_frame(&stored, seg, LAYOUT_14).is_ok());
        // 端数の segment も可。
        let tail = &full[..1_234_567];
        assert!(validate_frame(&frame(0, tail, tail, FRAME_REV_3), tail.len(), LAYOUT_14).is_ok());
        // 期待値と違う長さ（4MiB の frame を 1MiB として読む）は拒否する。
        assert!(validate_frame(&stored, 1 << 20, LAYOUT_14).is_err());
        // segment を超える長さは期待値が合っていても拒否する。
        let over = vec![5u8; seg + 1];
        let over_frame = frame(0, &over, &over, FRAME_REV_3);
        assert!(validate_frame(&over_frame, seg + 1, LAYOUT_14).is_err());
        // 1MiB 形式（revision 12・13）は 4MiB の frame を受け入れず、frame revision も取り違えない。
        assert!(validate_frame(&stored, seg, LAYOUT_13).is_err());
        let narrow = frame(0, &full[..1 << 20], &full[..1 << 20], FRAME_REV_2);
        assert!(validate_frame(&narrow, 1 << 20, LAYOUT_14).is_err());
        // 空の segment は無い。
        assert!(validate_frame(&frame(0, &[], &[], FRAME_REV_3), 0, LAYOUT_14).is_err());
        // wave は 2 segment（8MiB）、履歴の下限は wave 開始の 64MiB 前。
        assert_eq!(wave_start(3, LAYOUT_14), 2 * seg);
        assert_eq!(wave_start(4, LAYOUT_14), 4 * seg);
        assert_eq!(history_start(3, LAYOUT_14), 0);
        assert_eq!(history_start(20, LAYOUT_14), 20 * seg - WINDOW);
    }

    /// segment 4MiB の参照規則（記号列を直接作って確かめる。符号化は要らず debug でも軽い）。
    /// - 同じ wave の他 segment（4MiB 粒度）は参照できない。
    /// - wave 開始より前は、segment の境界をまたぐ参照も含めて、連続した slice の履歴と
    ///   segment の列の履歴で同じ結果になる。
    #[test]
    fn llz_rev3_reference_scope_uses_four_mib_segments() {
        let seg = LAYOUT_14.segment;
        let lits = || -> Vec<Sym> { (0..8).map(|i| Sym::Lit(b'a' + i as u8)).collect() };
        let expect_err = |syms: Vec<Sym>, block: usize, base: &[u8], base_start: usize| {
            let body = emit_symbols(&syms, block * seg, true);
            let raw = vec![0u8; 4096];
            let f = frame(1, &raw, &body, FRAME_REV_3);
            let e = decode_frame(&f, 4096, block, base, base_start, LAYOUT_14).unwrap_err();
            assert!(
                e.contains("match source outside the segment scope or window"),
                "{e}"
            );
        };
        let copy = |len: usize, dist: usize| Sym::Match {
            len,
            dist: dist as u32,
            near: None,
        };
        // 同じ wave の他 segment：segment 1（wave 開始は 0）が segment 0 の末尾を指す。
        let mut s = lits();
        s.push(copy(200, (seg + 8 - (seg - 100)) - 1));
        expect_err(s, 1, &[], 0);
        // segment 3（wave 開始は 8MiB）が同じ wave の segment 2 の中を指す（1MiB 粒度では別 wave の位置）。
        let history: Vec<u8> = (0..2 * seg).map(|i| (i * 7 % 251) as u8).collect();
        let mut s = lits();
        s.push(copy(200, (3 * seg + 8 - (2 * seg + 1000)) - 1));
        expect_err(s, 3, &history, 0);
        // wave 開始をまたぐ参照（8MiB の手前から 200 byte）も拒否する。
        let mut s = lits();
        s.push(copy(200, (3 * seg + 8 - (2 * seg - 100)) - 1));
        expect_err(s, 3, &history, 0);

        // segment 2 は wave 開始（8MiB）より前の 2 segment を読める。segment の境界（4MiB）をまたぐ参照を含む。
        let source = seg - 100;
        let mut s = lits();
        s.push(copy(200, (2 * seg + 8 - source) - 1));
        let mut want: Vec<u8> = (0..8).map(|i| b'a' + i as u8).collect();
        want.extend_from_slice(&history[source..source + 200]);
        let body = emit_symbols(&s, 2 * seg, true);
        let f = frame(1, &want, &body, FRAME_REV_3);
        assert!(f[10] == 1, "LZ frame");
        let by_slice = decode_frame(&f, want.len(), 2, &history, 0, LAYOUT_14).unwrap();
        assert_eq!(by_slice, want);
        let blocks: Vec<&[u8]> = history.chunks(seg).collect();
        let by_blocks = decode_frame_blocks(&f, want.len(), 2, &blocks, 0, LAYOUT_14).unwrap();
        assert_eq!(by_blocks, want);
        // 履歴の block が segment 長でなければ拒否する。
        let short: Vec<&[u8]> = history.chunks(seg - 1).collect();
        assert!(decode_frame_blocks(&f, want.len(), 2, &short, 0, LAYOUT_14).is_err());
        // 先頭の segment を欠く履歴（first=1）では、segment 0 を指す参照を拒否する。
        let mut s = lits();
        s.push(copy(200, (2 * seg + 8 - (seg - 100)) - 1));
        let body = emit_symbols(&s, 2 * seg, true);
        let f = frame(1, &want, &body, FRAME_REV_3);
        assert!(decode_frame_blocks(&f, want.len(), 2, &blocks[1..], 1, LAYOUT_14).is_err());
    }

    /// 小さな segment・探索単位・chunk で body を集める（置き場の途中解放を起こす試験用）。
    fn bodies_with(
        data: &[u8],
        threads: usize,
        plan: &par::Plan,
    ) -> Result<(Vec<Vec<u8>>, par::Stats), String> {
        let settings = codec::Settings {
            window: 256 << 10,
            cut: CUT,
            nice: NICE,
            segment: 64 << 10,
            wave: WAVE,
            near: true,
        };
        let mut out = Vec::new();
        let stats = par::encode_bodies(data, &settings, plan, threads, &mut |k, b| {
            assert_eq!(k, out.len(), "bodies must arrive in segment order");
            out.push(b);
            Ok(())
        })?;
        Ok((out, stats))
    }

    /// 置き場の予算・batch・探索単位・thread 数は body の byte を変えない。予算を極小にして
    /// segment の完成前に途中解放を起こしても同じで、確保量は予算を超えない。
    #[test]
    #[cfg_attr(
        debug_assertions,
        ignore = "多数の符号化を繰り返すため debug では遅い。release で実行する"
    )]
    fn llz_pool_budget_does_not_change_bodies() {
        let data = sample((2 << 20) + 4321);
        let unlimited = par::Plan {
            find_unit: 16 << 10,
            batch: 4,
            pool_budget: usize::MAX,
            chunk_matches: 1024,
        };
        let (reference, base) = bodies_with(&data, 4, &unlimited).unwrap();
        assert_eq!(reference.len(), data.len().div_ceil(64 << 10));
        assert_eq!(base.early_parses, 0);
        // 単位・batch・thread 数を変えても同じ。
        for (unit, batch, threads) in [(64 << 10, 1, 1), (32 << 10, 2, 2), (16 << 10, 3, 16)] {
            let plan = par::Plan {
                find_unit: unit,
                batch,
                ..unlimited
            };
            let (got, _) = bodies_with(&data, threads, &plan).unwrap();
            assert_eq!(
                got, reference,
                "unit {unit} batch {batch} threads {threads}"
            );
        }
        // 予算を小さくしていき、通った設定は同じ body で、確保量が予算以内であることを確かめる。
        let mut early = 0;
        let mut accepted = 0;
        for threads in [1usize, 4] {
            let growth = (16 << 10) * par::MAX_PAIRS * 8 + threads * 1024 * 8;
            for step in 1..=24 {
                let budget = growth + step * (192 << 10);
                let plan = par::Plan {
                    pool_budget: budget,
                    batch: 4,
                    ..unlimited
                };
                match bodies_with(&data, threads, &plan) {
                    Ok((got, stats)) => {
                        assert_eq!(got, reference, "budget {budget} threads {threads}");
                        assert!(stats.peak_pool_bytes <= budget, "pool {stats:?} > {budget}");
                        early += stats.early_parses;
                        accepted += 1;
                    }
                    Err(e) => assert!(e.contains("memory budget"), "{e}"),
                }
            }
        }
        assert!(accepted > 0, "some budget must be large enough");
        assert!(early > 0, "a small budget must release segments early");
    }

    /// revision 14 の frame は thread 数（batch は min(thread, 4)）によらず同じ byte で、
    /// 連続して書き出した frame 列が一括の結果と一致する。
    #[test]
    #[cfg_attr(
        debug_assertions,
        ignore = "9MiB を 4MiB segment で符号化するため debug では遅い。release で実行する"
    )]
    fn llz_rev14_frames_do_not_depend_on_threads() {
        let data = sample((9 << 20) + 12_345);
        let one = encode_blocks(&data, 1, LAYOUT_14).unwrap();
        for threads in [2usize, 4, 16] {
            assert_eq!(encode_blocks(&data, threads, LAYOUT_14).unwrap(), one);
        }
    }

    /// frame revision 3 の往復：thread 数で frame の byte が変わらず、逐次の復号で元に戻る。
    /// 基準の値は archive revision 14 を足した製品で記録した（以後の変更で frame の byte が変わらないことを守る）。
    #[test]
    #[cfg_attr(
        debug_assertions,
        ignore = "9MiB を 4MiB segment で符号化するため debug では遅い。release で実行する"
    )]
    fn llz_rev3_round_trip_and_thread_independence() {
        let data = sample((9 << 20) + 12_345);
        let one = encode_blocks(&data, 1, LAYOUT_14).unwrap();
        let four = encode_blocks(&data, 4, LAYOUT_14).unwrap();
        assert_eq!(one, four, "frames must not depend on the thread count");
        assert_eq!(one.len(), 3, "4MiB + 4MiB + the tail");
        assert_eq!(decode_all(&one, data.len(), FRAME_REV_3).unwrap(), data);
        for f in &one {
            assert_eq!(&f[8..10], &FRAME_REV_3.to_le_bytes());
        }
        // 同じ wave の 2 つ目（segment 1）は wave 開始（先頭）までの履歴だけで復号できる。
        let raw = decode_frame(&one[1], LAYOUT_14.segment, 1, &[], 0, LAYOUT_14).unwrap();
        assert_eq!(raw, data[LAYOUT_14.segment..2 * LAYOUT_14.segment]);
        // segment 2（次の wave）は、前の wave の 2 segment を履歴として復号する。
        let blocks: Vec<&[u8]> = data[..2 * LAYOUT_14.segment]
            .chunks(LAYOUT_14.segment)
            .collect();
        let tail = data.len() - 2 * LAYOUT_14.segment;
        let raw = decode_frame_blocks(&one[2], tail, 2, &blocks, 0, LAYOUT_14).unwrap();
        assert_eq!(raw, data[2 * LAYOUT_14.segment..]);
        // 窓分だけ残した履歴（ここでは全部）でも、segment の列と連続した slice で結果が同じ。
        let by_slice = decode_frame(
            &one[2],
            tail,
            2,
            &data[..2 * LAYOUT_14.segment],
            0,
            LAYOUT_14,
        )
        .unwrap();
        assert_eq!(by_slice, raw);
        let total: usize = one.iter().map(Vec::len).sum();
        assert!(total < data.len() / 2, "sample should compress: {total}");
        // frame の byte の基準（長さと CRC32）。par.rs などの変更で frame が変わらないことを守る。
        let all = one.concat();
        assert_eq!(all.len(), 900_001);
        assert_eq!(crc32(&all), 0x6d2b_f80e);
        // frame revision 3 の bit 列は frame revision 2 と同じなので、近傍符号を使う復号器だけが通る。
        let mut as2 = one[0].clone();
        as2[8..10].copy_from_slice(&FRAME_REV_2.to_le_bytes());
        reseal(&mut as2);
        assert!(validate_frame(&as2, LAYOUT_14.segment, LAYOUT_14).is_err());
    }

    #[test]
    fn llz_encoder_range() {
        assert!(encode_file(&[0u8; 1024], 1, lay(FRAME_REV_1), &mut |_| Ok(())).is_err());
        assert!(
            encode_file(
                &vec![0u8; (MIN_ENTRY - 1) as usize],
                1,
                lay(FRAME_REV_2),
                &mut |_| Ok(())
            )
            .is_err()
        );
        assert!(encode_file(&[0u8; 1024], 1, LAYOUT_14, &mut |_| Ok(())).is_err());
    }
}
