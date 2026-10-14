# ADR-0035: Compile-time proof and runtime contract enforcement

**Status:** proposed (2026-10-14)  
**Scope:** contract verification and release policy; design only, no compiler implementation in this ADR.  
**Related:** [ADR-0012](0012-contracts-as-annotations.md), [ADR-0020](0020-verifiable-software-roadmap.md), [ADR-0028](0028-contract-quality.md), [ADR-0029](0029-agent-refusal-protocol.md), [ADR-0030](0030-provable-std-and-minimal-trusted-runtime.md), [ADR-0031](0031-invariants-for-verified-business-logic.md), [assurance ledger](../assurance.md), [contracts](../contracts.md).

## Context

Orin has compiler-recognized `@Requires`, `@Ensures`, `@Invariant`, `@Decreases` and `@Rule` clauses, a `--check-contracts` runtime-checking build, and `orin verify --contracts [--strict]` for a **limited** SMT fragment (pure `int`/`bool` functions without loops, arrays, strings, records, classes or I/O). The latter produces `VERIFIED`, `REFUTED` or `UNKNOWN`, with assumptions including A-INT, A-DIV and A-PARTIAL.

Many invariants in the standard library are **runtime-checked and tested**, not formally proved. Counting contracts, testing mutations, successfully self-hosting, and having a Lean model of the ownership core do not prove the real standard library correct.

This ADR defines a single contract surface and two distinct enforcement mechanisms: static verification of proof obligations and dynamic checking of executable predicates. It explicitly forbids reporting runtime checks or nontrivial assumptions as universal proof.

## Decision

### D1. The proof obligation is the unit of evidence

The compiler generates individually identified verification conditions (VCs) for:
- Call-site preconditions;
- Function/method postconditions;
- Object and record invariant establishment and preservation;
- Loop invariant initialization, preservation and sufficiency at exit;
- Termination/variant obligations when `@Decreases` is requested;
- Arithmetic safety, array bounds and well-formed state needed for the claim;
- Frame/modification conditions **when supported and declared**.

Each result has `status` = `VERIFIED | REFUTED | UNKNOWN`, a stable obligation ID, source range, dependency IDs, model/semantic version, solver details, assumptions and assurance level (per ADR-0020). A solver's `unsat` proves a property **only within the encoded semantics and trusted assumptions**. A test pass is `TESTED_ONLY`; a runtime check is `DYNAMICALLY_CHECKED`, not `VERIFIED`. No count of assertions can substitute for proof coverage.

`REFUTED` means the model has a countermodel to an obligation. It is an actionable defect only after the relevant execution is feasible under Orin semantics and assumptions; otherwise report a spurious/inconclusive counterexample with `UNKNOWN` and a reason. A timeout, unsupported expression, undecidable solver result or incomplete model is always `UNKNOWN`, never `VERIFIED`.

### D2. Canonical conceptual build policies

We propose three user-facing policies (CLI names are **proposals**, not currently supported commands):

| Policy | Proposed CLI | Result |
|---|---|---|
| Normal | `orin build` | Current semantics: contracts are type-checked and normally erased; **no proof claim** |
| Checked | `orin build --verify=runtime` | Insert runtime checks for supported executable clauses; report which obligations are not dynamically enforceable |
| Strict | `orin build --verify=strict` | Generate required VCs and produce the release only when all mandatory obligations meet the configured evidence/trust policy |

Avoid inventing an undocumented default: `orin build` stays unchanged until an explicit migration decision. The existing `--check-contracts` flag and `orin verify --contracts --strict` stay valid during transition; a later implementation ADR must specify alias/deprecation and build-vs-verifier invocation precisely.

**Strict is not shorthand for "every possible property of the program is proved".** A manifest-defined **verification scope** enumerates required modules, exported boundaries, requirement IDs, and categories of obligations. No required obligation may be ungenerated, silently skipped, `UNKNOWN`, `REFUTED` or downgraded from `VERIFIED`. An absent contract does not create a property to prove. Verification coverage (which properties were required and which were generated) must be in the report, including uncovered boundaries.

A strict build may fail even if a checked build succeeds. A checked build must **not** be advertised as formally verified. Default compilation remains possible for iterative work, with warnings and clear evidence labels.

### D3. Runtime-check eligibility is explicit

`@Requires` and `@Ensures` with pure, terminating, executable expressions can be checked at calls and returns. Class and record invariants can be checked at defined state transitions, respecting construction and temporary mutation invariants. Loop invariants can be checked at entry and after each iteration **once the loop-instrumentation implementation exists**. Runtime enforcement of a variant can check observed decreases for executed iterations, but this is **not a general termination proof**.

Runtime checks may be unavailable or incomplete for quantified mathematical properties, ghost-only specifications, frame conditions, nontermination, cross-process safety policies and properties depending on unobservable past executions. The compiler MUST publish a per-obligation `runtime_supported` flag and an exact check-insertion description. In checked policy, any required but non-instrumentable obligation must be clearly reported as **not dynamically enforced**; a separate fail-closed configuration can reject such builds. Checking only exercised executions is never labelled universal proof.

Ordinary runtime contract failures use the established diagnostic and refusal protocol: preconditions blame the caller; postconditions/invariants indicate callee/spec decision; agents must not weaken contracts or assumptions without authority (ADR-0029).

### D4. Erasure and proof-driven elimination

A verified VC does not automatically justify deleting a runtime operation. A check can be removed only when all of the following hold:
1. The emitted check protects precisely the property proved, under the same path conditions and concrete integer, bounds, value and exception/trap semantics.
2. All premises are validated or explicitly included in the accepted trust policy; there is no unsupported/UNKNOWN premise.
3. Compilation passes between VC generation and machine output preserve this fact. Until translation validation/implementation assurance is established, state the compiler/backend trust dependency explicitly.
4. Removing the check does not remove an observable effect or alter required trap behaviour. Semantically required bounds, shape and capability checks are **not** omitted merely because a *source-level* contract was verified.
5. The artifact records the VC ID and why the check was elided, so a reviewer can audit the decision.

If any requirement is unmet, retain the mandatory safety check or fail the strict build. A release-speed switch can never globally disable required memory-shape, bounds or capability protection. Contract erasure in normal builds must remain testable as a semantics-preserving choice with no false safety claim.

### D5. Proof language evolves before adding new annotation names

Keep the current core clauses; extending the VC engine has priority over multiplying `@...` spellings. The implementation roadmap is:
1. **Loop VCs:** initiation, inductive preservation and exit implication, plus `@Decreases` with a well-founded, nonnegative measure; distinguish partial correctness from termination.
2. **Faithful arithmetic:** signed/unsigned fixed-width types and traps, overflow/division/bounds obligations; no silent shift from i64 to unbounded integers.
3. **Arrays/strings/records and `old`:** symbolic state, select/store, immutable-value semantics, local mutation and snapshots, modular call summaries.
4. **Frame specifications:** propose `@Modifies(...)` (new syntax **only after a separate ADR**) or a demonstrably equivalent mechanism, with sound frame inference and preservation obligations.
5. **Quantification and reusable proofs:** typed `forall`/`exists` semantics or specification-only functions, optional lemmas and ghost state **only after separate syntax/semantics ADRs**. Do not identify runtime `every` tests with universally proved quantification.

For complex collections (e.g. B-trees), prove a **vertical slice** first: preservation of sortedness, shape, membership, and a bounded operation, with a documented proof boundary. A checkable `@Invariant` without a discharged preservation VC remains a dynamic contract.

### D6. Stable, cacheable and reviewable evidence

Proof results are content-addressed by function/body, contract, transitive summaries, compiler/VC-model version and relevant trust assumptions. A dependency change invalidates dependent evidence. CI and MCP produce machine-readable evidence with precise `VERIFIED`/`REFUTED`/`UNKNOWN`, `TESTED_ONLY` and `DYNAMICALLY_CHECKED` **on distinct axes**, not as interchangeable statuses. OSIG can display and diff the obligations and their assumptions; signed attestations (`.orcert`) remain separate future work. Signing an outcome is not proof that the underlying verification implementation is correct.

A PR weakening a contract, excluding an obligation from strict scope, adding an assumption or permitting a new authority needs explicit human review per ADR-0029/ADR-0020.

## Non-goals and trust boundaries

- Not a promise that all Orin code or all standard-library algorithms can be automatically proved.
- Not proof that a specification reflects business intent.
- Not a complete proof of compiler, native backend, C runtime, OS, dependencies or external network.
- Not a change to already implemented compiler flags in this documentation-only PR.
- Does not retroactively promote existing standard-library tests, contract counts, mutation results, Lean model proofs or CBMC-bounded checks to implementation-level formal guarantees.

## Acceptance tests for a future implementation

1. Simple pure `int`/`bool` VERIFIED/REFUTED/UNKNOWN cases retain previous behavior and IDs or migration mapping.
2. An inductive summation loop emits distinct initialization, preservation, exit and termination VCs; removing its inductive step yields a real counterexample or UNKNOWN, never VERIFIED.
3. Overflowing arithmetic and out-of-bounds array access are not proved safe by unbounded integer or array models.
4. Unsupported array, heap or quantifier cases fail strict mode with a specific UNKNOWN reason and do not disappear from coverage.
5. A checked loop-invariant build catches a violated invariant on an executed iteration; an unreachable bad state is not falsely reported as disproved by finite tests.
6. A runtime-only property (e.g. termination) cannot silently count as checked merely because executable pre/postconditions passed.
7. A check can be elided only with a matching, traceable proof and trusted lowering policy; mandatory shape/capability checks persist otherwise.
8. Contract change, solver/model change or callee summary change invalidates cached evidence and semantic PR reporting identifies the impact.
9. Strengthening the strict scope makes the build fail when added obligations are UNKNOWN; weakening scope requires human authorization.
10. Test and mutation results remain TESTED_ONLY, even if every test passes.

## Rollout

**Phase 0 (this ADR):** specify modes, obligations, coverage and evidence; no production claim.

**Phase 1:** VC and report model/CLI design; keep existing `--check-contracts` and `orin verify --contracts`; add loop proof and honest strict gating over explicit scope.

**Phase 2:** executable loop checks and precise integer/array models; add corresponding cross-backend tests.

**Phase 3:** modular state, frame conditions, reusable proof summaries and std-library pilot (bytes/UTF-8/simple collection first, B-tree later).

**Phase 4:** optimization check elimination backed by matched proof artifacts and trusted translation boundary; attach evidence to OSIG and eventually attestations.

**Decision to review:** Whether a project-level checked policy should fail closed for obligations that cannot be instrumented. Until decided, no such guarantee is implied.
