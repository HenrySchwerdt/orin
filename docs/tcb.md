# Trusted computing base (TCB) inventory

_Updated: 2026-10-13 · ADR-0020 (vision phase 0). Update this file whenever a component moves in
or out of trust._

Which claim rests on which evidence, and at which assurance level, is in
[assurance.md](assurance.md).

A guarantee Orin reports ("memory safe", "VERIFIED") holds only if every component it rests on is
correct. This table lists those components, how much each is trusted, and what evidence exists
today. "Trusted" means a bug there can silently break a guarantee.

## Memory safety of a compiled program

| Component | Trust | Evidence today | Gap |
|---|---|---|---|
| Lexer, parser | trusted for meaning (what was written) | conformance suites (the Stage 0 vs Stage 1 parser differential was retired with Stage 0) | no formal grammar proof |
| Type checker, HIR | trusted for type safety | ~420 conformance programs, error suite, fmt/LSP corpus | not verified |
| HIR → MIR lowering, optimiser (owned params, moves, prune) | **not trusted for ownership**: output is re-checked | independent MIR ownership verifier on every compile (ICE exit 70) | lowering bugs can still change *behaviour* (not safety) |
| MIR ownership verifier (`compiler/verify`) | trusted | Lean: soundness of the checker *transcription* for the structured MIR core (`formal/`, `check_sound`); targeted regression cases | the Orin implementation is not proved equal to the Lean transcription; MIR features outside the core (closures, vtables, floats) are checked by rules not yet in the model |
| Lean model (`run_safe`, `makeUnique_store_cow`) | trusted (Lean kernel) | machine-checked | models the RC machine, not the C runtime code |
| C backend (`cemit`), LLVM backend | trusted | backend differential tests (C vs LLVM vs builtins vs opt), LLVM fixed-point self-build | no translation validation |
| Runtime object model (`runtime/orin_runtime.c`: RC, COW, arrays, strings) | trusted | ASan/UBSan runs of all suites, `ORIN_STATS` counters | not verified; R3 moves it into Orin, R4 refinement proof |
| L0 platform layer (`platform/`) | trusted, deliberately small (≤1000 code lines, contracts and comments excluded: the budget limits trusted code, not its specification) | ACSL-style contracts, 741 contract tests (incl. path-scope and policy primitives, symbolic-link cases), CBMC bounded harnesses (incl. `policy_parse`, `path_normalize`, `path_within`), boundary checker | bounded, not full Frama-C proof; float text conversion and clock are thin libc wrappers without harnesses |
| Capability grants (ADR-0027): grant table and authorisation in `runtime/orin_runtime.c` (`orin_cap_*`, `fs_check`), `std:host` / `std:fs` scope functions, the checker rules for resource handles | trusted for **authority**, not for memory safety | checker + independent MIR verifier rules (C14/C15), runtime handle validation (traps), runtime and platform tests, CBMC for the pure path logic | a grant is only as strong as the C runtime that checks it; no proof that every privileged operation goes through a check (an audit of `orin_platform_*` callers is the evidence: the platform boundary check keeps the list closed); races and hard links are out of scope; native code can bypass |
| C compiler, linker, libc, libm, OS kernel | trusted (external) | — | outside Orin's control; reproducible builds limit exposure |

## The compiler binary itself (bootstrap)

| Component | Trust | Evidence |
|---|---|---|
| Seed C (`seed/orin-seed.c.gz`) | trusted; single root | the seed from source commit `ec1ba3e` was cross-checked by the diverse double root (Rust Stage 0 root and seed root gave a byte-identical `stage2.c`; reproducible from branch `archive/stage0-final`, docs/bootstrap.md). Later seeds are not cross-checked by an independent root: they rest on that clean starting point, the reviewed source diff and the fixed point |
| Rust Stage 0 (branch `archive/stage0-final`) | retired; no longer part of the build | its evidence is historical (valid for `ec1ba3e` only); the Rust toolchain is not in the TCB of the current build |
| Fixed point | — | `stage2.c == stage3.c`; LLVM-built compiler reproduces `stage3.c` |

## Contract verification (ADR-0012 phase 2, in progress)

| Component | Trust | Notes |
|---|---|---|
| Contract checker / VC generator | trusted | to be tested against known `REFUTED` cases |
| SMT solver (Z3) | trusted | results are `VERIFIED` only with listed assumptions; no proof certificates yet |
| Runtime contract checks (`--check-contracts`) | trusted like the backend | traps exit 101 |

## Not covered by any guarantee today
FFI (none exists yet), network/DB (no std API yet), timing/side channels, business-rule
completeness, deployment configuration, ambient output (`console.*`, `exit`), the authority of a spawned shell
command, OS-level isolation (a hostile native binary can ignore every grant). These become explicit `ASSUMED` boundaries when the
corresponding features land (ADR-0020).
