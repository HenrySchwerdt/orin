#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int64_t *p; size_t len, cap; } Vec;
static void push(Vec *v, int64_t x) {
    if (v->len == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 4;
        v->p = realloc(v->p, v->cap * 8);
    }
    v->p[v->len++] = x;
}
static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648; }

/* Consumes xs (frees it), returns a fresh sorted vector. */
static Vec qs(Vec xs) {
    if (xs.len <= 1) return xs;
    int64_t p = xs.p[0];
    Vec lo = {0}, eq = {0}, hi = {0};
    for (size_t i = 0; i < xs.len; i++) {
        int64_t x = xs.p[i];
        if (x < p) push(&lo, x);
        else if (x == p) push(&eq, x);
        else push(&hi, x);
    }
    free(xs.p);
    Vec l = qs(lo), h = qs(hi);
    Vec r = {malloc((l.len + eq.len + h.len + 1) * 8), l.len + eq.len + h.len, l.len + eq.len + h.len + 1};
    if (l.len) memcpy(r.p, l.p, l.len * 8);
    if (eq.len) memcpy(r.p + l.len, eq.p, eq.len * 8);
    if (h.len) memcpy(r.p + l.len + eq.len, h.p, h.len * 8);
    free(l.p); free(eq.p); free(h.p);
    return r;
}

int main(void) {
    Vec a = {0};
    int64_t x = 42;
    for (int i = 0; i < 1000000; i++) {
        x = lcg(x);
        push(&a, (x / 16) % 1000000);
    }
    Vec s = qs(a);
    int64_t cs = 0;
    int sorted = 1;
    for (size_t k = 0; k < s.len; k++) {
        cs = (cs * 31 + s.p[k]) % 1000000007;
        if (k > 0 && s.p[k - 1] > s.p[k]) sorted = 0;
    }
    printf("sorted %d\n", sorted);
    printf("checksum %lld\n", (long long)cs);
    return 0;
}
