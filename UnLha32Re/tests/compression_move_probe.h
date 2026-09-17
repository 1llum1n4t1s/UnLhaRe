#pragma once

// compatibility_tests.cpp の匿名 namespace 末尾から取り込み、圧縮完了時の
// Win32 ファイル移動だけを観測する。フック中は出力せず、復元後に記録を公開する。

using CompressionMoveFileAFunction = BOOL(WINAPI*)(LPCSTR, LPCSTR);
using CompressionMoveFileWFunction = BOOL(WINAPI*)(LPCWSTR, LPCWSTR);
using CompressionMoveFileExAFunction = BOOL(WINAPI*)(LPCSTR, LPCSTR, DWORD);
using CompressionMoveFileExWFunction = BOOL(WINAPI*)(LPCWSTR, LPCWSTR, DWORD);

enum class CompressionMoveProbeMode {
    Observe,
    Deny,
};

enum class CompressionMoveProbeKind {
    Other,
    InitialBackup,
    CompletedMove,
    RollbackMove,
    UnmatchedToArchive,
};

enum class CompressionMoveProbeFailure {
    None,
    HookException,
    UnexpectedCompletedSource,
    UnclassifiedToArchive,
};

enum class CompressionMoveHookSite {
    Unchecked,
    ApiMissing,
    Iat,
    DataPointer,
    NotReferenced,
};

struct CompressionMoveProbeRecord final {
    const char* api = nullptr;
    CompressionMoveProbeKind kind = CompressionMoveProbeKind::Other;
    bool source_null = false;
    bool destination_null = false;
    bool extended = false;
    std::wstring source;
    std::wstring destination;
    DWORD flags = 0;
    BOOL result = FALSE;
    DWORD win32_error = ERROR_SUCCESS;
};

struct CompressionMoveProbeState final {
    CompressionMoveProbeMode mode = CompressionMoveProbeMode::Observe;
    CompressionMoveProbeFailure failure = CompressionMoveProbeFailure::None;
    std::wstring archive;
    std::wstring backup;
    std::wstring completed_source;
    std::vector<CompressionMoveProbeRecord> records;
    CompressionMoveFileAFunction move_a = nullptr;
    CompressionMoveFileWFunction move_w = nullptr;
    CompressionMoveFileExAFunction move_ex_a = nullptr;
    CompressionMoveFileExWFunction move_ex_w = nullptr;
    CompressionMoveHookSite move_a_site = CompressionMoveHookSite::Unchecked;
    CompressionMoveHookSite move_w_site = CompressionMoveHookSite::Unchecked;
    CompressionMoveHookSite move_ex_a_site = CompressionMoveHookSite::Unchecked;
    CompressionMoveHookSite move_ex_w_site = CompressionMoveHookSite::Unchecked;
    unsigned all_move = 0;
    unsigned initial_backup = 0;
    unsigned completed_move = 0;
    unsigned injected = 0;
    unsigned rollback_move = 0;
    unsigned unmatched_to_archive = 0;

    void reset(CompressionMoveProbeMode selected_mode, std::wstring archive_path) {
        mode = selected_mode;
        failure = CompressionMoveProbeFailure::None;
        archive = std::move(archive_path);
        backup.clear();
        completed_source.clear();
        records.clear();
        records.reserve(64);
        move_a = nullptr;
        move_w = nullptr;
        move_ex_a = nullptr;
        move_ex_w = nullptr;
        move_a_site = move_w_site = move_ex_a_site = move_ex_w_site =
            CompressionMoveHookSite::Unchecked;
        all_move = initial_backup = completed_move = injected = rollback_move =
            unmatched_to_archive = 0;
    }
};

static CompressionMoveProbeState compression_move_probe;

static void compression_move_mark_failure(CompressionMoveProbeFailure failure) noexcept {
    if (compression_move_probe.failure == CompressionMoveProbeFailure::None)
        compression_move_probe.failure = failure;
}

static std::wstring compression_move_absolute_path(const wchar_t* path) {
    if (!path || !*path) return {};
    return compression_commit_normalize_path(normalized_absolute_filename(path).c_str());
}

static std::wstring compression_move_ansi_path(const char* path) {
    if (!path || !*path) return {};
    const int length = MultiByteToWideChar(CP_ACP, 0, path, -1, nullptr, 0);
    if (length <= 0) throw std::runtime_error("cannot convert compression move path from ACP");
    std::wstring wide(static_cast<size_t>(length), L'\0');
    if (!MultiByteToWideChar(CP_ACP, 0, path, -1, &wide[0], length))
        throw std::runtime_error("cannot convert compression move path from ACP");
    wide.pop_back();
    return compression_move_absolute_path(wide.c_str());
}

static bool compression_move_same_path(const std::wstring& left, const std::wstring& right) {
    return !left.empty() && !right.empty() &&
        CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
}

struct CompressionMoveProbeIntent final {
    CompressionMoveProbeKind kind = CompressionMoveProbeKind::Other;
    bool source_null = false;
    bool destination_null = false;
    std::wstring source;
    std::wstring destination;
};

static CompressionMoveProbeIntent compression_move_classify(
    const wchar_t* source, const wchar_t* destination) {
    auto& state = compression_move_probe;
    CompressionMoveProbeIntent intent;
    intent.source_null = source == nullptr;
    intent.destination_null = destination == nullptr;
    intent.source = compression_move_absolute_path(source);
    intent.destination = compression_move_absolute_path(destination);
    ++state.all_move;

    const bool source_is_lht = compression_commit_temp_name(intent.source.c_str(), L"LHT");
    const bool destination_is_lht = compression_commit_temp_name(intent.destination.c_str(), L"LHT");
    if (compression_move_same_path(intent.source, state.archive) && destination_is_lht) {
        intent.kind = CompressionMoveProbeKind::InitialBackup;
        ++state.initial_backup;
        return intent;
    }
    if (!compression_move_same_path(intent.destination, state.archive))
        return intent;
    if (compression_move_same_path(intent.source, state.backup)) {
        intent.kind = CompressionMoveProbeKind::RollbackMove;
        ++state.rollback_move;
        return intent;
    }
    if (!source_is_lht) {
        intent.kind = CompressionMoveProbeKind::UnmatchedToArchive;
        ++state.unmatched_to_archive;
        compression_move_mark_failure(CompressionMoveProbeFailure::UnclassifiedToArchive);
        return intent;
    }

    ++state.completed_move;
    if (state.mode == CompressionMoveProbeMode::Deny) {
        if (state.completed_source.empty()) {
            state.completed_source = intent.source;
        } else if (!compression_move_same_path(intent.source, state.completed_source)) {
            intent.kind = CompressionMoveProbeKind::UnmatchedToArchive;
            ++state.unmatched_to_archive;
            compression_move_mark_failure(CompressionMoveProbeFailure::UnexpectedCompletedSource);
            return intent;
        }
    }
    intent.kind = CompressionMoveProbeKind::CompletedMove;
    return intent;
}

static void compression_move_finish(const char* api, CompressionMoveProbeIntent intent,
                                    const bool extended, const DWORD flags,
                                    const BOOL result, const DWORD win32_error) {
    auto& state = compression_move_probe;
    if (intent.kind == CompressionMoveProbeKind::InitialBackup && result) {
        if (state.backup.empty()) {
            state.backup = intent.destination;
        } else if (!compression_move_same_path(state.backup, intent.destination)) {
            compression_move_mark_failure(CompressionMoveProbeFailure::HookException);
        }
    }
    CompressionMoveProbeRecord record;
    record.api = api;
    record.kind = intent.kind;
    record.source_null = intent.source_null;
    record.destination_null = intent.destination_null;
    record.extended = extended;
    record.source = std::move(intent.source);
    record.destination = std::move(intent.destination);
    record.flags = flags;
    record.result = result;
    record.win32_error = win32_error;
    state.records.push_back(std::move(record));
}

template <typename CallReal>
static BOOL compression_move_dispatch(const char* api, const wchar_t* source,
                                      const wchar_t* destination, const bool extended,
                                      const DWORD flags, CallReal call_real) noexcept {
    const DWORD incoming_error = GetLastError();
    BOOL result = FALSE;
    DWORD result_error = incoming_error;
    bool real_called = false;
    bool injected = false;
    try {
        CompressionMoveProbeIntent intent = compression_move_classify(source, destination);
        if (compression_move_probe.mode == CompressionMoveProbeMode::Deny &&
            intent.kind == CompressionMoveProbeKind::CompletedMove) {
            ++compression_move_probe.injected;
            injected = true;
            result = FALSE;
            result_error = ERROR_ACCESS_DENIED;
        } else {
            SetLastError(incoming_error);
            result = call_real();
            result_error = GetLastError();
            real_called = true;
        }
        SetLastError(result_error);
        compression_move_finish(api, std::move(intent), extended, flags, result, result_error);
    } catch (...) {
        compression_move_mark_failure(CompressionMoveProbeFailure::HookException);
        if (!real_called && !injected) {
            SetLastError(incoming_error);
            result = call_real();
            result_error = GetLastError();
        }
    }
    SetLastError(result_error);
    return result;
}

static BOOL WINAPI compression_move_file_a(LPCSTR source, LPCSTR destination) {
    const DWORD incoming_error = GetLastError();
    try {
        const std::wstring source_w = compression_move_ansi_path(source);
        const std::wstring destination_w = compression_move_ansi_path(destination);
        SetLastError(incoming_error);
        return compression_move_dispatch("MoveFileA", source ? source_w.c_str() : nullptr,
            destination ? destination_w.c_str() : nullptr, false, 0,
            [=]() { return compression_move_probe.move_a(source, destination); });
    } catch (...) {
        compression_move_mark_failure(CompressionMoveProbeFailure::HookException);
        SetLastError(incoming_error);
        const BOOL result = compression_move_probe.move_a(source, destination);
        const DWORD result_error = GetLastError();
        SetLastError(result_error);
        return result;
    }
}

static BOOL WINAPI compression_move_file_w(LPCWSTR source, LPCWSTR destination) {
    return compression_move_dispatch("MoveFileW", source, destination, false, 0,
        [=]() { return compression_move_probe.move_w(source, destination); });
}

static BOOL WINAPI compression_move_file_ex_a(LPCSTR source, LPCSTR destination, DWORD flags) {
    const DWORD incoming_error = GetLastError();
    try {
        const std::wstring source_w = compression_move_ansi_path(source);
        const std::wstring destination_w = compression_move_ansi_path(destination);
        SetLastError(incoming_error);
        return compression_move_dispatch("MoveFileExA", source ? source_w.c_str() : nullptr,
            destination ? destination_w.c_str() : nullptr, true, flags,
            [=]() { return compression_move_probe.move_ex_a(source, destination, flags); });
    } catch (...) {
        compression_move_mark_failure(CompressionMoveProbeFailure::HookException);
        SetLastError(incoming_error);
        const BOOL result = compression_move_probe.move_ex_a(source, destination, flags);
        const DWORD result_error = GetLastError();
        SetLastError(result_error);
        return result;
    }
}

static BOOL WINAPI compression_move_file_ex_w(LPCWSTR source, LPCWSTR destination, DWORD flags) {
    return compression_move_dispatch("MoveFileExW", source, destination, true, flags,
        [=]() { return compression_move_probe.move_ex_w(source, destination, flags); });
}

static CompressionMoveHookSite compression_move_install_hook(
    ScopedImportOverride& hook, HMODULE module, const char* name,
    const DWORD expected, const DWORD replacement) {
    if (!expected) return CompressionMoveHookSite::ApiMissing;
    hook.install(module, name, expected, replacement, true);
    if (hook.slot) return CompressionMoveHookSite::Iat;
    hook.install_data_pointer(module, expected, replacement, true);
    return hook.slot ? CompressionMoveHookSite::DataPointer
                     : CompressionMoveHookSite::NotReferenced;
}

static const char* compression_move_hook_site_name(CompressionMoveHookSite site) {
    switch (site) {
    case CompressionMoveHookSite::ApiMissing: return "api-missing";
    case CompressionMoveHookSite::Iat: return "iat";
    case CompressionMoveHookSite::DataPointer: return "data-pointer";
    case CompressionMoveHookSite::NotReferenced: return "not-referenced";
    default: return "unchecked";
    }
}

static const char* compression_move_kind_name(CompressionMoveProbeKind kind) {
    switch (kind) {
    case CompressionMoveProbeKind::InitialBackup: return "initial-backup";
    case CompressionMoveProbeKind::CompletedMove: return "completed-move";
    case CompressionMoveProbeKind::RollbackMove: return "rollback-move";
    case CompressionMoveProbeKind::UnmatchedToArchive: return "unmatched-to-archive";
    default: return "other";
    }
}

static const char* compression_move_failure_name(CompressionMoveProbeFailure failure) {
    switch (failure) {
    case CompressionMoveProbeFailure::HookException: return "hook-exception";
    case CompressionMoveProbeFailure::UnexpectedCompletedSource:
        return "unexpected-completed-source";
    case CompressionMoveProbeFailure::UnclassifiedToArchive:
        return "unclassified-to-archive";
    default: return "none";
    }
}

static void compression_move_print_hook(const char* api, const bool available,
                                        CompressionMoveHookSite site) {
    std::cout << "compression-move-hook=api=" << api
              << ",available=" << available
              << ",site=" << compression_move_hook_site_name(site) << '\n';
}

static void compression_move_print_observations() {
    const auto& state = compression_move_probe;
    std::cout << "compression-move-mode="
              << (state.mode == CompressionMoveProbeMode::Deny ? "deny" : "observe") << '\n';
    compression_move_print_hook("MoveFileA", state.move_a != nullptr, state.move_a_site);
    compression_move_print_hook("MoveFileW", state.move_w != nullptr, state.move_w_site);
    compression_move_print_hook("MoveFileExA", state.move_ex_a != nullptr, state.move_ex_a_site);
    compression_move_print_hook("MoveFileExW", state.move_ex_w != nullptr, state.move_ex_w_site);
    for (const auto& record : state.records) {
        std::cout << "compression-move-record=api=" << record.api
                  << ",kind=" << compression_move_kind_name(record.kind)
                  << ",source-null=" << record.source_null
                  << ",source=" << quote_wide(record.source.c_str())
                  << ",destination-null=" << record.destination_null
                  << ",destination=" << quote_wide(record.destination.c_str())
                  << ",extended=" << record.extended
                  << ",flags=" << record.flags
                  << ",result=" << (record.result != FALSE)
                  << ",win32-error=" << record.win32_error << '\n';
    }
    std::cout << "compression-move-counts=all_move=" << state.all_move
              << ",initial_backup=" << state.initial_backup
              << ",completed_move=" << state.completed_move
              << ",injected=" << state.injected
              << ",rollback_move=" << state.rollback_move
              << ",unmatched_to_archive=" << state.unmatched_to_archive << '\n'
              << "compression-move-paths=archive=" << quote_wide(state.archive.c_str())
              << ",backup=" << quote_wide(state.backup.c_str())
              << ",completed-source=" << quote_wide(state.completed_source.c_str()) << '\n'
              << "compression-move-failure=" << compression_move_failure_name(state.failure) << '\n';
}

int run_compression_move_probe(const wchar_t* dll_path, const wchar_t* command,
                               const wchar_t* archive_path, const wchar_t* mode) {
    if (!dll_path || !command || !archive_path || !mode)
        throw std::runtime_error("compression move probe requires non-null arguments");
    CompressionMoveProbeMode selected_mode;
    if (_wcsicmp(mode, L"observe") == 0) selected_mode = CompressionMoveProbeMode::Observe;
    else if (_wcsicmp(mode, L"deny") == 0) selected_mode = CompressionMoveProbeMode::Deny;
    else throw std::runtime_error("compression move probe mode must be observe or deny");

    compression_move_probe.reset(selected_mode, compression_move_absolute_path(archive_path));
    if (compression_move_probe.archive.empty())
        throw std::runtime_error("compression move probe archive path is empty");

    struct LocaleRestore final {
        LCID previous = GetThreadLocale();
        ~LocaleRestore() { SetThreadLocale(previous); }
    } locale_restore;
    if (!SetThreadLocale(1041))
        throw std::runtime_error("cannot set compression move probe locale");

    // この保持を各 hook より先に宣言し、hook 復元後まで DLL を unload させない。
    Module retained(dll_path);
    (void)proc<FnWord0>(retained.handle, "UnlhaGetVersion")();
    (void)proc<FnBoolBool>(retained.handle, "UnlhaSetUnicodeMode")(FALSE);

    const HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
    if (!kernel32) throw std::runtime_error("kernel32 is not loaded");
    auto& state = compression_move_probe;
    state.move_a = optional_proc<CompressionMoveFileAFunction>(kernel32, "MoveFileA");
    state.move_w = optional_proc<CompressionMoveFileWFunction>(kernel32, "MoveFileW");
    state.move_ex_a = optional_proc<CompressionMoveFileExAFunction>(kernel32, "MoveFileExA");
    state.move_ex_w = optional_proc<CompressionMoveFileExWFunction>(kernel32, "MoveFileExW");

    int command_result = 0;
    std::string execution_failure;
    {
        ScopedImportOverride move_a_hook;
        ScopedImportOverride move_w_hook;
        ScopedImportOverride move_ex_a_hook;
        ScopedImportOverride move_ex_w_hook;
        try {
            state.move_a_site = compression_move_install_hook(move_a_hook, retained.handle,
                "MoveFileA", reinterpret_cast<DWORD>(state.move_a),
                reinterpret_cast<DWORD>(&compression_move_file_a));
            state.move_w_site = compression_move_install_hook(move_w_hook, retained.handle,
                "MoveFileW", reinterpret_cast<DWORD>(state.move_w),
                reinterpret_cast<DWORD>(&compression_move_file_w));
            state.move_ex_a_site = compression_move_install_hook(move_ex_a_hook, retained.handle,
                "MoveFileExA", reinterpret_cast<DWORD>(state.move_ex_a),
                reinterpret_cast<DWORD>(&compression_move_file_ex_a));
            state.move_ex_w_site = compression_move_install_hook(move_ex_w_hook, retained.handle,
                "MoveFileExW", reinterpret_cast<DWORD>(state.move_ex_w),
                reinterpret_cast<DWORD>(&compression_move_file_ex_w));
            const unsigned installed = (move_a_hook.slot != nullptr) + (move_w_hook.slot != nullptr) +
                (move_ex_a_hook.slot != nullptr) + (move_ex_w_hook.slot != nullptr);
            if (!installed) throw std::runtime_error("compression move interception unavailable");
            command_result = run_command_probe(dll_path, command);
        } catch (const std::exception& error) {
            execution_failure = error.what();
        } catch (...) {
            execution_failure = "unknown compression move probe failure";
        }
    }

    // ScopedImportOverride 群が全て復元された後だけ、監査結果を出力する。
    compression_move_print_observations();
    if (!execution_failure.empty()) throw std::runtime_error(execution_failure);
    if (state.failure != CompressionMoveProbeFailure::None)
        throw std::runtime_error(std::string("compression move audit failed: ") +
                                 compression_move_failure_name(state.failure));
    if (!state.completed_move)
        throw std::runtime_error("compression completed move was not observed");
    if (selected_mode == CompressionMoveProbeMode::Deny && !state.injected)
        throw std::runtime_error("compression completed move denial was not injected");
    return command_result;
}
