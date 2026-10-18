# Contract clauses: implementation notes

Spec: `spec/15-contracts-invariants-and-formal-verification.md` §4.2a. Decision: ADR-0012.
Beyond Orin-B (self-hosted compiler only; the compiler sources themselves stay Orin-B).

Contract clauses look like annotations but are **not annotations**: `@Requires(e)`, `@Ensures(e)`,
`@Invariant(e)`, `@Decreases(e)` and `@Rule("ID")` are a closed set of reserved constructs with their
own grammar productions and AST node (`ContractClause`, `compiler/syntax/ast.or`). The compiler's
built-in annotations `@Test`, `@Deprecated`, `@Inline` (ADR-0024, docs/testing.md) are a separate closed
set with their own AST node (`Annotation`); they may be mixed with contract clauses and are printed
before them. Any other `@Name` is reported as E0408 (user-defined annotations are post-1.0).

## Placement (grammar, E0200 otherwise)

| Clause | Before |
|---|---|
| `@Requires` | function, method, constructor |
| `@Ensures` | function, method |
| `@Invariant` | class, record type (`type R = { .. }`), `while` / `for` loop |
| `@Decreases` | function, method, loop |
| `@Rule` | function, method, constructor, class, any `type` declaration |

Clauses are stored in `contracts: ContractClause[]` on `FunctionDecl`, `MethodDecl`, `CtorDecl`,
`ClassDecl`, `TypeDecl`; loop clauses are `SContract` statements directly before the loop. They may be
mixed with each other in any order; the formatter prints one per line.

## Contract expressions (checker: `compiler/check/{contracts,purity,stmt,expr}.or`)

Every build type-checks all clauses (in a forked function context, then discards the result: nothing
reaches the generated code). Scope: parameters; `this` (methods, class invariants in the constructor,
record invariants); `result` (only in `@Ensures`, typed as the source return type; absent in `void`
functions) and `old(e)` (only in `@Ensures`, not nested); `a ==> b` (right associative, weaker than
`?:`, short-circuit, `!a || b`). For loop clauses the scope is the surrounding scope at the loop.
`@Decreases` takes an `int` or `usize` measure.

| Code | Meaning |
|---|---|
| E0414 | clause is not `bool` (`@Decreases`: not integer) |
| E0415 | `old` outside `@Ensures` / nested, `==>` outside a contract, `?` in a contract, parameter called `result` (or a variable called `loopIndex` in a `for .. of` invariant) hiding it |
| E0416 | impure contract expression (below) |
| E0300 | `result` outside `@Ensures` (or in a `void` function), or any unknown name |

### Purity rule (ADR-0031 A4)

A contract expression may contain only: arithmetic, comparisons, logic, conditionals, `match`, construction of
records / variants / arrays, built-in string / array / int / Option / Result methods, field access and indexing,
closures, and calls of **pure** functions and **pure closures**. It must not contain `?`, mutating built-ins
(`push`, `pop`), calls that mutate their receiver (mutating class methods), or any call whose effects are not
known to be pure (below).

A function is **pure** when
- it performs no I/O built-in (`console.log/error`, `readFile`, `writeFile`, `exists`, `args`, `exit`,
  `readBytes`, `readLine`, `writeStdout`, `shell`, the file primitives),
- it mutates no non-local state (changing its own locals and arrays is not an effect: value semantics, and Orin
  has no mutable globals),
- it calls only pure functions, and
- it calls a function value only if that value is a pure closure.

How function values are judged: a function that calls one of its function-typed *parameters* is pure *relative to
its argument*. `every(xs, pred)` is pure exactly when the closure passed for `pred` is; the call site decides.
So the prelude's `every`, `some`, `map`, `filter` (and any user combinator written the same way) can be used in
contracts with a pure lambda, `xs.every(x => isPositive(x))`, and a helper may use them internally. A function
value of any other origin (a local variable, a field, a call result, a captured variable, a function-typed
parameter of the constrained function itself) and a call through an interface value have unknown effects: the
caller is impure. A closure is judged by its own body (a closure that calls an impure helper is impure) and
captured variables are snapshots, so reading them is not an effect.

The analysis is a fixed point over the call graph of the typed HIR, after all functions (instances of generic
functions, lifted closures) are checked. It is monotone, so recursion and mutual recursion are allowed:
termination is not part of purity, and neither are traps (division by zero, `unwrap` of `None`, index out of
range). A closure that is created counts as called, so an impure closure is rejected even if it is never called.
(`count` is not in the prelude yet; `xs.filter(p).length` does the same.)

`std:seq` (ADR-0036) adds the pure functions `range(lo, hi)` (the index array `lo .. hi - 1`), `sum(xs)` and
`sumBy(xs, f)`: `range(1, xs.length).every(i => xs[i - 1] <= xs[i])` says `xs` is sorted, `sumBy(this.items, it =>
it.price * it.qty)` is the total of the line items. They run as ordinary code under `--check-contracts`;
`orin verify --contracts` reads them as bounded quantifiers and recursive sums (below).

E0416 names the impure operation and where it is: `call is not provably pure: `f` -> `g` performs I/O
(console.log) at file.or:12:3; contract expressions may only call pure functions` (the chain of calls from the
contract to the operation), or `I/O built-in `console.log` is not allowed in a contract expression`, or `function
value passed to `every` in a contract expression is not a closure literal, so its effects are unknown`.

Not supported in a clause: `result`, `this` and `old(..)` inside a closure with a *block* body (an expression
body works); the run-time rewriting does not descend into blocks.

## Erasure

Without flags the clauses produce no code. `tools/test_contract_erasure.py` (CI) compiles programs
with and without their clause lines and requires byte-identical C and LLVM IR. (Known corner: a
contract that is the only user of a generic instantiation leaves that instance in the output. The lifted
closure functions of closures written in a clause are dropped by the prune pass, `compiler/opt/prune.or`.)

## Runtime checking: `orin compile --check-contracts`

`compiler/check/rtcheck.or` expands the type-checked program on the AST and checks it again;
`compiler/check/rthir.or` then rewrites the typed HIR of the result (reports, caller locations, record
invariants):

- a function / method with `@Requires` or `@Ensures` becomes a wrapper with the original name around the
  original body (renamed `$contract$body$<name>`): entry checks, call, exit checks, return. Every return of the
  body, including early `?` returns, is therefore checked; recursive calls go through the wrapper. A function
  with a `@Requires` has a third function, `$contract$site$<name>`, that takes the caller's location as an extra
  first parameter; the wrapper forwards to it with `""`, and a call the compiler can see is redirected to it with
  `file:line` of the call;
- `old(e)` is `e` for functions (parameters are immutable); in methods it is evaluated over a snapshot
  `old$this` of the receiver taken at entry;
- class `@Invariant`s are checked at the end of constructors and after every non-private, non-static
  method; constructor `@Requires` run after the leading `this.f = e;` initialisations;
- **contract-internal calls are unchecked** (ADR-0031 A5): inside a clause a call of a function (or method)
  that has contracts goes to its `$contract$body$` function, so `@Ensures(isNormalized(result))` inside
  `isNormalized`, a self-call, or an invariant that calls a public method of its class terminate. The functions
  called that way run their own bodies as ordinary code (their inner calls are checked as usual);
- a violation prints the report below on stderr and exits with status 101 (same convention as other traps).

### Violation reports (ADR-0031 A1, A2; ADR-0029)

One stable text format on stderr. The first line is unchanged:

```
trap: contract violated: @Ensures(result.length == xs.length + 1 && result[0] == old(xs[0]) + 1) at f.or:13
  function: f.grow(xs = int[] of length 2, label = "abc")
  values:
    result.length = 3
    xs.length + 1 = 3
    result[0] = 5
    old(xs[0]) + 1 = 6
    old(xs[0]) = 5
  blame: the callee f.grow
  action: NEEDS_DECISION
  question: f.grow breaks its @Ensures. Is the code wrong, or is the contract?
  option 1: fix the code (the specification stays)
  option 2: add a precondition that excludes this call (changes the specification)
  option 3: change the clause (changes the specification)
```

- `function:` the function (qualified `unit.name`, `unit.Class.method`, generic instances `unit.f<T>`) and its
  argument values. Values: `int`/`usize`/fixed-width ints, `bool` and `float` by value; a string quoted, cut at 40
  characters with its length (`"abc..." (length 60)`); an array as `int[] of length N`; anything else as `<Type>`
  (not evaluated). A method shows `this = <Class>`.
- `values:` each *maximal non-literal operand* of the clause: both operands of a comparison, the operands of the
  failed boolean atom (the arguments of a call), the atom itself otherwise; literals are not repeated, equal terms
  are shown once. `xs.length + 1` is one term (the maximal operand), not `xs.length` and `1`. Terms are the source
  text of the sub-expression, so they read like the clause.
- `old(..)` values are shown as `old(e) = v`, in the term that contains them and again on their own line.
- The report evaluates sub-terms again, which is safe because contracts are pure. Parts that short-circuiting
  skipped (`b` in `a && b` when `a` was false, `b` in `a || b` when `a` was true) are not evaluated: `i <
  xs.length && xs[i] > 0` with an out-of-range `i` reports `i` and `xs.length`, never `xs[i]`. An `old(..)`
  inside a branch that may be skipped is shown as `<not shown>` unless it cannot trap.
- Blame and action (ADR-0029): a failed `@Requires` is the **caller's** fault: `blame: the caller, at file.or:LINE`
  with `action: FIX_CODE (caller)`. The location is the call of the function; it is not available when the call
  goes through a function value, an interface or a constructor, and the report then says
  `blame: the caller of f (call site not available ...)` (the function and its clause are in the first lines). A
  failed `@Ensures` or class `@Invariant` is the **callee's**: `blame: the callee f`, `action: NEEDS_DECISION`,
  with a `question:` and the `option` lines (an agent must ask a human, not weaken the contract). A record
  invariant reports `record R`, the location of the literal / assignment / return (`blame: the code that built
  this value, at ...`) and `action: NEEDS_DECISION`.
- There is no JSON form of a trap (the runtime prints plain text for every trap); a JSON report would need a
  runtime change.

### Record invariants (ADR-0031 A3)

A record type `@Invariant(e)` (`type R = { .. }`, `this` is the record) is checked under `--check-contracts` at
exactly these points; nowhere else:

1. **every record literal** of type `R`, including `R { ..spread, f: v }` (the invariant is evaluated on the
   finished value, so a literal that spreads a valid record and changes a field is checked);
2. **every write through a place that passes through an `R`**: an assignment `x.f = v`, a compound assignment
   `x.f += v`, a write through nested records `a.b.f = v` (the invariant of every record on the path that has
   one is checked, innermost first), through array elements `xs[i].f = v`, and `push` / `pop` on an array field
   (`x.items.push(v)`) used as a statement or as the initialiser of a `let`. The check runs right after the
   write, on the value as it is after it;
3. **every `return` in a function whose result type is `R`**, unless the returned expression is itself a record
   literal of `R` (already checked at 1). So a value that comes out of a function cannot violate the invariant
   even if it was assembled in a way points 1 and 2 do not see.

A value that violates the invariant therefore cannot be created by a literal, by a field write or by a function
result in checked code. Not checked: a record that is only *read* from an array or a variant payload (it was
checked when it was created); a field assignment whose place contains an index expression with a call in it
(`xs[next()].f = v`: the index would be evaluated twice, so the assignment is not checked); a write via an
`Option` / `Result` / variant payload or through a class field (class invariants are the class's); loop
invariants and `@Decreases`; generic records (`@Invariant` on them is E0408). Inside a clause no record literal
is checked (a clause may build the record it constrains). Records with an invariant in the compiler itself:
`Span`, `Diagnostic`, `Resolved`, `PreludeRoot`.

Without `--check-contracts` a record invariant is only type-checked and erased like every clause.

The test runner understands `// flags: --check-contracts` and `// stderr: text` headers
(`tools/run_tests.py`; for an error test `// stderr:` is matched against the compiler's output, which pins the
text of an E0416 message).

## `orin verify --contracts [--format=json] [--z3 PATH] [--timeout-ms N] [--retry-ms N] [--rlimit N] [--strict] entry.or` (phase 2, ADR-0031 B/C, ADR-0036)

Generates verification conditions and discharges them with z3 (`z3 -in`, SMT-LIB 2; install with
`pip install z3-solver` or your package manager). Query files are kept in `build/contracts-vc/` (`qN.smt2`, the solver's
answer in `qN.out`; a bounded counterexample search writes `qNb.smt2`). Per clause the result is **VERIFIED** (solver
`unsat`), **REFUTED** (`sat` with a counterexample that is real, see "Statuses and abstraction") or **UNKNOWN** (with a
reason; never upgraded to VERIFIED). Exit status 1 if any clause is REFUTED (or, with `--strict`, UNKNOWN). The units of
the program are verified; the std modules it imports (`$stdlib/..`) are *read* for their contracts (modular calls) but not
verified. To verify a std module, give it as the entry (a copy with a `main`, see "Measuring" in docs/assurance.md).

**Solver budget.** Almost all of the run time is z3 queries that end in `unknown`, so the budget decides the speed:
`--timeout-ms N` is the wall time of the first query of an obligation (default 4000), `--retry-ms N` the wall time of the
bounded counterexample search that follows an `unknown` (default 1000, 0 = no retry; `rawProve` in `compiler/vc/vc.or`) and
`--rlimit N` z3's deterministic resource limit (`rlimit=N`, default 0 = none) on top of the wall time. The hard limit of
z3 (`-T`) is the wall time rounded up to seconds plus 2. Measured on the compiler (z3 4.8.12): between 1 s and 4 s a query
is almost never solved (of 4 700 solved first queries 25 took more than 2 s), and the retry with 4 s gave 26 counterexamples and 8
proofs in 900 runs for 45 % of the z3 time; the retry cap of 1 s (the default) and also `--timeout-ms 2000` changed no status on the
modules measured (opt, lower, check, vc, loader, syntax), and `--timeout-ms 2000` halves the time of `opt`. The first
query keeps 4 s by default because a rare slow proof is lost under a lower budget (`i32_square` in
tests/contracts/verify_int_widths.or needs about 2.3 s and turns UNKNOWN at 2 s on a loaded machine): use
`--timeout-ms 2000` for quick runs. A wall-time limit makes a result depend on
the load of the machine; `--rlimit` does not, but z3 counts resource units unevenly (about 1.5 million per second on solved
queries, much fewer on a query stuck in quantifier instantiation, which then runs to the wall time), so it is a cap for
reproducible runs, not a replacement for the wall time.

### What is reported

| `kind` | Result for | Obligation |
|---|---|---|
| `ensures` | every `@Ensures`, at every return of the function or method | the clause holds (and is well defined) |
| `call-precondition` | the `@Requires` of every called function, method or `new C(..)`, at each call site | the caller establishes it; REFUTED is `FIX_CODE` |
| `invariant` | every class `@Invariant`, at every return of a public method that changes `this` and of every constructor | `inv && requires ==> inv'` (B8); a constructor establishes it |
| `bounds` | an index `xs[i]`, `s.charCodeAt(i)`, `s.charAt(i)`, `slice` and `substring` range | in range |
| `unwrap` | `unwrap` of an `Option` / `Result`, `unwrapErr` | the variant is the right one |
| `loop-invariant` | a loop `@Invariant`, on entry and preserved by one iteration | inductive |
| `decreases` | `@Decreases` | always UNKNOWN: termination is not checked |

`bounds` and `unwrap` results are reported for functions that have contract clauses (and for methods of a class with
invariants); a function without any clause only reports its `call-precondition`s. `@Rule` ids are attached to the results
as `rules`. JSON: `{"results":[{"function","file","line","kind","clause","rules","status","reason","counterexample",
"assumptions","action","question","options","candidates","evidence"}],"assumptions":[{"id","text"}],"warnings":[..],
"summary":{"verified","refuted","unknown"}}`. A method is reported as `Class.method`, a constructor as `Class.constructor`.

### The supported fragment

| Construct | Encoding in SMT | Obligation / assumption | Not supported (UNKNOWN with the reason) |
|---|---|---|---|
| `int`/`i64`, `i8 i16 i32 u8 u16 u32 u64 isize usize` | `Int` with the exact range of the type | arithmetic results and conversions are in range on returning paths (A-INT); `usize` subtraction below 0 traps | floats, `i128` |
| `bool`, `+ - * / %`, comparisons, `&& \|\| !`, `==>`, `?:` | Bool / Int; `/` and `%` truncate toward zero as in Orin | divisor non-zero on returning paths (A-DIV) | `wrapping*`, `checked*`, `saturating*` |
| arrays `T[]` | datatype (data `Array Int T`, length); `length`, `xs[i]`, `xs[i] = v`, `push`, `pop`, `get`, `slice`, `concat`, `includes`, `indexOf`, `join`; `find` / `findIndex` exactly (the first match); `sort` and `reduce` partially (see "Method axioms") | index / slice range in bounds (obligation `bounds`) | `reduce` / `sort` results beyond the facts of "Method axioms" |
| `every`, `some`, `map`, `filter` (pure lambda with an expression body) | quantifier over the indices; `map` / `filter` by their defining facts | well-definedness of the lambda body is part of a contract's goal | block-bodied lambdas; in code (not contracts) a lambda body with an index or call precondition |
| `range(a, b).every(i => ..)` / `.some(..)`, `sum(xs)`, `sumBy(xs, f)` (`std:seq`) | bounded quantifier; recursive sum with the store lemma | | `sumBy` summands that need a block |
| records, classes | datatype with one constructor; field read, write through nested places (`a.b.f = v`, `a[i].f = v`), `{ ...r, f: v }`; record `@Invariant`s of parameters and results are assumed (A3) | | generic records |
| recursive records, classes, unions (a type that reaches itself) | uninterpreted sort with accessor functions (a union: a variant tag and payload accessors); a built value is a fresh constant with its fields as facts; no quantifier; see "Recursive types" | same as records / unions; a counterexample is never reported | generic recursive types; `==` on them |
| `Option<T>`, `Result<T, E>`, user unions | datatypes; `isSome`, `isNone`, `isOk`, `isErr`, `unwrap`, `unwrapOr`, `unwrapErr`, `Some`, `None`, `Ok`, `Err`, variant constructors, `match` (expression and statement) | `unwrap` needs the right variant (obligation `unwrap`) | nested patterns, `?` where the operand is not always evaluated (see "Effects inside an expression"), `==` on these types |
| `Map<K, V>` | presence array, value array, size; `has`, `get`, `set`, `delete`, `keys`, `values`, `size`, `new Map` | | `entries`; map equality |
| `string` | datatype (length, id); `length`, `+`, `==`, literals, `charCodeAt`, `charAt`, `substring`, `trim`, `startsWith`, `endsWith`, `includes`, `toString`, template literals; `split`, `indexOf` partially (see "Method axioms") | index / range in bounds; `split` needs a non-empty separator | contents (see "Strings") |
| calls | modular: callee `@Requires` obligation, `@Ensures` assumed; pure function = uninterpreted function; recursion assumes the callee contract | A-CALL, A-PURE | calls of generic functions from outside their class, function values, interface calls |
| methods and constructors | receiver as a datatype value; a mutating method returns the new receiver; `new C(..)`; static methods | class invariants (B8), frames (B9) | `new C<T>(..)` of a generic class |
| generic functions and classes | checked once, abstractly: a type parameter `T` is an opaque value (nothing can be done with it but pass it around and store it), the class applied to its own parameters is the class | | `==` on a `T`; a call of a generic function from code that is not in the same class |
| interface types (`interface Sink { .. }`) | an opaque sort per interface (`If_Sink`): a parameter, field, result or local of the type is some object that implements it; a class-typed argument converts to it at a call (ADR-0019) as a fresh value of the sort | | a method call on the value (an interface call has unknown effects), `==`, a conversion other than an argument of a call |
| `if`, `match`, blocks, `return`, `let`, assignment, `+=` etc. | symbolic execution with merged states | | `break` / `continue` effects (the loop is havoc'd); an effect (`?`, a mutating call) in a `while` condition or in the right operand of `&&` / `||` / `==>`, in a branch of `?:` or in an arm of a `match` that is not a `return match` |
| `while`, `for .. of` | loop `@Invariant`, inferred counter bound, or havoc; also unrolled 3 iterations exactly | A-LOOP | nested loop invariants inside a loop with `break` |
| `console.log` / `console.error`, `exit` | no effect on the values; `exit` ends the path | | any other I/O |

A `match` statement is exhaustive (the checker rejects the others), so the path on which no arm matches is impossible and nothing
leaves it: a function whose arms all `return` has no path that falls off its end, whatever its result type. (Until 2026-10-18 that
path was modelled as a fall-through with the path condition `false`, and the function was UNKNOWN with "return statements do not
match the declared result type".) Regression test: `tests/contracts/verify_gaps.or`.

### Effects inside an expression (`?`, mutating calls)

The translation of an expression is pure, so an expression that contains an effect is first split into statements.
The effects are `e?` on a `Result` (the checker accepts `?` on nothing else; an `Option` is encoded the same way, with `None` as the early return) and a call of a mutating method (`this.next()`, `xs.pop()`, `m.set(k, v)`).
They are executed in the order the expression evaluates them (left to right, EXP-20) and replaced by a temporary holding
their value; each operand evaluated before an effect is bound to a temporary first, so an effect never changes what an
earlier operand reads and an earlier trap still comes first. This is done for a statement, a `let` initialiser, an assigned
value (to a variable or a field of `this`), a `return` value and an `if` condition. In `return match (s) { P => e, .. }` the
effects of the arms are executed in the arm that matches (each arm is a `return` of its own).

`e?` where `e` is Err / None is a return: the function returns `Err(payload)` / `None` of its own result type from that state
(the state after the effects so far), so every `@Ensures` and class invariant is checked on that path too, and the path
continues with the payload where `e` is Ok / Some. The error type of `e` must equal the error type of the function result;
`?` in a function that returns neither Result nor Option is UNKNOWN.

Where the order of evaluation cannot be kept the function is UNKNOWN with a reason: an effect in the right operand of
`&&` / `||` / `==>`, in a branch of `?:`, in an arm of a `match` that is not a `return match`, in a `while` condition, in the receiver of a mutating call,
in the arguments of a mutating call on a receiver that is not a plain variable or field path, in the right-hand side of
`x += ..` or of an assignment to an element (`xs[i] = ..`), or after a function value that is evaluated before it.

### Method axioms (`compiler/vc/methods.or`)

Methods the core translation does not model exactly get **axioms**: the result is a fresh constant constrained by facts that
every real execution satisfies. A partial description (`sort`, `reduce`, `split`, `indexOf`) taints the constant: a model that
depends on it is not a counterexample, so a claim the axioms do not prove is UNKNOWN, never REFUTED. Each fact follows from the
runtime (`runtime/core/orin_runtime.c`) or the prelude (`library/collections/array.or`).

| Method | Facts |
|---|---|
| `xs.sort(cmp)` | same length; every element of the result is an element of `xs` and vice versa. The order is not stated |
| `xs.findIndex(p)` / `xs.find(p)` | exact: `Some(i)` with `i` in bounds, `p(xs[i])` and `p` false before `i` (`find`: the value is `xs[i]`); `None` when `p` is false everywhere. Facts about calls inside `p` are hypotheses, so a call whose contract does not hold weakens the result, never strengthens it |
| `xs.reduce(f, init)` | an empty `xs` gives `init`; nothing else |
| `s.split(sep)` | obligation `bounds`: `sep` is not empty (the runtime traps). At least one piece, at most `s.length + 1`; every piece is a well-formed string no longer than `s` (than `s.length - sep.length` when there are two or more); one piece is `s` (always the case when `s` is shorter than `sep`); with two or three pieces the lengths and the separators add up to `s.length` |
| `s.startsWith(t)`, `s.endsWith(t)`, `s.includes(t)` | one uninterpreted function each of the two strings, so the same call has the same answer in the body and in a contract (also inside a quantifier body). For well-formed strings: true implies `s.length >= t.length`; an empty `t` or `t == s` gives true; true with equal lengths implies `s == t`; `startsWith` / `endsWith` imply `includes` |
| string literals | the bytes of a literal of at most 16 bytes are facts about `charCodeAt` (a literal's id stands for its contents, and distinct literals have distinct ids), so `"E0412".charCodeAt(0) == 69` and a precondition such as `c.length == 5 && c.charCodeAt(0) == 69` are provable on a literal argument |
| `s.indexOf(x)` | an empty `x` is found at 0; an `x` longer than `s` is not found; a position `p` has `p + x.length <= s.length` |

### Semantics (honest limits)

*Partial correctness.* Contracts are read over unbounded mathematical integers. Program arithmetic traps on overflow of
the type, division by zero, an index out of range and `unwrap` of `None`, and a trapping execution never returns, so on each
path the proof assumes the result of every arithmetic operation is in the range of its type, every divisor is non-zero, every
index is in range and every `unwrap` finds its variant. The last two are also **reported** (`bounds`, `unwrap`): the proof that
they cannot fail is a result of its own. A consequence: an `@Ensures` of a function that always traps (`return xs[xs.length]`)
is vacuously VERIFIED and its `bounds` result is REFUTED; read them together. Termination is not proved. VERIFIED therefore
means: for all inputs satisfying `@Requires`, if the function returns normally then the `@Ensures` holds and the class
invariants hold, assuming the callee contracts and the assumptions listed on the result.

*Contracts are total.* A clause that traps when evaluated (an index out of range inside a contract) is a failure: the goal of a
clause is "well defined and true". As a hypothesis (`@Requires`, a callee's `@Ensures`, an invariant) only its value is used.
Overflow inside a contract is ignored (unbounded integers).

### Statuses and abstraction

- **VERIFIED** is `unsat`. If the proof used a loop invariant, that invariant's own `loop-invariant` results (entry and
  preservation, also the inferred counter bounds) must all be VERIFIED; otherwise the result is UNKNOWN ("relies on a loop
  invariant that is not proved"). The assumptions it used are listed (below).
- **REFUTED** is `sat` with a counterexample that is real: the path to the clause used no abstraction. The counterexample lists
  the parameters (and `this`) at entry: scalars, string and array lengths with their first elements, record fields, `Option`
  / `Result` / union variants.
- **UNKNOWN** when the solver says `unknown` or times out (`--timeout-ms`, 2 s by default), the fragment does not cover the code (the
  reason names the construct), or the only `sat` models go through an abstraction: a loop without a sufficient invariant
  ("loop without invariant: i, s is unconstrained after the loop"), the size of a `Map`, derived string contents, or **the
  result of a call that is only known through its contract** (a pure function is an uninterpreted function, a mutating method
  returns a receiver that is only constrained by its `@Ensures` and frame: the real function computes one value, the model may
  pick another that the contract also allows). A counterexample there need not be a real execution, so it is not reported.
  The action is `STRENGTHEN_SPEC`. Not abstract, hence reportable: the arguments of a call (a violated `call-precondition`
  whose arguments come from the parameters), a `new C(..)` whose fields are all determined by parameter properties and
  initialisers.
- A false claim is usually still REFUTED: the verifier also unrolls every top-level loop 3 iterations *exactly* and tries
  the rest of the function from those states, and when the solver gives `unknown` on a satisfiable query it retries with every
  array shown in the counterexample bounded to length 3 and the quantified lemmas left out (a model found that way is a model
  of the original). Both only ever produce real counterexamples.

### Modular verification (B7)

Every value that is *read* (a field, an element, a payload, a match binding) gets the facts its type promises as an
assumption at the read: a `u8` is in 0..255, a length or a map size is not negative, the empty string is the only string of
length 0. (A datatype is free: it also contains negative lengths, so these are facts about values, never axioms over all
values.)

A call is replaced by the callee's contract: its `@Requires` (with well-definedness) is an obligation at the call site
(`call-precondition`, REFUTED = `FIX_CODE` for the caller), its `@Ensures` is assumed for the result under the `@Requires`
(and, for a public method, the class invariants of the receiver). A function the purity analysis (ADR-0031 A4) finds pure is an
uninterpreted function of its arguments (`uf_f`): two calls with equal arguments return equal values, and each call site gets the
instance `requires(args) ==> ensures(args, uf_f(args))` of its contract, so no quantifier is needed. Other functions return a
fresh value. Recursion assumes the function's own contract at the recursive call (partial correctness); this is the assumption
**A-CALL** on every result that went through a call. Functions, classes and types are keyed by the unit that declares them, and a name is resolved in the scope of the unit
it is written in (its own declarations and its imports, the way the checker binds them; `compiler/vc/scope.or`), so two units
may declare the same function or type name. Calls of a generic function, of a name the verifier cannot resolve (a built-in, or a name
bound more than once in one scope), or of a function whose signature is outside the fragment make the caller UNKNOWN.

### Recursive types

A record, class or union that reaches itself through its fields or payloads (`type Tree = { value: int; kids: Tree[] }`, a
scope with an `Option<Scope>` parent, `type Expr = Lit(int) | Add(Expr, Expr)`) has no finite SMT datatype. Its sort is
uninterpreted (`Rec_Tree`) and is described by what a datatype would say about the values that arise, minus
well-foundedness, without any quantified axiom:

- a record or class has an accessor function per field (`Rec_Tree.value`). A field read is the accessor. A value built in
  the code (a record literal, a field write, the receiver of a constructor, `this` after a loop that writes it) is a fresh
  constant whose accessors are stated as facts: the written field gets the new value, the others are carried over (value
  semantics, as for any record). The frame facts of a mutating method are equations between accessors.
- a union has a tag function (`Uni_Expr.tag`, the index of the variant) and payload accessors per variant (named as in a
  datatype, `Uni_Expr.Add.0`). The test for a variant is `tag = k`, so a value is of at most one variant; every value that
  is read or passed in has a tag in range (a well-formedness fact, like a length that is not negative). A variant built
  with a payload is a fresh constant with its tag and payload as facts; a nullary variant is a constant with its tag.
  `match` and variant construction work as for any union (nested patterns are still unsupported).
- inside a quantifier body (a function argument of `map`, `every` ..) a built value is the application of an uninterpreted
  function of its arguments, and its facts are stated inside the quantifier, per instance.

What this does not say: that values are finite (no induction over the structure; a recursive function is proved by its own
contract, A-CALL), and that two values with equal fields are equal (`==` on a record, class or union is unsupported anyway, so
nothing depends on it). Because the queries contain no quantifier for these types, the solver finds a model of a false
claim quickly instead of searching until the timeout. Every real execution is a model of these facts, so a VERIFIED result is as good as for other records. A
model of the solver need not be a real value (it may be cyclic), so **a function that uses a recursive type never gets a
counterexample**: a wrong claim is UNKNOWN ("the fields of the recursive type `X` are modelled by uninterpreted accessors (a
model need not be a finite value)"), never VERIFIED and never REFUTED. For the same reason such a function skips the
work that only looks for a counterexample: the bounded-search retry after `unknown`, the unrolled-loop pass and solving the
return paths one by one. The class invariants of a recursive class are assumed
and proved exactly where they are for other classes (A-INV, A-FRAME); the invariants of the type a field refers to are not
assumed for the field's value unless the field is read from a parameter or result for which they are assumed already.
Regression test: `tests/contracts/verify_rectypes.or`.

### Class invariants and frames (B8, B9)

For every public method that changes `this` (the mutation analysis of the checker, `Program.mutating`) and every constructor, the
verifier proves the class `@Invariant`s at every return, assuming them (and the `@Requires`) on entry: result kind `invariant`.
A method that can break an invariant is REFUTED with the values of `this` and the arguments, `action: NEEDS_DECISION`, and the
three options (fix the method, add a precondition, weaken the invariant). A private method has no invariant obligation (it may be
called in the middle of an update) and the invariant is not assumed on entry, unless every call of it proves it (next paragraph). Class-typed parameters are assumed to satisfy their
invariants (**A-INV**: constructors establish them, public methods maintain them; a write to a public field from outside the
class is not covered, and neither is it by the run-time check).

**Invariants in private methods.** A private helper often needs the invariant (the bound of an index, say), but it may be called in the
middle of an update, so assuming it on entry would be unsound. The verifier assumes it only for a helper whose calls all prove it:

1. A private instance method of a class with `@Invariant`s whose contracts are not all proved is a *candidate* when its name occurs in
   the class only as `.name(` besides its declaration. It is proved a second time with the invariants of `this` assumed on entry
   (A-INV). If that proves something the first run did not, the rest is checked; otherwise nothing changes.
2. At every call of the candidate in the class, the verifier proves the invariants of the receiver in the state at the call (a hidden
   obligation of kind `invariant-site`: not reported, not assumed afterwards, so a call at a broken state does not stop the path). The
   candidate is *eligible* only if every occurrence of its name in the class text is such a call that the verifier saw and proved. A
   mention that is not a call it analysed (in a contract, in a field initialiser, a call in a function outside the fragment or in a
   position that is not translated) makes it not eligible: the helper keeps the results of the first run.
3. A call in a caller that itself assumes the invariants (an eligible helper) counts only while that caller stays eligible: the set of
   eligible helpers is the greatest set closed under this. The chain of calls starts in a public method (which assumes the invariants
   on entry) or a constructor (which has to prove them at the call), so by induction on the depth of the call stack every call
   of an eligible helper is made in a state where the invariants hold. A helper that nothing calls is never run and is eligible.
4. For an eligible helper, each result that was not VERIFIED is replaced by the result of the run with the invariants assumed (VERIFIED,
   or a counterexample that now is a real one: the entry state satisfies the invariants). A result that was VERIFIED stays; the helper's
   `@Ensures` is what callers assume as before.

A helper called in the middle of an update (`this.pos = this.xs.length; this.at();`) fails step 2 and is not eligible, so a wrong
claim cannot be proved through it. The cost is one more run of the candidates that fail, and, for those that gain a proof, of the
functions of the class that mention them (only the call-site obligations are solved there). Regression test:
`tests/contracts/verify_private_inv.or`. To make a helper depend on the invariant without this inference, state it as the helper's
`@Requires`: the callers must then prove it, and the verifier takes it as a precondition.

A method's **frame** is the set of fields its body writes (assignments to `this.f..`, mutating calls on `this.f`, the frames
of the `this` methods it calls, to a fixed point); no annotation. After a call of a mutating method the receiver is a fresh
value that equals the old one on every field outside the frame (**A-FRAME**, listed on the results that used it). A method the
analysis cannot read (a call it cannot resolve) has the whole object as its frame.

### Loops

- A user `@Invariant(e)` before `while` / `for` (syntax of ADR-0012; not checked at run time yet) is proved on entry and for one
  iteration (`loop-invariant` results), then assumed after the loop together with the negated condition.
- A counting loop `while (i < N)` (or `<=`) whose body only does `i += 1` once per iteration, with `N` not changed by the body,
  gets `i0 <= i <= max(i0, N)` for free; it is proved like a user invariant but not reported by itself.
- Otherwise what the loop assigns (variables, `this.f`, receivers of `push` / `pop` / `set` / `delete` / mutating methods)
  is havoc'd. When the clause depends on it the result is UNKNOWN: "loop without invariant: ... is unconstrained after the loop",
  `action: STRENGTHEN_SPEC`. In `for (const x of xs)` the element is `xs[i]` for the position `i` of the iteration. A body with `break` or `continue`
  gets no invariant and no exit condition.
- `for (const x of xs)` has no counter, so an `@Invariant` in front of it may use the pseudo-variable **`loopIndex`** (a `usize`,
  read-only, in scope only in the clauses of a `for .. of`; a variable of that name hides it: E0415). It is the position in `xs`
  of the iteration the invariant is about: `0` on entry, `i + 1` after the iteration at position `i`, `xs.length` after the loop.
  The invariant holds at the start of the iteration at position `loopIndex`, so it speaks about the elements before it
  (`range(0, loopIndex).every(j => xs[j] >= 0)`, `loopIndex > 0 ==> last == xs[loopIndex - 1]`). Inside the body the verifier
  assumes `0 <= i < xs.length` and `x == xs[i]` for the position `i` of that iteration (`xs` is the value evaluated before the
  loop). Like every loop invariant it is not a run-time check (rtcheck.or), and it is ignored with `break` / `continue`.
  A counter the program keeps itself needs no `loopIndex`: with `let k = 0` earlier in the same block and `k += 1` as the last
  statement of the body (nothing else writes `k`), the verifier adds the hidden invariant `k == loopIndex`, so an invariant may
  speak about `k` (`range(0, k).every(j => xs[j] != v)`). This is what sources use that an older compiler (the bootstrap seed)
  still has to compile: `loopIndex` is unresolved there.

### Quantifiers and sums (C11, C12)

`xs.every(x => P(x))` is `forall i. 0 <= i < xs.length ==> P(xs[i])`, `some` is `exists`; `range(a, b).every(i => P(i))` of
`std:seq` is `forall i. a <= i < b ==> P(i)`. Nested ranges state pairwise properties (sorted, no duplicates):

```
@Invariant(range(1, this.items.length).every(i => this.items[i - 1] <= this.items[i]))
@Invariant(range(0, this.ids.length).every(i => range(i + 1, this.ids.length).every(j => this.ids[i] != this.ids[j])))
```

`sum(xs)` and `sumBy(xs, f)` are the recursive sums `psum(d, n) = n <= 0 ? 0 : psum(d, n - 1) + F(d[n - 1])` (one definition per distinct summand)
with the lemma `psum(store(d, i, v), n) = psum(d, n) + (0 <= i < n ? F(v) - F(d[i]) : 0)`, a theorem of the definition by
induction on `n` (it is what lets the solver prove that a transfer between two balances keeps the total without an induction
of its own):

```
@Ensures(sum(this.balances) == old(sum(this.balances)))
@Invariant(this.total == sumBy(this.items, it => it.price * it.qty))
```

The runtime meaning is the code of `library/std/seq.or` (`range` builds the index array, `sum` / `sumBy` are loops): under
`--check-contracts` the same clauses are executed. Unsupported: a lambda with a block body, a quantifier or sum inside a
quantifier body, `reduce`.

### Strings (B6)

A string is a pair (length, id): the id stands for the contents, and two strings with the same length and id are equal. The empty
string is the only string of length 0. `length`, `+` (length adds), literals (distinct literals have distinct ids), `==` between
variables and literals are exact. The operations on contents (`charCodeAt`, `substring`, `charAt`, `trim`, `startsWith`,
`toString`, a template literal, `==` with a computed string) are uninterpreted functions of the ids: they give no facts about the
contents, so a proof that needs them is UNKNOWN, and a counterexample that depends on them is not reported (a `charCodeAt` value
in a path condition or goal counts: the contents are not known, think of a table literal). `charCodeAt` is a byte, 0..255. A REFUTED
claim about strings is only given when it and its path use lengths, `+` and the bounds of `charCodeAt` / `substring`, not
contents. The Z3 string theory is not used: it is undecidable together with the length arithmetic and quantifiers.

### Counterexamples

`x = 5`, `xs.length = 2`, `xs[0] = 5`, `p.x = -1`, `o.isSome() = false`, `s is Rect = true`, `s.Rect.0 = 1`, `this.balance = 0`:
the values of the parameters and of `this` at entry, one line each, elements only below the length. The text report prints
the call `f(x = 5, ..)` in the question and a `candidate` precondition that excludes exactly the counterexample (never
verified). A `call-precondition` counterexample is the caller's parameters at entry.

### Assumptions (ADR-0020 D1)

Every VERIFIED result carries its assumptions (`assumptions` in JSON, listed once at the end of the text report):

| Id | Assumption | On a result when |
|---|---|---|
| A-INT | arithmetic results and conversions are in range on returning paths (a trap never returns); inside contracts integers are unbounded | always |
| A-DIV | no division or remainder by zero on returning paths | always |
| A-PARTIAL | termination is not proved | always |
| A-CALL | the contracts of called functions hold; a recursive call assumes its own contract | the proof went through a call |
| A-PURE | a function the purity analysis finds pure is a deterministic function of its arguments | an uninterpreted function was used |
| A-INV | class invariants hold on entry to a public method and for class-typed parameters and results; record invariants (ADR-0031 A3: such a value cannot exist) hold for record-typed parameters and results | an invariant was assumed |
| A-FRAME | a method writes only the fields its body writes; others keep their value | a frame fact was used |
| A-LOOP | the loop invariants used hold (each is proved) | the function has a loop |
| A-STR | strings are modelled by length (and an id for the contents); content operations are uninterpreted; `charCodeAt` is a byte in 0..255 (the runtime reads an unsigned char) | a string operation was used |
| A-MAP | the size of a `Map` is axiomatised, not computed from its keys | `size`, `keys` or `values` was used |

The soundness reasoning for each encoding choice (datatypes are free so well-formedness is stated about values, not as axioms;
why a `sat` model through an abstraction is not a counterexample; why the lemma about sums is valid) is in ADR-0036 and in the
header comments of `compiler/vc/*.or`.

## Contract quality (ADR-0028)

A contract that cannot fail catches no bug. The compiler reports weak or meaningless contracts as
**warnings** (never an error, never a changed exit status; `warning[W....]` in text, `"severity":"warning"` in
JSON, severity 2 in the LSP). All carry the action `STRENGTHEN_SPEC` (ADR-0029) in JSON.

Syntactic, always on in `orin check` / `compile` / `test` / LSP (`compiler/check/quality.or`):

| Code | Condition |
|---|---|
| W0450 | `@Invariant` of a class or record type that contains no `this` (so no field): it constrains no state |
| W0451 | `@Ensures` that does not mention `result` and, in a non-static method, `this`. Parameters are immutable, so such a clause only restates the input (move it to `@Requires`) |
| W0452 | a contract expression (also loop invariants) that is trivially true: `true`, `x == x`, `x <= x`, `x >= x`, `a.length >= 0`, `s.length >= 0`, `m.size >= 0`, a comparison of two literals that holds; also a trivially true conjunct of `&&`, consequent of `==>` or side of `\|\|` |

`x == x` is only reported when the operand has a declared non-float scalar or string type (it is a NaN test for
floats), and `.length` / `.size` only when the receiver is a parameter, `this` field or `result` of a declared
array, string or `Map` type; where the type is not known the pass is silent.

In `orin verify --contracts` (only for what the solver fragment supports; otherwise nothing is reported). The
`warnings` array of the JSON report and the `warning[...]` lines of the text report; each has `status`
`VERIFIED` (the finding is proved), `kind` and `action`:

| Code | Finding |
|---|---|
| W0460 | the clause is valid without any premise (parameters in the i64 range only): a tautology |
| W0461 | the `@Requires` clauses of a function are unsatisfiable: it can never be called |
| W0462 | an `@Ensures` follows from the `@Requires` alone, for every possible result: the body cannot violate it |

Strict contract coverage (opt-in: `--strict-contracts` or `[contracts] strict = true` in `orin.toml`; the
compiler itself does not use it yet): W0470 class with state (a field) and no `@Invariant`; W0471 public,
non-static method that mutates `this` and has no `@Ensures`.

**Contract strength:** `python3 tools/contract_mutation.py FILE.or` mutates the function bodies (operators,
literals, dropped statements), runs the `@Test` functions with contract checking and reports per function how
many mutants were killed by a contract or a test and which survived (see `examples/contract_mutation.or`).
A survivor means the contracts and tests do not notice the changed behaviour (or the mutant is equivalent).
Honest limits: a strong contract is still not proof that the specification is the right one.

## Refusal protocol fields of `orin verify --contracts` (ADR-0029)

Every JSON result also has `action` (`FIX_CODE`, `STRENGTHEN_SPEC`, `NEEDS_DECISION`, or `null` for `VERIFIED`),
`question` (string or `null`), `options` (list of `{"edit","changes_spec","widens_authority"}`), `candidates`
(suggested contracts, never verified) and `evidence` (`clause`, `location`, `counterexample`). The text report
prints `action:`, `question:`, `option N:` and `candidate:` lines.

| Result | `action` |
|---|---|
| REFUTED `call-precondition` | `FIX_CODE` (the caller passes an argument the callee forbids) |
| REFUTED contract of the function itself | `NEEDS_DECISION`: question plus options (fix the body; add the precondition that excludes the counterexample, `changes_spec`; weaken the contract, `changes_spec` and `widens_authority`) |
| UNKNOWN | `STRENGTHEN_SPEC` with the `reason`; no candidates (the solver gives no counterexample) |

An agent facing `NEEDS_DECISION` or `NEEDS_AUTHORITY` must ask the user the question with its options and must
not weaken contracts, add assumptions or widen grants to make a result pass.

## Known limitations

- `@Decreases` is only type-checked (termination is not proved). A loop `@Invariant` is type-checked and used by
  `orin verify --contracts` (proved before it is trusted), but not checked at run time yet (ADR-0036, open question 1).
- Contract-internal calls are unchecked only one level deep: the body of a function called from a clause is
  ordinary checked code (a recursive function with a contract that calls itself in its clause costs time
  quadratic in the depth, not an endless recursion).
- Loop clauses inside closure bodies are not part of the purity pass.
- `@Invariant` on a generic record is rejected (E0408).
- `--check-contracts` needs `exit` from `std:process`; a module that declares its own `exit` clashes.
- The editor grammar (`editors/vscode`) does not highlight clauses yet.
