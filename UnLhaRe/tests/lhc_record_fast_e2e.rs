//! 公開API/CLIの往復と拒否。失敗候補はscheduleの欠落・非最小/zero/overflow delta、
//! 重複/範囲外位置、不正幅、header/model/payload切断、CRC、余剰byte、再呼出し、
//! codec上限、既存出力の置換。実データは親が管理する外部E2E rootへ置く。
use crc_fast::{CrcAlgorithm, Digest, checksum};
use std::{fs, path::PathBuf, process::Command};
use unlhare::{
    Limits, SourceEntry,
    lhc::{self, BlockStrategy, CreateOptions},
};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;

fn root(tag: &str) -> PathBuf {
    let root = lhc_e2e_root::path(&format!("record-fast-{tag}"));
    fs::create_dir(&root).unwrap();
    root
}
fn options() -> CreateOptions {
    CreateOptions {
        block_strategy: BlockStrategy::RecordFastTrial,
        ..Default::default()
    }
}
fn u32_at(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}
fn seal(frame: &mut [u8]) {
    let mut crc = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    crc.update(&frame[..28]);
    crc.update(&frame[32..]);
    frame[28..32].copy_from_slice(&(crc.finalize() as u32).to_le_bytes());
}
fn seeded(n: usize) -> Vec<u8> {
    let mut state = 0x6d2b79f5u32;
    (0..n)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        })
        .collect()
}

fn switching_pair_corpus() -> Vec<u8> {
    let mut state = 0x6d2b79f5u32;
    (0..lhc::BLOCK_BYTES)
        .map(|i| {
            let (base, period) = if i < lhc::BLOCK_BYTES / 2 {
                (0, 16)
            } else {
                (lhc::BLOCK_BYTES / 2, 8)
            };
            match (i - base) % period {
                0 => 33,
                1 => 52,
                _ => {
                    state ^= state << 13;
                    state ^= state >> 17;
                    state ^= state << 5;
                    (state % 254 + 1) as u8
                }
            }
        })
        .collect()
}

#[test]
fn public_frames_match_and_reuse_krs1_model_and_payload() {
    let mut inputs = vec![
        vec![],
        vec![255],
        vec![0, 255],
        vec![0; 8192],
        seeded(16384),
    ];
    inputs.push(
        (0..16384)
            .map(|i| {
                if i < 8192 {
                    (i % 17) as u8
                } else {
                    (i % 31) as u8
                }
            })
            .collect(),
    );
    inputs.push((0..16384).map(|i| ((i % 2) * 19) as u8).collect());
    let switching_pair = switching_pair_corpus();
    assert_eq!(
        checksum(CrcAlgorithm::Crc32IsoHdlc, &switching_pair) as u32,
        3_173_957_449
    );
    inputs.push(switching_pair);
    let mut coded = 0;
    let mut scheduled = 0;
    let mut fallbacks = 0;
    for raw in inputs {
        let frame =
            lhc::compress_block_with_strategy(&raw, BlockStrategy::RecordFastTrial).unwrap();
        let fallback =
            lhc::compress_block_with_strategy(&raw, BlockStrategy::BinaryAdaptive).unwrap();
        assert!(
            frame.len() <= fallback.len(),
            "raw={} candidate={} baseline={}",
            raw.len(),
            frame.len(),
            fallback.len()
        );
        assert!(frame.len() <= raw.len() + 40);
        assert_eq!(lhc::decompress_block(&frame).unwrap(), raw);
        let old = lhc::compress_block_with_strategy(&raw, BlockStrategy::RecordTrial).unwrap();
        assert_eq!(&old[..8], b"KRS1BLK\0");
        assert_eq!(lhc::decompress_block(&old).unwrap(), raw);
        if frame.starts_with(b"KRS2BLK\0") {
            assert_eq!(frame[10], 1);
            coded += 1;
            assert_eq!(old[10], 1);
            let model = u32_at(&frame, 16);
            let schedule = u32_at(&frame, 32);
            scheduled += usize::from(schedule != 0);
            assert_eq!(model, u32_at(&old, 16));
            assert_eq!(&frame[40..40 + model], &old[40..40 + model]);
            assert_eq!(&frame[40 + model + schedule..], &old[40 + model..]);
            assert!(frame.len() < raw.len().min(fallback.len()));
        } else {
            assert!(frame.starts_with(b"LHC1BLK\0"));
            assert_eq!(
                frame, fallback,
                "fallback must preserve the full baseline frame"
            );
            fallbacks += 1;
        }
    }
    assert!(
        coded > 0,
        "must exercise a real encoder-selected KRS2 coded frame"
    );
    assert!(
        scheduled > 0,
        "must exercise an encoder-selected KRS2 frame with width changes"
    );
    assert!(
        fallbacks > 0,
        "must exercise an exact BinaryAdaptive fallback"
    );
    assert!(
        lhc::compress_block_with_strategy(
            &vec![0; lhc::BLOCK_BYTES + 1],
            BlockStrategy::RecordFastTrial
        )
        .is_err()
    );
}

#[test]
fn revision6_archive_roundtrip_boundary_limits_and_no_replace() {
    let root = root("archive");
    let source = root.join("source");
    fs::create_dir(&source).unwrap();
    let cases = [
        ("empty", vec![]),
        ("tiny", vec![255]),
        ("boundary", vec![7; lhc::BLOCK_BYTES + 1]),
        ("random", seeded(16384)),
        ("periodic", (0..8192).map(|i| (i % 23) as u8).collect()),
        ("switching-pair", switching_pair_corpus()),
    ];
    for (name, raw) in &cases {
        fs::write(source.join(name), raw).unwrap();
    }
    let archive = root.join("archive.lhc");
    let destination = root.join("out");
    lhc::create_from_directory(&source, &archive, &options()).unwrap();
    let original_archive = fs::read(&archive).unwrap();
    assert_eq!(original_archive[8], 6);
    assert!(
        original_archive
            .windows(8)
            .any(|window| window == &b"KRS2BLK\0"[..]),
        "revision6 archive must contain an encoder-selected KRS2 block"
    );
    let limits = Limits::default();
    assert_eq!(
        lhc::list_archive(&archive, &limits).unwrap().len(),
        cases.len()
    );
    let summary = lhc::verify_archive(&archive, &limits).unwrap();
    assert_eq!(summary.files, cases.len() as u64);
    lhc::extract_archive(&archive, &destination, &limits).unwrap();
    for (name, raw) in &cases {
        assert_eq!(&fs::read(destination.join(name)).unwrap(), raw);
    }
    assert!(lhc::extract_archive(&archive, &destination, &limits).is_err());
    for (name, raw) in &cases {
        assert_eq!(&fs::read(destination.join(name)).unwrap(), raw);
    }
    assert!(lhc::create_from_directory(&source, &archive, &options()).is_err());
    assert_eq!(fs::read(&archive).unwrap(), original_archive);
    let mut limited = options();
    limited.max_codec_memory_bytes = lhc::CODEC_MEMORY_BYTES - 1;
    let rejected = root.join("limited.lhc");
    assert!(lhc::create_from_directory(&source, &rejected, &limited).is_err());
    assert!(!rejected.exists());
    let empty = root.join("empty.lhc");
    lhc::create_archive(&empty, &[], &options()).unwrap();
    assert_eq!(fs::read(&empty).unwrap()[8], 6);
    assert!(lhc::list_archive(&empty, &limits).unwrap().is_empty());
    assert_eq!(lhc::verify_archive(&empty, &limits).unwrap().bytes, 0);
}

// 独立wire fixture: class0はcount=64だけ、freq=32768。残差modelは空、
// rANSは初期state=Lのまま。幅が変わってもcopyされる原文64byteは全zero。
fn scheduled(schedule: &[u8]) -> Vec<u8> {
    let model = [1, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0];
    let payload = [0, 0, 0, 128, 0];
    let mut frame = vec![0; 40];
    frame[..8].copy_from_slice(b"KRS2BLK\0");
    frame[8..10].copy_from_slice(&2u16.to_le_bytes());
    frame[10] = 1;
    frame[12..16].copy_from_slice(&64u32.to_le_bytes());
    frame[16..20].copy_from_slice(&(model.len() as u32).to_le_bytes());
    frame[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[24..28]
        .copy_from_slice(&(checksum(CrcAlgorithm::Crc32IsoHdlc, &[0; 64]) as u32).to_le_bytes());
    frame[32..36].copy_from_slice(&(schedule.len() as u32).to_le_bytes());
    frame.extend_from_slice(&model);
    frame.extend_from_slice(schedule);
    frame.extend_from_slice(&payload);
    seal(&mut frame);
    frame
}
fn old_method(method: u8, raw: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0; 40];
    frame[..8].copy_from_slice(b"KRS2BLK\0");
    frame[8..10].copy_from_slice(&2u16.to_le_bytes());
    frame[10] = method;
    frame[12..16].copy_from_slice(&(raw.len() as u32).to_le_bytes());
    frame[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    frame[24..28]
        .copy_from_slice(&(checksum(CrcAlgorithm::Crc32IsoHdlc, raw) as u32).to_le_bytes());
    frame.extend_from_slice(payload);
    seal(&mut frame);
    frame
}
fn faults() -> Vec<(&'static str, Vec<u8>, bool)> {
    let mut faults = Vec::new();
    for (name, schedule) in [
        ("schedule delta truncation", vec![128]),
        ("schedule width truncation", vec![1, 8]),
        ("noncanonical delta", vec![129, 0, 8, 0]),
        ("zero delta", vec![0, 8, 0]),
        ("overflow delta", vec![255, 255, 255, 1, 8, 0]),
        ("duplicate position", vec![1, 8, 0, 0, 1, 0]),
        ("raw-end position", vec![64, 8, 0]),
        ("past raw-end position", vec![65, 8, 0]),
        ("zero width", vec![1, 0, 0]),
        ("oversized width", vec![1, 1, 4]),
    ] {
        faults.push((name, scheduled(&schedule), true));
    }
    let good = scheduled(&[1, 8, 0, 2, 1, 0]);
    let zeroes = [0; 64];
    faults.push((
        "retired KRS2 stored method",
        old_method(0, &zeroes, &zeroes),
        true,
    ));
    let legacy = lhc::compress_block(&zeroes).unwrap();
    faults.push((
        "retired KRS2 nested fallback method",
        old_method(2, &zeroes, &legacy),
        true,
    ));
    for (name, length) in [
        ("header truncation", 39),
        ("model truncation", 45),
        ("schedule truncation", 55),
        ("payload truncation", good.len() - 1),
    ] {
        faults.push((name, good[..length].to_vec(), true));
    }
    for (name, at) in [
        ("wire CRC", 28),
        ("raw CRC", 24),
        ("model", 43),
        ("payload prefix", good.len() - 5),
        ("reserved", 36),
        ("version", 8),
    ] {
        let mut bad = good.clone();
        bad[at] ^= 1;
        if at != 28 {
            seal(&mut bad);
        }
        faults.push((name, bad, !matches!(name, "raw CRC" | "payload prefix")));
    }
    let mut trailing = good.clone();
    trailing.push(0);
    seal(&mut trailing);
    faults.push(("trailing byte", trailing, true));
    let mut trailing_payload = good.clone();
    trailing_payload.push(0);
    let payload_len = (u32_at(&trailing_payload, 20) + 1) as u32;
    trailing_payload[20..24].copy_from_slice(&payload_len.to_le_bytes());
    seal(&mut trailing_payload);
    // Exact frame extents pass; verify must reject the undeclared-to-rANS extra byte.
    faults.push(("declared trailing rANS byte", trailing_payload, false));
    faults
}

#[test]
fn malformed_schedules_reject_and_next_decode_recovers() {
    // count0/literal'A'/count63、二つの等確率count symbolから独立に計算したrANS。
    // 位置1でwidth8へ、位置17でwidth1へ切替。zero予測から周期copy・重複copyへ進む。
    let model = [2, 0, 0, 0, 64, 63, 0, 64, 1, 0, 65, 0, 128, 0, 0, 0, 0];
    let mut expected = vec![0; 64];
    expected[0] = 65;
    expected[8] = 65;
    expected[16..].fill(65);
    let mut patterned = scheduled(&[1, 8, 0, 16, 1, 0]);
    patterned[16..20].copy_from_slice(&(model.len() as u32).to_le_bytes());
    patterned[24..28]
        .copy_from_slice(&(checksum(CrcAlgorithm::Crc32IsoHdlc, &expected) as u32).to_le_bytes());
    patterned.truncate(40);
    patterned.extend_from_slice(&model);
    patterned.extend_from_slice(&[1, 8, 0, 16, 1, 0]);
    patterned.extend_from_slice(&[0, 0, 128, 0, 2]);
    seal(&mut patterned);
    assert_eq!(lhc::decompress_block(&patterned).unwrap(), expected);
    for schedule in [
        vec![],
        vec![1, 8, 0, 2, 1, 0],
        vec![1, 0, 4],
        vec![63, 1, 0],
    ] {
        assert_eq!(
            lhc::decompress_block(&scheduled(&schedule)).unwrap(),
            [0; 64]
        );
    }
    let good = scheduled(&[1, 8, 0, 2, 1, 0]);
    for (name, bad, _) in faults() {
        assert!(lhc::decompress_block(&bad).is_err(), "{name}");
        assert_eq!(
            lhc::decompress_block(&good).unwrap(),
            [0; 64],
            "recovery: {name}"
        );
    }
}

#[test]
fn actual_archive_rejects_malformed_frame_without_publishing_entry() {
    let root = root("reject");
    let source = root.join("input");
    fs::write(&source, [0; 64]).unwrap();
    let archive = root.join("good.lhc");
    lhc::create_archive(
        &archive,
        &[SourceEntry {
            path: source,
            name: "input".into(),
        }],
        &options(),
    )
    .unwrap();
    let base = fs::read(&archive).unwrap();
    let prefix = 32 + u32_at(&base, 20);
    let suffix = prefix + 4 + u32_at(&base, prefix);
    let limits = Limits::default();
    for revision in [1, 3, 4, 5] {
        let mut mixed = base.clone();
        mixed[8] = revision;
        let crc = checksum(CrcAlgorithm::Crc32IsoHdlc, &mixed[..28]) as u32;
        mixed[28..32].copy_from_slice(&crc.to_le_bytes());
        let path = root.join(format!("revision-{revision}-mixed.lhc"));
        fs::write(&path, mixed).unwrap();
        assert!(lhc::list_archive(&path, &limits).is_err());
        assert!(lhc::verify_archive(&path, &limits).is_err());
    }
    let mut compatible = base.clone();
    compatible[8] = 2;
    let crc = checksum(CrcAlgorithm::Crc32IsoHdlc, &compatible[..28]) as u32;
    compatible[28..32].copy_from_slice(&crc.to_le_bytes());
    let compatible_path = root.join("revision-2-compatible-fallback.lhc");
    fs::write(&compatible_path, compatible).unwrap();
    assert_eq!(
        lhc::list_archive(&compatible_path, &limits).unwrap().len(),
        1
    );
    assert_eq!(
        lhc::verify_archive(&compatible_path, &limits)
            .unwrap()
            .bytes,
        64
    );
    let old_frame =
        lhc::compress_block_with_strategy(&[0; 64], BlockStrategy::RecordTrial).unwrap();
    let mut mixed = base[..prefix].to_vec();
    mixed.extend_from_slice(&(old_frame.len() as u32).to_le_bytes());
    mixed.extend_from_slice(&old_frame);
    mixed.extend_from_slice(&base[suffix..]);
    let path = root.join("revision-6-krs1.lhc");
    fs::write(&path, mixed).unwrap();
    assert!(lhc::list_archive(&path, &limits).is_err());
    assert!(lhc::verify_archive(&path, &limits).is_err());
    for (index, (name, frame, list_reject)) in faults().into_iter().enumerate() {
        let mut wire = base[..prefix].to_vec();
        wire.extend_from_slice(&(frame.len() as u32).to_le_bytes());
        wire.extend_from_slice(&frame);
        wire.extend_from_slice(&base[suffix..]);
        let bad = root.join(format!("bad-{index}.lhc"));
        fs::write(&bad, wire).unwrap();
        if list_reject {
            assert!(lhc::list_archive(&bad, &limits).is_err(), "list: {name}");
        }
        assert!(
            lhc::verify_archive(&bad, &limits).is_err(),
            "verify: {name}"
        );
        let output = root.join(format!("out-{index}"));
        assert!(
            lhc::extract_archive(&bad, &output, &limits).is_err(),
            "extract: {name}"
        );
        assert!(!output.join("input").exists(), "publication: {name}");
        assert_eq!(lhc::verify_archive(&archive, &limits).unwrap().bytes, 64);
    }
}

#[test]
fn real_cli_revision6_create_list_test_extract() {
    let root = root("cli");
    let source = root.join("source");
    fs::create_dir(&source).unwrap();
    let raw = switching_pair_corpus();
    fs::write(source.join("input"), &raw).unwrap();
    let archive = root.join("cli.lhc");
    let output = root.join("out");
    let cli = env!("CARGO_BIN_EXE_unlhare-cli");
    for arguments in [
        vec![
            "lhc-create",
            archive.to_str().unwrap(),
            "--source",
            source.to_str().unwrap(),
            "--strategy",
            "record-fast-trial",
        ],
        vec!["lhc-list", archive.to_str().unwrap(), "--json"],
        vec!["lhc-test", archive.to_str().unwrap()],
        vec![
            "lhc-extract",
            archive.to_str().unwrap(),
            "--output",
            output.to_str().unwrap(),
        ],
    ] {
        let result = Command::new(cli).args(&arguments).output().unwrap();
        assert!(result.status.success(), "{arguments:?}: {result:?}");
    }
    let archive_bytes = fs::read(&archive).unwrap();
    assert_eq!(archive_bytes[8], 6);
    assert!(
        archive_bytes
            .windows(8)
            .any(|window| window == b"KRS2BLK\0")
    );
    assert_eq!(fs::read(output.join("input")).unwrap(), raw);
}
