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
| **L0 platform** (`runtime/platform/`) | C (or asm), freestanding style, no libc dependency beyond a declared list | raw memory: `page_alloc`/`page_free` (or `malloc`/`free` wrappers), byte load/store at an address, `memcpy`/`memmove`/`memcmp`; process: args, exit, abort; I/O: `read`/`write` on fds, open/close; clock; host policy and path-scope primitives for the capability grants (ADR-0027: `policy_parse/load`, `path_normalize/within/absolute/real`); later atomics and threads | each function has a written contract (pre/post/frame) and is verified separately (e.g. Frama-C/WP, VST, CBMC) or, until then, exhaustively tested and fuzzed; kept under a hard size budget (≤ 1,000 code lines, contracts and comments excluded: the budget limits trusted code, not its specification; no data structures) |
| **L1 core runtime** (`core/`, Orin "core dialect") | Orin with a small set of *core intrinsics* (raw address type, load/store, size_of) usable **only** in modules the package manifest marks `core = true` | object header layout, `retain`/`release`/`make_unique`, allocation, arrays (push/pop/grow), strings (concat/append/compare/slice), struct slots, traps, the `ORIN_STATS` counters | proven to implement the operations of the formal memory model (refinement: each core function satisfies the corresponding Lean machine operation's specification); all core code also passes the MIR ownership verifier where it uses ordinary values |
| **L2 std** (`library/core/`) | safe Orin only | string utilities (`split`, `trim`, `indexOf`, `parseInt`, number formatting), array utilities, `fs`/`process`/`io` wrappers over L0, later maps, JSON, … | ordinary safe Orin: memory safety follows from the language guarantees; functional correctness by tests and optional contracts (spec 15) |

Rules:
- Safe user code can never name core intrinsics; using them outside a `core` module is a compile
  error (R3d.0: a `core` module is a module of the embedded root `$rt`, see "R3d.0 preparation"). Annotations (spec 05) cannot generate core-intrinsic uses.
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
  `runtime/core/orin_runtime.c` (split, trim, indexOf/includes, parseInt, int/usize→string, join,
  slice/concat helpers) into Orin modules compiled with every program; keep C versions only where
  Stage 0 needs them. Differential tests old vs new; benchmarks.
  **Status: done (2026-10-13).** The implementation lives in `library/core/` (repo root; embedded into the
  compiler by `tools/embed_prelude.py`, loaded implicitly via the general "prelude roots" mechanism,
  see docs/architecture.md "Preludes"). The checker keeps the same surface API; lowering maps the
  moved built-ins to calls of the prelude functions; unreachable prelude functions are pruned from the
  emitted C. The C versions stay in `runtime/core/orin_runtime.c` because Stage 0 (frozen) and
  `--c-builtins` (the differential-test path, `tools/differential.sh --mode builtins`) still use
  them. Slice/concat/get of arrays were **not** moved: they are generic over the element type, and
  the prelude has no way to be instantiated per element type without generics-in-prelude (checker
  instance requests) or the R3 core dialect (raw slot copies). `substring` stays in C as a primitive
  (it defines the bounds trap and allocates). Measured effect: docs/benchmarks.md "R1".

### Inventory (state after R1)

Layer = the layer the function belongs to in the target design (section 2). Assurance labels follow
spec 07: *safe Orin* (language guarantees, MIR-verified), *tested only*, *trusted* (C).

| Function (runtime/core/orin_runtime.{h,c}) | Layer | Status after R1 |
|---|---|---|
| `orin_str_index_of`, `orin_str_includes` | L2 | moved: `library/core/strings.or` `strIndexOf`, `strIncludes` (naive scan with first-byte filter instead of `memmem`); C copy kept for Stage 0 / `--c-builtins` |
| `orin_str_starts_with`, `orin_str_ends_with` | L2 | moved: `strStartsWith`, `strEndsWith`; C copy kept |
| `orin_str_split` | L2 | moved: `strSplit` (empty separator still traps `split with empty separator`, status 101, via `console.error` + `process.exit(101)`); C copy kept |
| `orin_str_trim` | L2 | moved: `strTrim`; C copy kept |
| `orin_array_join` | L2 | moved: `strJoin` (grows the result by repeated in-place append instead of a pre-sized buffer); C copy kept |
| `orin_parse_int` | L2 | moved: `library/core/numbers.or` `strParseInt` (overflow checks done by hand; same accepted syntax); C copy kept |
| `orin_int_to_string`, `orin_usize_to_string`, `orin_bool_to_string` | L2 | moved: `intToString`, `usizeToString`, `boolToString` (no `snprintf`); C copies kept |
| `orin_parse_int_k` (`parseI8` .. `parseUsize`) | L2 | **R3b:** moved: `strParseIntK` (`library/core/numbers.or`; returns `Option<usize>` holding the kind's 64-bit pattern, signed kinds computed modulo 2^64); C copy kept for `--c-builtins` only |
| `orin_float_to_string`, `orin_f32_to_string`, `orin_parse_float` | L2 | **R3b: stay in C.** Shortest round-trip printing and correctly rounded parsing need `orin_platform_double_to_exp` / `parse_double` (L0, `printf`/`strtod`); R3a has no core operation for them and L0 is not touched by R3b. They become portable only with an Orin shortest-digits algorithm (Ryu/Grisu class) plus a correctly rounded decimal parser, or a new L0 entry exposed as a core operation (needs an ADR-0052 amendment) |
| `orin_float_to_int` | L1 intrinsic | **R3b: stays in C.** It is the float-to-int conversion itself (the cast and its `float to int out of range` trap); Orin has no other way to truncate a float |
| `orin_str_prepend`, `orin_str_append_int`, `orin_str_append_usize`, `orin_str_append_sub` | L1 | **R3b: stay in C.** In-place string growth under `rc == 1` and the sharing rule are the object model (R3d); the compiler fuses `s += x.toString()` into them |
| `orin_array_slice`, `orin_array_concat`, `orin_array_extend` | L1 | **R3b: stay in C.** They copy element slots and retain reference elements by the array's `is_ref` flag (object model); the generic prelude would need per-element-type instances, and ADR-0038 packed arrays rewrite them |
| `orin_bytes_to_string`, `orin_string_to_bytes` | L1 | **R3b: untouched** (perf thread, PR #142) |
| `orin_str_char_code_at` | L1 primitive | stays in C; now `static inline` in the header (the prelude loops over it) |
| `orin_str_char_at`, `orin_str_substring`, `orin_string_from_char_code` | L1 primitive | stay in C: allocation, bounds traps, shared 1-byte immortals |
| `orin_str_new`, `orin_str_concat`, `orin_str_append`, `orin_str_eq`, `orin_str_len`, `orin_str_data` | L1 | stay in C until R3 (object model, allocation, in-place append) |
| `orin_array_get`, `orin_array_slice`, `orin_array_concat` | L1 / L2 (generic) | stay in C: generic over the element type (see above); candidates for the array-API prelude or R3 |
| `orin_array_new`, `orin_array_push(_grow)`, `orin_array_pop`, `orin_array_len/at/slot_ptr` | L1 | stay in C until R3 |
| `orin_struct_*`, `orin_nullary`, `orin_variant1`, `orin_opt_unwrap`, `orin_res_unwrap(_err)`, `orin_tag` | L1 | stay in C until R3 |
| `orin_retain/dup/release/destroy`, `orin_make_unique(_slow)`, freelists, `orin_live_count`, `OrinStats` | L1 | stay in C until R3 |
| checked arithmetic and conversions (`orin_add_i` ... `orin_usize_to_int`) | L1 (codegen intrinsics) | stay in C (inline), R3 |
| `orin_trap`, `orin_init`, `orin_flush` | L1 shells over L0 | **R2 done:** the functions stay in `runtime/core/` as thin object-model-aware wrappers; all OS access is `orin_platform_init/write_line/exit/flush/at_exit/getenv` |
| `orin_console_log/error`, `orin_fs_read_file/write_file/exists`, `orin_process_args/exit`, `orin_runtime_io.h` (`std:io`) | L1 shells over L0 | **R2 done:** they only convert Orin strings to `(ptr, len)` and Result objects; OS work is `orin_platform_write_line`, `file_read/write/exists`, `error_message`, `arg_count/arg`, `exit`, `stdin_read/getc`, `shell` |
| allocation, `memcpy`/`memcmp`/`memset`/`memmem` in the object model | L0 | **R2 done:** `orin_platform_alloc/realloc/free`, `mem_copy/set/cmp/find`; `snprintf` replaced by `fmt_i64/fmt_u64` |

Labels: the prelude code is *safe Orin* (type-checked, MIR ownership-verified: `tools/verify_all.py`
covers all of it) with functional behaviour *tested only* (differential tests against the C versions
over all run suites, ASan/UBSan, plus `tests/run/std_prelude_edges.or`); everything still in C is
*trusted/tested only*. Observable differences: none intended; the trap for `split` with an empty
separator is raised through `process.exit(101)` after printing the same message.
- **R2 — carve out L0:** split the remaining C into `platform/` (the closed list; now `runtime/platform/`) and the object
  model; write L0 contracts.
  **Status: done (2026-10-13).** `runtime/platform/orin_platform.{h,c}` (about 440 lines incl. contracts; budget
  1,000) is the closed list; the final API: memory `alloc, realloc, free, mem_copy, mem_move, mem_set,
  mem_cmp, mem_find`; formatting `fmt_i64, fmt_u64`; process `init, arg_count, arg, getenv, at_exit, exit,
  abort, shell`; byte I/O `write, write_line, flush, stdin_read, stdin_getc`; files `file_read, file_write,
  file_exists, error_message`. No clock: nothing uses one yet (adding one needs an ADR). Every function has
  an ACSL-style `requires/ensures/assigns` block in the header. `tools/check_platform_boundary.sh` (CI)
  forbids direct libc calls/includes in `runtime/core/`. Assurance: memory, find and format primitives are
  bounded-verified with CBMC (`tools/verify_platform.sh`, docs/formal.md "L0 platform layer"); I/O, process
  and file primitives are tested only (`runtime/platform/tests/platform_test.c`, plain and under ASan/UBSan). The
  inventory above shows the layer of each runtime function after R2.
- **R3 — core dialect:** add core intrinsics (raw address type, load/store, size_of, header
  access) restricted to `core` modules; reimplement the object model (retain/release/make_unique,
  allocation, arrays, strings) in Orin; the C object model is deleted. Stage 0 keeps its own C
  runtime (frozen) or links the generated C of L1.
  - **R3a core operations (done, ADR-0052).** The first piece of the core dialect: ONE builtin family
    `BCore(k)` (table and doc in `compiler/hir/coreops.or`, same pattern as the task primitives `BTask`),
    exported by the internal module `std:core` (R3a: `std:fsraw`; moved in R3d.0, see below). An address is a plain
    `usize`; there is no new type and no operation that turns an address back into a reference. All operations
    that touch memory are impure for contracts and effects (loads read mutable memory); the bit operations,
    `expect` and `cfg` added in R3d.0 are pure. Both backends emit the same behaviour: loads and stores are native-endian and
    unaligned-safe (C: `__builtin_memcpy` of a constant size, LLVM: `align 1`); the memory operations are
    the L0 functions in C and libc malloc/free plus the LLVM intrinsics in LLVM. Self-test: `std:coreprobe`
    (`runtime/core/coreprobe.or`, `tests/run/core_ops.or`, compared on both backends).

    | operation | meaning |
    |---|---|
    | `load8/load32/load64(addr) -> usize` | zero-extended load of 1/4/8 bytes |
    | `loadF64(addr) -> float` | 8-byte IEEE load |
    | `store8/store32/store64(addr, v: usize)` | store of the low 8/32/64 bits |
    | `storeF64(addr, v: float)` | 8-byte IEEE store |
    | `memAlloc(n) -> usize` | `orin_platform_alloc` (never 0: `n = 0` gives one byte, and a failed allocation traps "out of memory", R3d.0) |
    | `memFree(addr)` | `orin_platform_free` |
    | `memCopy(dst, src, n)` | `orin_platform_mem_copy` (no overlap) |
    | `memSet(dst, byte, n)` | `orin_platform_mem_set` (low 8 bits of `byte`) |
    | `addrOf(x) -> usize` | object address of a string, array or record; read-only, the reference count is unchanged. An escape: the optimiser never unboxes, scalar-replaces or removes the operand (`opt/unbox.or`, R3d.0) |
    | `and/or/xor/shl/shr(a, b: usize) -> usize` (R3d.0) | bit operations (the language has none); a shift of 64 or more gives 0; pure |
    | `expect(b, likely) -> bool` (R3d.0) | `b` itself with a branch hint (`__builtin_expect`, `llvm.expect.i1`); `likely` should be a literal; pure |
    | `cfg(k) -> usize` (R3d.0) | build configuration: 0 free lists on, 1 hot counters, 2 site census; other `k` give 0; a constant, pure. The LLVM backend returns 1, 0, 0 until the driver flags of R3d.3 |
    | `heapBase() -> usize` (R3d.0) | address of the zero-initialised per-thread block `orin_heap` (`OrinHeap`, 128 words, `__thread`, local-exec; fields: "R3d.1" below); executables only |
    | `memRealloc(addr, n) -> usize` (R3d.0) | `orin_platform_realloc`, never 0 (traps "out of memory", the old block stays valid) |
    | `memMove(dst, src, n)` (R3d.0) | `orin_platform_mem_move` (ranges may overlap) |
    | `memCmp(a, b, n) -> int` (R3d.0) | `orin_platform_mem_cmp` normalised to -1, 0 or 1 (unsigned bytes) |
    | `hook(k, a, b, c: usize) -> usize` (R3d.5) | a call of the C runtime function `orin_core_hook(k, a, b, c)` (`runtime/core/orin_runtime.c`; the numbers are the `HK_*` constants of `runtime/core/heap.or`): the services that are still C when the Orin runtime needs them, namely `getenv`, one line on stderr, the runtime lock, the address of the totals of finished tasks (`g_fold`, `g_fold_live`), whether the hot counters are built in, and the allocation-site census hooks. Not pure; reachable like the other core operations only from `$rt/` |
    | `plat(k, a, b, c: usize) -> usize` (R3e.0) | a direct call of the L0 function `orin_platform_<name>` that the closed table of 20 functions (`platOpName` in `compiler/hir/coreops.or`; threads 0..3, monitors 4..13, process 14..19; named `PL_*` in `runtime/core/plat.or`) lists at index `k`, which must be a literal or a named constant below 20 (else E0404). Arguments are words (pointers are addresses; `thread_create` takes the `fnAddr` of a `void(void *)` entry), the result is the `int` / `int64_t` / pointer of L0 as a word (a C `int` sign-extended), 0 for a void function. Not pure, may write any memory, may not return (`thread_exit`, `exit`). The LLVM declarations carry no `readnone` / `readonly` / `argmemonly` / `nounwind`, and `tools/check_platform_boundary.sh` lints that and `orin_platform.h`; it replaces the L0-shaped hooks (R3e.1) |
    | `fnAddr(k: usize) -> usize` (R3e.0) | the address of the C-ABI wrapper (`orin_probe_entry`, later the task thread entry) of the L1 entry number `k` of `compiler/mir/rt.or`, a literal naming an entry of `fnAddrEntries()` (wrapper type `void(void *)`); pure |
    | `sharedBase() -> usize` (R3e.0) | address of the process-wide zero-initialised block `orin_shared` (`OrinShared`, 128 words, a plain global; layout "R3e.0" below); executables only; pure |

  - **R3d.0 preparation (done, ADR-0052 Addendum A; each item is a working assumption of its section 6 until the owner
    confirms it).** (1) *The `$rt` root* (question 1): `runtime/core/*.or` is the fourth embedded prelude root
    (`tools/embed_prelude.py`, `compiler/loader/prelude.or`), entry `$rt/module.or`, loaded into every compiled program but
    not by `noPreludeRoots()` (`check`, `api`, the language server, `--c-builtins`); the marker of a core module is the
    path prefix `$rt/`, not a manifest key `core = true` (the key is added when a second runtime needs user-visible core
    packages). (2) *The gate*: the internal module `std:core` exports exactly the core operations and only `$rt/` modules can
    import it (E0301 otherwise: `tests/next/errors/e0301_core_ops_are_internal.or`, `compiler/tests/loader_classes_test.or`);
    `std:fsraw` no longer exports them; `std:coreprobe` resolves to `$rt/coreprobe.or` (like `std:math`). (3) *Out of memory*
    (question 5): `memAlloc` and `memRealloc` trap "out of memory" (exit 101) on failure in both backends
    (`tests/run/core_oom_trap.or`, `core_oom_realloc_trap.or`). (4) *Seed bridge* (question 2): the runtime as it was before
    R3d is frozen in `bootstrap/seed/runtime/` and linked by stage 0 and stage 1 of `tools/bootstrap.sh` (stage 2 on links
    `runtime/core/`) and by the `--c-builtins` side of `tools/differential.sh --mode builtins`, which therefore compares the new
    world against the legacy world; programs of the core dialect (`std:coreprobe`) are skipped there. The C copies of the
    R1/R3b functions stay in the live runtime for now. (5) *One runtime source list*: `tools/runtime-sources.txt` names the
    files a program is linked with, per world (`core`, `legacy`); the shell tools (`tools/runtime_files.sh`), the Python tools
    (`tools/runtime_files.py`) and the Orin harnesses (`tooling/conformance`, `tooling/differential`) read it. Not yet
    converted (they name the installed layout or are literals in CI): `dist/orin-cli.sh`, `compiler/testing/runner.or`,
    `compiler/mcp/tools.or`, `tooling/mutation/src/{ox,net}_check.or`, `tooling/protocol/src/main.or`, `tooling/clitests/src/fmt.or`, `.github/workflows/{ci,bench}.yml`,
    `tools/verify_platform.sh`. The prune root set for L1 entries and the `--freelist` / `--stats` driver flags of `cfg` are
    not needed before the first L1 function is called by name (R3d.2 / R3d.3).

  - **R3d.2 the first L1 functions (done, ADR-0052 Addendum A sections 3 and 5).** `runtime/core/leaf.or` (module `$rt/leaf`): `optUnwrap`,
    `resUnwrap`, `resUnwrapErr`, `vUnwrap` (all `@Inline`), `trapShape`, `assertFact`, `assertArray`. Generated code calls them by name:
    `compiler/mir/rt.or` is the table (`rtNames`, `rtIds` find the function in the program), the backends cast an object to its address
    (`(uint64_t)(uintptr_t)` in C, `ptrtoint` in LLVM) and call `orin_fn_<i>_..` in place of the C function; `opt/prune.or` keeps `trapShape` always
    and the others where an instruction implies them (`rtImplied`: the unwrap builtins, `IForward`, `IArrayGetU/SetU`). A program without the
    entries (`--c-builtins`, hand-built MIR) emits the old C calls, so the frozen snapshot runtime serves that world. Traps are `taskTrap`
    (same message and exit 101 as `orin_trap`); the two checks of `--assert-facts` print through `console.error` and `exit(70)` (stdout is now
    flushed first). `trapShape` is called by the inline LLVM helpers (`orinl_slot`, `orinl_array_*`); C builds keep `orin_trap_shape` in C because
    the header inlines and the runtime call it (they move to the preamble in R3d.6). `orin_struct_copy_slot` had no caller in generated code
    or runtime and is deleted without a port. **Static nullary:** each payload-less variant tag a program uses is a static immortal object
    (`orin_nz<tag>`: C `static struct` in every unit that uses it, also in the split header and data unit; LLVM `internal global`), so
    `orin_nullary` (table, acquire load, compare-and-swap) is no longer called by generated code; for the C shells the header keeps a
    static-inline `orin_nullary` for tags 0 and 1. Deleted from `runtime/core/orin_runtime.c`: `orin_nullary`, `orin_assert_fact`,
    `orin_assert_array`, `orin_struct_copy_slot`, `orin_opt_unwrap`, `orin_res_unwrap`, `orin_res_unwrap_err`, `orin_v_unwrap`.
    Measured (valgrind, executed instructions, C / LLVM): bintrees 6,299,146,435 -> 5,591,750,641 (-11.2 %) / 6,029,451,956 -> 5,406,269,923
    (-10.3 %); mutres, pqueue, sortedmap, strings unchanged to 30 instructions; selfcompile (C) 24,781,316,263 -> 24,788,630,444 (+0.03 %).
    `ORIN_STATS` counters identical (`orin_nullary` was never counted).

  - **R3d.3 the object model in Orin (done, ADR-0052 Addendum A sections 3 and 5; three commits, each revertible alone).** (a) `runtime/core/object.or`
    (`structNew`, `variant1`, `arrayNew`, free lists); (b) `runtime/core/rc.or` (`destroy` iterative with the work stack in the heap block and the
    first dying child freed without a push, `makeUniqueSlow`); (c) `runtime/core/heap.or` (`sbAlloc`, `sbFree`, `sbRealloc`, the small-block cache),
    `strAlloc`, `arrayPushGrow` (kept out of line in LLVM, `noinline`). All sit on the `OrinHeap` block at the offsets of R3d.1. Generated code calls
    the entries directly (`newStruct`, array-new); the C shells of `orin_runtime.c` reach them through wrappers that the emitted code defines under the
    old C names (`backends/{c,llvm}/rtwrap.or`), so the C runtime keeps its call sites. New pure core operations 24..26: `wadd`, `wsub`, `wmul`
    (wrapping `usize` arithmetic; `wrappingAdd` is an out-of-line call and `+` adds trap paths). Census builds (`-DORIN_SITE_STATS`, `--stats-sites`)
    kept the C definitions until R3d.5 (the census hooks were C); `sb_drain` stays C. `cfg(0)` is a constant 1 in LLVM, so LLVM builds under ASan keep the free lists
    (ASan then does not see a recycled header). The C unit tests of the runtime link `tools/rt_stub.sh` (an empty program compiled to C with `main`
    renamed), which carries the wrappers. `compiler/mir/rt.or` also holds `rtAlways` (the entries `opt/prune.or` always keeps).
  - **R3d.4 strings and arrays in Orin (done, ADR-0052 Addendum A section 5).** `runtime/core/str.or` (`strConcat`, `strAppend`, `strAppendSub`,
    `strAppendInt`, `strAppendUsize`, `strPrepend`) and `runtime/core/array.or` (`arraySlice`, `arrayConcat`, `arrayExtend`, `bytesToString`,
    `stringToBytes`; the byte loops take eight elements per step) are entries 17..27 of `compiler/mir/rt.or`. The backends call them directly
    (`rtCallC`, `rtCallL`; objects as address words); without `$rt` (`--c-builtins`) they emit the old C call, which the frozen snapshot defines.
    Only `str_concat`, `str_append`, `array_slice`, `array_concat`, `array_extend`, `bytes_to_string` and `string_to_bytes` get a C-named wrapper
    (`rtWraps`), because the C unit tests call them; the others (`rtPlain`) have none. Growth, fresh allocation and the copying path of
    `arrayExtend` are separate `noinline` functions (`rtCold`). Counters are updated exactly as the C versions did. Census builds kept the C
    versions until R3d.5. `rc.or` exports `retain` and `release`.
  - **R3d.6 C preamble (done, ADR-0052 Addendum A section 3).** `compiler/backends/c/preamble.or` (`cInlines`, emitted by `cPreamble` into every
    generated C unit and, for `--split N`, into both the header and the data unit) defines the object-model inlines that generated code calls:
    retain / release / make_unique, the checked slot and array accessors, array push, the take / put / replace helpers of the MIR verifier's
    Unique objects, checked arithmetic and range conversions, `str_len` / `array_len`, the `OrinV0..3` aggregate types, and the `ORIN_CFG_*` macro
    constants that `cfg(k)` reads. They are the text `orin_runtime.h` and `orin_runtime_mir.h` had, under the prefix `orinc_` (the LLVM backend's
    `orinl_*` counterpart), so the machine code is unchanged; the preamble relies on the header only for the object layout, the `ORIN_STAT` /
    `ORIN_SITE_RC` hooks and the out-of-line entries. Both worlds get it, so `--c-builtins` output is unchanged in kind. `orin_runtime_mir.h` is
    deleted; the header lost the arithmetic and range inlines, `orin_s2f`, `orin_array_at_u` / `orin_array_slot_ptr_u` and the `ORIN_CFG_*` block. It
    keeps one copy of the inlines the C shells and their unit tests use (`orin_retain/dup/release/make_unique`, `orin_nullary/none/ok_void`,
    `orin_struct_*`, `orin_tag`, `orin_str_len/data/char_code_at`, `orin_array_push/len/at/slot_ptr`, `orin_f2s`): `orin_runtime.c`,
    `orin_runtime_io.h`, `orin_runtime_llvm.c` and `runtime/core/tests/*.c` are compiled without compiler output. R3f deletes them with the shells.
    Executed instructions against the R3d.5 base: every benchmark within +-0.00 % on C and LLVM, `selfcompile` +0.03 %; `ORIN_STATS` identical.
  - **R3d.5 stats, live count and the census on the Orin object model (done, ADR-0052 Addendum A section 5).** (1) `runtime/core/stats.or`:
    `statsReport` (the `ORIN_STATS=1` line, byte for byte the one the C `stats_report` printed, assembled in a raw buffer so that no Orin
    object is allocated while the counters are read) and `liveCount`, entries 28 and 29 of `compiler/mir/rt.or` with the C-named wrappers
    `orin_stats_report` (registered by `orin_init` with the platform at-exit list) and `orin_live_count`. (2) *Census prefix word* (Addendum
    rule 4): in a census build (`cfg(2)`) every heap object starts `pfx()` = 8 bytes after its block, the word before the header holds
    the allocating site, so `OrinObj` has no census fields and the offsets of the layout are the same in all builds; free lists and
    the small-block cache hold block addresses (the link is in the first word of the block, the prefix word). Immortal static objects
    have no prefix word: `ORIN_SITE_OF(o)` reads it unless the top two bits of the count are 11 (immortal; a lend-pinned object, bits 10, has one). (3) The census runs on the Orin entries: `rtIdsFor` and every
    `#ifdef ORIN_SITE_STATS` C copy (`struct_new`, `variant1`, `array_new`, `destroy`, `make_unique_slow`, the small-block functions,
    `str_alloc`, `array_push_grow`, the string append family, array slice/concat/extend, the byte conversions) are deleted. The Orin
    code reports to the census with `siteAlloc`, `siteGrow`, `siteFree` and `siteRc` (`heap.or`; constant-folded away unless `cfg(2)`),
    including `retain` / `release` / `decRef` of `rc.or`, as the header inlines of generated C do. Functions of `$rt` get no census
    sites (`sites.or` `isRtFunction`: no marks, no table entries), so what the runtime does is attributed to the site that called
    it, as when it was C. (4) *The C hook.* The census engine (`SiteCtr` tables, pair and call hash tables, fold at task end, the
    report) stays C in `orin_runtime.c`; Orin reaches it, `getenv`, the stderr line, the runtime lock and the totals of finished tasks
    (`g_fold`, `g_fold_live`, which `orin_rt_heap_exit` still writes) through the one new core operation 27, `hook(k, a, b, c)`, which calls
    `orin_core_hook` (a switch over 12 services, `HK_*` in `heap.or`); `HK_STATS_ON` keeps the `"counters"` field of an LLVM binary
    what it was (the label comes from the build of the C runtime, not from `cfg(1)`). (5) Census summaries: `peak_live_bytes` and
    `live_bytes` of a census run were 8 bytes per object larger (the widened header) and are now those of the normal build. `tools/test_resources.sh`
    checks that the objects a census run attributes to sites add up to its `alloc_total`.
  - **R3d.1 the per-thread heap block (done, ADR-0052 Addendum A section 5).** `g_live`, the free lists, the small-block cache, the
    work stack of `orin_destroy` and `orin_stats` are fields of one exported `__thread OrinHeap orin_heap` (1024 bytes, zero-initialised,
    the block `heapBase()` returns), so Orin code reaches each at a fixed offset. ADR-0017 behaviour is unchanged (per task, returned in
    `orin_rt_heap_exit`).

    | offset | size | field (`OrinHeap`) | was | note |
    |---:|---:|---|---|---|
    | 0 | 72 | `fl_struct[9]` | `fl_struct` | free struct objects by `nslots` 0..8 (next pointer in word 0) |
    | 72 | 8 | `fl_array` | `fl_array` | free array headers |
    | 80 | 80 | `fl_n[10]` (u64) | `fl_n` (u32) | list lengths, `[9]` the array headers; cap `FL_CAP` = 2^18 |
    | 160 | 8 | `live` (i64) | `g_live` | signed: a task can free more than it allocated |
    | 168 | 8 | `dstack` (`OrinObj **`) | `t_dstack` | work stack of `orin_destroy`, NULL until first use |
    | 176 | 8 | `dcap` (u64) | `t_dcap` | its capacity in entries |
    | 184 | 8 | reserved | | |
    | 192 | 144 | `stats` (`OrinStats`, 18 u64) | `orin_stats` | `alloc_string` +0, `alloc_array` +8, `alloc_struct` +16, `frees` +24, `retains` +32, `releases` +40, `cow_copies` +48, `cow_inplace` +56, `array_grows` +64, `string_grows` +72, `peak_live_objs` +80, `peak_live_bytes` +88, `live_bytes` +96, `file_opens` +104, `file_closes` +112, `transfer_moves` +120, `transfer_copies` +128, `tasks_spawned` +136 |
    | 336 | 8 | `task` | `t_task` (R3e.4) | address of the `RtTask` record of this thread, 0 on a thread that is not a task (`H_TASK`) |
    | 344 | 8 | `joined` | `t_joined_msg` (R3e.4) | the record of the task joined last by this thread (`H_JOINED`) |
    | 352 | 8 | `grants` | `g_grants` (R3c) | reserved for the grant table (`H_GRANTS`) |
    | 360 | 8 | `files` | `g_files` (R3c) | reserved for the open-file table (`H_FILES`) |
    | 368 | 8 | `netbuf` | `t_netbuf` (C4) | the per-task network buffer (`H_NETBUF`) |
    | 376 | 8 | `scratch` | | the out parameter of L0 calls (`thread_join`, `monitor_get`; `H_SCRATCH`) |
    | 384 | 120 | reserved | | up to 504 |
    | 504 | 8 | `probe` | | scratch word of `std:coreprobe` |
    | 512 | 272 | `sb[17]` (`{head, n}` pairs, 16 bytes each) | `sb_list`, `sb_cnt` (u32) | small-block cache by 16-byte class 0..16 (`SB_MAX` 256): list head @+0, length @+8, cap `SB_CAP` = 2^15 |
    | 784 | 240 | reserved | | up to 1024 bytes (128 words) |

    **Not moved (they stay `static __thread` in C until R3e; the census tables stay C, R3d.5):** `t_sites`, `t_pairs`, `t_calls` (census), `g_grants`, `g_files`, `t_task`, `t_joined_msg`, `orin_site_cur`, `orin_site_par`.
    Offsets do not depend on the build configuration (the lists and counters exist unused under `-DORIN_NO_FREELIST` or without `ORIN_STATS_ENABLED`) and are pinned by `_Static_assert`s in `runtime/core/orin_runtime.h`.
    `orin_stats` is now `#define orin_stats (orin_heap.stats)`, so inline code and generated C are unchanged; the block is `extern __thread OrinHeap orin_heap` (local-exec as before), `heapBase()` is its address (the C backend emits `&orin_heap`, the LLVM declaration is `[128 x i64]`).

  - **R3e.0 / R3e.1 the task interface starts (done, ADR-0052 Addendum B).** Three core operations (`plat`, `fnAddr`, `sharedBase`, table above) and
    the shared block `orin_shared`, a plain global defined in `orin_runtime.c` and listed in `bootstrap/seed/runtime/core-only-symbols.txt`
    (the legacy world never references it). Layout, pinned by `_Static_assert`s on `OrinShared` in `orin_runtime.h`: words 0..3 the transfer
    slot table (pointer, `n`, `cap`, free head), 4..7 the grant flight table (R3e.5), 8..63 reserved, 64..127 (byte 512) the line buffer of
    the process trap (the main thread only). Everything but the trap line is read and written only between `plat(RUNTIME_LOCK)` and
    `plat(RUNTIME_UNLOCK)`. `runtime/core/sync.or` holds the eleven monitor operations of `std:task` (`monNew` .. `monWaitUntil`, one `plat`
    call plus the failure test each); the backends call them in place of the C forwarders `orin_mon_*` through `l1Task` in `compiler/mir/rt.or`
    (entries 30 to 55 are numbered for all of R3e; a missing entry falls back to the C function of the same operation, so the C stays in the live
    runtime until R3e.6). `--rt-wrappers` (a `compile` flag, used by `tools/rt_stub.sh`) defines the C-named test wrappers of the entries
    (`rtTestWraps`, empty until R3e.6).


  - **R3b strings and numbers (partly done).** `parseI8` .. `parseUsize` moved (`strParseIntK`, one more slot in
    `compiler/lower/prelude.or`). The rest of the inventory above stays in C for the stated reasons; no core operation
    was needed (the port is plain safe Orin). **What still needs the C copies of the R1/R3b functions** (none is
    referenced by code generated in the default path, and none is deleted): (1) `--c-builtins`
    (`tools/differential.sh --mode builtins`, `BStr*`/`BParseInt*`/`BIntToString`/... fall back to the `orin_*` calls in
    `compiler/backends/c/function.or` and `compiler/backends/llvm/function.or`; `compiler/backends/llvm/runtime.or` declares them); (2) the
    frozen seed `bootstrap/seed/orin-seed.c.gz` is the compiler program compiled WITH the prelude, so the seed program itself
    does not call them (they appear there only as strings of the emitter tables), but it links the same
    `runtime/core/orin_runtime.c` and its `--c-builtins` mode needs them. Deleting them means deleting `--c-builtins`
    and the builtins differential mode; that is the R3f step, not R3b.
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
