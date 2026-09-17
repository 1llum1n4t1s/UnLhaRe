use std::collections::HashSet;
use std::fs::{self, File, Metadata};
use std::io::{Read, Write};
use std::path::Path;
use std::time::UNIX_EPOCH;

use oxiarc_lzhuf::{LzhMethod, encode_lzh};
use tempfile::NamedTempFile;

use crate::operation::checkpoint;
use crate::pathname::validate_entry_name;
use crate::{CreateOptions, Error, Method, Progress, Result, SourceEntry};

const CODE_PAGE_UTF8: u32 = 65_001;
const LEVEL2_FIXED_HEADER_SIZE: usize = 26;

struct ArchiveName {
    key: String,
    basename: String,
    directories: Vec<String>,
}

impl ArchiveName {
    fn parse(name: &str) -> Result<Self> {
        let _ = validate_entry_name(name)?;

        // LHA uses its own separators. Splitting both forms keeps archive names
        // identical on Windows and Unix hosts.
        let parts: Vec<_> = name
            .split(['/', '\\'])
            .filter(|part| !part.is_empty())
            .collect();
        let (basename, directories) = parts
            .split_last()
            .ok_or_else(|| Error::InvalidPath(name.to_owned()))?;

        Ok(Self {
            key: parts.join("/").to_lowercase(),
            basename: (*basename).to_owned(),
            directories: directories.iter().map(|part| (*part).to_owned()).collect(),
        })
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
    let mut scanned = Vec::with_capacity(prepared.len());
    let mut total_bytes = 0_u64;
    for (index, entry) in prepared.into_iter().enumerate() {
        let metadata = fs::symlink_metadata(&entry.source.path)?;
        reject_unsupported_source(&entry.source.path, &metadata)?;
        if metadata.is_file() {
            enforce_file_limits(
                &entry.source.path,
                metadata.len(),
                &mut total_bytes,
                options,
            )?;
        }
        scanned.push((entry, metadata));
        checkpoint(callback, 1, index as u64 + 1, entry_count)?;
    }

    let parent = destination
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(parent)?;
    let mut completed_bytes = 0_u64;
    checkpoint(callback, 2, 0, total_bytes)?;

    for (entry, metadata) in scanned {
        if metadata.is_dir() {
            let header = build_level2_header(
                b"-lhd-",
                0,
                0,
                0,
                unix_timestamp(&metadata),
                &entry.archive_name,
            )?;
            temporary.write_all(&header)?;
            continue;
        }

        let data = read_regular_file(
            &entry.source.path,
            &metadata,
            options,
            completed_bytes,
            total_bytes,
            callback,
        )?;
        let file_crc = crc16(&data);
        // OxiArc's encoder progress sink cannot abort an encode. This
        // checkpoint keeps cancellation responsive between entries without
        // presenting the current entry as complete before compression.
        checkpoint(callback, 2, completed_bytes, total_bytes)?;
        let (method_id, packed) = compress_entry(&data, options.method)?;
        completed_bytes = completed_bytes
            .checked_add(metadata.len())
            .ok_or_else(|| Error::Limit("source progress overflowed u64".to_owned()))?;
        checkpoint(callback, 2, completed_bytes, total_bytes)?;
        let header = build_level2_header(
            method_id,
            u64::try_from(packed.len())
                .map_err(|_| Error::Limit("packed size does not fit in u64".to_owned()))?,
            u64::try_from(data.len())
                .map_err(|_| Error::Limit("source size does not fit in u64".to_owned()))?,
            file_crc,
            unix_timestamp(&metadata),
            &entry.archive_name,
        )?;
        temporary.write_all(&header)?;
        temporary.write_all(&packed)?;
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
    Ok(())
}

fn reject_existing_destination(destination: &Path) -> Result<()> {
    match fs::symlink_metadata(destination) {
        Ok(_) => Err(Error::Exists(destination.to_path_buf())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Error::Io(error)),
    }
}

fn prepare_entries(entries: &[SourceEntry]) -> Result<Vec<PreparedEntry<'_>>> {
    let mut seen = HashSet::with_capacity(entries.len());
    let mut prepared = Vec::with_capacity(entries.len());
    for source in entries {
        let archive_name = ArchiveName::parse(&source.name)?;
        if !seen.insert(archive_name.key.clone()) {
            return Err(Error::InvalidArgument(format!(
                "duplicate archive entry name: {}",
                archive_name.key
            )));
        }
        prepared.push(PreparedEntry {
            source,
            archive_name,
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
    path: &Path,
    initial: &Metadata,
    options: &CreateOptions,
    completed_before: u64,
    total: u64,
    callback: &mut dyn FnMut(Progress) -> bool,
) -> Result<Vec<u8>> {
    let file = File::open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file() {
        return Err(Error::Unsupported(format!(
            "source changed type while being archived: {}",
            path.display()
        )));
    }
    if opened.len() != initial.len() {
        return Err(Error::InvalidArgument(format!(
            "source size changed while being archived: {}",
            path.display()
        )));
    }

    let expected = usize::try_from(opened.len()).map_err(|_| {
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
    let mut input = file.take(read_limit);
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let amount = input.read(&mut buffer)?;
        if amount == 0 {
            break;
        }
        data.extend_from_slice(&buffer[..amount]);
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
    if actual != opened.len() {
        return Err(Error::InvalidArgument(format!(
            "source size changed while being archived: {}",
            path.display()
        )));
    }
    Ok(data)
}

fn compress_entry(data: &[u8], requested: Method) -> Result<(&'static [u8; 5], Vec<u8>)> {
    let method = match requested {
        Method::Stored => return Ok((b"-lh0-", data.to_vec())),
        Method::Lh5 => LzhMethod::Lh5,
        Method::Lh6 => LzhMethod::Lh6,
        Method::Lh7 => LzhMethod::Lh7,
    };
    if data.is_empty() {
        return Ok((b"-lh0-", Vec::new()));
    }
    let compressed = encode_lzh(data, method)
        .map_err(|error| Error::Format(format!("LZH compression failed: {error}")))?;
    if compressed.len() > data.len() {
        Ok((b"-lh0-", data.to_vec()))
    } else {
        let method_id = match requested {
            Method::Lh5 => b"-lh5-",
            Method::Lh6 => b"-lh6-",
            Method::Lh7 => b"-lh7-",
            Method::Stored => unreachable!(),
        };
        Ok((method_id, compressed))
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
    let header_crc = crc16(&header);
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

fn crc16(data: &[u8]) -> u16 {
    let mut crc = 0_u16;
    for byte in data {
        crc ^= u16::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xa001
            } else {
                crc >> 1
            };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::crc16;

    #[test]
    fn crc16_matches_lha_known_value() {
        assert_eq!(crc16(b"123456789"), 0xbb3d);
    }
}
