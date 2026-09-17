use std::ffi::{CStr, CString, c_char};
use std::fs;
use std::ptr;

use tempfile::tempdir;
use unlhare::ffi::{
    STATUS_BUFFER_TOO_SMALL, STATUS_INVALID_ARGUMENT, STATUS_OK, unlhare_abi_version,
    unlhare_create, unlhare_extract, unlhare_last_error, unlhare_list_json, unlhare_verify,
};

fn c_path(path: &std::path::Path) -> CString {
    CString::new(path.to_string_lossy().as_bytes()).expect("temporary path must not contain NUL")
}

fn last_error() -> String {
    let mut required = 0_u64;
    // SAFETY: `required` is writable and a null output with zero capacity is
    // the documented size-query contract.
    let status = unsafe { unlhare_last_error(ptr::null_mut(), 0, &mut required) };
    assert_eq!(status, STATUS_BUFFER_TOO_SMALL);
    assert!(required >= 1);

    let mut output = vec![0_u8; usize::try_from(required).expect("error length must fit usize")];
    // SAFETY: `output` has exactly `required` writable bytes and `required` is writable.
    let status = unsafe {
        unlhare_last_error(
            output.as_mut_ptr().cast::<c_char>(),
            output.len() as u64,
            &mut required,
        )
    };
    assert_eq!(status, STATUS_OK);
    CStr::from_bytes_with_nul(&output)
        .expect("last error must be NUL-terminated")
        .to_str()
        .expect("last error must be UTF-8")
        .to_owned()
}

#[test]
fn c_abi_round_trip_and_buffer_contract() {
    let temporary = tempdir().expect("temporary directory");
    let source = temporary.path().join("source");
    let archive = temporary.path().join("round-trip.lzh");
    let extracted = temporary.path().join("extracted");
    fs::create_dir_all(source.join("nested")).expect("source directory");
    fs::write(
        source.join("nested").join("hello.txt"),
        "hello from the C ABI\n",
    )
    .expect("source file");

    let source_c = c_path(&source);
    let archive_c = c_path(&archive);
    let extracted_c = c_path(&extracted);

    assert_eq!(unlhare_abi_version(), 1);
    // SAFETY: All pointers reference live, NUL-terminated UTF-8 strings.
    assert_eq!(
        unsafe { unlhare_create(archive_c.as_ptr(), source_c.as_ptr(), 0) },
        STATUS_OK,
        "{}",
        last_error()
    );
    // SAFETY: `archive_c` is a live, NUL-terminated UTF-8 string.
    assert_eq!(
        unsafe { unlhare_verify(archive_c.as_ptr()) },
        STATUS_OK,
        "{}",
        last_error()
    );

    let mut required = 0_u64;
    // SAFETY: This is the documented size query and `required` is writable.
    assert_eq!(
        unsafe { unlhare_list_json(archive_c.as_ptr(), ptr::null_mut(), 0, &mut required) },
        STATUS_BUFFER_TOO_SMALL
    );
    assert!(required > 1);

    let mut short = [0x55_u8; 2];
    let mut required_again = 0_u64;
    // SAFETY: `short` and `required_again` are writable for their declared sizes.
    assert_eq!(
        unsafe {
            unlhare_list_json(
                archive_c.as_ptr(),
                short.as_mut_ptr().cast::<c_char>(),
                short.len() as u64,
                &mut required_again,
            )
        },
        STATUS_BUFFER_TOO_SMALL
    );
    assert_eq!(required_again, required);
    assert_eq!(short, [0x55, 0x55], "short buffers must not be modified");

    let mut json = vec![0_u8; usize::try_from(required).expect("JSON length must fit usize")];
    // SAFETY: `json` has `required` writable bytes and all other pointers are valid.
    assert_eq!(
        unsafe {
            unlhare_list_json(
                archive_c.as_ptr(),
                json.as_mut_ptr().cast::<c_char>(),
                json.len() as u64,
                &mut required,
            )
        },
        STATUS_OK,
        "{}",
        last_error()
    );
    let json = CStr::from_bytes_with_nul(&json)
        .expect("JSON must be NUL-terminated")
        .to_str()
        .expect("JSON must be UTF-8");
    let entries: serde_json::Value = serde_json::from_str(json).expect("valid JSON entry list");
    assert!(
        entries
            .as_array()
            .is_some_and(|entries| !entries.is_empty())
    );
    assert!(json.contains("hello.txt"));

    // SAFETY: Both pointers reference live, NUL-terminated UTF-8 strings.
    assert_eq!(
        unsafe { unlhare_extract(archive_c.as_ptr(), extracted_c.as_ptr()) },
        STATUS_OK,
        "{}",
        last_error()
    );
    assert_eq!(
        fs::read_to_string(extracted.join("nested").join("hello.txt")).expect("extracted file"),
        "hello from the C ABI\n"
    );
}

#[test]
fn invalid_arguments_and_last_error_contract() {
    let mut required = 99_u64;
    // SAFETY: `required` is writable. A null archive pointer is a supported
    // invalid-argument probe and is never dereferenced.
    assert_eq!(
        unsafe { unlhare_list_json(ptr::null(), ptr::null_mut(), 0, &mut required) },
        STATUS_INVALID_ARGUMENT
    );
    let original = last_error();
    assert!(original.contains("archive_utf8"));

    let mut output = [0_u8; 8];
    // SAFETY: The output storage is valid. A null `required` is a supported
    // invalid-argument probe and is never dereferenced.
    assert_eq!(
        unsafe {
            unlhare_last_error(
                output.as_mut_ptr().cast::<c_char>(),
                output.len() as u64,
                ptr::null_mut(),
            )
        },
        STATUS_INVALID_ARGUMENT
    );
    assert_eq!(last_error(), original, "last_error must preserve its value");

    let archive = CString::new("unused.lzh").expect("literal CString");
    required = 0;
    // SAFETY: The archive and required pointers are valid. Null output with a
    // non-zero capacity is rejected before the output pointer is dereferenced.
    assert_eq!(
        unsafe { unlhare_list_json(archive.as_ptr(), ptr::null_mut(), 1, &mut required) },
        STATUS_INVALID_ARGUMENT
    );

    // SAFETY: Null `required` is rejected before the archive or output pointers
    // are dereferenced.
    assert_eq!(
        unsafe {
            unlhare_list_json(
                archive.as_ptr(),
                output.as_mut_ptr().cast::<c_char>(),
                output.len() as u64,
                ptr::null_mut(),
            )
        },
        STATUS_INVALID_ARGUMENT
    );

    required = 0;
    // SAFETY: The oversized capacity is rejected before the one-byte output
    // allocation can be accessed.
    assert_eq!(
        unsafe {
            unlhare_list_json(
                archive.as_ptr(),
                output.as_mut_ptr().cast::<c_char>(),
                u64::MAX,
                &mut required,
            )
        },
        STATUS_INVALID_ARGUMENT
    );
}

#[test]
fn last_error_is_thread_local() {
    let temporary = tempdir().expect("temporary directory");
    let source = c_path(temporary.path());

    let main_output = CString::new("main.lzh").expect("literal CString");
    // SAFETY: Both strings are valid; method 99 is rejected before archive creation.
    assert_eq!(
        unsafe { unlhare_create(main_output.as_ptr(), source.as_ptr(), 99) },
        STATUS_INVALID_ARGUMENT
    );
    assert!(last_error().contains("99"));

    let errors: Vec<String> = [41, 42]
        .into_iter()
        .map(|method| {
            std::thread::spawn(move || {
                let temporary = tempdir().expect("thread temporary directory");
                let source = c_path(temporary.path());
                let output = c_path(&temporary.path().join("thread.lzh"));
                // SAFETY: Both strings are valid; the method is deliberately invalid.
                assert_eq!(
                    unsafe { unlhare_create(output.as_ptr(), source.as_ptr(), method) },
                    STATUS_INVALID_ARGUMENT
                );
                last_error()
            })
        })
        .map(|thread| thread.join().expect("thread must not panic"))
        .collect();

    assert!(errors[0].contains("41"));
    assert!(errors[1].contains("42"));
    assert!(last_error().contains("99"));
}
