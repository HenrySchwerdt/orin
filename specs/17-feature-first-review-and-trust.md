# RFC 017 — Feature-First Review and Evidence-Gated Change Approval

**Status:** DESIGN / OPTIONAL ENTERPRISE FEATURE. **Depends on:** RFC 014, RFC 015, RFC 016.  
**Product proposition:** Review what software does, not only how its code was written.

## 1. Vision

Orin SHOULD enable a **feature-first review** workflow in which a Product Owner, domain expert, or engineering reviewer assesses an understandable change specification, its examples, safety/evidence status, and risk before inspecting source code. For some low-risk, fully governed changes, an organization MAY approve on that basis without a manual line-by-line source-code review.

**This is not a claim that source-code review is universally unnecessary.** Mathematical verification is relative to stated specifications, assumptions and trusted tools. Unexpected requirements, unspecified side effects, malicious implementation, platform vulnerabilities, performance regressions, data protection issues and compiler bugs are not eliminated by green tests or a contract proof. A risk-based engineering/security review MUST remain available and MUST be mandatory where policy requires it.

## 2. Two independent approval axes

1. **Product approval:** Is the change in *intended business behavior* correct, complete, understandable and authorized?
2. **Engineering assurance:** Does the implementation satisfy the approved contracts under the stated assumptions, and is any unverified impact acceptable?

Neither approval implies the other. A PO SHOULD NOT be asked to interpret memory IR or source-code implementation detail. A security/engineering reviewer MUST be able to drill into code, generated artifacts, dependency changes, external effects and proof evidence.

## 3. Feature is a first-class versioned artifact

A feature (stable ID) is a collection of requirement clauses and their linked implementations, tests, invariants, interfaces and nonfunctional constraints. One source file may contribute to multiple features; one feature may span modules.

```text
spec/features/
  FEAT-CHECKOUT/
    feature.md          # business intent, actors, approvals
    scenarios.md        # acceptance cases and edge cases
    constraints.md      # formal properties, scope, assumptions
```

Feature metadata MUST include ID, version, owner, status, effective date when relevant, relevant rule IDs, supported deployment targets, compliance sensitivity and expected effects (e.g. payment provider call, DB write). Requirements MUST be maintained independently of implementation code and require authorized review on material changes.

## 4. Example feature review (illustrative)

```markdown
# FEAT-CHECKOUT — Premium Discount (Proposed Change)

**Summary:** Premium discount starts at 100 EUR rather than 150 EUR.

## What changes for a customer?
- At 99.99 EUR: no discount.
- At exactly 100.00 EUR: 10% discount.
- For non-premium customers: no discount.

## What does not change?
- Other discounts and payment-provider authorization rules.
  Evidence status: UNKNOWN until noninterference check is complete.

## Assurance
- Acceptance scenarios: 18/18 PASSED
- Domain invariants: 4/5 VERIFIED; 1 UNKNOWN
- Mutation testing: 23/25 detected
- Permission/side-effect impact: new DB access not detected by static analysis
- Overall: REVIEW REQUIRED (not auto-approvable)

## Decisions
- Product Owner approval: PENDING
- Engineering assurance: BLOCKED on unknown invariant
```

No fabricated coverage, proof or approval is permitted in actual reports. Summaries are derived mechanically from evidence, not from ungrounded AI prose.

## 5. Evidence hierarchy, explicitly non-equivalent

| Evidence | What it supports | What it does NOT show |
|---|---|---|
| Requirements approval | Intent accepted by a responsible human | Implementation correctness |
| Typechecking / memory verifier | Defined safety/type obligations | Business correctness |
| Example and generated tests | Concrete scenarios passed | All possible inputs |
| Branch, MC/DC, mutation evidence | Structural or fault-detection strength | Complete requirements |
| Formal contract proof | Implementation meets stated property in modeled semantics | Specification completeness or correct external systems |
| Relational/equivalence proof | Old/new behaviors equivalent in defined observation domain | Universal real-world equivalence |
| Threat model / security review | Examined security risks in scope | Absence of every vulnerability |

Statuses MUST be explicit: `VERIFIED`, `TESTED`, `REFUTED`, `UNKNOWN`, `STALE`, `NOT_RUN` and `ASSUMED` as applicable. `ASSUMED` MUST never be rendered as `VERIFIED`.

## 6. Default review gates (configurable by enterprise policy)

**Product gate:** Every changed business rule MUST be approved by a designated non-agent owner; permission to approve MUST be tied to repository/platform identity.

**Technical gate:** All mandatory compilation/type/memory checks, acceptance tests and required invariants MUST pass or carry a documented, approved exception. `UNKNOWN` MUST block auto-approval for mandatory properties. Evidence MUST be fresh, bound to the candidate commit and reproducible.

**Escalation gate:** A human engineering/security review MUST be triggered for changes involving:

- Native FFI, `unsafe` boundaries, runtime, compiler, allocator, verifier or code generator.
- Authn/authz, cryptography, secrets, payments, safety-critical behavior, privacy/data retention, or regulated data.
- New network, filesystem, database, third-party, process-execution or privilege effects.
- New dependencies, generated code outside trusted annotation boundaries, or substantial dependency upgrades.
- Contract coverage gaps, UNKNOWN proofs, spec/code disagreement, unexpected behavior diffs, performance/resource regression or unrecognized side effects.
- High-complexity migrations, schema changes, concurrency model changes, and nontrivial production rollout impact.

Organizations MAY require normal source review for all changes, regardless of evidence. The system MUST never claim to replace organizational compliance obligations.

## 7. Change risk classification

For every candidate, the compiler / CI produces the following independently labeled factors: feature criticality, specification confidence, proof completeness, mutation/coverage evidence, dependency impact, effects changes, data classification, implementation risk and runtime/resource change. The aggregate `review_tier` is a configurable policy result, not a learned percentage of correctness.

Recommended tiers:

- `T0 — DOCUMENTATION_ONLY`: metadata changes, no runtime or contract change proven or statically scoped.
- `T1 — FEATURE_REVIEW_ELIGIBLE`: low-risk, well-scoped behavior, signed specs, current complete mandatory evidence, no escalation triggers; eligible for feature-only human review IF organization opts in.
- `T2 — DUAL_REVIEW`: product + engineering review required.
- `T3 — SPECIALIST_REVIEW`: security/privacy/infrastructure/formal methods specialist needed.

Classifiers MUST fail closed on missing evidence, invalid hashes or unresolved privilege/effect analysis.

## 8. Feature review report anatomy

The report MUST have two synchronized presentations from the same signed evidence graph:

### A. Product Owner view

1. Change summary in plain language, verified against structured rule diffs.
2. Before/after examples, boundaries, failure cases and user-visible effects.
3. Explicit assumptions and *what is not yet known*.
4. Requirements acceptance, deployment impact and requested approvals.
5. Small digest of proof/test evidence with status labels and links.

### B. Engineering view

1. All of the above, with exact source/symbol/commit references.
2. Changed public APIs, modules, dependency graph, external effects, generated annotations.
3. Proof obligations, solver versions, tool hashes and counterexamples.
4. Performance/resource and security checks; direct source diff links.
5. Full audit history, signed approvals and evidence attestations.

A human reviewer MUST be able to expand any summary claim into its underlying artifact. The tool MUST not hide contradictory or failed evidence under an overall green badge.

## 9. AI-Agent responsibilities and independence

A coding agent MAY implement code, propose test cases, synthesize proof hints, and draft a change summary. Another agent MAY attempt adversarial tests, boundary discovery and specification-gap analysis. However:

- Agent-generated business requirements and acceptance criteria MUST be labeled proposed, never approved automatically.
- The same agent's tests do not constitute independent business validation.
- The verifier, compiler and review gate MUST operate on immutable revision inputs rather than self-reported agent status.
- Business approvals MUST be issued by an authorized human or separately governed enterprise process.
- The report MUST show which statements were inferred by AI rather than mechanically established.

## 10. Proposed CLI and MCP integration

```bash
orin review --base origin/main --head HEAD --audience product
orin review --base origin/main --head HEAD --audience engineering
orin review gate --policy orin.review.toml
orin evidence export --base origin/main --head HEAD --format json
orin evidence verify --file evidence.json
```

Proposed MCP tools: `feature_review`, `feature_impact`, `evidence_lookup`, `review_gate`. `feature_review` SHOULD default to delta/compact mode; long evidence is available by targeted lookup. The MCP server is advisory unless the CI policy evaluator uses the trusted same evidence and authenticated approval source.

Example enterprise policy (illustrative schema):

```toml
[review]
mode = "feature_first"
fail_closed = true
require_signed_evidence = true

[review.tiers]
feature_only_max = "T1"

[review.product]
require_human_approval_for_rule_change = true

[review.escalation]
unsafe = "T3"
auth = "T3"
payment = "T3"
unknown_mandatory_proof = "T2"
new_external_effect = "T2"
```

## 11. Release and audit requirements

- Proofs/reports MUST be bound to exact commits, toolchains, relevant policies and contract hashes.
- Review decisions MUST be auditable and preserved across deployments.
- CI MUST invalidate approvals if code, contracts, assumptions or evidence inputs change after review.
- Unapproved business rule changes MUST block a protected release.
- Reviewer role separation and authorization are external platform responsibilities, enforced by the CI integration.
- Observability SHOULD link runtime feature flags and rollout versions to approved behavior-change IDs.

## 12. Implementation plan

**Phase 1 — Traceability:** stable feature/rule IDs, annotations, manifest, test linkage, human-readable report; no proof claims.

**Phase 2 — Evidence graph:** compiler-based impact graph, coverage and mutation, signed baseline and diff reports.

**Phase 3 — Proof integration:** formal contracts, proof statuses, relational old-vs-new checks for a restricted pure subset; SMT counterexamples.

**Phase 4 — Controlled feature-first gate:** opt-in enterprise policy, strong evidence provenance, platform approvals, escalation and audits.

**Phase 5 — Advanced:** state-transition contracts, temporal properties, rollout/feature-flag attestations, proof regression and dependent feature impact.

## 13. Acceptance tests for this RFC

- [ ] Changed feature spec without authorized approval blocks a protected merge.
- [ ] An untested case is never labeled verified.
- [ ] Feature-only workflow unavailable when an escalation rule fires.
- [ ] Stale evidence (commit hash mismatch) is rejected.
- [ ] AI-authored feature spec is distinguishable from human-approved baseline.
- [ ] Reports show before/after behavior, examples, assumptions and unknowns.
- [ ] Engineering reviewer can navigate every material claim to source and evidence.
- [ ] Unmapped changed behavior is surfaced, not silently ignored.
- [ ] Product and engineering approvals remain separate.

## 14. Research and precedents

- Dafny, modular verification and contracts: https://dafny.org/dafny/DafnyRef/DafnyRef
- Google engineering review guidelines, including design, functionality, complexity: https://google.github.io/eng-practices/review/
- oasdiff, structured API/breaking-change reports: https://github.com/oasdiff/oasdiff
- RFCs 014–016 in this repository.
