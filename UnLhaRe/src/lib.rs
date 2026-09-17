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
mod pathname;
mod reader;
mod writer;

pub use error::{Error, Result};
pub use reader::{extract_archive, list_archive, verify_archive};
pub use writer::create_archive;

use serde::Serialize;
use std::{
    fs,
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

/// A regular file or an explicit directory and its portable archive name.
#[derive(Debug, Clone)]
pub struct SourceEntry {
    pub path: PathBuf,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    pub name: String,
    pub method: String,
    pub original_size: u64,
    pub compressed_size: u64,
    pub is_directory: bool,
    pub crc16: u16,
    pub header_level: u8,
}

#[derive(Debug, Clone, Default, Serialize)]
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
    let metadata = fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(Error::InvalidArgument(
            "source must be a regular directory".into(),
        ));
    }
    fn visit(
        root: &Path,
        directory: &Path,
        entries: &mut Vec<SourceEntry>,
        limits: &Limits,
        depth: usize,
    ) -> Result<()> {
        if depth > 128 {
            return Err(Error::Limit("directory depth exceeds 128".into()));
        }
        let mut children = Vec::new();
        for child in fs::read_dir(directory)? {
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
            let path = child.path();
            let kind = child.file_type()?;
            if kind.is_symlink() || (!kind.is_file() && !kind.is_dir()) {
                return Err(Error::Unsupported(format!(
                    "non-regular input: {}",
                    path.display()
                )));
            }
            let relative = path
                .strip_prefix(root)
                .map_err(|e| Error::InvalidArgument(e.to_string()))?;
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
                path: path.clone(),
                name,
            });
            if kind.is_dir() {
                visit(root, &path, entries, limits, depth + 1)?;
            }
        }
        Ok(())
    }
    let mut entries = Vec::new();
    visit(source, source, &mut entries, &options.limits, 0)?;
    create_archive(destination, &entries, options)
}
