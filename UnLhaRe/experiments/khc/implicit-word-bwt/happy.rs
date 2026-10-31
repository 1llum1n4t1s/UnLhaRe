use crate::implicit::{self as c, Result};
const CALLER: usize = 4 << 20;
fn check(ok: bool, name: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(format!("happy: {name}")) }
}

// @happypath @category happy,boundary @severity HIGH
// @description first-occurrence IDと語境界が再現すること @expected 既知stream、全raw byte。
fn words() -> Result<usize> {
    let (s, d) = c::transform(b"abc abc", CALLER)?.ok_or("tiny transform")?;
    check(s == b"abc \0\x01" && d == 1, "first occurrence word ID")?;
    check(c::restore(&s, 7, CALLER)?.0 == b"abc abc", "EOI reference")?;
    let (s, d) = c::transform(b"abc ABC abc ABC", CALLER)?.ok_or("case transform")?;
    check(s == b"abc ABC \0\x01 \0\x02" && d == 2, "case sensitive IDs")?;
    check(c::restore(&s, 15, CALLER)?.0 == b"abc ABC abc ABC", "case recovery")?;
    for len in [2, 3, 64, 65] {
        let word = vec![b'a'; len];
        let mut raw = word.clone();
        raw.push(b' ');
        raw.extend_from_slice(&word);
        let (s, d) = c::transform(&raw, CALLER)?.ok_or("boundary transform")?;
        check(d == usize::from((3..=64).contains(&len)), "word eligibility boundary")?;
        check(c::restore(&s, raw.len(), CALLER)?.0 == raw, "word boundary bytes")?;
    }
    Ok(8)
}

// @happypath @category happy,boundary,resource @severity HIGH
// @description 先着辞書が16384でfreezeすること @expected 未登録末語literal、先頭語ID0、全byte。
fn dictionary_limit() -> Result<usize> {
    let mut raw = Vec::new();
    let mut last = Vec::new();
    let mut maximum = Vec::new();
    for i in 0..16385usize {
        let word = [
            b'w',
            b'a' + (i / 17576 % 26) as u8,
            b'a' + (i / 676 % 26) as u8,
            b'a' + (i / 26 % 26) as u8,
            b'a' + (i % 26) as u8,
        ];
        raw.extend_from_slice(&word);
        raw.push(b' ');
        last = word.to_vec();
        if i == 16383 {
            maximum = word.to_vec();
        }
    }
    raw.extend_from_slice(&last);
    raw.extend_from_slice(b" waaaa");
    let (s, d) = c::transform(&raw, CALLER)?.ok_or("dictionary transform")?;
    check(d == 16384 && s.ends_with(b"\0\x01"), "dictionary freeze and existing ID")?;
    check(c::restore(&s, raw.len(), CALLER)?.0 == raw, "full dictionary bytes")?;
    raw.push(b' ');
    raw.extend_from_slice(&maximum);
    let (s, d) = c::transform(&raw, CALLER)?.ok_or("maximum ID transform")?;
    check(d == 16384 && s.ends_with(&[0, 0x80, 0x80, 1]), "largest dictionary ID three-byte varint")?;
    check(c::restore(&s, raw.len(), CALLER)?.0 == raw, "largest dictionary ID bytes")?;
    Ok(4)
}

// @happypath @category happy,boundary @severity HIGH
// @description 完全private frameが空/全byte/Unicode/乱数/codedを復元すること @expected 全byteとdeterministic frame。
fn frames() -> Result<usize> {
    let mut seed = 0x243f6a88u32;
    let random: Vec<u8> = (0..4096)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        })
        .collect();
    let cases = vec![
        vec![],
        vec![0],
        vec![255],
        (0..=255).collect(),
        "日本語\0\r\n\t👩‍💻".as_bytes().to_vec(),
        random,
        b"alpha beta gamma\n".repeat(1024),
    ];
    for raw in &cases {
        let (frame, stat) = c::encode(raw, CALLER)?;
        check(c::decode(&frame, CALLER)?.0 == *raw, "private frame bytes")?;
        check(stat.logical_peak <= 64 << 20 && frame.len() <= raw.len() + 40, "private frame bounds")?;
        check(c::encode(raw, CALLER)?.0 == frame, "deterministic frame")?;
    }
    let raw = vec![0; c::MAX_RAW];
    check(c::transform(&raw, CALLER)?.is_none(), "transform cap fallback")?;
    let (frame, stat) = c::encode(&raw, CALLER)?;
    check(stat.method == 0 && c::decode(&frame, CALLER)?.0 == raw, "maximum stored bytes")?;
    let (frame, stat) = c::encode(&b"alpha beta gamma\n".repeat(1024), CALLER)?;
    check(stat.method == 1 && frame[9] == 1, "actual coded normal path")?;
    Ok(cases.len() * 3 + 3)
}
pub fn run() -> Result<usize> {
    Ok(words()? + dictionary_limit()? + frames()?)
}
