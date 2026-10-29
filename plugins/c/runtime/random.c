#include <errno.h>
#include <stdlib.h>
#include <sys/random.h>

#include "monolith.h"

uint64_t mn_runtime_random_entropy(void) {
    uint64_t seed = 0;
    unsigned char *bytes = (unsigned char *)&seed;
    size_t filled = 0;
    while (filled < sizeof seed) {
        ssize_t count = getrandom(bytes + filled, sizeof seed - filled, 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            abort();
        }
        filled += (size_t)count;
    }
    return seed;
}
