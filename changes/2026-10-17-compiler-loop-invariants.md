- **Loop invariants in the compiler sources (ADR-0053 Addendum A, group U4).** The scanning, accumulating and counting loops
  of `compiler/syntax/lexer.or` and of the `opt`, `fmt`, `backends`, `lsp`, `mir`, `json`, `hir`, `lower` and `verify` modules
  now carry `@Invariant` clauses (index and range bounds, `acc.length == i`, monotone counters), so `orin verify --contracts`
  proves the substring/index bounds, `emit`/`fail` preconditions and length postconditions behind them instead of reporting
  UNKNOWN. A few loops were rewritten without `break`/`continue` or as indexed loops (same behaviour) because the verifier
  ignores invariants on loops with a jump and cannot count a `for .. of` iteration; `Lexer.step` states the class invariants
  it keeps as `@Ensures`, a few private lexer helpers get `@Requires`, and some accessors got `@Ensures(result == this.f.length)`.
  Loop invariants are type-checked only (no run-time cost). No existing contract was weakened or removed.
