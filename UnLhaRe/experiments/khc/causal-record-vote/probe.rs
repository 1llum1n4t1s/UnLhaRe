//! 因果的幅stateの有限独立参照と実corpus census。圧縮frame/速度の証拠ではない。
mod voter;
use std::{collections::BTreeMap, fmt::Write, fs::File, io::Read, path::Path};
use unlhare::{Limits, khc};
type Result<T> = std::result::Result<T, String>;
fn reference(raw: &[u8]) -> Result<usize> {
    let mut actual = voter::Voter::new()?;
    let mut last = BTreeMap::<u16, usize>::new();
    let mut votes = [0u32; 1025];
    let mut previous = None;
    for (i, &byte) in raw.iter().enumerate() {
        let mut best = 1;
        for d in 1..=1024 {
            if votes[d] > votes[best] {
                best = d
            }
        }
        if actual.best() != best {
            return Err(format!("causal best at {i}"));
        }
        if let Some(p) = previous {
            let key = (u16::from(p) << 8) | u16::from(byte);
            if key != 0 && key != 65535 {
                if let Some(old) = last.insert(key, i) {
                    let d = i - old;
                    if d <= 1024 {
                        votes[d] += 1
                    }
                }
            }
        }
        actual.observe(byte)?;
        previous = Some(byte);
    }
    let mut best = 1;
    for d in 1..=1024 {
        if votes[d] > votes[best] {
            best = d
        }
    }
    if actual.best() != best || actual.votes() != &votes {
        return Err("terminal best/votes".into());
    }
    for key in 0..65536 {
        let expected = last.get(&(key as u16)).map_or(u32::MAX, |&i| i as u32);
        if actual.positions()[key] != expected {
            return Err("all pair positions".into());
        }
    }
    Ok(raw.len() + 1)
}
fn random(n: usize) -> Vec<u8> {
    let mut state = 0x37ac514du32;
    (0..n)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        })
        .collect()
}
fn read(path: &Path, max: usize) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| e.to_string())?;
    if f.metadata().map_err(|e| e.to_string())?.len() > max as u64 {
        return Err("read bound".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(max + 1)
        .map_err(|_| "input allocation")?;
    f.take((max + 1) as u64)
        .read_to_end(&mut v)
        .map_err(|e| e.to_string())?;
    if v.len() > max {
        return Err("read changed".into());
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
fn execute() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus".into());
    }
    let mut blind = vec![0; 16384];
    blind.extend_from_slice(&random(2049));
    let inputs = vec![
        vec![],
        vec![0; 1025],
        vec![255; 1025],
        random(2049),
        (0..4097).map(|i| (i % 256) as u8).collect(),
        blind,
    ];
    let mut states = 0;
    for raw in &inputs {
        states += reference(raw)?
    }
    let mut limit = voter::Voter::new()?;
    for _ in 0..voter::MAX_RAW {
        limit.observe(0)?
    }
    if limit.observe(7).is_ok()
        || limit.best() != 1
        || limit.events != 0
        || limit.votes() != &[0; 1025]
        || limit.positions().iter().any(|&x| x != u32::MAX)
    {
        return Err("bound/default/transaction".into());
    }
    drop(limit);
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
    let archive = read(archive, 1048576)?;
    if archive.len() != 466395 {
        return Err("archive extent".into());
    }
    let mut at = 32 + get32(&archive, 20)?;
    let mut total = 0;
    let mut report = format!(
        "{{\"state_exact\":true,\"public_byte_exact\":true,\"new_codec_implemented\":false,\"speed_evidence\":false,\"finite_inputs\":6,\"independent_states\":{states},\"terminal_position_checks\":393216,\"bound_rejects\":1,\"state_bound\":{},\"rows\":[",
        voter::BOUND
    );
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
        let len = get32(&archive, at)?;
        at += 4;
        let frame = archive.get(at..at + len).ok_or("frame extent")?;
        at += len + 4;
        if khc::decompress_block(frame).map_err(|e| e.to_string())? != raw {
            return Err("public byte mismatch".into());
        }
        let mut model = voter::Voter::new()?;
        let mut used = [0usize; 1025];
        for &byte in &raw {
            used[model.best()] += 1;
            model.observe(byte)?
        }
        if model.capacity() > voter::BOUND
            || model.eligible != model.votes().iter().map(|&x| x as usize).sum::<usize>()
            || used.iter().sum::<usize>() != raw.len()
        {
            return Err("state capacity/count".into());
        }
        let mut order: Vec<_> = (1..=1024).filter(|&d| used[d] != 0).collect();
        order.sort_by_key(|&d| (std::cmp::Reverse(used[d]), d));
        let top: Vec<_> = order.iter().take(4).map(|&d| vec![d, used[d]]).collect();
        if index > 0 {
            report.push(',')
        }
        write!(&mut report,"{{\"name\":{:?},\"raw\":{},\"final_stride\":{},\"used_final_stride_bytes\":{},\"events\":{},\"matched\":{},\"eligible\":{},\"changes\":{},\"state_capacity\":{},\"top_used\":{:?}}}",entry.name,raw.len(),model.best(),used[model.best()],model.events,model.matched,model.eligible,model.changes,model.capacity(),top).map_err(|_|"report")?;
        total += raw.len();
    }
    if archive.get(at..) != Some(&b"KHC1END\0"[..]) || total != 2810784 {
        return Err("archive/total terminal".into());
    }
    write!(&mut report, "],\"raw_bytes\":{total}}}").map_err(|_| "report")?;
    if report.len() > 16384 {
        return Err("report bound".into());
    }
    println!("{report}");
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("causal_vote: {e}");
        std::process::exit(1)
    }
}
