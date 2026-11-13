//! 登録runner内で製品KCS1/KRS3 API・書庫・公開を確認する有限E2E。unit testではない。
#[path = "../src/lhc/block/multi_range.rs"]
#[allow(dead_code)]
mod range;
use std::{fs, path::Path};
use unlhare::{Error, Limits, SourceEntry, lhc};

fn crc(b: &[u8]) -> u32 {
    crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, b) as u32
}
fn field(b: &[u8], p: usize) -> usize {
    u32::from_le_bytes(b[p..p + 4].try_into().unwrap()) as usize
}
fn put(b: &mut [u8], p: usize, n: usize) {
    b[p..p + 4].copy_from_slice(&(n as u32).to_le_bytes());
}
fn seal(b: &mut [u8]) {
    let mut d = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[..28]);
    d.update(&b[32..]);
    b[28..32].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
}
fn reject_frame(bad: &[u8], valid: &[u8], raw: &[u8]) {
    assert!(lhc::decompress_block(bad).is_err());
    assert_eq!(lhc::decompress_block(valid).unwrap(), raw);
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
    let mut pairs = [false; 65536];
    for pair in raw.windows(2) {
        assert_ne!(pair[0], pair[1]);
        let key = (usize::from(pair[0]) << 8) | usize::from(pair[1]);
        assert!(!pairs[key], "KRS3 boundary input repeated an adjacent pair");
        pairs[key] = true;
    }
    let mut classes = [length, 0, 0, 0];
    for (index, &byte) in raw.iter().enumerate() {
        let predictor = index.checked_sub(1).map_or(0, |at| raw[at]);
        let class = if predictor == 0 {
            1
        } else if predictor == 255 {
            2
        } else {
            3
        };
        classes[class] += 1;
        assert_ne!(byte ^ predictor, 0);
    }
    assert_eq!(classes, [length, 1, 1, length - 2]);
    raw
}
fn unhex(input: &str) -> Vec<u8> {
    assert_eq!(input.len() % 2, 0);
    input
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}
fn krs3_trial_e2e(root: &Path, legacy: &[u8]) -> (Vec<usize>, usize, usize, usize) {
    const KRS2_GOLDEN: &str = "4B525332424C4B00020001008003000050000000160000007EE2103182FE37D506000000000000000300003C7806E203E1E20301006C00800000140001880802CC0C0688080988080B45040CCC0C0D45040E450411450415CC0C1945041A45041D88081F45044345044644044944045444045944046344041407000B1C00009E9EC601AFAC76301836196C843FEA5C0D96DE982E";
    let golden = unhex(KRS2_GOLDEN);
    assert_eq!(golden.len(), 148);
    let krs2 =
        lhc::compress_block_with_strategy(legacy, lhc::BlockStrategy::RecordFastTrial).unwrap();
    assert_eq!(krs2, golden, "KRS2 pre-candidate bytes changed");
    assert_eq!(lhc::decompress_block(&krs2).unwrap(), legacy);

    let mut adaptive_frames = Vec::new();
    let mut final_raw = Vec::new();
    let mut final_frame = Vec::new();
    for length in [1023, 1024, 1025, 1026, 1027] {
        let raw = krs3_boundary_input(length);
        let frame =
            lhc::compress_block_with_strategy(&raw, lhc::BlockStrategy::RecordAdaptiveTrial)
                .unwrap();
        assert_eq!(&frame[..8], b"KRS3BLK\0");
        assert_eq!(u16::from_le_bytes(frame[8..10].try_into().unwrap()), 3);
        assert!(frame.len() < raw.len());
        assert_eq!(
            frame,
            lhc::compress_block_with_strategy(&raw, lhc::BlockStrategy::RecordAdaptiveTrial,)
                .unwrap()
        );
        assert_eq!(lhc::decompress_block(&frame).unwrap(), raw);
        adaptive_frames.push(frame.len());
        final_raw = raw;
        final_frame = frame;
    }

    let mut malformed = Vec::new();
    for length in [0, 7, 8, 39, final_frame.len() - 1] {
        malformed.push(final_frame[..length].to_vec());
    }
    let mut bad = final_frame.clone();
    bad[0] ^= 1;
    malformed.push(bad);
    for (offset, value) in [(8, 2), (10, 2), (11, 1)] {
        let mut bad = final_frame.clone();
        bad[offset] = value;
        seal(&mut bad);
        malformed.push(bad);
    }
    for offset in [12, 16, 20, 32] {
        let mut bad = final_frame.clone();
        let value = field(&bad, offset) + 1;
        put(&mut bad, offset, value);
        seal(&mut bad);
        malformed.push(bad);
    }
    let mut bad = final_frame.clone();
    bad[24] ^= 1;
    seal(&mut bad);
    malformed.push(bad);
    for offset in [28, final_frame.len() - 1] {
        let mut bad = final_frame.clone();
        bad[offset] ^= 1;
        malformed.push(bad);
    }
    let mut bad = final_frame.clone();
    bad.push(0);
    malformed.push(bad);
    let malformed_count = malformed.len();
    for bad in malformed {
        reject_frame(&bad, &final_frame, &final_raw);
    }

    let mut fallback_inputs = vec![Vec::new(), vec![0], vec![0; 5]];
    let mut seed = 0x9e37_79b9u32;
    fallback_inputs.push(
        (0..4096)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                seed as u8
            })
            .collect(),
    );
    for raw in &fallback_inputs {
        let frame = lhc::compress_block_with_strategy(raw, lhc::BlockStrategy::RecordAdaptiveTrial)
            .unwrap();
        assert_eq!(&frame[..8], b"LHC1BLK\0");
        assert_eq!(lhc::decompress_block(&frame).unwrap(), *raw);
    }

    let source = root.join("adaptive-source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("a-main.bin"), &final_raw).unwrap();
    fs::write(source.join("empty.bin"), []).unwrap();
    fs::write(source.join("short.bin"), [0; 5]).unwrap();
    let options = lhc::CreateOptions {
        block_strategy: lhc::BlockStrategy::RecordAdaptiveTrial,
        ..Default::default()
    };
    let archive = root.join("adaptive-api.lhc");
    let gate = lhc::CreateOptions {
        max_codec_memory_bytes: lhc::CODEC_MEMORY_BYTES - 1,
        ..options.clone()
    };
    assert!(matches!(
        lhc::create_from_directory(&source, &archive, &gate),
        Err(Error::Limit(_))
    ));
    assert!(!archive.exists());
    lhc::create_from_directory(&source, &archive, &options).unwrap();
    let original = fs::read(&archive).unwrap();
    assert_eq!(original[8], 8);
    assert_eq!(
        lhc::list_archive(&archive, &Limits::default())
            .unwrap()
            .len(),
        3
    );
    lhc::verify_archive(&archive, &Limits::default()).unwrap();
    let frame = 32 + field(&original, 20) + 4;
    let frame_len = field(&original, frame - 4);
    assert_eq!(&original[frame..frame + frame_len], final_frame);
    // 最初のfile CRC、空file CRC、次frameの長さprefixを越える。
    let fallback = frame + frame_len + 12;
    assert_eq!(&original[fallback..fallback + 8], b"LHC1BLK\0");
    let output = root.join("adaptive-api-out");
    lhc::extract_archive(&archive, &output, &Limits::default()).unwrap();
    for file in ["a-main.bin", "empty.bin", "short.bin"] {
        assert_eq!(
            fs::read(source.join(file)).unwrap(),
            fs::read(output.join(file)).unwrap()
        );
    }
    assert!(lhc::create_from_directory(&source, &archive, &options).is_err());
    assert_eq!(fs::read(&archive).unwrap(), original);
    assert!(lhc::extract_archive(&archive, &output, &Limits::default()).is_err());
    assert_eq!(fs::read(output.join("a-main.bin")).unwrap(), final_raw);

    let mut cases = Vec::new();
    for offset in [12, 24, 28] {
        let mut bad = original.clone();
        bad[frame + offset] ^= 1;
        if offset != 28 {
            seal(&mut bad[frame..frame + frame_len]);
        }
        cases.push(bad);
    }
    let mut bad = original.clone();
    bad[frame + frame_len] ^= 1; // file CRC
    cases.push(bad);
    cases.push(original[..frame + frame_len - 1].to_vec());
    for revision in 1..=7 {
        let mut bad = original.clone();
        bad[8] = revision;
        let header_crc = crc(&bad[..28]);
        put(&mut bad, 28, header_crc as usize);
        cases.push(bad);
    }
    // 有効な旧familyもrevision 8へ直接混入させない。
    for old_strategy in [
        lhc::BlockStrategy::RecordTrial,
        lhc::BlockStrategy::Delta16Trial,
        lhc::BlockStrategy::SpatialBitsTrial,
    ] {
        let old_frame = lhc::compress_block_with_strategy(&final_raw, old_strategy).unwrap();
        let mut bad = original.clone();
        put(&mut bad, frame - 4, old_frame.len());
        bad.splice(frame..frame + frame_len, old_frame);
        cases.push(bad);
    }
    for magic in [b"KRS2BLK\0", b"LHCG32B\0"] {
        let mut bad = original.clone();
        bad[frame..frame + 8].copy_from_slice(magic);
        seal(&mut bad[frame..frame + frame_len]);
        cases.push(bad);
    }
    let bad_path = root.join("adaptive-bad.lhc");
    let rejected_output = root.join("adaptive-rejected");
    fs::create_dir(&rejected_output).unwrap();
    fs::write(rejected_output.join("sentinel"), b"keep").unwrap();
    let archive_cases = cases.len();
    for bad in cases {
        fs::write(&bad_path, bad).unwrap();
        assert!(lhc::verify_archive(&bad_path, &Limits::default()).is_err());
        assert!(lhc::extract_archive(&bad_path, &rejected_output, &Limits::default()).is_err());
        assert_eq!(fs::read(rejected_output.join("sentinel")).unwrap(), b"keep");
        assert_eq!(fs::read_dir(&rejected_output).unwrap().count(), 1);
        lhc::verify_archive(&archive, &Limits::default()).unwrap();
    }

    (
        adaptive_frames,
        malformed_count,
        fallback_inputs.len(),
        archive_cases,
    )
}
// 独立に組み立てたcount文法。product encoderを通らない悪性streamを作る。
fn forged(counts: &[u8], zero_literal: bool, skew: bool) -> Vec<u8> {
    let mut symbols = counts.to_vec();
    symbols.sort_unstable();
    symbols.dedup();
    assert!(symbols.len() <= 2);
    let mut frequencies = vec![32768u32 / symbols.len() as u32; symbols.len()];
    if skew {
        frequencies[0] -= 1;
        frequencies[1] += 1;
    }
    let mut meta = (symbols.len() as u16).to_le_bytes().to_vec();
    for (&b, &f) in symbols.iter().zip(&frequencies) {
        meta.push(b);
        meta.extend_from_slice(&(f as u16).to_le_bytes());
    }
    let mut enc = range::Encoder::with_limit(4096).unwrap();
    for b in counts {
        let i = symbols.iter().position(|s| s == b).unwrap();
        enc.interval(frequencies[..i].iter().sum(), frequencies[i], 32768)
            .unwrap();
    }
    if zero_literal {
        let mut p = 16384u32;
        for _ in 0..8 {
            enc.interval(0, p, 32768).unwrap();
            p += (32768 - p).div_ceil(32);
        }
    }
    let payload = enc.finish().unwrap();
    let mut out = vec![0; 40];
    out[..8].copy_from_slice(b"KCS1BLK\0");
    out[8] = 1;
    out[10] = 1;
    put(&mut out, 12, 4096);
    put(&mut out, 16, meta.len());
    put(&mut out, 20, payload.len());
    put(&mut out, 24, crc(&vec![0; 4096]) as usize);
    out.extend(meta);
    out.extend(payload);
    seal(&mut out);
    out
}
fn main() {
    let arg = std::env::args_os()
        .nth(1)
        .expect("new registered Temp subdirectory");
    let root = Path::new(&arg);
    assert!(root.is_absolute() && !root.exists());
    assert!(
        root.parent()
            .unwrap()
            .canonicalize()
            .unwrap()
            .starts_with(std::env::temp_dir().canonicalize().unwrap())
    );
    assert!(std::env::var_os("LHC_STORAGE_RUN_RECORD").is_some());
    fs::create_dir(root).unwrap();
    let strategy = lhc::BlockStrategy::SpatialBitsTrial;
    let mut seed = 7u32;
    let random: Vec<u8> = (0..16384)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        })
        .collect();
    let normal = [
        Vec::new(),
        vec![0],
        vec![255; 9],
        vec![0; 4096],
        (0..8192).map(|n| n as u8).collect(),
        (0..8192).map(|n| b"abc0123456789\0"[n % 14]).collect(),
        (0..8192)
            .map(|n| if n < 4096 { 0 } else { (n % 251) as u8 })
            .collect(),
        random,
        vec![0; lhc::BLOCK_BYTES],
    ];
    let mut seen = [false; 2];
    for raw in &normal {
        let frame = lhc::compress_block_with_strategy(raw, strategy).unwrap();
        assert_eq!(&frame[..8], b"KCS1BLK\0");
        assert!(frame.len() <= raw.len() + 40);
        assert_eq!(
            frame,
            lhc::compress_block_with_strategy(raw, strategy).unwrap()
        );
        assert_eq!(lhc::decompress_block(&frame).unwrap(), *raw);
        seen[frame[10] as usize] = true;
    }
    assert_eq!(seen, [true, true]);
    assert!(lhc::compress_block_with_strategy(&vec![0; lhc::BLOCK_BYTES + 1], strategy).is_err());
    let raw = vec![0; 4096];
    let valid = lhc::compress_block_with_strategy(&raw, strategy).unwrap();
    assert_eq!(valid[10], 1);
    let mut rejected = 0;
    for len in [0, 7, 8, 39, valid.len() - 1] {
        reject_frame(&valid[..len], &valid, &raw);
        rejected += 1;
    }
    for offset in [0, 8, 9, 10, 11, 24, 28, 32, 39] {
        let mut bad = valid.clone();
        bad[offset] ^= 128;
        if offset != 28 {
            seal(&mut bad);
        }
        reject_frame(&bad, &valid, &raw);
        rejected += 1;
    }
    for (offset, value) in [
        (12, lhc::BLOCK_BYTES + 1),
        (16, 771),
        (20, u32::MAX as usize),
    ] {
        let mut bad = valid.clone();
        put(&mut bad, offset, value);
        seal(&mut bad);
        reject_frame(&bad, &valid, &raw);
        rejected += 1;
    }
    let mut bad = valid.clone();
    bad.push(0);
    reject_frame(&bad, &valid, &raw);
    rejected += 1;
    let mut bad = valid.clone();
    bad.push(0);
    put(&mut bad, 20, field(&valid, 20) + 1);
    seal(&mut bad);
    reject_frame(&bad, &valid, &raw);
    rejected += 1;
    let mut bad = valid.clone();
    let last = bad.len() - 1;
    bad[last] ^= 1;
    seal(&mut bad);
    reject_frame(&bad, &valid, &raw);
    rejected += 1;
    // CDF support、frequency、range初期code、count・literal・CDF正規化。
    for offset in [40, 43, 40 + field(&valid, 16)] {
        let mut bad = valid.clone();
        bad[offset] = 255;
        seal(&mut bad);
        reject_frame(&bad, &valid, &raw);
        rejected += 1;
    }
    let zero_residual = forged(&[0], true, false);
    assert!(matches!(
        lhc::decompress_block(&zero_residual),
        Err(Error::Format(message)) if message == "zero residual/nonmaximal copy"
    ));
    reject_frame(&zero_residual, &valid, &raw);
    rejected += 1;
    for bad in [
        forged(&[128, 0], false, false),
        forged(&[128, 128, 128], false, false),
        forged(&[129, 32], false, false),
        forged(&[128, 32], false, true),
    ] {
        reject_frame(&bad, &valid, &raw);
        rejected += 1;
    }
    let source = root.join("source");
    fs::create_dir(&source).unwrap();
    let large = vec![0; lhc::BLOCK_BYTES + 257];
    fs::write(source.join("a-main.bin"), &large).unwrap();
    fs::write(source.join("empty.bin"), []).unwrap();
    fs::write(source.join("short.bin"), b"literal!?").unwrap();
    let options = lhc::CreateOptions {
        block_strategy: strategy,
        ..Default::default()
    };
    let archive = root.join("api.lhc");
    let gate = lhc::CreateOptions {
        max_codec_memory_bytes: lhc::CODEC_MEMORY_BYTES - 1,
        ..options.clone()
    };
    assert!(matches!(
        lhc::create_from_directory(&source, &archive, &gate),
        Err(Error::Limit(_))
    ));
    assert!(!archive.exists());
    lhc::create_from_directory(&source, &archive, &options).unwrap();
    let original = fs::read(&archive).unwrap();
    assert_eq!(original[8], 7);
    assert_eq!(
        lhc::list_archive(&archive, &Limits::default())
            .unwrap()
            .len(),
        3
    );
    lhc::verify_archive(&archive, &Limits::default()).unwrap();
    assert!(lhc::create_from_directory(&source, &archive, &options).is_err());
    assert_eq!(fs::read(&archive).unwrap(), original);
    let output = root.join("api-out");
    lhc::extract_archive(&archive, &output, &Limits::default()).unwrap();
    for file in ["a-main.bin", "empty.bin", "short.bin"] {
        assert_eq!(
            fs::read(source.join(file)).unwrap(),
            fs::read(output.join(file)).unwrap()
        );
    }
    assert!(lhc::extract_archive(&archive, &output, &Limits::default()).is_err());
    assert_eq!(fs::read(output.join("a-main.bin")).unwrap(), large);
    let frame = 32 + field(&original, 20) + 4;
    assert_eq!(&original[frame..frame + 8], b"KCS1BLK\0");
    let frame_len = field(&original, frame - 4);
    let bad_path = root.join("bad.lhc");
    let rejected_output = root.join("rejected");
    fs::create_dir(&rejected_output).unwrap();
    fs::write(rejected_output.join("sentinel"), b"keep").unwrap();
    let mut archive_cases = Vec::new();
    let mut bad = original.clone();
    put(&mut bad, frame + 12, lhc::BLOCK_BYTES - 1);
    seal(&mut bad[frame..frame + frame_len]);
    archive_cases.push(bad);
    let mut bad = original.clone();
    bad[frame + 24] ^= 1;
    seal(&mut bad[frame..frame + frame_len]);
    archive_cases.push(bad);
    let mut bad = original.clone();
    bad[frame + 28] ^= 1;
    archive_cases.push(bad);
    archive_cases.push(original[..frame + frame_len - 1].to_vec());
    let mut bad = original.clone();
    bad[8] = 6;
    let header_crc = crc(&bad[..28]);
    put(&mut bad, 28, header_crc as usize);
    archive_cases.push(bad);
    for bad in archive_cases {
        fs::write(&bad_path, &bad).unwrap();
        assert!(lhc::verify_archive(&bad_path, &Limits::default()).is_err());
        assert!(lhc::extract_archive(&bad_path, &rejected_output, &Limits::default()).is_err());
        assert_eq!(fs::read(rejected_output.join("sentinel")).unwrap(), b"keep");
        assert_eq!(fs::read_dir(&rejected_output).unwrap().count(), 1);
        lhc::verify_archive(&archive, &Limits::default()).unwrap();
    }
    let legacy_file = root.join("legacy.bin");
    let legacy_bytes = b"legacy format compatibility\n".repeat(32);
    fs::write(&legacy_file, &legacy_bytes).unwrap();
    let (adaptive_frames, adaptive_malformed, adaptive_fallbacks, adaptive_archive_cases) =
        krs3_trial_e2e(root, &legacy_bytes);
    for (revision, block_strategy) in [
        (1, lhc::BlockStrategy::Mdl),
        (2, lhc::BlockStrategy::HybridTrial),
        (3, lhc::BlockStrategy::RecordTrial),
        (4, lhc::BlockStrategy::Gather32Trial),
        (5, lhc::BlockStrategy::Delta16Trial),
        (6, lhc::BlockStrategy::RecordFastTrial),
        (7, lhc::BlockStrategy::SpatialBitsTrial),
    ] {
        let p = root.join(format!("legacy-{revision}.lhc"));
        lhc::create_archive(
            &p,
            &[SourceEntry {
                path: legacy_file.clone(),
                name: "legacy.bin".into(),
            }],
            &lhc::CreateOptions {
                block_strategy,
                ..Default::default()
            },
        )
        .unwrap();
        let archive_bytes = fs::read(&p).unwrap();
        assert_eq!(archive_bytes[8], revision);
        let frame = 32 + field(&archive_bytes, 20) + 4;
        assert!(frame + 8 <= archive_bytes.len());
        if revision == 6 {
            assert_eq!(&archive_bytes[frame..frame + 8], b"KRS2BLK\0");
        }
        lhc::verify_archive(&p, &Limits::default()).unwrap();
        let output = root.join(format!("legacy-out-{revision}"));
        lhc::extract_archive(&p, &output, &Limits::default()).unwrap();
        assert_eq!(fs::read(output.join("legacy.bin")).unwrap(), legacy_bytes);
    }
    println!(
        "{{\"normal_frames\":{},\"malformed_frames\":{rejected},\"recovery_frames\":{rejected},\"malformed_archives\":5,\"legacy_revisions\":[1,2,3,4,5,6,7],\"revision6_frame_magic\":\"KRS2BLK\\u0000\",\"krs2_golden_bytes\":148,\"krs2_golden_sha256\":\"ae1dbbf3d204b3fee9bd0a68242c5e5aa0811cf2910584868353e6a4d8b07d6e\",\"krs3_frames\":{},\"krs3_frame_bytes\":{adaptive_frames:?},\"krs3_malformed_recoveries\":{adaptive_malformed},\"krs3_fallback_cases\":{adaptive_fallbacks},\"adaptive_archive_revision\":8,\"adaptive_archive_malformed_recoveries\":{adaptive_archive_cases},\"memory_gate\":true,\"archive_bytes\":{}}}",
        normal.len(),
        adaptive_frames.len(),
        original.len()
    );
}
