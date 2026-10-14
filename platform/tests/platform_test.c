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
    /* The result goes through a volatile so the allocation escapes: clang may otherwise elide a malloc whose
       result is only compared with NULL and fold the comparison to false (seen on macOS). */
    void *volatile hp = orin_platform_alloc(huge);
    CHECK(hp == NULL); /* failure is NULL, not a crash */
    orin_platform_free(hp);
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

static void test_streams(void) {
    orin_platform_stream *s = (orin_platform_stream *)1;
    char buf[64];
    const char *p = P("stream.txt");
    /* open errors: nothing is opened, *out is NULL */
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_READ, &s) == ENOENT && s == NULL);
    CHECK(orin_platform_stream_open("a\0b", 3, ORIN_PLATFORM_STREAM_WRITE, &s) == ORIN_PLATFORM_EINVAL && s == NULL);
    CHECK(orin_platform_stream_open(p, strlen(p), 7, &s) == ORIN_PLATFORM_EINVAL && s == NULL);
    CHECK(orin_platform_stream_open(p, strlen(p), -1, &s) == ORIN_PLATFORM_EINVAL && s == NULL);
    CHECK(orin_platform_stream_open(tmpdir, strlen(tmpdir), ORIN_PLATFORM_STREAM_WRITE, &s) == EISDIR && s == NULL);
    const char *nd = P("no_such_dir/x");
    CHECK(orin_platform_stream_open(nd, strlen(nd), ORIN_PLATFORM_STREAM_WRITE, &s) == ENOENT && s == NULL);
    CHECK(access(p, F_OK) != 0); /* a failed open creates nothing */
    /* write, flush, append, close */
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_WRITE, &s) == 0 && s != NULL);
    CHECK(orin_platform_stream_write(s, "ab\ncd", 5) == 5 && orin_platform_stream_write(s, "", 0) == 0);
    CHECK(orin_platform_stream_flush(s) == 0 && orin_platform_stream_error(s) == 0);
    char *whole;
    size_t n;
    CHECK(orin_platform_file_read(p, strlen(p), &whole, &n) == 0 && n == 5 && memcmp(whole, "ab\ncd", 5) == 0); /* flush delivered */
    orin_platform_free(whole);
    CHECK(orin_platform_stream_close(s) == 0);
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_APPEND, &s) == 0);
    CHECK(orin_platform_stream_write(s, "\nef", 3) == 3 && orin_platform_stream_close(s) == 0); /* close flushes */
    /* read: getc, block read, short read at EOF, sticky EOF, no error */
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_READ, &s) == 0);
    CHECK(orin_platform_stream_getc(s) == 'a' && orin_platform_stream_read(s, buf, 0) == 0);
    CHECK(orin_platform_stream_read(s, buf, 3) == 3 && memcmp(buf, "b\nc", 3) == 0);
    CHECK(orin_platform_stream_read(s, buf, 50) == 4 && memcmp(buf, "d\nef", 4) == 0);
    CHECK(orin_platform_stream_read(s, buf, 5) == 0 && orin_platform_stream_getc(s) == -1 && orin_platform_stream_getc(s) == -1);
    CHECK(orin_platform_stream_error(s) == 0 && orin_platform_stream_close(s) == 0);
    /* WRITE truncates; a 0xff byte is a byte */
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_WRITE, &s) == 0);
    CHECK(orin_platform_stream_write(s, "\xff", 1) == 1 && orin_platform_stream_close(s) == 0);
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_READ, &s) == 0);
    CHECK(orin_platform_stream_getc(s) == 255 && orin_platform_stream_getc(s) == -1 && orin_platform_stream_close(s) == 0);
    /* a large write/read round trip (buffer boundaries) */
    size_t big = 300000;
    char *src = (char *)malloc(big), *dst = (char *)malloc(big);
    for (size_t i = 0; i < big; i++) src[i] = (char)(i * 7 + 3);
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_WRITE, &s) == 0);
    CHECK(orin_platform_stream_write(s, src, big) == big && orin_platform_stream_close(s) == 0);
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_READ, &s) == 0);
    CHECK(orin_platform_stream_read(s, dst, big + 10) == big && memcmp(src, dst, big) == 0);
    CHECK(orin_platform_stream_close(s) == 0);
    free(src);
    free(dst);
    /* errors are sticky and reported by close: reading a write-only stream, writing a read-only one */
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_WRITE, &s) == 0);
    CHECK(orin_platform_stream_getc(s) == -1 && orin_platform_stream_error(s) == EBADF);
    CHECK(orin_platform_stream_write(s, "x", 1) == 1); /* later operations still run; the first error stays */
    CHECK(orin_platform_stream_error(s) == EBADF && orin_platform_stream_close(s) == EBADF);
    CHECK(orin_platform_stream_open(p, strlen(p), ORIN_PLATFORM_STREAM_READ, &s) == 0);
    orin_platform_stream_write(s, "x", 1);
    CHECK(orin_platform_stream_error(s) == EBADF && orin_platform_stream_close(s) == EBADF);
    /* disk full is reported by flush and close */
    if (access("/dev/full", W_OK) == 0) {
        CHECK(orin_platform_stream_open("/dev/full", 9, ORIN_PLATFORM_STREAM_WRITE, &s) == 0);
        CHECK(orin_platform_stream_write(s, "x", 1) == 1 && orin_platform_stream_flush(s) == ENOSPC);
        CHECK(orin_platform_stream_error(s) == ENOSPC && orin_platform_stream_close(s) == ENOSPC);
    }
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

static int norm(const char *in, char *out, size_t cap) { return (int)orin_platform_path_normalize(in, strlen(in), out, cap); }

static void test_policy_and_scopes(void) {
    unsigned m = 99;
    CHECK(orin_platform_policy_parse("", 0, &m) == 0 && m == 0);
    CHECK(orin_platform_policy_parse("fs", 2, &m) == 0 && m == ORIN_PLATFORM_FAM_FS);
    CHECK(orin_platform_policy_parse("fs,process", 10, &m) == 0 && m == (ORIN_PLATFORM_FAM_FS | ORIN_PLATFORM_FAM_PROCESS));
    CHECK(orin_platform_policy_parse("stdio,clock,net", 15, &m) == 0 &&
          m == (ORIN_PLATFORM_FAM_STDIO | ORIN_PLATFORM_FAM_CLOCK | ORIN_PLATFORM_FAM_NET));
    CHECK(orin_platform_policy_parse("all", 3, &m) == 0 && m == 31u);
    CHECK(orin_platform_policy_parse("fs,fs", 5, &m) == 0 && m == ORIN_PLATFORM_FAM_FS);
    /* a typo must never silently allow: the whole policy is rejected */
    CHECK(orin_platform_policy_parse("fss", 3, &m) == ORIN_PLATFORM_EINVAL && m == 0);
    CHECK(orin_platform_policy_parse("fs,", 3, &m) == ORIN_PLATFORM_EINVAL && m == 0);
    CHECK(orin_platform_policy_parse(",fs", 3, &m) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_policy_parse("fs, process", 11, &m) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_policy_parse("FS", 2, &m) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_policy_parse("f\0s", 3, &m) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_policy_parse("fs", 1, &m) == ORIN_PLATFORM_EINVAL); /* length counts, not the NUL */
    unsetenv("ORIN_DENY");
    CHECK(orin_platform_policy_load(&m) == 0 && m == 0);
    setenv("ORIN_DENY", "process,net", 1);
    CHECK(orin_platform_policy_load(&m) == 0 && m == (ORIN_PLATFORM_FAM_PROCESS | ORIN_PLATFORM_FAM_NET));
    setenv("ORIN_DENY", "bogus", 1);
    CHECK(orin_platform_policy_load(&m) == ORIN_PLATFORM_EINVAL && m == 0);
    unsetenv("ORIN_DENY");

    char o[64];
    CHECK(norm("/", o, sizeof o) == 1 && strcmp(o, "/") == 0);
    CHECK(norm("//a///b/", o, sizeof o) == 4 && strcmp(o, "/a/b") == 0);
    CHECK(norm("/a/./b/.", o, sizeof o) == 4 && strcmp(o, "/a/b") == 0);
    CHECK(norm("/a/b/../c", o, sizeof o) == 4 && strcmp(o, "/a/c") == 0);
    CHECK(norm("/a/../../..", o, sizeof o) == 1 && strcmp(o, "/") == 0); /* ".." at the root is dropped */
    CHECK(norm("/..a/b..", o, sizeof o) == 8 && strcmp(o, "/..a/b..") == 0); /* names that merely contain dots */
    CHECK(norm("/a/b/..", o, sizeof o) == 2 && strcmp(o, "/a") == 0);
    CHECK(norm("a/b", o, sizeof o) == -1 && norm("", o, sizeof o) == -1);
    CHECK(norm("/abc", o, 3) == -1 && norm("/abc", o, 5) == 4); /* capacity is plen + 1 */
    CHECK(orin_platform_path_normalize("/a\0b", 4, o, sizeof o) == -1);

    CHECK(orin_platform_path_within("/", 1, "/etc/passwd", 11) == 1);
    CHECK(orin_platform_path_within("/a/b", 4, "/a/b", 4) == 1);
    CHECK(orin_platform_path_within("/a/b", 4, "/a/b/c", 6) == 1);
    CHECK(orin_platform_path_within("/a/b", 4, "/a/bc", 5) == 0); /* component boundary */
    CHECK(orin_platform_path_within("/a/b", 4, "/a", 2) == 0);
    CHECK(orin_platform_path_within("/a/b", 4, "/x/a/b", 6) == 0);

    /* absolute: relative paths resolve against the working directory */
    char cwd[PATH_MAX], a[PATH_MAX + 64];
    CHECK(getcwd(cwd, sizeof cwd) != NULL);
    CHECK(orin_platform_path_absolute("x/../y", 6, a, sizeof a) > 0);
    char want[PATH_MAX + 64];
    snprintf(want, sizeof want, "%s/y", strcmp(cwd, "/") == 0 ? "" : cwd);
    CHECK(strcmp(a, want) == 0);
    CHECK(orin_platform_path_absolute("/p/./q", 6, a, sizeof a) == 4 && strcmp(a, "/p/q") == 0);
    CHECK(orin_platform_path_absolute("", 0, a, sizeof a) == -1);
    CHECK(orin_platform_path_absolute("y", 1, a, 2) == -1); /* buffer too small */

    /* real: symbolic links in the existing prefix are resolved, the non-existing rest is kept */
    char root[PATH_MAX], r[PATH_MAX + 64], q[PATH_MAX + 64];
    CHECK(realpath(tmpdir, root) != NULL); /* the temp dir itself may be below a link (macOS /tmp) */
    mkdir(P("rd"), 0700);
    mkdir(P("rd/in"), 0700);
    mkdir(P("outside"), 0700);
    FILE *f = fopen(P("outside/secret.txt"), "wb");
    fputs("s", f);
    fclose(f);
    CHECK(symlink(P("outside"), P("rd/in/escape")) == 0);          /* link to a directory outside */
    CHECK(symlink(P("outside/secret.txt"), P("rd/in/flink")) == 0); /* link to a file outside */
    CHECK(symlink(P("outside/nothing_here"), P("rd/in/dangling")) == 0);
    CHECK(symlink("in", P("rd/loop1")) == 0);
    snprintf(q, sizeof q, "%s/rd/in/new/deeper.txt", root);
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) > 0 && strcmp(r, q) == 0); /* nothing to resolve */
    snprintf(q, sizeof q, "%s/rd/in/escape/secret.txt", root);
    snprintf(want, sizeof want, "%s/outside/secret.txt", root);
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) > 0 && strcmp(r, want) == 0);
    snprintf(q, sizeof q, "%s/rd/in/escape/not_yet.txt", root);
    snprintf(want, sizeof want, "%s/outside/not_yet.txt", root);
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) > 0 && strcmp(r, want) == 0); /* new file below a link */
    snprintf(q, sizeof q, "%s/rd/in/flink", root);
    snprintf(want, sizeof want, "%s/outside/secret.txt", root);
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) > 0 && strcmp(r, want) == 0);
    snprintf(q, sizeof q, "%s/rd/in/dangling", root); /* creating through a dangling link would escape */
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) == -1);
    snprintf(q, sizeof q, "%s/rd/loop1/new.txt", root); /* a link inside the tree stays inside */
    snprintf(want, sizeof want, "%s/rd/in/new.txt", root);
    CHECK(orin_platform_path_real(q, strlen(q), r, sizeof r) > 0 && strcmp(r, want) == 0);
    CHECK(orin_platform_path_real("/", 1, r, sizeof r) == 1 && strcmp(r, "/") == 0);
    CHECK(orin_platform_path_real("/orin_no_such_dir_xyz/a", 23, r, sizeof r) == 23 && strcmp(r, "/orin_no_such_dir_xyz/a") == 0);
    CHECK(orin_platform_path_real(root, strlen(root), r, 3) == -1); /* buffer too small */
}


/* ---- network (ADR-0033): loopback sockets; handle identity and scope are refused before any system call ---- */
static orin_platform_net root_grant(void) {
    orin_platform_net g;
    memset(&g, 0, sizeof g);
    g.magic = ORIN_PLATFORM_NET_MAGIC, g.kind = ORIN_PLATFORM_NET_GRANT, g.can = 3, g.fd = -1;
    for (int i = 0; i < 2; i++) g.sc[i].hl = 1, g.sc[i].h[0] = '*', g.sc[i].hi = 65535;
    return g;
}

static int open_fds(void) { /* descriptors open in this process: a refused call must not open one */
    int n = 0;
    for (int fd = 0; fd < 256; fd++)
        if (fcntl(fd, F_GETFD) != -1) n++;
    return n;
}

static void test_net(void) {
    signal(SIGPIPE, SIG_DFL); /* the layer must not need the process to ignore it */
    orin_platform_net root = root_grant(), lg, cg, ln, cs, as, junk;
    memset(&ln, 0, sizeof ln);
    int port = -1, outp = -1;
    char peer[64], buf[8];
    size_t n;
    /* narrowing */
    CHECK(orin_platform_net_narrow(&root, ORIN_PLATFORM_NET_LISTEN, "127.0.0.1", 9, 0, 0, &lg) == 0 && lg.can == ORIN_PLATFORM_NET_LISTEN);
    CHECK(orin_platform_net_narrow(&root, ORIN_PLATFORM_NET_CONNECT, "*.example.com", 13, 80, 443, &cg) == 0 && cg.can == ORIN_PLATFORM_NET_CONNECT);
    CHECK(orin_platform_net_narrow(&root, 3, "x", 1, 0, 1, &junk) == ORIN_PLATFORM_EINVAL); /* one capability at a time */
    CHECK(orin_platform_net_narrow(&root, ORIN_PLATFORM_NET_CONNECT, "a*", 2, 0, 1, &junk) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_net_narrow(&root, ORIN_PLATFORM_NET_CONNECT, "x", 1, 5, 4, &junk) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_net_narrow(&root, ORIN_PLATFORM_NET_CONNECT, "x", 1, 0, 70000, &junk) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_net_narrow(NULL, ORIN_PLATFORM_NET_CONNECT, "x", 1, 0, 1, &junk) == ORIN_PLATFORM_EPERM);
    orin_platform_net w;
    CHECK(orin_platform_net_narrow(&cg, ORIN_PLATFORM_NET_CONNECT, "*", 1, 80, 443, &w) == 0 && w.can == 0); /* wider pattern */
    CHECK(orin_platform_net_narrow(&cg, ORIN_PLATFORM_NET_CONNECT, "*.example.com", 13, 0, 443, &w) == 0 && w.can == 0); /* wider ports */
    CHECK(orin_platform_net_narrow(&cg, ORIN_PLATFORM_NET_CONNECT, "*.evil.example.com", 18, 443, 443, &w) == 0 && w.can != 0); /* narrower */
    CHECK(orin_platform_net_narrow(&cg, ORIN_PLATFORM_NET_CONNECT, "example.com", 11, 443, 443, &w) == 0 && w.can == 0); /* the apex is not below it */
    CHECK(orin_platform_net_narrow(&cg, ORIN_PLATFORM_NET_LISTEN, "127.0.0.1", 9, 0, 0, &w) == 0 && w.can == 0); /* cannot gain listen */
    CHECK(orin_platform_net_narrow(&lg, ORIN_PLATFORM_NET_CONNECT, "*", 1, 0, 65535, &w) == 0 && w.can == 0); /* cannot gain connect */

    /* a refused call opens nothing and is EPERM, before any system call */
    int fds = open_fds();
    CHECK(orin_platform_tcp_listen(&cg, "127.0.0.1", 9, 0, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM); /* connect grant */
    CHECK(orin_platform_tcp_listen(&lg, "127.0.0.1", 9, 80, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM); /* port outside */
    CHECK(orin_platform_tcp_listen(&lg, "0.0.0.0", 7, 0, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM); /* address outside */
    CHECK(orin_platform_tcp_connect(&lg, "127.0.0.1", 9, 80, 100, 0, &junk) == ORIN_PLATFORM_EPERM); /* listen grant */
    CHECK(orin_platform_tcp_connect(&cg, "127.0.0.1", 9, 80, 100, 0, &junk) == ORIN_PLATFORM_EPERM); /* host outside */
    CHECK(orin_platform_tcp_connect(&cg, "a.EXAMPLE.com", 13, 8080, 100, 0, &junk) == ORIN_PLATFORM_EPERM); /* port outside */
    CHECK(orin_platform_dns_resolve(&lg, "localhost", 9, buf, sizeof buf, &n) == ORIN_PLATFORM_EPERM && n == 0);
    CHECK(orin_platform_dns_resolve(&cg, "localhost", 9, buf, sizeof buf, &n) == ORIN_PLATFORM_EPERM);
    orin_platform_net denied = root;
    denied.deny = 1;
    CHECK(orin_platform_tcp_listen(&denied, "127.0.0.1", 9, 0, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_tcp_connect(&denied, "127.0.0.1", 9, 80, 100, 0, &junk) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_dns_resolve(&denied, "localhost", 9, buf, sizeof buf, &n) == ORIN_PLATFORM_EPERM);
    orin_platform_net forged;
    memset(&forged, 0x41, sizeof forged);
    CHECK(orin_platform_tcp_listen(&forged, "127.0.0.1", 9, 0, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_tcp_listen(NULL, "127.0.0.1", 9, 0, 8, 1, &junk, &outp) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_tcp_connect(&ln, "127.0.0.1", 9, 80, 100, 0, &junk) == ORIN_PLATFORM_EPERM); /* not a grant (zeroed) */
    CHECK(open_fds() == fds);

    /* listen / connect / accept on the loopback */
    CHECK(orin_platform_tcp_listen(&root, "127.0.0.1", 9, 0, 0, 1, &ln, &port) == ORIN_PLATFORM_EINVAL); /* backlog */
    CHECK(orin_platform_tcp_listen(&root, "not an address", 14, 0, 8, 1, &ln, &port) != 0); /* numeric only */
    CHECK(orin_platform_tcp_listen(&lg, "127.0.0.1", 9, 0, 8, 1, &ln, &port) == 0 && port > 0 && ln.kind == ORIN_PLATFORM_NET_LISTENER);
    CHECK(orin_platform_tcp_connect(&root, "127.0.0.1", 9, port, 1000, 1, &cs) == 0 && cs.kind == ORIN_PLATFORM_NET_STREAM);
    int pp = 0;
    CHECK(orin_platform_tcp_accept(&ln, 1000, 1, &as, peer, sizeof peer, &pp) == 0 && strcmp(peer, "127.0.0.1") == 0 && pp > 0);
    CHECK(orin_platform_tcp_accept(&ln, 20, 1, &junk, peer, sizeof peer, &pp) == ORIN_PLATFORM_NET_TIMEOUT); /* nobody there */
    CHECK(orin_platform_tcp_accept(&ln, -1, 1, &junk, peer, sizeof peer, &pp) == ORIN_PLATFORM_EINVAL); /* no negative timeout */
    CHECK(orin_platform_tcp_accept(&ln, ORIN_PLATFORM_NET_MAXMS + 1, 1, &junk, peer, sizeof peer, &pp) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_tcp_accept(&cs, 10, 1, &junk, peer, sizeof peer, &pp) == ORIN_PLATFORM_EPERM); /* a stream is not a listener */
    CHECK(orin_platform_tcp_connect(&root, "127.0.0.1", 9, 1, 1000, 0, &junk) != 0); /* nothing listens on port 1 */
    CHECK(orin_platform_tcp_connect(&root, "orin-no-such-host.invalid", 25, 80, 1000, 0, &junk) == ENOENT);

    /* bytes: partial reads, a recv never exceeds its capacity (guard bytes around the buffer), timeouts */
    CHECK(orin_platform_stream_send(&cs, "hello world", 11, 1000, &n) == 0 && n == 11);
    char area[16];
    memset(area, 0x55, sizeof area);
    CHECK(orin_platform_stream_recv(&as, area + 4, 5, 1000, &n) == 0 && n == 5 && memcmp(area + 4, "hello", 5) == 0);
    int guards = 1;
    for (int i = 0; i < 4; i++) guards &= area[i] == 0x55 && area[9 + i] == 0x55;
    CHECK(guards);
    CHECK(orin_platform_stream_recv(&as, area, 16, 1000, &n) == 0 && n == 6 && memcmp(area, " world", 6) == 0);
    CHECK(orin_platform_stream_recv(&as, area, 16, 30, &n) == ORIN_PLATFORM_NET_TIMEOUT && n == 0);
    CHECK(orin_platform_stream_recv(&as, area, 0, 30, &n) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_stream_recv(&as, area, 16, -5, &n) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_stream_send(&cs, "x", 1, -1, &n) == ORIN_PLATFORM_EINVAL && n == 0);
    CHECK(orin_platform_stream_send(&cs, "", 0, 100, &n) == 0 && n == 0);

    /* half-close: the peer sees EOF after the data, and can still answer */
    CHECK(orin_platform_stream_send(&cs, "tail", 4, 1000, &n) == 0 && n == 4);
    CHECK(orin_platform_net_shutdown(&cs, 1) == 0);
    CHECK(orin_platform_net_shutdown(&cs, 7) == ORIN_PLATFORM_EINVAL);
    CHECK(orin_platform_stream_recv(&as, area, 16, 1000, &n) == 0 && n == 4);
    CHECK(orin_platform_stream_recv(&as, area, 16, 1000, &n) == ORIN_PLATFORM_NET_EOF && n == 0);
    CHECK(orin_platform_stream_send(&as, "bye", 3, 1000, &n) == 0 && n == 3);
    CHECK(orin_platform_stream_recv(&cs, area, 16, 1000, &n) == 0 && n == 3);

    /* a backed-up peer: send reports a partial write or times out, it never blocks past its timeout */
    static char big[1 << 16];
    memset(big, 'x', sizeof big);
    int stuck = 0;
    for (int i = 0; i < 400 && !stuck; i++) {
        int rr = orin_platform_stream_send(&as, big, sizeof big, 50, &n);
        CHECK(rr == 0 || rr == ORIN_PLATFORM_NET_TIMEOUT);
        if (rr == ORIN_PLATFORM_NET_TIMEOUT) stuck = 1;
        CHECK(n <= sizeof big);
    }
    CHECK(stuck);

    /* close is idempotent; a closed record is refused; a reset is reported, not raised as SIGPIPE */
    CHECK(orin_platform_net_close(&cs) == 0 && cs.fd == -1 && orin_platform_net_close(&cs) == 0);
    CHECK(orin_platform_stream_recv(&cs, area, 16, 10, &n) == ORIN_PLATFORM_EPERM && n == 0);
    CHECK(orin_platform_stream_send(&cs, "x", 1, 10, &n) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_net_shutdown(&cs, 1) == ORIN_PLATFORM_EPERM);
    int r = 0;
    for (int i = 0; i < 100 && r == 0; i++) r = orin_platform_stream_send(&as, big, sizeof big, 200, &n); /* the peer is gone */
    CHECK(r == ORIN_PLATFORM_NET_RESET);
    CHECK(orin_platform_net_close(&as) == 0 && orin_platform_net_close(&ln) == 0);
    CHECK(orin_platform_net_close(NULL) == ORIN_PLATFORM_EPERM && orin_platform_net_close(&forged) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_tcp_accept(&ln, 10, 0, &junk, peer, sizeof peer, &pp) == ORIN_PLATFORM_EPERM); /* the closed listener */

    /* resolve: numeric addresses, one per line */
    char out[256];
    CHECK(orin_platform_dns_resolve(&root, "localhost", 9, out, sizeof out, &n) == 0 && n > 0 && out[n - 1] == '\n');
    CHECK(orin_platform_dns_resolve(&root, "127.0.0.1", 9, out, sizeof out, &n) == 0 && n == 10 && memcmp(out, "127.0.0.1\n", 10) == 0);
    CHECK(orin_platform_dns_resolve(&root, "127.0.0.1", 9, out, 4, &n) == 0 && n == 0); /* too small: nothing written past cap */
    CHECK(orin_platform_dns_resolve(&root, "orin-no-such-host.invalid", 25, out, sizeof out, &n) == ENOENT);

    CHECK(orin_platform_monotonic_millis() > 0);
    int64_t t0 = orin_platform_monotonic_millis();
    CHECK(orin_platform_stream_recv(&forged, area, 16, 10, &n) == ORIN_PLATFORM_EPERM);
    CHECK(orin_platform_monotonic_millis() >= t0);
}

int main(void) {
    snprintf(tmpdir, sizeof tmpdir, "/tmp/orin_platform_test_%d", (int)getpid());
    mkdir(tmpdir, 0700);
    test_memory();
    test_find();
    test_fmt();
    test_files();
    test_streams();
    test_process_and_output();
    test_stdin();
    test_policy_and_scopes();
    test_net();
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
