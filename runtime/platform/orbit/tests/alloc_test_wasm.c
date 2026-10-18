/* The allocator of orin_libc_orbit.c on its real target (tools/test_wasm.sh): the file is compiled into this freestanding wasm32 or
 * wasm64 module with the real memory.grow, and `run()` (run by tools/wasm_alloc_run.mjs) returns the number of failed checks. It
 * covers what the native alloc_test.c cannot on a 32-bit size_t: sizes at and beyond the 32-bit limit must fail (NULL), never
 * wrap, and the heap must stay usable near the 4 GiB end of a wasm32 memory. */
#include <stdint.h>
#include <stddef.h>
#include "../orin_libc_orbit.c"

static long bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)
static uint32_t rs = 2463534242u;
static uint32_t rnd(void) { rs ^= rs << 13, rs ^= rs >> 17, rs ^= rs << 5; return rs; }

enum { N = 400 };
__attribute__((export_name("run"))) long run(void) {
    /* sizes the 32-bit size_t cannot hold or the allocator refuses: NULL */
    CHECK(malloc((size_t)-1) == NULL);
    CHECK(malloc((size_t)-16) == NULL);
    CHECK(malloc(MAX_SIZE) == NULL);
    if (sizeof(size_t) == 4) CHECK(malloc((size_t)0x80000000u) == NULL);
    CHECK(calloc((size_t)1 << (sizeof(size_t) * 4), (size_t)1 << (sizeof(size_t) * 4)) == NULL);
    CHECK(realloc(NULL, (size_t)-1) == NULL);
    void *p = malloc(100);
    CHECK(p && ((uintptr_t)p & 15) == 0);
    CHECK(realloc(p, (size_t)-1) == NULL); /* the old block stays valid */
    ((unsigned char *)p)[99] = 7;
    free(p);
    /* random mix of small and large blocks, payload patterns checked */
    struct { unsigned char *p; size_t n; } s[N] = {0};
    for (int it = 0; it < 20000; it++) {
        int i = rnd() % N;
        if (s[i].p) {
            for (size_t k = 0; k < s[i].n; k += 97) CHECK(s[i].p[k] == (unsigned char)(i + k));
            free(s[i].p);
            s[i].p = 0;
            continue;
        }
        size_t n = rnd() % 8 == 0 ? 70000 + rnd() % 3000000 : 1 + rnd() % 3000;
        s[i].p = malloc(n);
        if (!s[i].p) { bad++; continue; }
        CHECK(((uintptr_t)s[i].p & 15) == 0);
        s[i].n = n;
        for (size_t k = 0; k < n; k += 97) s[i].p[k] = (unsigned char)(i + k);
    }
    for (int i = 0; i < N; i++) free(s[i].p);
    /* a big array growing by realloc, as the sieve does, then asking for more than the memory can hold: NULL or a usable block */
    unsigned char *a = malloc(1 << 20);
    size_t n = 1 << 20;
    CHECK(a != NULL);
    for (int g = 0; g < 6 && a; g++) {
        a[n - 1] = (unsigned char)g;
        unsigned char *b = realloc(a, n * 2);
        if (!b) break;
        CHECK(b[n - 1] == (unsigned char)g);
        a = b, n *= 2;
    }
    free(a);
    void *huge = malloc((size_t)0x7ff00000u); /* ~2 GiB: may fail on a small host memory, must not wrap */
    if (huge) {
        ((unsigned char *)huge)[0] = 1;
        ((unsigned char *)huge)[0x7ff00000u - 1] = 2;
        CHECK(((unsigned char *)huge)[0] == 1 && ((unsigned char *)huge)[0x7ff00000u - 1] == 2);
        void *more = malloc((size_t)0x7ff00000u); /* a second one would pass the 4 GiB end on wasm32: NULL there */
        if (sizeof(void *) == 4) CHECK(more == NULL);
        free(more);
        free(huge);
    }
    void *again = malloc(1000); /* still usable afterwards */
    CHECK(again != NULL);
    free(again);
    return bad;
}
