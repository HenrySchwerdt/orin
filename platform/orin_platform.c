/* Orin L0 platform layer: implementation. Contracts: orin_platform.h. */
#include "orin_platform.h"

#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>

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
    return 1 + orin_platform_fmt_u64(buf + 1, (uint64_t)0 - (uint64_t)v);
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
