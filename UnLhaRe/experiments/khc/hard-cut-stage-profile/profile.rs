// private診断。数値closureのResultを変えず、TLS借用を呼出しへ持ち越さない。
use std::cell::{Cell, RefCell};
use std::time::Instant;

pub const STRATA: usize = 8;
pub const STAGES: usize = 4;
pub const WHOLES: usize = 3;
pub const STATE_LIMIT: usize = 65536;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction { Encode, Decode }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    InvalidStratum, NestedBranch, ActiveReset, Unfinished, NoBranch, InvalidStage,
    StageOrder, AfterError, RepeatedCommit, EarlyCommit, InvalidWhole, NestedWhole,
    OverlapWhole, CounterOverflow, TimeOverflow, ReversedClock, NegativeResidual,
    BorrowConflict, TokenOverflow,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Bucket {
    pub attempts: u64, pub success: u64, pub error: u64,
    pub timer_starts: u64, pub timer_ends: u64, pub timer_pairs: u64, pub ns: u128,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stratum { pub branch: Bucket, pub samples: u64, pub child: [Bucket; STAGES] }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Report {
    pub enabled: bool, pub direction: Direction, pub strata: [Stratum; STRATA],
    pub whole: [Bucket; WHOLES], pub first_fault: Option<Fault>, pub fault_count: u64,
    pub pending_branch: bool, pub pending_stage: bool, pub pending_whole: bool,
    pub synthetic: bool, pub state_bytes: usize,
}
impl Default for Report {
    fn default() -> Self { Self { enabled: false, direction: Direction::Encode,
        strata: [Stratum::default(); STRATA], whole: [Bucket::default(); WHOLES],
        first_fault: None, fault_count: 0, pending_branch: false, pending_stage: false,
        pending_whole: false, synthetic: false, state_bytes: std::mem::size_of::<State>() } }
}
#[derive(Clone, Copy)]
enum Timer { Real(Instant), Synthetic }
#[derive(Clone, Copy)]
struct Pending { id: usize, timer: Option<Timer> }
#[derive(Clone, Copy)]
struct Active { token: u64, stratum: usize, sampled: bool, timer: Option<Timer>,
    next: usize, failed: bool, pending: Option<Pending> }
#[derive(Clone, Copy)]
struct WholeActive { token: u64, id: usize, timer: Timer }
#[derive(Clone, Copy)]
struct Clock { branch: u128, child: u128, whole: u128, reversed: bool }
struct State {
    enabled: Cell<bool>, direction: Cell<Direction>, generation: Cell<u64>,
    active: Cell<Option<Active>>, whole_active: Cell<Option<WholeActive>>,
    first_fault: Cell<Option<Fault>>, fault_count: Cell<u64>,
    ledger: RefCell<Report>, clock: Cell<Option<Clock>>,
}
const _: () = assert!(std::mem::size_of::<State>() <= STATE_LIMIT);
impl State {
    fn new() -> Self { Self { enabled: Cell::new(false), direction: Cell::new(Direction::Encode),
        generation: Cell::new(0), active: Cell::new(None), whole_active: Cell::new(None),
        first_fault: Cell::new(None), fault_count: Cell::new(0),
        ledger: RefCell::new(Report::default()), clock: Cell::new(None) } }
    fn fault(&self, fault: Fault) {
        if self.first_fault.get().is_none() { self.first_fault.set(Some(fault)); }
        match self.fault_count.get().checked_add(1) {
            Some(n) => self.fault_count.set(n), None => {
                // 飽和はfault件数だけ。時間や負残差は丸めない。
                if self.first_fault.get().is_none() { self.first_fault.set(Some(Fault::CounterOverflow)); }
            }
        }
    }
    fn edit(&self, f: impl FnOnce(&mut Report) -> Result<(), Fault>) -> bool {
        match self.ledger.try_borrow_mut() {
            Ok(mut r) => match f(&mut r) { Ok(()) => true, Err(e) => { self.fault(e); false } },
            Err(_) => { self.fault(Fault::BorrowConflict); false }
        }
    }
    fn token(&self) -> Option<u64> {
        match self.generation.get().checked_add(1) { Some(n) => { self.generation.set(n); Some(n) },
            None => { self.fault(Fault::TokenOverflow); None } }
    }
    fn timer(&self) -> Timer { if self.clock.get().is_some() { Timer::Synthetic } else { Timer::Real(Instant::now()) } }
    fn elapsed(&self, timer: Timer, kind: usize) -> Result<u128, Fault> {
        match timer {
            Timer::Real(start) => Instant::now().checked_duration_since(start)
                .map(|d| d.as_nanos()).ok_or(Fault::ReversedClock),
            Timer::Synthetic => match self.clock.get() {
                Some(c) if !c.reversed => Ok(match kind { 0 => c.branch, 1 => c.child, _ => c.whole }),
                _ => Err(Fault::ReversedClock),
            }
        }
    }
}
thread_local! { static STATE: State = State::new(); }
fn inc(n: u64) -> Result<u64, Fault> { n.checked_add(1).ok_or(Fault::CounterOverflow) }
fn begin_bucket(mut b: Bucket, timed: bool) -> Result<Bucket, Fault> {
    b.attempts = inc(b.attempts)?;
    if timed { b.timer_starts = inc(b.timer_starts)?; }
    Ok(b)
}
fn end_bucket(mut b: Bucket, ok: bool, ns: Option<u128>) -> Result<Bucket, Fault> {
    if ok { b.success = inc(b.success)?; } else { b.error = inc(b.error)?; }
    if let Some(ns) = ns {
        b.timer_ends = inc(b.timer_ends)?; b.timer_pairs = inc(b.timer_pairs)?;
        b.ns = b.ns.checked_add(ns).ok_or(Fault::TimeOverflow)?;
    }
    Ok(b)
}

// 正常resetでもsticky faultを消さない。方向はpendingなしでのみ変えられる。
pub fn reset(enabled: bool, direction: Direction) {
    let _ = STATE.try_with(|s| {
        if s.active.get().is_some() || s.whole_active.get().is_some() { s.fault(Fault::ActiveReset); return; }
        if s.edit(|r| { *r = Report::default(); Ok(()) }) {
            s.enabled.set(enabled); s.direction.set(direction);
        }
    });
}
pub struct Branch { token: u64, inert: bool, done: bool }
pub fn branch(component: usize, prefix: usize) -> Branch {
    let mut out = Branch { token: 0, inert: true, done: false };
    let _ = STATE.try_with(|s| {
        if !s.enabled.get() { return; }
        if component >= 2 || !(1..=4).contains(&prefix) { s.fault(Fault::InvalidStratum); return; }
        if s.active.get().is_some() { s.fault(Fault::NestedBranch); return; }
        if s.whole_active.get().is_some() { s.fault(Fault::OverlapWhole); return; }
        let Some(token) = s.token() else { return; };
        let idx = component * 4 + prefix - 1;
        let mut sampled = false;
        if !s.edit(|r| {
            let mut row = r.strata[idx];
            let ordinal = inc(row.branch.attempts)?;
            sampled = ordinal % 256 == 128;
            row.branch = begin_bucket(row.branch, sampled)?;
            if sampled { row.samples = inc(row.samples)?; }
            r.strata[idx] = row; Ok(())
        }) { return; }
        let timer = if sampled { Some(s.timer()) } else { None };
        s.active.set(Some(Active { token, stratum: idx, sampled, timer, next: 0, failed: false, pending: None }));
        out = Branch { token, inert: false, done: false };
    });
    out
}
impl Branch {
    pub fn sampled(&self) -> bool {
        STATE.try_with(|s| s.active.get().is_some_and(|a| a.token == self.token && a.sampled)).unwrap_or(false)
    }
    pub fn commit(&mut self) {
        if self.inert { return; }
        if self.done { let _ = STATE.try_with(|s| s.fault(Fault::RepeatedCommit)); return; }
        let _ = STATE.try_with(|s| {
            if let Some(a) = s.active.get().filter(|a| a.token == self.token) {
                if a.next != STAGES || a.failed || a.pending.is_some() {
                    s.fault(Fault::EarlyCommit); finish_branch(s, a, false);
                } else { finish_branch(s, a, true); }
            } else { s.fault(Fault::RepeatedCommit); }
        });
        self.done = true;
    }
}
impl Drop for Branch {
    fn drop(&mut self) {
        if self.inert || self.done { return; }
        let _ = STATE.try_with(|s| {
            if let Some(a) = s.active.get().filter(|a| a.token == self.token) { finish_branch(s, a, false); }
        });
        self.done = true;
    }
}
fn finish_branch(s: &State, a: Active, ok: bool) {
    // 先に解除。帳簿faultやunwindでも元operationの制御を壊さない。
    s.active.set(None);
    let ns = match a.timer { Some(t) => match s.elapsed(t, 0) { Ok(n) => Some(n), Err(e) => { s.fault(e); None } }, None => None };
    s.edit(|r| { r.strata[a.stratum].branch = end_bucket(r.strata[a.stratum].branch, ok, ns)?; Ok(()) });
    if a.pending.is_some() { s.fault(Fault::Unfinished); }
}
struct StageGuard { token: u64, id: usize, armed: bool }
fn begin_stage(id: usize) -> StageGuard {
    let mut g = StageGuard { token: 0, id, armed: false };
    let _ = STATE.try_with(|s| {
        if !s.enabled.get() { return; }
        let Some(mut a) = s.active.get() else { s.fault(Fault::NoBranch); return; };
        if id >= STAGES { s.fault(Fault::InvalidStage); return; }
        if a.failed { s.fault(Fault::AfterError); return; }
        if a.pending.is_some() || id != a.next { s.fault(Fault::StageOrder); return; }
        if !s.edit(|r| { r.strata[a.stratum].child[id] = begin_bucket(r.strata[a.stratum].child[id], a.sampled)?; Ok(()) }) {
            a.failed = true; s.active.set(Some(a)); return;
        }
        a.pending = Some(Pending { id, timer: if a.sampled { Some(s.timer()) } else { None } });
        s.active.set(Some(a)); g = StageGuard { token: a.token, id, armed: true };
    });
    g
}
impl StageGuard {
    fn finish(&mut self, ok: bool) {
        if !self.armed { return; }
        self.armed = false;
        let _ = STATE.try_with(|s| {
            let Some(mut a) = s.active.get().filter(|a| a.token == self.token) else { s.fault(Fault::NoBranch); return; };
            let Some(p) = a.pending.filter(|p| p.id == self.id) else { s.fault(Fault::StageOrder); return; };
            a.pending = None; a.next += 1; a.failed |= !ok; s.active.set(Some(a));
            let ns = match p.timer { Some(t) => match s.elapsed(t, 1) { Ok(n) => Some(n), Err(e) => { s.fault(e); None } }, None => None };
            if !s.edit(|r| { r.strata[a.stratum].child[self.id] = end_bucket(r.strata[a.stratum].child[self.id], ok, ns)?; Ok(()) }) {
                a.failed = true; s.active.set(Some(a));
            }
        });
    }
}
impl Drop for StageGuard { fn drop(&mut self) { self.finish(false); } }
pub fn stage<T, E>(id: usize, operation: impl FnOnce() -> Result<T, E>) -> Result<T, E> {
    let mut guard = begin_stage(id);
    let result = operation();
    guard.finish(result.is_ok());
    result
}
struct WholeGuard { token: u64, armed: bool }
impl WholeGuard {
    fn finish(&mut self, ok: bool) {
        if !self.armed { return; } self.armed = false;
        let _ = STATE.try_with(|s| {
            if let Some(a) = s.whole_active.get().filter(|a| a.token == self.token) {
                s.whole_active.set(None);
                let ns = match s.elapsed(a.timer, 2) { Ok(n) => Some(n), Err(e) => { s.fault(e); None } };
                s.edit(|r| { r.whole[a.id] = end_bucket(r.whole[a.id], ok, ns)?; Ok(()) });
            }
        });
    }
}
impl Drop for WholeGuard { fn drop(&mut self) { self.finish(false); } }
pub fn whole<T, E>(id: usize, operation: impl FnOnce() -> Result<T, E>) -> Result<T, E> {
    let mut guard = WholeGuard { token: 0, armed: false };
    let _ = STATE.try_with(|s| {
        if !s.enabled.get() { return; }
        if id >= WHOLES { s.fault(Fault::InvalidWhole); return; }
        if s.whole_active.get().is_some() { s.fault(Fault::NestedWhole); return; }
        if s.active.get().is_some() { s.fault(Fault::OverlapWhole); return; }
        let Some(token) = s.token() else { return; };
        if !s.edit(|r| { r.whole[id] = begin_bucket(r.whole[id], true)?; Ok(()) }) { return; }
        s.whole_active.set(Some(WholeActive { token, id, timer: s.timer() }));
        guard = WholeGuard { token, armed: true };
    });
    let result = operation(); guard.finish(result.is_ok()); result
}
pub fn snapshot() -> Report {
    STATE.try_with(|s| {
        let mut r = match s.ledger.try_borrow() { Ok(r) => *r, Err(_) => { s.fault(Fault::BorrowConflict); Report::default() } };
        r.enabled = s.enabled.get(); r.direction = s.direction.get();
        r.first_fault = s.first_fault.get(); r.fault_count = s.fault_count.get();
        r.pending_branch = s.active.get().is_some();
        r.pending_stage = s.active.get().is_some_and(|a| a.pending.is_some());
        r.pending_whole = s.whole_active.get().is_some(); r.synthetic = s.clock.get().is_some(); r
    }).unwrap_or_default()
}
pub fn validate() -> Result<(), Fault> {
    let r = snapshot();
    if let Some(f) = r.first_fault { return Err(f); }
    let checked = (|| {
    if r.pending_branch || r.pending_stage || r.pending_whole { return Err(Fault::Unfinished); }
    if r.state_bytes > STATE_LIMIT { return Err(Fault::CounterOverflow); }
    for row in &r.strata {
        for b in std::iter::once(&row.branch).chain(row.child.iter()) {
            if b.success.checked_add(b.error) != Some(b.attempts) || b.timer_starts != b.timer_ends || b.timer_pairs != b.timer_ends {
                return Err(Fault::Unfinished);
            }
        }
        if row.samples != row.branch.timer_pairs { return Err(Fault::Unfinished); }
        for child in &row.child {
            if child.attempts > row.branch.attempts || child.timer_pairs > row.samples { return Err(Fault::Unfinished); }
        }
        let sum = row.child.iter().try_fold(0u128, |n, b| n.checked_add(b.ns)).ok_or(Fault::TimeOverflow)?;
        if sum > row.branch.ns { return Err(Fault::NegativeResidual); }
    }
    for b in r.whole {
        if b.success.checked_add(b.error) != Some(b.attempts) || b.timer_starts != b.timer_ends || b.timer_pairs != b.attempts { return Err(Fault::Unfinished); }
    }
    Ok(())
    })();
    if let Err(f) = checked { let _ = STATE.try_with(|s| s.fault(f)); }
    checked
}
// codec外で一度だけ呼ぶ。校正値はbranch/wholeから引かない。
pub fn empty_clock_pairs() -> Result<u128, Fault> {
    let mut total = 0u128;
    for _ in 0..10000 {
        let start = Instant::now();
        let n = Instant::now().checked_duration_since(start).ok_or(Fault::ReversedClock)?.as_nanos();
        total = total.checked_add(n).ok_or(Fault::TimeOverflow)?;
    }
    Ok(total)
}
// 有限診断oracle専用。通常接続はこれらのseedを呼ばない。
pub(crate) fn audit_clear() { let _ = STATE.try_with(|s| {
        s.active.set(None); s.whole_active.set(None); s.enabled.set(false); s.generation.set(0);
        s.first_fault.set(None); s.fault_count.set(0); s.clock.set(None);
        s.edit(|r| { *r = Report::default(); Ok(()) });
    }); }
pub(crate) fn audit_clock(branch: u128, child: u128, whole: u128, reversed: bool) {
        let _ = STATE.try_with(|s| s.clock.set(Some(Clock { branch, child, whole, reversed })));
    }
pub(crate) fn audit_branch_count(stratum: usize, n: u64) { let _ = STATE.try_with(|s| { s.edit(|r| { r.strata[stratum].branch.attempts = n; Ok(()) }); }); }
pub(crate) fn audit_child_ns(stratum: usize, id: usize, n: u128) { let _ = STATE.try_with(|s| { s.edit(|r| { r.strata[stratum].child[id].ns = n; Ok(()) }); }); }
