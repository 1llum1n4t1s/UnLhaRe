//! 明示revision2をpublic API/実CLIで復元し、拒否と非公開を観測するE2E。
use crc_fast::{CrcAlgorithm, Digest};
use std::{fs, path::PathBuf, process::Command};
use unlhare::{
    Limits,
    khc::{self, BlockStrategy},
};
#[path = "common/khc_e2e_root.rs"]
mod khc_e2e_root;
fn seal(frame: &mut [u8]) {
    let mut d = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    d.update(&frame[..36]);
    d.update(&frame[40..]);
    frame[36..40].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
}
fn root() -> PathBuf {
    let root = khc_e2e_root::path("hybrid");
    fs::create_dir_all(&root).unwrap();
    root
}
// 製品モデルを借りず、初期確率1/2の異なるノードだけを通る悪性tokenを作る。
fn malformed_frame(method: u8, bits: &[u8]) -> Vec<u8> {
    let mut low = 0u64;
    let mut range = u32::MAX;
    let mut cache = 0u8;
    let mut pending = 1usize;
    let mut payload = Vec::new();
    let shift = |low: &mut u64, cache: &mut u8, pending: &mut usize, out: &mut Vec<u8>| {
        let lower = *low as u32;
        let carry = (*low >> 32) as u8;
        if lower < 0xff00_0000 || carry != 0 {
            out.push(cache.wrapping_add(carry));
            out.resize(out.len() + *pending - 1, 255u8.wrapping_add(carry));
            *pending = 0;
            *cache = (lower >> 24) as u8;
        }
        *pending += 1;
        *low = u64::from((lower & 0x00ff_ffff) << 8);
    };
    for &bit in bits {
        let unit = range / 32768;
        low += u64::from(unit) * u64::from(bit) * 16384;
        range = unit * 16384;
        while range < 1 << 24 {
            range <<= 8;
            shift(&mut low, &mut cache, &mut pending, &mut payload);
        }
    }
    for _ in 0..5 {
        shift(&mut low, &mut cache, &mut pending, &mut payload);
    }
    assert!((5..32).contains(&payload.len()));
    let mut frame = vec![0; 40];
    frame[..8].copy_from_slice(b"KHC1BLK\0");
    frame[8..10].copy_from_slice(&2u16.to_le_bytes());
    frame[10] = method;
    frame[12..16].copy_from_slice(&32u32.to_le_bytes());
    frame[24..28].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    let mut crc = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    crc.update(&[0; 32]);
    frame[32..36].copy_from_slice(&(crc.finalize() as u32).to_le_bytes());
    frame.extend_from_slice(&payload);
    seal(&mut frame);
    frame
}
#[test]
fn public_hybrid_frames_and_real_archive_routes() {
    let root = root();
    let strategies = [
        BlockStrategy::Mdl,
        BlockStrategy::HybridTrial,
        BlockStrategy::BinaryAdaptive,
    ];
    let mut vectors = 0;
    let mut rejects = 0;
    let mut methods = [false; 4];
    for n in [
        0,
        1,
        2,
        3,
        4,
        255,
        256,
        257,
        4095,
        4096,
        4097,
        65536,
        khc::BLOCK_BYTES - 1,
        khc::BLOCK_BYTES,
    ] {
        for pattern in 0..4 {
            let mut state = 0x6d2b79f5u32;
            let raw: Vec<u8> = (0..n)
                .map(|i| {
                    state ^= state << 13;
                    state ^= state >> 17;
                    state ^= state << 5;
                    match pattern {
                        0 => 7,
                        1 => i as u8,
                        2 => ((i * 173 + i * i * 13) & 255) as u8,
                        _ => state as u8,
                    }
                })
                .collect();
            let legacy = khc::compress_block(&raw).unwrap();
            for strategy in strategies {
                let frame = khc::compress_block_with_strategy(&raw, strategy).unwrap();
                assert_eq!(khc::decompress_block(&frame).unwrap(), raw);
                assert!(frame.len() <= raw.len() + 40);
                methods[frame[10] as usize] = true;
                if strategy == BlockStrategy::Mdl {
                    assert_eq!(frame, legacy);
                } else {
                    assert_eq!(&frame[8..10], &2u16.to_le_bytes());
                }
            }
            vectors += 1;
        }
    }
    for strategy in strategies {
        assert!(
            khc::compress_block_with_strategy(&vec![0; khc::BLOCK_BYTES + 1], strategy).is_err()
        );
    }
    let raw = vec![7; 4096];
    let witness = khc::compress_block_with_strategy(&raw, BlockStrategy::HybridTrial).unwrap();
    assert!(witness[10] >= 2);
    let mut witnesses = vec![witness];
    // 二つのliteral文脈はmethodで明示する。反復一字では同payloadなので合法に両方確認できる。
    let mut other = witnesses[0].clone();
    other[10] = if other[10] == 2 { 3 } else { 2 };
    seal(&mut other);
    assert_eq!(khc::decompress_block(&other).unwrap(), raw);
    witnesses.push(other);
    let text =
        b"Public hybrid API keeps integer probabilities and explicit revisions. ".repeat(100);
    let mdl = khc::compress_block_with_strategy(&text, BlockStrategy::BinaryAdaptive).unwrap();
    assert_eq!(mdl[10], 1);
    witnesses.push(mdl);
    let mut semantic_rejects = 0;
    for method in [2, 3] {
        // 最初のtokenがdistance1/length3のmatch：復元済みbyteがなく参照不能。
        let past = [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        // literal Aの後、distance1/length4096：宣言raw32を超過する。
        let extent = [
            0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 0,
        ];
        // 新distanceのlog31：シフト・確保前に整数上限を拒否する。
        let log = [1, 1, 1, 1, 1, 1, 1];
        for (bits, reason) in [
            (&past[..], "match offset/extent"),
            (&extent[..], "match offset/extent"),
            (&log[..], "number log bound"),
        ] {
            let bad = malformed_frame(method, bits);
            let error = khc::decompress_block(&bad).unwrap_err().to_string();
            assert!(error.contains(reason), "method {method}: {error}");
            semantic_rejects += 1;
            assert_eq!(khc::decompress_block(&witnesses[0]).unwrap(), raw);
        }
    }
    for good in witnesses {
        let plain = khc::decompress_block(&good).unwrap();
        for offset in [
            0,
            8,
            10,
            11,
            12,
            16,
            20,
            24,
            28,
            30,
            32,
            36,
            40,
            good.len() - 1,
        ] {
            let mut bad = good.clone();
            bad[offset] ^= 128;
            if offset != 0 && offset != 36 {
                seal(&mut bad);
            }
            assert!(
                khc::decompress_block(&bad).is_err(),
                "corruption offset {offset}"
            );
            rejects += 1;
            assert_eq!(khc::decompress_block(&good).unwrap(), plain);
        }
        for len in 0..good.len() {
            assert!(khc::decompress_block(&good[..len]).is_err());
            rejects += 1;
        }
        let mut extra = good.clone();
        extra.push(0);
        assert!(khc::decompress_block(&extra).is_err());
        rejects += 1;
        let mut old = good.clone();
        old[8..10].copy_from_slice(&1u16.to_le_bytes());
        seal(&mut old);
        if good[10] >= 2 {
            assert!(khc::decompress_block(&old).is_err());
            rejects += 1;
        }
    }
    let source = root.join("source");
    fs::create_dir_all(source.join("日本語")).unwrap();
    fs::write(source.join("日本語/data"), &raw).unwrap();
    fs::write(source.join("text"), &text).unwrap();
    fs::write(source.join("empty"), []).unwrap();
    let cli = env!("CARGO_BIN_EXE_unlhare-cli");
    let mut archives = Vec::new();
    for strategy in ["mdl", "hybrid-trial", "binary-adaptive"] {
        let archive = root.join(format!("{strategy}.khc"));
        let output = root.join(strategy);
        for args in [
            vec![
                "khc-create",
                archive.to_str().unwrap(),
                "--source",
                source.to_str().unwrap(),
                "--strategy",
                strategy,
            ],
            vec!["khc-list", archive.to_str().unwrap(), "--json"],
            vec!["khc-test", archive.to_str().unwrap()],
            vec![
                "khc-extract",
                archive.to_str().unwrap(),
                "--output",
                output.to_str().unwrap(),
            ],
        ] {
            let result = Command::new(cli).args(&args).output().unwrap();
            assert!(result.status.success(), "{args:?}: {result:?}");
        }
        for name in ["日本語/data", "text", "empty"] {
            assert_eq!(
                fs::read(output.join(name)).unwrap(),
                fs::read(source.join(name)).unwrap()
            );
        }
        assert!(khc::extract_archive(&archive, &output, &Limits::default()).is_err());
        let bytes = fs::read(&archive).unwrap();
        assert_eq!(bytes[8], if strategy == "mdl" { 1 } else { 2 });
        archives.push((strategy, bytes.len()));
        if strategy == "hybrid-trial" {
            // 再封印したarchive1へ新block2を混入してもlist/verify/extractは拒否する。
            let mut downgraded = bytes.clone();
            downgraded[8] = 1;
            let mut d = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
            d.update(&downgraded[..28]);
            downgraded[28..32].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
            let bad = root.join("downgraded.khc");
            fs::write(&bad, downgraded).unwrap();
            assert!(khc::list_archive(&bad, &Limits::default()).is_err());
            assert!(khc::verify_archive(&bad, &Limits::default()).is_err());
            let failed = root.join("failed");
            assert!(khc::extract_archive(&bad, &failed, &Limits::default()).is_err());
            assert!(!failed.join("日本語/data").exists());
        }
    }
    assert!(methods[0] && methods[2]);
    fs::write(root.join("result.json"),serde_json::to_vec_pretty(&serde_json::json!({"vectors":vectors,"strategies":3,"byte_exact":true,"default_byte_unchanged":true,"rejects":rejects,"semantic_rejects":semantic_rejects,"methods":methods,"cli_archives":archives,"no_clobber":true,"downgrade_rejected":true})).unwrap()).unwrap();
}
