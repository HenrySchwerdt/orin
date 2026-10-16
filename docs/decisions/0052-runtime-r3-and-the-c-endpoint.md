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
  `orin_runtime.h`/`orin_runtime_mir.h`; the header copy stays for the C shells until they are gone.
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
| R3d.3 | on the shared block: (a) `struct_new/array_new/variant1` + free lists, (b) `destroy`, `make_unique_slow`, (c) small-block cache, string allocation, `array_push_grow` | **bintrees** (destroy 62, struct_new 42 per node), sortedmap, mapfreq, qsort_func; (c) appends, strings, wordfreq, bytesstr, http_parse, html, url, selfcompile | **highest**: hot path, checked arithmetic, aliasing, `-O1` inlining; a/b/c revert alone |
| R3d.4 | strings and arrays (R3b leftovers): `str_concat/append/prepend/append_*`, `array_slice/concat/extend`, `bytes_to_string`, `string_to_bytes` | appends, mutres, strings, bytesstr, qsort_inplace, qsort_func, streams, url | medium: per-element retain by `is_ref` in a raw loop; appends/mutres are the in-place canaries |
| R3d.5 | stats, `stats_report`, census prefix word, `live_count` | counters and `tools/alloc_census.py` output identical; `tools/test_resources.sh` | low |
| R3d.6 | C preamble replaces the header inlines for generated code | all (C output changes textually) | medium |
| R3d.7 | seed refresh | bootstrap from the new seed; selfcompile | low |

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
