/*
 * Orin runtime (v1) -- shared by the code generators of all compiler stages.
 * Object model: docs/architecture.md "Runtime object model", ADR-0002.
 *
 * VALUES
 *   int -> int64_t, usize -> uint64_t, bool -> int64_t (0/1), float / f32 -> double (an f32 is a
 *   double that is exactly representable as a float; ADR-0018): unboxed scalars.
 *   Everything else (string, array, record, union, Option, Result) is an `OrinObj*`
 *   pointing at a reference-counted heap object. Generic containers store 64-bit "slots":
 *   a scalar's bits or a pointer (ORIN_SLOT / ORIN_REF convert).
 *
 * OWNERSHIP CONVENTION (what generated code must follow)
 *   - Function parameters are BORROWED. Return values are OWNED (+1).
 *   - "owned" results of runtime functions must be released (orin_release) or stored/returned.
 *   - Runtime functions BORROW their object arguments unless documented as "consumes".
 *   - Functions that store a value into a slot/array/struct ("consumes" / init functions)
 *     take over one count: pass an owned value (use orin_dup(x) to turn a borrowed x into
 *     an owned one).
 *   - Refcount < 0 means immortal (static literals, nullary-variant singletons): retain and
 *     release are no-ops. orin_release(NULL) is a no-op.
 *
 * COPY-ON-WRITE
 *   Objects are never mutated while shared. To mutate the object held by a slot/local:
 *       x = orin_make_unique(x);            (consumes the old reference, returns an owned one)
 *   which returns x itself when its count is 1, else a shallow copy (children retained).
 *   Walk a place path with orin_struct_slot_ptr / orin_array_slot_ptr and make each
 *   object on the path unique before writing (see codegen.rs).
 *
 * TRAPS: orin_trap(msg) flushes stdout, prints "trap: <msg>" on stderr, exits with 101.
 */
#ifndef ORIN_RUNTIME_H
#define ORIN_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORIN_UNLIKELY(x) __builtin_expect(!!(x), 0)
#define ORIN_LIKELY(x) __builtin_expect(!!(x), 1)

/* ---------------------------------------------------------------- object layout */

enum { ORIN_K_STRING = 1, ORIN_K_ARRAY = 2, ORIN_K_STRUCT = 3 };

typedef struct OrinObj {
    int64_t rc;    /* >0 live count, <0 immortal */
    uint32_t kind; /* ORIN_K_* */
    uint32_t tag;  /* variant tag (struct kind only; records use 0) */
} OrinObj;

typedef struct OrinString {
    OrinObj h;
    uint64_t len;
    uint64_t cap; /* bytes available in data (excluding the NUL terminator) */
    char data[];  /* len bytes + NUL */
} OrinString;

typedef struct OrinArray {
    OrinObj h;
    uint64_t len;
    uint64_t cap;
    uint64_t is_ref; /* 1 if elements are references (retained/released), else raw scalars */
    uint64_t *items;
} OrinArray;

typedef struct OrinStruct {
    OrinObj h; /* h.tag = variant tag */
    uint32_t nslots;
    uint32_t pad;
    uint64_t refmask; /* bit i set: slot i is a reference (max 64 slots) */
    uint64_t slots[];
} OrinStruct;

#define ORIN_SLOT(p) ((uint64_t)(uintptr_t)(p)) /* reference -> slot */

/* float <-> slot: the 64-bit pattern of the double (ADR-0018). */
static inline uint64_t orin_f2s(double d) {
    union { double d; uint64_t u; } v;
    v.d = d;
    return v.u;
}
static inline double orin_s2f(uint64_t u) {
    union { double d; uint64_t u; } v;
    v.u = u;
    return v.d;
}
#define ORIN_REF(s) ((OrinObj *)(uintptr_t)(s)) /* slot -> reference */

/*
 * Immortal static string literal. Defines `static OrinObj *const name`.
 *   ORIN_STRING_LIT(orin_s0, 5, "hello");   n = byte length of the literal's contents.
 * Write non-printable / non-ASCII bytes as 3-digit octal escapes.
 */
#define ORIN_STRING_LIT(name, n, bytes)                                                         \
    static struct {                                                                             \
        OrinObj h;                                                                              \
        uint64_t len;                                                                           \
        uint64_t cap;                                                                           \
        char data[(n) + 1];                                                                     \
    } name##_obj = {{-1, ORIN_K_STRING, 0}, (n), (n), bytes};                                   \
    static OrinObj *const name = (OrinObj *)&name##_obj

/* ---------------------------------------------------------------- lifecycle */

/* Call first in main(). Stores argc/argv for process.args and sets up stdout buffering. */
void orin_init(int argc, char **argv);
/* Flush buffered stdout (called by orin_process_exit, orin_trap; call before returning from main). */
void orin_flush(void);
void orin_trap(const char *msg) __attribute__((noreturn, cold));
/* Number of live (non-immortal) heap objects; for leak/UAF tests. */
int64_t orin_live_count(void);

void orin_destroy(OrinObj *o); /* internal: free an object whose count reached 0 */

/* Opt-in statistics (plain counters, always compiled in; printed as one JSON line on stderr at
 * exit only when the environment variable ORIN_STATS=1). retains/releases count only
 * non-immortal objects. Bytes are approximate (object + buffer capacity, excluding malloc
 * overhead). */
typedef struct OrinStats {
    uint64_t alloc_string, alloc_array, alloc_struct; /* object allocations by kind */
    uint64_t frees;                                   /* objects freed */
    uint64_t retains, releases;                       /* rc increments / decrements (incl. children released by destroy) */
    uint64_t cow_copies, cow_inplace;                 /* orin_make_unique: copied vs rc==1 reuse */
    uint64_t array_grows;                             /* array buffer growth reallocations */
    uint64_t string_grows;                            /* in-place string append reallocations */
    uint64_t peak_live_objs, peak_live_bytes;
    uint64_t live_bytes;
} OrinStats;
extern OrinStats orin_stats;

static inline void orin_retain(OrinObj *o) {
    if (ORIN_LIKELY(o->rc > 0)) {
        o->rc++;
        orin_stats.retains++;
    }
}
/* retain and return (turn a borrowed value into an owned one). */
static inline OrinObj *orin_dup(OrinObj *o) {
    if (ORIN_LIKELY(o->rc > 0)) {
        o->rc++;
        orin_stats.retains++;
    }
    return o;
}
/* NULL-safe. */
static inline void orin_release(OrinObj *o) {
    if (o && o->rc > 0) {
        orin_stats.releases++;
        if (ORIN_UNLIKELY(--o->rc == 0)) orin_destroy(o);
    }
}

/* Returns o if o->rc == 1, else a shallow copy (ref children retained) and releases one
 * count of o. Consumes the caller's reference to o, returns an owned one. */
OrinObj *orin_make_unique_slow(OrinObj *o); /* internal: the copying path */
static inline OrinObj *orin_make_unique(OrinObj *o) {
    if (ORIN_LIKELY(o->rc == 1)) {
        orin_stats.cow_inplace++;
        return o;
    }
    return orin_make_unique_slow(o);
}

/* ---------------------------------------------------------------- checked arithmetic */

static inline int64_t orin_add_i(int64_t a, int64_t b) {
    int64_t r;
    if (ORIN_UNLIKELY(__builtin_add_overflow(a, b, &r))) orin_trap("integer overflow");
    return r;
}
static inline int64_t orin_sub_i(int64_t a, int64_t b) {
    int64_t r;
    if (ORIN_UNLIKELY(__builtin_sub_overflow(a, b, &r))) orin_trap("integer overflow");
    return r;
}
static inline int64_t orin_mul_i(int64_t a, int64_t b) {
    int64_t r;
    if (ORIN_UNLIKELY(__builtin_mul_overflow(a, b, &r))) orin_trap("integer overflow");
    return r;
}
static inline int64_t orin_div_i(int64_t a, int64_t b) {
    if (ORIN_UNLIKELY(b == 0)) orin_trap("division by zero");
    if (ORIN_UNLIKELY(a == INT64_MIN && b == -1)) orin_trap("integer overflow");
    return a / b;
}
static inline int64_t orin_rem_i(int64_t a, int64_t b) {
    if (ORIN_UNLIKELY(b == 0)) orin_trap("modulo by zero");
    if (ORIN_UNLIKELY(a == INT64_MIN && b == -1)) orin_trap("integer overflow");
    return a % b;
}
static inline int64_t orin_neg_i(int64_t a) {
    if (ORIN_UNLIKELY(a == INT64_MIN)) orin_trap("integer overflow");
    return -a;
}
static inline uint64_t orin_add_u(uint64_t a, uint64_t b) {
    uint64_t r;
    if (ORIN_UNLIKELY(__builtin_add_overflow(a, b, &r))) orin_trap("usize overflow");
    return r;
}
static inline uint64_t orin_sub_u(uint64_t a, uint64_t b) {
    uint64_t r;
    if (ORIN_UNLIKELY(__builtin_sub_overflow(a, b, &r))) orin_trap("usize underflow");
    return r;
}
static inline uint64_t orin_mul_u(uint64_t a, uint64_t b) {
    uint64_t r;
    if (ORIN_UNLIKELY(__builtin_mul_overflow(a, b, &r))) orin_trap("usize overflow");
    return r;
}
static inline uint64_t orin_div_u(uint64_t a, uint64_t b) {
    if (ORIN_UNLIKELY(b == 0)) orin_trap("division by zero");
    return a / b;
}
static inline uint64_t orin_rem_u(uint64_t a, uint64_t b) {
    if (ORIN_UNLIKELY(b == 0)) orin_trap("modulo by zero");
    return a % b;
}
static inline uint64_t orin_neg_u(uint64_t a) {
    if (ORIN_UNLIKELY(a != 0)) orin_trap("usize underflow");
    return 0;
}
static inline uint64_t orin_int_to_usize(int64_t a) {
    if (ORIN_UNLIKELY(a < 0)) orin_trap("negative int to usize");
    return (uint64_t)a;
}
static inline int64_t orin_usize_to_int(uint64_t a) {
    if (ORIN_UNLIKELY(a > (uint64_t)INT64_MAX)) orin_trap("usize too large for int");
    return (int64_t)a;
}

/* ---------------------------------------------------------------- structs / variants */
/* Records use tag 0. Option: Some=0 (1 slot), None=1. Result: Ok=0 (1 slot, 0 for void), Err=1. */

/* New struct with all slots zero (null refs). Fill with orin_struct_set (init only). */
OrinObj *orin_struct_new(uint32_t tag, uint32_t nslots, uint64_t refmask);
/* Shared immortal singleton for a payload-less variant. */
OrinObj *orin_nullary(uint32_t tag);
/* Variant with one slot; consumes the slot's reference if the slot is a ref (refmask 0/1). */
OrinObj *orin_variant1(uint32_t tag, uint64_t refmask, uint64_t slot);
/* dst.slots[i] = src.slots[j], retaining it if it is a reference. dst slot must be empty. */
void orin_struct_copy_slot(OrinObj *dst, uint32_t i, OrinObj *src, uint32_t j);
/* Initialising store (no release of the old value; consumes `slot`'s reference). */
static inline void orin_struct_set(OrinObj *o, uint32_t i, uint64_t slot) {
    ((OrinStruct *)o)->slots[i] = slot;
}
/* Borrowed slot read. */
static inline uint64_t orin_struct_get(const OrinObj *o, uint32_t i) {
    return ((const OrinStruct *)o)->slots[i];
}
/* Pointer to slot i for in-place update (object must already be unique). */
static inline uint64_t *orin_struct_slot_ptr(OrinObj *o, uint32_t i) {
    return &((OrinStruct *)o)->slots[i];
}
static inline uint32_t orin_tag(const OrinObj *o) { return o->tag; }

/* Option / Result helpers (return borrowed slots; trap on the wrong variant). */
static inline OrinObj *orin_none(void) { return orin_nullary(1); }
static inline OrinObj *orin_ok_void(void) { return orin_nullary(0); }
uint64_t orin_opt_unwrap(OrinObj *o);
uint64_t orin_res_unwrap(OrinObj *o);
uint64_t orin_res_unwrap_err(OrinObj *o);

/* ---------------------------------------------------------------- strings (all byte strings) */

OrinObj *orin_str_new(const char *p, uint64_t n); /* owned copy */
OrinObj *orin_str_concat(OrinObj *a, OrinObj *b);
/* a += b. CONSUMES a, returns owned result; in place (amortised O(1)) when a is unique. */
OrinObj *orin_str_append(OrinObj *a, OrinObj *b);
int64_t orin_str_eq(OrinObj *a, OrinObj *b);
static inline uint64_t orin_str_len(const OrinObj *s) { return ((const OrinString *)s)->len; }
static inline const char *orin_str_data(const OrinObj *s) { return ((const OrinString *)s)->data; }
/* Inline: the std prelude (std/) loops over bytes with it. */
static inline int64_t orin_str_char_code_at(OrinObj *s, uint64_t i) {
    const OrinString *x = (const OrinString *)s;
    if (ORIN_UNLIKELY(i >= x->len)) orin_trap("charCodeAt index out of range");
    return (unsigned char)x->data[i];
}
OrinObj *orin_str_char_at(OrinObj *s, uint64_t i);
OrinObj *orin_str_substring(OrinObj *s, uint64_t a, uint64_t b);
OrinObj *orin_str_index_of(OrinObj *s, OrinObj *needle); /* Option<usize> */
int64_t orin_str_includes(OrinObj *s, OrinObj *needle);
int64_t orin_str_starts_with(OrinObj *s, OrinObj *p);
int64_t orin_str_ends_with(OrinObj *s, OrinObj *p);
OrinObj *orin_str_split(OrinObj *s, OrinObj *sep); /* string[]; traps if sep is empty */
OrinObj *orin_str_trim(OrinObj *s);
OrinObj *orin_string_from_char_code(int64_t c); /* c in 0..255 else trap */
OrinObj *orin_int_to_string(int64_t v);
OrinObj *orin_usize_to_string(uint64_t v);
OrinObj *orin_bool_to_string(int64_t v);
OrinObj *orin_parse_int(OrinObj *s); /* Option<int> */
/* Floats (ADR-0018). toString: shortest round-tripping digits, JavaScript-like layout (see the ADR). */
OrinObj *orin_float_to_string(double x);
OrinObj *orin_f32_to_string(double x); /* x holds a binary32 value */
OrinObj *orin_parse_float(OrinObj *s);  /* Option<float> */
int64_t orin_float_to_int(double x);    /* truncates toward zero; traps on NaN / out of range */

/* ---------------------------------------------------------------- arrays */

OrinObj *orin_array_new(uint64_t cap, int64_t is_ref);
/* Append in place; array must be unique (rc==1). Consumes the slot's reference. */
void orin_array_push_grow(OrinObj *a, uint64_t slot); /* internal: capacity exhausted */
static inline void orin_array_push(OrinObj *o, uint64_t slot) {
    OrinArray *a = (OrinArray *)o;
    if (ORIN_UNLIKELY(a->len == a->cap)) {
        orin_array_push_grow(o, slot);
        return;
    }
    a->items[a->len++] = slot;
}
/* Remove last element in place (array must be unique): Option<T> owning the element. */
OrinObj *orin_array_pop(OrinObj *a);
static inline uint64_t orin_array_len(const OrinObj *a) { return ((const OrinArray *)a)->len; }
/* Borrowed element slot; traps "index out of bounds". */
static inline uint64_t orin_array_at(OrinObj *o, uint64_t i) {
    OrinArray *a = (OrinArray *)o;
    if (ORIN_UNLIKELY(i >= a->len)) orin_trap("index out of bounds");
    return a->items[i];
}
/* Pointer to element slot for in-place update (array must be unique); traps if out of range. */
static inline uint64_t *orin_array_slot_ptr(OrinObj *o, uint64_t i) {
    OrinArray *a = (OrinArray *)o;
    if (ORIN_UNLIKELY(i >= a->len)) orin_trap("index out of bounds");
    return &a->items[i];
}
OrinObj *orin_array_get(OrinObj *a, uint64_t i); /* Option<T> (element retained) */
OrinObj *orin_array_slice(OrinObj *a, uint64_t from, uint64_t to);
OrinObj *orin_array_concat(OrinObj *a, OrinObj *b);
OrinObj *orin_array_join(OrinObj *a, OrinObj *sep); /* string[] -> string */

/* ---------------------------------------------------------------- I/O and process */

void orin_console_log(OrinObj *s);   /* stdout (buffered) + "\n" */
void orin_console_error(OrinObj *s); /* flushes stdout first, then stderr + "\n" */
OrinObj *orin_fs_read_file(OrinObj *path);                 /* Result<string,string> */
OrinObj *orin_fs_write_file(OrinObj *path, OrinObj *data); /* Result<void,string> */
int64_t orin_fs_exists(OrinObj *path);
OrinObj *orin_process_args(void); /* new string[] (without program name) */
void orin_process_exit(int64_t code) __attribute__((noreturn)); /* flushes stdout */

#ifdef __cplusplus
}
#endif
#endif
