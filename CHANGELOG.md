# Changelog

## Unreleased
- **Benchmark workflow** (`.github/workflows/bench.yml`, docs/benchmarks.md "Benchmark workflow"): nightly, manual, or on a PR
  labelled `bench`. `tools/bench.py` gains `--json` (machine, tool versions, commit; per benchmark and language wall median / min,
  user / sys CPU, peak RSS, output check), `--instructions` (executed instructions under valgrind cachegrind for the Orin
  binaries, C and the self-compile: the regression metric) and a parallel section (`bench/parallel_*`, `bench/streams_parallel`
  with 1, 2, 4 worker threads given as the first program argument: speedup, efficiency, CPU time); new `bench/parallel_collatz`.
  `tools/bench_report.py` (stdlib only) writes the job summary, the PR comparison comment (instructions > +2 % or wall > +15 % is
  flagged, never fails) and the SVG charts + README of the `bench-results` history branch.
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
