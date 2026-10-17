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

/* ---- host policy (ADR-0027): a typo or any character outside [a-z,] rejects the whole policy; a policy that
 *      is accepted only contains defined family bits (never a silent "allow" through a malformed element). */
void harness_policy_parse(void) {
    char spec[8];
    size_t n;
    __CPROVER_assume(n <= 8);
    unsigned mask = 0xdeadbeef;
    int r = orin_platform_policy_parse(spec, n, &mask);
    assert(r == 0 || r == ORIN_PLATFORM_EINVAL);
    assert((mask & ~31u) == 0);
    if (r == ORIN_PLATFORM_EINVAL) assert(mask == 0);
    if (n == 0) assert(r == 0 && mask == 0);
    for (size_t i = 0; i < n; i++)
        if (!((spec[i] >= 'a' && spec[i] <= 'z') || spec[i] == ',')) assert(r == ORIN_PLATFORM_EINVAL);
    if (r == 0 && n > 0) assert(mask != 0); /* every element named a family */
    /* the exact names */
    unsigned m;
    assert(orin_platform_policy_parse("fs", 2, &m) == 0 && m == ORIN_PLATFORM_FAM_FS);
    assert(orin_platform_policy_parse("net,clock", 9, &m) == 0 && m == (ORIN_PLATFORM_FAM_NET | ORIN_PLATFORM_FAM_CLOCK));
    assert(orin_platform_policy_parse("fs,", 3, &m) == ORIN_PLATFORM_EINVAL);
}

/* ---- path normalisation: the result is a canonical absolute path (the form the scope check relies on):
 *      starts with '/', no empty / "." / ".." component, no trailing '/', never longer than the input,
 *      NUL-terminated inside the buffer (cap == plen + 1: no write past it), and idempotent. */
enum { PN = 7 };
static void nondet_path(char *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c;
        __CPROVER_assume(c == '/' || c == '.' || c == 'a');
        p[i] = (char)c;
    }
}

static void check_canonical(const char *o, size_t len) {
    assert(len >= 1 && o[0] == '/' && o[len] == 0);
    for (size_t i = 0; i < len; i++) assert(o[i] != 0);
    for (size_t i = 0; i + 1 < len; i++) assert(!(o[i] == '/' && o[i + 1] == '/'));
    if (len > 1) assert(o[len - 1] != '/');
    size_t i = 1;
    while (i < len) {
        size_t s = i;
        while (i < len && o[i] != '/') i++;
        size_t n = i - s;
        assert(n >= 1);
        assert(!(n == 1 && o[s] == '.'));
        assert(!(n == 2 && o[s] == '.' && o[s + 1] == '.'));
        i++;
    }
}

void harness_path_normalize(void) {
    char p[PN];
    size_t n;
    __CPROVER_assume(n >= 1 && n <= PN);
    nondet_path(p, n);
    char o[PN + 1];
    int64_t r = orin_platform_path_normalize(p, n, o, n + 1);
    if (p[0] != '/') {
        assert(r == -1);
        return;
    }
    assert(r >= 1 && (size_t)r <= n);
    check_canonical(o, (size_t)r);
    char o2[PN + 1];
    int64_t r2 = orin_platform_path_normalize(o, (size_t)r, o2, (size_t)r + 1);
    assert(r2 == r);
    for (int64_t i = 0; i < r; i++) assert(o2[i] == o[i]);
    assert(orin_platform_path_normalize(p, n, o, n) == -1); /* too small: refused, not overrun */
}

/* ---- scope containment: agrees with the component-wise prefix definition, is reflexive and transitive
 *      (so narrowing a scope inside a scope can never reach outside it), and "/a/bc" is not inside "/a/b". */
static size_t comps(const char *o, size_t len, size_t *st, size_t *en) {
    size_t k = 0, i = 1;
    while (i < len) {
        size_t s = i;
        while (i < len && o[i] != '/') i++;
        st[k] = s;
        en[k] = i;
        k++;
        i++;
    }
    return k;
}

static int ref_within(const char *s, size_t sl, const char *p, size_t pl) {
    size_t ss[PN], se[PN], ps[PN], pe[PN];
    size_t sk = comps(s, sl, ss, se), pk = comps(p, pl, ps, pe);
    if (sk > pk) return 0;
    for (size_t k = 0; k < sk; k++) {
        if (se[k] - ss[k] != pe[k] - ps[k]) return 0;
        for (size_t i = 0; i < se[k] - ss[k]; i++)
            if (s[ss[k] + i] != p[ps[k] + i]) return 0;
    }
    return 1;
}

static size_t nondet_norm(char *o, size_t max) {
    char p[PN];
    size_t n;
    __CPROVER_assume(n >= 1 && n <= max);
    nondet_path(p, n);
    __CPROVER_assume(p[0] == '/');
    int64_t r = orin_platform_path_normalize(p, n, o, n + 1);
    assert(r >= 1);
    return (size_t)r;
}

void harness_path_within(void) {
    char a[PN + 1], b[PN + 1], c[PN + 1];
    /* 4-character paths (<= 2 components): 7 characters need ~10 minutes, 5 about 2 minutes, for the three-way check */
    size_t al = nondet_norm(a, 4), bl = nondet_norm(b, 4);
    int w = orin_platform_path_within(a, al, b, bl);
    assert(w == ref_within(a, al, b, bl));
    assert(orin_platform_path_within(a, al, a, al) == 1);
    size_t cl = nondet_norm(c, 4);
    if (w && orin_platform_path_within(b, bl, c, cl)) assert(orin_platform_path_within(a, al, c, cl) == 1);
    assert(orin_platform_path_within("/a/b", 4, "/a/bc", 5) == 0);
    assert(orin_platform_path_within("/", 1, a, al) == 1);
}

/* ---- millis_split (the timespec of a timed monitor wait): exact, no overflow. Nondeterministic |ms| <= 10^6 (64-bit division
 * is too slow for the solver, as for fmt_u64), plus the concrete extremes 0, INT64_MAX and -1. */
static void check_split(int64_t ms) {
    int64_t sec = -7, nsec = -7;
    int rc = orin_platform_millis_split(ms, &sec, &nsec);
    if (ms < 0) {
        assert(rc == ORIN_PLATFORM_EINVAL && sec == -7 && nsec == -7);
        return;
    }
    assert(rc == 0 && sec >= 0 && nsec >= 0 && nsec < 1000000000 && nsec % 1000000 == 0);
    assert(sec == ms / 1000 && nsec / 1000000 == ms % 1000);
    assert(sec * 1000 + nsec / 1000000 == ms);
}

void harness_millis_split(void) {
    int64_t ms;
    __CPROVER_assume(ms >= -1000000 && ms <= 1000000);
    check_split(ms);
    check_split(0);
    check_split(-1);
    check_split(INT64_MAX);
}
