/* Same work as main.or: the byte array is widened to 64-bit slots like Orin's u8[]. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    size_t n = 16 * 65536;
    char *s = malloc(n + 1);
    for (size_t i = 0; i < 65536; i++) memcpy(s + 16 * i, "0123456789abcdef", 16);
    s[n] = 0;
    long long total = 0;
    for (int round = 0; round < 40; round++) {
        uint64_t *b = malloc(n * 8);
        for (size_t i = 0; i < n; i++) b[i] = (unsigned char)s[i];
        char *t = malloc(n + 1);
        for (size_t i = 0; i < n; i++) t[i] = (char)b[i];
        t[n] = 0;
        total += (long long)n + (unsigned char)t[round * 7919] + (long long)b[round];
        free(b);
        free(t);
    }
    printf("len %zu\n", n);
    printf("total %lld\n", total);
    return 0;
}
