/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              lhext.c -- LHarc extract                                    */
/*                                                                          */
/*      Copyright (C) MCMLXXXIX Yooichi.Tagawa                              */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 0.00  Original                             1988.05.23  Y.Tagawa    */
/*  Ver. 1.00  Fixed                                1989.09.22  Y.Tagawa    */
/*  Ver. 0.03  LHa for UNIX                         1991.12.17  M.Oki       */
/*  Ver. 1.12  LHa for UNIX                         1993.10.01  N.Watazaki  */
/*  Ver. 1.13b Symbolic Link Update Bug Fix         1994.06.21  N.Watazaki  */
/*  Ver. 1.14  Source All chagned                   1995.01.14  N.Watazaki  */
/*  Ver. 1.14e bugfix                               1999.04.30  T.Okamoto   */
/* ------------------------------------------------------------------------ */
#include "lha.h"
/* ------------------------------------------------------------------------ */
static int      skip_flg = FALSE;   /* FALSE..No Skip , TRUE..Skip */
static char    *methods[] =
{
    LZHUFF0_METHOD, LZHUFF1_METHOD, LZHUFF2_METHOD, LZHUFF3_METHOD,
    LZHUFF4_METHOD, LZHUFF5_METHOD, LZHUFF6_METHOD, LZHUFF7_METHOD,
    LARC_METHOD, LARC5_METHOD, LARC4_METHOD,
    LZHDIRS_METHOD,
    PMARC0_METHOD, PMARC2_METHOD, LZHUFFX_METHOD, LZHUFFLX1_METHOD,
    NULL
};

static void add_dirinfo(char* name, LzHeader* hdr);
static void adjust_dirinfo();

#ifdef HAVE_LIBAPPLEFILE
static boolean decode_macbinary(FILE *ofp, off_t size, const char *outPath);
#endif

/* ------------------------------------------------------------------------ */
static          boolean
inquire_extract(char *name)
{
    struct stat     stbuf;

    skip_flg = FALSE;
    if (GETSTAT(name, &stbuf) >= 0) {
        if (!is_regularfile(&stbuf) && !is_symlink(&stbuf)) {
            error("\"%s\" already exists (not a file)", name);
            return FALSE;
        }

        if (noexec) {
            printf("EXTRACT %s but file is exist.\n", name);
            return FALSE;
        }
        else if (!force) {
            fatal_error("同名ファイルがあるので書き込めません。\n%s\n", name);
            return FALSE;
        }
        else {
            // 既存ファイルが読み取り専用（ReadOnly）の場合に備え、書き込み権限（0666）を与えて上書き可能にする
            chmod(name, 0666);
        }
    }

    if (noexec)
        printf("EXTRACT %s\n", name);

    return TRUE;
}

static boolean
make_name_with_pathcheck(char *name, size_t namesz, const char *q)
{
    int offset = 0;
    int sz;
#ifdef S_IFLNK
    const char *p;
    struct stat stbuf;
#endif

    if (extract_directory) {
        sz = xsnprintf(name, namesz, "%s/", extract_directory);
        if (sz == -1) {
            return FALSE;
        }
        offset = sz;
    }

#ifdef S_IFLNK
    while ((p = strchr(q, '/')) != NULL) {
        if (namesz - offset < (p - q) + 2) {
            return FALSE;
        }
        memcpy(name + offset, q, (p - q));
        name[offset + (p - q)] = 0;

        offset += (p - q);
        q = p + 1;

        if (lstat(name, &stbuf) < 0) {
            name[offset++] = '/';
            break;
        }
        if (is_symlink(&stbuf)) {
            return FALSE;
        }
        name[offset++] = '/';
    }
#endif

    str_safe_copy(name + offset, q, namesz - offset);

    return TRUE;
}

/* ------------------------------------------------------------------------ */
static          boolean
make_parent_path(const char *name)
{
    char            path[FILENAME_LENGTH];
    struct stat     stbuf;
    register char  *p;

    /* make parent directory name into PATH for recursive call */
    str_safe_copy(path, name, sizeof(path));
    for (p = path + strlen(path); p > path; p--)
        if (p[-1] == '/') {
            *--p = '\0';
            break;
        }

    if (p == path) {
        message("invalid path name \"%s\"", name);
        return FALSE;   /* no more parent. */
    }

    if (GETSTAT(path, &stbuf) >= 0) {
        if (is_directory(&stbuf))
            return TRUE;
    }

    if (verbose)
        message("Making directory \"%s\".", path);

#if defined __MINGW32__
    if (mkdir(path) >= 0) {
        Lha_RecordCommandEvent("mkdir", path, 0);
        return TRUE;
    }
#else
    if (mkdir(path, 0777) >= 0) { /* try */
        Lha_RecordCommandEvent("mkdir", path, 0);
        return TRUE;    /* successful done. */
    }
#endif

    if (!make_parent_path(path))
        return FALSE;

#if defined __MINGW32__
    if (mkdir(path) < 0) {      /* try again */
        error("Cannot make directory \"%s\"", path);
        return FALSE;
    }
    Lha_RecordCommandEvent("mkdir", path, 0);
#else
    if (mkdir(path, 0777) < 0) {    /* try again */
        error("Cannot make directory \"%s\"", path);
        return FALSE;
    }
    Lha_RecordCommandEvent("mkdir", path, 0);
#endif

    return TRUE;
}

/* ------------------------------------------------------------------------ */
static FILE    *
open_with_make_path(char *name)
{
    FILE           *fp;

    if ((fp = fopen(name, WRITE_BINARY)) == NULL) {
        if (!make_parent_path(name) ||
            (fp = fopen(name, WRITE_BINARY)) == NULL)
            error("Cannot extract a file \"%s\"", name);
    }
    return fp;
}

/* ------------------------------------------------------------------------ */
static int
symlink_with_make_path(const char *realname, const char *name)
{
    int l_code = -1;
#ifdef S_IFLNK
    l_code = symlink(realname, name);
    if (l_code < 0) {
        make_parent_path(name);
        l_code = symlink(realname, name);
    }
#endif
    return l_code;
}

/* ------------------------------------------------------------------------ */
static void
adjust_info(char *name, LzHeader *hdr)
{
#if defined(_WIN32)
    /* Windows環境ではutime/utimesがディレクトリのタイムスタンプを変更できないため、 */
    /* CreateFileとSetFileTimeを使用してタイムスタンプを復元する */
    if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) != UNIX_FILE_SYMLINK) {
        extern int win32_set_file_time(const char *name, time_t t, const LzHeader *header);
        win32_set_file_time(name, hdr->unix_last_modified_stamp, hdr);
    }
#elif HAVE_UTIMES
    struct timeval timevals[2];

    /* adjust file stamp */
    timevals[0].tv_sec = timevals[1].tv_sec = hdr->unix_last_modified_stamp;
    timevals[0].tv_usec = timevals[1].tv_usec = 0;

    if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) != UNIX_FILE_SYMLINK)
        utimes(name, timevals);
#else
    struct utimbuf utimebuf;

    /* adjust file stamp */
    utimebuf.actime = utimebuf.modtime = hdr->unix_last_modified_stamp;

    if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) != UNIX_FILE_SYMLINK)
        utime(name, &utimebuf);
#endif

    if (hdr->extend_type == EXTEND_UNIX
        || hdr->extend_type == EXTEND_OS68K
        || hdr->extend_type == EXTEND_XOSK) {

        if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) != UNIX_FILE_SYMLINK) {
            chmod(name, hdr->unix_mode);
        }

        if (!getuid()){
            uid_t uid = hdr->unix_uid;
            gid_t gid = hdr->unix_gid;

#if HAVE_GETPWNAM && HAVE_GETGRNAM
            if (hdr->user[0]) {
                struct passwd *ent = getpwnam(hdr->user);
                if (ent) uid = ent->pw_uid;
            }
            if (hdr->group[0]) {
                struct group *ent = getgrnam(hdr->group);
                if (ent) gid = ent->gr_gid;
            }
#endif

#if HAVE_LCHOWN
            if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_SYMLINK)
                lchown(name, uid, gid);
            else
#endif /* HAVE_LCHWON */
                chown(name, uid, gid);
        }
    }
#if __CYGWIN__
    else {
        /* On Cygwin, execute permission should be set for .exe or .dll. */
        mode_t m;

        umask(m = umask(0));    /* get current umask */
        chmod(name, 0777 & ~m);
    }
#endif
}

/* ------------------------------------------------------------------------ */
static off_t
extract_one(FILE *afp,  /* archive file */
            LzHeader *hdr, off_t data_start)
{
    g_infp = afp;
    FILE           *fp; /* output file */
#if HAVE_LIBAPPLEFILE
    FILE           *tfp; /* temporary output file */
#endif
    struct stat     stbuf;
    char            name[FILENAME_LENGTH];
    unsigned int crc;
    int             method;
    boolean         save_quiet, save_verbose, up_flag;
    char            member_path[FILENAME_LENGTH];
    char           *q = member_path, c;
    off_t read_size = 0;

    /* 原版は項目開始の進捗後、列挙・本文処理より前に非対応方式を読み飛ばす。 */
    if ((output_to_stdout || verify_mode) &&
        (memcmp(hdr->method, PMARC0_METHOD, 5) == 0 ||
         memcmp(hdr->method, PMARC2_METHOD, 5) == 0)) {
        Lha_RecordHeaderCommandEvent("UnsupportedMethod", hdr, hdr->method[3] - '0');
        return read_size;
    }

    if (!Lha_GetHeaderPath(hdr, member_path, sizeof(member_path)))
        fatal_error("File name is too long");
    if (ignore_directory && strrchr(member_path, '/')) {
        q = (char *) strrchr(member_path, '/') + 1;
    }
    else {
        if (is_directory_traversal(q)) {
            error("Possible directory traversal hack attempt in %s", q);
            exit(1);
        }

        if (*q == '/') {
            while (*q == '/') { q++; }

            /*
             * if OSK then strip device name
             */
            if (hdr->extend_type == EXTEND_OS68K
                || hdr->extend_type == EXTEND_XOSK) {
                do
                    c = (*q++);
                while (c && c != '/');
                if (!c || !*q)
                    q = ".";    /* if device name only */
            }
        }
    }

    if (!make_name_with_pathcheck(name, sizeof(name), q)) {
        error("Possible symlink traversal hack attempt in %s", q);
        exit(1);
    }

    if (!Lha_InvokeEnumMember(hdr, name, sizeof(name))) {
        return read_size;
    }
    Lha_SetProgressDestination(name);

    /* LZHDIRS_METHODを持つヘッダをチェックする */
    /* 1999.4.30 t.okamoto */
    for (method = 0;; method++) {
        if (methods[method] == NULL) {
            error("Unknown method \"%.*s\"; \"%s\" will be skipped ...",
                  5, hdr->method, name);
            return read_size;
        }
        if (memcmp(hdr->method, methods[method], 5) == 0)
            break;
    }

    if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_REGULAR
        && method != LZHDIRS_METHOD_NUM) {
    extract_regular:
#if 0
        for (method = 0;; method++) {
            if (methods[method] == NULL) {
                error("Unknown method \"%.*s\"; \"%s\" will be skipped ...",
                      5, hdr->method, name);
                return read_size;
            }
            if (memcmp(hdr->method, methods[method], 5) == 0)
                break;
        }
#endif

        reading_filename = archive_name;
        writing_filename = name;
        if (output_to_stdout || verify_mode) {
            /* "Icon\r" should be a resource fork file encoded in MacBinary
               format, so that it should be skipped. */
            if (hdr->extend_type == EXTEND_MACOS
                && strcmp(basename(name), "Icon\r") == 0
                && decode_macbinary_contents) {
                return read_size;
            }

            if (noexec) {
                printf("%s %s\n", verify_mode ? "VERIFY" : "EXTRACT", name);
                return read_size;
            }

            save_quiet = quiet;
            save_verbose = verbose;
            if (!quiet && output_to_stdout) {
                quiet = TRUE;
                verbose = FALSE;
            }
            else if (verify_mode) {
                quiet = FALSE;
                verbose = TRUE;
            }

#if defined(__MINGW32__) || defined(__DJGPP__)
            {
                int old_mode;
                fflush(stdout);
                old_mode = setmode(fileno(stdout), O_BINARY);
#endif

            if (output_to_stdout) {
                unsigned char capture_buffer[32768];
                FILE *capture_file = Lha_TemporaryFile();
                size_t captured;
                if (!capture_file)
                    fatal_error("Cannot create temporary output file");
                /* 深い復号処理から中断しても、共通 cleanup が一時出力を閉じる。 */
                g_outfp = capture_file;
                crc = decode_lzhuf(afp, capture_file,
                                   hdr->original_size, hdr->packed_size,
                                   name, method, &read_size);
                if (fflush(capture_file) != 0 || fseek(capture_file, 0, SEEK_SET) != 0) {
                    fatal_error("File write error");
                }
                while ((captured = fread(capture_buffer, 1, sizeof(capture_buffer),
                                         capture_file)) != 0) {
                    lha_capture_bytes(capture_buffer, captured);
                }
                if (ferror(capture_file)) {
                    fatal_error("File read error");
                }
                g_outfp = NULL;
                fclose(capture_file);
                /* 原版の格納方式デコーダーは各項目を NUL で区切る。
                 * 処理は後続項目へ続くが、返却文字列は最初の NUL で終わる。 */
                if (method == LZHUFF0_METHOD_NUM || method == LARC4_METHOD_NUM) {
                    if (hdr->original_size != 0) lha_capture_bytes("\0", 1);
                } else {
                    lha_capture_bytes("\r\n", 2);
                }
            } else {
#if HAVE_LIBAPPLEFILE
                /* On default, MacLHA encodes into MacBinary. */
                if (hdr->extend_type == EXTEND_MACOS && !verify_mode && decode_macbinary_contents) {
                    tfp = NULL;
                    tfp = build_temporary_file();
                    crc = decode_lzhuf(afp, tfp,
                                       hdr->original_size, hdr->packed_size,
                                       name, method, &read_size);
                    fclose(tfp);
                    decode_macbinary(stdout, hdr->original_size, name);
                    unlink(temporary_name);
                } else {
                    crc = decode_lzhuf(afp, stdout,
                                       hdr->original_size, hdr->packed_size,
                                       name, method, &read_size);
                }
#else
                crc = decode_lzhuf(afp, stdout,
                                   hdr->original_size, hdr->packed_size,
                                   name, method, &read_size);
#endif /* HAVE_LIBAPPLEFILE */
            }
#if defined(__MINGW32__) || defined(__DJGPP__)
                fflush(stdout);
                setmode(fileno(stdout), old_mode);
            }
#endif
            quiet = save_quiet;
            verbose = save_verbose;
        }
        else {
#ifndef __APPLE__
            /* "Icon\r" should be a resource fork of parent folder's icon,
               so that it can be skipped when system is not Mac OS X. */
            if (hdr->extend_type == EXTEND_MACOS
                && strcmp(basename(name), "Icon\r") == 0
                && decode_macbinary_contents) {
                make_parent_path(name); /* create directory only */
                return read_size;
            }
#endif /* __APPLE__ */
#ifdef LHA_LIBRARY
            if (!Lha_PrepareCommandExtraction(hdr, name, sizeof(name)))
                return read_size;
#endif
            if (skip_flg == FALSE)  {
                up_flag = inquire_extract(name);
                if (up_flag == FALSE && force == FALSE) {
                    return read_size;
                }
            }

            if (skip_flg == TRUE) {
                if (stat(name, &stbuf) == 0 && force != TRUE) {
                    if (quiet != TRUE)
                        printf("%s : Skipped...\n", name);
                    return read_size;
                }
            }
            if (noexec) {
                return read_size;
            }

            signal(SIGINT, interrupt);
#ifdef SIGHUP
            signal(SIGHUP, interrupt);
#endif

            unlink(name);
            remove_extracting_file_when_interrupt = TRUE;

            if ((fp = open_with_make_path(name)) != NULL) {
                g_outfp = fp;
#if HAVE_LIBAPPLEFILE
                if (hdr->extend_type == EXTEND_MACOS && !verify_mode && decode_macbinary_contents) {
                    /* build temporary file */
                    tfp = NULL; /* avoid compiler warnings `uninitialized' */
                    tfp = build_temporary_file();

                    crc = decode_lzhuf(afp, tfp,
                                       hdr->original_size, hdr->packed_size,
                                       name, method, &read_size);
                    fclose(tfp);
                    decode_macbinary(fp, hdr->original_size, name);
#ifdef __APPLE__
                    /* TODO: set resource fork */
                    /* after processing, "Icon\r" is not needed. */
                    if (strcmp(basename(name), "Icon\r") == 0) {
                        unlink(name);
                    }
#endif /* __APPLE__ */
                    unlink(temporary_name);
                } else {
                    crc = decode_lzhuf(afp, fp,
                                       hdr->original_size, hdr->packed_size,
                                       name, method, &read_size);
                }
#else /* HAVE_LIBAPPLEFILE */
                crc = decode_lzhuf(afp, fp,
                                   hdr->original_size, hdr->packed_size,
                                   name, method, &read_size);
#endif /* HAVE_LIBAPPLEFILE */
                g_outfp = NULL;
                fclose(fp);
            }
            remove_extracting_file_when_interrupt = FALSE;
            g_infp = NULL;
            signal(SIGINT, SIG_DFL);
#ifdef SIGHUP
            signal(SIGHUP, SIG_DFL);
#endif
            if (!fp)
                return read_size;
        }

        if (hdr->has_crc && crc != hdr->crc) {
#ifdef LHA_LIBRARY
            /* 本文を読み切った CRC 不一致だけを確認処理へ渡す。入力不足は従来の失敗を保つ。 */
            if (!ferror(afp) &&
                ((method == LZHUFF0_METHOD_NUM || method == LARC4_METHOD_NUM)
                    ? read_size == hdr->original_size : decode_count == hdr->original_size)) {
                /* 原版は削除確認の前に日時・属性を復元する。保持して中断する場合にも必要。 */
                if (!verify_mode && !output_to_stdout) adjust_info(name, hdr);
                if (Lha_HandleCommandCrcError(data_start, verify_mode || output_to_stdout ? NULL : name)) {
                    /* C++ 側から戻った後に、書庫も共通 cleanup の対象へ戻して終了する。 */
                    g_infp = afp;
                    exit(1);
                }
                return read_size;
            }
            else
#endif
            error("CRC error: \"%s\"", name);
        }
    }
    else if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_DIRECTORY
             || (hdr->unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_SYMLINK
             || method == LZHDIRS_METHOD_NUM) {
        /* ↑これで、Symbolic Link は、大丈夫か？ */
        if (!ignore_directory && !verify_mode && !output_to_stdout) {
            if (noexec) {
                if (quiet != TRUE)
                    printf("EXTRACT %s (directory)\n", name);
                return read_size;
            }
            /* NAME has trailing SLASH '/', (^_^) */
            if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_SYMLINK) {
#ifdef S_IFLNK
                int             l_code;
#endif

#ifdef S_IFLNK
                if (skip_flg == FALSE)  {
                    up_flag = inquire_extract(name);
                    if (up_flag == FALSE && force == FALSE) {
                        return read_size;
                    }
                }

                if (skip_flg == TRUE) {
                    if (GETSTAT(name, &stbuf) == 0 && force != TRUE) {
                        if (quiet != TRUE)
                            printf("%s : Skipped...\n", name);
                        return read_size;
                    }
                }

                unlink(name);
                l_code = symlink_with_make_path(hdr->realname, name);
                if (l_code < 0) {
                    if (quiet != TRUE)
                        warning("Can't make Symbolic Link \"%s\" -> \"%s\"",
                                name, hdr->realname);
                }
                if (quiet != TRUE) {
                    message("Symbolic Link %s -> %s",
                            name, hdr->realname);
                }
#else
                warning("Can't make Symbolic Link %s -> %s",
                        name, hdr->realname);
                return read_size;
#endif
            }
            else { /* make directory */
#if defined(_WIN32) && defined(LHA_LIBRARY)
                Lha_RecordHeaderCommandEvent("Melted", hdr, 0);
#endif
                if (!make_parent_path(name))
                    return read_size;
#if defined(_WIN32) && defined(LHA_LIBRARY)
                /* 原版は次の項目より前に復元する。中断後の次命令へ保留情報を持ち越さない。 */
                Lha_RestoreCommandDirectoryMetadata(hdr, name);
#else
                /* CLI など従来の利用形態では、子項目処理後のディレクトリ復元を維持する。 */
                add_dirinfo(name, hdr);
#endif
            }
        }
    }
    else {
        if (force)              /* force extract */
            goto extract_regular;
        else
            error("Unknown file type: \"%s\". use `f' option to force extract.", name);
    }

    if (!output_to_stdout && !verify_mode) {
        /* -lhd- の情報はディレクトリ作成経路が復元する。通常ファイルの復元と重複させない。 */
        if ((hdr->unix_mode & UNIX_FILE_TYPEMASK) != UNIX_FILE_DIRECTORY &&
            method != LZHDIRS_METHOD_NUM)
            adjust_info(name, hdr);
    }

    return read_size;
}

static int
skip_to_nextpos(FILE *fp, off_t pos, off_t off, off_t read_size)
{
    if (pos != -1) {
        if (fseeko(fp, pos + off, SEEK_SET) != 0) {
            return -1;
        }
    }
    else {
        off_t i = off - read_size;
        while (i--) {
            if (fgetc(fp) == EOF) {
                return -1;
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* EXTRACT COMMAND MAIN                                                     */
/* ------------------------------------------------------------------------ */
extern int Lha_GetEnableTotalProgress();
extern void Lha_SetTotalProgressInfo(__int64 total_bytes, int total_files);

void
cmd_extract()
{
    LzHeader        hdr;
    off_t           pos;
    FILE           *afp;
    off_t read_size;
    int first_header = TRUE;

    /* open archive file */
    if ((afp = open_old_archive()) == NULL)
        fatal_error("Cannot open archive file \"%s\"", archive_name);
    /* OPEN/BEGIN の中断も共通 cleanup に書庫の所有権を渡す。 */
    g_infp = afp;
    Lha_ClearProgressMember();
    if (Lha_SendProgressMessage(3 /* ARCEXTRACT_OPEN */, archive_name, 0, 0))
        fatal_error("User cancelled.");

    /* 拡張全体進捗のための事前スキャン */
    if (Lha_GetEnableTotalProgress()) {
        __int64 total_bytes = 0;
        int total_files = 0;

        if (archive_is_msdos_sfx1(archive_name))
            seek_lha_header(afp);

        while (Lha_ReadCommandHeader(afp, &hdr, first_header)) {
            first_header = FALSE;
            pos = ftello(afp);
            if (need_file_header(&hdr)) {
                /* ディレクトリ、シンボリックリンク等はサイズに含めない */
                if ((hdr.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_REGULAR || 
                    (hdr.unix_mode & UNIX_FILE_TYPEMASK) == 0) { /* 0は通常ファイル (OS依存等) */
                    total_bytes += hdr.original_size;
                    total_files++;
                }
            }
            if (skip_to_nextpos(afp, pos, hdr.packed_size, 0) == -1) {
                fatal_error("Cannot seek to next header position from \"%s\"", hdr.name);
            }
        }

        /* ファイルポインタを先頭に戻す */
        fseeko(afp, 0, SEEK_SET);
        first_header = TRUE;

        /* 情報をセット */
        Lha_SetTotalProgressInfo(total_bytes, total_files);
    }

    if (archive_is_msdos_sfx1(archive_name))
        seek_lha_header(afp);

    /* extract each files */

    while (Lha_ReadCommandHeader(afp, &hdr, first_header)) {
        first_header = FALSE;
        Lha_RecordEnumHeader(&hdr);
        pos = ftello(afp);
        /* 原版は t/p/e/x とも選択判定より前に項目開始を通知する。 */
        Lha_SetProgressMember(&hdr);
        if (Lha_SendProgressMessage(0 /* ARCEXTRACT_BEGIN */, hdr.name, 0, hdr.original_size))
            fatal_error("User cancelled.");
        if (need_file_header(&hdr)) {
            read_size = extract_one(afp, &hdr, pos);
            /* extract_one が本文終了時に外した入力を、次ヘッダーまで再び保持する。 */
            g_infp = afp;
            if (read_size != hdr.packed_size) {
                /* when error occurred in extract_one(), should adjust
                   point of file stream */
                if (skip_to_nextpos(afp, pos, hdr.packed_size, read_size) == -1) {
                    fatal_error("Cannot seek to next header position from \"%s\"", hdr.name);
                }
            }
        } else {
            if (skip_to_nextpos(afp, pos, hdr.packed_size, 0) == -1) {
                fatal_error("Cannot seek to next header position from \"%s\"", hdr.name);
            }
        }
    }

    if (!Lha_HasCommandHeaderError()) Lha_RecordProgressHeaderEnd();

    /* close archive file */
    fclose(afp);
    g_infp = NULL;

    if (Lha_HasCommandHeaderError()) {
        Lha_ClearProgressMember();
        return;
    }

    /* adjust directory information */
    adjust_dirinfo();

    Lha_SendProgressMessage(2 /* ARCEXTRACT_END */, NULL, 0, 0);
    Lha_ClearProgressMember();

    return;
}

int
is_directory_traversal(char *path)
{
    int state = 0;

    for (; *path; path++) {
        /* スラッシュとバックスラッシュの両方をパス区切り文字として扱う */
        int is_sep = (*path == '/' || *path == '\\');
        switch (state) {
        case 0:
            if (*path == '.') state = 1;
            else state = 3;
            break;
        case 1:
            if (*path == '.') state = 2;
            else if (is_sep) state = 0;
            else state = 3;
            break;
        case 2:
            if (is_sep) return 1;   /* ../または..\を検出 */
            else state = 3;
            break;
        case 3:
            if (is_sep) state = 0;
            break;
        }
    }

    return state == 2;
}

/*
 * restore directory information (timestamp, permission and uid/gid).
 * added by A.Iriyama  2003.12.12
 */

typedef struct LzHeaderList_t {
    struct LzHeaderList_t *next;
    LzHeader hdr;
} LzHeaderList;

static LzHeaderList *dirinfo;

static void add_dirinfo(char *name, LzHeader *hdr)
{
    LzHeaderList *p, *tmp, top;

    if (memcmp(hdr->method, LZHDIRS_METHOD, 5) != 0)
        return;

    p = xmalloc(sizeof(LzHeaderList));

    memcpy(&p->hdr, hdr, sizeof(LzHeader));
    strncpy(p->hdr.name, name, sizeof(p->hdr.name));
    p->hdr.name[sizeof(p->hdr.name)-1] = 0;

#if 0
    /* push front */
    {
        tmp = dirinfo;
        dirinfo = p;
        dirinfo->next = tmp;
    }
#else

    /*
      reverse sorted by pathname order

         p->hdr.name = "a"

         dirinfo->hdr.name             = "a/b/d"
         dirinfo->next->hdr.name       = "a/b/c"
         dirinfo->next->next->hdr.name = "a/b"

       result:

         dirinfo->hdr.name                   = "a/b/d"
         dirinfo->next->hdr.name             = "a/b/c"
         dirinfo->next->next->hdr.name       = "a/b"
         dirinfo->next->next->next->hdr.name = "a"
    */

    top.next = dirinfo;

    for (tmp = &top; tmp->next; tmp = tmp->next) {
        if (strcmp(p->hdr.name, tmp->next->hdr.name) > 0) {
            p->next = tmp->next;
            tmp->next = p;
            break;
        }
    }
    if (tmp->next == NULL) {
        p->next = NULL;
        tmp->next = p;
    }

    dirinfo = top.next;
#endif
}

static void adjust_dirinfo()
{
    while (dirinfo) {
        /* message("adjusting [%s]", dirinfo->hdr.name); */
        adjust_info(dirinfo->hdr.name, &dirinfo->hdr);

        {
            LzHeaderList *tmp = dirinfo;
            dirinfo = dirinfo->next;
            free(tmp);
        }
    }
}

#if HAVE_LIBAPPLEFILE
static boolean
decode_macbinary(FILE *ofp, off_t size, const char *outPath)
{
    af_file_t *afp = NULL;
    FILE *ifp = NULL;
    unsigned char *datap;
    size_t dlen;

    if ((afp = af_open(temporary_name)) != NULL) {
        /* fetch datafork */
        datap = af_data(afp, &dlen);
        fwrite(datap, sizeof(unsigned char), dlen, ofp);
        af_close(afp);
        return TRUE;
    } else { /* it may be not encoded in MacBinary */
        /* try to copy */
        if ((ifp = fopen(temporary_name, READ_BINARY)) == NULL) {
            error("Cannot open a temporary file \"%s\"", temporary_name);
            return FALSE;
        }
        copyfile(ifp, ofp, size, 0, 0);
        fclose(ifp);
        return TRUE;
    }

    return FALSE;
}
#endif /* HAVE_LIBAPPLEFILE */
