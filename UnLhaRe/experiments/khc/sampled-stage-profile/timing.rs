//! 標本タイマー。正式速度評価には使用しない。
use std::cell::RefCell;
use std::time::Instant;
#[derive(Clone, Copy)]
#[repr(usize)]
pub(crate) enum Span {
    Bwt, InverseBwt, EntropyEncode, EntropyDecode,
    LightInit, HeavyInit, LightPredict, LightUpdate, HeavyPredict, HeavyUpdate,
}
const MASK: u64 = 1023;
const SALT: u64 = 0x9e37_79b9_7f4a_7c15;
#[derive(Clone, Copy)]
struct Stat { calls: u64, samples: u64, sum_ns: u64, min_ns: u64, max_ns: u64, buckets: [u64; 65] }
const EMPTY: Stat = Stat { calls: 0, samples: 0, sum_ns: 0, min_ns: u64::MAX, max_ns: 0, buckets: [0; 65] };
std::thread_local! { static STATS: RefCell<[Stat; 10]> = const { RefCell::new([EMPTY; 10]) }; }
#[inline(always)]
fn mix(mut value: u64) -> u64 {
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^ (value >> 31)
}
pub(crate) struct Timer { span: Span, began: Option<Instant> }
impl Timer {
    #[inline(always)]
    pub(crate) fn start(span: Span) -> Self {
        let index = span as usize;
        let sample = STATS.with(|stats| {
            let mut stats = stats.borrow_mut();
            let stat = &mut stats[index];
            stat.calls = stat.calls.checked_add(1).expect("profile call count overflow");
            index < 6 || (mix(stat.calls.wrapping_add(SALT.wrapping_mul(index as u64 + 1))) & MASK) == 0
        });
        Self { span, began: if sample { Some(Instant::now()) } else { None } }
    }
}
impl Drop for Timer {
    #[inline(always)]
    fn drop(&mut self) {
        if let Some(began) = self.began {
            let elapsed = u64::try_from(began.elapsed().as_nanos()).expect("profile elapsed overflow");
            STATS.with(|stats| {
                let mut stats = stats.borrow_mut();
                let stat = &mut stats[self.span as usize];
                stat.samples = stat.samples.checked_add(1).expect("profile sample count overflow");
                stat.sum_ns = stat.sum_ns.checked_add(elapsed).expect("profile duration sum overflow");
                stat.min_ns = stat.min_ns.min(elapsed);
                stat.max_ns = stat.max_ns.max(elapsed);
                let bucket = (64 - elapsed.leading_zeros()) as usize;
                stat.buckets[bucket] = stat.buckets[bucket].checked_add(1).expect("profile bucket count overflow");
            });
        }
    }
}
pub(crate) fn json() -> String {
    let labels = ["bwt", "inverse_bwt", "entropy_encode", "entropy_decode", "light_init", "heavy_init",
        "light_predict", "light_update", "heavy_predict", "heavy_update"];
    STATS.with(|stats| {
        let stats = stats.borrow();
        let mut output = format!("{{\"kind\":\"sampled_stage_diagnostic_not_formal_performance\",\"sampling_mask\":{MASK},\"salt_u64_hex\":\"{SALT:016x}\",\"nested_spans_overlap\":true,\"spans\":[");
        for (index, (name, stat)) in labels.iter().zip(stats.iter()).enumerate() {
            if index != 0 { output.push(','); }
            let min = if stat.samples == 0 { 0 } else { stat.min_ns };
            output.push_str(&format!("{{\"name\":\"{name}\",\"calls\":{},\"samples\":{},\"sample_sum_ns\":{},\"sample_min_ns\":{min},\"sample_max_ns\":{},\"log2_ns_buckets\":{:?}}}",
                stat.calls, stat.samples, stat.sum_ns, stat.max_ns, stat.buckets));
        }
        output.push_str("]}");
        output
    })
}
