/* Same work as main.or with growable buffers (doubling). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *p; size_t len, cap; } str;
typedef struct { int64_t *p; size_t len, cap; } arr;

static void str_add(str *s, const char *t, size_t n) {
    if (s->len + n > s->cap) {
        s->cap = (s->cap * 2 > s->len + n) ? s->cap * 2 : s->len + n;
        s->p = realloc(s->p, s->cap);
    }
    memcpy(s->p + s->len, t, n);
    s->len += n;
}

static void arr_add(arr *a, int64_t v) {
    if (a->len == a->cap) {
        a->cap = a->cap ? a->cap * 2 : 4;
        a->p = realloc(a->p, a->cap * sizeof(int64_t));
    }
    a->p[a->len++] = v;
}

typedef struct { str s; arr a; } rec;

int main(void) {
    str s = {0};
    for (int i = 0; i < 200000; i++) str_add(&s, "x", 1);
    printf("local %zu\n", s.len);
    rec r = {0};
    for (int i = 0; i < 200000; i++) str_add(&r.s, "y", 1);
    printf("field %zu\n", r.s.len);
    str b = {0};
    for (int i = 0; i < 200000; i++) str_add(&b, "z", 1);
    printf("class field %zu\n", b.len);
    rec rs[2] = {{{0}, {0}}, {{0}, {0}}};
    for (int i = 0; i < 200000; i++) str_add(&rs[1].s, "w", 1);
    printf("element %zu %zu\n", rs[1].s.len, rs[0].s.len);
    arr a = {0};
    for (int64_t i = 0; i < 100000; i++) arr_add(&a, i);
    printf("array %zu %lld\n", a.len, (long long)a.p[99999]);
    for (int64_t i = 0; i < 100000; i++) {
        arr_add(&r.a, i);
        arr_add(&r.a, i);
    }
    printf("array field %zu %lld\n", r.a.len, (long long)r.a.p[199999]);
    return 0;
}
