# Progress

_Updated: 2026-10-15_

## Current stage: self-hosting alpha, first public pre-release
- Release **v0.1.0-alpha.1** (Linux x86-64, macOS arm64):
  https://github.com/HenrySchwerdt/orin/releases/tag/v0.1.0-alpha.1
- Self-hosted compiler (`compiler/`, Orin-B source) bootstraps reproducibly (`stage2.c == stage3.c`);
  a compiler built through the LLVM backend reproduces the same `stage3.c`.
- Pipeline: parse → load (modules, preludes) → check → HIR → MIR → optimise (owned params, moves)
  → independent ownership verifier (gates every compile) → C or LLVM IR.
- CI: Linux + macOS; ~295 conformance programs (also ASan/UBSan and LLVM), parser/backend/
  optimiser/prelude differential tests, formatter, LSP, MCP, verifier, Lean proofs, packaging.

## Capability matrix
| Area | Status |
|---|---|
| Core language, modules, Option/Result/`?`, match | done |
| Generics (ADR-0007), classes (ADR-0009), closures + array API (ADR-0011) | done |
| MIR + verifier + ownership optimisation (ADR-0010) | done |
| Backends: C (default), LLVM IR (ADR-0006) | done |
| Runtime R1: string/number std in Orin (spec 19) | done |
| Lean: RC machine safety, COW, checker soundness for the MIR core | done (partial) |
| Tooling: fmt, check --format=json, lsp, mcp, VS Code | done |
| Parser error recovery: up to 20 syntax errors per file (CLI, JSON, LSP, MCP), first error unchanged, no type checking of a file that does not parse (docs/rewrite.md "Parser error recovery") | done |
| Releases (dispatch workflow, packages, seed C) | done |
| Seed bootstrap (ADR-0014) | done |
| Floats (`float`, `f32`), `std:math`, `Map<K,V>` (ADR-0018) | done |
| Runtime R2: platform layer with contracts | done (CBMC-bounded + tests) |
| Contract clauses (ADR-0012): parse/check/erase, runtime checks, SMT for functions, methods and classes | done: phase 1 + phase 2 (`orin verify --contracts`, z3): integers, arrays, records, `Option`/`Result`/`Map`, strings by length, modular calls, class invariants per method, loops, quantifiers and sums (ADR-0031 B/C, ADR-0036; see docs/contracts.md) |
| Packages: `orin.toml`, architecture rules, API snapshots | done |
| std:path/json/time/graph | done |
| Provable std layer 1 (ADR-0030 §3): `std:bytes`, `std:utf8`, `std:collections` | done: pure Orin, best-known algorithms (B-tree maps, 4-ary heap, table-driven UTF-8 DFA, ring deque), 24 invariants / 16 `@Requires` / 291 `@Ensures`, 94 `@Test`, 60-mutant check and differential tests against executable specs (`tools/test_std.sh --mutate`); generic `Set`/`SortedMap<K,V>`/comparator queue blocked by language limits (docs/std.md) |
| `std:http`, the pure part (ADR-0030 §3 "protocols"): HTTP/1.1 request and response parser, serializer | done: incremental, smuggling-safe (every ambiguity refused with reason and position), limits as parameters, explicit state machine in the invariants, round-trip contract; 34 invariants / 49 `@Requires` / 131 `@Ensures`, 72 `@Test`, split-at-every-byte, differential and fuzz tests (40,000 fuzz iterations), 41-mutant check; sockets in `std:net` (ADR-0033) |
| `std:net` (ADR-0033): blocking TCP on L0 primitives with contracts and CBMC harnesses, `NetGrant` / `Listener` / `Stream` resources, `examples/http_server.or` | done: loopback tests on Linux and macOS (`tools/test_net.sh`), slowloris deadline, scope refusals, `ORIN_DENY=net`; one connection at a time (ADR-0017) |
| Interfaces (ADR-0019) | done |
| Fixed-width integers (`i8`..`u64`, `isize`, `usize`; 128-bit deferred, E0431) and template-literal interpolation (ADR-0022) | done |
| Built-in annotations `@Test` (`orin test`, `std:test`), `@Deprecated`, `@Inline` (ADR-0024, docs/testing.md) | done |
| Resources (`File`, ADR-0025): checker + verifier rules, scope API, streaming `std:fs` (unstable until capabilities) | done |
| Compiler rewrite with the full language (ADR-0015, docs/rewrite.md): `diag` + `loader` (step 1), checker foundation `check/{env,fnctx,types}` (step 2a: Map-based symbol tables / instance indexes, `Scope` class), expression and statement checker `check/body.or` split into `fnctx` / `ops` / `match` / `call` / `lift` / `hirok` / `expr` / `stmt` (step 2b: classes `FnCtx`, `ExprChecker`, `StmtChecker`, `Coverage`, `Inference`; 230 contract clauses; byte-identical output), `lower/` (step 3a: class `Lowerer`, `BlockBuilder`, `Locals`, `OwnedScope`; 97 contract clauses; **MIR source spans**, ADR-0020 D3, MIR v2.0; byte-identical C / LLVM output), `syntax/` (step 3c: classes `Lexer`, `Parser`, `OpTable`; precedence climbing over an operator table; AST well-formedness predicates; 129 contract clauses; parse errors and generated code byte-identical; then parser error recovery, several syntax errors per file), `opt/` + `cemit/` + `llvm/` (step 3d: classes `ParamInference`, `BlockSink`, `RewritePlan`, `CSymbols`, `CFunctionEmitter`, `LlvmSymbols`, `LlvmFunctionEmitter`, ...; per-function code generation from a read-only symbol table, rule 8; byte-identical C / LLVM output) | in progress (remaining `check` files) |
| Capabilities, Stage A (ADR-0021, ADR-0027): `main(host: Host)`, grants as resource handles, narrowing, `ORIN_DENY`, path scopes, `PERFORMS_IO` OSIG edges | done; std I/O signatures await the owner's freeze confirmation. **Stage B done** (transitive effect inference, `orin effects`, OSIG `MAY_PERFORM`, `[effects]` policy; docs/capabilities.md). Stages C-D (library adapters, lineage, strict policy gates) not started |
| Concurrency, stage 0 (ADR-0017 Addendum A, docs/concurrency.md): `std:task` (scope / spawn / join, bounded channels, grants moved into tasks, `parallelMap`), L0 threads and monitors, one temporary C interface with a porting table to R3 | done; C parts `TESTED_ONLY` (ThreadSanitizer, ASan + UBSan, stress); no `async` / `await`, cancellation, deadlock detection or M:N scheduler; concurrent HTTP server waits for `std:net` |
| OX markup and `std:html` (ADR-0043, ADR-0044, docs/ox.md): TSX-compatible syntax, providers selected by `import ox from`, `Markup` (fused single-buffer text) and `Components` (values) provider kinds, typed slots and fragments, named slots, spread, source-order evaluation, `@Sealed`; `std:html` is a provider, `std:ox` the protocol | done: 6 run + 30 error tests incl. a widget and an XML provider, compile-time/run-time escaping differential, `std:html` mutants, `tools/mutate_ox.py` on the compiler, `bench/html` vs hand-written; member tags, spread on intrinsics, pre-sized buffers, component fusion not started |
| Incremental analysis | not started |
| Closure inlining and fusion (ADR-0038 §2, `compiler/fuse`) | done for `map` / `filter` chains ended by every array-API terminal; chain = loop in CPU time (`bench/streams`); borrow inference, reuse in place not started |
| Parallel pipelines (ADR-0039 steps 1-3): `parallel()`, work-stealing fork/join pool in `std:task`, lending without copies, E0484-E0486, W0480-W0481 | done; speedup not yet measured on an idle machine; parallel `sort`, user reducers, all element types not started |
| OSIG: `orin graph`, `orin diff`, static HTML report, MCP `graph`/`diff` (ADR-0023, docs/osig.md) | done (phase 1 MVP: symbols, calls with MUST/MAY/UNKNOWN evidence, imports, implements, type refs, contracts) |
| Feature manifest, effects, lineage, `.orcert` (ADR-0020) | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | not started |

## Next milestones
See [`roadmap.md`](roadmap.md) (integrated plan, including the verifiable-software tracks of
ADR-0020) and [`tcb.md`](tcb.md) (what every guarantee currently trusts).
1. Interfaces + contract clauses phase 1 merged; OSIG/`orin graph`/`orin diff` started in parallel.
2. ~~Fixed-width integers, interpolation~~ (done, ADR-0022), ~~`@Test`/`@Deprecated`/`@Inline`~~ (done, ADR-0024), ~~resources~~ (done, ADR-0025), ~~generic classes~~ (done, ADR-0026: all language-freeze prerequisites are in; the language freeze and the compiler rewrite of ADR-0015 can start); capabilities (ADR-0021 Stage A, ADR-0027: done) → std I/O freeze (owner decision, open questions in ADR-0027).
3. Compiler rewrite with the full language and MIR source spans (ADR-0015): steps 1, 2a, 2b, 3a, 3b (verifier), 3c, 3d (optimiser and both backends, per-function code generation ready for ADR-0039 `.parallel()`) and 3e (tooling) done (3a added MIR source spans, ADR-0020 D3; 3c the lexer and parser); next the remaining checker files (`collect`, `decls`, `classes`, `index`, ...).
4. v0.1.0-alpha.2 with closures, floats, maps, interfaces, std modules.

## Open work, in order (updated 2026-10-15, after the performance wave)
Merged 2026-10-15: unboxing (#62, MIR v2.2), packed verifier state (#64), census quick wins (#65), borrow inference (#67),
concat reuse in place (#68, MIR v2.3), CI sharding of `backends` plus LLVM `.parallel()` declarations (#66), LLVM/C
instruction parity (#69, ADR-0038 §8 gate 1); the last four through the integration PR #70. Effect: self-compile -38.8%
executed instructions, -93% retains; census numbers and the lever ranking in
[`perf/alloc-census.md`](perf/alloc-census.md).

1. **Performance, lever 2: field and element access code** (not a census class; design accepted 2026-10-15, ADR-0038
   addendum "lever 2"): `make_unique` + `struct_get` / `struct_replace` per field write and repeated bounds-checked element
   reads (mutres 10.6x C instructions, pqueue 4.8x, nbody 3.7x, sieve 3.4x). Done: T3 (scalar stores without the run-time
   refmask test) and the `orin_stats` hot counters as a build option (#79); T1 (drop `makeunique` of a local proven `Unique`:
   nbody -13.8%, sieve -10.4% instructions). Next T4 (in progress), T5, T2 with the new verifier rules F1, U2-U5, U1;
   T6 (range facts) needs its own decision.
   Lever 1 (verifier and optimiser data structures) is done: self-compile -23% allocations, -3.2% instructions; the
   remaining self-compile time is no longer allocation.
2. **Performance, next ADR-0038 steps:** escape analysis / scalar replacement (c); unboxing of records with reference
   payloads and flattening `Span` into its containers (a); reuse in place for field/element in/out (e); regions for
   bintrees (f, low priority: bintrees is already at 0.94x C instructions); packed arrays (b).
3. **LLVM gates 2 + 3** (ADR-0038 §8): LLVM fixed point of the self-compile, pinned toolchain. Gate 1 is met (LLVM at or
   below the C backend on 13 of 15 instruction rows; appends +0.8%, qsort_func +0.5%).
4. **Parallel sockets:** `spawnNet` / `scopeNet`, a move rule for `Stream`, a per-task net buffer in place of the
   global `g_netbuf`, and a concurrent HTTP server with limits and TSan / load tests.
5. **Rewrite:** `compiler/vc/` and the remaining checker files. Then the rule-7 stream-style sweep, and later
   `.parallel()` per compiler phase (ADR-0039 §6).
6. **Follow-ups:**
   - `HStmt` spans for break/continue/return;
   - trap hook and cancellation for tasks (prerequisite for ADR-0041 Stage D);
   - ADR-0040 (generic methods);
   - ADR-0037 D5;
   - ADR-0042 stage 1 (complexity summaries);
   - decide whether a struct with more than 64 slots is a compile-time error (it currently traps at run time).
