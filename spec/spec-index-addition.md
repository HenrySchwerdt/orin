# Add these entries to your existing `spec/spec.md` table

```markdown
| `14-business-logic-testing.md` | Business rule scenarios, contract-to-test mapping, coverage, mutation testing |
| `15-contracts-invariants-and-formal-verification.md` | Optional function contracts, invariants, SMT proofs, proof regression |
| `16-semantic-change-analysis.md` | Version-to-version business behavior diffs, impact and PO-readable changes |
| `17-feature-first-review-and-trust.md` | Feature-first review, evidence trust, human sign-off and escalation gates |
```

## Additional cross-cutting design principle

> Orin SHOULD enable product owners to review *what business behavior changes*, with proof and test evidence, rather than requiring them to read source code. A low-risk change MAY be eligible for feature-only human review under explicit enterprise policy; code, security and platform review remain mandatory where risk, missing proof or policy requires them. Neither tests nor proofs establish that a business specification is complete or correct.
