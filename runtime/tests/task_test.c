/* Task runtime tests (ADR-0017 stage 0): transfer by move or deep copy, task start / join / trap, monitors, grants moving
 * into a task, per-task heaps. Build and run:
 *     cc -g -I runtime runtime/tests/task_test.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/task_test
 * and the same with -fsanitize=thread, and with -fsanitize=address,undefined (tools/test_concurrency.sh does all three).
 * Exits 0 and prints "task_test: N checks passed" on success. */
#define _GNU_SOURCE
#include "orin_runtime.h"
#include "../../platform/orin_platform.h"
#include <stdio.h>
#include <string.h>

static int checks, failures;
#define CHECK(c)                                                                                \
    do {                                                                                        \
        checks++;                                                                               \
        if (!(c)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                        \
            failures++;                                                                         \
        }                                                                                       \
    } while (0)

static OrinObj *S(const char *s) { return orin_str_new(s, strlen(s)); }
static int streq(OrinObj *o, const char *s) {
    return orin_str_len(o) == strlen(s) && memcmp(orin_str_data(o), s, strlen(s)) == 0;
}

/* A box: the record with one slot that std:task builds around every transferred value. Consumes v. */
static OrinObj *box_ref(OrinObj *v) {
    OrinObj *b = orin_struct_new(0, 1, 1);
    orin_struct_init(b, 0, ORIN_SLOT(v));
    return b;
}
static OrinObj *box_int(int64_t v) {
    OrinObj *b = orin_struct_new(0, 1, 0);
    orin_struct_init(b, 0, (uint64_t)v);
    return b;
}
static OrinObj *unbox(OrinObj *b) { return ORIN_REF(orin_struct_get(b, 0)); }

/* put + take in one thread, releasing the sender's box like generated code does after the call. */
static OrinObj *send(OrinObj *box) {
    uint64_t tok = orin_rt_transfer_put(box);
    orin_release(box);
    return orin_rt_transfer_take(tok);
}

static void test_transfer(void) {
    int64_t base = orin_live_count();
    uint64_t m0 = orin_rt_transfer_count(0), c0 = orin_rt_transfer_count(1);

    /* a uniquely owned graph is moved: the receiver sees the very same object */
    OrinObj *arr = orin_array_new(2, 1);
    OrinObj *a = S("alpha"), *b = S("beta");
    orin_array_push(arr, ORIN_SLOT(a));
    orin_array_push(arr, ORIN_SLOT(b));
    OrinObj *got = send(box_ref(arr));
    CHECK(unbox(got) == arr);
    CHECK(orin_rt_transfer_count(0) == m0 + 1 && orin_rt_transfer_count(1) == c0);
    CHECK(orin_array_len(unbox(got)) == 2 && streq(ORIN_REF(orin_array_at(unbox(got), 1)), "beta"));
    orin_release(got);
    CHECK(orin_live_count() == base);

    /* a value that is still referenced elsewhere is copied: a fresh graph, the original untouched */
    OrinObj *s = S("shared");
    orin_retain(s); /* the sender's other reference */
    got = send(box_ref(s));
    CHECK(unbox(got) != s && streq(unbox(got), "shared"));
    CHECK(orin_rt_transfer_count(1) == c0 + 1);
    CHECK(s->rc == 1); /* only the sender's own reference is left */
    orin_release(got);
    orin_release(s);

    /* a child shared INSIDE the graph also makes the whole transfer a copy */
    OrinObj *inner = S("inner");
    OrinObj *rec = orin_struct_new(0, 2, 3);
    orin_retain(inner);
    orin_struct_init(rec, 0, ORIN_SLOT(inner));
    orin_struct_init(rec, 1, ORIN_SLOT(inner));
    got = send(box_ref(rec));
    CHECK(orin_rt_transfer_count(1) == c0 + 2);
    OrinObj *r2 = unbox(got);
    CHECK(r2 != rec && ORIN_REF(orin_struct_get(r2, 0)) != inner);
    CHECK(streq(ORIN_REF(orin_struct_get(r2, 0)), "inner") && streq(ORIN_REF(orin_struct_get(r2, 1)), "inner"));
    orin_release(got);
    CHECK(orin_live_count() == base);

    /* scalars travel without a count; immortal objects (literals, singletons) are shared, not copied */
    got = send(box_int(-42));
    CHECK((int64_t)orin_struct_get(got, 0) == -42);
    orin_release(got);
    OrinObj *none = orin_none();
    OrinObj *opt = orin_struct_new(0, 1, 1);
    orin_struct_init(opt, 0, ORIN_SLOT(none));
    got = send(box_ref(opt));
    CHECK(ORIN_REF(orin_struct_get(unbox(got), 0)) == none);
    orin_release(got);
    CHECK(orin_live_count() == base);

    /* a long chain (200,000 nested records) neither overflows the stack nor leaks, moved or copied */
    OrinObj *chain = orin_nullary(1);
    for (int i = 0; i < 200000; i++) {
        OrinObj *n = orin_struct_new(0, 2, 2);
        orin_struct_init(n, 0, (uint64_t)i);
        orin_struct_init(n, 1, ORIN_SLOT(chain));
        chain = n;
    }
    orin_retain(chain);
    got = send(box_ref(chain)); /* shared: copied */
    OrinObj *p = unbox(got);
    int len = 0;
    while (orin_tag(p) == 0 && len < 300000) {
        len++;
        p = ORIN_REF(orin_struct_get(p, 1));
    }
    CHECK(len == 200000);
    orin_release(got);
    got = send(box_ref(chain)); /* now unique: moved */
    orin_release(got);
    CHECK(orin_live_count() == base);

    /* a token is taken exactly once */
    uint64_t tok = orin_rt_transfer_put(box_int(1));
    orin_release(orin_rt_transfer_take(tok));
    (void)tok;
}

/* ---------------------------------------------------------------- tasks */

static uint64_t g_mon;

static OrinObj *closure_of(void (*fn)(OrinObj *), OrinObj *env) {
    OrinObj *c = orin_struct_new(0, 2, 2);
    orin_struct_init(c, 0, (uint64_t)(uintptr_t)fn);
    orin_struct_init(c, 1, ORIN_SLOT(env));
    return c;
}

static uint64_t start(void (*fn)(OrinObj *), OrinObj *env) {
    OrinObj *b = box_ref(closure_of(fn, env));
    uint64_t tok = orin_rt_transfer_put(b);
    orin_release(b); /* the sender's (now empty, or still full if the value was copied) box */
    return orin_rt_task_spawn(tok);
}

static void body_incr(OrinObj *env) { /* env: record { monitor, n } */
    uint64_t m = orin_struct_get(env, 0), n = orin_struct_get(env, 1);
    for (uint64_t i = 0; i < n; i++) {
        orin_mon_lock(m);
        orin_mon_set(m, 0, orin_mon_get(m, 0) + 1);
        orin_mon_unlock(m);
    }
}

static OrinObj *env_of(uint64_t m, uint64_t n) {
    OrinObj *e = orin_struct_new(0, 2, 0);
    orin_struct_init(e, 0, m);
    orin_struct_init(e, 1, n);
    return e;
}

static void test_tasks(void) {
    int64_t base = orin_live_count();
    uint64_t m = orin_mon_new(1);
    enum { T = 64 };
    uint64_t th[T];
    for (int i = 0; i < T; i++) th[i] = start(body_incr, env_of(m, 1000));
    for (int i = 0; i < T; i++) CHECK(orin_rt_task_join(th[i]) == 0);
    orin_mon_lock(m);
    CHECK(orin_mon_get(m, 0) == (uint64_t)T * 1000);
    orin_mon_unlock(m);
    orin_mon_free(m);
    CHECK(orin_live_count() == base); /* the tasks' closures, environments and boxes are all gone */
}

static void body_trap(OrinObj *env) {
    (void)env;
    uint64_t m = g_mon;
    orin_mon_lock(m); /* the task dies holding a monitor: the runtime must release it */
    OrinObj *s = S("allocated before the trap"); /* leaked by design: a trap does not unwind */
    (void)s;
    orin_trap("boom in task");
}

static void test_trap(void) {
    g_mon = orin_mon_new(1);
    uint64_t th = start(body_trap, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 1);
    OrinObj *msg = orin_rt_task_message();
    CHECK(streq(msg, "boom in task"));
    orin_release(msg);
    orin_mon_lock(g_mon); /* would deadlock if the dead task still held it */
    orin_mon_unlock(g_mon);
    orin_mon_free(g_mon);
}

/* a bounded one-slot mailbox in a monitor: ping-pong between main and a task through condition variables and tokens */
static void body_echo(OrinObj *env) { /* words: 0 = state (0 empty, 1 ping, 2 pong), 1 = token */
    uint64_t m = orin_struct_get(env, 0), rounds = orin_struct_get(env, 1);
    for (uint64_t i = 0; i < rounds; i++) {
        orin_mon_lock(m);
        while (orin_mon_get(m, 0) != 1) orin_mon_wait(m);
        OrinObj *b = orin_rt_transfer_take(orin_mon_get(m, 1));
        int64_t v = (int64_t)orin_struct_get(b, 0);
        orin_release(b);
        orin_mon_set(m, 1, orin_rt_transfer_put(box_int(v + 1)) );
        orin_mon_set(m, 0, 2);
        orin_mon_notify_all(m);
        orin_mon_unlock(m);
    }
}

static void test_pingpong(void) {
    uint64_t m = orin_mon_new(2);
    uint64_t th = start(body_echo, env_of(m, 2000));
    int64_t v = 0;
    for (int i = 0; i < 2000; i++) {
        OrinObj *b = box_int(v);
        uint64_t tok = orin_rt_transfer_put(b);
        orin_release(b);
        orin_mon_lock(m);
        orin_mon_set(m, 1, tok);
        orin_mon_set(m, 0, 1);
        orin_mon_notify_all(m);
        while (orin_mon_get(m, 0) != 2) orin_mon_wait(m);
        OrinObj *r = orin_rt_transfer_take(orin_mon_get(m, 1));
        v = (int64_t)orin_struct_get(r, 0);
        orin_release(r);
        orin_mon_set(m, 0, 0);
        orin_mon_unlock(m);
    }
    CHECK(v == 2000);
    CHECK(orin_rt_task_join(th) == 0);
    orin_mon_free(m);
}

/* a producer task sends 5,000 arrays of strings; main receives them through the transfer table (moved, so no copy) */
static uint64_t g_toks[5000];
static void body_produce(OrinObj *env) {
    (void)env;
    for (int i = 0; i < 5000; i++) {
        OrinObj *arr = orin_array_new(2, 1);
        char buf[32];
        int n = snprintf(buf, sizeof buf, "item-%d", i);
        orin_array_push(arr, ORIN_SLOT(orin_str_new(buf, (uint64_t)n)));
        orin_array_push(arr, ORIN_SLOT(orin_str_new("payload", 7)));
        OrinObj *b = box_ref(arr);
        g_toks[i] = orin_rt_transfer_put(b);
        orin_release(b);
    }
}

static void test_cross_heap_free(void) {
    int64_t base = orin_live_count();
    uint64_t th = start(body_produce, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 0);
    int ok = 1;
    for (int i = 0; i < 5000; i++) {
        OrinObj *b = orin_rt_transfer_take(g_toks[i]);
        char buf[32];
        int n = snprintf(buf, sizeof buf, "item-%d", i);
        OrinObj *arr = unbox(b);
        if (!(streq(ORIN_REF(orin_array_at(arr, 0)), buf) && streq(ORIN_REF(orin_array_at(arr, 1)), "payload"))) ok = 0;
        (void)n;
        orin_release(b); /* freed by main although allocated by the task */
    }
    CHECK(ok);
    CHECK(orin_live_count() == base); /* allocations of the finished task and frees of main cancel out */
}

/* a grant is cloned, moved out, adopted by a task; the task's handle is unusable elsewhere */
static uint64_t g_grant_tok;
static int64_t g_stolen;
static void body_grant(OrinObj *env) {
    (void)env;
    int64_t g = orin_cap_adopt_clock(g_grant_tok);
    orin_cap_require(g, 4, "now"); /* valid in the adopting task */
    g_stolen = g;
    orin_cap_revoke(g);
}

static void test_grants(void) {
    int64_t host = orin_cap_host_root();
    int64_t clk = orin_cap_clock(host);
    int64_t c = orin_cap_clone(clk);
    CHECK(c != clk);
    g_grant_tok = orin_cap_move(c);
    uint64_t th = start(body_grant, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 0);
    orin_cap_require(clk, 4, "now"); /* the parent's own grant is untouched */
    orin_cap_revoke(clk);
    orin_cap_revoke(host);
}

static void body_foreign(OrinObj *env) { /* uses a handle that belongs to another task: must trap */
    orin_cap_require((int64_t)orin_struct_get(env, 0), 4, "now");
}

static void test_grant_is_per_task(void) {
    int64_t host = orin_cap_host_root();
    int64_t clk = orin_cap_clock(host);
    OrinObj *e = orin_struct_new(0, 1, 0);
    orin_struct_init(e, 0, (uint64_t)clk);
    uint64_t th = start(body_foreign, e);
    CHECK(orin_rt_task_join(th) == 1);
    OrinObj *msg = orin_rt_task_message();
    CHECK(orin_str_len(msg) > 0 && strstr(orin_str_data(msg), "invalid capability grant"));
    orin_release(msg);
    orin_cap_revoke(clk);
    orin_cap_revoke(host);
}

/* a grant a task leaves open when it traps is revoked by the runtime (the table has 256 slots) */
static void body_leak_grant(OrinObj *env) {
    (void)env;
    int64_t host = 0;
    (void)host;
    orin_trap("leaves grants open");
}

static void test_invalid_handles(void) {
    CHECK(orin_platform_monitor_lock(0) == ORIN_PLATFORM_EINVAL);
    uint64_t m = orin_mon_new(1);
    orin_mon_free(m);
    CHECK(orin_platform_monitor_lock((int64_t)m) == ORIN_PLATFORM_EINVAL); /* stale handle */
    void *arg;
    CHECK(orin_platform_thread_join(12345, &arg) == ORIN_PLATFORM_EINVAL);
    uint64_t th = start(body_leak_grant, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 1);
    OrinObj *msg = orin_rt_task_message();
    orin_release(msg);
    CHECK(orin_platform_thread_join((int64_t)th, &arg) == ORIN_PLATFORM_EINVAL); /* joined twice */
}

int main(void) {
    orin_init(0, NULL);
    test_transfer();
    test_tasks();
    test_trap();
    test_pingpong();
    test_cross_heap_free();
    test_grants();
    test_grant_is_per_task();
    test_invalid_handles();
    if (failures) {
        fprintf(stderr, "task_test: %d of %d checks FAILED\n", failures, checks);
        return 1;
    }
    printf("task_test: %d checks passed\n", checks);
    return 0;
}
