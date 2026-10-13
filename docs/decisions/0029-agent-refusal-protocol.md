# ADR-0029: Refusal protocol — every "no" of the toolchain says who has to act next

Status: proposed (2026-10-13). Related: ADR-0020 D1 (status vocabulary, `NEEDS_DECISION`),
ADR-0021/0027 (capabilities), ADR-0028 (contract quality), ADR-0023 (OSIG diff), vision §20a
point 6 (governance: an agent must not silently weaken a contract or add rights to make a red
result green).

## Context

Orin is meant to be written mostly by agents. When the compiler, the verifier or a policy says
**no**, an agent today sees an error code, a message and (for `REFUTED` contracts) a
counterexample. It cannot tell *whose* problem the refusal is:

1. the **code** is wrong and the agent should fix it;
2. the **specification** is incomplete (the verifier returns `UNKNOWN` because an invariant or
   precondition is missing) and the agent may propose one;
3. the code and the specification **contradict each other** and only a human knows which one is
   intended;
4. the change needs **more authority** (a capability grant, a new module dependency, a weaker
   contract, a new assumption) that an agent must never grant itself.

Agents typically "repair" cases 3 and 4 the cheapest way: weaken the `@Ensures`, add an
`@Assume`, widen a grant, add `allowed_dependencies`. The result is green and wrong. Provable
correctness from the ground up means the toolchain must make the right next step explicit,
including **the right question to ask a human**.

## Decision

### 1. Every refusal carries an `action` (binding for all new diagnostics and results)

Each error, warning and verification result in JSON (`--format=json`, MCP, LSP `data`) gets a field
`action` with exactly one of:

| `action` | Meaning | Agent may |
|---|---|---|
| `FIX_CODE` | The code violates a stated rule or contract; the spec is not in question | change the code |
| `STRENGTHEN_SPEC` | Proof failed for lack of information (`UNKNOWN`, missing invariant, missing precondition) | propose an *additional* contract; the proposal is shown as a suggestion, not applied as truth |
| `NEEDS_DECISION` | Code and spec disagree, or several fixes change meaning differently | ask a human, using `question` and `options`; must not pick an option itself |
| `NEEDS_AUTHORITY` | The fix requires more authority: grant, policy, dependency rule, assumption, weaker contract | ask a human; never apply itself |

`NEEDS_DECISION` is the existing ADR-0020 D1 status; `NEEDS_AUTHORITY` is a refinement of it for
governance cases and maps to `NEEDS_DECISION` wherever only D1 statuses are allowed.

### 2. Machine-readable evidence and a pre-formulated question

A refusal with `NEEDS_DECISION` or `NEEDS_AUTHORITY` carries:

- `evidence`: the counterexample (inputs, path through the function with source spans once MIR
  spans exist, ADR-0020 D3), the contract clause, the conflicting code location;
- `question`: one sentence a human can answer without reading the code, e.g.
  *"`withdraw(amount: 5)` with `balance: 3` makes `balance` negative, but `@Invariant(balance >= 0)`
  forbids it. Should withdraw reject the call (add `@Requires(amount <= this.balance)`), or may the
  balance become negative (remove the invariant)?"*;
- `options`: the concrete alternatives, each with its edit and its consequence
  (`changes_spec: true|false`, `widens_authority: true|false`).

`FIX_CODE` results carry `evidence` and, where mechanical, a `fix` edit (the same edit format as
ADR "did you mean" suggestions in roadmap step 2a). `STRENGTHEN_SPEC` results carry candidate
contracts derived from the counterexample (the negated failing condition as a precondition).

### 3. Classification rules (first version)

| Situation | `action` |
|---|---|
| type error, ownership error, unknown name, exhaustiveness | `FIX_CODE` |
| `REFUTED` `@Ensures`/`@Invariant` where the counterexample violates a `@Requires` of a *caller* inside the package | `FIX_CODE` (at the caller) |
| `REFUTED` contract of the function itself | `NEEDS_DECISION` (the code or the contract is wrong; options: change the body / add a precondition / change the contract) |
| `UNKNOWN` because of a loop without invariant or a call without `@Ensures` | `STRENGTHEN_SPEC` |
| `UNKNOWN` because of the unsupported fragment (strings, floats, collections) | `STRENGTHEN_SPEC` with reason; no candidate |
| capability not granted, path outside a scoped grant (E047x) | `NEEDS_AUTHORITY` |
| import violates `allowed_dependencies` (E0501) | `NEEDS_AUTHORITY` |
| contract-quality warnings (ADR-0028) | `STRENGTHEN_SPEC` |

### 4. Governance check in `orin diff` (OSIG)

`orin diff --base --head` reports, as `NEEDS_AUTHORITY` items in its summary and HTML report:
a removed or weakened `@Requires`/`@Ensures`/`@Invariant` (weaker = removed clause, or Z3 shows the
new clause is implied by the old one but not vice versa; otherwise `UNKNOWN`), a new `@Assume`,
a new capability grant or wider grant scope, a new `PERFORMS_IO` edge, a new
`allowed_dependencies` entry, a `VERIFIED` result that became `UNKNOWN`/`REFUTED`. CI can make these
fail closed unless the PR is labelled as approved by a human.

### 5. Agent guidance

`orin mcp` exposes the `action` field and a short instruction in its tool description:
*"On NEEDS_DECISION or NEEDS_AUTHORITY, stop and ask the user the provided question with the
provided options. Do not weaken contracts, add assumptions, widen grants or dependency rules
to make a result pass."* The same text goes into `docs/agents.md` (to be written) and the
`CLAUDE.md`/`AGENTS.md` of the `orin new` template (roadmap step 2a).

## Consequences

- The toolchain's "no" becomes a protocol: fix it yourself, propose a spec, or ask the human —
  with the question already formulated.
- Honest limits: the classification is a heuristic in places (row "REFUTED contract of the
  function itself" cannot know which side is intended — that is exactly why it asks). Candidate
  contracts are suggestions and stay `ASSUMED`/unverified until checked. Weakening detection via Z3
  only covers the supported int/bool fragment; elsewhere it reports `UNKNOWN`, never "not weaker".
- Diagnostics JSON gains fields; existing fields stay (additive, versioned with the diagnostics
  schema).

## Plan

1. After ADR-0028 lands: `action`/`evidence`/`question`/`options` for `orin verify --contracts`
   (REFUTED/UNKNOWN) and the contract-quality warnings; MCP tool description.
2. With roadmap step 2a (diagnostics): `action` and `fix` on all compiler diagnostics.
3. With capabilities Stage A/B: `NEEDS_AUTHORITY` for E047x and E0501.
4. OSIG diff governance items (§4) and a CI gate for the compiler itself.
5. An agent evaluation: a corpus of tasks where the correct behaviour is to ask (contradictory
   spec, missing grant); measured: does an agent using `orin mcp` ask instead of weakening.
