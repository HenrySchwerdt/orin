#include <stdio.h>
#include <string.h>

#define CAP 131072
static char keys[CAP][16];
static long long vals[CAP];
static int used[CAP];
static int distinct;

static unsigned long hash(const char *s) {
    unsigned long h = 5381;
    while (*s) h = h * 131 + (unsigned char)*s++;
    return h;
}

static long long *slot(const char *k) {
    unsigned long i = hash(k) % CAP;
    while (used[i] && strcmp(keys[i], k) != 0) i = (i + 1) % CAP;
    if (!used[i]) {
        used[i] = 1;
        strcpy(keys[i], k);
        distinct++;
    }
    return &vals[i];
}

int main(void) {
    char key[16];
    for (int i = 0; i < 1000000; i++) {
        snprintf(key, sizeof key, "w%d", (int)(((long long)i * 7919) % 50000));
        *slot(key) += 1;
    }
    long long check = 0;
    for (int i = 0; i < CAP; i++)
        if (used[i]) check += vals[i] * (long long)strlen(keys[i]);
    printf("distinct: %d\n", distinct);
    printf("check: %lld\n", check);
    printf("w123: %lld\n", *slot("w123"));
    return 0;
}
