use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crc_fast::{CrcAlgorithm, checksum};
use tempfile::tempdir;
use unlhare::{
    CreateOptions, Error, ExtractOptions, Limits, Method, SourceEntry,
    create_archive_with_progress, extract_archive, extract_archive_with_options, list_archive,
    list_archive_with_progress, verify_archive,
};

const ARCHIVE_MTIME: i64 = 1_234_567_890;

fn stored_options() -> CreateOptions {
    CreateOptions {
        method: Method::Stored,
        ..CreateOptions::default()
    }
}

fn source(path: impl Into<PathBuf>, name: &str) -> SourceEntry {
    SourceEntry {
        path: path.into(),
        name: name.to_owned(),
    }
}

fn system_time(unix_seconds: i64) -> SystemTime {
    let duration = Duration::from_secs(unix_seconds.unsigned_abs());
    if unix_seconds >= 0 {
        UNIX_EPOCH.checked_add(duration)
    } else {
        UNIX_EPOCH.checked_sub(duration)
    }
    .expect("test timestamp is representable")
}

fn set_modified(path: &Path, unix_seconds: i64) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .expect("open test file for timestamp")
        .set_times(fs::FileTimes::new().set_modified(system_time(unix_seconds)))
        .expect("set test timestamp");
}

fn modified(path: &Path) -> SystemTime {
    fs::metadata(path)
        .expect("read test file metadata")
        .modified()
        .expect("read test file modification time")
}

fn create_timestamped_archive(root: &Path) -> PathBuf {
    let input = root.join("input.txt");
    let archive = root.join("timestamped.lzh");
    fs::write(&input, b"timestamped payload").expect("write source file");
    set_modified(&input, ARCHIVE_MTIME);
    create_archive_with_progress(
        &archive,
        &[source(&input, "input.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("create timestamped archive");
    archive
}

fn mutate_level2_header(path: &Path, mutate: impl FnOnce(&mut [u8])) {
    let mut archive = fs::read(path).expect("read generated archive");
    let header_size = usize::from(u16::from_le_bytes([archive[0], archive[1]]));
    assert_eq!(archive[20], 2, "test archive must use a level-2 header");
    mutate(&mut archive[..header_size]);

    let mut extension_offset = 26_usize;
    let mut extension_size = usize::from(u16::from_le_bytes([archive[24], archive[25]]));
    let mut header_crc_offset = None;
    while extension_size != 0 {
        let extension_end = extension_offset + extension_size;
        assert!(
            extension_end <= header_size,
            "extended header must be bounded"
        );
        if archive[extension_offset] == 0x00 {
            header_crc_offset = Some(extension_offset + 1);
        }
        extension_size = usize::from(u16::from_le_bytes([
            archive[extension_end - 2],
            archive[extension_end - 1],
        ]));
        extension_offset = extension_end;
    }

    let header_crc_offset = header_crc_offset.expect("common header CRC extension");
    archive[header_crc_offset..header_crc_offset + 2].fill(0);
    let header_crc = u16::try_from(checksum(CrcAlgorithm::Crc16Arc, &archive[..header_size]))
        .expect("CRC-16/ARC is 16-bit");
    archive[header_crc_offset..header_crc_offset + 2].copy_from_slice(&header_crc.to_le_bytes());
    fs::write(path, archive).expect("write mutated archive");
}

fn assert_all_read_paths_reject(archive: &Path, temporary: &Path, expected: fn(&Error) -> bool) {
    let list_error = list_archive(archive, &Limits::default()).expect_err("list must reject");
    assert!(expected(&list_error), "unexpected list error: {list_error}");

    let verify_error = verify_archive(archive, &Limits::default()).expect_err("verify must reject");
    assert!(
        expected(&verify_error),
        "unexpected verify error: {verify_error}"
    );

    let destination = temporary.join("rejected-extraction");
    let extract_error = extract_archive(archive, &destination, &Limits::default())
        .expect_err("extraction must reject");
    assert!(
        expected(&extract_error),
        "unexpected extraction error: {extract_error}"
    );
    assert!(!destination.exists());
}

#[test]
fn list_can_cancel_before_opening_the_archive() {
    let missing = Path::new("this-archive-must-not-be-opened.lzh");
    let mut progress = Vec::new();

    let error = list_archive_with_progress(missing, &Limits::default(), &mut |current| {
        progress.push(current);
        false
    })
    .expect_err("pre-cancelled list must not open the archive");

    assert!(matches!(error, Error::Cancelled));
    assert_eq!(progress.len(), 1);
    assert_eq!(progress[0].phase, 1);
    assert_eq!(progress[0].completed, 0);
}

#[test]
fn list_can_cancel_between_headers() {
    let temporary = tempdir().expect("temporary directory");
    let first = temporary.path().join("first.txt");
    let second = temporary.path().join("second.txt");
    let archive = temporary.path().join("multiple.lzh");
    fs::write(&first, b"first").expect("first source file");
    fs::write(&second, b"second").expect("second source file");
    create_archive_with_progress(
        &archive,
        &[source(&first, "first.txt"), source(&second, "second.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("create multi-entry archive");

    let error = list_archive_with_progress(&archive, &Limits::default(), &mut |progress| {
        !(progress.phase == 1 && progress.completed == 1)
    })
    .expect_err("list must cancel after its first header");

    assert!(matches!(error, Error::Cancelled));
}

#[test]
fn list_reports_the_archive_modification_time() {
    let temporary = tempdir().expect("temporary directory");
    let archive = create_timestamped_archive(temporary.path());

    let entries = list_archive(&archive, &Limits::default()).expect("list timestamped archive");

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].modified_unix_seconds, Some(ARCHIVE_MTIME));
}

#[test]
fn timestamp_restoration_is_opt_in() {
    let temporary = tempdir().expect("temporary directory");
    let archive = create_timestamped_archive(temporary.path());
    let default_destination = temporary.path().join("default");
    let preserved_destination = temporary.path().join("preserved");

    extract_archive(&archive, &default_destination, &Limits::default())
        .expect("extract with default behavior");
    assert_ne!(
        modified(&default_destination.join("input.txt")),
        system_time(ARCHIVE_MTIME),
        "the existing extraction API must retain its default timestamp behavior"
    );

    extract_archive_with_options(
        &archive,
        &preserved_destination,
        &Limits::default(),
        None,
        &ExtractOptions {
            preserve_timestamps: true,
        },
        &mut |_| true,
    )
    .expect("extract with timestamp restoration");
    assert_eq!(
        modified(&preserved_destination.join("input.txt")),
        system_time(ARCHIVE_MTIME)
    );
}

#[test]
fn timestamp_restoration_does_not_modify_an_existing_file() {
    let temporary = tempdir().expect("temporary directory");
    let archive = create_timestamped_archive(temporary.path());
    let destination = temporary.path().join("existing");
    let existing = destination.join("input.txt");
    fs::create_dir(&destination).expect("create extraction destination");
    fs::write(&existing, b"existing payload").expect("write existing target");
    set_modified(&existing, ARCHIVE_MTIME + 86_400);
    let original_modified = modified(&existing);

    let error = extract_archive_with_options(
        &archive,
        &destination,
        &Limits::default(),
        None,
        &ExtractOptions {
            preserve_timestamps: true,
        },
        &mut |_| true,
    )
    .expect_err("existing target must not be replaced");

    assert!(matches!(error, Error::Exists(path) if path == existing));
    assert_eq!(
        fs::read(&existing).expect("read existing target"),
        b"existing payload"
    );
    assert_eq!(modified(&existing), original_modified);
}

#[test]
fn msdos_symlink_attribute_is_rejected_by_all_read_paths() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let archive = temporary.path().join("symlink-attribute.lzh");
    fs::write(&input, b"link target").expect("write source file");
    create_archive_with_progress(
        &archive,
        &[source(&input, "input.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("create base archive");
    mutate_level2_header(&archive, |header| header[19] |= 0x40);

    assert_all_read_paths_reject(&archive, temporary.path(), |error| {
        matches!(error, Error::Unsupported(_))
    });
}

#[test]
fn crafted_windows_device_name_is_rejected_by_all_read_paths() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let archive = temporary.path().join("device-name.lzh");
    fs::write(&input, b"payload").expect("write source file");
    create_archive_with_progress(
        &archive,
        &[source(&input, "safe.txt")],
        &stored_options(),
        &mut |_| true,
    )
    .expect("create base archive");
    mutate_level2_header(&archive, |header| {
        let replacement = b"COM0.txt";
        let filename_offset = header
            .windows(replacement.len() + 1)
            .position(|window| window[0] == 0x01 && &window[1..] == b"safe.txt")
            .expect("filename extension");
        header[filename_offset + 1..filename_offset + 1 + replacement.len()]
            .copy_from_slice(replacement);
    });

    assert_all_read_paths_reject(&archive, temporary.path(), |error| {
        matches!(error, Error::InvalidPath(_))
    });
}
