use std::fs;

use tempfile::tempdir;
use unlhare::{
    CreateOptions, Error, Limits, Method, Progress, SourceEntry, create_archive_with_progress,
    extract_archive_with_progress, verify_archive_with_progress,
};

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
fn progress_apis_round_trip_and_select_exact_names() {
    let temporary = tempdir().expect("temporary directory");
    let first = temporary.path().join("first.txt");
    let second = temporary.path().join("second.txt");
    let archive = temporary.path().join("selected.lzh");
    let destination = temporary.path().join("destination");
    fs::write(&first, b"first payload").expect("first source");
    fs::write(&second, b"second payload").expect("second source");

    let mut create_progress = Vec::new();
    create_archive_with_progress(
        &archive,
        &[
            source(&first, "Folder/first.txt"),
            source(&second, "Folder/second.txt"),
        ],
        &stored_options(),
        &mut |progress| {
            create_progress.push(progress);
            true
        },
    )
    .expect("archive creation");
    assert!(create_progress.iter().any(|progress| progress.phase == 1));
    assert!(create_progress.iter().any(|progress| progress.phase == 2));
    assert!(create_progress.iter().any(|progress| progress.phase == 4));

    let mut verify_progress = Vec::new();
    let verified = verify_archive_with_progress(&archive, &Limits::default(), &mut |progress| {
        verify_progress.push(progress);
        true
    })
    .expect("archive verification");
    assert_eq!(verified.files, 2);
    assert!(verify_progress.iter().any(|progress| progress.phase == 3));

    let selected = ["Folder/second.txt".to_owned()];
    let extracted = extract_archive_with_progress(
        &archive,
        &destination,
        &Limits::default(),
        Some(&selected),
        &mut |_| true,
    )
    .expect("selected extraction");
    assert_eq!(extracted, verified);
    assert!(!destination.join("Folder/first.txt").exists());
    assert_eq!(
        fs::read(destination.join("Folder/second.txt")).expect("selected file"),
        b"second payload"
    );
}

#[test]
fn creation_cancellation_leaves_no_archive() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("large.bin");
    let archive = temporary.path().join("cancelled.lzh");
    fs::write(&input, vec![0x5a; 128 * 1024]).expect("source file");

    let error = create_archive_with_progress(
        &archive,
        &[source(&input, "large.bin")],
        &stored_options(),
        &mut |progress| !(progress.phase == 2 && progress.total > 0),
    )
    .expect_err("creation should be cancelled");
    assert!(matches!(error, Error::Cancelled));
    assert!(!archive.exists());
}

#[test]
fn compressed_creation_can_cancel_after_encoding_without_publishing() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("large.bin");
    let archive = temporary.path().join("cancelled-compressed.lzh");
    fs::write(&input, vec![0x5a; 128 * 1024]).expect("source file");

    let error = create_archive_with_progress(
        &archive,
        &[source(&input, "large.bin")],
        &CreateOptions::default(),
        &mut |progress| {
            !(progress.phase == 2 && progress.total > 0 && progress.completed == progress.total)
        },
    )
    .expect_err("creation should be cancelled after compression");
    assert!(matches!(error, Error::Cancelled));
    assert!(!archive.exists());
}

#[test]
fn extraction_cancellation_removes_incomplete_file_and_preserves_existing_files() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("large.bin");
    let archive = temporary.path().join("cancelled-extract.lzh");
    let destination = temporary.path().join("destination");
    fs::write(&input, vec![0x33; 128 * 1024]).expect("source file");
    create_archive_with_progress(
        &archive,
        &[source(&input, "large.bin")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("archive creation");
    fs::create_dir(&destination).expect("destination");
    fs::write(destination.join("existing.txt"), b"keep").expect("existing file");

    let error = extract_archive_with_progress(
        &archive,
        &destination,
        &Limits::default(),
        None,
        &mut |Progress {
                  phase, completed, ..
              }| !(phase == 3 && completed > 0),
    )
    .expect_err("extraction should be cancelled");
    assert!(matches!(error, Error::Cancelled));
    assert!(!destination.join("large.bin").exists());
    assert_eq!(
        fs::read(destination.join("existing.txt")).expect("existing file"),
        b"keep"
    );
}

#[test]
fn verification_cancellation_is_reported() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("large.bin");
    let archive = temporary.path().join("cancelled-verify.lzh");
    fs::write(&input, vec![0x7c; 128 * 1024]).expect("source file");
    create_archive_with_progress(
        &archive,
        &[source(&input, "large.bin")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("archive creation");

    let error = verify_archive_with_progress(&archive, &Limits::default(), &mut |progress| {
        !(progress.phase == 3 && progress.completed > 0)
    })
    .expect_err("verification should be cancelled");
    assert!(matches!(error, Error::Cancelled));
}

#[test]
fn selection_still_applies_limits_to_the_complete_archive() {
    let temporary = tempdir().expect("temporary directory");
    let small = temporary.path().join("small.txt");
    let large = temporary.path().join("large.txt");
    let archive = temporary.path().join("limits.lzh");
    let destination = temporary.path().join("destination");
    fs::write(&small, b"ok").expect("small source");
    fs::write(&large, b"too large").expect("large source");
    create_archive_with_progress(
        &archive,
        &[source(&small, "small.txt"), source(&large, "large.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("archive creation");

    let selected = ["small.txt".to_owned()];
    let limits = Limits {
        max_entry_bytes: 4,
        ..Limits::default()
    };
    let error = extract_archive_with_progress(
        &archive,
        &destination,
        &limits,
        Some(&selected),
        &mut |_| true,
    )
    .expect_err("unselected metadata must still be limited");
    assert!(matches!(error, Error::Limit(_)));
    assert!(!destination.exists());
}

#[test]
fn exact_selection_does_not_replace_an_existing_target() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let archive = temporary.path().join("existing.lzh");
    let destination = temporary.path().join("destination");
    fs::write(&input, b"replacement").expect("source file");
    create_archive_with_progress(
        &archive,
        &[source(&input, "input.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("archive creation");
    fs::create_dir(&destination).expect("destination");
    fs::write(destination.join("input.txt"), b"original").expect("existing target");

    let selected = ["input.txt".to_owned()];
    let error = extract_archive_with_progress(
        &archive,
        &destination,
        &Limits::default(),
        Some(&selected),
        &mut |_| true,
    )
    .expect_err("existing target must be rejected");
    assert!(matches!(error, Error::Exists(_)));
    assert_eq!(
        fs::read(destination.join("input.txt")).expect("existing target"),
        b"original"
    );
}
