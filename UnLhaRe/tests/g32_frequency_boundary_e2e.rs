use unlhare::khc::{self, BlockStrategy};

#[test]
fn gather32_public_api_roundtrips_around_inverse_threshold() {
    let pattern = b"the bounded gather inverse transform\n";
    let input: Vec<u8> = (0..65_536)
        .map(|i| pattern[(i + i / 31) % pattern.len()])
        .collect();

    for raw_len in [65_534, 65_535, 65_536] {
        let plain = &input[..raw_len];
        let frame = khc::compress_block_with_strategy(plain, BlockStrategy::Gather32Trial)
            .expect("compress boundary input");
        assert!(
            frame.starts_with(b"KHCG32B\0"),
            "{raw_len} bytes must exercise a G32 frame"
        );
        let restored = khc::decompress_block(&frame).expect("decode boundary G32 frame");
        assert_eq!(restored.as_slice(), plain, "{raw_len} byte roundtrip");
    }
}
