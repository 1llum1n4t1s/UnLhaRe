/*
 * UnLha64x の msvc/UnLha64/unlha64.cpp を出発点とする派生実装。
 * 変更内容と再配布条件は README.md / THIRD_PARTY_NOTICES.md を参照。
 */
#include <windows.h>
#include <commdlg.h>
#include "UNLHA32.H"
#include "UNLHA64EX.H"
#include "UnLhaReSfxFormat.h"

#pragma comment(lib, "version.lib")
#pragma comment(lib, "comdlg32.lib")
#include <stdio.h>
#include <stdarg.h>



// DLLのモジュールハンドルを保持するグローバル変数
static HMODULE g_hModule = NULL;


extern "C" {
#include "lha.h"
#include "prototypes.h"
}

#include <shellapi.h>
#include <shlwapi.h>
#include <ctype.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <setjmp.h>
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <crtdbg.h>

#pragma comment(lib, "shlwapi.lib")

// CRTの無効パラメータハンドラ（アサーションダイアログを抑制する）
static void lha_invalid_parameter_handler(
    const wchar_t*, const wchar_t*, const wchar_t*, unsigned int, uintptr_t) {
    // 何もしない - アサーションダイアログを抑制する
}

// DLLロード時にstdout/stderrをNULにリダイレクトする。
// GUI(WPF)アプリではstdout/stderrに有効なハンドルがないため、
// CRTの終了時フラッシュでアサーション失敗(Debug Assertion Failed)が発生する。
// NULデバイスに紐づけることで安全にフラッシュできるようにする。
BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID) {
    if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
        g_hModule = hModule; // DLLのモジュールハンドルを保存
        // コマンド実行前の書庫走査でも使うため、CRC 表は DLL 読み込み時に確定する。
        make_crctable();
        // CRTの無効パラメータハンドラを設定してアサーションを抑制
        _set_invalid_parameter_handler(lha_invalid_parameter_handler);
#ifdef _DEBUG
        // Debugビルドでのアサーションダイアログを無効化
        _CrtSetReportMode(_CRT_ASSERT, 0);
#endif

        // 標準出力・標準エラーが有効かチェックする
        // 有効なコンソール出力がない（WPF等のGUIアプリ）場合のみ、NULにリダイレクトする
        HANDLE hStdOut = GetStdHandle(STD_OUTPUT_HANDLE);
        if (hStdOut == NULL || hStdOut == INVALID_HANDLE_VALUE || GetFileType(hStdOut) == FILE_TYPE_UNKNOWN) {
            FILE* fp = nullptr;
            freopen_s(&fp, "NUL", "w", stdout);
            fp = nullptr;
            freopen_s(&fp, "NUL", "w", stderr);
        }
    }
    return TRUE;
}

// UNLHA32.DLL の既定値。設定 API はプロセス内状態だけを変更する。
static std::atomic<UINT> g_code_page(CP_THREAD_ACP);
static std::atomic<BOOL> g_unicode_mode(FALSE);
// OpenArchive の処理開始後は、失敗しても DLL を解放するまで処理中状態が残る。
static std::atomic<BOOL> g_archive_session_active(FALSE);
static thread_local bool g_wide_command_input = false;
static thread_local bool g_wide_command_utf8_input = false;
struct WideCommandUtf8InputScope final {
    bool previous = g_wide_command_utf8_input;
    ~WideCommandUtf8InputScope() { g_wide_command_utf8_input = previous; }
};
static thread_local bool g_memory_extracting = false;
class MemoryProgressDialog;
static thread_local MemoryProgressDialog* g_memory_progress_dialog = nullptr;
static thread_local bool g_command_progress_enabled = true;
static thread_local bool g_rewrite_progress_member_transformed = false;
static thread_local int g_command_progress_cancel_state = -1;
static thread_local bool g_command_compression_copy_progress = false;
static thread_local FILETIME g_command_started_at{};

struct CommandProgressMode final {
    bool previous;
    explicit CommandProgressMode(bool enabled) : previous(g_command_progress_enabled) {
        g_command_progress_enabled = enabled;
    }
    ~CommandProgressMode() { g_command_progress_enabled = previous; }
};

static UINT ActiveCodePage() {
    return g_unicode_mode.load() || g_wide_command_utf8_input ? CP_UTF8 : CP_THREAD_ACP;
}

static UINT CallbackCodePage() {
    return g_unicode_mode.load() ? CP_UTF8 : CP_THREAD_ACP;
}

// 文字列変換ユーティリティ
static std::string WideStringToMultiByte(const std::wstring& wstr, const UINT code_page,
                                         bool* pUsedDefaultChar = nullptr) {
    if (wstr.empty()) {
        if (pUsedDefaultChar) *pUsedDefaultChar = false;
        return std::string();
    }
    const bool unicode_code_page = code_page == CP_UTF8 || code_page == CP_UTF7;
    const DWORD flags = unicode_code_page ? 0 : WC_NO_BEST_FIT_CHARS;
    int size_needed = WideCharToMultiByte(code_page, flags, &wstr[0], (int)wstr.size(), NULL, 0, NULL, NULL);
    if (size_needed <= 0) {
        if (pUsedDefaultChar) *pUsedDefaultChar = true;
        return std::string();
    }
    std::string strTo(size_needed, 0);
    BOOL usedDefaultChar = FALSE;
    char defaultChar = '_';
    LPCSTR default_char = unicode_code_page ? NULL : &defaultChar;
    LPBOOL used_default = unicode_code_page ? NULL : &usedDefaultChar;
    WideCharToMultiByte(code_page, flags, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, default_char, used_default);
    if (pUsedDefaultChar) *pUsedDefaultChar = (usedDefaultChar == TRUE);
    return strTo;
}

static std::wstring MultiByteStringToWide(const std::string& str, const UINT code_page) {
    if (str.empty()) return std::wstring();
    int size_needed = MultiByteToWideChar(code_page, 0, &str[0], (int)str.size(), NULL, 0);
    if (size_needed <= 0) return std::wstring();
    std::wstring wstrTo(size_needed, 0);
    MultiByteToWideChar(code_page, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
    return wstrTo;
}

static std::string WStringToString(const std::wstring& wstr, bool* pUsedDefaultChar = nullptr) {
    return WideStringToMultiByte(wstr, ActiveCodePage(), pUsedDefaultChar);
}

static std::wstring StringToWString(const std::string& str) {
    return MultiByteStringToWide(str, ActiveCodePage());
}

// 展開先を UTF-8 で C 本体へ渡す。公開 API の文字コードは変更しない。
// ディレクトリの日時復元は全メンバーの展開後なので、親パスもコマンド終了まで保持する。
static thread_local std::unordered_set<std::string> g_unicode_extraction_paths;

struct CommandExtractionPaths final {
    CommandExtractionPaths() { g_unicode_extraction_paths.clear(); }
    ~CommandExtractionPaths() { g_unicode_extraction_paths.clear(); }
};

static std::string RegisterUnicodeExtractionPath(std::wstring path) {
    std::replace(path.begin(), path.end(), L'\\', L'/');
    const std::string encoded = WideStringToMultiByte(path, CP_UTF8);
    const auto non_ascii = std::find_if(encoded.begin(), encoded.end(),
                                       [](unsigned char value) { return value >= 0x80; });
    if (non_ascii != encoded.end() && !g_unicode_mode.load()) {
        const size_t first_non_ascii = static_cast<size_t>(non_ascii - encoded.begin());
        size_t length = encoded.size();
        while (length > first_non_ascii) {
            g_unicode_extraction_paths.insert(encoded.substr(0, length));
            const size_t separator = encoded.rfind('/', length - 1);
            if (separator == std::string::npos) break;
            length = separator;
        }
    }
    return encoded;
}

static bool UsesUnicodeFilePath(const char* path) {
    if (g_unicode_mode.load() || g_wide_command_utf8_input) return true;
    if (!path || g_unicode_extraction_paths.empty()) return false;
    std::string key(path);
    std::replace(key.begin(), key.end(), '\\', '/');
    return g_unicode_extraction_paths.find(key) != g_unicode_extraction_paths.end();
}

static std::wstring FilePathToWide(const char* path) {
    return MultiByteStringToWide(path ? path : "", UsesUnicodeFilePath(path) ? CP_UTF8 : ActiveCodePage());
}

extern "C" FILE* Lha_OpenFile(const char* path, const char* mode) {
    if (!UsesUnicodeFilePath(path)) return fopen(path, mode);
    if (!path || !mode) { errno = EINVAL; return nullptr; }
    FILE* file = nullptr;
    _wfopen_s(&file, FilePathToWide(path).c_str(), MultiByteStringToWide(mode, CP_ACP).c_str());
    return file;
}

extern "C" int Lha_StatFile(const char* path, struct stat* status) {
    if (!UsesUnicodeFilePath(path)) return stat(path, status);
    if (!path || !status) { errno = EINVAL; return -1; }
    struct _stat64 wide{};
    if (_wstat64(FilePathToWide(path).c_str(), &wide) != 0) return -1;
    status->st_dev = wide.st_dev;
    status->st_ino = wide.st_ino;
    status->st_mode = wide.st_mode;
    status->st_nlink = wide.st_nlink;
    status->st_uid = wide.st_uid;
    status->st_gid = wide.st_gid;
    status->st_rdev = wide.st_rdev;
    status->st_size = static_cast<decltype(status->st_size)>(wide.st_size);
    status->st_atime = wide.st_atime;
    status->st_mtime = wide.st_mtime;
    status->st_ctime = wide.st_ctime;
    return 0;
}

extern "C" int Lha_RenameFile(const char* source, const char* destination) {
    if (!UsesUnicodeFilePath(source) && !UsesUnicodeFilePath(destination))
        return rename(source, destination);
    return _wrename(FilePathToWide(source).c_str(), FilePathToWide(destination).c_str());
}

extern "C" int Lha_UnlinkFile(const char* path) {
    return UsesUnicodeFilePath(path) ? _wunlink(FilePathToWide(path).c_str()) : _unlink(path);
}

extern "C" int Lha_MakeDirectory(const char* path) {
    return UsesUnicodeFilePath(path) ? _wmkdir(FilePathToWide(path).c_str()) : _mkdir(path);
}

extern "C" int Lha_ChangeFileMode(const char* path, int mode) {
    return UsesUnicodeFilePath(path) ? _wchmod(FilePathToWide(path).c_str(), mode) : _chmod(path, mode);
}

extern "C" int Lha_OpenDescriptor(const char* path, int flags, ...) {
    int mode = 0;
    if (flags & _O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, int);
        va_end(arguments);
    }
    return UsesUnicodeFilePath(path) ? _wopen(FilePathToWide(path).c_str(), flags, mode)
                                     : _open(path, flags, mode);
}

extern "C" int Lha_RemoveDirectory(const char* path) {
    return UsesUnicodeFilePath(path) ? _wrmdir(FilePathToWide(path).c_str()) : _rmdir(path);
}

extern "C" int Lha_SetFileTimes(const char* path, struct utimbuf* times) {
    if (!UsesUnicodeFilePath(path)) return utime(path, times);
    struct _utimbuf values{};
    if (times) {
        values.actime = times->actime;
        values.modtime = times->modtime;
    }
    return _wutime(FilePathToWide(path).c_str(), times ? &values : nullptr);
}

extern "C" unsigned int Lha_GetPathCodePage(void) { return ActiveCodePage(); }

extern "C" unsigned long Lha_GetFileAttributes(const char* path) {
    return UsesUnicodeFilePath(path) ? GetFileAttributesW(FilePathToWide(path).c_str()) : GetFileAttributesA(path);
}

extern "C" void* Lha_OpenMetadataFile(const char* path, unsigned long access) {
    const DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    return UsesUnicodeFilePath(path)
        ? CreateFileW(FilePathToWide(path).c_str(), access, share, nullptr, OPEN_EXISTING,
                      FILE_FLAG_BACKUP_SEMANTICS, nullptr)
        : CreateFileA(path, access, share, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
}

// UTF-8 の継続バイトを CP932 の2バイト文字として飛ばさない。
static bool IsInputLeadByte(const BYTE value) {
    return !g_unicode_mode.load() && IsDBCSLeadByteEx(ActiveCodePage(), value);
}

static UINT ConfiguredArchiveCodePage() {
    const UINT code_page = g_code_page.load();
    // 元 DLL の日本語版既定値 CP_THREAD_ACP は、書庫名の読み取りでは CP932 として働く。
    return code_page == CP_THREAD_ACP ? 932 : code_page;
}

static std::wstring ArchiveStringToWString(const std::string& str, const UINT code_page) {
    return MultiByteStringToWide(str, code_page);
}

static std::string WideStringToUtf8(const std::wstring& str) {
    return WideStringToMultiByte(str, CP_UTF8);
}

static UINT HeaderCodePage(const LzHeader& header, const UINT fallback) {
    return header.has_code_page && IsValidCodePage(header.code_page) ? header.code_page : fallback;
}

static std::wstring HeaderUnicodePart(const unsigned short* value, const size_t length,
                                      const bool directory) {
    std::wstring result;
    result.reserve(length);
    for (size_t index = 0; index < length; ++index) {
        const unsigned short unit = value[index];
        result.push_back(directory && unit == 0xffff ? L'/' : static_cast<wchar_t>(unit));
    }
    return result;
}

static std::wstring HeaderNameToWString(const LzHeader& header, const UINT fallback_code_page) {
    const UINT name_code_page = header.has_input_name_code_page
        ? header.input_name_code_page : HeaderCodePage(header, fallback_code_page);
    const std::wstring raw = ArchiveStringToWString(header.name, name_code_page);
    if (!header.has_unicode_name && !header.has_unicode_directory) return raw;

    const size_t separator = raw.find_last_of(L"/\\");
    const std::wstring raw_directory = separator == std::wstring::npos ? std::wstring() : raw.substr(0, separator + 1);
    const std::wstring raw_name = separator == std::wstring::npos ? raw : raw.substr(separator + 1);
    const std::wstring directory = header.has_unicode_directory
        ? HeaderUnicodePart(header.unicode_directory, header.unicode_directory_length, true)
        : raw_directory;
    const std::wstring name = header.has_unicode_name
        ? HeaderUnicodePart(header.unicode_name, header.unicode_name_length, false)
        : raw_name;
    return directory + name;
}

static void SetHeaderNameFromWide(LzHeader& header, std::wstring value,
                                  const bool compression_utf8_input = false,
                                  const bool compression_ansi_input = false,
                                  bool* thread_ansi_directory_used_default = nullptr,
                                  bool* thread_ansi_name_used_default = nullptr) {
    if (thread_ansi_directory_used_default) *thread_ansi_directory_used_default = false;
    if (thread_ansi_name_used_default) *thread_ansi_name_used_default = false;
    std::replace(value.begin(), value.end(), L'\\', L'/');
    const size_t separator = value.find_last_of(L'/');
    const std::wstring directory = separator == std::wstring::npos
        ? std::wstring() : value.substr(0, separator + 1);
    const std::wstring name = separator == std::wstring::npos
        ? value : value.substr(separator + 1);
    const UINT code_page = header.has_input_name_code_page
        ? header.input_name_code_page : HeaderCodePage(header, ConfiguredArchiveCodePage());
    bool directory_used_default = false;
    bool name_used_default = false;
    const std::string directory_a = WideStringToMultiByte(
        directory, code_page, &directory_used_default);
    const std::string name_a = WideStringToMultiByte(name, code_page, &name_used_default);
    const std::string fallback = directory_a + name_a;
    strncpy_s(header.name, fallback.c_str(), _TRUNCATE);

    if (compression_utf8_input) {
        // UTF-8 圧縮入力の Unicode 拡張は保存 CP ではなく、スレッドの ANSI 表現可否で決まる。
        const UINT stored_code_page = HeaderCodePage(header, ConfiguredArchiveCodePage());
        if (stored_code_page == CP_UTF8 || stored_code_page == CP_UTF7) {
            directory_used_default = name_used_default = false;
        } else {
            WideStringToMultiByte(directory, CP_THREAD_ACP, &directory_used_default);
            WideStringToMultiByte(name, CP_THREAD_ACP, &name_used_default);
            // Unicode ファイル名を持つパスは、ANSI で表せる親ディレクトリも拡張へ保持する。
            directory_used_default = directory_used_default || (name_used_default && !directory.empty());
        }
    } else if (compression_ansi_input) {
        const UINT stored_code_page = HeaderCodePage(header, ConfiguredArchiveCodePage());
        // ANSI 圧縮入力はシステム ACP のファイル名を格納するが、level-2 の Unicode 拡張は
        // 呼び出しスレッドの ANSI 表現可否にも従う。UTF-8 保存名は拡張を加えない。
        if (stored_code_page != CP_UTF8 && stored_code_page != CP_UTF7) {
            bool thread_directory_default = false;
            bool thread_name_default = false;
            WideStringToMultiByte(directory, CP_THREAD_ACP, &thread_directory_default);
            WideStringToMultiByte(name, CP_THREAD_ACP, &thread_name_default);
            if (thread_ansi_directory_used_default)
                *thread_ansi_directory_used_default = thread_directory_default;
            if (thread_ansi_name_used_default) *thread_ansi_name_used_default = thread_name_default;
            directory_used_default = directory_used_default || thread_directory_default;
            name_used_default = name_used_default || thread_name_default;
        }
    }

    header.unicode_name_length = 0;
    header.has_unicode_name = FALSE;
    header.unicode_directory_length = 0;
    header.has_unicode_directory = FALSE;
    if (header.header_level != 2 && !(compression_utf8_input && header.header_level == 1)) return;

    header.extend_type = EXTEND_MSDOS;
    if (!header.has_input_name_code_page) header.code_page = code_page;
    header.has_code_page = TRUE;
    if (name_used_default && header.header_level == 2) {
        header.unicode_name_length = (std::min)(name.size(),
            static_cast<size_t>(FILENAME_LENGTH - 1));
        for (size_t index = 0; index < header.unicode_name_length; ++index) {
            header.unicode_name[index] = static_cast<unsigned short>(name[index]);
        }
        header.unicode_name[header.unicode_name_length] = 0;
        header.has_unicode_name = TRUE;
    }
    if (directory_used_default) {
        header.unicode_directory_length = (std::min)(directory.size(),
            static_cast<size_t>(FILENAME_LENGTH - 1));
        for (size_t index = 0; index < header.unicode_directory_length; ++index) {
            const wchar_t unit = directory[index];
            header.unicode_directory[index] = unit == L'/' || unit == L'\\'
                ? 0xffff : static_cast<unsigned short>(unit);
        }
        header.unicode_directory[header.unicode_directory_length] = 0;
        header.has_unicode_directory = TRUE;
    }
}

static std::string HeaderNameToString(const LzHeader& header, const UINT fallback_code_page) {
    return WStringToString(HeaderNameToWString(header, fallback_code_page));
}

extern "C" void Lha_EncodeHeaderName(LzHeader* header) {
    if (!header) return;
    // 圧縮コアの ANSI ファイル列挙はスレッドではなくシステム ACP の生バイトを返す。
    header->input_name_code_page = g_unicode_mode.load() || g_wide_command_utf8_input
        ? CP_UTF8 : CP_ACP;
    header->has_input_name_code_page = TRUE;
}

extern "C" int Lha_EncodeStoredHeaderDirectory(const LzHeader* header, char* directory,
                                              const size_t capacity) {
    if (!header || !header->has_input_name_code_page ||
        (header->header_level != 1 && header->header_level != 2)) return FALSE;
    std::wstring name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    std::replace(name.begin(), name.end(), L'\\', L'/');
    const size_t separator = name.find_last_of(L'/');
    name = separator == std::wstring::npos ? std::wstring() : name.substr(0, separator + 1);
    const UINT code_page = HeaderCodePage(*header, ConfiguredArchiveCodePage());
    // Level-1 のファイル名とは独立して、ディレクトリ拡張は保存 CP で符号化する。
    std::string encoded = WideStringToMultiByte(name, code_page);
    // 原版 RVA 0x153BD/0x10B27 は保存 CP ではなく CharNextA のシステム ANSI CP で走査する。
    for (size_t index = 0; index < encoded.size();) {
        if (encoded[index] == '/' || encoded[index] == '\\') encoded[index] = static_cast<char>(0xff);
        index = static_cast<size_t>(CharNextA(encoded.c_str() + index) - encoded.c_str());
    }
    strncpy_s(directory, capacity, encoded.c_str(), _TRUNCATE);
    return TRUE;
}

extern "C" void Lha_EncodeStoredHeaderName(LzHeader* header) {
    if (!header || !header->has_input_name_code_page) return;
    const std::wstring name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    const bool utf8_input = header->input_name_code_page == CP_UTF8;
    const bool needs_unicode_name = utf8_input || header->has_unicode_name != FALSE;
    const bool needs_unicode_directory = utf8_input || header->has_unicode_directory != FALSE;
    if (header->header_level < 2) {
        // Level-0/1 は保存コードページ設定を使わず、呼び出しスレッドの ANSI 名を格納する。
        header->input_name_code_page = CP_THREAD_ACP;
        SetHeaderNameFromWide(*header, name, utf8_input);
        header->has_input_name_code_page = FALSE;
        return;
    }
    header->has_input_name_code_page = FALSE;
    bool thread_ansi_directory_default = false;
    bool thread_ansi_name_default = false;
    SetHeaderNameFromWide(*header, name, utf8_input, !utf8_input,
                          &thread_ansi_directory_default, &thread_ansi_name_default);
    // 通知・進捗の元ヘッダーは保持し、保存用コピーだけを変換する。
    if (!needs_unicode_name && !thread_ansi_name_default) {
        header->has_unicode_name = FALSE;
        header->unicode_name_length = 0;
    }
    if (!needs_unicode_directory && !thread_ansi_directory_default) {
        header->has_unicode_directory = FALSE;
        header->unicode_directory_length = 0;
    }
}

extern "C" int Lha_GetHeaderPath(const LzHeader* header, char* path, size_t capacity) {
    if (!header || !path) return FALSE;
    // 実際に使う Unicode 名を先に渡し、C 本体の階層除去・安全検査にも同じ名前を使わせる。
    std::wstring member = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    std::replace(member.begin(), member.end(), L'\\', L'/');
    const std::string value = WideStringToUtf8(member);
    if (value.size() >= capacity) return FALSE;
    strcpy_s(path, capacity, value.c_str());
    return TRUE;
}

extern "C" char* Lha_FullPath(char* output, const char* path, size_t capacity) {
    if (!UsesUnicodeFilePath(path)) return _fullpath(output, path, capacity);
    wchar_t wide[FILENAME_LENGTH * 4]{};
    const DWORD length = GetFullPathNameW(FilePathToWide(path).c_str(), _countof(wide), wide, nullptr);
    if (length == 0 || length >= _countof(wide)) return nullptr;
    const std::string converted = WideStringToUtf8(wide);
    if (!output || converted.size() >= capacity) return nullptr;
    strcpy_s(output, capacity, converted.c_str());
    return output;
}

extern "C" FILE* Lha_TemporaryFile(void) {
    if (!g_unicode_mode.load()) return tmpfile();
    wchar_t directory[MAX_PATH]{};
    wchar_t path[MAX_PATH]{};
    const DWORD length = GetTempPathW(_countof(directory), directory);
    if (!length || length >= _countof(directory) ||
        !GetTempFileNameW(directory, L"ULT", 0, path)) return nullptr;
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        DeleteFileW(path);
        SetLastError(error);
        return nullptr;
    }
    // CRT にハンドルの所有権を移し、fclose で一時ファイルも削除する。
    const int descriptor = _open_osfhandle(reinterpret_cast<intptr_t>(file), _O_BINARY | _O_RDWR);
    if (descriptor < 0) { CloseHandle(file); return nullptr; }
    FILE* stream = _fdopen(descriptor, "w+b");
    if (!stream) _close(descriptor);
    return stream;
}

static char LowerCharacter(const char value) {
    return static_cast<char>(tolower(static_cast<unsigned char>(value)));
}

static bool ReadResponseArgumentsW(const std::wstring& path,
                                   std::vector<std::wstring>& arguments,
                                   const bool prefer_wide) {
    FILE* fp = nullptr;
    if (_wfopen_s(&fp, path.c_str(), L"rb") != 0 || !fp) {
        return false;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return false;
    }
    long size = ftell(fp);
    if (size < 0 || fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return false;
    }
    std::vector<unsigned char> buffer(static_cast<size_t>(size));
    const size_t read_bytes = size == 0 ? 0 : fread(buffer.data(), 1, buffer.size(), fp);
    const bool success = !ferror(fp) && read_bytes == buffer.size();
    fclose(fp);
    if (!success) return false;
    arguments.clear();
    if (buffer.empty()) return true;

    bool wide = prefer_wide;
    UINT code_page = ActiveCodePage();
    size_t offset = 0;
    if (size >= 2 && buffer[0] == 0xff && buffer[1] == 0xfe) {
        wide = true;
        offset = 2;
    } else if (size >= 2 && buffer[0] == 0xfe && buffer[1] == 0xff) {
        // 3.00 のレスポンス読込は BE BOM の内容を空として扱う（注釈読込とは異なる）。
        return true;
    } else if (size >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf) {
        wide = false;
        code_page = CP_UTF8;
        offset = 3;
    }
    const int eof = wide ? 0xffff : -1;
    const auto read_character = [&]() -> int {
        if (offset + (wide ? 1U : 0U) >= buffer.size()) return eof;
        const int low = buffer[offset++];
        return wide ? low | (buffer[offset++] << 8) : low;
    };
    for (;;) {
        int character;
        do {
            character = read_character();
            if (character == eof) return true;
        } while (character <= 0x20);
        std::wstring units;
        bool quoted = false;
        const size_t limit = wide ? 2049U : 2048U;
        for (size_t count = 0; count < limit; ++count) {
            if (character == '"') quoted = !quoted;
            else units.push_back(static_cast<wchar_t>(character));
            character = read_character();
            if (character < 0x20 || (!quoted && character == 0x20)) break;
            // UTF-16 では引数の途中の EOF も U+FFFF として上限まで格納される。
            // 引用符と、上限到達時に先読みして捨てる 1 文字も本家と同じ位置で数える。
        }
        if (wide) arguments.push_back(std::move(units));
        else {
            std::string bytes;
            for (const wchar_t unit : units) bytes.push_back(static_cast<char>(unit));
            const std::wstring decoded = MultiByteStringToWide(bytes, code_page);
            if (code_page == CP_UTF8 && !bytes.empty() && decoded.empty()) return true;
            arguments.push_back(decoded);
        }
    }
}

static bool ReadResponseArguments(const std::string& path, std::vector<std::string>& arguments) {
    std::vector<std::wstring> decoded;
    if (!ReadResponseArgumentsW(StringToWString(path), decoded, g_wide_command_input)) return false;
    arguments.clear();
    for (auto& token : decoded) {
        // 元 DLL の内部パスでは U+FFFF も区切り文字。ANSI 変換で '?' に失わせない。
        std::replace(token.begin(), token.end(), L'\xffff', L'/');
        arguments.push_back(WStringToString(token));
    }
    return true;
}

static std::vector<std::string> TokenizeCommandLine(const std::string& cmdLine) {
    std::vector<std::string> args;
    std::string current;
    bool inQuote = false;
    for (size_t i = 0; i <= cmdLine.length(); ++i) {
        char c = (i < cmdLine.length()) ? cmdLine[i] : '\0';
        if (c == '\"') {
            inQuote = !inQuote;
        } else if ((c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\0') && !inQuote) {
            if (!current.empty()) {
                args.push_back(current);
                current.clear();
            }
        } else {
            current += c;
        }
    }
    return args;
}

static std::vector<std::wstring> TokenizeCommandLineW(const std::wstring& cmdLine) {
    std::vector<std::wstring> args;
    std::wstring current;
    bool in_quote = false;
    for (size_t index = 0; index <= cmdLine.length(); ++index) {
        const wchar_t character = index < cmdLine.length() ? cmdLine[index] : L'\0';
        if (character == L'"') {
            in_quote = !in_quote;
        } else if ((character == L' ' || character == L'\t' ||
                    character == L'\r' || character == L'\n' ||
                    character == L'\0') && !in_quote) {
            if (!current.empty()) {
                args.push_back(current);
                current.clear();
            }
        } else {
            current += character;
        }
    }
    return args;
}


// グローバル状態
static bool g_running = false;
static int g_lha_exit_status = 0;
static int g_last_error_code = 0;
static DWORD g_last_system_error = ERROR_SUCCESS;
static DWORD g_last_packed_size = 0;
static bool IsDllRunning() {
    return g_running || g_archive_session_active.load();
}

static int RecordBusyError() {
    g_last_error_code = ERROR_ALREADY_RUNNING;
    g_last_system_error = ERROR_BUSY;
    return ERROR_ALREADY_RUNNING;
}
static BOOL g_background_mode = FALSE;
static BOOL g_cursor_mode = TRUE;
static WORD g_cursor_interval = 80;
static int g_priority = THREAD_PRIORITY_ERROR_RETURN;
static LANGID g_language = MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT);
static UNLHA_WND_ENUMMEMBPROC g_enum_members_proc = NULL;
static DWORD g_enum_struct_size = 0;
static DWORD g_owner_struct_size = 0;
enum class EnumTextMode { None, Ansi, Wide };
static EnumTextMode g_enum_text_mode = EnumTextMode::None;
// 登録中の数値領域はヘッダー読み取りと利用者の書き換えで更新され、ADD/FRESH が再利用する。
static UNLHA_ENUM_MEMBER_INFO64W g_enum_metadata{};
enum class OwnerProgressLayout {
    None,
    BasicA,
    BasicW,
    ExA,
    ExW,
    Ex32A,
    Ex32W,
    Ex64A,
    Ex64W
};
typedef BOOL (CALLBACK *LHA_ARCHIVERPROC)(HWND, UINT, UINT, LPVOID);
static HWND g_hwndOwner = NULL;
static HWND g_progressWindow = NULL;
static UINT g_uMsgArcExtract = 0;
static LHA_ARCHIVERPROC g_lpArcProc = NULL;
static BOOL g_bEnableTotalProgress = FALSE;
static OwnerProgressLayout g_owner_progress_layout = OwnerProgressLayout::None;
static UINT g_enum_command = 0;
static size_t g_enum_invoked_count = 0;
static size_t g_enum_selected_count = 0;
static std::vector<BOOL> g_enum_selection_results;
struct CommandEvent final {
    std::string action;
    std::string name;
    int value = 0;
    std::wstring wide_name;
    bool directory = false;
    bool non_msdos = false;
};
static std::vector<CommandEvent> g_command_events;
static CommandEvent g_command_read_member;
static std::vector<__int64> g_command_test_crc_errors;
static bool g_command_crc_stopped = false;
static std::wstring g_command_crc_failure_path;
static std::wstring g_command_disk_space_failure_path;
struct CommandExtractionFailure final {
    int code = 0;
    DWORD system_error = ERROR_SUCCESS;
    std::wstring path;
    const wchar_t* location = L"extractsub";
    bool include_system_error = false;
};
static CommandExtractionFailure g_command_extraction_failure;
// j の連結元を末尾判定で拒否した場合だけ、原版と同じ arccopy の出力を組み立てる。
static bool g_rewrite_foreign_source_rejected = false;
static std::wstring g_rewrite_foreign_source_path;
// 最後の連結元で、終端から基本ヘッダー 21 バイトを読めるかによる終了状態を保つ。
static DWORD g_rewrite_join_source_system_error = ERROR_SUCCESS;
enum class CommandReadFailure {
    None,
    CopyFile,
    FillBuffer
};
static CommandReadFailure g_command_read_failure = CommandReadFailure::None;
static bool g_print_output_completed = false;
static std::string g_print_output_log;
static std::string g_command_renamed_destination;
static std::string g_command_renamed_member;
static std::wstring g_command_renamed_member_w;
static std::string g_command_metadata_path;
static DWORD g_command_metadata_attributes = 0;
struct CommandUpdatePolicy final {
    char command = 'l';
    int comparison = 1;
    bool ignore_timestamp = false;
    bool existing_only = false;
    bool new_only = false;
    int overwrite_mode = 0;
    int protected_attributes = 0;
    bool suppress_errors = false;
    bool restore_attributes = false;
    bool assume_overwrite = false;
    bool assume_directory = false;
    bool suppress_new_name = true;
    bool check_disk_space = true;
    int stop_on_extract_error = 0;
    ULONGLONG reserved_disk_space = 0;
};
static CommandUpdatePolicy g_command_update_policy;
enum class CommandFileQuestion { Overwrite, ReadOnly, Directory };
struct CommandQuestionState final {
    bool overwrite_all = false;
    bool skip_existing = false;
    int protected_all = 0;
    int create_directory = 0;
    const wchar_t* cancelled_location = nullptr;
};
static CommandQuestionState g_command_question_state;
static constexpr int IDD_UNLHA_OVERWRITE = 204;
extern "C" INT_PTR CALLBACK OverWriteMsgDlgProc(HWND, UINT, WPARAM, LPARAM);
extern "C" INT_PTR CALLBACK OWReadOnlyMsgDlgProc(HWND, UINT, WPARAM, LPARAM);
extern "C" INT_PTR CALLBACK MakeDirMsgDlgProc(HWND, UINT, WPARAM, LPARAM);
struct CommandExistingMember final {
    FILETIME write_time;
    ULHA_INT64 size;
    size_t position;
};
struct CommandMemberNameLess final {
    bool operator()(const std::wstring& first, const std::wstring& second) const {
        return _wcsicmp(first.c_str(), second.c_str()) < 0;
    }
};
static std::map<std::wstring, CommandExistingMember, CommandMemberNameLess> g_command_existing_members;
static bool g_enum_additional_w_active = false;
static std::wstring g_enum_additional_w;
static bool g_progress_destination_w_active = false;
static std::wstring g_progress_destination_w;
struct ForcedHeaderName final {
    std::string placeholder;
    std::wstring member_name;
};
static std::vector<ForcedHeaderName> g_forced_header_names;
struct FreshenInput final {
    std::wstring callback_source;
    struct stat search_status{};
    bool has_search_status = false;
};
static std::map<std::wstring, FreshenInput, CommandMemberNameLess> g_freshen_callback_sources;
static std::pair<std::string, DWORD> g_compression_read_failure;
static std::pair<std::string, DWORD> g_compression_delete_failure;
static std::unordered_map<const char*, size_t> g_compression_source_order;
static std::set<std::wstring> g_archived_compression_inputs;
static bool g_compression_reject_shared_writers = false;
static bool g_compression_inputs_explicit = false;
static bool g_compression_inputs_flat = false;
static bool g_compression_store_directories = false;
static bool g_compression_deleted_file = false;
static DWORD g_compression_terminal_error = ERROR_NO_MORE_FILES;
static bool g_discard_compression_update = false;

struct CommandCompressionInputs final {
    size_t retained_names = g_forced_header_names.size();
    decltype(g_freshen_callback_sources) previous_freshen_sources;
    decltype(g_compression_read_failure) previous_read_failure;
    decltype(g_compression_delete_failure) previous_delete_failure;
    decltype(g_compression_source_order) previous_source_order;
    decltype(g_archived_compression_inputs) previous_archived_inputs;
    bool previous_reject_shared_writers = g_compression_reject_shared_writers;
    bool previous_explicit = g_compression_inputs_explicit;
    bool previous_flat = g_compression_inputs_flat;
    bool previous_store_directories = g_compression_store_directories;
    bool previous_deleted_file = g_compression_deleted_file;
    DWORD previous_terminal_error = g_compression_terminal_error;
    bool previous_discard = g_discard_compression_update;
    CommandCompressionInputs() {
        previous_freshen_sources.swap(g_freshen_callback_sources);
        previous_read_failure.swap(g_compression_read_failure);
        previous_delete_failure.swap(g_compression_delete_failure);
        previous_source_order.swap(g_compression_source_order);
        previous_archived_inputs.swap(g_archived_compression_inputs);
        g_compression_reject_shared_writers = false;
        g_compression_inputs_explicit = false;
        g_compression_inputs_flat = false;
        g_compression_store_directories = false;
        g_compression_deleted_file = false;
        g_compression_terminal_error = ERROR_NO_MORE_FILES;
        g_discard_compression_update = false;
    }
    ~CommandCompressionInputs() {
        g_forced_header_names.resize(retained_names);
        g_freshen_callback_sources.swap(previous_freshen_sources);
        g_compression_read_failure.swap(previous_read_failure);
        g_compression_delete_failure.swap(previous_delete_failure);
        g_compression_source_order.swap(previous_source_order);
        g_archived_compression_inputs.swap(previous_archived_inputs);
        g_compression_reject_shared_writers = previous_reject_shared_writers;
        g_compression_inputs_explicit = previous_explicit;
        g_compression_inputs_flat = previous_flat;
        g_compression_store_directories = previous_store_directories;
        g_compression_deleted_file = previous_deleted_file;
        g_compression_terminal_error = previous_terminal_error;
        g_discard_compression_update = previous_discard;
    }
};

extern "C" int Lha_HasExplicitCompressionInputs(void) { return g_compression_inputs_explicit; }
extern "C" int Lha_HasFlatCompressionInputs(void) { return g_compression_inputs_flat; }
extern "C" int Lha_StoresCompressionDirectories(void) { return g_compression_store_directories; }
extern "C" void Lha_RecordCompressionFileDeleted(void) { g_compression_deleted_file = true; }
extern "C" void Lha_RecordCompressionHeaderEnd(void) {
    Lha_RecordProgressHeaderEnd();
    g_compression_terminal_error = ERROR_HANDLE_EOF;
}
static std::wstring CompressionInputAbsolutePath(const char* name) {
    if (!name || !*name) return {};
    wchar_t absolute[FILENAME_LENGTH * 4]{};
    const DWORD length = GetFullPathNameW(FilePathToWide(name).c_str(),
        _countof(absolute), absolute, nullptr);
    if (!length || length >= _countof(absolute)) return {};
    std::wstring actual(absolute, length);
    size_t begin = 0;
    const size_t drive = actual.size() >= 3 && actual[1] == L':' ? 0 :
        actual.size() >= 7 && actual.rfind(L"\\\\?\\", 0) == 0 && actual[5] == L':' ? 4 : SIZE_MAX;
    if (drive != SIZE_MAX) {
        if (actual[drive] >= L'a' && actual[drive] <= L'z') actual[drive] -= L'a' - L'A';
        begin = drive + 3;
    } else if (actual.rfind(L"\\\\", 0) == 0) {
        const size_t server_begin = _wcsnicmp(actual.c_str(), L"\\\\?\\UNC\\", 8) == 0 ? 8 : 2;
        const size_t server_end = actual.find(L'\\', server_begin);
        const size_t share_end = server_end == std::wstring::npos ? server_end : actual.find(L'\\', server_end + 1);
        begin = share_end == std::wstring::npos ? actual.size() : share_end + 1;
    }
    // 一律の大小文字無視では別ファイルを混同する。各成分の実名で同じ入力の別表記だけをそろえる。
    // GetLongPathName は長い成分の照合を省くため、mkdir ログと同じ実名探索を使用する。
    while (begin < actual.size()) {
        const size_t separator = actual.find(L'\\', begin);
        size_t end = separator == std::wstring::npos ? actual.size() : separator;
        WIN32_FIND_DATAW found{};
        const HANDLE search = FindFirstFileW(actual.substr(0, end).c_str(), &found);
        if (search != INVALID_HANDLE_VALUE) {
            actual.replace(begin, end - begin, found.cFileName);
            end = begin + wcslen(found.cFileName);
            FindClose(search);
        }
        begin = end + 1;
    }
    return actual;
}

extern "C" int Lha_CanRemoveCompressionInput(const char* name, const int directory) {
    const DWORD previous_error = GetLastError();
    std::wstring path = CompressionInputAbsolutePath(name);
    bool allowed = false;
    if (!path.empty()) {
        if (directory) {
            if (path.back() != L'\\') path += L'\\';
            const auto child = g_archived_compression_inputs.lower_bound(path);
            allowed = child != g_archived_compression_inputs.end() &&
                child->compare(0, path.size(), path) == 0;
        } else {
            allowed = g_archived_compression_inputs.find(path) != g_archived_compression_inputs.end();
        }
    }
    SetLastError(previous_error);
    return allowed;
}

extern "C" void Lha_RecordCompressionCompletion(const LzHeader* header, const char* name) {
    Lha_RecordProgressCompressionResult(header);
    if (!header || memcmp(header->method, LZHDIRS_METHOD, METHOD_TYPE_STORAGE) == 0) return;
    if (g_command_update_policy.command == 'm') {
        const DWORD previous_error = GetLastError();
        std::wstring path = CompressionInputAbsolutePath(name);
        // 検索結果ではなく、コールバック後に実際に格納した入力だけを削除可能にする。
        if (!path.empty()) g_archived_compression_inputs.emplace(std::move(path));
        SetLastError(previous_error);
    }
    // 空入力は 0、圧縮器の EOF は 38。jm0 の定量コピーは直前の値を保持する。
    if (header->original_size == 0) g_compression_terminal_error = ERROR_SUCCESS;
    else if (compress_method != LZHUFF0_METHOD_NUM) g_compression_terminal_error = ERROR_HANDLE_EOF;
}
extern "C" int Lha_ShouldDiscardCompressionUpdate(void) { return g_discard_compression_update; }

extern "C" int Lha_CompressionInputStat(const char* name, struct stat* status) {
    if (g_enum_command == UNLHA_FRESH_COMMAND && name && status) {
        const DWORD previous_error = GetLastError();
        const auto source = g_freshen_callback_sources.find(StringToWString(name));
        if (source != g_freshen_callback_sources.end() && source->second.has_search_status) {
            *status = source->second.search_status;
            SetLastError(previous_error);
            return 0;
        }
        SetLastError(previous_error);
    }
    return Lha_StatFile(name, status);
}

extern "C" {
static bool ConfiguredMappedFileEnabled();
static DWORD ConfiguredFileBufferSize();
}

static thread_local FILE* g_new_compression_file = nullptr;
static thread_local bool g_new_compression_mapped = false;
static thread_local __int64 g_new_compression_allocation = 0;
struct CompressionWriteBuffer {
    std::unique_ptr<unsigned char[]> bytes;
    size_t capacity = 0;
    size_t valid = 0;
    size_t dirty = 0;
    __int64 start = 0;
    __int64 position = 0;
    __int64 length = 0;
};
static thread_local CompressionWriteBuffer g_compression_write_buffer;

static void ClearNewCompressionArchiveState(FILE* file) {
    if (file == g_new_compression_file) {
        g_new_compression_file = nullptr;
        g_new_compression_mapped = false;
        g_new_compression_allocation = 0;
        g_compression_write_buffer = CompressionWriteBuffer{};
    }
}

static bool UsesCompressionWriteBuffer(FILE* file) {
    return file && file == g_new_compression_file && !g_new_compression_mapped;
}

static int FlushCompressionWriteBuffer(FILE* file) {
    auto& buffer = g_compression_write_buffer;
    if (buffer.dirty) {
        if (_fseeki64(file, buffer.start, SEEK_SET) != 0 ||
            fwrite(buffer.bytes.get(), 1, buffer.dirty, file) != buffer.dirty || fflush(file) != 0)
            return -1;
    }
    buffer.valid = buffer.dirty = 0;
    return 0;
}

extern "C" __int64 Lha_TellCompressionFile(FILE* file) {
    return UsesCompressionWriteBuffer(file) ? g_compression_write_buffer.position : _ftelli64(file);
}

extern "C" int Lha_SeekCompressionFile(FILE* file, __int64 offset, int origin) {
    if (!UsesCompressionWriteBuffer(file)) return _fseeki64(file, offset, origin);
    auto& buffer = g_compression_write_buffer;
    const __int64 base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? buffer.position : buffer.length;
    if ((origin != SEEK_SET && origin != SEEK_CUR && origin != SEEK_END) ||
        (offset > 0 && base > INT64_MAX - offset) || offset < -base) {
        errno = EINVAL;
        return -1;
    }
    const __int64 position = base + offset;
    if (position < buffer.start || position - buffer.start > static_cast<__int64>(buffer.valid)) {
        if (FlushCompressionWriteBuffer(file) != 0) return -1;
    }
    buffer.position = position;
    return 0;
}

static size_t WriteBufferedCompressionData(const void* data, size_t size, size_t count, FILE* file) {
    auto& buffer = g_compression_write_buffer;
    if (!size || !count) return 0;
    if (count > static_cast<size_t>(INT64_MAX) / size ||
        size * count > static_cast<unsigned __int64>(INT64_MAX - buffer.position)) {
        errno = EOVERFLOW;
        return 0;
    }
    const size_t total = size * count;
    size_t written = 0;
    while (written < total) {
        if (!buffer.valid || buffer.position < buffer.start ||
            buffer.position - buffer.start >= static_cast<__int64>(buffer.capacity)) {
            if (FlushCompressionWriteBuffer(file) != 0) break;
            // 原版は任意の許容設定値について、このビットマスクで窓を選ぶ。
            buffer.start = buffer.position & ~static_cast<__int64>(buffer.capacity - 1);
            const size_t readable = static_cast<size_t>((std::min)(
                static_cast<__int64>(buffer.capacity), (std::max)(__int64{0}, buffer.length - buffer.start)));
            if (readable) {
                if (_fseeki64(file, buffer.start, SEEK_SET) != 0 ||
                    fread(buffer.bytes.get(), 1, readable, file) != readable) break;
            }
            buffer.valid = readable;
        }
        const size_t offset = static_cast<size_t>(buffer.position - buffer.start);
        const size_t amount = (std::min)(total - written, buffer.capacity - offset);
        memcpy(buffer.bytes.get() + offset, static_cast<const unsigned char*>(data) + written, amount);
        buffer.position += amount;
        buffer.length = (std::max)(buffer.length, buffer.position);
        buffer.dirty = (std::max)(buffer.dirty, offset + amount);
        buffer.valid = (std::max)(buffer.valid, buffer.dirty);
        written += amount;
    }
    return written / size;
}

extern "C" int Lha_BeginNewCompressionArchive(const char* name, FILE** file) {
    g_new_compression_file = nullptr;
    g_new_compression_mapped = false;
    g_new_compression_allocation = 0;
    g_compression_write_buffer = CompressionWriteBuffer{};
    if (!name || !*name || !strcmp(name, "-")) return 0;
    const DWORD saved_error = GetLastError();
    const std::wstring path = FilePathToWide(name);
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
        SetLastError(saved_error);
        return 0;
    }
    if (GetLastError() != ERROR_FILE_NOT_FOUND) { SetLastError(saved_error); return 0; }
    // 新規ファイルだけを排他的に作成し、確認後に現れた既存ファイルは上書きしない。
    const HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
        nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return -1;
    wchar_t volume[MAX_PATH]{};
    if (ConfiguredMappedFileEnabled() && GetVolumePathNameW(path.c_str(), volume, _countof(volume)) &&
        GetDriveTypeW(volume) == DRIVE_FIXED) {
        const HANDLE mapping = CreateFileMappingW(handle, nullptr, PAGE_READWRITE, 0, 0x800000, nullptr);
        if (mapping) {
            CloseHandle(mapping);
            g_new_compression_mapped = true;
            g_new_compression_allocation = 0x800000;
        }
    }
    const int descriptor = _open_osfhandle(reinterpret_cast<intptr_t>(handle), _O_BINARY | _O_RDWR);
    if (descriptor == -1) { CloseHandle(handle); DeleteFileW(path.c_str()); return -1; }
    *file = _fdopen(descriptor, "w+b");
    if (!*file) { _close(descriptor); DeleteFileW(path.c_str()); return -1; }
    if (!g_new_compression_mapped) {
        g_compression_write_buffer.capacity = ConfiguredFileBufferSize();
        g_compression_write_buffer.bytes.reset(new (std::nothrow) unsigned char[g_compression_write_buffer.capacity]);
        if (!g_compression_write_buffer.bytes) {
            fclose(*file);
            *file = nullptr;
            DeleteFileW(path.c_str());
            errno = ENOMEM;
            return -1;
        }
    }
    strcpy_s(temporary_name, _countof(temporary_name), name);
    temporary_fd = descriptor;
    g_new_compression_file = *file;
    SetLastError(saved_error);
    return 1;
}

extern "C" int Lha_FinishNewCompressionArchive(FILE* file, off_t size) {
    int result = 0;
    if (UsesCompressionWriteBuffer(file) && FlushCompressionWriteBuffer(file) != 0) result = -1;
    if (result == 0 && fflush(file) != 0) result = -1;
    if (result == 0 && _chsize_s(_fileno(file), size) != 0) result = -1;
    ClearNewCompressionArchiveState(file);
    return result;
}

extern "C" int Lha_TruncateCompressionWorkFile(FILE* file, off_t size) {
    if (UsesCompressionWriteBuffer(file)) {
        auto& buffer = g_compression_write_buffer;
        if (size < 0) { errno = EINVAL; return -1; }
        const size_t retained = static_cast<size_t>((std::min)(static_cast<__int64>(buffer.capacity),
            (std::max)(__int64{0}, static_cast<__int64>(size) - buffer.start)));
        buffer.valid = (std::min)(buffer.valid, retained);
        buffer.dirty = (std::min)(buffer.dirty, retained);
        buffer.length = size;
        // 未反映の末尾を捨てるだけなら、公開ファイルを論理サイズまで伸ばさない。
        const __int64 physical_size = _filelengthi64(_fileno(file));
        if (physical_size < 0) return -1;
        return physical_size > size ? (_chsize_s(_fileno(file), size) == 0 ? 0 : -1) : 0;
    }
    // 格納方式への再試行で不要な本文を捨てても、マッピングの予約領域は完了まで保持する。
    const __int64 allocation = file == g_new_compression_file && g_new_compression_mapped
        ? (std::max)(g_new_compression_allocation, ((static_cast<__int64>(size) / 0x800000) + 1) * 0x800000) : size;
    return _chsize_s(_fileno(file), allocation) == 0 ? 0 : -1;
}

extern "C" size_t Lha_WriteCompressionData(const void* data, size_t size, size_t count, FILE* file) {
    if (UsesCompressionWriteBuffer(file)) return WriteBufferedCompressionData(data, size, count, file);
    if (file == g_new_compression_file && g_new_compression_mapped && size && count) {
        const DWORD saved_error = GetLastError();
        const __int64 position = _ftelli64(file);
        if (position < 0 || count > static_cast<size_t>(INT64_MAX) / size ||
            static_cast<unsigned __int64>(size * count) > static_cast<unsigned __int64>(INT64_MAX - position)) {
            errno = EOVERFLOW;
            return 0;
        }
        const __int64 end = position + static_cast<__int64>(size * count);
        if (end > g_new_compression_allocation) {
            if (end > INT64_MAX - 0x7fffff) { errno = EOVERFLOW; return 0; }
            const __int64 allocation = ((end / 0x800000) + (end % 0x800000 != 0)) * 0x800000;
            const HANDLE handle = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(file)));
            const HANDLE mapping = CreateFileMappingW(handle, nullptr, PAGE_READWRITE,
                static_cast<DWORD>(allocation >> 32), static_cast<DWORD>(allocation), nullptr);
            if (!mapping) { errno = ENOSPC; return 0; }
            CloseHandle(mapping);
            g_new_compression_allocation = allocation;
        }
        SetLastError(saved_error);
    }
    return fwrite(data, size, count, file);
}

extern "C" int Lha_WriteCompressionCharacter(int value, FILE* file) {
    // lha.h の fputc マクロを経由すると、この関数へ再帰してしまう。
    const unsigned char byte = static_cast<unsigned char>(value);
    return Lha_WriteCompressionData(&byte, 1, 1, file) == 1 ? byte : EOF;
}

extern "C" unsigned long Lha_GetProgressTickCount(void) {
    return GetTickCount();
}

static DWORD ConfiguredBackgroundDelay() {
    return g_priority == THREAD_PRIORITY_IDLE ? 24
        : g_priority == THREAD_PRIORITY_LOWEST ? 16
        : g_priority == THREAD_PRIORITY_BELOW_NORMAL ? 14
        : (g_priority == THREAD_PRIORITY_ABOVE_NORMAL || g_priority == THREAD_PRIORITY_HIGHEST) ? 4 : 8;
}

extern "C" void Lha_WaitAfterCompressionProgress(void) {
    const DWORD delay = ConfiguredBackgroundDelay();
    if (g_background_mode || delay > 8) Sleep(delay);
}

extern "C" void Lha_PumpCommandMessages(void) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    const DWORD delay = ConfiguredBackgroundDelay();
    if (g_background_mode || delay > 8) Sleep(delay / 8);
}

extern "C" FILE* Lha_OpenCompressionInput(const char* name, LzHeader* header) {
    if (!name) { errno = EINVAL; SetLastError(ERROR_INVALID_PARAMETER); return nullptr; }
    const bool unicode = UsesUnicodeFilePath(name);
    const std::wstring wide_name = unicode ? FilePathToWide(name) : std::wstring();
    const auto open_shared = [&](const int sharing) {
        return unicode ? _wfsopen(wide_name.c_str(), L"rb", sharing)
                       : _fsopen(name, "rb", sharing);
    };
    // 原版の ShareCheck と同様、まず書き込みを拒否し、既定では共有を広げて再試行する。
    // 列挙通知による読込先変更の後だけで行い、汎用の書庫・出力オープンには適用しない。
    int sharing = _SH_DENYWR;
    FILE* file = open_shared(sharing);
    if (!file && !g_compression_reject_shared_writers) {
        sharing = _SH_DENYNO;
        file = open_shared(sharing);
    }
    if (file) {
        // 原版の共有確認は非空入力を読み取りマッピングにして閉じる。参照日時の更新は OS に委ねる。
        const HANDLE probe_handle = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(file)));
        LARGE_INTEGER size{};
        if (ConfiguredMappedFileEnabled() && GetFileSizeEx(probe_handle, &size) && size.QuadPart > 0) {
            const HANDLE mapping = CreateFileMappingW(probe_handle, nullptr, PAGE_READONLY, 0, 0, nullptr);
            if (mapping) CloseHandle(mapping);
        }
        fclose(file);
        file = open_shared(sharing);
        if (file && header && header->has_windows_timestamp) {
            // 原版は共有確認後に検索情報を取得する。ハンドルの日時とは更新時期が異なる。
            WIN32_FIND_DATAW wide_data{};
            WIN32_FIND_DATAA ansi_data{};
            const HANDLE search = unicode ? FindFirstFileW(wide_name.c_str(), &wide_data)
                                          : FindFirstFileA(name, &ansi_data);
            if (search != INVALID_HANDLE_VALUE) {
                const FILETIME access_time = unicode ? wide_data.ftLastAccessTime : ansi_data.ftLastAccessTime;
                header->windows_last_access_time =
                    (static_cast<uint64_t>(access_time.dwHighDateTime) << 32) | access_time.dwLowDateTime;
                FindClose(search);
            }
        }
    }
    if (!file) {
        unsigned long system_error = ERROR_SUCCESS;
        if (_get_doserrno(&system_error) == 0 && system_error != ERROR_SUCCESS)
            SetLastError(system_error);
    }
    return file;
}

static int CompressionReadErrorCode(const DWORD system_error) {
    return system_error == ERROR_ACCESS_DENIED || system_error == ERROR_SHARING_VIOLATION ||
        system_error == ERROR_LOCK_VIOLATION ? ERROR_SHARING : ERROR_NOT_FIND_FILE;
}

extern "C" int Lha_HasCompressionDeleteFailure(void) {
    return !g_compression_delete_failure.first.empty();
}

extern "C" int Lha_HandleCompressionDeleteFailure(const char* name) {
    if (g_command_update_policy.command != 'm' || !name) return FALSE;
    const DWORD system_error = GetLastError();
    char absolute[FILENAME_LENGTH * 4]{};
    const char* reported = Lha_FullPath(absolute, name, _countof(absolute)) ? absolute : name;
    g_compression_delete_failure = {reported, system_error};
    // 圧縮済みの書庫は取り消さず、以後の入力の削除だけを止める。
    SetLastError(system_error);
    return TRUE;
}

extern "C" int Lha_HandleCompressionReadFailure(const char* name) {
    const DWORD system_error = GetLastError();
    const bool source_compression = g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND;
    const bool sharing_error = CompressionReadErrorCode(system_error) == ERROR_SHARING;
    const bool missing_freshen = g_enum_command == UNLHA_FRESH_COMMAND &&
        (system_error == ERROR_FILE_NOT_FOUND || system_error == ERROR_PATH_NOT_FOUND);
    if (!source_compression || (!sharing_error && !missing_freshen)) return FALSE;
    std::string reported = name ? name : "";
    if (g_enum_command != UNLHA_FRESH_COMMAND && name) {
        char absolute[FILENAME_LENGTH * 4]{};
        if (Lha_FullPath(absolute, name, _countof(absolute))) reported = absolute;
    }
    g_compression_read_failure = {std::move(reported), system_error};
    g_discard_compression_update = true;
    SetLastError(system_error);
    return TRUE;
}

enum class MemberTimeKind { Create, Access, Write };

extern "C" {
static UINT HeaderOsType(const LzHeader& header);
static int HeaderAttributes(const LzHeader& header);
static WORD HeaderRatio(const LzHeader& header);
static FILETIME UnixTimeToFileTime(time_t value);
static FILETIME HeaderTimeToFileTime(const LzHeader& header, MemberTimeKind kind);
static FILETIME HeaderExtractionTime(const LzHeader& header, MemberTimeKind kind);
static void PrepareConfiguredCommandState(bool use_registry);
}

static UINT EnumCommandFromCharacter(const char command) {
    switch (command) {
    case 'l': case 'v': return UNLHA_LIST_COMMAND;
    case 'a': case 'u': case 'm': return UNLHA_ADD_COMMAND;
    case 'f': return UNLHA_FRESH_COMMAND;
    case 'd': return UNLHA_DELETE_COMMAND;
    case 'e': case 'x': return UNLHA_EXTRACT_COMMAND;
    case 'p': return UNLHA_PRINT_COMMAND;
    case 't': return UNLHA_TEST_COMMAND;
    case 's': return UNLHA_MAKESFX_COMMAND;
    case 'j': return UNLHA_JOINT_COMMAND;
    case 'y': return UNLHA_CONVERT_COMMAND;
    case 'n': return UNLHA_RENAME_COMMAND;
    default: return 0;
    }
}

template<typename T>
static void FillEnumMetadata(T& info, const LzHeader& header) {
    info.dwAttributes = static_cast<DWORD>(HeaderAttributes(header));
    info.dwCRC = static_cast<DWORD>(header.crc);
    info.uOSType = HeaderOsType(header);
    info.wRatio = header.original_size > 0
        ? static_cast<WORD>((header.packed_size * 1000) / header.original_size)
        : 0;
    info.ftCreateTime = HeaderTimeToFileTime(header, MemberTimeKind::Create);
    info.ftAccessTime = HeaderTimeToFileTime(header, MemberTimeKind::Access);
    info.ftWriteTime = HeaderTimeToFileTime(header, MemberTimeKind::Write);
}

template<typename T, typename U>
static void CopyEnumMetadata(T& destination, const U& source) {
    destination.dwAttributes = source.dwAttributes;
    destination.dwCRC = source.dwCRC;
    destination.uOSType = source.uOSType;
    destination.wRatio = source.wRatio;
    destination.ftCreateTime = source.ftCreateTime;
    destination.ftAccessTime = source.ftAccessTime;
    destination.ftWriteTime = source.ftWriteTime;
}

extern "C" void Lha_RecordEnumHeader(const LzHeader* header) {
    const DWORD previous_error = GetLastError();
    // 呼び出し元は論理的な読み取り位置。進捗側は列挙登録がなくても更新する。
    if (header) Lha_RecordProgressHeader(header, HeaderOsType(*header));
    if (header && (g_enum_command == UNLHA_TEST_COMMAND || g_enum_command == UNLHA_PRINT_COMMAND ||
                   g_enum_command == UNLHA_EXTRACT_COMMAND)) {
        // 中断後に未処理の本文を再読せず、実際に到達した検査ログだけを返す。
        g_command_read_member.wide_name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
        g_command_read_member.non_msdos = header->extend_type != EXTEND_GENERIC &&
            header->extend_type != EXTEND_MSDOS;
        if (header->header_level != 0 && !header->has_header_crc)
            g_command_events.push_back({"ReadHeaderCrcMissing", {}, 0, g_command_read_member.wide_name});
    }
    if (header && g_enum_members_proc) {
        g_enum_metadata.llOriginalSize = header->original_size;
        g_enum_metadata.llCompressedSize = header->packed_size;
        FillEnumMetadata(g_enum_metadata, *header);
    }
    SetLastError(previous_error);
}

template<typename T>
using EnumHas64BitSizes = std::integral_constant<bool,
    std::is_same<T, UNLHA_ENUM_MEMBER_INFO64A>::value || std::is_same<T, UNLHA_ENUM_MEMBER_INFO64W>::value>;

template<typename T>
static void FillEnumSizes(T& info, ULHA_INT64 original, ULHA_INT64 packed, std::true_type) {
    info.llOriginalSize = original;
    info.llCompressedSize = packed;
}

template<typename T>
static void FillEnumSizes(T& info, ULHA_INT64 original, ULHA_INT64 packed, std::false_type) {
    info.dwOriginalSize = static_cast<DWORD>(original);
    info.dwCompressedSize = static_cast<DWORD>(packed);
}

template<typename T>
static void RetainEnumSizes(const T& info, std::true_type) {
    g_enum_metadata.llOriginalSize = info.llOriginalSize;
    g_enum_metadata.llCompressedSize = info.llCompressedSize;
}

template<typename T>
static void RetainEnumSizes(const T& info, std::false_type) {
    g_enum_metadata.llOriginalSize = info.dwOriginalSize;
    g_enum_metadata.llCompressedSize = info.dwCompressedSize;
}

template<typename T>
static void FillEnumCallbackMetadata(T& info, const LzHeader& header) {
    const bool retained = g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND;
    FillEnumSizes(info, retained ? g_enum_metadata.llOriginalSize : header.original_size,
                  retained ? g_enum_metadata.llCompressedSize : header.packed_size, EnumHas64BitSizes<T>{});
    if (retained) CopyEnumMetadata(info, g_enum_metadata);
    else FillEnumMetadata(info, header);
}

template<typename T>
static void RetainEnumCallbackMetadata(const T& info) {
    RetainEnumSizes(info, EnumHas64BitSizes<T>{});
    CopyEnumMetadata(g_enum_metadata, info);
}

static bool EnumUsesArchiveName(const UINT command) {
    return command == UNLHA_ADD_COMMAND || command == UNLHA_FRESH_COMMAND ||
           command == UNLHA_MAKESFX_COMMAND || command == UNLHA_JOINT_COMMAND ||
           command == UNLHA_CONVERT_COMMAND || command == UNLHA_RENAME_COMMAND;
}

static bool EnumUsesAdditionalName(const UINT command) {
    return command == UNLHA_ADD_COMMAND || command == UNLHA_FRESH_COMMAND ||
           command == UNLHA_EXTRACT_COMMAND;
}

static std::string ResolveEnumExtractionName(std::wstring selected) {
    if (selected.empty()) return std::string();
    const bool rooted = selected[0] == L'/' || selected[0] == L'\\' ||
        (selected.size() >= 2 && selected[1] == L':');
    if (!rooted && extract_directory && *extract_directory) {
        // コールバックで変更された相対名は、展開先を基準に解決する。
        std::wstring base = StringToWString(extract_directory);
        if (!base.empty()) {
            if (base.back() != L'/' && base.back() != L'\\') base += L'/';
            selected = base + selected;
        }
    }
    wchar_t absolute[FILENAME_LENGTH * 4]{};
    const DWORD length = GetFullPathNameW(selected.c_str(), _countof(absolute), absolute, nullptr);
    if (length > 0 && length < _countof(absolute)) selected = absolute;
    return RegisterUnicodeExtractionPath(std::move(selected));
}

static void SetEnumResultMemberName(LzHeader& header, std::wstring name) {
    if ((g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND) &&
        memcmp(header.method, LZHDIRS_METHOD, METHOD_TYPE_STORAGE) == 0 &&
        !name.empty() && name.back() != L'/' && name.back() != L'\\') name += L'/';
    SetHeaderNameFromWide(header, name);
}

static void CopyEnumResult(LzHeader* header, char* additional_name,
                           const size_t additional_name_size,
                           const char* member_name, const char* selected_name) {
    if (EnumUsesArchiveName(g_enum_command) && member_name) {
        SetEnumResultMemberName(*header, MultiByteStringToWide(member_name, CallbackCodePage()));
    }
    if (EnumUsesAdditionalName(g_enum_command) && additional_name && additional_name_size > 0) {
        const std::string selected = g_enum_command == UNLHA_EXTRACT_COMMAND
            ? ResolveEnumExtractionName(MultiByteStringToWide(selected_name ? selected_name : "", CallbackCodePage()))
            : (selected_name ? selected_name : "");
        strncpy_s(additional_name, additional_name_size, selected.c_str(), _TRUNCATE);
    }
}

static void CopyEnumResultW(LzHeader* header, char* additional_name,
                            const size_t additional_name_size,
                            const wchar_t* member_name, const wchar_t* selected_name) {
    if (EnumUsesArchiveName(g_enum_command) && member_name) {
        SetEnumResultMemberName(*header, member_name);
    }
    if (EnumUsesAdditionalName(g_enum_command) && additional_name && additional_name_size > 0) {
        const std::wstring requested = selected_name ? selected_name : L"";
        const std::string selected = g_enum_command == UNLHA_EXTRACT_COMMAND
            ? ResolveEnumExtractionName(requested) : WStringToString(requested);
        strncpy_s(additional_name, additional_name_size, selected.c_str(), _TRUNCATE);
    }
}

static BOOL CallEnumMembersProc(LPVOID info) {
    ++g_enum_invoked_count;
    const BOOL selected = g_enum_members_proc(info);
    g_enum_selection_results.push_back(selected);
    if (selected) ++g_enum_selected_count;
    return selected;
}

static std::wstring CoreExtractionPathToWide(const char* path) {
    const std::string value = path ? path : "";
    if (extract_directory && *extract_directory) {
        const std::string prefix = std::string(extract_directory) + '/';
        if (value.compare(0, prefix.size(), prefix) == 0) {
            // 展開先引数は API の文字コード、GetHeaderPath が返す書庫内名は UTF-8。
            return StringToWString(prefix) + MultiByteStringToWide(value.substr(prefix.size()), CP_UTF8);
        }
    }
    return MultiByteStringToWide(value, CP_UTF8);
}

extern "C" int Lha_InvokeEnumMember(LzHeader* header, char* additional_name,
                                      const size_t additional_name_size) {
    if (!g_memory_extracting && g_enum_command == UNLHA_EXTRACT_COMMAND) {
        // ディレクトリ項目など、PrepareCommandExtraction を通らない項目へ前回名を持ち越さない。
        g_command_renamed_destination.clear();
        g_command_renamed_member.clear();
        g_command_renamed_member_w.clear();
    }
    if (header) {
        for (const ForcedHeaderName& forced : g_forced_header_names) {
            if (strcmp(header->name, forced.placeholder.c_str()) == 0) {
                SetHeaderNameFromWide(*header, forced.member_name);
                break;
            }
        }
        if (g_enum_command == UNLHA_FRESH_COMMAND) {
            // f は既存の格納名、a/u/m は検索された実ファイル名を通知・出力する。
            const std::wstring name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
            const auto existing = g_command_existing_members.find(name);
            if (existing != g_command_existing_members.end() && existing->first != name)
                SetHeaderNameFromWide(*header, existing->first);
        }
    }
    const bool command_destination = !g_memory_extracting &&
        (g_enum_command == UNLHA_EXTRACT_COMMAND || g_enum_command == UNLHA_PRINT_COMMAND ||
         g_enum_command == UNLHA_TEST_COMMAND);
    if (header && command_destination && additional_name && additional_name_size > 0) {
        std::wstring path = CoreExtractionPathToWide(additional_name);
        wchar_t absolute[FILENAME_LENGTH * 4]{};
        const DWORD length = GetFullPathNameW(path.c_str(), _countof(absolute), absolute, nullptr);
        if (length > 0 && length < _countof(absolute)) path = absolute;
        const std::string encoded = RegisterUnicodeExtractionPath(std::move(path));
        if (encoded.size() >= additional_name_size) return FALSE;
        strcpy_s(additional_name, additional_name_size, encoded.c_str());
    }
    if (header && g_enum_command == UNLHA_FRESH_COMMAND && additional_name && additional_name_size > 0) {
        const auto source = g_freshen_callback_sources.find(HeaderNameToWString(*header, ConfiguredArchiveCodePage()));
        if (source != g_freshen_callback_sources.end()) {
            const std::string encoded = WStringToString(source->second.callback_source);
            if (encoded.size() >= additional_name_size) return FALSE;
            strcpy_s(additional_name, additional_name_size, encoded.c_str());
        }
    }
    if (!header || !g_enum_members_proc || g_enum_text_mode == EnumTextMode::None || g_enum_command == 0) {
        return TRUE;
    }

    std::string member_name = HeaderNameToString(*header, ConfiguredArchiveCodePage());
    std::wstring member_name_w = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    if (g_wide_command_utf8_input) member_name = WideStringToMultiByte(member_name_w, CallbackCodePage());
    if ((g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND) &&
        memcmp(header->method, LZHDIRS_METHOD, METHOD_TYPE_STORAGE) == 0) {
        // 圧縮通知では末尾区切りを外し、格納時には SetEnumResultMemberName で戻す。
        if (!member_name.empty() && member_name.back() == '/') member_name.pop_back();
        if (!member_name_w.empty() && member_name_w.back() == L'/') member_name_w.pop_back();
    }
    std::wstring add_name_w = g_enum_additional_w_active
        ? g_enum_additional_w : command_destination ? FilePathToWide(additional_name)
                                                   : StringToWString(additional_name ? additional_name : "");
    const bool compression_source = g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND;
    bool raw_freshen_source = false;
    if (g_enum_command == UNLHA_FRESH_COMMAND) {
        const auto source = g_freshen_callback_sources.find(member_name_w);
        if (source != g_freshen_callback_sources.end()) {
            add_name_w = source->second.callback_source;
            raw_freshen_source = true;
        }
    }
    if ((command_destination || compression_source) && !raw_freshen_source && !add_name_w.empty()) {
        wchar_t absolute[FILENAME_LENGTH * 4]{};
        const DWORD length = GetFullPathNameW(add_name_w.c_str(), _countof(absolute), absolute, nullptr);
        if (length > 0 && length < _countof(absolute)) {
            add_name_w = absolute;
            std::replace(add_name_w.begin(), add_name_w.end(), L'\\', L'/');
        }
    }
    const std::string add_name = WideStringToMultiByte(add_name_w, CallbackCodePage());

    if (g_enum_text_mode == EnumTextMode::Ansi &&
        g_enum_struct_size == sizeof(UNLHA_ENUM_MEMBER_INFOA)) {
        UNLHA_ENUM_MEMBER_INFOA info{};
        info.dwStructSize = sizeof(info);
        info.uCommand = g_enum_command;
        FillEnumCallbackMetadata(info, *header);
        strncpy_s(info.szFileName, member_name.c_str(), _TRUNCATE);
        strncpy_s(info.szAddFileName, add_name.c_str(), _TRUNCATE);
        const BOOL selected = CallEnumMembersProc(&info);
        RetainEnumCallbackMetadata(info);
        info.szFileName[_countof(info.szFileName) - 1] = '\0';
        info.szAddFileName[_countof(info.szAddFileName) - 1] = '\0';
        if (selected) {
            CopyEnumResult(header, additional_name, additional_name_size,
                           info.szFileName, info.szAddFileName);
            if (g_enum_additional_w_active) {
                g_enum_additional_w = MultiByteStringToWide(info.szAddFileName, CallbackCodePage());
            }
        }
        return selected;
    }
    if (g_enum_text_mode == EnumTextMode::Wide &&
        g_enum_struct_size == sizeof(UNLHA_ENUM_MEMBER_INFOW)) {
        UNLHA_ENUM_MEMBER_INFOW info{};
        info.dwStructSize = sizeof(info);
        info.uCommand = g_enum_command;
        FillEnumCallbackMetadata(info, *header);
        wcsncpy_s(info.szFileName, member_name_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szAddFileName, add_name_w.c_str(), _TRUNCATE);
        const BOOL selected = CallEnumMembersProc(&info);
        RetainEnumCallbackMetadata(info);
        info.szFileName[_countof(info.szFileName) - 1] = L'\0';
        info.szAddFileName[_countof(info.szAddFileName) - 1] = L'\0';
        if (selected) {
            CopyEnumResultW(header, additional_name, additional_name_size,
                            info.szFileName, info.szAddFileName);
            if (g_enum_additional_w_active) g_enum_additional_w = info.szAddFileName;
        }
        return selected;
    }
    if (g_enum_text_mode == EnumTextMode::Ansi &&
        g_enum_struct_size == sizeof(UNLHA_ENUM_MEMBER_INFO64A)) {
        UNLHA_ENUM_MEMBER_INFO64A info{};
        info.dwStructSize = sizeof(info);
        info.uCommand = g_enum_command;
        FillEnumCallbackMetadata(info, *header);
        strncpy_s(info.szFileName, member_name.c_str(), _TRUNCATE);
        strncpy_s(info.szAddFileName, add_name.c_str(), _TRUNCATE);
        const BOOL selected = CallEnumMembersProc(&info);
        RetainEnumCallbackMetadata(info);
        info.szFileName[_countof(info.szFileName) - 1] = '\0';
        info.szAddFileName[_countof(info.szAddFileName) - 1] = '\0';
        if (selected) {
            CopyEnumResult(header, additional_name, additional_name_size,
                           info.szFileName, info.szAddFileName);
            if (g_enum_additional_w_active) {
                g_enum_additional_w = MultiByteStringToWide(info.szAddFileName, CallbackCodePage());
            }
        }
        return selected;
    }
    if (g_enum_text_mode == EnumTextMode::Wide &&
        g_enum_struct_size == sizeof(UNLHA_ENUM_MEMBER_INFO64W)) {
        UNLHA_ENUM_MEMBER_INFO64W info{};
        info.dwStructSize = sizeof(info);
        info.uCommand = g_enum_command;
        FillEnumCallbackMetadata(info, *header);
        wcsncpy_s(info.szFileName, member_name_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szAddFileName, add_name_w.c_str(), _TRUNCATE);
        const BOOL selected = CallEnumMembersProc(&info);
        RetainEnumCallbackMetadata(info);
        info.szFileName[_countof(info.szFileName) - 1] = L'\0';
        info.szAddFileName[_countof(info.szAddFileName) - 1] = L'\0';
        if (selected) {
            CopyEnumResultW(header, additional_name, additional_name_size,
                            info.szFileName, info.szAddFileName);
            if (g_enum_additional_w_active) g_enum_additional_w = info.szAddFileName;
        }
        return selected;
    }
    return TRUE;
}

extern "C" void Lha_RecordCommandEvent(const char* action, const char* name,
                                         const int value) {
    if (!action || !name) return;
    const DWORD previous_error = GetLastError();
    std::string event_name = name;
    std::wstring wide_name;
    if (strcmp(action, "mkdir") == 0) {
        wide_name = FilePathToWide(name);
        if (g_enum_command == UNLHA_EXTRACT_COMMAND && !g_command_renamed_destination.empty()) {
            std::wstring requested = FilePathToWide(g_command_renamed_destination.c_str());
            std::wstring created = wide_name;
            std::replace(requested.begin(), requested.end(), L'\\', L'/');
            std::replace(created.begin(), created.end(), L'\\', L'/');
            const size_t separator = requested.find_last_of(L'/');
            if (separator != std::wstring::npos &&
                _wcsicmp(requested.substr(0, separator).c_str(), created.c_str()) != 0) {
                // 元 DLL は再帰的に作った中間階層ではなく、要求した親フォルダーだけを表示する。
                SetLastError(previous_error);
                return;
            }
        }
        wchar_t absolute[MAX_PATH * 4]{};
        const DWORD length = GetFullPathNameW(wide_name.c_str(),
                                             _countof(absolute), absolute, nullptr);
        if (length > 0 && length < _countof(absolute)) {
            std::wstring actual_case = absolute;
            size_t begin = actual_case.size() >= 3 && actual_case[1] == L':' ? 3 : 0;
            if (actual_case.rfind(L"\\\\", 0) == 0) {
                const size_t server_end = actual_case.find(L'\\', 2);
                const size_t share_end = server_end == std::wstring::npos ? server_end
                    : actual_case.find(L'\\', server_end + 1);
                begin = share_end == std::wstring::npos ? actual_case.size() : share_end + 1;
            }
            // GetLongPathName は長い成分の照合を省略するため、各成分の実名を取得する。
            while (begin < actual_case.size()) {
                const size_t separator = actual_case.find(L'\\', begin);
                size_t end = separator == std::wstring::npos ? actual_case.size() : separator;
                WIN32_FIND_DATAW found{};
                const HANDLE search = FindFirstFileW(actual_case.substr(0, end).c_str(), &found);
                if (search != INVALID_HANDLE_VALUE) {
                    actual_case.replace(begin, end - begin, found.cFileName);
                    end = begin + wcslen(found.cFileName);
                    FindClose(search);
                }
                begin = end + 1;
            }
            event_name = WStringToString(actual_case);
            wide_name = std::move(actual_case);
        }
    }
    const bool renamed = _strnicmp(action, "Melted", 6) == 0 &&
        !g_command_renamed_destination.empty() && g_command_renamed_destination == name;
    if (renamed) wide_name = g_command_renamed_member_w;
    else if (_strnicmp(action, "Melted", 6) == 0 && UsesUnicodeFilePath(name))
        wide_name = FilePathToWide(name);
    g_command_events.push_back({action, renamed ? g_command_renamed_member : event_name,
                               value, std::move(wide_name)});
    if (_strnicmp(action, "Tested", 6) == 0) {
        CommandEvent& event = g_command_events.back();
        event.wide_name = g_command_read_member.wide_name;
        event.non_msdos = g_command_read_member.non_msdos;
    } else if (_strnicmp(action, "Melted", 6) == 0) {
        g_command_events.back().non_msdos = g_command_read_member.non_msdos;
    }
    SetLastError(previous_error);
}

extern "C" void Lha_RecordHeaderCommandEvent(const char* action, const LzHeader* header, int value) {
    if (!header || !action) return;
    const DWORD previous_error = GetLastError();
    const std::string name = g_unicode_mode.load()
        ? HeaderNameToString(*header, ConfiguredArchiveCodePage()) : header->name;
    Lha_RecordCommandEvent(action, name.c_str(), value);
    g_command_events.back().wide_name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    g_command_events.back().directory = memcmp(header->method, LZHDIRS_METHOD, METHOD_TYPE_STORAGE) == 0;
    SetLastError(previous_error);
}

extern "C" void Lha_RecordCommandTestCrcError(const off_t data_start) {
    // 項目名は重複・変更できるため、実際に検査した本文位置を記録する。
    g_command_test_crc_errors.push_back(data_start);
    // finish_indicator が直前に作ったログへ、後から判明した CRC 不一致を結び付ける。
    if (!g_command_events.empty()) {
        CommandEvent& event = g_command_events.back();
        if (_strnicmp(event.action.c_str(), "Melted", 6) == 0 ||
            _strnicmp(event.action.c_str(), "Tested", 6) == 0) {
            event.value = 1;
        }
    }
}

static bool UseEnglishDialogResources() {
    LANGID language = g_language;
    if (PRIMARYLANGID(language) == LANG_NEUTRAL) language = GetUserDefaultUILanguage();
    return PRIMARYLANGID(language) == LANG_ENGLISH;
}

static std::wstring CommandCrcErrorMessage() {
    return UseEnglishDialogResources() ? L"CRC error."
        : L"ファイルのチェックサムが合っていません";
}

static const wchar_t* CommandCancellationLocation() {
    return g_command_progress_cancel_state == ARCEXTRACT_OPEN ? L"SetDlgArcName"
        : g_command_progress_cancel_state == ARCEXTRACT_INPROCESS ? L"SetParcent" : L"SetDlgFileName";
}

static std::wstring CommandCancellationMessage() {
    return UseEnglishDialogResources() ? L"Break signaled." : L"ユーザーによって中断されました";
}

static void ReportCommandCancellation() {
    if (g_memory_extracting || g_command_update_policy.suppress_errors) return;
    const std::wstring title = std::wstring(UseEnglishDialogResources() ? L"UNLHA32 Error report (on "
        : L"UNLHA32 エラー報告 (on ") + CommandCancellationLocation() + L")";
    MessageBoxW(nullptr, CommandCancellationMessage().c_str(), title.c_str(), MB_TASKMODAL | MB_ICONERROR);
}

extern "C" int Lha_HandleCommandCrcError(const off_t data_start, const char* output_path) {
    Lha_RecordCommandTestCrcError(data_start);
    if (g_enum_command != UNLHA_EXTRACT_COMMAND && g_enum_command != UNLHA_PRINT_COMMAND)
        return FALSE;
    // p はメモリ出力であり、削除対象となるファイル名を持たない。
    std::wstring path = output_path ? FilePathToWide(output_path) : std::wstring();
    std::replace(path.begin(), path.end(), L'\\', L'/');
    const bool english = UseEnglishDialogResources();
    const bool silent = g_command_update_policy.suppress_errors;
    const HWND owner = g_hwndOwner;
    const std::wstring question = english ? L"CRC Error!\r\nDelete '" + path + L"'?"
        : L"CRC エラーです。\r\n'" + path + L"' は完全ではありません。削除しますか？";
    const int remove = silent ? IDYES : MessageBoxW(owner, question.c_str(),
        english ? L"Deleting a file" : L"削除確認", MB_TASKMODAL | MB_YESNO | MB_ICONQUESTION);
    if (remove == IDYES && output_path) DeleteFileW(path.c_str());
    if (!silent && MessageBoxW(owner,
        english ? L"Continue Process?" : L"処理を続行しますか？",
        english ? L"Contine" : L"処理続行確認", MB_TASKMODAL | MB_YESNO | MB_ICONQUESTION) == IDNO) {
        g_command_crc_stopped = true;
        g_command_crc_failure_path = std::move(path);
        const std::wstring report = CommandCrcErrorMessage() + (g_command_crc_failure_path.empty()
            ? std::wstring() : L" : '" + g_command_crc_failure_path + L"'");
        MessageBoxW(nullptr, report.c_str(), english ? L"UNLHA32 Error report (on extractsub)"
            : L"UNLHA32 エラー報告 (on extractsub)", MB_TASKMODAL | MB_ICONERROR);
        // C++ の一時オブジェクトを破棄してから、呼び出し側の C で共通 cleanup へ移る。
        return TRUE;
    }
    return FALSE;
}

static bool CommandTimestampMatches(const FILETIME& incoming, const FILETIME& existing,
                                    const ULHA_INT64 incoming_size, const ULHA_INT64 existing_size) {
    const int order = CompareFileTime(&incoming, &existing);
    if (g_command_update_policy.comparison == 2) return order < 0;
    if (g_command_update_policy.comparison == 3)
        return order != 0 || incoming_size != existing_size;
    return order > 0;
}

extern "C" int Lha_CommandShouldAddMember(const LzHeader* header) {
    if (!header) return FALSE;
    const auto& policy = g_command_update_policy;
    std::wstring name = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    for (const ForcedHeaderName& forced : g_forced_header_names) {
        if (strcmp(header->name, forced.placeholder.c_str()) == 0) {
            name = forced.member_name;
            break;
        }
    }
    const auto member = g_command_existing_members.find(name);
    const bool exists = member != g_command_existing_members.end();
    if (policy.command == 'f' && !exists) return FALSE;
    if (policy.command != 'f' && policy.new_only) return exists ? FALSE : TRUE;
    if (policy.command == 'a' || !exists) return TRUE;
    // f の旧版互換経路では、古い／異なるものの選択が -c1 より優先される。
    if (policy.ignore_timestamp && (policy.command != 'f' || policy.comparison == 1)) return TRUE;
    const FILETIME incoming = HeaderTimeToFileTime(*header, MemberTimeKind::Write);
    return CommandTimestampMatches(incoming, member->second.write_time, header->original_size, member->second.size)
        ? TRUE : FALSE;
}

static DWORD InspectExistingExtractionFile(const std::wstring& path, bool& opened) {
    // 原版は判定対象を読み取りマッピングで開く。参照日時の更新もファイルシステムに委ねる。
    // ビューは不要。空ファイルは判定を継続し、開けない場合は呼び出し元で停止する。
    const DWORD previous_error = GetLastError();
    // 原版のボリューム照会前処理は NULL パスを 87 と記録する。
    // マッピング成功時はその値を残し、未使用・空ファイルではサイズ照会の値へ更新する。
    DWORD system_error = ERROR_INVALID_PARAMETER;
    const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    opened = file != INVALID_HANDLE_VALUE;
    if (file != INVALID_HANDLE_VALUE) {
        // 原版は空ファイルをマッピングしない。失敗するマッピング作成でも参照日時が変わる。
        LARGE_INTEGER size{};
        SetLastError(ERROR_SUCCESS);
        const BOOL sized = GetFileSizeEx(file, &size);
        if (sized && ConfiguredMappedFileEnabled() && size.QuadPart > 0) {
            const HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
            if (mapping) CloseHandle(mapping);
            else system_error = GetLastError();
        } else system_error = GetLastError();
        CloseHandle(file);
    } else system_error = GetLastError();
    SetLastError(previous_error);
    return system_error;
}

static std::wstring CommandExtractionErrorMessage(const int code) {
    const bool english = UseEnglishDialogResources();
    switch (code) {
    case ERROR_MORE_FRESH: return english ? L"Newer or same file exists." : L"新しいファイルが既に存在しています";
    case ERROR_ALREADY_EXIST: return english ? L"Already exists." : L"既にファイルが存在しています";
    case ERROR_NOT_EXIST: return english ? L"No file exists." : L"同名のファイルが存在していません";
    case ERROR_READ_ONLY: return english ? L"Read only file." : L"上書きしようとしているファイルはリードオンリーです";
    case ERROR_USER_SKIP: return english ? L"Break signaled by user." : L"ユーザーによって展開をスキップされました";
    case ERROR_UNKNOWN_TYPE: return english ? L"Unknown file type." : L"格納ファイルが MS-DOS で扱える形式ではありません";
    case ERROR_MAKEDIRECTORY: return english ? L"Can't create directory." : L"ディレクトリが作成できません";
    default: return english ? L"Can't open file." : L"ファイルを開けませんでした";
    }
}

static std::wstring CommandExtractionFailureLocation() {
    const auto& failure = g_command_extraction_failure;
    return std::wstring(L" (on ") + failure.location +
        (failure.include_system_error ? L" : " + std::to_wstring(failure.system_error) : L"") + L")";
}

static void RecordCommandExtractionFailure(const int code, const std::wstring& path, const DWORD system_error,
                                          const wchar_t* location = L"extractsub", const bool include_system = false) {
    auto& failure = g_command_extraction_failure;
    failure = {code, system_error, path, location, include_system};
    std::replace(failure.path.begin(), failure.path.end(), L'\\', L'/');
    if (!g_command_update_policy.suppress_errors) {
        const std::wstring title = (UseEnglishDialogResources() ? L"UNLHA32 Error report" : L"UNLHA32 エラー報告") +
            CommandExtractionFailureLocation();
        const std::wstring report = CommandExtractionErrorMessage(code) + L" : '" + failure.path + L"'";
        MessageBoxW(nullptr, report.c_str(), title.c_str(), MB_TASKMODAL | MB_ICONERROR);
    }
}

static void InitializeFileQuestionDialog(HWND dialog, const wchar_t* body, const CommandFileQuestion kind) {
    const bool english = UseEnglishDialogResources();
    const bool directory = kind == CommandFileQuestion::Directory;
    SetWindowTextW(dialog, directory ? (english ? L"Creating Directory" : L"ディレクトリの作成")
        : kind == CommandFileQuestion::ReadOnly
        ? (english ? L"Overwriting a file" : L"特殊属性上書き確認")
        : (english ? L"Overwriting" : L"上書き確認"));
    SetDlgItemTextW(dialog, 11, body ? body : L"");
    SetDlgItemTextW(dialog, 20, english ? L"&Process" : L"処理(&P)");
    const wchar_t* overwrite_labels[] = {
        english ? L"Over&Write" : L"上書き(&W)", english ? L"&Skip" : L"上書きしない(&N)",
        english ? L"Overwrite &All" : L"全て上書き(&A)", english ? L"s&Kip All" : L"全て無視(&H)"
    };
    const wchar_t* directory_labels[] = {
        english ? L"&Create" : L"作成する(&M)", english ? L"&Not create" : L"作成しない(&N)",
        english ? L"Create &All" : L"以降全て作成(&A)", english ? L"&Skip All" : L"全て作成しない(&H)"
    };
    const wchar_t* const* labels = directory ? directory_labels : overwrite_labels;
    for (int index = 0; index < 4; ++index) {
        const HWND control = GetDlgItem(dialog, 21 + index);
        SetWindowTextW(control, labels[index]);
        HDC dc = GetDC(control);
        if (dc) {
            const HFONT font = reinterpret_cast<HFONT>(SendMessageW(control, WM_GETFONT, 0, 0));
            const HGDIOBJ previous = font ? SelectObject(dc, font) : nullptr;
            SIZE extent{};
            if (GetTextExtentPoint32W(dc, labels[index], static_cast<int>(wcslen(labels[index])), &extent)) {
                RECT rect{};
                GetWindowRect(control, &rect);
                SetWindowPos(control, nullptr, 0, 0, rect.right - rect.left + extent.cx,
                    rect.bottom - rect.top, SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER);
            }
            if (previous) SelectObject(dc, previous);
            ReleaseDC(control, dc);
        }
    }
    SetDlgItemTextW(dialog, IDOK, english ? L"&Ok" : L"了解(&O)");
    SetDlgItemTextW(dialog, IDCANCEL, english ? L"&Cancel" : L"中止(&C)");
    CheckRadioButton(dialog, 21, 24, 21);

    // 原版は長い説明行を最大2行へ折り返せる幅まで広げ、本文以外の配置は保つ。
    LONG longest = 0;
    HDC dc = GetDC(dialog);
    if (dc && body) {
        const HFONT font = reinterpret_cast<HFONT>(SendMessageW(dialog, WM_GETFONT, 0, 0));
        const HGDIOBJ previous = font ? SelectObject(dc, font) : nullptr;
        for (const wchar_t* cursor = body; *cursor;) {
            const wchar_t* line = cursor;
            while (*cursor >= 0x20) ++cursor;
            SIZE extent{};
            if (GetTextExtentPoint32W(dc, line, static_cast<int>(cursor - line), &extent))
                longest = (std::max)(longest, extent.cx);
            while (*cursor && *cursor < 0x20) ++cursor;
        }
        if (previous) SelectObject(dc, previous);
    }
    if (dc) ReleaseDC(dialog, dc);
    RECT window{};
    GetWindowRect(dialog, &window);
    if (!directory && longest > 600) {
        RECT units{0, 0, 4, 8};
        MapDialogRect(dialog, &units);
        const int base_width = units.right * 200 / 4;
        const int extra = longest / 2 - base_width;
        if (extra > 0) {
            const HWND message_control = GetDlgItem(dialog, 11);
            RECT message_rect{};
            GetClientRect(message_control, &message_rect);
            SetWindowPos(message_control, nullptr, units.right * 5 / 2, units.bottom * 5 / 8,
                base_width + extra, message_rect.bottom, SWP_NOACTIVATE | SWP_NOZORDER);
            window.right += extra;
        }
    }
    RECT work_area{};
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0))
        GetWindowRect(GetDesktopWindow(), &work_area);
    RECT bounds = work_area;
    // DialogBox が選び直した最上位所有者ではなく、呼び出し元の子ウィンドウも基準にする。
    const HWND owner = g_hwndOwner;
    if (owner && IsWindowVisible(owner)) GetWindowRect(owner, &bounds);
    const int width = window.right - window.left, height = window.bottom - window.top;
    // 原版と同じ個別の整数丸めと作業領域への補正を行う。
    int target_x = bounds.left + (bounds.right - bounds.left) / 2 - width / 2;
    int target_y = bounds.top + (bounds.bottom - bounds.top) / 2 - height / 2;
    target_x = (std::max)(target_x, static_cast<int>(work_area.left));
    target_y = (std::max)(target_y, static_cast<int>(work_area.top));
    if (target_x + width > work_area.right) target_x = work_area.right - width;
    if (target_y + height > work_area.bottom) target_y = work_area.bottom - height;
    SetWindowPos(dialog, nullptr, target_x, target_y, width, height, SWP_NOACTIVATE | SWP_NOZORDER);
}

static const wchar_t* FileQuestionLocation(const CommandFileQuestion kind) {
    return kind == CommandFileQuestion::Directory ? L"CheckDiretory"
        : kind == CommandFileQuestion::ReadOnly ? L"OWReadOnlyMessage" : L"OverWriteMessage";
}

static INT_PTR HandleFileQuestionDialog(HWND dialog, const UINT message, const WPARAM wparam,
                                       const LPARAM lparam, const CommandFileQuestion kind) {
    if (message == WM_INITDIALOG) {
        InitializeFileQuestionDialog(dialog, reinterpret_cast<const wchar_t*>(lparam), kind);
        return FALSE;
    }
    if (message == WM_COMMAND || message == WM_CLOSE) {
        const int action = message == WM_CLOSE ? IDCANCEL : LOWORD(wparam);
        if (action == IDOK) {
            int selected = 21;
            for (int radio = 21; radio <= 24; ++radio)
                if (IsDlgButtonChecked(dialog, radio) == BST_CHECKED) { selected = radio; break; }
            if (kind == CommandFileQuestion::Directory) {
                if (selected == 23) g_command_question_state.create_directory = 1;
                else if (selected == 24) g_command_question_state.create_directory = 2;
            } else if (kind == CommandFileQuestion::ReadOnly) {
                if (selected == 23) g_command_question_state.protected_all = 1;
                else if (selected == 24) g_command_question_state.protected_all = 2;
            } else {
                if (selected == 23) g_command_question_state.overwrite_all = true;
                else if (selected == 24) g_command_question_state.skip_existing = true;
            }
            EndDialog(dialog, selected & 1);
        } else if (action == IDCANCEL) {
            g_command_question_state.cancelled_location = FileQuestionLocation(kind);
            EndDialog(dialog, FALSE);
        }
        return TRUE;
    }
    return FALSE;
}

static std::vector<unsigned char> FileQuestionDialogTemplate() {
    const HRSRC resource = FindResourceW(g_hModule, MAKEINTRESOURCEW(IDD_UNLHA_OVERWRITE), MAKEINTRESOURCEW(5));
    const DWORD size = resource ? SizeofResource(g_hModule, resource) : 0;
    const HGLOBAL loaded = resource ? LoadResource(g_hModule, resource) : nullptr;
    const auto* bytes = loaded ? static_cast<const unsigned char*>(LockResource(loaded)) : nullptr;
    if (!bytes || size < sizeof(DLGTEMPLATE)) return {};
    size_t cursor = sizeof(DLGTEMPLATE);
    const auto word = [&](const size_t offset) {
        WORD value = 0;
        if (offset + sizeof(value) <= size) memcpy(&value, bytes + offset, sizeof(value));
        return value;
    };
    // 自分の標準ダイアログリソースのメニュー・クラス・タイトルを越える。
    for (int field = 0; field < 3; ++field) {
        if (cursor + 2 > size) return {};
        if (word(cursor) == 0xffff) cursor += 4;
        else {
            while (cursor + 2 <= size && word(cursor) != 0) cursor += 2;
            cursor += 2;
        }
    }
    const size_t font_offset = cursor;
    cursor += 2;
    while (cursor + 2 <= size && word(cursor) != 0) cursor += 2;
    cursor = (cursor + 2 + 3) & ~size_t{3};
    if (cursor > size) return {};

    LOGFONTW font{};
    WORD points = 10;
    std::wstring face = L"System";
    if (GetObjectW(GetStockObject(DEFAULT_GUI_FONT), sizeof(font), &font)) {
        face = font.lfFaceName;
        HDC dc = GetDC(nullptr);
        const int dpi = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
        if (dc) ReleaseDC(nullptr, dc);
        points = static_cast<WORD>((std::max)(9L, dpi > 0 ? font.lfHeight * 72 / dpi : 9L));
    }
    std::vector<unsigned char> result(bytes, bytes + font_offset);
    result.insert(result.end(), reinterpret_cast<const unsigned char*>(&points),
        reinterpret_cast<const unsigned char*>(&points) + sizeof(points));
    const auto* name = reinterpret_cast<const unsigned char*>(face.c_str());
    result.insert(result.end(), name, name + (face.size() + 1) * sizeof(wchar_t));
    result.resize((result.size() + 3) & ~size_t{3}, 0);
    result.insert(result.end(), bytes + cursor, bytes + size);
    return result;
}

static bool AskFileQuestion(const std::wstring& body, const CommandFileQuestion kind) {
    // 原版は DEFAULT_GUI_FONT の実名と、下限9ポイントのサイズをテンプレートへ設定する。
    const auto resource = FileQuestionDialogTemplate();
    const DLGPROC callback = kind == CommandFileQuestion::Directory ? MakeDirMsgDlgProc
        : kind == CommandFileQuestion::ReadOnly ? OWReadOnlyMsgDlgProc : OverWriteMsgDlgProc;
    const INT_PTR answer = resource.empty() ? -1 : DialogBoxIndirectParamW(g_hModule,
        reinterpret_cast<const DLGTEMPLATE*>(resource.data()), g_hwndOwner,
        callback, reinterpret_cast<LPARAM>(body.c_str()));
    // 画面生成に失敗した場合も、確認を得ていない保存先を変更しない。
    if (answer < 0 && !g_command_question_state.cancelled_location)
        g_command_question_state.cancelled_location = FileQuestionLocation(kind);
    if (g_command_question_state.cancelled_location) {
        const std::wstring title = std::wstring(UseEnglishDialogResources() ? L"UNLHA32 Error report (on "
            : L"UNLHA32 エラー報告 (on ") + g_command_question_state.cancelled_location + L")";
        MessageBoxW(nullptr, CommandCancellationMessage().c_str(), title.c_str(), MB_TASKMODAL | MB_ICONERROR);
    }
    return answer == TRUE && !g_command_question_state.cancelled_location;
}

static constexpr int COMMAND_EXTRACTION_RENAMED = 9;

static bool SelectCommandExtractionName(std::wstring& path) {
    if (g_command_update_policy.suppress_new_name) return false;
    const bool english = UseEnglishDialogResources();
    if (MessageBoxW(g_hwndOwner, english ? L"Change the filename?" : L"ファイル名を変更しますか？",
        english ? L"Changing filename" : L"ファイル名変更確認",
        MB_TASKMODAL | MB_ICONQUESTION | MB_YESNO) != IDYES) return false;

    std::wstring initial = path;
    std::replace(initial.begin(), initial.end(), L'/', L'\\');
    const size_t slash = initial.find_last_of(L'\\');
    std::wstring parent = slash == std::wstring::npos ? std::wstring() : initial.substr(0, slash);
    if (slash == 0 || (parent.size() == 2 && parent[1] == L':')) parent += L'\\';
    const std::wstring leaf = slash == std::wstring::npos ? initial : initial.substr(slash + 1);
    wchar_t selected[512]{}, title[512]{}, previous_directory[32768]{};
    if (leaf.size() >= _countof(selected)) return false;
    wcscpy_s(selected, leaf.c_str());
    const DWORD directory_length = GetCurrentDirectoryW(_countof(previous_directory), previous_directory);
    if (!directory_length || directory_length >= _countof(previous_directory)) return false;
    OPENFILENAMEW options{};
    options.lStructSize = OPENFILENAME_SIZE_VERSION_400W;
    options.hwndOwner = g_hwndOwner;
    // 原版は表示名だけのフィルターと旧サイズ構造体を渡し、OS標準の保存画面を使う。
    options.lpstrFilter = L"*.*\0\0";
    options.nFilterIndex = 1;
    options.lpstrFile = selected;
    options.nMaxFile = _countof(selected);
    options.lpstrFileTitle = title;
    options.nMaxFileTitle = _countof(title);
    options.lpstrInitialDir = parent.c_str();
    options.Flags = OFN_HIDEREADONLY;
    const BOOL accepted = GetSaveFileNameW(&options);
    // 保存画面でフォルダーを移動しても、次の項目・命令の基点を変えない。
    const BOOL restored = SetCurrentDirectoryW(previous_directory);
    if (!accepted || !restored || !selected[0]) return false;
    path = selected;
    return true;
}

static int PrepareCommandParentDirectory(std::wstring& path, const bool selected_by_dialog = false) {
    const size_t separator = path.find_last_of(L"/\\");
    if (separator == std::wstring::npos) return 0;
    std::wstring parent = path.substr(0, separator);
    if (parent.size() == 2 && parent[1] == L':') parent += L'/';
    const DWORD attributes = GetFileAttributesW(parent.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)) return 0;
    if (g_command_question_state.create_directory == 2) return 8;
    if (g_command_question_state.create_directory == 1 || g_command_update_policy.assume_directory ||
        g_command_update_policy.suppress_errors) return 0;
    std::wstring displayed = path;
    if (!selected_by_dialog) std::replace(displayed.begin(), displayed.end(), L'\\', L'/');
    const std::wstring question = UseEnglishDialogResources()
        ? L"'" + displayed + L"', Create this directory?"
        : L"[" + displayed + L"]\r\nディレクトリが存在しません。作成しますか？";
    if (AskFileQuestion(question, CommandFileQuestion::Directory)) return 0;
    if (g_command_question_state.cancelled_location) return -1;
    return SelectCommandExtractionName(path) ? COMMAND_EXTRACTION_RENAMED : 8;
}

static std::wstring OverwriteTimeText(const FILETIME& value) {
    FILETIME local{};
    SYSTEMTIME time{};
    FileTimeToLocalFileTime(&value, &local);
    FileTimeToSystemTime(&local, &time);
    wchar_t formatted[32]{};
    _snwprintf_s(formatted, _countof(formatted), _TRUNCATE, L"%04u/%02u/%02u %02u:%02u:%02u",
        time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    return formatted;
}

static int PrepareCommandExtraction(const LzHeader& header, std::wstring& path, bool& existing_approved,
                                    const bool selected_by_dialog, DWORD& system_error) {
    existing_approved = false;
    WIN32_FILE_ATTRIBUTE_DATA existing{};
    bool exists = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &existing) != FALSE;
    system_error = exists ? ERROR_INVALID_PARAMETER : GetLastError();
    if (exists && !(existing.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        bool opened = false;
        system_error = InspectExistingExtractionFile(path, opened);
        if (!opened) {
            RecordCommandExtractionFailure(ERROR_FILE_OPEN, path, system_error, L"MyGetFileTimeInfo", true);
            return -1;
        }
    }
    const auto& policy = g_command_update_policy;
    if (exists && policy.new_only) return 1;
    if (exists && policy.overwrite_mode == 2) {
        const size_t slash = path.find_last_of(L"/\\");
        const size_t dot = path.find_last_of(L'.');
        const std::wstring base = dot != std::wstring::npos &&
            (slash == std::wstring::npos || dot > slash) ? path.substr(0, dot) : path;
        bool found = false;
        for (int index = 0; index <= 999; ++index) {
            wchar_t extension[5]{};
            _snwprintf_s(extension, _countof(extension), _TRUNCATE, L".%03d", index);
            const std::wstring candidate = base + extension;
            if (GetFileAttributesW(candidate.c_str()) == INVALID_FILE_ATTRIBUTES) {
                path = candidate;
                found = true;
                break;
            }
        }
        if (!found) return 1;
        exists = false;
    }
    if (!exists) {
        // 原版は未作成の展開先だけ属性で除外し、既存ファイルへの上書きは別判定にする。
        if (!policy.restore_attributes && (HeaderAttributes(header) & 6U) != 0) return 7;
        return policy.existing_only ? 5 : 0;
    }
    if (!policy.ignore_timestamp && !(policy.existing_only && policy.comparison == 3)) {
        // 3.00.0.5 は -gf3 の展開経路で同日時・同サイズの除外を行わない。
        const ULHA_INT64 size = (static_cast<ULHA_INT64>(existing.nFileSizeHigh) << 32) |
                                existing.nFileSizeLow;
        const FILETIME incoming = HeaderTimeToFileTime(header, MemberTimeKind::Write);
        if (!CommandTimestampMatches(incoming, existing.ftLastWriteTime, header.original_size, size))
            return policy.comparison == 2 ? 3 : (policy.comparison == 3 ? 4 : 2);
    }
    if (g_command_question_state.skip_existing) return 4;
    std::wstring display_path = path;
    if (!selected_by_dialog) std::replace(display_path.begin(), display_path.end(), L'\\', L'/');
    if (!policy.assume_overwrite && !policy.suppress_errors && !g_command_question_state.overwrite_all) {
        const FILETIME incoming = HeaderTimeToFileTime(header, MemberTimeKind::Write);
        const std::wstring question = L"LZH : " + OverwriteTimeText(incoming) + L", DISK : " +
            OverwriteTimeText(existing.ftLastWriteTime) + L"\r\n'" + display_path +
            (UseEnglishDialogResources() ? L"' is same or newer.\r\nOverwrite?"
                : L"' は既に存在しています。\r\n上書きしますか？");
        if (!AskFileQuestion(question, CommandFileQuestion::Overwrite)) {
            if (g_command_question_state.cancelled_location) return -1;
            return SelectCommandExtractionName(path) ? COMMAND_EXTRACTION_RENAMED : 4;
        }
    }
    if ((existing.dwFileAttributes & 7U) != 0 && policy.protected_attributes != 1) {
        if (policy.suppress_errors || policy.protected_attributes == 2) return 6;
        if (g_command_question_state.protected_all == 2) return 6;
        if (g_command_question_state.protected_all == 0) {
            std::wstring attributes = L"---w";
            if (existing.dwFileAttributes & FILE_ATTRIBUTE_ARCHIVE) attributes[0] = L'a';
            if (existing.dwFileAttributes & FILE_ATTRIBUTE_SYSTEM) attributes[1] = L's';
            if (existing.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) attributes[2] = L'h';
            if (existing.dwFileAttributes & FILE_ATTRIBUTE_READONLY) attributes[3] = L'r';
            const std::wstring question = L"'" + display_path + L"' [" + attributes + L"]  : " +
                (UseEnglishDialogResources() ? L"Special attributes.\r\nOverwrite?"
                    : L"特殊属性のファイルです。\r\n上書きしますか？");
            if (!AskFileQuestion(question, CommandFileQuestion::ReadOnly))
                return g_command_question_state.cancelled_location ? -1 : 6;
        }
    }
    // 特殊属性の上書きを許可した時点で原版は全属性を通常へ戻す。
    // 後続の容量確認で拒否しても、本文は保持し、この属性変更は残る。
    if ((existing.dwFileAttributes & 7U) != 0) SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
    existing_approved = true;
    return 0;
}

extern "C" int Lha_PrepareCommandExtraction(const LzHeader* header, char* path, const size_t path_size) {
    if (!header || !path) return FALSE;
    g_command_renamed_destination.clear();
    g_command_renamed_member.clear();
    g_command_renamed_member_w.clear();
    g_command_metadata_path.clear();
    bool unicode_path = UsesUnicodeFilePath(path);
    std::wstring wide_path = FilePathToWide(path);
    bool existing_approved = false;
    bool selected_by_dialog = false;
    int reason = 0;
    DWORD system_error = ERROR_SUCCESS;
    do {
        reason = PrepareCommandExtraction(*header, wide_path, existing_approved, selected_by_dialog, system_error);
        if (reason == 0) reason = PrepareCommandParentDirectory(wide_path, selected_by_dialog);
        // 選び直した名前は存在・日時・保護属性・親を再評価する。元の項目を再列挙しない。
        if (reason == COMMAND_EXTRACTION_RENAMED) unicode_path = selected_by_dialog = true;
    } while (reason == COMMAND_EXTRACTION_RENAMED);
    // C++ の一時オブジェクトを破棄してから、C の呼び出し元で共通 cleanup へ移る。
    if (reason < 0) return -1;
    if (reason > 0 && g_command_update_policy.stop_on_extract_error == 2) {
        const int codes[] = {0, ERROR_ALREADY_EXIST, ERROR_MORE_FRESH, ERROR_MORE_FRESH,
            ERROR_MORE_FRESH, ERROR_NOT_EXIST, ERROR_READ_ONLY, ERROR_UNKNOWN_TYPE, ERROR_USER_SKIP};
        if (reason < static_cast<int>(_countof(codes))) {
            RecordCommandExtractionFailure(codes[reason], wide_path, reason == 8 ? ERROR_CANCELLED : system_error);
            return -1;
        }
    }
    if (reason != 0) Lha_RecordHeaderCommandEvent("Skipped", header, reason);
    else {
        const std::string selected = unicode_path ? RegisterUnicodeExtractionPath(wide_path)
                                                 : WStringToString(wide_path);
        if (selected.size() >= path_size) return FALSE;
        // A 通知による代替文字や別名保存にかかわらず、ログには元の書庫内名を使う。
        g_command_renamed_destination = selected;
        g_command_renamed_member = g_unicode_mode.load()
            ? HeaderNameToString(*header, ConfiguredArchiveCodePage()) : header->name;
        g_command_renamed_member_w = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
        strcpy_s(path, path_size, selected.c_str());
        // -m2 による自動採番後の保存先を、後続の進捗通知にも反映する。
        Lha_SetProgressDestination(path);
        if (g_command_update_policy.restore_attributes) {
            g_command_metadata_path = selected;
            g_command_metadata_attributes = static_cast<DWORD>(HeaderAttributes(*header));
        }
    }
    return reason == 0 ? (existing_approved ? 2 : 1) : 0;
}

extern "C" int Lha_PrepareCommandDirectoryExtraction(const char* path) {
    if (!path) return 0;
    std::wstring requested = FilePathToWide(path);
    const int reason = PrepareCommandParentDirectory(requested);
    // 明示ディレクトリ項目では原版も別名を作成せず、この項目の処理を終える。
    return reason < 0 ? -1 : reason == 0 ? 1 : 0;
}

extern "C" int Lha_CommandChecksDiskSpace() {
    return g_command_update_policy.check_disk_space ? TRUE : FALSE;
}

static std::wstring CommandDiskSpaceErrorMessage() {
    return UseEnglishDialogResources() ? L"Not enough disk space." : L"ディスクの空きがありません";
}

extern "C" int Lha_CheckCommandDiskSpace(const LzHeader* header, const char* path) {
    if (!header || !path || !g_command_update_policy.check_disk_space) return 1;
    const std::wstring destination = FilePathToWide(path);
    wchar_t absolute[32768]{};
    wchar_t* leaf = nullptr;
    const DWORD length = GetFullPathNameW(destination.c_str(), _countof(absolute), absolute, &leaf);
    if (!length || length >= _countof(absolute) || !leaf) return 1;
    *leaf = L'\0';
    ULARGE_INTEGER available{};
    // 呼び出し元に利用可能な容量を使う。作業ディレクトリを変更せず、Unicode の親を照会する。
    if (!GetDiskFreeSpaceExW(absolute, &available, nullptr, nullptr)) return 1;
    WIN32_FILE_ATTRIBUTE_DATA existing{};
    ULONGLONG credit = 0;
    if (GetFileAttributesExW(destination.c_str(), GetFileExInfoStandard, &existing) &&
        !(existing.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
        credit = (static_cast<ULONGLONG>(existing.nFileSizeHigh) << 32) | existing.nFileSizeLow;
    const ULONGLONG incoming = header->original_size > 0 ? static_cast<ULONGLONG>(header->original_size) : 0;
    const ULONGLONG required = incoming + g_command_update_policy.reserved_disk_space;
    const ULONGLONG usable = available.QuadPart + credit;
    // 加算の桁上がりを保持し、巨大な予約容量を小さな必要量として扱わない。
    const bool required_carry = required < incoming;
    const bool usable_carry = usable < available.QuadPart;
    if (required_carry < usable_carry || (required_carry == usable_carry && required <= usable)) return 1;
    const bool english = UseEnglishDialogResources();
    const std::wstring member = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
    const std::wstring question = english ? L"Not enoough disk space for '" + member + L"'\r\nContinue?"
        : L"'" + member + L"' を展開するための空きがありません。\r\n処理を続けますか？";
    const int answer = g_command_update_policy.suppress_errors ? IDNO : MessageBoxW(g_hwndOwner,
        question.c_str(), english ? L"UNLHA32 Warning report" : L"UNLHA32 警告",
        MB_TASKMODAL | MB_ICONQUESTION | MB_YESNOCANCEL);
    if (answer == IDYES) return 1;
    if (answer != IDCANCEL) {
        Lha_RecordHeaderCommandEvent("Skipped", header, 10);
        return 0;
    }
    g_command_disk_space_failure_path = destination;
    std::replace(g_command_disk_space_failure_path.begin(), g_command_disk_space_failure_path.end(), L'\\', L'/');
    const std::wstring report = CommandDiskSpaceErrorMessage() + L" : '" + g_command_disk_space_failure_path + L"'";
    MessageBoxW(nullptr, report.c_str(), english ? L"UNLHA32 Error report (on extractsub)"
        : L"UNLHA32 エラー報告 (on extractsub)", MB_TASKMODAL | MB_ICONERROR);
    // longjmp は一時オブジェクトの破棄後、C の呼び出し元で行う。
    return -1;
}

extern "C" int Lha_HandleCommandCreateFailure(const LzHeader* header, const char* path) {
    unsigned long system_error = 0;
    _get_doserrno(&system_error);
    if (!system_error) system_error = GetLastError();
    if (!g_command_update_policy.stop_on_extract_error) {
        Lha_RecordHeaderCommandEvent("Skipped", header, 11);
        return 0;
    }
    RecordCommandExtractionFailure(ERROR_FILE_OPEN, FilePathToWide(path), system_error, L"extractsub", true);
    // C++ の一時オブジェクトを破棄してから C 側の共通 cleanup で終了する。
    return 1;
}

extern "C" void Lha_HandleCommandDirectoryFailure(const char* path) {
    unsigned long system_error = 0;
    _get_doserrno(&system_error);
    if (!system_error) system_error = GetLastError();
    RecordCommandExtractionFailure(ERROR_MAKEDIRECTORY, FilePathToWide(path), system_error, L"CheckDirectory", true);
}

extern "C" void Lha_RestoreCommandDirectoryMetadata(const LzHeader* header, const char* path) {
    if (!header || !path) return;
    const std::wstring wide_path = FilePathToWide(path);
    // 原版は命令開始より新しい作成日時を持つディレクトリだけを復元する。
    // 子項目が先に作った親にも適用し、開始前からある古いディレクトリは保持する。
    HANDLE directory = CreateFileW(wide_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                   OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_ATTRIBUTE_NORMAL, nullptr);
    if (directory == INVALID_HANDLE_VALUE) return;
    FILETIME existing_create{};
    const bool restore = GetFileTime(directory, &existing_create, nullptr, nullptr) &&
        CompareFileTime(&existing_create, &g_command_started_at) > 0;
    if (restore) {
        const FILETIME create = HeaderExtractionTime(*header, MemberTimeKind::Create);
        const FILETIME access = HeaderExtractionTime(*header, MemberTimeKind::Access);
        const FILETIME write = HeaderExtractionTime(*header, MemberTimeKind::Write);
        SetFileTime(directory, &create, &access, &write);
    }
    CloseHandle(directory);
    if (!restore) return;
    const DWORD attributes = g_command_update_policy.restore_attributes
        ? static_cast<DWORD>(HeaderAttributes(*header)) : FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_ARCHIVE;
    SetFileAttributesW(wide_path.c_str(), attributes);
}

struct ProgressMetadata final {
    ULHA_INT64 legacy_file_size = 0;
    ULHA_INT64 file_size = 0;
    ULHA_INT64 compressed_size = 0;
    ULHA_INT64 write_size = 0;
    DWORD attributes = 0;
    DWORD crc = 0;
    UINT os_type = 0;
    WORD ratio = 0;
    WORD date = 0;
    WORD time = 0;
    FILETIME create_time{};
    FILETIME access_time{};
    FILETIME write_time{};
    std::string attribute_text;
    std::string method;
    std::string source_a;
    std::string destination_a;
    std::wstring attribute_text_w;
    std::wstring method_w;
    std::wstring source_w;
    std::wstring destination_w;
};

static std::wstring ProgressDestinationToWide(const LzHeader* header, const char* destination) {
    if (!destination || !*destination) return std::wstring();
    if (UsesUnicodeFilePath(destination)) return FilePathToWide(destination);
    const std::string raw_destination(destination);
    if (header && *header->name) {
        const std::string raw_member(header->name);
        if (raw_destination.size() >= raw_member.size() &&
            raw_destination.compare(raw_destination.size() - raw_member.size(),
                                    raw_member.size(), raw_member) == 0) {
            const std::string prefix = raw_destination.substr(0, raw_destination.size() - raw_member.size());
            return FilePathToWide(prefix.c_str()) +
                   HeaderNameToWString(*header, ConfiguredArchiveCodePage());
        }
    }
    return FilePathToWide(destination);
}

static std::string DosAttributeText(const DWORD attributes) {
    char attribute_buffer[5]{};
    attribute_buffer[0] = (attributes & FA_ARCH) ? 'A' : '-';
    attribute_buffer[1] = (attributes & FA_SYSTEM) ? 'S' : '-';
    attribute_buffer[2] = (attributes & FA_HIDDEN) ? 'H' : '-';
    attribute_buffer[3] = (attributes & FA_RDONLY) ? 'R' : 'W';
    return attribute_buffer;
}

static void UnixTimeToDosTime(const time_t value, WORD& date, WORD& time) {
    struct tm local{};
    if (localtime_s(&local, &value) != 0) return;
    // 59 秒の切り上げは、分だけでなく日・月・年の繰り上がりも含めて変換する。
    if (local.tm_sec & 1) {
        const time_t rounded = value + 1;
        if (localtime_s(&local, &rounded) != 0) return;
    }
    if (local.tm_year < 80) return;
    date = static_cast<WORD>(((local.tm_year - 80) << 9) |
                             ((local.tm_mon + 1) << 5) | local.tm_mday);
    time = static_cast<WORD>((local.tm_hour << 11) | (local.tm_min << 5) |
                             (local.tm_sec / 2));
}

static ProgressMetadata MakeProgressMetadata(const LzHeader* header, const char* source,
                                              const char* destination, const ULHA_INT64 write_size,
                                              const ULHA_INT64 total_size) {
    ProgressMetadata result;
    bool source_is_path = false;
    result.write_size = write_size;
    if (header) {
        result.file_size = header->original_size;
        result.compressed_size = header->packed_size;
        result.attributes = static_cast<DWORD>(HeaderAttributes(*header));
        result.crc = static_cast<DWORD>(header->crc);
        result.os_type = HeaderOsType(*header);
        result.ratio = HeaderRatio(*header);
        result.create_time = HeaderTimeToFileTime(*header, MemberTimeKind::Create);
        result.access_time = HeaderTimeToFileTime(*header, MemberTimeKind::Access);
        result.write_time = HeaderTimeToFileTime(*header, MemberTimeKind::Write);
        result.method.assign(header->method, METHOD_TYPE_STORAGE);
        result.source_w = HeaderNameToWString(*header, ConfiguredArchiveCodePage());
        result.source_a = HeaderNameToString(*header, ConfiguredArchiveCodePage());
        if (source && strcmp(source, header->name) != 0) {
            result.source_a = source;
            result.source_w = FilePathToWide(source);
            source_is_path = true;
        }
        UnixTimeToDosTime(header->unix_last_modified_stamp, result.date, result.time);
    } else {
        result.source_a = source ? source : "";
        result.source_w = FilePathToWide(source);
        source_is_path = source && *source;
    }
    result.legacy_file_size = total_size > 0 ? total_size : result.file_size;
    // p/t の列挙情報には仮の展開先名があるが、実ファイルを作らない進捗情報は空欄になる。
    if (g_enum_command != UNLHA_PRINT_COMMAND && g_enum_command != UNLHA_TEST_COMMAND) {
        result.destination_w = g_progress_destination_w_active
            ? g_progress_destination_w : ProgressDestinationToWide(header, destination);
    }
    if (g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND) {
        // 圧縮の通知先は原版と同じ区切りにする。ANSI の多バイト文字内の 0x5c は変更しない。
        std::replace(result.destination_w.begin(), result.destination_w.end(), L'\\', L'/');
    }
    if (g_enum_command == UNLHA_JOINT_COMMAND) {
        // j の SEARCH/OPEN/COPY は、メンバー名ではなく実パスだけを '/' で通知する。
        if (source_is_path) std::replace(result.source_w.begin(), result.source_w.end(), L'\\', L'/');
        std::replace(result.destination_w.begin(), result.destination_w.end(), L'\\', L'/');
        result.source_a = WStringToString(result.source_w);
    }
    result.destination_a = WStringToString(result.destination_w);
    if (g_wide_command_utf8_input) {
        result.source_a = WideStringToMultiByte(result.source_w, CallbackCodePage());
        result.destination_a = WideStringToMultiByte(result.destination_w, CallbackCodePage());
    }
    if (header) result.attribute_text = DosAttributeText(result.attributes);
    result.attribute_text_w = ArchiveStringToWString(result.attribute_text, 932);
    result.method_w = ArchiveStringToWString(result.method, 932);
    return result;
}

static void FillBasicProgress(EXTRACTINGINFOA& info, const ProgressMetadata& metadata) {
    info.dwFileSize = static_cast<DWORD>(metadata.legacy_file_size);
    info.dwWriteSize = static_cast<DWORD>(metadata.write_size);
    strncpy_s(info.szSourceFileName, metadata.source_a.c_str(), _TRUNCATE);
    strncpy_s(info.szDestFileName, metadata.destination_a.c_str(), _TRUNCATE);
}

static void FillBasicProgress(EXTRACTINGINFOW& info, const ProgressMetadata& metadata) {
    info.dwFileSize = static_cast<DWORD>(metadata.legacy_file_size);
    info.dwWriteSize = static_cast<DWORD>(metadata.write_size);
    wcsncpy_s(info.szSourceFileName, metadata.source_w.c_str(), _TRUNCATE);
    wcsncpy_s(info.szDestFileName, metadata.destination_w.c_str(), _TRUNCATE);
}

template<typename T>
static void FillExtendedProgressCommon(T& info, const ProgressMetadata& metadata) {
    info.dwAttributes = metadata.attributes;
    info.dwCRC = metadata.crc;
    info.uOSType = metadata.os_type;
    info.wRatio = metadata.ratio;
    info.ftCreateTime = metadata.create_time;
    info.ftAccessTime = metadata.access_time;
    info.ftWriteTime = metadata.write_time;
}

static BOOL InvokeProgressReceiver(const UINT state, LPVOID info, const bool wide) {
    if (g_uMsgArcExtract == 0) {
        g_uMsgArcExtract = RegisterWindowMessageA(WM_ARCEXTRACT);
        if (g_uMsgArcExtract == 0) return TRUE;
    }
    if (g_lpArcProc) {
        return g_lpArcProc(g_hwndOwner, g_uMsgArcExtract, state, info);
    }
    const LRESULT result = wide
        ? SendMessageW(g_progressWindow, g_uMsgArcExtract, static_cast<WPARAM>(state), reinterpret_cast<LPARAM>(info))
        : SendMessageA(g_progressWindow, g_uMsgArcExtract, static_cast<WPARAM>(state), reinterpret_cast<LPARAM>(info));
    return result == 0 ? TRUE : FALSE;
}

extern "C" int Lha_DispatchCompatProgress(const int state, const LzHeader* header,
                                             const char* source, const char* destination,
                                             const __int64 current_size,
                                             const __int64 total_size, const int os_override) {
    if (!g_command_progress_enabled || (!g_progressWindow && !g_lpArcProc) ||
        g_owner_progress_layout == OwnerProgressLayout::None) {
        return 0;
    }
    const bool wide = g_owner_progress_layout == OwnerProgressLayout::BasicW ||
                      g_owner_progress_layout == OwnerProgressLayout::ExW ||
                      g_owner_progress_layout == OwnerProgressLayout::Ex32W ||
                      g_owner_progress_layout == OwnerProgressLayout::Ex64W;
    if (state == ARCEXTRACT_END) {
        const BOOL result = InvokeProgressReceiver(static_cast<UINT>(state), nullptr, wide);
        return (!result && state != ARCEXTRACT_COPY) ? 1 : 0;
    }

    if (!g_memory_extracting && state == ARCEXTRACT_INPROCESS && header && current_size == 0 && total_size > 0 &&
        (g_enum_command == UNLHA_EXTRACT_COMMAND || g_enum_command == UNLHA_PRINT_COMMAND ||
         g_enum_command == UNLHA_TEST_COMMAND)) {
        const bool stored = memcmp(header->method, LZHUFF0_METHOD, 5) == 0 ||
                            memcmp(header->method, LARC4_METHOD, 5) == 0;
        // 原版の格納方式は size / 100 が 0 の場合だけ開始時に 0 を通知する。
        // 圧縮方式の復号にはこの開始時通知がなく、空項目の終了通知は別に保持する。
        if (!stored || header->original_size >= 100) return 0;
    }

    ProgressMetadata metadata = MakeProgressMetadata(header, source, destination,
                                                      current_size, total_size);
    if (state == 5 /* ARCEXTRACT_SEARCH */ && !header && source &&
        !g_unicode_mode.load() && !g_wide_command_utf8_input &&
        (g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND)) {
        // 非 Unicode の圧縮入力列挙名だけは FindFirstFileA が返すシステム ACP の生バイトである。
        // Unicode の GlobUnicode / W の UTF-8 入力を CP_ACP として再解釈してはならない。
        metadata.source_w = MultiByteStringToWide(source, CP_ACP);
    }
    // n/y の置換段階だけ、拡張情報のサイズは最後の圧縮本文長になる。
    if ((g_enum_command == UNLHA_RENAME_COMMAND || g_enum_command == UNLHA_CONVERT_COMMAND) &&
        g_rewrite_progress_member_transformed && destination && *destination &&
        (state == ARCEXTRACT_COPY || state == ARCEXTRACT_INPROCESS)) {
        metadata.file_size = metadata.compressed_size;
    }
    if (header && os_override >= 0) metadata.os_type = static_cast<UINT>(os_override);
    BOOL result = TRUE;
    switch (g_owner_progress_layout) {
    case OwnerProgressLayout::BasicA: {
        EXTRACTINGINFOA info{};
        FillBasicProgress(info, metadata);
        result = InvokeProgressReceiver(state, &info, false);
        break;
    }
    case OwnerProgressLayout::BasicW: {
        EXTRACTINGINFOW info{};
        FillBasicProgress(info, metadata);
        result = InvokeProgressReceiver(state, &info, true);
        break;
    }
    case OwnerProgressLayout::ExA: {
        EXTRACTINGINFOEXA info{};
        FillBasicProgress(info.exinfo, metadata);
        info.dwCompressedSize = static_cast<DWORD>(metadata.compressed_size);
        info.dwCRC = metadata.crc;
        info.uOSType = metadata.os_type;
        info.wRatio = metadata.ratio;
        info.wDate = metadata.date;
        info.wTime = metadata.time;
        strncpy_s(info.szAttribute, metadata.attribute_text.c_str(), _TRUNCATE);
        strncpy_s(info.szMode, metadata.method.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, false);
        break;
    }
    case OwnerProgressLayout::ExW: {
        EXTRACTINGINFOEXW info{};
        FillBasicProgress(info.exinfo, metadata);
        info.dwCompressedSize = static_cast<DWORD>(metadata.compressed_size);
        info.dwCRC = metadata.crc;
        info.uOSType = metadata.os_type;
        info.wRatio = metadata.ratio;
        info.wDate = metadata.date;
        info.wTime = metadata.time;
        wcsncpy_s(info.szAttribute, metadata.attribute_text_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szMode, metadata.method_w.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, true);
        break;
    }
    case OwnerProgressLayout::Ex32A: {
        EXTRACTINGINFOEX32A info{};
        info.dwStructSize = sizeof(info);
        FillBasicProgress(info.exinfo, metadata);
        info.dwFileSize = static_cast<DWORD>(metadata.file_size);
        info.dwCompressedSize = static_cast<DWORD>(metadata.compressed_size);
        info.dwWriteSize = static_cast<DWORD>(metadata.write_size);
        FillExtendedProgressCommon(info, metadata);
        strncpy_s(info.szMode, metadata.method.c_str(), _TRUNCATE);
        strncpy_s(info.szSourceFileName, metadata.source_a.c_str(), _TRUNCATE);
        strncpy_s(info.szDestFileName, metadata.destination_a.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, false);
        break;
    }
    case OwnerProgressLayout::Ex32W: {
        EXTRACTINGINFOEX32W info{};
        info.dwStructSize = sizeof(info);
        FillBasicProgress(info.exinfo, metadata);
        info.dwFileSize = static_cast<DWORD>(metadata.file_size);
        info.dwCompressedSize = static_cast<DWORD>(metadata.compressed_size);
        info.dwWriteSize = static_cast<DWORD>(metadata.write_size);
        FillExtendedProgressCommon(info, metadata);
        wcsncpy_s(info.szMode, metadata.method_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szSourceFileName, metadata.source_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szDestFileName, metadata.destination_w.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, true);
        break;
    }
    case OwnerProgressLayout::Ex64A: {
        EXTRACTINGINFOEX64A info{};
        info.dwStructSize = sizeof(info);
        FillBasicProgress(info.exinfo, metadata);
        info.llFileSize = metadata.file_size;
        info.llCompressedSize = metadata.compressed_size;
        info.llWriteSize = metadata.write_size;
        FillExtendedProgressCommon(info, metadata);
        strncpy_s(info.szMode, metadata.method.c_str(), _TRUNCATE);
        strncpy_s(info.szSourceFileName, metadata.source_a.c_str(), _TRUNCATE);
        strncpy_s(info.szDestFileName, metadata.destination_a.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, false);
        break;
    }
    case OwnerProgressLayout::Ex64W: {
        EXTRACTINGINFOEX64W info{};
        info.dwStructSize = sizeof(info);
        FillBasicProgress(info.exinfo, metadata);
        info.llFileSize = metadata.file_size;
        info.llCompressedSize = metadata.compressed_size;
        info.llWriteSize = metadata.write_size;
        FillExtendedProgressCommon(info, metadata);
        wcsncpy_s(info.szMode, metadata.method_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szSourceFileName, metadata.source_w.c_str(), _TRUNCATE);
        wcsncpy_s(info.szDestFileName, metadata.destination_w.c_str(), _TRUNCATE);
        result = InvokeProgressReceiver(state, &info, true);
        break;
    }
    default:
        return 0;
    }
    const bool compression = g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND;
    if (compression && state == ARCEXTRACT_COPY) g_command_compression_copy_progress = true;
    // 原版は COPY に入った後の本文通知では、FALSE でも書庫の置換を完了する。
    if (compression && state == ARCEXTRACT_INPROCESS && g_command_compression_copy_progress) return 0;
    if (!result && state != ARCEXTRACT_COPY) {
        g_command_progress_cancel_state = state;
        if (state == ARCEXTRACT_INPROCESS && header &&
            (g_enum_command == UNLHA_EXTRACT_COMMAND || g_enum_command == UNLHA_PRINT_COMMAND ||
             g_enum_command == UNLHA_TEST_COMMAND)) {
            // 原版は本文の最初の通知で中断しても、処理中の項目行を残す。
            const char* action = g_enum_command == UNLHA_TEST_COMMAND ? "Tested" : "Melted";
            Lha_RecordCommandEvent(action, destination ? destination : source, 0);
        }
        if (((state == ARCEXTRACT_OPEN || state == ARCEXTRACT_BEGIN || state == ARCEXTRACT_INPROCESS) &&
            (g_enum_command == UNLHA_EXTRACT_COMMAND || g_enum_command == UNLHA_PRINT_COMMAND ||
             g_enum_command == UNLHA_TEST_COMMAND)) ||
            (compression && (state == ARCEXTRACT_OPEN || state == ARCEXTRACT_BEGIN ||
                             state == ARCEXTRACT_INPROCESS || state == 5 || state == 6))) {
            // 原版は報告への応答を待ってから入力・出力を解放する。
            ReportCommandCancellation();
        }
    }
    return (!result && state != ARCEXTRACT_COPY) ? 1 : 0;
}

// LhaCoreのcallback.cで定義されているキャプチャ用グローバル変数への参照
extern "C" {
    extern volatile char* g_capture_buffer;
    extern volatile size_t g_capture_buffer_size;
    extern volatile size_t g_capture_buffer_written;
}


// ライブラリレベルの終了呼び出しを処理するためのジャンプバッファ
jmp_buf g_lha_exit_jmp_buf;
int g_lha_exit_jmp_enabled = 0;
static thread_local jmp_buf* g_lha_scoped_exit = nullptr;

std::wstring g_last_error;

extern "C" {
    void set_lha_error(const char* msg) {
        if (!msg) return;
        if (strncmp(msg, "file read error", 15) == 0)
            g_command_read_failure = CommandReadFailure::CopyFile;
        else if (strncmp(msg, "cannot read stream", 18) == 0)
            g_command_read_failure = CommandReadFailure::FillBuffer;
        int size_needed = MultiByteToWideChar(CP_UTF8, 0, msg, -1, NULL, 0);
        std::wstring wstrTo(size_needed, 0);
        MultiByteToWideChar(CP_UTF8, 0, msg, -1, &wstrTo[0], size_needed);
        g_last_error = wstrTo;
    }

    void set_lha_error_invalid_char(const char* filename_sjis) {
        if (!filename_sjis) return;
        std::wstring nameW = StringToWString(filename_sjis);
		g_last_error = L"ファイル名にShift_JISに変換できない文字が含まれています: " + nameW;
	}
}

extern "C" void lha_exit_handler(int status) {
    if (g_lha_scoped_exit) {
        longjmp(*g_lha_scoped_exit, status == 0 ? -1 : status);
    }
    /* テンポラリファイルなどのリソースをクリーンアップ */
    cleanup();
    g_lha_exit_status = status;
    if (g_lha_exit_jmp_enabled) {
        longjmp(g_lha_exit_jmp_buf, status == 0 ? -1 : status);
    }
}

static int g_command_dictionary_bits = 0;

extern "C" {
    int Lha_GetDictionaryBits() { return g_command_dictionary_bits; }
    HWND Lha_GetHwndOwner() { return g_hwndOwner; }
    HWND Lha_GetProgressWindow() { return g_progressWindow; }
    BOOL Lha_IsMemoryExtracting() { return g_memory_extracting ? TRUE : FALSE; }
    UINT Lha_GetArchiveCodePage() { return ConfiguredArchiveCodePage(); }
    BYTE Lha_GetCommonHeaderFlags() {
        TIME_ZONE_INFORMATION zone{};
        const DWORD mode = GetTimeZoneInformation(&zone);
        LONG bias = zone.Bias;
        if (mode == TIME_ZONE_ID_DAYLIGHT) bias += zone.DaylightBias;
        else if (mode == TIME_ZONE_ID_STANDARD) bias += zone.StandardBias;
        const LONG encoded = 16 + bias / 60;
        return encoded >= 0 && encoded <= 31 ? static_cast<BYTE>(encoded) : 0;
    }
    UINT Lha_GetMsgArcExtract() { return g_uMsgArcExtract; }
    void Lha_SetMsgArcExtract(UINT u) { g_uMsgArcExtract = u; }
    LHA_ARCHIVERPROC Lha_GetArcProc() { return g_lpArcProc; }
    BOOL Lha_GetEnableTotalProgress() { return g_bEnableTotalProgress; }
}

extern "C" {

#undef Unlha
#undef UnlhaCheckArchive
#undef UnlhaConfigDialog
#undef UnlhaGetFileCount
#undef UnlhaOpenArchive
#undef UnlhaFindFirst
#undef UnlhaFindNext
#undef UnlhaGetArcFileName
#undef UnlhaSetOwnerWindow
#undef UnlhaClearOwnerWindow
#undef UnlhaSetOwnerWindowEx
#undef UnlhaKillOwnerWindowEx

WORD WINAPI UnlhaGetVersion() {
    return 300;
}

BOOL WINAPI UnlhaGetRunning() {
    return IsDllRunning();
}

// PEファイルの物理サイズ（セクションデータの終端）を計算する
static DWORD GetExeSize(FILE* fp) {
    if (!fp) return 0;
    
    // ファイルサイズの取得
    _fseeki64(fp, 0, SEEK_END);
    __int64 fileSize = _ftelli64(fp);
    if (fileSize < sizeof(IMAGE_DOS_HEADER)) {
        return 0;
    }
    
    IMAGE_DOS_HEADER dosHeader;
    if (fseek(fp, 0, SEEK_SET) != 0) return 0;
    if (fread(&dosHeader, sizeof(dosHeader), 1, fp) != 1) return 0;
    if (dosHeader.e_magic != IMAGE_DOS_SIGNATURE) return 0; // 'MZ'
    
    // e_lfanew が妥当かチェック
    if (dosHeader.e_lfanew < 0 || dosHeader.e_lfanew + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) > (ULONGLONG)fileSize) {
        return 0;
    }
    
    // PEシグネチャのチェック
    DWORD peSignature;
    if (fseek(fp, dosHeader.e_lfanew, SEEK_SET) != 0) return 0;
    if (fread(&peSignature, sizeof(peSignature), 1, fp) != 1) return 0;
    if (peSignature != IMAGE_NT_SIGNATURE) return 0; // 'PE\0\0'
    
    // FileHeaderの読み込み
    IMAGE_FILE_HEADER fileHeader;
    if (fread(&fileHeader, sizeof(fileHeader), 1, fp) != 1) return 0;
    
    // セクションテーブルの開始位置
    // PEシグネチャ(4バイト) + IMAGE_FILE_HEADER(20バイト) + SizeOfOptionalHeader
    DWORD sectionOffset = dosHeader.e_lfanew + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) + fileHeader.SizeOfOptionalHeader;
    
    // セクションテーブル全体がファイルサイズに収まっているかチェック
    if (sectionOffset + (DWORD)fileHeader.NumberOfSections * sizeof(IMAGE_SECTION_HEADER) > (ULONGLONG)fileSize) {
        return 0;
    }
    
    DWORD exeSize = 0;
    for (WORD i = 0; i < fileHeader.NumberOfSections; ++i) {
        IMAGE_SECTION_HEADER sectionHeader;
        if (fseek(fp, sectionOffset + i * sizeof(IMAGE_SECTION_HEADER), SEEK_SET) != 0) return 0;
        if (fread(&sectionHeader, sizeof(sectionHeader), 1, fp) != 1) return 0;
        
        DWORD sectionEnd = sectionHeader.PointerToRawData + sectionHeader.SizeOfRawData;
        if (sectionEnd > exeSize) {
            exeSize = sectionEnd;
        }
    }
    
    return exeSize;
}

#define CHECK_HEADER_SIZE           0
#define CHECK_HEADER_CHECKSUM       1
#define CHECK_METHOD                2
#define CHECK_ATTRIBUTE             19
#define CHECK_HEADER_LEVEL          20

static bool WidePathIsSfx(const wchar_t* path, FILE* file);

static bool ReadUnLhaReSfxFooter(FILE* file, UnLhaReSfxFooter* result) {
    if (!file) return false;
    const __int64 original_position = _ftelli64(file);
    bool valid = false;
    UnLhaReSfxFooter footer{};
    if (_fseeki64(file, 0, SEEK_END) == 0) {
        const __int64 signed_size = _ftelli64(file);
        if (signed_size >= static_cast<__int64>(sizeof(footer)) &&
            _fseeki64(file, signed_size - sizeof(footer), SEEK_SET) == 0 &&
            fread(&footer, 1, sizeof(footer), file) == sizeof(footer)) {
            const ULONGLONG file_size = static_cast<ULONGLONG>(signed_size);
            const ULONGLONG payload_end = file_size - sizeof(footer);
            valid = memcmp(footer.magic, kUnLhaReSfxFooterMagic,
                           sizeof(kUnLhaReSfxFooterMagic)) == 0 &&
                    footer.version == kUnLhaReSfxFooterVersion &&
                    footer.archiveOffset < footer.dllOffset &&
                    footer.archiveOffset <= payload_end &&
                    footer.archiveSize <= footer.dllOffset - footer.archiveOffset &&
                    footer.dllOffset <= payload_end &&
                    footer.dllSize <= payload_end - footer.dllOffset;
        }
    }
    _fseeki64(file, original_position >= 0 ? original_position : 0, SEEK_SET);
    if (valid && result) *result = footer;
    return valid;
}

static int DetectSfxType(FILE* file, const bool sfx_hint) {
    if (!file) return SFX_NOT;
    UnLhaReSfxFooter footer{};
    if (ReadUnLhaReSfxFooter(file, &footer) && footer.flavor != SFX_NOT) {
        return static_cast<int>(footer.flavor);
    }

    const __int64 original_position = _ftelli64(file);
    const DWORD executable_size = GetExeSize(file);
    _fseeki64(file, original_position >= 0 ? original_position : 0, SEEK_SET);
    if (executable_size != 0) {
        // UNLHA32 3.00.5 が生成する既知の WinSFX スタブ境界。
        if (executable_size == 0x0000F200UL) return SFX_WIN32_300_1;
        if (executable_size == 0x00014A00UL) return SFX_WIN32_213_3;
        return SFX_WIN32_UNKNOWN;
    }
    return sfx_hint ? SFX_DOS_UNKNOWN : SFX_NOT;
}

// fp の startOffset から最大 maxScanLength バイトの範囲で LZH ヘッダを探索する
static BOOL FindLhaHeaderLimit(FILE* fp, __int64 startOffset, ULONGLONG maxScanLength) {
    if (fseeko(fp, startOffset, SEEK_SET) != 0) return FALSE;
    
    unsigned char buf[4096];
    __int64 currentOffset = startOffset;
    const ULONGLONG unsigned_start = static_cast<ULONGLONG>(startOffset);
    const ULONGLONG unsigned_limit = unsigned_start + maxScanLength;
    if (unsigned_limit > static_cast<ULONGLONG>(INT64_MAX)) return FALSE;
    __int64 limitOffset = static_cast<__int64>(unsigned_limit);

    while (currentOffset < limitOffset) {
        __int64 remaining = limitOffset - currentOffset;
        size_t readSize = sizeof(buf);
        if ((__int64)readSize > remaining) {
            readSize = (size_t)remaining;
        }
        
        if (readSize < 24) {
            break;
        }

        if (fseeko(fp, currentOffset, SEEK_SET) != 0) {
            break;
        }

        size_t n = fread(buf, 1, readSize, fp);
        if (n < 24) {
            break;
        }

        for (size_t i = 0; i <= n - 24; ++i) {
            unsigned char* p = buf + i;
            if (p[CHECK_METHOD] == '-' &&
                (p[CHECK_METHOD + 1] == 'l' || p[CHECK_METHOD + 1] == 'p') &&
                p[CHECK_METHOD + 4] == '-') {

                // レベル0または1のヘッダ
                if ((p[CHECK_HEADER_LEVEL] == 0 || p[CHECK_HEADER_LEVEL] == 1)
                    && p[CHECK_HEADER_SIZE] > 20
                    && i + 2U + p[CHECK_HEADER_SIZE] <= n
                    && p[CHECK_HEADER_CHECKSUM] == calc_sum(p + 2, p[CHECK_HEADER_SIZE])) {
                    fseeko(fp, currentOffset + static_cast<__int64>(i), SEEK_SET);
                    return TRUE;
                }

                // レベル2のヘッダ
                if (p[CHECK_HEADER_LEVEL] == 2
                    && p[CHECK_HEADER_SIZE] >= 24
                    && p[CHECK_ATTRIBUTE] == 0x20) {
                    fseeko(fp, currentOffset + static_cast<__int64>(i), SEEK_SET);
                    return TRUE;
                }

                // level 3 は先頭 WORD がサイズフィールド幅 4 を表す。
                if (p[CHECK_HEADER_LEVEL] == 3 && p[CHECK_HEADER_SIZE] == 4
                    && p[CHECK_ATTRIBUTE] == 0x20) {
                    fseeko(fp, currentOffset + static_cast<__int64>(i), SEEK_SET);
                    return TRUE;
                }
            }
        }

        // レベル0/1のヘッダーは最大257バイト。チェックサム対象が境界をまたいでも再検査する。
        if (currentOffset + static_cast<__int64>(n) >= limitOffset || n < sizeof(buf)) break;
        currentOffset += (n - 256);
    }

    return FALSE;
}

static int MethodNumber(const char method[5]);
static bool ReadArchiveHeaderGuarded(FILE* archive, LzHeader& header);

static int DecodeArchiveMemberGuarded(FILE* archive, FILE* output, LzHeader& header,
                                      const int method, unsigned int* decoded_crc = nullptr,
                                      off_t* decoded_size = nullptr) {
    error_occurred = 0;
    dtext = nullptr;
    jmp_buf scope;
    jmp_buf* const previous_scope = g_lha_scoped_exit;
    g_lha_scoped_exit = &scope;
#pragma warning(push)
#pragma warning(disable: 4611)
    if (setjmp(scope) != 0) {
        g_lha_scoped_exit = previous_scope;
        free(dtext);
        dtext = nullptr;
        return error_occurred ? ERROR_HUFFMAN_CODE : ERROR_CANNOT_READ;
    }
    off_t read_size = 0;
    const unsigned int crc = decode_lzhuf(archive, output, header.original_size, header.packed_size,
                                         header.name, method, &read_size);
#pragma warning(pop)
    g_lha_scoped_exit = previous_scope;
    if (decoded_crc) *decoded_crc = crc;
    if (decoded_size) *decoded_size = read_size;
    return 0;
}

static uint32_t ReadLittleEndian(const unsigned char* data, const size_t width) {
    uint32_t value = 0;
    for (size_t index = 0; index < width; ++index) {
        value |= static_cast<uint32_t>(data[index]) << (index * 8U);
    }
    return value;
}

static bool HasForeignArchiveTail(FILE* file, const __int64 file_size, DWORD& system_error) {
    system_error = ERROR_SUCCESS;
    const __int64 position = _ftelli64(file);
    struct RestorePosition {
        FILE* file;
        __int64 position;
        ~RestorePosition() { if (position >= 0) _fseeki64(file, position, SEEK_SET); }
    } restore{file, position};
    // 元版は末尾 6 バイトを ZIP ディレクトリへの参照としても検査する。
    if (file_size < 6 || _fseeki64(file, file_size - 6, SEEK_SET) != 0) {
        system_error = ERROR_INVALID_PARAMETER;
        return false;
    }
    unsigned char footer[6]{};
    if (fread(footer, 1, sizeof(footer), file) != sizeof(footer)) {
        system_error = ERROR_HANDLE_EOF;
        return false;
    }
    if (footer[4] != 0 || footer[5] != 0) return false;
    const __int64 offset = ReadLittleEndian(footer, 4);
    if (offset > file_size || _fseeki64(file, offset, SEEK_SET) != 0) {
        system_error = ERROR_INVALID_PARAMETER;
        return false;
    }
    unsigned char signature[4]{};
    if (fread(signature, 1, sizeof(signature), file) != sizeof(signature)) {
        system_error = ERROR_HANDLE_EOF;
        return false;
    }
    return ReadLittleEndian(signature, 4) == 0x02014b50U;
}

static bool ValidateRawHeaderCrc(FILE* file, const __int64 header_start,
                                 const __int64 data_start,
                                 const unsigned char level) {
    if (level < 2) return true;
    if (header_start < 0 || data_start <= header_start ||
        static_cast<ULONGLONG>(data_start - header_start) > 16ULL * 1024ULL * 1024ULL) {
        return false;
    }
    const size_t header_size = static_cast<size_t>(data_start - header_start);
    const size_t size_width = level == 2 ? 2U : (level == 3 ? 4U : 0U);
    const size_t base_size = level == 2 ? 26U : (level == 3 ? 32U : 0U);
    const size_t next_size_offset = level == 2 ? 24U : 28U;
    if (size_width == 0 || header_size < base_size ||
        next_size_offset + size_width > header_size) {
        return false;
    }

    std::vector<unsigned char> raw(header_size);
    if (_fseeki64(file, header_start, SEEK_SET) != 0 ||
        fread(raw.data(), 1, raw.size(), file) != raw.size()) {
        _fseeki64(file, data_start, SEEK_SET);
        return false;
    }

    uint32_t extension_size = ReadLittleEndian(raw.data() + next_size_offset,
                                                size_width);
    size_t extension_offset = base_size;
    bool has_header_crc = false;
    unsigned int stored_crc = 0;
    while (extension_size != 0) {
        if (extension_size < 1U + size_width || extension_offset > raw.size() ||
            extension_size > raw.size() - extension_offset) {
            _fseeki64(file, data_start, SEEK_SET);
            return false;
        }
        if (raw[extension_offset] == 0) {
            if (extension_size < 3U + size_width) {
                _fseeki64(file, data_start, SEEK_SET);
                return false;
            }
            stored_crc = ReadLittleEndian(raw.data() + extension_offset + 1U, 2U);
            raw[extension_offset + 1U] = 0;
            raw[extension_offset + 2U] = 0;
            has_header_crc = true;
        }
        const size_t next_offset = extension_offset + extension_size - size_width;
        extension_size = ReadLittleEndian(raw.data() + next_offset, size_width);
        extension_offset = next_offset + size_width;
    }
    make_crctable();
    const unsigned int calculated_crc = calccrc(
        0, reinterpret_cast<char*>(raw.data()), static_cast<unsigned int>(raw.size()));
    _fseeki64(file, data_start, SEEK_SET);
    return !has_header_crc || stored_crc == calculated_crc;
}

static bool FindValidArchiveHeader(FILE* file, __int64 start, const __int64 file_size,
                                    const __int64 search_limit, LzHeader& header,
                                    __int64* header_offset = nullptr) {
    if (header_offset) *header_offset = -1;
    const __int64 limit = (std::min)(file_size, search_limit);
    if (start < 0 || limit < 2 || start > limit - 2) return false;
    // 原版の探索制限はヘッダー先頭の2バイトまで。残りのヘッダーは制限を越えて読み取れる。
    const __int64 read_limit = limit + (std::min)(static_cast<__int64>(256), file_size - limit);
    while (start <= limit - 2 && FindLhaHeaderLimit(file, start,
            static_cast<ULONGLONG>(read_limit - start))) {
        const __int64 header_start = _ftelli64(file);
        if (header_start < start || header_start > limit - 2) return false;
        if (ReadArchiveHeaderGuarded(file, header) && MethodNumber(header.method) >= 0 &&
            ValidateRawHeaderCrc(file, header_start, _ftelli64(file), header.header_level)) {
            if (header_offset) *header_offset = header_start;
            return true;
        }
        start = header_start + 1;
    }
    return false;
}

static bool g_command_header_validation = false;
static int g_command_header_error = 0;
static int g_command_header_warning = 0;
static DWORD g_command_header_system_error = ERROR_SUCCESS;

static bool ReadCompatibleCommandHeader(FILE* file, LzHeader& header,
                                        const bool first_header, int& read_error,
                                        bool* recovered = nullptr,
                                        bool* initial_missing_crc = nullptr,
                                        int* read_warning = nullptr) {
    const __int64 header_start = _ftelli64(file);
    const int previous_error = error_occurred;
    const size_t previous_output = g_capture_buffer_written;
    const bool parsed_header = get_header(file, &header) != FALSE;
    // 下の探索・状態確認の seek で消える前に、ヘッダー読み取りの末尾不足を保持する。
    const bool truncated_header = !parsed_header && feof(file) != 0;
    const auto discard_parser_warning = [&]() {
        error_occurred = previous_error;
        // p の本文バッファへ、判定済みの C コア警告・エラーを混入させない。
        if (g_capture_buffer && previous_output < g_capture_buffer_size) {
            g_capture_buffer_written = previous_output;
            g_capture_buffer[previous_output] = '\0';
        }
    };
    if (!parsed_header && !first_header) {
        const __int64 file_size = _filelengthi64(_fileno(file));
        if (header_start >= 0 && file_size >= 0) {
            if (header_start > file_size) {
                read_error = ERROR_SET_POINT;
            } else if (header_start == file_size) {
                if (read_warning) *read_warning = ERROR_NO_END_MARK;
            } else if (_fseeki64(file, header_start, SEEK_SET) == 0) {
                const int marker = fgetc(file);
                if (marker != 0 && marker != EOF) {
                    if (file_size - header_start == 1) {
                        if (read_warning) *read_warning = ERROR_INVALID_END_MARK;
                    } else if (file_size - header_start < 21 || truncated_header) {
                        read_error = ERROR_UNEXPECTED_EOF;
                    }
                }
            }
        }
        if (read_error != 0 || (read_warning && *read_warning != 0))
            discard_parser_warning();
        return false;
    }
    const bool initial_level0_without_crc = parsed_header && first_header &&
        header.header_level == 0 && !header.has_crc;
    if (initial_level0_without_crc && initial_missing_crc) *initial_missing_crc = true;
    if (initial_level0_without_crc) {
        read_error = ERROR_FILE_STYLE;
        return false;
    }
    if (parsed_header && !first_header && header.header_level == 0 && !header.has_crc) {
        read_error = ERROR_HDR_EXPLOIT;
        return false;
    }
    if (parsed_header && !initial_level0_without_crc && (header.header_level < 2 ||
        ValidateRawHeaderCrc(file, header_start, _ftelli64(file), header.header_level))) return true;

    // 初回の終端・短いヘッダーも初期探索へ戻す。途中の終端と CRC 不良は従来どおり停止する。
    discard_parser_warning();
    if (first_header) {
        const __int64 file_size = _filelengthi64(_fileno(file));
        const bool found = FindValidArchiveHeader(file, header_start + 1, file_size, file_size, header);
        discard_parser_warning();
        if (!found) read_error = ERROR_FILE_STYLE;
        else if (recovered) *recovered = true;
        return found;
    }
    read_error = ERROR_HEADER_CRC;
    return false;
}

extern "C" int Lha_ReadCommandHeader(FILE* file, LzHeader* header, const int first_header) {
    if (!g_command_header_validation) return get_header(file, header);
    if (first_header) {
        g_command_header_error = 0;
        g_command_header_warning = 0;
        g_command_header_system_error = ERROR_SUCCESS;
    }
    bool initial_missing_crc = false;
    const bool found = ReadCompatibleCommandHeader(file, *header, first_header != 0,
                                                   g_command_header_error, nullptr, &initial_missing_crc,
                                                   &g_command_header_warning);
    if (!found) g_command_header_system_error = g_command_header_error == ERROR_FILE_STYLE
        ? (initial_missing_crc ? ERROR_NO_MORE_FILES : ERROR_HANDLE_EOF) : ERROR_SUCCESS;
    if (!found && g_command_header_error != 0)
        Lha_RecordProgressHeaderError(header, HeaderOsType(*header));
    return found;
}

extern "C" int Lha_HasCommandHeaderError(void) { return g_command_header_error != 0; }

static bool InspectArchiveStreamForeignTail(FILE* file, bool& valid_lzh,
                                            __int64* valid_lzh_header_offset = nullptr) {
    valid_lzh = false;
    if (valid_lzh_header_offset) *valid_lzh_header_offset = -1;
    const __int64 original_position = _ftelli64(file);
    const __int64 file_size = _filelengthi64(_fileno(file));
    DWORD ignored_error = ERROR_SUCCESS;
    bool has_foreign_tail = HasForeignArchiveTail(file, file_size, ignored_error);
    if (has_foreign_tail) {
        // -jsg0 は LZH 書庫に付いた末尾だけを許可する。ZIP ディレクトリだけの入力は
        // 常に arccopy の形式エラーとする。
        make_crctable();
        LzHeader header{};
        __int64 header_offset = -1;
        valid_lzh = FindValidArchiveHeader(file, 0, file_size, file_size, header,
                                            &header_offset);
        if (valid_lzh && valid_lzh_header_offset) *valid_lzh_header_offset = header_offset;
    }
    // 拒否しない入力は後段の get_header が読み始められる位置を必ず保つ。
    if (original_position >= 0) _fseeki64(file, original_position, SEEK_SET);
    return has_foreign_tail;
}

static bool ArchiveStreamHasForeignTail(FILE* file) {
    bool valid_lzh = false;
    return InspectArchiveStreamForeignTail(file, valid_lzh) && valid_lzh;
}

static bool VerifyArchiveMemberCrc(FILE* file, LzHeader& header,
                                   const __int64 data_start, int* decoder_error = nullptr) {
    if (decoder_error) *decoder_error = 0;
    const int method = MethodNumber(header.method);
    if (method < 0) return false;
    // 原版は PMarc の本文を CRC 検査しない。復旧探索は本文内でなく次の宣言位置から始める。
    if (method == PMARC0_METHOD_NUM || method == PMARC2_METHOD_NUM) {
        _fseeki64(file, data_start + header.packed_size, SEEK_SET);
        return false;
    }
    if (method == LZHDIRS_METHOD_NUM) {
        // 原版はディレクトリーの本文 CRC を検査せず、宣言された次ヘッダーへ進む。
        return _fseeki64(file, data_start + header.packed_size, SEEK_SET) == 0;
    }
    if ((header.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_DIRECTORY) {
        return header.packed_size == 0;
    }

    const boolean saved_quiet = quiet;
    const boolean saved_verify_mode = verify_mode;
    const boolean saved_text_mode = text_mode;
    FILE* const saved_input = g_infp;
    FILE* const saved_output = g_outfp;
    quiet = TRUE;
    verify_mode = TRUE;
    text_mode = FALSE;
    make_crctable();
    g_infp = file;
    g_outfp = nullptr;
    Lha_SetProgressMember(&header);
    off_t read_size = 0;
    unsigned int crc = 0;
    const int decode_result = DecodeArchiveMemberGuarded(file, nullptr, header, method, &crc, &read_size);
    if (decoder_error) *decoder_error = decode_result;
    Lha_ClearProgressMember();
    g_infp = saved_input;
    g_outfp = saved_output;
    quiet = saved_quiet;
    verify_mode = saved_verify_mode;
    text_mode = saved_text_mode;
    if (decode_result != 0) {
        g_last_error_code = 0;
        g_last_system_error = ERROR_INVALID_DATA;
    }
    // 原版は復号結果と本文 CRC で判定する。消費量を管理しない LZ5 や末尾余白も受理する。
    const bool valid = decode_result == 0 && (!header.has_crc || crc == header.crc);
    if (_fseeki64(file, data_start + header.packed_size, SEEK_SET) != 0) {
        return false;
    }
    return valid;
}

static BOOL CheckArchiveStream(FILE* file, const bool, const int mode, int* file_count) {
    if (file_count) *file_count = 0;
    DWORD tail_error = ERROR_SUCCESS;
    const auto finish = [&tail_error](const BOOL result, const int error = 0,
                             const DWORD system = ERROR_NO_MORE_FILES) {
        g_last_error_code = error;
        g_last_system_error = system == ERROR_NO_MORE_FILES && tail_error != ERROR_SUCCESS
            ? tail_error : system;
        return result;
    };
    g_last_error_code = 0;
    g_last_system_error = ERROR_NO_MORE_FILES;
    if (!file || _fseeki64(file, 0, SEEK_END) != 0) return FALSE;
    const __int64 file_size = _ftelli64(file);
    const int base_mode = mode & 3;
    const bool verify_crc = base_mode == CHECKARCHIVE_FULLCRC;
    const bool recovery = (mode & CHECKARCHIVE_RECOVERY) != 0;
    const __int64 search_limit = base_mode == CHECKARCHIVE_RAPID && (mode & CHECKARCHIVE_ALL) == 0
        ? (std::min)(file_size, static_cast<__int64>(128 * 1024)) : file_size;
    LzHeader header{};
    if (!FindValidArchiveHeader(file, 0, file_size, search_limit, header)) {
        if (header.header_level >= 2)
            Lha_RecordProgressHeaderError(&header, HeaderOsType(header));
        return finish(FALSE, ERROR_FILE_STYLE, search_limit < file_size ? ERROR_NO_MORE_FILES : ERROR_HANDLE_EOF);
    }
    if ((mode & CHECKARCHIVE_ENDDATA) == 0 && HasForeignArchiveTail(file, file_size, tail_error))
        return finish(FALSE, ERROR_FILE_STYLE);
    bool first_header = true;
    size_t header_count = 0;
    while (true) {
        if (!first_header) {
            const __int64 header_start = _ftelli64(file);
            if (header_start < 0 || header_start > file_size) return finish(FALSE, 0, ERROR_INVALID_PARAMETER);
            const __int64 remaining = file_size - header_start;
            // 原版は2バイト未満を終端とし、共通ヘッダー21バイトの不足をシステムエラーに残す。
            const DWORD header_system = remaining < 21 ? ERROR_HANDLE_EOF : ERROR_NO_MORE_FILES;
            if (remaining < 2) {
                Lha_RecordProgressHeaderEnd();
                return finish(TRUE, 0, header_system);
            }
            const int marker = fgetc(file);
            if (marker == 0 || marker == EOF) {
                Lha_RecordProgressHeaderEnd();
                return finish(TRUE, 0, header_system);
            }
            if (_fseeki64(file, header_start, SEEK_SET) != 0) return finish(FALSE, 0, ERROR_INVALID_PARAMETER);
            const bool parsed_header = remaining >= 21 && ReadArchiveHeaderGuarded(file, header) &&
                MethodNumber(header.method) >= 0;
            if (!parsed_header || !ValidateRawHeaderCrc(file, header_start, _ftelli64(file), header.header_level)) {
                if (parsed_header && header.header_level >= 2)
                    Lha_RecordProgressHeaderError(&header, HeaderOsType(header));
                if (!recovery) return finish(FALSE, 0, header_system);
                if (!FindValidArchiveHeader(file, header_start + 1, file_size, file_size, header))
                    return finish(TRUE, 0, ERROR_HANDLE_EOF);
            }
        }
        first_header = false;
        Lha_RecordEnumHeader(&header);
        const __int64 data_start = _ftelli64(file);
        if (data_start < 0 || data_start > file_size || header.packed_size < 0 ||
            static_cast<ULONGLONG>(header.packed_size) >
                static_cast<ULONGLONG>(file_size - data_start)) {
            return finish(FALSE, verify_crc ? ERROR_CANNOT_READ : 0,
                           verify_crc ? ERROR_HANDLE_EOF : ERROR_INVALID_PARAMETER);
        }
        if (verify_crc) {
            int decoder_error = 0;
            if (!VerifyArchiveMemberCrc(file, header, data_start, &decoder_error)) {
                if (decoder_error != 0) return FALSE;
                if (!recovery) return finish(FALSE);
            }
        } else if (_fseeki64(file, data_start + header.packed_size, SEEK_SET) != 0) {
            return finish(FALSE, 0, ERROR_INVALID_PARAMETER);
        }
        ++header_count;
        if (file_count) *file_count = static_cast<int>(header_count);
        // RAPID は先頭 3 ヘッダーまでを確認するという公開契約。
        if (base_mode == CHECKARCHIVE_RAPID && header_count >= 3) return finish(TRUE);
    }
}

BOOL WINAPI UnlhaCheckArchive(LPCSTR _szFileName, int _iMode) {
    if (!_szFileName) return UnlhaCheckArchiveW(nullptr, _iMode);
    return UnlhaCheckArchiveW(StringToWString(_szFileName).c_str(), _iMode);
}

static BOOL CheckArchiveFileW(LPCWSTR _szFileName, const int _iMode, int* file_count) {
    const auto fail = [](const int error, const DWORD system) {
        g_last_error_code = error;
        g_last_system_error = system;
        return FALSE;
    };
    if (IsDllRunning()) return fail(ERROR_ALREADY_RUNNING, ERROR_BUSY);
    struct RunningScope {
        RunningScope() { g_running = true; }
        ~RunningScope() { g_running = false; }
    } running_scope;
    if (!_szFileName || !*_szFileName) return fail(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
    PrepareConfiguredCommandState(true);
    std::wstring file_name;
    if (*_szFileName == L'"') {
        // 原版は引用符付き入力を内部コマンドの先頭引数として読み、未閉鎖の引用符も受け入れる。
        bool quoted = false;
        for (const wchar_t* unit = _szFileName; *unit; ++unit) {
            if (*unit == L'"') { quoted = !quoted; continue; }
            if (!quoted && *unit <= L' ') break;
            file_name.push_back(*unit);
        }
    } else {
        file_name = _szFileName;
    }
    if (file_name.empty()) return fail(0, ERROR_INVALID_DATA);
    WIN32_FIND_DATAW item{};
    HANDLE find = FindFirstFileW(file_name.c_str(), &item);
    if (find == INVALID_HANDLE_VALUE) return fail(0, ERROR_FILE_NOT_FOUND);
    bool found_file = false;
    do {
        if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            found_file = true;
            break;
        }
    } while (FindNextFileW(find, &item));
    FindClose(find);
    if (!found_file) return fail(0, ERROR_FILE_NOT_FOUND);
    FILE* file = nullptr;
    if (_wfopen_s(&file, file_name.c_str(), L"rb") != 0 || !file)
        return fail(ERROR_ARC_FILE_OPEN, GetLastError());
    const int sfx_type = DetectSfxType(file, WidePathIsSfx(file_name.c_str(), file));
    BOOL result = CheckArchiveStream(file, sfx_type != SFX_NOT, _iMode, file_count);
    if (result && (_iMode & CHECKARCHIVE_SFX) != 0 && sfx_type != SFX_NOT) {
        result = static_cast<BOOL>(0x8000 + sfx_type);
    }
    fclose(file);
    return result;
}

BOOL WINAPI UnlhaCheckArchiveW(LPCWSTR file_name, int mode) {
    return CheckArchiveFileW(file_name, mode, nullptr);
}

static bool HasWildcard(const std::string& path) {
    return path.find('*') != std::string::npos || path.find('?') != std::string::npos;
}

static void SplitPath(const std::string& fullPath, std::string& dir, std::string& pattern) {
    size_t lastSlash = fullPath.find_last_of("\\/");
    if (lastSlash == std::string::npos) {
        dir = "";
        pattern = fullPath;
    } else {
        dir = fullPath.substr(0, lastSlash + 1);
        pattern = fullPath.substr(lastSlash + 1);
    }
}

extern "C++" {
static std::string NormalizeCompressionDots(const std::string& path, const bool search) {
    std::string result;
    bool boundary = true;
    for (size_t index = 0; index < path.size();) {
        const char unit = path[index];
        if (unit == '*' || unit == '?') {
            result.append(path, index, std::string::npos);
            break;
        }
        if (boundary && unit == '.') {
            const size_t dots = index + 1 < path.size() && path[index + 1] == '.' ? 2 : 1;
            const size_t after = index + dots;
            if (after == path.size() || path[after] == '/' || path[after] == '\\') {
                // 原版は検索時に .. の直後の区切りだけを落とし、読み取り時は .. 自体を落とす。
                if (dots == 2 && search) result += "..";
                index = after < path.size() ? after + 1 : after;
                continue;
            }
        }
        const size_t width = IsInputLeadByte(static_cast<BYTE>(unit)) && index + 1 < path.size() ? 2 : 1;
        result.append(path, index, width);
        boundary = width == 1 && (unit == '/' || unit == '\\' || unit == ':');
        index += width;
    }
    return result;
}

static std::string CompressionMemberName(std::string path) {
    for (size_t index = 0; index < path.size(); ++index) {
        if (IsInputLeadByte(static_cast<BYTE>(path[index])) && index + 1 < path.size()) ++index;
        else if (path[index] == '\\') path[index] = '/';
    }
    if (!path.empty()) {
        char canonical[FILENAME_LENGTH]{};
        Lha_CanonicalizePath(canonical, &path[0], sizeof(canonical));
        path = canonical;
    }
    if (!path.empty() && !enable_absolute_path) {
        strip_absolute_root(&path[0]);
        path.resize(strlen(path.c_str()));
    }
    if (generic_format) {
        const size_t separator = path.find_last_of('/');
        if (separator != std::string::npos) path.erase(0, separator + 1);
    }
    return path;
}

static std::string CompressionStoredSuffix(const std::string& found, const std::string& base) {
    const std::wstring path = StringToWString(found);
    size_t offset = (std::min)(StringToWString(base).size(), path.size());
    // 原版は変換前の基準長を使い、成分の途中なら次の区切りへ進む。
    // . / .. で基準が短くなると、再帰先の先頭成分が格納名から外れる。
    if (offset && path[offset - 1] != L'/' && path[offset - 1] != L'\\' && path[offset - 1] != L':') {
        size_t separator = path.find_first_of(L"/\\", offset);
        if (separator == std::wstring::npos) separator = path.find_last_of(L"/\\");
        offset = separator == std::wstring::npos ? 0 : separator + 1;
    }
    return WStringToString(path.substr(offset));
}

static size_t CompressionInputPosition(const char* source) {
    const std::string header_name = CompressionMemberName(source);
    std::wstring name = StringToWString(header_name);
    for (const ForcedHeaderName& forced : g_forced_header_names) {
        if (header_name == forced.placeholder) {
            name = forced.member_name;
            break;
        }
    }
    const DWORD attributes = Lha_GetFileAttributes(source);
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !name.empty() && name.back() != L'/') name += L'/';
    const auto existing = g_command_existing_members.find(name);
    return existing == g_command_existing_members.end() ? SIZE_MAX : existing->second.position;
}
}

extern "C" void Lha_OrderCompressionInputs(const int count, char** files) {
    const DWORD previous_error = GetLastError();
    if (g_command_update_policy.command == 'm') {
        g_compression_source_order.clear();
        for (int index = 0; index < count; ++index)
            g_compression_source_order.emplace(files[index], static_cast<size_t>(index));
    }
    if (count < 2 || g_command_existing_members.empty()) {
        SetLastError(previous_error);
        return;
    }
    std::vector<std::pair<size_t, char*>> ordered;
    ordered.reserve(count);
    for (int index = 0; index < count; ++index)
        ordered.emplace_back(CompressionInputPosition(files[index]), files[index]);
    // 旧項目は書庫順、新規項目は元の入力順。辞書順でのマージは行わない。
    std::stable_sort(ordered.begin(), ordered.end(), [](const auto& first, const auto& second) {
        return first.first < second.first;
    });
    for (int index = 0; index < count; ++index) files[index] = ordered[index].second;
    SetLastError(previous_error);
}

extern "C" void Lha_RestoreCompressionInputOrder(const int count, char** files) {
    if (count < 2 || g_compression_source_order.empty()) return;
    const DWORD previous_error = GetLastError();
    std::vector<std::pair<size_t, char*>> ordered;
    ordered.reserve(count);
    for (int index = 0; index < count; ++index) {
        const auto source = g_compression_source_order.find(files[index]);
        ordered.emplace_back(source == g_compression_source_order.end() ? SIZE_MAX : source->second, files[index]);
    }
    // 圧縮は旧書庫順でも、m の削除は元の入力順。除外済みの引数は戻さない。
    std::stable_sort(ordered.begin(), ordered.end(), [](const auto& first, const auto& second) {
        return first.first < second.first;
    });
    for (int index = 0; index < count; ++index) files[index] = ordered[index].second;
    SetLastError(previous_error);
}

extern "C" int Lha_CompareCompressionHeader(const LzHeader* old_header, const char* source) {
    const DWORD previous_error = GetLastError();
    const auto existing = g_command_existing_members.find(
        HeaderNameToWString(*old_header, ConfiguredArchiveCodePage()));
    const size_t old_position = existing == g_command_existing_members.end()
        ? SIZE_MAX : existing->second.position;
    const size_t incoming_position = CompressionInputPosition(source);
    SetLastError(previous_error);
    if (incoming_position == SIZE_MAX) return -1;
    return old_position < incoming_position ? -1 : old_position == incoming_position ? 0 : 1;
}

static void GlobWidePaths(const std::wstring& base, const std::wstring& pattern,
                          std::vector<std::wstring>& results, const bool recursive) {
    std::unordered_set<std::wstring> matched_files;
    WIN32_FIND_DATAW item{};
    HANDLE search = FindFirstFileW((base + pattern).c_str(), &item);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(item.cFileName, L".") != 0 && wcscmp(item.cFileName, L"..") != 0 &&
                (!recursive || !(item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))) {
                if (recursive) matched_files.insert(item.cFileName);
                else results.push_back(base + item.cFileName);
            }
        } while (FindNextFileW(search, &item));
        FindClose(search);
    }
    if (!recursive) return;
    search = FindFirstFileW((base + L"*").c_str(), &item);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
                wcscmp(item.cFileName, L".") != 0 && wcscmp(item.cFileName, L"..") != 0)
                GlobWidePaths(base + item.cFileName + L"\\", pattern, results, true);
            else if (!(item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && matched_files.count(item.cFileName))
                results.push_back(base + item.cFileName);
        } while (FindNextFileW(search, &item));
        FindClose(search);
    }
}

static void GlobUnicode(const std::wstring& base, const std::wstring& pattern,
                        std::vector<std::string>& results, const bool recursive) {
    std::vector<std::wstring> found;
    GlobWidePaths(base, pattern, found, recursive);
    for (const auto& path : found) results.push_back(WStringToString(path));
}

static void GlobRecursive(const std::string& baseDir, const std::string& searchPattern, std::vector<std::string>& results) {
    if (g_unicode_mode.load() || g_wide_command_utf8_input) {
        GlobUnicode(FilePathToWide(baseDir.c_str()), FilePathToWide(searchPattern.c_str()), results, true);
        return;
    }
    std::unordered_set<std::string> matched_files;
    std::string findPath = baseDir + searchPattern;
    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA(findPath.c_str(), &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                matched_files.insert(fd.cFileName);
            }
        } while (FindNextFileA(hFind, &fd));
        FindClose(hFind);
    }

    std::string subDirFind = baseDir + "*";
    hFind = FindFirstFileA(subDirFind.c_str(), &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (strcmp(fd.cFileName, ".") != 0 && strcmp(fd.cFileName, "..") != 0) {
                    GlobRecursive(baseDir + fd.cFileName + "\\", searchPattern, results);
                }
            } else if (matched_files.count(fd.cFileName)) results.push_back(baseDir + fd.cFileName);
        } while (FindNextFileA(hFind, &fd));
        FindClose(hFind);
    }
}

static void GlobSingle(const std::string& baseDir, const std::string& searchPattern, std::vector<std::string>& results) {
    if (g_unicode_mode.load() || g_wide_command_utf8_input) {
        GlobUnicode(FilePathToWide(baseDir.c_str()), FilePathToWide(searchPattern.c_str()), results, false);
        return;
    }
    std::string findPath = baseDir + searchPattern;
    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA(findPath.c_str(), &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (strcmp(fd.cFileName, ".") != 0 && strcmp(fd.cFileName, "..") != 0) {
                results.push_back(baseDir + fd.cFileName);
            }
        } while (FindNextFileA(hFind, &fd));
        FindClose(hFind);
    }
}

static void GlobCompressionPaths(const std::string& base, const std::string& pattern,
                                 std::vector<std::string>& results, const int recursive_mode) {
    std::vector<std::string> matches;
    GlobSingle(base, pattern, matches);
    // r2 は指定位置で一致したディレクトリーだけを後段で展開する。
    if (recursive_mode != 1) {
        results.insert(results.end(), matches.begin(), matches.end());
        return;
    }
    const std::unordered_set<std::string> matched(matches.begin(), matches.end());
    std::vector<std::string> entries;
    GlobSingle(base, "*", entries);
    for (const std::string& entry : entries) {
        const DWORD attributes = Lha_GetFileAttributes(entry.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) continue;
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            GlobCompressionPaths(entry + "\\", pattern, results, recursive_mode);
        } else if (matched.count(entry)) {
            results.push_back(entry);
        }
    }
    SetLastError(ERROR_NO_MORE_FILES);
}

static void AppendCompressionDirectory(const std::string& source, const std::string& prefix,
                                       std::vector<std::string>& selected) {
    std::string base = source;
    if (base.back() != '/' && base.back() != '\\') base += '\\';
    std::vector<std::string> entries;
    GlobSingle(base, "*", entries);
    for (const std::string& entry : entries) {
        const DWORD attributes = Lha_GetFileAttributes(entry.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) continue;
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) AppendCompressionDirectory(entry, prefix, selected);
        else selected.push_back(entry.substr(prefix.size()));
    }
    // ディレクトリーメンバーは、その配下のファイル・ディレクトリーの後に格納する。
    selected.push_back(source.substr(prefix.size()));
}

static void ExpandCompressionDirectories(std::vector<std::string>& inputs, const size_t first_input,
                                        const std::string& base, const int recursive_mode,
                                        const bool store_directories, DWORD& search_error) {
    if (first_input >= inputs.size()) return;
    const DWORD previous_error = GetLastError();
    std::vector<std::string> selected(inputs.begin(), inputs.begin() + first_input);
    for (size_t index = first_input; index < inputs.size(); ++index) {
        const std::string& name = inputs[index];
        const bool relative = !name.empty() && name[0] != '/' && name[0] != '\\' &&
            !(name.size() > 1 && name[1] == ':');
        const std::string prefix = relative ? base : std::string();
        std::string source = prefix + name;
        const DWORD attributes = Lha_GetFileAttributes(source.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
            selected.push_back(name);
            continue;
        }
        // r0/r1 で見つかったディレクトリーは入力ファイルではない。
        // r2 では配下のファイルを検索順に渡し、圧縮・通知・m の削除対象をそろえる。
        search_error = ERROR_NO_MORE_FILES;
        if (recursive_mode == 2) {
            if (store_directories) {
                AppendCompressionDirectory(source, prefix, selected);
                continue;
            }
            if (source.back() != '/' && source.back() != '\\') source += '\\';
            std::vector<std::string> children;
            GlobRecursive(source, "*", children);
            for (const std::string& child : children) selected.push_back(child.substr(prefix.size()));
        }
    }
    inputs.swap(selected);
    SetLastError(previous_error);
}

static bool CopyArchiveBytes(FILE* source, FILE* destination, off_t size,
                             const bool notify_rewrite = false) {
    unsigned char buffer[64 * 1024];
    off_t copied = 0;
    while (size > 0) {
        const size_t chunk = static_cast<size_t>((std::min)(
            size, static_cast<off_t>(sizeof(buffer))));
        if (fread(buffer, 1, chunk, source) != chunk ||
            Lha_WriteCompressionData(buffer, 1, chunk, destination) != chunk) {
            return false;
        }
        size -= static_cast<off_t>(chunk);
        copied += static_cast<off_t>(chunk);
        if (notify_rewrite && size > 0 && copied % (256 * 1024) == 0 &&
            Lha_SendCompatProgressMessage(ARCEXTRACT_INPROCESS, nullptr, copied, 0)) return false;
    }
    return true;
}

static void StripHeaderDirectory(LzHeader& header) {
    std::wstring name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
    const size_t separator = name.find_last_of(L"/\\");
    if (separator != std::wstring::npos) name.erase(0, separator + 1);
    SetHeaderNameFromWide(header, name);
}

static bool OpenArchiveForRewrite(const std::string& path, FILE** file) {
    *file = Lha_OpenFile(path.c_str(), "rb");
    if (!*file) return false;
    if (archive_is_msdos_sfx1(const_cast<char*>(path.c_str()))) {
        if (seek_lha_header(*file) != 0) {
            fclose(*file);
            *file = nullptr;
            return false;
        }
    }
    return true;
}

static bool ResolveRewriteDestination(const std::string& destination,
                                      std::string& full_destination) {
    wchar_t full_path[FILENAME_LENGTH * 2]{};
    const DWORD length = GetFullPathNameW(StringToWString(destination).c_str(),
                                          static_cast<DWORD>(_countof(full_path)),
                                          full_path, nullptr);
    if (length == 0 || length >= _countof(full_path)) return false;
    full_destination = WStringToString(full_path);
    return true;
}

static bool CreateRewriteOutput(const std::string& full_destination,
                                 std::string& temporary, FILE** output, const wchar_t* prefix = L"ulr") {
    const size_t separator = full_destination.find_last_of("\\/");
    const std::wstring directory = separator == std::string::npos
        ? std::wstring(L".") : StringToWString(full_destination.substr(0, separator + 1));
    wchar_t temp_path[MAX_PATH + 1]{};
    if (directory.size() >= MAX_PATH ||
        GetTempFileNameW(directory.c_str(), prefix, 0, temp_path) == 0) {
        return false;
    }
    temporary = WStringToString(temp_path);
    *output = Lha_OpenFile(temporary.c_str(), "wb");
    if (!*output) {
        DeleteFileW(temp_path);
        temporary.clear();
        return false;
    }
    return true;
}

// RewriteArchiveStream 内の get_header/write_header は致命的な I/O 失敗で lha_exit() を
// 経由し得る。通常の戻り値経路と同じく、出力と一時名を LHa の cleanup() に渡す。
static void RegisterRewriteOutputForCleanup(FILE* output, const std::string& temporary) {
    if (!output) return;
    g_outfp = output;
    temporary_fd = _fileno(output);
    if (temporary_fd >= 0) {
        strcpy_s(temporary_name, _countof(temporary_name), temporary.c_str());
    }
}

static void ReleaseRewriteOutputFromCleanup(FILE* output, const int descriptor) {
    if (g_outfp == output) g_outfp = nullptr;
    if (temporary_fd == descriptor) temporary_fd = -1;
}

static void SetRewriteSearchProgressDirectory(const std::string& path) {
    char full_path[FILENAME_LENGTH * 4]{};
    if (!Lha_FullPath(full_path, path.c_str(), _countof(full_path))) {
        Lha_SetProgressDestination("");
        return;
    }
    char* slash = strrchr(full_path, '/');
    char* backslash = strrchr(full_path, '\\');
    char* separator = slash;
    if (!separator || (backslash && backslash > separator)) separator = backslash;
    if (separator) separator[1] = '\0';
    else full_path[0] = '\0';
    Lha_SetProgressDestination(full_path);
}

static const char* RewriteInputLeafName(const std::string& path) {
    const size_t separator = path.find_last_of("\\/");
    return path.c_str() + (separator == std::string::npos ? 0 : separator + 1);
}

static int RewriteFailure(const int code, const wchar_t* message,
                          const DWORD system_error = ERROR_SUCCESS) {
    g_last_error = message ? message : L"";
    g_last_system_error = system_error;
    return code;
}

static bool WriteHandleAll(HANDLE file, const void* data, ULONGLONG size) {
    const BYTE* cursor = static_cast<const BYTE*>(data);
    while (size > 0) {
        const DWORD requested = static_cast<DWORD>((std::min)(
            size, static_cast<ULONGLONG>(MAXDWORD)));
        DWORD written = 0;
        if (!WriteFile(file, cursor, requested, &written, nullptr) || written == 0) {
            return false;
        }
        cursor += written;
        size -= written;
    }
    return true;
}

static bool CopyHandleAll(HANDLE input, HANDLE output, ULONGLONG size) {
    LARGE_INTEGER beginning{};
    if (!SetFilePointerEx(input, beginning, nullptr, FILE_BEGIN)) return false;
    BYTE buffer[64 * 1024];
    while (size > 0) {
        const DWORD requested = static_cast<DWORD>((std::min)(
            size, static_cast<ULONGLONG>(sizeof(buffer))));
        DWORD read = 0;
        if (!ReadFile(input, buffer, requested, &read, nullptr) || read == 0 ||
            !WriteHandleAll(output, buffer, read)) {
            return false;
        }
        size -= read;
    }
    return true;
}

static bool GetHandleSize(HANDLE file, ULONGLONG& size) {
    LARGE_INTEGER value{};
    if (!GetFileSizeEx(file, &value) || value.QuadPart < 0) return false;
    size = static_cast<ULONGLONG>(value.QuadPart);
    return true;
}

static void MakeSfxLeafName(const std::wstring& archive,
                            const std::wstring& rename_target,
                            std::wstring& leaf) {
    leaf = rename_target.empty() ? archive : rename_target;
    const size_t separator = leaf.find_last_of(L"\\/");
    if (separator != std::wstring::npos) leaf.erase(0, separator + 1);
    const size_t extension = leaf.find_last_of(L'.');
    if (extension != std::wstring::npos) leaf.erase(extension);
    if (leaf.empty()) leaf = L"archive";
    leaf += L".EXE";
}

static int ExecuteSfxCommandW(const std::wstring& archive_path,
                              const std::wstring& destination_directory,
                              const std::wstring& rename_target,
                              const int sfx_type, const bool overwrite) {
    if (archive_path.empty()) {
        return RewriteFailure(ERROR_NOT_FILENAME, L"書庫名が指定されていません。",
                              ERROR_INVALID_PARAMETER);
    }

    wchar_t full_archive_buffer[MAX_PATH * 4]{};
    const DWORD archive_length = GetFullPathNameW(
        archive_path.c_str(), static_cast<DWORD>(_countof(full_archive_buffer)),
        full_archive_buffer, nullptr);
    if (archive_length == 0 || archive_length >= _countof(full_archive_buffer)) {
        return RewriteFailure(ERROR_INVALID_PATH, L"書庫のパスが長すぎます。",
                              GetLastError());
    }
    const std::wstring full_archive(full_archive_buffer);

    std::wstring output_directory;
    if (destination_directory.empty()) {
        const size_t separator = full_archive.find_last_of(L"\\/");
        output_directory = separator == std::wstring::npos
            ? std::wstring(L".") : full_archive.substr(0, separator + 1);
    } else {
        wchar_t full_directory_buffer[MAX_PATH * 4]{};
        const DWORD directory_length = GetFullPathNameW(
            destination_directory.c_str(),
            static_cast<DWORD>(_countof(full_directory_buffer)),
            full_directory_buffer, nullptr);
        if (directory_length == 0 || directory_length >= _countof(full_directory_buffer)) {
            return RewriteFailure(ERROR_INVALID_PATH, L"出力先のパスが長すぎます。",
                                  GetLastError());
        }
        output_directory = full_directory_buffer;
    }
    const DWORD directory_attributes = GetFileAttributesW(output_directory.c_str());
    if (directory_attributes == INVALID_FILE_ATTRIBUTES ||
        (directory_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        return RewriteFailure(ERROR_INVALID_PATH, L"出力先ディレクトリがありません。",
                              ERROR_PATH_NOT_FOUND);
    }

    std::wstring output_path = output_directory;
    if (!output_path.empty() && output_path.back() != L'\\' &&
        output_path.back() != L'/') {
        output_path += L'\\';
    }
    std::wstring output_leaf;
    MakeSfxLeafName(full_archive, rename_target, output_leaf);
    output_path += output_leaf;
    if (!overwrite && GetFileAttributesW(output_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
        return RewriteFailure(ERROR_ALREADY_EXIST, L"出力ファイルは既に存在します。",
                              ERROR_FILE_EXISTS);
    }

    HRSRC resource = FindResourceW(
        g_hModule, MAKEINTRESOURCEW(kUnLhaReSfxLoaderResource), MAKEINTRESOURCEW(10));
    HGLOBAL resource_memory = resource ? LoadResource(g_hModule, resource) : nullptr;
    const DWORD loader_size = resource ? SizeofResource(g_hModule, resource) : 0;
    const void* loader = resource_memory ? LockResource(resource_memory) : nullptr;
    if (!loader || loader_size == 0) {
        return RewriteFailure(ERROR_EXECUTABLE_FILE,
                              L"自己解凍ローダーを読み込めません。", GetLastError());
    }

    wchar_t dll_path[MAX_PATH * 4]{};
    const DWORD dll_path_length = GetModuleFileNameW(
        g_hModule, dll_path, static_cast<DWORD>(_countof(dll_path)));
    if (dll_path_length == 0 || dll_path_length >= _countof(dll_path)) {
        return RewriteFailure(ERROR_EXECUTABLE_FILE,
                              L"展開エンジンのパスを取得できません。", GetLastError());
    }

    HANDLE archive = CreateFileW(full_archive.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                 nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (archive == INVALID_HANDLE_VALUE) {
        return RewriteFailure(ERROR_ARC_FILE_OPEN, L"書庫を開けません。", GetLastError());
    }
    HANDLE dll = CreateFileW(dll_path, GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    ULONGLONG archive_size = 0;
    ULONGLONG dll_size = 0;
    if (dll == INVALID_HANDLE_VALUE || !GetHandleSize(archive, archive_size) ||
        !GetHandleSize(dll, dll_size)) {
        const DWORD system_error = GetLastError();
        CloseHandle(archive);
        if (dll != INVALID_HANDLE_VALUE) CloseHandle(dll);
        return RewriteFailure(ERROR_EXECUTABLE_FILE,
                              L"自己解凍データを読み込めません。", system_error);
    }

    wchar_t temporary_path[MAX_PATH * 4]{};
    if (!GetTempFileNameW(output_directory.c_str(), L"ULS", 0, temporary_path)) {
        const DWORD system_error = GetLastError();
        CloseHandle(dll);
        CloseHandle(archive);
        return RewriteFailure(ERROR_TMP_OPEN, L"一時ファイルを作成できません。",
                              system_error);
    }
    HANDLE output = CreateFileW(temporary_path, GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) {
        const DWORD system_error = GetLastError();
        DeleteFileW(temporary_path);
        CloseHandle(dll);
        CloseHandle(archive);
        return RewriteFailure(ERROR_TMP_OPEN, L"一時ファイルを開けません。",
                              system_error);
    }

    UnLhaReSfxFooter footer{};
    memcpy(footer.magic, kUnLhaReSfxFooterMagic, sizeof(footer.magic));
    footer.version = kUnLhaReSfxFooterVersion;
    footer.flavor = static_cast<DWORD>(sfx_type);
    footer.archiveOffset = loader_size;
    footer.archiveSize = archive_size;
    footer.dllOffset = footer.archiveOffset + footer.archiveSize;
    footer.dllSize = dll_size;
    const bool written = WriteHandleAll(output, loader, loader_size) &&
                         CopyHandleAll(archive, output, archive_size) &&
                         CopyHandleAll(dll, output, dll_size) &&
                         WriteHandleAll(output, &footer, sizeof(footer)) &&
                         FlushFileBuffers(output) != FALSE;
    const DWORD write_error = written ? ERROR_SUCCESS : GetLastError();
    CloseHandle(output);
    CloseHandle(dll);
    CloseHandle(archive);
    if (!written) {
        DeleteFileW(temporary_path);
        return RewriteFailure(ERROR_CANNOT_WRITE,
                              L"自己解凍ファイルを書き込めません。", write_error);
    }

    const DWORD move_flags = MOVEFILE_WRITE_THROUGH |
        (overwrite ? MOVEFILE_REPLACE_EXISTING : 0);
    if (!MoveFileExW(temporary_path, output_path.c_str(), move_flags)) {
        const DWORD system_error = GetLastError();
        DeleteFileW(temporary_path);
        return RewriteFailure(system_error == ERROR_ALREADY_EXISTS ||
                                      system_error == ERROR_FILE_EXISTS
                                  ? ERROR_ALREADY_EXIST : ERROR_CANNOT_WRITE,
                              L"自己解凍ファイルを配置できません。", system_error);
    }
    g_last_error.clear();
    g_last_system_error = ERROR_SUCCESS;
    return 0;
}

struct CommandCommentInput {
    bool replace = false;
    std::wstring value;
};

static bool ReadCommandComment(const std::string& path, CommandCommentInput& comment) {
    FILE* file = nullptr;
    if (_wfopen_s(&file, StringToWString(path).c_str(), L"rb") != 0 || !file) return false;
    unsigned char bytes[0x1008]{};
    const size_t count = fread(bytes, 1, sizeof(bytes), file);
    const bool ok = !ferror(file);
    fclose(file);
    if (!ok) return false;

    bool wide = g_wide_command_input;
    bool big_endian = false;
    UINT code_page = g_unicode_mode.load() ? CP_UTF8 : ConfiguredArchiveCodePage();
    size_t offset = 0;
    if (count >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
        wide = true;
        offset = 2;
    } else if (count >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
        wide = true;
        big_endian = true;
        offset = 2;
    } else if (count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
        wide = false;
        code_page = CP_UTF8;
        offset = 3;
    }
    comment.replace = wide || count > offset;
    if (wide) {
        while (offset + 1 < count && comment.value.size() < 0x802) {
            const wchar_t character = static_cast<wchar_t>(big_endian
                ? (bytes[offset] << 8) | bytes[offset + 1]
                : bytes[offset] | (bytes[offset + 1] << 8));
            if (character == 0 || character == 0xffff) break;
            comment.value.push_back(character);
            offset += 2;
        }
    } else {
        const size_t capacity = (std::min)(count - offset, static_cast<size_t>(0x801));
        const size_t length = strnlen(reinterpret_cast<const char*>(bytes + offset), capacity);
        // 元 DLL は未終端の読込バッファを -1 長で変換するが、ここでは読込範囲に限定する。
        comment.value = MultiByteStringToWide(
            std::string(reinterpret_cast<const char*>(bytes + offset), length), code_page);
    }
    return true;
}

static bool ReplaceRawHeaderComment(std::vector<unsigned char>& raw, const LzHeader& header,
                                    const CommandCommentInput& comment) {
    if (!comment.replace || header.header_level == 0) return true;
    if (raw.size() < 26 || header.header_level > 2) return false;
    std::string encoded = WideStringToMultiByte(comment.value,
                                               HeaderCodePage(header, ConfiguredArchiveCodePage()));
    // 元 DLL の 2048 バイト変換バッファ超過時は、保存長がエラー文字列の 5 バイトになる。
    if (encoded.size() >= 0x800) encoded.resize(5);
    const size_t first_extension = header.header_level == 2 ? 24U : raw[0];
    if (first_extension + 2 > raw.size()) return false;
    std::vector<unsigned char> replaced(raw.begin(), raw.begin() + first_extension);
    auto put_word = [&](const unsigned int value) {
        replaced.push_back(static_cast<unsigned char>(value));
        replaced.push_back(static_cast<unsigned char>(value >> 8));
    };
    bool inserted = false;
    auto insert_comment = [&]() {
        if (inserted) return;
        inserted = true;
        if (encoded.empty()) return;
        put_word(static_cast<unsigned int>(encoded.size() + 3));
        replaced.push_back(0x3f);
        replaced.insert(replaced.end(), encoded.begin(), encoded.end());
    };
    size_t crc_offset = 0;
    size_t position = first_extension;
    while (position + 2 <= raw.size()) {
        const size_t length = raw[position] | (static_cast<size_t>(raw[position + 1]) << 8);
        if (length == 0) break;
        if (length < 3 || length > raw.size() - position) return false;
        const unsigned char type = raw[position + 2];
        if (type != 0x3f && !(type >= 0xc4 && type <= 0xc8)) {
            if (type == 0 && length >= 5) {
                insert_comment();
                crc_offset = replaced.size() + 3;
            }
            replaced.insert(replaced.end(), raw.begin() + position, raw.begin() + position + length);
        }
        position += length;
    }
    insert_comment();
    put_word(0);
    if (header.header_level == 2) {
        if ((replaced.size() & 0xffU) == 0) replaced.push_back(0);
        if (replaced.size() > 0xffffU) return false;
        replaced[0] = static_cast<unsigned char>(replaced.size());
        replaced[1] = static_cast<unsigned char>(replaced.size() >> 8);
    } else {
        const unsigned long packed = static_cast<unsigned long>(header.packed_size) +
            static_cast<unsigned long>(replaced.size() - first_extension - 2);
        for (size_t index = 0; index < 4; ++index)
            replaced[7 + index] = static_cast<unsigned char>(packed >> (index * 8));
        unsigned int sum = 0;
        for (size_t index = 2; index < first_extension + 2; ++index) sum += replaced[index];
        replaced[1] = static_cast<unsigned char>(sum);
    }
    if (crc_offset != 0) {
        replaced[crc_offset] = replaced[crc_offset + 1] = 0;
        const unsigned int crc = calccrc(0, reinterpret_cast<char*>(replaced.data()),
                                         static_cast<unsigned int>(replaced.size()));
        replaced[crc_offset] = static_cast<unsigned char>(crc);
        replaced[crc_offset + 1] = static_cast<unsigned char>(crc >> 8);
    }
    raw.swap(replaced);
    return true;
}

static bool CommandMemberMatches(const LzHeader& header,
                                 const std::vector<std::string>& patterns,
                                 const std::vector<std::string>& exclusions);

static bool RewriteArchiveStream(FILE* input, FILE* output, const char command,
                                 const bool existing_join_target,
                                 const std::vector<std::string>& member_patterns,
                                 const int requested_header_level,
                                 const bool strip_directories,
                                 const std::string& rename_target,
                                 const std::vector<std::string>& exclusions,
                                 const CommandCommentInput* comment, bool& changed) {
    const __int64 join_source_size = command == 'j' && !existing_join_target
        ? _filelengthi64(_fileno(input)) : -1;
    while (true) {
        const off_t header_start = ftello(input);
        LzHeader header{};
        if (!get_header(input, &header)) {
            if (command == 'j' && !existing_join_target) {
                g_rewrite_join_source_system_error = join_source_size - header_start < 21
                    ? ERROR_HANDLE_EOF : ERROR_FILE_NOT_FOUND;
            }
            Lha_RecordProgressHeaderEnd();
            break;
        }
        Lha_RecordEnumHeader(&header);
        const off_t data_start = ftello(input);
        const off_t raw_header_size = data_start - header_start;
        const off_t packed_size = header.packed_size;
        const bool notify_rewrite = command == 'n' || command == 'y' || command == 'j';
        if (notify_rewrite) {
            g_rewrite_progress_member_transformed = false;
            if (command == 'j' && !existing_join_target) {
                // 連結元の進捗は末尾名、旧項目の進捗は格納パス。保存用ヘッダーは変えない。
                LzHeader progress_header = header;
                StripHeaderDirectory(progress_header);
                Lha_SetProgressMember(&progress_header);
            } else {
                Lha_SetProgressMember(&header);
            }
            if (Lha_SendCompatProgressMessage(ARCEXTRACT_BEGIN, header.name, 0, header.original_size))
                return false;
        }
        const std::wstring original_member_name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
        const size_t original_separator = original_member_name.find_last_of(L"/\\");
        const size_t display_offset = original_separator == std::wstring::npos ? 0 : original_separator + 1;
        std::wstring display_member_name = original_member_name.substr(display_offset);
        if ((command == 'j' || command == 'y' || command == 'n') &&
            header.header_level != 0 && !header.has_header_crc) {
            g_command_events.push_back({"HeaderCrcMissing", {}, 0, original_member_name});
        }
        const bool matched = command == 'j' || CommandMemberMatches(header, member_patterns, exclusions);
        bool transform = false;
        bool include = true;

        if (matched && command == 'c' && comment) {
            if (raw_header_size < 0 || raw_header_size > 0x10000 ||
                fseeko(input, header_start, SEEK_SET) != 0) return false;
            std::vector<unsigned char> raw(static_cast<size_t>(raw_header_size));
            if (fread(raw.data(), 1, raw.size(), input) != raw.size() ||
                !ReplaceRawHeaderComment(raw, header, *comment) ||
                Lha_WriteCompressionData(raw.data(), 1, raw.size(), output) != raw.size() ||
                !CopyArchiveBytes(input, output, packed_size)) return false;
            Lha_RecordHeaderCommandEvent("Commented", &header, 0);
            continue;
        }

        if (matched) {
            if (command == 'j') {
                // 結合は -h 指定による形式変換を行わず、各入力のレベルを保持する。
                const int selected = existing_join_target
                    ? Lha_InvokeEnumMember(&header, nullptr, 0) : TRUE;
                if (!selected) {
                    include = false;
                } else {
                    // 既存項目は選択結果だけを採用し、名前の書き換えも含めて元のヘッダーを保持する。
                    transform = !existing_join_target;
                    // 既存の結合先メンバーは階層を保持する。除去指定は追加する入力だけに適用する。
                    if (strip_directories && !existing_join_target) StripHeaderDirectory(header);
                    display_member_name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
                }
            } else {
                if (!existing_join_target) {
                    if (command == 'y') {
                        header.header_level = static_cast<unsigned char>(
                            requested_header_level >= 0 ? requested_header_level : 2);
                    }

                    const bool has_enum_callback = g_enum_members_proc != nullptr;
                    const int selected = Lha_InvokeEnumMember(&header, nullptr, 0);
                    if (selected) {
                        // 原版は変更前の末尾名位置を保持する。短い改名で位置まで届かない場合は旧名が残る。
                        const std::wstring callback_name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
                        if (callback_name.size() >= display_offset)
                            display_member_name = callback_name.substr(display_offset);
                        transform = command == 'y';
                        if (command == 'n') {
                            if (!has_enum_callback && !rename_target.empty()) {
                                SetHeaderNameFromWide(header, StringToWString(rename_target));
                            }
                            transform = has_enum_callback || !rename_target.empty();
                        } else if (strip_directories) {
                            StripHeaderDirectory(header);
                        }
                    }
                }
            }
        }

        if (!include) {
            if (fseeko(input, data_start + packed_size, SEEK_SET) != 0) return false;
            continue;
        }

        if (transform && command == 'n') {
            g_command_events.push_back({"Renamed", {}, 0, display_member_name});
        }
        if (!transform) {
            if (fseeko(input, header_start, SEEK_SET) != 0 ||
                raw_header_size < 0 ||
                !CopyArchiveBytes(input, output, raw_header_size + packed_size)) {
                return false;
            }
        } else {
            if (notify_rewrite && packed_size < 100 && (command != 'y' || packed_size != 0) &&
                Lha_SendCompatProgressMessage(ARCEXTRACT_INPROCESS, nullptr, 0, header.original_size))
                return false;
            if (fseeko(input, data_start, SEEK_SET) != 0) return false;
            header.packed_size = packed_size;
            // 原版の再生成ヘッダーは Windows 形式。元にない日時は更新日時で補完する。
            if (header.header_level != 0) header.extend_type = EXTEND_MSDOS;
            // 再生成では既存ビットを保持し、出力形式の値を加える。
            header.common_header_flags = static_cast<unsigned char>(
                (header.has_common_header_flags ? header.common_header_flags : 0) |
                (header.header_level >= 2 ? Lha_GetCommonHeaderFlags() : 0x40));
            header.preserve_common_header_flags = TRUE;
            if (header.header_level == 2) {
                if (!existing_join_target && HeaderCodePage(header, ConfiguredArchiveCodePage()) != ConfiguredArchiveCodePage()) {
                    const std::wstring name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
                    const bool had_unicode_name = header.has_unicode_name != FALSE;
                    const bool had_unicode_directory = header.has_unicode_directory != FALSE;
                    header.code_page = ConfiguredArchiveCodePage();
                    header.has_code_page = TRUE;
                    SetHeaderNameFromWide(header, name);
                    // 再符号化だけでは Unicode 拡張を新設しない。既存の拡張は必要な場合に保持する。
                    if (!had_unicode_name) {
                        header.has_unicode_name = FALSE;
                        header.unicode_name_length = 0;
                    }
                    if (!had_unicode_directory) {
                        header.has_unicode_directory = FALSE;
                        header.unicode_directory_length = 0;
                    }
                }
                if (!header.has_code_page) {
                    header.code_page = ConfiguredArchiveCodePage();
                    header.has_code_page = TRUE;
                }
                if (!header.has_windows_timestamp) {
                    const FILETIME time = HeaderTimeToFileTime(header, MemberTimeKind::Write);
                    const uint64_t value = (static_cast<uint64_t>(time.dwHighDateTime) << 32) | time.dwLowDateTime;
                    header.windows_creation_time = value;
                    header.windows_last_modified_time = value;
                    header.windows_last_access_time = value;
                    header.has_windows_timestamp = TRUE;
                }
            }
            if (header.header_level <= 1 && (header.unix_last_modified_stamp & 1)) {
                // DOS 時刻は整数の奇数秒を切り上げる。進捗用の元ヘッダーには変更を持ち越さない。
                ++header.unix_last_modified_stamp;
            }
            write_header(output, &header);
            header.packed_size = packed_size;
            if (!CopyArchiveBytes(input, output, packed_size, notify_rewrite)) return false;
            changed = true;
            if (command == 'n' || command == 'y') g_rewrite_progress_member_transformed = true;
            // 空本文の改名・結合項目はコピー前の 0 通知だけを送る。
            if ((command == 'n' || command == 'j') && packed_size != 0 &&
                Lha_SendCompatProgressMessage(ARCEXTRACT_INPROCESS, nullptr, packed_size, header.original_size))
                return false;
        }
        // 保存コードページへの変換前に保持した表示名を使用する。
        if (transform && (command == 'y' || (command == 'j' && !existing_join_target))) {
            const char* action = command == 'j' ? "Append" : command == 'y' ? "Converted"
                : command == 'n' ? "Renamed" : nullptr;
            if (action) {
                g_command_events.push_back({action, {}, 0, display_member_name});
            }
        }
    }
    return !ferror(input) && !ferror(output);
}

static int ExecuteRewriteCommand(const char command,
                                 const std::vector<std::string>& operands,
                                 const std::vector<std::string>& exclude_patterns,
                                 const int requested_header_level,
                                 const bool strip_directories,
                                 const std::string& rename_target,
                                 const bool reject_foreign_data,
                                 const CommandCommentInput* comment = nullptr) {
    make_crctable();
    if (operands.empty()) {
        return RewriteFailure(ERROR_NOT_FILENAME, L"書庫名が指定されていません。",
                              ERROR_INVALID_PARAMETER);
    }
    if (command == 'j' && operands.size() < 2) {
        return RewriteFailure(ERROR_NOT_FILENAME, L"連結する書庫が指定されていません。",
                              ERROR_INVALID_PARAMETER);
    }

    std::string full_destination;
    std::string temporary;
    FILE* output = nullptr;
    if (!ResolveRewriteDestination(operands[0], full_destination)) {
        return RewriteFailure(ERROR_TMP_OPEN, L"一時書庫を作成できません。", GetLastError());
    }

    const bool existing_join_target = command == 'j' &&
        Lha_GetFileAttributes(full_destination.c_str()) != INVALID_FILE_ATTRIBUTES;
    const bool new_join_progress = command == 'j' && !existing_join_target;
    bool direct_new_join = false;
    if (new_join_progress) {
        const int direct_output = Lha_BeginNewCompressionArchive(full_destination.c_str(), &output);
        if (direct_output < 0) {
            return RewriteFailure(ERROR_TMP_OPEN, L"一時書庫を作成できません。", GetLastError());
        }
        if (direct_output > 0) {
            temporary = full_destination;
            direct_new_join = true;
        }
    }
    if (!output && !CreateRewriteOutput(full_destination, temporary, &output,
            command == 'n' || command == 'y' || existing_join_target ? L"LHT" : L"ulr")) {
        return RewriteFailure(ERROR_TMP_OPEN, L"一時書庫を作成できません。", GetLastError());
    }
    RegisterRewriteOutputForCleanup(output, temporary);
    bool ok = true;
    bool changed = false;
    // 通知の有無と出力の公開方法を分離し、既存 j は置換成功まで元書庫を保持する。
    const bool notify_rewrite = command == 'n' || command == 'y' || command == 'j';
    struct RewriteProgressCleanup final {
        bool enabled;
        ~RewriteProgressCleanup() {
            if (enabled) {
                Lha_ClearProgressMember();
                g_rewrite_progress_member_transformed = false;
            }
        }
    } progress_cleanup{notify_rewrite};
    if (notify_rewrite) {
        Lha_ClearProgressMember();
        if (command == 'j') {
            for (size_t index = 1; ok && index < operands.size(); ++index) {
                const std::string leaf = RewriteInputLeafName(operands[index]);
                bool excluded = false;
                for (const std::string& pattern : exclude_patterns) {
                    if (fnmatch(pattern.c_str(), leaf.c_str(), FNM_NOESCAPE | FNM_PERIOD) == 0) {
                        excluded = true;
                        break;
                    }
                }
                if (!excluded) {
                    SetRewriteSearchProgressDirectory(operands[index]);
                    ok = !Lha_SendCompatProgressMessage(5 /* ARCEXTRACT_SEARCH */, leaf.c_str(), 0, 0);
                }
            }
            Lha_ClearProgressMember();
        }
        if (ok) ok = !Lha_SendCompatProgressMessage(ARCEXTRACT_OPEN, full_destination.c_str(), 0, 0);
    }
    auto append_archive = [&](const std::string& path, const bool existing_join_target,
                              const std::vector<std::string>& patterns) {
        FILE* input = nullptr;
        if (!OpenArchiveForRewrite(path, &input)) return false;
        g_update_archive_fp = input;
        // 新規・既存とも連結元を Processing 前に末尾判定する。
        // 既存の出力先そのものは対象外とし、拒否時は未公開の一時出力だけを解放する。
        if (command == 'j' && !existing_join_target) {
            bool foreign_source_is_lzh = false;
            __int64 foreign_source_header_offset = -1;
            if (InspectArchiveStreamForeignTail(input, foreign_source_is_lzh,
                                                &foreign_source_header_offset)) {
                if (reject_foreign_data || !foreign_source_is_lzh) {
                    g_rewrite_foreign_source_path = CompressionInputAbsolutePath(path.c_str());
                    if (g_rewrite_foreign_source_path.empty())
                        g_rewrite_foreign_source_path = FilePathToWide(path.c_str());
                    g_rewrite_foreign_source_rejected = true;
                    if (g_update_archive_fp == input) g_update_archive_fp = nullptr;
                    fclose(input);
                    return false;
                }
                // 原版は先頭の非 SFX プレフィックスを越えて、有効な LZH ヘッダーから連結する。
                // 末尾検査は読み取り位置を戻すため、許可した入力だけ実ヘッダー位置へ戻す。
                if (foreign_source_header_offset < 0 ||
                    _fseeki64(input, foreign_source_header_offset, SEEK_SET) != 0) {
                    if (g_update_archive_fp == input) g_update_archive_fp = nullptr;
                    fclose(input);
                    return false;
                }
            }
        }
        if (command == 'j' && !existing_join_target) {
            const std::wstring source = CompressionInputAbsolutePath(path.c_str());
            g_command_events.push_back({"Processing", {}, 0, source});
        }
        const bool result = RewriteArchiveStream(input, output, command,
                                                 existing_join_target, patterns,
                                                 requested_header_level,
                                                 strip_directories, rename_target,
                                                 exclude_patterns, comment, changed);
        if (g_update_archive_fp == input) g_update_archive_fp = nullptr;
        fclose(input);
        return result;
    };

    if (command == 'j') {
        if (ok && existing_join_target) {
            ok = append_archive(full_destination, true, {});
        }
        for (size_t index = 1; ok && index < operands.size(); ++index) {
            const std::string leaf = operands[index].substr(
                operands[index].find_last_of("\\/") + 1);
            bool excluded = false;
            for (const std::string& pattern : exclude_patterns) {
                if (fnmatch(pattern.c_str(), leaf.c_str(), FNM_NOESCAPE | FNM_PERIOD) == 0) {
                    excluded = true;
                    break;
                }
            }
            if (!excluded) ok = append_archive(operands[index], false, {});
        }
    } else {
        const std::vector<std::string> patterns(operands.begin() + 1, operands.end());
        if (ok) ok = append_archive(full_destination, false, patterns);
    }

    if (ok && fputc(0, output) == EOF) ok = false;
    const off_t rewritten_size = static_cast<off_t>(Lha_TellCompressionFile(output));
    if (rewritten_size < 0) ok = false;
    if (direct_new_join) {
        // 新規 j は原版同様、SEARCH 前に作った出力先を COPY の直前で実サイズへ確定する。
        if (ok && Lha_FinishNewCompressionArchive(output, rewritten_size) != 0) ok = false;
    } else if (fflush(output) != 0) ok = false;
    const int output_descriptor = _fileno(output);
    if (fclose(output) != 0) ok = false;
    ReleaseRewriteOutputFromCleanup(output, output_descriptor);
    if (direct_new_join) {
        // 圧縮器外の j 経路でも、次の命令へ閉じた descriptor や書込み状態を残さない。
        ClearNewCompressionArchiveState(output);
    }
    output = nullptr;

    if (!ok) {
        const bool output_removed = Lha_UnlinkFile(temporary.c_str()) == 0;
        if (g_rewrite_foreign_source_rejected && output_removed) return ERROR_FILE_STYLE;
        if (g_rewrite_foreign_source_rejected) {
            g_rewrite_foreign_source_rejected = false;
            g_rewrite_foreign_source_path.clear();
        }
        if (notify_rewrite && Lha_CheckAbort()) {
            const DWORD system_error = new_join_progress &&
                (g_command_progress_cancel_state == ARCEXTRACT_BEGIN ||
                 g_command_progress_cancel_state == ARCEXTRACT_INPROCESS)
                ? ERROR_FILE_NOT_FOUND : ERROR_CANCELLED;
            return RewriteFailure(ERROR_USER_CANCEL, L"ユーザーによって中断されました。", system_error);
        }
        return RewriteFailure(ERROR_CANNOT_WRITE, L"書庫を再構築できません。",
                              ERROR_WRITE_FAULT);
    }
    bool published_new_join = direct_new_join;
    if (new_join_progress && changed && !published_new_join) {
        if (!MoveFileExW(StringToWString(temporary).c_str(), StringToWString(full_destination).c_str(),
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            const DWORD system_error = GetLastError();
            Lha_UnlinkFile(temporary.c_str());
            return RewriteFailure(ERROR_CANNOT_WRITE, L"書庫を置換できません。", system_error);
        }
        published_new_join = true;
    }
    if (notify_rewrite && changed) {
        Lha_SetProgressDestination(full_destination.c_str());
        Lha_SendCompatProgressMessage(ARCEXTRACT_COPY,
                                      published_new_join ? full_destination.c_str() : temporary.c_str(),
                                      0, rewritten_size);
    }
    if (notify_rewrite && Lha_SendCompatProgressMessage(ARCEXTRACT_INPROCESS,
            changed ? (published_new_join ? full_destination.c_str() : temporary.c_str()) : nullptr,
            rewritten_size, changed ? rewritten_size : 0)) {
        if (!changed) {
            Lha_UnlinkFile(temporary.c_str());
            return RewriteFailure(ERROR_USER_CANCEL, L"ユーザーによって中断されました。", ERROR_CANCELLED);
        }
        // COPY 段階の通知拒否は原版同様に置換を継続する。
        Lha_ResetAbort();
    }
    if (!published_new_join && !MoveFileExW(StringToWString(temporary).c_str(), StringToWString(full_destination).c_str(),
                                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const DWORD system_error = GetLastError();
        Lha_UnlinkFile(temporary.c_str());
        return RewriteFailure(ERROR_CANNOT_WRITE, L"書庫を置換できません。", system_error);
    }
    if (notify_rewrite) {
        // END の拒否は原版と同じく成功を維持し、次回へ中断状態を持ち越さない。
        Lha_SendCompatProgressMessage(ARCEXTRACT_END, nullptr, 0, 0);
        Lha_ResetAbort();
    }
    g_last_error.clear();
    g_last_system_error = ERROR_SUCCESS;
    return 0;
}

} // extern "C"

struct CommandOutputArchive final {
    std::string path;
    time_t write_time = 0;
    std::vector<LzHeader> members;
    std::vector<bool> member_crc_errors;
    bool last_pattern_matched = false;
    DWORD system_error = ERROR_NO_MORE_FILES;
    int read_error = 0;
    int read_warning = 0;
    bool recovered_header = false;
    bool initial_missing_crc = false;
};

struct CommandArchiveSnapshot final {
    std::string path;
    bool existed = false;
    DWORD open_error = ERROR_SUCCESS;
    bool foreign_tail = false;
};

static bool ResolveCommandArchive(const std::string& requested,
                                  std::string& resolved, FILE** file);

static UINT CommandOutputCodePage() {
    // Wide API の中間ログでは、呼び出し元の ANSI コードページに表せない文字も保持する。
    return g_wide_command_input ? CP_UTF8 : ActiveCodePage();
}

static void NormalizeAnsiSeparators(std::string& value) {
    for (size_t index = 0; index < value.size(); ++index) {
        if (IsInputLeadByte(static_cast<BYTE>(value[index])) && index + 1 < value.size()) {
            ++index;
        } else if (value[index] == '\\') {
            value[index] = '/';
        }
    }
}

static bool CommandPathHasExtension(const std::string& path) {
    const size_t separator = path.find_last_of("/\\");
    const size_t extension = path.find_last_of('.');
    return extension != std::string::npos &&
           (separator == std::string::npos || extension > separator);
}

static bool UsesExtendedWindowsPathPrefix(const std::string& path) {
    return path.size() >= 4 &&
        ((path[0] == '\\' && path[1] == '\\' && path[2] == '?' &&
          (path[3] == '\\' || path[3] == '/')) ||
         (path[0] == '/' && path[1] == '/' && path[2] == '?' &&
          (path[3] == '\\' || path[3] == '/')));
}

static CommandArchiveSnapshot SnapshotCommandArchivePath(const std::string& requested,
                                                          const bool check_foreign) {
    CommandArchiveSnapshot snapshot;
    FILE* file = nullptr;
    if (ResolveCommandArchive(requested, snapshot.path, &file)) {
        snapshot.existed = true;
        if (check_foreign) snapshot.foreign_tail = ArchiveStreamHasForeignTail(file);
        fclose(file);
        return snapshot;
    }
    snapshot.open_error = GetLastError();

    std::string candidate = requested;
    if (!CommandPathHasExtension(candidate)) candidate += ".lzh";
    wchar_t full_path[FILENAME_LENGTH * 4]{};
    const DWORD length = GetFullPathNameW(StringToWString(candidate).c_str(),
                                          static_cast<DWORD>(_countof(full_path)),
                                          full_path, nullptr);
    snapshot.path = length > 0 && length < _countof(full_path) ? WStringToString(full_path) : candidate;
    NormalizeAnsiSeparators(snapshot.path);
    return snapshot;
}

static std::string CommandEventLeaf(std::string name) {
    NormalizeAnsiSeparators(name);
    size_t separator = std::string::npos;
    for (size_t index = 0; index < name.size(); ++index) {
        if (IsInputLeadByte(static_cast<BYTE>(name[index])) && index + 1 < name.size()) {
            ++index;
        } else if (name[index] == '/') {
            separator = index;
        }
    }
    return separator == std::string::npos ? name : name.substr(separator + 1);
}

static bool CommandEventActionIs(const CommandEvent& event, const char* action) {
    return action && _strnicmp(event.action.c_str(), action, strlen(action)) == 0;
}

static size_t CommandEventDisplayWidth(const std::string& name) {
    // 元 DLL の桁埋めは UTF-8 のバイト数ではなく、従来の文字幅を使う。
    return g_unicode_mode.load()
        ? WideStringToMultiByte(StringToWString(name), ConfiguredArchiveCodePage()).size()
        : name.size();
}

static std::pair<std::string, size_t> CommandLeafForOutput(const std::wstring& wide_name) {
    const size_t separator = wide_name.find_last_of(L"/\\");
    const std::wstring name = separator == std::wstring::npos
        ? wide_name : wide_name.substr(separator + 1);
    return {WideStringToMultiByte(name, CommandOutputCodePage()),
            WideStringToMultiByte(name, ConfiguredArchiveCodePage()).size()};
}

static std::string CommandNameField(const std::wstring& wide_name, const size_t characters) {
    std::wstring field = wide_name;
    field.resize(characters, L' ');
    std::vector<WORD> types(characters);
    size_t display_width = characters;
    if (GetStringTypeExW(LOCALE_USER_DEFAULT, CT_CTYPE3, field.c_str(),
                        static_cast<int>(characters), types.data())) {
        display_width = 0;
        for (const WORD type : types) {
            const bool wide = (type & (C3_KATAKANA | C3_HIRAGANA | C3_IDEOGRAPH)) != 0
                ? (type & C3_HALFWIDTH) == 0 : (type & C3_FULLWIDTH) != 0;
            display_width += wide ? 2U : 1U;
        }
    }
    // 原版は固定 WCHAR 欄を先に作り、その幅の超過分だけ右側の数値・末尾を左へ移す。
    // 表示幅で名前を単純に切る処理とは、長い全角名の結果が異なる。
    field.resize(characters * 2U - display_width);
    return WideStringToMultiByte(field, CommandOutputCodePage());
}

static std::string CommandLeafField(const std::wstring& wide_name, const size_t characters) {
    const size_t separator = wide_name.find_last_of(L"/\\");
    return CommandNameField(separator == std::wstring::npos ? wide_name : wide_name.substr(separator + 1), characters);
}

static std::pair<std::string, size_t> CommandEventLeafForOutput(const CommandEvent& event) {
    if (!event.wide_name.empty()) return CommandLeafForOutput(event.wide_name);
    const std::string name = CommandEventLeaf(event.name);
    return {name, CommandEventDisplayWidth(name)};
}

static bool IsPmarcMethod(const char* method) {
    return memcmp(method, PMARC0_METHOD, 5) == 0 || memcmp(method, PMARC2_METHOD, 5) == 0;
}

static std::string UnsupportedCommandMethodOutput(const std::wstring& name, const char* method) {
    // 原版の警告自体には改行がなく、次項目のログまたはコマンド終端へ続く。
    return CommandLeafField(name, 25) + " : " +
        WideStringToMultiByte(L"未対応の圧縮法", CommandOutputCodePage()) + " '" + std::string(method, 5) + "'";
}

static std::string BuildCompatibleActionOutput(const char command,
                                               const CommandArchiveSnapshot& archive,
                                               const std::vector<CommandEvent>& events,
                                               const bool cancellation = false) {
    const char* title = nullptr;
    switch (command) {
    case 'a': case 'u': case 'm': case 'j':
        title = archive.existed ? "Updating" : "Creating";
        break;
    case 'f': title = "Freshening"; break;
    case 'c': case 'y': case 'n': title = "Updating"; break;
    case 'd': title = "Deleting from"; break;
    case 'e': case 'x': title = "Extracting from"; break;
    case 't': title = "Testing"; break;
    case 'p': break;
    default: return std::string();
    }

    std::string output = title ? "\r\n" + std::string(title) + " archive : " +
                         WideStringToMultiByte(FilePathToWide(archive.path.c_str()), CommandOutputCodePage()) +
                         "\r\n\r\n" : std::string();
    for (const CommandEvent& event : events) {
        if (cancellation && event.action == "ReadHeaderCrcMissing") {
            std::wstring name = event.wide_name;
            std::replace(name.begin(), name.end(), L'\\', L'/');
            const wchar_t* warning = UseEnglishDialogResources() ? L"Header CRC not found."
                : L"ヘッダ CRC が存在しません";
            output += WideStringToMultiByte(std::wstring(warning) + L" : '" + name + L"'\r\n",
                CommandOutputCodePage());
        } else if ((command == 'j' || command == 'y' || command == 'n') &&
            (event.action == "Processing" || event.action == "Append" || event.action == "Converted" ||
             event.action == "Renamed" || event.action == "HeaderCrcMissing")) {
            std::wstring name = event.wide_name;
            std::replace(name.begin(), name.end(), L'\\', L'/');
            const std::string display = WideStringToMultiByte(name, CommandOutputCodePage());
            if (event.action == "Processing") output += "\r\nProcessing archive : " + display + "\r\n\r\n";
            else if (event.action == "HeaderCrcMissing") {
                output += WideStringToMultiByte(L"ヘッダ CRC が存在しません : '", CommandOutputCodePage()) + display + "'\r\n";
            } else {
                output += (event.action == "Append" ? "Append   " : event.action == "Converted" ? "Converted  " : "Renamed  ");
                output += display + "\r\n";
            }
        } else if (command == 'c' && CommandEventActionIs(event, "Commented")) {
            output += "Commented  " + CommandEventLeafForOutput(event).first + "\r\n";
        } else if ((command == 'a' || command == 'u' || command == 'f' || command == 'm') &&
            CommandEventActionIs(event, "Frozen")) {
            char prefix[32]{};
            _snprintf_s(prefix, _countof(prefix), _TRUNCATE,
                        "Frozen   ==> %3d%% ", event.value);
            const std::string name = event.directory
                ? WideStringToMultiByte(event.wide_name, CommandOutputCodePage())
                : CommandEventLeafForOutput(event).first;
            output += prefix + name + "\r\n";
        } else if (command == 'd' && CommandEventActionIs(event, "Deleted")) {
            output += "Deleted  " + CommandEventLeafForOutput(event).first + "\r\n";
        } else if ((command == 'e' || command == 'x') &&
                   CommandEventActionIs(event, "mkdir")) {
            std::wstring wide_path = event.wide_name.empty()
                ? StringToWString(event.name) : event.wide_name;
            std::replace(wide_path.begin(), wide_path.end(), L'\\', L'/');
            const std::string path = WideStringToMultiByte(wide_path, CommandOutputCodePage());
            output += "mkdir  " + path + "\r\n";
        } else if ((command == 'e' || command == 'x') &&
                   CommandEventActionIs(event, "Skipped")) {
            const auto name = CommandEventLeafForOutput(event);
            output += "Skipped  " + name.first;
            const size_t width = name.second;
            if (width < 26U) output.append(26U - width, ' ');
            else output.push_back(' ');
            const wchar_t* reason = event.value == 1 ? L"同名のファイルがあります"
                : event.value == 2 ? L"最新のファイルが存在"
                : event.value == 3 ? L"古いファイルが存在"
                : event.value == 4 ? L"同じファイルがあります"
                : event.value == 5 ? L"ファイルが存在しません"
                : event.value == 7 ? L"特殊な属性のファイル"
                : event.value == 8 ? L"ユーザによりスキップ"
                : event.value == 10 ? L"ディスクが満杯"
                : event.value == 11 ? L"ファイルが開けません" : L"書き込み禁止";
            if (UseEnglishDialogResources()) {
                static const wchar_t* reasons[] = {L"already exists.", L"newer or same file exists.",
                    L"older or same file exists.", L"same file exists.", L"no file exists.",
                    L"read only file.", L"special attributes.", L"skipped by user."};
                reason = event.value == 11 ? L"can't open." : event.value == 10 ? L"disk full."
                    : reasons[event.value >= 1 && event.value <= 8 ? event.value - 1 : 5];
            }
            output += ": " + WideStringToMultiByte(reason, CommandOutputCodePage()) + "\r\n";
        } else if ((command == 'p' || command == 't' || command == 'e' || command == 'x') &&
                   CommandEventActionIs(event, "UnsupportedMethod")) {
            const std::wstring name = event.wide_name.empty() ? StringToWString(event.name) : event.wide_name;
            output += UnsupportedCommandMethodOutput(name, event.value == 2 ? PMARC2_METHOD : PMARC0_METHOD);
        } else if (command == 't' && CommandEventActionIs(event, "Tested")) {
            const std::wstring name = event.wide_name.empty() ? StringToWString(event.name) : event.wide_name;
            output += "Tested   " + CommandLeafField(name, 25);
            if (event.non_msdos) output += " : " + WideStringToMultiByte(
                UseEnglishDialogResources() ? L"binary file from a different OS."
                    : L"MS-DOS で作成されたバイナリファイルではありません", CommandOutputCodePage());
            output += "  ";
            if (event.value != 0) output += "CRC error!";
            output += "\r\n";
        } else if ((command == 'e' || command == 'x' || command == 'p') &&
                   CommandEventActionIs(event, "Melted")) {
            const std::wstring name = event.wide_name.empty() ? StringToWString(event.name) : event.wide_name;
            if (event.directory) {
                output += "Melted   " + CommandNameField(name, 25) + "\r\n";
                continue;
            }
            output += "Melted   " + CommandLeafField(name, 25);
            if (cancellation && event.non_msdos) output += " : " + WideStringToMultiByte(
                UseEnglishDialogResources() ? L"binary file from a different OS."
                    : L"MS-DOS で作成されたバイナリファイルではありません", CommandOutputCodePage());
            output += "  ";
            if (event.value != 0) output += "CRC error!";
            output += "\r\n";
        }
    }
    if (command == 'e' || command == 'x') output += "\r\n";
    return output;
}

static std::string BuildCompatiblePrintReadFailureOutput(
    const CommandArchiveSnapshot& archive,
    const std::vector<CommandEvent>& events,
    const CommandOutputArchive& output_archive) {
    std::string output = BuildCompatibleActionOutput('p', archive, events);
    size_t processed_members = 0;
    for (const CommandEvent& event : events) {
        if (CommandEventActionIs(event, "Melted") ||
            CommandEventActionIs(event, "UnsupportedMethod")) {
            ++processed_members;
        }
    }
    while (processed_members < output_archive.members.size() &&
           IsPmarcMethod(output_archive.members[processed_members].method)) {
        ++processed_members;
    }
    if (processed_members < output_archive.members.size()) {
        const LzHeader& header = output_archive.members[processed_members];
        output += "Melted   " + CommandLeafField(
            HeaderNameToWString(header, ConfiguredArchiveCodePage()), 25) + "  \r\n";
    }
    return output;
}

static std::string CommandMemberName(const LzHeader& header, const bool full_path) {
    const std::wstring name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
    if (full_path) return WideStringToMultiByte(name, CommandOutputCodePage());
    const size_t separator = name.find_last_of(L"/\\");
    return WideStringToMultiByte(separator == std::wstring::npos ? name : name.substr(separator + 1),
                                 CommandOutputCodePage());
}

static bool CommandMemberHasDirectory(const LzHeader& header) {
    const std::wstring name = HeaderNameToWString(header, ConfiguredArchiveCodePage());
    return name.find_first_of(L"/\\") != std::wstring::npos;
}

static int g_command_path_mode = 0;
static int g_command_recursive_mode = 0;

static wchar_t FoldArchiveCharacter(wchar_t value) {
    // 元 DLL の CharUpperW と同じ Windows の文字変換を使う。CRT の C ロケールでは不足する。
    CharUpperBuffW(&value, 1);
    return value;
}

static bool CommandCharacterEqual(const char first, const char second) {
    return LowerCharacter(first) == LowerCharacter(second);
}

static bool CommandCharacterEqual(const wchar_t first, const wchar_t second) {
    return FoldArchiveCharacter(first) == FoldArchiveCharacter(second);
}

template<typename String>
static bool CommandComponentMatches(String pattern, const String& name) {
    // DOS の末尾 .* は省略可能。*.*.* や *.txt.* にも同じ規則が適用される。
    if (!pattern.empty() && pattern.back() == '.') {
        pattern.pop_back();
        if (name.find('.') != std::string::npos && pattern.find('.') == std::string::npos)
            return false;
    }
    const auto matches = [&]() {
        // 角括弧は文字クラスではない。
        size_t p = 0, n = 0, star = String::npos, retry = 0;
        while (n < name.size()) {
            if (p < pattern.size() && (pattern[p] == '?' ||
                CommandCharacterEqual(pattern[p], name[n]))) {
                ++p;
                ++n;
            } else if (p < pattern.size() && pattern[p] == '*') {
                star = p++;
                retry = n;
            } else if (star != String::npos) {
                p = star + 1;
                n = ++retry;
            } else {
                return false;
            }
        }
        while (p < pattern.size() && pattern[p] == '*') ++p;
        return p == pattern.size();
    };
    while (!matches()) {
        if (pattern.size() < 2 || pattern[pattern.size() - 2] != '.' || pattern.back() != '*')
            return false;
        pattern.resize(pattern.size() - 2);
    }
    return true;
}

static std::vector<std::string> CommandPathComponents(std::string path) {
    NormalizeAnsiSeparators(path);
    std::vector<std::string> components;
    size_t start = 0;
    do {
        const size_t end = path.find('/', start);
        components.push_back(path.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) break;
        start = end + 1;
    } while (start <= path.size());
    return components;
}

static std::vector<std::wstring> CommandPathComponents(std::wstring path) {
    std::replace(path.begin(), path.end(), L'\\', L'/');
    std::vector<std::wstring> components;
    size_t start = 0;
    do {
        const size_t end = path.find(L'/', start);
        components.push_back(path.substr(start, end == std::wstring::npos ? end : end - start));
        if (end == std::wstring::npos) break;
        start = end + 1;
    } while (start <= path.size());
    return components;
}

template<typename String>
static bool CommandPatternMatches(const String& pattern, const String& name,
                                   const bool exclusion, const int path_mode,
                                   const int recursive_mode) {
    const auto wanted = CommandPathComponents(pattern);
    const auto actual = CommandPathComponents(name);
    // 除外名には通常の -r は適用されず、-p2 のパス前方照合だけが作用する。
    const int recursion = exclusion ? (path_mode == 2 ? 2 : 0) : recursive_mode;
    if (recursion == 2) {
        if (wanted.size() > actual.size()) return FALSE;
        for (size_t index = 0; index < wanted.size(); ++index)
            if (!CommandComponentMatches(wanted[index], actual[index])) return FALSE;
        return TRUE;
    }
    if (wanted.size() == 1) {
        if (path_mode != 0 && actual.size() != 1) return FALSE;
        return CommandComponentMatches(wanted.back(), actual.back()) ? TRUE : FALSE;
    }
    if (wanted.size() > actual.size() || (recursion != 1 && wanted.size() != actual.size()))
        return FALSE;
    for (size_t index = 0; index + 1 < wanted.size(); ++index)
        if (!CommandComponentMatches(wanted[index], actual[index])) return FALSE;
    return CommandComponentMatches(wanted.back(), actual.back()) ? TRUE : FALSE;
}

extern "C" int Lha_CommandPatternMatches(const char* pattern, const char* name,
                                         const int exclusion) {
    if (pattern && name && g_unicode_mode.load())
        return CommandPatternMatches(StringToWString(pattern), StringToWString(name),
            exclusion != FALSE, g_command_path_mode, g_command_recursive_mode) ? TRUE : FALSE;
    return pattern && name && CommandPatternMatches(std::string(pattern), std::string(name),
        exclusion != FALSE, g_command_path_mode, g_command_recursive_mode) ? TRUE : FALSE;
}

extern "C" int Lha_CommandHeaderPatternMatches(const char* pattern, const LzHeader* header,
                                               const int exclusion) {
    if (!pattern || !header) return FALSE;
    // W 命令の UTF-8 引数は、公開 UnicodeMode が無効でも保存名の符号化と分けて照合する。
    if (!g_unicode_mode.load() && !g_wide_command_utf8_input)
        return Lha_CommandPatternMatches(pattern, header->name, exclusion);
    return CommandPatternMatches(StringToWString(pattern), HeaderNameToWString(*header, ConfiguredArchiveCodePage()),
        exclusion != FALSE, g_command_path_mode, g_command_recursive_mode) ? TRUE : FALSE;
}

static bool ArchivePatternMatches(const std::wstring& pattern, const std::wstring& name,
                                   const bool full_path, const bool recursive) {
    if (pattern.empty() || name.empty()) return false;
    std::wstring wanted = pattern, actual = name;
    std::replace(wanted.begin(), wanted.end(), L'\\', L'/');
    std::replace(actual.begin(), actual.end(), L'\\', L'/');
    const bool has_path = pattern.find_first_of(L"/\\:") != std::wstring::npos;
    if (!has_path && !full_path) actual.erase(0, actual.find_last_of(L'/') + 1);
    const size_t leaf = actual.find_last_of(L'/') + 1;
    const size_t width = wanted.size() + 1;
    std::vector<signed char> memo((actual.size() + 1) * width, -1);
    const auto match = [&](const auto& self, size_t n, size_t p) -> bool {
        auto& cached = memo[n * width + p];
        if (cached >= 0) return cached != 0;
        const auto evaluate = [&]() -> bool {
            // ./ は同階層を表す。元の区切り位置を残し、最後の / でだけ再帰する。
            if (p + 1 < wanted.size() && wanted[p] == L'.' && wanted[p + 1] == L'/' &&
                (p == 0 || wanted[p - 1] == L'/')) return self(self, n, p + 2);
            if (p == wanted.size()) return n == actual.size();
            const wchar_t unit = wanted[p];
            const bool at_boundary = n == actual.size() || actual[n] == L'/';
            if (unit == L'*') {
                const wchar_t next = p + 1 < wanted.size() ? wanted[p + 1] : L'\0';
                size_t retry = n;
                for (;;) {
                    while (retry < actual.size() && actual[retry] != L'/' &&
                           FoldArchiveCharacter(actual[retry]) != FoldArchiveCharacter(next)) ++retry;
                    if (next == L'.' && (p + 2 == wanted.size() || wanted[p + 2] == L'/'))
                        return self(self, retry, p + 1);
                    if (self(self, retry, p + 1)) return true;
                    if (retry == actual.size() || actual[retry] == L'/') return false;
                    ++retry;
                }
            }
            if (unit == L'.') {
                if (p + 1 < wanted.size() && wanted[p + 1] == L'*' && at_boundary)
                    return self(self, n, p + 2);
                if ((p + 1 == wanted.size() || wanted[p + 1] == L'/') && at_boundary)
                    return self(self, n, p + 1);
            }
            // 元 DLL の再帰照合は終端の先も進むことがある。候補側は文字列内に限定する。
            if (n == actual.size()) return false;
            if (unit == L'/' && recursive && wanted.find(L'/', p + 1) == std::wstring::npos) {
                const size_t next = n < leaf ? leaf : n + 1;
                return self(self, next, p + 1);
            }
            if (unit == L'?' || FoldArchiveCharacter(unit) == FoldArchiveCharacter(actual[n]))
                return self(self, n + 1, p + 1);
            return false;
        };
        cached = evaluate() ? 1 : 0;
        return cached != 0;
    };
    return match(match, 0, 0);
}

static bool CommandMemberMatches(const LzHeader& header,
                                 const std::vector<std::string>& patterns,
                                 const std::vector<std::string>& exclusions) {
    bool included = patterns.empty() && Lha_CommandHeaderPatternMatches("*", &header, FALSE);
    for (const auto& pattern : patterns) {
        if (Lha_CommandHeaderPatternMatches(pattern.c_str(), &header, FALSE)) {
            included = true;
            break;
        }
    }
    if (!included) return false;
    for (const auto& pattern : exclusions)
        if (Lha_CommandHeaderPatternMatches(pattern.c_str(), &header, TRUE)) return false;
    return true;
}

static bool ResolveCommandArchive(const std::string& requested,
                                  std::string& resolved, FILE** file) {
    if (!file) return false;
    *file = nullptr;
    std::vector<std::string> candidates{requested};
    const size_t separator = requested.find_last_of("/\\");
    const size_t extension = requested.find_last_of('.');
    if (extension == std::string::npos ||
        (separator != std::string::npos && extension < separator)) {
        candidates.push_back(requested + ".lzh");
    }

    for (const std::string& candidate : candidates) {
        wchar_t full_path[FILENAME_LENGTH * 4]{};
        const DWORD length = GetFullPathNameW(StringToWString(candidate).c_str(),
                                              static_cast<DWORD>(_countof(full_path)),
                                              full_path, nullptr);
        if (length == 0 || length >= _countof(full_path)) continue;
        if (_wfopen_s(file, full_path, L"rb") != 0 || !*file) continue;

        wchar_t canonical[FILENAME_LENGTH * 4]{};
        const DWORD canonical_length = GetLongPathNameW(
            full_path, canonical, static_cast<DWORD>(_countof(canonical)));
        resolved = WStringToString(canonical_length > 0 && canonical_length < _countof(canonical)
                            ? canonical : full_path);
        NormalizeAnsiSeparators(resolved);

        if (WidePathIsSfx(full_path, *file) && seek_lha_header(*file) != 0) {
            fclose(*file);
            *file = nullptr;
            continue;
        }
        return true;
    }
    return false;
}

static bool ReadCommandOutputArchive(const std::string& requested,
                                     const std::vector<std::string>& patterns,
                                     const std::vector<std::string>& exclusions,
                                     const std::vector<BOOL>* selections,
                                     const bool check_foreign, const bool tested_members,
                                     CommandOutputArchive& result) {
    FILE* file = nullptr;
    if (!ResolveCommandArchive(requested, result.path, &file)) return false;
    const __int64 file_size = _filelengthi64(_fileno(file));
    DWORD tail_error = ERROR_SUCCESS;
    if (check_foreign) HasForeignArchiveTail(file, file_size, tail_error);
    if (tail_error != ERROR_SUCCESS) result.system_error = tail_error;

    struct _stat64 status{};
    std::string native_path = result.path;
    std::replace(native_path.begin(), native_path.end(), '/', '\\');
    if ((UsesUnicodeFilePath(native_path.c_str())
             ? _wstat64(FilePathToWide(native_path.c_str()).c_str(), &status)
             : _stat64(native_path.c_str(), &status)) == 0)
        result.write_time = status.st_mtime;

    LzHeader header{};
    size_t selection_index = 0;
    bool first_header = true;
    while (true) {
        const __int64 header_start = _ftelli64(file);
        if (!ReadCompatibleCommandHeader(file, header, first_header, result.read_error,
                                         &result.recovered_header, &result.initial_missing_crc,
                                         &result.read_warning)) {
            if (result.read_error != 0)
                result.system_error = result.read_error == ERROR_FILE_STYLE
                    ? (result.initial_missing_crc ? ERROR_NO_MORE_FILES : ERROR_HANDLE_EOF)
                    : ERROR_SUCCESS;
            else if (result.read_warning != 0) result.system_error = ERROR_SUCCESS;
            else if (file_size - header_start < 21) result.system_error = ERROR_HANDLE_EOF;
            break;
        }
        first_header = false;
        const __int64 data_start = _ftelli64(file);
        if (data_start < 0 || header.packed_size < 0 ||
            static_cast<unsigned __int64>(header.packed_size) >
                static_cast<unsigned __int64>(INT64_MAX - data_start)) {
            fclose(file);
            return false;
        }
        result.last_pattern_matched = CommandMemberMatches(header, patterns, {});
        if (result.last_pattern_matched && CommandMemberMatches(header, patterns, exclusions)) {
            const bool unsupported = tested_members && IsPmarcMethod(header.method);
            const bool selected = unsupported || !selections ||
                (selection_index < selections->size() && (*selections)[selection_index] != FALSE);
            // 非対応項目には列挙がないため、後続項目の拒否結果を消費しない。
            if (!unsupported) ++selection_index;
            if (selected) {
                result.members.push_back(header);
                result.member_crc_errors.push_back(std::binary_search(
                    g_command_test_crc_errors.begin(), g_command_test_crc_errors.end(), data_start));
                if (tested_members && !unsupported && MethodNumber(header.method) != LZHDIRS_METHOD_NUM)
                    result.system_error = ERROR_INVALID_PARAMETER;
            }
        }
        if (_fseeki64(file, data_start + header.packed_size, SEEK_SET) != 0) {
            fclose(file);
            return false;
        }
    }
    fclose(file);
    return true;
}

static unsigned int CommandRatio(const off_t packed, const off_t original) {
    if (packed <= 0 || original <= 0) return 0;
    const long double scaled = static_cast<long double>(packed) * 1000.0L /
                               static_cast<long double>(original);
    return static_cast<unsigned int>(scaled);
}

static std::string CommandDateAndSizes(const off_t original, const off_t packed,
                                       const time_t stamp) {
    struct tm local{};
    if (localtime_s(&local, &stamp) != 0) memset(&local, 0, sizeof(local));
    const unsigned int ratio = CommandRatio(packed, original);
    char value[128]{};
    _snprintf_s(value, _countof(value), _TRUNCATE,
                "%10lld%10lld %3u.%1u%% %02d-%02d-%02d %02d:%02d:%02d",
                static_cast<long long>(original), static_cast<long long>(packed),
                ratio / 10U, ratio % 10U, local.tm_year % 100, local.tm_mon + 1,
                local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec);
    return value;
}

static std::string CommandListDataLine(const LzHeader& header) {
    std::string line(14, ' ');
    line += CommandDateAndSizes(header.original_size, header.packed_size,
                                header.unix_last_modified_stamp);
    const int member_attributes = HeaderAttributes(header);
    char attributes[5] = {'-', '-', '-', 'w', '\0'};
    if ((member_attributes & FA_ARCH) != 0) attributes[0] = 'a';
    if ((member_attributes & FA_SYSTEM) != 0) attributes[1] = 's';
    if ((member_attributes & FA_HIDDEN) != 0) attributes[2] = 'h';
    if ((member_attributes & FA_RDONLY) != 0) attributes[3] = 'o';
    char suffix[32]{};
    if (header.has_crc) {
        _snprintf_s(suffix, _countof(suffix), _TRUNCATE, " %s %.5s %04X",
                    attributes, header.method, header.crc & 0xffffU);
    } else {
        _snprintf_s(suffix, _countof(suffix), _TRUNCATE, " %s %.5s ****",
                    attributes, header.method);
    }
    line += suffix;
    return line;
}

static std::string MissingHeaderCrcMessage(const LzHeader& header) {
    if (header.header_level == 0 || header.has_header_crc) return std::string();
    return WideStringToMultiByte(L"ヘッダ CRC が存在しません : '",
                                 CommandOutputCodePage()) +
           CommandMemberName(header, true) + "'\r\n";
}

static std::string BuildCompatibleListHeading(const std::string& archive_path, const bool names_only) {
    std::string output;
    if (!names_only) {
        output = "\r\nListing of archive : " + archive_path + "\r\n\r\n";
        output += "  Name          Original    Packed  Ratio   Date     Time   Attr Type  CRC\r\n";
        output += "--------------  --------  -------- ------ -------- -------- ---- ----- ----\r\n";
    }
    return output;
}

static std::string BuildForeignArchiveCommandOutput(const char command, const std::string& archive_path,
                                                     const bool names_only, const UINT code_page) {
    std::string output;
    if (command == 'l' || command == 'v') output = BuildCompatibleListHeading(archive_path, names_only);
    else if (command != 'p') {
        const char* title = command == 't' ? "Testing" : command == 'f' ? "Freshening"
            : command == 'd' ? "Deleting from" : command == 'e' || command == 'x' ? "Extracting from"
            : command == 's' ? "Making SFX of" : "Updating";
        output = "\r\n" + std::string(title) + " archive : " + archive_path + "\r\n\r\n";
    }
    std::string error_path = archive_path;
    if (command == 's') {
        const size_t extension = error_path.find_last_of('.');
        const size_t separator = error_path.find_last_of('/');
        if (extension != std::string::npos && (separator == std::string::npos || extension > separator))
            error_path.erase(extension);
        error_path += ".EXE";
    }
    return output + "\r\n" + WideStringToMultiByte(
        L"指定された書庫ファイルは LZH 形式ではありません (on execute_cmd (inithdr)) : '", code_page)
        + error_path + "'\r\n";
}

static std::string BuildRewriteForeignSourceOutput(const CommandArchiveSnapshot& archive,
                                                   const std::vector<CommandEvent>& events,
                                                   std::wstring source_path) {
    std::replace(source_path.begin(), source_path.end(), L'\\', L'/');
    return BuildCompatibleActionOutput('j', archive, events) + "\r\n" +
        WideStringToMultiByte(L"指定された書庫ファイルは LZH 形式ではありません (on arccopy) : '",
                              CommandOutputCodePage()) +
        WideStringToMultiByte(source_path, CommandOutputCodePage()) + "'\r\n";
}

static DWORD ForeignArchiveCommandSystemError(const char command) {
    return command == 'f' || command == 'd' || command == 'c' || command == 'n' || command == 'y' || command == 's'
        ? ERROR_INVALID_PARAMETER : ERROR_NO_MORE_FILES;
}

static bool HasExtractCommandCancellation(const char command) {
    return (command == 't' || command == 'p' || command == 'e' || command == 'x') &&
        (g_command_progress_cancel_state == ARCEXTRACT_OPEN ||
         g_command_progress_cancel_state == ARCEXTRACT_BEGIN ||
         g_command_progress_cancel_state == ARCEXTRACT_INPROCESS);
}

static bool HasCompressionCommandCancellation(const char command) {
    return (command == 'a' || command == 'u' || command == 'f' || command == 'm') &&
        (g_command_progress_cancel_state == ARCEXTRACT_OPEN ||
         g_command_progress_cancel_state == ARCEXTRACT_BEGIN ||
         g_command_progress_cancel_state == ARCEXTRACT_INPROCESS ||
         g_command_progress_cancel_state == 5 || g_command_progress_cancel_state == 6);
}

static std::string BuildExtractCommandCancellationOutput(const char command,
                                                         const CommandArchiveSnapshot& archive) {
    std::string output = BuildCompatibleActionOutput(command, archive, g_command_events, true);
    if (command == 'e' || command == 'x') output.resize(output.size() - 2);
    if (g_command_progress_cancel_state != ARCEXTRACT_INPROCESS) output += "\r\n";
    output += WideStringToMultiByte(CommandCancellationMessage() + L" (on " +
        CommandCancellationLocation() + L")\r\n", CommandOutputCodePage());
    return output;
}

static std::string BuildCompatibleListOutput(const CommandOutputArchive& archive,
                                             const bool verbose_names,
                                             const bool names_only) {
    std::string output = BuildCompatibleListHeading(archive.path, names_only);

    unsigned long long original_total = 0;
    unsigned long long packed_total = 0;
    for (const LzHeader& header : archive.members) {
        output += MissingHeaderCrcMessage(header);
        const std::string name = CommandMemberName(header, verbose_names);
        if (names_only) {
            output += name + "\r\n";
            continue;
        }

        std::string data = CommandListDataLine(header);
        if (verbose_names) {
            output += name + "\r\n" + data + "\r\n";
        } else {
            data = data.substr(0, 2) + CommandLeafField(HeaderNameToWString(header,
                ConfiguredArchiveCodePage()), 12) + data.substr(14);
            if (CommandMemberHasDirectory(header)) data[0] = '+';
            output += data + "\r\n";
        }
        original_total += static_cast<unsigned long long>(header.original_size);
        packed_total += static_cast<unsigned long long>(header.packed_size);
    }

    if (archive.read_error != 0) return output;
    if (names_only) return output + "\r\n";
    if (archive.members.empty()) return output + "  no file\r\n\r\n";

    output += "--------------  --------  -------- ------ -------- -------- ---- ----- ----\r\n";
    char prefix[32]{};
    _snprintf_s(prefix, _countof(prefix), _TRUNCATE, "   %3u files  ",
                static_cast<unsigned int>(archive.members.size()));
    output += prefix;
    output += CommandDateAndSizes(static_cast<off_t>(original_total),
                                  static_cast<off_t>(packed_total), archive.write_time);
    output += "\r\n\r\n";
    return output;
}

static std::string BuildCompatibleTestOutput(const CommandOutputArchive& archive) {
    std::string output = "\r\nTesting archive : " + archive.path + "\r\n\r\n";
    if (archive.recovered_header) output += WideStringToMultiByte(
        L"情報：最初のヘッダの前に余分なデータがあります。\r\n\r\n", CommandOutputCodePage());
    const std::string non_msdos = WideStringToMultiByte(
        L"MS-DOS で作成されたバイナリファイルではありません",
        CommandOutputCodePage());
    for (size_t index = 0; index < archive.members.size(); ++index) {
        const LzHeader& header = archive.members[index];
        if (IsPmarcMethod(header.method)) {
            output += UnsupportedCommandMethodOutput(
                HeaderNameToWString(header, ConfiguredArchiveCodePage()), header.method);
            continue;
        }
        output += MissingHeaderCrcMessage(header);
        output += "Tested   " + CommandLeafField(HeaderNameToWString(header, ConfiguredArchiveCodePage()), 25);
        if (header.extend_type != EXTEND_GENERIC && header.extend_type != EXTEND_MSDOS) {
            output += " : " + non_msdos + "  ";
        } else output += "  ";
        if (archive.member_crc_errors[index]) output += "CRC error!";
        output += "\r\n";
    }
    return archive.read_error == 0 ? output + "\r\n" : output;
}

static std::string BuildCommandHeaderErrorOutput(const std::string& archive_path,
                                                  const int error = ERROR_HEADER_CRC,
                                                  const CommandReadFailure read_failure = CommandReadFailure::None) {
    const UINT code_page = CommandOutputCodePage();
    if (error == ERROR_CANNOT_READ) {
        const char* location = read_failure == CommandReadFailure::CopyFile ? "copyfile" : "fillbuf";
        return WideStringToMultiByte(
            L"ファイルの読み込み時に読み込みエラーが生じました (on ", code_page) +
            location + " : 38) : '" + archive_path + "'\r\n";
    }
    if (error == ERROR_SET_POINT) {
        return "\r\n" + WideStringToMultiByte(
            L"ファイル・ポインタの設定ができません (on execute_cmd (gethdr) : 87) : '", code_page) +
            archive_path + "'\r\n";
    }
    if (error == ERROR_UNEXPECTED_EOF) {
        return "\r\n" + WideStringToMultiByte(
            L"ヘッダ情報が欠落しています (on execute_cmd (gethdr)) : '", code_page) +
            archive_path + "'\r\n";
    }
    const wchar_t* message = error == ERROR_HDR_EXPLOIT
        ? L"脆弱性利用が疑われるヘッダです (on execute_cmd (gethdr)) : '"
        : L"書庫ファイルのヘッダの CRC エラーです (on execute_cmd (gethdr)) : '";
    return "\r\n" + WideStringToMultiByte(message, code_page) + archive_path + "'\r\n";
}

static std::string BuildCommandHeaderWarningOutput(const std::string& archive_path,
                                                    const int warning,
                                                    const bool print_output = false) {
    if (warning != ERROR_NO_END_MARK && warning != ERROR_INVALID_END_MARK) return std::string();
    const wchar_t* message = warning == ERROR_INVALID_END_MARK
        ? L"不正なエンドマークです (on execute_cmd (gethdr)) : '"
        : L"エンドマークが存在しません (on execute_cmd (gethdr)) : '";
    // p は本文で上書きする前のログでも、警告の直前に空行を置き、直後は一行だけとする。
    return std::string(print_output ? "\r\n" : "") +
        WideStringToMultiByte(message, CommandOutputCodePage()) + archive_path +
        (print_output ? "'\r\n" : "'\r\n\r\n");
}

static void CopyCompatibleCommandOutput(const std::string& output,
                                        char* destination, const DWORD capacity) {
    if (!destination || capacity == 0) return;
    const size_t length = (std::min)(output.size(), static_cast<size_t>(capacity - 1));
    if (length != 0) memcpy(destination, output.data(), length);
    destination[length] = '\0';
}

static std::vector<std::string> SplitCompatibleSwitches(const std::string& argument) {
    std::vector<std::string> switches;
    if (argument.size() < 2) return switches;
    const char prefix = argument[0];
    const std::string content = argument.substr(1);
    size_t index = 0;
    bool extended = false;
    auto numeric_value = [&]() {
        const size_t start = index;
        if (index < content.size() && (content[index] == '+' || content[index] == '-')) ++index;
        while (index < content.size() && isdigit(static_cast<unsigned char>(content[index]))) ++index;
        return content.substr(start, index - start);
    };
    auto append = [&](const std::string& name, const std::string& value) {
        switches.push_back(std::string(1, prefix) + name + value);
    };

    while (index < content.size()) {
        const char character = LowerCharacter(content[index++]);
        if (character == 'j') {
            extended = !extended;
            continue;
        }
        std::string name = extended ? "j" + std::string(1, character)
                                    : std::string(1, character);
        if (character == 'g') {
            if (index == content.size()) break;
            name = "g" + std::string(1, LowerCharacter(content[index++]));
        }

        // jy は値を 1 文字だけ取り、最初の不正文字以降を読み進めない。
        if (name == "jy") {
            while (index < content.size()) {
                const char raw = content[index++];
                const char flag = LowerCharacter(raw);
                if (std::string("cdkno").find(flag) == std::string::npos) {
                    append(name + raw, "");
                    break;
                }
                std::string value;
                if (index < content.size() && (content[index] == '+' || content[index] == '-' ||
                    isdigit(static_cast<unsigned char>(content[index])))) value += content[index++];
                append(name + flag, value);
            }
            break;
        }

        // js/jt/gy の残りは、通常スイッチではなくサブフラグ列として解釈する。
        if (name == "js" || name == "jt" || name == "gy") {
            while (index < content.size()) {
                const std::string sub = name + LowerCharacter(content[index++]);
                const bool string_value = sub == "gyd" || sub == "gye" ||
                    sub == "gyt" || sub == "gyw" ||
                    (sub == "jtz" && index < content.size() &&
                     content[index] != '0' && content[index] != '1' &&
                     content[index] != '+' && content[index] != '-');
                if (string_value) {
                    append(sub, content.substr(index));
                    index = content.size();
                } else if (sub == "jso" || sub == "jse") {
                    // 真偽値は 1 文字。残りの数字も次の js サブスイッチとして扱う。
                    std::string value;
                    if (index < content.size() && (content[index] == '+' || content[index] == '-' ||
                        isdigit(static_cast<unsigned char>(content[index])))) value += content[index++];
                    append(sub, value);
                } else if (name == "js" && isdigit(static_cast<unsigned char>(sub.back()))) {
                    append(sub, "");
                } else {
                    append(sub, numeric_value());
                }
            }
            break;
        }

        if (name == "+" && index < content.size() &&
            (content[index] == '+' || content[index] == '-')) {
            append(name, content.substr(index++, 1));
        } else if (name == "jm") {
            std::string value;
            if (index < content.size()) {
                const char method = LowerCharacter(content[index]);
                if (method == 'm') {
                    ++index;
                    append("jmm", numeric_value());
                    continue;
                }
                if (isdigit(static_cast<unsigned char>(method)) || method == 'a' || method == 'm')
                    value += content[index++];
            }
            append(name, value);
        } else if (name == "jd") {
            std::string value = numeric_value();
            // 予約容量の K は次の拡張スイッチではなく、10進の1000倍接尾辞。
            if (index < content.size() && LowerCharacter(content[index]) == 'k') value += content[index++];
            append(name, value);
        } else if (name == "jw" || name == "gw") {
            std::string value;
            if (index < content.size() &&
                (LowerCharacter(content[index]) == 'j' || LowerCharacter(content[index]) == 'e'))
                value += content[index++];
            value += numeric_value();
            append(name, value);
        } else if (name == "jb" || name == "jx" || name == "jo" || name == "jz" ||
                   name == "gb" || name == "gl" || name == "gr" || name == "gx" ||
                   ((name == "w" || name == "z") && index < content.size() &&
                    !isdigit(static_cast<unsigned char>(content[index])) &&
                    content[index] != '+' && content[index] != '-')) {
            append(name, content.substr(index));
            break;
        } else {
            append(name, numeric_value());
        }
    }
    return switches;
}

template<typename String>
struct ParsedCommandArgument {
    String value;
    bool is_switch;
    bool force_file;
};

template<typename String, typename Reader, typename Splitter>
static bool ParseCompatibleArguments(const std::vector<String>& tokens,
    std::vector<ParsedCommandArgument<String>>& arguments, Reader read_response,
    Splitter split_switches) {
    struct PendingArgument { String value; bool from_response; };
    std::vector<PendingArgument> pending;
    for (const auto& token : tokens) pending.push_back({token, false});
    typename String::value_type response_char = '@';
    bool enable_response = true;
    bool enable_dash_switch = true;
    for (size_t index = 0; index < pending.size(); ++index) {
        const String arg = pending[index].value;
        if (arg.empty()) continue;
        if (arg[0] == '/' || (enable_dash_switch && arg[0] == '-')) {
            if (arg.size() >= 2 && arg[1] == '-') {
                const String value = arg.substr(2);
                if (value.empty() || (value.size() == 1 && value[0] == '1')) enable_response = false;
                else if (value.size() == 1 && value[0] == '0') {
                    response_char = '@'; enable_response = true; enable_dash_switch = true;
                } else if (value.size() == 1 && value[0] == '2') {
                    enable_response = false; enable_dash_switch = false;
                } else if (value.size() == 1 && value[0] == '3') enable_dash_switch = false;
                else if (!value.empty()) { response_char = value[0]; enable_response = true; }
                continue;
            }
            for (const auto& option : split_switches(arg)) {
                if (option.size() >= 3 && (option[1] == 'g' || option[1] == 'G') &&
                    (option[2] == 'b' || option[2] == 'B'))
                    arguments.push_back({option.substr(3), false, true});
                else arguments.push_back({option, true, false});
            }
        } else if (enable_response && !pending[index].from_response && arg[0] == response_char) {
            std::vector<String> response_tokens;
            if (!read_response(arg.substr(1), response_tokens)) return false;
            std::vector<PendingArgument> response_args;
            for (const auto& token : response_tokens) response_args.push_back({token, true});
            pending.insert(pending.begin() + index + 1, response_args.begin(), response_args.end());
        } else arguments.push_back({arg, false, false});
    }
    return true;
}

static int FinishCommandFailure(const int result, const DWORD system_error,
                                const DWORD win32_error) {
    g_capture_buffer = nullptr;
    g_capture_buffer_size = 0;
    g_capture_buffer_written = 0;
    g_running = false;
    g_last_error.clear();
    g_last_error_code = 0;
    g_last_system_error = system_error;
    SetLastError(win32_error);
    return result;
}

static int CommandSwitchValue(const std::string& option, const size_t offset,
                               const int current, const int maximum) {
    const std::string value = option.substr(offset);
    if (value.empty() || value == "+") return 1;
    if (value == "-") return 0;
    char* end = nullptr;
    const long parsed = strtol(value.c_str(), &end, 10);
    return end && *end == '\0' && parsed >= 0 && parsed <= maximum
        ? static_cast<int>(parsed) : current;
}

static void ApplyCommandUpdateSwitch(CommandUpdatePolicy& policy, const std::string& option) {
    if (option.empty()) return;
    if (option[0] == 'a') {
        policy.restore_attributes = CommandSwitchValue(option, 1, policy.restore_attributes ? 1 : 0, 2) != 0;
    } else if (option[0] == 'c') {
        policy.ignore_timestamp = CommandSwitchValue(option, 1, policy.ignore_timestamp ? 1 : 0, 1) != 0;
    } else if (option[0] == 'u' || option.rfind("gf", 0) == 0) {
        const bool existing = option[0] == 'g';
        const int value = CommandSwitchValue(option, existing ? 2 : 1, policy.comparison, 3);
        policy.existing_only = existing;
        if (existing) policy.new_only = false;
        if (value == 0) policy.ignore_timestamp = true;
        else policy.comparison = value;
    } else if (option.rfind("jn", 0) == 0) {
        policy.new_only = CommandSwitchValue(option, 2, policy.new_only ? 1 : 0, 1) != 0;
    } else if (option[0] == 'm') {
        policy.overwrite_mode = option.size() > 1 && option[1] == '2' ? 2 :
            option.size() > 1 && (option[1] == '0' || option[1] == '-') ? 0 : 1;
        policy.assume_overwrite = policy.assume_directory = policy.overwrite_mode != 0;
    } else if (option[0] == 'f') {
        policy.reserved_disk_space = 0;
        policy.check_disk_space = option.size() > 1 && (option[1] == '0' || option[1] == '-');
    } else if (option.rfind("jd", 0) == 0) {
        policy.check_disk_space = option.size() <= 2 || option[2] != '-';
        policy.reserved_disk_space = 0;
        size_t index = 2;
        // +/- は有効・無効指定であり、数値の符号としては扱わない。
        if (index < option.size() && option[index] != '+' && option[index] != '-') {
            for (; index < option.size() && option[index] >= '0' && option[index] <= '9'; ++index) {
                const ULONGLONG digit = option[index] - '0';
                policy.reserved_disk_space = policy.reserved_disk_space > (ULLONG_MAX - digit) / 10
                    ? ULLONG_MAX : policy.reserved_disk_space * 10 + digit;
            }
            if (index < option.size() && option[index] == 'k')
                policy.reserved_disk_space = policy.reserved_disk_space > ULLONG_MAX / 1000
                    ? ULLONG_MAX : policy.reserved_disk_space * 1000;
        }
    } else if (option[0] == 'y') {
        policy.assume_overwrite = policy.assume_directory = policy.suppress_new_name =
            !(option.size() > 1 && (option[1] == '0' || option[1] == '-'));
    } else if (option.rfind("jy", 0) == 0) {
        for (size_t index = 2; index < option.size();) {
            const char kind = option[index++];
            if (std::string("cdkno").find(kind) == std::string::npos) break;
            int value = -1;
            if (index < option.size()) {
                const char digit = option[index];
                if ((digit >= '0' && digit <= '9') || digit == '+' || digit == '-') {
                    ++index;
                    if (digit == '0' || digit == '-') value = 0;
                    else if (digit == '1' || digit == '+') value = 1;
                }
            }
            bool* assumed = kind == 'c' ? &policy.assume_directory : kind == 'o' ? &policy.assume_overwrite :
                kind == 'n' ? &policy.suppress_new_name : kind == 'k' ? &policy.check_disk_space : nullptr;
            if (assumed) *assumed = value < 0 ? !*assumed : value != 0;
        }
    } else if (option.rfind("jse", 0) == 0) {
        const char value = option.size() > 3 ? option[3] : '\0';
        policy.stop_on_extract_error = value == '0' || value == '-' ? 0 : value == '2' ? 2 : 1;
    } else if (option.rfind("ga", 0) == 0) {
        policy.protected_attributes = CommandSwitchValue(option, 2, policy.protected_attributes, 2);
    } else if (option.rfind("gm", 0) == 0) {
        policy.suppress_errors = CommandSwitchValue(option, 2, policy.suppress_errors ? 1 : 0, 1) != 0;
    }
}

static void ReadCommandExistingMembers(const std::string& requested) {
    g_command_existing_members.clear();
    FILE* file = nullptr;
    std::string resolved;
    if (!ResolveCommandArchive(requested, resolved, &file)) return;
    LzHeader header{};
    size_t position = 0;
    while (get_header(file, &header)) {
        g_command_existing_members.emplace(HeaderNameToWString(header, ConfiguredArchiveCodePage()),
            CommandExistingMember{HeaderTimeToFileTime(header, MemberTimeKind::Write), header.original_size, position++});
        if (header.packed_size < 0 || _fseeki64(file, header.packed_size, SEEK_CUR) != 0) break;
    }
    fclose(file);
}

static void ExpandFreshenCommandInputs(const std::string& requested, const std::string& base,
    const std::vector<std::string>& patterns, const std::vector<std::string>& exclusions,
    std::vector<std::string>& files) {
    FILE* archive = nullptr;
    std::string resolved;
    if (!ResolveCommandArchive(requested, resolved, &archive)) return;
    LzHeader header{};
    while (ReadArchiveHeaderGuarded(archive, header)) {
        if (CommandMemberMatches(header, patterns, exclusions)) {
            // f は書庫の各項目から検索先を組み立て、入力ワイルドカードを直接展開しない。
            const std::wstring member = HeaderNameToWString(header, ConfiguredArchiveCodePage());
            const std::string name = WStringToString(member);
            const std::string source = base + name;
            std::string search_directory, search_pattern;
            SplitPath(NormalizeCompressionDots(source, true), search_directory, search_pattern);
            std::vector<std::string> matches;
            GlobSingle(search_directory, search_pattern, matches);
            if (!matches.empty()) {
                FreshenInput input;
                input.has_search_status = Lha_StatFile(matches.front().c_str(), &input.search_status) == 0;
                const std::string core_name = CompressionMemberName(name);
                if (core_name != name) g_forced_header_names.push_back({core_name, member});
                // f は基準側を / にそろえ、呼出元 CWD の区切りと ../ をそのまま通知する。
                std::wstring callback_source = StringToWString(source);
                std::replace(callback_source.begin(), callback_source.end(), L'\\', L'/');
                const bool relative = !source.empty() && source[0] != '/' && source[0] != '\\' &&
                    !(source.size() > 1 && source[1] == ':');
                if (relative) {
                    wchar_t current[FILENAME_LENGTH * 4]{};
                    const DWORD length = GetCurrentDirectoryW(_countof(current), current);
                    if (length && length < _countof(current)) callback_source = std::wstring(current) + L'\\' + callback_source;
                }
                input.callback_source = std::move(callback_source);
                g_freshen_callback_sources.emplace(member, std::move(input));
                files.push_back(name);
            }
        }
        if (header.packed_size < 0 || _fseeki64(archive, header.packed_size, SEEK_CUR) != 0) break;
    }
    fclose(archive);
}

extern "C" {
static void GetConfiguredCommandDefaults(bool use_registry, std::wstring& directory,
                                          std::vector<std::string>& switches);
static DWORD GetConfiguredArchiveSearchMode(DWORD mode);
}

template<typename String>
static bool UseCommandRegistry(const std::vector<ParsedCommandArgument<String>>& arguments) {
    bool use_registry = true;
    for (const auto& argument : arguments) {
        if (!argument.is_switch || argument.value.size() < 2 || argument.value[1] != '+') continue;
        const std::string value(argument.value.begin() + 2, argument.value.end());
        if (value.empty() || value == "+") use_registry = false;
        else if (value == "-") use_registry = true;
        else {
            char* end = nullptr;
            const long parsed = strtol(value.c_str(), &end, 10);
            if (end != value.c_str() && *end == '\0') use_registry = parsed <= 0;
        }
    }
    return use_registry;
}

template<typename Character>
struct CommandOutputTerminator final {
    Character* output;
    DWORD capacity;
    ~CommandOutputTerminator() {
        // 原版のコマンド API は成功・失敗とも出力領域の最後を終端する。
        if (output && capacity > 0) output[capacity - 1] = 0;
    }
};

struct ScopedThreadPriority final {
    int previous = THREAD_PRIORITY_NORMAL;
    ScopedThreadPriority() {
        const DWORD error = GetLastError();
        const HANDLE thread = GetCurrentThread();
        previous = GetThreadPriority(thread);
        if (previous == THREAD_PRIORITY_ERROR_RETURN) previous = THREAD_PRIORITY_NORMAL;
        if (g_priority == THREAD_PRIORITY_IDLE ||
            (g_priority >= THREAD_PRIORITY_LOWEST && g_priority <= THREAD_PRIORITY_HIGHEST))
            SetThreadPriority(thread, g_priority);
        SetLastError(error);
    }
    ~ScopedThreadPriority() {
        const DWORD error = GetLastError();
        SetThreadPriority(GetCurrentThread(), previous);
        SetLastError(error);
    }
};

extern "C" {

int WINAPI Unlha(HWND _hwnd, LPCSTR _szCmdLine, LPSTR _szOutput, DWORD _dwSize) {
    if (IsDllRunning()) return RecordBusyError();
    if (!_szCmdLine) return -1;
    const ScopedThreadPriority thread_priority;
    const CommandOutputTerminator<char> output_terminator{_szOutput, _dwSize};
    const CommandExtractionPaths extraction_paths;
    const CommandCompressionInputs compression_inputs;
    const CommandProgressMode progress_mode(false);
    g_print_output_completed = false;
    g_print_output_log.clear();
    g_command_header_validation = false;
    g_command_header_error = 0;

    // キャプチャバッファを設定
    if (_szOutput && _dwSize > 0) {
        g_capture_buffer = _szOutput;
        g_capture_buffer_size = _dwSize;
        g_capture_buffer_written = 0;
        g_capture_buffer[0] = '\0';
    } else {
        g_capture_buffer = nullptr;
        g_capture_buffer_size = 0;
        g_capture_buffer_written = 0;
    }

    g_hwndOwner = _hwnd;
    g_running = true;
    g_last_error.clear();
    SYSTEMTIME started_at{};
    GetSystemTime(&started_at);
    SystemTimeToFileTime(&started_at, &g_command_started_at);

    // コマンドラインをトークンに分解する（ダブルクォート考慮）
    std::vector<std::string> raw_tokens = TokenizeCommandLine(_szCmdLine);

    if (raw_tokens.empty()) {
        return FinishCommandFailure(ERROR_NOT_ARC_FILE, ERROR_INVALID_DATA, ERROR_SUCCESS);
    }

    std::vector<ParsedCommandArgument<std::string>> raw_args;
    if (!ParseCompatibleArguments(raw_tokens, raw_args, ReadResponseArguments,
                                   SplitCompatibleSwitches)) {
        const DWORD error = GetLastError();
        return FinishCommandFailure(ERROR_RESPONSE_READ, error, error);
    }
    std::wstring configured_directory;
    std::vector<std::string> configured_switches;
    GetConfiguredCommandDefaults(UseCommandRegistry(raw_args), configured_directory, configured_switches);

    // パラメータ解析
    char cmd_char = '\0';
    std::vector<std::string> file_list;
    std::vector<std::string> raw_switches = configured_switches;
    std::string log_file_path = "";
    std::string switch_warnings;
    std::vector<std::string> exclude_patterns;

    // スイッチのデフォルト設定
    // UNLHA32.DLL の初期設定: -d0 -r0 -x0 -jm2
    int recursive_mode = 0; // 0: -r0, 1: -r1, 2: -r2
    int compression_attribute_mode = 0;
    int path_match_mode = 0;
    bool is_x_specified = false;
    bool is_x_val = false;
    int jm_val = 2; // -jm2
    int dictionary_bits = 0;
    int full_dictionary = 1;
    bool is_y_val = false;
    int name_output_mode = 0;
    bool reject_foreign_data = true;
    int requested_header_level = -1;
    std::string rename_target;
    std::string comment_file;
    int sfx_mode = 0;

    // コマンド（命令）とスイッチ、ファイルリストの分類
    for (size_t i = 0; i < raw_args.size(); ++i) {
        std::string arg = raw_args[i].value;
        if (arg.empty()) continue;

        if (raw_args[i].is_switch) {
            raw_switches.push_back(arg);
        } else {
            // スイッチでない引数
            if (cmd_char == '\0') {
                // 最初の非スイッチ引数が1文字（または2文字でオプション付きの可能性もあるが基本1文字）
                // コマンド文字であるかを判定
                if (!raw_args[i].force_file &&
                    (arg.length() == 1 || (arg.length() == 2 && isalpha(arg[0])))) {
                    const char c = LowerCharacter(arg[0]);
                    if (c == 'a' || c == 'c' || c == 'd' || c == 'e' || c == 'f' || c == 'j' ||
                        c == 'l' || c == 'm' || c == 'n' || c == 'p' || c == 's' || c == 't' ||
                        c == 'u' || c == 'v' || c == 'x' || c == 'y') {
                        cmd_char = c;
                        continue;
                    }
                }
                // コマンド文字が省略されているとみなして、デフォルトの 'l' とする
                cmd_char = 'l';
            }
            file_list.push_back(arg);
        }
    }

    if (cmd_char == '\0') {
        cmd_char = 'l';
    }

    if (file_list.empty()) {
        return FinishCommandFailure(ERROR_NOT_ARC_FILE, ERROR_INVALID_DATA, ERROR_SUCCESS);
    }
    if (!configured_directory.empty()) {
        const char last = file_list.size() > 1 && !file_list[1].empty() ? file_list[1].back() : '\0';
        if (last != '/' && last != '\\' && last != ':') {
            std::string directory = WStringToString(configured_directory);
            if (!directory.empty() && directory.back() != '/' && directory.back() != '\\') directory += '\\';
            file_list.insert(file_list.begin() + 1, directory);
        }
    }
    if (cmd_char == 'd') {
        bool has_pattern = false;
        for (size_t index = 1; index < file_list.size(); ++index) {
            const char last = file_list[index].empty() ? '\0' : file_list[index].back();
            if (last != '/' && last != '\\' && last != ':') has_pattern = true;
        }
        if (!has_pattern)
            return FinishCommandFailure(ERROR_NOT_FILENAME, ERROR_INVALID_DATA, ERROR_SUCCESS);
    }

    g_command_update_policy = CommandUpdatePolicy{};
    g_command_update_policy.command = cmd_char;
    g_command_update_policy.overwrite_mode = cmd_char == 'x' ? 1 : 0;
    g_command_update_policy.assume_overwrite = g_command_update_policy.assume_directory = cmd_char == 'x';
    g_command_existing_members.clear();

    // スイッチの解析
    for (const std::string& sw : raw_switches) {
        if (sw.length() <= 1) continue;
        std::string s = sw.substr(1); // 先頭の '-' または '/' を除く
        std::transform(s.begin(), s.end(), s.begin(), LowerCharacter);

        if (s.empty()) continue;
        ApplyCommandUpdateSwitch(g_command_update_policy, s);
        if (s.rfind("jy", 0) == 0) {
            // 質問抑制フラグの値は 1 文字だけ消費し、最初の不正文字を元の大小文字で報告する。
            for (size_t index = 2; index < s.size(); ++index) {
                if (std::string("cdkno").find(s[index]) == std::string::npos) {
                    switch_warnings += "invalid switch : '-jy" + std::string(1, sw[index + 1]) + "'\r\n";
                    break;
                }
                if (index + 1 < s.size() && (isdigit(static_cast<unsigned char>(s[index + 1])) ||
                    s[index + 1] == '+' || s[index + 1] == '-')) ++index;
            }
        }
        if (s.rfind("j+", 0) == 0) switch_warnings += "invalid switch : '-j+'\r\n";
        if (s.size() == 3 && s.rfind("js", 0) == 0 && isdigit(static_cast<unsigned char>(s[2])))
            switch_warnings += "invalid switch : '-" + s + "'\r\n";
        if (s[0] >= '0' && s[0] <= '9')
            switch_warnings += "invalid switch : '-" + std::string(1, s[0]) + "'\r\n";

        // 個別対応スイッチのパース
        if (s[0] == 'a') {
            compression_attribute_mode = CommandSwitchValue(s, 1, compression_attribute_mode, 2);
        } else if (s[0] == 'd') {
            // -d1 はその位置で r2/x1 を設定し、-d0 は既存の r/x を戻さない。
            if (CommandSwitchValue(s, 1, 0, 1) != 0) {
                recursive_mode = 2;
                compression_attribute_mode = 2;
                is_x_specified = true;
                is_x_val = true;
            }
        } else if (s[0] == 'e') {
            full_dictionary = CommandSwitchValue(s, 1, full_dictionary, 2);
        } else if (s[0] == 'r') {
            recursive_mode = CommandSwitchValue(s, 1, recursive_mode, 2);
        } else if (s[0] == 'p') {
            path_match_mode = CommandSwitchValue(s, 1, path_match_mode, 2);
            if (path_match_mode == 2) recursive_mode = 2;
        } else if (s[0] == 'x') {
            is_x_specified = true;
            is_x_val = CommandSwitchValue(s, 1, is_x_val ? 1 : 0, 1) != 0;
        } else if (s.find("jmm") == 0U) {
            dictionary_bits = static_cast<int>((std::max)(12L,
                (std::min)(19L, strtol(s.c_str() + 3, nullptr, 10))));
        } else if (s.find("jm") == 0U) {
            if (s.length() >= 3 && isdigit(s[2])) {
                jm_val = s[2] - '0';
                dictionary_bits = 0;
            }
        } else if (s.find("jx") == 0U) {
            std::string pat = sw.substr(3); // 元の文字列から大文字小文字を維持して切り出す
            if (!pat.empty()) {
                exclude_patterns.push_back(pat);
            }
        } else if (s.find("gr") == 0U) {
            rename_target = sw.substr(3);
        } else if (s.find("jz") == 0U) {
            comment_file = sw.substr(3);
        } else if (s.rfind("jsg", 0) == 0) {
            reject_foreign_data = CommandSwitchValue(s, 3, reject_foreign_data, 1) != 0;
        } else if (s.rfind("jso", 0) == 0) {
            // js の真偽値は先頭 1 文字だけを消費し、省略・範囲外の数字では反転する。
            const char value = s.size() > 3 ? s[3] : '\0';
            if (value == '0' || value == '-') g_compression_reject_shared_writers = false;
            else if (value == '1' || value == '+') g_compression_reject_shared_writers = true;
            else g_compression_reject_shared_writers = !g_compression_reject_shared_writers;
        } else if (s.find("gw") == 0U) {
            if (s.size() == 2) {
                sfx_mode = 1;
            } else if (s.size() == 3 && s[2] >= '0' && s[2] <= '4') {
                sfx_mode = s[2] - '0';
            } else {
                g_capture_buffer = nullptr;
                g_capture_buffer_size = 0;
                g_capture_buffer_written = 0;
                g_running = false;
                return ERROR_INVALID_PARAMETER;
            }
        } else if (s.find("gl") == 0U) {
            log_file_path = sw.substr(3);
        } else if (s.size() == 2 && s[0] == 'h' && s[1] >= '0' && s[1] <= '2') {
            requested_header_level = s[1] - '0';
        } else if (s[0] == 'n') {
            name_output_mode = CommandSwitchValue(s, 1, name_output_mode, 2);
        } else if (s[0] == 'y') {
            is_y_val = CommandSwitchValue(s, 1, is_y_val ? 1 : 0, 1) != 0;
        }
    }

    // 原版の通常進捗通知は -n1 / -n2 で有効になり、-n0（省略値）では送信しない。
    g_command_progress_enabled = name_output_mode != 0;

    // x 命令では保存された「階層を無視」が明示の -x1 より優先される。
    if (cmd_char == 'x' && std::find(configured_switches.begin(), configured_switches.end(), "-x0") != configured_switches.end()) {
        is_x_specified = true;
        is_x_val = false;
    }
    g_command_path_mode = path_match_mode;
    g_command_recursive_mode = recursive_mode;

    // ライブラリの初期化
    lha_init_variable();
    Lha_ResetAbort();
    g_infp = NULL;
    g_outfp = NULL;
    g_update_archive_fp = NULL;
    g_new_compression_file = nullptr;
    g_new_compression_mapped = false;
    g_new_compression_allocation = 0;

    // LhaCore のグローバル変数に適用
    const bool assume_extraction_overwrite = (cmd_char == 'e' || cmd_char == 'x')
        ? g_command_update_policy.assume_overwrite || g_command_update_policy.overwrite_mode == 2
        : is_y_val || g_command_update_policy.overwrite_mode != 0;
    if (assume_extraction_overwrite || g_command_update_policy.suppress_errors) {
        force = TRUE;
    } else {
        force = FALSE;
    }
    freshen_only = (cmd_char == 'f') ? TRUE : FALSE;

    if (cmd_char == 'e' || cmd_char == 'x' || cmd_char == 'p' || cmd_char == 't')
        ignore_directory = (is_x_specified ? is_x_val : cmd_char == 'x') ? FALSE : TRUE;

    if (recursive_mode > 0) {
        recursive_archiving = TRUE;
    } else {
        recursive_archiving = FALSE;
    }

    if (!is_x_val) {
        generic_format = TRUE;
    } else {
        generic_format = FALSE;
    }

    switch (jm_val) {
        case 0: compress_method = LZHUFF0_METHOD_NUM; break;
        case 1: compress_method = LZHUFF1_METHOD_NUM; break;
        case 2: compress_method = LZHUFF5_METHOD_NUM; break;
        case 3: compress_method = LZHUFF6_METHOD_NUM; break;
        case 4: compress_method = LZHUFF7_METHOD_NUM; break;
        case 5: compress_method = LZHUFF2_METHOD_NUM; break;
        case 6: compress_method = LZHUFF3_METHOD_NUM; break;
        case 7: compress_method = LARC_METHOD_NUM; break;
        case 8: compress_method = LARC5_METHOD_NUM; break;
        default: compress_method = LZHUFF5_METHOD_NUM; break;
    }
    g_command_dictionary_bits = dictionary_bits;
    if (dictionary_bits != 0)
        compress_method = dictionary_bits <= 13 ? LZHUFF5_METHOD_NUM :
            dictionary_bits <= 15 ? LZHUFF6_METHOD_NUM :
            dictionary_bits == 16 ? LZHUFF7_METHOD_NUM : LZHUFFX_METHOD_NUM;
    if (full_dictionary == 0) {
        if (compress_method == LZHUFF5_METHOD_NUM) g_command_dictionary_bits = 12;
        else if (compress_method == LZHUFF6_METHOD_NUM) g_command_dictionary_bits = 14;
        else if (compress_method == LZHUFF7_METHOD_NUM) g_command_dictionary_bits = 15;
    }

    // 圧縮系コマンドの場合のみワイルドカードを展開する
    std::vector<std::string> expanded_file_list;
    bool is_compress_cmd = (cmd_char == 'a' || cmd_char == 'u' || cmd_char == 'm' || cmd_char == 'f' || cmd_char == 'j');
    const bool source_compression = is_compress_cmd && cmd_char != 'j';
    DWORD compression_search_error = ERROR_FILE_NOT_FOUND;
    std::vector<std::pair<std::string, DWORD>> compression_read_failures;
    size_t compression_selected_count = 0;
    std::string glob_base_directory;
    if (cmd_char != 'j' && is_compress_cmd && file_list.size() > 1 && !file_list[1].empty()) {
        const char last = file_list[1].back();
        if (last == '/' || last == '\\' || last == ':') glob_base_directory = file_list[1];
    }

    if (file_list.size() > 0) {
        expanded_file_list.push_back(file_list[0]); // 書庫名は展開しない

        if (cmd_char == 'f') {
            g_compression_inputs_explicit = true;
            const size_t first_pattern = glob_base_directory.empty() ? 1 : 2;
            if (!glob_base_directory.empty()) expanded_file_list.push_back(glob_base_directory);
            const std::vector<std::string> patterns(file_list.begin() + first_pattern, file_list.end());
            const size_t first_input = expanded_file_list.size();
            ExpandFreshenCommandInputs(file_list[0], glob_base_directory, patterns, exclude_patterns,
                expanded_file_list);
            compression_selected_count = expanded_file_list.size() - first_input;
        }
        for (size_t i = 1; cmd_char != 'f' && i < file_list.size(); ++i) {
            std::string path = file_list[i];
            if (source_compression && i == 1 && !glob_base_directory.empty()) {
                expanded_file_list.push_back(path);
                continue;
            }
            if (source_compression) g_compression_inputs_explicit = true;
            if (source_compression && (recursive_mode > 0 || HasWildcard(path) ||
                NormalizeCompressionDots(glob_base_directory + path, false) != glob_base_directory + path)) {
                const bool relative = !path.empty() && path[0] != '/' && path[0] != '\\' &&
                    !(path.size() > 1 && path[1] == ':');
                const std::string prefix = relative ? glob_base_directory : std::string();
                const std::string requested = prefix + path;
                const std::string search_path = NormalizeCompressionDots(requested, true);
                const std::string read_path = NormalizeCompressionDots(requested, false);
                const std::string read_base = NormalizeCompressionDots(prefix, false);
                std::string search_directory, search_pattern, read_directory, read_pattern;
                SplitPath(search_path, search_directory, search_pattern);
                SplitPath(read_path, read_directory, read_pattern);
                std::vector<std::string> matches;
                GlobCompressionPaths(search_directory, search_pattern, matches, recursive_mode);
                if (matches.empty()) compression_search_error = GetLastError();
                for (const auto& found : matches) {
                    const std::string source = read_directory + found.substr(search_directory.size());
                    if (read_path != search_path) {
                        struct stat status{};
                        if (Lha_StatFile(source.c_str(), &status) != 0) {
                            const DWORD failure = GetLastError();
                            if (failure == ERROR_FILE_NOT_FOUND || failure == ERROR_PATH_NOT_FOUND) {
                                wchar_t absolute[FILENAME_LENGTH * 4]{};
                                const DWORD length = GetFullPathNameW(StringToWString(source).c_str(), _countof(absolute), absolute, nullptr);
                                std::string reported = length && length < _countof(absolute) ? WStringToString(absolute) : source;
                                compression_read_failures.emplace_back(std::move(reported), failure);
                                continue;
                            }
                        }
                    }
                    const std::string core_name = source.substr(read_base.size());
                    const std::string header_name = CompressionMemberName(core_name);
                    const std::string stored_name = CompressionMemberName(CompressionStoredSuffix(found, prefix));
                    if (header_name != stored_name)
                        g_forced_header_names.push_back({header_name, StringToWString(stored_name)});
                    expanded_file_list.push_back(core_name);
                    ++compression_selected_count;
                }
            } else if (is_compress_cmd && HasWildcard(path)) {
                std::string dir, pattern;
                SplitPath(path, dir, pattern);
                const bool relative = !path.empty() && path[0] != '/' && path[0] != '\\' &&
                    !(path.size() > 1 && path[1] == ':');
                // 呼び出し元の CWD ではなく、指定された基準ディレクトリ内を検索する。
                // 得られた引数は基準からの相対名に戻し、格納名と既存の CWD 復元順序を保つ。
                const std::string prefix = i > 1 && relative ? glob_base_directory : std::string();
                std::vector<std::string> matches;
                if (recursive_mode >= 1) {
                    GlobRecursive(prefix + dir, pattern, matches);
                } else {
                    GlobSingle(prefix + dir, pattern, matches);
                }
                if (matches.empty()) {
                    expanded_file_list.push_back(path);
                } else {
                    for (const std::string& m : matches) {
                        expanded_file_list.push_back(m.substr(prefix.size()));
                    }
                }
            } else {
                if (source_compression) {
                    // リテラル指定でも検索結果の大小文字を使う。見つからない入力の扱いは変えない。
                    const DWORD previous_error = GetLastError();
                    const bool relative = !path.empty() && path[0] != '/' && path[0] != '\\' &&
                        !(path.size() > 1 && path[1] == ':');
                    const std::string prefix = relative ? glob_base_directory : std::string();
                    std::string directory, pattern;
                    SplitPath(prefix + path, directory, pattern);
                    std::vector<std::string> matches;
                    GlobSingle(directory, pattern, matches);
                    if (matches.size() == 1) path = matches.front().substr(prefix.size());
                    SetLastError(previous_error);
                }
                expanded_file_list.push_back(path);
                if (source_compression) ++compression_selected_count;
            }
        }
    }

    if (source_compression && cmd_char != 'f') {
        const size_t first_input = glob_base_directory.empty() ? 1 : 2;
        g_compression_store_directories = compression_attribute_mode == 2 && recursive_mode == 2;
        ExpandCompressionDirectories(expanded_file_list, first_input, glob_base_directory, recursive_mode,
            g_compression_store_directories, compression_search_error);
        g_compression_inputs_flat = g_compression_inputs_explicit;
        compression_selected_count = expanded_file_list.size() > first_input
            ? expanded_file_list.size() - first_input : 0;
    }

    // 原版の j は Win32 の拡張名前空間を通常の書庫名として解釈しない。ここで止めれば、
    // 新規直接出力を作成してから失敗する経路にも入らない。
    if (cmd_char == 'j' && !expanded_file_list.empty() &&
        UsesExtendedWindowsPathPrefix(expanded_file_list.front())) {
        return FinishCommandFailure(ERROR_NOT_FIND_ARC_FILE, ERROR_FILE_NOT_FOUND, ERROR_INVALID_NAME);
    }

    const CommandArchiveSnapshot command_archive = expanded_file_list.empty()
        ? CommandArchiveSnapshot() : SnapshotCommandArchivePath(expanded_file_list[0], reject_foreign_data);
    if (!command_archive.existed && cmd_char != 'a' && cmd_char != 'u' &&
        cmd_char != 'm' && cmd_char != 'j' &&
        (command_archive.open_error == ERROR_FILE_NOT_FOUND ||
         command_archive.open_error == ERROR_PATH_NOT_FOUND)) {
        return FinishCommandFailure(ERROR_NOT_FIND_ARC_FILE, ERROR_FILE_NOT_FOUND,
                                    command_archive.open_error);
    }

    // UNIXベースのライブラリ向けにパスを正規化する（バックスラッシュをスラッシュに変換）
    // また、引数リスト argv を再構成する
    std::vector<std::string> final_argv_strs;
    final_argv_strs.push_back("lha");
    const char core_cmd_char = (cmd_char == 'f') ? 'u' : cmd_char;
    final_argv_strs.push_back(std::string(1, core_cmd_char));

    if (requested_header_level >= 0) {
        final_argv_strs.push_back("-" + std::to_string(requested_header_level));
    }

    // 除外パターンの追加 (-jx -> -x)
    for (const std::string& pat : exclude_patterns) {
        final_argv_strs.push_back("-x" + pat);
    }
    final_argv_strs.push_back("--");

    // 書庫名とファイルリストの追加
    for (const std::string& f : expanded_file_list) {
        final_argv_strs.push_back(f);
    }

    // UNLHA32.DLL 互換レイヤー: すべてのコマンドに対応するように変更
    // アーカイブ名の後の引数がディレクトリのように見えるかチェックし、
    // 必要に応じて展開先ディレクトリ、または圧縮時の基準ディレクトリとして扱う。その他のコマンドでは引数から除去する。
    char* compress_base_directory = nullptr;
    size_t archive_idx = 3 + exclude_patterns.size() +
                         (requested_header_level >= 0 ? 1U : 0U);
    if (final_argv_strs.size() >= archive_idx + 2) {
        int dest_idx = -1;
        size_t i = archive_idx + 1;
        if (i < final_argv_strs.size()) {
            size_t len = final_argv_strs[i].length();
            if (len > 0U) {
                char last_char = final_argv_strs[i][len - 1];
                if (last_char == '/' || last_char == '\\' || last_char == ':') {
                    dest_idx = (int)i;
                }
            }
        }
        if (dest_idx != -1) {
            if (cmd_char == 'e' || cmd_char == 'x' || cmd_char == 'p' || cmd_char == 't') {
                // 静的にメモリ確保された文字列に複製して LhaCore の extract_directory に設定
                char* dest_dir = _strdup(final_argv_strs[dest_idx].c_str());
                extract_directory = dest_dir;
            } else if (cmd_char == 'a' || cmd_char == 'u' || cmd_char == 'f' || cmd_char == 'm') {
                const std::string base = cmd_char == 'f' ? final_argv_strs[dest_idx]
                    : NormalizeCompressionDots(final_argv_strs[dest_idx], false);
                compress_base_directory = _strdup(base.c_str());
            } else {
                // その他のコマンド（t, l, v など）では、抽出した基準ディレクトリは使用しないので変数には格納せず、単に引数から除去する
            }
            final_argv_strs.erase(final_argv_strs.begin() + dest_idx);
        }
    }

    // 圧縮時の基準ディレクトリ指定がある場合、書庫名を絶対パスに変換する（移動先で作成されるのを防ぐため）
    if (compress_base_directory && final_argv_strs.size() > archive_idx) {
        wchar_t full_path[FILENAME_LENGTH * 4]{};
        const DWORD length = GetFullPathNameW(StringToWString(final_argv_strs[archive_idx]).c_str(),
            static_cast<DWORD>(_countof(full_path)), full_path, nullptr);
        if (length > 0 && length < _countof(full_path)) {
            final_argv_strs[archive_idx] = WStringToString(full_path);
        }
    }

    // パスの区切り文字を正規化
    if (extract_directory) {
        char* p = extract_directory;
        while (*p) {
            if (IsInputLeadByte((BYTE)*p)) {
                if (*(p + 1)) p += 2;
                else p++;
                continue;
            }
            if (*p == '\\') *p = '/';
            p++;
        }
        size_t len = strlen(extract_directory);
        if (len > 0U && extract_directory[len - 1] == '/') {
            extract_directory[len - 1] = '\0';
        }
    }

    for (size_t i = 0; i < final_argv_strs.size(); ++i) {
        for (size_t j = 0; j < final_argv_strs[i].length(); ++j) {
            // SJISのマルチバイト文字に配慮しながらバックスラッシュをスラッシュに変換
            if (IsInputLeadByte((BYTE)final_argv_strs[i][j])) {
                if (j + 1U < final_argv_strs[i].length()) j++;
                continue;
            }
            if (final_argv_strs[i][j] == '\\') {
                final_argv_strs[i][j] = '/';
            }
        }
    }

    // 整形前のログや p の本文を分離し、最終文字列より後の呼び出し元領域を守る。
    const bool rebuilds_text_output = cmd_char == 'l' || cmd_char == 'v' || cmd_char == 't' ||
        cmd_char == 'e' || cmd_char == 'x';
    std::vector<char> command_capture;
    if ((cmd_char == 'p' || rebuilds_text_output) && g_capture_buffer && _dwSize > 0) {
        try {
            command_capture.resize(_dwSize);
        } catch (const std::bad_alloc&) {
            return FinishCommandFailure(ERROR_ENOUGH_MEMORY, ERROR_NOT_ENOUGH_MEMORY, ERROR_NOT_ENOUGH_MEMORY);
        }
        g_capture_buffer = command_capture.data();
        g_capture_buffer_written = 0;
    }

    // argv 配列（Cスタイル）を構築
    std::vector<char*> argv;
    std::vector<char*> original_argv;
    for (const std::string& arg_str : final_argv_strs) {
        char* arg = _strdup(arg_str.c_str());
        argv.push_back(arg);
        original_argv.push_back(arg);
    }
    argv.push_back(NULL);
    int argc = (int)argv.size() - 1;
    char** argv_ptr = argv.data();

    // 圧縮時の基準ディレクトリへ一時的に移動
    wchar_t original_directory[FILENAME_LENGTH * 4]{};
    bool dir_changed = false;
    if (compress_base_directory) {
        const DWORD length = GetCurrentDirectoryW(_countof(original_directory), original_directory);
        if (length > 0 && length < _countof(original_directory)) {
            if (SetCurrentDirectoryW(StringToWString(compress_base_directory).c_str())) {
                dir_changed = true;
            }
        }
    }

    int result = 0;
    const bool foreign_archive = command_archive.foreign_tail;
    g_command_header_validation = cmd_char == 'l' || cmd_char == 'v' || cmd_char == 't' || cmd_char == 'p' ||
        cmd_char == 'e' || cmd_char == 'x';
    g_enum_command = EnumCommandFromCharacter(cmd_char);
    g_enum_invoked_count = 0;
    g_enum_selected_count = 0;
    g_enum_selection_results.clear();
    g_command_events.clear();
    g_command_read_member = CommandEvent{};
    g_command_test_crc_errors.clear();
    g_command_crc_stopped = false;
    g_command_question_state = CommandQuestionState{};
    g_command_crc_failure_path.clear();
    g_command_disk_space_failure_path.clear();
    g_command_extraction_failure = CommandExtractionFailure{};
    g_rewrite_foreign_source_rejected = false;
    g_rewrite_foreign_source_path.clear();
    g_rewrite_join_source_system_error = ERROR_SUCCESS;
    g_command_read_failure = CommandReadFailure::None;
    g_command_header_error = 0;
    g_command_header_warning = 0;
    g_command_header_system_error = ERROR_SUCCESS;
    g_command_progress_cancel_state = -1;
    g_command_compression_copy_progress = false;
    g_command_renamed_destination.clear();
    g_command_renamed_member.clear();
    g_command_renamed_member_w.clear();
    g_command_metadata_path.clear();
    g_lha_exit_jmp_enabled = 1;
#pragma warning(push)
#pragma warning(disable: 4611)
    if (setjmp(g_lha_exit_jmp_buf) == 0) {
        if (foreign_archive) {
            result = ERROR_FILE_STYLE;
        } else if (cmd_char == 's') {
            if (expanded_file_list.empty()) {
                result = RewriteFailure(ERROR_NOT_FILENAME,
                                        L"書庫名が指定されていません。",
                                        ERROR_INVALID_PARAMETER);
            } else {
                const std::wstring archive = StringToWString(expanded_file_list[0]);
                const std::wstring destination = expanded_file_list.size() >= 2
                    ? StringToWString(expanded_file_list[1]) : std::wstring();
                const int sfx_type = sfx_mode == 0 ? SFX_DOS_260S
                    : (sfx_mode >= 3 ? SFX_WIN32_213_3 : SFX_WIN32_300_1);
                result = ExecuteSfxCommandW(archive, destination,
                                            StringToWString(rename_target),
                                            sfx_type, is_y_val);
            }
        } else if (cmd_char == 'j' || cmd_char == 'y' || cmd_char == 'n' || cmd_char == 'c') {
            std::vector<std::string> operands;
            if (archive_idx < final_argv_strs.size()) {
                operands.assign(final_argv_strs.begin() + archive_idx,
                                final_argv_strs.end());
            }
            CommandCommentInput comment;
            if (cmd_char == 'c' && (comment_file.empty() || !ReadCommandComment(comment_file, comment))) {
                result = RewriteFailure(ERROR_FILE_OPEN, L"注釈ファイルを開けません。", GetLastError());
            } else {
                result = ExecuteRewriteCommand(cmd_char, operands, exclude_patterns,
                                               requested_header_level, !is_x_val,
                                               rename_target, reject_foreign_data,
                                               cmd_char == 'c' ? &comment : nullptr);
            }
        } else if (lha_parse_option(argc, argv_ptr) == 0) {
            if (cmd_char == 'a' || cmd_char == 'u' || cmd_char == 'f' || cmd_char == 'm') {
                ReadCommandExistingMembers(final_argv_strs[archive_idx]);
            }
            result = lha_execute();
        } else {
            result = -1; // パースエラー
        }
    } else {
        // longjmp (lha_exit) からの復帰
        result = -g_lha_exit_status;
    }
#pragma warning(pop)
    g_lha_exit_jmp_enabled = 0;
    g_new_compression_file = nullptr;
    g_new_compression_mapped = false;
    g_new_compression_allocation = 0;
    g_compression_write_buffer = CompressionWriteBuffer{};
    if (cmd_char == 'a' || cmd_char == 'u' || cmd_char == 'f' || cmd_char == 'm')
        Lha_PumpCommandMessages();
    g_command_header_validation = false;
    const DWORD command_system_error = GetLastError();
    if (!g_compression_read_failure.first.empty())
        compression_read_failures.push_back(g_compression_read_failure);
    if ((g_enum_command == UNLHA_ADD_COMMAND || g_enum_command == UNLHA_FRESH_COMMAND) &&
        g_enum_members_proc && g_enum_invoked_count > 0 && g_enum_selected_count == 0) {
        result = 0;
        g_last_error.clear();
    }
    g_enum_command = 0;

    // カレントディレクトリを復元
    if (dir_changed) {
        SetCurrentDirectoryW(original_directory);
    }

    // extract_directory 用に複製した領域のクリーンアップ
    if (extract_directory) {
        free(extract_directory);
        extract_directory = nullptr;
    }

    // compress_base_directory 用に複製した領域のクリーンアップ
    if (compress_base_directory) {
        free(compress_base_directory);
        compress_base_directory = nullptr;
    }

    // 元のポインタを使用して安全にargvをクリーンアップする
    for (char* arg : original_argv) {
        if (arg) free(arg);
    }

    bool compatible_output_copied = false;
    const bool command_read_failure =
        (cmd_char == 't' || cmd_char == 'p') &&
        g_command_read_failure != CommandReadFailure::None;
    const bool rewrite_progress_cancelled = result == ERROR_USER_CANCEL &&
        (cmd_char == 'n' || cmd_char == 'y' ||
         (cmd_char == 'j' && g_command_progress_cancel_state >= 0));
    if (g_command_extraction_failure.code) {
        result = g_command_extraction_failure.code;
        g_last_error.clear();
        const std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events) +
            WideStringToMultiByte(CommandExtractionErrorMessage(result) + CommandExtractionFailureLocation() + L" : '" +
                g_command_extraction_failure.path + L"'\r\n", CommandOutputCodePage());
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = g_command_extraction_failure.system_error;
        SetLastError(ERROR_SUCCESS);
    } else if (!g_command_disk_space_failure_path.empty()) {
        result = ERROR_DISK_SPACE;
        g_last_error.clear();
        const std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events) +
            WideStringToMultiByte(CommandDiskSpaceErrorMessage() + L" (on extractsub) : '" +
                g_command_disk_space_failure_path + L"'\r\n", CommandOutputCodePage());
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = ERROR_CANCELLED;
        SetLastError(ERROR_SUCCESS);
    } else if (g_command_question_state.cancelled_location) {
        result = ERROR_USER_CANCEL;
        g_last_error.clear();
        const std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events) +
            WideStringToMultiByte(CommandCancellationMessage() + L" (on " +
                g_command_question_state.cancelled_location + L")\r\n", CommandOutputCodePage());
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = ERROR_CANCELLED;
        SetLastError(ERROR_SUCCESS);
    } else if (rewrite_progress_cancelled) {
        const wchar_t* location = g_command_progress_cancel_state == ARCEXTRACT_OPEN ? L"SetDlgArcName"
            : (g_command_progress_cancel_state == ARCEXTRACT_BEGIN ||
               (cmd_char == 'j' && g_command_progress_cancel_state == 5)) ? L"SetDlgFileName" : L"SetParcent";
        std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events);
        output += "\r\n" + WideStringToMultiByte(std::wstring(L"ユーザーによって中断されました (on ") +
            location + L")\r\n", CommandOutputCodePage());
        g_last_error.clear();
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        if (cmd_char != 'j') g_last_system_error = ERROR_CANCELLED;
        SetLastError(ERROR_SUCCESS);
    } else if (HasExtractCommandCancellation(cmd_char) || HasCompressionCommandCancellation(cmd_char)) {
        result = ERROR_USER_CANCEL;
        g_last_error.clear();
        const std::string output = HasExtractCommandCancellation(cmd_char)
            ? BuildExtractCommandCancellationOutput(cmd_char, command_archive)
            : BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events) + "\r\n" +
                WideStringToMultiByte(CommandCancellationMessage() + L" (on " +
                    CommandCancellationLocation() + L")\r\n", CommandOutputCodePage());
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = ERROR_CANCELLED;
        SetLastError(ERROR_SUCCESS);
    } else if (g_rewrite_foreign_source_rejected) {
        g_last_error.clear();
        CopyCompatibleCommandOutput(switch_warnings + BuildRewriteForeignSourceOutput(
            command_archive, g_command_events, g_rewrite_foreign_source_path), _szOutput, _dwSize);
        compatible_output_copied = true;
        // 原版の診断値を保つが、その値を生む元書庫の消失・一時書庫残存は再現しない。
        g_last_system_error = command_archive.existed ? ERROR_SHARING_VIOLATION : ERROR_FILE_NOT_FOUND;
        SetLastError(ERROR_SUCCESS);
    } else if (foreign_archive) {
        CopyCompatibleCommandOutput(switch_warnings + BuildForeignArchiveCommandOutput(
            cmd_char, command_archive.path, name_output_mode != 0, CommandOutputCodePage()), _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = ForeignArchiveCommandSystemError(cmd_char);
        SetLastError(ERROR_SUCCESS);
    } else if (g_command_crc_stopped) {
        std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events);
        if (cmd_char == 'p') output += "\r\n";
        output += WideStringToMultiByte(CommandCrcErrorMessage() + L" (on extractsub)" +
            (g_command_crc_failure_path.empty() ? std::wstring()
                : L" : '" + g_command_crc_failure_path + L"'") + L"\r\n", CommandOutputCodePage());
        g_last_error.clear();
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        result = ERROR_FILE_CRC;
        g_last_system_error = ERROR_INVALID_DATA;
        SetLastError(ERROR_SUCCESS);
    } else if ((cmd_char == 'e' || cmd_char == 'x') &&
        g_command_read_failure != CommandReadFailure::None) {
        std::string output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events);
        output.resize(output.size() - 2);
        // 本文を読み切れなかった項目には完了イベントがない。実際に準備した展開名を使う。
        if (!g_command_renamed_member_w.empty())
            output += "Melted   " + CommandLeafField(g_command_renamed_member_w, 25) + "  \r\n";
        output += BuildCommandHeaderErrorOutput(
            command_archive.path, ERROR_CANNOT_READ, g_command_read_failure);
        g_last_error.clear();
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        result = ERROR_CANNOT_READ;
        g_last_system_error = ERROR_HANDLE_EOF;
        SetLastError(ERROR_SUCCESS);
    } else if ((cmd_char == 'e' || cmd_char == 'x') && result != ERROR_USER_CANCEL &&
        (result == 0 || g_command_header_error != 0) &&
        (g_command_header_error != 0 || g_command_header_warning != 0)) {
        // 展開済みイベントだけでログを組み立て、終了後の書庫再読み込みを避ける。
        std::string output;
        if (g_command_header_error == ERROR_FILE_STYLE) {
            output = BuildForeignArchiveCommandOutput(
                cmd_char, command_archive.path, false, CommandOutputCodePage());
        } else {
            output = BuildCompatibleActionOutput(cmd_char, command_archive, g_command_events);
            if (g_command_header_error != 0) {
                // 正常終了用の空行を、エラー先頭の空行と重複させない。
                output.resize(output.size() - 2);
                output += BuildCommandHeaderErrorOutput(command_archive.path, g_command_header_error);
            } else {
                output += BuildCommandHeaderWarningOutput(command_archive.path, g_command_header_warning);
            }
        }
        g_last_error.clear();
        CopyCompatibleCommandOutput(switch_warnings + output, _szOutput, _dwSize);
        compatible_output_copied = true;
        if (g_command_header_error != 0) result = g_command_header_error;
        g_last_system_error = g_command_header_system_error;
        SetLastError(ERROR_SUCCESS);
    } else if ((result == 0 || command_read_failure || g_command_header_error != 0) &&
        !expanded_file_list.empty() &&
        (cmd_char == 'l' || cmd_char == 'v' || cmd_char == 't' || cmd_char == 'p')) {
        std::vector<std::string> member_patterns;
        if (final_argv_strs.size() > archive_idx + 1) {
            member_patterns.assign(final_argv_strs.begin() + archive_idx + 1, final_argv_strs.end());
        }
        CommandOutputArchive archive;
        const std::vector<BOOL>* enum_selections = g_enum_invoked_count != 0
            ? &g_enum_selection_results : nullptr;
        if (ReadCommandOutputArchive(expanded_file_list[0], member_patterns,
                                     exclude_patterns, enum_selections, reject_foreign_data,
                                     cmd_char == 't' || cmd_char == 'p', archive)) {
            if (command_read_failure) {
                archive.read_error = ERROR_CANNOT_READ;
                archive.read_warning = 0;
                archive.system_error = ERROR_HANDLE_EOF;
                g_last_error.clear();
            } else {
                if (archive.read_error != 0) g_command_header_error = archive.read_error;
                if (archive.read_warning != 0) g_command_header_warning = archive.read_warning;
            }
            if (archive.read_error == ERROR_FILE_STYLE) {
                CopyCompatibleCommandOutput(switch_warnings + BuildForeignArchiveCommandOutput(
                    cmd_char, archive.path, name_output_mode != 0, CommandOutputCodePage()), _szOutput, _dwSize);
            } else if (cmd_char != 'p') {
                const std::string compatible_output = cmd_char == 't'
                    ? BuildCompatibleTestOutput(archive)
                    : BuildCompatibleListOutput(archive,
                        cmd_char == 'v' || (is_x_specified && is_x_val),
                        name_output_mode != 0);
                const std::string diagnostic = archive.read_error != 0
                    ? BuildCommandHeaderErrorOutput(archive.path, archive.read_error,
                                                    g_command_read_failure)
                    : BuildCommandHeaderWarningOutput(archive.path, archive.read_warning);
                CopyCompatibleCommandOutput(switch_warnings + compatible_output + diagnostic,
                    _szOutput, _dwSize);
            } else if (archive.read_error != 0) {
                // p は読み取り失敗時には本文を上書きせず、処理済みログとエラーを返す。
                const std::string action_output = command_read_failure
                    ? BuildCompatiblePrintReadFailureOutput(command_archive, g_command_events, archive)
                    : BuildCompatibleActionOutput('p', command_archive, g_command_events);
                CopyCompatibleCommandOutput(switch_warnings + action_output + BuildCommandHeaderErrorOutput(
                        archive.path, archive.read_error, g_command_read_failure),
                    _szOutput, _dwSize);
            } else {
                // 原版は処理ログを書いた後、p の最初の NUL までを先頭に上書きする。
                // 終端後のログと出力領域末尾の NUL も保持し、A/W とも同じ順序にする。
                g_print_output_log = switch_warnings + BuildCompatibleActionOutput(
                    'p', command_archive, g_command_events) +
                    BuildCommandHeaderWarningOutput(archive.path, archive.read_warning, true);
                g_print_output_completed = true;
                if (_szOutput && _dwSize > 0) {
                    std::string payload = command_capture.empty() ? std::string()
                        : std::string(command_capture.data(), strnlen(command_capture.data(), _dwSize - 1));
                    // ANSI 版は本文もスレッド ACP の文字列として往復変換する。W 版は外側で変換する。
                    if (!g_unicode_mode.load() && !g_wide_command_input)
                        payload = WideStringToMultiByte(MultiByteStringToWide(payload, CP_THREAD_ACP), CP_THREAD_ACP);
                    CopyCompatibleCommandOutput(g_print_output_log, _szOutput, _dwSize);
                    CopyCompatibleCommandOutput(payload, _szOutput, _dwSize);
                }
            }
            compatible_output_copied = true;
            if (archive.read_error != 0) result = archive.read_error;
            g_last_system_error = archive.read_error == 0 && (cmd_char == 'l' || cmd_char == 'v') && name_output_mode == 0 &&
                !archive.members.empty() && !archive.last_pattern_matched
                    ? ERROR_INVALID_NAME : archive.system_error;
            SetLastError(archive.read_error == 0 && (cmd_char == 'l' || cmd_char == 'v') && name_output_mode == 0
                             ? ERROR_INVALID_WINDOW_HANDLE : ERROR_SUCCESS);
        }
    } else if (result == 0 && !expanded_file_list.empty() &&
               (cmd_char == 'a' || cmd_char == 'u' || cmd_char == 'f' || cmd_char == 'm' ||
                cmd_char == 'd' || cmd_char == 'e' || cmd_char == 'x' || cmd_char == 'c' ||
                cmd_char == 'j' || cmd_char == 'y' || cmd_char == 'n')) {
        std::string compatible_output = BuildCompatibleActionOutput(
            cmd_char, command_archive, g_command_events);
        for (const auto& failure : compression_read_failures) {
            std::string path = failure.first;
            NormalizeAnsiSeparators(path);
            const std::wstring message = CompressionReadErrorCode(failure.second) == ERROR_SHARING
                ? L"ファイルへのアクセスが許可されていません"
                : failure.second == ERROR_PATH_NOT_FOUND && cmd_char != 'f'
                    ? L"指定されたパスが見つかりません" : L"ファイルが見つかりません";
            compatible_output += "\r\n" + WideStringToMultiByte(message, CommandOutputCodePage()) +
                " (on ShareCheck : " + std::to_string(failure.second) + ") : '" + path + "'\r\n";
        }
        if (!g_compression_delete_failure.first.empty()) {
            std::string path = g_compression_delete_failure.first;
            NormalizeAnsiSeparators(path);
            compatible_output += "\r\n" + WideStringToMultiByte(
                L"ファイルを閉じることができませんでした", CommandOutputCodePage()) +
                " (on deletefiles : " + std::to_string(g_compression_delete_failure.second) + ") : '" + path + "'\r\n";
        }
        CopyCompatibleCommandOutput(switch_warnings + compatible_output, _szOutput, _dwSize);
        compatible_output_copied = true;
        g_last_system_error = cmd_char == 'j' && g_rewrite_join_source_system_error != ERROR_SUCCESS
                ? g_rewrite_join_source_system_error
                : g_command_events.empty() &&
                    (command_system_error == ERROR_FILE_NOT_FOUND || command_system_error == ERROR_PATH_NOT_FOUND)
                    ? command_system_error
                    : (cmd_char == 'm' && g_compression_deleted_file ? ERROR_NO_MORE_FILES
                        : source_compression ? g_compression_terminal_error : ERROR_HANDLE_EOF);
        if (source_compression && g_compression_inputs_explicit && compression_selected_count == 0)
            g_last_system_error = command_archive.existed ? ERROR_HANDLE_EOF : compression_search_error;
        if (!compression_read_failures.empty() && !command_archive.existed && g_command_events.empty())
            g_last_system_error = compression_read_failures.back().second;
        if ((cmd_char == 'f' || g_discard_compression_update) && !compression_read_failures.empty()) {
            result = CompressionReadErrorCode(compression_read_failures.back().second);
            g_last_system_error = compression_read_failures.back().second;
        }
        if (!g_compression_delete_failure.first.empty()) {
            result = ERROR_CLOSE_FILE;
            g_last_system_error = g_compression_delete_failure.second;
        }
        SetLastError(ERROR_SUCCESS);
    }

    if (rebuilds_text_output && !compatible_output_copied && !command_capture.empty()) {
        // エラー等で互換ログへ置換しない場合は、従来の書き込み済み範囲だけを戻す。
        const size_t captured = (std::min)(static_cast<size_t>(g_capture_buffer_written), command_capture.size() - 1);
        memcpy(_szOutput, command_capture.data(), captured + 1);
    }
    if (cmd_char == 'p' && !foreign_archive && !compatible_output_copied &&
        g_command_header_error == 0 && !g_print_output_completed && !command_capture.empty()) {
        CopyCompatibleCommandOutput(std::string(command_capture.data()), _szOutput, _dwSize);
    }
    g_running = false;

    if (!g_last_error.empty() && _szOutput && _dwSize > 0) {
        int size_needed = WideCharToMultiByte(CP_ACP, 0, g_last_error.c_str(), -1, NULL, 0, NULL, NULL);
        if (size_needed > 0 && size_needed <= (int)_dwSize) {
            WideCharToMultiByte(CP_ACP, 0, g_last_error.c_str(), -1, _szOutput, size_needed, NULL, NULL);
        } else if (size_needed > (int)_dwSize) {
            std::string tempBuffer(size_needed, 0);
            WideCharToMultiByte(CP_ACP, 0, g_last_error.c_str(), -1, &tempBuffer[0], size_needed, NULL, NULL);
            strncpy(_szOutput, tempBuffer.c_str(), _dwSize - 1);
            _szOutput[_dwSize - 1] = '\0';
        }
    }

    // ログファイルの書き出し
    if (!log_file_path.empty() && _szOutput && _dwSize > 0) {
        FILE* fpLog = fopen(log_file_path.c_str(), "w");
        if (fpLog) {
            fputs(_szOutput, fpLog);
            fclose(fpLog);
        }
    }

    // 実行終了時にキャプチャバッファを解除
    g_capture_buffer = nullptr;
    g_capture_buffer_size = 0;
    g_capture_buffer_written = 0;

    g_last_error_code = g_command_extraction_failure.code ? g_command_extraction_failure.code
        : !g_command_disk_space_failure_path.empty() ? ERROR_DISK_SPACE
        : g_command_question_state.cancelled_location || rewrite_progress_cancelled
        ? ERROR_USER_CANCEL : HasExtractCommandCancellation(cmd_char) || HasCompressionCommandCancellation(cmd_char)
        ? ERROR_USER_CANCEL
        : g_rewrite_foreign_source_rejected || foreign_archive ? ERROR_FILE_STYLE
        : g_command_crc_stopped ? ERROR_FILE_CRC : g_command_header_error != 0
        ? g_command_header_error : g_command_read_failure != CommandReadFailure::None
        ? ERROR_CANNOT_READ : g_command_header_warning != 0
        ? g_command_header_warning : !g_compression_delete_failure.first.empty()
        ? ERROR_CLOSE_FILE : compression_read_failures.empty()
        ? 0 : CompressionReadErrorCode(compression_read_failures.back().second);
    return result;
}

static constexpr int WIDE_COMMAND_NOT_HANDLED = INT_MIN;
static char ParsedWideCommandCharacter(LPCWSTR command_line);
static int ExecuteWideUnicodeCommand(HWND hwnd, LPCWSTR command_line,
                                     LPWSTR output, DWORD output_size);

int WINAPI UnlhaW(HWND _hwnd, LPCWSTR _szCmdLine, LPWSTR _szOutput, DWORD _dwSize) {
    if (IsDllRunning()) return RecordBusyError();
    if (!_szCmdLine) return -1;
    const CommandOutputTerminator<wchar_t> output_terminator{_szOutput, _dwSize};
    if (_szOutput && _dwSize > 0) _szOutput[0] = L'\0';
    
    // 引数ごとにパースして、SJISに変換できない文字が含まれているかチェックする
    const std::vector<std::wstring> arguments = TokenizeCommandLineW(_szCmdLine);
    const WideCommandUtf8InputScope utf8_input_scope;
    if (!arguments.empty()) {
        std::wstring errorFile = L"";
        for (const std::wstring& argument : arguments) {
            bool usedDefault = false;
            WStringToString(argument, &usedDefault);
            if (usedDefault) {
                // コマンド（a, e など）やオプション（-r など）は通常アスキーなので、ここで引っかかるのはファイル名のはず
                errorFile = argument;
                break;
            }
        }
        
        if (!errorFile.empty()) {
            const char command = ParsedWideCommandCharacter(_szCmdLine);
            if (command == 'd' || command == 'j' || command == 'l' || command == 'm' ||
                command == 'n' || command == 'p' || command == 't' || command == 'v' ||
                command == 'y') {
                // W の引数だけを UTF-8 で共通処理へ運ぶ。保存コードページと公開 UnicodeMode は変更しない。
                g_wide_command_utf8_input = true;
            } else {
            const int wide_result = ExecuteWideUnicodeCommand(
                _hwnd, _szCmdLine, _szOutput, _dwSize);
            if (wide_result != WIDE_COMMAND_NOT_HANDLED) {
                return wide_result;
            }
            if (_szOutput && _dwSize > 0) {
                std::wstring errMsg = L"ファイル名にShift_JISに変換できない文字が含まれています: " + errorFile;
                wcsncpy(_szOutput, errMsg.c_str(), _dwSize - 1);
                _szOutput[_dwSize - 1] = L'\0';
            }
            return 87; // ERROR_INVALID_PARAMETER
            }
        }
    }

    std::string szCmdLineA = WStringToString(_szCmdLine);

    g_last_error.clear();

    std::vector<char> ansiOutput;
    DWORD ansiCapacity = 0;
    if (_szOutput && _dwSize > 0) {
        const ULONGLONG requested = static_cast<ULONGLONG>(_dwSize) * 4ULL;
        ansiCapacity = static_cast<DWORD>((std::min)(requested,
                                                     static_cast<ULONGLONG>(MAXDWORD)));
        try {
            ansiOutput.resize(ansiCapacity);
        } catch (const std::bad_alloc&) {
            g_last_error_code = ERROR_ENOUGH_MEMORY;
            g_last_system_error = ERROR_NOT_ENOUGH_MEMORY;
            return ERROR_ENOUGH_MEMORY;
        }
    }

    const bool previous_wide_command = g_wide_command_input;
    g_wide_command_input = true;
    int result = Unlha(_hwnd, szCmdLineA.c_str(),
                       ansiOutput.empty() ? nullptr : ansiOutput.data(), ansiCapacity);
    const UINT output_code_page = CommandOutputCodePage();
    g_wide_command_input = previous_wide_command;

    if (_szOutput && _dwSize > 0) {
        std::wstring wideOutput;
        if (!ansiOutput.empty() && ansiOutput[0] != '\0') {
            // p は公開容量で本文バイト列を制限してから W 文字列へ変換する。
            const std::string output_bytes = g_print_output_completed
                ? std::string(ansiOutput.data(), strnlen(ansiOutput.data(), _dwSize - 1))
                : std::string(ansiOutput.data());
            wideOutput = MultiByteStringToWide(output_bytes,
                g_print_output_completed ? CP_THREAD_ACP : output_code_page);
        } else if (!g_last_error.empty()) {
            wideOutput = g_last_error;
        }
        if (g_print_output_completed && result == 0) {
            const std::wstring log = MultiByteStringToWide(g_print_output_log, output_code_page);
            wcsncpy_s(_szOutput, _dwSize, log.c_str(), _TRUNCATE);
        }
        wcsncpy_s(_szOutput, _dwSize, wideOutput.c_str(), _TRUNCATE);
    }

    return result;
}

#include <new>

static void SetCompatError(int code, DWORD system_error = ERROR_SUCCESS) {
    g_last_error_code = code;
    g_last_system_error = system_error;
}

enum class ArcSearchState { NotStarted, Searching, Finished };

struct ArcSearchPattern {
    std::wstring value;
    bool consumed = false;
};

struct ArcHandleContext {
    union {
        wchar_t wpath[FNAME_MAX32 + 1];
        char apath[(FNAME_MAX32 + 1) * sizeof(wchar_t)];
    } sharedPath;

    std::string filename;
    std::wstring filenameW;
    ULHA_INT64 originalSizeTotal;
    ULHA_INT64 compressedSizeTotal;
    ULHA_INT64 archiveSize;
    ULHA_INT64 readSize;
    std::vector<LzHeader> headers;
    std::vector<ULHA_INT64> readOffsets;
    size_t currentIndex;
    size_t nextIndex = 0;
    ArcSearchState searchState = ArcSearchState::NotStarted;
    std::vector<ArcSearchPattern> searchPatterns;
    bool matchFullPath = false;
    bool recursiveSearch = true;
    UINT archiveCodePage;
    int sfxType;
    FILETIME creationTime;
    FILETIME accessTime;
    FILETIME writeTime;
    int pendingReadError = 0;
    std::unique_ptr<LzHeader> failedReadHeader;

    ArcHandleContext() : originalSizeTotal(0), compressedSizeTotal(0), archiveSize(0), readSize(0), currentIndex(0),
                         archiveCodePage(ConfiguredArchiveCodePage()), sfxType(SFX_NOT) {
        memset(&sharedPath, 0, sizeof(sharedPath));
        memset(&creationTime, 0, sizeof(creationTime));
        memset(&accessTime, 0, sizeof(accessTime));
        memset(&writeTime, 0, sizeof(writeTime));
    }
};

static const LzHeader* CurrentHeader(const ArcHandleContext* ctx) {
    if (!ctx) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return nullptr;
    }
    if (ctx->searchState != ArcSearchState::Searching || ctx->currentIndex == 0 ||
        ctx->currentIndex > ctx->headers.size()) {
        SetCompatError(ERROR_NOT_SEARCH_MODE, ERROR_INVALID_PARAMETER);
        return nullptr;
    }
    return &ctx->headers[ctx->currentIndex - 1];
}

class ArcHandleLock {
    HGLOBAL m_hMem;
    ArcHandleContext* m_ctx;

public:
    ArcHandleLock(HARC harc) : m_hMem((HGLOBAL)harc), m_ctx(NULL) {
        if (m_hMem) {
            UINT flags = GlobalFlags(m_hMem);
            if (flags != GMEM_INVALID_HANDLE) {
                m_ctx = (ArcHandleContext*)GlobalLock(m_hMem);
            }
        }
    }

    ~ArcHandleLock() {
        if (m_ctx && m_hMem) {
            GlobalUnlock(m_hMem);
        }
    }

    bool IsValid() const {
        return m_ctx != NULL;
    }

    ArcHandleContext* GetContext() const {
        return m_ctx;
    }

    ArcHandleContext* operator->() const {
        return m_ctx;
    }
};

static bool WidePathIsSfx(const wchar_t* path, FILE* file) {
    std::wstring value = path ? path : L"";
    std::transform(value.begin(), value.end(), value.begin(), towlower);
    const bool extension_match =
        (value.size() >= 4 &&
         (value.compare(value.size() - 4, 4, L".com") == 0 ||
          value.compare(value.size() - 4, 4, L".exe") == 0)) ||
        (value.size() >= 2 && value.compare(value.size() - 2, 2, L".x") == 0);
    if (extension_match) return true;
    if (!file) return false;
    const off_t position = ftello(file);
    if (fseeko(file, 0, SEEK_SET) != 0) return false;
    const int first = fgetc(file);
    const int second = fgetc(file);
    fseeko(file, position >= 0 ? position : 0, SEEK_SET);
    return first == 'M' && second == 'Z';
}

static HARC OpenArchiveStream(FILE* file, const std::string& filename,
                              const std::wstring& filename_w, const bool wide_path,
                              const int sfx_type,
                              const WIN32_FILE_ATTRIBUTE_DATA* attributes, const DWORD mode) {
    if (!file) {
        SetCompatError(ERROR_FILE_OPEN, GetLastError());
        return nullptr;
    }
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(ArcHandleContext));
    if (!memory) {
        fclose(file);
        g_archive_session_active = FALSE;
        SetCompatError(ERROR_MORE_HEAP_MEMORY, ERROR_NOT_ENOUGH_MEMORY);
        return nullptr;
    }
    void* raw = GlobalLock(memory);
    if (!raw) {
        GlobalFree(memory);
        fclose(file);
        g_archive_session_active = FALSE;
        SetCompatError(ERROR_MORE_HEAP_MEMORY, ERROR_NOT_ENOUGH_MEMORY);
        return nullptr;
    }

    ArcHandleContext* context = ::new (raw) ArcHandleContext();
    context->filename = filename;
    context->filenameW = filename_w;
    context->sfxType = sfx_type;
    const DWORD search_mode = GetConfiguredArchiveSearchMode(mode);
    context->matchFullPath = (search_mode & M_CHECK_ALL_PATH) != 0 && (search_mode & M_CHECK_FILENAME_ONLY) == 0;
    context->recursiveSearch = (search_mode & M_CHECK_ALL_PATH) == 0;
    if (wide_path) {
        wcsncpy(context->sharedPath.wpath, filename_w.c_str(), FNAME_MAX32);
        context->sharedPath.wpath[FNAME_MAX32] = L'\0';
    } else {
        strncpy(context->sharedPath.apath, filename.c_str(), FNAME_MAX32);
        context->sharedPath.apath[FNAME_MAX32] = '\0';
    }

    _fseeki64(file, 0, SEEK_END);
    context->archiveSize = _ftelli64(file);
    _fseeki64(file, 0, SEEK_SET);
    if (attributes) {
        context->creationTime = attributes->ftCreationTime;
        context->accessTime = attributes->ftLastAccessTime;
        context->writeTime = attributes->ftLastWriteTime;
    }
    if (context->sfxType != SFX_NOT && seek_lha_header(file) != 0) {
        context->~ArcHandleContext();
        GlobalUnlock(memory);
        GlobalFree(memory);
        fclose(file);
        SetCompatError(ERROR_FILE_STYLE, ERROR_HANDLE_EOF);
        return nullptr;
    }

    LzHeader header{};
    while (true) {
        const __int64 header_start = _ftelli64(file);
        if (!get_header(file, &header)) break;
        if (header.header_level >= 2 &&
            !ValidateRawHeaderCrc(file, header_start, _ftelli64(file), header.header_level)) {
            if (context->headers.empty()) {
                // 初期探索だけは不良ヘッダーを越えて次の有効項目を探す。
                if (!FindValidArchiveHeader(file, header_start + 1, context->archiveSize,
                                            context->archiveSize, header)) break;
            } else {
                // Open は先頭項目で成功し、途中の CRC 不良は検索が到達した時点で返す。
                context->pendingReadError = ERROR_HEADER_CRC;
                context->failedReadHeader = std::make_unique<LzHeader>(header);
                break;
            }
        }
        context->headers.push_back(header);
        _fseeki64(file, header.packed_size, SEEK_CUR);
        context->readOffsets.push_back(_ftelli64(file));
    }
    DWORD open_system_error = ERROR_SUCCESS;
    const bool foreign_tail = !context->headers.empty() &&
        HasForeignArchiveTail(file, context->archiveSize, open_system_error);
    fclose(file);
    if (context->headers.empty() || foreign_tail) {
        context->~ArcHandleContext();
        GlobalUnlock(memory);
        GlobalFree(memory);
        SetCompatError(ERROR_FILE_STYLE, foreign_tail ? open_system_error : ERROR_HANDLE_EOF);
        return nullptr;
    }
    // 原版の共通ヘッダー領域は、OpenArchive の直後には先頭項目を保持する。
    g_last_packed_size = static_cast<DWORD>(context->headers.front().packed_size);
    Lha_RecordEnumHeader(&context->headers.front());
    GlobalUnlock(memory);
    SetCompatError(0, open_system_error);
    return reinterpret_cast<HARC>(memory);
}

// ハンドルベース API
HARC WINAPI UnlhaOpenArchive(HWND owner, LPCSTR _szFileName, DWORD mode) {
    if (IsDllRunning()) { RecordBusyError(); return nullptr; }
    return UnlhaOpenArchiveW(owner, _szFileName ? StringToWString(_szFileName).c_str() : nullptr, mode);
}

extern "C++" {
static std::wstring PrepareOpenArchivePath(const wchar_t* input) {
    // 3.00.0.5 は先頭・末尾の引用符を各 1 個だけ除き、入力表記は正規化しない。
    if (*input == L'"') ++input;
    std::wstring path(input, wcsnlen(input, FNAME_MAX32));
    if (!path.empty() && path.back() == L'"') path.pop_back();
    const size_t root_index = path.size() >= 2 && path[1] == L':' ? 2U : 0U;
    const wchar_t root_character = root_index < path.size() ? path[root_index] : L'\0';
    if (root_character != L'\\' && root_character != L'/') {
        wchar_t directory[FNAME_MAX32 + 1]{};
        const DWORD length = GetCurrentDirectoryW(_countof(directory), directory);
        if (length > 0 && length < _countof(directory)) {
            std::wstring base(directory);
            if (base.back() != L'\\') base.push_back(L'\\');
            path.insert(0, base);
        }
    }
    if (path.size() > FNAME_MAX32) path.resize(FNAME_MAX32);
    return path;
}
}

HARC WINAPI UnlhaOpenArchiveW(HWND, LPCWSTR _szFileName, DWORD mode) {
    if (IsDllRunning()) { RecordBusyError(); return nullptr; }
    const ScopedThreadPriority thread_priority;
    if (!_szFileName) {
        // 原版の未初期化 HARC は返さず、観測できるエラー状態だけを再現する。
        SetCompatError(0, ERROR_INVALID_VALUE);
        return nullptr;
    }
    g_archive_session_active = TRUE;
    const std::wstring filename = PrepareOpenArchivePath(_szFileName);
    FILE* file = nullptr;
    if (_wfopen_s(&file, filename.c_str(), L"rb") != 0 || !file) {
        SetCompatError(ERROR_FILE_OPEN, GetLastError());
        return nullptr;
    }
    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    const bool has_attributes =
        GetFileAttributesExW(filename.c_str(), GetFileExInfoStandard, &attributes) != FALSE;
    const int sfx_type = DetectSfxType(file, WidePathIsSfx(filename.c_str(), file));
    return OpenArchiveStream(file, WStringToString(filename), filename, true,
                             sfx_type,
                             has_attributes ? &attributes : nullptr, mode);
}


int WINAPI UnlhaCloseArchive(HARC _harc) { 
    if (!_harc) {
        g_last_system_error = ERROR_INVALID_PARAMETER;
        return ERROR_HARC_ISNOT_OPENED;
    }
    HGLOBAL hMem = (HGLOBAL)_harc;
    UINT flags = GlobalFlags(hMem);
    if (flags == GMEM_INVALID_HANDLE) {
        g_last_system_error = ERROR_INVALID_PARAMETER;
        return ERROR_HARC_ISNOT_OPENED;
    }

    const ScopedThreadPriority thread_priority;
    ArcHandleContext* ctx = (ArcHandleContext*)GlobalLock(hMem);
    if (ctx) {
        ctx->~ArcHandleContext();
        GlobalUnlock(hMem);
        g_archive_session_active = FALSE;
    }
    GlobalFree(hMem);
    SetCompatError(0);
    return 0; 
}
static UINT HeaderOsType(const LzHeader& header) {
    switch (header.extend_type) {
    case EXTEND_MSDOS: return 0;
    case EXTEND_UNIX: return 2;
    case EXTEND_MACOS: return 4;
    case EXTEND_OS2: return 5;
    case EXTEND_OS9: return 11;
    case EXTEND_OS68K: return 12;
    case EXTEND_OS386: return 13;
    case EXTEND_HUMAN: return 14;
    case EXTEND_CPM: return 15;
    case EXTEND_FLEX: return 16;
    case EXTEND_RUNSER: return 17;
    case 'W': return 18;
    case 'w': return 19;
    default: return 10;
    }
}

static std::string HeaderAttributeText(const LzHeader& header) {
    return DosAttributeText(HeaderAttributes(header));
}

static void MapHeaderToInfo(const LzHeader& hdr, const UINT code_page, INDIVIDUALINFO* _lpSearch) {
    if (!_lpSearch) return;
    memset(_lpSearch, 0, sizeof(INDIVIDUALINFO));
    _lpSearch->dwOriginalSize = (DWORD)hdr.original_size;
    _lpSearch->dwCompressedSize = (DWORD)hdr.packed_size;
    _lpSearch->dwCRC = hdr.crc;
    _lpSearch->uOSType = HeaderOsType(hdr);
    if (hdr.original_size > 0) {
        _lpSearch->wRatio = (WORD)((hdr.packed_size * 1000) / hdr.original_size);
    }
    
    const std::string name = HeaderNameToString(hdr, code_page);
    strncpy_s(_lpSearch->szFileName, sizeof(_lpSearch->szFileName), name.c_str(), _TRUNCATE);
    const std::string attribute = HeaderAttributeText(hdr);
    strncpy_s(_lpSearch->szAttribute, sizeof(_lpSearch->szAttribute), attribute.c_str(), _TRUNCATE);
    strncpy_s(_lpSearch->szMode, sizeof(_lpSearch->szMode), hdr.method, _TRUNCATE);
    
    UnixTimeToDosTime(hdr.unix_last_modified_stamp, _lpSearch->wDate, _lpSearch->wTime);
}

static void MapHeaderToInfoW(const LzHeader& hdr, const UINT code_page, INDIVIDUALINFOW* _lpSearch) {
    if (!_lpSearch) return;
    memset(_lpSearch, 0, sizeof(INDIVIDUALINFOW));
    _lpSearch->dwOriginalSize = (DWORD)hdr.original_size;
    _lpSearch->dwCompressedSize = (DWORD)hdr.packed_size;
    _lpSearch->dwCRC = hdr.crc;
    _lpSearch->uOSType = HeaderOsType(hdr);
    if (hdr.original_size > 0) {
        _lpSearch->wRatio = (WORD)((hdr.packed_size * 1000) / hdr.original_size);
    }
    
    // 書庫内の既定 CP932 名を UTF-16 へ変換
    std::wstring wname = HeaderNameToWString(hdr, code_page);
    wcsncpy(_lpSearch->szFileName, wname.c_str(), sizeof(_lpSearch->szFileName) / sizeof(wchar_t) - 1);
    const std::wstring attribute = StringToWString(HeaderAttributeText(hdr));
    wcsncpy_s(_lpSearch->szAttribute, _countof(_lpSearch->szAttribute), attribute.c_str(), _TRUNCATE);
    std::wstring method = StringToWString(hdr.method);
    wcsncpy_s(_lpSearch->szMode, _countof(_lpSearch->szMode), method.c_str(), _TRUNCATE);
    
    UnixTimeToDosTime(hdr.unix_last_modified_stamp, _lpSearch->wDate, _lpSearch->wTime);
}


static void SetArchiveSearchPattern(ArcHandleContext* ctx, const std::wstring& pattern) {
    auto patterns = TokenizeCommandLineW(pattern);
    // 引数なしは全件だが、引用符だけの空引数は一致する名前がない検索になる。
    if (patterns.empty() && pattern.find_first_not_of(L" \t\r\n") == std::wstring::npos)
        patterns.push_back(L"*");
    for (std::wstring& value : patterns) {
        std::replace(value.begin(), value.end(), L'\\', L'/');
        ctx->searchPatterns.push_back({std::move(value), false});
    }
}

static bool HeaderSearchTimeOutOfRange(const LzHeader& header) {
    // 列挙時の 32 ビット time_t と DOS 日時の警告だけを再現し、元の FILETIME は保つ。
    constexpr uint64_t epoch = 116444736000000000ULL;
    for (const MemberTimeKind kind : {MemberTimeKind::Create, MemberTimeKind::Access, MemberTimeKind::Write}) {
        const FILETIME value = HeaderTimeToFileTime(header, kind);
        const uint64_t ticks = (static_cast<uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime;
        if (ticks < epoch || (ticks - epoch) / 10000000ULL > 0x7fffffffULL) return true;
    }
    const FILETIME write_time = HeaderTimeToFileTime(header, MemberTimeKind::Write);
    FILETIME local_time{};
    SYSTEMTIME calendar{};
    return !FileTimeToLocalFileTime(&write_time, &local_time) ||
        !FileTimeToSystemTime(&local_time, &calendar) || calendar.wYear < 1980 || calendar.wYear > 2107;
}

static int AdvanceArchiveSearch(ArcHandleContext* ctx, const bool first) {
    SetCompatError(0);
    if (!first && ctx->searchState != ArcSearchState::Searching) return ERROR_NOT_SEARCH_MODE;
    ctx->searchState = ArcSearchState::Searching;
    // FindFirst の再呼び出しも現在位置から続け、走査位置と直前の一致項目を分けて保持する。
    while (ctx->nextIndex < ctx->headers.size()) {
        const size_t index = ctx->nextIndex++;
        g_last_packed_size = static_cast<DWORD>(ctx->headers[index].packed_size);
        Lha_RecordEnumHeader(&ctx->headers[index]);
        ctx->readSize = ctx->readOffsets[index];
        const std::wstring name = HeaderNameToWString(ctx->headers[index], ctx->archiveCodePage);
        const bool matched = std::any_of(ctx->searchPatterns.begin(), ctx->searchPatterns.end(),
            [&](ArcSearchPattern& pattern) {
                if (pattern.consumed || !ArchivePatternMatches(pattern.value, name,
                        ctx->matchFullPath, ctx->recursiveSearch)) return false;
                // パスを含む完全一致条件は一度だけ使う。パスなし・ワイルドカードは継続する。
                pattern.consumed = pattern.value.find_first_of(L"*?") == std::wstring::npos &&
                    (ctx->matchFullPath || pattern.value.find_first_of(L"/\\:") != std::wstring::npos);
                return true;
            });
        if (matched) {
            ctx->currentIndex = index + 1;
            ctx->originalSizeTotal += ctx->headers[index].original_size;
            ctx->compressedSizeTotal += ctx->headers[index].packed_size;
            if (HeaderSearchTimeOutOfRange(ctx->headers[index])) SetCompatError(ERROR_TIME_STAMP_RANGE);
            return 0;
        }
    }
    if (ctx->pendingReadError != 0) {
        const int error = ctx->pendingReadError;
        if (error == ERROR_HEADER_CRC && ctx->failedReadHeader) {
            // 現在メンバー・累計・列挙情報は保持し、解析済みの進捗数値だけ更新する。
            const LzHeader& failed = *ctx->failedReadHeader;
            Lha_RecordProgressHeaderError(&failed, HeaderOsType(failed));
        } else if (error == ERROR_SET_POINT) {
            // 再検索の読み取り準備は CRC・OS を消去するが、直前の圧縮残量は保持する。
            Lha_RecordProgressHeaderEnd();
        }
        ctx->pendingReadError = ERROR_SET_POINT;
        SetCompatError(error);
        return error;
    }
    Lha_RecordProgressHeaderEnd();
    ctx->searchState = ArcSearchState::Finished;
    g_last_packed_size = 0;
    SetCompatError(0, ERROR_HANDLE_EOF);
    return -1;
}

static void CopyArchiveSearchResult(const ArcHandleContext* ctx, INDIVIDUALINFOA* info) {
    if (!info) return;
    if (ctx->currentIndex) MapHeaderToInfo(ctx->headers[ctx->currentIndex - 1], ctx->archiveCodePage, info);
    else memset(info, 0, sizeof(*info)); // 原版の未初期化メタデータは返さない。
}

static void CopyArchiveSearchResultW(const ArcHandleContext* ctx, INDIVIDUALINFOW* info) {
    if (!info) return;
    if (ctx->currentIndex) MapHeaderToInfoW(ctx->headers[ctx->currentIndex - 1], ctx->archiveCodePage, info);
    else memset(info, 0, sizeof(*info));
}

int WINAPI UnlhaFindFirst(HARC archive, LPCSTR pattern, INDIVIDUALINFO* info) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) return ERROR_HARC_ISNOT_OPENED;
    const ScopedThreadPriority thread_priority;
    SetArchiveSearchPattern(lock.GetContext(), pattern ? StringToWString(pattern) : L"");
    const int result = AdvanceArchiveSearch(lock.GetContext(), true);
    if (result == 0 || result == -1) CopyArchiveSearchResult(lock.GetContext(), info);
    return result;
}

int WINAPI UnlhaFindFirstW(HARC archive, LPCWSTR pattern, INDIVIDUALINFOW* info) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) return ERROR_HARC_ISNOT_OPENED;
    const ScopedThreadPriority thread_priority;
    SetArchiveSearchPattern(lock.GetContext(), pattern ? pattern : L"");
    const int result = AdvanceArchiveSearch(lock.GetContext(), true);
    if (result == 0 || result == -1) CopyArchiveSearchResultW(lock.GetContext(), info);
    return result;
}

int WINAPI UnlhaFindNext(HARC archive, INDIVIDUALINFO* info) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) return ERROR_HARC_ISNOT_OPENED;
    const ScopedThreadPriority thread_priority;
    const int result = AdvanceArchiveSearch(lock.GetContext(), false);
    if (result == 0 || result == -1) CopyArchiveSearchResult(lock.GetContext(), info);
    return result;
}

int WINAPI UnlhaFindNextW(HARC archive, INDIVIDUALINFOW* info) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) return ERROR_HARC_ISNOT_OPENED;
    const ScopedThreadPriority thread_priority;
    const int result = AdvanceArchiveSearch(lock.GetContext(), false);
    if (result == 0 || result == -1) CopyArchiveSearchResultW(lock.GetContext(), info);
    return result;
}

struct GetterConversionError {
    DWORD error = 0;
    // GlobalUnlock が Win32 エラーを消すため、ロック解放後に変換失敗を復元する。
    ~GetterConversionError() { if (error != 0) SetLastError(error); }
};

static int ValidateStringGetter(const ArcHandleLock& lock, const bool member) {
    if (!lock.IsValid()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_PARAMETER);
        return ERROR_HARC_ISNOT_OPENED;
    }
    if (member && !CurrentHeader(lock.GetContext())) return g_last_error_code;
    SetCompatError(0);
    return 0;
}

static int CopyGetterNameA(const std::wstring& name, LPSTR buffer, const int size,
                           GetterConversionError& conversion_error) {
    if (!buffer) return 0;
    // サイズ 0 で原版が行うバッファ直前への書き込みは再現しない。
    if (size == 0) { SetCompatError(0, ERROR_INVALID_PARAMETER); return 0; }
    if (size < 0 || IsBadWritePtr(buffer, static_cast<UINT_PTR>(size))) return ERROR_INVALID_VALUE;
    const UINT code_page = ActiveCodePage();
    const bool unicode_page = code_page == CP_UTF8 || code_page == CP_UTF7;
    const char default_character = '_';
    const int converted = WideCharToMultiByte(code_page, unicode_page ? 0 : WC_NO_BEST_FIT_CHARS,
        name.c_str(), -1, buffer, size,
        unicode_page ? nullptr : &default_character, nullptr);
    if (converted == 0) {
        conversion_error.error = GetLastError();
        SetCompatError(0, conversion_error.error);
    }
    buffer[size - 1] = '\0';
    return 0;
}

static int CopyGetterNameW(const std::wstring& name, LPWSTR buffer, const int size) {
    if (!buffer) return 0;
    if (size == 0) { SetCompatError(0, ERROR_INVALID_PARAMETER); return 0; }
    if (size < 0 || IsBadWritePtr(buffer, static_cast<UINT_PTR>(size) * sizeof(wchar_t)))
        return ERROR_INVALID_VALUE;
    lstrcpynW(buffer, name.c_str(), size);
    return 0;
}

int WINAPI UnlhaGetArcFileName(HARC archive, LPSTR buffer, int size) {
    GetterConversionError conversion_error;
    ArcHandleLock lock(archive);
    const int validation = ValidateStringGetter(lock, false);
    if (validation != 0) return validation;
    return CopyGetterNameA(lock->filenameW, buffer, size, conversion_error);
}

int WINAPI UnlhaGetArcFileNameW(HARC archive, LPWSTR buffer, int size) {
    ArcHandleLock lock(archive);
    const int validation = ValidateStringGetter(lock, false);
    if (validation != 0) return validation;
    return CopyGetterNameW(lock->filenameW, buffer, size);
}

DWORD WINAPI UnlhaGetArcFileSize(HARC _harc) { 
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    return (DWORD)lock->archiveSize;
}

BOOL WINAPI UnlhaGetArcFileSizeEx(HARC _harc, ULHA_INT64* _pllSize) { 
    if (!_pllSize) return FALSE;
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return FALSE;
    }
    *_pllSize = lock->archiveSize;
    return TRUE;
}

DWORD WINAPI UnlhaGetArcOriginalSize(HARC _harc) { 
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    if (lock->searchState == ArcSearchState::NotStarted) {
        SetCompatError(ERROR_NOT_SEARCH_MODE, ERROR_INVALID_PARAMETER);
        return MAXDWORD;
    }
    SetCompatError(0);
    return (DWORD)lock->originalSizeTotal;
}

BOOL WINAPI UnlhaGetArcOriginalSizeEx(HARC _harc, ULHA_INT64* _pllSize) { 
    if (!_pllSize) return FALSE;
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return FALSE;
    }
    *_pllSize = lock->originalSizeTotal;
    SetCompatError(0);
    return TRUE;
}

DWORD WINAPI UnlhaGetArcCompressedSize(HARC _harc) { 
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    if (lock->searchState == ArcSearchState::NotStarted) {
        SetCompatError(ERROR_NOT_SEARCH_MODE, ERROR_INVALID_PARAMETER);
        return MAXDWORD;
    }
    SetCompatError(0);
    return (DWORD)lock->compressedSizeTotal;
}

BOOL WINAPI UnlhaGetArcCompressedSizeEx(HARC _harc, ULHA_INT64* _pllSize) { 
    if (!_pllSize) return FALSE;
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return FALSE;
    }
    *_pllSize = lock->compressedSizeTotal;
    SetCompatError(0);
    return TRUE;
}

static void SetOwnerCompatError(const int code, const DWORD system_error) {
    g_last_error_code = code;
    g_last_system_error = system_error;
}

static void ClearOwnerRegistration() {
    g_hwndOwner = NULL;
    g_progressWindow = NULL;
    g_lpArcProc = NULL;
    g_bEnableTotalProgress = FALSE;
    g_owner_struct_size = 0;
    g_owner_progress_layout = OwnerProgressLayout::None;
}

static BOOL SetOwnerRegistration(const HWND hwnd, const LPARCHIVERPROC callback,
                                 const OwnerProgressLayout layout, const DWORD struct_size,
                                 const BOOL total_progress) {
    if (g_running) {
        SetOwnerCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY);
        return FALSE;
    }
    if (!hwnd && !callback) {
        SetOwnerCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    if (g_owner_progress_layout != OwnerProgressLayout::None && g_hwndOwner != hwnd) {
        SetOwnerCompatError(ERROR_INVALID_VALUE, ERROR_ALREADY_EXISTS);
        return FALSE;
    }
    g_hwndOwner = hwnd;
    g_progressWindow = hwnd;
    g_lpArcProc = reinterpret_cast<LHA_ARCHIVERPROC>(callback);
    g_bEnableTotalProgress = total_progress;
    g_owner_struct_size = struct_size;
    g_owner_progress_layout = layout;
    SetOwnerCompatError(0, ERROR_SUCCESS);
    return TRUE;
}

static BOOL KillOwnerRegistration(const HWND hwnd) {
    if (IsDllRunning()) {
        // 解除は登録と異なり、OpenArchive の保持状態も拒否する。原版のエラー値は 0 のまま。
        SetOwnerCompatError(0, ERROR_SUCCESS);
        return FALSE;
    }
    if (hwnd && g_owner_progress_layout != OwnerProgressLayout::None && g_hwndOwner != hwnd) {
        SetOwnerCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_WINDOW_HANDLE);
        return FALSE;
    }
    ClearOwnerRegistration();
    SetOwnerCompatError(0, ERROR_SUCCESS);
    return TRUE;
}

BOOL WINAPI UnlhaSetOwnerWindow(HWND hwnd) {
    return SetOwnerRegistration(hwnd, nullptr, OwnerProgressLayout::BasicA,
                                sizeof(EXTRACTINGINFOA), FALSE);
}

BOOL WINAPI UnlhaSetOwnerWindowA(HWND hwnd) {
    return SetOwnerRegistration(hwnd, nullptr, OwnerProgressLayout::BasicA,
                                sizeof(EXTRACTINGINFOA), FALSE);
}

BOOL WINAPI UnlhaSetOwnerWindowW(HWND hwnd) {
    return SetOwnerRegistration(hwnd, nullptr, OwnerProgressLayout::BasicW,
                                sizeof(EXTRACTINGINFOW), FALSE);
}

BOOL WINAPI UnlhaClearOwnerWindow() { return KillOwnerRegistration(nullptr); }

BOOL WINAPI UnlhaSetOwnerWindowEx(HWND hwnd, LPARCHIVERPROC callback) {
    return SetOwnerRegistration(hwnd, callback, OwnerProgressLayout::ExA,
                                sizeof(EXTRACTINGINFOEXA), FALSE);
}

BOOL WINAPI UnlhaSetOwnerWindowExA(HWND hwnd, LPARCHIVERPROC callback) {
    return SetOwnerRegistration(hwnd, callback, OwnerProgressLayout::ExA,
                                sizeof(EXTRACTINGINFOEXA), FALSE);
}

BOOL WINAPI UnlhaSetOwnerWindowExW(HWND hwnd, LPARCHIVERPROC callback) {
    return SetOwnerRegistration(hwnd, callback, OwnerProgressLayout::ExW,
                                sizeof(EXTRACTINGINFOEXW), FALSE);
}

BOOL WINAPI UnlhaKillOwnerWindowEx(HWND hwnd) { return KillOwnerRegistration(hwnd); }

BOOL WINAPI UnlhaSetOwnerWindowExTotal(HWND _hwnd, LPARCHIVERPROC _lpArcProcArg, BOOL _bEnableTotalProgressArg) {
    return SetOwnerRegistration(_hwnd, _lpArcProcArg, OwnerProgressLayout::Ex64W,
                                sizeof(EXTRACTINGINFOEX64W), _bEnableTotalProgressArg);
}

// Windows環境において、ディレクトリやファイルのタイムスタンプを設定するヘルパー関数
// (Cコードから呼び出すためのCリンケージ)
int win32_set_file_time(const char* name, time_t t, const LzHeader* header) {
    ULARGE_INTEGER ull;
    ull.QuadPart = ((ULONGLONG)t * 10000000ULL) + 116444736000000000ULL;
    
    FILETIME ft;
    ft.dwLowDateTime = ull.LowPart;
    ft.dwHighDateTime = ull.HighPart;

    // ディレクトリやファイルを開く (FILE_FLAG_BACKUP_SEMANTICS が必要)
    HANDLE hFile = Lha_OpenMetadataFile(name, GENERIC_WRITE);
    if (hFile == INVALID_HANDLE_VALUE) {
        return 0; // 失敗
    }

    // 展開時は time_t を経由せず、元の FILETIME の精度と未記録値の規則を保つ。
    const FILETIME create_time = header ? HeaderExtractionTime(*header, MemberTimeKind::Create) : ft;
    const FILETIME access_time = header ? HeaderExtractionTime(*header, MemberTimeKind::Access) : ft;
    const FILETIME write_time = header ? HeaderExtractionTime(*header, MemberTimeKind::Write) : ft;
    BOOL result = SetFileTime(hFile, header ? &create_time : nullptr, &access_time, &write_time);
    CloseHandle(hFile);
    // 展開本体がファイルを閉じ、メタデータ復元へ到達したものだけに適用する。
    if ((g_enum_command == UNLHA_EXTRACT_COMMAND) && g_command_metadata_path == name) {
        const BOOL changed = UsesUnicodeFilePath(name)
            ? SetFileAttributesW(FilePathToWide(name).c_str(), g_command_metadata_attributes)
            : SetFileAttributesA(name, g_command_metadata_attributes);
        if (!changed) result = FALSE;
        g_command_metadata_path.clear();
    }
    return result ? 1 : 0;
}

int WINAPI UnlhaGetFileNameA(HARC _harc, LPSTR _lpBuffer, const int _nSize) {
    GetterConversionError conversion_error;
    ArcHandleLock lock(_harc);
    const int validation = ValidateStringGetter(lock, true);
    if (validation != 0) return validation;
    ArcHandleContext* ctx = lock.GetContext();
    const LzHeader& hdr = ctx->headers[ctx->currentIndex - 1];
    return CopyGetterNameA(HeaderNameToWString(hdr, ctx->archiveCodePage), _lpBuffer, _nSize, conversion_error);
}

int WINAPI UnlhaGetFileNameW(HARC _harc, LPWSTR _lpBuffer, const int _nSize) {
    ArcHandleLock lock(_harc);
    const int validation = ValidateStringGetter(lock, true);
    if (validation != 0) return validation;
    ArcHandleContext* ctx = lock.GetContext();
    const LzHeader& hdr = ctx->headers[ctx->currentIndex - 1];
    return CopyGetterNameW(HeaderNameToWString(hdr, ctx->archiveCodePage), _lpBuffer, _nSize);
}

DWORD WINAPI UnlhaGetOriginalSize(HARC _harc) {
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    ArcHandleContext* ctx = lock.GetContext();
    if (!CurrentHeader(ctx)) return MAXDWORD;
    SetCompatError(0);
    return (DWORD)ctx->headers[ctx->currentIndex - 1].original_size;
}

BOOL WINAPI UnlhaGetOriginalSizeEx(HARC _harc, ULHA_INT64 *_lpllSize) {
    if (!_lpllSize) {
        g_last_error_code = -1;
        return FALSE;
    }
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return FALSE;
    }
    ArcHandleContext* ctx = lock.GetContext();
    if (!CurrentHeader(ctx)) return FALSE;
    *_lpllSize = ctx->headers[ctx->currentIndex - 1].original_size;
    SetCompatError(0);
    return TRUE;
}

WORD WINAPI UnlhaGetDate(HARC _harc) {
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    ArcHandleContext* ctx = lock.GetContext();
    if (!CurrentHeader(ctx)) return 0xffff;
    const LzHeader& hdr = ctx->headers[ctx->currentIndex - 1];
    WORD wDate = 0;
    WORD wTime = 0;
    UnixTimeToDosTime(hdr.unix_last_modified_stamp, wDate, wTime);
    SetCompatError(0);
    return wDate;
}

WORD WINAPI UnlhaGetTime(HARC _harc) {
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    ArcHandleContext* ctx = lock.GetContext();
    if (!CurrentHeader(ctx)) return 0xffff;
    const LzHeader& hdr = ctx->headers[ctx->currentIndex - 1];
    WORD wDate = 0;
    WORD wTime = 0;
    UnixTimeToDosTime(hdr.unix_last_modified_stamp, wDate, wTime);
    SetCompatError(0);
    return wTime;
}

int WINAPI UnlhaGetAttribute(HARC _harc) {
    ArcHandleLock lock(_harc);
    if (!lock.IsValid()) {
        g_last_error_code = ERROR_HARC_ISNOT_OPENED;
        return 0;
    }
    ArcHandleContext* ctx = lock.GetContext();
    if (!CurrentHeader(ctx)) return -1;
    const LzHeader& hdr = ctx->headers[ctx->currentIndex - 1];
    const int attr = HeaderAttributes(hdr);
    SetCompatError(0);
    return attr;
}

int WINAPI UnlhaGetLastError(LPDWORD _lpdwSystemError) {
    if (_lpdwSystemError) {
        *_lpdwSystemError = g_last_system_error;
    }
    return g_last_error_code;
}

static int HeaderAttributes(const LzHeader& header) {
    // DOS 系は記録された属性をそのまま返す。Level-0 の OS 省略も DOS と扱う。
    if (header.extend_type == EXTEND_MSDOS || header.extend_type == EXTEND_OS2 ||
        header.extend_type == 'W' || header.extend_type == 'w' ||
        (header.header_level == 0 && header.extend_type == EXTEND_GENERIC)) {
        return header.attribute;
    }
    int attributes = FA_ARCH;
    if (header.extend_type == EXTEND_UNIX) {
        if ((header.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_DIRECTORY) attributes |= FA_DIREC;
        if ((header.unix_mode & 0200) == 0) attributes |= FA_RDONLY;
    }
    return attributes;
}

static WORD HeaderRatio(const LzHeader& header) {
    if (header.original_size <= 0) return 0;
    const ULHA_INT64 ratio = (static_cast<ULHA_INT64>(header.packed_size) * 1000) /
                             static_cast<ULHA_INT64>(header.original_size);
    return static_cast<WORD>(ratio);
}

static FILETIME UnixTimeToFileTime(time_t value) {
    ULARGE_INTEGER converted{};
    if (value >= 0) {
        converted.QuadPart = static_cast<ULONGLONG>(value) * 10000000ULL + 116444736000000000ULL;
    }
    FILETIME result{};
    result.dwLowDateTime = converted.LowPart;
    result.dwHighDateTime = converted.HighPart;
    return result;
}

static FILETIME UInt64ToFileTime(const uint64_t value) {
    FILETIME result{};
    result.dwLowDateTime = static_cast<DWORD>(value);
    result.dwHighDateTime = static_cast<DWORD>(value >> 32);
    return result;
}

static FILETIME HeaderTimeToFileTime(const LzHeader& header, const MemberTimeKind kind) {
#ifdef HAVE_UINT64_T
    if (header.has_windows_timestamp) {
        switch (kind) {
        case MemberTimeKind::Create:
            return UInt64ToFileTime(header.windows_creation_time);
        case MemberTimeKind::Access:
            return UInt64ToFileTime(header.windows_last_access_time);
        case MemberTimeKind::Write:
            return UInt64ToFileTime(header.windows_last_modified_time);
        }
    }
#endif
    return UnixTimeToFileTime(header.unix_last_modified_stamp);
}

static FILETIME HeaderExtractionTime(const LzHeader& header, const MemberTimeKind kind) {
    FILETIME value = HeaderTimeToFileTime(header, kind);
    // 取得 API・通知では 0 をそのまま返すが、展開時の未記録の作成／参照日時は更新日時で補う。
    if (kind != MemberTimeKind::Write && value.dwLowDateTime == 0 && value.dwHighDateTime == 0)
        value = HeaderTimeToFileTime(header, MemberTimeKind::Write);
    return value;
}

static ULHA_INT64 FileTimeToUnixTime64(const FILETIME& value) {
    constexpr uint64_t kUnixEpochFileTime = 116444736000000000ULL;
    constexpr ULHA_INT64 kMinimumUnixTime = -6857222400LL; // 1752-09-14 00:00:00 UTC
    ULARGE_INTEGER converted{};
    converted.LowPart = value.dwLowDateTime;
    converted.HighPart = value.dwHighDateTime;
    if (converted.QuadPart >= kUnixEpochFileTime) {
        return static_cast<ULHA_INT64>((converted.QuadPart - kUnixEpochFileTime) / 10000000ULL);
    }
    const uint64_t seconds_before_epoch =
        (kUnixEpochFileTime - converted.QuadPart) / 10000000ULL;
    const ULHA_INT64 unix_time = -static_cast<ULHA_INT64>(seconds_before_epoch);
    return (std::max)(unix_time, kMinimumUnixTime);
}

static DWORD FileTimeToUnixTime32(const FILETIME& value) {
    const ULHA_INT64 converted = FileTimeToUnixTime64(value);
    return converted < 0 ? 0 : static_cast<DWORD>(converted);
}

static BOOL CopyFileTime(const FILETIME& source, FILETIME* destination) {
    if (!destination) {
        SetCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    *destination = source;
    SetCompatError(0);
    return TRUE;
}

static BOOL CopyTime64(ULHA_INT64 source, ULHA_INT64* destination) {
    if (!destination) {
        SetCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    *destination = source;
    SetCompatError(0);
    return TRUE;
}

static BOOL ArchiveDosTime(HARC archive, WORD* date, WORD* time) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return FALSE;
    }
    FILETIME local{};
    if (!FileTimeToLocalFileTime(&lock->writeTime, &local) ||
        !FileTimeToDosDateTime(&local, date, time)) {
        SetCompatError(ERROR_CONVERT_TIME, GetLastError());
        return FALSE;
    }
    SetCompatError(0);
    return TRUE;
}

WORD WINAPI UnlhaGetSubVersion() {
    SetCompatError(0);
    return 5;
}

BOOL WINAPI UnlhaGetBackGroundMode() {
    SetCompatError(0);
    return g_background_mode;
}

BOOL WINAPI UnlhaSetBackGroundMode(const BOOL mode) {
    SetCompatError(0);
    if (IsDllRunning()) return FALSE;
    g_background_mode = mode ? TRUE : FALSE;
    SetCompatError(0);
    return TRUE;
}

BOOL WINAPI UnlhaGetCursorMode() {
    SetCompatError(0);
    return g_cursor_mode;
}

BOOL WINAPI UnlhaSetCursorMode(const BOOL mode) {
    SetCompatError(0);
    if (IsDllRunning()) return FALSE;
    g_cursor_mode = mode ? TRUE : FALSE;
    SetCompatError(0);
    return TRUE;
}

WORD WINAPI UnlhaGetCursorInterval() {
    SetCompatError(0);
    return g_cursor_interval;
}

BOOL WINAPI UnlhaSetCursorInterval(const WORD interval) {
    SetCompatError(0);
    if (IsDllRunning()) return FALSE;
    g_cursor_interval = interval;
    SetCompatError(0);
    return TRUE;
}

BOOL WINAPI UnlhaQueryFunctionList(const int function) {
    SetCompatError(0);
    return (function >= 0 && function <= 8) ||
           (function >= 16 && function <= 19) ||
           (function >= 23 && function <= 26) ||
           (function >= 31 && function <= 34) ||
           (function >= 40 && function <= 51) ||
           (function >= 57 && function <= 72) ||
           (function >= 80 && function <= 114);
}

enum : int {
    IDD_UNLHA_CONFIG = 201,
    IDD_UNLHA_LOCAL_CONFIG = 202,
    IDC_CONFIG_DEFAULT_DIR = 401,
    IDC_CONFIG_DIRECTORY_GROUP = 402,
    IDC_CONFIG_DIRECTORY_ABSOLUTE = 403,
    IDC_CONFIG_DIRECTORY_RELATIVE = 404,
    IDC_CONFIG_OVERWRITE_GROUP = 405,
    IDC_CONFIG_OVERWRITE_ALWAYS = 406,
    IDC_CONFIG_OVERWRITE_QUERY = 407,
    IDC_CONFIG_OVERWRITE_NEVER = 408,
    IDC_CONFIG_ATTRIBUTES = 409,
    IDC_CONFIG_JUNK_DIRECTORY = 410,
    IDC_CONFIG_LOCAL = 411,
    IDC_CONFIG_SAVE = 412,
    IDC_CONFIG_BAD_PATH_GROUP = 413,
    IDC_CONFIG_BAD_PATH_0 = 414,
    IDC_CONFIG_BAD_PATH_1 = 415,
    IDC_CONFIG_BAD_PATH_2 = 416,
    IDC_LOCAL_MAKE_DIRECTORY = 502,
    IDC_LOCAL_DISK_SPACE = 503,
    IDC_LOCAL_TOTAL_BAR = 504,
    IDC_LOCAL_MINI_DIALOG = 505,
    IDC_LOCAL_FLUSH_BUFFER = 506,
    IDC_LOCAL_OLD_LOG = 507,
    IDC_LOCAL_OLD_GF = 508,
    IDC_LOCAL_MAPPED_FILE = 509,
};

struct ConfigDialogState {
    std::wstring defaultDirectory;
    int directoryMode = IDC_CONFIG_DIRECTORY_ABSOLUTE;
    int overwriteMode = IDC_CONFIG_OVERWRITE_QUERY;
    int badPathLevel = 1;
    bool extractAttributes = false;
    bool junkDirectory = false;
    bool forceUseAllPath = false;
    bool diskSpaceCheck = true;
    bool makeDirectoryMode = false;
    int totalBar = 0;
    int miniDialog = 0;
    bool flushBuffer = false;
    bool useOldLog = false;
    bool causeOldGf = false;
    bool useMappedFile = true;
    DWORD fileBufferSize = 0x40000;
};

static ConfigDialogState g_config_state;
static bool g_config_state_initialized = false;
static bool g_prepared_config_relative = false;

static bool ReadRegistryDword(HKEY key, const wchar_t* name, DWORD& value) {
    DWORD type = 0;
    DWORD size = sizeof(value);
    return RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<LPBYTE>(&value), &size) == ERROR_SUCCESS &&
           type == REG_DWORD && size == sizeof(value);
}

static void LoadConfigRegistry(ConfigDialogState& state) {
    HKEY common = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\ArchiverDll\\Common", 0,
                      KEY_QUERY_VALUE, &common) == ERROR_SUCCESS) {
        wchar_t directory[513]{};
        DWORD type = 0;
        DWORD size = sizeof(directory);
        if (RegQueryValueExW(common, L"DefaultDir", nullptr, &type,
                             reinterpret_cast<LPBYTE>(directory), &size) == ERROR_SUCCESS &&
            (type == REG_SZ || type == REG_EXPAND_SZ)) {
            directory[_countof(directory) - 1] = L'\0';
            state.defaultDirectory = directory;
            std::replace(state.defaultDirectory.begin(), state.defaultDirectory.end(), L'\\', L'/');
        }
        DWORD value = 0;
        if (ReadRegistryDword(common, L"DirectoryMode", value)) {
            state.directoryMode = value == 0
                                      ? IDC_CONFIG_DIRECTORY_RELATIVE
                                      : IDC_CONFIG_DIRECTORY_ABSOLUTE;
        }
        if (ReadRegistryDword(common, L"OverWriteMode", value)) {
            if (value == 0) {
                state.overwriteMode = IDC_CONFIG_OVERWRITE_ALWAYS;
            } else if (value == 2) {
                state.overwriteMode = IDC_CONFIG_OVERWRITE_NEVER;
            } else {
                state.overwriteMode = IDC_CONFIG_OVERWRITE_QUERY;
            }
        }
        if (ReadRegistryDword(common, L"ExtractAttribute", value)) {
            state.extractAttributes = value == 1;
        }
        if (ReadRegistryDword(common, L"JunkDirectory", value)) state.junkDirectory = value == 1;
        if (ReadRegistryDword(common, L"BadPathLevel", value)) {
            state.badPathLevel = value == 0 ? 0 : (value == 3 ? 3 : 1);
        }
        RegCloseKey(common);
    }

    HKEY local = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\ArchiverDll\\UNLHA32", 0,
                      KEY_QUERY_VALUE, &local) == ERROR_SUCCESS) {
        DWORD value = 0;
        if (ReadRegistryDword(local, L"ForceUseAllPath", value)) state.forceUseAllPath = value == 1;
        if (ReadRegistryDword(local, L"DiskSpaceCheck", value)) state.diskSpaceCheck = value != 0;
        if (ReadRegistryDword(local, L"MakeDirectoryMode", value)) state.makeDirectoryMode = value == 1;
        if (ReadRegistryDword(local, L"TotalBar", value))
            state.totalBar = value == 1 ? 1 : (value == MAXDWORD ? -1 : 0);
        if (ReadRegistryDword(local, L"FVMode", value))
            state.miniDialog = value == 1 ? 1 : (value == MAXDWORD ? -1 : 0);
        if (ReadRegistryDword(local, L"FlushBuffer", value)) state.flushBuffer = value == 1;
        if (ReadRegistryDword(local, L"UseOldLog", value)) state.useOldLog = value == 1;
        if (ReadRegistryDword(local, L"CauseOldGfSwitch", value)) state.causeOldGf = value == 1;
        if (ReadRegistryDword(local, L"UseMFile", value)) state.useMappedFile = value != 0;
        if (ReadRegistryDword(local, L"FileBufferSize", value) && value >= 8192 && value <= 524288)
            state.fileBufferSize = value;
        RegCloseKey(local);
    }
}

static void EnsureConfigState() {
    if (g_config_state_initialized) return;
    g_config_state = ConfigDialogState{};
    LoadConfigRegistry(g_config_state);
    g_config_state_initialized = true;
}

static bool ConfiguredMappedFileEnabled() {
    EnsureConfigState();
    return g_config_state.useMappedFile;
}

static DWORD ConfiguredFileBufferSize() {
    EnsureConfigState();
    return g_config_state.fileBufferSize;
}

static void PrepareConfiguredCommandState(const bool use_registry) {
    EnsureConfigState();
    g_prepared_config_relative = use_registry &&
        g_config_state.directoryMode == IDC_CONFIG_DIRECTORY_RELATIVE;
}

static DWORD GetConfiguredArchiveSearchMode(const DWORD mode) {
    EnsureConfigState();
    // ハンドル検索の設定は通常コマンドの有効設定・初期化順序とは独立する。
    if ((mode & (M_REGARDLESS_INIT_FILE | M_CHECK_ALL_PATH | M_CHECK_FILENAME_ONLY)) == 0 &&
        g_config_state.forceUseAllPath) return mode | M_CHECK_ALL_PATH;
    return mode;
}

static void GetConfiguredCommandDefaults(const bool use_registry, std::wstring& directory,
                                          std::vector<std::string>& switches) {
    EnsureConfigState();
    // 原版は今回の初期化より前に、前回の有効設定から基準ディレクトリを選ぶ。
    if (g_prepared_config_relative) directory = g_config_state.defaultDirectory;
    PrepareConfiguredCommandState(use_registry);
    if (!use_registry) return;
    // 保存設定は省略値として先に適用し、後続の明示スイッチで上書きする。
    if (g_config_state.overwriteMode == IDC_CONFIG_OVERWRITE_ALWAYS) switches.push_back("-c1");
    else if (g_config_state.overwriteMode == IDC_CONFIG_OVERWRITE_NEVER) switches.push_back("-jn1");
    if (g_config_state.junkDirectory) switches.push_back("-x0");
    if (g_config_state.extractAttributes) switches.push_back("-a1");
    if (g_config_state.makeDirectoryMode) switches.push_back("-jyc1");
    if (!g_config_state.diskSpaceCheck) switches.push_back("-f1");
}

static bool SaveConfigDword(const wchar_t* section, const wchar_t* name, const DWORD value,
                            const DWORD default_value) {
    const std::wstring path = std::wstring(L"Software\\ArchiverDll\\") + section;
    HKEY key = nullptr;
    DWORD current = default_value;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        ReadRegistryDword(key, name, current);
        RegCloseKey(key);
    }
    // 原版は未保存の既定値を作らず、既存値が変わったときだけ書き込む。
    if (current == value) return true;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
    const LSTATUS result = RegSetValueExW(key, name, 0, REG_DWORD,
                                         reinterpret_cast<const BYTE*>(&value), sizeof(value));
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

static bool SaveConfigRegistry(const ConfigDialogState& state) {
    ConfigDialogState current;
    LoadConfigRegistry(current);
    bool result = true;
    if (current.defaultDirectory != state.defaultDirectory) {
        HKEY common = nullptr;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\ArchiverDll\\Common", 0, nullptr, 0,
                            KEY_SET_VALUE, nullptr, &common, nullptr) != ERROR_SUCCESS) return false;
        const DWORD bytes = static_cast<DWORD>((state.defaultDirectory.size() + 1) * sizeof(wchar_t));
        result = RegSetValueExW(common, L"DefaultDir", 0, REG_SZ,
                                reinterpret_cast<const BYTE*>(state.defaultDirectory.c_str()), bytes) == ERROR_SUCCESS;
        RegCloseKey(common);
    }
    result &= SaveConfigDword(L"Common", L"DirectoryMode",
                               state.directoryMode == IDC_CONFIG_DIRECTORY_ABSOLUTE ? 1U : 0U, 1);
    result &= SaveConfigDword(L"Common", L"OverWriteMode",
                               state.overwriteMode == IDC_CONFIG_OVERWRITE_ALWAYS ? 0U :
                               (state.overwriteMode == IDC_CONFIG_OVERWRITE_NEVER ? 2U : 1U), 1);
    result &= SaveConfigDword(L"Common", L"ExtractAttribute", state.extractAttributes ? 1U : 0U, 0);
    result &= SaveConfigDword(L"Common", L"JunkDirectory", state.junkDirectory ? 1U : 0U, 0);
    result &= SaveConfigDword(L"Common", L"BadPathLevel", static_cast<DWORD>(state.badPathLevel), 1);
    result &= SaveConfigDword(L"UNLHA32", L"DiskSpaceCheck", state.diskSpaceCheck ? 1U : 0U, 1);
    result &= SaveConfigDword(L"UNLHA32", L"MakeDirectoryMode", state.makeDirectoryMode ? 1U : 0U, 0);
    result &= SaveConfigDword(L"UNLHA32", L"TotalBar", static_cast<DWORD>(state.totalBar), 0);
    result &= SaveConfigDword(L"UNLHA32", L"FVMode", static_cast<DWORD>(state.miniDialog), 0);
    result &= SaveConfigDword(L"UNLHA32", L"FlushBuffer", state.flushBuffer ? 1U : 0U, 0);
    result &= SaveConfigDword(L"UNLHA32", L"UseOldLog", state.useOldLog ? 1U : 0U, 0);
    result &= SaveConfigDword(L"UNLHA32", L"CauseOldGfSwitch", state.causeOldGf ? 1U : 0U, 0);
    result &= SaveConfigDword(L"UNLHA32", L"UseMFile", state.useMappedFile ? 1U : 0U, 1);
    return result;
}

static void SetDialogItemText(HWND dialog, int id, const wchar_t* text) {
    SetDlgItemTextW(dialog, id, text);
}

static void LocalizeConfigDialog(HWND dialog) {
    if (!UseEnglishDialogResources()) return;
    SetWindowTextW(dialog, L"Setting UNLHA32");
    SetDialogItemText(dialog, 56, L"Base &Directory :");
    SetDialogItemText(dialog, IDC_CONFIG_JUNK_DIRECTORY, L"&Junked directory");
    SetDialogItemText(dialog, IDC_CONFIG_DIRECTORY_GROUP, L"Directory &Mode");
    SetDialogItemText(dialog, IDC_CONFIG_DIRECTORY_ABSOLUTE, L"Absolute");
    SetDialogItemText(dialog, IDC_CONFIG_DIRECTORY_RELATIVE, L"Relative");
    SetDialogItemText(dialog, IDC_CONFIG_BAD_PATH_GROUP, L"Invalid &Path check");
    SetDialogItemText(dialog, IDC_CONFIG_BAD_PATH_0, L"Level 0 (No check)");
    SetDialogItemText(dialog, IDC_CONFIG_BAD_PATH_1, L"Level 1 (Base directory)");
    SetDialogItemText(dialog, IDC_CONFIG_BAD_PATH_2, L"Level 2 (Abs. directory)");
    SetDialogItemText(dialog, IDC_CONFIG_OVERWRITE_GROUP, L"Overwrite &Query");
    SetDialogItemText(dialog, IDC_CONFIG_OVERWRITE_ALWAYS, L"Assume YES");
    SetDialogItemText(dialog, IDC_CONFIG_OVERWRITE_QUERY, L"Query");
    SetDialogItemText(dialog, IDC_CONFIG_OVERWRITE_NEVER, L"Assume NO");
    SetDialogItemText(dialog, IDC_CONFIG_ATTRIBUTES, L"Set &Attributes");
    SetDialogItemText(dialog, IDC_CONFIG_LOCAL, L"&Local Setting>>");
    SetDialogItemText(dialog, IDOK, L"&Ok");
    SetDialogItemText(dialog, IDCANCEL, L"&Cancel");
    SetDialogItemText(dialog, IDC_CONFIG_SAVE, L"&Save settings");
}

static void LocalizeLocalConfigDialog(HWND dialog) {
    if (!UseEnglishDialogResources()) return;
    SetWindowTextW(dialog, L"Setting UNLHA32 (local)");
    SetDialogItemText(dialog, IDC_LOCAL_MAKE_DIRECTORY, L"Suppress create directory &Query");
    SetDialogItemText(dialog, IDC_LOCAL_DISK_SPACE, L"Ensure free disk &Space");
    SetDialogItemText(dialog, IDC_LOCAL_FLUSH_BUFFER, L"Flush &Buffer");
    SetDialogItemText(dialog, IDC_LOCAL_MAPPED_FILE, L"Use memory-mapped &Files");
    SetDialogItemText(dialog, IDC_LOCAL_TOTAL_BAR, L"Progless bar mode : &Total");
    SetDialogItemText(dialog, IDC_LOCAL_MINI_DIALOG, L"Mini &Dialog");
    SetDialogItemText(dialog, IDC_LOCAL_OLD_LOG, L"Use old &Log");
    SetDialogItemText(dialog, IDC_LOCAL_OLD_GF, L"Cause old &Gf switch");
    SetDialogItemText(dialog, IDOK, L"&Ok");
    SetDialogItemText(dialog, IDCANCEL, L"&Cancel");
}

static ConfigDialogState* DialogConfigState(HWND dialog) {
    return reinterpret_cast<ConfigDialogState*>(GetWindowLongPtrW(dialog, DWLP_USER));
}

static void InitializeMainConfigControls(HWND dialog, const ConfigDialogState& state) {
    SetDlgItemTextW(dialog, IDC_CONFIG_DEFAULT_DIR, state.defaultDirectory.c_str());
    CheckRadioButton(dialog, IDC_CONFIG_DIRECTORY_ABSOLUTE, IDC_CONFIG_DIRECTORY_RELATIVE,
                     state.directoryMode);
    CheckRadioButton(dialog, IDC_CONFIG_OVERWRITE_ALWAYS, IDC_CONFIG_OVERWRITE_NEVER,
                     state.overwriteMode);
    const int badPathControl = state.badPathLevel == 0 ? IDC_CONFIG_BAD_PATH_0
                                : state.badPathLevel == 3 ? IDC_CONFIG_BAD_PATH_2
                                                        : IDC_CONFIG_BAD_PATH_1;
    CheckRadioButton(dialog, IDC_CONFIG_BAD_PATH_0, IDC_CONFIG_BAD_PATH_2, badPathControl);
    CheckDlgButton(dialog, IDC_CONFIG_ATTRIBUTES,
                   state.extractAttributes ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_CONFIG_JUNK_DIRECTORY,
                   state.junkDirectory ? BST_CHECKED : BST_UNCHECKED);
}

static void ReadMainConfigControls(HWND dialog, ConfigDialogState& state) {
    wchar_t directory[513]{};
    GetDlgItemTextW(dialog, IDC_CONFIG_DEFAULT_DIR, directory, _countof(directory));
    state.defaultDirectory = directory;
    state.directoryMode = IsDlgButtonChecked(dialog, IDC_CONFIG_DIRECTORY_RELATIVE) == BST_CHECKED
                              ? IDC_CONFIG_DIRECTORY_RELATIVE
                              : IDC_CONFIG_DIRECTORY_ABSOLUTE;
    if (IsDlgButtonChecked(dialog, IDC_CONFIG_OVERWRITE_ALWAYS) == BST_CHECKED) {
        state.overwriteMode = IDC_CONFIG_OVERWRITE_ALWAYS;
    } else if (IsDlgButtonChecked(dialog, IDC_CONFIG_OVERWRITE_NEVER) == BST_CHECKED) {
        state.overwriteMode = IDC_CONFIG_OVERWRITE_NEVER;
    } else {
        state.overwriteMode = IDC_CONFIG_OVERWRITE_QUERY;
    }
    if (IsDlgButtonChecked(dialog, IDC_CONFIG_BAD_PATH_0) == BST_CHECKED) {
        state.badPathLevel = 0;
    } else if (IsDlgButtonChecked(dialog, IDC_CONFIG_BAD_PATH_2) == BST_CHECKED) {
        state.badPathLevel = 3;
    } else {
        state.badPathLevel = 1;
    }
    state.extractAttributes = IsDlgButtonChecked(dialog, IDC_CONFIG_ATTRIBUTES) == BST_CHECKED;
    state.junkDirectory = IsDlgButtonChecked(dialog, IDC_CONFIG_JUNK_DIRECTORY) == BST_CHECKED;
}

static void InitializeLocalConfigControls(HWND dialog, const ConfigDialogState& state) {
    CheckDlgButton(dialog, IDC_LOCAL_MAKE_DIRECTORY,
                   state.makeDirectoryMode ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_DISK_SPACE,
                   state.diskSpaceCheck ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_TOTAL_BAR, state.totalBar ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_MINI_DIALOG, state.miniDialog ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_FLUSH_BUFFER,
                   state.flushBuffer ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_OLD_LOG, state.useOldLog ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_OLD_GF, state.causeOldGf ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(dialog, IDC_LOCAL_MAPPED_FILE,
                   state.useMappedFile ? BST_CHECKED : BST_UNCHECKED);
}

static void ReadLocalConfigControls(HWND dialog, ConfigDialogState& state) {
    state.makeDirectoryMode = IsDlgButtonChecked(dialog, IDC_LOCAL_MAKE_DIRECTORY) == BST_CHECKED;
    state.diskSpaceCheck = IsDlgButtonChecked(dialog, IDC_LOCAL_DISK_SPACE) == BST_CHECKED;
    state.totalBar = IsDlgButtonChecked(dialog, IDC_LOCAL_TOTAL_BAR) == BST_CHECKED;
    state.miniDialog = IsDlgButtonChecked(dialog, IDC_LOCAL_MINI_DIALOG) == BST_CHECKED;
    state.flushBuffer = IsDlgButtonChecked(dialog, IDC_LOCAL_FLUSH_BUFFER) == BST_CHECKED;
    state.useOldLog = IsDlgButtonChecked(dialog, IDC_LOCAL_OLD_LOG) == BST_CHECKED;
    state.causeOldGf = IsDlgButtonChecked(dialog, IDC_LOCAL_OLD_GF) == BST_CHECKED;
    state.useMappedFile = IsDlgButtonChecked(dialog, IDC_LOCAL_MAPPED_FILE) == BST_CHECKED;
}

INT_PTR CALLBACK UnlhaDialogProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam);
INT_PTR CALLBACK UnlhaLocalDlgProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam);

static std::wstring BuildConfigOptions(const ConfigDialogState& state) {
    std::wstring options = L"-+jf";
    if (state.directoryMode != IDC_CONFIG_DIRECTORY_ABSOLUTE) options += L'-';
    if (state.overwriteMode == IDC_CONFIG_OVERWRITE_ALWAYS) {
        options += L" -jyc1";
    } else if (state.overwriteMode == IDC_CONFIG_OVERWRITE_QUERY) {
        options += L" -jyc0";
    } else {
        options += L" -c1jn";
    }
    options += L" -";
    if (state.forceUseAllPath) options += L'p';
    if (state.junkDirectory) options += L"x0";
    options += state.diskSpaceCheck ? L"f0" : L"f1";
    if (state.extractAttributes) options += L"a1";
    options += L" -jsp" + std::to_wstring(state.badPathLevel);
    return options;
}

static BOOL RunConfigDialog(HWND owner, void* options, const bool wide) {
    const size_t requiredBytes = wide ? 513U * sizeof(wchar_t) : 513U;
    const DWORD previous_system_error = g_last_system_error;
    if (IsDllRunning()) {
        SetCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY);
        return ERROR_ALREADY_RUNNING;
    }
    if (options && IsBadWritePtr(options, requiredBytes)) {
        SetCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return ERROR_INVALID_VALUE;
    }
    if (options) {
        if (wide) *static_cast<wchar_t*>(options) = L'\0';
        else *static_cast<char*>(options) = '\0';
    }

    PrepareConfiguredCommandState(true);
    ConfigDialogState state = g_config_state;
    g_running = true;
    SetCompatError(0, previous_system_error);
    const INT_PTR result = DialogBoxParamW(g_hModule, MAKEINTRESOURCEW(IDD_UNLHA_CONFIG), owner,
                                            UnlhaDialogProc,
                                            reinterpret_cast<LPARAM>(&state));
    g_running = false;
    if (result != IDOK) {
        if (result == -1) SetCompatError(ERROR_NOT_SUPPORT, GetLastError());
        else SetCompatError(0, previous_system_error);
        return FALSE;
    }

    g_config_state = state;
    const std::wstring command = BuildConfigOptions(state);
    if (options) {
        if (wide) {
            wcscpy_s(static_cast<wchar_t*>(options), 513, command.c_str());
        } else {
            const std::string ansi = WideStringToMultiByte(command, CP_ACP);
            strcpy_s(static_cast<char*>(options), 513, (ansi + " ").c_str());
        }
    }
    SetCompatError(0, previous_system_error);
    return TRUE;
}

BOOL WINAPI UnlhaConfigDialogA(HWND owner, LPSTR options, const int) {
    return RunConfigDialog(owner, options, false);
}

BOOL WINAPI UnlhaConfigDialogW(HWND owner, LPWSTR options, const int) {
    return RunConfigDialog(owner, options, true);
}

int WINAPI UnlhaGetFileCountA(LPCSTR archive_file) {
    if (IsDllRunning()) { RecordBusyError(); return -1; }
    return UnlhaGetFileCountW(archive_file ? StringToWString(archive_file).c_str() : nullptr);
}

int WINAPI UnlhaGetFileCountW(LPCWSTR archive_file) {
    // 元版も BASIC 検査で数える。HARC を開く経路とはエラーと寿命が異なる。
    int count = 0;
    return CheckArchiveFileW(archive_file, CHECKARCHIVE_BASIC, &count) ? count : -1;
}

static UINT ArchiveCodePageFromOptions(const std::string& options, const UINT fallback) {
    const std::vector<std::string> tokens = TokenizeCommandLine(options);
    for (const std::string& token : tokens) {
        if (token.size() <= 4 || (token[0] != '-' && token[0] != '/')) continue;
        std::string name = token.substr(1, 3);
        std::transform(name.begin(), name.end(), name.begin(), LowerCharacter);
        if (name != "jtl") continue;
        char* end = NULL;
        const unsigned long value = strtoul(token.c_str() + 4, &end, 10);
        if (end && *end == '\0' && value <= MAXUINT && IsValidCodePage(static_cast<UINT>(value))) {
            return static_cast<UINT>(value);
        }
    }
    return fallback;
}

HARC WINAPI UnlhaOpenArchive2A(HWND hwnd, LPCSTR file_name, const DWORD mode, LPCSTR options) {
    HARC archive = UnlhaOpenArchive(hwnd, file_name, mode);
    if (archive) {
        ArcHandleLock lock(archive);
        if (lock.IsValid()) lock->archiveCodePage = ArchiveCodePageFromOptions(options ? options : "", lock->archiveCodePage);
    }
    return archive;
}

HARC WINAPI UnlhaOpenArchive2W(HWND hwnd, LPCWSTR file_name, const DWORD mode, LPCWSTR options) {
    HARC archive = UnlhaOpenArchiveW(hwnd, file_name, mode);
    if (archive) {
        ArcHandleLock lock(archive);
        if (lock.IsValid()) {
            const std::string utf8Options = options ? WideStringToUtf8(options) : std::string();
            lock->archiveCodePage = ArchiveCodePageFromOptions(utf8Options, lock->archiveCodePage);
        }
    }
    return archive;
}

DWORD WINAPI UnlhaGetArcReadSize(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return 0;
    }
    if (lock->searchState == ArcSearchState::NotStarted) {
        SetCompatError(ERROR_NOT_SEARCH_MODE, ERROR_INVALID_PARAMETER);
        return MAXDWORD;
    }
    SetCompatError(0);
    if (lock->readSize > MAXDWORD) {
        SetCompatError(ERROR_TOO_BIG, ERROR_ARITHMETIC_OVERFLOW);
        return MAXDWORD;
    }
    return static_cast<DWORD>(lock->readSize);
}

BOOL WINAPI UnlhaGetArcReadSizeEx(HARC archive, ULHA_INT64* size) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid() || !size) {
        SetCompatError(lock.IsValid() ? ERROR_INVALID_VALUE : ERROR_HARC_ISNOT_OPENED,
                       lock.IsValid() ? ERROR_INVALID_PARAMETER : ERROR_INVALID_HANDLE);
        return FALSE;
    }
    *size = lock->readSize;
    SetCompatError(0);
    return TRUE;
}

WORD WINAPI UnlhaGetArcRatio(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return 0;
    }
    if (lock->searchState == ArcSearchState::NotStarted) {
        SetCompatError(ERROR_NOT_SEARCH_MODE, ERROR_INVALID_PARAMETER);
        return 0xffff;
    }
    if (lock->originalSizeTotal == 0) {
        SetCompatError(0);
        return 0;
    }
    const ULHA_INT64 ratio = (lock->compressedSizeTotal * 1000) / lock->originalSizeTotal;
    SetCompatError(0);
    return static_cast<WORD>(ratio);
}

WORD WINAPI UnlhaGetArcDate(HARC archive) {
    WORD date = 0, time = 0;
    ArchiveDosTime(archive, &date, &time);
    return date;
}

WORD WINAPI UnlhaGetArcTime(HARC archive) {
    WORD date = 0, time = 0;
    ArchiveDosTime(archive, &date, &time);
    return time;
}

DWORD WINAPI UnlhaGetArcWriteTime(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return 0; }
    SetCompatError(0);
    return FileTimeToUnixTime32(lock->writeTime);
}

DWORD WINAPI UnlhaGetArcCreateTime(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return 0; }
    SetCompatError(0);
    return FileTimeToUnixTime32(lock->creationTime);
}

DWORD WINAPI UnlhaGetArcAccessTime(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return 0; }
    SetCompatError(0);
    return FileTimeToUnixTime32(lock->accessTime);
}

BOOL WINAPI UnlhaGetArcWriteTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyFileTime(lock->writeTime, value);
}

BOOL WINAPI UnlhaGetArcCreateTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyFileTime(lock->creationTime, value);
}

BOOL WINAPI UnlhaGetArcAccessTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyFileTime(lock->accessTime, value);
}

BOOL WINAPI UnlhaGetArcWriteTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyTime64(FileTimeToUnixTime64(lock->writeTime), value);
}

BOOL WINAPI UnlhaGetArcCreateTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyTime64(FileTimeToUnixTime64(lock->creationTime), value);
}

BOOL WINAPI UnlhaGetArcAccessTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) { SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE); return FALSE; }
    return CopyTime64(FileTimeToUnixTime64(lock->accessTime), value);
}

UINT WINAPI UnlhaGetArcOSType(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid() || lock->headers.empty()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return static_cast<UINT>(-1);
    }
    SetCompatError(0);
    return HeaderOsType(lock->headers.front());
}

int WINAPI UnlhaIsSFXFile(HARC archive) {
    ArcHandleLock lock(archive);
    if (!lock.IsValid()) {
        SetCompatError(ERROR_HARC_ISNOT_OPENED, ERROR_INVALID_HANDLE);
        return 0;
    }
    SetCompatError(0);
    return lock->sfxType;
}

int WINAPI UnlhaGetMethodA(HARC archive, LPSTR buffer, const int size) {
    GetterConversionError conversion_error;
    ArcHandleLock lock(archive);
    const int validation = ValidateStringGetter(lock, true);
    if (validation != 0) return validation;
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!g_unicode_mode.load())
        return CopyGetterNameA(StringToWString(header->method), buffer, size, conversion_error);
    if (!buffer) return 0;
    if (size < 0 || IsBadWritePtr(buffer, static_cast<UINT_PTR>(size))) return ERROR_INVALID_VALUE;
    // UTF-8 モードの方式名は、名前取得と異なり単純コピーされる。
    if (size > 0) lstrcpynA(buffer, header->method, size);
    return 0;
}

int WINAPI UnlhaGetMethodW(HARC archive, LPWSTR buffer, const int size) {
    GetterConversionError conversion_error;
    ArcHandleLock lock(archive);
    const int validation = ValidateStringGetter(lock, true);
    if (validation != 0) return validation;
    if (!buffer) return 0;
    if (size < 0 || IsBadWritePtr(buffer, static_cast<UINT_PTR>(size) * sizeof(wchar_t)))
        return ERROR_INVALID_VALUE;
    const LzHeader* header = CurrentHeader(lock.GetContext());
    // 元版の W 方式名は変換 API の出力そのもの。容量不足時にも末尾を上書きしない。
    if (MultiByteToWideChar(CP_THREAD_ACP, MB_PRECOMPOSED, header->method, -1, buffer, size) == 0) {
        conversion_error.error = GetLastError();
        SetCompatError(0, conversion_error.error);
    }
    return 0;
}

DWORD WINAPI UnlhaGetCompressedSize(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return MAXDWORD;
    SetCompatError(0);
    return static_cast<DWORD>(header->packed_size);
}

BOOL WINAPI UnlhaGetCompressedSizeEx(HARC archive, ULHA_INT64* size) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    if (!size) { SetCompatError(ERROR_NOT_SEARCH_MODE); return FALSE; }
    *size = header->packed_size;
    SetCompatError(0);
    return TRUE;
}

WORD WINAPI UnlhaGetRatio(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return 0xffff;
    SetCompatError(0);
    return HeaderRatio(*header);
}

DWORD WINAPI UnlhaGetWriteTime(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return MAXDWORD;
    SetCompatError(0);
    return FileTimeToUnixTime32(HeaderTimeToFileTime(*header, MemberTimeKind::Write));
}

DWORD WINAPI UnlhaGetCreateTime(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return MAXDWORD;
    SetCompatError(0);
    return FileTimeToUnixTime32(HeaderTimeToFileTime(*header, MemberTimeKind::Create));
}

DWORD WINAPI UnlhaGetAccessTime(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return MAXDWORD;
    SetCompatError(0);
    return FileTimeToUnixTime32(HeaderTimeToFileTime(*header, MemberTimeKind::Access));
}

BOOL WINAPI UnlhaGetWriteTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyFileTime(HeaderTimeToFileTime(*header, MemberTimeKind::Write), value);
}

BOOL WINAPI UnlhaGetCreateTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyFileTime(HeaderTimeToFileTime(*header, MemberTimeKind::Create), value);
}

BOOL WINAPI UnlhaGetAccessTimeEx(HARC archive, FILETIME* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyFileTime(HeaderTimeToFileTime(*header, MemberTimeKind::Access), value);
}

BOOL WINAPI UnlhaGetWriteTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyTime64(FileTimeToUnixTime64(HeaderTimeToFileTime(*header, MemberTimeKind::Write)), value);
}

BOOL WINAPI UnlhaGetCreateTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyTime64(FileTimeToUnixTime64(HeaderTimeToFileTime(*header, MemberTimeKind::Create)), value);
}

BOOL WINAPI UnlhaGetAccessTime64(HARC archive, ULHA_INT64* value) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return FALSE;
    return CopyTime64(FileTimeToUnixTime64(HeaderTimeToFileTime(*header, MemberTimeKind::Access)), value);
}

DWORD WINAPI UnlhaGetCRC(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return MAXDWORD;
    SetCompatError(0);
    return header->crc;
}

int WINAPI UnlhaGetAttributes(HARC archive) { return UnlhaGetAttribute(archive); }

UINT WINAPI UnlhaGetOSType(HARC archive) {
    ArcHandleLock lock(archive);
    const LzHeader* header = CurrentHeader(lock.GetContext());
    if (!header) return static_cast<UINT>(-1);
    SetCompatError(0);
    return HeaderOsType(*header);
}

BOOL WINAPI UnlhaSetOwnerWindowEx64(const HWND hwnd, LPARCHIVERPROC callback, const DWORD struct_size) {
    OwnerProgressLayout layout = OwnerProgressLayout::None;
    if (struct_size == sizeof(EXTRACTINGINFOEXA)) layout = OwnerProgressLayout::ExA;
    else if (struct_size == sizeof(EXTRACTINGINFOEXW)) layout = OwnerProgressLayout::ExW;
    else if (struct_size == sizeof(EXTRACTINGINFOEX32A)) layout = OwnerProgressLayout::Ex32A;
    else if (struct_size == sizeof(EXTRACTINGINFOEX32W)) layout = OwnerProgressLayout::Ex32W;
    else if (struct_size == sizeof(EXTRACTINGINFOEX64A)) layout = OwnerProgressLayout::Ex64A;
    else if (struct_size == sizeof(EXTRACTINGINFOEX64W)) layout = OwnerProgressLayout::Ex64W;
    if (layout == OwnerProgressLayout::None) {
        SetOwnerCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    return SetOwnerRegistration(hwnd, callback, layout, struct_size, FALSE);
}

BOOL WINAPI UnlhaKillOwnerWindowEx64(const HWND hwnd) { return KillOwnerRegistration(hwnd); }

static BOOL RegisterEnumMembers(UNLHA_WND_ENUMMEMBPROC callback, const DWORD struct_size) {
    if (g_running) { SetCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY); return FALSE; }
    EnumTextMode enum_mode = EnumTextMode::None;
    if (struct_size == sizeof(UNLHA_ENUM_MEMBER_INFOA) ||
        struct_size == sizeof(UNLHA_ENUM_MEMBER_INFO64A)) {
        enum_mode = EnumTextMode::Ansi;
    } else if (struct_size == sizeof(UNLHA_ENUM_MEMBER_INFOW) ||
               struct_size == sizeof(UNLHA_ENUM_MEMBER_INFO64W)) {
        enum_mode = EnumTextMode::Wide;
    } else {
        SetCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    // 原版はサイズを先に検査し、有効なサイズの NULL 登録は既存登録を保持して失敗する。
    SetCompatError(0);
    if (!callback) return FALSE;
    if (IsBadCodePtr(reinterpret_cast<FARPROC>(callback))) {
        SetCompatError(ERROR_INVALID_VALUE, ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    g_enum_members_proc = callback;
    g_enum_struct_size = struct_size;
    g_enum_text_mode = enum_mode;
    g_enum_metadata = {};
    SetCompatError(0);
    return TRUE;
}

BOOL WINAPI UnlhaSetEnumMembersProcA(UNLHA_WND_ENUMMEMBPROC callback) {
    return RegisterEnumMembers(callback, sizeof(UNLHA_ENUM_MEMBER_INFOA));
}

BOOL WINAPI UnlhaSetEnumMembersProcW(UNLHA_WND_ENUMMEMBPROC callback) {
    return RegisterEnumMembers(callback, sizeof(UNLHA_ENUM_MEMBER_INFOW));
}

BOOL WINAPI UnlhaClearEnumMembersProc() {
    if (g_running) { SetCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY); return FALSE; }
    g_enum_members_proc = NULL;
    g_enum_struct_size = 0;
    g_enum_text_mode = EnumTextMode::None;
    g_enum_metadata = {};
    SetCompatError(0);
    return TRUE;
}

BOOL WINAPI UnlhaSetEnumMembersProc64(UNLHA_WND_ENUMMEMBPROC callback, const DWORD struct_size) {
    return RegisterEnumMembers(callback, struct_size);
}

BOOL WINAPI UnlhaClearEnumMembersProc64() { return UnlhaClearEnumMembersProc(); }

BOOL WINAPI SetLangueSpecified(const LANGID language) { g_language = language; SetCompatError(0); return TRUE; }
BOOL WINAPI SetLangueJapanese() { return SetLangueSpecified(MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT)); }
BOOL WINAPI SetLangueEnglish() { return SetLangueSpecified(MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT)); }
BOOL WINAPI UnlhaSetLangueSpecified(const LANGID language) { return SetLangueSpecified(language); }
BOOL WINAPI UnlhaSetLangueJapanese() { return SetLangueJapanese(); }
BOOL WINAPI UnlhaSetLangueEnglish() { return SetLangueEnglish(); }

static thread_local UINT g_requested_code_page = 0;
static thread_local bool g_requested_code_page_supported = false;

static BOOL CALLBACK FindSupportedCodePage(LPSTR value) {
    if (strtoul(value, nullptr, 10) != g_requested_code_page) return TRUE;
    g_requested_code_page_supported = true;
    return FALSE;
}

BOOL WINAPI UnlhaSetCP(UINT code_page) {
    SetCompatError(0);
    if (IsDllRunning()) return FALSE;
    if (code_page > 0xffffU) code_page = CP_THREAD_ACP;
    g_requested_code_page = code_page;
    g_requested_code_page_supported = false;
    EnumSystemCodePagesA(FindSupportedCodePage, CP_SUPPORTED);
    if (g_requested_code_page_supported) g_code_page.store(code_page);
    // 特殊値 3 は列挙されない。同じ値なら成功し、異なる未対応値は既定へ戻して失敗する。
    if (g_code_page.load() == code_page) return TRUE;
    g_code_page.store(CP_THREAD_ACP);
    return FALSE;
}

UINT WINAPI UnlhaGetCP() {
    SetCompatError(0);
    return IsDllRunning() ? MAXUINT : g_code_page.load();
}

BOOL WINAPI UnlhaSetUnicodeMode(const BOOL unicode_mode) {
    SetCompatError(0);
    if (IsDllRunning()) return FALSE;
    g_unicode_mode.store(unicode_mode);
    SetCompatError(0);
    return TRUE;
}

BOOL WINAPI UnlhaSetPriority(const int priority) {
    if (g_running) { SetCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY); return FALSE; }
    g_priority = priority;
    SetCompatError(0);
    return TRUE;
}

static bool ParseMemoryCommand(const char* command_line, std::string& archive, std::string& member) {
    if (!command_line || !*command_line) return false;
    const std::vector<std::string> tokens = TokenizeCommandLine(command_line);
    std::vector<std::string> operands;
    for (const auto& token : tokens) {
        if (token.empty() || token[0] == '-' || token[0] == '/') continue;
        if (operands.empty() && token.size() == 1 && isalpha(static_cast<unsigned char>(token[0]))) continue;
        operands.push_back(token);
    }
    if (operands.empty()) return false;
    archive = operands[0];
    if (operands.size() > 1) member = operands[1];
    std::replace(member.begin(), member.end(), '\\', '/');
    return true;
}

static bool ParseMemoryCommandW(const wchar_t* command_line, std::wstring& archive,
                                std::wstring& member, bool& preserve_directories) {
    if (!command_line || !*command_line) return false;
    const std::vector<std::wstring> tokens = TokenizeCommandLineW(command_line);
    std::vector<std::wstring> operands;
    for (const std::wstring& token : tokens) {
        if (token.empty()) continue;
        if (token[0] == L'-' || token[0] == L'/') {
            std::wstring option = token.substr(1);
            std::transform(option.begin(), option.end(), option.begin(), towlower);
            if (option == L"x" || option == L"x1") preserve_directories = true;
            else if (option == L"x0") preserve_directories = false;
            continue;
        }
        if (operands.empty() && token.size() == 1 && iswalpha(token[0])) continue;
        operands.push_back(token);
    }
    if (operands.empty()) return false;
    archive = operands[0];
    if (operands.size() > 1) member = operands[1];
    std::replace(member.begin(), member.end(), L'\\', L'/');
    return true;
}

static int MethodNumber(const char method[5]) {
    static const char* const methods[] = {
        LZHUFF0_METHOD, LZHUFF1_METHOD, LZHUFF2_METHOD, LZHUFF3_METHOD,
        LZHUFF4_METHOD, LZHUFF5_METHOD, LZHUFF6_METHOD, LZHUFF7_METHOD,
        LARC_METHOD, LARC5_METHOD, LARC4_METHOD, LZHDIRS_METHOD,
        PMARC0_METHOD, PMARC2_METHOD, LZHUFFX_METHOD, LZHUFFLX1_METHOD
    };
    for (int index = 0; index < static_cast<int>(_countof(methods)); ++index) {
        if (memcmp(method, methods[index], 5) == 0) return index;
    }
    return -1;
}

// 本家のメモリ API は、非該当・引数エラーでも直前に処理した項目の情報を返す。
static time_t g_memory_timestamp = 0;
static WORD g_memory_attributes = 0;
static DWORD g_memory_written = 0;

struct MemoryExtractCommand {
    struct Pattern { std::wstring name; std::wstring directory; };
    std::wstring archive;
    std::wstring directory;
    std::vector<Pattern> patterns;
    std::vector<std::wstring> exclusions;
    int path_mode = 0;
    int recursive_mode = 0;
    bool preserve_directories = false;
    bool reject_foreign_data = true;
    bool suppress_progress = false;
};

extern "C++" {

static constexpr int kMemoryProgressDialogResource = 203;
// 原版の進捗画面は IDOK (1) を「取消」ボタンとして使う。
static constexpr int kMemoryProgressCancelControl = IDOK;

static std::wstring MemoryProgressNumber(const __int64 value) {
    std::wstring digits = std::to_wstring(static_cast<unsigned long long>((std::max)(value, __int64{0})));
    for (ptrdiff_t index = static_cast<ptrdiff_t>(digits.size()) - 3; index > 0; index -= 3)
        digits.insert(static_cast<size_t>(index), 1, L',');
    return digits;
}

class MemoryProgressDialog final {
public:
    MemoryProgressDialog(const HWND owner, const bool suppressed, std::wstring archive)
        : owner_(owner), suppressed_(suppressed), archive_(std::move(archive)) {}

    ~MemoryProgressDialog() {
        if (dialog_) DestroyWindow(dialog_);
    }

    void Create() {
        if (suppressed_ || !EnsureBarWindowClass()) return;
        dialog_ = CreateDialogParamW(g_hModule, MAKEINTRESOURCEW(kMemoryProgressDialogResource), owner_, DialogProc,
                                      reinterpret_cast<LPARAM>(this));
        if (!dialog_) return;

        RECT client{};
        GetClientRect(dialog_, &client);
        const int bar_left = MulDiv(8, client.right, 333);
        const int top = MulDiv(73, client.bottom, 123);
        const int bar_right = MulDiv(323, client.right, 333);
        const int bottom = MulDiv(91, client.bottom, 123);
        bar_ = CreateWindowExW(0, L"BarWindow", L"", WS_CHILD | WS_VISIBLE | WS_BORDER,
                               bar_left, top, bar_right - bar_left, bottom - top, dialog_,
                               reinterpret_cast<HMENU>(608), g_hModule, this);
        if (!bar_) {
            DestroyWindow(dialog_);
            dialog_ = nullptr;
            return;
        }
        ShowWindow(dialog_, SW_SHOW);
        UpdateWindow(dialog_);
    }

    void Begin(const LzHeader& header) {
        member_ = HeaderNameToWString(header, ConfiguredArchiveCodePage());
        total_ = (std::max)(header.original_size, off_t{0});
        current_ = 0;
        populated_ = false;
    }

    int Dispatch(const int state, const __int64 current_size, const __int64 total_size) {
        if (!dialog_) return 0;
        if (state == ARCEXTRACT_BEGIN || state == ARCEXTRACT_INPROCESS) {
            if (total_size > 0) total_ = total_size;
            if (current_size >= 0) current_ = current_size;
            if (!populated_ && !member_.empty()) {
                SetDlgItemTextW(dialog_, 603, CompactArchivePath().c_str());
                SetDlgItemTextW(dialog_, 604, member_.c_str());
                populated_ = true;
            }
            SetDlgItemTextW(dialog_, 606, MemoryProgressNumber(current_).c_str());
            InvalidateRect(bar_, nullptr, FALSE);
        }
        PumpMessages();
        return cancelled_ ? 1 : 0;
    }

    bool Cancelled() const { return cancelled_; }
    DWORD CurrentSize() const {
        return static_cast<DWORD>((std::min)((std::max)(current_, __int64{0}), static_cast<__int64>(MAXDWORD)));
    }

private:
    static bool EnsureBarWindowClass() {
        static const bool registered = [] {
            WNDCLASSW existing{};
            if (GetClassInfoW(g_hModule, L"BarWindow", &existing)) return true;
            WNDCLASSW window_class{};
            window_class.lpfnWndProc = BarProc;
            window_class.hInstance = g_hModule;
            window_class.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
            window_class.lpszClassName = L"BarWindow";
            return RegisterClassW(&window_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        }();
        return registered;
    }

    static std::wstring CompactPath(HWND control, const std::wstring& path) {
        if (!control || path.empty()) return path;
        std::vector<wchar_t> compact(path.begin(), path.end());
        compact.push_back(L'\0');
        RECT client{};
        HDC dc = GetDC(control);
        GetClientRect(control, &client);
        if (dc && client.right > 0) PathCompactPathW(dc, compact.data(), client.right);
        if (dc) ReleaseDC(control, dc);
        return compact.data();
    }

    std::wstring CompactArchivePath() const {
        std::wstring display = archive_;
        std::replace(display.begin(), display.end(), L'/', L'\\');
        return CompactPath(GetDlgItem(dialog_, 603), display);
    }

    void Initialize() {
        const bool english = UseEnglishDialogResources();
        // 原版は言語リソースごとに、3 行の値欄を同じ左端へ揃える。
        const int value_left = english ? 78 : 83;
        SetWindowTextW(dialog_, english ? L"Melting..." : L"展開状況");
        SetProgressLabel(601, english ? L"Archive :" : L"書庫ファイル：", 603, value_left);
        SetProgressLabel(602, english ? L"Stored file :" : L"格納ファイル：", 604, value_left);
        SetProgressLabel(609, english ? L"Restore :" : L"展開先：", 610, value_left);
        SetProgressLabel(605, english ? L"Size :" : L"書込サイズ：", 0);
        SetDlgItemTextW(dialog_, 611, L"[1/-]");
        SetDlgItemTextW(dialog_, kMemoryProgressCancelControl, english ? L"&Cancel" : L"取消(&C)");
    }

    void SetProgressLabel(const int label_id, const wchar_t* label_text, const int value_id,
                          const int fixed_value_left = 0) {
        SetDlgItemTextW(dialog_, label_id, label_text);
        const HWND label = GetDlgItem(dialog_, label_id);
        if (!label) return;
        HDC dc = GetDC(label);
        if (!dc) return;
        const HFONT font = reinterpret_cast<HFONT>(SendMessageW(label, WM_GETFONT, 0, 0));
        const HGDIOBJ previous = font ? SelectObject(dc, font) : nullptr;
        SIZE extent{};
        const bool measured = GetTextExtentPoint32W(dc, label_text, static_cast<int>(wcslen(label_text)), &extent) != FALSE;
        if (previous) SelectObject(dc, previous);
        ReleaseDC(label, dc);
        if (!measured) return;

        RECT label_rect{};
        GetWindowRect(label, &label_rect);
        MapWindowPoints(nullptr, dialog_, reinterpret_cast<POINT*>(&label_rect), 2);
        const int width = extent.cx + 5;
        SetWindowPos(label, nullptr, label_rect.left, label_rect.top, width,
                     label_rect.bottom - label_rect.top, SWP_NOACTIVATE | SWP_NOZORDER);
        if (value_id == 0) return;

        const HWND value = GetDlgItem(dialog_, value_id);
        if (!value) return;
        RECT value_rect{};
        GetWindowRect(value, &value_rect);
        MapWindowPoints(nullptr, dialog_, reinterpret_cast<POINT*>(&value_rect), 2);
        const int value_left = fixed_value_left ? fixed_value_left : label_rect.left + width + 5;
        SetWindowPos(value, nullptr, value_left, value_rect.top, value_rect.right - value_left,
                     value_rect.bottom - value_rect.top, SWP_NOACTIVATE | SWP_NOZORDER);
    }

    void PumpMessages() {
        MSG message{};
        // 原版と同じく、WM_QUIT を含む呼び出し元スレッド全体のキューを取得する。
        while (dialog_ && PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (!IsDialogMessageW(dialog_, &message)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }

    void PaintBar(HDC dc, const RECT& client) const {
        FillRect(dc, &client, GetSysColorBrush(COLOR_WINDOW));
        FrameRect(dc, &client, GetSysColorBrush(COLOR_WINDOWFRAME));
        RECT fill = client;
        InflateRect(&fill, -1, -1);
        if (fill.right <= fill.left || fill.bottom <= fill.top) return;
        if (total_ > 0 && current_ > 0) {
            const __int64 bounded = (std::min)(current_, total_);
            fill.right = fill.left + MulDiv(fill.right - fill.left, static_cast<int>(bounded * 100 / total_), 100);
            if (fill.right > fill.left) FillRect(dc, &fill, GetSysColorBrush(COLOR_HIGHLIGHT));
        }
    }

    static LRESULT CALLBACK BarProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        if (message == WM_NCCREATE) {
            const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        } else if (message == WM_PAINT) {
            PAINTSTRUCT paint{};
            const HDC dc = BeginPaint(window, &paint);
            RECT client{};
            GetClientRect(window, &client);
            if (auto* self = reinterpret_cast<MemoryProgressDialog*>(GetWindowLongPtrW(window, GWLP_USERDATA)))
                self->PaintBar(dc, client);
            else
                FillRect(dc, &client, GetSysColorBrush(COLOR_WINDOW));
            EndPaint(window, &paint);
            return 0;
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }

    static INT_PTR CALLBACK DialogProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
        auto* self = reinterpret_cast<MemoryProgressDialog*>(GetWindowLongPtrW(dialog, DWLP_USER));
        if (message == WM_INITDIALOG) {
            self = reinterpret_cast<MemoryProgressDialog*>(lparam);
            SetWindowLongPtrW(dialog, DWLP_USER, reinterpret_cast<LONG_PTR>(self));
            if (!self) return FALSE;
            self->dialog_ = dialog;
            self->Initialize();
            return TRUE;
        }
        if (!self) return FALSE;
        if (message == WM_COMMAND && LOWORD(wparam) == kMemoryProgressCancelControl) {
            self->cancelled_ = true;
            EnableWindow(GetDlgItem(dialog, kMemoryProgressCancelControl), FALSE);
            return TRUE;
        }
        if (message == WM_CLOSE) {
            self->cancelled_ = true;
            EnableWindow(GetDlgItem(dialog, kMemoryProgressCancelControl), FALSE);
            return TRUE;
        }
        if (message == WM_NCDESTROY) self->dialog_ = nullptr;
        return FALSE;
    }

    HWND owner_{};
    HWND dialog_{};
    HWND bar_{};
    bool suppressed_{};
    bool cancelled_{};
    bool populated_{};
    std::wstring archive_;
    std::wstring member_;
    __int64 current_{};
    __int64 total_{};
};

struct MemoryProgressDialogScope final {
    MemoryProgressDialog* previous = g_memory_progress_dialog;
    explicit MemoryProgressDialogScope(MemoryProgressDialog& dialog) { g_memory_progress_dialog = &dialog; }
    ~MemoryProgressDialogScope() { g_memory_progress_dialog = previous; }
};

extern "C" int Lha_DispatchMemoryProgress(const int state, const LzHeader*, const char*, const char*,
                                            const __int64 current_size, const __int64 total_size) {
    return g_memory_progress_dialog ? g_memory_progress_dialog->Dispatch(state, current_size, total_size) : 0;
}

} // extern "C++"

extern "C++" {
static std::wstring MemoryBaseDirectory(std::wstring directory) {
    if (directory == L"./") directory.clear();
    if (directory.empty() || (directory.front() != L'/' &&
        (directory.size() < 2 || directory[1] != L':'))) {
        const DWORD length = GetCurrentDirectoryW(0, nullptr);
        std::wstring current(length, L'\0');
        if (length && GetCurrentDirectoryW(length, &current[0])) {
            current.resize(std::wcslen(current.c_str()));
            std::replace(current.begin(), current.end(), L'\\', L'/');
            if (!current.empty() && current.back() != L'/') current.push_back(L'/');
            directory.insert(0, current);
        }
    }
    // 基準ディレクトリは絶対化するが、内部の ../ や連続区切りは畳み込まない。
    if (directory.size() > FNAME_MAX32) directory.resize(FNAME_MAX32);
    return directory;
}
}

static int ParseMemoryExtractCommand(const std::wstring& command_line,
                                      const bool wide_response, MemoryExtractCommand& command) {
    std::vector<ParsedCommandArgument<std::wstring>> args;
    const auto split = [](const std::wstring& value) {
        std::vector<std::wstring> result;
        for (const auto& option : SplitCompatibleSwitches(WideStringToUtf8(value)))
            result.push_back(MultiByteStringToWide(option, CP_UTF8));
        return result;
    };
    const auto read = [wide_response](const std::wstring& path, std::vector<std::wstring>& arguments) {
        return ReadResponseArgumentsW(path, arguments, wide_response);
    };
    if (!ParseCompatibleArguments(TokenizeCommandLineW(command_line), args, read, split)) {
        SetCompatError(0, GetLastError());
        return ERROR_RESPONSE_READ;
    }
    PrepareConfiguredCommandState(UseCommandRegistry(args));
    command.directory = MemoryBaseDirectory(L"");
    for (const auto& arg : args) {
        if (arg.is_switch) {
            std::string option = WideStringToUtf8(arg.value.substr(1));
            std::transform(option.begin(), option.end(), option.begin(), LowerCharacter);
            if (option.empty()) continue;
            if (option[0] == 'p') {
                command.path_mode = CommandSwitchValue(option, 1, command.path_mode, 2);
                if (command.path_mode == 2) command.recursive_mode = 2;
            } else if (option[0] == 'r') command.recursive_mode = CommandSwitchValue(option, 1, command.recursive_mode, 2);
            else if (option[0] == 'x') command.preserve_directories = CommandSwitchValue(option, 1, command.preserve_directories, 1) != 0;
            else if (option[0] == 'n') command.suppress_progress =
                CommandSwitchValue(option, 1, command.suppress_progress ? 1 : 0, 2) != 0;
            else if (option.rfind("jx", 0) == 0 && arg.value.size() > 3) command.exclusions.push_back(arg.value.substr(3));
            else if (option.rfind("jsg", 0) == 0)
                command.reject_foreign_data = CommandSwitchValue(option, 3, command.reject_foreign_data, 1) != 0;
        } else {
            std::wstring value = arg.value;
            std::replace(value.begin(), value.end(), L'\\', L'/');
            std::replace(value.begin(), value.end(), L'\xffff', L'/');
            if (command.archive.empty()) command.archive = value;
            else if (!arg.force_file && !value.empty() && (value.back() == L'/' || value.back() == L':'))
                command.directory = MemoryBaseDirectory(value);
            else command.patterns.push_back({value, command.directory});
        }
    }
    if (command.archive.empty()) return ERROR_NOT_FILENAME;
    return 0;
}

static void CopyMemoryResult(const DWORD amount, time_t* timestamp,
                              LPWORD attributes, LPDWORD written) {
    if (written) *written = amount;
    if (timestamp) *timestamp = g_memory_timestamp;
    if (attributes) *attributes = g_memory_attributes;
}

static bool ReadArchiveHeaderGuarded(FILE* archive, LzHeader& header) {
    // C コアの致命的エラーを DLL の呼び出し元まで伝播させない。
    // FILE はこの呼び出し元が所有し、コアの cleanup へは登録しない。
    jmp_buf scope;
    jmp_buf* const previous_scope = g_lha_scoped_exit;
    g_lha_scoped_exit = &scope;
#pragma warning(push)
#pragma warning(disable: 4611)
    if (setjmp(scope) != 0) {
        g_lha_scoped_exit = previous_scope;
        return false;
    }
    const bool valid = get_header(archive, &header) != FALSE;
#pragma warning(pop)
    g_lha_scoped_exit = previous_scope;
    return valid;
}

static int ExtractMemFromStream(HWND hwnd, FILE* archive,
                                const MemoryExtractCommand& command, LPBYTE buffer, const DWORD size,
                                time_t* timestamp, LPWORD attributes, LPDWORD written) {
    // 処理中の再入 API は書き込み済み量でなく外側の残り容量を返す。
    g_memory_written = size;
    lha_init_variable();
    make_crctable();
    Lha_ResetAbort();
    Lha_ClearProgressMember();
    g_hwndOwner = hwnd;
    g_running = true;
    g_memory_extracting = true;
    // メモリ API は -n1/-n2 のときだけ登録済みの外部進捗を送る。
    CommandProgressMode memory_progress_mode(command.suppress_progress);
    g_enum_command = UNLHA_TEST_COMMAND;
    g_enum_invoked_count = g_enum_selected_count = 0;
    g_enum_selection_results.clear();
    MemoryProgressDialog progress_dialog(hwnd, command.suppress_progress, command.archive);
    progress_dialog.Create();
    MemoryProgressDialogScope progress_dialog_scope(progress_dialog);

    DWORD total_written = 0;
    int result = 0;
    int retained_error = 0;
    DWORD retained_system_error = ERROR_NO_MORE_FILES;
    DWORD system_error = ERROR_HANDLE_EOF;
    _fseeki64(archive, 0, SEEK_END);
    const __int64 file_size = _ftelli64(archive);
    bool first_header = true;
    LzHeader header{};
    const std::string progress_archive = WideStringToUtf8(command.archive);
    if (Lha_SendProgressMessage(ARCEXTRACT_OPEN, progress_archive.c_str(), 0, 0)) {
        result = ERROR_USER_CANCEL;
        system_error = ERROR_CANCELLED;
    }
    while (result == 0) {
        __int64 header_start;
        if (first_header) {
            if (!FindValidArchiveHeader(archive, 0, file_size, file_size, header)) {
                if (header.header_level >= 2)
                    Lha_RecordProgressHeaderError(&header, HeaderOsType(header));
                result = ERROR_FILE_STYLE;
                break;
            }
            DWORD tail_error = ERROR_SUCCESS;
            if (command.reject_foreign_data && HasForeignArchiveTail(archive, file_size, tail_error)) {
                result = ERROR_FILE_STYLE;
                system_error = ERROR_NO_MORE_FILES;
                break;
            }
            if (tail_error != ERROR_SUCCESS) retained_system_error = tail_error;
            first_header = false;
        } else {
            header_start = _ftelli64(archive);
            const int marker = fgetc(archive);
            if (marker == 0) {
                Lha_RecordProgressHeaderEnd();
                system_error = file_size - header_start < 21 ? ERROR_HANDLE_EOF : retained_system_error;
                break;
            }
            if (marker == EOF) {
                Lha_RecordProgressHeaderEnd();
                retained_error = ERROR_NO_END_MARK;
                system_error = 0;
                break;
            }
            unsigned char common[21]{};
            _fseeki64(archive, header_start, SEEK_SET);
            const size_t available = fread(common, 1, sizeof(common), archive);
            _fseeki64(archive, header_start, SEEK_SET);
            if (available < sizeof(common)) {
                // 1 バイトの不正終端は警告、2～20 バイトのヘッダー不足は展開失敗になる。
                if (available == 1) {
                    retained_error = ERROR_INVALID_END_MARK;
                    system_error = 0;
                } else if (available != 0) {
                    result = ERROR_UNEXPECTED_EOF;
                    system_error = 0;
                } else {
                    result = ERROR_CANNOT_READ;
                }
                break;
            }
            if (common[20] > 3) { result = ERROR_UNKNOWN_LEVEL; system_error = 0; break; }
            const bool parsed_header = ReadArchiveHeaderGuarded(archive, header);
            if (!parsed_header ||
                !ValidateRawHeaderCrc(archive, header_start, _ftelli64(archive), header.header_level)) {
                if (parsed_header && header.header_level >= 2)
                    Lha_RecordProgressHeaderError(&header, HeaderOsType(header));
                result = ERROR_HEADER_CRC;
                system_error = 0;
                break;
            }
        }
        Lha_RecordEnumHeader(&header);
        const __int64 next_header = _ftelli64(archive) + header.packed_size;
        const std::wstring archive_member = HeaderNameToWString(header, ConfiguredArchiveCodePage());
        const auto matches = [&](const std::wstring& pattern, const bool exclusion) {
            return CommandPatternMatches(pattern, archive_member, exclusion, command.path_mode, command.recursive_mode);
        };
        std::wstring directory = command.directory;
        bool selected = command.patterns.empty() && matches(L"*", false);
        for (const auto& pattern : command.patterns) {
            if (matches(pattern.name, false)) {
                selected = true;
                directory = pattern.directory;
                break;
            }
        }
        if (selected && std::any_of(command.exclusions.begin(), command.exclusions.end(),
                [&](const std::wstring& pattern) { return matches(pattern, true); })) selected = false;
        // 原版は PMarc を列挙通知・メモリ出力・返却メタデータの更新より前に読み飛ばす。
        const int method = MethodNumber(header.method);
        if (method == PMARC0_METHOD_NUM || method == PMARC2_METHOD_NUM) selected = false;
        if (selected) {
            std::wstring destination = archive_member;
            if (!command.preserve_directories) {
                const size_t separator = destination.find_last_of(L"/\\");
                if (separator != std::wstring::npos) destination.erase(0, separator + 1);
            }
            g_enum_additional_w = directory + destination;
            std::replace(g_enum_additional_w.begin(), g_enum_additional_w.end(), L'\\', L'/');
            g_enum_additional_w_active = true;
            selected = Lha_InvokeEnumMember(&header, nullptr, 0) != FALSE;
            g_enum_additional_w_active = false;
        }
        if (selected) {
            if (next_header > file_size || header.packed_size < 0) {
                result = ERROR_CANNOT_READ;
                break;
            }
            if (method < 0) {
                result = ERROR_METHOD;
                system_error = ERROR_NOT_SUPPORTED;
                break;
            }
            if (method != LZHDIRS_METHOD_NUM) {
                FILE* output = Lha_TemporaryFile();
                if (!output) {
                    result = ERROR_TMP_OPEN;
                    system_error = GetLastError();
                    break;
                }
                Lha_SetProgressMember(&header);
                progress_dialog.Begin(header);
                const int decode_result = DecodeArchiveMemberGuarded(archive, output, header, method);
                if (progress_dialog.Cancelled() || Lha_CheckAbort()) {
                    // 原版は取消時に、これまでに出力済みの量を残りバッファー量として返す。
                    fflush(output);
                    __int64 partial_size = 0;
                    if (_fseeki64(output, 0, SEEK_END) == 0) partial_size = _ftelli64(output);
                    const DWORD remaining = size - total_written;
                    const DWORD amount = static_cast<DWORD>((std::min)(
                        static_cast<__int64>(remaining), (std::max)(partial_size, __int64{0})));
                    rewind(output);
                    total_written += static_cast<DWORD>(fread(buffer + total_written, 1, amount, output));
                    fclose(output);
                    result = ERROR_USER_CANCEL;
                    // 項目を出し終えた後の取消は原版どおり終端到達の system error を残す。
                    system_error = partial_size >= static_cast<__int64>(header.original_size)
                        ? ERROR_NO_MORE_FILES : ERROR_CANCELLED;
                    break;
                }
                if (decode_result != 0) {
                    fclose(output);
                    result = decode_result;
                    if (result == ERROR_HUFFMAN_CODE) system_error = ERROR_INVALID_DATA;
                    break;
                }
                const DWORD amount = static_cast<DWORD>((std::min)(
                    static_cast<ULHA_INT64>(size - total_written),
                    (std::max)(static_cast<ULHA_INT64>(0), static_cast<ULHA_INT64>(header.original_size))));
                rewind(output);
                total_written += static_cast<DWORD>(fread(buffer + total_written, 1, amount, output));
                g_memory_written = size - total_written;
                fclose(output);
                g_memory_timestamp = static_cast<time_t>(FileTimeToUnixTime32(
                    HeaderTimeToFileTime(header, MemberTimeKind::Write)));
                g_memory_attributes = static_cast<WORD>(HeaderAttributes(header));
                // 原版のメモリ出力後に残る値。後続ヘッダーの読取不足なら EOF に更新される。
                retained_system_error = ERROR_INVALID_PARAMETER;
                // メモリ展開 I はデータ CRC 不一致を失敗として扱わない。
            }
        }
        if (next_header > file_size || header.packed_size < 0) {
            result = ERROR_SET_POINT;
            system_error = 0;
            break;
        }
        if (_fseeki64(archive, next_header, SEEK_SET) != 0) {
            result = ERROR_CANNOT_READ;
            system_error = ERROR_SEEK;
            break;
        }
    }
    Lha_ClearProgressMember();
    Lha_SendProgressMessage(ARCEXTRACT_END, nullptr, 0, 0);
    fclose(archive);
    g_enum_command = 0;
    g_memory_extracting = false;
    g_running = false;
    // 本家は異常脱出時に「書き込み済み」への変換を経由せず、残り容量を返す。
    g_memory_written = result != 0 ? size - total_written : total_written;
    CopyMemoryResult(g_memory_written, timestamp, attributes, written);
    SetCompatError(result == ERROR_HUFFMAN_CODE ? 0 : (result != 0 ? result : retained_error), system_error);
    return result;
}

static int ExtractMemoryCommand(HWND hwnd, LPCWSTR command_line, LPBYTE buffer, const DWORD size,
                                 time_t* timestamp, LPWORD attributes, LPDWORD written,
                                 const bool wide_response) {
    SetCompatError(0);
    if (IsDllRunning()) {
        CopyMemoryResult(g_memory_written, timestamp, attributes, written);
        SetCompatError(ERROR_ALREADY_RUNNING, ERROR_BUSY);
        return ERROR_ALREADY_RUNNING;
    }
    const ScopedThreadPriority api_priority;
    g_memory_written = 0;
    CopyMemoryResult(0, timestamp, attributes, written);
    if (!command_line || !*command_line) return ERROR_NOT_FILENAME;
    if (!buffer || size == 0) return ERROR_INVALID_VALUE;
    const ScopedThreadPriority command_priority;
    MemoryExtractCommand command;
    const int parsed = ParseMemoryExtractCommand(command_line, wide_response, command);
    if (parsed != 0) return parsed;
    FILE* archive = nullptr;
    _wfopen_s(&archive, command.archive.c_str(), L"rb");
    if (!archive) {
        const size_t separator = command.archive.find_last_of(L"/\\");
        const size_t extension = command.archive.find_last_of(L'.');
        if (extension == std::wstring::npos || (separator != std::wstring::npos && extension < separator)) {
            const std::wstring with_extension = command.archive + L".lzh";
            _wfopen_s(&archive, with_extension.c_str(), L"rb");
        }
    }
    if (!archive) {
        const DWORD system_error = GetLastError();
        if (system_error == ERROR_FILE_NOT_FOUND || system_error == ERROR_PATH_NOT_FOUND) {
            SetCompatError(0, system_error);
            return ERROR_NOT_FIND_ARC_FILE;
        }
        SetCompatError(ERROR_ARC_FILE_OPEN, system_error);
        return ERROR_ARC_FILE_OPEN;
    }
    return ExtractMemFromStream(hwnd, archive, command, buffer, size, timestamp, attributes, written);
}

int WINAPI UnlhaExtractMemA(HWND hwnd, LPCSTR command_line, LPBYTE buffer, const DWORD size,
                            time_t* timestamp, LPWORD attributes, LPDWORD written) {
    const std::wstring command_w = command_line ? StringToWString(command_line) : std::wstring();
    return ExtractMemoryCommand(hwnd, command_w.c_str(), buffer, size, timestamp, attributes, written, false);
}

int WINAPI UnlhaExtractMemW(HWND hwnd, LPCWSTR command_line, LPBYTE buffer, const DWORD size,
                            time_t* timestamp, LPWORD attributes, LPDWORD written) {
    return ExtractMemoryCommand(hwnd, command_line, buffer, size, timestamp, attributes, written, true);
}

static bool CreateDirectoriesForFileW(const std::wstring& path);

static bool CreateDirectoriesForFile(const std::string& path) {
    if (g_unicode_mode.load()) return CreateDirectoriesForFileW(StringToWString(path));
    size_t cursor = path.find_first_of("\\/");
    while (cursor != std::string::npos) {
        if (cursor > 0 && path[cursor - 1] != ':') {
            const std::string directory = path.substr(0, cursor);
            if (!directory.empty() && !CreateDirectoryA(directory.c_str(), NULL) &&
                GetLastError() != ERROR_ALREADY_EXISTS) return false;
        }
        cursor = path.find_first_of("\\/", cursor + 1);
    }
    return true;
}

static void RemoveTemporaryTreeW(const std::wstring& directory) {
    WIN32_FIND_DATAW item{};
    HANDLE find = FindFirstFileW((directory + L"\\*").c_str(), &item);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(item.cFileName, L".") == 0 || wcscmp(item.cFileName, L"..") == 0) continue;
            const std::wstring path = directory + L"\\" + item.cFileName;
            if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                RemoveTemporaryTreeW(path);
            } else {
                SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(path.c_str());
            }
        } while (FindNextFileW(find, &item));
        FindClose(find);
    }
    RemoveDirectoryW(directory.c_str());
}

static void RemoveTemporaryTree(const std::string& directory) {
    // 呼び出し元の GetTempFileNameA が返すパスは API 入力とは別の ACP。
    RemoveTemporaryTreeW(MultiByteStringToWide(directory, CP_ACP));
}

struct WideCommandParts final {
    char command = 'l';
    std::vector<std::wstring> switches;
    std::vector<std::wstring> operands;
    bool preserve_directories = false;
    bool directory_mode_specified = false;
    bool force = false;
    bool reject_foreign_data = true;
    bool names_only = false;
    int sfx_mode = 0;
    std::wstring rename_target;
};

static bool ParseWideCommand(const wchar_t* command_line, WideCommandParts& result) {
    if (!command_line) return false;
    const std::vector<std::wstring> arguments = TokenizeCommandLineW(command_line);
    bool command_seen = false;
    for (const std::wstring& value : arguments) {
        if (value.empty()) continue;
        if (value[0] == L'-' || value[0] == L'/') {
            result.switches.push_back(value);
            std::wstring option = value.substr(1);
            std::transform(option.begin(), option.end(), option.begin(), towlower);
            if (option == L"x" || option == L"x1" || option == L"d" || option == L"d1") {
                result.preserve_directories = true;
                result.directory_mode_specified = true;
            } else if (option == L"x0" || option == L"d0") {
                result.preserve_directories = false;
                result.directory_mode_specified = true;
            }
            if (!option.empty() && option[0] == L'y') result.force = true;
            if (option.rfind(L"gw", 0) == 0) {
                if (option.size() == 2) {
                    result.sfx_mode = 1;
                } else if (option.size() == 3 && option[2] >= L'0' &&
                           option[2] <= L'4') {
                    result.sfx_mode = option[2] - L'0';
                } else {
                    return false;
                }
            } else if (option.rfind(L"gr", 0) == 0) {
                result.rename_target = value.substr(3);
            }
            continue;
        }
        if (!command_seen && value.size() == 1 && iswalpha(value[0])) {
            result.command = static_cast<char>(towlower(value[0]));
            command_seen = true;
            continue;
        }
        command_seen = true;
        result.operands.push_back(value);
    }
    std::vector<ParsedCommandArgument<std::wstring>> parsed_switches;
    for (const auto& option : result.switches) {
        for (const auto& part : SplitCompatibleSwitches(WideStringToUtf8(option)))
            parsed_switches.push_back({MultiByteStringToWide(part, CP_UTF8), true, false});
    }
    for (const auto& argument : parsed_switches) {
        std::string option = WideStringToUtf8(argument.value.substr(1));
        std::transform(option.begin(), option.end(), option.begin(), LowerCharacter);
        if (option.rfind("jsg", 0) == 0)
            result.reject_foreign_data = CommandSwitchValue(option, 3, result.reject_foreign_data, 1) != 0;
        else if (!option.empty() && option[0] == 'n')
            result.names_only = CommandSwitchValue(option, 1, result.names_only, 2) != 0;
    }
    std::wstring configured_directory;
    std::vector<std::string> defaults;
    GetConfiguredCommandDefaults(UseCommandRegistry(parsed_switches), configured_directory, defaults);
    std::vector<std::wstring> default_switches;
    for (const auto& option : defaults) {
        default_switches.push_back(MultiByteStringToWide(option, CP_UTF8));
        if (option == "-x0" && (!result.directory_mode_specified || result.command == 'x')) {
            result.directory_mode_specified = true;
            result.preserve_directories = false;
        }
    }
    result.switches.insert(result.switches.begin(), default_switches.begin(), default_switches.end());
    if (!configured_directory.empty() && !result.operands.empty()) {
        const wchar_t last = result.operands.size() > 1 && !result.operands[1].empty()
            ? result.operands[1].back() : L'\0';
        if (last != L'/' && last != L'\\' && last != L':') {
            if (configured_directory.back() != L'/' && configured_directory.back() != L'\\')
                configured_directory += L'\\';
            result.operands.insert(result.operands.begin() + 1, configured_directory);
        }
    }
    return !result.operands.empty();
}

static char ParsedWideCommandCharacter(const wchar_t* command_line) {
    WideCommandParts command;
    return ParseWideCommand(command_line, command) ? command.command : '\0';
}

static bool IsWideAbsolutePath(const std::wstring& path) {
    return (path.size() >= 2 && path[1] == L':') ||
           (path.size() >= 2 && path[0] == L'\\' && path[1] == L'\\') ||
           (!path.empty() && path[0] == L'/');
}

static std::string QuoteAnsiArgument(const std::string& value) {
    std::string quoted = "\"";
    for (const char character : value) {
        if (character == '\"') quoted += '\\';
        quoted += character;
    }
    quoted += '\"';
    return quoted;
}

static int ExecuteWideUnicodeAdd(HWND hwnd, const WideCommandParts& command,
                                 LPWSTR output, const DWORD output_size) {
    if (command.operands.size() < 2) return WIDE_COMMAND_NOT_HANDLED;

    wchar_t full_archive[MAX_PATH * 4]{};
    const DWORD archive_length = GetFullPathNameW(
        command.operands[0].c_str(), static_cast<DWORD>(_countof(full_archive)),
        full_archive, nullptr);
    if (archive_length == 0 || archive_length >= _countof(full_archive)) {
        SetCompatError(ERROR_INVALID_PATH, GetLastError());
        return ERROR_INVALID_PATH;
    }

    size_t source_index = 1;
    std::wstring source_base;
    if (command.operands.size() >= 3) {
        const std::wstring& possible_base = command.operands[1];
        if (!possible_base.empty() &&
            (possible_base.back() == L'\\' || possible_base.back() == L'/' ||
             possible_base.back() == L':')) {
            source_base = possible_base;
            source_index = 2;
        }
    }
    if (source_index >= command.operands.size()) return WIDE_COMMAND_NOT_HANDLED;

    char temp_path[MAX_PATH]{};
    char temp_directory[MAX_PATH]{};
    char temp_archive[MAX_PATH]{};
    if (!GetTempPathA(_countof(temp_path), temp_path) ||
        !GetTempFileNameA(temp_path, "UWA", 0, temp_directory)) {
        SetCompatError(ERROR_TMP_OPEN, GetLastError());
        return ERROR_TMP_OPEN;
    }
    DeleteFileA(temp_directory);
    if (!CreateDirectoryA(temp_directory, nullptr) ||
        !GetTempFileNameA(temp_path, "UWX", 0, temp_archive)) {
        const DWORD system_error = GetLastError();
        RemoveTemporaryTree(temp_directory);
        SetCompatError(ERROR_TMP_OPEN, system_error);
        return ERROR_TMP_OPEN;
    }

    const std::wstring temp_archive_w = StringToWString(temp_archive);
    const bool destination_exists =
        GetFileAttributesW(full_archive) != INVALID_FILE_ATTRIBUTES;
    if (destination_exists) {
        if (!CopyFileW(full_archive, temp_archive_w.c_str(), FALSE)) {
            const DWORD system_error = GetLastError();
            DeleteFileA(temp_archive);
            RemoveTemporaryTree(temp_directory);
            SetCompatError(ERROR_ARC_FILE_OPEN, system_error);
            return ERROR_ARC_FILE_OPEN;
        }
    } else {
        DeleteFileA(temp_archive);
    }

    std::vector<std::string> aliases;
    g_forced_header_names.clear();
    bool prepared = true;
    for (size_t index = source_index; index < command.operands.size(); ++index) {
        const std::wstring& requested = command.operands[index];
        if (requested.find_first_of(L"*?") != std::wstring::npos) {
            prepared = false;
            break;
        }
        std::wstring source = requested;
        if (!source_base.empty() && !IsWideAbsolutePath(source)) source = source_base + source;
        wchar_t full_source[MAX_PATH * 4]{};
        const DWORD source_length = GetFullPathNameW(
            source.c_str(), static_cast<DWORD>(_countof(full_source)), full_source,
            nullptr);
        const DWORD source_attributes = source_length > 0 && source_length < _countof(full_source)
            ? GetFileAttributesW(full_source) : INVALID_FILE_ATTRIBUTES;
        if (source_attributes == INVALID_FILE_ATTRIBUTES ||
            (source_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            prepared = false;
            break;
        }

        char alias[32]{};
        _snprintf_s(alias, _TRUNCATE, "F%08u.BIN",
                    static_cast<unsigned int>(aliases.size()));
        const std::wstring alias_path = StringToWString(temp_directory) + L"\\" +
                                        StringToWString(alias);
        if (!CopyFileW(full_source, alias_path.c_str(), TRUE)) {
            prepared = false;
            break;
        }
        aliases.emplace_back(alias);

        std::wstring stored_name = requested;
        std::replace(stored_name.begin(), stored_name.end(), L'\\', L'/');
        while (stored_name.rfind(L"./", 0) == 0) stored_name.erase(0, 2);
        if (!command.preserve_directories) {
            const size_t separator = stored_name.find_last_of(L'/');
            if (separator != std::wstring::npos) stored_name.erase(0, separator + 1);
        }
        g_forced_header_names.push_back({alias, stored_name});
    }

    int result = ERROR_NOT_FILENAME;
    if (prepared && !aliases.empty()) {
        std::string ansi_command(1, command.command);
        for (const std::wstring& item : command.switches) {
            bool used_default = false;
            const std::string converted = WideStringToMultiByte(
                item, ActiveCodePage(), &used_default);
            if (used_default) {
                prepared = false;
                break;
            }
            ansi_command += " " + converted;
        }
        if (prepared) {
            ansi_command += " " + QuoteAnsiArgument(temp_archive);
            ansi_command += " " + QuoteAnsiArgument(std::string(temp_directory) + "\\");
            for (const std::string& alias : aliases) {
                ansi_command += " " + QuoteAnsiArgument(alias);
            }
            std::vector<char> ansi_output(output && output_size > 0
                ? (std::max)(static_cast<size_t>(output_size) * 4U,
                             static_cast<size_t>(4096U)) : 1U, 0);
            result = Unlha(hwnd, ansi_command.c_str(),
                           output && output_size > 0 ? ansi_output.data() : nullptr,
                           output && output_size > 0
                               ? static_cast<DWORD>(ansi_output.size()) : 0);
            if (output && output_size > 0) {
                const std::wstring converted_output =
                    StringToWString(ansi_output.data());
                wcsncpy_s(output, output_size, converted_output.c_str(), _TRUNCATE);
            }
        }
    }
    g_forced_header_names.clear();

    if (result == 0) {
        if (GetFileAttributesA(temp_archive) == INVALID_FILE_ATTRIBUTES ||
            !MoveFileExW(temp_archive_w.c_str(), full_archive,
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            const DWORD system_error = GetLastError();
            result = ERROR_CANNOT_WRITE;
            SetCompatError(result, system_error);
        }
    }
    if (GetFileAttributesA(temp_archive) != INVALID_FILE_ATTRIBUTES) {
        DeleteFileA(temp_archive);
    }
    RemoveTemporaryTree(temp_directory);
    return result;
}

static bool CreateDirectoriesForFileW(const std::wstring& path) {
    size_t cursor = path.find_first_of(L"\\/");
    while (cursor != std::wstring::npos) {
        if (cursor > 0 && path[cursor - 1] != L':') {
            const std::wstring directory = path.substr(0, cursor);
            if (!directory.empty() &&
                !CreateDirectoryW(directory.c_str(), nullptr) &&
                GetLastError() != ERROR_ALREADY_EXISTS) {
                return false;
            }
        }
        cursor = path.find_first_of(L"\\/", cursor + 1);
    }
    return true;
}

static int ExecuteWideUnicodeCommand(HWND hwnd, LPCWSTR command_line,
                                     LPWSTR output, const DWORD output_size) {
    WideCommandParts command;
    if (!ParseWideCommand(command_line, command)) return WIDE_COMMAND_NOT_HANDLED;
    if (command.command == 'x' || command.command == 'e') {
        // 入力パスだけ UTF-8 で共通処理へ運び、公開 UnicodeMode と保存 CP は保持する。
        // 内側の W 呼び出しは全入力を表現できるため、ここへ再分岐しない。
        const WideCommandUtf8InputScope utf8_input_scope;
        g_wide_command_utf8_input = true;
        return UnlhaW(hwnd, command_line, output, output_size);
    }
    if (command.reject_foreign_data) {
        std::vector<std::wstring> paths{command.operands[0]};
        const size_t extension = paths[0].find_last_of(L'.');
        const size_t separator = paths[0].find_last_of(L"/\\");
        if (extension == std::wstring::npos || (separator != std::wstring::npos && extension < separator))
            paths.push_back(paths[0] + L".lzh");
        for (const auto& path : paths) {
            FILE* archive = nullptr;
            if (_wfopen_s(&archive, path.c_str(), L"rb") != 0 || !archive) continue;
            const bool foreign_tail = ArchiveStreamHasForeignTail(archive);
            fclose(archive);
            if (!foreign_tail) break;
            wchar_t full_path[FILENAME_LENGTH * 4]{};
            const DWORD length = GetFullPathNameW(path.c_str(), _countof(full_path), full_path, nullptr);
            std::wstring resolved = length > 0 && length < _countof(full_path) ? full_path : path;
            wchar_t canonical[FILENAME_LENGTH * 4]{};
            const DWORD canonical_length = GetLongPathNameW(resolved.c_str(), canonical, _countof(canonical));
            if (canonical_length > 0 && canonical_length < _countof(canonical)) resolved = canonical;
            std::replace(resolved.begin(), resolved.end(), L'\\', L'/');
            const std::wstring message = MultiByteStringToWide(BuildForeignArchiveCommandOutput(
                command.command, WideStringToUtf8(resolved), command.names_only, CP_UTF8), CP_UTF8);
            if (output && output_size > 0) wcsncpy_s(output, output_size, message.c_str(), _TRUNCATE);
            SetCompatError(ERROR_FILE_STYLE, ForeignArchiveCommandSystemError(command.command));
            SetLastError(ERROR_SUCCESS);
            return ERROR_FILE_STYLE;
        }
    }
    if (command.command == 's') {
        const bool was_running = g_running;
        if (!was_running) {
            g_hwndOwner = hwnd;
            g_running = true;
        }
        g_last_error.clear();
        if (output && output_size > 0) output[0] = L'\0';
        const std::wstring destination = command.operands.size() >= 2
            ? command.operands[1] : std::wstring();
        const int sfx_type = command.sfx_mode == 0 ? SFX_DOS_260S
            : (command.sfx_mode >= 3 ? SFX_WIN32_213_3 : SFX_WIN32_300_1);
        const int result = ExecuteSfxCommandW(
            command.operands[0], destination, command.rename_target,
            sfx_type, command.force);
        if (output && output_size > 0 && !g_last_error.empty()) {
            wcsncpy_s(output, output_size, g_last_error.c_str(), _TRUNCATE);
        }
        if (!was_running) g_running = false;
        g_last_error_code = result;
        return result;
    }
    if (command.command == 'a' || command.command == 'c' ||
        command.command == 'u' || command.command == 'f') {
        const int result = ExecuteWideUnicodeAdd(hwnd, command, output, output_size);
        g_last_error_code = result;
        return result;
    }
    return WIDE_COMMAND_NOT_HANDLED;
}

extern "C++" {
static std::string MemoryCompressionMethodSwitches(const std::string& command_line) {
    std::string result;
    for (const auto& token : TokenizeCommandLine(command_line)) {
        if (token.empty() || (token[0] != '-' && token[0] != '/')) continue;
        for (const auto& part : SplitCompatibleSwitches(token)) {
            std::string option = part.substr(1);
            std::transform(option.begin(), option.end(), option.begin(), LowerCharacter);
            if (option.rfind("jm", 0) == 0 || (!option.empty() && option[0] == 'e'))
                result += " -" + option;
        }
    }
    return result;
}
}

int WINAPI UnlhaCompressMemA(HWND hwnd, LPCSTR command_line, const LPBYTE buffer, const DWORD size,
                             const time_t* timestamp, const LPWORD attributes, LPDWORD written) {
    g_memory_timestamp = timestamp ? *timestamp : time(nullptr);
    g_memory_attributes = attributes ? *attributes : FILE_ATTRIBUTE_ARCHIVE;
    if (IsDllRunning()) {
        if (written) *written = g_last_packed_size;
        return RecordBusyError();
    }
    std::string archive_path;
    std::string member;
    if (!buffer || !ParseMemoryCommand(command_line, archive_path, member) || member.empty() ||
        member.find("..") != std::string::npos || (!member.empty() && (member[0] == '/' || member[0] == '\\'))) {
        SetCompatError(ERROR_NOT_FILENAME, ERROR_INVALID_PARAMETER);
        return ERROR_NOT_FILENAME;
    }
    wchar_t full_archive_w[MAX_PATH * 4]{};
    const DWORD full_length = GetFullPathNameW(StringToWString(archive_path).c_str(),
        static_cast<DWORD>(_countof(full_archive_w)), full_archive_w, nullptr);
    if (full_length == 0 || full_length >= _countof(full_archive_w)) {
        SetCompatError(ERROR_INVALID_PATH, GetLastError());
        return ERROR_INVALID_PATH;
    }
    const std::string full_archive = WStringToString(full_archive_w);
    wchar_t temp_path[MAX_PATH]{};
    wchar_t temp_name[MAX_PATH]{};
    const DWORD temp_length = GetTempPathW(_countof(temp_path), temp_path);
    if (!temp_length || temp_length >= _countof(temp_path) ||
        !GetTempFileNameW(temp_path, L"ULR", 0, temp_name)) {
        SetCompatError(ERROR_TMP_OPEN, GetLastError());
        return ERROR_TMP_OPEN;
    }
    DeleteFileW(temp_name);
    if (!CreateDirectoryW(temp_name, NULL)) {
        SetCompatError(ERROR_MAKEDIRECTORY, GetLastError());
        return ERROR_MAKEDIRECTORY;
    }
    std::replace(member.begin(), member.end(), '/', '\\');
    const std::string input_path = WStringToString(temp_name) + "\\" + member;
    if (!CreateDirectoriesForFile(input_path)) {
        RemoveTemporaryTreeW(temp_name);
        SetCompatError(ERROR_MAKEDIRECTORY, GetLastError());
        return ERROR_MAKEDIRECTORY;
    }
    FILE* input = Lha_OpenFile(input_path.c_str(), "wb");
    if (!input) {
        RemoveTemporaryTreeW(temp_name);
        SetCompatError(ERROR_CANNOT_WRITE, GetLastError());
        return ERROR_CANNOT_WRITE;
    }
    const size_t stored = fwrite(buffer, 1, size, input);
    fclose(input);
    if (stored != size) {
        RemoveTemporaryTreeW(temp_name);
        SetCompatError(ERROR_CANNOT_WRITE, ERROR_WRITE_FAULT);
        return ERROR_CANNOT_WRITE;
    }
    if (timestamp) win32_set_file_time(input_path.c_str(), *timestamp, nullptr);
    if (attributes) {
        if (g_unicode_mode.load()) SetFileAttributesW(StringToWString(input_path).c_str(), *attributes);
        else SetFileAttributesA(input_path.c_str(), *attributes);
    }

    std::string base = WStringToString(temp_name);
    base += "\\";
    const std::string command = "a -y -jm2" + MemoryCompressionMethodSwitches(command_line) +
        " \"" + full_archive + "\" \"" + base + "\" \"" + member + "\"";
    const int result = Unlha(hwnd, command.c_str(), NULL, 0);
    if (result == 0 && written) {
        *written = 0;
        HARC archive = UnlhaOpenArchive(NULL, full_archive.c_str(), M_REGARDLESS_INIT_FILE);
        if (archive) {
            INDIVIDUALINFOA info{};
            std::replace(member.begin(), member.end(), '\\', '/');
            if (UnlhaFindFirst(archive, member.c_str(), &info) == 0) *written = info.dwCompressedSize;
            UnlhaCloseArchive(archive);
        }
    }
    RemoveTemporaryTreeW(temp_name);
    SetCompatError(result, result == 0 ? ERROR_SUCCESS : GetLastError());
    return result;
}

int WINAPI UnlhaCompressMemW(HWND hwnd, LPCWSTR command_line, const LPBYTE buffer, const DWORD size,
                             const time_t* timestamp, const LPWORD attributes, LPDWORD written) {
    g_memory_timestamp = timestamp ? *timestamp : time(nullptr);
    g_memory_attributes = attributes ? *attributes : FILE_ATTRIBUTE_ARCHIVE;
    if (IsDllRunning()) {
        if (written) *written = g_last_packed_size;
        return RecordBusyError();
    }
    std::wstring archive_path;
    std::wstring member;
    bool preserve_directories = false;
    if (!buffer || !ParseMemoryCommandW(command_line, archive_path, member,
                                        preserve_directories) || member.empty() ||
        member.find(L"..") != std::wstring::npos ||
        (!member.empty() && (member[0] == L'/' || member[0] == L'\\'))) {
        SetCompatError(ERROR_NOT_FILENAME, ERROR_INVALID_PARAMETER);
        return ERROR_NOT_FILENAME;
    }

    wchar_t full_archive[MAX_PATH * 4]{};
    const DWORD full_length = GetFullPathNameW(archive_path.c_str(),
                                               static_cast<DWORD>(_countof(full_archive)),
                                               full_archive, nullptr);
    if (full_length == 0 || full_length >= _countof(full_archive)) {
        SetCompatError(ERROR_INVALID_PATH, GetLastError());
        return ERROR_INVALID_PATH;
    }

    wchar_t temp_path[MAX_PATH]{};
    wchar_t temp_archive[MAX_PATH]{};
    const DWORD temp_length = GetTempPathW(_countof(temp_path), temp_path);
    if (!temp_length || temp_length >= _countof(temp_path) ||
        !GetTempFileNameW(temp_path, L"ULW", 0, temp_archive)) {
        SetCompatError(ERROR_TMP_OPEN, GetLastError());
        return ERROR_TMP_OPEN;
    }
    const std::wstring temp_archive_w(temp_archive);
    const bool destination_exists =
        GetFileAttributesW(full_archive) != INVALID_FILE_ATTRIBUTES;
    if (destination_exists &&
        !CopyFileW(full_archive, temp_archive_w.c_str(), FALSE)) {
        const DWORD system_error = GetLastError();
        DeleteFileW(temp_archive);
        SetCompatError(ERROR_ARC_FILE_OPEN, system_error);
        return ERROR_ARC_FILE_OPEN;
    }
    if (!destination_exists) DeleteFileW(temp_archive);

    char placeholder_buffer[64]{};
    _snprintf_s(placeholder_buffer, _TRUNCATE, "__ulhare_mem_%08lX.bin",
                static_cast<unsigned long>(GetTickCount()));
    const std::string placeholder = placeholder_buffer;
    const std::string memory_command = MemoryCompressionMethodSwitches(WStringToString(command_line)) +
                                       " \"" + WStringToString(temp_archive_w) + "\" \"" +
                                       placeholder + "\"";
    std::wstring header_member = member;
    if (!preserve_directories) {
        const size_t separator = header_member.find_last_of(L"/\\");
        if (separator != std::wstring::npos) header_member.erase(0, separator + 1);
    }
    g_forced_header_names.clear();
    g_forced_header_names.push_back({placeholder, header_member});
    const int result = UnlhaCompressMemA(hwnd, memory_command.c_str(), buffer, size,
                                         timestamp, attributes, nullptr);
    g_forced_header_names.clear();

    if (result != 0) {
        DeleteFileW(temp_archive);
        return result;
    }
    DWORD compressed_size = 0;
    if (written) {
        FILE* archive = nullptr;
        if (_wfopen_s(&archive, temp_archive, L"rb") == 0 && archive) {
            LzHeader header{};
            while (get_header(archive, &header)) {
                if (HeaderNameToWString(header, ConfiguredArchiveCodePage()) == header_member) {
                    compressed_size = static_cast<DWORD>(header.packed_size);
                    break;
                }
                if (fseeko(archive, header.packed_size, SEEK_CUR) != 0) break;
            }
            fclose(archive);
        }
    }
    if (GetFileAttributesW(temp_archive) == INVALID_FILE_ATTRIBUTES ||
        !MoveFileExW(temp_archive_w.c_str(), full_archive,
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const DWORD system_error = GetLastError();
        DeleteFileW(temp_archive);
        SetCompatError(ERROR_CANNOT_WRITE, system_error);
        return ERROR_CANNOT_WRITE;
    }
    if (written) *written = compressed_size;
    SetCompatError(0);
    return 0;
}

INT_PTR CALLBACK UnlhaDialogProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_INITDIALOG: {
        auto* state = reinterpret_cast<ConfigDialogState*>(lparam);
        SetWindowLongPtrW(dialog, DWLP_USER, reinterpret_cast<LONG_PTR>(state));
        if (!state) return FALSE;
        LocalizeConfigDialog(dialog);
        InitializeMainConfigControls(dialog, *state);
        return TRUE;
    }
    case WM_COMMAND: {
        ConfigDialogState* state = DialogConfigState(dialog);
        if (!state) return FALSE;
        switch (LOWORD(wparam)) {
        case IDC_CONFIG_LOCAL: {
            ReadMainConfigControls(dialog, *state);
            ConfigDialogState localState = *state;
            if (DialogBoxParamW(g_hModule, MAKEINTRESOURCEW(IDD_UNLHA_LOCAL_CONFIG), dialog,
                                UnlhaLocalDlgProc,
                                reinterpret_cast<LPARAM>(&localState)) == IDOK) {
                state->makeDirectoryMode = localState.makeDirectoryMode;
                state->diskSpaceCheck = localState.diskSpaceCheck;
                state->totalBar = localState.totalBar;
                state->miniDialog = localState.miniDialog;
                state->flushBuffer = localState.flushBuffer;
                state->useOldLog = localState.useOldLog;
                state->causeOldGf = localState.causeOldGf;
                state->useMappedFile = localState.useMappedFile;
            }
            return TRUE;
        }
        case IDC_CONFIG_SAVE:
            ReadMainConfigControls(dialog, *state);
            g_config_state = *state;
            g_config_state_initialized = true;
            if (!SaveConfigRegistry(*state)) {
                SetCompatError(ERROR_CANNOT_WRITE, GetLastError());
                MessageBeep(MB_ICONERROR);
            } else {
                SetCompatError(0);
            }
            return TRUE;
        case IDOK:
            ReadMainConfigControls(dialog, *state);
            EndDialog(dialog, IDOK);
            return TRUE;
        case IDCANCEL:
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        default:
            break;
        }
        break;
    }
    case WM_CLOSE:
        EndDialog(dialog, IDCANCEL);
        return TRUE;
    default:
        break;
    }
    return FALSE;
}

INT_PTR CALLBACK UnlhaLocalDlgProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_INITDIALOG: {
        auto* state = reinterpret_cast<ConfigDialogState*>(lparam);
        SetWindowLongPtrW(dialog, DWLP_USER, reinterpret_cast<LONG_PTR>(state));
        if (!state) return FALSE;
        LocalizeLocalConfigDialog(dialog);
        InitializeLocalConfigControls(dialog, *state);
        return TRUE;
    }
    case WM_COMMAND: {
        ConfigDialogState* state = DialogConfigState(dialog);
        if (!state) return FALSE;
        if (LOWORD(wparam) == IDOK) {
            ReadLocalConfigControls(dialog, *state);
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        if (LOWORD(wparam) == IDCANCEL) {
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        }
        break;
    }
    case WM_CLOSE:
        EndDialog(dialog, IDCANCEL);
        return TRUE;
    default:
        break;
    }
    return FALSE;
}
INT_PTR CALLBACK UnlhaPrtBarDlgProc(HWND, UINT, WPARAM, LPARAM) { return FALSE; }
LRESULT CALLBACK UnlhaBarWindProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
}
INT_PTR CALLBACK GetWinSFXParamDlgProc(HWND, UINT, WPARAM, LPARAM) { return FALSE; }
INT_PTR CALLBACK GetFileNameDlgProc(HWND, UINT, WPARAM, LPARAM) { return FALSE; }
INT_PTR CALLBACK GetCommentDlgProc(HWND, UINT, WPARAM, LPARAM) { return FALSE; }
INT_PTR CALLBACK OverWriteMsgDlgProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    return HandleFileQuestionDialog(dialog, message, wparam, lparam, CommandFileQuestion::Overwrite);
}
INT_PTR CALLBACK MakeDirMsgDlgProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    return HandleFileQuestionDialog(dialog, message, wparam, lparam, CommandFileQuestion::Directory);
}
INT_PTR CALLBACK OWReadOnlyMsgDlgProc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
    return HandleFileQuestionDialog(dialog, message, wparam, lparam, CommandFileQuestion::ReadOnly);
}

} // extern "C"
