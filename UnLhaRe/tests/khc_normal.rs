//! 製品API/実CLIを通る正常系。実装より先に往復契約を固定する。
use std::{fs, path::PathBuf, process::Command};
use unlhare::{Limits, SourceEntry, khc};
#[path = "common/khc_e2e_root.rs"]
mod khc_e2e_root;

fn root(tag: &str) -> PathBuf {
    let root = khc_e2e_root::path(tag);
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn real_cli_and_api_round_trip_multiblock_and_empty() {
    let root = root("normal");
    let source = root.join("source");
    fs::create_dir_all(source.join("日本語/sub")).unwrap();
    let mut data = vec![b'A'; 1_048_577];
    data[1_048_575] = 255;
    fs::write(source.join("日本語/sub/data"), &data).unwrap();
    fs::write(source.join("empty"), []).unwrap();
    fs::write(source.join("one"), [0xff]).unwrap();
    fs::write(source.join("all"), (0..=255).collect::<Vec<u8>>()).unwrap();
    let archive = root.join("test.khc");
    let destination = root.join("extracted");
    let cli = env!("CARGO_BIN_EXE_unlhare-cli");
    for args in [
        vec![
            "khc-create",
            archive.to_str().unwrap(),
            "--source",
            source.to_str().unwrap(),
        ],
        vec!["khc-list", archive.to_str().unwrap(), "--json"],
        vec!["khc-test", archive.to_str().unwrap()],
        vec![
            "khc-extract",
            archive.to_str().unwrap(),
            "--output",
            destination.to_str().unwrap(),
        ],
    ] {
        let result = Command::new(cli).args(&args).output().unwrap();
        assert!(result.status.success(), "{args:?}: {result:?}");
    }
    for name in ["日本語/sub/data", "empty", "one", "all"] {
        assert_eq!(
            fs::read(source.join(name)).unwrap(),
            fs::read(destination.join(name)).unwrap()
        );
    }
    let limits = Limits::default();
    let summary = khc::verify_archive(&archive, &limits).unwrap();
    assert_eq!(summary.files, 4);
    assert_eq!(summary.bytes, 1_048_834);
    let mut visited = Vec::new();
    khc::visit_archive_entries(&archive, &limits, &mut |e| {
        visited.push(e.name.clone());
        true
    })
    .unwrap();
    assert_eq!(visited.len(), 6);
    assert_eq!(khc::list_archive(&archive, &limits).unwrap().len(), 6);
    let bytes = fs::read(&archive).unwrap();
    assert_eq!(&bytes[..8], b"KHC1ARC\0");
    assert!(bytes.len() < data.len());
    fs::write(
        root.join("result.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "byte_exact": true, "files": summary.files, "bytes": summary.bytes,
            "archive_bytes": bytes.len(), "api_and_real_cli": true
        }))
        .unwrap(),
    )
    .unwrap();
}

#[test]
fn independent_block_api_stored_and_empty_archive() {
    let root = root("empty-stored");
    let limits = Limits::default();
    let archive = root.join("empty.khc");
    khc::create_archive(&archive, &[], &khc::CreateOptions::default()).unwrap();
    assert!(khc::list_archive(&archive, &limits).unwrap().is_empty());
    assert_eq!(khc::verify_archive(&archive, &limits).unwrap().bytes, 0);
    let input: Vec<u8> = (0..=255).collect();
    let frame = khc::compress_block(&input).unwrap();
    assert_eq!(frame[10], 0);
    assert_eq!(khc::decompress_block(&frame).unwrap(), input);
    let file = root.join("input");
    fs::write(&file, &input).unwrap();
    let single = root.join("stored.khc");
    khc::create_archive(
        &single,
        &[SourceEntry {
            path: file,
            name: "input".into(),
        }],
        &khc::CreateOptions::default(),
    )
    .unwrap();
    khc::extract_archive(&single, &root.join("out"), &limits).unwrap();
    assert_eq!(fs::read(root.join("out/input")).unwrap(), input);
}
