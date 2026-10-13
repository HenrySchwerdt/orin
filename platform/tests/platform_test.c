/* L0 platform layer: executable test of every contract in platform/orin_platform.h, including error
 * paths (missing file, NUL in path, directory, EOF, short read, huge request). Tests may use libc.
 * Build/run: tools/verify_platform.sh  (or cc -I platform platform/tests/platform_test.c platform/orin_platform.c) */
#define _GNU_SOURCE
#include "../orin_platform.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures, checks;
#define CHECK(c)                                                                                \
    do {                                                                                        \
        checks++;                                                                               \
        if (!(c)) {                                                                             \
            failures++;                                                                         \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                        \
        }                                                                                       \
    } while (0)

static char tmpdir[256];
static char *P(const char *name) {
    static char buf[4][512];
    static int k;
    k = (k + 1) % 4;
    snprintf(buf[k], sizeof buf[k], "%s/%s", tmpdir, name);
    return buf[k];
}

static void test_memory(void) {
    void *p = orin_platform_alloc(0);
    CHECK(p != NULL && (size_t)p % 16 == 0);
    p = orin_platform_realloc(p, 100);
    CHECK(p != NULL);
    orin_platform_mem_set(p, 0xAB, 100);
    p = orin_platform_realloc(p, 1000);
    CHECK(p && ((unsigned char *)p)[0] == 0xAB && ((unsigned char *)p)[99] == 0xAB);
    volatile size_t huge = (size_t)-1;
    CHECK(orin_platform_alloc(huge) == NULL); /* failure is NULL, not a crash */
    void *volatile vp = p;
    void *q = orin_platform_realloc(vp, huge);
    CHECK(q == NULL && ((unsigned char *)vp)[50] == 0xAB); /* old block still valid */
    orin_platform_free(vp);
    orin_platform_free(NULL);

    char a[8] = "abcdefg", b[8];
    CHECK(orin_platform_mem_copy(b, a, 8) == b && orin_platform_mem_cmp(a, b, 8) == 0);
    CHECK(orin_platform_mem_copy(NULL, NULL, 0) == NULL);
    orin_platform_mem_move(a + 1, a, 6); /* overlapping */
    CHECK(memcmp(a, "aabcdef", 7) == 0);
    orin_platform_mem_move(a, a + 1, 6);
    CHECK(memcmp(a, "abcdef", 6) == 0);
    CHECK(orin_platform_mem_cmp("abc", "abd", 3) < 0 && orin_platform_mem_cmp("abd", "abc", 3) > 0);
    CHECK(orin_platform_mem_cmp("a\200", "a\001", 2) > 0); /* unsigned comparison */
    CHECK(orin_platform_mem_cmp(NULL, NULL, 0) == 0);
    CHECK(orin_platform_mem_cmp("abc", "abd", 2) == 0);
}

static void test_find(void) {
    const char *h = "abcabcabd";
    CHECK(orin_platform_mem_find(h, 9, "abd", 3) == h + 6);
    CHECK(orin_platform_mem_find(h, 9, "abc", 3) == h);
    CHECK(orin_platform_mem_find(h, 9, "c", 1) == h + 2);
    CHECK(orin_platform_mem_find(h, 9, "", 0) == h);
    CHECK(orin_platform_mem_find(h, 0, "", 0) == h);
    CHECK(orin_platform_mem_find(h, 9, "abdd", 4) == NULL);
    CHECK(orin_platform_mem_find(h, 2, "abc", 3) == NULL); /* needle longer than haystack */
    CHECK(orin_platform_mem_find(h, 8, "abd", 3) == NULL);  /* match would cross the end */
    CHECK(orin_platform_mem_find(h, 9, "z", 1) == NULL);
    CHECK(orin_platform_mem_find("a\0b", 3, "\0b", 2) != NULL); /* NUL bytes are ordinary */
    const char *aab = "aab";
    CHECK(orin_platform_mem_find(aab, 3, "ab", 2) == aab + 1); /* partial match then real match */
}

static void test_fmt(void) {
    char b[32];
    struct { int64_t v; const char *s; } si[] = {{0, "0"}, {7, "7"}, {-7, "-7"}, {10, "10"}, {INT64_MAX, "9223372036854775807"},
                                                  {INT64_MIN, "-9223372036854775808"}, {-1, "-1"}, {100000, "100000"}};
    for (size_t i = 0; i < sizeof si / sizeof si[0]; i++) {
        size_t n = orin_platform_fmt_i64(b, si[i].v);
        CHECK(n == strlen(si[i].s) && memcmp(b, si[i].s, n) == 0);
    }
    struct { uint64_t v; const char *s; } su[] = {{0, "0"}, {9, "9"}, {UINT64_MAX, "18446744073709551615"}, {1000, "1000"}};
    for (size_t i = 0; i < sizeof su / sizeof su[0]; i++) {
        size_t n = orin_platform_fmt_u64(b, su[i].v);
        CHECK(n == strlen(su[i].s) && memcmp(b, su[i].s, n) == 0);
    }
    for (int64_t v = -2000; v <= 2000; v += 7) { /* agrees with snprintf */
        char r[32];
        size_t n = orin_platform_fmt_i64(b, v);
        snprintf(r, sizeof r, "%lld", (long long)v);
        CHECK(n == strlen(r) && memcmp(b, r, n) == 0);
    }
}

static void test_files(void) {
    char *buf = (char *)1;
    size_t n = 99;
    const char *path = P("a.bin");
    const char data[] = {'x', 0, 'y', '\n', (char)0xff};
    CHECK(orin_platform_file_exists(path, strlen(path)) == 0);
    CHECK(orin_platform_file_read(path, strlen(path), &buf, &n) == ENOENT); /* missing file */
    CHECK(buf == NULL && n == 0);
    CHECK(strstr(orin_platform_error_message(ENOENT), "No such file") != NULL);
    CHECK(orin_platform_file_write(path, strlen(path), data, sizeof data) == 0);
    CHECK(orin_platform_file_exists(path, strlen(path)) == 1);
    CHECK(orin_platform_file_read(path, strlen(path), &buf, &n) == 0 && n == sizeof data && memcmp(buf, data, n) == 0);
    orin_platform_free(buf);
    /* empty file */
    const char *e = P("empty");
    CHECK(orin_platform_file_write(e, strlen(e), NULL, 0) == 0);
    CHECK(orin_platform_file_read(e, strlen(e), &buf, &n) == 0 && n == 0 && buf != NULL);
    orin_platform_free(buf);
    /* larger than the initial 4096 buffer and than one doubling */
    size_t big = 100000;
    char *src = (char *)malloc(big);
    for (size_t i = 0; i < big; i++) src[i] = (char)(i * 31);
    const char *bp = P("big");
    CHECK(orin_platform_file_write(bp, strlen(bp), src, big) == 0);
    CHECK(orin_platform_file_read(bp, strlen(bp), &buf, &n) == 0 && n == big && memcmp(buf, src, big) == 0);
    orin_platform_free(buf);
    free(src);
    /* overwrite truncates */
    CHECK(orin_platform_file_write(path, strlen(path), "hi", 2) == 0);
    CHECK(orin_platform_file_read(path, strlen(path), &buf, &n) == 0 && n == 2 && memcmp(buf, "hi", 2) == 0);
    orin_platform_free(buf);
    /* NUL byte in path: EINVAL, nothing touched */
    CHECK(orin_platform_file_read("a\0b", 3, &buf, &n) == ORIN_PLATFORM_EINVAL && buf == NULL);
    CHECK(orin_platform_file_write("a\0b", 3, "x", 1) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_file_exists("a\0b", 3) == 0);
    CHECK(access("a", F_OK) != 0);
    /* directory: cannot be read, can be "existing"; unwritable path */
    CHECK(orin_platform_file_exists(tmpdir, strlen(tmpdir)) == 1);
    CHECK(orin_platform_file_read(tmpdir, strlen(tmpdir), &buf, &n) == EISDIR);
    const char *nd = P("no/such/dir/f");
    CHECK(orin_platform_file_write(nd, strlen(nd), "x", 1) == ENOENT);
    CHECK(orin_platform_file_write(tmpdir, strlen(tmpdir), "x", 1) == EISDIR);
    CHECK(orin_platform_file_exists("", 0) == 0);
    CHECK(orin_platform_file_read("", 0, &buf, &n) == ENOENT);
    /* path length is honoured, not strlen: a prefix of a real name is a different name */
    CHECK(orin_platform_file_exists(path, strlen(path) - 1) == 0);
    /* /dev/full: a failed write is reported (Linux only) */
    if (access("/dev/full", W_OK) == 0) CHECK(orin_platform_file_write("/dev/full", 9, "x", 1) == ENOSPC);
}

static int capture(void (*fn)(void), char *out, size_t cap, int fd_to_capture) {
    int pfd[2];
    if (pipe(pfd)) return -1;
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pfd[1], fd_to_capture);
        close(pfd[0]);
        close(pfd[1]);
        fn();
        fflush(stdout);
        fflush(stderr);
        _exit(0);
    }
    close(pfd[1]);
    size_t got = 0;
    ssize_t k;
    while ((k = read(pfd[0], out + got, cap - 1 - got)) > 0) got += (size_t)k;
    out[got] = 0;
    close(pfd[0]);
    int st;
    waitpid(pid, &st, 0);
    return st;
}

static void w_out(void) {
    orin_platform_write(ORIN_PLATFORM_STDOUT, "ab", 2);
    orin_platform_write(ORIN_PLATFORM_STDOUT, "", 0);
    orin_platform_write_line(ORIN_PLATFORM_STDOUT, "cd", 2);
    orin_platform_write_line(ORIN_PLATFORM_STDOUT, "", 0);
    orin_platform_write(ORIN_PLATFORM_STDOUT, "x\0y", 3); /* binary safe */
    orin_platform_flush();
}
static void w_err(void) {
    orin_platform_write(ORIN_PLATFORM_STDOUT, "out1 ", 5); /* buffered, must come first */
    orin_platform_write_line(ORIN_PLATFORM_STDERR, "err1", 4);
}
static void w_exit(void) {
    orin_platform_write(ORIN_PLATFORM_STDOUT, "bye", 3);
    orin_platform_exit(7);
}
static void w_abort(void) { orin_platform_abort(); }
static void w_shell(void) {
    orin_platform_write(ORIN_PLATFORM_STDOUT, "pre;", 4);
    int64_t a = orin_platform_shell("echo hi; exit 3", 15);
    int64_t b = orin_platform_shell("true", 4);
    int64_t c = orin_platform_shell("kill -9 $$", 10);
    int64_t d = orin_platform_shell("echo cut\0rest", 13); /* bytes after NUL ignored */
    printf(";%lld,%lld,%lld,%lld", (long long)a, (long long)b, (long long)c, (long long)d);
}
static void w_args(void) {
    char *argv[] = {"prog", "one", "two"};
    int before = failures;
    CHECK(orin_platform_arg_count() == 0);
    orin_platform_init(3, argv);
    CHECK(orin_platform_arg_count() == 3 && strcmp(orin_platform_arg(0), "prog") == 0 && strcmp(orin_platform_arg(2), "two") == 0);
    CHECK(orin_platform_getenv("ORIN_PLATFORM_TEST_VAR") && strcmp(orin_platform_getenv("ORIN_PLATFORM_TEST_VAR"), "v1") == 0);
    CHECK(orin_platform_getenv("ORIN_PLATFORM_SURELY_UNSET") == NULL);
    printf("%d", failures - before);
}
static void hook1(void) { fputs("[h1]", stdout); }
static void hook2(void) { fputs("[h2]", stdout); }
static void w_atexit(void) {
    CHECK(orin_platform_at_exit(hook1) == 0 && orin_platform_at_exit(hook2) == 0);
    orin_platform_exit(0);
}

static void test_process_and_output(void) {
    char out[512];
    int st = capture(w_out, out, sizeof out, 1);
    CHECK(WIFEXITED(st) && memcmp(out, "abcd\n\nx\0y", 9) == 0);
    {   /* ordering: capture both streams on one pipe */
        int pfd[2];
        CHECK(pipe(pfd) == 0);
        fflush(stdout);
        pid_t pid = fork();
        if (pid == 0) { dup2(pfd[1], 1); dup2(pfd[1], 2); close(pfd[0]); w_err(); fflush(stdout); _exit(0); }
        close(pfd[1]);
        size_t got = 0;
        ssize_t k;
        while ((k = read(pfd[0], out + got, sizeof out - 1 - got)) > 0) got += (size_t)k;
        out[got] = 0;
        close(pfd[0]);
        waitpid(pid, &st, 0);
        CHECK(strcmp(out, "out1 err1\n") == 0);
    }
    st = capture(w_exit, out, sizeof out, 1);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 7 && strcmp(out, "bye") == 0); /* exit flushes */
    st = capture(w_abort, out, sizeof out, 1);
    CHECK(WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
    st = capture(w_shell, out, sizeof out, 1);
    CHECK(strstr(out, "pre;hi\n") == out && strstr(out, ";3,0,-1,0") != NULL); /* shell flushes stdout first */
    setenv("ORIN_PLATFORM_TEST_VAR", "v1", 1);
    st = capture(w_args, out, sizeof out, 1);
    CHECK(strcmp(out, "0") == 0);
    st = capture(w_atexit, out, sizeof out, 1);
    CHECK(strcmp(out, "[h2][h1]") == 0);
}

static void test_stdin(void) {
    /* stdin is a temp file: "line1\nabcdef" then EOF */
    const char *p = P("stdin.txt");
    FILE *f = fopen(p, "wb");
    fputs("line1\nabcdef", f);
    fclose(f);
    int fd = open(p, O_RDONLY);
    dup2(fd, 0);
    close(fd);
    CHECK(orin_platform_stdin_getc() == 'l');
    char buf[16];
    CHECK(orin_platform_stdin_read(buf, 4) == 4 && memcmp(buf, "ine1", 4) == 0);
    CHECK(orin_platform_stdin_getc() == '\n');
    CHECK(orin_platform_stdin_read(buf, 0) == 0);
    CHECK(orin_platform_stdin_read(buf, 3) == 3 && memcmp(buf, "abc", 3) == 0);
    CHECK(orin_platform_stdin_read(buf, 10) == 3 && memcmp(buf, "def", 3) == 0); /* short read at EOF */
    CHECK(orin_platform_stdin_read(buf, 5) == 0);
    CHECK(orin_platform_stdin_getc() == -1);
    CHECK(orin_platform_stdin_getc() == -1); /* EOF is sticky */
    /* a 0xff byte is a byte, not EOF */
    f = fopen(p, "wb");
    fputc(0xff, f);
    fclose(f);
    fd = open(p, O_RDONLY);
    dup2(fd, 0);
    close(fd);
    clearerr(stdin);
    CHECK(orin_platform_stdin_getc() == 255 && orin_platform_stdin_getc() == -1);
}

int main(void) {
    snprintf(tmpdir, sizeof tmpdir, "/tmp/orin_platform_test_%d", (int)getpid());
    mkdir(tmpdir, 0700);
    test_memory();
    test_find();
    test_fmt();
    test_files();
    test_process_and_output();
    test_stdin();
    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmpdir);
    if (system(cmd)) {}
    if (failures) {
        fprintf(stderr, "platform_test: %d of %d checks FAILED\n", failures, checks);
        return 1;
    }
    printf("platform_test: %d checks passed\n", checks);
    return 0;
}
