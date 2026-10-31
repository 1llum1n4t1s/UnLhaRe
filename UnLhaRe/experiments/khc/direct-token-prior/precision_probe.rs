#[path = "../direct-token/cdf_model.rs"]
mod original;
mod cdf_model;
mod prior_math;

fn main() {
    if std::env::args().len() != 1 { eprintln!("no arguments"); std::process::exit(2); }
    let mut old = original::ContextModel::new(256, 2).unwrap();
    let mut new = cdf_model::ContextModel::new(256, 2).unwrap();
    for _ in 0..8192 { old.update(0, 0).unwrap(); new.update(0, 0).unwrap(); }
    let mut counts_checked = 0;
    for key in [None, Some(0), Some(1)] {
        for token in 0..256 {
            let expected = match key {
                None => if token == 0 { 8193 } else { 1 },
                Some(0) => if token == 0 { 8192 } else { 0 },
                _ => 0,
            };
            assert_eq!(old.audit_counts(key).unwrap()[token], expected);
            assert_eq!(new.audit_counts(key).unwrap()[token], expected);
            counts_checked += 2;
        }
    }
    assert_eq!(old.audit_rescales(), (0, 0)); assert_eq!(new.audit_rescales(), (0, 0));
    let cold_old = old.interval(1, 0, 256).unwrap();
    let cold_new = new.interval(1, 0, 256).unwrap();
    let hot_old = old.interval(0, 0, 256).unwrap();
    let hot_new = new.interval(0, 0, 256).unwrap();
    assert_eq!(cold_old, (0, 8193, 8448)); assert_eq!(cold_new, (0, 249, 512));
    assert_eq!(hot_old, (0, 40961, 41216)); assert_eq!(hot_new, (0, 33017, 33280));
    let mut intervals_checked = 0;
    for key in 0..2 {
        let local_total = if key == 0 { 8192u32 } else { 0 };
        let mut root_prefix = 0u32;
        let mut local_prefix = 0u32;
        for token in 0..256 {
            let root_count = if token == 0 { 8193u32 } else { 1 };
            let local_count = if key == 0 && token == 0 { 8192u32 } else { 0 };
            let old_expected = (root_prefix + 4 * local_prefix, root_count + 4 * local_count, 8448 + 4 * local_total);
            let new_prefix = token as u32 + 4 * local_prefix + (256 * u128::from(root_prefix) / 8448) as u32;
            let new_end = token as u32 + 1 + 4 * (local_prefix + local_count)
                + (256 * u128::from(root_prefix + root_count) / 8448) as u32;
            let new_expected = (new_prefix, new_end - new_prefix, 512 + 4 * local_total);
            assert_eq!(old.interval(key, token, 256).unwrap(), old_expected);
            assert_eq!(new.interval(key, token, 256).unwrap(), new_expected);
            root_prefix += root_count; local_prefix += local_count; intervals_checked += 2;
        }
    }
    let before = new.audit_counts(None).unwrap().to_vec();
    assert!(new.update(2, 0).is_err()); assert!(new.update(0, 256).is_err());
    assert_eq!(new.audit_counts(None).unwrap(), before);
    assert_eq!(new.interval(1, 0, 256).unwrap(), cold_new);
    println!("{{\"status\":\"passed\",\"updates_per_model\":8192,\"counts_checked\":{counts_checked},\"intervals_checked\":{intervals_checked},\"cold_old\":[0,8193,8448],\"cold_new\":[0,249,512],\"hot_old\":[0,40961,41216],\"hot_new\":[0,33017,33280],\"cold_uniform_mass\":256,\"cold_total_mass\":512}}");
}
