# 19 — Self-Hosted Runtime and Minimal Platform Layer

**Status:** RFC v0.1 (2026-10-13). Relates to `06` (OIM), `07` (formal safety, TCB), `08`
(std/core split), `09` (self-hosting), `11` (performance). Decision record: ADR-0013.

## 1. Goal

The Orin runtime MUST be **predominantly written in Orin**. Only a **minimal, explicit platform
layer** may be written in another language (C or assembly). The platform layer MUST be small
enough to be reviewed, specified and verified **separately** from the compiler and the rest of
the runtime. Rationale: every line of runtime code outside Orin is trusted computing base (spec 07);
moving it into Orin lets the same proofs that cover compiled programs (memory IR, verifier, formal
model) cover the runtime as well.

## 2. Layers

| Layer | Language | Contents | Assurance target |
|---|---|---|---|
| **L0 platform** (`platform/`) | C (or asm), freestanding style, no libc dependency beyond a declared list | raw memory: `page_alloc`/`page_free` (or `malloc`/`free` wrappers), byte load/store at an address, `memcpy`/`memmove`/`memcmp`; process: args, exit, abort; I/O: `read`/`write` on fds, open/close; clock; host policy and path-scope primitives for the capability grants (ADR-0027: `policy_parse/load`, `path_normalize/within/absolute/real`); later atomics and threads | each function has a written contract (pre/post/frame) and is verified separately (e.g. Frama-C/WP, VST, CBMC) or, until then, exhaustively tested and fuzzed; kept under a hard size budget (target ≤ 1,000 lines, no data structures) |
| **L1 core runtime** (`core/`, Orin "core dialect") | Orin with a small set of *core intrinsics* (raw address type, load/store, size_of) usable **only** in modules the package manifest marks `core = true` | object header layout, `retain`/`release`/`make_unique`, allocation, arrays (push/pop/grow), strings (concat/append/compare/slice), struct slots, traps, the `ORIN_STATS` counters | proven to implement the operations of the formal memory model (refinement: each core function satisfies the corresponding Lean machine operation's specification); all core code also passes the MIR ownership verifier where it uses ordinary values |
| **L2 std** (`std/`) | safe Orin only | string utilities (`split`, `trim`, `indexOf`, `parseInt`, number formatting), array utilities, `fs`/`process`/`io` wrappers over L0, later maps, JSON, … | ordinary safe Orin: memory safety follows from the language guarantees; functional correctness by tests and optional contracts (spec 15) |

Rules:
- Safe user code can never name core intrinsics; using them outside a `core` module is a compile
  error. Annotations (spec 05) cannot generate core-intrinsic uses.
- The platform API is a **closed list** declared in one header/interface file; adding a function
  needs an ADR. L1/L2 may call L0 only through that list.
- The compiler links L1/L2 like any Orin code (whole-program, inlinable), so moving logic into
  Orin must not cost performance (spec 11: measure before/after each migration step).
- The generated program's TCB becomes: L0 + the C compiler/LLVM + the emitter (until translation
  validation) — not the object model or library logic.

## 3. Proof story (spec 07 layers)

1. **L0:** per-function contracts; verified with a C verifier or bounded model checker; the
   contracts are the axioms assumed by L1 proofs.
2. **L1:** Orin core functions refine the Lean memory machine (`formal/`): e.g. the
   implementation of `release` performs exactly the abstract `release` step (decrement, free at
   zero, release children) given L0's contracts. This turns today's "runtime is TCB" into a proof
   obligation.
3. **L2 and user code:** safe Orin; covered by the MIR verifier + formal model like any program.
Documentation MUST state for each runtime function which layer it is in and which of
"proven / statically checked / tested only / trusted" applies (spec 07 labelling).

## 4. Migration plan (incremental, never breaking the bootstrap)

- **R1 — std in Orin (no new language features):** move pure library logic currently in
  `runtime/orin_runtime.c` (split, trim, indexOf/includes, parseInt, int/usize→string, join,
  slice/concat helpers) into Orin modules compiled with every program; keep C versions only where
  Stage 0 needs them. Differential tests old vs new; benchmarks.
  **Status: done (2026-10-13).** The implementation lives in `std/` (repo root; embedded into the
  compiler by `tools/embed_prelude.py`, loaded implicitly via the general "prelude roots" mechanism,
  see docs/architecture.md "Preludes"). The checker keeps the same surface API; lowering maps the
  moved built-ins to calls of the prelude functions; unreachable prelude functions are pruned from the
  emitted C. The C versions stay in `runtime/orin_runtime.c` because Stage 0 (frozen) and
  `--c-builtins` (the differential-test path, `tools/diff_backends.py --mode builtins`) still use
  them. Slice/concat/get of arrays were **not** moved: they are generic over the element type, and
  the prelude has no way to be instantiated per element type without generics-in-prelude (checker
  instance requests) or the R3 core dialect (raw slot copies). `substring` stays in C as a primitive
  (it defines the bounds trap and allocates). Measured effect: docs/benchmarks.md "R1".

### Inventory (state after R1)

Layer = the layer the function belongs to in the target design (section 2). Assurance labels follow
spec 07: *safe Orin* (language guarantees, MIR-verified), *tested only*, *trusted* (C).

| Function (runtime/orin_runtime.{h,c}) | Layer | Status after R1 |
|---|---|---|
| `orin_str_index_of`, `orin_str_includes` | L2 | moved: `std/strings.or` `strIndexOf`, `strIncludes` (naive scan with first-byte filter instead of `memmem`); C copy kept for Stage 0 / `--c-builtins` |
| `orin_str_starts_with`, `orin_str_ends_with` | L2 | moved: `strStartsWith`, `strEndsWith`; C copy kept |
| `orin_str_split` | L2 | moved: `strSplit` (empty separator still traps `split with empty separator`, status 101, via `console.error` + `process.exit(101)`); C copy kept |
| `orin_str_trim` | L2 | moved: `strTrim`; C copy kept |
| `orin_array_join` | L2 | moved: `strJoin` (grows the result by repeated in-place append instead of a pre-sized buffer); C copy kept |
| `orin_parse_int` | L2 | moved: `std/numbers.or` `strParseInt` (overflow checks done by hand; same accepted syntax); C copy kept |
| `orin_int_to_string`, `orin_usize_to_string`, `orin_bool_to_string` | L2 | moved: `intToString`, `usizeToString`, `boolToString` (no `snprintf`); C copies kept |
| `orin_str_char_code_at` | L1 primitive | stays in C; now `static inline` in the header (the prelude loops over it) |
| `orin_str_char_at`, `orin_str_substring`, `orin_string_from_char_code` | L1 primitive | stay in C: allocation, bounds traps, shared 1-byte immortals |
| `orin_str_new`, `orin_str_concat`, `orin_str_append`, `orin_str_eq`, `orin_str_len`, `orin_str_data` | L1 | stay in C until R3 (object model, allocation, in-place append) |
| `orin_array_get`, `orin_array_slice`, `orin_array_concat` | L1 / L2 (generic) | stay in C: generic over the element type (see above); candidates for the array-API prelude or R3 |
| `orin_array_new`, `orin_array_push(_grow)`, `orin_array_pop`, `orin_array_len/at/slot_ptr` | L1 | stay in C until R3 |
| `orin_struct_*`, `orin_nullary`, `orin_variant1`, `orin_opt_unwrap`, `orin_res_unwrap(_err)`, `orin_tag` | L1 | stay in C until R3 |
| `orin_retain/dup/release/destroy`, `orin_make_unique(_slow)`, freelists, `orin_live_count`, `OrinStats` | L1 | stay in C until R3 |
| checked arithmetic and conversions (`orin_add_i` ... `orin_usize_to_int`) | L1 (codegen intrinsics) | stay in C (inline), R3 |
| `orin_trap`, `orin_init`, `orin_flush` | L1 shells over L0 | **R2 done:** the functions stay in `runtime/` as thin object-model-aware wrappers; all OS access is `orin_platform_init/write_line/exit/flush/at_exit/getenv` |
| `orin_console_log/error`, `orin_fs_read_file/write_file/exists`, `orin_process_args/exit`, `orin_runtime_io.h` (`std:io`) | L1 shells over L0 | **R2 done:** they only convert Orin strings to `(ptr, len)` and Result objects; OS work is `orin_platform_write_line`, `file_read/write/exists`, `error_message`, `arg_count/arg`, `exit`, `stdin_read/getc`, `shell` |
| allocation, `memcpy`/`memcmp`/`memset`/`memmem` in the object model | L0 | **R2 done:** `orin_platform_alloc/realloc/free`, `mem_copy/set/cmp/find`; `snprintf` replaced by `fmt_i64/fmt_u64` |

Labels: the prelude code is *safe Orin* (type-checked, MIR ownership-verified: `tools/verify_all.py`
covers all of it) with functional behaviour *tested only* (differential tests against the C versions
over all run suites, ASan/UBSan, plus `tests/run/std_prelude_edges.or`); everything still in C is
*trusted/tested only*. Observable differences: none intended; the trap for `split` with an empty
separator is raised through `process.exit(101)` after printing the same message.
- **R2 — carve out L0:** split the remaining C into `platform/` (the closed list) and the object
  model; write L0 contracts.
  **Status: done (2026-10-13).** `platform/orin_platform.{h,c}` (about 440 lines incl. contracts; budget
  1,000) is the closed list; the final API: memory `alloc, realloc, free, mem_copy, mem_move, mem_set,
  mem_cmp, mem_find`; formatting `fmt_i64, fmt_u64`; process `init, arg_count, arg, getenv, at_exit, exit,
  abort, shell`; byte I/O `write, write_line, flush, stdin_read, stdin_getc`; files `file_read, file_write,
  file_exists, error_message`. No clock: nothing uses one yet (adding one needs an ADR). Every function has
  an ACSL-style `requires/ensures/assigns` block in the header. `tools/check_platform_boundary.sh` (CI)
  forbids direct libc calls/includes in `runtime/`. Assurance: memory, find and format primitives are
  bounded-verified with CBMC (`tools/verify_platform.sh`, docs/formal.md "L0 platform layer"); I/O, process
  and file primitives are tested only (`platform/tests/platform_test.c`, plain and under ASan/UBSan). The
  inventory above shows the layer of each runtime function after R2.
- **R3 — core dialect:** add core intrinsics (raw address type, load/store, size_of, header
  access) restricted to `core` modules; reimplement the object model (retain/release/make_unique,
  allocation, arrays, strings) in Orin; the C object model is deleted. Stage 0 keeps its own C
  runtime (frozen) or links the generated C of L1.
- **R4 — proofs:** L0 contracts verified with a C verification tool; L1 refinement proofs against
  the Lean machine; update the safety-status table.

## 5. Non-goals / OPEN

- No garbage collector is introduced by this split (spec 06).
- Async runtime design is OPEN (spec 12 #5). **Threads (ADR-0017 stage 0, 2026-10-14):** the scheduler's low-level primitives are L0
  (`orin_platform_thread_*`, `orin_platform_monitor_*`: thread create / join / exit and a mutex + condition queues + integer words, all
  handle-checked) and stay C; its logic (task table, channels, join results) is Orin (`std:task`); the part that needs the object model
  (value transfer between task heaps, per-task allocator state) is ONE temporary C interface, `orin_rt_*`, that R3 replaces
  function by function (porting table: ADR-0017 Addendum A, docs/concurrency.md). The L0 size budget counts CODE lines (comments and
  contract blocks excluded), per ADR-0030.
- Exact choice of C verification tool is OPEN.
