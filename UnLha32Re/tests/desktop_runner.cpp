#include "isolated_desktop.h"
#include <cwchar>

namespace {
bool dialog_observed = false;
BOOL CALLBACK close_probe_window(HWND window, LPARAM) {
    wchar_t title[128]{};
    GetWindowTextW(window, title, 128);
    if (std::wcscmp(title, L"UnLhaRe isolation probe") == 0) {
        dialog_observed = true;
        EndDialog(window, IDOK);
    }
    return TRUE;
}
void CALLBACK close_probe_dialog(HWND, UINT, UINT_PTR, DWORD) {
    // 非入力デスクトップではアクティブ化されないため、生成後のメッセージループで閉じる。
    EnumThreadWindows(GetCurrentThreadId(), close_probe_window, 0);
}
int probe_dialog() {
    if (!isolated_desktop::is_isolated()) throw std::runtime_error("dialog probe requires isolated desktop");
    HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) throw isolated_desktop::failure("OpenInputDesktop");
    const std::wstring input_name = isolated_desktop::object_name(input);
    CloseDesktop(input);
    const std::wstring current = isolated_desktop::object_name(GetThreadDesktop(GetCurrentThreadId()));
    if (current == input_name) throw std::runtime_error("test desktop is visible");
    const UINT_PTR timer = SetTimer(nullptr, 0, 100, close_probe_dialog);
    if (!timer) throw isolated_desktop::failure("SetTimer");
    const int result = MessageBoxW(nullptr, L"The test desktop must remain hidden.",
        L"UnLhaRe isolation probe", MB_OK | MB_TOPMOST | MB_SETFOREGROUND);
    KillTimer(nullptr, timer);
    input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) throw isolated_desktop::failure("OpenInputDesktop after dialog");
    const bool unchanged = isolated_desktop::object_name(input) == input_name;
    CloseDesktop(input);
    if (result != IDOK || !dialog_observed || !unchanged)
        throw std::runtime_error("isolated dialog probe failed");
    std::cout << "isolated-dialog=1,input-desktop-unchanged=1\n";
    return 0;
}
}
int wmain(int argc, wchar_t** argv) {
    try {
        if (argc == 2 && std::wcscmp(argv[1], L"--require-isolated") == 0) {
            if (!isolated_desktop::is_isolated()) throw std::runtime_error("isolated desktop required");
            return 0;
        }
        if (argc == 2 && std::wcscmp(argv[1], L"--probe-dialog") == 0) return probe_dialog();
        int begin = 1;
        DWORD timeout = INFINITE;
        if (argc >= 4 && std::wcscmp(argv[1], L"--timeout-seconds") == 0) {
            wchar_t* end = nullptr;
            const unsigned long seconds = std::wcstoul(argv[2], &end, 10);
            if (end == argv[2] || *end || seconds == 0 || seconds >= MAXDWORD / 1000)
                throw std::runtime_error("invalid timeout");
            timeout = seconds * 1000;
            begin = 3;
        }
        if (begin == argc) throw std::runtime_error("usage: DesktopRunner [--timeout-seconds n] <exe> [args...]");
        std::vector<std::wstring> arguments;
        for (int index = begin; index < argc; ++index) arguments.emplace_back(argv[index]);
        return isolated_desktop::run(arguments, timeout);
    } catch (const std::exception& error) {
        std::cerr << "isolated desktop: " << error.what() << '\n';
        return 125;
    }
}
