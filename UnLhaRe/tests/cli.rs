use std::{fs, process::Command};

#[test]
fn cli_accepts_lh4_high_compression() {
    let temporary = tempfile::tempdir().unwrap();
    let source = temporary.path().join("input");
    fs::create_dir(&source).unwrap();
    fs::write(
        source.join("input"),
        b"LH4 CLI high compression\n".repeat(100),
    )
    .unwrap();
    let archive = temporary.path().join("high.lzh");
    let output = Command::new(env!("CARGO_BIN_EXE_unlhare-cli"))
        .arg("create")
        .arg(&archive)
        .arg("--source")
        .arg(&source)
        .args(["--method", "lh4", "--high-compression"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let limits = unlhare::Limits::default();
    assert_eq!(
        unlhare::list_archive(&archive, &limits).unwrap()[0].method,
        "-lh4-"
    );
    unlhare::verify_archive(&archive, &limits).unwrap();
}

#[test]
fn cli_commands_round_trip_and_report_existing_destination() {
    let temporary = tempfile::tempdir().unwrap();
    let source = temporary.path().join("input");
    let archive = temporary.path().join("test.lzh");
    let output = temporary.path().join("output");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("document.txt"), b"CLI round trip\n").unwrap();
    let cli = env!("CARGO_BIN_EXE_unlhare-cli");
    let created = Command::new(cli)
        .arg("create")
        .arg(&archive)
        .arg("--source")
        .arg(&source)
        .output()
        .unwrap();
    assert!(created.status.success(), "{:?}", created);
    let listed = Command::new(cli)
        .arg("list")
        .arg(&archive)
        .arg("--json")
        .output()
        .unwrap();
    assert!(listed.status.success());
    let entries: serde_json::Value = serde_json::from_slice(&listed.stdout).unwrap();
    assert_eq!(entries[0]["name"], "document.txt");
    assert!(
        Command::new(cli)
            .arg("test")
            .arg(&archive)
            .output()
            .unwrap()
            .status
            .success()
    );
    assert!(
        Command::new(cli)
            .arg("extract")
            .arg(&archive)
            .arg("--output")
            .arg(&output)
            .output()
            .unwrap()
            .status
            .success()
    );
    assert_eq!(
        fs::read(output.join("document.txt")).unwrap(),
        b"CLI round trip\n"
    );
    assert!(
        !Command::new(cli)
            .arg("extract")
            .arg(&archive)
            .arg("--output")
            .arg(&output)
            .output()
            .unwrap()
            .status
            .success()
    );
    assert_eq!(
        fs::read(output.join("document.txt")).unwrap(),
        b"CLI round trip\n"
    );
}
