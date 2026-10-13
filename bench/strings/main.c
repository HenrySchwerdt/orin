#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *p; size_t len, cap; } Buf;
static void buf_append(Buf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap * 2;
        if (cap < b->len + n + 1) cap = b->len + n + 1;
        if (cap < 16) cap = 16;
        b->p = realloc(b->p, cap);
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}

int main(void) {
    Buf s = {0};
    for (int64_t i = 0; i < 500000; i++) {
        char t[48];
        int n = snprintf(t, sizeof t, "item%lld,", (long long)i);
        buf_append(&s, t, (size_t)n);
    }
    /* split on "," into separately allocated parts */
    size_t pcap = 4, plen = 0;
    char **parts = malloc(pcap * sizeof(char *));
    size_t *plens = malloc(pcap * sizeof(size_t));
    size_t start = 0;
    for (size_t i = 0; i <= s.len; i++) {
        if (i == s.len || s.p[i] == ',') {
            if (plen == pcap) {
                pcap *= 2;
                parts = realloc(parts, pcap * sizeof(char *));
                plens = realloc(plens, pcap * sizeof(size_t));
            }
            size_t n = i - start;
            char *q = malloc(n + 1);
            memcpy(q, s.p + start, n);
            q[n] = 0;
            parts[plen] = q;
            plens[plen++] = n;
            start = i + 1;
        }
    }
    /* join with ";" */
    size_t total = 0;
    for (size_t i = 0; i < plen; i++) total += plens[i];
    if (plen > 1) total += plen - 1;
    char *joined = malloc(total + 1);
    size_t pos = 0;
    for (size_t i = 0; i < plen; i++) {
        if (i) joined[pos++] = ';';
        memcpy(joined + pos, parts[i], plens[i]);
        pos += plens[i];
    }
    joined[pos] = 0;
    int64_t sum = 0, nonEmpty = 0;
    for (size_t i = 0; i < plen; i++) {
        if (plens[i] > 0) {
            sum += strtoll(parts[i] + 4, NULL, 10);
            nonEmpty++;
        }
    }
    printf("len %zu\n", s.len);
    printf("parts %zu nonEmpty %lld\n", plen, (long long)nonEmpty);
    printf("joined %zu\n", total);
    printf("sum %lld\n", (long long)sum);
    for (size_t i = 0; i < plen; i++) free(parts[i]);
    free(parts); free(plens); free(joined); free(s.p);
    return 0;
}
