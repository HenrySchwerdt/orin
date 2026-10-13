# Changelog

## Unreleased
- Built-in annotations (ADR-0024, spec 05; compiler built-ins only, any other `@Name` is still E0408):
  `@Test` on top-level `void` functions with `orin test <file|dir> [--filter S] [--format=json]` (one
  executable, one process per test, PASS/FAIL per test, stable JSON, MCP `test` with `unit: true`) and
  the new `std:test` module (`assert`, `assertEq`, ...); `@Test` functions are type-checked but erased from
  ordinary builds (byte-identical output). `@Deprecated("message")` gives warning W0440 on uses (text, JSON
  `severity:"warning"`, LSP severity 2 + Deprecated tag, hover, `orin api --check`). `@Inline` becomes
  `static inline` (C) / `alwaysinline` (LLVM); a recursive `@Inline` function is E0444. New errors
  E0440-E0445, formatter, VS Code grammar. See docs/testing.md.
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
