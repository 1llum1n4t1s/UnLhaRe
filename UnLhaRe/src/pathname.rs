use crate::{Error, Result};
use delharc::LhaHeader;
use std::path::PathBuf;

/// Use the same portable filename contract on every operating system.
pub(crate) fn validate_entry_name(name: &str) -> Result<PathBuf> {
    if name.is_empty() || name.len() > 32_000 || name.starts_with('/') || name.contains('\\') {
        return Err(Error::InvalidPath(name.into()));
    }
    let mut path = PathBuf::new();
    for part in name.trim_end_matches('/').split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with(['.', ' '])
            || part
                .chars()
                .any(|c| c.is_control() || ":*?\"<>|".contains(c))
        {
            return Err(Error::InvalidPath(name.into()));
        }
        let stem = part
            .split('.')
            .next()
            .unwrap_or_default()
            .to_ascii_uppercase();
        if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$")
            || (stem.len() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        {
            return Err(Error::InvalidPath(name.into()));
        }
        path.push(part);
    }
    Ok(path)
}

fn decode_name(bytes: &[u8], codepage: Option<u32>) -> Result<String> {
    if codepage == Some(65001) {
        return String::from_utf8(bytes.to_vec()).map_err(|e| Error::Format(e.to_string()));
    }
    if codepage.is_none()
        && let Ok(text) = std::str::from_utf8(bytes)
    {
        return Ok(text.into());
    }
    let encoding = match codepage {
        None | Some(0 | 932) => encoding_rs::SHIFT_JIS,
        Some(51932 | 20932) => encoding_rs::EUC_JP,
        Some(1252) => encoding_rs::WINDOWS_1252,
        Some(other) => return Err(Error::Unsupported(format!("filename code page {other}"))),
    };
    let (text, _, errors) = encoding.decode(bytes);
    if errors {
        return Err(Error::Format("filename encoding is invalid".into()));
    }
    Ok(text.into_owned())
}

fn utf16_name(bytes: &[u8], directory: bool) -> Result<String> {
    if !bytes.len().is_multiple_of(2) {
        return Err(Error::Format("odd UTF-16 filename length".into()));
    }
    let words: Vec<u16> = bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|v| {
            let word = u16::from_le_bytes([v[0], v[1]]);
            if directory && word == 0xffff {
                u16::from(b'/')
            } else {
                word
            }
        })
        .collect();
    String::from_utf16(&words).map_err(|e| Error::Format(e.to_string()))
}

pub(crate) fn archive_name(header: &LhaHeader) -> Result<String> {
    let mut codepage = None;
    let mut filename = header.filename.as_ref();
    let mut directory: Option<&[u8]> = None;
    let mut wide_file = None;
    let mut wide_directory = None;
    for extra in header.iter_extra() {
        match extra {
            [0x01, value @ ..] => filename = value,
            [0x02, value @ ..] => directory = Some(value),
            [0x44, value @ ..] => wide_file = Some(value),
            [0x45, value @ ..] => wide_directory = Some(value),
            [0x46, a, b, c, d] => codepage = Some(u32::from_le_bytes([*a, *b, *c, *d])),
            _ => {}
        }
    }
    let name = if let Some(bytes) = wide_file {
        utf16_name(bytes, false)?
    } else {
        decode_name(filename, codepage)?
    };
    let dir = if let Some(bytes) = wide_directory {
        utf16_name(bytes, true)?
    } else if let Some(bytes) = directory {
        bytes
            .split(|b| *b == 0xff)
            .map(|part| decode_name(part, codepage))
            .collect::<Result<Vec<_>>>()?
            .join("/")
    } else {
        String::new()
    };
    let combined = if dir.is_empty() {
        name
    } else if name.is_empty() {
        dir
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    };
    let portable = combined.replace('\\', "/");
    let portable = portable.trim_end_matches('/').to_string();
    validate_entry_name(&portable)?;
    Ok(portable)
}
