/* Orin runtime implementation. API and conventions: orin_runtime.h */
/* Layers (spec 19): this file is the C object model (future L1). Every OS / libc interaction goes
 * through the closed platform API (../platform/orin_platform.h); tools/check_platform_boundary.sh
 * enforces it. */
#include "orin_runtime.h"
#include "../platform/orin_platform.h"

static int64_t g_live;
OrinStats orin_stats;

/* Accounting helpers: called wherever g_live changes / buffers are (re)allocated. */
static inline void stat_alloc(uint64_t *kind_counter, uint64_t bytes) {
    (*kind_counter)++;
    orin_stats.live_bytes += bytes;
    if (orin_stats.live_bytes > orin_stats.peak_live_bytes) orin_stats.peak_live_bytes = orin_stats.live_bytes;
    if ((uint64_t)g_live > orin_stats.peak_live_objs) orin_stats.peak_live_objs = (uint64_t)g_live;
}

/* Report buffer: fixed size, assembled by hand (no printf). Longest report is < 700 bytes. */
typedef struct { char b[1024]; size_t n; } Rep;
static void rep_s(Rep *r, const char *s) {
    size_t k = 0;
    while (s[k]) k++;
    orin_platform_mem_copy(r->b + r->n, s, k);
    r->n += k;
}
static void rep_u(Rep *r, const char *key, uint64_t v) {
    rep_s(r, key);
    r->n += orin_platform_fmt_u64(r->b + r->n, v);
}

static void stats_report(void) {
    const char *e = orin_platform_getenv("ORIN_STATS");
    if (!e || e[0] != '1' || e[1] != 0) return;
    const OrinStats *s = &orin_stats;
    Rep r = {{0}, 0};
    rep_s(&r, "{\"orin_stats\":");
    rep_u(&r, "{\"alloc_string\":", s->alloc_string);
    rep_u(&r, ",\"alloc_array\":", s->alloc_array);
    rep_u(&r, ",\"alloc_struct\":", s->alloc_struct);
    rep_u(&r, ",\"alloc_total\":", s->alloc_string + s->alloc_array + s->alloc_struct);
    rep_u(&r, ",\"frees\":", s->frees);
    rep_u(&r, ",\"retains\":", s->retains);
    rep_u(&r, ",\"releases\":", s->releases);
    rep_u(&r, ",\"cow_copies\":", s->cow_copies);
    rep_u(&r, ",\"cow_inplace\":", s->cow_inplace);
    rep_u(&r, ",\"array_grows\":", s->array_grows);
    rep_u(&r, ",\"string_grows\":", s->string_grows);
    rep_u(&r, ",\"peak_live_objs\":", s->peak_live_objs);
    rep_u(&r, ",\"peak_live_bytes\":", s->peak_live_bytes);
    rep_u(&r, ",\"file_opens\":", s->file_opens);
    rep_u(&r, ",\"file_closes\":", s->file_closes);
    rep_s(&r, ",\"live_objs_at_exit\":");
    r.n += orin_platform_fmt_i64(r.b + r.n, g_live);
    rep_s(&r, "}}");
    orin_platform_write_line(ORIN_PLATFORM_STDERR, r.b, r.n);
}
int64_t orin_live_count(void) { return g_live; }

static void files_at_exit(void);

void orin_init(int argc, char **argv) {
    orin_platform_init(argc, argv);
    orin_platform_at_exit(stats_report);
    orin_platform_at_exit(files_at_exit); /* runs before stats_report: the counters include the closes */
}

void orin_flush(void) { orin_platform_flush(); }

void orin_trap(const char *msg) {
    size_t n = 0;
    while (msg[n]) n++;
    enum { MAX = 480 };
    char buf[MAX + 8];
    if (n > MAX) n = MAX;
    orin_platform_mem_copy(buf, "trap: ", 6);
    orin_platform_mem_copy(buf + 6, msg, n);
    orin_platform_write_line(ORIN_PLATFORM_STDERR, buf, 6 + n);
    orin_platform_exit(101);
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
    void *p = orin_platform_alloc(n);
    if (!p) orin_trap("out of memory");
    return p;
}
static void *xrealloc(void *q, size_t n) {
    void *p = orin_platform_realloc(q, n);
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
            orin_platform_free(a->items);
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
        orin_platform_free(x);
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
    orin_platform_mem_set(s->slots, 0, (size_t)nslots * 8);
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

void orin_trap_shape(void) { orin_trap("field access on a value of the wrong shape (compiler bug)"); }

OrinObj *orin_variant1(uint32_t tag, uint64_t refmask, uint64_t slot) {
    OrinObj *o = orin_struct_new(tag, 1, refmask & 1);
    ((OrinStruct *)o)->slots[0] = slot;
    return o;
}

void orin_struct_copy_slot(OrinObj *dst, uint32_t i, OrinObj *src, uint32_t j) {
    orin_chk_slot(dst, i);
    orin_chk_slot(src, j);
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
    if (n) orin_platform_mem_copy(s->data, p, n);
    return &s->h;
}

OrinObj *orin_str_concat(OrinObj *a, OrinObj *b) {
    OrinString *x = (OrinString *)a, *y = (OrinString *)b;
    if (y->len == 0) return orin_dup(a);
    if (x->len == 0) return orin_dup(b);
    OrinString *r = str_alloc(x->len + y->len, x->len + y->len);
    orin_platform_mem_copy(r->data, x->data, x->len);
    orin_platform_mem_copy(r->data + x->len, y->data, y->len);
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
        orin_platform_mem_copy(x->data + x->len, y->data, y->len);
        x->len = n;
        x->data[n] = 0;
        return &x->h;
    }
    OrinString *r = str_alloc(n, n + n / 2 + 8);
    if (x->len) orin_platform_mem_copy(r->data, x->data, x->len);
    orin_platform_mem_copy(r->data + x->len, y->data, y->len);
    orin_release(a);
    return &r->h;
}

int64_t orin_str_eq(OrinObj *a, OrinObj *b) {
    if (a == b) return 1;
    OrinString *x = (OrinString *)a, *y = (OrinString *)b;
    return x->len == y->len && orin_platform_mem_cmp(x->data, y->data, x->len) == 0;
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
    const char *p = (const char *)orin_platform_mem_find(x->data, x->len, n->data, n->len);
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
    return y->len <= x->len && orin_platform_mem_cmp(x->data, y->data, y->len) == 0;
}
int64_t orin_str_ends_with(OrinObj *s, OrinObj *p) {
    OrinString *x = (OrinString *)s, *y = (OrinString *)p;
    return y->len <= x->len && orin_platform_mem_cmp(x->data + x->len - y->len, y->data, y->len) == 0;
}

OrinObj *orin_str_split(OrinObj *s, OrinObj *sep) {
    OrinString *x = (OrinString *)s, *y = (OrinString *)sep;
    if (y->len == 0) orin_trap("split with empty separator");
    OrinObj *arr = orin_array_new(4, 1);
    uint64_t start = 0;
    for (;;) {
        const char *p = NULL;
        if (x->len - start >= y->len) p = (const char *)orin_platform_mem_find(x->data + start, x->len - start, y->data, y->len);
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
    char buf[24];
    return orin_str_new(buf, (uint64_t)orin_platform_fmt_i64(buf, v));
}
OrinObj *orin_usize_to_string(uint64_t v) {
    char buf[24];
    return orin_str_new(buf, (uint64_t)orin_platform_fmt_u64(buf, v));
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

/* ---------------------------------------------------------------- fixed-width integers (ADR-0022) */
/* Kinds: 0 i8, 1 i16, 2 i32, 3 i64, 4 isize, 5 u8, 6 u16, 7 u32, 8 u64, 9 usize. A value is passed and stored as its
 * 64-bit pattern: sign-extended for the signed kinds, zero-extended for u8/u16/u32, plain for u64/usize. */

static int kind_bits(int64_t k) {
    switch (k) {
    case 0: case 5: return 8;
    case 1: case 6: return 16;
    case 2: case 7: return 32;
    default: return 64;
    }
}
static int kind_signed(int64_t k) { return k <= 4; }
static __int128 kind_min(int64_t k) {
    return kind_signed(k) ? -((__int128)1 << (kind_bits(k) - 1)) : 0;
}
static __int128 kind_max(int64_t k) {
    return kind_signed(k) ? (((__int128)1 << (kind_bits(k) - 1)) - 1) : (((__int128)1 << kind_bits(k)) - 1);
}
static __int128 int_decode(uint64_t bits, int64_t k) {
    return (k == 8 || k == 9) ? (__int128)bits : (__int128)(int64_t)bits;
}
static uint64_t int_encode(__int128 v, int64_t k) {
    return (k == 8 || k == 9) ? (uint64_t)v : (uint64_t)(int64_t)v;
}
/* v reduced modulo 2^bits into the kind's range. */
static __int128 int_wrap(__int128 v, int64_t k) {
    int b = kind_bits(k);
    if (b == 64) return kind_signed(k) ? (__int128)(int64_t)(uint64_t)v : (__int128)(uint64_t)v;
    uint64_t m = ((uint64_t)1 << b) - 1;
    uint64_t u = (uint64_t)v & m;
    if (kind_signed(k) && (u >> (b - 1))) return (__int128)(int64_t)(u | ~m);
    return (__int128)u;
}
static __int128 int_exact(int64_t mode, __int128 a, __int128 b) {
    switch (mode % 3) {
    case 0: return a + b;
    case 1: return a - b;
    default: return a * b;
    }
}

/* mode 0..2 wrapping add/sub/mul, 3..5 saturating add/sub/mul. */
uint64_t orin_int_op(int64_t mode, uint64_t a, uint64_t b, int64_t kind) {
    __int128 r = int_exact(mode, int_decode(a, kind), int_decode(b, kind));
    if (mode < 3) return int_encode(int_wrap(r, kind), kind);
    if (r < kind_min(kind)) r = kind_min(kind);
    if (r > kind_max(kind)) r = kind_max(kind);
    return int_encode(r, kind);
}

/* mode 0..2 checked add/sub/mul: Option of the result. */
OrinObj *orin_int_chk(int64_t mode, uint64_t a, uint64_t b, int64_t kind) {
    __int128 r = int_exact(mode, int_decode(a, kind), int_decode(b, kind));
    if (r < kind_min(kind) || r > kind_max(kind)) return orin_none();
    return orin_variant1(0, 0, int_encode(r, kind));
}

OrinObj *orin_parse_int_k(OrinObj *s, int64_t kind) {
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
    __int128 v = neg ? -(__int128)acc : (__int128)acc;
    if (v < kind_min(kind) || v > kind_max(kind)) return orin_none();
    return orin_variant1(0, 0, int_encode(v, kind));
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
        orin_platform_double_to_exp(buf, sizeof buf, p - 1, x);
        if (orin_platform_parse_double(buf, is_f32) == x) break;
    }
    char digits[32];
    int nd = 0;
    const char *q = buf;
    for (; *q && *q != 'e'; q++) {
        if (*q >= '0' && *q <= '9') digits[nd++] = *q;
    }
    int k = 0;
    if (*q == 'e') {
        const char *e = q + 1;
        int eneg = *e == '-';
        if (*e == '-' || *e == '+') e++;
        for (; *e >= '0' && *e <= '9'; e++) k = k * 10 + (*e - '0');
        if (eneg) k = -k;
    }
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
        int ek = k < 0 ? -k : k;
        char ed[8];
        int ne = 0;
        do { ed[ne++] = (char)('0' + ek % 10); ek /= 10; } while (ek);
        while (ne) out[n++] = ed[--ne];
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
    if (n == 3 && orin_platform_mem_cmp(d, "NaN", 3) == 0) return orin_variant1(0, 0, orin_f2s(__builtin_nan("")));
    if (n == 8 && orin_platform_mem_cmp(d, "Infinity", 8) == 0) return orin_variant1(0, 0, orin_f2s(__builtin_inf()));
    if (n == 9 && orin_platform_mem_cmp(d, "-Infinity", 9) == 0) return orin_variant1(0, 0, orin_f2s(-__builtin_inf()));
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
    return orin_variant1(0, 0, orin_f2s(orin_platform_parse_double(d, 0))); /* data is NUL-terminated */
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
            orin_platform_mem_copy(r->data + pos, sp->data, sp->len);
            pos += sp->len;
        }
        OrinString *e = (OrinString *)ORIN_REF(a->items[i]);
        orin_platform_mem_copy(r->data + pos, e->data, e->len);
        pos += e->len;
    }
    return &r->h;
}

/* ---------------------------------------------------------------- I/O */

void orin_console_log(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    orin_platform_write_line(ORIN_PLATFORM_STDOUT, x->data, x->len);
}

void orin_console_error(OrinObj *s) {
    OrinString *x = (OrinString *)s;
    orin_platform_write_line(ORIN_PLATFORM_STDERR, x->data, x->len);
}

/* Err("<what> '<path>': <reason>") */
static OrinObj *err_result(const char *what, OrinObj *path, int code) {
    OrinString *p = (OrinString *)path;
    const char *why = orin_platform_error_message(code);
    size_t wl = 0, yl = 0;
    while (what[wl]) wl++;
    while (why[yl]) yl++;
    OrinString *m = str_alloc(wl + 2 + p->len + 3 + yl, 0);
    char *d = m->data;
    orin_platform_mem_copy(d, what, wl), d += wl;
    *d++ = ' ';
    *d++ = '\'';
    orin_platform_mem_copy(d, p->data, p->len), d += p->len;
    *d++ = '\'';
    *d++ = ':';
    *d++ = ' ';
    orin_platform_mem_copy(d, why, yl), d += yl;
    *d = 0;
    return orin_variant1(1, 1, ORIN_SLOT(&m->h));
}

OrinObj *orin_fs_read_file(OrinObj *path) {
    OrinString *p = (OrinString *)path;
    char *buf;
    size_t len;
    int rc = orin_platform_file_read(p->data, p->len, &buf, &len);
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    if (rc) return err_result("cannot read", path, rc);
    OrinObj *s = orin_str_new(buf, len);
    orin_platform_free(buf);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

OrinObj *orin_fs_write_file(OrinObj *path, OrinObj *data) {
    OrinString *p = (OrinString *)path, *d = (OrinString *)data;
    int rc = orin_platform_file_write(p->data, p->len, d->data, d->len);
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    if (rc) return err_result("cannot write", path, rc);
    return orin_ok_void();
}

int64_t orin_fs_exists(OrinObj *path) {
    OrinString *p = (OrinString *)path;
    return orin_platform_file_exists(p->data, p->len);
}

/* ---------------------------------------------------------------- file resources (ADR-0025) */

enum { FILE_SLOTS = 256 };
typedef struct {
    orin_platform_stream *s; /* NULL = free */
    uint64_t gen;            /* incremented on every open of the slot; never 0 while open */
    int mode;                /* ORIN_PLATFORM_STREAM_* */
    int err;                 /* first runtime-detected error (wrong mode); 0 = none */
} FileSlot;
static FileSlot g_files[FILE_SLOTS];

static void files_at_exit(void) {
    for (int i = 0; i < FILE_SLOTS; i++) {
        if (g_files[i].s) {
            orin_platform_stream_close(g_files[i].s); /* flushes buffered bytes */
            g_files[i].s = NULL;
            orin_stats.file_closes++;
        }
    }
}

static OrinObj *reason_str(const char *what, int code) {
    const char *why = orin_platform_error_message(code);
    size_t wl = 0, yl = 0;
    while (what[wl]) wl++;
    while (why[yl]) yl++;
    OrinString *m = str_alloc(wl + yl, 0);
    orin_platform_mem_copy(m->data, what, wl);
    orin_platform_mem_copy(m->data + wl, why, yl);
    m->data[wl + yl] = 0;
    return &m->h;
}

/* The slot of a valid open handle; traps on anything else (closed, stale, foreign, failed-open, 0). */
static FileSlot *file_slot(int64_t h) {
    if (h > 0) {
        uint64_t idx = (uint64_t)h & 255, gen = (uint64_t)h >> 8;
        if (g_files[idx].s && g_files[idx].gen == gen) return &g_files[idx];
    }
    orin_trap("invalid file handle (closed, stale or failed to open)");
}

static void file_fail(FileSlot *f, int code) {
    if (f->err == 0) f->err = code;
}

int64_t orin_file_open(OrinObj *path, int64_t mode) {
    if (mode < 0 || mode > 2) return -ORIN_PLATFORM_EINVAL;
    int i = 0;
    while (i < FILE_SLOTS && g_files[i].s) i++;
    if (i == FILE_SLOTS) return -24; /* EMFILE: too many open files */
    orin_platform_stream *s;
    int rc = orin_platform_stream_open(orin_str_data(path), (size_t)orin_str_len(path), (int)mode, &s);
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    if (rc) return -(int64_t)rc;
    g_files[i].s = s;
    g_files[i].gen++;
    g_files[i].mode = (int)mode;
    g_files[i].err = 0;
    orin_stats.file_opens++;
    return (int64_t)((g_files[i].gen << 8) | (uint64_t)i);
}

int64_t orin_file_is_open(int64_t h) { return h > 0; }

OrinObj *orin_file_open_error(int64_t h) {
    return reason_str("", h < 0 && h > -100000 ? (int)-h : ORIN_PLATFORM_EINVAL);
}

OrinObj *orin_file_close(int64_t h) {
    if (h <= 0) return orin_none(); /* nothing was opened: nothing to release */
    FileSlot *f = file_slot(h);
    int rc = orin_platform_stream_close(f->s);
    int code = f->err ? f->err : rc;
    f->s = NULL;
    orin_stats.file_closes++;
    if (code == 0) return orin_none();
    return orin_variant1(0, 1, ORIN_SLOT(reason_str("I/O error: ", code)));
}

/* Reads up to n bytes (n may be huge): grows the buffer as data arrives. Returns the byte count. */
static OrinObj *file_read_upto(FileSlot *f, uint64_t n, int *any) {
    size_t cap = 4096, len = 0;
    char *buf = (char *)orin_platform_alloc(cap);
    if (!buf) orin_trap("out of memory");
    while ((uint64_t)len < n) {
        if (len == cap) {
            if (cap > SIZE_MAX / 2) orin_trap("out of memory");
            cap *= 2;
            buf = (char *)orin_platform_realloc(buf, cap);
            if (!buf) orin_trap("out of memory");
        }
        size_t want = cap - len;
        if ((uint64_t)want > n - (uint64_t)len) want = (size_t)(n - (uint64_t)len);
        size_t got = orin_platform_stream_read(f->s, buf + len, want);
        len += got;
        if (got < want) break; /* EOF or error */
    }
    *any = len > 0;
    OrinObj *r = orin_str_new(buf, len);
    orin_platform_free(buf);
    return r;
}

OrinObj *orin_file_read_line(int64_t h) {
    FileSlot *f = file_slot(h);
    if (f->mode != ORIN_PLATFORM_STREAM_READ) {
        file_fail(f, 9); /* EBADF */
        return orin_none();
    }
    size_t cap = 128, len = 0;
    char *buf = (char *)orin_platform_alloc(cap);
    if (!buf) orin_trap("out of memory");
    int c, any = 0;
    while ((c = orin_platform_stream_getc(f->s)) >= 0) {
        any = 1;
        if (c == '\n') break;
        if (len == cap) {
            cap *= 2;
            buf = (char *)orin_platform_realloc(buf, cap);
            if (!buf) orin_trap("out of memory");
        }
        buf[len++] = (char)c;
    }
    if (!any) {
        orin_platform_free(buf);
        return orin_none();
    }
    if (len > 0 && buf[len - 1] == '\r') len--;
    OrinObj *s = orin_str_new(buf, len);
    orin_platform_free(buf);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

OrinObj *orin_file_read(int64_t h, uint64_t n) {
    FileSlot *f = file_slot(h);
    if (f->mode != ORIN_PLATFORM_STREAM_READ) {
        file_fail(f, 9);
        return orin_none();
    }
    int any;
    OrinObj *s = file_read_upto(f, n, &any);
    if (n > 0 && !any) {
        orin_release(s);
        return orin_none();
    }
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

OrinObj *orin_file_read_all(int64_t h) {
    FileSlot *f = file_slot(h);
    if (f->mode != ORIN_PLATFORM_STREAM_READ) {
        file_fail(f, 9);
        return orin_str_new("", 0);
    }
    int any;
    return file_read_upto(f, UINT64_MAX, &any);
}

void orin_file_write(int64_t h, OrinObj *s) {
    FileSlot *f = file_slot(h);
    if (f->mode == ORIN_PLATFORM_STREAM_READ) {
        file_fail(f, 9);
        return;
    }
    orin_platform_stream_write(f->s, orin_str_data(s), (size_t)orin_str_len(s));
}

void orin_file_write_line(int64_t h, OrinObj *s) {
    FileSlot *f = file_slot(h);
    if (f->mode == ORIN_PLATFORM_STREAM_READ) {
        file_fail(f, 9);
        return;
    }
    orin_platform_stream_write(f->s, orin_str_data(s), (size_t)orin_str_len(s));
    orin_platform_stream_write(f->s, "\n", 1);
}

void orin_file_flush(int64_t h) {
    FileSlot *f = file_slot(h);
    if (f->mode != ORIN_PLATFORM_STREAM_READ) orin_platform_stream_flush(f->s);
}

OrinObj *orin_process_args(void) {
    int argc = orin_platform_arg_count();
    OrinObj *arr = orin_array_new(argc > 1 ? (uint64_t)argc - 1 : 0, 1);
    for (int i = 1; i < argc; i++) {
        const char *a = orin_platform_arg(i);
        size_t n = 0;
        while (a[n]) n++;
        orin_array_push(arr, ORIN_SLOT(orin_str_new(a, n)));
    }
    return arr;
}

void orin_process_exit(int64_t code) { orin_platform_exit((int)code); }
