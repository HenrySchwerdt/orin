# Changelog

## Unreleased
- Resources and streaming `std:fs` (ADR-0025, ADR-0016 "Resources"): `File` is a non-copyable handle that can only be a
  function parameter; scope API `withFile` / `useFile` / `withFiles` / `useFiles` (`std:fs`, unstable until capabilities)
  with `readLine`, `read`, `readAll`, `write`, `writeLine`, `flush`; errors E0450 (resource inside another type /
  variable / result), E0451 (handle used as a value), E0452 (captured by a closure). MIR v1.8: `MHandle` with a linear
  open/close discipline in the verifier; platform stream primitives with contracts; runtime handle table.
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
