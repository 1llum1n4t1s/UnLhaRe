//! revision 11（PPMII 系テキスト候補 LPM1BLK を含む portfolio）の公開API往復と拒否。
//! - テキスト block は LPM1BLK を選び、逐次・並列の展開と検証で元に戻る。
//! - LPM1BLK は revision 11 の書庫でだけ受理し、revision 10 へ書き換えた書庫は拒否する。
//! - payload を壊した frame は（wire CRC を付け直しても）拒否し、entry を公開しない。
use crc_fast::{CrcAlgorithm, Digest, checksum};
use std::{fs, path::PathBuf};
use unlhare::{
    ExtractOptions, Limits, SourceEntry,
    lhc::{self, BlockStrategy, CreateOptions},
};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;

const PPM_MAGIC: &[u8; 8] = b"LPM1BLK\0";

fn root(tag: &str) -> PathBuf {
    let root = lhc_e2e_root::path(&format!("ppm-{tag}"));
    fs::create_dir_all(&root).unwrap();
    root
}
fn u32_at(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}
// frame の wire CRC（28..32 を除く全体）を付け直す。
fn seal(frame: &mut [u8]) {
    let mut crc = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    crc.update(&frame[..28]);
    crc.update(&frame[32..]);
    frame[28..32].copy_from_slice(&(crc.finalize() as u32).to_le_bytes());
}
// 書庫 header の revision を書き換え、header CRC を付け直す。
fn with_revision(archive: &[u8], revision: u8) -> Vec<u8> {
    let mut bytes = archive.to_vec();
    bytes[8] = revision;
    let crc = checksum(CrcAlgorithm::Crc32IsoHdlc, &bytes[..28]) as u32;
    bytes[28..32].copy_from_slice(&crc.to_le_bytes());
    bytes
}

// 語の並びを変えた英文風テキスト。PPM が MDL より明確に小さくなる入力。
fn prose(len: usize) -> Vec<u8> {
    let words = [
        "the ",
        "archive ",
        "keeps ",
        "every ",
        "block ",
        "self ",
        "contained ",
        "and ",
        "checks ",
        "its ",
        "crc ",
        "before ",
        "publishing ",
        "files.\n",
    ];
    let mut state = 0x9e37_79b9u32;
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        out.extend_from_slice(words[(state % words.len() as u32) as usize].as_bytes());
    }
    out.truncate(len);
    out
}

#[test]
fn revision11_selects_ppm_round_trips_and_rejects_family_and_corruption() {
    let root = root("archive");
    let source = root.join("prose.txt");
    let raw = prose(300_000);
    fs::write(&source, &raw).unwrap();
    let archive = root.join("ppm.lhc");
    lhc::create_archive(
        &archive,
        &[SourceEntry {
            path: source,
            name: "prose.txt".into(),
        }],
        &CreateOptions {
            block_strategy: BlockStrategy::PortfolioPpmTrial,
            ..Default::default()
        },
    )
    .unwrap();
    let base = fs::read(&archive).unwrap();
    assert_eq!(base[8], 11, "archive revision");
    let prefix = 32 + u32_at(&base, 20);
    let length = u32_at(&base, prefix);
    let frame = &base[prefix + 4..prefix + 4 + length];
    assert_eq!(&frame[..8], PPM_MAGIC, "text block must select LPM1BLK");
    // 同じ入力の revision 10 書庫より小さい。
    let revision10 = root.join("portfolio.lhc");
    lhc::create_archive(
        &revision10,
        &[SourceEntry {
            path: root.join("prose.txt"),
            name: "prose.txt".into(),
        }],
        &CreateOptions {
            block_strategy: BlockStrategy::PortfolioTrial,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(base.len() < fs::read(&revision10).unwrap().len());

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
            raw.len() as u64
        );
        let output = root.join(format!("out-{threads}"));
        lhc::extract_archive_with_options(&archive, &output, &limits, &options).unwrap();
        assert_eq!(fs::read(output.join("prose.txt")).unwrap(), raw);
    }

    // LPM1BLK は revision 10 の family 境界の外。
    let downgraded = root.join("revision-10.lhc");
    fs::write(&downgraded, with_revision(&base, 10)).unwrap();
    assert!(lhc::verify_archive(&downgraded, &limits).is_err());
    let output = root.join("out-downgraded");
    assert!(lhc::extract_archive(&downgraded, &output, &limits).is_err());
    assert!(!output.join("prose.txt").exists());

    // 未知の revision 12 は manifest 読み取りで拒否する。
    let future = root.join("revision-12.lhc");
    fs::write(&future, with_revision(&base, 12)).unwrap();
    assert!(lhc::list_archive(&future, &limits).is_err());

    // payload の破損（wire CRC 付け直し・なしの両方）は拒否し、公開しない。
    for (index, reseal) in [(0usize, false), (1, true)] {
        let mut broken = base.clone();
        let at = prefix + 4 + 40 + length / 2;
        broken[at] ^= 0x24;
        if reseal {
            seal(&mut broken[prefix + 4..prefix + 4 + length]);
        }
        let path = root.join(format!("broken-{index}.lhc"));
        fs::write(&path, &broken).unwrap();
        for threads in [0, 4] {
            let options = ExtractOptions {
                threads,
                ..Default::default()
            };
            assert!(lhc::verify_archive_with_options(&path, &limits, &options).is_err());
            let output = root.join(format!("broken-out-{index}-{threads}"));
            assert!(lhc::extract_archive_with_options(&path, &output, &limits, &options).is_err());
            assert!(!output.join("prose.txt").exists());
        }
    }

    // 単独 block API でも frame の余剰・切断を拒否する。
    let frame =
        lhc::compress_block_with_strategy(&raw[..100_000], BlockStrategy::PortfolioPpmTrial)
            .unwrap();
    assert_eq!(&frame[..8], PPM_MAGIC);
    assert_eq!(lhc::decompress_block(&frame).unwrap(), &raw[..100_000]);
    let mut extended = frame.clone();
    extended.push(0);
    assert!(lhc::decompress_block(&extended).is_err());
    assert!(lhc::decompress_block(&frame[..frame.len() - 1]).is_err());
}
