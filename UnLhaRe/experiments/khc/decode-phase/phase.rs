//! 派生source専用の粗いinclusive区間。symbol/byte単位の計測や途中ログは行わない。
use std::{
    fmt::Write as _,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};

pub const PHASE_NAMES: [&str; 27] = [
    "archive.whole",
    "archive.open",
    "archive.manifest",
    "archive.parallel_eligibility",
    "archive.parallel_dispatch",
    "archive.read_frame",
    "archive.decompress",
    "archive.file_crc",
    "archive.write",
    "archive.sync_all",
    "archive.publish",
    "archive.close",
    "archive.finish",
    "block.whole",
    "block.header_wire",
    "block.stored_copy",
    "block.lz",
    "block.model_setup",
    "block.entropy_loop",
    "block.inverse",
    "block.raw_crc",
    "spatial.whole",
    "spatial.header_wire",
    "spatial.stored_copy",
    "spatial.model_setup",
    "spatial.token_loop",
    "spatial.raw_crc",
];

#[derive(Clone, Copy)]
struct Counter {
    calls: u64,
    ns: u128,
}

static COUNTERS: Mutex<[Counter; PHASE_NAMES.len()]> =
    Mutex::new([Counter { calls: 0, ns: 0 }; PHASE_NAMES.len()]);
static LOST: AtomicBool = AtomicBool::new(false);

pub struct Guard {
    index: Option<usize>,
    started: Instant,
}

pub fn enter(name: &'static str) -> Guard {
    let started = Instant::now();
    let index = PHASE_NAMES.iter().position(|item| *item == name);
    if index.is_none() {
        LOST.store(true, Ordering::Relaxed);
    }
    Guard { index, started }
}

impl Drop for Guard {
    fn drop(&mut self) {
        let elapsed = self.started.elapsed().as_nanos();
        let Some(index) = self.index else { return };
        let Ok(mut counters) = COUNTERS.lock() else {
            LOST.store(true, Ordering::Relaxed);
            return;
        };
        let counter = &mut counters[index];
        match (
            counter.calls.checked_add(1),
            counter.ns.checked_add(elapsed),
        ) {
            (Some(calls), Some(ns)) => {
                counter.calls = calls;
                counter.ns = ns;
            }
            _ => {
                LOST.store(true, Ordering::Relaxed);
            }
        }
    }
}

/// 全guardのdrop後に一度だけ呼ぶ。inclusive値を足してouterから引いてはならない。
pub fn report_json(outer_total_ns: u128) -> String {
    let counters = match COUNTERS.lock() {
        Ok(counters) => counters,
        Err(poisoned) => {
            LOST.store(true, Ordering::Relaxed);
            poisoned.into_inner()
        }
    };
    let mut phases = String::new();
    for (index, name) in PHASE_NAMES.iter().enumerate() {
        if index != 0 {
            phases.push(',');
        }
        let counter = counters[index];
        let _ = write!(
            phases,
            "{{\"name\":\"{name}\",\"calls\":{},\"ns\":{}}}",
            counter.calls, counter.ns
        );
    }
    format!(
        "{{\"schema\":1,\"purpose\":\"non-comparative-decode-phase-diagnostic\",\"superiority_decision_allowed\":false,\"inclusive\":true,\"aggregation\":\"do not sum inclusive phases; outer total includes unmeasured intervals\",\"unmeasured_scope\":\"routing, allocation, metadata and pipeline internals may be unmeasured; instrumentation adds overhead\",\"outer_total_ns\":{outer_total_ns},\"lost_measurements\":{},\"phases\":[{phases}]}}",
        LOST.load(Ordering::Relaxed)
    )
}
