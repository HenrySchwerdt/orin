/* Runtime adapter: discard partial listings without leaking, propagate OOM, and sort unsigned bytes.
 * Link platform with -Dorin_platform_dir_list=orin_platform_dir_list_real; other primitives stay real. */
#include "orin_runtime.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int error_code;
int orin_platform_dir_list(const char *path, size_t plen,
                          void (*each)(void *, const char *, size_t, int), void *ctx) {
    (void)path; (void)plen;
    each(ctx, "\377", 1, 0);
    each(ctx, "a.", 2, 0);
    each(ctx, "\200", 1, 0);
    each(ctx, "a-", 2, 1);
    each(ctx, "a", 1, 0);
    return error_code;
}
/* The unwrap helpers are Orin functions now ($rt/leaf.or, ADR-0052 R3d.2); this test reads the payload slot directly. */
static uint64_t orin_res_unwrap(OrinObj *r) { return orin_tag(r) == 0 ? orin_struct_get(r, 0) : 0; }
static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)
static int cleanup_fd;
static int64_t cleanup_baseline;
static void report_cleanup(void) {
    char result = orin_live_count() == cleanup_baseline ? 'Y' : 'N';
    (void)write(cleanup_fd, &result, 1);
}

static void expect_failure(int64_t fs, OrinObj *path, int code, int64_t baseline) {
    int report[2];
    if (pipe(report) != 0) { CHECK(0); return; }
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(report[0]);
        cleanup_fd = report[1];
        cleanup_baseline = baseline;
        CHECK(atexit(report_cleanup) == 0);
        error_code = code;
        (void)freopen("/dev/null", "w", stderr);
        OrinObj *r = orin_fs_list_dir(fs, path);
        int bad = orin_tag(r) == 1; /* every enumeration failure is an Err; out of memory still traps (101) */
        orin_release(r);
        exit(bad ? 101 : 0); /* exit, not _exit: the atexit hook reports the leak check */
    }
    close(report[1]);
    if (child > 0) {
        int status = 0;
        CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 101);
        char result = 0;
        CHECK(read(report[0], &result, 1) == 1 && result == 'Y');
    }
    close(report[0]);
}

int main(int argc, char **argv) {
    orin_init(argc, argv);
    int64_t host = orin_cap_host_root(), fs = orin_cap_fs(host);
    OrinObj *path = orin_str_new(".", 1);
    int64_t baseline = orin_live_count();
    const int errors[] = { EIO, EACCES, ENOENT, ENOTDIR, ENOMEM };
    for (size_t i = 0; i < sizeof errors / sizeof *errors; i++) {
        expect_failure(fs, path, errors[i], baseline);
        CHECK(orin_live_count() == baseline);
    }
    error_code = 0;
    const char *expected[] = {"a", "a-/", "a.", "\200", "\377"};
    OrinObj *result = orin_fs_list_dir(fs, path);
    CHECK(orin_tag(result) == 0);
    OrinObj *entries = ORIN_REF(orin_res_unwrap(result));
    CHECK(orin_array_len(entries) == 5);
    for (size_t i = 0; i < orin_array_len(entries) && i < 5; i++) {
        OrinObj *entry = ORIN_REF(orin_array_at(entries, i));
        CHECK(orin_str_len(entry) == strlen(expected[i]));
        CHECK(memcmp(orin_str_data(entry), expected[i], strlen(expected[i])) == 0);
    }
    orin_release(result);
    CHECK(orin_live_count() == baseline);
    orin_release(path);
    orin_cap_revoke(fs); orin_cap_revoke(host);
    CHECK(orin_live_count() == baseline - 1);
    if (failures) return 1;
    puts("runtime dir_fault_test: error traps, partial cleanup, unsigned order and OOM passed");
    return 0;
}
