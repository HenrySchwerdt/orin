/* Same algorithm as main.or: a binary min-heap of (priority, value) pairs in a growable array. Ties between equal
 * priorities are not FIFO here; the checksums only depend on the popped priorities. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int64_t prio, val; } item;
static item *heap;
static int64_t n, cap;

static void push(int64_t prio, int64_t val) {
    if (n == cap) {
        cap = cap ? cap * 2 : 16;
        heap = realloc(heap, (size_t)cap * sizeof(item));
    }
    int64_t i = n++;
    while (i > 0) {
        int64_t p = (i - 1) / 2;
        if (heap[p].prio <= prio) break;
        heap[i] = heap[p];
        i = p;
    }
    heap[i].prio = prio;
    heap[i].val = val;
}

static item pop(void) {
    item top = heap[0];
    item last = heap[--n];
    int64_t i = 0;
    for (;;) {
        int64_t c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && heap[c + 1].prio < heap[c].prio) c++;
        if (heap[c].prio >= last.prio) break;
        heap[i] = heap[c];
        i = c;
    }
    if (n > 0) heap[i] = last;
    return top;
}

static int64_t next_rand(int64_t s) { return (s * 1103515245 + 12345) % 2147483648LL; }

int main(void) {
    int64_t seed = 1;
    for (int64_t i = 0; i < 200000; i++) {
        seed = next_rand(seed);
        push(seed % 1000003, i);
    }
    printf("size %lld\n", (long long)n);
    int64_t check = 0;
    for (int64_t i = 0; i < 400000; i++) {
        seed = next_rand(seed);
        push(seed % 1000003, i);
        item e = pop();
        check = (check * 31 + e.prio) % 1000000007;
    }
    printf("interleaved %lld size %lld\n", (long long)check, (long long)n);
    int64_t cnt = 0, sum = 0, last = -1;
    int ordered = 1;
    while (n > 0) {
        item e = pop();
        if (e.prio < last) ordered = 0;
        last = e.prio;
        cnt++;
        sum = (sum + e.prio * (cnt % 1000)) % 1000000007;
    }
    printf("drained %lld ordered %s sum %lld\n", (long long)cnt, ordered ? "true" : "false", (long long)sum);
    return 0;
}
