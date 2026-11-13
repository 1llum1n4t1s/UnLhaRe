//! scan後のsource交換・時刻と、macOS FIFOの非停止を実入口で確認する。
#[cfg(target_os = "macos")]
use std::path::PathBuf;
use std::{
    fs,
    time::{Duration, UNIX_EPOCH},
};
use unlhare::{Error, SourceEntry, lhc};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;
#[test]
fn source_replacement_is_rejected_and_negative_subsecond_time_is_floored() {
    let root = lhc_e2e_root::path("source-state");
    fs::create_dir_all(&root).unwrap();
    let source = root.join("input");
    fs::write(&source, b"input").unwrap();
    let before = fs::metadata(&source).unwrap().modified().unwrap();
    let archive = root.join("replaced.lhc");
    let mut replaced = false;
    let result = lhc::create_archive_with_progress(
        &archive,
        &[SourceEntry {
            path: source.clone(),
            name: "input".into(),
        }],
        &lhc::CreateOptions::default(),
        &mut |p| {
            if p.phase == 2 && !replaced {
                fs::rename(&source, root.join("prior-input-fixture")).unwrap();
                fs::write(&source, b"other").unwrap();
                fs::File::options()
                    .write(true)
                    .open(&source)
                    .unwrap()
                    .set_times(fs::FileTimes::new().set_modified(before))
                    .unwrap();
                replaced = true;
            }
            true
        },
    );
    assert!(matches!(result, Err(Error::Unsupported(_))));
    assert!(!archive.exists());
    fs::File::options()
        .write(true)
        .open(&source)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH - Duration::from_millis(500)))
        .unwrap();
    let timed = root.join("timed.lhc");
    lhc::create_archive(
        &timed,
        &[SourceEntry {
            path: source,
            name: "input".into(),
        }],
        &lhc::CreateOptions::default(),
    )
    .unwrap();
    assert_eq!(
        lhc::list_archive(&timed, &unlhare::Limits::default()).unwrap()[0].modified_unix_seconds,
        Some(-1)
    );
    fs::write(
        root.join("result.json"),
        b"{\"replacement_rejected\":true,\"unpublished\":true,\"pre_epoch_subsecond_floor\":true}",
    )
    .unwrap();
}

#[cfg(target_os = "macos")]
#[test]
fn macos_fifo_api_child() {
    let Some(path) = std::env::var_os("UNLHARE_LHC_FIFO_CHILD") else {
        return;
    };
    let path = PathBuf::from(path);
    let limits = unlhare::Limits::default();
    assert!(lhc::list_archive(&path, &limits).is_err());
    assert!(lhc::verify_archive(&path, &limits).is_err());
    assert!(lhc::extract_archive(&path, &path.with_extension("out"), &limits).is_err());
    assert!(
        lhc::create_archive(
            &path.with_extension("lhc"),
            &[SourceEntry {
                path,
                name: "fifo".into()
            }],
            &lhc::CreateOptions::default()
        )
        .is_err()
    );
}

#[cfg(target_os = "macos")]
#[test]
fn macos_fifo_is_rejected_without_waiting_for_a_writer() {
    use std::process::Command;
    let root = lhc_e2e_root::path("macos-fifo");
    fs::create_dir_all(&root).unwrap();
    let fifo = root.join("fifo");
    assert!(
        Command::new("/usr/bin/mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "macos_fifo_api_child", "--nocapture"])
        .env("UNLHARE_LHC_FIFO_CHILD", &fifo)
        .spawn()
        .unwrap();
    let start = std::time::Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if start.elapsed() > Duration::from_secs(3) {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("FIFO open blocked");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    fs::write(
        root.join("result.json"),
        b"{\"fifo_api_rejected_with_timeout\":true}",
    )
    .unwrap();
}
