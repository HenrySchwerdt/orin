/* CBMC harnesses for the pure / memory part of the L0 platform layer (spec 19 R2).
 * Run by tools/verify_platform.sh:  cbmc --function <harness> --bounds-check --pointer-check
 *   --signed-overflow-check --unsigned-overflow-check --conversion-check --unwind N ...
 * Bounded: array sizes are limited (MAXN below); contents and the arithmetic values are fully
 * nondeterministic. This is bounded model checking, not a proof for all sizes. */
#include "../orin_platform.h"

#include <assert.h>

enum { MAXN = 6 };

/* ---- mem_find: result is the FIRST occurrence, NULL iff none (reference spec written naively) */
void harness_mem_find(void) {
    unsigned char hay[MAXN], needle[MAXN];
    size_t hn, nn;
    __CPROVER_assume(hn <= MAXN && nn <= MAXN);
    const unsigned char *r = (const unsigned char *)orin_platform_mem_find(hay, hn, needle, nn);
    if (nn == 0) {
        assert(r == hay);
        return;
    }
    int found = 0;
    size_t first = 0;
    for (size_t i = 0; i + nn <= hn; i++) {
        int m = 1;
        for (size_t k = 0; k < nn; k++)
            if (hay[i + k] != needle[k]) m = 0;
        if (m && !found) {
            found = 1;
            first = i;
        }
    }
    if (found) assert(r == hay + first);
    else assert(r == NULL);
}

/* ---- fmt_u64 / fmt_i64: exact decimal text, no leading zeros, never writes past 20 bytes */
static uint64_t parse_u(const char *b, size_t n) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) v = v * 10 + (uint64_t)(b[i] - '0');
    return v;
}

/* 64-bit division/multiplication blow up the SAT encoding (a full-range run did not finish in 20
 * minutes), so the nondeterministic harnesses cover |v| < 10^6 (6 digits) and the extremes are
 * checked as concrete values in harness_fmt_extremes. */
void harness_fmt_u64(void) {
    uint64_t v;
    __CPROVER_assume(v < 1000000u);
    char buf[20];
    size_t n = orin_platform_fmt_u64(buf, v);
    assert(n >= 1 && n <= 20);
    for (size_t i = 0; i < n; i++) assert(buf[i] >= '0' && buf[i] <= '9');
    assert(n == 1 || buf[0] != '0');
    /* the value read back (mod 2^64, exact for all 64-bit values) equals v */
    uint64_t back = 0;
    for (size_t i = 0; i < n; i++) back = back * 10 + (uint64_t)(buf[i] - '0');
    assert(back == v);
}

void harness_fmt_i64(void) {
    int64_t v;
    __CPROVER_assume(v > -1000000 && v < 1000000);
    char buf[20];
    size_t n = orin_platform_fmt_i64(buf, v);
    assert(n >= 1 && n <= 20);
    size_t o = 0;
    if (v < 0) {
        assert(buf[0] == '-');
        o = 1;
        assert(n >= 2);
    } else {
        assert(buf[0] != '-');
    }
    for (size_t i = o; i < n; i++) assert(buf[i] >= '0' && buf[i] <= '9');
    assert(n - o == 1 || buf[o] != '0');
    uint64_t back = parse_u(buf + o, n - o);
    uint64_t mag = v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    assert(back == mag);
}

/* ---- memory wrappers behave as their contracts say */
void harness_mem(void) {
    unsigned char a[MAXN], b[MAXN];
    size_t n;
    __CPROVER_assume(n <= MAXN);
    unsigned char saved[MAXN];
    for (size_t i = 0; i < MAXN; i++) saved[i] = a[i];
    void *r = orin_platform_mem_copy(b, a, n);
    assert(r == b);
    for (size_t i = 0; i < n; i++) assert(b[i] == saved[i]);
    assert(orin_platform_mem_cmp(a, b, n) == 0);
    b[0] = a[0] ^ 1;
    if (n > 0) assert(orin_platform_mem_cmp(a, b, n) != 0);

    /* overlapping move inside one buffer */
    unsigned char m[2 * MAXN], old[2 * MAXN];
    size_t from, to;
    __CPROVER_assume(n <= MAXN && from <= 2 * MAXN && to <= 2 * MAXN);
    __CPROVER_assume(from + n <= 2 * MAXN && to + n <= 2 * MAXN);
    for (size_t i = 0; i < 2 * MAXN; i++) old[i] = m[i];
    orin_platform_mem_move(m + to, m + from, n);
    for (size_t i = 0; i < n; i++) assert(m[to + i] == old[from + i]);
    for (size_t i = 0; i < 2 * MAXN; i++)
        if (i < to || i >= to + n) assert(m[i] == old[i]); /* frame: nothing else changes */

    unsigned char s[MAXN];
    int c;
    __CPROVER_assume(c >= 0 && c < 256);
    orin_platform_mem_set(s, c, n);
    for (size_t i = 0; i < n; i++) assert(s[i] == (unsigned char)c);

    /* cmp is a three-way unsigned comparison of the first difference */
    unsigned char x[MAXN], y[MAXN];
    int d = orin_platform_mem_cmp(x, y, n);
    size_t i = 0;
    while (i < n && x[i] == y[i]) i++;
    if (i == n) assert(d == 0);
    else if (x[i] < y[i]) assert(d < 0);
    else assert(d > 0);
}

/* ---- alloc / realloc: failure keeps the old block, success preserves the prefix */
void harness_alloc(void) {
    size_t n, m;
    __CPROVER_assume(n <= 8 && m <= 8);
    unsigned char *p = (unsigned char *)orin_platform_alloc(n);
    if (!p) return;
    size_t cap = n ? n : 1;
    for (size_t i = 0; i < cap; i++) p[i] = (unsigned char)(i + 1);
    unsigned char *q = (unsigned char *)orin_platform_realloc(p, m);
    if (!q) {
        for (size_t i = 0; i < cap; i++) assert(p[i] == (unsigned char)(i + 1)); /* p still valid */
        orin_platform_free(p);
        return;
    }
    size_t keep = cap < (m ? m : 1) ? cap : (m ? m : 1);
    for (size_t i = 0; i < keep; i++) assert(q[i] == (unsigned char)(i + 1));
    q[(m ? m : 1) - 1] = 0; /* whole new block is writable */
    orin_platform_free(q);
    orin_platform_free(NULL);
}

static int is(const char *buf, size_t n, const char *want) {
    size_t i = 0;
    while (want[i]) i++;
    if (i != n) return 0;
    for (size_t k = 0; k < n; k++)
        if (buf[k] != want[k]) return 0;
    return 1;
}

void harness_fmt_extremes(void) {
    char b[20];
    size_t n = orin_platform_fmt_u64(b, UINT64_MAX);
    assert(is(b, n, "18446744073709551615"));
    n = orin_platform_fmt_u64(b, 0);
    assert(is(b, n, "0"));
    n = orin_platform_fmt_i64(b, INT64_MAX);
    assert(is(b, n, "9223372036854775807"));
    n = orin_platform_fmt_i64(b, INT64_MIN);
    assert(is(b, n, "-9223372036854775808"));
    n = orin_platform_fmt_i64(b, -1);
    assert(is(b, n, "-1"));
}
