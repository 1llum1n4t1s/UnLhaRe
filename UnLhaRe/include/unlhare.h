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
