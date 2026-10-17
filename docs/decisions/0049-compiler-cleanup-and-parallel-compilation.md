# ADR-0049: Compiler cleanup and parallel compilation

Status: accepted (2026-10-16). Plan only; implementation starts after ADR-0047's layout move and the ADR-0038 escape-analysis work are in `main`. The sharing question of section 2.4 is decided in the [addendum](#addendum-2026-10-16-the-sharing-decision-row-13): the program is lent read-only to the workers (option B), not summarised per worker (option A).

Evidence: [docs/audits/2026-10-16-compiler.md](../audits/2026-10-16-compiler.md) (file:line references, profile, measurements). Item ids A1..A15 and P1..P12 refer to that audit.

## Motivation

The compiler should read like the Orin we want users to write, and it should use the cores it runs on. The audit found:

- The compiler is already mostly modern (about 1,700 `match`, 700 `Option`, 440 `Result`, 1,500 contract clauses). Old style is concentrated in a few files the earlier rewrite (`docs/rewrite.md`) did not reach: `check/index.or`, `vc/*`, `mcp/*`, `analysis/osig*.or`, `check/classes.or`.
- It uses none of `std:collections`, `std:seq`, `std:task`, OX, generic functions or generic classes, and never calls the prelude `sort` while it contains seven hand-written sorts. About 45 helper functions exist in two to six copies (`isLocal` x6, `isDigit` x5, `hexDigit` x5).
- `orin compile compiler/main.or` takes 3.1 to 3.8 s; the MIR verifier and optimiser are 70 to 90 % of it, and both already work per function. A full bootstrap is dominated by `cc` on the 11.4 MB generated C (63 s per stage at `-O1`), not by the Orin compiler.
- The compiler has no global mutable state, so per-function phases are parallel-ready at the algorithm level. The blocker is sharing: a task gets a deep copy of every captured value (measured: about 0.14 s per 0.9 M objects), so handing the whole MIR program to each worker costs as much as the parallel part saves.

## Decision

### 1. Cleanup rules for compiler code

1. Compiler code uses the language as the docs teach it: tagged unions instead of magic ints, `Option<usize>` instead of `-1`, classes or records instead of parallel arrays, `Map` instead of hand-made hash tables, `xs.sort(cmp)` instead of hand sorts, template literals for generated text where they do not change output.
2. Shared helpers live once, in `compiler/util/` (strings and characters, process, text and JSON escaping). Phase-specific shared helpers live in the phase (`hir/walk.or`, `mir/operand.or`, `backends/common`).
3. HIR traversals use one generic fold (`foldExpr<S>(e, s, f)` plus `mapExpr`), with state threaded explicitly because closures cannot mutate captures.
4. Interfaces only where there are really two implementations and never on hot paths (interfaces are boxed; `docs/rewrite.md` records the cost). Hot per-instruction loops stay loops (rewrite rule 7).
5. Not cleanup targets: the packed verifier state, the struct-of-arrays tables in `opt/unbox.or` and `verify/verify.or`, and sorts or predicates that carry proved contracts unless the contract moves to a wrapper.
6. Every cleanup PR is behaviour-neutral and proves it: bootstrap fixed point, LLVM fixed point, a zero diff of the generated C of `compiler/main.or` and the test corpus between the pre-PR and post-PR compiler (`tools/differential.sh compilers`), the LSP/MCP/OSIG/fmt/CLI suites, and `tools/test_compiler_contracts.sh` where contracts change. A cleanup PR never touches the library (`std/`, `stdlib/`, `array/`, later `library/`), because the embedded prelude is generated from it; library changes follow ADR-0048.

### 2. Parallel compilation

1. Parallel phases are built on `std:task` `forkJoin` over function or file indices, with results merged in index order. With `parallelism() == 1` (`ORIN_THREADS=1`, Windows today) the code path is exactly the sequential one.
2. Output must be identical for every thread count. The gate is an `ORIN_THREADS=1..8` equality matrix over the compiler and the test corpus, in addition to the bootstrap fixed point.
3. Order of work, by gain per risk:
   - **No sharing needed** (process-level parallelism): parallel `orin test` (one process per test already), parallel z3 in `orin verify --contracts` (per-function SMT file names instead of the program-wide `Rt.qn` counter), `orin fmt` and workspace commands per file or package.
   - **Split generated C into N translation units** (P1) so `cc` runs in parallel in bootstrap, `orin test` and CI. The single-file output stays the default (`-o out.c`); a `--split N` option enables the new layout so goldens stay valid. Expected: about 63 s to about 20 s per bootstrap stage on 4 cores.
   - **LSP/MCP analysis cache** keyed by `(entry, revision)` before any threads; then per-document tasks.
   - **Verifier, then optimiser, lowering and emission per function** (P2 to P5), after the sharing decision below. Expected 1.4x (verifier) up to 1.7 to 2.1x for `orin compile` on 4 cores; to be re-measured on an idle machine first.
   - **Checker and parser** (P6, P7) only if measurements after the above justify them: together they are under 20 % of a compile, and the checker's `Env` threading and discovery-order numbering would change generated ids.
4. **Sharing decision (decided in the addendum below, row 13):** either (A) each worker receives its own function plus a small per-program summary table (`Sigs`: parameter ownership, in/out flags, return kinds, vtable targets), which needs only compiler work, or (B) the runtime lends closure captures read-only. The plan assumed A. The addendum's measurements reverse that: A still copies every function body to a worker once, which costs about 60 % of the verifier it would parallelise. B is chosen, using the lending of ADR-0039 section 4 that is already in the runtime, exposed as one `std:task` function (row 13a). No second sharing mechanism is invented, and ADR-0038's frozen sharing can later replace the implementation without changing the API.

### 3. Sequence

One PR per row; rows 1 to 8 are pure code quality in directories no other effort is editing.

| # | PR | Area |
|---|---|---|
| 1 | `compiler/util/*` modules with tests, no call sites changed (A1) | new files |
| 2 | Adopt `util`, one directory per PR (`syntax`, `check`, `analysis`, `package`, `json`, `lsp`, `mcp`, `vc`, `testing`, `tools`) | those directories |
| 3 | Replace hand-written sorts with `sort` (A2) | `check/index.or`, `analysis`, `mcp`, `package` |
| 4 | Magic-int modes to unions, `-1` indices to `Option<usize>` (A3) | `check` |
| 5 | `hir/walk.or` and ports of `check/purity`, `parallel`, `resources`, `tasks`, `hirok` (A4) | `hir`, `check` |
| 6 | `fuse` pure helpers moved out, then replaced by the fold | `fuse` |
| 7 | `check/index.or` split into `check/index/` and rewritten with classes and `Map` tables (A6) | `check/index.or` |
| 8 | `main.or`: one `buildMir(checked, flags)`, a declarative option table, a thin `driver` (A5) | `main.or`, `tools/*cli.or` |
| 9 | Parallel helper `mapOrdered(n, f)` and the thread-count equality tests; first users `orin fmt` and `orin test` (P9, P10) | new, `testing`, `tools` |
| 10 | Parallel z3 for `verify --contracts` (P8) | `vc` |
| 11 | LSP/MCP analysis cache, then per-document tasks (P11, P12) | `lsp`, `analysis`, `mcp` |
| 12 | `--split N` C translation units and N LLVM modules; bootstrap, test runner and CI use it (P1) | `backends`, tooling |
| 13 | Addendum: sharing decision A or B (done: B, see the addendum) | docs |
| 13a | `std:task` `forkJoinLent`, `mapOrderedLent` / `mapChunksLent`, tests, seed refresh (added by the addendum) | `library/std/task.or`, `compiler/util/parallel.or`, seed |
| 14 | Parallel verifier entry point (P2) | `verify/verify.or`, `main.or` |
| 15 | Parallel per-function optimise, lower and emit (P3 to P5) | `opt`, `lower`, `backends` |
| 16 | MIR helper dedup (A7) and shared backend helpers (A9) | `mir`, `opt`, `verify`, `backends` |
| 17 | Extract the OX part of `check/expr.or` (about 1,030 lines) behind an `ExprHost` interface, as a pure move | `check/expr.or` |
| 18 | Opportunistic: template literals in text generators, compiler JSON dedup, generated `apitable` (with ADR-0048), OSIG HTML reports via OX (with ADR-0047 step 6) | various |

Coordination: rows 14 to 16 touch the files the escape-analysis work edits and waited for it (merged as #113); rows 12 and 16 follow ADR-0047's move of `cemit/` and `llvm/` to `compiler/backends/`; row 8 follows ADR-0047's workspace CLI changes to `main.or`. `check/expr.or` (row 17) is edited by most language PRs, so it is done in a quiet window.

## Consequences

- About 2,500 to 3,500 lines less compiler code (helpers, walkers, sorts, `index.or`, `main.or`, apitable), and the compiler becomes the first large user of `std:task`, generics and the prelude collection API, which also tests them.
- Bootstrap and CI wall time drop mostly through parallel `cc` and parallel tests, which need no language or runtime work.
- Compile-time parallelism inside the compiler depends on one library addition (row 13a, decided in the addendum); until then the compiler stays sequential and loses nothing.

## Addendum (2026-10-16): the sharing decision (row 13)

Decides section 2.4 before rows 14 to 16. Docs only. The experiments ran outside the repository (under `build/`); their programs and numbers are described here so they can be repeated.

### What exists today

- A task body is copied into its task. `forkJoin`, and so `mapOrdered` (`compiler/util/parallel.or`), copies the closure once per worker, on the spawning thread. A value is moved instead of copied only when every object in its graph has a count of 1 (`graph_unique` in `runtime/core/orin_runtime.c`). The MIR program is not such a graph (types, spans and operands are shared), and the caller needs it afterwards, so it is always copied.
- Lending is in the runtime already: ADR-0039 section 4, `orin_rt_lend` (`lendPut`), described in `docs/concurrency.md` "Fork/join pool and lending". The lent graph is pinned: counts become negative, so retain and release are no-ops and nothing in it is freed or changed in place. A transfer by the lending task shares pinned objects; a transfer by any other task copies them, so a result never points into the lent graph. `transitDrop` of the token restores the counts. It works on any graph without handles; `runtime/core/tests/task_test.c` (`test_lend`) lends an array of records. Its soundness is `TESTED_ONLY`.
- Only `library/collections/parallel.or` uses it, for the input array of `.parallel()`. `std:fsraw` can be imported from prelude files only (E0301), so compiler code cannot lend, and `.parallel()` accepts only arrays of scalars or flat records and pure closure literals (ADR-0039 sections 3 and 4).
- ADR-0038's frozen shared graphs (R3 regions and frozen sharing) are not built. The escape-analysis work that landed (#113: scalar replacement of temporary array literals) does not touch sharing, and the bintrees region experiment was measured and deferred. So the condition "B only if the escape-analysis work delivers frozen sharing anyway" did not come true; lending is what is available.

### What the verifier needs per function (the size of option A)

`verifyFunction(prog, f)` (`compiler/verify/verify.or`) reads its own function in full. Of every other function it reads only the signature: `name` (for messages), `paramCount`, `paramOwned`, `inout`, the classes of the first `paramCount` locals, and the class of `ret` (`verify/wf.or` `callMsg` and `closureMsg`, `verify/rules.or` call rule, `verify/range.or` `borrowedCall`, `verify/scan.or`). From the program it reads the lengths of `functions`, `strings` and `vtables` (`mir/wellformed.or` `instrInRange`). The `main` and vtable checks in `verify` are sequential and cheap.

So `Sigs` is about four objects per function (record, name, `paramOwned`, classes): 3,909 functions give about 16,000 objects, about 4 ms per copy. The summary itself is small. The cost of option A is in the other half of its definition: "each worker receives its own function" means every function body is copied to some worker.

### Measurements

Machine: 4 cores, load average about 10 (other jobs) during all runs. Absolute times are pessimistic and noisy; read the ratios. Micro experiment compiled with `cc -O2`, compiler builds with `cc -O1`.

(a) Micro experiment, a program in `build/exp/` that uses a copy of `compiler/util/parallel.or` `mapOrdered`; each task reads one element:

| Case | Time |
|---|---|
| 300,000 records `{id, name, xs[3]}` (0.9 M objects) captured by `mapOrdered(4, ...)` | 569 and 657 ms (four copies, 142 to 164 ms each; the audit measured 0.14 s per 0.9 M objects) |
| the same `mapOrdered(4, ...)`, nothing captured | 3 to 7 ms |
| a `Sigs`-sized table (3,909 records of 4 objects) captured | 16 to 17 ms for four workers (a cold first run: 100 ms); linear, 39,090 entries: 136 to 152 ms |
| 900,000 flat records `{a, b, c}` through `parallelMap(xs, f, 4)` (slices copied) | 85 to 126 ms |
| the same array through `.parallel().map(f)` (lent) | 36 to 55 ms |
| the same array, sequential `map` | 5 to 12 ms |

Lending costs about a third of one copy and does not grow with the number of workers; a captured value costs one full copy per worker.

(b) Prototypes of the parallel verifier in copies of the compiler sources (`orin compile compiler/main.or --timings`, not committed). The sequential verify phase of the same compiler took 0.71 to 1.05 s (855 ms in the first, quieter measurement). Every variant produced byte-identical C at `ORIN_THREADS=1` and `4`.

| Variant (`ORIN_THREADS=4`) | verify phase |
|---|---|
| V1: `mapOrdered(n, fi => verifyFunction(prog, prog.functions[fi]))`, the whole program captured | 2.07 to 2.43 s (about 2.5 times slower than sequential) |
| V2: option A as designed: a stub program (signatures only, no bodies) plus the worker's own slice of function bodies (balanced by instruction count, one `spawn` per slice) | 1.16 to 1.56 s, against 0.80 to 1.09 s for the same binary at `ORIN_THREADS=1` |
| V3: V2 with the per-function verification removed (distribution only) | 0.45 to 0.60 s |

V3 is the point. Handing every function body to a worker once costs about 0.5 s, about 60 % of the whole sequential verifier, and it is serial (the spawning thread copies). Four threads can remove at most 75 % of the 0.85 s of real work, so the best case of A is about 0.5 + 0.2 = 0.7 s against 0.85 s: 18 % of the verifier, not the 1.4x of the whole compile the audit expected for P2. The audit's variant A ("each worker gets its function, moved if unique") is not available, because the caller keeps the program. The optimiser (P3) is worse: `optimizeFunction(q, p, fi)` reads both whole programs and returns functions that share unchanged parts with its input.

Not measured: lending a deep graph from Orin code (the import is closed, see above); only the flat array in (a). From that figure pinning and restoring cost about 40 ns per object for both passes together, so the MIR program (about 1.5 M objects, an estimate) would cost about 0.06 to 0.08 s once. Row 13a measures it on the real program and has a stop condition.

### Decision: option B, by lending, through one `std:task` function

1. The compiler lends the read-only MIR program to the worker tasks of a per-function phase. Workers read it without a copy and send back only their results.
2. The mechanism is the existing one (ADR-0039 section 4). It is exposed as one function in `std:task`:

   ```
   forkJoinLent<A, R>(lent: A, chunks: usize, workers: usize, body: (k: usize) => R): R[]
   ```

   It is `forkJoin` with `lendPut(lent)` before and `transitDrop` after, the `lendIf`/`endLend` of `library/collections/parallel.or`. With `workers <= 1` or `chunks <= 1` nothing is lent and `body` runs in order on the calling task: the sequential path (`ORIN_THREADS=1`, Windows). `body` reaches the lent value through its captures, as in the `.parallel()` implementation; its other captures are copied as today and must stay small. `lent` can be any value but a handle (E0480). The documentation states the owner's obligation (the calling task only spawns and joins while the value is lent, which `forkJoinLent` guarantees by construction) and that results never refer into the lent graph (the transfer copies them). `compiler/util/parallel.or` gets `mapOrderedLent(lent, n, f)` and `mapChunksLent(lent, n, size, f)`.
3. This is an additive library change under ADR-0048 and ADR-0039 and needs no new runtime code. When ADR-0038 builds frozen sharing, or ADR-0052's R3 moves `orin_rt_lend` to Orin as `core.lend.put`, `forkJoinLent` keeps its signature and changes its implementation. No second sharing mechanism is introduced.
4. Option A is rejected as the main mechanism. It has to copy the program once anyway (V3), it needs a hand-written summary and a documented table of facts for every pass (rows 15 and 16), and it raises peak memory by one program per worker. The list of what each pass reads (above, for the verifier) stays as documentation.

### What rows 14 to 16 are then

**Row 13a** (library PR, not docs only): add `forkJoinLent` to `library/std/task.or` and `mapOrderedLent`, `mapChunksLent` to `compiler/util/parallel.or`. Tests: a lent graph of records, strings, arrays and nested records read by 1..8 workers; results equal to the sequential path for `ORIN_THREADS=1..8`; the live-object balance (`ORIN_STATS`) after the call; a trap in a piece (same message as the sequential path); the `workers <= 1` path lends nothing; ThreadSanitizer at 2, 4 and 8 threads as `tools/test_parallel.sh` does. The compiler is compiled by an older compiler whose embedded `std:task` lacks the new function, so the seed is refreshed (`tools/update_seed.sh`) in this PR or immediately after, before compiler code calls it. Stop condition: lending and unlending the real MIR program of `compiler/main.or` (measured by a test program that builds it) takes more than 0.15 s, or the lent graph shows any `transfer_copies` in `ORIN_STATS`. Then B is not delivering, and this ADR is amended again before rows 14 to 16.

**Row 14**, parallel verifier (P2). The entry point stays `verify(prog: MProgram): VerifyReport` in `compiler/verify/verify.or`; its callers (`main.or` `runVerify`, the tests) do not change, and `verifyFunction` and all rules are untouched.
- The sequential prelude is unchanged: the `main` index check and the vtable checks (`vtableMsg`), in order.
- The function loop becomes `mapChunksLent(prog, n, 64, range => verifyRange(prog, range))`: pieces of 64 consecutive functions (about 60 pieces for the compiler, so the per-piece transfer is small and stealing stays granular). The piece number selects the range; the program reaches the piece through the lent capture. A piece returns `VerifyReport[]`, one report per function of its range.
- Merge: the pool returns the pieces in index order, and the errors and warnings of the reports are appended function by function, exactly the order of today's loop. `reportPlaced(prog, ...)` and the printed order are unchanged. Issues are values (strings, spans, indices), so the copy of a result is small.
- Gate: `ORIN_THREADS=1,2,4,8` equality of (i) the C output of `orin compile compiler/main.or`, (ii) the verifier messages for the corpus of broken MIR (the `compiler/tests/verify_main.or` cases and the `tools/mutate_mir.py` mutants), (iii) `orin verify` over the test corpus. These join the existing `orin test` and `orin fmt` cases of `tools/test_threads.py` and run in CI with it, together with the bootstrap fixed point and `tools/differential.sh compilers`.
- Acceptance, measured on an idle 4-core machine with `--timings`: the verify phase at `ORIN_THREADS=4` is at most 0.6 times the phase at `ORIN_THREADS=1` (expected 0.3 to 0.45: lend 0.07 s, 0.85 / 4 = 0.21 s, merge). Otherwise the PR is not merged and the numbers go into this ADR.

**Row 15**, per-function optimise, lower and emit (P3 to P5), as separate PRs:
- 15a, optimiser. The program-wide steps stay sequential and in order (`closureTargets`, `inferModes`, `withModes`, then the shape analysis of `pairReturns` and the web analysis of `unbox`). `optimize` lends one record holding the inputs of the per-function step (`{ q, p }`; `q` shares most of its objects with `p`, so the pinned graph is not doubled) and replaces `indices(n).map(fi => optimizeFunction(q, p, fi))` by `mapChunksLent`; each piece returns the `MFunction[]` of its range, and `fns` is their concatenation in order. The per-function rewrites that follow their analyses (`forwardProgram`, `dropUniqueProgram`, `uncheckProgram`) get the same treatment, with the analysis result each reads inside the lent record. Results share unchanged blocks with the input, and the transfer copies them (cost proportional to the output, measured in the PR).
- 15b, emit. `emitC` and the LLVM emitter produce each function's text in a piece from the lent program and the lent program-wide tables (type and vtable tables built sequentially first). The texts are joined in function order, so the file is byte-identical to today's. With `--split N` (row 12) a piece can be an output unit.
- 15c, lowering, only if the profile after 15a and 15b still shows it (the audit puts it under 10 %).
- Gate for each: the same `ORIN_THREADS=1..8` equality over the compiler and the test corpus, the bootstrap fixed point (stage 2 and stage 3 C identical), the LLVM fixed point, `tools/differential.sh compilers`, and a timings table in the PR.

Row 16 (helper dedup) is unaffected and runs after 15 as before.

### Risks

1. **Lending is `TESTED_ONLY` and becomes a dependency of the compiler's own build.** A wrong pin would corrupt a compile. The equality gate and the fixed point run at `ORIN_THREADS=1..8`, ThreadSanitizer and ASan/UBSan cover the lending tests, and the sequential path never lends and stays the reference: any suspect result can be reproduced with `ORIN_THREADS=1`.
2. **Pin coverage.** Objects with a count of 2^32 or more and immortal objects are copied or skipped, and if the owner's thread id does not fit in 30 bits nothing is pinned. That is correct but slow. The row 13a test reads `transfer_copies` and fails when a lent program is copied.
3. **The owner's obligation.** While a value is lent its graph is frozen and the lending task may only spawn and join. `forkJoinLent` keeps this by construction. A reference to a pinned object that outlives the call would be uncounted, so in rows 14 and 15 the call is the last use of the lent value except for its results (a review rule).
4. **Bootstrap order.** The seed compiler's embedded library does not have `forkJoinLent`, so row 13a refreshes the seed before row 14 can compile. Section 1.6 (a cleanup PR never touches the library) is not affected: 13a is not a cleanup PR, and it follows ADR-0048.
5. **Results that share with the lent graph** (`func: f.name` in an issue, unchanged blocks in an optimised function) are copied back. The cost is bounded by the result size, is measured in rows 14 and 15, and is a reason to return indices or flags instead of whole values where that is possible.
6. **Measurement noise.** The numbers above come from a machine under load, and the prototypes are not the final code. The acceptance numbers of rows 14 and 15 are taken on an idle machine with the audit's section 3.2 differential.
7. **Windows and one thread.** There is no thread backend on Windows today; `parallelism() == 1` runs the plain sequential code without lending, so nothing changes there. Equality at `ORIN_THREADS=1` with the pre-change compiler is part of the gate.
8. **Order dependence.** Pieces must not depend on each other. `verifyFunction` and `optimizeFunction` do not, because the compiler has no global mutable state (see Motivation). The hazard is counters or tables that grow while a phase runs (`Rt.qn` in `vc` was one, row 10); looking for module-level mutable state in the phase is a checklist item of each PR.
