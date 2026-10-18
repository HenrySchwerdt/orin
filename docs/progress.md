# Progress

_Status refresh: 2026-10-16, baseline `732af00`; dated measurements below retain their own baselines._

## Current stage: self-hosting alpha, first public pre-release
- Release **v0.1.0-alpha.1** (Linux x86-64, macOS arm64):
  https://github.com/orin-lang/orin-lang/releases/tag/v0.1.0-alpha.1
- Self-hosted compiler (`compiler/`, full Orin source) bootstraps reproducibly (`stage2.c == stage3.c`);
  a compiler built through the LLVM backend reproduces the same `stage3.c`.
- Pipeline: parse → load (modules, preludes) → check → HIR → MIR → optimise (owned params, moves)
  → independent ownership verifier (gates every compile) → C or LLVM IR.
- CI: Linux + macOS; conformance programs in `tests/run`, `tests/errors` and `tests/next` (also ASan/UBSan and LLVM), parser/backend/
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
| Code explorer (ADR-0050) with a business view for product owners (ADR-0051): rules as sentences, use cases, capabilities, behaviour diff; rule status (proved / runtime / open) waits for OSIG to carry it | done (status: open item) |
| Releases (dispatch workflow, packages, seed C) | done |
| Seed bootstrap (ADR-0014) | done |
| Floats (`float`, `f32`), `std:math`, `Map<K,V>` (ADR-0018) | done |
| Runtime R2: platform layer with contracts | done (CBMC-bounded + tests) |
| Contract clauses (ADR-0012): parse/check/erase, runtime checks, SMT for functions, methods and classes | done: phase 1 + phase 2 (`orin verify --contracts`, z3): integers, arrays, records, `Option`/`Result`/`Map`, strings by length, modular calls, class invariants per method, loops, quantifiers and sums (ADR-0031 B/C, ADR-0036; see docs/contracts.md) |
| Packages: `orin.toml`, architecture rules, API snapshots | done |
| Project CLI: `init`, cached build/run, `dev`, project tests/fmt, path/Git dependencies and lockfile, colored source diagnostics | implemented; see [CLI guide](cli.md); registry, structured assertion diffs and animated progress remain |
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
| Concurrency, stage 0 (ADR-0017 Addendum A, docs/concurrency.md): `std:task` (scope / spawn / join, bounded channels, grants moved into tasks, `parallelMap`), L0 threads and monitors, one temporary C interface with a porting table to R3 | done; C parts `TESTED_ONLY` (ThreadSanitizer, ASan + UBSan, stress); no `async` / `await`, general cancellation, deadlock detection or M:N scheduler; concurrent HTTP service needs network grant/stream ownership and cleanup work, see [roadmap](roadmaps/async-concurrency.md) |
| OX markup and `std:html` (ADR-0043, ADR-0044, docs/ox.md): TSX-compatible syntax, providers selected by `import ox from`, `Markup` (fused single-buffer text) and `Components` (values) provider kinds, typed slots and fragments, named slots, spread, source-order evaluation, `@Sealed`; `std:html` is a provider, `std:ox` the protocol | done: 6 run + 30 error tests incl. a widget and an XML provider, compile-time/run-time escaping differential, `std:html` mutants, `tools/mutation.sh ox` on the compiler, `bench/html` vs hand-written; member tags (instances, interfaces, static methods; modules have no values), spread on intrinsics and pre-sized buffers done; component fusion, append without temporaries, streaming not started |
| Incremental analysis | not started |
| Closure inlining and fusion (ADR-0038 §2, `compiler/fuse`) | done for `map` / `filter` chains ended by every array-API terminal; chain = loop in CPU time (`bench/streams`); borrow inference, reuse in place not started |
| Parallel pipelines (ADR-0039 steps 1-3): `parallel()`, work-stealing fork/join pool in `std:task`, lending without copies, E0484-E0486, W0480-W0481 | done; speedup not yet measured on an idle machine; parallel `sort`, user reducers, all element types not started |
| OSIG: `orin graph`, `orin diff`, static HTML report, MCP `graph`/`diff` (ADR-0023, docs/osig.md) | done (phase 1 MVP: symbols, calls with MUST/MAY/UNKNOWN evidence, imports, implements, type refs, contracts) |
| Feature manifest, effects, lineage, `.orcert` (ADR-0020) | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | R3a done (core operations `BCore`, ADR-0052: all of `runtime/core` to Orin in R3a-R3f, L0 stays C); R3d.0 done (preparation for the object model in Orin, ADR-0052 Addendum A: embedded root `$rt`, internal module `std:core` for `$rt/` only, core operations 13..23 (bit operations, `expect`, `cfg`, `heapBase`, `memRealloc`, `memMove`, `memCmp`), `memAlloc` traps on out of memory, `addrOf` escape rule in `opt/unbox`, frozen runtime snapshot `bootstrap/seed/runtime/`, one runtime source list `tools/runtime-sources.txt`; no change to emitted code of normal programs; the working assumptions of the addendum section 6 await the owner); R3d.1 done (runtime only: `g_live`, free lists, small-block cache, `orin_destroy` work stack and `orin_stats` are fields of one exported `__thread OrinHeap orin_heap`, 1024 bytes, which `heapBase()` returns; offsets in spec 19 "R3d.1", pinned by `_Static_assert`s; counters and instruction counts unchanged); R3d.2 done (first L1 functions in Orin called by generated code: `runtime/core/leaf.or` unwraps, shape trap, `--assert-facts` checks; static immortal objects for `nullary`, bintrees -11 % instructions on C and LLVM, others unchanged; C counterparts deleted from the live runtime; spec 19 "R3d.2"); R3d.3 done (allocator, free lists, `destroy`, `make_unique_slow`, small-block cache, string allocation and `array_push_grow` in Orin on the shared heap block, three commits, core operations `wadd` / `wsub` / `wmul`; bintrees -20 % instructions in total with R3d.2, others within budget; census builds kept the C versions until R3d.5; spec 19 "R3d.3"); R3d.4 done (string append family, array slice/concat/extend and the byte conversions in Orin, `runtime/core/{str,array}.or`; LLVM appends -19 %, bytesstr -21 %, html -11 %, C within +1.1 %; spec 19 "R3d.4"); R3d.5 done (`ORIN_STATS` report and `live_count` in Orin, `runtime/core/stats.or`; the allocation-site census runs on the Orin object model through a prefix word before each object and the new core operation `hook` to the C census tables, all `#ifdef ORIN_SITE_STATS` C copies and `rtIdsFor` deleted; counters and census tables identical, instructions unchanged, and the digit counting of `appendDecimal` fixed: `mapfreq` and `wordfreq` -2 %; spec 19 "R3d.5"); R3d.6 done (the C backend emits a preamble of the object-model inlines, `compiler/backends/c/preamble.or`, under the prefix `orinc_`, and `orin_runtime_mir.h` plus the arithmetic and unchecked-array inlines of `orin_runtime.h` are deleted; the header keeps only what the C shells and their unit tests call; instructions unchanged, +-0.00 % on every benchmark; spec 19 "R3d.6"); R3b partly done (`parseI8`..`parseUsize` in Orin; float format/parse stay C, see spec 19 inventory); R3c-R3f and R4 not started |
| Provability phase: record/class invariants proved, memory-safety proof chain (ADR-0053, M1-M13) | proposed (ADR only); starts after the language work, M9-M12 wait for ADR-0052 R3b/R3d/R3e |

## Next milestones

**Consolidated plan to 1.0:** [Orin 1.0 roadmap](roadmaps/orin-1.0.md) (proposal for owner review, 2026-10-16): definition of done, gaps, milestones M0-M5 and the open owner decisions.

**User-defined annotations (ADR-0046, implemented 2026-10-16):** S1 definitions and uses, S2 tooling metadata, S3 `std:meta`, S4 companion modules and `orin expand`, S5 processor execution, S6 the examples `examples/json-codec` (`@Json` codecs) and `examples/routes` (`@Route` table) as example packages, not std (owner decision). Not done: LSP/MCP/`orin test`/`orin graph` do not expand `.gen`, OSIG `GENERATED_BY` edges, processor memory limit.

See [`roadmap.md`](roadmap.md) (integrated plan, including the verifiable-software tracks of
ADR-0020) and [`tcb.md`](tcb.md) (what every guarantee currently trusts).
1. Resolve stable API/I/O scope and final candidate/platform evidence before claiming 1.0 readiness;
   see [release gates](release-1.0-readiness.md) and the [completed night-shift handoff](release-1.0-nightshift.md).
2. Public monotonic clock/deadline work is active separately, not landed at this baseline. The
   [stdlib priorities](agent-stdlib-priorities.md) distinguish shipped JSON/encoding/URL slices from
   remaining process capture/output limits, filesystem helpers and integration libraries.
3. Follow the [async/concurrency roadmap](roadmaps/async-concurrency.md): cleanup/cancellation and
   interruptible waits before a scheduler experiment; syntax changes require their own ADR decision.
4. Continue the remaining checker/VC rewrite under ADR-0015. Performance PRs #91 and #98 remain
   decision/parked work, as detailed below; their existence is not implementation on main.
5. After the ADR-0047 layout move and the escape-analysis work: unify the std API per
   [ADR-0048](decisions/0048-std-api-conventions.md) and clean up and parallelise the compiler per
   [ADR-0049](decisions/0049-compiler-cleanup-and-parallel-compilation.md); evidence in [`audits/`](audits).
   Row 13 (sharing decision) is done: the program is lent read-only to the workers via a new `std:task` `forkJoinLent`
   (row 13a), then the parallel verifier (row 14) and optimiser/emitter (row 15); see the ADR's addendum for measurements.

## Open work and decision gates (performance history retained)
Merged 2026-10-15: unboxing (#62, MIR v2.2), packed verifier state (#64), census quick wins (#65), borrow inference (#67),
concat reuse in place (#68, MIR v2.3), CI sharding of `backends` plus LLVM `.parallel()` declarations (#66), LLVM/C
instruction parity (#69, ADR-0038 §8 gate 1); the last four through the integration PR #70. Effect: self-compile -38.8%
executed instructions, -93% retains; census numbers and the lever ranking in
[`perf/alloc-census.md`](perf/alloc-census.md).
Census re-run 2026-10-16 (after lever 1 and T1/T3/T4) with the current lever ranking (string intermediates first, then `Span`/`Token` flattening, escape analysis; T6 pending): [`perf/alloc-census.md`](perf/alloc-census.md) section "Since #71".

1. **Performance, lever 2: field and element access code** (not a census class; design accepted 2026-10-15, ADR-0038
   addendum "lever 2"): `make_unique` + `struct_get` / `struct_replace` per field write and repeated bounds-checked element
   reads (mutres 10.6x C instructions, pqueue 4.8x, nbody 3.7x, sieve 3.4x). Done: T3 (scalar stores without the run-time
   refmask test) and the `orin_stats` hot counters as a build option (#79); T1 (drop `makeunique` of a local proven `Unique`:
   nbody -13.8%, sieve -10.4% instructions); T4 (load forwarding: MIR v2.4 `IForward`, verifier rule F1, `orin2 compile --assert-facts`;
   nbody -6.0%, mutres +0.05% instructions, the other three unchanged, self-compile unchanged; 77 forwarded loads in the compiler itself).
   T5 (unique receivers and results across calls: MIR v2.7, verifier rules U2-U5, optimistic flags
   `unique-in` / `unique-out`; mutres -5.6%, the other four unchanged, self-compile +0.83%; it also closed a hole where a borrowed `Unique` argument
   stayed `Unique` after an in/out call). T2 (U1) and T6 (range facts) are separate entries.
   Lever 1 (verifier and optimiser data structures) is done: self-compile -23% allocations, -3.2% instructions; the
   remaining self-compile time is no longer allocation.
2. **Performance, census row 1 (string intermediates) is done** (ADR-0038 addendum 2026-10-16, MIR v2.5: `IStrAppendNum`,
   `IStrAppendSub`): mapfreq -27.7%, wordfreq -28.9%, html -36.6%, strings -37.8% executed instructions; html -60% and html_hand
   -98% allocations (html_hand -65% instructions); self-compile -0.5%. The mapfreq / wordfreq allocations stay (the number string is the map key). Next in the
   census ranking: `Span` / `Token` flattening, then escape analysis. `Span` / `Token` flattening was measured 2026-10-16 and
   dropped: its cheapest part (`skipTrivia` returning a plain `usize`, removing ~507k `Ok(i)`) gives only -0.29% self-compile
   instructions, and flattening `Span` itself needs value types (every `toks[i].span` / `spanTo` would re-allocate it).
   T2 (unchecked dominated accesses, draft #98) is parked: gcc -O2 already removes the second check, gain nil; it is the
   base for T6, whose ceiling (all array kind + bounds checks removed) is nbody -53%, pqueue -37%, sieve -18% instructions.
   T6 (range facts, same branch, draft #98) is built: `compiler/verify/range.or`, nbody -53.1% (the ceiling), pqueue / sieve /
   qsort_inplace / mutres unchanged (parameter and push-built arrays have no shape fact), self-compile +0.37%; verifier 2476 -> 3461
   code lines (T2 +115, T6 +870). Needs the owner's decision on the interval domain before merge (ADR-0038 T6).
   Escape analysis / scalar replacement (c) is done for its one clean case (ADR-0038 addendum 2026-10-16, `compiler/opt/lits.or`, no MIR
   or verifier change): a temporary array literal that is only appended (`x = x.concat([..])`) becomes pushes; appends -48.6%
   instructions, -99.99% allocations, all other benchmarks and the self-compile unchanged. The rest of class (c) in the compiler
   (`BlockSink`, `State`, `RewritePlan`, `Transfer`: mutable helper objects) is worth about 0.5% of the self-compile and needs an inliner
   or a verified non-heap object; not built.
3. **Performance, further ADR-0038 steps:** unboxing of records with reference
   payloads and flattening `Span` into its containers (a); reuse in place for field/element in/out (e); regions for
   bintrees (f, deferred: measured 2026-10-16, free lists and iterative release already exist, regions would give about -50 %
   on bintrees alone and nothing elsewhere; ADR-0038 addendum); packed arrays (b). **Measured 2026-10-16 (ADR-0038 addendum "packed arrays (b) and reuse in place (e)"):** (e) is worth at most 0.54 % of the self-compile (all COW copies together 2.25 %, the rest is real sharing) and nothing on any benchmark: not built. (b): full packing would give bytesstr -99 % and http_parse at most -9 %, nothing on the compiler, for a MIR version, a lowering change and 40 runtime array sites: not built; instead the `u8[]` <-> string conversion loops are unrolled in the runtime (bytesstr -27 %, LLVM -35 %, http_parse up to -1.5 %, no MIR / verifier change). Done on the way: small-block cache for
   strings and array buffers, self-compile -4.9 %, wordfreq -13 %, mapfreq -9 %.
4. **LLVM default for `--release`** (ADR-0038 §8): **done** (owner, 2026-10-16); `--backend=c` is the explicit fallback. Gate 3 is met (2026-10-16: pinned LLVM 19.1.7, `dist/llvm.pin`,
   `orin toolchain install` verifies the sha256; `orin doctor` reports it; `--release --backend=llvm` without it falls back to C
   and says so). `--release` now defaults to LLVM (`release_backend` in `dist/orin-cli.sh`); without the pinned clang it uses a system clang at least as new as the pin, else C.
   Not bundled in the packages; aarch64 / macOS downloads unexercised. Gate 2 is met (2026-10-16: `tools/llvm_fixpoint.sh`, in CI;
   the LLVM-built compiler emits the same C and the same `.ll` as orin2, also with a third stage). Gate 1 is met (LLVM at or
   below the C backend on 13 of 15 instruction rows; appends +0.8%, qsort_func +0.5%).
5. **Parallel sockets (done, ADR-0017 Addendum C):** `spawnNet` / `scopeNet`, `acceptDetached` / `spawnAccepted` / `serveAccepted`
   (a `Stream` is moved into a task via the grant-token machinery), E0487, a per-task net buffer in place of the global
   `g_netbuf`, `examples/http_server.or` (concurrent since C5; the former `http_server_concurrent.or` was merged into it) with limits, load and TSan tests in `tools/test_net.sh`, and the C5 acceptance campaign `tools/test_server_campaign.sh`.
6. **Rewrite:** `compiler/vc/` and the remaining checker files. Then the rule-7 stream-style sweep, and later
   `.parallel()` per compiler phase (ADR-0039 §6).
7. **Follow-ups:**
   - `HStmt` spans for break/continue/return;
   - trap hook and cancellation for tasks (prerequisite for ADR-0041 Stage D);
   - ADR-0040 (generic methods);
   - ADR-0037 D5;
   - ADR-0042 stage 1 (complexity summaries);
   - done (ADR-0056 C9): a record or variant with more than 64 slots is compile error E0305.
