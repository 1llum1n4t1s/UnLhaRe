use crate::operation::checkpoint;
use crate::{Entry, Error, Limits, Progress, Result, Summary, pathname};
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use delharc::LhaDecodeReader;
use std::{
    collections::HashSet,
    fs::File,
    io::{self, BufRead, BufReader, Read, Write},
    path::Path,
};

type Decoder = LhaDecodeReader<BufReader<File>>;

struct ScannedArchive {
    summary: Summary,
    entries: Vec<Entry>,
}

fn open(path: &Path) -> Result<Decoder> {
    let mut input = BufReader::new(File::open(path)?);
    if input.fill_buf()?.is_empty() {
        return Err(Error::Format("empty file is not an LHA archive".into()));
    }
    let mut decoder = Decoder::default();
    let present = decoder
        .begin_new(input)
        .map_err(|error| Error::Format(error.to_string()))?;
    Ok(if present { decoder } else { Decoder::default() })
}

fn metadata(decoder: &Decoder) -> Result<Entry> {
    let h = decoder.header();
    if let Some(mode) = h.parse_unix_permissions()
        && (mode.is_link() || (!(mode.is_file() || mode.is_dir()) && mode.bits() & 0xf000 != 0))
    {
        return Err(Error::Unsupported(
            "symbolic links and special archive entries".into(),
        ));
    }
    if h.is_directory() && (h.original_size != 0 || h.compressed_size != 0) {
        return Err(Error::Format("directory contains file data".into()));
    }
    Ok(Entry {
        name: pathname::archive_name(h)?,
        method: String::from_utf8_lossy(&h.compression).into_owned(),
        original_size: h.original_size,
        compressed_size: h.compressed_size,
        is_directory: h.is_directory(),
        crc16: h.file_crc,
        header_level: h.level,
    })
}

fn account(
    entry: &Entry,
    limits: &Limits,
    summary: &mut Summary,
    names: &mut HashSet<String>,
) -> Result<()> {
    if !names.insert(entry.name.to_lowercase()) {
        return Err(Error::Format(format!(
            "duplicate portable name: {}",
            entry.name
        )));
    }
    summary.entries = summary
        .entries
        .checked_add(1)
        .ok_or_else(|| Error::Limit("entry count overflow".into()))?;
    summary.bytes = summary
        .bytes
        .checked_add(entry.original_size)
        .ok_or_else(|| Error::Limit("size overflow".into()))?;
    if summary.entries > limits.max_entries
        || entry.original_size > limits.max_entry_bytes
        || summary.bytes > limits.max_total_bytes
    {
        return Err(Error::Limit(entry.name.clone()));
    }
    if !entry.is_directory {
        summary.files += 1;
    }
    Ok(())
}

fn decode<W: Write>(
    decoder: &mut Decoder,
    entry: &Entry,
    output: &mut W,
    completed: &mut u64,
    total: u64,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<()> {
    if !decoder.is_decoder_supported() {
        return Err(Error::Unsupported(entry.method.clone()));
    }
    let mut bytes = 0u64;
    let mut buffer = [0u8; 65536];
    loop {
        let amount = decoder.read(&mut buffer)?;
        if amount == 0 {
            break;
        }
        bytes = bytes
            .checked_add(amount as u64)
            .ok_or_else(|| Error::Limit("decoded size overflow".into()))?;
        if bytes > entry.original_size {
            return Err(Error::Format("decoded size exceeds header".into()));
        }
        output.write_all(&buffer[..amount])?;
        *completed = completed
            .checked_add(amount as u64)
            .ok_or_else(|| Error::Limit("decoded progress overflow".into()))?;
        checkpoint(callback, 3, *completed, total)?;
    }
    if bytes != entry.original_size {
        return Err(Error::Format("decoded size differs from header".into()));
    }
    decoder
        .crc_check()
        .map_err(|error| Error::Format(error.to_string()))?;
    Ok(())
}

fn scan_archive(
    path: &Path,
    limits: &Limits,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<ScannedArchive> {
    let mut decoder = open(path)?;
    let mut summary = Summary::default();
    let mut names = HashSet::new();
    let mut entries = Vec::new();
    checkpoint(callback, 1, 0, 0)?;
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        account(&entry, limits, &mut summary, &mut names)?;
        entries.push(entry);
        checkpoint(callback, 1, summary.entries, 0)?;
        if !next(&mut decoder)? {
            break;
        }
    }
    checkpoint(callback, 1, summary.entries, summary.entries)?;
    Ok(ScannedArchive { summary, entries })
}

fn ensure_unchanged(current: &Entry, expected: Option<&Entry>) -> Result<()> {
    if expected == Some(current) {
        Ok(())
    } else {
        Err(Error::Format(
            "archive changed while being processed".into(),
        ))
    }
}

fn next(decoder: &mut Decoder) -> Result<bool> {
    decoder
        .seek_next_file()
        .map_err(|error| Error::Format(error.to_string()))
}

/// List metadata without treating this as a payload/CRC verification.
pub fn list_archive(path: &Path, limits: &Limits) -> Result<Vec<Entry>> {
    let mut decoder = open(path)?;
    let mut result = Vec::new();
    let mut summary = Summary::default();
    let mut names = HashSet::new();
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        account(&entry, limits, &mut summary, &mut names)?;
        result.push(entry);
        if !next(&mut decoder)? {
            break;
        }
    }
    Ok(result)
}

/// Decode each regular entry and require its complete length and CRC to match.
pub fn verify_archive(path: &Path, limits: &Limits) -> Result<Summary> {
    verify_archive_with_progress(path, limits, &mut |_| true)
}

/// Verify every payload and report cancellable progress.
pub fn verify_archive_with_progress(
    path: &Path,
    limits: &Limits,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<Summary> {
    let scanned = scan_archive(path, limits, callback)?;
    let mut decoder = open(path)?;
    let mut completed = 0_u64;
    let mut index = 0_usize;
    checkpoint(callback, 3, 0, scanned.summary.bytes)?;
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        ensure_unchanged(&entry, scanned.entries.get(index))?;
        if !entry.is_directory {
            decode(
                &mut decoder,
                &entry,
                &mut io::sink(),
                &mut completed,
                scanned.summary.bytes,
                callback,
            )?;
        }
        index += 1;
        if !next(&mut decoder)? {
            break;
        }
    }
    if index != scanned.entries.len() {
        return Err(Error::Format(
            "archive changed while being processed".into(),
        ));
    }
    checkpoint(
        callback,
        4,
        scanned.summary.entries,
        scanned.summary.entries,
    )?;
    Ok(scanned.summary)
}

/// Extract into a capability-scoped directory, never replacing an existing file.
/// Each file is published only after CRC validation. Earlier completed entries
/// remain if a later entry fails; this is not an archive-wide transaction.
pub fn extract_archive(path: &Path, destination: &Path, limits: &Limits) -> Result<Summary> {
    extract_archive_with_progress(path, destination, limits, None, &mut |_| true)
}

/// Extract selected exact archive names with cancellable progress.
///
/// Metadata and limits are checked for the complete archive even when a
/// selection is supplied. Unselected payloads are skipped without decoding.
pub fn extract_archive_with_progress(
    path: &Path,
    destination: &Path,
    limits: &Limits,
    selected_names: Option<&[String]>,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<Summary> {
    let scanned = scan_archive(path, limits, callback)?;
    let selected: Option<HashSet<&str>> =
        selected_names.map(|names| names.iter().map(String::as_str).collect());
    let progress_total = if let Some(selected) = &selected {
        scanned
            .entries
            .iter()
            .filter(|entry| !entry.is_directory && selected.contains(entry.name.as_str()))
            .try_fold(0_u64, |total, entry| {
                total
                    .checked_add(entry.original_size)
                    .ok_or_else(|| Error::Limit("selected size overflow".into()))
            })?
    } else {
        scanned.summary.bytes
    };

    let mut decoder = open(path)?;
    std::fs::create_dir_all(destination)?;
    let root = Dir::open_ambient_dir(destination, ambient_authority())?;
    let mut completed = 0_u64;
    let mut index = 0_usize;
    checkpoint(callback, 3, 0, progress_total)?;
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        ensure_unchanged(&entry, scanned.entries.get(index))?;
        index += 1;
        let chosen = selected
            .as_ref()
            .is_none_or(|names| names.contains(entry.name.as_str()));
        if !chosen {
            if !next(&mut decoder)? {
                break;
            }
            continue;
        }
        let relative = pathname::validate_entry_name(&entry.name)?;
        if entry.is_directory {
            root.create_dir_all(&relative)?;
        } else {
            let parent_path = relative
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            root.create_dir_all(parent_path)?;
            let parent = root.open_dir(parent_path)?;
            let filename = relative
                .file_name()
                .ok_or_else(|| Error::InvalidPath(entry.name.clone()))?;
            match parent.symlink_metadata(filename) {
                Ok(_) => return Err(Error::Exists(destination.join(&relative))),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            // A private temporary directory on the same filesystem permits a
            // no-replace hard-link commit after validation. Filesystems which
            // reject hard links use the platform's atomic no-replace rename.
            let staging = cap_tempfile::TempDir::new_in(&parent)?;
            let mut file = create_staging_file(&staging)?;
            decode(
                &mut decoder,
                &entry,
                &mut file,
                &mut completed,
                progress_total,
                callback,
            )?;
            file.sync_all()?;
            publish_staged_no_replace(
                &staging,
                &file,
                &parent,
                filename,
                &destination.join(&relative),
                callback,
            )?;
            drop(file);
            staging.close()?;
        }
        if !next(&mut decoder)? {
            break;
        }
    }
    if index != scanned.entries.len() {
        return Err(Error::Format(
            "archive changed while being processed".into(),
        ));
    }
    checkpoint(callback, 4, 0, 0)?;
    Ok(scanned.summary)
}

fn create_staging_file(staging: &Dir) -> io::Result<cap_std::fs::File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(windows)]
    {
        use cap_std::fs::OpenOptionsExt;
        use windows_sys::Win32::{
            Foundation::{GENERIC_READ, GENERIC_WRITE},
            Storage::FileSystem::{DELETE, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE},
        };

        options
            .access_mode(GENERIC_READ | GENERIC_WRITE | DELETE)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    }
    staging.open_with("content", &options)
}

fn publish_staged_no_replace(
    staging: &Dir,
    staged_file: &cap_std::fs::File,
    parent: &Dir,
    filename: &std::ffi::OsStr,
    destination: &Path,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<()> {
    publish_staged_no_replace_impl(
        staging,
        staged_file,
        parent,
        filename,
        destination,
        callback,
        true,
    )
}

fn publish_staged_no_replace_impl(
    staging: &Dir,
    staged_file: &cap_std::fs::File,
    parent: &Dir,
    filename: &std::ffi::OsStr,
    destination: &Path,
    callback: &mut dyn FnMut(Progress) -> bool,
    try_hard_link: bool,
) -> Result<()> {
    checkpoint(callback, 4, 0, 0)?;
    if try_hard_link {
        match staging.hard_link("content", parent, filename) {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                return Err(Error::Exists(destination.to_path_buf()));
            }
            Err(_) => {}
        }
    }

    rename_staged_no_replace(staging, staged_file, parent, filename).map_err(|error| {
        if error.kind() == io::ErrorKind::AlreadyExists {
            Error::Exists(destination.to_path_buf())
        } else {
            Error::Io(error)
        }
    })
}

#[cfg(target_os = "macos")]
fn rename_staged_no_replace(
    staging: &Dir,
    _staged_file: &cap_std::fs::File,
    parent: &Dir,
    filename: &std::ffi::OsStr,
) -> io::Result<()> {
    rustix::fs::renameat_with(
        staging,
        "content",
        parent,
        filename,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(io::Error::from)
}

#[cfg(windows)]
fn rename_staged_no_replace(
    _staging: &Dir,
    staged_file: &cap_std::fs::File,
    parent: &Dir,
    filename: &std::ffi::OsStr,
) -> io::Result<()> {
    use std::{mem, os::windows::ffi::OsStrExt, os::windows::io::AsRawHandle, ptr};
    use windows_sys::{
        Wdk::Storage::FileSystem::{
            FILE_RENAME_INFORMATION, FileRenameInformation, NtSetInformationFile,
        },
        Win32::{Foundation::RtlNtStatusToDosError, System::IO::IO_STATUS_BLOCK},
    };

    let wide_name: Vec<u16> = filename.encode_wide().collect();
    let name_bytes = wide_name
        .len()
        .checked_mul(mem::size_of::<u16>())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "filename is too long"))?;
    let buffer_bytes = mem::size_of::<FILE_RENAME_INFORMATION>()
        .checked_add(name_bytes)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "filename is too long"))?;
    let buffer_items = buffer_bytes.div_ceil(mem::size_of::<FILE_RENAME_INFORMATION>());
    let mut buffer = vec![FILE_RENAME_INFORMATION::default(); buffer_items.max(1)];
    let info = buffer.as_mut_ptr();

    // SAFETY: 配列は構造体の整列と可変長UTF-16名の容量を満たし、
    // ディレクトリとファイルのハンドルは同期呼び出しの終了まで有効。
    unsafe {
        (*info).Anonymous.ReplaceIfExists = false;
        (*info).RootDirectory = parent.as_raw_handle();
        (*info).FileNameLength = u32::try_from(name_bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "filename is too long"))?;
        ptr::copy_nonoverlapping(
            wide_name.as_ptr(),
            ptr::addr_of_mut!((*info).FileName).cast::<u16>(),
            wide_name.len(),
        );
        let size = u32::try_from(buffer_bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "filename is too long"))?;
        let mut io_status = IO_STATUS_BLOCK::default();
        let status = NtSetInformationFile(
            staged_file.as_raw_handle(),
            &mut io_status,
            info.cast(),
            size,
            FileRenameInformation,
        );
        if status < 0 {
            return Err(io::Error::from_raw_os_error(
                RtlNtStatusToDosError(status) as i32
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{create_staging_file, publish_staged_no_replace_impl};
    use crate::Error;
    use cap_std::{ambient_authority, fs::Dir};
    use std::{fs, io::Write};
    use tempfile::tempdir;

    #[test]
    fn forced_rename_fallback_publishes_without_replacing_an_existing_file() {
        let temporary = tempdir().expect("temporary directory");
        let parent = Dir::open_ambient_dir(temporary.path(), ambient_authority())
            .expect("capability directory");

        let staging = cap_tempfile::TempDir::new_in(&parent).expect("staging directory");
        let mut staged_file = create_staging_file(&staging).expect("staging file");
        staged_file.write_all(b"published").expect("staging data");
        staged_file.sync_all().expect("sync staging data");
        publish_staged_no_replace_impl(
            &staging,
            &staged_file,
            &parent,
            std::ffi::OsStr::new("a"),
            &temporary.path().join("a"),
            &mut |_| true,
            false,
        )
        .expect("forced rename fallback");
        drop(staged_file);
        staging.close().expect("remove empty staging directory");
        assert_eq!(
            fs::read(temporary.path().join("a")).expect("published file"),
            b"published"
        );

        fs::write(temporary.path().join("existing.txt"), b"original")
            .expect("existing destination");
        let staging = cap_tempfile::TempDir::new_in(&parent).expect("second staging directory");
        let mut staged_file = create_staging_file(&staging).expect("second staging file");
        staged_file
            .write_all(b"replacement")
            .expect("second staging data");
        staged_file.sync_all().expect("sync second staging data");
        let error = publish_staged_no_replace_impl(
            &staging,
            &staged_file,
            &parent,
            std::ffi::OsStr::new("existing.txt"),
            &temporary.path().join("existing.txt"),
            &mut |_| true,
            false,
        )
        .expect_err("existing destination must be rejected");
        assert!(matches!(error, Error::Exists(_)));
        assert_eq!(
            fs::read(temporary.path().join("existing.txt")).expect("existing file"),
            b"original"
        );
        drop(staged_file);
        staging.close().expect("remove rejected staging directory");
    }

    #[test]
    fn forced_rename_fallback_cancellation_does_not_remove_other_files() {
        let temporary = tempdir().expect("temporary directory");
        let parent = Dir::open_ambient_dir(temporary.path(), ambient_authority())
            .expect("capability directory");
        fs::write(temporary.path().join("keep.txt"), b"keep").expect("unrelated file");
        let staging = cap_tempfile::TempDir::new_in(&parent).expect("staging directory");
        let mut staged_file = create_staging_file(&staging).expect("staging file");
        staged_file.write_all(b"cancelled").expect("staging data");
        staged_file.sync_all().expect("sync staging data");

        let error = publish_staged_no_replace_impl(
            &staging,
            &staged_file,
            &parent,
            std::ffi::OsStr::new("cancelled.txt"),
            &temporary.path().join("cancelled.txt"),
            &mut |_| false,
            false,
        )
        .expect_err("publication should be cancelled before rename");
        assert!(matches!(error, Error::Cancelled));
        assert!(!temporary.path().join("cancelled.txt").exists());
        assert_eq!(
            fs::read(temporary.path().join("keep.txt")).expect("unrelated file"),
            b"keep"
        );
        drop(staged_file);
        staging.close().expect("remove cancelled staging directory");
    }
}
