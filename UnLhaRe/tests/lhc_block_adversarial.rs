//! 公開API/アーカイブで30件の破損故障とG32 revision互換性を検査するE2E。
use crc_fast::{CrcAlgorithm, Digest};
use std::fs;
use unlhare::{
    Limits,
    lhc::{self, BlockStrategy},
};
#[path = "common/lhc_e2e_root.rs"]
mod lhc_e2e_root;

fn put(b: &mut [u8], at: usize, value: usize) {
    b[at..at + 4].copy_from_slice(&(value as u32).to_le_bytes());
}
fn seal(b: &mut [u8]) {
    let mut d = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    d.update(&b[..36]);
    d.update(&b[40..]);
    b[36..40].copy_from_slice(&(d.finalize() as u32).to_le_bytes());
}
#[test]
fn thirty_product_decoder_faults_and_recovery() {
    let output = lhc_e2e_root::path("block-adverse");
    fs::create_dir_all(&output).unwrap();
    let plain = vec![65; 4096];
    let good = lhc::compress_block(&plain).unwrap();
    assert_eq!(good[10], 1);
    let alphabets = u16::from_le_bytes(good[28..30].try_into().unwrap()) as usize;
    let model = u32::from_le_bytes(good[20..24].try_into().unwrap()) as usize;
    let model_at = 40 + 2 * alphabets;
    let payload_at = model_at + model;
    let mut reasons = Vec::new();
    let mut resealed = 0;
    for case in 0..30 {
        let mut bad = good.clone();
        let mut reseal = true;
        match case {
            0 => bad[0] ^= 1,
            1 => bad[8] = 3,
            2 => bad[10] = 2,
            3 => bad[11] = 1,
            4 => bad[30] = 1,
            5 => put(&mut bad, 12, lhc::BLOCK_BYTES + 1),
            6 => put(&mut bad, 16, 4097),
            7 => {
                bad.truncate(39);
                reseal = false;
            }
            8 => {
                bad.pop();
                reseal = false;
            }
            9 => bad.push(0),
            10 => put(&mut bad, 20, u32::MAX as usize),
            11 => put(&mut bad, 24, u32::MAX as usize),
            12 => bad[28..30].copy_from_slice(&65535u16.to_le_bytes()),
            13 => {
                *bad.last_mut().unwrap() ^= 1;
                reseal = false;
            }
            14 => bad[32] ^= 1,
            15 => {
                let first = [bad[40], bad[41]];
                bad[42..44].copy_from_slice(&first);
            }
            16 => bad[40..42].copy_from_slice(&257u16.to_le_bytes()),
            17 => bad[42..44].copy_from_slice(&1u16.to_le_bytes()),
            18 => {
                bad[40..42].copy_from_slice(&0u16.to_le_bytes());
                bad[42..44].copy_from_slice(&66u16.to_le_bytes());
            }
            19 => bad[model_at] = 0,
            20 => bad[model_at + 133] |= 1,
            21 => bad[payload_at] = 1,
            22 => {
                bad.push(0);
                put(&mut bad, 24, good.len() - payload_at + 1);
            }
            23 => *bad.last_mut().unwrap() ^= 1,
            24 => put(&mut bad, 16, 0),
            25 => {
                bad[10] = 0;
            }
            26 => put(&mut bad, 12, good.len() - 40),
            27 => {
                bad[29] = 1;
            }
            28 => {
                bad[31] = 1;
            }
            _ => put(&mut bad, 24, 4),
        }
        if reseal {
            seal(&mut bad);
            resealed += 1;
        }
        let err = lhc::decompress_block(&bad).expect_err(&format!("fault {case}"));
        reasons.push(err.to_string());
        assert_eq!(
            lhc::decompress_block(&good).unwrap(),
            plain,
            "recovery {case}"
        );
    }
    let mut state = 0x6d2b79f5u32;
    let g32_plain: Vec<u8> = (0..65_536)
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
        .collect();
    let g32 = lhc::compress_block_with_strategy(&g32_plain, BlockStrategy::Gather32Trial).unwrap();
    assert_eq!(&g32[..8], b"LHCG32B\0", "fixture must exercise G32");
    assert_eq!(&g32[8..10], &2u16.to_le_bytes());
    assert_eq!(lhc::decompress_block(&g32).unwrap(), g32_plain);

    let mut legacy_revision = g32.clone();
    legacy_revision[8..10].copy_from_slice(&1u16.to_le_bytes());
    seal(&mut legacy_revision);
    assert_eq!(lhc::decompress_block(&legacy_revision).unwrap(), g32_plain);
    let mut unknown_revision = g32.clone();
    unknown_revision[8..10].copy_from_slice(&3u16.to_le_bytes());
    seal(&mut unknown_revision);
    assert!(lhc::decompress_block(&unknown_revision).is_err());
    let mut bad_crc = g32.clone();
    *bad_crc.last_mut().unwrap() ^= 1;
    assert!(lhc::decompress_block(&bad_crc).is_err());
    let mut unsupported_method = vec![0; 40 + g32_plain.len() - 1];
    unsupported_method[..8].copy_from_slice(b"LHCG32B\0");
    unsupported_method[8..10].copy_from_slice(&2u16.to_le_bytes());
    unsupported_method[10] = 2;
    unsupported_method[12..16].copy_from_slice(&(g32_plain.len() as u32).to_le_bytes());
    unsupported_method[24..28].copy_from_slice(&((g32_plain.len() - 1) as u32).to_le_bytes());
    let mut raw_crc = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
    raw_crc.update(&g32_plain);
    unsupported_method[32..36].copy_from_slice(&(raw_crc.finalize() as u32).to_le_bytes());
    seal(&mut unsupported_method);
    assert!(lhc::decompress_block(&unsupported_method).is_err());

    let g32_source = output.join("g32-revision4-source");
    fs::create_dir_all(&g32_source).unwrap();
    fs::write(g32_source.join("data"), &g32_plain).unwrap();
    let archive = output.join("g32-revision4.lhc");
    let options = lhc::CreateOptions {
        block_strategy: BlockStrategy::Gather32Trial,
        ..lhc::CreateOptions::default()
    };
    lhc::create_from_directory(&g32_source, &archive, &options).unwrap();
    let archive_bytes = fs::read(&archive).unwrap();
    assert_eq!(archive_bytes[8], 4);
    let frame_at = archive_bytes
        .windows(8)
        .position(|window| window == b"LHCG32B\0")
        .expect("revision 4 archive must contain its G32 block");
    let frame_len_at = frame_at - 4;
    let frame_len =
        u32::from_le_bytes(archive_bytes[frame_len_at..frame_at].try_into().unwrap()) as usize;
    let frame_end = frame_at + frame_len;
    assert_eq!(
        &archive_bytes[frame_at + 8..frame_at + 10],
        &2u16.to_le_bytes()
    );
    let limits = Limits::default();
    assert_eq!(lhc::list_archive(&archive, &limits).unwrap().len(), 1);
    lhc::verify_archive(&archive, &limits).unwrap();
    let good_output = output.join("g32-revision4-good");
    lhc::extract_archive(&archive, &good_output, &limits).unwrap();
    assert_eq!(fs::read(good_output.join("data")).unwrap(), g32_plain);

    let mut legacy_archive = archive_bytes.clone();
    legacy_archive[frame_at + 8..frame_at + 10].copy_from_slice(&1u16.to_le_bytes());
    seal(&mut legacy_archive[frame_at..frame_end]);
    let legacy_archive_path = output.join("g32-revision4-legacy-revision.lhc");
    fs::write(&legacy_archive_path, legacy_archive).unwrap();
    assert_eq!(
        lhc::list_archive(&legacy_archive_path, &limits)
            .unwrap()
            .len(),
        1
    );
    lhc::verify_archive(&legacy_archive_path, &limits).unwrap();
    let legacy_output = output.join("g32-revision4-legacy-output");
    lhc::extract_archive(&legacy_archive_path, &legacy_output, &limits).unwrap();
    assert_eq!(fs::read(legacy_output.join("data")).unwrap(), g32_plain);

    let mut bad_archive = archive_bytes;
    bad_archive[frame_at + 8..frame_at + 10].copy_from_slice(&3u16.to_le_bytes());
    seal(&mut bad_archive[frame_at..frame_end]);
    let bad_archive_path = output.join("g32-revision4-bad-revision.lhc");
    fs::write(&bad_archive_path, bad_archive).unwrap();
    assert!(lhc::list_archive(&bad_archive_path, &limits).is_err());
    assert!(lhc::verify_archive(&bad_archive_path, &limits).is_err());
    let bad_output = output.join("g32-revision4-bad-output");
    assert!(lhc::extract_archive(&bad_archive_path, &bad_output, &limits).is_err());
    assert!(!bad_output.join("data").exists());

    fs::write(output.join("result.json"),serde_json::to_vec_pretty(&serde_json::json!({
        "faults":30,"recoveries":30,"resealed":resealed,"errors":reasons,
        "corpus":"product encoder repeated byte frame, not experimental handbuilt uniform witness",
        "g32_revision2_roundtrip":true,"g32_revision1_legacy_roundtrip":true,
        "g32_revision4_legacy_archive_roundtrip":true,"g32_revision3_rejected":true,
        "g32_revision2_method2_rejected":true,
        "g32_revision4_unknown_archive_rejected_by_list_verify_extract":true
    })).unwrap()).unwrap();
}
