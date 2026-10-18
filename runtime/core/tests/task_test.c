/* Task runtime tests (ADR-0017 stage 0): transfer by move or deep copy, task start / join / trap, monitors, grants moving
 * into a task, per-task heaps. Build and run:
 *     cc -g -I runtime/core runtime/core/tests/task_test.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c $(tools/rt_stub.sh build/rt_stub.o) -lm -o build/task_test
 * (tools/rt_stub.sh: the object model is Orin code since ADR-0052 R3d.3; the stub object defines its C names for the C shells)
 * and the same with -fsanitize=thread, and with -fsanitize=address,undefined (tools/test_concurrency.sh does all three).
 * Exits 0 and prints "task_test: N checks passed" on success. */
#define _GNU_SOURCE
#include "orin_runtime.h"
#include "../../platform/orin_platform.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ORIN_TRANSFER_IN_ORIN
/* The transfer, lend and thread-count operations of runtime/core/{transfer,lend,task}.or (the functions std:task calls) instead of the C
 * ones, through the test wrappers of `--rt-wrappers` (tools/rt_stub.sh; ADR-0052 Addendum B, R3e.2 and R3e.3). The C task code works on
 * the same slot table. */
uint64_t orin_t_transfer_put(OrinObj *box);
OrinObj *orin_t_transfer_take(uint64_t token);
void orin_t_transfer_drop(uint64_t token);
uint64_t orin_t_transfer_count(uint64_t which);
uint64_t orin_t_lend(OrinObj *box);
uint64_t orin_t_par_threads(void);
#define orin_rt_lend orin_t_lend
#define orin_rt_par_threads orin_t_par_threads
#define orin_rt_transfer_put orin_t_transfer_put
#define orin_rt_transfer_take orin_t_transfer_take
#define orin_rt_transfer_drop orin_t_transfer_drop
#define orin_rt_transfer_count orin_t_transfer_count
#endif

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
        while (orin_mon_get(m, 0) != 1) orin_mon_wait(m, 0);
        OrinObj *b = orin_rt_transfer_take(orin_mon_get(m, 1));
        int64_t v = (int64_t)orin_struct_get(b, 0);
        orin_release(b);
        orin_mon_set(m, 1, orin_rt_transfer_put(box_int(v + 1)) );
        orin_mon_set(m, 0, 2);
        orin_mon_notify_all(m, 0);
        orin_mon_unlock(m);
    }
}

/* C1: orin_rt_task_watch (a task announces its end, by return or by trap) and orin_mon_wait_until (timed wait) */
static void body_watched(OrinObj *env) {
    orin_rt_task_watch(orin_struct_get(env, 0));
    if (orin_struct_get(env, 1)) orin_trap("watched task trapped");
}

static int wait_done(uint64_t m, int64_t millis) { /* 1 when word 1 became 1 within `millis`, else 0 */
    int64_t deadline = orin_platform_monotonic_millis() + millis;
    orin_mon_lock(m);
    while (orin_mon_get(m, 1) == 0)
        if (orin_mon_wait_until(m, 0, (uint64_t)deadline)) break;
    int done = orin_mon_get(m, 1) != 0;
    orin_mon_unlock(m);
    return done;
}

static void test_timed(void) {
    uint64_t m = orin_mon_new(2);
    orin_mon_lock(m);
    int64_t t0 = orin_platform_monotonic_millis();
    CHECK(orin_mon_wait_until(m, 1, (uint64_t)t0 + 50) == 1); /* nobody notifies: the deadline passes */
    CHECK(orin_platform_monotonic_millis() >= t0 + 50);
    CHECK(orin_mon_wait_until(m, 0, 0) == 1); /* long past: returns at once */
    orin_mon_unlock(m);
    CHECK(wait_done(m, 30) == 0);
    for (int trapped = 0; trapped < 2; trapped++) { /* the end of a task, by return and by trap, wakes the timed waiter */
        uint64_t w = orin_mon_new(2);
        OrinObj *e = orin_struct_new(0, 2, 0);
        orin_struct_init(e, 0, w);
        orin_struct_init(e, 1, (uint64_t)trapped);
        uint64_t th = start(body_watched, e);
        CHECK(wait_done(w, 60000) == 1);
        CHECK(orin_rt_task_join(th) == (uint64_t)trapped);
        if (trapped) orin_release(orin_rt_task_message());
        orin_mon_free(w);
    }
    orin_mon_free(m);
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
        orin_mon_notify_all(m, 0);
        while (orin_mon_get(m, 0) != 2) orin_mon_wait(m, 0);
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


/* ---------------------------------------------------------------- network handles moving into a task (ADR-0017 Addendum C) */

enum { NETN = 8 };
static uint64_t g_net_tok[NETN], g_stream_tok[NETN];
static int g_net_port, g_net_ok[NETN], g_srv_ok[NETN];
static OrinObj *u8_of(const char *t) { /* a u8[] */
    OrinObj *a = orin_array_new(strlen(t), 0);
    for (size_t i = 0; t[i]; i++) orin_array_push(a, (uint64_t)(unsigned char)t[i]);
    return a;
}

static void body_net_client(OrinObj *env) { /* adopts a cloned NetGrant, connects, ping / pong, closes */
    int64_t i = (int64_t)orin_struct_get(env, 0);
    int64_t g = orin_cap_adopt_net(g_net_tok[i]);
    orin_cap_require(g, 5, "net");
    OrinObj *host = S("127.0.0.1");
    int64_t s = orin_net_connect(g, host, g_net_port, 2000, 1);
    orin_release(host);
    if (s > 0) {
        OrinObj *ping = u8_of("ping");
        OrinObj *w = orin_net_send(s, ping, 0, 4, 2000);
        orin_release(w);
        orin_release(ping);
        OrinObj *r = orin_net_recv(s, 16, 2000); /* Result<u8[], int>: tag 0 = Ok */
        g_net_ok[i] = orin_tag(r) == 0;
        orin_release(r);
        orin_net_close(s);
    }
    orin_cap_revoke(g);
}

static void body_net_server(OrinObj *env) { /* adopts the accepted Stream the main task moved out, pong */
    int64_t i = (int64_t)orin_struct_get(env, 0);
    int64_t s = orin_cap_adopt_stream(g_stream_tok[i]);
    orin_cap_require(s, 7, "stream");
    OrinObj *r = orin_net_recv(s, 16, 2000);
    int ok = orin_tag(r) == 0;
    orin_release(r);
    OrinObj *pong = u8_of("pong");
    OrinObj *w = orin_net_send(s, pong, 0, 4, 2000);
    orin_release(w);
    orin_release(pong);
    g_srv_ok[i] = ok;
    orin_net_close(s);
}

static int64_t g_dead_stream;
static void body_use_moved(OrinObj *env) { /* the moved Stream's handle is dead in the task that moved it */
    (void)env;
    (void)orin_net_status(g_dead_stream); /* traps: stale handle */
}
static uint64_t g_twice_tok;
static void body_adopt_twice(OrinObj *env) {
    (void)env;
    int64_t s = orin_cap_adopt_stream(g_twice_tok); /* traps: the token was adopted already */
    orin_net_close(s);
}
static void body_adopt_wrong_kind(OrinObj *env) { /* a Stream token adopted as a NetGrant */
    (void)env;
    (void)orin_cap_adopt_net(g_twice_tok);
}
static void body_move_listener(OrinObj *env) { /* a task binds its own listener and tries to move it: refused */
    int64_t i = (int64_t)orin_struct_get(env, 0);
    int64_t g = orin_cap_adopt_net(g_net_tok[i]);
    OrinObj *a = S("127.0.0.1");
    int64_t lg = orin_cap_listen(g, a, 0);
    int64_t l = orin_net_listen(lg, a, 0, 4, 1);
    (void)orin_cap_move(l); /* traps */
    orin_release(a);
}

static OrinObj *env_i(int64_t i) {
    OrinObj *e = orin_struct_new(0, 1, 0);
    orin_struct_init(e, 0, (uint64_t)i);
    return e;
}

static void test_net_move(void) {
    int64_t host = orin_cap_host_root();
    int64_t net = orin_cap_net(host);
    OrinObj *a = S("127.0.0.1");
    int64_t lg = orin_cap_listen(net, a, 0);
    int64_t ln = orin_net_listen(lg, a, 0, 16, 1);
    CHECK(ln > 0);
    g_net_port = (int)orin_net_port(ln);
    uint64_t cth[NETN], sth[NETN];
    for (int i = 0; i < NETN; i++) { /* NETN client tasks, each with its own clone of the NetGrant */
        int64_t c = orin_cap_clone(net);
        CHECK(c != net);
        g_net_tok[i] = orin_cap_move(c);
        cth[i] = start(body_net_client, env_i(i));
    }
    int64_t first = 0;
    for (int i = 0; i < NETN; i++) { /* accept each connection and MOVE it into a task of its own */
        int64_t st = orin_net_accept(ln, 2000, 1);
        CHECK(st > 0);
        if (i == 0) first = st;
        g_stream_tok[i] = orin_cap_move(st);
        sth[i] = start(body_net_server, env_i(i));
    }
    for (int i = 0; i < NETN; i++) {
        CHECK(orin_rt_task_join(cth[i]) == 0);
        CHECK(orin_rt_task_join(sth[i]) == 0);
        CHECK(g_net_ok[i] && g_srv_ok[i]);
    }
    /* the moved handle is dead for the mover */
    g_dead_stream = first;
    uint64_t th = start(body_use_moved, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 1);
    orin_release(orin_rt_task_message());
    /* a token is valid for one adopt; the wrong family is refused */
    OrinObj *h = S("127.0.0.1");
    int64_t cs = orin_net_connect(net, h, g_net_port, 2000, 1);
    orin_release(h);
    CHECK(cs > 0);
    int64_t st = orin_net_accept(ln, 2000, 1);
    CHECK(st > 0);
    g_twice_tok = orin_cap_move(st);
    th = start(body_adopt_wrong_kind, orin_nullary(0));
    CHECK(orin_rt_task_join(th) == 1);
    OrinObj *msg = orin_rt_task_message();
    CHECK(strstr(orin_str_data(msg), "wrong family") != NULL);
    orin_release(msg);
    th = start(body_adopt_twice, orin_nullary(0)); /* the failed adopt consumed the token */
    CHECK(orin_rt_task_join(th) == 1);
    msg = orin_rt_task_message();
    CHECK(strstr(orin_str_data(msg), "invalid grant token") != NULL);
    orin_release(msg);
    orin_net_close(cs);
    /* a Listener never moves */
    g_net_tok[0] = orin_cap_move(orin_cap_clone(net));
    th = start(body_move_listener, env_i(0));
    CHECK(orin_rt_task_join(th) == 1);
    msg = orin_rt_task_message();
    CHECK(strstr(orin_str_data(msg), "only a family grant or a Stream") != NULL);
    orin_release(msg);
    orin_release(a);
    orin_net_close(ln);
    orin_cap_revoke(lg);
    orin_cap_revoke(net);
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

/* ---------------------------------------------------------------- lending (ADR-0039 §4, `.parallel()`) */

static OrinObj *lend_box(OrinObj *v) { /* the two-slot record of a lend; consumes v */
    OrinObj *b = orin_struct_new(0, 2, 1);
    orin_struct_init(b, 0, ORIN_SLOT(v));
    orin_struct_init(b, 1, 0);
    return b;
}

static void body_sum(OrinObj *env) { /* env: { lent int array, monitor, word }: reads the array like generated code */
    OrinObj *arr = ORIN_REF(orin_struct_get(env, 0));
    uint64_t m = orin_struct_get(env, 1), k = orin_struct_get(env, 2);
    for (int r = 0; r < 100; r++) {
        orin_retain(arr); /* no-op on a pinned object: the shared count is never written */
        orin_release(arr);
    }
    int64_t s = 0;
    for (uint64_t i = 0; i < orin_array_len(arr); i++) s += (int64_t)orin_array_at(arr, i);
    orin_mon_lock(m);
    orin_mon_set(m, k, (uint64_t)s);
    orin_mon_unlock(m);
}

static OrinObj *env3(OrinObj *ref, uint64_t m, uint64_t k) { /* consumes ref */
    OrinObj *e = orin_struct_new(0, 3, 1);
    orin_struct_init(e, 0, ORIN_SLOT(ref));
    orin_struct_init(e, 1, m);
    orin_struct_init(e, 2, k);
    return e;
}

static void body_send_back(OrinObj *env) { /* env: { lent record array, monitor, _ }: sends element 0 back to the owner */
    OrinObj *recs = ORIN_REF(orin_struct_get(env, 0));
    uint64_t m = orin_struct_get(env, 1);
    OrinObj *r0 = ORIN_REF(orin_array_at(recs, 0));
    orin_retain(r0);
    OrinObj *b = box_ref(r0);
    uint64_t tok = orin_rt_transfer_put(b); /* by a task that does not own the pin: must copy r0 */
    orin_release(b);
    orin_mon_lock(m);
    orin_mon_set(m, 0, tok);
    orin_mon_unlock(m);
}

static void test_lend(void) {
    int64_t base = orin_live_count();
    /* an int array lent to 8 tasks: no copy, counts untouched, restored at the end */
    OrinObj *arr = orin_array_new(1000, 0);
    int64_t want = 0;
    for (int64_t i = 0; i < 1000; i++) {
        orin_array_push(arr, (uint64_t)i);
        want += i;
    }
    orin_retain(arr);
    OrinObj *lb = lend_box(arr);
    uint64_t lt = orin_rt_lend(lb);
    orin_release(lb);
    CHECK(arr->rc < 0);
    uint64_t c0 = orin_rt_transfer_count(1);
    enum { T = 8 };
    uint64_t m = orin_mon_new(T), th[T];
    for (int i = 0; i < T; i++) {
        orin_retain(arr);
        th[i] = start(body_sum, env3(arr, m, (uint64_t)i));
    }
    for (int i = 0; i < T; i++) CHECK(orin_rt_task_join(th[i]) == 0);
    CHECK(orin_rt_transfer_count(1) == c0); /* the closures were moved and shared the pinned array: nothing copied */
    orin_mon_lock(m);
    for (int i = 0; i < T; i++) CHECK((int64_t)orin_mon_get(m, (uint64_t)i) == want);
    orin_mon_unlock(m);
    orin_rt_transfer_drop(lt);
    CHECK(arr->rc == 1);
    orin_release(arr);
    /* records: a result sent back by a reader is a COPY, so no reference into the lent graph survives the lend */
    OrinObj *recs = orin_array_new(4, 1);
    for (int64_t i = 0; i < 4; i++) {
        OrinObj *r = orin_struct_new(0, 1, 0);
        orin_struct_init(r, 0, (uint64_t)(i * 7));
        orin_array_push(recs, ORIN_SLOT(r));
    }
    OrinObj *r0 = ORIN_REF(orin_array_at(recs, 0));
    orin_retain(recs);
    lb = lend_box(recs);
    lt = orin_rt_lend(lb);
    orin_release(lb);
    CHECK(recs->rc < 0 && r0->rc < 0);
    orin_retain(recs);
    uint64_t t1 = start(body_send_back, env3(recs, m, 0));
    CHECK(orin_rt_task_join(t1) == 0);
    orin_mon_lock(m);
    uint64_t tok = orin_mon_get(m, 0);
    orin_mon_unlock(m);
    OrinObj *got = orin_rt_transfer_take(tok);
    CHECK(unbox(got) != r0 && orin_struct_get(unbox(got), 0) == 0);
    orin_rt_transfer_drop(lt);
    CHECK(recs->rc == 1 && r0->rc == 1);
    orin_release(got);
    orin_release(recs);
    orin_mon_free(m);
    CHECK(orin_live_count() == base);
    /* the thread count of parallel pipelines */
    CHECK(orin_rt_par_threads() >= 1);
    setenv("ORIN_THREADS", "3", 1);
    CHECK(orin_rt_par_threads() == 3);
    setenv("ORIN_THREADS", "0", 1);
    CHECK(orin_rt_par_threads() == orin_platform_cpu_count());
    setenv("ORIN_THREADS", "x2", 1);
    CHECK(orin_rt_par_threads() == orin_platform_cpu_count());
    unsetenv("ORIN_THREADS");
}

int main(void) {
    orin_init(0, NULL);
    test_lend();
    test_transfer();
    test_tasks();
    test_trap();
    test_timed();
    test_pingpong();
    test_cross_heap_free();
    test_grants();
    test_grant_is_per_task();
    test_net_move();
    test_invalid_handles();
    if (failures) {
        fprintf(stderr, "task_test: %d of %d checks FAILED\n", failures, checks);
        return 1;
    }
    printf("task_test: %d checks passed\n", checks);
    return 0;
}
