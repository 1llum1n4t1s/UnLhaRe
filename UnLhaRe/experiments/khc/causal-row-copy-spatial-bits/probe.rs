//! 有限E2E入口。unit testを追加せず、正常・悪性・同一process復帰を検証する。
#![allow(dead_code)]
mod codec;
use codec::{Result, decode, encode, field, put, reseal};
use std::{fs, io::Read, time::Instant};
fn need(ok: bool, why: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(why.into()) }
}
fn sha(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h = [
        0x6a09e667u32,
        0xbb67ae85,
        0x3c6ef372,
        0xa54ff53a,
        0x510e527f,
        0x9b05688c,
        0x1f83d9ab,
        0x5be0cd19,
    ];
    let blocks = (data.len() + 9).div_ceil(64);
    for block in 0..blocks {
        let mut chunk = [0; 64];
        for (i, b) in chunk.iter_mut().enumerate() {
            let p = block * 64 + i;
            *b = if p < data.len() {
                data[p]
            } else if p == data.len() {
                128
            } else {
                0
            };
        }
        if block + 1 == blocks {
            chunk[56..].copy_from_slice(&(data.len() as u64 * 8).to_be_bytes());
        }
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[4 * i..4 * i + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let a = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let b = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(a)
                .wrapping_add(w[i - 7])
                .wrapping_add(b);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut q] = h;
        for i in 0..64 {
            let s = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let t = q
                .wrapping_add(s)
                .wrapping_add((e & f) ^ (!e & g))
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let u = (a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22))
                .wrapping_add((a & b) ^ (a & c) ^ (b & c));
            q = g;
            g = f;
            f = e;
            e = d.wrapping_add(t);
            d = c;
            c = b;
            b = a;
            a = t.wrapping_add(u);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, q]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|n| format!("{n:08x}")).collect()
}
fn reject(bad: &[u8], valid: &[u8], raw: &[u8], label: &str, count: &mut usize) -> Result<()> {
    need(decode(valid)?.0 == raw, "pre-malformed recovery")?;
    need(decode(bad).is_err(), &format!("accepted malformed {label}"))?;
    need(decode(valid)?.0 == raw, "post-malformed recovery")?;
    *count += 1;
    Ok(())
}
fn forged(counts: &[u8], zero_literal: bool) -> Result<Vec<u8>> {
    let raw = vec![0; 4096];
    let mut histogram = [0; 256];
    for &b in counts {
        histogram[b as usize] += 1;
    }
    let model = codec::CountModel::normalize(&histogram)?;
    let mut enc = codec::range::Encoder::with_limit(4096).map_err(str::to_owned)?;
    for &b in counts {
        model.encode(b, &mut enc)?;
    }
    if zero_literal {
        let mut p = 16384;
        for _ in 0..8 {
            enc.interval(0, u32::from(p), 32768)
                .map_err(str::to_owned)?;
            p = codec::update(p, false);
        }
    }
    codec::pack(
        &raw,
        &model.serialize(),
        &enc.finish().map_err(str::to_owned)?,
        1,
    )
}
fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    need(args.len() == 4, "usage: probe input expected-sha work")?;
    let mut raw = Vec::new();
    fs::File::open(&args[1])
        .map_err(|e| e.to_string())?
        .take((codec::MAX + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|e| e.to_string())?;
    need(
        raw.len() == 513216 && sha(&raw) == args[2],
        "fixed ptt5 identity",
    )?;
    need(
        sha(b"") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "SHA empty vector",
    )?;
    need(
        sha(b"abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA abc vector",
    )?;
    let mut rng = 0x12345678u32;
    let random: Vec<u8> = (0..65536)
        .map(|_| {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            rng as u8
        })
        .collect();
    let normal = vec![
        ("empty", vec![]),
        ("zero", vec![0]),
        ("ff", vec![255]),
        ("all-copy", vec![0; 4096]),
        ("all-ff", vec![255; 4096]),
        (
            "periodic",
            (0..8192).map(|i| b"abc0123456789\0"[i % 14]).collect(),
        ),
        (
            "prefix-change",
            (0..8192)
                .map(|i| if i < 4096 { 0 } else { (i % 251) as u8 })
                .collect(),
        ),
        ("all-bytes", (0..8192).map(|i| i as u8).collect()),
        ("random", random),
        ("max-copy", vec![0; codec::MAX]),
    ];
    let mut cases = Vec::new();
    let mut seen = [false; 2];
    for (name, input) in normal {
        let (a, s) = encode(&input)?;
        let (b, _) = encode(&input)?;
        need(a == b, "matrix deterministic")?;
        let (plain, d) = decode(&a)?;
        need(plain == input, "matrix roundtrip")?;
        if a[10] == 1 {
            need(s == d, "matrix grammar synchronization")?;
        }
        seen[a[10] as usize] = true;
        cases.push(format!(
            "{{\"name\":\"{name}\",\"raw\":{},\"frame\":{},\"method\":{}}}",
            input.len(),
            a.len(),
            a[10]
        ));
    }
    need(seen == [true, true], "coded and stored exercised")?;
    need(
        encode(&vec![0; codec::MAX + 1]).is_err(),
        "encode raw bound",
    )?;
    let started = Instant::now();
    let (frame, stats) = encode(&raw)?;
    let encode_ns = started.elapsed().as_nanos();
    let started = Instant::now();
    let (restored, decoded) = decode(&frame)?;
    let decode_ns = started.elapsed().as_nanos();
    need(
        restored == raw && sha(&restored) == args[2],
        "ptt5 roundtrip/SHA",
    )?;
    need(frame == encode(&raw)?.0, "ptt5 deterministic")?;
    need(
        stats == decoded && frame[10] == 1,
        "ptt5 coded grammar synchronization",
    )?;
    let mut rejects = 0;
    for p in [0, 8, 10, 11, 12, 16, 20, 24, 28, 32, 39] {
        let mut b = frame.clone();
        b[p] ^= 0x40;
        if p != 28 {
            reseal(&mut b);
        }
        reject(&b, &frame, &raw, &format!("header {p}"), &mut rejects)?;
    }
    for cut in [0, 7, 39, 40, frame.len() - 1] {
        reject(&frame[..cut], &frame, &raw, "truncate", &mut rejects)?;
    }
    let meta = field(&frame, 16)?;
    for p in [40, 42, 43, 40 + meta, frame.len() - 1] {
        let mut b = frame.clone();
        b[p] ^= 0x80;
        reseal(&mut b);
        reject(&b, &frame, &raw, &format!("model/range {p}"), &mut rejects)?;
    }
    let mut b = frame.clone();
    put(&mut b, 12, codec::MAX + 1);
    reseal(&mut b);
    reject(&b, &frame, &raw, "oversize raw", &mut rejects)?;
    let mut b = frame.clone();
    b.push(0);
    let n = field(&b, 20)? + 1;
    put(&mut b, 20, n);
    reseal(&mut b);
    reject(&b, &frame, &raw, "trailing range", &mut rejects)?;
    for (label, b) in [
        ("overlong count", forged(&[128, 0], false)?),
        ("count width", forged(&[128, 128, 128], false)?),
        ("count remaining", forged(&[129, 32], false)?),
        ("zero residual", forged(&[0], true)?),
    ] {
        reject(&b, &frame, &raw, label, &mut rejects)?;
    }
    let work = std::path::Path::new(&args[3]);
    fs::write(work.join("ptt5.kcs1"), &frame).map_err(|e| e.to_string())?;
    fs::write(work.join("restored-ptt5"), &restored).map_err(|e| e.to_string())?;
    let payload = field(&frame, 20)?;
    println!(
        "{{\"schema\":1,\"complete_frame\":true,\"input_bytes\":{},\"input_sha256\":\"{}\",\"frame_sha256\":\"{}\",\"frame_bytes\":{},\"header_bytes\":40,\"count_model_bytes\":{},\"payload_including_finish_bytes\":{},\"stored_frame_bytes\":{},\"tokens\":{},\"copied\":{},\"literals\":{},\"literal_bits\":{},\"count_bytes\":{},\"final_width\":{},\"normal_cases\":[{}],\"rejections\":{},\"same_process_recoveries\":{},\"encode_ns_single\":{},\"decode_ns_single\":{},\"logical_allocation_bound_bytes\":8388608,\"size_screen_go\":{}}}",
        raw.len(),
        args[2],
        sha(&frame),
        frame.len(),
        meta,
        payload,
        raw.len() + 40,
        stats.tokens,
        stats.copied,
        stats.literals,
        stats.literals * 8,
        stats.count_bytes,
        stats.final_width,
        cases.join(","),
        rejects,
        rejects,
        encode_ns,
        decode_ns,
        frame.len() < 46202
    );
    Ok(())
}
fn main() {
    if let Err(e) = main_run() {
        eprintln!("E2E failed: {e}");
        std::process::exit(1);
    }
}
