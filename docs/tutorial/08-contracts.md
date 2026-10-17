# 8. Contracts

A contract states what a function needs and what it promises. Orin can prove many contracts with an SMT solver, and checks
the rest while your tests run.

## The program

<!-- file: examples/tutorial/08-contracts.or -->
```ts
// Contracts: @Requires says what a caller must provide, @Ensures what the function promises.
//   orin verify --contracts 08-contracts.or     proves the clauses with z3
//   orin compile --check-contracts              checks them while the program runs
@Requires(lo <= hi)
@Ensures(result >= lo && result <= hi)
@Ensures(x >= lo && x <= hi ==> result == x)
function clamp(x: int, lo: int, hi: int): int {
  if (x < lo) {
    return lo;
  }
  if (x > hi) {
    return hi;
  }
  return x;
}

@Ensures(result >= 0)
@Ensures(result == x || result == 0 - x)
function abs(x: int): int {
  if (x < 0) {
    return 0 - x;
  }
  return x;
}

function main(): void {
  console.log("clamp(15, 0, 10) = " + clamp(15, 0, 10).toString());
  console.log("abs(-7) = " + abs(-7).toString());
}
```

- `@Requires(e)` is the precondition: what a caller must make true. A violation is the *caller's* fault.
- `@Ensures(e)` is the postcondition: what the function promises. In it `result` is the return value; `old(e)` is the value
  of `e` on entry (for methods). A violation is the *function's* fault.
- `a ==> b` means "if `a` then `b`". A contract expression has no side effects: it may use arithmetic, comparisons,
  `match`, array and string methods and calls of pure functions.
- Contracts cost nothing in a normal build: they produce no code. `orin run` prints:

<!-- file: examples/tutorial/08-contracts.out -->
```text
clamp(15, 0, 10) = 10
abs(-7) = 7
```

## Proving them: `orin verify`

`orin verify --contracts` turns each clause into a logical question and asks [z3](https://github.com/Z3Prover/z3). z3 is not
part of Orin: install it (`brew install z3`, `apt install z3` or `pip install z3-solver`) and make sure `z3` is on your
`PATH`.

```sh
orin verify --contracts examples/tutorial/08-contracts.or
```

<!-- file: examples/tutorial/08-contracts.verify.out -->
```text
VERIFIED  clamp: @Ensures(result >= lo && result <= hi)  (examples/tutorial/08-contracts.or:5)
VERIFIED  clamp: @Ensures(x >= lo && x <= hi ==> result == x)  (examples/tutorial/08-contracts.or:6)
VERIFIED  abs: @Ensures(result >= 0)  (examples/tutorial/08-contracts.or:17)
VERIFIED  abs: @Ensures(result == x || result == 0 - x)  (examples/tutorial/08-contracts.or:18)
VERIFIED  main: @Requires(lo <= hi) (call of clamp)  (examples/tutorial/08-contracts.or:27)
VERIFIED holds under these assumptions:
  A-INT: integers: every arithmetic result and conversion is assumed to be in the range of its type on the paths that return (an overflow traps, so it never returns); inside a contract integers are unbounded
  A-DIV: no division or remainder by zero occurs on the paths that return
  A-PARTIAL: partial correctness: the function is assumed to return (termination is not proved)
  A-CALL: the contracts of the functions called hold: their @Ensures are assumed (each is proved for the callee separately), and a recursive call assumes the function's own contract
  A-PURE: a function the purity analysis finds pure is a deterministic function of its arguments
  A-STR: strings are modelled by their length (and an id for the contents); concatenation, substring and the other operations on contents are uninterpreted; charCodeAt is a byte in 0..255 (the runtime reads an unsigned char)
verified 5, refuted 0, unknown 0
```

Each line is a clause that was proved for *all* inputs. The `main:` line shows that the call `clamp(15, 0, 10)` meets the callee's `@Requires`
(`0 <= 10`); calls are checked against preconditions too. The assumptions at the end are part of the result: for example integers do not
overflow on a path that returns (an overflow traps, so it never returns a wrong value), and termination is not proved.
Note the `@Requires` on `abs`: without it `abs(-9223372036854775808)` would overflow, and the prover would say so.

## When a contract is wrong

<!-- file: examples/tutorial/08-violation.or -->
```ts
// A broken function: the @Ensures clause is not true for every input.
// `orin verify --contracts` refutes it; `orin test` (which checks contracts at run time) fails.
@Ensures(result >= 0)
function absWrong(x: int): int {
  return x;   // forgot to negate
}

@Test
function absOfNegative(): void {
  absWrong(-3);
}

function main(): void {
  console.log("absWrong(3) = " + absWrong(3).toString());
}
```

`absWrong` forgets to negate. Verification finds an input that breaks the promise and exits with status 1:

```sh
orin verify --contracts examples/tutorial/08-violation.or
```

```
REFUTED  absWrong: @Ensures(result >= 0)  (examples/tutorial/08-violation.or:3)
    counterexample: x = -9223372036854775808
    action: NEEDS_DECISION
    question: absWrong(x = -9223372036854775808) violates @Ensures(result >= 0). Is the body wrong (fix it), ...
    ...
verified 0, refuted 1, unknown 0
```

A clause can also be `UNKNOWN` (the solver gave up or the clause uses something it cannot model); that is never reported
as verified. The same contract is checked at run time when you test: `orin test` runs with contract checking on, so the
test fails with the exact clause, the argument values and who is to blame:

```sh
orin test examples/tutorial/08-violation.or
```

<!-- file: examples/tutorial/08-violation.test.out -->
```text
FAIL 08-violation.absOfNegative (trap, exit 101) examples/tutorial/08-violation.or:9:10
     stderr: trap: contract violated: @Ensures(result >= 0) at examples/tutorial/08-violation.or:3
     stderr:   function: 08-violation.absWrong(x = -3)
     stderr:   values:
     stderr:     result = -3
     stderr:   blame: the callee 08-violation.absWrong
     stderr:   action: NEEDS_DECISION
     stderr:   question: 08-violation.absWrong breaks its @Ensures. Is the code wrong, or is the contract?
     stderr:   option 1: fix the code (the specification stays)
     stderr:   option 2: add a precondition that excludes this call (changes the specification)
     stderr:   option 3: change the clause (changes the specification)
0 passed, 1 failed
```

The program itself (`orin run`) still prints `absWrong(3) = 3`, because outside of tests and verification the clauses are
erased.

Classes can have an `@Invariant(e)` that holds after the constructor and every public method; loops can have
`@Invariant` and `@Decreases`. See the [contracts guide](../contracts.md).

## Try it

Fix `absWrong` (`return x < 0 ? 0 - x : x;`) and verify again: now the clause is `VERIFIED`. Then change
the contract to `@Ensures(result > 0)` and read the counterexample (`x = 0`).

Reference: [annotations and contracts](../reference/07-annotations-contracts.md), [contracts guide](../contracts.md).

Next: [9. A project with packages](09-project.md).
