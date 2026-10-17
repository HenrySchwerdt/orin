/* Differential test: orin_float_orbit.c against glibc snprintf("%.*e") / strtod / strtof. */
#define _GNU_SOURCE
#include "../orin_float_orbit.c"

#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rs = 0x9e3779b97f4a7c15ULL;
static uint64_t rnd(void) {
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs * 0x2545F4914F6CDD1DULL;
}

static long n_fmt, n_parse, bad;

static void report(const char *what, const char *in, const char *got, const char *want) {
    if (bad++ < 20) printf("MISMATCH %s: in=%.120s\n  got =%.120s\n  want=%.120s\n", what, in, got, want);
}

static void check_fmt(double x, int prec) {
    char a[40], b[40], in[40];
    orin_orbit_fmt_exp(a, sizeof a, prec, x);
    snprintf(b, sizeof b, "%.*e", prec, x);
    n_fmt++;
    if (strcmp(a, b)) { snprintf(in, sizeof in, "%a prec=%d", x, prec); report("fmt", in, a, b); }
}

static int same(double a, double b) {
    if (isnan(a) || isnan(b)) return isnan(a) && isnan(b) && signbit(a) == signbit(b);
    return memcmp(&a, &b, sizeof a) == 0;
}

static void check_parse(const char *s) {
    for (int f32 = 0; f32 < 2; f32++) {
        double got = orin_orbit_parse_float(s, f32);
        double want = f32 ? (double)strtof(s, NULL) : strtod(s, NULL);
        n_parse++;
        if (!same(got, want)) {
            char a[64], b[64];
            snprintf(a, sizeof a, "%a (f32=%d)", got, f32);
            snprintf(b, sizeof b, "%a", want);
            report("parse", s, a, b);
        }
    }
}

static double from_bits(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

static void fmt_all(double x) { for (int p = 0; p <= 17; p++) check_fmt(x, p); }

/* parse the exact text of x, a neighbour midpoint, and values just above and below it */
static void check_mid(const char *mid) {
    char t[1300], *e = strchr(mid, 'e');
    if (!e) return;
    check_parse(mid);
    size_t k = (size_t)(e - mid);
    memcpy(t, mid, k); strcpy(t + k, "1"); strcat(t, e);
    check_parse(t); /* above */
    memcpy(t, mid, k + strlen(e) + 1);
    size_t z = k;
    while (z > 0 && (t[z - 1] == '0')) z--;
    if (z > 0 && t[z - 1] >= '1' && t[z - 1] <= '9') { /* decrement last nonzero digit, fill zeros with 9 */
        t[z - 1]--;
        for (size_t i = z; i < k && i < z + 8; i++) t[i] = '9';
        check_parse(t); /* below */
    }
}

int main(void) {
    static const double edge[] = {0.0, -0.0, 1, -1, 0.1, 0.5, 2.5, 1e23, 9007199254740993.0, 5e-324,
        2.2250738585072011e-308, 2.2250738585072014e-308, 1.7976931348623157e308, 123456789.125,
        0.3, 1e-5, 99999.5, 9.5, 0.95, 9.9999999999999995, 1e15, 1e16, 1e22, 4.35, 1.5, 0.125, 1e100,
        1e-100, 4.9406564584124654e-324, 8.98846567431158e307, 3.0517578125e-5};
    for (size_t i = 0; i < sizeof edge / sizeof *edge; i++) fmt_all(edge[i]);
    fmt_all(nextafter(1.0, 2)); fmt_all(nextafter(1.0, 0)); fmt_all(DBL_MAX); fmt_all(-DBL_MAX);
    fmt_all(DBL_MIN); fmt_all(DBL_TRUE_MIN); fmt_all(nextafter(DBL_MIN, 0));
    for (int e = -1074; e <= 1023; e++) { fmt_all(ldexp(1.0, e)); fmt_all(ldexp(1.5, e)); }
    for (int i = 0; i < 200000; i++) fmt_all(from_bits(rnd() & ~(0xfffULL << 52) | ((rnd() % 2047) << 52)));
    for (int i = 0; i < 3000000; i++) {
        uint64_t u = rnd();
        if ((u >> 52 & 0x7ff) == 0x7ff) u &= ~(1ULL << 62);
        if (i & 1) u &= ~0ULL << (rnd() % 52); /* few mantissa bits: exact ties */
        if ((u >> 52 & 0x7ff) == 0x7ff) continue;
        check_fmt(from_bits(u), (int)(rnd() % 18));
    }
    for (int i = 0; i < 1000000; i++) { /* small integers and halves: decimal ties */
        double x = (double)(int64_t)(rnd() % 2000000) / (1 << (rnd() % 4));
        check_fmt(x, (int)(rnd() % 6)); check_fmt(-x, (int)(rnd() % 18));
    }
    printf("fmt: %ld checks, %ld mismatches so far\n", n_fmt, bad);

    static const char *ps[] = {"0", "-0", "+0.0", "1", "0.1", "0.5", "2.5", "1e23", "9007199254740993", "5e-324",
        "2.5e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "2.2250738585072011e-308",
        "2.2250738585072014e-308", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308",
        "1e400", "-1e400", "1e-400", "-1e-400", "1e99999999999", "1e-99999999999", ".5", "5.", "1e", "1e+", "1.e3",
        "0.1000000000000000055511151231257827021181583404541015625",
        "0.1000000000000000055511151231257827021181583404541015626",
        "0.1000000000000000055511151231257827021181583404541015624",
        "16777217", "16777216.99999", "16777217.00001", "33554434", "3.4028235e38", "3.4028236e38",
        "3.4028235677973366e38", "3.4028234663852886e38", "1.17549435e-38", "1.4e-45", "7e-46", "7.006492321624085e-46",
        "7.006492321624086e-46", "1.401298464324817e-45", "1e-46", "inf", "-Infinity", "INF", "NaN", "-nan", "infinit",
        "  12.5", "00000000000000000000000000001", "0.0000000000000000000000000000000001e34", "123456789012345678901234567890e-20"};
    for (size_t i = 0; i < sizeof ps / sizeof *ps; i++) check_parse(ps[i]);
    {   static char big_s[2200];
        for (int len = 300; len <= 1500; len += 37) { /* long digit strings */
            for (int i = 0; i < len; i++) big_s[i] = (char)('0' + rnd() % 10);
            big_s[0] = '1'; big_s[len] = 0;
            check_parse(big_s);
            snprintf(big_s + len, 20, "e-%d", len - 3); check_parse(big_s);
            big_s[len / 2] = '.'; check_parse(big_s);
        }
        memset(big_s, '0', 1000); big_s[1000] = 0; big_s[0] = '1'; check_parse(big_s);
        memset(big_s, '9', 1000); big_s[1000] = 0; check_parse(big_s);
        strcpy(big_s, "0."); memset(big_s + 2, '0', 900); strcpy(big_s + 902, "123"); check_parse(big_s);
        strcpy(big_s, "0."); memset(big_s + 2, '0', 400); strcpy(big_s + 402, "1"); check_parse(big_s);
        /* 2^-1075 (a tie) and values around it, written with 800+ digits */
        char t[1300]; snprintf(t, sizeof t, "%.1100e", ldexp(1.0, -1074)); check_parse(t);
    }
    /* midpoints between adjacent doubles and floats, exact in decimal */
    for (int i = 0; i < 30000; i++) {
        uint64_t u = rnd(); u &= ~(0x7ffULL << 52); u |= (rnd() % 2046) << 52; if (i % 4 == 0) u &= (1ULL << 52) - 1 | (rnd() & 1) << 63;
        double x = from_bits(u), y = nextafter(x, INFINITY);
        char t[1300];
#if LDBL_MANT_DIG == 64
        long double mid = ((long double)x + (long double)y) / 2;
        snprintf(t, sizeof t, "%.1000Le", mid);
        check_mid(t);
#endif
        float f = (float)x, g = nextafterf(f, INFINITY);
        if (isfinite(f) && isfinite(g)) { snprintf(t, sizeof t, "%.1000e", ((double)f + (double)g) / 2); check_mid(t); }
    }
    for (int i = 0; i < 20000; i++) { /* float midpoints over the whole float range incl. subnormals */
        uint32_t fb = (uint32_t)rnd() & 0x7f7fffff; if (i & 1) fb &= 0x00ffffff;
        float f; memcpy(&f, &fb, 4);
        float g = nextafterf(f, INFINITY); char t[1300];
        if (!isfinite(g)) continue;
        snprintf(t, sizeof t, "%.1000e", ((double)f + (double)g) / 2); check_mid(t);
    }
    for (long i = 0; i < 3000000; i++) { /* random decimal strings */
        char t[1400]; int o = 0, len = (rnd() % 10 == 0) ? (int)(rnd() % 900) + 1 : (int)(rnd() % 25) + 1;
        if (rnd() & 1) t[o++] = '-';
        int dotat = (int)(rnd() % (len + 1));
        for (int j = 0; j < len; j++) { if (j == dotat && rnd() % 4) t[o++] = '.'; t[o++] = (char)('0' + rnd() % 10); }
        int ex = (rnd() % 3) ? (int)(rnd() % 700) - 350 : (int)(rnd() % 80) - 40;
        if (rnd() % 5) o += snprintf(t + o, 20, "e%d", ex);
        t[o] = 0; check_parse(t);
    }
    for (int i = 0; i < 1500000; i++) { /* round trips through fmt */
        uint64_t u = rnd(); if ((u >> 52 & 0x7ff) == 0x7ff) continue;
        double x = from_bits(u); char a[40], b[40];
        orin_orbit_fmt_exp(a, sizeof a, 17, x);
        n_parse++;
        if (!same(orin_orbit_parse_float(a, 0), x)) report("roundtrip", a, "?", "?");
        float f = (float)x; if (!isfinite(f)) continue;
        orin_orbit_fmt_exp(b, sizeof b, 9, (double)f);
        if (!same(orin_orbit_parse_float(b, 1), (double)f)) report("roundtrip32", b, "?", "?");
    }
    printf("fmt checks: %ld, parse checks: %ld, mismatches: %ld\n", n_fmt, n_parse, bad);
    puts(bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
