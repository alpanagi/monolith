#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "monolith.h"

#if defined(__APPLE__)
#define mn_modified_time st_mtimespec
#else
#define mn_modified_time st_mtim
#endif

static_assert(PATH_MAX <= 4096, "the buffer of mn::filesystem::Path::absolute holds 4096 bytes");

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

typedef struct mn_mn_filesystem_9Directory_8RawEntry {
    uint8_t const *name;
    size_t length;
    int32_t kind;
} mn_mn_filesystem_9Directory_8RawEntry;

ptrdiff_t mn_runtime_io_error_code(int number);

static int32_t mn_runtime_filesystem_error_code(int number) {
    switch (number) {
    case EISDIR:
        return -1;
    case ENAMETOOLONG:
        return -2;
    case EDQUOT:
    case EFBIG:
    case ENOSPC:
    case EOVERFLOW:
        return -3;
    case ENOTDIR:
        return -4;
    case ENODEV:
    case ENOENT:
    case ENXIO:
        return -5;
    case EACCES:
    case EPERM:
    case EROFS:
        return -6;
    case ELOOP:
    case EMFILE:
    case ENFILE:
    case ENOMEM:
        return -7;
    case EEXIST:
        return -8;
    default:
        return -9;
    }
}

static int32_t mn_runtime_filesystem_mode_kind(mode_t mode) {
    if (S_ISREG(mode)) return 0;
    if (S_ISDIR(mode)) return 1;
    if (S_ISLNK(mode)) return 2;
    return 3;
}

static int mn_runtime_filesystem_open_at(int base, mn_slice_u8 name, int flags, mode_t creation_mode) {
    int descriptor;
    do {
        descriptor = openat(base, (char const *)name.items, flags | O_CLOEXEC, creation_mode);
    } while (descriptor < 0 && errno == EINTR);
    return descriptor;
}

int32_t mn_runtime_filesystem_open(mn_slice_u8 name, int32_t mode) {
    int flags = mode == 1 ? O_RDWR | O_CREAT | O_TRUNC : O_RDONLY;
    int descriptor = mn_runtime_filesystem_open_at(AT_FDCWD, name, flags, 0666);
    if (descriptor < 0) return mn_runtime_filesystem_error_code(errno);
    struct stat status;
    if (fstat(descriptor, &status) != 0) {
        int number = errno;
        close(descriptor);
        return mn_runtime_filesystem_error_code(number);
    }
    if (S_ISDIR(status.st_mode)) {
        close(descriptor);
        return mn_runtime_filesystem_error_code(EISDIR);
    }
    return descriptor;
}

int32_t mn_runtime_filesystem_absolute(mn_slice_u8 name, mn_slice_u8 buffer) {
    char const *resolved = realpath((char const *)name.items, (char *)buffer.items);
    if (resolved == NULL) return mn_runtime_filesystem_error_code(errno);
    return (int32_t)strlen(resolved);
}

int32_t mn_runtime_filesystem_metadata(mn_slice_u8 name, int32_t *kind, size_t *size, int64_t *seconds, uint32_t *nanoseconds) {
    struct stat status;
    if (stat((char const *)name.items, &status) != 0) return mn_runtime_filesystem_error_code(errno);
    *kind = mn_runtime_filesystem_mode_kind(status.st_mode);
    *size = (size_t)status.st_size;
    *seconds = (int64_t)status.mn_modified_time.tv_sec;
    *nanoseconds = (uint32_t)status.mn_modified_time.tv_nsec;
    return 0;
}

ptrdiff_t mn_runtime_filesystem_size(int32_t descriptor) {
    struct stat status;
    if (fstat(descriptor, &status) != 0) return mn_runtime_io_error_code(errno);
    return (ptrdiff_t)status.st_size;
}

void mn_runtime_filesystem_close(int32_t descriptor) {
    close(descriptor);
}

void *mn_runtime_filesystem_open_directory(mn_slice_u8 name, int32_t *code) {
    int descriptor = mn_runtime_filesystem_open_at(AT_FDCWD, name, O_RDONLY | O_DIRECTORY, 0);
    if (descriptor < 0) {
        *code = mn_runtime_filesystem_error_code(errno);
        return NULL;
    }
    DIR *directory = fdopendir(descriptor);
    if (directory == NULL) {
        *code = mn_runtime_filesystem_error_code(errno);
        close(descriptor);
        return NULL;
    }
    return directory;
}

static int32_t mn_runtime_filesystem_entry_kind(DIR *directory, struct dirent const *found) {
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
    return mn_runtime_filesystem_mode_kind(status.st_mode);
}

int32_t mn_runtime_filesystem_next_entry(void *handle, mn_mn_filesystem_9Directory_8RawEntry *entry) {
    DIR *directory = handle;
    while (true) {
        errno = 0;
        struct dirent *found = readdir(directory);
        if (found == NULL) {
            if (errno == 0) return 0;
            return (int32_t)mn_runtime_io_error_code(errno);
        }
        if (strcmp(found->d_name, ".") == 0 || strcmp(found->d_name, "..") == 0) continue;
        entry->name = (uint8_t const *)found->d_name;
        entry->length = strlen(found->d_name);
        entry->kind = mn_runtime_filesystem_entry_kind(directory, found);
        return 1;
    }
}

void mn_runtime_filesystem_close_directory(void *handle) {
    closedir(handle);
}

int32_t mn_runtime_filesystem_create_directory(mn_slice_u8 name) {
    if (mkdir((char const *)name.items, 0777) != 0) return mn_runtime_filesystem_error_code(errno);
    return 0;
}
