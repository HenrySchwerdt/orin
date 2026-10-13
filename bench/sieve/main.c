#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
static int64_t sieve(uint64_t n) {
    uint64_t cap = 4, len = 0;
    int64_t *flags = malloc(cap * 8);
    for (uint64_t i = 0; i <= n; i++) {
        if (len == cap) {
            cap *= 2;
            flags = realloc(flags, cap * 8);
        }
        flags[len++] = 1;
    }
    flags[0] = 0;
    flags[1] = 0;
    for (uint64_t i = 2; i * i <= n; i++)
        if (flags[i] == 1)
            for (uint64_t j = i * i; j <= n; j += i) flags[j] = 0;
    int64_t count = 0;
    for (uint64_t i = 0; i <= n; i++) count += flags[i];
    free(flags);
    return count;
}
int main(void) {
    printf("primes<=10000000: %lld\n", (long long)sieve(10000000));
    return 0;
}
