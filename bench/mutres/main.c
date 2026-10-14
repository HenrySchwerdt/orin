/* Same work as main.or: structs and functions taking a pointer. */
#include <stdint.h>
#include <stdio.h>

typedef struct { const int64_t *data; int64_t len; int64_t pos; } reader;
typedef struct { reader r; int64_t total; } q;

static int64_t next(reader *r) {
    int64_t v = r->data[r->pos];
    r->pos++;
    if (r->pos == r->len) r->pos = 0;
    return v;
}
static void skip(reader *r) {
    r->pos++;
    if (r->pos == r->len) r->pos = 0;
}
static int64_t cur(const reader *r) { return r->data[r->pos]; }
static int64_t step_ret(q *x) {
    int64_t v = next(&x->r);
    x->total += v;
    return v;
}
static void step_void(q *x) {
    x->total += cur(&x->r);
    skip(&x->r);
}

int main(void) {
    static const int64_t d[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    q qq = {{d, 16, 0}, 0};
    reader r = {d, 16, 0};
    int64_t sum = 0;
    for (int i = 0; i < 10000000; i++) sum += next(&r);
    printf("ret %lld %lld\n", (long long)sum, (long long)r.pos);
    for (int i = 0; i < 10000000; i++) {
        skip(&r);
        sum += cur(&r);
    }
    printf("void %lld %lld\n", (long long)sum, (long long)r.pos);
    for (int i = 0; i < 10000000; i++) sum += step_ret(&qq);
    printf("nested ret %lld %lld\n", (long long)sum, (long long)qq.total);
    for (int i = 0; i < 10000000; i++) step_void(&qq);
    printf("nested void %lld %lld\n", (long long)qq.total, (long long)qq.r.pos);
    return 0;
}
