/* Orin L0 platform layer: implementation. Contracts: orin_platform.h. */
#include "orin_platform.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

_Static_assert(ORIN_PLATFORM_EINVAL == EINVAL, "EINVAL value");
_Static_assert(ORIN_PLATFORM_ENOMEM == ENOMEM, "ENOMEM value");

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
    fflush(stdout);
    exit(code);
}
void orin_platform_abort(void) { abort(); }

int64_t orin_platform_shell(const char *cmd, size_t n) {
    fflush(stdout);
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

void orin_platform_write(int stream, const char *p, size_t n) {
    if (stream == ORIN_PLATFORM_STDOUT) {
        if (n) ORIN_FWRITE(p, 1, n, stdout);
    } else {
        fflush(stdout);
        if (n) fwrite(p, 1, n, stderr);
        fflush(stderr);
    }
}

void orin_platform_write_line(int stream, const char *p, size_t n) {
    if (stream == ORIN_PLATFORM_STDOUT) {
        if (n) ORIN_FWRITE(p, 1, n, stdout);
        ORIN_PUTC('\n', stdout);
    } else {
        fflush(stdout);
        if (n) fwrite(p, 1, n, stderr);
        fputc('\n', stderr);
        fflush(stderr);
    }
}

void orin_platform_flush(void) { fflush(stdout); }

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

/* ---------------------------------------------------------------- network (ADR-0033) */

#ifdef MSG_NOSIGNAL
#define NET_SEND_FLAGS (MSG_DONTWAIT | MSG_NOSIGNAL)
#else
#define NET_SEND_FLAGS MSG_DONTWAIT /* SO_NOSIGPIPE is set on the socket instead (net_make) */
#endif

int64_t orin_platform_monotonic_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
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

/* Waits until fd is ready for `ev`: 0, NET_TIMEOUT, EINVAL for a bad timeout, or an errno. */
static int net_wait(int fd, short ev, int ms) {
    if (ms < 0 || ms > ORIN_PLATFORM_NET_MAXMS) return ORIN_PLATFORM_EINVAL;
    struct pollfd p = {fd, ev, 0};
    int r;
    while ((r = poll(&p, 1, ms)) < 0 && errno == EINTR) {}
    return r < 0 ? errno : r == 0 ? ORIN_PLATFORM_NET_TIMEOUT : 0;
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
    int e = port < 1 || port > 65535 ? EINVAL : net_lookup(host, hl, port, 0, &ai);
    if (e) return e;
    int fd = -1;
    for (a = ai, e = ENOENT; a && fd < 0; a = a->ai_next) {
        int s = socket(a->ai_family, SOCK_STREAM, 0), fl = s < 0 ? -1 : fcntl(s, F_GETFL);
        if (fl >= 0 && fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0 && (connect(s, a->ai_addr, a->ai_addrlen) == 0 || errno == EINPROGRESS)) {
            socklen_t n = sizeof e;
            int w = net_wait(s, POLLOUT, timeout_ms), soe = 0;
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
    int e = net_lookup(name, nlen, 0, 0, &ai);
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
