use std::{fs, path::Path};
use unlhare::{Error, Limits, SourceEntry, khc};

fn crc(bytes: &[u8]) -> u32 {
    crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, bytes) as u32
}

fn field(bytes: &[u8], offset: usize) -> usize {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize
}

fn put(bytes: &mut [u8], offset: usize, value: usize) {
    bytes[offset..offset + 4].copy_from_slice(&(value as u32).to_le_bytes());
}

fn seal_block_crc(frame: &mut [u8]) {
    let mut wire = frame[..36].to_vec();
    wire.extend_from_slice(&frame[40..]);
    put(frame, 36, crc(&wire) as usize);
}

fn krs3_boundary_input(length: usize) -> Vec<u8> {
    assert!((1023..=1027).contains(&length));
    let mut next = [0u8; 128];
    let mut stack = vec![64u8];
    let mut reversed = Vec::with_capacity(1153);
    while let Some(&vertex) = stack.last() {
        let edge = next[usize::from(vertex)];
        if edge < 18 {
            next[usize::from(vertex)] += 1;
            let delta = if edge < 17 { edge + 1 } else { 32 };
            stack.push(vertex ^ delta);
        } else {
            reversed.push(stack.pop().unwrap());
        }
    }
    reversed.reverse();
    assert_eq!(reversed.len(), 1153);
    assert_eq!(reversed.first(), Some(&64));
    let mut raw = Vec::with_capacity(length);
    raw.push(255);
    raw.extend_from_slice(&reversed[..length - 1]);
    let mut pairs = [false; 65_536];
    for pair in raw.windows(2) {
        assert_ne!(pair[0], pair[1]);
        let key = (usize::from(pair[0]) << 8) | usize::from(pair[1]);
        assert!(!pairs[key]);
        pairs[key] = true;
    }
    raw
}

fn gather32_input(length: usize) -> Vec<u8> {
    let mut state = 0x6d2b79f5u32;
    (0..length)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            match state % 100 {
                0..=79 => b'A',
                80..=94 => b'B',
                95..=98 => b'C',
                _ => b'D',
            }
        })
        .collect()
}

#[derive(Clone)]
struct FrameInfo {
    file_name: String,
    block_index: usize,
    prefix: usize,
    start: usize,
    length: usize,
    magic: [u8; 8],
}

fn frame_infos(bytes: &[u8]) -> Vec<FrameInfo> {
    assert!(bytes.len() >= 32);
    assert_eq!(&bytes[..8], b"KHC1ARC\0");
    let entries = field(bytes, 16);
    let manifest_length = field(bytes, 20);
    let manifest_start = 32;
    let manifest_end = manifest_start + manifest_length;
    assert!(manifest_end <= bytes.len());
    let mut manifest_offset = manifest_start;
    let mut files = Vec::with_capacity(entries);
    for _ in 0..entries {
        assert!(manifest_offset + 20 <= manifest_end);
        let name_length = u16::from_le_bytes(
            bytes[manifest_offset..manifest_offset + 2]
                .try_into()
                .unwrap(),
        ) as usize;
        let is_directory = bytes[manifest_offset + 2] != 0;
        let size = u64::from_le_bytes(
            bytes[manifest_offset + 4..manifest_offset + 12]
                .try_into()
                .unwrap(),
        ) as usize;
        let name_start = manifest_offset + 20;
        let name_end = name_start + name_length;
        let file_name = std::str::from_utf8(&bytes[name_start..name_end])
            .unwrap()
            .to_owned();
        manifest_offset += 20 + name_length;
        assert!(manifest_offset <= manifest_end);
        files.push((file_name, is_directory, size));
    }
    assert_eq!(manifest_offset, manifest_end);

    let mut offset = manifest_end;
    let mut result = Vec::new();
    for (file_name, is_directory, size) in files {
        if is_directory {
            assert_eq!(size, 0);
            continue;
        }
        let mut remaining = size;
        let mut block_index = 0;
        while remaining != 0 {
            assert!(offset + 4 <= bytes.len());
            let length = field(bytes, offset);
            let start = offset + 4;
            assert!(length >= 8 && start + length <= bytes.len());
            let mut magic = [0; 8];
            magic.copy_from_slice(&bytes[start..start + 8]);
            result.push(FrameInfo {
                file_name: file_name.clone(),
                block_index,
                prefix: offset,
                start,
                length,
                magic,
            });
            offset = start + length;
            remaining -= remaining.min(khc::BLOCK_BYTES);
            block_index += 1;
        }
        assert!(offset + 4 <= bytes.len());
        offset += 4;
    }
    assert!(offset + 8 <= bytes.len());
    assert_eq!(&bytes[offset..offset + 8], b"KHC1END\0");
    assert_eq!(offset + 8, bytes.len());
    result
}

fn is_portfolio_fallback(frame: &[u8]) -> bool {
    if frame.get(..8) != Some(&b"KHC1BLK\0"[..]) || frame.len() < 12 {
        return false;
    }
    let revision = u16::from_le_bytes(frame[8..10].try_into().unwrap());
    let method = frame[10];
    matches!((revision, method), (1, 0 | 1) | (2, 0 | 1 | 3))
}

fn is_binary_adaptive_fallback(frame: &[u8]) -> bool {
    frame.get(..8) == Some(&b"KHC1BLK\0"[..])
        && frame.len() >= 12
        && u16::from_le_bytes(frame[8..10].try_into().unwrap()) == 2
        && matches!(frame[10], 0 | 1 | 3)
}

fn replace_frame(archive: &[u8], frame: &FrameInfo, replacement: &[u8]) -> Vec<u8> {
    let mut patched = Vec::with_capacity(archive.len() - frame.length + replacement.len());
    patched.extend_from_slice(&archive[..frame.prefix]);
    patched.extend_from_slice(&(replacement.len() as u32).to_le_bytes());
    patched.extend_from_slice(replacement);
    patched.extend_from_slice(&archive[frame.start + frame.length..]);
    patched
}

fn assert_rejected(
    root: &Path,
    index: usize,
    bad: &[u8],
    output_name: &str,
    expected_output: Option<&[u8]>,
) {
    let bad_path = root.join(format!("bad-{index}.khc"));
    fs::write(&bad_path, bad).unwrap();
    assert!(khc::verify_archive(&bad_path, &Limits::default()).is_err());
    // 不正frame群は部分出力しないため同じ小さな出力先を使う。
    // 完全entryの後でtrailerが壊れる2件だけは独立させる。
    let output = root.join(output_name);
    if !output.exists() {
        fs::create_dir(&output).unwrap();
        fs::write(output.join("sentinel"), b"keep").unwrap();
    }
    let sentinel = output.join("sentinel");
    let payload = output.join("payload.bin");
    assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
    assert!(!payload.exists(), "earlier rejection wrote an output file");
    assert!(khc::extract_archive(&bad_path, &output, &Limits::default()).is_err());
    assert_eq!(fs::read(sentinel).unwrap(), b"keep");
    if let Some(expected) = expected_output {
        if payload.exists() {
            assert_eq!(fs::read(payload).unwrap(), expected);
        }
    } else {
        assert!(!payload.exists(), "rejected frame produced an output file");
    }
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let root = Path::new(&args.next().expect("registered E2E subdirectory")).to_path_buf();
    let ptt5_path = Path::new(&args.next().expect("pinned development fixture")).to_path_buf();
    assert!(args.next().is_none());
    assert!(root.is_absolute() && !root.exists());
    assert!(ptt5_path.is_absolute() && ptt5_path.is_file());
    assert!(
        root.parent()
            .unwrap()
            .canonicalize()
            .unwrap()
            .starts_with(std::env::temp_dir().canonicalize().unwrap())
    );
    assert!(std::env::var_os("KHC_STORAGE_RUN_RECORD").is_some());
    fs::create_dir(&root).unwrap();

    let ptt5 = fs::read(&ptt5_path).unwrap();
    assert_eq!(ptt5.len(), 513_216);
    let mut seed = 7u32;
    let random: Vec<u8> = (0..32_768)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        })
        .collect();
    let legacy_bytes = b"legacy format compatibility\n".repeat(32);
    let krs3_raw = krs3_boundary_input(1027);
    let g32_raw = gather32_input(65_536);
    // pairが一意な1024B行を繰り返し、学習した幅1024の途中にliteralを置く。
    let mut spatial_width_1024 = krs3_boundary_input(1024).repeat(4);
    spatial_width_1024[3 * 1024 + 500] ^= 1;
    // Count0の折り畳み前後で、初回literal・copy128・zero literalを照合する。
    let folded_inputs = [
        vec![0xff; 64],
        vec![0xff; 129],
        [vec![0; 128], vec![0xff, 0], vec![0; 127]].concat(),
    ];
    let folded_frame_hex: Vec<String> = folded_inputs
        .iter()
        .map(|raw| {
            let frame =
                khc::compress_block_with_strategy(raw, khc::BlockStrategy::SpatialBitsTrial)
                    .unwrap();
            assert_eq!(
                frame[10], 1,
                "folded-count fixture must exercise range coding"
            );
            assert_eq!(khc::decompress_block(&frame).unwrap(), *raw);
            frame.iter().map(|byte| format!("{byte:02x}")).collect()
        })
        .collect();
    // S2登録run 3e8983eeee7146fe8729467941ab7b25から採取した完全frame。
    let expected_folded_frames = [
        "4b435331424c4b0001000100400000000800000006000000ba87610fd572c036000000000000000002000000403f0040007fb14e1100",
        "4b435331424c4b0001000100810000000b00000006000000ef200f802c7a2f260000000000000000030000ab2a01ab2a80aa2a00553db9247f",
        "4b435331424c4b0001000100010100000e000000070000007e864bccfa8545da000000000000000004000000200100207f002080002000dfefebcb6300",
    ];
    assert_eq!(folded_frame_hex, expected_folded_frames);
    let inputs = [
        Vec::new(),
        vec![0],
        vec![0; 10],
        vec![0; 11],
        vec![0; 127],
        vec![0; 128],
        vec![0; 16_383],
        vec![0; 16_384],
        random[..775].to_vec(),
        random[..776].to_vec(),
        spatial_width_1024,
        folded_inputs[0].clone(),
        folded_inputs[1].clone(),
        folded_inputs[2].clone(),
        (0..=255).collect(),
        (0..32_768).map(|n| b"abc0123456789\0"[n % 14]).collect(),
        random.clone(),
        ptt5.clone(),
        legacy_bytes.clone(),
        krs3_raw.clone(),
        vec![0; khc::BLOCK_BYTES - 1],
        vec![0; khc::BLOCK_BYTES],
    ];
    let candidates = [
        khc::BlockStrategy::Mdl,
        khc::BlockStrategy::SpatialBitsTrial,
        khc::BlockStrategy::RecordFastTrial,
        khc::BlockStrategy::RecordAdaptiveTrial,
    ];
    let expected_magics: [&[u8; 8]; 4] = [b"KHC1BLK\0", b"KCS1BLK\0", b"KRS2BLK\0", b"KRS3BLK\0"];
    for raw in &inputs {
        let mut best_strategy = candidates[0];
        let mut best_len = usize::MAX;
        for (index, candidate) in candidates.iter().copied().enumerate() {
            let frame = khc::compress_block_with_strategy(raw, candidate).unwrap();
            assert_eq!(
                frame,
                khc::compress_block_with_strategy(raw, candidate).unwrap(),
                "candidate frame must be deterministic: {candidate:?}"
            );
            let family_is_valid = match index {
                0 => {
                    frame.get(..8) == Some(&expected_magics[index][..])
                        && frame[8..10] == 1u16.to_le_bytes()
                }
                1 => frame.get(..8) == Some(&expected_magics[index][..]),
                _ => {
                    frame.get(..8) == Some(&expected_magics[index][..])
                        || is_binary_adaptive_fallback(&frame)
                }
            };
            assert!(family_is_valid, "candidate family: {candidate:?}");
            assert_eq!(khc::decompress_block(&frame).unwrap(), *raw);
            if frame.len() < best_len {
                best_strategy = candidate;
                best_len = frame.len();
            }
        }
        let expected = khc::compress_block_with_strategy(raw, best_strategy).unwrap();
        assert_eq!(expected.len(), best_len, "winner re-encode size");
        let frame =
            khc::compress_block_with_strategy(raw, khc::BlockStrategy::PortfolioTrial).unwrap();
        assert_eq!(frame, expected, "portfolio must select the strict minimum");
        assert_eq!(
            frame,
            khc::compress_block_with_strategy(raw, khc::BlockStrategy::PortfolioTrial).unwrap()
        );
        assert_eq!(khc::decompress_block(&frame).unwrap(), *raw);
        assert!(frame.len() <= khc::BLOCK_BYTES + 40);
    }
    assert!(
        khc::compress_block_with_strategy(
            &vec![0; khc::BLOCK_BYTES + 1],
            khc::BlockStrategy::PortfolioTrial,
        )
        .is_err()
    );

    let source = root.join("source");
    fs::create_dir(&source).unwrap();
    let large = vec![0; khc::BLOCK_BYTES + 257];
    fs::write(source.join("a-main.bin"), &large).unwrap();
    fs::write(source.join("empty.bin"), []).unwrap();
    fs::write(source.join("g32.bin"), &g32_raw).unwrap();
    fs::write(source.join("krs2.bin"), &legacy_bytes).unwrap();
    fs::write(source.join("krs3.bin"), &krs3_raw).unwrap();
    fs::write(source.join("legacy.bin"), &legacy_bytes).unwrap();
    fs::write(source.join("random.bin"), &random).unwrap();
    fs::write(source.join("short.bin"), b"literal!?").unwrap();

    let archive = root.join("api.khc");
    let options = khc::CreateOptions {
        block_strategy: khc::BlockStrategy::PortfolioTrial,
        ..Default::default()
    };
    let rejected_options = khc::CreateOptions {
        max_codec_memory_bytes: khc::CODEC_MEMORY_BYTES - 1,
        ..options.clone()
    };
    assert!(matches!(
        khc::create_from_directory(&source, &archive, &rejected_options),
        Err(Error::Limit(_))
    ));
    assert!(!archive.exists());
    khc::create_from_directory(&source, &archive, &options).unwrap();
    let original = fs::read(&archive).unwrap();
    assert_eq!(original[8], 10);
    assert_eq!(
        khc::list_archive(&archive, &Limits::default())
            .unwrap()
            .len(),
        8
    );
    khc::verify_archive(&archive, &Limits::default()).unwrap();
    let frames = frame_infos(&original);
    assert!(!frames.is_empty());
    for frame in &frames {
        match &frame.magic {
            b"KHC1BLK\0" => {
                let fallback = &original[frame.start..frame.start + frame.length];
                assert!(is_portfolio_fallback(fallback));
            }
            b"KCS1BLK\0" | b"KRS2BLK\0" | b"KRS3BLK\0" => {}
            _ => panic!("unexpected revision 10 family: {:?}", frame.magic),
        }
    }

    assert!(khc::create_from_directory(&source, &archive, &options).is_err());
    assert_eq!(fs::read(&archive).unwrap(), original);
    let output = root.join("api-output");
    khc::extract_archive(&archive, &output, &Limits::default()).unwrap();
    for name in [
        "a-main.bin",
        "empty.bin",
        "g32.bin",
        "krs2.bin",
        "krs3.bin",
        "legacy.bin",
        "random.bin",
        "short.bin",
    ] {
        assert_eq!(
            fs::read(source.join(name)).unwrap(),
            fs::read(output.join(name)).unwrap(),
            "API roundtrip {name}"
        );
    }
    assert!(khc::extract_archive(&archive, &output, &Limits::default()).is_err());
    assert_eq!(fs::read(output.join("a-main.bin")).unwrap(), large);

    let default_mdl = khc::compress_block(&large[..khc::BLOCK_BYTES]).unwrap();
    let stored_mdl = khc::compress_block(b"literal!?").unwrap();
    let kcs = khc::compress_block_with_strategy(
        &large[khc::BLOCK_BYTES..],
        khc::BlockStrategy::SpatialBitsTrial,
    )
    .unwrap();
    let krs2 =
        khc::compress_block_with_strategy(&legacy_bytes, khc::BlockStrategy::RecordFastTrial)
            .unwrap();
    assert_eq!(&krs2[..8], b"KRS2BLK\0");
    let krs3 =
        khc::compress_block_with_strategy(&krs3_raw, khc::BlockStrategy::RecordAdaptiveTrial)
            .unwrap();
    assert_eq!(&krs3[..8], b"KRS3BLK\0");

    let binary_stored =
        khc::compress_block_with_strategy(&random, khc::BlockStrategy::BinaryAdaptive).unwrap();
    assert_eq!(&binary_stored[..8], b"KHC1BLK\0");
    assert_eq!(&binary_stored[8..10], &2u16.to_le_bytes());
    assert_eq!(binary_stored[10], 0);
    let binary_mdl =
        khc::compress_block_with_strategy(&legacy_bytes, khc::BlockStrategy::BinaryAdaptive)
            .unwrap();
    assert_eq!(&binary_mdl[..8], b"KHC1BLK\0");
    assert_eq!(&binary_mdl[8..10], &2u16.to_le_bytes());
    assert_eq!(binary_mdl[10], 1);
    let binary_lz8 = khc::compress_block_with_strategy(
        &large[..khc::BLOCK_BYTES],
        khc::BlockStrategy::BinaryAdaptive,
    )
    .unwrap();
    assert_eq!(&binary_lz8[..8], b"KHC1BLK\0");
    assert_eq!(&binary_lz8[8..10], &2u16.to_le_bytes());
    assert_eq!(binary_lz8[10], 3);
    assert!(is_portfolio_fallback(&binary_stored));
    assert!(is_portfolio_fallback(&binary_mdl));
    assert!(is_portfolio_fallback(&binary_lz8));

    let replacements = [
        ("a-main.bin", 0, default_mdl.clone()),
        ("a-main.bin", 1, kcs.clone()),
        ("short.bin", 0, stored_mdl),
        ("random.bin", 0, binary_stored.clone()),
        ("legacy.bin", 0, binary_mdl.clone()),
        ("a-main.bin", 0, binary_lz8.clone()),
        ("krs2.bin", 0, krs2.clone()),
        ("krs3.bin", 0, krs3.clone()),
    ];
    let mut accepted_all = original.clone();
    for (file_name, block_index, replacement) in &replacements {
        let current_frames = frame_infos(&accepted_all);
        let frame = current_frames
            .iter()
            .find(|frame| {
                frame.file_name.as_str() == *file_name && frame.block_index == *block_index
            })
            .unwrap();
        accepted_all = replace_frame(&accepted_all, frame, replacement);
    }
    let accepted_path = root.join("accepted-all.khc");
    fs::write(&accepted_path, &accepted_all).unwrap();
    khc::verify_archive(&accepted_path, &Limits::default()).unwrap();
    let accepted_output = root.join("accepted-all-output");
    khc::extract_archive(&accepted_path, &accepted_output, &Limits::default()).unwrap();
    for name in [
        "a-main.bin",
        "empty.bin",
        "g32.bin",
        "krs2.bin",
        "krs3.bin",
        "legacy.bin",
        "random.bin",
        "short.bin",
    ] {
        assert_eq!(
            fs::read(source.join(name)).unwrap(),
            fs::read(accepted_output.join(name)).unwrap(),
            "allowed-frame roundtrip {name}"
        );
    }

    // 異常frameは1-entry archiveへ挿入する。全corruption caseを独立した小さい
    // fixtureにし、拒否後の部分出力が次のcaseへ混入しないようにする。
    let zero_block = &large[..khc::BLOCK_BYTES];
    let invalid_base_path = root.join("invalid-base.khc");
    khc::create_archive(
        &invalid_base_path,
        &[SourceEntry {
            path: source.join("g32.bin"),
            name: "payload.bin".into(),
        }],
        &options,
    )
    .unwrap();
    let invalid_base = fs::read(&invalid_base_path).unwrap();
    khc::verify_archive(&invalid_base_path, &Limits::default()).unwrap();
    let invalid_base_frames = frame_infos(&invalid_base);
    assert_eq!(
        khc::list_archive(&invalid_base_path, &Limits::default())
            .unwrap()
            .len(),
        1
    );
    assert_eq!(invalid_base_frames.len(), 1);
    let invalid_base_frame = invalid_base_frames
        .into_iter()
        .find(|frame| frame.file_name == "payload.bin" && frame.block_index == 0)
        .unwrap();
    assert_eq!(invalid_base_frame.file_name, "payload.bin");

    let invalid_kcs =
        khc::compress_block_with_strategy(zero_block, khc::BlockStrategy::SpatialBitsTrial)
            .unwrap();
    let mut corrupt_kcs = replace_frame(&invalid_base, &invalid_base_frame, &invalid_kcs);
    let kcs_info = frame_infos(&corrupt_kcs).into_iter().next().unwrap();
    corrupt_kcs[kcs_info.start + 28] ^= 1;
    assert_rejected(&root, 0, &corrupt_kcs, "rejected-frames", None);

    let mut corrupt_mdl = replace_frame(&invalid_base, &invalid_base_frame, &default_mdl);
    let mdl_info = frame_infos(&corrupt_mdl).into_iter().next().unwrap();
    corrupt_mdl[mdl_info.start + 36] ^= 1;
    assert_rejected(&root, 1, &corrupt_mdl, "rejected-frames", None);

    let truncated = &invalid_base[..invalid_base.len() - 1];
    let mut trailing = invalid_base.clone();
    trailing.push(0);
    assert_rejected(&root, 3, &trailing, "rejected-trailing", Some(&g32_raw));
    let mut unknown = invalid_base.clone();
    unknown[8] = 11;
    let header_crc = crc(&unknown[..28]);
    put(&mut unknown, 28, header_crc as usize);
    assert_rejected(&root, 4, &unknown, "rejected-frames", None);

    let foreign =
        khc::compress_block_with_strategy(zero_block, khc::BlockStrategy::RecordTrial).unwrap();
    assert_eq!(&foreign[..8], b"KRS1BLK\0");
    let wrong_krs1 = replace_frame(&invalid_base, &invalid_base_frame, &foreign);
    assert_rejected(&root, 5, &wrong_krs1, "rejected-frames", None);

    let gather32_base_path = root.join("gather32-base.khc");
    khc::create_archive(
        &gather32_base_path,
        &[SourceEntry {
            path: source.join("g32.bin"),
            name: "payload.bin".into(),
        }],
        &options,
    )
    .unwrap();
    let gather32_base = fs::read(&gather32_base_path).unwrap();
    khc::verify_archive(&gather32_base_path, &Limits::default()).unwrap();
    let gather32_base_frames = frame_infos(&gather32_base);
    assert_eq!(gather32_base_frames.len(), 1);
    let gather32_base_frame = gather32_base_frames.first().unwrap();
    let gather32 =
        khc::compress_block_with_strategy(&g32_raw, khc::BlockStrategy::Gather32Trial).unwrap();
    assert_eq!(&gather32[..8], b"KHCG32B\0");
    let wrong_gather32 = replace_frame(&gather32_base, gather32_base_frame, &gather32);
    assert_rejected(&root, 6, &wrong_gather32, "rejected-frames", None);

    let delta16 =
        khc::compress_block_with_strategy(zero_block, khc::BlockStrategy::Delta16Trial).unwrap();
    let wrong_delta16 = replace_frame(&invalid_base, &invalid_base_frame, &delta16);
    assert_rejected(&root, 7, &wrong_delta16, "rejected-frames", None);

    let mut unsupported_v2 = binary_lz8;
    unsupported_v2[10] = 2;
    seal_block_crc(&mut unsupported_v2);
    let wrong_v2_method = replace_frame(&invalid_base, &invalid_base_frame, &unsupported_v2);
    assert_rejected(&root, 8, &wrong_v2_method, "rejected-frames", None);
    assert_rejected(&root, 2, truncated, "rejected-truncated", Some(&g32_raw));
    fs::copy(root.join("bad-5.khc"), root.join("bad.khc")).unwrap();

    let legacy_file = root.join("legacy.bin");
    fs::write(&legacy_file, &legacy_bytes).unwrap();
    let legacy_strategies = [
        (1, khc::BlockStrategy::Mdl),
        (2, khc::BlockStrategy::HybridTrial),
        (3, khc::BlockStrategy::RecordTrial),
        (4, khc::BlockStrategy::Gather32Trial),
        (5, khc::BlockStrategy::Delta16Trial),
        (6, khc::BlockStrategy::RecordFastTrial),
        (7, khc::BlockStrategy::SpatialBitsTrial),
        (8, khc::BlockStrategy::RecordAdaptiveTrial),
        (9, khc::BlockStrategy::SpatialMdlTrial),
    ];
    let legacy_output = root.join("legacy-compat-output");
    for (revision, strategy) in legacy_strategies {
        let path = root.join(format!("legacy-{revision}.khc"));
        let name = format!("legacy-{revision}.bin");
        khc::create_archive(
            &path,
            &[SourceEntry {
                path: legacy_file.clone(),
                name: name.clone(),
            }],
            &khc::CreateOptions {
                block_strategy: strategy,
                ..Default::default()
            },
        )
        .unwrap();
        let bytes = fs::read(&path).unwrap();
        assert_eq!(bytes[8], revision);
        khc::verify_archive(&path, &Limits::default()).unwrap();
        khc::extract_archive(&path, &legacy_output, &Limits::default()).unwrap();
        assert_eq!(fs::read(legacy_output.join(name)).unwrap(), legacy_bytes);
    }

    println!(
        "{{\"schema\":1,\"revision\":10,\"frame_count\":{},\"allowed_families\":[\"KHC1BLK-v1-MDL-0/1\",\"KHC1BLK-v2-BinaryAdaptive-0/1/3\",\"KCS1BLK\",\"KRS2BLK\",\"KRS3BLK\"],\"malformed_archives_rejected\":9,\"legacy_revisions\":[1,2,3,4,5,6,7,8,9],\"memory_reservation_guard_tested\":true,\"archive_bytes\":{},\"folded_zero_count_frames\":{}}}",
        frames.len(),
        original.len(),
        serde_json::to_string(&folded_frame_hex).unwrap()
    );
}
