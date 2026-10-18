/* Runtime-only tests. Build: cc -I runtime/core runtime/core/tests/runtime_test.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c
 *     $(tools/rt_stub.sh build/rt_stub.o)
 * (the object model is Orin code, ADR-0052 R3d.3; the stub object defines orin_struct_new, orin_destroy, ... for the C shells).
 * Optionally with -fsanitize=address,undefined. Exits 0 and prints "ok" on success. */
#define _GNU_SOURCE
#include "orin_runtime.h"
#include "orin_runtime_io.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>

static int failures;
#define CHECK(c)                                                                                \
    do {                                                                                        \
        if (!(c)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                        \
            failures++;                                                                         \
        }                                                                                       \
    } while (0)

/* The unwrap helpers are Orin functions now ($rt/leaf.or, ADR-0052 R3d.2); these tests read the payload slot directly. */
static uint64_t orin_res_unwrap(OrinObj *r) { return orin_tag(r) == 0 ? orin_struct_get(r, 0) : 0; }
static uint64_t orin_res_unwrap_err(OrinObj *r) { return orin_struct_get(r, 0); }

static OrinObj *S(const char *s) { return orin_str_new(s, strlen(s)); }
static int streq(OrinObj *o, const char *s) {
    return orin_str_len(o) == strlen(s) && memcmp(orin_str_data(o), s, strlen(s)) == 0;
}

ORIN_STRING_LIT(lit_nul, 3, "a\000b");

static void test_strings(void) {
    int64_t base = orin_live_count();
    OrinObj *a = S("hello"), *b = S(" world");
    OrinObj *c = orin_str_concat(a, b);
    CHECK(streq(c, "hello world"));
    CHECK(orin_str_eq(c, c));
    OrinObj *sub = orin_str_substring(c, 6, 11);
    CHECK(streq(sub, "world"));
    OrinObj *idx = orin_str_index_of(c, sub);
    CHECK(orin_tag(idx) == 0 && orin_struct_get(idx, 0) == 6);
    OrinObj *miss = S("zzz");
    OrinObj *idx2 = orin_str_index_of(c, miss);
    CHECK(orin_tag(idx2) == 1);
    CHECK(orin_str_includes(c, sub) && orin_str_starts_with(c, a) && orin_str_ends_with(c, sub));
    OrinObj *comma = S(",");
    OrinObj *csv = S("a,b,,c");
    OrinObj *parts = orin_str_split(csv, comma);
    CHECK(orin_array_len(parts) == 4);
    OrinObj *joined = orin_array_join(parts, comma);
    CHECK(streq(joined, "a,b,,c"));
    OrinObj *trimmed = S("  \t x y\n ");
    OrinObj *tr = orin_str_trim(trimmed);
    CHECK(streq(tr, "x y"));
    CHECK(orin_str_len(lit_nul) == 3 && orin_str_data(lit_nul)[1] == 0 && orin_str_data(lit_nul)[2] == 'b');
    OrinObj *n = S("-42");
    OrinObj *p = orin_parse_int(n);
    CHECK(orin_tag(p) == 0 && (int64_t)orin_struct_get(p, 0) == -42);
    OrinObj *bad = S("12x");
    OrinObj *p2 = orin_parse_int(bad);
    CHECK(orin_tag(p2) == 1);
    OrinObj *big = S("9223372036854775808");
    OrinObj *p3 = orin_parse_int(big);
    CHECK(orin_tag(p3) == 1);
    OrinObj *mn = S("-9223372036854775808");
    OrinObj *p4 = orin_parse_int(mn);
    CHECK(orin_tag(p4) == 0 && (int64_t)orin_struct_get(p4, 0) == INT64_MIN);
    OrinObj *its = orin_int_to_string(INT64_MIN);
    CHECK(streq(its, "-9223372036854775808"));
    /* append: in place when unique */
    OrinObj *acc = S("x");
    for (int i = 0; i < 1000; i++) acc = orin_str_append(acc, comma);
    CHECK(orin_str_len(acc) == 1001);
    OrinObj *shared = orin_dup(acc);
    OrinObj *acc2 = orin_str_append(acc, comma); /* consumes one count of acc; shared keeps old */
    CHECK(orin_str_len(shared) == 1001 && orin_str_len(acc2) == 1002);
    OrinObj *os[] = {a, b, c, sub, idx, miss, idx2, comma, csv, parts, joined, trimmed, tr, n, p, bad, p2,
                     big, p3, mn, p4, its, shared, acc2};
    for (size_t i = 0; i < sizeof os / sizeof *os; i++) orin_release(os[i]);
    CHECK(orin_live_count() == base);
}

static void test_arrays_cow(void) {
    int64_t base = orin_live_count();
    OrinObj *xs = orin_array_new(0, 1);
    for (int i = 0; i < 100; i++) orin_array_push(xs, ORIN_SLOT(orin_int_to_string(i)));
    CHECK(orin_array_len(xs) == 100);
    OrinObj *ys = orin_dup(xs);
    xs = orin_make_unique(xs); /* shared -> copy */
    CHECK(xs != ys && ys->rc == 1 && xs->rc == 1);
    OrinObj *last = orin_array_pop(xs);
    CHECK(orin_tag(last) == 0 && streq(ORIN_REF(orin_struct_get(last, 0)), "99"));
    CHECK(orin_array_len(xs) == 99 && orin_array_len(ys) == 100);
    OrinObj *sl = orin_array_slice(ys, 10, 20);
    CHECK(orin_array_len(sl) == 10 && streq(ORIN_REF(orin_array_at(sl, 0)), "10"));
    OrinObj *cc = orin_array_concat(sl, sl);
    CHECK(orin_array_len(cc) == 20);
    OrinObj *g = orin_array_get(cc, 19), *g2 = orin_array_get(cc, 20);
    CHECK(orin_tag(g) == 0 && orin_tag(g2) == 1);
    /* nested: record holding an array; unique-path update leaves the shared copy untouched */
    OrinObj *rec = orin_struct_new(0, 2, 2);
    orin_struct_set(rec, 0, 7);
    orin_struct_set(rec, 1, ORIN_SLOT(orin_dup(xs)));
    OrinObj *rec2 = orin_dup(rec);
    rec = orin_make_unique(rec);
    uint64_t *slot = orin_struct_slot_ptr(rec, 1);
    OrinObj *inner = orin_make_unique(ORIN_REF(*slot));
    *slot = ORIN_SLOT(inner);
    uint64_t *el = orin_array_slot_ptr(inner, 0);
    OrinObj *old = ORIN_REF(*el);
    *el = ORIN_SLOT(S("changed"));
    orin_release(old);
    CHECK(streq(ORIN_REF(orin_array_at(ORIN_REF(orin_struct_get(rec2, 1)), 0)), "0"));
    CHECK(streq(ORIN_REF(orin_array_at(ORIN_REF(orin_struct_get(rec, 1)), 0)), "changed"));
    OrinObj *all[] = {xs, ys, last, sl, cc, g, g2, rec, rec2};
    for (size_t i = 0; i < sizeof all / sizeof *all; i++) orin_release(all[i]);
    CHECK(orin_live_count() == base);
}

static void test_deep_chain(void) {
    int64_t base = orin_live_count();
    OrinObj *list = orin_nullary(1);
    for (int i = 0; i < 1000000; i++) {
        OrinObj *n = orin_struct_new(0, 2, 2);
        orin_struct_set(n, 0, (uint64_t)i);
        orin_struct_set(n, 1, ORIN_SLOT(list));
        list = n;
    }
    orin_release(list); /* must not overflow the stack */
    CHECK(orin_live_count() == base);
}

static void test_misc(void) {
    /* The checked arithmetic of generated code is defined by the compiler's preamble (compiler/backends/c/preamble.or, ADR-0052 R3d.6);
     * its results and traps are covered by tests/run and the conformance suite, not here. */
    OrinObj *none = orin_none();
    CHECK(none->rc < 0 && orin_nullary(1) == none);
    orin_release(none); /* no-op on immortal */
    orin_release(NULL);
    OrinObj *r = orin_variant1(1, 1, ORIN_SLOT(S("err")));
    CHECK(orin_tag(r) == 1 && streq(ORIN_REF(orin_res_unwrap_err(r)), "err"));
    orin_release(r);
    OrinObj *p = S("/definitely/not/here");
    int64_t host = orin_cap_host_root(), fs = orin_cap_acquire(host, 1);
    OrinObj *rd = orin_fs_read_file(fs, p);
    CHECK(orin_tag(rd) == 1 && !orin_fs_exists(fs, p));
    orin_cap_revoke(fs);
    orin_release(rd);
    orin_release(p);
}

/* Shape confusion must trap (exit 101), never read or write out of bounds: run each access in a child. */
static int traps(int which) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        OrinObj *s = orin_struct_new(0, 1, 0);        /* a struct with ONE slot */
        OrinObj *a = orin_array_new(4, 0);
        OrinObj *str = S("x");
        switch (which) {
        case 0: (void)orin_struct_get(s, 1); break;                 /* index == nslots */
        case 1: orin_struct_set(s, 5, 0); break;
        case 2: (void)orin_struct_slot_ptr(s, 1); break;
        case 3: (void)orin_struct_get(a, 0); break;                 /* array read as struct */
        case 4: (void)orin_struct_get(str, 0); break;               /* string read as struct */
        case 5: (void)orin_struct_get(orin_nullary(1), 0); break;   /* payload-less variant */
        case 6: (void)orin_array_at(s, 0); break;                   /* struct read as array */
        case 7: orin_array_push(s, 1); break;
        }
        _exit(0); /* the access did not trap */
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 101;
}

static void test_shape_traps(void) {
    for (int i = 0; i < 8; i++) CHECK(traps(i));
    OrinObj *s = orin_struct_new(0, 2, 0);
    orin_struct_set(s, 1, 9);
    CHECK(orin_struct_get(s, 1) == 9); /* in-range access still works */
    orin_release(s);
}


/* ---- capability grants (ADR-0027) ---- */
/* every temporary of test_grants is collected and released at its end (the suite runs under LeakSanitizer) */
static OrinObj *keep[512];
static int nkeep;
static OrinObj *K(OrinObj *o) {
    keep[nkeep++] = o;
    return o;
}
#define S(x) K(orin_str_new((x), strlen(x)))
#define orin_fs_read_file(...) K(orin_fs_read_file(__VA_ARGS__))
#define orin_fs_write_file(...) K(orin_fs_write_file(__VA_ARGS__))
static int64_t g_host, g_fs;
static int trap_code(void (*fn)(void)) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        fn();
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
static void t_forged(void) { (void)orin_fs_exists(0x12345, S("/")); }
static void t_file_as_grant(void) { /* a file-handle-shaped integer is not a grant */
    (void)orin_fs_exists(((int64_t)7 << 8) | 0, S("/"));
}
static void t_stale(void) {
    int64_t g = orin_cap_acquire(g_host, 1);
    orin_cap_revoke(g);
    (void)orin_fs_exists(g, S("/"));
}
static void t_wrong_kind(void) { (void)orin_process_args(g_fs); }
static void t_mut_forged(void) { (void)orin_fs_rename(0x12345, S("/a"), S("/b")); }
static void t_mut_stale(void) {
    int64_t g = orin_cap_acquire(g_host, 1);
    orin_cap_revoke(g);
    (void)orin_fs_remove_file(g, S("/a"));
}
static void t_mut_wrong_kind(void) { (void)orin_fs_write_file_atomic(orin_cap_acquire(g_host, 2), S("/a"), S("x")); }
static void t_double_revoke(void) {
    int64_t g = orin_cap_acquire(g_host, 4);
    orin_cap_revoke(g);
    orin_cap_revoke(g);
}
static void t_clock_ok(void) { (void)orin_time_now_millis(orin_cap_acquire(g_host, 4)); }
static void t_denied_args(void) { (void)orin_process_args(orin_cap_acquire(g_host, 2)); }
static void t_nospawn_timeout(void) { (void)orin_io_shell_timeout(orin_cap_narrow(orin_cap_acquire(g_host, 2), 2, S("")), S("echo MUST_NOT_RUN"), 1); }
static void t_nospawn(void) { (void)orin_io_shell(orin_cap_narrow(orin_cap_acquire(g_host, 2), 2, S("")), S("true")); }

static void t_list_forged(void) { (void)orin_fs_list_dir(0x12345, S("/")); }
static void t_list_wrong_kind(void) { (void)orin_fs_list_dir(orin_cap_acquire(g_host, 2), S("/")); }
static void t_list_stale(void) {
    int64_t g = orin_cap_acquire(g_host, 1);
    orin_cap_revoke(g);
    (void)orin_fs_list_dir(g, S("/"));
}

static int64_t list_error_fs;
static OrinObj *list_error_path;
/* listDir reports every refusal or enumeration failure as an Err (never a trap). */
static int list_fails(void) {
    OrinObj *r = orin_fs_list_dir(list_error_fs, list_error_path);
    int bad = orin_tag(r) == 1;
    orin_release(r);
    return bad;
}
static OrinObj *entries_of(OrinObj *r) {
    CHECK(orin_tag(r) == 0);
    return ORIN_REF(orin_res_unwrap(r));
}
#define ENTRIES(r) entries_of(r)

static void test_list_dir(void) {
    int64_t baseline = orin_live_count();
    char directory[] = "/tmp/orin_rt_listing_XXXXXX", path[128];
    CHECK(mkdtemp(directory) != NULL);
    unsetenv("ORIN_DENY");
    int64_t host = orin_cap_host_root(), fs = orin_cap_acquire(host, 1);
    OrinObj *dir = S(directory);
    OrinObj *entries = orin_fs_list_dir(fs, dir);
    CHECK(orin_array_len(ENTRIES(entries)) == 0);
    orin_release(entries);
    const char *files[] = {"a.", "Aa", ".hidden", "a0", "\303\251"};
    for (size_t i = 0; i < sizeof files / sizeof *files; i++) {
        snprintf(path, sizeof path, "%s/%s", directory, files[i]);
        FILE *f = fopen(path, "wb");
        CHECK(f != NULL);
        if (f) CHECK(fclose(f) == 0);
    }
    const char *dirs[] = {"a-", "a"};
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) {
        snprintf(path, sizeof path, "%s/%s", directory, dirs[i]);
        CHECK(mkdir(path, 0700) == 0);
    }
    snprintf(path, sizeof path, "%s/loop", directory);
    CHECK(symlink(".", path) == 0);
    snprintf(path, sizeof path, "%s/dangling", directory);
    CHECK(symlink("absent", path) == 0);
    const char *expected[] = {".hidden", "Aa", "a-/", "a.", "a/", "a0", "dangling", "loop", "\303\251"};
    int64_t live = orin_live_count();
    for (int round = 0; round < 64; round++) {
        entries = orin_fs_list_dir(fs, dir);
        CHECK(orin_array_len(ENTRIES(entries)) == sizeof expected / sizeof *expected);
        for (size_t i = 0; i < orin_array_len(ENTRIES(entries)) && i < sizeof expected / sizeof *expected; i++)
            CHECK(streq(ORIN_REF(orin_array_at(ENTRIES(entries), i)), expected[i]));
        orin_release(entries);
        CHECK(orin_live_count() == live);
    }
    int64_t scoped = orin_cap_narrow(fs, 0, dir), ro = orin_cap_narrow(scoped, 1, NULL);
    entries = orin_fs_list_dir(ro, dir);
    CHECK(orin_array_len(ENTRIES(entries)) == sizeof expected / sizeof *expected);
    orin_release(entries);
    snprintf(path, sizeof path, "%s/absent", directory);
    list_error_fs = fs;
    list_error_path = S(path);
    CHECK(list_fails());
    snprintf(path, sizeof path, "%s/a.", directory);
    list_error_fs = fs;
    list_error_path = S(path);
    CHECK(list_fails());
    list_error_path = lit_nul;
    CHECK(list_fails());
    /* Root can read mode-000 directories; only assert permission refusal for ordinary users. */
    if (geteuid() != 0) {
        CHECK(chmod(directory, 0) == 0);
        list_error_path = dir;
        CHECK(list_fails());
        CHECK(chmod(directory, 0700) == 0);
    }
    for (size_t i = 0; i < sizeof expected / sizeof *expected; i++) {
        snprintf(path, sizeof path, "%s/%s", directory, expected[i]);
        if (expected[i][strlen(expected[i]) - 1] == '/') CHECK(rmdir(path) == 0);
        else CHECK(unlink(path) == 0);
    }
    CHECK(rmdir(directory) == 0);
    orin_cap_revoke(ro); orin_cap_revoke(scoped); orin_cap_revoke(fs); orin_cap_revoke(host);
    while (nkeep) orin_release(keep[--nkeep]);
    CHECK(orin_live_count() == baseline);
}

static void test_grants(void) {
    unsetenv("ORIN_DENY");
    g_host = orin_cap_host_root();
    g_fs = orin_cap_acquire(g_host, 1);
    CHECK(trap_code(t_forged) == 101 && trap_code(t_file_as_grant) == 101 && trap_code(t_stale) == 101);
    CHECK(trap_code(t_wrong_kind) == 101 && trap_code(t_double_revoke) == 101);
    CHECK(trap_code(t_clock_ok) == 0);
    CHECK(trap_code(t_nospawn) == 101);
    CHECK(trap_code(t_nospawn_timeout) == 101);
    CHECK(trap_code(t_list_forged) == 101 && trap_code(t_list_wrong_kind) == 101 && trap_code(t_list_stale) == 101);
    CHECK(system("rm -rf /tmp/orin_rt_scope && mkdir -p /tmp/orin_rt_scope/in /tmp/orin_rt_scope/out && "
                 "echo hi > /tmp/orin_rt_scope/in/a.txt && echo secret > /tmp/orin_rt_scope/out/s.txt && "
                 "ln -s ../out /tmp/orin_rt_scope/in/esc") == 0);
    int64_t in = orin_cap_narrow(g_fs, 0, S("/tmp/orin_rt_scope/in"));
    OrinObj *r = orin_fs_read_file(in, S("/tmp/orin_rt_scope/in/a.txt"));
    CHECK(orin_tag(r) == 0);
    CHECK(orin_fs_exists(in, S("/tmp/orin_rt_scope/in/a.txt")));
    r = orin_fs_read_file(in, S("/tmp/orin_rt_scope/out/s.txt")); /* absolute, outside */
    CHECK(orin_tag(r) == 1 && streq(ORIN_REF(orin_res_unwrap_err(r)), "cannot read '/tmp/orin_rt_scope/out/s.txt': outside the granted file scope"));
    r = orin_fs_read_file(in, S("/tmp/orin_rt_scope/in/../out/s.txt")); /* ../ */
    CHECK(orin_tag(r) == 1);
    r = orin_fs_read_file(in, S("/tmp/orin_rt_scope/in/esc/s.txt")); /* symlink to outside */
    CHECK(orin_tag(r) == 1);
    CHECK(orin_file_open(in, S("/tmp/orin_rt_scope/in/esc/s.txt"), 0) == -100002);
    CHECK(orin_tag(orin_fs_write_file(in, S("/tmp/orin_rt_scope/in/esc/new.txt"), S("x"))) == 1);
    CHECK(orin_tag(orin_fs_write_file(in, S("/tmp/orin_rt_scope/in/new.txt"), S("x"))) == 0);
    /* narrowing never widens */
    int64_t wide = orin_cap_narrow(in, 0, S("/tmp/orin_rt_scope"));
    CHECK(orin_tag(orin_fs_read_file(wide, S("/tmp/orin_rt_scope/out/s.txt"))) == 1);
    CHECK(orin_tag(orin_fs_read_file(wide, S("/tmp/orin_rt_scope/in/a.txt"))) == 0);
    int64_t disjoint = orin_cap_narrow(in, 0, S("/tmp/orin_rt_scope/out"));
    CHECK(orin_tag(orin_fs_read_file(disjoint, S("/tmp/orin_rt_scope/out/s.txt"))) == 1);
    CHECK(orin_tag(orin_fs_read_file(disjoint, S("/tmp/orin_rt_scope/in/a.txt"))) == 1);
    /* read-only */
    int64_t ro = orin_cap_narrow(in, 1, S(""));
    CHECK(orin_tag(orin_fs_read_file(ro, S("/tmp/orin_rt_scope/in/a.txt"))) == 0);
    CHECK(orin_tag(orin_fs_write_file(ro, S("/tmp/orin_rt_scope/in/b.txt"), S("x"))) == 1);
    CHECK(orin_file_open(ro, S("/tmp/orin_rt_scope/in/b.txt"), 1) == -100003);
    int64_t fh = orin_file_open(ro, S("/tmp/orin_rt_scope/in/a.txt"), 0);
    CHECK(fh > 0);
    orin_release(orin_file_close(fh));
    /* relative scopes resolve against the working directory */
    CHECK(system("mkdir -p /tmp/orin_rt_scope/rel") == 0);
    CHECK(orin_fs_exists(orin_cap_narrow(g_fs, 0, S("/tmp/orin_rt_scope/in")), S("/etc")) == -100002);
    list_error_fs = orin_cap_narrow(g_fs, 0, S("/tmp/orin_rt_scope/in"));
    list_error_path = S("/tmp/orin_rt_scope/out");
    CHECK(list_fails());
    list_error_path = S("/tmp/orin_rt_scope/in/esc");
    CHECK(list_fails());
    orin_cap_revoke(ro); orin_cap_revoke(disjoint); orin_cap_revoke(wide); orin_cap_revoke(in);
    CHECK(system("rm -rf /tmp/orin_rt_scope") == 0);
    /* host policy: families named in ORIN_DENY are refused (re-read by orin_cap_host_root) */
    setenv("ORIN_DENY", "fs,process", 1);
    g_host = orin_cap_host_root();
    g_fs = orin_cap_acquire(g_host, 1);
    OrinObj *d = orin_fs_read_file(g_fs, S("/etc/passwd"));
    CHECK(orin_tag(d) == 1 && streq(ORIN_REF(orin_res_unwrap_err(d)), "cannot read '/etc/passwd': denied by the host policy (ORIN_DENY)"));
    CHECK(orin_file_open(g_fs, S("/etc/passwd"), 0) == -100001);
    CHECK(orin_fs_exists(g_fs, S("/")) == -100001 && trap_code(t_denied_args) == 101);
    list_error_fs = g_fs;
    list_error_path = S("/");
    CHECK(list_fails());
    CHECK(trap_code(t_clock_ok) == 0); /* clock is not denied */
    unsetenv("ORIN_DENY");
    while (nkeep) orin_release(keep[--nkeep]);
}

/* ---- network handles (ADR-0033): forged / stale / wrong-kind handles trap; scope and policy refuse; recv stays in its capacity ---- */
static int64_t n_host, n_net, n_lis, n_cl, n_srv;
static void t_net_forged(void) { orin_release(orin_net_recv(0x12345, 4, 10)); }
static void t_net_file_shaped(void) { orin_release(orin_net_recv(((int64_t)7 << 8) | 0, 4, 10)); }
static void t_net_listener_as_stream(void) { orin_release(orin_net_recv(n_lis, 4, 10)); }
static void t_net_stream_as_listener(void) { (void)orin_net_accept(n_srv, 10, 0); }
static void t_net_grant_as_stream(void) { orin_release(orin_net_recv(n_net, 4, 10)); }
static void t_net_stale(void) {
    int64_t c = orin_net_connect(n_net, orin_str_new("127.0.0.1", 9), orin_net_port(n_lis), 1000, 0);
    orin_net_close(c);
    orin_release(orin_net_recv(c, 4, 10)); /* the closed slot: stale */
}
/* the slot of a closed stream is reused by the next one with a NEW generation: the old handle stays dead (generation-tagged handles) */
static void t_net_stale_after_reuse(void) {
    OrinObj *host = orin_str_new("127.0.0.1", 9); /* borrowed by connect; released before the trap (LeakSanitizer) */
    int64_t c1 = orin_net_connect(n_net, host, orin_net_port(n_lis), 1000, 0);
    orin_net_close(c1);
    int64_t c2 = orin_net_connect(n_net, host, orin_net_port(n_lis), 1000, 0);
    orin_release(host);
    if (c2 == c1 || (c2 & 0xff) != (c1 & 0xff)) _exit(3); /* the test needs the same slot under another generation */
    orin_release(orin_net_recv(c1, 4, 10));
}
static void t_net_double_close(void) {
    int64_t c = orin_net_connect(n_net, orin_str_new("127.0.0.1", 9), orin_net_port(n_lis), 1000, 0);
    orin_net_close(c);
    orin_net_close(c);
}
static void t_net_close_grant(void) { orin_net_close(n_net); }
static void t_net_send_range(void) {
    OrinObj *a = orin_array_new(4, 0);
    for (int i = 0; i < 4; i++) orin_array_push(a, (uint64_t)i);
    orin_release(orin_net_send(n_cl, a, 3, 2, 10)); /* [3, 5) of a 4 element array */
}
static void t_net_send_range_overflow(void) {
    OrinObj *a = orin_array_new(4, 0);
    orin_release(orin_net_send(n_cl, a, 1, UINT64_MAX, 10)); /* off + len wraps */
}
static void t_net_use_after_grant_revoked(void) {
    int64_t g = orin_cap_net(n_host);
    orin_cap_revoke(g);
    (void)orin_net_listen(g, orin_str_new("127.0.0.1", 9), 0, 4, 0);
}

static void test_net_handles(void) {
    unsetenv("ORIN_DENY");
    n_host = orin_cap_host_root();
    n_net = orin_cap_net(n_host);
    int64_t ll = orin_cap_listen(n_net, S("127.0.0.1"), 0);
    n_lis = orin_net_listen(ll, S("127.0.0.1"), 0, 8, 1);
    CHECK(n_lis > 0 && orin_net_status(n_lis) == 0 && orin_net_port(n_lis) > 0);
    int64_t cc = orin_cap_connect(n_net, S("127.0.0.1"), orin_net_port(n_lis), orin_net_port(n_lis));
    n_cl = orin_net_connect(cc, S("127.0.0.1"), orin_net_port(n_lis), 1000, 1);
    n_srv = orin_net_accept(n_lis, 1000, 1);
    CHECK(n_cl > 0 && n_srv > 0 && orin_net_now(n_cl) > 0 && orin_net_now(n_net) > 0);
    /* forged, wrong-kind, stale handles trap (exit 101), never reach a socket */
    CHECK(trap_code(t_net_forged) == 101 && trap_code(t_net_file_shaped) == 101);
    CHECK(trap_code(t_net_listener_as_stream) == 101 && trap_code(t_net_stream_as_listener) == 101 && trap_code(t_net_grant_as_stream) == 101);
    CHECK(trap_code(t_net_stale) == 101 && trap_code(t_net_double_close) == 101 && trap_code(t_net_close_grant) == 101);
    CHECK(trap_code(t_net_use_after_grant_revoked) == 101);
    CHECK(trap_code(t_net_stale_after_reuse) == 101);
    /* a set wake source (ADR-0017 Addendum D) ends a wait with the code 1004 and leaves the connection queued */
    int64_t wk = orin_platform_wake_open();
    CHECK(wk > 0 && orin_platform_wake_signal(wk) == 1);
    int64_t cancelled = orin_net_accept(n_lis, 1000, 0);
    CHECK(cancelled < 0 && orin_net_status(cancelled) == ORIN_PLATFORM_NET_CANCELLED);
    CHECK(orin_platform_wake_close(wk) == 0 && orin_platform_wake_bound() == 0);
    CHECK(trap_code(t_net_send_range) == 101 && trap_code(t_net_send_range_overflow) == 101);
    /* a recv never returns more than the capacity it was given, and the bytes are right */
    OrinObj *a = K(orin_array_new(10, 0));
    for (int i = 0; i < 10; i++) orin_array_push(a, (uint64_t)(200 + i));
    OrinObj *r = K(orin_net_send(n_cl, a, 2, 8, 1000)); /* bytes 202 .. 209 */
    CHECK(orin_tag(r) == 0 && orin_res_unwrap(r) == 8);
    r = K(orin_net_recv(n_srv, 3, 1000));
    CHECK(orin_tag(r) == 0 && orin_array_len(ORIN_REF(orin_res_unwrap(r))) == 3);
    CHECK(orin_array_at(ORIN_REF(orin_res_unwrap(r)), 0) == 202 && orin_array_at(ORIN_REF(orin_res_unwrap(r)), 2) == 204);
    r = K(orin_net_recv(n_srv, 1 << 20, 1000)); /* huge capacity: clamped, here only 5 bytes are there */
    CHECK(orin_tag(r) == 0 && orin_array_len(ORIN_REF(orin_res_unwrap(r))) == 5);
    r = K(orin_net_recv(n_srv, 4, 20)); /* nothing more: a timeout is a value, not a trap */
    CHECK(orin_tag(r) == 1 && orin_res_unwrap_err(r) == ORIN_PLATFORM_NET_TIMEOUT);
    r = K(orin_net_recv(n_srv, 0, 20));
    CHECK(orin_tag(r) == 1);
    r = K(orin_net_recv(n_srv, 4, -1));
    CHECK(orin_tag(r) == 1); /* no negative or infinite timeout */
    CHECK(orin_net_shutdown(n_cl, 1) == 0);
    r = K(orin_net_recv(n_srv, 4, 1000));
    CHECK(orin_tag(r) == 1 && orin_res_unwrap_err(r) == ORIN_PLATFORM_NET_EOF);
    OrinObj *p = K(orin_net_peer(n_srv));
    CHECK(orin_str_len(p) > 10 && orin_str_starts_with(p, S("127.0.0.1:")));
    /* scope: a widened narrowing reaches nothing; a listen grant cannot connect; refusals are EPERM values */
    int64_t wide = orin_cap_listen(ll, S("0.0.0.0"), 0);
    CHECK(orin_net_listen(wide, S("0.0.0.0"), 0, 4, 0) == -ORIN_PLATFORM_EPERM);
    CHECK(orin_net_listen(ll, S("127.0.0.1"), 80, 4, 0) == -ORIN_PLATFORM_EPERM);
    CHECK(orin_net_connect(ll, S("127.0.0.1"), orin_net_port(n_lis), 1000, 0) == -ORIN_PLATFORM_EPERM);
    CHECK(orin_net_connect(cc, S("127.0.0.1"), orin_net_port(n_lis) + 1, 1000, 0) == -ORIN_PLATFORM_EPERM);
    CHECK(orin_net_connect(cc, S("localhost"), orin_net_port(n_lis), 1000, 0) == -ORIN_PLATFORM_EPERM);
    OrinObj *rs = K(orin_net_resolve(cc, S("localhost")));
    CHECK(orin_tag(rs) == 1 && orin_res_unwrap_err(rs) == ORIN_PLATFORM_EPERM);
    CHECK(orin_net_status(-ORIN_PLATFORM_EPERM) == ORIN_PLATFORM_EPERM);
    orin_net_close(-ORIN_PLATFORM_EPERM); /* closing a failed open is a no-op */
    orin_net_close(n_srv), orin_net_close(n_cl), orin_net_close(n_lis);
    orin_cap_revoke(wide), orin_cap_revoke(cc), orin_cap_revoke(ll), orin_cap_revoke(n_net);
    /* host policy: ORIN_DENY=net refuses every operation (an EPERM value), even on a grant that is otherwise in scope */
    setenv("ORIN_DENY", "net", 1);
    n_host = orin_cap_host_root();
    n_net = orin_cap_net(n_host);
    CHECK(orin_net_listen(n_net, S("127.0.0.1"), 0, 4, 0) == -ORIN_PLATFORM_EPERM);
    CHECK(orin_net_connect(n_net, S("127.0.0.1"), 80, 100, 0) == -ORIN_PLATFORM_EPERM);
    int64_t nl = orin_cap_listen(n_net, S("127.0.0.1"), 0); /* narrowing a denied grant stays denied */
    CHECK(orin_net_listen(nl, S("127.0.0.1"), 0, 4, 0) == -ORIN_PLATFORM_EPERM);
    orin_cap_revoke(nl), orin_cap_revoke(n_net);
    unsetenv("ORIN_DENY");
    while (nkeep) orin_release(keep[--nkeep]);
}

/* ---- rename / remove / atomic write through the grant layer (C4 primitives) ---- */
static int read_back(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(out, 1, cap, f);
    fclose(f);
    return (int)n;
}
static int exists_(const char *path) { return access(path, F_OK) == 0; }
static int is_err(OrinObj *r, const char *msg) { return orin_tag(r) == 1 && streq(ORIN_REF(orin_res_unwrap_err(r)), msg); }
#define R(op, ...) K(orin_fs_##op(__VA_ARGS__))
static void test_fs_mutation(void) {
    char buf[64];
    unsetenv("ORIN_DENY");
    int64_t host = orin_cap_host_root(), fs = orin_cap_acquire(host, 1);
    CHECK(system("rm -rf /tmp/orin_rt_mut && mkdir -p /tmp/orin_rt_mut/in/sub /tmp/orin_rt_mut/out && "
                 "echo secret > /tmp/orin_rt_mut/out/s.txt && echo hi > /tmp/orin_rt_mut/in/a.txt && "
                 "ln -s ../out /tmp/orin_rt_mut/in/esc && ln -s a.txt /tmp/orin_rt_mut/in/lnk") == 0);
    int64_t in = orin_cap_narrow(fs, 0, S("/tmp/orin_rt_mut/in"));
    /* ungranted-scope (full) grant: rename, remove, atomic write */
    CHECK(orin_tag(R(write_file_atomic, fs, S("/tmp/orin_rt_mut/f1"), S("v1"))) == 0);
    CHECK(read_back("/tmp/orin_rt_mut/f1", buf, sizeof buf) == 2 && memcmp(buf, "v1", 2) == 0);
    CHECK(orin_tag(R(write_file_atomic, fs, S("/tmp/orin_rt_mut/f1"), S("v22"))) == 0);
    CHECK(read_back("/tmp/orin_rt_mut/f1", buf, sizeof buf) == 3);
    CHECK(orin_tag(R(rename, fs, S("/tmp/orin_rt_mut/f1"), S("/tmp/orin_rt_mut/f2"))) == 0);
    CHECK(!exists_("/tmp/orin_rt_mut/f1") && exists_("/tmp/orin_rt_mut/f2"));
    CHECK(is_err(R(rename, fs, S("/tmp/orin_rt_mut/f1"), S("/tmp/orin_rt_mut/f3")),
                 "cannot rename '/tmp/orin_rt_mut/f1': No such file or directory"));
    CHECK(orin_tag(R(remove_file, fs, S("/tmp/orin_rt_mut/f2"))) == 0 && !exists_("/tmp/orin_rt_mut/f2"));
    CHECK(is_err(R(remove_file, fs, S("/tmp/orin_rt_mut/f2")), "cannot remove '/tmp/orin_rt_mut/f2': No such file or directory"));
    CHECK(orin_tag(R(remove_file, fs, S("/tmp/orin_rt_mut/in/sub"))) == 1); /* a directory is not a file */
    CHECK(is_err(R(remove_dir, fs, S("/tmp/orin_rt_mut/in")), "cannot remove '/tmp/orin_rt_mut/in': Directory not empty"));
    CHECK(orin_tag(R(remove_dir, fs, S("/tmp/orin_rt_mut/in/sub"))) == 0 && !exists_("/tmp/orin_rt_mut/in/sub"));
    CHECK(orin_tag(R(remove_dir, fs, S("/tmp/orin_rt_mut/in/a.txt"))) == 1);
    CHECK(is_err(R(write_file_atomic, fs, S("/tmp/orin_rt_mut/nodir/x"), S("z")),
                 "cannot write '/tmp/orin_rt_mut/nodir/x': No such file or directory"));
    /* scoped grant: inside works, outside / traversal / links out are refused with the usual texts */
    CHECK(orin_tag(R(write_file_atomic, in, S("/tmp/orin_rt_mut/in/new.txt"), S("n"))) == 0);
    CHECK(orin_tag(R(rename, in, S("/tmp/orin_rt_mut/in/new.txt"), S("/tmp/orin_rt_mut/in/new2.txt"))) == 0);
    CHECK(exists_("/tmp/orin_rt_mut/in/new2.txt") && !exists_("/tmp/orin_rt_mut/in/new.txt"));
    CHECK(is_err(R(rename, in, S("/tmp/orin_rt_mut/in/new2.txt"), S("/tmp/orin_rt_mut/out/stolen.txt")),
                 "cannot rename '/tmp/orin_rt_mut/in/new2.txt': outside the granted file scope"));
    CHECK(is_err(R(rename, in, S("/tmp/orin_rt_mut/out/s.txt"), S("/tmp/orin_rt_mut/in/s.txt")),
                 "cannot rename '/tmp/orin_rt_mut/out/s.txt': outside the granted file scope"));
    CHECK(orin_tag(R(rename, in, S("/tmp/orin_rt_mut/in/new2.txt"), S("/tmp/orin_rt_mut/in/esc/e.txt"))) == 1); /* through a link out */
    CHECK(!exists_("/tmp/orin_rt_mut/out/e.txt") && exists_("/tmp/orin_rt_mut/in/new2.txt"));
    CHECK(orin_tag(R(rename, in, S("/tmp/orin_rt_mut/in/../out/s.txt"), S("/tmp/orin_rt_mut/in/x"))) == 1);
    CHECK(orin_tag(R(remove_file, in, S("/tmp/orin_rt_mut/out/s.txt"))) == 1 && exists_("/tmp/orin_rt_mut/out/s.txt"));
    CHECK(orin_tag(R(remove_file, in, S("/tmp/orin_rt_mut/in/esc/s.txt"))) == 1 && exists_("/tmp/orin_rt_mut/out/s.txt"));
    CHECK(orin_tag(R(write_file_atomic, in, S("/tmp/orin_rt_mut/in/esc/n.txt"), S("x"))) == 1 && !exists_("/tmp/orin_rt_mut/out/n.txt"));
    CHECK(orin_tag(R(remove_dir, in, S("/tmp/orin_rt_mut/in"))) == 1); /* the scope root itself lies outside via its parent */
    CHECK(orin_tag(R(remove_dir, in, S("/"))) == 1 && orin_tag(R(remove_file, in, S("/"))) == 1);
    /* a link is removed / replaced itself, never its target (also a link that leaves the scope) */
    CHECK(orin_tag(R(remove_file, in, S("/tmp/orin_rt_mut/in/lnk"))) == 0 && !exists_("/tmp/orin_rt_mut/in/lnk") && exists_("/tmp/orin_rt_mut/in/a.txt"));
    CHECK(orin_tag(R(remove_file, in, S("/tmp/orin_rt_mut/in/esc"))) == 0 && !exists_("/tmp/orin_rt_mut/in/esc") && exists_("/tmp/orin_rt_mut/out/s.txt"));
    CHECK(system("ln -s ../out/s.txt /tmp/orin_rt_mut/in/out_link") == 0);
    CHECK(orin_tag(R(write_file_atomic, in, S("/tmp/orin_rt_mut/in/out_link"), S("mine"))) == 0);
    CHECK(read_back("/tmp/orin_rt_mut/out/s.txt", buf, sizeof buf) == 7 && memcmp(buf, "secret\n", 7) == 0);
    CHECK(read_back("/tmp/orin_rt_mut/in/out_link", buf, sizeof buf) == 4 && memcmp(buf, "mine", 4) == 0);
    /* dot segments are normalised before the check */
    CHECK(orin_tag(R(write_file_atomic, in, S("/tmp/orin_rt_mut/in/../in/dot.txt"), S("d"))) == 0 && exists_("/tmp/orin_rt_mut/in/dot.txt"));
    /* read-only grant refuses all of them */
    int64_t ro = orin_cap_narrow(in, 1, S(""));
    CHECK(is_err(R(rename, ro, S("/tmp/orin_rt_mut/in/a.txt"), S("/tmp/orin_rt_mut/in/b.txt")), "cannot rename '/tmp/orin_rt_mut/in/a.txt': the file grant is read-only"));
    CHECK(is_err(R(remove_file, ro, S("/tmp/orin_rt_mut/in/a.txt")), "cannot remove '/tmp/orin_rt_mut/in/a.txt': the file grant is read-only"));
    CHECK(is_err(R(remove_dir, ro, S("/tmp/orin_rt_mut/in/a")), "cannot remove '/tmp/orin_rt_mut/in/a': the file grant is read-only"));
    CHECK(is_err(R(write_file_atomic, ro, S("/tmp/orin_rt_mut/in/a.txt"), S("x")), "cannot write '/tmp/orin_rt_mut/in/a.txt': the file grant is read-only"));
    CHECK(exists_("/tmp/orin_rt_mut/in/a.txt") && !exists_("/tmp/orin_rt_mut/in/b.txt"));
    /* a disjoint grant reaches nothing */
    int64_t disjoint = orin_cap_narrow(in, 0, S("/tmp/orin_rt_mut/out"));
    CHECK(orin_tag(R(remove_file, disjoint, S("/tmp/orin_rt_mut/out/s.txt"))) == 1 && exists_("/tmp/orin_rt_mut/out/s.txt"));
    /* forged / stale / wrong-family grants trap */
    CHECK(trap_code(t_mut_forged) == 101 && trap_code(t_mut_stale) == 101 && trap_code(t_mut_wrong_kind) == 101);
    /* the host policy */
    setenv("ORIN_DENY", "fs", 1);
    int64_t dhost = orin_cap_host_root(), denied = orin_cap_acquire(dhost, 1);
    CHECK(is_err(R(rename, denied, S("/tmp/orin_rt_mut/a"), S("/tmp/orin_rt_mut/b")), "cannot rename '/tmp/orin_rt_mut/a': denied by the host policy (ORIN_DENY)"));
    CHECK(is_err(R(remove_file, denied, S("/x")), "cannot remove '/x': denied by the host policy (ORIN_DENY)"));
    CHECK(is_err(R(remove_dir, denied, S("/x")), "cannot remove '/x': denied by the host policy (ORIN_DENY)"));
    CHECK(is_err(R(write_file_atomic, denied, S("/x"), S("")), "cannot write '/x': denied by the host policy (ORIN_DENY)"));
    orin_cap_revoke(denied); orin_cap_revoke(dhost);
    unsetenv("ORIN_DENY");
    /* nothing is left behind in the directory by any of the above */
    CHECK(system("! ls /tmp/orin_rt_mut /tmp/orin_rt_mut/in | grep -q orin-tmp") == 0);
    orin_cap_revoke(disjoint); orin_cap_revoke(ro); orin_cap_revoke(in); orin_cap_revoke(fs); orin_cap_revoke(host);
    CHECK(system("rm -rf /tmp/orin_rt_mut") == 0);
    while (nkeep) orin_release(keep[--nkeep]);
}
#undef R

#undef S
#undef orin_fs_read_file
#undef orin_fs_write_file

/* ---- bulk byte conversions and in-place array extension (docs/mir.md v1.10) ---- */
static OrinObj *u8array(const unsigned char *p, uint64_t n) {
    OrinObj *a = orin_array_new(n, 0);
    for (uint64_t i = 0; i < n; i++) orin_array_push(a, p[i]);
    return a;
}

/* Zero-capacity arrays have NULL items: an empty conversion must not form NULL + 0. */
static void test_empty_byte_strings(void) {
    int64_t base = orin_live_count();
    OrinObj *empty = orin_array_new(0, 0), *reserved = orin_array_new(4, 0);
    CHECK(((OrinArray *)empty)->items == NULL && orin_array_len(empty) == 0);
    CHECK(((OrinArray *)reserved)->items != NULL && orin_array_len(reserved) == 0);
    OrinObj *e0 = orin_bytes_to_string(empty, 0, 0);
    OrinObj *e1 = orin_bytes_to_string(empty, 0, 0);
    OrinObj *er = orin_bytes_to_string(reserved, 0, 0);
    CHECK(streq(e0, "") && streq(e1, "") && streq(er, ""));
    CHECK(e0 != e1 && e0 != er && e1 != er && e0->rc == 1 && e1->rc == 1 && er->rc == 1);
    CHECK(orin_str_data(e0)[0] == 0 && orin_str_data(e1)[0] == 0);
    unsigned char data[3] = {0, 65, 255};
    OrinObj *bytes = u8array(data, 3);
    OrinObj *start = orin_bytes_to_string(bytes, 0, 0), *end = orin_bytes_to_string(bytes, 3, 0);
    OrinObj *full = orin_bytes_to_string(bytes, 0, 3);
    CHECK(streq(start, "") && streq(end, "") && start != end);
    CHECK(orin_str_len(full) == 3 && memcmp(orin_str_data(full), data, 3) == 0);
    OrinObj *all[] = {empty, reserved, e0, e1, er, bytes, start, end, full};
    for (size_t i = 0; i < sizeof all / sizeof *all; i++) orin_release(all[i]);
    CHECK(orin_live_count() == base);
}

static int bulk_traps(int which) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        unsigned char b[3] = {1, 2, 3};
        OrinObj *a = u8array(b, 3);
        OrinObj *refs = orin_array_new(1, 1);
        OrinObj *str = S("x");
        OrinObj *empty = orin_array_new(0, 0);
        switch (which) {
        case 0: (void)orin_bytes_to_string(a, 2, 2); break;                 /* start + len > length */
        case 1: (void)orin_bytes_to_string(a, 4, 0); break;                 /* start > length */
        case 2: (void)orin_bytes_to_string(a, 1, (uint64_t)-1); break;      /* start + len overflows */
        case 3: (void)orin_bytes_to_string(str, 0, 1); break;               /* a string is not an array */
        case 4: (void)orin_bytes_to_string(refs, 0, 0); break;              /* a reference array is not a u8[] */
        case 5: orin_array_push(a, 256); (void)orin_bytes_to_string(a, 3, 1); break; /* element above 255 */
        case 6: (void)orin_string_to_bytes(a); break;                       /* an array is not a string */
        case 7: (void)orin_array_extend(str, a); break;                     /* a string cannot be extended */
        case 8: (void)orin_array_extend(a, str); break;
        case 9: (void)orin_bytes_to_string(empty, 1, 0); break;             /* empty array: start past end */
        case 10: (void)orin_bytes_to_string(empty, 0, 1); break;            /* empty array: length past end */
        case 11: (void)orin_bytes_to_string(str, 0, 0); break;              /* empty range still checks shape */
        }
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 101;
}

static void test_bulk(void) {
    int64_t base = orin_live_count();
    /* stringToBytes / bytesToString: every byte value, NUL included, round trips; empty ranges */
    unsigned char all[256];
    for (int i = 0; i < 256; i++) all[i] = (unsigned char)i;
    OrinObj *s = orin_str_new((const char *)all, 256);
    OrinObj *bytes = orin_string_to_bytes(s);
    CHECK(orin_array_len(bytes) == 256 && !((OrinArray *)bytes)->is_ref);
    for (uint64_t i = 0; i < 256; i++) CHECK(orin_array_at(bytes, i) == i);
    OrinObj *back = orin_bytes_to_string(bytes, 0, 256);
    CHECK(orin_str_eq(s, back));
    OrinObj *mid = orin_bytes_to_string(bytes, 65, 3);
    CHECK(streq(mid, "ABC"));
    OrinObj *e1 = orin_bytes_to_string(bytes, 256, 0), *e2 = orin_bytes_to_string(bytes, 0, 0);
    CHECK(orin_str_len(e1) == 0 && orin_str_len(e2) == 0);
    OrinObj *emp = S("");
    OrinObj *eb = orin_string_to_bytes(emp);
    CHECK(orin_array_len(eb) == 0);
    for (int i = 0; i < 12; i++) CHECK(bulk_traps(i));
    /* extend: in place when unique (same object), a copy when shared; b is never changed */
    OrinObj *x = orin_array_new(0, 0);
    for (uint64_t i = 0; i < 3; i++) orin_array_push(x, i);
    OrinObj *y = orin_array_new(0, 0);
    for (uint64_t i = 10; i < 13; i++) orin_array_push(y, i);
    OrinObj *x0 = x;
    x = orin_array_extend(x, y);
    CHECK(x == x0 && orin_array_len(x) == 6 && orin_array_at(x, 3) == 10 && orin_array_len(y) == 3);
    OrinObj *shared = orin_dup(x);
    x = orin_array_extend(x, y); /* x is shared: the result is a new array, `shared` keeps its length */
    CHECK(x != shared && orin_array_len(x) == 9 && orin_array_len(shared) == 6 && shared->rc == 1);
    x = orin_array_extend(x, x); /* y == x: never extended into itself in place, still a ++ a (and a is consumed) */
    CHECK(orin_array_len(x) == 18 && orin_array_at(x, 17) == 12 && orin_array_at(x, 8) == 12 && x->rc == 1);
    x0 = x;
    OrinObj *none_ = orin_array_new(0, 0);
    x = orin_array_extend(x, none_); /* appending nothing returns the same array */
    CHECK(x == x0);
    orin_release(none_);
    for (int i = 0; i < 1000; i++) x = orin_array_extend(x, y); /* amortised growth */
    CHECK(orin_array_len(x) == 18 + 3000);
    /* reference elements: every copied reference is retained once more */
    OrinObj *rs = orin_array_new(0, 1), *rt = orin_array_new(0, 1);
    OrinObj *p = S("p"), *q = S("q");
    orin_array_push(rs, ORIN_SLOT(orin_dup(p)));
    orin_array_push(rt, ORIN_SLOT(orin_dup(q)));
    rs = orin_array_extend(rs, rt);
    rs = orin_array_extend(rs, rs);
    CHECK(orin_array_len(rs) == 4 && p->rc == 3 && q->rc == 4 && rt->rc == 1);
    OrinObj *emptyref = orin_array_new(0, 0); /* an empty array adopts the element kind of b */
    emptyref = orin_array_extend(emptyref, rt);
    CHECK(((OrinArray *)emptyref)->is_ref == 1 && orin_array_len(emptyref) == 1 && q->rc == 5);
    OrinObj *all2[] = {s, bytes, back, mid, e1, e2, emp, eb, x, y, shared, rs, rt, p, q, emptyref};
    for (size_t i = 0; i < sizeof all2 / sizeof *all2; i++) orin_release(all2[i]);
    CHECK(orin_live_count() == base);
}

int main(int argc, char **argv) {
    orin_init(argc, argv);
    test_strings();
    test_arrays_cow();
    test_deep_chain();
    test_misc();
    test_shape_traps();
    test_empty_byte_strings();
    test_bulk();
    test_list_dir();
    test_grants();
    test_fs_mutation();
    test_net_handles();
    if (failures) return 1;
    printf("ok\n");
    orin_flush();
    return 0;
}
