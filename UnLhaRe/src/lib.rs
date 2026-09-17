//! Portable LHA operations with a new UTF-8, 64-bit interface.
//!
//! This is independent of the UNLHA32 x86 ABI. Operations own their decoder state;
//! they do not change the working directory, registry, or process signal handlers.

#[cfg(not(all(
    target_pointer_width = "64",
    any(target_arch = "x86_64", target_arch = "aarch64"),
    any(target_os = "windows", target_os = "macos")
)))]
compile_error!("UnLhaRe supports only Windows/macOS on x86_64 or aarch64 (64-bit).");

mod error;
pub mod ffi;
mod operation;
mod pathname;
mod reader;
mod writer;

pub use error::{Error, Result};
pub use operation::{Progress, ProgressCallback};
pub use reader::{
    extract_archive, extract_archive_with_options, extract_archive_with_progress, list_archive,
    list_archive_with_progress, verify_archive, verify_archive_with_progress,
};
pub use writer::{create_archive, create_archive_with_progress, create_archive_with_report};

use cap_std::fs::Dir;
use serde::Serialize;
use std::{
    fs::File,
    io,
    path::{Path, PathBuf},
};

/// Writer methods. Unprofitable compression may be stored as LH0.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Method {
    Stored,
    #[default]
    Lh5,
    Lh6,
    Lh7,
}

/// Caller-controlled memory/output policy. Sizes never use platform-dependent `long`.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_entries: u64,
    pub max_entry_bytes: u64,
    pub max_total_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_entries: 100_000,
            max_entry_bytes: 256 * 1024 * 1024,
            max_total_bytes: 2 * 1024 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CreateOptions {
    pub method: Method,
    pub limits: Limits,
}

/// Optional extraction behavior. Existing APIs keep their original defaults.
#[derive(Debug, Clone, Copy, Default)]
pub struct ExtractOptions {
    /// Restore regular-file modification times before publishing each file.
    /// Directory timestamps are not changed.
    pub preserve_timestamps: bool,
}

/// Result of explicitly requesting creation that skips unreadable source files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CreateReport {
    pub entries: Vec<CreateEntryResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CreateEntryResult {
    pub name: String,
    pub status: CreateEntryStatus,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CreateEntryStatus {
    Written,
    Skipped,
}

/// A regular file or an explicit directory and its portable archive name.
#[derive(Debug, Clone)]
pub struct SourceEntry {
    pub path: PathBuf,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    pub method: String,
    pub original_size: u64,
    pub compressed_size: u64,
    pub is_directory: bool,
    pub crc16: u16,
    pub header_level: u8,
    /// Unix seconds; DOS timestamps use the host local time zone.
    /// Invalid or ambiguous local timestamps have no value.
    pub modified_unix_seconds: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Summary {
    pub entries: u64,
    pub files: u64,
    pub bytes: u64,
}

/// Collect a directory deterministically. Symbolic links and special files are rejected.
pub fn create_from_directory(
    source: &Path,
    destination: &Path,
    options: &CreateOptions,
) -> Result<()> {
    let directory = open_source_directory_nofollow(source)?;
    let metadata = directory.metadata()?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::InvalidArgument(
            "source must be a regular directory".into(),
        ));
    }
    let root = Dir::from_std_file(directory);
    fn visit(
        directory: &Dir,
        relative_directory: &Path,
        entries: &mut Vec<SourceEntry>,
        limits: &Limits,
        depth: usize,
    ) -> Result<()> {
        if depth > 128 {
            return Err(Error::Limit("directory depth exceeds 128".into()));
        }
        let mut children = Vec::new();
        for child in directory.entries()? {
            if children.len() as u64 >= limits.max_entries.saturating_sub(entries.len() as u64) {
                return Err(Error::Limit("entry count".into()));
            }
            children.push(child?);
        }
        children.sort_by_key(|child| child.file_name());
        for child in children {
            if entries.len() as u64 >= limits.max_entries {
                return Err(Error::Limit("entry count".into()));
            }
            let kind = child.file_type()?;
            if kind.is_symlink() || (!kind.is_file() && !kind.is_dir()) {
                return Err(Error::Unsupported(format!(
                    "non-regular input: {}",
                    relative_directory.join(child.file_name()).display()
                )));
            }
            let child_name = child.file_name();
            let relative = relative_directory.join(&child_name);
            let name = relative
                .components()
                .map(|component| {
                    component
                        .as_os_str()
                        .to_str()
                        .ok_or_else(|| Error::InvalidPath(relative.display().to_string()))
                })
                .collect::<Result<Vec<_>>>()?
                .join("/");
            pathname::validate_entry_name(&name)?;
            entries.push(SourceEntry {
                path: relative.clone(),
                name,
            });
            if kind.is_dir() {
                // Opening from the current directory handle keeps resolution
                // beneath that directory even if the name is raced to a link.
                let child_directory = directory.open_dir(&child_name)?;
                visit(&child_directory, &relative, entries, limits, depth + 1)?;
            }
        }
        Ok(())
    }
    let mut entries = Vec::new();
    visit(&root, Path::new(""), &mut entries, &options.limits, 0)?;
    writer::create_archive_beneath(destination, &root, &entries, options)
}

#[cfg(windows)]
fn open_source_directory_nofollow(source: &Path) -> io::Result<File> {
    use std::fs::OpenOptions;
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    };

    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(source)?;
    if directory.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "source directory is a reparse point",
        ));
    }
    Ok(directory)
}

#[cfg(target_os = "macos")]
fn open_source_directory_nofollow(source: &Path) -> io::Result<File> {
    use rustix::fs::{Mode, OFlags, open};

    let descriptor = open(
        source,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::DIRECTORY | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    Ok(File::from(descriptor))
}

#[cfg(test)]
mod tests {
    use super::open_source_directory_nofollow;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn source_directory_symlink_is_not_followed() {
        let temporary = tempdir().expect("temporary directory");
        let target = temporary.path().join("target");
        let link = temporary.path().join("link");
        fs::create_dir(&target).expect("source target");

        #[cfg(windows)]
        let linked = std::os::windows::fs::symlink_dir(&target, &link);
        #[cfg(target_os = "macos")]
        let linked = std::os::unix::fs::symlink(&target, &link);
        if let Err(error) = linked {
            if error.kind() == std::io::ErrorKind::PermissionDenied
                || error.raw_os_error() == Some(1314)
            {
                return;
            }
            panic!("create source directory symlink: {error}");
        }

        open_source_directory_nofollow(&link)
            .expect_err("source directory symlink must not be followed");
    }
}
