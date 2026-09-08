#include <windows.h>
#include <commdlg.h>
#include <psapi.h>
#include <intrin.h>
#include "UNLHA32.H"
#include "UNLHA64EX.H"
#include "isolated_desktop.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

template <typename T>
T proc(HMODULE module, const char* name) {
    auto address = GetProcAddress(module, name);
    if (!address) {
        throw std::runtime_error(std::string("missing export: ") + name);
    }
    return reinterpret_cast<T>(address);
}

template <typename T>
T optional_proc(HMODULE module, const char* name) {
    return reinterpret_cast<T>(GetProcAddress(module, name));
}

std::string quote_bytes(const char* value) {
    std::ostringstream out;
    out << '"';
    if (value) {
        for (const unsigned char c : std::string(value)) {
            if (c == '\\' || c == '"') {
                out << '\\' << static_cast<char>(c);
            } else if (c >= 0x20 && c < 0x7f) {
                out << static_cast<char>(c);
            } else {
                char buffer[5]{};
                std::snprintf(buffer, sizeof(buffer), "\\x%02X", c);
                out << buffer;
            }
        }
    }
    out << '"';
    return out.str();
}

std::string quote_wide(const wchar_t* value) {
    std::ostringstream out;
    out << '"';
    if (value) {
        for (const wchar_t c : std::wstring(value)) {
            if (c == L'\\' || c == L'"') {
                out << '\\' << static_cast<char>(c);
            } else if (c >= 0x20 && c < 0x7f) {
                out << static_cast<char>(c);
            } else {
                char buffer[7]{};
                std::snprintf(buffer, sizeof(buffer), "\\u%04X", static_cast<unsigned int>(c));
                out << buffer;
            }
        }
    }
    out << '"';
    return out.str();
}

struct Module final {
    explicit Module(const wchar_t* path) : handle(LoadLibraryW(path)) {
        if (!handle) {
            throw std::runtime_error("LoadLibraryW failed: " + std::to_string(GetLastError()));
        }
    }
    ~Module() { FreeLibrary(handle); }
    Module(const Module&) = delete;
    Module& operator=(const Module&) = delete;
    HMODULE handle;
};

// DLL のロード前に HKCU を専用の一時キーへ切り替え、利用者の設定を触らない。
class RegistrySandbox final {
public:
    explicit RegistrySandbox(const wchar_t* settings, const bool dump = false) : dump_(dump) {
        FILETIME now{};
        GetSystemTimeAsFileTime(&now);
        name_ = L"UnLhaRe-RegistryTest-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                std::to_wstring(now.dwHighDateTime) + L"-" + std::to_wstring(now.dwLowDateTime);
        LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software", 0,
                                       KEY_ALL_ACCESS, &parent_);
        if (status != ERROR_SUCCESS) throw std::runtime_error("cannot open registry sandbox parent");
        DWORD disposition = 0;
        status = RegCreateKeyExW(parent_, name_.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
                                 KEY_ALL_ACCESS, nullptr, &root_, &disposition);
        if (status != ERROR_SUCCESS || disposition != REG_CREATED_NEW_KEY) {
            if (root_) RegCloseKey(root_);
            RegCloseKey(parent_);
            throw std::runtime_error("cannot create a new registry sandbox");
        }
        try {
            seed(settings);
            status = RegOverridePredefKey(HKEY_CURRENT_USER, root_);
            if (status != ERROR_SUCCESS) throw std::runtime_error("cannot isolate HKCU");
            overridden_ = true;
        } catch (...) {
            cleanup();
            throw;
        }
    }
    ~RegistrySandbox() {
        if (dump_) dump();
        cleanup();
    }
    RegistrySandbox(const RegistrySandbox&) = delete;
    RegistrySandbox& operator=(const RegistrySandbox&) = delete;

    void seed(const std::wstring& settings) {
        size_t begin = 0;
        while (begin < settings.size()) {
            const size_t end = settings.find(L';', begin);
            const std::wstring item = settings.substr(begin, end - begin);
            const size_t equals = item.find(L'=');
            if (item.size() < 4 || item[1] != L':' || equals == std::wstring::npos || equals < 3 ||
                (item[0] != L'C' && item[0] != L'L')) {
                throw std::runtime_error("invalid registry seed; use C:Name=number or L:Name@=string");
            }
            std::wstring name = item.substr(2, equals - 2);
            const std::wstring value = item.substr(equals + 1);
            const bool string_value = name.back() == L'@';
            if (string_value) name.pop_back();
            HKEY key = nullptr;
            const std::wstring path = std::wstring(L"Software\\ArchiverDll\\") +
                                      (item[0] == L'C' ? L"Common" : L"UNLHA32");
            if (RegCreateKeyExW(root_, path.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
                                KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
                throw std::runtime_error("cannot create registry seed key");
            }
            LSTATUS status = ERROR_SUCCESS;
            if (string_value) {
                status = RegSetValueExW(key, name.c_str(), 0, REG_SZ,
                    reinterpret_cast<const BYTE*>(value.c_str()),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
            } else {
                wchar_t* tail = nullptr;
                const unsigned long long number = std::wcstoull(value.c_str(), &tail, 0);
                if (tail == value.c_str() || *tail || number > MAXDWORD) {
                    RegCloseKey(key);
                    throw std::runtime_error("invalid DWORD registry seed");
                }
                const DWORD number32 = static_cast<DWORD>(number);
                status = RegSetValueExW(key, name.c_str(), 0, REG_DWORD,
                    reinterpret_cast<const BYTE*>(&number32), sizeof(number32));
            }
            RegCloseKey(key);
            if (status != ERROR_SUCCESS) throw std::runtime_error("cannot write registry seed");
            if (end == std::wstring::npos) break;
            begin = end + 1;
        }
    }

private:
    void dump() const {
        std::vector<std::string> lines;
        for (const auto section : {L"Common", L"UNLHA32"}) {
            HKEY key = nullptr;
            const std::wstring path = std::wstring(L"Software\\ArchiverDll\\") + section;
            if (RegOpenKeyExW(root_, path.c_str(), 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) continue;
            for (DWORD index = 0;; ++index) {
                wchar_t name[256]{};
                DWORD name_size = _countof(name), type = 0, data_size = 4096;
                BYTE data[4096]{};
                const LSTATUS status = RegEnumValueW(key, index, name, &name_size, nullptr,
                                                     &type, data, &data_size);
                if (status == ERROR_NO_MORE_ITEMS) break;
                if (status != ERROR_SUCCESS) {
                    RegCloseKey(key);
                    std::cerr << "registry enumeration failed: " << status << '\n';
                    return;
                }
                std::ostringstream line;
                line << "registry." << quote_wide(section) << '.' << quote_wide(name)
                     << ".type=" << type << ",bytes=" << data_size << ",value=";
                if (type == REG_DWORD && data_size == sizeof(DWORD)) {
                    DWORD value = 0;
                    std::memcpy(&value, data, sizeof(value));
                    line << value;
                } else if (type == REG_SZ && data_size < sizeof(data)) {
                    line << quote_wide(reinterpret_cast<const wchar_t*>(data));
                } else line << "unformatted";
                lines.push_back(line.str());
            }
            RegCloseKey(key);
        }
        std::sort(lines.begin(), lines.end());
        for (const auto& line : lines) std::cout << line << '\n';
    }
    void cleanup() noexcept {
        if (overridden_) {
            const LSTATUS status = RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
            if (status != ERROR_SUCCESS) std::cerr << "registry restore failed: " << status << '\n';
            overridden_ = false;
        }
        // 作成済みと確認した専用キーだけを、切替前の親ハンドルから削除する。
        if (root_) {
            const LSTATUS status = RegDeleteTreeW(root_, nullptr);
            if (status != ERROR_SUCCESS) std::cerr << "registry sandbox cleanup failed: " << status << '\n';
            RegCloseKey(root_);
            root_ = nullptr;
            const LSTATUS deleted = RegDeleteKeyW(parent_, name_.c_str());
            if (deleted != ERROR_SUCCESS) std::cerr << "registry sandbox deletion failed: " << deleted << '\n';
        }
        if (parent_) RegCloseKey(parent_);
        parent_ = nullptr;
    }
    HKEY parent_ = nullptr;
    HKEY root_ = nullptr;
    std::wstring name_;
    bool overridden_ = false;
    bool dump_ = false;
};

using FnWord0 = WORD(WINAPI*)();
using FnBool0 = BOOL(WINAPI*)();
using FnBoolBool = BOOL(WINAPI*)(BOOL);
using FnWordWord = BOOL(WINAPI*)(WORD);
using FnIntInt = BOOL(WINAPI*)(int);
using FnUInt0 = UINT(WINAPI*)();
using FnBoolUInt = BOOL(WINAPI*)(UINT);
using FnCheck = BOOL(WINAPI*)(LPCSTR, int);
using FnCheckW = BOOL(WINAPI*)(LPCWSTR, int);
using FnCount = int(WINAPI*)(LPCSTR);
using FnCountW = int(WINAPI*)(LPCWSTR);
using FnOpen = HARC(WINAPI*)(HWND, LPCSTR, DWORD);
using FnOpenW = HARC(WINAPI*)(HWND, LPCWSTR, DWORD);
using FnClose = int(WINAPI*)(HARC);
using FnFindFirst = int(WINAPI*)(HARC, LPCSTR, INDIVIDUALINFOA*);
using FnFindNext = int(WINAPI*)(HARC, INDIVIDUALINFOA*);
using FnFindFirstW = int(WINAPI*)(HARC, LPCWSTR, INDIVIDUALINFOW*);
using FnFindNextW = int(WINAPI*)(HARC, INDIVIDUALINFOW*);
using FnGetString = int(WINAPI*)(HARC, LPSTR, int);
using FnDwordHarc = DWORD(WINAPI*)(HARC);
using FnWordHarc = WORD(WINAPI*)(HARC);
using FnIntHarc = int(WINAPI*)(HARC);
using FnUIntHarc = UINT(WINAPI*)(HARC);
using FnSizeEx = BOOL(WINAPI*)(HARC, ULHA_INT64*);
using FnFileTime = BOOL(WINAPI*)(HARC, FILETIME*);
using FnTime64 = BOOL(WINAPI*)(HARC, ULHA_INT64*);
using FnLastError = int(WINAPI*)(LPDWORD);
using FnUnlhaA = int(WINAPI*)(HWND, LPCSTR, LPSTR, DWORD);
using FnUnlhaW = int(WINAPI*)(HWND, LPCWSTR, LPWSTR, DWORD);
using FnConfigA = BOOL(WINAPI*)(HWND, LPSTR, int);
using FnConfigW = BOOL(WINAPI*)(HWND, LPWSTR, int);
using FnExtractMemW = int(WINAPI*)(HWND, LPCWSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD);
using FnCompressMemW = int(WINAPI*)(HWND, LPCWSTR, const LPBYTE, DWORD, const time_t*, const LPWORD, LPDWORD);
using FnSetEnum = BOOL(WINAPI*)(UNLHA_WND_ENUMMEMBPROC);
using FnSetEnum64 = BOOL(WINAPI*)(UNLHA_WND_ENUMMEMBPROC, DWORD);
using FnSetOwnerEx = BOOL(WINAPI*)(HWND, LPARCHIVERPROC);
using FnSetOwnerEx64 = BOOL(WINAPI*)(HWND, LPARCHIVERPROC, DWORD);
using FnKillOwnerEx = BOOL(WINAPI*)(HWND);
using FnSetOwner = BOOL(WINAPI*)(HWND);

enum class EnumLayout { None, A32, W32, A64, W64 };
EnumLayout enum_layout = EnumLayout::None;
BOOL enum_result = TRUE;
void (*enum_observer)() = nullptr;
std::vector<std::string> enum_records;
std::string enum_replacement_file_a;
std::string enum_replacement_add_a;
std::wstring enum_replacement_file_w;
std::wstring enum_replacement_add_w;
bool enum_mutate_metadata = false;

template<typename T>
void mutate_enum_sizes(T& info) { info.dwOriginalSize = 7; info.dwCompressedSize = 3; }
void mutate_enum_sizes(UNLHA_ENUM_MEMBER_INFO64A& info) {
    info.llOriginalSize = 0x100000007LL; info.llCompressedSize = 0x100000003LL;
}
void mutate_enum_sizes(UNLHA_ENUM_MEMBER_INFO64W& info) {
    info.llOriginalSize = 0x100000007LL; info.llCompressedSize = 0x100000003LL;
}

template<typename T>
void mutate_enum_metadata(T& info) {
    if (!enum_mutate_metadata) return;
    mutate_enum_sizes(info);
    info.dwAttributes = 7;
    info.dwCRC = 0x1234;
    info.uOSType = 42;
    info.wRatio = 321;
    info.ftCreateTime = FILETIME{101, 201};
    info.ftAccessTime = FILETIME{102, 202};
    info.ftWriteTime = FILETIME{103, 203};
}

std::uint64_t filetime_value(const FILETIME& value) {
    ULARGE_INTEGER raw{};
    raw.LowPart = value.dwLowDateTime;
    raw.HighPart = value.dwHighDateTime;
    return raw.QuadPart;
}

template<typename T>
void append_enum_record(const T& info, const std::string& file_name, const std::string& add_name) {
    std::ostringstream out;
    out << "size=" << info.dwStructSize
        << ",command=" << info.uCommand
        << ",original=" << info.dwOriginalSize
        << ",packed=" << info.dwCompressedSize
        << ",attributes=" << info.dwAttributes
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",create=" << filetime_value(info.ftCreateTime)
        << ",access=" << filetime_value(info.ftAccessTime)
        << ",write=" << filetime_value(info.ftWriteTime)
        << ",file=" << file_name
        << ",add=" << add_name;
    enum_records.push_back(out.str());
}

void append_enum_record(const UNLHA_ENUM_MEMBER_INFO64A& info) {
    std::ostringstream out;
    out << "size=" << info.dwStructSize
        << ",command=" << info.uCommand
        << ",original=" << info.llOriginalSize
        << ",packed=" << info.llCompressedSize
        << ",attributes=" << info.dwAttributes
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",create=" << filetime_value(info.ftCreateTime)
        << ",access=" << filetime_value(info.ftAccessTime)
        << ",write=" << filetime_value(info.ftWriteTime)
        << ",file=" << quote_bytes(info.szFileName)
        << ",add=" << quote_bytes(info.szAddFileName);
    enum_records.push_back(out.str());
}

void append_enum_record(const UNLHA_ENUM_MEMBER_INFO64W& info) {
    std::ostringstream out;
    out << "size=" << info.dwStructSize
        << ",command=" << info.uCommand
        << ",original=" << info.llOriginalSize
        << ",packed=" << info.llCompressedSize
        << ",attributes=" << info.dwAttributes
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",create=" << filetime_value(info.ftCreateTime)
        << ",access=" << filetime_value(info.ftAccessTime)
        << ",write=" << filetime_value(info.ftWriteTime)
        << ",file=" << quote_wide(info.szFileName)
        << ",add=" << quote_wide(info.szAddFileName);
    enum_records.push_back(out.str());
}

BOOL CALLBACK enum_probe(LPVOID raw_info) {
    if (enum_observer) enum_observer();
    if (!raw_info) {
        enum_records.push_back("null");
        return enum_result;
    }
    switch (enum_layout) {
    case EnumLayout::A32: {
        auto& info = *static_cast<UNLHA_ENUM_MEMBER_INFOA*>(raw_info);
        append_enum_record(info, quote_bytes(info.szFileName), quote_bytes(info.szAddFileName));
        mutate_enum_metadata(info);
        if (!enum_replacement_file_a.empty()) {
            strncpy_s(info.szFileName, enum_replacement_file_a.c_str(), _TRUNCATE);
        }
        if (!enum_replacement_add_a.empty()) {
            strncpy_s(info.szAddFileName, enum_replacement_add_a.c_str(), _TRUNCATE);
        }
        break;
    }
    case EnumLayout::W32: {
        auto& info = *static_cast<UNLHA_ENUM_MEMBER_INFOW*>(raw_info);
        append_enum_record(info, quote_wide(info.szFileName), quote_wide(info.szAddFileName));
        mutate_enum_metadata(info);
        if (!enum_replacement_file_w.empty()) {
            wcsncpy_s(info.szFileName, enum_replacement_file_w.c_str(), _TRUNCATE);
        }
        if (!enum_replacement_add_w.empty()) {
            wcsncpy_s(info.szAddFileName, enum_replacement_add_w.c_str(), _TRUNCATE);
        }
        break;
    }
    case EnumLayout::A64: {
        auto& info = *static_cast<UNLHA_ENUM_MEMBER_INFO64A*>(raw_info);
        append_enum_record(info);
        mutate_enum_metadata(info);
        if (!enum_replacement_file_a.empty()) {
            strncpy_s(info.szFileName, enum_replacement_file_a.c_str(), _TRUNCATE);
        }
        if (!enum_replacement_add_a.empty()) {
            strncpy_s(info.szAddFileName, enum_replacement_add_a.c_str(), _TRUNCATE);
        }
        break;
    }
    case EnumLayout::W64: {
        auto& info = *static_cast<UNLHA_ENUM_MEMBER_INFO64W*>(raw_info);
        append_enum_record(info);
        mutate_enum_metadata(info);
        if (!enum_replacement_file_w.empty()) {
            wcsncpy_s(info.szFileName, enum_replacement_file_w.c_str(), _TRUNCATE);
        }
        if (!enum_replacement_add_w.empty()) {
            wcsncpy_s(info.szAddFileName, enum_replacement_add_w.c_str(), _TRUNCATE);
        }
        break;
    }
    default:
        enum_records.push_back("unexpected-layout");
        break;
    }
    return enum_result;
}

enum class ProgressLayout { BasicA, BasicW, ExA, ExW, Ex32A, Ex32W, Ex64A, Ex64W, Total };
ProgressLayout progress_layout = ProgressLayout::ExA;
BOOL progress_result = TRUE;
int progress_abort_state = -1;
unsigned int progress_abort_occurrence = 1;
unsigned int progress_abort_seen = 0;
bool progress_abort_after_start = false;
HWND progress_expected_owner = nullptr;
bool progress_ignore_access_time = false;
bool progress_full_paths = false;
bool progress_audit_copy_files = false;
std::wstring progress_archive_audit_path;
bool progress_archive_prefix_audit = false;
std::wstring progress_access_audit_path;
bool progress_find_access_audit = false;
std::wstring progress_directory_audit_path;
bool progress_directory_audit_access = false;
std::vector<std::string> progress_records;

std::string describe_progress_name(const char* value) {
    if (!value || !*value) return "empty";
    if (progress_full_paths) return "raw=" + quote_bytes(value);
    const char* slash = std::strrchr(value, '/');
    const char* backslash = std::strrchr(value, '\\');
    const char* leaf = slash && backslash ? (std::max)(slash, backslash) + 1
                     : slash ? slash + 1 : backslash ? backslash + 1 : value;
    return std::string(leaf == value ? "name=" : "path=") + quote_bytes(leaf);
}

std::string describe_progress_name(const wchar_t* value) {
    if (!value || !*value) return "empty";
    if (progress_full_paths) return "raw=" + quote_wide(value);
    const wchar_t* slash = std::wcsrchr(value, L'/');
    const wchar_t* backslash = std::wcsrchr(value, L'\\');
    const wchar_t* leaf = slash && backslash ? (std::max)(slash, backslash) + 1
                        : slash ? slash + 1 : backslash ? backslash + 1 : value;
    return std::string(leaf == value ? "name=" : "path=") + quote_wide(leaf);
}

template<typename T>
void append_progress_record(UINT message, UINT state, const T& info,
                            std::int64_t file_size, std::int64_t compressed_size,
                            std::int64_t write_size,
                            const std::string& source, const std::string& destination,
                            const std::string& mode) {
    std::ostringstream out;
    out << "msg=" << (message != 0)
        << ",state=" << state;
    if (state == 5) {
        out << ",legacy-file=undefined,legacy-write=undefined";
    } else {
        out << ",legacy-file=" << info.exinfo.dwFileSize
            << ",legacy-write=" << info.exinfo.dwWriteSize;
    }
    out
        << ",file=" << file_size
        << ",compressed=" << compressed_size
        << ",write=" << write_size
        << ",attributes=" << info.dwAttributes
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",create=" << filetime_value(info.ftCreateTime)
        << ",access=";
    if (progress_ignore_access_time) out << "volatile";
    else out << filetime_value(info.ftAccessTime);
    out << ",write-time=" << filetime_value(info.ftWriteTime)
        << ",mode=" << mode
        << ",source=" << source
        << ",dest=" << destination;
    if (state == ARCEXTRACT_BEGIN && !progress_access_audit_path.empty()) {
        // 圧縮完了後は参照日時が再更新され得るため、BEGIN の瞬間に実ファイルから独立に取得する。
        const DWORD previous_error = GetLastError();
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        out << ",source-access-audit=";
        if (GetFileAttributesExW(progress_access_audit_path.c_str(), GetFileExInfoStandard, &attributes))
            out << filetime_value(attributes.ftLastAccessTime);
        else out << "unavailable";
        if (progress_find_access_audit) {
            // ハンドルを開く取得方式と区別して、原版が用いる検索時の日時を観測する。
            WIN32_FIND_DATAW found{};
            const HANDLE search = FindFirstFileW(progress_access_audit_path.c_str(), &found);
            out << ",source-find-access-audit=";
            if (search != INVALID_HANDLE_VALUE) {
                out << filetime_value(found.ftLastAccessTime);
                FindClose(search);
            } else out << "unavailable";
        }
        SetLastError(previous_error);
    }
    if (!progress_directory_audit_path.empty()) {
        const DWORD previous_error = GetLastError();
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        out << ",directory-audit=";
        if (GetFileAttributesExW(progress_directory_audit_path.c_str(), GetFileExInfoStandard, &attributes)) {
            out << attributes.dwFileAttributes << ",directory-create=" << filetime_value(attributes.ftCreationTime)
                << ",directory-write=" << filetime_value(attributes.ftLastWriteTime);
            if (progress_directory_audit_access)
                out << ",directory-access=" << filetime_value(attributes.ftLastAccessTime);
        }
        else out << "missing";
        SetLastError(previous_error);
    }
    progress_records.push_back(out.str());
}

void append_progress_record(UINT message, UINT state, const EXTRACTINGINFOEXA& info) {
    std::ostringstream out;
    out << "msg=" << (message != 0)
        << ",state=" << state
        << ",file=" << info.exinfo.dwFileSize
        << ",write=" << info.exinfo.dwWriteSize
        << ",compressed=" << info.dwCompressedSize
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",date=" << info.wDate
        << ",time=" << info.wTime
        << ",attribute=" << quote_bytes(info.szAttribute)
        << ",mode=" << quote_bytes(info.szMode)
        << ",source=" << describe_progress_name(info.exinfo.szSourceFileName)
        << ",dest=" << describe_progress_name(info.exinfo.szDestFileName);
    progress_records.push_back(out.str());
}

void append_progress_record(UINT message, UINT state, const EXTRACTINGINFOEXW& info) {
    std::ostringstream out;
    out << "msg=" << (message != 0)
        << ",state=" << state
        << ",file=" << info.exinfo.dwFileSize
        << ",write=" << info.exinfo.dwWriteSize
        << ",compressed=" << info.dwCompressedSize
        << ",crc=" << info.dwCRC
        << ",os=" << info.uOSType
        << ",ratio=" << info.wRatio
        << ",date=" << info.wDate
        << ",time=" << info.wTime
        << ",attribute=" << quote_wide(info.szAttribute)
        << ",mode=" << quote_wide(info.szMode)
        << ",source=" << describe_progress_name(info.exinfo.szSourceFileName)
        << ",dest=" << describe_progress_name(info.exinfo.szDestFileName);
    progress_records.push_back(out.str());
}

void append_progress_record(UINT message, UINT state, const EXTRACTINGINFOA& info) {
    std::ostringstream out;
    out << "msg=" << (message != 0)
        << ",state=" << state
        << ",file=" << info.dwFileSize
        << ",write=" << info.dwWriteSize
        << ",source=" << describe_progress_name(info.szSourceFileName)
        << ",dest=" << describe_progress_name(info.szDestFileName);
    progress_records.push_back(out.str());
}

void append_progress_record(UINT message, UINT state, const EXTRACTINGINFOW& info) {
    std::ostringstream out;
    out << "msg=" << (message != 0)
        << ",state=" << state
        << ",file=" << info.dwFileSize
        << ",write=" << info.dwWriteSize
        << ",source=" << describe_progress_name(info.szSourceFileName)
        << ",dest=" << describe_progress_name(info.szDestFileName);
    progress_records.push_back(out.str());
}

static bool should_abort_progress(const UINT state) {
    return state == static_cast<UINT>(progress_abort_state) &&
        ++progress_abort_seen >= progress_abort_occurrence;
}

static HWND pump_audit_window = nullptr;
static bool audit_thread_priority = false;
static unsigned int pump_audit_serial = 0;
static constexpr UINT pump_audit_message = WM_APP + 77;
static WNDPROC pump_audit_original_proc = nullptr;
static LRESULT CALLBACK pump_audit_window_proc(HWND hwnd, UINT message, WPARAM state, LPARAM serial) {
    if (message == pump_audit_message) {
        const DWORD error = GetLastError();
        std::cout << "pump-delivered=" << state << ',' << serial << '\n';
        SetLastError(error);
        return 0;
    }
    return CallWindowProcW(pump_audit_original_proc, hwnd, message, state, serial);
}

BOOL CALLBACK progress_probe(HWND hwnd, UINT message, UINT state, LPVOID raw_info) {
    if (audit_thread_priority) {
        const DWORD error = GetLastError();
        std::cout << "priority-audit=" << state << ',' << GetThreadPriority(GetCurrentThread()) << '\n';
        SetLastError(error);
    }
    if (pump_audit_window) {
        const DWORD error = GetLastError();
        const unsigned int serial = ++pump_audit_serial;
        const BOOL posted = PostMessageW(pump_audit_window, pump_audit_message, state, serial);
        std::cout << "pump-post=" << state << ',' << serial << ",ok=" << posted << '\n';
        SetLastError(error);
    }
    if (!raw_info) {
        std::ostringstream out;
        out << "msg=" << (message != 0) << ",state=" << state << ",null=1"
            << ",owner=" << (hwnd == progress_expected_owner);
        progress_records.push_back(out.str());
        return should_abort_progress(state) ? FALSE : progress_result;
    }
    switch (progress_layout) {
    case ProgressLayout::Total: {
        const auto& info = *static_cast<EXTRACTINGINFO_TOTAL*>(raw_info);
        if (info.dwStructSize != sizeof(info)) {
            progress_records.push_back("unexpected-total-progress-size");
            return FALSE;
        }
        std::ostringstream out;
        out << "msg=" << (message != 0) << ",state=" << state
            << ",file=" << info.llFileSize << ",write=" << info.llWriteSize
            << ",total=" << info.llTotalBytes << ",processed=" << info.llTotalProcessed
            << ",files=" << info.dwFilesProcessed << '/' << info.dwTotalFiles
            << ",source=" << quote_wide(info.szSourceFileName)
            << ",dest=" << quote_wide(info.szDestFileName) << ',';
        progress_records.push_back(out.str());
        if (progress_abort_after_start && state == ARCEXTRACT_INPROCESS && info.llWriteSize > 0)
            return FALSE;
        break;
    }
    case ProgressLayout::ExA:
        append_progress_record(message, state, *static_cast<EXTRACTINGINFOEXA*>(raw_info));
        break;
    case ProgressLayout::ExW:
        append_progress_record(message, state, *static_cast<EXTRACTINGINFOEXW*>(raw_info));
        break;
    case ProgressLayout::Ex32A: {
        const auto& info = *static_cast<EXTRACTINGINFOEX32A*>(raw_info);
        append_progress_record(message, state, info, info.dwFileSize, info.dwCompressedSize,
                               info.dwWriteSize, describe_progress_name(info.szSourceFileName),
                               describe_progress_name(info.szDestFileName), quote_bytes(info.szMode));
        break;
    }
    case ProgressLayout::Ex32W: {
        const auto& info = *static_cast<EXTRACTINGINFOEX32W*>(raw_info);
        append_progress_record(message, state, info, info.dwFileSize, info.dwCompressedSize,
                               info.dwWriteSize, describe_progress_name(info.szSourceFileName),
                               describe_progress_name(info.szDestFileName), quote_wide(info.szMode));
        break;
    }
    case ProgressLayout::Ex64A: {
        const auto& info = *static_cast<EXTRACTINGINFOEX64A*>(raw_info);
        append_progress_record(message, state, info, info.llFileSize, info.llCompressedSize,
                               info.llWriteSize, describe_progress_name(info.szSourceFileName),
                               describe_progress_name(info.szDestFileName), quote_bytes(info.szMode));
        break;
    }
    case ProgressLayout::Ex64W: {
        const auto& info = *static_cast<EXTRACTINGINFOEX64W*>(raw_info);
        append_progress_record(message, state, info, info.llFileSize, info.llCompressedSize,
                               info.llWriteSize, describe_progress_name(info.szSourceFileName),
                               describe_progress_name(info.szDestFileName), quote_wide(info.szMode));
        break;
    }
    }
    if (!progress_records.empty()) {
        if (!progress_archive_audit_path.empty()) {
            // 通知名とは独立に、指定した書庫パスの公開時点を読み取りだけで観測する。
            const DWORD saved_error = GetLastError();
            WIN32_FILE_ATTRIBUTE_DATA attributes{};
            std::string value;
            if (GetFileAttributesExW(progress_archive_audit_path.c_str(), GetFileExInfoStandard, &attributes)) {
                value = std::to_string((static_cast<unsigned long long>(attributes.nFileSizeHigh) << 32) |
                                       attributes.nFileSizeLow);
            } else value = std::string("error:") + std::to_string(GetLastError());
            progress_records.back() += ",audit-archive-size=" + value;
            if (progress_archive_prefix_audit) {
                const HANDLE file = CreateFileW(progress_archive_audit_path.c_str(), GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
                std::string prefix;
                if (file == INVALID_HANDLE_VALUE) prefix = "error:" + std::to_string(GetLastError());
                else {
                    unsigned char bytes[256]{};
                    DWORD count = 0;
                    if (!ReadFile(file, bytes, sizeof(bytes), &count, nullptr))
                        prefix = "error:" + std::to_string(GetLastError());
                    else {
                        constexpr char digits[] = "0123456789abcdef";
                        for (DWORD index = 0; index < count; ++index) {
                            prefix += digits[bytes[index] >> 4];
                            prefix += digits[bytes[index] & 15];
                        }
                    }
                    CloseHandle(file);
                }
                progress_records.back() += ",audit-archive-prefix=" + prefix;
            }
            SetLastError(saved_error);
        }
        if (progress_audit_copy_files && state == ARCEXTRACT_COPY && raw_info) {
            const auto& info = *static_cast<EXTRACTINGINFOEX64W*>(raw_info);
            const DWORD saved_error = GetLastError();
            const auto audit_file = [](const wchar_t* path) {
                WIN32_FILE_ATTRIBUTE_DATA attributes{};
                if (!GetFileAttributesExW(path, GetFileExInfoStandard, &attributes))
                    return std::string("error:") + std::to_string(GetLastError());
                const unsigned long long size = (static_cast<unsigned long long>(attributes.nFileSizeHigh) << 32) |
                                                attributes.nFileSizeLow;
                return std::to_string(size);
            };
            progress_records.back() += ",audit-source-size=" + audit_file(info.szSourceFileName) +
                                       ",audit-dest-size=" + audit_file(info.szDestFileName);
            SetLastError(saved_error);
        }
        progress_records.back() += std::string(",owner=") +
                                   (hwnd == progress_expected_owner ? "1" : "0");
    }
    return should_abort_progress(state) ? FALSE : progress_result;
}

LRESULT CALLBACK progress_window_proc(HWND hwnd, UINT message, WPARAM state, LPARAM raw_info) {
    static const UINT progress_message = RegisterWindowMessageA(WM_ARCEXTRACT);
    if (message == progress_message) {
        if (!raw_info) {
            std::ostringstream out;
            out << "msg=1,state=" << state << ",null=1";
            progress_records.push_back(out.str());
        } else if (progress_layout == ProgressLayout::BasicA) {
            append_progress_record(message, static_cast<UINT>(state),
                                   *reinterpret_cast<const EXTRACTINGINFOA*>(raw_info));
        } else {
            append_progress_record(message, static_cast<UINT>(state),
                                   *reinterpret_cast<const EXTRACTINGINFOW*>(raw_info));
        }
        return 0;
    }
    return DefWindowProcW(hwnd, message, state, raw_info);
}

std::wstring quote_argument(const std::wstring& value) {
    return L"\"" + value + L"\"";
}

void ensure_directory(const std::wstring& path) {
    if (!CreateDirectoryW(path.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        throw std::runtime_error("CreateDirectoryW failed: " + std::to_string(GetLastError()));
    }
}

void write_file(const std::wstring& path, const std::vector<unsigned char>& data) {
    FILE* file = nullptr;
    if (_wfopen_s(&file, path.c_str(), L"wb") != 0 || !file) {
        throw std::runtime_error("cannot create integration input");
    }
    const size_t written = std::fwrite(data.data(), 1, data.size(), file);
    std::fclose(file);
    if (written != data.size()) throw std::runtime_error("short integration write");
}

void set_file_write_time(const std::wstring& path, const WORD year, const WORD month,
                         const WORD day, const WORD hour = 0, const WORD minute = 0,
                         const WORD second = 0) {
    SYSTEMTIME system_time{};
    system_time.wYear = year;
    system_time.wMonth = month;
    system_time.wDay = day;
    system_time.wHour = hour;
    system_time.wMinute = minute;
    system_time.wSecond = second;
    FILETIME file_time{};
    if (!SystemTimeToFileTime(&system_time, &file_time)) {
        throw std::runtime_error("SystemTimeToFileTime failed");
    }
    HANDLE file = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        throw std::runtime_error("cannot open file to set timestamp");
    }
    const BOOL result = SetFileTime(file, nullptr, nullptr, &file_time);
    CloseHandle(file);
    if (!result) throw std::runtime_error("SetFileTime failed");
}

void set_file_times(const std::wstring& path, const WORD year, const WORD month,
                    const WORD day, const WORD hour = 0, const WORD minute = 0,
                    const WORD second = 0) {
    SYSTEMTIME system_time{};
    system_time.wYear = year;
    system_time.wMonth = month;
    system_time.wDay = day;
    system_time.wHour = hour;
    system_time.wMinute = minute;
    system_time.wSecond = second;
    FILETIME file_time{};
    if (!SystemTimeToFileTime(&system_time, &file_time)) {
        throw std::runtime_error("SystemTimeToFileTime failed");
    }
    HANDLE file = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        throw std::runtime_error("cannot open file to set timestamps");
    }
    const BOOL result = SetFileTime(file, &file_time, &file_time, &file_time);
    CloseHandle(file);
    if (!result) throw std::runtime_error("SetFileTime failed");
}

std::vector<unsigned char> read_file(const std::wstring& path) {
    FILE* file = nullptr;
    if (_wfopen_s(&file, path.c_str(), L"rb") != 0 || !file) {
        throw std::runtime_error("cannot open integration output");
    }
    _fseeki64(file, 0, SEEK_END);
    const __int64 length = _ftelli64(file);
    _fseeki64(file, 0, SEEK_SET);
    if (length < 0 || length > 16 * 1024 * 1024) {
        std::fclose(file);
        throw std::runtime_error("unexpected integration output size");
    }
    std::vector<unsigned char> data(static_cast<size_t>(length));
    const size_t actual = data.empty() ? 0 : std::fread(data.data(), 1, data.size(), file);
    std::fclose(file);
    if (actual != data.size()) throw std::runtime_error("short integration read");
    return data;
}

std::string dictionary_command_utf8(const std::wstring& command) {
    const int length = WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (length <= 0) throw std::runtime_error("cannot encode dictionary command");
    std::string result(static_cast<size_t>(length), '\0');
    if (!WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, &result[0], length, nullptr, nullptr))
        throw std::runtime_error("cannot encode dictionary command");
    result.pop_back();
    return result;
}

int run_legacy_payload_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                             const wchar_t* expected_path, const bool quiet = false) {
    const auto expected = read_file(expected_path);
    // LH3 の単一文字木は約 15 MiB の反復入力で次ブロックに到達する。
    if (expected.size() > 16U * 1024U * 1024U)
        throw std::runtime_error("legacy payload exceeds sixteen MiB");
    const DWORD capacity = static_cast<DWORD>(expected.size()) + 17;
    const std::wstring command = std::wstring(quiet ? L"-gm1 -n1 " : L"-gm1 ") +
        quote_argument(archive_path) + L" *";
    const std::string encoded = dictionary_command_utf8(command);
    for (const char* api : {"legacy", "A", "W"}) {
        // API 間の持越しを避け、本文・未使用領域・両端のガードを独立に観測する。
        Module module(dll_path);
        proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
        std::vector<unsigned char> buffer(capacity + 32U, 0xcc);
        auto* output = buffer.data() + 16;
        DWORD written = 123456;
        time_t timestamp = 0;
        WORD attributes = 0;
        using NarrowExtract = int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD,
                                            time_t*, LPWORD, LPDWORD);
        const int result = std::strcmp(api, "W") == 0
            ? proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
                nullptr, command.c_str(), output, capacity, &timestamp, &attributes, &written)
            : proc<NarrowExtract>(module.handle, std::strcmp(api, "A") == 0
                ? "UnlhaExtractMemA" : "UnlhaExtractMem")(
                nullptr, encoded.c_str(), output, capacity, &timestamp, &attributes, &written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        const auto unchanged = [](unsigned char value) { return value == 0xcc; };
        const bool prefix = std::equal(expected.begin(), expected.end(), output);
        const bool tail = std::all_of(output + expected.size(), output + capacity, unchanged);
        const bool guard = std::all_of(buffer.begin(), buffer.begin() + 16, unchanged) &&
            std::all_of(buffer.end() - 16, buffer.end(), unchanged);
        std::cout << "memory." << api << '=' << result << ",error=" << error
                  << ",system=" << system << ",written=" << written
                  << ",time=" << timestamp << ",attr=" << attributes
                  << ",expected=" << expected.size()
                  << ",payload=" << (result == 0 && written == expected.size() && prefix)
                  << ",prefix=" << prefix << ",tail=" << tail << ",guard=" << guard << '\n';
        // 原版のアンロードより先に各 API の観測結果を出力する。
        std::cout.flush();
    }
    return 0;
}

int create_dictionary_fixture(const wchar_t* dll_path, const wchar_t* workspace,
                              const wchar_t* switches, const size_t block_size,
                              const wchar_t* api, const wchar_t* member = L"payload.bin") {
    if (block_size > 1024 * 1024) throw std::runtime_error("dictionary fixture too large");
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const std::wstring root(workspace);
    ensure_directory(root);
    const std::wstring archive = root + L"\\compressed.lzh";
    if (GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("dictionary fixture already exists");
    std::vector<unsigned char> payload(block_size * 3);
    unsigned int state = 0x9178be3dU;
    for (size_t index = 0; index < block_size; ++index) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        payload[index] = static_cast<unsigned char>(state);
        payload[index + block_size] = payload[index];
        payload[index + block_size * 2] = payload[index];
    }
    write_file(root + L"\\payload.bin", payload);
    set_file_times(root + L"\\payload.bin", 2024, 1, 2, 3, 4, 6);
    if (std::wcscmp(member, L"payload.bin") != 0) {
        write_file(root + L"\\" + member, payload);
        set_file_times(root + L"\\" + member, 2024, 1, 2, 3, 4, 6);
    }
    const std::wstring options = L"-gm1 -y1 -e1 -h2 " + std::wstring(switches) + L" ";
    const bool memory = std::wcsncmp(api, L"memory", 6) == 0;
    const std::wstring command = (memory ? L"" : L"a ") + options + quote_argument(archive) +
        L" " + (memory ? L"" : quote_argument(root + L"\\") + L" ") + quote_argument(member);
    int result = 0;
    std::vector<wchar_t> output_w(4096);
    std::vector<char> output_a(16384);
    if (memory) {
        const time_t timestamp = 1704164646;
        WORD attributes = FILE_ATTRIBUTE_ARCHIVE;
        DWORD written = 0;
        unsigned char empty = 0;
        auto* data = payload.empty() ? &empty : payload.data();
        if (std::wcscmp(api, L"memoryA") == 0) {
            const std::string narrow = dictionary_command_utf8(command);
            result = proc<int(WINAPI*)(HWND, LPCSTR, const LPBYTE, DWORD, const time_t*, const LPWORD, LPDWORD)>(
                module.handle, "UnlhaCompressMemA")(nullptr, narrow.c_str(), data,
                    static_cast<DWORD>(payload.size()), &timestamp, &attributes, &written);
        } else {
            result = proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW")(nullptr, command.c_str(), data,
                static_cast<DWORD>(payload.size()), &timestamp, &attributes, &written);
        }
        std::cout << "memory.written=" << written << '\n';
    } else if (std::wcscmp(api, L"A") == 0) {
        const std::string narrow = dictionary_command_utf8(command);
        result = proc<FnUnlhaA>(module.handle, "UnlhaA")(nullptr, narrow.c_str(), output_a.data(),
            static_cast<DWORD>(output_a.size()));
    } else {
        result = proc<FnUnlhaW>(module.handle, "UnlhaW")(nullptr, command.c_str(), output_w.data(),
            static_cast<DWORD>(output_w.size()));
    }
    std::cout << "create.result=" << result << '\n';
    if (result != 0) {
        DWORD system_error = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
        std::cout << "create.error=" << error << ",system=" << system_error
                  << ",outputA=" << quote_bytes(output_a.data()) << ",outputW=" << quote_wide(output_w.data()) << '\n';
        return 1;
    }
    const auto bytes = read_file(archive);
    if (bytes.size() < 21) throw std::runtime_error("dictionary fixture header missing");
    std::cout << "create.method=" << std::string(bytes.begin() + 2, bytes.begin() + 7) << '\n';
    std::cout << "create.size=" << bytes.size() << '\n';
    return 0;
}

int verify_dictionary_fixture(const wchar_t* dll_path, const wchar_t* workspace,
                              const wchar_t* member = L"payload.bin") {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const std::wstring root(workspace);
    const std::wstring archive = root + L"\\compressed.lzh";
    const auto payload = read_file(root + L"\\payload.bin");
    for (int mode : {0, 1, 2}) {
        if (!proc<FnCheckW>(module.handle, "UnlhaCheckArchiveW")(archive.c_str(), mode))
            throw std::runtime_error("dictionary CheckArchive failed");
    }
    HARC handle = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW")(nullptr, archive.c_str(), 0);
    if (!handle) throw std::runtime_error("dictionary OpenArchive failed");
    INDIVIDUALINFOW info{};
    const int found = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW")(handle, L"*", &info);
    proc<FnClose>(module.handle, "UnlhaCloseArchive")(handle);
    if (found != 0 || info.dwOriginalSize != payload.size() || std::wcscmp(info.szFileName, member) != 0) {
        std::cerr << "dictionary name=" << quote_wide(info.szFileName) << '\n';
        throw std::runtime_error("dictionary metadata mismatch");
    }
    const std::wstring command = L"-gm1 " + quote_argument(archive) + L" " + quote_argument(member);
    for (const char* api : {"UnlhaExtractMem", "UnlhaExtractMemA", "UnlhaExtractMemW"}) {
        const DWORD capacity = static_cast<DWORD>((std::max)(size_t{1}, payload.size()));
        std::vector<unsigned char> buffer(capacity + 16, 0xa5);
        DWORD written = 0;
        time_t timestamp = 0;
        WORD attributes = 0;
        int result;
        if (std::strcmp(api, "UnlhaExtractMemW") == 0) {
            result = proc<FnExtractMemW>(module.handle, api)(nullptr, command.c_str(), buffer.data(),
                capacity, &timestamp, &attributes, &written);
        } else {
            const std::string narrow = dictionary_command_utf8(command);
            result = proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                module.handle, api)(nullptr, narrow.c_str(), buffer.data(),
                    capacity, &timestamp, &attributes, &written);
        }
        if (result != 0 || written != payload.size() || timestamp != 1704164646 || attributes != FILE_ATTRIBUTE_ARCHIVE ||
            !std::equal(payload.begin(), payload.end(), buffer.begin()) ||
            !std::all_of(buffer.begin() + payload.size(), buffer.end(), [](unsigned char b) { return b == 0xa5; })) {
            std::cerr << "dictionary memory result=" << result << ",written=" << written
                      << ",expected=" << payload.size() << ",first=" << static_cast<unsigned int>(buffer[0]) << '\n';
            throw std::runtime_error(std::string("dictionary memory mismatch: ") + api);
        }
    }
    const std::wstring extracted = root + L"\\extracted-" + std::to_wstring(GetCurrentProcessId());
    ensure_directory(extracted);
    const std::wstring extract = L"x -gm1 -y1 " + quote_argument(archive) + L" " + quote_argument(extracted + L"\\");
    const int result = proc<FnUnlhaW>(module.handle, "UnlhaW")(nullptr, extract.c_str(), nullptr, 0);
    if (result != 0 || read_file(extracted + L"\\" + member) != payload)
        throw std::runtime_error("dictionary file extraction mismatch");
    WIN32_FILE_ATTRIBUTE_DATA expected_time{}, actual_time{};
    if (!GetFileAttributesExW((root + L"\\payload.bin").c_str(), GetFileExInfoStandard, &expected_time) ||
        !GetFileAttributesExW((extracted + L"\\" + member).c_str(), GetFileExInfoStandard, &actual_time) ||
        CompareFileTime(&expected_time.ftLastWriteTime, &actual_time.ftLastWriteTime) != 0)
        throw std::runtime_error("dictionary extracted timestamp mismatch");
    std::cout << "verify=ok,bytes=" << payload.size() << '\n';
    return 0;
}

int run_dictionary_state(const wchar_t* dll_path, const wchar_t* workspace) {
    // 検査・展開が変更する辞書状態も含め、同じ DLL インスタンスを使い続ける。
    Module retained(dll_path);
    ensure_directory(workspace);
    const wchar_t* options[] = {L"-jmm17", L"-jm2", L"-jmm19", L"-jm4", L"-jmm18", L"-jm1", L"-jmm12", L"-jm3"};
    const size_t blocks[] = {98304, 1024, 393216, 49152, 196608, 1024, 3072, 24576};
    for (size_t index = 0; index < _countof(options); ++index) {
        const std::wstring root = std::wstring(workspace) + L"\\step-" + std::to_wstring(index);
        if (create_dictionary_fixture(dll_path, root.c_str(), options[index], blocks[index], L"W") != 0 ||
            verify_dictionary_fixture(dll_path, root.c_str()) != 0)
            return 1;
    }
    std::cout << "dictionary.state=ok\n";
    return 0;
}

int run_integration(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto extract_mem = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const auto compress_mem = proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring extracted = root + L"\\extracted";
    const std::wstring archive = root + L"\\roundtrip.lzh";
    const std::wstring memory_archive = root + L"\\memory.lzh";
    ensure_directory(root);
    ensure_directory(source);
    ensure_directory(extracted);

    std::vector<unsigned char> payload(65539);
    for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<unsigned char>((index * 37U + index / 251U) & 0xffU);
    }
    write_file(source + L"\\payload.bin", payload);

    wchar_t output[4096]{};
    const std::wstring add_command = L"a -y -jm2 " + quote_argument(archive) + L" " +
                                     quote_argument(source + L"\\") + L" " + quote_argument(L"payload.bin");
    const int add_result = unlha(nullptr, add_command.c_str(), output, _countof(output));
    if (add_result != 0) {
        std::wcerr << L"add failed rc=" << add_result << L" output=" << output << L'\n';
        return 1;
    }

    const std::wstring extract_command = L"x -y " + quote_argument(archive) + L" " +
                                         quote_argument(extracted + L"\\");
    std::memset(output, 0, sizeof(output));
    const int extract_result = unlha(nullptr, extract_command.c_str(), output, _countof(output));
    if (extract_result != 0 || read_file(extracted + L"\\payload.bin") != payload) {
        std::wcerr << L"extract round-trip failed rc=" << extract_result << L" output=" << output << L'\n';
        return 1;
    }

    std::vector<unsigned char> memory(payload.size());
    DWORD memory_written = 0;
    time_t timestamp = 0;
    WORD attributes = 0;
    const std::wstring memory_command = quote_argument(archive) + L" " + quote_argument(L"payload.bin");
    const int memory_result = extract_mem(nullptr, memory_command.c_str(), memory.data(),
                                         static_cast<DWORD>(memory.size()), &timestamp, &attributes,
                                         &memory_written);
    if (memory_result != 0 || memory_written != payload.size() || memory != payload) {
        std::cerr << "memory extract failed rc=" << memory_result << " written=" << memory_written << '\n';
        return 1;
    }

    DWORD compressed_written = 0;
    const std::wstring compress_memory_command = quote_argument(memory_archive) + L" " +
                                                  quote_argument(L"memory.bin");
    const int compress_memory_result = compress_mem(nullptr, compress_memory_command.c_str(), payload.data(),
                                                    static_cast<DWORD>(payload.size()), &timestamp, &attributes,
                                                    &compressed_written);
    if (compress_memory_result != 0 || compressed_written == 0) {
        std::cerr << "memory compress failed rc=" << compress_memory_result
                  << " written=" << compressed_written << '\n';
        return 1;
    }

    std::fill(memory.begin(), memory.end(), static_cast<unsigned char>(0));
    memory_written = 0;
    const std::wstring verify_memory_command = quote_argument(memory_archive) + L" " + quote_argument(L"memory.bin");
    const int verify_memory_result = extract_mem(nullptr, verify_memory_command.c_str(), memory.data(),
                                                static_cast<DWORD>(memory.size()), nullptr, nullptr,
                                                &memory_written);
    if (verify_memory_result != 0 || memory_written != payload.size() || memory != payload) {
        std::cerr << "memory compress round-trip failed rc=" << verify_memory_result << '\n';
        return 1;
    }

    std::cout << "integration round-trip passed\n";
    return 0;
}

int run_fresh_effects(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto extract_mem = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const auto get_file_count = proc<FnCountW>(module.handle, "UnlhaGetFileCountW");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\fresh.lzh";
    const std::wstring existing_file = source + L"\\existing.bin";
    const std::wstring new_file = source + L"\\new.bin";
    ensure_directory(root);
    ensure_directory(source);

    const std::vector<unsigned char> original_payload = {0x11, 0x22, 0x33, 0x44};
    const std::vector<unsigned char> newer_payload = {0x91, 0x82, 0x73, 0x64, 0x55};
    const std::vector<unsigned char> older_payload = {0xaa, 0xbb, 0xcc};
    const std::vector<unsigned char> new_payload = {0xde, 0xad, 0xbe, 0xef};

    write_file(existing_file, original_payload);
    set_file_write_time(existing_file, 2020, 1, 2, 3, 4, 6);
    wchar_t output[4096]{};
    const std::wstring add_command = L"a -y -jm2 " + quote_argument(archive) + L" " +
                                     quote_argument(source + L"\\") + L" " +
                                     quote_argument(L"existing.bin");
    if (unlha(nullptr, add_command.c_str(), output, _countof(output)) != 0) {
        throw std::runtime_error("fresh effects: initial archive creation failed");
    }

    write_file(existing_file, newer_payload);
    set_file_write_time(existing_file, 2021, 2, 3, 4, 5, 8);
    write_file(new_file, new_payload);
    set_file_write_time(new_file, 2021, 2, 3, 4, 5, 8);
    std::memset(output, 0, sizeof(output));
    const std::wstring fresh_command = L"f -y -jm2 " + quote_argument(archive) + L" " +
                                       quote_argument(source + L"\\") + L" " +
                                       quote_argument(L"existing.bin") + L" " +
                                       quote_argument(L"new.bin");
    const int fresh_result = unlha(nullptr, fresh_command.c_str(), output, _countof(output));
    if (fresh_result != 0) {
        std::wcerr << L"fresh effects: update failed rc=" << fresh_result << L" output=" << output << L'\n';
        return 1;
    }

    std::vector<unsigned char> extracted(newer_payload.size());
    DWORD extracted_size = 0;
    const std::wstring existing_command = quote_argument(archive) + L" " +
                                          quote_argument(L"existing.bin");
    if (extract_mem(nullptr, existing_command.c_str(), extracted.data(),
                    static_cast<DWORD>(extracted.size()), nullptr, nullptr, &extracted_size) != 0 ||
        extracted_size != newer_payload.size() || extracted != newer_payload) {
        throw std::runtime_error("fresh effects: newer existing member was not replaced");
    }

    if (get_file_count(archive.c_str()) != 1) {
        throw std::runtime_error("fresh effects: absent member was unexpectedly added");
    }

    write_file(existing_file, older_payload);
    set_file_write_time(existing_file, 2019, 1, 2, 3, 4, 6);
    std::memset(output, 0, sizeof(output));
    if (unlha(nullptr, fresh_command.c_str(), output, _countof(output)) != 0) {
        throw std::runtime_error("fresh effects: older-file pass failed");
    }
    std::fill(extracted.begin(), extracted.end(), static_cast<unsigned char>(0));
    extracted_size = 0;
    if (extract_mem(nullptr, existing_command.c_str(), extracted.data(),
                    static_cast<DWORD>(extracted.size()), nullptr, nullptr, &extracted_size) != 0 ||
        extracted_size != newer_payload.size() || extracted != newer_payload) {
        throw std::runtime_error("fresh effects: older source replaced a newer member");
    }

    std::cout << "fresh command effects passed\n";
    return 0;
}

int run_progress_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                       const wchar_t* workspace, const bool abort_only) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto set_a = proc<FnSetOwnerEx>(h, "UnlhaSetOwnerWindowExA");
    const auto set_w = proc<FnSetOwnerEx>(h, "UnlhaSetOwnerWindowExW");
    const auto set_64 = proc<FnSetOwnerEx64>(h, "UnlhaSetOwnerWindowEx64");
    const auto kill = proc<FnKillOwnerEx>(h, "UnlhaKillOwnerWindowEx");
    const auto kill_64 = proc<FnKillOwnerEx>(h, "UnlhaKillOwnerWindowEx64");
    const auto set_basic_a = proc<FnSetOwner>(h, "UnlhaSetOwnerWindowA");
    const auto set_basic_w = proc<FnSetOwner>(h, "UnlhaSetOwnerWindowW");
    const auto clear = proc<FnBool0>(h, "UnlhaClearOwnerWindow");

    const std::wstring destination(workspace);
    ensure_directory(destination);
    const HWND owner = nullptr;

    const wchar_t* window_class_name = L"UnLhaReCompatibilityProgressWindow";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = progress_window_proc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = window_class_name;
    if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        throw std::runtime_error("cannot register progress message window class");
    }
    const HWND message_window = CreateWindowExW(0, window_class_name, L"", 0,
                                                 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                                 window_class.hInstance, nullptr);
    if (!message_window) throw std::runtime_error("cannot create progress message window");

    auto make_mode_destination = [&](const char* mode) {
        const int mode_length = MultiByteToWideChar(CP_UTF8, 0, mode, -1, nullptr, 0);
        std::wstring mode_wide(static_cast<size_t>(mode_length), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, mode, -1, &mode_wide[0], mode_length);
        mode_wide.resize(static_cast<size_t>(mode_length - 1));
        const std::wstring result = destination + L"\\" + mode_wide;
        ensure_directory(result);
        return result;
    };

    auto report_basic = [&](const char* mode, ProgressLayout layout, FnSetOwner setter) {
        progress_layout = layout;
        progress_abort_state = -1;
        progress_records.clear();
        const std::wstring mode_destination = make_mode_destination(mode);
        const std::wstring command = L"x -n1 -y " + quote_argument(archive_path) + L" " +
                                     quote_argument(mode_destination + L"\\");
        const BOOL set_result = setter(message_window);
        wchar_t output[4096]{};
        const int command_result = set_result
            ? unlha_w(nullptr, command.c_str(), output, _countof(output))
            : INT_MIN;
        const BOOL clear_result = clear();
        std::cout << mode << ".set=" << set_result << '\n'
                  << mode << ".command_result=" << command_result << '\n'
                  << mode << ".clear=" << clear_result << '\n'
                  << mode << ".count=" << progress_records.size() << '\n';
        for (size_t index = 0; index < progress_records.size(); ++index) {
            std::cout << mode << ".entry" << index << '=' << progress_records[index] << '\n';
        }
        std::cout << std::flush;
    };

    auto report = [&](const char* mode, ProgressLayout layout, DWORD struct_size,
                      FnSetOwnerEx legacy_setter) {
        progress_layout = layout;
        progress_result = TRUE;
        progress_abort_state = -1;
        progress_expected_owner = nullptr;
        progress_records.clear();
        const std::wstring mode_destination = make_mode_destination(mode);
        const std::wstring command = L"x -n1 -y " + quote_argument(archive_path) + L" " +
                                     quote_argument(mode_destination + L"\\");
        const BOOL set_result = legacy_setter
            ? legacy_setter(message_window, progress_probe)
            : set_64(message_window, progress_probe, struct_size);
        wchar_t output[4096]{};
        const int command_result = set_result
            ? unlha_w(nullptr, command.c_str(), output, _countof(output))
            : INT_MIN;
        const BOOL kill_result = legacy_setter ? kill(message_window) : kill_64(message_window);
        if (!kill_result) clear();
        std::cout << mode << ".set=" << set_result << '\n'
                  << mode << ".command_result=" << command_result << '\n'
                  << mode << ".kill=" << kill_result << '\n'
                  << mode << ".count=" << progress_records.size() << '\n';
        for (size_t index = 0; index < progress_records.size(); ++index) {
            std::cout << mode << ".entry" << index << '=' << progress_records[index] << '\n';
        }
        std::cout << std::flush;
    };

    if (!abort_only) {
        report_basic("basica", ProgressLayout::BasicA, set_basic_a);
        report_basic("basicw", ProgressLayout::BasicW, set_basic_w);
        report("exa", ProgressLayout::ExA, sizeof(EXTRACTINGINFOEXA), set_a);
        report("exw", ProgressLayout::ExW, sizeof(EXTRACTINGINFOEXW), set_w);
        report("ex32a", ProgressLayout::Ex32A, sizeof(EXTRACTINGINFOEX32A), nullptr);
        report("ex32w", ProgressLayout::Ex32W, sizeof(EXTRACTINGINFOEX32W), nullptr);
        report("ex64a", ProgressLayout::Ex64A, sizeof(EXTRACTINGINFOEX64A), nullptr);
        report("ex64w", ProgressLayout::Ex64W, sizeof(EXTRACTINGINFOEX64W), nullptr);

        const BOOL invalid_set = set_64(owner, progress_probe, sizeof(EXTRACTINGINFOEX64A) - 1);
        std::cout << "invalid.set=" << invalid_set << '\n';
        if (invalid_set) {
            std::cout << "invalid.kill=" << kill_64(owner) << '\n';
        }
        std::cout << std::flush;
        DestroyWindow(message_window);
        UnregisterClassW(window_class_name, window_class.hInstance);
        return 0;
    }

    progress_layout = ProgressLayout::Ex64W;
    progress_result = TRUE;
    progress_abort_state = ARCEXTRACT_INPROCESS;
    progress_expected_owner = message_window;
    progress_records.clear();
    const std::wstring abort_destination = make_mode_destination("abort");
    const std::wstring abort_command = L"x -n1 -y " + quote_argument(archive_path) + L" " +
                                       quote_argument(abort_destination + L"\\");
    const BOOL abort_set = set_64(message_window, progress_probe, sizeof(EXTRACTINGINFOEX64W));
    wchar_t abort_output[4096]{};
    const int abort_result = abort_set
        ? unlha_w(message_window, abort_command.c_str(), abort_output, _countof(abort_output))
        : INT_MIN;
    const BOOL abort_kill = kill_64(message_window);
    std::cout << "abort.set=" << abort_set << '\n'
              << "abort.command_result=" << abort_result << '\n'
              << "abort.kill=" << abort_kill << '\n'
              << "abort.count=" << progress_records.size() << '\n';
    for (size_t index = 0; index < progress_records.size(); ++index) {
        std::cout << "abort.entry" << index << '=' << progress_records[index] << '\n';
    }
    std::cout << std::flush;
    progress_abort_state = -1;
    DestroyWindow(message_window);
    UnregisterClassW(window_class_name, window_class.hInstance);
    return 0;
}

int run_progress_add_probe(const wchar_t* dll_path, const wchar_t* workspace, const int name_mode = 1) {
    Module module(dll_path);
    const auto unlha_w = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto set_64 = proc<FnSetOwnerEx64>(module.handle, "UnlhaSetOwnerWindowEx64");
    const auto kill_64 = proc<FnKillOwnerEx>(module.handle, "UnlhaKillOwnerWindowEx64");

    const std::wstring root(workspace);
    ensure_directory(root);
    const std::wstring source = root + L"\\progress-add.txt";
    const std::wstring archive = root + L"\\progress-add.lzh";
    std::vector<unsigned char> payload{
        'p', 'r', 'o', 'g', 'r', 'e', 's', 's', '-', 'a', 'd', 'd'
    };
    write_file(source, payload);
    set_file_times(source, 2026, 9, 4, 1, 2, 4);

    progress_layout = ProgressLayout::Ex64W;
    progress_result = TRUE;
    progress_abort_state = -1;
    progress_expected_owner = nullptr;
    progress_ignore_access_time = true;
    progress_records.clear();
    const BOOL set_result = set_64(nullptr, progress_probe, sizeof(EXTRACTINGINFOEX64W));
    const std::wstring command = L"a -n" + std::to_wstring(name_mode) + L" -y " + quote_argument(archive) + L" " +
                                 quote_argument(source);
    wchar_t output[4096]{};
    const int command_result = set_result
        ? unlha_w(nullptr, command.c_str(), output, _countof(output))
        : INT_MIN;
    const BOOL kill_result = kill_64(nullptr);

    std::cout << "add.set=" << set_result << '\n'
              << "add.command_result=" << command_result << '\n'
              << "add.kill=" << kill_result << '\n'
              << "add.count=" << progress_records.size() << '\n';
    for (size_t index = 0; index < progress_records.size(); ++index) {
        std::cout << "add.entry" << index << '=' << progress_records[index] << '\n';
    }
    progress_ignore_access_time = false;
    return 0;
}

int create_unicode_fixture(const wchar_t* dll_path, const wchar_t* archive_path,
                           const bool fixed_time = false) {
    Module module(dll_path);
    const auto compress_mem = proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW");
    std::vector<unsigned char> payload = {
        0x55, 0x6e, 0x4c, 0x68, 0x61, 0x52, 0x65, 0x00, 0xff, 0x10, 0x20, 0x30
    };
    const std::wstring command = quote_argument(archive_path) + L" " +
                                 quote_argument(L"\u2603-\u65E5\u672C\u8A9E.txt");
    const time_t timestamp = 1704164646;
    DWORD compressed = 0;
    const int result = compress_mem(nullptr, command.c_str(), payload.data(),
                                    static_cast<DWORD>(payload.size()),
                                    fixed_time ? &timestamp : nullptr, nullptr, &compressed);
    if (result != 0 || compressed == 0 || GetFileAttributesW(archive_path) == INVALID_FILE_ATTRIBUTES) {
        std::cerr << "unicode fixture creation failed rc=" << result << " written=" << compressed << '\n';
        return 1;
    }
    std::cout << "unicode fixture created\n";
    return 0;
}

int run_dos_time_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto compress_mem = proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW");
    const auto open = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto find_a = proc<FnFindFirst>(module.handle, "UnlhaFindFirst");
    const auto find_w = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    const auto get_date = proc<FnWordHarc>(module.handle, "UnlhaGetDate");
    const auto get_time = proc<FnWordHarc>(module.handle, "UnlhaGetTime");
    const auto set_owner = proc<FnSetOwnerEx>(module.handle, "UnlhaSetOwnerWindowExW");
    const auto kill_owner = proc<FnKillOwnerEx>(module.handle, "UnlhaKillOwnerWindowEx");
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const std::wstring root(workspace);
    ensure_directory(root);
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = progress_window_proc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"UnLhaReDosTimeProgress";
    if (!RegisterClassW(&window_class)) throw std::runtime_error("DOS time: cannot register window");
    const HWND message_window = CreateWindowExW(0, window_class.lpszClassName, L"", 0,
        0, 0, 0, 0, HWND_MESSAGE, nullptr, window_class.hInstance, nullptr);
    if (!message_window) throw std::runtime_error("DOS time: cannot create window");
    const int cases[][6] = {
        {2024, 3, 4, 1, 1, 0}, {2024, 3, 4, 1, 1, 1}, {2024, 3, 4, 1, 1, 2},
        {2024, 3, 4, 1, 1, 57}, {2024, 3, 4, 1, 1, 58}, {2024, 3, 4, 1, 1, 59},
        {2024, 3, 4, 1, 59, 59}, {2024, 3, 4, 23, 59, 59},
        {2024, 1, 31, 23, 59, 59}, {2024, 2, 28, 23, 59, 59},
        {2024, 2, 29, 23, 59, 59}, {1999, 12, 31, 23, 59, 59}
    };
    for (size_t index = 0; index < _countof(cases); ++index) {
        const auto& fields = cases[index];
        std::tm local{};
        local.tm_year = fields[0] - 1900;
        local.tm_mon = fields[1] - 1;
        local.tm_mday = fields[2];
        local.tm_hour = fields[3];
        local.tm_min = fields[4];
        local.tm_sec = fields[5];
        local.tm_isdst = -1;
        const time_t timestamp = std::mktime(&local);
        if (timestamp < 0) throw std::runtime_error("DOS time: invalid test timestamp");
        const std::wstring archive_path = root + L"\\time-" + std::to_wstring(index) + L".lzh";
        const std::wstring memory_command = quote_argument(archive_path) + L" time.bin";
        unsigned char payload = 0x41;
        DWORD written = 0;
        if (compress_mem(nullptr, memory_command.c_str(), &payload, 1, &timestamp, nullptr, &written) != 0) {
            throw std::runtime_error("DOS time: cannot create fixture");
        }
        HARC archive = open(nullptr, archive_path.c_str(), 0);
        if (!archive) throw std::runtime_error("DOS time: cannot open fixture");
        INDIVIDUALINFOA narrow{};
        INDIVIDUALINFOW wide{};
        const int result_a = find_a(archive, "*", &narrow);
        const WORD api_date = get_date(archive);
        const WORD api_time = get_time(archive);
        close(archive);
        archive = open(nullptr, archive_path.c_str(), 0);
        if (!archive) throw std::runtime_error("DOS time: cannot reopen fixture");
        const int result_w = find_w(archive, L"*", &wide);
        close(archive);
        if (result_a || result_w) throw std::runtime_error("DOS time: cannot enumerate fixture");
        std::cout << "time." << index << ".metadata=" << narrow.wDate << ',' << narrow.wTime
                  << ',' << wide.wDate << ',' << wide.wTime << ',' << api_date << ',' << api_time << '\n';

        const std::wstring destination = root + L"\\out-" + std::to_wstring(index);
        ensure_directory(destination);
        progress_layout = ProgressLayout::ExW;
        progress_result = TRUE;
        progress_abort_state = -1;
        progress_expected_owner = nullptr;
        progress_records.clear();
        if (!set_owner(message_window, progress_probe)) throw std::runtime_error("DOS time: cannot set callback");
        wchar_t output[4096]{};
        const std::wstring command = L"x -y -n1 " + quote_argument(archive_path) + L" " +
                                     quote_argument(destination + L"\\");
        const int result = unlha(nullptr, command.c_str(), output, _countof(output));
        if (!kill_owner(message_window)) proc<FnBool0>(module.handle, "UnlhaClearOwnerWindow")();
        if (result != 0) throw std::runtime_error("DOS time: cannot extract fixture");
        if (progress_records.size() != 6) throw std::runtime_error("DOS time: missing progress records");
        std::cout << "time." << index << ".progress-count=" << progress_records.size() << '\n';
        for (const auto& record : progress_records) {
            std::cout << "time." << index << ".progress=" << record << '\n';
        }
        std::cout << std::flush;
    }
    DestroyWindow(message_window);
    UnregisterClassW(window_class.lpszClassName, window_class.hInstance);
    return 0;
}

int run_archive_path_probe(const wchar_t* dll_path, const wchar_t* input_path,
                            const wchar_t* next_directory, const wchar_t* encoding, const int only_api = -1) {
    const bool utf8 = std::wcscmp(encoding, L"utf8") == 0;
    const LCID original_locale = GetThreadLocale();
    struct RestoreLocale {
        LCID locale;
        ~RestoreLocale() { SetThreadLocale(locale); }
    } restore_locale{original_locale};
    if (std::wcscmp(encoding, L"ansi-ja") == 0 && !SetThreadLocale(1041))
        throw std::runtime_error("cannot set Japanese thread locale");
    Module module(dll_path);
    if (utf8) proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    if (only_api >= 0)
        std::cout << "environment=" << GetACP() << ',' << GetOEMCP() << ',' << GetThreadLocale() << '\n';
    wchar_t original_directory[32768]{};
    const DWORD directory_size = GetCurrentDirectoryW(_countof(original_directory), original_directory);
    if (!directory_size || directory_size >= _countof(original_directory))
        throw std::runtime_error("cannot capture current directory");
    struct RestoreDirectory {
        const wchar_t* path;
        ~RestoreDirectory() { SetCurrentDirectoryW(path); }
    } restore{original_directory};
    char path_a[32768]{};
    BOOL substituted = FALSE;
    // ANSI API は OS の ACP ではなく、呼び出しスレッドの ACP を使う。
    const UINT input_code_page = utf8 ? CP_UTF8 : std::wcscmp(encoding, L"cp932-input") == 0 ? 932 : CP_THREAD_ACP;
    const bool ansi_path = WideCharToMultiByte(input_code_page,
        utf8 ? 0 : WC_NO_BEST_FIT_CHARS, input_path, -1, path_a, sizeof(path_a),
        nullptr, utf8 ? nullptr : &substituted) > 0 && !substituted;
    const char* open_names[] = {"UnlhaOpenArchive", "UnlhaOpenArchiveA", "UnlhaOpenArchiveW",
        "UnlhaOpenArchive2", "UnlhaOpenArchive2A", "UnlhaOpenArchive2W"};
    const char* getter_names[] = {"UnlhaGetArcFileName", "UnlhaGetArcFileNameA", "UnlhaGetArcFileNameW"};
    const DWORD mode = M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF;
    for (int api = 0; api < 6; ++api) {
        if (only_api >= 0 && api != only_api) continue;
        if (!SetCurrentDirectoryW(original_directory)) throw std::runtime_error("cannot restore current directory");
        const bool wide_open = api == 2 || api == 5;
        if (!wide_open && !ansi_path) {
            std::cout << "api=" << api << "|not-representable\n";
            continue;
        }
        HARC archive = nullptr;
        if (api < 3) archive = wide_open
            ? proc<FnOpenW>(module.handle, open_names[api])(nullptr, input_path, mode)
            : proc<FnOpen>(module.handle, open_names[api])(nullptr, path_a, mode);
        else archive = wide_open
            ? proc<HARC(WINAPI*)(HWND, LPCWSTR, DWORD, LPCWSTR)>(module.handle, open_names[api])(
                nullptr, input_path, mode, L"")
            : proc<HARC(WINAPI*)(HWND, LPCSTR, DWORD, LPCSTR)>(module.handle, open_names[api])(
                nullptr, path_a, mode, "");
        std::cout << "api=" << api << "|opened=" << (archive != nullptr) << '\n';
        if (only_api >= 0) {
            DWORD system_error = 0;
            const int last = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
            std::cout << "open.last=" << last << "|system=" << system_error << '\n';
        }
        if (!archive) continue;
        for (int phase = 0; phase < 2; ++phase) {
            if (phase == 1 && !SetCurrentDirectoryW(next_directory))
                throw std::runtime_error("cannot change directory after opening archive");
            for (int getter = 0; getter < 3; ++getter) {
                for (const int capacity : {1, 2, 3, 17, 79, 260, 512, 513, 1024}) {
                    std::vector<wchar_t> storage(1040, 0x5a5a);
                    BYTE* const bytes = reinterpret_cast<BYTE*>(storage.data());
                    SetLastError(0x12345678U);
                    const int result = getter == 2
                        ? proc<int(WINAPI*)(HARC, LPWSTR, int)>(module.handle, getter_names[getter])(
                            archive, storage.data() + 4, capacity)
                        : proc<FnGetString>(module.handle, getter_names[getter])(
                            archive, reinterpret_cast<char*>(bytes + 8), capacity);
                    const DWORD win32_error = GetLastError();
                    DWORD system_error = 0;
                    const int last = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
                    std::uint32_t hash = 2166136261U;
                    for (size_t index = 0; index < storage.size() * sizeof(wchar_t); ++index)
                        hash = (hash ^ bytes[index]) * 16777619U;
                    const std::wstring wide_value(storage.data() + 4,
                        wcsnlen(storage.data() + 4, getter == 2 ? capacity : 0));
                    const std::string ansi_value(reinterpret_cast<char*>(bytes + 8),
                        strnlen(reinterpret_cast<char*>(bytes + 8), getter == 2 ? 0 : capacity));
                    std::cout << "api=" << api << "|phase=" << phase << "|getter=" << getter
                        << "|capacity=" << capacity << "|result=" << result << "|win32=" << win32_error
                        << "|last=" << last << "|system=" << system_error << "|buffer=" << hash
                        << "|name=" << (getter == 2 ? quote_wide(wide_value.c_str()) : quote_bytes(ansi_value.c_str())) << '\n';
                }
            }
        }
        proc<FnClose>(module.handle, "UnlhaCloseArchive")(archive);
    }
    return 0;
}

int run_getter_buffer_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                            const wchar_t* encoding, const bool zero_safety = false) {
    const LCID original_locale = GetThreadLocale();
    struct RestoreLocale {
        LCID locale;
        ~RestoreLocale() { SetThreadLocale(locale); }
    } restore_locale{original_locale};
    if (std::wcscmp(encoding, L"ansi-ja") == 0 && !SetThreadLocale(1041))
        throw std::runtime_error("cannot set Japanese thread locale");
    Module module(dll_path);
    if (std::wcscmp(encoding, L"utf8") == 0)
        proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    HARC archive = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW")(
        nullptr, archive_path, M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
    if (!archive) throw std::runtime_error("getter buffers: cannot open fixture");
    const char* getters[] = {"UnlhaGetArcFileName", "UnlhaGetArcFileNameA", "UnlhaGetArcFileNameW",
        "UnlhaGetFileName", "UnlhaGetFileNameA", "UnlhaGetFileNameW",
        "UnlhaGetMethod", "UnlhaGetMethodA", "UnlhaGetMethodW"};
    for (int phase = 0; phase < 4; ++phase) {
        if (phase == 1 && proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW")(archive, L"*", nullptr) != 0)
            throw std::runtime_error("getter buffers: fixture has no first entry");
        if (phase == 2) while (proc<FnFindNextW>(module.handle, "UnlhaFindNextW")(archive, nullptr) == 0) {}
        if (phase == 3) {
            proc<FnClose>(module.handle, "UnlhaCloseArchive")(archive);
            archive = nullptr;
        }
        for (int getter = 0; getter < _countof(getters); ++getter) {
            const bool wide = getter % 3 == 2;
            for (const bool null_buffer : {false, true}) {
                for (const int capacity : {-1, 0, 1, 2, 3, 4, 5, 6, 7, 17, 79, 260, 512, 513, 1024}) {
                    // 原版 ANSI のサイズ 0 はバッファ直前へ書くので、比較対象には含めない。
                    if (zero_safety) {
                        if (wide || null_buffer || capacity != 0) continue;
                    } else if (!wide && !null_buffer && capacity == 0) continue;
                    std::vector<wchar_t> storage(1040, 0x5a5a);
                    BYTE* const bytes = reinterpret_cast<BYTE*>(storage.data());
                    SetLastError(0x12345678U);
                    const int result = wide
                        ? proc<int(WINAPI*)(HARC, LPWSTR, int)>(module.handle, getters[getter])(
                            archive, null_buffer ? nullptr : storage.data() + 4, capacity)
                        : proc<FnGetString>(module.handle, getters[getter])(
                            archive, null_buffer ? nullptr : reinterpret_cast<char*>(bytes + 8), capacity);
                    const DWORD win32_error = GetLastError();
                    DWORD system_error = 0;
                    const int last = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
                    std::uint32_t hash = 2166136261U;
                    for (size_t index = 0; index < storage.size() * sizeof(wchar_t); ++index)
                        hash = (hash ^ bytes[index]) * 16777619U;
                    if (zero_safety) {
                        const int expected_result = phase == 3 ? ERROR_HARC_ISNOT_OPENED
                            : getter >= 3 && phase != 1 ? ERROR_NOT_SEARCH_MODE : 0;
                        if (result != expected_result || !std::all_of(storage.begin(), storage.end(),
                                [](wchar_t value) { return value == 0x5a5a; }))
                            throw std::runtime_error("getter size zero modified memory or returned an unexpected status");
                    }
                    std::cout << "phase=" << phase << "|getter=" << getter << "|null=" << null_buffer
                        << "|capacity=" << capacity << "|result=" << result << "|win32=" << win32_error
                        << "|last=" << last << "|system=" << system_error << "|buffer=" << hash << '\n';
                }
            }
        }
    }
    return 0;
}

BOOL CALLBACK open_state_progress(HWND, UINT, UINT, LPVOID) { return TRUE; }
BOOL CALLBACK open_state_enum(LPVOID) { return TRUE; }

int create_open_size_fixtures(const wchar_t* archive_path, const wchar_t* workspace) {
    ensure_directory(workspace);
    const auto original = read_file(archive_path);
    for (const size_t size : {55U, 64U, 79U, 80U, 81U, 100U, 127U, 128U, 129U,
            255U, 256U, 257U, 511U, 512U, 513U, 1023U, 1024U, 4096U}) {
        if (size < original.size()) continue;
        auto bytes = original;
        bytes.resize(size, 0);
        write_file(std::wstring(workspace) + L"\\size-" + std::to_wstring(size) + L".lzh", bytes);
    }
    if (original.size() < 80) {
        for (const DWORD offset : {0U, 1U, 80U, 122U, 124U, 125U, 126U, 127U, 128U, 129U, MAXDWORD}) {
            for (const bool zip : {false, true}) {
                auto bytes = original;
                bytes.resize(128, 0);
                if (zip) {
                    bytes[80] = 'P'; bytes[81] = 'K'; bytes[82] = 1; bytes[83] = 2;
                }
                for (size_t index = 0; index < 4; ++index)
                    bytes[122 + index] = static_cast<unsigned char>(offset >> (index * 8));
                write_file(std::wstring(workspace) + L"\\tail-" + std::to_wstring(offset) +
                    (zip ? L"-zip.lzh" : L".lzh"), bytes);
            }
        }
    }
    if (original.size() == 55 && original[20] == 1 &&
        std::all_of(original.begin() + 11, original.begin() + 15,
                    [](unsigned char value) { return value == 0; })) {
        for (const char method : std::string("01234567x")) {
            auto bytes = original;
            bytes[5] = method;
            unsigned checksum = 0;
            for (size_t index = 2; index < static_cast<size_t>(bytes[0]) + 2; ++index)
                checksum += bytes[index];
            bytes[1] = static_cast<unsigned char>(checksum);
            bytes.resize(128, 0);
            write_file(std::wstring(workspace) + L"\\empty-lh" + static_cast<wchar_t>(method) + L".lzh", bytes);
        }
    }
    return 0;
}

int run_archive_tail_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                           const bool suppress_progress = false) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const std::wstring path(archive_path);
    const std::wstring inputs[] = {path, quote_argument(path), L"\"" + path,
        L"", path + L".missing", path.substr(0, path.find_last_of(L"/\\"))};
    const char* count_names[] = {"UnlhaGetFileCount", "UnlhaGetFileCountA", "UnlhaGetFileCountW"};
    for (int api = 0; api < _countof(count_names); ++api) {
        for (int input = 0; input <= _countof(inputs); ++input) {
            const wchar_t* value = input == _countof(inputs) ? nullptr : inputs[input].c_str();
            char narrow[32768]{};
            if (value && !WideCharToMultiByte(CP_UTF8, 0, value, -1, narrow, sizeof(narrow), nullptr, nullptr))
                throw std::runtime_error("archive tail: cannot encode count path");
            const int result = api == 2
                ? proc<FnCountW>(module.handle, count_names[api])(value)
                : proc<int(WINAPI*)(LPCSTR)>(module.handle, count_names[api])(value ? narrow : nullptr);
            DWORD system = 0;
            const int error = last_error(&system);
            std::cout << "tail.count." << api << '.' << input << '=' << result
                      << ",error=" << error << ",system=" << system
                      << ",running=" << proc<FnBool0>(module.handle, "UnlhaGetRunning")() << std::endl;
        }
    }
    const char* memory_names[] = {"UnlhaExtractMem", "UnlhaExtractMemA", "UnlhaExtractMemW"};
    const wchar_t* switches[] = {L"-gm1", L"-gm1 -jsg0", L"-gm1 -jsg1", L"-gm1 -jsg1 -jsg0"};
    for (int api = 0; api < _countof(memory_names); ++api) {
        for (int option = 0; option < _countof(switches); ++option) {
            for (const bool selected : {false, true}) {
                const std::wstring command = std::wstring(switches[option])
                    + (suppress_progress ? L" -n1 " : L" ") + quote_argument(path)
                    + (selected ? L" *" : L" missing");
                char narrow[32768]{};
                if (!WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, narrow, sizeof(narrow), nullptr, nullptr))
                    throw std::runtime_error("archive tail: cannot encode memory command");
                for (const DWORD capacity : {0U, 1U, 64U}) {
                    unsigned char buffer[80];
                    std::fill(std::begin(buffer), std::end(buffer), 0xcc);
                    DWORD written = 123456;
                    time_t timestamp = 123456;
                    WORD attributes = 12345;
                    const int result = api == 2
                        ? proc<FnExtractMemW>(module.handle, memory_names[api])(nullptr, command.c_str(),
                            buffer, capacity, &timestamp, &attributes, &written)
                        : proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                            module.handle, memory_names[api])(nullptr, narrow, buffer, capacity,
                            &timestamp, &attributes, &written);
                    DWORD system = 0;
                    const int error = last_error(&system);
                    std::uint32_t hash = 2166136261U;
                    for (const unsigned char byte : buffer) hash = (hash ^ byte) * 16777619U;
                    std::cout << "tail.memory." << api << '.' << option << '.' << selected << '.' << capacity
                              << '=' << result << ",error=" << error << ",system=" << system
                              << ",written=" << written << ",time=" << static_cast<long long>(timestamp)
                              << ",attr=" << attributes << ",hash=" << hash << std::endl;
                }
            }
        }
    }
    return 0;
}

int run_open_state_probe(const wchar_t* dll_path, const wchar_t* valid_path,
                          const wchar_t* initial_path, const int api, const wchar_t* action,
                          const bool owned = false) {
    struct ProbeWindow {
        HWND handle = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
        ~ProbeWindow() { if (handle) DestroyWindow(handle); }
    } window;
    if (!window.handle) throw std::runtime_error("open state: cannot create message-only window");
    const HWND owner = owned ? window.handle : nullptr;
    Module module(dll_path);
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const auto running = proc<FnBool0>(module.handle, "UnlhaGetRunning");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    const auto open_w = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const DWORD mode = M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF;
    bool undefined_busy_error = false;
    const auto report = [&](const char* label, const auto result) {
        DWORD system_error = 0;
        const int error = last_error(&system_error);
        std::cout << label << '=' << result << "|last=";
        if (undefined_busy_error) std::cout << "undefined-busy";
        else std::cout << error;
        std::cout << "|system=" << system_error << '\n';
    };
    const wchar_t* path = std::wcscmp(initial_path, L"@null") == 0 ? nullptr
        : std::wcscmp(initial_path, L"@empty") == 0 ? L""
        : std::wcscmp(initial_path, L"@valid") == 0 ? valid_path : initial_path;
    char path_a[32768]{};
    if (path && !WideCharToMultiByte(CP_THREAD_ACP, 0, path, -1, path_a, sizeof(path_a), nullptr, nullptr))
        throw std::runtime_error("open state: cannot encode initial path");
    const char* names[] = {"UnlhaOpenArchive", "UnlhaOpenArchiveA", "UnlhaOpenArchiveW",
        "UnlhaOpenArchive2", "UnlhaOpenArchive2A", "UnlhaOpenArchive2W"};
    if (api < 0 || api >= _countof(names)) throw std::runtime_error("open state: unknown open API");
    const bool wide = api == 2 || api == 5;
    HARC initial = nullptr;
    if (api < 3) initial = wide ? open_w(owner, path, mode)
        : proc<FnOpen>(module.handle, names[api])(owner, path ? path_a : nullptr, mode);
    else initial = wide
        ? proc<HARC(WINAPI*)(HWND, LPCWSTR, DWORD, LPCWSTR)>(module.handle, names[api])(owner, path, mode, L"")
        : proc<HARC(WINAPI*)(HWND, LPCSTR, DWORD, LPCSTR)>(module.handle, names[api])(
            owner, path ? path_a : nullptr, mode, "");
    if (!path) {
        // 原版の NULL 入力は未初期化 HARC を返す。利用せず、定義済みの状態だけ比較する。
        report("initial", "undefined-null-handle");
        initial = nullptr;
    } else report("initial", initial != nullptr);
    report("running.initial", running());
    const std::wstring command = L"l -gm1 " + quote_argument(valid_path);
    if (std::wcscmp(action, L"settings") == 0) {
        report("get-cp", proc<FnUInt0>(module.handle, "UnlhaGetCP")());
        report("set-cp", proc<FnBoolUInt>(module.handle, "UnlhaSetCP")(65001));
        report("unicode", proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE));
    } else if (std::wcscmp(action, L"close-null") == 0) {
        report("close-null", close(nullptr));
    } else if (std::wcscmp(action, L"check-w") == 0) {
        report("check", proc<FnCheckW>(module.handle, "UnlhaCheckArchiveW")(valid_path, 0));
    } else if (std::wcscmp(action, L"command-w") == 0) {
        wchar_t output[4096] = L"sentinel";
        report("command", proc<FnUnlhaW>(module.handle, "UnlhaW")(nullptr, command.c_str(), output, _countof(output)));
        std::cout << "command.output=" << quote_wide(output) << '\n';
    } else if (std::wcscmp(action, L"count-w") == 0) {
        report("count", proc<FnCountW>(module.handle, "UnlhaGetFileCountW")(valid_path));
    } else if (std::wcscmp(action, L"memory-w") == 0) {
        std::vector<unsigned char> output(65536, 0x5a);
        const std::wstring memory_command = L"-gm1 " + quote_argument(valid_path) + L" *";
        DWORD written = 12345;
        report("memory", proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
            nullptr, memory_command.c_str(), output.data(), static_cast<DWORD>(output.size()), nullptr, nullptr, &written));
        std::cout << "memory.written=" << written << '\n';
    } else if (std::wcscmp(action, L"compress-state") == 0) {
        if (!initial) throw std::runtime_error("compression state requires an archive handle");
        const auto compress = proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW");
        for (int phase = 0; phase < 12; ++phase) {
            INDIVIDUALINFOW info{};
            int found = 0;
            if (phase == 1) found = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW")(initial, L"*", &info);
            else if (phase > 1) found = proc<FnFindNextW>(module.handle, "UnlhaFindNextW")(initial, &info);
            DWORD written = 12345;
            const time_t timestamp = 1700000000;
            WORD attributes = FILE_ATTRIBUTE_ARCHIVE;
            report("compress-state", compress(nullptr, L"", nullptr, 0, &timestamp, &attributes, &written));
            std::cout << "compress-state." << phase << "|found=" << found << "|written=" << written
                      << "|original=" << info.dwOriginalSize << "|compressed=" << info.dwCompressedSize << '\n';
            if (found != 0) break;
        }
    } else if (std::wcscmp(action, L"guards") == 0) {
        if (!running()) throw std::runtime_error("open state: busy guards require an active state");
        report("cursor-interval", proc<FnWordWord>(module.handle, "UnlhaSetCursorInterval")(5));
        report("background", proc<FnBoolBool>(module.handle, "UnlhaSetBackGroundMode")(FALSE));
        report("cursor", proc<FnBoolBool>(module.handle, "UnlhaSetCursorMode")(FALSE));
        report("priority", proc<FnIntInt>(module.handle, "UnlhaSetPriority")(0));
        report("owner", proc<FnSetOwner>(module.handle, "UnlhaSetOwnerWindow")(window.handle));
        report("owner-ex", proc<FnSetOwnerEx>(module.handle, "UnlhaSetOwnerWindowExW")(window.handle, open_state_progress));
        report("enum-a", proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcA")(open_state_enum));
        report("enum-w", proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(open_state_enum));
        report("enum-clear", proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")());
        report("config", proc<FnConfigW>(module.handle, "UnlhaConfigDialogW")(nullptr, nullptr, 0));
        DWORD written = 12345;
        report("compress", proc<FnCompressMemW>(module.handle, "UnlhaCompressMemW")(
            nullptr, L"", nullptr, 0, nullptr, nullptr, &written));
        std::cout << "compress.written=" << written << '\n';
    } else if (std::wcscmp(action, L"api-variants") == 0) {
        if (!running()) throw std::runtime_error("open state: API variants require an active state");
        char valid_a[32768]{};
        WideCharToMultiByte(CP_THREAD_ACP, 0, valid_path, -1, valid_a, sizeof(valid_a), nullptr, nullptr);
        const std::string command_a = "l -gm1 \"" + std::string(valid_a) + "\"";
        for (const char* name : {"Unlha", "UnlhaA"}) {
            char output[32] = "sentinel";
            report(name, proc<FnUnlhaA>(module.handle, name)(owner, command_a.c_str(), output, sizeof(output)));
            std::cout << name << ".output=" << quote_bytes(output) << '\n';
        }
        for (const char* name : {"UnlhaCheckArchive", "UnlhaCheckArchiveA"})
            report(name, proc<FnCheck>(module.handle, name)(valid_a, 0));
        for (const char* name : {"UnlhaGetFileCount", "UnlhaGetFileCountA"})
            report(name, proc<FnCount>(module.handle, name)(valid_a));
        for (const char* name : {"UnlhaConfigDialog", "UnlhaConfigDialogA"})
            report(name, proc<FnConfigA>(module.handle, name)(owner, nullptr, 0));
        for (const char* name : {"UnlhaExtractMem", "UnlhaExtractMemA"}) {
            unsigned char output[16]{};
            DWORD written = 12345;
            report(name, proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(module.handle, name)(
                owner, "", output, sizeof(output), nullptr, nullptr, &written));
            std::cout << name << ".written=" << written << '\n';
        }
        for (const char* name : {"UnlhaCompressMem", "UnlhaCompressMemA"}) {
            DWORD written = 12345;
            report(name, proc<int(WINAPI*)(HWND, LPCSTR, const LPBYTE, DWORD, const time_t*, const LPWORD, LPDWORD)>(
                module.handle, name)(owner, "", nullptr, 0, nullptr, nullptr, &written));
            std::cout << name << ".written=" << written << '\n';
        }
    } else if (std::wcscmp(action, L"retry") != 0) {
        throw std::runtime_error("open state: unknown action");
    }
    report("running.action", running());
    // 0x1000776b は未初期化ローカルを最終エラーへコピーする。システムエラーは比較する。
    undefined_busy_error = running() != FALSE;
    HARC retry = open_w(owner, valid_path, mode);
    report("retry", retry != nullptr);
    report("running.retry", running());
    if (retry) { undefined_busy_error = false; report("retry.close", close(retry)); }
    if (initial) {
        undefined_busy_error = false;
        report("initial.close", close(initial));
        HARC reopened = open_w(owner, valid_path, mode);
        report("after-close.open", reopened != nullptr);
        if (reopened) report("after-close.close", close(reopened));
    }
    report("running.end", running());
    return 0;
}

int run_attribute_probe(const wchar_t* dll_path, const wchar_t* archive_path, const bool audit = false) {
    const auto trace = [audit](const char* stage, const int api, const int result, const size_t count) {
        if (!audit) return;
        const DWORD saved_error = GetLastError();
        DWORD flags = 0;
        SetLastError(0);
        const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
        const BOOL valid = GetHandleInformation(output, &flags);
        const DWORD error = GetLastError();
        // stderr に直接記録し、cout の暗黙フラッシュで観測対象を変えない。
        std::fprintf(stderr, "attribute-audit stage=%s,pid=%lu,api=%d,result=%d,count=%zu,stdout=%p,valid=%d,error=%lu,good=%d\n",
            stage, GetCurrentProcessId(), api, result, count, output, valid, error, std::cout.good());
        SetLastError(saved_error);
    };
    trace("begin", -1, 0, 0);
    struct UnloadAudit final {
        decltype(trace)& callback;
        ~UnloadAudit() {
            callback("unloaded", -1, 0, 0);
        }
    } unload_audit{trace};
    Module module(dll_path);
    trace("loaded", -1, 0, 0);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const int encoded_size = WideCharToMultiByte(CP_UTF8, 0, archive_path, -1, nullptr, 0, nullptr, nullptr);
    if (!encoded_size) throw std::runtime_error("attribute probe: cannot encode archive path");
    std::vector<char> encoded_path(encoded_size);
    WideCharToMultiByte(CP_UTF8, 0, archive_path, -1, encoded_path.data(), encoded_size, nullptr, nullptr);
    std::vector<std::wstring> members;
    const char* first_names[] = {"UnlhaFindFirst", "UnlhaFindFirstA", "UnlhaFindFirstW"};
    const char* next_names[] = {"UnlhaFindNext", "UnlhaFindNextA", "UnlhaFindNextW"};
    const char* open_names[] = {"UnlhaOpenArchive", "UnlhaOpenArchiveA", "UnlhaOpenArchiveW"};
    for (int api = 0; api < 3; ++api) {
        const DWORD mode = M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF;
        HARC archive = api == 2
            ? proc<FnOpenW>(module.handle, open_names[api])(nullptr, archive_path, mode)
            : proc<FnOpen>(module.handle, open_names[api])(nullptr, encoded_path.data(), mode);
        if (!archive) throw std::runtime_error("attribute probe: cannot open archive");
        trace("opened", api, 0, 0);
        int result = 0;
        for (size_t index = 0;; ++index) {
            INDIVIDUALINFOA info_a{};
            INDIVIDUALINFOW info_w{};
            result = api == 2
                ? (index == 0 ? proc<FnFindFirstW>(module.handle, first_names[api])(archive, L"*", &info_w)
                              : proc<FnFindNextW>(module.handle, next_names[api])(archive, &info_w))
                : (index == 0 ? proc<FnFindFirst>(module.handle, first_names[api])(archive, "*", &info_a)
                              : proc<FnFindNext>(module.handle, next_names[api])(archive, &info_a));
            trace("find", api, result, index);
            if (result != 0) break;
            if (api == 2) members.emplace_back(info_w.szFileName);
            std::cout << "attribute." << api << '.' << index << "=name="
                      << (api == 2 ? quote_wide(info_w.szFileName) : quote_bytes(info_a.szFileName))
                      << ",text=" << (api == 2 ? quote_wide(info_w.szAttribute) : quote_bytes(info_a.szAttribute))
                      << ",value=" << proc<FnIntHarc>(module.handle, "UnlhaGetAttribute")(archive)
                      << ",alias=" << proc<FnIntHarc>(module.handle, "UnlhaGetAttributes")(archive) << '\n';
        }
        proc<FnClose>(module.handle, "UnlhaCloseArchive")(archive);
        trace("closed", api, result, members.size());
        if (result != -1) throw std::runtime_error("attribute probe: unexpected enumeration result");
    }
    const char* memory_names[] = {"UnlhaExtractMem", "UnlhaExtractMemA", "UnlhaExtractMemW"};
    for (int api = 0; api < 3; ++api) {
        for (size_t index = 0; index < members.size(); ++index) {
            const std::wstring command = L"-gm1 " + quote_argument(archive_path) + L" " + quote_argument(members[index]);
            const int size = WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, nullptr, 0, nullptr, nullptr);
            std::vector<char> encoded(size);
            WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, encoded.data(), size, nullptr, nullptr);
            unsigned char buffer[4096];
            std::fill(std::begin(buffer), std::end(buffer), 0xcc);
            time_t timestamp = 123456;
            WORD attributes = 0xabcd;
            DWORD written = 123456;
            const int result = api == 2
                ? proc<FnExtractMemW>(module.handle, memory_names[api])(nullptr, command.c_str(),
                    buffer, sizeof(buffer), &timestamp, &attributes, &written)
                : proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                    module.handle, memory_names[api])(nullptr, encoded.data(), buffer, sizeof(buffer),
                    &timestamp, &attributes, &written);
            DWORD system = 0;
            const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
            trace("memory", api, result, index);
            std::uint32_t hash = 2166136261U;
            for (const auto value : buffer) hash = (hash ^ value) * 16777619U;
            std::cout << "attribute.memory." << api << '.' << index << "=result=" << result
                      << ",error=" << error << ",system=" << system << ",value=" << attributes
                      << ",written=" << written << ",time=" << static_cast<long long>(timestamp)
                      << ",hash=" << hash << '\n';
        }
    }
    trace("end", -1, 0, members.size());
    // DLL 解放・プロセス終了時の暗黙フラッシュに結果の保存を委ねない。
    std::cout.flush();
    trace("flushed", -1, 0, members.size());
    if (!std::cout.good()) throw std::runtime_error("attribute probe: cannot flush output");
    return 0;
}

int run_find_state_probe(const wchar_t* dll_path, const wchar_t* workspace,
                          const wchar_t* input_archive) {
    Module module(dll_path);
    const auto open = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto first_a = proc<FnFindFirst>(module.handle, "UnlhaFindFirst");
    const auto first_w = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW");
    const auto next_a = proc<FnFindNext>(module.handle, "UnlhaFindNext");
    const auto next_w = proc<FnFindNextW>(module.handle, "UnlhaFindNextW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const std::wstring root(workspace);
    ensure_directory(root);
    std::wstring path = root + L"\\state.lzh";
    if (input_archive) path = input_archive;
    else {
        const std::wstring source = root + L"\\input";
        ensure_directory(source);
        ensure_directory(source + L"\\dir");
        const wchar_t* names[] = {L"a.txt", L"b.log", L"dir\\c.txt", L"dir\\d.log", L"z"};
        std::wstring command = L"a -y -gm1 -jm0 -x1 " + quote_argument(path) + L" " +
                               quote_argument(source + L"\\");
        for (size_t index = 0; index < _countof(names); ++index) {
            const std::wstring file = source + L"\\" + names[index];
            write_file(file, std::vector<unsigned char>(3 + index * 2, 0x41));
            set_file_times(file, 2024, 1, 2, 3, 4, 6);
            command += L" " + quote_argument(names[index]);
        }
        wchar_t output[4096]{};
        if (proc<FnUnlhaW>(module.handle, "UnlhaW")(nullptr, command.c_str(), output, _countof(output)))
            throw std::runtime_error("find state: cannot create fixture");
    }
    struct Operation { bool first; const wchar_t* pattern; bool null_output; };
    const std::vector<std::vector<Operation>> sequences = {
        {{false, nullptr, false}, {true, L"*", false}, {false, nullptr, false},
         {true, L"*", false}, {false, nullptr, false}, {false, nullptr, false},
         {false, nullptr, false}, {false, nullptr, false}, {true, L"*", false},
         {false, nullptr, false}},
        {{true, L"missing", false}, {false, nullptr, false}, {true, L"*", false},
         {false, nullptr, false}},
        {{true, L"*", true}, {false, nullptr, true}, {true, L"b.log", false},
         {false, nullptr, false}, {true, L"*", false}},
        {{true, L"a.txt", false}, {true, L"z", false}, {false, nullptr, false},
         {true, L"*", false}},
        {{true, L"b.log", false}, {false, nullptr, false}, {true, L"*", false}},
        {{true, L"", false}, {false, nullptr, false}}
    };
    for (int layout = 0; layout < 3; ++layout) {
        for (size_t sequence = 0; sequence < sequences.size(); ++sequence) {
            HARC archive = open(nullptr, path.c_str(), M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
            if (!archive) throw std::runtime_error("find state: cannot open fixture");
            bool had_match = false;
            for (size_t step = 0; step < sequences[sequence].size(); ++step) {
                const auto& operation = sequences[sequence][step];
                const bool wide = layout == 1 || (layout == 2 && step % 2 != 0);
                INDIVIDUALINFOA info_a{};
                INDIVIDUALINFOW info_w{};
                strcpy_s(info_a.szFileName, "sentinel");
                wcscpy_s(info_w.szFileName, L"sentinel");
                const std::wstring pattern_w = operation.pattern ? operation.pattern : L"";
                std::string pattern_a;
                for (const wchar_t unit : pattern_w) pattern_a.push_back(static_cast<char>(unit));
                const int result = wide
                    ? (operation.first ? first_w(archive, operation.pattern, operation.null_output ? nullptr : &info_w)
                                       : next_w(archive, operation.null_output ? nullptr : &info_w))
                    : (operation.first ? first_a(archive, operation.pattern ? pattern_a.c_str() : nullptr,
                                                 operation.null_output ? nullptr : &info_a)
                                       : next_a(archive, operation.null_output ? nullptr : &info_a));
                DWORD system_error = 0;
                const int compat_error = last_error(&system_error);
                if (result == 0) had_match = true;
                char current_name[1024] = "sentinel";
                const int name_result = proc<FnGetString>(module.handle, "UnlhaGetFileName")(
                    archive, current_name, sizeof(current_name));
                std::cout << "find." << layout << '.' << sequence << '.' << step
                          << "=rc=" << result << ",error=" << compat_error << ",system=" << system_error
                          // 原版は一度も一致していない EOF で未初期化メタデータをコピーする。
                          << ",info=" << (operation.null_output ? "null" : result == -1 && !had_match
                              ? "undefined" : wide
                              ? quote_wide(info_w.szFileName) : quote_bytes(info_a.szFileName))
                          << ",current-rc=" << name_result << ",current=" << quote_bytes(current_name)
                          << ",total=" << proc<FnDwordHarc>(module.handle, "UnlhaGetArcOriginalSize")(archive)
                          << ",read=" << proc<FnDwordHarc>(module.handle, "UnlhaGetArcReadSize")(archive) << '\n';
            }
            close(archive);
            std::cout << std::flush;
        }
    }
    HARC archive = open(nullptr, path.c_str(), M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
    if (!archive) throw std::runtime_error("member state: cannot open fixture");
    for (int phase = 0; phase < 3; ++phase) {
        if (phase == 1) first_w(archive, L"*", nullptr);
        if (phase == 2) while (next_w(archive, nullptr) == 0) {}
        auto report = [&](const char* name, const std::string& value) {
            DWORD system = 0;
            const int error = last_error(&system);
            std::cout << "member." << phase << '.' << name << '=' << value
                      << ",error=" << error << ",system=" << system << '\n';
        };
        for (const char* name : {"UnlhaGetFileName", "UnlhaGetMethod"}) {
            char buffer[1024] = "sentinel";
            const int result = proc<FnGetString>(module.handle, name)(archive, buffer, sizeof(buffer));
            report(name, std::to_string(result) + ",buffer=" + quote_bytes(buffer));
        }
        for (const char* name : {"UnlhaGetFileNameW", "UnlhaGetMethodW"}) {
            wchar_t buffer[1024] = L"sentinel";
            const int result = proc<int(WINAPI*)(HARC, LPWSTR, int)>(module.handle, name)(
                archive, buffer, _countof(buffer));
            report(name, std::to_string(result) + ",buffer=" + quote_wide(buffer));
        }
        for (const char* name : {"UnlhaGetOriginalSize", "UnlhaGetCompressedSize", "UnlhaGetCRC",
             "UnlhaGetWriteTime", "UnlhaGetCreateTime", "UnlhaGetAccessTime", "UnlhaGetOSType",
             "UnlhaGetArcOriginalSize", "UnlhaGetArcCompressedSize", "UnlhaGetArcReadSize"}) {
            report(name, std::to_string(proc<FnDwordHarc>(module.handle, name)(archive)));
        }
        for (const char* name : {"UnlhaGetDate", "UnlhaGetTime", "UnlhaGetRatio", "UnlhaGetArcRatio"}) {
            report(name, std::to_string(proc<FnWordHarc>(module.handle, name)(archive)));
        }
        for (const char* name : {"UnlhaGetAttribute", "UnlhaGetAttributes"}) {
            report(name, std::to_string(proc<FnIntHarc>(module.handle, name)(archive)));
        }
        for (const char* name : {"UnlhaGetOriginalSizeEx", "UnlhaGetCompressedSizeEx",
             "UnlhaGetArcOriginalSizeEx", "UnlhaGetArcCompressedSizeEx", "UnlhaGetArcReadSizeEx",
             "UnlhaGetWriteTime64", "UnlhaGetCreateTime64", "UnlhaGetAccessTime64"}) {
            ULHA_INT64 value = 123456;
            const BOOL result = proc<FnSizeEx>(module.handle, name)(archive, &value);
            report(name, std::to_string(result) + ",value=" + std::to_string(value));
        }
        for (const char* name : {"UnlhaGetWriteTimeEx", "UnlhaGetCreateTimeEx", "UnlhaGetAccessTimeEx"}) {
            FILETIME value{123456, 0};
            const BOOL result = proc<FnFileTime>(module.handle, name)(archive, &value);
            report(name, std::to_string(result) + ",value=" + std::to_string(filetime_value(value)));
        }
    }
    close(archive);
    return 0;
}

int run_original_find_internals(const wchar_t* dll_path, const wchar_t* archive_path,
                                const wchar_t* pattern) {
    Module module(dll_path);
    const auto base = reinterpret_cast<uintptr_t>(module.handle);
    if (reinterpret_cast<uintptr_t>(GetProcAddress(module.handle, "UnlhaFindFirst")) - base != 0x748d)
        throw std::runtime_error("internal inspection requires the original UNLHA32 3.00.0.5 binary");
    const auto read = [](const uintptr_t address, void* destination, const size_t size) {
        SIZE_T transferred = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(address),
                               destination, size, &transferred) || transferred != size)
            throw std::runtime_error("original search state is unreadable");
    };
    const auto open = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto first = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW");
    const auto next = proc<FnFindNextW>(module.handle, "UnlhaFindNextW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    HARC archive = open(nullptr, archive_path, M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
    if (!archive) throw std::runtime_error("internal inspection cannot open archive");
    INDIVIDUALINFOW info{};
    for (int result = first(archive, pattern, &info); result == 0; result = next(archive, &info)) {
        uintptr_t pointer = 0;
        WORD directory_offset = 0;
        read(base + 0x7746c, &pointer, sizeof(pointer));
        read(base + 0x79496, &directory_offset, sizeof(directory_offset));
        wchar_t name[64]{};
        read(pointer, name, sizeof(name) - sizeof(wchar_t));
        std::cout << "internal.info=" << quote_wide(info.szFileName)
                  << ",name=" << quote_wide(name) << ",directory=" << directory_offset << ",raw=";
        for (size_t index = 0; index < 20; ++index) std::cout << std::hex << static_cast<unsigned>(name[index]) << ',';
        std::cout << std::dec << '\n';
    }
    close(archive);
    return 0;
}

int compress_fixture_member(HMODULE module, const std::wstring& archive, const std::wstring& command,
                              std::vector<unsigned char>& payload, const time_t* timestamp,
                              const LPWORD attributes) {
    const auto compress = proc<FnCompressMemW>(module, "UnlhaCompressMemW");
    const DWORD original_attributes = GetFileAttributesW(archive.c_str());
    const bool existed = original_attributes != INVALID_FILE_ATTRIBUTES;
    const auto original = existed ? read_file(archive) : std::vector<unsigned char>{};
    for (unsigned attempt = 0; ; ++attempt) {
        DWORD written = 0;
        const int result = compress(nullptr, command.c_str(), payload.data(),
            static_cast<DWORD>(payload.size()), timestamp, attributes, &written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module, "UnlhaGetLastError")(&system);
        if (result != ERROR_ARC_FILE_OPEN || error != result ||
            system != ERROR_ACCESS_DENIED || attempt == 2) return result;
        // 比較試験ではなく入力書庫の準備だけを再試行する。失敗前の書庫が変化した場合は中止する。
        const DWORD current_attributes = GetFileAttributesW(archive.c_str());
        if (current_attributes != original_attributes || (existed && read_file(archive) != original))
            return result;
        std::cerr << "fixture preparation: retry " << (attempt + 1)
                  << " after access denied; archive unchanged" << std::endl;
        Sleep(50);
    }
}

int create_find_pattern_fixture(const wchar_t* dll_path, const wchar_t* workspace,
                                const bool tree, const int single_member = -1) {
    Module module(dll_path);
    const std::wstring root(workspace);
    ensure_directory(root);
    const wchar_t* unicode_names[] = {L"\u8cc7\u6599.txt", L"\u00c9tage.bin", L"\u03a3.txt",
        L"\uff21.txt", L"\xd83d\xde00.txt", L"dir\\\u8cc7\u6599.txt", L"space name.txt", L"[ab].txt"};
    const wchar_t* tree_names[] = {L"dir/a.txt", L"dir/sub/c.txt", L"dir/sub/d.log",
        L"other/deep/a.txt", L"a.txt", L"z"};
    const auto names = tree ? tree_names : unicode_names;
    const size_t member_count = tree ? _countof(tree_names) : _countof(unicode_names);
    const time_t timestamp = 1704164646;
    for (size_t index = 0; index < member_count; ++index) {
        if (single_member >= 0 && index != static_cast<size_t>(single_member)) continue;
        std::vector<unsigned char> payload(3 + 2 * index, 0x41);
        const std::wstring archive = root + L"\\pattern.lzh";
        const std::wstring command = L"-gm1 -x1 " + quote_argument(archive) + L" " +
                                     quote_argument(names[index]);
        const int result = compress_fixture_member(module.handle, archive, command, payload, &timestamp, nullptr);
        if (result) {
            DWORD system = 0;
            const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
            throw std::runtime_error("find fixture: member=" + std::to_string(index) +
                ", result=" + std::to_string(result) + ", error=" + std::to_string(error) +
                ", system=" + std::to_string(system));
        }
    }
    return 0;
}

int run_find_pattern_probe(const wchar_t* dll_path, const wchar_t* archive_path, const bool utf8,
                           const int single_pattern = -1, const bool component_patterns = false,
                           const bool defined_patterns = false, const bool use_saved_settings = false) {
    Module module(dll_path);
    if (utf8) proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const auto open_a = proc<FnOpen>(module.handle, "UnlhaOpenArchive");
    const auto open_w = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto open2_a = proc<HARC(WINAPI*)(HWND, LPCSTR, DWORD, LPCSTR)>(module.handle, "UnlhaOpenArchive2A");
    const auto open2_w = proc<HARC(WINAPI*)(HWND, LPCWSTR, DWORD, LPCWSTR)>(module.handle, "UnlhaOpenArchive2W");
    const auto first_a = proc<FnFindFirst>(module.handle, "UnlhaFindFirst");
    const auto first_w = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW");
    const auto next_a = proc<FnFindNext>(module.handle, "UnlhaFindNext");
    const auto next_w = proc<FnFindNextW>(module.handle, "UnlhaFindNextW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    char path_a[MAX_PATH * 4]{};
    WideCharToMultiByte(932, 0, archive_path, -1, path_a, sizeof(path_a), nullptr, nullptr);
    const wchar_t* patterns[] = {
        L"", L"*", L"*.txt", L"*.log", L"A.TXT", L"a.*.*", L"?", L"?.txt",
        L"*.*.*", L"*.txt.*", L"*.", L"dir/*.txt", L"dir/*", L"*/?.txt", L"dir",
        L"\"a.txt\" \"b.log\"", L"a.txt b.log", L"a.txt; b.log", L"[ab]*.txt",
        L"a.txt a.txt", L"\\a.txt", L".\\a.txt", L"dir\\c.txt", L"-p1 *.txt", L"-jx*.txt *",
        L"??.txt", L"\u8cc7?.txt", L"\u8cc7\u6599.txt", L"dir\\\u8cc7\u6599.txt",
        L"\u00e9tage.bin", L"\u03c3.txt", L"\uff41.txt", L"\xd83d\xde00.txt",
        L"\"space name.txt\"", L"space name.txt", L"[ab].txt", L"dir/./c.txt",
        L"dir/../a.txt", L"././a.txt", L"a.txt\tb.log", L"a.txt,b.log", L"\"\"",
        L" ", L"\t", L"\"\" *", L"* \"\"", L"dir//c.txt", L"DIR/*.TXT",
        L"*/??.txt", L"*/[ab].txt", L"x/?.txt", L"*/????.txt", L"*/\u03a3.txt",
        L"./*.txt", L"\"*/space name.txt\"", L"*/", L"dir/", L"dir/*/*", L"dir/*.*",
        L"dir/../*", L"../*.txt", L"*/sub/*.txt", L"dir/./*.txt", L"dir/sub/../c.txt",
        L"\\a.txt \\a.txt", L"dir/a.txt dir/sub/c.txt", L"dir/*.txt dir/a.txt", L"dir/a.txt dir/*.txt"
    };
    const DWORD modes[] = {0, M_CHECK_ALL_PATH, M_CHECK_FILENAME_ONLY,
                          M_CHECK_ALL_PATH | M_CHECK_FILENAME_ONLY};
    const wchar_t* options[] = {L"", L"-p0", L"-p1", L"-p2", L"-r1", L"-r2",
                                L"-p1 -r1", L"-jx*.txt", L"-p2 -r0", L"-r0 -p2"};
    for (int api = 0; api < 4; ++api) {
        for (size_t mode = 0; mode < _countof(modes); ++mode) {
            for (size_t option = 0; option < (api < 2 ? 1U : _countof(options)); ++option) {
                for (size_t index = 0; index < _countof(patterns); ++index) {
                    if (single_pattern >= 0 && index != static_cast<size_t>(single_pattern)) continue;
                    if (component_patterns && std::wcspbrk(patterns[index], L"/\\")) continue;
                    // 元 DLL はこの 3 条件で名前の終端を越えて照合する。別の境界試験で候補を検証する。
                    if (defined_patterns && (index == 13 || index == 51 || index == 55)) continue;
                    const DWORD flags = modes[mode] | M_ERROR_MESSAGE_OFF |
                                        (use_saved_settings ? 0 : M_REGARDLESS_INIT_FILE);
                    std::string option_a;
                    for (const wchar_t unit : std::wstring(options[option])) option_a.push_back(static_cast<char>(unit));
                    HARC archive = api == 0 ? open_a(nullptr, path_a, flags)
                        : api == 1 ? open_w(nullptr, archive_path, flags)
                        : api == 2 ? open2_a(nullptr, path_a, flags, option_a.c_str())
                                   : open2_w(nullptr, archive_path, flags, options[option]);
                    if (!archive) throw std::runtime_error("find pattern: cannot open fixture");
                    char pattern_a[4096]{};
                    WideCharToMultiByte(utf8 ? CP_UTF8 : CP_ACP, 0, patterns[index], -1,
                        pattern_a, sizeof(pattern_a), nullptr, nullptr);
                    const bool wide = api % 2 != 0;
                    INDIVIDUALINFOA narrow{};
                    INDIVIDUALINFOW unicode{};
                    int result = wide ? first_w(archive, patterns[index], &unicode)
                                      : first_a(archive, pattern_a, &narrow);
                    std::ostringstream matches;
                    size_t count = 0;
                    while (result == 0) {
                        if (++count > 1000) throw std::runtime_error("find pattern: enumeration did not finish");
                        matches << (wide ? quote_wide(unicode.szFileName) : quote_bytes(narrow.szFileName)) << ';';
                        result = wide ? next_w(archive, &unicode) : next_a(archive, &narrow);
                    }
                    const DWORD total = proc<FnDwordHarc>(module.handle, "UnlhaGetArcOriginalSize")(archive);
                    close(archive);
                    std::cout << "pattern." << api << '.' << mode << '.' << option << '.' << index
                              << "=end=" << result << ",total=" << total << ",names=" << matches.str() << '\n';
                }
                std::cout << std::flush;
            }
        }
    }
    return 0;
}

int create_memory_selection_fixture(const wchar_t* dll_path, const wchar_t* workspace,
                                     const bool compressed = false) {
    Module module(dll_path);
    const std::wstring root(workspace);
    ensure_directory(root);
    const wchar_t* names[] = {L"a.txt", L"_tage.bin", L"dir/c.txt", L"z.bin"};
    for (size_t index = 0; index < _countof(names); ++index) {
        std::vector<unsigned char> payload(compressed ? 512 + 256 * index : 3 + 2 * index);
        for (size_t offset = 0; offset < payload.size(); ++offset)
            payload[offset] = static_cast<unsigned char>(0x10 * (index + 1) + offset);
        const time_t timestamp = static_cast<time_t>(1704164646 + 86400 * index);
        WORD attributes = FILE_ATTRIBUTE_ARCHIVE | (index % 2 ? FILE_ATTRIBUTE_READONLY : 0);
        const std::wstring archive = root + L"\\selection.lzh";
        const std::wstring command = L"-gm1 -x1 " + quote_argument(archive) + L" " +
                                     quote_argument(names[index]);
        if (compress_fixture_member(module.handle, archive, command, payload, &timestamp, &attributes) != 0)
            throw std::runtime_error("memory selection: cannot create fixture");
    }
    return 0;
}

int run_memory_workflow_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                               const wchar_t* workspace, const bool progress,
                               const wchar_t* selected_case = nullptr) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const std::wstring root(workspace);
    ensure_directory(root);
    const std::wstring response_path = root + L"\\members.txt";
    const std::string response = "a.txt z.bin";
    if (GetFileAttributesW(response_path.c_str()) == INVALID_FILE_ATTRIBUTES)
        write_file(response_path, std::vector<unsigned char>(response.begin(), response.end()));
    const std::wstring response_wide = root + L"\\members-wide.txt";
    const std::wstring response_utf8 = root + L"\\members-utf8.txt";
    const std::wstring response_even = root + L"\\members-even.txt";
    const std::wstring response_wide_space = root + L"\\members-wide-space.txt";
    const std::wstring response_wide_null = root + L"\\members-wide-null.txt";
    if (GetFileAttributesW(response_wide.c_str()) == INVALID_FILE_ATTRIBUTES) {
        std::vector<unsigned char> wide_bytes{0xff, 0xfe};
        for (const char value : response) { wide_bytes.push_back(value); wide_bytes.push_back(0); }
        write_file(response_wide, wide_bytes);
        std::vector<unsigned char> utf8_bytes{0xef, 0xbb, 0xbf};
        utf8_bytes.insert(utf8_bytes.end(), response.begin(), response.end());
        write_file(response_utf8, utf8_bytes);
        std::vector<unsigned char> even_bytes(response.begin(), response.end());
        even_bytes.push_back(' ');
        write_file(response_even, even_bytes);
    }
    if (GetFileAttributesW(response_wide_space.c_str()) == INVALID_FILE_ATTRIBUTES) {
        auto wide_bytes = read_file(response_wide);
        wide_bytes.push_back(' ');
        wide_bytes.push_back(0);
        write_file(response_wide_space, wide_bytes);
        wide_bytes[wide_bytes.size() - 2] = 0;
        write_file(response_wide_null, wide_bytes);
    }
    struct Case { const char* label; std::wstring before; std::wstring after; };
    std::vector<Case> cases{
        {"all", L"", L"*"}, {"implicit", L"", L""},
        {"multiple", L"", L"a.txt z.bin"}, {"reversed", L"", L"z.bin a.txt"},
        {"duplicate", L"", L"a.txt a.txt"}, {"overlap", L"", L"a.txt *"},
        {"exclude", L"-jx*.bin", L"*"}, {"exclude-path", L"-jxdir/*", L"*"},
        {"path1", L"-p1", L"*.txt"}, {"path2", L"-p2", L"*.txt"},
        {"recursive0", L"-r0", L"*.txt"}, {"recursive1", L"-r1", L"*.txt"},
        {"recursive2", L"-r2", L"*.txt"}, {"directories", L"-x1", L"*"},
        {"flat", L"-x0", L"*"}, {"response", L"", L"@" + quote_argument(response_path)},
        {"response-even", L"", L"@" + quote_argument(response_even)},
        {"response-wide", L"", L"@" + quote_argument(response_wide)},
        {"response-wide-space", L"", L"@" + quote_argument(response_wide_space)},
        {"response-wide-null", L"", L"@" + quote_argument(response_wide_null)},
        {"response-utf8", L"", L"@" + quote_argument(response_utf8)},
        {"response-missing", L"", L"@" + quote_argument(response_path + L".missing")},
        {"command-letter", L"a", L"a.txt"},
        {"response-disabled", L"--1", L"@" + quote_argument(response_path)},
        {"directory-before", L"", L"alpha/ a.txt z.bin"},
        {"directory-after", L"", L"a.txt alpha/"},
        {"directory-between", L"", L"a.txt alpha/ z.bin"},
        {"directory-multiple", L"", L"alpha/ a.txt beta/ z.bin"},
        {"directory-default", L"", L"alpha/"},
        {"directory-reset", L"", L"alpha/ a.txt ./ z.bin"},
        {"directory-duplicate", L"", L"alpha/ a.txt beta/ a.txt"},
        {"directory-overlap", L"", L"alpha/ * beta/ a.txt"},
        {"directory-parent", L"", L"one/../two/ *"},
        {"directory-forced-file", L"", L"-gbalpha/"},
        {"literal", L"", L"\"a.txt z.bin\""}, {"no-match", L"", L"missing"}
    };
    const auto wide_response_case = [&](const char* label, const std::wstring& contents) {
        const std::wstring path = root + L"\\" + std::wstring(label, label + std::strlen(label)) + L".txt";
        if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
            std::vector<unsigned char> bytes{0xff, 0xfe};
            for (const wchar_t unit : contents) {
                bytes.push_back(static_cast<unsigned char>(unit));
                bytes.push_back(static_cast<unsigned char>(unit >> 8));
            }
            write_file(path, bytes);
        }
        cases.push_back({label, L"", L"@" + quote_argument(path)});
    };
    wide_response_case("response-wide-single", L"z.bin");
    wide_response_case("response-wide-quotes", L"\"a.txt\" \"z.bin\"");
    wide_response_case("response-wide-controls", std::wstring(L"a.txt\0z.bin \t", 13));
    wide_response_case("response-wide-sentinel-start", L"\xffff a.txt ");
    wide_response_case("response-wide-sentinel-middle", L"alpha\xffff a.txt ");
    wide_response_case("response-wide-token-limit", L"alpha/" + std::wstring(2043, L'/') + L"X a.txt ");
    // 本家がアクセス違反で終了する長い検索条件は、必ず単独プロセスで検査する。
    if (selected_case && std::wcscmp(selected_case, L"response-wide-long") == 0)
        wide_response_case("response-wide-long", std::wstring(2050, L'q') + L" a.txt ");
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = progress_window_proc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"UnLhaReMemoryWorkflow";
    if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
        throw std::runtime_error("memory workflow: window registration failed");
    const HWND message_window = CreateWindowExW(0, window_class.lpszClassName, L"", 0,
        0, 0, 0, 0, HWND_MESSAGE, nullptr, window_class.hInstance, nullptr);
    if (!message_window) throw std::runtime_error("memory workflow: window creation failed");
    if (progress) {
        progress_layout = ProgressLayout::Ex64W;
        progress_expected_owner = nullptr;
        progress_abort_state = -1;
        if (!proc<FnSetOwnerEx64>(module.handle, "UnlhaSetOwnerWindowEx64")(
                message_window, progress_probe, sizeof(EXTRACTINGINFOEX64W)))
            throw std::runtime_error("memory workflow: cannot register progress receiver");
    }
    enum_layout = EnumLayout::W32;
    proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
    for (unsigned wide = 0; wide < 2; ++wide)
    for (const Case& entry : cases) for (const DWORD capacity : {1U, 8192U}) {
        if (selected_case && std::wstring(entry.label, entry.label + std::strlen(entry.label)) != selected_case)
            continue;
        enum_records.clear();
        progress_records.clear();
        std::vector<unsigned char> buffer(capacity + 16, 0xcc);
        DWORD written = 0;
        time_t timestamp = 0;
        WORD attributes = 0;
        const std::wstring command = (std::string(entry.label) == "all" ? L"" : L"-gm1 ") + entry.before + L" " + quote_argument(archive_path) +
                                     L" " + entry.after;
        char command_a[8192]{};
        WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, command_a, sizeof(command_a), nullptr, nullptr);
        const int result = wide ? proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
            nullptr, command.c_str(), buffer.data(), capacity, &timestamp, &attributes, &written)
            : proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                module.handle, "UnlhaExtractMemA")(nullptr, command_a, buffer.data(), capacity,
                &timestamp, &attributes, &written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        std::uint32_t hash = 2166136261U;
        for (size_t index = 0; index < capacity; ++index) hash = (hash ^ buffer[index]) * 16777619U;
        const bool guard = std::all_of(buffer.begin() + capacity, buffer.end(),
            [](unsigned char value) { return value == 0xcc; });
        std::cout << "workflow." << wide << '.' << entry.label << '.' << capacity << '=' << result << ",error=" << error
                  << ",system=" << system << ",written=" << written << ",time=" << timestamp
                  << ",attr=" << attributes << ",hash=" << hash << ",guard=" << guard
                  << ",enum=" << enum_records.size() << ",progress=" << progress_records.size() << '\n';
        for (const auto& record : enum_records) std::cout << "workflow.member=" << record << '\n';
        for (const auto& record : progress_records) std::cout << "workflow.progress=" << record << '\n';
        std::cout.flush();
    }
    if (progress) proc<FnKillOwnerEx>(module.handle, "UnlhaKillOwnerWindowEx64")(message_window);
    DestroyWindow(message_window);
    UnregisterClassW(window_class.lpszClassName, window_class.hInstance);
    return 0;
}

int create_memory_damage_fixtures(const wchar_t* archive_path, const wchar_t* workspace) {
    const auto original = read_file(archive_path);
    if (original.size() < 26 || original[20] != 2)
        throw std::runtime_error("memory damage: expected a level-2 fixture");
    const auto read_size = [&](const size_t offset, const size_t width) {
        size_t value = 0;
        for (size_t index = 0; index < width; ++index)
            value |= static_cast<size_t>(original.at(offset + index)) << (index * 8);
        return value;
    };
    const size_t header_size = read_size(0, 2);
    const size_t packed_size = read_size(7, 4);
    if (!packed_size || header_size + packed_size >= original.size())
        throw std::runtime_error("memory damage: invalid first member layout");
    const std::wstring root(workspace);
    ensure_directory(root);
    for (const unsigned char fill : {static_cast<unsigned char>(0), static_cast<unsigned char>(0xff)}) {
        auto bytes = original;
        std::fill(bytes.begin() + header_size, bytes.begin() + header_size + packed_size, fill);
        write_file(root + (fill ? L"\\body-ff.lzh" : L"\\body-zero.lzh"), bytes);
    }
    auto bytes = original;
    bytes[header_size + packed_size / 2] ^= 0x5a;
    write_file(root + L"\\body-flip.lzh", bytes);
    bytes = original;
    bytes.resize(header_size + packed_size / 2);
    write_file(root + L"\\body-truncated.lzh", bytes);
    bytes = original;
    bytes[22] ^= 1;
    write_file(root + L"\\first-header-crc.lzh", bytes);
    bytes = original;
    const size_t second_header = header_size + packed_size;
    if (bytes.at(second_header + 20) != 2)
        throw std::runtime_error("memory damage: missing second member");
    bytes[second_header + 22] ^= 1;
    write_file(root + L"\\second-header-crc.lzh", bytes);
    return 0;
}

int run_memory_failure_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                             const wchar_t* valid_archive) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const auto extract_w = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const auto extract_a = proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
        module.handle, "UnlhaExtractMemA");
    const auto invoke = [&](const bool wide, const std::wstring& command,
                            std::vector<unsigned char>& buffer, const DWORD capacity,
                            time_t& timestamp, WORD& attributes, DWORD& written) {
        char narrow[8192]{};
        if (!WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, narrow, sizeof(narrow), nullptr, nullptr))
            throw std::runtime_error("memory failure: command conversion failed");
        return wide ? extract_w(nullptr, command.c_str(), buffer.data(), capacity, &timestamp, &attributes, &written)
                    : extract_a(nullptr, narrow, buffer.data(), capacity, &timestamp, &attributes, &written);
    };
    enum_layout = EnumLayout::W32;
    proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
    for (unsigned wide = 0; wide < 2; ++wide)
    for (unsigned selection = 0; selection < 3; ++selection)
    for (const DWORD capacity : {1U, 1024U, 4096U, 8192U}) {
        enum_result = TRUE;
        std::vector<unsigned char> seed(8192);
        time_t timestamp = 0;
        WORD attributes = 0;
        DWORD written = 0;
        const std::wstring valid = L"-gm1 " + quote_argument(valid_archive) + L" *";
        if (invoke(wide != 0, valid, seed, static_cast<DWORD>(seed.size()), timestamp, attributes, written) != 0)
            throw std::runtime_error("memory failure: initial valid extraction failed");
        enum_result = selection == 2 ? FALSE : TRUE;
        enum_replacement_file_w.clear();
        enum_replacement_add_w.clear();
        enum_records.clear();
        std::vector<unsigned char> buffer(capacity + 16, 0xcc);
        timestamp = 123456;
        attributes = 12345;
        written = 123456;
        const std::wstring command = L"-gm1 " + quote_argument(archive_path) +
                                     (selection == 1 ? L" missing" : L" *");
        const int result = invoke(wide != 0, command, buffer, capacity, timestamp, attributes, written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        std::uint32_t hash = 2166136261U;
        for (size_t index = 0; index < capacity; ++index) hash = (hash ^ buffer[index]) * 16777619U;
        const bool guard = std::all_of(buffer.begin() + capacity, buffer.end(),
            [](unsigned char value) { return value == 0xcc; });
        std::cout << "failure." << wide << '.' << selection << '.' << capacity << '=' << result
                  << ",error=" << error << ",system=" << system << ",written=" << written
                  << ",time=" << timestamp << ",attr=" << attributes << ",hash=" << hash
                  << ",guard=" << guard << ",enum=" << enum_records.size() << '\n';
        for (const auto& record : enum_records) std::cout << "failure.member=" << record << '\n';
        std::cout.flush();
        enum_result = TRUE;
        if (invoke(wide != 0, valid, seed, static_cast<DWORD>(seed.size()), timestamp, attributes, written) != 0)
            throw std::runtime_error("memory failure: subsequent valid extraction failed");
    }
    enum_result = TRUE;
    return 0;
}

int run_memory_failure_stress(const wchar_t* dll_path, const wchar_t* archive_path) {
    Module module(dll_path);
    const ULONGLONG started = GetTickCount64();
    const auto extract = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const std::wstring command = L"-gm1 " + quote_argument(archive_path) + L" *";
    const auto invoke = [&]() {
        unsigned char buffer[64];
        std::fill(std::begin(buffer), std::end(buffer), static_cast<unsigned char>(0xcc));
        DWORD written = 0;
        const int result = extract(nullptr, command.c_str(), buffer, 48, nullptr, nullptr, &written);
        if (result != ERROR_HUFFMAN_CODE || written != 48 ||
            !std::all_of(std::begin(buffer), std::end(buffer), [](unsigned char value) { return value == 0xcc; }))
            throw std::runtime_error("memory stress: invalid failure result or buffer write");
    };
    const auto heap_bytes = []() {
        const HANDLE heap = GetProcessHeap();
        if (!HeapLock(heap)) throw std::runtime_error("memory stress: cannot lock heap");
        PROCESS_HEAP_ENTRY entry{};
        size_t total = 0;
        while (HeapWalk(heap, &entry))
            if ((entry.wFlags & PROCESS_HEAP_ENTRY_BUSY) != 0) total += entry.cbData;
        const DWORD error = GetLastError();
        HeapUnlock(heap);
        if (error != ERROR_NO_MORE_ITEMS) throw std::runtime_error("memory stress: heap walk failed");
        return total;
    };
    for (unsigned index = 0; index < 32; ++index) invoke();
    // 通常表示を含む反復が時間上限に達しても、完了した回数を特定できるようにする。
    // 出力系の初期化は資源量の基準採取より前に済ませる。
    std::cout << "memory.stress.warmup=32,elapsed-ms=" << GetTickCount64() - started << std::endl;
    const size_t before = heap_bytes();
    DWORD handles_before = 0, handles_after = 0;
    if (!GetProcessHandleCount(GetCurrentProcess(), &handles_before))
        throw std::runtime_error("memory stress: handle count failed");
    for (unsigned index = 0; index < 512; ++index) {
        invoke();
        if ((index + 1) % 64 == 0)
            std::cout << "memory.stress.progress=" << index + 1
                      << ",elapsed-ms=" << GetTickCount64() - started << std::endl;
    }
    const size_t after = heap_bytes();
    if (!GetProcessHandleCount(GetCurrentProcess(), &handles_after))
        throw std::runtime_error("memory stress: handle count failed");
    std::cout << "memory.stress.calls=512,heap-growth=" << (after > before ? after - before : 0)
              << ",handle-growth=" << (handles_after > handles_before ? handles_after - handles_before : 0) << '\n';
    if (after > before + 128U * 1024U || handles_after > handles_before)
        throw std::runtime_error("memory stress: repeated decoder failure leaked resources");
    return 0;
}

int create_check_boundary_fixtures(const wchar_t* valid_archive, const wchar_t* workspace) {
    const auto valid = read_file(valid_archive);
    const std::wstring root(workspace);
    ensure_directory(root);
    write_file(root + L"\\unicode-\u8cc7\u6599-\xd83d\xde00.lzh", valid);
    for (const size_t prefix : {4060U, 4072U, 4073U, 8170U, 8190U, 8192U,
            131040U, 131048U, 131049U, 131071U, 131072U, 131073U, 131104U, 262144U}) {
        std::vector<unsigned char> bytes(prefix, 0x41);
        bytes.insert(bytes.end(), valid.begin(), valid.end());
        write_file(root + L"\\prefix-" + std::to_wstring(prefix) + L".lzh", bytes);
    }
    for (const size_t tail : {1U, 16U, 1024U, 131072U}) {
        auto bytes = valid;
        bytes.insert(bytes.end(), tail, 0x41);
        write_file(root + L"\\tail-" + std::to_wstring(tail) + L".lzh", bytes);
        bytes.insert(bytes.begin(), 32U, 0x41);
        write_file(root + L"\\embedded-" + std::to_wstring(tail) + L".lzh", bytes);
    }
    for (size_t tail = 0; tail <= 64; ++tail) {
        auto bytes = valid;
        bytes.insert(bytes.end(), tail, 0x41);
        write_file(root + L"\\tail-boundary-" + std::to_wstring(tail) + L".lzh", bytes);
    }
    for (const size_t tail : {1U, 2U, 19U, 20U, 21U, 22U, 64U}) {
        auto bytes = valid;
        if (bytes.empty() || bytes.back() != 0) throw std::runtime_error("check boundary: missing terminator");
        bytes.pop_back();
        bytes.insert(bytes.end(), tail, 0x41);
        write_file(root + L"\\nonzero-tail-" + std::to_wstring(tail) + L".lzh", bytes);
    }
    for (size_t prefix = 131040; prefix <= 131080; ++prefix) {
        std::vector<unsigned char> bytes(prefix, 0x41);
        bytes.insert(bytes.end(), valid.begin(), valid.end());
        write_file(root + L"\\scan-boundary-" + std::to_wstring(prefix) + L".lzh", bytes);
    }
    if (valid.size() >= 24 && valid[20] <= 1 && static_cast<size_t>(valid[0]) + 2 <= valid.size()) {
        auto bytes = valid;
        bytes[5] = '9';
        unsigned sum = 0;
        for (size_t index = 2; index < static_cast<size_t>(bytes[0]) + 2; ++index) sum += bytes[index];
        bytes[1] = static_cast<unsigned char>(sum);
        write_file(root + L"\\unknown-method.lzh", bytes);
    }
    return 0;
}

int run_check_existing_archive_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                      const bool select_mode = false, const int selected_mode = 0) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    char narrow[8192]{};
    if (!WideCharToMultiByte(CP_UTF8, 0, archive_path, -1, narrow, sizeof(narrow), nullptr, nullptr))
        throw std::runtime_error("check existing: path conversion failed");
    const char* names[] = {"UnlhaCheckArchive", "UnlhaCheckArchiveA", "UnlhaCheckArchiveW"};
    for (unsigned api = 0; api < 3; ++api) {
        for (int index = 0; index < (select_mode ? 1 : 64); ++index) {
            const int mode = select_mode ? selected_mode : index;
            const BOOL result = api == 2
                ? proc<FnCheckW>(module.handle, names[api])(archive_path, mode)
                : proc<FnCheck>(module.handle, names[api])(narrow, mode);
            DWORD system = 0;
            const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
            std::cout << "check.existing." << api << '.' << mode << '=' << result
                      << ",error=" << error << ",system=" << system << std::endl;
        }
    }
    return 0;
}

int run_check_argument_probe(const wchar_t* dll_path, const wchar_t* archive_path) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const std::wstring normal(archive_path);
    const std::wstring quoted = quote_argument(normal);
    const std::wstring unclosed = L"\"" + normal;
    const std::wstring directory = normal.substr(0, normal.find_last_of(L"/\\"));
    const std::wstring missing = normal + L".missing";
    const std::wstring missing_parent = directory + L"\\nonexistent\\missing.lzh";
    const std::wstring wildcard = normal.substr(0, normal.size() - 1) + L"?";
    const std::wstring quoted_extra = quoted + L" extra";
    const std::wstring wildcard_missing = missing + L"?";
    const std::wstring invalid_name = directory + L"\\bad|name.lzh";
    struct Input { const char* name; const wchar_t* path; };
    const Input inputs[] = {{"normal", normal.c_str()}, {"quoted", quoted.c_str()},
        {"unclosed", unclosed.c_str()}, {"empty", L""}, {"null", nullptr}, {"space", L" "},
        {"missing", missing.c_str()}, {"missing-parent", missing_parent.c_str()},
        {"directory", directory.c_str()}, {"wildcard", wildcard.c_str()},
        {"quoted-empty", L"\"\""}, {"quoted-space", L"\" \""},
        {"quoted-extra", quoted_extra.c_str()}, {"wildcard-missing", wildcard_missing.c_str()},
        {"invalid-name", invalid_name.c_str()}};
    const char* apis[] = {"UnlhaCheckArchive", "UnlhaCheckArchiveA", "UnlhaCheckArchiveW"};
    for (unsigned api = 0; api < 3; ++api)
    for (const auto& input : inputs)
    for (const int mode : {0, 1, 2, 6}) {
        char narrow[8192]{};
        if (input.path && !WideCharToMultiByte(CP_UTF8, 0, input.path, -1, narrow, sizeof(narrow), nullptr, nullptr))
            throw std::runtime_error("check argument: path conversion failed");
        const BOOL result = api == 2
            ? proc<FnCheckW>(module.handle, apis[api])(input.path, mode)
            : proc<FnCheck>(module.handle, apis[api])(input.path ? narrow : nullptr, mode);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        std::cout << "check.argument." << api << '.' << input.name << '.' << mode << '=' << result
                  << ",error=" << error << ",system=" << system << std::endl;
    }
    return 0;
}

struct CheckBusyContext {
    HMODULE module;
    const wchar_t* path;
    std::string narrow;
    unsigned calls = 0;
};
CheckBusyContext* check_busy_context = nullptr;

BOOL CALLBACK check_busy_callback(LPVOID) {
    auto& context = *check_busy_context;
    ++context.calls;
    const char* apis[] = {"UnlhaCheckArchive", "UnlhaCheckArchiveA", "UnlhaCheckArchiveW"};
    for (unsigned api = 0; api < 3; ++api)
    for (unsigned null_path = 0; null_path < 2; ++null_path)
    for (const int mode : {0, 1, 2}) {
        const BOOL result = api == 2
            ? proc<FnCheckW>(context.module, apis[api])(null_path ? nullptr : context.path, mode)
            : proc<FnCheck>(context.module, apis[api])(null_path ? nullptr : context.narrow.c_str(), mode);
        DWORD system = 0;
        const int error = proc<FnLastError>(context.module, "UnlhaGetLastError")(&system);
        std::cout << "check.busy." << api << '.' << null_path << '.' << mode << '=' << result
                  << ",error=" << error << ",system=" << system << std::endl;
    }
    return TRUE;
}

int run_check_busy_probe(const wchar_t* dll_path, const wchar_t* archive_path) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    char narrow[8192]{};
    if (!WideCharToMultiByte(CP_UTF8, 0, archive_path, -1, narrow, sizeof(narrow), nullptr, nullptr))
        throw std::runtime_error("check busy: path conversion failed");
    CheckBusyContext context{module.handle, archive_path, narrow};
    check_busy_context = &context;
    proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(check_busy_callback);
    const std::wstring command = L"-gm1 " + quote_argument(archive_path) + L" *";
    std::vector<unsigned char> buffer(8192);
    DWORD written = 0;
    const int result = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
        nullptr, command.c_str(), buffer.data(), static_cast<DWORD>(buffer.size()), nullptr, nullptr, &written);
    proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
    check_busy_context = nullptr;
    std::cout << "check.busy.outer=" << result << ",written=" << written << ",calls=" << context.calls << '\n';
    return 0;
}

int run_check_decoder_failure_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                    const wchar_t* valid_archive) {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const auto narrow = [](const wchar_t* value) {
        char buffer[8192]{};
        if (!WideCharToMultiByte(CP_UTF8, 0, value, -1, buffer, sizeof(buffer), nullptr, nullptr))
            throw std::runtime_error("check decoder: path conversion failed");
        return std::string(buffer);
    };
    const std::string damaged_a = narrow(archive_path);
    const std::string valid_a = narrow(valid_archive);
    const char* names[] = {"UnlhaCheckArchive", "UnlhaCheckArchiveA", "UnlhaCheckArchiveW"};
    for (unsigned api = 0; api < 3; ++api) {
        const auto invoke = [&](const bool damaged) {
            return api == 2
                ? proc<FnCheckW>(module.handle, names[api])(
                    damaged ? archive_path : valid_archive, CHECKARCHIVE_FULLCRC)
                : proc<FnCheck>(module.handle, names[api])(
                    damaged ? damaged_a.c_str() : valid_a.c_str(), CHECKARCHIVE_FULLCRC);
        };
        for (unsigned repetition = 0; repetition < 4; ++repetition) {
            const BOOL result = invoke(true);
            DWORD system = 0;
            const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
            // 異常脱出後も同じプロセスで通常の CRC 検査を再実行できることを確認する。
            const BOOL recovery = invoke(false);
            std::cout << "check.decoder." << api << '.' << repetition << '=' << result
                      << ",error=" << error << ",system=" << system << ",recovery=" << recovery
                      << std::endl;
            if (result != FALSE || error != 0 || system != ERROR_INVALID_DATA || recovery != TRUE)
                throw std::runtime_error("check decoder: failure state or subsequent valid check differs");
        }
    }
    return 0;
}

int run_memory_state_probe(const wchar_t* dll_path, const wchar_t* archive_path) {
    Module module(dll_path);
    const auto extract = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const std::wstring valid = quote_argument(archive_path) + L" *";
    const std::wstring missing = quote_argument(archive_path) + L" missing";
    const std::wstring nonexistent = quote_argument(std::wstring(archive_path) + L".missing") + L" *";
    const auto invoke = [&](const char* label, const wchar_t* command, const DWORD capacity,
                             const bool null_buffer = false) {
        unsigned char buffer[64];
        std::fill(std::begin(buffer), std::end(buffer), 0xcc);
        DWORD written = 123456;
        time_t timestamp = 123456;
        WORD attributes = 12345;
        const int result = extract(nullptr, command, null_buffer ? nullptr : buffer, capacity,
                                     &timestamp, &attributes, &written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        std::cout << "memory.state." << label << '=' << result << ",error=" << error
                  << ",system=" << system << ",written=" << written << ",time=" << timestamp
                  << ",attr=" << attributes << ",first=" << static_cast<unsigned>(buffer[0]) << '\n';
    };
    invoke("initial-missing", missing.c_str(), 64);
    invoke("first", valid.c_str(), 64);
    invoke("zero", valid.c_str(), 0);
    invoke("null-buffer", valid.c_str(), 64, true);
    invoke("null-command", nullptr, 64);
    invoke("empty-command", L"", 64);
    invoke("nonexistent", nonexistent.c_str(), 64);
    invoke("repeat", valid.c_str(), 64);
    const auto open = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    HARC handle = open(nullptr, archive_path, M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
    if (!handle) throw std::runtime_error("memory state: cannot open archive");
    invoke("busy", valid.c_str(), 64);
    proc<FnClose>(module.handle, "UnlhaCloseArchive")(handle);
    invoke("after-close", valid.c_str(), 64);
    return 0;
}

int run_memory_selection_case_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                     const std::wstring& profile, const unsigned pattern,
                                     const DWORD capacity) {
    const wchar_t* patterns[] = {L"*", L"*.txt", L"_tage.bin", L"missing"};
    if (pattern >= _countof(patterns) || capacity > 1024U * 1024U ||
        (profile != L"none" && profile != L"w64" && profile != L"reject" && profile != L"rename"))
        throw std::runtime_error("invalid memory selection case");
    if (!SetThreadLocale(1041)) throw std::runtime_error("cannot set memory probe locale");
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    if (profile != L"none") {
        enum_layout = EnumLayout::W64;
        enum_result = profile == L"reject" ? FALSE : TRUE;
        if (profile == L"rename") {
            enum_replacement_file_w = L"ignored-member.bin";
            enum_replacement_add_w = L"ignored-destination.bin";
        }
        if (!proc<FnSetEnum64>(module.handle, "UnlhaSetEnumMembersProc64")(
                enum_probe, sizeof(UNLHA_ENUM_MEMBER_INFO64W)))
            throw std::runtime_error("cannot register memory case callback");
    }
    // 原版の長い連続試験から、表示抑止付きの単一選択・容量を独立して比較する。
    const std::wstring command = L"-gm1 " + quote_argument(archive_path) + L" " + quote_argument(patterns[pattern]);
    const std::string narrow = dictionary_command_utf8(command);
    for (unsigned api = 0; api < 3; ++api) {
        enum_records.clear();
        std::vector<unsigned char> storage(capacity + 32U, 0xcc);
        auto* output = storage.data() + 16;
        DWORD written = 123456;
        time_t timestamp = 123456;
        WORD attributes = 12345;
        using NarrowExtract = int(WINAPI*)(HWND,LPCSTR,LPBYTE,DWORD,time_t*,LPWORD,LPDWORD);
        const int result = api == 2
            ? proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
                nullptr, command.c_str(), output, capacity, &timestamp, &attributes, &written)
            : proc<NarrowExtract>(module.handle, api == 1 ? "UnlhaExtractMemA" : "UnlhaExtractMem")(
                nullptr, narrow.c_str(), output, capacity, &timestamp, &attributes, &written);
        DWORD system = 0;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
        std::uint32_t hash = 2166136261U;
        for (DWORD i = 0; i < capacity; ++i) hash = (hash ^ output[i]) * 16777619U;
        const auto untouched = [](unsigned char value) { return value == 0xcc; };
        const bool guard = std::all_of(storage.begin(), storage.begin() + 16, untouched) &&
            std::all_of(storage.end() - 16, storage.end(), untouched);
        std::cout << "memory." << api << '.' << pattern << '.' << capacity << '=' << result
            << ",error=" << error << ",system=" << system << ",written=" << written
            << ",time=" << static_cast<long long>(timestamp) << ",attr=" << attributes
            << ",hash=" << hash << ",guard=" << guard << ",enum=" << enum_records.size() << '\n';
        for (const auto& record : enum_records) std::cout << "memory.member=" << record << '\n';
        std::cout.flush();
    }
    return 0;
}

int run_memory_selection_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                               const std::wstring& callback_mode = L"none") {
    Module module(dll_path);
    proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    const bool callbacks = callback_mode != L"none";
    if (callbacks) {
        enum_result = callback_mode == L"reject" ? FALSE : TRUE;
        if (callback_mode == L"rename") {
            enum_replacement_file_w = L"ignored-member.bin";
            enum_replacement_add_w = L"ignored-destination.bin";
        }
        enum_layout = callback_mode == L"a32" ? EnumLayout::A32 : callback_mode == L"a64"
            ? EnumLayout::A64 : callback_mode == L"w64" ? EnumLayout::W64 : EnumLayout::W32;
        if (enum_layout == EnumLayout::A64 || enum_layout == EnumLayout::W64) {
            proc<FnSetEnum64>(module.handle, "UnlhaSetEnumMembersProc64")(enum_probe,
                enum_layout == EnumLayout::A64 ? sizeof(UNLHA_ENUM_MEMBER_INFO64A) : sizeof(UNLHA_ENUM_MEMBER_INFO64W));
        } else {
            proc<FnSetEnum>(module.handle, enum_layout == EnumLayout::A32
                ? "UnlhaSetEnumMembersProcA" : "UnlhaSetEnumMembersProcW")(enum_probe);
        }
    }
    const wchar_t* patterns[] = {L"*", L"*.txt", L"_tage.bin", L"missing"};
    const DWORD sizes[] = {0, 1, 3, 4, 8, 15, 16, 32, 79, 80, 81, 8192};
    for (int wide = 0; wide < 2; ++wide) {
        for (size_t pattern = 0; pattern < _countof(patterns); ++pattern) {
            const std::wstring command = quote_argument(archive_path) + L" " + quote_argument(patterns[pattern]);
            char command_a[8192]{};
            WideCharToMultiByte(CP_UTF8, 0, command.c_str(), -1, command_a, sizeof(command_a), nullptr, nullptr);
            for (const DWORD capacity : sizes) {
                enum_records.clear();
                std::vector<unsigned char> buffer(capacity + 16U, 0xcc);
                DWORD written = 123456;
                time_t timestamp = 123456;
                WORD attributes = 12345;
                const int result = wide ? proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW")(
                    nullptr, command.c_str(), buffer.data(), capacity, &timestamp, &attributes, &written)
                    : proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                        module.handle, "UnlhaExtractMemA")(nullptr, command_a, buffer.data(), capacity,
                        &timestamp, &attributes, &written);
                DWORD system = 0;
                const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
                std::uint32_t hash = 2166136261U;
                for (size_t index = 0; index < capacity; ++index) hash = (hash ^ buffer[index]) * 16777619U;
                const bool guard = std::all_of(buffer.begin() + capacity, buffer.end(),
                                               [](unsigned char value) { return value == 0xcc; });
                std::cout << "memory." << wide << '.' << pattern << '.' << capacity << "=" << result
                          << ",error=" << error << ",system=" << system << ",written=" << written
                          << ",time=" << static_cast<long long>(timestamp) << ",attr=" << attributes
                          << ",hash=" << hash << ",guard=" << guard << '\n';
                if (callbacks) {
                    std::cout << "memory.enum." << wide << '.' << pattern << '.' << capacity
                              << "=" << enum_records.size() << '\n';
                    for (const auto& record : enum_records) std::cout << "memory.member=" << record << '\n';
                }
            }
        }
    }
    return 0;
}

int run_timestamp_range_probe(const wchar_t* dll_path, const wchar_t* fixture_path,
                               const wchar_t* workspace) {
    Module module(dll_path);
    const std::wstring root(workspace);
    ensure_directory(root);
    const auto source = read_file(fixture_path);
    if (source.size() < 26 || source[20] != 2) throw std::runtime_error("time range: level-2 fixture required");
    const size_t header_size = source[0] | (static_cast<size_t>(source[1]) << 8);
    size_t time_offset = 0;
    size_t crc_offset = 0;
    for (size_t offset = 24; offset + 2 <= header_size;) {
        const size_t length = source.at(offset) | (static_cast<size_t>(source.at(offset + 1)) << 8);
        if (length == 0) break;
        if (length < 3 || offset + length > header_size) throw std::runtime_error("time range: invalid extension");
        if (source[offset + 2] == 0x41 && length >= 27) time_offset = offset + 3;
        if (source[offset + 2] == 0 && length >= 5) crc_offset = offset + 3;
        offset += length;
    }
    if (!time_offset || !crc_offset) throw std::runtime_error("time range: missing timestamp or CRC");
    const std::int64_t boundary_times[] = {-6857222401LL, -6857222400LL, -1LL, 0LL,
        2147483647LL, 2147483648LL, 4102444799LL, 4294967295LL, 13569465599LL, 13569465600LL,
        315500399LL, 315500400LL, 315532799LL, 315532800LL};
    for (unsigned mask = 0; mask < 8 + 4 * _countof(boundary_times); ++mask) {
        auto bytes = source;
        for (unsigned kind = 0; kind < 3; ++kind) {
            const unsigned selected = mask < 8 ? 0 : (mask - 8) % 4;
            const std::uint64_t value = mask < 8 ? ((mask & (1U << kind)) ? 133486382460000000ULL : 0)
                : selected && selected != kind + 1 ? 133486382460000000ULL
                : static_cast<std::uint64_t>(116444736000000000LL + boundary_times[(mask - 8) / 4] * 10000000LL);
            for (unsigned index = 0; index < 8; ++index)
                bytes[time_offset + kind * 8 + index] = static_cast<unsigned char>(value >> (index * 8));
        }
        bytes[crc_offset] = bytes[crc_offset + 1] = 0;
        unsigned crc = 0;
        for (size_t index = 0; index < header_size; ++index) {
            crc ^= bytes[index];
            for (unsigned bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0xa001U : 0);
        }
        bytes[crc_offset] = static_cast<unsigned char>(crc);
        bytes[crc_offset + 1] = static_cast<unsigned char>(crc >> 8);
        const std::wstring archive_path = root + L"\\time-" + std::to_wstring(mask) + L".lzh";
        write_file(archive_path, bytes);
        const wchar_t* patterns_w[] = {L"*", L"z.bin", L"missing"};
        const char* patterns_a[] = {"*", "z.bin", "missing"};
        for (unsigned wide = 0; wide < 2; ++wide) for (unsigned no_info = 0; no_info < 2; ++no_info)
        for (unsigned pattern = 0; pattern < _countof(patterns_w); ++pattern) {
            HARC handle = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW")(
                nullptr, archive_path.c_str(), M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
            if (!handle) throw std::runtime_error("time range: cannot open fixture");
            INDIVIDUALINFOA info_a{};
            INDIVIDUALINFOW info_w{};
            const int result = wide
                ? proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW")(handle, patterns_w[pattern], no_info ? nullptr : &info_w)
                : proc<FnFindFirst>(module.handle, "UnlhaFindFirst")(handle, patterns_a[pattern], no_info ? nullptr : &info_a);
            DWORD system = 0;
            const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system);
            std::cout << "time.range." << mask << '.' << wide << '.' << no_info << '.' << pattern << '=' << result
                      << ",error=" << error << ",system=" << system;
            if (result == 0) {
                for (const char* name : {"UnlhaGetCreateTimeEx", "UnlhaGetWriteTimeEx", "UnlhaGetAccessTimeEx"}) {
                    FILETIME value{};
                    proc<BOOL(WINAPI*)(HARC, FILETIME*)>(module.handle, name)(handle, &value);
                    std::cout << ',' << filetime_value(value);
                }
            }
            std::cout << '\n';
            proc<FnClose>(module.handle, "UnlhaCloseArchive")(handle);
        }
    }
    return 0;
}

int run_code_page_probe(const wchar_t* dll_path, const wchar_t* fixture_path, const wchar_t* workspace) {
    Module module(dll_path);
    std::cout << "cp.environment=" << GetACP() << ',' << GetOEMCP() << ',' << GetThreadLocale() << '\n';
    const auto set_cp = proc<FnBoolUInt>(module.handle, "UnlhaSetCP");
    const auto get_cp = proc<FnUInt0>(module.handle, "UnlhaGetCP");
    const auto set_unicode = proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const auto open_a = proc<FnOpen>(module.handle, "UnlhaOpenArchive");
    const auto open_w = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    const auto first = proc<FnFindFirst>(module.handle, "UnlhaFindFirst");
    const auto get_name = proc<FnGetString>(module.handle, "UnlhaGetFileName");
    const auto get_name_w = proc<int(WINAPI*)(HARC, LPWSTR, int)>(module.handle, "UnlhaGetFileNameW");
    const auto encode = [](const std::wstring& value, const UINT code_page) {
        const int size = WideCharToMultiByte(code_page, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
        if (size <= 0) throw std::runtime_error("code page probe cannot encode input");
        std::string result(static_cast<size_t>(size), '\0');
        WideCharToMultiByte(code_page, 0, value.c_str(), -1, &result[0], size, nullptr, nullptr);
        if (!result.empty()) result.pop_back();
        return result;
    };
    const auto report = [&](const std::string& label, const auto result) {
        DWORD system = 0;
        const int error = last_error(&system);
        const UINT code_page = get_cp();
        std::cout << label << "=" << result << ",error=" << error << ",system=" << system
                  << ",cp=" << code_page << '\n';
    };
    const UINT sequence[] = {65001, 3, 3, 932, 0, 1252, 999999, 65536, 65001, 1, 437,
                             65000, 51932, 1200, 65001, 0xffffffffU, 3};
    for (size_t index = 0; index < _countof(sequence); ++index)
        report("cp.setter." + std::to_string(index), set_cp(sequence[index]));
    for (const BOOL mode : {FALSE, TRUE, 2, -1, FALSE})
        report("cp.unicode." + std::to_string(mode), set_unicode(mode));
    const std::wstring root(workspace);
    ensure_directory(root);
    const std::wstring archive = root + L"\\input.lzh";
    const std::wstring japanese_archive = root + L"\\\u66f8\u5eab.lzh";
    if (!CopyFileW(fixture_path, archive.c_str(), TRUE) ||
        !CopyFileW(fixture_path, japanese_archive.c_str(), TRUE))
        throw std::runtime_error("code page fixture cannot be copied");
    for (const UINT code_page : {3U, 932U, 1252U, 65001U}) {
        for (const BOOL unicode : {FALSE, TRUE}) {
            const std::string label = "cp." + std::to_string(code_page) + '.' + std::to_string(unicode);
            const auto reset = [&]() {
                set_cp(3);
                set_cp(3);
                set_cp(code_page);
                set_unicode(unicode);
            };
            reset();
            HARC handle = open_w(nullptr, archive.c_str(), M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
            report(label + ".openW", handle != nullptr);
            if (handle) {
                report(label + ".set-busy", set_cp(65001));
                report(label + ".unicode-busy", set_unicode(!unicode));
                INDIVIDUALINFOA info{};
                report(label + ".firstA", first(handle, "*", &info));
                std::cout << label << ".info=" << quote_bytes(info.szFileName) << '\n';
                char name[1024]{};
                wchar_t name_w[1024]{};
                report(label + ".getA", get_name(handle, name, sizeof(name)));
                report(label + ".getW", get_name_w(handle, name_w, _countof(name_w)));
                std::cout << label << ".names=" << quote_bytes(name) << ',' << quote_wide(name_w) << '\n';
                report(label + ".closeW", close(handle));
            }
            const UINT api_code_page = unicode ? CP_UTF8 : CP_THREAD_ACP;
            const std::wstring selected_archive = unicode ? japanese_archive : archive;
            const std::string path = encode(selected_archive, api_code_page);
            reset();
            handle = open_a(nullptr, path.c_str(), M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF);
            report(label + ".openA", handle != nullptr);
            if (handle) report(label + ".closeA", close(handle));
            reset();
            report(label + ".countA", proc<FnCount>(module.handle, "UnlhaGetFileCount")(path.c_str()));
            reset();
            report(label + ".checkA", proc<FnCheck>(module.handle, "UnlhaCheckArchive")(path.c_str(), 0));
            reset();
            const std::string list_command = encode(L"l -n1 -gm1 " + quote_argument(selected_archive), api_code_page);
            char output[32768]{};
            enum_records.clear();
            enum_layout = EnumLayout::A32;
            proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcA")(enum_probe);
            report(label + ".listA", proc<FnUnlhaA>(module.handle, "Unlha")(
                nullptr, list_command.c_str(), output, sizeof(output)));
            proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
            std::cout << label << ".log=" << quote_bytes(output) << '\n';
            for (size_t index = 0; index < enum_records.size(); ++index)
                std::cout << label << ".enum." << index << '=' << enum_records[index] << '\n';
            reset();
            const std::string memory_command = encode(quote_argument(selected_archive) + L" *", api_code_page);
            unsigned char payload[8192]{};
            DWORD written = 0;
            time_t timestamp = 0;
            WORD attributes = 0;
            report(label + ".extractA", proc<int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD)>(
                module.handle, "UnlhaExtractMemA")(nullptr, memory_command.c_str(), payload, sizeof(payload),
                &timestamp, &attributes, &written));
            std::cout << label << ".memory=" << written << ',' << static_cast<long long>(timestamp)
                      << ',' << attributes << ',' << static_cast<unsigned>(payload[0]) << '\n';
        }
    }
    return 0;
}

int run_unicode_memory_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto compress_mem = proc<FnCompressMemW>(h, "UnlhaCompressMemW");
    const auto extract_mem = proc<FnExtractMemW>(h, "UnlhaExtractMemW");
    const auto open_w = proc<FnOpenW>(h, "UnlhaOpenArchiveW");
    const auto find_first_w = proc<FnFindFirstW>(h, "UnlhaFindFirstW");
    const auto close = proc<FnClose>(h, "UnlhaCloseArchive");

    const std::wstring root(workspace);
    ensure_directory(root);
    const std::wstring archive = root + L"\\\u66F8\u5EAB\u2603.lzh";
    const std::wstring member = L"\u968E\u5C64\u2603/\u8CC7\u6599\u2665.bin";
    std::vector<unsigned char> payload{
        0x00, 0x10, 0x20, 0x30, 0x7f, 0x80, 0xff, 0x41, 0x42, 0x43, 0x44
    };
    const std::wstring command = quote_argument(archive) + L" " + quote_argument(member);
    const time_t source_time = static_cast<time_t>(1704164646);
    WORD source_attributes = FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_READONLY;
    DWORD compressed = 0;
    const int compress_result = compress_mem(nullptr, command.c_str(), payload.data(),
                                             static_cast<DWORD>(payload.size()), &source_time,
                                             &source_attributes, &compressed);
    std::cout << "unicode.compress.rc=" << compress_result << '\n';
    std::cout << "unicode.compress.written=" << compressed << '\n';
    std::cout << "unicode.archive.exists="
              << (GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES) << '\n';

    HARC handle = open_w(nullptr, archive.c_str(), 0);
    std::cout << "unicode.open=" << (handle != nullptr) << '\n';
    if (handle) {
        INDIVIDUALINFOW info{};
        const int find_result = find_first_w(handle, L"*", &info);
        std::cout << "unicode.find=" << find_result << '\n';
        if (find_result == 0) {
            std::cout << "unicode.name=" << quote_wide(info.szFileName) << '\n';
            std::cout << "unicode.original=" << info.dwOriginalSize << '\n';
            std::cout << "unicode.packed=" << info.dwCompressedSize << '\n';
            std::cout << "unicode.crc=" << info.dwCRC << '\n';
            std::cout << "unicode.attributes=" << quote_wide(info.szAttribute) << '\n';
        }
        std::cout << "unicode.close=" << close(handle) << '\n';
    }

    std::vector<unsigned char> extracted(payload.size() + 8U, 0xcc);
    DWORD extracted_size = 0;
    time_t extracted_time = 0;
    WORD extracted_attributes = 0;
    const int extract_result = extract_mem(nullptr, command.c_str(), extracted.data(),
                                           static_cast<DWORD>(extracted.size()),
                                           &extracted_time, &extracted_attributes,
                                           &extracted_size);
    const bool payload_matches = extracted_size == payload.size() &&
                                 std::equal(payload.begin(), payload.end(), extracted.begin());
    const bool payload_prefix_matches =
        std::equal(payload.begin(), payload.end(), extracted.begin());
    std::cout << "unicode.extract.rc=" << extract_result << '\n';
    std::cout << "unicode.extract.written=" << extracted_size << '\n';
    std::cout << "unicode.extract.time=" << static_cast<long long>(extracted_time) << '\n';
    std::cout << "unicode.extract.attributes=" << extracted_attributes << '\n';
    std::cout << "unicode.extract.payload=" << payload_matches << '\n';
    std::cout << "unicode.extract.payload-prefix=" << payload_prefix_matches << '\n';

    const std::wstring basename = member.substr(member.find_last_of(L"/\\") + 1);
    const std::wstring basename_command = quote_argument(archive) + L" " +
                                          quote_argument(basename);
    std::fill(extracted.begin(), extracted.end(), static_cast<unsigned char>(0xcc));
    extracted_size = 0;
    extracted_time = 0;
    extracted_attributes = 0;
    const int basename_extract_result =
        extract_mem(nullptr, basename_command.c_str(), extracted.data(),
                    static_cast<DWORD>(extracted.size()), &extracted_time,
                    &extracted_attributes, &extracted_size);
    const bool basename_payload_matches = extracted_size == payload.size() &&
                                          std::equal(payload.begin(), payload.end(),
                                                     extracted.begin());
    std::cout << "unicode.extract-basename.rc=" << basename_extract_result << '\n';
    std::cout << "unicode.extract-basename.written=" << extracted_size << '\n';
    std::cout << "unicode.extract-basename.time=" << static_cast<long long>(extracted_time) << '\n';
    std::cout << "unicode.extract-basename.attributes=" << extracted_attributes << '\n';
    std::cout << "unicode.extract-basename.payload=" << basename_payload_matches << '\n';

    const std::wstring missing_command = quote_argument(archive) + L" " +
                                         quote_argument(L"missing.bin");
    std::fill(extracted.begin(), extracted.end(), static_cast<unsigned char>(0xcc));
    extracted_size = 0;
    extracted_time = 0;
    extracted_attributes = 0;
    const int missing_result =
        extract_mem(nullptr, missing_command.c_str(), extracted.data(),
                    static_cast<DWORD>(extracted.size()), &extracted_time,
                    &extracted_attributes, &extracted_size);
    std::cout << "unicode.extract-missing.rc=" << missing_result << '\n';
    std::cout << "unicode.extract-missing.written=" << extracted_size << '\n';
    std::cout << "unicode.extract-missing.time=" << static_cast<long long>(extracted_time) << '\n';
    std::cout << "unicode.extract-missing.attributes=" << extracted_attributes << '\n';

    const std::wstring path_archive = root + L"\\\u968E\u5C64\u66F8\u5EAB\u2603.lzh";
    const std::wstring path_command = L"-x1 " + quote_argument(path_archive) + L" " +
                                      quote_argument(member);
    compressed = 0;
    const int path_compress_result =
        compress_mem(nullptr, path_command.c_str(), payload.data(),
                     static_cast<DWORD>(payload.size()), &source_time,
                     &source_attributes, &compressed);
    std::cout << "unicode-path.compress.rc=" << path_compress_result << '\n';
    std::cout << "unicode-path.compress.written=" << compressed << '\n';
    handle = open_w(nullptr, path_archive.c_str(), 0);
    std::cout << "unicode-path.open=" << (handle != nullptr) << '\n';
    if (handle) {
        INDIVIDUALINFOW info{};
        const int find_result = find_first_w(handle, L"*", &info);
        std::cout << "unicode-path.find=" << find_result << '\n';
        if (find_result == 0) {
            std::cout << "unicode-path.name=" << quote_wide(info.szFileName) << '\n';
            std::cout << "unicode-path.attributes=" << quote_wide(info.szAttribute) << '\n';
        }
        std::cout << "unicode-path.close=" << close(handle) << '\n';
    }
    std::fill(extracted.begin(), extracted.end(), static_cast<unsigned char>(0xcc));
    extracted_size = 0;
    extracted_time = 0;
    extracted_attributes = 0;
    const int path_extract_result =
        extract_mem(nullptr, path_command.c_str(), extracted.data(),
                    static_cast<DWORD>(extracted.size()), &extracted_time,
                    &extracted_attributes, &extracted_size);
    const bool path_payload_matches = extracted_size == payload.size() &&
                                      std::equal(payload.begin(), payload.end(),
                                                 extracted.begin());
    std::cout << "unicode-path.extract.rc=" << path_extract_result << '\n';
    std::cout << "unicode-path.extract.written=" << extracted_size << '\n';
    std::cout << "unicode-path.extract.time=" << static_cast<long long>(extracted_time) << '\n';
    std::cout << "unicode-path.extract.attributes=" << extracted_attributes << '\n';
    std::cout << "unicode-path.extract.payload=" << path_payload_matches << '\n';
    return 0;
}

int run_unicode_command_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto open_w = proc<FnOpenW>(h, "UnlhaOpenArchiveW");
    const auto find_first_w = proc<FnFindFirstW>(h, "UnlhaFindFirstW");
    const auto close = proc<FnClose>(h, "UnlhaCloseArchive");
    const auto check_w = proc<FnCheckW>(h, "UnlhaCheckArchiveW");
    const auto count_w = proc<FnCountW>(h, "UnlhaGetFileCountW");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\\u5165\u529B\u2603";
    const std::wstring nested = source + L"\\\u968E\u5C64\u2603";
    const std::wstring relative_member = L"\u968E\u5C64\u2603\\\u8CC7\u6599\u2665.bin";
    const std::wstring stored_member = L"\u968E\u5C64\u2603/\u8CC7\u6599\u2665.bin";
    const std::wstring source_file = source + L"\\" + relative_member;
    const std::wstring archive = root + L"\\\u66F8\u5EAB\u2603.lzh";
    const std::wstring destination = root + L"\\\u51FA\u529B\u2603";
    const std::wstring extracted_file = destination + L"\\" + relative_member;
    ensure_directory(root);
    ensure_directory(source);
    ensure_directory(nested);
    ensure_directory(destination);
    std::vector<unsigned char> payload(513);
    for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<unsigned char>((index * 19U + 0x35U) & 0xffU);
    }
    write_file(source_file, payload);
    set_file_times(source_file, 2025, 6, 7, 8, 9, 10);

    wchar_t output[8192]{};
    const std::wstring add_command = L"a -n1 -y -x1 " + quote_argument(archive) + L" " +
                                     quote_argument(source + L"\\") + L" " +
                                     quote_argument(relative_member);
    const int add_result = unlha_w(nullptr, add_command.c_str(), output, _countof(output));
    std::cout << "unicode-command.add.rc=" << add_result << '\n';
    std::cout << "unicode-command.archive.exists="
              << (GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES) << '\n';
    std::cout << "unicode-command.check=" << check_w(archive.c_str(), 0) << '\n';
    std::cout << "unicode-command.count=" << count_w(archive.c_str()) << '\n';

    HARC handle = open_w(nullptr, archive.c_str(), 0);
    std::cout << "unicode-command.open=" << (handle != nullptr) << '\n';
    if (handle) {
        INDIVIDUALINFOW info{};
        const int find_result = find_first_w(handle, L"*", &info);
        std::cout << "unicode-command.find=" << find_result << '\n';
        if (find_result == 0) {
            std::cout << "unicode-command.name=" << quote_wide(info.szFileName) << '\n';
            std::cout << "unicode-command.original=" << info.dwOriginalSize << '\n';
            std::cout << "unicode-command.packed=" << info.dwCompressedSize << '\n';
            std::cout << "unicode-command.crc=" << info.dwCRC << '\n';
        }
        std::cout << "unicode-command.close=" << close(handle) << '\n';
    }

    std::memset(output, 0, sizeof(output));
    const std::wstring extract_command = L"x -n1 -y " + quote_argument(archive) + L" " +
                                         quote_argument(destination + L"\\") + L" " +
                                         quote_argument(stored_member);
    const int extract_result =
        unlha_w(nullptr, extract_command.c_str(), output, _countof(output));
    const bool extracted_exists =
        GetFileAttributesW(extracted_file.c_str()) != INVALID_FILE_ATTRIBUTES;
    std::cout << "unicode-command.extract.rc=" << extract_result << '\n';
    std::cout << "unicode-command.extract.exists=" << extracted_exists << '\n';
    std::cout << "unicode-command.extract.payload="
              << (extracted_exists && read_file(extracted_file) == payload) << '\n';
    return 0;
}

int run_utf8_path_probe(const wchar_t* dll_path, const wchar_t* workspace, const wchar_t* api,
                       const bool configured = true) {
    std::cout.setf(std::ios::unitbuf);
    Module module(dll_path);
    const HMODULE h = module.handle;
    proc<FnBoolBool>(h, "UnlhaSetUnicodeMode")(TRUE);
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\入力😀";
    const std::wstring nested = source + L"\\階層😺";
    const std::wstring archive = root + L"\\書庫😀.lzh";
    const std::wstring first = L"資料😀.bin", second = L"資料😁.bin";
    const std::wstring child = L"階層😺/追加🦊.bin";
    ensure_directory(root);
    ensure_directory(source);
    ensure_directory(nested);
    write_file(source + L"\\" + first, {65, 66, 67});
    write_file(source + L"\\" + second, {68, 69, 70, 71, 72});
    write_file(nested + L"\\追加🦊.bin", {73, 74, 75, 76, 77, 78, 79});
    for (const auto& name : {first, second, child})
        set_file_times(source + L"\\" + name, 2024, 1, 2, 3, 4, 6);
    SetFileAttributesW((source + L"\\" + second).c_str(), FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_HIDDEN);
    SYSTEMTIME directory_time{};
    directory_time.wYear = 2024;
    directory_time.wMonth = 1;
    directory_time.wDay = 2;
    FILETIME directory_filetime{};
    SystemTimeToFileTime(&directory_time, &directory_filetime);
    HANDLE directory = CreateFileW(nested.c_str(), FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (directory == INVALID_HANDLE_VALUE) throw std::runtime_error("UTF-8 directory timestamp open failed");
    const BOOL timed = SetFileTime(directory, &directory_filetime, &directory_filetime, &directory_filetime);
    CloseHandle(directory);
    if (!timed) throw std::runtime_error("UTF-8 directory timestamp failed");

    wchar_t initial_directory[32768]{};
    if (!GetCurrentDirectoryW(_countof(initial_directory), initial_directory))
        throw std::runtime_error("UTF-8 probe cannot capture current directory");
    struct RestoreDirectory {
        const wchar_t* path;
        ~RestoreDirectory() { SetCurrentDirectoryW(path); }
    } restore{initial_directory};
    if (!SetCurrentDirectoryW(root.c_str())) throw std::runtime_error("UTF-8 probe cannot set directory");
    auto run = [&](const char* label, const std::wstring& command) {
        wchar_t expected_directory[32768]{};
        GetCurrentDirectoryW(_countof(expected_directory), expected_directory);
        wchar_t output_w[16384]{};
        char output_a[65536]{};
        int result;
        if (std::wcscmp(api, L"W") == 0) {
            result = proc<FnUnlhaW>(h, "UnlhaW")(nullptr, command.c_str(), output_w, _countof(output_w));
        } else {
            const std::string input = dictionary_command_utf8(command);
            result = proc<FnUnlhaA>(h, std::wcscmp(api, L"A") == 0 ? "UnlhaA" : "Unlha")(
                nullptr, input.c_str(), output_a, _countof(output_a));
            MultiByteToWideChar(CP_UTF8, 0, output_a, -1, output_w, _countof(output_w));
        }
        wchar_t current_directory[32768]{};
        GetCurrentDirectoryW(_countof(current_directory), current_directory);
        std::wstring output(output_w);
        for (std::wstring prefix : {root, root + L"\\"}) {
            for (int slash = 0; slash < 2; ++slash) {
                size_t position = 0;
                while ((position = output.find(prefix, position)) != std::wstring::npos) {
                    output.replace(position, prefix.size(), L"<root>");
                    position += 6;
                }
                std::replace(prefix.begin(), prefix.end(), L'\\', L'/');
            }
        }
        const bool same_directory = std::wcscmp(expected_directory, current_directory) == 0;
        std::cout << label << ".rc=" << result << ",cwd=" << same_directory << '\n';
        std::cout << label << ".output=" << quote_wide(output.c_str()) << '\n';
        if (!same_directory) SetCurrentDirectoryW(expected_directory);
        return result;
    };
    auto snapshot = [&](const char* label, const std::wstring& path) {
        const HARC handle = proc<FnOpenW>(h, "UnlhaOpenArchiveW")(nullptr, path.c_str(), 0);
        std::cout << label << ".open=" << (handle != nullptr) << '\n';
        if (!handle) return;
        std::vector<std::wstring> names;
        INDIVIDUALINFOW info{};
        int result = proc<FnFindFirstW>(h, "UnlhaFindFirstW")(handle, L"*", &info);
        for (size_t index = 0; result == 0 && index < 32; ++index) {
            names.emplace_back(info.szFileName);
            std::cout << label << ".member" << index << '=' << quote_wide(info.szFileName)
                      << ",size=" << info.dwOriginalSize << ",crc=" << info.dwCRC
                      << ",date=" << info.wDate << ",time=" << info.wTime
                      << ",attribute=" << quote_wide(info.szAttribute) << '\n';
            result = proc<FnFindNextW>(h, "UnlhaFindNextW")(handle, &info);
        }
        proc<FnClose>(h, "UnlhaCloseArchive")(handle);
        std::cout << label << ".end=" << result << ",count=" << names.size() << '\n';
        for (size_t index = 0; index < names.size(); ++index) {
            if (names[index].empty() || names[index].back() == L'/') continue;
            unsigned char buffer[64]{};
            DWORD written = 0;
            time_t timestamp = 0;
            WORD attributes = 0;
            const std::wstring command = L"-gm1 " + quote_argument(path) + L" " + quote_argument(names[index]);
            const int extract = proc<FnExtractMemW>(h, "UnlhaExtractMemW")(
                nullptr, command.c_str(), buffer, sizeof(buffer), &timestamp, &attributes, &written);
            std::cout << label << ".data" << index << '=' << extract << ",bytes=" << written
                      << ",time=" << timestamp << ",attribute=" << attributes << ",payload=";
            for (DWORD offset = 0; offset < (std::min)(written, DWORD{sizeof(buffer)}); ++offset)
                std::cout << static_cast<unsigned int>(buffer[offset]) << ',';
            std::cout << '\n';
        }
    };
    const std::wstring settings = configured ? L" -a1 -e1 -r2 " : L" ";
    const std::wstring add_base = L" -gm1 -y1 -n1 -jm0 -h2 -x1 " + settings + quote_argument(archive) +
                                 L" " + quote_argument(source + L"\\") + L" ";
    run("add", L"a" + add_base + quote_argument(first) + L" " + quote_argument(second));
    snapshot("add", archive);
    write_file(source + L"\\" + first, {80, 81, 82, 83});
    set_file_times(source + L"\\" + first, 2025, 1, 2, 3, 4, 6);
    run("update", L"u" + add_base + quote_argument(first));
    snapshot("update", archive);
    run("recursive", L"a" + add_base + quote_argument(L"階層😺"));
    snapshot("recursive", archive);
    const std::wstring wildcard_archive = root + L"\\一致😺.lzh";
    // UTF-8 の FindFirstFile とディレクトリ列挙をそれぞれ通す。
    SetCurrentDirectoryW(source.c_str());
    const std::wstring wildcard = L"a -gm1 -y1 -n1 -jm0 " + settings + quote_argument(wildcard_archive) +
                                 L" " + quote_argument(L"資料*.bin");
    run("wildcard", wildcard);
    SetCurrentDirectoryW(root.c_str());
    snapshot("wildcard", wildcard_archive);
    const std::wstring destination = root + L"\\展開🦊";
    ensure_directory(destination);
    run("extract", L"x -gm1 -y1 -n1 " + settings + quote_argument(archive) + L" " + quote_argument(destination + L"\\"));
    for (const auto& name : {first, second, child}) {
        WIN32_FILE_ATTRIBUTE_DATA info{};
        const std::wstring path = destination + L"\\" + name;
        const BOOL exists = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info);
        std::cout << "extract.file=" << quote_wide(name.c_str()) << ",exists=" << exists;
        if (exists) {
            std::cout << ",attribute=" << info.dwFileAttributes << ",write="
                      << info.ftLastWriteTime.dwHighDateTime << ':' << info.ftLastWriteTime.dwLowDateTime
                      << ",payload=";
            for (const auto byte : read_file(path)) std::cout << static_cast<unsigned int>(byte) << ',';
        }
        std::cout << '\n';
    }
    const std::wstring renamed = L"改名🦊.bin";
    run("rename", L"n -gm1 -y1 -n1 " + quote_argument(L"-gr" + renamed) + L" " +
                  quote_argument(archive) + L" " + quote_argument(first));
    snapshot("rename", archive);
    run("convert", L"y -gm1 -y1 -n1 -h2 " + quote_argument(archive) + L" " + quote_argument(second));
    snapshot("convert", archive);
    run("delete", L"d -gm1 -y1 -n1 " + quote_argument(archive) + L" " + quote_argument(second));
    snapshot("delete", archive);
    const std::wstring joined = root + L"\\結合😀.lzh";
    run("join", L"j -gm1 -y1 -n1 " + quote_argument(joined) + L" " + quote_argument(archive));
    snapshot("join", joined);
    run("missing", L"a" + add_base + quote_argument(L"存在しない😀.bin"));
    return 0;
}

int run_sfx_probe(const wchar_t* dll_path, const wchar_t* workspace,
                  const wchar_t* selected_mode = nullptr) {
    std::cout.setf(std::ios::unitbuf);
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto check_w = proc<FnCheckW>(h, "UnlhaCheckArchiveW");
    const auto open_w = proc<FnOpenW>(h, "UnlhaOpenArchiveW");
    const auto is_sfx = proc<FnIntHarc>(h, "UnlhaIsSFXFile");
    const auto close = proc<FnClose>(h, "UnlhaCloseArchive");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\input";
    ensure_directory(root);
    ensure_directory(source);
    std::vector<unsigned char> payload(257);
    for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<unsigned char>((index * 31U + 7U) & 0xffU);
    }
    write_file(source + L"\\payload.bin", payload);

    struct SfxMode final {
        const char* label;
        const wchar_t* option;
        const wchar_t* rename;
    };
    const SfxMode modes[] = {
        {"dos", L"-gw0", L""},
        {"win", L"-gw2", L""},
        {"winm", L"-gw4", L"CustomSfx"},
    };

    for (const SfxMode& mode : modes) {
        const std::string label(mode.label);
        const std::wstring label_w(label.begin(), label.end());
        if (selected_mode && _wcsicmp(selected_mode, label_w.c_str()) != 0) continue;
        const std::wstring archive = root + L"\\" + label_w + L".lzh";
        const std::wstring destination = root + L"\\" + label_w + L"-out";
        ensure_directory(destination);
        wchar_t output[8192]{};
        const std::wstring add_command = L"a -n1 -y " + quote_argument(archive) + L" " +
                                         quote_argument(source + L"\\") + L" " +
                                         quote_argument(L"payload.bin");
        const int add_result = unlha_w(nullptr, add_command.c_str(), output, _countof(output));
        std::cout << "sfx." << label << ".add.rc=" << add_result << '\n';

        std::wstring sfx_command = L"s -n1 -y";
        if (*mode.option) sfx_command += L" " + std::wstring(mode.option);
        if (*mode.rename) sfx_command += L" -gr" + std::wstring(mode.rename);
        sfx_command += L" " + quote_argument(archive) + L" " +
                       quote_argument(destination + L"\\");
        std::memset(output, 0, sizeof(output));
        const int sfx_result = unlha_w(nullptr, sfx_command.c_str(), output, _countof(output));
        std::cout << "sfx." << label << ".command.rc=" << sfx_result << '\n';
        std::cout << "sfx." << label << ".input.exists="
                  << (GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES) << '\n';

        WIN32_FIND_DATAW item{};
        HANDLE find = FindFirstFileW((destination + L"\\*").c_str(), &item);
        int file_index = 0;
        if (find != INVALID_HANDLE_VALUE) {
            do {
                if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
                const std::wstring generated = destination + L"\\" + item.cFileName;
                std::cout << "sfx." << label << ".file" << file_index
                          << ".name=" << quote_wide(item.cFileName) << '\n';
                std::cout << "sfx." << label << ".file" << file_index
                          << ".size="
                          << ((static_cast<unsigned long long>(item.nFileSizeHigh) << 32) |
                              item.nFileSizeLow) << '\n';
                std::cout << "sfx." << label << ".file" << file_index
                          << ".check=" << check_w(generated.c_str(), 0) << '\n';
                std::cout << "sfx." << label << ".file" << file_index
                          << ".check-sfx=" << check_w(generated.c_str(), CHECKARCHIVE_SFX)
                          << '\n';
                HARC archive_handle = open_w(nullptr, generated.c_str(), 0);
                std::cout << "sfx." << label << ".file" << file_index
                          << ".open=" << (archive_handle != nullptr) << '\n';
                if (archive_handle) {
                    std::cout << "sfx." << label << ".file" << file_index
                              << ".type=" << is_sfx(archive_handle) << '\n';
                    std::cout << "sfx." << label << ".file" << file_index
                              << ".close=" << close(archive_handle) << '\n';
                }
                ++file_index;
            } while (FindNextFileW(find, &item));
            FindClose(find);
        }
        std::cout << "sfx." << label << ".files=" << file_index << '\n';
    }
    return 0;
}

int run_check_archive_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto check_a = proc<FnCheck>(h, "UnlhaCheckArchive");
    const auto check_w = proc<FnCheckW>(h, "UnlhaCheckArchiveW");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\input";
    const std::wstring archive = root + L"\\valid.lzh";
    const std::wstring level2_archive = root + L"\\level2-valid.lzh";
    ensure_directory(root);
    ensure_directory(source);
    std::vector<unsigned char> payload(1024);
    for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<unsigned char>((index * 17U + 0x49U) & 0xffU);
    }
    write_file(source + L"\\payload.bin", payload);
    wchar_t output[4096]{};
    const std::wstring command = L"a -n1 -y -h1 -jm0 " + quote_argument(archive) +
        L" " + quote_argument(source + L"\\") + L" " + quote_argument(L"payload.bin");
    const int add_result = unlha_w(nullptr, command.c_str(), output, _countof(output));
    std::cout << "check.add.rc=" << add_result << '\n';
    if (add_result != 0) return 1;
    const std::wstring level2_command = L"a -n1 -y -h2 -jm0 " +
        quote_argument(level2_archive) + L" " + quote_argument(source + L"\\") +
        L" " + quote_argument(L"payload.bin");
    const int level2_add_result = unlha_w(
        nullptr, level2_command.c_str(), output, _countof(output));
    std::cout << "check.level2-add.rc=" << level2_add_result << '\n';
    if (level2_add_result != 0) return 1;

    const std::vector<unsigned char> valid = read_file(archive);
    if (valid.size() < 32) throw std::runtime_error("check archive fixture is too small");
    const size_t header_end = static_cast<size_t>(valid[0]) + 2U;
    const unsigned long packed = static_cast<unsigned long>(valid[7]) |
        (static_cast<unsigned long>(valid[8]) << 8) |
        (static_cast<unsigned long>(valid[9]) << 16) |
        (static_cast<unsigned long>(valid[10]) << 24);
    if (header_end >= valid.size() || packed == 0 ||
        header_end + packed > valid.size()) {
        throw std::runtime_error("unexpected level-1 check fixture layout");
    }

    struct Variant final {
        const char* label;
        std::wstring path;
        std::vector<unsigned char> bytes;
    };
    std::vector<Variant> variants;
    variants.push_back({"valid", archive, valid});
    std::vector<unsigned char> bad_header = valid;
    bad_header[1] ^= 0x01;
    variants.push_back({"bad-header", root + L"\\bad-header.lzh", bad_header});
    std::vector<unsigned char> bad_data = valid;
    bad_data[header_end + packed / 2U] ^= 0x5a;
    variants.push_back({"bad-data", root + L"\\bad-data.lzh", bad_data});
    std::vector<unsigned char> truncated = valid;
    truncated.resize(header_end + packed / 2U);
    variants.push_back({"truncated", root + L"\\truncated.lzh", truncated});
    std::vector<unsigned char> trailing = valid;
    trailing.insert(trailing.end(), {0xde, 0xad, 0xbe, 0xef});
    variants.push_back({"trailing", root + L"\\trailing.lzh", trailing});
    std::vector<unsigned char> prefixed(32, 0x41);
    prefixed.insert(prefixed.end(), valid.begin(), valid.end());
    variants.push_back({"prefixed", root + L"\\prefixed.lzh", prefixed});
    if (valid.back() != 0) throw std::runtime_error("check fixture has no terminator");
    const std::vector<unsigned char> entry(valid.begin(), valid.end() - 1);
    std::vector<unsigned char> multi;
    for (int index = 0; index < 4; ++index) {
        multi.insert(multi.end(), entry.begin(), entry.end());
    }
    multi.push_back(0);
    variants.push_back({"multi", root + L"\\multi.lzh", multi});
    std::vector<unsigned char> bad_fourth = multi;
    bad_fourth[entry.size() * 3U + 1U] ^= 0x01;
    variants.push_back({"bad-fourth", root + L"\\bad-fourth.lzh", bad_fourth});
    std::vector<unsigned char> recoverable = entry;
    recoverable.insert(recoverable.end(), 32, 0x41);
    recoverable.insert(recoverable.end(), entry.begin(), entry.end());
    recoverable.push_back(0);
    variants.push_back({"between-garbage", root + L"\\between-garbage.lzh", recoverable});
    std::vector<unsigned char> no_terminator = valid;
    no_terminator.pop_back();
    variants.push_back({"no-terminator", root + L"\\no-terminator.lzh", no_terminator});

    const std::vector<unsigned char> level2_valid = read_file(level2_archive);
    variants.push_back({"level2-valid", level2_archive, level2_valid});
    std::vector<unsigned char> level2_bad_name = level2_valid;
    const std::string member_name = "payload.bin";
    const auto member_position = std::search(
        level2_bad_name.begin(), level2_bad_name.end(),
        member_name.begin(), member_name.end());
    if (member_position == level2_bad_name.end()) {
        throw std::runtime_error("level-2 member name was not found");
    }
    *member_position ^= 0x01;
    variants.push_back({"level2-bad-name", root + L"\\level2-bad-name.lzh",
                        level2_bad_name});
    variants.push_back({"empty", root + L"\\empty.lzh", {}});

    struct Mode final { const char* label; int value; };
    const Mode modes[] = {
        {"rapid", CHECKARCHIVE_RAPID},
        {"basic", CHECKARCHIVE_BASIC},
        {"fullcrc", CHECKARCHIVE_FULLCRC},
        {"recovery", CHECKARCHIVE_RECOVERY},
        {"all", CHECKARCHIVE_ALL},
        {"enddata", CHECKARCHIVE_ENDDATA},
        {"basic-enddata", CHECKARCHIVE_BASIC | CHECKARCHIVE_ENDDATA},
        {"fullcrc-enddata", CHECKARCHIVE_FULLCRC | CHECKARCHIVE_ENDDATA},
        {"recovery-all", CHECKARCHIVE_RECOVERY | CHECKARCHIVE_ALL},
    };

    for (Variant& variant : variants) {
        write_file(variant.path, variant.bytes);
        char ansi_path[MAX_PATH * 4]{};
        if (!WideCharToMultiByte(932, WC_NO_BEST_FIT_CHARS, variant.path.c_str(), -1,
                                 ansi_path, static_cast<int>(sizeof(ansi_path)),
                                 nullptr, nullptr)) {
            throw std::runtime_error("check archive path is not CP932");
        }
        for (const Mode& mode : modes) {
            std::cout << "check." << variant.label << '.' << mode.label << ".a="
                      << check_a(ansi_path, mode.value) << '\n';
            std::cout << "check." << variant.label << '.' << mode.label << ".w="
                      << check_w(variant.path.c_str(), mode.value) << '\n';
        }
    }
    return 0;
}

struct ConfigDialogProbeContext {
    HMODULE module{};
    bool wide{};
    bool null_buffer{};
    int mode{};
    BOOL result{};
    DWORD win32_error{};
    int compat_error{};
    DWORD compat_system_error{};
    char ansi_buffer[1024]{};
    wchar_t wide_buffer[1024]{};
};

DWORD WINAPI config_dialog_probe_thread(LPVOID raw_context) {
    auto& context = *static_cast<ConfigDialogProbeContext*>(raw_context);
    strcpy_s(context.ansi_buffer, "ANSI-SENTINEL");
    wcscpy_s(context.wide_buffer, L"WIDE-SENTINEL");
    SetLastError(0x12345678U);
    if (context.wide) {
        context.result = proc<FnConfigW>(context.module, "UnlhaConfigDialogW")(
            nullptr, context.null_buffer ? nullptr : context.wide_buffer, context.mode);
    } else {
        context.result = proc<FnConfigA>(context.module, "UnlhaConfigDialogA")(
            nullptr, context.null_buffer ? nullptr : context.ansi_buffer, context.mode);
    }
    context.win32_error = GetLastError();
    context.compat_system_error = 0x87654321U;
    context.compat_error = proc<FnLastError>(context.module, "UnlhaGetLastError")(
        &context.compat_system_error);
    return 0;
}

struct DialogWindowSnapshot {
    HWND dialog{};
    std::vector<std::string> lines;
};

BOOL CALLBACK snapshot_dialog_child(HWND window, LPARAM raw_snapshot) {
    auto& snapshot = *reinterpret_cast<DialogWindowSnapshot*>(raw_snapshot);
    wchar_t class_name[128]{};
    wchar_t text[1024]{};
    GetClassNameW(window, class_name, _countof(class_name));
    GetWindowTextW(window, text, _countof(text));
    std::ostringstream line;
    line << "control." << snapshot.lines.size()
         << ".id=" << GetDlgCtrlID(window)
         << ",class=" << quote_wide(class_name)
         << ",text=" << quote_wide(text)
         << ",check=" << SendMessageW(window, BM_GETCHECK, 0, 0)
         << ",enabled=" << IsWindowEnabled(window)
         << ",visible=" << IsWindowVisible(window)
         << ",style=" << static_cast<unsigned long>(GetWindowLongPtrW(window, GWL_STYLE));
    snapshot.lines.push_back(line.str());
    return TRUE;
}

BOOL CALLBACK find_config_dialog(HWND window, LPARAM raw_snapshot) {
    auto& snapshot = *reinterpret_cast<DialogWindowSnapshot*>(raw_snapshot);
    wchar_t class_name[128]{};
    GetClassNameW(window, class_name, _countof(class_name));
    if (std::wcscmp(class_name, L"#32770") != 0 || !IsWindowVisible(window) ||
        !IsWindowEnabled(window)) return TRUE;
    snapshot.dialog = window;
    wchar_t title[1024]{};
    GetWindowTextW(window, title, _countof(title));
    snapshot.lines.push_back("dialog.title=" + quote_wide(title));
    EnumChildWindows(window, snapshot_dialog_child, raw_snapshot);
    return FALSE;
}

int run_config_dialog_probe(const wchar_t* dll_path, const wchar_t* mode_text,
                            const wchar_t* action, const wchar_t* variant) {
    Module module(dll_path);
    wchar_t* mode_end = nullptr;
    const long parsed_mode = std::wcstol(mode_text, &mode_end, 0);
    if (!mode_end || *mode_end != L'\0') throw std::runtime_error("invalid config mode");

    ConfigDialogProbeContext context{};
    context.module = module.handle;
    context.mode = static_cast<int>(parsed_mode);
    context.wide = variant[0] == L'w' || variant[0] == L'W';
    context.null_buffer = std::wcsstr(variant, L"null") != nullptr;

    const bool main_action = _wcsnicmp(action, L"main:", 5) == 0;
    const bool save_local = _wcsnicmp(action, L"local-save:", 11) == 0;
    const bool local_action = save_local || _wcsnicmp(action, L"local:", 6) == 0;
    std::vector<int> click_ids;
    if (main_action || local_action) {
        const wchar_t* cursor = action + (main_action ? 5 : (save_local ? 11 : 6));
        while (*cursor) {
            wchar_t* end = nullptr;
            const long id = std::wcstol(cursor, &end, 10);
            if (!end || end == cursor || (id < 0 || id > 65535)) {
                throw std::runtime_error("invalid config control id");
            }
            click_ids.push_back(static_cast<int>(id));
            if (*end == L'\0') break;
            if (*end != L',') throw std::runtime_error("invalid config control list");
            cursor = end + 1;
        }
    }

    DWORD thread_id = 0;
    HANDLE thread = CreateThread(nullptr, 0, config_dialog_probe_thread, &context, 0, &thread_id);
    if (!thread) throw std::runtime_error("CreateThread failed: " + std::to_string(GetLastError()));

    DialogWindowSnapshot snapshot{};
    bool command_sent = false;
    HWND outer_dialog = nullptr;
    int expand_phase = 0;
    int expand_wait = 0;
    std::vector<std::string> expanded_lines;
    DWORD wait_result = WAIT_TIMEOUT;
    for (int attempt = 0; attempt < 250; ++attempt) {
        wait_result = WaitForSingleObject(thread, 20);
        if (wait_result != WAIT_TIMEOUT) break;
        if (!command_sent) {
            snapshot = DialogWindowSnapshot{};
            EnumThreadWindows(thread_id, find_config_dialog, reinterpret_cast<LPARAM>(&snapshot));
            if (snapshot.dialog) {
                if (main_action) {
                    for (const int id : click_ids) {
                        HWND control = GetDlgItem(snapshot.dialog, id);
                        DWORD_PTR ignored = 0;
                        if (control) {
                            SendMessageTimeoutW(control, BM_CLICK, 0, 0, SMTO_ABORTIFHUNG,
                                                1000, &ignored);
                        }
                    }
                    PostMessageW(snapshot.dialog, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
                    command_sent = true;
                    continue;
                }
                if (_wcsicmp(action, L"expand") == 0 || local_action) {
                    if (expand_phase == 0) {
                        outer_dialog = snapshot.dialog;
                        PostMessageW(outer_dialog, WM_COMMAND, MAKEWPARAM(411, BN_CLICKED), 0);
                        expand_phase = 1;
                        continue;
                    }
                    if (expand_phase == 1) {
                        if (snapshot.dialog != outer_dialog) {
                            expanded_lines = snapshot.lines;
                            if (local_action) {
                                for (const int id : click_ids) {
                                    HWND control = GetDlgItem(snapshot.dialog, id);
                                    DWORD_PTR ignored = 0;
                                    if (control) {
                                        SendMessageTimeoutW(control, BM_CLICK, 0, 0,
                                                            SMTO_ABORTIFHUNG, 1000, &ignored);
                                    }
                                }
                            }
                            PostMessageW(snapshot.dialog, WM_COMMAND,
                                         MAKEWPARAM(local_action ? IDOK : IDCANCEL, BN_CLICKED), 0);
                            expand_phase = 2;
                            continue;
                        }
                        if (++expand_wait < 10) continue;
                    } else if (snapshot.dialog != outer_dialog) {
                        continue;
                    }
                }
                const bool accept = _wcsicmp(action, L"ok") == 0 || local_action;
                if (save_local) {
                    DWORD_PTR ignored = 0;
                    SendMessageTimeoutW(GetDlgItem(snapshot.dialog, 412), BM_CLICK, 0, 0,
                                        SMTO_ABORTIFHUNG, 1000, &ignored);
                }
                PostMessageW(snapshot.dialog, WM_COMMAND,
                             MAKEWPARAM(accept ? IDOK : IDCANCEL, BN_CLICKED), 0);
                command_sent = true;
            }
        }
    }
    if (wait_result == WAIT_TIMEOUT) {
        if (snapshot.dialog) PostMessageW(snapshot.dialog, WM_CLOSE, 0, 0);
        wait_result = WaitForSingleObject(thread, 1000);
    }
    if (wait_result != WAIT_OBJECT_0) {
        CloseHandle(thread);
        throw std::runtime_error("config dialog did not terminate");
    }
    CloseHandle(thread);

    std::cout << "variant=" << (context.wide ? "W" : "A")
              << (context.null_buffer ? "-null" : "") << '\n';
    std::cout << "mode=" << context.mode << '\n';
    std::cout << "dialog-found=" << command_sent << '\n';
    const std::vector<std::string>& reported_lines = expanded_lines.empty() ? snapshot.lines : expanded_lines;
    for (const std::string& line : reported_lines) std::cout << line << '\n';
    std::cout << "result=" << context.result << '\n';
    std::cout << "buffer=" << (context.wide ? quote_wide(context.wide_buffer)
                                             : quote_bytes(context.ansi_buffer)) << '\n';
    std::cout << "win32-error=" << context.win32_error << '\n';
    std::cout << "compat-error=" << context.compat_error << '\n';
    std::cout << "compat-system-error=" << context.compat_system_error << '\n';
    return 0;
}

int run_command_probe(const wchar_t* dll_path, const wchar_t* command, const HWND owner = nullptr) {
    Module module(dll_path);
    std::vector<wchar_t> output(65536);
    SetLastError(0x12345678U);
    const int result = proc<FnUnlhaW>(module.handle, "UnlhaW")(
        owner, command, output.data(), static_cast<DWORD>(output.size()));
    const DWORD win32_error = GetLastError();
    DWORD system_error = 0x87654321U;
    const int compat_error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
    std::cout << "result=" << result << '\n';
    std::cout << "output=" << quote_wide(output.data()) << '\n';
    std::cout << "win32-error=" << win32_error << '\n';
    std::cout << "compat-error=" << compat_error << '\n';
    std::cout << "compat-system-error=" << system_error << '\n';
    return 0;
}

int run_registry_lifecycle_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                  RegistrySandbox& registry) {
    Module retained(dll_path);
    std::cout << "phase=initial\n";
    run_config_dialog_probe(dll_path, L"1", L"ok", L"W");
    registry.seed(L"C:OverWriteMode=0;C:DirectoryMode=0;C:JunkDirectory=1");
    std::cout << "phase=external-change\n";
    run_config_dialog_probe(dll_path, L"1", L"ok", L"W");
    std::cout << "phase=dialog-change\n";
    run_config_dialog_probe(dll_path, L"1", L"main:408", L"W");
    std::cout << "phase=dialog-reopen\n";
    run_config_dialog_probe(dll_path, L"1", L"ok", L"W");
    const std::wstring command = L"l -gm1 " + quote_argument(archive_path);
    std::cout << "phase=command\n";
    run_command_probe(dll_path, command.c_str());
    std::cout << "phase=after-command\n";
    run_config_dialog_probe(dll_path, L"1", L"ok", L"W");
    return 0;
}

int run_command_sequence_probe(const wchar_t* dll_path, const wchar_t* first, const wchar_t* second) {
    Module retained(dll_path);
    std::cout << "phase=first\n";
    run_command_probe(dll_path, first);
    std::cout << "phase=second\n";
    return run_command_probe(dll_path, second);
}

int run_command_raw_probe(const wchar_t* dll_path, const wchar_t* command, const wchar_t* api,
                          const DWORD capacity, const bool utf8 = false) {
    if (capacity > 4096) throw std::runtime_error("raw command probe capacity too large");
    Module module(dll_path);
    if (utf8) proc<FnBoolBool>(module.handle, "UnlhaSetUnicodeMode")(TRUE);
    std::vector<wchar_t> wide(capacity + 16, static_cast<wchar_t>(0xcccc));
    std::vector<unsigned char> narrow(capacity + 16, 0xcc);
    const bool is_wide = std::wcscmp(api, L"W") == 0;
    const std::string input = dictionary_command_utf8(command);
    const int result = is_wide
        ? proc<FnUnlhaW>(module.handle, "UnlhaW")(nullptr, command, wide.data() + 8, capacity)
        : proc<FnUnlhaA>(module.handle, std::wcscmp(api, L"A") == 0 ? "UnlhaA" : "Unlha")(
            nullptr, input.c_str(), reinterpret_cast<char*>(narrow.data() + 8), capacity);
    DWORD system_error = 0;
    const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
    std::cout << "result=" << result << ",error=" << error << ",system=" << system_error << ",raw=";
    for (size_t index = 0; index < capacity + 16; ++index)
        std::cout << std::hex << (is_wide ? static_cast<unsigned int>(wide[index]) : narrow[index]) << ',';
    std::cout << std::dec << '\n';
    return 0;
}

int run_command_probe_a(const wchar_t* dll_path, const wchar_t* command, const char* api = "Unlha",
                         const UINT code_page = 932, const HWND owner = nullptr) {
    Module module(dll_path);
    const DWORD conversion_flags = code_page == CP_UTF8 ? 0 : WC_NO_BEST_FIT_CHARS;
    const int command_size = WideCharToMultiByte(code_page, conversion_flags, command, -1,
                                                  nullptr, 0, nullptr, nullptr);
    if (command_size <= 0) throw std::runtime_error("command conversion failed");
    std::vector<char> command_a(static_cast<size_t>(command_size));
    if (!WideCharToMultiByte(code_page, conversion_flags, command, -1, command_a.data(),
                             command_size, nullptr, nullptr)) {
        throw std::runtime_error("command conversion failed");
    }
    std::vector<char> output(65536, static_cast<char>(0xcc));
    SetLastError(0x12345678U);
    const int result = proc<FnUnlhaA>(module.handle, api)(
        owner, command_a.data(), output.data(), static_cast<DWORD>(output.size()));
    const DWORD win32_error = GetLastError();
    DWORD system_error = 0x87654321U;
    const int compat_error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
    const size_t length = strnlen(output.data(), output.size());
    std::cout << "result=" << result << '\n';
    std::cout << "output-length=" << length << '\n';
    std::cout << "output=" << quote_bytes(output.data()) << '\n';
    std::cout << "win32-error=" << win32_error << '\n';
    std::cout << "compat-error=" << compat_error << '\n';
    std::cout << "compat-system-error=" << system_error << '\n';
    return 0;
}

int run_command_enum_probe(const wchar_t* dll_path, const wchar_t* command,
                           const wchar_t* layout, const BOOL selected,
                           const wchar_t* replacement, const LCID locale,
                           const bool utf8, const wchar_t* api, const bool with_progress,
                           const int abort_state = -1, const HWND owner = nullptr) {
    const LCID previous_locale = GetThreadLocale();
    struct RestoreEnumLocale final {
        LCID value;
        ~RestoreEnumLocale() { SetThreadLocale(value); }
    } restore_locale{previous_locale};
    if (locale && !SetThreadLocale(locale)) throw std::runtime_error("cannot set enum probe locale");
    Module retained(dll_path);
    if (utf8) proc<FnBoolBool>(retained.handle, "UnlhaSetUnicodeMode")(TRUE);
    std::cout << "enum.locale=" << GetThreadLocale() << '\n'
              << "enum.acp=" << GetACP() << '\n'
              << "enum.cp-before=" << proc<FnUInt0>(retained.handle, "UnlhaGetCP")() << '\n';
    const bool with_enum = _wcsicmp(layout, L"none") != 0;
    const bool wide = _wcsicmp(layout, L"w32") == 0 || _wcsicmp(layout, L"w64") == 0 ||
        (!with_enum && api && std::wcscmp(api, L"W") == 0);
    DWORD size = 0;
    if (_wcsicmp(layout, L"a32") == 0) {
        enum_layout = EnumLayout::A32;
        size = sizeof(UNLHA_ENUM_MEMBER_INFOA);
    } else if (_wcsicmp(layout, L"w32") == 0) {
        enum_layout = EnumLayout::W32;
        size = sizeof(UNLHA_ENUM_MEMBER_INFOW);
    } else if (_wcsicmp(layout, L"a64") == 0) {
        enum_layout = EnumLayout::A64;
        size = sizeof(UNLHA_ENUM_MEMBER_INFO64A);
    } else if (_wcsicmp(layout, L"w64") == 0) {
        enum_layout = EnumLayout::W64;
        size = sizeof(UNLHA_ENUM_MEMBER_INFO64W);
    } else if (!with_enum) {
        enum_layout = EnumLayout::None;
    } else {
        throw std::runtime_error("unknown command enum layout");
    }
    enum_result = selected;
    enum_records.clear();
    enum_replacement_file_a.clear();
    enum_replacement_file_w.clear();
    const bool replace_member = replacement && std::wcsncmp(replacement, L"@file:", 6) == 0;
    const wchar_t* replacement_value = replace_member ? replacement + 6 : replacement;
    enum_replacement_add_w = !replace_member && replacement_value ? replacement_value : L"";
    if (replace_member) enum_replacement_file_w = replacement_value;
    enum_replacement_add_a.clear();
    if (replacement) {
        char converted[MAX_PATH * 4]{};
        if (!WideCharToMultiByte(utf8 ? CP_UTF8 : 932, utf8 ? 0 : WC_NO_BEST_FIT_CHARS, replacement_value, -1,
                                 converted, sizeof(converted), nullptr, nullptr))
            throw std::runtime_error("enum replacement conversion failed");
        if (replace_member) enum_replacement_file_a = converted;
        else enum_replacement_add_a = converted;
    }
    const BOOL registered = !with_enum ? FALSE : enum_layout == EnumLayout::A32 || enum_layout == EnumLayout::W32
        ? proc<FnSetEnum>(retained.handle, wide ? "UnlhaSetEnumMembersProcW" : "UnlhaSetEnumMembersProcA")(enum_probe)
        : proc<FnSetEnum64>(retained.handle, "UnlhaSetEnumMembersProc64")(enum_probe, size);
    std::cout << "enum.set=" << registered << '\n';
    if (with_enum && !registered) throw std::runtime_error("command enum registration failed");
    struct EnumProgressWindow final {
        HWND handle = nullptr;
        ~EnumProgressWindow() { if (handle) DestroyWindow(handle); }
    } window;
    if (with_progress) {
        window.handle = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                                        HWND_MESSAGE, nullptr, nullptr, nullptr);
        if (!window.handle) throw std::runtime_error("cannot create enum progress window");
        progress_layout = wide ? ProgressLayout::Ex64W : ProgressLayout::Ex64A;
        progress_result = TRUE;
        progress_abort_state = abort_state;
        progress_expected_owner = nullptr;
        progress_records.clear();
        const BOOL owner_set = proc<FnSetOwnerEx64>(retained.handle, "UnlhaSetOwnerWindowEx64")(
            window.handle, progress_probe, wide ? sizeof(EXTRACTINGINFOEX64W) : sizeof(EXTRACTINGINFOEX64A));
        std::cout << "progress.set=" << owner_set << '\n';
        if (!owner_set) throw std::runtime_error("cannot register enum progress callback");
    }
    const bool wide_command = api ? std::wcscmp(api, L"W") == 0 : wide;
    const int result = wide_command ? run_command_probe(dll_path, command, owner)
        : run_command_probe_a(dll_path, command, api && std::wcscmp(api, L"A") == 0 ? "UnlhaA" : "Unlha",
                              utf8 ? CP_UTF8 : 932, owner);
    if (with_progress) {
        std::cout << "progress.kill=" << proc<FnKillOwnerEx>(retained.handle, "UnlhaKillOwnerWindowEx64")(
            window.handle) << '\n'
                  << "progress.count=" << progress_records.size() << '\n';
        for (const auto& record : progress_records) std::cout << "progress.entry=" << record << '\n';
    }
    std::cout << "enum.cp-after=" << proc<FnUInt0>(retained.handle, "UnlhaGetCP")() << '\n';
    std::cout << "enum.clear=" << (with_enum ? proc<FnBool0>(retained.handle, "UnlhaClearEnumMembersProc")() : FALSE) << '\n'
              << "enum.count=" << enum_records.size() << '\n';
    for (const auto& record : enum_records) std::cout << "enum.entry=" << record << '\n';
    enum_layout = EnumLayout::None;
    enum_result = TRUE;
    enum_replacement_add_a.clear();
    enum_replacement_add_w.clear();
    return result;
}

int run_enum_sequence_probe(const wchar_t* dll_path, const wchar_t* layout, LCID locale,
    bool utf8, const wchar_t* api, int count, wchar_t** steps, const wchar_t* progress_kind);

struct CommandDialogProbeContext final {
    const wchar_t* dll_path;
    const wchar_t* command;
    const wchar_t* layout;
    const wchar_t* api;
    LCID locale;
    LANGID language;
    bool utf8;
    const wchar_t* audit_archive;
    int step_count;
    wchar_t** steps;
    const wchar_t* progress_kind;
    int owner_mode;
    std::string failure;
};

DWORD WINAPI command_dialog_probe_thread(LPVOID raw_context) {
    auto& context = *static_cast<CommandDialogProbeContext*>(raw_context);
    try {
        struct ProbeOwnerWindow final {
            HWND handle = nullptr;
            ~ProbeOwnerWindow() { if (handle) DestroyWindow(handle); }
        } window;
        HWND owner = nullptr;
        if (context.owner_mode) {
            const DWORD visibility = context.owner_mode == 1 ? 0 : WS_VISIBLE;
            window.handle = CreateWindowExW(0, L"STATIC", L"Dialog probe owner",
                WS_OVERLAPPEDWINDOW | visibility, 160, 120, 700, 480, nullptr, nullptr, nullptr, nullptr);
            if (!window.handle) throw std::runtime_error("cannot create dialog probe owner");
            owner = window.handle;
            if (context.owner_mode == 3) {
                owner = CreateWindowExW(0, L"STATIC", L"Dialog probe child", WS_CHILD | WS_VISIBLE,
                    40, 50, 180, 90, window.handle, nullptr, nullptr, nullptr);
                if (!owner) throw std::runtime_error("cannot create dialog probe child");
            } else if (context.owner_mode == 4) {
                RECT work_area{};
                if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0))
                    throw std::runtime_error("cannot read dialog probe work area");
                SetWindowPos(owner, nullptr, work_area.right - 20, work_area.bottom - 20,
                    700, 480, SWP_NOZORDER | SWP_NOACTIVATE);
            }
        }
        Module retained(context.dll_path);
        if (context.language != 0xffff) {
            using FnLanguage = BOOL(WINAPI*)(LANGID);
            if (!proc<FnLanguage>(retained.handle, "UnlhaSetLangueSpecified")(context.language))
                throw std::runtime_error("cannot set command dialog language");
        }
        if (context.steps) {
            run_enum_sequence_probe(context.dll_path, context.layout, context.locale,
                context.utf8, context.api, context.step_count, context.steps, context.progress_kind);
        } else {
            run_command_enum_probe(context.dll_path, context.command, context.layout, TRUE,
                L"", context.locale, context.utf8, context.api, true, -1, owner);
        }
        if (context.audit_archive) {
            // DLL を保持したまま、CRC 分岐後と次の正常呼び出し後のハンドル解放を確認する。
            const auto audit = [&]() {
                const HANDLE file = CreateFileW(context.audit_archive, GENERIC_READ, 0, nullptr,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
                const DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
                if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
                std::cout << "archive-released=" << (file != INVALID_HANDLE_VALUE) << ",error=" << error << '\n';
            };
            audit();
            std::cout << "phase=after-crc\n";
            const std::wstring following = L"l -+ -gm1 -n1 " + quote_argument(context.audit_archive) + L" *";
            run_command_probe(context.dll_path, following.c_str());
            audit();
        }
        std::cout.flush();
    } catch (const std::exception& problem) {
        context.failure = problem.what();
    }
    return 0;
}

[[noreturn]] static void stop_command_dialog_probe(const UINT status, const char* reason,
                                                  const std::vector<std::string>& records) {
    // 観測専用・応答不足・時間超過では、このプローブだけを終了する。
    // 実行中の DLL を unload したり、他の検証プロセスを終了したりしない。
    for (const auto& record : records) std::cout << record << '\n';
    std::cout.flush();
    std::cerr << reason << std::endl;
    TerminateProcess(GetCurrentProcess(), status);
    ExitProcess(status);
}

BOOL CALLBACK find_command_dialog(HWND window, LPARAM raw_snapshot) {
    // -n0 の進捗画面も #32770 だが、応答待ちの確認画面ではない。
    // 実測した書庫名・項目名の Static 群で区別し、ボタン操作の対象から外す。
    bool progress_window = true;
    for (const int id : {601, 603, 604}) {
        wchar_t class_name[64]{};
        const HWND control = GetDlgItem(window, id);
        if (!control || !GetClassNameW(control, class_name, _countof(class_name)) ||
            _wcsicmp(class_name, L"Static") != 0) progress_window = false;
    }
    return progress_window ? TRUE : find_config_dialog(window, raw_snapshot);
}

static std::string snapshot_window_text(HWND window) {
    wchar_t text[1024]{};
    DWORD_PTR ignored = 0;
    if (!SendMessageTimeoutW(window, WM_GETTEXT, _countof(text), reinterpret_cast<LPARAM>(text),
                             SMTO_ABORTIFHUNG | SMTO_BLOCK, 50, &ignored)) return "<timeout>";
    return quote_wide(text);
}

static std::string snapshot_window_check(HWND window) {
    DWORD_PTR value = 0;
    if (!SendMessageTimeoutW(window, BM_GETCHECK, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 50, &value))
        return "<timeout>";
    return std::to_string(value);
}

BOOL CALLBACK snapshot_memory_progress_child(HWND window, LPARAM raw_snapshot) {
    auto& snapshot = *reinterpret_cast<DialogWindowSnapshot*>(raw_snapshot);
    wchar_t class_name[128]{};
    GetClassNameW(window, class_name, _countof(class_name));
    RECT rect{};
    GetWindowRect(window, &rect);
    MapWindowPoints(nullptr, snapshot.dialog, reinterpret_cast<POINT*>(&rect), 2);
    std::ostringstream line;
    line << "control." << snapshot.lines.size()
         << ".id=" << GetDlgCtrlID(window)
         << ",class=" << quote_wide(class_name)
         << ",text=" << snapshot_window_text(window)
         << ",check=" << snapshot_window_check(window)
         << ",enabled=" << IsWindowEnabled(window)
         << ",visible=" << IsWindowVisible(window)
         << ",style=" << static_cast<unsigned long>(GetWindowLongPtrW(window, GWL_STYLE))
         << ",rect=" << rect.left << ',' << rect.top << ',' << rect.right << ',' << rect.bottom;
    snapshot.lines.push_back(line.str());
    return TRUE;
}

BOOL CALLBACK find_memory_progress_dialog(HWND window, LPARAM raw_snapshot) {
    auto& snapshot = *reinterpret_cast<DialogWindowSnapshot*>(raw_snapshot);
    wchar_t class_name[64]{};
    GetClassNameW(window, class_name, _countof(class_name));
    if (std::wcscmp(class_name, L"#32770") != 0 || !IsWindowVisible(window) ||
        !IsWindowEnabled(window)) return TRUE;
    // 原版の -n0 メモリ展開画面は、書庫名・項目名・進捗を示すこの 3 つの Static を持つ。
    for (const int id : {601, 603, 604}) {
        HWND control = GetDlgItem(window, id);
        wchar_t control_class[64]{};
        if (!control || !GetClassNameW(control, control_class, _countof(control_class)) ||
            _wcsicmp(control_class, L"Static") != 0) return TRUE;
    }
    snapshot.dialog = window;
    return FALSE;
}

static void snapshot_memory_progress_dialog(HWND dialog, DialogWindowSnapshot& snapshot) {
    snapshot.dialog = dialog;
    snapshot.lines.push_back("dialog.title=" + snapshot_window_text(dialog));
    RECT client{};
    GetClientRect(dialog, &client);
    snapshot.lines.push_back("dialog.client=" + std::to_string(client.right) + "x" + std::to_string(client.bottom) +
                             ",style=" + std::to_string(static_cast<unsigned long>(GetWindowLongPtrW(dialog, GWL_STYLE))) +
                             ",exstyle=" + std::to_string(static_cast<unsigned long>(GetWindowLongPtrW(dialog, GWL_EXSTYLE))));
    EnumChildWindows(dialog, snapshot_memory_progress_child, reinterpret_cast<LPARAM>(&snapshot));
}

struct MemoryProgressDialogProbeContext final {
    HMODULE module{};
    std::wstring command;
    LANGID language{0xffff};
    std::vector<BYTE> buffer;
    int result{};
    DWORD written{};
    time_t timestamp{};
    WORD attributes{};
    int error{};
    DWORD system_error{};
    bool inspect_quit{};
    bool quit_pending{};
    std::string failure;
};

enum class MemoryProgressDialogProbeAction {
    Observe,
    Complete,
    Cancel,
    Quit
};

static constexpr unsigned long long kMemoryProgressDialogProbeMaximumCapacity = 4ULL * 1024 * 1024;

DWORD WINAPI memory_progress_dialog_probe_thread(LPVOID raw_context) {
    auto& context = *reinterpret_cast<MemoryProgressDialogProbeContext*>(raw_context);
    try {
        if (context.language != 0xffff) {
            using FnLanguage = BOOL(WINAPI*)(LANGID);
            if (!proc<FnLanguage>(context.module, "UnlhaSetLangueSpecified")(context.language))
                throw std::runtime_error("cannot set memory progress dialog language");
        }
        context.result = proc<FnExtractMemW>(context.module, "UnlhaExtractMemW")(
            nullptr, context.command.c_str(), context.buffer.data(), static_cast<DWORD>(context.buffer.size()),
            &context.timestamp, &context.attributes, &context.written);
        context.error = proc<FnLastError>(context.module, "UnlhaGetLastError")(&context.system_error);
        if (context.inspect_quit) {
            MSG message{};
            context.quit_pending = PeekMessageW(&message, nullptr, WM_QUIT, WM_QUIT, PM_NOREMOVE) != FALSE;
        }
    } catch (const std::exception& problem) {
        context.failure = problem.what();
    }
    return 0;
}

int run_memory_progress_dialog_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                      const wchar_t* switches, const DWORD capacity,
                                      const MemoryProgressDialogProbeAction action,
                                      const LANGID language = 0xffff) {
    if (!isolated_desktop::is_isolated())
        throw std::runtime_error("memory progress dialog probe requires the isolated desktop");
    Module module(dll_path);
    MemoryProgressDialogProbeContext context{};
    context.module = module.handle;
    context.command = std::wstring(switches) + L" " + quote_argument(archive_path) + L" *";
    context.language = language;
    context.inspect_quit = action == MemoryProgressDialogProbeAction::Quit;
    context.buffer.resize(capacity);
    DWORD thread_id = 0;
    const HANDLE thread = CreateThread(nullptr, 0, memory_progress_dialog_probe_thread, &context, 0, &thread_id);
    if (!thread) throw std::runtime_error("cannot start memory progress dialog thread");

    std::vector<std::string> records;
    bool observed = false;
    // 軽い展開でも作成直後のモデルレス画面を取り逃さないよう、10 秒の観測枠を細かく刻む。
    for (int attempt = 0; attempt < 10000; ++attempt) {
        const DWORD wait = WaitForSingleObject(thread, 1);
        if (wait == WAIT_OBJECT_0) {
            CloseHandle(thread);
            if (!context.failure.empty()) throw std::runtime_error(context.failure);
            for (const auto& record : records) std::cout << record << '\n';
            std::cout << "memory-dialog.complete=" << observed << ",result=" << context.result
                      << ",error=" << context.error << ",system=" << context.system_error
                      << ",written=" << context.written << '\n';
            if (context.inspect_quit)
                std::cout << "memory-dialog.quit-pending=" << context.quit_pending << '\n';
            return 0;
        }
        if (wait != WAIT_TIMEOUT) {
            CloseHandle(thread);
            throw std::runtime_error("memory progress dialog wait failed: " + std::to_string(GetLastError()));
        }
        DialogWindowSnapshot snapshot{};
        EnumThreadWindows(thread_id, find_memory_progress_dialog, reinterpret_cast<LPARAM>(&snapshot));
        if (!snapshot.dialog || observed) continue;
        if (!IsWindow(snapshot.dialog)) continue;
        snapshot_memory_progress_dialog(snapshot.dialog, snapshot);
        records.push_back("memory-dialog.present=1");
        records.insert(records.end(), snapshot.lines.begin(), snapshot.lines.end());
        observed = true;
        if (action == MemoryProgressDialogProbeAction::Observe) {
            CloseHandle(thread);
            stop_command_dialog_probe(125, "memory progress dialog observation completed", records);
        }
        if (action == MemoryProgressDialogProbeAction::Cancel &&
            !PostMessageW(snapshot.dialog, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED),
                          reinterpret_cast<LPARAM>(GetDlgItem(snapshot.dialog, IDOK)))) {
            CloseHandle(thread);
            throw std::runtime_error("cannot cancel memory progress dialog: " + std::to_string(GetLastError()));
        }
        if (action == MemoryProgressDialogProbeAction::Quit &&
            !PostThreadMessageW(thread_id, WM_QUIT, 0, 0)) {
            CloseHandle(thread);
            throw std::runtime_error("cannot post memory progress dialog quit: " + std::to_string(GetLastError()));
        }
    }
    CloseHandle(thread);
    stop_command_dialog_probe(124, "memory progress dialog probe timed out", records);
}

int run_command_dialog_probe(const wchar_t* dll_path, const wchar_t* command,
                             const wchar_t* responses, const wchar_t* layout,
                             const bool utf8, const wchar_t* api, const LCID locale,
                             const LANGID language, const wchar_t* audit_archive,
                             const int step_count = 0, wchar_t** steps = nullptr,
                             const wchar_t* progress_kind = nullptr, const bool settle_filename_dialog = false) {
    if (!isolated_desktop::is_isolated())
        throw std::runtime_error("command dialogs require the isolated desktop");
    std::wstring dialog_audit_archive;
    LANGID initial_language = language;
    bool initial_language_set = false;
    std::vector<wchar_t*> command_steps;
    for (int index = 0; index < step_count; ++index) {
        if (std::wcsncmp(steps[index], L"@initial-language:", 18) == 0) {
            const std::wstring value = steps[index] + 18;
            if (initial_language_set || (value != L"0" && value != L"1033" && value != L"1041"))
                throw std::runtime_error("invalid initial dialog language");
            initial_language = static_cast<LANGID>(std::wcstoul(value.c_str(), nullptr, 10));
            initial_language_set = true;
            continue;
        }
        command_steps.push_back(steps[index]);
        if (std::wcsncmp(steps[index], L"@audit-dialog-archive:", 22) != 0) continue;
        dialog_audit_archive = steps[index] + 22;
        if (dialog_audit_archive.size() < 3 || dialog_audit_archive[1] != L':' ||
            (dialog_audit_archive[2] != L'\\' && dialog_audit_archive[2] != L'/'))
            throw std::runtime_error("dialog archive audit requires an absolute path");
    }
    if (steps && command_steps.empty())
        throw std::runtime_error("dialog command sequence required after initial language");
    struct DialogResponse final { int radio; int button; std::wstring file; };
    std::vector<DialogResponse> buttons;
    int owner_mode = 0;
    if (std::wcsncmp(responses, L"inspect-layout:", 15) == 0) {
        const std::wstring mode = responses + 15;
        owner_mode = mode == L"hidden" ? 1 : mode == L"visible" ? 2 :
            mode == L"child" ? 3 : mode == L"offscreen" ? 4 : 0;
        if (!owner_mode || steps) throw std::runtime_error("invalid standalone dialog owner inspection");
    }
    const bool inspect_geometry = std::wcscmp(responses, L"inspect-layout") == 0 || owner_mode != 0;
    const bool inspect = std::wcscmp(responses, L"inspect") == 0 || inspect_geometry;
    if (!inspect) {
        const wchar_t* cursor = responses;
        while (*cursor) {
            std::wstring selected_file;
            if (std::wcsncmp(cursor, L"file:", 5) == 0) {
                cursor += 5;
                const wchar_t* hex_end = std::wcschr(cursor, L':');
                if (!hex_end || hex_end == cursor || (hex_end - cursor) % 4 != 0 ||
                    (hex_end - cursor) / 4 >= 512)
                    throw std::runtime_error("invalid dialog filename encoding");
                while (cursor < hex_end) {
                    unsigned value = 0;
                    for (int digit = 0; digit < 4; ++digit, ++cursor) {
                        const wchar_t character = *cursor;
                        const int number = character >= L'0' && character <= L'9' ? character - L'0' :
                            character >= L'A' && character <= L'F' ? character - L'A' + 10 :
                            character >= L'a' && character <= L'f' ? character - L'a' + 10 : -1;
                        if (number < 0) throw std::runtime_error("invalid dialog filename encoding");
                        value = value * 16 + static_cast<unsigned>(number);
                    }
                    if (value < 32) throw std::runtime_error("invalid dialog filename character");
                    selected_file.push_back(static_cast<wchar_t>(value));
                }
                if (selected_file.size() < 4 || selected_file[1] != L':' ||
                    (selected_file[2] != L'\\' && selected_file[2] != L'/'))
                    throw std::runtime_error("dialog filename requires an absolute path");
                ++cursor;
            }
            wchar_t* end = nullptr;
            long button = std::wcstol(cursor, &end, 10);
            if (end == cursor || button < 1 || button > 65535)
                throw std::runtime_error("invalid dialog button sequence");
            int radio = 0;
            if (*end == L':') {
                if (!selected_file.empty()) throw std::runtime_error("filename cannot select a radio");
                radio = static_cast<int>(button);
                cursor = end + 1;
                button = std::wcstol(cursor, &end, 10);
                if (end == cursor || button < 1 || button > 65535)
                    throw std::runtime_error("invalid dialog radio response");
            }
            if (*end && *end != L',') throw std::runtime_error("invalid dialog button sequence");
            buttons.push_back({radio, static_cast<int>(button), std::move(selected_file)});
            cursor = *end ? end + 1 : end;
        }
        if (buttons.empty()) throw std::runtime_error("dialog response required");
    }
    if (audit_archive && (wcslen(audit_archive) < 3 || audit_archive[1] != L':' ||
        (audit_archive[2] != L'\\' && audit_archive[2] != L'/')))
        throw std::runtime_error("command dialog release audit requires an absolute path");
    // 単発プローブと同じく、通知登録前の言語指定も選べる。通常の @language は系列内に残す。
    CommandDialogProbeContext context{dll_path, command, layout, api, locale, initial_language, utf8,
        audit_archive, static_cast<int>(command_steps.size()), steps ? command_steps.data() : nullptr,
        progress_kind, owner_mode, {}};
    std::vector<std::string> records;
    DWORD thread_id = 0;
    const HANDLE thread = CreateThread(nullptr, 0, command_dialog_probe_thread, &context, 0, &thread_id);
    if (!thread) throw std::runtime_error("cannot start command dialog thread");
    const ULONGLONG started = GetTickCount64();
    HWND answered = nullptr;
    HWND settling_dialog = nullptr;
    ULONGLONG settling_started = 0, stable_since = 0;
    std::vector<std::string> settling_lines;
    size_t count = 0;
    for (;;) {
        const DWORD wait = WaitForSingleObject(thread, 20);
        if (wait == WAIT_OBJECT_0) break;
        if (wait != WAIT_TIMEOUT || GetTickCount64() - started > 20000)
            stop_command_dialog_probe(124, "command dialog probe timed out", records);
        DialogWindowSnapshot snapshot{};
        // この DLL を呼んだスレッドだけが対象。他のデスクトップやウィンドウは探索しない。
        EnumThreadWindows(thread_id, find_command_dialog, reinterpret_cast<LPARAM>(&snapshot));
        if (!snapshot.dialog || snapshot.dialog == answered) continue;
        bool native_file_edit = false;
        if (settle_filename_dialog) EnumChildWindows(snapshot.dialog, [](HWND child, LPARAM data) -> BOOL {
            wchar_t class_name[64]{};
            if (GetDlgCtrlID(child) == 1001 && IsWindowVisible(child) && IsWindowEnabled(child) &&
                GetClassNameW(child, class_name, _countof(class_name)) && _wcsicmp(class_name, L"Edit") == 0)
                *reinterpret_cast<bool*>(data) = true;
            return TRUE;
        }, reinterpret_cast<LPARAM>(&native_file_edit));
        if (native_file_edit) {
            // 保存画面のShellツリーは表示後も構築されるため、入力前に部品全体の安定を確認する。
            const ULONGLONG now = GetTickCount64();
            if (settling_dialog != snapshot.dialog) {
                settling_dialog = snapshot.dialog;
                settling_started = stable_since = now;
                settling_lines = snapshot.lines;
            } else if (settling_lines != snapshot.lines) {
                stable_since = now;
                settling_lines = snapshot.lines;
            }
            if (now - settling_started > 3000)
                stop_command_dialog_probe(124, "native filename dialog did not settle", records);
            if (now - settling_started < 500 || now - stable_since < 300) continue;
        } else {
            settling_dialog = nullptr;
        }
        // DLL 呼び出し側と同時に ostream へ書かず、終了後に観測順で出力する。
        records.push_back("command-dialog.begin=" + std::to_string(count));
        records.insert(records.end(), snapshot.lines.begin(), snapshot.lines.end());
        if (inspect_geometry) {
            RECT outer{}, client{};
            GetWindowRect(snapshot.dialog, &outer);
            GetClientRect(snapshot.dialog, &client);
            records.push_back("dialog.position=" + std::to_string(outer.left) + "," +
                std::to_string(outer.top));
            records.push_back("dialog.geometry=" + std::to_string(outer.right - outer.left) + "," +
                std::to_string(outer.bottom - outer.top) + ",client=" + std::to_string(client.right) + "," +
                std::to_string(client.bottom));
            LOGFONTW font{};
            const HFONT handle = reinterpret_cast<HFONT>(SendMessageW(snapshot.dialog, WM_GETFONT, 0, 0));
            if (handle && GetObjectW(handle, sizeof(font), &font))
                records.push_back("dialog.font=" + quote_wide(font.lfFaceName) + ",height=" +
                    std::to_string(font.lfHeight) + ",weight=" + std::to_string(font.lfWeight));
            for (HWND child = GetWindow(snapshot.dialog, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
                RECT rect{};
                GetWindowRect(child, &rect);
                MapWindowPoints(nullptr, snapshot.dialog, reinterpret_cast<POINT*>(&rect), 2);
                records.push_back("control.geometry=" + std::to_string(GetDlgCtrlID(child)) + "," +
                    std::to_string(rect.left) + "," + std::to_string(rect.top) + "," +
                    std::to_string(rect.right - rect.left) + "," + std::to_string(rect.bottom - rect.top));
            }
        }
        if (!dialog_audit_archive.empty()) {
            const HANDLE file = CreateFileW(dialog_audit_archive.c_str(), GENERIC_READ, 0, nullptr,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            const DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
            if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
            records.push_back("dialog.archive-released=" + std::to_string(file != INVALID_HANDLE_VALUE) +
                ",error=" + std::to_string(error));
        }
        records.push_back("command-dialog.end=" + std::to_string(count));
        if (inspect) stop_command_dialog_probe(125, "command dialog observation completed", records);
        if (count >= buttons.size())
            stop_command_dialog_probe(126, "command dialog response sequence exhausted", records);
        if (!buttons[count].file.empty()) {
            struct FileEdit final { HWND window = nullptr; unsigned count = 0; } edit;
            EnumChildWindows(snapshot.dialog, [](HWND child, LPARAM data) -> BOOL {
                auto& found = *reinterpret_cast<FileEdit*>(data);
                wchar_t class_name[64]{};
                if (GetDlgCtrlID(child) == 1001 && IsWindowVisible(child) && IsWindowEnabled(child) &&
                    GetClassNameW(child, class_name, _countof(class_name)) &&
                    _wcsicmp(class_name, L"Edit") == 0) {
                    found.window = child;
                    ++found.count;
                }
                return TRUE;
            }, reinterpret_cast<LPARAM>(&edit));
            DWORD_PTR delivered = 0;
            wchar_t actual[512]{};
            if (edit.count != 1 ||
                !SendMessageTimeoutW(edit.window, EM_SETSEL, 0, -1,
                    SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &delivered) ||
                !SendMessageTimeoutW(edit.window, EM_REPLACESEL, TRUE,
                    reinterpret_cast<LPARAM>(buttons[count].file.c_str()), SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &delivered) ||
                !SendMessageTimeoutW(edit.window, WM_GETTEXT, _countof(actual),
                    reinterpret_cast<LPARAM>(actual), SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &delivered) ||
                buttons[count].file != actual)
                stop_command_dialog_probe(126, "cannot enter the selected dialog filename", records);
            records.push_back("command-dialog.file=" + quote_wide(actual));
        }
        const int button = buttons[count].button;
        const HWND control = GetDlgItem(snapshot.dialog, button);
        wchar_t class_name[64]{};
        if (control) GetClassNameW(control, class_name, _countof(class_name));
        if (!control || !IsWindowEnabled(control) || _wcsicmp(class_name, L"Button") != 0)
            stop_command_dialog_probe(126, "requested dialog button is not available", records);
        if (buttons[count].radio != 0) {
            const int radio_id = buttons[count].radio;
            const HWND radio = GetDlgItem(snapshot.dialog, radio_id);
            wchar_t radio_class[64]{};
            if (radio) GetClassNameW(radio, radio_class, _countof(radio_class));
            if (!radio || !IsWindowEnabled(radio) || _wcsicmp(radio_class, L"Button") != 0 ||
                (GetWindowLongPtrW(radio, GWL_STYLE) & BS_TYPEMASK) != BS_AUTORADIOBUTTON)
                stop_command_dialog_probe(126, "requested dialog radio is not available", records);
            // 利用者の選択と同じクリックを送り、チェックされたことを確認してから確定する。
            DWORD_PTR checked = 0;
            if (!SendMessageTimeoutW(radio, BM_CLICK, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &checked) ||
                !SendMessageTimeoutW(radio, BM_GETCHECK, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &checked) ||
                checked != BST_CHECKED)
                stop_command_dialog_probe(126, "cannot select dialog radio", records);
            records.push_back("command-dialog.radio=" + std::to_string(radio_id) + ",check=1");
        }
        records.push_back("command-dialog.response=" + std::to_string(button));
        answered = snapshot.dialog;
        ++count;
        if (!PostMessageW(snapshot.dialog, WM_COMMAND, MAKEWPARAM(button, BN_CLICKED),
                          reinterpret_cast<LPARAM>(control)))
            stop_command_dialog_probe(126, "cannot send dialog response", records);
    }
    CloseHandle(thread);
    for (const auto& record : records) std::cout << record << '\n';
    if (!context.failure.empty()) throw std::runtime_error(context.failure);
    std::cout << "command-dialog.count=" << count << std::endl;
    return 0;
}

// 原版・候補への入力日時と直後の値を、専用プローブ内だけで観測する。
static BOOL WINAPI audit_directory_set_time(HANDLE file, const FILETIME* create,
                                           const FILETIME* access, const FILETIME* write) {
    const DWORD previous_error = GetLastError();
    BY_HANDLE_FILE_INFORMATION info{};
    const bool directory = GetFileInformationByHandle(file, &info) &&
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    SetLastError(previous_error);
    const BOOL result = SetFileTime(file, create, access, write);
    const DWORD error = GetLastError();
    if (directory) {
        FILETIME actual_create{}, actual_access{}, actual_write{};
        const BOOL queried = GetFileTime(file, &actual_create, &actual_access, &actual_write);
        const auto ticks = [](const FILETIME* value) -> ULONGLONG {
            return value ? (static_cast<ULONGLONG>(value->dwHighDateTime) << 32) | value->dwLowDateTime : 0;
        };
        std::cout << "directory-set-time=result=" << result << ",queried=" << queried
            << ",create=" << ticks(create) << ",access=" << ticks(access) << ",write=" << ticks(write)
            << ",actual-create=" << ticks(&actual_create) << ",actual-access=" << ticks(&actual_access)
            << ",actual-write=" << ticks(&actual_write) << '\n';
    }
    SetLastError(error);
    return result;
}

static DWORD controlled_tick = 0;
static unsigned int priority_fail_call = 0;
static unsigned int priority_call_count = 0;
static unsigned int priority_get_fail_call = 0;
static unsigned int priority_get_call_count = 0;
static HMODULE memory_reentry_module = nullptr;
static std::wstring memory_reentry_command;
static std::string memory_reentry_command_a;
static bool memory_reentry_active = false;
static void audit_memory_reentry() {
    if (memory_reentry_active) throw std::runtime_error("unexpected nested memory callback");
    memory_reentry_active = true;
    struct Reset final { ~Reset() { memory_reentry_active = false; } } reset;
    using NarrowExtract = int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD);
    for (unsigned api = 0; api < 3; ++api) {
        for (unsigned input = 0; input < 4; ++input) {
            BYTE buffer[32]{};
            DWORD written = 123456;
            LPBYTE output = input == 2 ? nullptr : buffer;
            const DWORD capacity = input == 3 ? 0 : sizeof(buffer);
            const int before = GetThreadPriority(GetCurrentThread());
            const int result = api == 2
                ? proc<FnExtractMemW>(memory_reentry_module, "UnlhaExtractMemW")(
                    nullptr, input == 1 ? L"" : memory_reentry_command.c_str(), output, capacity, nullptr, nullptr, &written)
                : proc<NarrowExtract>(memory_reentry_module, api == 0 ? "UnlhaExtractMem" : "UnlhaExtractMemA")(
                    nullptr, input == 1 ? "" : memory_reentry_command_a.c_str(), output, capacity, nullptr, nullptr, &written);
            std::cout << "memory-reentry=" << api << ',' << input << ",result=" << result << ",written=" << written
                      << ",before=" << before << ",after=" << GetThreadPriority(GetCurrentThread()) << '\n';
        }
    }
}
static int WINAPI audited_get_thread_priority(HANDLE thread) {
    ++priority_get_call_count;
    int result = THREAD_PRIORITY_ERROR_RETURN;
    if (priority_get_fail_call && priority_get_call_count == priority_get_fail_call) SetLastError(ERROR_ACCESS_DENIED);
    else result = GetThreadPriority(thread);
    const DWORD error = GetLastError();
    std::cout << "priority-get=" << result << '\n';
    SetLastError(error);
    return result;
}
static BOOL WINAPI audited_set_thread_priority(HANDLE thread, int priority) {
    ++priority_call_count;
    BOOL result = FALSE;
    if (priority_fail_call && priority_call_count == priority_fail_call) SetLastError(ERROR_ACCESS_DENIED);
    else result = SetThreadPriority(thread, priority);
    const DWORD error = GetLastError();
    std::cout << "priority-call=" << priority << ",result=" << result
              << ",actual=" << GetThreadPriority(thread) << '\n';
    SetLastError(error);
    return result;
}
static DWORD controlled_tick_step = 0;
static DWORD WINAPI controlled_get_tick_count() {
    const DWORD value = controlled_tick;
    controlled_tick += controlled_tick_step;
    return value;
}
static uintptr_t sleep_audit_module_base = 0;
static uintptr_t sleep_audit_module_end = 0;
static void WINAPI audited_sleep(DWORD duration) {
    const DWORD error = GetLastError();
    std::cout << "sleep-audit=" << duration << '\n';
    std::cout << "sleep-audit-site=" << std::hex
              << (reinterpret_cast<uintptr_t>(_ReturnAddress()) - sleep_audit_module_base)
              << std::dec << '\n';
    void* frames[8]{};
    const USHORT count = CaptureStackBackTrace(1, _countof(frames), frames, nullptr);
    std::cout << "sleep-audit-stack=" << std::hex;
    for (USHORT index = 0; index < count; ++index) {
        const uintptr_t address = reinterpret_cast<uintptr_t>(frames[index]);
        if (address >= sleep_audit_module_base && address < sleep_audit_module_end)
            std::cout << (address - sleep_audit_module_base) << ':';
    }
    std::cout << std::dec << '\n';
    SetLastError(error);
}

struct ScopedImportOverride final {
    DWORD* slot = nullptr;
    DWORD original = 0;
    void assign(DWORD value) const {
        DWORD protect = 0, ignored = 0;
        if (!VirtualProtect(slot, sizeof(DWORD), PAGE_READWRITE, &protect))
            throw std::runtime_error("cannot protect time audit import");
        *slot = value;
        if (!VirtualProtect(slot, sizeof(DWORD), protect, &ignored))
            throw std::runtime_error("cannot restore time audit import protection");
    }
    void install(HMODULE module, const char* function_name, DWORD expected, DWORD replacement,
                 bool allow_missing = false) {
        if (slot) throw std::runtime_error("time audit already installed");
        const auto base = reinterpret_cast<BYTE*>(module);
        const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
        if (nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC)
            throw std::runtime_error("time audit requires PE32");
        auto descriptor = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(base +
            nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
        for (; descriptor->Name; ++descriptor) {
            if (!descriptor->OriginalFirstThunk) continue;
            auto name = reinterpret_cast<const IMAGE_THUNK_DATA32*>(base + descriptor->OriginalFirstThunk);
            auto address = reinterpret_cast<IMAGE_THUNK_DATA32*>(base + descriptor->FirstThunk);
            for (; name->u1.AddressOfData; ++name, ++address) {
                if (IMAGE_SNAP_BY_ORDINAL32(name->u1.Ordinal)) continue;
                const auto imported = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(base + name->u1.AddressOfData);
                if (std::strcmp(reinterpret_cast<const char*>(imported->Name), function_name)) continue;
                if (address->u1.Function != expected)
                    throw std::runtime_error("unexpected time audit import");
                slot = &address->u1.Function;
                original = *slot;
                assign(replacement);
                return;
            }
        }
        if (!allow_missing) throw std::runtime_error(std::string(function_name) + " import missing");
    }
    void install_data_pointer(HMODULE module, DWORD expected, DWORD replacement, bool allow_missing = false) {
        if (slot) throw std::runtime_error("API override already installed");
        const auto base = reinterpret_cast<BYTE*>(module);
        const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
        if (nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC)
            throw std::runtime_error("API override requires PE32");
        DWORD* found = nullptr;
        const auto sections = IMAGE_FIRST_SECTION(nt);
        for (WORD index = 0; index < nt->FileHeader.NumberOfSections; ++index) {
            const auto& section = sections[index];
            if (!(section.Characteristics & IMAGE_SCN_MEM_WRITE) ||
                !(section.Characteristics & IMAGE_SCN_CNT_INITIALIZED_DATA)) continue;
            if (section.VirtualAddress >= nt->OptionalHeader.SizeOfImage ||
                section.Misc.VirtualSize > nt->OptionalHeader.SizeOfImage - section.VirtualAddress)
                throw std::runtime_error("invalid API pointer section");
            auto values = reinterpret_cast<DWORD*>(base + section.VirtualAddress);
            for (DWORD offset = 0; offset < section.Misc.VirtualSize / sizeof(DWORD); ++offset) {
                if (values[offset] != expected) continue;
                if (found) throw std::runtime_error("ambiguous dynamic API pointer");
                found = values + offset;
            }
        }
        if (!found) {
            if (allow_missing) return;
            throw std::runtime_error("dynamic API pointer missing");
        }
        slot = found;
        original = *slot;
        assign(replacement);
    }
    ~ScopedImportOverride() {
        if (slot) { try { assign(original); } catch (...) { std::terminate(); } }
    }
};

using SaveFileNameWFunction = BOOL(WINAPI*)(LPOPENFILENAMEW);
static SaveFileNameWFunction filename_dialog_real = nullptr;
static std::vector<std::wstring> filename_dialog_selections;
static size_t filename_dialog_used = 0;
static std::string filename_dialog_failure;

static std::wstring normalized_absolute_filename(const wchar_t* path) {
    wchar_t full[32768]{};
    const DWORD length = GetFullPathNameW(path, _countof(full), full, nullptr);
    if (!length || length >= _countof(full)) throw std::runtime_error("cannot normalize selected filename");
    std::wstring value = full;
    std::replace(value.begin(), value.end(), L'/', L'\\');
    return value;
}

static BOOL WINAPI audited_save_filename(LPOPENFILENAMEW options) {
    const DWORD previous_error = GetLastError();
    try {
        if (!options || options->lStructSize < OPENFILENAME_SIZE_VERSION_400W ||
            !options->lpstrFile || !options->nMaxFile || options->nMaxFile > 32768)
            throw std::runtime_error("invalid save filename request");
        std::wstring filter;
        if (options->lpstrFilter) {
            const wchar_t* part = options->lpstrFilter;
            size_t used = 0;
            while (*part && used < 1024) {
                const size_t size = wcsnlen_s(part, 1024 - used);
                if (size >= 1024 - used) throw std::runtime_error("unterminated save filename filter");
                filter.append(part, size);
                filter += L'|';
                part += size + 1;
                used += size + 1;
            }
        }
        std::cout << "filename-dialog.request=size=" << options->lStructSize << ",flags=" << options->Flags
                  << ",owner=" << (options->hwndOwner != nullptr) << ",file=" << quote_wide(options->lpstrFile)
                  << ",capacity=" << options->nMaxFile << ",title-capacity=" << options->nMaxFileTitle
                  << ",filter=" << quote_wide(filter.c_str()) << ",filter-index=" << options->nFilterIndex
                  << ",initial=" << quote_wide(options->lpstrInitialDir ? options->lpstrInitialDir : L"")
                  << ",title=" << quote_wide(options->lpstrTitle ? options->lpstrTitle : L"")
                  << ",extension=" << quote_wide(options->lpstrDefExt ? options->lpstrDefExt : L"") << '\n';
        if (filename_dialog_used >= filename_dialog_selections.size())
            throw std::runtime_error("save filename responses exhausted");
        const auto& choice = filename_dialog_selections[filename_dialog_used++];
        if (choice == L"cancel") { SetLastError(previous_error); return FALSE; }
        const bool native = choice.rfind(L"native:", 0) == 0;
        const std::wstring path = native ? choice.substr(7) : choice;
        if (native) {
            const BOOL accepted = filename_dialog_real(options);
            if (path == L"cancel") {
                if (accepted) throw std::runtime_error("native filename cancellation unexpectedly accepted a path");
                return FALSE;
            }
            if (!accepted) throw std::runtime_error("native filename selection was not accepted");
            // 名前入力が反映されなかった場合、元 DLL が想定外の場所へ書く前に拒否する。
            if (_wcsicmp(normalized_absolute_filename(options->lpstrFile).c_str(),
                         normalized_absolute_filename(path.c_str()).c_str()) != 0) {
                std::cout << "filename-dialog.unexpected=" << quote_wide(options->lpstrFile) << '\n';
                throw std::runtime_error("native filename selection differed from the audited path");
            }
        } else {
            if (path.size() >= options->nMaxFile) throw std::runtime_error("selected filename exceeds the caller buffer");
            wcscpy_s(options->lpstrFile, options->nMaxFile, path.c_str());
            const size_t slash = path.find_last_of(L"/\\");
            std::wstring parent = path.substr(0, slash);
            while (GetFileAttributesW(parent.c_str()) == INVALID_FILE_ATTRIBUTES && parent.size() > 3) {
                const size_t separator = parent.find_last_of(L"/\\");
                if (separator == std::wstring::npos) break;
                parent.resize(separator == 2 ? 3 : separator);
            }
            if (!SetCurrentDirectoryW(parent.c_str())) throw std::runtime_error("cannot exercise filename working-directory restoration");
            // フォルダーを移動して保存した場合と同様に、呼び出し元によるCWD復元を検査する。
            SetLastError(previous_error);
        }
        std::cout << "filename-dialog.selected=" << quote_wide(options->lpstrFile) << '\n';
        return TRUE;
    } catch (const std::exception& problem) {
        filename_dialog_failure = problem.what();
        SetLastError(previous_error);
        return FALSE;
    }
}

int run_filename_dialog_probe(const wchar_t* dll_path, const wchar_t* command,
                              const wchar_t* responses, const wchar_t* layout,
                              const bool utf8, const wchar_t* api, const LCID locale,
                              const LANGID language, const wchar_t* selections,
                              const int step_count = 0, wchar_t** steps = nullptr,
                              const wchar_t* progress_kind = nullptr) {
    filename_dialog_selections.clear();
    filename_dialog_failure.clear();
    filename_dialog_used = 0;
    std::wistringstream stream(std::wcscmp(selections, L"none") == 0 ? L"" : selections);
    std::wstring selected;
    while (std::getline(stream, selected, L'|')) {
        const auto path = selected.rfind(L"native:", 0) == 0 ? selected.substr(7) : selected;
        if (path != L"cancel" && (path.size() < 4 || path.size() >= 512 || path[1] != L':' ||
            (path[2] != L'\\' && path[2] != L'/')))
            throw std::runtime_error("save filename response requires an absolute path or cancel");
        filename_dialog_selections.push_back(selected);
    }
    if (filename_dialog_selections.empty() && std::wcscmp(selections, L"none") != 0)
        throw std::runtime_error("save filename response required");
    wchar_t before[32768]{}, after[32768]{};
    if (!GetCurrentDirectoryW(_countof(before), before)) throw std::runtime_error("cannot capture filename working directory");
    Module common(L"comdlg32.dll");
    filename_dialog_real = proc<SaveFileNameWFunction>(common.handle, "GetSaveFileNameW");
    Module retained(dll_path);
    ScopedImportOverride hook;
    hook.install(retained.handle, "GetSaveFileNameW", reinterpret_cast<DWORD>(filename_dialog_real),
                 reinterpret_cast<DWORD>(audited_save_filename), true);
    if (!hook.slot) hook.install_data_pointer(retained.handle, reinterpret_cast<DWORD>(filename_dialog_real),
                                             reinterpret_cast<DWORD>(audited_save_filename));
    const int result = run_command_dialog_probe(dll_path, command, responses, layout, utf8, api, locale,
        language, nullptr, step_count, steps, progress_kind, true);
    if (!GetCurrentDirectoryW(_countof(after), after)) throw std::runtime_error("cannot capture final filename working directory");
    const bool restored = std::wcscmp(before, after) == 0;
    std::cout << "filename-dialog.requests=" << filename_dialog_used << ",cwd-preserved=" << restored << std::endl;
    if (!filename_dialog_failure.empty()) throw std::runtime_error(filename_dialog_failure);
    if (!restored || filename_dialog_used != filename_dialog_selections.size())
        throw std::runtime_error("save filename calls or working-directory restoration differ");
    return result;
}

static std::vector<ULONGLONG> disk_space_values;
static std::vector<std::string> disk_space_observations;
static size_t disk_space_used = 0;
static bool disk_space_probe_failed = false;

static BOOL audited_disk_space(const wchar_t* path, PULARGE_INTEGER available,
                               PULARGE_INTEGER total, PULARGE_INTEGER free) {
    const DWORD previous_error = GetLastError();
    try {
        const ULONGLONG value = disk_space_values[(std::min)(disk_space_used, disk_space_values.size() - 1)];
        ++disk_space_used;
        if (available) available->QuadPart = value;
        if (total) total->QuadPart = (std::max)(value, 1ULL << 40);
        if (free) free->QuadPart = value;
        wchar_t directory[32768]{};
        if (!path) GetCurrentDirectoryW(_countof(directory), directory);
        std::wstring observed = path ? path : directory;
        std::replace(observed.begin(), observed.end(), L'/', L'\\');
        disk_space_observations.push_back("disk-space.query=" + quote_wide(observed.c_str()) +
            ",available=" + std::to_string(value));
        SetLastError(previous_error);
        return TRUE;
    } catch (...) {
        disk_space_probe_failed = true;
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }
}

static BOOL WINAPI audited_disk_space_w(LPCWSTR path, PULARGE_INTEGER available,
                                        PULARGE_INTEGER total, PULARGE_INTEGER free) {
    return audited_disk_space(path, available, total, free);
}

static BOOL WINAPI audited_disk_space_a(LPCSTR path, PULARGE_INTEGER available,
                                        PULARGE_INTEGER total, PULARGE_INTEGER free) {
    const DWORD previous_error = GetLastError();
    wchar_t wide[32768]{};
    if (path && !MultiByteToWideChar(CP_ACP, 0, path, -1, wide, _countof(wide))) {
        disk_space_probe_failed = true;
        return FALSE;
    }
    SetLastError(previous_error);
    return audited_disk_space(path ? wide : nullptr, available, total, free);
}

int run_disk_space_dialog_probe(const wchar_t* dll_path, const wchar_t* command,
                                const wchar_t* responses, const wchar_t* layout, const bool utf8,
                                const wchar_t* api, const LCID locale, const LANGID language,
                                const wchar_t* values, const int step_count = 0, wchar_t** steps = nullptr,
                                const wchar_t* progress_kind = nullptr) {
    disk_space_values.clear();
    disk_space_observations.clear();
    disk_space_used = 0;
    disk_space_probe_failed = false;
    std::wistringstream stream(values);
    std::wstring value;
    while (std::getline(stream, value, L'|')) {
        if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos)
            throw std::runtime_error("disk space values require unsigned byte counts");
        disk_space_values.push_back(std::stoull(value));
    }
    if (disk_space_values.empty()) throw std::runtime_error("disk space value required");
    Module retained(dll_path);
    const HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    const DWORD function_a = reinterpret_cast<DWORD>(GetProcAddress(kernel, "GetDiskFreeSpaceExA"));
    const DWORD function_w = reinterpret_cast<DWORD>(GetProcAddress(kernel, "GetDiskFreeSpaceExW"));
    if (!function_a || !function_w) throw std::runtime_error("disk space API unavailable");
    ScopedImportOverride hook_a, hook_w;
    hook_a.install(retained.handle, "GetDiskFreeSpaceExA", function_a,
        reinterpret_cast<DWORD>(audited_disk_space_a), true);
    if (!hook_a.slot) hook_a.install_data_pointer(retained.handle, function_a,
        reinterpret_cast<DWORD>(audited_disk_space_a), true);
    hook_w.install(retained.handle, "GetDiskFreeSpaceExW", function_w,
        reinterpret_cast<DWORD>(audited_disk_space_w), true);
    wchar_t before[32768]{}, after[32768]{};
    if (!GetCurrentDirectoryW(_countof(before), before)) throw std::runtime_error("cannot capture disk probe directory");
    const int result = run_command_dialog_probe(dll_path, command, responses, layout, utf8, api, locale,
        language, nullptr, step_count, steps, progress_kind);
    if (!GetCurrentDirectoryW(_countof(after), after)) throw std::runtime_error("cannot capture final disk probe directory");
    for (const auto& observation : disk_space_observations) std::cout << observation << '\n';
    std::cout << "disk-space.queries=" << disk_space_used << ",cwd-preserved=" << (std::wcscmp(before, after) == 0)
              << std::endl;
    if (std::wcscmp(before, after) != 0) throw std::runtime_error("disk probe changed working directory");
    if (disk_space_probe_failed) throw std::runtime_error("disk space audit failed");
    return result;
}

static std::wstring create_failure_path;
static DWORD create_failure_error = ERROR_ACCESS_DENIED;
static unsigned create_failure_calls = 0;
static bool create_failure_audit_failed = false;
using CreateFileWFunction = decltype(&CreateFileW);
using FopenFunction = decltype(&fopen);
using WideFopenFunction = decltype(&_wfopen_s);
static CreateFileWFunction create_failure_real_w = nullptr;
static FopenFunction create_failure_real_fopen = nullptr;
static WideFopenFunction create_failure_real_wfopen = nullptr;

static bool matches_create_failure(const wchar_t* path) noexcept {
    const DWORD previous = GetLastError();
    bool matches = false;
    try {
        matches = path && _wcsicmp(normalized_absolute_filename(path).c_str(), create_failure_path.c_str()) == 0;
    } catch (...) { create_failure_audit_failed = true; }
    SetLastError(previous);
    return matches;
}

static HANDLE WINAPI audited_create_file_w(LPCWSTR path, DWORD access, DWORD share,
    LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags, HANDLE template_file) {
    if ((access & GENERIC_WRITE) && matches_create_failure(path)) {
        ++create_failure_calls;
        SetLastError(create_failure_error);
        return INVALID_HANDLE_VALUE;
    }
    return create_failure_real_w(path, access, share, security, disposition, flags, template_file);
}

static void set_create_failure_errno() {
    ++create_failure_calls;
    errno = EACCES;
    _set_doserrno(create_failure_error);
    SetLastError(create_failure_error);
}

static FILE* __cdecl audited_create_fopen(const char* path, const char* mode) {
    const DWORD previous = GetLastError();
    wchar_t wide[32768]{};
    const bool write = mode && (std::strchr(mode, 'w') || std::strchr(mode, 'a') || std::strchr(mode, '+'));
    const bool converted = path && MultiByteToWideChar(CP_ACP, 0, path, -1, wide, _countof(wide));
    SetLastError(previous);
    if (write && converted && matches_create_failure(wide)) {
        set_create_failure_errno();
        return nullptr;
    }
    return create_failure_real_fopen(path, mode);
}

static errno_t __cdecl audited_create_wfopen(FILE** file, const wchar_t* path, const wchar_t* mode) {
    if (mode && (std::wcschr(mode, L'w') || std::wcschr(mode, L'a') || std::wcschr(mode, L'+')) &&
        matches_create_failure(path)) {
        if (file) *file = nullptr;
        set_create_failure_errno();
        return EACCES;
    }
    return create_failure_real_wfopen(file, path, mode);
}

int run_create_failure_probe(const wchar_t* dll_path, const wchar_t* command,
    const wchar_t* responses, const wchar_t* layout, bool utf8, const wchar_t* api,
    LCID locale, LANGID language, const wchar_t* path, DWORD error,
    const int step_count = 0, wchar_t** steps = nullptr, const wchar_t* progress_kind = nullptr) {
    create_failure_path = normalized_absolute_filename(path);
    create_failure_error = error;
    create_failure_calls = 0;
    create_failure_audit_failed = false;
    Module retained(dll_path);
    Module runtime(L"ucrtbase.dll");
    create_failure_real_w = proc<CreateFileWFunction>(GetModuleHandleW(L"kernel32.dll"), "CreateFileW");
    create_failure_real_fopen = proc<FopenFunction>(runtime.handle, "fopen");
    create_failure_real_wfopen = proc<WideFopenFunction>(runtime.handle, "_wfopen_s");
    ScopedImportOverride native, narrow, wide;
    native.install(retained.handle, "CreateFileW", reinterpret_cast<DWORD>(create_failure_real_w),
        reinterpret_cast<DWORD>(audited_create_file_w), true);
    if (!native.slot) native.install_data_pointer(retained.handle, reinterpret_cast<DWORD>(create_failure_real_w),
        reinterpret_cast<DWORD>(audited_create_file_w), true);
    narrow.install(retained.handle, "fopen", reinterpret_cast<DWORD>(create_failure_real_fopen),
        reinterpret_cast<DWORD>(audited_create_fopen), true);
    wide.install(retained.handle, "_wfopen_s", reinterpret_cast<DWORD>(create_failure_real_wfopen),
        reinterpret_cast<DWORD>(audited_create_wfopen), true);
    if (!native.slot && !narrow.slot && !wide.slot) throw std::runtime_error("file create interception unavailable");
    const int result = run_command_dialog_probe(dll_path, command, responses, layout, utf8, api, locale,
        language, nullptr, step_count, steps, progress_kind);
    std::cout << "create-failure.calls=" << create_failure_calls << ",error=" << error << std::endl;
    if (!create_failure_calls || create_failure_audit_failed) throw std::runtime_error("file create audit failed");
    return result;
}

static std::wstring overwrite_race_path;
static unsigned overwrite_race_observations = 0;

static BOOL WINAPI overwrite_race_attributes(LPCWSTR path, GET_FILEEX_INFO_LEVELS level, LPVOID data) {
    if (path) {
        std::wstring normalized = path;
        std::replace(normalized.begin(), normalized.end(), L'/', L'\\');
        if (_wcsicmp(normalized.c_str(), overwrite_race_path.c_str()) == 0 && ++overwrite_race_observations == 1) {
            // 事前判定直後に同名ファイルが現れる条件を、当該判定1回だけの不在応答で再現する。
            SetLastError(ERROR_FILE_NOT_FOUND);
            return FALSE;
        }
    }
    return GetFileAttributesExW(path, level, data);
}

int run_overwrite_race_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                             const wchar_t* expected_path, const wchar_t* workspace) {
    if (GetFileAttributesW(workspace) != INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("overwrite race requires a new workspace");
    const auto input = read_file(archive_path);
    const auto expected = read_file(expected_path);
    ensure_directory(workspace);
    const std::wstring root = workspace;
    const std::wstring archive = root + L"\\source.lzh";
    const std::wstring output = root + L"\\output";
    ensure_directory(output);
    write_file(archive, input);
    overwrite_race_path = output + L"\\nested.txt";
    std::replace(overwrite_race_path.begin(), overwrite_race_path.end(), L'/', L'\\');
    const std::vector<unsigned char> saved{'S', 'A', 'F', 'E'};
    write_file(overwrite_race_path, saved);
    Module retained(dll_path);
    const auto unlha = proc<FnUnlhaW>(retained.handle, "UnlhaW");
    const std::wstring operands = quote_argument(archive) + L" " + quote_argument(output + L"\\") + L" folder/nested.txt";
    int result = 0;
    overwrite_race_observations = 0;
    {
        ScopedImportOverride attributes;
        attributes.install(retained.handle, "GetFileAttributesExW",
            reinterpret_cast<DWORD>(GetFileAttributesExW), reinterpret_cast<DWORD>(overwrite_race_attributes));
        result = unlha(nullptr, (L"e -n1 " + operands).c_str(), nullptr, 0);
    }
    if (overwrite_race_observations == 0 || result == 0 || read_file(overwrite_race_path) != saved)
        throw std::runtime_error("overwrite race changed an unconfirmed existing file");
    const auto require_released = [&]() {
        const HANDLE file = CreateFileW(archive.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("overwrite race retained the input handle");
        CloseHandle(file);
    };
    require_released();
    if (unlha(nullptr, (L"e -n1 -gm1 -y1 -c1 " + operands).c_str(), nullptr, 0) != 0 ||
        read_file(overwrite_race_path) != expected)
        throw std::runtime_error("overwrite race subsequent authorized extraction failed");
    require_released();
    if (read_file(archive) != input) throw std::runtime_error("overwrite race changed the archive");
    overwrite_race_path.clear();
    std::cout << "overwrite.race=preserved,subsequent=passed,input-released=1\n";
    return 0;
}

int run_enum_sequence_probe(const wchar_t* dll_path, const wchar_t* layout, const LCID locale,
                            const bool utf8, const wchar_t* api, int count, wchar_t** steps,
                            const wchar_t* progress_kind = nullptr) {
    // DLL の登録を保ったまま、通知のない API 呼び出しと複数コマンドを比較する。
    Module retained(dll_path);
    ScopedImportOverride directory_time_audit;
    struct EnumObserverScope final { ~EnumObserverScope() { enum_observer = nullptr; } } enum_observer_scope;
    enum_observer = nullptr;
    ScopedImportOverride tick_override;
    ScopedImportOverride sleep_override;
    ScopedImportOverride priority_override;
    ScopedImportOverride priority_get_override;
    priority_fail_call = priority_call_count = 0;
    priority_get_fail_call = priority_get_call_count = 0;
    struct ProbeThreadPriorityScope final {
        int previous = GetThreadPriority(GetCurrentThread());
        bool changed = false;
        ~ProbeThreadPriorityScope() {
            if (changed) SetThreadPriority(GetCurrentThread(), previous);
        }
    } probe_thread_priority;
    progress_access_audit_path.clear();
    progress_archive_audit_path.clear();
    progress_archive_prefix_audit = false;
    progress_find_access_audit = false;
    progress_directory_audit_path.clear();
    progress_directory_audit_access = false;
    progress_abort_occurrence = 1;
    progress_abort_seen = 0;
    struct AccessAuditScope final {
        bool previous_full_paths = progress_full_paths;
        bool previous_copy_audit = progress_audit_copy_files;
        ~AccessAuditScope() {
            audit_thread_priority = false;
            progress_access_audit_path.clear();
            progress_archive_audit_path.clear();
            progress_archive_prefix_audit = false;
            progress_find_access_audit = false;
            progress_directory_audit_path.clear();
            progress_directory_audit_access = false;
            progress_abort_occurrence = 1;
            progress_abort_seen = 0;
            progress_full_paths = previous_full_paths;
            progress_audit_copy_files = previous_copy_audit;
        }
    } access_audit_scope;
    progress_full_paths = false;
    progress_audit_copy_files = false;
    std::wstring command_api = api;
    std::wstring archive_api = L"W";
    std::wstring memory_api = L"W";
    bool memory_null_buffer = false;
    bool memory_zero_size = false;
    const auto archive_argument = [utf8](const wchar_t* value) {
        const UINT code_page = utf8 ? CP_UTF8 : 932;
        const int length = WideCharToMultiByte(code_page, 0, value, -1, nullptr, 0, nullptr, nullptr);
        if (!length) throw std::runtime_error("archive argument conversion failed");
        std::string converted(static_cast<size_t>(length), '\0');
        if (!WideCharToMultiByte(code_page, 0, value, -1, &converted[0], length, nullptr, nullptr))
            throw std::runtime_error("archive argument conversion failed");
        converted.pop_back();
        return converted;
    };
    progress_abort_after_start = false;
    if (!SetThreadLocale(locale)) throw std::runtime_error("cannot set sequence locale");
    proc<FnBoolBool>(retained.handle, "UnlhaSetUnicodeMode")(utf8 ? TRUE : FALSE);
    DWORD size = 0;
    if (!_wcsicmp(layout, L"a32")) { enum_layout = EnumLayout::A32; size = sizeof(UNLHA_ENUM_MEMBER_INFOA); }
    else if (!_wcsicmp(layout, L"w32")) { enum_layout = EnumLayout::W32; size = sizeof(UNLHA_ENUM_MEMBER_INFOW); }
    else if (!_wcsicmp(layout, L"a64")) { enum_layout = EnumLayout::A64; size = sizeof(UNLHA_ENUM_MEMBER_INFO64A); }
    else if (!_wcsicmp(layout, L"w64")) { enum_layout = EnumLayout::W64; size = sizeof(UNLHA_ENUM_MEMBER_INFO64W); }
    else if (!_wcsicmp(layout, L"none") && progress_kind) { enum_layout = EnumLayout::None; }
    else throw std::runtime_error("unknown sequence layout");
    const bool with_enum = enum_layout != EnumLayout::None;
    enum_result = TRUE;
    enum_mutate_metadata = false;
    enum_replacement_file_a.clear(); enum_replacement_file_w.clear();
    enum_replacement_add_a.clear(); enum_replacement_add_w.clear();
    const auto register_enum = [&]() {
        return proc<FnSetEnum64>(retained.handle, "UnlhaSetEnumMembersProc64")(enum_probe, size);
    };
    if (with_enum && !register_enum()) throw std::runtime_error("cannot register sequence callback");
    struct SequenceProgress final {
        HMODULE module = nullptr;
        HWND window = nullptr;
        DWORD size = 0;
        bool active = false;
        ~SequenceProgress() {
            pump_audit_window = nullptr;
            if (active) proc<FnKillOwnerEx>(module, "UnlhaKillOwnerWindowEx64")(nullptr);
            if (window) DestroyWindow(window);
        }
    } progress;
    progress.module = retained.handle;
    const auto register_progress = [&]() {
        using FnSetTotal = BOOL(WINAPI*)(HWND, LPARCHIVERPROC, BOOL);
        const BOOL result = progress_layout == ProgressLayout::Total
            ? proc<FnSetTotal>(retained.handle, "UnlhaSetOwnerWindowExTotal")(progress.window, progress_probe, TRUE)
            : proc<FnSetOwnerEx64>(retained.handle, "UnlhaSetOwnerWindowEx64")(
                progress.window, progress_probe, progress.size);
        progress.active = result != FALSE;
        return result;
    };
    if (progress_kind) {
        if (!_wcsicmp(progress_kind, L"total")) { progress_layout = ProgressLayout::Total; progress.size = sizeof(EXTRACTINGINFO_TOTAL); }
        else if (!_wcsicmp(progress_kind, L"a32")) { progress_layout = ProgressLayout::Ex32A; progress.size = sizeof(EXTRACTINGINFOEX32A); }
        else if (!_wcsicmp(progress_kind, L"w32")) { progress_layout = ProgressLayout::Ex32W; progress.size = sizeof(EXTRACTINGINFOEX32W); }
        else if (!_wcsicmp(progress_kind, L"a64")) { progress_layout = ProgressLayout::Ex64A; progress.size = sizeof(EXTRACTINGINFOEX64A); }
        else if (!_wcsicmp(progress_kind, L"w64")) { progress_layout = ProgressLayout::Ex64W; progress.size = sizeof(EXTRACTINGINFOEX64W); }
        else throw std::runtime_error("unknown sequence progress layout");
        progress.window = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
            HWND_MESSAGE, nullptr, nullptr, nullptr);
        if (!progress.window) throw std::runtime_error("cannot create sequence progress window");
        progress_result = TRUE;
        progress_abort_state = -1;
        progress_expected_owner = nullptr;
        progress_records.clear();
        if (!register_progress()) throw std::runtime_error("cannot register sequence progress callback");
        std::cout << "progress.set=1\n";
    }
    HARC archive = nullptr;
    bool expect_progress_kill_failure = false;
    for (int index = 0; index < count; ++index) {
        enum_records.clear();
        if (progress_kind) progress_records.clear();
        const std::wstring step = steps[index];
        std::cout << "phase=" << index << '\n' << std::flush;
        if (step.rfind(L"@audit-dialog-archive:", 0) == 0) {
            // ダイアログ監視側が呼び出し開始前に読み取る固定の観測対象。
        } else if (step == L"@handle-count") {
            const DWORD previous_error = GetLastError();
            DWORD handles = 0;
            if (!GetProcessHandleCount(GetCurrentProcess(), &handles))
                throw std::runtime_error("cannot read process handle count");
            std::cout << "handle-count=" << handles << '\n';
            SetLastError(previous_error);
        } else if (step.rfind(L"@language:", 0) == 0) {
            const std::wstring value = step.substr(10);
            if (value != L"0" && value != L"1033" && value != L"1041")
                throw std::runtime_error("unsupported sequence language");
            using FnLanguage = BOOL(WINAPI*)(LANGID);
            if (!proc<FnLanguage>(retained.handle, "UnlhaSetLangueSpecified")(
                    static_cast<LANGID>(std::stoul(value))))
                throw std::runtime_error("cannot set sequence language");
        } else if (step.rfind(L"@audit-progress-archive:", 0) == 0) {
            const std::wstring path = step.substr(24);
            if (!progress_kind || path.size() < 3 || path[1] != L':' ||
                (path[2] != L'\\' && path[2] != L'/'))
                throw std::runtime_error("archive progress audit requires a drive-absolute path and progress");
            progress_archive_audit_path = path;
        } else if (step == L"@audit-progress-archive-prefix") {
            if (!progress_kind || progress_archive_audit_path.empty())
                throw std::runtime_error("archive prefix audit requires an archive audit path");
            progress_archive_prefix_audit = true;
        } else if (step == L"@audit-progress-copy-files") {
            if (!progress_kind || progress_layout != ProgressLayout::Ex64W)
                throw std::runtime_error("copy file audit requires w64 progress");
            progress_audit_copy_files = true;
        } else if (step == L"@full-progress-paths" || step == L"@short-progress-paths") {
            if (!progress_kind) throw std::runtime_error("progress path mode requires a progress callback");
            progress_full_paths = step == L"@full-progress-paths";
        } else if (step.rfind(L"@abort-state:", 0) == 0) {
            if (!progress_kind || progress_layout == ProgressLayout::Total)
                throw std::runtime_error("abort-state requires compatible progress");
            const std::wstring value = step.substr(13);
            if (value != L"-1" && value != L"0" && value != L"1" && value != L"2" &&
                value != L"3" && value != L"4" && value != L"5" && value != L"6")
                throw std::runtime_error("invalid abort state");
            progress_abort_state = std::stoi(value);
            progress_abort_seen = 0;
        } else if (step.rfind(L"@abort-occurrence:", 0) == 0) {
            if (!progress_kind || progress_layout == ProgressLayout::Total)
                throw std::runtime_error("abort occurrence requires compatible progress");
            const std::wstring value = step.substr(18);
            if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos)
                throw std::runtime_error("invalid abort occurrence");
            const unsigned long occurrence = std::stoul(value);
            if (!occurrence || occurrence > 100000) throw std::runtime_error("abort occurrence out of range");
            progress_abort_occurrence = static_cast<unsigned int>(occurrence);
            progress_abort_seen = 0;
        } else if (step == L"@audit-directory-set-time") {
            directory_time_audit.install(retained.handle, "SetFileTime",
                reinterpret_cast<DWORD>(&SetFileTime), reinterpret_cast<DWORD>(&audit_directory_set_time));
        } else if (step.rfind(L"@priority-get-fail:", 0) == 0) {
            const std::wstring value = step.substr(19);
            if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos)
                throw std::runtime_error("invalid priority get failure index");
            priority_get_fail_call = static_cast<unsigned int>(std::stoul(value));
            priority_get_call_count = 0;
            priority_get_override.install(retained.handle, "GetThreadPriority",
                reinterpret_cast<DWORD>(&GetThreadPriority), reinterpret_cast<DWORD>(&audited_get_thread_priority));
        } else if (step.rfind(L"@priority-fail:", 0) == 0) {
            const std::wstring value = step.substr(15);
            if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos)
                throw std::runtime_error("invalid priority failure index");
            priority_fail_call = static_cast<unsigned int>(std::stoul(value));
            priority_call_count = 0;
        } else if (step == L"@audit-priority-calls") {
            priority_override.install(retained.handle, "SetThreadPriority",
                reinterpret_cast<DWORD>(&SetThreadPriority), reinterpret_cast<DWORD>(&audited_set_thread_priority));
        } else if (step == L"@thread-baseline:1") {
            if (!SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL))
                throw std::runtime_error("cannot set probe thread baseline");
            probe_thread_priority.changed = true;
        } else if (step == L"@audit-thread-priority") {
            audit_thread_priority = true;
        } else if (step == L"@thread-priority") {
            const DWORD error = GetLastError();
            std::cout << "thread-priority=" << GetThreadPriority(GetCurrentThread()) << '\n';
            SetLastError(error);
        } else if (step == L"@audit-pump") {
            if (!progress.window || pump_audit_window) throw std::runtime_error("pump audit requires progress");
            pump_audit_original_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(progress.window,
                GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&pump_audit_window_proc)));
            if (!pump_audit_original_proc) throw std::runtime_error("cannot install pump audit");
            pump_audit_serial = 0;
            pump_audit_window = progress.window;
        } else if (step == L"@drain-pump-audit") {
            if (!pump_audit_window) throw std::runtime_error("pump audit is not installed");
            MSG message{};
            unsigned int pending_messages = 0;
            while (PeekMessageW(&message, pump_audit_window, pump_audit_message, pump_audit_message, PM_REMOVE)) {
                ++pending_messages;
                DispatchMessageW(&message);
            }
            std::cout << "pump-pending-at-return=" << pending_messages << '\n';
        } else if (step == L"@audit-sleep") {
            sleep_audit_module_base = reinterpret_cast<uintptr_t>(retained.handle);
            const auto base = reinterpret_cast<const BYTE*>(retained.handle);
            const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
            const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
            sleep_audit_module_end = sleep_audit_module_base + nt->OptionalHeader.SizeOfImage;
            sleep_override.install(retained.handle, "Sleep", reinterpret_cast<DWORD>(&Sleep),
                reinterpret_cast<DWORD>(&audited_sleep), true);
            std::cout << "sleep-import=" << (sleep_override.slot ? 1 : 0) << '\n';
        } else if (step == L"@background-on") {
            if (!proc<FnBoolBool>(retained.handle, "UnlhaSetBackGroundMode")(TRUE))
                throw std::runtime_error("cannot enable background mode");
        } else if (step.rfind(L"@priority:", 0) == 0) {
            const std::wstring value = step.substr(10);
            if (value != L"-15" && value != L"-2" && value != L"-1" && value != L"0" &&
                value != L"1" && value != L"2" && value != L"-3" && value != L"3" && value != L"15")
                throw std::runtime_error("unsupported audit priority");
            if (!proc<FnIntInt>(retained.handle, "UnlhaSetPriority")(std::stoi(value)))
                throw std::runtime_error("cannot set audit priority");
        } else if (step.rfind(L"@clock-step:", 0) == 0) {
            const auto value = step.substr(12);
            if (value != L"0" && value != L"33" && value != L"34")
                throw std::runtime_error("unsupported controlled clock step");
            controlled_tick = 0;
            controlled_tick_step = std::stoul(value);
            tick_override.install(retained.handle, "GetTickCount",
                reinterpret_cast<DWORD>(&GetTickCount), reinterpret_cast<DWORD>(&controlled_get_tick_count));
        } else if (step == L"@audit-directory-access") {
            progress_directory_audit_access = true;
        } else if (step.rfind(L"@audit-directory:", 0) == 0) {
            progress_directory_audit_path = step.substr(17);
            if (progress_directory_audit_path.size() < 3 || progress_directory_audit_path[1] != L':' ||
                (progress_directory_audit_path[2] != L'\\' && progress_directory_audit_path[2] != L'/'))
                throw std::runtime_error("progress directory audit requires an absolute path");
        } else if (step.rfind(L"@directory-state:", 0) == 0) {
            const std::wstring path = step.substr(17);
            if (path.size() < 3 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/'))
                throw std::runtime_error("directory state audit requires an absolute path");
            WIN32_FILE_ATTRIBUTE_DATA state{};
            if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &state) ||
                (state.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
                throw std::runtime_error("directory state audit target is not a directory");
            std::cout << "directory-state=" << quote_wide(path.c_str())
                << ",attributes=" << state.dwFileAttributes
                << ",create=" << filetime_value(state.ftCreationTime)
                << ",access=" << filetime_value(state.ftLastAccessTime)
                << ",write=" << filetime_value(state.ftLastWriteTime) << '\n';
        } else if (step.rfind(L"@audit-archive-release:", 0) == 0) {
            const std::wstring path = step.substr(23);
            if (path.size() < 3 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/'))
                throw std::runtime_error("archive release audit requires an absolute path");
            const DWORD previous_error = GetLastError();
            // 内容を書かず、読み取り用の排他オープンで DLL に残ったハンドルを検出する。
            const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr,
                                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            const DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
            if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
            std::cout << "archive-released=" << (file != INVALID_HANDLE_VALUE) << ",error=" << error << '\n';
            SetLastError(previous_error);
        } else if (step == L"@audit-find-access") {
            progress_find_access_audit = true;
        } else if (step.rfind(L"@audit-access:", 0) == 0) {
            if (!progress_kind || progress_layout == ProgressLayout::Total)
                throw std::runtime_error("access audit requires extended progress");
            progress_access_audit_path = step.substr(14);
            const bool drive_rooted = progress_access_audit_path.size() >= 3 &&
                progress_access_audit_path[1] == L':' &&
                (progress_access_audit_path[2] == L'\\' || progress_access_audit_path[2] == L'/');
            const bool unc_rooted = progress_access_audit_path.size() >= 2 &&
                progress_access_audit_path[0] == L'\\' && progress_access_audit_path[1] == L'\\';
            if (!drive_rooted && !unc_rooted)
                throw std::runtime_error("access audit requires an absolute source path");
        } else if (step.rfind(L"@api:", 0) == 0) {
            command_api = step.substr(5);
            if (command_api != L"A" && command_api != L"W" && command_api != L"legacy")
                throw std::runtime_error("invalid sequence command API");
        } else if (step == L"@cp-state") {
            std::cout << "code-page=" << proc<FnUInt0>(retained.handle, "UnlhaGetCP")() << '\n';
        } else if (step.rfind(L"@set-cp:", 0) == 0) {
            const std::wstring value = step.substr(8);
            size_t consumed = 0;
            const unsigned long code_page = std::stoul(value, &consumed);
            if (consumed != value.size()) throw std::runtime_error("invalid sequence code page");
            std::cout << "code-page.set=" << proc<FnBoolUInt>(retained.handle, "UnlhaSetCP")(code_page) << '\n';
        } else if (step == L"@abort-after-start" || step == L"@abort-off") {
            if (!progress_kind || progress_layout != ProgressLayout::Total)
                throw std::runtime_error("abort-after-start requires total progress");
            // 初回のゼロ進捗ではなく、圧縮バッファ確保後の読み取り通知で中断する。
            progress_abort_after_start = step == L"@abort-after-start";
        } else if (step == L"@private-bytes") {
            PROCESS_MEMORY_COUNTERS_EX counters{};
            counters.cb = sizeof(counters);
            using FnMemory = BOOL(WINAPI*)(HANDLE, PPROCESS_MEMORY_COUNTERS, DWORD);
            if (!proc<FnMemory>(GetModuleHandleW(L"kernel32.dll"), "K32GetProcessMemoryInfo")(
                    GetCurrentProcess(), reinterpret_cast<PPROCESS_MEMORY_COUNTERS>(&counters), sizeof(counters)))
                throw std::runtime_error("cannot query process private bytes");
            std::cout << "memory.private-bytes=" << counters.PrivateUsage << '\n';
        } else if (step == L"@expect-progress-kill-failure") {
            if (!progress_kind) throw std::runtime_error("sequence progress not configured");
            expect_progress_kill_failure = true;
        } else if (step == L"@probe-progress-kill") {
            if (!progress.active) throw std::runtime_error("sequence progress not active");
            const BOOL cleared = proc<FnKillOwnerEx>(retained.handle, "UnlhaKillOwnerWindowEx64")(nullptr);
            DWORD system = 0;
            const int error = proc<FnLastError>(retained.handle, "UnlhaGetLastError")(&system);
            std::cout << "progress.probe-kill=" << (cleared != FALSE) << ",error=" << error << ",system=" << system << '\n';
            if (cleared) progress.active = false;
        } else if (step == L"@register" || step == L"@reregister") {
            if (!with_enum) throw std::runtime_error("sequence enum registration requires a layout");
            if (step == L"@reregister")
                std::cout << "clear=" << proc<FnBool0>(retained.handle, "UnlhaClearEnumMembersProc")() << '\n';
            std::cout << "register=" << register_enum() << '\n';
        } else if (step == L"@progress-off") {
            if (!progress_kind || !progress.active) throw std::runtime_error("sequence progress not registered");
            const BOOL cleared = proc<FnKillOwnerEx>(retained.handle, "UnlhaKillOwnerWindowEx64")(nullptr);
            if (!cleared) throw std::runtime_error("cannot clear sequence progress callback");
            progress.active = false;
            std::cout << "progress.off=1\n";
        } else if (step == L"@progress-on") {
            if (!progress_kind || progress.active) throw std::runtime_error("sequence progress already registered");
            if (!register_progress()) throw std::runtime_error("cannot restore sequence progress callback");
            std::cout << "progress.on=1\n";
        } else if (step == L"@mutate" || step == L"@nomutate") {
            enum_mutate_metadata = step == L"@mutate";
        } else if (step == L"@reject" || step == L"@accept") {
            enum_result = step == L"@accept";
        } else if (step.rfind(L"@add:", 0) == 0) {
            enum_replacement_add_w = step.substr(5);
            char converted[MAX_PATH * 4]{};
            if (!WideCharToMultiByte(utf8 ? CP_UTF8 : 932, utf8 ? 0 : WC_NO_BEST_FIT_CHARS,
                    enum_replacement_add_w.c_str(), -1, converted, sizeof(converted), nullptr, nullptr))
                throw std::runtime_error("sequence replacement conversion failed");
            enum_replacement_add_a = converted;
        } else if (step.rfind(L"@archive-api:", 0) == 0) {
            archive_api = step.substr(13);
            if (archive_api != L"A" && archive_api != L"W" && archive_api != L"legacy")
                throw std::runtime_error("unknown archive API");
        } else if (step.rfind(L"@open:", 0) == 0 || step.rfind(L"@open-quiet:", 0) == 0) {
            if (archive) throw std::runtime_error("sequence archive already open");
            const bool quiet = step.rfind(L"@open-quiet:", 0) == 0;
            const wchar_t* path = step.c_str() + (quiet ? 12 : 6);
            const DWORD mode = quiet ? M_REGARDLESS_INIT_FILE | M_ERROR_MESSAGE_OFF : 0;
            archive = archive_api == L"W"
                ? proc<FnOpenW>(retained.handle, "UnlhaOpenArchiveW")(nullptr, path, mode)
                : proc<FnOpen>(retained.handle, archive_api == L"A" ? "UnlhaOpenArchiveA" : "UnlhaOpenArchive")(
                    nullptr, archive_argument(path).c_str(), mode);
            std::cout << "open=" << (archive != nullptr) << '\n';
        } else if (step.rfind(L"@first:", 0) == 0) {
            INDIVIDUALINFOW info{};
            INDIVIDUALINFOA info_a{};
            const int result = archive_api == L"W"
                ? proc<FnFindFirstW>(retained.handle, "UnlhaFindFirstW")(archive, step.c_str() + 7, &info)
                : proc<FnFindFirst>(retained.handle, archive_api == L"A" ? "UnlhaFindFirstA" : "UnlhaFindFirst")(
                    archive, archive_argument(step.c_str() + 7).c_str(), &info_a);
            std::cout << "first=" << result << '\n';
        } else if (step == L"@next") {
            INDIVIDUALINFOW info{};
            INDIVIDUALINFOA info_a{};
            const int result = archive_api == L"W"
                ? proc<FnFindNextW>(retained.handle, "UnlhaFindNextW")(archive, &info)
                : proc<FnFindNext>(retained.handle, archive_api == L"A" ? "UnlhaFindNextA" : "UnlhaFindNext")(
                    archive, &info_a);
            std::cout << "next=" << result << '\n';
        } else if (step == L"@close") {
            std::cout << "close=" << proc<FnClose>(retained.handle, "UnlhaCloseArchive")(archive) << '\n';
            archive = nullptr;
        } else if (step.rfind(L"@count:", 0) == 0) {
            std::cout << "count=" << proc<FnCountW>(retained.handle, "UnlhaGetFileCountW")(step.c_str() + 7) << '\n';
        } else if (step.rfind(L"@check:", 0) == 0) {
            std::cout << "check=" << proc<FnCheckW>(retained.handle, "UnlhaCheckArchiveW")(step.c_str() + 7, 0) << '\n';
        } else if (step.rfind(L"@memory-reenter:", 0) == 0) {
            memory_reentry_module = retained.handle;
            memory_reentry_command = step.substr(16);
            memory_reentry_command_a = archive_argument(memory_reentry_command.c_str());
            enum_observer = &audit_memory_reentry;
        } else if (step.rfind(L"@memory-api:", 0) == 0) {
            memory_api = step.substr(12);
            if (memory_api != L"A" && memory_api != L"W" && memory_api != L"legacy")
                throw std::runtime_error("unknown memory API");
        } else if (step == L"@memory-null-buffer" || step == L"@memory-valid-buffer") {
            memory_null_buffer = step == L"@memory-null-buffer";
        } else if (step == L"@memory-zero-size" || step == L"@memory-default-size") {
            memory_zero_size = step == L"@memory-zero-size";
        } else if (step.rfind(L"@memory:", 0) == 0) {
            std::vector<BYTE> output(65536);
            DWORD written = 0;
            LPBYTE buffer = memory_null_buffer ? nullptr : output.data();
            const DWORD buffer_size = memory_zero_size ? 0 : static_cast<DWORD>(output.size());
            using NarrowExtract = int(WINAPI*)(HWND, LPCSTR, LPBYTE, DWORD, time_t*, LPWORD, LPDWORD);
            const int result = memory_api == L"W"
                ? proc<FnExtractMemW>(retained.handle, "UnlhaExtractMemW")(
                    nullptr, step.c_str() + 8, buffer, buffer_size, nullptr, nullptr, &written)
                : proc<NarrowExtract>(retained.handle, memory_api == L"A" ? "UnlhaExtractMemA" : "UnlhaExtractMem")(
                    nullptr, archive_argument(step.c_str() + 8).c_str(), buffer, buffer_size, nullptr, nullptr, &written);
            std::cout << "memory=" << result << ",written=" << written << '\n';
        } else if (step.rfind(L"@", 0) == 0) {
            throw std::runtime_error("unknown sequence operation");
        } else if (command_api == L"W") {
            run_command_probe(dll_path, step.c_str());
        } else {
            run_command_probe_a(dll_path, step.c_str(), command_api == L"A" ? "UnlhaA" : "Unlha",
                                utf8 ? CP_UTF8 : 932);
        }
        std::cout << "enum.count=" << enum_records.size() << '\n';
        for (const auto& record : enum_records) std::cout << "enum.entry=" << record << '\n';
        if (progress_kind) {
            std::cout << "progress.count=" << progress_records.size() << '\n';
            for (const auto& record : progress_records) std::cout << "progress.entry=" << record << '\n';
        }
    }
    if (archive) proc<FnClose>(retained.handle, "UnlhaCloseArchive")(archive);
    std::cout << "enum.clear=" << (with_enum ? proc<FnBool0>(retained.handle, "UnlhaClearEnumMembersProc")() : FALSE) << '\n';
    if (progress.active) {
        const BOOL cleared = proc<FnKillOwnerEx>(retained.handle, "UnlhaKillOwnerWindowEx64")(nullptr);
        if ((cleared == FALSE) != expect_progress_kill_failure)
            throw std::runtime_error("unexpected final sequence progress clearing result");
        if (cleared) progress.active = false;
        std::cout << "progress.kill=" << (cleared != FALSE) << '\n';
        if (expect_progress_kill_failure) {
            DWORD system = 0;
            const int error = proc<FnLastError>(retained.handle, "UnlhaGetLastError")(&system);
            std::cout << "progress.kill-error=" << error << ",system=" << system << '\n';
        }
    }
    enum_layout = EnumLayout::None;
    enum_mutate_metadata = false;
    enum_result = TRUE;
    progress_abort_after_start = false;
    return 0;
}

int run_registry_path_sequence_probe(const wchar_t* dll_path, const wchar_t* archive_path,
                                      const wchar_t* initial, const wchar_t* second,
                                      const wchar_t* variant) {
    Module retained(dll_path);
    std::cout << "phase=initial\n";
    std::wstringstream operations(initial);
    std::wstring operation;
    while (std::getline(operations, operation, L';')) {
        if (operation.rfind(L"config:", 0) == 0) {
            run_config_dialog_probe(dll_path, L"1", operation.c_str() + 7, variant);
        } else if (operation == L"open" || operation == L"open-ignore") {
            const DWORD mode = operation == L"open-ignore" ? M_REGARDLESS_INIT_FILE : 0;
            const HARC archive = proc<FnOpenW>(retained.handle, "UnlhaOpenArchiveW")(nullptr, archive_path, mode);
            std::cout << "opened=" << (archive != nullptr) << '\n';
            if (archive) proc<FnClose>(retained.handle, "UnlhaCloseArchive")(archive);
        } else if (operation == L"check") {
            std::cout << "checked=" << proc<FnCheckW>(retained.handle, "UnlhaCheckArchiveW")(archive_path, 0) << '\n';
        } else if (operation == L"memory" || operation == L"memory -+") {
            const std::wstring command = operation.substr(6) + L" " + quote_argument(archive_path) + L" a.txt";
            std::vector<BYTE> buffer(4096);
            DWORD written = 0;
            const int result = proc<FnExtractMemW>(retained.handle, "UnlhaExtractMemW")(
                nullptr, command.c_str(), buffer.data(), static_cast<DWORD>(buffer.size()),
                nullptr, nullptr, &written);
            std::cout << "extracted=" << result << "|written=" << written << '\n';
        } else {
            const std::wstring command = operation + L" -gm1 " + quote_argument(archive_path);
            if (_wcsicmp(variant, L"A") == 0) run_command_probe_a(dll_path, command.c_str());
            else run_command_probe(dll_path, command.c_str());
        }
    }
    std::cout << "phase=second\n";
    return _wcsicmp(variant, L"A") == 0
        ? run_command_probe_a(dll_path, second) : run_command_probe(dll_path, second);
}

int run_command_probe_a_summary(const wchar_t* dll_path, const wchar_t* command) {
    Module module(dll_path);
    const int command_size = WideCharToMultiByte(932, WC_NO_BEST_FIT_CHARS, command, -1,
                                                  nullptr, 0, nullptr, nullptr);
    if (command_size <= 0) throw std::runtime_error("command is not representable in CP932");
    std::vector<char> command_a(static_cast<size_t>(command_size));
    WideCharToMultiByte(932, WC_NO_BEST_FIT_CHARS, command, -1, command_a.data(),
                        command_size, nullptr, nullptr);
    std::vector<char> output(65536, static_cast<char>(0xcc));
    SetLastError(0x12345678U);
    const int result = proc<FnUnlhaA>(module.handle, "Unlha")(
        nullptr, command_a.data(), output.data(), static_cast<DWORD>(output.size()));
    const DWORD win32_error = GetLastError();
    DWORD system_error = 0x87654321U;
    const int compat_error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
    const size_t length = strnlen(output.data(), output.size());
    unsigned long long hash = 14695981039346656037ULL;
    for (size_t index = 0; index < length; ++index) {
        hash ^= static_cast<unsigned char>(output[index]);
        hash *= 1099511628211ULL;
    }
    const size_t tail_offset = length > 24 ? length - 24 : 0;
    const std::string tail(output.data() + tail_offset, length - tail_offset);
    std::cout << "result=" << result << '\n';
    std::cout << "output-length=" << length << '\n';
    std::cout << "output-fnv64=" << std::hex << std::uppercase << hash << std::dec << '\n';
    std::cout << "output-tail=" << quote_bytes(tail.c_str()) << '\n';
    std::cout << "win32-error=" << win32_error << '\n';
    std::cout << "compat-error=" << compat_error << '\n';
    std::cout << "compat-system-error=" << system_error << '\n';
    return 0;
}

int run_action_output_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const auto count = proc<FnCountW>(module.handle, "UnlhaGetFileCountW");
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring nested = source + L"\\folder";
    const std::wstring flat = root + L"\\flat";
    const std::wstring full = root + L"\\full";
    const std::wstring move = root + L"\\move";
    for (const auto& path : {root, source, nested, flat, full, move}) ensure_directory(path);

    std::vector<unsigned char> alpha(4099, 'A');
    std::vector<unsigned char> beta(521, 'B');
    std::vector<unsigned char> newer(3077, 'N');
    write_file(source + L"\\alpha.txt", alpha);
    write_file(source + L"\\beta.txt", beta);
    write_file(nested + L"\\alpha.txt", alpha);
    write_file(move + L"\\alpha.txt", alpha);
    for (const auto& path : {source + L"\\alpha.txt", source + L"\\beta.txt",
                             nested + L"\\alpha.txt", move + L"\\alpha.txt"}) {
        set_file_times(path, 2024, 1, 2, 3, 4, 6);
    }

    auto normalize = [&](std::wstring value) {
        std::wstring slash_root = root;
        std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
        for (const auto& prefix : {root, slash_root}) {
            size_t offset = 0;
            while ((offset = value.find(prefix, offset)) != std::wstring::npos) {
                value.replace(offset, prefix.size(), L"<ROOT>");
                offset += 6;
            }
        }
        return value;
    };
    auto invoke = [&](const char* label, const std::wstring& command) {
        wchar_t output[65536]{};
        // 原版のモーダルエラーで停止しても、最後に開始した操作をログへ残す。
        std::cout << label << ".begin=1\n" << std::flush;
        SetLastError(0x12345678U);
        const int result = unlha(nullptr, command.c_str(), output, _countof(output));
        const DWORD win32_error = GetLastError();
        DWORD system_error = 0x87654321U;
        const int compat_error = last_error(&system_error);
        std::cout << label << ".result=" << result << '\n'
                  << label << ".output=" << quote_wide(normalize(output).c_str()) << '\n'
                  << label << ".win32-error=" << win32_error << '\n'
                  << label << ".compat-error=" << compat_error << '\n'
                  << label << ".system-error=" << system_error << '\n' << std::flush;
        return result;
    };

    const std::wstring archive = root + L"\\action.lzh";
    const std::wstring fresh = root + L"\\fresh.lzh";
    const std::wstring operands = quote_argument(archive) + L" " +
        quote_argument(source + L"\\") + L" alpha.txt beta.txt";
    invoke("add-new", L"a -y -jm2 " + operands);
    invoke("add-existing", L"a -y -jm2 " + operands);
    invoke("update-same", L"u -y -jm2 " + operands);
    invoke("fresh-same", L"f -y -jm2 " + operands);
    if (!CopyFileW(archive.c_str(), fresh.c_str(), TRUE))
        throw std::runtime_error("cannot prepare fresh output probe");

    write_file(source + L"\\alpha.txt", newer);
    write_file(source + L"\\gamma.txt", beta);
    set_file_times(source + L"\\alpha.txt", 2025, 2, 3, 4, 5, 8);
    set_file_times(source + L"\\gamma.txt", 2025, 2, 3, 4, 5, 8);
    const std::wstring changed_operands = L" " + quote_argument(source + L"\\") +
                                          L" alpha.txt gamma.txt";
    invoke("update-newer", L"u -y -jm2 " + quote_argument(archive) + changed_operands);
    std::cout << "update-newer.count=" << count(archive.c_str()) << '\n';
    invoke("fresh-newer", L"f -y -jm2 " + quote_argument(fresh) + changed_operands);
    std::cout << "fresh-newer.count=" << count(fresh.c_str()) << '\n';
    invoke("delete", L"d -y " + quote_argument(archive) + L" beta.txt");
    std::cout << "delete.count=" << count(archive.c_str()) << '\n';

    const std::wstring moved_archive = root + L"\\moved.lzh";
    invoke("move", L"m -y -jm2 " + quote_argument(moved_archive) + L" " +
                   quote_argument(move + L"\\") + L" alpha.txt");
    std::cout << "move.source-exists=" <<
        (GetFileAttributesW((move + L"\\alpha.txt").c_str()) != INVALID_FILE_ATTRIBUTES) << '\n';

    const std::wstring nested_archive = root + L"\\nested.lzh";
    invoke("nested-add", L"a -y -x1 -jm2 " + quote_argument(nested_archive) + L" " +
                         quote_argument(source + L"\\") + L" folder/alpha.txt");
    invoke("extract-flat", L"e -y " + quote_argument(nested_archive) + L" " +
                           quote_argument(flat + L"\\"));
    invoke("extract-path", L"x -y " + quote_argument(nested_archive) + L" " +
                           quote_argument(full + L"\\"));
    std::cout << "extract-flat.payload=" << (read_file(flat + L"\\alpha.txt") == alpha) << '\n';
    std::cout << "extract-path.payload=" << (read_file(full + L"\\folder\\alpha.txt") == alpha) << '\n';

    proc<FnBoolUInt>(module.handle, "UnlhaSetCP")(999999U);
    invoke("error-empty", L"");
    invoke("error-no-archive", L"l");
    const std::wstring missing = root + L"\\missing.lzh";
    invoke("error-missing-list", L"l " + quote_argument(missing));
    invoke("error-missing-test", L"t " + quote_argument(missing));
    invoke("error-missing-extract", L"x -y " + quote_argument(missing) + L" " +
                                     quote_argument(flat + L"\\"));
    invoke("error-missing-directory", L"l " + quote_argument(root + L"\\absent\\missing.lzh"));
    const auto before_delete = read_file(archive);
    invoke("error-delete-no-pattern", L"d -y " + quote_argument(archive));
    std::cout << "error-delete-no-pattern.unchanged=" << (read_file(archive) == before_delete) << '\n';
    invoke("add-no-source", L"a -y " + quote_argument(root + L"\\empty-input.lzh") + L" " +
                             quote_argument(source + L"\\") + L" no-such-file.txt");
    return 0;
}

int run_match_options_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\matching.lzh";
    for (const auto& path : {root, source, source + L"\\dir", source + L"\\dir\\deep",
                             source + L"\\else"}) ensure_directory(path);
    const std::vector<std::wstring> names = {
        L"root.txt", L"noext", L".hidden", L"dir\\root.txt", L"dir\\data.log",
        L"dir\\deep\\root.txt", L"dir\\deep\\data.log", L"else\\side.txt"};
    std::wstring add = L"a -y -x1 " + quote_argument(archive) + L" " +
        quote_argument(source + L"\\");
    for (size_t index = 0; index < names.size(); ++index) {
        const std::wstring path = source + L"\\" + names[index];
        write_file(path, std::vector<unsigned char>(41 + index, static_cast<unsigned char>('A' + index)));
        set_file_times(path, 2024, 1, 2, 3, 4, 6);
        add += L" " + quote_argument(names[index]);
    }
    wchar_t scratch[65536]{};
    if (unlha(nullptr, add.c_str(), scratch, _countof(scratch)) != 0)
        throw std::runtime_error("matching probe: cannot create fixture");
    set_file_times(archive, 2024, 1, 2, 3, 4, 6);
    auto execute = [&](const std::wstring& label, const std::wstring& command) {
        wchar_t output[65536]{};
        SetLastError(0x12345678U);
        const std::wstring controlled_command = command + L" -gm1";
        const int result = unlha(nullptr, controlled_command.c_str(), output, _countof(output));
        const DWORD win32_error = GetLastError();
        DWORD system_error = 0x87654321U;
        const int compat_error = last_error(&system_error);
        std::wstring value(output);
        std::wstring slash_root = root;
        std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
        for (const auto& prefix : {root, slash_root}) {
            size_t offset = 0;
            while ((offset = value.find(prefix, offset)) != std::wstring::npos) {
                value.replace(offset, prefix.size(), L"<ROOT>");
                offset += 6;
            }
        }
        std::cout << "case=" << quote_wide(label.c_str())
                  << " result=" << result << " output=" << quote_wide(value.c_str())
                  << " win32=" << win32_error << " compat=" << compat_error
                  << " system=" << system_error << '\n';
        std::cout.flush();
    };
    auto invoke = [&](const std::wstring& options, const std::wstring& pattern) {
        execute(options + L" | " + pattern, L"l -n1 " + options + L" " + quote_argument(archive) +
            (pattern.empty() ? L"" : L" " + quote_argument(pattern)));
    };
    for (const auto* options : {L"", L"-p0", L"-p1", L"-p2", L"-r0", L"-r1", L"-r2"}) {
        for (const auto* pattern : {L"*.txt", L"dir/*.txt", L"dir", L"dir/*.*"})
            invoke(options, pattern);
    }
    for (const auto* options : {L"-p1 -r1", L"-r1 -p1", L"-p2 -r0", L"-r0 -p2",
                                L"-d1 -x0", L"-x0 -d1", L"-d0 -x1", L"-x1 -d0",
                                L"-n-", L"-n+", L"-x-", L"-x+", L"-p-", L"-p+"})
        invoke(options, L"*.txt");
    for (const auto* pattern : {L"*.*", L"noext.*", L"ROOT.TXT", L"r??t.txt", L"*.TXT",
                                L"[r]*.txt", L"dir\\root.txt", L"dir/*/root.txt", L"dir*",
                                L"*.", L"root.txt.", L"noext.", L"*.*.*", L"root.*.*",
                                L"*.txt.*", L"*.*x", L"*.*.txt"})
        invoke(L"-x1", pattern);
    for (const wchar_t command : {L'l', L'v'}) {
        for (const auto* pattern : {L"*.txt", L"*.log", L"absent", L"dir/*.*"})
            execute(std::wstring(1, command) + L"-formatted | " + pattern,
                std::wstring(1, command) + L" " + quote_argument(archive) + L" " + pattern);
        for (const auto* selection : {L"*.txt -jxside.txt", L"*.log -jxroot.txt", L"*.log -jx*"})
            execute(std::wstring(1, command) + L"-excluded | " + selection,
                std::wstring(1, command) + L" " + quote_argument(archive) + L" " + selection);
    }
    for (const auto* options : {L"-jx*.txt", L"-jxdir/*.txt", L"-jxdir", L"-r2 -jxdir",
                                L"-p1 -jx*.txt", L"-p2 -jxdir"})
        invoke(options, L"");
    for (const auto* options : {L"-p2 -r0", L"-p2 -r1", L"-r1 -p2", L"-p2 -p0",
                                L"-d1 -r0", L"-r0 -d1", L"-d1 -d0"})
        invoke(options, L"dir");
    execute(L"base-directory", L"l -n1 -p1 " + quote_argument(archive) + L" " +
        quote_argument(source + L"\\") + L" *.txt");
    const std::vector<std::pair<std::wstring, std::wstring>> selections = {
        {L"-p1", L"*.txt"}, {L"-r0", L"dir/*.txt"}, {L"-r1", L"dir/*.txt"},
        {L"-r2", L"dir"}, {L"-jx*.txt", L"*.*"}, {L"-p2 -jxdir", L"*.*"}};
    for (size_t index = 0; index < selections.size(); ++index) {
        const std::wstring id = std::to_wstring(index);
        const std::wstring selection = selections[index].first;
        const std::wstring pattern = quote_argument(selections[index].second);
        const std::wstring destination = root + L"\\extract" + id;
        const std::wstring deleted = root + L"\\delete" + id + L".lzh";
        ensure_directory(destination);
        if (!CopyFileW(archive.c_str(), deleted.c_str(), TRUE))
            throw std::runtime_error("matching probe: cannot copy fixture");
        execute(L"test" + id, L"t " + selection + L" " + quote_argument(archive) + L" " + pattern);
        execute(L"print" + id, L"p " + selection + L" " + quote_argument(archive) + L" " + pattern);
        execute(L"extract" + id, L"x -y " + selection + L" " + quote_argument(archive) + L" " +
            quote_argument(destination + L"\\") + L" " + pattern);
        std::cout << "extract" << index << ".files=";
        for (size_t member = 0; member < names.size(); ++member) {
            const std::wstring path = destination + L"\\" + names[member];
            if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
                if (read_file(path) != std::vector<unsigned char>(41 + member,
                    static_cast<unsigned char>('A' + member)))
                    throw std::runtime_error("matching probe: extracted payload mismatch");
                std::cout << member << ',';
            }
        }
        std::cout << '\n';
        execute(L"delete" + id, L"d -y " + selection + L" " + quote_argument(deleted) + L" " + pattern);
        execute(L"remaining" + id, L"l -n1 -x1 " + quote_argument(deleted));
        for (const wchar_t command : {L'y', L'n'}) {
            const std::wstring transformed = root + L"\\transform" + command + id + L".lzh";
            if (!CopyFileW(archive.c_str(), transformed.c_str(), TRUE))
                throw std::runtime_error("matching probe: cannot prepare transform");
            enum_layout = EnumLayout::W32;
            enum_result = FALSE;
            enum_records.clear();
            proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
            const std::wstring transform = std::wstring(1, command) + L" -y -gm1 -n1 -x1 " +
                selection + L" " + quote_argument(transformed) + L" " + pattern;
            const int result = unlha(nullptr, transform.c_str(), scratch, _countof(scratch));
            if (result != 0) {
                DWORD system_error = 0;
                const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
                std::cerr << "matching transform result=" << result << ",error=" << error
                          << ",system=" << system_error << ",output=" << quote_wide(scratch) << '\n';
            }
            proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
            if (result != 0 || read_file(transformed) != read_file(archive))
                throw std::runtime_error("matching probe: rejected transform changed archive");
            std::cout << "transform" << static_cast<char>(command) << index
                      << ".callbacks=" << enum_records.size() << '\n';
        }
    }
    enum_layout = EnumLayout::None;
    enum_result = TRUE;
    return 0;
}

int run_update_policy_probe(const wchar_t* dll_path, const wchar_t* workspace,
                            const wchar_t* commands = L"exaufm") {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const auto open = proc<FnOpenW>(module.handle, "UnlhaOpenArchiveW");
    const auto find = proc<FnFindFirstW>(module.handle, "UnlhaFindFirstW");
    const auto close = proc<FnClose>(module.handle, "UnlhaCloseArchive");
    const auto extract = proc<FnExtractMemW>(module.handle, "UnlhaExtractMemW");
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring full_archive = root + L"\\full.lzh";
    const std::wstring partial_archive = root + L"\\partial.lzh";
    ensure_directory(root);
    ensure_directory(source);
    const std::vector<std::wstring> names = {
        L"a_old.bin", L"b_same.bin", L"c_new.bin", L"d_size.bin", L"e_absent.bin"};
    std::wstring members;
    for (const auto& name : names) {
        write_file(source + L"\\" + name, std::vector<unsigned char>(41, 'A'));
        set_file_times(source + L"\\" + name, 2024, 1, 2, 3, 4, 6);
        members += L" " + name;
    }
    wchar_t scratch[65536]{};
    const std::wstring add = L"a -y -gm1 -jm0 " + quote_argument(full_archive) + L" " +
        quote_argument(source + L"\\") + members;
    if (unlha(nullptr, add.c_str(), scratch, _countof(scratch)) != 0 ||
        !CopyFileW(full_archive.c_str(), partial_archive.c_str(), TRUE))
        throw std::runtime_error("update policy: cannot create fixtures");
    const std::wstring remove = L"d -y -gm1 " + quote_argument(partial_archive) + L" e_absent.bin";
    if (unlha(nullptr, remove.c_str(), scratch, _countof(scratch)) != 0)
        throw std::runtime_error("update policy: cannot remove absent member");
    for (const auto& archive : {full_archive, partial_archive})
        set_file_times(archive, 2024, 1, 2, 3, 4, 6);
    const auto full_bytes = read_file(full_archive);
    const auto partial_bytes = read_file(partial_archive);

    const std::vector<std::wstring> options = {
        L"", L"-c0", L"-c1", L"-u0", L"-u1", L"-u2", L"-u3",
        L"-gf0", L"-gf1", L"-gf2", L"-gf3", L"-jn1", L"-jn1 -jn0",
        L"-c1 -u2", L"-u2 -c1", L"-gf2 -u1", L"-u1 -gf2",
        L"-c1 -u1", L"-u1 -c1", L"-c1 -u3", L"-c1 -gf1", L"-u0 -c0"};
    std::vector<std::pair<std::wstring, std::wstring>> archives_to_verify;
    for (const wchar_t command : std::wstring(commands)) {
        for (size_t option = 0; option < options.size(); ++option) {
            const bool extracting = command == L'e' || command == L'x';
            const std::wstring id = std::wstring(1, command) + std::to_wstring(option);
            const std::wstring directory = root + L"\\" + id;
            const std::wstring archive = root + L"\\" + id + L".lzh";
            ensure_directory(directory);
            write_file(archive, extracting ? full_bytes : partial_bytes);
            set_file_times(archive, 2024, 1, 2, 3, 4, 6);
            for (size_t index = 0; index < (extracting ? 4U : names.size()); ++index) {
                const std::wstring path = directory + L"\\" + names[index];
                write_file(path, std::vector<unsigned char>(index == 3 ? 42 : 41, 'D'));
                set_file_times(path, index == 0 ? 2023 : (index == 2 ? 2025 : 2024),
                               1, 2, 3, 4, 6);
            }
            enum_layout = EnumLayout::W32;
            enum_result = TRUE;
            enum_records.clear();
            proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
            const std::wstring line = std::wstring(1, command) + L" -y -gm1 -jm0 " + options[option] +
                L" " + quote_argument(archive) + L" " + quote_argument(directory + L"\\") + members;
            SetLastError(0x12345678U);
            scratch[0] = L'\0';
            const int result = unlha(nullptr, line.c_str(), scratch, _countof(scratch));
            const DWORD win32_error = GetLastError();
            DWORD system_error = 0x87654321U;
            const int compat_error = last_error(&system_error);
            const size_t callbacks = enum_records.size();
            proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
            std::wstring output(scratch);
            std::wstring slash_root = root;
            std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
            for (const auto& prefix : {root, slash_root}) {
                size_t offset = 0;
                while ((offset = output.find(prefix, offset)) != std::wstring::npos) {
                    output.replace(offset, prefix.size(), L"<ROOT>");
                    offset += 6;
                }
            }
            std::cout << "case=" << static_cast<char>(command) << ':' << quote_wide(options[option].c_str())
                      << " result=" << result << " win32=" << win32_error << " compat=" << compat_error
                      << " system=" << system_error << " callbacks=" << callbacks
                      << " output=" << quote_wide(output.c_str()) << " files=";
            for (size_t index = 0; index < names.size(); ++index) {
                const std::wstring path = directory + L"\\" + names[index];
                if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) std::cout << '-';
                else {
                    const auto bytes = read_file(path);
                    if (bytes != std::vector<unsigned char>(41, 'A') &&
                        bytes != std::vector<unsigned char>(index == 3 ? 42 : 41, 'D'))
                        throw std::runtime_error("update policy: unexpected disk payload");
                    std::cout << static_cast<char>(bytes[0]);
                }
            }
            if (!extracting) {
                archives_to_verify.emplace_back(id, archive);
            }
            std::cout << '\n';
            std::cout.flush();
        }
    }
    // 書庫 API の検査は命令列の実行後に分離し、両系統の状態が干渉しないようにする。
    for (const auto& item : archives_to_verify) {
        std::cout << "archive=" << quote_wide(item.first.c_str()) << " profile=";
        for (size_t index = 0; index < names.size(); ++index) {
            HARC handle = open(nullptr, item.second.c_str(), 0);
            if (!handle) throw std::runtime_error("update policy: cannot open result archive");
            INDIVIDUALINFOW info{};
            const int found = find(handle, names[index].c_str(), &info);
            close(handle);
            if (found != 0) {
                std::cout << '-';
                continue;
            }
            std::vector<unsigned char> bytes(info.dwOriginalSize);
            // 更新判定では展開データだけを確認する。既定の進捗画面は専用の UI 試験で比較するため、
            // 数百回のメモリ展開でモデルレス画面を作らないよう明示的に抑止する。
            const std::wstring memory = L"-n1 " + quote_argument(item.second) + L" " + quote_argument(names[index]);
            if (extract(nullptr, memory.c_str(), bytes.data(), static_cast<DWORD>(bytes.size()),
                        nullptr, nullptr, nullptr) != 0 ||
                (bytes != std::vector<unsigned char>(41, 'A') &&
                 bytes != std::vector<unsigned char>(index == 3 ? 42 : 41, 'D')))
                throw std::runtime_error("update policy: unexpected archive payload");
            std::cout << static_cast<char>(bytes[0]);
        }
        std::cout << '\n';
    }
    enum_layout = EnumLayout::None;
    return 0;
}

int run_overwrite_policy_probe(const wchar_t* dll_path, const wchar_t* workspace,
                                const bool registry_options = false) {
    Module module(dll_path);
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\overwrite.lzh";
    ensure_directory(root);
    ensure_directory(source);
    const std::vector<std::wstring> names = {L"normal.txt", L"readonly.bin", L"hidden.bin", L"system.bin", L"noext"};
    const DWORD attributes[] = {0, FILE_ATTRIBUTE_READONLY, FILE_ATTRIBUTE_HIDDEN, FILE_ATTRIBUTE_SYSTEM, 0};
    std::wstring members;
    for (const auto& name : names) {
        write_file(source + L"\\" + name, std::vector<unsigned char>(41, 'A'));
        set_file_times(source + L"\\" + name, 2024, 1, 2, 3, 4, 6);
        members += L" " + name;
    }
    wchar_t output[65536]{};
    const std::wstring add = L"a -y -gm1 -jm0 " + quote_argument(archive) + L" " +
        quote_argument(source + L"\\") + members;
    if (unlha(nullptr, add.c_str(), output, _countof(output)) != 0)
        throw std::runtime_error("overwrite policy: cannot create fixture");
    std::vector<std::wstring> options = {
        L"x", L"x -m1", L"e -m1", L"x -m2", L"e -m2", L"x -y -m2", L"x -m2 -y",
        L"x -ga1", L"x -ga2", L"x -y -ga2", L"x -m2 -ga2", L"x -c1 -jn1 -m2", L"x -gf1 -m2",
        L"x -y", L"x -y -ga0", L"x -ga2 -y", L"x -m0 -y", L"e", L"e -m0", L"x -m1 -y0"};
    if (registry_options) {
        const std::vector<std::wstring> extra{
            L"x -+", L"x -+0", L"x -+1", L"x -+1 -+0", L"x -+0 -+1",
            L"x -jn0", L"x -jn0 -+0", L"x -+0 -jn0", L"x -c0", L"x -c0 -+0",
            L"x -+0 -c0", L"x -jn0 -+", L"x -+ -jn0", L"x -jn0 -+1 -+0",
            L"x -+1 -jn0 -+0", L"x -+1 -jn0", L"e -+", L"e -+0", L"e -jn0",
            L"x -+jn0", L"x -+0jn0", L"x -jn0+0", L"x -jn0+", L"x -+2", L"x -+-",
            L"x -gf1", L"x -jn1 -gf1", L"x -gf1 -jn1", L"x -jn1 -gf1 -m2",
            L"x -gf1 -jn1 -m2", L"x -+3", L"x -+-1", L"x -+9", L"x -+0 -+2"};
        options.insert(options.end(), extra.begin(), extra.end());
    }
    for (size_t option = 0; option < options.size(); ++option) {
        const std::wstring destination = root + L"\\case" + std::to_wstring(option);
        ensure_directory(destination);
        for (size_t index = 0; index < names.size(); ++index) {
            const std::wstring path = destination + L"\\" + names[index];
            write_file(path, std::vector<unsigned char>(41, 'D'));
            set_file_times(path, 2023, 1, 2, 3, 4, 6);
            if (attributes[index] && !SetFileAttributesW(path.c_str(), attributes[index]))
                throw std::runtime_error("overwrite policy: cannot set test attributes");
        }
        write_file(destination + L"\\normal.000", {'X'});
        enum_layout = EnumLayout::W32;
        enum_result = TRUE;
        enum_records.clear();
        proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
        const std::wstring command = options[option] + L" -gm1 " + quote_argument(archive) +
            L" " + quote_argument(destination + L"\\");
        SetLastError(0x12345678U);
        output[0] = L'\0';
        const int result = unlha(nullptr, command.c_str(), output, _countof(output));
        const DWORD win32_error = GetLastError();
        DWORD system_error = 0x87654321U;
        const int compat_error = last_error(&system_error);
        const size_t callbacks = enum_records.size();
        proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
        std::wstring captured(output);
        std::wstring slash_root = root;
        std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
        for (const auto& prefix : {root, slash_root}) {
            size_t offset = 0;
            while ((offset = captured.find(prefix, offset)) != std::wstring::npos) {
                captured.replace(offset, prefix.size(), L"<ROOT>");
                offset += 6;
            }
        }
        std::cout << "case=" << quote_wide(options[option].c_str()) << " result=" << result
                  << " win32=" << win32_error << " compat=" << compat_error << " system=" << system_error
                  << " callbacks=" << callbacks << " output=" << quote_wide(captured.c_str()) << " files=";
        std::vector<std::string> files;
        WIN32_FIND_DATAW data{};
        HANDLE find = FindFirstFileW((destination + L"\\*").c_str(), &data);
        if (find == INVALID_HANDLE_VALUE) throw std::runtime_error("overwrite policy: cannot enumerate results");
        do {
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
            const auto bytes = read_file(destination + L"\\" + data.cFileName);
            if (bytes != std::vector<unsigned char>(41, 'A') && bytes != std::vector<unsigned char>(41, 'D') &&
                bytes != std::vector<unsigned char>{'X'})
                throw std::runtime_error("overwrite policy: unexpected extracted payload");
            files.push_back(quote_wide(data.cFileName) + ':' + static_cast<char>(bytes[0]) + ':' +
                            std::to_string(data.dwFileAttributes & 7U));
        } while (FindNextFileW(find, &data));
        FindClose(find);
        std::sort(files.begin(), files.end());
        for (const auto& file : files) std::cout << file << ',';
        std::cout << '\n';
        std::cout.flush();
    }
    enum_layout = EnumLayout::None;
    return 0;
}

int run_comment_probe(const wchar_t* dll_path, const wchar_t* workspace,
                       const wchar_t* verification_dll = nullptr) {
    Module module(dll_path);
    Module verifier(verification_dll ? verification_dll : dll_path);
    const auto unlha_a = proc<FnUnlhaA>(module.handle, "Unlha");
    const auto unlha_w = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const auto last_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\base.lzh";
    for (const auto& path : {root, source, source + L"\\dir"}) ensure_directory(path);
    const std::vector<unsigned char> payload(317, 'A');
    write_file(source + L"\\alpha.txt", payload);
    write_file(source + L"\\dir\\alpha.txt", payload);
    for (const auto& path : {source + L"\\alpha.txt", source + L"\\dir\\alpha.txt"})
        set_file_times(path, 2024, 1, 2, 3, 4, 6);
    wchar_t scratch[65536]{};
    const std::wstring add = L"a -y -x1 " + quote_argument(archive) + L" " +
        quote_argument(source + L"\\") + L" alpha.txt dir/alpha.txt";
    if (unlha_w(nullptr, add.c_str(), scratch, _countof(scratch)) != 0)
        throw std::runtime_error("comment probe: fixture creation failed");
    for (const int level : {0, 1}) {
        const std::wstring legacy_add = L"a -y -x1 -h" + std::to_wstring(level) + L" " +
            quote_argument(root + L"\\base" + std::to_wstring(level) + L".lzh") + L" " +
            quote_argument(source + L"\\") + L" alpha.txt dir/alpha.txt";
        if (unlha_w(nullptr, legacy_add.c_str(), scratch, _countof(scratch)) != 0)
            throw std::runtime_error("comment probe: legacy fixture creation failed");
    }
    const std::string ascii = "sample comment\r\nsecond line\r\n";
    std::vector<unsigned char> ascii_content(ascii.begin(), ascii.end());
    ascii_content.push_back(0);
    write_file(root + L"\\ascii.txt", ascii_content);
    const std::wstring wide = L"sample comment\r\n日本語の注釈\r\n";
    const auto* wide_bytes = reinterpret_cast<const unsigned char*>(wide.data());
    std::vector<unsigned char> wide_content(wide_bytes, wide_bytes + wide.size() * sizeof(wchar_t));
    write_file(root + L"\\wide.txt", wide_content);
    wide_content.insert(wide_content.begin(), {0xff, 0xfe});
    write_file(root + L"\\wide-bom.txt", wide_content);
    for (size_t i = 0; i + 1 < wide_content.size(); i += 2)
        std::swap(wide_content[i], wide_content[i + 1]);
    write_file(root + L"\\wide-be.txt", wide_content);
    const int utf8_size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::vector<unsigned char> utf8(3 + utf8_size);
    utf8[0] = 0xef;
    utf8[1] = 0xbb;
    utf8[2] = 0xbf;
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, reinterpret_cast<char*>(utf8.data() + 3),
                        utf8_size, nullptr, nullptr);
    write_file(root + L"\\utf8.txt", utf8);
    write_file(root + L"\\empty.txt", {});
    write_file(root + L"\\clear.txt", {0});
    std::vector<unsigned char> long_content;
    for (size_t i = 0; i < 8192; ++i) {
        long_content.push_back('C');
        long_content.push_back(0);
    }
    write_file(root + L"\\long.txt", long_content);

    auto report_headers = [&](const std::wstring& path) {
        const auto bytes = read_file(path);
        auto read_le = [&](const size_t position, const size_t count) {
            unsigned long value = 0;
            for (size_t i = 0; i < count; ++i)
                value |= static_cast<unsigned long>(bytes.at(position + i)) << (i * 8);
            return value;
        };
        size_t offset = 0;
        while (offset + 26 <= bytes.size() && bytes[offset] != 0) {
            const unsigned level = bytes[offset + 20];
            const size_t header_size = level == 2 ? read_le(offset, 2) : bytes[offset] + 2;
            const size_t packed = read_le(offset + 7, 4);
            size_t extension = level == 2 ? offset + 24 : offset + header_size - 2;
            std::cout << "header=" << level;
            if (level != 0) {
                while (extension + 3 <= bytes.size()) {
                    const size_t size = read_le(extension, 2);
                    if (size == 0) break;
                    if (size < 3 || size > bytes.size() - extension)
                        throw std::runtime_error("comment probe: invalid extension");
                    const unsigned type = bytes[extension + 2];
                    if (type == 0x3f || (type >= 0xc4 && type <= 0xc8)) {
                        unsigned long long hash = 14695981039346656037ULL;
                        for (size_t i = extension + 3; i < extension + size; ++i) {
                            hash ^= bytes[i];
                            hash *= 1099511628211ULL;
                        }
                        std::cout << ",comment=" << type << ',' << size - 3 << ',' << hash;
                    }
                    extension += size;
                }
            }
            std::cout << '\n';
            offset += header_size + packed;
            if (level > 2) break;
        }
    };
    std::vector<std::wstring> verification_paths;
    auto invoke = [&](const wchar_t* label, const wchar_t* filename, const bool wide_api,
                       const wchar_t* options) {
        const std::wstring target = root + L"\\" + label + L".lzh";
        std::wstring input = std::wcscmp(label, L"empty") == 0 || std::wcscmp(label, L"wide-empty") == 0 ||
            std::wcscmp(label, L"clear") == 0 ? root + L"\\ansi.lzh" : archive;
        if (std::wcscmp(label, L"existing-level-zero") == 0) input = root + L"\\base0.lzh";
        if (std::wcscmp(label, L"existing-level-one") == 0) input = root + L"\\base1.lzh";
        if (!CopyFileW(input.c_str(), target.c_str(), TRUE))
            throw std::runtime_error("comment probe: fixture copy failed");
        const std::wstring command = L"c -y -gm1 -n1 " + std::wstring(options) + L" -jz" +
            quote_argument(root + L"\\" + filename) + L" " + quote_argument(target) + L" alpha.txt";
        enum_layout = EnumLayout::W32;
        enum_result = FALSE;
        enum_records.clear();
        proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(enum_probe);
        SetLastError(0x12345678U);
        int result;
        std::wstring output;
        if (wide_api) {
            wchar_t buffer[65536]{};
            result = unlha_w(nullptr, command.c_str(), buffer, _countof(buffer));
            output = buffer;
        } else {
            char command_a[32768]{}, buffer[65536]{};
            WideCharToMultiByte(932, 0, command.c_str(), -1, command_a, sizeof(command_a), nullptr, nullptr);
            result = unlha_a(nullptr, command_a, buffer, _countof(buffer));
            wchar_t converted[65536]{};
            MultiByteToWideChar(932, 0, buffer, -1, converted, _countof(converted));
            output = converted;
        }
        const DWORD win32_error = GetLastError();
        DWORD system_error = 0x87654321U;
        const int compat_error = last_error(&system_error);
        proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc")();
        std::wstring slash_root = root;
        std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
        for (const auto& prefix : {root, slash_root}) {
            size_t position = 0;
            while ((position = output.find(prefix, position)) != std::wstring::npos) {
                output.replace(position, prefix.size(), L"<ROOT>");
                position += 6;
            }
        }
        std::cout << "case=" << quote_wide(label) << " result=" << result
                  << " output=" << quote_wide(output.c_str()) << " win32=" << win32_error
                  << " compat=" << compat_error << " system=" << system_error
                  << " callbacks=" << enum_records.size() << '\n';
        report_headers(target);
        verification_paths.push_back(target);
        std::cout.flush();
    };
    invoke(L"ansi", L"ascii.txt", false, L"");
    invoke(L"wide", L"wide.txt", true, L"");
    invoke(L"wide-bom", L"wide-bom.txt", true, L"");
    invoke(L"ansi-wide-bom", L"wide-bom.txt", false, L"");
    invoke(L"wide-be", L"wide-be.txt", true, L"");
    invoke(L"ansi-utf8", L"utf8.txt", false, L"");
    invoke(L"wide-utf8", L"utf8.txt", true, L"");
    invoke(L"empty", L"empty.txt", false, L"");
    invoke(L"wide-empty", L"empty.txt", true, L"");
    invoke(L"clear", L"clear.txt", false, L"");
    invoke(L"long", L"long.txt", true, L"");
    invoke(L"level-one", L"ascii.txt", false, L"-h1");
    invoke(L"level-zero", L"ascii.txt", false, L"-h0");
    invoke(L"existing-level-zero", L"ascii.txt", false, L"");
    invoke(L"existing-level-one", L"ascii.txt", false, L"");
    invoke(L"root-only", L"ascii.txt", false, L"-p1");
    for (const size_t length : {1024U, 2047U, 2048U}) {
        const std::wstring label = L"length-" + std::to_wstring(length);
        const std::wstring filename = label + L".txt";
        std::vector<unsigned char> content(length, 'C');
        content.push_back(0);
        write_file(root + L"\\" + filename, content);
        invoke(label.c_str(), filename.c_str(), false, L"-p1");
    }
    enum_layout = EnumLayout::None;
    enum_result = TRUE;
    for (const auto& target : verification_paths) {
        if (!proc<FnCheckW>(verifier.handle, "UnlhaCheckArchiveW")(target.c_str(), CHECKARCHIVE_FULLCRC))
            throw std::runtime_error("comment probe: header/data CRC verification failed");
        for (const auto* member : {L"alpha.txt", L"dir/alpha.txt"}) {
            const std::wstring extract = quote_argument(target) + L" " + quote_argument(member);
            std::vector<unsigned char> extracted(payload.size());
            if (proc<FnExtractMemW>(verifier.handle, "UnlhaExtractMemW")(
                    nullptr, extract.c_str(), extracted.data(), static_cast<DWORD>(extracted.size()),
                    nullptr, nullptr, nullptr) != 0 || extracted != payload)
                throw std::runtime_error("comment probe: stored payload changed");
        }
    }
    std::cout << "verified=header-crc,data-crc,payload\n";
    return 0;
}

int run_method_switch_probe(const wchar_t* dll_path, const wchar_t* workspace,
                             const wchar_t* verification_dll) {
    Module module(dll_path);
    Module verifier(verification_dll ? verification_dll : dll_path);
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    ensure_directory(root);
    ensure_directory(source);
    std::vector<unsigned char> payload(65539);
    for (size_t index = 0; index < payload.size(); ++index)
        payload[index] = static_cast<unsigned char>((index * 37U + index / 251U) & 0xffU);
    write_file(source + L"\\payload.bin", payload);
    set_file_times(source + L"\\payload.bin", 2024, 1, 2, 3, 4, 6);
    const std::vector<int> methods{2, 0, 1, 3, 4, 2, 0, 2, 2};
    for (size_t index = 0; index < methods.size(); ++index) {
        const int level = index == 7 ? 0 : index == 8 ? 1 : 2;
        const std::wstring archive = root + L"\\method" + std::to_wstring(index) + L".lzh";
        const std::wstring command = L"a -y -n1 -jm" + std::to_wstring(methods[index]) + L" -h" +
            std::to_wstring(level) + L" " + quote_argument(archive) + L" " +
            quote_argument(source + L"\\") + L" payload.bin";
        wchar_t output[4096]{};
        const int result = proc<FnUnlhaW>(module.handle, "UnlhaW")(
            nullptr, command.c_str(), output, _countof(output));
        if (result != 0) throw std::runtime_error("method probe: compression failed");
        const auto bytes = read_file(archive);
        if (bytes.size() < 24) throw std::runtime_error("method probe: missing header");
        const std::string method(bytes.begin() + 2, bytes.begin() + 7);
        std::cout << "method" << index << "=" << method << ",header=" << static_cast<unsigned>(bytes[20]);
        const std::wstring extract_command = quote_argument(archive) + L" payload.bin";
        for (const HMODULE reader : {module.handle, verifier.handle}) {
            if (!proc<FnCheckW>(reader, "UnlhaCheckArchiveW")(archive.c_str(), CHECKARCHIVE_FULLCRC))
                throw std::runtime_error("method probe: archive validation failed");
            std::vector<unsigned char> extracted(payload.size());
            if (proc<FnExtractMemW>(reader, "UnlhaExtractMemW")(
                    nullptr, extract_command.c_str(), extracted.data(), static_cast<DWORD>(extracted.size()),
                    nullptr, nullptr, nullptr) != 0 || extracted != payload)
                throw std::runtime_error("method probe: extracted payload mismatch");
        }
        std::cout << ",crc-and-payload=ok\n";
    }
    return 0;
}

int run_response_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\input.lzh";
    for (const auto& path : {root, source, source + L"\\dir"}) ensure_directory(path);
    for (const auto* name : {L"alpha.txt", L"beta.log", L"dir\\alpha.txt", L"-x1", L"-n1", L"@literal"}) {
        const std::wstring path = source + L"\\" + name;
        write_file(path, std::vector<unsigned char>(317, 'A'));
        set_file_times(path, 2024, 1, 2, 3, 4, 6);
    }
    wchar_t scratch[65536]{};
    // 構文比較用の書庫は非圧縮にし、圧縮器ごとの圧縮率差を出力比較へ混ぜない。
    const std::wstring add = L"a -y -x1 -jm0 " + quote_argument(archive) + L" " +
        quote_argument(source + L"\\") + L" alpha.txt beta.log dir/alpha.txt -gb-x1 -gb-n1 -gb@literal";
    if (proc<FnUnlhaW>(module.handle, "UnlhaW")(
            nullptr, add.c_str(), scratch, _countof(scratch)) != 0)
        throw std::runtime_error("response probe: fixture creation failed");
    set_file_times(archive, 2024, 1, 2, 3, 4, 6);
    auto write_text = [&](const std::wstring& filename, const std::wstring& value, const int encoding) {
        std::vector<unsigned char> bytes;
        if (encoding == 0 || encoding == 3) {
            const UINT code_page = encoding == 3 ? CP_UTF8 : 932;
            const int size = WideCharToMultiByte(code_page, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
            bytes.resize(size);
            WideCharToMultiByte(code_page, 0, value.c_str(), -1, reinterpret_cast<char*>(bytes.data()),
                                size, nullptr, nullptr);
            if (encoding == 3) bytes.insert(bytes.begin(), {0xef, 0xbb, 0xbf});
        } else {
            const auto* begin = reinterpret_cast<const unsigned char*>(value.c_str());
            bytes.assign(begin, begin + (value.size() + 1) * sizeof(wchar_t));
            if (encoding >= 2) bytes.insert(bytes.begin(), {0xff, 0xfe});
            if (encoding == 4)
                for (size_t index = 0; index + 1 < bytes.size(); index += 2)
                    std::swap(bytes[index], bytes[index + 1]);
        }
        write_file(root + L"\\" + filename, bytes);
    };
    auto invoke = [&](const std::wstring& label, const std::wstring& command, const bool wide) {
        int result;
        DWORD win32_error;
        std::wstring output;
        SetLastError(0x12345678U);
        if (wide) {
            wchar_t buffer[65536]{};
            result = proc<FnUnlhaW>(module.handle, "UnlhaW")(
                nullptr, command.c_str(), buffer, _countof(buffer));
            win32_error = GetLastError();
            output = buffer;
        } else {
            char command_a[32768]{}, buffer[65536]{};
            WideCharToMultiByte(932, 0, command.c_str(), -1, command_a, sizeof(command_a), nullptr, nullptr);
            result = proc<FnUnlhaA>(module.handle, "Unlha")(
                nullptr, command_a, buffer, _countof(buffer));
            win32_error = GetLastError();
            wchar_t converted[65536]{};
            MultiByteToWideChar(932, 0, buffer, -1, converted, _countof(converted));
            output = converted;
        }
        DWORD system_error = 0x87654321U;
        const int error = proc<FnLastError>(module.handle, "UnlhaGetLastError")(&system_error);
        std::wstring slash_root = root;
        std::replace(slash_root.begin(), slash_root.end(), L'\\', L'/');
        for (const auto& prefix : {root, slash_root}) {
            size_t offset = 0;
            while ((offset = output.find(prefix, offset)) != std::wstring::npos) {
                output.replace(offset, prefix.size(), L"<ROOT>");
                offset += 6;
            }
        }
        std::cout << "case=" << quote_wide(label.c_str()) << " result=" << result
                  << " output=" << quote_wide(output.c_str()) << " win32=" << win32_error
                  << " compat=" << error << " system=" << system_error << '\n';
        std::cout.flush();
    };
    const std::wstring base = L"l -gm1 -n1 " + quote_argument(archive) + L" ";
    for (const bool wide : {false, true}) {
        const std::wstring label = wide ? L"W" : L"A";
        const std::wstring basic = label + L"-basic.rsp";
        write_text(basic, L"*.txt\r\n-p1\r\n", wide ? 1 : 0);
        const std::wstring response = quote_argument(root + L"\\" + basic);
        for (const auto* controls : {L"", L"--1 ", L"--1 --0 ", L"--2 ", L"--3 ",
                                     L"--3 /-0 ", L"--2 /-0 "})
            invoke(label + L" " + controls, base + controls + L"@" + response, wide);
        invoke(label + L" alternate", base + L"--! !" + response, wide);
        for (const auto* controls : {L"--3 -x1", L"--3 -x1 /-0 *.txt", L"--3 /-0 -x1 *.txt",
                                     L"--2 /n0 *.txt", L"--1 -x1 *.txt", L"-gb-n1",
                                     L"--3 --0 *.txt", L"--1 @literal", L"--2 -n1", L"-gb@literal"})
            invoke(label + L" " + controls, base + controls, wide);
        for (const int encoding : {2, 3, 4}) {
            const std::wstring filename = label + L"-bom" + std::to_wstring(encoding) + L".rsp";
            write_text(filename, L"*.txt -p1", encoding);
            invoke(filename, base + L"@" + quote_argument(root + L"\\" + filename), wide);
        }
        const std::wstring whole = label + L"-whole.rsp";
        write_text(whole, base + L"*.txt -p1", wide ? 1 : 0);
        invoke(label + L" whole-command", L"@" + quote_argument(root + L"\\" + whole), wide);
        const std::wstring nested = label + L"-nested.rsp";
        write_text(nested, L"@" + response, wide ? 1 : 0);
        invoke(label + L" nested", base + L"@" + quote_argument(root + L"\\" + nested), wide);
        invoke(label + L" missing", base + L"@" + quote_argument(root + L"\\missing.rsp"), wide);
        invoke(label + L" missing-parent", base + L"@" + quote_argument(root + L"\\absent\\missing.rsp"), wide);
        const std::wstring state = label + L"-state.rsp";
        write_text(state, L"--3 -x1 /-0 *.txt", wide ? 1 : 0);
        invoke(label + L" response-controls", base + L"@" + quote_argument(root + L"\\" + state), wide);
        write_text(state, L"--3", wide ? 1 : 0);
        invoke(label + L" controls-carry", base + L"@" + quote_argument(root + L"\\" + state) + L" -x1", wide);
        write_file(root + L"\\" + state, {});
        invoke(label + L" empty-response", base + L"@" + quote_argument(root + L"\\" + state), wide);
        const auto before = read_file(archive);
        invoke(label + L" failed-delete", L"d -y -gm1 -n1 " + quote_argument(archive) +
            L" @" + quote_argument(root + L"\\missing.rsp"), wide);
        if (read_file(archive) != before)
            throw std::runtime_error("response probe: read failure modified archive");
    }
    return 0;
}

unsigned registration_callback_count = 0;
unsigned registration_alternate_count = 0;

BOOL CALLBACK registration_callback(LPVOID) {
    ++registration_callback_count;
    return TRUE;
}

BOOL CALLBACK registration_alternate(LPVOID) {
    ++registration_alternate_count;
    return TRUE;
}

struct EnumRegistrationBusyContext {
    HMODULE module;
    const char* name;
    DWORD size;
    unsigned operation;
    unsigned calls = 0;
};
EnumRegistrationBusyContext* registration_busy_context = nullptr;

BOOL CALLBACK registration_busy_callback(LPVOID) {
    auto& context = *registration_busy_context;
    if (++context.calls != 1) return TRUE;
    const BOOL running = proc<FnBool0>(context.module, "UnlhaGetRunning")();
    const auto callback = context.operation == 0 ? registration_alternate : context.operation == 1
        ? nullptr : reinterpret_cast<UNLHA_WND_ENUMMEMBPROC>(1);
    const BOOL result = context.operation == 3
        ? proc<FnBool0>(context.module, context.name)()
        : context.size ? proc<FnSetEnum64>(context.module, context.name)(callback, context.size)
                       : proc<FnSetEnum>(context.module, context.name)(callback);
    DWORD system = 0;
    const int error = proc<FnLastError>(context.module, "UnlhaGetLastError")(&system);
    std::cout << "busy.inner=" << result << ",error=" << error << ",system=" << system
              << ",running=" << running << '\n';
    return TRUE;
}

int run_enum_registration_probe(const wchar_t* dll_path, const wchar_t* archive_path, const bool busy = false) {
    std::cout << std::unitbuf;
    Module module(dll_path);
    std::cout << "registration.loaded=1\n";
    const auto set64 = proc<FnSetEnum64>(module.handle, "UnlhaSetEnumMembersProc64");
    const auto clear = proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc");
    const auto get_error = proc<FnLastError>(module.handle, "UnlhaGetLastError");
    const auto unlha = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const std::wstring command = L"l -gm1 " + quote_argument(archive_path);
    auto report = [&](const std::string& name, BOOL result) {
        DWORD system = 0x12345678;
        const int error = get_error(&system);
        std::cout << name << '=' << result << ",error=" << error << ",system=" << system << '\n';
    };
    auto list = [&](const std::string& name) {
        registration_callback_count = registration_alternate_count = 0;
        wchar_t output[4096]{};
        const int result = unlha(nullptr, command.c_str(), output, _countof(output));
        report(name, result);
        std::cout << name << ".callbacks=" << registration_callback_count << ','
                  << registration_alternate_count << '\n';
    };
    struct Setter { const char* name; DWORD size; };
    const Setter setters[] = {
        {"UnlhaSetEnumMembersProc", 0}, {"UnlhaSetEnumMembersProcA", 0},
        {"UnlhaSetEnumMembersProcW", 0},
        {"UnlhaSetEnumMembersProc64", sizeof(UNLHA_ENUM_MEMBER_INFOA)},
        {"UnlhaSetEnumMembersProc64", sizeof(UNLHA_ENUM_MEMBER_INFO64A)},
        {"UnlhaSetEnumMembersProc64", sizeof(UNLHA_ENUM_MEMBER_INFOW)},
        {"UnlhaSetEnumMembersProc64", sizeof(UNLHA_ENUM_MEMBER_INFO64W)}
    };
    for (const auto& setter : setters) {
        const std::string label = std::string(setter.name) + '.' + std::to_string(setter.size);
        const auto set = [&](UNLHA_WND_ENUMMEMBPROC callback) {
            return setter.size ? set64(callback, setter.size)
                : proc<FnSetEnum>(module.handle, setter.name)(callback);
        };
        set64(registration_callback, sizeof(UNLHA_ENUM_MEMBER_INFOA));
        report(label + ".initial-clear", clear());
        report(label + ".initial-invalid-size", set64(registration_callback, 1));
        report(label + ".null-initial", set(nullptr));
        list(label + ".empty");
        report(label + ".first", set(registration_callback));
        set64(registration_callback, 1);
        report(label + ".null-retained", set(nullptr));
        list(label + ".retained");
        report(label + ".replace", set(registration_alternate));
        list(label + ".replaced");
        report(label + ".clear64", proc<FnBool0>(module.handle, "UnlhaClearEnumMembersProc64")());
        list(label + ".cleared");
        report(label + ".clear-again", clear());
        // 不正なアドレスは登録の検査にだけ使い、絶対にコールバックとして実行しない。
        report(label + ".invalid-address", set(reinterpret_cast<UNLHA_WND_ENUMMEMBPROC>(1)));
        clear();
    }
    for (const DWORD size : {0U, 1U, 1085U, 1087U, 1093U, 1095U, 2117U, 2119U, 2125U, 2127U, MAXDWORD}) {
        for (const bool present : {false, true}) {
            clear();
            proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(registration_callback);
            const std::string label = "invalid-size." + std::to_string(size) + '.' + std::to_string(present);
            report(label, set64(present ? registration_alternate : nullptr, size));
            list(label + ".retained");
        }
    }
    clear();
    // 原版の実行中再登録は、次の一覧取得で例外終了する。通常比較から独立した診断にする。
    if (!busy) return 0;
    for (const auto& setter : setters) {
        for (const unsigned operation : {0U, 1U}) {
            EnumRegistrationBusyContext context{module.handle, setter.name, setter.size, operation};
            registration_busy_context = &context;
            proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(registration_busy_callback);
            const std::string label = "busy." + std::string(setter.name) + '.' +
                std::to_string(setter.size) + '.' + std::to_string(operation);
            list(label);
            list(label + ".after");
            clear();
            registration_busy_context = nullptr;
        }
    }
    for (const char* name : {"UnlhaClearEnumMembersProc", "UnlhaClearEnumMembersProc64"}) {
        EnumRegistrationBusyContext context{module.handle, name, 0, 3};
        registration_busy_context = &context;
        proc<FnSetEnum>(module.handle, "UnlhaSetEnumMembersProcW")(registration_busy_callback);
        list(std::string("busy.") + name);
        list(std::string("busy.") + name + ".after");
        clear();
        registration_busy_context = nullptr;
    }
    return 0;
}

int run_enum_probe(const wchar_t* dll_path, const wchar_t* archive_path) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_a = proc<FnUnlhaA>(h, "Unlha");
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto set_a = proc<FnSetEnum>(h, "UnlhaSetEnumMembersProcA");
    const auto set_w = proc<FnSetEnum>(h, "UnlhaSetEnumMembersProcW");
    const auto set_64 = proc<FnSetEnum64>(h, "UnlhaSetEnumMembersProc64");
    const auto clear = proc<FnBool0>(h, "UnlhaClearEnumMembersProc");

    char archive_a[MAX_PATH * 4]{};
    if (!WideCharToMultiByte(932, WC_NO_BEST_FIT_CHARS, archive_path, -1, archive_a,
                             static_cast<int>(sizeof(archive_a)), nullptr, nullptr)) {
        throw std::runtime_error("archive path is not representable in CP932");
    }
    const std::string command_a = "l \"" + std::string(archive_a) + "\"";
    const std::wstring command_w = L"l " + quote_argument(archive_path);

    auto report = [&](const char* mode, EnumLayout layout, DWORD struct_size,
                      bool wide, bool legacy) {
        enum_layout = layout;
        enum_result = TRUE;
        enum_records.clear();
        const BOOL set_result = legacy ? (wide ? set_w(enum_probe) : set_a(enum_probe))
                                       : set_64(enum_probe, struct_size);
        int command_result = 0;
        if (wide) {
            wchar_t output[4096]{};
            command_result = unlha_w(nullptr, command_w.c_str(), output, _countof(output));
        } else {
            char output[4096]{};
            command_result = unlha_a(nullptr, command_a.c_str(), output, sizeof(output));
        }
        const BOOL clear_result = clear();
        std::cout << mode << ".set=" << set_result << '\n'
                  << mode << ".command_result=" << command_result << '\n'
                  << mode << ".clear=" << clear_result << '\n'
                  << mode << ".count=" << enum_records.size() << '\n';
        for (size_t index = 0; index < enum_records.size(); ++index) {
            std::cout << mode << ".entry" << index << '=' << enum_records[index] << '\n';
        }
    };

    report("a32", EnumLayout::A32, sizeof(UNLHA_ENUM_MEMBER_INFOA), false, true);
    report("w32", EnumLayout::W32, sizeof(UNLHA_ENUM_MEMBER_INFOW), true, true);
    report("a64", EnumLayout::A64, sizeof(UNLHA_ENUM_MEMBER_INFO64A), false, false);
    report("w64", EnumLayout::W64, sizeof(UNLHA_ENUM_MEMBER_INFO64W), true, false);
    enum_layout = EnumLayout::None;
    return 0;
}

int run_enum_effects(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto compress_mem = proc<FnCompressMemW>(h, "UnlhaCompressMemW");
    const auto extract_mem = proc<FnExtractMemW>(h, "UnlhaExtractMemW");
    const auto set_w = proc<FnSetEnum>(h, "UnlhaSetEnumMembersProcW");
    const auto clear = proc<FnBool0>(h, "UnlhaClearEnumMembersProc");

    const std::wstring root(workspace);
    const std::wstring rejected = root + L"\\rejected";
    const std::wstring renamed = root + L"\\renamed";
    const std::wstring source = root + L"\\source";
    const std::wstring archive = root + L"\\input.lzh";
    const std::wstring rewritten_archive = root + L"\\rewritten.lzh";
    ensure_directory(root);
    ensure_directory(rejected);
    ensure_directory(renamed);
    ensure_directory(source);

    std::vector<unsigned char> payload(4099);
    std::vector<unsigned char> alternate(3073);
    for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = static_cast<unsigned char>((index * 29U + 7U) & 0xffU);
    }
    for (size_t index = 0; index < alternate.size(); ++index) {
        alternate[index] = static_cast<unsigned char>((index * 17U + 91U) & 0xffU);
    }
    const std::wstring initial_command = quote_argument(archive) + L" " + quote_argument(L"payload.bin");
    DWORD compressed = 0;
    if (compress_mem(nullptr, initial_command.c_str(), payload.data(), static_cast<DWORD>(payload.size()),
                     nullptr, nullptr, &compressed) != 0 || compressed == 0) {
        throw std::runtime_error("enum effects: initial archive creation failed");
    }

    auto prepare_callback = [&](BOOL result, const std::wstring& file_name,
                                const std::wstring& add_name) {
        enum_layout = EnumLayout::W32;
        enum_result = result;
        enum_records.clear();
        enum_replacement_file_a.clear();
        enum_replacement_add_a.clear();
        enum_replacement_file_w = file_name;
        enum_replacement_add_w = add_name;
        if (!set_w(enum_probe)) throw std::runtime_error("enum effects: callback registration failed");
    };
    auto finish_callback = [&]() {
        if (!clear()) throw std::runtime_error("enum effects: callback clear failed");
        enum_replacement_file_w.clear();
        enum_replacement_add_w.clear();
    };

    wchar_t output[8192]{};
    prepare_callback(FALSE, L"", L"");
    const std::wstring list_command = L"l " + quote_argument(archive);
    const int list_result = unlha_w(nullptr, list_command.c_str(), output, _countof(output));
    const size_t list_callbacks = enum_records.size();
    finish_callback();
    if (list_result != 0 || list_callbacks != 1 || std::wcsstr(output, L"payload.bin") != nullptr) {
        throw std::runtime_error("enum effects: FALSE did not filter list command");
    }

    std::memset(output, 0, sizeof(output));
    prepare_callback(FALSE, L"", L"");
    const std::wstring rejected_command = L"x -y " + quote_argument(archive) + L" " +
                                           quote_argument(rejected + L"\\");
    const int rejected_result = unlha_w(nullptr, rejected_command.c_str(), output, _countof(output));
    const size_t rejected_callbacks = enum_records.size();
    finish_callback();
    if (rejected_result != 0 || rejected_callbacks != 1 ||
        GetFileAttributesW((rejected + L"\\payload.bin").c_str()) != INVALID_FILE_ATTRIBUTES) {
        throw std::runtime_error("enum effects: FALSE did not skip extraction");
    }

    std::memset(output, 0, sizeof(output));
    prepare_callback(FALSE, L"", L"");
    const std::wstring delete_command = L"d -y " + quote_argument(archive) + L" " +
                                         quote_argument(L"payload.bin");
    const int delete_result = unlha_w(nullptr, delete_command.c_str(), output, _countof(output));
    const size_t delete_callbacks = enum_records.size();
    finish_callback();
    std::vector<unsigned char> retained(payload.size());
    DWORD retained_size = 0;
    const int retained_result = extract_mem(nullptr, initial_command.c_str(), retained.data(),
                                            static_cast<DWORD>(retained.size()), nullptr, nullptr,
                                            &retained_size);
    if (delete_result != 0 || delete_callbacks != 1 || retained_result != 0 ||
        retained_size != payload.size() || retained != payload) {
        throw std::runtime_error("enum effects: FALSE did not prevent deletion");
    }

    const std::wstring renamed_file = renamed + L"\\selected.bin";
    std::memset(output, 0, sizeof(output));
    prepare_callback(TRUE, L"", renamed_file);
    const std::wstring renamed_command = L"x -y " + quote_argument(archive) + L" " +
                                          quote_argument(renamed + L"\\");
    const int renamed_result = unlha_w(nullptr, renamed_command.c_str(), output, _countof(output));
    const size_t renamed_callbacks = enum_records.size();
    finish_callback();
    if (renamed_result != 0 || renamed_callbacks != 1 || read_file(renamed_file) != payload ||
        GetFileAttributesW((renamed + L"\\payload.bin").c_str()) != INVALID_FILE_ATTRIBUTES) {
        throw std::runtime_error("enum effects: extraction destination rewrite failed");
    }

    const std::wstring placeholder_file = source + L"\\placeholder.bin";
    const std::wstring alternate_file = source + L"\\alternate.bin";
    write_file(placeholder_file, payload);
    write_file(alternate_file, alternate);

    const std::wstring blocked_archive = root + L"\\blocked.lzh";
    std::memset(output, 0, sizeof(output));
    prepare_callback(FALSE, L"", L"");
    const std::wstring blocked_command = L"a -y -jm2 " + quote_argument(blocked_archive) + L" " +
                                         quote_argument(source + L"\\") + L" " + quote_argument(L"placeholder.bin");
    const int blocked_result = unlha_w(nullptr, blocked_command.c_str(), output, _countof(output));
    const size_t blocked_callbacks = enum_records.size();
    finish_callback();
    std::vector<unsigned char> blocked_buffer(payload.size());
    DWORD blocked_size = 0;
    const std::wstring blocked_memory_command = quote_argument(blocked_archive) + L" " +
                                                quote_argument(L"placeholder.bin");
    const int blocked_extract_result = extract_mem(nullptr, blocked_memory_command.c_str(),
                                                    blocked_buffer.data(),
                                                    static_cast<DWORD>(blocked_buffer.size()),
                                                    nullptr, nullptr, &blocked_size);
    if (blocked_result != 0 || blocked_callbacks != 1 || blocked_extract_result == 0) {
        throw std::runtime_error("enum effects: FALSE did not prevent addition");
    }

    std::memset(output, 0, sizeof(output));
    prepare_callback(TRUE, L"callback.bin", alternate_file);
    const std::wstring add_command = L"a -y -jm2 " + quote_argument(rewritten_archive) + L" " +
                                     quote_argument(source + L"\\") + L" " + quote_argument(L"placeholder.bin");
    const int add_result = unlha_w(nullptr, add_command.c_str(), output, _countof(output));
    const size_t add_callbacks = enum_records.size();
    finish_callback();
    if (add_result != 0 || add_callbacks != 1) {
        throw std::runtime_error("enum effects: add callback failed");
    }

    std::vector<unsigned char> extracted(alternate.size());
    DWORD extracted_size = 0;
    const std::wstring memory_command = quote_argument(rewritten_archive) + L" " +
                                        quote_argument(L"callback.bin");
    const int memory_result = extract_mem(nullptr, memory_command.c_str(), extracted.data(),
                                          static_cast<DWORD>(extracted.size()), nullptr, nullptr,
                                          &extracted_size);
    if (memory_result != 0 || extracted_size != alternate.size() || extracted != alternate) {
        throw std::runtime_error("enum effects: add source/name rewrite failed");
    }

    enum_layout = EnumLayout::None;
    enum_result = TRUE;
    std::cout << "enum callback effects passed\n";
    return 0;
}

int run_special_command_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    HMODULE h = module.handle;
    const auto unlha_w = proc<FnUnlhaW>(h, "UnlhaW");
    const auto open_w = proc<FnOpenW>(h, "UnlhaOpenArchiveW");
    const auto close = proc<FnClose>(h, "UnlhaCloseArchive");
    const auto find_first_w = proc<FnFindFirstW>(h, "UnlhaFindFirstW");
    const auto find_next_w = proc<FnFindNextW>(h, "UnlhaFindNextW");
    const auto get_method = proc<FnGetString>(h, "UnlhaGetMethod");
    const auto get_last_error = proc<FnLastError>(h, "UnlhaGetLastError");
    const auto set_enum_w = proc<FnSetEnum>(h, "UnlhaSetEnumMembersProcW");
    const auto clear_enum = proc<FnBool0>(h, "UnlhaClearEnumMembersProc");

    const std::wstring root(workspace);
    const std::wstring source = root + L"\\source";
    const std::wstring base_archive = root + L"\\base.lzh";
    const std::wstring first_archive = root + L"\\first.lzh";
    const std::wstring second_archive = root + L"\\second.lzh";
    const std::wstring joined_archive = root + L"\\joined.lzh";
    const std::wstring converted_archive = root + L"\\converted.lzh";
    const std::wstring renamed_archive = root + L"\\renamed.lzh";
    const std::wstring direct_h1_archive = root + L"\\direct-h1.lzh";
    const std::wstring enum_join_archive = root + L"\\enum-joined.lzh";
    const std::wstring enum_join_rejected_archive = root + L"\\enum-join-rejected.lzh";
    const std::wstring enum_convert_archive = root + L"\\enum-converted.lzh";
    const std::wstring enum_convert_rejected_archive = root + L"\\enum-convert-rejected.lzh";
    const std::wstring enum_rename_archive = root + L"\\enum-renamed.lzh";
    const std::wstring enum_rename_rejected_archive = root + L"\\enum-rename-rejected.lzh";
    ensure_directory(root);
    ensure_directory(source);

    const std::wstring base_file = source + L"\\base.bin";
    const std::wstring first_file = source + L"\\first.bin";
    const std::wstring second_file = source + L"\\second.bin";
    write_file(base_file, {0x10, 0x20, 0x30});
    write_file(first_file, {0x41, 0x42, 0x43, 0x44});
    write_file(second_file, {0x51, 0x52, 0x53, 0x54, 0x55});
    set_file_times(base_file, 2024, 1, 2, 3, 4, 6);
    set_file_times(first_file, 2024, 2, 3, 4, 5, 8);
    set_file_times(second_file, 2024, 3, 4, 5, 6, 10);

    wchar_t output[8192]{};
    auto run = [&](const std::wstring& command) {
        std::memset(output, 0, sizeof(output));
        return unlha_w(nullptr, command.c_str(), output, _countof(output));
    };
    auto make_archive = [&](const std::wstring& archive, const std::wstring& member) {
        const std::wstring command = L"a -n1 -y -jm2 " + quote_argument(archive) + L" " +
                                     quote_argument(source + L"\\") + L" " + quote_argument(member);
        return run(command);
    };
    auto summarize = [&](const char* label, const std::wstring& archive) {
        const bool exists = GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES;
        std::cout << label << ".exists=" << exists << '\n';
        if (!exists) return;
        const std::vector<unsigned char> raw = read_file(archive);
        const unsigned int level = raw.size() > 20 ? static_cast<unsigned int>(raw[20]) : 999U;
        std::cout << label << ".first-level=" << level << '\n';
        size_t extension = raw.size();
        unsigned int os_type = 999U;
        if (level == 1 && raw.size() > 21) {
            const size_t name_length = raw[21];
            const size_t os_offset = 24 + name_length;
            if (os_offset < raw.size()) {
                os_type = raw[os_offset];
                extension = os_offset + 1;
            }
        } else if (level == 2 && raw.size() > 23) {
            os_type = raw[23];
            extension = 24;
        }
        std::cout << label << ".first-os=" << os_type << '\n';
        int common_flags = -1;
        while (extension + 2 <= raw.size()) {
            const size_t size = static_cast<size_t>(raw[extension]) |
                                (static_cast<size_t>(raw[extension + 1]) << 8U);
            if (size == 0 || size < 3 || extension + size > raw.size()) break;
            if (raw[extension + 2] == 0 && size >= 6) {
                common_flags = raw[extension + 5];
                break;
            }
            extension += size;
        }
        std::cout << label << ".first-common-flags=" << common_flags << '\n';
        HARC handle = open_w(nullptr, archive.c_str(), 0);
        std::cout << label << ".open=" << (handle != nullptr) << '\n';
        if (!handle) return;
        INDIVIDUALINFOW info{};
        int result = find_first_w(handle, L"*", &info);
        int index = 0;
        while (result == 0) {
            char method[32]{};
            get_method(handle, method, static_cast<int>(sizeof(method)));
            std::cout << label << ".entry" << index
                      << "=name=" << quote_wide(info.szFileName)
                      << ",original=" << info.dwOriginalSize
                      << ",packed=" << info.dwCompressedSize
                      << ",crc=" << info.dwCRC
                      << ",method=" << quote_bytes(method) << '\n';
            ++index;
            result = find_next_w(handle, &info);
        }
        std::cout << label << ".count=" << index << '\n';
        close(handle);
    };

    const std::wstring direct_h1_command = L"a -n1 -y -h1 " + quote_argument(direct_h1_archive) + L" " +
                                           quote_argument(source + L"\\") + L" " + quote_argument(L"first.bin");
    const int direct_h1_result = run(direct_h1_command);
    DWORD direct_h1_system_error = 0;
    const int direct_h1_last_error = get_last_error(&direct_h1_system_error);
    std::cout << "direct-h1.rc=" << direct_h1_result << '\n';
    std::cout << "direct-h1.last-error=" << direct_h1_last_error
              << ",system=" << direct_h1_system_error
              << ",output=" << quote_wide(output) << '\n';
    summarize("direct-h1", direct_h1_archive);

    std::cout << "setup.base.rc=" << make_archive(base_archive, L"base.bin") << '\n';
    std::cout << "setup.first.rc=" << make_archive(first_archive, L"first.bin") << '\n';
    std::cout << "setup.second.rc=" << make_archive(second_archive, L"second.bin") << '\n';

    if (!CopyFileW(base_archive.c_str(), joined_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare joined archive");
    }
    const std::wstring join_command = L"j -n1 -y " + quote_argument(joined_archive) + L" " +
                                      quote_argument(first_archive) + L" " + quote_argument(second_archive);
    std::cout << "join.rc=" << run(join_command) << '\n';
    summarize("join", joined_archive);

    if (!CopyFileW(first_archive.c_str(), converted_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare converted archive");
    }
    const std::wstring convert_command = L"y -n1 -y -h1 " + quote_argument(converted_archive);
    std::cout << "convert.rc=" << run(convert_command) << '\n';
    summarize("convert", converted_archive);

    if (!CopyFileW(first_archive.c_str(), renamed_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare renamed archive");
    }
    const std::wstring rename_command = L"n -n1 -y -grfolder/renamed.bin " +
                                        quote_argument(renamed_archive) + L" " + quote_argument(L"first.bin");
    std::cout << "rename.rc=" << run(rename_command) << '\n';
    summarize("rename", renamed_archive);

    auto run_with_enum = [&](const char* label, const BOOL callback_result,
                             const std::wstring& replacement,
                             const std::wstring& command,
                             const std::wstring& result_archive) {
        enum_layout = EnumLayout::W32;
        enum_result = callback_result;
        enum_records.clear();
        enum_replacement_file_a.clear();
        enum_replacement_add_a.clear();
        enum_replacement_file_w = replacement;
        enum_replacement_add_w.clear();
        if (!set_enum_w(enum_probe)) {
            throw std::runtime_error("special commands: callback registration failed");
        }
        const int result = run(command);
        const BOOL cleared = clear_enum();
        std::cout << label << ".rc=" << result << '\n';
        std::cout << label << ".clear=" << cleared << '\n';
        std::cout << label << ".callbacks=" << enum_records.size() << '\n';
        for (size_t index = 0; index < enum_records.size(); ++index) {
            std::cout << label << ".callback" << index << '=' << enum_records[index] << '\n';
        }
        summarize(label, result_archive);
        enum_layout = EnumLayout::None;
        enum_result = TRUE;
        enum_replacement_file_w.clear();
    };

    run_with_enum("enum-join", TRUE, L"callback/joined.bin",
                  L"j -n1 -y " + quote_argument(enum_join_archive) + L" " +
                      quote_argument(first_archive),
                  enum_join_archive);
    if (!CopyFileW(base_archive.c_str(), enum_join_rejected_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare rejected join archive");
    }
    run_with_enum("enum-join-rejected", FALSE, L"",
                  L"j -n1 -y " + quote_argument(enum_join_rejected_archive) + L" " +
                      quote_argument(first_archive),
                  enum_join_rejected_archive);

    if (!CopyFileW(first_archive.c_str(), enum_convert_archive.c_str(), FALSE) ||
        !CopyFileW(first_archive.c_str(), enum_convert_rejected_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare callback convert archives");
    }
    run_with_enum("enum-convert", TRUE, L"callback/converted.bin",
                  L"y -n1 -y -h1 " + quote_argument(enum_convert_archive),
                  enum_convert_archive);
    run_with_enum("enum-convert-rejected", FALSE, L"",
                  L"y -n1 -y -h1 " + quote_argument(enum_convert_rejected_archive),
                  enum_convert_rejected_archive);

    if (!CopyFileW(first_archive.c_str(), enum_rename_archive.c_str(), FALSE) ||
        !CopyFileW(first_archive.c_str(), enum_rename_rejected_archive.c_str(), FALSE)) {
        throw std::runtime_error("special commands: cannot prepare callback rename archives");
    }
    run_with_enum("enum-rename", TRUE, L"callback/renamed.bin",
                  L"n -n1 -y " + quote_argument(enum_rename_archive) + L" " +
                      quote_argument(L"first.bin"),
                  enum_rename_archive);
    run_with_enum("enum-rename-rejected", FALSE, L"",
                  L"n -n1 -y " + quote_argument(enum_rename_rejected_archive) + L" " +
                      quote_argument(L"first.bin"),
                  enum_rename_rejected_archive);
    return 0;
}

int run_special_transform_probe(const wchar_t* dll_path, const wchar_t* workspace) {
    Module module(dll_path);
    const auto unlha_w = proc<FnUnlhaW>(module.handle, "UnlhaW");
    const std::wstring root(workspace);
    const std::wstring base_archive = root + L"\\base.lzh";
    const std::wstring first_archive = root + L"\\first.lzh";
    const std::wstring second_archive = root + L"\\second.lzh";
    const std::wstring joined_archive = root + L"\\joined.lzh";
    const std::wstring converted_archive = root + L"\\converted.lzh";
    const std::wstring renamed_archive = root + L"\\renamed.lzh";
    for (const std::wstring* source : {&base_archive, &first_archive, &second_archive}) {
        if (GetFileAttributesW(source->c_str()) == INVALID_FILE_ATTRIBUTES) {
            throw std::runtime_error("special transform: input archive is missing");
        }
    }
    if (!CopyFileW(base_archive.c_str(), joined_archive.c_str(), FALSE) ||
        !CopyFileW(first_archive.c_str(), converted_archive.c_str(), FALSE) ||
        !CopyFileW(first_archive.c_str(), renamed_archive.c_str(), FALSE)) {
        throw std::runtime_error("special transform: cannot prepare outputs");
    }
    wchar_t output[8192]{};
    auto run = [&](const std::wstring& command) {
        std::memset(output, 0, sizeof(output));
        return unlha_w(nullptr, command.c_str(), output, _countof(output));
    };
    const int join_result = run(L"j -n1 -y " + quote_argument(joined_archive) + L" " +
                                quote_argument(first_archive) + L" " +
                                quote_argument(second_archive));
    const int convert_result = run(L"y -n1 -y -h1 " + quote_argument(converted_archive));
    const int rename_result = run(L"n -n1 -y -grfolder/renamed.bin " +
                                  quote_argument(renamed_archive) + L" " +
                                  quote_argument(L"first.bin"));
    std::cout << "join.rc=" << join_result << '\n';
    std::cout << "convert.rc=" << convert_result << '\n';
    std::cout << "rename.rc=" << rename_result << '\n';
    return join_result == 0 && convert_result == 0 && rename_result == 0 ? 0 : 1;
}

std::vector<std::string> snapshot(const wchar_t* dll_path, const char* archive_path,
                                  const wchar_t* archive_path_wide) {
    Module module(dll_path);
    HMODULE h = module.handle;
    std::vector<std::string> lines;
    auto add = [&](const std::string& key, auto value) {
        std::ostringstream out;
        out << key << '=' << value;
        lines.push_back(out.str());
    };

    add("version", proc<FnWord0>(h, "UnlhaGetVersion")());
    add("subversion", proc<FnWord0>(h, "UnlhaGetSubVersion")());
    add("running", proc<FnBool0>(h, "UnlhaGetRunning")());
    add("cursor_interval", proc<FnWord0>(h, "UnlhaGetCursorInterval")());
    add("background_mode", proc<FnBool0>(h, "UnlhaGetBackGroundMode")());
    add("cursor_mode", proc<FnBool0>(h, "UnlhaGetCursorMode")());
    add("code_page", proc<FnUInt0>(h, "UnlhaGetCP")());

    auto query = proc<FnIntInt>(h, "UnlhaQueryFunctionList");
    std::ostringstream supported;
    bool first = true;
    for (int id = 0; id <= 114; ++id) {
        if (query(id)) {
            if (!first) supported << ',';
            supported << id;
            first = false;
        }
    }
    add("query", supported.str());

    add("set_enum_a", proc<FnSetEnum>(h, "UnlhaSetEnumMembersProcA")(enum_probe));
    add("clear_enum_a", proc<FnBool0>(h, "UnlhaClearEnumMembersProc")());
    add("set_enum_64", proc<FnSetEnum64>(h, "UnlhaSetEnumMembersProc64")(
                           enum_probe, sizeof(UNLHA_ENUM_MEMBER_INFO64A)));
    add("clear_enum_64", proc<FnBool0>(h, "UnlhaClearEnumMembersProc64")());

    auto check = proc<FnCheck>(h, "UnlhaCheckArchive");
    add("check_rapid", check(archive_path, CHECKARCHIVE_RAPID));
    add("check_basic", check(archive_path, CHECKARCHIVE_BASIC));
    add("file_count", proc<FnCount>(h, "UnlhaGetFileCount")(archive_path));

    auto open = proc<FnOpen>(h, "UnlhaOpenArchive");
    auto close = proc<FnClose>(h, "UnlhaCloseArchive");
    HARC archive = open(nullptr, archive_path, 0);
    add("open", archive != nullptr);
    if (!archive) {
        return lines;
    }

    char text[1024]{};
    add("arc_name_rc", proc<FnGetString>(h, "UnlhaGetArcFileName")(archive, text, sizeof(text)));
    add("arc_name", quote_bytes(text));
    add("arc_file_size", proc<FnDwordHarc>(h, "UnlhaGetArcFileSize")(archive));
    ULHA_INT64 wide_size = -1;
    add("arc_file_size_ex_rc", proc<FnSizeEx>(h, "UnlhaGetArcFileSizeEx")(archive, &wide_size));
    add("arc_file_size_ex", wide_size);
    add("arc_os", proc<FnUIntHarc>(h, "UnlhaGetArcOSType")(archive));
    add("arc_is_sfx", proc<FnIntHarc>(h, "UnlhaIsSFXFile")(archive));

    auto find_first = proc<FnFindFirst>(h, "UnlhaFindFirst");
    auto find_next = proc<FnFindNext>(h, "UnlhaFindNext");
    INDIVIDUALINFOA info{};
    int find_result = find_first(archive, "*", &info);
    int count = 0;
    while (find_result == 0) {
        std::ostringstream prefix;
        prefix << "entry" << count;
        add(prefix.str() + ".name", quote_bytes(info.szFileName));
        add(prefix.str() + ".original", info.dwOriginalSize);
        add(prefix.str() + ".packed", info.dwCompressedSize);
        add(prefix.str() + ".crc", info.dwCRC);
        add(prefix.str() + ".os", info.uOSType);
        add(prefix.str() + ".ratio", info.wRatio);
        add(prefix.str() + ".date", info.wDate);
        add(prefix.str() + ".time", info.wTime);
        std::memset(text, 0, sizeof(text));
        add(prefix.str() + ".method_rc", proc<FnGetString>(h, "UnlhaGetMethod")(archive, text, sizeof(text)));
        add(prefix.str() + ".method", quote_bytes(text));
        add(prefix.str() + ".attr", proc<FnIntHarc>(h, "UnlhaGetAttribute")(archive));
        add(prefix.str() + ".attrs", proc<FnIntHarc>(h, "UnlhaGetAttributes")(archive));
        add(prefix.str() + ".size", proc<FnDwordHarc>(h, "UnlhaGetOriginalSize")(archive));
        add(prefix.str() + ".packed_size", proc<FnDwordHarc>(h, "UnlhaGetCompressedSize")(archive));
        add(prefix.str() + ".crc_api", proc<FnDwordHarc>(h, "UnlhaGetCRC")(archive));
        add(prefix.str() + ".os_api", proc<FnUIntHarc>(h, "UnlhaGetOSType")(archive));

        add(prefix.str() + ".write_time", proc<FnDwordHarc>(h, "UnlhaGetWriteTime")(archive));
        add(prefix.str() + ".create_time", proc<FnDwordHarc>(h, "UnlhaGetCreateTime")(archive));
        add(prefix.str() + ".access_time", proc<FnDwordHarc>(h, "UnlhaGetAccessTime")(archive));

        FILETIME write_time{};
        FILETIME create_time{};
        FILETIME access_time{};
        add(prefix.str() + ".write_time_ex_rc",
            proc<FnFileTime>(h, "UnlhaGetWriteTimeEx")(archive, &write_time));
        add(prefix.str() + ".write_time_ex", filetime_value(write_time));
        add(prefix.str() + ".create_time_ex_rc",
            proc<FnFileTime>(h, "UnlhaGetCreateTimeEx")(archive, &create_time));
        add(prefix.str() + ".create_time_ex", filetime_value(create_time));
        add(prefix.str() + ".access_time_ex_rc",
            proc<FnFileTime>(h, "UnlhaGetAccessTimeEx")(archive, &access_time));
        add(prefix.str() + ".access_time_ex", filetime_value(access_time));

        ULHA_INT64 write_time64 = 0;
        ULHA_INT64 create_time64 = 0;
        ULHA_INT64 access_time64 = 0;
        add(prefix.str() + ".write_time64_rc",
            proc<FnTime64>(h, "UnlhaGetWriteTime64")(archive, &write_time64));
        add(prefix.str() + ".write_time64", write_time64);
        add(prefix.str() + ".create_time64_rc",
            proc<FnTime64>(h, "UnlhaGetCreateTime64")(archive, &create_time64));
        add(prefix.str() + ".create_time64", create_time64);
        add(prefix.str() + ".access_time64_rc",
            proc<FnTime64>(h, "UnlhaGetAccessTime64")(archive, &access_time64));
        add(prefix.str() + ".access_time64", access_time64);
        ++count;
        find_result = find_next(archive, &info);
    }
    add("entry_count", count);
    add("find_end", find_result);
    add("arc_original", proc<FnDwordHarc>(h, "UnlhaGetArcOriginalSize")(archive));
    add("arc_packed", proc<FnDwordHarc>(h, "UnlhaGetArcCompressedSize")(archive));
    add("arc_ratio", proc<FnWordHarc>(h, "UnlhaGetArcRatio")(archive));
    add("close", close(archive));
    DWORD system_error = 0;
    add("last_error", proc<FnLastError>(h, "UnlhaGetLastError")(&system_error));

    HARC wide_archive = proc<FnOpenW>(h, "UnlhaOpenArchiveW")(nullptr, archive_path_wide, 0);
    add("wide_open", wide_archive != nullptr);
    if (wide_archive) {
        INDIVIDUALINFOW wide_info{};
        const int wide_find = proc<FnFindFirstW>(h, "UnlhaFindFirstW")(wide_archive, L"*", &wide_info);
        add("wide_find", wide_find);
        if (wide_find == 0) add("wide_name", quote_wide(wide_info.szFileName));
        add("wide_close", close(wide_archive));
    }

    const UINT original_code_page = proc<FnUInt0>(h, "UnlhaGetCP")();
    add("set_cp_utf8", proc<FnBoolUInt>(h, "UnlhaSetCP")(CP_UTF8));
    HARC utf8_archive = proc<FnOpenW>(h, "UnlhaOpenArchiveW")(nullptr, archive_path_wide, 0);
    add("utf8_open", utf8_archive != nullptr);
    if (utf8_archive) {
        INDIVIDUALINFOW utf8_info{};
        const int utf8_find = proc<FnFindFirstW>(h, "UnlhaFindFirstW")(utf8_archive, L"*", &utf8_info);
        add("utf8_find", utf8_find);
        if (utf8_find == 0) add("utf8_name", quote_wide(utf8_info.szFileName));
        add("utf8_close", close(utf8_archive));
    }
    add("restore_cp", proc<FnBoolUInt>(h, "UnlhaSetCP")(original_code_page));
    return lines;
}

void print_snapshot(const std::vector<std::string>& values) {
    for (const auto& value : values) {
        std::cout << value << '\n';
    }
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    try {
        if (!isolated_desktop::is_isolated()) return isolated_desktop::relaunch(argc, argv);
        std::unique_ptr<RegistrySandbox> registry;
        const bool explicit_registry = argc >= 4 && (std::wcscmp(argv[1], L"--registry") == 0 ||
                                                     std::wcscmp(argv[1], L"--registry-dump") == 0);
        if (explicit_registry) {
            registry.reset(new RegistrySandbox(argv[2], std::wcscmp(argv[1], L"--registry-dump") == 0));
            argc -= 2;
            argv += 2;
        } else {
            // 旧形式の呼び出しも利用者の設定から分離し、明示した seed だけを比較へ反映する。
            registry.reset(new RegistrySandbox(L""));
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--integration") == 0) {
            return run_integration(argv[2], argv[3]);
        }
        if (argc >= 6 && argc <= 8 && std::wcscmp(argv[1], L"--create-dictionary-fixture") == 0) {
            return create_dictionary_fixture(argv[2], argv[3], argv[4], std::stoul(argv[5]),
                                              argc >= 7 ? argv[6] : L"W", argc == 8 ? argv[7] : L"payload.bin");
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--verify-dictionary-fixture") == 0) {
            return verify_dictionary_fixture(argv[2], argv[3], argc == 5 ? argv[4] : L"payload.bin");
        }
        if ((argc == 5 || argc == 6) && std::wcscmp(argv[1], L"--legacy-payload-probe") == 0) {
            if (argc == 6 && std::wcscmp(argv[5], L"quiet") != 0)
                throw std::runtime_error("legacy payload: optional mode must be quiet");
            return run_legacy_payload_probe(argv[2], argv[3], argv[4], argc == 6);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--dictionary-state") == 0) {
            return run_dictionary_state(argv[2], argv[3]);
        }
        if ((argc == 4 || (argc == 5 && std::wcscmp(argv[4], L"fixed") == 0)) &&
            std::wcscmp(argv[1], L"--create-unicode-fixture") == 0) {
            return create_unicode_fixture(argv[2], argv[3], argc == 5);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--dos-time-probe") == 0) {
            return run_dos_time_probe(argv[2], argv[3]);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--find-state-probe") == 0) {
            return run_find_state_probe(argv[2], argv[3], argc == 5 ? argv[4] : nullptr);
        }
        if (argc >= 5 && argc <= 7 && std::wcscmp(argv[1], L"--archive-path-probe") == 0) {
            return run_archive_path_probe(argv[2], argv[3], argv[4], argc >= 6 ? argv[5] : L"ansi",
                                          argc == 7 ? std::stoi(argv[6]) : -1);
        }
        if ((argc == 4 || argc == 5) && (std::wcscmp(argv[1], L"--getter-buffer-probe") == 0 ||
                                       std::wcscmp(argv[1], L"--getter-zero-safety") == 0)) {
            return run_getter_buffer_probe(argv[2], argv[3], argc == 5 ? argv[4] : L"ansi",
                                            std::wcscmp(argv[1], L"--getter-zero-safety") == 0);
        }
        if ((argc == 7 || argc == 8) && std::wcscmp(argv[1], L"--open-state-probe") == 0) {
            return run_open_state_probe(argv[2], argv[3], argv[4], std::stoi(argv[5]), argv[6], argc == 8);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--create-open-size-fixtures") == 0) {
            return create_open_size_fixtures(argv[2], argv[3]);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--archive-tail-probe") == 0) {
            if (argc == 5 && std::wcscmp(argv[4], L"quiet") != 0)
                throw std::runtime_error("archive tail: optional mode must be quiet");
            return run_archive_tail_probe(argv[2], argv[3], argc == 5);
        }
        if ((argc == 4 || argc == 6 || argc == 7 || argc == 8) && std::wcscmp(argv[1], L"--memory-progress-dialog-probe") == 0) {
            wchar_t* capacity_end = nullptr;
            const unsigned long long capacity = argc >= 6 ? std::wcstoull(argv[5], &capacity_end, 10) : 64;
            MemoryProgressDialogProbeAction action = MemoryProgressDialogProbeAction::Observe;
            if (argc >= 7) {
                if (std::wcscmp(argv[6], L"observe") == 0) action = MemoryProgressDialogProbeAction::Observe;
                else if (std::wcscmp(argv[6], L"complete") == 0) action = MemoryProgressDialogProbeAction::Complete;
                else if (std::wcscmp(argv[6], L"cancel") == 0) action = MemoryProgressDialogProbeAction::Cancel;
                else if (std::wcscmp(argv[6], L"quit") == 0) action = MemoryProgressDialogProbeAction::Quit;
                else throw std::runtime_error("memory progress dialog action is invalid");
            }
            if (argc >= 6 && (!capacity_end || *capacity_end || capacity == 0 ||
                              capacity > kMemoryProgressDialogProbeMaximumCapacity))
                throw std::runtime_error("memory progress dialog capacity is invalid");
            LANGID language = 0xffff;
            if (argc == 8) {
                wchar_t* language_end = nullptr;
                const unsigned long requested = std::wcstoul(argv[7], &language_end, 10);
                if (!language_end || *language_end || (requested != 0 && requested != 1033 && requested != 1041))
                    throw std::runtime_error("memory progress dialog language is invalid");
                language = static_cast<LANGID>(requested);
            }
            return run_memory_progress_dialog_probe(argv[2], argv[3], argc >= 6 ? argv[4] : L"-gm1",
                                                    static_cast<DWORD>(capacity), action, language);
        }
        if (argc >= 4 && argc <= 6 && std::wcscmp(argv[1], L"--find-pattern-probe") == 0) {
            const bool components = argc == 6 && std::wcscmp(argv[5], L"components") == 0;
            const bool defined = argc == 6 && std::wcscmp(argv[5], L"defined") == 0;
            return run_find_pattern_probe(argv[2], argv[3], argc >= 5 && std::wcscmp(argv[4], L"utf8") == 0,
                                          argc == 6 && !components && !defined ? std::stoi(argv[5]) : -1,
                                          components, defined);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--create-find-unicode-fixture") == 0) {
            return create_find_pattern_fixture(argv[2], argv[3], false, argc == 5 ? std::stoi(argv[4]) : -1);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--create-find-tree-fixture") == 0) {
            return create_find_pattern_fixture(argv[2], argv[3], true);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--original-find-internals") == 0) {
            return run_original_find_internals(argv[2], argv[3], argv[4]);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--code-page-probe") == 0) {
            return run_code_page_probe(argv[2], argv[3], argv[4]);
        }
        if (argc == 4 && (std::wcscmp(argv[1], L"--attribute-probe") == 0 ||
                          std::wcscmp(argv[1], L"--attribute-probe-audit") == 0)) {
            return run_attribute_probe(argv[2], argv[3], std::wcscmp(argv[1], L"--attribute-probe-audit") == 0);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--timestamp-range-probe") == 0) {
            return run_timestamp_range_probe(argv[2], argv[3], argv[4]);
        }
        if (argc == 7 && std::wcscmp(argv[1], L"--memory-selection-case-probe") == 0) {
            return run_memory_selection_case_probe(argv[2], argv[3], argv[4],
                static_cast<unsigned>(std::stoul(argv[5])), static_cast<DWORD>(std::stoul(argv[6])));
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--memory-selection-probe") == 0) {
            return run_memory_selection_probe(argv[2], argv[3], argc == 5 ? argv[4] : L"none");
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--create-memory-selection-fixture") == 0) {
            return create_memory_selection_fixture(argv[2], argv[3], argc == 5);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--memory-state-probe") == 0) {
            return run_memory_state_probe(argv[2], argv[3]);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--memory-failure-probe") == 0) {
            return run_memory_failure_probe(argv[2], argv[3], argv[4]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--create-memory-damage-fixtures") == 0) {
            return create_memory_damage_fixtures(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--memory-failure-stress") == 0) {
            return run_memory_failure_stress(argv[2], argv[3]);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--check-decoder-failure-probe") == 0) {
            return run_check_decoder_failure_probe(argv[2], argv[3], argv[4]);
        }
        if (argc >= 5 && argc <= 7 && std::wcscmp(argv[1], L"--memory-workflow-probe") == 0) {
            return run_memory_workflow_probe(argv[2], argv[3], argv[4], argc >= 6, argc == 7 ? argv[6] : nullptr);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--unicode-memory-probe") == 0) {
            return run_unicode_memory_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--unicode-command-probe") == 0) {
            return run_unicode_command_probe(argv[2], argv[3]);
        }
        if ((argc == 5 || argc == 6) && std::wcscmp(argv[1], L"--utf8-path-probe") == 0) {
            return run_utf8_path_probe(argv[2], argv[3], argv[4], argc != 6);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--sfx-probe") == 0) {
            return run_sfx_probe(argv[2], argv[3], argc == 5 ? argv[4] : nullptr);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--check-archive-probe") == 0) {
            return run_check_archive_probe(argv[2], argv[3]);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--check-existing-archive-probe") == 0) {
            return run_check_existing_archive_probe(argv[2], argv[3], argc == 5,
                argc == 5 ? std::stoi(argv[4]) : 0);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--create-check-boundary-fixtures") == 0) {
            return create_check_boundary_fixtures(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--check-argument-probe") == 0) {
            return run_check_argument_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--check-busy-probe") == 0) {
            return run_check_busy_probe(argv[2], argv[3]);
        }
        if (argc == 6 && std::wcscmp(argv[1], L"--config-dialog-probe") == 0) {
            return run_config_dialog_probe(argv[2], argv[3], argv[4], argv[5]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--registry-lifecycle-probe") == 0) {
            if (!explicit_registry) throw std::runtime_error("registry lifecycle probe requires --registry");
            return run_registry_lifecycle_probe(argv[2], argv[3], *registry);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--registry-overwrite-probe") == 0) {
            if (!explicit_registry) throw std::runtime_error("registry overwrite probe requires --registry");
            return run_overwrite_policy_probe(argv[2], argv[3], true);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--registry-find-probe") == 0) {
            if (!explicit_registry) throw std::runtime_error("registry find probe requires --registry");
            return run_find_pattern_probe(argv[2], argv[3], false, -1, false, true, true);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--command-sequence-probe") == 0) {
            return run_command_sequence_probe(argv[2], argv[3], argv[4]);
        }
        if (argc == 7 && std::wcscmp(argv[1], L"--registry-path-sequence-probe") == 0) {
            if (!explicit_registry) throw std::runtime_error("registry path sequence requires --registry");
            return run_registry_path_sequence_probe(argv[2], argv[3], argv[4], argv[5], argv[6]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--command-probe") == 0) {
            return run_command_probe(argv[2], argv[3]);
        }
        if ((argc == 7 || argc == 9) && std::wcscmp(argv[1], L"--base-command-probe") == 0) {
            wchar_t before[32768]{}, after[32768]{};
            if (!GetCurrentDirectoryW(_countof(before), before))
                throw std::runtime_error("cannot capture initial working directory");
            const int result = run_command_enum_probe(argv[2], argv[3], argc == 9 ? argv[7] : L"none", TRUE, L"",
                std::wcstoul(argv[4], nullptr, 10), std::wcstol(argv[5], nullptr, 10) != 0, argv[6],
                argc == 9 && std::wcstol(argv[8], nullptr, 10) != 0);
            if (!GetCurrentDirectoryW(_countof(after), after))
                throw std::runtime_error("cannot capture final working directory");
            const bool restored = std::wcscmp(before, after) == 0;
            std::cout << "directory-preserved=" << restored << '\n';
            if (!restored) throw std::runtime_error("command changed the caller's working directory");
            return result;
        }
        if (argc >= 8 && std::wcscmp(argv[1], L"--enum-sequence-probe") == 0) {
            return run_enum_sequence_probe(argv[2], argv[3], std::wcstoul(argv[4], nullptr, 10),
                std::wcstol(argv[5], nullptr, 10) != 0, argv[6], argc - 7, argv + 7);
        }
        if (argc >= 9 && std::wcscmp(argv[1], L"--progress-sequence-probe") == 0) {
            return run_enum_sequence_probe(argv[2], argv[3], std::wcstoul(argv[4], nullptr, 10),
                std::wcstol(argv[5], nullptr, 10) != 0, argv[6], argc - 8, argv + 8, argv[7]);
        }
        if (argc >= 6 && argc <= 12 && std::wcscmp(argv[1], L"--command-enum-probe") == 0) {
            return run_command_enum_probe(argv[2], argv[3], argv[4], std::wcstol(argv[5], nullptr, 10) != 0,
                                          argc >= 7 ? argv[6] : nullptr,
                                          argc >= 8 ? std::wcstoul(argv[7], nullptr, 10) : 0,
                                          argc >= 9 && std::wcstol(argv[8], nullptr, 10) != 0,
                                          argc >= 10 && *argv[9] ? argv[9] : nullptr,
                                          argc >= 11 && std::wcstol(argv[10], nullptr, 10) != 0,
                                          argc == 12 ? std::wcstol(argv[11], nullptr, 10) : -1);
        }
        if (argc == 6 && std::wcscmp(argv[1], L"--overwrite-race-probe") == 0) {
            return run_overwrite_race_probe(argv[2], argv[3], argv[4], argv[5]);
        }
        if (argc == 12 && std::wcscmp(argv[1], L"--create-failure-probe") == 0) {
            return run_create_failure_probe(argv[2], argv[3], argv[4], argv[5],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[8], nullptr, 10),
                static_cast<LANGID>(std::wcstoul(argv[9], nullptr, 10)), argv[10], std::wcstoul(argv[11], nullptr, 10));
        }
        if (argc >= 12 && std::wcscmp(argv[1], L"--create-failure-sequence-probe") == 0) {
            return run_create_failure_probe(argv[2], nullptr, argv[3], argv[4],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[5], nullptr, 10),
                0xffff, argv[9], std::wcstoul(argv[10], nullptr, 10), argc - 11, argv + 11, argv[8]);
        }
        if (argc == 11 && std::wcscmp(argv[1], L"--disk-space-dialog-probe") == 0) {
            return run_disk_space_dialog_probe(argv[2], argv[3], argv[4], argv[5],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[8], nullptr, 10),
                static_cast<LANGID>(std::wcstoul(argv[9], nullptr, 10)), argv[10]);
        }
        if (argc >= 11 && std::wcscmp(argv[1], L"--disk-space-sequence-probe") == 0) {
            return run_disk_space_dialog_probe(argv[2], nullptr, argv[3], argv[4],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[5], nullptr, 10),
                0xffff, argv[9], argc - 10, argv + 10, argv[8]);
        }
        if (argc == 11 && std::wcscmp(argv[1], L"--filename-dialog-probe") == 0) {
            return run_filename_dialog_probe(argv[2], argv[3], argv[4], argv[5],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[8], nullptr, 10),
                static_cast<LANGID>(std::wcstoul(argv[9], nullptr, 10)), argv[10]);
        }
        if (argc >= 11 && std::wcscmp(argv[1], L"--filename-sequence-probe") == 0) {
            return run_filename_dialog_probe(argv[2], nullptr, argv[3], argv[4],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[5], nullptr, 10),
                0xffff, argv[9], argc - 10, argv + 10, argv[8]);
        }
        if (argc >= 8 && argc <= 11 && std::wcscmp(argv[1], L"--command-dialog-probe") == 0) {
            return run_command_dialog_probe(argv[2], argv[3], argv[4], argv[5],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7],
                argc >= 9 ? std::wcstoul(argv[8], nullptr, 10) : 1041,
                argc >= 10 ? static_cast<LANGID>(std::wcstoul(argv[9], nullptr, 10)) : 0xffff,
                argc == 11 ? argv[10] : nullptr);
        }
        if (argc >= 10 && std::wcscmp(argv[1], L"--sequence-dialog-probe") == 0) {
            return run_command_dialog_probe(argv[2], nullptr, argv[3], argv[4],
                std::wcstol(argv[6], nullptr, 10) != 0, argv[7], std::wcstoul(argv[5], nullptr, 10),
                0xffff, nullptr, argc - 9, argv + 9, argv[8]);
        }
        if (argc >= 5 && argc <= 7 && std::wcscmp(argv[1], L"--command-raw-probe") == 0) {
            return run_command_raw_probe(argv[2], argv[3], argv[4], argc >= 6 ? std::stoul(argv[5]) : 64, argc == 7);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--command-probe-a") == 0) {
            return run_command_probe_a(argv[2], argv[3], argc == 5 && std::wcscmp(argv[4], L"A") == 0 ? "UnlhaA" : "Unlha");
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--command-probe-a-summary") == 0) {
            return run_command_probe_a_summary(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--action-output-probe") == 0) {
            return run_action_output_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--match-options-probe") == 0) {
            return run_match_options_probe(argv[2], argv[3]);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--update-policy-probe") == 0) {
            return run_update_policy_probe(argv[2], argv[3], argc == 5 ? argv[4] : L"exaufm");
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--overwrite-policy-probe") == 0) {
            return run_overwrite_policy_probe(argv[2], argv[3]);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--comment-probe") == 0) {
            return run_comment_probe(argv[2], argv[3], argc == 5 ? argv[4] : nullptr);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--method-switch-probe") == 0) {
            return run_method_switch_probe(argv[2], argv[3], argc == 5 ? argv[4] : nullptr);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--response-probe") == 0) {
            return run_response_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--enum-probe") == 0) {
            return run_enum_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--enum-registration-probe") == 0) {
            return run_enum_registration_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--enum-registration-busy-probe") == 0) {
            return run_enum_registration_probe(argv[2], argv[3], true);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--enum-effects") == 0) {
            return run_enum_effects(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--fresh-effects") == 0) {
            return run_fresh_effects(argv[2], argv[3]);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--progress-probe") == 0) {
            return run_progress_probe(argv[2], argv[3], argv[4], false);
        }
        if (argc == 5 && std::wcscmp(argv[1], L"--progress-abort-probe") == 0) {
            return run_progress_probe(argv[2], argv[3], argv[4], true);
        }
        if ((argc == 4 || argc == 5) && std::wcscmp(argv[1], L"--progress-add-probe") == 0) {
            return run_progress_add_probe(argv[2], argv[3], argc == 5 ? std::stoi(argv[4]) : 1);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--special-command-probe") == 0) {
            return run_special_command_probe(argv[2], argv[3]);
        }
        if (argc == 4 && std::wcscmp(argv[1], L"--special-transform-probe") == 0) {
            return run_special_transform_probe(argv[2], argv[3]);
        }
        if (argc != 3 && argc != 4) {
            std::cerr << "usage: CompatibilityTests <candidate.dll> <archive> [oracle.dll]\n"
                         "       CompatibilityTests --registry[-dump] <C:name=value;L:name=value> <probe> ...\n"
                         "       All probes use temporary HKCU settings; omitted --registry means an empty seed.\n"
                         "       CompatibilityTests --registry-lifecycle-probe <dll> <archive>\n"
                         "       CompatibilityTests --registry-overwrite-probe <dll> <workspace>\n"
                         "       CompatibilityTests --registry-find-probe <dll> <archive>\n"
                         "       CompatibilityTests --registry-path-sequence-probe <dll> <archive> <initial-operations> <second-command> <A|W>\n"
                         "       CompatibilityTests --command-sequence-probe <dll> <first-command> <second-command>\n"
                         "       CompatibilityTests --command-enum-probe <dll> <command> <a32|w32|a64|w64|none> <selected> [replacement|@file:member] [locale] [unicode-mode] [api] [progress] [abort-state]\n"
                         "       CompatibilityTests --integration <candidate.dll> <workspace>\n"
                         "       CompatibilityTests --create-dictionary-fixture <dll> <workspace> <switches> <block-size> [W|A|memoryW|memoryA] [member]\n"
                         "       CompatibilityTests --verify-dictionary-fixture <dll> <workspace> [member]\n"
                         "       CompatibilityTests --utf8-path-probe <dll> <workspace> <W|A|legacy> [defaults]\n"
                         "       CompatibilityTests --command-dialog-probe <dll> <command> <buttons|inspect> <layout> <unicode-mode> <W|A|legacy> [locale [language [audit-archive]]]\n"
                         "         buttons: comma-separated button IDs or radio:button pairs\n"
                         "         inspect-layout: inspect dialog geometry without responding\n"
                         "         inspect-layout:hidden|visible|child|offscreen: inspect with a test owner window\n"
                         "         sequence @initial-language:0|1033|1041 sets language before callback registration\n"
                         "       CompatibilityTests --overwrite-race-probe <dll> <archive> <expected-payload> <workspace>\n"
                         "       CompatibilityTests --filename-dialog-probe <dll> <command> <buttons> <layout> <unicode-mode> <api> <locale> <language> <paths|cancel>\n"
                         "       CompatibilityTests --filename-sequence-probe <dll> <buttons> <layout> <locale> <unicode-mode> <api> <progress-layout> <paths|cancel> <steps...>\n"
                         "       CompatibilityTests --sequence-dialog-probe <dll> <buttons|inspect> <layout> <locale> <unicode-mode> <api> <progress-layout> <steps...>\n"
                         "       CompatibilityTests --command-raw-probe <dll> <command> <W|A|legacy> [capacity] [utf8]\n"
                         "       CompatibilityTests --attribute-probe <dll> <archive>\n"
                         "       CompatibilityTests --attribute-probe-audit <dll> <archive>\n"
                         "       CompatibilityTests --dictionary-state <dll> <workspace>\n"
                         "       CompatibilityTests --create-unicode-fixture <dll> <archive> [fixed]\n"
                         "       CompatibilityTests --dos-time-probe <dll> <workspace>\n"
                         "       CompatibilityTests --find-state-probe <dll> <workspace> [archive]\n"
                         "       CompatibilityTests --archive-path-probe <dll> <archive> <after-open-directory> [ansi|ansi-ja|utf8|cp932-input] [api]\n"
                         "       CompatibilityTests --getter-buffer-probe <dll> <archive> [ansi|ansi-ja|utf8]\n"
                         "       CompatibilityTests --getter-zero-safety <candidate-dll> <archive> [ansi|ansi-ja|utf8]\n"
                         "       CompatibilityTests --open-state-probe <dll> <valid-archive> <initial-path|@null|@empty|@valid> <api> <action> [owner]\n"
                         "       CompatibilityTests --create-open-size-fixtures <empty-archive> <workspace>\n"
                         "       CompatibilityTests --archive-tail-probe <dll> <archive> [quiet]\n"
                         "       CompatibilityTests --memory-progress-dialog-probe <dll> <archive> [switches capacity [observe|complete|cancel|quit [language]]]\n"
                         "       CompatibilityTests --unicode-memory-probe <dll> <workspace>\n"
                         "       CompatibilityTests --unicode-command-probe <dll> <workspace>\n"
                         "       CompatibilityTests --sfx-probe <dll> <workspace> [dos|win|winm]\n"
                         "       CompatibilityTests --check-archive-probe <dll> <workspace>\n"
                         "       CompatibilityTests --check-existing-archive-probe <dll> <archive> [mode]\n"
                         "       CompatibilityTests --legacy-payload-probe <dll> <archive> <expected-payload> [quiet]\n"
                         "       CompatibilityTests --create-check-boundary-fixtures <valid-archive> <workspace>\n"
                         "       CompatibilityTests --check-argument-probe <dll> <archive>\n"
                         "       CompatibilityTests --check-busy-probe <dll> <archive>\n"
                         "       CompatibilityTests --check-decoder-failure-probe <dll> <damaged-archive> <valid-archive>\n"
                         "       CompatibilityTests --create-memory-damage-fixtures <level-2-archive> <workspace>\n"
                         "       CompatibilityTests --memory-failure-probe <dll> <damaged-archive> <valid-archive>\n"
                         "       CompatibilityTests --memory-selection-case-probe <dll> <archive> <none|w64|reject|rename> <pattern-index> <capacity>\n"
                         "       CompatibilityTests --memory-failure-stress <dll> <damaged-huffman-archive>\n"
                         "       CompatibilityTests --config-dialog-probe <dll> <mode> <cancel|ok|expand|main:ids|local:ids|local-save:ids> <a|w|anull|wnull>\n"
                         "       CompatibilityTests --command-probe <dll> <wide-command-line>\n"
                         "       CompatibilityTests --base-command-probe <dll> <command> <locale> <unicode-mode> <legacy|A|W> [none|a32|w32|a64|w64 progress]\n"
                         "       CompatibilityTests --command-probe-a <dll> <ansi-command-line> [A]\n"
                         "       CompatibilityTests --command-probe-a-summary <dll> <ansi-command-line>\n"
                         "       CompatibilityTests --enum-probe <dll> <archive>\n"
                         "       CompatibilityTests --enum-registration-probe <dll> <archive>\n"
                         "       CompatibilityTests --enum-registration-busy-probe <dll> <archive>\n"
                         "       CompatibilityTests --enum-effects <dll> <workspace>\n"
                         "       CompatibilityTests --enum-sequence-probe <dll> <a32|w32|a64|w64> <locale> <utf8> <legacy|A|W> <steps...>\n"
                         "       CompatibilityTests --progress-sequence-probe <dll> <none|a32|w32|a64|w64> <locale> <utf8> <legacy|A|W> <a32|w32|a64|w64|total> <steps...>\n"
                         "       CompatibilityTests --fresh-effects <dll> <workspace>\n"
                         "       CompatibilityTests --progress-probe <dll> <archive> <workspace>\n"
                         "       CompatibilityTests --progress-abort-probe <dll> <archive> <workspace>\n"
                         "       CompatibilityTests --progress-add-probe <dll> <workspace> [name-mode]\n"
                         "       CompatibilityTests --special-command-probe <dll> <workspace>\n"
                         "       CompatibilityTests --special-transform-probe <dll> <workspace>\n";
            return 2;
        }
        char archive_path[MAX_PATH * 4]{};
        if (!WideCharToMultiByte(932, WC_NO_BEST_FIT_CHARS, argv[2], -1, archive_path,
                                 static_cast<int>(sizeof(archive_path)), nullptr, nullptr)) {
            throw std::runtime_error("archive path is not representable in CP932");
        }
        const auto candidate = snapshot(argv[1], archive_path, argv[2]);
        if (argc == 3) {
            print_snapshot(candidate);
            return 0;
        }
        const auto oracle = snapshot(argv[3], archive_path, argv[2]);
        if (candidate == oracle) {
            std::cout << "compatible snapshot\n";
            return 0;
        }
        const size_t count = (std::max)(candidate.size(), oracle.size());
        for (size_t i = 0; i < count; ++i) {
            const std::string left = i < oracle.size() ? oracle[i] : "<missing>";
            const std::string right = i < candidate.size() ? candidate[i] : "<missing>";
            if (left != right) {
                std::cout << "oracle:    " << left << '\n';
                std::cout << "candidate: " << right << '\n';
            }
        }
        return 1;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 2;
    }
}
