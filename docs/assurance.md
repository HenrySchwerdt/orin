# Assurance ledger: claims, evidence and proof debt

_Updated: 2026-10-13 · ADR-0020 D7 (vision §20a, phases L0, L1: C4 differential test and mutation corpus). This file is the claim-vs-evidence
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
| C3 | MIR accepted by the ownership checker is memory-safe (`check_sound`) | `MODEL_ONLY` for the structured MIR core | Lean, `Sound.lean`/`Top.lean` | see C4 for the implementation gap, plus: calls, loops, arrays, closures, vtables and floats are outside the model; `ill` (null/type confusion) is not excluded (realised once, finding F-shape; runtime field bounds checks are the backstop) |
| C4 | `compiler/verify` implements the Lean checker | `TESTED_ONLY` | hand transcription; regression cases in `compiler/tests/verify_main.or`; Finding 1 fixed; **differential test** `tools/diff_verifier_lean.py` (Lean `check` run as `orin_check` vs `compiler/verify`, 12000 generated programs per CI run, verdicts agree up to one allow-listed class, Finding 6; CI `formal` job); **mutation corpus** `tools/mutate_mir.py` (about 20,000 injected ownership bugs in real MIR, none survives; CI `test` job) | structured fragment only (no calls, loops, arrays, strings, `Imm`, owned params, class-ill-typed MIR); a differential test is evidence, not a proof that the Orin source implements `check`; Findings 2-7 in `docs/formal.md` open |
| C5 | Every compiled program is accepted by the ownership verifier | enforced on every compile; level of C3/C4 | verifier gates code generation (ICE exit 70); `tools/verify_all.py` | inherits C3/C4 |
| C6 | Optimisations (owned params, last-use moves, prune) preserve behaviour | `TESTED_ONLY` | `diff_backends.py --mode opt`; memory safety re-checked by the verifier (C5) | no translation validation (L2 target) |
| C7 | HIR → MIR lowering preserves source semantics | `TESTED_ONLY` | about 420 conformance programs, two backends, sanitizers | no source semantics in Lean |
| C8 | C and LLVM backends emit the MIR semantics | `TESTED_ONLY` | backend differential tests, LLVM fixed-point self-build | no translation validation |
| C9 | The type checker is sound for the language core | `TESTED_ONLY` | error suite, conformance suite | no type-soundness theorem |
| C10 | The platform layer meets its contracts | `TESTED_ONLY` (bounded) | 689 contract tests (incl. the file-stream primitives of ADR-0025), CBMC bounded harnesses, boundary checker | bounded only; no Frama-C/WP proof; float/clock wrappers have no harness |
| C11 | Contract `VERIFIED` results are correct | `TESTED_ONLY` for the VC generator; solver trusted | `tools/test_verify_contracts.py` (known VERIFIED/REFUTED cases) | VC encoder not proved; no solver certificates; model assumptions A-INT/A-DIV/A-PARTIAL are listed in every result |
| C12 | Contract erasure leaves code unchanged | `TESTED_ONLY` | `tools/test_contract_erasure.py` (byte-identical C/LLVM) | corner case: an instantiation used only by a contract |
| C14 | A resource handle (`File`, ADR-0025) is never duplicated, stored, returned, captured or compared, and every opened file is closed exactly once on every path of the function that opened it | `TESTED_ONLY` (two independent enforcement layers) | type checker rules E0450/E0451/E0452 (`compiler/check/resources.or`, 34 error tests) and, independently, the MIR verifier's `MHandle` rules (wf + linear open/close dataflow; 31 hand-built MIR cases in `compiler/tests/verify_main.or`); `verify_all` over the compiler; runtime validates every handle (generation-tagged) and traps on a stale one, so a violation of the rules is never memory-unsafe | the handle rules are an extension of the verifier that is **not** in the Lean model (C3/C4 cover only the RC ownership core); no differential test against a model; "closed on trap" means the exit hook flushes and closes (no `Err`), nothing for a kill by signal; calls into the runtime (`orin_file_*`) are trusted C |
| C15 | A capability grant (ADR-0021 Stage A, ADR-0027) cannot be forged, duplicated, stored, returned or captured; a std I/O call needs a grant of the right family; a narrowed grant never has more authority than its parent; the runtime refuses an operation outside the host policy, the read-only flag or the path scope | `TESTED_ONLY` (three enforcement layers: checker, MIR verifier, runtime/platform) | checker: E0470-E0472 and E0450-E0452 for grants (`tests/next/errors/e04[457]*_grant*`, `e0470_*`); MIR verifier: the handle rules of C14 apply unchanged to grants plus the opener-authority rule, 23 + 31 hand-built MIR cases in `compiler/tests/verify_main.or`; runtime: every operation validates the tagged, generation-checked handle and traps on a forged / stale / revoked / wrong-family one (`runtime/tests/runtime_test.c`); path scope and deny policy: platform contracts + 52 contract tests + CBMC harnesses for `policy_parse`, `path_normalize`, `path_within` (canonical form, idempotence, agreement with the component definition, transitivity); end-to-end: `tests/next/run/cap_*.or`, `tools/test_capabilities.sh` (`ORIN_DENY` matrix, both backends) | as C14 (not in the Lean model); the C runtime and platform layer are trusted code; **path scopes are not race-free** (TOCTOU), do not see hard links or mounts; **`console.*` and `exit` are ambient** (recorded as OSIG events only); a `ProcessGrant` that may spawn is ambient authority (`shell` bypasses every other grant); native code / FFI / a modified compiler can bypass all of it (needs OS isolation, ADR-0021); the OSIG records primitive I/O call sites (`PERFORMS_IO`), not transitive effects (Stage B) |
| C13 | The compiler binary comes from its source | reproducibility | `stage2 == stage3` for every seed; diverse double root (seed and Rust Stage 0 → identical `stage2.c`) established once, for the seed from `ec1ba3e`, and no longer re-run (Stage 0 retired, branch `archive/stage0-final`) | later seeds have a single root (chain argument only, docs/bootstrap.md); external C compiler trusted (`docs/tcb.md`) |

## Findings (gaps that were realised, not just listed)

| Id | Finding | Mitigation | Level | Proper fix |
|---|---|---|---|---|
| F-shape | **C3/C5 gap realised: shape confusion from a lowering bug passed the ownership verifier.** `?` inside a mutating class method returning `Result` returned a bare `Result` struct where the caller expected the `{ receiver, result }` pair; the caller's `orin_struct_get` read past the end of the struct (ASan heap-buffer-overflow, plain build: segfault). The MIR was ownership-correct, so the verifier (C5) accepted it: it checks RC/ownership, not value shapes (field index vs struct arity, struct vs array vs string) - exactly the `ill` class C3 says is not excluded. | **Runtime field bounds checks** (`orin_chk_slot`, `@orinl_slot`): every struct slot access on an object of unknown provenance checks kind and `index < nslots`, array slot access/push check kind; a mismatch traps (`trap: field access on a value of the wrong shape (compiler bug)`, exit 101). `TESTED_ONLY`: `tests/next/run/shape_confusion_try_in_mutating_method.or` (C, ASan, LLVM), `runtime/tests/runtime_test.c`. Cost: `docs/benchmarks.md`. Elided only where the object is a fresh `orin_struct_new` with the constant arity of the same instruction (initialising stores). | `TESTED_ONLY` | MIR shape/type check in the verifier (P0 below). **Policy (2026-10-13, project owner delegated the call):** the checks stay on (about +23% selfcompile, see `docs/benchmarks.md`) until the verifier proves shapes; then the compiler may omit them exactly where shapes are proven (statically proven property, no redundant runtime check), never by a flag that trades safety for speed. |

## Fail-closed gates (established, mandatory in CI)
- Lean builds with the pinned toolchain (`formal/lean-toolchain`). Headline theorems use only the
  standard axioms (`Audit.lean`, `formal/check.sh`); `sorry` fails the build.
- Ownership verifier on every compile; `verify_all` over the compiler itself.
- Bootstrap fixed point and identical roots; platform boundary, contract tests and CBMC harnesses.

## Proof debt (risk-ranked, vision §20a)

| P | Item | Phase | Plan |
|---|---|---|---|
| P0 | Differential test of Lean `check` against `compiler/verify` on generated structured MIR (C4) | L1 | **done for the structured fragment** (`formal/Orin/Exec.lean`, `tools/gen_mir_fragment.py`, `tools/diff_verifier_lean.py`, `compiler/tests/verify_text.or`; CI `formal` job). Open: extend the generator with calls/owned params, loops (needs a Lean model), arrays; allow-listed class F6 (verifier accepts `IStructNew d [.. d ..]`, model rejects) still to be resolved by modelling `IStructNew` as one instruction or rejecting it in `wf.or` |
| P0 | Mutation corpus: injected faults must be rejected by the verifier (drop a release, extra release, use after move, store through a shared reference) and caught by the opt-diff test | L1 | **partly done**: `tools/mutate_mir.py` (13 mutation classes, about 20,000 mutants of the optimised MIR of the conformance programs; CI `test` job; leaks are required to *warn*, everything else to be *rejected*, with the expected message). Not done: catching mutants by `diff_backends.py --mode opt` (behavioural detection), mutants in the optimiser itself (C6), mutants with calls/owned parameters/loop back edges beyond what occurs in the corpus |
| P0 | Translation validator for last-use moves / owned parameters (C6) | L2 | independent checker comparing pre- and post-opt MIR; the vertical proof slice of §20a |
| P0 | Call rule, loops, arrays in the Lean model (C3) | L3 | extends `check_sound` |
| P0 | **MIR shape/type check in the verifier**: every `IGetField`/`ISetField`/`ITakeField`/`IPutField`/`ITag` operand has a known struct type whose arity bounds the field index, every array op an array type; function results and call arguments agree with the callee's declared MIR types (finding F-shape; the runtime bounds checks are only a backstop) | L1 then L3 | type-annotated MIR is already available (`locals[].ty`); add to `compiler/verify` and to the Lean model (`ill` excluded in `check_sound`), differential test in `tools/diff_verifier_lean.py` |
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
