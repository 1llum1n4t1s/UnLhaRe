//! 製品入口の異常系。有限故障を固定し、失敗entryの非公開も観測する。
use std::{fs, path::PathBuf};
use unlhare::{Error, Limits, SourceEntry, khc};
#[path = "common/khc_e2e_root.rs"]
mod khc_e2e_root;

fn root(tag: &str) -> PathBuf {
    let root = khc_e2e_root::path(tag);
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn corrupt_truncated_and_trailing_are_rejected_before_entry_publication() {
    let root = root("corrupt");
    let input = root.join("input");
    fs::write(&input, b"a small stored input").unwrap();
    let good = root.join("good.khc");
    khc::create_archive(
        &good,
        &[SourceEntry {
            path: input,
            name: "input".into(),
        }],
        &khc::CreateOptions::default(),
    )
    .unwrap();
    let bytes = fs::read(&good).unwrap();
    let limits = Limits::default();
    let mut corruptions = Vec::new();
    for offset in [0, 8, 9, 12, 16, 20, 24, 28, 32] {
        let mut b = bytes.clone();
        b[offset] ^= 0xff;
        corruptions.push(b);
    }
    // frame payload、file CRCの破損はこのentryを公開しない。
    let mut body = bytes.clone();
    let index = body.len() - 13;
    body[index] ^= 1;
    corruptions.push(body);
    let mut crc = bytes.clone();
    let index = crc.len() - 9;
    crc[index] ^= 1;
    corruptions.push(crc);
    for length in [0, 1, 8, 31, 32, bytes.len() / 2, bytes.len() - 9] {
        corruptions.push(bytes[..length].to_vec());
    }
    for (i, corruption) in corruptions.iter().enumerate() {
        let archive = root.join(format!("bad-{i}.khc"));
        fs::write(&archive, corruption).unwrap();
        assert!(khc::verify_archive(&archive, &limits).is_err(), "fault {i}");
        let output = root.join(format!("out-{i}"));
        assert!(
            khc::extract_archive(&archive, &output, &limits).is_err(),
            "extract fault {i}"
        );
        assert!(!output.join("input").exists(), "fault {i} published");
        assert_eq!(khc::verify_archive(&good, &limits).unwrap().files, 1);
    }
    // whole-archive trailing is detected, but already verified prior entries may remain.
    let mut trailing = bytes;
    trailing.push(0);
    let archive = root.join("trailing.khc");
    fs::write(&archive, trailing).unwrap();
    assert!(khc::verify_archive(&archive, &limits).is_err());
    fs::write(
        root.join("result.json"),
        format!(
            "{{\"rejected\":{},\"same_process_recovery\":{},\"failed_entry_unpublished\":true}}",
            corruptions.len() + 1,
            corruptions.len()
        ),
    )
    .unwrap();
}

#[test]
fn limits_names_cancellation_and_no_replace() {
    let root = root("policy");
    let source = root.join("input");
    fs::write(&source, b"original").unwrap();
    let entry = SourceEntry {
        path: source.clone(),
        name: "input".into(),
    };
    let options = khc::CreateOptions::default();
    let archive = root.join("good.khc");
    khc::create_archive(&archive, std::slice::from_ref(&entry), &options).unwrap();
    assert!(matches!(
        khc::create_archive(&archive, std::slice::from_ref(&entry), &options),
        Err(Error::Exists(_))
    ));
    let output = root.join("out");
    fs::create_dir(&output).unwrap();
    fs::write(output.join("input"), b"preserve").unwrap();
    assert!(matches!(
        khc::extract_archive(&archive, &output, &Limits::default()),
        Err(Error::Exists(_))
    ));
    assert_eq!(fs::read(output.join("input")).unwrap(), b"preserve");
    let zero = Limits {
        max_entries: 0,
        ..Limits::default()
    };
    assert!(matches!(
        khc::list_archive(&archive, &zero),
        Err(Error::Limit(_))
    ));
    let tiny = Limits {
        max_entry_bytes: 1,
        ..Limits::default()
    };
    assert!(matches!(
        khc::verify_archive(&archive, &tiny),
        Err(Error::Limit(_))
    ));
    for (i, name) in ["../outside", "/absolute", "CON", "a\\b", "a/../b"]
        .iter()
        .enumerate()
    {
        let bad = root.join(format!("name-{i}.khc"));
        assert!(
            khc::create_archive(
                &bad,
                &[SourceEntry {
                    path: source.clone(),
                    name: (*name).into()
                }],
                &options
            )
            .is_err()
        );
        assert!(!bad.exists());
    }
    for names in [["same", "SAME"], ["file", "file/child"]] {
        let bad = root.join(format!("collision-{}.khc", names[0]));
        assert!(
            khc::create_archive(
                &bad,
                &names.map(|name| SourceEntry {
                    path: source.clone(),
                    name: name.into()
                }),
                &options
            )
            .is_err()
        );
        assert!(!bad.exists());
    }
    let cancelled = root.join("cancelled.khc");
    assert!(matches!(
        khc::create_archive_with_progress(&cancelled, &[entry], &options, &mut |p| p.phase != 4),
        Err(Error::Cancelled)
    ));
    assert!(!cancelled.exists());
    let race = root.join("race.khc");
    let result = khc::create_archive_with_progress(
        &race,
        &[SourceEntry {
            path: source,
            name: "input".into(),
        }],
        &options,
        &mut |p| {
            if p.phase == 4 && !race.exists() {
                fs::write(&race, b"racer").unwrap();
            }
            true
        },
    );
    assert!(matches!(result, Err(Error::Exists(_))));
    assert_eq!(fs::read(&race).unwrap(), b"racer");
}
