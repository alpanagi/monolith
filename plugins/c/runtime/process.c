#include <string.h>

#include "monolith.h"

typedef struct mn_slice_u8 {
    uint8_t *items;
    size_t length;
} mn_slice_u8;

typedef struct mn_slice_slice_u8 {
    mn_slice_u8 *items;
    size_t length;
} mn_slice_slice_u8;

static mn_slice_slice_u8 mn_runtime_process_saved_arguments;

void mn_runtime_process_start(int count, char **values, mn_slice_u8 *arguments) {
    for (int index = 0; index < count; index += 1) {
        arguments[index] = (mn_slice_u8){ .items = (uint8_t *)values[index], .length = strlen(values[index]) };
    }
    mn_runtime_process_saved_arguments = (mn_slice_slice_u8){ .items = arguments, .length = (size_t)count };
}

mn_slice_slice_u8 mn_runtime_process_arguments(void) {
    return mn_runtime_process_saved_arguments;
}
