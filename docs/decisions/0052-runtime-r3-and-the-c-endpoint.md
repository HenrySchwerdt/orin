# ADR-0052: Runtime R3 plan and how much C remains

Status: accepted (2026-10-16, Henry). Refines ADR-0013 and spec 19 §4 (R3/R4); no code change in this ADR.

## Question

ADR-0013 already decided that the runtime is predominantly Orin over a small, separately verified C
platform layer. R1 (std logic in Orin) and R2 (L0 carve-out) are done; R3 (object model in Orin) has
not started. The open question is how far R3 goes: does any hand-written C have to remain at all?

## Current state (main 46cae57)

| Part | Location | Size | Layer |
|---|---|---|---|
| Object model: alloc + small-block cache, RC, make_unique, destroy, structs/variants | `runtime/core/orin_runtime.{c,h}` | ~3,200 lines C (c + h) together with the rows below | L1 |
| Strings, number formatting/parsing, arrays (slice/concat/join/extend) | same | | L1 / L2 |
| Capability, fs, file, net, process shells (Orin values <-> `(ptr, len)`) | same + `orin_runtime_io.h` | | L1 |
| Task value transfer, per-task heap (`orin_rt_*`, ADR-0017) | same | ~340 code lines | L1 (temporary C) |
| LLVM out-of-line shims | `runtime/core/orin_runtime_llvm.c` | 46 lines | glue |
| OS access: memory, I/O, fs, clock, process, net, threads/monitors, policy | `runtime/platform/orin_platform.{c,h}` | ~1,000 code lines, contracts, CBMC harnesses | L0 |

## Decision

1. **Everything in `runtime/core/` moves to Orin (R3).** That includes the allocator and small-block
   cache, RC, `make_unique`, destroy, strings, arrays, the I/O shells, and the `orin_rt_*` task
   interface. The C object model is deleted at the end of R3, as ADR-0013 requires.
2. **`runtime/platform/` (L0) stays C for now.** Reasons:
   - The stable OS interface is libc (macOS has no stable syscall ABI; pthreads, `getaddrinfo`,
     `posix_spawn` are libc). Orin code would call the same symbols, so rewriting L0 in Orin removes
     no dependency.
   - L0 is the part we verify with CBMC (ADR-0030). An Orin L0 would lose those proofs until Orin's
     own verifier covers the core dialect.
   - It is small (≤ 1,000 code lines, hard budget) and has no data structures, so it is the
     cheapest trusted base we can have.
   Revisit after R3 (see "Zero C" below).
3. **Generated C is not hand-written C.** The C backend stays as the bootstrap path (`seed/`) and as
   the explicit fallback next to LLVM (`--release` uses LLVM since #129). It compiles the Orin L1
   runtime like any other module.
4. **The program entry point stays libc `main`** in L0 (`orin_platform_init`); no custom `_start`.
   A freestanding target (WASI, embedded) gets its own L0 file, not a different L1.

## Core dialect (prerequisite)

R3 needs the core dialect from ADR-0013, legal only in modules marked `core = true` in the manifest:

- raw address type and `load<T>` / `store<T>` at byte offsets, `sizeOf<T>`, object-header access;
- calls to L0 functions by declaration (`extern` to `orin_platform_*`), no other foreign calls;
- thread-local globals (per-task heap state, `orin_stats`);
- checked-arithmetic and branch-hint intrinsics map to what both backends already emit inline.

Safe code and annotation expansion can never reach these constructs (negative tests required).

## Order

Each step is a small PR, keeps stage2 == stage3 for both backends, and is benchmarked (`bench/`,
no regression without an ADR, ADR-0013).

- **R3a** core dialect in the compiler (`compiler/` only; coordinate with ADR-0049 steps in `check/`).
- **R3b** string, number and array functions without allocation policy (index/split/trim/join/format/parse).
- **R3c** capability, fs, file, net and process shells over L0.
- **R3d** allocator, small-block cache, RC, `make_unique`, destroy, struct/variant construction.
  Starts only after the ADR-0038 perf work in `runtime/core/` (packed arrays, in-place reuse) is merged,
  because it rewrites the same code. Hot paths must stay inlinable: the LLVM backend already emits
  retain/release and field access as IR; the C backend emits L1 hot functions `static inline`.
- **R3e** task transfer and per-task heap (`orin_rt_*`, porting table in ADR-0017 Addendum A).
- **R3f** delete the C object model and `orin_runtime_llvm.c`; `tools/check_platform_boundary.sh`
  then asserts that `runtime/core/` contains no C.

R4 (L1 refinement proofs against the Lean machine) follows per ADR-0013.

## Zero C

After R3 the only hand-written C is L0. Removing it too means writing L0 in core-dialect Orin with
`extern` calls straight into libc. That is possible, but it trades CBMC-verified C for unverified
Orin and still links libc. It becomes worth doing only when Orin's verifier covers the core dialect
(so L0 keeps a proof) or when a target without libc (WASI, bare metal) needs a non-C L0 anyway.

## Consequences

- The trusted C shrinks from ~4,200 lines to the ~1,000-line verified L0.
- The object model becomes readable and verifiable in Orin, which R4 needs.
- Risk: performance of the hot RC/alloc path; mitigated by the benchmark gate and by doing R3d last.

## Addendum A: R3d object model in Orin (design)

Status: proposed (2026-10-16). Step R3d.0 is implemented on the working assumptions of section 6 (spec 19 "R3d.0 preparation"); the rest is design only. Read against PR #141 (R3a `BCore`, R3b). *(inference)* marks a conclusion from the code,
not something the code states. Open questions for the owner: section 6.

### 1. Where the L1 modules live, how they load, how the gate narrows

- **Sources:** `runtime/core/*.or` beside the C files: `layout.or` (offsets), `heap.or` (TLS block, free lists, small-block cache), `object.or`
  (struct/array/string allocation, make_unique), `rc.or` (destroy), `stats.or`, `module.or`. `tools/embed_prelude.py` lists only `*.or`, so the C files are ignored.
- **Loading:** a fourth embedded root, a row `("runtime/core", "$rt", "compiler/loader/embedded_rt.or", "embeddedRtFiles")` in `PRELUDES` and a
  `PreludeRoot` in `preludeRoots()` (`compiler/loader/prelude.or`; its `@Ensures` says `length == 3` today) with entry `$rt/module.or`, so every
  compiled program gets it. `noPreludeRoots()` (check, api, language server, `--c-builtins`) does not: the object model is below the checker.
- **Pruning:** `compiler/opt/prune.or` drops uncalled `$` functions. The backends call L1 by name (section 3), which HIR/MIR do not show, so
  prune gets a second root set: the entries implied by the instruction kinds present (`IStructNew` -> `structNew`) *(inference; keeping all
  ~30 entries is the cheap alternative)*.
- **Gate today:** `loader/resolve.or:136` lets any importer whose path starts with `$` (all of `$std`, `$array`, `$stdlib`) import `std:fsraw`,
  and the `BCore` family hangs on that module (`check/collect.or` `coreVal`). **Narrowing:** (a) a new internal module `std:core` exporting
  only `BCore`, importable only from `$rt/` (E0301 otherwise; update the `@Ensures` of `resolve`); (b) `std:fsraw` stops exporting `BCore`;
  (c) `library/std/coreprobe.or` moves to `runtime/core/coreprobe.or`, still reached as `std:coreprobe` by a special case like `std:math` ->
  `$array/math.or` (`resolve.or:127`), so `tests/run/core_ops.or` keeps working; (d) negative tests: a user file and a `$std`/`$array`/`$stdlib`
  file importing `std:core` fail with E0301, and `compiler/testing/transform.or` (it synthesizes `std:fsraw` imports) still compiles.
- **`core = true`:** `package/manifest.or` has no such key and embedded roots have no manifest. In R3d the prefix `$rt/` is the marker (question 1).

### 2. Core operations R3d needs

R3a has load/store 8/32/64/F64, `memAlloc/Free/Copy/Set`, `addrOf` (`compiler/hir/coreops.or`, 0..12). **No address -> reference operation is
added:** L1 entries take and return addresses as `usize` and the backends insert the pointer casts at the call (as `coreC` does for `addrOf`),
so the language still cannot forge a reference. `sizeOf<T>` (listed above in this ADR) is not needed: every slot is 8 bytes.

| new op (13..) | C / LLVM | semantics and safety rule |
|---|---|---|
| `and, or, xor, shl, shr` (usize) | `& \| ^ << >>` / `and or xor shl lshr` | The language has **no bit operators** (`BinOp` in `hir/hir.or`: Add..Rem, comparisons, And/Or). Needed for `refmask >> i & 1`, the lend pin test (`rc >> 62`) and the signed test `rc > 0`. A shift of 64 or more gives 0 (no UB). **Pure**, unlike loads |
| `expect(b: bool, likely: bool)` | `__builtin_expect` / `llvm.expect.i1` | identity on `b`, a hint; keeps the `ORIN_LIKELY` of the C header on free-list hit and `rc > 0` |
| `cfg(k)` -> usize | macro constant in the emitted preamble / module constant | 0 free lists on (off under ASan or `-DORIN_NO_FREELIST`), 1 hot counters (`ORIN_STATS_ENABLED`), 2 site census. Folds away; LLVM takes them from flags the driver sets (`--freelist=off`, `--stats`) |
| `heapBase()` -> usize | `static __thread uint64_t orin_heap[N]`, `tls_model("local-exec")` as `orin_stats` today / `thread_local(localexec)` global | the per-thread block of section 5; zero-initialised, so a new thread starts with empty lists as today; executables only |
| `memRealloc, memMove, memCmp` | `orin_platform_realloc/mem_move/mem_cmp` / libc `realloc`, `llvm.memmove`, `memcmp` | already in the L0 list. `realloc` keeps in-place growth over 256 bytes (`sb_realloc`), `memMove` is `str_prepend`, `memCmp` is `str_eq` |

Rules, each pinned by a test in R3d.0:
1. **`memAlloc` may return 0.** The R3a table says "never 0", but `coreC` (`backends/c/function.or:229`) emits plain `orin_platform_alloc` = `malloc`.
   Either the op traps "out of memory" itself (question 5) or L1 checks (`taskTrap` with a literal allocates nothing).
2. **`addrOf` is an escape.** `BCore` appears nowhere in `compiler/opt/`; `unbox.or:519` whitelists only `readsVariant` builtins and `lits.or` matches
   named ones *(inference: an unlisted builtin disqualifies, untested)*. A record unboxed by MIR v2.2 or an array literal scalar-replaced (ADR-0038
   addendum "escape analysis") has no address, so an operand of `addrOf` is never unboxed or removed. L1 takes addresses of strings and arrays only.
3. **Layout is frozen in R3d:** `rc`@0, `kind`@8, `tag`@12; string `len`@16 `cap`@24 `data`@32; array `len`@16 `cap`@24 `is_ref`@32 `items`@40; struct
   `nslots`@16 `refmask`@24 `slots`@32 (asserted in `runtime/core/orin_runtime_llvm.c`). `rc > 0` is live, `rc <= 0` immortal or lend-pinned (top two bits,
   "lending" in `orin_runtime.c`); both backends' inline retain/release rely on it and L1 keeps it.
4. Census builds (`ORIN_SITE_STATS`) widen the header by 8 bytes, which would make every offset conditional. L1 puts the site id in a **prefix
   word** before the header (question 4), so rule 3 holds in all builds.

### 3. How generated code reaches the object model

- **Stay compiler-emitted inline** (a few instructions on the fixed layout; the MIR verifier and the ADR-0038 T1..T6 facts reason about them as
  instructions): retain/dup, release fast path (decrement, test, call destroy), `make_unique` fast path, checked struct/array slot access,
  `array_push` without growth, `struct_init`, checked arithmetic. LLVM already has them as text (`backends/llvm/runtime.or`: `orinl_dup`,
  `orinl_release`, ...). The C backend gets the same text as a preamble (`backends/c/preamble.or`, new) in place of the `static inline` of
  `orin_runtime.h`/`orin_runtime_mir.h`; the header copy stays for the C shells until they are gone (R3d.6: only the inlines the shells use).
- **Become Orin functions:** `struct_new`, `array_new`, `variant1`, string allocation, free lists, the small-block cache (`sb_*`, #121), `destroy`
  (iterative, per-task work stack), `make_unique_slow`, `array_push_grow`, the string append family, array slice/concat/extend, `trap_shape`, the
  `--assert-facts` checkers, unwrap helpers, `stats_report`. `orin_nullary` becomes **static immortal objects emitted per used tag** (C: initialised
  static like `ORIN_STRING_LIT`; LLVM: constant global): no table, acquire load or CAS; the bintrees profile charges it 19 of 186 instructions per
  node. Singleton identity is only tested in `runtime/core/tests/runtime_test.c:135` *(inference from grep)*.
- **Calling:** the backends find an entry by name in `prog.functions` (as `preludeIds` does for R1) from a table `compiler/lower/rt.or` and wrap the
  call by `MType` (reference operands `(uint64_t)(uintptr_t)`, results back to `OrinObj *`; LLVM `ptrtoint`/`inttoptr`). Names keep their C spelling
  (`orin_struct_new`) while a C file calls them; the prototype then moves from `orin_runtime.h` to a private `orin_l1_abi.h` included only by
  `runtime/core/*.c` (otherwise the generated unit sees two declarations), and an entry with a C caller also gets an exported one-line wrapper.
- **Inlining:** L1 is part of the program MIR, so definition and call share one translation unit (the benchmark build has the runtime as a
  separate unit, no LTO: docs/benchmarks.md "Methodology"). Hot entries get `@Inline` (ADR-0024 s4): `static inline` in C (`backends/c/symbols.or:18`),
  `alwaysinline` in LLVM (`backends/llvm/function.or:1373`); E0444 already forbids recursion. `destroy` stays out of line. It also removes the
  residue named in ADR-0038 gate 1 (runtime compiled by clang instead of gcc: `appends` +0.9 %, `bintrees` +0.5 %).
- **Costs to watch (inference):** L1 uses `wrappingAdd/Sub/Mul` (`check/ints.or`) where overflow is impossible, since `usize` arithmetic is
  checked; `inttoptr` loads are may-alias in LLVM, so an inlined `struct_new` can kill the caller's forwarded loads (T4, TBAA); if bintrees
  shows it, `struct_new` stays a call in LLVM.
- **OrinStats and census:** `OrinStats` becomes a field range of the TLS block; the C backend's inline `orin_stats.retains++` is unchanged (LLVM counts
  nothing inline today); Orin code updates counters under `cfg(1)`. The `ORIN_STATS=1` JSON, `live_objs_at_exit`, `ORIN_STATS=sites` and
  `tools/alloc_census.py` keep their format. The counters are deterministic, so they are the equivalence oracle of every step.

### 4. Bootstrap: two object models coexist, then one is deleted

- **Problem:** `tools/bootstrap.sh` links the seed (old emitter) and `stage1.c` (emitted by `orin0`, old logic) with the live
  `runtime/core/orin_runtime.c`; both reference `orin_struct_new`, `orin_destroy`, ... The live runtime cannot lose a definition before the seed is
  regenerated. ADR-0017 Addendum A's "no seed bridge needed" (ABI only grew) ends here.
- **Seed bridge (R3d.0):** freeze `orin_runtime.{c,h}`, `orin_runtime_io.h`, `orin_runtime_mir.h`, `orin_runtime_llvm.c` into `bootstrap/seed/runtime/`
  (ADR-0014). `bootstrap.sh` links `seed.c` and `stage1.c` against it, stage 2 on against `runtime/core/`. Stage 2/3 come from compilers with the new
  logic, so `stage2.c == stage3.c` keeps its meaning per backend.
- **`--c-builtins` becomes the "legacy world":** one flag selects the frozen runtime (C copies of the R1/R3b functions *and* the C object model;
  `$rt` and `$std` not loaded). The C copies of `strIndexOf`, `parseInt`, ... can then leave the live runtime in R3d.0. `tools/differential.sh --mode
  builtins` becomes "new world against legacy world" (same program and compiler, different runtime): the oracle R3d needs for the object model.
  The name stays until R3f. (If R3c lands first its C shells follow the same snapshot rule.)
- **Deletion order:** (1) R3d.7 `tools/update_seed.sh` with an R3d compiler: the seed contains L1, bootstrap no longer needs the snapshot; (2) R3e
  removes `orin_rt_*` and the C thread-local state; (3) R3f: header inlines and `orin_runtime_mir.h`, then the legacy flag, the snapshot and the
  `builtins` mode, then `orin_runtime.c` and `orin_runtime_llvm.c`. The link line becomes `cc -I runtime/core out.c runtime/platform/orin_platform.c`;
  it is spelled in ~15 places (`tools/bootstrap.sh`, `dist/orin-cli.sh:413`, `tools/dev.sh`, `tooling/{conformance,differential,mutation,benchmarks,
  explorer}`, `tools/{check_encoding,test_net,test_forward_assert,test_concurrency}.*`, `ci_local.sh`), so R3d.0 puts the runtime source list in one
  place the others read. `tools/check_platform_boundary.sh` then asserts that `runtime/core/` has no `.c`/`.h`.

### 5. Sub-steps, gates, task heaps

Gate for every step: `stage2.c == stage3.c` and `tools/llvm_fixpoint.sh`; conformance and `differential.sh` (all modes, plus `--sanitize`); the
`ORIN_STATS=1` counters of every `bench/` program **identical** to the step before; executed instructions (`tools/bench.py`) at most +1 % per step on
every benchmark and +2 % cumulative for R3d (the CI verdict fires at +2 %, wall time +15 %: docs/benchmarks.md); LLVM/C ratio per benchmark not
worse than the table "Backends: ADR-0038 §8 gate 1".

| step | content (one PR each) | gating benchmarks | risk |
|---|---|---|---|
| R3d.0 | `$rt` root, `std:core` gate and negative tests, ops of section 2, `addrOf` escape rule, `rt.or`, prune roots, seed bridge, one runtime source list, legacy flag. No emitted-code change | all; self-compile output byte-identical | low |
| R3d.1 | runtime only: `g_live`, `fl_*`, `sb_*`, `t_dstack`, `orin_stats` into one exported `__thread orin_heap` with documented offsets and `_Static_assert`s | bintrees, mapfreq, wordfreq, strings, selfcompile; expect 0.00 % | low (TLS cost was 1.0197 in "Concurrency stage 0") |
| R3d.2 | leaves without allocator state: unwraps, `trap_shape`, `assert_*`, `struct_copy_slot`; static `nullary` | **bintrees** (expect about -10 %), mutres, pqueue, sortedmap | low |
| R3d.3 | on the shared block: (a) `struct_new/array_new/variant1` + free lists, (b) `destroy`, `make_unique_slow`, (c) small-block cache, string allocation, `array_push_grow` | **bintrees** (destroy 62, struct_new 42 per node), sortedmap, mapfreq, qsort_func; (c) appends, strings, wordfreq, bytesstr, http_parse, html, url, selfcompile | **highest**: hot path, checked arithmetic, aliasing, `-O1` inlining; a/b/c revert alone. **Done**: bintrees -20.3 % (C and LLVM) against the pre-R3d.2 base, every other benchmark within +0.7 % (C) / +0.0 % (LLVM) of it; the commits are within budget one by one (LLVM bintrees (b) +0.35 % over (a)); wadd / wsub / wmul added to avoid checked arithmetic; census builds keep the C allocator until R3d.5 |
| R3d.4 | strings and arrays (R3b leftovers): `str_concat/append/prepend/append_*`, `array_slice/concat/extend`, `bytes_to_string`, `string_to_bytes` | appends, mutres, strings, bytesstr, qsort_inplace, qsort_func, streams, url | medium: per-element retain by `is_ref` in a raw loop; appends/mutres are the in-place canaries**Done**: `runtime/core/{str,array}.or`; wrappers only for the 7 functions the C unit tests call; census builds kept the C versions under `#ifdef ORIN_SITE_STATS` until R3d.5. Executed instructions against the R3d.3 base, LLVM: appends -19.0 %, bytesstr -21.0 %, html -10.8 %, strings -4.4 %, qsort_func -9.8 %, url -1.8 %, http_parse -0.8 %, wordfreq +0.6 %, the others within +0.01 %; C: bytesstr -5.7 %, qsort_func -9.9 %, http_parse +1.1 %, wordfreq +0.9 %, selfcompile +0.4 %, the others within +-0.5 %; `ORIN_STATS` counters of every benchmark identical. The fresh-allocation paths are separate `noinline` functions (`rtCold`), so the in-place path of an append keeps its few registers |
| R3d.5 | stats, `stats_report`, census prefix word, `live_count` | counters and `tools/alloc_census.py` output identical; `tools/test_resources.sh` | low. **Done**: `runtime/core/stats.or` (`statsReport`, `liveCount`; entries 28 and 29, wrappers `orin_stats_report`, `orin_live_count`); in a census build every heap object has the 8-byte prefix word before its header (`pfx()`), so `OrinObj` is 16 bytes in all builds; the census runs on the Orin entries and every `#ifdef ORIN_SITE_STATS` C copy (`struct_new`, `variant1`, `array_new`, `destroy`, `make_unique_slow`, the small-block functions, `str_alloc`, `array_push_grow`, the string append family, array slice/concat/extend, the byte conversions) and `rtIdsFor(sites)` are deleted. The C census hooks cannot be called from Orin, so the step adds one core operation, **`hook(k, a, b, c)` (27)**, a call of the C function `orin_core_hook`: the census tables, folding and report stay C (their port belongs with R3e, which owns `orin_rt_heap_exit`, the writer of `g_fold`), and the same hook gives the report `getenv`, the stderr line, the runtime lock and the address of the totals of finished tasks; functions of `$rt` get no census sites, so the runtime is attributed to its caller as when it was C. Measured against the R3d.4 base (executed instructions, valgrind): LLVM `mapfreq` -2.0 %, `wordfreq` -2.0 %, `html_hand` -1.2 %, `html` -0.7 %, `strings` -0.7 %, `appends` +0.2 %, the others within +-0.02 %; C `wordfreq` -2.4 %, `mapfreq` -2.3 %, `html_hand` -2.3 %, `html` -1.5 %, `strings` -1.4 %, the others within +-0.02 %, `selfcompile` +0.09 %; the gains come from the `mapfreq` fix below, not from this step. `ORIN_STATS` of every benchmark identical; the `alloc_census.py` site, pair and call tables of every workload are identical modulo site renumbering (only thread-timing counters of the pool workers vary, between two runs of the same binary too), the census summary's `peak_live_bytes` is now that of the normal build (it was 8 bytes per object higher). **`mapfreq` (left +1.40 % on LLVM by R3d.4):** the cause was `appendDecimal` counting the digits by repeated division before writing them by repeated division (about 21 instructions per `"w" + n.toString()`, where the C version formed the digits once); `decimalDigits` now counts by a ladder of compares (division only from six digits on) |
| R3d.6 | C preamble replaces the header inlines for generated code | all (C output changes textually) | medium. **Done**: `compiler/backends/c/preamble.or` (`cInlines`, via `cPreamble`; also in the header and data unit of `--split N`) defines the inlines generated code calls under the prefix `orinc_` (retain/release/make_unique, struct and array slot access, array push, the MIR take/put/replace helpers, checked arithmetic and conversions, `OrinV0..3`) and the `ORIN_CFG_*` constants of `cfg(k)`, with the text the header had; generated code calls only `orinc_*`. `orin_runtime_mir.h`, the arithmetic, range, `s2f`, unchecked-array and `ORIN_CFG_*` parts of `orin_runtime.h` are deleted. The header keeps one copy of the inlines the C shells and their unit tests still call (`orin_retain/dup/release/make_unique`, `orin_nullary/none/ok_void`, `orin_struct_*`, `orin_tag`, `orin_str_len/data/char_code_at`, `orin_array_push/len/at/slot_ptr`, `orin_f2s`); they go with the shells in R3f. The seed compilers are untouched (they emit and link the legacy world). Executed instructions against the R3d.5 base: every benchmark within +-0.00 % on C and LLVM (the preamble is the old text), `selfcompile` +0.03 %; `ORIN_STATS` of every benchmark identical |
| R3d.7 | seed refresh | bootstrap from the new seed; selfcompile | low. **Done**: `tools/update_seed.sh` from b8e7a691 (R3d.0-R3d.6, the concurrency stack #175/#184/#186/#187/#189 and #191 in), built with `--c-builtins` as Addendum B section 4 says, so stage 0 and stage 1 still link the frozen snapshot until R3e.7. Bootstrap from the new seed: `stage2.c == stage3.c`, conformance 144/144, `tools/llvm_fixpoint.sh` OK, `differential.sh --mode builtins` 459 programs with 0 differences, `check_seed_runtime` OK |

**ADR-0017 task heaps.** The TLS block is the per-task heap state, so the allocator is thread-local by construction with today's rules: a block is
plain `malloc` memory, may be freed by another thread and joins that thread's capped list (`FL_CAP`, `SB_CAP`), and every list is returned at task
end. The block reserves room for later fields (pointers to grant and file tables, `t_task`). **Deferred to R3e:** `orin_rt_heap_exit` (folds counters
under the L0 runtime lock, for which no core op exists, and revokes grants and closes files), `transfer`/`lend` (`graph_unique`, `copy_node` read
`refmask`, `is_ref` and the pin bits), `task_main` (calls a closure through a raw function address; no core op). In R3d they stay C and read the
shared block through the offsets of R3d.1. The porting table of ADR-0017 Addendum A is unchanged.

**R3d.1 (done): the offsets of the shared block.** `heapBase()` is `&orin_heap`, `extern __thread OrinHeap orin_heap` in `runtime/core/orin_runtime.h`
(1024 bytes, 128 words, replacing the 64-word placeholder of R3d.0; word 63 stays the scratch word of `std:coreprobe`). Every offset is pinned by a `_Static_assert`.

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
| 336 | 168 | reserved | | task pointer, grant and file tables (R3e) |
| 504 | 8 | `probe` | | scratch word of `std:coreprobe` |
| 512 | 272 | `sb[17]` (`{head, n}` pairs, 16 bytes each) | `sb_list`, `sb_cnt` (u32) | small-block cache by 16-byte class 0..16 (`SB_MAX` 256): list head @+0, length @+8, cap `SB_CAP` = 2^15 |
| 784 | 240 | reserved | | up to 1024 bytes (128 words) |

**Not moved (they stay `static __thread` in C until R3e):** `t_sites`, `t_pairs`, `t_calls` (census), `g_grants`, `g_files`, `t_task`, `t_joined_msg`, `orin_site_cur`, `orin_site_par`.
Offsets do not depend on the build configuration (the lists and counters exist unused under `-DORIN_NO_FREELIST` or without `ORIN_STATS_ENABLED`) and are pinned by `_Static_assert`s in `runtime/core/orin_runtime.h`.
`orin_stats` is now `#define orin_stats (orin_heap.stats)`, so inline code and generated C are unchanged; the block is `extern __thread OrinHeap orin_heap` (local-exec as before), `heapBase()` is its address (the C backend emits `&orin_heap`, the LLVM declaration is `[128 x i64]`).

### 6. Open questions for the project owner

**Working assumptions until the owner confirms (2026-10-17):** the work proceeds on the recommendations below, as the decision
card in the project thread says it would. Budget rule as applied: per step at most +1 % executed instructions on the LLVM backend
(the `--release` default), and below +2 % on the C backend. R3d.1 measured LLVM -0.9 to -1.6 %, C +0.55 to +1.62 % (bintrees).
Each assumption is a separate commit (R3d.0) and can be reverted alone if the owner decides otherwise.

1. **Marker of a core module.** Recommend virtual root `$rt/` plus internal module `std:core`, and amending spec 19 and this ADR from "manifest
   `core = true`" to "modules of the embedded runtime root"; add the key when a second runtime (WASI, freestanding) needs user-visible core packages.
2. **Seed bridge.** Recommend the frozen snapshot in `bootstrap/seed/runtime/` (also the `--c-builtins` runtime) over keeping the C object model in
   the live runtime until R3f: each step deletes its C at once. Cost: a ~4,000-line frozen copy until R3f.
3. **Budget.** Recommend +1 % instructions per step, +2 % cumulative, a net gain on `bintrees` as the target; above that an ADR (ADR-0013). Confirm.
4. **Census layout.** Recommend the prefix word (offsets build-independent, LLVM asserts valid) over a wider header conditional on `cfg(2)`.
5. **Out of memory.** Recommend that `memAlloc` itself traps "out of memory" (like `xmalloc`): L1 and the R3a table cannot disagree. It changes
   R3a behaviour only for a failed allocation.
6. **Order against R3c.** R3d does not need R3c; both touch the C shells and the snapshot rule. Recommend R3c first if nearly done, else R3d.0-R3d.2
   in parallel and R3d.3 after it.

## Addendum B: R3e design (task interface)

Status: accepted (2026-10-17; the owner delegated the open decisions to the project coordinator, which took every recommendation of
section 8). Written as a design; R3e.0 and R3e.1 are implemented (rows of the table in section 5). Structure and depth follow Addendum A.
*(inference)* marks a conclusion from the code, not something the code states. Basis of the design: `origin/main` d0a17a96 (R3d.5 done)
plus the open concurrency work, read from its branches (PR number to head branch by `gh api repos/henryschwerdt/orin/pulls/N`): #175
`claude/project-thread-5wtl8u-c4` (C4), #187 `...-c3` (C3, base c4), #189 `...-c5` (C5, base c3), #184 `...-gm` (ADR-0040), #191
`claude/adr0048-fs`. What each means for R3e is in section 7. Open questions: section 8.

**Re-derived from the merged tree before R3e.0 (2026-10-17, `origin/main` b8e7a691: the whole stack and R3d.6 are in, R3d.7 is not).** The
tables below were checked against the code and stand, except: (1) L0 is **1,167** code lines (measured with the `tools/verify_platform.sh`
method), not 1,163, so **233** of 1,400 stay reserved; (2) `taskOpCount` is 37, the last `rt.or` entry is 29, the heap block is 1,024 bytes
with the reserved range at 336..503 (21 words), and the C tasks section is 588 lines (1472 to the end of `orin_runtime.c`), as written;
(3) the core operations were numbered 0..27, so `plat`, `fnAddr` and `sharedBase` are 28, 29 and 30 as written and `coreOpCount` is 31;
(4) all 20 functions of the `plat` table exist in `orin_platform.h`, `orin_platform.c` and the Orbit L0 (`runtime/platform/orbit`).

### 1. What moves to Orin, what stays C

The interface is the "tasks and transfer" section of `runtime/core/orin_runtime.c` (about 580 lines to the end of the file on main; ADR-0017 counts
342 code lines) plus the grant flight table. Destination modules are new files of the `$rt` root (`runtime/core/*.or`), one per step of section 5.

| C today (`orin_runtime.c`) | Orin (`$rt`) | Needs from outside Orin |
|---|---|---|
| `orin_mon_*` (11 forwarders: new, free, lock, unlock, wait, wait_until, notify_all, notify_one, get, set, grow) and `mon_check` | `sync.or`: one `@Inline` function per op, a `plat` call plus the failure test | L0 `orin_platform_monitor_*` |
| `orin_rt_transfer_put/take/drop/count`, `tr_publish/claim_kind/is_lend` (slot table, generation tokens), `graph_unique`, `copy_node`, `deep_copy` | `transfer.or` | `runtime_lock/unlock`; the shared block (2.3) |
| `orin_rt_lend`, `lend_put/lend_end`, `pin_*`, `orin_rt_par_threads` | `lend.or` | `thread_id`, `cpu_count`, `getenv`, runtime lock |
| `orin_rt_task_spawn/join/message/watch`, `RtTask`, `task_main`, `task_signal_done`, `task_trap`, `orin_rt_heap_exit`, `orin_rt_trap_str`, **`orin_trap`** | `task.or` | `thread_create/join/exit`, monitors (done signal), `write_line`, `exit` |
| `orin_cap_clone/move/adopt_*` and the flight table `g_gf` (plus `orin_cap_adopt_net/stream` of C4) | `cap.or`, **only after R3c** (step R3e.5) | the `Grant` table, which is still C |

**Stays in `runtime/core/` C until R3c or R3f, reached from Orin through `hook`:** the grant table and policy (`grant_new/ref/copy_into`,
`orin_cap_revoke`), the file table (`files_at_exit`), the per-task net buffer of C4 (`t_netbuf`), the allocation-site census tables, `orin_init`,
`orin_flush`. They are R3c shells; R3e must not port half of them. `orin_rt_heap_exit` reaches them through new hooks (2.2).

**Stays in L0 (`runtime/platform`, C, no change in R3e):**

- thread create/join/exit/id with the handle registry (`g_reg`, generation-checked), `pthread_exit` and the release of monitors held by an exiting
  thread (this is the trap unwinding, 6.3), the thread-local `t_tid` and the atomic `g_next_tid`;
- monitors: mutex, two condition variables, integer words, the atomic `owner`, `wait_until` on `CLOCK_MONOTONIC`; the runtime lock `g_rt` and the stdout
  lock `g_io`;
- everything that needs libc or the kernel: `getenv`, `cpu_count`, `write_line`, `exit`, `alloc/free/realloc/mem_*`, and (after #187) the wake sources
  (`eventfd`/pipe, `poll`, the thread-local binding).

**The exact L0 primitive set R3e calls** (20 functions, all existing; each is one case of the `plat` operation, 2.1; signatures as in `orin_platform.h`):

| group | functions |
|---|---|
| threads (4) | `thread_create(entry, arg)`, `thread_join(h, &arg)`, `thread_exit()`, `thread_id()` |
| monitors (10) | `monitor_new/free/lock/unlock/wait/wait_until/notify/get/set/grow` |
| process (6) | `runtime_lock`, `runtime_unlock`, `cpu_count`, `getenv`, `write_line(fd, buf, n)`, `exit(code)` |

No atomic, no TLS and no signal primitive is added: Orin code takes shared state only under the runtime lock or a monitor, and the thread-local state
is the heap block (2.4). **Budget (ADR-0054): R3e adds 0 code lines to L0.** L0 was 1,036 of 1,400 on the base of this design (measured with the `tools/verify_platform.sh`
method) and is 1,167 on the merged tree (#187, its Addendum D: +127, and later work), so 233 stay reserved for the scheduler and the Windows backend. The variant of Q3 (setjmp/longjmp
instead of `pthread_exit`) would cost about +10 lines. What leaves the trusted C is about 580 lines of `orin_runtime.c` (the forwarders and the whole
transfer and task code), none of it L0, so the TCB figure in tcb.md falls by that much at R3e.6. Every L0 function R3e calls already has its contract
and its executable test; no L0 test is added.

### 2. Core operations and hooks

#### 2.1 Three new operations (`BCore(k)`, `compiler/hir/coreops.or`, 28..30; E0301 outside `$rt/`, negative tests as in R3d.0)

| new op | C / LLVM | semantics and safety rule |
|---|---|---|
| `plat(k, a, b, c)` -> usize (28) | a direct call of `orin_platform_<name>(a, b, c)` / `call @orin_platform_<name>` | `k` indexes a **closed table** of the 20 functions above (numbered in the order of the table: threads 0..3, monitors 4..13, process 14..19; `platOpName` in `hir/coreops.or`, the names `PL_*` in `runtime/core/plat.or`) and must be a literal or a named constant (a non-literal or unknown `k` is the compile error E0404, so there is no computed call). Arguments are words, pointers are addresses (`thread_join`'s `void **` is the address of a word of the heap block). Void functions give 0, the others their `int` / `int64_t` result as usize. **Not pure**, may write any memory, may not return (`thread_exit`, `exit`). The table is the "calls to L0 functions by declaration" of the core dialect list above; it replaces the L0-shaped hooks of R3d.5 (`HK_LOCK`, `HK_UNLOCK`, `HK_GETENV`, `HK_WRITE_LINE`) |
| `fnAddr(k)` -> usize (29) | `(uint64_t)(uintptr_t)&orin_rt_task_main` / `ptrtoint ptr @orin_rt_task_main` | the address of the C-ABI wrapper (the `RtWrap` machinery of `mir/rt.or`) of the entry `k` (an entry number of `rt.or`), a literal; only entries of type `void(void *)` qualify (`fnAddrEntries` in `hir/coreops.or`, checked against the wrapper table by `rtFnAddrOk`: the probe target of `std:coreprobe` in R3e.0, the task entry joins in R3e.4). Needed because `thread_create` takes a C function pointer and a core module has no function-pointer type. Pure |
| `sharedBase()` -> usize (30) | `extern uint64_t orin_shared[128]` / `@orin_shared = global [128 x i64]` | the address of the process-wide zero-initialised block of 128 words (1,024 bytes), the shared counterpart of `heapBase()`. Layout in 2.3. Executables only, like `heapBase`. Pure (an address) |

**Considered and not needed:** an atomic or compare-and-swap operation (all cross-thread state is under the runtime lock or a monitor; the one CAS
table of the runtime, `char_string` in C, belongs to R3f); an indirect-call operation (the task entry calls its closure as an Orin value,
`const b: TaskBox = take(tok); b.f();`, the way `std:task` builds the box with `putBox`); a function-address operation for arbitrary functions.

#### 2.2 Hooks (`orin_core_hook`, the `HK_*` constants of `runtime/core/heap.or`: C services that are not L0)

Added: `HK_REVOKE_GRANTS` (12, revoke every live grant of this task: the loop of `orin_rt_heap_exit`), `HK_CLOSE_FILES` (13, `files_at_exit`),
`HK_FREE_NETBUF` (14, C4's `t_netbuf`), `HK_SITE_FOLD` (15, `site_fold`, census builds only). `HK_FOLD_STATS` and `HK_FOLD_LIVE` stay (the totals live in
C until R3f). The four L0-shaped hooks are removed once `plat` replaces them (R3e.1). Each remaining hook disappears with the shell it serves (R3c, R3f).

#### 2.3 The shared block `orin_shared` (word offsets pinned by `_Static_assert`s on the `OrinShared` struct in `orin_runtime.h`; the named constants of the users go with them)

| words | content (read and written only between `plat(RUNTIME_LOCK)` and `plat(RUNTIME_UNLOCK)`) |
|---:|---|
| 0..3 | transfer slot table: pointer, `n`, `cap`, free head (`g_tr*`) |
| 4..7 | grant flight table: pointer, `n`, `cap`, free head (`g_gf*`, step R3e.5) |
| 8..63 | reserved |
| 64..127 | line buffer of the process trap (512 bytes; used only by the main thread, which is about to exit, so it needs no lock; the trap path allocates nothing) |

`orin_shared` is defined in `orin_runtime.c` like `orin_heap` and listed in `bootstrap/seed/runtime/core-only-symbols.txt`; R3f makes the backends emit it.

#### 2.4 Per-task state in the heap block (the reserved bytes 336..503 of Addendum A section 5; the block size does not change; named in `runtime/core/heap.or` as `H_TASK` .. `H_SCRATCH`, pinned by `_Static_assert`s in `orin_runtime.h`)

| offset | field | was |
|---:|---|---|
| 336 | `task`: address of the `RtTask` record, 0 on a thread that is not a task | `t_task` |
| 344 | `joined`: record of the task joined last by this thread (`taskMessage` reads its message; freed at the next join and at heap exit) | `t_joined_msg[481]` |
| 352 / 360 | `grants`, `files`: pointers reserved for R3c | `g_grants`, `g_files` |
| 368 | `netbuf` | `t_netbuf` (C4) |
| 376 | scratch word (the out-parameter of `thread_join`) | |

`RtTask` is 512 bytes of raw memory from `memAlloc` (never the small-block cache: the joiner frees it on another thread): `tok`@0, `trapped`@8,
`done_mon`@16, message@24 (480 bytes and a NUL).

### 3. How `BTask(k)` lowers

`BTask(k)` stays one builtin through HIR and MIR: names, result kinds, opener/closer rules (`taskOpRet/OpensFrom/Adopts/Moves`), the MIR verifier
and OSIG do not change. Only the two backends change, exactly as `l1Builtin` did for `BArrSlice` in R3d.4: `compiler/mir/rt.or` gets the entries
30.. and `l1Task(k): Option<usize>`; a backend emits a call of the Orin function when the program has the entry (`rtIds`), else the old call
`taskOpC(k)`. Reference operands and results are words (`transitPut` takes the box address, `transitTake` returns the owned object address; no
count changes at the call). `opt/prune.or` keeps the entry that a live `BTask(k)` implies (`rtImplied`). The C name column is the fallback of the
legacy world and the seed (section 4). `taskops.or` gains a third table (`entry`) beside `names()` and `cnames()`.

| k | op | C name (fallback, test wrapper) | `$rt` entry | step |
|---|---|---|---|---|
| 0..8, 23, 27 | monNew .. monGrow, monNotifyOne, monWaitUntil | `orin_mon_*` | `sync.monNew` .. `sync.monWaitUntil` (`@Inline`) | R3e.1 |
| 24 | arrayWithCapacity | `orin_array_new` | the existing `RT_ARRAY_NEW` (a call of its wrapper today) | R3e.1 |
| 9, 10, 11, 16 | transitPut, transitTake, transitDrop, transferCount | `orin_rt_transfer_*` | `transfer.put/take/drop/count` | R3e.2 |
| 25, 26 | lendPut, parThreads | `orin_rt_lend`, `orin_rt_par_threads` | `lend.put`, `task.parThreads` | R3e.3 |
| 12, 13, 14, 28, 15 | taskSpawn, taskJoin, taskMessage, taskWatch, taskTrap | `orin_rt_task_*`, `orin_rt_trap_str` | `task.spawn/join/message/watch`, `task.trapStr` | R3e.4 |
| 17..22, 29, 30 | grantClone, grantMove, grantAdopt* (Fs, Process, Stdio, Clock, Net, Stream) | `orin_cap_*` | `cap.clone/move/adopt` | R3e.5 (needs R3c) |
| 31..36 | wakeOpen .. wakeCheck (#187) | `orin_platform_wake_*` | none: they stay direct L0 calls | - |

New entries (numbers from 30 in `rtNames`): the 11 `sync` ops, `transfer.put/take/drop/count`, `lend.put`, `task.spawn/join/message/watch/trapStr/
parThreads`, `task.main` (the thread entry, kept alive by a live `taskSpawn`), `task.trap` (the C name `orin_trap`: wrapper always emitted, called by
the C shells and by every emitted trap) and `task.heapRetire` (the C name `orin_rt_heap_exit`, called by `task.main` and `task.trap`).
**Wrappers for C callers.** After R3e the only C that calls these names are the unit tests (`runtime/core/tests/task_test.c`, `runtime_test.c`, which
link the stub of `tools/rt_stub.sh`) and, until R3c, the C shells that trap. `rtAlways` must not pull the whole task code into every program:
only `orin_trap` and `task.main` (when spawn is live) are always wrapped; the test wrappers (`orin_rt_*`, `orin_mon_*`) are emitted only when the stub
is compiled with a new driver flag `--rt-wrappers`, set by `tools/rt_stub.sh` (Q4).

### 4. Seed and legacy world

- **The frozen snapshot keeps the C versions.** `bootstrap/seed/runtime/orin_runtime.c` holds the whole C tasks section as of 4d5eeee (plus the
  additive exceptions of its README). Stage 0 and stage 1 and the `--c-builtins` programs call the C names, so R3e touches the snapshot only for
  the additive exceptions below. Each R3e step deletes its C from the **live** runtime at once (as R3d did); the snapshot is the oracle.
- **What #191 changed.** `tools/update_seed.sh` now builds the seed with `--c-builtins` ("stage 0 and stage 1 link the frozen runtime snapshot").
  Then the R3d.7 refresh does not make the seed independent of the C task code: a seed built that way calls `orin_rt_*`, `orin_mon_*` and `orin_cap_*` by
  their C names. The snapshot (with the task section) must survive until a seed is produced **without** `--c-builtins` by a compiler that has R3e
  (step R3e.7), and, for the legacy world of the differential, until R3f. This corrects Addendum A section 4 ("(2) R3e removes `orin_rt_*`"):
  R3e removes them from the *live* runtime only.
- **The platform file is shared between the worlds** (`tools/runtime-sources.txt`: both list `runtime/platform/orin_platform.c`). R3e does not change
  L0, so this holds; a later L0 change must keep every function the snapshot calls.
- **Additive edits the snapshot needs from the stack** (the stack's duty, listed so it is not forgotten). #175 adds `orin_cap_adopt_net/stream`, the
  `GK_NET` branch of `orin_cap_clone` and the thread-local net buffer to the live runtime but touches no snapshot file on its branch; it was cut
  before `tools/check_seed_runtime.sh` existed, which fails until they are copied verbatim. #184 changes the live `orin_rt_transfer_put` to accept a
  box of 0 slots (void task results); `tests/next/run/task_void_*` under `--c-builtins` needs the same edit in the snapshot. R3e.2 ports the post-#184
  behaviour (`nslots <= 1`).
- **`tools/check_seed_runtime.sh`** compares the external symbols of the C files of each world. R3e deletes live symbols (allowed) and adds exactly
  one, `orin_shared`, which goes into `core-only-symbols.txt` (`orin_heap`, `orin_oom`, `orin_core_hook` are there). Wrappers are emitted code, not
  runtime symbols, so they never appear. Any other new live C symbol is a design violation.
- **Oracle.** `tools/differential.sh --mode builtins` (new world against legacy world) on every task test: stdout, exit status and `ORIN_STATS`
  (`tasks_spawned`, `transfer_moves`, `transfer_copies`, `live_objs_at_exit`) must be identical.

### 5. Steps, gates and benchmarks

Gate for every step (Addendum A section 5, plus the task suites): `stage2.c == stage3.c` for both backends and `tools/llvm_fixpoint.sh`; conformance and
`differential.sh` (all modes, `--sanitize`, `--c-builtins`); `tools/test_concurrency.sh` in full (task_test.c plain, **TSan**, ASan + UBSan; every
`tests/concurrency/*.or` plain, TSan, ASan + UBSan, no live object at exit); `tools/test_parallel.sh`; `tools/test_net.sh` (after #175);
`tools/verify_platform.sh` (size unchanged, platform tests under TSan); `tools/check_seed_runtime.sh`; the `ORIN_STATS=1` counters of every `bench/`
program identical.

**Budget rule.** Per step at most +1 % executed instructions on the LLVM backend and below +2 % on the C backend, on every benchmark that
`tools/bench.py` counts (valgrind). R3e touches code that a program without tasks never runs, so the expected change there is 0.00 % (unused entries
are pruned). `bench/tasks`, `bench/parallel_collatz` and `bench/streams_parallel` cannot be counted (valgrind serialises threads; `bench/tasks/
instructions.skip` says so). They get **user-mode instructions from `perf stat -e instructions:u` where the host has the counter** (same thresholds),
else the median of 9 interleaved runs of wall time: at most +5 % for the channel parts (ping-pong 3.7 us per message and throughput 1.5 us per
message are futex-bound) and +10 % for spawn/join (83 us, thread creation dominates). Reference numbers: docs/concurrency.md "Measurements".

| step | content (one PR each) | extra tests and benchmarks | risk |
|---|---|---|---|
| R3e.0 | `plat`, `fnAddr`, `sharedBase` in `coreops.or` and both backends; `orin_shared` (C definition, core-only list); heap block offsets 336..376 with `_Static_assert`s; `rt.or` entries 30.., `l1Task`, prune roots, `--rt-wrappers`; E0301 negative tests (user file, `$std` file importing the ops, non-literal `k`, unknown `k`); a probe function per op in `coreprobe.or`. No emitted-code change for normal programs | self-compile output byte-identical; `tests/run/core_ops.or` extended; the lint of 6.2 over the L0 declarations; the `clang -fsanitize=thread x.ll` experiment of 6.1 | low. **Done**: the three ops are in both backends (`plat` is a direct call of `orin_platform_<name>`, `fnAddr` the address of the `RtWrap` wrapper, `sharedBase` `&orin_shared`); E0301 test for the user file and the `$std` file, E0404 for a non-literal and an unknown `k` (`check_body_test`); `orin_shared` is in `core-only-symbols.txt` (the only edit under `bootstrap/seed/`, approved); `--rt-wrappers` is carried as a marker in `MProgram.inlineFns` (no signature change) and `rt_stub.sh` uses it; `check_platform_boundary.sh` runs the lint of 6.2. **Measured**: emitted C and LLVM of 446 test programs, of the compiler and of the 22 benchmark mains are byte-identical to the base (0.00% executed instructions on every benchmark, C and LLVM); `bootstrap` stage2 == stage3; conformance 1063 passed on C, LLVM and `--sanitize`; differential builtins/llvm 0 differences; `llvm_fixpoint` OK. The TSan experiment: `clang -fsanitize=thread` on the emitted `.ll` adds only `__tsan_func_entry/exit` calls (33 in `core_ops`) and no read/write instrumentation; the TSan runtime library is not installed on the build host, so the binary could not be linked and run (recorded, not built, as decided in section 8 item 8). The `k` numbering differs from the first draft: see the notes in 2.1, 2.3, 2.4 |
| R3e.1 | `sync.or` (11 monitor ops); k=24 to `RT_ARRAY_NEW`; the four L0-shaped hooks replaced by `plat` | `bench/tasks` (all three parts), `timed_waits.or`, `select`, `stress_*`; the monitor checks of task_test.c through test wrappers; expect slightly fewer instructions (the forwarder call is gone) | low. **Done**: `runtime/core/sync.or` holds the 11 monitor operations (`@Inline`; the error codes map as before, `monFail` treats any non-EINVAL error of `monLock` as the deadlock error because EDEADLK differs between Linux and macOS); k=24 maps to `RT_ARRAY_NEW` through `l1Task`; `HK_GETENV/LOCK/UNLOCK/WRITE_LINE` and their cases in `orin_core_hook` are gone, `stats.or` calls `plat`. The C `orin_mon_*` stay until R3e.6 (`l1Task` falls back to the C name for an absent entry). **Measured** (`bench.py --instructions`, valgrind, against the base): every benchmark within +0.02% on C and LLVM, self-compile +0.34% (30,525,444,792 to 30,630,617,645); no change for programs that do not use tasks beyond the `arrayWithCapacity` call now reaching `RT_ARRAY_NEW`. `bench/tasks` wall time, median of 9 interleaved runs, base versus new, C / LLVM: spawn+join +3.9% / +3.1%, ping-pong -0.7% / -2.2%, throughput +3.4% / -6.2% (limits +10% / +5% / +5%; no `perf` on the host). Not done: the monitor checks of `task_test.c` through test wrappers (`rtTestWraps()` is empty; they move with R3e.6) |
| R3e.2 | `transfer.or`: slot table, tokens, `graph_unique`, deep copy, move-or-copy, counters, box-once path, void box (#184) | `move_counts.or`, `stress_messages.or`, `par_pipelines`, task_test.c (200,000-deep chain, immortals, pinned objects), copying 1,000,000 ints and 100,000 strings as in the Measurements section, `task_void_*`; `ORIN_STATS` move/copy counts identical | medium: iterative walks over raw memory, `rc` sign tests. **Done**: `runtime/core/transfer.or` holds `put`, `take`, `drop`, `count` (and `publish`, the pin helpers the lend of R3e.3 shares); the walks (`graphUnique`, `deepCopy`) are loops over `memAlloc` work stacks, a value array and the scalar slots are copied as words (`memCopy`), the void box (`nslots <= 1`, post-#184) and the box-once path are ported as in C. The slot table is in `orin_shared` words 0..3 with a 32-byte slot (box, gen, next, pins, npins; a lend is a slot with `pins` != 0, so the former `lend` field is gone) and the live C functions (`tr_publish`, `tr_claim_kind`, the lend, `task_main`) were changed to use the same table, because the C task code and `orin_rt_lend` still run beside the Orin `put/take/drop`; the table grows with the allocation made before the lock is taken, so no trap happens with the lock held. `drop` ends a lend as well (the restore loop is in `transfer.or`, not in `lend.or`: the lend token is a slot of this table and `drop` is the one entry for both). Test wrappers: `rtTestWraps` has `orin_t_transfer_put/take/drop/count` (a distinct prefix, because the C names stay defined until R3e.6) and `task_test.c` built with `-DORIN_TRANSFER_IN_ORIN` runs all its checks against the Orin functions (plain, TSan, ASan + UBSan in `test_concurrency.sh`), next to the unchanged run against the C ones (184 checks each). New test `tests/concurrency/transfer_deep.or` (200,000-link chains moved and copied, a task capturing and returning one, 1,000,000 ints and 100,000 strings copied, literals). **Measured**: stage2 == stage3 and `llvm_fixpoint` hold; conformance 1063 passed on C, LLVM and `--sanitize`; `differential.sh` builtins 459 programs, llvm 462 and opt 462 with 0 differences (the stats of each task program identical to the legacy world; the move/copy counts of programs that race on thread timing, like `par_lent`, vary from run to run on the base too, 34..48 moves of 132); `test_concurrency.sh` (task_test.c 184 checks against the C and against the Orin transfer, plain, TSan, ASan + UBSan; every `tests/concurrency/*.or` in the three builds) and `test_parallel.sh` (ORIN_THREADS 1..8, TSan at 2, 4, 8, 108 runs) pass. `bench.py --instructions` against the base 44becfbe, C / LLVM: every benchmark within +0.005% (22 programs; the task benchmarks cannot be counted), self-compile +0.09% (30,927,018,005 to 30,955,685,257, the larger embedded runtime). Wall time, median of 9 interleaved runs, base versus new, C / LLVM (the numbers of R3e.2 and R3e.3 together): `bench/tasks` spawn+join -1.2% / -6.3%, ping-pong -1.2% / -0.4%, throughput -4.0% / -0.8%; `parallel_collatz` (4 workers) -0.5% / +3.9%; `streams_parallel` parheavy -2.9% / -9.1%, par (49 ms, noise) +5.0% / +6.8%. The self-compile adds only the new functions |
| R3e.3 | `lend.or`, `parThreads` | `tools/test_parallel.sh` (ORIN_THREADS 1..8, TSan at 2, 4, 8), `bench/parallel_collatz`, `bench/streams_parallel` | medium: pin bits, owner thread id in 30 bits. **Done**: `runtime/core/lend.or` holds `put` (the iterative pin walk: every live object with a count below 2^32 gets `PIN | owner << 32 | count`; nothing is pinned when the owner's thread id does not fit in 30 bits; the pins buffer and the retained box go into the transfer slot through `publish(box, pins, n)` in one lock, no window in which the slot is not yet a lend) and `runtime/core/task.or` holds `parThreads` (`ORIN_THREADS` 1..1024 else `cpu_count`, through `plat`); the end of a lend stays in `transfer.drop` (see R3e.2), so `lend.or` is the pin walk only. The test wrappers `orin_t_lend` and `orin_t_par_threads` let `task_test.c` (`-DORIN_TRANSFER_IN_ORIN`) run its lend, pinned-object and thread-count checks against the Orin code. **Measured**: measured together with R3e.2 (one tree; the R3e.2 snapshot was validated alone before R3e.3 was added: bootstrap fixpoint, llvm_fixpoint, conformance on C, LLVM and `--sanitize`, compiler contracts, differential builtins): see the R3e.2 row for the full gate, benchmark and wall-time numbers. `par_lent` and `par_pipelines` run under TSan at ORIN_THREADS 2, 4 and 8 and under ASan + UBSan with no live object at exit |
| R3e.4 | `task.or`: `RtTask`, spawn/main/join/message/watch, heap retire, `orin_trap` and `trapStr`, thread exit | `panic_chain`, `panic_many`, `timed_join_panic`, the 23,254-task stress, a new `trap_deep.or` (trap at depth in generated frames and in `$rt` frames, 10,000 tasks), `bench/tasks` spawn/join, a trap on the main thread (exit 101, stderr text identical), `tools/test_server_campaign.sh` (#189) | **highest**: trap unwinding, retire order, TSan |
| R3e.5 | `cap.or`: clone/move/adopt, the flight table, `adopt_net/stream`, net buffer release. **Only when R3c has moved the grant table**; otherwise skipped, these stay C until R3c | `net_task_move.or`, `tools/test_net.sh` under TSan, the grant task tests | medium |
| R3e.6 | delete the dead C from the live runtime (the tasks section, `t_task`, `g_tr*`, `g_gf*`, the four hooks); docs: concurrency.md porting table marked done, spec 19, progress, tcb.md | `verify_platform.sh`, `check_platform_boundary.sh`, every user of `tools/rt_stub.sh` | low |
| R3e.7 | seed refresh without `--c-builtins` by an R3e compiler (`tools/update_seed.sh`): stage 0 and 1 no longer call C task names; the snapshot stays for the legacy world until R3f | bootstrap from the new seed; selfcompile | low |

R3e.0 and R3e.1 can ship together if the result stays inside the budget; R3e.2 and R3e.3 are independent of each other. Every step reverts alone:
`l1Task` falls back to the C name for an absent entry, and the step's C stays in the live runtime until R3e.6.

### 6. Risks

1. **TSan sees Orin code through the C backend only.** `tools/test_concurrency.sh` compiles the program with the C backend and `-fsanitize=thread`, so
   the emitted `$rt` functions are ordinary instrumented C: the transfer code is checked as code, as the C runtime is today. The LLVM backend's `.ll` is
   probably not instrumented *(inference: the instrumentation pass is driven by a per-function attribute that clang's front end adds and the LLVM
   backend does not emit)*; that is already true of all emitted code, so R3e does not lower the evidence, but R3e.0 must run one
   `clang -fsanitize=thread x.ll` experiment and record the result. Happens-before edges come only from L0 calls (mutex, condvar, `pthread_create/join`
   are intercepted); `plat` must never become something TSan cannot see (no inline atomics, no `futex` calls from `$rt`). No TSan suppressions.
2. **Memory ordering.** Shared Orin data is (a) the transfer and flight tables, touched only between `runtime_lock` and `runtime_unlock`; (b) `RtTask`,
   written by the spawner before `thread_create` and by the task before it ends, read by the joiner after `thread_join`; (c) lent objects, pinned by
   the owner before the workers start and restored after they are joined; (d) monitor words, under the monitor. All four get their ordering from
   pthread operations in L0, which are opaque external calls. Requirements on the toolchain: a core `load`/`store` is never moved across a `plat`
   call (the conservative effects of `coreops.or`: loads read mutable memory, stores and `plat` write it), and the L0 declarations in the LLVM
   preamble and the C header never gain `readnone`/`readonly`/`argmemonly`/`const`/`pure` or `static inline` (a lint in R3e.0 over
   `backends/llvm/runtime.or` and `orin_platform.h`; with LTO this would otherwise be silently wrong). No `__atomic` is used in R3e, so there is no
   weaker-than-sequentially-consistent case to reason about. The "box once" shortcut of `transfer_put` relies on the sender's release being ordered
   before the receiver's take by a monitor or a thread start; both are L0 calls, so the argument is unchanged and is restated in the Orin source.
3. **Trap unwinding across Orin frames.** A task trap ends the task with `pthread_exit` (forced unwinding in glibc), which must walk every frame
   between the trap and the thread entry, including generated code and now `$rt` frames. Today the same walk crosses generated C or LLVM frames, so the
   unwind tables of both backends already work for `panic_chain` and `panic_many`; R3e adds frames of the same kind. New hazards: (a) an optimisation
   or attribute that lets a caller of `task.trap` drop its unwind info (`nounwind`/`noreturn` on the LLVM declaration of the trap entry); (b)
   `heapRetire` runs on the unwinding thread before `thread_exit` and must not itself trap (it allocates nothing; a failure inside it is
   `plat(EXIT, 101)`); (c) the runtime lock is never held across a possible trap (the C code unlocks before `orin_trap` everywhere; the Orin code keeps
   the rule and `trap_deep.or` pins it); (d) macOS arm64 uses compact unwind and is not run in CI (docs/windows.md, the release dry run): the probe must
   run there once before R3e.4 merges. Fallback if a platform fails: Q3.
4. **The trap path must not allocate or depend on the object model.** It runs when memory is exhausted (`orin_oom` -> `orin_trap`), from `$rt` code in
   the middle of an allocation, and on the main thread for every checked failure of every program. Preallocated buffers only (2.3, 2.4), no strings, no
   `rtCold` call.
5. **Cost from inlining** (`@Inline` of 11 monitor operations into `std:task`: code size) and from `inttoptr` aliasing around transfer: the transfer
   functions stay out of line; `bench/tasks` and `streams_parallel` decide (Addendum A section 3, "Costs to watch").
6. **Conflicts with the concurrency stack.** `taskops.or` is edited by #175 (29, 30), #187 (31..36, count 37) and by every R3e step; `orin_runtime.c`
   by #175, #184 and #191. R3e is written against main after they merge (section 9), never stacked on them.

### 7. What the open PRs change for R3e

| PR (head branch) | Touches the task interface | Consequence |
|---|---|---|
| #175 (`claude/project-thread-5wtl8u-c4`) | `taskops.or` 29, 30; `orin_cap_clone` accepts `GK_NET`, `orin_cap_move` rejects Host and Listener, `orin_cap_adopt_net/stream`; thread-local `t_netbuf` freed by `orin_rt_heap_exit`; `task_test.c` +145 lines; LLVM `declares` | the `cap` step grows by two adopters; `heapRetire` frees the net buffer through `HK_FREE_NETBUF`; the snapshot needs the same additive edits (section 4) |
| #187 (`...-c3`, base c4) | L0 wake sources (+127 lines, 1,163 in all), `taskops.or` 31..36 as direct platform calls, `std:task` binds the scope token in `spawn`; no runtime C change | R3e leaves 31..36 alone; the L0 binding is thread-local and dies with the thread, so `task.main` needs no code for it; `taskOpCount` is 37 |
| #189 (`...-c5`, base c3) | tests, campaign scripts, CI; no runtime change | `tools/test_server_campaign.sh` joins the gate of R3e.4 and R3e.5 (a server under TSan is the best task-trap and cancel stress there is) |
| #184 (`...-gm`) | `orin_rt_transfer_put` accepts a box of 0 slots (void task results); no other runtime edit | R3e.2 ports `nslots <= 1`; `tests/next/run/task_void_*` join the transfer gate |
| #191 (`claude/adr0048-fs`) | seed refresh built with `--c-builtins`; snapshot edited for `orin_fs_exists` / `listDir`; `update_seed.sh` | changes the seed story of section 4: R3d.7 and R3e.7 are both needed before the snapshot is unnecessary for bootstrap |

### 8. Open questions for the project owner

Decided 2026-10-17: every recommendation below is taken (the owner delegated the decision; see the status line). Each is still a separate
commit of the step it affects, so it can be reverted alone.

1. **Reaching L0 from `$rt`.** Recommend the `plat(k, ...)` operation with a closed table (20 functions) over more `hook` numbers: a monitor operation is
   on the channel hot path (`bench/tasks` 1.5 us per message) and a hook adds a call and a `switch` in C that R3f has to delete again, while `plat` is
   the direct call that the core dialect list of this ADR promised. Hooks stay for the C-only services (grants, files, census) and die with them.
2. **Shared process state.** Recommend the `sharedBase()` operation (no cost, like `heapBase`) over a hook that returns the address of a C static
   (as `HK_FOLD_STATS` does). Both work; the operation needs no C file in R3f.
3. **How a task thread ends on a trap.** Recommend keeping `pthread_exit` (no L0 change, behaviour identical) and gating R3e.4 on the `trap_deep.or`
   probe, including one macOS arm64 run. If a platform fails it, add to L0 `task_run(entry, arg)` and `task_abort()` (setjmp in the thread frame,
   longjmp to it, then the same monitor release; about +10 code lines with a contract and an executable test) and re-budget under ADR-0054.
4. **Test wrappers.** Recommend `--rt-wrappers` (test-only C names, stub only) and moving the C unit tests to Orin `@Test`s in R3f, over wrapping every
   task entry in every program (`rtAlways` would keep about 15 functions alive in every binary).
5. **R3c versus R3e.5.** Recommend R3e.0..R3e.4 and R3e.6 without waiting for R3c, and R3e.5 (grants) only after R3c has put the grant and file tables
   in Orin, so that `cap.or` reads them instead of hooking. If R3c slips, R3e.5 leaves the definition of "R3e done" and is tracked with R3c; the
   1.0 roadmap (D8 gates on R3d/R3e merged) then reads "R3e.0-R3e.4".
6. **C2 (trap-safe structured cleanup).** The roadmap asks for it "in Orin inside R3e". Recommend after R3e.6, as its own change on `task.or`: R3e is a
   1:1 port whose oracle is identical counters and output against the legacy world, which a behaviour change (cancel and join the descendants of a
   trapping parent) would destroy.
7. **Measuring the task benchmarks.** Recommend `perf stat -e instructions:u` for the three task benchmarks with the thresholds of section 5, wall-time
   medians as the fallback and no new valgrind mode. Confirm that the budget rule (+1 % LLVM, below +2 % C per step) applies to them.
8. **LLVM and ThreadSanitizer.** Recommend only recording the R3e.0 experiment and not building an instrumented LLVM mode in R3e (it needs
   `sanitize_thread` attributes in the backend); decide that separately.

### 9. Ordering

R3e code starts only after (1) the concurrency PR stack #175, #187 and #189 and the independent #184, and (2) #191, are merged to main, and (3) after
R3d.7 (the seed refresh). R3e rewrites the lines those changes edit (`taskops.or`, the C tasks section, the snapshot, `update_seed.sh`), and the
tables of this addendum must be re-derived from the merged tree before R3e.0 (`taskOpCount` 37, L0 at 1,167 lines; done, see the status). R3d.6 (the C preamble in place of
the header inlines) should be in too, since both edit `backends/c/function.or` *(recommendation, not a dependency)*. R3c precedes R3e.5 only. Until
then this addendum is the only R3e change: nothing in `runtime/`, `compiler/` or `tools/` moves.
