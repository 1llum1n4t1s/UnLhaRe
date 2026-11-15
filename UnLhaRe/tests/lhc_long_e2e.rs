//! revision 12・13・14（大きな entry を長距離LZ LLZ1BLK で格納。13 は近傍距離符号を加えた frame revision 2、
//! 14 は同じ符号で segment を 4MiB に広げた frame revision 3）の公開API往復と拒否。
//! - 8MiB 以上の entry は LLZ1BLK、小さな entry は revision 11 と同じ候補を使う。
//! - 作成の worker 数で書庫の byte は変わらない。codec memory が足りなければ処理前に拒否する。
//! - 逐次・並列（wave 単位）の展開と検証で元に戻る。
//! - revision 11 へ書き換えた書庫、payload を壊した書庫は拒否し、entry を公開しない。
//!
//! 9MiB の入力を符号化するため、debug build では時間がかかる。release で実行する
//! （`cargo test --release --test lhc_long_e2e`）。
use crc_fast::{CrcAlgorithm, Digest, checksum};
use std::{fs, path::PathBuf};
use unlhare::{
    Error, ExtractOptions, Limits, SourceEntry,
    lhc::{self, BlockStrategy, CreateOptions},
};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;

const LLZ_MAGIC: &[u8; 8] = b"LLZ1BLK\0";

fn root(tag: &str) -> PathBuf {
    let root = lhc_e2e_root::path(&format!("long-{tag}"));
    fs::create_dir_all(&root).unwrap();
    root
}
fn u32_at(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}
// LLZ1BLK の wire CRC（header の 0..24 と 28..32、payload）を付け直す。
fn seal(frame: &mut [u8]) {
    let mut crc = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    crc.update(&frame[..24]);
    crc.update(&frame[28..]);
    frame[24..28].copy_from_slice(&(crc.finalize() as u32).to_le_bytes());
}
fn with_revision(archive: &[u8], revision: u8) -> Vec<u8> {
    let mut bytes = archive.to_vec();
    bytes[8] = revision;
    let crc = checksum(CrcAlgorithm::Crc32IsoHdlc, &bytes[..28]) as u32;
    bytes[28..32].copy_from_slice(&crc.to_le_bytes());
    bytes
}

// 語の並びに、数MiB前の断片の写しを混ぜたテキスト。長距離の一致が効く入力。
fn text(len: usize, seed: u32) -> Vec<u8> {
    let words = [
        "the ",
        "archive ",
        "keeps ",
        "every ",
        "block ",
        "and ",
        "checks ",
        "its ",
        "crc ",
        "<page>",
        "</page>\n",
        "long ",
        "range ",
        "match ",
    ];
    let mut state = seed;
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        if state.is_multiple_of(89) && out.len() > 3 << 20 {
            let from = out.len() - (2 << 20) - (state as usize % (1 << 20));
            let piece = out[from..from + 300].to_vec();
            out.extend_from_slice(&piece);
        } else {
            out.extend_from_slice(words[(state % words.len() as u32) as usize].as_bytes());
        }
    }
    out.truncate(len);
    out
}

fn create(
    root: &std::path::Path,
    name: &str,
    threads: usize,
    memory: u64,
) -> unlhare::Result<PathBuf> {
    create_with(root, name, threads, memory, BlockStrategy::LongRangeTrial)
}
fn create_with(
    root: &std::path::Path,
    name: &str,
    threads: usize,
    memory: u64,
    strategy: BlockStrategy,
) -> unlhare::Result<PathBuf> {
    let archive = root.join(name);
    lhc::create_archive(
        &archive,
        &[
            SourceEntry {
                path: root.join("big.txt"),
                name: "big.txt".into(),
            },
            SourceEntry {
                path: root.join("small.txt"),
                name: "small.txt".into(),
            },
        ],
        &CreateOptions {
            block_strategy: strategy,
            max_codec_memory_bytes: memory,
            threads,
            skip_fsync: true,
            ..Default::default()
        },
    )?;
    Ok(archive)
}

#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "9MiB の符号化に時間がかかるため release で実行する"
)]
fn revision12_long_entries_round_trip_and_reject_corruption() {
    let root = root("archive");
    let big = text((9 << 20) + 4321, 0x9e37_79b9);
    let small = text(300_000, 0x1234_5678);
    fs::write(root.join("big.txt"), &big).unwrap();
    fs::write(root.join("small.txt"), &small).unwrap();
    let memory = lhc::LONG_RANGE_CREATE_MEMORY_BYTES;

    // codec memory が足りなければ処理前に拒否し、書庫を作らない。
    let refused = create(&root, "refused.lhc", 1, lhc::CODEC_MEMORY_BYTES);
    assert!(matches!(refused, Err(Error::Limit(_))), "{refused:?}");
    assert!(!root.join("refused.lhc").exists());

    let archive = create(&root, "long.lhc", 1, memory).unwrap();
    let parallel = create(&root, "long-4.lhc", 4, memory).unwrap();
    let base = fs::read(&archive).unwrap();
    assert_eq!(
        base,
        fs::read(&parallel).unwrap(),
        "worker count must not change bytes"
    );
    assert_eq!(base[8], 12, "archive revision");
    let prefix = 32 + u32_at(&base, 20);
    let first = u32_at(&base, prefix);
    assert_eq!(
        &base[prefix + 4..prefix + 12],
        LLZ_MAGIC,
        "big entry uses LLZ1BLK"
    );
    // 小さな entry の frame は LLZ1BLK ではない（big の frame 列と CRC の後ろ）。
    let mut at = prefix;
    let mut remaining = big.len();
    while remaining != 0 {
        at += 4 + u32_at(&base, at);
        remaining -= remaining.min(1 << 20);
    }
    at += 4;
    assert_ne!(
        &base[at + 4..at + 12],
        LLZ_MAGIC,
        "small entry stays revision 11"
    );

    let limits = Limits::default();
    for threads in [0, 1, 4] {
        let options = ExtractOptions {
            threads,
            skip_fsync: true,
            ..Default::default()
        };
        assert_eq!(
            lhc::verify_archive_with_options(&archive, &limits, &options)
                .unwrap()
                .bytes,
            (big.len() + small.len()) as u64
        );
        let output = root.join(format!("out-{threads}"));
        lhc::extract_archive_with_options(&archive, &output, &limits, &options).unwrap();
        assert_eq!(fs::read(output.join("big.txt")).unwrap(), big);
        assert_eq!(fs::read(output.join("small.txt")).unwrap(), small);
    }
    let listed = lhc::list_archive(&archive, &limits).unwrap();
    assert_eq!(listed.len(), 2);

    // LLZ1BLK は revision 11 の family 境界の外。
    let downgraded = root.join("revision-11.lhc");
    fs::write(&downgraded, with_revision(&base, 11)).unwrap();
    assert!(lhc::verify_archive(&downgraded, &limits).is_err());

    // 2 つ目の wave の block（block 2）の payload を壊す（wire CRC の付け直しあり・なし）。
    let mut block2 = prefix + 4 + first;
    block2 += 4 + u32_at(&base, block2);
    let length2 = u32_at(&base, block2);
    assert_eq!(&base[block2 + 4..block2 + 12], LLZ_MAGIC);
    for (index, reseal) in [(0usize, false), (1, true)] {
        let mut broken = base.clone();
        broken[block2 + 4 + 32 + length2 / 2] ^= 0x24;
        if reseal {
            seal(&mut broken[block2 + 4..block2 + 4 + length2]);
        }
        let path = root.join(format!("broken-{index}.lhc"));
        fs::write(&path, &broken).unwrap();
        for threads in [0, 1, 4] {
            let options = ExtractOptions {
                threads,
                ..Default::default()
            };
            assert!(lhc::verify_archive_with_options(&path, &limits, &options).is_err());
            let output = root.join(format!("broken-out-{index}-{threads}"));
            assert!(lhc::extract_archive_with_options(&path, &output, &limits, &options).is_err());
            assert!(!output.join("big.txt").exists());
        }
    }

    // LLZ1BLK は単独の block としては復号しない。
    let frame = &base[prefix + 4..prefix + 4 + first];
    assert!(lhc::decompress_block(frame).is_err());
}

/// big.txt の全 frame の位置（長さ prefix の位置）。manifest の直後から big.txt の block が並ぶ。
fn big_frames(archive: &[u8], len: usize) -> Vec<usize> {
    let mut at = 32 + u32_at(archive, 20);
    let mut out = Vec::new();
    let mut remaining = len;
    while remaining != 0 {
        out.push(at);
        at += 4 + u32_at(archive, at);
        remaining -= remaining.min(1 << 20);
    }
    out
}
fn frame_rev(archive: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(archive[at + 4 + 8..at + 4 + 10].try_into().unwrap())
}

#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "9MiB の符号化に時間がかかるため release で実行する"
)]
fn revision13_near_entries_round_trip_and_reject_cross_revision() {
    let root = root("near");
    let big = text((9 << 20) + 4321, 0x9e37_79b9);
    let small = text(300_000, 0x1234_5678);
    fs::write(root.join("big.txt"), &big).unwrap();
    fs::write(root.join("small.txt"), &small).unwrap();
    let memory = lhc::LONG_RANGE_CREATE_MEMORY_BYTES;
    let near = BlockStrategy::LongRangeNearTrial;

    // codec memory の条件は revision 12 と同じ。足りなければ処理前に拒否し、書庫を作らない。
    let refused = create_with(&root, "refused.lhc", 1, lhc::CODEC_MEMORY_BYTES, near);
    assert!(matches!(refused, Err(Error::Limit(_))), "{refused:?}");
    assert!(!root.join("refused.lhc").exists());

    let one = create_with(&root, "near-1.lhc", 1, memory, near).unwrap();
    let four = create_with(&root, "near-4.lhc", 4, memory, near).unwrap();
    let v13 = fs::read(&one).unwrap();
    assert_eq!(
        v13,
        fs::read(&four).unwrap(),
        "worker count must not change bytes"
    );
    assert_eq!(v13[8], 13, "archive revision");
    let v12_path = create(&root, "plain.lhc", 4, memory).unwrap();
    let v12 = fs::read(&v12_path).unwrap();
    assert_eq!(v12[8], 12, "revision 12 archive");

    // frame revision は archive revision と 1 対 1（13 は 2、12 は 1）。
    let frames13 = big_frames(&v13, big.len());
    let frames12 = big_frames(&v12, big.len());
    assert_eq!(frames13.len(), frames12.len());
    for (&a, &b) in frames13.iter().zip(&frames12) {
        assert_eq!(&v13[a + 4..a + 12], LLZ_MAGIC);
        assert_eq!(&v12[b + 4..b + 12], LLZ_MAGIC);
        assert_eq!(frame_rev(&v13, a), 2);
        assert_eq!(frame_rev(&v12, b), 1);
    }
    // 小さな entry は従来どおり LLZ1BLK ではない（big の最後の frame と CRC の後ろ）。
    let last = *frames13.last().unwrap();
    let after_big = last + 4 + u32_at(&v13, last) + 4;
    assert_ne!(&v13[after_big + 4..after_big + 12], LLZ_MAGIC);

    // 一覧・検証・展開（逐次・並列）で元に戻り、revision 12 の書庫も引き続き読める。
    let limits = Limits::default();
    for (label, archive) in [("13", &one), ("12", &v12_path)] {
        assert_eq!(lhc::list_archive(archive, &limits).unwrap().len(), 2);
        for threads in [0, 1, 4] {
            let options = ExtractOptions {
                threads,
                skip_fsync: true,
                ..Default::default()
            };
            assert_eq!(
                lhc::verify_archive_with_options(archive, &limits, &options)
                    .unwrap()
                    .bytes,
                (big.len() + small.len()) as u64
            );
            let output = root.join(format!("out-{label}-{threads}"));
            lhc::extract_archive_with_options(archive, &output, &limits, &options).unwrap();
            assert_eq!(fs::read(output.join("big.txt")).unwrap(), big);
            assert_eq!(fs::read(output.join("small.txt")).unwrap(), small);
        }
    }

    // 版の境界：書庫の revision を書き換える（header CRC は付け直す）と、frame revision と合わず拒否する。
    let mut cases: Vec<(&str, Vec<u8>)> = vec![
        ("rev 2 frames in a rev 12 archive", with_revision(&v13, 12)),
        ("rev 1 frames in a rev 13 archive", with_revision(&v12, 13)),
        ("rev 13 archive read as 11", with_revision(&v13, 11)),
        ("rev 13 archive read as 14", with_revision(&v13, 14)),
        ("rev 13 archive read as 15", with_revision(&v13, 15)),
    ];
    // frame revision だけを書き換える（wire CRC は付け直す）。archive の revision とは合わない。
    for (label, source, frames, from, to) in [
        (
            "rev 2 frame rewritten as rev 1 in a rev 13 archive",
            &v13,
            &frames13,
            2u16,
            1u16,
        ),
        (
            "rev 1 frame rewritten as rev 2 in a rev 12 archive",
            &v12,
            &frames12,
            1,
            2,
        ),
        (
            "rev 2 frame rewritten as rev 3 in a rev 13 archive",
            &v13,
            &frames13,
            2,
            3,
        ),
    ] {
        let mut bytes = source.clone();
        let at = frames[1];
        let length = u32_at(&bytes, at);
        assert_eq!(frame_rev(&bytes, at), from);
        bytes[at + 4 + 8..at + 4 + 10].copy_from_slice(&to.to_le_bytes());
        seal(&mut bytes[at + 4..at + 4 + length]);
        cases.push((label, bytes));
    }
    for (index, (label, bytes)) in cases.iter().enumerate() {
        let path = root.join(format!("cross-{index}.lhc"));
        fs::write(&path, bytes).unwrap();
        for threads in [0, 1, 4] {
            let options = ExtractOptions {
                threads,
                ..Default::default()
            };
            assert!(
                lhc::verify_archive_with_options(&path, &limits, &options).is_err(),
                "{label} must be rejected (threads {threads})"
            );
            let output = root.join(format!("cross-out-{index}-{threads}"));
            assert!(
                lhc::extract_archive_with_options(&path, &output, &limits, &options).is_err(),
                "{label} extraction must fail (threads {threads})"
            );
            assert!(!output.join("big.txt").exists());
        }
    }

    // payload の破損（wire CRC の付け直しあり・なし）は revision 13 でも拒否し、公開しない。
    let block2 = frames13[2];
    let length2 = u32_at(&v13, block2);
    for (index, reseal) in [(0usize, false), (1, true)] {
        let mut broken = v13.clone();
        broken[block2 + 4 + 32 + length2 / 2] ^= 0x24;
        if reseal {
            seal(&mut broken[block2 + 4..block2 + 4 + length2]);
        }
        let path = root.join(format!("broken-13-{index}.lhc"));
        fs::write(&path, &broken).unwrap();
        for threads in [0, 1, 4] {
            let options = ExtractOptions {
                threads,
                ..Default::default()
            };
            assert!(lhc::verify_archive_with_options(&path, &limits, &options).is_err());
            let output = root.join(format!("broken-13-out-{index}-{threads}"));
            assert!(lhc::extract_archive_with_options(&path, &output, &limits, &options).is_err());
            assert!(!output.join("big.txt").exists());
        }
    }
}

// ---- revision 14（segment 4MiB、frame revision 3） ----

const MIB: usize = 1 << 20;

/// 長さ prefix の位置から、`len` byte の entry の frame の位置を `unit` 単位で数えて並べる。
fn frames_at(archive: &[u8], start: usize, len: usize, unit: usize) -> Vec<usize> {
    let mut at = start;
    let mut out = Vec::new();
    let mut remaining = len;
    while remaining != 0 {
        out.push(at);
        at += 4 + u32_at(archive, at);
        remaining -= remaining.min(unit);
    }
    out
}
/// 位置 `at` の frame（長さ prefix 付き）を `frame` に置き換える。
fn replace_frame(archive: &[u8], at: usize, frame: &[u8]) -> Vec<u8> {
    let old = u32_at(archive, at);
    let mut out = archive[..at].to_vec();
    out.extend_from_slice(&(frame.len() as u32).to_le_bytes());
    out.extend_from_slice(frame);
    out.extend_from_slice(&archive[at + 4 + old..]);
    out
}
/// 位置 `at` の長さ prefix だけを書き換える（後ろの byte は動かさない）。
fn set_prefix(archive: &[u8], at: usize, length: u32) -> Vec<u8> {
    let mut out = archive.to_vec();
    out[at..at + 4].copy_from_slice(&length.to_le_bytes());
    out
}
/// LLZ1BLK の frame の生データ長（header の 12..16）を書き換え、wire CRC を付け直す。
fn with_raw_length(frame: &[u8], raw: u32) -> Vec<u8> {
    let mut out = frame.to_vec();
    out[12..16].copy_from_slice(&raw.to_le_bytes());
    seal(&mut out);
    out
}

/// 逐次・並列の検証と展開が失敗し、big.txt を公開しないことを確かめる。
fn assert_rejected(root: &std::path::Path, label: &str, bytes: &[u8], must_contain: Option<&str>) {
    assert_rejected_entry(root, label, bytes, must_contain, "big.txt");
}

/// 壊した entry（`broken`）が公開されないことまで確かめる（それより前の entry は公開されうる）。
fn assert_rejected_entry(
    root: &std::path::Path,
    label: &str,
    bytes: &[u8],
    must_contain: Option<&str>,
    broken: &str,
) {
    let limits = Limits::default();
    let path = root.join(format!("bad-{}.lhc", label.replace([' ', '/'], "_")));
    fs::write(&path, bytes).unwrap();
    // 一覧は frame の構造（長さ・family・LLZ1BLK の規則）だけを検査する。
    if let Some(text) = must_contain {
        let error = lhc::list_archive(&path, &limits).expect_err(label);
        assert!(error.to_string().contains(text), "{label}: {error}");
    }
    for threads in [0, 1, 4] {
        let options = ExtractOptions {
            threads,
            skip_fsync: true,
            ..Default::default()
        };
        assert!(
            lhc::verify_archive_with_options(&path, &limits, &options).is_err(),
            "{label} must be rejected (threads {threads})"
        );
        let output = root.join(format!(
            "bad-out-{}-{threads}",
            label.replace([' ', '/'], "_")
        ));
        assert!(
            lhc::extract_archive_with_options(&path, &output, &limits, &options).is_err(),
            "{label} extraction must fail (threads {threads})"
        );
        assert!(!output.join(broken).exists(), "{label}: entry published");
    }
}

#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "9MiB の符号化に時間がかかるため release で実行する"
)]
fn revision14_wide_entries_round_trip_and_reject_malformed_frames() {
    let root = root("wide");
    let big = text((9 << 20) + 4321, 0x9e37_79b9);
    let small = text(300_000, 0x1234_5678);
    let exact = text(8 << 20, 0x0bad_cafe);
    fs::write(root.join("big.txt"), &big).unwrap();
    fs::write(root.join("small.txt"), &small).unwrap();
    fs::write(root.join("exact.txt"), &exact).unwrap();
    let wide = BlockStrategy::LongRangeWideTrial;
    let sources = || {
        ["big.txt", "small.txt", "exact.txt"].map(|name| SourceEntry {
            path: root.join(name),
            name: name.into(),
        })
    };
    let make = |name: &str, threads: usize, memory: u64, strategy: BlockStrategy| {
        let archive = root.join(name);
        lhc::create_archive(
            &archive,
            &sources(),
            &CreateOptions {
                block_strategy: strategy,
                max_codec_memory_bytes: memory,
                threads,
                skip_fsync: true,
                ..Default::default()
            },
        )
        .map(|()| archive)
    };
    let memory = lhc::LONG_RANGE_WIDE_CREATE_MEMORY_BYTES;
    assert!(memory > lhc::LONG_RANGE_CREATE_MEMORY_BYTES);

    // codec memory が足りなければ処理前に拒否し、書庫を作らない（revision 12・13 の予算でも足りない）。
    for short in [lhc::CODEC_MEMORY_BYTES, lhc::LONG_RANGE_CREATE_MEMORY_BYTES] {
        let refused = make("refused.lhc", 1, short, wide);
        assert!(matches!(refused, Err(Error::Limit(_))), "{refused:?}");
        assert!(!root.join("refused.lhc").exists());
    }

    let one = make("wide-1.lhc", 1, memory, wide).unwrap();
    let four = make("wide-4.lhc", 4, memory, wide).unwrap();
    let zero = make("wide-0.lhc", 0, memory, wide).unwrap();
    let v14 = fs::read(&one).unwrap();
    for other in [&zero, &four] {
        assert_eq!(
            v14,
            fs::read(other).unwrap(),
            "worker count must not change bytes"
        );
    }
    assert_eq!(v14[8], 14, "archive revision");

    // big は 4MiB 単位の LLZ1BLK（最後だけ端数）、small は LLZ1BLK ではない、exact は 4MiB の 2 frame。
    let start = 32 + u32_at(&v14, 20);
    let big_frames = frames_at(&v14, start, big.len(), 4 * MIB);
    assert_eq!(big_frames.len(), 3);
    for &at in &big_frames {
        assert_eq!(&v14[at + 4..at + 12], LLZ_MAGIC);
        assert_eq!(frame_rev(&v14, at), 3);
    }
    assert_eq!(u32_at(&v14, big_frames[0] + 4 + 12), 4 * MIB, "raw length");
    assert_eq!(u32_at(&v14, big_frames[2] + 4 + 12), MIB + 4321, "tail");
    let last = *big_frames.last().unwrap();
    let small_at = last + 4 + u32_at(&v14, last) + 4;
    assert_ne!(&v14[small_at + 4..small_at + 12], LLZ_MAGIC);
    let small_frames = frames_at(&v14, small_at, small.len(), MIB);
    let last = *small_frames.last().unwrap();
    let exact_at = last + 4 + u32_at(&v14, last) + 4;
    let exact_frames = frames_at(&v14, exact_at, exact.len(), 4 * MIB);
    assert_eq!(exact_frames.len(), 2);
    for &at in &exact_frames {
        assert_eq!(&v14[at + 4..at + 12], LLZ_MAGIC);
        assert_eq!(u32_at(&v14, at + 4 + 12), 4 * MIB);
    }

    // 一覧・検証・展開（threads 0/1/4）で元に戻る。
    let limits = Limits::default();
    let total = (big.len() + small.len() + exact.len()) as u64;
    assert_eq!(lhc::list_archive(&one, &limits).unwrap().len(), 3);
    for threads in [0, 1, 4] {
        let options = ExtractOptions {
            threads,
            skip_fsync: true,
            ..Default::default()
        };
        assert_eq!(
            lhc::verify_archive_with_options(&one, &limits, &options)
                .unwrap()
                .bytes,
            total
        );
        let output = root.join(format!("out-14-{threads}"));
        lhc::extract_archive_with_options(&one, &output, &limits, &options).unwrap();
        assert_eq!(fs::read(output.join("big.txt")).unwrap(), big);
        assert_eq!(fs::read(output.join("small.txt")).unwrap(), small);
        assert_eq!(fs::read(output.join("exact.txt")).unwrap(), exact);
    }

    // revision 11 で作った書庫（8MiB 以上の entry も 1MiB の block）は、revision 14 としても正しい書庫。
    // 他 family の entry は単位 1MiB で、LLZ1BLK を置けない。
    let plain11 = fs::read(
        make(
            "plain-11.lhc",
            1,
            lhc::CODEC_MEMORY_BYTES,
            BlockStrategy::PortfolioPpmTrial,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(plain11[8], 11);
    let plain14 = with_revision(&plain11, 14);
    let plain_path = root.join("plain-14.lhc");
    fs::write(&plain_path, &plain14).unwrap();
    for threads in [0, 1, 4] {
        let options = ExtractOptions {
            threads,
            skip_fsync: true,
            ..Default::default()
        };
        assert_eq!(
            lhc::verify_archive_with_options(&plain_path, &limits, &options)
                .unwrap()
                .bytes,
            total
        );
        let output = root.join(format!("out-plain-{threads}"));
        lhc::extract_archive_with_options(&plain_path, &output, &limits, &options).unwrap();
        assert_eq!(fs::read(output.join("big.txt")).unwrap(), big);
    }
    let plain_frames = frames_at(&plain14, start, big.len(), MIB);
    assert_eq!(plain_frames.len(), 10);
    assert_ne!(
        &plain14[plain_frames[0] + 4..plain_frames[0] + 12],
        LLZ_MAGIC
    );

    // 版の取り違え：archive revision を書き換える（header CRC は付け直す）と、frame revision と単位が合わず拒否する。
    assert_rejected(&root, "rev14 read as 13", &with_revision(&v14, 13), None);
    assert_rejected(&root, "rev14 read as 12", &with_revision(&v14, 12), None);
    assert_rejected(&root, "rev14 read as 11", &with_revision(&v14, 11), None);
    assert_rejected(&root, "rev14 read as 15", &with_revision(&v14, 15), None);
    // frame revision だけを書き換える（wire CRC は付け直す）。3 を 2・4 にした frame は拒否する。
    for to in [2u16, 4] {
        let mut bytes = v14.clone();
        let at = big_frames[1];
        let length = u32_at(&bytes, at);
        bytes[at + 4 + 8..at + 4 + 10].copy_from_slice(&to.to_le_bytes());
        seal(&mut bytes[at + 4..at + 4 + length]);
        assert_rejected(
            &root,
            &format!("frame rev 3 rewritten as {to}"),
            &bytes,
            Some("LLZ1BLK"),
        );
    }

    // LLZ1BLK の entry の途中に他 family の frame（自己完結の 1MiB block）が混ざる。
    let other =
        lhc::compress_block_with_strategy(&big[..MIB], BlockStrategy::PortfolioPpmTrial).unwrap();
    for index in [1usize, 2] {
        let bytes = replace_frame(&v14, big_frames[index], &other);
        assert_rejected(
            &root,
            &format!("other family at frame {index}"),
            &bytes,
            Some("LLZ1BLK"),
        );
    }
    // 他 family の entry の途中に LLZ1BLK の frame が混ざる（最後の frame の LLZ1BLK を 1MiB block の位置へ）。
    let llz_tail = v14[big_frames[2] + 4..big_frames[2] + 4 + u32_at(&v14, big_frames[2])].to_vec();
    assert!(llz_tail.len() <= MIB + 40);
    for index in [1usize, 5, 8] {
        let bytes = replace_frame(&plain14, plain_frames[index], &llz_tail);
        assert_rejected(
            &root,
            &format!("llz in a plain entry at {index}"),
            &bytes,
            Some("outside an LLZ1BLK entry"),
        );
    }
    // 8MiB 未満の entry に LLZ1BLK が現れる。
    let bytes = replace_frame(&v14, small_frames[0], &llz_tail);
    assert_rejected_entry(&root, "llz in a small entry", &bytes, None, "small.txt");

    // LLZ1BLK の生データ長が期待値 min(残り, 4MiB) と違う（短い・長い・最後の frame が 4MiB など）。
    for (index, raw) in [
        (0usize, 4 * MIB as u32 - 1),
        (0, MIB as u32),
        (1, 4 * MIB as u32 - 1),
        (2, 4 * MIB as u32),
        (2, MIB as u32),
    ] {
        let at = big_frames[index];
        let length = u32_at(&v14, at);
        let frame = with_raw_length(&v14[at + 4..at + 4 + length], raw);
        let bytes = replace_frame(&v14, at, &frame);
        assert_rejected(
            &root,
            &format!("raw length {raw} at frame {index}"),
            &bytes,
            Some("LLZ1BLK lengths"),
        );
    }

    // frame の長さ prefix の上限：他 family の frame は 1MiB+40 まで、LLZ1BLK は 4MiB+40 まで（確保の前に拒否）。
    for (label, bytes) in [
        (
            "plain first frame 1MiB+41",
            set_prefix(&plain14, plain_frames[0], (MIB + 41) as u32),
        ),
        (
            "plain later frame 1MiB+41",
            set_prefix(&plain14, plain_frames[3], (MIB + 41) as u32),
        ),
        (
            "llz first frame 4MiB+41",
            set_prefix(&v14, big_frames[0], (4 * MIB + 41) as u32),
        ),
        (
            "llz later frame 4MiB+41",
            set_prefix(&v14, big_frames[1], (4 * MIB + 41) as u32),
        ),
        (
            "llz tail frame 1MiB+4361",
            set_prefix(&v14, big_frames[2], (MIB + 4321 + 41) as u32),
        ),
        (
            "first frame 4GiB",
            set_prefix(&v14, big_frames[0], u32::MAX),
        ),
    ] {
        assert_rejected(&root, label, &bytes, Some("block extent"));
    }

    // payload の破損（wire CRC の付け直しあり・なし）は拒否し、公開しない。wave の 1 つ目・2 つ目・最後の frame。
    for (index, &at) in big_frames.iter().enumerate() {
        let length = u32_at(&v14, at);
        for reseal in [false, true] {
            let mut broken = v14.clone();
            broken[at + 4 + 32 + (length - 32) / 2] ^= 0x24;
            if reseal {
                seal(&mut broken[at + 4..at + 4 + length]);
            }
            assert_rejected(
                &root,
                &format!("payload frame {index} reseal {reseal}"),
                &broken,
                None,
            );
        }
    }

    // LLZ1BLK は単独の block としては復号しない。
    assert!(
        lhc::decompress_block(
            &v14[big_frames[0] + 4..big_frames[0] + 4 + u32_at(&v14, big_frames[0])]
        )
        .is_err()
    );
}
