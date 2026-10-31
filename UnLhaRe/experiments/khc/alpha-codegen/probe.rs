//! 凍結旧primitiveを参照する生成コード専用harness。実行・性能測定は行わない。
#![allow(dead_code)]

#[path = "../quaternary-cts-q32/integer_cts.rs"]
mod reference_cts;

pub use reference_cts::{Kernel, Result};

pub fn alpha_codegen_update_kernel(
    snapshot: &Kernel,
    weights: [u64; 9],
    prefix: usize,
    child: usize,
    after: u32,
) -> Result<[u64; 9]> {
    reference_cts::update_kernel(snapshot, weights, prefix, child, after)
}

pub fn alpha_codegen_posterior_switch(
    weight: u64,
    own: u64,
    rawmass: u128,
    after: u32,
) -> Result<(u64, u64, u64)> {
    reference_cts::posterior_switch(weight, own, rawmass, after)
}
