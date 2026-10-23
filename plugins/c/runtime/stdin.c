#include <unistd.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

size_t mn_runtime_stdin_read(mn_slice_u8 buffer) {
    ssize_t count = read(0, buffer.items, buffer.length);
    return count < 0 ? 0 : (size_t)count;
}
