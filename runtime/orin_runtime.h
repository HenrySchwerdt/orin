/*
 * Orin runtime (v1) -- shared by the code generators of all compiler stages.
 * Object model: docs/architecture.md "Runtime object model", ADR-0002.
 *
 * VALUES
 *   int / i8..i32 / u8..u32 / isize -> int64_t, usize / u64 -> uint64_t (ADR-0022), bool -> int64_t (0/1), float / f32 -> double (an f32 is a
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
/* Number of live (non-immortal) heap objects; for leak/UAF tests. Counts the calling thread's allocations minus its
 * frees plus the net of all finished tasks (an object moved between tasks is allocated by one and freed by another). */
int64_t orin_live_count(void);

void orin_destroy(OrinObj *o); /* internal: free an object whose count reached 0 */

/* ---------------------------------------------------------------- tasks (ADR-0017 stage 0, docs/concurrency.md)
 * TEMPORARY interface (spec 19 R3): the part of task support that needs the object model. Each function maps 1:1 onto
 * a planned Orin core-dialect function (docs/concurrency.md "Porting table"). Everything else of std:task is Orin.
 *   transfer: a value changes task heaps. `box` is a record with ONE slot that the sender has just built (so the value
 *     in it was consumed by the sender); put detaches the value (moved if its whole graph is uniquely owned, deep-copied
 *     otherwise; a copy is a fresh graph nobody else can reach) and returns a token; take returns the box (owned by the
 *     caller, now in ITS heap); drop frees it. A token is valid for exactly one take or drop; anything else traps.
 *   task: spawn starts a thread that takes the closure `() => void` out of the token, runs it and ends; join waits
 *     (0: it returned, 1: it trapped, the message is then available from orin_rt_task_message). A trap on a task thread
 *     ends only that task. */
uint64_t orin_rt_transfer_put(OrinObj *box);
OrinObj *orin_rt_transfer_take(uint64_t token);
void orin_rt_transfer_drop(uint64_t token);
uint64_t orin_rt_transfer_count(uint64_t which); /* 0: values moved by this task so far, 1: copied */
uint64_t orin_rt_task_spawn(uint64_t token);
uint64_t orin_rt_task_join(uint64_t thread);
OrinObj *orin_rt_task_message(void);
void orin_rt_trap_str(OrinObj *msg) __attribute__((noreturn)); /* trap with the text of an Orin string */
void orin_rt_heap_exit(void);                                   /* end of a task's heap (called by the runtime itself) */
/* monitors (L0, platform layer): forwarders that trap on an invalid handle / unlocked access */
uint64_t orin_mon_new(uint64_t nwords);
void orin_mon_free(uint64_t m);
void orin_mon_lock(uint64_t m);
void orin_mon_unlock(uint64_t m);
void orin_mon_wait(uint64_t m, uint64_t cond);       /* cond: 0 or 1, the two condition queues of a monitor */
void orin_mon_notify_all(uint64_t m, uint64_t cond);
void orin_mon_notify_one(uint64_t m, uint64_t cond);
uint64_t orin_mon_get(uint64_t m, uint64_t i);
void orin_mon_set(uint64_t m, uint64_t i, uint64_t v);
void orin_mon_grow(uint64_t m, uint64_t nwords);

/* ---------------------------------------------------------------- file resources (ADR-0025)
 * A file handle is an int64_t: a positive generation-tagged index into a fixed table of open streams
 * (generation * 256 + slot), or the NEGATED errno-style code of a failed open. Handles are scalars at the
 * language level (MIR class `MHandle`); the compiler guarantees (checker rules + MIR verifier) that a handle is
 * only passed to functions, never copied, stored, returned or compared, and is closed exactly once on every
 * path. The runtime does not rely on that: every operation validates the handle and TRAPS ("invalid file
 * handle") on a closed, stale or foreign one, so a compiler bug can never become memory unsafety.
 * At most 256 files are open at the same time (open fails with EMFILE beyond that). Streams still open at
 * process end (a trap inside the scope callback, process.exit) are flushed and closed by an exit hook. Errors
 * of read/write/flush are sticky per file and are reported by the close that ends the scope. */
int64_t orin_file_open(int64_t fs, OrinObj *path, int64_t mode); /* mode 0 read, 1 write (truncate), 2 append; fs = file grant */
int64_t orin_file_is_open(int64_t h);                 /* 1 if h came from a successful open, else 0 */
OrinObj *orin_file_open_error(int64_t h);             /* string: why the open failed (h <= 0) */
OrinObj *orin_file_close(int64_t h);                  /* Option<string>: Some(message) if any operation failed */
OrinObj *orin_file_read_line(int64_t h);              /* Option<string>: next line without "\n"/"\r\n"; None at EOF */
OrinObj *orin_file_read(int64_t h, uint64_t n);       /* Option<string>: up to n bytes; None at EOF (n > 0) */
OrinObj *orin_file_read_all(int64_t h);               /* string: the rest of the file */
void orin_file_write(int64_t h, OrinObj *s);
void orin_file_write_line(int64_t h, OrinObj *s);     /* s followed by "\n" */
void orin_file_flush(int64_t h);

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
    uint64_t file_opens, file_closes;                 /* resource handles (ADR-0025): successful opens / closes */
    uint64_t transfer_moves, transfer_copies;         /* values sent between tasks (ADR-0017): moved without a copy / deep-copied */
    uint64_t tasks_spawned;
} OrinStats;
/* Per THREAD (every task has its own heap and its own counters; a finished task's counters are folded into the
 * process totals, which the ORIN_STATS report prints together with the main thread's). */
/* The counters live in one executable (never a shared library), so on ELF targets the access can use the local-exec TLS model: one
 * instruction per counter update, like the plain global it replaced (measured: instruction counts of the benchmarks are unchanged). */
#if defined(__ELF__)
#define ORIN_TLS_MODEL __attribute__((tls_model("local-exec")))
#else
#define ORIN_TLS_MODEL
#endif
extern __thread OrinStats orin_stats ORIN_TLS_MODEL;

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

/* Fixed-width integers (ADR-0022). Types narrower than 64 bits live in int64_t locals; after an operation the
 * result is range-checked. Conversions trap when the value does not fit. Kinds: 0 i8, 1 i16, 2 i32, 3 i64, 4 isize,
 * 5 u8, 6 u16, 7 u32, 8 u64, 9 usize (see orin_runtime.c). */
static inline int64_t orin_range_i(int64_t v, int64_t lo, int64_t hi) {
    if (ORIN_UNLIKELY(v < lo || v > hi)) orin_trap("integer overflow");
    return v;
}
static inline int64_t orin_conv_i(int64_t v, int64_t lo, int64_t hi) {
    if (ORIN_UNLIKELY(v < lo || v > hi)) orin_trap("integer conversion out of range");
    return v;
}
static inline int64_t orin_conv_u(uint64_t v, int64_t hi) {
    if (ORIN_UNLIKELY(v > (uint64_t)hi)) orin_trap("integer conversion out of range");
    return (int64_t)v;
}
uint64_t orin_int_op(int64_t mode, uint64_t a, uint64_t b, int64_t kind); /* wrapping (0..2) / saturating (3..5) add sub mul */
OrinObj *orin_int_chk(int64_t mode, uint64_t a, uint64_t b, int64_t kind); /* checked add sub mul: Option */
OrinObj *orin_parse_int_k(OrinObj *s, int64_t kind);                      /* Option of the parsed integer */

/* ---------------------------------------------------------------- structs / variants */
/* Records use tag 0. Option: Some=0 (1 slot), None=1. Result: Ok=0 (1 slot, 0 for void), Err=1. */

/* New struct with all slots zero (null refs). Fill with orin_struct_init (init only). */
OrinObj *orin_struct_new(uint32_t tag, uint32_t nslots, uint64_t refmask);
/* Shared immortal singleton for a payload-less variant. */
OrinObj *orin_nullary(uint32_t tag);
/* Variant with one slot; consumes the slot's reference if the slot is a ref (refmask 0/1). */
OrinObj *orin_variant1(uint32_t tag, uint64_t refmask, uint64_t slot);
/* dst.slots[i] = src.slots[j], retaining it if it is a reference. dst slot must be empty. */
void orin_struct_copy_slot(OrinObj *dst, uint32_t i, OrinObj *src, uint32_t j);
/* Defence in depth (docs/assurance.md, finding "shape confusion"): every field access on an object of unknown
 * provenance checks that it is a struct and that the slot index is below its slot count, so a lowering bug that
 * confuses value shapes becomes a clean trap instead of an out-of-bounds read or write. The ownership verifier
 * does not check value shapes. The LLVM backend does the same check in its inline helper @orinl_slot. */
void orin_trap_shape(void) __attribute__((noreturn, cold));
static inline void orin_chk_slot(const OrinObj *o, uint32_t i) {
    if (ORIN_UNLIKELY(o->kind != ORIN_K_STRUCT || i >= ((const OrinStruct *)o)->nslots)) orin_trap_shape();
}
/* Initialising store into an object that orin_struct_new just returned in the same code sequence with a constant
 * slot count (the emitters pass the index from the same MIR instruction): in bounds by construction, unchecked. */
static inline void orin_struct_init(OrinObj *o, uint32_t i, uint64_t slot) {
    ((OrinStruct *)o)->slots[i] = slot;
}
/* Store (no release of the old value; consumes `slot`'s reference). Checked. */
static inline void orin_struct_set(OrinObj *o, uint32_t i, uint64_t slot) {
    orin_chk_slot(o, i);
    ((OrinStruct *)o)->slots[i] = slot;
}
/* Borrowed slot read. Checked. */
static inline uint64_t orin_struct_get(const OrinObj *o, uint32_t i) {
    orin_chk_slot(o, i);
    return ((const OrinStruct *)o)->slots[i];
}
/* Pointer to slot i for in-place update (object must already be unique). Checked. */
static inline uint64_t *orin_struct_slot_ptr(OrinObj *o, uint32_t i) {
    orin_chk_slot(o, i);
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
    if (ORIN_UNLIKELY(o->kind != ORIN_K_ARRAY)) orin_trap_shape();
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
    if (ORIN_UNLIKELY(o->kind != ORIN_K_ARRAY)) orin_trap_shape();
    if (ORIN_UNLIKELY(i >= a->len)) orin_trap("index out of bounds");
    return a->items[i];
}
/* Pointer to element slot for in-place update (array must be unique); traps if out of range. */
static inline uint64_t *orin_array_slot_ptr(OrinObj *o, uint64_t i) {
    OrinArray *a = (OrinArray *)o;
    if (ORIN_UNLIKELY(o->kind != ORIN_K_ARRAY)) orin_trap_shape();
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
OrinObj *orin_fs_read_file(int64_t fs, OrinObj *path);                 /* Result<string,string> */
OrinObj *orin_fs_write_file(int64_t fs, OrinObj *path, OrinObj *data); /* Result<void,string> */
int64_t orin_fs_exists(int64_t fs, OrinObj *path);
OrinObj *orin_process_args(int64_t proc); /* new string[] (without program name) */

/* ---------------------------------------------------------------- capability grants (ADR-0021 Stage A, ADR-0027)
 * Every privileged operation above and in orin_runtime_io.h takes a grant handle first (int64_t, tagged, generation-
 * checked; see orin_runtime.c). The root handle of the program is created only here, for `main(host: Host)`. */
int64_t orin_cap_host_root(void);                              /* the Host handle; reads ORIN_DENY (traps if malformed) */
int64_t orin_cap_acquire(int64_t host, int64_t family);        /* family 1 fs, 2 process, 3 stdio, 4 clock */
int64_t orin_cap_narrow(int64_t parent, int64_t op, OrinObj *arg); /* op 0 fs under(arg), 1 fs readOnly, 2 process argsOnly */
/* plain-call forms of the above, one per builtin (used by both backends) */
int64_t orin_cap_fs(int64_t host);
int64_t orin_cap_process(int64_t host);
int64_t orin_cap_stdio(int64_t host);
int64_t orin_cap_clock(int64_t host);
int64_t orin_cap_under(int64_t fs, OrinObj *path);
int64_t orin_cap_read_only(int64_t fs);
int64_t orin_cap_args_only(int64_t proc);
void orin_cap_revoke(int64_t grant);                           /* end of the scope that acquired / narrowed it */
/* Moving a grant into a task (ADR-0017, ADR-0027 Q10): clone derives a grant with the same authority (never more);
 * move detaches it into a one-shot token (the handle is dead afterwards, like after revoke); adopt_* makes the token a
 * live grant of the calling task, of the family the function names. A token adopted twice, or as the wrong family, traps.
 * Handles are per task: a grant handle used on another thread than the one that made it traps. */
int64_t orin_cap_clone(int64_t grant);
uint64_t orin_cap_move(int64_t grant);
int64_t orin_cap_adopt_fs(uint64_t token);
int64_t orin_cap_adopt_process(uint64_t token);
int64_t orin_cap_adopt_stdio(uint64_t token);
int64_t orin_cap_adopt_clock(uint64_t token);
void orin_cap_require(int64_t grant, int64_t kind, const char *what); /* traps unless valid, of `kind` and not denied */
void orin_cap_require_spawn(int64_t proc);                     /* traps unless the process grant may spawn */
void orin_process_exit(int64_t code) __attribute__((noreturn)); /* flushes stdout */

#ifdef __cplusplus
}
#endif
#endif
