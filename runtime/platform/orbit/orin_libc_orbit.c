/* The minimal C library of the WebAssembly platform layer (ADR-0055): exactly what runtime/platform/orin_platform.h and
 * runtime/core/orin_runtime.c need from libc on a freestanding wasm64 target (include/stdlib.h, include/string.h).
 * No imports: memory comes from memory.grow.
 *
 * Allocator: power-of-two size classes. A block of class c is 2^c bytes (c >= 5): a 16-byte header holding c, then
 * 2^c - 16 bytes of payload, so every payload is 16-byte aligned (the orin_platform_alloc contract). A freed block goes on
 * the free list of its class and is reused by the next allocation of that class; new blocks are cut from the end of the
 * heap, which grows with memory.grow. Memory is never returned to the host (an instance's memory only grows), and the
 * waste is below 2x per block. One thread (see orin_platform_orbit.c), so no locking. */
#include <stddef.h>
#include <stdint.h>

#include "include/stdlib.h"
#include "include/string.h"

enum { HDR = 16, MIN_CLASS = 5, MAX_CLASS = 47 };

extern unsigned char __heap_base; /* provided by wasm-ld: the first byte after the stack and the data */
static unsigned char *g_top;      /* next unused byte of the heap */
static void *g_free[MAX_CLASS + 1];

static int class_of(size_t n) {
    if (n > ((size_t)1 << MAX_CLASS) - HDR) return -1;
    int c = MIN_CLASS;
    while (((size_t)1 << c) - HDR < n) c++;
    return c;
}

static unsigned char *heap_cut(size_t size) {
    if (!g_top) g_top = (unsigned char *)(((uintptr_t)&__heap_base + HDR - 1) & ~(uintptr_t)(HDR - 1));
    size_t have = __builtin_wasm_memory_size(0) * 65536;
    if ((uintptr_t)g_top > have || size > have - (uintptr_t)g_top) {
        size_t need = size - (have - (uintptr_t)g_top);
        if ((uintptr_t)g_top > have) need = size + ((uintptr_t)g_top - have);
        if (__builtin_wasm_memory_grow(0, (need + 65535) / 65536) == (size_t)-1) return NULL;
    }
    unsigned char *b = g_top;
    g_top += size;
    return b;
}

void *malloc(size_t n) {
    int c = class_of(n);
    if (c < 0) return NULL;
    unsigned char *b;
    if (g_free[c]) {
        b = (unsigned char *)g_free[c] - HDR;
        g_free[c] = *(void **)g_free[c];
    } else if (!(b = heap_cut((size_t)1 << c))) {
        return NULL;
    }
    *(size_t *)b = (size_t)c;
    return b + HDR;
}

void free(void *p) {
    if (!p) return;
    size_t c = *(size_t *)((unsigned char *)p - HDR);
    *(void **)p = g_free[c];
    g_free[c] = p;
}

void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    size_t cap = ((size_t)1 << *(size_t *)((unsigned char *)p - HDR)) - HDR;
    if (n <= cap) return p;
    void *q = malloc(n);
    if (!q) return NULL; /* p stays valid and unchanged */
    memcpy(q, p, cap);
    free(p);
    return q;
}

void *calloc(size_t n, size_t m) {
    if (m && n > (size_t)-1 / m) return NULL;
    void *p = malloc(n * m);
    return p ? memset(p, 0, n * m) : NULL;
}

_Noreturn void abort(void) { __builtin_trap(); }

/* memory.copy / memory.fill (bulk memory): the builtins compile to single instructions, never to a call of themselves. */
void *memcpy(void *restrict d, const void *restrict s, size_t n) {
    __builtin_memcpy(d, s, n);
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    __builtin_memmove(d, s, n);
    return d;
}
void *memset(void *p, int c, size_t n) {
    __builtin_memset(p, c, n);
    return p;
}

__attribute__((no_builtin)) int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}

__attribute__((no_builtin)) size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}
