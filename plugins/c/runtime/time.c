#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <time.h>

#include "monolith.h"

void mn_runtime_time_wall_clock(int64_t *seconds, uint32_t *nanoseconds) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) abort();
    *seconds = (int64_t)now.tv_sec;
    *nanoseconds = (uint32_t)now.tv_nsec;
}

int64_t mn_runtime_time_monotonic_clock(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (int64_t)now.tv_sec * INT64_C(1000000000) + (int64_t)now.tv_nsec;
}
