- **Loop invariants in `compiler/syntax` (ADR-0053 Addendum A).** `indexRows` (`precedence.or`) and the line-comment scan of
  `scanComments` (`trivia.or`) get loop `@Invariant` clauses (index bounds), so the verifier proves `indexRows`'s
  `@Ensures(result.size <= rows.length)` and the `src.charCodeAt(e - 1)` bound in `scanComments`. Contract-only change; no
  logic change. The rest of the `syntax` UNKNOWN obligations need verifier features (the `?` operator, mutating calls in
  expressions, string contents, recursive types, module-qualified names), not contracts.
