#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648; }

/* Copies xs (Orin copies on first write to a shared array), sorts the copy in place. */
static int64_t *sort_ints(const int64_t *xs, size_t n) {
    int64_t *a = malloc(n * 8);
    memcpy(a, xs, n * 8);
    size_t scap = 64, sl = 0;
    uint64_t *stack = malloc(scap * 8);
    stack[sl++] = 0;
    stack[sl++] = n - 1;
    while (sl > 0) {
        uint64_t hi = stack[--sl];
        uint64_t lo = stack[--sl];
        int64_t p = a[hi];
        uint64_t i = lo, j = lo;
        while (j < hi) {
            if (a[j] < p) {
                int64_t t = a[i]; a[i] = a[j]; a[j] = t;
                i++;
            }
            j++;
        }
        int64_t t2 = a[i]; a[i] = a[hi]; a[hi] = t2;
        if (sl + 4 > scap) { scap *= 2; stack = realloc(stack, scap * 8); }
        if (i > lo + 1) { stack[sl++] = lo; stack[sl++] = i - 1; }
        if (hi > i + 1) { stack[sl++] = i + 1; stack[sl++] = hi; }
    }
    free(stack);
    return a;
}

int main(void) {
    size_t n = 1000000;
    int64_t *a = malloc(n * 8);
    int64_t x = 42;
    for (size_t i = 0; i < n; i++) {
        x = lcg(x);
        a[i] = (x / 16) % 1000000;
    }
    int64_t *s = sort_ints(a, n);
    int64_t cs = 0;
    int sorted = 1;
    for (size_t k = 0; k < n; k++) {
        cs = (cs * 31 + s[k]) % 1000000007;
        if (k > 0 && s[k - 1] > s[k]) sorted = 0;
    }
    printf("sorted %d\n", sorted);
    printf("checksum %lld\n", (long long)cs);
    return 0;
}
