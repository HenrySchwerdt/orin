# Roadmap

_Updated: 2026-10-13._ The integrated plan. Product vision and rationale are in
[ORIN_VISION_ARCHITECTURE_ROADMAP.md](ORIN_VISION_ARCHITECTURE_ROADMAP.md); the decisions that
connect the vision to this plan are in [ADR-0020](decisions/0020-verifiable-software-roadmap.md).
Current status per area is in [progress.md](progress.md). Order matters more than dates. Each step
ships with tests and docs and passes the full CI, including the bootstrap.

## Backbone

### 1. Language 1.0 core (ADR-0016), then a two-stage freeze
- **done:**
  - generics, classes, closures, array API
  - floats/`f32`, `Map<K,V>`
  - `orin.toml` packages
  - std path/json/time/graph
  - runtime R2 platform layer
- **done:** interfaces (ADR-0019), contract clauses phase 1 + 2 (ADR-0012), `@Test`/`orin test`, `@Deprecated`, `@Inline` (ADR-0024)
- **next:**
  - fixed-width integers and template-literal interpolation
  - resources and the streaming `std:fs`
  - ~~generic classes (`class Graph<T>`), then `std:graph` on `Graph<T>`/`GraphId<T>`~~ (done, ADR-0026)
  - **all language-freeze prerequisites are done** (integers, interpolation, annotations, resources, generic classes)
- **capabilities (language part):** ADR-0021 Stage A is **done** ([ADR-0027](decisions/0027-stage-a-root-capabilities.md)):
  `main(host: Host)`, grants as resource handles derived by scope functions and narrowed without amplification, the
  std I/O functions take their grant first, enforcement in the runtime / platform layer (`ORIN_DENY`, path scopes),
  `PERFORMS_IO` edges in the OSIG. Open questions for the owner before the std I/O freeze are listed at the end
  of ADR-0027. Stages B-D (effect inference, library adapters, lineage, strict policy) stay with their phases.
- **Freeze, in two stages (ADR-0016 amendment):**
  1. **Language freeze** once the "next" items are in. Syntax and semantics then change only
     through an ADR, and the compiler rewrite (step 2) starts.
  2. **std I/O freeze** after capabilities. Stage A has landed, so the signatures are now the
     proposed final ones (`std:host`, `std:fs`, `std:process`, `std:io`, `std:time` take grants);
     they stay *unstable* until the project owner confirms the freeze (ADR-0027 open questions).

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
- The Stage 0 CI jobs and the Rust crate were retired in the first post-freeze cleanup PR (branch `archive/stage0-final`, docs/bootstrap.md).

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
| B Security | 2 | language part before the std I/O freeze; inference/policy after step 2 | resources, `orin.toml` rules, platform layer |
| B Security | 3 | after step 2 | MIR source spans, effects |
| C Formal | 4 | running | ADR-0012 |
| E Ecosystem | 5 | after the freeze | capabilities, std:json |
| D Product | 6 | when phases 1–4 produce output | specs 16/17 |
| D Product | 7 | after phase 6 | reproducible builds |
| E Ecosystem | 8 | after step 3 | concurrency |
| F Compiler assurance | L0 | done: `docs/assurance.md` | vision §20a, ADR-0020 D7 |
| F Compiler assurance | L1 | **now, parallel to the core** | Lean model, `compiler/verify` |
| F Compiler assurance | L2 | after L1 | opt pass |
| F Compiler assurance | L3–L5 | with the rewrite, R3/R4 and phase 7 | |

What each phase delivers:
- **Phase 1 (done, MVP; tickets 1, 3, 5, 6):**
  - OSIG schema v0.1 ([ADR-0023](decisions/0023-osig-schema-v0.1.md))
  - `orin graph` ([osig.md](osig.md))
  - `orin diff --base --head` (text/JSON/HTML), heuristic renames, reverse impact with explaining path
  - static HTML PR report as a CI artifact (report only); MCP `graph` / `diff`
  - still open from the phase: stable feature IDs and the feature manifest (ticket 4), MIR source mapping
    (ticket 2, with the compiler rewrite); the gate's "affected features" needs ticket 4
- **Phase 2:**
  - ~~capability handles (language part)~~ (done: ADR-0027; primitive `PERFORMS_IO` edges only, no transitive effects yet)
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
- **Track F (compiler assurance, ADR-0020 D7):**
  - L1: Lean checker vs `compiler/verify` differential test, mutation corpus
  - L2: translation validator for moves/owned parameters
  - L3: call rule/loops/arrays in Lean, type and VC soundness
  - L4: runtime refinement (R3/R4)
  - L5: proof-carrying releases
- **Phase 7:** `.orcert` with SLSA/in-toto/Sigstore and an independent checker.
- **Phase 8:**
  - HTTP, Postgres adapter, JSX
  - the payment/orders reference service

## Next concrete steps
1. (done) Interfaces and contract clauses merged.
2. (done) Track A phase 1: OSIG schema ADR, `orin graph`, `orin diff`, HTML report (vision tickets 1, 3,
   5, 6). Next in the track: feature manifest (ticket 4). Ticket 2 (MIR spans) waits for the rewrite.
3. Start the Track F L1 worker (Lean-vs-verifier differential test, mutation corpus).
4. Fixed-width integers + interpolation; then `@Test` + resources; then ADR-0021 capabilities.
5. Release v0.1.0-alpha.2 (closures, floats, maps, interfaces, std modules).
