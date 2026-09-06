/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              slide.c -- sliding dictionary with percolating update       */
/*                                                                          */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14d  Exchanging a search algorithm  1997.01.11    T.Okamoto      */
/* ------------------------------------------------------------------------ */

#if 0
#define DEBUG 1
#endif

#include "lha.h"

#ifdef DEBUG
FILE *fout = NULL;
static int noslide = 1;
#endif

/* variables for hash */
struct hash {
    unsigned int pos;
    int too_flag;               /* if 1, matching candidate is too many */
} *hash;
static unsigned int *prev;      /* previous posiion associated with hash */

/* hash function: it represents 3 letters from `pos' on `text' */
#define INIT_HASH(pos) \
        ((( (text[(pos)] << 5) \
           ^ text[(pos) + 1]  ) << 5) \
           ^ text[(pos) + 2]         ) & (unsigned)(HSHSIZ - 1);
#define NEXT_HASH(hash,pos) \
        (((hash) << 5) \
           ^ text[(pos) + 2]         ) & (unsigned)(HSHSIZ - 1);

static struct encode_option encode_define[6] = {
#if defined(__STDC__) || defined(AIX) || defined(_MSC_VER)
    /* lh1 */
    { (void (*) (void)) output_dyn,
     (void (*) (void)) encode_start_fix,
     (void (*) (void)) encode_end_dyn},
    /* lh4, 5, 6, 7 */
    { (void (*) (void)) output_st1,
     (void (*) (void)) encode_start_st1,
     (void (*) (void)) encode_end_st1},
    /* lzs */
    { (void (*) (void)) output_lzs,
     (void (*) (void)) encode_start_lzs,
     (void (*) (void)) encode_end_lzs},
    /* lh2 */
    { (void (*) (void)) output_dyn2,
     (void (*) (void)) encode_start_dyn,
     (void (*) (void)) encode_end_dyn},
    /* lz5 */
    { (void (*) (void)) output_lz5,
     (void (*) (void)) encode_start_lz5,
     (void (*) (void)) encode_end_lz5},
    /* lh3 */
    { (void (*) (void)) output_st0,
     (void (*) (void)) encode_start_st0,
     (void (*) (void)) encode_end_st0}
#else
    /* lh1 */
    {(void (*) (void)) output_dyn,
     (void (*) (void)) encode_start_fix,
     (void (*) (void)) encode_end_dyn},
    /* lh4, 5, 6, 7 */
    {(void (*) (void)) output_st1,
     (void (*) (void)) encode_start_st1,
     (void (*) (void)) encode_end_st1},
    /* lzs */
    {(void (*) (void)) output_lzs,
     (void (*) (void)) encode_start_lzs,
     (void (*) (void)) encode_end_lzs},
    /* lh2 */
    {(void (*) (void)) output_dyn2,
     (void (*) (void)) encode_start_dyn,
     (void (*) (void)) encode_end_dyn},
    /* lz5 */
    {(void (*) (void)) output_lz5,
     (void (*) (void)) encode_start_lz5,
     (void (*) (void)) encode_end_lz5},
    /* lh3 */
    {(void (*) (void)) output_st0,
     (void (*) (void)) encode_start_st0,
     (void (*) (void)) encode_end_st0}
#endif
};

static struct decode_option decode_define[] = {
    /* lh1 */
    {decode_c_dyn, decode_p_st0, decode_start_fix},
    /* lh2 */
    {decode_c_dyn, decode_p_dyn, decode_start_dyn},
    /* lh3 */
    {decode_c_st0, decode_p_st0, decode_start_st0},
    /* lh4 */
    {decode_c_st1, decode_p_st1, decode_start_st1},
    /* lh5 */
    {decode_c_st1, decode_p_st1, decode_start_st1},
    /* lh6 */
    {decode_c_st1, decode_p_st1, decode_start_st1},
    /* lh7 */
    {decode_c_st1, decode_p_st1, decode_start_st1},
    /* lzs */
    {decode_c_lzs, decode_p_lzs, decode_start_lzs},
    /* lz5 */
    {decode_c_lz5, decode_p_lz5, decode_start_lz5},
    /* lz4 */
    {NULL        , NULL        , NULL            },
    /* lhd */
    {NULL        , NULL        , NULL            },
    /* pm0 */
    {NULL        , NULL        , NULL            },
    /* pm2 */
    {decode_c_pm2, decode_p_pm2, decode_start_pm2},
    /* lhx: 位置だけは decode_p_st1_wide を直接使う。 */
    {decode_c_st1, NULL, decode_start_st1},
    /* lx1 */
    {decode_c_lx1, decode_p_lx1, decode_start_lx1}
};

static struct encode_option encode_set;
static struct decode_option decode_set;

#define HSHSIZ (((unsigned long)1) <<15)
#define NIL 0
#define LIMIT 0x100             /* limit of hash chain */

static unsigned int txtsiz;
static unsigned long dicsiz;
static unsigned long allocated_dicsiz;
static unsigned int remainder;

struct matchdata {
    int len;
    unsigned int off;
};

int
encode_alloc(int method)
{
    unsigned long capacity;
    int requested_bits;
    switch (method) {
    case LZHUFF1_METHOD_NUM:
        encode_set = encode_define[0];
        maxmatch = 60;
        dicbit = LZHUFF1_DICBIT;    /* 12 bits  Changed N.Watazaki */
        break;
    case LZHUFF2_METHOD_NUM:
        encode_set = encode_define[3];
        maxmatch = MAXMATCH;
        dicbit = LZHUFF2_DICBIT;
        break;
    case LZHUFF3_METHOD_NUM:
        encode_set = encode_define[5];
        maxmatch = MAXMATCH;
        dicbit = LZHUFF3_DICBIT;
        break;
    case LZHUFF5_METHOD_NUM:
        encode_set = encode_define[1];
        maxmatch = MAXMATCH;
        dicbit = LZHUFF5_DICBIT;    /* 13 bits */
        break;
    case LZHUFF6_METHOD_NUM:
        encode_set = encode_define[1];
        maxmatch = MAXMATCH;
        dicbit = LZHUFF6_DICBIT;    /* 15 bits */
        break;
    case LZHUFF7_METHOD_NUM:
        encode_set = encode_define[1];
        maxmatch = MAXMATCH;
        dicbit = LZHUFF7_DICBIT;    /* 16 bits */
        break;
    case LZHUFFX_METHOD_NUM:
        encode_set = encode_define[1];
        maxmatch = MAXMATCH;
        dicbit = LZHUFFX_DICBIT;
        break;
    case LARC_METHOD_NUM:
        encode_set = encode_define[2];
        maxmatch = 17;
        dicbit = LARC_DICBIT;
        break;
    case LARC5_METHOD_NUM:
        encode_set = encode_define[4];
        maxmatch = 17;
        dicbit = LARC5_DICBIT;
        break;
    default:
        error("unknown method %d", method);
        exit(1);
    }

    requested_bits = Lha_GetDictionaryBits();
    if ((method == LZHUFF5_METHOD_NUM && requested_bits >= 12 && requested_bits <= 13) ||
        (method == LZHUFF6_METHOD_NUM && requested_bits >= 14 && requested_bits <= 15) ||
        (method == LZHUFF7_METHOD_NUM && requested_bits >= 15 && requested_bits <= 16) ||
        (method == LZHUFFX_METHOD_NUM && requested_bits >= 17 && requested_bits <= 19))
        dicbit = requested_bits;
    dicsiz = (((unsigned long)1) << dicbit);
    txtsiz = dicsiz*2+maxmatch;

    if (!hash) {
        alloc_buf();
        hash = (struct hash*)xmalloc(HSHSIZ * sizeof(struct hash));
    }
    /* 通常方式は従来サイズ。大辞書を要求されたときだけ伸長して再利用する。 */
    capacity = dicsiz > MAX_DICSIZ ? dicsiz : MAX_DICSIZ;
    if (capacity > allocated_dicsiz) {
        prev = (unsigned int*)xrealloc(prev, capacity * sizeof(unsigned int));
        text = (unsigned char*)xrealloc(text, capacity * 2L + MAXMATCH);
        allocated_dicsiz = capacity;
    }

    return method;
}

static void
init_slide()
{
    unsigned int i;

    for (i = 0; i < HSHSIZ; i++) {
        hash[i].pos = NIL;
        hash[i].too_flag = 0;
    }
}

/* update dictionary */
static void
update_dict(unsigned int *pos, unsigned int *crc)
{
    unsigned int i, j;
    long n;

    memmove(&text[0], &text[dicsiz], txtsiz - dicsiz);

    n = fread_crc(crc, &text[txtsiz - dicsiz], dicsiz, infile);

    remainder += n;

    *pos -= dicsiz;
    for (i = 0; i < HSHSIZ; i++) {
        j = hash[i].pos;
        hash[i].pos = (j > dicsiz) ? j - dicsiz : NIL;
    }
    for (i = 0; i < dicsiz; i++) {
        j = prev[i];
        prev[i] = (j > dicsiz) ? j - dicsiz : NIL;
    }
}

/* associate position with token */
static void
insert_hash(unsigned int token, unsigned int pos)
{
    prev[pos & (dicsiz - 1)] = hash[token].pos; /* chain the previous pos. */
    hash[token].pos = pos;
}

static void
search_dict_1(unsigned int token, unsigned int pos, unsigned int off,
              unsigned int max,  /* max. length of matching string */
              struct matchdata *m)
{
    unsigned int chain = 0;
    unsigned int scan_pos = hash[token].pos;
    int scan_beg = scan_pos - off;
    int scan_end = pos - dicsiz;
    unsigned int len;

    /* 原版は 256 番目の候補へ進む前に探索を打ち切る。 */
    while (scan_beg > scan_end && ++chain < LIMIT) {

        if (text[scan_beg + m->len] == text[pos + m->len]) {
            {
                /* collate token */
                unsigned char *a = &text[scan_beg];
                unsigned char *b = &text[pos];

                for (len = 0; len < max && *a++ == *b++; len++);
            }

            if (len > (unsigned int)m->len) {
                m->off = pos - scan_beg;
                m->len = len;
                if (m->len == max)
                    break;

#ifdef DEBUG
                if (noslide) {
                    if (pos - m->off < dicsiz) {
                        printf("matchpos=%u scan_pos=%u dicsiz=%u\n",
                               pos - m->off, scan_pos, dicsiz);
                    }
                }
#endif
            }
        }
        scan_pos = prev[scan_pos & (dicsiz - 1)];
        scan_beg = scan_pos - off;
    }

    if (chain >= LIMIT)
        hash[token].too_flag = 1;
    else if (scan_beg <= scan_end)
        hash[token].too_flag = 0;
}

/* search the longest token matching to current token */
static void
search_dict(unsigned int token,  /* search token */
            unsigned int pos,    /* position of token */
            struct matchdata *m)
{
    unsigned int off, tok, max;

    max = maxmatch;
    m->off = 0;
    m->len = THRESHOLD - 1;

    off = 0;
    for (tok = token; hash[tok].too_flag && off < (unsigned int)(maxmatch - THRESHOLD); ) {
        /* If matching position is too many, The search key is
           changed into following token from `off' (for speed). */
        ++off;
        tok = NEXT_HASH(tok, pos+off);
    }
    if (off == maxmatch - THRESHOLD) {
        off = 0;
        tok = token;
    }

    search_dict_1(tok, pos, off, max, m);

    if (off > 0 && (unsigned int)m->len < off + 3)
        /* re-search */
        search_dict_1(token, pos, 0, off+2, m);

    if ((unsigned int)m->len > remainder) m->len = (int)remainder;
}

/* slide dictionary */
static void
next_token(unsigned int *token, unsigned int *pos, unsigned int *crc)
{
    remainder--;
    if (++*pos >= txtsiz - maxmatch) {
        update_dict(pos, crc);
#ifdef DEBUG
        noslide = 0;
#endif
    }
    *token = NEXT_HASH(*token, *pos);
}

unsigned int
encode(struct interfacing *iface)
{
    unsigned int token, pos, crc;
    off_t count;
    off_t progress_checked = 0;
    off_t progress_threshold;
    unsigned long progress_tick;
    struct matchdata match, last;

#ifdef DEBUG
    if (!fout)
        fout = xfopen("en", "wt");
    fprintf(fout, "[filename: %s]\n", reading_filename);
#endif
    infile = iface->infile;
    outfile = iface->outfile;
    origsize = iface->original;
    compsize = count = 0L;
    unpackable = 0;

    INITIALIZE_CRC(crc);

    init_slide();

    encode_set.encode_start();
    memset(text, ' ', txtsiz);

    remainder = fread_crc(&crc, &text[dicsiz], txtsiz-dicsiz, infile);

    match.len = THRESHOLD - 1;
    match.off = 0;
    if (match.len > remainder) match.len = remainder;

    pos = dicsiz;
    token = INIT_HASH(pos);
    /* 原版は入力位置 0 を辞書へ登録せず、位置 1 から参照候補を蓄積する。 */
    progress_threshold = origsize > 13107200 ? 131072 : origsize > 409600 ? origsize / 100 : 4096;
    progress_tick = Lha_GetProgressTickCount();

    while (remainder > 0 && ! unpackable) {
        if (Lha_CheckAbort()) fatal_error("User cancelled.");
        // 処理量の閾値を越えた時点だけ時計を調べ、33 ms 超で互換通知を送る。
        if (count - progress_checked > progress_threshold) {
            progress_checked = count;
            if ((unsigned long)(Lha_GetProgressTickCount() - progress_tick) > 33) {
                if (Lha_SendCompatProgressMessage(1, NULL, count, origsize))
                    fatal_error("User cancelled.");
                Lha_WaitAfterCompressionProgress();
                progress_tick = Lha_GetProgressTickCount();
            }
        }
        last = match;

        next_token(&token, &pos, &crc);
        search_dict(token, pos, &match);
        insert_hash(token, pos);

        /* 原版は長さだけでなく距離の符号化コストも見て、次位置の一致を選ぶ。 */
        if (match.len > last.len + 1 ||
            (match.len == last.len + 1 && match.off < (last.off - 1) * 256U) ||
            (match.len == last.len && match.len >= THRESHOLD &&
             match.off * 16U <= last.off - 1) ||
            last.len < THRESHOLD) {
            /* output a letter */
            encode_set.output(text[pos - 1], 0);
#ifdef DEBUG
            fprintf(fout, "%u C %02X\n", count, text[pos-1]);
#endif
            count++;
        } else {
            /* output length and offset */
            encode_set.output(last.len + (256 - THRESHOLD),
                              (last.off-1) & (dicsiz-1) );

#ifdef DEBUG
            {
                int i;
                unsigned char *ptr;
                unsigned int offset = (last.off & (dicsiz-1));

                fprintf(fout, "%u M <%u %u> ",
                        count, last.len, count - offset);

                ptr = &text[pos-1 - offset];
                for (i=0; i < last.len; i++)
                    fprintf(fout, "%02X ", ptr[i]);
                fprintf(fout, "\n");
            }
#endif
            count += last.len;

            --last.len;
            while (--last.len > 0) {
                next_token(&token, &pos, &crc);
                insert_hash(token, pos);
            }
            next_token(&token, &pos, &crc);
            search_dict(token, pos, &match);
            insert_hash(token, pos);
        }
    }
    encode_set.encode_end();

    iface->packed = compsize;
    iface->original = count;

    return crc;
}

unsigned int
decode(struct interfacing *iface)
{
    unsigned int i, c;
    unsigned int dicsiz1, adjust;
    unsigned int crc;

#ifdef DEBUG
    if (!fout)
        fout = xfopen("de", "wt");
    fprintf(fout, "[filename: %s]\n", writing_filename);
#endif

    infile = iface->infile;
    outfile = iface->outfile;
    dicbit = iface->dicbit;
    origsize = iface->original;
    compsize = iface->packed;
    Lha_StartProgressDecoder(iface->packed);
    decode_set = decode_define[iface->method - 1];

    INITIALIZE_CRC(crc);
    dicsiz = 1L << dicbit;
    dtext = (unsigned char *)xmalloc(dicsiz);

    if (extract_broken_archive)

        /* LHa for UNIX (autoconf) had a fatal bug since version
           1.14i-ac20030713 (slide.c revision 1.20).

           This bug is possible to make a broken archive, proper LHA
           cannot extract it (probably it report CRC error).

           If the option "--extract-broken-archive" specified, extract
           the broken archive made by old LHa for UNIX. */
        memset(dtext, 0, dicsiz);
    else
        memset(dtext, ' ', dicsiz);
    decode_set.decode_start();
    dicsiz1 = dicsiz - 1;
    adjust = 256 - THRESHOLD;
    if ((iface->method == LARC_METHOD_NUM) || (iface->method == PMARC2_METHOD_NUM))
        adjust = 256 - 2;

    decode_count = 0;
    loc = 0;
    while (decode_count < origsize) {
        if (Lha_CheckAbort()) fatal_error("User cancelled.");
        c = decode_set.decode_c();
        if (c < 256) {
            if (dump_lzss) {
#if SIZEOF_OFF_T == 8
                printf("%04llu %02x(%c)\n",
                       decode_count, c, isprint(c) ? c : '?');
#else
                printf("%04lu %02x(%c)\n",
                       decode_count, c, isprint(c) ? c : '?');
#endif
            }
            dtext[loc++] = c;
            if (loc == dicsiz) {
                fwrite_crc(&crc, dtext, dicsiz, outfile);
                loc = 0;
            }
            decode_count++;
        }
        else {
            struct matchdata match;
            unsigned int matchpos;

            match.len = c - adjust;
            match.off = (iface->method == LZHUFFX_METHOD_NUM
                ? decode_p_st1_wide() : decode_set.decode_p()) + 1;
            /* 壊れた入力の一致長が宣言された展開サイズを越えても、原版は末尾で打ち切る。 */
            if ((off_t)match.len > origsize - decode_count)
                match.len = (int)(origsize - decode_count);
            matchpos = (loc - match.off) & dicsiz1;
            if (dump_lzss) {
#if SIZEOF_OFF_T == 8
                printf("%04llu <%u %llu>\n",
                       decode_count, match.len, decode_count-match.off);
#else
                printf("%04lu <%u %lu>\n",
                       decode_count, match.len, decode_count-match.off);
#endif
            }

            decode_count += match.len;
            for (i = 0; i < (unsigned int)match.len; i++) {
                c = dtext[(matchpos + i) & dicsiz1];
                /*
                if (dump_lzss) {
                    printf(" %02x", c & 0xff);
                }
                */
                dtext[loc++] = c;
                if (loc == dicsiz) {
                    fwrite_crc(&crc, dtext, dicsiz, outfile);
                    loc = 0;
                }
            }
            /*
            if (dump_lzss) {
                printf("\n");
            }
            */
        }
    }
    if (loc != 0) {
        fwrite_crc(&crc, dtext, loc, outfile);
    }

    free(dtext);
    /* 呼び出し側の異常終了処理でも解放状態を判別できるようにする。 */
    dtext = NULL;

    /* usually read size is iface->packed */
    iface->read_size = iface->packed - compsize;

    return crc;
}
