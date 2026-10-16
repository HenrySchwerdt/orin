# ADR-0049: Compiler cleanup and parallel compilation

Status: accepted (2026-10-16). Plan only; implementation starts after ADR-0047's layout move and the ADR-0038 escape-analysis work are in `main`.

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
6. Every cleanup PR is behaviour-neutral and proves it: bootstrap fixed point, LLVM fixed point, a zero diff of the generated C of `compiler/main.or` and the test corpus between the pre-PR and post-PR compiler (`tools/diff_compilers.py`), the LSP/MCP/OSIG/fmt/CLI suites, and `tools/test_compiler_contracts.sh` where contracts change. A cleanup PR never touches the library (`std/`, `stdlib/`, `array/`, later `library/`), because the embedded prelude is generated from it; library changes follow ADR-0048.

### 2. Parallel compilation

1. Parallel phases are built on `std:task` `forkJoin` over function or file indices, with results merged in index order. With `parallelism() == 1` (`ORIN_THREADS=1`, Windows today) the code path is exactly the sequential one.
2. Output must be identical for every thread count. The gate is an `ORIN_THREADS=1..8` equality matrix over the compiler and the test corpus, in addition to the bootstrap fixed point.
3. Order of work, by gain per risk:
   - **No sharing needed** (process-level parallelism): parallel `orin test` (one process per test already), parallel z3 in `orin verify --contracts` (per-function SMT file names instead of the program-wide `Rt.qn` counter), `orin fmt` and workspace commands per file or package.
   - **Split generated C into N translation units** (P1) so `cc` runs in parallel in bootstrap, `orin test` and CI. The single-file output stays the default (`-o out.c`); a `--split N` option enables the new layout so goldens stay valid. Expected: about 63 s to about 20 s per bootstrap stage on 4 cores.
   - **LSP/MCP analysis cache** keyed by `(entry, revision)` before any threads; then per-document tasks.
   - **Verifier, then optimiser, lowering and emission per function** (P2 to P5), after the sharing decision below. Expected 1.4x (verifier) up to 1.7 to 2.1x for `orin compile` on 4 cores; to be re-measured on an idle machine first.
   - **Checker and parser** (P6, P7) only if measurements after the above justify them: together they are under 20 % of a compile, and the checker's `Env` threading and discovery-order numbering would change generated ids.
4. **Sharing decision (open, decided in an addendum before P2):** either (A) each worker receives its own function plus a small per-program summary table (`Sigs`: parameter ownership, in/out flags, return kinds, vtable targets), which needs only compiler work, or (B) the runtime lends closure captures read-only, which belongs to ADR-0038's frozen sharing. The default is A, because it needs no runtime change and keeps workers' inputs small; B is chosen only if the escape-analysis work delivers frozen sharing anyway. No second sharing mechanism is invented outside ADR-0038.

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
| 13 | Addendum: sharing decision A or B | docs |
| 14 | Parallel verifier entry point (P2) | `verify/verify.or`, `main.or` |
| 15 | Parallel per-function optimise, lower and emit (P3 to P5) | `opt`, `lower`, `backends` |
| 16 | MIR helper dedup (A7) and shared backend helpers (A9) | `mir`, `opt`, `verify`, `backends` |
| 17 | Extract the OX part of `check/expr.or` (about 1,030 lines) behind an `ExprHost` interface, as a pure move | `check/expr.or` |
| 18 | Opportunistic: template literals in text generators, compiler JSON dedup, generated `apitable` (with ADR-0048), OSIG HTML reports via OX (with ADR-0047 step 6) | various |

Coordination: rows 14 to 16 touch the files the escape-analysis work edits and wait until it is merged; rows 12 and 16 follow ADR-0047's move of `cemit/` and `llvm/` to `compiler/backends/`; row 8 follows ADR-0047's workspace CLI changes to `main.or`. `check/expr.or` (row 17) is edited by most language PRs, so it is done in a quiet window.

## Consequences

- About 2,500 to 3,500 lines less compiler code (helpers, walkers, sorts, `index.or`, `main.or`, apitable), and the compiler becomes the first large user of `std:task`, generics and the prelude collection API, which also tests them.
- Bootstrap and CI wall time drop mostly through parallel `cc` and parallel tests, which need no language or runtime work.
- Compile-time parallelism inside the compiler depends on one decision (section 2.4) and on ADR-0038; until then the compiler stays sequential and loses nothing.
