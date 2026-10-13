# 07 — Formal Memory Safety Specification

## Precise intended guarantee

For safe, well-typed Orin programs and a correctly implemented trusted backend/runtime/FFI boundary: no use-after-free, double-free, dangling-pointer dereference, out-of-bounds memory access, uninitialized read, invalid type reinterpretation, or race on unsynchronized shared mutable memory. A *formal core safety theorem* and a mechanically checked proof are required goals; a compiling self-hosted compiler by itself is not proof.

Memory leak freedom, guaranteed termination, absence of OOM, freedom from logic bugs and correctness of external unsafe/native code are **NOT** implied by memory safety. Defined traps (e.g. bounds, overflow, failed invariant) are permitted as safe outcomes.

## Formal core calculus

Define a small typed operational semantics with values (scalars, records, tagged unions, arrays), functions, closures, immutable sharing, explicit local-update semantics, and `Result`/`Option`. Classes and annotations desugar into this core. Let state `S = (E, H, R, O)` include environment E, heap H, active regions R, and ownership/accounting O.

Let `WellFormed(S, Γ)` enforce type, pointer-liveness, uniqueness, RC/region, and concurrency invariants. The desired progress theorem is: a well-typed valid state is a value, a specified failure, or can make a step. Preservation is: if `WellFormed(S, Γ)` and `S -> S'`, then `WellFormed(S', Γ')` for an appropriate successor context. Explicit heap safety lemmas must connect typed operational semantics to the absence of bad memory events.

## Required invariants

- Reference accounting reflects all live owning paths and transfers.
- Allocation produces fresh valid locations or safe reuse under uniqueness proof.
- `release` only frees when safe and never creates a reachable dangling pointer.
- Region disposal leaves no valid external borrow into disposed memory.
- Copy-on-write/update does not mutate values observed through aliases.
- Bounds checking, arithmetic traps, handle checks and OOM are memory-safe.
- Generated annotation code has no privileged unchecked memory operations.

## Verifier and trusted computing base

Orin MUST develop an independent **OIM IR verifier** that checks certificates/typing judgments for memory operations. Merely checking IR syntax is insufficient. The verifier itself should be small and ultimately mechanically verified. The native backend, ABI, allocator, concurrency primitives, machine-model assumptions and FFI boundary are still in the trusted computing base unless verified or translation-validated.

A self-hosted compiler that emits unverified machine code cannot truthfully claim end-to-end formally proven memory safety merely because its input IR was checked. Label guarantees by layer: *source core*, *memory IR*, *native artifact*.

## Proof and validation plan

1. Specify executable reference semantics and model the syntax-to-core lowering.
2. Prove type safety (progress + preservation) with heap/ownership invariants.
3. Prove RC accounting, uniqueness-based reuse, and region safety.
4. Model safe graph handles and task isolation.
5. Implement verified/certificate-checking OIM IR verifier.
6. Prove or translation-validate critical lowering and codegen; make remaining assumptions explicit.
7. Supplement proof with property-based, differential, sanitizer and fuzz tests. Tests do not replace proofs.

Use Lean 4 or Rocq for mechanization; choice is OPEN. Separation logic/Iris or equivalent techniques may help with advanced mutable resource abstractions.

## Research context

Relevant precedents: Perceus correctness, RustBelt semantic models of safe abstractions, CompCert verified compilation, region inference. None directly proves this design as a whole. See `13-research-references.md`.
