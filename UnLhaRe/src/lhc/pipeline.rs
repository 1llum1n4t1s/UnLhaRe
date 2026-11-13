//! plain API 専用。入力・出力とentry公開をmainに閉じ、decodeだけを並列化する。
use super::*;
use std::{
    collections::VecDeque,
    io::{Seek, SeekFrom},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::mpsc::{Receiver, SyncSender, sync_channel},
    thread::{self, JoinHandle},
};

const WORKERS: usize = 4;
const MAX_EVENTS: usize = 32;
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

pub(super) fn eligible(input: &mut File, entries: &[Entry], revision: u8) -> Result<bool> {
    if !matches!(revision, 4 | 5)
        || entries.len() > MAX_PARALLEL_ENTRIES
        || entries.iter().map(|entry| entry.name.len()).sum::<usize>() > MAX_PARALLEL_NAME_BYTES
    {
        return Ok(false);
    }
    let position = input.stream_position()?;
    let scan = (|| -> Result<bool> {
        let mut has_g32 = false;
        for entry in entries.iter().filter(|e| !e.is_directory) {
            let mut remaining = entry.original_size;
            while remaining != 0 {
                let expected = remaining.min(BLOCK_BYTES as u64) as usize;
                let frame = read_frame(input, expected, revision)?;
                let Some(frame_has_g32) = worker_kind(&frame) else {
                    return Ok(false);
                };
                has_g32 |= frame_has_g32;
                remaining -= expected as u64;
            }
            let mut crc = [0u8; 4];
            exact(input, &mut crc)?;
        }
        finish(input)?;
        Ok(has_g32)
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
}
struct Decoded {
    id: u64,
    raw: Result<Vec<u8>>,
}
struct Worker {
    input: SyncSender<Job>,
    output: Receiver<Decoded>,
    handle: JoinHandle<()>,
}
struct Pool {
    workers: Vec<Worker>,
}
impl Pool {
    fn new() -> Result<Self> {
        let mut pool = Self {
            workers: Vec::with_capacity(WORKERS),
        };
        for slot in 0..WORKERS {
            let (sender, receiver) = sync_channel::<Job>(1);
            let (results, output) = sync_channel(1);
            let handle = thread::Builder::new()
                .name(format!("lhc-decode-{slot}"))
                .stack_size(STACK_BYTES)
                .spawn(move || {
                    while let Ok(job) = receiver.recv() {
                        let id = job.id;
                        let raw = catch_unwind(AssertUnwindSafe(move || {
                            let raw = decompress_block(&job.frame)?;
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
            pool.workers.push(Worker {
                input: sender,
                output,
                handle,
            });
        }
        Ok(pool)
    }

    fn receive(&self, slot: usize, id: u64) -> Result<Vec<u8>> {
        let decoded = self.workers[slot]
            .output
            .recv()
            .map_err(|_| Error::Unsupported("LHC decode worker disconnected".into()))?;
        if decoded.id != id {
            return Err(Error::Unsupported("LHC decode job order".into()));
        }
        decoded.raw
    }

    fn shutdown(&mut self) -> Result<()> {
        let mut panicked = false;
        // 全channelを閉じてからjoinするため、失敗時のsendも停止できる。
        let handles: Vec<_> = self
            .workers
            .drain(..)
            .map(
                |Worker {
                     input,
                     output,
                     handle,
                 }| {
                    drop(input);
                    drop(output);
                    handle
                },
            )
            .collect();
        for handle in handles {
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
    Block { slot: usize, id: u64 },
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
    busy: [bool; WORKERS],
    done: bool,
    events: VecDeque<Event>,
}
impl Producer {
    fn new(revision: u8) -> Self {
        Self {
            revision,
            entry: 0,
            phase: Phase::Begin,
            next_id: 0,
            busy: [false; WORKERS],
            done: false,
            events: VecDeque::with_capacity(MAX_EVENTS),
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
                }
            }
            Phase::Blocks(0) => self.phase = Phase::Crc,
            Phase::Blocks(remaining) => {
                let Some(slot) = self.busy.iter().position(|&busy| !busy) else {
                    return Ok(false);
                };
                let expected = remaining.min(BLOCK_BYTES as u64) as usize;
                let frame = read_frame(input, expected, self.revision)?;
                // prescan後に入力が変わっても、旧MDLをworkerへ渡さない。
                if worker_kind(&frame).is_none() {
                    return Err(Error::Format("LHC parallel frame changed".into()));
                }
                let id = self.next_id;
                self.next_id = id
                    .checked_add(1)
                    .ok_or_else(|| Error::Limit("LHC decode job count".into()))?;
                pool.workers[slot]
                    .input
                    .send(Job {
                        id,
                        expected,
                        frame,
                    })
                    .map_err(|_| Error::Unsupported("LHC decode worker disconnected".into()))?;
                self.busy[slot] = true;
                self.events.push_back(Event::Block { slot, id });
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
            output.sync_all()?;
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

pub(super) fn process(
    input: &mut File,
    entries: &[Entry],
    revision: u8,
    root: Option<&Dir>,
    destination: Option<&Path>,
    options: &ExtractOptions,
) -> Result<()> {
    let mut pool = Pool::new()?;
    let result = (|| -> Result<()> {
        let mut producer = Producer::new(revision);
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
                Event::Block { slot, id } => {
                    let raw = pool.receive(slot, id)?;
                    let file = pending
                        .as_mut()
                        .ok_or_else(|| Error::Unsupported("LHC decode pipeline entry".into()))?;
                    file.crc.update(&raw);
                    if let Some(output) = &mut file.output {
                        output.write_all(&raw)?;
                    }
                    // rawはこのiterationで解放し、次のfillからだけslotを再利用する。
                    producer.busy[slot] = false;
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
