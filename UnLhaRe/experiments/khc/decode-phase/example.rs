//! archive/outputだけを受け取る単回診断。復元全SHAの検証はcontrollerが行う。
use std::{path::PathBuf, time::Instant};
use unlhare::{Limits, Summary, khc};

fn run() -> Result<Summary, String> {
    let mut args = std::env::args_os().skip(1);
    let (Some(archive), Some(output), None) = (args.next(), args.next(), args.next()) else {
        return Err("expected exactly archive and output arguments".to_owned());
    };
    khc::extract_archive(
        &PathBuf::from(archive),
        &PathBuf::from(output),
        &Limits::default(),
    )
    .map_err(|error| error.to_string())
}

fn main() {
    let started = Instant::now();
    let result = run();
    let outer_total_ns = started.elapsed().as_nanos();
    let phases = khc::phase_diagnostic::report_json(outer_total_ns);
    let (status, summary, error, exit) = match result {
        Ok(summary) => (
            "completed",
            format!(
                "{{\"entries\":{},\"files\":{},\"bytes\":{}}}",
                summary.entries, summary.files, summary.bytes
            ),
            "null".to_owned(),
            0,
        ),
        Err(error) => (
            "failed",
            "null".to_owned(),
            serde_json::to_string(&error)
                .unwrap_or_else(|_| "\"error serialization failed\"".to_owned()),
            1,
        ),
    };
    println!(
        "{{\"schema\":1,\"purpose\":\"non-comparative-decode-phase-diagnostic\",\"superiority_decision_allowed\":false,\"status\":\"{status}\",\"summary\":{summary},\"error\":{error},\"phase_report\":{phases}}}"
    );
    if exit != 0 {
        std::process::exit(exit);
    }
}
