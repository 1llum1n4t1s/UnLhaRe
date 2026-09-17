use crate::{Entry, Error, Limits, Result, Summary, pathname};
use cap_std::{ambient_authority, fs::Dir};
use delharc::LhaDecodeReader;
use std::{
    collections::HashSet,
    fs::File,
    io::{self, BufRead, BufReader, Read, Write},
    path::Path,
};

type Decoder = LhaDecodeReader<BufReader<File>>;

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

fn decode<W: Write>(decoder: &mut Decoder, entry: &Entry, output: &mut W) -> Result<()> {
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
    }
    if bytes != entry.original_size {
        return Err(Error::Format("decoded size differs from header".into()));
    }
    decoder
        .crc_check()
        .map_err(|error| Error::Format(error.to_string()))?;
    Ok(())
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
    let mut decoder = open(path)?;
    let mut summary = Summary::default();
    let mut names = HashSet::new();
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        account(&entry, limits, &mut summary, &mut names)?;
        if !entry.is_directory {
            decode(&mut decoder, &entry, &mut io::sink())?;
        }
        if !next(&mut decoder)? {
            break;
        }
    }
    Ok(summary)
}

/// Extract into a capability-scoped directory, never replacing an existing file.
/// Each file is published only after CRC validation. Earlier completed entries
/// remain if a later entry fails; this is not an archive-wide transaction.
pub fn extract_archive(path: &Path, destination: &Path, limits: &Limits) -> Result<Summary> {
    let mut decoder = open(path)?;
    std::fs::create_dir_all(destination)?;
    let root = Dir::open_ambient_dir(destination, ambient_authority())?;
    let mut summary = Summary::default();
    let mut names = HashSet::new();
    while decoder.is_present() {
        let entry = metadata(&decoder)?;
        account(&entry, limits, &mut summary, &mut names)?;
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
            // no-replace hard-link commit after validation on both target OSes.
            let staging = cap_tempfile::TempDir::new_in(&parent)?;
            let mut file = staging.create("content")?;
            decode(&mut decoder, &entry, &mut file)?;
            file.sync_all()?;
            drop(file);
            staging
                .hard_link("content", &parent, filename)
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::AlreadyExists {
                        Error::Exists(destination.join(&relative))
                    } else {
                        Error::Io(error)
                    }
                })?;
            staging.close()?;
        }
        if !next(&mut decoder)? {
            break;
        }
    }
    Ok(summary)
}
