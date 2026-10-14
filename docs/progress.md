# Progress

_Updated: 2026-10-13_

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
| Compiler rewrite with the full language (ADR-0015, docs/rewrite.md): `diag` + `loader` (step 1), checker foundation `check/{env,fnctx,types}` (step 2a: Map-based symbol tables / instance indexes, `Scope` class), expression and statement checker `check/body.or` split into `fnctx` / `ops` / `match` / `call` / `lift` / `hirok` / `expr` / `stmt` (step 2b: classes `FnCtx`, `ExprChecker`, `StmtChecker`, `Coverage`, `Inference`; 230 contract clauses; byte-identical output), `lower/` (step 3a: class `Lowerer`, `BlockBuilder`, `Locals`, `OwnedScope`; 97 contract clauses; **MIR source spans**, ADR-0020 D3, MIR v2.0; byte-identical C / LLVM output), `syntax/` (step 3c: classes `Lexer`, `Parser`, `OpTable`; precedence climbing over an operator table; AST well-formedness predicates; 129 contract clauses; parse errors and generated code byte-identical) | in progress (remaining `check` files, opt / verify, backends, tooling: not started) |
| Capabilities, Stage A (ADR-0021, ADR-0027): `main(host: Host)`, grants as resource handles, narrowing, `ORIN_DENY`, path scopes, `PERFORMS_IO` OSIG edges | done; std I/O signatures await the owner's freeze confirmation. **Stage B done** (transitive effect inference, `orin effects`, OSIG `MAY_PERFORM`, `[effects]` policy; docs/capabilities.md). Stages C-D (library adapters, lineage, strict policy gates) not started |
| Concurrency (ADR-0017), incremental analysis | not started |
| OSIG: `orin graph`, `orin diff`, static HTML report, MCP `graph`/`diff` (ADR-0023, docs/osig.md) | done (phase 1 MVP: symbols, calls with MUST/MAY/UNKNOWN evidence, imports, implements, type refs, contracts) |
| Feature manifest, effects, lineage, `.orcert` (ADR-0020) | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | not started |

## Next milestones
See [`roadmap.md`](roadmap.md) (integrated plan, including the verifiable-software tracks of
ADR-0020) and [`tcb.md`](tcb.md) (what every guarantee currently trusts).
1. Interfaces + contract clauses phase 1 merged; OSIG/`orin graph`/`orin diff` started in parallel.
2. ~~Fixed-width integers, interpolation~~ (done, ADR-0022), ~~`@Test`/`@Deprecated`/`@Inline`~~ (done, ADR-0024), ~~resources~~ (done, ADR-0025), ~~generic classes~~ (done, ADR-0026: all language-freeze prerequisites are in; the language freeze and the compiler rewrite of ADR-0015 can start); capabilities (ADR-0021 Stage A, ADR-0027: done) → std I/O freeze (owner decision, open questions in ADR-0027).
3. Compiler rewrite with the full language and MIR source spans (ADR-0015): steps 1, 2a, 2b, 3a and 3c done (3a added MIR source spans, ADR-0020 D3; 3c the lexer and parser); next the remaining checker files (`collect`, `decls`, `classes`, `index`, ...), then opt / verify, backends, tooling.
4. v0.1.0-alpha.2 with closures, floats, maps, interfaces, std modules.
