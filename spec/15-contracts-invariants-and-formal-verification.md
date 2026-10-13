# Orin Specification 15 — Business Contracts, Invariants & Formal Verification

**Status:** Proposed language/compiler feature (RFC; not yet implemented)  
**Version:** 0.1  
**Relates to:** `02-types-and-errors.md`, `03-values-classes-interfaces.md`, `05-annotations-and-metaprogramming.md`, `06-memory-model-oim.md`, `07-formal-safety.md`, `09-compiler-self-hosting.md`, `10-mcp-and-agent-tooling.md`, `14-business-logic-testing.md`.

## 1. Purpose and non-goals

Orin SHOULD make business rules **explicit, traceable, testable, and optionally formally provable**, while preserving familiar TypeScript-like source code and the simplicity of its core compiler.

This feature is called **Orin Contracts**. Verification is an optional compiler feature (`orin verify`), not an unconditional cost imposed on every build. Syntax and semantics are specified below as a **proposal**; they must not be reported as already supported by the compiler.

Separate four claims:

1. **Memory safety:** a language/runtime property established by the Orin Core/OIM safety project. It does not imply correctness of business logic.
2. **Business requirements:** externally reviewed requirements or contracts saying what software *ought* to do. A compiler cannot establish whether an incorrectly written requirement matches business intent.
3. **Testing:** execution of finitely many cases; supports confidence, not universal proof.
4. **Deductive verification:** proofs that an implementation satisfies a *specific formal contract* under explicitly declared assumptions, models and environmental conditions.

No test coverage percentage, AI-generated test suite, or solver result may be called a proof of all business behavior. Proof of partial correctness is not proof of termination, availability, external-system correctness, security, or economic/business intent.

## 2. Layered design

The compiler MUST keep the basic execution language separate from the optional verification subsystem:

```text
Human-approved business rule (stable ID, prose, cases, formal properties)
                   |
                   v
Orin source: types + @Rule metadata + contracts + tests
                   |
             Type-checked HIR
                   |
      +------------+------------------+
      |                               |
Runtime compilation               Verification IR
OIM -> MIR -> native code          pure expressions + state/VCs
      |                               |
Executable                       SMT / proof backend
      |                               |
Tests / property tests       VERIFIED / FAILED / UNKNOWN
      +----------------+--------------+
                       |
          Review evidence & MCP summary
```

The optional verifier MUST use the same resolved symbols, types, module boundaries and integer semantics as the compiler. It MUST NOT silently alter the meaning of source expressions. Verification specifications are erased from release binaries unless runtime checking is explicitly enabled.

## 3. Requirements are independent artifacts

Each business rule SHOULD have a stable ID (e.g. `SHOP-001`), a human-readable statement, a revision, a named reviewer/owner role, and a traceability record. The specification is maintained separately from the implementation, for example:

```text
src/shop/discount.or
spec/contracts/SHOP-001.contract.md
src/shop/discount.test.or
```

The business specification MAY be Markdown with machine-readable frontmatter or a separate structured manifest. The **semantics** of formal assertions MUST reside in a constrained, type-checked Orin contract language; unrestricted natural language is not machine provable.

Sample Markdown artifact:

```yaml
---
id: SHOP-001
revision: 3
subject: shop.discount
owner_role: product-owner
review_status: approved
cases:
  - PREMIUM_BELOW
  - PREMIUM_AT_THRESHOLD
  - PREMIUM_ABOVE
  - REGULAR_CUSTOMER
properties:
  - NON_NEGATIVE
  - ZERO_FOR_REGULAR
  - CAP_AT_TEN_PERCENT
---
```

Approval is not proof: the reviewer must verify the specification reflects the intended business policy. Implementation and verification agents SHOULD be separate when feasible; generated examples/expectations MUST NOT be treated as independently approved business truth.

## 4. Proposed source-level feature set

### 4.1 Contracts use `requires`, `ensures`, `invariant`

Orin SHOULD support optional compiler-recognized contract clauses with TypeScript-style syntax:

```typescript
@Rule("SHOP-001")
export function discount(cents: int, premium: bool): int
  requires cents >= 0
  ensures result >= 0
  ensures result <= cents
  ensures !premium ==> result == 0
{
  if (premium && cents >= 10000) {
    return cents / 10;
  }
  return 0;
}
```

- `requires` is a precondition on valid calls.
- `ensures` is a postcondition over the returned result and original parameter values.
- `result` is a **reserved contract-only identifier** referring to the return value.
- `==>` is **only a specification operator**, not a general runtime expression operator. It means logical implication.
- Conditions MUST be pure, side-effect-free, terminating, and type-checked. They MUST NOT perform I/O, call impure functions, or mutate state.
- The code above uses the usual fixed-width `int` semantics (signed 64-bit); the verification backend must model overflow precisely, or discharge a sound range proof before using mathematical integers.
- Calls to verified functions can use established contracts rather than expanding their implementations, enabling modular verification.

In ordinary builds, contracts are static metadata. In `--contracts=runtime` mode, applicable entry/exit assertions MAY be inserted (with explicit runtime overhead). A normal `orin build` MUST NOT pretend it has discharged a formal proof.

### 4.2 Type invariants

A record/class MAY declare a state invariant:

```typescript
@Rule("WALLET-001")
export class Wallet {
  private balance: int;

  invariant this.balance >= 0;

  constructor(balance: int)
    requires balance >= 0
  {
    this.balance = balance;
  }

  debit(amount: int): Result<void, WalletError>
    requires amount >= 0
    ensures match (result) {
      Ok(_) => this.balance >= 0,
      Err(_) => this.balance == old(this.balance)
    }
  {
    if (amount > this.balance) return Err(WalletError.Insufficient);
    this.balance -= amount;
    return Ok();
  }
}
```

This is a **design sketch**, not final parsing syntax: mutable `this`, contracts on `Result`, `old(...)`, and constructor initialization require an explicit formal operational model before acceptance. For verification v1, prefer pure functions over immutable records; mutable state and constructors are a subsequent milestone.

An invariant MUST be established by construction and preserved by every accessible state transition. A constructor is not allowed to expose an object before invariants hold. Private fields cannot be mutated by uncontrolled outside aliases. OIM value semantics help, but **do not replace** proof of the state invariant.

### 4.2a Canonical surface syntax: contract clauses (decision 2026-10-13, ADR-0012)

The keyword clauses in §4.1–§4.3 are superseded as surface syntax by **contract clauses written
with an `@` prefix**. They *look like* annotations but are **not annotations**: they are
dedicated core-language constructs with their own grammar productions, AST nodes, scoping and
semantics (see "Contract clauses are not annotations" below). Semantics are unchanged. One
canonical form:

```typescript
@Invariant(this.balance >= 0)
class BankAccount {
  balance: int;

  @Requires(initialBalance >= 0)
  constructor(initialBalance: int) {
    this.balance = initialBalance;
  }

  @Requires(amount > 0 && amount <= this.balance)
  @Ensures(this.balance == old(this.balance) - amount)
  mut withdraw(amount: int): void {
    this.balance -= amount;
  }
}

@Requires(cents >= 0)
@Ensures(result >= 0 && result <= cents)
function discount(cents: int, premium: bool): int { ... }
```

| Clause | Target | Meaning |
|---|---|---|
| `@Requires(e)` | function, method, constructor | precondition; may mention parameters and (methods) `this` |
| `@Ensures(e)` | function, method | postcondition; may mention `result`, parameters, `this`, `old(e)` |
| `@Invariant(e)` | class/record; loop (statement annotation before `while`/`for`) | state / loop invariant |
| `@Decreases(e)` | loop, recursive function | termination measure |
| `@Rule("SHOP-001")` | any declaration | traceability to a business rule (spec 14) |

**Contract clauses are not annotations.**
- They are a **closed, compiler-defined set** of keywords spelled `@Requires`, `@Ensures`,
  `@Invariant`, `@Decreases`, `@Rule`. These names are reserved: they cannot be declared,
  imported, re-exported, shadowed, aliased or redefined by annotation libraries (spec 05).
- The parser has **dedicated productions** for them and produces dedicated AST nodes
  (`ContractClause`), never generic annotation-use nodes. Their arguments are contract
  expressions in a special scope (`result`, `old(...)`, `==>`), not ordinary annotation
  arguments.
- They are **not processed by the annotation mechanism**: annotation expansion (spec 05) can
  neither generate, remove, rewrite nor reorder contract clauses, and generated code is subject to
  the contracts of the declarations it belongs to like handwritten code. Annotation processors MAY
  read clauses through a read-only API for documentation/tooling.
- They have **fixed semantics defined by this specification** (preconditions, postconditions,
  invariants, termination measures, traceability) and are consumed by the checker, the
  verification pass and optional runtime checking — not by user code or reflection.
- Placement is part of the grammar: clauses precede the declaration they constrain (function,
  method, constructor, class/record, loop) and may be freely mixed with real annotations, but
  their meaning never depends on surrounding annotations.

- Contract expressions are **pure Orin expressions** (no calls to non-pure functions, no
  mutation, no allocation-observable effects); `old(e)` only in `@Ensures`; `==>` implication is
  available only inside contract expressions. Quantifiers (`forall`/`exists`) are OPEN.
- Mutating methods are marked with `mut` (spec 03, ADR-0009 amendment); `old(this.f)` refers to
  the receiver value before the call — under value semantics this is simply the input snapshot.
- **Compiler integration:** every build parses, resolves and *type-checks* contract expressions
  (so they never rot), and erases them from release code. The proof itself is a compiler pass
  (`check → contract IR → VC generation → SMT/proof backend`) run by `orin verify`, by
  `orin build --verify`, or automatically for modules whose `orin.toml` policy requires it
  (`[verification] required = ["payments"]`). A required-but-failed or `UNKNOWN` proof fails
  that build. Runtime checking of contracts MAY be enabled per build (`--check-contracts`),
  turning violations into defined traps.
- Results are reported per contract as VERIFIED / FAILED (with counterexample) / UNKNOWN (§5),
  exposed via `orin verify --format=json`, MCP `inspect`, and LSP (spec 18 §4).

### 4.3 Loop invariants and termination

For imperative verification, the compiler SHOULD support:

```typescript
function sumPositive(values: int[]): int
  requires values.every(x => x >= 0)
  ensures result >= 0
{
  let sum = 0;
  let i = 0;
  while (i < values.length)
    invariant i >= 0 && i <= values.length
    invariant sum >= 0
    decreases values.length - i
  {
    sum += values[i];
    i += 1;
  }
  return sum;
}
```

`decreases` is a proposed termination metric. The example also needs overflow safety: either a precondition bounds the total, or the implementation uses a checked operation/appropriate wide representation. A verifier must reject or report UNKNOWN for an unproved overflow obligation. Partial correctness of the loop alone is insufficient to show termination.

### 4.4 Contracts for `Result` and `Option`

Verification MUST distinguish `Ok`, `Err`, `Some`, and `None`, including short-circuit `?` propagation. A postcondition over a `Result` MUST explicitly specify the success and error branches when relevant. There is no `null` and no unchecked exception path.

Public functions with external side effects (database, network, time, randomness) are verified using **abstract effect interfaces/contracts**, not by assuming an external service behaves correctly. Their assumptions and trusted boundaries MUST be shown in the review report.

## 5. Formal verification algorithm (optional feature)

The proposed pipeline:

1. Resolve business-rule IDs and type-check contracts.
2. Lower ordinary code into Typed HIR and a verification-friendly control-flow graph. Do not make annotation macros privileged: verify their expanded code normally.
3. Extract pure specification expressions, preconditions, postconditions, loop invariants, frame conditions and relevant OIM state transitions.
4. Generate **verification conditions (VCs)** by weakest-precondition reasoning or a sound equivalent (e.g. SSA symbolic execution). For a function body `B`, precondition `P`, postcondition `Q`, verify `P => WP(B,Q)`.
5. Use an SMT solver for supported fragments: propositional logic, finite algebraic datatypes, constrained arrays, bit-vectors, selected linear arithmetic, and quantifiers only with clear resource limits.
6. On SAT/counterexample, show concrete failing input/path when possible. On timeout/unsupported/nonconvergent proof, report **UNKNOWN**, never VERIFIED.
7. Bind successful verification evidence to hashes of the source, contracts, dependencies, semantic model, compiler/verifier version, and solver configuration. Any relevant change invalidates the proof status.
8. Optionally use proof certificates checked by a small independent trusted checker. **A raw `unsat` response from an SMT solver is not itself an independently machine-checked proof certificate.**

For a loop, the verifier MUST prove initialization, preservation, and sufficiency of each invariant; termination requires a separate well-founded decreasing metric. Modular calls MUST ensure the caller proves the callee's preconditions and may use only the callee's established postconditions.

SMT automation is deliberately incomplete: unrestricted programs, nonlinear arithmetic, higher-order properties, or arbitrary loops can be undecidable/intractable. The compiler MUST NOT infer business intent or claim completeness.

## 6. Test strategies and evidence fusion

These are separate complementary channels:

| Evidence | Guarantee | Example |
|---|---|---|
| Example-based business cases | Tested specified examples | Boundary at exactly 10000 cents |
| Property-based testing | Sampled inputs satisfy predicate | Discount never negative in sampled cases |
| Mutation testing | Tests detect chosen implementation mutations | `>=` changed to `>` |
| Branch/MC/DC coverage | Specified structural paths/conditions executed | Premium and threshold conditions |
| Formal contract verification | For the verified model, *all admitted inputs* satisfy formal postconditions, subject to assumptions | `requires cents >= 0 => ensures discount <= cents` |

A formal proof is about precisely stated properties; high mutation score or MC/DC coverage is not a substitute, and formal proof of an incomplete contract does not establish full business correctness.

The compiler SHOULD extract a **business-rule coverage graph**:

```text
requirement -> accepted contract revision -> implementation symbol
            -> formal obligations -> proof status
            -> example/property/mutation test evidence
            -> reviewer approval
```

Reviewers can determine which rules lack any of: approved meaning, negative/boundary cases, formal obligations, or satisfactory evidence. A rule with zero meaningful assertions must never receive a green 'business verified' status simply because tests pass.

## 7. Status and review gates

Per *property*, report exactly one of:

- `VERIFIED`: all obligations proved under a recorded model and trusted assumptions.
- `REFUTED`: the verifier found a genuine counterexample in the supported model (validated where feasible).
- `UNKNOWN`: timeout, unsupported language fragment, insufficient invariants, unresolved proof.
- `STALE`: inputs changed after evidence was created.
- `NOT_RUN`: verification not requested.

A **business rule** gets a separate review/evidence status; `VERIFIED` of two assertions must never be presented as proof of all behavior.

Suggested policy for CI:

- `normal`: ordinary type checks and tests; proofs optional.
- `contract`: reject missing IDs, unapproved required contracts, failing tests, stale references.
- `critical`: require selected properties VERIFIED, required boundary cases passed, trusted assumptions enumerated, no UNKNOWN or STALE for mandated properties.

The policy is project-defined, with an explicit list of critical rule IDs. Do not require formal verification for every application function.

## 8. CLI and MCP requirements

Proposed commands:

```bash
orin test --business
orin test --rule SHOP-001
orin verify --rule SHOP-001
orin verify --changed --json
orin verify --explain SHOP-001
orin evidence --format markdown
```

The integrated compiler MCP SHOULD expose verification through the existing small tool surface (e.g. `check` with `verification: "changed"`, and `inspect` for a contract/report), rather than registering dozens of new tools. A `verify` tool MAY be introduced if workload separation is necessary.

Compact structured response example:

```json
{
  "revision": "git:abc123",
  "rule": "SHOP-001",
  "contractRevision": 3,
  "status": "UNKNOWN",
  "properties": [
    {"id": "NON_NEGATIVE", "status": "VERIFIED"},
    {"id": "CAP_AT_TEN_PERCENT", "status": "UNKNOWN", "reason": "integer-overflow obligation"}
  ],
  "tests": {"casesPassed": 4, "casesRequired": 4},
  "trustedAssumptions": [],
  "nextAction": "Bound cents or prove no overflow"
}
```

A reviewer-facing human report MUST include readable rule text, case matrix, boundary tests, proof assumptions, proof statuses, code locations, last verified revision and an explicit statement of **what has not been proved**. MCP deltas MUST refer to a known prior revision or fall back to a snapshot.

## 9. Security and trust

- Contract annotations and verification hints MUST NOT silently weaken normal Orin memory safety.
- General `assume`/`axiom` MUST NOT be permitted in ordinary application code without a narrowly scoped, reviewable trusted boundary. Trusted assumptions MUST be enumerated prominently.
- Verification must use correct fixed-width integer, overflow, floating-point, OIM value/alias and effect semantics. Approximations may be used only if sound and clearly stated.
- Runtime checks for unproved properties MAY be an opt-in fallback. They are not evidence of universal static proof.
- The verification backend must be sandboxed/resource limited. Compilation of untrusted projects, macros and tests must respect the project's security policy.
- Native compiler correctness remains a separate issue: source-level proof plus an unverified backend does not establish end-to-end verified machine code.
- Self-hosting is independent of proof correctness. Future self-hosted code may call an external solver/verifier; it does not have to implement an SMT solver itself.

## 10. Incremental delivery plan

**Milestone A — Evidence first** (feasible early): `@Rule`, `@Tests`, `@Case`, unique IDs, type-checked metadata, traceability, business-case matrix, property-test integration, MCP/CI summaries. No formal proof claim.

**Milestone B — Small pure verifier**: `requires`/`ensures` for pure functions with `bool`, fixed-width integers, simple records, `Option`/`Result`; generate VCs and send them to an SMT backend; strict VERIFIED/UNKNOWN distinction; counterexamples where available.

**Milestone C — Controlled imperative code**: loop invariants, decreases, arrays, well-defined overflow and bounds behavior, contract-checked calls, modular compilation.

**Milestone D — Classes and effects**: class invariants, mutating methods with OIM value semantics, frame conditions, resource/actor protocols, abstract external effects.

**Milestone E — Independent checking**: checked proof artifacts, reproducible certificates, proof-status cache, translation validation or tighter compiler trusted base.

Formal verification MUST remain a separable feature and SHOULD NOT block early self-hosting. Ordinary Orin remains concise; only business-critical logic needs explicit contracts and proofs.

## 11. Research foundations

- **Dafny** (Leino; official reference): `requires`, `ensures`, loop invariants, `decreases`, modular reasoning. https://dafny.org/latest/DafnyRef/DafnyRef.html
- **Why3 / Weakest Preconditions** (Filliâtre et al.; official VC generation docs): construction of VCs as `Pre => WP(body, Post)`. https://why3.org/doc/vcgen.html
- **Prusti / Viper** (official project/docs): specifications and verification of Rust implementations with preconditions, postconditions and loop invariants. https://github.com/prusti/prusti
- **Orin OIM safety RFC:** refer to `07-formal-safety.md`; proofs of business functional correctness and memory safety are distinct obligations.

## 12. Acceptance criteria

The proposed feature is ready for an experimental release only when:

1. Every reported VERIFIED proof is reproducible against a pinned source/contract/model revision.
2. The verifier never reports VERIFIED for unsupported, timed-out, failed or stale obligations.
3. At least one deliberately incorrect implementation yields a reproducible counterexample.
4. `Result`/`Option` branches are accounted for in verification and business-case reporting.
5. Tests and proofs refer to stable business-rule IDs, and the reviewer can see missing cases and assumptions.
6. Changing an implementation, a transitive callee contract or a contract definition invalidates the relevant evidence.
7. Release binaries do not incur proof-generation overhead unless explicitly requested; runtime assertion checks are separately configured.
8. Formal contracts cannot override the ordinary type checker, OIM safety restrictions or module visibility.

**Normative principle:** Orin may prove *implementation conforms to an approved formal business contract*. It cannot prove the contract itself is the business's intended rule without independent review.
