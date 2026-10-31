mod multi_range;
use multi_range::{Decoder, Encoder};
type Interval = (u32, u32, u32);

fn intervals(seed: u32, count: usize) -> Vec<Interval> {
    let mut state = seed;
    (0..count).map(|i| {
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        let total = match i % 7 { 0 => 1, 1 => 2, 2 => 256, 3 => 81920, _ => 1 + state % 81920 };
        let cumulative = match i % 5 { 0 => 0, 1 => total - 1, _ => state % total };
        let frequency = if i % 3 == 0 { total - cumulative } else { 1 + (state >> 16) % (total - cumulative) };
        (cumulative, frequency, total)
    }).collect()
}

// 本体の u32/u64 状態を参照せず、u128 と明示 modulo で wire を算出する。
fn oracle(seq: &[Interval]) -> (Vec<u8>, usize, usize, usize) {
    let (mut low, mut width, mut pending, mut cache) = (0u128, 0xffff_ffffu128, 1usize, 0u128);
    let mut out = Vec::new();
    let (mut carries, mut max_pending, mut normalizations) = (0, 1, 0);
    let shift = |low: &mut u128, pending: &mut usize, cache: &mut u128, out: &mut Vec<u8>, carries: &mut usize, max_pending: &mut usize| {
        let lower = *low % (1u128 << 32);
        let carry = *low / (1u128 << 32);
        assert!(carry <= 1);
        if lower < 0xff00_0000 || carry != 0 {
            *carries += usize::from(carry != 0);
            out.push(((*cache + carry) % 256) as u8);
            for _ in 1..*pending { out.push(((255 + carry) % 256) as u8); }
            *pending = 0;
            *cache = lower / (1u128 << 24);
        }
        *pending += 1;
        *max_pending = (*max_pending).max(*pending);
        *low = (lower % (1u128 << 24)) * 256;
    };
    for &(c, f, t) in seq {
        let unit = width / u128::from(t);
        low += unit * u128::from(c);
        width = unit * u128::from(f);
        while width < (1u128 << 24) {
            width *= 256;
            normalizations += 1;
            shift(&mut low, &mut pending, &mut cache, &mut out, &mut carries, &mut max_pending);
        }
    }
    for _ in 0..5 { shift(&mut low, &mut pending, &mut cache, &mut out, &mut carries, &mut max_pending); }
    (out, carries, max_pending, normalizations)
}

fn encode(seq: &[Interval], limit: usize) -> Result<Vec<u8>, &'static str> {
    let mut encoder = Encoder::with_limit(limit)?;
    for &(c, f, t) in seq { encoder.interval(c, f, t)?; }
    encoder.finish()
}

fn decode(bytes: &[u8], seq: &[Interval], check_oracle: bool) -> Result<(), &'static str> {
    let mut decoder = Decoder::new(bytes)?;
    let mut code = u128::from(u32::from_be_bytes(bytes[1..5].try_into().unwrap()));
    let mut width = 0xffff_ffffu128;
    let mut position = 5;
    for &(c, f, t) in seq {
        let slot = decoder.slot(t)?;
        assert_eq!(decoder.slot(t)?, slot);
        if check_oracle {
            let unit = width / u128::from(t);
            assert_eq!(u128::from(slot), code / unit);
            code -= unit * u128::from(c);
            width = unit * u128::from(f);
            while width < (1u128 << 24) {
                code = (code * 256 + u128::from(*bytes.get(position).ok_or("oracle truncated")?)) % (1u128 << 32);
                width *= 256;
                position += 1;
            }
        }
        if c > 0 { assert!(decoder.consume(0, c, t).is_err()); }
        else if c + f < t { assert!(decoder.consume(c + f, t - c - f, t).is_err()); }
        assert_eq!(decoder.slot(t)?, slot);
        decoder.consume(c, f, t)?;
    }
    if check_oracle { assert_eq!(position, bytes.len()); assert_eq!(code, 0); }
    decoder.finish()
}

fn fingerprint(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x100000001b3))
}

fn audit() {
    let bad = [(0, 1, 0), (0, 1, 81921), (0, 0, 1), (1, 1, 1), (u32::MAX, 1, 81920), (0, u32::MAX, 81920)];
    let mut checks = 0usize;
    let mut rejected = 0usize;
    let mut fingerprint_all = 0u64;
    let (mut carry_count, mut max_pending, mut normalization_count) = (0, 1, 0);
    for seed in [0, 1, 0x6a09e667, 0xbb67ae85] {
        let seq = intervals(seed, 50000);
        let (expected, carry, pending, norm) = oracle(&seq);
        let actual = encode(&seq, expected.len()).unwrap();
        assert_eq!(actual, expected);
        decode(&actual, &seq, true).unwrap();
        assert!(encode(&seq, expected.len() - 1).is_err());
        fingerprint_all ^= fingerprint(&actual);
        carry_count += carry; max_pending = max_pending.max(pending); normalization_count += norm;
        checks += seq.len();
    }
    assert!(carry_count > 0 && max_pending > 1);
    let seq = intervals(42, 32);
    let bytes = encode(&seq, 4096).unwrap();
    let readonly_hash = fingerprint(&bytes);
    let mut encoder = Encoder::with_limit(4096).unwrap();
    let mut decoder = Decoder::new(&bytes).unwrap();
    for &(c, f, t) in &seq {
        for &(bc, bf, bt) in &bad {
            assert!(encoder.interval(bc, bf, bt).is_err());
            assert!(decoder.consume(bc, bf, bt).is_err());
            rejected += 2;
        }
        assert!(decoder.slot(0).is_err()); assert!(decoder.slot(81921).is_err());
        encoder.interval(c, f, t).unwrap(); decoder.consume(c, f, t).unwrap();
    }
    assert_eq!(encoder.finish().unwrap(), bytes); decoder.finish().unwrap();
    assert_eq!(fingerprint(&bytes), readonly_hash);
    for n in 0..bytes.len() { assert!(decode(&bytes[..n], &seq, false).is_err()); rejected += 1; }
    let mut trailing = bytes.clone(); trailing.push(0); assert!(decode(&trailing, &seq, false).is_err()); rejected += 1;
    assert!(Decoder::new(&[1,0,0,0,0]).is_err());
    assert!(Decoder::new(&[0,0,0,0,1]).unwrap().finish().is_err());
    assert!(Decoder::new(&[0,255,255,255,255]).unwrap().slot(1).is_err()); rejected += 3;
    let mut truncated = Decoder::new(&[0,0,0,0,0]).unwrap();
    assert!(truncated.consume(0,1,81920).is_err());
    truncated.consume(0,1,1).unwrap(); truncated.finish().unwrap(); rejected += 1;
    for limit in 0..5 { assert!(Encoder::with_limit(limit).unwrap().finish().is_err()); rejected += 1; }
    let mut limited = Encoder::with_limit(0).unwrap();
    assert!(limited.interval(0,1,81920).is_err());
    limited.interval(0,1,1).unwrap(); rejected += 1;
    assert_eq!(Encoder::with_limit(5).unwrap().finish().unwrap(), [0,0,0,0,0]);
    // 1MiB の初期 reserve を超える growth と巨大 declared limit の bounded reserve。
    let growth_seq: Vec<_> = (0..550000u32).map(|i| (i.wrapping_mul(1664525) % 81920, 1, 81920)).collect();
    let growth_expected = oracle(&growth_seq).0;
    assert!(growth_expected.len() > (1 << 20));
    let grown = encode(&growth_seq, growth_expected.len()).unwrap();
    assert_eq!(grown, growth_expected); decode(&grown, &growth_seq, true).unwrap(); checks += growth_seq.len();
    Encoder::with_limit(usize::MAX).unwrap().finish().unwrap();
    let carry_seq = intervals(0xbb67ae85, 50000);
    let mut probe = Encoder::with_limit(1 << 20).unwrap();
    let mut delayed_checks = 0;
    for (index, &(c,f,t)) in carry_seq.iter().enumerate() {
        let before = probe.audit_state();
        probe.interval(c,f,t).unwrap();
        let after = probe.audit_state();
        if before.3 > 1 && after.4 > before.4 {
            let mut short = Encoder::with_limit(before.4 + before.3 - 1).unwrap();
            for &(pc,pf,pt) in &carry_seq[..index] { short.interval(pc,pf,pt).unwrap(); }
            let unchanged = short.audit_state();
            assert!(short.interval(c,f,t).is_err());
            assert_eq!(short.audit_state(), unchanged);
            short.interval(0,1,1).unwrap();
            assert_eq!(short.audit_state(), unchanged);
            delayed_checks += 1; rejected += 1;
            break;
        }
    }
    assert_eq!(delayed_checks,1);
    println!("{{\"status\":\"passed\",\"interval_checks\":{checks},\"rejections\":{rejected},\"carry_count\":{carry_count},\"max_pending\":{max_pending},\"normalizations\":{normalization_count},\"fingerprint\":\"{fingerprint_all:016x}\",\"readonly_fingerprint\":\"{readonly_hash:016x}\",\"growth_bytes\":{}}}", grown.len());
}

fn run() -> Result<(), &'static str> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("audit") => audit(),
        Some("encode") => {
            let bytes = encode(&intervals(123, 512), 4096)?;
            for byte in bytes { print!("{byte:02x}"); } println!();
        },
        Some("decode") => {
            let hex = args.get(2).ok_or("missing hex")?;
            if hex.len() > 8192 || hex.len() % 2 != 0 { return Err("invalid hex length"); }
            let mut bytes = Vec::new();
            for pair in hex.as_bytes().chunks(2) {
                let pair = std::str::from_utf8(pair).map_err(|_| "invalid hex")?;
                bytes.push(u8::from_str_radix(pair,16).map_err(|_| "invalid hex")?);
            }
            decode(&bytes, &intervals(123,512), true)?;
            println!("{{\"status\":\"passed\",\"serialized_symbols\":512,\"fingerprint\":\"{:016x}\"}}",fingerprint(&bytes));
        },
        _ => return Err("invalid mode"),
    }
    Ok(())
}
fn main() { if let Err(error) = run() { eprintln!("{error}"); std::process::exit(2); } }
