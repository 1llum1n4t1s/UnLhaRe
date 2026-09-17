use serde_json::json;
use std::{
    ffi::{CString, c_void},
    fs, ptr,
};
use tempfile::tempdir;
use unlhare::ffi::{
    STATUS_CANCELLED, STATUS_INVALID_ARGUMENT, STATUS_OK, unlhare_api_level, unlhare_run_json,
};

fn run(value: serde_json::Value) -> i32 {
    let request = CString::new(value.to_string()).unwrap();
    // SAFETY: requestは呼出し中有効であり、callbackは未指定。
    unsafe { unlhare_run_json(request.as_ptr(), None, ptr::null_mut()) }
}

#[test]
fn json_api_selection_and_validation() {
    let temp = tempdir().unwrap();
    let input = temp.path().join("日本語.txt");
    let archive = temp.path().join("test.lzh");
    let output = temp.path().join("out");
    fs::write(&input, "内容").unwrap();
    assert_eq!(unlhare_api_level(), 2);
    assert_eq!(
        run(
            json!({"operation":"create", "output":archive, "entries":[{"path":input,"name":"日本語.txt"}],"method":0})
        ),
        STATUS_OK
    );
    assert_eq!(
        run(json!({"operation":"verify","archive":archive})),
        STATUS_OK
    );
    assert_eq!(
        run(json!({"operation":"extract","archive":archive,"destination":output,"entries":[]})),
        STATUS_OK
    );
    assert!(!output.join("日本語.txt").exists());
    assert_eq!(
        run(
            json!({"operation":"extract","archive":archive,"destination":output,"entries":["日本語.txt"]})
        ),
        STATUS_OK
    );
    assert_eq!(
        fs::read_to_string(output.join("日本語.txt")).unwrap(),
        "内容"
    );
    assert_eq!(
        run(json!({"operation":"verify","archive":archive,"unknown":true})),
        STATUS_INVALID_ARGUMENT
    );
}

unsafe extern "C" fn cancel(user: *mut c_void, _: u32, _: u64, _: u64) -> i32 {
    // SAFETY: callerが有効なu32へのポインターを提供する。
    unsafe {
        *user.cast::<u32>() += 1;
    }
    1
}

#[test]
fn json_api_callback_lifetime_and_cancel_status() {
    let temp = tempdir().unwrap();
    let input = temp.path().join("input.txt");
    let archive = temp.path().join("cancelled.lzh");
    fs::write(&input, "data").unwrap();
    let request = CString::new(json!({"operation":"create","output":archive,"entries":[{"path":input,"name":"input.txt"}],"method":0}).to_string()).unwrap();
    let mut calls = 0u32;
    // SAFETY: request、callbackとuserは同期呼出しの間有効。
    let status = unsafe {
        unlhare_run_json(
            request.as_ptr(),
            Some(cancel),
            (&mut calls as *mut u32).cast(),
        )
    };
    assert_eq!(status, STATUS_CANCELLED);
    assert_eq!(calls, 1);
    assert!(!archive.exists());
}
