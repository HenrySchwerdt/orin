/* Compiler support routines of the WebAssembly platform layer (ADR-0055): the calls clang emits for operations that have
 * no WebAssembly instruction, which a freestanding wasm64 link has no compiler-rt or libm for. Only <stdint.h>, so
 * runtime/platform/orbit/tests/i128_test.c can include this file natively and compare it with the compiler's own code. */
#include <stdint.h>

/* round (half away from zero): the C backend emits __builtin_round, which has no WebAssembly instruction (floor, ceil, trunc,
 * sqrt have one). x - trunc(x) is exact, so the comparison with 0.5 is too; NaN and infinities fall through unchanged. */
double round(double x) {
    double t = __builtin_trunc(x);
    if (__builtin_fabs(x - t) >= 0.5) t += __builtin_copysign(1.0, x);
    return t;
}

/* ---------------------------------------------------------------- 128-bit integer helpers (compiler-rt ABI)
 * The runtime's integer-kind checks use __int128 (orin_runtime.c); clang lowers its multiplication and variable shifts to
 * these calls, which a freestanding wasm64 link has no compiler-rt for. Written on 64-bit halves, so they never call
 * themselves. */
typedef union {
    __int128 s;
    unsigned __int128 u;
    struct {
        uint64_t lo, hi; /* little endian */
    } w;
} I128;

static unsigned __int128 u128(uint64_t hi, uint64_t lo) {
    I128 r;
    r.w.lo = lo, r.w.hi = hi;
    return r.u;
}

__int128 __multi3(__int128 a, __int128 b) {
    I128 x, y;
    x.s = a, y.s = b;
    uint64_t a0 = x.w.lo & 0xffffffffu, a1 = x.w.lo >> 32, b0 = y.w.lo & 0xffffffffu, b1 = y.w.lo >> 32;
    uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    uint64_t mid = (p00 >> 32) + (p01 & 0xffffffffu) + (p10 & 0xffffffffu);
    uint64_t lo = (p00 & 0xffffffffu) | (mid << 32);
    uint64_t hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32) + x.w.lo * y.w.hi + x.w.hi * y.w.lo;
    I128 r;
    r.u = u128(hi, lo);
    return r.s;
}

__int128 __ashlti3(__int128 a, int n) {
    I128 x;
    x.s = a;
    if (n == 0) return a;
    if (n >= 64) x.u = u128(x.w.lo << (n - 64), 0);
    else x.u = u128((x.w.hi << n) | (x.w.lo >> (64 - n)), x.w.lo << n);
    return x.s;
}

__int128 __lshrti3(__int128 a, int n) {
    I128 x;
    x.s = a;
    if (n == 0) return a;
    if (n >= 64) x.u = u128(0, x.w.hi >> (n - 64));
    else x.u = u128(x.w.hi >> n, (x.w.lo >> n) | (x.w.hi << (64 - n)));
    return x.s;
}

__int128 __ashrti3(__int128 a, int n) {
    I128 x;
    x.s = a;
    if (n == 0) return a;
    int64_t hi = (int64_t)x.w.hi;
    if (n >= 64) x.u = u128((uint64_t)(hi >> 63), (uint64_t)(hi >> (n - 64)));
    else x.u = u128((uint64_t)(hi >> n), (x.w.lo >> n) | (x.w.hi << (64 - n)));
    return x.s;
}
