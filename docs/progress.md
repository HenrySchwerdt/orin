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
| Contract clauses (ADR-0012): parse/check/erase, runtime checks, SMT for pure functions | done: phase 1 + phase 2 for int/bool functions (`orin verify --contracts`, z3; see docs/contracts.md) |
| Packages: `orin.toml`, architecture rules, API snapshots | done |
| std:path/json/time/graph | done |
| Interfaces (ADR-0019) | done |
| Fixed-width integers (`i8`..`u64`, `isize`, `usize`; 128-bit deferred, E0431) and template-literal interpolation (ADR-0022) | done |
| Built-in annotations `@Test` (`orin test`, `std:test`), `@Deprecated`, `@Inline` (ADR-0024, docs/testing.md) | done |
| Resources (`File`, ADR-0025): checker + verifier rules, scope API, streaming `std:fs` (unstable until capabilities) | done |
| Compiler rewrite with the full language (ADR-0015, docs/rewrite.md): `diag` + `loader` (step 1), checker foundation `check/{env,fnctx,types}` (step 2a: Map-based symbol tables / instance indexes, `Scope` class) | in progress (rest of `check`, lower / opt / verify, backends, tooling: not started) |
| Capabilities (ADR-0020/0021) | not started |
| Concurrency (ADR-0017), incremental analysis | not started |
| OSIG: `orin graph`, `orin diff`, static HTML report, MCP `graph`/`diff` (ADR-0023, docs/osig.md) | done (phase 1 MVP: symbols, calls with MUST/MAY/UNKNOWN evidence, imports, implements, type refs, contracts) |
| Feature manifest, effects, lineage, `.orcert` (ADR-0020) | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | not started |

## Next milestones
See [`roadmap.md`](roadmap.md) (integrated plan, including the verifiable-software tracks of
ADR-0020) and [`tcb.md`](tcb.md) (what every guarantee currently trusts).
1. Interfaces + contract clauses phase 1 merged; OSIG/`orin graph`/`orin diff` started in parallel.
2. ~~Fixed-width integers, interpolation~~ (done, ADR-0022), ~~`@Test`/`@Deprecated`/`@Inline`~~ (done, ADR-0024), ~~resources~~ (done, ADR-0025), ~~generic classes~~ (done, ADR-0026: all language-freeze prerequisites are in; the language freeze and the compiler rewrite of ADR-0015 can start); capabilities (ADR-0021) → std I/O freeze.
3. Compiler rewrite with the full language and MIR source spans (ADR-0015): steps 1 and 2a done; next 2b/2c (`body.or`), then the other checker files, lower / opt / verify, backends, tooling.
4. v0.1.0-alpha.2 with closures, floats, maps, interfaces, std modules.
