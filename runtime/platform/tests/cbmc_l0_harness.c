/* CBMC harnesses for the remaining pure / model-checkable part of the L0 platform layer (ADR-0053 M7):
 * float text conversion, the clock wrappers, argument access, host-policy loading, path_absolute, error_message and the
 * HANDLE VALIDATION logic of threads and monitors (generation + liveness) as a bounded state machine. Run by
 * tools/verify_platform.sh like cbmc_harness.c:
 *   cbmc runtime/platform/tests/cbmc_l0_harness.c --function <harness> --bounds-check --pointer-check ...
 * The harness INCLUDES orin_platform.c (to reach the static handle tables and mon_ref) and replaces the system calls by
 * stubs that are nondeterministic within the OS contract. The threads themselves are NOT modelled (pthread_create /
 * pthread_join are stubs that do not run anything): what is checked is the table logic -- which handle is accepted,
 * which refused -- not the interleaving, which stays with ThreadSanitizer (docs/tcb.md). Bounded model checking, not a
 * proof for all sizes. */
/* tools/verify_platform.sh passes -DL0_SRC to a copy of orin_platform.c whose handle tables are shrunk from 65,536 / 262,144
 * records to 8 (a sed of the one `enum { THR_MAX, MON_MAX }` line): the 2^18-entry tables alone exhaust the solver's memory,
 * and the validation logic (index < high-water mark, generation equality, liveness flag, free list) does not depend on the
 * table size. Without -DL0_SRC the real file is included (the table-size dependent harnesses are then not run). */
#ifndef L0_SRC
#define L0_SRC "../orin_platform.c"
#endif
/* path_absolute keeps two PATH_MAX buffers on the stack: bound PATH_MAX for the model */
#include <limits.h>
#undef PATH_MAX
#define PATH_MAX 16
#include L0_SRC

#include <assert.h>

/* ---- stubs ---------------------------------------------------------------------------------------------------- */
static int g_clock_rc;
static struct timespec g_clock_ts;
int clock_gettime(clockid_t id, struct timespec *ts) {
    (void)id;
    *ts = g_clock_ts;
    return g_clock_rc;
}
static const char *g_env;
char *getenv(const char *name) {
    (void)name;
    return (char *)g_env;
}
static const char *g_cwd;
char *getcwd(char *buf, size_t n) {
    size_t l = 0;
    if (!g_cwd) return NULL;
    while (g_cwd[l]) l++;
    if (l + 1 > n) return NULL;
    for (size_t i = 0; i <= l; i++) buf[i] = g_cwd[i];
    return buf;
}
/* threads run nothing: the create stub only succeeds or fails, the join stub returns at once */
int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
    (void)t, (void)a, (void)fn, (void)arg;
    int r;
    __CPROVER_assume(r == 0 || r == 11);
    return r;
}
int pthread_join(pthread_t t, void **ret) {
    (void)t, (void)ret;
    return 0;
}

/* snprintf model for the only call the layer makes with a float ("%.*e"): C99 7.21.6.5 -- writes min(len, cap-1) chars and a
 * NUL when cap > 0, len being the length of the full rendering. For a finite double and prec <= 17 that is at most
 * sign + digit + '.' + 17 digits + 'e' + sign + 3 exponent digits = 25. The harness asserts that bound is what the
 * stub is given (the `cap >= 32` precondition is therefore sufficient, no truncation) and checks memory safety. */
#include <stdarg.h>
static size_t g_snprintf_cap;
int snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int prec = va_arg(ap, int);
    double x = va_arg(ap, double);
    va_end(ap);
    (void)x;
    assert(fmt[0] == '%' && fmt[1] == '.' && fmt[2] == '*' && fmt[3] == 'e' && fmt[4] == 0);
    g_snprintf_cap = cap;
    int len;
    __CPROVER_assume(len >= prec + 5 && len <= prec + 8 + (prec ? 0 : -1));
    __CPROVER_assume(len <= 25);
    if (cap) {
        size_t w = (size_t)len < cap - 1 ? (size_t)len : cap - 1;
        for (size_t i = 0; i < w; i++) buf[i] = 'x';
        buf[w] = 0;
    }
    return len;
}

/* ---- double_to_exp: contract "buf holds the NUL-terminated %.*e rendering" (here: memory safety and NUL termination
 *      against the CBMC model of snprintf; the textual correctness is libc's and covered by platform_test.c) */
void harness_double_to_exp(void) {
    char buf[32];
    int prec;
    double x;
    __CPROVER_assume(prec >= 0 && prec <= 17);
    __CPROVER_assume(x == x && x - x == 0); /* finite */
    orin_platform_double_to_exp(buf, sizeof buf, prec, x);
    size_t n = 0;
    while (n < sizeof buf && buf[n]) n++;
    assert(g_snprintf_cap == sizeof buf);
    assert(n < sizeof buf); /* NUL-terminated inside the buffer: cap >= 32 suffices for prec <= 17 */
}

/* ---- parse_double: the f32 result is exactly a float value (rounded to float first); memory safe on any string */
void harness_parse_double(void) {
    char s[6];
    int f32;
    size_t n;
    __CPROVER_assume(n < sizeof s);
    s[n] = 0;
    for (size_t i = 0; i < n; i++) __CPROVER_assume(s[i] != 0);
    double d = orin_platform_parse_double(s, f32);
    if (f32 && d == d) assert((double)(float)d == d);
}

/* ---- now_millis: sec * 1000 + nsec / 10^6 exactly, for the representable range of a wall clock.
 *      Precondition found by the overflow check: |tv_sec| < 2^53 (year ~285,000,000), far beyond any real clock;
 *      the contract does not state it (see report: header comment candidate). */
void harness_now_millis(void) {
    g_clock_rc = 0;
    __CPROVER_assume(g_clock_ts.tv_nsec >= 0 && g_clock_ts.tv_nsec < 1000000000L);
    __CPROVER_assume(g_clock_ts.tv_sec > -((int64_t)1 << 53) && g_clock_ts.tv_sec < ((int64_t)1 << 53));
    int64_t r = orin_platform_now_millis();
    assert(r == (int64_t)g_clock_ts.tv_sec * 1000 + g_clock_ts.tv_nsec / 1000000);
    /* the fraction of the second is in [0, 999] ms */
    int64_t frac = r - (int64_t)g_clock_ts.tv_sec * 1000;
    assert(frac >= 0 && frac <= 999);
}

/* ---- monotonic_millis: -1 on clock failure / invalid timespec / overflow, else the exact conversion, never
 *      negative. Fully nondeterministic timespec (no range assumption). */
void harness_monotonic_millis(void) {
    int64_t a;
    int rc;
    struct timespec t1;
    g_clock_rc = rc;
    g_clock_ts.tv_sec = t1.tv_sec;
    g_clock_ts.tv_nsec = t1.tv_nsec;
    a = orin_platform_monotonic_millis();
    assert(a == -1 || a >= 0);
    if (rc != 0 || t1.tv_sec < 0 || t1.tv_nsec < 0 || t1.tv_nsec >= 1000000000L) assert(a == -1);
    if (a >= 0) {
        assert(rc == 0);
        assert(a == (int64_t)t1.tv_sec * 1000 + t1.tv_nsec / 1000000);
    }
    /* concrete boundary: INT64_MAX ms is representable, one more is refused */
    g_clock_rc = 0;
    g_clock_ts.tv_sec = INT64_MAX / 1000;
    g_clock_ts.tv_nsec = (INT64_MAX % 1000) * 1000000L;
    assert(orin_platform_monotonic_millis() == INT64_MAX);
    g_clock_ts.tv_nsec += 1000000L;
    assert(orin_platform_monotonic_millis() == -1);
}

/* ---- error_message / cpu_count / argument access */
void harness_error_message(void) {
    int code;
    const char *m = orin_platform_error_message(code);
    assert(m != NULL); /* contract: never NULL */
}

void harness_args(void) {
    char *argv[3];
    int argc, i;
    __CPROVER_assume(argc >= 0 && argc <= 3);
    orin_platform_init(argc, argv);
    assert(orin_platform_arg_count() == argc);
    __CPROVER_assume(i >= 0 && i < argc);
    assert(orin_platform_arg(i) == argv[i]);
}

/* ---- policy_load: the ORIN_DENY text is parsed with the same strict grammar; unset == empty == no family denied */
void harness_policy_load(void) {
    char spec[6];
    size_t n;
    int set;
    __CPROVER_assume(n < sizeof spec);
    spec[n] = 0;
    for (size_t i = 0; i < n; i++) __CPROVER_assume(spec[i] != 0);
    g_env = set ? spec : NULL;
    unsigned mask = 0xdeadbeef;
    int r = orin_platform_policy_load(&mask);
    assert(r == 0 || r == ORIN_PLATFORM_EINVAL);
    assert((mask & ~31u) == 0);
    if (!set || n == 0) assert(r == 0 && mask == 0);
    if (r == ORIN_PLATFORM_EINVAL) assert(mask == 0);
    unsigned m2 = 1;
    int r2 = set ? orin_platform_policy_parse(spec, n, &m2) : 0;
    if (set) assert(r == r2 && mask == m2);
}

/* ---- path_absolute: an absolute input is normalised directly; a relative one is joined with the cwd first; the result
 *      is canonical (starts with '/', no '.', '..', '//' components) or -1; getcwd failure gives -1; no overrun */
void harness_path_absolute(void) {
    char cwd[3], p[2], o[8];
    size_t cn, n;
    int has_cwd;
    __CPROVER_assume(cn >= 1 && cn <= 2 && n <= 2);
    cwd[0] = '/';
    for (size_t i = 1; i < cn; i++) {
        unsigned char c;
        __CPROVER_assume(c == 'a' || c == '.' || c == '/');
        cwd[i] = (char)c;
    }
    cwd[cn] = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c;
        __CPROVER_assume(c == 'a' || c == '.' || c == '/');
        p[i] = (char)c;
    }
    g_cwd = has_cwd ? cwd : NULL;
    int64_t r = orin_platform_path_absolute(p, n, o, sizeof o);
    if (n == 0) {
        assert(r == -1);
        return;
    }
    if (p[0] != '/' && !has_cwd) {
        assert(r == -1);
        return;
    }
    if (r >= 0) {
        assert(r >= 1 && (size_t)r < sizeof o);
        assert(o[0] == '/' && o[r] == 0);
        for (int64_t i = 0; i + 1 < r; i++) assert(!(o[i] == '/' && o[i + 1] == '/'));
        if (r > 1) assert(o[r - 1] != '/');
    }
    if (p[0] == '/' && r >= 0) { /* identical to normalize on the same text */
        char o2[8];
        assert(orin_platform_path_normalize(p, n, o2, sizeof o2) == r);
        for (int64_t i = 0; i <= r; i++) assert(o[i] == o2[i]);
    }
}

/* ---- handle validation, monitors: a bounded STATE MACHINE. Reference model: for each handle ever issued, whether it is
 *      live and whether the (single) calling thread holds it. Steps: new / free / lock / unlock / get / set on an issued
 *      or a forged handle. Checked at every step: a live handle is accepted (state-appropriate result), a freed (stale)
 *      handle and a forged handle are ALWAYS refused with ORIN_PLATFORM_EINVAL and change nothing; handles are positive and
 *      never reused while live (a recycled slot gets a new generation); the tables are never read out of bounds. */
enum { STEPS = 5, MW = 2 };

void harness_monitor_state_machine(void) {
    int64_t hs[STEPS];
    int live[STEPS], held[STEPS];
    unsigned issued = 0;
    for (int step = 0; step < STEPS; step++) {
        int op;
        __CPROVER_assume(op >= 0 && op <= 5);
        if (op == 0 || issued == 0) { /* new */
            int64_t h = orin_platform_monitor_new(MW);
            if (h == 0) continue; /* resource refusal */
            assert(h > 0);
            for (unsigned k = 0; k < issued; k++) assert(!live[k] || hs[k] != h); /* unique among live handles */
            hs[issued] = h, live[issued] = 1, held[issued] = 0;
            issued++;
            continue;
        }
        unsigned k;
        int forged;
        int64_t h, f;
        __CPROVER_assume(k < issued);
        h = forged ? f : hs[k];
        if (forged) { /* a forged handle: any value that is not a live issued handle */
            for (unsigned j = 0; j < issued; j++) __CPROVER_assume(!live[j] || hs[j] != h);
            k = issued; /* no reference record */
        }
        int known_live = !forged && live[k];
        uint64_t out = 7;
        int r;
        switch (op) {
        case 1: /* free */
            r = orin_platform_monitor_free(h);
            if (!known_live) assert(r == ORIN_PLATFORM_EINVAL);
            else if (held[k]) assert(r == ORIN_PLATFORM_EBUSY);
            else {
                assert(r == 0);
                live[k] = 0;
            }
            break;
        case 2: /* lock */
            r = orin_platform_monitor_lock(h);
            if (!known_live) assert(r == ORIN_PLATFORM_EINVAL);
            else if (held[k]) assert(r == ORIN_PLATFORM_EDEADLK);
            else {
                assert(r == 0);
                held[k] = 1;
            }
            break;
        case 3: /* unlock */
            r = orin_platform_monitor_unlock(h);
            if (!known_live || !held[k]) assert(r == ORIN_PLATFORM_EINVAL);
            else {
                assert(r == 0);
                held[k] = 0;
            }
            break;
        case 4: /* get */
            r = orin_platform_monitor_get(h, 0, &out);
            if (!known_live || !held[k]) {
                assert(r == ORIN_PLATFORM_EINVAL && out == 7);
            } else assert(r == 0);
            break;
        case 5: /* set then get round trip, index bound */
            r = orin_platform_monitor_set(h, MW, 1); /* index == n: out of range, always refused */
            assert(r == ORIN_PLATFORM_EINVAL);
            r = orin_platform_monitor_set(h, MW - 1, 42);
            if (!known_live || !held[k]) assert(r == ORIN_PLATFORM_EINVAL);
            else {
                assert(r == 0);
                assert(orin_platform_monitor_get(h, MW - 1, &out) == 0 && out == 42);
            }
            break;
        default:
            break;
        }
    }
    /* the handle 0 and negative handles are never valid */
    int64_t neg;
    __CPROVER_assume(neg <= 0);
    assert(orin_platform_monitor_lock(0) == ORIN_PLATFORM_EINVAL);
    assert(orin_platform_monitor_free(neg) == ORIN_PLATFORM_EINVAL);
}

/* a recycled slot gets a NEW generation: the handle of a freed monitor stays refused after the slot is reused */
void harness_monitor_generation(void) {
    int64_t a = orin_platform_monitor_new(1);
    if (!a) return;
    assert(orin_platform_monitor_free(a) == 0);
    assert(orin_platform_monitor_lock(a) == ORIN_PLATFORM_EINVAL);
    assert(orin_platform_monitor_free(a) == ORIN_PLATFORM_EINVAL); /* double free refused */
    int64_t b = orin_platform_monitor_new(1);
    if (!b) return;
    assert(b != a);
    /* the same slot may be reused ... */
    assert(orin_platform_monitor_lock(a) == ORIN_PLATFORM_EINVAL); /* ... the old handle still is not */
    assert(orin_platform_monitor_lock(b) == 0);
    assert(orin_platform_monitor_free(b) == ORIN_PLATFORM_EBUSY); /* locked: nothing happens */
    assert(orin_platform_monitor_unlock(b) == 0);
    assert(orin_platform_monitor_free(b) == 0);
}

/* grow: monotone, new words zero, old kept; shrinking refused */
void harness_monitor_grow(void) {
    int64_t h = orin_platform_monitor_new(2);
    if (!h) return;
    assert(orin_platform_monitor_lock(h) == 0);
    assert(orin_platform_monitor_set(h, 1, 9) == 0);
    size_t to;
    __CPROVER_assume(to <= 4);
    int r = orin_platform_monitor_grow(h, to);
    uint64_t v = 1;
    if (to < 2) assert(r == ORIN_PLATFORM_EINVAL);
    else if (r == 0) {
        assert(orin_platform_monitor_get(h, 1, &v) == 0 && v == 9);
        for (size_t i = 2; i < to; i++) assert(orin_platform_monitor_get(h, i, &v) == 0 && v == 0);
        assert(orin_platform_monitor_get(h, to, &v) == ORIN_PLATFORM_EINVAL);
    } else assert(r == ORIN_PLATFORM_ENOMEM);
}

/* ---- handle validation, threads: create -> join accepts exactly once; a joined, forged or foreign handle, a handle
 *      whose generation does not match, and a record that is being joined are refused with ORIN_PLATFORM_EINVAL. */
static void noop(void *p) { (void)p; }

void harness_thread_handles(void) {
    void *arg = NULL;
    int64_t forged;
    /* nothing created yet: every handle is refused, and no table read goes out of bounds */
    assert(orin_platform_thread_join(0, &arg) == ORIN_PLATFORM_EINVAL);
    assert(orin_platform_thread_join(forged, &arg) == ORIN_PLATFORM_EINVAL);

    int marker;
    int64_t a = orin_platform_thread_create(noop, &marker);
    if (a == 0) return; /* refused by resources / the (stubbed) OS: nothing to clean */
    assert(a > 0);
    /* a neighbour with the wrong generation, or the same generation in an unissued slot, is refused */
    int64_t wrong_gen = (int64_t)((uint64_t)a ^ ((uint64_t)1 << 32));
    assert(orin_platform_thread_join(wrong_gen, &arg) == ORIN_PLATFORM_EINVAL);
    int64_t unissued = (int64_t)(((uint64_t)a & 0xffffffff00000000ull) | (((uint64_t)a & 0xffffffffu) + 1));
    assert(orin_platform_thread_join(unissued, &arg) == ORIN_PLATFORM_EINVAL);
    /* being joined by another thread (state 2): refused, nothing happens */
    Thr *t = g_thr[(uint32_t)((uint64_t)a & 0xffffffffu) - 1u];
    t->state = 2;
    assert(orin_platform_thread_join(a, &arg) == ORIN_PLATFORM_EINVAL);
    t->state = 1;
    /* the first join succeeds and returns the argument, the second is refused (joined twice) */
    assert(orin_platform_thread_join(a, &arg) == 0);
    assert(arg == &marker);
    assert(orin_platform_thread_join(a, &arg) == ORIN_PLATFORM_EINVAL);
    /* the record is recycled with a new generation: the old handle stays dead, the new one works once */
    int64_t b = orin_platform_thread_create(noop, &marker);
    if (b == 0) return;
    assert(b != a);
    assert(orin_platform_thread_join(a, &arg) == ORIN_PLATFORM_EINVAL);
    assert(orin_platform_thread_join(b, &arg) == 0);
    assert(orin_platform_thread_join(b, &arg) == ORIN_PLATFORM_EINVAL);
}
