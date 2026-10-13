# ADR-0015: Modernise the compiler with the full language and dogfood contract clauses

Status: accepted (2026-10-13). Depends on ADR-0014 (seed bootstrap), ADR-0012 (contract clauses),
the Map/float work and closures (ADR-0011).

## Decision
Once the seed bootstrap is merged, the compiler source (`compiler/`) is no longer restricted to
Orin-B. We then rewrite it module by module to use the language idiomatically and to state its own
invariants as contract clauses:

- **Structure:** classes for stateful passes (`Checker`, `FnContext`, `Lowerer`, `Emitter`,
  `Verifier`) instead of threading records through every call; generics instead of per-type copies
  of helpers; closures + array API (`map`/`filter`/`find`/`sort`) instead of manual index loops;
  `Map<K, V>` for symbol tables, scopes, string-literal tables and the semantic index (replacing
  linear search).
- **Contracts in the compiler itself** (spec 15 §4.2a): `@Requires`/`@Ensures` on core functions and
  `@Invariant` on core data, e.g.
  - spans: `start <= end`, file index in range;
  - HIR/MIR well-formedness: local/block/function indices in range, `paramOwned.length == paramCount`;
  - lowering: every emitted MIR function verifies (`@Ensures(verify(result).errors.length == 0)`
    on `lower` where cheap enough for runtime checking);
  - type substitution leaves no type parameters in monomorphised output;
  - formatter: idempotence and AST preservation as stated properties of `format`.
- **Checking:** CI builds an extra compiler with `--check-contracts` and runs the full test suite
  and the bootstrap with it (contracts become traps); normal builds erase them (zero cost). Pure
  functions with supported contracts are additionally sent to `orin verify --contracts` once
  phase 2 exists; results are reported per clause (VERIFIED / REFUTED / UNKNOWN / ASSUMED, ADR-0020 D1), never as
  "the compiler is proven".

## Rules for the rewrite
- One module per PR; behaviour-preserving (stage2 == stage3 must still hold for each step, all
  suites and differential tests green, diagnostics unchanged byte for byte on tests/errors).
- No new language features are invented for the rewrite; if something is missing, it is designed
  separately (ADR) first.
- Order: `loader` + `diag` (small) → `check` (largest win: Map-based scopes, classes) → `lower` /
  `opt` / `verify` → backends → tooling. Performance is measured (self-compile time, RSS) per step.
