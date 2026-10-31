//! 全分割uniformと全可変Forestの独立wireを公開APIで復号するE2E。
use crc_fast::{CrcAlgorithm, Digest};
use std::{fs, time::Instant};
use unlhare::khc;
#[path = "common/khc_e2e_root.rs"]
mod khc_e2e_root;
fn bit(out: &mut Vec<u8>, position: &mut usize, value: u8) {
    if (*position).is_multiple_of(8) {
        out.push(0);
    }
    out[*position / 8] |= value << (7 - *position % 8);
    *position += 1;
}
fn node(
    out: &mut Vec<u8>,
    position: &mut usize,
    depth: usize,
    path: usize,
    k: usize,
    variable: bool,
) {
    if depth == 5 {
        // 履歴1023だけpureにして全rootを可変にする。独立payloadはこの履歴を使わない。
        for b in [0, 1, u8::from(!variable || path != 1023)] {
            bit(out, position, b);
        }
        if variable && path == 1023 {
            for _ in 0..if k == 2 { 1 } else { 2 } {
                bit(out, position, 0);
            }
        }
    } else {
        bit(out, position, 1);
        if depth == 0 {
            bit(out, position, 0);
        }
        for digit in 0..4 {
            node(
                out,
                position,
                depth + 1,
                path | (digit << (2 * depth)),
                k,
                variable,
            );
        }
    }
}
// 独立fixture encoder：uniform CDFのpayloadを作り、製品学習CDFを借用しない。
struct Range {
    low: u64,
    range: u32,
    cache: u8,
    pending: usize,
    bytes: Vec<u8>,
}
impl Range {
    fn new() -> Self {
        Self {
            low: 0,
            range: u32::MAX,
            cache: 0,
            pending: 1,
            bytes: Vec::new(),
        }
    }
    fn shift(&mut self) {
        let low = self.low as u32;
        let carry = (self.low >> 32) as u8;
        if low < 0xff00_0000 || carry != 0 {
            self.bytes.push(self.cache.wrapping_add(carry));
            self.bytes.resize(
                self.bytes.len() + self.pending - 1,
                255u8.wrapping_add(carry),
            );
            self.pending = 0;
            self.cache = (low >> 24) as u8;
        }
        self.pending += 1;
        self.low = u64::from((low & 0x00ff_ffff) << 8);
    }
    fn interval(&mut self, c: u32, f: u32, total: u32) {
        let unit = self.range / total;
        self.low += u64::from(unit) * u64::from(c);
        self.range = unit * f;
        while self.range < 1 << 24 {
            self.range <<= 8;
            self.shift();
        }
    }
    fn uniform_token(&mut self, alphabet: usize, limit: usize, token: usize) {
        let mut lo = 0;
        let mut hi = alphabet;
        loop {
            let cuts = if lo == 0 {
                vec![0, 1, 2, 4, hi]
            } else if lo == 4 && hi == alphabet {
                vec![4, 8, 16, 32, hi]
            } else if lo == 32 && hi == alphabet {
                vec![32, 64, 128, 256, hi]
            } else {
                let n = (hi - lo).min(4);
                (0..=n).map(|i| lo + (hi - lo) * i / n).collect()
            };
            let edges: Vec<_> = cuts
                .windows(2)
                .filter(|p| p[0] < p[1] && p[0] < limit)
                .collect();
            let k = edges.len();
            let child = edges
                .iter()
                .position(|p| p[0] <= token && token < p[1])
                .unwrap();
            if k > 1 {
                let base = 32768 / k as u32;
                let rem = 32768 % k as u32;
                self.interval(
                    child as u32 * base + (child as u32).min(rem),
                    base + u32::from((child as u32) < rem),
                    32768,
                );
            }
            lo = edges[child][0];
            hi = edges[child][1];
            if hi - lo == 1 {
                break;
            }
        }
    }
    fn finish(mut self) -> Vec<u8> {
        for _ in 0..5 {
            self.shift();
        }
        self.bytes
    }
}
#[test]
fn maximum_split_uniform_model_decodes_with_linear_dispatch_work() {
    let plain = vec![65; khc::BLOCK_BYTES];
    let good = khc::compress_block(&plain).unwrap();
    let alphabet = u16::from_le_bytes(good[28..30].try_into().unwrap()) as usize * 2;
    let model_at = 40 + alphabet;
    let old_model = u32::from_le_bytes(good[20..24].try_into().unwrap()) as usize;
    // 通常encoderは非uniform木も選ぶため、そのpayloadは再利用しない。
    assert!(old_model >= 241);
    let mut range = Range::new();
    range.uniform_token(257, 2, 0);
    range.uniform_token(256, 256, 255);
    let mut escape = khc::BLOCK_BYTES - 256;
    loop {
        let mut b = (escape & 127) as u8;
        escape >>= 7;
        if escape != 0 {
            b |= 128;
        }
        range.interval(u32::from(b), 1, 256);
        if escape == 0 {
            break;
        }
    }
    range.uniform_token(257, 1, 0);
    range.uniform_token(256, 1, 0);
    let payload = range.finish();
    let mut rows = Vec::new();
    for variable in [false, true] {
        let mut tree = Vec::new();
        let mut position = 0;
        for root in 0..852 {
            bit(&mut tree, &mut position, 1);
            node(&mut tree, &mut position, 0, 0, root % 3 + 2, variable);
        }
        let mut model = good[model_at..model_at + 134].to_vec();
        model[1..5].copy_from_slice(&(position as u32).to_le_bytes());
        model.extend_from_slice(&tree);
        assert_eq!(model.len(), if variable { 364_009 } else { 363_832 });
        let mut frame = good[..model_at].to_vec();
        frame[20..24].copy_from_slice(&(model.len() as u32).to_le_bytes());
        frame.extend_from_slice(&model);
        frame[24..28].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.extend_from_slice(&payload);
        let mut c = Digest::new(CrcAlgorithm::Crc32IsoHdlc);
        c.update(&frame[..36]);
        c.update(&frame[40..]);
        frame[36..40].copy_from_slice(&(c.finalize() as u32).to_le_bytes());
        let start = Instant::now();
        assert_eq!(khc::decompress_block(&frame).unwrap(), plain);
        let elapsed = start.elapsed();
        assert!(
            elapsed.as_secs_f64() < 5.0,
            "bounded model decode: {elapsed:?}"
        );
        rows.push(serde_json::json!({
            "variable_roots": if variable { 852 } else { 0 },
            "model_bytes": model.len(), "byte_exact": true,
            "decode_ms": elapsed.as_secs_f64() * 1000.0,
            "frequency_rows": if variable { 872448 } else { 0 },
            "frequency_bytes": if variable { 6979584 } else { 0 },
            "all_rows_variable_by_independent_wire": variable
        }));
    }
    let root = khc_e2e_root::path("model-boundary");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("result.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "full_split_roots":852, "models":rows,
            "dispatch_assignments":872448, "old_mask_checks":893386752
        }))
        .unwrap(),
    )
    .unwrap();
}
