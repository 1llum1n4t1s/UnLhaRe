//! 全置換n<=8でvisitedとprimary帰還の拒否時点を逐次照合する。
fn audit(next: &[usize], cases: &mut u64, steps: &mut u64, short: &mut u64) {
    for primary in 0..next.len() {
        let mut visited = [false; 8];
        let mut row = primary;
        let mut ended = false;
        for step in 0..next.len() {
            let old_reject = visited[row];
            let new_reject = step > 0 && row == primary;
            assert_eq!(old_reject, new_reject, "{next:?}/{primary}/{step}");
            *steps += 1;
            if old_reject {
                *short += 1;
                ended = true;
                break;
            }
            visited[row] = true;
            row = next[row];
        }
        if !ended {
            assert_eq!(row, primary, "terminal {next:?}/{primary}");
        }
        *cases += 1;
    }
}
fn enumerate(next: &mut [usize], at: usize, cases: &mut u64, steps: &mut u64, short: &mut u64) {
    if at == next.len() {
        audit(next, cases, steps, short);
        return;
    }
    for other in at..next.len() {
        next.swap(at, other);
        enumerate(next, at + 1, cases, steps, short);
        next.swap(at, other);
    }
}
fn main() {
    let mut cases = 0;
    let mut steps = 0;
    let mut short = 0;
    for n in 1..=8 {
        let mut next = [0usize; 8];
        for (i, value) in next.iter_mut().enumerate() {
            *value = i;
        }
        enumerate(&mut next[..n], 0, &mut cases, &mut steps, &mut short);
    }
    println!(
        "permutation_primary_cases={cases}; compared_steps={steps}; short_cycle_rejections={short}; exact=true"
    );
}
