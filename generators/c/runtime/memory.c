#include <stdlib.h>
#include <string.h>

#include "monolith.h"

uint8_t *mn_runtime_memory_allocate(size_t size, size_t alignment) {
    if (alignment < alignof(max_align_t)) alignment = alignof(max_align_t);
    size_t rounded = size + (alignment - size % alignment) % alignment;
    if (rounded < size) return NULL;
    if (rounded == 0) rounded = alignment;
    return aligned_alloc(alignment, rounded);
}

void mn_runtime_memory_copy(void *destination, void const *source, size_t size) {
    if (size == 0) return;
    memmove(destination, source, size);
}

void mn_runtime_memory_free(uint8_t *pointer) {
    free(pointer);
}
