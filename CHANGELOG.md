# Changelog

## Unreleased
- **Pinned LLVM toolchain (ADR-0038 section 8, gate 3).** New `orin toolchain install [--force]` / `status` (in `dist/orin`, wired
  into `dist/orin-cli.sh`): it downloads the LLVM release pinned in `dist/llvm.pin` (19.1.7; linux-x86_64, linux-aarch64,
  macos-arm64), refuses the archive unless its sha256 matches the pin, unpacks `clang`, `llc` and clang's resource directory (about
  400 MB) into `~/.orin/toolchains/llvm-19.1.7`. `orin build|run --backend=llvm` then uses that clang; `--release --backend=llvm`
  without it falls back to the C backend and prints a note; `orin doctor` reports the toolchain (informational). With the pinned
  clang the llvm suite (925 tests) and `tools/llvm_fixpoint.sh` pass unchanged. `tools/test_llvm_toolchain.sh` (CI job `llvm`) checks
  the pin and the install against a local fake archive (wrong checksum, tampered file, wrong version, unpinned platform);
  `tools/test_cli.py` covers fallback, install, use and `CC` precedence. LLVM is still not the release default (all three gates
  are met; the decision is the owner's). 18.1.8 was rejected: its Linux x86_64 archive needs `libtinfo.so.5`.
- **Code explorer (ADR-0050, step 1).** New package `tooling/explorer` (`explore SNAPSHOT.json [--diff DIFF.json] [--title NAME] --out DIR`): an offline, deterministic site generated with Orin + OX from `orin graph` / `orin diff --format=json` output: overview cards, module dependency graph and call flow (server-side layered SVG layout with MUST / MAY / UNKNOWN evidence), symbol pages with documentation comments, contracts, effects and call neighbourhood, a symbol index, the compiler pipeline view and a changes page built on `DiffView`. `orin-reports`: `ShellWith`, a bare SVG canvas with rounded boxes, curves and safe links, compact card numbers (`24.50 G`, exact value as tooltip) that never wrap, and a card grid without orphan rows.
- **OSIG `osig/0.3`: documentation comments in the snapshot (ADR-0050).** Additive node field `doc` (the rendered `/** */` comment of a declaration, written only when present); `orin graph` and `orin diff` read every `osig/0.*` snapshot as before. New helper `documentationFrom` (scan a file once, document many declarations). Used by the new code explorer (`tooling/explorer`).
- **Benchmark reports in Orin + OX (ADR-0047 phase 6).** New packages `tooling/reports` (typed report model, shared OX components, static CSS design system, SVG canvas) and `tooling/benchmarks` (`bench-report summary|compare|render`) replace `tools/bench_report.py`; Markdown, SVG and README are byte-identical to the Python output (golden tests, fuzzed against the old tool), and `render` adds a stand-alone `report.html`. `.github/workflows/bench.yml` builds and uses the Orin tool.
- **Escape analysis, scalar replacement of temporary array literals (ADR-0038 addendum 2026-10-16, class (c)).** New optimiser pass
  `compiler/opt/lits.or`: `t = arraynew [e1..ek]; arrayextend x, t; release t` (the lowering of `x = x.concat([e1, .., ek])`) becomes
  `arraypush x, e1; ..; arraypush x, ek`. No MIR change, no new verifier rule, no runtime change. appends -48.6 % executed instructions
  and -99.99 % allocations (200,019 -> 19); every other benchmark and the self-compile are unchanged (the compiler has no such
  literal). Regression program `tests/next/run/escape_array_literal`. The method-local helper objects of the compiler (`BlockSink`,
  `State`, ...) were measured at about 0.5 % of the self-compile's instructions and are not removed.
- **Unchecked array accesses from range facts (ADR-0038 lever 2, T6, MIR v2.6; draft).** The verifier gains an interval analysis
  (`compiler/verify/range.or`, rules R1-R5 in docs/mir.md) that accepts `arraygetu` / `arraysetu` when the index is provably below the length
  of an array built by `arraynew` in the same function; the optimiser pass `opt/bounds.or` emits them where the verifier agrees.
  nbody -53.1 % executed instructions, the other benchmarks unchanged, self-compile +0.37 %. Array length stays outside the Lean model
  (docs/tcb.md). New mutation classes `range-*`, regression programs `tests/next/run/bce_range_*`.
- **LLVM fixed point (ADR-0038 section 8, gate 2).** New `tools/llvm_fixpoint.sh` (run in the CI `llvm` job): `orin2` compiles
  `compiler/main.or` with `--backend=llvm`, clang links `orin2-llvm`, and `orin2-llvm` reproduces both the C (`== stage2.c`,
  11,055,024 bytes) and the LLVM IR (45,279,878 bytes) byte for byte; `--deep` adds a third stage. No differences were found,
  so no backend or runtime change. LLVM is still not the release default (gate 3, the pinned toolchain, is open).
- **bench/url prints no wall-clock time.** The benchmark printed `ms=<elapsed>` next to its checksum, so every run differed from the
  previous one (also C against C) and `tools/bench.py` reported "CHECKSUM MISMATCH in url (llvm)". This was not an LLVM miscompile:
  output of the C and LLVM binaries is identical apart from the timing field. The benchmark now prints only deterministic values
  (timing is measured by `tools/bench.py`), like every other benchmark.
- **String intermediates removed (ADR-0038 addendum 2026-10-16, MIR v2.5).** New instructions `IStrAppendNum` (append the decimal
  text of an `int`/`usize` to a string) and `IStrAppendSub` (append `s.substring(i, j)` without the substring object), with the
  ownership rule of `IStrAppend`; runtime `orin_str_append_int` / `_usize` / `_sub`. `s + n.toString()`, `${n}`, `s += n.toString()`,
  a bare `n.toString()`, the operands of a string `+=` chain and the pieces of `html.escape` no longer build temporary strings
  (same text, evaluation order and traps). Executed instructions: mapfreq -27.7%, wordfreq -28.9%, html -36.6%, strings -37.8%;
  allocations: html -60%, html_hand -98%, strings -33%; self-compile -0.5% (same input). The verifier gains one arm per instruction;
  `tools/mutate_mir.py` gains three classes for string appends.
- **Verifier: an in/out call demotes its borrowed arguments.** A `Unique` local passed in a borrowed position to an in/out
  function stayed `Unique` after the call, although the callee can keep a counted reference to it in the receiver it hands
  back (`push(items, item)`). The verifier now demotes such arguments, as it already did for calls with a reference result.
  The generated code is unchanged (lowering still emits the `makeunique` before every store); this closes a gap in the
  trusted checker, found while building ADR-0038 T5.
- **Project CLI and terminal UX.** `orin init` (application, library, HTTP template), project discovery,
  content-cached native builds, `dev`/test watch, project-wide formatting and independent test discovery.
  Source diagnostics have themed colors, source excerpts and bounded multiline highlights; compact/JSON,
  LSP and MCP formats remain available. `add`/`remove`/`deps`/`fetch`/`update` support path and Git libraries,
  root lockfiles including transitive commits, offline/locked resolution and rollback on failed adds.
  Release CLI requires Bash 3.2+. Source checkouts can use `./tools/orin`. See `docs/cli.md`.
- **Redundant uniqueness checks removed (ADR-0038 lever 2, T1; `compiler/opt/unique.or`).** A `makeunique` of a local that is
  certainly `Unique` (fresh, or already made unique and not shared since) is deleted. nbody -13.8%, sieve -10.4%, pqueue -8.4%
  executed instructions; only the `cow_inplace` counter changes; the verifier re-checks the result.
- **Scalar stores without the release test (ADR-0038 lever 2, T3), statistics counters as a build option.** `ISetField` /
  `IArraySet` of an `int`, `usize`, `bool`, `float` or handle store directly; the hot `orin_stats` counters are compiled in only
  with `-DORIN_STATS_ENABLED` (implied by `-DORIN_SITE_STATS`; `tools/bench.py` builds a separate counting binary). nbody -21%,
  mutres -17.6% executed instructions.
- **OX member tags on a class name (ADR-0044 §4.5).** `<Ui.Card title="x">..</Ui.Card>`, where `Ui` names a class and no value,
  calls the static method `Ui.Card` with the component rules (attributes by parameter name, slots, `Option` parameters, spread,
  source-order evaluation), for local, imported and generic classes. An instance method there is E0491, a private static
  method outside its class E0405. Member tags on a module are not added: orin has no module values (`import * as m` is E0200),
  so a module's component is imported by name and written `<Card>`.
- **OX roots are built in a pre-sized buffer (ADR-0044).** A markup root with a dynamic piece starts from `str.withCapacity(static bytes + 16 per dynamic piece)` (new builtin, runtime `orin_str_with_capacity`), so the pieces are appended in place without regrowth. `bench/html`: `string_grows` 4.23 M -> 0.25 M, executed instructions 3.99 G -> 3.10 G.
- **Verifier and optimiser without per-block allocations (ADR-0038 lever 1).** The ownership verifier's fixpoint joins
  out-states into the successors in place and replays every block with one reusable `Transfer`; the optimiser's analyses use
  a reusable use buffer and one allocation-free successor walk (`succCount` / `succAt`). Self-compile: -23% allocations,
  -36% COW copies, -3.2% executed instructions; generated code and every verifier verdict unchanged (checked on the corpus
  and all `mutate_mir` mutants).
- **Borrow inference for read-only parameters (ADR-0038 class (d); `compiler/opt/borrow.or`).** A method or function that only
  reads a reference parameter (typically `this`: `Bytes.length`, `Reader.cur`, `isDone`, ...) now takes it borrowed: the caller no
  longer retains the argument and the callee no longer releases it. Interprocedural fixpoint inside the existing parameter-mode
  inference; default deny (stores, moves, returns, mutation, a second retain keep the parameter owned). The verifier is unchanged
  (a borrow of a borrowed parameter was already a rule). Unit tests in `compiler/tests/opt_test.or`.
- **Reuse in place for dying concatenation operands (ADR-0038 class (e)).** `"w" + n.toString()` prepends onto the fresh number string
  (new MIR instruction `IStrPrepend`, runtime `orin_str_prepend`, in place when unique) instead of copying the literal and appending;
  `qs(lo).concat(eq)` extends the dying temporary (`extendArrays`, `d = concat(x, y); release x`). Value semantics unchanged: a shared
  operand is copied by the runtime. See docs/mir.md v2.3.
- **Closure inlining and fusion (ADR-0038 §2; `compiler/fuse`).** A chain of `map` / `filter` stages ended by `map`, `filter`,
  `reduce`, `some`, `every`, `find`, `findIndex`, `forEach`, `includes` or `indexOf`, with pure arrow functions or named
  functions at the call, becomes one loop: no intermediate arrays, no closure objects, closure bodies inlined, early exit, exact
  capacity for a final `map`. Not fused: function values, impure closures, non-simple value arguments, results bound to a
  variable, `sort` (a barrier). Traps: the same (stage, element) pairs are evaluated, so a fused chain traps iff the unfused one
  does; the first of two traps may differ; early exit never hides a trap. `filter -> map -> reduce` over 5 M ints: 3.9x the loop's
  CPU time before, 1.02x after. New flags `--no-fuse` and `--fuse-report`; `tools/diff_backends.py --mode fuse`; programs without
  an array-API call compile to byte-identical code. The rewrite exception "hot loops stay loops" is gone (docs/rewrite.md rule 7).
- **Parallel pipelines (ADR-0039 steps 1-3).** `xs.parallel()` with `map`, `filter`, `reduce`, `some`, `every`, `find`,
  `findIndex`, `toArray`: fixed chunks of 4,096 (bit-identical results for every thread count), fused per chunk by the optimiser,
  run by a new work-stealing fork/join pool in `std:task` (`forkJoin`, `forkJoinUntil`, `parallelism`; `std:taskcore` `Ranges`).
  The input is lent to the workers without a copy (runtime: pinned reference counts; a transfer by another task copies pinned
  objects). New rules: **E0484** (impure or unknown function), **E0485** (reducer not a built-in associative operator), **E0486**
  (input element type not a scalar or flat record of scalars), warnings **W0480** (float reduce) and **W0481** (signed `+` or `*`
  reduce may overflow differently). L0 gains `orin_platform_cpu_count`; `ORIN_THREADS` sets the thread count. Tests:
  `tools/test_parallel.sh` (threads 1..8, fused / unfused, ThreadSanitizer, ASan), now part of `tools/test_concurrency.sh`. No
  speedup could be measured on the loaded shared machine (CPU time unchanged); see docs/benchmarks.md.
- **Fix:** `ORIN_STATS` peak live objects / bytes wrapped to 2^64 - 1 in programs whose tasks free objects other tasks allocated.
- **Compiler rewrite step 3d: `opt/`, `cemit/`, `llvm/` under the contract and class standard** (docs/rewrite.md "Step 3d"). No
  change to the generated C, C with `--check-contracts` or LLVM IR (byte-identical on the corpus and on `compiler/main.or`).
  The code generators now emit every function from a read-only, program-wide symbol table built first in a fixed order
  (`CSymbols`, `LlvmSymbols`) and join the texts in index order (rule 8, new in docs/rewrite.md: ready for ADR-0039
  `.parallel()`); the optimiser's per-function stage is a `map` over the functions after the program-wide parameter-mode
  inference (`ParamInference`). New classes `BlockSink`, `RewritePlan`, `EdgeBlocks`, `RecordAliases`, `ParamInference`,
  `CSymbols`, `CFunctionEmitter`, `LlvmSymbols`, `LlvmFunctionEmitter`; contracts for every pass (well-formedness, signature,
  same calls in the same order, instruction-count claims) and for the emitters (only declared symbols referenced, literals
  round-trip, unique function symbols). **Fixed**: a record or closure with more than 64 slots of which two or more past
  slot 63 hold references crashed the compiler (`trap: usize overflow` in the reference-mask computation of both backends);
  it now compiles and the program traps at run time with the runtime's defined "struct has more than 64 slots".
  Unit tests `compiler/tests/opt_test.or`, `compiler/tests/emit_test.or` (run by `tools/test_tooling.sh`).
- **Benchmark workflow** (`.github/workflows/bench.yml`, docs/benchmarks.md "Benchmark workflow"): nightly, manual, or on a PR
  labelled `bench`. `tools/bench.py` gains `--json` (machine, tool versions, commit; per benchmark and language wall median / min,
  user / sys CPU, peak RSS, output check), `--instructions` (executed instructions under valgrind cachegrind for the Orin
  binaries, C and the self-compile: the regression metric) and a parallel section (`bench/parallel_*`, `bench/streams_parallel`
  with 1, 2, 4 worker threads given as the first program argument: speedup, efficiency, CPU time); new `bench/parallel_collatz`.
  `tools/bench_report.py` (stdlib only) writes the job summary, the PR comparison comment (instructions > +2 % or wall > +15 % is
  flagged, never fails) and the SVG charts + README of the `bench-results` history branch.
- **Rewrite step 3b: the ownership verifier `compiler/verify/`, shared MIR well-formedness, `compiler/hir/` contracts
  (ADR-0015).** The verifier's abstract state is a class `State`, the transfer functions are the methods of a class
  `Transfer` (one run through a block), the fixpoint and its worklist are the class `Fixpoint`; 98 contract clauses (0 before), among
  them: the join is commutative, idempotent and an upper bound in an independently stated lattice order; no instruction
  revives a dead or poisoned local unless it defines it; borrows stay flat; every report names an existing block and
  instruction with its span; the fixpoint is stable; the verifier's well-formedness check implies the shared predicate
  `isWellFormedProgram` (new `compiler/mir/wellformed.or`, also used by the lowering). `hir/`: integer-kind round trip and
  exact ranges, `Function.paramCount <= locals.length`, `CallSite` evidence and edge kinds. 23 unit tests
  (`compiler/tests/verify_test.or`), 12/12 hand-made mutants killed. **Fixed**: four inputs on which the verifier itself
  crashed (`trap: index out of bounds`) instead of reporting ill-formed MIR: a call of a callee with more parameters than
  locals, a closure target or vtable entry with parameters but no locals, a block with fewer spans than instructions; they are
  now rejected with a message. Every other verdict and message is unchanged; generated C / LLVM output is byte-identical.
- **Allocation census (ADR-0038): where the heap allocations and RC operations come from.** Opt-in census build:
  `orin2 compile --stats-sites` marks every MIR instruction with its site id (`ORIN_SITE(n, caller)`) and appends a site table;
  with a runtime built with `-DORIN_SITE_STATS`, `ORIN_STATS=sites` reports per site the objects allocated (string, scalar /
  reference array, record shape), bytes, growths, frees, the retains / releases / COW copies executed there and those its
  objects received, the joint (executing site, allocating site) RC counts and one level of calling context. Without the flag
  nothing changes: generated C and LLVM byte-identical on the corpus, runtime object code identical. `tools/alloc_census.py`
  runs every benchmark, `examples/http_server.or` under a scripted loopback load and the self-compile, attributes each site to the
  ADR-0038 transformation that would remove it (unboxing, packed arrays, escape / stack, borrow, reuse, region / freeze,
  library) and writes docs/perf/alloc-census.md: the ranking for the performance wave and the library quick wins.
- **Rewrite step 3e: the tooling modules `analysis/`, `lsp/`, `mcp/`, `json/`, `fmt/` (ADR-0015) and the capability gate.**
  State that was threaded through records is now five classes: `Workspace` (the document store), `LspServer`, `McpSession`,
  `JsonCursor`, and the formatter's `Layout` (source text and comment queue); 213 contract clauses (35 before), among them the
  JSON round trip (`parseJson(stringifyJson(v))` equals `v`), offset <-> position round trip, the reply rule of the LSP and MCP
  servers (every request answered once with its id), references that point at existing definitions, formatter idempotence and
  comment preservation as `@Ensures` of `format`, OSIG snapshots that read back with their hash. **Capability gate:** `analysis`
  performs no I/O of its own: its three file reads go through the loader's `Sources`, and the drivers of `orin graph` / `diff` /
  `effects` (with their output file) moved to `tools`; `orin effects compiler/main.or` shows only inherited `Fs.ReadFile` /
  `Fs.Stat` for `analysis`, every path ending in `loader::Sources` (pinned by `tools/test_effects.py`). Fixes: `parseJson` reads
  every `int` (it rejected 19-digit integers that `stringifyJson` writes); the effect-policy errors E0474 / E0502 are located in
  `orin.toml` (they were printed as a position in the program's first source file, and the contract-checked compiler trapped).
  Generated C / LLVM unchanged. `lsp::shellRun` stays until `spawn` exists (ADR-0037 D5). Tests: `compiler/tests/tooling_test.or`
  (16 `@Test`). Docs: docs/rewrite.md "Step 3e", docs/capabilities.md.
- **Parser error recovery: several syntax errors per file.** `orin check`, `orin compile`, `--format=json`, the LSP
  diagnostics and MCP `check` now report every syntax error of a file (up to 20; past that the 20th carries the note
  "further syntax errors suppressed") instead of only the first. Recovery points: the next statement of a block (after `;`,
  at the block's `}`, past an `if` / `while` / `for` body, at a statement keyword), the next member of a class or interface,
  the next top-level `function` / `class` / `interface` / `type` / `import` / `export` / `@`; a declaration keyword inside a
  body (a missing `}`) is reported once and the parse resumes there. No cascades: a file with syntax errors is not type
  checked (only its syntax errors are reported, so no node built by recovery reaches the checker), an error at or right
  after a resume point is dropped, running into the end of the file stops. The first error is byte-identical to before for
  every input (code, message, span: a contract of `parseRecovering`, and 3,247 inputs incl. 1,500 garbage files compared);
  valid programs give the same trees and the same C / LLVM output; `orin fmt` still refuses a file with a syntax error. A
  lexical error (E0100) is still the only error of its file. New: `parseRecovering` (syntax module), progress contracts of
  the recovery loops, `compiler/tests/recovery_test.or`, `tests/recovery/` with `tools/test_recovery.py`.
- **Rewrite step 3c: `compiler/syntax/` (ADR-0015).** The lexer is a `Lexer` class (cursor, tokens, template depth) and the
  parser a `Parser` class (tokens and cursor as fields instead of `{ node, pos }` records returned by ~90 functions); binary
  operators are parsed by precedence climbing over a data table (`precedence.or`, class `OpTable`: level, operator,
  associativity per spelling, with an invariant); placement rules of clauses and annotations moved to `rules.or`; new
  well-formedness predicates of tokens (`tokensWellFormed`), trees (`wellformed.or`: spans nested and ordered) and comments.
  129 contract clauses (was 1): every successful `parseX` consumes at least one token and spans exactly what it consumed
  (the progress property), the cursor never passes the final KEof, `parse` ensures a well-formed module or a parse error
  inside the source. 14 unit tests in `compiler/tests/syntax_test.or` (incl. termination on garbage input). Parse errors,
  ASTs and generated code are byte-identical to before; no change to the language. Also: `@Ensures` for the 13 public
  mutating methods of `vc/gen.or` `Gen` and `vc/vt.or` `Tab` that `orin check --strict-contracts compiler/main.or` reported.
- **Concurrency, stage 0 (ADR-0017 Addendum A; docs/concurrency.md).** New module `std:task`, written in Orin: structured
  `scope` / `spawn` / `TaskHandle.join`, bounded `channel<T>(capacity)` with `Sender` / `Receiver` (`send`, `recv`, `close`),
  `parallelMap`, and `scopeFs` / `spawnFs` (also process, stdio, clock) that MOVE a derived grant into a task (ADR-0027 Q10, smallest
  sound form, no new syntax). Tasks are isolated threads with their own heaps: a value crossing a task boundary is moved if its
  whole graph is uniquely owned, else deep-copied; reference counts stay non-atomic; a panic in a task is a trap of the joiner
  (`task panicked: <message>`), at `join` or when the scope ends, never lost. Layers: scheduler bookkeeping, channel buffers, join
  results and scopes are Orin (508 code lines in `std:task` and the pure `std:taskcore`, 8 invariants, 26 contract clauses, a 16-mutant check); **L0 (C, forever)** gains thread create / join /
  exit and handle-checked monitors (mutex, two condition queues, integer words), +243 code lines, L0 total 700 of 1,000 (the
  budget now counts code lines, not comments or contracts, ADR-0030); **runtime C (temporary, 342 code lines)** is one
  interface, `orin_rt_transfer_*` / `orin_rt_task_*` / `orin_rt_heap_exit`, with a 1:1 porting table to Orin R3 functions
  (docs/concurrency.md, ADR-0017 Addendum A). Runtime made thread-safe: per-task free lists, counters, work stack, grant and file
  tables (`ORIN_STATS` adds `transfer_moves`, `transfer_copies`, `tasks_spawned`), immortal singletons published by compare-and-swap,
  the stdout buffer locked, grant handles carry the owning task. Compiler: one builtin `BTask(k)`; checker rules **E0481** (task
  body captures a `Scope`), **E0482** (`channel(0)`), **E0483** (task body captures a resource handle); MIR v2.1 (`grantClone`
  opener, `grantMove` closer, `grantAdopt*` opener: a handle moves exactly once on every path; 14 verifier cases); OSIG events
  (`Task.Spawn` / `Task.Join` CONTROL, `Channel.Send` OUTPUT, `Channel.Receive` INPUT). Tests: 10 run + 5 error conformance programs
  (all backend modes), 10 `@Test` + 4 expect-trap, stress tests (3,000 live tasks, 40,000 messages), C tests, everything under
  ThreadSanitizer and ASan + UBSan (`tools/test_concurrency.sh`). Example `examples/parallel_map.or`. Assurance: the C parts are
  `TESTED_ONLY` (ThreadSanitizer, no proof) until R3 / R4 (docs/assurance.md C17). Not in stage 0: `async` / `await`, cancellation,
  timeouts, deadlock detection, an M:N scheduler, a concurrent HTTP server (`std:net` has not landed).
- **Performance defects of the std fixed** (docs/benchmarks.md "Performance defects found while building the std"): `x = x + e` /
  `x = x.concat(e)` on fields, elements and nested places are in-place (take/put of the slot, new MIR instruction `IArrayExtend`;
  74 s -> 13 ms on bench/appends); mutating methods with a result no longer allocate a pair or copy a field receiver (MIR v1.10 in/out
  receivers, `compiler/opt/pairs.or`; call loops 8-13x, std:http parse 2x); built-ins `bytesToString(u8[], start, len)` and
  `stringToBytes(s)` (std:bytes / std:http use them: 8x); verifier definitions no longer scan all locals; LLVM `noundef` / `nonnull`.
  New benchmarks (appends, mutres, bytesstr, http_parse, sortedmap, pqueue), Rust and Java counterparts in tools/bench.py.
- **Capabilities, Stage B: transitive effect inference (ADR-0037 D2, graph 2; no new syntax).** The compiler now infers, for
  every function, method and constructor, the set of primitive effects it may perform *transitively* (`Fs.ReadFile`,
  `Console.Write`, `Process.Spawn`, `Clock.Now`, ...; direction INPUT / OUTPUT / CONTROL; grant family), with evidence (MUST: a
  primitive call in the body; MAY: inherited, in a closure, through an implementation; UNKNOWN: unknown target, never pure)
  and the shortest call chain that explains it. A sound over-approximation: closures are accounted for the function that creates
  them, a call of a parameter makes the function parametric in it (so `useHost(host, callback)` is precise), an interface call
  is the union over all implementations (`Unknown.Interface` without any), a function value of unknown origin is
  `Unknown.FunctionValue`, recursion is a fixed point. Agrees with the purity analysis (a function with an effect is impure;
  a contract ties the two builtin tables). **One engine** (`compiler/analysis/effects.or`) for: `orin effects <entry|package>
  [--format=json] [--summary] [--module M] [--function F] [--no-paths] [--check-purity]` (entry point, package, module and
  function summaries with paths); OSIG **`osig/0.2`** with the `MAY_PERFORM` edge (and the edge field `next`; 0.1 readers
  keep working, `PERFORMS_IO` stays); `orin diff` (`osig-diff/0.2`) sections for new and removed effects per function and
  module with the explaining path and the entry points that reach a new effect; the LSP hover and the MCP `inspect` result
  show the summary. **Effect policy** (prepares ADR-0037 D4): `[effects] allowed = [...]` / `[effects.<module>]` in `orin.toml`;
  a module whose inferred effects exceed its allowance is **E0473** (explanation path in the notes), **E0474** unknown effect
  name, **E0502** for a table of a missing module; absent configuration means no restriction. Semantic index: `CallSite` gets
  `param` / `fnArgs`, `SemanticIndex` gets `fnDefs` / `fnKinds` / `typed` (no behaviour change of the checker or the generated
  code; the C of every program is byte-identical). The compiler's own summary: `syntax`, `package`, `check`, `lower`, `mir`,
  `opt`, `verify`, `cemit`, `llvm`, `fmt`, `json`, `diag`, `hir` are pure; file, stdio and process effects are only in `loader`
  (`Sources`), `analysis`, `tools`, `lsp`, `mcp`, `testing`, `vc` and the driver, nothing is UNKNOWN (docs/capabilities.md).
  Findings: the only `shell` call is `lsp::shellRun`, imported by `testing`, `vc` and `mcp`; `analysis` reaches the file
  system in three places. Docs: new docs/capabilities.md, docs/osig.md, docs/mcp.md, ADR-0023 addendum.
  Tests: `compiler/tests/effects_test.or`, `tools/test_effects.py` (goldens `tests/osig/effects/`), LSP / MCP / OSIG /
  capability tests.
- **Rewrite step 3a: `compiler/lower/` and MIR source spans (ADR-0015, ADR-0020 D3).** HIR -> MIR lowering is now a `Lowerer`
  class per function with a `BlockBuilder`, a `Locals` table and an `OwnedScope` (97 contract clauses, 15 unit tests in
  `compiler/tests/lower_test.or`), split into `lowerer` / `builder` / `state` / `ops` / `place` / `values` / `wellformed`.
  **MIR v2.0**: every instruction and terminator carries the span of the HIR node it was lowered from
  (`MBlock { instrs, spans, term, termSpan }`, `noSpan()` for hand-written MIR); the optimiser keeps them; the text format
  of `orin mir` gains ` @file:start-end` per line (the verifier driver, `tools/mutate_mir.py` and the Lean differential
  test accept it); `orin verify` / `orin compile` report an ownership error as `verify error: f b0 i2 at path:line:col: ..`.
  C and LLVM output are byte-identical to before (spans are never emitted). No change to the language.
- **`std:net`: blocking TCP, and an HTTP server on `std:http` (ADR-0033).** New L0 functions (`tcp_listen`, `tcp_accept`,
  `tcp_connect`, `stream_recv`, `stream_send`, `net_shutdown`, `net_close`, `net_narrow`, `dns_resolve`,
  `monotonic_millis`; 685 code lines for the whole layer, budget now counted in code lines without contracts and comments, ADR-0030 §1),
  each with a contract; handle identity, scope and `ORIN_DENY=net` are checked before any system call (EPERM); CBMC harnesses for
  the recv / send buffer bounds, "narrowing never widens" and "refused before any syscall" (found and fixed: an errno of 0 could make
  a failed recv look like success). New `NetGrant` / `Listener` / `Stream` resources, `useNet`, `useListen`, `useConnect`, `std:net`
  (`useListener`, `useAccepted`, `useConnection`, `recv`, `sendAll`, `StreamReader.readExact/readUntil`, `resolve`, deadlines,
  half-close), 16 internal built-ins re-checked by the MIR verifier, OSIG `Net.*` / `Stream.*` effects, E0470 / E0471 for every
  function whose first parameter is a grant. `examples/http_server.or`; `tools/test_net.sh` (Linux and macOS CI): curl and raw-socket
  checks, a slowloris client cut off by the deadline, narrowed-scope refusals from an Orin client, `ORIN_DENY=net`. One connection
  at a time until tasks exist (ADR-0017).
- **Contract verifier, bigger fragment (ADR-0031 B6-B9, C11-C12; ADR-0036).** `orin verify --contracts` now encodes arrays
  (length, index with a bounds obligation, push/pop/slice/element writes), records and classes (fields, `{ ..r, f: v }`),
  `Option` / `Result` / unions with `match`, `Map` (size, membership), every integer width with its exact range, strings by
  length, and generic functions and classes (type parameters are opaque). Modular verification: a callee `@Requires` is an
  obligation at the call (`FIX_CODE`), its `@Ensures` is assumed, pure functions are uninterpreted functions, recursion assumes
  the function's own contract. Class invariants are proved per public mutating method and constructor (`inv && requires ==>
  inv'`; a breaking method is REFUTED with `NEEDS_DECISION` and the three options); frames come from the mutation analysis,
  no annotations. Loops: user `@Invariant` (existing ADR-0012 syntax, proved on entry and per iteration), inferred counter
  bounds, otherwise havoc with UNKNOWN "loop without invariant" / `STRENGTHEN_SPEC`; the first three iterations are also
  unrolled exactly so wrong claims after loops are REFUTED. Bounded quantifiers: `xs.every/some(pure lambda)` and
  `range(a, b).every/some` become forall/exists; `sum`/`sumBy` are axiomatised by a recursive SMT function. New std module
  `std:seq` (`range`, `sum`, `sumBy`), no grammar or checker change. New result kinds `bounds`, `unwrap`, `invariant`,
  `loop-invariant`; every VERIFIED lists its assumptions (A-INT, A-DIV, A-PARTIAL, A-CALL, A-PURE, A-INV, A-FRAME, A-LOOP,
  A-STR, A-MAP). Soundness: a REFUTED needs a model on a path with no abstraction (loop havoc, uninterpreted call results,
  derived string contents, Map size make a model untrusted, UNKNOWN). Found and fixed during development: F-vc1 (a datatype
  well-formedness axiom made everything VERIFIED; docs/assurance.md). Measured on `compiler/` (444 results): before 0 VERIFIED /
  0 REFUTED / 117 UNKNOWN, after 163 / 1 / 280; `std:bytes` 1V/8U before, 80V/0R/71U after; `std:utf8` 3V/34U before,
  60V/0R/37U; `std:collections` 0V/8U before, 215V/2R/286U after (generics); `std:seq` 7V/0R/1U (new). REFUTED, all listed and not changed: `boundOf` (compiler/check/env.or, missing precondition) and, in std:collections,
  `Deque.slot` / its call in `Deque.grow` (the private method's contract omits `head < buf.length`). Small spec gaps fixed with contracts, no behaviour change: `mkTok`, `entrySpan`, `sigText`, `TScope`
  constructor, `TomlEntry` invariant. The contract-checked compiler now also runs the verifier tests. Tests:
  `tests/contracts/verify_*.or`, `tests/std/seq_test.or`, `tools/test_verify_contracts.py` (809 checks).
- **Capabilities, Stage A (ADR-0021 addendum, ADR-0027).** Standard I/O now needs a *grant*. Programs that do I/O are
  `function main(host: Host): void`; `Host` and every grant (`FsGrant`, `ProcessGrant`, `StdioGrant`, `ClockGrant`) are
  resource handles with the rules of `File` (only a parameter; E0450-E0452; the MIR verifier re-checks). Grants are derived
  by the scope functions of the new `std:host` (`useHost`, `useFs`, ...) and narrowed without amplification
  (`useUnder(fs, dir, ...)`, `useReadOnly`, `useArgsOnly`). **Breaking (std I/O is unstable):** `readFile(fs, path)`,
  `writeFile(fs, ..)`, `exists(fs, ..)`, `withFile/useFile/withFiles/useFiles(fs, ..)`, `args(proc)`, `shell(proc, cmd)`,
  `readLine(stdio)`, `readBytes(stdio, n)`, `writeStdout(stdio, s)`, `nowMillis(clock)`; `main()` without `host` has no I/O
  authority (E0470); new errors E0470 (missing grant), E0471 (wrong family), E0472 (`main` takes another grant);
  `@Test` functions may take `host: Host`. `console.log` / `console.error` / `exit` stay grant-free (ambient; recorded as
  OSIG events). Runtime: tagged, generation-checked grant table; host policy `ORIN_DENY=fs,process,stdio,clock,net,all`
  (a malformed value traps at start; a denied `Result` operation is `Err`, every other operation traps); path scopes
  compare normalised absolute paths and resolved symbolic links and open the checked path; the compiler itself takes its
  grants from `main(host)`. L0 platform: `orin_platform_policy_*`, `orin_platform_path_*` with contracts, tests and CBMC
  harnesses. MIR v1.9 (`BGrant*` builtins, grants first in every std I/O builtin). OSIG: `PERFORMS_IO` edges to `Effect`
  nodes (primitive call sites only). Seed refreshed through a bridge compiler (ADR-0027, "Bootstrap note"). Not covered:
  TOCTOU, hard links, mounts, `shell`, native code. Open questions for the owner: ADR-0027.
- Provable std layer 1 (ADR-0030 §3): new pure-Orin modules `std:bytes` (`Bytes`, `ByteBuilder`, `ByteReader`),
  `std:utf8` (validated decoding, `Utf8String`, `CodePointCursor`) and `std:collections` (`IntSet`, `StringSet`,
  ring `Deque<T>`, B-tree `SortedMap<V>`/`SortedStringMap<V>`, 4-ary `PriorityQueue<T>`), every class with invariants and every method
  with contracts; `tools/test_std.sh [--mutate]`, `tests/std/`. Registered in `compiler/loader/resolve.or`; docs/std.md.
- `std:http` (ADR-0030 §3, the pure part; no sockets): HTTP/1.1 `Request`/`Response`/`Headers`/`Status`, an incremental
  request parser and response parser (`feed(chunk)` answers `NeedMore | Done(message, used) | Failed(HttpError)`; refuses
  request-smuggling ambiguities: Content-Length with Transfer-Encoding, duplicate Content-Length, obs-fold, bare LF/CR,
  whitespace before the colon, chunk-size overflow; limits as parameters; explicit state machine) and a serializer with
  the round-trip contract `parse(serialize(m)) == m`; header injection is impossible by construction. Registered like
  the layer-1 modules (`compiler/loader/resolve.or`), `tests/std/http_*_test.or`, 41 mutants in `tools/mutate_std.py`,
  `tests/std/bench/http_bench.or`; docs/std.md.
- Stronger invariants, part A (ADR-0031 A1-A5), under `--check-contracts` and in the checker:
  - a violated contract prints a power-assert style report: the clause, the function and its argument values, the
    value of every maximal non-literal operand of the clause (ints, bools, floats, quoted and truncated strings,
    array lengths, `<Type>` otherwise), the `old(..)` values, then blame and action (ADR-0029): a failed
    `@Requires` is `FIX_CODE (caller)` with the call's `file:line`, a failed `@Ensures` / `@Invariant` is
    `NEEDS_DECISION` with a question and options. The first line and exit status 101 are unchanged;
  - record `@Invariant`s are enforced at every record literal, field write (also through nested records, array
    elements, `push` / `pop` on a field) and function result of the record type (docs/contracts.md lists exactly
    which points);
  - purity is inferred over the call graph (fixed point, recursion allowed): contracts may call pure functions and
    pure closures, including `every` / `some` / `map` / `filter` with a pure lambda; E0416 stays for impure ones,
    with a message that names the impure operation and its `file:line:col`;
  - calls inside a contract go to the unchecked body, so a clause that calls its own function (or an invariant that
    calls a public method) terminates; it used to recurse without end;
  - the test runner matches `// stderr:` against the compiler's output for error tests;
  - compiler: `compiler/check/rthir.or` (HIR pass behind `--check-contracts`), the purity inference in
    `compiler/check/purity.or`, the prune pass also drops unreferenced lifted closures (erased clause closures leave
    no trace); `allNormalized`, `allRenderable`, `allWellFormed`, `allWarnings`, `anyStrictCode`, `allUnbound`,
    `allUnitsWellFormed` now use `every` / `some`. **The seed was refreshed** (`tools/update_seed.sh`), because the
    compiler sources now call pure closures in contracts, which the previous seed rejected (ADR-0014).
- Contract-quality diagnostics (ADR-0028): warnings W0450-W0452 (invariant without `this`, `@Ensures` that cannot
  fail, trivially true contracts), solver-based W0460-W0462 in `orin verify --contracts`, opt-in strict coverage
  W0470/W0471 (`--strict-contracts`, `[contracts] strict = true`), and `tools/contract_mutation.py` (contract
  strength by mutation). `orin verify --contracts` results carry the ADR-0029 fields `action`, `question`,
  `options`, `candidates`, `evidence`.

## 0.1.0-alpha.2 (2026-10-13)
Language 1.0 core complete and frozen (ADR-0016; std I/O stays unstable until capabilities, ADR-0021).
- Generic classes (ADR-0026, ADR-0016 "Generic classes"): `class Box<T>`, `new Box<int>(1)` / inferred `new Box(1)`,
  several type parameters, nesting, bounds `class C<T extends I>` (ADR-0019), `implements` of non-generic
  interfaces, contract clauses per instantiation, cross-module use; monomorphised per instantiation by lowering to
  generic records and functions (no HIR/MIR/backend change, MIR stays v1.8); mutation inferred once, equal for all
  instances and shown in hover / `orin api` / MCP / OSIG (`Program.mutating`). OSIG: one node per generic
  declaration. New errors E0460 (generic methods, post-1.0) and E0461 (static method uses a class type
  parameter). `std:graph` is rewritten as `class Graph<T>` (generational, tagged ids, stale/foreign ids are `Err`);
  the functional API is removed. Fix: `?` in a mutating method that returns a Result no longer crashes.
  The language-freeze prerequisites are complete.
- Defence in depth against shape confusion (docs/assurance.md F-shape): every struct/variant slot access (`orin_struct_get/set/slot_ptr`, `orin_mir_struct_take/replace`, `orin_struct_copy_slot`, LLVM `@orinl_slot`) checks that the object is a struct and the index is below its slot count, array slot access and push check the object kind; a mismatch traps with exit 101 (`trap: field access on a value of the wrong shape (compiler bug)`) instead of reading or writing out of bounds. Initialising stores into a fresh `orin_struct_new` use the unchecked `orin_struct_init`. Measured cost in docs/benchmarks.md. New regression test `tests/next/run/shape_confusion_try_in_mutating_method.or`; new P0 proof-debt item: MIR shape/type check in the verifier.
- OSIG (ADR-0023, docs/osig.md): `orin graph <entry|package-dir> [-o out.json]` exports the deterministic
  Orin Software Intelligence Graph (schema `osig/0.1`: packages, modules, functions, methods, classes,
  interfaces, types, fields, variants, contract clauses; edges `DEFINES`, `IMPORTS`, `CALLS` with
  `MUST`/`MAY`/`UNKNOWN` evidence, `IMPLEMENTS`, `HAS_FIELD`, `REFERENCES_TYPE`, `HAS_CONTRACT`; stable ids,
  source spans, snapshot hash). `orin diff --base --head [--format=text|json|html]` compares two snapshots:
  changed/added/removed symbols, added/removed edges, heuristic rename candidates, reverse impact with the
  explaining path from entry points; the HTML report is one self-contained file. MCP tools `graph` and
  `diff`. `SemanticIndex` gains `calls` (call sites from the typed HIR). CI uploads the diff report of a
  pull request as an artifact (report only). `orin api --check` is unchanged.
- Built-in annotations (ADR-0024, spec 05; compiler built-ins only, any other `@Name` is still E0408):
  `@Test` on top-level `void` functions with `orin test <file|dir> [--filter S] [--format=json]` (one
  executable, one process per test, PASS/FAIL per test, stable JSON, MCP `test` with `unit: true`) and
  the new `std:test` module (`assert`, `assertEq`, ...); `@Test` functions are type-checked but erased from
  ordinary builds (byte-identical output). `@Deprecated("message")` gives warning W0440 on uses (text, JSON
  `severity:"warning"`, LSP severity 2 + Deprecated tag, hover, `orin api --check`). `@Inline` becomes
  `static inline` (C) / `alwaysinline` (LLVM); a recursive `@Inline` function is E0444. New errors
  E0440-E0445, formatter, VS Code grammar. See docs/testing.md.
- Resources and streaming `std:fs` (ADR-0025, ADR-0016 "Resources"): `File` is a non-copyable handle that can only be a
  function parameter; scope API `withFile` / `useFile` / `withFiles` / `useFiles` (`std:fs`, unstable until capabilities)
  with `readLine`, `read`, `readAll`, `write`, `writeLine`, `flush`; errors E0450 (resource inside another type /
  variable / result), E0451 (handle used as a value), E0452 (captured by a closure). MIR v1.8: `MHandle` with a linear
  open/close discipline in the verifier; platform stream primitives with contracts; runtime handle table.
- Packages (ADR-0016, spec 04): `orin.toml` manifest (`[package]`, `[architecture]`,
  `[modules.<path>] allowed_dependencies`), enforced by the loader (E0501 disallowed import, E0502
  unknown module, E0500/E0503 manifest errors); `orin check|compile|build|run <package-dir>`;
  `orin check --deps` (module dependency summary); `orin api [--check <snapshot>]` (public API
  snapshot and change detection); MCP `inspect` module shows the manifest rule.
- Floats (`float`, `f32`), `std:math`, built-in `Map<K, V>` (ADR-0018). Float programs link with `-lm`.
- Fixed-width integers (ADR-0022): `i8 i16 i32 i64 u8 u16 u32 u64 isize usize` (`int` = `i64`); literals adopt the expected type (E0430 when they do not fit; `u64` literals up to 2^64-1), no implicit conversions, explicit `toI32()` etc. that trap when the value does not fit, `wrapping*` / `checked*` / `saturating*` `Add`/`Sub`/`Mul`, `parseI32` etc., overflow / division traps at every width, usable as array elements, record fields, Map keys, generics, closures. `i128` / `u128` are rejected with E0431 (deferred, see the ADR).
- Template-literal interpolation (ADR-0022): `` `Hello ${name}, you are ${age}` `` with TypeScript lexing (escapes, nesting, multi-line); `string`, integer, `float`, `f32` and `bool` interpolate implicitly, other types are E0432; lowered to one append chain; formatter prints templates verbatim; LSP resolves identifiers inside `${}`; VS Code grammar highlights templates. New diagnostics E0430, E0431, E0432. MIR v1.6 (no new type; `OUsize` is a 64-bit pattern).
- Std modules in Orin (ADR-0016): `std:path`, `std:json` (integers only), `std:time` (new built-in `nowMillis`), `std:graph`; see docs/std.md.

## 0.1.0-alpha.1 (2026-10-13)
First experimental release of the self-hosted Orin compiler.
- Self-hosted compiler (Orin), reproducible bootstrap (stage2 == stage3).
- Language: Orin-B core, generics, classes with value semantics.
- Pipeline: HIR → MIR → independent ownership verifier → C; owned-parameter inference and
  last-use moves.
- Tooling: `orin check --format=json`, `orin fmt`, `orin lsp`, VS Code extension.
- Formal: Lean model of the RC memory machine; soundness of the MIR ownership checker for the
  structured core (`check_sound`). Not end-to-end verified.
