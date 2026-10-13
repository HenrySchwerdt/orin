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
| Contract clauses (ADR-0012): parse/check/erase, runtime checks, SMT for pure functions | in progress |
| Packages: `orin.toml`, architecture rules, API snapshots | done |
| std:path/json/time/graph | done |
| Interfaces (ADR-0019) | integrating |
| Integers, interpolation, annotations (spec 05), resources, capabilities (ADR-0020/0021) | not started |
| Concurrency (ADR-0017), incremental analysis | not started |
| OSIG / `orin graph` / `orin diff`, effects, lineage, `.orcert` (ADR-0020) | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | not started |

## Next milestones
See [`roadmap.md`](roadmap.md) (integrated plan, including the verifiable-software tracks of
ADR-0020) and [`tcb.md`](tcb.md) (what every guarantee currently trusts).
1. Interfaces + contract clauses phase 1 merged; OSIG/`orin graph`/`orin diff` started in parallel.
2. Fixed-width integers, interpolation, `@Test`, resources, capability handles (ADR-0021) → freeze.
3. Compiler rewrite with the full language and MIR source spans (ADR-0015).
4. v0.1.0-alpha.2 with closures, floats, maps, interfaces, std modules.
