# ADR-0041: Proof-guided error handling, `@NoTrap`, and recoverable boundaries

Status: **proposed** (2026-10-14). Design only; not yet implemented. Acceptance requires review of
runtime isolation and verifier soundness before enabling any strict mode.

Related: [contracts](../contracts.md), [capabilities](../capabilities.md), ADR-0017 (concurrency),
ADR-0021/0027 (capabilities), ADR-0029 (honest diagnostics and refusal), ADR-0030 (trusted runtime),
ADR-0031/0036 (contract verification), ADR-0032 (end-to-end assurance), ADR-0037 (effects).

## Motivation

Orin has `@Requires`, `@Ensures`, `@Invariant`, a path-sensitive contract verifier,
and transitive capability-effect inference. These answer *what a function promises* and
*what effects it may perform*, but not yet the full question:

> Under the function's stated preconditions, can any of its executions reach a
> **modelled runtime trap**?

Nor do they consistently tell developers whether to add a precondition, a guard,
a postcondition, an ordinary error result, or a fault-containment boundary.

The desired programming model is **verified core, recoverable shell**. Developers
write normal Orin with contracts. The compiler reasons through branches and calls,
explains the remaining obligations, and makes safe error boundaries explicit.
Recovery is a **last line of containment**, not a substitute for validating input,
proving call-site preconditions, or dealing with ordinary I/O errors.

## 1. Separate five independent concepts

1. **`@Requires(P)`:** caller obligation. For a correct call, `P` holds at entry.
   A guard such as `if (x <= 0) return Err(...)` can discharge this obligation
   on the continuing branch. The compiler should report a precise missing guard
   or possible caller precondition.
2. **`@Ensures(Q)`:** *partial-correctness* promise. If the function returns normally
   under its preconditions, `Q` holds. It does **not** prove termination or exclude
   traps; an always-trapping function can satisfy an `@Ensures` vacuously.
3. **`@Invariant(I)`:** preservation obligation on supported class, record or loop
   boundaries. Invariant violations are faults, not ordinary business failures.
4. **`@NoTrap` (new, proposed):** a compiler-checked assertion of freedom from
   **all modelled runtime traps**, for every execution starting in a state that
   satisfies the function's preconditions, *regardless of whether it terminates*.
   An unproved assertion is never reported as VERIFIED.
5. **`Result<T, E>` and recovery:** `Result` communicates expected errors, such as
   invalid JSON, DB timeouts, EOF or denied access. An isolated recovery boundary
   contains an unexpected *recoverable fault* and discards the isolated work.
   A `Result` return type does not catch a trap.

These are independent of **capabilities**: a grant confers permission to attempt
I/O, not a guarantee of success, and pure code can still trap. Capability effects
indicate likely architectural boundaries, *not* mandatory recover calls.

## 2. Normative meaning of `@NoTrap`

For a function `f` with precondition `P`:

`@NoTrap f` is VERIFIED only if, for every state satisfying `P`, **no reachable
execution** of `f` triggers any trap in the published Orin trap model.

Initial modelled traps:
- integer overflow and underflow for precise integer widths; invalid conversions;
- division or remainder by zero and the signed division overflow corner case;
- array/string indexing and slice bounds failures;
- `Option`/`Result` invalid `unwrap`/variant extraction;
- violated runtime `@Requires`, `@Ensures`, `@Invariant` and applicable
  explicit checks;
- invalid resource state/access where the language defines a trap;
- any additional compiler/runtime trap source must be enumerated before claiming
  completeness.

**Outside the initial guarantee:** termination, deadlock, starvation, process
kill, system power loss, OS/kernel faults, arbitrary native C corruption, failed
allocation/oom until allocation failure is specified and modelled, and
unmodelled host behavior. Do not report these as proved safe. If memory allocation
can terminate the process independently, report `@NoTrap` as "free of *modelled
language traps*", not "this program cannot crash".

A verified `@NoTrap` may additionally rely on explicit assumptions about trusted
runtime operations; list those assumptions in the report. L0/FFI calls with
unspecified failure behavior produce UNKNOWN, never blanket VERIFIED.

`@NoTrap` is a **proof requirement**, not a runtime catch and not a developer
assertion whose truth is simply trusted. An annotation with a REFUTED or UNKNOWN
proof fails strict verification; IDE/tooling must present why. Proof metadata
must distinguish `VERIFIED`, `REFUTED`, and `UNKNOWN`, including assumptions.

### Crucial current gap

Today (see `docs/contracts.md`, A-INT/A-DIV) normal-return postcondition proofs
assume arithmetic stays in range and division is defined. `bounds` and `unwrap`
already receive dedicated obligations, but overflow and divide-by-zero do not
yet provide the required full trap-safety proof. **These assumptions cannot
silently discharge `@NoTrap`.** Add explicit safety verification conditions (VCs)
for *every* potentially trapping operation, including in expressions used
to establish other facts.

## 3. Composition through the call graph

For each call `g(args)` under path condition `PC`, in caller `f`:

1. Prove `P_f AND PC => P_g(args)` (using the value of variables at the call,
   including mutations, aliases and branches). A condition verified earlier
   cannot be reused after an invalidating mutation.
2. Prove the called implementation is `@NoTrap` within `P_g` or verify its
   body transitively; merely seeing an annotation is not proof.
3. Verify all operations local to `f` and all possible dynamic targets.
   An unresolved interface/callback target is UNKNOWN unless a valid
   universally quantified interface contract/closed implementation set can
   discharge it.
4. Recursive strongly connected components require sound summaries/invariants,
   not circular trust in their own unproved `@NoTrap` claims.
5. `@Ensures` facts may be assumed after a call only when their source and
   applicable proof/contract-check guarantees are stated explicitly; do not
   infer trap-freedom from partial correctness.

Calling `@NoTrap` code **without satisfying its `@Requires` is not safe**.
Do not infer and silently add new public `@Requires` clauses from implementation:
that changes API obligations. Suggest explicit propagation or validation instead.

### Example: guard discharges precondition

The example uses a conservative finite input bound so that `amount * 2` fits
the current `int` representation; all syntax below apart from `@NoTrap`
is illustrative until separately tested against the compiler.

```orin
@Requires(amount > 0 && amount <= 1000)
@Ensures(result == amount * 2)
@NoTrap
function double(amount: int): int {
    return amount * 2;
}

@NoTrap
function handle(amount: int): Result<int, string> {
    if (amount <= 0 || amount > 1000) {
        return Err("invalid amount");
    }
    return Ok(double(amount));
}
```

`handle` needs no `@Requires` for the incoming `amount`: invalid input
takes a normal `Err` path; the surviving path satisfies `double`'s precondition.
The compiler also must prove that the `Err` and `Ok` construction paths and
all helper operations are trap-free. No `recover` is needed here.

Without the guard, `handle` cannot claim `@NoTrap` for arbitrary `amount`,
even if `double` itself has a verified `@NoTrap` under its own precondition.

## 4. Proof-guided recommendations, not one-size-fits-all syntax

When an obligation is open, compiler/LSP/MCP recommendations should be contextual:

| Finding | Preferred response | Why |
|---|---|---|
| An internal call requires a known predicate not established on this path | Add a guard; or explicitly propagate `@Requires` to caller | Prove the call is legal; a generic recover is lower quality |
| Return value should satisfy a business promise | Add/strengthen `@Ensures`, then prove it | Contract expresses successful-result behavior |
| Stateful method can invalidate a representation invariant | Add/strengthen `@Invariant` | Express preservation obligations |
| Local arithmetic/index/unwrap may trap | Guard, safe checked API, or a stronger input bound; request `@NoTrap` proof | Avoid traps rather than catching them |
| Invalid external JSON or business input | Parser/validator returning `Result`, then use guards/refined types | Bad input is not a compiler/runtime failure |
| Capability-mediated network/DB/filesystem call returns `Result` | Handle or propagate `Err`; possibly retry with an explicit policy | Expected operational failure; NOT automatically a trap |
| Unverified fault can escape a long-lived request/job/task | Isolated recovery/supervision boundary if the runtime can safely isolate it | Contain faults without risking shared state |
| Possible memory corruption, unsound unsafe host call or arbitrary L0 failure | Process/sandbox isolation or reject in strict mode | In-process recover cannot promise safety |

In particular **the compiler must never suggest `recover` as a way to prove a
missing `@Requires`** when an ordinary guard can discharge it. Conversely,
it must not recommend `@Ensures` for validation of unknown *incoming* data;
postconditions describe successful outputs.

Suggestions are diagnostics and optional code actions, never implicit source
changes, automatically inserted contracts, or unreviewed new public API rules.

## 5. Trap inference and effect inference

Add a compiler-owned **Trap Analysis** over typed HIR/MIR and the call graph,
reusing the existing contract verifier's path conditions and the effects
analysis's call-graph resolution where appropriate. Do *not* conflate the
two lattices:

- **Effect summary**: `Fs.Read`, `Net.Connect`, `Unknown.Interface`, etc.
  Describes observable operations and required grant, not success/failure.
- **Trap summary**: possible local and transitive *language* trap kinds with
  witness source spans, branch conditions, callee chain, confidence status
  and explicit assumptions. Unknown dynamic calls must remain UNKNOWN.
- **Error-result behavior**: values of type `Result<T, E>` that the caller must
  consciously inspect or propagate according to the API/policy. An `Err`
  value is *not* a trap.

When a check becomes VERIFIED, safely remove *redundant* runtime checking only
if compatible with the build's policy and soundness assumptions. Keep a
`--check-contracts` mode that actually exercises declared contracts. Avoid
silently treating ordinary non-checking builds as though they enforced
unverified `@Requires`/`@Ensures`: today's compiler erases contracts by default.

The analysis should be surfaced in:
- CLI `orin verify` and a distinct `orin safety` view (name provisional);
- LSP diagnostics/hover/code actions;
- MCP inspection and agent-facing structured JSON;
- OSIG provenance and call-path reports, with different categories for
  `MAY_PERFORM` and `MAY_TRAP`.

Example proposed machine-facing record (not yet an implemented schema):

```json
{
  "kind": "precondition",
  "status": "UNKNOWN",
  "site": "server.or:28:10",
  "call": "handle -> double",
  "predicate": "amount > 0",
  "reason": "no dominating guard or caller precondition establishes the predicate",
  "actions": ["guard-and-return-Err", "explicitly-propagate-Requires"]
}
```

A diagnostic must separate `UNKNOWN` (solver limitation, abstraction or
unresolved target) from `REFUTED` (real counterexample); UNKNOWN is never
reported as a discovered crashing input.

## 6. Recovery semantics and safety constraints

`recover` is a **fault-containment boundary**, not a general exception facility.
The final syntax remains open. Prefer an isolated task/request/job supervisor
over unwinding arbitrary stack frames while continuing with possibly mutated
shared state.

A future conceptual API might be:

```orin
// PSEUDOCODE ONLY: no Task.runIsolated / RecoverOutcome API exists yet.
const outcome = Task.runIsolated(() => serveOneRequest(request));
return match (outcome) {
    Ok(response) => response,
    RecoverableTrap(fault) => internalServerError(),
};
```

Binding design constraints:

1. Prove or enforce **isolation**: no mutable shared memory or references to
   broken state leak to the supervisor, including through callback captures.
   Isolation of in-process tasks does *not* protect against runtime/heap
   corruption; those need process isolation.
2. Define the **closed set of recoverable traps** and unwind/cleanup semantics.
   Do not claim all faults (OOM, segfaults, stack corruption, external termination)
   can be recovered in-process.
3. Capabilities transferred into work require scoped lifetime/revocation rules.
   A capability **by itself does not force `recover`**.
4. External effects are not rolled back by a recovered trap. DB writes, network
   sends and money transfers need transactions, idempotency and reconciliation.
5. When catching a postcondition/invariant violation, abandon the affected state;
   never turn it into a successful return from the same broken object.
6. Recovery policy belongs at **explicit architectural boundaries** (server
   request, worker, job supervisor) rather than autogenerated wrappers around
   each potentially failing function.
7. A failed mandatory runtime contract check currently exits with code 101.
   Do not intercept or reinterpret it until the new isolation model is
   implemented and tested across the runtime.

A stricter future application policy may require either verified `@NoTrap` or
a justified safe containment boundary for every escaping modelled trap. It
must NOT demand a recovery boundary just because code receives external input,
holds a grant, or returns `Result`.

## 7. Strict build policy and reporting

Proposed independent controls (flags/names to be finalized):
- **Verify annotations:** an `@NoTrap` that is REFUTED or UNKNOWN is a build
  error in strict mode; standard diagnostics always explain why.
- **Require containment:** at public long-lived entrypoints, every unproved
  potential trap must be removed by proof/guard or accounted for by a *valid*
  isolation boundary. An unknown/unsafe native call cannot be declared safe
  merely by surrounding it with an in-process `recover`.
- **Expected errors:** do not ban `Result.Err` or require a recover for
  network/database I/O; require handling/propagation only under a separate
  explicit error-result policy.
- **Publish assumptions:** a `VERIFIED` label must include the model and
  dependencies, particularly A-INT replacement, L0 and dynamic dispatch
  assumptions, so users do not confuse partial correctness with total safety.

No existing default compilation behavior changes just by accepting this ADR.

## 8. Implementation order and acceptance tests

### Stage A: trap taxonomy and static VCs (no new runtime behavior)
- Inventory all compiler-emitted/runtime traps from the C and LLVM backends,
  including hidden traps in operator lowering and contracts.
- Add explicit overflow, division, bounds, unwrap and contract-well-definedness
  proof obligations. Stop treating A-INT and A-DIV as proof of trap-freedom.
- Prove simple flow examples with and without guards, including mutation
  between guard and call; add real counterexample tests.
- Add stable verifier statuses and JSON diagnostics, with source spans.

### Stage B: `@NoTrap` and compositional call summaries
- Introduce `@NoTrap` in the closed annotation/contract grammar via an ADR-
  reviewed syntax choice (compiler builtin; not arbitrary user decorator).
- Verify it on the full body, including call targets and dynamic/recursive cases.
- Enforce no false VERIFIED for unresolved/unknown callees or unmodelled
  platform primitives. Summaries are shared by CLI, LSP, MCP and OSIG.
- Add positive/negative conformance cases and `UNKNOWN` regression tests.

### Stage C: compiler advice and strict safety gates
- Suggest `@Requires` propagation vs guard/`Result` on unsatisfied call sites,
  `@Ensures` for useful return postconditions, `@Invariant` for state,
  `@NoTrap` for safety claims, and recovery **only at eligible boundaries**.
- Machine-readable diagnostics with explanation/witness/source/quick-fix.
- Per-package policy for entrypoint safety; no hidden inference changing the
  caller-visible API. Benchmark usefulness on the agent ergonomics task set.

### Stage D: isolation, supervision and recovery
- After/concurrent with ADR-0017 and R3/R4, implement isolated fault domains,
  cleanup, resource scopes and supervisor API.
- Specify precise recoverable categories. Add adversarial tests: invariant
  mutation, leaked references, partial DB writes, aborted streaming output,
  cancellation, resource closure and nested request failures.
- Test that unrecoverable faults do not get mislabeled or swallowed and that
  one recoverable request fault does not kill a healthy supervisor.

### Mandatory CI demonstrations
1. A caller with a dominating `if` guard discharges a callee `@Requires`.
2. An unguarded caller cannot be VERIFIED merely because its callee has
   `@NoTrap` under preconditions.
3. `@Ensures` on an always-trapping function does not imply `@NoTrap`.
4. `int` overflow and division-by-zero produce their own obligations; both
   C and LLVM behavior agree under checks.
5. `Result.Err` from I/O is not a trap and does not require recovery.
6. Unknown callback/interface calls remain UNKNOWN.
7. A correctly validated JSON-to-typed-data boundary feeding a proved core
   needs no recovery solely because data originated outside.
8. Recovery cannot continue with invalidated state or claim to undo a write.

## Non-goals

- Blanket `try/catch` for arbitrary exceptions, implicit conversion of
  contract violations into `Result.Err`, and automatic per-operation recover.
- A guarantee that every application always terminates or survives arbitrary
  OS/heap/native faults.
- Declaring capability effects unsafe or recoverable by default.
- Shipping a new runtime primitive before its safety/isolation semantics are
  specified and tested.

## Decision requested

Agree to the **semantic direction** and stage gates above. Keep exact syntax,
public strict-mode switches and fault-domain implementation open until the
required proofs and runtime experiments exist.
