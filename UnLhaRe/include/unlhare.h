#ifndef UNLHARE_H
#define UNLHARE_H

#include <stdint.h>

#if !defined(_WIN32) && !defined(__APPLE__)
#error "UnLhaRe supports Windows and macOS only"
#endif

#if UINTPTR_MAX != UINT64_MAX
#error "UnLhaRe requires a 64-bit target"
#endif

#if defined(_WIN32)
#if !defined(_M_X64) && !defined(_M_ARM64)
#error "UnLhaRe supports x64 and ARM64 only"
#endif
#elif !defined(__x86_64__) && !defined(__aarch64__) && !defined(__arm64__)
#error "UnLhaRe supports x64 and ARM64 only"
#endif

#if defined(__cplusplus)
static_assert(sizeof(void *) == 8, "UnLhaRe requires 64-bit pointers");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(void *) == 8, "UnLhaRe requires 64-bit pointers");
#endif

#if defined(_WIN32)
#if defined(UNLHARE_BUILD_DLL)
#define UNLHARE_API __declspec(dllexport)
#elif defined(UNLHARE_STATIC)
#define UNLHARE_API
#else
#define UNLHARE_API __declspec(dllimport)
#endif
#else
#define UNLHARE_API __attribute__((visibility("default")))
#endif

#define UNLHARE_ABI_VERSION UINT32_C(1)

#define UNLHARE_STATUS_OK INT32_C(0)
#define UNLHARE_STATUS_ERROR INT32_C(1)
#define UNLHARE_STATUS_BUFFER_TOO_SMALL INT32_C(2)
#define UNLHARE_STATUS_INVALID_ARGUMENT INT32_C(3)
#define UNLHARE_STATUS_PANIC INT32_C(4)
#define UNLHARE_STATUS_CANCELLED INT32_C(5)
#define UNLHARE_API_LEVEL UINT32_C(3)

#define UNLHARE_METHOD_STORED INT32_C(0)
#define UNLHARE_METHOD_LH5 INT32_C(5)
#define UNLHARE_METHOD_LH6 INT32_C(6)
#define UNLHARE_METHOD_LH7 INT32_C(7)

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Pointer contract:
 * - Every input string is a readable, NUL-terminated UTF-8 string.
 * - `required` is a non-NULL writable pointer. It receives a byte count that
 *   includes the trailing NUL.
 * - A non-NULL `output` points to at least `capacity` writable bytes.
 * - Pointer regions remain valid for the call and do not overlap.
 * Violating this contract is undefined behavior. Passing NULL with zero
 * capacity is the supported size query and returns BUFFER_TOO_SMALL.
 */

UNLHARE_API uint32_t unlhare_abi_version(void);

/* API level 2: JSON requests, configurable limits, selection and cancellation.
 * Progress callback runs synchronously on the caller thread; 0 continues,
 * nonzero cancels. Neither callback nor user is retained after return.
 * phase: 1 prepare, 2 compression, 3 extraction/verification, 4 finalize.
 * total=0 means indeterminate. Callbacks must not throw across the C boundary.
 */
typedef int32_t (*unlhare_progress_callback)(void *user, uint32_t phase,
                                           uint64_t completed, uint64_t total);
UNLHARE_API uint32_t unlhare_api_level(void);
UNLHARE_API int32_t unlhare_run_json(const char *request_utf8,
                                    unlhare_progress_callback callback,
                                    void *user);
UNLHARE_API int32_t unlhare_list_json_ex(const char *request_utf8,
                                        char *output, uint64_t capacity,
                                        uint64_t *required);

/* API level 3 additions. Existing ABI 1 functions retain their signatures.
 * JSON result callback is required and runs once on success, never on failure.
 * JSON is UTF-8, is not NUL-terminated, and is valid only during the callback.
 * The receiver must copy the bytes before returning and must not throw.
 * List uses the same request as list_json_ex but scans the archive once.
 * create_json_report uses the "create" request and skips source I/O failures;
 * output errors, invalid paths, limits and cancellation still abort the archive.
 * Its result is {"entries":[{"name":"...","status":"written"|"skipped",
 *                            "error":null|"..."}]} in input order.
 * The create result is delivered AFTER publication and cannot cancel it.
 * run_json extract additionally accepts "preserve_timestamps":true to restore
 * regular-file modification times. Directory times are unchanged.
 * List entries include optional modified_unix_seconds. DOS times are interpreted
 * in the host local time zone; invalid/ambiguous timestamps are null.
 */
typedef void (*unlhare_json_callback)(void *user, const char *json, uint64_t length);
UNLHARE_API int32_t unlhare_list_json_with_progress(const char *request_utf8,
                                                   unlhare_progress_callback callback,
                                                   unlhare_json_callback result,
                                                   void *user);
UNLHARE_API int32_t unlhare_create_json_report(const char *request_utf8,
                                              unlhare_progress_callback callback,
                                              unlhare_json_callback result,
                                              void *user);

UNLHARE_API int32_t unlhare_list_json(const char *archive_utf8,
                                      char *output,
                                      uint64_t capacity,
                                      uint64_t *required);

UNLHARE_API int32_t unlhare_verify(const char *archive_utf8);

UNLHARE_API int32_t unlhare_extract(const char *archive_utf8,
                                    const char *destination_utf8);

UNLHARE_API int32_t unlhare_create(const char *output_utf8,
                                   const char *source_directory_utf8,
                                   int32_t method);

/* This query never clears or replaces the calling thread's saved error. */
UNLHARE_API int32_t unlhare_last_error(char *output,
                                       uint64_t capacity,
                                       uint64_t *required);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UNLHARE_H */
