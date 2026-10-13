# ADR-0012: Contracts are built-in annotations; verification is a compiler pass

Status: accepted (2026-10-13). Spec: `spec/15-contracts-invariants-and-formal-verification.md` §4.2a.
Implementation: not started (needs annotation parsing — spec 05 — and a contract IR/SMT backend).

- Canonical syntax: `@Requires(e)`, `@Ensures(e)` (with `result`, `old(e)`), `@Invariant(e)`,
  `@Decreases(e)`, `@Rule("ID")`. The keyword-clause sketch of spec 15 §4.1–4.3 is superseded as
  syntax (one canonical form, spec 01; Java-style annotations, spec 05).
- Contract expressions are always resolved and type-checked during normal builds; proofs run as a
  compiler pass when requested (`orin verify`, `--verify`) or required by module policy.
- Order of implementation: annotation syntax in parser/AST (store, check, ignore) → pure-function
  `@Requires/@Ensures` VC generation (spec 15 Milestone B) → loops → classes/`mut` methods.
