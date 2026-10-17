/* Native stress test of the allocator in orin_libc_orbit.c (tools/test_wasm.sh): the file is compiled into this program with
 * its libc names renamed, on a fake heap (an mmap'd region grown by a stand-in for memory.grow). Random malloc / calloc /
 * realloc / free over small, large and huge sizes, checking alignment, that payloads survive realloc, that live blocks never
 * overlap, that calloc is zeroed, that failures leave the old block valid, and that the sieve-like growth pattern (an array
 * grown by repeated realloc) peaks below 1.5x its final size. Exit 1 on any failure. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define malloc t_malloc
#define free t_free
#define realloc t_realloc
#define calloc t_calloc
#define abort t_abort
#define memcpy t_memcpy
#define memmove t_memmove
#define memset t_memset
#define memcmp t_memcmp
#define strlen t_strlen
#define HEAP_MAX ((size_t)3 << 30)
static unsigned char *g_hbp; /* the fake heap: base of the mapping, page aligned */
static size_t g_pages;       /* committed pages, counted from address 0 like wasm memory */
#define __heap_base (*g_hbp)
#define __builtin_wasm_memory_size(m) (g_pages)
#define __builtin_wasm_memory_grow(m, d) fake_grow(d)
static size_t fake_grow(size_t d) {
    size_t old = g_pages;
    if (d > ((uintptr_t)g_hbp + HEAP_MAX) / 65536 - old) return (size_t)-1;
    g_pages += d;
    return old;
}
#include "../orin_libc_orbit.c"
#undef malloc
#undef free
#undef realloc
#undef calloc
#undef memcpy
#undef memset

static uint64_t rs = 88172645463325252ull;
static uint64_t rnd(void) {
    rs ^= rs << 13, rs ^= rs >> 7, rs ^= rs << 17;
    return rs;
}
static long bad;
#define CHECK(c, ...) do { if (!(c) && bad++ < 20) { fprintf(stderr, "FAIL line %d: ", __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

typedef struct { unsigned char *p; size_t n; unsigned char seed; } Slot;
/* Payload bytes checked: the first and last 64 and every 509th, so multi-MB blocks stay cheap. */
static size_t nxt(size_t i, size_t n) {
    size_t t = n > 64 ? n - 64 : 0, j = i < 63 ? i + 1 : (i / 509 + 1) * 509;
    return i >= t ? i + 1 : j > t ? t : j;
}
#define EACH(i, n) for (size_t i = 0; i < (n); i = nxt(i, (n)))
#define BYTE(s, i) ((unsigned char)((s)->seed + (i) * 7))
static void fill(Slot *s) { EACH(i, s->n) s->p[i] = BYTE(s, i); }
/* m bytes are compared against the fill of s->n bytes (after a realloc s->n is still the old size). */
static int verify(Slot *s, size_t m) {
    EACH(i, s->n) if (i < m && s->p[i] != BYTE(s, i)) return 0;
    return 1;
}
static size_t pick(void) {
    uint64_t r = rnd() % 1000;
    if (r < 700) return rnd() % 300;
    if (r < 900) return rnd() % 20000;
    if (r < 995) return 40000 + rnd() % 400000;
    return 1000000 + rnd() % 4000000;
}
static int cmp(const void *a, const void *b) { const Slot *x = a, *y = b; return x->p < y->p ? -1 : x->p > y->p; }
static void overlaps(Slot *live, int cap, Slot *tmp) {
    int k = 0;
    for (int i = 0; i < cap; i++) if (live[i].p) tmp[k++] = live[i];
    qsort(tmp, k, sizeof *tmp, cmp);
    for (int i = 0; i < k; i++) {
        CHECK(((uintptr_t)tmp[i].p & 15) == 0, "payload %p not 16-byte aligned", (void *)tmp[i].p);
        CHECK(tmp[i].p >= g_hbp && tmp[i].p + tmp[i].n <= g_top, "block outside the heap");
        if (i + 1 < k) CHECK(tmp[i].p + tmp[i].n <= tmp[i + 1].p - HDR, "blocks overlap or share a header");
    }
}

static void stress(long ops, int cap) {
    Slot *live = calloc(cap, sizeof *live), *tmp = calloc(cap, sizeof *live);
    for (long op = 0; op < ops; op++) {
        Slot *s = &live[rnd() % cap];
        switch (rnd() % 4) {
        case 0: case 1:
            if (s->p) { CHECK(verify(s, s->n), "payload damaged"); t_free(s->p); s->p = NULL; }
            else {
                s->n = pick(); s->seed = (unsigned char)rnd();
                s->p = (rnd() & 3) ? t_malloc(s->n) : t_calloc(1, s->n);
                CHECK(s->p != NULL, "malloc %zu failed", s->n);
                fill(s);
            }
            break;
        case 2:
            if (s->p) {
                size_t m = rnd() & 1 ? pick() : s->n + rnd() % 5000;
                unsigned char *q = t_realloc(s->p, m);
                CHECK(q != NULL, "realloc %zu -> %zu failed", s->n, m);
                if (!q) break;
                s->p = q;
                CHECK(verify(s, m < s->n ? m : s->n), "realloc lost the payload (%zu -> %zu)", s->n, m);
                s->n = m;
                fill(s);
            }
            break;
        default:
            if (!s->p) {
                s->n = pick(); s->seed = 0;
                s->p = t_calloc(s->n, 1);
                CHECK(s->p != NULL, "calloc failed");
                for (size_t i = 0; i < s->n; i += (s->n < 100000 ? 1 : 61)) if (s->p[i]) { CHECK(0, "calloc not zeroed"); break; }
                fill(s);
            }
        }
        if (op % 20000 == 0) overlaps(live, cap, tmp);
    }
    overlaps(live, cap, tmp);
    for (int i = 0; i < cap; i++) if (live[i].p) { CHECK(verify(&live[i], live[i].n), "payload damaged at the end"); t_free(live[i].p); }
    free(live); free(tmp);
}

/* A realloc-grown array (bench/sieve): the heap must stay below 1.5x the final size, with and without small allocations
 * between the growth steps. */
static void reset_heap(void) { memset(g_free, 0, sizeof g_free); g_large = NULL; g_top = NULL; g_last = 0; }
static void growth(size_t final, double factor, int interleave) {
    reset_heap();
    size_t n = 16, peak = 0;
    unsigned char *a = t_malloc(n);
    memset(a, 0xAB, n);
    while (n < final) {
        size_t m = (size_t)(n * factor) + 8;
        if (m > final) m = final;
        if (interleave) { void *x = t_malloc(40); CHECK(x != NULL, "small malloc"); }
        unsigned char *q = t_realloc(a, m);
        CHECK(q != NULL, "grow failed");
        CHECK(q[0] == 0xAB && q[n - 1] == 0xAB, "array lost on growth");
        a = q;
        memset(a + n, 0xAB, m - n);
        n = m;
        if ((size_t)(g_top - g_hbp) > peak) peak = g_top - g_hbp;
    }
    double ratio = (double)peak / (double)final;
    printf("growth final=%zu factor=%.2f interleave=%d: heap peak %.2fx\n", final, factor, interleave, ratio);
    CHECK(ratio < 1.5, "heap peak %.2fx of the final size", ratio);
    t_free(a);
}


int main(void) {
    g_hbp = mmap(NULL, HEAP_MAX, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (g_hbp == MAP_FAILED) { perror("mmap"); return 1; }
    g_hbp += 4096; /* __heap_base is not page aligned: the data segment ends mid page */
    g_pages = ((uintptr_t)g_hbp + 65535) / 65536;

    CHECK(t_malloc(0) != NULL, "malloc(0)");
    CHECK(t_calloc((size_t)1 << 62, 4) == NULL, "calloc overflow");
    CHECK(t_malloc((size_t)1 << 48) == NULL, "huge malloc");
    unsigned char *a = t_malloc(100000);
    memset(a, 7, 100000);
    CHECK(t_realloc(a, (size_t)1 << 40) == NULL && a[0] == 7 && a[99999] == 7, "failed realloc must keep the old block");
    unsigned char *s = t_malloc(10);
    memset(s, 9, 10);
    CHECK(t_realloc(s, (size_t)1 << 40) == NULL && s[9] == 9, "failed small realloc must keep the old block");
    t_free(a); t_free(s);

    stress(1000000, 400);
    reset_heap();
    stress(1000000, 60);
    reset_heap();
    stress(500000, 3000);
    reset_heap();
    growth(80u << 20, 1.5, 0);
    growth(80u << 20, 1.5, 1);
    growth(80u << 20, 2.0, 1);
    growth(80u << 20, 1.1, 1);
    growth(80u << 20, 1.0001, 0);
    printf("alloc_test: %s\n", bad ? "FAILED" : "ok");
    return bad != 0;
}
