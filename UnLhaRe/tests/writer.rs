use std::fs::{self, File};
use std::io::Read;

use delharc::LhaDecodeReader;
use tempfile::tempdir;
use unlhare::{CreateOptions, Error, Method, SourceEntry, create_archive};

fn source(path: impl Into<std::path::PathBuf>, name: &str) -> SourceEntry {
    SourceEntry {
        path: path.into(),
        name: name.to_owned(),
    }
}

fn decode_one(archive: &std::path::Path, expected_method: &[u8; 5]) -> (String, Vec<u8>) {
    let file = File::open(archive).expect("archive should open");
    let mut reader = LhaDecodeReader::new(file).expect("level-2 header should parse");
    assert_eq!(reader.header().level, 2);
    assert_eq!(&reader.header().compression, expected_method);
    let name = reader.header().parse_pathname_to_str();
    let mut decoded = Vec::new();
    reader
        .read_to_end(&mut decoded)
        .expect("entry body should decode");
    reader.crc_check().expect("entry body CRC should match");
    assert!(!reader.next_file().expect("archive terminator should parse"));
    (name, decoded)
}

#[test]
fn all_public_methods_round_trip_with_independent_reader() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("payload.bin");
    let payload = b"compressible modern UnLhaRe payload\n".repeat(4096);
    fs::write(&input, &payload).expect("source file");

    for (method, method_id, label) in [
        (Method::Stored, b"-lh0-", "lh0"),
        (Method::Lh5, b"-lh5-", "lh5"),
        (Method::Lh6, b"-lh6-", "lh6"),
        (Method::Lh7, b"-lh7-", "lh7"),
    ] {
        let archive = temporary.path().join(format!("{label}.lzh"));
        let options = CreateOptions {
            method,
            ..CreateOptions::default()
        };
        create_archive(&archive, &[source(&input, "folder/payload.bin")], &options)
            .expect("archive creation should succeed");

        let (name, decoded) = decode_one(&archive, method_id);
        assert_eq!(name, "folder/payload.bin");
        assert_eq!(decoded, payload);
    }
}

#[test]
fn empty_archive_and_empty_file_are_valid() {
    let temporary = tempdir().expect("temporary directory");
    let empty_archive = temporary.path().join("empty-archive.lzh");
    create_archive(&empty_archive, &[], &CreateOptions::default())
        .expect("empty archive creation should succeed");
    assert_eq!(fs::read(&empty_archive).expect("empty archive"), [0]);

    let input = temporary.path().join("empty.txt");
    fs::write(&input, []).expect("empty source file");
    let archive = temporary.path().join("empty-file.lzh");
    create_archive(
        &archive,
        &[source(&input, "empty.txt")],
        &CreateOptions::default(),
    )
    .expect("empty file should archive");
    let (name, decoded) = decode_one(&archive, b"-lh0-");
    assert_eq!(name, "empty.txt");
    assert!(decoded.is_empty());
}

#[test]
fn japanese_hierarchy_has_utf8_codepage_and_unicode_extensions() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("source.txt");
    let payload = "日本語の本文".as_bytes();
    fs::write(&input, payload).expect("source file");
    let archive = temporary.path().join("unicode.lzh");
    let options = CreateOptions {
        method: Method::Stored,
        ..CreateOptions::default()
    };
    create_archive(&archive, &[source(&input, "日本語/資料.txt")], &options)
        .expect("Unicode archive creation should succeed");

    let file = File::open(&archive).expect("archive should open");
    let mut reader = LhaDecodeReader::new(file).expect("Unicode header CRC should parse");
    let extras: Vec<Vec<u8>> = reader
        .header()
        .iter_extra()
        .map(|extra| extra.to_vec())
        .collect();

    assert!(extras.iter().any(|extra| {
        extra.first() == Some(&0x46) && extra.get(1..5) == Some(&65_001_u32.to_le_bytes())
    }));
    assert!(extras.iter().any(|extra| {
        extra.first() == Some(&0x01) && extra.get(1..) == Some("資料.txt".as_bytes())
    }));
    let mut utf8_directory = "日本語".as_bytes().to_vec();
    utf8_directory.push(0xff);
    assert!(extras.iter().any(|extra| {
        extra.first() == Some(&0x02) && extra.get(1..) == Some(utf8_directory.as_slice())
    }));

    let utf16_name: Vec<u8> = "資料.txt"
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    assert!(extras.iter().any(|extra| {
        extra.first() == Some(&0x44) && extra.get(1..) == Some(utf16_name.as_slice())
    }));
    let mut utf16_directory: Vec<u8> = "日本語".encode_utf16().flat_map(u16::to_le_bytes).collect();
    utf16_directory.extend_from_slice(&0xffff_u16.to_le_bytes());
    assert!(extras.iter().any(|extra| {
        extra.first() == Some(&0x45) && extra.get(1..) == Some(utf16_directory.as_slice())
    }));

    let mut decoded = Vec::new();
    reader
        .read_to_end(&mut decoded)
        .expect("Unicode entry should decode");
    assert_eq!(decoded, payload);
    reader.crc_check().expect("CRC should match");
}

#[test]
fn explicit_directory_is_written_as_lhd() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("empty-directory");
    fs::create_dir(&input).expect("source directory");
    let archive = temporary.path().join("directory.lzh");
    create_archive(
        &archive,
        &[source(&input, "parent/empty-directory")],
        &CreateOptions::default(),
    )
    .expect("directory should archive");

    let file = File::open(&archive).expect("archive should open");
    let mut reader = LhaDecodeReader::new(file).expect("directory header should parse");
    assert!(reader.header().is_directory());
    assert_eq!(
        reader.header().parse_pathname_to_str(),
        "parent/empty-directory"
    );
    assert_eq!(reader.header().original_size, 0);
    assert_eq!(reader.header().compressed_size, 0);
    assert!(!reader.next_file().expect("archive terminator should parse"));
}

#[test]
fn existing_destination_is_preserved() {
    let temporary = tempdir().expect("temporary directory");
    let input = temporary.path().join("input.txt");
    let archive = temporary.path().join("existing.lzh");
    fs::write(&input, b"new data").expect("source file");
    fs::write(&archive, b"keep me").expect("existing destination");

    let error = create_archive(
        &archive,
        &[source(&input, "input.txt")],
        &CreateOptions::default(),
    )
    .expect_err("existing output must be rejected");
    assert!(matches!(error, Error::Exists(path) if path == archive));
    assert_eq!(
        fs::read(&archive).expect("existing destination"),
        b"keep me"
    );
}

#[test]
fn entry_count_file_size_and_total_size_limits_are_enforced() {
    let temporary = tempdir().expect("temporary directory");
    let first = temporary.path().join("first.bin");
    let second = temporary.path().join("second.bin");
    fs::write(&first, b"1234").expect("first source");
    fs::write(&second, b"5678").expect("second source");
    let entries = [source(&first, "first.bin"), source(&second, "second.bin")];

    let mut count_options = CreateOptions::default();
    count_options.limits.max_entries = 1;
    let count_output = temporary.path().join("count.lzh");
    assert!(matches!(
        create_archive(&count_output, &entries, &count_options),
        Err(Error::Limit(_))
    ));
    assert!(!count_output.exists());

    let mut entry_options = CreateOptions::default();
    entry_options.limits.max_entry_bytes = 3;
    let entry_output = temporary.path().join("entry.lzh");
    assert!(matches!(
        create_archive(&entry_output, &entries[..1], &entry_options),
        Err(Error::Limit(_))
    ));
    assert!(!entry_output.exists());

    let mut total_options = CreateOptions::default();
    total_options.limits.max_total_bytes = 7;
    let total_output = temporary.path().join("total.lzh");
    assert!(matches!(
        create_archive(&total_output, &entries, &total_options),
        Err(Error::Limit(_))
    ));
    assert!(!total_output.exists());
}
