use std::collections::{HashMap, hash_map::Entry};
#[cfg(windows)]
use std::fs::OpenOptions;
use std::fs::{self, File, Metadata};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::UNIX_EPOCH;

use oxiarc_lzhuf::{LzhEncoder, LzhMethod};
use tempfile::NamedTempFile;

use crate::operation::checkpoint;
use crate::pathname::validate_entry_name;
use crate::{
    CreateEntryResult, CreateEntryStatus, CreateOptions, CreateReport, Error, Method, Progress,
    Result, SourceEntry,
};
use cap_std::fs::Dir;
use crc_fast::{CrcAlgorithm, Digest, checksum};

const CODE_PAGE_UTF8: u32 = 65_001;
const LEVEL2_FIXED_HEADER_SIZE: usize = 26;

struct ArchiveName {
    basename: String,
    directories: Vec<String>,
}

impl ArchiveName {
    fn parse(name: &str) -> Result<(Self, String, String)> {
        let normalized = name.replace('\\', "/");
        let _ = validate_entry_name(&normalized)?;

        // LHA uses slash separators regardless of the host operating system.
        let parts: Vec<_> = normalized
            .split('/')
            .filter(|part| !part.is_empty())
            .collect();
        let (basename, directories) = parts
            .split_last()
            .ok_or_else(|| Error::InvalidPath(normalized.clone()))?;

        let key = parts.join("/").to_lowercase();
        Ok((
            Self {
                basename: (*basename).to_owned(),
                directories: directories.iter().map(|part| (*part).to_owned()).collect(),
            },
            key,
            normalized.trim_end_matches('/').to_owned(),
        ))
    }

    fn utf8_directory(&self) -> Vec<u8> {
        let mut result = Vec::new();
        for component in &self.directories {
            result.extend_from_slice(component.as_bytes());
            result.push(0xff);
        }
        result
    }

    fn utf16_basename(&self) -> Vec<u8> {
        self.basename
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect()
    }

    fn utf16_directory(&self) -> Vec<u8> {
        let mut result = Vec::new();
        for component in &self.directories {
            for code_unit in component.encode_utf16() {
                result.extend_from_slice(&code_unit.to_le_bytes());
            }
            result.extend_from_slice(&0xffff_u16.to_le_bytes());
        }
        result
    }

    fn contains_non_ascii(&self) -> bool {
        !self.basename.is_ascii() || self.directories.iter().any(|part| !part.is_ascii())
    }
}

struct PreparedEntry<'a> {
    source: &'a SourceEntry,
    archive_name: ArchiveName,
    normalized_name: String,
    index: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileIdentity {
    volume: u64,
    file: u64,
}

struct ScannedSource {
    metadata: Metadata,
    identity: Option<FileIdentity>,
}

struct ReadSource {
    data: Vec<u8>,
    crc16: u16,
}

#[derive(Debug)]
struct OpenedRegularFile {
    file: File,
    metadata: Metadata,
}

enum PackedData {
    Source,
    Compressed,
}

impl PackedData {
    fn as_slice<'a>(&self, source: &'a [u8], compressed: &'a [u8]) -> &'a [u8] {
        match self {
            Self::Source => source,
            Self::Compressed => compressed,
        }
    }
}

/// Creates a new LHA level-2 archive without replacing an existing destination.
pub fn create_archive(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
) -> Result<()> {
    create_archive_with_progress(destination, entries, options, &mut |_| true)
}

/// Creates a new LHA level-2 archive and reports cancellable progress.
///
/// The compression library encodes each LZH entry in one synchronous call.
/// Cancellation is therefore observed while reading and between entries, but
/// cannot interrupt an individual Lh5/Lh6/Lh7 encode already in progress.
pub fn create_archive_with_progress(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<()> {
    create_archive_with_progress_impl(destination, entries, options, callback, None, false)?;
    Ok(())
}

/// Creates an archive while reporting source entries skipped due to I/O errors.
///
/// Only I/O errors raised while scanning or reading an input source are
/// recoverable. Invalid names, resource limits, cancellation, compression
/// failures, and destination I/O errors still abort the entire operation.
pub fn create_archive_with_report(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<CreateReport> {
    create_archive_with_progress_impl(destination, entries, options, callback, None, true)?
        .ok_or_else(|| Error::InvalidArgument("create report was not generated".to_owned()))
}

pub(crate) fn create_archive_beneath(
    destination: &Path,
    source_root: &Dir,
    entries: &[SourceEntry],
    options: &CreateOptions,
) -> Result<()> {
    create_archive_with_progress_impl(
        destination,
        entries,
        options,
        &mut |_| true,
        Some(source_root),
        false,
    )?;
    Ok(())
}

fn create_archive_with_progress_impl(
    destination: &Path,
    entries: &[SourceEntry],
    options: &CreateOptions,
    callback: &mut dyn FnMut(Progress) -> bool,
    source_root: Option<&Dir>,
    skip_source_io: bool,
) -> Result<Option<CreateReport>> {
    reject_existing_destination(destination)?;

    let entry_count = u64::try_from(entries.len())
        .map_err(|_| Error::Limit("entry count does not fit in u64".to_owned()))?;
    if entry_count > options.limits.max_entries {
        return Err(Error::Limit(format!(
            "archive has {entry_count} entries; limit is {}",
            options.limits.max_entries
        )));
    }

    checkpoint(callback, 1, 0, entry_count)?;
    let prepared = prepare_entries(entries)?;
    let mut report_entries = skip_source_io.then(|| {
        let mut values = Vec::with_capacity(prepared.len());
        values.resize_with(prepared.len(), || None);
        values
    });
    let mut scanned = Vec::with_capacity(prepared.len());
    let mut total_bytes = 0_u64;
    for (index, entry) in prepared.into_iter().enumerate() {
        let scanned_source = match scan_source(source_root, &entry.source.path) {
            Ok(scanned_source) => scanned_source,
            Err(Error::Io(error)) if skip_source_io => {
                set_report_result(
                    &mut report_entries,
                    entry.index,
                    skipped_result(entry.normalized_name, error),
                );
                checkpoint(callback, 1, index as u64 + 1, entry_count)?;
                continue;
            }
            Err(error) => return Err(error),
        };
        if scanned_source.metadata.is_file() {
            enforce_file_limits(
                &entry.source.path,
                scanned_source.metadata.len(),
                &mut total_bytes,
                options,
            )?;
        }
        scanned.push((entry, scanned_source));
        checkpoint(callback, 1, index as u64 + 1, entry_count)?;
    }

    let parent = destination
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(parent)?;
    let mut completed_bytes = 0_u64;
    let mut encoder = None;
    let mut compressed = Vec::new();
    checkpoint(callback, 2, 0, total_bytes)?;

    for (entry, scanned_source) in scanned {
        if scanned_source.metadata.is_dir() {
            let header = build_level2_header(
                b"-lhd-",
                0,
                0,
                0,
                unix_timestamp(&scanned_source.metadata),
                &entry.archive_name,
            )?;
            temporary.write_all(&header)?;
            set_report_result(
                &mut report_entries,
                entry.index,
                written_result(entry.normalized_name),
            );
            continue;
        }

        let source = match read_regular_file(
            source_root,
            &entry.source.path,
            &scanned_source,
            options,
            completed_bytes,
            total_bytes,
            callback,
        ) {
            Ok(source) => source,
            Err(Error::Io(error)) if skip_source_io => {
                completed_bytes = completed_bytes
                    .checked_add(scanned_source.metadata.len())
                    .ok_or_else(|| Error::Limit("source progress overflowed u64".to_owned()))?;
                set_report_result(
                    &mut report_entries,
                    entry.index,
                    skipped_result(entry.normalized_name, error),
                );
                checkpoint(callback, 2, completed_bytes, total_bytes)?;
                continue;
            }
            Err(error) => return Err(error),
        };
        let data = source.data;
        // OxiArc's encoder progress sink cannot abort an encode. This
        // checkpoint keeps cancellation responsive between entries without
        // presenting the current entry as complete before compression.
        checkpoint(callback, 2, completed_bytes, total_bytes)?;
        let (method_id, packed) =
            compress_entry(&data, options.method, &mut encoder, &mut compressed)?;
        let packed = packed.as_slice(&data, &compressed);
        completed_bytes = completed_bytes
            .checked_add(scanned_source.metadata.len())
            .ok_or_else(|| Error::Limit("source progress overflowed u64".to_owned()))?;
        checkpoint(callback, 2, completed_bytes, total_bytes)?;
        let header = build_level2_header(
            &method_id,
            u64::try_from(packed.len())
                .map_err(|_| Error::Limit("packed size does not fit in u64".to_owned()))?,
            u64::try_from(data.len())
                .map_err(|_| Error::Limit("source size does not fit in u64".to_owned()))?,
            source.crc16,
            unix_timestamp(&scanned_source.metadata),
            &entry.archive_name,
        )?;
        temporary.write_all(&header)?;
        temporary.write_all(packed)?;
        set_report_result(
            &mut report_entries,
            entry.index,
            written_result(entry.normalized_name),
        );
    }

    // A zero byte terminates both non-empty archives and a valid empty archive.
    temporary.write_all(&[0])?;
    temporary.as_file_mut().sync_all()?;
    checkpoint(callback, 4, 0, 0)?;
    temporary.persist_noclobber(destination).map_err(|error| {
        if error.error.kind() == std::io::ErrorKind::AlreadyExists {
            Error::Exists(destination.to_path_buf())
        } else {
            Error::Io(error.error)
        }
    })?;
    Ok(report_entries.map(|entries| CreateReport {
        entries: entries
            .into_iter()
            .map(|entry| entry.expect("every prepared entry receives a create result"))
            .collect(),
    }))
}

fn set_report_result(
    report_entries: &mut Option<Vec<Option<CreateEntryResult>>>,
    index: usize,
    result: CreateEntryResult,
) {
    if let Some(entries) = report_entries {
        entries[index] = Some(result);
    }
}

fn written_result(name: String) -> CreateEntryResult {
    CreateEntryResult {
        name,
        status: CreateEntryStatus::Written,
        error: None,
    }
}

fn skipped_result(name: String, error: io::Error) -> CreateEntryResult {
    CreateEntryResult {
        name,
        status: CreateEntryStatus::Skipped,
        error: Some(Error::Io(error).to_string()),
    }
}

fn reject_existing_destination(destination: &Path) -> Result<()> {
    match fs::symlink_metadata(destination) {
        Ok(_) => Err(Error::Exists(destination.to_path_buf())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Error::Io(error)),
    }
}

fn prepare_entries(entries: &[SourceEntry]) -> Result<Vec<PreparedEntry<'_>>> {
    let mut seen = HashMap::with_capacity(entries.len());
    let mut prepared = Vec::with_capacity(entries.len());
    for (index, source) in entries.iter().enumerate() {
        let (archive_name, key, normalized_name) = ArchiveName::parse(&source.name)?;
        match seen.entry(key) {
            Entry::Occupied(entry) => {
                return Err(Error::InvalidArgument(format!(
                    "duplicate archive entry name: {}",
                    entry.key()
                )));
            }
            Entry::Vacant(entry) => {
                entry.insert(());
            }
        }
        prepared.push(PreparedEntry {
            source,
            archive_name,
            normalized_name,
            index,
        });
    }
    Ok(prepared)
}

fn reject_unsupported_source(path: &Path, metadata: &Metadata) -> Result<()> {
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        return Err(Error::Unsupported(format!(
            "symbolic links cannot be archived: {}",
            path.display()
        )));
    }
    if !file_type.is_file() && !file_type.is_dir() {
        return Err(Error::Unsupported(format!(
            "source is neither a regular file nor a directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn scan_source(source_root: Option<&Dir>, path: &Path) -> Result<ScannedSource> {
    let metadata = if let Some(root) = source_root {
        let link_metadata = root.symlink_metadata(path)?;
        let file_type = link_metadata.file_type();
        if file_type.is_symlink() || (!file_type.is_file() && !file_type.is_dir()) {
            return Err(Error::Unsupported(format!(
                "source is not a regular file or directory: {}",
                path.display()
            )));
        }
        if link_metadata.is_dir() {
            root.open_dir(path)?.into_std_file().metadata()?
        } else {
            root.open(path)?.into_std().metadata()?
        }
    } else {
        fs::symlink_metadata(path).map_err(|error| source_io_error(path, error))?
    };
    reject_unsupported_source(path, &metadata)?;
    if metadata.is_dir() {
        return Ok(ScannedSource {
            metadata,
            identity: None,
        });
    }

    // Open without following the final path component. This closes the race
    // between the symlink check above and acquiring the file used for identity.
    let file = open_regular_file(source_root, path)?;
    let opened = file.metadata()?;
    reject_unsupported_source(path, &opened)?;
    Ok(ScannedSource {
        identity: Some(file_identity(&file, &opened)?),
        metadata: opened,
    })
}

#[cfg(windows)]
fn open_regular_file_nofollow(path: &Path) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;

    OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

fn open_regular_file(source_root: Option<&Dir>, path: &Path) -> Result<File> {
    match source_root {
        Some(root) => root.open(path).map(cap_std::fs::File::into_std),
        None => open_regular_file_nofollow(path),
    }
    .map_err(|error| source_io_error(path, error))
}

fn source_io_error(_path: &Path, error: io::Error) -> Error {
    // nofollowによる拒否は、結果通知版でも読取失敗としてスキップしない。
    #[cfg(target_os = "macos")]
    if error.raw_os_error() == Some(rustix::io::Errno::LOOP.raw_os_error()) {
        return Error::Unsupported(format!(
            "source symbolic link resolution was rejected: {}",
            _path.display()
        ));
    }
    Error::Io(error)
}

#[cfg(target_os = "macos")]
fn open_regular_file_nofollow(path: &Path) -> io::Result<File> {
    use rustix::fs::{Mode, OFlags, open};

    let descriptor = open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    Ok(File::from(descriptor))
}

#[cfg(windows)]
fn file_identity(file: &File, _metadata: &Metadata) -> io::Result<FileIdentity> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
    };

    let mut information = BY_HANDLE_FILE_INFORMATION::default();
    // SAFETY: `file` keeps the valid handle alive for the duration of the call,
    // and `information` is a writable structure of the required type.
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut information) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(FileIdentity {
        volume: u64::from(information.dwVolumeSerialNumber),
        file: (u64::from(information.nFileIndexHigh) << 32) | u64::from(information.nFileIndexLow),
    })
}

fn open_matching_regular_file(
    source_root: Option<&Dir>,
    path: &Path,
    expected: FileIdentity,
) -> Result<OpenedRegularFile> {
    let file = open_regular_file(source_root, path)?;
    let metadata = file.metadata()?;
    reject_unsupported_source(path, &metadata)?;
    if file_identity(&file, &metadata)? != expected {
        return Err(Error::Unsupported(format!(
            "source was replaced while being archived: {}",
            path.display()
        )));
    }
    Ok(OpenedRegularFile { file, metadata })
}

#[cfg(target_os = "macos")]
fn file_identity(_file: &File, metadata: &Metadata) -> io::Result<FileIdentity> {
    use std::os::unix::fs::MetadataExt;

    Ok(FileIdentity {
        volume: metadata.dev(),
        file: metadata.ino(),
    })
}

fn enforce_file_limits(
    path: &Path,
    length: u64,
    total_bytes: &mut u64,
    options: &CreateOptions,
) -> Result<()> {
    if length > options.limits.max_entry_bytes {
        return Err(Error::Limit(format!(
            "source {} is {length} bytes; per-entry limit is {}",
            path.display(),
            options.limits.max_entry_bytes
        )));
    }
    let new_total = total_bytes
        .checked_add(length)
        .ok_or_else(|| Error::Limit("total source size overflowed u64".to_owned()))?;
    if new_total > options.limits.max_total_bytes {
        return Err(Error::Limit(format!(
            "total source size is {new_total} bytes; limit is {}",
            options.limits.max_total_bytes
        )));
    }
    *total_bytes = new_total;
    Ok(())
}

fn read_regular_file(
    source_root: Option<&Dir>,
    path: &Path,
    scanned: &ScannedSource,
    options: &CreateOptions,
    completed_before: u64,
    total: u64,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<ReadSource> {
    let opened = open_matching_regular_file(
        source_root,
        path,
        scanned
            .identity
            .expect("regular files always have an identity"),
    )?;
    if opened.metadata.len() != scanned.metadata.len() {
        return Err(Error::InvalidArgument(format!(
            "source size changed while being archived: {}",
            path.display()
        )));
    }

    let expected = usize::try_from(opened.metadata.len()).map_err(|_| {
        Error::Limit(format!(
            "source is too large for this process address space: {}",
            path.display()
        ))
    })?;
    let mut data = Vec::new();
    data.try_reserve_exact(expected).map_err(|_| {
        Error::Limit(format!(
            "could not reserve memory for source: {}",
            path.display()
        ))
    })?;
    let read_limit = options.limits.max_entry_bytes.saturating_add(1);
    let mut input = opened.file.take(read_limit);
    let mut buffer = [0_u8; 64 * 1024];
    let mut crc16 = Digest::new(CrcAlgorithm::Crc16Arc);
    loop {
        let amount = input.read(&mut buffer)?;
        if amount == 0 {
            break;
        }
        data.extend_from_slice(&buffer[..amount]);
        crc16.update(&buffer[..amount]);
        // completed counts bytes whose compression has finished. Repeating
        // the value during input reads still supplies cancellation points and
        // avoids claiming 100% while compression is running.
        checkpoint(callback, 2, completed_before, total)?;
    }
    let actual = u64::try_from(data.len())
        .map_err(|_| Error::Limit("source size does not fit in u64".to_owned()))?;
    if actual > options.limits.max_entry_bytes {
        return Err(Error::Limit(format!(
            "source {} grew beyond the per-entry limit of {} bytes",
            path.display(),
            options.limits.max_entry_bytes
        )));
    }
    if actual != opened.metadata.len() {
        return Err(Error::InvalidArgument(format!(
            "source size changed while being archived: {}",
            path.display()
        )));
    }
    let crc16 =
        u16::try_from(crc16.finalize()).expect("CRC-16/ARC always produces a 16-bit checksum");
    Ok(ReadSource { data, crc16 })
}

fn compress_entry(
    data: &[u8],
    requested: Method,
    encoder: &mut Option<LzhEncoder>,
    compressed: &mut Vec<u8>,
) -> Result<([u8; 5], PackedData)> {
    let method = match requested {
        Method::Stored => return Ok((LzhMethod::Lh0.id(), PackedData::Source)),
        Method::Lh5 => LzhMethod::Lh5,
        Method::Lh6 => LzhMethod::Lh6,
        Method::Lh7 => LzhMethod::Lh7,
    };
    if data.is_empty() {
        return Ok((LzhMethod::Lh0.id(), PackedData::Source));
    }
    compressed.clear();
    let encoder = encoder.get_or_insert_with(|| LzhEncoder::new(method));
    encoder.reset();
    encoder
        .encode(data, compressed, true)
        .map_err(|error| Error::Format(format!("LZH compression failed: {error}")))?;
    if compressed.len() > data.len() {
        Ok((LzhMethod::Lh0.id(), PackedData::Source))
    } else {
        Ok((method.id(), PackedData::Compressed))
    }
}

fn build_level2_header(
    method: &[u8; 5],
    packed_size: u64,
    original_size: u64,
    file_crc: u16,
    modified: u32,
    name: &ArchiveName,
) -> Result<Vec<u8>> {
    let mut extensions = Vec::new();
    extensions.push((0x46, CODE_PAGE_UTF8.to_le_bytes().to_vec()));
    extensions.push((0x01, name.basename.as_bytes().to_vec()));

    let utf8_directory = name.utf8_directory();
    if !utf8_directory.is_empty() {
        extensions.push((0x02, utf8_directory));
    }
    if name.contains_non_ascii() {
        extensions.push((0x44, name.utf16_basename()));
        let utf16_directory = name.utf16_directory();
        if !utf16_directory.is_empty() {
            extensions.push((0x45, utf16_directory));
        }
    }
    if packed_size > u32::MAX as u64 || original_size > u32::MAX as u64 {
        let mut sizes = Vec::with_capacity(16);
        sizes.extend_from_slice(&packed_size.to_le_bytes());
        sizes.extend_from_slice(&original_size.to_le_bytes());
        extensions.push((0x42, sizes));
    }
    // The extra flags byte matches the Windows-style common header layout.
    extensions.push((0x00, vec![0, 0, 0]));

    let mut extension_sizes = Vec::with_capacity(extensions.len());
    for (kind, data) in &extensions {
        let size = 1_usize
            .checked_add(data.len())
            .and_then(|size| size.checked_add(2))
            .ok_or_else(|| Error::InvalidArgument("extended header is too large".to_owned()))?;
        let size = u16::try_from(size).map_err(|_| {
            Error::InvalidArgument(format!("extended header 0x{kind:02x} is too large"))
        })?;
        extension_sizes.push(size);
    }

    let extensions_size = extension_sizes.iter().try_fold(0_usize, |total, size| {
        total
            .checked_add(usize::from(*size))
            .ok_or_else(|| Error::InvalidArgument("archive header is too large".to_owned()))
    })?;
    let mut header_size = LEVEL2_FIXED_HEADER_SIZE
        .checked_add(extensions_size)
        .ok_or_else(|| Error::InvalidArgument("archive header is too large".to_owned()))?;
    let padding = header_size & 0xff == 0;
    if padding {
        header_size = header_size
            .checked_add(1)
            .ok_or_else(|| Error::InvalidArgument("archive header is too large".to_owned()))?;
    }
    let header_size_u16 = u16::try_from(header_size)
        .map_err(|_| Error::InvalidArgument("archive header exceeds level-2 limits".to_owned()))?;

    let mut header = Vec::with_capacity(header_size);
    header.extend_from_slice(&header_size_u16.to_le_bytes());
    header.extend_from_slice(method);
    header.extend_from_slice(&(packed_size as u32).to_le_bytes());
    header.extend_from_slice(&(original_size as u32).to_le_bytes());
    header.extend_from_slice(&modified.to_le_bytes());
    header.push(0x20);
    header.push(2);
    header.extend_from_slice(&file_crc.to_le_bytes());
    header.push(b'M');
    header.extend_from_slice(&extension_sizes[0].to_le_bytes());

    let mut header_crc_offset = None;
    for (index, ((kind, data), _size)) in extensions.iter().zip(extension_sizes.iter()).enumerate()
    {
        header.push(*kind);
        if *kind == 0x00 {
            header_crc_offset = Some(header.len());
        }
        header.extend_from_slice(data);
        let next_size = extension_sizes.get(index + 1).copied().unwrap_or(0);
        header.extend_from_slice(&next_size.to_le_bytes());
    }
    if padding {
        header.push(0);
    }
    debug_assert_eq!(header.len(), header_size);

    let crc_offset = header_crc_offset
        .ok_or_else(|| Error::Format("common header CRC field was not generated".to_owned()))?;
    let header_crc = lha_crc16(&header);
    header[crc_offset..crc_offset + 2].copy_from_slice(&header_crc.to_le_bytes());
    Ok(header)
}

fn unix_timestamp(metadata: &Metadata) -> u32 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs().min(u64::from(u32::MAX)) as u32)
        .unwrap_or(0)
}

fn lha_crc16(data: &[u8]) -> u16 {
    u16::try_from(checksum(CrcAlgorithm::Crc16Arc, data))
        .expect("CRC-16/ARC always produces a 16-bit checksum")
}

#[cfg(test)]
mod tests {
    use super::{create_archive_beneath, lha_crc16, open_matching_regular_file, scan_source};
    use crate::{CreateOptions, SourceEntry};
    use cap_std::{ambient_authority, fs::Dir};
    use crc_fast::{CrcAlgorithm, Digest};
    use std::fs;
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn crc16_matches_lha_known_value() {
        assert_eq!(lha_crc16(b"123456789"), 0xbb3d);

        let mut digest = Digest::new(CrcAlgorithm::Crc16Arc);
        digest.update(b"1234");
        digest.update(b"56789");
        assert_eq!(digest.finalize(), 0xbb3d);
    }

    #[test]
    fn replaced_source_is_rejected_even_when_its_size_matches() {
        let temporary = tempdir().expect("temporary directory");
        let source = temporary.path().join("source.bin");
        let replacement = temporary.path().join("replacement.bin");
        let original = temporary.path().join("original.bin");
        fs::write(&source, b"original").expect("original source");
        fs::write(&replacement, b"replaced").expect("same-size replacement");

        let scanned = scan_source(None, &source).expect("scan original source");
        fs::rename(&source, &original).expect("move original source");
        fs::rename(&replacement, &source).expect("replace source path");

        let error =
            open_matching_regular_file(None, &source, scanned.identity.expect("file identity"))
                .expect_err("replacement must not be archived");
        assert!(
            matches!(error, crate::Error::Unsupported(message) if message.contains("replaced"))
        );
    }

    #[test]
    fn source_symlink_is_not_followed_after_scan() {
        let temporary = tempdir().expect("temporary directory");
        let source = temporary.path().join("source.bin");
        let link = temporary.path().join("link.bin");
        fs::write(&source, b"private payload").expect("source file");
        let scanned = scan_source(None, &source).expect("scan original source");

        #[cfg(windows)]
        let linked = std::os::windows::fs::symlink_file(&source, &link);
        #[cfg(target_os = "macos")]
        let linked = std::os::unix::fs::symlink(&source, &link);
        if let Err(error) = linked {
            if error.kind() == std::io::ErrorKind::PermissionDenied
                || error.raw_os_error() == Some(1314)
            {
                return;
            }
            panic!("create source symlink: {error}");
        }

        let error =
            open_matching_regular_file(None, &link, scanned.identity.expect("file identity"))
                .expect_err("source symlink must not be followed");
        assert!(matches!(error, crate::Error::Unsupported(_)));
    }

    #[test]
    fn capability_source_root_does_not_follow_an_intermediate_symlink() {
        let temporary = tempdir().expect("temporary directory");
        let source = temporary.path().join("source");
        let outside = temporary.path().join("outside");
        let link = source.join("link");
        let archive = temporary.path().join("archive.lzh");
        fs::create_dir(&source).expect("source directory");
        fs::create_dir(&outside).expect("outside directory");
        fs::write(outside.join("secret.txt"), b"secret").expect("outside file");

        #[cfg(windows)]
        let linked = std::os::windows::fs::symlink_dir(&outside, &link);
        #[cfg(target_os = "macos")]
        let linked = std::os::unix::fs::symlink(&outside, &link);
        if let Err(error) = linked {
            if error.kind() == std::io::ErrorKind::PermissionDenied
                || error.raw_os_error() == Some(1314)
            {
                return;
            }
            panic!("create intermediate source symlink: {error}");
        }

        let root = Dir::open_ambient_dir(&source, ambient_authority()).expect("source capability");
        let entries = [SourceEntry {
            path: PathBuf::from("link/secret.txt"),
            name: "secret.txt".into(),
        }];
        create_archive_beneath(&archive, &root, &entries, &CreateOptions::default())
            .expect_err("intermediate source symlink must not escape the capability root");
        assert!(!archive.exists());
    }
}
