/* The minimal C library of the WebAssembly platform layer (ADR-0055): exactly what runtime/platform/orin_platform.h and
 * runtime/core/orin_runtime.c need from libc on a freestanding wasm64 target (include/stdlib.h, include/string.h).
 * No imports: memory comes from memory.grow.
 *
 * Allocator: every block is a 16-byte header {size, size of the physically previous block} and a payload, so every payload
 * is 16-byte aligned (the orin_platform_alloc contract). `size` counts the header; its low bit marks a free large block.
 *  - Small blocks (size <= 64 KiB) are powers of two with one free list per class: the fast path, waste below 2x of a
 *    small block. A freed small block is reused by its class and never merged; a class with no free block is cut from
 *    a free large block if one has room, else from the heap top.
 *  - Large blocks are a multiple of 16 bytes, kept on one doubly linked free list (best fit, split when the remainder is
 *    itself large) and merged with free neighbours through the previous-size tag. The block ending at the heap top grows
 *    in place by extending g_top, and freeing it lowers g_top, so a growing array costs its own size, not 3x.
 * Memory is never returned to the host (an instance's memory only grows). One thread (see orin_platform_orbit.c), so no
 * locking. */
#include <stddef.h>
#include <stdint.h>

#include "include/stdlib.h"
#include "include/string.h"

enum { HDR = 16, MIN_CLASS = 5, SMALL = 65536, MAX_SIZE = (size_t)1 << 47 };

typedef size_t word;
extern unsigned char __heap_base; /* provided by wasm-ld: the first byte after the stack and the data */
static unsigned char *g_top;      /* next unused byte of the heap */
static word g_last;               /* size of the block ending at g_top */
static void *g_free[17];          /* small free lists by class, linked through the payload */
static unsigned char *g_large;    /* free large blocks: payload = {next, prev} */

#define W(b) ((word *)(b))
#define NEXT(b) (*(unsigned char **)((b) + HDR))
#define PREV(b) (*(unsigned char **)((b) + HDR + 8))

/* Set the size of block b and the previous-size tag of the block behind it. */
static void set_size(unsigned char *b, word s) {
    W(b)[0] = s;
    if (b + s == g_top) g_last = s;
    else W(b + s)[1] = s;
}

/* Make room for `size` more bytes at g_top; 0 when the host refuses to grow. */
static int heap_room(size_t size) {
    if (!g_top) g_top = (unsigned char *)(((uintptr_t)&__heap_base + HDR - 1) & ~(uintptr_t)(HDR - 1));
    size_t have = __builtin_wasm_memory_size(0) * 65536;
    if ((uintptr_t)g_top > have || size > have - (uintptr_t)g_top) {
        size_t need = size - (have - (uintptr_t)g_top);
        if ((uintptr_t)g_top > have) need = size + ((uintptr_t)g_top - have);
        if (__builtin_wasm_memory_grow(0, (need + 65535) / 65536) == (size_t)-1) return 0;
    }
    return 1;
}

static unsigned char *heap_cut(size_t size) {
    if (!heap_room(size)) return NULL;
    unsigned char *b = g_top;
    g_top += size;
    W(b)[1] = g_last;
    set_size(b, size);
    return b;
}

static void unlink_large(unsigned char *b) {
    if (PREV(b)) NEXT(PREV(b)) = NEXT(b);
    else g_large = NEXT(b);
    if (NEXT(b)) PREV(NEXT(b)) = PREV(b);
}

/* Free the large block b (its size and tag are set, the flag is clear): merge it with free neighbours; a block that then
 * ends at the heap top lowers g_top instead of being listed. */
static void free_large(unsigned char *b) {
    word s = W(b)[0];
    unsigned char *n = b + s;
    if (n != g_top && (W(n)[0] & 1)) {
        unlink_large(n);
        s += W(n)[0] & ~(word)1;
    }
    if (W(b)[1] && (W(b - W(b)[1])[0] & 1)) {
        unsigned char *p = b - W(b)[1];
        unlink_large(p);
        s += W(p)[0] & ~(word)1;
        b = p;
    }
    if (b + s == g_top) {
        g_top = b;
        g_last = W(b)[1];
        return;
    }
    set_size(b, s);
    W(b)[0] |= 1;
    NEXT(b) = g_large;
    PREV(b) = NULL;
    if (g_large) PREV(g_large) = b;
    g_large = b;
}

/* Shrink the large block b to `need` bytes and free the tail if it is itself a large block. */
static void trim(unsigned char *b, word need) {
    word s = W(b)[0];
    if (s - need <= SMALL) return;
    set_size(b, need);
    set_size(b + need, s - need);
    free_large(b + need);
}

void *malloc(size_t n) {
    if (n > MAX_SIZE - HDR) return NULL;
    unsigned char *b;
    if (n + HDR <= SMALL) {
        int c = MIN_CLASS;
        while (((size_t)1 << c) - HDR < n) c++;
        if (g_free[c]) {
            b = (unsigned char *)g_free[c] - HDR;
            g_free[c] = *(void **)g_free[c];
        } else if (g_large && (W(g_large)[0] & ~(word)1) - ((size_t)1 << c) > SMALL) {
            b = g_large; /* a free large block has room: cut the small block from its start, so holes get reused */
            unlink_large(b);
            W(b)[0] &= ~(word)1;
            trim(b, (size_t)1 << c);
        } else if (!(b = heap_cut((size_t)1 << c))) {
            return NULL;
        }
    } else {
        word need = (n + HDR + 15) & ~(size_t)15, best = (word)-1;
        b = NULL;
        for (unsigned char *f = g_large; f; f = NEXT(f)) {
            word s = W(f)[0] & ~(word)1;
            if (s >= need && s < best) b = f, best = s;
        }
        if (b) {
            unlink_large(b);
            W(b)[0] = best;
            trim(b, need);
        } else if (!(b = heap_cut(need))) {
            return NULL;
        }
    }
    return b + HDR;
}

void free(void *p) {
    if (!p) return;
    unsigned char *b = (unsigned char *)p - HDR;
    if (W(b)[0] > SMALL) {
        free_large(b);
        return;
    }
    int c = __builtin_ctzl(W(b)[0]);
    *(void **)p = g_free[c];
    g_free[c] = p;
}

void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    unsigned char *b = (unsigned char *)p - HDR;
    word s = W(b)[0];
    if (n <= s - HDR) {
        if (s > SMALL) trim(b, n + HDR > SMALL ? (n + HDR + 15) & ~(size_t)15 : SMALL + 16);
        return p;
    }
    if (s > SMALL && n <= MAX_SIZE - HDR) { /* a large block: grow in place into the heap top or a free neighbour */
        word need = (n + HDR + 15) & ~(size_t)15;
        unsigned char *nx = b + s;
        if (nx == g_top) {
            if (!heap_room(need - s)) return NULL;
            g_top += need - s;
            set_size(b, need);
            return p;
        }
        if ((W(nx)[0] & 1) && s + (W(nx)[0] & ~(word)1) >= need) {
            word t = s + (W(nx)[0] & ~(word)1);
            unlink_large(nx);
            set_size(b, t);
            trim(b, need);
            return p;
        }
    }
    void *q = malloc(n);
    if (!q) return NULL; /* p stays valid and unchanged */
    memcpy(q, p, s - HDR);
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
