# Changelog

## Unreleased
- Packages (ADR-0016, spec 04): `orin.toml` manifest (`[package]`, `[architecture]`,
  `[modules.<path>] allowed_dependencies`), enforced by the loader (E0501 disallowed import, E0502
  unknown module, E0500/E0503 manifest errors); `orin check|compile|build|run <package-dir>`;
  `orin check --deps` (module dependency summary); `orin api [--check <snapshot>]` (public API
  snapshot and change detection); MCP `inspect` module shows the manifest rule.

## 0.1.0-alpha.1 (2026-10-13)
First experimental release of the self-hosted Orin compiler.
- Self-hosted compiler (Orin), reproducible bootstrap (stage2 == stage3).
- Language: Orin-B core, generics, classes with value semantics.
- Pipeline: HIR → MIR → independent ownership verifier → C; owned-parameter inference and
  last-use moves.
- Tooling: `orin check --format=json`, `orin fmt`, `orin lsp`, VS Code extension.
- Formal: Lean model of the RC memory machine; soundness of the MIR ownership checker for the
  structured core (`check_sound`). Not end-to-end verified.
