use std::fs;

use tempfile::tempdir;
use unlhare::{
    CreateEntryStatus, CreateOptions, CreateReportOptions, Error, Limits, Method, SourceEntry,
    create_archive, create_archive_with_progress, create_archive_with_report,
    create_archive_with_report_options, list_archive,
};

#[cfg(windows)]
use unlhare::Progress;

fn source(path: impl Into<std::path::PathBuf>, name: &str) -> SourceEntry {
    SourceEntry {
        path: path.into(),
        name: name.to_owned(),
    }
}

fn stored_options() -> CreateOptions {
    CreateOptions {
        method: Method::Stored,
        ..CreateOptions::default()
    }
}

#[test]
fn missing_source_is_skipped_without_losing_other_entries() {
    let temporary = tempdir().expect("temporary directory");
    let first = temporary.path().join("first.txt");
    let missing = temporary.path().join("missing.txt");
    let second = temporary.path().join("second.txt");
    let archive = temporary.path().join("reported.lzh");
    fs::write(&first, b"first").expect("first source");
    fs::write(&second, b"second").expect("second source");

    let report = create_archive_with_report(
        &archive,
        &[
            source(&first, "first.txt"),
            source(&missing, "missing.txt"),
            source(&second, "second.txt"),
        ],
        &stored_options(),
        &mut |_| true,
    )
    .expect("archive creation with report");

    assert_eq!(report.entries.len(), 3);
    assert_eq!(report.entries[0].name, "first.txt");
    assert_eq!(report.entries[0].status, CreateEntryStatus::Written);
    assert_eq!(report.entries[0].error, None);
    assert_eq!(report.entries[1].name, "missing.txt");
    assert_eq!(report.entries[1].status, CreateEntryStatus::Skipped);
    assert!(report.entries[1].error.is_some());
    assert_eq!(report.entries[2].name, "second.txt");
    assert_eq!(report.entries[2].status, CreateEntryStatus::Written);

    let entries = list_archive(&archive, &Limits::default()).expect("list reported archive");
    assert_eq!(
        entries
            .into_iter()
            .map(|entry| entry.name)
            .collect::<Vec<_>>(),
        ["first.txt", "second.txt"]
    );
}

#[test]
fn all_skipped_sources_create_a_valid_empty_archive() {
    let temporary = tempdir().expect("temporary directory");
    let archive = temporary.path().join("empty.lzh");

    let report = create_archive_with_report(
        &archive,
        &[source(temporary.path().join("missing.txt"), "missing.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("all-skipped archive creation");

    assert_eq!(report.entries.len(), 1);
    assert_eq!(report.entries[0].status, CreateEntryStatus::Skipped);
    assert_eq!(fs::read(&archive).expect("empty archive"), [0]);
}

#[test]
fn fail_if_all_skipped_does_not_publish_an_empty_archive() {
    let temporary = tempdir().expect("temporary directory");
    let archive = temporary.path().join("must-not-exist.lzh");
    let error = create_archive_with_report_options(
        &archive,
        &[source(temporary.path().join("missing.txt"), "missing.txt")],
        &stored_options(),
        &CreateReportOptions {
            fail_if_all_skipped: true,
        },
        &mut |_| true,
    )
    .expect_err("all-skipped creation must fail when explicitly requested");

    assert!(matches!(error, Error::InvalidArgument(_)));
    assert!(!archive.exists());
}

#[test]
fn fail_if_all_skipped_still_publishes_partial_success() {
    let temporary = tempdir().expect("temporary directory");
    let readable = temporary.path().join("readable.txt");
    let archive = temporary.path().join("partial.lzh");
    fs::write(&readable, b"readable").expect("readable source");
    let report = create_archive_with_report_options(
        &archive,
        &[
            source(&readable, "readable.txt"),
            source(temporary.path().join("missing.txt"), "missing.txt"),
        ],
        &stored_options(),
        &CreateReportOptions {
            fail_if_all_skipped: true,
        },
        &mut |_| true,
    )
    .expect("one written entry must permit publication");

    assert_eq!(report.entries[0].status, CreateEntryStatus::Written);
    assert_eq!(report.entries[1].status, CreateEntryStatus::Skipped);
    assert!(archive.exists());
}

#[test]
fn legacy_create_apis_still_abort_on_missing_sources() {
    let temporary = tempdir().expect("temporary directory");
    let missing = temporary.path().join("missing.txt");
    let plain_archive = temporary.path().join("plain.lzh");
    let progress_archive = temporary.path().join("progress.lzh");
    let entries = [source(&missing, "missing.txt")];

    assert!(matches!(
        create_archive(&plain_archive, &entries, &stored_options()),
        Err(Error::Io(_))
    ));
    assert!(matches!(
        create_archive_with_progress(&progress_archive, &entries, &stored_options(), &mut |_| {
            true
        },),
        Err(Error::Io(_))
    ));
    assert!(!plain_archive.exists());
    assert!(!progress_archive.exists());
}

#[test]
fn cancellation_limits_and_invalid_names_are_never_reported_as_skips() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let missing = temporary.path().join("missing.txt");
    fs::write(&input, b"four").expect("source file");

    let cancelled_archive = temporary.path().join("cancelled.lzh");
    let cancelled = create_archive_with_report(
        &cancelled_archive,
        &[source(&missing, "missing.txt")],
        &stored_options(),
        &mut |progress| !(progress.phase == 1 && progress.completed == 1),
    )
    .expect_err("cancellation after a scan skip must abort");
    assert!(matches!(cancelled, Error::Cancelled));
    assert!(!cancelled_archive.exists());

    let limit_archive = temporary.path().join("limit.lzh");
    let mut limited = stored_options();
    limited.limits.max_entry_bytes = 3;
    let limit = create_archive_with_report(
        &limit_archive,
        &[source(&input, "input.txt")],
        &limited,
        &mut |_| true,
    )
    .expect_err("limit failure must abort");
    assert!(matches!(limit, Error::Limit(_)));
    assert!(!limit_archive.exists());

    for invalid_name in ["", "../escape.txt", r"C:\escape.txt"] {
        let invalid_archive = temporary
            .path()
            .join(format!("invalid-{}.lzh", invalid_name.len()));
        let invalid = create_archive_with_report(
            &invalid_archive,
            &[source(&missing, invalid_name)],
            &stored_options(),
            &mut |_| true,
        )
        .expect_err("invalid name must fail before a missing source is skipped");
        assert!(matches!(invalid, Error::InvalidPath(_)));
        assert!(!invalid_archive.exists());
    }
}

#[test]
fn windows_device_names_are_rejected_before_source_io() {
    let temporary = tempdir().expect("temporary directory");
    let missing = temporary.path().join("missing.txt");

    for (index, invalid_name) in [
        "CONIN$",
        "CONOUT$.txt",
        "COM0",
        "COM¹.txt",
        "LPT0",
        "LPT³.txt",
    ]
    .into_iter()
    .enumerate()
    {
        let archive = temporary.path().join(format!("device-{index}.lzh"));
        let error = create_archive(
            &archive,
            &[source(&missing, invalid_name)],
            &stored_options(),
        )
        .expect_err("device name must fail before the missing source is opened");

        assert!(matches!(error, Error::InvalidPath(name) if name == invalid_name));
        assert!(!archive.exists());
    }
}

#[test]
fn windows_relative_names_are_normalized_and_collide_with_slash_names() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let archive = temporary.path().join("windows-name.lzh");
    fs::write(&input, b"payload").expect("source file");

    let report = create_archive_with_report(
        &archive,
        &[source(&input, r"folder\payload.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("Windows-style relative name");
    assert_eq!(report.entries[0].name, "folder/payload.txt");
    assert_eq!(report.entries[0].status, CreateEntryStatus::Written);
    let listed = list_archive(&archive, &Limits::default()).expect("list normalized archive");
    assert_eq!(listed[0].name, "folder/payload.txt");

    let duplicate_archive = temporary.path().join("duplicate.lzh");
    let duplicate = create_archive_with_report(
        &duplicate_archive,
        &[
            source(&input, r"folder\payload.txt"),
            source(&input, "folder/payload.txt"),
        ],
        &stored_options(),
        &mut |_| true,
    )
    .expect_err("separator-normalized duplicate must fail");
    assert!(matches!(duplicate, Error::InvalidArgument(_)));
    assert!(!duplicate_archive.exists());
}

#[cfg(windows)]
#[test]
fn exclusively_locked_source_is_skipped_without_losing_other_entries() {
    use std::fs::OpenOptions;
    use std::os::windows::fs::OpenOptionsExt;

    let temporary = tempdir().expect("temporary directory");
    let locked = temporary.path().join("locked.txt");
    let readable = temporary.path().join("readable.txt");
    let archive = temporary.path().join("locked-scan.lzh");
    fs::write(&locked, b"locked").expect("locked source");
    fs::write(&readable, b"readable").expect("readable source");
    let _exclusive = OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(&locked)
        .expect("exclusive source handle");

    let report = create_archive_with_report(
        &archive,
        &[
            source(&locked, "locked.txt"),
            source(&readable, "readable.txt"),
        ],
        &stored_options(),
        &mut |_| true,
    )
    .expect("locked source should be skipped");

    assert_eq!(report.entries[0].status, CreateEntryStatus::Skipped);
    assert_eq!(report.entries[1].status, CreateEntryStatus::Written);
    let listed = list_archive(&archive, &Limits::default()).expect("list archive");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "readable.txt");
}

#[cfg(windows)]
#[test]
fn read_phase_io_skip_completes_progress_and_still_honors_cancellation() {
    use std::fs::{File, OpenOptions};
    use std::os::windows::fs::OpenOptionsExt;

    let temporary = tempdir().expect("temporary directory");
    let locked = temporary.path().join("locked.txt");
    let readable = temporary.path().join("readable.txt");
    fs::write(&locked, b"locked").expect("locked source");
    fs::write(&readable, b"readable").expect("readable source");
    let entries = [
        source(&locked, "locked.txt"),
        source(&readable, "readable.txt"),
    ];

    let archive = temporary.path().join("locked-read.lzh");
    let mut exclusive: Option<File> = None;
    let mut phase2 = Vec::new();
    let report =
        create_archive_with_report(&archive, &entries, &stored_options(), &mut |progress| {
            if progress.phase == 2 && exclusive.is_none() {
                exclusive = Some(
                    OpenOptions::new()
                        .read(true)
                        .share_mode(0)
                        .open(&locked)
                        .expect("lock after scan"),
                );
            }
            if progress.phase == 2 {
                phase2.push(progress);
            }
            true
        })
        .expect("read failure should be skipped");
    drop(exclusive);

    assert_eq!(report.entries[0].status, CreateEntryStatus::Skipped);
    assert_eq!(report.entries[1].status, CreateEntryStatus::Written);
    assert!(!phase2.is_empty());
    assert!(
        phase2.windows(2).all(|pair| {
            pair[0].total == pair[1].total && pair[0].completed <= pair[1].completed
        })
    );
    assert_eq!(phase2.last().map(|progress| progress.completed), Some(14));
    assert_eq!(phase2.last().map(|progress| progress.total), Some(14));

    let cancelled_archive = temporary.path().join("locked-read-cancelled.lzh");
    let mut exclusive: Option<File> = None;
    let cancelled = create_archive_with_report(
        &cancelled_archive,
        &entries[..1],
        &stored_options(),
        &mut |Progress {
                  phase,
                  completed,
                  total,
              }| {
            if phase == 2 && exclusive.is_none() {
                exclusive = Some(
                    OpenOptions::new()
                        .read(true)
                        .share_mode(0)
                        .open(&locked)
                        .expect("lock after scan"),
                );
            }
            !(phase == 2 && total > 0 && completed == total)
        },
    )
    .expect_err("cancellation at the read-skip checkpoint must abort");
    assert!(matches!(cancelled, Error::Cancelled));
    assert!(!cancelled_archive.exists());
}
