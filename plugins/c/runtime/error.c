#include <stdio.h>

#include "monolith.h"

void mn_runtime_error_report(char const *name) {
    fputs(name, stderr);
    fputc('\n', stderr);
}
