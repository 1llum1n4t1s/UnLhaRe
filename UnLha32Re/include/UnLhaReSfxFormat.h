#pragma once

#include <windows.h>

#pragma pack(push, 1)
struct UnLhaReSfxFooter final {
    char magic[16];
    DWORD version;
    DWORD flavor;
    ULONGLONG archiveOffset;
    ULONGLONG archiveSize;
    ULONGLONG dllOffset;
    ULONGLONG dllSize;
};
#pragma pack(pop)

static constexpr char kUnLhaReSfxFooterMagic[16] = {
    'U', 'N', 'L', 'H', 'A', 'R', 'E', 'S', 'F', 'X', '1', 0, 0, 0, 0, 0
};
static constexpr DWORD kUnLhaReSfxFooterVersion = 1;
static constexpr int kUnLhaReSfxLoaderResource = 101;

