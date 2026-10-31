//! 実frameの区間列を再生して復元全体とrANS単独の費用を分離する診断。
#![allow(dead_code)]
#[path = "../kht-bounded-ans/codec.rs"]
mod current;
mod trace_codec;
use std::{path::Path, time::Instant};
type Result<T> = std::result::Result<T, String>;
const DRIVER: usize = 1 << 20;
const ROUNDS: usize = 9;
const MODEL: usize = 16 << 20;

fn u32_at(b: &[u8], at: usize) -> Result<usize> {
    let end = at.checked_add(4).ok_or("u32 extent overflow")?;
    Ok(u32::from_le_bytes(b.get(at..end).ok_or("u32 extent")?.try_into().map_err(|_| "u32")?) as usize)
}
fn add(parts: &[usize]) -> Result<usize> {
    parts.iter().try_fold(0usize, |sum, n| sum.checked_add(*n).ok_or_else(|| "capacity overflow".into()))
}
fn gate(parts: &[usize]) -> Result<usize> {
    let peak = add(parts)?;
    if peak > current::RAM_LIMIT {
        return Err(format!("logical RAM bound {peak}"));
    }
    Ok(peak)
}
fn next<'a>(saved: &'a [u8], at: &mut usize) -> Result<&'a [u8]> {
    let len = u32_at(saved, *at)?;
    let start = at.checked_add(4).ok_or("archive extent overflow")?;
    let end = start.checked_add(len).ok_or("archive extent overflow")?;
    let after = end.checked_add(4).ok_or("archive CRC extent overflow")?;
    let frame = saved.get(start..end).ok_or("archive frame extent")?;
    saved.get(end..after).ok_or("archive frame CRC extent")?;
    *at = after;
    Ok(frame)
}
fn payload(frame: &[u8]) -> Result<&[u8]> {
    let alphabet = u16::from_le_bytes(frame.get(28..30).ok_or("alphabet extent")?.try_into().map_err(|_| "alphabet")?) as usize;
    let start = add(&[40, alphabet.checked_mul(2).ok_or("alphabet overflow")?, u32_at(frame, 20)?])?;
    let end = start.checked_add(u32_at(frame, 24)?).ok_or("payload overflow")?;
    if end != frame.len() {
        return Err("payload/frame terminal extent".into());
    }
    frame.get(start..end).ok_or_else(|| "payload extent".into())
}
fn median(samples: &[f64]) -> f64 {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[sorted.len() / 2]
}

// 時計は各呼出しの外側だけ。照合、課金、出力は計測区間から外す。
fn full(frame: &[u8], raw: &[u8], caller: usize, event_bytes: usize) -> Result<(f64, usize)> {
    gate(&[MODEL, 7 * (raw.len() + 1), 131072, frame.len(), caller, event_bytes])?;
    let clock = Instant::now();
    let decoded = current::decode(std::hint::black_box(frame));
    let ms = clock.elapsed().as_secs_f64() * 1000.0;
    let (out, stats) = decoded?;
    let peak = gate(&[stats.peak_capacity_bound, caller, event_bytes, out.capacity()])?;
    if out != raw {
        return Err("timed current complete bytes".into());
    }
    std::hint::black_box(&out);
    Ok((ms, peak))
}
fn replay(payload: &[u8], events: &[[u32; 3]], caller: usize, event_bytes: usize) -> Result<(f64, usize)> {
    let peak = gate(&[caller, event_bytes, 4096])?;
    let clock = Instant::now();
    let result = trace_codec::replay(std::hint::black_box(payload), std::hint::black_box(events));
    let ms = clock.elapsed().as_secs_f64() * 1000.0;
    result?;
    Ok((ms, peak))
}
fn malformed(payload: &[u8], events: &[[u32; 3]], caller: usize, event_bytes: usize) -> Result<usize> {
    if payload.is_empty() {
        return Err("expected nonempty rANS payload".into());
    }
    for bad in [&payload[..0], &payload[..payload.len() - 1]] {
        if trace_codec::replay(bad, events).is_ok() {
            return Err("truncated replay accepted".into());
        }
    }
    let extra = payload.len().checked_add(1).ok_or("payload size overflow")?;
    gate(&[caller, event_bytes, extra, 4096])?;
    let mut trailing = Vec::new();
    trailing.try_reserve_exact(extra).map_err(|_| "trailing allocation")?;
    gate(&[caller, event_bytes, trailing.capacity(), 4096])?;
    trailing.extend_from_slice(payload);
    trailing.push(0);
    if trace_codec::replay(&trailing, events).is_ok() {
        return Err("trailing replay accepted".into());
    }
    drop(trailing);
    trace_codec::replay(payload, events)?;
    Ok(4)
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive/corpus required".into());
    }
    let archive = Path::new(&args[1]);
    if std::fs::metadata(archive).map_err(|e| e.to_string())?.len() != 466395 {
        return Err("fixed native archive bytes".into());
    }
    let entries = unlhare::khc::list_archive(archive, &unlhare::Limits::default()).map_err(|e| e.to_string())?;
    let saved = std::fs::read(archive).map_err(|e| e.to_string())?;
    if entries.len() != 11 || saved.len() != 466395 {
        return Err("fixed native corpus coverage".into());
    }
    let mut at = add(&[32, u32_at(&saved, 20)?])?;
    let mut rows = Vec::new();
    let mut mdl = 0;
    let mut invalid_checks = 0;
    let mut logical_peak = gate(&[saved.capacity(), DRIVER])?;
    let mut full_totals = [0.0f64; ROUNDS];
    let mut replay_totals = [0.0f64; ROUNDS];
    let mut interval_totals = [0usize; 2];
    for entry in entries {
        if entry.is_directory
            || entry.name.is_empty()
            || !entry.name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            || matches!(entry.name.as_str(), "." | "..")
        {
            return Err("native name/directory contract".into());
        }
        let old = next(&saved, &mut at)?;
        let raw_path = Path::new(&args[2]).join(&entry.name);
        if std::fs::metadata(&raw_path).map_err(|e| e.to_string())?.len() > current::MAX_INPUT as u64 {
            return Err("corpus input bound".into());
        }
        let raw = std::fs::read(&raw_path).map_err(|e| e.to_string())?;
        if entry.original_size != raw.len() as u64 {
            return Err("native original size".into());
        }
        logical_peak = logical_peak.max(gate(&[32 << 20, saved.capacity(), raw.capacity(), raw.len(), DRIVER])?);
        let native = unlhare::khc::decompress_block(old).map_err(|e| e.to_string())?;
        logical_peak = logical_peak.max(gate(&[32 << 20, saved.capacity(), raw.capacity(), native.capacity(), DRIVER])?);
        if native != raw {
            return Err(format!("native complete bytes {}", entry.name));
        }
        drop(native);
        if old.get(10) != Some(&1) {
            rows.push(serde_json::json!({"name":entry.name,"profiled":false,"byte_exact":true,"raw_bytes":raw.len(),"native_frame_bytes":old.len()}));
            continue;
        }
        mdl += 1;
        // encoderの最大journal24MiBとmodel16MiBを実行前に予約する。
        logical_peak = logical_peak.max(gate(&[MODEL, 24 << 20, 9 * (raw.len() + 1), 131112, raw.len(), old.len(), saved.capacity(), raw.capacity(), DRIVER])?);
        let (frame, encode_stats) = current::encode_from_legacy(&raw, old)?.ok_or("MDL KHT1 encode fallback")?;
        logical_peak = logical_peak.max(gate(&[encode_stats.peak_capacity_bound, saved.capacity(), raw.capacity(), frame.capacity(), DRIVER])?);
        let caller = add(&[saved.capacity(), raw.capacity(), frame.capacity(), DRIVER])?;
        // captureのjournal成長最大36MiBを事前課金。事後も実capacityを足す保守的境界。
        logical_peak = logical_peak.max(gate(&[MODEL, 36 << 20, 7 * (raw.len() + 1), 131072, frame.len(), caller])?);
        let captured = trace_codec::capture(&frame)?;
        let event_bytes = captured.events.capacity().checked_mul(std::mem::size_of::<[u32; 3]>()).ok_or("event capacity overflow")?;
        // eventsはcaptureの36MiB journal予約に含まれる。
        let capture_live_peak = gate(&[captured.stats.peak_capacity_bound, caller, captured.plain.capacity()])?;
        logical_peak = logical_peak.max(capture_live_peak);
        if captured.plain != raw {
            return Err("capture complete bytes".into());
        }
        let mut counts = [0usize; 2];
        for event in &captured.events {
            let i = match event[2] {
                262144 => 0,
                256 => 1,
                _ => return Err("recorded interval total".into()),
            };
            if event[1] == 0 || event[0].checked_add(event[1]).is_none_or(|end| end > event[2]) {
                return Err("recorded interval extent".into());
            }
            counts[i] += 1;
        }
        if counts.iter().sum::<usize>() != captured.events.len() {
            return Err("interval count".into());
        }
        for i in 0..2 {
            interval_totals[i] += counts[i];
        }
        let roots = captured.root_leaf;
        let tokens = captured.tokens;
        let capture_peak = captured.stats.peak_capacity_bound;
        let journal_capacity = captured.journal_capacity_bytes;
        let journal_transient = captured.journal_transient_bytes;
        let events = captured.events;
        drop(captured.plain);
        let ans = payload(&frame)?;
        invalid_checks += malformed(ans, &events, caller, event_bytes)?;
        let (_, p) = full(&frame, &raw, caller, event_bytes)?;
        logical_peak = logical_peak.max(p);
        let (_, p) = replay(ans, &events, caller, event_bytes)?;
        logical_peak = logical_peak.max(p);
        let mut full_samples = Vec::with_capacity(ROUNDS);
        let mut replay_samples = Vec::with_capacity(ROUNDS);
        let mut row_peak = capture_live_peak;
        for round in 0..ROUNDS {
            let ((f, fp), (r, rp)) = if round % 2 == 0 {
                let f = full(&frame, &raw, caller, event_bytes)?;
                let r = replay(ans, &events, caller, event_bytes)?;
                (f, r)
            } else {
                let r = replay(ans, &events, caller, event_bytes)?;
                let f = full(&frame, &raw, caller, event_bytes)?;
                (f, r)
            };
            full_samples.push(f);
            replay_samples.push(r);
            full_totals[round] += f;
            replay_totals[round] += r;
            row_peak = row_peak.max(fp).max(rp);
        }
        logical_peak = logical_peak.max(row_peak);
        rows.push(serde_json::json!({"name":entry.name,"profiled":true,"byte_exact":true,
            "raw_bytes":raw.len(),"native_frame_bytes":old.len(),"current_frame_bytes":frame.len(),"payload_bytes":ans.len(),
            "intervals":events.len(),"q18_intervals":counts[0],"byte256_intervals":counts[1],"root_leaf":roots,"tokens":tokens,
            "journal_capacity_bytes":journal_capacity,"journal_transient_bytes":journal_transient,"event_capacity_bytes":event_bytes,
            "logical_peak_bytes":row_peak,"capture_library_peak_bytes":capture_peak,
            "full_current_decode_median_ms":median(&full_samples),"interval_replay_only_median_ms":median(&replay_samples),
            "full_current_decode_samples_ms":full_samples,"interval_replay_only_samples_ms":replay_samples}));
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) || mdl != 8 || rows.len() != 11 {
        return Err("native archive tail/MDL coverage".into());
    }
    println!(
        "{}",
        serde_json::json!({"rows":rows,"entries":11,"MDL_inputs":mdl,"archive_bytes":saved.len(),
        "phases":["full_current_decode","interval_replay_only"],"rounds":ROUNDS,"warm":1,"pair_order":"AB/BA alternating",
        "speed_evidence":false,"native_changes":false,"raw_frame_disk":0,"diagnostic_only":true,
        "whole_minus_replay_is_reference_only":true,"difference_includes":["model","CDF","active_state","inverse","other_full_decode_work"],
        "interval_totals":{"q18":interval_totals[0],"byte256":interval_totals[1]},"replay_rejection_and_recovery_checks":invalid_checks,
        "logical_peak_bytes":logical_peak,"ram_limit_bytes":current::RAM_LIMIT,"driver_fee_bytes":DRIVER,
        "full_current_decode_total_samples_ms":full_totals,"interval_replay_only_total_samples_ms":replay_totals,
        "full_current_decode_total_median_ms":median(&full_totals),"interval_replay_only_total_median_ms":median(&replay_totals)})
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("replay diagnostic: {error}");
        std::process::exit(1);
    }
}
