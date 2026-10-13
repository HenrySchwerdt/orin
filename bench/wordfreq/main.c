#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *word; size_t len; int64_t count; } Entry;
typedef struct { Entry *e; size_t len, cap; } Bucket;

static int64_t lcg(int64_t x) { return (x * 1103515245 + 12345) % 2147483648; }

static size_t hash(const char *w, size_t n) {
    size_t h = 0;
    for (size_t i = 0; i < n; i++) h = (h * 31 + (unsigned char)w[i]) % 1024;
    return h;
}

static int64_t find_idx(Bucket *buckets, size_t h, const char *w, size_t n) {
    Bucket *b = &buckets[h];
    for (size_t j = 0; j < b->len; j++)
        if (b->e[j].len == n && memcmp(b->e[j].word, w, n) == 0) return (int64_t)j;
    return -1;
}

int main(void) {
    Bucket *buckets = calloc(1024, sizeof(Bucket));
    int64_t x = 42;
    for (int n = 0; n < 1000000; n++) {
        x = lcg(x);
        char tmp[32];
        int wl = snprintf(tmp, sizeof tmp, "w%lld", (long long)((x / 65536) % 5000));
        size_t h = hash(tmp, (size_t)wl);
        int64_t idx = find_idx(buckets, h, tmp, (size_t)wl);
        if (idx >= 0) {
            buckets[h].e[idx].count++;
        } else {
            Bucket *b = &buckets[h];
            if (b->len == b->cap) {
                b->cap = b->cap ? b->cap * 2 : 4;
                b->e = realloc(b->e, b->cap * sizeof(Entry));
            }
            char *w = malloc((size_t)wl + 1);
            memcpy(w, tmp, (size_t)wl + 1);
            b->e[b->len++] = (Entry){w, (size_t)wl, 1};
        }
    }
    int64_t distinct = 0, weighted = 0, maxCount = 0;
    for (size_t i = 0; i < 1024; i++)
        for (size_t j = 0; j < buckets[i].len; j++) {
            Entry *e = &buckets[i].e[j];
            distinct++;
            weighted += e->count * (int64_t)e->len;
            if (e->count > maxCount) maxCount = e->count;
        }
    printf("distinct %lld\n", (long long)distinct);
    printf("weighted %lld\n", (long long)weighted);
    printf("max %lld\n", (long long)maxCount);
    return 0;
}
