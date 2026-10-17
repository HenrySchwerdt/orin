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
#ifdef ORIN_SITE_STATS
    uint32_t site; /* allocation-site census only (see "Allocation-site census" below): the site that allocated it */
    uint32_t site_pad;
#endif
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
 *     A box only the sender references is published itself (retained; no second box): the sender must release its
 *     reference before the token reaches another task (std:task's putBox does; a monitor or a thread start orders it).
 *   task: spawn starts a thread that takes the closure `() => void` out of the token, runs it and ends; join waits
 *     (0: it returned, 1: it trapped, the message is then available from orin_rt_task_message). A trap on a task thread
 *     ends only that task.
 *   lend (ADR-0039, `.parallel()`): orin_rt_lend of a TWO-slot record { value, _ } pins the value's graph for reading by the tasks
 *     the owner spawns next (their closures share it instead of copying it); drop of that token ends the lend and
 *     restores the counts; take of it traps. A transfer by another task copies pinned objects. See "lending" in the .c. */
uint64_t orin_rt_transfer_put(OrinObj *box);
OrinObj *orin_rt_transfer_take(uint64_t token);
void orin_rt_transfer_drop(uint64_t token);
uint64_t orin_rt_transfer_count(uint64_t which); /* 0: values moved by this task so far, 1: copied */
uint64_t orin_rt_lend(OrinObj *box);             /* lend the value of a two-slot record { value, _ } (end: orin_rt_transfer_drop) */
uint64_t orin_rt_par_threads(void);              /* the thread count of parallel pipelines */
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

/* Opt-in statistics, a BUILD-TIME option (ADR-0038 lever 2): the hot counters (allocations, frees, retains, releases, COW copies and
 * in-place reuses, buffer growths, live and peak bytes / objects) are updated only when the runtime and the generated C are compiled
 * with -DORIN_STATS_ENABLED (implied by -DORIN_SITE_STATS); otherwise every update is an empty macro and release builds pay nothing.
 * The cold counters stay always on (file opens / closes, values moved / copied between tasks, which std:task's movedCount() and
 * copiedCount() return, tasks spawned), and so does the live-object balance (live_objs_at_exit, used by the leak checks). One JSON
 * line is printed on stderr at exit only when the environment variable ORIN_STATS=1; its "counters" field says "all" (option on) or
 * "cold" (option off: the hot counters read 0). tools/bench.py, tools/alloc_census.py and tools/test_resources.sh build with the
 * option; `orin test` and the default build do not. retains/releases count only
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
#if defined(ORIN_SITE_STATS) && !defined(ORIN_STATS_ENABLED)
#define ORIN_STATS_ENABLED 1
#endif
#ifdef ORIN_STATS_ENABLED
#define ORIN_STAT(...) do { __VA_ARGS__; } while (0)
#define ORIN_STAT_ON 1
#else
#define ORIN_STAT(...) ((void)0)
#define ORIN_STAT_ON 0
#endif

/* Allocation-site census (opt-in, docs/perf/alloc-census.md, tools/alloc_census.py). Compiled in only when BOTH the generated C
 * and the runtime are built with ORIN_SITE_STATS: the compiler (`orin2 compile --stats-sites`) then defines it at the top of
 * its output, emits `ORIN_SITE(n, orin_site_caller);` before every MIR instruction and terminator (n: the site id, 1-based, in
 * MIR order: function, block, instruction; the terminator counts as the last instruction; `orin_site_caller` is a local that
 * every function sets on entry to the call site that entered it, one level of calling context for its allocations) and a
 * table `orin_site_names` describing every site; the
 * runtime must be compiled with -DORIN_SITE_STATS (a mismatch is a link error: each side references a symbol only the other
 * defines). Every object records the site that allocated it (OrinObj.site), so the counters are both "at the site" (operations
 * the site executed, on any object) and "of the site" (operations on the objects the site allocated). Report: ORIN_STATS=sites
 * writes one line per site that did anything to $ORIN_SITES_OUT (stderr when unset), besides the usual summary line.
 * Without ORIN_SITE_STATS every hook below is an empty macro: normal builds are unchanged. */
#ifdef ORIN_SITE_STATS
extern __thread uint32_t orin_site_cur ORIN_TLS_MODEL; /* the site executing now (0: none / runtime start-up) */
extern __thread uint32_t orin_site_par ORIN_TLS_MODEL; /* the call site that entered the function of orin_site_cur */
#define ORIN_SITE(n, caller) (orin_site_cur = (uint32_t)(n), orin_site_par = (caller))
enum { ORIN_SITE_RETAIN = 0, ORIN_SITE_RELEASE = 1, ORIN_SITE_COW_COPY = 2, ORIN_SITE_COW_INPLACE = 3 };
void orin_site_rc(OrinObj *o, int what); /* out of line: counts at orin_site_cur and at o->site */
#define ORIN_SITE_RC(o, what) orin_site_rc((o), (what))
#else
#define ORIN_SITE_RC(o, what) ((void)0)
#endif

static inline void orin_retain(OrinObj *o) {
    if (ORIN_LIKELY(o->rc > 0)) {
        o->rc++;
        ORIN_STAT(orin_stats.retains++);
        ORIN_SITE_RC(o, ORIN_SITE_RETAIN);
    }
}
/* retain and return (turn a borrowed value into an owned one). */
static inline OrinObj *orin_dup(OrinObj *o) {
    if (ORIN_LIKELY(o->rc > 0)) {
        o->rc++;
        ORIN_STAT(orin_stats.retains++);
        ORIN_SITE_RC(o, ORIN_SITE_RETAIN);
    }
    return o;
}
/* NULL-safe. */
static inline void orin_release(OrinObj *o) {
    if (o && o->rc > 0) {
        ORIN_STAT(orin_stats.releases++);
        ORIN_SITE_RC(o, ORIN_SITE_RELEASE);
        if (ORIN_UNLIKELY(--o->rc == 0)) orin_destroy(o);
    }
}

/* Returns o if o->rc == 1, else a shallow copy (ref children retained) and releases one
 * count of o. Consumes the caller's reference to o, returns an owned one. */
OrinObj *orin_make_unique_slow(OrinObj *o); /* internal: the copying path */
static inline OrinObj *orin_make_unique(OrinObj *o) {
    if (ORIN_LIKELY(o->rc == 1)) {
        ORIN_STAT(orin_stats.cow_inplace++);
        ORIN_SITE_RC(o, ORIN_SITE_COW_INPLACE);
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
/* `--assert-facts` builds only (docs/mir.md v2.4): checks the value an IForward claims for slot `key` of `o`; exit 70 if it differs. */
void orin_assert_fact(const OrinObj *o, uint64_t key, uint64_t got);
/* `--assert-facts` builds only (docs/mir.md v2.6): the kind and bounds checks an IArrayGetU / IArraySetU omits; exit 70 if they would fail. */
void orin_assert_array(const OrinObj *o, uint64_t i);
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
/* Unboxed Option / Result (ADR-0038 step 1, docs/mir.md v2.2): `word` when `tag` is the expected one, else the trap of
   the boxed builtin. what: 0 = Option.unwrap (tag 0), 1 = Result.unwrap (tag 0), 2 = Result.unwrapErr (tag 1). */
uint64_t orin_v_unwrap(uint64_t tag, uint64_t word, int64_t what);
/* `pop` into an unboxed Option<T>: out[0] = 0 and out[1] = the element, or out[0] = 1 (None) and out[1] = 0 when the
   array is empty. The Option holds a scalar only: an element of a reference array is released (the Option is never
   read as a reference; the optimiser unboxes only Options whose payload is read as a scalar or not at all). */
void orin_array_pop_v(OrinObj *a, uint64_t *out);

uint64_t orin_res_unwrap(OrinObj *o);
uint64_t orin_res_unwrap_err(OrinObj *o);

/* ---------------------------------------------------------------- strings (all byte strings) */

OrinObj *orin_str_new(const char *p, uint64_t n); /* owned copy */
/*@ orin_str_with_capacity(cap): a new, empty buffer for appending (OX markup roots, ADR-0044).
    ensures  \result is a fresh unique string (rc == 1), len(\result) == 0, capacity >= min(cap, ORIN_STR_HINT_MAX),
             so orin_str_append onto it is in place (no growth) while the total length stays within that capacity;
    assigns  the heap (one allocation). cap is a hint only: it never changes the value, and is clamped to 1 MiB. */
#define ORIN_STR_HINT_MAX ((uint64_t)1 << 20)
OrinObj *orin_str_with_capacity(uint64_t cap);
OrinObj *orin_str_concat(OrinObj *a, OrinObj *b);
/* a += b. CONSUMES a, returns owned result; in place (amortised O(1)) when a is unique. */
OrinObj *orin_str_append(OrinObj *a, OrinObj *b);
/*@ orin_str_append_usize(a, v) / orin_str_append_int(a, v): a = a ++ decimal(v), no temporary string (ADR-0038 addendum
    2026-10-16, MIR v2.5 IStrAppendNum). CONSUMES a, returns the owned result.
    requires a is a string kept alive by its caller;
    ensures  \result is a string equal to a followed by the decimal digits of v (no leading zeros, `0` for zero; for the
             signed form a `-` first when v < 0, so INT64_MIN is "-9223372036854775808"), exactly the text of
             orin_usize_to_string / orin_int_to_string;
    ensures  a->rc == 1 ==> \result == a, extended in place (capacity at least doubles on growth); a shared a (rc != 1,
             e.g. a literal) is never modified: \result is a fresh string and a has been released;
    assigns  the heap (a, or a new string). */
OrinObj *orin_str_append_usize(OrinObj *a, uint64_t v);
/*@ orin_str_append_sub(a, s, i, j): a = a ++ s.substring(i, j) without the substring object (MIR v2.5 IStrAppendSub).
    CONSUMES a, s is only read.
    requires a and s are strings, each kept alive by its caller;
    ensures  traps ("substring out of range") exactly when orin_str_substring(s, i, j) does (i > j or j > len(s));
    ensures  otherwise \result is a followed by the bytes [i, j) of s; a->rc == 1 && a != s ==> \result == a, extended in
             place; a shared a (or a == s) is never modified: \result is then a fresh string and a has been released;
    assigns  the heap (a, or a new string). */
OrinObj *orin_str_append_sub(OrinObj *a, OrinObj *s, uint64_t i, uint64_t j);
OrinObj *orin_str_append_int(OrinObj *a, int64_t v);
/*@ orin_str_prepend(a, b): a = b ++ a.  CONSUMES a (the result replaces it), b is only read.
    requires a and b are strings, each kept alive by its caller;
    ensures  \result is a string equal to b followed by a (len(result) == len(a) + len(b)); b is unchanged;
    ensures  a->rc == 1 && a != b ==> \result == a, extended in place (the old bytes are moved up; capacity at least
             doubles on growth), so a string that is shared (rc > 1, e.g. an alias of a literal or of another binding)
             is never modified: \result is then a fresh string and a has been released (one reference dropped);
    assigns  the heap (a, or a new string). */
OrinObj *orin_str_prepend(OrinObj *a, OrinObj *b);
int64_t orin_str_eq(OrinObj *a, OrinObj *b);
static inline uint64_t orin_str_len(const OrinObj *s) { return ((const OrinString *)s)->len; }
static inline const char *orin_str_data(const OrinObj *s) { return ((const OrinString *)s)->data; }
/* Inline: the std prelude (library/core/) loops over bytes with it. */
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
/* Unchecked variants for IArrayGetU / IArraySetU (docs/mir.md v2.6, rule U1): the verifier has shown that an earlier access of the
 * same block already passed the kind check and the bounds check for this array and index, and that nothing since changed them.
 * These are the only helpers whose memory safety rests on a verified fact; `orin2 compile --assert-facts` runs orin_assert_array first. */
static inline uint64_t orin_array_at_u(OrinObj *o, uint64_t i) { return ((OrinArray *)o)->items[i]; }
static inline uint64_t *orin_array_slot_ptr_u(OrinObj *o, uint64_t i) { return &((OrinArray *)o)->items[i]; }
OrinObj *orin_array_get(OrinObj *a, uint64_t i); /* Option<T> (element retained) */
OrinObj *orin_array_slice(OrinObj *a, uint64_t from, uint64_t to);
OrinObj *orin_array_concat(OrinObj *a, OrinObj *b);
/*@ orin_array_extend(a, b): a = a ++ b.  CONSUMES a (the result replaces it), b is only read.
    requires a and b are arrays (anything else traps "wrong shape"); each is kept alive by its caller;
    ensures  \result is an array whose elements are a's elements followed by b's: len(result) == len(a) + len(b);
             every reference element copied from b is retained once more (b keeps its own references);
    ensures  a->rc == 1 && a != b && (a, b have the same element kind, or a is empty)
               ==> \result == a, extended in place (amortised O(len(b)), capacity at least doubles on growth);
    ensures  otherwise \result is a fresh array and a has been released (as orin_array_concat followed by a release);
    assigns  the heap (a, or a new array); b is unchanged. */
OrinObj *orin_array_extend(OrinObj *a, OrinObj *b);
/*@ orin_bytes_to_string(a, start, len): the bytes a[start .. start+len) of a u8 array as a string.
    requires a is an array of u8 (elements 0..255 in 64-bit slots; anything else traps "wrong shape");
    ensures  start <= len(a) && len <= len(a) - start, else it traps "slice out of range" (never reads out of bounds);
    ensures  \result is a fresh string of exactly len bytes with \result[i] == a[start + i] for i < len;
    ensures  an element above 255 (impossible for a well-typed u8 array) traps "byte out of range" instead of being truncated;
    assigns  one allocation; a is unchanged. O(len), a plain copy loop, no per-byte allocation. */
OrinObj *orin_bytes_to_string(OrinObj *a, uint64_t start, uint64_t len);
/*@ orin_string_to_bytes(s): the bytes of a string as a u8 array.
    requires s is a string (anything else traps "wrong shape");
    ensures  \result is a fresh u8 array (not reference elements) with len == len(s) and \result[i] == (unsigned char)s[i];
    assigns  one array allocation and its buffer; s is unchanged. O(len). */
OrinObj *orin_string_to_bytes(OrinObj *s);
OrinObj *orin_array_join(OrinObj *a, OrinObj *sep); /* string[] -> string */

/* ---------------------------------------------------------------- I/O and process */

void orin_console_log(OrinObj *s);   /* stdout (buffered) + "\n" */
void orin_console_error(OrinObj *s); /* flushes stdout first, then stderr + "\n" */
OrinObj *orin_fs_read_file(int64_t fs, OrinObj *path);                 /* Result<string,string> */
OrinObj *orin_fs_write_file(int64_t fs, OrinObj *path, OrinObj *data); /* Result<void,string> */
int64_t orin_fs_exists(int64_t fs, OrinObj *path);  /* 1 present, 0 absent, -100001..-100004 the grant refused the query */
OrinObj *orin_fs_list_dir(int64_t fs, OrinObj *path); /* Result<string[],string> */
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
/* network (ADR-0033; handles: NetGrant 5, Listener 6, Stream 7; openers return the handle or the negated error code) */
int64_t orin_cap_net(int64_t host);
int64_t orin_cap_listen(int64_t net, OrinObj *addr, int64_t port);
int64_t orin_cap_connect(int64_t net, OrinObj *pattern, int64_t lo, int64_t hi);
int64_t orin_net_listen(int64_t net, OrinObj *addr, int64_t port, int64_t backlog, int64_t opt);
int64_t orin_net_accept(int64_t listener, int64_t timeout_ms, int64_t opt);
int64_t orin_net_connect(int64_t net, OrinObj *host, int64_t port, int64_t timeout_ms, int64_t opt);
int64_t orin_net_status(int64_t h);
void orin_net_close(int64_t h);
int64_t orin_net_port(int64_t listener);
int64_t orin_net_now(int64_t h);
OrinObj *orin_net_recv(int64_t stream, uint64_t cap, int64_t timeout_ms); /* Result<u8[], int> */
OrinObj *orin_net_send(int64_t stream, OrinObj *data, uint64_t off, uint64_t len, int64_t timeout_ms); /* Result<usize, int> */
int64_t orin_net_shutdown(int64_t stream, int64_t how);
OrinObj *orin_net_peer(int64_t stream);
OrinObj *orin_net_resolve(int64_t net, OrinObj *name); /* Result<string, int> */
OrinObj *orin_net_error_text(int64_t code);
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
