# ADR-0008: One shared semantic engine for compiler, LSP, MCP and formatter

Status: accepted (2026-10-13). Spec: `spec/18-developer-tooling.md`.

## Decision
- All tools are subcommands of the one self-hosted `orin` binary and call the same modules:
  `syntax` (lexer/parser), `loader`, `check`, plus a new `analysis` module that wraps them with an
  input overlay (unsaved buffers), revisions and indexes (symbols, references, expression types).
- The checker records resolution facts (definition spans, use → definition, expression types)
  in a side table returned with the HIR, instead of tools re-deriving them.
- Phase 1 recomputes the whole program per change (measured: the compiler itself checks in
  ~50 ms). A salsa-style memoised query engine is deferred to P3, when programs or latency
  require it; the API (pure queries over revisioned inputs) is designed so it can be added
  without changing callers.
- The formatter works on the AST plus comment trivia from the same lexer.
- Tools are written in Orin (self-hosted), except the VS Code client glue (JavaScript), because
  the compiler is the only implementation of the language.

## Consequences
- Requires stdin access in the runtime/std (`std:io` read primitives) for `orin lsp`/`orin mcp`;
  added through the normal builtin path (HIR Builtin → MIR → C).
- No duplicated grammar logic except the TextMate grammar used for highlighting only.
- The Stage 0 Rust compiler stays frozen and does not grow tooling.
