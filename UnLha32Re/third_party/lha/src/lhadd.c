/* ------------------------------------------------------------------------ */
/* LHa for UNIX                                                             */
/*              lhadd.c -- LHarc Add Command                                */
/*                                                                          */
/*      Copyright (C) MCMLXXXIX Yooichi.Tagawa                              */
/*      Modified                Nobutaka Watazaki                           */
/*                                                                          */
/*  Ver. 1.14   Source All chagned              1995.01.14  N.Watazaki      */
/* ------------------------------------------------------------------------ */
#include "lha.h"
#ifdef LHA_LIBRARY
#undef fseeko
#undef ftello
#define fseeko Lha_SeekCompressionFile
#define ftello Lha_TellCompressionFile
#endif
/* ------------------------------------------------------------------------ */
static void     remove_files(int filec, char **filev);
static int      added_member_count;

/* 全体進捗通知のための外部関数 */
extern int Lha_GetEnableTotalProgress();
extern void Lha_SetTotalProgressInfo(__int64 total_bytes, int total_files);

static int
is_excluded_compression_input(const char *name)
{
    int i;
    /* a/u/m の旧項目は -x の対象外。f と新規項目の除外は維持する。 */
#ifdef LHA_LIBRARY
    if (Lha_IsExistingCompressionInput(name)) return FALSE;
#endif
    for (i = 0; exclude_files && exclude_files[i]; i++) {
        if (fnmatch(exclude_files[i], basename(name),
                    FNM_PATHNAME|FNM_NOESCAPE|FNM_PERIOD) == 0)
            return TRUE;
    }
    return FALSE;
}

static void
set_progress_file_destination(const char *name)
{
    char fullpath[FILENAME_LENGTH];
    if (Lha_FullPath(fullpath, name, sizeof(fullpath)) != NULL)
        Lha_SetProgressDestination(fullpath);
    else
        Lha_SetProgressDestination(name);
}

static void
set_progress_directory_destination(const char *name)
{
    char fullpath[FILENAME_LENGTH];
    char *slash, *backslash, *separator;
    if (Lha_FullPath(fullpath, name, sizeof(fullpath)) == NULL) {
        Lha_SetProgressDestination("");
        return;
    }
    slash = strrchr(fullpath, '/');
    backslash = strrchr(fullpath, '\\');
    separator = slash;
    if (!separator || (backslash && backslash > separator))
        separator = backslash;
    if (separator)
        separator[1] = '\0';
    else
        fullpath[0] = '\0';
    Lha_SetProgressDestination(fullpath);
}

static void
notify_add_old_member(const LzHeader *hdr)
{
    /* 更新対象でなくても、実際に読んだ旧メンバーを BEGIN で通知する。 */
    Lha_SetProgressMember(hdr);
    if (Lha_SendCompatProgressMessage(0, hdr->name, 0, hdr->original_size))
        fatal_error("User cancelled.");
}

static void
notify_add_begin(const char *name, const LzHeader *hdr)
{
    LzHeader progress = *hdr;
    Lha_ApplyCompressionProgressHistory(&progress);
    /* 原版は選択方式にかかわらず BEGIN を lh5 とし、FINISH で実方式へ更新する。 */
    memcpy(progress.method, LZHUFF5_METHOD, METHOD_TYPE_STORAGE);
    Lha_SetCompressionProgressMember(&progress);
    set_progress_file_destination(name);
    if (Lha_SendCompatProgressMessage(0, progress.name, 0, progress.original_size))
        fatal_error("User cancelled.");
}

static void
notify_add_complete(const char *name, const LzHeader *hdr)
{
    LzHeader progress = *hdr;
    ++added_member_count;
    Lha_RecordCompressionCompletion(hdr, name);
    Lha_SetCompressionProgressMember(&progress);
    set_progress_file_destination(name);
    if (Lha_SendCompatProgressMessage(6, progress.name, 0, progress.original_size) ||
        Lha_SendCompatProgressMessage(1, progress.name,
                                      progress.original_size, progress.original_size))
        fatal_error("User cancelled.");
    /* 完了通知を受理した項目だけをログへ確定する。 */
    Lha_RecordHeaderCommandEvent("Frozen", hdr,
        hdr->original_size > 0 ? (int)(hdr->packed_size * 100 / hdr->original_size) : 0);
}

/* 圧縮対象ファイルの事前スキャン用再帰関数 */
static void
scan_add_files_recursive(const char *name, __int64 *total_bytes, int *total_files)
{
    struct stat stbuf;
    int filec;
    char **filev;
    int i;

    if (Lha_CompressionInputStat(name, &stbuf) < 0) {
        return;
    }

    if (is_directory(&stbuf)) {
        if (recursive_archiving && !Lha_HasFlatCompressionInputs()) {
            if (find_files(name, &filec, &filev)) {
                for (i = 0; i < filec; i++) {
                    scan_add_files_recursive(filev[i], total_bytes, total_files);
                }
                free_files(filec, filev);
            }
        }
    }
    else if (is_regularfile(&stbuf) || is_symlink(&stbuf)) {
        (*total_files)++;
        if (is_regularfile(&stbuf)) {
            (*total_bytes) += stbuf.st_size;
        }
    }
}

static char     new_archive_name_buffer[FILENAME_LENGTH];
static char    *new_archive_name;
static time_t most_recent;      /* for time-stamp archiving */

static void
copy_old_one(FILE *oafp, FILE *nafp, LzHeader *hdr)
{
    if (noexec) {
        fseeko(oafp, hdr->header_size + hdr->packed_size, SEEK_CUR);
    }
    else {
        reading_filename = archive_name;
        writing_filename = temporary_name;
        copyfile(oafp, nafp, hdr->header_size + hdr->packed_size, 0, 0);

        /* directory and symlink are ignored for time-stamp archiving */
        if (memcmp(hdr->method, "-lhd-", 5) != 0) {
            if (most_recent < hdr->unix_last_modified_stamp)
                most_recent = hdr->unix_last_modified_stamp;
        }
    }
}

static void
keep_rejected_old_member(FILE *oafp, FILE *nafp, LzHeader *hdr,
                         off_t old_header, int comparison)
{
    if (oafp && comparison == 0) {
        fseeko(oafp, old_header, SEEK_SET);
        copy_old_one(oafp, nafp, hdr);
    }
}

static void
add_one(FILE *fp, FILE *nafp, LzHeader *hdr)
{
    off_t header_pos, next_pos, org_pos, data_pos;
    off_t v_original_size, v_packed_size;

    reading_filename = hdr->name;
    writing_filename = temporary_name;

    /* directory and symlink are ignored for time-stamp archiving */
    if (memcmp(hdr->method, "-lhd-", 5) != 0) {
        if (most_recent < hdr->unix_last_modified_stamp)
            most_recent = hdr->unix_last_modified_stamp;
    }

    if (!fp && generic_format && !Lha_StoresCompressionDirectories())
        return;
    header_pos = ftello(nafp);
    write_header(nafp, hdr);/* DUMMY */

    if ((hdr->unix_mode & UNIX_FILE_SYMLINK) == UNIX_FILE_SYMLINK) {
        if (!quiet)
            printf("%s -> %s\t- Symbolic Link\n", hdr->name, hdr->realname);
    }

    if (hdr->original_size == 0) {  /* empty file, symlink or directory */
        start_indicator(hdr->name, 0, "Frozen", 2048);
        finish_indicator2(hdr->name, "Frozen", 0);
        return;     /* previous write_header is not DUMMY. (^_^) */
    }
    org_pos = ftello(fp);
    data_pos = ftello(nafp);

    g_infp = fp;
    g_outfp = nafp;
    hdr->crc = encode_lzhuf(fp, nafp, hdr->original_size,
          &v_original_size, &v_packed_size, hdr->name, hdr->method);

    if (v_packed_size < v_original_size || (compress_method == 0 && !text_mode)) {
        next_pos = ftello(nafp);
    }
    else {          /* retry by stored method */
        fseeko(fp, org_pos, SEEK_SET);
        fseeko(nafp, data_pos, SEEK_SET);
        g_infp = fp;
        g_outfp = nafp;
        start_indicator(hdr->name, hdr->original_size, "Storing ", 2048);
        if (!text_mode) {
            unsigned int stored_crc;
            v_original_size = v_packed_size = Lha_CopyStoredWithProgress(
                fp, nafp, hdr->original_size, hdr->name, &stored_crc);
            hdr->crc = stored_crc;
        } else {
            hdr->crc = encode_stored_crc(fp, nafp, hdr->original_size,
                          &v_original_size, &v_packed_size);
        }
        finish_indicator2(hdr->name, "Stored ", 100);
        fflush(nafp);
        next_pos = ftello(nafp);
#ifdef LHA_LIBRARY
        if (Lha_TruncateCompressionWorkFile(nafp, next_pos) == -1)
            error("cannot truncate archive");
#elif HAVE_FTRUNCATE
        if (ftruncate(fileno(nafp), next_pos) == -1)
            error("cannot truncate archive");
#elif HAVE_CHSIZE
        if (chsize(fileno(nafp), next_pos) == -1)
            error("cannot truncate archive");
#else
        CAUSE COMPILE ERROR
#endif
        memcpy(hdr->method, LZHUFF0_METHOD, METHOD_TYPE_STORAGE);
    }
    hdr->original_size = v_original_size;
    hdr->packed_size = v_packed_size;
    fseeko(nafp, header_pos, SEEK_SET);
    write_header(nafp, hdr);
    fseeko(nafp, next_pos, SEEK_SET);
}

FILE           *
append_it(char *name, FILE *oafp, FILE *nafp)
{
    LzHeader        ahdr, hdr;
    FILE           *fp;
    off_t            old_header = 0;
    int             cmp;
    int             filec;
    char          **filev;
    int             i;
    struct stat     stbuf;
    char            selected_name[FILENAME_LENGTH];
    char            selected_header_name[FILENAME_LENGTH];
    const char     *source_name = name;

    boolean         directory, symlink;

    if (Lha_CompressionInputStat(name, &stbuf) < 0) {
        error("Cannot access file \"%s\"", name);   /* See cleaning_files, Why? */
        return oafp;
    }

    init_header(name, &stbuf, &hdr);

#ifdef LHA_LIBRARY
    if (!Lha_CommandShouldAddMember(&hdr))
        return oafp;
#endif

    cmp = 0;                    /* avoid compiler warnings `uninitialized' */
    while (oafp) {
        old_header = ftello(oafp);
        if (!get_header(oafp, &ahdr)) {
            /* end of archive or error occurred */
            Lha_RecordCompressionHeaderEnd();
            fclose(oafp);
            oafp = NULL;
            g_update_archive_fp = NULL;
            break;
        }
        Lha_RecordEnumHeader(&ahdr);
        notify_add_old_member(&ahdr);

        if (!sort_contents) {
            if (!noexec) {
                fseeko(oafp, old_header, SEEK_SET);
                copy_old_one(oafp, nafp, &ahdr);
            }
            else
                fseeko(oafp, ahdr.packed_size, SEEK_CUR);
            cmp = -1;           /* to be -1 always */
            continue;
        }

#ifdef LHA_LIBRARY
        /* 通知で格納名・読込先が変わっても、選択した旧項目の位置で置換する。 */
        cmp = Lha_CompareCompressionHeader(&ahdr, source_name);
#else
        cmp = strcmp(ahdr.name, hdr.name);
#endif
        if (cmp < 0) {          /* SKIP */
            /* copy old to new */
            if (!noexec) {
                fseeko(oafp, old_header, SEEK_SET);
                copy_old_one(oafp, nafp, &ahdr);
            }
            else
                fseeko(oafp, ahdr.packed_size, SEEK_CUR);
        } else if (cmp == 0) {  /* REPLACE */
            /* コールバックが拒否した場合にも旧項目を保持できる位置で止める。 */
            break;
        } else {                /* cmp > 0, INSERT */
            fseeko(oafp, old_header, SEEK_SET);
            break;
        }
    }

    /* ADD/FRESH の数値情報は、入力ファイルでなく直前に読んだ旧ヘッダー由来。 */
    strncpy(selected_name, name, sizeof(selected_name) - 1);
    selected_name[sizeof(selected_name) - 1] = '\0';
    if (!Lha_InvokeEnumMember(&hdr, selected_name, sizeof(selected_name))) {
        keep_rejected_old_member(oafp, nafp, &ahdr, old_header, cmp);
        return oafp;
    }

    strncpy(selected_header_name, hdr.name, sizeof(selected_header_name) - 1);
    selected_header_name[sizeof(selected_header_name) - 1] = '\0';
    if (strcmp(selected_name, name) != 0) {
        name = selected_name;
        if (GETSTAT(name, &stbuf) < 0) {
            if (Lha_HandleCompressionReadFailure(name)) return oafp;
            error("Cannot access file \"%s\"", name);
            keep_rejected_old_member(oafp, nafp, &ahdr, old_header, cmp);
            return oafp;
        }
        init_header(name, &stbuf, &hdr);
        strncpy(hdr.name, selected_header_name, sizeof(hdr.name) - 1);
        hdr.name[sizeof(hdr.name) - 1] = '\0';
    }

    directory = is_directory(&stbuf);
    symlink = is_symlink(&stbuf);
    fp = NULL;
    if (!directory && !symlink && !noexec) {
        fp = Lha_OpenCompressionInput(name, &hdr);
        if (!fp) {
            if (Lha_HandleCompressionReadFailure(name)) return oafp;
            error("Cannot open file \"%s\": %s", name, strerror(errno));
            keep_rejected_old_member(oafp, nafp, &ahdr, old_header, cmp);
            return oafp;
        }
    }
    if (oafp && cmp == 0) fseeko(oafp, ahdr.packed_size, SEEK_CUR);
    /* 項目開始・格納完了の通知から中断する間も元ファイルを所有する。 */
    g_infp = fp;

    if (!oafp || cmp > 0) { /* not in archive */
        if (!freshen_only) {
            if (noexec)
                printf("ADD %s\n", name);
            else {
                notify_add_begin(name, &hdr);
                add_one(fp, nafp, &hdr);
                notify_add_complete(name, &hdr);
            }
        }
    }
    else {      /* cmp == 0 */
#ifdef LHA_LIBRARY
        /* 対象選択はコールバック前に互換層で済ませている。 */
        if (TRUE) {
#else
        if (!update_if_newer ||
            ahdr.unix_last_modified_stamp < hdr.unix_last_modified_stamp) {
#endif
                                /* newer than archive's */
            if (noexec)
                printf("REPLACE %s\n", name);
            else {
                notify_add_begin(name, &hdr);
                add_one(fp, nafp, &hdr);
                notify_add_complete(name, &hdr);
            }
        }
        else {                  /* copy old to new */
            if (!noexec) {
                fseeko(oafp, old_header, SEEK_SET);
                copy_old_one(oafp, nafp, &ahdr);
            }
        }
    }

    if (fp) {
        fclose(fp);
        g_infp = NULL;
    }

    if (directory && recursive_archiving && !Lha_HasFlatCompressionInputs()) {
        if (find_files(name, &filec, &filev)) {
            for (i = 0; i < filec; i++)
                oafp = append_it(filev[i], oafp, nafp);
            free_files(filec, filev);
        }
    }
    return oafp;
}

/* ------------------------------------------------------------------------ */
static void
find_update_files(FILE *oafp)  /* oafp: old archive */
{
    char            name[FILENAME_LENGTH];
    struct string_pool sp;
    LzHeader        hdr;
    off_t           pos;
    struct stat     stbuf;
    size_t          len;

    pos = ftello(oafp);

    init_sp(&sp);
    while (get_header(oafp, &hdr)) {
        if ((hdr.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_REGULAR) {
            if (stat(hdr.name, &stbuf) >= 0)    /* exist ? */
                add_sp(&sp, hdr.name, (int)strlen(hdr.name) + 1);
        }
        else if ((hdr.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_DIRECTORY) {
            strcpy(name, hdr.name); /* ok */
            len = strlen(name);
            if (len > 0 && name[len - 1] == '/')
                name[--len] = '\0'; /* strip tail '/' */
            if (stat(name, &stbuf) >= 0)    /* exist ? */
                add_sp(&sp, name, (int)len + 1);
        }
        fseeko(oafp, hdr.packed_size, SEEK_CUR);
    }

    fseeko(oafp, pos, SEEK_SET);

    finish_sp(&sp, &cmd_filec, &cmd_filev);
}

/* ------------------------------------------------------------------------ */
static void
delete(FILE *oafp, FILE *nafp)
{
    LzHeader ahdr;
    off_t old_header_pos;

    old_header_pos = ftello(oafp);
    while (get_header(oafp, &ahdr)) {
        Lha_RecordEnumHeader(&ahdr);
        if (need_file_header(&ahdr) && Lha_InvokeEnumMember(&ahdr, NULL, 0)) { /* skip */
            fseeko(oafp, ahdr.packed_size, SEEK_CUR);
            Lha_RecordHeaderCommandEvent("Deleted", &ahdr, 0);
            if (noexec || !quiet) {
                if ((ahdr.unix_mode & UNIX_FILE_TYPEMASK) == UNIX_FILE_SYMLINK)
                    message("delete %s -> %s", ahdr.name, ahdr.realname);
                else
                    message("delete %s", ahdr.name);
            }
        }
        else {
            fseeko(oafp, old_header_pos, SEEK_SET);
            copy_old_one(oafp, nafp, &ahdr);
        }
        old_header_pos = ftello(oafp);
    }
    Lha_RecordProgressHeaderEnd();
    return;
}

/* ------------------------------------------------------------------------ */
/*                                                                          */
/* ------------------------------------------------------------------------ */
FILE    *
build_temporary_file()
{
    FILE *afp;

#ifndef LHA_LIBRARY
    signal(SIGINT, interrupt);
#ifdef SIGHUP
    signal(SIGHUP, interrupt);
#endif
#endif

    temporary_fd = build_temporary_name();
    if (temporary_fd == -1)
        fatal_error("Cannot open temporary file \"%s\"", temporary_name);

    afp = fdopen(temporary_fd, WRITE_BINARY);
    if (afp == NULL)
        fatal_error("Cannot open temporary file \"%s\"", temporary_name);

    return afp;
}

/* ------------------------------------------------------------------------ */
static void
build_backup_file()
{

    build_backup_name(backup_archive_name, archive_name,
                      sizeof(backup_archive_name));
    if (!noexec) {
#ifndef LHA_LIBRARY
        signal(SIGINT, SIG_IGN);
#ifdef SIGHUP
        signal(SIGHUP, SIG_IGN);
#endif
#endif
        if (rename(archive_name, backup_archive_name) < 0) {
#if __MINGW32__
            /* On MinGW, cannot rename when
               newfile (backup_archive_name) already exists */
            if (unlink(backup_archive_name) < 0 ||
                rename(archive_name, backup_archive_name) < 0)
#endif
            fatal_error("Cannot make backup file \"%s\"", archive_name);
        }
        recover_archive_when_interrupt = TRUE;
#ifndef LHA_LIBRARY
        signal(SIGINT, interrupt);
#ifdef SIGHUP
        signal(SIGHUP, interrupt);
#endif
#endif
    }
}

/* ------------------------------------------------------------------------ */
static void
report_archive_name_if_different()
{
    if (!quiet && new_archive_name == new_archive_name_buffer) {
        /* warning at old archive is SFX */
        message("New archive file is \"%s\"", new_archive_name);
    }
}

/* ------------------------------------------------------------------------ */
void
temporary_to_new_archive_file(off_t new_archive_size)
{
    FILE *oafp, *nafp;

    if (!strcmp(new_archive_name, "-")) {
        nafp = stdout;
        writing_filename = "standard output";
#if defined(__MINGW32__) || defined(__DJGPP__)
        setmode(fileno(stdout), O_BINARY);
#endif
    }
    else {
#ifdef LHA_LIBRARY
        if (Lha_CommitCompressionArchive(temporary_name, new_archive_name) < 0)
            fatal_error("Cannot replace archive file \"%s\"", new_archive_name);
        return;
#else
        unlink(new_archive_name);
        if (rename(temporary_name, new_archive_name) == 0)
            return;
        nafp = xfopen(new_archive_name, WRITE_BINARY);
        writing_filename = archive_name;
#endif
    }

    oafp = xfopen(temporary_name, READ_BINARY);
    reading_filename = temporary_name;
    copyfile(oafp, nafp, new_archive_size, 0, 0);
    if (nafp != stdout)
        fclose(nafp);
    fclose(oafp);

    recover_archive_when_interrupt = FALSE;
    unlink(temporary_name);
}

/* ------------------------------------------------------------------------ */
static void
set_archive_file_mode()
{
    int             umask_value;
    struct stat     stbuf;

    if (archive_file_gid < 0) {
        umask(umask_value = umask(0));
        archive_file_mode = (~umask_value) & 0666;  /* rw-rw-rw- */
        if (stat(".", &stbuf) >= 0)
            archive_file_gid = stbuf.st_gid;
    }
    if (archive_file_gid >= 0)
        chown(new_archive_name, getuid(), archive_file_gid);

    chmod(new_archive_name, archive_file_mode);

    if (timestamp_archive && most_recent) {
#if HAVE_UTIMES
        struct timeval  timevals[2];
        timevals[0].tv_sec = timevals[1].tv_sec = most_recent;
        timevals[0].tv_usec = timevals[1].tv_usec = 0;
        utimes(new_archive_name, timevals);
#else
        struct utimbuf  utimebuf;
        utimebuf.actime = utimebuf.modtime = most_recent;
        utime(new_archive_name, &utimebuf);
#endif
    }
}

/* ------------------------------------------------------------------------ */
/*                          REMOVE FILE/DIRECTORY                           */
/* ------------------------------------------------------------------------ */
static void
remove_one(char *name)
{
    struct stat     stbuf;
    int             filec;
    char          **filev;

    const int status = GETSTAT(name, &stbuf);
#ifdef LHA_LIBRARY
    /* m の削除だけで再探索した除外項目・未格納の入力・別パスを保持する。 */
    if (!Lha_CanRemoveCompressionInput(name, status == 0 && is_directory(&stbuf))) return;
#endif
    if (status < 0) {
        if (Lha_HandleCompressionDeleteFailure(name)) return;
        warning("Cannot access \"%s\": %s", name, strerror(errno));
    }
    else if (is_directory(&stbuf)) {
#ifdef LHA_LIBRARY
        /* 非再帰の圧縮が処理していない子ファイルを、削除段階だけで探索しない。 */
        if (!recursive_archiving || Lha_HasFlatCompressionInputs()) return;
#endif
        if (find_files(name, &filec, &filev)) {
            remove_files(filec, filev);
            free_files(filec, filev);
            if (Lha_HasCompressionDeleteFailure()) return;
        }
        else
            warning("Cannot open directory \"%s\"", name);

#ifndef LHA_LIBRARY
        /* UNLHA32 の m はディレクトリー自体を削除しない。 */
        if (noexec)
            message("REMOVE DIRECTORY %s", name);
        else if (rmdir(name) < 0)
            warning("Cannot remove directory \"%s\"", name);
        else if (verbose)
            message("Removed %s.", name);
#endif
    }
    else if (is_regularfile(&stbuf)) {
        if (noexec)
            message("REMOVE FILE %s.", name);
        else if (unlink(name) < 0) {
            if (Lha_HandleCompressionDeleteFailure(name)) return;
            warning("Cannot remove \"%s\"", name);
        }
        else {
            Lha_RecordCompressionFileDeleted();
            if (verbose) message("Removed %s.", name);
        }
    }
    else if (is_symlink(&stbuf)) {
        if (noexec)
            message("REMOVE SYMBOLIC LINK %s.", name);
        else if (unlink(name) < 0) {
            if (Lha_HandleCompressionDeleteFailure(name)) return;
            warning("Cannot remove", name);
        }
        else {
            Lha_RecordCompressionFileDeleted();
            if (verbose) message("Removed %s.", name);
        }
    }
    else {
        error("Cannot remove file \"%s\" (not a file or directory)", name);
    }
}

static void
remove_files(int filec, char **filev)
{
    int             i;

    for (i = 0; i < filec && !Lha_HasCompressionDeleteFailure(); i++)
        remove_one(filev[i]);
}

/* ------------------------------------------------------------------------ */
/*                                                                          */
/* ------------------------------------------------------------------------ */
void
cmd_add()
{
    LzHeader        ahdr;
    FILE           *oafp, *nafp;
    int             i;
    off_t            old_header;
    boolean         old_archive_exist;
    off_t           new_archive_size;
    int             direct_new_archive = 0;
#ifdef LHA_LIBRARY
    const int       explicit_inputs = Lha_HasExplicitCompressionInputs();
#else
    const int       explicit_inputs = 0;
#endif

    most_recent = 0;
    added_member_count = 0;

    /* exit if no operation */
    if (!update_if_newer && cmd_filec == 0 && !explicit_inputs) {
        error("No files given in argument, do nothing.");
        exit(1);
    }

    nafp = NULL;
    direct_new_archive = Lha_BeginNewCompressionArchive(!noexec && !freshen_only ? archive_name : NULL, &nafp);
    if (direct_new_archive < 0) fatal_error("Cannot create archive file");
    if (direct_new_archive) {
        g_outfp = nafp;
        /* open_old_archive を省略しても、新規書庫に旧属性や初期値0を適用しない。 */
        archive_file_gid = -1;
    }
    Lha_ClearProgressMember();
    for (i = 0; !freshen_only && i < cmd_filec; ++i) {
        if (strcmp(cmd_filev[i], archive_name) == 0)
            continue;
        set_progress_directory_destination(cmd_filev[i]);
        if (Lha_SendCompatProgressMessage(5, basename(cmd_filev[i]), 0, 0))
            fatal_error("User cancelled.");
    }
    Lha_ClearProgressMember();
    if (Lha_SendCompatProgressMessage(3, archive_name, 0, 0))
        fatal_error("User cancelled.");

    /* open old archive if exist */
    if ((oafp = direct_new_archive ? NULL : open_old_archive()) == NULL)
        old_archive_exist = FALSE;
    else
        old_archive_exist = TRUE;
    g_update_archive_fp = oafp;

    if (update_if_newer && cmd_filec == 0 && !explicit_inputs) {
        warning("No files given in argument");
        if (!oafp) {
            error("archive file \"%s\" does not exists.",
                  archive_name);
            exit(1);
        }
    }

    if (new_archive && old_archive_exist) {
        fclose(oafp);
        oafp = NULL;
        g_update_archive_fp = NULL;
    }

    if (oafp && archive_is_msdos_sfx1(archive_name)) {
        seek_lha_header(oafp);
        build_standard_archive_name(new_archive_name_buffer,
                                    archive_name,
                                    sizeof(new_archive_name_buffer));
        new_archive_name = new_archive_name_buffer;
    }
    else {
        new_archive_name = archive_name;
    }

    /* build temporary file */
    if (!noexec && !direct_new_archive)
        nafp = build_temporary_file();
    g_outfp = nafp;

    /* find needed files when automatic update */
    if (update_if_newer && cmd_filec == 0 && !explicit_inputs)
        find_update_files(oafp);

    /* build new archive file */
    /* cleaning arguments */
    cleaning_files(&cmd_filec, &cmd_filev);
#ifdef LHA_LIBRARY
    Lha_OrderCompressionInputs(cmd_filec, cmd_filev);
#endif
    if (cmd_filec == 0 && !explicit_inputs) {
        if (oafp) {
            fclose(oafp);
            g_update_archive_fp = NULL;
            g_infp = NULL;
        }
        if (!noexec) {
            fclose(nafp);
            g_outfp = NULL;
            temporary_fd = -1;
            unlink(temporary_name);
        }
        return;
    }

    /* 拡張全体進捗のための事前スキャン */
    if (Lha_GetEnableTotalProgress()) {
        __int64 total_bytes = 0;
        int total_files = 0;
        for (i = 0; i < cmd_filec; i++) {
            if (strcmp(cmd_filev[i], archive_name) == 0) {
                continue;
            }
            if (is_excluded_compression_input(cmd_filev[i])) goto skip_scan;

            scan_add_files_recursive(cmd_filev[i], &total_bytes, &total_files);

        skip_scan:
            ;
        }
        Lha_SetTotalProgressInfo(total_bytes, total_files);
    }

    for (i = 0; i < cmd_filec; i++) {
        int j;

        if (strcmp(cmd_filev[i], archive_name) == 0) {
            /* exclude target archive */
            warning("specified file \"%s\" is the generating archive. skip",
                    cmd_filev[i]);
            for (j = i; j < cmd_filec-1; j++)
                cmd_filev[j] = cmd_filev[j+1];
            cmd_filec--;
            i--;
            continue;
        }

        if (is_excluded_compression_input(cmd_filev[i])) goto next;

        oafp = append_it(cmd_filev[i], oafp, nafp);
        if (Lha_ShouldDiscardCompressionUpdate()) break;
    next:
        ;
    }

    if (oafp) {
        old_header = ftello(oafp);
        while (!Lha_ShouldDiscardCompressionUpdate() && get_header(oafp, &ahdr)) {
            Lha_RecordEnumHeader(&ahdr);
            notify_add_old_member(&ahdr);
            if (noexec)
                fseeko(oafp, ahdr.packed_size, SEEK_CUR);
            else {
                fseeko(oafp, old_header, SEEK_SET);
                copy_old_one(oafp, nafp, &ahdr);
            }
            old_header = ftello(oafp);
        }
        if (!Lha_ShouldDiscardCompressionUpdate()) Lha_RecordCompressionHeaderEnd();
        fclose(oafp);
        g_update_archive_fp = NULL;
        g_infp = NULL;
    }

    new_archive_size = 0;       /* avoid compiler warnings `uninitialized' */
    if (!noexec) {
        off_t tmp;

        write_archive_tail(nafp);
        tmp = ftello(nafp);
        if (tmp == -1) {
            warning("ftello(): %s", strerror(errno));
            new_archive_size = 0;
        }
        else
            new_archive_size = tmp;

        if (direct_new_archive && Lha_FinishNewCompressionArchive(nafp, new_archive_size) != 0)
            fatal_error("Cannot finish archive file");
        fclose(nafp);
        g_outfp = NULL;
        /* 二重クローズを防止するため、ファイルディスクリプタ変数をリセット */
        temporary_fd = -1;
    }

    /* 共有エラーや f の欠落入力では、先行する圧縮結果も破棄し、書庫と入力を保つ。 */
#ifdef LHA_LIBRARY
    if (!noexec && Lha_ShouldDiscardCompressionUpdate()) {
        g_outfp = NULL;
        unlink(temporary_name);
        Lha_ClearProgressMember();
        return;
    }
#endif

    /* 明示された検索が空でも旧内容の読み取りと完了通知は行い、書庫は置き換えない。 */
    if (!noexec && explicit_inputs && cmd_filec == 0) {
        g_outfp = NULL;
        unlink(temporary_name);
        Lha_SetProgressDestination("");
        if (Lha_SendCompatProgressMessage(1, archive_name, new_archive_size, 0))
            fatal_error("User cancelled.");
        Lha_SendCompatProgressMessage(2, NULL, 0, 0);
        Lha_ClearProgressMember();
        return;
    }

    /* 圧縮結果が空（終端マークのみの1バイト以下）の場合、エラーとする */
    if (!noexec && new_archive_size <= 1) {
        unlink(temporary_name);
        error("No files archived.");
        lha_exit(1);
    }

    /* build backup archive file */
    if (old_archive_exist && backup_old_archive)
        build_backup_file();

    report_archive_name_if_different();

    /* copy temporary file to new archive file */
    if (!noexec) {
        if (added_member_count > 0) {
            Lha_SetProgressDestination(new_archive_name);
            /* 既存書庫の更新では、原版は公開前の完成一時書庫を COPY の
             * source として通知する。新規書庫では temporary_name が最終名
             * のため、従来の通知内容を保つ。 */
            Lha_SendCompatProgressMessage(4, temporary_name, 0, new_archive_size);
            if (Lha_SendCompatProgressMessage(1, temporary_name,
                                              new_archive_size, new_archive_size))
                fatal_error("User cancelled.");
        }
        else {
            /* 原版は不更新でも書庫に書き込み得るが、COPY は出さず最後の旧項目で完了する。 */
            Lha_SetProgressDestination("");
            if (Lha_SendCompatProgressMessage(1, archive_name, new_archive_size, 0))
                fatal_error("User cancelled.");
        }
#ifdef LHA_LIBRARY
        if (!direct_new_archive)
            temporary_to_new_archive_file(new_archive_size);
#else
        if (!direct_new_archive && (strcmp(new_archive_name, "-") == 0 ||
            rename(temporary_name, new_archive_name) < 0)) {
            temporary_to_new_archive_file(new_archive_size);
        }
#endif

        /* set new archive file mode/group */
        set_archive_file_mode();
    }

    Lha_SendCompatProgressMessage(2, NULL, 0, 0);
    Lha_ClearProgressMember();

    /* remove archived files */
    if (delete_after_append) {
        Lha_RestoreCompressionInputOrder(cmd_filec, cmd_filev);
        remove_files(cmd_filec, cmd_filev);
    }

    return;
}

/* ------------------------------------------------------------------------ */
void
cmd_delete()
{
    FILE *oafp, *nafp;
    off_t new_archive_size;

    most_recent = 0;

    /* open old archive if exist */
    if ((oafp = open_old_archive()) == NULL)
        fatal_error("Cannot open archive file \"%s\"", archive_name);

    /* exit if no operation */
    if (cmd_filec == 0) {
        fclose(oafp);
        warning("No files given in argument, do nothing.");
        return;
    }

    if (archive_is_msdos_sfx1(archive_name)) {
        seek_lha_header(oafp);
        build_standard_archive_name(new_archive_name_buffer,
                                    archive_name,
                                    sizeof(new_archive_name_buffer));
        new_archive_name = new_archive_name_buffer;
    }
    else {
        new_archive_name = archive_name;
    }

    /* build temporary file */
    nafp = NULL;                /* avoid compiler warnings `uninitialized' */
    if (!noexec)
        nafp = build_temporary_file();

    /* build new archive file */
    delete(oafp, nafp);
    fclose(oafp);

    new_archive_size = 0;       /* avoid compiler warnings `uninitialized' */
    if (!noexec) {
        off_t tmp;

        write_archive_tail(nafp);
        tmp = ftello(nafp);
        if (tmp == -1) {
            warning("ftello(): %s", strerror(errno));
            new_archive_size = 0;
        }
        else
            new_archive_size = tmp;

        fclose(nafp);
    }

    /* build backup archive file */
    if (backup_old_archive)
        build_backup_file();

    /* 1999.5.24 t.oka */
    if(!noexec && new_archive_size <= 1){
        unlink(temporary_name);
        if (!backup_old_archive)
            unlink(archive_name);
        warning("The archive file \"%s\" was removed because it would be empty.", new_archive_name);
        return;
    }

    report_archive_name_if_different();

    /* copy temporary file to new archive file */
    if (!noexec) {
#ifdef LHA_LIBRARY
        temporary_to_new_archive_file(new_archive_size);
#else
        if (rename(temporary_name, new_archive_name) < 0)
            temporary_to_new_archive_file(new_archive_size);
#endif

        /* set new archive file mode/group */
        set_archive_file_mode();
    }

    return;
}
