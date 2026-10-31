//! KHCの実書庫・ファイル公開・失敗順序を検証する独立E2E実行例。
//! 引数: Canterbury書庫、元コーパス、新規の外部Temp出力ディレクトリ。
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
use unlhare::{ExtractOptions, Limits, khc};

fn tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(base: &Path, at: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for item in fs::read_dir(at).unwrap() {
            let p = item.unwrap().path();
            if p.is_dir() {
                walk(base, &p, out);
            } else {
                out.insert(
                    p.strip_prefix(base).unwrap().to_owned(),
                    fs::read(p).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    if root.exists() {
        walk(root, root, &mut out);
    }
    out
}
fn serial_verify(p: &Path) -> unlhare::Result<unlhare::Summary> {
    khc::verify_archive_with_progress(p, &Limits::default(), &mut |_| true)
}
fn verify_error(p: &Path) -> String {
    let plain = khc::verify_archive(p, &Limits::default())
        .unwrap_err()
        .to_string();
    let serial = serial_verify(p).unwrap_err().to_string();
    assert_eq!(plain, serial, "error precedence {}", p.display());
    plain
}
fn file_crc_offsets(bytes: &[u8]) -> (Vec<(String, usize)>, usize) {
    let count = u32::from_le_bytes(bytes[16..20].try_into().unwrap()) as usize;
    let mlen = u32::from_le_bytes(bytes[20..24].try_into().unwrap()) as usize;
    let mut at = 32;
    let mut body = 32 + mlen;
    let mut out = Vec::new();
    let mut compressed_binary_adaptive_frames = 0;
    for _ in 0..count {
        let n = u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap()) as usize;
        let dir = bytes[at + 2] == 1;
        let mut raw = u64::from_le_bytes(bytes[at + 4..at + 12].try_into().unwrap());
        let name = String::from_utf8(bytes[at + 20..at + 20 + n].to_vec()).unwrap();
        at += 20 + n;
        if dir {
            continue;
        }
        while raw > 0 {
            let len = u32::from_le_bytes(bytes[body..body + 4].try_into().unwrap()) as usize;
            let frame = &bytes[body + 4..body + 4 + len];
            if frame.len() >= 12
                && &frame[..8] == b"KHC1BLK\0"
                && frame[8..10] == [2, 0]
                && frame[10] == 1
            {
                compressed_binary_adaptive_frames += 1;
            }
            body += 4 + len;
            raw -= raw.min(khc::BLOCK_BYTES as u64);
        }
        out.push((name, body));
        body += 4;
    }
    assert_eq!(body + 8, bytes.len());
    (out, compressed_binary_adaptive_frames)
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 4 {
        eprintln!(
            "usage: khc_pipeline_e2e <Canterbury.khc> <corpus-directory> <new-external-Temp-directory>"
        );
        std::process::exit(2);
    }
    let archive = Path::new(&args[1]);
    let corpus = Path::new(&args[2]);
    let root = Path::new(&args[3]);
    assert!(
        root.is_absolute(),
        "E2E output must be an absolute Temp path"
    );
    let temp = std::env::temp_dir().canonicalize().unwrap();
    let parent = root.parent().unwrap().canonicalize().unwrap();
    assert!(
        parent.starts_with(temp),
        "E2E output must be outside the repository in Temp"
    );
    assert!(!root.exists());
    fs::create_dir_all(root).unwrap();
    let limits = Limits::default();
    let opts = ExtractOptions::default();
    let raw = fs::read(archive).unwrap();
    let (offsets, compressed_binary_adaptive_frames) = file_crc_offsets(&raw);
    assert!(
        compressed_binary_adaptive_frames > 0,
        "Canterbury11 product E2E must decode a compressed BinaryAdaptive KHC1 frame"
    );
    let plain = khc::verify_archive(archive, &limits).unwrap();
    let serial = serial_verify(archive).unwrap();
    assert_eq!(plain.bytes, 2_810_784);
    assert_eq!(plain.files, 11);
    assert_eq!(plain.bytes, serial.bytes);
    let restored = root.join("canterbury");
    khc::extract_archive(archive, &restored, &limits).unwrap();
    assert_eq!(tree(corpus), tree(&restored));
    let collision = khc::extract_archive(archive, &restored, &limits).unwrap_err();
    assert!(collision.to_string().contains("exists"), "{collision}");
    assert_eq!(tree(corpus), tree(&restored));
    let mut n = 3;
    for (label, mutated) in [
        ("header", {
            let mut v = raw.clone();
            v[8] = 255;
            v
        }),
        ("manifest", {
            let mut v = raw.clone();
            v[32] ^= 1;
            v
        }),
        ("first-frame", {
            let mut v = raw.clone();
            let start = 32 + u32::from_le_bytes(v[20..24].try_into().unwrap()) as usize;
            v[start + 12] ^= 1;
            v
        }),
        ("end", {
            let mut v = raw.clone();
            let last = v.len() - 1;
            v[last] ^= 1;
            v
        }),
        ("trailing", {
            let mut v = raw.clone();
            v.push(1);
            v
        }),
        ("truncated-header", raw[..12].to_vec()),
        (
            "truncated-last-crc",
            raw[..offsets.last().unwrap().1 + 2].to_vec(),
        ),
        ("truncated-frame", raw[..1024].to_vec()),
    ] {
        let p = root.join(format!("{label}.khc"));
        fs::write(&p, mutated).unwrap();
        let _ = verify_error(&p);
        n += 1;
    }
    for index in [0, 5, 10] {
        let mut v = raw.clone();
        v[offsets[index].1] ^= 1;
        let p = root.join(format!("bad-file-crc-{index}.khc"));
        fs::write(&p, v).unwrap();
        assert!(verify_error(&p).contains("file CRC"));
        let parallel_out = root.join(format!("parallel-bad-{index}"));
        let serial_out = root.join(format!("serial-bad-{index}"));
        let a = khc::extract_archive(&p, &parallel_out, &limits)
            .unwrap_err()
            .to_string();
        let b = khc::extract_archive_with_progress(&p, &serial_out, &limits, &opts, &mut |_| true)
            .unwrap_err()
            .to_string();
        assert_eq!(a, b);
        assert_eq!(tree(&parallel_out), tree(&serial_out));
        assert!(!parallel_out.join(&offsets[index].0).exists());
        for (name, _) in offsets.iter().take(index) {
            assert!(parallel_out.join(name).exists());
        }
        n += 2;
    }
    let mut calls = 0;
    let cancel = khc::verify_archive_with_progress(archive, &limits, &mut |_| {
        calls += 1;
        calls < 4
    })
    .unwrap_err();
    assert_eq!(calls, 4);
    assert!(cancel.to_string().to_lowercase().contains("cancel"));
    n += 1;
    let sources = root.join("boundary-source");
    fs::create_dir_all(sources.join("empty-dir")).unwrap();
    fs::create_dir_all(sources.join("nested")).unwrap();
    fs::write(sources.join("empty"), []).unwrap();
    fs::write(sources.join("nested/tiny"), [0, 255, 1, 254]).unwrap();
    let data: Vec<u8> = (0..khc::BLOCK_BYTES + 17)
        .map(|i| (i.wrapping_mul(17).wrapping_add(i / 257) & 255) as u8)
        .collect();
    fs::write(sources.join("boundary"), &data).unwrap();
    drop(data);
    let new_archive = root.join("boundary.khc");
    khc::create_from_directory(
        &sources,
        &new_archive,
        &khc::CreateOptions {
            block_strategy: khc::BlockStrategy::Gather32Trial,
            ..Default::default()
        },
    )
    .unwrap();
    khc::verify_archive(&new_archive, &limits).unwrap();
    serial_verify(&new_archive).unwrap();
    let boundary = root.join("boundary-restore");
    khc::extract_archive(&new_archive, &boundary, &limits).unwrap();
    assert_eq!(tree(&sources), tree(&boundary));
    assert!(boundary.join("empty-dir").is_dir());
    n += 3;
    for _ in 0..3 {
        khc::verify_archive(archive, &limits).unwrap();
        serial_verify(archive).unwrap();
    }
    n += 3;
    println!(
        "E2E PASS: {n} assertions/groups; exact Canterbury11, file-CRC publication, corruption precedence, cancellation, empty/directory/1MiB+17, repeat calls; compressed BinaryAdaptive KHC1 method-1 frames={compressed_binary_adaptive_frames}"
    );
}
