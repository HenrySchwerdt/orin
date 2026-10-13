# 18 — Developer Tooling and the Shared Semantic Engine

**Status:** RFC v0.1 (2026-10-13). Relates to `09` (one semantic service library), `10` (MCP),
`04` (modules), `06/07` (memory analysis, verification), `14–17` (contracts, semantic change,
feature-first review). Design rationale: `docs/decisions/0008-shared-semantic-engine.md`.

## 1. Principle: one semantic engine

The compiler, `orin lsp`, `orin mcp`, `orin fmt` and future verification/review tools MUST use the
same lexer, parser, module loader, name resolution and type checker. No tool may carry its own
parser or checker. Tools consume the engine through an **analysis API** (`compiler/analysis/`)
that is usable without code generation or a native build.

The analysis API exposes (P = priority, see §6):

| Facility | Content | P |
|---|---|---|
| Syntax | AST with byte spans; comments/trivia for formatting | P1 |
| Diagnostics | stable code (`E0400`), span, message, notes; deterministic ordering | P1 |
| Symbols | definitions (name, kind, module, span, signature/type) | P1 |
| References | every resolved identifier use → definition | P1 |
| Types | type of every expression span; signatures of functions/variants | P1 |
| Modules | unit graph, exports/public API, dependency edges, boundary violations | P1/P3 |
| Incremental | per-file input revisions, dependency tracking, invalidation | P3 |
| Memory | per-function MIR summary: allocations, RC ops, COW sites, verifier status | P4 |
| Contracts/verification | contract IDs, proof status, evidence links (spec 14–17) | P4 |

## 2. Analysis model

- **Inputs** are *file contents keyed by path* (an overlay map). Editors supply unsaved buffers;
  missing entries fall back to disk. Every input change bumps a **revision** number.
- **Queries** are pure functions of inputs: `parse(file)`, `load(entry)`, `check(program)`,
  `index(program)`, `lower(program)`. Results carry the revision they were computed at; a client
  never sees a result older than its last edit (stale-result avoidance).
- **Phase 1 (now):** recompute the whole program on change. Orin-B programs including the
  compiler itself check in ~50 ms, so whole-program recomputation is sufficient.
- **Phase 2 (P3):** memoised, dependency-tracked queries per unit (rust-analyzer/salsa style):
  re-parse only edited files; re-check only units whose imported public API changed (module DAG,
  spec 04). Cancellation: long requests check a revision counter between units and abort if a
  newer edit arrived.
- Error tolerance: parsing and checking continue past errors where feasible so that
  definition/hover work in files with unrelated errors (incrementally improved; Phase 1 may
  answer from the last good analysis of a file).

## 3. Tools

### `orin check` (P1)
Type-check without code generation. `--format=json` emits one JSON object per line:
`{"code":"E0400","severity":"error","file":"a.or","line":3,"col":5,"endLine":3,"endCol":9,"message":"...","notes":[]}`.
Codes are stable across releases (the `E0xxx` table in `docs/bootstrap-subset.md` §9 and its
successors); messages may improve. Ordering is deterministic.

### `orin fmt` (P1)
The canonical formatter is the spelling authority (spec 01). It formats from the AST plus
preserved comments; it MUST be idempotent and MUST preserve the AST (modulo spans). Style: 2-space
indent, `;`-terminated statements, one canonical form per construct, trailing commas in multi-line
lists, line width 100. `orin fmt --check` exits non-zero if a file would change. Files with syntax
errors are left untouched and reported.

### `orin lsp` (P2)
LSP 3.17 over stdio (JSON-RPC, `Content-Length` framing). Initial capabilities: diagnostics
(push on open/change/save), go to definition, hover (type + signature), find references, go to implementations (classes implementing an interface, ADR-0019), rename
(module-aware; rejects renames that would break exports/imports or collide), document
formatting (via `orin fmt`), completion (scope locals, module declarations, imported names,
members/methods of the receiver type, keywords). Later: signature help, auto-imports, code
actions/quick fixes, semantic tokens, inlay hints, call hierarchy, module dependency view.
Full-document sync initially; incremental sync is P3.

### `orin mcp` (P3)
Spec 10 is authoritative. MCP tools (`check`, `inspect`, `edit`, `test`, `build`) call the same
analysis API as LSP; responses are compact structured JSON (codes + spans + short messages,
signatures instead of source text).

### Editor integration (P2)
A TextMate grammar (`editors/vscode/syntaxes/orin.tmLanguage.json`) and a minimal VS Code
extension that launches `orin lsp`. The grammar is only for highlighting; semantic tokens from
the LSP refine it later.

## 4. Orin-specific extension points (P4, design only)

The analysis API reserves typed result slots (not yet populated) for:
verification status per function/contract (VERIFIED/FAILED/UNKNOWN, spec 15), memory insights
per function (allocation sites, RC ops, COW copies, verifier result — from MIR, spec 06/07),
module-boundary violations with the violated rule (spec 04), business contract navigation
(rule ID ↔ code ↔ tests, spec 14/15), semantic change summaries (spec 16) and review evidence
(spec 17). Exposed to editors as LSP custom requests (`orin/memoryReport`, `orin/verification`,
…) and code lenses; to agents via MCP `inspect`.

## 5. Determinism and safety

Analysis results MUST be deterministic for identical inputs. Tools never execute project code
during analysis (spec 05 rules apply to future annotation expansion). LSP/MCP write access is
limited to edits the client requests; workspace roots bound file access (spec 10 security).

## 6. Priorities
P0 self-hosted compiler and bootstrap correctness · P1 stable diagnostics, formatter, analysis API
· P2 basic LSP + VS Code · P3 incremental analysis, advanced LSP, MCP · P4 verification-aware IDE
and semantic review tooling. Editor features never justify weakening compiler correctness or
memory safety.
