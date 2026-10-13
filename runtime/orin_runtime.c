/* Orin runtime implementation. API and conventions: orin_runtime.h */
#define _GNU_SOURCE
#include "orin_runtime.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int64_t g_live;
OrinStats orin_stats;

/* Accounting helpers: called wherever g_live changes / buffers are (re)allocated. */
static inline void stat_alloc(uint64_t *kind_counter, uint64_t bytes) {
    (*kind_counter)++;
    orin_stats.live_bytes += bytes;
    if (orin_stats.live_bytes > orin_stats.peak_live_bytes) orin_stats.peak_live_bytes = orin_stats.live_bytes;
    if ((uint64_t)g_live > orin_stats.peak_live_objs) orin_stats.peak_live_objs = (uint64_t)g_live;
}

static void stats_report(void) {
    const char *e = getenv("ORIN_STATS");
    if (!e || strcmp(e, "1") != 0) return;
    const OrinStats *s = &orin_stats;
    fprintf(stderr,
            "{\"orin_stats\":{\"alloc_string\":%llu,\"alloc_array\":%llu,\"alloc_struct\":%llu,"
            "\"alloc_total\":%llu,\"frees\":%llu,\"retains\":%llu,\"releases\":%llu,"
            "\"cow_copies\":%llu,\"cow_inplace\":%llu,\"array_grows\":%llu,\"string_grows\":%llu,"
            "\"peak_live_objs\":%llu,\"peak_live_bytes\":%llu,\"live_objs_at_exit\":%lld}}\n",
            (unsigned long long)s->alloc_string, (unsigned long long)s->alloc_array,
            (unsigned long long)s->alloc_struct,
            (unsigned long long)(s->alloc_string + s->alloc_array + s->alloc_struct),
            (unsigned long long)s->frees, (unsigned long long)s->retains,
            (unsigned long long)s->releases, (unsigned long long)s->cow_copies,
            (unsigned long long)s->cow_inplace, (unsigned long long)s->array_grows,
            (unsigned long long)s->string_grows, (unsigned long long)s->peak_live_objs,
            (unsigned long long)s->peak_live_bytes, (long long)g_live);
}
static int g_argc;
static char **g_argv;

int64_t orin_live_count(void) { return g_live; }

void orin_init(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
    atexit(stats_report);
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
}

void orin_flush(void) { fflush(stdout); }

void orin_trap(const char *msg) {
    fflush(stdout);
    fprintf(stderr, "trap: %s\n", msg);
    fflush(stderr);
    exit(101);
}

/* Size-class freelists for small struct objects (by slot count) and array headers. Objects are
 * recycled, never returned to malloc. Disabled under ASan (so use-after-free is still detected)
 * or with -DORIN_NO_FREELIST. */
#if !defined(ORIN_NO_FREELIST)
#if defined(__SANITIZE_ADDRESS__)
#define ORIN_NO_FREELIST 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(memory_sanitizer)
#define ORIN_NO_FREELIST 1
#endif
#endif
#endif
#ifndef ORIN_NO_FREELIST
enum { FL_STRUCT_CLASSES = 9 }; /* nslots 0..8 */
typedef struct FreeNode { struct FreeNode *next; } FreeNode;
static FreeNode *fl_struct[FL_STRUCT_CLASSES];
static FreeNode *fl_array;
#endif

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) orin_trap("out of memory");
    return p;
}
static void *xrealloc(void *q, size_t n) {
    void *p = realloc(q, n ? n : 1);
    if (!p) orin_trap("out of memory");
    return p;
}

/* ---------------------------------------------------------------- destroy */

void orin_destroy(OrinObj *o) {
    /* Iterative so that long chains (lists, deep trees) cannot overflow the C stack. */
    static OrinObj **stack;
    static size_t sp, scap;
    sp = 0;
#define PUSH(x)                                                                                 \
    do {                                                                                        \
        if (sp == scap) {                                                                       \
            scap = scap ? scap * 2 : 256;                                                       \
            stack = (OrinObj **)xrealloc(stack, scap * sizeof(OrinObj *));                      \
        }                                                                                       \
        stack[sp++] = (x);                                                                      \
    } while (0)
#define DEC(c)                                                                                  \
    do {                                                                                        \
        OrinObj *c_ = (c);                                                                      \
        if (c_ && c_->rc > 0) {                                                                 \
            orin_stats.releases++;                                                              \
            if (--c_->rc == 0) PUSH(c_);                                                        \
        }                                                                                       \
    } while (0)
    PUSH(o);
    while (sp) {
        OrinObj *x = stack[--sp];
        switch (x->kind) {
        case ORIN_K_ARRAY: {
            OrinArray *a = (OrinArray *)x;
            if (a->is_ref)
                for (uint64_t i = 0; i < a->len; i++) DEC(ORIN_REF(a->items[i]));
            orin_stats.live_bytes -= sizeof(OrinArray) + a->cap * 8;
            free(a->items);
#ifndef ORIN_NO_FREELIST
            ((FreeNode *)x)->next = fl_array;
            fl_array = (FreeNode *)x;
            g_live--;
            orin_stats.frees++;
            continue;
#endif
            break;
        }
        case ORIN_K_STRUCT: {
            OrinStruct *s = (OrinStruct *)x;
            for (uint32_t i = 0; i < s->nslots; i++)
                if ((s->refmask >> i) & 1) DEC(ORIN_REF(s->slots[i]));
            orin_stats.live_bytes -= sizeof(OrinStruct) + (uint64_t)s->nslots * 8;
#ifndef ORIN_NO_FREELIST
            if (s->nslots < FL_STRUCT_CLASSES) {
                ((FreeNode *)x)->next = fl_struct[s->nslots];
                fl_struct[s->nslots] = (FreeNode *)x;
                g_live--;
                orin_stats.frees++;
                continue;
            }
#endif
            break;
        }
        default: orin_stats.live_bytes -= sizeof(OrinString) + ((OrinString *)x)->cap + 1; break;
        }
        free(x);
        g_live--;
        orin_stats.frees++;
    }
#undef PUSH
#undef DEC
}

/* ---------------------------------------------------------------- structs */

OrinObj *orin_struct_new(uint32_t tag, uint32_t nslots, uint64_t refmask) {
    if (nslots > 64) orin_trap("struct has more than 64 slots");
    OrinStruct *s;
#ifndef ORIN_NO_FREELIST
    if (nslots < FL_STRUCT_CLASSES && fl_struct[nslots]) {
        FreeNode *n = fl_struct[nslots];
        fl_struct[nslots] = n->next;
        s = (OrinStruct *)n;
    } else
#endif
        s = (OrinStruct *)xmalloc(sizeof(OrinStruct) + (size_t)nslots * 8);
    s->h.rc = 1;
    s->h.kind = ORIN_K_STRUCT;
    s->h.tag = tag;
    s->nslots = nslots;
    s->pad = 0;
    s->refmask = refmask;
    memset(s->slots, 0, (size_t)nslots * 8);
    g_live++;
    stat_alloc(&orin_stats.alloc_struct, sizeof(OrinStruct) + (uint64_t)nslots * 8);
    return &s->h;
}

OrinObj *orin_nullary(uint32_t tag) {
    enum { N = 1024 };
    static OrinObj *tbl[N];
    if (tag >= N) orin_trap("variant tag too large");
    if (!tbl[tag]) {
        OrinObj *o = orin_struct_new(tag, 0, 0);
        o->rc = -1;
        g_live--; /* immortal: not counted */
        orin_stats.alloc_struct--;
        orin_stats.live_bytes -= sizeof(OrinStruct);
        tbl[tag] = o;
    }
    return tbl[tag];
}

OrinObj *orin_variant1(uint32_t tag, uint64_t refmask, uint64_t slot) {
    OrinObj *o = orin_struct_new(tag, 1, refmask & 1);
    ((OrinStruct *)o)->slots[0] = slot;
    return o;
}

void orin_struct_copy_slot(OrinObj *dst, uint32_t i, OrinObj *src, uint32_t j) {
    OrinStruct *d = (OrinStruct *)dst;
    uint64_t v = ((OrinStruct *)src)->slots[j];
    if ((d->refmask >> i) & 1) orin_retain(ORIN_REF(v));
    d->slots[i] = v;
}

uint64_t orin_opt_unwrap(OrinObj *o) {
    if (o->tag != 0) orin_trap("unwrap on None");
    return orin_struct_get(o, 0);
}
uint64_t orin_res_unwrap(OrinObj *o) {
    if (o->tag != 0) orin_trap("unwrap on Err");
    return ((OrinStruct *)o)->nslots ? orin_struct_get(o, 0) : 0;
}
uint64_t orin_res_unwrap_err(OrinObj *o) {
    if (o->tag != 1) orin_trap("unwrapErr on Ok");
    return orin_struct_get(o, 0);
}

/* ---------------------------------------------------------------- make_unique */

OrinObj *orin_make_unique_slow(OrinObj *o) {
    orin_stats.cow_copies++;
    OrinObj *r;
    switch (o->kind) {
    case ORIN_K_STRUCT: {
        OrinStruct *s = (OrinStruct *)o;
        r = orin_struct_new(o->tag, s->nslots, s->refmask);
        OrinStruct *d = (OrinStruct *)r;
        for (uint32_t i = 0; i < s->nslots; i++) {
            d->slots[i] = s->slots[i];
            if ((s->refmask >> i) & 1) orin_retain(ORIN_REF(s->slots[i]));
        }
        break;
    }
    case ORIN_K_ARRAY: {
        OrinArray *a = (OrinArray *)o;
        r = orin_array_new(a->len, (int64_t)a->is_ref);
        OrinArray *d = (OrinArray *)r;
        for (uint64_t i = 0; i < a->len; i++) {
            d->items[i] = a->items[i];
            if (a->is_ref) orin_retain(ORIN_REF(a->items[i]));
        }
        d->len = a->len;
        break;
    }
    default: r = orin_str_new(((OrinString *)o)->data, ((OrinString *)o)->len); break;
    }
    orin_release(o);
    return r;
}

/* ---------------------------------------------------------------- strings */

static OrinString *str_alloc(uint64_t len, uint64_t cap) {
    if (cap < len) cap = len;
    if (cap > ((uint64_t)1 << 48)) orin_trap("string too large");
    OrinString *s = (OrinString *)xmalloc(sizeof(OrinString) + cap + 1);
    s->h.rc = 1;
    s->h.kind = ORIN_K_STRING;
    s->h.tag = 0;
    s->len = len;
    s->cap = cap;
    s->data[len] = 0;
    g_live++;
    stat_alloc(&orin_stats.alloc_string, sizeof(OrinString) + cap + 1);
    return s;
}

OrinObj *orin_str_new(const char *p, uint64_t n) {
    OrinString *s = str_alloc(n, n);
    if (n) memcpy(s->data, p, n);
    return &s->h;
}

OrinObj *orin_str_concat(OrinObj *a, OrinObj *b) {
    OrinString *x = (OrinString *)a, *y = (OrinString *)b;
    if (y->len == 0) return orin_dup(a);
    if (x->len == 0) return orin_dup(b);
    OrinString *r = str_alloc(x->len + y->len, x->len + y->len);
    memcpy(r->data, x->data, x->len);
    memcpy(r->data + x->len, y->data, y->len);
    return &r->h;
}

OrinObj *orin_str_append(OrinObj *a, OrinObj *b) {
    OrinString *x = (OrinString *)a, *y = (OrinString *)b;
    if (y->len == 0) return a;
    uint64_t n = x->len + y->len;
    if (a->rc == 1 && a != b) {
        if (n > x->cap) {
            uint64_t cap = x->cap * 2;
            if (cap < n) cap = n;
            if (cap < 16) cap = 16;
            x = (OrinString *)xrealloc(x, sizeof(OrinString) + cap + 1);
            orin_stats.live_bytes += cap - x->cap;
            orin_stats.string_grows++;
            x->cap = cap;
        }
        memcpy(x->data + x->len, y->data, y->len);
        x->len = n;
        x->data[n] = 0;
        return &x->h;
    }
    OrinString *r = str_alloc(n, n + n / 2 + 8);
    if (x->len) memcpy(r->data, x->data, x->len);
    memcpy(r->data + x->len, y->data, y->len);
    orin_release(a);
    return &r->h;
}

int64_t orin_str_eq(OrinObj *a, OrinObj *b) {
    if (a == b) return 1;
    OrinString *x = (OrinString *)a, *y = (OrinString *)b;
    return x->len == y->len && memcmp(x->data, y->data, x->len) == 0;
}

static OrinObj *char_string(unsigned c) {
    static OrinObj *tbl[256];
    if (!tbl[c]) {
        char ch = (char)c;
        OrinObj *o = orin_str_new(&ch, 1);
        o->rc = -1;
        g_live--;
        orin_stats.alloc_string--;
        orin_stats.live_bytes -= sizeof(OrinString) + 2;
        tbl[c] = o;
    }
    return tbl[c];
}

OrinObj *orin_str_char_at(OrinObj *s, uint64_t i) {
    OrinString *x = (OrinString *)s;
    if (i >= x->len) orin_trap("charAt index out of range");
    return char_string((unsigned char)x->data[i]);
}

OrinObj *orin_str_substring(OrinObj *s, uint64_t a, uint64_t b) {
    OrinString *x = (OrinString *)s;
    if (a > b || b > x->len) orin_trap("substring out of range");
    if (a == 0 && b == x->len) return orin_dup(s);
    return orin_str_new(x->data + a, b - a);
}

static int64_t find(const OrinString *x, const OrinString *n) {
    if (n->len == 0) return 0;
    if (n->len > x->len) return -1;
    const char *p = (const char *)memmem(x->data, x->len, n->data, n->len);
    return p ? (int64_t)(p - x->data) : -1;
}

OrinObj *orin_str_index_of(OrinObj *s, OrinObj *needle) {
    int64_t i = find((OrinString *)s, (OrinString *)needle);
    if (i < 0) return orin_none();
    return orin_variant1(0, 0, (uint64_t)i);
}
int64_t orin_str_includes(OrinObj *s, OrinObj *n) { return find((OrinString *)s, (OrinString *)n) >= 0; }
int64_t orin_str_starts_with(OrinObj *s, OrinObj *p) {
    OrinString *x = (OrinString *)s, *y = (OrinString *)p;
    return y->len <= x->len && memcmp(x->data, y->data, y->len) == 0;
}
int64_t orin_str_ends_with(OrinObj *s, OrinObj *p) {
    OrinString *x = (OrinString *)s, *y = (OrinString *)p;
    return y->len <= x->len && memcmp(x->data + x->len - y->len, y->data, y->len) == 0;
}

OrinObj *orin_str_split(OrinObj *s, OrinObj *sep) {
    OrinString *x = (OrinString *)s, *y = (OrinString *)sep;
    if (y->len == 0) orin_trap("split with empty separator");
    OrinObj *arr = orin_array_new(4, 1);
    uint64_t start = 0;
    for (;;) {
        const char *p = NULL;
        if (x->len - start >= y->len) p = (const char *)memmem(x->data + start, x->len - start, y->data, y->len);
        if (!p) break;
        uint64_t end = (uint64_t)(p - x->data);
        orin_array_push(arr, ORIN_SLOT(orin_str_new(x->data + start, end - start)));
        start = end + y->len;
    }
    orin_array_push(arr, ORIN_SLOT(orin_str_new(x->data + start, x->len - start)));
    return arr;
}

OrinObj *orin_str_trim(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    uint64_t a = 0, b = x->len;
#define WS(c) ((c) == ' ' || (c) == '\t' || (c) == '\n' || (c) == '\r' || (c) == '\v' || (c) == '\f')
    while (a < b && WS(x->data[a])) a++;
    while (b > a && WS(x->data[b - 1])) b--;
#undef WS
    return orin_str_substring(s, a, b);
}

OrinObj *orin_string_from_char_code(int64_t c) {
    if (c < 0 || c > 255) orin_trap("fromCharCode out of range");
    return char_string((unsigned)c);
}

OrinObj *orin_int_to_string(int64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
    return orin_str_new(buf, (uint64_t)n);
}
OrinObj *orin_usize_to_string(uint64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%llu", (unsigned long long)v);
    return orin_str_new(buf, (uint64_t)n);
}
OrinObj *orin_bool_to_string(int64_t v) {
    return v ? orin_str_new("true", 4) : orin_str_new("false", 5);
}

OrinObj *orin_parse_int(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    uint64_t i = 0;
    int neg = 0;
    if (i < x->len && x->data[i] == '-') {
        neg = 1;
        i++;
    }
    if (i >= x->len) return orin_none();
    uint64_t acc = 0;
    for (; i < x->len; i++) {
        char c = x->data[i];
        if (c < '0' || c > '9') return orin_none();
        uint64_t d = (uint64_t)(c - '0');
        if (acc > (UINT64_MAX - d) / 10) return orin_none();
        acc = acc * 10 + d;
    }
    if (neg) {
        if (acc > (uint64_t)INT64_MAX + 1) return orin_none();
        return orin_variant1(0, 0, (uint64_t)0 - acc);
    }
    if (acc > (uint64_t)INT64_MAX) return orin_none();
    return orin_variant1(0, 0, acc);
}

/* ---------------------------------------------------------------- floats (ADR-0018) */

int64_t orin_float_to_int(double x) {
    /* int64 range is [-2^63, 2^63); both bounds are exactly representable as doubles. */
    if (!(x >= -9223372036854775808.0 && x < 9223372036854775808.0)) orin_trap("float to int out of range");
    return (int64_t)x;
}

/* Shortest digits that round-trip (precision search over %.{p-1}e), laid out like JavaScript:
 * positional for -7 < exp10 < 21, else d.ddde+XX. Integral values keep a ".0". */
static OrinObj *float_to_string(double x, int is_f32) {
    char out[64];
    size_t n = 0;
    if (x != x) return orin_str_new("NaN", 3);
    if (x == __builtin_inf()) return orin_str_new("Infinity", 8);
    if (x == -__builtin_inf()) return orin_str_new("-Infinity", 9);
    int neg = __builtin_signbit(x) != 0;
    if (neg) x = -x;
    if (x == 0.0) return neg ? orin_str_new("-0.0", 4) : orin_str_new("0.0", 3);
    char buf[64];
    int maxp = is_f32 ? 9 : 17;
    for (int p = 1; p <= maxp; p++) {
        snprintf(buf, sizeof buf, "%.*e", p - 1, x);
        if (is_f32 ? ((double)strtof(buf, NULL) == x) : (strtod(buf, NULL) == x)) break;
    }
    char digits[32];
    int nd = 0;
    const char *q = buf;
    for (; *q && *q != 'e'; q++) {
        if (*q >= '0' && *q <= '9') digits[nd++] = *q;
    }
    int k = (*q == 'e') ? atoi(q + 1) : 0;
    if (neg) out[n++] = '-';
    if (k > -7 && k < 21) {
        if (k >= 0) {
            for (int i = 0; i <= k; i++) out[n++] = i < nd ? digits[i] : '0';
            out[n++] = '.';
            if (nd > k + 1) {
                for (int i = k + 1; i < nd; i++) out[n++] = digits[i];
            } else {
                out[n++] = '0';
            }
        } else {
            out[n++] = '0';
            out[n++] = '.';
            for (int i = 0; i < -k - 1; i++) out[n++] = '0';
            for (int i = 0; i < nd; i++) out[n++] = digits[i];
        }
    } else {
        out[n++] = digits[0];
        if (nd > 1) {
            out[n++] = '.';
            for (int i = 1; i < nd; i++) out[n++] = digits[i];
        }
        out[n++] = 'e';
        out[n++] = k < 0 ? '-' : '+';
        n += (size_t)snprintf(out + n, sizeof out - n, "%d", k < 0 ? -k : k);
    }
    return orin_str_new(out, n);
}

OrinObj *orin_float_to_string(double x) { return float_to_string(x, 0); }
OrinObj *orin_f32_to_string(double x) { return float_to_string(x, 1); }

/* `-? D+ (. D+)? ([eE] [+-]? D+)?`, or `Infinity`, `-Infinity`, `NaN`; nothing else. */
OrinObj *orin_parse_float(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    const char *d = x->data;
    uint64_t n = x->len, i = 0;
    if (n == 3 && memcmp(d, "NaN", 3) == 0) return orin_variant1(0, 0, orin_f2s(strtod("nan", NULL)));
    if (n == 8 && memcmp(d, "Infinity", 8) == 0) return orin_variant1(0, 0, orin_f2s(strtod("inf", NULL)));
    if (n == 9 && memcmp(d, "-Infinity", 9) == 0) return orin_variant1(0, 0, orin_f2s(-strtod("inf", NULL)));
    if (i < n && d[i] == '-') i++;
    uint64_t ds = i;
    while (i < n && d[i] >= '0' && d[i] <= '9') i++;
    if (i == ds) return orin_none();
    if (i < n && d[i] == '.') {
        i++;
        uint64_t fs = i;
        while (i < n && d[i] >= '0' && d[i] <= '9') i++;
        if (i == fs) return orin_none();
    }
    if (i < n && (d[i] == 'e' || d[i] == 'E')) {
        i++;
        if (i < n && (d[i] == '+' || d[i] == '-')) i++;
        uint64_t es = i;
        while (i < n && d[i] >= '0' && d[i] <= '9') i++;
        if (i == es) return orin_none();
    }
    if (i != n) return orin_none();
    return orin_variant1(0, 0, orin_f2s(strtod(d, NULL))); /* data is NUL-terminated */
}

/* ---------------------------------------------------------------- arrays */

OrinObj *orin_array_new(uint64_t cap, int64_t is_ref) {
    if (cap > ((uint64_t)1 << 40)) orin_trap("array too large");
    OrinArray *a;
#ifndef ORIN_NO_FREELIST
    if (fl_array) {
        a = (OrinArray *)fl_array;
        fl_array = fl_array->next;
    } else
#endif
        a = (OrinArray *)xmalloc(sizeof(OrinArray));
    a->h.rc = 1;
    a->h.kind = ORIN_K_ARRAY;
    a->h.tag = 0;
    a->len = 0;
    a->cap = cap;
    a->is_ref = is_ref ? 1 : 0;
    a->items = cap ? (uint64_t *)xmalloc(cap * 8) : NULL;
    g_live++;
    stat_alloc(&orin_stats.alloc_array, sizeof(OrinArray) + cap * 8);
    return &a->h;
}

void orin_array_push_grow(OrinObj *o, uint64_t slot) {
    OrinArray *a = (OrinArray *)o;
    uint64_t cap = a->cap ? a->cap * 2 : 4;
    a->items = (uint64_t *)xrealloc(a->items, cap * 8);
    orin_stats.live_bytes += (cap - a->cap) * 8;
    if (orin_stats.live_bytes > orin_stats.peak_live_bytes) orin_stats.peak_live_bytes = orin_stats.live_bytes;
    orin_stats.array_grows++;
    a->cap = cap;
    a->items[a->len++] = slot;
}

OrinObj *orin_array_pop(OrinObj *o) {
    OrinArray *a = (OrinArray *)o;
    if (a->len == 0) return orin_none();
    return orin_variant1(0, a->is_ref, a->items[--a->len]);
}

OrinObj *orin_array_get(OrinObj *o, uint64_t i) {
    OrinArray *a = (OrinArray *)o;
    if (i >= a->len) return orin_none();
    uint64_t v = a->items[i];
    if (a->is_ref) orin_retain(ORIN_REF(v));
    return orin_variant1(0, a->is_ref, v);
}

OrinObj *orin_array_slice(OrinObj *o, uint64_t from, uint64_t to) {
    OrinArray *a = (OrinArray *)o;
    if (from > to || to > a->len) orin_trap("slice out of range");
    OrinObj *r = orin_array_new(to - from, (int64_t)a->is_ref);
    for (uint64_t i = from; i < to; i++) {
        if (a->is_ref) orin_retain(ORIN_REF(a->items[i]));
        orin_array_push(r, a->items[i]);
    }
    return r;
}

OrinObj *orin_array_concat(OrinObj *x, OrinObj *y) {
    OrinArray *a = (OrinArray *)x, *b = (OrinArray *)y;
    OrinObj *r = orin_array_new(a->len + b->len, (int64_t)(a->is_ref | b->is_ref));
    for (uint64_t i = 0; i < a->len; i++) {
        if (a->is_ref) orin_retain(ORIN_REF(a->items[i]));
        orin_array_push(r, a->items[i]);
    }
    for (uint64_t i = 0; i < b->len; i++) {
        if (b->is_ref) orin_retain(ORIN_REF(b->items[i]));
        orin_array_push(r, b->items[i]);
    }
    return r;
}

OrinObj *orin_array_join(OrinObj *o, OrinObj *sep) {
    OrinArray *a = (OrinArray *)o;
    OrinString *sp = (OrinString *)sep;
    uint64_t total = 0;
    for (uint64_t i = 0; i < a->len; i++) total += ((OrinString *)ORIN_REF(a->items[i]))->len;
    if (a->len > 1) total += sp->len * (a->len - 1);
    OrinString *r = str_alloc(total, total);
    uint64_t pos = 0;
    for (uint64_t i = 0; i < a->len; i++) {
        if (i) {
            memcpy(r->data + pos, sp->data, sp->len);
            pos += sp->len;
        }
        OrinString *e = (OrinString *)ORIN_REF(a->items[i]);
        memcpy(r->data + pos, e->data, e->len);
        pos += e->len;
    }
    return &r->h;
}

/* ---------------------------------------------------------------- I/O */

/* fwrite_unlocked is a glibc extension; fall back to fwrite elsewhere (macOS, musl). */
#if defined(__GLIBC__)
#define ORIN_FWRITE fwrite_unlocked
#else
#define ORIN_FWRITE fwrite
#endif

void orin_console_log(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    ORIN_FWRITE(x->data, 1, x->len, stdout);
    putc_unlocked('\n', stdout);
}

void orin_console_error(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    fflush(stdout);
    fwrite(x->data, 1, x->len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

static OrinObj *err_result(const char *what, OrinObj *path) {
    OrinString *p = (OrinString *)path;
    const char *why = strerror(errno);
    size_t n = strlen(what) + 2 + p->len + 3 + strlen(why);
    char *buf = (char *)xmalloc(n + 1);
    int m = snprintf(buf, n + 1, "%s '%.*s': %s", what, (int)p->len, p->data, why);
    OrinObj *msg = orin_str_new(buf, (uint64_t)m);
    free(buf);
    return orin_variant1(1, 1, ORIN_SLOT(msg));
}

OrinObj *orin_fs_read_file(OrinObj *path) {
    OrinString *p = (OrinString *)path;
    if (memchr(p->data, 0, p->len)) {
        errno = EINVAL;
        return err_result("cannot read", path);
    }
    FILE *f = fopen(p->data, "rb");
    if (!f) return err_result("cannot read", path);
    size_t cap = 4096, len = 0;
    char *buf = (char *)xmalloc(cap);
    for (;;) {
        if (len == cap) {
            cap *= 2;
            buf = (char *)xrealloc(buf, cap);
        }
        size_t k = fread(buf + len, 1, cap - len, f);
        len += k;
        if (k == 0) break;
    }
    int bad = ferror(f);
    int saved = errno;
    fclose(f);
    if (bad) {
        free(buf);
        errno = saved;
        return err_result("cannot read", path);
    }
    OrinObj *s = orin_str_new(buf, len);
    free(buf);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

OrinObj *orin_fs_write_file(OrinObj *path, OrinObj *data) {
    OrinString *p = (OrinString *)path, *d = (OrinString *)data;
    if (memchr(p->data, 0, p->len)) {
        errno = EINVAL;
        return err_result("cannot write", path);
    }
    FILE *f = fopen(p->data, "wb");
    if (!f) return err_result("cannot write", path);
    size_t k = fwrite(d->data, 1, d->len, f);
    int bad = (k != d->len) | (fclose(f) != 0);
    if (bad) return err_result("cannot write", path);
    return orin_ok_void();
}

int64_t orin_fs_exists(OrinObj *path) {
    OrinString *p = (OrinString *)path;
    struct stat st;
    if (memchr(p->data, 0, p->len)) return 0;
    return stat(p->data, &st) == 0;
}

OrinObj *orin_process_args(void) {
    OrinObj *arr = orin_array_new(g_argc > 1 ? (uint64_t)g_argc - 1 : 0, 1);
    for (int i = 1; i < g_argc; i++)
        orin_array_push(arr, ORIN_SLOT(orin_str_new(g_argv[i], strlen(g_argv[i]))));
    return arr;
}

void orin_process_exit(int64_t code) {
    fflush(stdout);
    exit((int)code);
}
