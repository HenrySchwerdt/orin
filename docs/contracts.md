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

## Contract expressions (checker: `compiler/check/{contracts,purity}.or`, `body.or`)

Every build type-checks all clauses (in a forked function context, then discards the result: nothing
reaches the generated code). Scope: parameters; `this` (methods, class invariants in the constructor,
record invariants); `result` (only in `@Ensures`, typed as the source return type; absent in `void`
functions) and `old(e)` (only in `@Ensures`, not nested); `a ==> b` (right associative, weaker than
`?:`, short-circuit, `!a || b`). For loop clauses the scope is the surrounding scope at the loop.
`@Decreases` takes an `int` or `usize` measure.

| Code | Meaning |
|---|---|
| E0414 | clause is not `bool` (`@Decreases`: not integer) |
| E0415 | `old` outside `@Ensures` / nested, `==>` outside a contract, `?` in a contract, parameter called `result` hiding it |
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

E0416 names the impure operation and where it is: `call is not provably pure: `f` -> `g` performs I/O
(console.log) at file.or:12:3; contract expressions may only call pure functions` (the chain of calls from the
contract to the operation), or `I/O built-in `console.log` is not allowed in a contract expression`, or `function
value passed to `every` in a contract expression is not a closure literal, so its effects are unknown`.

Not supported in a clause: `result`, `this` and `old(..)` inside a closure with a *block* body (an expression
body works); the run-time rewriting does not descend into blocks.

## Erasure

Without flags the clauses produce no code. `tools/test_contract_erasure.py` (CI) compiles programs
with and without their clause lines and requires byte-identical C and LLVM IR. (Known corner: a
contract that is the only user of a generic instantiation leaves that instance in the output.)

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

## `orin verify --contracts [--format=json] [--z3 PATH] [--strict] entry.or` (phase 2)

Generates verification conditions and discharges them with z3 (`z3 -in`, SMT-LIB 2; install with
`pip install z3-solver` or your package manager). Query files are kept in `build/contracts-vc/`.
Per clause the result is **VERIFIED** (solver `unsat`), **REFUTED** (`sat`, with a counterexample for
the parameters) or **UNKNOWN** (with a reason; never upgraded to VERIFIED). Exit status 1 if any clause is REFUTED (or, with
`--strict`, UNKNOWN).

Reported clauses: every `@Ensures`, the `@Requires` of every called function at each call site
(`call-precondition`), and `@Decreases` (always UNKNOWN: termination is not checked). `@Rule` ids are
attached to the results as `rules`. JSON: `{"results":[{"function","file","line","kind","clause",
"rules","status","reason","counterexample","assumptions"}],"assumptions":[{"id","text"}],
"summary":{"verified","refuted","unknown"}}`.

Every VERIFIED result names the model assumptions it depends on (ADR-0020 D1), listed once per
report and referenced by id from each result: `A-INT` (no i64 overflow on returning paths),
`A-DIV` (no division/remainder by zero on returning paths), `A-PARTIAL` (termination not proved).
The text output prints the same list after the results.

Supported fragment: functions whose parameters and result are `int` or `bool`; body of `const`/`let`
of such types, assignments and `+=` etc. to locals, `if`/`else`, `return`, blocks; expressions over
literals, locals, `+ - * / %`, comparisons, `&& || !`, `?:` and calls of named functions of the same
fragment (modular: callee `@Requires` are obligations, callee `@Ensures` are assumed, so recursion
works). Anything else (loops, strings, arrays, records, classes, I/O, `usize`, generics) makes that
function's clauses UNKNOWN with the reason; nothing is silently skipped except functions without
any clause.

Semantics (honest limits): *partial correctness*. Contracts are read over unbounded mathematical
integers. Program arithmetic traps on i64 overflow and division by zero, and a trapping execution
never returns, so on each path the proof assumes the result of every arithmetic operation is in the
i64 range and every divisor is non-zero (`/` and `%` truncate toward zero as in Orin). Termination
and loop invariants are not proved (loops are outside the fragment). VERIFIED therefore means: for
all inputs satisfying `@Requires`, if the function returns normally then the `@Ensures` holds,
assuming the callee contracts hold.

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

- Loop invariants / `@Decreases` are only type-checked.
- Contract-internal calls are unchecked only one level deep: the body of a function called from a clause is
  ordinary checked code (a recursive function with a contract that calls itself in its clause costs time
  quadratic in the depth, not an endless recursion).
- Loop clauses inside closure bodies are not part of the purity pass.
- `@Invariant` on a generic record is rejected (E0408).
- `--check-contracts` needs `exit` from `std:process`; a module that declares its own `exit` clashes.
- The editor grammar (`editors/vscode`) does not highlight clauses yet.
