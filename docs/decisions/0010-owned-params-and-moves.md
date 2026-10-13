# ADR-0010: Inferred owned parameters, last-use moves and RC cancellation (MIR)

Status: accepted (2026-10-13). Spec 06 "borrow-like internal transfer (not source syntax)" and
"retain-release cancellation"; spec 11 optimisation order.

## Decision
- MIR functions get per-parameter modes: **borrowed** (today's convention) or **owned** (the
  callee receives one counted reference and must consume, return or release it).
- A MIR→MIR pass (`compiler/opt/`) infers modes: a parameter is owned if the callee would
  otherwise `IDup` it to store/return/mutate it (e.g. functions that return an updated version of
  their argument — the class mutating-method lowering of ADR-0009 and functional state threading).
  Interprocedural fixpoint over the call graph; recursion handled by iteration to a fixpoint
  starting from "borrowed".
- At call sites, an argument for an owned parameter is passed by **move** if the argument local
  is dead after the call (last use), else by `IDup`.
- Peephole: cancel `IDup x; … IRelease x` pairs and `IDup` immediately consumed by a move when
  no intervening use requires the count.
- No source syntax; no observable semantic change. Every optimised function MUST pass the
  verifier (docs/mir.md, extended: owned params start in state Owned; an `ICall` operand in an
  owned-parameter position is consumed).
- Differential testing (optimised vs unoptimised, all suites) and benchmarks gate the merge.
