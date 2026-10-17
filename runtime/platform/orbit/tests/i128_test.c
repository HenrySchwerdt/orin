/* Native differential test of orin_builtins_orbit.c (tools/test_wasm.sh): the helpers, renamed, against the compiler's own
 * __int128 arithmetic and round() of libm, over random operands and every shift count. Exit 1 on any mismatch. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#define __multi3 t_multi3
#define __ashlti3 t_ashlti3
#define __lshrti3 t_lshrti3
#define __ashrti3 t_ashrti3
#define round t_round
#include "../orin_builtins_orbit.c"
#undef round

static uint64_t r64(void) { return ((uint64_t)rand() << 62) ^ ((uint64_t)rand() << 31) ^ (uint64_t)rand(); }

int main(void) {
    long bad = 0, n = 0;
    srand(1);
    for (int i = 0; i < 1000000; i++) {
        __int128 a = (__int128)(((unsigned __int128)r64() << 64) | r64());
        __int128 b = i % 3 ? (__int128)(((unsigned __int128)r64() << 64) | r64()) : (__int128)(int64_t)r64();
        int s = i % 128;
        bad += t_multi3(a, b) != (__int128)((unsigned __int128)a * (unsigned __int128)b);
        bad += t_ashlti3(a, s) != (__int128)((unsigned __int128)a << s);
        bad += t_lshrti3(a, s) != (__int128)((unsigned __int128)a >> s);
        bad += t_ashrti3(a, s) != a >> s;
        n += 4;
    }
    double xs[] = {0.0, -0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 0.49999999999999994, 4503599627370495.5, 4503599627370497.0,
                   1e300, -1e-300, INFINITY, -INFINITY};
    for (size_t i = 0; i < sizeof xs / sizeof xs[0]; i++, n++) {
        double w = round(xs[i]), g = t_round(xs[i]);
        bad += w != g || signbit(w) != signbit(g);
    }
    for (int i = 0; i < 1000000; i++, n++) {
        union { uint64_t u; double d; } v = {r64()};
        double w = round(v.d), g = t_round(v.d);
        if (isnan(w)) bad += !isnan(g);
        else bad += w != g || signbit(w) != signbit(g);
    }
    printf("i128_test: %ld checks, %ld mismatches\n", n, bad);
    return bad != 0;
}
