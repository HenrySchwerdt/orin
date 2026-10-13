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

### Purity rule (v1, conservative)

A contract expression may contain only: arithmetic, comparisons, logic, conditionals, `match`,
construction of records / variants / arrays, built-in string / array / int / Option / Result methods,
field access and indexing, and calls of **pure** functions. It must not contain closures, `?`,
mutating built-ins (`push`, `pop`), calls that mutate their receiver (mutating class methods), calls
through function values, or I/O built-ins (`console.log/error`, `readFile`, `writeFile`, `exists`,
`args`, `exit`, `readBytes`, `readLine`, `writeStdout`, `shell`).

A user function is *pure* if neither it nor any function reachable from it through calls or closure
creation performs I/O or calls a function value. Changing the function's own locals or arrays is not
an effect (value semantics; Orin has no mutable globals). Recursion is allowed. The analysis is over
the typed HIR after all functions are checked. Traps (division by zero, `unwrap` of `None`, index out
of range) and non-termination are not effects here.

## Erasure

Without flags the clauses produce no code. `tools/test_contract_erasure.py` (CI) compiles programs
with and without their clause lines and requires byte-identical C and LLVM IR. (Known corner: a
contract that is the only user of a generic instantiation leaves that instance in the output.)

## Runtime checking: `orin compile --check-contracts`

`compiler/check/rtcheck.or` expands the type-checked program and checks it again:

- a function / method with `@Requires` or `@Ensures` becomes a wrapper with the original name around
  the original body (renamed `$contract$body$<name>`): entry checks, call, exit checks, return. Every
  return of the body, including early `?` returns, is therefore checked; recursive calls go through
  the wrapper;
- `old(e)` is `e` for functions (parameters are immutable); in methods it is evaluated over a snapshot
  `old$this` of the receiver taken at entry;
- class `@Invariant`s are checked at the end of constructors and after every non-private, non-static
  method; constructor `@Requires` run after the leading `this.f = e;` initialisations;
- a violation prints `trap: contract violated: @Requires(x > 0) at file.or:LINE` on stderr and exits
  with status 101 (same convention as other traps).

Not checked at run time (still type-checked): record-type invariants, loop invariants, `@Decreases`.
The test runner understands `// flags: --check-contracts` and `// stderr: text` headers
(`tools/run_tests.py`).

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

- Loop invariants / `@Decreases` and record invariants are only type-checked.
- Loop clauses inside closure bodies are not part of the purity pass.
- `@Invariant` on a generic record is rejected (E0408).
- `--check-contracts` needs `exit` from `std:process`; a module that declares its own `exit` clashes.
- The editor grammar (`editors/vscode`) does not highlight clauses yet.
