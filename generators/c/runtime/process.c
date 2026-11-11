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

typedef struct mn_optional_slice_u8 {
    mn_slice_u8 value;
    bool present;
} mn_optional_slice_u8;

extern char **environ;

static mn_slice_slice_u8 mn_runtime_process_saved_arguments;
static mn_slice_u8 mn_runtime_process_saved_invoked_as;

void mn_runtime_process_start(int count, char **values, mn_slice_u8 *arguments) {
    size_t length = count > 0 ? (size_t)count - 1 : 0;
    for (size_t index = 0; index < length; index += 1) {
        char *value = values[index + 1];
        arguments[index] = (mn_slice_u8){ .items = (uint8_t *)value, .length = strlen(value) };
    }
    mn_runtime_process_saved_arguments = (mn_slice_slice_u8){ .items = arguments, .length = length };
    char *first = count > 0 ? values[0] : "";
    mn_runtime_process_saved_invoked_as = (mn_slice_u8){ .items = (uint8_t *)first, .length = strlen(first) };
}

mn_slice_slice_u8 mn_runtime_process_arguments(void) {
    return mn_runtime_process_saved_arguments;
}

mn_slice_u8 mn_runtime_process_invoked_as(void) {
    return mn_runtime_process_saved_invoked_as;
}

mn_optional_slice_u8 mn_runtime_process_environment_variable(mn_slice_u8 name) {
    for (char **entry = environ; entry != NULL && *entry != NULL; entry += 1) {
        uint8_t *bytes = (uint8_t *)*entry;
        size_t index = 0;
        while (index < name.length && bytes[index] != 0 && bytes[index] == name.items[index]) index += 1;
        if (index != name.length || bytes[index] != '=') continue;
        uint8_t *value = bytes + index + 1;
        return (mn_optional_slice_u8){ .value = { .items = value, .length = strlen((char *)value) }, .present = true };
    }
    return (mn_optional_slice_u8){ .present = false };
}
