use crate::lexeme::{self as l, MAX_DICT, MAX_RAW, Result, TOTAL};

fn reject<T>(result: Result<T>, name: &str) -> Result<()> {
    if result.is_err() {
        Ok(())
    } else {
        Err(format!("adversarial accepted: {name}"))
    }
}

// @adversarial @category resource @severity HIGH
// @description 宣言上限直後を実枯渇なしに拒否すること @expected Err、続く正常入力は成功。
fn limits() -> Result<usize> {
    reject(l::analyze(&vec![0; MAX_RAW + 1]), "raw limit")?;
    reject(l::normalize(&vec![1; TOTAL + 1]), "normalization alphabet limit")?;
    reject(l::front_decode(&[], MAX_DICT + 1), "dictionary count limit")?;
    reject(l::ans_count(&vec![0; MAX_RAW + 1], &[1024; 256], &[]), "symbol limit")?;
    if !l::analyze(b"Abc def Abc def")?.frontend_exact {
        return Err("normal recovery".into());
    }
    Ok(4)
}

// @adversarial @category type @severity HIGH
// @description 0頻度/不正総和/行/IDを拒否すること @expected Err、正常 uniform は n+4。
fn frequencies() -> Result<usize> {
    reject(l::normalize(&[]), "empty alphabet")?;
    let good = vec![1024; 256];
    let mut zero = good.clone();
    zero[0] = 0;
    zero[1] += 1024;
    let mut wrong = good.clone();
    wrong[0] += 1;
    for bad in [&zero, &wrong] {
        reject(l::ans_count(&[0], bad, &[]), "bad token frequencies")?;
        reject(l::ans_byte_count(&[0], bad), "bad dictionary frequencies")?;
    }
    reject(l::ans_count(&[256], &good, &[]), "bad ID")?;
    reject(l::ans_count(&[0], &good, &[1; 255]), "bad row1 alphabet")?;
    let extended = l::normalize(&vec![1; 258])?;
    reject(l::ans_count(&[256], &extended, &[]), "word without row1")?;
    reject(l::ans_count(&[256, 257], &extended, &good), "adjacent word IDs")?;
    reject(l::ans_count(&[258], &extended, &good), "ID above vocabulary")?;
    if l::ans_count(&[0, 255], &good, &[])? != 6 {
        return Err("frequency recovery".into());
    }
    Ok(10)
}

// @adversarial @category type,boundary @severity HIGH
// @description 切断/非canonical varint/LCP/重複/順序/文字を拒否すること @expected 各 Err、正常辞書は復元。
fn dictionary() -> Result<usize> {
    let words: Vec<&[u8]> = vec![b"alpha", b"alpha beta", b"beta"];
    let valid = l::front_encode(&words)?;
    let mut checks = 0;
    for cut in 0..valid.len() {
        reject(l::front_decode(&valid[..cut], words.len()), "every truncation")?;
        checks += 1;
    }
    let mut tail = valid.clone();
    tail.push(0);
    reject(l::front_decode(&tail, words.len()), "trailing dictionary bytes")?;
    checks += 1;
    for wire in [
        vec![0x80, 0, 3, b'a', b'b', b'c'],
        vec![1, 3, b'a', b'b', b'c'],
        vec![0, 3, b'a', b'b'],
        vec![0xff; 11],
        vec![0, 0],
    ] {
        reject(l::front_decode(&wire, 1), "malformed prefix/suffix/varint")?;
        checks += 1;
    }
    reject(l::front_decode(&[0], 0), "empty dictionary with tail")?;
    checks += 1;
    reject(l::front_decode(b"\x00\x05alpha\x05\x00", 2), "duplicate entry")?;
    checks += 1;
    reject(l::front_decode(b"\x00\x05alpha\x00\x08alphabet", 2), "non-LCP prefix")?;
    checks += 1;
    reject(l::front_decode(b"\x00\x04beta\x00\x05alpha", 2), "unsorted entries")?;
    checks += 1;
    let long = vec![b'a'; 65];
    let mut long_pair = long.clone();
    long_pair.extend_from_slice(b" b");
    for bad in [b"ab".as_slice(), b"a  b", b" a b", b"abc1", b"a b c", "日本語".as_bytes(), &long, &long_pair] {
        reject(l::front_encode(&[bad]), "illegal encoder word")?;
        let mut wire = vec![0, bad.len() as u8];
        wire.extend_from_slice(bad);
        reject(l::front_decode(&wire, 1), "illegal decoder word")?;
        checks += 2;
    }
    reject(l::front_encode(&[b"alpha", b"alpha"]), "encoder duplicate")?;
    reject(l::front_encode(&[b"beta", b"alpha"]), "encoder order")?;
    checks += 2;
    if !l::front_decode(&valid, words.len())?.iter().map(Vec::as_slice).eq(words.iter().copied()) {
        return Err("dictionary recovery".into());
    }
    Ok(checks)
}

pub fn run() -> Result<usize> {
    Ok(limits()? + frequencies()? + dictionary()?)
}
