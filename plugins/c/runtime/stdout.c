#include <stdio.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

void mn_runtime_stdout_write(mn_slice_u8 text) {
    fwrite(text.items, 1, text.length, stdout);
}
