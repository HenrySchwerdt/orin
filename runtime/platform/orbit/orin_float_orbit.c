/* Orin L0 platform layer, orbit (wasm64, freestanding): float <-> text without libc.
 * Implements the contracts of orin_platform_double_to_exp and orin_platform_parse_double
 * (orin_platform.h) with glibc-identical results.
 *
 * Both directions use exact arithmetic on a small fixed-size big integer (little-endian uint32_t
 * words; no allocation, no libc, no long double, no 128-bit integers):
 *   fmt_exp: x = m * 2^e. For e >= 0 the integer m<<e is converted to decimal digits; for e < 0,
 *            x = m * 5^-e / 10^-e, so the digits of m*5^-e plus a decimal point shift give the exact
 *            expansion. The digits are then rounded half-to-even to prec+1 places (exact, like glibc).
 *   parse:   the decimal text is read as D * 10^q with D an integer. Only the first 800 significant
 *            digits are kept; a nonzero tail becomes one sticky digit "1" (exact for round-to-nearest,
 *            since a tie needs at most ~770 digits). D*10^q = N/T is divided to P bits (53 or 24) by
 *            shift-and-subtract long division, then rounded half-even from the remainder. Subnormals
 *            come from clamping the binary exponent; the result bits are assembled directly, so a carry
 *            out of the mantissa and overflow to infinity fall out of one addition.
 */
#include <stddef.h>
#include <stdint.h>

#define NW 132 /* words: 4224 bits > 10^1125, the largest value parse builds */
#define MAXD 800 /* significant digits kept by parse */

typedef struct {
    uint32_t w[NW];
    int n; /* used words; no leading zero word, so 0 has n == 0 */
} big;

static void b_trim(big *b) {
    while (b->n > 0 && b->w[b->n - 1] == 0) b->n--;
}

static void b_set64(big *b, uint64_t v) {
    b->w[0] = (uint32_t)v;
    b->w[1] = (uint32_t)(v >> 32);
    b->n = 2;
    b_trim(b);
}

static void b_copy(big *d, const big *s) {
    for (int i = 0; i < s->n; i++) d->w[i] = s->w[i];
    d->n = s->n;
}

/* b = b * m + add */
static void b_mul(big *b, uint32_t m, uint32_t add) {
    uint64_t c = add;
    for (int i = 0; i < b->n; i++) {
        c += (uint64_t)b->w[i] * m;
        b->w[i] = (uint32_t)c;
        c >>= 32;
    }
    if (c) b->w[b->n++] = (uint32_t)c;
}

/* b = b / d, returns the remainder */
static uint32_t b_divsm(big *b, uint32_t d) {
    uint64_t r = 0;
    for (int i = b->n - 1; i >= 0; i--) {
        uint64_t cur = (r << 32) | b->w[i];
        b->w[i] = (uint32_t)(cur / d);
        r = cur % d;
    }
    b_trim(b);
    return (uint32_t)r;
}

static void b_shl(big *b, int s) {
    int n = b->n, ws = s / 32, bs = s % 32;
    if (n == 0) return;
    for (int j = n + ws; j >= 0; j--) {
        int k = j - ws;
        uint32_t v = 0;
        if (k >= 0 && k < n) v = b->w[k] << bs;
        if (bs && k - 1 >= 0 && k - 1 < n) v |= b->w[k - 1] >> (32 - bs);
        b->w[j] = v;
    }
    b->n = n + ws + 1;
    b_trim(b);
}

static void b_shr1(big *b) {
    for (int i = 0; i < b->n; i++) b->w[i] = (b->w[i] >> 1) | (i + 1 < b->n ? b->w[i + 1] << 31 : 0);
    b_trim(b);
}

static int b_cmp(const big *a, const big *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--)
        if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    return 0;
}

static void b_sub(big *a, const big *b) { /* a -= b, requires a >= b */
    uint64_t br = 0;
    for (int i = 0; i < a->n; i++) {
        uint64_t t = (uint64_t)a->w[i] - (i < b->n ? b->w[i] : 0) - br;
        a->w[i] = (uint32_t)t;
        br = (t >> 32) & 1;
    }
    b_trim(a);
}

static int b_bits(const big *b) {
    return b->n == 0 ? 0 : 32 * (b->n - 1) + 32 - __builtin_clz(b->w[b->n - 1]);
}

/* b = b * base^k for base 5 (chunks of 5^13) or 10 (chunks of 10^9) */
static void b_mulpow(big *b, uint32_t base, int k) {
    uint32_t chunk = base == 5 ? 1220703125u : 1000000000u;
    int per = base == 5 ? 13 : 9;
    for (; k >= per; k -= per) b_mul(b, chunk, 0);
    uint32_t m = 1;
    for (; k > 0; k--) m *= base;
    if (m > 1) b_mul(b, m, 0);
}

void orin_orbit_fmt_exp(char *buf, size_t cap, int prec, double x) {
    union { double d; uint64_t u; } v;
    v.d = x;
    uint64_t m = v.u & ((1ULL << 52) - 1);
    int be = (int)((v.u >> 52) & 0x7ff), neg = (int)(v.u >> 63);
    char dig[MAXD];
    const char *s = "0"; /* exact decimal digits of |x|, no leading zeros */
    int n = 1, e10 = 0;
    if (be != 0 || m != 0) {
        big b;
        if (be) m |= 1ULL << 52; else be = 1;
        int e = be - 1075, k = 0; /* |x| = m * 2^e */
        b_set64(&b, m);
        if (e >= 0) b_shl(&b, e);
        else { b_mulpow(&b, 5, -e); k = -e; }
        int pos = MAXD;
        while (b.n > 0) {
            uint32_t r = b_divsm(&b, 1000000000u);
            for (int i = 0; i < 9 && (b.n > 0 || r > 0); i++) {
                dig[--pos] = (char)('0' + r % 10);
                r /= 10;
            }
        }
        s = dig + pos;
        n = MAXD - pos;
        e10 = n - 1 - k;
    }
    char out[24];
    int p = prec + 1;
    for (int i = 0; i < p; i++) out[i] = i < n ? s[i] : '0';
    if (n > p) { /* round half to even on the exact remaining digits */
        int up = s[p] > '5';
        if (s[p] == '5') {
            up = (out[p - 1] - '0') & 1;
            for (int i = p + 1; i < n && !up; i++) up = s[i] != '0';
        }
        if (up) {
            int i = p - 1;
            while (i >= 0 && out[i] == '9') out[i--] = '0';
            if (i >= 0) out[i]++;
            else { out[0] = '1'; e10++; }
        }
    }
    size_t o = 0;
    if (neg) buf[o++] = '-';
    buf[o++] = out[0];
    if (prec > 0) {
        buf[o++] = '.';
        for (int i = 1; i < p; i++) buf[o++] = out[i];
    }
    buf[o++] = 'e';
    buf[o++] = e10 < 0 ? '-' : '+';
    int ae = e10 < 0 ? -e10 : e10;
    if (ae >= 100) buf[o++] = (char)('0' + ae / 100);
    buf[o++] = (char)('0' + ae / 10 % 10);
    buf[o++] = (char)('0' + ae % 10);
    buf[o] = 0;
    (void)cap; /* cap >= 32 by contract; the longest output is 26 bytes */
}

/* case-insensitive match of the lowercase word w at *p; advances *p on success */
static int word(const char **p, const char *w) {
    const char *s = *p;
    for (; *w; w++, s++)
        if ((*s | 0x20) != *w) return 0;
    *p = s;
    return 1;
}

double orin_orbit_parse_float(const char *s, int is_f32) {
    union { double d; uint64_t u; } r;
    union { float f; uint32_t u; } rf;
    while (*s == ' ' || (*s >= '\t' && *s <= '\r')) s++;
    int neg = 0;
    if (*s == '-' || *s == '+') neg = *s++ == '-';
    uint64_t sign = neg ? 1ULL << 63 : 0;
    if ((*s | 0x20) == 'i' || (*s | 0x20) == 'n') {
        r.u = sign | 0x7ff0000000000000ULL; /* inf */
        if (word(&s, "inf")) return r.d;
        r.u = sign | 0x7ff8000000000000ULL; /* quiet nan */
        if (word(&s, "nan")) return r.d;
    }
    char dig[MAXD + 2];
    int nd = 0, q = 0, dot = 0, sticky = 0;
    for (;; s++) {
        if (*s == '.' && !dot) { dot = 1; continue; }
        if (*s < '0' || *s > '9') break;
        if (nd < MAXD) {
            if (nd || *s != '0') dig[nd++] = (char)(*s - '0');
            if (dot) q--;
        } else {
            if (*s != '0') sticky = 1;
            if (!dot) q++;
        }
    }
    if (sticky) { dig[nd++] = 1; q--; }
    if ((*s | 0x20) == 'e') {
        const char *t = s + 1;
        int es = 0, ev = 0;
        if (*t == '-' || *t == '+') es = *t++ == '-';
        if (*t >= '0' && *t <= '9') {
            for (; *t >= '0' && *t <= '9'; t++)
                if (ev < 100000) ev = ev * 10 + (*t - '0');
            q += es ? -ev : ev;
        }
    }
    const int P = is_f32 ? 24 : 53, emin = is_f32 ? -149 : -1074; /* value = Q * 2^e2, Q < 2^P */
    uint64_t bits;
    if (nd == 0 || nd + q < -325) { /* below half the smallest subnormal */
        bits = 0;
    } else if (nd + q > 310) { /* beyond every finite value */
        bits = is_f32 ? 0x7f800000u : 0x7ff0000000000000ULL;
    } else {
        big N, T, S, U;
        N.n = 0;
        for (int i = 0; i < nd;) {
            uint32_t chunk = 0, mul = 1;
            for (int j = 0; j < 9 && i < nd; j++, i++) { chunk = chunk * 10 + (uint32_t)dig[i]; mul *= 10; }
            b_mul(&N, mul, chunk);
        }
        T.w[0] = 1;
        T.n = 1;
        if (q >= 0) b_mulpow(&N, 10, q); else b_mulpow(&T, 10, -q);
        int e2 = b_bits(&N) - b_bits(&T) - P; /* N/T / 2^e2 lies in (2^(P-1), 2^(P+1)) */
        if (e2 < emin) e2 = emin;
        b_copy(&S, &N);
        if (e2 < 0) b_shl(&S, -e2); else b_shl(&T, e2);
        b_copy(&U, &T);
        b_shl(&U, P);
        if (b_cmp(&S, &U) >= 0) { e2++; b_shl(&T, 1); }
        b_copy(&U, &T);
        b_shl(&U, P - 1);
        uint64_t Q = 0; /* floor(S / T) by restoring division, S < T * 2^P */
        for (int i = P - 1; i >= 0; i--) {
            if (b_cmp(&S, &U) >= 0) { b_sub(&S, &U); Q |= 1ULL << i; }
            b_shr1(&U);
        }
        b_shl(&S, 1); /* round half to even on the remainder */
        int c = b_cmp(&S, &T);
        if (c > 0 || (c == 0 && (Q & 1))) Q++;
        /* a carry to 2^P bumps the exponent field by itself; the field saturating means overflow */
        if (is_f32) {
            bits = ((uint64_t)(e2 + 149) << 23) + Q;
            if (bits > 0x7f800000u) bits = 0x7f800000u;
        } else {
            bits = ((uint64_t)(e2 + 1074) << 52) + Q;
            if (bits > 0x7ff0000000000000ULL) bits = 0x7ff0000000000000ULL;
        }
    }
    if (is_f32) {
        rf.u = (uint32_t)bits | (neg ? 0x80000000u : 0);
        return (double)rf.f; /* exact widening */
    }
    r.u = bits | sign;
    return r.d;
}
