use serde_json::{Value, json};
use std::{
    ffi::{CString, c_char, c_void},
    fs, slice,
};
use tempfile::tempdir;
use unlhare::ffi::{
    STATUS_CANCELLED, STATUS_INVALID_ARGUMENT, STATUS_OK, unlhare_create_json_report,
    unlhare_list_json_with_progress,
};

#[derive(Default)]
struct State {
    results: Vec<Vec<u8>>,
    scanned: Vec<u64>,
    cancel_after: Option<u64>,
}

unsafe extern "C" fn receive(user: *mut c_void, bytes: *const c_char, length: u64) {
    // SAFETY: 通知中有効なJSON領域とStateをテストが提供する。
    unsafe {
        let state = &mut *user.cast::<State>();
        state
            .results
            .push(slice::from_raw_parts(bytes.cast(), length as usize).to_vec());
    }
}

unsafe extern "C" fn progress(user: *mut c_void, phase: u32, completed: u64, _: u64) -> i32 {
    // SAFETY: 呼出し終了までテストのStateが生存する。
    let state = unsafe { &mut *user.cast::<State>() };
    if phase == 1 {
        state.scanned.push(completed);
        if state.cancel_after.is_some_and(|limit| completed >= limit) {
            return 1;
        }
    }
    0
}

#[test]
fn result_api_creates_once_and_lists_once_with_cancellation() {
    let root = tempdir().unwrap();
    let archive = root.path().join("archive.lzh");
    let source = root.path().join("input.txt");
    fs::write(&source, "payload").unwrap();
    let create = CString::new(
        json!({"operation":"create","output":archive,"method":0,
        "entries":[{"path":source,"name":"folder\\input.txt"},
                   {"path":root.path().join("missing"),"name":"missing.txt"}]})
        .to_string(),
    )
    .unwrap();
    let mut state = State::default();
    // SAFETY: すべてのポインターと通知はこの同期呼出し中有効。
    let status = unsafe {
        unlhare_create_json_report(
            create.as_ptr(),
            Some(progress),
            Some(receive),
            (&mut state as *mut State).cast(),
        )
    };
    assert_eq!(status, STATUS_OK);
    assert_eq!(state.results.len(), 1);
    let result: Value = serde_json::from_slice(&state.results[0]).unwrap();
    assert_eq!(result["entries"][0]["name"], "folder/input.txt");
    assert_eq!(result["entries"][0]["status"], "written");
    assert_eq!(result["entries"][1]["status"], "skipped");

    let list = CString::new(json!({"archive":archive}).to_string()).unwrap();
    state = State::default();
    // SAFETY: すべてのポインターと通知はこの同期呼出し中有効。
    assert_eq!(
        unsafe {
            unlhare_list_json_with_progress(
                list.as_ptr(),
                Some(progress),
                Some(receive),
                (&mut state as *mut State).cast(),
            )
        },
        STATUS_OK
    );
    assert_eq!(state.results.len(), 1);
    assert_eq!(state.scanned.iter().filter(|&&n| n == 1).count(), 1);
    let entries: Value = serde_json::from_slice(&state.results[0]).unwrap();
    assert_eq!(entries.as_array().unwrap().len(), 1);
    assert!(entries[0]["modified_unix_seconds"].is_i64());

    state = State {
        cancel_after: Some(1),
        ..State::default()
    };
    // SAFETY: すべてのポインターと通知はこの同期呼出し中有効。
    assert_eq!(
        unsafe {
            unlhare_list_json_with_progress(
                list.as_ptr(),
                Some(progress),
                Some(receive),
                (&mut state as *mut State).cast(),
            )
        },
        STATUS_CANCELLED
    );
    assert!(state.results.is_empty());
}

#[test]
fn result_callback_is_required_before_side_effects_and_cancel_has_no_result() {
    let root = tempdir().unwrap();
    let archive = root.path().join("archive.lzh");
    let create = CString::new(
        json!({"operation":"create","output":archive,"method":0,"entries":[]}).to_string(),
    )
    .unwrap();
    let mut state = State {
        cancel_after: Some(0),
        ..State::default()
    };
    // SAFETY: NULL resultは引数検証対象。他のポインターは有効。
    assert_eq!(
        unsafe {
            unlhare_create_json_report(
                create.as_ptr(),
                None,
                None,
                (&mut state as *mut State).cast(),
            )
        },
        STATUS_INVALID_ARGUMENT
    );
    assert!(!archive.exists());
    // SAFETY: 有効な同期通知で最初の準備を中断する。
    assert_eq!(
        unsafe {
            unlhare_create_json_report(
                create.as_ptr(),
                Some(progress),
                Some(receive),
                (&mut state as *mut State).cast(),
            )
        },
        STATUS_CANCELLED
    );
    assert!(!archive.exists());
    assert!(state.results.is_empty());
}
