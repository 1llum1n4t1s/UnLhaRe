use std::{fs, process::Command};

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
