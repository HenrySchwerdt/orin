# Roadmap

_Updated: 2026-10-13._ The integrated plan. Product vision and rationale are in
[ORIN_VISION_ARCHITECTURE_ROADMAP.md](ORIN_VISION_ARCHITECTURE_ROADMAP.md); the decisions that
connect the vision to this plan are in [ADR-0020](decisions/0020-verifiable-software-roadmap.md).
Current status per area is in [progress.md](progress.md). Order matters more than dates. Each step
ships with tests and docs and passes the full CI, including the bootstrap.

## Backbone

**Order** (project owner, 2026-10-13). The numbered sections below give the details.

1. Language 1.0 core and freeze (done).
2. Compiler rewrite under the contract and class standard, then diagnostics and CLI polish (2a).
   The refusal protocol (ADR-0029) is part of 2a.
   **Stronger invariants (ADR-0031):** directly after rewrite 2a. This step covers:
   - violation reports with values and blame; **done** (ADR-0031 A1-A2);
   - enforced record invariants and pure functions in contracts; **done** (A3-A5: purity is inferred, contract-internal
     calls are unchecked; docs/contracts.md);
   - static per-method proofs of class invariants;
   - business-logic patterns: quantifiers, `sum`, conservation laws, executable specs, state
     machines, `std:decimal` and `@Property`.

   ADR-0031 part A (items 1-5) is done; parts B-E remain.
   The acceptance test is `examples/ledger/`.
3. **Provable std** on a minimal trusted runtime (ADR-0030), together with capabilities Stage A/B:
   - bytes and UTF-8, collections, I/O
   - `std:net`, `std:http`
   - `std:mcp`, JSX/`std:html`
4. **Complete the Lean proofs:**
   - shape check in the verifier and the model (finding F-shape);
   - the model covers closures, vtables, floats and resource handles;
   - a binding between the real verifier and the Lean checker, so the result is no longer
     `MODEL_ONLY`;
   - all L0 functions contract-verified;
   - R3 object model in Orin, then R4 refinement proofs against the Lean machine.

   **End-to-end assurance (ADR-0032)** extends this step:
   - a Lean semantics of the source language with type soundness;
   - per-compile translation validation of lowering, optimisation and emission, built with the
     lowering rewrite and R3;
   - SMT proof certificates checked by the Lean kernel, and a proof that VC generation is sound;
   - `@Decreases` (termination) and a "no runtime errors" mode;
   - for people:
     - a traceable normative language reference;
     - a per-program assurance report;
     - decision tables as a specification form, checked for completeness and overlap;
     - a TCB size budget enforced in CI;
   - closing the chain to the binary: a CompCert-compatible C path, diverse double compiling
     against the archived Stage 0, and signed `.orcert` attestations.
5. **Concurrency** (ADR-0017), placed after R3/R4 and before the performance push:
   - *after R3*, because task heaps and the L0 thread primitives belong to the Orin core runtime.
     Built before R3, threads would be built twice, once in C and again in Orin;
   - isolated tasks with send = move-or-copy keep reference counting non-atomic. The proofs then
     extend by "disjoint heaps, send transfers ownership" instead of a new memory model;
   - *before performance*, because allocation, RC elision and escape analysis depend on the
     threading model, and the comparison with Go needs parallelism;
   - the HTTP server becomes concurrent here.
6. **Performance push:**
   - unboxing, RC elision, escape analysis and region/stack allocation;
   - LLVM tuning and a parallel compiler;
   - **contract-driven optimisation** (ADR-0031 §E). Only `VERIFIED` facts remove checks or change
     representations, for example:
     - bounds and overflow checks;
     - narrower integer storage;
     - inline storage for size-bounded arrays;
     - tag-free `Option` fields;
     - exact-size allocation.

     Check hoisting from runtime-checked `@Requires` comes earlier.
   - every optimisation is translation-validated or proved; the goal is at least on par with Go,
     measured.
7. Flagship: TypeScript tooling in Orin (3a). **Deferred** (project owner, 2026-10-13): starts only after the owner has set up a separate GitHub organisation for Orin, so the extra repositories do not land in the personal account.

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
- **capabilities (language part):** ADR-0021 is to be written. It covers unforgeable handles,
  grants at the program root, boundary declarations in `orin.toml` and enforcement in the platform
  layer. It changes the std I/O signatures, so the std I/O freeze waits for it.
- **Freeze, in two stages (ADR-0016 amendment):**
  1. **Language freeze** once the "next" items are in. Syntax and semantics then change only
     through an ADR, and the compiler rewrite (step 2) starts.
  2. **std I/O freeze** after capabilities. Until then `std:fs`, `std:process`, `std:io` and
     `std:time` are *unstable*.

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
- **Contract and class standard** (project owner, 2026-10-13): every class carries meaningful
  `@Invariant`s, stateful logic is a class (class invariants are runtime-checked, and since ADR-0031 A3
  record invariants too), every non-trivial function states real `@Requires`/`@Ensures`. Step 1 (loader/diag) is
  brought up to this standard in step 1b. Details: `docs/rewrite.md`.
- **Contract gate for the compiler (planned, not implemented):** CI fails when the compiler's own
  contracts are weak or regress: strict contract coverage on (`[contracts] strict = true`, ADR-0028;
  today `compiler/` has 0 non-strict and 2 strict findings, both in `compiler/loader`), a minimum mutation kill rate
  (`tools/contract_mutation.py --min-kill-rate`) per module, and no regression of `VERIFIED`
  contracts (`orin verify --contracts` results may not turn `UNKNOWN`/`REFUTED`). **Capability gate
  (planned):** only `loader/sources` and the output module may have `PERFORMS_IO` edges (ADR-0021 effect
  analysis, checked by `orin diff` / `orin effects`).

### 2a. Diagnostics and CLI polish (directly after the rewrite)
Goal (project owner, 2026-10-13): hints and CLI tooling that are a pleasure to use, built on
the rewritten, contract-checked front end.
- **Diagnostics:** "did you mean" for names, fields, methods, imports and TS habits
  (`docs/ts-diagnostics.md`: `null`/`undefined`, `any`, `===`, `var`, `throw`, `extends`, union
  types such as `type Id = int | string`, which is accepted silently today); secondary labels
  ("declared here", "moved here"); concrete fix suggestions as machine-applicable edits (LSP code
  actions, MCP, `orin fix`); one stable code and an `orin explain <code>` page per diagnostic
  (`docs/diagnostics.md`); a golden test per diagnostic.
- **CLI:** consistent subcommands and flags with `--help` and examples for each; colour and
  terminal-width-aware output (off for non-TTY, `NO_COLOR`); `--format=json` for every command;
  short timing summary; `orin new` (package scaffold), `orin fix`, `orin explain`; watch mode
  for `check`/`test`; clear exit codes (documented).
- **Contract-quality warnings (landed in part, ADR-0028):** syntactic warnings W0450-W0452 in every
  `check`/`compile`/LSP run, solver-based W0460-W0462 in `orin verify --contracts`, opt-in strict
  coverage W0470/W0471 (`--strict-contracts`, `[contracts] strict`), and the mutation tool
  `tools/contract_mutation.py`. Missing: `orin explain` pages and golden `fix` edits for them, strict
  mode for loop invariants, and warnings from the MCP `check` tool.
- Measured: a TS-developer task corpus (common mistakes from `docs/ts-developers.md`) where each
  mistake must produce a diagnostic with a correct, applicable suggestion.
- **Refusal protocol for agents (ADR-0029, accepted):** every error and verification result says
  who acts next — `FIX_CODE`, `STRENGTHEN_SPEC`, `NEEDS_DECISION` (with a pre-formulated question
  and options for the human) or `NEEDS_AUTHORITY` (grant, dependency rule, assumption or weaker
  contract: never applied by an agent itself). `orin diff` flags weakened contracts and widened
  authority. Measured with a corpus of tasks where the correct agent behaviour is to ask.

### 3. Concurrency (ADR-0017)
Isolated tasks, `scope`/`spawn`/`join`, channels and send = move-or-copy. Runs on the L0 thread
primitives.

### 3a. Flagship: TypeScript tooling in Orin (deferred until a GitHub organisation exists)
Goal (project owner, 2026-10-13): show that Orin is the natural language for TypeScript tooling —
TS-familiar syntax for the community, native speed **at least on par with Go**, measured, not claimed.
1. **Benchmark target first:** Orin formatter/parser on a large TS-like corpus vs a Go parser
   (e.g. esbuild's); tracked in `docs/benchmarks.md`. Today Orin is about 1.5-1.6x slower than Go on
   `nbody`/`mapfreq`; the levers are unboxing, RC elision, escape analysis (step 4) and threads (step 3).
2. **Port the TypeScript compiler** (Apache-2.0, port with notice), staged: scanner + parser →
   binder → checker. Not a 1:1 translation: the TS compiler relies on shared mutable graphs (parent
   pointers, symbol back-links, caches); in Orin these become **arenas with index ids** (as in
   swc/oxc) and `Graph<T>`. Parallel checking needs read-only sharing between tasks: `Shared<T>`
   (post-1.0 option in ADR-0017) must be designed first (ADR).
3. Expected findings: missing library pieces (arena collection, string interning, fast file walking)
   and language friction — fed back into post-1.0 ADRs.
Also: [Orin for TypeScript developers](ts-developers.md) (done): the semantic differences behind the
familiar syntax; every example is a test (`tests/next/**/ts_dev_*.or`), so update the page with any
language-surface ADR. Next: "did you mean" diagnostics for common TS habits — candidate list in
[ts-diagnostics.md](ts-diagnostics.md).

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

## Distribution and developer tools

| Item | Status |
|---|---|
| Release matrix: linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64; per-target bootstrap, smoke test, `.sha256`, combined `SHA256SUMS`; dry-run dispatch | done (`.github/workflows/release.yml`) |
| `install.sh` (checksum-verified, `~/.orin`, uninstall), tested in CI against the packages (`tools/test_install.sh`) | done ([install.md](install.md)) |
| `orin doctor` and `orin --version` in the wrapper | done (no compiler change) |
| Homebrew tap | planned (dropped from the first distribution round) |
| Native Windows (clang, PowerShell wrapper, zip, Scoop, winget, `install.ps1`) | planned, starts after capabilities Stage A ([windows.md](windows.md)) |
| Notarised/signed macOS and Windows binaries; `.deb`/`.rpm`; musl (static Linux) builds | not planned yet |

## Next concrete steps
1. (done) Interfaces and contract clauses merged.
2. (done) Track A phase 1: OSIG schema ADR, `orin graph`, `orin diff`, HTML report (vision tickets 1, 3,
   5, 6). Next in the track: feature manifest (ticket 4). Ticket 2 (MIR spans) waits for the rewrite.
3. Start the Track F L1 worker (Lean-vs-verifier differential test, mutation corpus).
4. Fixed-width integers + interpolation; then `@Test` + resources; then ADR-0021 capabilities.
5. Release v0.1.0-alpha.2 (closures, floats, maps, interfaces, std modules).
