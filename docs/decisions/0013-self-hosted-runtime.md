# ADR-0013: Predominantly self-hosted runtime over a minimal, separately verifiable platform layer

Status: accepted (2026-10-13). Spec: `spec/19-runtime-and-platform-layer.md`.

- Three layers: **L0 platform** (C, closed API list, hard size budget, per-function contracts,
  separately verified), **L1 core runtime** (Orin with core-only intrinsics: object model, RC,
  arrays, strings), **L2 std** (safe Orin).
- Goal: shrink the trusted computing base from "the whole C runtime" to L0 + toolchain, and
  extend the formal proofs (Lean memory model, MIR verifier) into the runtime via refinement
  proofs for L1.
- Migration R1 (std logic to Orin, no new features) → R2 (carve out L0) → R3 (core dialect,
  object model in Orin) → R4 (L0 verification, L1 refinement proofs). Each step keeps the
  bootstrap green and is benchmarked (no performance regression accepted without an ADR).
- Consequence: the language gains a restricted "core dialect" (raw addresses, load/store) that is
  only legal in manifest-marked `core` modules; safe code and annotation expansion can never
  reach it.
