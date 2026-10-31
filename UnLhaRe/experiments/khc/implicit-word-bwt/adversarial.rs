use crate::implicit::{self as c, Result};
const CALLER: usize = 4 << 20;
fn rejected<T>(x: Result<T>, name: &str) -> Result<()> {
    if x.is_err() { Ok(()) } else { Err(format!("accepted: {name}")) }
}
pub fn wrap(stream: &[u8], raw: &[u8]) -> Result<Vec<u8>> {
    let body = unlhare::khc::compress_block(stream).map_err(|e| e.to_string())?;
    let mut f = vec![0u8; 40];
    f[..8].copy_from_slice(b"KWI1BLK\0");
    f[8] = 1;
    f[9] = 1;
    for (at, n) in [(12, raw.len()), (16, stream.len()), (20, body.len()), (32, 16384)] {
        f[at..at + 4].copy_from_slice(&(n as u32).to_le_bytes());
    }
    f[24..28].copy_from_slice(&c::crc(raw).to_le_bytes());
    f.extend_from_slice(&body);
    c::seal(&mut f)?;
    Ok(f)
}

// @adversarial @category type,boundary @severity HIGH
// @description 不正varint/未来ID/語結合/長さを拒否すること @expected 直接restore Err、正常へ回復。
fn stream() -> Result<usize> {
    for (b, n) in [
        (b"\0".as_slice(), 3),
        (b"\0\x80\0", 3),
        (b"\0\xff\xff\xff", 3),
        (b"\0\x01", 3),
        (b"abc \0\x02", 7),
        (b"abc abc\0\x01", 10),
        (b"abc \0\x01d", 8),
        (b"abc", 2),
        (b"abc", 4),
    ] {
        rejected(c::restore(b, n, CALLER), "stream grammar")?;
    }
    if c::restore(b"abc \0\x01", 7, CALLER)?.0 != b"abc abc" {
        return Err("stream recovery".into());
    }
    Ok(9)
}

// @adversarial @category type,boundary @severity HIGH
// @description 切断/CRC/未知識別子/整合しない長さを拒否すること @expected 外側再CRC後もsemantic Err。
fn frame() -> Result<usize> {
    let base = c::encode(b"abc abc", CALLER)?.0;
    let mut checks = 0;
    for at in 0..base.len() {
        rejected(c::decode(&base[..at], CALLER), "stored truncation")?;
        checks += 1;
    }
    for at in [0, 8, 9, 10, 11, 12, 16, 20, 24, 32, 36] {
        let mut bad = base.clone();
        bad[at] ^= 0x7f;
        c::seal(&mut bad)?;
        rejected(c::decode(&bad, CALLER), "resealed header semantics")?;
        checks += 1;
    }
    let mut bad = base.clone();
    *bad.last_mut().ok_or("base")? ^= 1;
    rejected(c::decode(&bad, CALLER), "outer wire CRC")?;
    checks += 1;
    let good = wrap(b"abc \0\x01", b"abc abc")?;
    if c::decode(&good, CALLER)?.0 != b"abc abc" {
        return Err("valid manual coded frame".into());
    }
    for at in 0..good.len() {
        rejected(c::decode(&good[..at], CALLER), "coded truncation")?;
        checks += 1;
    }
    for at in [40, 52, 68] {
        let mut bad = good.clone();
        bad[at] ^= 1;
        c::seal(&mut bad)?;
        rejected(c::decode(&bad, CALLER), "inner semantic/CRC")?;
        checks += 1;
    }
    for (b, r) in [
        (b"abc \0\x02".as_slice(), b"abc abc".as_slice()),
        (b"abc abc\0\x01", b"abc abcabc"),
        (b"abc \0\x01d", b"abc abcd"),
    ] {
        rejected(c::decode(&wrap(b, r)?, CALLER), "coded grammar with valid outer CRC")?;
        checks += 1;
    }
    Ok(checks)
}

// @adversarial @category resource @severity HIGH
// @description 宣言上限とcaller費を実枯渇なしに拒否すること @expected 事前Err、正常復元回復。
fn limits() -> Result<usize> {
    rejected(c::encode(&vec![0; c::MAX_RAW + 1], CALLER), "raw upper")?;
    rejected(c::restore(&[], c::MAX_RAW + 1, CALLER), "restore upper")?;
    rejected(c::restore(&vec![0; c::MAX_STREAM + 1], 0, CALLER), "stream upper")?;
    rejected(c::encode(b"abc abc", 64 << 20), "caller upper")?;
    let good = c::encode(b"abc abc", CALLER)?.0;
    if c::decode(&good, CALLER)?.0 != b"abc abc" {
        return Err("limit recovery".into());
    }
    Ok(4)
}
pub fn run() -> Result<usize> {
    Ok(stream()? + frame()? + limits()?)
}
