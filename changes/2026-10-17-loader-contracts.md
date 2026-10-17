- **Contracts for `compiler/loader` (ADR-0053 Addendum A).** `orin verify --contracts` now proves 13 more obligations of the loader module
  (98 to 85 `UNKNOWN`, none `VERIFIED` lost): loop `@Invariant` on the scans of `dirname`, `relativeTo`, `SrcRoot.unknownModules` and
  `Sources.constructor`; `@Ensures` on the helper predicates the class invariants are built from (`edgesWellFormed`, `edgesAllowed`,
  `allNormalized`, `allDistinct`, `isTopological`, `allUnitsWellFormed`, `unitsIndexed`, `noneDone` hold for an empty array;
  `allNormalized` equals its `every`; `isAbs` equals its definition; `isValidOutcome` states what it means), and `allWellFormed(result.diags)`
  on `loadAll` / `loadWithOverlay`. The new clauses are runtime-checked under `--check-contracts` and cheap; no existing contract was
  weakened or removed and no logic changed. What is left (85) needs verifier features: string methods (`startsWith`, `split`),
  `reduce`, `isValidCode` of literals, callee results known only by contract.
