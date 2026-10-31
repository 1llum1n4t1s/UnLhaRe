//! bench専用。単一スレッドcodecのuser+kernel CPU時間をwall時間と分ける。
//! 取得単位は精度の保証ではなく、短い処理では成功時にも0を返し得る。

use std::time::Instant;

type CpuSample = Result<u64, &'static str>;

pub(crate) struct Measurement {
    pub(crate) wall_ms: f64,
    pub(crate) cpu_ms: Option<f64>,
    pub(crate) cpu_status: &'static str,
}

#[cfg(windows)]
fn cpu_sample() -> CpuSample {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, GetThreadTimes};

    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // 現スレッドの疑似handleと、各々独立した書込可能FILETIMEを渡す。
    // 疑似handleは所有せずCloseHandleしない。失敗時の出力は読まない。
    let ok = unsafe {
        GetThreadTimes(
            GetCurrentThread(),
            &mut creation,
            &mut exit,
            &mut kernel,
            &mut user,
        )
    };
    if ok == 0 {
        return Err("unavailable");
    }
    let ticks =
        |value: FILETIME| (u64::from(value.dwHighDateTime) << 32) | u64::from(value.dwLowDateTime);
    ticks(kernel).checked_add(ticks(user)).ok_or("unavailable")
}

#[cfg(not(windows))]
fn cpu_sample() -> CpuSample {
    Err("unsupported")
}

fn cpu_delta(start: CpuSample, end: CpuSample) -> (Option<f64>, &'static str) {
    match (start, end) {
        (Ok(start), Ok(end)) => match end.checked_sub(start) {
            Some(ticks) => (Some(ticks as f64 / 10_000.0), "ok"),
            None => (None, "non_monotonic"),
        },
        (Err(status), _) | (_, Err(status)) => (None, status),
    }
}

pub(crate) fn measure<T>(action: impl FnOnce() -> T) -> (T, Measurement) {
    let cpu_start = cpu_sample();
    let wall_start = Instant::now();
    let result = action();
    let wall_ms = wall_start.elapsed().as_secs_f64() * 1000.0;
    let (cpu_ms, cpu_status) = cpu_delta(cpu_start, cpu_sample());
    (
        result,
        Measurement {
            wall_ms,
            cpu_ms,
            cpu_status,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_delta_preserves_zero_and_reports_missing_or_invalid_samples() {
        assert_eq!(cpu_delta(Ok(7), Ok(7)), (Some(0.0), "ok"));
        assert_eq!(cpu_delta(Ok(7), Ok(10_007)), (Some(1.0), "ok"));
        assert_eq!(cpu_delta(Ok(8), Ok(7)), (None, "non_monotonic"));
        assert_eq!(cpu_delta(Err("unavailable"), Ok(8)), (None, "unavailable"));
        assert_eq!(cpu_delta(Ok(8), Err("unavailable")), (None, "unavailable"));
        assert_eq!(
            cpu_delta(Err("unsupported"), Err("unsupported")),
            (None, "unsupported")
        );
    }

    #[test]
    fn measure_preserves_action_result_and_native_counter() {
        let mut calls = 0;
        let (value, time) = measure(|| {
            calls += 1;
            Err::<(), _>("expected")
        });
        assert_eq!(calls, 1);
        assert_eq!(value, Err("expected"));
        assert!(time.wall_ms.is_finite() && time.wall_ms >= 0.0);
        if cfg!(windows) {
            assert_eq!(time.cpu_status, "ok");
            assert!(
                time.cpu_ms
                    .is_some_and(|value| value.is_finite() && value >= 0.0)
            );
        } else {
            assert_eq!(time.cpu_status, "unsupported");
            assert_eq!(time.cpu_ms, None);
        }
    }
}
