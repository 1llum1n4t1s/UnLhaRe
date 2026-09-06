#pragma once
#include <windows.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#pragma comment(lib, "user32.lib")

// 検証のウィンドウを作業用デスクトップから分離する。製品 DLL の表示動作は変えない。
namespace isolated_desktop {
struct Handle {
    HANDLE value;
    explicit Handle(HANDLE raw = nullptr) : value(raw) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};
inline std::runtime_error failure(const char* operation) {
    return std::runtime_error(std::string(operation) + ": " + std::to_string(GetLastError()));
}
inline std::wstring object_name(HANDLE object) {
    DWORD bytes = 0;
    GetUserObjectInformationW(object, UOI_NAME, nullptr, 0, &bytes);
    if (!bytes) throw failure("GetUserObjectInformationW size");
    std::vector<wchar_t> name(bytes / sizeof(wchar_t) + 1, 0);
    if (!GetUserObjectInformationW(object, UOI_NAME, name.data(), bytes, &bytes))
        throw failure("GetUserObjectInformationW");
    return name.data();
}
inline bool is_isolated() {
    return object_name(GetThreadDesktop(GetCurrentThreadId())).find(L"UnLhaReTest-") == 0;
}
inline std::wstring executable_path() {
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) throw failure("GetModuleFileNameW");
    return std::wstring(path.data(), length);
}
inline std::wstring quote(const std::wstring& value) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (const wchar_t unit : value) {
        if (unit == L'\\') { ++slashes; continue; }
        result.append(slashes * (unit == L'\"' ? 2 : 1), L'\\');
        slashes = 0;
        if (unit == L'\"') result += L'\\';
        result += unit;
    }
    result.append(slashes * 2, L'\\');
    result += L'\"';
    return result;
}
inline HANDLE inherited_stream(DWORD kind) {
    HANDLE result = nullptr;
    const HANDLE source = GetStdHandle(kind);
    if (source && source != INVALID_HANDLE_VALUE) {
        if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), &result,
                             0, TRUE, DUPLICATE_SAME_ACCESS)) throw failure("DuplicateHandle");
        return result;
    }
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
    result = CreateFileW(L"NUL", kind == STD_INPUT_HANDLE ? GENERIC_READ : GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_EXISTING, 0, nullptr);
    if (result == INVALID_HANDLE_VALUE) throw failure("CreateFileW NUL");
    return result;
}
struct Desktop {
    HDESK value;
    HDESK previous;
    explicit Desktop(const std::wstring& name) : value(nullptr), previous(GetThreadDesktop(GetCurrentThreadId())) {
        value = CreateDesktopW(name.c_str(), nullptr, nullptr, 0,
            DESKTOP_CREATEWINDOW | DESKTOP_CREATEMENU | DESKTOP_READOBJECTS |
            DESKTOP_WRITEOBJECTS | DESKTOP_ENUMERATE | DESKTOP_HOOKCONTROL, nullptr);
        if (!value) throw failure("CreateDesktopW");
    }
    ~Desktop() {
        if (GetThreadDesktop(GetCurrentThreadId()) != previous) SetThreadDesktop(previous);
        CloseDesktop(value);
    }
    Desktop(const Desktop&) = delete;
    Desktop& operator=(const Desktop&) = delete;
};
struct Attributes {
    std::vector<unsigned char> storage;
    LPPROC_THREAD_ATTRIBUTE_LIST value = nullptr;
    Attributes() {
        SIZE_T bytes = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
        if (!bytes) throw failure("InitializeProcThreadAttributeList size");
        storage.resize(bytes);
        auto* list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        if (!InitializeProcThreadAttributeList(list, 1, 0, &bytes))
            throw failure("InitializeProcThreadAttributeList");
        value = list;
    }
    ~Attributes() { if (value) DeleteProcThreadAttributeList(value); }
    Attributes(const Attributes&) = delete;
    Attributes& operator=(const Attributes&) = delete;
};
inline int run(const std::vector<std::wstring>& arguments, DWORD timeout = INFINITE) {
    if (arguments.empty() || arguments.front().empty()) throw std::runtime_error("child executable required");
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    const std::wstring name = L"UnLhaReTest-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
        std::to_wstring(now.dwHighDateTime) + L"-" + std::to_wstring(now.dwLowDateTime);
    const std::wstring station = object_name(GetProcessWindowStation());
    Desktop desktop(name);
    std::wstring desktop_path = station + L"\\" + name;
    Handle job(CreateJobObjectW(nullptr, nullptr));
    if (!job.value) throw failure("CreateJobObjectW");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
        throw failure("SetInformationJobObject");
    Handle input(inherited_stream(STD_INPUT_HANDLE));
    Handle output(inherited_stream(STD_OUTPUT_HANDLE));
    Handle error(inherited_stream(STD_ERROR_HANDLE));
    HANDLE streams[] = {input.value, output.value, error.value};
    Attributes attributes;
    if (!UpdateProcThreadAttribute(attributes.value, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   streams, sizeof(streams), nullptr, nullptr))
        throw failure("UpdateProcThreadAttribute");
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.lpDesktop = &desktop_path[0];
    // 表示先だけを分離する。SW_HIDE でダイアログの可視状態を変えると UI 比較を壊す。
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_FORCEOFFFEEDBACK;
    startup.StartupInfo.hStdInput = input.value;
    startup.StartupInfo.hStdOutput = output.value;
    startup.StartupInfo.hStdError = error.value;
    startup.lpAttributeList = attributes.value;
    std::wstring command;
    for (const auto& argument : arguments) {
        if (!command.empty()) command += L' ';
        command += quote(argument);
    }
    PROCESS_INFORMATION child{};
    // 表示先・終了管理を確定してから動かす。失敗時に通常デスクトップへ戻して実行しない。
    if (!CreateProcessW(arguments.front().c_str(), &command[0], nullptr, nullptr, TRUE,
        CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, nullptr, &startup.StartupInfo, &child)) throw failure("CreateProcessW");
    Handle process(child.hProcess);
    Handle thread(child.hThread);
    if (!AssignProcessToJobObject(job.value, process.value)) {
        const auto problem = failure("AssignProcessToJobObject");
        TerminateProcess(process.value, 125);
        WaitForSingleObject(process.value, 5000);
        throw problem;
    }
    if (ResumeThread(thread.value) == static_cast<DWORD>(-1)) throw failure("ResumeThread");
    const DWORD wait = WaitForSingleObject(process.value, timeout);
    if (wait == WAIT_TIMEOUT) {
        TerminateJobObject(job.value, 124);
        WaitForSingleObject(process.value, 5000);
        std::cerr << "isolated desktop: timeout\n";
        return 124;
    }
    if (wait != WAIT_OBJECT_0) throw failure("WaitForSingleObject");
    DWORD result = 0;
    if (!GetExitCodeProcess(process.value, &result)) throw failure("GetExitCodeProcess");
    return static_cast<int>(result);
}
inline int relaunch(int argc, wchar_t** argv) {
    std::vector<std::wstring> arguments{executable_path()};
    for (int index = 1; index < argc; ++index) arguments.emplace_back(argv[index]);
    return run(arguments);
}
} // namespace isolated_desktop
