# Changelog

## Unreleased
- Stronger invariants, part A (ADR-0031 A1-A5), under `--check-contracts` and in the checker:
  - a violated contract prints a power-assert style report: the clause, the function and its argument values, the
    value of every maximal non-literal operand of the clause (ints, bools, floats, quoted and truncated strings,
    array lengths, `<Type>` otherwise), the `old(..)` values, then blame and action (ADR-0029): a failed
    `@Requires` is `FIX_CODE (caller)` with the call's `file:line`, a failed `@Ensures` / `@Invariant` is
    `NEEDS_DECISION` with a question and options. The first line and exit status 101 are unchanged;
  - record `@Invariant`s are enforced at every record literal, field write (also through nested records, array
    elements, `push` / `pop` on a field) and function result of the record type (docs/contracts.md lists exactly
    which points);
  - purity is inferred over the call graph (fixed point, recursion allowed): contracts may call pure functions and
    pure closures, including `every` / `some` / `map` / `filter` with a pure lambda; E0416 stays for impure ones,
    with a message that names the impure operation and its `file:line:col`;
  - calls inside a contract go to the unchecked body, so a clause that calls its own function (or an invariant that
    calls a public method) terminates; it used to recurse without end;
  - the test runner matches `// stderr:` against the compiler's output for error tests.
- Contract-quality diagnostics (ADR-0028): warnings W0450-W0452 (invariant without `this`, `@Ensures` that cannot
  fail, trivially true contracts), solver-based W0460-W0462 in `orin verify --contracts`, opt-in strict coverage
  W0470/W0471 (`--strict-contracts`, `[contracts] strict = true`), and `tools/contract_mutation.py` (contract
  strength by mutation). `orin verify --contracts` results carry the ADR-0029 fields `action`, `question`,
  `options`, `candidates`, `evidence`.

## 0.1.0-alpha.2 (2026-10-13)
Language 1.0 core complete and frozen (ADR-0016; std I/O stays unstable until capabilities, ADR-0021).
- Generic classes (ADR-0026, ADR-0016 "Generic classes"): `class Box<T>`, `new Box<int>(1)` / inferred `new Box(1)`,
  several type parameters, nesting, bounds `class C<T extends I>` (ADR-0019), `implements` of non-generic
  interfaces, contract clauses per instantiation, cross-module use; monomorphised per instantiation by lowering to
  generic records and functions (no HIR/MIR/backend change, MIR stays v1.8); mutation inferred once, equal for all
  instances and shown in hover / `orin api` / MCP / OSIG (`Program.mutating`). OSIG: one node per generic
  declaration. New errors E0460 (generic methods, post-1.0) and E0461 (static method uses a class type
  parameter). `std:graph` is rewritten as `class Graph<T>` (generational, tagged ids, stale/foreign ids are `Err`);
  the functional API is removed. Fix: `?` in a mutating method that returns a Result no longer crashes.
  The language-freeze prerequisites are complete.
- Defence in depth against shape confusion (docs/assurance.md F-shape): every struct/variant slot access (`orin_struct_get/set/slot_ptr`, `orin_mir_struct_take/replace`, `orin_struct_copy_slot`, LLVM `@orinl_slot`) checks that the object is a struct and the index is below its slot count, array slot access and push check the object kind; a mismatch traps with exit 101 (`trap: field access on a value of the wrong shape (compiler bug)`) instead of reading or writing out of bounds. Initialising stores into a fresh `orin_struct_new` use the unchecked `orin_struct_init`. Measured cost in docs/benchmarks.md. New regression test `tests/next/run/shape_confusion_try_in_mutating_method.or`; new P0 proof-debt item: MIR shape/type check in the verifier.
- OSIG (ADR-0023, docs/osig.md): `orin graph <entry|package-dir> [-o out.json]` exports the deterministic
  Orin Software Intelligence Graph (schema `osig/0.1`: packages, modules, functions, methods, classes,
  interfaces, types, fields, variants, contract clauses; edges `DEFINES`, `IMPORTS`, `CALLS` with
  `MUST`/`MAY`/`UNKNOWN` evidence, `IMPLEMENTS`, `HAS_FIELD`, `REFERENCES_TYPE`, `HAS_CONTRACT`; stable ids,
  source spans, snapshot hash). `orin diff --base --head [--format=text|json|html]` compares two snapshots:
  changed/added/removed symbols, added/removed edges, heuristic rename candidates, reverse impact with the
  explaining path from entry points; the HTML report is one self-contained file. MCP tools `graph` and
  `diff`. `SemanticIndex` gains `calls` (call sites from the typed HIR). CI uploads the diff report of a
  pull request as an artifact (report only). `orin api --check` is unchanged.
- Built-in annotations (ADR-0024, spec 05; compiler built-ins only, any other `@Name` is still E0408):
  `@Test` on top-level `void` functions with `orin test <file|dir> [--filter S] [--format=json]` (one
  executable, one process per test, PASS/FAIL per test, stable JSON, MCP `test` with `unit: true`) and
  the new `std:test` module (`assert`, `assertEq`, ...); `@Test` functions are type-checked but erased from
  ordinary builds (byte-identical output). `@Deprecated("message")` gives warning W0440 on uses (text, JSON
  `severity:"warning"`, LSP severity 2 + Deprecated tag, hover, `orin api --check`). `@Inline` becomes
  `static inline` (C) / `alwaysinline` (LLVM); a recursive `@Inline` function is E0444. New errors
  E0440-E0445, formatter, VS Code grammar. See docs/testing.md.
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
