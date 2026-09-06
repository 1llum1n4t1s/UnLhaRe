/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              larc.c -- extra *.lzs                                       */
/*                                                                          */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14   Source All chagned              1995.01.14  N.Watazaki      */
/* ------------------------------------------------------------------------ */
#include "lha.h"

/* ------------------------------------------------------------------------ */
static int      flag, flagcnt, matchpos;
static unsigned int lzs_encode_count;
static unsigned int lz5_encode_count, lz5_encode_used, lz5_encode_flags;
static unsigned char lz5_encode_codes[8];
static unsigned short lz5_encode_positions[8];

/* 原版の LZS は共有 LZ 探索の結果を 1/8 または 1/11/4 ビットで出力する。 */
void
encode_start_lzs(void)
{
    lzs_encode_count = 0;
    init_putbits();
}

void
output_lzs(unsigned int code, unsigned int pos)
{
    if (code < 0x100) {
        putbits(1, 1);
        putbits(8, (unsigned short)code);
        lzs_encode_count++;
    }
    else {
        putbits(1, 0);
        putbits(11, (unsigned short)((lzs_encode_count - pos - MAGIC0) & 0x7ff));
        putbits(4, (unsigned short)(code - 0xff));
        lzs_encode_count += code - (256 - THRESHOLD);
    }
}

void
encode_end_lzs(void)
{
    putbits(7, 0);
}

/* LZ5 の最終パケットも 8 トークン。余ったスロットは同じ項目の直前値を使う。 */
static void
flush_lz5_packet(void)
{
    unsigned int i;

    putbits(8, (unsigned short)(~lz5_encode_flags & 0xff));
    for (i = 0; i < 8 && !unpackable; i++) {
        if (lz5_encode_flags & (1U << i)) {
            const unsigned int position = lz5_encode_positions[i];
            putbits(8, (unsigned short)(position & 0xff));
            if (!unpackable)
                putbits(8, (unsigned short)(((position >> 4) & 0xf0) + lz5_encode_codes[i]));
        }
        else {
            putbits(8, lz5_encode_codes[i]);
        }
    }
}

void
encode_start_lz5(void)
{
    lz5_encode_count = lz5_encode_used = lz5_encode_flags = 0;
    /* 初回の未使用スロットへ、原版で観測した未初期化メモリを露出させない。 */
    memset(lz5_encode_codes, 0, sizeof(lz5_encode_codes));
    init_putbits();
}

void
output_lz5(unsigned int code, unsigned int pos)
{
    unsigned int slot;

    if (lz5_encode_used == 8) {
        flush_lz5_packet();
        if (unpackable) return;
        lz5_encode_used = lz5_encode_flags = 0;
    }
    slot = lz5_encode_used++;
    lz5_encode_codes[slot] = (unsigned char)code;
    if (code < 0x100) {
        lz5_encode_count++;
    }
    else {
        lz5_encode_flags |= 1U << slot;
        lz5_encode_positions[slot] = (unsigned short)((lz5_encode_count - pos - MAGIC5) & 0xfff);
        lz5_encode_count += code - (256 - THRESHOLD);
    }
}

void
encode_end_lz5(void)
{
    if (lz5_encode_used && !unpackable)
        flush_lz5_packet();
}

/* ------------------------------------------------------------------------ */
/* lzs */
unsigned short
decode_c_lzs( /*void*/ )
{
    if (getbits(1)) {
        return getbits(8);
    }
    else {
        matchpos = getbits(11);
        return getbits(4) + 0x100;
    }
}

/* ------------------------------------------------------------------------ */
/* lzs */
unsigned short
decode_p_lzs( /*void*/ )
{
    return (loc - matchpos - MAGIC0) & 0x7ff;
}

/* ------------------------------------------------------------------------ */
/* lzs */
void
decode_start_lzs( /*void*/ )
{
    init_getbits();
    init_code_cache();
}

/* ------------------------------------------------------------------------ */
/* lz5 */
unsigned short
decode_c_lz5( /*void*/ )
{
    int             c;

    if (flagcnt == 0) {
        flagcnt = 8;
        flag = getc(infile);
    }
    flagcnt--;
    c = getc(infile);
    if ((flag & 1) == 0) {
        matchpos = c;
        c = getc(infile);
        matchpos += (c & 0xf0) << 4;
        c &= 0x0f;
        c += 0x100;
    }
    flag >>= 1;
    return c;
}

/* ------------------------------------------------------------------------ */
/* lz5 */
unsigned short
decode_p_lz5( /*void*/ )
{
    return (loc - matchpos - MAGIC5) & 0xfff;
}

/* ------------------------------------------------------------------------ */
/* lz5 */
void
decode_start_lz5( /*void*/ )
{
    int             i;

    flagcnt = 0;
    for (i = 0; i < 256; i++)
        memset(&dtext[i * 13 + 18], i, 13);
    for (i = 0; i < 256; i++)
        dtext[256 * 13 + 18 + i] = i;
    for (i = 0; i < 256; i++)
        dtext[256 * 13 + 256 + 18 + i] = 255 - i;
    memset(&dtext[256 * 13 + 512 + 18], 0, 128);
    memset(&dtext[256 * 13 + 512 + 128 + 18], ' ', 128 - 18);
}
