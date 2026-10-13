# ADR-0031: Stronger invariants — better diagnostics and verified business logic

Status: accepted (2026-10-13, project owner). Related: ADR-0012 (contract clauses), ADR-0028
(contract quality), ADR-0029 (refusal protocol), ADR-0030 (provable std), ADR-0020 D1 (statuses).

## Context

Today:
- most invariants are only checked at run time in a `--check-contracts` build (`TESTED_ONLY`);
- Z3 verification covers pure int/bool expressions only;
- record invariants are type-checked but not enforced;
- helpers used in contracts cannot use closures, `map`, `every` or `some`;
- a contract that calls its own function does not terminate under `--check-contracts`;
- a violated contract reports the clause, but not the values that broke it.

The goal has two parts. First, the toolchain should report errors earlier, with better content: at
compile time rather than in tests, with values, blame and the next action. Second, **business logic
should be provably correct**: money is conserved, totals match their line items, state machines only
take allowed transitions, and rounding follows a stated rule.

## Decision

### A. Diagnostics and enforcement (first)

1. **Violation reports with values** (power-assert style). Every subterm of the failed clause is
   printed with its value, plus the `old(...)` values, the call and its arguments.
2. **Blame and action at run time**, the same as ADR-0029 statically:
   - a failed `@Requires` → caller, `FIX_CODE` at the call site;
   - a failed `@Ensures`/`@Invariant` → callee, `NEEDS_DECISION`.
3. **Record invariants are enforced** at every literal, at every field assignment and at
   construction through functions. A value of the type that violates its invariant cannot exist.
4. **Purity inference:** a function with no I/O, no mutation of reachable state and no trap other
   than the contract checks is *pure*. Pure functions and pure closures may be used in contracts,
   including the prelude's `every`, `some`, `count`, `map` and `filter`.
5. **Contract-internal calls** go to the unchecked version of the function, so a self-call inside
   a contract terminates.

### B. Static verification grows (largest step)

6. **The VC fragment grows** to cover:
   - array length and indexing (the sequence theory);
   - record and class fields;
   - `Option`/`Result`;
   - `Map` size and membership;
   - fixed-width integers with exact ranges;
   - strings by length, with full string theory only where it stays decidable.
7. **Modular verification:** a call is replaced by the callee's `@Requires` (an obligation) and
   `@Ensures` (an assumption). Pure functions become uninterpreted functions axiomatised by their
   contracts.
8. **Class invariants are proved per method:** `inv ∧ requires ⇒ inv' after body`. A method that
   can break an invariant is a compile-time `REFUTED` with a counterexample.
9. **Frames are inferred, not annotated.** Value semantics mean there is no aliasing, and the
   compiler already infers which methods mutate `this`. A method's frame is the set of fields it
   writes. This is the structural advantage of Orin over heap-based languages.
10. **Loop invariants** need additive syntax (an ADR under the ADR-0016 rule). Simple bounds such
    as `0 <= i <= arr.length` are inferred.

### C. Business-logic specification patterns

These are the constructs that make "mathematically correct business logic" expressible and
checkable:

11. **Bounded quantifiers in contracts:** `forall(i in 0..arr.length, P(i))` and `exists(...)`.
    At run time they are loops; in Z3 they are quantified formulas over sequences. Examples:
    "every line item has a positive quantity" and "the ledger has no duplicate ids".
12. **Aggregates:** `sum(items, it => it.price * it.qty)` in contracts. These are pure
    combinators from item 4, axiomatised for Z3. Example: `@Invariant(this.total ==
    sum(this.items, ...))`.
13. **Conservation laws** as two-state contracts over `old`. Example:
    `@Ensures(sum(this.balances) == old(sum(this.balances)))` for a transfer, so money is neither
    created nor destroyed.
14. **Executable specifications (refinement):** a simple, obviously correct pure function is the
    spec, and the optimised implementation states `@Ensures(result == specFn(args))`. Z3 proves it
    where it can; property-based tests check it otherwise. This is the main pattern for complex
    business rules such as pricing, tax, discounts and rounding.
15. **State machines:** an `enum` state plus a declared transition relation (`@Transitions` or a
    pure `allowed(from, to)` function). Every method that changes the state ensures
    `allowed(old(state), state)`. OSIG shows the graph and flags unreachable or undeclared states.
16. **`std:decimal`:** exact fixed-point money (no floats for money). Rounding is an explicit
    parameter (`HalfEven`, `HalfUp`, …) with contracts. Currency is a type parameter, so EUR + USD
    is a compile error. Overflow traps as with all integers.
17. **Property-based tests:** `@Property` with generators for records and collections. Each
    `@Ensures` and refinement contract is exercised on generated inputs, and failures are shrunk to
    a minimal counterexample. Where Z3 is UNKNOWN, this is the stated evidence (`TESTED_ONLY`) —
    never reported as VERIFIED.

### D. Invariant suggestions

18. **Dynamic invariant inference** (Daikon-style) during `orin test` observes relations between
    fields: order, equal lengths, sortedness, sums. Z3 checks each candidate. Survivors are offered as
    `STRENGTHEN_SPEC` candidates, never applied automatically.
19. **Mutation survivors** (ADR-0028 tool) are turned into hints that name the missing clause.

### E. Contract-driven optimisation

20. **Only `VERIFIED` facts may remove a check or change a representation.** A contract that is
    only `TESTED_ONLY` or `ASSUMED` never removes a memory-safety check, because a wrong contract
    would then turn a logic bug into memory unsafety (finding F-shape: bounds checks are the
    backstop).
21. **Optimisations enabled by proved facts:**
    - a proved index bound removes the bounds check;
    - a proved integer range removes the overflow check and allows a narrower stored
      representation (e.g. `u16` instead of `i64`);
    - a proved size bound (`@Invariant(this.buf.length <= 64)`) allows inline fixed storage instead
      of a heap array: unboxing, no allocation, no reference count;
    - a proved `isSome()` invariant allows a tag-free `Option` field and an unchecked `unwrap`;
    - a declared state machine removes unreachable states and their code;
    - a proved result length (`@Ensures(result.length == a.length + b.length)`) allows one
      exact-size allocation instead of growth;
    - compiler-inferred uniqueness removes the copy-on-write check.
22. **Check hoisting is allowed earlier,** because it removes no check: a runtime-checked
    `@Requires(i < arr.length)` at the call lets the checks inside the body go. The check moves
    and is not deleted, so a wrong contract is still caught.
23. **Why this is sound in Orin:** value semantics mean no aliasing, so a proved fact about a
    field cannot be invalidated through another reference.
24. **Validation:** every such optimisation goes through translation validation (ADR-0032). The
    validator receives the used facts as listed assumptions, and the assurance report shows which
    check was removed on the basis of which proof.

## Honest limits

- Z3 is incomplete for nonlinear arithmetic, quantifiers and strings. The goal is fewer `UNKNOWN`
  results, not zero; UNKNOWN stays visible.
- A fully proved implementation can still implement the wrong rule. Executable specs (14) keep the
  spec small and reviewable, and `NEEDS_DECISION` stays the answer to conflicts.
- Inferred invariants and generated tests are evidence of the observed behaviour, not of the
  intended behaviour.
- Every new construct (quantifiers, `sum`, `@Transitions`, loop invariants, `@Property`) is
  additive syntax or std and needs its own ADR or ADR-0016 amendment before it ships.

## Order

1. A (items 1–5), right after PR #31 (rewrite 2a + contract quality).
2. B items 6–9 and C items 11–14, together, because quantifiers and aggregates need the sequence
   theory.
3. `std:decimal` (16) alongside the std foundation (ADR-0030); then state machines (15) and
   `@Property` (17).
4. D (18–19), and loop invariants (10).
5. E: check hoisting (22) with the optimisation work. Proof-based removals (21) come in the
   performance push (roadmap step 6), after B and ADR-0032 translation validation.
6. A reference example, `examples/ledger/`: accounts, transfers, invoices with line items,
   tax/rounding and an order state machine. Every rule is stated as a contract, and the example
   reports, per clause, `VERIFIED`, `TESTED_ONLY` or `UNKNOWN`. This is the acceptance test of
   this ADR.
