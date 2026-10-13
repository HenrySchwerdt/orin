#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

/* NULL child plays the role of Orin's `Leaf` variant. */
typedef struct Node {
    struct Node *l, *r;
} Node;

static Node *build(int64_t d) {
    Node *n = malloc(sizeof(Node));
    if (d == 0) {
        n->l = n->r = NULL;
    } else {
        n->l = build(d - 1);
        n->r = build(d - 1);
    }
    return n;
}
static int64_t check(Node *t) { return t ? 1 + check(t->l) + check(t->r) : 0; }
static void drop(Node *t) {
    if (!t) return;
    drop(t->l);
    drop(t->r);
    free(t);
}

int main(void) {
    const int64_t maxDepth = 16;
    Node *longLived = build(maxDepth);
    int64_t total = 0;
    for (int64_t d = 4; d <= maxDepth; d += 4) {
        int64_t iters = 1;
        for (int64_t k = 0; k < 22 - d; k++) iters *= 2;
        int64_t sum = 0;
        for (int64_t i = 0; i < iters; i++) {
            Node *t = build(d);
            sum += check(t);
            drop(t);
        }
        printf("depth %lld trees %lld check %lld\n", (long long)d, (long long)iters, (long long)sum);
        total += sum;
    }
    printf("long lived check %lld\n", (long long)check(longLived));
    printf("total %lld\n", (long long)total);
    return 0;
}
