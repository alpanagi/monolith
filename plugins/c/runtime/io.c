#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <unistd.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

ptrdiff_t mn_runtime_io_error_code(int number) {
    switch (number) {
    case EPIPE:
        return -1;
    case ECONNABORTED:
    case ECONNRESET:
    case ENETDOWN:
    case ENETUNREACH:
    case ENOTCONN:
    case ETIMEDOUT:
        return -2;
    case EIO:
        return -3;
    case EISDIR:
        return -4;
    case EDQUOT:
    case EFBIG:
    case ENOSPC:
        return -5;
    case EBADF:
        return -6;
    case EAGAIN:
#if EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK:
#endif
        return -7;
    default:
        return -8;
    }
}

ptrdiff_t mn_runtime_io_read(int32_t descriptor, mn_slice_u8 buffer) {
    while (true) {
        ssize_t count = read(descriptor, buffer.items, buffer.length);
        if (count >= 0) return (ptrdiff_t)count;
        if (errno != EINTR) return mn_runtime_io_error_code(errno);
    }
}

static bool mn_runtime_io_pipe_handler_installed = false;

static void mn_runtime_io_ignore_signal(int) {}

static void mn_runtime_io_install_pipe_handler(void) {
    struct sigaction action = {};
    action.sa_handler = mn_runtime_io_ignore_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGPIPE, &action, NULL);
    mn_runtime_io_pipe_handler_installed = true;
}

ptrdiff_t mn_runtime_io_write(int32_t descriptor, mn_slice_u8 bytes) {
    if (!mn_runtime_io_pipe_handler_installed) mn_runtime_io_install_pipe_handler();
    size_t written = 0;
    while (written < bytes.length) {
        ssize_t count = write(descriptor, bytes.items + written, bytes.length - written);
        if (count < 0) {
            if (errno == EINTR) continue;
            return mn_runtime_io_error_code(errno);
        }
        written += (size_t)count;
    }
    return 0;
}
