# ADR-0020: Adopt the verifiable-software vision and fold it into the implementation plan

Status: accepted (2026-10-13). Source: `docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md` (the "vision",
PR #13). This ADR does not restate the vision; it fixes what changes in the plan, in which order,
and which existing parts each vision subsystem builds on. The integrated plan is `docs/roadmap.md`.

## Decisions

**D1 — Proof status vocabulary (binding now).** Every verification result in the compiler, CLI,
JSON, MCP, LSP and docs uses exactly: `VERIFIED` (proved under the listed assumptions), `REFUTED`
(counterexample or real refutation; replaces the earlier name `FAILED` of spec 15/18),
`UNKNOWN` (timeout, unsupported fragment, missing model), `ASSUMED` (stated, not proved: `@Assume`,
external contracts), `NEEDS_DECISION` (a required specification answer is missing),
`NOT_APPLICABLE` (with a reason); plus the evidence states `STALE` and `NOT_RUN` that spec 15 §7
already defines. Statuses are never merged or upgraded; a `VERIFIED` result always
carries its assumption list. Applies to contract verification (ADR-0012 phase 2) from its first
release.

**D2 — OSIG is the existing semantic engine, grown — not a second one.** The Orin Software
Intelligence Graph extends the semantic index (ADR-0008) and the API snapshot (`orin api`, PR #11):
nodes/edges come from the checker, HIR and MIR of the same compile. `orin graph` exports it,
`orin diff --base --head` generalises `orin api --check` from public API to call/type/module/effect
edges. Stable symbol IDs = package + module path + symbolic signature (the API snapshot key today).
Graph schema versioned independently of the compiler.

**D3 — Source mapping is part of the compiler rewrite (ADR-0015).** Every MIR instruction carries
the source span of the HIR node it was lowered from. This is required by OSIG, lineage, contract
counterexamples and diagnostics, and is cheapest to add while the lowering is rewritten, not before.

**D4 — Capabilities must be designed before the 1.0 language freeze.** Default-deny capability
handles change the signatures of `std:fs`, `std:process`, `std:io`, `std:time` and every future
network/DB API. Retro-fitting them after the freeze would break all programs, so the language-level
part (ADR-0021, to be written) joins the 1.0 core scope (ADR-0016 amended):
- a capability is an unforgeable value (no constructor, no literal; resource-like: may be passed and
  narrowed, never forged); the program root receives the grants from the platform;
- effects are **inferred** inside a package (no effect annotations in private code) and **declared
  at package/module boundaries** in `orin.toml`, next to the existing `allowed_dependencies` rules;
- the runtime check sits in the L0 platform layer (spec 19), so it is enforced also for code the
  analysis cannot see through (FFI is a declared trust boundary).
Effect inference across the call graph, the policy checker and `orin effects` come after the freeze.

**D5 — Order of the vision phases relative to the current plan.** Language core → compiler rewrite
→ (optimisation ‖ provability) stays the backbone; the vision adds tracks that run in parallel when
they do not touch the language surface:

| Vision phase | Plan slot | Depends on |
|---|---|---|
| 0 ADRs, schema, TCB inventory | now (this ADR, `docs/tcb.md`, OSIG schema ADR next) | — |
| 1 OSIG MVP, `orin graph`, `orin diff`, static HTML report | parallel to the language core (tooling track) | semantic index, API snapshot |
| 2 Effects + capabilities | language part before freeze (D4); inference/policy after the rewrite | resources (ADR-0016), platform layer |
| 3 Field lineage + information flow | after the rewrite, on MIR with spans | D3, effects |
| 4 Contracts + proof obligations | already running (ADR-0012 phase 1/2); D1 applies | — |
| 5 Typed config + attestation | post-1.0 core; needs a `config` construct ADR | capabilities, std:json |
| 6 Feature review + agent loop | after phases 1–4 have real output; specs 16/17 | OSIG diff, proofs |
| 7 `.orcert` | after phase 6; reuses SLSA/in-toto/Sigstore, no own crypto | reproducible builds (have), OSIG |
| 8 Hardening, runtime R3/R4, HTTP/DB/JSX, reference service | R3/R4 as planned; HTTP/DB/JSX after concurrency | ADR-0017 |

**D6 — Not changed by the vision.** Value semantics, inferred mutation, isolated-task concurrency,
contract clauses as compiler constructs (ADR-0012), the seed bootstrap and the C/LLVM backends.
The vision's `@Sensitive`, `@Secret`, `@Range` etc. are compiler built-ins in the sense of ADR-0016
(not user annotation processors); each gets an ADR when its phase starts.

## Consequences
- ADR-0016 gains a capability row; the 1.0 freeze waits for ADR-0021.
- spec 15 / spec 18 / ADR-0015 use the D1 vocabulary.
- `docs/tcb.md` is the TCB inventory; it is updated whenever a component moves in or out of trust.
- The reference payment/orders service (vision §14) is the end-to-end acceptance target for
  phases 2–7; the acceptance scenarios of vision §17 become test cases as their phase lands.
