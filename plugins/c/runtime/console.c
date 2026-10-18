#include <stdio.h>

#include "monolith.h"

void mn_console_write(string text) {
    fwrite(text.bytes, 1, text.length, stdout);
}
