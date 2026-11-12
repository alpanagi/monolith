#include <stdlib.h>
#include <sys/random.h>

#include "monolith.h"

uint64_t mn_runtime_random_entropy(void) {
    uint64_t seed = 0;
    if (getentropy(&seed, sizeof seed) != 0) abort();
    return seed;
}
