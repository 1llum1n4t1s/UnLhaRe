//! 有限partition oracleと実保存書庫からKFTへ写すE2E。diskにframeを複写しない。
#![allow(dead_code)]
#[path = "codec.rs"]
mod codec;
#[path = "../tree-span-compiled/codec.rs"]
mod reference;
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("archive extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn next<'a>(b: &'a [u8], at: &mut usize) -> Result<&'a [u8]> {
    let n = num(b, *at)?;
    *at += 4;
    let f = b.get(*at..*at + n).ok_or("archive frame")?;
    *at += n + 4;
    Ok(f)
}
fn seal(b: &mut [u8]) {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[..36]);
    d.update(&b[40..]);
    b[36..40].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
}
fn malformed(frame: &[u8]) -> Result<usize> {
    let mut count = 0;
    for at in [0, 8, 10, 11, 12, 16, 20, 24, 28, 30, 31, 32, 36] {
        let mut bad = frame.to_vec();
        bad[at] ^= 0x80;
        if at != 36 {
            seal(&mut bad);
        }
        if codec::decode(&bad).is_ok() {
            return Err(format!("malformed header accepted {at}"));
        }
        count += 1;
    }
    for end in 0..frame.len() {
        if codec::decode(&frame[..end]).is_ok() {
            return Err("frame truncation accepted".into());
        }
        count += 1;
    }
    let mut trailing = frame.to_vec();
    trailing.push(0);
    if codec::decode(&trailing).is_ok() {
        return Err("trailing extent accepted".into());
    }
    count += 1;
    let payload = num(frame, 24)?;
    trailing[24..28].copy_from_slice(&((payload + 1) as u32).to_le_bytes());
    seal(&mut trailing);
    if codec::decode(&trailing).is_ok() {
        return Err("ANS trailing accepted".into());
    }
    count += 1;
    if codec::decode(frame)?.0.len() != num(frame, 12)? {
        return Err("fresh decode after errors".into());
    }
    Ok(count + 1)
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        return Err("legacy/record/corpus required".into());
    }
    let entries = unlhare::khc::list_archive(Path::new(&args[1]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let record_entries =
        unlhare::khc::list_archive(Path::new(&args[2]), &unlhare::Limits::default())
            .map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    let record = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
    if entries.len() != 11
        || record_entries.len() != 11
        || saved.len() != 466395
        || record.len() != 457017
    {
        return Err("fixed corpus coverage".into());
    }
    let finite = codec::finite_backend_contract()?;
    if finite < 524800 {
        return Err("backend finite coverage".into());
    }
    let legacy_input_checks = legacy_input_contract()?;
    let histories = [[0; 6], [1023; 6], [1, 4, 16, 64, 256, 768]];
    let mut at = 32 + num(&saved, 20)?;
    let mut ra = 32 + num(&record, 20)?;
    let mut rows = Vec::new();
    let mut partitions = 0;
    let mut mdl = 0;
    let mut coded = 0;
    let mut improved = 0;
    let mut allframes = 0;
    let mut invalid = 0;
    let mut wire_checks = 0;
    for (entry, re) in entries.iter().zip(&record_entries) {
        if entry.name != re.name
            || entry.original_size != re.original_size
            || entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry pairing/name".into());
        }
        let old = next(&saved, &mut at)?;
        let rf = next(&record, &mut ra)?;
        let raw =
            std::fs::read(Path::new(&args[3]).join(&entry.name)).map_err(|e| e.to_string())?;
        if unlhare::khc::decompress_block(old).map_err(|e| e.to_string())? != raw
            || unlhare::khc::decompress_block(rf).map_err(|e| e.to_string())? != raw
        {
            return Err("public legacy/record bytes".into());
        }
        if old[10] == 1 {
            mdl += 1;
            partitions += codec::finite_partition_legacy(old, &histories)?;
            if codec::finite_partition_legacy(old, &[[1024; 6]]).is_ok() {
                return Err("invalid history accepted".into());
            }
        }
        let caller = saved.capacity()
            + record.capacity()
            + raw.capacity().saturating_sub(raw.len())
            + 1048576;
        let candidate = codec::encode_from_legacy(&raw, old)?;
        wire_checks += wire_contract(&raw, old, &candidate, caller)?;
        let row = if let Some((frame, s)) = candidate {
            coded += 1;
            let (decoded, d) = codec::decode(&frame)?;
            if decoded != raw {
                return Err("new full bytes".into());
            }
            let ep = s.peak_capacity_bound + caller;
            let dp = d.peak_capacity_bound
                + caller
                + raw.capacity()
                + frame.capacity().saturating_sub(frame.len());
            if ep > codec::RAM_LIMIT || dp > codec::RAM_LIMIT {
                return Err("whole caller/model/journal capacity".into());
            }
            invalid += malformed(&frame)?;
            let selected = frame.len().min(rf.len());
            allframes += selected;
            improved += usize::from(frame.len() < rf.len());
            let rerun = codec::encode_from_legacy(&raw, old)?
                .ok_or("candidate determinism fallback")?
                .0;
            if rerun != frame {
                return Err("candidate frame determinism".into());
            }
            serde_json::json!({"name":entry.name,"raw":raw.len(),"legacy_frame":old.len(),"record_frame":rf.len(),"candidate_frame":frame.len(),"selected_frame":selected,"events":s.events,"branches":s.branches,"runs":s.runs,"escapes":s.escapes,"journal_capacity":s.journal_capacity,"journal_transient":s.journal_transient,"encode_logical_peak":ep,"decode_logical_peak":dp,"byte_exact":true})
        } else {
            allframes += rf.len();
            let conservative = 54 * 1048576 + caller;
            if conservative > codec::RAM_LIMIT {
                return Err("None caller reservation".into());
            }
            serde_json::json!({"name":entry.name,"raw":raw.len(),"legacy_frame":old.len(),"record_frame":rf.len(),"candidate_frame":null,"selected_frame":rf.len(),"logical_peak_reservation":conservative,"byte_exact":true})
        };
        let mut bad = old.to_vec();
        bad[36] ^= 1;
        if codec::encode_from_legacy(&raw, &bad).is_ok() {
            return Err("legacy CRC error hidden as fallback".into());
        }
        invalid += 1;
        rows.push(row);
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..])
        || record.get(ra..) != Some(&b"KHC1END\0"[..])
        || mdl != 8
        || partitions != 1585176
        || coded == 0
    {
        return Err("tail/MDL/partition/coded coverage".into());
    }
    let mut synthetic = Vec::new();
    for (name, raw) in [
        ("empty", Vec::new()),
        ("one-byte", vec![255]),
        ("all-byte", (0..65536).map(|i| i as u8).collect()),
        ("max-repeated", vec![b'A'; codec::MAX_INPUT]),
    ] {
        let stored = codec::stored(&raw)?;
        if codec::decode(&stored)?.0 != raw {
            return Err("stored full bytes".into());
        }
        let old = unlhare::khc::compress_block(&raw).map_err(|e| e.to_string())?;
        if unlhare::khc::decompress_block(&old).map_err(|e| e.to_string())? != raw {
            return Err("synthetic legacy whole bytes".into());
        }
        let new = codec::encode_from_legacy(&raw, &old)?;
        wire_checks += wire_contract(
            &raw,
            &old,
            &new,
            saved.capacity() + record.capacity() + 1048576,
        )?;
        let (size, logical) = if let Some((frame, s)) = new {
            let (decoded, d) = codec::decode(&frame)?;
            if decoded != raw {
                return Err("synthetic new whole bytes".into());
            }
            (
                Some(frame.len()),
                (s.peak_capacity_bound
                    .max(d.peak_capacity_bound + raw.capacity() + old.capacity()))
                    + saved.capacity()
                    + record.capacity()
                    + 1048576,
            )
        } else {
            (
                None,
                54 * 1048576 + saved.capacity() + record.capacity() + 1048576,
            )
        };
        if logical > codec::RAM_LIMIT {
            return Err("synthetic full fees".into());
        }
        synthetic.push(serde_json::json!({"name":name,"raw":raw.len(),"legacy_method":old[10],"candidate":size,"logical_peak":logical,"byte_exact":true}));
    }
    let mut too = codec::stored(&[])?;
    too[12..16].copy_from_slice(&((codec::MAX_INPUT + 1) as u32).to_le_bytes());
    seal(&mut too);
    if codec::decode(&too).is_ok() {
        return Err("oversize accepted".into());
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"synthetic":synthetic,"backend_finite_checks":finite,"partition_leaves":partitions,"histories":3,"complete_inputs":11,"MDL_inputs":mdl,"coded_candidates":coded,"improved_inputs":improved,"malformed_checks":invalid+1,"legacy_input_checks":legacy_input_checks,"wire_byte_comparisons":wire_checks,"selected_frame_bytes":allframes,"container_existing":444,"integration_reservation":256,"all_fee_selection":allframes+700,"size_screen_pass":allframes+700<=457415,"speed_evidence":false,"native_integrated":false,"raw_frame_disk":0,"known_development":true,"allocation_fault_injection":false})
    );
    Ok(())
}
fn legacy_input_contract() -> Result<usize> {
    let mut valid = codec::stored(&[])?;
    valid[..8].copy_from_slice(b"KHC1BLK\0");
    seal(&mut valid);
    let mut checks = 0;
    for at in 0..40 {
        if codec::encode_from_legacy(&[], &valid[..at]).is_ok() {
            return Err("legacy truncated header accepted".into());
        }
        checks += 1;
    }
    for (at, value) in [
        (0, b'X'),
        (8, 9),
        (10, 4),
        (11, 1),
        (12, 1),
        (24, 1),
        (30, 1),
        (32, 1),
    ] {
        let mut bad = valid.clone();
        bad[at] = value;
        seal(&mut bad);
        if codec::encode_from_legacy(&[], &bad).is_ok() {
            return Err("legacy invalid header accepted".into());
        }
        checks += 1;
    }
    let mut record = valid.clone();
    record[..8].copy_from_slice(b"KRS1BLK\0");
    seal(&mut record);
    let mut excess = valid.clone();
    excess.resize(codec::MAX_INPUT + 41, 0);
    let mut trailing = valid.clone();
    trailing.push(0);
    for bad in [&record, &excess, &trailing] {
        if codec::encode_from_legacy(&[], bad).is_ok() {
            return Err("legacy wrong domain/extent accepted".into());
        }
        checks += 1;
    }
    if codec::encode_from_legacy(&[], &valid)?.is_some() {
        return Err("legacy stored fallback changed".into());
    }
    if codec::encode_from_legacy(&[1], &valid).is_ok() {
        return Err("legacy caller mismatch accepted".into());
    }
    Ok(checks + 2)
}
fn wire_contract(
    raw: &[u8],
    old: &[u8],
    candidate: &Option<(Vec<u8>, codec::Stats)>,
    caller: usize,
) -> Result<usize> {
    let expected = reference::encode_from_legacy(raw, old)?;
    match (candidate, expected) {
        (None, None) => (),
        (Some((frame, _)), Some((prior, stats))) => {
            if stats.peak_capacity_bound + caller + frame.capacity() > codec::RAM_LIMIT {
                return Err("wire reference full fees".into());
            }
            if *frame != prior || reference::decode(frame)?.0 != raw {
                return Err("wire old/new whole frame or old decoder differs".into());
            }
        }
        _ => return Err("wire fallback selection differs".into()),
    }
    Ok(1)
}
fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(f64::total_cmp);
    s[s.len() / 2]
}
struct TimedRow<'a> {
    name: String,
    raw: Vec<u8>,
    old: &'a [u8],
    new: Vec<u8>,
}
fn timed_decode(rows: &[TimedRow<'_>], new: bool, caller: usize) -> Result<(f64, Vec<f64>)> {
    let mut times = Vec::new();
    for row in rows {
        let frame = if new { &row.new[..] } else { row.old };
        let clock = std::time::Instant::now();
        let out = if frame.get(..8) == Some(&codec::MAGIC[..]) {
            let (out, s) = codec::decode(frame)?;
            if s.peak_capacity_bound + caller > codec::RAM_LIMIT {
                return Err("timed caller RAM".into());
            }
            out
        } else {
            unlhare::khc::decompress_block(frame).map_err(|e| e.to_string())?
        };
        let ms = clock.elapsed().as_secs_f64() * 1000.0;
        if out != row.raw {
            return Err("timed complete bytes".into());
        }
        std::hint::black_box(&out);
        times.push(ms);
    }
    Ok((times.iter().sum(), times))
}
fn speed() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 5 || !matches!(args[4].as_str(), "normal" | "reverse") {
        return Err("paired args".into());
    }
    let reverse = args[4] == "reverse";
    let entries = unlhare::khc::list_archive(Path::new(&args[2]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
    if entries.len() != 11 || saved.len() != 457017 {
        return Err("speed fixed input".into());
    }
    let mut at = 32 + num(&saved, 20)?;
    let mut rows = Vec::new();
    for entry in entries {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("speed name".into());
        }
        let old = next(&saved, &mut at)?;
        let raw =
            std::fs::read(Path::new(&args[3]).join(&entry.name)).map_err(|e| e.to_string())?;
        if unlhare::khc::decompress_block(old).map_err(|e| e.to_string())? != raw {
            return Err("public saved bytes".into());
        }
        rows.push(TimedRow {
            name: entry.name,
            raw,
            old,
            new: Vec::new(),
        });
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("speed tail".into());
    }
    let raws: usize = rows.iter().map(|r| r.raw.capacity()).sum();
    let mut cache = 0;
    let mut improved = 0;
    for row in &mut rows {
        let f = row.old;
        let new = if f[10] == 2 && f.get(40..48) == Some(&b"KHC1BLK\0"[..]) && f.get(50) == Some(&1)
        {
            if let Some((candidate, s)) = codec::encode_from_legacy(&row.raw, &f[40..])? {
                if s.peak_capacity_bound + saved.capacity() + raws + cache + 1048576 + 40
                    > codec::RAM_LIMIT
                {
                    return Err("speed prepare full fees".into());
                }
                if candidate.len() < f.len() {
                    improved += 1;
                    candidate
                } else {
                    f.to_vec()
                }
            } else {
                f.to_vec()
            }
        } else {
            f.to_vec()
        };
        cache += new.capacity();
        row.new = new;
    }
    let caller = saved.capacity() + raws + cache + 1048576;
    let size: usize = rows.iter().map(|r| r.new.len()).sum();
    if size + 700 > 457415 || improved == 0 {
        return Err("unchanged rate/selection gate".into());
    }
    for new in if reverse {
        [true, false]
    } else {
        [false, true]
    } {
        let _ = timed_decode(&rows, new, caller)?;
    }
    let (mut old, mut new) = (Vec::new(), Vec::new());
    let mut od = vec![Vec::new(); 11];
    let mut nd = vec![Vec::new(); 11];
    for _ in 0..9 {
        for candidate in if reverse {
            [true, false]
        } else {
            [false, true]
        } {
            let (sum, t) = timed_decode(&rows, candidate, caller)?;
            if candidate {
                new.push(sum);
                for (i, x) in t.into_iter().enumerate() {
                    nd[i].push(x);
                }
            } else {
                old.push(sum);
                for (i, x) in t.into_iter().enumerate() {
                    od[i].push(x);
                }
            }
        }
    }
    let detail:Vec<_>=rows.iter().enumerate().map(|(i,r)|serde_json::json!({"name":r.name,"old_frame":r.old.len(),"new_frame":r.new.len(),"old_median_ms":median(&od[i]),"new_median_ms":median(&nd[i]),"byte_exact":true})).collect();
    println!(
        "{}",
        serde_json::json!({"order":args[4],"pairs":9,"warm":1,"rows":detail,"old_group_ms":old,"new_group_ms":new,"old_median_ms":median(&old),"new_median_ms":median(&new),"decode_screen_pass":median(&new)<=median(&old),"all_fee_selection":size+700,"encode_speed_evidence":false,"native_integrated":false,"final_7zip_gate":false,"caller_capacity":caller})
    );
    Ok(())
}
fn main() {
    let result = if std::env::args().count() == 5 {
        speed()
    } else {
        run()
    };
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
