//! 失敗契約はPLAN。private新識別子の全復元と、モデル再構築込みの復号比較を行う。
#![allow(dead_code)]
mod block;
#[path = "../../../src/lhc/block/mod.rs"]
mod original;
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
const RESERVE: usize = 54 << 20;
const OUTER: &[u8; 8] = b"KDR1BLK\0";
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(b.get(at..at + 4).ok_or("field extent")?.try_into().map_err(|_| "field")?) as usize)
}
fn ram(caller: usize) -> Result<()> {
    if caller.checked_add(RESERVE).ok_or("caller overflow")? > 64 << 20 {
        return Err("caller/library bound".into());
    }
    Ok(())
}
fn exact(len: usize) -> Result<Vec<u8>> {
    if len > original::MAX_INPUT + 80 {
        return Err("frame bound".into());
    }
    let mut v = Vec::new();
    v.try_reserve_exact(len).map_err(|_| "frame allocation")?;
    if v.capacity() > len {
        return Err("frame capacity".into());
    }
    Ok(v)
}
fn wire(b: &[u8]) -> u32 {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[..28]);
    d.update(&b[32..]);
    d.finalize() as u32
}
fn seal(b: &mut [u8]) {
    let crc = wire(b);
    b[28..32].copy_from_slice(&crc.to_le_bytes());
}
fn wrap(old: &[u8], inner: &[u8]) -> Result<Vec<u8>> {
    if old.len() < 80 || old[10] != 2 || num(old, 16)? != 0 || inner.len() > num(old, 12)? + 40 {
        return Err("wrapper source".into());
    }
    let mut b = exact(40 + inner.len())?;
    b.extend_from_slice(&old[..40]);
    b[..8].copy_from_slice(OUTER);
    b[20..24].copy_from_slice(&(inner.len() as u32).to_le_bytes());
    b.extend_from_slice(inner);
    seal(&mut b);
    Ok(b)
}
fn decode(b: &[u8], caller: usize) -> Result<Vec<u8>> {
    ram(caller)?;
    if b.get(..8) != Some(&OUTER[..]) {
        return unlhare::lhc::decompress_block(b).map_err(|e| e.to_string());
    }
    if b.len() < 80 || b.len() > original::MAX_INPUT + 80 || b[8..10] != [1, 0] || b[10] != 2 || b[11] != 0 || b[32..40] != [0; 8] {
        return Err("dual wrapper header".into());
    }
    let raw = num(b, 12)?;
    let model = num(b, 16)?;
    let payload = num(b, 20)?;
    if raw > original::MAX_INPUT
        || model != 0
        || payload < 48
        || payload > raw + 40
        || 40usize.checked_add(payload) != Some(b.len())
        || wire(b) as usize != num(b, 28)?
        || b.get(40..48) != Some(&block::MAGIC[..])
        || num(b, 52)? != raw
    {
        return Err("dual wrapper fields/CRC".into());
    }
    let (v, s) = block::decode(&b[40..])?;
    if s.phase_capacity_bound > RESERVE || v.len() != raw || original::crc32(&v) as usize != num(b, 24)? {
        return Err("dual wrapper raw/phase".into());
    }
    Ok(v)
}
struct Row<'a> {
    name: String,
    raw: Vec<u8>,
    old: &'a [u8],
    selected: Vec<u8>,
}
impl Row<'_> {
    fn candidate(&self) -> &[u8] {
        if self.selected.is_empty() { self.old } else { &self.selected }
    }
}
fn timed(rows: &[Row<'_>], new: bool, caller: usize) -> Result<Vec<f64>> {
    let mut times = Vec::new();
    for row in rows {
        ram(caller)?;
        let clock = std::time::Instant::now();
        let out = if new {
            decode(row.candidate(), caller)?
        } else {
            unlhare::lhc::decompress_block(row.old).map_err(|e| e.to_string())?
        };
        let ms = clock.elapsed().as_secs_f64() * 1000.;
        if out != row.raw {
            return Err("paired whole bytes".into());
        }
        std::hint::black_box(&out);
        times.push(ms);
    }
    Ok(times)
}
fn median(v: &[f64]) -> f64 {
    let mut a = v.to_vec();
    a.sort_by(f64::total_cmp);
    a[a.len() / 2]
}
fn inner_seal(b: &mut [u8]) {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[40..76]);
    d.update(&b[80..]);
    let crc = d.finalize() as u32;
    b[76..80].copy_from_slice(&crc.to_le_bytes());
    seal(b);
}
fn copied(b: &[u8], extra: usize) -> Result<Vec<u8>> {
    let mut v = exact(b.len() + extra)?;
    v.extend_from_slice(b);
    Ok(v)
}
fn reject(b: Vec<u8>, caller: usize) -> Result<()> {
    if decode(&b, caller + b.capacity()).is_ok() {
        return Err("malformed accepted".into());
    }
    Ok(())
}
fn malformed(rows: &[Row<'_>], caller: usize) -> Result<(usize, usize)> {
    let (mut cuts, mut semantic) = (0, 0);
    for row in rows {
        let b = row.candidate();
        ram(caller + 2 * (b.len() + 1))?;
        for n in 0..b.len() {
            if decode(&b[..n], caller).is_ok() {
                return Err("cut accepted".into());
            }
            cuts += 1;
        }
        let mut bad = copied(b, 1)?;
        bad.push(0);
        reject(bad, caller)?;
        cuts += 1;
        let mut bad = copied(b, 0)?;
        bad[28] ^= 1;
        reject(bad, caller)?;
        cuts += 1;
        if !row.selected.is_empty() {
            // 全てwire CRCを再封印し、CRC不一致だけで意味検査を代用しない。
            for field in [8usize, 10, 11, 32, 40, 48, 50, 51, 70] {
                let mut bad = copied(b, 0)?;
                bad[field] ^= 128;
                if field >= 40 {
                    inner_seal(&mut bad);
                } else {
                    seal(&mut bad);
                }
                reject(bad, caller)?;
                semantic += 1;
            }
            for field in [12usize, 16, 20, 52, 56, 60, 64] {
                let mut bad = copied(b, 0)?;
                bad[field..field + 4].copy_from_slice(&u32::MAX.to_le_bytes());
                if field >= 40 {
                    inner_seal(&mut bad);
                } else {
                    seal(&mut bad);
                }
                reject(bad, caller)?;
                semantic += 1;
            }
            for lane in 0..2 {
                for state in [0u32, 1u32 << 31] {
                    let mut bad = copied(b, 0)?;
                    let payload = 80 + 2 * usize::from(u16::from_le_bytes([b[68], b[69]])) + num(b, 60)?;
                    bad[payload + lane * 4..payload + lane * 4 + 4].copy_from_slice(&state.to_le_bytes());
                    inner_seal(&mut bad);
                    reject(bad, caller)?;
                    semantic += 1;
                }
            }
            let mut bad = copied(b, 0)?;
            bad[72] ^= 1;
            inner_seal(&mut bad);
            reject(bad, caller)?;
            semantic += 1;
            if unlhare::lhc::decompress_block(b).is_ok() || original::decode(&b[40..]).is_ok() {
                return Err("old decoder accepted new identifiers".into());
            }
            semantic += 2;
        }
        if decode(b, caller)? != row.raw {
            return Err("recovery whole bytes".into());
        }
    }
    Ok((cuts, semantic))
}
fn stored(raw: &[u8]) -> Result<Vec<u8>> {
    let mut b = exact(raw.len() + 40)?;
    b.resize(40, 0);
    b[..8].copy_from_slice(b"KRS1BLK\0");
    b[8] = 1;
    b[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    b[20..24].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    b[24..28].copy_from_slice(&original::crc32(raw).to_le_bytes());
    b.extend_from_slice(raw);
    seal(&mut b);
    Ok(b)
}
fn run() -> Result<()> {
    // 固定11入力は合計2810784B。manifest/list/全read前にも余裕込みで先払いする。
    ram(6 << 20)?;
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 || !matches!(args[3].as_str(), "e2e" | "normal" | "reverse") {
        return Err("archive corpus mode".into());
    }
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if saved.len() != 457017 || entries.len() != 11 {
        return Err("fixed archive".into());
    }
    let mut at = 32 + num(&saved, 20)?;
    let mut rows = Vec::new();
    for e in entries {
        if e.is_directory || !e.name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
            return Err("entry".into());
        }
        let len = num(&saved, at)?;
        at = at.checked_add(4).ok_or("frame prefix")?;
        if len < 40 || len > original::MAX_INPUT + 80 {
            return Err("frame extent".into());
        }
        let old = saved.get(at..at.checked_add(len).ok_or("frame end")?).ok_or("frame")?;
        at += len;
        ram(saved.capacity() + rows.iter().map(|r: &Row<'_>| r.raw.capacity()).sum::<usize>() + e.original_size as usize + 1048576)?;
        let raw = std::fs::read(Path::new(&args[2]).join(&e.name)).map_err(|e| e.to_string())?;
        ram(saved.capacity() + rows.iter().map(|r: &Row<'_>| r.raw.capacity()).sum::<usize>() + raw.capacity() + 1048576)?;
        if raw.len() as u64 != e.original_size || original::crc32(&raw) as usize != num(&saved, at)? {
            return Err("entry raw/CRC".into());
        }
        at += 4;
        rows.push(Row {
            name: e.name,
            raw,
            old,
            selected: Vec::new(),
        });
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("footer".into());
    }
    let base = saved.capacity() + rows.iter().map(|r| r.raw.capacity()).sum::<usize>() + 1048576;
    ram(base)?;
    let mut caller = base;
    let (mut eligible, mut changed, mut unprofitable) = (0, 0, 0);
    let mut construction = Vec::new();
    for row in &mut rows {
        if row.old[10] == 2 && row.old.get(50) == Some(&1) {
            eligible += 1;
            ram(caller)?;
            let clock = std::time::Instant::now();
            match block::transcode(&row.old[40..]) {
                Ok((inner, s)) => {
                    if s.phase_bound > RESERVE {
                        return Err("construction bound".into());
                    }
                    if inner.len() < row.old.len() - 40 {
                        ram(caller + inner.capacity() + inner.len() + 40)?;
                        let selected = wrap(row.old, &inner)?;
                        if decode(&selected, caller + inner.capacity() + selected.capacity())? != row.raw {
                            return Err("construction raw".into());
                        }
                        caller += selected.capacity();
                        ram(caller)?;
                        row.selected = selected;
                        changed += 1;
                    } else {
                        unprofitable += 1;
                    }
                    construction.push(serde_json::json!({"name":row.name,"events":s.events,"grammar_steps":s.grammar_steps,"implicit":s.implicit,"phase_bound":s.phase_bound,"model_capacity":s.model_capacity,"journal_capacity":s.journal_capacity,"journal_transient":s.journal_transient,"ms":clock.elapsed().as_secs_f64()*1000.}));
                }
                Err(e) if e == "unprofitable dual body" => {
                    unprofitable += 1;
                    construction.push(serde_json::json!({"name":row.name,"unprofitable":true,"ms":clock.elapsed().as_secs_f64()*1000.}));
                }
                Err(e) => return Err(e),
            }
        }
    }
    if eligible != 8 {
        return Err("eligible MDL count".into());
    }
    let overhead = saved.len() - rows.iter().map(|r| r.old.len()).sum::<usize>();
    let projected_archive = overhead + rows.iter().map(|r| r.candidate().len()).sum::<usize>();
    let all_fee = projected_archive + 256;
    let fee_pass = all_fee <= 457415 && all_fee < 457273;
    if args[3] == "e2e" {
        timed(&rows, false, caller)?;
        timed(&rows, true, caller)?;
        let (oracle, invalid, rollback) = block::finite_backend()?;
        let grammar = block::finite_schedule()?;
        let (cuts, semantic) = malformed(&rows, caller)?;
        let mut boundaries = 0;
        for n in [0, 1, 256, 4096, 1048576] {
            ram(caller + 2 * (n + 40))?;
            let raw: Vec<_> = (0..n).map(|i| (i as u8).wrapping_mul(53)).collect();
            let frame = stored(&raw)?;
            if decode(&frame, caller)? != raw {
                return Err("stored boundary".into());
            }
            boundaries += 1;
        }
        println!(
            "{}",
            serde_json::json!({"complete_inputs":11,"eligible_MDL":eligible,"changed":changed,"unprofitable":unprofitable,"oracle_checks":oracle,"invalid_checks":invalid,"rollback_checks":rollback,"grammar_checks":grammar,"malformed_checks":cuts,"semantic_checks":semantic,"stored_boundaries":boundaries,"projected_archive_bytes":projected_archive,"all_fee":all_fee,"fee_pass":fee_pass,"caller_capacity":caller,"construction":construction,"byte_exact":true,"wire_changed":true,"native_integrated":false,"true_RAW_encode_evidence":false,"speed_evidence":false})
        );
    } else {
        if args[3] == "reverse" {
            rows.reverse();
        }
        let (mut old, mut new) = (Vec::new(), Vec::new());
        let (mut od, mut nd) = (vec![Vec::new(); 11], vec![Vec::new(); 11]);
        timed(&rows, false, caller)?;
        timed(&rows, true, caller)?;
        for pair in 0..9 {
            let (a, b) = if pair % 2 == 0 {
                let a = timed(&rows, false, caller)?;
                let b = timed(&rows, true, caller)?;
                (a, b)
            } else {
                let b = timed(&rows, true, caller)?;
                let a = timed(&rows, false, caller)?;
                (a, b)
            };
            old.push(a.iter().sum::<f64>());
            new.push(b.iter().sum::<f64>());
            for i in 0..11 {
                od[i].push(a[i]);
                nd[i].push(b[i]);
            }
        }
        let detail: Vec<_> = rows
            .iter()
            .enumerate()
            .map(|(i, r)| serde_json::json!({"name":r.name,"old_ms":median(&od[i]),"new_ms":median(&nd[i]),"byte_exact":true}))
            .collect();
        let speed_pass = median(&new) <= 0.85 * median(&old) && (0..11).all(|i| median(&nd[i]) <= 1.10 * median(&od[i]));
        println!(
            "{}",
            serde_json::json!({"order":args[3],"warm":1,"pairs":9,"old_median_ms":median(&old),"new_median_ms":median(&new),"old_group_ms":old,"new_group_ms":new,"rows":detail,"speed_pass":speed_pass,"fee_pass":fee_pass,"diagnostic_pass":speed_pass&&fee_pass,"projected_archive_bytes":projected_archive,"all_fee":all_fee,"changed":changed,"construction":construction,"wire_changed":true,"byte_exact":true,"native_integrated":false,"final_7zip_gate":false,"true_RAW_encode_evidence":false})
        );
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
