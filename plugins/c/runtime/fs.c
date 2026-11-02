#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

typedef struct mn_mn_fs_9Directory_8RawEntry {
    uint8_t const *name;
    size_t length;
    int32_t kind;
} mn_mn_fs_9Directory_8RawEntry;

static int32_t mn_runtime_fs_error_code(int number) {
    switch (number) {
    case EISDIR:
        return -1;
    case ENAMETOOLONG:
        return -2;
    case ENOTDIR:
        return -3;
    case ENOENT:
        return -4;
    case EACCES:
    case EPERM:
        return -5;
    default:
        return -6;
    }
}

static int mn_runtime_fs_open_at(int base, mn_slice_u8 name, int flags, mode_t creation_mode) {
    if (memchr(name.items, 0, name.length - 1) != NULL) {
        errno = ENOENT;
        return -1;
    }
    int descriptor;
    do {
        descriptor = openat(base, (char const *)name.items, flags | O_CLOEXEC, creation_mode);
    } while (descriptor < 0 && errno == EINTR);
    return descriptor;
}

int32_t mn_runtime_fs_open(mn_slice_u8 name, int32_t mode) {
    int flags = mode == 1 ? O_RDWR | O_CREAT | O_TRUNC : O_RDONLY;
    int descriptor = mn_runtime_fs_open_at(AT_FDCWD, name, flags, 0666);
    if (descriptor < 0) return mn_runtime_fs_error_code(errno);
    struct stat status;
    if (fstat(descriptor, &status) != 0) {
        int number = errno;
        close(descriptor);
        return mn_runtime_fs_error_code(number);
    }
    if (S_ISDIR(status.st_mode)) {
        close(descriptor);
        return mn_runtime_fs_error_code(EISDIR);
    }
    return descriptor;
}

ptrdiff_t mn_runtime_fs_size(int32_t descriptor) {
    struct stat status;
    if (fstat(descriptor, &status) != 0) return errno == EIO ? -2 : -5;
    return (ptrdiff_t)status.st_size;
}

void mn_runtime_fs_close(int32_t descriptor) {
    close(descriptor);
}

void *mn_runtime_fs_open_directory(mn_slice_u8 name, int32_t *code) {
    int descriptor = mn_runtime_fs_open_at(AT_FDCWD, name, O_RDONLY | O_DIRECTORY, 0);
    if (descriptor < 0) {
        *code = mn_runtime_fs_error_code(errno);
        return NULL;
    }
    DIR *directory = fdopendir(descriptor);
    if (directory == NULL) {
        *code = mn_runtime_fs_error_code(errno);
        close(descriptor);
        return NULL;
    }
    return directory;
}

static int32_t mn_runtime_fs_entry_kind(DIR *directory, struct dirent const *found) {
#ifdef DT_UNKNOWN
    switch (found->d_type) {
    case DT_REG:
        return 0;
    case DT_DIR:
        return 1;
    case DT_LNK:
        return 2;
    case DT_UNKNOWN:
        break;
    default:
        return 3;
    }
#endif
    struct stat status;
    if (fstatat(dirfd(directory), found->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) return 3;
    if (S_ISREG(status.st_mode)) return 0;
    if (S_ISDIR(status.st_mode)) return 1;
    if (S_ISLNK(status.st_mode)) return 2;
    return 3;
}

int32_t mn_runtime_fs_next_entry(void *handle, mn_mn_fs_9Directory_8RawEntry *entry) {
    DIR *directory = handle;
    while (true) {
        errno = 0;
        struct dirent *found = readdir(directory);
        if (found == NULL) {
            if (errno == 0) return 0;
            return errno == EIO ? -2 : -5;
        }
        if (strcmp(found->d_name, ".") == 0 || strcmp(found->d_name, "..") == 0) continue;
        entry->name = (uint8_t const *)found->d_name;
        entry->length = strlen(found->d_name);
        entry->kind = mn_runtime_fs_entry_kind(directory, found);
        return 1;
    }
}

void mn_runtime_fs_close_directory(void *handle) {
    closedir(handle);
}
