//! 失敗先行PLANの有限E2E。全入力/実capacityを検査し、frameはdiskへ複写しない。
#![allow(dead_code)]
#[path = "../lz-byte-ans/codec.rs"]
mod codec;
#[path = "../../../src/lhc/block/lz.rs"]
mod lz;
#[path = "../../../src/lhc/block/multi_range.rs"]
mod multi_range;
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
const MAX_INPUT: usize = 1 << 20;
fn allocate<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| "driver allocation")?;
    v.resize(n, value);
    Ok(v)
}
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("archive extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
fn next<'a>(b: &'a [u8], at: &mut usize) -> Result<&'a [u8]> {
    let len = num(b, *at)?;
    *at += 4;
    let frame = b.get(*at..*at + len).ok_or("archive frame extent")?;
    *at += len + 4;
    Ok(frame)
}
fn crc(b: &[u8]) -> u32 {
    crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, b) as u32
}
fn legacy(raw: &[u8], context: u8) -> Result<Option<Vec<u8>>> {
    let Some(payload) = lz::encode(raw, context)? else {
        return Ok(None);
    };
    let mut frame = allocate(40 + payload.len(), 0u8)?;
    frame[..8].copy_from_slice(b"KHC1BLK\0");
    frame[8..10].copy_from_slice(&2u16.to_le_bytes());
    frame[10] = if context == 3 { 2 } else { 3 };
    frame[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    frame[24..28].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[32..36].copy_from_slice(&crc(raw).to_le_bytes());
    frame[40..].copy_from_slice(&payload);
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..36]);
    digest.update(&frame[40..]);
    frame[36..40].copy_from_slice(&(digest.finalize() as u32).to_le_bytes());
    Ok(Some(frame))
}
fn peak(s: &codec::Stats, caller: usize) -> Result<usize> {
    let n = s
        .peak_capacity_bound
        .checked_add(caller)
        .ok_or("caller fee overflow")?;
    if n > codec::RAM_LIMIT {
        return Err("full caller/model/journal RAM".into());
    }
    Ok(n)
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        return Err("old/record/corpus required".into());
    }
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let record_entries =
        unlhare::lhc::list_archive(Path::new(&args[2]), &unlhare::Limits::default())
            .map_err(|e| e.to_string())?;
    if entries.len() != 11 || record_entries.len() != 11 {
        return Err("entry coverage".into());
    }
    let old = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    let record = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
    if old.len() != 466395 || record.len() != 457017 {
        return Err("archive pin size".into());
    }
    let finite = codec::finite_contract()?;
    if finite.contexts != 2 || finite.checks < 33000 {
        return Err("finite contract coverage".into());
    }
    let mut old_at = 32 + num(&old, 20)?;
    let mut record_at = 32 + num(&record, 20)?;
    let mut rows = Vec::new();
    let mut finite_legacy = 0;
    let mut selected_frames = 0;
    let mut improved = 0;
    let mut nonbenefit = 0;
    let mut applicable = 0;
    for (entry, record_entry) in entries.iter().zip(&record_entries) {
        if entry.name != record_entry.name
            || entry.original_size != record_entry.original_size
            || entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry pairing/name".into());
        }
        let old_frame = next(&old, &mut old_at)?;
        let record_frame = next(&record, &mut record_at)?;
        let raw =
            std::fs::read(Path::new(&args[3]).join(&entry.name)).map_err(|e| e.to_string())?;
        if raw.len() != entry.original_size as usize
            || unlhare::lhc::decompress_block(old_frame).map_err(|e| e.to_string())? != raw
            || unlhare::lhc::decompress_block(record_frame).map_err(|e| e.to_string())? != raw
        {
            return Err("public legacy/record whole bytes".into());
        }
        let c = codec::finite_legacy_contract(&raw, old_frame)?;
        finite_legacy += c.checks;
        let caller =
            old.capacity() + record.capacity() + raw.capacity().saturating_sub(raw.len()) + 1048576;
        let is_applicable = old_frame[10] >= 2;
        applicable += usize::from(is_applicable);
        let candidate = codec::encode_from_legacy(&raw, old_frame)?;
        let row = match candidate {
            Some((frame, s)) => {
                let (decoded, d) = codec::decode(&frame)?;
                if decoded != raw || frame.len() >= old_frame.len() {
                    return Err("candidate roundtrip/strict size benefit".into());
                }
                let encoder_peak = peak(&s, caller)?;
                let decoder_peak = peak(
                    &d,
                    caller + raw.capacity() + frame.capacity().saturating_sub(frame.len()),
                )?;
                let chosen = frame.len().min(record_frame.len());
                improved += usize::from(frame.len() < record_frame.len());
                selected_frames += chosen;
                serde_json::json!({"name":entry.name,"raw":raw.len(),"legacy_method":old_frame[10],"legacy_frame":old_frame.len(),"record_frame":record_frame.len(),"candidate_frame":frame.len(),"selected_frame":chosen,"context":s.context,"events":s.events,"literals":s.literals,"matches":s.matches,"model_capacity":s.model_capacity,"journal_capacity":s.journal_capacity,"journal_transient":s.journal_transient,"encode_logical_peak":encoder_peak,"decode_logical_peak":decoder_peak,"byte_exact":true})
            }
            None => {
                if is_applicable {
                    nonbenefit += codec::finite_nonbenefit_contract(&raw, old_frame)?.checks;
                }
                let conservative = caller + raw.len() + old_frame.len() + 24 * 1048576;
                if conservative > codec::RAM_LIMIT {
                    return Err("None conservative full fees".into());
                }
                selected_frames += record_frame.len();
                serde_json::json!({"name":entry.name,"raw":raw.len(),"legacy_method":old_frame[10],"legacy_frame":old_frame.len(),"record_frame":record_frame.len(),"candidate_frame":null,"selected_frame":record_frame.len(),"None_is_not_corruption":true,"logical_peak_reservation":conservative,"byte_exact":true})
            }
        };
        rows.push(row);
    }
    if old.get(old_at..) != Some(&b"KHC1END\0"[..])
        || record.get(record_at..) != Some(&b"KHC1END\0"[..])
    {
        return Err("archive tail".into());
    }
    // 固定ctx両方で上限/全byteを実旧LZ grammarから生成。探索パラメータを動かさない。
    let mut synthetic = Vec::new();
    for context in [3, 8] {
        for (name, raw) in [
            ("max-repeated", vec![b'A'; MAX_INPUT]),
            ("all-byte", (0..16384).map(|i| i as u8).collect()),
        ] {
            let frame = legacy(&raw, context)?.ok_or("synthetic legacy LZ missing")?;
            if unlhare::lhc::decompress_block(&frame).map_err(|e| e.to_string())? != raw {
                return Err("synthetic native old mismatch".into());
            }
            finite_legacy += codec::finite_legacy_contract(&raw, &frame)?.checks;
            let candidate = codec::encode_from_legacy(&raw, &frame)?;
            let (candidate_len, logical) = if let Some((new, s)) = candidate {
                let (decoded, ds) = codec::decode(&new)?;
                if decoded != raw {
                    return Err("synthetic new mismatch".into());
                }
                (
                    Some(new.len()),
                    peak(&s, old.capacity() + record.capacity() + 1048576)?.max(peak(
                        &ds,
                        old.capacity()
                            + record.capacity()
                            + raw.capacity()
                            + frame.capacity()
                            + 1048576,
                    )?),
                )
            } else {
                nonbenefit += codec::finite_nonbenefit_contract(&raw, &frame)?.checks;
                (
                    None,
                    24 * 1048576
                        + raw.capacity()
                        + frame.capacity()
                        + old.capacity()
                        + record.capacity()
                        + 1048576,
                )
            };
            if logical > codec::RAM_LIMIT {
                return Err("synthetic caller RAM".into());
            }
            synthetic.push(serde_json::json!({"name":name,"context":context,"raw":raw.len(),"legacy":frame.len(),"candidate":candidate_len,"logical_peak":logical,"byte_exact":true}));
        }
    }
    if applicable != 3 || nonbenefit == 0 {
        return Err("applicable/nonbenefit coverage missing".into());
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"synthetic":synthetic,"complete_inputs":11,"finite_checks":finite.checks,"finite_contexts":finite.contexts,"finite_legacy_checks":finite_legacy,"applicable":applicable,"nonbenefit_checks":nonbenefit,"improved_inputs":improved,"selected_frame_bytes":selected_frames,"container_existing":444,"integration_reservation":256,"all_fee_selection":selected_frames+700,"size_screen_gate":selected_frames+700 <= 457415,"allocation_fault_injection":false,"speed_evidence":false,"input_known_development":true,"raw_frame_disk":0,"native_integrated":false})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
