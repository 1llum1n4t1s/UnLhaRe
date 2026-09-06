/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              append.c -- append to archive                               */
/*                                                                          */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14   Source All chagned              1995.01.14  N.Watazaki      */
/* ------------------------------------------------------------------------ */
#include "lha.h"

/* 通常の jm0 は確定前の情報のまま、最大 64 KiB ごとに格納進捗を通知する。 */
off_t
Lha_CopyStoredWithProgress(FILE *input, FILE *output, off_t size, const char *name, unsigned int *crc)
{
    char buffer[65536];
    off_t completed = 0, since_notification = 0;
    off_t threshold = size > 13107200 ? 131072 : size > 409600 ? size / 100 : 4096;
    INITIALIZE_CRC(*crc);
    while (completed < size) {
        size_t count = size - completed > sizeof(buffer) ? sizeof(buffer) : (size_t)(size - completed);
        if (fread(buffer, 1, count, input) != count) fatal_error("file read error");
        if (Lha_WriteCompressionData(buffer, 1, count, output) != count) fatal_error("file write error");
        *crc = calccrc(*crc, buffer, (unsigned int)count);
        put_indicator((long)count);
        completed += count;
        since_notification += count;
        if (since_notification >= threshold) {
            since_notification = 0;
            if (Lha_SendCompatProgressMessage(1, name, completed, size))
                fatal_error("User cancelled.");
        }
    }
    return completed;
}

int
encode_lzhuf(FILE *infp, FILE *outfp,
             off_t size, off_t *original_size_var, off_t *packed_size_var,
             char *name, char *hdr_method)
{
    int method = compress_method;
    unsigned int crc;
    struct interfacing iface;

    /* jm5 は項目ごとに判定し、8 KiB 以上を LH3 へ切り替える。 */
    if (method == LZHUFF2_METHOD_NUM && size >= 8192)
        method = LZHUFF3_METHOD_NUM;

    /* DLL の再呼出し・展開後にも圧縮方式と辞書状態を再設定する。領域は再利用する。 */
    if (method > 0)
        method = encode_alloc(method);

    iface.method = method;

    if (iface.method > 0) {
        iface.infile = infp;
        iface.outfile = outfp;
        iface.original = size;
        start_indicator(name, size, "Freezing", 1 << dicbit);
        crc = encode(&iface);
        *packed_size_var = iface.packed;
        *original_size_var = iface.original;
    } else {
        start_indicator(name, size, "Storing ", 2048);
        *packed_size_var = *original_size_var =
            !text_mode ? Lha_CopyStoredWithProgress(infp, outfp, size, name, &crc)
                       : copyfile(infp, outfp, size, 0, &crc);
    }
    if (iface.method == LARC_METHOD_NUM) {
        memcpy(hdr_method, LARC_METHOD, METHOD_TYPE_STORAGE);
    } else if (iface.method == LARC5_METHOD_NUM) {
        memcpy(hdr_method, LARC5_METHOD, METHOD_TYPE_STORAGE);
    } else {
        memcpy(hdr_method, "-lh -", 5);
        hdr_method[3] = iface.method == LZHUFFX_METHOD_NUM ? 'x' : iface.method + '0';
    }

    finish_indicator2(name, "Frozen",
            (int) ((*packed_size_var * 100L) / *original_size_var));
    return crc;
}
