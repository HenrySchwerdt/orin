# Orin Specification 14 — Business Contract Testing

Status: PROPOSED (not implemented)  
Version: 0.1  
Dependencies: modules, annotations, type system, MCP, compiler IR  
Scope: test declarations, executable contracts, evidence, and review; not an assertion of complete correctness.

## 1. Motivation and normative principles

Business correctness is different from compilation, memory safety, and line coverage. Orin SHALL make business-rule-to-test traceability a first-class development workflow. The compiler/test runner SHALL report what is specified, what is exercised, what is asserted, and what remains unverified. Passing tests MUST NOT be reported as proof that all business requirements are correct.

The design SHOULD keep production syntax familiar to TypeScript developers and allow the test library to operate without runtime reflection. Business-rule metadata SHALL be retained in test artifacts but MAY be removed from optimized release binaries.

## 2. Terminology and evidence levels

- **Rule:** a stable, unique, human-authored business requirement ID, description, and owner/source.
- **Scenario:** a named set of initial conditions and expected observable outcome(s) for a rule.
- **Test:** executable verification using an oracle that is separate from the production implementation.
- **Property:** a general invariant checked over generated inputs, with recorded random seed and shrinking when applicable.
- **Mutation:** a controlled alteration to production behavior; surviving mutations indicate possible weaknesses, not necessarily bugs.
- **Evidence:** a versioned link among a rule, its scenarios, source implementation, assertions, and executed test results.

Evidence statuses SHALL distinguish `declared`, `implemented`, `executed`, `passed`, `failed`, `skipped`, `blocked`, `stale`, and `reviewed`. A scenario is not verified just because it has a test annotation.

## 3. Minimal developer API (design syntax; not yet grammar-stable)

Production code:

```typescript
@Rule("SHOP-001", "Premium customers get 10% discount for totals >= 10000 cents")
export function discount(totalCents: int, premium: bool): int {
  if (premium && totalCents >= 10000) {
    return totalCents / 10;
  }
  return 0;
}
```

Example tests:

```typescript
@Tests("SHOP-001")
class DiscountTests {
  @Case("Premium above threshold")
  above() { expect(discount(15000, true)).toBe(1500); }

  @Case("Premium below threshold")
  below() { expect(discount(9999, true)).toBe(0); }

  @Case("Exactly at threshold")
  boundary() { expect(discount(10000, true)).toBe(1000); }

  @Case("Regular customer")
  regular() { expect(discount(15000, false)).toBe(0); }
}
```

These annotations link source to declared requirements. They do **not** infer whether the set of tests is complete. Rule definitions and scenario expectations SHOULD be held in an independent, reviewer-owned contract file for business-critical modules.

## 4. Independent business contract

Recommended file: `src/<module>/contracts/SHOP-001.contract.md` or a machine-readable equivalent. A rule SHOULD contain:

- Unique ID, title, version, and source/owner.
- Preconditions, expected outputs, errors, and important invariants.
- Equivalence classes, boundary conditions, and negative cases.
- Relevant state transitions when behavior depends on history.
- Explicit scenarios with IDs and expected results, independently approved when required.
- Criticality (`standard`, `important`, `critical`).

Example minimal YAML representation (alternative to Markdown with structured frontmatter):

```yaml
id: SHOP-001
version: 1
owner: product
summary: Premium receives 10% off at or above 10000 cents
scenarios:
  - id: S1
    given: { totalCents: 15000, premium: true }
    expect: { discountCents: 1500 }
  - id: S2
    given: { totalCents: 9999, premium: true }
    expect: { discountCents: 0 }
  - id: S3
    given: { totalCents: 10000, premium: true }
    expect: { discountCents: 1000 }
  - id: S4
    given: { totalCents: 15000, premium: false }
    expect: { discountCents: 0 }
```

Implementation and tests MUST NOT silently rewrite approved expectations. Changes to a business contract SHALL be separately visible in code review. IDs SHALL remain stable across refactoring.

## 5. Required testing layers

1. **Scenario / example tests:** Expected results for approved business scenarios; named and traceable.
2. **Boundary and decision analysis:** Explicit threshold tests; branch coverage and optional MC/DC for high-criticality conditions.
3. **Property-based tests:** Check reusable laws across generated inputs. Shrink failures; persist the minimal counterexample and seed. Properties MUST NOT merely duplicate implementation algorithms.
4. **Mutation tests:** Modify business-relevant operators and branch predicates at typed HIR/MIR level; run impacted tests; record killed, survived, equivalent/waived, invalid, and timeout cases separately. Equivalent mutations require human review or clear documented justification.
5. **State machine/contract tests:** For workflows like payment lifecycle, test allowed transitions and forbidden transitions, including failure paths and retries.
6. **Integration/contract tests:** Test external boundaries with controllable test doubles or sandboxes. Do not substitute implementation mocks for the domain oracle.

## 6. Compiler and test-runner requirements

- The compiler SHALL maintain a stable mapping `Rule ID -> declaration(s) -> scenario ID(s) -> tests -> observed outcome`.
- The test runner SHALL reject duplicate rule IDs in the same versioned namespace and flag orphan scenarios/tests.
- `orin test` SHALL run ordinary unit tests, scenario tests, and requested property tests.
- `orin test --changed` SHALL use the module dependency graph and changed rule versions to select affected tests; uncertainty MUST broaden selection instead of falsely claiming full coverage.
- `orin test --business` SHALL generate machine-readable and reviewer-readable reports.
- `orin test --mutate` MAY be expensive and SHOULD support per-module or CI-scheduled execution.
- Annotation processing SHALL happen at compile time; test metadata SHALL NOT require release-time reflection or dynamic registration.
- Deterministic execution seeds, time controls, and fake I/O SHALL be available to make business tests reproducible.
- Test-time memory errors must remain distinct from business-assertion failures.

## 7. Review report and quality gates

Each rule's report SHALL include:

| Field | Meaning |
|---|---|
| Rule ID and contract version | Stable traceability |
| Contract owner / approval | Who validated the requirement (if applicable) |
| Implementing symbols/modules | Code under review |
| Declared scenarios | Independently defined expected cases |
| Executed/pass/fail/skipped scenarios | Actual test-run evidence |
| Boundaries and MC/DC | Structural evidence, where enabled |
| Mutation results | Killed/survived/waived/invalid, with source diff |
| Properties and counterexamples | Seeds, shrink results, invariant descriptions |
| Change impact | Other rules/modules potentially affected |
| Source and test revision | Prevents stale evidence |

CI policies may require: all declared critical scenarios passing; no missing scenario tests; no unreviewed high-risk surviving mutations; approved changes to critical contracts. Percentage thresholds SHALL NOT imply proof of complete correctness. Proof obligations and model checking can supplement testing where feasible.

## 8. Agent/MCP interface

Extend the existing small MCP toolset rather than proliferating many top-level tools:

- `inspect({kind:"business_rule", id:"SHOP-001", detail:"compact"})`: returns contract/version, implementation, missing and executed cases, risk notes.
- `test({scope:"changed", evidence:"delta"})`: reports changed rule/scenario statuses since a known revision.
- `test({rule:"SHOP-001", mutation:true})`: targeted mutation analysis.
- `check({scope:"changed", include:"contracts"})`: rejects broken links and forbidden dependency changes.

Responses SHOULD be compact and structured, with stable IDs, hashes/revisions, and pointers to full traces on demand. Never describe unexecuted tests as passing. Agents SHOULD generate tests from a reviewed business contract, not derive expected values exclusively from their own implementation.

## 9. Separation of trust

The same agent writing implementation and tests can make the same mistake twice. For critical rules, contracts SHOULD be authored/approved separately and test oracles SHOULD be independently reviewed. Use adversarial review agents as assistance, not as a guarantee. Tests prove only the cases and properties checked under the recorded assumptions.

## 10. Incremental roadmap

- **MVP:** `@Rule`, `@Tests`, `@Case`, `expect`, traceability registry, `orin test --business`, machine-readable report.
- **Next:** contract-file parser/validation, boundaries, changed-module selection, reviewer UI and MCP deltas.
- **Later:** property generation/shrinking, typed mutation engine, MC/DC, state-machine test generation, independent oracles, formal contracts and selected proofs.

Do not make advanced testing features prerequisites for self-hosting the minimal compiler.

## 11. Research/practice references

- NASA guidance on MC/DC: https://swehb.nasa.gov/plugins/viewsource/viewpagesrc.action?pageId=209846403
- Lampropoulos, Hicks, Pierce, *Coverage Guided, Property Based Testing*, OOPSLA 2019: https://doi.org/10.1145/3360607
- PIT mutation-testing concepts: https://pitest.org/quickstart/basic_concepts/
- Keles, Miao, Lampropoulos, *Evaluating Shrinking*, Haskell Symposium 2026: https://arxiv.org/abs/2608.09935

**Status:** This document is a proposed extension to Orin's specification; no command or feature described here is asserted to exist yet.
