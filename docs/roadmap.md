# Roadmap

_Updated: 2026-10-13._ The integrated plan. Product vision and rationale are in
[ORIN_VISION_ARCHITECTURE_ROADMAP.md](ORIN_VISION_ARCHITECTURE_ROADMAP.md); the decisions that
connect the vision to this plan are in [ADR-0020](decisions/0020-verifiable-software-roadmap.md).
Current status per area is in [progress.md](progress.md). Order matters more than dates. Each step
ships with tests and docs and passes the full CI, including the bootstrap.

## Backbone

### 1. Language 1.0 core (ADR-0016), then freeze
- **done:**
  - generics, classes, closures, array API
  - floats/`f32`, `Map<K,V>`
  - `orin.toml` packages
  - std path/json/time/graph
  - runtime R2 platform layer
- **integrating:** interfaces (ADR-0019)
- **in progress:** contract clauses phase 1 (parse/check/erase/runtime checks), then phase 2 (SMT for
  pure functions) with the ADR-0020 status vocabulary
- **next:**
  - fixed-width integers and template-literal interpolation
  - `@Test`/`orin test`, `@Deprecated`, `@Inline`
  - resources and the streaming `std:fs`
- **capabilities (language part):** ADR-0021 is to be written. It covers unforgeable handles,
  grants at the program root, boundary declarations in `orin.toml` and enforcement in the platform
  layer. It must land before the freeze because it changes the std I/O signatures.
- **freeze:** after these, the language surface only changes through an ADR.

### 2. Compiler rewrite with the full language (ADR-0015)
- Refresh the seed, then rewrite module by module:
  1. `loader`/`diag`
  2. `check`
  3. `lower`/`opt`/`verify`
  4. backends
  5. tooling
- The rewrite uses classes, interfaces, generics, closures and `Map`. The compiler's own
  invariants are stated as contract clauses and checked in CI with `--check-contracts`.
- **MIR source spans** are added during the lowering rewrite (ADR-0020 D3).
- The Stage 0 CI job is retired when `compiler/` first leaves Orin-B.

### 3. Concurrency (ADR-0017)
Isolated tasks, `scope`/`spawn`/`join`, channels and send = move-or-copy. Runs on the L0 thread
primitives.

### 4. Optimisation ‖ provability (in parallel)
- **Optimisation:** unboxing, RC elision, escape analysis/stack allocation, LLVM tuning. Each step
  is measured (`docs/benchmarks.md`) and checked by the differential tests.
- **Provability:**
  - runtime R3: core dialect, object model in Orin
  - R4: refinement proofs
  - Lean model extended to closures/vtables/floats and to send
  - translation validation for risky passes
  - TCB shrinks (`docs/tcb.md`)

## Verifiable-software tracks (vision phases, ADR-0020 D5)

| Track | Phase | When | Builds on |
|---|---|---|---|
| A Graph | 1 | **now, parallel to the core** | semantic index, `orin api` |
| B Security | 2 | language part before the freeze; inference/policy after step 2 | resources, `orin.toml` rules, platform layer |
| B Security | 3 | after step 2 | MIR source spans, effects |
| C Formal | 4 | running | ADR-0012 |
| E Ecosystem | 5 | after the freeze | capabilities, std:json |
| D Product | 6 | when phases 1–4 produce output | specs 16/17 |
| D Product | 7 | after phase 6 | reproducible builds |
| E Ecosystem | 8 | after step 3 | concurrency |

What each phase delivers:
- **Phase 1:**
  - OSIG schema v0.1 (ADR)
  - `orin graph`
  - `orin diff --base --head`
  - static HTML PR report as a CI artifact
- **Phase 2:**
  - capability handles (language part)
  - effect inference and transitive fixpoint
  - policy checker, `orin effects`
- **Phase 3:**
  - field lineage
  - control-dependence information flow
  - `orin lineage`
- **Phase 4:**
  - VC generation, Z3
  - `old()`, frame conditions
  - `@Assume` → `ASSUMED`
  - requirement IDs
- **Phase 5:**
  - `config` construct (ADR)
  - startup validation and attestation
- **Phase 6:**
  - feature manifests
  - semantic PR report
  - MCP `explain_*`
  - `NEEDS_DECISION`
- **Phase 7:** `.orcert` with SLSA/in-toto/Sigstore and an independent checker.
- **Phase 8:**
  - HTTP, Postgres adapter, JSX
  - the payment/orders reference service

## Next concrete steps
1. Merge interfaces and contract clauses phase 1.
2. Start the Track A worker: OSIG schema ADR, `orin graph` and `orin diff` (vision tickets 1, 3,
   5). Ticket 2 (MIR spans) waits for the rewrite.
3. Fixed-width integers + interpolation; then `@Test` + resources; then ADR-0021 capabilities.
4. Release v0.1.0-alpha.2 (closures, floats, maps, interfaces, std modules).
