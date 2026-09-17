use super::*;
use serde::Deserialize;
use std::ffi::c_void;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputLimits {
    max_entries: u64,
    max_entry_bytes: u64,
    max_total_bytes: u64,
}

impl Default for InputLimits {
    fn default() -> Self {
        let value = Limits::default();
        Self {
            max_entries: value.max_entries,
            max_entry_bytes: value.max_entry_bytes,
            max_total_bytes: value.max_total_bytes,
        }
    }
}

impl From<InputLimits> for Limits {
    fn from(value: InputLimits) -> Self {
        Self {
            max_entries: value.max_entries,
            max_entry_bytes: value.max_entry_bytes,
            max_total_bytes: value.max_total_bytes,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    path: PathBuf,
    name: String,
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Create {
        output: PathBuf,
        entries: Vec<Source>,
        method: i32,
        #[serde(default)]
        limits: InputLimits,
    },
    Extract {
        archive: PathBuf,
        destination: PathBuf,
        entries: Option<Vec<String>>,
        #[serde(default)]
        limits: InputLimits,
    },
    Verify {
        archive: PathBuf,
        #[serde(default)]
        limits: InputLimits,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListRequest {
    archive: PathBuf,
    #[serde(default)]
    limits: InputLimits,
}

fn operation_error(error: crate::Error) -> FfiError {
    if matches!(error, crate::Error::Cancelled) {
        FfiError {
            status: STATUS_CANCELLED,
            message: error.to_string(),
        }
    } else {
        FfiError::operation(error.to_string())
    }
}

unsafe fn parse_request<T: serde::de::DeserializeOwned>(
    request: *const c_char,
) -> Result<T, FfiError> {
    if request.is_null() {
        return Err(FfiError::invalid("request must not be null"));
    }
    // 呼び出し元が有効なNUL終端領域を提供する。
    let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
    serde_json::from_slice(bytes)
        .map_err(|error| FfiError::invalid(format!("invalid request: {error}")))
}

/// ABI 1に追加されたアプリ連携APIの世代。
#[unsafe(no_mangle)]
pub extern "C" fn unlhare_api_level() -> u32 {
    2
}

/// 0で続行、それ以外で中断する。同じ呼び出しスレッドで同期実行する。
pub type ProgressCallback = unsafe extern "C" fn(*mut c_void, u32, u64, u64) -> i32;

/// JSON指定による選択圧縮・展開・検査。コールバックとuserは呼び出し終了後に保持しない。
///
/// # Safety
/// requestは呼び出し中有効なNUL終端UTF-8。callbackは有効な関数であり、
/// userを適切に扱い、例外をこの境界へ伝播させてはならない。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_run_json(
    request: *const c_char,
    callback: Option<ProgressCallback>,
    user: *mut c_void,
) -> i32 {
    run_ffi(|| {
        // ポインターの有効性は公開契約で保証される。
        let request: Request = unsafe { parse_request(request)? };
        let mut report = |progress: crate::Progress| {
            match callback {
                None => true,
                // callbackとuserは呼び出し元の契約に従い同期利用する。
                Some(callback) => unsafe {
                    callback(user, progress.phase, progress.completed, progress.total) == 0
                },
            }
        };
        match request {
            Request::Create {
                output,
                entries,
                method,
                limits,
            } => {
                let method = method_from_abi(method)?;
                let sources: Vec<_> = entries
                    .into_iter()
                    .map(|entry| crate::SourceEntry {
                        path: entry.path,
                        name: entry.name,
                    })
                    .collect();
                crate::create_archive_with_progress(
                    &output,
                    &sources,
                    &CreateOptions {
                        method,
                        limits: limits.into(),
                    },
                    &mut report,
                )
                .map_err(operation_error)?;
            }
            Request::Extract {
                archive,
                destination,
                entries,
                limits,
            } => {
                crate::extract_archive_with_progress(
                    &archive,
                    &destination,
                    &limits.into(),
                    entries.as_deref(),
                    &mut report,
                )
                .map_err(operation_error)?;
            }
            Request::Verify { archive, limits } => {
                crate::verify_archive_with_progress(&archive, &limits.into(), &mut report)
                    .map_err(operation_error)?;
            }
        }
        Ok(())
    })
}

/// 上限指定付き一覧JSON。出力バッファの契約はunlhare_list_jsonと同一。
///
/// # Safety
/// requestは有効なNUL終端UTF-8。requiredは書込可能u64、outputはcapacity分の
/// 書込可能領域（容量0のNULL照会を除く）。各領域は重複せず呼び出し中有効。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlhare_list_json_ex(
    request: *const c_char,
    output: *mut c_char,
    capacity: u64,
    required: *mut u64,
) -> i32 {
    run_ffi(|| {
        validate_output_arguments(output, capacity, required)?;
        // ポインターの有効性は公開契約で保証される。
        let request: ListRequest = unsafe { parse_request(request)? };
        let entries = crate::list_archive(&request.archive, &request.limits.into())
            .map_err(operation_error)?;
        let json =
            serde_json::to_vec(&entries).map_err(|error| FfiError::operation(error.to_string()))?;
        // ポインターの有効性は公開契約で保証される。
        unsafe { copy_output(&json, output, capacity, required) }
    })
}
