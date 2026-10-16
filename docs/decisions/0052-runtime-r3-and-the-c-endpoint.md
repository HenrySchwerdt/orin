# ADR-0052: Runtime R3 plan and how much C remains

Status: proposed (2026-10-16). Refines ADR-0013 and spec 19 §4 (R3/R4); no code change in this ADR.

## Question

ADR-0013 already decided that the runtime is predominantly Orin over a small, separately verified C
platform layer. R1 (std logic in Orin) and R2 (L0 carve-out) are done; R3 (object model in Orin) has
not started. The open question is how far R3 goes: does any hand-written C have to remain at all?

## Current state (main 46cae57)

| Part | Location | Size | Layer |
|---|---|---|---|
| Object model: alloc + small-block cache, RC, make_unique, destroy, structs/variants | `runtime/core/orin_runtime.{c,h}` | ~3,200 lines C (c + h) together with the rows below | L1 |
| Strings, number formatting/parsing, arrays (slice/concat/join/extend) | same | | L1 / L2 |
| Capability, fs, file, net, process shells (Orin values <-> `(ptr, len)`) | same + `orin_runtime_io.h` | | L1 |
| Task value transfer, per-task heap (`orin_rt_*`, ADR-0017) | same | ~340 code lines | L1 (temporary C) |
| LLVM out-of-line shims | `runtime/core/orin_runtime_llvm.c` | 46 lines | glue |
| OS access: memory, I/O, fs, clock, process, net, threads/monitors, policy | `runtime/platform/orin_platform.{c,h}` | ~1,000 code lines, contracts, CBMC harnesses | L0 |

## Decision

1. **Everything in `runtime/core/` moves to Orin (R3).** That includes the allocator and small-block
   cache, RC, `make_unique`, destroy, strings, arrays, the I/O shells, and the `orin_rt_*` task
   interface. The C object model is deleted at the end of R3, as ADR-0013 requires.
2. **`runtime/platform/` (L0) stays C for now.** Reasons:
   - The stable OS interface is libc (macOS has no stable syscall ABI; pthreads, `getaddrinfo`,
     `posix_spawn` are libc). Orin code would call the same symbols, so rewriting L0 in Orin removes
     no dependency.
   - L0 is the part we verify with CBMC (ADR-0030). An Orin L0 would lose those proofs until Orin's
     own verifier covers the core dialect.
   - It is small (≤ 1,000 code lines, hard budget) and has no data structures, so it is the
     cheapest trusted base we can have.
   Revisit after R3 (see "Zero C" below).
3. **Generated C is not hand-written C.** The C backend stays as the bootstrap path (`seed/`) and as
   the explicit fallback next to LLVM (`--release` uses LLVM since #129). It compiles the Orin L1
   runtime like any other module.
4. **The program entry point stays libc `main`** in L0 (`orin_platform_init`); no custom `_start`.
   A freestanding target (WASI, embedded) gets its own L0 file, not a different L1.

## Core dialect (prerequisite)

R3 needs the core dialect from ADR-0013, legal only in modules marked `core = true` in the manifest:

- raw address type and `load<T>` / `store<T>` at byte offsets, `sizeOf<T>`, object-header access;
- calls to L0 functions by declaration (`extern` to `orin_platform_*`), no other foreign calls;
- thread-local globals (per-task heap state, `orin_stats`);
- checked-arithmetic and branch-hint intrinsics map to what both backends already emit inline.

Safe code and annotation expansion can never reach these constructs (negative tests required).

## Order

Each step is a small PR, keeps stage2 == stage3 for both backends, and is benchmarked (`bench/`,
no regression without an ADR, ADR-0013).

- **R3a** core dialect in the compiler (`compiler/` only; coordinate with ADR-0049 steps in `check/`).
- **R3b** string, number and array functions without allocation policy (index/split/trim/join/format/parse).
- **R3c** capability, fs, file, net and process shells over L0.
- **R3d** allocator, small-block cache, RC, `make_unique`, destroy, struct/variant construction.
  Starts only after the ADR-0038 perf work in `runtime/core/` (packed arrays, in-place reuse) is merged,
  because it rewrites the same code. Hot paths must stay inlinable: the LLVM backend already emits
  retain/release and field access as IR; the C backend emits L1 hot functions `static inline`.
- **R3e** task transfer and per-task heap (`orin_rt_*`, porting table in ADR-0017 Addendum A).
- **R3f** delete the C object model and `orin_runtime_llvm.c`; `tools/check_platform_boundary.sh`
  then asserts that `runtime/core/` contains no C.

R4 (L1 refinement proofs against the Lean machine) follows per ADR-0013.

## Zero C

After R3 the only hand-written C is L0. Removing it too means writing L0 in core-dialect Orin with
`extern` calls straight into libc. That is possible, but it trades CBMC-verified C for unverified
Orin and still links libc. It becomes worth doing only when Orin's verifier covers the core dialect
(so L0 keeps a proof) or when a target without libc (WASI, bare metal) needs a non-C L0 anyway.

## Consequences

- The trusted C shrinks from ~4,200 lines to the ~1,000-line verified L0.
- The object model becomes readable and verifiable in Orin, which R4 needs.
- Risk: performance of the hot RC/alloc path; mitigated by the benchmark gate and by doing R3d last.
