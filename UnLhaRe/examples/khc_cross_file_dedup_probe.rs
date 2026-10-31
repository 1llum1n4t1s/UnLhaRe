//! 事前登録された開発pair専用のKCD1 size-first E2E。製品形式ではない。
use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
};
use unlhare::khc::{self, BlockStrategy};

const FILE_CAP: usize = 1 << 20;
const ARCHIVE_CAP: usize = 8 << 20;
const NAMES: [&str; 2] = ["plink-0.82.exe", "plink-0.83.exe"];
type R<T> = Result<T, String>;
fn require(ok: bool, message: &str) -> R<()> {
    if ok { Ok(()) } else { Err(message.into()) }
}
fn crc(b: &[u8]) -> u32 {
    crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, b) as u32
}
fn mix64(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}
fn chunks(bytes: &[u8]) -> Vec<&[u8]> {
    let gear: [u64; 256] = std::array::from_fn(|b| {
        mix64(0x4b48435f47454152u64.wrapping_add((b as u64).wrapping_mul(0x9e3779b97f4a7c15)))
    });
    let (mut start, mut h) = (0, 0u64);
    let mut out = Vec::new();
    for (i, &b) in bytes.iter().enumerate() {
        h = (h << 1).wrapping_add(gear[b as usize]);
        let n = i + 1 - start;
        if (n >= 512 && h & 2047 == 0) || n == 8192 {
            out.push(&bytes[start..=i]);
            start = i + 1;
            h = 0;
        }
    }
    if start < bytes.len() {
        out.push(&bytes[start..]);
    }
    out
}
#[derive(Clone)]
struct Record {
    kind: u8,
    raw: u32,
    payload: Vec<u8>,
}
#[derive(Clone)]
struct File {
    name: String,
    raw: u64,
    crc: u32,
    records: Vec<Record>,
}
fn child(b: &[u8]) -> R<Vec<u8>> {
    khc::compress_block_with_strategy(b, BlockStrategy::BinaryAdaptive).map_err(|e| e.to_string())
}
fn exact_id(base: &[&[u8]], b: &[u8], collision: bool) -> Option<usize> {
    base.iter()
        .position(|v| v.len() == b.len() && (collision || crc(v) == crc(b)) && *v == b)
}
fn encode(input: &[Vec<u8>; 2], mode: u8, collision: bool) -> R<Vec<u8>> {
    require(
        mode <= 2 && input.iter().all(|b| b.len() <= FILE_CAP),
        "encoder caps",
    )?;
    let base = chunks(&input[0]);
    let mut files = Vec::new();
    for (i, b) in input.iter().enumerate() {
        let parts = if mode == 0 {
            if b.is_empty() {
                vec![]
            } else {
                vec![b.as_slice()]
            }
        } else {
            chunks(b)
        };
        let mut records = Vec::new();
        for part in parts {
            let frame = child(part)?;
            let id = if mode == 2 && i == 1 && frame.len() > 4 {
                exact_id(&base, part, collision)
            } else {
                None
            };
            records.push(Record {
                kind: u8::from(id.is_some()),
                raw: part.len() as u32,
                payload: id.map_or(frame, |id| (id as u32).to_le_bytes().to_vec()),
            });
        }
        files.push(File {
            name: NAMES[i].into(),
            raw: b.len() as u64,
            crc: crc(b),
            records,
        });
    }
    Ok(wire(
        mode,
        input.iter().map(|b| b.len() as u64).sum(),
        &files,
    ))
}
fn wire(mode: u8, total: u64, files: &[File]) -> Vec<u8> {
    let mut b = b"KCD1".to_vec();
    b.extend(1u16.to_le_bytes());
    b.push(mode);
    b.push(files.len() as u8);
    b.extend(total.to_le_bytes());
    for f in files {
        b.extend((f.name.len() as u16).to_le_bytes());
        b.extend(f.name.as_bytes());
        b.extend(f.raw.to_le_bytes());
        b.extend(f.crc.to_le_bytes());
        b.extend((f.records.len() as u32).to_le_bytes());
        for r in &f.records {
            b.push(r.kind);
            b.extend(r.raw.to_le_bytes());
            b.extend((r.payload.len() as u32).to_le_bytes());
            b.extend(&r.payload);
        }
    }
    b
}
struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> R<&'a [u8]> {
        let end = self.at.checked_add(n).ok_or("extent overflow")?;
        let b = self.b.get(self.at..end).ok_or("truncated")?;
        self.at = end;
        Ok(b)
    }
    fn u8(&mut self) -> R<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> R<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> R<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> R<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
}
fn decode(b: &[u8]) -> R<[Vec<u8>; 2]> {
    require(b.len() <= ARCHIVE_CAP, "archive cap")?;
    let mut p = Reader { b, at: 0 };
    require(p.take(4)? == b"KCD1" && p.u16()? == 1, "magic/version")?;
    let mode = p.u8()?;
    require(mode <= 2 && p.u8()? == 2, "mode/file count")?;
    let total = p.u64()?;
    require(total <= (2 * FILE_CAP) as u64, "total cap")?;
    let mut result: [Vec<u8>; 2] = Default::default();
    let mut names = Vec::new();
    let mut base = Vec::new();
    let mut sum = 0u64;
    let mut count_sum = 0usize;
    for i in 0..2 {
        let name_len = p.u16()? as usize;
        require((1..=32).contains(&name_len), "name cap")?;
        let name = p.take(name_len)?;
        require(
            name.is_ascii()
                && name != b"."
                && name != b".."
                && !name.contains(&b'/')
                && !name.contains(&b'\\')
                && !name.contains(&0)
                && !names.contains(&name),
            "basename",
        )?;
        names.push(name);
        let raw = p.u64()?;
        require(raw <= FILE_CAP as u64, "file cap")?;
        sum = sum.checked_add(raw).ok_or("raw overflow")?;
        require(sum <= total, "raw sum")?;
        let expected_crc = p.u32()?;
        let count = p.u32()? as usize;
        let limit = if mode == 0 {
            usize::from(raw != 0)
        } else {
            (raw as usize).div_ceil(512)
        };
        count_sum = count_sum.checked_add(count).ok_or("count overflow")?;
        require(
            count <= limit && count_sum <= 4096 && (raw != 0 || count == 0),
            "count cap",
        )?;
        // 残りwire長も確認し、攻撃者のcountで先行確保しない。
        require(
            count.checked_mul(9).is_some_and(|n| n <= b.len() - p.at),
            "record extent",
        )?;
        let mut lengths = Vec::new();
        for _ in 0..count {
            let kind = p.u8()?;
            let len = p.u32()? as usize;
            let payload_len = p.u32()? as usize;
            require(
                len > 0 && len <= if mode == 0 { FILE_CAP } else { 8192 },
                "chunk cap",
            )?;
            let end = result[i].len().checked_add(len).ok_or("decoded overflow")?;
            require(
                end <= raw as usize && payload_len <= FILE_CAP + 40,
                "record length",
            )?;
            let payload = p.take(payload_len)?;
            let decoded = match kind {
                0 => {
                    // BinaryAdaptiveはKHC1BLK完全frameのみ。子decoderの確保前にraw欄を照合。
                    require(
                        payload.len() >= 40 && &payload[..8] == b"KHC1BLK\0",
                        "child header",
                    )?;
                    require(
                        u32::from_le_bytes(payload[12..16].try_into().unwrap()) as usize == len,
                        "child decoded size",
                    )?;
                    khc::decompress_block(payload).map_err(|e| e.to_string())?
                }
                1 => {
                    require(mode == 2 && i == 1 && payload_len == 4, "reference context")?;
                    let id = u32::from_le_bytes(payload.try_into().unwrap()) as usize;
                    let bytes: &Vec<u8> = base.get(id).ok_or("reference ID")?;
                    require(bytes.len() == len, "reference length")?;
                    bytes.clone()
                }
                _ => return Err("record kind".into()),
            };
            require(decoded.len() == len, "decoded length")?;
            if i == 0 {
                base.push(decoded.clone());
            }
            lengths.push(len);
            result[i].extend(decoded);
        }
        require(
            result[i].len() == raw as usize && crc(&result[i]) == expected_crc,
            "file length/CRC",
        )?;
        if mode == 0 {
            require(count == usize::from(raw != 0), "full-file layout")?;
        } else {
            require(
                chunks(&result[i]).iter().map(|b| b.len()).eq(lengths),
                "CDC layout",
            )?;
        }
    }
    require(sum == total && p.at == b.len(), "total/trailing")?;
    Ok(result)
}
fn fixture(n: usize) -> Vec<u8> {
    (0..n)
        .map(|i| (131usize.wrapping_mul(i).wrapping_add(17)) as u8)
        .collect()
}
fn run_e2e_checks() -> R<usize> {
    let mut checks = 0;
    for n in [0, 1, 511, 512, 8191, 8192, 8193] {
        let pair = [fixture(n), fixture(n)];
        for mode in 0..=2 {
            let b = encode(&pair, mode, false)?;
            require(
                decode(&b)? == pair && encode(&pair, mode, false)? == b,
                "fixture roundtrip/determinism",
            )?;
            checks += 1;
        }
        let joined = chunks(&pair[0]);
        require(
            joined.iter().all(|c| chunks(c).len() == 1) && chunks(&pair[0]) == chunks(&pair[1]),
            "reset/file independence",
        )?;
        checks += 1;
    }
    let repeated = vec![0xa5; 16384];
    let full = chunks(&repeated)[0].to_vec();
    let mut different = full.clone();
    different[0] ^= 1;
    require(
        exact_id(&[&full, &full], &full, true) == Some(0)
            && exact_id(&[&full], &different, true).is_none(),
        "collision/min ID",
    )?;
    checks += 1;
    let pair = [[full.clone(), full.clone()].concat(), full.clone()];
    let valid = encode(&pair, 2, false)?;
    require(decode(&valid)? == pair, "duplicate base")?;
    checks += 1;
    let mut p = Reader { b: &valid, at: 16 };
    let mut files = Vec::new();
    for _ in 0..2 {
        let n = p.u16()? as usize;
        let name = String::from_utf8(p.take(n)?.to_vec()).map_err(|e| e.to_string())?;
        let raw = p.u64()?;
        let c = p.u32()?;
        let count = p.u32()?;
        let mut records = Vec::new();
        for _ in 0..count {
            let kind = p.u8()?;
            let raw = p.u32()?;
            let n = p.u32()? as usize;
            records.push(Record {
                kind,
                raw,
                payload: p.take(n)?.to_vec(),
            });
        }
        files.push(File {
            name,
            raw,
            crc: c,
            records,
        });
    }
    require(
        files[0].records.iter().all(|r| r.kind == 0)
            && files[1].records[0].kind == 1
            && files[1].records[0].payload == 0u32.to_le_bytes(),
        "base children/min reference",
    )?;
    checks += 1;
    let total = pair.iter().map(|b| b.len() as u64).sum();
    let mut bad = Vec::new();
    for n in 0..valid.len() {
        bad.push(valid[..n].to_vec());
    }
    let mut b = valid.clone();
    b.push(0);
    bad.push(b);
    for (at, value) in [(0, 0), (4, 2), (6, 3), (7, 3)] {
        let mut b = valid.clone();
        b[at] = value;
        bad.push(b);
    }
    for name in [
        "",
        ".",
        "..",
        "a/b",
        "a\\b",
        "é",
        "123456789012345678901234567890123",
    ] {
        let mut f = files.clone();
        f[0].name = name.into();
        bad.push(wire(2, total, &f));
    }
    let mut f = files.clone();
    f[1].name = f[0].name.clone();
    bad.push(wire(2, total, &f));
    for raw in [u64::MAX, (FILE_CAP + 1) as u64, files[0].raw + 1] {
        let mut f = files.clone();
        f[0].raw = raw;
        bad.push(wire(2, total, &f));
    }
    bad.push(wire(2, u64::MAX, &files));
    bad.push(wire(2, total + 1, &files));
    let count_at = 16 + 2 + files[0].name.len() + 8 + 4;
    for count in [u32::MAX, 4097, 0] {
        let mut b = valid.clone();
        b[count_at..count_at + 4].copy_from_slice(&count.to_le_bytes());
        bad.push(b);
    }
    for len in [0, 8193, u32::MAX, files[0].records[0].raw + 1] {
        let mut f = files.clone();
        f[0].records[0].raw = len;
        bad.push(wire(2, total, &f));
    }
    let mut f = files.clone();
    f[0].crc ^= 1;
    bad.push(wire(2, total, &f));
    let mut f = files.clone();
    f[0].records[0].payload[0] ^= 1;
    bad.push(wire(2, total, &f));
    let mut f = files.clone();
    let last = f[0].records[0].payload.len() - 1;
    f[0].records[0].payload[last] ^= 1;
    bad.push(wire(2, total, &f));
    let mut f = files.clone();
    f[0].records[0].kind = 9;
    bad.push(wire(2, total, &f));
    for id in [files[0].records.len() as u32, u32::MAX] {
        let mut f = files.clone();
        f[1].records[0].payload = id.to_le_bytes().to_vec();
        bad.push(wire(2, total, &f));
    }
    let mut f = files.clone();
    f[1].records[0].raw -= 1;
    bad.push(wire(2, total, &f));
    for payload in [
        vec![],
        vec![0; 3],
        vec![0; 5],
        files[0].records[0].payload.clone(),
    ] {
        let mut f = files.clone();
        f[1].records[0].payload = payload;
        bad.push(wire(2, total, &f));
    }
    let mut f = files.clone();
    f[0].records[0] = Record {
        kind: 1,
        raw: full.len() as u32,
        payload: 0u32.to_le_bytes().to_vec(),
    };
    bad.push(wire(2, total, &f));
    bad.push(wire(0, total, &files));
    bad.push(wire(1, total, &files));
    // 子frame/descriptorを正しく再封印しても511-byte内部chunkは不正。
    let raw = fixture(8193);
    let mut f = files.clone();
    f[0].raw = raw.len() as u64;
    f[0].crc = crc(&raw);
    f[0].records = vec![
        Record {
            kind: 0,
            raw: 511,
            payload: child(&raw[..511])?,
        },
        Record {
            kind: 0,
            raw: 7682,
            payload: child(&raw[511..])?,
        },
    ];
    bad.push(wire(2, f[0].raw + f[1].raw, &f));
    // 同長だが別byteの正しい子frameはdescriptor CRCで拒否。
    let mut f = files.clone();
    f[0].records[0].payload = child(&different)?;
    bad.push(wire(2, total, &f));
    // 子frameのCRC欄を再封印してもraw欄の矛盾は拒否する。
    let mut f = files.clone();
    let frame = &mut f[0].records[0].payload;
    frame[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
    let mut digest = crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc);
    digest.update(&frame[..36]);
    digest.update(&frame[40..]);
    frame[36..40].copy_from_slice(&(digest.finalize() as u32).to_le_bytes());
    bad.push(wire(2, total, &f));
    let record_at = count_at + 4;
    let mut b = valid.clone();
    b[record_at + 5..record_at + 9].copy_from_slice(&u32::MAX.to_le_bytes());
    bad.push(b);
    let mut f = files.clone();
    f[0].records[0].raw = (FILE_CAP + 1) as u32;
    bad.push(wire(0, total, &f));
    require(
        full != different && sha256(&full) != sha256(&different),
        "byte/SHA mismatch detection",
    )?;
    checks += 1;
    for b in bad {
        require(decode(&b).is_err(), "malformed accepted")?;
        require(decode(&valid)? == pair, "recovery after reject")?;
        checks += 1;
    }
    require(decode(&vec![0; ARCHIVE_CAP + 1]).is_err(), "archive cap")?;
    checks += 1;
    let ramp: Vec<u8> = (0..16384).map(|i| i as u8).collect();
    let pair = [ramp.clone(), ramp];
    for mode in 0..=2 {
        require(
            decode(&encode(&pair, mode, true)?)? == pair,
            "ramp collision roundtrip",
        )?;
        checks += 1;
    }
    Ok(checks)
}
fn create(path: &Path, bytes: &[u8]) -> R<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    f.write_all(bytes).map_err(|e| e.to_string())
}
// khc_lab.rsのローカルSHA-256と同じ定数・round式。依存追加なし。
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
    let a: Vec<_> = env::args_os().skip(1).collect();
    require(a.len() == 3, "expected input0 input1 report")?;
    for p in &a[..2] {
        require(
            fs::metadata(p).map_err(|e| e.to_string())?.len() <= FILE_CAP as u64,
            "input cap",
        )?;
    }
    let input = [
        fs::read(&a[0]).map_err(|e| e.to_string())?,
        fs::read(&a[1]).map_err(|e| e.to_string())?,
    ];
    require(
        input[0].len() == 856688 && input[1].len() == 868976,
        "fixed pair sizes",
    )?;
    let expected = [
        "a86180e9a7ac473ad52fbab2842a1554581c536dd6e112fae9c824dd1041af20",
        "7308e9d356f14aa1f08cab1af363f71a077bf35dcb49e50b363418044758cd1e",
    ];
    let hashes: Vec<_> = input.iter().map(|b| sha256(b)).collect();
    require(
        hashes.iter().zip(expected).all(|(a, b)| a == b),
        "fixed input SHA",
    )?;
    require(
        sha256(b"abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA known vector",
    )?;
    let checks = run_e2e_checks()?;
    let mut sizes = Vec::new();
    let mut archive_hashes = Vec::new();
    for mode in 0..=2 {
        let b = encode(&input, mode, false)?;
        let decoded = decode(&b)?;
        require(
            b == encode(&input, mode, false)?
                && decoded == input
                && decoded.iter().map(|b| sha256(b)).eq(hashes.iter().cloned()),
            "input roundtrip/determinism/SHA",
        )?;
        sizes.push(b.len() as u64);
        archive_hashes.push(sha256(&b));
    }
    let gate = 20 * sizes[2] <= 19 * sizes[0] && sizes[2] < sizes[1];
    let report = serde_json::json!({"schema":1,"input_bytes":[856688,868976],"input_sha256":hashes,"e2e_checks_passed":checks,"roundtrip":true,"deterministic":true,"full_input_match":true,"serialized_bytes":sizes,"serialized_sha256":archive_hashes,"size_gate":gate,"decision":if gate {"go"} else {"no-go"}});
    let bytes = serde_json::to_vec(&report).map_err(|e| e.to_string())?;
    require(bytes.len() <= 32768, "report cap")?;
    create(Path::new(&a[2]), &bytes)
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
