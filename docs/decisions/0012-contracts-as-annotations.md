# ADR-0012: Contract clauses (annotation-like syntax, own language constructs); verification is a compiler pass

Status: accepted (2026-10-13). Spec: `spec/15-contracts-invariants-and-formal-verification.md` §4.2a.
Implementation: phase 1 (parse, resolve, type-check, erase, `--check-contracts`) and phase 2 (`orin verify --contracts`, straight-line int/bool functions via z3) done; see `docs/contracts.md`.

- Canonical syntax: `@Requires(e)`, `@Ensures(e)` (with `result`, `old(e)`), `@Invariant(e)`,
  `@Decreases(e)`, `@Rule("ID")`. The keyword-clause sketch of spec 15 §4.1–4.3 is superseded as
  syntax (one canonical form, spec 01).
- **They are not annotations.** The `@` spelling is only familiar surface syntax. Contract
  clauses are a closed set of reserved, compiler-defined constructs with dedicated grammar
  productions and AST nodes (`ContractClause`), their own expression scope (`result`, `old`,
  `==>`) and semantics fixed by spec 15. The annotation mechanism of spec 05 cannot define,
  import, shadow, generate, remove or rewrite them; annotation processors get read-only access at
  most. Rationale: proof obligations must not depend on user-extensible metaprogramming, and the
  verifier's trusted input must be exactly what the programmer wrote.
- Contract expressions are always resolved and type-checked during normal builds; proofs run as a
  compiler pass when requested (`orin verify`, `--verify`) or required by module policy.
- Order of implementation: contract-clause productions + AST nodes in the parser (store, check, ignore) → pure-function
  `@Requires/@Ensures` VC generation (spec 15 Milestone B) → loops → classes/`mut` methods.
