//! 失敗先行の有限E2E。全byte比較を省略しない。製品unit testではない。
#![allow(dead_code)]
mod baseline_block;
use baseline_block as baseline;
mod codec;
#[path = "full_codec.rs"]
mod full_trial;
use codec::{Model, Result, Stats};
use std::path::Path;
use unlhare::{Limits, khc};
fn pattern(n: usize, kind: usize) -> Vec<u8> {
    let mut state = 0x91b774e5u32;
    (0..n)
        .map(|i| match kind {
            0 => 0,
            1 => {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            }
            _ => b"recorded grammar repeated\n"[i % 26],
        })
        .collect()
}
fn reference(counts: &[u32; 256]) -> [u16; 256] {
    let sum: u64 = counts.iter().map(|&x| u64::from(x)).sum();
    let support = counts.iter().filter(|&&x| x != 0).count();
    let mut freq = [0u16; 256];
    if sum == 0 {
        return freq;
    }
    let remaining = 32768 - support;
    let mut used = 0;
    for (i, &x) in counts.iter().enumerate() {
        if x != 0 {
            freq[i] = (1 + u64::from(x) * remaining as u64 / sum) as u16;
            used += usize::from(freq[i]);
        }
    }
    // 独立の順位数による剰余配分。codecのsortを呼ばない。
    for (i, &x) in counts.iter().enumerate() {
        if x == 0 {
            continue;
        }
        let rem = u64::from(x) * remaining as u64 % sum;
        let rank = counts
            .iter()
            .enumerate()
            .filter(|&(j, &v)| {
                v != 0
                    && (u64::from(v) * remaining as u64 % sum > rem
                        || (u64::from(v) * remaining as u64 % sum == rem && j < i))
            })
            .count();
        if rank < 32768 - used {
            freq[i] += 1;
        }
    }
    freq
}

struct Reference<'a> {
    raw: &'a [u8],
    at: usize,
    best: usize,
    previous: Option<u8>,
    seen: std::collections::BTreeMap<u16, usize>,
    votes: [usize; 1025],
    pending: [(usize, u8); 4],
    cursor: usize,
    length: usize,
    tokens: usize,
    copied: usize,
    literals: usize,
    fields: usize,
}
impl<'a> Reference<'a> {
    fn new(raw: &'a [u8]) -> Self {
        Self {
            raw,
            at: 0,
            best: 1,
            previous: None,
            seen: Default::default(),
            votes: [0; 1025],
            pending: [(0, 0); 4],
            cursor: 0,
            length: 0,
            tokens: 0,
            copied: 0,
            literals: 0,
            fields: 0,
        }
    }
    fn observe(&mut self, byte: u8) {
        if let Some(prev) = self.previous {
            let pair = (u16::from(prev) << 8) | u16::from(byte);
            if pair != 0 && pair != 65535 {
                if let Some(old) = self.seen.insert(pair, self.at) {
                    let gap = self.at - old;
                    if gap <= 1024 {
                        self.votes[gap] += 1;
                    }
                }
            }
        }
        self.previous = Some(byte);
        // 全票から幅を再構成。codecのmaximum/last Vec/observeを共有しない。
        self.best = 1;
        for i in 2..=1024 {
            if self.votes[i] > self.votes[self.best] {
                self.best = i;
            }
        }
    }
    fn prediction(&self) -> u8 {
        if self.at >= self.best {
            self.raw[self.at - self.best]
        } else {
            0
        }
    }
    fn next(&mut self) -> Option<(usize, u8)> {
        if self.cursor == self.length {
            if self.at == self.raw.len() {
                return None;
            }
            self.cursor = 0;
            self.length = 0;
            let begin = self.at;
            while self.at < self.raw.len() && self.prediction() == self.raw[self.at] {
                self.observe(self.raw[self.at]);
                self.at += 1;
            }
            let mut count = self.at - begin;
            self.copied += count;
            self.tokens += 1;
            loop {
                let byte = (count % 128) as u8;
                count /= 128;
                self.pending[self.length] = (0, byte | if count != 0 { 128 } else { 0 });
                self.length += 1;
                if count == 0 {
                    break;
                }
            }
            if self.at < self.raw.len() {
                let pred = self.prediction();
                let class = if pred == 0 {
                    1
                } else if pred == 255 {
                    2
                } else {
                    3
                };
                self.pending[self.length] = (class, self.raw[self.at] ^ pred);
                self.length += 1;
                self.literals += 1;
                self.observe(self.raw[self.at]);
                self.at += 1;
            }
        }
        let field = self.pending[self.cursor];
        self.cursor += 1;
        self.fields += 1;
        Some(field)
    }
}
fn grammar_contract() -> Result<usize> {
    let mut cases = 0;
    for raw in [
        vec![],
        vec![255],
        pattern(257, 1),
        pattern(2049, 2),
        pattern(8193, 1),
        {
            let mut raw = vec![0; 257];
            raw.extend_from_slice(&pattern(2049, 1));
            raw
        },
    ] {
        let mut reference = Reference::new(&raw);
        let observed = codec::scan(&raw, |class, byte| {
            if reference.next() != Some((class, byte)) {
                return Err("independent grammar field mismatch".into());
            }
            Ok(())
        })?;
        if reference.next().is_some()
            || (
                observed.width,
                observed.tokens,
                observed.copied,
                observed.literals,
                observed.fields,
            ) != (
                reference.best,
                reference.tokens,
                reference.copied,
                reference.literals,
                reference.fields,
            )
        {
            return Err("independent grammar end state".into());
        }
        cases += 1;
    }
    Ok(cases)
}

fn model_contract() -> Result<(usize, usize)> {
    let mut cases = 0;
    let mut slots = 0;
    for support in 1..=256 {
        for kind in 0..3 {
            let mut counts = [0u32; 256];
            for (i, x) in counts[..support].iter_mut().enumerate() {
                *x = match kind {
                    0 => 1,
                    1 => {
                        if i == 0 {
                            u32::MAX
                        } else {
                            1
                        }
                    }
                    _ => 1 + (i % 7) as u32,
                };
            }
            let model = Model::normalize(&counts)?;
            if model.freq != reference(&counts) {
                return Err("independent integer CDF mismatch".into());
            }
            let lut = model.lut()?;
            let mut at = 0;
            for i in 0..256 {
                if usize::from(model.cum[i]) != at {
                    return Err("CDF cumulative mismatch".into());
                }
                for slot in &lut[at..at + usize::from(model.freq[i])] {
                    if usize::from(*slot) != i {
                        return Err("LUT slot mismatch".into());
                    }
                    slots += 1;
                }
                at += usize::from(model.freq[i]);
            }
            if at != 32768 {
                return Err("CDF normalization sum".into());
            }
            let empty = Model::normalize(&[0; 256])?;
            let wire =
                codec::serialize(&[model.clone(), empty.clone(), empty.clone(), empty.clone()])?;
            let parsed = codec::parse_models(&wire)?;
            if parsed != [model, empty.clone(), empty.clone(), empty] {
                return Err("model wire roundtrip".into());
            }
            cases += 1;
        }
    }
    if Model::normalize(&[0; 256])?.support != 0 {
        return Err("empty model".into());
    }
    Ok((cases, slots))
}
fn reseal(frame: &mut [u8]) {
    let crc = codec::wire_crc(frame);
    frame[28..32].copy_from_slice(&crc.to_le_bytes());
}
fn rejects(frame: &[u8]) -> Result<()> {
    if codec::decode(frame).is_ok() {
        return Err("must-reject frame accepted".into());
    }
    Ok(())
}
fn malformed(frame: &[u8]) -> Result<usize> {
    let mut count = 0;
    for offset in [0usize, 8, 10, 11, 12, 16, 20, 24, 32, 39] {
        let mut bad = frame.to_vec();
        bad[offset] ^= 128;
        reseal(&mut bad);
        rejects(&bad)?;
        count += 1;
    }
    let mut bad = frame.to_vec();
    bad[28] ^= 1;
    rejects(&bad)?;
    count += 1;
    for cut in [0, 1, 7, 8, 39, frame.len() - 1] {
        rejects(&frame[..cut])?;
        count += 1;
    }
    let mut bad = frame.to_vec();
    bad.push(0);
    rejects(&bad)?;
    count += 1;
    for magic in [b"KRC1BLK\0", b"KRB1BLK\0", b"KRP1BLK\0", b"KHC1BLK\0"] {
        let mut bad = frame.to_vec();
        bad[..8].copy_from_slice(magic);
        reseal(&mut bad);
        rejects(&bad)?;
        count += 1;
    }
    if frame[10] == 1 {
        let m = codec::u32_at(frame, 16)?;
        let start = 40 + m;
        for offset in [40, start, start + 1, start + 2, start + 3, start + 4] {
            let mut bad = frame.to_vec();
            bad[offset] ^= 1;
            reseal(&mut bad);
            rejects(&bad)?;
            count += 1;
        }
    }
    Ok(count)
}
fn crafted(fields: &[(usize, u8)], residual_zero: bool) -> Result<Vec<u8>> {
    let raw = vec![0u8; 1024];
    let mut hist = [[0u32; 256]; 4];
    for &(c, b) in fields {
        hist[c][usize::from(b)] += 1;
    }
    if residual_zero {
        hist[1][0] += 1;
    }
    if hist[0].iter().all(|&x| x == 0) {
        hist[0][0] = 1;
    }
    let models = [
        Model::normalize(&hist[0])?,
        Model::normalize(&hist[1])?,
        Model::normalize(&hist[2])?,
        Model::normalize(&hist[3])?,
    ];
    let meta = codec::serialize(&models)?;
    let mut enc = codec::entropy::Encoder::with_limit(1024)?;
    for &(c, b) in fields {
        models[c].put(b, &mut enc)?;
    }
    codec::pack(&raw, &meta, &enc.finish()?, 1)
}
fn abnormal_contract() -> Result<usize> {
    let mut count = 0;
    // ULEB canonicality is checked independently of ANS and CRC.
    for sequence in [
        &[0x80, 0][..],
        &[0x80, 0x80, 0][..],
        &[0x80, 0x80, 0x80, 0][..],
        &[0x81, 0x08][..],
    ] {
        let mut at = 0;
        if codec::read_count(
            || {
                let b = *sequence.get(at).ok_or("count truncated")?;
                at += 1;
                Ok(b)
            },
            1024,
        )
        .is_ok()
        {
            return Err("bad ULEB accepted".into());
        }
        count += 1;
        let fields: Vec<_> = sequence.iter().map(|&b| (0, b)).collect();
        rejects(&crafted(&fields, false)?)?;
        count += 1;
    }
    for fields in [
        vec![(0, 0)],
        vec![(0, 0), (1, 1)],
        vec![(0, 0x80), (0, 8), (0, 1)],
        vec![(0, 0x80), (0, 8), (1, 1), (1, 2)],
    ] {
        rejects(&crafted(&fields, false)?)?;
        count += 1;
    }
    rejects(&crafted(&[(0, 0), (1, 0)], true)?)?;
    count += 1;
    // singletonの余分なputはANS恒等写像でwireに存在しない。
    // 未使用の非empty residual model自体は仕様上有効。拒否要件にしない。
    if codec::decode(&crafted(&[(0, 0x80), (0, 8), (1, 1)], false)?)?.0 != vec![0; 1024] {
        return Err("unused singleton model rejected".into());
    }
    let valid = crafted(&[(0, 0x80), (0, 8)], false)?;
    if codec::decode(&valid)?.0 != vec![0; 1024] {
        return Err("crafted terminal/recovery".into());
    }
    let m = codec::u32_at(&valid, 16)?;
    for offset in [40usize, 42, 43, 44, 45, 46] {
        let mut bad = valid.clone();
        bad[offset] ^= 255;
        reseal(&mut bad);
        rejects(&bad)?;
        count += 1;
    }
    let mut bad = valid.clone();
    bad.insert(40 + m, 1);
    let payload = codec::u32_at(&bad, 20)? + 1;
    bad[20..24].copy_from_slice(&(payload as u32).to_le_bytes());
    reseal(&mut bad);
    rejects(&bad)?;
    count += 1;
    let mut bad = valid.clone();
    bad.pop();
    let payload = codec::u32_at(&bad, 20)? - 1;
    bad[20..24].copy_from_slice(&(payload as u32).to_le_bytes());
    reseal(&mut bad);
    rejects(&bad)?;
    count += 1;
    let mut bad = valid.clone();
    bad.push(1);
    let payload = codec::u32_at(&bad, 20)? + 1;
    bad[20..24].copy_from_slice(&(payload as u32).to_le_bytes());
    reseal(&mut bad);
    rejects(&bad)?;
    count += 1;
    let mut bad = valid.clone();
    let end = 40 + m + 1;
    bad[end..end + 4].copy_from_slice(&((1u32 << 23) + 1).to_le_bytes());
    reseal(&mut bad);
    rejects(&bad)?;
    count += 1;
    if codec::decode(&valid)?.0 != vec![0; 1024] {
        return Err("reject recovery".into());
    }
    Ok(count)
}
fn verify(old: &[u8], frame: &[u8], raw: &[u8]) -> Result<Stats> {
    if baseline::decode(old)?.0 != raw
        || khc::decompress_block(old).map_err(|e| e.to_string())? != raw
    {
        return Err("baseline full bytes".into());
    }
    let (v, s) = codec::decode(frame)?;
    if v != raw {
        return Err("new full bytes".into());
    }
    if s.method == 1 {
        let expected = codec::scan(raw, |_, _| Ok(()))?;
        if (s.fields, s.tokens, s.copied, s.literals, s.width)
            != (
                expected.fields,
                expected.tokens,
                expected.copied,
                expected.literals,
                expected.width,
            )
        {
            return Err("coded token/state mismatch".into());
        }
    }
    Ok(s)
}
fn read(path: &Path, bound: usize) -> Result<Vec<u8>> {
    let n = path.metadata().map_err(|e| e.to_string())?.len();
    if n > bound as u64 {
        return Err("input file bound".into());
    }
    std::fs::read(path).map_err(|e| e.to_string())
}
fn run() -> Result<String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive corpus required".into());
    }
    let (cdf, slots) = model_contract()?;
    let grammar_cases = grammar_contract()?;
    let mut rejected = abnormal_contract()?;
    let mut logical = 0;
    let mut finite = 0;
    let mut pruned_trials = 0;
    let mut modes = [false; 3];
    for n in [
        0, 1, 2, 255, 256, 257, 1023, 1024, 1025, 4096, 65536, 1048576,
    ] {
        for kind in 0..3 {
            let raw = pattern(n, kind);
            let (old, os) = baseline::encode_hybrid(&raw, true)?;
            let public =
                khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                    .map_err(|e| e.to_string())?;
            if old != public {
                return Err("finite public bytes".into());
            }
            drop(public);
            let (new, s) = codec::encode(&raw)?;
            if new != full_trial::encode(&raw)?.0 {
                return Err("pruned/full finite frame mismatch".into());
            }
            if s.pruned {
                pruned_trials += 1;
            }
            let ds = verify(&old, &new, &raw)?;
            if new != codec::encode(&raw)?.0 {
                return Err("finite reencode bytes".into());
            }
            modes[s.method as usize] = true;
            logical = logical
                .max(s.logical_bound)
                .max(ds.logical_bound)
                .max(os.phase_capacity_bound);
            rejected += malformed(&new)?;
            finite += 1;
        }
    }
    let mut forced = 0;
    for raw in [vec![0; 65536], b"ABCD".repeat(16384), {
        let mut r = vec![0; 16384];
        r.extend_from_slice(&b"ABCD".repeat(16384));
        r
    }] {
        let (old, _) = baseline::encode_hybrid(&raw, true)?;
        let mut s = Stats::default();
        let frame = codec::record(&raw, raw.len(), &mut s, 0)?;
        let ds = verify(&old, &frame, &raw)?;
        rejected += malformed(&frame)?;
        logical = logical.max(s.logical_bound).max(ds.logical_bound);
        modes[1] = true;
        forced += 1;
    }
    let legacyraw = b"legacy arithmetic grammar\n".repeat(200);
    let (old, _) = baseline::encode_hybrid(&legacyraw, true)?;
    let frame = codec::pack(&legacyraw, &[], &old, 2)?;
    verify(&old, &frame, &legacyraw)?;
    rejected += malformed(&frame)?;
    modes[2] = true;
    let oversize = vec![0; 1048577];
    if codec::encode(&oversize).is_ok() || codec::scan(&oversize, |_, _| Ok(())).is_ok() {
        return Err("oversize accepted".into());
    }
    drop(oversize);
    if modes != [true; 3] {
        return Err("wire method coverage".into());
    }
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let entries = khc::list_archive(archive, &Limits::default()).map_err(|e| e.to_string())?;
    if entries.len() != 11
        || khc::verify_archive(archive, &Limits::default())
            .map_err(|e| e.to_string())?
            .bytes
            != 2810784
    {
        return Err("archive public contract".into());
    }
    let saved = read(archive, 1048576)?;
    if saved.len() != 466395 {
        return Err("archive extent".into());
    }
    let mut at = 32 + codec::u32_at(&saved, 20)?;
    let mut old_total = 0;
    let mut new_total = 0;
    let mut report = String::from("{\"rows\":[");
    for (i, entry) in entries.iter().enumerate() {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry path".into());
        }
        let raw = read(&corpus.join(&entry.name), 1048576)?;
        let length = codec::u32_at(&saved, at)?;
        at += 4;
        let frozen = saved.get(at..at + length).ok_or("saved frame truncated")?;
        at += length + 4;
        let (old, os) = baseline::encode_hybrid(&raw, true)?;
        if old != frozen
            || old
                != khc::compress_block_with_strategy(&raw, khc::BlockStrategy::BinaryAdaptive)
                    .map_err(|e| e.to_string())?
        {
            return Err("saved/public/private baseline bytes".into());
        }
        let (frame, s) = codec::encode(&raw)?;
        if frame != full_trial::encode(&raw)?.0 {
            return Err("pruned/full corpus frame mismatch".into());
        }
        if s.pruned {
            pruned_trials += 1;
        }
        let ds = verify(&old, &frame, &raw)?;
        if frame != codec::encode(&raw)?.0 {
            return Err("corpus reencode bytes".into());
        }
        logical = logical
            .max(s.logical_bound)
            .max(ds.logical_bound)
            .max(os.phase_capacity_bound);
        rejected += malformed(&frame)?;
        old_total += old.len();
        new_total += frame.len();
        if i != 0 {
            report.push(',');
        }
        report.push_str(&format!("{{\"name\":\"{}\",\"raw\":{},\"old_frame\":{},\"new_frame\":{},\"method\":{},\"metadata\":{},\"fields\":{},\"tokens\":{},\"copied\":{},\"literals\":{},\"width\":{},\"journal\":{},\"transient\":{},\"logical_bound\":{}}}",entry.name,raw.len(),old.len(),frame.len(),s.method,s.metadata,s.fields,s.tokens,s.copied,s.literals,s.width,s.journal,s.transient,s.logical_bound));
    }
    if pruned_trials == 0 || new_total != 456573 {
        return Err("prune reachability/frozen frame aggregate".into());
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) || old_total != 465951 || logical > 67108864 {
        return Err("archive tail/bound".into());
    }
    report.push_str(&format!("],\"strict_rejection\":true,\"must_reject_checks\":{rejected},\"byte_exact\":true,\"public_baseline_exact\":true,\"all_methods\":true,\"coded_state_exact\":true,\"finite_encodings\":{finite},\"forced_encodings\":{forced},\"independent_grammar_cases\":{grammar_cases},\"pruned_trials\":{pruned_trials},\"full_trial_frame_exact\":true,\"cdf_cases\":{cdf},\"lut_slots\":{slots},\"bound_rejects\":2,\"old_frame_bytes\":{old_total},\"new_frame_bytes\":{new_total},\"reserved_archive_estimate\":{},\"size_gate\":{},\"logical_bound\":{logical},\"speed_evidence\":false}}",new_total+700,new_total+700<=457415));
    Ok(report)
}
fn main() {
    match run() {
        Ok(report) => println!("{report}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
