//! 独立LHC1形式。LHA API/wireを変更せず、自己完結1MiB blockを順に処理する。
//! CRCは破損検出であり認証ではない。展開は検証済みentry単位のno-replace公開。
pub(crate) mod block;
mod delta16;
#[allow(dead_code)]
mod g32;
mod pipeline;
// PPMII系テキスト候補（LPM1BLK）。revision 11 の portfolio が使う。
mod ppm;
#[allow(dead_code)]
mod record;
mod spatial;

use crate::{Error, ExtractOptions, Limits, Progress, Result, SourceEntry, Summary};
use crate::{directory, operation::checkpoint, pathname::validate_entry_name};
use cap_std::fs::Dir;
use crc_fast::{CrcAlgorithm, Digest, checksum};
use serde::Serialize;
use std::{
    collections::{BinaryHeap, HashMap, VecDeque},
    fs::File,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        mpsc::{Receiver, Sender, channel},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub const BLOCK_BYTES: usize = 1 << 20;
pub const MAX_MANIFEST_BYTES: usize = 4 << 20;
pub const MAX_ENTRIES: u64 = 100_000;
/// Encoder/decoder scratch policy; manifest and caller input/output are separate.
pub const CODEC_MEMORY_BYTES: u64 = 64 << 20;
const HEADER: usize = 32;
const MAGIC: &[u8; 8] = b"LHC1ARC\0";
const END: &[u8; 8] = b"LHC1END\0";

#[derive(Debug, Clone)]
pub struct CreateOptions {
    pub limits: Limits,
    /// revision 2〜10 は明示指定。既定は revision 1 の出力を維持する。
    pub block_strategy: BlockStrategy,
    /// Reject before processing when less than the fixed codec reservation.
    /// Parallel creation also needs one reservation per worker.
    pub max_codec_memory_bytes: u64,
    /// Block-compression workers. 0 and 1 compress serially. Larger values use up to
    /// `min(threads, MAX_CREATE_WORKERS, max_codec_memory_bytes / CODEC_MEMORY_BYTES)`
    /// workers. The archive bytes are identical for every worker count.
    pub threads: usize,
    /// Skip `sync_all` of the finished archive before publishing (default: durable).
    pub skip_fsync: bool,
}
impl Default for CreateOptions {
    fn default() -> Self {
        Self {
            limits: Limits::default(),
            block_strategy: BlockStrategy::Mdl,
            max_codec_memory_bytes: CODEC_MEMORY_BYTES,
            threads: 0,
            skip_fsync: false,
        }
    }
}

/// Upper bound of parallel block-compression workers.
pub const MAX_CREATE_WORKERS: usize = 16;
// 研究由来の encoder は再帰・大きな局所配列を持ちうるため、mainと同等以上のstackを確保する。
const ENCODE_STACK_BYTES: usize = 16 << 20;

// threads と codec メモリ予約から、実際に使う worker 数を決める。
fn create_workers(options: &CreateOptions) -> usize {
    let by_memory = (options.max_codec_memory_bytes / CODEC_MEMORY_BYTES).max(1) as usize;
    options.threads.clamp(1, MAX_CREATE_WORKERS).min(by_memory)
}

// ---- 並列作成 ----
// workerは共有queueから「長いblockを先に」取り出す（LPT）。先頭blockが長くても他workerは
// 後続blockを処理でき、全体の尾も短くなる。結果は OrderedWriter が書庫順に並べ直して書く。

struct EncodeJob {
    id: u64,
    raw: Vec<u8>,
}
impl PartialEq for EncodeJob {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}
impl Eq for EncodeJob {}
impl PartialOrd for EncodeJob {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for EncodeJob {
    // BinaryHeap は最大を先に返す。長い block を優先し、同長なら書庫順で早い方を先にする。
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.raw
            .len()
            .cmp(&other.raw.len())
            .then_with(|| other.id.cmp(&self.id))
    }
}

struct EncodeQueue {
    state: Mutex<(BinaryHeap<EncodeJob>, bool)>,
    ready: Condvar,
}

struct EncodePool {
    queue: Arc<EncodeQueue>,
    results: Receiver<(u64, Result<Vec<u8>>)>,
}

impl EncodePool {
    fn start<'scope>(
        scope: &'scope std::thread::Scope<'scope, '_>,
        workers: usize,
        strategy: BlockStrategy,
    ) -> Result<Self> {
        let queue = Arc::new(EncodeQueue {
            state: Mutex::new((BinaryHeap::new(), false)),
            ready: Condvar::new(),
        });
        let (sender, results) = channel();
        // 先に pool を作っておく。途中の spawn が失敗して `?` で返っても Drop が queue を閉じるので、
        // 起動済み worker は condvar 待ちから抜けて終わり、scope の join が止まらない。
        let pool = Self {
            queue: Arc::clone(&queue),
            results,
        };
        for _ in 0..workers {
            let queue = Arc::clone(&queue);
            let sender: Sender<(u64, Result<Vec<u8>>)> = sender.clone();
            std::thread::Builder::new()
                .name("lhc-encode".into())
                .stack_size(ENCODE_STACK_BYTES)
                .spawn_scoped(scope, move || {
                    loop {
                        let job = {
                            let mut state = queue.state.lock().unwrap_or_else(|e| e.into_inner());
                            loop {
                                if let Some(job) = state.0.pop() {
                                    break Some(job);
                                }
                                if state.1 {
                                    break None;
                                }
                                state = queue.ready.wait(state).unwrap_or_else(|e| e.into_inner());
                            }
                        };
                        let Some(EncodeJob { id, raw }) = job else {
                            return;
                        };
                        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            compress_block_with_strategy(&raw, strategy)
                        }))
                        .unwrap_or_else(|_| {
                            Err(Error::Unsupported("LHC encode worker panic".into()))
                        });
                        drop(raw);
                        // 受信側が先に終了（エラー）していれば送信失敗するので、そのまま終わる。
                        if sender.send((id, result)).is_err() {
                            return;
                        }
                    }
                })?;
        }
        Ok(pool)
    }

    fn submit(&self, id: u64, raw: Vec<u8>) {
        let mut state = self.queue.state.lock().unwrap_or_else(|e| e.into_inner());
        state.0.push(EncodeJob { id, raw });
        drop(state);
        self.queue.ready.notify_one();
    }

    fn receive(&self) -> Result<(u64, Vec<u8>)> {
        let (id, result) = self
            .results
            .recv()
            .map_err(|_| Error::Unsupported("LHC encode workers disconnected".into()))?;
        Ok((id, result?))
    }
}

impl Drop for EncodePool {
    // 正常終了・エラーのどちらでも queue を閉じ、未着手 job を捨てて worker を終わらせる。
    // scope の終わりで全 worker が join される。
    fn drop(&mut self) {
        let mut state = self.queue.state.lock().unwrap_or_else(|e| e.into_inner());
        state.0.clear();
        state.1 = true;
        drop(state);
        self.queue.ready.notify_all();
    }
}

enum OrderItem {
    Frame(u64),
    Crc(u32),
}

// 圧縮結果を書庫順に書き出す。未書込み block は最大 window 個（raw/frame とも <= 1MiB 強）で、
// それを超えると最古の結果が揃うまで受信して待つ。
struct OrderedWriter {
    order: VecDeque<OrderItem>,
    done: HashMap<u64, Vec<u8>>,
    next_id: u64,
    outstanding: usize,
    window: usize,
}

impl OrderedWriter {
    fn new(workers: usize) -> Self {
        Self {
            order: VecDeque::new(),
            done: HashMap::new(),
            next_id: 0,
            outstanding: 0,
            window: workers.saturating_mul(4).max(1),
        }
    }

    fn submit(&mut self, pool: &EncodePool, raw: Vec<u8>, output: &mut impl Write) -> Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        pool.submit(id, raw);
        self.order.push_back(OrderItem::Frame(id));
        self.outstanding += 1;
        self.write_ready(output)?;
        while self.outstanding >= self.window {
            let (id, frame) = pool.receive()?;
            self.done.insert(id, frame);
            self.write_ready(output)?;
        }
        Ok(())
    }

    fn crc(&mut self, value: u32, output: &mut impl Write) -> Result<()> {
        self.order.push_back(OrderItem::Crc(value));
        self.write_ready(output)
    }

    fn finish(&mut self, pool: &EncodePool, output: &mut impl Write) -> Result<()> {
        while !self.order.is_empty() {
            let (id, frame) = pool.receive()?;
            self.done.insert(id, frame);
            self.write_ready(output)?;
        }
        Ok(())
    }

    fn write_ready(&mut self, output: &mut impl Write) -> Result<()> {
        while let Some(item) = self.order.front() {
            match *item {
                OrderItem::Crc(value) => output.write_all(&value.to_le_bytes())?,
                OrderItem::Frame(id) => {
                    let Some(frame) = self.done.remove(&id) else {
                        break;
                    };
                    write_frame(output, &frame)?;
                    self.outstanding -= 1;
                }
            }
            self.order.pop_front();
        }
        Ok(())
    }
}

fn write_frame(output: &mut impl Write, frame: &[u8]) -> Result<()> {
    output.write_all(&(frame.len() as u32).to_le_bytes())?;
    output.write_all(frame)?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    pub original_size: u64,
    /// Frame prefixes, complete frames and file CRC; archive/manifest fees are separate.
    pub compressed_size: u64,
    pub is_directory: bool,
    pub modified_unix_seconds: Option<i64>,
}

/// Compress at most 1MiB into a self-contained LHC1BLK frame.
pub fn compress_block(input: &[u8]) -> Result<Vec<u8>> {
    compress_block_with_history_mode(input, HistoryMode::PaidHistoryOrder)
}

/// Encoder-only choice; both modes use the same version and integer decoder.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum HistoryMode {
    #[default]
    PaidHistoryOrder,
    /// Controlled ablation: train only low-bit-first history trees.
    LowHistoryOnly,
}

/// Encoder strategies. Decoder requirements are always identified in the frame.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BlockStrategy {
    #[default]
    Mdl,
    /// Pays for MDL and both LZ trials, then selects the smallest complete frame.
    HybridTrial,
    /// Development heuristic: >=90% printable ASCII/whitespace selects MDL; otherwise LZ8.
    BinaryAdaptive,
    /// Experimental revision 3: causal copy plus four byte CDFs, with exact trial pruning.
    RecordTrial,
    /// Experimental revision 4: sampled BWT and bounded gather32 inverse.
    Gather32Trial,
    /// 実験 revision 5: 符号付き word 差分と二つの byte plane。
    Delta16Trial,
    /// 実験 revision 6: copy幅変更scheduleでvoter再計算を省く。
    RecordFastTrial,
    /// 実験 revision 7: 因果copyとliteral XOR残差の空間bit符号。
    SpatialBitsTrial,
    /// 実験 revision 8: scheduleとclass単位の適応CDF。
    RecordAdaptiveTrial,
    /// 実験 revision 9: KCS1と既定MDLの完全frameをblockごとに比較する。
    SpatialMdlTrial,
    /// 候補の完全frameを MDL, KCS1, KRS2, KRS3 の順に比較する revision 10。
    PortfolioTrial,
    /// revision 10 の候補へ PPMII 系テキスト候補（LPM1BLK、順位4）を加えた revision 11。
    PortfolioPpmTrial,
}

pub fn compress_block_with_strategy(input: &[u8], strategy: BlockStrategy) -> Result<Vec<u8>> {
    if strategy == BlockStrategy::Mdl {
        return compress_block(input);
    }
    if input.len() > BLOCK_BYTES {
        return Err(Error::Limit("LHC block size".into()));
    }
    if strategy == BlockStrategy::Gather32Trial {
        return g32::encode_trial(input).map_err(Error::Format);
    }
    if strategy == BlockStrategy::Delta16Trial {
        return delta16::encode_selected(input).map_err(Error::Format);
    }
    if strategy == BlockStrategy::RecordTrial {
        return record::encode(input)
            .map(|(bytes, _)| bytes)
            .map_err(Error::Format);
    }
    if strategy == BlockStrategy::RecordFastTrial {
        return record::encode_fast(input).map_err(Error::Format);
    }
    if strategy == BlockStrategy::RecordAdaptiveTrial {
        return record::encode_adaptive(input).map_err(Error::Format);
    }
    if strategy == BlockStrategy::SpatialBitsTrial {
        return spatial::encode(input)
            .map(|(bytes, _)| bytes)
            .map_err(Error::Format);
    }
    if strategy == BlockStrategy::SpatialMdlTrial {
        let (mdl, _) = block::encode(input).map_err(Error::Format)?;
        if mdl
            .capacity()
            .checked_add(spatial::MEMORY_BOUND)
            .is_none_or(|bytes| bytes > CODEC_MEMORY_BYTES as usize)
        {
            return Err(Error::Limit("spatial/MDL codec memory".into()));
        }
        let (spatial, _) = spatial::encode(input).map_err(Error::Format)?;
        return Ok(if spatial.len() < mdl.len() {
            spatial
        } else {
            mdl
        });
    }
    if matches!(
        strategy,
        BlockStrategy::PortfolioTrial | BlockStrategy::PortfolioPpmTrial
    ) {
        let spatial_len = spatial::encoded_len(input).map_err(Error::Format)?;
        // MDL は一度だけ計算する。テキスト入力では KRS 準備の基準（BinaryAdaptive）も MDL frame の
        // revision 書換えなので、それを再利用して MDL の重複計算（最大3回）を避ける。出力は不変。
        // MDL frame（<=1MiB+header）を KRS 準備中も保持するが、各 phase の gate 内に収まる。
        let mdl = block::encode(input).map_err(Error::Format)?;
        let (fast_len, adaptive_len) =
            record::scheduled_lengths_with_mdl(input, &mdl).map_err(Error::Format)?;
        let mut best_strategy = BlockStrategy::Mdl;
        let mut best_len = mdl.0.len();
        let mut best_rank = 0;
        let candidates = [
            (BlockStrategy::SpatialBitsTrial, spatial_len, 1),
            (BlockStrategy::RecordFastTrial, fast_len, 2),
            (BlockStrategy::RecordAdaptiveTrial, adaptive_len, 3),
        ];
        for (candidate, len, rank) in candidates {
            if len < best_len || (len == best_len && rank < best_rank) {
                best_strategy = candidate;
                best_len = len;
                best_rank = rank;
            }
        }
        // revision 11 だけ PPM（順位4、同長なら既存候補を優先）を比較する。PPM の encode は
        // 完全 frame を作るので、そのまま採用できる。モデル arena（ppm::MODEL_MIB）と保持中の
        // MDL frame を合わせても codec gate 内に収まる（ppm 側の const 検査を参照）。
        if strategy == BlockStrategy::PortfolioPpmTrial
            && let Some(frame) = ppm::encode(input, ppm::DEFAULT_ORDER).map_err(Error::Format)?
            && frame.len() < best_len
        {
            return Ok(frame);
        }
        // Explicit ranks preserve the MDL → KCS1 → KRS2 → KRS3 (→ PPM) tie order.
        return match best_strategy {
            BlockStrategy::Mdl => Ok(mdl.0),
            BlockStrategy::RecordFastTrial | BlockStrategy::RecordAdaptiveTrial => {
                let adaptive = best_strategy == BlockStrategy::RecordAdaptiveTrial;
                record::encode_scheduled_with_mdl(input, adaptive, &mdl).map_err(Error::Format)
            }
            _ => {
                drop(mdl);
                compress_block_with_strategy(input, best_strategy)
            }
        };
    }
    block::encode_hybrid(input, strategy == BlockStrategy::BinaryAdaptive)
        .map(|(bytes, _)| bytes)
        .map_err(Error::Format)
}

pub fn compress_block_with_history_mode(input: &[u8], mode: HistoryMode) -> Result<Vec<u8>> {
    if input.len() > BLOCK_BYTES {
        return Err(Error::Limit("LHC block size".into()));
    }
    match mode {
        HistoryMode::PaidHistoryOrder => block::encode(input),
        HistoryMode::LowHistoryOnly => block::encode_low_history_only(input),
    }
    .map(|(bytes, _)| bytes)
    .map_err(Error::Format)
}
/// Exact frame decoding; rejects noncanonical, corrupt or trailing data.
pub fn decompress_block(frame: &[u8]) -> Result<Vec<u8>> {
    if frame.get(..8) == Some(&ppm::MAGIC[..]) {
        return ppm::decode(frame).map_err(Error::Format);
    }
    if frame.get(..8) == Some(&spatial::MAGIC[..]) {
        let expected = spatial::field(frame, 12).map_err(Error::Format)?;
        return spatial::decode(frame, expected)
            .map(|(bytes, _)| bytes)
            .map_err(Error::Format);
    }
    if frame.get(..8) == Some(&record::FAST_MAGIC[..]) {
        return record::decode_fast(frame).map_err(Error::Format);
    }
    if frame.get(..8) == Some(&record::ADAPTIVE_MAGIC[..]) {
        return record::decode_adaptive(frame).map_err(Error::Format);
    }
    if frame.get(..8) == Some(&delta16::MAGIC[..]) {
        return delta16::decode(frame).map_err(Error::Format);
    }
    if frame.get(..8) == Some(&g32::MAGIC[..]) {
        if frame.len() > BLOCK_BYTES + g32::HEADER {
            return Err(Error::Limit("LHC G32 frame size".into()));
        }
        let expected = frame
            .get(12..16)
            .ok_or_else(|| Error::Format("G32 header truncated".into()))?;
        g32::validate_frame(
            frame,
            u32::from_le_bytes(expected.try_into().unwrap()) as usize,
        )
        .map_err(Error::Format)?;
        return g32::decode(frame)
            .map(|(bytes, _)| bytes)
            .map_err(Error::Format);
    }
    if frame.get(..8) == Some(&record::MAGIC[..]) {
        if frame.len() > BLOCK_BYTES + 80 {
            return Err(Error::Limit("LHC record frame size".into()));
        }
        return record::decode(frame)
            .map(|(bytes, _)| bytes)
            .map_err(Error::Format);
    }
    if frame.len() > BLOCK_BYTES + block::HEADER {
        return Err(Error::Limit("LHC frame size".into()));
    }
    block::decode(frame)
        .map(|(bytes, _)| bytes)
        .map_err(Error::Format)
}

fn crc(bytes: &[u8]) -> u32 {
    checksum(CrcAlgorithm::Crc32IsoHdlc, bytes) as u32
}
fn digest() -> Digest {
    Digest::new(CrcAlgorithm::Crc32IsoHdlc)
}
fn exact(reader: &mut impl Read, bytes: &mut [u8]) -> Result<()> {
    reader.read_exact(bytes).map_err(|e| {
        if e.kind() == io::ErrorKind::UnexpectedEof {
            Error::Format("truncated LHC archive".into())
        } else {
            Error::Io(e)
        }
    })
}
fn allocate(bytes: usize) -> Result<Vec<u8>> {
    let mut result = Vec::new();
    result
        .try_reserve_exact(bytes)
        .map_err(|_| Error::Limit("LHC allocation".into()))?;
    result.resize(bytes, 0);
    Ok(result)
}
fn count(count: u64, limits: &Limits) -> Result<()> {
    if count > limits.max_entries || count > MAX_ENTRIES {
        return Err(Error::Limit("LHC entry count".into()));
    }
    Ok(())
}
fn lengths(entries: &[Entry], limits: &Limits) -> Result<Summary> {
    count(entries.len() as u64, limits)?;
    let mut result = Summary {
        entries: entries.len() as u64,
        ..Summary::default()
    };
    for entry in entries {
        if entry.is_directory {
            if entry.original_size != 0 {
                return Err(Error::Format("LHC directory has content".into()));
            }
        } else {
            if entry.original_size > limits.max_entry_bytes {
                return Err(Error::Limit("LHC entry bytes".into()));
            }
            result.bytes = result
                .bytes
                .checked_add(entry.original_size)
                .ok_or_else(|| Error::Limit("LHC total overflow".into()))?;
            if result.bytes > limits.max_total_bytes {
                return Err(Error::Limit("LHC total bytes".into()));
            }
            result.files += 1;
        }
    }
    Ok(result)
}
fn names(entries: &[Entry]) -> Result<()> {
    let mut keys = HashMap::new();
    keys.try_reserve(entries.len())
        .map_err(|_| Error::Limit("LHC names allocation".into()))?;
    for entry in entries {
        validate_entry_name(&entry.name)?;
        if entry.name.ends_with('/') {
            return Err(Error::InvalidPath(entry.name.clone()));
        }
        if keys
            .insert(entry.name.to_lowercase(), entry.is_directory)
            .is_some()
        {
            return Err(Error::InvalidPath(format!(
                "duplicate LHC name: {}",
                entry.name
            )));
        }
    }
    for key in keys.keys() {
        let mut prefix = key.as_str();
        let mut depth = 1;
        while let Some(split) = prefix.rfind('/') {
            prefix = &prefix[..split];
            depth += 1;
            if depth > 128 {
                return Err(Error::Limit("LHC name depth exceeds 128".into()));
            }
            if keys.get(prefix) == Some(&false) {
                return Err(Error::InvalidPath(format!(
                    "LHC file/child collision: {key}"
                )));
            }
        }
    }
    Ok(())
}
fn seconds(time: SystemTime) -> Option<i64> {
    match time.duration_since(UNIX_EPOCH) {
        Ok(v) => i64::try_from(v.as_secs()).ok(),
        Err(e) => {
            let d = e.duration();
            i64::try_from(d.as_secs().checked_add(u64::from(d.subsec_nanos() != 0))?)
                .ok()?
                .checked_neg()
        }
    }
    .filter(|v| *v != i64::MIN)
}
fn serialize(entries: &[Entry]) -> Result<Vec<u8>> {
    let size = entries
        .iter()
        .try_fold(0usize, |sum, e| {
            sum.checked_add(20)?.checked_add(e.name.len())
        })
        .ok_or_else(|| Error::Limit("LHC manifest overflow".into()))?;
    if size > MAX_MANIFEST_BYTES {
        return Err(Error::Limit("LHC manifest bytes".into()));
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(size)
        .map_err(|_| Error::Limit("LHC manifest allocation".into()))?;
    for e in entries {
        bytes.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
        bytes.push(u8::from(e.is_directory));
        bytes.push(0);
        bytes.extend_from_slice(&e.original_size.to_le_bytes());
        bytes.extend_from_slice(&e.modified_unix_seconds.unwrap_or(i64::MIN).to_le_bytes());
        bytes.extend_from_slice(e.name.as_bytes());
    }
    Ok(bytes)
}
fn read_manifest(file: &mut File, limits: &Limits) -> Result<(Vec<Entry>, Summary, u8)> {
    let mut h = [0u8; HEADER];
    exact(file, &mut h)?;
    if &h[..8] != MAGIC
        || !matches!(h[8], 1..=11)
        || h[9..12] != [0; 3]
        || u32::from_le_bytes(h[12..16].try_into().unwrap()) != BLOCK_BYTES as u32
    {
        return Err(Error::Format("LHC magic/revision/flags/block limit".into()));
    }
    if crc(&h[..28]) != u32::from_le_bytes(h[28..32].try_into().unwrap()) {
        return Err(Error::Format("LHC header CRC".into()));
    }
    let n = u32::from_le_bytes(h[16..20].try_into().unwrap()) as usize;
    let size = u32::from_le_bytes(h[20..24].try_into().unwrap()) as usize;
    count(n as u64, limits)?;
    if size > MAX_MANIFEST_BYTES || n > size / 21 {
        return Err(Error::Limit("LHC manifest extent".into()));
    }
    let mut bytes = allocate(size)?;
    exact(file, &mut bytes)?;
    if crc(&bytes) != u32::from_le_bytes(h[24..28].try_into().unwrap()) {
        return Err(Error::Format("LHC manifest CRC".into()));
    }
    let mut entries = Vec::new();
    entries
        .try_reserve_exact(n)
        .map_err(|_| Error::Limit("LHC entries allocation".into()))?;
    let mut at = 0usize;
    for _ in 0..n {
        let fixed = bytes
            .get(at..at + 20)
            .ok_or_else(|| Error::Format("LHC manifest record".into()))?;
        let length = u16::from_le_bytes(fixed[..2].try_into().unwrap()) as usize;
        if fixed[2] > 1 || fixed[3] != 0 {
            return Err(Error::Format("LHC entry kind/flags".into()));
        }
        let original_size = u64::from_le_bytes(fixed[4..12].try_into().unwrap());
        let mtime = i64::from_le_bytes(fixed[12..20].try_into().unwrap());
        let raw_name = bytes
            .get(at + 20..at + 20 + length)
            .ok_or_else(|| Error::Format("LHC manifest name".into()))?;
        let name = std::str::from_utf8(raw_name)
            .map_err(|_| Error::Format("LHC UTF-8 name".into()))?
            .to_owned();
        entries.push(Entry {
            name,
            original_size,
            compressed_size: 0,
            is_directory: fixed[2] == 1,
            modified_unix_seconds: (mtime != i64::MIN).then_some(mtime),
        });
        at += 20 + length;
    }
    if at != bytes.len() {
        return Err(Error::Format("LHC manifest trailing bytes".into()));
    }
    names(&entries)?;
    let summary = lengths(&entries, limits)?;
    Ok((entries, summary, h[8]))
}

fn open_source(root: Option<&Dir>, path: &Path) -> Result<File> {
    let file = match root {
        Some(root) => directory::open_entry_beneath_nofollow(root, path),
        None => directory::open_ambient_entry_nofollow(path),
    }?;
    crate::writer::reject_unsupported_source(path, &file.metadata()?)?;
    Ok(file)
}
fn open_archive(path: &Path) -> Result<File> {
    let file = open_source(None, path)?;
    if !file.metadata()?.is_file() {
        return Err(Error::InvalidArgument("LHC archive must be regular".into()));
    }
    Ok(file)
}
fn existing(parent: &Dir, name: &std::ffi::OsStr, path: &Path) -> Result<()> {
    match parent.symlink_metadata(name) {
        Ok(_) => Err(Error::Exists(path.to_owned())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

pub fn create_archive(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
) -> Result<()> {
    create_archive_with_progress(destination, entries, options, &mut |_| true)
}
pub fn create_archive_with_progress(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<()> {
    create(destination, None, entries, options, callback)
}
pub fn create_from_directory(
    source: &Path,
    destination: &Path,
    options: &CreateOptions,
) -> Result<()> {
    let source_absolute = std::path::absolute(source)?;
    let destination_absolute = std::path::absolute(destination)?;
    if destination_absolute.starts_with(&source_absolute) {
        return Err(Error::InvalidArgument(
            "LHC output must be outside the source directory".into(),
        ));
    }
    let mut limits = options.limits;
    limits.max_entries = limits.max_entries.min(MAX_ENTRIES);
    let (root, entries) = crate::collect_source_directory(source, &limits)?;
    create(destination, Some(&root), &entries, options, &mut |_| true)
}
fn create(
    destination: &Path,
    source_root: Option<&Dir>,
    sources: &[SourceEntry],
    options: &CreateOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<()> {
    if options.max_codec_memory_bytes < CODEC_MEMORY_BYTES {
        return Err(Error::Limit("LHC codec memory reservation".into()));
    }
    count(sources.len() as u64, &options.limits)?;
    checkpoint(callback, 1, 0, sources.len() as u64)?;
    let mut entries = Vec::new();
    let mut scanned = Vec::new();
    let mut manifest_size = 0usize;
    for (index, source) in sources.iter().enumerate() {
        checkpoint(callback, 1, index as u64, sources.len() as u64)?;
        validate_entry_name(&source.name)?;
        manifest_size = manifest_size
            .checked_add(20 + source.name.len())
            .ok_or_else(|| Error::Limit("LHC manifest overflow".into()))?;
        if manifest_size > MAX_MANIFEST_BYTES {
            return Err(Error::Limit("LHC manifest bytes".into()));
        }
        let file = open_source(source_root, &source.path)?;
        let m = file.metadata()?;
        let identity = crate::writer::file_identity(&file, &m)?;
        entries.push(Entry {
            name: source.name.clone(),
            original_size: if m.is_dir() { 0 } else { m.len() },
            compressed_size: 0,
            is_directory: m.is_dir(),
            modified_unix_seconds: m.modified().ok().and_then(seconds),
        });
        scanned.push((identity, m.modified().ok()));
    }
    names(&entries)?;
    let summary = lengths(&entries, &options.limits)?;
    let manifest = serialize(&entries)?;
    let parent_path = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let parent = directory::create_ambient_directory_all_nofollow(parent_path)?;
    let filename = destination
        .file_name()
        .ok_or_else(|| Error::InvalidPath(destination.display().to_string()))?;
    existing(&parent, filename, destination)?;
    let staging = cap_tempfile::TempDir::new_in(&parent)?;
    let mut output = crate::reader::create_staging_file(&staging, true)?;
    let mut header = [0u8; HEADER];
    header[..8].copy_from_slice(MAGIC);
    header[8] = match options.block_strategy {
        BlockStrategy::Mdl => 1,
        BlockStrategy::RecordTrial => 3,
        BlockStrategy::Gather32Trial => 4,
        BlockStrategy::Delta16Trial => 5,
        BlockStrategy::RecordFastTrial => 6,
        BlockStrategy::SpatialBitsTrial => 7,
        BlockStrategy::RecordAdaptiveTrial => 8,
        BlockStrategy::SpatialMdlTrial => 9,
        BlockStrategy::PortfolioTrial => 10,
        BlockStrategy::PortfolioPpmTrial => 11,
        _ => 2,
    };
    header[12..16].copy_from_slice(&(BLOCK_BYTES as u32).to_le_bytes());
    header[16..20].copy_from_slice(&(entries.len() as u32).to_le_bytes());
    header[20..24].copy_from_slice(&(manifest.len() as u32).to_le_bytes());
    header[24..28].copy_from_slice(&crc(&manifest).to_le_bytes());
    let hcrc = crc(&header[..28]);
    header[28..32].copy_from_slice(&hcrc.to_le_bytes());
    output.write_all(&header)?;
    output.write_all(&manifest)?;
    let workers = create_workers(options);
    let strategy = options.block_strategy;
    let mut completed = 0u64;
    std::thread::scope(|scope| -> Result<()> {
        // blockは独立に圧縮されるので、worker数や処理順にかかわらず書庫は byte 単位で同一になる。
        // 書込みは常に書庫順（frame と file CRC を出現順に並べた order）で行う。
        let mut writer = OrderedWriter::new(workers);
        let pool = (workers > 1)
            .then(|| EncodePool::start(scope, workers, strategy))
            .transpose()?;
        for (index, (source, entry)) in sources.iter().zip(&entries).enumerate() {
            checkpoint(callback, 2, completed, summary.bytes)?;
            let mut file = open_source(source_root, &source.path)?;
            let before = file.metadata()?;
            if crate::writer::file_identity(&file, &before)? != scanned[index].0
                || before.is_dir() != entry.is_directory
                || (!entry.is_directory && before.len() != entry.original_size)
                || before.modified().ok() != scanned[index].1
            {
                return Err(Error::Unsupported("LHC source changed after scan".into()));
            }
            if entry.is_directory {
                continue;
            }
            let mut remaining = entry.original_size;
            let mut file_crc = digest();
            while remaining != 0 {
                checkpoint(callback, 2, completed, summary.bytes)?;
                let length = remaining.min(BLOCK_BYTES as u64) as usize;
                let mut raw = allocate(length)?;
                exact(&mut file, &mut raw)?;
                file_crc.update(&raw);
                match &pool {
                    None => {
                        write_frame(&mut output, &compress_block_with_strategy(&raw, strategy)?)?
                    }
                    Some(pool) => writer.submit(pool, raw, &mut output)?,
                }
                remaining -= length as u64;
                completed += length as u64;
            }
            let mut extra = [0u8; 1];
            let after = file.metadata()?;
            if file.read(&mut extra)? != 0
                || after.len() != before.len()
                || after.modified().ok() != before.modified().ok()
            {
                return Err(Error::Unsupported("LHC source changed while read".into()));
            }
            let value = file_crc.finalize() as u32;
            match &pool {
                None => output.write_all(&value.to_le_bytes())?,
                Some(_) => writer.crc(value, &mut output)?,
            }
        }
        if let Some(pool) = &pool {
            writer.finish(pool, &mut output)?;
        }
        Ok(())
    })?;
    output.write_all(END)?;
    if !options.skip_fsync {
        output.sync_all()?;
    }
    crate::reader::publish_staged_no_replace(
        &staging,
        &output,
        &parent,
        filename,
        destination,
        callback,
    )?;
    drop(output);
    staging.close()?;
    Ok(())
}

fn read_frame(file: &mut File, expected: usize, archive_revision: u8) -> Result<Vec<u8>> {
    let mut prefix = [0u8; 4];
    exact(file, &mut prefix)?;
    let length = u32::from_le_bytes(prefix) as usize;
    let overhead = if archive_revision == 5 {
        delta16::HEADER
    } else if matches!(archive_revision, 6..=11) {
        40
    } else if matches!(archive_revision, 3 | 4) {
        80
    } else {
        block::HEADER
    };
    let minimum = if matches!(archive_revision, 7 | 9 | 10 | 11) {
        spatial::HEADER
    } else {
        block::HEADER
    };
    if length < minimum || length > expected + overhead {
        return Err(Error::Format("LHC block extent".into()));
    }
    let mut frame = allocate(length)?;
    exact(file, &mut frame)?;
    if matches!(archive_revision, 10 | 11) {
        if archive_revision == 11 && frame.get(..8) == Some(&ppm::MAGIC[..]) {
            ppm::validate_frame(&frame, expected).map_err(Error::Format)?;
        } else if frame.get(..8) == Some(&spatial::MAGIC[..]) {
            spatial::validate_frame(&frame, expected).map_err(Error::Format)?;
        } else if frame.get(..8) == Some(&record::FAST_MAGIC[..]) {
            record::validate_fast_frame(&frame, expected).map_err(Error::Format)?;
        } else if frame.get(..8) == Some(&record::ADAPTIVE_MAGIC[..]) {
            record::validate_adaptive_frame(&frame, expected).map_err(Error::Format)?;
        } else if frame.get(..8) == Some(&block::MAGIC[..]) {
            validate_mdl_fallback_frame(&frame, expected, archive_revision)?;
        } else {
            return Err(Error::Format("revision 10/11 frame family".into()));
        }
    } else if archive_revision == 9 {
        if frame.get(..8) == Some(&spatial::MAGIC[..]) {
            spatial::validate_frame(&frame, expected).map_err(Error::Format)?;
        } else {
            validate_mdl_fallback_frame(&frame, expected, archive_revision)?;
        }
    } else if archive_revision == 8 {
        if frame.get(..8) == Some(&record::ADAPTIVE_MAGIC[..]) {
            record::validate_adaptive_frame(&frame, expected).map_err(Error::Format)?;
        } else {
            validate_legacy_frame(&frame, expected, archive_revision)?;
        }
    } else if archive_revision == 7 {
        spatial::validate_frame(&frame, expected).map_err(Error::Format)?;
    } else if archive_revision == 6 {
        if frame.get(..8) == Some(&record::FAST_MAGIC[..]) {
            record::validate_fast_frame(&frame, expected).map_err(Error::Format)?;
        } else {
            validate_legacy_frame(&frame, expected, archive_revision)?;
        }
    } else if archive_revision == 5 {
        delta16::validate_frame(&frame, expected).map_err(Error::Format)?;
    } else if archive_revision == 4 {
        validate_gather32_frame(&frame, expected)?;
    } else if archive_revision == 3 {
        record::validate_frame(&frame, expected).map_err(Error::Format)?;
    } else {
        validate_legacy_frame(&frame, expected, archive_revision)?;
    }
    Ok(frame)
}

// revision 5 の子にも revision 4 と同じ非再帰の family 境界を使う。
fn validate_gather32_frame(frame: &[u8], expected: usize) -> Result<()> {
    if frame.get(..8) == Some(&g32::MAGIC[..]) {
        g32::validate_frame(frame, expected).map_err(Error::Format)?;
    } else {
        record::validate_frame(frame, expected).map_err(Error::Format)?;
        // method 2 は metadata を持たない旧形式 fallback。MDL は独立 G32 だけ。
        if frame[10] == 2 && frame[record::HEADER + 10] == 1 {
            return Err(Error::Format("revision 4 legacy MDL fallback".into()));
        }
    }
    Ok(())
}

fn validate_legacy_frame(frame: &[u8], expected: usize, archive_revision: u8) -> Result<()> {
    if frame.len() < block::HEADER || frame.len() > expected + block::HEADER {
        return Err(Error::Format("LHC block extent".into()));
    }
    let length = frame.len();
    if &frame[..8] != block::MAGIC
        || !block::revision_method_valid(frame)
        || (archive_revision == 1 && frame[8..10] != 1u16.to_le_bytes())
        || frame[11] != 0
        || frame[30..32] != [0; 2]
        || u32::from_le_bytes(frame[12..16].try_into().unwrap()) as usize != expected
    {
        return Err(Error::Format("LHC block header/expected length".into()));
    }
    let primary = u32::from_le_bytes(frame[16..20].try_into().unwrap()) as usize;
    let metadata = u32::from_le_bytes(frame[20..24].try_into().unwrap()) as usize;
    let payload = u32::from_le_bytes(frame[24..28].try_into().unwrap()) as usize;
    let alphabet = u16::from_le_bytes(frame[28..30].try_into().unwrap()) as usize;
    let body = alphabet * 2 + metadata + payload;
    if body + block::HEADER != length
        || (frame[10] >= 2
            && (primary != 0
                || metadata != 0
                || alphabet != 0
                || payload < 5
                || payload >= expected))
        || (frame[10] == 0
            && (primary != 0 || metadata != 0 || alphabet != 0 || payload != expected))
        || (frame[10] == 1
            && (body >= expected
                || primary > expected
                || !(2..=257).contains(&alphabet)
                || metadata < 241
                || payload < 5))
    {
        return Err(Error::Format("LHC block canonical fields".into()));
    }
    let mut wire_crc = digest();
    wire_crc.update(&frame[..36]);
    wire_crc.update(&frame[40..]);
    if wire_crc.finalize() as u32 != u32::from_le_bytes(frame[36..40].try_into().unwrap()) {
        return Err(Error::Format("LHC block wire CRC".into()));
    }
    Ok(())
}

fn validate_mdl_fallback_frame(frame: &[u8], expected: usize, archive_revision: u8) -> Result<()> {
    if frame.get(..8) != Some(&block::MAGIC[..]) || frame.len() < 12 {
        return Err(Error::Format("fallback frame family/header".into()));
    }
    let frame_revision = u16::from_le_bytes(frame[8..10].try_into().unwrap());
    let method = frame[10];
    let allowed = match archive_revision {
        9 => frame_revision == 1 && method <= 1,
        10 | 11 => matches!((frame_revision, method), (1, 0 | 1) | (2, 0 | 1 | 3)),
        _ => false,
    };
    if !allowed {
        return Err(Error::Format(
            "fallback is outside the revision allowlist".into(),
        ));
    }
    validate_legacy_frame(frame, expected, archive_revision)
}

fn finish(file: &mut File) -> Result<()> {
    let mut end = [0u8; 8];
    exact(file, &mut end)?;
    if &end != END {
        return Err(Error::Format("LHC end marker".into()));
    }
    let mut extra = [0u8; 1];
    if file.read(&mut extra)? != 0 {
        return Err(Error::Format("LHC trailing data".into()));
    }
    Ok(())
}

/// Scan without decoding plain bytes. Use verify_archive for full CRC validation.
pub fn list_archive(archive: &Path, limits: &Limits) -> Result<Vec<Entry>> {
    let mut result = Vec::new();
    visit_archive_entries(archive, limits, &mut |e| {
        result.push(e.clone());
        true
    })?;
    Ok(result)
}
/// Visitor avoids a second full returned list; validation still retains the bounded manifest.
pub fn visit_archive_entries(
    archive: &Path,
    limits: &Limits,
    visitor: &mut dyn FnMut(&Entry) -> bool,
) -> Result<Summary> {
    let mut file = open_archive(archive)?;
    let (entries, summary, revision) = read_manifest(&mut file, limits)?;
    for mut entry in entries {
        if !entry.is_directory {
            let mut remaining = entry.original_size;
            while remaining != 0 {
                let expected = remaining.min(BLOCK_BYTES as u64) as usize;
                let frame = read_frame(&mut file, expected, revision)?;
                entry.compressed_size += 4 + frame.len() as u64;
                remaining -= expected as u64;
            }
            let mut crc = [0u8; 4];
            exact(&mut file, &mut crc)?;
            entry.compressed_size += 4;
        }
        if !visitor(&entry) {
            return Err(Error::Cancelled);
        }
    }
    finish(&mut file)?;
    Ok(summary)
}
pub fn verify_archive(archive: &Path, limits: &Limits) -> Result<Summary> {
    process(
        archive,
        None,
        limits,
        &ExtractOptions::default(),
        &mut |_| true,
        true,
    )
}
pub fn verify_archive_with_progress(
    archive: &Path,
    limits: &Limits,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<Summary> {
    process(
        archive,
        None,
        limits,
        &ExtractOptions::default(),
        callback,
        false,
    )
}
pub fn extract_archive(archive: &Path, destination: &Path, limits: &Limits) -> Result<Summary> {
    process(
        archive,
        Some(destination),
        limits,
        &ExtractOptions::default(),
        &mut |_| true,
        true,
    )
}
/// Plain verification with explicit options (`threads`); no progress callback.
pub fn verify_archive_with_options(
    archive: &Path,
    limits: &Limits,
    options: &ExtractOptions,
) -> Result<Summary> {
    process(archive, None, limits, options, &mut |_| true, true)
}
/// Plain extraction with explicit options (`threads`, `skip_fsync`,
/// `preserve_timestamps`); no progress callback.
pub fn extract_archive_with_options(
    archive: &Path,
    destination: &Path,
    limits: &Limits,
    options: &ExtractOptions,
) -> Result<Summary> {
    process(
        archive,
        Some(destination),
        limits,
        options,
        &mut |_| true,
        true,
    )
}
pub fn extract_archive_with_progress(
    archive: &Path,
    destination: &Path,
    limits: &Limits,
    options: &ExtractOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<Summary> {
    process(archive, Some(destination), limits, options, callback, false)
}
fn process(
    archive: &Path,
    destination: Option<&Path>,
    limits: &Limits,
    options: &ExtractOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
    parallel: bool,
) -> Result<Summary> {
    checkpoint(callback, 1, 0, 0)?;
    let mut input = open_archive(archive)?;
    let (entries, summary, revision) = read_manifest(&mut input, limits)?;
    let root = destination
        .map(directory::create_ambient_directory_all_nofollow)
        .transpose()?;
    // threads: 0=旧来（G32系revision 4/5だけ4worker）、1=逐次、2以上=全familyを並列。
    // 進捗付きAPI（parallel=false）は取消・進捗通知を保つため常に逐次。
    let (workers, all_families) = match options.threads {
        0 => (pipeline::WORKERS, false),
        threads => (threads, true),
    };
    if parallel && workers >= 2 && pipeline::eligible(&mut input, &entries, revision, all_families)?
    {
        pipeline::process(
            &mut input,
            &entries,
            revision,
            root.as_ref(),
            destination,
            options,
            pipeline::Parallelism {
                workers,
                all_families,
            },
        )?;
        return Ok(summary);
    }
    let mut completed = 0;
    for entry in entries {
        checkpoint(callback, 3, completed, summary.bytes)?;
        let relative = validate_entry_name(&entry.name)?;
        if entry.is_directory {
            if let Some(root) = &root {
                directory::create_directory_all_beneath_nofollow(root, &relative)?;
            }
            continue;
        }
        let parent = root
            .as_ref()
            .map(|root| {
                directory::create_directory_all_beneath_nofollow(
                    root,
                    relative
                        .parent()
                        .filter(|p| !p.as_os_str().is_empty())
                        .unwrap_or(Path::new(".")),
                )
            })
            .transpose()?;
        let filename = relative
            .file_name()
            .ok_or_else(|| Error::InvalidPath(entry.name.clone()))?;
        let path = destination
            .map(|d| d.join(&relative))
            .unwrap_or_else(|| PathBuf::from(&entry.name));
        if let Some(parent) = &parent {
            existing(parent, filename, &path)?;
        }
        let staging = parent
            .as_ref()
            .map(cap_tempfile::TempDir::new_in)
            .transpose()?;
        let mut output = staging
            .as_ref()
            .map(|s| crate::reader::create_staging_file(s, true))
            .transpose()?;
        let mut remaining = entry.original_size;
        let mut file_crc = digest();
        while remaining != 0 {
            checkpoint(callback, 3, completed, summary.bytes)?;
            let expected = remaining.min(BLOCK_BYTES as u64) as usize;
            let frame = read_frame(&mut input, expected, revision)?;
            let raw = decompress_block(&frame)?;
            if raw.len() != expected {
                return Err(Error::Format("LHC decoded size".into()));
            }
            file_crc.update(&raw);
            if let Some(output) = &mut output {
                output.write_all(&raw)?;
            }
            remaining -= expected as u64;
            completed += expected as u64;
        }
        let mut expected_crc = [0u8; 4];
        exact(&mut input, &mut expected_crc)?;
        if file_crc.finalize() as u32 != u32::from_le_bytes(expected_crc) {
            return Err(Error::Format("LHC file CRC".into()));
        }
        if let (Some(output), Some(staging), Some(parent)) = (&output, &staging, &parent) {
            if options.preserve_timestamps
                && let Some(seconds) = entry.modified_unix_seconds
            {
                let duration = Duration::from_secs(seconds.unsigned_abs());
                let time = if seconds >= 0 {
                    UNIX_EPOCH.checked_add(duration)
                } else {
                    UNIX_EPOCH.checked_sub(duration)
                }
                .ok_or_else(|| Error::Format("LHC time range".into()))?;
                output
                    .try_clone()?
                    .into_std()
                    .set_times(std::fs::FileTimes::new().set_modified(time))?;
            }
            if !options.skip_fsync {
                output.sync_all()?;
            }
            crate::reader::publish_staged_no_replace(
                staging, output, parent, filename, &path, callback,
            )?;
        }
        drop(output);
        if let Some(staging) = staging {
            staging.close()?;
        }
    }
    finish(&mut input)?;
    checkpoint(callback, 4, completed, summary.bytes)?;
    Ok(summary)
}
