/* Orin L0 platform layer: the PURE primitives (no OS, no libc), shared by every platform implementation: the native one
 * (orin_platform.c) and the WebAssembly one (orbit/orin_platform_orbit.c, ADR-0055). Contracts: orin_platform.h.
 * Not a translation unit of its own: each implementation #includes it once (definitions, not declarations; named .h so the
 * `*.c` globs of the tools and the release driver never compile it alone). Plain loops, so CBMC covers them whole. */
#ifndef ORIN_PLATFORM_PURE_H
#define ORIN_PLATFORM_PURE_H

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

int orin_platform_millis_split(int64_t ms, int64_t *sec, int64_t *nsec) {
    if (ms < 0) return ORIN_PLATFORM_EINVAL;
    *sec = ms / 1000;
    *nsec = (ms % 1000) * 1000000;
    return 0;
}

#endif
