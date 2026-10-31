//! Native公開APIの有限E2E。専用rootのfixtureを保持し、削除は行わない。
use std::{fs, path::Path};
use unlhare::{Error, Limits, SourceEntry, khc};
type Result<T> = std::result::Result<T, String>;
fn api<T>(r: unlhare::Result<T>) -> Result<T> {
    r.map_err(|e| e.to_string())
}
fn check(v: bool, msg: &str) -> Result<()> {
    if v { Ok(()) } else { Err(msg.into()) }
}
fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .and_then(|mut f| std::io::Write::write_all(&mut f, bytes))
        .map_err(|e| e.to_string())
}
fn options(strategy: khc::BlockStrategy) -> khc::CreateOptions {
    khc::CreateOptions {
        block_strategy: strategy,
        ..Default::default()
    }
}
fn u32_at(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}
fn header_crc(bytes: &mut [u8]) {
    let c = crc_fast::checksum(crc_fast::CrcAlgorithm::Crc32IsoHdlc, &bytes[..28]) as u32;
    bytes[28..32].copy_from_slice(&c.to_le_bytes());
}
pub fn run(root: &Path, corpus: &Path, old_archive: &Path) -> Result<serde_json::Value> {
    check(!root.exists(), "unused native fixture root")?;
    fs::create_dir(root).map_err(|e| e.to_string())?;
    let limits = Limits::default();
    api(khc::verify_archive(old_archive, &limits))?;
    let prior = api(khc::list_archive(old_archive, &limits))?;
    let corpus_sources: Vec<_> = prior
        .iter()
        .map(|e| SourceEntry {
            path: corpus.join(&e.name),
            name: e.name.clone(),
        })
        .collect();
    let actual = root.join("corpus-r3.khc");
    api(khc::create_archive(
        &actual,
        &corpus_sources,
        &options(khc::BlockStrategy::RecordTrial),
    ))?;
    let rows = api(khc::list_archive(&actual, &limits))?;
    let summary = api(khc::verify_archive(&actual, &limits))?;
    check(
        rows.len() == 11 && summary.bytes == 2810784 && summary.files == 11,
        "native corpus summary",
    )?;
    let archive_bytes = fs::metadata(&actual).map_err(|e| e.to_string())?.len();
    check(archive_bytes == 457017, "native actual archive fees/frames")?;
    let native_bytes = fs::read(&actual).map_err(|e| e.to_string())?;
    check(native_bytes[8] == 3, "archive opt-in revision")?;
    drop(native_bytes);
    let source = root.join("source");
    fs::create_dir(&source).map_err(|e| e.to_string())?;
    let mut big = vec![0u8; 1048577];
    big[1048575] = 255;
    let inputs = [
        ("big", big),
        ("empty", vec![]),
        ("one", vec![255]),
        ("all", (0..=255).collect()),
        ("日本語", b"native".to_vec()),
    ];
    let mut entries = Vec::new();
    for (name, raw) in &inputs {
        let path = source.join(name);
        write(&path, raw)?;
        entries.push(SourceEntry {
            path,
            name: (*name).into(),
        });
    }
    fs::create_dir(source.join("sub")).map_err(|e| e.to_string())?;
    entries.push(SourceEntry {
        path: source.join("sub"),
        name: "sub".into(),
    });
    let archive = root.join("small-r3.khc");
    api(khc::create_archive(
        &archive,
        &entries,
        &options(khc::BlockStrategy::RecordTrial),
    ))?;
    let listed = api(khc::list_archive(&archive, &limits))?;
    check(listed.len() == 6, "directory/empty listing")?;
    api(khc::verify_archive(&archive, &limits))?;
    let output = root.join("output");
    api(khc::extract_archive(&archive, &output, &limits))?;
    for (name, raw) in &inputs {
        check(
            fs::read(output.join(name)).map_err(|e| e.to_string())? == *raw,
            "native whole-byte extraction",
        )?;
    }
    check(output.join("sub").is_dir(), "directory extraction")?;
    let existing = fs::read(&archive).map_err(|e| e.to_string())?;
    check(
        matches!(
            khc::create_archive(
                &archive,
                &entries,
                &options(khc::BlockStrategy::RecordTrial)
            ),
            Err(Error::Exists(_))
        ),
        "archive no-clobber",
    )?;
    check(
        fs::read(&archive).map_err(|e| e.to_string())? == existing,
        "existing archive untouched",
    )?;
    check(
        matches!(
            khc::extract_archive(&archive, &output, &limits),
            Err(Error::Exists(_))
        ),
        "extract no-clobber",
    )?;
    check(
        fs::read(output.join("big")).map_err(|e| e.to_string())? == inputs[0].1,
        "existing extracted data untouched",
    )?;
    let cancel = root.join("cancelled.khc");
    let cancelled = khc::create_archive_with_progress(
        &cancel,
        &entries,
        &options(khc::BlockStrategy::RecordTrial),
        &mut |p| !(p.phase == 2 && p.completed > 0),
    );
    check(
        matches!(cancelled, Err(Error::Cancelled)) && !cancel.exists(),
        "late create cancellation/no publication",
    )?;
    let cancel_output = root.join("cancel-output");
    check(
        matches!(
            khc::extract_archive_with_progress(
                &archive,
                &cancel_output,
                &limits,
                &Default::default(),
                &mut |p| !(p.phase == 3 && p.completed > 0)
            ),
            Err(Error::Cancelled)
        ) && !cancel_output.join("big").exists(),
        "late extract cancellation/no publication",
    )?;
    let low = root.join("low-memory.khc");
    let mut opt = options(khc::BlockStrategy::RecordTrial);
    opt.max_codec_memory_bytes = (64 << 20) - 1;
    check(
        matches!(
            khc::create_archive(&low, &entries, &opt),
            Err(Error::Limit(_))
        ) && !low.exists(),
        "codec policy reservation",
    )?;
    let low_limits = Limits {
        max_entry_bytes: 100,
        ..Default::default()
    };
    check(
        khc::list_archive(&archive, &low_limits).is_err()
            && khc::verify_archive(&archive, &low_limits).is_err(),
        "entry length limits",
    )?;
    let mut visited = 0;
    check(
        matches!(
            khc::visit_archive_entries(&archive, &limits, &mut |_| {
                visited += 1;
                false
            }),
            Err(Error::Cancelled)
        ) && visited == 1,
        "stream visitor cancellation",
    )?;
    for (revision, strategy) in [
        (1, khc::BlockStrategy::Mdl),
        (2, khc::BlockStrategy::BinaryAdaptive),
    ] {
        let path = root.join(format!("legacy-r{revision}.khc"));
        api(khc::create_archive(
            &path,
            &entries[1..],
            &options(strategy),
        ))?;
        check(
            fs::read(&path).map_err(|e| e.to_string())?[8] == revision,
            "legacy default revision unchanged",
        )?;
        api(khc::list_archive(&path, &limits))?;
        api(khc::verify_archive(&path, &limits))?;
    }
    let first = 32 + u32_at(&existing, 20);
    let frame_start = first + 4;
    let frame_end = frame_start + u32_at(&existing, first);
    check(
        &existing[frame_start..frame_start + 8] == b"KRS1BLK\0" && existing[frame_start + 10] == 1,
        "coded multiblock fixture",
    )?;
    let mut rejected = 0usize;
    for revision in [0, 1, 2, 4, 255] {
        let mut bad = existing.clone();
        bad[8] = revision;
        header_crc(&mut bad);
        let path = root.join(format!("bad-revision-{revision}.khc"));
        write(&path, &bad)?;
        check(
            khc::list_archive(&path, &limits).is_err(),
            "wrong archive revision accepted",
        )?;
        rejected += 1;
    }
    for (tag, mut bad) in [
        ("wire-crc", {
            let mut b = existing.clone();
            b[frame_start + 28] ^= 1;
            b
        }),
        ("truncated", existing[..frame_end - 1].to_vec()),
        ("trailing", {
            let mut b = existing.clone();
            b.push(0);
            b
        }),
        ("extent", {
            let mut b = existing.clone();
            b[first..first + 4].copy_from_slice(&u32::MAX.to_le_bytes());
            b
        }),
        ("cdf", {
            let mut b = existing.clone();
            b[frame_start + 40..frame_start + 42].copy_from_slice(&257u16.to_le_bytes());
            let c = super::codec::wire_crc(&b[frame_start..frame_end]);
            b[frame_start + 28..frame_start + 32].copy_from_slice(&c.to_le_bytes());
            b
        }),
    ] {
        let path = root.join(format!("bad-{tag}.khc"));
        write(&path, &bad)?;
        check(
            khc::list_archive(&path, &limits).is_err(),
            "native structural rejection",
        )?;
        rejected += 1;
        bad.clear();
    }
    let mut at = first;
    let mut remaining = inputs[0].1.len();
    while remaining > 0 {
        let n = u32_at(&existing, at);
        at += 4 + n;
        remaining -= remaining.min(1 << 20);
    }
    let mut bad = existing.clone();
    bad[at] ^= 1;
    let path = root.join("bad-file-crc.khc");
    write(&path, &bad)?;
    check(
        khc::verify_archive(&path, &limits).is_err(),
        "file CRC verify rejection",
    )?;
    let corrupt_output = root.join("bad-output");
    check(
        khc::extract_archive(&path, &corrupt_output, &limits).is_err()
            && !corrupt_output.join("big").exists(),
        "CRC before publication",
    )?;
    rejected += 2;
    Ok(
        serde_json::json!({"corpus_files":11,"native_archive_bytes":archive_bytes,"actual_container_fees":444,"revision":3,"all_bytes_exact":true,"legacy_revisions":[1,2],"stream_visitor_cancelled":true,"late_create_cancelled_unpublished":true,"late_extract_cancelled_unpublished":true,"no_clobber":true,"CRC_before_publication":true,"malformed_archive_checks":rejected,"fixture_root":root,"selected_extraction":"not present in current KHC API; not claimed","timing_evidence":false}),
    )
}
