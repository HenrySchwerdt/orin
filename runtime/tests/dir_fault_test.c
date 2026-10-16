/* Runtime adapter: discard partial listings without leaking, propagate OOM, and sort unsigned bytes.
 * Link platform with -Dorin_platform_dir_list=orin_platform_dir_list_real; other primitives stay real. */
#include "orin_runtime.h"
#include <errno.h>
#include <stdio.h>
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
static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)
int main(int argc, char **argv) {
    orin_init(argc, argv);
    int64_t host = orin_cap_host_root(), fs = orin_cap_fs(host);
    OrinObj *path = orin_str_new(".", 1);
    int64_t baseline = orin_live_count();
    error_code = EIO;
    for (int round = 0; round < 32; round++) {
        OrinObj *entries = orin_fs_list_dir(fs, path);
        CHECK(orin_array_len(entries) == 0);
        orin_release(entries);
        CHECK(orin_live_count() == baseline);
    }
    error_code = 0;
    const char *expected[] = {"a", "a-/", "a.", "\200", "\377"};
    OrinObj *entries = orin_fs_list_dir(fs, path);
    CHECK(orin_array_len(entries) == 5);
    for (size_t i = 0; i < orin_array_len(entries) && i < 5; i++) {
        OrinObj *entry = ORIN_REF(orin_array_at(entries, i));
        CHECK(orin_str_len(entry) == strlen(expected[i]));
        CHECK(memcmp(orin_str_data(entry), expected[i], strlen(expected[i])) == 0);
    }
    orin_release(entries);
    CHECK(orin_live_count() == baseline);
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        error_code = ENOMEM;
        (void)freopen("/dev/null", "w", stderr);
        orin_release(orin_fs_list_dir(fs, path));
        _exit(0);
    }
    if (child > 0) {
        int status = 0;
        CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 101);
    }
    orin_release(path);
    orin_cap_revoke(fs); orin_cap_revoke(host);
    CHECK(orin_live_count() == baseline - 1);
    if (failures) return 1;
    puts("runtime dir_fault_test: partial cleanup, unsigned order and OOM passed");
    return 0;
}
