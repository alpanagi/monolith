#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "monolith.h"

#if defined(__APPLE__)
#define mn_access_time st_atimespec
#define mn_modified_time st_mtimespec
#else
#define mn_access_time st_atim
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
    case ENOTEMPTY:
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

static int mn_runtime_filesystem_move_exclusive(char const *from, char const *to) {
#if defined(__APPLE__)
    return renamex_np(from, to, RENAME_EXCL);
#elif defined(RENAME_NOREPLACE)
    return renameat2(AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE);
#else
    errno = ENOSYS;
    return -1;
#endif
}

static int mn_runtime_filesystem_clear_target(char const *target, bool overwrite) {
    if (!overwrite || unlink(target) == 0 || errno == ENOENT) return 0;
    return -1;
}

static int mn_runtime_filesystem_copy_by_reading(int source, int target) {
    char buffer[65536];
    while (true) {
        ssize_t count = read(source, buffer, sizeof buffer);
        if (count == 0) return 0;
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t written = 0;
        while (written < count) {
            ssize_t result = write(target, buffer + written, (size_t)(count - written));
            if (result < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            written += result;
        }
    }
}

static int mn_runtime_filesystem_copy_contents(int source, int target) {
#if defined(__linux__)
    while (true) {
        ssize_t copied = copy_file_range(source, NULL, target, NULL, (size_t)1 << 30, 0);
        if (copied == 0) return 0;
        if (copied > 0) continue;
        if (errno == EINTR) continue;
        if (errno != EXDEV && errno != ENOSYS && errno != EINVAL && errno != EOPNOTSUPP) return -1;
        break;
    }
#endif
    return mn_runtime_filesystem_copy_by_reading(source, target);
}

static int mn_runtime_filesystem_copy_ownership(int descriptor, struct stat const *status) {
    if (fchown(descriptor, status->st_uid, status->st_gid) == 0) return 0;
    if (errno != EPERM) return -1;
    if (fchown(descriptor, (uid_t)-1, status->st_gid) == 0 || errno == EPERM) return 0;
    return -1;
}

static int mn_runtime_filesystem_copy_attributes(int descriptor, struct stat const *status) {
    if (mn_runtime_filesystem_copy_ownership(descriptor, status) != 0) return -1;
    if (fchmod(descriptor, status->st_mode & 07777) != 0) return -1;
    struct timespec const times[2] = { status->mn_access_time, status->mn_modified_time };
    return futimens(descriptor, times);
}

static int mn_runtime_filesystem_copy_file(mn_slice_u8 from, mn_slice_u8 to, bool overwrite) {
    int source = mn_runtime_filesystem_open_at(AT_FDCWD, from, O_RDONLY | O_NOFOLLOW, 0);
    if (source < 0) return -1;
    struct stat status;
    if (fstat(source, &status) != 0 || mn_runtime_filesystem_clear_target((char const *)to.items, overwrite) != 0) {
        int number = errno;
        close(source);
        errno = number;
        return -1;
    }
    int target = mn_runtime_filesystem_open_at(AT_FDCWD, to, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (target < 0) {
        int number = errno;
        close(source);
        errno = number;
        return -1;
    }
    bool is_copied = mn_runtime_filesystem_copy_contents(source, target) == 0 && mn_runtime_filesystem_copy_attributes(target, &status) == 0;
    int number = errno;
    close(source);
    if (close(target) != 0 && is_copied) {
        is_copied = false;
        number = errno;
    }
    if (is_copied) return 0;
    unlink((char const *)to.items);
    errno = number;
    return -1;
}

static int mn_runtime_filesystem_copy_link(char const *source, char const *target, bool overwrite) {
    char link_target[PATH_MAX];
    ssize_t length = readlink(source, link_target, sizeof link_target);
    if (length < 0) return -1;
    if ((size_t)length >= sizeof link_target) {
        errno = ENAMETOOLONG;
        return -1;
    }
    link_target[length] = 0;
    if (mn_runtime_filesystem_clear_target(target, overwrite) != 0) return -1;
    return symlink(link_target, target);
}

int32_t mn_runtime_filesystem_move(mn_slice_u8 from, mn_slice_u8 to, bool overwrite) {
    char const *source = (char const *)from.items;
    char const *target = (char const *)to.items;
    struct stat status;
    if (lstat(source, &status) != 0) return mn_runtime_filesystem_error_code(errno);
    if (S_ISDIR(status.st_mode)) return mn_runtime_filesystem_error_code(EISDIR);
    int renamed = overwrite ? rename(source, target) : mn_runtime_filesystem_move_exclusive(source, target);
    if (renamed == 0) return 0;
    if (errno != EXDEV || !(S_ISREG(status.st_mode) || S_ISLNK(status.st_mode))) return mn_runtime_filesystem_error_code(errno);
    int copied = S_ISREG(status.st_mode) ? mn_runtime_filesystem_copy_file(from, to, overwrite) : mn_runtime_filesystem_copy_link(source, target, overwrite);
    if (copied != 0) return mn_runtime_filesystem_error_code(errno);
    if (unlink(source) != 0) return mn_runtime_filesystem_error_code(errno);
    return 0;
}
