# Trusted computing base (TCB) inventory

_Updated: 2026-10-13 · ADR-0020 (vision phase 0). Update this file whenever a component moves in
or out of trust._

A guarantee Orin reports ("memory safe", "VERIFIED") holds only if every component it rests on is
correct. This table lists those components, how much each is trusted, and what evidence exists
today. "Trusted" means a bug there can silently break a guarantee.

## Memory safety of a compiled program

| Component | Trust | Evidence today | Gap |
|---|---|---|---|
| Lexer, parser | trusted for meaning (what was written) | conformance suites, Stage0/Stage1 parser differential (`tools/diff_parsers.py`) | no formal grammar proof |
| Type checker, HIR | trusted for type safety | ~420 conformance programs, error suite, fmt/LSP corpus | not verified |
| HIR → MIR lowering, optimiser (owned params, moves, prune) | **not trusted for ownership**: output is re-checked | independent MIR ownership verifier on every compile (ICE exit 70) | lowering bugs can still change *behaviour* (not safety) |
| MIR ownership verifier (`compiler/verify`) | trusted | Lean: soundness of the checker *transcription* for the structured MIR core (`formal/`, `check_sound`); targeted regression cases | the Orin implementation is not proved equal to the Lean transcription; MIR features outside the core (closures, vtables, floats) are checked by rules not yet in the model |
| Lean model (`run_safe`, `makeUnique_store_cow`) | trusted (Lean kernel) | machine-checked | models the RC machine, not the C runtime code |
| C backend (`cemit`), LLVM backend | trusted | backend differential tests (C vs LLVM vs builtins vs opt), LLVM fixed-point self-build | no translation validation |
| Runtime object model (`runtime/orin_runtime.c`: RC, COW, arrays, strings) | trusted | ASan/UBSan runs of all suites, `ORIN_STATS` counters | not verified; R3 moves it into Orin, R4 refinement proof |
| L0 platform layer (`platform/`) | trusted, deliberately small (≤1000 lines) | ACSL-style contracts, 651 contract tests, CBMC bounded harnesses, boundary checker | bounded, not full Frama-C proof; float text conversion and clock are thin libc wrappers without harnesses |
| C compiler, linker, libc, libm, OS kernel | trusted (external) | — | outside Orin's control; reproducible builds limit exposure |

## The compiler binary itself (bootstrap)

| Component | Trust | Evidence |
|---|---|---|
| Seed C (`bootstrap/seed/orin-seed.c.gz`) | trusted unless cross-checked | diverse double root: the Rust Stage0 root and the seed root produce byte-identical `stage2.c` in CI |
| Rust Stage0 (`bootstrap/`, frozen) | second root only | Rust toolchain is then part of that root's TCB |
| Fixed point | — | `stage2.c == stage3.c`; LLVM-built compiler reproduces `stage3.c` |

## Contract verification (ADR-0012 phase 2, in progress)

| Component | Trust | Notes |
|---|---|---|
| Contract checker / VC generator | trusted | to be tested against known `REFUTED` cases |
| SMT solver (Z3) | trusted | results are `VERIFIED` only with listed assumptions; no proof certificates yet |
| Runtime contract checks (`--check-contracts`) | trusted like the backend | traps exit 101 |

## Not covered by any guarantee today
FFI (none exists yet), network/DB (no std API yet), timing/side channels, business-rule
completeness, deployment configuration. These become explicit `ASSUMED` boundaries when the
corresponding features land (ADR-0020).
