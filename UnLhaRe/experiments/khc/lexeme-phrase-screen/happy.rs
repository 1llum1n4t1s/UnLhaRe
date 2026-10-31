use crate::lexeme::{self as l, MAX_RAW, Result, TOTAL};

fn same(ok: bool, name: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(format!("happy: {name}")) }
}

// @happypath @category happy @severity HIGH
// @description 整数 Hamilton が既知の値と一致すること @expected 正値、総和 Q18、ID 順の余り。
fn frequencies() -> Result<usize> {
    for (input, expected) in [
        (vec![1, 1], vec![131072, 131072]),
        (vec![0, 0, 0], vec![87382, 87381, 87381]),
        (vec![7], vec![262144]),
        (vec![u32::MAX, u32::MAX], vec![131072, 131072]),
    ] {
        same(l::normalize(&input)? == expected, "Hamilton exact frequencies")?;
    }
    let max = l::normalize(&vec![0; TOTAL])?;
    same(max.len() == TOTAL && max.iter().all(|&n| n == 1), "maximum alphabet")?;
    Ok(5)
}

// 独立した u128 計数 oracle。コード生成物ではなく静的 rANS の整数遷移を照合する。
fn oracle(symbols: &[u16], a: &[u32], b: &[u32]) -> usize {
    let mut state = 8388608u128;
    let mut result = 4;
    for (index, &symbol) in symbols.iter().enumerate().rev() {
        let row = if index > 0 && symbols[index - 1] >= 256 { b } else { a };
        let frequency = u128::from(row[usize::from(symbol)]);
        while state >= frequency * 8192 {
            state /= 256;
            result += 1;
        }
        let quotient = state / frequency;
        let remainder = state - quotient * frequency;
        let start: u128 = row[..usize::from(symbol)].iter().map(|&n| u128::from(n)).sum();
        state = quotient * 262144 + remainder + start;
    }
    result
}

// @happypath @category happy @severity HIGH
// @description uniform bytes と異なる2文脈の計数が一致すること @expected n+4 / u128 oracle。
fn counters() -> Result<usize> {
    let uniform = vec![1024; 256];
    let bytes: Vec<u8> = (0..=255).collect();
    let symbols: Vec<u16> = bytes.iter().map(|&n| u16::from(n)).collect();
    same(l::ans_count(&symbols, &uniform, &[])? == 260, "uniform token byte fee")?;
    same(l::ans_byte_count(&bytes, &uniform)? == 260, "uniform dictionary byte fee")?;
    same(l::ans_count(&[], &uniform, &[])? == 4, "empty ANS state fee")?;
    let mut counts = vec![1; 258];
    counts[32] = 71;
    counts[256] = 89;
    counts[257] = 3;
    let row0 = l::normalize(&counts)?;
    let mut counts1 = vec![0; 256];
    counts1[32] = 5;
    counts1[0] = 2;
    let row1 = l::normalize(&counts1)?;
    for n in 0..64 {
        let mut seq = Vec::new();
        for i in 0..n {
            seq.extend_from_slice(&[if i % 2 == 0 { 256 } else { 257 }, if i % 3 == 0 { 0 } else { 32 }]);
        }
        same(l::ans_count(&seq, &row0, &row1)? == oracle(&seq, &row0, &row1), "two-context integer count")?;
    }
    Ok(67)
}

// @happypath @category boundary @severity HIGH
// @description 辞書の単語/句の境界と prefix varint を復元すること @expected 全辞書 byte 一致。
fn dictionary() -> Result<usize> {
    let basic: Vec<&[u8]> = vec![b"alpha", b"alpha beta", b"beta", b"beta alpha"];
    let coded = l::front_encode(&basic)?;
    same(
        l::front_decode(&coded, basic.len())?.iter().map(Vec::as_slice).eq(basic.iter().copied()),
        "front dictionary",
    )?;
    let mut long = vec![b'A'; 64];
    long.push(b' ');
    long.extend_from_slice(&[b'B'; 64]);
    let mut next = long.clone();
    next[128] = b'C';
    let edge: Vec<&[u8]> = vec![
        &long,
        &next,
        b"a b",
        b"aaa",
        b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ];
    let coded = l::front_encode(&edge)?;
    same(
        l::front_decode(&coded, edge.len())?.iter().map(Vec::as_slice).eq(edge.iter().copied()),
        "129-byte phrase / 128-byte prefix",
    )?;
    same(l::front_encode(&[])?.is_empty() && l::front_decode(&[], 0)?.is_empty(), "empty dictionary")?;
    Ok(3)
}

// @happypath @category happy,boundary @severity HIGH
// @description literal/単語/句/unused pruning と任意 byte を復元すること @expected 全 raw byte、固定 vocab。
fn frontend() -> Result<usize> {
    let mut seed = 0x243f6a88u32;
    let random: Vec<u8> = (0..4096)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        })
        .collect();
    let fixtures = vec![
        vec![],
        vec![0],
        vec![255],
        (0..=255).collect(),
        "日本語\0\r\n\t👩‍💻\u{200b}\u{202e}".as_bytes().to_vec(),
        vec![b'a'; 65],
        b"word\tword\r\nword".to_vec(),
        b"Abc def Abc def".to_vec(),
        b"ab cd ab cd".to_vec(),
        random,
    ];
    for raw in &fixtures {
        let a = l::analyze(raw)?;
        same(
            a.frontend_exact && a.dict_exact && a.logical_bound <= l::LIBRARY_RESERVE,
            "frontend and dictionary bytes",
        )?;
        same(a.estimated_frame_bytes <= raw.len() + 40, "stored fallback fee")?;
    }
    for raw in [b"Abc def Abc def".as_slice(), b"ab cd ab cd".as_slice()] {
        let a = l::analyze(raw)?;
        same((a.vocab, a.phrases, a.symbols) == (1, 1, 3), "phrase first / unused single pruning")?;
        let again = l::analyze(raw)?;
        same(
            (a.dict_box_bytes, a.model_bytes, a.ans_bytes) == (again.dict_box_bytes, again.model_bytes, again.ans_bytes),
            "deterministic fees",
        )?;
    }
    let max = l::analyze(&vec![0; MAX_RAW])?;
    same(max.frontend_exact && max.dict_exact && max.vocab == 0 && max.symbols == MAX_RAW, "maximum raw")?;
    Ok(fixtures.len() + 5)
}

pub fn run() -> Result<usize> {
    Ok(frequencies()? + counters()? + dictionary()? + frontend()?)
}
