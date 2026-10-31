// 先行15fixtureの独立standalone E2E入口。親harnessからrun()を一度呼ぶ。
// 合成帳簿oracleであり、実codec/実elapsed/公開入力到達性の検証ではない。
use crate::profile as p;
use p::{Direction, Fault};
type Result<T> = std::result::Result<T, String>;
fn need(ok: bool, what: &str) -> Result<()> { if ok { Ok(()) } else { Err(what.into()) } }
fn setup() {
    p::audit_clear(); p::audit_clock(10, 1, 5, false); p::reset(true, Direction::Encode);
}
fn clean() -> Result<()> {
    let r = p::snapshot();
    need(!r.pending_branch && !r.pending_stage && !r.pending_whole, "pending scope")
}
fn fault(want: Fault) -> Result<()> { need(p::snapshot().first_fault == Some(want), "first fault") }
fn operation(id: usize) -> std::result::Result<usize, &'static str> { p::stage(id, || Ok(id)) }
fn normal(c: usize, k: usize) -> Result<bool> {
    let mut b = p::branch(c, k); let sampled = b.sampled();
    for id in 0..4 { need(operation(id) == Ok(id), "operation return")?; }
    b.commit(); Ok(sampled)
}
fn successful_bucket(b: p::Bucket, attempts: u64, pairs: u64, ns: u128) -> bool {
    b.attempts == attempts && b.success == attempts && b.error == 0 &&
    b.timer_starts == pairs && b.timer_ends == pairs && b.timer_pairs == pairs && b.ns == ns
}
fn core() -> Result<()> {
    setup();
    for c in 0..2 { for k in 1..=4 { for ordinal in 1..=385 {
        need(normal(c, k)? == (ordinal == 128 || ordinal == 384), "ordinal128/384")?;
    } } }
    need(p::validate() == Ok(()), "core validate")?;
    let r = p::snapshot(); need(r.synthetic && r.state_bytes <= p::STATE_LIMIT, "state bound")?;
    for row in r.strata {
        need(row.samples == 2 && successful_bucket(row.branch, 385, 2, 20), "branch385")?;
        for child in row.child { need(successful_bucket(child, 385, 2, 2), "four child385")?; }
        let sum = row.child.iter().try_fold(0u128, |n, b| n.checked_add(b.ns)).ok_or("oracle sum")?;
        need(row.branch.ns.checked_sub(sum) == Some(12), "residual12")?;
    }
    clean()
}
fn disabled_reset_whole() -> Result<()> {
    setup(); p::reset(false, Direction::Encode);
    need(!normal(0, 1)?, "disabled sampled")?;
    need(p::whole(0, || Ok::<_, &'static str>(27)) == Ok(27), "disabled whole return")?;
    let r = p::snapshot(); need(r.strata == [p::Stratum::default(); 8] && r.whole == [p::Bucket::default(); 3], "disabled counters")?;
    p::reset(true, Direction::Decode);
    for id in 0..3 { need(p::whole(id, || Ok::<_, &'static str>(id)) == Ok(id), "whole return")?; }
    let r = p::snapshot(); need(r.direction == Direction::Decode, "decode reset")?;
    for b in r.whole { need(successful_bucket(b, 1, 1, 5), "whole5")?; }
    need(p::validate() == Ok(()), "whole validate")?; clean()
}
fn branch_failure() -> Result<()> {
    setup();
    for fail_id in 0..4 {
        let b = p::branch(0, 1);
        for id in 0..fail_id { need(operation(id) == Ok(id), "pre error stage")?; }
        let got = p::stage(fail_id, || Err::<usize, _>("numeric marker"));
        need(got == Err("numeric marker"), "original Err unchanged")?;
        drop(b); clean()?;
    }
    // coder/guardの数値ErrはModel子の外。codec所有scopeの未commit Dropを模す。
    for completed in [2, 3] {
        let b = p::branch(0, 1);
        for id in 0..completed { need(operation(id) == Ok(id), "external error stage")?; }
        let numeric: std::result::Result<(), &str> = Err("outside child");
        need(numeric == Err("outside child"), "outside Err")?;
        drop(b); clean()?;
    }
    normal(0, 1)?;
    let row = p::snapshot().strata[0];
    need(row.branch.attempts == 7 && row.branch.success == 1 && row.branch.error == 6, "abort6 recovery1")?;
    let attempts = [7, 6, 4, 2];
    for id in 0..4 {
        need(row.child[id].attempts == attempts[id] && row.child[id].error == 1 &&
            row.child[id].success == attempts[id] - 1 && row.child[id].timer_pairs == 0, "child error census")?;
    }
    need(p::validate() == Ok(()), "numeric Err no diagnostic fault")?; clean()
}
fn invalid_stratum() -> Result<()> {
    setup(); for (c, k) in [(2, 1), (0, 0), (0, 5)] { drop(p::branch(c, k)); }
    fault(Fault::InvalidStratum)?;
    need(p::snapshot().fault_count == 3 && p::snapshot().strata == [p::Stratum::default(); 8], "invalid strata3")?; clean()
}
fn nested_reset_unfinished() -> Result<()> {
    setup(); let b = p::branch(0, 1); drop(p::branch(1, 1));
    p::reset(false, Direction::Encode); p::reset(true, Direction::Decode);
    // sticky existing faultを返すvalidateと、pending-only拒否を別に確認する。
    need(p::validate() == Err(Fault::NestedBranch), "sticky validate")?;
    need(p::snapshot().fault_count == 3 && p::snapshot().direction == Direction::Encode, "nested/reset3")?;
    drop(b); clean()?;
    setup(); let b = p::branch(0, 1);
    need(p::validate() == Err(Fault::Unfinished), "unfinished validate")?; drop(b); clean()
}
fn stage_contract() -> Result<()> {
    setup(); need(operation(0) == Ok(0), "no scope Result")?; fault(Fault::NoBranch)?;
    setup(); let b = p::branch(0, 1); need(operation(4) == Ok(4), "invalid stage Result")?;
    fault(Fault::InvalidStage)?; drop(b); clean()?;
    setup(); let b = p::branch(0, 1); need(operation(1) == Ok(1), "out of order Result")?;
    fault(Fault::StageOrder)?; drop(b); clean()?;
    setup(); let b = p::branch(0, 1); need(operation(0) == Ok(0), "stage0")?;
    need(operation(0) == Ok(0), "duplicate stage Result")?; fault(Fault::StageOrder)?; drop(b); clean()?;
    setup(); let b = p::branch(0, 1);
    need(p::stage(0, || Err::<(), _>("own Err")) == Err("own Err"), "Err retained")?;
    need(operation(1) == Ok(1), "after error Result")?; fault(Fault::AfterError)?; drop(b); clean()
}
fn repeated_commit() -> Result<()> {
    setup(); let mut b = p::branch(0, 1);
    for id in 0..4 { need(operation(id) == Ok(id), "commit stage")?; }
    b.commit(); b.commit(); fault(Fault::RepeatedCommit)?;
    need(p::snapshot().strata[0].branch.success == 1, "commit only once")?; clean()
}
fn early_commit() -> Result<()> {
    setup(); let mut b = p::branch(0, 1); need(operation(0) == Ok(0), "early stage")?;
    b.commit(); fault(Fault::EarlyCommit)?;
    need(p::snapshot().strata[0].branch.error == 1, "early abort")?; clean()
}
fn whole_contract() -> Result<()> {
    setup(); need(p::whole(3, || Ok::<_, &'static str>(3)) == Ok(3), "invalid whole Result")?;
    fault(Fault::InvalidWhole)?;
    setup(); need(p::whole(0, || p::whole(1, || Ok::<_, &'static str>(9))) == Ok(9), "nested whole Result")?;
    fault(Fault::NestedWhole)?; clean()?;
    setup(); let b = p::branch(0, 1);
    need(p::whole(0, || Err::<(), _>("whole numeric Err")) == Err("whole numeric Err"), "overlap Err unchanged")?;
    fault(Fault::OverlapWhole)?; drop(b); clean()
}
fn counter_overflow() -> Result<()> {
    setup(); p::audit_branch_count(0, u64::MAX); drop(p::branch(0, 1));
    fault(Fault::CounterOverflow)?; need(p::snapshot().strata[0].branch.attempts == u64::MAX, "counter no wrap")?; clean()
}
fn timer_overflow() -> Result<()> {
    setup(); p::audit_branch_count(0, 127); p::audit_child_ns(0, 0, u128::MAX);
    let b = p::branch(0, 1); need(b.sampled(), "timer overflow sample128")?;
    need(operation(0) == Ok(0), "timer overflow Result")?;
    fault(Fault::TimeOverflow)?; drop(b);
    need(p::snapshot().strata[0].child[0].ns == u128::MAX, "time no wrap")?; clean()
}
fn negative_residual() -> Result<()> {
    setup(); p::audit_clock(3, 1, 5, false);
    for _ in 0..128 { normal(0, 1)?; }
    let row = p::snapshot().strata[0];
    let sum = row.child.iter().try_fold(0u128, |n, b| n.checked_add(b.ns)).ok_or("negative sum")?;
    need(row.branch.ns == 3 && sum == 4 && row.branch.ns.checked_sub(sum).is_none(), "negative residual exact")?;
    need(p::validate() == Err(Fault::NegativeResidual), "negative diagnostic")?; clean()
}
fn reversed_clock() -> Result<()> {
    setup(); p::audit_clock(10, 1, 5, true); p::audit_branch_count(0, 127);
    let b = p::branch(0, 1); need(operation(0) == Ok(0), "reversed clock Result")?;
    drop(b); fault(Fault::ReversedClock)?; clean()
}
fn unwind_cleanup() -> Result<()> {
    setup();
    let saved = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let caught = std::panic::catch_unwind(|| {
        let _b = p::branch(0, 1);
        let _: std::result::Result<(), &str> = p::stage(0, || panic!("finite own panic"));
    });
    std::panic::set_hook(saved); // assert/returnより前に元hookを必ず復元。
    need(caught.is_err(), "own panic caught")?;
    let row = p::snapshot().strata[0];
    need(row.branch.error == 1 && row.child[0].error == 1 && row.child[0].attempts == 1, "panic once accounting")?;
    need(p::validate() == Ok(()), "panic cleanup validate")?; clean()
}
fn sticky_reset() -> Result<()> {
    setup(); drop(p::branch(2, 1)); need(operation(0) == Ok(0), "sticky original Result")?;
    p::reset(true, Direction::Decode);
    fault(Fault::InvalidStratum)?;
    need(p::snapshot().fault_count == 2 && p::snapshot().direction == Direction::Decode, "sticky across reset")?;
    clean()
}
pub fn run() -> Result<String> {
    let cases: [fn() -> Result<()>; 15] = [core, disabled_reset_whole, branch_failure, invalid_stratum,
        nested_reset_unfinished, stage_contract, repeated_commit, early_commit, whole_contract,
        counter_overflow, timer_overflow, negative_residual, reversed_clock, unwind_cleanup, sticky_reset];
    for case in cases { case()?; }
    let bytes = p::snapshot().state_bytes;
    p::audit_clear();
    Ok(format!("{{\"status\":\"passed\",\"synthetic_fixtures\":15,\"core_strata\":8,\"core_branches\":3080,\"core_samples\":16,\"core_child_attempts_each\":3080,\"core_child_pairs_each\":16,\"core_parent_ns\":160,\"core_child_ns_each\":16,\"core_residual_ns\":96,\"numeric_error_abort_branches\":6,\"recovery_commits\":1,\"stage_contract_rejections\":5,\"whole_contract_rejections\":3,\"unwind_cases\":1,\"state_bytes\":{bytes},\"actual_codec_cases_executed\":0,\"runtime_clock_claim\":false}}"))
}
