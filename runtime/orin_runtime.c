/* Orin runtime implementation. API and conventions: orin_runtime.h */
/* Layers (spec 19): this file is the C object model (future L1). Every OS / libc interaction goes
 * through the closed platform API (../platform/orin_platform.h); tools/check_platform_boundary.sh
 * enforces it. */
#include "orin_runtime.h"
#include "../platform/orin_platform.h"

/* Per-thread heap state (ADR-0017): every task allocates from, and counts in, its own thread-local state, so reference counts
 * and free lists need no atomics. Moving an object to another task's heap is safe because a block is just malloc memory
 * (freed on any thread). The process-wide totals of finished tasks are g_fold / g_fold_live. */
static __thread int64_t g_live;
__thread OrinStats orin_stats ORIN_TLS_MODEL;
static OrinStats g_fold;
static int64_t g_fold_live;

/* Accounting helpers: called wherever g_live changes / buffers are (re)allocated. */
static inline void stat_alloc(uint64_t *kind_counter, uint64_t bytes) {
    (*kind_counter)++;
    orin_stats.live_bytes += bytes;
    /* A task that frees objects another task allocated (a value moved to it) can have a negative balance of its own:
     * the counters are per task, so they are compared as signed numbers (they used to wrap to 2^64 - 1). */
    if ((int64_t)orin_stats.live_bytes > 0 && orin_stats.live_bytes > orin_stats.peak_live_bytes)
        orin_stats.peak_live_bytes = orin_stats.live_bytes;
    if (g_live > 0 && (uint64_t)g_live > orin_stats.peak_live_objs) orin_stats.peak_live_objs = (uint64_t)g_live;
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

/* d += s (peaks: the larger one). */
static void stats_add(OrinStats *d, const OrinStats *s) {
    d->alloc_string += s->alloc_string, d->alloc_array += s->alloc_array, d->alloc_struct += s->alloc_struct;
    d->frees += s->frees, d->retains += s->retains, d->releases += s->releases;
    d->cow_copies += s->cow_copies, d->cow_inplace += s->cow_inplace;
    d->array_grows += s->array_grows, d->string_grows += s->string_grows;
    if (s->peak_live_objs > d->peak_live_objs) d->peak_live_objs = s->peak_live_objs;
    if (s->peak_live_bytes > d->peak_live_bytes) d->peak_live_bytes = s->peak_live_bytes;
    d->live_bytes += s->live_bytes;
    d->file_opens += s->file_opens, d->file_closes += s->file_closes;
    d->transfer_moves += s->transfer_moves, d->transfer_copies += s->transfer_copies, d->tasks_spawned += s->tasks_spawned;
}

static void stats_report(void) {
    const char *e = orin_platform_getenv("ORIN_STATS");
    if (!e || e[0] != '1' || e[1] != 0) return;
    OrinStats tot = orin_stats;
    orin_platform_runtime_lock();
    stats_add(&tot, &g_fold);
    orin_platform_runtime_unlock();
    const OrinStats *s = &tot;
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
    rep_u(&r, ",\"transfer_moves\":", s->transfer_moves);
    rep_u(&r, ",\"transfer_copies\":", s->transfer_copies);
    rep_u(&r, ",\"tasks_spawned\":", s->tasks_spawned);
    rep_s(&r, ",\"live_objs_at_exit\":");
    r.n += orin_platform_fmt_i64(r.b + r.n, orin_live_count());
    rep_s(&r, "}}");
    orin_platform_write_line(ORIN_PLATFORM_STDERR, r.b, r.n);
}
int64_t orin_live_count(void) {
    orin_platform_runtime_lock();
    int64_t folded = g_fold_live;
    orin_platform_runtime_unlock();
    return g_live + folded;
}

static void files_at_exit(void);

void orin_init(int argc, char **argv) {
    orin_platform_init(argc, argv);
    orin_platform_at_exit(stats_report);
    orin_platform_at_exit(files_at_exit); /* runs before stats_report: the counters include the closes */
}

void orin_flush(void) { orin_platform_flush(); }

static int task_active(void);
static void task_trap(const char *msg) __attribute__((noreturn));

void orin_trap(const char *msg) {
    if (task_active()) task_trap(msg); /* a trap on a task thread ends that task only; the joiner traps (ADR-0017) */
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
/* A free list holds at most FL_CAP objects: a task that frees more than it allocates (the consumer of a channel) must not hoard
 * the memory of a producer that keeps allocating; beyond the cap an object goes back to the allocator. fl_n[FL_STRUCT_CLASSES]
 * counts the array headers. */
enum { FL_CAP = 1 << 18 };
typedef struct FreeNode { struct FreeNode *next; } FreeNode;
static __thread FreeNode *fl_struct[FL_STRUCT_CLASSES];
static __thread FreeNode *fl_array;
static __thread uint32_t fl_n[FL_STRUCT_CLASSES + 1];
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

static __thread OrinObj **t_dstack; /* the work stack of orin_destroy: per task, freed when the task ends */
static __thread size_t t_dcap;

void orin_destroy(OrinObj *o) {
    /* Iterative so that long chains (lists, deep trees) cannot overflow the C stack. */
    OrinObj **stack = t_dstack;
    size_t scap = t_dcap, sp = 0;
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
            if (fl_n[FL_STRUCT_CLASSES] < FL_CAP) {
                ((FreeNode *)x)->next = fl_array;
                fl_array = (FreeNode *)x;
                fl_n[FL_STRUCT_CLASSES]++;
                g_live--;
                orin_stats.frees++;
                continue;
            }
#endif
            break;
        }
        case ORIN_K_STRUCT: {
            OrinStruct *s = (OrinStruct *)x;
            for (uint32_t i = 0; i < s->nslots; i++)
                if ((s->refmask >> i) & 1) DEC(ORIN_REF(s->slots[i]));
            orin_stats.live_bytes -= sizeof(OrinStruct) + (uint64_t)s->nslots * 8;
#ifndef ORIN_NO_FREELIST
            if (s->nslots < FL_STRUCT_CLASSES && fl_n[s->nslots] < FL_CAP) {
                ((FreeNode *)x)->next = fl_struct[s->nslots];
                fl_struct[s->nslots] = (FreeNode *)x;
                fl_n[s->nslots]++;
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
    t_dstack = stack;
    t_dcap = scap;
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
        fl_n[nslots]--;
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

/* The immortal singletons are shared by all tasks (never counted, never freed, never written after creation): created on
 * first use and published with a compare-and-swap, the loser frees its copy. */
OrinObj *orin_nullary(uint32_t tag) {
    enum { N = 1024 };
    static OrinObj *tbl[N];
    if (tag >= N) orin_trap("variant tag too large");
    OrinObj *o = __atomic_load_n(&tbl[tag], __ATOMIC_ACQUIRE);
    if (!o) {
        OrinStruct *s = (OrinStruct *)xmalloc(sizeof(OrinStruct));
        s->h.rc = -1;
        s->h.kind = ORIN_K_STRUCT;
        s->h.tag = tag;
        s->nslots = 0;
        s->pad = 0;
        s->refmask = 0;
        OrinObj *none = NULL;
        if (__atomic_compare_exchange_n(&tbl[tag], &none, &s->h, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            o = &s->h;
        } else {
            orin_platform_free(s);
            o = none;
        }
    }
    return o;
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

static OrinObj *char_string(unsigned c) { /* shared immortals, published like orin_nullary's */
    static OrinObj *tbl[256];
    OrinObj *o = __atomic_load_n(&tbl[c], __ATOMIC_ACQUIRE);
    if (!o) {
        OrinString *s = (OrinString *)xmalloc(sizeof(OrinString) + 2);
        s->h.rc = -1;
        s->h.kind = ORIN_K_STRING;
        s->h.tag = 0;
        s->len = s->cap = 1;
        s->data[0] = (char)c;
        s->data[1] = 0;
        OrinObj *none = NULL;
        if (__atomic_compare_exchange_n(&tbl[c], &none, &s->h, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            o = &s->h;
        } else {
            orin_platform_free(s);
            o = none;
        }
    }
    return o;
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
        fl_n[FL_STRUCT_CLASSES]--;
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
    if ((int64_t)orin_stats.live_bytes > 0 && orin_stats.live_bytes > orin_stats.peak_live_bytes) orin_stats.peak_live_bytes = orin_stats.live_bytes;
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
static OrinObj *err_msg(const char *what, OrinObj *path, const char *why) {
    OrinString *p = (OrinString *)path;
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

static OrinObj *err_result(const char *what, OrinObj *path, int code) {
    return err_msg(what, path, orin_platform_error_message(code));
}

static size_t strlen_(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* ---------------------------------------------------------------- capability grants (ADR-0021 Stage A, ADR-0027)
 * A grant is an int64_t handle like a file handle (MIR class MHandle; the compiler guarantees that it is only
 * passed to calls and closed once, ADR-0025), tagged with bit 40 so a file handle can never be taken for a grant.
 * Layout: GRANT_TAG | generation << 8 | slot. The runtime does not rely on the compiler: every privileged operation
 * validates the handle (live slot, generation, kind) and TRAPS on a forged, stale, revoked or wrong-kind handle.
 * Authority is checked at every operation: the family policy (ORIN_DENY, read once by orin_cap_host_root), the
 * read-only flag and, for the file system, the path scope. Denial: an operation that returns a Result reports
 * Err("... denied ..."); every other operation traps ("capability denied ..."). */
enum { GK_HOST = 0, GK_FS = 1, GK_PROCESS = 2, GK_STDIO = 3, GK_CLOCK = 4, GK_NET = 5, GK_LISTENER = 6, GK_STREAM = 7 };
enum { GR_SLOTS = 256, CAP_PATH = 4096 };
enum { DEN_POLICY = 100001, DEN_SCOPE = 100002, DEN_RDONLY = 100003, DEN_RESOLVE = 100004 };
#define GRANT_TAG ((int64_t)1 << 40)
typedef struct {
    int live, kind;
    uint64_t gen;
    int denied;    /* the host policy denies this family: every operation is refused */
    int readonly;  /* fs: no write, no create */
    int nospawn;   /* process: args only */
    int empty;     /* fs: narrowed to nothing (the requested scope was not inside the parent's) */
    char *scope;   /* fs: normalised absolute scope, NULL = the whole file system */
    size_t slen;
    char *rscope;  /* the same with every symbolic link resolved */
    size_t rlen;
    orin_platform_net net; /* net family (ADR-0033): the L0 record of a NetGrant / Listener / Stream */
    int port;              /* listener: the bound port; stream: the peer port */
    char peer[72];         /* stream: numeric peer address */
} Grant;
static __thread Grant g_grants[GR_SLOTS]; /* per task: a handle is only meaningful in the task that made it */
static unsigned g_deny;                    /* written once by orin_cap_host_root before any task exists */
static uint64_t cap_tid(void) { return orin_platform_thread_id() & 0x3fffff; }

static const char *kind_name(int k) {
    return k == GK_FS ? "fs" : k == GK_PROCESS ? "process" : k == GK_STDIO ? "stdio" : k == GK_CLOCK ? "clock" : k >= GK_NET ? "net" : "host";
}

static const char *den_text(int code) {
    return code == DEN_POLICY    ? "denied by the host policy (ORIN_DENY)"
           : code == DEN_SCOPE   ? "outside the granted file scope"
           : code == DEN_RDONLY  ? "the file grant is read-only"
                                 : "path cannot be resolved inside the granted scope";
}

static void trap_denied(int kind, const char *what, const char *why) {
    char b[240];
    size_t n = 0;
    const char *parts[] = {"capability denied: ", kind_name(kind), " ", what, ": ", why};
    for (int i = 0; i < 6; i++)
        for (const char *q = parts[i]; *q && n + 1 < sizeof b; q++) b[n++] = *q;
    b[n] = 0;
    orin_trap(b);
}

static Grant *grant_new(int kind) {
    for (int i = 0; i < GR_SLOTS; i++) {
        if (!g_grants[i].live) {
            Grant *g = &g_grants[i];
            uint64_t gen = g->gen + 1;
            orin_platform_mem_set(g, 0, sizeof *g);
            g->gen = gen;
            g->live = 1;
            g->kind = kind;
            return g;
        }
    }
    orin_trap("too many active capability grants");
}

/* GRANT_TAG | task id << 41 | generation (32 bits) << 8 | slot */
static int64_t grant_handle(const Grant *g) {
    return GRANT_TAG | (int64_t)(cap_tid() << 41) | (int64_t)((g->gen & 0xffffffffu) << 8) | (int64_t)(g - g_grants);
}

/* The live grant named by h, of kind `kind` (kind < 0: any kind); traps on anything else (forged, revoked, stale,
 * wrong kind). */
static Grant *grant_ref(int64_t h, int kind) {
    if (h > 0 && ((uint64_t)h & (uint64_t)GRANT_TAG) && ((uint64_t)h >> 41) == cap_tid()) {
        uint64_t idx = (uint64_t)h & 255, gen = ((uint64_t)h >> 8) & 0xffffffffu;
        Grant *g = &g_grants[idx];
        if (g->live && (g->gen & 0xffffffffu) == gen && (kind < 0 || g->kind == kind)) return g;
    }
    orin_trap("invalid capability grant (forged, revoked, or of the wrong kind)");
}

static Grant *grant_use(int64_t h, int kind, const char *what) {
    Grant *g = grant_ref(h, kind);
    if (g->denied) trap_denied(kind, what, den_text(DEN_POLICY));
    return g;
}

void orin_cap_require(int64_t h, int64_t kind, const char *what) { (void)grant_use(h, (int)kind, what); }
void orin_cap_require_spawn(int64_t h) {
    if (grant_use(h, GK_PROCESS, "shell")->nospawn) trap_denied(GK_PROCESS, "shell", "this process grant allows args only");
}

int64_t orin_cap_host_root(void) {
    if (orin_platform_policy_load(&g_deny) != 0)
        orin_trap("invalid ORIN_DENY (expected a comma-separated list of: fs, process, stdio, clock, net, all)");
    return grant_handle(grant_new(GK_HOST));
}

int64_t orin_cap_acquire(int64_t host, int64_t family) {
    (void)grant_ref(host, GK_HOST);
    if (family < GK_FS || family > GK_CLOCK) orin_trap("invalid capability family");
    Grant *g = grant_new((int)family);
    unsigned bit = family == GK_FS        ? ORIN_PLATFORM_FAM_FS
                   : family == GK_PROCESS ? ORIN_PLATFORM_FAM_PROCESS
                   : family == GK_STDIO   ? ORIN_PLATFORM_FAM_STDIO
                                          : ORIN_PLATFORM_FAM_CLOCK;
    g->denied = (g_deny & bit) != 0;
    return grant_handle(g);
}

int64_t orin_cap_fs(int64_t host) { return orin_cap_acquire(host, GK_FS); }
int64_t orin_cap_process(int64_t host) { return orin_cap_acquire(host, GK_PROCESS); }
int64_t orin_cap_stdio(int64_t host) { return orin_cap_acquire(host, GK_STDIO); }
int64_t orin_cap_clock(int64_t host) { return orin_cap_acquire(host, GK_CLOCK); }

static char *dup_cstr(const char *s, size_t n) {
    char *d = (char *)xmalloc(n + 1);
    orin_platform_mem_copy(d, s, n);
    d[n] = 0;
    return d;
}

/* g gets the authority of p (same flags, same scope). */
static void grant_copy_into(Grant *g, const Grant *p) {
    g->denied = p->denied;
    g->readonly = p->readonly;
    g->nospawn = p->nospawn;
    g->empty = p->empty;
    if (p->scope) {
        g->scope = dup_cstr(p->scope, p->slen);
        g->slen = p->slen;
        g->rscope = dup_cstr(p->rscope, p->rlen);
        g->rlen = p->rlen;
    }
}

/* op 0: fs under(path); op 1: fs readOnly; op 2: process argsOnly. A narrowed grant never has more authority than
 * its parent: the new scope is used only when it lies inside the parent's (else the parent's, if that is
 * narrower, else nothing). */
int64_t orin_cap_narrow(int64_t parent, int64_t op, OrinObj *arg) {
    if (op < 0 || op > 2) orin_trap("invalid capability narrowing");
    Grant *p = grant_ref(parent, op == 2 ? GK_PROCESS : GK_FS);
    Grant *g = grant_new(p->kind);
    grant_copy_into(g, p);
    if (op == 1) g->readonly = 1;
    if (op == 2) g->nospawn = 1;
    if (op == 0 && !g->empty) {
        char abs[CAP_PATH + 1], real[CAP_PATH + 1];
        int64_t al = orin_platform_path_absolute(orin_str_data(arg), (size_t)orin_str_len(arg), abs, sizeof abs);
        int64_t rl = al > 0 ? orin_platform_path_real(abs, (size_t)al, real, sizeof real) : -1;
        if (rl <= 0) {
            g->empty = 1;
        } else if (!p->scope || (orin_platform_path_within(p->scope, p->slen, abs, (size_t)al) &&
                                 orin_platform_path_within(p->rscope, p->rlen, real, (size_t)rl))) {
            orin_platform_free(g->scope);
            orin_platform_free(g->rscope);
            g->scope = dup_cstr(abs, (size_t)al);
            g->slen = (size_t)al;
            g->rscope = dup_cstr(real, (size_t)rl);
            g->rlen = (size_t)rl;
        } else if (!orin_platform_path_within(abs, (size_t)al, p->scope, p->slen)) {
            g->empty = 1; /* disjoint from the parent's scope */
        } /* else: the parent's scope is already inside the requested one: keep it */
    }
    return grant_handle(g);
}

int64_t orin_cap_under(int64_t fs, OrinObj *path) { return orin_cap_narrow(fs, 0, path); }
int64_t orin_cap_read_only(int64_t fs) { return orin_cap_narrow(fs, 1, NULL); }
int64_t orin_cap_args_only(int64_t proc) { return orin_cap_narrow(proc, 2, NULL); }

void orin_cap_revoke(int64_t h) {
    Grant *g = grant_ref(h, -1);
    if (g->kind >= GK_NET) orin_platform_net_close(&g->net);
    orin_platform_free(g->scope);
    orin_platform_free(g->rscope);
    g->scope = g->rscope = NULL;
    g->live = 0;
}

/* Authorises an operation on `path` with the file grant gh. Returns 0 (and, for a scoped grant, the canonical path to
 * use in `eff`, *scoped = 1) or a DEN_* code. The caller opens `eff`, not the original text: the checked path is the
 * used path (a ".." behind a symbolic link cannot differ between check and use). */
static int fs_check(int64_t gh, int write, OrinObj *path, char *eff, int *scoped) {
    Grant *g = grant_ref(gh, GK_FS);
    *scoped = 0;
    if (g->denied) return DEN_POLICY;
    if (write && g->readonly) return DEN_RDONLY;
    if (!g->scope) return 0;
    if (g->empty) return DEN_SCOPE;
    char abs[CAP_PATH + 1];
    int64_t al = orin_platform_path_absolute(orin_str_data(path), (size_t)orin_str_len(path), abs, sizeof abs);
    if (al <= 0) return DEN_RESOLVE;
    if (!orin_platform_path_within(g->scope, g->slen, abs, (size_t)al)) return DEN_SCOPE;
    int64_t rl = orin_platform_path_real(abs, (size_t)al, eff, CAP_PATH + 1);
    if (rl <= 0) return DEN_RESOLVE;
    if (!orin_platform_path_within(g->rscope, g->rlen, eff, (size_t)rl)) return DEN_SCOPE;
    *scoped = 1;
    return 0;
}

OrinObj *orin_fs_read_file(int64_t gh, OrinObj *path) {
    OrinString *p = (OrinString *)path;
    char eff[CAP_PATH + 1];
    int scoped, den = fs_check(gh, 0, path, eff, &scoped);
    if (den) return err_msg("cannot read", path, den_text(den));
    char *buf;
    size_t len;
    int rc = scoped ? orin_platform_file_read(eff, strlen_(eff), &buf, &len)
                    : orin_platform_file_read(p->data, p->len, &buf, &len);
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    if (rc) return err_result("cannot read", path, rc);
    OrinObj *s = orin_str_new(buf, len);
    orin_platform_free(buf);
    return orin_variant1(0, 1, ORIN_SLOT(s));
}

OrinObj *orin_fs_write_file(int64_t gh, OrinObj *path, OrinObj *data) {
    OrinString *p = (OrinString *)path, *d = (OrinString *)data;
    char eff[CAP_PATH + 1];
    int scoped, den = fs_check(gh, 1, path, eff, &scoped);
    if (den) return err_msg("cannot write", path, den_text(den));
    int rc = scoped ? orin_platform_file_write(eff, strlen_(eff), d->data, d->len)
                    : orin_platform_file_write(p->data, p->len, d->data, d->len);
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    if (rc) return err_result("cannot write", path, rc);
    return orin_ok_void();
}

/* A bool cannot carry a denial: a refused query traps (like every operation without a Result). */
int64_t orin_fs_exists(int64_t gh, OrinObj *path) {
    OrinString *p = (OrinString *)path;
    char eff[CAP_PATH + 1];
    int scoped, den = fs_check(gh, 0, path, eff, &scoped);
    if (den) trap_denied(GK_FS, "exists", den_text(den));
    return scoped ? orin_platform_file_exists(eff, strlen_(eff)) : orin_platform_file_exists(p->data, p->len);
}

/* ---------------------------------------------------------------- file resources (ADR-0025) */

enum { FILE_SLOTS = 256 };
typedef struct {
    orin_platform_stream *s; /* NULL = free */
    uint64_t gen;            /* incremented on every open of the slot; never 0 while open */
    int mode;                /* ORIN_PLATFORM_STREAM_* */
    int err;                 /* first runtime-detected error (wrong mode); 0 = none */
} FileSlot;
static __thread FileSlot g_files[FILE_SLOTS]; /* per task, like the grants; a task's open files are closed when it ends */

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
    if (h > 0 && h < GRANT_TAG) {
        uint64_t idx = (uint64_t)h & 255, gen = (uint64_t)h >> 8;
        if (g_files[idx].s && g_files[idx].gen == gen) return &g_files[idx];
    }
    orin_trap("invalid file handle (closed, stale or failed to open)");
}

static void file_fail(FileSlot *f, int code) {
    if (f->err == 0) f->err = code;
}

int64_t orin_file_open(int64_t gh, OrinObj *path, int64_t mode) {
    if (mode < 0 || mode > 2) return -ORIN_PLATFORM_EINVAL;
    char eff[CAP_PATH + 1];
    int scoped, den = fs_check(gh, mode != 0, path, eff, &scoped);
    if (den) return -(int64_t)den;
    int i = 0;
    while (i < FILE_SLOTS && g_files[i].s) i++;
    if (i == FILE_SLOTS) return -24; /* EMFILE: too many open files */
    orin_platform_stream *s;
    int rc = scoped ? orin_platform_stream_open(eff, strlen_(eff), (int)mode, &s)
                    : orin_platform_stream_open(orin_str_data(path), (size_t)orin_str_len(path), (int)mode, &s);
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
    if (h <= -DEN_POLICY && h >= -DEN_RESOLVE) {
        const char *t = den_text((int)-h);
        size_t n = strlen_(t);
        OrinString *m = str_alloc(n, 0);
        orin_platform_mem_copy(m->data, t, n);
        m->data[n] = 0;
        return &m->h;
    }
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

/* ---------------------------------------------------------------- network (ADR-0033)
 * NetGrant (kind 5), Listener (6) and Stream (7) are grant-table handles like the other grants: generation-checked, so a
 * forged, stale, closed or wrong-kind handle traps. The scope, the policy bit (ORIN_DENY=net) and the socket handling live
 * in the L0 record (`orin_platform_net`) and are checked by L0 before any system call; a refusal is the code EPERM
 * (reported as Err by std:net). An opener returns the handle or the NEGATED error code (as orin_file_open). */
enum { NET_BUF = 65536 };
static char g_netbuf[NET_BUF]; /* the bulk buffer between the u8[] arrays and L0 (single-threaded) */

int64_t orin_cap_net(int64_t host) {
    (void)grant_ref(host, GK_HOST);
    Grant *g = grant_new(GK_NET);
    orin_platform_net *n = &g->net;
    n->magic = ORIN_PLATFORM_NET_MAGIC, n->kind = ORIN_PLATFORM_NET_GRANT, n->can = ORIN_PLATFORM_NET_LISTEN | ORIN_PLATFORM_NET_CONNECT;
    n->fd = -1, n->deny = (g_deny & ORIN_PLATFORM_FAM_NET) != 0;
    for (int i = 0; i < 2; i++) n->sc[i].hl = 1, n->sc[i].h[0] = '*', n->sc[i].lo = 0, n->sc[i].hi = 65535;
    return grant_handle(g);
}

/* narrowing: what = LISTEN (host:port) or CONNECT (pattern, lo..hi). A request outside the parent's scope yields a grant
 * that reaches nothing; a malformed request (bad pattern or range) too. */
static int64_t net_narrow(int64_t parent, unsigned what, OrinObj *host, int64_t lo, int64_t hi) {
    Grant *p = grant_ref(parent, GK_NET);
    Grant *g = grant_new(GK_NET);
    int rc = lo < 0 || hi > 65535 || lo > hi ? ORIN_PLATFORM_EINVAL
                                              : orin_platform_net_narrow(&p->net, what, orin_str_data(host), (size_t)orin_str_len(host),
                                                                         (int)lo, (int)hi, &g->net);
    if (rc) {
        g->net = p->net;
        g->net.can = 0;
    }
    return grant_handle(g);
}
int64_t orin_cap_listen(int64_t net, OrinObj *addr, int64_t port) { return net_narrow(net, ORIN_PLATFORM_NET_LISTEN, addr, port, port); }
int64_t orin_cap_connect(int64_t net, OrinObj *pat, int64_t lo, int64_t hi) { return net_narrow(net, ORIN_PLATFORM_NET_CONNECT, pat, lo, hi); }

static int64_t net_done(Grant *g, int rc) { /* an opener's result: the handle, or the negated code with the slot freed */
    if (rc == 0) return grant_handle(g);
    g->live = 0;
    return -(int64_t)rc;
}

int64_t orin_net_listen(int64_t gh, OrinObj *addr, int64_t port, int64_t backlog, int64_t opt) {
    Grant *p = grant_ref(gh, GK_NET), *l = grant_new(GK_LISTENER);
    if (port < 0 || port > 65535 || backlog < 1 || backlog > 4096) return net_done(l, ORIN_PLATFORM_EINVAL);
    int bound = 0, rc = orin_platform_tcp_listen(&p->net, orin_str_data(addr), (size_t)orin_str_len(addr), (int)port, (int)backlog,
                                                 (int)opt, &l->net, &bound);
    l->port = bound;
    return net_done(l, rc);
}

int64_t orin_net_accept(int64_t lh, int64_t timeout_ms, int64_t opt) {
    Grant *l = grant_ref(lh, GK_LISTENER), *s = grant_new(GK_STREAM);
    if (timeout_ms < 0 || timeout_ms > ORIN_PLATFORM_NET_MAXMS) return net_done(s, ORIN_PLATFORM_EINVAL);
    int rc = orin_platform_tcp_accept(&l->net, (int)timeout_ms, (int)opt, &s->net, s->peer, sizeof s->peer, &s->port);
    return net_done(s, rc);
}

int64_t orin_net_connect(int64_t gh, OrinObj *host, int64_t port, int64_t timeout_ms, int64_t opt) {
    Grant *p = grant_ref(gh, GK_NET), *s = grant_new(GK_STREAM);
    if (port < 0 || port > 65535 || timeout_ms < 0 || timeout_ms > ORIN_PLATFORM_NET_MAXMS) return net_done(s, ORIN_PLATFORM_EINVAL);
    int rc = orin_platform_tcp_connect(&p->net, orin_str_data(host), (size_t)orin_str_len(host), (int)port, (int)timeout_ms, (int)opt, &s->net);
    s->port = (int)port;
    size_t n = (size_t)orin_str_len(host);
    n = n < sizeof s->peer - 1 ? n : sizeof s->peer - 1;
    orin_platform_mem_copy(s->peer, orin_str_data(host), n), s->peer[n] = 0;
    return net_done(s, rc);
}

/* 0 for an open handle, else the code of the failed open (a handle <= 0 is the negated code). */
int64_t orin_net_status(int64_t h) {
    if (h > 0) {
        (void)grant_ref(h, -1);
        return 0;
    }
    return h < 0 && h > -100000 ? -h : ORIN_PLATFORM_EINVAL;
}

void orin_net_close(int64_t h) {
    if (h <= 0) return; /* a failed open: nothing to release */
    Grant *g = grant_ref(h, -1);
    if (g->kind != GK_LISTENER && g->kind != GK_STREAM) orin_trap("invalid capability grant (forged, revoked, or of the wrong kind)");
    orin_platform_net_close(&g->net);
    g->live = 0;
}

int64_t orin_net_port(int64_t lh) { return grant_ref(lh, GK_LISTENER)->port; }

int64_t orin_net_now(int64_t h) {
    Grant *g = grant_ref(h, -1);
    if (g->kind < GK_NET) orin_trap("invalid capability grant (forged, revoked, or of the wrong kind)");
    return orin_platform_monotonic_millis();
}

/* Result<u8[], int>: Ok(1..min(cap, 64 KiB) bytes) or Err(code: NET_EOF / TIMEOUT / RESET / errno). One copy from the
 * L0 buffer into a fresh array (a u8 element is an 8-byte slot, ADR-0022). */
OrinObj *orin_net_recv(int64_t sh, uint64_t cap, int64_t timeout_ms) {
    Grant *s = grant_ref(sh, GK_STREAM);
    size_t n = 0, want = cap < NET_BUF ? (size_t)cap : NET_BUF;
    int rc = timeout_ms < 0 || timeout_ms > ORIN_PLATFORM_NET_MAXMS ? ORIN_PLATFORM_EINVAL
                                                                      : orin_platform_stream_recv(&s->net, g_netbuf, want, (int)timeout_ms, &n);
    if (rc != 0 || n == 0 || n > want) return orin_variant1(1, 0, (uint64_t)(rc ? rc : ORIN_PLATFORM_EINVAL));
    OrinObj *a = orin_array_new(n, 0);
    for (size_t i = 0; i < n; i++) orin_array_push(a, (uint64_t)(unsigned char)g_netbuf[i]);
    return orin_variant1(0, 1, ORIN_SLOT(a));
}

/* Result<usize, int>: sends from data[off .. off+len) (at most 64 KiB per call); Ok(bytes handed to the OS), Err(code). */
OrinObj *orin_net_send(int64_t sh, OrinObj *data, uint64_t off, uint64_t len, int64_t timeout_ms) {
    Grant *s = grant_ref(sh, GK_STREAM);
    OrinArray *a = (OrinArray *)data;
    if (data->kind != ORIN_K_ARRAY || off > a->len || len > a->len - off) orin_trap("net send: byte range out of bounds");
    size_t n = len < NET_BUF ? (size_t)len : NET_BUF, sent = 0;
    for (size_t i = 0; i < n; i++) g_netbuf[i] = (char)a->items[off + i];
    int rc = timeout_ms < 0 || timeout_ms > ORIN_PLATFORM_NET_MAXMS ? ORIN_PLATFORM_EINVAL
                                                                      : orin_platform_stream_send(&s->net, g_netbuf, n, (int)timeout_ms, &sent);
    return rc ? orin_variant1(1, 0, (uint64_t)rc) : orin_variant1(0, 0, (uint64_t)sent);
}

int64_t orin_net_shutdown(int64_t sh, int64_t how) {
    return orin_platform_net_shutdown(&grant_ref(sh, GK_STREAM)->net, (int)how);
}

/* "addr:port", an IPv6 address in brackets */
OrinObj *orin_net_peer(int64_t sh) {
    Grant *s = grant_ref(sh, GK_STREAM);
    char b[104], num[20];
    size_t n = 0, pl = strlen_(s->peer), k = orin_platform_fmt_i64(num, s->port);
    int v6 = 0;
    for (size_t i = 0; i < pl; i++) v6 |= s->peer[i] == ':';
    if (v6) b[n++] = '[';
    orin_platform_mem_copy(b + n, s->peer, pl), n += pl;
    if (v6) b[n++] = ']';
    b[n++] = ':';
    orin_platform_mem_copy(b + n, num, k), n += k;
    return orin_str_new(b, n);
}

/* Result<string, int>: the numeric addresses of a name, one per line */
OrinObj *orin_net_resolve(int64_t gh, OrinObj *name) {
    Grant *g = grant_ref(gh, GK_NET);
    size_t n = 0;
    int rc = orin_platform_dns_resolve(&g->net, orin_str_data(name), (size_t)orin_str_len(name), g_netbuf, 4096, &n);
    if (rc) return orin_variant1(1, 0, (uint64_t)rc);
    return orin_variant1(0, 1, ORIN_SLOT(orin_str_new(g_netbuf, n)));
}

OrinObj *orin_net_error_text(int64_t code) {
    const char *t = code == ORIN_PLATFORM_EPERM ? "permission denied: outside the granted network scope, or denied by the host policy (ORIN_DENY)"
                    : code == ORIN_PLATFORM_NET_EOF ? "connection closed by the peer"
                    : code == ORIN_PLATFORM_NET_TIMEOUT ? "timed out"
                    : code == ORIN_PLATFORM_NET_RESET ? "connection reset"
                    : code > 0 && code < 1000 ? orin_platform_error_message((int)code) : "network error";
    return orin_str_new(t, strlen_(t));
}

OrinObj *orin_process_args(int64_t gh) {
    (void)grant_use(gh, GK_PROCESS, "args");
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

/* ================================================================ tasks and transfer (ADR-0017 stage 0)
 * TEMPORARY C (spec 19 R3, docs/concurrency.md "Porting table"): everything between this banner and the end of the
 * file needs the object model (reference counts, struct / array / string layout, thread-local free lists) and
 * therefore cannot be written in Orin before R3. It is ONE small interface: orin_rt_transfer_* (move or deep copy
 * of a value between task heaps), orin_rt_task_* (start / join / trap of a task), orin_rt_heap_* (the per-thread
 * allocator state), plus forwarders that trap on a failed L0 call (orin_mon_*). Each function maps 1:1 onto a planned
 * Orin core-dialect function; no logic of the task library (scheduler bookkeeping, channels, scopes) lives here:
 * that is std:task (stdlib/task.or). Every task owns its heap: reference counts stay NON-atomic because an object
 * graph is only ever reachable from one thread at a time (a transfer moves a uniquely owned graph, or copies). */

/* Transfer slots: a value in flight between two tasks, owned by nobody. A token is `generation << 32 | (index + 1)`. */
typedef struct {
    OrinObj *box; /* NULL = free */
    uint32_t gen, next;
    OrinObj **pins; /* a LEND (see "lending" below): the objects this lend pinned; NULL for a value in flight */
    uint64_t npins;
    int lend;
} TrSlot;
static TrSlot *g_tr;
static uint32_t g_tr_n, g_tr_cap, g_tr_free; /* g_tr_free: 1-based head of the free list, 0 = empty */

static uint64_t tr_publish(OrinObj *box) {
    orin_platform_runtime_lock();
    if (!g_tr_free && g_tr_n == g_tr_cap) {
        uint32_t cap = g_tr_cap ? g_tr_cap * 2 : 256;
        TrSlot *t = (TrSlot *)orin_platform_realloc(g_tr, (size_t)cap * sizeof(TrSlot));
        if (!t) {
            orin_platform_runtime_unlock();
            orin_trap("out of memory");
        }
        g_tr = t;
        g_tr_cap = cap;
    }
    uint32_t i;
    if (g_tr_free) {
        i = g_tr_free - 1;
        g_tr_free = g_tr[i].next;
    } else {
        i = g_tr_n++;
        g_tr[i].gen = 0;
    }
    g_tr[i].box = box;
    g_tr[i].pins = NULL;
    g_tr[i].npins = 0;
    g_tr[i].lend = 0;
    g_tr[i].gen++;
    uint64_t tok = ((uint64_t)g_tr[i].gen << 32) | (i + 1);
    orin_platform_runtime_unlock();
    return tok;
}

/* Claims slot `tok`: a value in flight when `lend` is 0, a lend when it is 1 (then *pins / *npins get what it pinned). */
static OrinObj *tr_claim_kind(uint64_t tok, int lend, OrinObj ***pins, uint64_t *npins) {
    uint32_t i = (uint32_t)(tok & 0xffffffffu) - 1u;
    orin_platform_runtime_lock();
    if (tok == 0 || i >= g_tr_n || !g_tr[i].box || g_tr[i].gen != (uint32_t)(tok >> 32)) {
        orin_platform_runtime_unlock();
        orin_trap("invalid transfer token (taken twice, dropped, or forged)");
    }
    if (g_tr[i].lend != lend) {
        orin_platform_runtime_unlock();
        orin_trap("a lent value cannot be taken, only ended");
    }
    if (pins) {
        *pins = g_tr[i].pins;
        *npins = g_tr[i].npins;
    }
    g_tr[i].pins = NULL;
    g_tr[i].npins = 0;
    g_tr[i].lend = 0;
    OrinObj *b = g_tr[i].box;
    g_tr[i].box = NULL;
    g_tr[i].next = g_tr_free;
    g_tr_free = i + 1;
    orin_platform_runtime_unlock();
    return b;
}

static OrinObj *tr_claim(uint64_t tok) { return tr_claim_kind(tok, 0, NULL, NULL); }

/* Is `tok` a live lend? */
static int tr_is_lend(uint64_t tok) {
    uint32_t i = (uint32_t)(tok & 0xffffffffu) - 1u;
    orin_platform_runtime_lock();
    int r = tok != 0 && i < g_tr_n && g_tr[i].box && g_tr[i].gen == (uint32_t)(tok >> 32) && g_tr[i].lend;
    orin_platform_runtime_unlock();
    return r;
}

/* ---------------------------------------------------------------- lending (ADR-0039 §4: the borrowed input of `.parallel()`)
 * A LEND lets other tasks READ a value of the lending task for a bounded time without copying it. Reference counts are not
 * atomic, so a lent graph is PINNED: every object in it with a positive count gets the count PIN | owner << 32 | count,
 * which is negative, so retain / release (inline in the generated code of both backends) treat the object as immortal: a
 * reader never writes the shared count, and nothing in the graph is freed or changed in place (orin_make_unique copies an
 * object whose count is not 1). Ending the lend restores every count it pinned.
 *   * Sharing: a transfer (orin_rt_transfer_put) by the OWNER of a pin shares the pinned object instead of copying it: this
 *     is how the closure of a worker task reaches the lent array. A transfer by any OTHER task copies pinned objects, so a
 *     result sent back to the owner never refers into the lent graph (after the end that reference would be uncounted).
 *   * The owner's obligation (std:task `forkJoin` keeps it): between lend and end it only spawns the tasks that read the
 *     value and joins them, so every reference to a pinned object made meanwhile is gone before the end (a retain or a
 *     release of a pinned object is a no-op, so a reference that outlived the lend would be uncounted).
 *   * Not pinned (left to the copying transfer): an object with a count of 2^32 or more, and everything when the owner's
 *     thread id does not fit in 30 bits. Immortal objects (count -1) and objects pinned by another lend are skipped.
 * The lend token is a transfer slot whose box is a TWO-slot record { value, unused } (a value in flight has one slot). */
#define PIN_TAG ((uint64_t)1 << 63)
static inline int pin_is(int64_t rc) { return ((uint64_t)rc >> 62) == 2; }
static inline uint64_t pin_owner(int64_t rc) { return ((uint64_t)rc >> 32) & 0x3fffffffu; }
static int pinned_foreign(const OrinObj *o) { return pin_is(o->rc) && pin_owner(o->rc) != orin_platform_thread_id(); }

static uint64_t lend_put(OrinObj *box) {
    OrinStruct *s = (OrinStruct *)box;
    uint64_t tid = orin_platform_thread_id();
    size_t cap = 16, n = 0, sp = 0, scap = 64;
    OrinObj **pins = (OrinObj **)xmalloc(cap * sizeof *pins);
    OrinObj **st = (OrinObj **)xmalloc(scap * sizeof *st);
    if ((s->refmask & 1) && s->slots[0] && tid < ((uint64_t)1 << 30)) st[sp++] = ORIN_REF(s->slots[0]);
    while (sp) {
        OrinObj *x = st[--sp];
        if (x->rc <= 0 || (uint64_t)x->rc >= ((uint64_t)1 << 32)) continue;
        x->rc = (int64_t)(PIN_TAG | tid << 32 | (uint64_t)x->rc);
        if (n == cap) pins = (OrinObj **)xrealloc(pins, (cap *= 2) * sizeof *pins);
        pins[n++] = x;
        uint64_t *items = NULL, len = 0, mask = ~(uint64_t)0;
        if (x->kind == ORIN_K_STRUCT) {
            items = ((OrinStruct *)x)->slots;
            len = ((OrinStruct *)x)->nslots;
            mask = ((OrinStruct *)x)->refmask;
        } else if (x->kind == ORIN_K_ARRAY && ((OrinArray *)x)->is_ref) {
            items = ((OrinArray *)x)->items;
            len = ((OrinArray *)x)->len;
        }
        for (uint64_t i = 0; i < len; i++) {
            if (!((mask >> (i & 63)) & 1)) continue;
            OrinObj *c = ORIN_REF(items[i]);
            if (!c || c->rc <= 0) continue;
            if (sp == scap) st = (OrinObj **)xrealloc(st, (scap *= 2) * sizeof *st);
            st[sp++] = c;
        }
    }
    orin_platform_free(st);
    orin_retain(box); /* the slot keeps the box, and so the value, alive until the lend ends */
    uint64_t tok = tr_publish(box);
    uint32_t i = (uint32_t)(tok & 0xffffffffu) - 1u;
    orin_platform_runtime_lock();
    g_tr[i].pins = pins;
    g_tr[i].npins = n;
    g_tr[i].lend = 1;
    orin_platform_runtime_unlock();
    return tok;
}

static void lend_end(uint64_t tok) {
    OrinObj **pins = NULL;
    uint64_t n = 0;
    OrinObj *box = tr_claim_kind(tok, 1, &pins, &n);
    for (uint64_t i = 0; i < n; i++) pins[i]->rc = (int64_t)((uint64_t)pins[i]->rc & 0xffffffffu);
    orin_platform_free(pins);
    orin_release(box);
}

/* Is every object reachable from `root` referenced exactly once (immortals excepted)? Then the graph has no other
 * owner in this task and can change hands without copying. Iterative: a long list cannot overflow the C stack. */
static int graph_unique(OrinObj *root) {
    if (root->rc != 1) return 0;
    size_t cap = 64, sp = 0;
    OrinObj **st = (OrinObj **)xmalloc(cap * sizeof *st);
    st[sp++] = root;
    int ok = 1;
    while (sp && ok) {
        OrinObj *x = st[--sp];
        uint64_t *items = NULL;
        uint64_t n = 0;
        if (x->kind == ORIN_K_STRUCT) {
            OrinStruct *s = (OrinStruct *)x;
            for (uint32_t i = 0; i < s->nslots && ok; i++) {
                if (!((s->refmask >> i) & 1)) continue;
                OrinObj *c = ORIN_REF(s->slots[i]);
                if (c && c->rc < 0 && pinned_foreign(c)) {
                    ok = 0; /* another task's pinned object: copied, never shared (see "lending") */
                    break;
                }
                if (!c || c->rc < 0) continue;
                if (c->rc != 1) {
                    ok = 0;
                    break;
                }
                if (sp == cap) st = (OrinObj **)xrealloc(st, (cap *= 2) * sizeof *st);
                st[sp++] = c;
            }
        } else if (x->kind == ORIN_K_ARRAY && ((OrinArray *)x)->is_ref) {
            items = ((OrinArray *)x)->items;
            n = ((OrinArray *)x)->len;
            for (uint64_t i = 0; i < n; i++) {
                OrinObj *c = ORIN_REF(items[i]);
                if (c && c->rc < 0 && pinned_foreign(c)) {
                    ok = 0;
                    break;
                }
                if (!c || c->rc < 0) continue;
                if (c->rc != 1) {
                    ok = 0;
                    break;
                }
                if (sp == cap) st = (OrinObj **)xrealloc(st, (cap *= 2) * sizeof *st);
                st[sp++] = c;
            }
        }
    }
    orin_platform_free(st);
    return ok;
}

typedef struct {
    uint64_t *dst; /* where the copy of `src` has to be stored */
    OrinObj *src;
} CopyJob;

/* Deep copy of one object (not of its children): scalars are copied, reference slots get a job. */
static OrinObj *copy_node(OrinObj *x, CopyJob **jobs, size_t *n, size_t *cap) {
#define JOB(slotp, child)                                                                       \
    do {                                                                                        \
        OrinObj *c_ = (child);                                                                  \
        if (!c_ || (c_->rc < 0 && !pinned_foreign(c_))) {                                       \
            *(slotp) = ORIN_SLOT(c_);                                                           \
        } else {                                                                                \
            if (*n == *cap) *jobs = (CopyJob *)xrealloc(*jobs, (*cap *= 2) * sizeof(CopyJob)); \
            (*jobs)[(*n)++] = (CopyJob){(slotp), c_};                                           \
        }                                                                                       \
    } while (0)
    if (x->kind == ORIN_K_STRING) return orin_str_new(((OrinString *)x)->data, ((OrinString *)x)->len);
    if (x->kind == ORIN_K_ARRAY) {
        OrinArray *a = (OrinArray *)x;
        OrinObj *r = orin_array_new(a->len, (int64_t)a->is_ref);
        OrinArray *d = (OrinArray *)r;
        d->len = a->len;
        for (uint64_t i = 0; i < a->len; i++) {
            if (a->is_ref) JOB(&d->items[i], ORIN_REF(a->items[i]));
            else d->items[i] = a->items[i];
        }
        return r;
    }
    OrinStruct *s = (OrinStruct *)x;
    OrinObj *r = orin_struct_new(x->tag, s->nslots, s->refmask);
    OrinStruct *d = (OrinStruct *)r;
    for (uint32_t i = 0; i < s->nslots; i++) {
        if ((s->refmask >> i) & 1) JOB(&d->slots[i], ORIN_REF(s->slots[i]));
        else d->slots[i] = s->slots[i];
    }
    return r;
#undef JOB
}

static OrinObj *deep_copy(OrinObj *root) {
    size_t n = 0, cap = 64;
    CopyJob *jobs = (CopyJob *)xmalloc(cap * sizeof *jobs);
    OrinObj *r = copy_node(root, &jobs, &n, &cap);
    while (n) {
        CopyJob j = jobs[--n];
        *j.dst = ORIN_SLOT(copy_node(j.src, &jobs, &n, &cap));
    }
    orin_platform_free(jobs);
    return r;
}

/* Detach the value in `box` (a one-slot record the sender has just built and still owns) and publish it. Moved when
 * every reference in it is the only one (the sender's own copy is then empty and its release frees only the husk);
 * deep-copied otherwise. Either way the receiver gets a graph no other task can reach. */
uint64_t orin_rt_transfer_put(OrinObj *box) {
    if (box->kind == ORIN_K_STRUCT && ((OrinStruct *)box)->nslots == 2) return lend_put(box);
    if (box->kind != ORIN_K_STRUCT || ((OrinStruct *)box)->nslots != 1) orin_trap_shape();
    OrinStruct *s = (OrinStruct *)box;
    OrinObj *out;
    if (!(s->refmask & 1) || !s->slots[0]) {
        out = orin_struct_new(box->tag, 1, s->refmask);
        ((OrinStruct *)out)->slots[0] = s->slots[0];
    } else if (graph_unique(box)) {
        out = orin_struct_new(box->tag, 1, s->refmask);
        ((OrinStruct *)out)->slots[0] = s->slots[0];
        s->slots[0] = 0;
        orin_stats.transfer_moves++;
    } else {
        out = deep_copy(box);
        orin_stats.transfer_copies++;
    }
    return tr_publish(out);
}

OrinObj *orin_rt_transfer_take(uint64_t tok) { return tr_claim(tok); }
/* Ends a value in flight (frees it) or a lend (restores the counts it pinned). Only the owner holds a lend token. */
void orin_rt_transfer_drop(uint64_t tok) {
    if (tr_is_lend(tok)) lend_end(tok);
    else orin_release(tr_claim(tok));
}

/* The number of worker threads of a parallel pipeline (ADR-0039): ORIN_THREADS when it is a number from 1 to 1024,
 * otherwise the processors online. Results never depend on it (fixed chunks, combined in chunk order). */
static uint64_t par_threads(void) {
    const char *e = orin_platform_getenv("ORIN_THREADS");
    if (e && *e) {
        uint64_t v = 0;
        int ok = 1;
        for (const char *p = e; *p; p++) {
            if (*p < '0' || *p > '9' || v > 1024) {
                ok = 0;
                break;
            }
            v = v * 10 + (uint64_t)(*p - '0');
        }
        if (ok && v >= 1 && v <= 1024) return v;
    }
    return orin_platform_cpu_count();
}

/* 0: values moved by this task so far, 1: copied; 2: the thread count of parallel pipelines (par_threads). Query 2 shares
 * this function because both backends already declare it (the LLVM backend's list of runtime declarations was not
 * extended for parallel pipelines); it becomes `core.task.threads` with the rest of this section in R3. */
uint64_t orin_rt_transfer_count(uint64_t which) {
    return which == 0 ? orin_stats.transfer_moves : which == 1 ? orin_stats.transfer_copies : which == 2 ? par_threads() : 0;
}

/* ---------------------------------------------------------------- tasks */

enum { TASK_MSG = 480 };
typedef struct {
    uint64_t tok;       /* the transfer token of the task body (a closure) */
    int trapped;        /* written by the task thread, read after the join */
    char msg[TASK_MSG]; /* the trap message */
} RtTask;
static __thread RtTask *t_task;                        /* the task this thread runs, NULL on the main thread */
static __thread char t_joined_msg[TASK_MSG + 1];       /* message of the task joined last by this thread */

/* A task's heap ends: close what it left open, return its free lists to the allocator, fold its counters. */
void orin_rt_heap_exit(void) {
    for (int i = 0; i < GR_SLOTS; i++)
        if (g_grants[i].live) orin_cap_revoke(grant_handle(&g_grants[i]));
    files_at_exit();
    orin_platform_free(t_dstack);
    t_dstack = NULL;
    t_dcap = 0;
#ifndef ORIN_NO_FREELIST
    for (int c = 0; c < FL_STRUCT_CLASSES; c++)
        while (fl_struct[c]) {
            FreeNode *n = fl_struct[c];
            fl_struct[c] = n->next;
            fl_n[c]--;
            orin_platform_free(n);
        }
    while (fl_array) {
        FreeNode *n = fl_array;
        fl_array = n->next;
        fl_n[FL_STRUCT_CLASSES]--;
        orin_platform_free(n);
    }
#endif
    orin_platform_runtime_lock();
    g_fold_live += g_live;
    stats_add(&g_fold, &orin_stats);
    orin_platform_runtime_unlock();
}

static int task_active(void) { return t_task != NULL; }

/* Called by orin_trap on a task thread: record the message, end the task, never return. */
static void task_trap(const char *msg) {
    size_t n = 0;
    while (msg[n] && n < TASK_MSG - 1) n++;
    orin_platform_mem_copy(t_task->msg, msg, n);
    t_task->msg[n] = 0;
    t_task->trapped = 1;
    orin_rt_heap_exit();
    orin_platform_thread_exit();
}

static void task_main(void *p) {
    RtTask *t = (RtTask *)p;
    t_task = t;
    OrinObj *box = tr_claim(t->tok);
    OrinStruct *clo = (OrinStruct *)ORIN_REF(((OrinStruct *)box)->slots[0]);
    ((void (*)(OrinObj *))(uintptr_t)clo->slots[0])(ORIN_REF(clo->slots[1])); /* closure layout: docs/mir.md v1.3 */
    orin_release(box);
    orin_rt_heap_exit();
}

uint64_t orin_rt_task_spawn(uint64_t tok) {
    RtTask *t = (RtTask *)xmalloc(sizeof *t);
    t->tok = tok;
    t->trapped = 0;
    t->msg[0] = 0;
    int64_t h = orin_platform_thread_create(task_main, t);
    if (!h) {
        orin_platform_free(t);
        orin_rt_transfer_drop(tok);
        orin_trap("cannot start a task (thread limit reached)");
    }
    orin_stats.tasks_spawned++;
    return (uint64_t)h;
}

/* Waits for the task to end. 0: it returned; 1: it trapped (the message is kept for orin_rt_task_message). */
uint64_t orin_rt_task_join(uint64_t h) {
    void *arg = NULL;
    if (orin_platform_thread_join((int64_t)h, &arg) != 0) orin_trap("invalid task handle (joined twice, or forged)");
    RtTask *t = (RtTask *)arg;
    uint64_t st = (uint64_t)t->trapped;
    orin_platform_mem_copy(t_joined_msg, t->msg, TASK_MSG);
    t_joined_msg[TASK_MSG] = 0;
    orin_platform_free(t);
    return st;
}

OrinObj *orin_rt_task_message(void) {
    size_t n = 0;
    while (t_joined_msg[n]) n++;
    return orin_str_new(t_joined_msg, n);
}

/* ---------------------------------------------------------------- monitors (forwarders to L0 that trap on failure) */

static void mon_check(int rc) {
    if (rc == 0) return;
    if (rc == ORIN_PLATFORM_EDEADLK) orin_trap("monitor locked twice by the same task");
    if (rc == ORIN_PLATFORM_ENOMEM) orin_trap("out of memory");
    orin_trap("invalid monitor operation (stale handle, lock not held, or index out of range)");
}
uint64_t orin_mon_new(uint64_t n) {
    int64_t h = orin_platform_monitor_new((size_t)n);
    if (!h) orin_trap("cannot create a monitor (limit reached)");
    return (uint64_t)h;
}
void orin_mon_free(uint64_t m) { mon_check(orin_platform_monitor_free((int64_t)m)); }
void orin_mon_lock(uint64_t m) { mon_check(orin_platform_monitor_lock((int64_t)m)); }
void orin_mon_unlock(uint64_t m) { mon_check(orin_platform_monitor_unlock((int64_t)m)); }
void orin_mon_wait(uint64_t m, uint64_t c) { mon_check(orin_platform_monitor_wait((int64_t)m, (int)c)); }
void orin_mon_notify_all(uint64_t m, uint64_t c) { mon_check(orin_platform_monitor_notify((int64_t)m, (int)c, 1)); }
void orin_mon_notify_one(uint64_t m, uint64_t c) { mon_check(orin_platform_monitor_notify((int64_t)m, (int)c, 0)); }
uint64_t orin_mon_get(uint64_t m, uint64_t i) {
    uint64_t v = 0;
    mon_check(orin_platform_monitor_get((int64_t)m, (size_t)i, &v));
    return v;
}
void orin_mon_set(uint64_t m, uint64_t i, uint64_t v) { mon_check(orin_platform_monitor_set((int64_t)m, (size_t)i, v)); }
void orin_mon_grow(uint64_t m, uint64_t n) { mon_check(orin_platform_monitor_grow((int64_t)m, (size_t)n)); }

void orin_rt_trap_str(OrinObj *msg) {
    char buf[TASK_MSG];
    size_t n = (size_t)orin_str_len(msg);
    if (n > TASK_MSG - 1) n = TASK_MSG - 1;
    orin_platform_mem_copy(buf, orin_str_data(msg), n);
    buf[n] = 0;
    orin_trap(buf);
}

/* ---------------------------------------------------------------- grants moving into a task (ADR-0017, ADR-0027 Q10) */

typedef struct {
    Grant g; /* the detached grant: its scope strings belong to the slot until adopted */
    uint32_t gen, next;
    int used;
} GrantFlight;
static GrantFlight *g_gf;
static uint32_t g_gf_n, g_gf_cap, g_gf_free;

int64_t orin_cap_clone(int64_t h) {
    Grant *p = grant_ref(h, -1);
    if (p->kind < GK_FS || p->kind > GK_CLOCK) orin_trap("only a grant of a family (fs, process, stdio, clock) can be delegated to a task");
    Grant *g = grant_new(p->kind);
    grant_copy_into(g, p);
    return grant_handle(g);
}

uint64_t orin_cap_move(int64_t h) {
    Grant *g = grant_ref(h, -1);
    orin_platform_runtime_lock();
    if (!g_gf_free && g_gf_n == g_gf_cap) {
        uint32_t cap = g_gf_cap ? g_gf_cap * 2 : 16;
        GrantFlight *t = (GrantFlight *)orin_platform_realloc(g_gf, (size_t)cap * sizeof(GrantFlight));
        if (!t) {
            orin_platform_runtime_unlock();
            orin_trap("out of memory");
        }
        g_gf = t;
        g_gf_cap = cap;
    }
    uint32_t i;
    if (g_gf_free) {
        i = g_gf_free - 1;
        g_gf_free = g_gf[i].next;
    } else {
        i = g_gf_n++;
        g_gf[i].gen = 0;
    }
    g_gf[i].g = *g;
    g_gf[i].used = 1;
    g_gf[i].gen++;
    uint64_t tok = ((uint64_t)g_gf[i].gen << 32) | (i + 1);
    orin_platform_runtime_unlock();
    g->scope = g->rscope = NULL; /* the strings travel with the token */
    g->live = 0;
    return tok;
}

static int64_t cap_adopt(uint64_t tok, int kind) {
    uint32_t i = (uint32_t)(tok & 0xffffffffu) - 1u;
    orin_platform_runtime_lock();
    if (tok == 0 || i >= g_gf_n || !g_gf[i].used || g_gf[i].gen != (uint32_t)(tok >> 32)) {
        orin_platform_runtime_unlock();
        orin_trap("invalid grant token (adopted twice, or forged)");
    }
    Grant d = g_gf[i].g;
    g_gf[i].used = 0;
    g_gf[i].next = g_gf_free;
    g_gf_free = i + 1;
    orin_platform_runtime_unlock();
    if (d.kind != kind) {
        orin_platform_free(d.scope);
        orin_platform_free(d.rscope);
        orin_trap("grant token adopted as the wrong family");
    }
    Grant *g = grant_new(kind);
    d.gen = g->gen;
    *g = d;
    g->live = 1;
    return grant_handle(g);
}
int64_t orin_cap_adopt_fs(uint64_t t) { return cap_adopt(t, GK_FS); }
int64_t orin_cap_adopt_process(uint64_t t) { return cap_adopt(t, GK_PROCESS); }
int64_t orin_cap_adopt_stdio(uint64_t t) { return cap_adopt(t, GK_STDIO); }
int64_t orin_cap_adopt_clock(uint64_t t) { return cap_adopt(t, GK_CLOCK); }
