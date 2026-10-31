//! 固定開発入力だけに使うKHT1 size-first probe。製品形式ではない。
use std::{
    env,
    fs::{File, OpenOptions},
    io::{Read, Write},
};
use unlhare::khc::{self, BlockStrategy};

const CAP: usize = 1 << 20;
const INPUT_SHA: &str = "e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61";
type R<T> = Result<T, String>;
type Span = (u8, usize, usize);

fn require(ok: bool, message: &str) -> R<()> {
    if ok { Ok(()) } else { Err(message.into()) }
}

fn push_span(spans: &mut Vec<Span>, kind: u8, start: usize, end: usize) {
    if start == end {
        return;
    }
    if let Some(last) = spans.last_mut()
        && last.0 == kind
    {
        last.2 = end;
        return;
    }
    spans.push((kind, start, end));
}

fn spans(input: &[u8]) -> Vec<Span> {
    let mut spans = Vec::new();
    let (mut text, mut at) = (0, 0);
    while at < input.len() {
        if input[at] != b'<' {
            at += 1;
            continue;
        }
        let start = at;
        let mut quote = 0;
        at += 1;
        while at < input.len() {
            let b = input[at];
            if quote != 0 {
                if b == quote {
                    quote = 0;
                }
            } else if b == b'\'' || b == b'"' {
                quote = b;
            } else if b == b'>' {
                break;
            }
            at += 1;
        }
        // 閉じない候補以後は、すべて同じ本文suffixとして保持する。
        if at == input.len() {
            break;
        }
        push_span(&mut spans, 0, text, start);
        push_span(&mut spans, 1, start, at + 1);
        at += 1;
        text = at;
    }
    push_span(&mut spans, 0, text, input.len());
    spans
}

fn encode(input: &[u8]) -> R<Option<Vec<u8>>> {
    require(input.len() <= CAP, "raw cap")?;
    let spans = spans(input);
    let size = spans
        .len()
        .checked_mul(5)
        .and_then(|n| n.checked_add(12))
        .and_then(|n| n.checked_add(input.len()))
        .ok_or("transform length overflow")?;
    if size > CAP {
        return Ok(None);
    }
    let mut out = Vec::with_capacity(size);
    out.extend(b"KHT1");
    out.extend((input.len() as u32).to_le_bytes());
    out.extend((spans.len() as u32).to_le_bytes());
    for &(kind, start, end) in &spans {
        out.push(kind);
        out.extend(((end - start) as u32).to_le_bytes());
    }
    for kind in [0, 1] {
        for &(k, start, end) in &spans {
            if k == kind {
                out.extend(&input[start..end]);
            }
        }
    }
    require(out.len() == size, "transform extent")?;
    Ok(Some(out))
}

fn word(frame: &[u8], at: usize) -> R<usize> {
    let end = at.checked_add(4).ok_or("word overflow")?;
    let bytes = frame.get(at..end).ok_or("truncated word")?;
    Ok(u32::from_le_bytes(bytes.try_into().map_err(|_| "word")?) as usize)
}

fn decode(frame: &[u8]) -> R<Vec<u8>> {
    require(frame.len() <= CAP, "transform cap")?;
    require(frame.get(..4) == Some(b"KHT1"), "magic/version")?;
    let raw = word(frame, 4)?;
    let count = word(frame, 8)?;
    require(raw <= CAP && count <= raw, "raw/count cap")?;
    require((raw == 0) == (count == 0), "empty count")?;
    let stream = count
        .checked_mul(5)
        .and_then(|n| n.checked_add(12))
        .ok_or("descriptor overflow")?;
    require(stream <= frame.len(), "truncated descriptors")?;
    let mut totals = [0usize; 2];
    let mut previous = None;
    for i in 0..count {
        let at = 12 + i * 5;
        let kind = frame[at];
        require(kind <= 1 && previous != Some(kind), "kind/alternation")?;
        let len = word(frame, at + 1)?;
        require(len > 0, "zero span")?;
        totals[kind as usize] = totals[kind as usize]
            .checked_add(len)
            .ok_or("length sum overflow")?;
        require(totals[kind as usize] <= raw, "length sum overrun")?;
        previous = Some(kind);
    }
    require(totals[0].checked_add(totals[1]) == Some(raw), "raw sum")?;
    require(stream.checked_add(raw) == Some(frame.len()), "stream/EOF")?;
    let mut offsets = [stream, stream + totals[0]];
    let mut out = Vec::with_capacity(raw);
    for i in 0..count {
        let at = 12 + i * 5;
        let kind = frame[at] as usize;
        let end = offsets[kind]
            .checked_add(word(frame, at + 1)?)
            .ok_or("stream extent overflow")?;
        out.extend(frame.get(offsets[kind]..end).ok_or("stream extent")?);
        offsets[kind] = end;
    }
    require(out.len() == raw, "decoded length")?;
    Ok(out)
}

fn child(input: &[u8]) -> R<Vec<u8>> {
    require(input.len() <= CAP, "child input cap")?;
    khc::compress_block_with_strategy(input, BlockStrategy::BinaryAdaptive)
        .map_err(|e| e.to_string())
}

fn restore(frame: &[u8]) -> R<Vec<u8>> {
    khc::decompress_block(frame).map_err(|e| e.to_string())
}

fn reject_child_damage(frame: &[u8]) -> R<()> {
    require(!frame.is_empty(), "empty child frame")?;
    // 小さい合成frameは全prefix、固定入力frameは各構造境界と末尾を確認する。
    let cuts = if frame.len() <= 256 {
        (0..frame.len()).collect::<Vec<_>>()
    } else {
        vec![0, 1, 4, 8, 12, frame.len() / 2, frame.len() - 1]
    };
    for cut in cuts {
        require(restore(&frame[..cut]).is_err(), "child truncation accepted")?;
    }
    let mut damaged = frame.to_vec();
    damaged[0] ^= 0x80;
    require(
        restore(&damaged).is_err(),
        "child magic corruption accepted",
    )?;
    damaged.copy_from_slice(frame);
    let last = damaged.len() - 1;
    damaged[last] ^= 0x80;
    require(
        restore(&damaged).is_err(),
        "child payload corruption accepted",
    )
}

fn e2e() -> R<Vec<serde_json::Value>> {
    require(
        sha256(b"abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256 known answer",
    )?;
    let cases: &[(&str, &[u8], &[(u8, usize)])] = &[
        ("empty", b"", &[]),
        ("plain-no-tag", b"plain", &[(0, 5)]),
        ("simple-tag", b"a<b>c", &[(0, 1), (1, 3), (0, 1)]),
        ("quoted-angle", b"<a x='>' y=\">\">z", &[(1, 15), (0, 1)]),
        ("angle-in-text", b"a>b", &[(0, 3)]),
        ("adjacent-tags-merged", b"<a><b>", &[(1, 6)]),
        ("less-than-inside-tag", b"<<x>", &[(1, 4)]),
        ("unterminated-less-than", b"a<x", &[(0, 3)]),
        ("unmatched-quote", b"a<x='>tail", &[(0, 10)]),
        (
            "arbitrary-bytes",
            b"\xff\0<\x80>\xfe",
            &[(0, 2), (1, 3), (0, 1)],
        ),
        ("quote-only-in-tag", b"'<x>\"", &[(0, 1), (1, 3), (0, 1)]),
        ("unterminated-after-tag", b"<x>a<z", &[(1, 3), (0, 3)]),
    ];
    let mut table = Vec::new();
    for &(name, input, expected) in cases {
        let actual: Vec<_> = spans(input).iter().map(|&(k, s, e)| (k, e - s)).collect();
        require(actual == expected, name)?;
        let encoded = encode(input)?.ok_or("small transform unavailable")?;
        require(
            encode(input)?.as_ref() == Some(&encoded),
            "transform determinism",
        )?;
        let a = child(input)?;
        let c = child(&encoded)?;
        require(
            a == child(input)? && c == child(&encoded)?,
            "child determinism",
        )?;
        require(restore(&a)? == input, "baseline roundtrip")?;
        let decoded = decode(&restore(&c)?)?;
        require(
            decoded == input && sha256(&decoded) == sha256(input),
            "candidate SHA roundtrip",
        )?;
        reject_child_damage(&a)?;
        reject_child_damage(&c)?;
        table.push(serde_json::json!({"case":name,"passed":true}));
    }
    let mut cap_input = Vec::with_capacity(CAP);
    while cap_input.len() < CAP {
        cap_input.extend(b"<x>a");
    }
    require(encode(&cap_input)?.is_none(), "descriptor cap unavailable")?;
    table.push(serde_json::json!({"case":"patterned-1MiB-descriptor-cap","passed":true}));
    require(encode(&vec![0; CAP + 1]).is_err(), "raw cap accepted")?;
    table.push(serde_json::json!({"case":"raw-over-cap","passed":true}));

    let good = encode(b"a<x>b")?.ok_or("malformed seed")?;
    let mut malformed: Vec<(&str, Vec<u8>)> = Vec::new();
    for (name, at, bytes) in [
        ("wrong-magic", 0, b"BAD!".as_slice()),
        ("unknown-version", 0, b"KHT2".as_slice()),
        ("unknown-kind", 12, &[2]),
        ("zero-length", 13, &[0, 0, 0, 0]),
        ("nonempty-zero-count", 8, &[0, 0, 0, 0]),
        ("empty-nonzero-count", 4, &[0, 0, 0, 0]),
        ("count-over-raw", 8, &[6, 0, 0, 0]),
        ("sum-mismatch", 13, &[2, 0, 0, 0]),
        ("sum-overrun", 13, &[255, 255, 255, 255]),
        ("adjacent-same-kind", 17, &[0]),
    ] {
        let mut bad = good.clone();
        bad[at..at + bytes.len()].copy_from_slice(bytes);
        malformed.push((name, bad));
    }
    for (name, cut) in [
        ("truncated-header", 11),
        ("truncated-descriptor", 26),
        ("truncated-stream", good.len() - 1),
    ] {
        malformed.push((name, good[..cut].to_vec()));
    }
    let mut trailing = good.clone();
    trailing.push(0);
    malformed.push(("trailing-byte", trailing));
    let mut empty_bad = encode(b"")?.ok_or("empty seed")?;
    empty_bad.extend([0, 1, 0, 0, 0, 0]);
    malformed.push(("empty-trailing-descriptor", empty_bad));
    for (name, bad) in malformed {
        // 悪性KHT1も正常なBinaryAdaptive frameを経由させる。
        let frame = child(&bad)?;
        let recovered = restore(&frame)?;
        require(recovered == bad && decode(&recovered).is_err(), name)?;
        table.push(serde_json::json!({"case":name,"passed":true}));
    }
    Ok(table)
}

fn sha256(input: &[u8]) -> String {
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
    let mut s = [
        0x6a09e667u32,
        0xbb67ae85,
        0x3c6ef372,
        0xa54ff53a,
        0x510e527f,
        0x9b05688c,
        0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut bytes = input.to_vec();
    bytes.push(0x80);
    while bytes.len() % 64 != 56 {
        bytes.push(0);
    }
    bytes.extend(((input.len() as u64) * 8).to_be_bytes());
    for block in bytes.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, b) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes(b.try_into().unwrap());
        }
        for i in 16..64 {
            let x = w[i - 15];
            let y = w[i - 2];
            w[i] = w[i - 16]
                .wrapping_add(x.rotate_right(7) ^ x.rotate_right(18) ^ (x >> 3))
                .wrapping_add(w[i - 7])
                .wrapping_add(y.rotate_right(17) ^ y.rotate_right(19) ^ (y >> 10));
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = s;
        for i in 0..64 {
            let t = h
                .wrapping_add(e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25))
                .wrapping_add((e & f) ^ (!e & g))
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let u = (a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22))
                .wrapping_add((a & b) ^ (a & c) ^ (b & c));
            [h, g, f, e, d, c, b, a] = [g, f, e, d.wrapping_add(t), c, b, a, t.wrapping_add(u)];
        }
        for (x, y) in s.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *x = x.wrapping_add(y);
        }
    }
    s.iter().map(|w| format!("{w:08x}")).collect()
}

fn run() -> R<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    require(args.len() == 2, "expected fixed input and report path")?;
    let file = File::open(&args[0]).map_err(|e| e.to_string())?;
    require(
        file.metadata().map_err(|e| e.to_string())?.len() == 24603,
        "fixed input size",
    )?;
    let mut input = Vec::with_capacity(24603);
    file.take(24604)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    require(
        input.len() == 24603 && sha256(&input) == INPUT_SHA,
        "fixed input SHA-256",
    )?;
    let table = e2e()?;
    let baseline = child(&input)?;
    require(baseline == child(&input)?, "fixed baseline determinism")?;
    require(restore(&baseline)? == input, "fixed baseline roundtrip")?;
    reject_child_damage(&baseline)?;
    let tag_bytes: usize = spans(&input)
        .iter()
        .filter(|s| s.0 == 1)
        .map(|s| s.2 - s.1)
        .sum();
    let transformed = encode(&input)?;
    require(
        encode(&input)? == transformed,
        "fixed transform determinism",
    )?;
    let candidate = if let Some(bytes) = &transformed {
        let c = child(bytes)?;
        require(c == child(bytes)?, "fixed candidate determinism")?;
        let recovered = restore(&c)?;
        require(recovered == *bytes, "fixed transform child roundtrip")?;
        let decoded = decode(&recovered)?;
        require(
            decoded == input && sha256(&decoded) == INPUT_SHA,
            "fixed candidate SHA roundtrip",
        )?;
        reject_child_damage(&c)?;
        Some(c)
    } else {
        None
    };
    let gate = candidate
        .as_ref()
        .is_some_and(|c| tag_bytes > 0 && 20 * (c.len() as u64) <= 19 * (baseline.len() as u64));
    let report = serde_json::json!({
        "schema":1, "format":"KHT1", "input_bytes":input.len(), "input_sha256":INPUT_SHA,
        "e2e":table, "roundtrip":true, "deterministic":true,
        "recognized_tag_bytes":tag_bytes, "candidate_available":candidate.is_some(),
        "baseline_bytes":baseline.len(), "baseline_sha256":sha256(&baseline),
        "transform_bytes":transformed.as_ref().map(Vec::len),
        "transform_sha256":transformed.as_ref().map(|b| sha256(b)),
        "candidate_bytes":candidate.as_ref().map(Vec::len),
        "candidate_sha256":candidate.as_ref().map(|b| sha256(b)),
        "size_gate":gate, "decision":if gate {"go"} else {"no-go"}
    });
    let json = serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?;
    require(json.len() <= 32768, "report cap")?;
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&args[1])
        .and_then(|mut f| f.write_all(&json))
        .map_err(|e| e.to_string())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
