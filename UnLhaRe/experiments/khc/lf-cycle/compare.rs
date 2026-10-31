//! 現行inverseと局所候補の有限全域比較。製品経路は変更しない。
#![allow(dead_code)]
type Result<T> = std::result::Result<T, String>;
const MAX_INPUT: usize = 1 << 20;
fn allocate<T: Clone>(n: usize, value: T) -> Result<Vec<T>> {
    let mut out = Vec::new();
    out.try_reserve_exact(n).map_err(|_| "allocation failed")?;
    out.resize(n, value);
    Ok(out)
}
mod candidate;
#[path = "../../../src/khc/block/packed.rs"]
mod original;
fn check(
    last: &[u16],
    primary: usize,
    alphabet: &[u16],
    ok: &mut u64,
    reject: &mut u64,
) -> Result<()> {
    let a = original::inverse(last, primary, alphabet);
    let b = candidate::inverse(last, primary, alphabet);
    match (a, b) {
        (Ok(a), Ok(b))
            if a.plain == b.plain
                && a.route == b.route
                && a.scratch_capacity_words == b.scratch_capacity_words
                && a.result_capacity == b.result_capacity =>
        {
            *ok += 1;
            Ok(())
        }
        (Err(a), Err(b)) if a == b => {
            *reject += 1;
            Ok(())
        }
        _ => Err(format!(
            "inverse mismatch: n={}, primary={primary}, alphabet={alphabet:?}, last_prefix={:?}",
            last.len(),
            &last[..last.len().min(8)]
        )),
    }
}
fn main() -> Result<()> {
    let mut ok = 0;
    let mut reject = 0;
    let symbols = [0u16, 1, 256];
    for n in 1..=8 {
        let mut last = [0u16; 8];
        for mut digits in 0..3usize.pow(n as u32) {
            for value in &mut last[..n] {
                *value = symbols[digits % 3];
                digits /= 3;
            }
            let alphabet: Vec<_> = symbols
                .into_iter()
                .filter(|s| last[..n].contains(s))
                .collect();
            for primary in 0..=n {
                check(&last[..n], primary, &alphabet, &mut ok, &mut reject)?;
                check(
                    &last[..n],
                    primary,
                    &alphabet[..alphabet.len().saturating_sub(1)],
                    &mut ok,
                    &mut reject,
                )?;
            }
        }
    }
    for (last, alphabet) in [
        (&[][..], &[][..]),
        (&[0, 257][..], &[0, 1][..]),
        (&[0][..], &[257][..]),
    ] {
        check(last, 0, alphabet, &mut ok, &mut reject)?;
    }
    let mut maximum = vec![1u16; MAX_INPUT + 1];
    maximum[MAX_INPUT] = 0;
    check(&maximum, MAX_INPUT, &[0, 1], &mut ok, &mut reject)?;
    maximum.push(1);
    check(&maximum, MAX_INPUT, &[0, 1], &mut ok, &mut reject)?;
    println!(
        "same_output={ok}; same_rejection={reject}; exact=true; max_valid_raw={MAX_INPUT}; raw_disk_files=0"
    );
    Ok(())
}
