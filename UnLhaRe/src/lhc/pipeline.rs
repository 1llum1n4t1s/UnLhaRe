//! plain API 専用。入力・出力とentry公開をmainに閉じ、decodeだけを並列化する。
use super::*;
use std::{
    collections::{HashMap, VecDeque},
    io::{Seek, SeekFrom},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, Sender, channel},
    },
    thread::{self, JoinHandle},
};

// 既定(旧来)のworker数と、threads指定時の上限。
// 1MiB blockの1worker当たりの復号scratchはframe/raw各1MiB強と小さなmodel表の見積もりで数MiBであり、
// 4worker同時でも64MiB codec gate内に収まる想定（見積もりであり、全familyのpeak実測ではない）。
// LLZ1BLK（revision 12〜15）の entry は別枠で、同じ file の直近の出力（窓64MiB＋wave）を履歴として持つ。
// revision 14・15 は segment が4MiBなので、履歴は約72MiB、wave内で同時に復号する2 segmentのframeとrawが
// 各最大4MiB強（合計16MiB強）で、codec gateを超える（読み手の別枠）。revision 15はさらに、復号する
// segmentごとに混合表（約128KiB）を持つ。
pub(super) const WORKERS: usize = 4;
const MAX_EVENTS: usize = 32;
// 投入済みで未消費のblock（queue待ち・復号中・並べ直し待ち）の上限はworker数×この値。
// 各blockはframeかraw（各1MiB強）を1つ持つので、保持量は最大でも約16MiB（4worker時）に収まる。
// 4MiB単位のLLZ1BLK（revision 14・15）はwaveで投入が止まり同時最大2件なので、この上限には達しない。
// 重いblock（PPMなど）を待つ間も、他のworkerが後続blockを先に復号できる幅を確保する。
const WINDOW_PER_WORKER: usize = 4;
const STACK_BYTES: usize = 2 << 20;
const MAX_PARALLEL_ENTRIES: usize = 4096;
const MAX_PARALLEL_NAME_BYTES: usize = 512 << 10;

// read_frameで検証済みのフレームだけを受け取り、G32の有無も返す。
fn worker_kind(frame: &[u8]) -> Option<bool> {
    let frame = if frame.get(..8) == Some(&delta16::MAGIC[..]) {
        match frame.get(10) {
            Some(0) => return Some(false),
            Some(1 | 2) => frame.get(delta16::HEADER..)?,
            _ => return None,
        }
    } else {
        frame
    };
    if frame.get(..8) == Some(&g32::MAGIC[..]) {
        Some(true)
    } else if frame.get(..8) == Some(&record::MAGIC[..])
        && (matches!(frame.get(10), Some(0 | 1))
            || (frame.get(10) == Some(&2)
                && matches!(frame.get(record::HEADER + 10), Some(0 | 2 | 3))))
    {
        Some(false)
    } else {
        None
    }
}

pub(super) fn eligible(
    input: &mut File,
    entries: &[Entry],
    revision: u8,
    all_families: bool,
) -> Result<bool> {
    // all_families は threads>=2 の明示指定時だけ。read_frame が revision ごとの family 境界を検証し、
    // decompress_block が全 family を厳密に復号するため、worker_kind の制限を外せる。
    if !(matches!(revision, 4 | 5) || (all_families && (1..=15).contains(&revision)))
        || entries.len() > MAX_PARALLEL_ENTRIES
        || entries.iter().map(|entry| entry.name.len()).sum::<usize>() > MAX_PARALLEL_NAME_BYTES
    {
        return Ok(false);
    }
    let position = input.stream_position()?;
    let scan = (|| -> Result<bool> {
        let mut has_g32 = false;
        for entry in entries.iter().filter(|e| !e.is_directory) {
            let mut units = UnitReader::new(revision, entry);
            let mut remaining = entry.original_size;
            while remaining != 0 {
                let (frame, expected) = units.next(input, remaining)?;
                let frame_has_g32 = match worker_kind(&frame) {
                    Some(kind) => kind,
                    None if all_families => false,
                    None => return Ok(false),
                };
                has_g32 |= frame_has_g32;
                remaining -= expected as u64;
            }
            let mut crc = [0u8; 4];
            exact(input, &mut crc)?;
        }
        finish(input)?;
        Ok(has_g32 || all_families)
    })();
    // scanの失敗は元のserial経路で、元のentry順に報告する。
    // 復帰seekの失敗だけは、誤った位置からserialを続けられないため返す。
    input.seek(SeekFrom::Start(position))?;
    Ok(scan.unwrap_or(false))
}

struct Job {
    id: u64,
    expected: usize,
    frame: Vec<u8>,
    /// LLZ1BLK のときだけ、同じ file の履歴（wave 開始までの block 列）を持つ。
    llz: Option<LlzJob>,
}
/// LLZ1BLK の復号に要る履歴。segment 番号 `first` から wave 開始の直前までの segment 長の block を共有参照で持つ。
struct LlzJob {
    block: usize,
    first: usize,
    /// 書庫の revision が許す LLZ1BLK の形式（segment 長・frame revision）。
    layout: longlz::Layout,
    blocks: Vec<Segment>,
}
/// 復号済みの segment を、複製せずに履歴と書込みで共有する。worker の出力 Vec をそのまま包む
/// （`Arc<[u8]>` への変換は 4MiB の確保と複製になり、wave の境目の直列区間を延ばすため使わない）。
#[derive(Clone)]
struct Segment(Arc<Vec<u8>>);
impl AsRef<[u8]> for Segment {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}
struct Decoded {
    id: u64,
    raw: Result<Vec<u8>>,
}
/// 共有 job queue から書庫順に block を取り出す worker 群。結果は id 付きで返り、
/// `receive` が書庫順へ並べ直す。先に届いた結果は `ready` に保持する（件数は window で有界）。
struct Pool {
    jobs: Option<Sender<Job>>,
    results: Receiver<Decoded>,
    ready: HashMap<u64, Result<Vec<u8>>>,
    /// 停止時に、queue に残った job を復号せず捨てさせる印。
    stop: Arc<AtomicBool>,
    handles: Vec<JoinHandle<()>>,
}
impl Pool {
    fn new(workers: usize) -> Result<Self> {
        let (jobs, queue) = channel::<Job>();
        let queue = Arc::new(Mutex::new(queue));
        let (results, output) = channel::<Decoded>();
        // spawn 途中で失敗しても Drop が queue を閉じて既存 worker を止められるよう、先に組み立てる。
        let mut pool = Self {
            jobs: Some(jobs),
            results: output,
            ready: HashMap::new(),
            stop: Arc::new(AtomicBool::new(false)),
            handles: Vec::with_capacity(workers),
        };
        for slot in 0..workers {
            let queue = Arc::clone(&queue);
            let results = results.clone();
            let stop = Arc::clone(&pool.stop);
            let handle = thread::Builder::new()
                .name(format!("lhc-decode-{slot}"))
                .stack_size(STACK_BYTES)
                .spawn(move || {
                    loop {
                        // lock は受信の間だけ持つ。復号中は他の worker が次の job を取れる。
                        let job = match queue.lock() {
                            Ok(queue) => queue.recv(),
                            Err(_) => break,
                        };
                        let Ok(job) = job else { break };
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        let id = job.id;
                        let raw = catch_unwind(AssertUnwindSafe(move || {
                            let raw = match &job.llz {
                                Some(l) => longlz::decode_frame_blocks(
                                    &job.frame,
                                    job.expected,
                                    l.block,
                                    &l.blocks,
                                    l.first,
                                    l.layout,
                                )
                                .map_err(Error::Format)?,
                                None => decompress_block(&job.frame)?,
                            };
                            if raw.len() != job.expected {
                                return Err(Error::Format("LHC decoded size".into()));
                            }
                            Ok(raw)
                        }));
                        let panicked = raw.is_err();
                        let raw = raw.unwrap_or_else(|_| {
                            Err(Error::Unsupported("LHC decode worker panic".into()))
                        });
                        // frameとdecode scratchはsend前に解放済み。
                        if results.send(Decoded { id, raw }).is_err() || panicked {
                            break;
                        }
                    }
                })?;
            pool.handles.push(handle);
        }
        // 結果の送信側は worker だけが持つ。全 worker が終われば recv が切断を返す。
        drop(results);
        Ok(pool)
    }

    fn submit(&self, job: Job) -> Result<()> {
        self.jobs
            .as_ref()
            .and_then(|jobs| jobs.send(job).ok())
            .ok_or_else(|| Error::Unsupported("LHC decode worker disconnected".into()))
    }

    // id の結果を書庫順で受け取る。先に届いた別 id の結果は ready に保持する。
    fn receive(&mut self, id: u64) -> Result<Vec<u8>> {
        if let Some(raw) = self.ready.remove(&id) {
            return raw;
        }
        loop {
            let decoded = self
                .results
                .recv()
                .map_err(|_| Error::Unsupported("LHC decode worker disconnected".into()))?;
            if decoded.id == id {
                return decoded.raw;
            }
            if self.ready.insert(decoded.id, decoded.raw).is_some() {
                return Err(Error::Unsupported("LHC decode job order".into()));
            }
        }
    }

    fn shutdown(&mut self) -> Result<()> {
        // 残った job は捨て、queue を閉じてから join する。
        self.stop.store(true, Ordering::Relaxed);
        self.jobs = None;
        self.ready.clear();
        let mut panicked = false;
        for handle in self.handles.drain(..) {
            panicked |= handle.join().is_err();
        }
        if panicked {
            Err(Error::Unsupported("LHC decode worker panic".into()))
        } else {
            Ok(())
        }
    }
}
impl Drop for Pool {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

enum Event {
    Directory(usize),
    Begin(usize),
    /// entry は block が属する entry の番号（LLZ の履歴へ足すかの判定に使う）。
    Block {
        id: u64,
        entry: usize,
    },
    End(u32),
    Finished(Result<()>),
}
enum Phase {
    Begin,
    Blocks(u64),
    Crc,
}
struct Producer {
    revision: u8,
    entry: usize,
    phase: Phase,
    next_id: u64,
    /// 投入済みで未消費の block 数と、その上限。
    in_flight: usize,
    window: usize,
    all_families: bool,
    done: bool,
    events: VecDeque<Event>,
    /// 現在の entry の frame の単位（entry の開始で作る）と、次に読む frame（segment）の番号。
    units: Option<UnitReader>,
    block: usize,
    /// LLZ1BLK の履歴：消費済みの segment（番号 history_first から）。窓＋wave の分だけ保つ。
    history: VecDeque<Segment>,
    history_first: usize,
    /// wave の前の block がまだ消費されておらず、投入を待っている frame。
    held: Option<(Vec<u8>, usize)>,
}
impl Producer {
    fn new(revision: u8, workers: usize, all_families: bool) -> Self {
        Self {
            revision,
            all_families,
            entry: 0,
            phase: Phase::Begin,
            next_id: 0,
            in_flight: 0,
            window: workers * WINDOW_PER_WORKER,
            done: false,
            events: VecDeque::with_capacity(MAX_EVENTS),
            units: None,
            block: 0,
            history: VecDeque::new(),
            history_first: 0,
            held: None,
        }
    }

    /// 消費した block を、現在の entry の LLZ 履歴へ足す（別の entry の block なら何もしない）。
    fn consumed(&mut self, entry: usize, raw: &Segment) {
        if entry != self.entry {
            return;
        }
        // LLZ1BLK の entry（revision 14・15 は最初の frame が LLZ1BLK の entry）だけ履歴を持つ。
        let Some(layout) = self.units.as_ref().and_then(UnitReader::long_layout) else {
            return;
        };
        self.history.push_back(raw.clone());
        // 今後の segment が参照しうるのは history_start(現在の segment) 以降だけ。
        let keep_from = longlz::history_start(self.block, layout) / layout.segment;
        while self.history_first < keep_from && !self.history.is_empty() {
            self.history.pop_front();
            self.history_first += 1;
        }
    }
    fn fill(&mut self, input: &mut File, entries: &[Entry], pool: &Pool) {
        while !self.done && self.events.len() < MAX_EVENTS {
            match self.step(input, entries, pool) {
                Err(error) => {
                    self.events.push_back(Event::Finished(Err(error)));
                    self.done = true;
                }
                Ok(false) => break,
                Ok(true) => {}
            }
        }
    }
    fn step(&mut self, input: &mut File, entries: &[Entry], pool: &Pool) -> Result<bool> {
        match self.phase {
            Phase::Begin => {
                let Some(entry) = entries.get(self.entry) else {
                    self.events.push_back(Event::Finished(finish(input)));
                    self.done = true;
                    return Ok(true);
                };
                if entry.is_directory {
                    self.events.push_back(Event::Directory(self.entry));
                    self.entry += 1;
                } else {
                    self.events.push_back(Event::Begin(self.entry));
                    self.phase = Phase::Blocks(entry.original_size);
                    self.units = Some(UnitReader::new(self.revision, entry));
                    self.block = 0;
                    self.history.clear();
                    self.history_first = 0;
                    self.held = None;
                }
            }
            Phase::Blocks(0) => self.phase = Phase::Crc,
            Phase::Blocks(remaining) => {
                if self.in_flight >= self.window {
                    return Ok(false);
                }
                let (frame, expected) = match self.held.take() {
                    Some(held) => held,
                    None => self
                        .units
                        .as_mut()
                        .ok_or_else(|| Error::Unsupported("LHC decode pipeline units".into()))?
                        .next(input, remaining)?,
                };
                let mut llz = None;
                if frame.get(..8) == Some(&longlz::MAGIC[..]) {
                    let layout = self
                        .units
                        .as_ref()
                        .and_then(UnitReader::long_layout)
                        .ok_or_else(|| Error::Format("LLZ1BLK without a layout".into()))?;
                    // LLZ1BLK は wave の前の segment がすべて消費されてから投入する。
                    let wave = longlz::wave_start(self.block, layout) / layout.segment;
                    if self.history_first + self.history.len() < wave {
                        self.held = Some((frame, expected));
                        return Ok(false);
                    }
                    let first = longlz::history_start(self.block, layout) / layout.segment;
                    if first < self.history_first {
                        return Err(Error::Format("LLZ1BLK history range".into()));
                    }
                    llz = Some(LlzJob {
                        block: self.block,
                        first,
                        layout,
                        blocks: self
                            .history
                            .range(first - self.history_first..wave - self.history_first)
                            .cloned()
                            .collect(),
                    });
                } else if !self.all_families && worker_kind(&frame).is_none() {
                    // prescan後に入力が変わっても、旧MDLをworkerへ渡さない。
                    return Err(Error::Format("LHC parallel frame changed".into()));
                }
                let id = self.next_id;
                self.next_id = id
                    .checked_add(1)
                    .ok_or_else(|| Error::Limit("LHC decode job count".into()))?;
                pool.submit(Job {
                    id,
                    expected,
                    frame,
                    llz,
                })?;
                self.in_flight += 1;
                self.block += 1;
                self.events.push_back(Event::Block {
                    id,
                    entry: self.entry,
                });
                self.phase = Phase::Blocks(remaining - expected as u64);
            }
            Phase::Crc => {
                let mut bytes = [0u8; 4];
                exact(input, &mut bytes)?;
                self.events.push_back(Event::End(u32::from_le_bytes(bytes)));
                self.entry += 1;
                self.phase = Phase::Begin;
            }
        }
        Ok(true)
    }
}

struct Pending {
    entry: usize,
    parent: Option<Dir>,
    staging: Option<cap_tempfile::TempDir>,
    output: Option<cap_std::fs::File>,
    path: PathBuf,
    crc: Digest,
}
impl Pending {
    fn begin(
        entry: usize,
        entries: &[Entry],
        root: Option<&Dir>,
        destination: Option<&Path>,
    ) -> Result<Self> {
        let relative = validate_entry_name(&entries[entry].name)?;
        let parent = root
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
            .ok_or_else(|| Error::InvalidPath(entries[entry].name.clone()))?;
        let path = destination
            .map(|d| d.join(&relative))
            .unwrap_or_else(|| PathBuf::from(&entries[entry].name));
        if let Some(parent) = &parent {
            existing(parent, filename, &path)?;
        }
        let staging = parent
            .as_ref()
            .map(cap_tempfile::TempDir::new_in)
            .transpose()?;
        let output = staging
            .as_ref()
            .map(|s| crate::reader::create_staging_file(s, true))
            .transpose()?;
        Ok(Self {
            entry,
            parent,
            staging,
            output,
            path,
            crc: digest(),
        })
    }
    fn finish(self, entries: &[Entry], expected: u32, options: &ExtractOptions) -> Result<()> {
        if self.crc.finalize() as u32 != expected {
            return Err(Error::Format("LHC file CRC".into()));
        }
        if let (Some(output), Some(staging), Some(parent)) =
            (&self.output, &self.staging, &self.parent)
        {
            if options.preserve_timestamps
                && let Some(seconds) = entries[self.entry].modified_unix_seconds
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
            let filename = self
                .path
                .file_name()
                .ok_or_else(|| Error::InvalidPath(entries[self.entry].name.clone()))?;
            crate::reader::publish_staged_no_replace(
                staging,
                output,
                parent,
                filename,
                &self.path,
                &mut |_| true,
            )?;
        }
        drop(self.output);
        if let Some(staging) = self.staging {
            staging.close()?;
        }
        Ok(())
    }
}

/// 並列復号の設定。workers は 1..=WORKERS へ丸める。all_families は threads>=2 の明示指定時だけ真。
#[derive(Clone, Copy)]
pub(super) struct Parallelism {
    pub workers: usize,
    pub all_families: bool,
}

pub(super) fn process(
    input: &mut File,
    entries: &[Entry],
    revision: u8,
    root: Option<&Dir>,
    destination: Option<&Path>,
    options: &ExtractOptions,
    parallelism: Parallelism,
) -> Result<()> {
    let Parallelism {
        workers,
        all_families,
    } = parallelism;
    let workers = workers.clamp(1, WORKERS);
    let mut pool = Pool::new(workers)?;
    let result = (|| -> Result<()> {
        let mut producer = Producer::new(revision, workers, all_families);
        let mut pending: Option<Pending> = None;
        loop {
            producer.fill(input, entries, &pool);
            let event = producer
                .events
                .pop_front()
                .ok_or_else(|| Error::Unsupported("LHC decode pipeline empty".into()))?;
            match event {
                Event::Directory(index) => {
                    let relative = validate_entry_name(&entries[index].name)?;
                    if let Some(root) = root {
                        directory::create_directory_all_beneath_nofollow(root, &relative)?;
                    }
                }
                Event::Begin(index) => {
                    pending = Some(Pending::begin(index, entries, root, destination)?)
                }
                Event::Block { id, entry } => {
                    // 受け取った block を履歴へ足した直後に次の frame を投入し、worker を待たせない。
                    // LLZ1BLK の次の wave は wave の全 block が履歴に入るまで投入できない（held）ので、その間は
                    // 同じ entry の次の block も先に受け取って履歴へ足す。CRC と書込みは投入の後に、書庫順で
                    // まとめて行い、次の wave の復号と重ねる。先に受け取る block は wave 幅までで、保持は有界。
                    // 投入の失敗は event として後で返るので、受け取った block の CRC 検査・書込みの順序と、
                    // 失敗時の停止は変わらない。
                    let mut batch: Vec<Segment> = Vec::with_capacity(longlz::WAVE);
                    let mut next = Some((id, entry));
                    while let Some((id, entry)) = next.take() {
                        let raw = Segment(Arc::new(pool.receive(id)?));
                        producer.in_flight -= 1;
                        producer.consumed(entry, &raw);
                        producer.fill(input, entries, &pool);
                        batch.push(raw);
                        if producer.held.is_some()
                            && batch.len() < longlz::WAVE
                            && let Some(&Event::Block { id, entry }) = producer.events.front()
                        {
                            producer.events.pop_front();
                            next = Some((id, entry));
                        }
                    }
                    let file = pending
                        .as_mut()
                        .ok_or_else(|| Error::Unsupported("LHC decode pipeline entry".into()))?;
                    for raw in &batch {
                        file.crc.update(raw.as_ref());
                        if let Some(output) = &mut file.output {
                            output.write_all(raw.as_ref())?;
                        }
                    }
                    // batch はこの iteration の終わりで手放す（LLZ の履歴が参照していれば、外れるまで残る）。
                }
                Event::End(crc) => pending
                    .take()
                    .ok_or_else(|| Error::Unsupported("LHC decode pipeline entry".into()))?
                    .finish(entries, crc, options)?,
                Event::Finished(result) => return result,
            }
        }
    })();
    let joined = pool.shutdown();
    result.and(joined)
}
