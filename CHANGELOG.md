# Changelog

## Unreleased
- OSIG (ADR-0023, docs/osig.md): `orin graph <entry|package-dir> [-o out.json]` exports the deterministic
  Orin Software Intelligence Graph (schema `osig/0.1`: packages, modules, functions, methods, classes,
  interfaces, types, fields, variants, contract clauses; edges `DEFINES`, `IMPORTS`, `CALLS` with
  `MUST`/`MAY`/`UNKNOWN` evidence, `IMPLEMENTS`, `HAS_FIELD`, `REFERENCES_TYPE`, `HAS_CONTRACT`; stable ids,
  source spans, snapshot hash). `orin diff --base --head [--format=text|json|html]` compares two snapshots:
  changed/added/removed symbols, added/removed edges, heuristic rename candidates, reverse impact with the
  explaining path from entry points; the HTML report is one self-contained file. MCP tools `graph` and
  `diff`. `SemanticIndex` gains `calls` (call sites from the typed HIR). CI uploads the diff report of a
  pull request as an artifact (report only). `orin api --check` is unchanged.
- Packages (ADR-0016, spec 04): `orin.toml` manifest (`[package]`, `[architecture]`,
  `[modules.<path>] allowed_dependencies`), enforced by the loader (E0501 disallowed import, E0502
  unknown module, E0500/E0503 manifest errors); `orin check|compile|build|run <package-dir>`;
  `orin check --deps` (module dependency summary); `orin api [--check <snapshot>]` (public API
  snapshot and change detection); MCP `inspect` module shows the manifest rule.
- Floats (`float`, `f32`), `std:math`, built-in `Map<K, V>` (ADR-0018). Float programs link with `-lm`.
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
