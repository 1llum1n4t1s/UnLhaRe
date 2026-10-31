//! 製品public APIの有限入力と凍結3block基準以下の実費を確認するE2E。
use std::{fs, io::Read};
use unlhare::khc;
#[path = "common/khc_e2e_root.rs"]
mod khc_e2e_root;

fn seeded(n: usize) -> Vec<u8> {
    let mut result = vec![0; n];
    let mut x = 0x6d2b79f5u32;
    for b in &mut result {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        *b = x as u8;
    }
    result
}

#[test]
fn product_finite_frames_and_frozen_fixed_block_costs() {
    let output = khc_e2e_root::path("block-normal");
    fs::create_dir_all(&output).unwrap();
    let mut rows = Vec::new();
    for case in 0..9 {
        let input = match case {
            0 => Vec::new(),
            1 => vec![165],
            2 => (0..=255).collect(),
            3 => vec![7; 4096],
            4 => (0..8192)
                .map(|i| if i % 127 == 0 { 255 } else { 0 })
                .collect(),
            5 => seeded(8192),
            6 => (0..4096).map(|i| (i % 3) as u8).collect(),
            7 => vec![23; khc::BLOCK_BYTES - 1],
            _ => seeded(khc::BLOCK_BYTES),
        };
        let frame = khc::compress_block(&input).unwrap();
        assert_eq!(khc::decompress_block(&frame).unwrap(), input);
        assert!(frame.len() <= input.len() + 40);
        rows.push(serde_json::json!({"case":case,"input":input.len(),"frame":frame.len(),"method":frame[10]}));
    }
    assert!(khc::compress_block(&vec![0; khc::BLOCK_BYTES + 1]).is_err());
    let mut fixed = Vec::new();
    if let Some(path) = std::env::var_os("UNLHARE_KHC_FIXED_INPUT") {
        let mut file = fs::File::open(path).unwrap();
        for (size, expected) in [
            (1_048_576, 157_149),
            (1_048_576, 237_852),
            (713_854, 120_312),
        ] {
            let mut input = vec![0; size];
            file.read_exact(&mut input).unwrap();
            let frame = khc::compress_block(&input).unwrap();
            // encoder戦略は改良できる。凍結基準は保持し、新frameが超えないことを確認する。
            assert!(
                frame.len() <= expected,
                "exceeds frozen default cost baseline"
            );
            assert_eq!(khc::decompress_block(&frame).unwrap(), input);
            fixed.push(frame.len());
        }
        let mut extra = [0];
        assert_eq!(file.read(&mut extra).unwrap(), 0);
    }
    let plain = b"low history ablation ".repeat(400);
    let low =
        khc::compress_block_with_history_mode(&plain, khc::HistoryMode::LowHistoryOnly).unwrap();
    assert_eq!(khc::decompress_block(&low).unwrap(), plain);
    fs::write(output.join("result.json"),serde_json::to_vec_pretty(&serde_json::json!({
        "normal":rows,"fixed_frame_bytes":fixed,"frozen_baseline_bytes":[157149,237852,120312],"fixed_not_larger_than_baseline":!fixed.is_empty(),"fixed_byte_exact":!fixed.is_empty(),"low_only_byte_exact":true,"oversize_rejected":true
    })).unwrap()).unwrap();
}
