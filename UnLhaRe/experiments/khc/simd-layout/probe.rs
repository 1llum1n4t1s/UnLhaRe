//! 命令/配置の静的調査専用。full codecでも速度ベンチマークでもない。
#[allow(dead_code)]
#[path = "../simd-quotient/exact_div.rs"]
mod exact_div;

#[unsafe(no_mangle)]
pub fn batch_probe(
    engine: &exact_div::BatchEngine, a: [u64; 4], b: [u64; 4], d: [u64; 4],
) -> [exact_div::Ratio; 4] {
    engine.ratio4(a, b, d)
}

#[unsafe(no_mangle)]
pub fn ratio_bytes() -> usize { std::mem::size_of::<exact_div::Ratio>() }
#[unsafe(no_mangle)]
pub fn four_ratio_bytes() -> usize { std::mem::size_of::<[exact_div::Ratio; 4]>() }
#[unsafe(no_mangle)]
pub fn four_cts_result_bytes() -> usize {
    std::mem::size_of::<[Result<u64, String>; 4]>()
}
#[unsafe(no_mangle)]
pub fn four_cts_input_bytes() -> usize {
    std::mem::size_of::<[Result<(u64, u64, u64), String>; 4]>()
}
#[unsafe(no_mangle)]
pub fn four_plain_posterior_bytes() -> usize { std::mem::size_of::<[u64; 4]>() }
