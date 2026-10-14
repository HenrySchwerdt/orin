# ADR-0037: Closed-root capability derivation, generic I/O boundaries and proof roadmap

**Status:** accepted (2026-10-14, project owner). Architecture/design only; no new syntax, builtins or proof claims implemented by this ADR. Accepted with the D5 decisions: user-facing `console.*` moves to `StdioGrant` with a trusted panic/diagnostic path, and `shell` is replaced by `spawn(proc, executable, argv)` with enforced allowlists; both are implemented before the std I/O freeze (follow-up implementation ADR for migration and policy format).

**Related:** [ADR-0021](0021-capabilities-and-io-provenance.md), [ADR-0027](0027-stage-a-root-capabilities.md), [ADR-0023](0023-osig-schema-v0.1.md), [ADR-0020](0020-verifiable-software-roadmap.md), [ADR-0025](0025-resources-and-streaming-fs.md), [ADR-0032](0032-end-to-end-assurance.md), [ADR-0033](0033-l0-network-primitives.md), [assurance](../assurance.md). The language freeze of ADR-0016 requires separate approval for new surface syntax.

## Motivation

Orin aims to make **every external I/O operation authorized, observable and analyzable**, regardless of whether a library exposes a free function, a class method, a registered callback or a framework-defined annotation such as a hypothetical `@KafkaListener`. Libraries must not need compiler-specific Kafka/HTTP/Postgres logic. The compiler and LSP must derive consistent per-function/module/package effect summaries, and OSIG must build explainable lineage down to actual input and output values.

Stage A already enforces built-in Host-derived resource grants for FS/process/stdio/clock and records primitive `PERFORMS_IO` call-site events. Stage B (transitive effects), third-party derived capability types, semantic-boundary registration and field lineage are **not implemented**. This ADR proposes a protocol-agnostic extension, explicitly preserving the Stage A trusted root and runtime grant checks.

## D1 — Closed root authority, open *restricted* derivation

Only the compiler/trusted L0 runtime defines/mints **root authority families and primitive operation kinds**. No application or library can declare, instantiate, fake or cast a new primitive authority/root token. User libraries may define **nominal derived capability types** only if every privilege can be accounted for by existing parent grants. A type declaration itself never manufactures a usable token; a derived **instance** must be constructed through a compiler/runtime-validated, lifetime-safe derivation from live parents.

For effective scopes `A`:

```
A(derived) ⊆ union(A(parent_i))
A(derived, INPUT) ⊆ union(A(parent_i, INPUT))
A(derived, OUTPUT) ⊆ union(A(parent_i, OUTPUT))
A(derived, CONTROL) ⊆ union(A(parent_i, CONTROL))
```

This is an **authority non-amplification** condition, not merely a relationship of named types. The union is additionally restricted by operation family, resource identity, endpoint/path scope, allowed modes, lifetime and host policy. A type cannot rename Stream.Write as Stream.Read or turn a read-only file grant into a write grant. Combining parents cannot silently transfer resources/rights beyond their intersection where an operation requires both constraints. Unknown or dynamic scopes require runtime validation; if they cannot be validated safely, deny.

**Inheritance/traits:** common `Input<T>`/`Output<T>` contracts and interfaces may describe behaviour, but *implementing a trait never grants authority*. Capability provenance is a separate, sealed derivation DAG, not arbitrary class inheritance. A derived capability can have both INPUT and OUTPUT, but the two rights are separable, visible and independently narrowable. No synthetic `SuperAdmin` capability without parents.

## D2 — Three different graphs, one shared compiler semantic engine

1. **Authority DAG**: parent grants, narrowed scopes, nominal derived capability instances, lifetime, trusted minting.
2. **Primitive/effect graph**: compiler-owned operation IDs; physical INPUT (e.g. Stream.Read), OUTPUT (Stream.Write), CONTROL (Connect/Bind/Spawn etc.); transitive may-effects over direct calls, interfaces, closures, callback registration and recursion.
3. **Data-lineage graph**: compiler-generated edges connecting I/O values to local assignments, fields, parameter bindings, returns, decoder outputs and subsequent I/O inputs. Identity evidence is qualified rather than invented.

Per-function effects are inferred, with deterministic summaries aggregated per exported module, package and entrypoint. Effects do not confer permissions: possession/borrowing of the corresponding valid grant at the effect operation remains mandatory. An invoked callback or dynamically dispatched method may produce MAY/UNKNOWN summary edges; the compiler must not silently call it pure. Each edge carries source span, operation, resource/handle ID where known, direction, evidence/uncertainty and explanatory call path.

The compiler, LSP, MCP and OSIG must consume **the same versioned semantic index**, not reimplement capability or effects reasoning independently. Hover and diagnostics expose inferred and declared capabilities, direction, primitive effects, unknown semantic bindings and explanation paths.

## D3 — Required metadata and protocol-independent resource/boundary model

Exported derived capabilities MUST provide a non-empty human-readable **description**, stable nominal ID, parent derivation, intended operations/directions and typed resource-scope descriptors (plus version and documentation link where useful). This metadata is human explanation, not an authorization claim.

A `resource` is a typed, **unprivileged** descriptor with an optional canonical external identity: file path, TCP endpoint, topic, HTTP route, database table, or an application-specific stream. It cannot be cast to a grant, and an identical string does not establish identical external identity. The author of a library defines resource schemas, not new compiler-known resource families.

A semantic `boundary` associates **existing primitive event/value IDs** with a typed payload, concrete decoder/encoder and handler dispatch:

- input: authorized primitive Read event → byte/value data dependency → decode/transform → callback/function parameter;
- output: function argument/field → encode/transform → authorized primitive Write event;
- control: connect/bind/subscribe/spawn lifecycle, *not* automatically a business payload;
- declared resource identity is linked to primitive handle via a verified binding, trusted protocol adapter, explicit assumption or UNKNOWN.

The boundary API is a **compiler-recognized, capability-neutral std interface** with sealed input/output event provenance tokens that library code cannot fabricate. A plain `boundary.input(topic, message)` with free-form strings or synthesized messages MUST NOT create VERIFIED lineage. The compiler checks call paths, payload binding, event provenance and authority; where it cannot prove higher-level protocol/resource identity, label it DECLARED/ASSUMED/UNKNOWN according to ADR-0021. A network reader remains observable as primitive Net Stream.Read INPUT even if its semantic protocol is unknown.

**Illustrative logical flow, not implemented syntax:**

```text
host-issued NetGrant
  -> Stream.Read [primitive INPUT, sealed handle, bytes value id]
  -> library decoder [typed transform]
  -> boundary adapter maps read value to callback arg [CHECKED or UNKNOWN]
  -> onOrder(order: OrderCreated) [application function]
  -> order.customerId -> process() -> output payload.customerId
  -> Stream.Write [primitive OUTPUT, sealed handle]
```

The compiler need not know Kafka. A Kafka library's `@KafkaListener` is optional front-end sugar for registration, which a proposed library-defined annotation/macro mechanism must lower to explicit typed callback/boundary operations while preserving source spans. It is not a privileged permission or authoritative assertion. Generic boundaries work equally for free functions and methods; *not* tied to classes.

## D4 — Compile errors, fallback and strict policies

- Missing, forged, revoked, escaped, wrong-family or widened authority: **compiler rejection when statically detectable**, with mandatory runtime handle validation at L0. Denial at runtime is still necessary for dynamic policy/scope conditions.
- A library-defined root authority or a derived type with no legitimate ancestor: **compile error**, never a silent fallback.
- A primitive I/O event with a valid grant but no evidenced application-level boundary: **normal build succeeds**, recorded as primitive `NetGrant/Stream.Read/INPUT` (or equivalent), semantic identity UNKNOWN.
- A declared boundary contradicted by provable actual data/effect flows: **compile error** for demonstrable inconsistency; an undecidable binding is UNKNOWN, never a false claim of a proven contradiction.
- A policy requiring semantically verified boundaries: **strict policy failure** if boundary/effect/value binding remains UNKNOWN, ASSUMED without explicit approval, or missing; the failure includes a concrete remediation path. `UNKNOWN` must not disappear from the graph.
- Root I/O is observable even without a framework annotation; arbitrary raw syscall/FFI/native code is an unsafe trust boundary and is disallowed, isolated or explicitly trusted in certified policies. A compiler alone cannot prevent native code or the OS from bypassing mediation.
- There is no global guarantee that a library author supplied truthful protocol metadata: it is validated against observable events or clearly labeled as a trust assumption.

Maintain separate **authorization** and **semantic identity** policies; "fully lineage verified" requires declared scope and reportable evidence, not merely that a program compiles.

## D5 — Console and process as normal authority-bearing effects

Move normal user-facing `console.log/error` to a safe Orin std layer using `StdioGrant`, so writes are primitive OUTPUT effects and are policy-controlled. Retain a restricted trusted runtime trap/diagnostic mechanism that is **not available to arbitrary library code**. This changes ADR-0027 D5 (ambient console) only after explicit compatibility approval and test migration. A library without grants should not be able to exfiltrate through ambient console; a strict host/OS deployment policy is still required for native bypasses.

Replace unrestricted `shell(proc, commandString)` with an explicit `spawn(proc, executable, argv, ...)` abstraction with runtime-enforced executable/argument allowlists and a secure process execution policy. A spawned child has OS authority unless sandboxed; a ProcessGrant alone is not an OS sandbox. Process Spawn remains CONTROL; child stdio is separately modeled as INPUT/OUTPUT stream effects. Deprecation/migration and policy format require a follow-up implementation ADR and owner approval before I/O freeze.

## D6 — Formal verification in Lean is a planned **required assurance milestone**

The capability foundation **must be formally modeled in Lean 4**; this is an explicit future delivery requirement, **not a claim that it is proved today**. In consultation with ADR-0020/0032's assurance levels, stage proofs and code-to-model linkage as follows:

**Lean model (theorems and negative examples):**
1. **Unforgeability:** well-typed untrusted code cannot construct valid root/derived handles except through authorized trusted root/derive operations; include preservation under lowering of handle operations in the modeled fragment.
2. **Non-amplification:** `EffectiveAuthority(derive(parents, restriction))` is a subset of parent effective authority, separately for INPUT, OUTPUT and CONTROL, resource scopes and constraints.
3. **No direction laundering:** derived INPUT does not imply OUTPUT; primitive Read and Write event direction is fixed by the trusted primitive and cannot be relabeled by a library.
4. **Lifetime/revocation:** handles cannot escape their sanctioned scope, and revoked handles cannot authorize any primitive effect; composition cannot outlive any required parent.
5. **Authorization soundness:** all reachable privileged operations in the modeled language fragment are authorized by an appropriate live grant, subject to explicitly modeled runtime host policy and restrictions.
6. **Effect inference soundness:** an inferred summary **over-approximates** actual reachable primitive effects, including indirect calls, callbacks, recursion and unknown callees (UNKNOWN is not treated as pure).
7. **Provenance/lineage conservativeness:** any graph edge labeled as *verified* is justified by source-value dependencies and a checked boundary binding; unresolved or opaque external relationships cannot become VERIFIED. Define clearly whether the property is absence of false positives for VERIFIED, or completeness for primitive flows; do not conflate them.
8. **Monotonic restrictions:** further narrowing cannot restore previously denied authority; operation-level runtime policy must respect the same ordering.

**Implementation assurance is distinct from model proofs:**
- Implement an executable specification of the capability checker and effect propagation for a scoped core MIR/IR subset.
- Differentially test Lean/spec semantics versus the actual Orin checker/MIR verifier/runtime on generated positive and adversarial programs; add mutation tests for grants, output laundering, revoked handles, callback effects, resource identities and dynamic unknowns.
- Establish a checked refinement/translation-validation link between the actual compiler's representation and the Lean semantics, including the relevant L0 runtime behavior and platform/OS assumptions. Only *then* elevate the applicable assurance level beyond MODEL_ONLY/TESTED_ONLY.
- CI must build Lean proofs with pinned toolchain, no `sorry`, avoid undeclared axioms, audit admitted assumptions, test adversarial counterexamples and fail closed on broken proof obligations.
- Record separate evidence: Lean theorem identifiers, covered IR subset, model assumptions, implementation correspondence, independent runtime/OS threat boundaries, and semantic binding trust. Do not report `capabilities proved safe` globally if only a small calculus is formalized.
- Native FFI and OS syscall bypass require a trusted boundary or sandbox; a Lean proof of the language calculus does not prove that an arbitrary native process obeys it.

**Proposed Lean proof milestones:** (L1) root/derived rights lattice + direction + lifetime semantics; (L2) statically checked operation/effect soundness with callback summaries; (L3) checked semantic-boundary mapping and data-lineage edge provenance; (L4) implementation correspondence through MIR/L0/platform and OS isolation assumptions. Each milestone includes theorem names, executable counterexamples and a proof-to-code coverage matrix in `docs/assurance.md`.

## Acceptance criteria for future implementation

1. Creating a new root capability in a library is rejected; deriving a read-only grant into a write grant is rejected.
2. A valid derived type without live parent grant instances cannot be instantiated as a usable handle.
3. A function with only an input grant cannot cause a primitive output through an indirect call or callback without an independent authorized output grant.
4. A library with only generic network I/O and no protocol binding shows primitive read/write/control effects, UNKNOWN protocol identity, and no fabricated topic/route lineage.
5. A generic callback-based listener maps verified decoder output to its handler's actual parameter independent of library/protocol or class shape; if the mapping cannot be proven, display MAY/UNKNOWN.
6. Module/package summaries include all reachable primitive effects (sound over-approximation) and explanation call paths; LSP and OSIG share the identical underlying analysis.
7. A forged binding or an adapter that relabels physical OUTPUT as INPUT cannot generate verified semantic lineage.
8. User-facing console respects StdioGrant in the migrated mode; malicious no-grant library cannot print through user std APIs. Trusted panic diagnostics are not exposed as an escape hatch.
9. Process spawn uses explicit argv and enforced policy, and is not misrepresented as sandbox confinement.
10. Lean proofs establish non-amplification, unforgeability/direction invariants and conservative effect analysis on the stated model subset; mutated implementations or unsafe counterexamples fail, and the assurance ledger distinguishes MODEL_ONLY from demonstrated implementation correspondence.

## Rollout and open decisions

Phase A: review and decide the API shape (`capability` declarations vs compiler-recognized std descriptors), root operation lattice and no-new-root rule before extending the frozen language surface. Do not implement illustrative syntax without a separate ADR.

Phase B: complete Stage B transitive effects, source spans and stable per-module/contract summaries first, then introduce sealed semantic provenance tokens and versioned generic boundary declarations.

Phase C: pilot on a minimal generic byte-stream listener with a typed decoder and callback; separately validate Kafka/HTTP adapters without introducing special compiler rules. Integrate LSP hover/explain and OSIG function/field lineage.

Phase D: implement the Lean milestones progressively and add a gated proof/implementation correspondence matrix; do not wait to add compiler/runtime safety tests.

**Project owner decisions still pending (ADR-0027):** grant-only vs borrowed local syntax, new console policy and trusted panic path, safe process spawn, host policy format, path-relative semantics, `exists` result type, env/entropy families, network scoped listeners, runtime grant quotas and async grant transfer. This ADR proposes directions for console/spawn but **does not silently freeze their API**.

## Implementation status

- **Phase B, D2 (transitive effects): implemented** (Stage B of ADR-0021), no new syntax. One engine over the semantic index,
  `compiler/analysis/effects.or`, behind `orin effects <entry|package>`, the OSIG `MAY_PERFORM` edge (`osig/0.2`, ADR-0023
  addendum), the `orin diff` effect sections, the LSP hover and the MCP `inspect` result. Soundness argument, the UNKNOWN
  sources and the purity agreement: [capabilities.md](../capabilities.md). Acceptance criterion 6 (module / package summaries
  with all reachable primitive effects and explanation paths, LSP and OSIG on the identical analysis) holds; criterion 3 (an
  indirect call or callback cannot cause an output without an independent grant) is enforced by the Stage A checker, the
  summary shows the effect.
- **D4, minimal policy hook:** `[effects] allowed` / `[effects.<module>]` in `orin.toml`; E0473 (module exceeds its allowance,
  with the explanation path), E0474 (unknown effect name). The strict policies on semantic boundaries are open.
- Not started: D1 derived capability types, D3 boundaries / lineage, D5 migration of `console.*` and `shell`, D6 Lean model.
  The effect summary treats `console.*` as an ambient OUTPUT effect and `shell` as `Process.Spawn` (CONTROL) already, so the
  D5 migration changes the grant column of `Console.Write` and nothing else.

