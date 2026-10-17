/* Orin L0 platform layer for WebAssembly under the Orbit host ABI v1 (ADR-0055). Contracts: ../orin_platform.h.
 *
 * Target: wasm32, compiled by clang --target=wasm32-wasip1 -mexec-model=reactor against wasi-libc, but the linked module
 * imports NO WASI function: libc is used only for its pure parts (malloc, string, snprintf/strtod). Every privileged
 * operation goes through an `orbit:<capability>/v1` import (orbit docs/host-abi.md); pointers and lengths are passed as
 * zero-extended i64. A capability the program never reaches is not imported (wasm-ld drops dead imports), so the module's
 * import list is exactly what it may ask the host for, and the host's grant decides (deny by default).
 *
 * Differences from the native layer, all fail closed:
 *   stdout / stderr   orbit:log/v1 write, one record per line (stdout = info, stderr = error), partial lines on flush;
 *   clock             orbit:clock/v1 (the host may coarsen it);
 *   args / env        one argument "main", no environment; ORIN_DENY does not exist (the host grant is the policy);
 *   files, processes, network
 *                     not available: every call returns ORIN_PLATFORM_EPERM (or -1 where the contract has no code);
 *   threads           none: a task runs to completion inside orin_platform_thread_create; a monitor wait that no other
 *                     task could ever notify traps instead of deadlocking;
 *   exit              flushes, records the status (export orin_exit_status) and traps: WebAssembly has no unwinding here.
 * Entry point: the export `orin_main` runs the program's main and returns its exit status. */
#include "../orin_platform.h"

#include "../orin_platform_pure.h"

#define ORBIT_IMPORT(m, n) __attribute__((import_module(m), import_name(n)))
ORBIT_IMPORT("orbit:log/v1", "write") int32_t orbit_log_write(int32_t level, int64_t ptr, int64_t len);
ORBIT_IMPORT("orbit:clock/v1", "now_unix_nanos") int64_t orbit_clock_now_unix_nanos(void);
ORBIT_IMPORT("orbit:clock/v1", "monotonic_nanos") int64_t orbit_clock_monotonic_nanos(void);

enum { LOG_INFO = 2, LOG_ERROR = 4, LOG_MAX = 16384 };

/* ---------------------------------------------------------------- process */

static char *g_argv0[] = {"main", NULL};
static int g_argc;
static char **g_argv;
static void (*g_exit_fns[32])(void);
static int g_nexit;
static int32_t g_exit_status = -1; /* -1 until main returned or exit was called */
__attribute__((export_name("orin_exit_status"))) int32_t orin_exit_status(void) { return g_exit_status; }

void orin_platform_init(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}
int orin_platform_arg_count(void) { return g_argc; }
const char *orin_platform_arg(int i) { return g_argv[i]; }
const char *orin_platform_getenv(const char *name) {
    (void)name;
    return NULL;
}
int orin_platform_at_exit(void (*fn)(void)) {
    if (g_nexit == 32) return -1;
    g_exit_fns[g_nexit++] = fn;
    return 0;
}
static void run_at_exit(void) {
    while (g_nexit > 0) g_exit_fns[--g_nexit]();
}

void orin_platform_exit(int code) {
    run_at_exit();
    orin_platform_flush();
    g_exit_status = code & 0xff;
    __builtin_trap();
}
void orin_platform_abort(void) { __builtin_trap(); }

int64_t orin_platform_shell(const char *cmd, size_t n) {
    (void)cmd, (void)n;
    orin_platform_flush();
    return -1;
}
int64_t orin_platform_shell_timeout(const char *cmd, size_t n, int64_t seconds) {
    (void)seconds;
    return orin_platform_shell(cmd, n);
}

int main(int argc, char **argv); /* emitted by the compiler */

__attribute__((export_name("orin_main"))) int32_t orin_main(void) {
    g_exit_status = main(1, g_argv0);
    run_at_exit();
    orin_platform_flush();
    return g_exit_status;
}

/* ---------------------------------------------------------------- clocks */

int64_t orin_platform_now_millis(void) { return orbit_clock_now_unix_nanos() / 1000000; }
int64_t orin_platform_monotonic_millis(void) {
    int64_t ns = orbit_clock_monotonic_nanos();
    return ns < 0 ? -1 : ns / 1000000;
}

/* ---------------------------------------------------------------- floating point text */

void orin_orbit_fmt_exp(char *buf, size_t cap, int prec, double x); /* orin_libc_orbit.c */
double orin_orbit_parse_float(const char *s, int is_f32);
void orin_platform_double_to_exp(char *buf, size_t cap, int prec, double x) { orin_orbit_fmt_exp(buf, cap, prec, x); }
double orin_platform_parse_double(const char *s, int is_f32) { return orin_orbit_parse_float(s, is_f32); }

/* ---------------------------------------------------------------- byte I/O: one log record per line */

typedef struct {
    size_t n;
    char b[LOG_MAX];
} LineBuf;
static LineBuf g_out, g_err;

static void line_emit(LineBuf *lb, int level) {
    if (lb->n) orbit_log_write(level, (int64_t)(uintptr_t)lb->b, (int64_t)lb->n);
    lb->n = 0;
}

static void line_put(LineBuf *lb, int level, const char *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (p[i] == '\n') {
            orbit_log_write(level, (int64_t)(uintptr_t)lb->b, (int64_t)lb->n); /* an empty line is still a record */
            lb->n = 0;
            continue;
        }
        if (lb->n == LOG_MAX) line_emit(lb, level);
        lb->b[lb->n++] = p[i];
    }
}

static void write_bytes(int stream, const char *p, size_t n, int newline) {
    if (stream == ORIN_PLATFORM_STDOUT) {
        line_put(&g_out, LOG_INFO, p, n);
        if (newline) line_put(&g_out, LOG_INFO, "\n", 1);
    } else {
        line_emit(&g_out, LOG_INFO);
        line_put(&g_err, LOG_ERROR, p, n);
        if (newline) line_put(&g_err, LOG_ERROR, "\n", 1);
        line_emit(&g_err, LOG_ERROR);
    }
}
void orin_platform_write(int stream, const char *p, size_t n) { write_bytes(stream, p, n, 0); }
void orin_platform_write_line(int stream, const char *p, size_t n) { write_bytes(stream, p, n, 1); }
void orin_platform_flush(void) { line_emit(&g_out, LOG_INFO); }

size_t orin_platform_stdin_read(char *buf, size_t n) {
    (void)buf, (void)n;
    return 0;
}
int orin_platform_stdin_getc(void) { return -1; }

/* ---------------------------------------------------------------- files: not available */

const char *orin_platform_error_message(int code) {
    if (code == 0) return "Success";
    if (code == ORIN_PLATFORM_EPERM) return "Operation not permitted (not available under Orbit)";
    if (code == ORIN_PLATFORM_EINVAL) return "Invalid argument";
    if (code == ORIN_PLATFORM_ENOMEM) return "Out of memory";
    if (code == ORIN_PLATFORM_EBUSY) return "Device or resource busy";
    return "Unknown error";
}

int orin_platform_file_read(const char *path, size_t plen, char **out, size_t *out_len) {
    (void)path, (void)plen;
    *out = NULL;
    *out_len = 0;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_file_write(const char *path, size_t plen, const char *data, size_t dlen) {
    (void)path, (void)plen, (void)data, (void)dlen;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_file_exists(const char *path, size_t plen) {
    (void)path, (void)plen;
    return 0;
}
int orin_platform_dir_list(const char *path, size_t plen, void (*each)(void *, const char *, size_t, int), void *ctx) {
    (void)path, (void)plen, (void)each, (void)ctx;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_stream_open(const char *path, size_t plen, int mode, orin_platform_stream **out) {
    (void)path, (void)plen;
    *out = NULL;
    return mode < 0 || mode > 2 ? ORIN_PLATFORM_EINVAL : ORIN_PLATFORM_EPERM;
}
/* No stream can be opened, so the functions below are never reached with a valid stream. */
size_t orin_platform_stream_read(orin_platform_stream *s, char *buf, size_t n) {
    (void)s, (void)buf, (void)n;
    return 0;
}
int orin_platform_stream_getc(orin_platform_stream *s) {
    (void)s;
    return -1;
}
size_t orin_platform_stream_write(orin_platform_stream *s, const char *p, size_t n) {
    (void)s, (void)p, (void)n;
    return 0;
}
int orin_platform_stream_flush(orin_platform_stream *s) {
    (void)s;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_stream_error(const orin_platform_stream *s) {
    (void)s;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_stream_close(orin_platform_stream *s) {
    (void)s;
    return ORIN_PLATFORM_EPERM;
}

/* ---------------------------------------------------------------- host policy and paths */

int orin_platform_policy_load(unsigned *mask) { /* the host grant is the policy: nothing is denied on top of it */
    *mask = 0;
    return 0;
}
int64_t orin_platform_path_absolute(const char *path, size_t plen, char *out, size_t cap) {
    if (plen == 0) return -1;
    if (path[0] == '/') return orin_platform_path_normalize(path, plen, out, cap);
    char *tmp = (char *)orin_platform_alloc(plen + 1); /* the working directory is "/" */
    if (!tmp) return -1;
    tmp[0] = '/';
    orin_platform_mem_copy(tmp + 1, path, plen);
    int64_t r = orin_platform_path_normalize(tmp, plen + 1, out, cap);
    orin_platform_free(tmp);
    return r;
}
int64_t orin_platform_path_real(const char *abs, size_t alen, char *out, size_t cap) { /* no file system, no links */
    if (alen == 0 || alen + 1 > cap) return -1;
    orin_platform_mem_copy(out, abs, alen);
    out[alen] = 0;
    return (int64_t)alen;
}

/* ---------------------------------------------------------------- threads and monitors: one thread */

uint64_t orin_platform_thread_id(void) { return 1; }
uint64_t orin_platform_cpu_count(void) { return 1; }

enum { THR_MAX = 1 << 12, MON_MAX = 1 << 14 };
typedef struct {
    void *arg;
    uint32_t gen;
    int live;
} Thr;
static Thr g_thr[THR_MAX];
static uint32_t g_thr_hi, g_thr_free[THR_MAX], g_thr_nfree;

static int64_t slot_handle(uint32_t gen, uint32_t i) { return (int64_t)(((uint64_t)gen << 32) | (uint64_t)(i + 1)); }
static uint32_t slot_index(int64_t h) { return (uint32_t)((uint64_t)h & 0xffffffffu) - 1u; }
static uint32_t slot_gen(int64_t h) { return (uint32_t)((uint64_t)h >> 32); }

int64_t orin_platform_thread_create(void (*entry)(void *), void *arg) {
    uint32_t i;
    if (g_thr_nfree) i = g_thr_free[--g_thr_nfree];
    else if (g_thr_hi < THR_MAX) i = g_thr_hi++;
    else return 0;
    Thr *t = &g_thr[i];
    t->gen++;
    t->arg = arg;
    t->live = 1;
    entry(arg); /* runs to completion: there is no second thread */
    return slot_handle(t->gen, i);
}
int orin_platform_thread_join(int64_t h, void **arg) {
    uint32_t i = slot_index(h);
    if (h <= 0 || i >= g_thr_hi || !g_thr[i].live || g_thr[i].gen != slot_gen(h)) return ORIN_PLATFORM_EINVAL;
    *arg = g_thr[i].arg;
    g_thr[i].live = 0;
    g_thr_free[g_thr_nfree++] = i;
    return 0;
}
void orin_platform_thread_exit(void) { __builtin_trap(); } /* a trapping task cannot be unwound: the instance traps */

typedef struct {
    uint64_t *w;
    size_t n;
    uint32_t gen;
    int live, locked;
} Mon;
static Mon g_mon[MON_MAX];
static uint32_t g_mon_hi, g_mon_free[MON_MAX], g_mon_nfree;

static Mon *mon_ref(int64_t h) {
    uint32_t i = slot_index(h);
    return h > 0 && i < g_mon_hi && g_mon[i].live && g_mon[i].gen == slot_gen(h) ? &g_mon[i] : NULL;
}

int64_t orin_platform_monitor_new(size_t nwords) {
    uint64_t *w = (uint64_t *)orin_platform_alloc(nwords * sizeof(uint64_t));
    if (!w) return 0;
    orin_platform_mem_set(w, 0, nwords * sizeof(uint64_t));
    uint32_t i;
    if (g_mon_nfree) i = g_mon_free[--g_mon_nfree];
    else if (g_mon_hi < MON_MAX) i = g_mon_hi++;
    else {
        orin_platform_free(w);
        return 0;
    }
    Mon *m = &g_mon[i];
    m->gen++;
    m->w = w, m->n = nwords, m->live = 1, m->locked = 0;
    return slot_handle(m->gen, i);
}
int orin_platform_monitor_free(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m) return ORIN_PLATFORM_EINVAL;
    if (m->locked) return ORIN_PLATFORM_EBUSY;
    orin_platform_free(m->w);
    m->w = NULL, m->live = 0;
    g_mon_free[g_mon_nfree++] = (uint32_t)(m - g_mon);
    return 0;
}
int orin_platform_monitor_lock(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m) return ORIN_PLATFORM_EINVAL;
    if (m->locked) return ORIN_PLATFORM_EDEADLK;
    m->locked = 1;
    return 0;
}
int orin_platform_monitor_unlock(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked) return ORIN_PLATFORM_EINVAL;
    m->locked = 0;
    return 0;
}
static void deadlock(void) {
    static const char msg[] = "deadlock: a task waits for a notification, but WebAssembly under Orbit runs one task at a time";
    orin_platform_write_line(ORIN_PLATFORM_STDERR, msg, sizeof msg - 1);
    __builtin_trap();
}
int orin_platform_monitor_wait(int64_t h, int cond) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked || (cond != 0 && cond != 1)) return ORIN_PLATFORM_EINVAL;
    deadlock(); /* the caller holds the only thread: nobody can notify */
    return 0;
}
int orin_platform_monitor_wait_until(int64_t h, int cond, int64_t deadline_ms) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked || (cond != 0 && cond != 1) || deadline_ms < 0) return ORIN_PLATFORM_EINVAL;
    return ORIN_PLATFORM_WAIT_TIMEOUT; /* nobody can notify, so the wait ends at the deadline; returning early is allowed
                                           only by notification, so the caller sees the timeout and re-checks */
}
int orin_platform_monitor_notify(int64_t h, int cond, int all) {
    (void)all;
    Mon *m = mon_ref(h);
    return !m || !m->locked || (cond != 0 && cond != 1) ? ORIN_PLATFORM_EINVAL : 0;
}
int orin_platform_monitor_get(int64_t h, size_t i, uint64_t *out) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked || i >= m->n) return ORIN_PLATFORM_EINVAL;
    *out = m->w[i];
    return 0;
}
int orin_platform_monitor_set(int64_t h, size_t i, uint64_t v) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked || i >= m->n) return ORIN_PLATFORM_EINVAL;
    m->w[i] = v;
    return 0;
}
int orin_platform_monitor_grow(int64_t h, size_t nwords) {
    Mon *m = mon_ref(h);
    if (!m || !m->locked || nwords < m->n) return ORIN_PLATFORM_EINVAL;
    uint64_t *w = (uint64_t *)orin_platform_realloc(m->w, nwords * sizeof(uint64_t));
    if (!w) return ORIN_PLATFORM_ENOMEM;
    orin_platform_mem_set(w + m->n, 0, (nwords - m->n) * sizeof(uint64_t));
    m->w = w, m->n = nwords;
    return 0;
}
void orin_platform_runtime_lock(void) {}
void orin_platform_runtime_unlock(void) {}

/* ---------------------------------------------------------------- network: not available */

int orin_platform_net_narrow(const orin_platform_net *p, unsigned what, const char *h, size_t hl, int lo, int hi,
                             orin_platform_net *out) {
    (void)p, (void)what, (void)h, (void)hl, (void)lo, (void)hi, (void)out;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_tcp_listen(const orin_platform_net *g, const char *a, size_t al, int port, int backlog, int opt,
                             orin_platform_net *out, int *out_port) {
    (void)g, (void)a, (void)al, (void)port, (void)backlog, (void)opt, (void)out, (void)out_port;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_tcp_accept(const orin_platform_net *l, int timeout_ms, int opt, orin_platform_net *out, char *peer,
                             size_t pcap, int *peer_port) {
    (void)l, (void)timeout_ms, (void)opt, (void)out, (void)peer, (void)pcap, (void)peer_port;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_tcp_connect(const orin_platform_net *g, const char *h, size_t hl, int port, int timeout_ms, int opt,
                              orin_platform_net *out) {
    (void)g, (void)h, (void)hl, (void)port, (void)timeout_ms, (void)opt, (void)out;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_stream_recv(const orin_platform_net *s, char *buf, size_t cap, int timeout_ms, size_t *out_len) {
    (void)s, (void)buf, (void)cap, (void)timeout_ms;
    *out_len = 0;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_stream_send(const orin_platform_net *s, const char *data, size_t len, int timeout_ms, size_t *out_sent) {
    (void)s, (void)data, (void)len, (void)timeout_ms;
    *out_sent = 0;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_net_shutdown(const orin_platform_net *s, int how) {
    (void)s, (void)how;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_net_close(orin_platform_net *h) {
    (void)h;
    return ORIN_PLATFORM_EPERM;
}
int orin_platform_dns_resolve(const orin_platform_net *g, const char *name, size_t nlen, char *out, size_t cap,
                              size_t *out_len) {
    (void)g, (void)name, (void)nlen, (void)out, (void)cap;
    *out_len = 0;
    return ORIN_PLATFORM_EPERM;
}

/* ---------------------------------------------------------------- wake sources: flags only (no wait can block) */

enum { WAKE_MAX = 1 << 12 };
typedef struct {
    int live, set, depth;
    uint32_t gen;
    int64_t parent;
} Wake;
static Wake g_wake[WAKE_MAX];
static uint32_t g_wake_hi, g_wake_free[WAKE_MAX], g_wake_nfree;
static int64_t g_wake_bound;

static Wake *wake_ref(int64_t h) {
    uint32_t i = slot_index(h);
    return h > 0 && i < g_wake_hi && g_wake[i].live && g_wake[i].gen == slot_gen(h) ? &g_wake[i] : NULL;
}
int64_t orin_platform_wake_open(void) {
    Wake *p = wake_ref(g_wake_bound);
    if (p && p->depth >= ORIN_PLATFORM_WAKE_DEPTH) return 0;
    uint32_t i;
    if (g_wake_nfree) i = g_wake_free[--g_wake_nfree];
    else if (g_wake_hi < WAKE_MAX) i = g_wake_hi++;
    else return 0;
    Wake *w = &g_wake[i];
    w->gen++;
    w->live = 1, w->set = 0, w->depth = p ? p->depth + 1 : 0, w->parent = p ? g_wake_bound : 0;
    return g_wake_bound = slot_handle(w->gen, i);
}
int64_t orin_platform_wake_close(int64_t h) {
    Wake *w = wake_ref(h);
    if (!w) return ORIN_PLATFORM_EINVAL;
    if (g_wake_bound == h) g_wake_bound = w->parent;
    w->live = 0;
    g_wake_free[g_wake_nfree++] = (uint32_t)(w - g_wake);
    return 0;
}
int64_t orin_platform_wake_signal(int64_t h) {
    Wake *w = wake_ref(h);
    if (!w || w->set) return 0;
    w->set = 1;
    return 1;
}
int64_t orin_platform_wake_check(int64_t h) {
    Wake *w = wake_ref(h);
    if (!w) return 2;
    for (; w; w = wake_ref(w->parent))
        if (w->set) return 1;
    return 0;
}
int64_t orin_platform_wake_bind(int64_t h) {
    int64_t old = g_wake_bound;
    g_wake_bound = wake_ref(h) ? h : 0;
    return old;
}
int64_t orin_platform_wake_bound(void) { return g_wake_bound; }
