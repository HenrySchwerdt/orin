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
| Seed bootstrap (ADR-0014) | in progress |
| Floats + Map<K,V> | in progress |
| Runtime R2: platform layer with contracts | in progress |
| Contract clauses (ADR-0012): parse/check/erase, runtime checks, SMT for pure functions | in progress |
| Interfaces, annotations (spec 05), concurrency, packages, incremental analysis | not started |
| Runtime R3/R4 (object model in Orin, refinement proofs) | not started |

## Next milestones
1. Seed bootstrap merged → compiler source may use generics/closures/classes; then the
   compiler modernisation with contract dogfooding (ADR-0015), module by module.
2. v0.1.0-alpha.2 with closures, floats, maps.
3. Runtime R3 (core dialect, object model in Orin) and refinement proofs.
4. Contract verification beyond pure functions; interfaces; concurrency design (spec 12 #5).
