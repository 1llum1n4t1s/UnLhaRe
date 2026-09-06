#ifndef DIRENT_MSVC_H
#define DIRENT_MSVC_H

#include <io.h>
#include <string.h>
#include <stdlib.h>
/* Windows の RPC 型定義に LHA の boolean マクロを適用しない。 */
#pragma push_macro("boolean")
#undef boolean
#include <windows.h>
#pragma pop_macro("boolean")

struct dirent {
    char d_name[1024]; /* UTF-8 の名前も切断せず保持する。 */
};

typedef struct {
    intptr_t handle;
    struct _finddata_t info;
    struct _wfinddata_t wide_info;
    struct dirent result;
    int first;
    int unicode;
} DIR;

extern void set_lha_error_invalid_char(const char* name);
extern void fatal_error(char *fmt, ...);
extern unsigned int Lha_GetPathCodePage(void);

static __inline DIR *opendir(const char *name) {
    DIR *dir = (DIR *)malloc(sizeof(DIR));
    if (!dir) return NULL;
    char *path = (char *)malloc(strlen(name) + 3);
    if (!path) { free(dir); return NULL; }
    strcpy(path, name);
    size_t len = strlen(path);
    if (len > 0 && path[len-1] != '/' && path[len-1] != '\\') {
        strcat(path, "/*");
    } else {
        strcat(path, "*");
    }
    dir->unicode = Lha_GetPathCodePage() == CP_UTF8;
    if (dir->unicode) {
        int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
        wchar_t *wide = length > 0 ? (wchar_t *)malloc(length * sizeof(wchar_t)) : NULL;
        if (!wide) { free(path); free(dir); return NULL; }
        MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, length);
        dir->handle = _wfindfirst(wide, &dir->wide_info);
        free(wide);
    } else {
        dir->handle = _findfirst(path, &dir->info);
    }
    free(path);
    if (dir->handle == -1) {
        free(dir);
        return NULL;
    }
    dir->first = 1;
    return dir;
}

static __inline struct dirent *readdir(DIR *dirp) {
    if (!dirp || dirp->handle == -1) return NULL;
    if (dirp->first) {
        dirp->first = 0;
    } else {
        if ((dirp->unicode ? _wfindnext(dirp->handle, &dirp->wide_info)
                          : _findnext(dirp->handle, &dirp->info)) != 0) {
            return NULL;
        }
    }
    
    if (dirp->unicode) {
        if (!WideCharToMultiByte(CP_UTF8, 0, dirp->wide_info.name, -1, dirp->result.d_name,
                                 sizeof(dirp->result.d_name), NULL, NULL)) return NULL;
        return &dirp->result;
    }
    if (strchr(dirp->info.name, '?') != NULL) {
        set_lha_error_invalid_char(dirp->info.name);
        fatal_error((char *)"SJIS error");
    }
    
    strncpy(dirp->result.d_name, dirp->info.name, sizeof(dirp->result.d_name));
    dirp->result.d_name[sizeof(dirp->result.d_name)-1] = '\0';
    return &dirp->result;
}

static __inline int closedir(DIR *dirp) {
    if (!dirp) return -1;
    if (dirp->handle != -1) {
        _findclose(dirp->handle);
    }
    free(dirp);
    return 0;
}

#endif /* DIRENT_MSVC_H */
