/* Orin L0 platform layer: implementation. Contracts: orin_platform.h. */
#include "orin_platform.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

_Static_assert(ORIN_PLATFORM_EINVAL == EINVAL, "EINVAL value");
_Static_assert(ORIN_PLATFORM_ENOMEM == ENOMEM, "ENOMEM value");
_Static_assert(ORIN_PLATFORM_EBUSY == EBUSY, "EBUSY value");

/* ---------------------------------------------------------------- memory */

const void *orin_platform_mem_find(const void *hay, size_t hn, const void *needle, size_t nn) {
    if (nn == 0) return hay;
    if (nn > hn) return NULL;
    const unsigned char *h = (const unsigned char *)hay, *n = (const unsigned char *)needle;
    /* plain loops (no libc), so that the function is fully covered by the CBMC harness */
    for (size_t i = 0; i <= hn - nn; i++) {
        size_t k = 0;
        while (k < nn && h[i + k] == n[k]) k++;
        if (k == nn) return h + i;
    }
    return NULL;
}

/* ---------------------------------------------------------------- formatting */

size_t orin_platform_fmt_u64(char *buf, uint64_t v) {
    char tmp[20];
    size_t k = 0;
    do {
        tmp[k++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    for (size_t i = 0; i < k; i++) buf[i] = tmp[k - 1 - i];
    return k;
}

size_t orin_platform_fmt_i64(char *buf, int64_t v) {
    if (v >= 0) return orin_platform_fmt_u64(buf, (uint64_t)v);
    buf[0] = '-';
    return 1 + orin_platform_fmt_u64(buf + 1, (uint64_t)(-(v + 1)) + 1); /* |v| without wrapping */
}

/* ---------------------------------------------------------------- process */

static int g_argc;
static char **g_argv;

void orin_platform_init(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
}
int orin_platform_arg_count(void) { return g_argc; }
const char *orin_platform_arg(int i) { return g_argv[i]; }
const char *orin_platform_getenv(const char *name) { return getenv(name); }
int orin_platform_at_exit(void (*fn)(void)) { return atexit(fn); }

void orin_platform_exit(int code) {
    orin_platform_flush();
    exit(code);
}
void orin_platform_abort(void) { abort(); }

int64_t orin_platform_shell(const char *cmd, size_t n) {
    orin_platform_flush();
    char *buf = (char *)orin_platform_alloc(n + 1);
    if (!buf) return -1;
    orin_platform_mem_copy(buf, cmd, n);
    buf[n] = 0;
    int r = system(buf);
    orin_platform_free(buf);
    if (r == -1) return -1;
    if (WIFEXITED(r)) return (int64_t)WEXITSTATUS(r);
    return -1;
}

int64_t orin_platform_now_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

/* ---------------------------------------------------------------- host policy and path scopes */

/* One policy element: exact family names, plain loops (no libc) so that CBMC covers the whole function. */
static unsigned policy_word(const char *w, size_t n) {
    static const char *const names[] = {"fs", "process", "stdio", "clock", "net", "all"};
    static const unsigned bits[] = {ORIN_PLATFORM_FAM_FS, ORIN_PLATFORM_FAM_PROCESS, ORIN_PLATFORM_FAM_STDIO,
                                    ORIN_PLATFORM_FAM_CLOCK, ORIN_PLATFORM_FAM_NET, 31u};
    for (size_t k = 0; k < 6; k++) {
        size_t i = 0;
        while (i < n && names[k][i] && w[i] == names[k][i]) i++;
        if (i == n && names[k][i] == 0) return bits[k];
    }
    return 0;
}

int orin_platform_policy_parse(const char *spec, size_t n, unsigned *mask) {
    *mask = 0;
    if (n == 0) return 0;
    unsigned m = 0;
    size_t start = 0;
    for (size_t i = 0; i <= n; i++) {
        if (i == n || spec[i] == ',') {
            unsigned b = policy_word(spec + start, i - start);
            if (b == 0) return ORIN_PLATFORM_EINVAL;
            m |= b;
            start = i + 1;
        }
    }
    *mask = m;
    return 0;
}

int orin_platform_policy_load(unsigned *mask) {
    const char *v = getenv("ORIN_DENY");
    if (!v) {
        *mask = 0;
        return 0;
    }
    return orin_platform_policy_parse(v, strlen(v), mask);
}

int64_t orin_platform_path_normalize(const char *path, size_t plen, char *out, size_t cap) {
    if (plen == 0 || path[0] != '/' || cap < plen + 1) return -1;
    for (size_t i = 0; i < plen; i++)
        if (path[i] == 0) return -1;
    size_t len = 1; /* out[0..len-1] is the result so far; always starts with '/' */
    out[0] = '/';
    size_t i = 0;
    while (i < plen) {
        while (i < plen && path[i] == '/') i++;
        size_t s = i;
        while (i < plen && path[i] != '/') i++;
        size_t n = i - s;
        if (n == 0 || (n == 1 && path[s] == '.')) continue;
        if (n == 2 && path[s] == '.' && path[s + 1] == '.') {
            while (len > 1 && out[len - 1] != '/') len--; /* drop the last component ... */
            if (len > 1) len--;                           /* ... and the '/' before it */
            continue;
        }
        if (len > 1) out[len++] = '/';
        for (size_t k = 0; k < n; k++) out[len++] = path[s + k];
    }
    out[len] = 0;
    return (int64_t)len;
}

int orin_platform_path_within(const char *scope, size_t slen, const char *path, size_t plen) {
    if (slen == 1) return 1; /* "/" contains every absolute path */
    if (plen < slen) return 0;
    for (size_t i = 0; i < slen; i++)
        if (scope[i] != path[i]) return 0;
    return plen == slen || path[slen] == '/';
}

int64_t orin_platform_path_absolute(const char *path, size_t plen, char *out, size_t cap) {
    if (plen == 0) return -1;
    if (path[0] == '/') return orin_platform_path_normalize(path, plen, out, cap);
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) return -1;
    size_t cl = strlen(cwd);
    char *tmp = (char *)orin_platform_alloc(cl + 1 + plen);
    if (!tmp) return -1;
    orin_platform_mem_copy(tmp, cwd, cl);
    tmp[cl] = '/';
    orin_platform_mem_copy(tmp + cl + 1, path, plen);
    int64_t r = orin_platform_path_normalize(tmp, cl + 1 + plen, out, cap);
    orin_platform_free(tmp);
    return r;
}

int64_t orin_platform_path_real(const char *abs, size_t alen, char *out, size_t cap) {
    if (alen == 0 || alen >= PATH_MAX) return -1;
    char pre[PATH_MAX], res[PATH_MAX];
    orin_platform_mem_copy(pre, abs, alen);
    pre[alen] = 0;
    size_t plen = alen; /* pre[0..plen-1] is the prefix still to be resolved; abs[plen..] the rest */
    for (;;) {
        if (realpath(pre, res)) break;
        int e = errno;
        struct stat st;
        if (lstat(pre, &st) == 0) return -1; /* exists but cannot be resolved: a dangling link or a loop */
        if (e != ENOENT && e != ENOTDIR) return -1;
        while (plen > 1 && pre[plen - 1] != '/') plen--; /* drop the last component */
        if (plen > 1) plen--;
        pre[plen] = 0;
    }
    /* the rest of abs starts at abs[plen], which is a '/' (or the end) -- except when only the root is left,
       where plen == 1 and the rest is abs[1..] without a leading '/' */
    size_t rl = strlen(res), from = plen, rest;
    if (plen == 1) {
        if (rl != 1) return -1; /* realpath("/") is "/" */
        from = 1;
        rest = alen - 1;
    } else {
        rest = alen - plen;
        if (rl == 1) rl = 0; /* the prefix resolved to "/": the rest brings its own '/' */
    }
    if (rl + rest + 1 > cap) return -1;
    orin_platform_mem_copy(out, res, rl);
    orin_platform_mem_copy(out + rl, abs + from, rest);
    out[rl + rest] = 0;
    return (int64_t)(rl + rest);
}

/* ---------------------------------------------------------------- floating point text */

void orin_platform_double_to_exp(char *buf, size_t cap, int prec, double x) {
    snprintf(buf, cap, "%.*e", prec, x);
}

double orin_platform_parse_double(const char *s, int is_f32) {
    return is_f32 ? (double)strtof(s, NULL) : strtod(s, NULL);
}

/* ---------------------------------------------------------------- byte I/O */

/* fwrite_unlocked is a glibc extension; plain fwrite elsewhere (macOS, musl). */
#if defined(__GLIBC__)
#define ORIN_FWRITE fwrite_unlocked
#define ORIN_PUTC putc_unlocked
#else
#define ORIN_FWRITE fwrite
#define ORIN_PUTC putc
#endif

/* One lock for the process-wide stdout buffer (and the stderr that must flush it first): tasks may print at the same time
 * (ADR-0017). Stdin needs none: getc / fread of stdio lock internally. */
static pthread_mutex_t g_io = PTHREAD_MUTEX_INITIALIZER;

void orin_platform_write(int stream, const char *p, size_t n) {
    pthread_mutex_lock(&g_io);
    if (stream == ORIN_PLATFORM_STDOUT) {
        if (n) ORIN_FWRITE(p, 1, n, stdout);
    } else {
        fflush(stdout);
        if (n) fwrite(p, 1, n, stderr);
        fflush(stderr);
    }
    pthread_mutex_unlock(&g_io);
}

void orin_platform_write_line(int stream, const char *p, size_t n) {
    pthread_mutex_lock(&g_io);
    if (stream == ORIN_PLATFORM_STDOUT) {
        if (n) ORIN_FWRITE(p, 1, n, stdout);
        ORIN_PUTC('\n', stdout);
    } else {
        fflush(stdout);
        if (n) fwrite(p, 1, n, stderr);
        fputc('\n', stderr);
        fflush(stderr);
    }
    pthread_mutex_unlock(&g_io);
}

void orin_platform_flush(void) {
    pthread_mutex_lock(&g_io);
    fflush(stdout);
    pthread_mutex_unlock(&g_io);
}

size_t orin_platform_stdin_read(char *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        size_t k = fread(buf + got, 1, n - got, stdin);
        if (k == 0) break;
        got += k;
    }
    return got;
}

int orin_platform_stdin_getc(void) {
    int c = getc(stdin);
    return c == EOF ? -1 : c;
}

/* ---------------------------------------------------------------- files */

const char *orin_platform_error_message(int code) { return strerror(code); }

/* NUL-terminated private copy of a (ptr, len) path; NULL with *err set on NUL byte / no memory. */
static char *path_copy(const char *path, size_t plen, int *err) {
    if (plen && memchr(path, 0, plen)) {
        *err = ORIN_PLATFORM_EINVAL;
        return NULL;
    }
    char *c = (char *)orin_platform_alloc(plen + 1);
    if (!c) {
        *err = ORIN_PLATFORM_ENOMEM;
        return NULL;
    }
    orin_platform_mem_copy(c, path, plen);
    c[plen] = 0;
    return c;
}

int orin_platform_file_read(const char *path, size_t plen, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    int err = 0;
    char *p = path_copy(path, plen, &err);
    if (!p) return err;
    errno = 0;
    FILE *f = fopen(p, "rb");
    orin_platform_free(p);
    if (!f) return errno ? errno : EIO;
    size_t cap = 4096, len = 0;
    char *buf = (char *)orin_platform_alloc(cap);
    if (!buf) {
        fclose(f);
        return ORIN_PLATFORM_ENOMEM;
    }
    for (;;) {
        if (len == cap) {
            char *nb = cap > SIZE_MAX / 2 ? NULL : (char *)orin_platform_realloc(buf, cap * 2);
            if (!nb) {
                orin_platform_free(buf);
                fclose(f);
                return ORIN_PLATFORM_ENOMEM;
            }
            buf = nb;
            cap *= 2;
        }
        size_t k = fread(buf + len, 1, cap - len, f);
        len += k;
        if (k == 0) break;
    }
    int bad = ferror(f);
    int saved = errno ? errno : EIO;
    fclose(f);
    if (bad) {
        orin_platform_free(buf);
        return saved;
    }
    *out = buf;
    *out_len = len;
    return 0;
}

int orin_platform_file_write(const char *path, size_t plen, const char *data, size_t dlen) {
    int err = 0;
    char *p = path_copy(path, plen, &err);
    if (!p) return err;
    errno = 0;
    FILE *f = fopen(p, "wb");
    orin_platform_free(p);
    if (!f) return errno ? errno : EIO;
    size_t k = dlen ? fwrite(data, 1, dlen, f) : 0;
    int werr = errno ? errno : EIO;
    errno = 0;
    int cerr = fclose(f) != 0 ? (errno ? errno : EIO) : 0; /* buffered data is flushed by fclose */
    if (k != dlen) return werr;
    return cerr;
}

int orin_platform_file_exists(const char *path, size_t plen) {
    int err = 0;
    char *p = path_copy(path, plen, &err);
    if (!p) return 0;
    struct stat st;
    int r = stat(p, &st) == 0;
    orin_platform_free(p);
    return r;
}

/* ---------------------------------------------------------------- file streams */

struct orin_platform_stream {
    FILE *f;
    int err; /* first error code, 0 = none (sticky) */
};

static void stream_fail(orin_platform_stream *s, int code) {
    if (s->err == 0) s->err = code ? code : EIO;
}

int orin_platform_stream_open(const char *path, size_t plen, int mode, orin_platform_stream **out) {
    *out = NULL;
    if (mode != ORIN_PLATFORM_STREAM_READ && mode != ORIN_PLATFORM_STREAM_WRITE && mode != ORIN_PLATFORM_STREAM_APPEND)
        return ORIN_PLATFORM_EINVAL;
    int err = 0;
    char *p = path_copy(path, plen, &err);
    if (!p) return err;
    orin_platform_stream *s = (orin_platform_stream *)orin_platform_alloc(sizeof *s);
    if (!s) {
        orin_platform_free(p);
        return ORIN_PLATFORM_ENOMEM;
    }
    errno = 0;
    s->f = fopen(p, mode == ORIN_PLATFORM_STREAM_READ ? "rb" : (mode == ORIN_PLATFORM_STREAM_WRITE ? "wb" : "ab"));
    s->err = 0;
    orin_platform_free(p);
    if (!s->f) {
        int code = errno ? errno : EIO;
        orin_platform_free(s);
        return code;
    }
    *out = s;
    return 0;
}

size_t orin_platform_stream_read(orin_platform_stream *s, char *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        errno = 0;
        size_t k = fread(buf + got, 1, n - got, s->f);
        got += k;
        if (k == 0) {
            if (ferror(s->f)) stream_fail(s, errno);
            break;
        }
    }
    return got;
}

int orin_platform_stream_getc(orin_platform_stream *s) {
    errno = 0;
    int c = getc(s->f);
    if (c == EOF) {
        if (ferror(s->f)) stream_fail(s, errno);
        return -1;
    }
    return c;
}

size_t orin_platform_stream_write(orin_platform_stream *s, const char *p, size_t n) {
    if (n == 0) return 0;
    errno = 0;
    size_t k = fwrite(p, 1, n, s->f);
    if (k != n) stream_fail(s, errno);
    return k;
}

int orin_platform_stream_flush(orin_platform_stream *s) {
    errno = 0;
    if (fflush(s->f) != 0) stream_fail(s, errno);
    return s->err;
}

int orin_platform_stream_error(const orin_platform_stream *s) { return s->err; }

int orin_platform_stream_close(orin_platform_stream *s) {
    errno = 0;
    if (fclose(s->f) != 0) stream_fail(s, errno);
    int err = s->err;
    orin_platform_free(s);
    return err;
}

/* ---------------------------------------------------------------- threads and monitors (ADR-0017 stage 0) */

/* Handles are `generation << 32 | (index + 1)`; 0 is never valid. Records are recycled, never freed, so a stale
 * handle is detected by its generation (and a lookup never touches freed memory). g_reg guards the tables'
 * free lists and high-water marks only; operations on a monitor use the monitor's own mutex. */
enum { THR_MAX = 1 << 16, MON_MAX = 1 << 18 };

typedef struct Thr {
    pthread_t th;
    void (*entry)(void *);
    void *arg;
    uint32_t gen;
    int state; /* 0 free, 1 running or finished and not yet joined, 2 being joined */
} Thr;

typedef struct Mon {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    uint64_t *w;
    size_t n;
    uint64_t owner; /* id of the thread holding mu, 0 = nobody (atomic) */
    uint32_t gen;
    uint32_t waiters;
    int live; /* atomic */
} Mon;

static pthread_mutex_t g_reg = PTHREAD_MUTEX_INITIALIZER;
static Thr *g_thr[THR_MAX];
static uint32_t g_thr_hi, g_thr_free[THR_MAX], g_thr_nfree;
static Mon *g_mon[MON_MAX];
static uint32_t g_mon_hi, g_mon_free[MON_MAX], g_mon_nfree;
static uint64_t g_next_tid;
static __thread uint64_t t_tid;

uint64_t orin_platform_thread_id(void) {
    if (!t_tid) t_tid = __atomic_add_fetch(&g_next_tid, 1, __ATOMIC_RELAXED);
    return t_tid;
}

static void *thread_main(void *p) {
    Thr *t = (Thr *)p;
    (void)orin_platform_thread_id();
    t->entry(t->arg);
    return NULL;
}

int64_t orin_platform_thread_create(void (*entry)(void *), void *arg) {
    pthread_mutex_lock(&g_reg);
    uint32_t i;
    if (g_thr_nfree) {
        i = g_thr_free[--g_thr_nfree];
    } else if (g_thr_hi < THR_MAX) {
        i = g_thr_hi++;
        g_thr[i] = (Thr *)calloc(1, sizeof(Thr));
        if (!g_thr[i]) {
            g_thr_hi--;
            pthread_mutex_unlock(&g_reg);
            return 0;
        }
    } else {
        pthread_mutex_unlock(&g_reg);
        return 0;
    }
    Thr *t = g_thr[i];
    t->entry = entry;
    t->arg = arg;
    t->state = 1;
    uint32_t gen = t->gen;
    pthread_mutex_unlock(&g_reg);
    if (pthread_create(&t->th, NULL, thread_main, t) != 0) {
        pthread_mutex_lock(&g_reg);
        t->state = 0;
        g_thr_free[g_thr_nfree++] = i;
        pthread_mutex_unlock(&g_reg);
        return 0;
    }
    return (int64_t)(((uint64_t)gen << 32) | (i + 1));
}

int orin_platform_thread_join(int64_t h, void **arg) {
    uint32_t i = (uint32_t)((uint64_t)h & 0xffffffffu) - 1u, gen = (uint32_t)((uint64_t)h >> 32);
    pthread_mutex_lock(&g_reg);
    Thr *t = (h > 0 && i < g_thr_hi) ? g_thr[i] : NULL;
    if (!t || t->gen != gen || t->state != 1) {
        pthread_mutex_unlock(&g_reg);
        return ORIN_PLATFORM_EINVAL;
    }
    t->state = 2;
    pthread_mutex_unlock(&g_reg);
    pthread_join(t->th, NULL);
    *arg = t->arg;
    pthread_mutex_lock(&g_reg);
    t->state = 0;
    t->gen++;
    g_thr_free[g_thr_nfree++] = i;
    pthread_mutex_unlock(&g_reg);
    return 0;
}

static Mon *mon_ref(int64_t h) {
    uint32_t i = (uint32_t)((uint64_t)h & 0xffffffffu) - 1u;
    if (h <= 0 || i >= __atomic_load_n(&g_mon_hi, __ATOMIC_ACQUIRE)) return NULL;
    Mon *m = __atomic_load_n(&g_mon[i], __ATOMIC_ACQUIRE);
    if (!m || !__atomic_load_n(&m->live, __ATOMIC_ACQUIRE) || __atomic_load_n(&m->gen, __ATOMIC_RELAXED) != (uint32_t)((uint64_t)h >> 32))
        return NULL;
    return m;
}

static int mon_held(const Mon *m) { return __atomic_load_n(&m->owner, __ATOMIC_RELAXED) == orin_platform_thread_id(); }

void orin_platform_thread_exit(void) {
    uint64_t me = orin_platform_thread_id();
    uint32_t hi = __atomic_load_n(&g_mon_hi, __ATOMIC_ACQUIRE);
    for (uint32_t i = 0; i < hi; i++) {
        Mon *m = __atomic_load_n(&g_mon[i], __ATOMIC_ACQUIRE);
        if (m && __atomic_load_n(&m->owner, __ATOMIC_RELAXED) == me) { /* a panic must not leave a lock held */
            __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
            pthread_mutex_unlock(&m->mu);
        }
    }
    pthread_exit(NULL);
}

int64_t orin_platform_monitor_new(size_t nwords) {
    uint64_t *w = (uint64_t *)calloc(nwords ? nwords : 1, sizeof(uint64_t));
    if (!w) return 0;
    pthread_mutex_lock(&g_reg);
    uint32_t i;
    if (g_mon_nfree) {
        i = g_mon_free[--g_mon_nfree];
    } else if (g_mon_hi < MON_MAX) {
        Mon *m = (Mon *)calloc(1, sizeof(Mon));
        if (!m) {
            pthread_mutex_unlock(&g_reg);
            free(w);
            return 0;
        }
        pthread_mutex_init(&m->mu, NULL);
        pthread_cond_init(&m->cv, NULL);
        i = g_mon_hi;
        __atomic_store_n(&g_mon[i], m, __ATOMIC_RELEASE);
        __atomic_store_n(&g_mon_hi, i + 1, __ATOMIC_RELEASE);
    } else {
        pthread_mutex_unlock(&g_reg);
        free(w);
        return 0;
    }
    Mon *m = g_mon[i];
    m->w = w;
    m->n = nwords;
    uint32_t gen = __atomic_load_n(&m->gen, __ATOMIC_RELAXED);
    __atomic_store_n(&m->live, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_reg);
    return (int64_t)(((uint64_t)gen << 32) | (i + 1));
}

int orin_platform_monitor_lock(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m) return ORIN_PLATFORM_EINVAL;
    if (mon_held(m)) return ORIN_PLATFORM_EDEADLK;
    pthread_mutex_lock(&m->mu);
    __atomic_store_n(&m->owner, orin_platform_thread_id(), __ATOMIC_RELAXED);
    return 0;
}

int orin_platform_monitor_unlock(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m)) return ORIN_PLATFORM_EINVAL;
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&m->mu);
    return 0;
}

int orin_platform_monitor_wait(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m)) return ORIN_PLATFORM_EINVAL;
    m->waiters++;
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    pthread_cond_wait(&m->cv, &m->mu);
    __atomic_store_n(&m->owner, orin_platform_thread_id(), __ATOMIC_RELAXED);
    m->waiters--;
    return 0;
}

int orin_platform_monitor_notify_all(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m)) return ORIN_PLATFORM_EINVAL;
    pthread_cond_broadcast(&m->cv);
    return 0;
}

int orin_platform_monitor_get(int64_t h, size_t i, uint64_t *out) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || i >= m->n) return ORIN_PLATFORM_EINVAL;
    *out = m->w[i];
    return 0;
}

int orin_platform_monitor_set(int64_t h, size_t i, uint64_t v) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || i >= m->n) return ORIN_PLATFORM_EINVAL;
    m->w[i] = v;
    return 0;
}

int orin_platform_monitor_grow(int64_t h, size_t nwords) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || nwords < m->n) return ORIN_PLATFORM_EINVAL;
    uint64_t *w = (uint64_t *)realloc(m->w, (nwords ? nwords : 1) * sizeof(uint64_t));
    if (!w) return ORIN_PLATFORM_ENOMEM;
    for (size_t i = m->n; i < nwords; i++) w[i] = 0;
    m->w = w;
    m->n = nwords;
    return 0;
}

int orin_platform_monitor_free(int64_t h) {
    Mon *m = mon_ref(h);
    if (!m) return ORIN_PLATFORM_EINVAL;
    if (pthread_mutex_trylock(&m->mu) != 0) return ORIN_PLATFORM_EBUSY;
    if (m->waiters) {
        pthread_mutex_unlock(&m->mu);
        return ORIN_PLATFORM_EBUSY;
    }
    __atomic_store_n(&m->live, 0, __ATOMIC_RELEASE);
    free(m->w);
    m->w = NULL;
    m->n = 0;
    __atomic_add_fetch(&m->gen, 1, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&m->mu);
    pthread_mutex_lock(&g_reg);
    g_mon_free[g_mon_nfree++] = (uint32_t)((uint64_t)h & 0xffffffffu) - 1u;
    pthread_mutex_unlock(&g_reg);
    return 0;
}

/* The one lock of the runtime's own shared tables (transfer slots, statistics of finished tasks). */
static pthread_mutex_t g_rt = PTHREAD_MUTEX_INITIALIZER;
void orin_platform_runtime_lock(void) { pthread_mutex_lock(&g_rt); }
void orin_platform_runtime_unlock(void) { pthread_mutex_unlock(&g_rt); }
