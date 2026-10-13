# Progress

_Updated: 2026-10-13_

## Current stage: self-hosting alpha
- Self-hosted compiler (`compiler/`, Orin-B) bootstraps: Stage 0 → orin1 → orin2 → stage3,
  `stage2.c == stage3.c`; in CI (`tools/bootstrap.sh`).
- Default pipeline: parse → load → check → **HIR → MIR → ownership verifier → C**. The verifier
  gates every compile (ICE exit 70 on failure); the legacy HIR → C path remains for
  differential testing (`--legacy-codegen`, `tools/diff_backends.py`).
- Test status (all in CI, also under ASan/UBSan): 138 default conformance tests (Stage 0 and
  orin2), 60 `tests/next` tests (orin2), 753+ parser differential files, 875 formatter checks,
  67 verifier unit cases, JSON/analysis/LSP unit tests, VS Code grammar tests, Lean proofs.

## Capability matrix (self-hosted compiler)
| Area | Status |
|---|---|
| Orin-B core (functions, records, unions, match, Option/Result/`?`, arrays, strings, modules) | done |
| Generics (functions, records, unions, aliases; monomorphised, ADR-0007) | done |
| Classes (ADR-0009) | in progress |
| MIR + independent ownership verifier (docs/mir.md) | done; verifier gates compile |
| Owned params / last-use moves / RC cancellation (ADR-0010) | in progress |
| Formal model (Lean): RC machine safety + COW lemma | done (partial, docs/formal.md) |
| Formal link verifier ⇒ machine safety | in progress |
| `orin fmt`, `check --format=json` | done |
| LSP core (pure), JSON lib, analysis facade, VS Code extension + grammar | done |
| Live `orin lsp` (stdin), semantic index (definition/hover/references/rename) | in progress |
| Benchmarks + runtime stats (docs/benchmarks.md) | done; Orin 1.1–2.7× C |
| Closures, floats, maps, interfaces, annotations, MCP, LLVM backend | not started |

## Next milestones
1. Classes + owned-param optimisation merged; benchmarks re-measured.
2. Live LSP with navigation; then MCP (`orin mcp`) on the same analysis API.
3. Closures/lambdas + std array API (`map`/`filter`/…), floats, `Map<K,V>`.
4. Seed C file so the compiler source may use features beyond Orin-B (ADR pending).
5. LLVM IR backend from MIR (ADR-0006).
