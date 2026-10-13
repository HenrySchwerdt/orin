# Changelog

## Unreleased
- Packages (ADR-0016, spec 04): `orin.toml` manifest (`[package]`, `[architecture]`,
  `[modules.<path>] allowed_dependencies`), enforced by the loader (E0501 disallowed import, E0502
  unknown module, E0500/E0503 manifest errors); `orin check|compile|build|run <package-dir>`;
  `orin check --deps` (module dependency summary); `orin api [--check <snapshot>]` (public API
  snapshot and change detection); MCP `inspect` module shows the manifest rule.
- Floats (`float`, `f32`), `std:math`, built-in `Map<K, V>` (ADR-0018). Float programs link with `-lm`.
- Fixed-width integers (ADR-0022): `i8 i16 i32 i64 u8 u16 u32 u64 isize usize` (`int` = `i64`); literals adopt the expected type (E0430 when they do not fit; `u64` literals up to 2^64-1), no implicit conversions, explicit `toI32()` etc. that trap when the value does not fit, `wrapping*` / `checked*` / `saturating*` `Add`/`Sub`/`Mul`, `parseI32` etc., overflow / division traps at every width, usable as array elements, record fields, Map keys, generics, closures. `i128` / `u128` are rejected with E0431 (deferred, see the ADR).
- Template-literal interpolation (ADR-0022): `` `Hello ${name}, you are ${age}` `` with TypeScript lexing (escapes, nesting, multi-line); `string`, integer, `float`, `f32` and `bool` interpolate implicitly, other types are E0432; lowered to one append chain; formatter prints templates verbatim; LSP resolves identifiers inside `${}`; VS Code grammar highlights templates. New diagnostics E0430, E0431, E0432. MIR v1.6 (no new type; `OUsize` is a 64-bit pattern).
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
