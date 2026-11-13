//! 公開native対private選択器。双方同じ呼出し費用で測り、照合は計時外。
#![allow(dead_code)]
#[path = "../lz-byte-ans-narrow/codec.rs"]
mod codec;
use std::{hint::black_box, path::Path, time::Instant};
type Result<T> = std::result::Result<T, String>;
const RAM: usize = 64 << 20;
fn num(b: &[u8], at: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        b.get(at..at + 4)
            .ok_or("archive extent")?
            .try_into()
            .map_err(|_| "u32")?,
    ) as usize)
}
struct Row<'a> {
    name: String,
    raw: Vec<u8>,
    old: &'a [u8],
    new: Vec<u8>,
}
fn variant(raw: &[u8], frame: &[u8], caller: usize) -> Result<(Vec<u8>, usize)> {
    if frame.get(..8) != Some(&b"KRS1BLK\0"[..]) {
        return Err("record frame identity".into());
    }
    if frame[10] == 2
        && frame.get(40..48) == Some(&b"KHC1BLK\0"[..])
        && frame.get(50).is_some_and(|&method| method >= 2)
    {
        if let Some((candidate, s)) = codec::encode_from_legacy(raw, &frame[40..])? {
            let logical = s
                .peak_capacity_bound
                .checked_add(caller)
                .and_then(|v| v.checked_add(frame.len() - frame[40..].len()))
                .ok_or("capacity overflow")?;
            if logical > RAM {
                return Err("variant full model/journal/caller fee".into());
            }
            if candidate.len() < frame.len() {
                return Ok((candidate, logical));
            }
        }
    }
    let out = frame.to_vec();
    let logical = caller + raw.len() + frame.len() + out.capacity() + 24 * 1048576;
    if logical > RAM {
        return Err("fallback caller reservation".into());
    }
    Ok((out, logical))
}
fn decode(frame: &[u8], caller: usize) -> Result<Vec<u8>> {
    if frame.get(..8) == Some(&b"KAB1BLK\0"[..]) {
        let (out, s) = codec::decode(frame)?;
        if s.peak_capacity_bound + caller > RAM {
            return Err("decode caller fee".into());
        }
        Ok(out)
    } else {
        unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())
    }
}
fn timed(rows: &[Row<'_>], candidate: bool, caller: usize) -> Result<(f64, Vec<f64>)> {
    let mut times = Vec::with_capacity(rows.len());
    for row in rows {
        let frame = if candidate { &row.new[..] } else { row.old };
        let start = Instant::now();
        let out = if candidate {
            decode(black_box(frame), caller)?
        } else {
            unlhare::lhc::decompress_block(black_box(frame)).map_err(|e| e.to_string())?
        };
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        if out != row.raw {
            return Err("timed whole bytes".into());
        }
        black_box(&out);
        times.push(ms);
    }
    Ok((times.iter().sum(), times))
}
fn median(v: &[f64]) -> f64 {
    let mut sorted = v.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[sorted.len() / 2]
}
fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 || !matches!(args[3].as_str(), "normal" | "reverse") {
        return Err("record/corpus/order required".into());
    }
    let reverse = args[3] == "reverse";
    let entries = unlhare::lhc::list_archive(Path::new(&args[1]), &unlhare::Limits::default())
        .map_err(|e| e.to_string())?;
    let saved = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
    if entries.len() != 11 || saved.len() != 457017 {
        return Err("saved corpus coverage".into());
    }
    let mut rows = Vec::new();
    let mut at = 32 + num(&saved, 20)?;
    for entry in entries {
        if entry.is_directory
            || !entry
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("entry name/type".into());
        }
        let len = num(&saved, at)?;
        at += 4;
        let frame = saved.get(at..at + len).ok_or("frame extent")?;
        at += len + 4;
        let raw =
            std::fs::read(Path::new(&args[2]).join(&entry.name)).map_err(|e| e.to_string())?;
        if raw.len() != entry.original_size as usize
            || unlhare::lhc::decompress_block(frame).map_err(|e| e.to_string())? != raw
        {
            return Err("public saved whole bytes".into());
        }
        rows.push(Row {
            name: entry.name,
            raw,
            old: frame,
            new: Vec::new(),
        });
    }
    if saved.get(at..) != Some(&b"KHC1END\0"[..]) {
        return Err("archive tail".into());
    }
    let raw_capacity: usize = rows.iter().map(|r| r.raw.capacity()).sum();
    let mut new_capacity = 0;
    let mut encode_logical = 0;
    for row in &mut rows {
        let caller = saved.capacity() + raw_capacity + new_capacity + 1048576;
        let (frame, logical) = variant(&row.raw, row.old, caller)?;
        encode_logical = encode_logical.max(logical);
        new_capacity += frame.capacity();
        row.new = frame;
    }
    let caller = saved.capacity() + raw_capacity + new_capacity + 1048576;
    for row in &rows {
        if decode(&row.new, caller)? != row.raw {
            return Err("cached candidate whole bytes".into());
        }
    }
    let old_bytes: usize = rows.iter().map(|r| r.old.len()).sum();
    let new_bytes: usize = rows.iter().map(|r| r.new.len()).sum();
    if old_bytes != 456573 || new_bytes + 700 > 457415 {
        return Err("all fee screen gate".into());
    }
    for candidate in if reverse {
        [true, false]
    } else {
        [false, true]
    } {
        let _ = timed(&rows, candidate, caller)?;
    }
    let mut old_group = Vec::new();
    let mut new_group = Vec::new();
    let mut old_rows = vec![Vec::new(); 11];
    let mut new_rows = vec![Vec::new(); 11];
    for _ in 0..9 {
        for candidate in if reverse {
            [true, false]
        } else {
            [false, true]
        } {
            let (sum, times) = timed(&rows, candidate, caller)?;
            if candidate {
                new_group.push(sum);
                for (i, t) in times.into_iter().enumerate() {
                    new_rows[i].push(t);
                }
            } else {
                old_group.push(sum);
                for (i, t) in times.into_iter().enumerate() {
                    old_rows[i].push(t);
                }
            }
        }
    }
    let details:Vec<_>=rows.iter().enumerate().map(|(i,r)|serde_json::json!({"name":r.name,"old_frame":r.old.len(),"new_frame":r.new.len(),"old_median_ms":median(&old_rows[i]),"new_median_ms":median(&new_rows[i]),"byte_exact":true})).collect();
    println!(
        "{}",
        serde_json::json!({"order":args[3],"pairs":9,"warm":1,"rows":details,"old_group_ms":old_group,"new_group_ms":new_group,"old_median_ms":median(&old_group),"new_median_ms":median(&new_group),"decode_screen_pass":median(&new_group)<=median(&old_group),"selected_frame_bytes":new_bytes,"all_fee_selection":new_bytes+700,"encode_logical_peak":encode_logical,"decode_caller_capacity":caller,"encode_speed_evidence":false,"native_variant_integrated":false,"final_7zip_gate":false,"known_development":true})
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
