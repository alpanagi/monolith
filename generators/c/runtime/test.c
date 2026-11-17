#include <stdio.h>

#include "monolith.h"

static bool mn_runtime_test_has_file = false;

void mn_runtime_test_file(char const *file) {
    if (mn_runtime_test_has_file) fputc('\n', stderr);
    mn_runtime_test_has_file = true;
    fprintf(stderr, "%s\n", file);
}

void mn_runtime_test_start(char const *text) {
    fprintf(stderr, "    %s", text);
    fflush(stderr);
}

void mn_runtime_test_pass(void) {
    fputc('\n', stderr);
}

void mn_runtime_test_failure(void) {
    fputs("  failed: ", stderr);
}

void mn_runtime_test_summary(size_t passed, size_t failed) {
    if (passed + failed > 0) fputc('\n', stderr);
    fprintf(stderr, "%zu passed, %zu failed\n", passed, failed);
}
