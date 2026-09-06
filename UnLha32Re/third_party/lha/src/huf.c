/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              huf.c -- new static Huffman                                 */
/*                                                                          */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14   Source All chagned              1995.01.14  N.Watazaki      */
/*  Ver. 1.14i  Support LH7 & Bug Fixed         2000.10. 6  t.okamoto       */
/* ------------------------------------------------------------------------ */
#include "lha.h"

#if HAVE_SYS_PARAM_H
#include <sys/param.h>
#endif

#if STDC_HEADERS
#include <stdlib.h>
#else
extern char *malloc ();
#endif

/* ------------------------------------------------------------------------ */
unsigned short left[2 * NC - 1], right[2 * NC - 1];

unsigned short c_code[NC];      /* encode */
unsigned short pt_code[NPT];    /* encode */

unsigned short c_table[4096];   /* decode */
unsigned short pt_table[256];   /* decode */

unsigned short c_freq[2 * NC - 1]; /* encode */
unsigned short p_freq[2 * NP - 1]; /* encode */
unsigned short t_freq[2 * NT - 1]; /* encode */

unsigned char  c_len[NC];
unsigned char  pt_len[NPT];

static unsigned char *buf;      /* encode */
static unsigned int bufsiz;     /* encode */
static unsigned short blocksize; /* decode */
static unsigned short output_pos, output_mask; /* encode */

static int pbit;
static int np;
static unsigned short lx1_position_mode;

/* lh3 encoder */
#define ST0_NC              286
#define ST0_NP              128
#define ST0_BUFSIZ          65536U
#define ST0_FLUSH_MARGIN    24U

/*
 * UNLHA32 3.00.0.5 は単一の位置群しかない LH3 ブロックでも動的位置木を
 * 選び、128 個のゼロ長をそのまま書く。そのため位置群が 0 以外だと、成功を
 * 返した書庫を正しく復元できない。既知のデータ破損だけは再現しない。
 */
static unsigned char *st0_buf;
static unsigned int *st0_positions;
static unsigned short st0_p_freq[2 * ST0_NP - 1];
static unsigned int st0_match_pos;
static unsigned short st0_cpos;
/* ------------------------------------------------------------------------ */
/*                              Encording                                   */
/* ------------------------------------------------------------------------ */
/* lh3 */
static void
write_c_len_st0(unsigned short root)
{
    int i;

    if (root < ST0_NC) {
        /* decode_c_st0 が定義する単一シンボル木の省略表現。 */
        for (i = 0; i < 3; i++) {
            putbits(1, 1);
            putbits(4, 0);
        }
        putbits(9, root);
        memset(c_len, 0, ST0_NC);
        return;
    }

    for (i = 0; i < ST0_NC; i++) {
        if (c_len[i] == 0) {
            putbits(1, 0);
        } else {
            putbits(1, 1);
            putbits(4, c_len[i] - 1);
        }
        if (i == 2 && c_len[0] == 1 && c_len[1] == 1 && c_len[2] == 1) {
            putbits(9, root);
            memset(c_len, 0, ST0_NC);
            return;
        }
    }
}

/* ------------------------------------------------------------------------ */
/* lh3 */
static void
write_p_len_st0(unsigned short root)
{
    int i;

    if (root < ST0_NP) {
        /* decode_p_st0 が定義する単一位置群木の省略表現。 */
        for (i = 0; i < 3; i++)
            putbits(4, 1);
        putbits(7, root);
        memset(pt_len, 0, ST0_NP);
        return;
    }

    for (i = 0; i < ST0_NP; i++) {
        putbits(4, pt_len[i]);
        if (i == 2 && pt_len[0] == 1 && pt_len[1] == 1 && pt_len[2] == 1) {
            putbits(7, root);
            memset(pt_len, 0, ST0_NP);
            return;
        }
    }
}

/* ------------------------------------------------------------------------ */
/* lh3 */
static void
send_block_st0( /* void */ )
{
    unsigned char flags;
    unsigned short c, i, root, size;
    unsigned int position, pos;

    root = make_tree(ST0_NC, c_freq, c_len, c_code);
    size = c_freq[root];
    putbits(16, size);
    write_c_len_st0(root);

    /* 原版と同じく、LH3 の位置木は常に動的形式で出力する。 */
    root = make_tree(ST0_NP, st0_p_freq, pt_len, pt_code);
    putbits(1, 1);
    write_p_len_st0(root);

    pos = 0;
    position = 0;
    flags = 0;
    for (i = 0; i < size; i++) {
        if (i % CHAR_BIT == 0)
            flags = st0_buf[pos++];
        else
            flags <<= 1;

        c = st0_buf[pos++];
        if (flags & (1 << (CHAR_BIT - 1))) {
            c += 1 << CHAR_BIT;
            if (c >= ST0_NC - 1) {
                putcode(c_len[ST0_NC - 1], c_code[ST0_NC - 1]);
                putbits(8, c - (ST0_NC - 1));
            } else {
                putcode(c_len[c], c_code[c]);
            }
            encode_p_st0((unsigned short)st0_positions[position++]);
        } else {
            putcode(c_len[c], c_code[c]);
        }
        if (unpackable)
            return;
    }

    for (i = 0; i < ST0_NC; i++)
        c_freq[i] = 0;
    for (i = 0; i < ST0_NP; i++)
        st0_p_freq[i] = 0;
}

/* ------------------------------------------------------------------------ */
/* lh3 */
void
output_st0(unsigned int c, unsigned int p)
{
    output_mask >>= 1;
    if (output_mask == 0) {
        output_mask = 1 << (CHAR_BIT - 1);
        if (output_pos >= ST0_BUFSIZ - ST0_FLUSH_MARGIN) {
            send_block_st0();
            if (unpackable)
                return;
            output_pos = 0;
            st0_match_pos = 0;
        }
        st0_cpos = output_pos++;
        st0_buf[st0_cpos] = 0;
    }

    st0_buf[output_pos++] = (unsigned char)c;
    if (c < ST0_NC - 1)
        c_freq[c]++;
    else
        c_freq[ST0_NC - 1]++;

    if (c >= (1 << CHAR_BIT)) {
        st0_buf[st0_cpos] |= output_mask;
        st0_positions[st0_match_pos++] = p;
        st0_p_freq[p >> 6]++;
    }
}

/* ------------------------------------------------------------------------ */
/* lh3 */
void
encode_start_st0( /* void */ )
{
    n_max = ST0_NC;
    maxmatch = MAXMATCH;

    st0_buf = (unsigned char *)xmalloc(ST0_BUFSIZ * (1U + sizeof(unsigned int)));
    st0_positions = (unsigned int *)(st0_buf + ST0_BUFSIZ);
    st0_buf[0] = 0;
    output_pos = output_mask = 0;
    st0_match_pos = 0;

    memset(c_freq, 0, ST0_NC * sizeof(c_freq[0]));
    memset(st0_p_freq, 0, ST0_NP * sizeof(st0_p_freq[0]));
    init_putbits();
    init_code_cache();
}

/* ------------------------------------------------------------------------ */
/* lh3 */
void
free_st0_buffer( /* void */ )
{
    free(st0_buf);
    st0_buf = NULL;
    st0_positions = NULL;
}

void
encode_end_st0( /* void */ )
{
    if (!unpackable) {
        send_block_st0();
        putbits(CHAR_BIT - 1, 0);
    }
    free_st0_buffer();
}

/* ------------------------------------------------------------------------ */
static void
count_t_freq(/*void*/)
{
    short           i, k, n, count;

    for (i = 0; i < NT; i++)
        t_freq[i] = 0;
    n = NC;
    while (n > 0 && c_len[n - 1] == 0)
        n--;
    i = 0;
    while (i < n) {
        k = c_len[i++];
        if (k == 0) {
            count = 1;
            while (i < n && c_len[i] == 0) {
                i++;
                count++;
            }
            if (count <= 2)
                t_freq[0] += count;
            else if (count <= 18)
                t_freq[1]++;
            else if (count == 19) {
                t_freq[0]++;
                t_freq[1]++;
            }
            else
                t_freq[2]++;
        } else
            t_freq[k + 2]++;
    }
}

/* ------------------------------------------------------------------------ */
static void
write_pt_len(short n, short nbit, short i_special)
{
    short           i, k;

    while (n > 0 && pt_len[n - 1] == 0)
        n--;
    putbits(nbit, n);
    i = 0;
    while (i < n) {
        k = pt_len[i++];
        if (k <= 6)
            putbits(3, k);
        else
            /* k=7 -> 1110  k=8 -> 11110  k=9 -> 111110 ... */
            putbits(k - 3, (short)(USHRT_MAX << 1));
        if (i == i_special) {
            while (i < 6 && pt_len[i] == 0)
                i++;
            putbits(2, i - 3);
        }
    }
}

/* ------------------------------------------------------------------------ */
static void
write_c_len(/*void*/)
{
    short           i, k, n, count;

    n = NC;
    while (n > 0 && c_len[n - 1] == 0)
        n--;
    putbits(CBIT, n);
    i = 0;
    while (i < n) {
        k = c_len[i++];
        if (k == 0) {
            count = 1;
            while (i < n && c_len[i] == 0) {
                i++;
                count++;
            }
            if (count <= 2) {
                for (k = 0; k < count; k++)
                    putcode(pt_len[0], pt_code[0]);
            }
            else if (count <= 18) {
                putcode(pt_len[1], pt_code[1]);
                putbits(4, count - 3);
            }
            else if (count == 19) {
                putcode(pt_len[0], pt_code[0]);
                putcode(pt_len[1], pt_code[1]);
                putbits(4, 15);
            }
            else {
                putcode(pt_len[2], pt_code[2]);
                putbits(CBIT, count - 20);
            }
        }
        else
            putcode(pt_len[k + 2], pt_code[k + 2]);
    }
}

/* ------------------------------------------------------------------------ */
static void
encode_c(short c)
{
    putcode(c_len[c], c_code[c]);
}

/* ------------------------------------------------------------------------ */
static void
encode_p(unsigned int p)
{
    unsigned short c;
    unsigned int q;

    c = 0;
    q = p;
    while (q) {
        q >>= 1;
        c++;
    }
    putcode(pt_len[c], pt_code[c]);
    if (c > 17) {
        /* bitio の入出力単位は 16 bit。上位から分割して出力する。 */
        putbits(c - 17, (unsigned short)(p >> 16));
        putbits(16, (unsigned short)p);
    } else if (c > 1)
        putbits(c - 1, (unsigned short)p);
}

/* ------------------------------------------------------------------------ */
static void
send_block( /* void */ )
{
    unsigned char   flags;
    unsigned short  i, root, pos, size;
    unsigned int k;

    root = make_tree(NC, c_freq, c_len, c_code);
    size = c_freq[root];
    putbits(16, size);
    if (root >= NC) {
        count_t_freq();
        root = make_tree(NT, t_freq, pt_len, pt_code);
        if (root >= NT) {
            write_pt_len(NT, TBIT, 3);
        } else {
            putbits(TBIT, 0);
            putbits(TBIT, root);
        }
        write_c_len();
    } else {
        putbits(TBIT, 0);
        putbits(TBIT, 0);
        putbits(CBIT, 0);
        putbits(CBIT, root);
    }
    root = make_tree(np, p_freq, pt_len, pt_code);
    if (root >= np) {
        write_pt_len(np, pbit, -1);
    }
    else {
        putbits(pbit, 0);
        putbits(pbit, root);
    }
    pos = 0;
    for (i = 0; i < size; i++) {
        if (i % CHAR_BIT == 0)
            flags = buf[pos++];
        else
            flags <<= 1;
        if (flags & (1 << (CHAR_BIT - 1))) {
            encode_c(buf[pos++] + (1 << CHAR_BIT));
            k = dicbit > 16 ? (unsigned int)buf[pos++] << 16 : 0;
            k += (unsigned int)buf[pos++] << CHAR_BIT;
            k += buf[pos++];
            encode_p(k);
        } else
            encode_c(buf[pos++]);
        if (unpackable)
            return;
    }
    for (i = 0; i < NC; i++)
        c_freq[i] = 0;
    for (i = 0; i < np; i++)
        p_freq[i] = 0;
}

/* ------------------------------------------------------------------------ */
/* lh4, 5, 6, 7 */
void
output_st1(unsigned int c, unsigned int p)
{
    static unsigned short cpos;

    output_mask >>= 1;
    if (output_mask == 0) {
        output_mask = 1 << (CHAR_BIT - 1);
        if (output_pos >= bufsiz - (dicbit > 16 ? 4 : 3) * CHAR_BIT) {
            send_block();
            if (unpackable)
                return;
            output_pos = 0;
        }
        cpos = output_pos++;
        buf[cpos] = 0;
    }
    buf[output_pos++] = (unsigned char) c;
    c_freq[c]++;
    if (c >= (1 << CHAR_BIT)) {
        buf[cpos] |= output_mask;
        if (dicbit > 16)
            buf[output_pos++] = (unsigned char)(p >> 16);
        buf[output_pos++] = (unsigned char) (p >> CHAR_BIT);
        buf[output_pos++] = (unsigned char) p;
        c = 0;
        while (p) {
            p >>= 1;
            c++;
        }
        p_freq[c]++;
    }
}

/* ------------------------------------------------------------------------ */
unsigned char  *
alloc_buf( /* void */ )
{
    bufsiz = 16 * 1024 *2;  /* 65408U; */ /* t.okamoto */
    while ((buf = (unsigned char *) malloc(bufsiz)) == NULL) {
        bufsiz = (bufsiz / 10) * 9;
        if (bufsiz < 4 * 1024)
            fatal_error("Not enough memory");
    }
    return buf;
}

/* ------------------------------------------------------------------------ */
/* lh4, 5, 6, 7 */
void
encode_start_st1( /* void */ )
{
    int             i;

    switch (dicbit) {
    case LZHUFF4_DICBIT:
    case LZHUFF5_DICBIT: pbit = 4; np = LZHUFF5_DICBIT + 1; break;
    case 14:
    case LZHUFF6_DICBIT: pbit = 5; np = LZHUFF6_DICBIT + 1; break;
    case LZHUFF7_DICBIT: pbit = 5; np = LZHUFF7_DICBIT + 1; break;
    case 17:
    case 18:
    case LZHUFFX_DICBIT: pbit = 5; np = dicbit + 1; break;
    default:
        fatal_error("Cannot use %d bytes dictionary", 1 << dicbit);
    }

    for (i = 0; i < NC; i++)
        c_freq[i] = 0;
    for (i = 0; i < np; i++)
        p_freq[i] = 0;
    output_pos = output_mask = 0;
    init_putbits();
    init_code_cache();
    buf[0] = 0;
}

/* ------------------------------------------------------------------------ */
/* lh4, 5, 6, 7 */
void
encode_end_st1( /* void */ )
{
    if (!unpackable) {
        send_block();
        putbits(CHAR_BIT - 1, 0);   /* flush remaining bits */
    }
}

/* ------------------------------------------------------------------------ */
/*                              decoding                                    */
/* ------------------------------------------------------------------------ */
static void
read_pt_len(short nn, short nbit, short i_special)
{
    int           i, c, n;

    n = getbits(nbit);
    if (n == 0) {
        c = getbits(nbit);
        for (i = 0; i < nn; i++)
            pt_len[i] = 0;
        for (i = 0; i < 256; i++)
            pt_table[i] = c;
    }
    else {
        i = 0;
        while (i < MIN(n, NPT)) {
            c = peekbits(3);
            if (c != 7)
                fillbuf(3);
            else {
                unsigned short  mask = 1 << (16 - 4);
                while (mask & bitbuf) {
                    mask >>= 1;
                    c++;
                }
                fillbuf(c - 3);
            }

            pt_len[i++] = c;
            if (i == i_special) {
                c = getbits(2);
                while (--c >= 0 && i < NPT)
                    pt_len[i++] = 0;
            }
        }
        while (i < nn)
            pt_len[i++] = 0;
        make_table(nn, pt_len, 8, pt_table);
    }
}

/* ------------------------------------------------------------------------ */
static void
read_c_len( /* void */ )
{
    short           i, c, n;

    n = getbits(CBIT);
    if (n == 0) {
        c = getbits(CBIT);
        for (i = 0; i < NC; i++)
            c_len[i] = 0;
        for (i = 0; i < 4096; i++)
            c_table[i] = c;
    } else {
        i = 0;
        while (i < MIN(n,NC)) {
            c = pt_table[peekbits(8)];
            if (c >= NT) {
                unsigned short  mask = 1 << (16 - 9);
                do {
                    if (bitbuf & mask)
                        c = right[c];
                    else
                        c = left[c];
                    mask >>= 1;
                } while (c >= NT && (mask || c != left[c])); /* CVE-2006-4338 */
            }
            fillbuf(pt_len[c]);
            if (c <= 2) {
                if (c == 0)
                    c = 1;
                else if (c == 1)
                    c = getbits(4) + 3;
                else
                    c = getbits(CBIT) + 20;
                while (--c >= 0)
                    c_len[i++] = 0;
            }
            else
                c_len[i++] = c - 2;
        }
        while (i < NC)
            c_len[i++] = 0;
        make_table(NC, c_len, 12, c_table);
    }
}

/* ------------------------------------------------------------------------ */
/* LH 系と LX1 は文字符号の表と読み取りを共有する。 */
static unsigned short
decode_c_st1_symbol(void)
{
    unsigned short  j, mask;

    j = c_table[peekbits(12)];
    if (j < NC)
        fillbuf(c_len[j]);
    else {
        fillbuf(12);
        mask = 1 << (16 - 1);
        do {
            if (bitbuf & mask)
                j = right[j];
            else
                j = left[j];
            mask >>= 1;
        } while (j >= NC && (mask || j != left[j])); /* CVE-2006-4338 */
        fillbuf(c_len[j] - 12);
    }
    return j;
}

unsigned short
decode_c_st1(void)
{
    if (blocksize == 0) {
        blocksize = getbits(16);
        read_pt_len(NT, TBIT, 3);
        read_c_len();
        read_pt_len(np, pbit, -1);
    }
    blocksize--;
    return decode_c_st1_symbol();
}

/* LX1 の方式 1 は、128 個の上位位置符号を固定の長さで読む。 */
static void
read_lx1_fixed_positions(void)
{
    static const unsigned char boundaries[] = {1, 1, 3, 6, 13, 31, 78, 0};
    unsigned int i, boundary = 0;
    unsigned char length = 2;

    for (i = 0; i < 128; i++) {
        while (boundaries[boundary] == i) {
            length++;
            boundary++;
        }
        pt_len[i] = length;
    }
    make_table(128, pt_len, 8, pt_table);
}

static void
read_lx1_positions(void)
{
    int i, symbol;

    for (i = 0; i < 128; i++) {
        pt_len[i] = getbits(4);
        if (i == 2 && pt_len[0] == 1 && pt_len[1] == 1 && pt_len[2] == 1) {
            symbol = getbits(7);
            memset(pt_len, 0, 128);
            for (i = 0; i < 256; i++) pt_table[i] = symbol;
            return;
        }
    }
    make_table(128, pt_len, 8, pt_table);
}

unsigned short
decode_c_lx1(void)
{
    if (blocksize == 0) {
        blocksize = getbits(16);
        read_pt_len(NT, TBIT, 3);
        read_c_len();
        lx1_position_mode = getbits(2);
        // 方式 3 の内部ノードは 16 から始まる。他方式の 128 と混同しない。
        np = lx1_position_mode == 3 ? 16 : 128;
        switch (lx1_position_mode) {
        case 1: read_lx1_fixed_positions(); break;
        case 2: read_lx1_positions(); break;
        case 3: read_pt_len(16, 5, -1); break;
        }
    }
    blocksize--;
    return decode_c_st1_symbol();
}

unsigned short
decode_p_lx1(void)
{
    unsigned short symbol, mask;

    if (lx1_position_mode == 0) return getbits(15);
    if (lx1_position_mode == 3) return decode_p_st1();
    symbol = pt_table[peekbits(8)];
    if (symbol < 128) {
        fillbuf(pt_len[symbol]);
    } else {
        fillbuf(8);
        mask = 1U << 15;
        do {
            if (symbol >= 2 * NC - 1 || mask == 0)
                fatal_error("Invalid LX1 position code");
            symbol = bitbuf & mask ? right[symbol] : left[symbol];
            mask >>= 1;
        } while (symbol >= 128);
        fillbuf(pt_len[symbol] - 8);
    }
    return (symbol << 8) + getbits(8);
}

void
decode_start_lx1(void)
{
    np = 128;
    lx1_position_mode = 0;
    init_getbits();
    init_code_cache();
    blocksize = 0;
}

/* ------------------------------------------------------------------------ */
/* lh4, 5, 6, 7 */
unsigned short
decode_p_st1( /* void */ )
{
    return (unsigned short)decode_p_st1_wide();
}

unsigned int
decode_p_st1_wide(void)
{
    unsigned short  j, mask;
    unsigned int extra;

    j = pt_table[peekbits(8)];
    if (j < np)
        fillbuf(pt_len[j]);
    else {
        fillbuf(8);
        mask = 1 << (16 - 1);
        do {
            if (bitbuf & mask)
                j = right[j];
            else
                j = left[j];
            mask >>= 1;
        } while (j >= np && (mask || j != left[j])); /* CVE-2006-4338 */
        fillbuf(pt_len[j] - 8);
    }
    if (j >= np)
        fatal_error("Invalid position code");
    if (j == 0) return 0;
    if (j > 17) {
        extra = (unsigned int)getbits(j - 17) << 16;
        extra += getbits(16);
    } else {
        extra = getbits(j - 1);
    }
    return (1U << (j - 1)) + extra;
}

/* ------------------------------------------------------------------------ */
/* lh4, 5, 6, 7 */
void
decode_start_st1( /* void */ )
{
    switch (dicbit) {
    case LZHUFF4_DICBIT:
    case LZHUFF5_DICBIT: pbit = 4; np = LZHUFF5_DICBIT + 1; break;
    case 14:
    case LZHUFF6_DICBIT: pbit = 5; np = LZHUFF6_DICBIT + 1; break;
    case LZHUFF7_DICBIT: pbit = 5; np = LZHUFF7_DICBIT + 1; break;
    case 17:
    case 18:
    case LZHUFFX_DICBIT: pbit = 5; np = dicbit + 1; break;
    default:
        fatal_error("Cannot use %d bytes dictionary", 1 << dicbit);
    }

    init_getbits();
    init_code_cache();
    blocksize = 0;
}
