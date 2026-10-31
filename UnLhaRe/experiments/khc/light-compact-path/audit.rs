//! 全履歴のheap mappingと旧・新lightモデルの状態を逐次比較するCLI。
#![allow(dead_code)]
#[path = "old_audit.rs"]
mod old;
#[path = "light.rs"]
mod compact;
type Result<T> = std::result::Result<T, String>;
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length).map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}
fn require(ok: bool, message: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(message.into()) }
}
fn fingerprint(hash: &mut u64, value: u64) {
    for byte in value.to_le_bytes() {
        *hash = (*hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3);
    }
}
fn next(seed: &mut u64) -> u64 {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    *seed
}
fn same_error(a: Option<String>, b: Option<String>, expected: &str) -> Result<()> {
    require(a.as_deref() == Some(expected) && b.as_deref() == Some(expected), "error differs")
}
fn run() -> Result<()> {
    let mut hash = 0xcbf2_9ce4_8422_2325;
    let mut mappings = 0;
    for history in 0..=u16::MAX {
        let reversed = u32::from(history.reverse_bits());
        for depth in 0..=16 {
            let expected = ((1_usize << depth) - 1) + (reversed >> (16 - depth)) as usize;
            let prior = old::audit_index(history, depth)?;
            let current = compact::audit_index(history, depth)?;
            require(prior == expected && current == expected && current < 131071, "heap mapping differs")?;
            fingerprint(&mut hash, u64::from(history));
            fingerprint(&mut hash, depth as u64);
            fingerprint(&mut hash, current as u64);
            mappings += 1;
        }
    }
    for bad in [17, usize::MAX] {
        same_error(old::audit_index(0, bad).err(), compact::audit_index(0, bad).err(), "suffix level outside bounds")?;
    }
    let (old_prediction, old_node) = old::Model::audit_layout();
    let (new_prediction, new_node) = compact::Model::audit_layout();
    require(old_node == 8 && new_node == 8 && new_prediction < old_prediction, "compact layout did not shrink")?;
    let mut previous = old::Model::new()?;
    let mut current = compact::Model::new()?;
    let mut seed = 0x243f_6a88_85a3_08d3;
    let events = 131072;
    let mut classes = [0_u64; 7];
    let mut selected = [0_u64; 17];
    for record in 0..events {
        let random = next(&mut seed);
        let class = if record < 8192 { record % 7 } else { (record / 8192) % 7 } as u32;
        let bit = match (record / 8192) % 4 {
            0 => false,
            1 => true,
            2 => record % 2 != 0,
            _ => random & 1 != 0,
        };
        require(previous.predict(class)?.zero() == current.predict(class)?.zero(), "Q15 prediction differs")?;
        let prior = previous.audit_step(class, bit)?;
        let state = current.audit_step(class, bit)?;
        require(prior == state, "Q32/expert/count/history state differs")?;
        require(state[71] <= 16, "selected depth outside bounds")?;
        selected[state[71] as usize] += 1;
        classes[class as usize] += 1;
        fingerprint(&mut hash, u64::from(class));
        fingerprint(&mut hash, u64::from(bit));
        for value in state { fingerprint(&mut hash, value); }
    }
    require(classes.iter().all(|&count| count > 0) && selected[0] > 0 && selected[16] > 0, "class/expert coverage incomplete")?;
    for class in [7, u32::MAX] {
        same_error(previous.predict(class).err(), current.predict(class).err(), "suffix class outside bounds")?;
    }
    let old_prediction_first = previous.predict(0)?;
    let new_prediction_first = current.predict(0)?;
    let old_prediction_stale = previous.predict(0)?;
    let new_prediction_stale = current.predict(0)?;
    previous.update(0, &old_prediction_first, true)?;
    current.update(0, &new_prediction_first, true)?;
    let before_old = previous.audit_snapshot(0)?;
    let before_new = current.audit_snapshot(0)?;
    require(before_old == before_new, "state before stale refusal")?;
    same_error(previous.update(0, &old_prediction_stale, false).err(), current.update(0, &new_prediction_stale, false).err(), "suffix stale prediction")?;
    require(previous.audit_snapshot(0)? == before_old && current.audit_snapshot(0)? == before_new, "stale refusal changed path state")?;
    let old_prediction_class = previous.predict(0)?;
    let new_prediction_class = current.predict(0)?;
    same_error(previous.update(1, &old_prediction_class, false).err(), current.update(1, &new_prediction_class, false).err(), "suffix prediction class mismatch")?;
    require(previous.audit_snapshot(0)? == before_old && current.audit_snapshot(0)? == before_new, "class mismatch changed path state")?;
    require(previous.audit_step(0, false)? == current.audit_step(0, false)?, "post-refusal continuation differs")?;

    let mut cap_old = old::Model::new()?;
    let mut cap_new = compact::Model::new()?;
    cap_old.audit_set_class_cap(0)?;
    cap_new.audit_set_class_cap(0)?;
    let cap_old_before = cap_old.audit_snapshot(0)?;
    let cap_new_before = cap_new.audit_snapshot(0)?;
    require(cap_old_before == cap_new_before, "injected cap state differs")?;
    let old_cap_prediction = cap_old.predict(0)?;
    let new_cap_prediction = cap_new.predict(0)?;
    same_error(cap_old.update(0, &old_cap_prediction, true).err(), cap_new.update(0, &new_cap_prediction, true).err(), "suffix class observation cap exceeded")?;
    require(cap_old.audit_snapshot(0)? == cap_old_before && cap_new.audit_snapshot(0)? == cap_new_before, "cap refusal changed path state")?;
    require(cap_old.audit_step(1, true)? == cap_new.audit_step(1, true)?, "cap refusal affected other class")?;
    println!("{{\"status\":\"light_compact_path_state_verified_not_codec_or_timing\",\"mapping_records\":{mappings},\"invalid_depth_cases\":2,\"state_events\":{events},\"values_per_event\":72,\"invalid_class_cases\":2,\"stale_cases\":1,\"class_mismatch_cases\":1,\"injected_cap_cases\":1,\"rollback_checks\":3,\"continuation_events\":2,\"classes\":{classes:?},\"selected_depths\":{selected:?},\"old_prediction_bytes\":{old_prediction},\"new_prediction_bytes\":{new_prediction},\"old_node_bytes\":{old_node},\"new_node_bytes\":{new_node},\"fingerprint_u64\":\"{hash:016x}\"}}");
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
