//! 並列作成・並列展開・fsync省略の契約。
//! - 作成: worker 数にかかわらず書庫は byte 単位で同一（block は独立に圧縮し、書庫順に書く）。
//! - 展開/検証: threads 指定時は全 frame family を並列復号し、逐次と同じ内容を公開する。
//! - skip_fsync は公開前の fsync だけを省き、CRC 検査・no-replace 公開は維持する。
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use unlhare::{ExtractOptions, Limits, lhc};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;

fn root(tag: &str) -> PathBuf {
    let root = lhc_e2e_root::path(tag);
    fs::create_dir_all(&root).unwrap();
    root
}

// 決定的な疑似乱数（xorshift）。外部 fixture に依存せずテキスト/バイナリ混在の入力を作る。
fn pseudo(seed: u64, len: usize) -> Vec<u8> {
    let mut state = seed | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect()
}

fn text(len: usize) -> Vec<u8> {
    let words = [
        "lhc ",
        "archive ",
        "block ",
        "parallel ",
        "worker ",
        "order ",
        "frame ",
        "\n",
    ];
    let mut out = Vec::with_capacity(len);
    let mut i = 0usize;
    while out.len() < len {
        out.extend_from_slice(words[(i * 7 + i / 3) % words.len()].as_bytes());
        i += 1;
    }
    out.truncate(len);
    out
}

fn source(root: &Path) -> PathBuf {
    let source = root.join("source");
    fs::create_dir_all(source.join("dir/sub")).unwrap();
    // 1MiB を超える file は複数 block になり、file をまたいだ並列と順序復元を確認できる。
    fs::write(source.join("dir/multi.txt"), text(1_100_000)).unwrap();
    fs::write(source.join("dir/sub/random.bin"), pseudo(7, 40_000)).unwrap();
    fs::write(source.join("small.txt"), text(3_000)).unwrap();
    fs::write(source.join("empty"), []).unwrap();
    fs::write(source.join("tiny"), [1, 2, 3]).unwrap();
    source
}

fn create(source: &Path, archive: &Path, strategy: lhc::BlockStrategy, threads: usize) {
    lhc::create_from_directory(
        source,
        archive,
        &lhc::CreateOptions {
            block_strategy: strategy,
            threads,
            max_codec_memory_bytes: lhc::CODEC_MEMORY_BYTES * threads.max(1) as u64,
            skip_fsync: threads > 1,
            ..Default::default()
        },
    )
    .unwrap();
}

fn assert_same_tree(expected: &Path, actual: &Path) {
    for name in [
        "dir/multi.txt",
        "dir/sub/random.bin",
        "small.txt",
        "empty",
        "tiny",
    ] {
        assert_eq!(
            fs::read(expected.join(name)).unwrap(),
            fs::read(actual.join(name)).unwrap(),
            "{name}"
        );
    }
}

#[test]
fn parallel_create_is_byte_identical_and_parallel_extract_restores() {
    let root = root("parallel");
    let source = source(&root);
    for (label, strategy) in [
        ("mdl", lhc::BlockStrategy::Mdl),
        ("portfolio", lhc::BlockStrategy::PortfolioTrial),
        ("portfolio-ppm", lhc::BlockStrategy::PortfolioPpmTrial),
    ] {
        let serial = root.join(format!("{label}-1.lhc"));
        create(&source, &serial, strategy, 1);
        let expected = fs::read(&serial).unwrap();
        for threads in [2, 4] {
            let parallel = root.join(format!("{label}-{threads}.lhc"));
            create(&source, &parallel, strategy, threads);
            assert_eq!(
                expected,
                fs::read(&parallel).unwrap(),
                "{label}: archive bytes differ with {threads} workers"
            );
        }
        let limits = Limits::default();
        for threads in [1, 3] {
            let summary = lhc::verify_archive_with_options(
                &serial,
                &limits,
                &ExtractOptions {
                    threads,
                    ..Default::default()
                },
            )
            .unwrap();
            assert_eq!(summary.files, 5);
            for skip_fsync in [false, true] {
                let destination = root.join(format!("{label}-out-{threads}-{skip_fsync}"));
                lhc::extract_archive_with_options(
                    &serial,
                    &destination,
                    &limits,
                    &ExtractOptions {
                        threads,
                        skip_fsync,
                        ..Default::default()
                    },
                )
                .unwrap();
                assert_same_tree(&source, &destination);
                // 既存出力は上書きしない（並列経路でも no-replace を維持）。
                assert!(
                    lhc::extract_archive_with_options(
                        &serial,
                        &destination,
                        &limits,
                        &ExtractOptions {
                            threads,
                            skip_fsync,
                            ..Default::default()
                        },
                    )
                    .is_err()
                );
            }
        }
    }
}

#[test]
fn parallel_extract_rejects_corruption_without_publishing_later_files() {
    let root = root("parallel-corrupt");
    let source = source(&root);
    let archive = root.join("archive.lhc");
    create(&source, &archive, lhc::BlockStrategy::Mdl, 1);
    let mut bytes = fs::read(&archive).unwrap();
    // 末尾付近（最後の file 群の frame か CRC）を壊す。
    let at = bytes.len() - 40;
    bytes[at] ^= 0x55;
    let broken = root.join("broken.lhc");
    fs::write(&broken, &bytes).unwrap();
    let destination = root.join("broken-out");
    let result = lhc::extract_archive_with_options(
        &broken,
        &destination,
        &Limits::default(),
        &ExtractOptions {
            threads: 4,
            skip_fsync: true,
            ..Default::default()
        },
    );
    assert!(result.is_err());
    // 書庫順で最後の file は破損位置を含むので公開されない。
    let last = lhc::list_archive(&archive, &Limits::default())
        .unwrap()
        .into_iter()
        .rfind(|entry| !entry.is_directory && entry.original_size > 0)
        .unwrap();
    assert!(!destination.join(&last.name).exists(), "{}", last.name);
}

#[test]
fn cli_threads_and_no_fsync_flags_round_trip() {
    let root = root("parallel-cli");
    let source = source(&root);
    let archive = root.join("cli.lhc");
    let destination = root.join("cli-out");
    let cli = env!("CARGO_BIN_EXE_unlhare-cli");
    for args in [
        vec![
            "lhc-create",
            archive.to_str().unwrap(),
            "--source",
            source.to_str().unwrap(),
            "--threads",
            "3",
            "--no-fsync",
        ],
        vec!["lhc-test", archive.to_str().unwrap(), "--threads", "2"],
        vec![
            "lhc-extract",
            archive.to_str().unwrap(),
            "--output",
            destination.to_str().unwrap(),
            "--threads",
            "4",
            "--no-fsync",
        ],
    ] {
        let result = Command::new(cli).args(&args).output().unwrap();
        assert!(result.status.success(), "{args:?}: {result:?}");
    }
    assert_same_tree(&source, &destination);
}
