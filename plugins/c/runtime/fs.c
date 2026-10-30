#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

static int32_t mn_runtime_fs_error_code(int number) {
    switch (number) {
    case EISDIR:
        return -1;
    case ENAMETOOLONG:
        return -2;
    case ENOENT:
    case ENOTDIR:
        return -3;
    case EACCES:
    case EPERM:
        return -4;
    default:
        return -5;
    }
}

int32_t mn_runtime_fs_open(mn_slice_u8 path) {
    char name[PATH_MAX];
    if (path.length >= sizeof name) return mn_runtime_fs_error_code(ENAMETOOLONG);
    if (memchr(path.items, 0, path.length) != NULL) return mn_runtime_fs_error_code(ENOENT);
    memcpy(name, path.items, path.length);
    name[path.length] = 0;
    int descriptor;
    do {
        descriptor = open(name, O_RDONLY | O_CLOEXEC);
    } while (descriptor < 0 && errno == EINTR);
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
