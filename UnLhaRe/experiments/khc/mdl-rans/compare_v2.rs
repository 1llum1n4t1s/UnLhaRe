//! 別研究形式の有限E2Eとold/new paired encode/decode。製品速度ではない。
#[allow(dead_code)]
#[path = "candidate_block_v2.rs"]
mod new;
#[allow(dead_code)]
#[path = "baseline_block.rs"]
mod old;
use std::{fs::File, io::Read, time::Instant};
#[derive(Clone, Copy)]
struct Interval {
    c: u32,
    f: u32,
    t: u32,
}
fn reference(events: &[Interval]) -> Vec<u8> {
    let mut state = 1u64 << 23;
    let mut emitted = Vec::new();
    for e in events.iter().rev() {
        let bits = e.t.trailing_zeros();
        let threshold = ((1u64 << 23) / u64::from(e.t)) * 256 * u64::from(e.f);
        while state >= threshold {
            emitted.push((state % 256) as u8);
            state /= 256;
        }
        state = (state / u64::from(e.f)) * u64::from(e.t) + state % u64::from(e.f) + u64::from(e.c);
        assert_eq!(1u64 << bits, u64::from(e.t));
    }
    let mut out = vec![0];
    out.extend_from_slice(&(state as u32).to_le_bytes());
    out.extend(emitted.into_iter().rev());
    out
}
fn coder_contract() -> Result<(usize, usize), String> {
    let mut cases = 0;
    let mut rejects = 0;
    let mut sequences = vec![
        vec![],
        vec![Interval {
            c: 165,
            f: 1,
            t: 256,
        }],
    ];
    for seed in 0..64u32 {
        let mut state = seed + 1;
        let mut events = Vec::new();
        for index in 0..257 {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let t = if index % 5 == 0 { 256 } else { 32768 };
            let f = match index % 6 {
                0 => 1,
                1 => t,
                2 => 2,
                3 => t - 1,
                _ => 1 + state % t,
            };
            let c = (state >> 8) % (t - f + 1);
            events.push(Interval { c, f, t });
        }
        sequences.push(events);
    }
    for events in &sequences {
        let expected = reference(events);
        let mut enc = new::mdl_entropy::Encoder::with_limit(16384).map_err(str::to_owned)?;
        for e in events {
            enc.interval(e.c, e.f, e.t).map_err(str::to_owned)?;
        }
        let bytes = enc.finish().map_err(str::to_owned)?;
        if bytes != expected {
            return Err("independent rANS byte mismatch".into());
        }
        let mut dec = new::mdl_entropy::Decoder::new(&bytes).map_err(str::to_owned)?;
        for e in events {
            let slot = dec.slot(e.t).map_err(str::to_owned)?;
            if slot < e.c || slot >= e.c + e.f {
                return Err("rANS slot mismatch".into());
            }
            dec.consume(e.c, e.f, e.t).map_err(str::to_owned)?;
        }
        dec.finish().map_err(str::to_owned)?;
        cases += 1;
    }
    if reference(&sequences[1]) != [0, 165, 0, 128, 0, 0] {
        return Err("known single escape".into());
    }
    let mut enc = new::mdl_entropy::Encoder::with_limit(16).map_err(str::to_owned)?;
    for (c, f, t) in [
        (0, 0, 256),
        (256, 1, 256),
        (u32::MAX, 1, 256),
        (0, 1, 0),
        (0, 1, 1),
        (0, 1, 81920),
        (0, 32769, 32768),
    ] {
        if enc.interval(c, f, t).is_ok() {
            return Err("invalid interval accepted".into());
        }
        rejects += 1;
    }
    if enc.event_count() != 0 || enc.finish().map_err(str::to_owned)? != [0, 0, 0, 128, 0] {
        return Err("invalid encoder committed".into());
    }
    for state in [0u32, (1 << 23) - 1, 1 << 31, u32::MAX] {
        let mut bytes = vec![0];
        bytes.extend_from_slice(&state.to_le_bytes());
        if new::mdl_entropy::Decoder::new(&bytes).is_ok() {
            return Err("bad rANS state".into());
        }
        rejects += 1;
    }
    for end in 0..5 {
        if new::mdl_entropy::Decoder::new(&[0, 0, 0, 128, 0][..end]).is_ok() {
            return Err("short prefix".into());
        }
        rejects += 1;
    }
    let mut enc = new::mdl_entropy::Encoder::with_limit(32).map_err(str::to_owned)?;
    enc.interval(165, 1, 32768).map_err(str::to_owned)?;
    let bytes = enc.finish().map_err(str::to_owned)?;
    let mut dec = new::mdl_entropy::Decoder::new(&bytes).map_err(str::to_owned)?;
    let slot = dec.slot(32768).map_err(str::to_owned)?;
    if dec.slot(81920).is_ok()
        || dec.consume(0, 1, 32768).is_ok()
        || dec.consume(0, 0, 32768).is_ok()
        || dec.slot(32768).map_err(str::to_owned)? != slot
    {
        return Err("decoder error committed".into());
    }
    rejects += 3;
    dec.consume(165, 1, 32768).map_err(str::to_owned)?;
    dec.finish().map_err(str::to_owned)?;
    let cut = &bytes[..bytes.len() - 1];
    let mut dec = new::mdl_entropy::Decoder::new(cut).map_err(str::to_owned)?;
    for _ in 0..2 {
        if dec.consume(165, 1, 32768).is_ok() || dec.slot(32768).map_err(str::to_owned)? != slot {
            return Err("truncated decoder commit".into());
        }
        rejects += 1;
    }
    let mut extra = bytes.clone();
    extra.push(0);
    let mut dec = new::mdl_entropy::Decoder::new(&extra).map_err(str::to_owned)?;
    dec.consume(165, 1, 32768).map_err(str::to_owned)?;
    if dec.finish().is_ok() {
        return Err("trailing rANS byte".into());
    }
    rejects += 1;
    let state = [0, 1, 0, 128, 0];
    if new::mdl_entropy::Decoder::new(&state)
        .map_err(str::to_owned)?
        .finish()
        .is_ok()
    {
        return Err("noncanonical terminal".into());
    }
    rejects += 1;
    let mut enc = new::mdl_entropy::Encoder::with_limit(4).map_err(str::to_owned)?;
    enc.interval(0, 32768, 32768).map_err(str::to_owned)?;
    if enc.finish() != Err("range output limit") {
        return Err("small output limit".into());
    }
    rejects += 1;
    let mut enc = new::mdl_entropy::Encoder::with_limit(5).map_err(str::to_owned)?;
    for _ in 0..new::mdl_entropy::MAX_EVENTS {
        enc.interval(0, 32768, 32768).map_err(str::to_owned)?;
    }
    if enc.event_count() != new::mdl_entropy::MAX_EVENTS
        || enc.capacity_bytes() > 12582912
        || enc.transient_bytes() > 6291456
        || enc.interval(0, 32768, 32768) != Err("ANS journal limit")
    {
        return Err("journal bound".into());
    }
    rejects += 1;
    if enc.finish().map_err(str::to_owned)? != [0, 0, 0, 128, 0] {
        return Err("bounded full journal".into());
    }
    Ok((cases, rejects))
}
struct Snapshot {
    method: u8,
    frame: usize,
    metadata: usize,
    branches: usize,
    phase: usize,
    journal: usize,
    events: usize,
    transient: usize,
}
fn encoded(raw: &[u8], candidate: bool) -> Result<(Vec<u8>, Snapshot), String> {
    if candidate {
        let (frame, s) = new::encode_hybrid(raw, true)?;
        Ok((
            frame,
            Snapshot {
                method: s.method,
                frame: s.frame,
                metadata: s.metadata,
                branches: s.branches,
                phase: s.phase_capacity_bound,
                journal: s.journal_capacity,
                events: s.journal_events,
                transient: s.journal_transient,
            },
        ))
    } else {
        let (frame, s) = old::encode_hybrid(raw, true)?;
        Ok((
            frame,
            Snapshot {
                method: s.method,
                frame: s.frame,
                metadata: s.metadata,
                branches: s.branches,
                phase: s.phase_capacity_bound,
                journal: 0,
                events: 0,
                transient: 0,
            },
        ))
    }
}
fn roundtrip(raw: &[u8], before: &[u8], after: &[u8]) -> Result<(), String> {
    if old::decode(before)?.0 != raw
        || new::decode(after)?.0 != raw
        || unlhare::khc::decompress_block(before).map_err(|e| e.to_string())? != raw
    {
        return Err("self/public byte mismatch".into());
    }
    if old::decode(after).is_ok()
        || new::decode(before).is_ok()
        || unlhare::khc::decompress_block(after).is_ok()
    {
        return Err("cross-format accepted".into());
    }
    if before[10] == 1 && after[10] == 1 {
        let a = u16::from_le_bytes(before[28..30].try_into().map_err(|_| "alphabet")?) as usize * 2;
        let m = u32::from_le_bytes(before[20..24].try_into().map_err(|_| "metadata")?) as usize;
        if before[20..24] != after[20..24]
            || before[28..30] != after[28..30]
            || before.get(40..40 + a + m) != after.get(40..40 + a + m)
        {
            return Err("MDL metadata changed".into());
        }
    } else if before[10] != 1 && after[10] == before[10] {
        let mut normalized = after.to_vec();
        normalized[..8].copy_from_slice(old::MAGIC);
        old::reseal(&mut normalized)?;
        if normalized != before {
            return Err("nonMDL frame changed".into());
        }
    }
    Ok(())
}
fn malformed(raw: &[u8], frame: &[u8]) -> Result<(usize, usize), String> {
    let mut cases = 0;
    let mut rejects = 0;
    let mut check = |bytes: &[u8]| -> Result<(), String> {
        match new::decode(bytes) {
            Ok((plain, _)) if plain == raw => {}
            Ok(_) => return Err("malformed wrong byte accepted".into()),
            Err(_) => rejects += 1,
        }
        cases += 1;
        if new::decode(frame)?.0 != raw {
            return Err("error recovery".into());
        }
        Ok(())
    };
    for end in 0..40 {
        check(&frame[..end])?;
    }
    for at in 0..40 {
        let mut bad = frame.to_vec();
        bad[at] ^= 128;
        new::reseal(&mut bad)?;
        check(&bad)?;
    }
    for i in 0..16 {
        let end = 40 + (frame.len() - 40) * i / 16;
        check(&frame[..end])?;
    }
    if frame.len() > 40 {
        for i in 0..16 {
            let mut bad = frame.to_vec();
            let at = 40 + (frame.len() - 41) * i / 15;
            bad[at] ^= 1;
            new::reseal(&mut bad)?;
            check(&bad)?;
        }
    }
    Ok((cases, rejects))
}
fn finite_contract() -> Result<(), String> {
    let (coder_cases, coder_rejections) = coder_contract()?;
    let mut cases = Vec::new();
    for length in [0, 1, 2, 15, 127, 249, 250, 251, 256, 257, 511, 4096] {
        cases.push(vec![b'a'; length]);
        cases.push((0..length).map(|i| (i % 256) as u8).collect());
    }
    cases.push(b"integer grammar: abcd abcd abcde abcdef abcdefgh\n".repeat(128));
    cases.push(vec![0; 65536]);
    let mut state = 0x71349a2fu32;
    cases.push(
        (0..4096)
            .map(|_| {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                (state >> 24) as u8
            })
            .collect(),
    );
    let mut malformed_cases = 0;
    let mut rejected = 0;
    let mut mdl = 0;
    for raw in &cases {
        let (before, _) = encoded(raw, false)?;
        let (after, s) = encoded(raw, true)?;
        roundtrip(raw, &before, &after)?;
        let (n, r) = malformed(raw, &after)?;
        malformed_cases += n;
        rejected += r;
        mdl += usize::from(s.method == 1);
        if s.phase > 64 * 1024 * 1024 || s.journal > 12582912 || s.transient > 6291456 {
            return Err("finite capacity".into());
        }
    }
    println!(
        "{{\"byte_exact\":true,\"coder_sequences\":{coder_cases},\"coder_rejections\":{coder_rejections},\"finite_raw_cases\":{},\"finite_MDL\":{mdl},\"malformed_cases\":{malformed_cases},\"rejected\":{rejected},\"journal_limit_events\":2097152}}",
        cases.len()
    );
    Ok(())
}
fn execute() -> Result<(), String> {
    let arg = std::env::args().nth(1).ok_or("input")?;
    if arg == "--contract" {
        return finite_contract();
    }
    let reversed = std::env::args().nth(2).as_deref() == Some("--reverse");
    let mut raw = Vec::new();
    raw.try_reserve_exact(old::MAX_INPUT + 1)
        .map_err(|_| "input allocation")?;
    match arg.as_str() {
        "--empty" => {}
        "--one" => raw.push(165),
        _ => {
            File::open(arg)
                .map_err(|e| e.to_string())?
                .take((old::MAX_INPUT + 1) as u64)
                .read_to_end(&mut raw)
                .map_err(|e| e.to_string())?;
        }
    }
    if raw.len() > old::MAX_INPUT {
        return Err("input bound".into());
    }
    let (before, old_stats) = encoded(&raw, false)?;
    let (after, new_stats) = encoded(&raw, true)?;
    roundtrip(&raw, &before, &after)?;
    let mut old_encode = [0u128; 9];
    let mut new_encode = [0u128; 9];
    let mut old_decode = [0u128; 9];
    let mut new_decode = [0u128; 9];
    for round in 0..9 {
        let order = if (round % 2 == 0) ^ reversed {
            [false, true]
        } else {
            [true, false]
        };
        for candidate in order {
            let started = Instant::now();
            let (frame, s) = encoded(&raw, candidate)?;
            let ns = started.elapsed().as_nanos();
            let reference = if candidate { &after } else { &before };
            if &frame != reference {
                return Err("encoder nondeterministic".into());
            }
            if candidate {
                new_encode[round] = ns;
            } else {
                old_encode[round] = ns;
            }
            if s.phase > 67108864 {
                return Err("encode phase bound".into());
            }
            let started = Instant::now();
            let plain = if candidate {
                new::decode(&frame)?.0
            } else {
                old::decode(&frame)?.0
            };
            let ns = started.elapsed().as_nanos();
            if candidate {
                new_decode[round] = ns;
            } else {
                old_decode[round] = ns;
            }
            if plain != raw {
                return Err("measured decode mismatch".into());
            }
        }
    }
    let (cases, rejected) = malformed(&raw, &after)?;
    println!(
        "{{\"byte_exact\":true,\"raw_bytes\":{},\"old_bytes\":{},\"new_bytes\":{},\"old_method\":{},\"new_method\":{},\"old_metadata\":{},\"new_metadata\":{},\"old_branches\":{},\"new_branches\":{},\"old_encode_ns\":{:?},\"new_encode_ns\":{:?},\"old_decode_ns\":{:?},\"new_decode_ns\":{:?},\"old_phase_capacity\":{},\"new_phase_capacity\":{},\"journal_capacity\":{},\"journal_events\":{},\"journal_transient\":{},\"malformed_cases\":{},\"rejected\":{},\"reversed\":{}}}",
        raw.len(),
        old_stats.frame,
        new_stats.frame,
        old_stats.method,
        new_stats.method,
        old_stats.metadata,
        new_stats.metadata,
        old_stats.branches,
        new_stats.branches,
        old_encode,
        new_encode,
        old_decode,
        new_decode,
        old_stats.phase,
        new_stats.phase,
        new_stats.journal,
        new_stats.events,
        new_stats.transient,
        cases,
        rejected,
        reversed
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("mdl_rans_compare: {error}");
        std::process::exit(1);
    }
}
