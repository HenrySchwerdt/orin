# ADR-0006: Production backend — textual LLVM IR via a backend-neutral MIR

Status: accepted (2026-10-13). Refines ADR-0001.

## Decision
- **Production backend: LLVM**, targeted by emitting **textual LLVM IR (`.ll`)** and invoking
  `clang`/`llc` + the system linker. No C++/C-API bindings are needed, so the self-hosted Orin
  compiler can emit it exactly like it emits C today (string output).
- **C stays** as the bootstrap backend (Stage 0/1) and as a portability/debug fallback.
- Both backends consume one new **MIR** layer (spec 09: "MIR/SSA -> OIM analysis + memory IR
  verifier -> codegen"): explicit control-flow graph, explicit `retain/release/make_unique`,
  explicit traps/checks. The OIM memory verifier (spec 07) checks MIR, so its guarantees
  apply to both backends equally.

## Rationale
- Spec 11 targets Go-to-Rust performance; LLVM gives mature optimisation, many targets
  (x86-64, ARM64; Linux/macOS/Windows — spec 12 #12) and debug info.
- Cranelift is attractive for compile speed but is a Rust library without a stable C API — a
  poor fit for a compiler written in Orin. QBE is small but optimises less and has fewer targets.
- Textual IR keeps the trusted computing base explicit (spec 07: LLVM + linker are TCB).

## Sequencing
Self-hosting (M3) stays on the critical path and is completed with the C backend. Then:
1. Introduce MIR in the self-hosted compiler; port C codegen to consume MIR (no behaviour change,
   Stage 2/3 equality must still hold).
2. Add the MIR → LLVM IR backend; run the conformance suite on both backends (differential).
3. Make LLVM the default for release builds once it passes all tests and benchmarks (spec 11).
A faster non-optimising debug backend (e.g. direct MIR → machine code) MAY be considered later.
