//! row-copy tokenの逐次E2Eと独立小参照。新frame/圧縮率/速度ではない。
#[path = "../causal-record-vote/voter.rs"]
mod voter;
use std::{collections::BTreeMap, fmt::Write, fs::File, io::Read, path::Path};
use unlhare::{Limits, khc};
type Result<T> = std::result::Result<T, String>;
#[derive(Default, Debug, PartialEq)]
struct Stats {
    tokens: usize,
    copied: usize,
    literals: usize,
    length_bytes: usize,
}
struct Decoder {
    plain: Vec<u8>,
    length: usize,
    model: voter::Voter,
}
impl Decoder {
    fn new(length: usize) -> Result<Self> {
        if length > voter::MAX_RAW {
            return Err("copy raw bound".into());
        }
        let mut plain = Vec::new();
        plain
            .try_reserve_exact(length)
            .map_err(|_| "copy allocation")?;
        Ok(Self {
            plain,
            length,
            model: voter::Voter::new()?,
        })
    }
    fn token(&mut self, count: usize, residual: Option<u8>) -> Result<()> {
        let remaining = self.length - self.plain.len();
        if remaining == 0
            || count > remaining
            || (count == remaining) != residual.is_none()
            || residual == Some(0)
        {
            return Err("copy token canonical/extent".into());
        }
        for _ in 0..count {
            let pos = self.plain.len();
            let stride = self.model.best();
            let byte = if pos >= stride {
                self.plain[pos - stride]
            } else {
                0
            };
            self.plain.push(byte);
            self.model.observe(byte)?;
        }
        if let Some(residual) = residual {
            let pos = self.plain.len();
            let stride = self.model.best();
            let prediction = if pos >= stride {
                self.plain[pos - stride]
            } else {
                0
            };
            let byte = prediction ^ residual;
            self.plain.push(byte);
            self.model.observe(byte)?
        }
        Ok(())
    }
}
fn census(
    raw: &[u8],
    mut token_check: impl FnMut(usize, Option<u8>) -> Result<()>,
) -> Result<Stats> {
    if raw.len() > voter::MAX_RAW {
        return Err("copy input bound".into());
    }
    let mut model = voter::Voter::new()?;
    let mut decoder = Decoder::new(raw.len())?;
    let mut at = 0;
    let mut s = Stats::default();
    while at < raw.len() {
        let begin = at;
        while at < raw.len() {
            let stride = model.best();
            let pred = if at >= stride { raw[at - stride] } else { 0 };
            if raw[at] != pred {
                break;
            }
            model.observe(raw[at])?;
            at += 1;
        }
        let count = at - begin;
        let residual = if at < raw.len() {
            let stride = model.best();
            let pred = if at >= stride { raw[at - stride] } else { 0 };
            let value = raw[at] ^ pred;
            model.observe(raw[at])?;
            at += 1;
            Some(value)
        } else {
            None
        };
        token_check(count, residual)?;
        decoder.token(count, residual)?;
        let mut value = count;
        let mut encoded = 1;
        while value >= 128 {
            encoded += 1;
            value >>= 7
        }
        if encoded > 3 {
            return Err("copy length encoding bound".into());
        }
        s.tokens += 1;
        s.copied += count;
        s.literals += usize::from(residual.is_some());
        s.length_bytes += encoded;
    }
    if decoder.plain != raw
        || decoder.model.best() != model.best()
        || decoder.model.votes() != model.votes()
        || decoder.model.positions() != model.positions()
        || s.copied + s.literals != raw.len()
    {
        return Err("copy E2E/full state".into());
    }
    Ok(s)
}
struct Reference {
    last: BTreeMap<u16, usize>,
    votes: [u32; 1025],
    at: usize,
    previous: Option<u8>,
}
impl Reference {
    fn new() -> Self {
        Self {
            last: BTreeMap::new(),
            votes: [0; 1025],
            at: 0,
            previous: None,
        }
    }
    fn best(&self) -> usize {
        let mut best = 1;
        for d in 1..=1024 {
            if self.votes[d] > self.votes[best] {
                best = d
            }
        }
        best
    }
    fn observe(&mut self, byte: u8) {
        if let Some(p) = self.previous {
            let key = (u16::from(p) << 8) | u16::from(byte);
            if key != 0 && key != 65535 {
                if let Some(old) = self.last.insert(key, self.at) {
                    let d = self.at - old;
                    if d <= 1024 {
                        self.votes[d] += 1
                    }
                }
            }
        }
        self.previous = Some(byte);
        self.at += 1;
    }
    fn next(&mut self, raw: &[u8]) -> Result<(usize, Option<u8>)> {
        if self.at >= raw.len() {
            return Err("reference terminal".into());
        }
        let begin = self.at;
        while self.at < raw.len() {
            let stride = self.best();
            let prediction = if self.at >= stride {
                raw[self.at - stride]
            } else {
                0
            };
            if prediction != raw[self.at] {
                break;
            }
            self.observe(raw[self.at]);
        }
        let copied = self.at - begin;
        let residual = if self.at < raw.len() {
            let stride = self.best();
            let pred = if self.at >= stride {
                raw[self.at - stride]
            } else {
                0
            };
            let value = raw[self.at] ^ pred;
            self.observe(raw[self.at]);
            Some(value)
        } else {
            None
        };
        Ok((copied, residual))
    }
}
fn read(path: &Path, max: usize) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| e.to_string())?;
    if f.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("input extent".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(max + 1)
        .map_err(|_| "input allocation")?;
    f.take((max + 1) as u64)
        .read_to_end(&mut v)
        .map_err(|e| e.to_string())?;
    if v.len() > max {
        return Err("input changed".into());
    }
    Ok(v)
}
fn get32(v: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        v.get(at..at + 4)
            .ok_or("u32")?
            .try_into()
            .map_err(|_| "u32 extent")?,
    ) as usize)
}
fn random(n: usize) -> Vec<u8> {
    let mut state = 0x43715badu32;
    (0..n)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        })
        .collect()
}
fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus".into());
    }
    let mut prefix = vec![0; 16384];
    prefix.extend_from_slice(&(0..4097).map(|i| (i % 256) as u8).collect::<Vec<_>>());
    let finite = [
        vec![],
        vec![0; 257],
        vec![255; 1025],
        random(2049),
        (0..4097).map(|i| (i % 256) as u8).collect(),
        prefix,
    ];
    let mut tokens = 0;
    for raw in &finite {
        let mut reference = Reference::new();
        let s = census(raw, |c, r| {
            if reference.next(raw)? != (c, r) {
                return Err("independent copy grammar".into());
            }
            Ok(())
        })?;
        if reference.at != raw.len() {
            return Err("reference extent".into());
        }
        tokens += s.tokens
    }
    let mut rejected = 0;
    for (count, value) in [(5, None), (0, None), (4, Some(1)), (0, Some(0))] {
        let mut d = Decoder::new(4)?;
        if d.token(count, value).is_ok() || !d.plain.is_empty() {
            return Err("invalid copy token accepted/committed".into());
        }
        rejected += 1;
        d.token(4, None)?;
        if d.plain != [0; 4] || d.token(0, None).is_ok() {
            return Err("copy rejection recovery/extra".into());
        }
        rejected += 1;
    }
    if Decoder::new(1048577).is_ok() || census(&vec![0; 1048577], |_, _| Ok(())).is_ok() {
        return Err("copy oversize".into());
    }
    rejected += 2;
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11
        || khc::verify_archive(archive, &Limits::default())
            .map_err(|e| e.to_string())?
            .bytes
            != 2810784
    {
        return Err("archive contract".into());
    }
    let data = read(archive, 1048576)?;
    if data.len() != 466395 {
        return Err("archive size".into());
    }
    let mut at = 32 + get32(&data, 20)?;
    let mut report = format!(
        "{{\"token_byte_state_exact\":true,\"public_byte_exact\":true,\"new_codec_implemented\":false,\"speed_evidence\":false,\"finite_inputs\":6,\"independent_tokens\":{tokens},\"rejects\":{rejected},\"rows\":["
    );
    let mut total = 0;
    for (index, entry) in entries.iter().enumerate() {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry path".into());
        }
        let raw = read(&corpus.join(&entry.name), 1048576)?;
        let len = get32(&data, at)?;
        at += 4;
        let frame = data.get(at..at + len).ok_or("archive frame")?;
        at += len + 4;
        if khc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
            return Err("public bytes".into());
        }
        let s = census(&raw, |_, _| Ok(()))?;
        if s != census(&raw, |_, _| Ok(()))? {
            return Err("census repeat".into());
        }
        let intervals = s.length_bytes + s.literals * 8;
        let old = raw.len() * 8;
        if index > 0 {
            report.push(',')
        }
        write!(&mut report,"{{\"name\":{:?},\"raw\":{},\"tokens\":{},\"copied\":{},\"literals\":{},\"length_bytes\":{},\"new_paid_intervals_bound\":{},\"old_bit_intervals\":{},\"interval_gate\":{}}}",entry.name,raw.len(),s.tokens,s.copied,s.literals,s.length_bytes,intervals,old,intervals<=old/2).map_err(|_|"report")?;
        total += raw.len();
    }
    if data.get(at..) != Some(&b"KHC1END\0"[..]) || total != 2810784 {
        return Err("archive terminal".into());
    }
    write!(&mut report, "],\"raw_bytes\":{total}}}").map_err(|_| "report")?;
    if report.len() > 16384 {
        return Err("report bound".into());
    }
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(e) = main_run() {
        eprintln!("row_copy: {e}");
        std::process::exit(1)
    }
}
