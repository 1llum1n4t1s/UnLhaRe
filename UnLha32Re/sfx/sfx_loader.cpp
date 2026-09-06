#include <windows.h>
#include <shellapi.h>
#include <strsafe.h>

#include "UnLhaReSfxFormat.h"

#include <cstdint>
#include <cstring>
#include <cwchar>

using UnlhaWProc = int (WINAPI*)(HWND, LPCWSTR, LPWSTR, DWORD);

static bool SeekFile(HANDLE file, const ULONGLONG offset) {
    LARGE_INTEGER position{};
    position.QuadPart = static_cast<LONGLONG>(offset);
    return SetFilePointerEx(file, position, nullptr, FILE_BEGIN) != FALSE;
}

static bool ReadExactly(HANDLE file, void* buffer, const DWORD size) {
    BYTE* cursor = static_cast<BYTE*>(buffer);
    DWORD remaining = size;
    while (remaining > 0) {
        DWORD amount = 0;
        if (!ReadFile(file, cursor, remaining, &amount, nullptr) || amount == 0) return false;
        cursor += amount;
        remaining -= amount;
    }
    return true;
}

static bool CopyRange(HANDLE source, HANDLE destination, ULONGLONG offset,
                      ULONGLONG size) {
    if (!SeekFile(source, offset)) return false;
    BYTE buffer[64 * 1024];
    while (size > 0) {
        const DWORD requested = static_cast<DWORD>(
            size < sizeof(buffer) ? size : sizeof(buffer));
        DWORD read = 0;
        if (!ReadFile(source, buffer, requested, &read, nullptr) || read == 0) return false;
        DWORD written_total = 0;
        while (written_total < read) {
            DWORD written = 0;
            if (!WriteFile(destination, buffer + written_total, read - written_total,
                           &written, nullptr) || written == 0) {
                return false;
            }
            written_total += written;
        }
        size -= read;
    }
    return true;
}

static void ShowFailure(const wchar_t* detail) {
    MessageBoxW(nullptr, detail && *detail ? detail : L"自己解凍に失敗しました。",
                L"UnLhaRe SFX", MB_OK | MB_ICONERROR);
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    wchar_t executable[MAX_PATH * 4]{};
    const DWORD executable_length = GetModuleFileNameW(
        nullptr, executable, static_cast<DWORD>(_countof(executable)));
    if (executable_length == 0 || executable_length >= _countof(executable)) {
        ShowFailure(L"自己解凍ファイル名を取得できません。");
        return 1;
    }

    HANDLE source = CreateFileW(executable, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (source == INVALID_HANDLE_VALUE) {
        ShowFailure(L"自己解凍ファイルを開けません。");
        return 1;
    }
    LARGE_INTEGER file_size{};
    UnLhaReSfxFooter footer{};
    bool valid = GetFileSizeEx(source, &file_size) != FALSE &&
                 file_size.QuadPart >= static_cast<LONGLONG>(sizeof(footer));
    if (valid) {
        valid = SeekFile(source, static_cast<ULONGLONG>(file_size.QuadPart) - sizeof(footer)) &&
                ReadExactly(source, &footer, sizeof(footer)) &&
                std::memcmp(footer.magic, kUnLhaReSfxFooterMagic,
                            sizeof(kUnLhaReSfxFooterMagic)) == 0 &&
                footer.version == kUnLhaReSfxFooterVersion &&
                footer.archiveOffset < footer.dllOffset &&
                footer.archiveSize <= footer.dllOffset - footer.archiveOffset &&
                footer.dllOffset <=
                    static_cast<ULONGLONG>(file_size.QuadPart) - sizeof(footer) &&
                footer.dllSize <= static_cast<ULONGLONG>(file_size.QuadPart) -
                                      sizeof(footer) - footer.dllOffset &&
                footer.dllOffset + footer.dllSize <=
                    static_cast<ULONGLONG>(file_size.QuadPart) - sizeof(footer) &&
                footer.dllSize <= MAXDWORD;
    }
    if (!valid) {
        CloseHandle(source);
        ShowFailure(L"自己解凍データが壊れています。");
        return 1;
    }

    wchar_t temporary_directory[MAX_PATH * 4]{};
    wchar_t temporary_dll[MAX_PATH * 4]{};
    if (!GetTempPathW(static_cast<DWORD>(_countof(temporary_directory)),
                      temporary_directory) ||
        !GetTempFileNameW(temporary_directory, L"ULR", 0, temporary_dll)) {
        CloseHandle(source);
        ShowFailure(L"一時ファイルを作成できません。");
        return 1;
    }
    HANDLE dll_file = CreateFileW(temporary_dll, GENERIC_WRITE, 0, nullptr,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (dll_file == INVALID_HANDLE_VALUE ||
        !CopyRange(source, dll_file, footer.dllOffset, footer.dllSize)) {
        if (dll_file != INVALID_HANDLE_VALUE) CloseHandle(dll_file);
        CloseHandle(source);
        DeleteFileW(temporary_dll);
        ShowFailure(L"展開エンジンを準備できません。");
        return 1;
    }
    CloseHandle(dll_file);
    CloseHandle(source);

    HMODULE library = LoadLibraryW(temporary_dll);
    const auto unlha = library
        ? reinterpret_cast<UnlhaWProc>(GetProcAddress(library, "UnlhaW")) : nullptr;
    if (!unlha) {
        if (library) FreeLibrary(library);
        DeleteFileW(temporary_dll);
        ShowFailure(L"展開エンジンを読み込めません。");
        return 1;
    }

    wchar_t destination[MAX_PATH * 4]{};
    int argument_count = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
    if (arguments && argument_count >= 2 && arguments[1] && *arguments[1]) {
        const DWORD length = GetFullPathNameW(
            arguments[1], static_cast<DWORD>(_countof(destination)), destination, nullptr);
        if (length == 0 || length >= _countof(destination)) destination[0] = L'\0';
    }
    if (arguments) LocalFree(arguments);
    if (!*destination) {
        StringCchCopyW(destination, _countof(destination), executable);
        wchar_t* separator = wcsrchr(destination, L'\\');
        if (!separator) separator = wcsrchr(destination, L'/');
        if (separator) *separator = L'\0';
    }
    const size_t destination_length = wcslen(destination);
    if (destination_length > 0 && destination_length + 1 < _countof(destination) &&
        destination[destination_length - 1] != L'\\' &&
        destination[destination_length - 1] != L'/') {
        destination[destination_length] = L'\\';
        destination[destination_length + 1] = L'\0';
    }

    wchar_t command[32768]{};
    wchar_t output[4096]{};
    HRESULT formatted = StringCchPrintfW(
        command, _countof(command), L"x -n1 -y \"%s\" \"%s\"", executable,
        destination);
    const int result = SUCCEEDED(formatted)
        ? unlha(nullptr, command, output, static_cast<DWORD>(_countof(output))) : 87;
    FreeLibrary(library);
    DeleteFileW(temporary_dll);
    if (result != 0) {
        wchar_t message[4608]{};
        if (*output) {
            StringCchPrintfW(message, _countof(message),
                             L"自己解凍に失敗しました (エラー %d)。\r\n%s", result,
                             output);
        } else {
            StringCchPrintfW(message, _countof(message),
                             L"自己解凍に失敗しました (エラー %d)。", result);
        }
        ShowFailure(message);
    }
    return result == 0 ? 0 : 1;
}
