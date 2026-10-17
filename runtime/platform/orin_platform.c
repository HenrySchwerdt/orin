/* Orin L0 platform layer: implementation. Contracts: orin_platform.h. */
#include "orin_platform.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/socket.h>
#ifdef __linux__
#include <sys/eventfd.h>
#endif
#include <sys/stat.h>
#include <dirent.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

_Static_assert(ORIN_PLATFORM_EINVAL == EINVAL, "EINVAL value");
_Static_assert(ORIN_PLATFORM_ENOMEM == ENOMEM, "ENOMEM value");
_Static_assert(ORIN_PLATFORM_EBUSY == EBUSY, "EBUSY value");

#include "orin_platform_pure.h" /* mem_find, fmt, policy_parse, path_normalize / _within, millis_split */

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

/* ADR-0045. Observe without reaping: the pinned leader PID cannot be reused
 * before group cleanup. Kill both the group and direct child (even if it escaped). */
extern char **environ;
int64_t orin_platform_shell_timeout(const char *cmd, size_t n, int64_t seconds) {
    struct timespec begin, now, pause = {0, 10000000};
    if (seconds <= 0 || n == SIZE_MAX || clock_gettime(CLOCK_MONOTONIC, &begin)) return -1;
    struct sigaction disposition;
    if (sigaction(SIGCHLD, NULL, &disposition) || disposition.sa_handler != SIG_DFL || (disposition.sa_flags & SA_NOCLDWAIT)) return -1;
    orin_platform_flush();
    char *buf = (char *)orin_platform_alloc(n + 1);
    if (!buf) return -1;
    orin_platform_mem_copy(buf, cmd, n);
    buf[n] = 0;
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr)) { orin_platform_free(buf); return -1; }
    int err = posix_spawnattr_setpgroup(&attr, 0);
    if (!err) err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    pid_t pid = -1;
    char *argv[] = {"sh", "-c", buf, NULL};
    if (!err) err = posix_spawn(&pid, "/bin/sh", NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    orin_platform_free(buf);
    if (err) return -1;
    int result = -1, status;
    for (;;) {
        if (clock_gettime(CLOCK_MONOTONIC, &now)) break;
        int64_t elapsed = (int64_t)now.tv_sec - (int64_t)begin.tv_sec;
        if (elapsed > seconds || (elapsed == seconds && now.tv_nsec >= begin.tv_nsec)) { result = -2; break; }
        siginfo_t info = {0};
        if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT)) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) return -1; /* ownership was lost: never signal a possibly reused PID */
            break;
        }
        if (info.si_pid == pid) { result = 0; break; }
        if (nanosleep(&pause, NULL) && errno != EINTR) break;
    }
    /* SIGKILL is deliberate: user handlers cannot defer the deadline. */
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    pid_t reaped;
    do { reaped = waitpid(pid, &status, 0); } while (reaped < 0 && errno == EINTR);
    if (reaped != pid) return -1;
    return result == 0 ? (WIFEXITED(status) ? WEXITSTATUS(status) : -1) : result;
}

int64_t orin_platform_now_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

/* ---------------------------------------------------------------- host policy and path scopes */

int orin_platform_policy_load(unsigned *mask) {
    const char *v = getenv("ORIN_DENY");
    return orin_platform_policy_parse(v ? v : "", v ? strlen(v) : 0, mask);
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

static void write_bytes(int stream, const char *p, size_t n, int newline) {
    pthread_mutex_lock(&g_io);
    if (stream == ORIN_PLATFORM_STDOUT) {
        if (n) ORIN_FWRITE(p, 1, n, stdout);
        if (newline) ORIN_PUTC('\n', stdout);
    } else {
        fflush(stdout);
        if (n) fwrite(p, 1, n, stderr);
        if (newline) fputc('\n', stderr);
        fflush(stderr);
    }
    pthread_mutex_unlock(&g_io);
}

void orin_platform_write(int stream, const char *p, size_t n) { write_bytes(stream, p, n, 0); }
void orin_platform_write_line(int stream, const char *p, size_t n) { write_bytes(stream, p, n, 1); }

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

int orin_platform_dir_list(const char *path, size_t plen, void (*each)(void *ctx, const char *name, size_t len, int is_dir),
                           void *ctx) {
    int err = 0;
    char *p = path_copy(path, plen, &err);
    if (!p) return err;
    DIR *d = opendir(p);
    err = d ? 0 : errno;
    orin_platform_free(p);
    if (!d) return err;
    for (;;) {
        errno = 0;
        struct dirent *de = readdir(d);
        if (!de) {
            err = errno;
            break;
        }
        const char *n = de->d_name;
        if (n[0] == '.' && (n[1] == 0 || (n[1] == '.' && n[2] == 0))) continue;
        struct stat st;
        if (fstatat(dirfd(d), n, &st, AT_SYMLINK_NOFOLLOW)) {
            err = errno;
            break;
        }
        each(ctx, n, strlen(n), S_ISDIR(st.st_mode));
    }
    if (closedir(d) && !err) err = errno;
    return err;
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
    pthread_cond_t cv[2]; /* two condition queues, so that e.g. senders and receivers of a channel do not wake each other */
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

uint64_t orin_platform_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n >= 1 ? (uint64_t)n : 1;
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
        pthread_condattr_t ca;
        pthread_condattr_init(&ca);
#ifndef __APPLE__
        pthread_condattr_setclock(&ca, CLOCK_MONOTONIC); /* wait_until takes absolute CLOCK_MONOTONIC instants */
#endif
        pthread_cond_init(&m->cv[0], &ca);
        pthread_cond_init(&m->cv[1], &ca);
        pthread_condattr_destroy(&ca);
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

int orin_platform_monitor_wait(int64_t h, int cond) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || (cond != 0 && cond != 1)) return ORIN_PLATFORM_EINVAL;
    m->waiters++;
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    pthread_cond_wait(&m->cv[cond], &m->mu);
    __atomic_store_n(&m->owner, orin_platform_thread_id(), __ATOMIC_RELAXED);
    m->waiters--;
    return 0;
}


int orin_platform_monitor_wait_until(int64_t h, int cond, int64_t deadline_ms) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || (cond != 0 && cond != 1) || deadline_ms < 0) return ORIN_PLATFORM_EINVAL;
    int64_t sec, nsec;
#ifdef __APPLE__
    int64_t now = orin_platform_monotonic_millis();
    orin_platform_millis_split(now < 0 || deadline_ms < now ? 0 : deadline_ms - now, &sec, &nsec); /* relative */
#else
    orin_platform_millis_split(deadline_ms, &sec, &nsec); /* absolute */
#endif
    struct timespec ts = {(time_t)sec, (long)nsec};
    m->waiters++;
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
#ifdef __APPLE__
    int rc = pthread_cond_timedwait_relative_np(&m->cv[cond], &m->mu, &ts);
#else
    int rc = pthread_cond_timedwait(&m->cv[cond], &m->mu, &ts);
#endif
    __atomic_store_n(&m->owner, orin_platform_thread_id(), __ATOMIC_RELAXED);
    m->waiters--;
    return rc == ETIMEDOUT ? ORIN_PLATFORM_WAIT_TIMEOUT : 0;
}

int orin_platform_monitor_notify(int64_t h, int cond, int all) {
    Mon *m = mon_ref(h);
    if (!m || !mon_held(m) || (cond != 0 && cond != 1)) return ORIN_PLATFORM_EINVAL;
    if (all) pthread_cond_broadcast(&m->cv[cond]);
    else pthread_cond_signal(&m->cv[cond]);
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
/* ---------------------------------------------------------------- network (ADR-0033) */

#ifdef MSG_NOSIGNAL
#define NET_SEND_FLAGS (MSG_DONTWAIT | MSG_NOSIGNAL)
#else
#define NET_SEND_FLAGS MSG_DONTWAIT /* SO_NOSIGPIPE is set on the socket instead (net_make) */
#endif

int64_t orin_platform_monotonic_millis(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) || ts.tv_sec < 0 || ts.tv_nsec < 0 || ts.tv_nsec >= 1000000000) return -1;
    if ((uint64_t)ts.tv_sec > (uint64_t)(INT64_MAX - ts.tv_nsec / 1000000) / 1000) return -1;
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static int net_ok(const orin_platform_net *h, unsigned kind) { /* identity, liveness and policy: 0 or EPERM */
    int live = h && h->magic == ORIN_PLATFORM_NET_MAGIC && h->kind == kind && !h->deny;
    return live && (kind == ORIN_PLATFORM_NET_GRANT ? h->can != 0 : h->fd >= 0) ? 0 : ORIN_PLATFORM_EPERM;
}

static int ieq(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return 0;
    }
    return 1;
}

/* Does pattern p cover s? s is a name or itself a "*.sfx" pattern (then every name s covers must be covered). */
static int net_cover(const char *p, size_t pl, const char *s, size_t sl) {
    int sw = sl >= 2 && s[0] == '*' && s[1] == '.';
    if (pl == 1 && p[0] == '*') return 1;
    if (pl >= 2 && p[0] == '*' && p[1] == '.')
        return (sw ? sl - 1 >= pl - 1 : sl > pl - 1) && ieq(s + sl - (pl - 1), p + 1, pl - 1);
    return !sw && pl == sl && ieq(p, s, pl);
}

static int net_text(const char *h, size_t hl) { /* a usable host text: 1..63 bytes, no NUL, no '*' */
    for (size_t i = 0; i < hl; i++)
        if (h[i] == 0 || h[i] == '*') return 0;
    return hl >= 1 && hl <= 63;
}

static int net_scope(const orin_platform_net *g, unsigned what, const char *h, size_t hl, int port) {
    const orin_platform_scope *s = &g->sc[what - 1];
    return (g->can & what) && net_text(h, hl) && port >= 0 && (unsigned)port >= s->lo && (unsigned)port <= s->hi &&
           net_cover(s->h, s->hl, h, hl);
}

int orin_platform_net_narrow(const orin_platform_net *p, unsigned what, const char *h, size_t hl, int lo, int hi,
                             orin_platform_net *out) {
    if (!p || p->magic != ORIN_PLATFORM_NET_MAGIC || p->kind != ORIN_PLATFORM_NET_GRANT) return ORIN_PLATFORM_EPERM;
    int pat = (hl == 1 && h[0] == '*') || net_text(h, hl) || (hl > 2 && h[0] == '*' && h[1] == '.' && net_text(h + 2, hl - 2));
    if ((what != ORIN_PLATFORM_NET_LISTEN && what != ORIN_PLATFORM_NET_CONNECT) || !pat || lo < 0 || hi > 65535 || lo > hi)
        return ORIN_PLATFORM_EINVAL;
    const orin_platform_scope *ps = &p->sc[what - 1];
    int in = (p->can & what) && (unsigned)lo >= ps->lo && (unsigned)hi <= ps->hi && net_cover(ps->h, ps->hl, h, hl);
    *out = *p;
    out->can = in ? what : 0;
    if (in) {
        orin_platform_scope *ns = &out->sc[what - 1];
        ns->hl = hl, ns->lo = (unsigned)lo, ns->hi = (unsigned)hi;
        orin_platform_mem_copy(ns->h, h, hl);
    }
    return 0;
}

/* A fresh record for socket fd: non-blocking, close-on-exec, no SIGPIPE. fd < 0 or a failure: the errno (fd closed). */
static int net_make(int fd, unsigned kind, int opt, orin_platform_net *out) {
    int one = 1, fl;
    if (fd < 0) return errno ? errno : EIO;
    if ((fl = fcntl(fd, F_GETFL)) < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        int e = errno;
        close(fd);
        return e;
    }
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    if (kind == ORIN_PLATFORM_NET_STREAM && (opt & 1)) setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    orin_platform_mem_set(out, 0, sizeof *out);
    out->magic = ORIN_PLATFORM_NET_MAGIC, out->kind = kind, out->fd = fd;
    return 0;
}

/* ---- wake sources (ADR-0017 Addendum D): a cancellation token that a blocked network wait polls together with its socket.
 * A record is a flag plus a lazily created eventfd (a pipe off Linux); records form a tree (a nested scope's token is a child of
 * the token its task is bound to), a wait polls the whole chain. Handles are `generation << 32 | (index + 1)`. */
enum { WAKE_MAX = 1 << 16, WAKE_DEPTH = 32 };
typedef struct {
    int rd, wr, live, set, depth;
    uint32_t gen;
    int64_t parent;
} Wake;
static Wake g_wake[WAKE_MAX];
static uint32_t g_wake_hi, g_wake_free[WAKE_MAX], g_wake_nfree;
static pthread_mutex_t g_wk = PTHREAD_MUTEX_INITIALIZER;
static __thread int64_t t_wake; /* the token the calling thread's waits observe, 0 = none */

static Wake *wake_ref(int64_t h) { /* under g_wk */
    uint32_t i = (uint32_t)((uint64_t)h & 0xffffffffu) - 1u;
    return h > 0 && i < g_wake_hi && g_wake[i].live && g_wake[i].gen == (uint32_t)((uint64_t)h >> 32) ? &g_wake[i] : NULL;
}

static int64_t wake_handle(const Wake *w) { return (int64_t)(((uint64_t)w->gen << 32) | (uint64_t)(w - g_wake + 1)); }

static void wake_poke(const Wake *w) {
    uint64_t one = 1;
    ssize_t n = write(w->wr, &one, w->rd == w->wr ? sizeof one : 1);
    (void)n;
}

static int wake_fd(Wake *w) { /* under g_wk: the readable end, created on first use; -1 when no descriptor is left */
    if (w->rd < 0) {
#ifdef __linux__
        w->rd = w->wr = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
#else
        int p[2];
        if (pipe(p) == 0) {
            for (int i = 0; i < 2; i++) fcntl(p[i], F_SETFL, fcntl(p[i], F_GETFL) | O_NONBLOCK), fcntl(p[i], F_SETFD, FD_CLOEXEC);
            w->rd = p[0], w->wr = p[1];
        }
#endif
        if (w->rd >= 0 && w->set) wake_poke(w);
    }
    return w->rd;
}

/* under g_wk: 1 when the token or an ancestor is set, else 0; with fds the readable ends of the chain go to fds[0..*n-1], -1 on EMFILE */
static int wake_walk(int64_t h, int *fds, int *n) {
    int set = 0;
    for (Wake *w; (w = wake_ref(h)) != NULL; h = w->parent) {
        set |= w->set;
        if (fds && (fds[*n] = wake_fd(w)) < 0) return -1;
        if (fds) ++*n;
    }
    return set;
}

int64_t orin_platform_wake_open(void) {
    pthread_mutex_lock(&g_wk);
    Wake *p = wake_ref(t_wake);
    uint32_t i = g_wake_nfree ? g_wake_free[g_wake_nfree - 1] : g_wake_hi;
    if (i >= WAKE_MAX || (p && p->depth >= WAKE_DEPTH)) {
        pthread_mutex_unlock(&g_wk);
        return 0;
    }
    if (g_wake_nfree) g_wake_nfree--;
    else g_wake_hi++;
    Wake *w = &g_wake[i];
    w->rd = w->wr = -1, w->live = 1, w->set = 0, w->parent = p ? t_wake : 0, w->depth = p ? p->depth + 1 : 0;
    t_wake = wake_handle(w);
    pthread_mutex_unlock(&g_wk);
    return t_wake;
}

int64_t orin_platform_wake_close(int64_t h) {
    pthread_mutex_lock(&g_wk);
    Wake *w = wake_ref(h);
    if (!w) {
        pthread_mutex_unlock(&g_wk);
        return ORIN_PLATFORM_EINVAL;
    }
    if (t_wake == h) t_wake = w->parent;
    if (w->rd >= 0) close(w->rd);
    if (w->wr >= 0 && w->wr != w->rd) close(w->wr);
    w->live = 0, w->gen = (w->gen + 1) & 0x7fffffffu;
    g_wake_free[g_wake_nfree++] = (uint32_t)(w - g_wake);
    pthread_mutex_unlock(&g_wk);
    return 0;
}

int64_t orin_platform_wake_signal(int64_t h) {
    pthread_mutex_lock(&g_wk);
    Wake *w = wake_ref(h);
    int64_t changed = w && !w->set;
    if (changed && (w->set = 1, w->wr >= 0)) wake_poke(w);
    pthread_mutex_unlock(&g_wk);
    return changed;
}

int64_t orin_platform_wake_check(int64_t h) {
    pthread_mutex_lock(&g_wk);
    int64_t r = wake_ref(h) ? wake_walk(h, NULL, NULL) : 2;
    pthread_mutex_unlock(&g_wk);
    return r;
}

int64_t orin_platform_wake_bind(int64_t h) {
    int64_t prev = t_wake;
    t_wake = h;
    return prev;
}

int64_t orin_platform_wake_bound(void) { return t_wake; }

static int net_cancelled(void) { /* 1 when the bound token or an ancestor is set */
    if (!t_wake) return 0;
    pthread_mutex_lock(&g_wk);
    int r = wake_walk(t_wake, NULL, NULL);
    pthread_mutex_unlock(&g_wk);
    return r;
}

/* Waits until fd is ready for `ev`: 0, NET_TIMEOUT, NET_CANCELLED (the bound token is set before or while waiting), EINVAL for a
 * bad timeout, or an errno (EMFILE when the wake descriptor cannot be made). */
static int net_wait(int fd, short ev, int ms) {
    if (ms < 0 || ms > ORIN_PLATFORM_NET_MAXMS) return ORIN_PLATFORM_EINVAL;
    struct pollfd p[WAKE_DEPTH + 2];
    int wf[WAKE_DEPTH + 1], n = 0, r = 0;
    p[0].fd = fd, p[0].events = ev, p[0].revents = 0;
    if (t_wake) {
        pthread_mutex_lock(&g_wk);
        r = wake_walk(t_wake, wf, &n);
        pthread_mutex_unlock(&g_wk);
        if (r) return r < 0 ? EMFILE : ORIN_PLATFORM_NET_CANCELLED;
    }
    for (int i = 0; i < n; i++) p[i + 1].fd = wf[i], p[i + 1].events = POLLIN, p[i + 1].revents = 0;
    while ((r = poll(p, (nfds_t)(n + 1), ms)) < 0 && errno == EINTR) {}
    if (r < 0) return errno;
    return net_cancelled() ? ORIN_PLATFORM_NET_CANCELLED : r == 0 ? ORIN_PLATFORM_NET_TIMEOUT : 0;
}

/* what is left of a wait of `ms` that began at t0 (ms when the clock fails: the operation then keeps its per-wait bound) */
static int net_left(int64_t t0, int ms) {
    int64_t now = orin_platform_monotonic_millis(), left = ms - (now - t0);
    return ms < 0 || ms > ORIN_PLATFORM_NET_MAXMS || now < 0 || t0 < 0 ? ms : left < 0 ? 0 : left > ms ? ms : (int)left;
}

static int net_err(int e) {
    return e == EAGAIN || e == EINTR ? ORIN_PLATFORM_NET_TIMEOUT
           : e == ECONNRESET || e == EPIPE || e == ECONNABORTED || e == ETIMEDOUT ? ORIN_PLATFORM_NET_RESET : e ? e : EIO; /* never 0: a failure stays a failure */
}

/* getaddrinfo for (host, port); 0, ENOENT (no such name) or EINVAL. */
static int net_lookup(const char *h, size_t hl, int port, int flags, struct addrinfo **ai) {
    char name[64], ps[8];
    struct addrinfo hint;
    orin_platform_mem_set(&hint, 0, sizeof hint);
    orin_platform_mem_copy(name, h, hl), name[hl] = 0;
    snprintf(ps, sizeof ps, "%d", port);
    hint.ai_socktype = SOCK_STREAM, hint.ai_flags = flags;
    int r = getaddrinfo(name, ps, &hint, ai);
    return r == 0 ? 0 : r == EAI_NONAME ? ENOENT : EINVAL;
}

int orin_platform_tcp_listen(const orin_platform_net *g, const char *addr, size_t alen, int port, int backlog, int opt,
                             orin_platform_net *out, int *out_port) {
    if (net_ok(g, ORIN_PLATFORM_NET_GRANT) || !net_scope(g, ORIN_PLATFORM_NET_LISTEN, addr, alen, port)) return ORIN_PLATFORM_EPERM;
    struct addrinfo *ai;
    int e = port > 65535 || backlog < 1 || backlog > 4096 ? EINVAL : net_lookup(addr, alen, port, AI_NUMERICHOST | AI_PASSIVE, &ai);
    if (e) return e;
    int fd = socket(ai->ai_family, SOCK_STREAM, 0), on = 1;
    if (fd >= 0 && (opt & 1)) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    if (fd >= 0 && (bind(fd, ai->ai_addr, ai->ai_addrlen) < 0 || listen(fd, backlog) < 0)) e = errno, close(fd), fd = -1, errno = e;
    freeaddrinfo(ai);
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    if (fd >= 0 && getsockname(fd, (struct sockaddr *)&ss, &sl) == 0)
        *out_port = ntohs(ss.ss_family == AF_INET ? ((struct sockaddr_in *)&ss)->sin_port : ((struct sockaddr_in6 *)&ss)->sin6_port);
    return net_make(fd, ORIN_PLATFORM_NET_LISTENER, 0, out);
}

int orin_platform_tcp_accept(const orin_platform_net *l, int timeout_ms, int opt, orin_platform_net *out, char *peer, size_t pcap,
                             int *peer_port) {
    if (net_ok(l, ORIN_PLATFORM_NET_LISTENER)) return ORIN_PLATFORM_EPERM;
    int e = net_wait(l->fd, POLLIN, timeout_ms);
    if (e) return e;
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    char serv[16];
    int fd = accept(l->fd, (struct sockaddr *)&ss, &sl);
    if (fd >= 0 && (pcap == 0 || getnameinfo((struct sockaddr *)&ss, sl, peer, (socklen_t)pcap, serv, sizeof serv,
                                             NI_NUMERICHOST | NI_NUMERICSERV)))
        close(fd), fd = -1, errno = EINVAL;
    if (fd >= 0) *peer_port = atoi(serv);
    return fd < 0 && (errno == EAGAIN || errno == ECONNABORTED) ? ORIN_PLATFORM_NET_TIMEOUT : net_make(fd, ORIN_PLATFORM_NET_STREAM, opt, out);
}

int orin_platform_tcp_connect(const orin_platform_net *g, const char *host, size_t hl, int port, int timeout_ms, int opt,
                              orin_platform_net *out) {
    if (net_ok(g, ORIN_PLATFORM_NET_GRANT) || !net_scope(g, ORIN_PLATFORM_NET_CONNECT, host, hl, port)) return ORIN_PLATFORM_EPERM;
    struct addrinfo *ai, *a;
    int e = net_cancelled() ? ORIN_PLATFORM_NET_CANCELLED : port < 1 || port > 65535 ? EINVAL : net_lookup(host, hl, port, 0, &ai);
    if (e) return e;
    int fd = -1;
    int64_t t0 = orin_platform_monotonic_millis(); /* timeout_ms bounds the whole connect, not each address */
    for (a = ai, e = ENOENT; a && fd < 0 && e != ORIN_PLATFORM_NET_CANCELLED; a = a->ai_next) {
        int s = socket(a->ai_family, SOCK_STREAM, 0), fl = s < 0 ? -1 : fcntl(s, F_GETFL);
        if (fl >= 0 && fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0 && (connect(s, a->ai_addr, a->ai_addrlen) == 0 || errno == EINPROGRESS)) {
            socklen_t n = sizeof e;
            int w = net_wait(s, POLLOUT, net_left(t0, timeout_ms)), soe = 0;
            if (w == 0 && getsockopt(s, SOL_SOCKET, SO_ERROR, &soe, &n) == 0 && soe == 0) fd = s;
            else e = net_err(w ? w : soe), close(s);
        } else e = errno, s >= 0 ? close(s) : 0;
    }
    freeaddrinfo(ai);
    return fd < 0 ? e : net_make(fd, ORIN_PLATFORM_NET_STREAM, opt, out);
}

int orin_platform_stream_recv(const orin_platform_net *s, char *buf, size_t cap, int timeout_ms, size_t *out_len) {
    *out_len = 0;
    if (net_ok(s, ORIN_PLATFORM_NET_STREAM)) return ORIN_PLATFORM_EPERM;
    int e = cap == 0 ? ORIN_PLATFORM_EINVAL : net_wait(s->fd, POLLIN, timeout_ms);
    if (e) return e;
    ssize_t n = recv(s->fd, buf, cap, MSG_DONTWAIT);
    if (n > 0 && (size_t)n <= cap) return *out_len = (size_t)n, 0;
    return n == 0 ? ORIN_PLATFORM_NET_EOF : net_err(errno);
}

int orin_platform_stream_send(const orin_platform_net *s, const char *data, size_t len, int timeout_ms, size_t *out_sent) {
    *out_sent = 0;
    if (net_ok(s, ORIN_PLATFORM_NET_STREAM)) return ORIN_PLATFORM_EPERM;
    int e = net_wait(s->fd, POLLOUT, timeout_ms);
    if (e || len == 0) return e;
    ssize_t n = send(s->fd, data, len, NET_SEND_FLAGS);
    if (n >= 0 && (size_t)n <= len) return *out_sent = (size_t)n, 0;
    return net_err(errno);
}

int orin_platform_net_shutdown(const orin_platform_net *s, int how) {
    if (net_ok(s, ORIN_PLATFORM_NET_STREAM)) return ORIN_PLATFORM_EPERM;
    if (how < 0 || how > 2) return ORIN_PLATFORM_EINVAL;
    return shutdown(s->fd, how == 0 ? SHUT_RD : how == 1 ? SHUT_WR : SHUT_RDWR) == 0 ? 0 : net_err(errno);
}

int orin_platform_net_close(orin_platform_net *h) {
    if (!h || h->magic != ORIN_PLATFORM_NET_MAGIC) return ORIN_PLATFORM_EPERM;
    if (h->fd >= 0) close(h->fd);
    h->fd = -1, h->can = 0;
    return 0;
}

int orin_platform_dns_resolve(const orin_platform_net *g, const char *name, size_t nlen, char *out, size_t cap, size_t *out_len) {
    *out_len = 0;
    if (net_ok(g, ORIN_PLATFORM_NET_GRANT) || !net_scope(g, ORIN_PLATFORM_NET_CONNECT, name, nlen, (int)g->sc[1].lo))
        return ORIN_PLATFORM_EPERM;
    struct addrinfo *ai, *a;
    int e = net_cancelled() ? ORIN_PLATFORM_NET_CANCELLED : net_lookup(name, nlen, 0, 0, &ai); /* getaddrinfo itself cannot be interrupted */
    for (a = e ? NULL : ai; a; a = a->ai_next) {
        char t[64];
        if (getnameinfo(a->ai_addr, a->ai_addrlen, t, sizeof t, NULL, 0, NI_NUMERICHOST)) continue;
        size_t n = strlen(t);
        if (*out_len + n + 1 > cap || orin_platform_mem_find(out, *out_len, t, n)) continue; /* full, or a duplicate */
        orin_platform_mem_copy(out + *out_len, t, n), out[*out_len + n] = '\n', *out_len += n + 1;
    }
    if (!e) freeaddrinfo(ai);
    return e;
}
