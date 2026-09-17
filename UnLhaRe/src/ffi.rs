//! Stable C ABI for UnLhaRe.
//!
//! The functions in this module deliberately expose only C-compatible scalar
//! and pointer types. All input strings are UTF-8, NUL-terminated strings. The
//! caller owns every pointer passed across the boundary.

use std::cell::RefCell;
use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::slice;

use crate::{CreateOptions, Limits, Method};

mod app;
pub use app::{
    JsonCallback, ProgressCallback, unlhare_api_level, unlhare_create_json_report,
    unlhare_list_json_ex, unlhare_list_json_with_progress, unlhare_run_json,
};

/// 操作がコールバックから中断された。
pub const STATUS_CANCELLED: i32 = 5;

/// ABI version implemented by this library.
pub const ABI_VERSION: u32 = 1;

/// Operation completed successfully.
pub const STATUS_OK: i32 = 0;
/// The archive operation failed.
pub const STATUS_ERROR: i32 = 1;
/// The caller-provided output buffer was too small.
pub const STATUS_BUFFER_TOO_SMALL: i32 = 2;
/// One or more arguments were invalid.
pub const STATUS_INVALID_ARGUMENT: i32 = 3;
/// A Rust panic was caught at the ABI boundary.
pub const STATUS_PANIC: i32 = 4;

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

#[derive(Debug)]
struct FfiError {
    status: i32,
    message: String,
}

impl FfiError {
    fn operation(message: impl Into<String>) -> Self {
        Self {
            status: STATUS_ERROR,
            message: message.into(),
        }
    }

    fn invalid(message: impl Into<String>) -> Self {
        Self {
            status: STATUS_INVALID_ARGUMENT,
            message: message.into(),
        }
    }

    fn buffer_too_small(required: u64, capacity: u64) -> Self {
        Self {
            status: STATUS_BUFFER_TOO_SMALL,
            message: format!(
                "output buffer is too small: required {required} bytes, received {capacity}"
            ),
        }
    }
}

fn set_last_error(message: &str) {
    LAST_ERROR.with(|last_error| {
        let mut destination = last_error.borrow_mut();
        destination.clear();
        for character in message.chars() {
            if character == '\0' {
                destination.push('\u{fffd}');
            } else {
                destination.push(character);
            }
        }
    });
}

fn run_ffi(operation: impl FnOnce() -> Result<(), FfiError>) -> i32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => {
            let status = error.status;
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                set_last_error(&error.message)
            }))
            .is_err()
            {
                STATUS_PANIC
            } else {
                status
            }
        }
        Err(_) => {
            let _ = std::panic::catch_unwind(|| {
                set_last_error("a Rust panic was caught at the FFI boundary")
            });
            STATUS_PANIC
        }
    }
}

unsafe fn write_required(required: *mut u64, value: u64) -> Result<(), FfiError> {
    if required.is_null() {
        return Err(FfiError::invalid("required must not be null"));
    }

    // SAFETY: The caller contract requires `required` to point to a writable
    // `u64` for the duration of this call. Null was rejected above.
    unsafe { *required = value };
    Ok(())
}

unsafe fn utf8_path(pointer: *const c_char, name: &str) -> Result<PathBuf, FfiError> {
    if pointer.is_null() {
        return Err(FfiError::invalid(format!("{name} must not be null")));
    }

    // SAFETY: The caller contract requires `pointer` to reference a readable,
    // NUL-terminated byte string for the duration of this call.
    let value = unsafe { CStr::from_ptr(pointer) };
    let value = value
        .to_str()
        .map_err(|_| FfiError::invalid(format!("{name} must be valid UTF-8")))?;
    if value.is_empty() {
        return Err(FfiError::invalid(format!("{name} must not be empty")));
    }

    Ok(PathBuf::from(value))
}

fn nul_terminated_length(bytes: &[u8]) -> Result<(usize, u64), FfiError> {
    let length = bytes
        .len()
        .checked_add(1)
        .ok_or_else(|| FfiError::operation("output length overflowed usize"))?;
    if length > isize::MAX as usize {
        return Err(FfiError::operation(
            "output is larger than the maximum supported pointer offset",
        ));
    }
    let length_u64 = u64::try_from(length)
        .map_err(|_| FfiError::operation("output length overflowed uint64_t"))?;
    Ok((length, length_u64))
}

fn validate_output_arguments(
    output: *mut c_char,
    capacity: u64,
    required: *mut u64,
) -> Result<(), FfiError> {
    if required.is_null() {
        return Err(FfiError::invalid("required must not be null"));
    }
    if output.is_null() && capacity != 0 {
        return Err(FfiError::invalid(
            "output must not be null when capacity is non-zero",
        ));
    }
    let capacity = usize::try_from(capacity)
        .map_err(|_| FfiError::invalid("capacity does not fit in usize"))?;
    if capacity > isize::MAX as usize {
        return Err(FfiError::invalid(
            "capacity exceeds the maximum supported pointer offset",
        ));
    }
    Ok(())
}

unsafe fn copy_output(
    bytes: &[u8],
    output: *mut c_char,
    capacity: u64,
    required: *mut u64,
) -> Result<(), FfiError> {
    validate_output_arguments(output, capacity, required)?;
    let (required_usize, required_u64) = nul_terminated_length(bytes)?;
    // SAFETY: This function has the same pointer contract as the public ABI.
    unsafe { write_required(required, required_u64)? };

    if output.is_null() {
        return Err(FfiError::buffer_too_small(required_u64, capacity));
    }

    // Conversion and `isize::MAX` bounds were checked above.
    let capacity_usize = capacity as usize;
    if capacity_usize < required_usize {
        return Err(FfiError::buffer_too_small(required_u64, capacity));
    }

    // SAFETY: The caller contract requires `output` to reference `capacity`
    // writable bytes. The checked capacity is at least `required_usize`, and
    // both lengths are at most `isize::MAX`.
    let destination = unsafe { slice::from_raw_parts_mut(output.cast::<u8>(), required_usize) };
    destination[..bytes.len()].copy_from_slice(bytes);
    destination[bytes.len()] = 0;
    Ok(())
}

fn method_from_abi(method: i32) -> Result<Method, FfiError> {
    match method {
        0 => Ok(Method::Stored),
        5 => Ok(Method::Lh5),
        6 => Ok(Method::Lh6),
        7 => Ok(Method::Lh7),
        value => Err(FfiError::invalid(format!(
            "method must be one of 0, 5, 6, or 7; received {value}"
        ))),
    }
}

/// Returns the stable C ABI version.
#[unsafe(no_mangle)]
pub extern "C" fn unlhare_abi_version() -> u32 {
    ABI_VERSION
}

/// Serializes the archive entry list as UTF-8 JSON.
///
/// On success, `output` contains a NUL-terminated JSON document and `required`
/// receives its byte length including the terminator. Pass a null `output` and
/// zero `capacity` to query the required size; that query returns
/// [`STATUS_BUFFER_TOO_SMALL`].
///
/// # Safety
///
/// `archive_utf8` must point to a readable, NUL-terminated UTF-8 string.
/// `required` must point to a writable `u64`. When `output` is non-null, it must
/// point to `capacity` writable bytes. These regions must remain valid for the
/// duration of the call and must not overlap each other.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_list_json(
    archive_utf8: *const c_char,
    output: *mut c_char,
    capacity: u64,
    required: *mut u64,
) -> i32 {
    run_ffi(|| {
        validate_output_arguments(output, capacity, required)?;
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let archive = unsafe { utf8_path(archive_utf8, "archive_utf8")? };
        let entries = crate::list_archive(&archive, &Limits::default())
            .map_err(|error| FfiError::operation(error.to_string()))?;
        let json = serde_json::to_vec(&entries).map_err(|error| {
            FfiError::operation(format!("failed to serialize entry list: {error}"))
        })?;
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        unsafe { copy_output(&json, output, capacity, required) }
    })
}

/// Verifies the structure and payloads in an archive.
///
/// # Safety
///
/// `archive_utf8` must point to a readable, NUL-terminated UTF-8 string that
/// remains valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_verify(archive_utf8: *const c_char) -> i32 {
    run_ffi(|| {
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let archive = unsafe { utf8_path(archive_utf8, "archive_utf8")? };
        crate::verify_archive(&archive, &Limits::default())
            .map_err(|error| FfiError::operation(error.to_string()))?;
        Ok(())
    })
}

/// Extracts an archive into a destination directory.
///
/// # Safety
///
/// Both arguments must point to readable, NUL-terminated UTF-8 strings that
/// remain valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_extract(
    archive_utf8: *const c_char,
    destination_utf8: *const c_char,
) -> i32 {
    run_ffi(|| {
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let archive = unsafe { utf8_path(archive_utf8, "archive_utf8")? };
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let destination = unsafe { utf8_path(destination_utf8, "destination_utf8")? };
        crate::extract_archive(&archive, &destination, &Limits::default())
            .map_err(|error| FfiError::operation(error.to_string()))?;
        Ok(())
    })
}

/// Creates an archive from all files below a source directory.
///
/// `method` is `0` for stored data or `5`, `6`, or `7` for the corresponding
/// LHA compression method.
///
/// # Safety
///
/// Both string arguments must point to readable, NUL-terminated UTF-8 strings
/// that remain valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_create(
    output_utf8: *const c_char,
    source_directory_utf8: *const c_char,
    method: i32,
) -> i32 {
    run_ffi(|| {
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let output = unsafe { utf8_path(output_utf8, "output_utf8")? };
        // SAFETY: Pointer validity is guaranteed by the public caller contract.
        let source_directory =
            unsafe { utf8_path(source_directory_utf8, "source_directory_utf8")? };
        let method = method_from_abi(method)?;
        let options = CreateOptions {
            method,
            limits: Limits::default(),
        };
        crate::create_from_directory(&source_directory, &output, &options)
            .map_err(|error| FfiError::operation(error.to_string()))?;
        Ok(())
    })
}

/// Copies the calling thread's most recent ABI error as UTF-8.
///
/// The size query and copy do not clear or replace the saved error, including
/// when this function itself receives invalid arguments.
///
/// # Safety
///
/// `required` must point to a writable `u64`. When `output` is non-null, it must
/// point to `capacity` writable bytes. The regions must remain valid for the
/// duration of the call and must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_last_error(
    output: *mut c_char,
    capacity: u64,
    required: *mut u64,
) -> i32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        LAST_ERROR.with(|last_error| {
            let last_error = last_error.borrow();
            // SAFETY: Pointer validity is guaranteed by the public caller contract.
            unsafe { copy_output(last_error.as_bytes(), output, capacity, required) }
        })
    })) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => error.status,
        Err(_) => STATUS_PANIC,
    }
}
