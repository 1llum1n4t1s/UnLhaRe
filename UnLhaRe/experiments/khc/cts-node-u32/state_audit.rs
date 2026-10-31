//! 旧・新モデルを逐次比較する独立CLI。生状態列は保存しない。
#![allow(dead_code)]
#[path = "../causal-compact-simd/cts_model.rs"]
mod old;
#[path = "cts_model.rs"]
mod compact;
type Result<T> = std::result::Result<T, String>;
const Q: u64 = 1 << 32;
const CAP: u32 = 562_036_803;
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut result = Vec::new();
    result.try_reserve_exact(length).map_err(|_| "allocation failed")?;
    result.resize(length, value);
    Ok(result)
}
fn require(ok: bool, message: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(message.into()) }
}
fn next(seed: &mut u64) -> u64 {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    *seed
}
fn fingerprint(hash: &mut u64, value: u64) {
    for byte in value.to_le_bytes() {
        *hash = (*hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3);
    }
}
fn run() -> Result<()> {
    let old_table = old::audit_kt_table()?;
    let new_table = compact::audit_kt_table()?;
    let mut hash = 0xcbf2_9ce4_8422_2325;
    let mut transitions = 0_u64;
    let afters = [1, 2, 3, 7, 15, 255, 65535, 65536, 65537, CAP / 2, CAP - 1, CAP];
    let posteriors = [0, 1, 2, Q / 2 - 1, Q / 2, Q / 2 + 1, Q - 2, Q - 1, Q];
    let mut verify_transition = |after: u32, posterior: u64| -> Result<()> {
        let alpha = Q / (u64::from(after) + 1);
        let retained = Q - 2 * alpha;
        let expected = alpha + ((u128::from(retained) * u128::from(posterior)) / u128::from(Q)) as u64;
        let prior = old::next_weight(&old_table, alpha, retained, posterior)?;
        let current = compact::next_weight(&new_table, alpha, retained, posterior)?;
        require(prior == expected && current == expected, "transition oracle differs")?;
        require(alpha >= 7 && alpha <= Q / 2 && expected >= alpha && expected <= Q - alpha,
            "legal transition bound")?;
        let stored = compact::audit_compact_storage(current)?;
        require(stored == [0, Q / 2, expected], "legal compact storage refused or changed")?;
        fingerprint(&mut hash, u64::from(after));
        fingerprint(&mut hash, posterior);
        fingerprint(&mut hash, expected);
        transitions += 1;
        Ok(())
    };
    for after in afters {
        for posterior in posteriors { verify_transition(after, posterior)?; }
    }
    let mut seed = 0x243f_6a88_85a3_08d3;
    for _ in 0..65536 {
        let after = (next(&mut seed) % u64::from(CAP) + 1) as u32;
        let posterior = next(&mut seed) % (Q + 1);
        verify_transition(after, posterior)?;
    }
    let storage_values = [0, 1, Q / 2, Q - 7, Q - 2, Q - 1, Q, Q + 1, u64::MAX];
    let mut storage_rejections = 0;
    for value in storage_values {
        let actual = compact::audit_compact_storage(value)?;
        let expected = match u32::try_from(value) {
            Ok(v) => [0, Q / 2, u64::from(v)],
            Err(_) => { storage_rejections += 1; [1, Q / 2, Q / 2] },
        };
        require(actual == expected, "checked storage or unchanged-on-error differs")?;
        for item in actual { fingerprint(&mut hash, item); }
    }
    let (old_prediction, old_node) = old::Model::audit_layout();
    let (new_prediction, new_node) = compact::Model::audit_layout();
    require(old_prediction == new_prediction && old_node == 16 && new_node == 12, "layout differs")?;
    let node_count = 7 * ((1_usize << 17) - 1);
    require(node_count == 917497 && (old_node - new_node) * node_count == 3669988, "node savings")?;
    let mut previous = old::Model::new()?;
    let mut current = compact::Model::new()?;
    let events = 131072;
    let mut class_events = [0_u64; 7];
    for record in 0..events {
        let random = next(&mut seed);
        let class = if record < 8192 { record % 7 } else { (record / 8192) % 7 } as u32;
        let bit = match (record / 8192) % 4 {
            0 => false,
            1 => true,
            2 => record % 2 != 0,
            _ => random & 1 != 0,
        };
        require(previous.predict(class)?.zero() == current.predict(class)?.zero(), "prediction differs")?;
        let old_state = previous.audit_step(class, bit)?;
        let new_state = current.audit_step(class, bit)?;
        require(old_state == new_state, "full path state differs")?;
        class_events[class as usize] += 1;
        fingerprint(&mut hash, u64::from(class));
        fingerprint(&mut hash, u64::from(bit));
        for item in new_state { fingerprint(&mut hash, item); }
    }
    let mut refused = 0;
    for class in [7, u32::MAX] {
        let old_error = previous.predict(class).err().ok_or("old invalid class accepted")?;
        let new_error = current.predict(class).err().ok_or("new invalid class accepted")?;
        require(old_error == new_error && old_error == "CTS class outside bounds", "invalid class error differs")?;
        let old_prediction = previous.predict(0)?;
        let new_prediction = current.predict(0)?;
        let old_error = previous.update(class, &old_prediction, false).err().ok_or("old update class accepted")?;
        let new_error = current.update(class, &new_prediction, false).err().ok_or("new update class accepted")?;
        require(old_error == new_error && old_error == "CTS class outside bounds", "update class error differs")?;
        refused += 2;
    }
    // 拒否後も状態が一致し、次の正常処理を継続できることを確認する。
    require(previous.audit_step(0, true)? == current.audit_step(0, true)?, "post-error state differs")?;
    require(class_events.iter().all(|&count| count > 0), "class coverage incomplete")?;
    println!("{{\"status\":\"node_u32_state_and_bounds_verified_not_timing\",\"transitions\":{transitions},\"storage_cases\":{},\"storage_rejections\":{storage_rejections},\"state_events\":{events},\"path_values_per_event\":85,\"post_error_events\":1,\"invalid_class_refusals\":{refused},\"old_node_bytes\":{old_node},\"new_node_bytes\":{new_node},\"prediction_bytes\":{new_prediction},\"node_count\":{node_count},\"logical_node_bytes\":{},\"saved_node_bytes\":3669988,\"minimum_alpha\":{},\"maximum_updated_weight\":{},\"fingerprint_u64\":\"{hash:016x}\"}}",
        storage_values.len(), new_node * node_count, Q / (u64::from(CAP) + 1), Q - 7);
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
