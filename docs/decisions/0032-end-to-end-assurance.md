# ADR-0032: End-to-end assurance — from source semantics to the binary, checkable by people

Status: accepted (2026-10-13, project owner). Related: ADR-0020 (statuses, assurance levels),
ADR-0030 (provable std, R3/R4), ADR-0031 (stronger invariants), vision §20a, `docs/tcb.md`,
`docs/assurance.md`.

## Context

Orin's language design already removes the usual sources of unprovable behaviour:
- no `null`, exceptions, inheritance or implicit conversions;
- overflow and out-of-bounds trap instead of being undefined;
- exhaustive `match`;
- value semantics, so there are no hidden aliasing effects.

The proof chain still has gaps:

| Gap | Today |
|---|---|
| Meaning of a source program | prose spec; Lean models only the MIR memory machine |
| Compiler passes | ownership verifier independent but `MODEL_ONLY`; lowering, optimisation and emission tested only |
| C compiler | gcc/clang trusted |
| SMT solver | `unsat` trusted |
| Runtime | C, tested only (ADR-0030 R3/R4 planned) |
| Termination, absence of traps | not proved; contracts give partial correctness only |
| Bootstrap | seed + fixed point; no independent cross-check |

People also need to see *what* is proved, under *which* assumptions, without reading proofs.

## Decision

### Proof chain

1. **Source semantics in Lean.** A mechanised semantics of the language core: the HIR level,
   values, records/classes, closures, `match`, traps. Plus a **type soundness** proof (progress and
   preservation). Every later "VERIFIED" refers to this semantics.
2. **Translation validation per compile.** Each pass emits a certificate that a small independent
   checker validates:
   - parse → AST: a round trip through the formatter;
   - check → HIR: typing derivation;
   - HIR → MIR, optimisations, MIR → C: semantic simulation witnesses.

   This is built together with the lowering rewrite and R3. A failed or missing certificate is
   `UNKNOWN`, never silently accepted. Per-program validation is the chosen route, not a fully
   verified compiler like CompCert, because it is cheaper and gives the same guarantee for each
   program.
3. **Proof-producing SMT.** Z3/cvc5 proof objects (or Alethe proofs) are checked by the Lean
   kernel. VC generation is proved sound with respect to (1). Until then, the solver stays listed in
   the TCB and results say so.
4. **Termination and absence of run-time errors.**
   - `@Decreases(measure)` on loops and recursive functions gives total correctness.
   - A `--no-runtime-errors` mode proves that no overflow, out-of-bounds, unwrap-of-None or
     division by zero can happen. Every unprovable site becomes `NEEDS_DECISION` (ADR-0029).
5. **Runtime:** R3 and R4 as in ADR-0030; L0 contract-verified.
6. **To the binary:**
   - **CompCert path:** emit C in the CompCert-supported subset, so the C compiler is a verified
     compiler.
   - **Diverse double compiling:** cross-check the bootstrap against an independent compiler. The
     archived Rust Stage 0 accepts only the old bootstrap subset, so the check is a chain through
     historical commits, each step bit-compared, not a single step.
   - **Signed `.orcert` attestations** bind source, binary, compiler version and every piece of
     evidence.

### Human checkability

7. **Normative, traceable language reference.** It is short. Each rule links to its Lean
   definition or theorem, its conformance tests and its error code. CI checks that the links
   resolve.
8. **Assurance report per program** (HTML, built on OSIG). For each function and clause it shows:
   - the status (`VERIFIED` / `TESTED_ONLY` / `ASSUMED` / `UNKNOWN`);
   - the assumptions;
   - the TCB items it depends on.

   PRs show the report as a diff (ADR-0029 §4).
9. **Decision tables** as a specification form for business rules. The compiler checks
   completeness (no gap) and disjointness (no overlap), like exhaustive `match`. It generates the
   executable specification of ADR-0031 §14 from the table.
10. **TCB budget.** `docs/tcb.md` lists every trusted component with its size. CI fails if L0 grows
    beyond its budget or a new trusted component appears without an ADR.

## Honest limits

- The OS kernel and the hardware stay trusted.
- Lean's kernel, and CompCert's own proof, are trusted.
- No proof shows that a specification says what its authors intended. Items 7–9 exist so people can
  check exactly that part.
- Translation validation proves each compiled program, not the compiler for all inputs.

## Order

Part of roadmap step 4 ("Complete the Lean proofs"):

1. (1) semantics and type soundness;
2. (2) translation validation, with the lowering rewrite and R3;
3. (3) and (4);
4. (8) and (9), as early as the report data exists;
5. (6) and (10).

The step is done when a reference program (`examples/ledger/`, ADR-0031) has a report in which
every clause is `VERIFIED` under listed assumptions, and the TCB list contains only L0, the OS, the
hardware, Lean's kernel and the C compiler (CompCert on the certified path).
