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

/* A pointer-holding field of the runtime ABI that heap.or / object.or / array.or read and write as one 64-bit word at a fixed byte
 * offset (load64 / store64): 8 bytes of storage on every target (ADR-0055 "Later", wasm32). On a 32-bit little-endian target the
 * pointer is the low half of the union and the high half stays zero, because the Orin side always stores a zero-extended 64-bit
 * value and every C writer only replaces the low half. On 64-bit targets the union is exactly the pointer (same size, offset and
 * code). `ORIN_PTR64(T, name)` declares the member `name` of type T (used as a plain pointer) and the word `name##_w`. */
#define ORIN_PTR64(T, name) union { T name; uint64_t name##_w; }

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
    ORIN_PTR64(uint64_t *, items); /* 8 bytes @40 on every target */
} OrinArray;

typedef struct OrinStruct {
    OrinObj h; /* h.tag = variant tag */
    uint32_t nslots;
    uint32_t pad;
    uint64_t refmask; /* bit i set: slot i is a reference (max 64 slots) */
    uint64_t slots[];
} OrinStruct;

#define ORIN_SLOT(p) ((uint64_t)(uintptr_t)(p)) /* reference -> slot */

/* float -> slot: the 64-bit pattern of the double (ADR-0018). Generated code has its own orinc_f2s / orinc_s2f
 * (compiler/backends/c/preamble.or). */
static inline uint64_t orin_f2s(double d) {
    union { double d; uint64_t u; } v;
    v.d = d;
    return v.u;
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
/* internal, ADR-0052 R3d.5: Orin functions of runtime/core/stats.or (the ORIN_STATS report, run at exit by orin_init, and the live-object
 * count above), defined by the code a program is compiled to (compiler/backends/{c,llvm}/rtwrap.or), and the C services that Orin
 * runtime code reaches through the core operation `hook` (orin_runtime.c lists them). */
void orin_stats_report(void);
uint64_t orin_core_hook(uint64_t k, uint64_t a, uint64_t b, uint64_t c);

/* internal, ADR-0052 R3d.3 (c): Orin functions of runtime/core/heap.or and object.or (the small-block cache and string allocation), defined by
 * the code a program is compiled to for the C shells of the runtime (compiler/backends/{c,llvm}/rtwrap.or). */
void *orin_sb_alloc(uint64_t n);
void orin_sb_free(void *p, uint64_t n);
void *orin_sb_realloc(void *p, uint64_t old, uint64_t n);
OrinObj *orin_str_alloc(uint64_t len, uint64_t cap); /* a string of length len, capacity max(len, cap); the NUL terminator is set */
void orin_destroy(OrinObj *o); /* internal: free an object whose count reached 0 (an Orin function of runtime/core/rc.or, ADR-0052 R3d.3 (b)) */

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
void orin_rt_task_watch(uint64_t monitor);         /* the calling task sets word 1 of the monitor to 1 and notifies queue 0 when it ends */
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
uint64_t orin_mon_wait_until(uint64_t m, uint64_t cond, uint64_t deadline_ms); /* 1: the deadline passed, 0: notified */
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

/* The build configuration seen by the core operation cfg(k) (ORIN_CFG_FREELIST / STATS / SITES) is defined by the preamble of the
 * generated code (compiler/backends/c/preamble.or), not here: no C shell reads it. */

/* The per-thread heap block (ADR-0052 Addendum A section 5, step R3d.1): ALL allocator state of a thread / task (ADR-0017) in one
 * zero-initialised `__thread` object, so a new thread starts with empty lists and zeroed counters. It is the block the core operation
 * heapBase() returns, so Orin code (the L1 modules of later steps) reaches every field at a fixed byte offset from heapBase(); the
 * offsets are part of the runtime ABI like the object layout (rule 3 of the Addendum), pinned by the _Static_asserts below and listed
 * in spec/19 "R3d.1". Offsets are independent of the build configuration: the free lists and the counters exist (unused) with
 * -DORIN_NO_FREELIST or without ORIN_STATS_ENABLED. Word 63 (byte 504) is the scratch word of std:coreprobe; the "reserved" ranges
 * are for later fields (task pointer, grant and file tables) and stay zero. A block is plain malloc memory, so a free-list node may
 * come from another thread's heap and joins this one's (capped by FL_CAP / SB_CAP). */
enum { FL_STRUCT_CLASSES = 9, SB_MAX = 256, SB_CLASSES = SB_MAX / 16, ORIN_HEAP_WORDS = 128 };
typedef struct FreeNode { ORIN_PTR64(struct FreeNode *, next); } FreeNode;
/* A free-list head that is an array element: `.p` is the pointer, `.w` the 64-bit word. */
typedef union FreeHead { FreeNode *p; uint64_t w; } FreeHead;
/* A small-block cache class: list head and length side by side, so one scaled index reaches both. */
typedef struct SbClass { ORIN_PTR64(FreeNode *, head); uint64_t n; } SbClass;
typedef struct OrinHeap {
    FreeHead fl_struct[FL_STRUCT_CLASSES];   /* @0    free struct objects by nslots 0..8 */
    ORIN_PTR64(FreeNode *, fl_array);       /* @72   free array headers */
    uint64_t fl_n[FL_STRUCT_CLASSES + 1];   /* @80   list lengths: structs by nslots, [9] the array headers */
    int64_t live;                           /* @160  live objects of this heap (signed: a task can free more than it allocated) */
    ORIN_PTR64(OrinObj **, dstack);         /* @168  the work stack of orin_destroy (NULL until first use) */
    uint64_t dcap;                          /* @176  its capacity in entries */
    uint64_t reserved0;                     /* @184 */
    OrinStats stats;                        /* @192  the counters (OrinStats, 18 words) */
    uint64_t task;                          /* @336  address of the RtTask record of this thread, 0 on a thread that is not a task (R3e.4) */
    uint64_t joined;                        /* @344  the record of the task this thread joined last (its message; R3e.4) */
    uint64_t grants;                        /* @352  the grant table of this task (R3c) */
    uint64_t files;                         /* @360  the open-file table of this task (R3c) */
    uint64_t netbuf;                        /* @368  the per-task network buffer (C4) */
    uint64_t scratch;                       /* @376  scratch word: the out parameter of L0 calls (thread_join, monitor_get) */
    uint64_t reserved1[15];                 /* @384  up to 504 */
    uint64_t probe;                         /* @504  std:coreprobe scratch word */
    SbClass sb[SB_CLASSES + 1];             /* @512  small-block cache by 16-byte class 0..16: list head, length */
    uint64_t reserved2[30];                 /* @784  up to 1024 */
} OrinHeap;
extern __thread OrinHeap orin_heap ORIN_TLS_MODEL;

/* The process-wide shared block (core operation `sharedBase`, hir/coreops.or 30; ADR-0052 Addendum B section 2.3): 128 zero-initialised
 * words, read and written by Orin code only between the runtime lock and its release (`plat` 14 and 15), except the trap line buffer.
 * The offsets are part of the runtime ABI like those of OrinHeap (spec 19 "R3e.0"). */
enum { ORIN_SHARED_WORDS = 128 };
typedef struct OrinShared {
    uint64_t transfer[4];   /* @0    transfer slot table: pointer, n, cap, free head */
    uint64_t flight[4];     /* @32   grant flight table: pointer, n, cap, free head (R3e.5) */
    uint64_t reserved[56];  /* @64   up to 512 */
    char trapline[512];     /* @512  line buffer of the process trap (the main thread only, which is about to exit) */
} OrinShared;
extern OrinShared orin_shared;
_Static_assert(offsetof(OrinShared, transfer) == 0 && offsetof(OrinShared, flight) == 32 && offsetof(OrinShared, reserved) == 64 &&
                   offsetof(OrinShared, trapline) == 512 && sizeof(OrinShared) == ORIN_SHARED_WORDS * 8,
               "orin_shared: transfer @0, flight @32, trap line @512, 128 words");
/* The counters keep their name: `orin_stats.retains++` in the inline functions below and in generated code. */
#define orin_stats (orin_heap.stats)
#define ORIN_HEAP_OFF(f) offsetof(OrinHeap, f)
_Static_assert(sizeof(OrinStats) == 144, "OrinStats is 18 words");
_Static_assert(sizeof(FreeNode) == 8 && sizeof(FreeHead) == 8 && sizeof(OrinArray) == 48 && sizeof(void *) <= 8 &&
                   __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
               "the pointer fields of the heap block and of OrinArray are 8-byte words, the pointer in the low half");
_Static_assert(ORIN_HEAP_OFF(fl_struct) == 0, "orin_heap.fl_struct @0");
_Static_assert(ORIN_HEAP_OFF(fl_array) == 72, "orin_heap.fl_array @72");
_Static_assert(ORIN_HEAP_OFF(fl_n) == 80, "orin_heap.fl_n @80");
_Static_assert(ORIN_HEAP_OFF(live) == 160, "orin_heap.live @160");
_Static_assert(ORIN_HEAP_OFF(dstack) == 168, "orin_heap.dstack @168");
_Static_assert(ORIN_HEAP_OFF(dcap) == 176, "orin_heap.dcap @176");
_Static_assert(ORIN_HEAP_OFF(reserved0) == 184, "orin_heap.reserved0 @184");
_Static_assert(ORIN_HEAP_OFF(stats) == 192, "orin_heap.stats @192");
_Static_assert(ORIN_HEAP_OFF(task) == 336, "orin_heap.task @336");
_Static_assert(ORIN_HEAP_OFF(joined) == 344, "orin_heap.joined @344");
_Static_assert(ORIN_HEAP_OFF(grants) == 352, "orin_heap.grants @352");
_Static_assert(ORIN_HEAP_OFF(files) == 360, "orin_heap.files @360");
_Static_assert(ORIN_HEAP_OFF(netbuf) == 368, "orin_heap.netbuf @368");
_Static_assert(ORIN_HEAP_OFF(scratch) == 376, "orin_heap.scratch @376");
_Static_assert(ORIN_HEAP_OFF(reserved1) == 384, "orin_heap.reserved1 @384");
_Static_assert(ORIN_HEAP_OFF(probe) == 504, "orin_heap.probe @504");
_Static_assert(ORIN_HEAP_OFF(sb) == 512 && sizeof(SbClass) == 16, "orin_heap.sb @512, 16 bytes per class (head @+0, n @+8)");
_Static_assert(ORIN_HEAP_OFF(reserved2) == 784, "orin_heap.reserved2 @784");
_Static_assert(sizeof(OrinHeap) == ORIN_HEAP_WORDS * 8, "orin_heap is 128 words (1024 bytes)");
_Static_assert(offsetof(OrinStats, alloc_string) == 0 && offsetof(OrinStats, alloc_array) == 8 && offsetof(OrinStats, alloc_struct) == 16 &&
                   offsetof(OrinStats, frees) == 24 && offsetof(OrinStats, retains) == 32 && offsetof(OrinStats, releases) == 40 &&
                   offsetof(OrinStats, cow_copies) == 48 && offsetof(OrinStats, cow_inplace) == 56 && offsetof(OrinStats, array_grows) == 64 &&
                   offsetof(OrinStats, string_grows) == 72 && offsetof(OrinStats, peak_live_objs) == 80 &&
                   offsetof(OrinStats, peak_live_bytes) == 88 && offsetof(OrinStats, live_bytes) == 96 && offsetof(OrinStats, file_opens) == 104 &&
                   offsetof(OrinStats, file_closes) == 112 && offsetof(OrinStats, transfer_moves) == 120 &&
                   offsetof(OrinStats, transfer_copies) == 128 && offsetof(OrinStats, tasks_spawned) == 136,
               "OrinStats field offsets (relative to orin_heap.stats, i.e. to heapBase())");

/* Allocation-site census (opt-in, docs/perf/alloc-census.md, tools/alloc_census.py). Compiled in only when BOTH the generated C
 * and the runtime are built with ORIN_SITE_STATS: the compiler (`orin2 compile --stats-sites`) then defines it at the top of
 * its output, emits `ORIN_SITE(n, orin_site_caller);` before every MIR instruction and terminator (n: the site id, 1-based, in
 * MIR order: function, block, instruction; the terminator counts as the last instruction; `orin_site_caller` is a local that
 * every function sets on entry to the call site that entered it, one level of calling context for its allocations) and a
 * table `orin_site_names` describing every site; the
 * runtime must be compiled with -DORIN_SITE_STATS (a mismatch is a link error: each side references a symbol only the other
 * defines). Every heap object records the site that allocated it in a prefix word of 8 bytes before its header (ORIN_SITE_OF; the
 * object layout is the same in all builds), so the counters are both "at the site" (operations the site executed, on any object)
 * and "of the site" (operations on the objects the site allocated). Report: ORIN_STATS=sites
 * writes one line per site that did anything to $ORIN_SITES_OUT (stderr when unset), besides the usual summary line.
 * Without ORIN_SITE_STATS every hook below is an empty macro: normal builds are unchanged. */
#ifdef ORIN_SITE_STATS
extern __thread uint32_t orin_site_cur ORIN_TLS_MODEL; /* the site executing now (0: none / runtime start-up) */
extern __thread uint32_t orin_site_par ORIN_TLS_MODEL; /* the call site that entered the function of orin_site_cur */
#define ORIN_SITE(n, caller) (orin_site_cur = (uint32_t)(n), orin_site_par = (caller))
enum { ORIN_SITE_RETAIN = 0, ORIN_SITE_RELEASE = 1, ORIN_SITE_COW_COPY = 2, ORIN_SITE_COW_INPLACE = 3 };
void orin_site_rc(OrinObj *o, int what); /* out of line: counts at orin_site_cur and at the site of o */
/* The site that allocated `o`: its prefix word. An immortal object (count -1: the static literals and variants, which no prefix word
 * precedes) has site 0. A dying object (count 0) and a lend-pinned one (top two bits 10, see "lending" in orin_runtime.c) still have it. */
#define ORIN_SITE_OF(o) (((uint64_t)(o)->rc >> 62) != 3 ? ((const uint32_t *)(o))[-2] : 0u)
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
OrinObj *orin_make_unique_slow(OrinObj *o); /* internal: the copying path (an Orin function of runtime/core/rc.or, R3d.3 (b)) */
static inline OrinObj *orin_make_unique(OrinObj *o) {
    if (ORIN_LIKELY(o->rc == 1)) {
        ORIN_STAT(orin_stats.cow_inplace++);
        ORIN_SITE_RC(o, ORIN_SITE_COW_INPLACE);
        return o;
    }
    return orin_make_unique_slow(o);
}

/* ---------------------------------------------------------------- integers
 * The checked arithmetic of generated code (orinc_add_i, orinc_div_u, orinc_range_i, ...) is defined by the preamble the compiler
 * emits (compiler/backends/c/preamble.or, ADR-0052 R3d.6); the runtime has no copy, no C shell calls it. */

/* Fixed-width integers (ADR-0022). Types narrower than 64 bits live in int64_t locals; after an operation the
 * result is range-checked (orinc_range_i, orinc_conv_i, orinc_conv_u of the preamble). Conversions trap when the value does not fit. Kinds: 0 i8, 1 i16, 2 i32, 3 i64, 4 isize,
 * 5 u8, 6 u16, 7 u32, 8 u64, 9 usize (see orin_runtime.c). */
uint64_t orin_int_op(int64_t mode, uint64_t a, uint64_t b, int64_t kind); /* wrapping (0..2) / saturating (3..5) add sub mul */
OrinObj *orin_int_chk(int64_t mode, uint64_t a, uint64_t b, int64_t kind); /* checked add sub mul: Option */
OrinObj *orin_parse_int_k(OrinObj *s, int64_t kind);                      /* Option of the parsed integer */

/* ---------------------------------------------------------------- structs / variants */
/* Records use tag 0. Option: Some=0 (1 slot), None=1. Result: Ok=0 (1 slot, 0 for void), Err=1. */

/* New struct with all slots zero (null refs). Fill with orin_struct_init (init only).
 * orin_struct_new, orin_variant1 and orin_array_new are Orin functions of runtime/core/object.or ($rt, ADR-0052 R3d.3 (a)): the code a
 * program is compiled to defines these C names (compiler/backends/{c,llvm}/rtwrap.or) and calls the Orin functions directly; a test that links
 * only the C files of the runtime links tools/rt_stub.sh's object. */
OrinObj *orin_struct_new(uint32_t tag, uint32_t nslots, uint64_t refmask);
/* Immortal singleton for a payload-less variant, for the C shells: tag 0 (Ok of void) or 1 (None, Err), one static object per
 * translation unit. Generated code has its own static objects per tag (`orin_nz<tag>`, ADR-0052 R3d.2). */
static inline OrinObj *orin_nullary(uint32_t tag) {
    static struct { OrinObj h; uint32_t nslots; uint32_t pad; uint64_t refmask; } n[2] = {
        {{-1, ORIN_K_STRUCT, 0}, 0, 0, 0}, {{-1, ORIN_K_STRUCT, 1}, 0, 0, 0}};
    if (ORIN_UNLIKELY(tag > 1)) orin_trap("variant tag too large");
    return &n[tag].h;
}
/* Variant with one slot; consumes the slot's reference if the slot is a ref (refmask 0/1). */
OrinObj *orin_variant1(uint32_t tag, uint64_t refmask, uint64_t slot);
/* Defence in depth (docs/assurance.md, finding "shape confusion"): every field access on an object of unknown
 * provenance checks that it is a struct and that the slot index is below its slot count, so a lowering bug that
 * confuses value shapes becomes a clean trap instead of an out-of-bounds read or write. The ownership verifier
 * does not check value shapes. The LLVM backend does the same check in its inline helper @orinl_slot. */
void orin_trap_shape(void) __attribute__((noreturn, cold));
/* `--assert-facts` checks (orin_assert_fact, orin_assert_array), the unwrap helpers (orin_opt_unwrap, orin_res_unwrap(_err), orin_v_unwrap)
 * and the shape trap of generated LLVM code are Orin functions of runtime/core/leaf.or ($rt, ADR-0052 R3d.2); this C trap serves the inlines below. */
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
/* `pop` into an unboxed Option<T>: out[0] = 0 and out[1] = the element, or out[0] = 1 (None) and out[1] = 0 when the
   array is empty. The Option holds a scalar only: an element of a reference array is released (the Option is never
   read as a reference; the optimiser unboxes only Options whose payload is read as a scalar or not at all). */
void orin_array_pop_v(OrinObj *a, uint64_t *out);


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
int64_t orin_cap_adopt_net(uint64_t token);
int64_t orin_cap_adopt_stream(uint64_t token);
void orin_cap_require(int64_t grant, int64_t kind, const char *what); /* traps unless valid, of `kind` and not denied */
void orin_cap_require_spawn(int64_t proc);                     /* traps unless the process grant may spawn */
void orin_process_exit(int64_t code) __attribute__((noreturn)); /* flushes stdout */

#ifdef __cplusplus
}
#endif
#endif
