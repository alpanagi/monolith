#include <stdio.h>

#include "monolith.h"

void mn_runtime_test_failure(char const *file, size_t row, char const *text) {
    fprintf(stderr, "%s:%zu: test \"%s\" failed: ", file, row, text);
}

void mn_runtime_test_summary(size_t passed, size_t failed) {
    fprintf(stderr, "%zu passed, %zu failed\n", passed, failed);
}
