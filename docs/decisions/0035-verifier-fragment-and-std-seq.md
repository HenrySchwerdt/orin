# ADR-0035: The verifier fragment of ADR-0031 B/C, loop invariants and `std:seq`

Status: accepted for implementation (2026-10-14), as the "own ADR" ADR-0031 asks for before quantifiers and
aggregates ship. Related: ADR-0012 (contract clauses), ADR-0020 D1 (statuses), ADR-0028 (W046x), ADR-0029 (refusal
protocol), ADR-0031 (B items 6-9, C items 11-14). Open questions for the owner are at the end.

## Context

ADR-0031 B and C ask for a larger fragment of `orin verify --contracts` (sequences, records, `Option` / `Result` / `Map`,
exact integer widths, modular calls, class invariants per method, frames), for bounded quantifiers and aggregates in
contracts, and say that every new construct (quantifiers, `sum`, loop invariants) needs its own ADR or an ADR-0016
amendment before it ships. Looking at the code for this ADR showed two things that change the plan:

1. **Loop invariants already have syntax.** `@Invariant(e)` before a `while` / `for` loop is in the grammar and the AST
   since ADR-0012 (`SContract`); it is type-checked and not used. No new syntax is needed to give the verifier loop
   invariants.
2. **The prelude's array API cannot be extended without the checker.** The array prelude (`array/`) is not in scope of
   user code: the checker rewrites `xs.map(f)` to the generic function. A new method such as `xs.sum()` would need a
   change in `compiler/check/body.or`, and a free function `sum(xs)` in the prelude is not visible to a program.
   A std module (ADR-0030) is the existing way to add a pure library function.

## Decision

### 1. Quantifiers are the array API plus one function; no new syntax

ADR-0031 C11 proposes `forall(i in 0..n, P(i))` and `exists(..)`. Instead:

- `xs.every(p)` and `xs.some(p)` with a pure lambda are the bounded quantifiers over the *elements* of an array. They exist
  today, runtime semantics unchanged (ADR-0031 A4 made them legal in contracts).
- Quantifiers over *indices* (sortedness, "no duplicates") use `range(lo, hi)` of the new module **`std:seq`**:
  `range(1, xs.length).every(i => xs[i - 1] <= xs[i])`. At run time `range` builds the index array (a loop); the verifier
  reads `range(a, b).every(..)` / `.some(..)` as `forall i. a <= i < b ==> ..` / `exists`. Nested ranges give
  pairwise properties.
- This costs an allocation per evaluation in a `--check-contracts` build and nothing in a normal build (clauses are
  erased). It adds a function to std, no grammar and no keyword.

### 2. Aggregates: `sum` and `sumBy` in `std:seq`

`sum(xs: int[]): int` and `sumBy<T>(xs: T[], f: (x: T) => int): int` are ordinary pure functions (loops; `sumBy` is pure
relative to `f`, like `every`). Under `--check-contracts` they run as written, so the runtime meaning is the code's. The
verifier does not run them: it gives each distinct summand `F` the recursive function
`psum(d, n) = n <= 0 ? 0 : psum(d, n - 1) + F(d[n - 1])` (SMT-LIB `define-fun-rec`) and the lemma
`psum(store(d, i, v), n) = psum(d, n) + (0 <= i < n ? F(v) - F(d[i]) : 0)`, a theorem of the definition by induction on `n`
that lets the solver reason about element updates (a transfer between two balances keeps the sum) without induction of its
own. Overflow: contracts are over mathematical integers; a sum that does not fit traps at run time and the verifier assumes the
paths that return did not overflow (A-INT).

### 3. The verification fragment (the table is in docs/contracts.md)

Generic functions and classes are checked once, abstractly: a type parameter is an opaque value. Arrays are a data array plus a length (`select` / `store`; index with an in-bounds obligation, `push`, `pop`, `slice`,
element assignment); records and classes are datatypes (field read, write through nested places, `{ ..r, f: v }`);
`Option`, `Result` and unions are datatypes with `match`; `Map` is a presence array, a value array and a size; strings are a
pair (length, id) with uninterpreted content operations; every integer width has its exact range. Unsupported constructs give
`UNKNOWN` with the reason. Datatypes are *free*, so facts every real value satisfies (a length is not negative, a `u8` is in
0..255) are stated about the values that arise (parameters, fresh values, call results), never as axioms over all values.

### 4. Soundness rules for statuses

- `VERIFIED` is solver `unsat`, plus: every loop invariant it relied on is itself proved (entry and one iteration), else
  `UNKNOWN`.
- `REFUTED` needs a counterexample that is real: a `sat` model on a path that used no abstraction. A path through a loop
  without a proved-complete invariant, a `Map` size, string contents that were derived, or **a value that is only known through
  a callee's contract** (a pure function is an uninterpreted function; the result of an impure call and a receiver after a
  mutating call are constrained only by `@Ensures` and the frame; this includes the assumptions about the inputs, a pure
  helper in a `@Requires`) is *abstract*: `sat` there is `UNKNOWN` ("the counterexample is not trusted"), with
  `action: STRENGTHEN_SPEC`. The arguments of a call, and a `new C(..)` whose fields are determined by parameter properties and
  initialisers, are not abstract.
- To keep refutation useful, a loop is also **unrolled a few iterations exactly** (3); obligations and postconditions found
  on those paths are real. A false claim after a loop, and an index that goes out of range within three iterations, are
  `REFUTED`.
- `unsat` of a query that assumed the *callee* contracts (modular calls) is `VERIFIED` under assumption A-CALL, listed on the
  result (ADR-0020 D1); likewise A-PURE, A-INV, A-FRAME, A-LOOP, A-STR, A-MAP (docs/assurance.md).

### 5. Class invariants and frames

For every public method that changes `this` (the existing mutation analysis, `Program.mutating`) and for every constructor,
the verifier proves `inv && requires ==> inv'` at every return; the result kind is `invariant`. A method that can break an
invariant is `REFUTED` with the values of `this` and the arguments, `action: NEEDS_DECISION` and the three options (fix the
method, add a precondition, weaken the invariant). A method's *frame* is the set of fields its body writes, found by the same
kind of syntactic scan that the mutation analysis does; across a call of a mutating method, fields outside the frame keep their
value (A-FRAME, listed on every result that used it). There are no annotations.

## Consequences

- No grammar change, no new keyword, no checker change (`compiler/check/body.or` is untouched). One new std module
  (`stdlib/seq.or`, registered in `compiler/loader/resolve.or`), one new CLI-visible kind of result per obligation:
  `bounds`, `unwrap`, `invariant`, `loop-invariant` (besides `ensures`, `call-precondition`, `decreases`).
- `std:seq` is verified by the verifier itself (`range` and `sum` have loop invariants; `sumBy` is generic, so its clause is
  `UNKNOWN`: generic functions are outside the fragment).
- Loop `@Invariant` is not yet checked at run time. It is only trusted after the verifier proved it.

## Honest limits

- Z3 is incomplete for quantifiers: a proof that needs an induction the lemmas do not cover is `UNKNOWN`. A false claim is
  often `REFUTED` through the unrolled pass or the bounded search (arrays of length <= 3 without the lemmas), not always.
- Loops with `break` / `continue` are not given invariants. Loop invariants over records of the loop-modified variables
  (`this.f` changed in a loop) are found field by field; calls to mutating methods inside loops havoc the receiver.
- A write to a public field of a class from outside the class can break an invariant that the verifier assumes on entry
  (A-INV). The run-time check has the same hole (invariants are checked at constructors and after methods).
- Strings are modelled by length. `REFUTED` is only given when the claim and the path use lengths, `charCodeAt` or `+`, not
  all together and not derived contents.
- Floats, interfaces, closures as values, `?`, `reduce`, calls of generic functions from outside their class and recursive
  types (their fields are opaque) are outside the fragment. Types with the same simple name in two units are ambiguous
  (UNKNOWN); resolving names per unit is the next step for the compiler's own sources.
- `charCodeAt` is a byte (0..255): the runtime reads an unsigned char. A `charCodeAt` value that reaches a goal or a path
  condition makes a counterexample untrusted (the model does not know the contents, e.g. of a table literal).

## Open questions for the owner

1. Run-time checking of the loop `@Invariant` (cheap: check at the top of each iteration) so that a loop invariant that the
   verifier cannot prove is at least tested. Recommended; not done here (it changes `compiler/check/rtcheck.or` behaviour).
2. `std:seq` is a library module. If `xs.sum()` and `forall(i in a..b, ..)` read better, they are a later checker change; the
   verifier reads both forms the same way once they exist.
3. Whether the unrolled pass (3 iterations) should be configurable (`--unroll N`).
