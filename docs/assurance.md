# Assurance ledger: claims, evidence and proof debt

_Updated: 2026-10-13 · ADR-0020 D7 (vision §20a, phase L0). This file is the claim-vs-evidence
table. Update it in the same PR that changes the evidence for a claim._

Every claim has two separate labels:

- **status:** `VERIFIED`, `REFUTED`, `UNKNOWN`, `ASSUMED`, … (ADR-0020 D1);
- **assurance level:** how far the evidence reaches:
  - `MODEL_ONLY`: Lean proves the property of a formal model; the Orin implementation is not
    bound to it.
  - `TRANSLATION_VALIDATED`: an independent validator checks each concrete run.
  - `IMPLEMENTATION_VERIFIED`: a checked relation binds the real implementation to the model.
  - `TESTED_ONLY`: tests, sanitizers, differential runs or bounded model checking.

Reproducible builds and `stage2 == stage3` are reproducibility, not correctness.

## Claims

| ID | Claim | Assurance today | Evidence | Gap / proof debt |
|---|---|---|---|---|
| C1 | The RC machine never touches freed memory (`run_safe`) | `MODEL_ONLY` | Lean, `formal/Orin/Theorems.lean`; axiom audit in CI | `orin_runtime.c` is not bound to the model (R3/R4) |
| C2 | Copy-on-write preserves value semantics (`makeUnique_store_cow`) | `MODEL_ONLY` | Lean, `COW.lean` | same as C1 |
| C3 | MIR accepted by the ownership checker is memory-safe (`check_sound`) | `MODEL_ONLY` for the structured MIR core | Lean, `Sound.lean`/`Top.lean` | see C4 for the implementation gap, plus: calls, loops, arrays, closures, vtables and floats are outside the model; `ill` (null/type confusion) is not excluded |
| C4 | `compiler/verify` implements the Lean checker | `TESTED_ONLY` | hand transcription; regression cases in `compiler/tests/verify_main.or`; Finding 1 fixed | no differential test of Lean `check` against `compiler/verify` yet (L1); Findings 2–7 in `docs/formal.md` open |
| C5 | Every compiled program is accepted by the ownership verifier | enforced on every compile; level of C3/C4 | verifier gates code generation (ICE exit 70); `tools/verify_all.py` | inherits C3/C4 |
| C6 | Optimisations (owned params, last-use moves, prune) preserve behaviour | `TESTED_ONLY` | `diff_backends.py --mode opt`; memory safety re-checked by the verifier (C5) | no translation validation (L2 target) |
| C7 | HIR → MIR lowering preserves source semantics | `TESTED_ONLY` | about 420 conformance programs, two backends, sanitizers | no source semantics in Lean |
| C8 | C and LLVM backends emit the MIR semantics | `TESTED_ONLY` | backend differential tests, LLVM fixed-point self-build | no translation validation |
| C9 | The type checker is sound for the language core | `TESTED_ONLY` | error suite, conformance suite | no type-soundness theorem |
| C10 | The platform layer meets its contracts | `TESTED_ONLY` (bounded) | 651 contract tests, CBMC bounded harnesses, boundary checker | bounded only; no Frama-C/WP proof; float/clock wrappers have no harness |
| C11 | Contract `VERIFIED` results are correct | `TESTED_ONLY` for the VC generator; solver trusted | `tools/test_verify_contracts.py` (known VERIFIED/REFUTED cases) | VC encoder not proved; no solver certificates; model assumptions A-INT/A-DIV/A-PARTIAL are listed in every result |
| C12 | Contract erasure leaves code unchanged | `TESTED_ONLY` | `tools/test_contract_erasure.py` (byte-identical C/LLVM) | corner case: an instantiation used only by a contract |
| C13 | The compiler binary comes from its source | reproducibility | diverse double root (seed and Rust Stage 0 → identical `stage2.c`), `stage2 == stage3` | external C compiler trusted (`docs/tcb.md`) |

## Fail-closed gates (established, mandatory in CI)
- Lean builds with the pinned toolchain (`formal/lean-toolchain`). Headline theorems use only the
  standard axioms (`Audit.lean`, `formal/check.sh`); `sorry` fails the build.
- Ownership verifier on every compile; `verify_all` over the compiler itself.
- Bootstrap fixed point and identical roots; platform boundary, contract tests and CBMC harnesses.

## Proof debt (risk-ranked, vision §20a)

| P | Item | Phase | Plan |
|---|---|---|---|
| P0 | Differential test of Lean `check` against `compiler/verify` on generated structured MIR (C4) | L1 | export the Lean checker as an executable; random MIR generator; CI step |
| P0 | Mutation corpus: injected faults must be rejected by the verifier (drop a release, extra release, use after move, store through a shared reference) and caught by the opt-diff test | L1 | `tools/mutate_mir.py`; CI step; a mutant that survives is a finding |
| P0 | Translation validator for last-use moves / owned parameters (C6) | L2 | independent checker comparing pre- and post-opt MIR; the vertical proof slice of §20a |
| P0 | Call rule, loops, arrays in the Lean model (C3) | L3 | extends `check_sound` |
| P0 | Runtime refinement: core dialect in Orin refines the Lean machine (C1, C2) | L4 | runtime R3/R4 (spec 19) |
| P0 | Effects, capabilities and information-flow soundness | L3 | proved with their phase (ADR-0020 D5), not after it |
| P0 | VC generator soundness (C11) | L3 | Lean model of the VC encoding for the int/bool fragment, or solver certificates |
| P1 | Type soundness for the core calculus (C9) | L3 | |
| P1 | Backend translation validation (C8) | L3–L5 | |
| P1 | Platform layer full proof (C10) | L4 | Frama-C/WP on `platform/` |

## Rules
- A result without an assurance level is reported as `TESTED_ONLY` at best.
- A change that weakens a claim, adds an axiom, or moves a gate from fail-closed to advisory needs
  explicit human approval in the PR (vision §20a governance). A red gate is never fixed that way.
