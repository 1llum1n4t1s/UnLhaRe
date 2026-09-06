/*
 * UnLha64x の msvc/UnLha64/lha_progress.c を出発点とする派生実装。
 * 変更内容と再配布条件は README.md / THIRD_PARTY_NOTICES.md を参照。
 */
/* lha_progress.c - LHa コアから DLL 側へのプログレス通知ブリッジ */
/* lha.h のマクロ環境下でコンパイルされ、indicator.c から呼び出される */

#include <windows.h>
#include <string.h>
#include <io.h>
#include "lha.h"
#include "UNLHA64EX.H"

/* コールバック関数ポインタ型 */
typedef BOOL (WINAPI *LHA_ARCHIVERPROC_GEN)(HWND, UINT, UINT, LPVOID);

/* アクセサ関数 (unlha64.cpp から) */
extern HWND Lha_GetHwndOwner();
extern HWND Lha_GetProgressWindow();
extern UINT Lha_GetMsgArcExtract();
extern void Lha_SetMsgArcExtract(UINT u);
extern LHA_ARCHIVERPROC_GEN Lha_GetArcProc();
extern BOOL Lha_GetEnableTotalProgress();
extern int cmd;
extern int Lha_DispatchCompatProgress(int state, const LzHeader* header,
                                      const char* source, const char* destination,
                                      __int64 current_size, __int64 total_size, int os_override);

/* 全体進捗の追跡用グローバル変数 */
static __int64 g_total_bytes = 0;      /* 処理対象の全ファイルの合計サイズ */
static __int64 g_processed_bytes = 0;  /* これまでに処理した累計バイト数 */
static int     g_total_files = 0;      /* 処理対象の全ファイル数 */
static int     g_processed_files = 0;  /* これまでに処理したファイル数 */

static __int64 g_current_file_processed = 0;
static __int64 g_current_file_size = 0;
static char    g_last_filename[513] = {0};
static int     g_lha_aborted = 0;
static LzHeader g_progress_header;
static int      g_has_progress_header = 0;
static char     g_progress_destination[FILENAME_LENGTH] = {0};
static int      g_copy_progress = 0;
/* 原版の進捗数値は通知の登録・解除やコマンド終了とは独立して残る。 */
static __int64  g_read_progress_packed = 0;
static unsigned int g_read_progress_crc = 0;
static int g_read_progress_os = 10;
static int g_progress_os_override = -1;

void Lha_RecordProgressCompressionResult(const LzHeader* header) {
    if (!header) return;
    g_read_progress_packed = header->packed_size;
    g_read_progress_crc = header->crc;
}

void Lha_RecordProgressHeader(const LzHeader* header, int os_type) {
    if (!header) return;
    Lha_RecordProgressCompressionResult(header);
    g_read_progress_os = os_type;
}

void Lha_RecordProgressHeaderError(const LzHeader* header, int os_type) {
    if (!header) return;
    /* CRC 不良時は CRC・OS だけが残り、圧縮サイズは直前の読取・復号状態を保つ。 */
    g_read_progress_crc = header->crc;
    g_read_progress_os = os_type;
}

void Lha_StartProgressDecoder(off_t packed_size) {
    g_read_progress_packed = packed_size;
}

void Lha_ConsumeProgressDecoderByte(void) {
    /* 原版の通知状態には入力境界後の先読み分も残る。実入力の残量・読取境界とは分離する。 */
    --g_read_progress_packed;
}

void Lha_RecordProgressHeaderEnd(void) {
    /* 終端では CRC と OS が初期化され、圧縮サイズは直前の値を保持する。 */
    g_read_progress_crc = 0;
    g_read_progress_os = 10;
}

void Lha_ApplyCompressionProgressHistory(LzHeader* header) {
    if (!header || memcmp(header->method, LZHDIRS_METHOD, METHOD_TYPE_STORAGE) == 0) return;
    header->packed_size = g_read_progress_packed;
    header->crc = g_read_progress_crc;
}

/* 他の処理から全体サイズなどの情報を設定するためのAPI */
void Lha_SetTotalProgressInfo(__int64 total_bytes, int total_files) {
    g_total_bytes = total_bytes;
    g_processed_bytes = 0;
    g_total_files = total_files;
    g_processed_files = 0;
    g_current_file_processed = 0;
    g_current_file_size = 0;
    memset(g_last_filename, 0, sizeof(g_last_filename));
}

void Lha_SetProgressMember(const LzHeader* header) {
    g_progress_os_override = -1;
    if (header) {
        memcpy(&g_progress_header, header, sizeof(g_progress_header));
        g_has_progress_header = 1;
    } else {
        memset(&g_progress_header, 0, sizeof(g_progress_header));
        g_has_progress_header = 0;
    }
    g_progress_destination[0] = '\0';
}

void Lha_SetCompressionProgressMember(const LzHeader* header) {
    Lha_SetProgressMember(header);
    /* 通知の OS だけを継承し、入力の属性・日時を別の OS として解釈しない。 */
    g_progress_os_override = g_read_progress_os;
}

void Lha_SetProgressDestination(const char* destination) {
    if (!destination) {
        g_progress_destination[0] = '\0';
        return;
    }
    strncpy(g_progress_destination, destination, sizeof(g_progress_destination) - 1);
    g_progress_destination[sizeof(g_progress_destination) - 1] = '\0';
}

void Lha_ClearProgressMember() {
    g_progress_os_override = -1;
    memset(&g_progress_header, 0, sizeof(g_progress_header));
    g_has_progress_header = 0;
    g_progress_destination[0] = '\0';
}

int Lha_CheckAbort() {
    return g_lha_aborted;
}

void Lha_ResetAbort() {
    g_lha_aborted = 0;
}

static int Lha_SendProgressMessageCore(int state, const char* filename,
                                       __int64 current_size, __int64 total_size) {
    HWND hwnd = Lha_GetHwndOwner();
    HWND progress_window = Lha_GetProgressWindow();
    LHA_ARCHIVERPROC_GEN proc = Lha_GetArcProc();

    if (g_lha_aborted) return 1;
    if (!progress_window && !proc) return 0;

    /* 1. 全体進捗の自動計算ロジック */
    if (Lha_GetEnableTotalProgress()) {
        if (state == 0) { /* ARCEXTRACT_BEGIN */
            if (filename && strcmp(filename, g_last_filename) != 0) {
                g_processed_files++;
                strncpy(g_last_filename, filename, 512);
            }
            g_current_file_size = total_size;
            g_current_file_processed = 0;
        }
        else if (state == 1) { /* ARCEXTRACT_INPROCESS */
            __int64 delta = current_size - g_current_file_processed;
            if (delta > 0) {
                g_processed_bytes += delta;
                g_current_file_processed = current_size;
            }
        }
        else if (state == 2) { /* ARCEXTRACT_END */
            __int64 delta = total_size - g_current_file_processed;
            if (delta > 0) {
                g_processed_bytes += delta;
            }
            g_current_file_processed = total_size;
        }
    }

    /* 2. 拡張プログレス（wm_arcextract_ex）での通知 */
    if (Lha_GetEnableTotalProgress()) {
        static UINT msg_ex = 0;
        if (msg_ex == 0) {
            msg_ex = RegisterWindowMessageA("wm_arcextract_ex");
            if (msg_ex == 0) return 0;
        }

        EXTRACTINGINFO_TOTAL pi_ex;
        memset(&pi_ex, 0, sizeof(pi_ex));
        pi_ex.dwStructSize = sizeof(pi_ex);
        pi_ex.llFileSize = g_current_file_size;
        pi_ex.llWriteSize = g_current_file_processed;
        pi_ex.llTotalBytes = g_total_bytes;
        pi_ex.llTotalProcessed = g_processed_bytes;
        pi_ex.dwTotalFiles = (DWORD)g_total_files;
        pi_ex.dwFilesProcessed = (DWORD)g_processed_files;

        const char* name_to_use = (filename && filename[0] != '\0') ? filename : g_last_filename;
        if (name_to_use[0] != '\0') {
            MultiByteToWideChar(932, 0, name_to_use, -1, pi_ex.szSourceFileName, FNAME_MAX32);
            MultiByteToWideChar(932, 0, name_to_use, -1, pi_ex.szDestFileName, FNAME_MAX32);
        }

        int abort = 0;
        if (proc) {
            /* コールバック関数の場合は TRUE が継続、FALSE が中断 */
            BOOL ret = proc(hwnd, msg_ex, (UINT)state, (LPVOID)&pi_ex);
            if (!ret) {
                abort = 1;
            }
        } else if (progress_window != NULL) {
            /* メッセージ送信の場合は 0 が継続、非ゼロが中断 */
            LRESULT ret = SendMessageA(progress_window, msg_ex, (WPARAM)state, (LPARAM)&pi_ex);
            if (ret != 0) {
                abort = 1;
            }
        }

        if (abort) {
            g_lha_aborted = 1;
        }
        return abort;
    }

    /* 3. UNLHA32 互換の従来進捗通知 */
    const LzHeader* header = g_has_progress_header ? &g_progress_header : NULL;
    if (state == ARCEXTRACT_BEGIN || state == ARCEXTRACT_OPEN)
        g_copy_progress = 0;
    if (state == ARCEXTRACT_COPY)
        g_copy_progress = 1;
    const char* source = (state == ARCEXTRACT_OPEN || g_copy_progress) ? filename
                       : header ? header->name : filename;
    const char* destination = g_progress_destination[0] ? g_progress_destination : NULL;
    if (state == ARCEXTRACT_END) {
        header = NULL;
        source = NULL;
        destination = NULL;
        g_copy_progress = 0;
    }
    int abort = Lha_DispatchCompatProgress(state, header, source, destination,
                                            current_size, total_size, g_progress_os_override);

    if (abort) {
        g_lha_aborted = 1;
    }
    if (!abort && cmd == CMD_ADD && (state != ARCEXTRACT_INPROCESS || g_copy_progress))
        Lha_PumpCommandMessages();
    return abort;
}

int Lha_SendProgressMessage(int state, const char* filename,
                            __int64 current_size, __int64 total_size) {
    if (!Lha_GetEnableTotalProgress() && cmd == CMD_ADD)
        return 0;
    return Lha_SendProgressMessageCore(state, filename, current_size, total_size);
}

int Lha_SendCompatProgressMessage(int state, const char* filename,
                                  __int64 current_size, __int64 total_size) {
    if (Lha_GetEnableTotalProgress())
        return 0;
    return Lha_SendProgressMessageCore(state, filename, current_size, total_size);
}
