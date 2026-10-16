/* Deterministic clock_gettime injection. Compile platform/runtime with
 * -Dclock_gettime=orin_test_clock_gettime. CLOCK_STUB_ONLY supplies a failing clock to Orin programs. */
#include "orin_runtime.h"
#include "orin_runtime_io.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int fail_clock = 1;
static struct timespec sample;
int orin_test_clock_gettime(clockid_t which, struct timespec *out) {
    if (fail_clock || which != CLOCK_MONOTONIC) { errno = EINVAL; return -1; }
    *out = sample;
    return 0;
}

#ifndef CLOCK_STUB_ONLY
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "clock test failed: %s\n", #c); return 1; } } while (0)
int main(int argc, char **argv) {
    orin_init(argc, argv);
    if (argc > 1 && strcmp(argv[1], "platform") == 0) {
        CHECK(orin_platform_monotonic_millis() == -1); /* output was never initialized */
        fail_clock = 0;
        sample.tv_sec = 0; sample.tv_nsec = 0;
        CHECK(orin_platform_monotonic_millis() == 0);
        int64_t grant = orin_cap_clock(orin_cap_host_root());
        OrinObj *zero = orin_time_monotonic_millis(grant);
        CHECK(orin_tag(zero) == 0 && orin_struct_get(zero, 0) == 0);
        orin_release(zero);
        sample.tv_sec = 1; sample.tv_nsec = 234567890;
        CHECK(orin_platform_monotonic_millis() == 1234);
        sample.tv_sec = -1;
        CHECK(orin_platform_monotonic_millis() == -1);
        sample.tv_sec = 0; sample.tv_nsec = -1;
        CHECK(orin_platform_monotonic_millis() == -1);
        sample.tv_nsec = 1000000000;
        CHECK(orin_platform_monotonic_millis() == -1);
        sample.tv_sec = INT64_MAX / 1000; sample.tv_nsec = (INT64_MAX % 1000) * 1000000;
        CHECK(orin_platform_monotonic_millis() == INT64_MAX);
        OrinObj *largest = orin_time_monotonic_millis(grant);
        CHECK(orin_tag(largest) == 0 && orin_struct_get(largest, 0) == INT64_MAX);
        orin_release(largest);
        orin_cap_revoke(grant);
        sample.tv_nsec += 1000000;
        CHECK(orin_platform_monotonic_millis() == -1);
        sample.tv_sec = INT64_MAX; sample.tv_nsec = 0;
        CHECK(orin_platform_monotonic_millis() == -1);
        puts("platform clock cases passed"); return 0;
    }
    int64_t host = orin_cap_host_root();
    if (argc > 1 && strcmp(argv[1], "net") == 0) {
        (void)orin_net_now(orin_cap_net(host)); /* must trap, never fabricate a network deadline */
    } else {
        int64_t clock = argc > 1 && strcmp(argv[1], "wrong") == 0 ? orin_cap_fs(host) : orin_cap_clock(host);
        if (argc > 1 && strcmp(argv[1], "revoked") == 0) orin_cap_revoke(clock);
        OrinObj *r = orin_time_monotonic_millis(clock);
        CHECK(orin_tag(r) == 1);
        orin_release(r);
        orin_cap_revoke(clock);
        puts("clock failure returned None"); return 0;
    }
    return 2;
}
#endif
