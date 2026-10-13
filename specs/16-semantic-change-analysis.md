# RFC 016 — Semantic Change Analysis and Business Logic Versioning

**Status:** DESIGN / OPTIONAL COMPILER FEATURE. **Language:** Orin (`.or`). **Dependencies:** RFC 014 (Business Logic Testing), RFC 015 (Contracts and Formal Verification).  
**Principle:** Review behavioral changes, not only textual changes.

## 1. Goals and scope

Orin SHOULD generate a machine-readable and human-readable **Business Behavior Diff (BBD)** for two immutable project revisions. Business reviewers and Product Owners (POs) SHOULD be able to see *what customer-visible rules changed*, the affected scenarios, whether a change was authorized, and the strength of supporting evidence. Developers retain access to code diffs and technical evidence.

A source-code diff is not a behavioral diff. Equivalently, a changed contract is not proof that implementation behavior changed. The tool MUST identify which conclusions are proved, tested, syntactically derived, or inferred. It MUST NOT claim semantic equivalence from passing tests, unchanged function names, or no recorded contract differences.

## 2. Source of truth: business rule registry

Each externally relevant business rule has a stable ID and human-owned specification entry. The rule's natural-language description is reviewable, but its formal predicates, examples, and links to code are machine-processable.

Recommended structure:

```text
spec/business/
  SHOP-001.rule.md
  PAY-004.rule.md
```

An example business rule file (YAML front matter is metadata, not Orin program syntax):

```markdown
---
id: SHOP-001
version: 2
owner: product/payments
status: approved
severity: high
supersedes: SHOP-001@1
---
# Premium discount
Premium customers receive 10% off from 100.00 EUR, inclusive.

## Acceptance criteria
- Non-premium customers never receive this discount.
- At exactly 100.00 EUR the discount applies.
- Discounts are nonnegative and never exceed total.

## Authorized change rationale
The minimum spend was decreased from 150.00 EUR to 100.00 EUR.
```

The baseline (`v1`) MUST remain available and immutable in the review record. Approval metadata MUST not be forgeable merely by changing files in the same pull request. Trusted identity is provided by the source-control/review platform, not an `approved: true` field written by an agent.

## 3. Three independent diffs

For baseline B and candidate C, the system MUST compute (when supported):

1. **Contract diff:** changed rules, predicates, accepted/rejected examples, preconditions, postconditions, invariants, public API and error behavior.
2. **Implementation impact diff:** changed symbols, call sites, module dependencies, generated annotations/routes, resources, effects and external interfaces.
3. **Evidence diff:** newly proven/refuted/unknown properties, added/removed tests, mutation score shifts, counterexamples, regression results.

Every claim MUST cite the corresponding rule IDs, artifact hashes, file/symbol references, verifier output and code revision. Changes with no matching rule SHOULD be flagged `UNSPECIFIED_BEHAVIOR_CHANGE` when detectable, and `UNMAPPED_CODE_CHANGE` otherwise.

## 4. Comparison semantics

For a pure deterministic function `f` with old/new preconditions `P_B/P_C` and postconditions `Q_B/Q_C`, the strongest supported checks may include:

- **Refinement / no regression:** for every input permitted by the compatibility policy, candidate behavior satisfies the baseline requirements.
- **Intentional deviation:** there exists a witness where the candidate's behavior differs, and that input belongs to a human-approved changed-rule scope.
- **Unchanged behavior:** relational equivalence (`f_B(x) = f_C(x)`) over an explicitly stated input domain. Do not treat this as implied by equal contracts.
- **Compatibility:** compare schemas, error variants, route registration, input ranges, observable outputs, timing guarantees when specified, and relevant effects.

For stateful logic, behavioral equivalence MUST refer to bounded traces or a formally specified transition system, and MUST state the observation boundary. For I/O, nondeterminism, time, network, database or third-party behavior, the system MUST report assumptions and model coverage. General equivalence of arbitrary programs is undecidable; `UNKNOWN` is a normal outcome.

Proof results are only as strong as the rule specification. The system MUST distinguish a proof that the implementation satisfies the contract from a proof that old and new implementations are equivalent.

## 5. Change taxonomy and severity

| Category | Meaning | Example |
|---|---|---|
| `INTENDED_BEHAVIOR_CHANGE` | Approved new business rule | Discount threshold changed |
| `PRESERVED_BEHAVIOR_PROVEN` | Defined observable behavior equivalent over declared domain | Refactor with relational proof |
| `REGRESSION_PROVEN` | Verifier found counterexample against retained contract | Non-premium users receive discount |
| `REGRESSION_TESTED` | Tests detected actual changed behavior | Historical edge test fails |
| `CONTRACT_CHANGE_ONLY` | Specification changed, implementation effect not established | Rule text updated |
| `IMPLEMENTATION_ONLY` | Code changed, business effect not established | Internal refactor |
| `POTENTIAL_BREAKING_CHANGE` | Static/schema impact detected but not fully proven | New error return |
| `UNKNOWN` | Insufficient specification, proof/model or timeout | External provider impact |

A test failure is not automatically mathematical proof of a general regression, but a concrete input producing disallowed output is a valid counterexample to a universal property if its execution environment is trusted.

## 6. Required PO-facing report

Each affected rule MUST show:

- Stable rule ID, human-readable description, responsible owner.
- Old behavior vs. proposed behavior in ordinary language.
- Explicit boundary examples: before, at, and after thresholds; failure scenarios; state transitions.
- Whether behavior changes are intended, compatible, breaking, or unknown.
- Who approved the new requirement (from signed/platform identity), and when.
- Evidence status and the assumptions under which any proof was accepted.
- Links to detailed test/proof output and source diff, never an inaccessible summary only.

Example **illustrative**, not verified:

```text
SHOP-001 — Premium discount
OLD: Eligible from 150.00 EUR
NEW: Eligible from 100.00 EUR (inclusive)
Examples:
  premium,  99.99 -> 0.00 (unchanged)
  premium, 100.00 -> 10.00 (changed)
  premium, 149.99 -> 15.00 (changed; integer cent rounding policy required)
Compatibility: intentional behavior change
Evidence: tests PASS; contract proof UNKNOWN (rounding model incomplete)
Approval: REQUIRED from Product Owner
```

All amounts in examples MUST use the actual domain rounding rule; the example above illustrates what must be reviewed and MUST not be treated as an approved pricing specification.

## 7. Artifact and reproducibility contract

The canonical evidence record MUST include:

```json
{
  "schema": "orin.business-diff/v1",
  "base_commit": "<commit-sha>",
  "candidate_commit": "<commit-sha>",
  "rule_ids": ["SHOP-001"],
  "spec_hashes": {"base": "sha256:...", "candidate": "sha256:..."},
  "compiler": {"version": "...", "hash": "..."},
  "verifier": {"version": "...", "hash": "...", "solver": "..."},
  "environment": {"target": "...", "assumptions": []},
  "results": [{"property": "...", "status": "UNKNOWN", "reason": "..."}],
  "evidence_digest": "sha256:..."
}
```

Artifacts SHOULD be content-addressed and CI-signed, and bound to the exact base/candidate revisions. Any edit to relevant inputs invalidates evidence and requires recomputation. Git history is input, not itself an authorization mechanism.

## 8. CLI, MCP and CI (proposed; not implemented)

```bash
orin business diff --base origin/main --head HEAD --format md
orin business diff --base origin/main --head HEAD --format json
orin business impact --rule SHOP-001
orin business evidence --rule SHOP-001
orin business baseline --revision origin/main
```

MCP SHOULD expose `business_diff`, `rule_impact`, and `rule_evidence` as compact results with optional detailed pagination. Delta queries MUST be revision-scoped and invalidated on hash mismatch. CI MUST store full evidence even when the MCP response is intentionally short.

## 9. Acceptance criteria

- [ ] Reports changed and unchanged rules separately from implementation-only changes.
- [ ] Never outputs `PROVEN` for test-only evidence, solver timeouts, incomplete assumptions or stale artifacts.
- [ ] Classifies unauthorized contract changes as requiring human approval.
- [ ] Detects changed external signatures and maps them to potentially affected modules.
- [ ] Reviewer can reproduce each report from pinned source, tool versions and assumptions.
- [ ] Unknown behavior cannot be silently described as unchanged.

## 10. Research and precedent

- Dafny specifications and modular verification: https://dafny.org/dafny/DafnyRef/DafnyRef
- OpenAPI semantic/breaking change analysis (inspiration, not a general program equivalence solver): https://github.com/oasdiff/oasdiff
- RFC 014 and RFC 015 in this repository.
