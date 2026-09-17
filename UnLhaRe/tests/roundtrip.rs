use std::fs;
use std::sync::{Arc, Barrier};
use std::thread;

use tempfile::tempdir;
use unlhare::{
    CreateOptions, Error, Limits, Method, create_from_directory, extract_archive, list_archive,
    verify_archive,
};

#[test]
fn public_apis_round_trip_unicode_hierarchy_and_empty_entries() {
    let temporary = tempdir().expect("temporary directory");
    let source = temporary.path().join("source");
    let unicode_directory = source.join("日本語😀");
    let empty_directory = source.join("空ディレクトリ🫙");
    let archive = temporary.path().join("unicode.lzh");
    let destination = temporary.path().join("extracted");
    let payload = "日本語とemojiの本文 🚀\n".repeat(128);

    fs::create_dir_all(&unicode_directory).expect("Unicode source directory");
    fs::create_dir_all(&empty_directory).expect("empty source directory");
    fs::write(unicode_directory.join("絵文字🚀.txt"), payload.as_bytes())
        .expect("Unicode source file");
    fs::write(unicode_directory.join("空ファイル.txt"), []).expect("empty source file");

    create_from_directory(&source, &archive, &CreateOptions::default())
        .expect("directory should archive");

    let entries = list_archive(&archive, &Limits::default()).expect("archive should list");
    assert_eq!(entries.len(), 4);
    assert!(entries.iter().any(|entry| {
        entry.name == "日本語😀" && entry.is_directory && entry.original_size == 0
    }));
    assert!(entries.iter().any(|entry| {
        entry.name == "空ディレクトリ🫙" && entry.is_directory && entry.original_size == 0
    }));
    assert!(entries.iter().any(|entry| {
        entry.name == "日本語😀/絵文字🚀.txt"
            && !entry.is_directory
            && entry.original_size == payload.len() as u64
    }));
    assert!(entries.iter().any(|entry| {
        entry.name == "日本語😀/空ファイル.txt" && !entry.is_directory && entry.original_size == 0
    }));

    let verified = verify_archive(&archive, &Limits::default()).expect("archive should verify");
    assert_eq!(verified.entries, 4);
    assert_eq!(verified.files, 2);
    assert_eq!(verified.bytes, payload.len() as u64);

    let extracted = extract_archive(&archive, &destination, &Limits::default())
        .expect("archive should extract");
    assert_eq!(extracted.entries, verified.entries);
    assert_eq!(extracted.files, verified.files);
    assert_eq!(extracted.bytes, verified.bytes);
    assert_eq!(
        fs::read_to_string(destination.join("日本語😀").join("絵文字🚀.txt"))
            .expect("extracted Unicode file"),
        payload
    );
    assert_eq!(
        fs::read(destination.join("日本語😀").join("空ファイル.txt"))
            .expect("extracted empty file"),
        [0u8; 0]
    );
    assert!(destination.join("空ディレクトリ🫙").is_dir());
}

#[test]
fn empty_directory_produces_empty_archive_for_all_reader_operations() {
    let temporary = tempdir().expect("temporary directory");
    let source = temporary.path().join("empty-source");
    let archive = temporary.path().join("empty.lzh");
    let destination = temporary.path().join("empty-output");
    fs::create_dir(&source).expect("empty source directory");

    create_from_directory(&source, &archive, &CreateOptions::default())
        .expect("empty directory should archive");
    assert_eq!(fs::read(&archive).expect("empty archive"), [0]);
    assert!(
        list_archive(&archive, &Limits::default())
            .expect("empty archive should list")
            .is_empty()
    );
    let verified =
        verify_archive(&archive, &Limits::default()).expect("empty archive should verify");
    assert_eq!(verified.entries, 0);
    assert_eq!(verified.files, 0);
    assert_eq!(verified.bytes, 0);

    let extracted = extract_archive(&archive, &destination, &Limits::default())
        .expect("empty archive should extract");
    assert_eq!(extracted.entries, 0);
    assert_eq!(extracted.files, 0);
    assert_eq!(extracted.bytes, 0);
    assert!(destination.is_dir());
    assert_eq!(
        fs::read_dir(&destination)
            .expect("empty extraction directory")
            .count(),
        0
    );
}

#[test]
fn extraction_preserves_an_existing_file() {
    let temporary = tempdir().expect("temporary directory");
    let source = temporary.path().join("source");
    let archive = temporary.path().join("existing-target.lzh");
    let destination = temporary.path().join("destination");
    fs::create_dir(&source).expect("source directory");
    fs::create_dir(&destination).expect("destination directory");
    fs::write(source.join("keep.txt"), b"replacement").expect("source file");
    fs::write(destination.join("keep.txt"), b"original").expect("existing destination file");
    create_from_directory(&source, &archive, &CreateOptions::default())
        .expect("source should archive");

    let error = extract_archive(&archive, &destination, &Limits::default())
        .expect_err("existing extraction target must be rejected");
    assert!(matches!(error, Error::Exists(path) if path == destination.join("keep.txt")));
    assert_eq!(
        fs::read(destination.join("keep.txt")).expect("existing file should remain"),
        b"original"
    );
}

#[test]
fn limits_apply_to_creation_and_all_reader_operations() {
    let temporary = tempdir().expect("temporary directory");
    let source = temporary.path().join("source");
    let archive = temporary.path().join("limits.lzh");
    fs::create_dir(&source).expect("source directory");
    fs::write(source.join("payload.bin"), b"12345678").expect("source file");

    let create_limits = Limits {
        max_entries: 0,
        ..Limits::default()
    };
    let create_options = CreateOptions {
        method: Method::Stored,
        limits: create_limits,
    };
    let rejected_archive = temporary.path().join("rejected.lzh");
    assert!(matches!(
        create_from_directory(&source, &rejected_archive, &create_options),
        Err(Error::Limit(_))
    ));
    assert!(!rejected_archive.exists());

    let options = CreateOptions {
        method: Method::Stored,
        limits: Limits::default(),
    };
    create_from_directory(&source, &archive, &options).expect("source should archive");
    let strict_limits = Limits {
        max_entries: 1,
        max_entry_bytes: 7,
        max_total_bytes: 7,
    };
    assert!(matches!(
        list_archive(&archive, &strict_limits),
        Err(Error::Limit(_))
    ));
    assert!(matches!(
        verify_archive(&archive, &strict_limits),
        Err(Error::Limit(_))
    ));
    let destination = temporary.path().join("limited-extraction");
    assert!(matches!(
        extract_archive(&archive, &destination, &strict_limits),
        Err(Error::Limit(_))
    ));
    assert!(!destination.join("payload.bin").exists());
}

#[test]
fn public_operations_are_independent_when_called_in_parallel() {
    const WORKERS: usize = 4;
    let barrier = Arc::new(Barrier::new(WORKERS));
    let workers: Vec<_> = (0..WORKERS)
        .map(|index| {
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                let temporary = tempdir().expect("worker temporary directory");
                let source = temporary.path().join("source");
                let archive = temporary.path().join("parallel.lzh");
                let destination = temporary.path().join("output");
                fs::create_dir(&source).expect("worker source directory");
                let payload = format!("並列ワーカー {index} 🧵");
                fs::write(source.join("結果😀.txt"), payload.as_bytes())
                    .expect("worker source file");
                let options = CreateOptions {
                    method: Method::Stored,
                    limits: Limits::default(),
                };

                barrier.wait();
                create_from_directory(&source, &archive, &options)
                    .expect("parallel archive creation");
                let entries =
                    list_archive(&archive, &Limits::default()).expect("parallel archive listing");
                assert_eq!(entries.len(), 1);
                assert_eq!(entries[0].name, "結果😀.txt");
                let verified = verify_archive(&archive, &Limits::default())
                    .expect("parallel archive verification");
                assert_eq!(verified.entries, 1);
                assert_eq!(verified.files, 1);
                assert_eq!(verified.bytes, payload.len() as u64);
                extract_archive(&archive, &destination, &Limits::default())
                    .expect("parallel archive extraction");
                assert_eq!(
                    fs::read_to_string(destination.join("結果😀.txt"))
                        .expect("parallel extracted file"),
                    payload
                );
            })
        })
        .collect();

    for worker in workers {
        worker.join().expect("parallel worker should not panic");
    }
}
