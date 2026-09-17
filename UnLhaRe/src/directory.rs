//! Directory traversal which resolves one component at a time without following links.

use cap_std::fs::Dir;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io;
use std::path::{Component, Path, PathBuf};

#[cfg(windows)]
use cap_std::fs::{OpenOptions as CapOpenOptions, OpenOptionsExt as _};
#[cfg(windows)]
use std::fs::OpenOptions;
#[cfg(windows)]
use std::os::windows::fs::{MetadataExt, OpenOptionsExt as _};
#[cfg(windows)]
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_SHARE_READ, FILE_SHARE_WRITE,
};

pub(crate) fn is_nofollow_rejection(error: &io::Error) -> bool {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{
            ERROR_REPARSE_POINT_ENCOUNTERED, ERROR_STOPPED_ON_SYMLINK,
        };

        error.kind() == io::ErrorKind::InvalidInput
            || matches!(
                error.raw_os_error(),
                Some(code)
                    if code == ERROR_REPARSE_POINT_ENCOUNTERED as i32
                        || code == ERROR_STOPPED_ON_SYMLINK as i32
            )
    }

    #[cfg(target_os = "macos")]
    {
        matches!(
            error.raw_os_error(),
            Some(code)
                if code == rustix::io::Errno::LOOP.raw_os_error()
                    || code == rustix::io::Errno::NOTDIR.raw_os_error()
        )
    }
}

pub(crate) fn open_ambient_directory_nofollow(path: &Path) -> io::Result<Dir> {
    walk_absolute(path, false)
}

pub(crate) fn create_ambient_directory_all_nofollow(path: &Path) -> io::Result<Dir> {
    walk_absolute(path, true)
}

pub(crate) fn open_directory_beneath_nofollow(root: &Dir, path: &Path) -> io::Result<Dir> {
    walk_beneath(root, path, false)
}

pub(crate) fn create_directory_all_beneath_nofollow(root: &Dir, path: &Path) -> io::Result<Dir> {
    walk_beneath(root, path, true)
}

pub(crate) fn open_ambient_entry_nofollow(path: &Path) -> io::Result<File> {
    let absolute = std::path::absolute(path)?;
    let name = entry_name(&absolute)?;
    let parent = absolute
        .parent()
        .ok_or_else(|| invalid_path("path has no parent directory"))?;
    let directory = open_ambient_directory_nofollow(parent)?;
    open_entry(&directory, &name)
}

pub(crate) fn open_entry_beneath_nofollow(root: &Dir, path: &Path) -> io::Result<File> {
    validate_relative(path)?;
    let name = entry_name(path)?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let directory = open_directory_beneath_nofollow(root, parent)?;
    open_entry(&directory, &name)
}

fn walk_absolute(path: &Path, create_missing: bool) -> io::Result<Dir> {
    let absolute = std::path::absolute(path)?;

    #[cfg(windows)]
    let (root, relative) = open_windows_root(&absolute)?;
    #[cfg(target_os = "macos")]
    let (root, relative) = open_macos_root(&absolute)?;

    walk_file(root, &relative, create_missing)
}

#[cfg(windows)]
fn open_windows_root(absolute: &Path) -> io::Result<(File, PathBuf)> {
    let mut anchor = PathBuf::new();
    let mut relative = PathBuf::new();
    let mut saw_root = false;

    for component in absolute.components() {
        match component {
            Component::Prefix(_) if relative.as_os_str().is_empty() => {
                anchor.push(component.as_os_str());
            }
            Component::RootDir if relative.as_os_str().is_empty() => {
                anchor.push(component.as_os_str());
                saw_root = true;
            }
            Component::Normal(name) if saw_root => relative.push(name),
            Component::CurDir if saw_root => {}
            Component::ParentDir => {
                return Err(invalid_path("path contains an unresolved parent component"));
            }
            _ => return Err(invalid_path("path is not an absolute Windows path")),
        }
    }
    if !saw_root {
        return Err(invalid_path("path has no filesystem root"));
    }

    let root = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(&anchor)?;
    validate_directory(&root, &anchor)?;
    Ok((root, relative))
}

#[cfg(target_os = "macos")]
fn open_macos_root(absolute: &Path) -> io::Result<(File, PathBuf)> {
    use rustix::fs::{Mode, OFlags, open};

    let relative = absolute
        .strip_prefix(Path::new("/"))
        .map_err(|_| invalid_path("path is not an absolute macOS path"))?
        .to_path_buf();
    let relative = normalize_macos_standard_root_alias(relative)?;
    let descriptor = open(
        "/",
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::DIRECTORY | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    let root = File::from(descriptor);
    validate_directory(&root, Path::new("/"))?;
    Ok((root, relative))
}

#[cfg(target_os = "macos")]
fn normalize_macos_standard_root_alias(relative: PathBuf) -> io::Result<PathBuf> {
    let Some(Component::Normal(first)) = relative.components().next() else {
        return Ok(relative);
    };
    let first = first.to_os_string();
    if !matches!(first.to_str(), Some("var" | "tmp" | "etc")) {
        return Ok(relative);
    }

    let expected_relative = PathBuf::from("private").join(&first);
    let expected_absolute = Path::new("/").join(&expected_relative);
    let observed = match std::fs::read_link(Path::new("/").join(&first)) {
        Ok(target) => target,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::InvalidInput
            ) =>
        {
            return Ok(relative);
        }
        Err(error) => return Err(error),
    };
    if observed != expected_relative && observed != expected_absolute {
        return Ok(relative);
    }

    let mut normalized = expected_relative;
    for component in relative.components().skip(1) {
        normalized.push(component.as_os_str());
    }
    Ok(normalized)
}

fn walk_beneath(root: &Dir, path: &Path, create_missing: bool) -> io::Result<Dir> {
    validate_relative(path)?;
    let root = root.try_clone()?.into_std_file();
    validate_directory(&root, Path::new("."))?;
    walk_file(root, path, create_missing)
}

fn walk_file(mut current: File, path: &Path, create_missing: bool) -> io::Result<Dir> {
    for component in path.components() {
        let Component::Normal(name) = component else {
            if matches!(component, Component::CurDir) {
                continue;
            }
            return Err(invalid_path(
                "directory path must contain only normal components",
            ));
        };

        let child = match open_child_directory_nofollow(&current, name) {
            Ok(child) => child,
            Err(error) if create_missing && error.kind() == io::ErrorKind::NotFound => {
                let parent = Dir::from_std_file(current.try_clone()?);
                match parent.create_dir(name) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error),
                }
                open_child_directory_nofollow(&current, name)?
            }
            Err(error) => return Err(error),
        };
        validate_directory(&child, Path::new(name))?;
        current = child;
    }
    Ok(Dir::from_std_file(current))
}

#[cfg(windows)]
fn open_child_directory_nofollow(parent: &File, name: &OsStr) -> io::Result<File> {
    cap_primitives::fs::open_dir_nofollow(parent, Path::new(name))
}

#[cfg(target_os = "macos")]
fn open_child_directory_nofollow(parent: &File, name: &OsStr) -> io::Result<File> {
    use rustix::fs::{Mode, OFlags, openat};

    let descriptor = openat(
        parent,
        Path::new(name),
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::DIRECTORY | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    Ok(File::from(descriptor))
}

#[cfg(windows)]
fn open_entry(parent: &Dir, name: &OsStr) -> io::Result<File> {
    let mut options = CapOpenOptions::new();
    options
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
    parent
        .open_with(name, &options)
        .map(cap_std::fs::File::into_std)
}

#[cfg(target_os = "macos")]
fn open_entry(parent: &Dir, name: &OsStr) -> io::Result<File> {
    use rustix::fs::{Mode, OFlags, openat};

    let descriptor = openat(
        parent,
        Path::new(name),
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    Ok(File::from(descriptor))
}

fn validate_relative(path: &Path) -> io::Result<()> {
    for component in path.components() {
        if !matches!(component, Component::Normal(_) | Component::CurDir) {
            return Err(invalid_path(
                "path must be relative and remain beneath its root",
            ));
        }
    }
    Ok(())
}

fn entry_name(path: &Path) -> io::Result<OsString> {
    let name = path
        .file_name()
        .ok_or_else(|| invalid_path("path has no final entry name"))?;
    if !matches!(
        Path::new(name).components().next(),
        Some(Component::Normal(_))
    ) {
        return Err(invalid_path(
            "final entry name is not a normal path component",
        ));
    }
    Ok(name.to_os_string())
}

fn validate_directory(file: &File, path: &Path) -> io::Result<()> {
    let metadata = file.metadata()?;
    #[cfg(windows)]
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("directory is a reparse point: {}", path.display()),
        ));
    }
    if !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotADirectory,
            format!("path component is not a directory: {}", path.display()),
        ));
    }
    Ok(())
}

fn invalid_path(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::normalize_macos_standard_root_alias;
    use std::path::{Path, PathBuf};

    #[test]
    fn normalizes_only_standard_macos_root_alias_targets() {
        for name in ["var", "tmp", "etc"] {
            let expected = PathBuf::from("private").join(name);
            let target = std::fs::read_link(Path::new("/").join(name))
                .expect("standard macOS root alias should exist");
            assert!(target == expected || target == Path::new("/").join(&expected));
            assert_eq!(
                normalize_macos_standard_root_alias(PathBuf::from(name).join("child"))
                    .expect("standard alias normalization should succeed"),
                expected.join("child")
            );
        }
    }
}
