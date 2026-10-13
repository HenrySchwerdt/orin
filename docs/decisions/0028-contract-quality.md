# ADR-0028: Contract quality diagnostics and a contract-strength tool

Status: accepted (2026-10-13). Related: ADR-0012 (contract clauses), ADR-0020 D1/D7 (statuses, assurance
levels), ADR-0024 (warnings, W0440), ADR-0029 (refusal protocol: these warnings carry the action
`STRENGTHEN_SPEC`).

## Context

Orin's point is verifiable software, and a contract is only worth something if it can fail. Today the
compiler accepts `@Ensures(true)`, an `@Invariant` that talks about no field, or an `@Ensures` that only
restates the parameters, and counts them as contracts. `VERIFIED` on such a clause is true and useless.
The compiler never warned about weak or meaningless contracts, and there was no way to ask the dual
question "would my contracts and tests notice a bug?".

## Decision

### 1. Warning codes

Warnings are ordinary `Diagnostic`s whose code starts with `W` (`diag.isValidCode` accepts `W` + four
digits; ADR-0024). They never change the exit status. Range: **W0450-W0479 contract quality** (W045x
syntactic, W046x solver-based, W047x strict coverage).

| Code | Where | Condition |
|---|---|---|
| W0450 | `check`, `compile`, `test`, LSP | `@Invariant` of a class or record type whose expression contains no `this` |
| W0451 | same | `@Ensures` of a function or method that does not mention `result` and, for a non-static method, does not mention `this` |
| W0452 | same | a contract expression that is syntactically trivially true |
| W0460 | `verify --contracts` | clause valid with no premises (solver) |
| W0461 | `verify --contracts` | the `@Requires` of a function are unsatisfiable (solver) |
| W0462 | `verify --contracts` | an `@Ensures` implied by the `@Requires` alone, for every result (solver) |
| W0470 | strict mode | class with state and no `@Invariant` |
| W0471 | strict mode | public non-static method that mutates `this` and has no `@Ensures` |

### 2. Syntactic warnings (`compiler/check/quality.or`)

Pure AST analysis, always on, cheap (no type check, no index). Std and prelude units (`$`-prefixed) are
skipped. Source order, units in loader order: deterministic.

* **W0450.** The expression of a class `@Invariant` or record-type `@Invariant` contains no occurrence of
  `this`. (A bare `this` passed to a helper, `@Invariant(wellFormed(this))`, counts as a mention; a call of a
  helper on constants does not.) Loop invariants are not covered.
* **W0451.** Orin parameters are immutable (value semantics), so the only things a function can change
  that a postcondition can observe are its result and, for a non-static method, `this`. An `@Ensures` is
  flagged when its expression mentions neither the name `result` nor (non-static methods only) `this`. So:
  functions and static methods: flagged unless `result` occurs (a `void` function therefore always flags);
  `old(e)` does not count by itself (`old(x)` of a parameter is `x`); methods: `this.f` or `result` makes it
  observing. Expression forms the walk cannot see into (match arms with block bodies, closures) count as a
  mention, i.e. no warning.
* **W0452.** Per clause expression of every `@Requires`, `@Ensures`, `@Invariant` (loop invariants too),
  the first trivially true part is reported: the whole expression, a conjunct of `&&`, the whole of
  `a ==> T` and of `a || T` / `T || a`. Trivially true atoms: literal `true`; `x == x`, `x <= x`, `x >= x`
  for structurally equal simple operands (identifier, `this`, member chain, literal) of a **known non-float
  scalar or string type**; `E.length >= 0` (or `0 <= E.length`) for `E` of declared array or string type;
  `E.size >= 0` for `E` of declared `Map` type; a comparison of two integer literals that holds (`1 < 2`).
  "Known type" means the declared type of a parameter, a field of `this`, or the declared result. Where the
  type is unknown nothing is reported: `x == x` is false for a NaN `float` (the idiom for a NaN test), and a
  record may have an ordinary integer field called `length`.

### 3. Solver-based warnings (`compiler/vc/vc.or`)

Run in `orin verify --contracts` for functions inside the supported pure int / bool fragment (ADR-0012
phase 2). They concern the clauses only, not the body, so a function with a loop is still analysed when
its clauses translate. A clause outside the fragment is skipped **silently**; a warning is issued only
with a solver proof (`unsat`). `sat`, `unknown`, timeouts and a missing solver produce no warning.

* **W0460 tautology.** `@Requires`: the clause is valid assuming only that parameters are in the i64 range.
  `@Ensures`: valid with `result` unconstrained (in range). Clauses that are already W0452 are not repeated.
* **W0461 unsatisfiable `@Requires`.** The conjunction of the clauses and the parameter ranges is unsat:
  the function can never be called and every `@Ensures` holds vacuously. Reported once, at the first
  `@Requires`; the other solver checks of that function are skipped.
* **W0462 implied `@Ensures`.** With `result` a fresh unconstrained value, the clause follows from the
  `@Requires` alone (and is not a tautology): whatever the body returns, the clause holds, so it cannot
  catch a bug in the body. (This covers clauses that do not mention `result` and clauses that mention it
  but hold for every value.)

Report format: the JSON report gains `"warnings":[{"code","function","file","line","kind","clause",
"message","status","assumptions","action"}]` (`kind` is `tautology`, `unsatisfiable-requires`,
`implied-ensures`); `status` is the status of the *finding* (`VERIFIED`: the vacuity is proved, ADR-0020 D1)
and `action` is `STRENGTHEN_SPEC`. The text report prints `warning[W046x]` lines before the summary.
The warnings do not count as results (`summary` and the exit status are unchanged). With
`--format=json`, the syntactic warnings of `check` go to stderr as text, so stdout stays one JSON document.

### 4. Strict coverage mode (opt-in)

`--strict-contracts` on the command line (`check`, `compile`, `verify`, ...) or `[contracts] strict = true`
in `orin.toml` (the only new manifest key; default `false`; LSP and `orin test` honour the manifest key,
not the flag). Adds:

* **W0470**: a class that has at least one field (declared or a `public`/`private` constructor parameter)
  and no `@Invariant`, reported at the class name.
* **W0471**: a public (not `private`), non-static method that mutates `this` and has no `@Ensures`,
  reported at the method name. Mutation is detected syntactically: an assignment to a place rooted at
  `this`, `push`/`pop`/`set`/`delete`/`clear`/`remove`/`add`/`insert` on such a place, or a call of another
  mutating method of the same class (a fixpoint over the class). Mutation through other paths is missed;
  the warning can be absent but is never reported for a method without such a construct.

Not enabled for the compiler itself yet (planned gate, roadmap step 2).

### 5. Contract-strength tool (`tools/contract_mutation.py`)

Source-level mutation: for the bodies of the functions and methods of a `.or` file (not `@Test`, not `main`,
not constructors) apply one mutation per mutant: `+`/`-`, `<`/`<=`, `>`/`>=`, `==`/`!=`, `&&`/`||`,
integer literal +1 / -1, drop a single-line assignment or call statement. Each mutant is built and run with
`orin test` (runtime contract checking on). A mutant is **killed** when a contract fires or a test fails
(trap, non-zero exit, timeout), **survived** when everything passes, **invalid** when it does not compile
(excluded). The report is per function (`killed/total`, killed by contract vs by test, survivors with
line and column) in text and JSON; `--max-mutants` samples round-robin over the functions with a fixed
seed, mutants run in parallel, `--min-kill-rate` makes the exit status fail below a rate (used by the CI
smoke test on `examples/contract_mutation.or`).

### 6. Honest limits

* The syntactic pass sees no types beyond declarations (hence the silent cases above) and cannot judge
  whether a non-trivial clause is *meaningful*; `@Ensures(result >= 0)` on `abs` passes all checks.
* The solver warnings exist only for the supported int / bool fragment (ADR-0012); everywhere else the
  absence of a warning means nothing. They assume contracts are read over unbounded integers with
  parameters in the i64 range, like the verifier.
* A strong contract is still not a proof that the specification is the right one. Quality warnings find
  vacuous or weak clauses; they cannot find a wrong one.
* Mutation testing is a heuristic: surviving mutants include equivalent ones (`<` to `<=` where the operands
  are never equal) and the tool cannot separate them; mutations are textual and assume formatter-canonical
  code (operators with spaces).

## Consequences

* Weak contracts become visible in every build; the compiler's own source currently triggers none of the
  non-strict warnings.
* `Manifest` gains the field `strictContracts`; `verify --contracts` JSON gains `warnings` (and the ADR-0029
  fields); the test runner understands `// warns: W0450 ...` headers.
* Planned (roadmap step 2): a compiler contract gate (strict mode, minimum kill rate, no regression of
  `VERIFIED` contracts).
