# Compiler rewrite process (ADR-0015)

How a module of `compiler/` is rewritten with the full language and contract clauses, as it was
actually done for the first two modules (`compiler/diag/`, `compiler/loader/`, the trial run). The
next modules (check, lower / opt / verify, backends, tooling: step 3e below) follow the same checklist.

The rules are in [ADR-0015](decisions/0015-compiler-modernisation-and-contract-dogfooding.md): one
module per PR, **behaviour-preserving**, no new language features, contracts for real invariants,
performance measured. The seed (`seed/`, `tools/bootstrap.sh`) understands the whole language, so
the compiler source is not restricted to Orin-B any more.

## Checklist per module

1. **Baseline first.** Before touching the module: `./tools/bootstrap.sh`, then keep copies outside
   the worktree: `cp build/bootstrap/orin2 $S/orin2_base`, `cp -r compiler $S/base/compiler`,
   `cp build/bootstrap/stage2.c $S/stage2_base.c`. These are the reference for every comparison below.
   (Do not edit `compiler/` while `bootstrap.sh` runs: stages 2 and 3 re-read the sources.)
2. **Read the callers** (`grep -rn 'from "../<module>"' compiler`): the exported surface (the module's
   `module.or`) is what the rest of the compiler sees. Keep it stable; additions are free.
3. **Rewrite in small steps** and compile after each with the baseline compiler:
   `$S/orin2_base compile compiler/main.or -o $S/n.c` (about 4 s, type-checks everything). The
   baseline compiler is enough while the module only uses features it knows; the seed has the same
   front end.
4. **Fast unit tests** while rewriting: `orin test compiler/tests/<module>_test.or --runtime runtime/core`
   (needs no bootstrap). The tests are `@Test` functions (ADR-0024); `orin test` runs with runtime
   contract checking, so the contracts of the module are exercised by every test. Write the tests
   against the *old* code first (copy the test into `$S/base/compiler/tests/` and run it with
   `$S/orin2_base`): a test that passes on both is a behaviour specification, a test that fails on the
   old code is a wrong expectation (this caught one wrong test of ours).
5. **State contracts** (below), run the contract build (below).
6. **`orin fmt`** every file of the module (`orin2 fmt compiler/<module>/*.or`); the formatter is
   canonical and rewrites comment layout, so run it before the final commit, not at the end of the
   day.
7. **Fixed point:** `./tools/bootstrap.sh` (seed -> orin0 -> orin1 -> orin2 -> stage3; `stage2.c ==
   stage3.c`) and its conformance run. The seed has to compile the new source: nothing may use a
   feature that is newer than the seed.
8. **Behaviour preservation** (next section), **OSIG diff**, **performance**, then `./tools/ci_local.sh`.
9. Commit `WIP:` checkpoints at milestones, a final commit after the full CI.

## Checking behaviour preservation

Diagnostics are the contract of the front end, so compare them byte for byte instead of trusting the
suites (the error tests only check the code and the line):

```
tools/differential.sh compilers $S/orin2_base build/bootstrap/orin2
```

`tools/differential.sh compilers` runs both compilers over every input of `tests/{errors,next/errors,parse_edge,run,next/run,
contracts}`, all package test directories and `compiler/main.or` itself, in three modes (`compile X -o
/dev/null`, `check X`, `check --format=json X`), and compares exit status, stdout and stderr. For
`loader` + `diag`: 1304 inputs x 3 modes, 0 differences.

Also:

* `stage2.c == stage3.c` (bootstrap) and **`stage2.c` of the rewrite compared to the baseline's** is
  *not* expected to be equal: the compiler's own code changed. What must be equal is the output of the
  new compiler and the old compiler on the same input: `cmp $S/orin2_base ... compile compiler/main.or`
  with both on the new tree gives identical C (checked: 5,438,653 bytes both).
* `tools/ci_local.sh` (suites with sanitizers and with the LLVM backend, `verify_all`, diff modes,
  formatter, tooling, LSP, MCP, OSIG).
* `orin diff --base <old compiler/main.or> --head <new compiler/main.or>`: expect only changed
  internals of the module, no changed exported signature (additions are fine); other modules appear
  only as changed call paths that now reach new functions.

## Contracts: what worked and what to avoid

Contracts are checked at run time only in a `--check-contracts` build
(`tools/test_compiler_contracts.sh`, CI job `contracts`): `orin2 compile compiler/main.or
--check-contracts`, cc, then (1) the contract-checked compiler self-compiles `compiler/main.or` and
the output must be byte-identical to `stage2.c`, (2) all conformance suites run with it as the
compiler under test (`--quick` limits it to the default suite). Every compilation of every test
then executes the module's contracts on real inputs.

Rules learned:

* Clauses must be **pure**. Since ADR-0031 A4 the purity analysis is inferred over the call graph: a helper may
  use `every` / `some` / `map` / `filter` with a pure lambda (a lambda that calls an impure function, or a
  function value of unknown origin, is still E0416). *Historical* (steps 1-2a): before that a helper used in a
  contract had to be written with loops (`isWellFormed`, `importCount`, `isNormalized`, `segments`,
  `allRenderable`); those that were not touched since are still loops.
* A function may call itself from its own contract (`@Ensures(f(result) == result)`): since ADR-0031 A5 a call
  inside a clause goes to the unchecked body, so it terminates. (Before, with `--check-contracts` the recursive
  call went through the wrapper and never terminated, hence the advice "state the property structurally".)
* Record `@Invariant`s are enforced under `--check-contracts` at every literal, field write and function result
  (ADR-0031 A3, docs/contracts.md); the same property is still also an `@Requires` / `@Ensures` of the functions
  that build the value (`span`, `spanTo`) where that was written before. Class `@Invariant`s are enforced after
  every non-private method.
* Prefer a small exported predicate over a long clause (`isValidCode`, `isRenderable`,
  `isWellFormed`): it documents the invariant once and is reused in `@Requires` and `@Ensures`.
* A contract that cannot fail is noise. Ask "which bug would this catch?": a diagnostic whose span lies
  outside the source map (`isRenderable`), a unit that imports a *later* unit (cycle / order bug,
  `isWellFormed`), a non-normalized path that breaks the `Map` lookup of `Sources`.

Contracts of this step: see the table in the PR description / `compiler/diag/diag.or`,
`compiler/loader/{path,loader,program}.or` (`grep -n '@Requires\|@Ensures\|@Invariant'`). None fired
on the compiler's own sources, on the conformance suites or on the unit tests.

## Idioms used, and how to decide

| Old style | New style | Where |
|---|---|---|
| iterative DFS with parallel stacks (`sNode`, `sAst`, `sItem`, `sImps`) because every array had to be grown in a `let` local | recursive `visit` in a class (`Loader`), state in fields, `?` for errors | loader.or |
| overlay as `SourceFile[]` + linear `findIn` | `Sources` class with `Map<string, string>` (also the single place that touches the disk) | sources.or |
| node lookup by linear search in `nodePaths` | `Map<string, usize>` `done` + `stack.indexOf` | loader.or |
| `std: int` codes 0..4 for std modules | `Option<StdModule>` and a `match` on the import string | resolve.or |
| three parallel edge arrays | one `ModuleEdge[]` record array, projected with `map` when the package API wants parallel arrays | loader.or |
| `PkgCtx { on, m, src }` | `Option<Manifest>` + `srcRoot` | loader.or |
| `"a" + b + "c"` message building | template literals | everywhere |
| index loops that map / filter | `map`, `filter`, `reduce`, `slice`, `concat` | prelude.or, path.or, loader.or |
| two scans for line and column | one `lineCol` | diag.or |

Decide per construct: a **class** where several functions thread the same state (`Loader`,
`Sources`); a **record + functions** for plain data that crosses module boundaries (`Span`,
`Diagnostic`, `Unit`: they are built by literals in other modules and the contract is the
constructor function, not a type); **no interface** where there is no second implementation
(`Sources` has one; ADR-0021 may turn it into one when a grant is threaded through: all disk access
of the loader is in `sources.or`); **no generics** were needed in these two modules.

## Pitfalls found

* `from` is a keyword: a record field or variable called `from` is E0200 ("expected identifier").
* No array `const` at the top level ("top-level const initializer must be a literal"): use a
  function with `match` on the string.
* `slice(a, b)` takes both arguments.
* Preserve quirks on purpose, record them in a comment or test: `isInside("../..", "x")` is false
  because of the length check before the `..` rule; the first overlay entry for a path wins (a `Map`
  `set` would let the last one win); `relativeTo` of a path below a `..` base is lexical nonsense.
* `git` in a compound shell command is refused in a worktree-isolated session; run git commands alone.
* Do not use `pgrep -f <name>` in a monitor loop that itself contains `<name>`.

## Numbers (loader + diag)

Lines (`wc -l`, without the generated `embedded_*.or`): before 835, after 942 + 198 lines of new tests
(`compiler/tests/loader_test.or`). `loader.or` alone went from 518 to 248 lines; its logic now lives in
`loader.or` (class `Loader`), `resolve.or` (imports), `modules.or` (packages), `sources.or`, `program.or`
(types, `isWellFormed`). The growth is contracts and comments.

Selfcompile (`orin2 compile compiler/main.or`, 15 interleaved runs after one warm-up, wall time and peak
RSS via `tools/bench.py`'s `run_once`; the machine was shared, so the spread is large):

| | wall median (min-max) | peak RSS median |
|---|---|---|
| before (baseline compiler on the old tree) | 3.935 s (3.822-4.101) | 107.6 MiB |
| after (new compiler on the new tree) | 4.006 s (3.675-4.273), +1.8 %, inside the noise | 108.1 MiB, +0.5 % (the source is larger) |
| both compilers on the *same* (new) tree | 4.260 s vs 4.243 s (3.63-4.73 / 3.60-4.91) | 108.3 vs 108.1 MiB |

No regression: the loader is a tiny part of the time (parsing and checking dominate), and the Map-based
lookups replaced linear searches over a few dozen files. The contract-checked compiler is slower by
design and is not part of this comparison.

## Contract and class standard (from step 2a on)

The project owner's review of step 1 asked for clearly more invariants and more classes. From step 2a on every
rewritten module follows these rules (the contracts are checked by the `contracts` CI job, the unit tests run with
`orin test`, which checks them too):

1. **Every class has at least one meaningful `@Invariant`.** State that several functions thread through (a record
   plus free functions: tables with their indexes, parallel arrays, a scope stack) becomes a class with methods where
   that is a mechanical change, because a class `@Invariant` is checked after every non-private method (a record `@Invariant` is checked at
   every literal, field write and function result under `--check-contracts` since ADR-0031 A3, so a record is also
   fine when the property is a plain data rule). A class whose only job is to keep arrays in step (`Captures`,
   `TScope`) still earns its keep: the invariant is the point. Keep invariants O(1) or O(depth); a method that
   mutates may state the O(n) property in its `@Ensures` instead.
2. **Every exported or non-trivial function has `@Requires` / `@Ensures` that state a real property:** lookup after
   bind returns the bound value, `open` / `close` change the depth by one, an index found in a table is in range and
   points at what was asked for, an index map is as large as its array, a resolved type refers only to ids that exist,
   a parallel-array argument has equal lengths, `declare` does not shrink the tables. Trivial one-liners (`isInt`)
   need none.
3. **Well-formedness helpers**: a small exported predicate (no self-call) that is reused in `@Requires`, `@Ensures`
   and `@Invariant` (`marksOrdered`, `noRepeats`, `typeInRange`, `isWellFormedEnv`, `sigOk`, `bindsKept`), like
   `isWellFormed` of the loader. Since ADR-0031 A, purity inference accepts `every` / `some` / `map` / `filter` with a
   pure arrow function in a clause, so a helper may use them; a clause still cannot call a function *value*.
4. **Ask of each contract which bug it would catch.** Good: `typeEq(a, b) == (typeId(a) == typeId(b))` (the two
   notions of type identity cannot drift apart, which would corrupt the instance cache), `Insts.add` requires a fresh key
   *and* a fresh id, `bindsKept` (unification never unbinds), `declare` fails only when the name is already in the
   innermost scope. Not good: a clause that restates the body. When in doubt err on the side of more coverage; a clause
   that never fails on the compiler's own sources is still worth it when the property is a real design rule.
5. **Tests that would fail if an invariant were broken**: call sequences from outside (`open` / `bind` / `close` /
   `lookup`, instance add / find / origin) in `compiler/tests/<module>_test.or`.
6. **Do not state what the data does not guarantee.** A program with a duplicate type parameter is reported (E0304) but
   still reaches the resolver, so `TScope` must not require distinct names; the first draft did, and an error test would
   have trapped the contract-checked compiler. Run the error suites with the contract-checked compiler before you
   believe an invariant.
7. **Say what a loop computes** (project owner, 2026-10-14): a loop that is a transformation or a question about an
   array is written with the array API: `map`, `filter`, `find`, `findIndex`, `some`, `every`, `reduce`. Examples are
   collecting the names of the active items, finding the first match, or checking that all entries are in range. Keep a
   `for` loop where it is the clearer form: several results built in one pass, index arithmetic, early exit with
   state, or mutation of the iterated data. There is no `Stream<T>` type. Laziness comes from the compiler: closure
   inlining and fusion of pure `filter`/`map`/`reduce` chains into one loop (ADR-0038 §2, `compiler/fuse`). Fusion has
   landed for every shape the compiler uses (`map`/`filter` stages ending in `map`, `filter`, `reduce`, `some`, `every`,
   `find`, `findIndex`, `forEach`, `includes`, `indexOf`, with arrow functions or named functions at the call), so a hot
   loop of the compiler may be written as a chain too: `filter → map → reduce` over 5 M ints now runs at the speed of
   the loop (docs/benchmarks.md "Streams"). `orin compile --fuse-report` lists every chain and whether it became one
   loop; what is not fused (a function value that is not a literal, an impure closure, a result bound to a variable and
   used twice, `sort`) stays a call of the prelude function. The self-compile time in the PR shows whether a change
   slowed the compiler down.

8. **No global counters in per-function work** (project owner, 2026-10-14; ADR-0039 §6): a phase that works per
   function, such as checking a body, lowering, verifying or emitting code, numbers what it creates (temporaries,
   string literals, fresh names) locally. A program-wide numbering is assigned afterwards, in a fixed order. Then a
   phase can switch to `.parallel()` without changing its output, so the bootstrap fixed point keeps holding.
   Step 3d (below) applies it to the optimiser and both code generators.

## Step 2a: `check/{env,fnctx,types}.or` (the checker's foundation)

Rewritten: symbol tables, scope stack, type-instance caches. `body.or`, `decls.or`, `collect.or` only got the
mechanical call-site updates the new interfaces need (about 10 lines); `resources.or`, the `main` checks, `std:*`
loading and the I/O builtins were not touched (ADR-0021 Stage A work happens there).

| Old | New |
|---|---|
| `Names { types: TypeBind[]; vals: ValBind[] }`, `findType` / `findVal` linear scans | class `Names` over two `Map`s |
| `findInst`, `originOf`: linear scan of `Env.insts` per call | class `Insts` with two `Map` indexes (keys `kind:gid:typeIds`, `kind:id`) maintained by `add`; `typeId` is a structural key (ids, not names) |
| `Env.bounds: OpaqueBound[]` + `boundOf` scan; `TScope` record | `Env.bounds: Map<usize, usize>`, `addBound`; `TScope` class |
| `FnCtx.names / ids / marks` flat stack with linear `lookupLocal`; `capNames / capTys / capIds` parallel arrays | classes `Scope` (`Map<string, Bind>` + undo log + marks, `FnCtx.scope`) and `Captures` (`FnCtx.caps`); `open` / `close` / `bind` / `lookup` / `inInnermost` |
| two 30-field `FnCtx { .. }` literals full of `noX` consts | `blankCtx` + the two constructors set only what differs (empty array / `None` literals infer from the field type) |
| string `+` building, index loops | template literals, `map` / `join` / `filter` / `indexOf` / `includes` |
| `dedupDiags` O(n^2) with `diagEq` | one pass with a `Map` of diagnostic keys (`diagEq` removed, it had no other user) |

Classes (0 before, 5 now): `Names` (the per-unit name tables; `bound == types.size + vals.size`, so a silent
overwrite shows), `Insts` (the instance table with its two indexes; both stay as large as the list; `add` requires a
fresh key and a fresh record / union / function id), `Scope` (scope stack over a `Map` with an undo log; marks ordered
and inside the log, `vis.size <= log.length`), `Captures` (the three parallel arrays of an arrow function's captures:
equal lengths, names and ids distinct), `TScope` (the resolver's type-parameter scope: names and types in step).
`Env.insts` is an `Insts`, `FnCtx.scope` a `Scope`, `FnCtx.caps` a `Captures`; the call sites that changed are
`withEnv` (`insts.size()`), the closure lowering (`inner.caps.names`), the three `TScope` literals of `body.or` and the
two `Names` binds of `collect.or`.

Contracts: 110 clauses in the three files (0 before): `env.or` 45, `fnctx.or` 36, `types.or` 29. None fired on the
compiler's own sources, the conformance suites or the unit tests (see the numbers in the final report of the step).
Highlights: every resolution function (`resolveTy`, `resolveType`, `aliasType`, `instType`, `resolveSig`, `instFunc`)
ensures `resolvedOk` / `sigOk` / `funcOutOk` (types refer only to ids that exist, ids returned are inside their tables,
`isWellFormedEnv`), `instType` also ensures that the instance it returns is registered under the generic it was asked
for; `unify` requires `tp.length == binds.length` and ensures `bindsKept`; `mkOpaque*` ensure the new record id and
the bound; `declare` / `newLocal` / `lookupVar` / `pushScope` / `popScope` state their effect on the locals, scope depth
and captures. ADR-0015 names "`substitute` leaves no type parameters": there is no `substitute` function in the checker
(a type expression is resolved against a `TScope` that maps parameter names to concrete types, so no parameter can
survive by construction); the dangling-id and instance-registration checks above are the corresponding properties of
the resolver.

Lessons:

* **The checker is not where the time goes.** gprof of `orin2 check compiler/main.or` (0.37 s of the 4 s
  self-compile): parsing / lexing dominate (`orin_struct_new`, `orin_destroy`, `orin_str_eq` from the lexer's keyword
  and operator tables), `findType` / `findInst` are below 1 %. The `Map` conversion is therefore design hygiene
  (O(1) lookups, one place that maintains the indexes), not a speed-up; measured: no change beyond noise. The big
  costs are copy-on-write copies of `Env` arrays and retain / release traffic from threading `Env` and `FnCtx` by
  value (177 M retains per self-compile), which only the later body.or / Env-as-class steps can reduce.
* A closure cannot mutate a captured local (`seen.set` inside `filter` does not work): dedup is a `for` loop.
* A contract helper must not use `map` either (it calls a function value, so it is impure): `typesId` is a loop
  because `instKey` is used in `addInst`'s `@Requires`.
* A `Map` / class inside the `Env` record is copy-on-write like the arrays: `e.insts.add(..)` on a local copy of
  `env` costs what `e.records.push(..)` did; no extra copies showed up (wall time within noise).
* The contract-checked self-compile is about 1.5x slower (6.1 s vs 4 s) with the 110 clauses; the O(n) properties are
  therefore stated only in mutating methods' `@Ensures`, and class invariants stay O(1).
* A class stored in a record field works with value semantics (`let f = fx; f.scope.open()` does not touch `fx`), which
  the closure snapshot `FnCtx.outer` needs.
* Keep the formatter off files you only touch mechanically (`collect.or`, `decls.or`): `orin fmt` reflows them
  completely (+300 lines of diff).
* `compiler/tests/check_env_test.or` tests `Scope`, the name tables, the type / instance keys and `dedupDiags`; for
  that `check/module.or` exports them (module boundary E0302).

## Step 2b: `check/body.or` (the expression and statement checker)

Rewritten: `check/body.or` (3,548 lines, about 190 functions that threaded `Env` and `FnCtx` through every call and
returned `{ fx, result }` records) and the record part of `check/fnctx.or`. `check/{checker,classfix,contracts,pattern}.or`
only got the call-site updates the new interfaces need (`checkBlock(fx, body)`, `checkClause(fx, c, cmode)`, `FnCtx`
methods instead of `newLocal(fx, ..)`; about 20 lines); `env.or` gained `Env.wrappers` and `emptyEnv()`.
`compiler/vc/` was not touched.

| Old | New |
|---|---|
| `body.or`: 3,548 lines, 190 functions, `(env, fx, args) -> Result<{ fx, x }, Diagnostic>` | `body.or` is a 18-line facade; the code lives in `expr.or`, `stmt.or`, `ops.or`, `match.or`, `call.or`, `lift.or`, `hirok.or` |
| `type FnCtx = { 30 fields }` plus free functions `newLocal`, `declare`, `pushScope`, `markBreak`, `lookupVar`, ... | class `FnCtx` (fnctx.or) with the same fields and the operations as methods; 13 invariants |
| every function threads `fx` in and out, `env` is passed beside it | `ExprChecker` owns the context: methods return the HIR (or a diagnostic) and leave what they learnt in `this.fx` |
| statements, blocks, `match` arms, loop clauses, `checkClause` | class `StmtChecker` (stmt.or), which owns an `ExprChecker`; its invariants say it closed every scope and loop it opened |
| `match` exhaustiveness: `covered: bool[]` and `wild` threaded through `checkArm` and an inline `missing` loop | class `Coverage` (match.or): flags, `absorb`, `missing`, `verdict`; the E0402 message is produced in one place |
| `inferPre`: `binds` and `outArgs` as two threaded arrays | class `Inference` (call.or): binding table, argument slots, `typeArgs` |
| `registerLifted` / `wrapFunc` / the tail of `checkArrow` | lift.or: `registerLifted`, `liftClosure`, `wrapperOf`; wrapper lookup by `Env.wrappers: Map<string, usize>` instead of a scan of `Env.funcs` |
| ~60 helpers mixed in between (literals, operator rules, diagnostics) | ops.or: pure functions with contracts (`binaryType`, `intLiteral`, `negBigLiteral`, `interpolated`, `fieldIndex`, `missingNames`, `pureH`, ...) |

Files (lines are `orin fmt` output, which spreads every call with more than a few arguments over several lines: the old
`body.or` is 4,461 lines in the same layout; clauses are the `@Requires` / `@Ensures` / `@Invariant` annotations):

| file | role | lines | requires | ensures | invariant |
|---|---|---|---|---|---|
| `fnctx.or` (was 457 lines, 36 clauses) | `Scope`, `Captures` (unchanged), `FnCtx`, `newFnCtx`, `newClosureCtx` | 533 | 10 | 44 | 13 |
| `ops.or` (new) | pure helpers and typing rules | 770 | 2 | 24 | 0 |
| `match.or` (new) | `Coverage`, `variantsOf` | 148 | 1 | 7 | 2 |
| `call.or` (new) | `Inference`, diagnostics of built-in calls | 178 | 4 | 8 | 1 |
| `lift.or` (new) | closure conversion | 168 | 3 | 12 | 0 |
| `hirok.or` (new) | HIR well-formedness predicates for contracts | 145 | 0 | 0 | 0 |
| `expr.or` (new) | `ExprChecker` (75 methods) | 3,160 | 5 | 50 | 1 |
| `stmt.or` (new) | `StmtChecker`, `StmtHost`, `checkBlock`, `checkClause` | 702 | 2 | 39 | 2 |
| `body.or` (was 3,548 lines, 5 clauses) | facade | 18 | 0 | 0 | 0 |
| total, before -> after | | 4,005 -> 5,822 | 41 -> 230 clauses | | |

Unit tests: `compiler/tests/check_body_test.or`, 38 `@Test`, 1,279 lines (and `check_env_test.or` of step 2a, which was not
run by CI, is now run by `tools/test_tooling.sh` together with it).

Classes (6 new, 11 in `check/` with those of 2a): `FnCtx` (the state of one function body: a scope is always open, every capture is a
local, `cmode` is one of four, a closure has its environment local, type parameters and bindings are parallel, a generic
instance is no deeper than `MAX_DEPTH`), `ExprChecker` (the environment it works on is well-formed), `StmtChecker`
(`scope.depth() == base + open` and `loops.length == loopBase + loops`: whatever a statement opens it closes),
`StmtHost` (stateless; implements the interface `BlockHost` of expr.or), `Coverage` (one flag per variant; flags only
grow), `Inference` (one binding per type parameter, one slot per argument). The 2a classes `Scope` and `Captures` are
unchanged.

Contracts (highlights; `grep -n '@Requires\|@Ensures\|@Invariant' compiler/check/{fnctx,expr,stmt,match,call,lift,ops}.or`):

* **a check either reports or returns a well-typed node**: `ExprChecker.check` ensures that the HIR it returns has a type
  that refers only to ids of the environment (`typeInRange`) and mentions only locals that exist (`localsBound`, hirok.or,
  a loop-and-recursion predicate over every kind of `HExpr` / `HStmt`), and that scopes, loops and contract mode are as
  they were; `expect` ensures `typeEq(result.ty, ty)`; the private recursive core carries the cheap version
  (`typeInRange` only) so that the heavy walk runs once per expression root;
* **scope depth is balanced across statement checking**: the `StmtChecker` invariants, `block` / `matchOf` / `arm`
  ensure the depth, the loop depth and the pending-statement list are unchanged on success, `checkBlock` ensures
  `allStmtsBound(block.stmts, locals.length)`;
* **match**: `Coverage.verdict(span).isNone() == exhaustive()`, `absorb` requires `coverageKept(old, new)` (a covered
  variant stays covered), `arm` ensures the same, `matchOf` ensures the HIR has one arm per source arm and a statement
  match has type `void`;
* **hoisting** (ADR-0009): `tryInMutating` ensures exactly two hoisted statements, `cond` ensures none, `mapMutCall` at
  least one outside a probe; `FnCtx.stashPre` / `restorePre` / `hoist` state their effect on `pre`;
* **inference**: `Inference.learn` ensures `bindsKept` (a binding is never changed), `fill` requires an empty slot,
  `typeArgs` ensures `length == tp.length` and no `void`; `inferPre` ensures one checked argument per parameter;
* **closures**: `registerLifted` ensures a new lifted function with `mode` `FmLifted` that points at its HIR,
  `liftClosure` ensures `functionBound` of the lifted function (every local it mentions is its own),
  `arrow` ensures a `TyFn` and a closure counted in `ncl`; `wrapperOf` ensures the wrapper is indexed under its name;
* **contexts**: `FnCtx.newLocal` ensures the id is the old length and the local is what was asked for, `declare` fails only
  with E0304 and only when the name is in the innermost scope, `lookupVar` never shrinks locals / captures and returns a
  local, `adopt` requires that the environment only grew (`envGrew`);
* **typing rules** (ops.or): `binaryType` ensures both operand types equal and the result is the operand type for
  arithmetic and `bool` for a comparison, `intLiteral` ensures `litFits`, `negBigLiteral` ensures the value is `i64::MIN`.

None fired on the compiler's own sources, on the 804 conformance tests or on the unit tests. To see that they can: 15 hand-made mutants
of the new code (a scope not counted, a verdict that never complains, `popScope` that opens, a predicate that skips
assignments, a conditional that allows hoisting, an inference that learns nothing, `-` typed as `bool`, ...) were run against
`check_body_test.or`: 12 are killed (by a contract trap with the values of the clause, or an assertion), the other three are
the redundant halves of the trial-rollback protocol (below); the pair `loose` + `inferPre` without any rollback is killed
by `failedTrialChecksLeaveNoTrace`.

Design:

* **One mutable context, two classes, one interface.** The old code returned the updated `fx` from every function; a
  class that owns `fx` removes that, but expressions and statements are mutually recursive (a `match` arm or an arrow
  function body is a block), module cycles are an error (E0303) and a class cannot span files. `ExprChecker` therefore
  holds an interface `BlockHost` (`block`, `stmtExpr`, `matchExpr`) that `StmtHost` implements in stmt.or; a call hands the
  context to the other side and gets the updated one back (`this.fx = r.fx`). Value semantics make this cheap and safe:
  the context is copy-on-write, so the checker that handed it out and the one that works on it share until one writes.
* **Trial checks need an explicit rollback.** In the functional version a failed check dropped its context for free.
  Now `methodCall` (the receiver is checked as a value, then for `push` / `pop` as a place), `inferPre` (a deferred
  argument), `loose` (the fallback after a half-resolved arrow function) and `callBuiltin` (the grant argument is only
  probed) snapshot `this.fx` and restore it. `failedTrialChecksLeaveNoTrace` pins the observable effect: the generic
  instance a failed attempt created is created again by the retry, so instance order, and with it the generated C,
  is the old one.
* **Mutating methods have rules of their own** (ADR-0009): the checker's methods are inferred to mutate `this`, so a call
  is hoisted in front of its statement and may not stand in a conditionally evaluated position (`&&`, `||`, `?:`,
  `while` condition, E0408), and the receiver must be a `let` place (`let sub = new ExprChecker(..); sub.check(..)`,
  not `new ExprChecker(..).check(..)`). The code is written in statements (`const r = this.ex(e, None)?;`).
* **Private core, public entry points.** Class invariants are checked after every non-private method, so the
  recursive methods are private and the heavy clauses sit on the few public ones (`check`, `expect`, `place`,
  `block`, `matchOf`, `clause`).
* **Method order matters to the compiler.** Class mutability is a fixpoint that probes every method that is not yet known
  to mutate, once per round; a method that only calls mutating methods becomes mutating in the round after its callees.
  `orin check compiler/main.or` went from 0.53 s to 0.57 s with the new classes (the whole self-compile is unchanged,
  below); methods are not reordered for that.

Behaviour preservation (all against the baseline compiler built before the step):

* `tools/differential.sh compilers`: 1,396 inputs x 3 modes (`compile`, `check`, `check --format=json`), **0 differences**;
* generated code: the C of `compile`, of `compile --check-contracts` and the LLVM IR of `compile --backend=llvm` of
  every `tests/run`, `tests/next/run`, `tests/contracts` and `examples/` program and of `compiler/main.or`
  (415 inputs x 3) is **byte-identical** between the two compilers (the diagnostics diff cannot see instance order,
  hoisted temporaries or closure numbering; this does);
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (6,503,269 bytes), conformance 141/141;
* all 804 conformance tests, also with the contract-checked compiler (`tools/test_compiler_contracts.sh`), no contract fired;
* `orin check --strict-contracts compiler/main.or`: 0 warnings (W045x and W047x);
* `tools/ci_local.sh` (after merging origin/main, `timeout 4000`): all steps passed;
* the 11 end-to-end tests of `check_body_test.or` (diagnostic codes and messages, hoisted statements, lifted closures,
  trial rollback) also pass on the old `body.or`, so they are a specification, not a description of the new code.

Selfcompile (`orin2 compile compiler/main.or`, 11 interleaved runs after a warm-up, the machine was shared by three workers):

| | wall median (min-max) | peak RSS median |
|---|---|---|
| before (baseline compiler on the old tree) | 4.270 s (4.101-4.610) | 121.2 MiB |
| after (new compiler on the new tree) | 4.272 s (4.147-5.014), +0.05 % | 124.8 MiB, +3 % (the source is larger) |
| baseline compiler on the new tree | 4.289 s (4.121-4.655) | 124.4 MiB |

`orin check compiler/main.or` (front end only): 0.527 s -> 0.573 s. The contract-checked compiler self-compiles in
the same time as the normal one within noise.

Friction (language and toolchain):

* **No shared mutable object.** Classes are values, so two cooperating checkers cannot share one context by reference;
  the interface `BlockHost` plus handing the context across is the workaround, and `StmtHost` is a class without state
  that exists only to be converted to the interface. A `&mut` parameter or a reference type for checker state would
  remove both.
* **Parameters are immutable.** A helper that "adds a local" cannot take the context: it is a method of `FnCtx`, or it
  returns the grown environment (`wrapperOf`, `liftClosure` return `{ env, .. }` and the caller `adopt`s it).
* **Constructors**: only leading `this.f = e;` statements (no local temporaries, `Coverage` calls its helper twice),
  no `@Ensures` on a constructor, no `readonly`.
* **Mutating-call rules** (E0408 in conditional positions, `let` receivers) forced the statement style above; `known ?
  sub.ep(e, ret)? : sub.ex(e, None)?` had to become an `if` / `else`.
* **Trial checks** are error-prone with a mutable context (four sites found by reading, one pinned by a test); a context
  that is a value but still copy-on-write cheap is the right model, it just has to be restored by hand.
* **`Env` as a class** was not mechanical (about 120 sites build or update it through helper functions of
  types.or / collect.or / decls.or) and was left for the step that rewrites those; `Env.wrappers` is the one new field.
* **`ExprChecker` is one class of 75 methods in one 3,160-line file** (about 2,560 lines before `orin fmt`): a class cannot
  span files and a calls layer on top of it would need a second host interface and the context handed across at every
  call expression. The pure parts are in ops / call / lift / match / hirok.
* **Contract helpers** over trees are explicit recursion (`localsBound`); `every` / `some` / `filter` are used where the
  property is about an array (`fieldIndex`, `missingNames`, `noPre`, `typeArgs`).
* The formatter's canonical layout adds about 25 % lines to code with long diagnostics; line counts above are after it.

## Step 3a: `lower/` (HIR -> MIR) and MIR source spans

Rewritten: `compiler/lower/` (`body.or` 1,732 lines of functions threading the counters `Ctr`, the scope `Sc` and a growing `Item[]` through every call, `items.or`, `util.or`) into a `Lowerer` class per function plus small classes and pure helpers. **ADR-0020 D3 is done**: MIR carries source spans (below). `compiler/vc/` was not touched; `compiler/check/` was not touched.

| Old | New |
|---|---|
| `Ctr { loc, lab }` threaded in and out of every function (`tm(c, ty)` returns the new counter) | class `Locals` (state.or): the MIR locals table, `fresh(ty)` returns the next id; labels come from `BlockBuilder.reserve(n)` |
| `V { items, op, k, root, stable, c }` returned by every expression, `items.concat(..)` everywhere | `Lowerer` emits into a `BlockBuilder` as it goes; `V` (values.or) is only the operand and its ownership kind |
| flat `Item[]` (`IxI` / `IxL` / `IxT` / `IxD`) converted by `buildBlocks` at the end | class `BlockBuilder` (builder.or): open block, labels, `emit` / `place` / `terminate` / `finish` (unreachable blocks dropped, labels renumbered) |
| `Sc { vars, loopMark, brk, cont }` copied into every call, `inVars`, `releaseFrom` | class `OwnedScope` (state.or): owned locals as a stack, the loop stack, `owned(lo)` in release order |
| `walkPlace(c, ..)` building items | pure `walkPlace(base, ..) -> { instrs, temps }` (place.or), tested without a lowerer |
| ~40 small helpers inside `body.or` | ops.or (operator rules, `match` dispatch planning, place paths, `Callee` / `callInstr`), values.or, wellformed.or (predicates over MIR, used by the contracts) |

Files (`orin fmt` output; clauses are `@Requires` / `@Ensures` / `@Invariant` annotations):

| file | role | lines | requires | ensures | invariant |
|---|---|---|---|---|---|
| `lowerer.or` (was `body.or`, 1,732 lines, 0 clauses) | class `Lowerer` (expressions, statements, `match`, closures, places) and `lowerFunction` | 1,302 | 2 | 21 | 3 |
| `builder.or` (was `items.or`, 128) | class `BlockBuilder` | 180 | 3 | 14 | 6 |
| `state.or` (new) | classes `Locals`, `OwnedScope` | 180 | 5 | 9 | 2 |
| `ops.or` (new) | pure helpers | 248 | 3 | 11 | 0 |
| `place.or` (new) | pure place walk | 191 | 1 | 3 | 0 |
| `values.or` (new) | `V`, `Args` (record invariants) | 87 | 0 | 0 | 2 |
| `wellformed.or` (new) | MIR predicates (`allReachable`, `blocksLocalsBelow`, `operandMatches`, `fnWellLowered`, ...) | 241 | 0 | 0 | 0 |
| `util.or` (was 321) | type mapping, effects, string table | 388 | 1 | 7 | 0 |
| `lower.or` (was 23) | `lower` | 36 | 0 | 4 | 0 |
| total, before -> after | | 2,204 -> 2,853 | | 0 -> 69 ensures + 15 requires + 13 invariants (97 clauses) | |

Unit tests: `compiler/tests/lower_test.or` (15 `@Test`, 437 lines), run by `tools/test_tooling.sh` together with the checker tests; `compiler/tests/verify_main.or` gained 3 span cases.

Classes (4 new): `BlockBuilder` (cur instructions and spans in step, a closed builder has no pending code, labels placed are below the label counter, every finished block was opened by a distinct label), `Locals` (HIR locals first, a temporary's id is its index), `OwnedScope` (loop marks ordered and never above the owned depth; a local is registered once), `Lowerer` (owned depth <= locals, HIR locals preserved, the current span is a real span). `V` and `Args` are records with invariants (a tracked value is in a local; the four argument arrays are parallel).

Contracts (highlights): `Lowerer.finish` ensures the function declares every local it mentions, branches only to blocks of the function, has no unreachable block, every string literal is in the table, a span on every instruction and terminator, HIR locals first with the MIR type of their HIR type, all parameters borrowed; `Lowerer.run` ensures the builder is closed (every block terminated exactly once), no loop open, nothing owned; `expr` ensures the owned depth, loop depth and span are as they were and that the operand of the value is typed like the HIR expression (`operandMatches`); `args` ensures one operand per argument and the owned stack restored; `BlockBuilder.place` / `terminate` ensure the block count and the open flag, `finish` ensures targets in range and all blocks reachable; `walkPlace` ensures take / put balance (every slot it empties is filled again); `rangeCheck` ensures a check exactly for `+ - * /` on narrow types; `variantDispatch` ensures one case per tag, the first arm wins; `litId` requires that the literal was collected (the old code answered 0 and would have used another string silently); `mty` ensures `isRefTy` / `isVoidTy` / `isHandleTy` agree with the MIR class; `isSimple` ensures `!hasEffects`; `lower` ensures the function / vtable / `main` correspondence and `progWellLowered`. None fired on the compiler's own sources, the conformance suites or the unit tests.

### MIR source spans

`MBlock = { instrs; spans; term; termSpan }`, record invariant `spans.length == instrs.length`; `noSpan()` for code without a source. The lowering sets the span of the HIR node it lowers (docs/mir.md "Source spans"); `break` / `continue` / bare `return` have no span in the HIR (`HStmt` has none) and take the previous statement's. The optimiser (`opt/calls.or`, `params.or`, `prune.or`) carries them along; `MBlock` literals elsewhere are the hand-written MIR of the tests (`plainBlock`). `VerifyIssue.span`; the printer writes ` @file:start-end` after an instruction; `verify_text.or` parses it; `tools/gen_mir_fragment.py` / `diff_verifier_lean.py` feed the verifier driver with synthetic spans on every line (so the Lean differential test also exercises the parser), `tools/mutate_mir.py` drops them. The C and LLVM emitters ignore spans (generated code byte-identical, below); there is no comment-in-output flag.

Verifier messages, before and after (`orin verify` / `orin compile`; the same MIR: `l1 = dup str#0; release l1; release l1`):

```
before:  verify error: f b0 i2: use of `l1` which is dead (uninitialised, moved, released or invalidated)
after:   verify error: f b0 i2 at src/main.or:12:5: use of `l1` which is dead (uninitialised, moved, released or invalidated)
```

and through the batch driver (`verify_text`): `f:b0:i2: use of .. @0:78-89`. A function-level well-formedness error and MIR without spans keep the old text. Only a compiler bug triggers a verifier error, so no conformance input changes (`tools/differential.sh compilers`: 0 differences).

Design notes and friction:

* **Classes are values.** `PlaceWalker` as a class over the builder was impossible (no shared mutable object), so the walk is a pure planner (temporaries as `base + k`) and the lowerer declares and emits its result. The same holds for `ownAll` / `args`, which are `Lowerer` methods because they emit.
* **One class, 1,300 lines.** A class cannot span files and `match` arms contain statements (mutual recursion), so expressions, statements and `match` stay in one class; everything that does not emit is outside (ops / place / values / wellformed).
* **Mutating methods that return a value.** Every `Lowerer` method that emits and returns (`expr`, `args`, `temp`, `dupOf`, `ownOp`, ...) is inferred mutating and returns `(self, result)` in the generated C: that pair is where the allocation is built (see the report of step 3a; lowering is about 5 % of the self-compile).
* **Statement style.** Mutating calls cannot stand in `&&` / `||` / `?:`; the lowerer is written in statements (`const v = this.expr(e);`); the call helpers use a `Callee` union instead of a lambda that builds the instruction.
* **Label numbers do not matter.** Labels are renumbered to block indices by `finish`, so labels are handed out on demand (`reserve(n)`); only the order of temporaries (local ids) shows in the generated code, and is unchanged.

Behaviour preservation (against the baseline compiler built before the step):

* `tools/differential.sh compilers`: 1,396 inputs x 3 modes, **0 differences** (diagnostics unchanged; the verifier message gains a location only for compiler bugs, so no input shows it);
* generated code: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`, `examples/` program and of `compiler/main.or` (381 inputs x 3) **byte-identical** (spans never reach the emitters);
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (6,617,344 bytes), conformance 141/141; `tools/test_compiler_contracts.sh`: contract-checked self-compile byte-identical to `stage2.c`, 804 / 804 conformance tests, **no contract fired**;
* `orin check --strict-contracts compiler/main.or`: 0 warnings;
* `tools/mutate_mir.py` (37,951 mutants: all rejected, warned or classified benign) and `tools/diff_verifier_lean.py` (6,000 programs with a synthetic span on every line, only the 4 allow-listed F6 divergences) pass;
* `tools/ci_local.sh` after merging origin/main: every step passed (sanitizer and LLVM suites, the four diff modes, formatter, tooling incl. `lower_test`, LSP, MCP, packages, OSIG, verify contracts, verify-all, erasure); the last step "provable std (tests+mutants)" hit the 4,000 s limit on the shared machine and was run as `tools/test_std.sh` (ok).

Selfcompile (`orin2 compile compiler/main.or -o /dev/null`, interleaved runs, both compilers on the same tree, the machine shared with two other workers): baseline compiler median 8.76 s (min 7.59), new compiler 9.49 s (min 7.83), +3 % on the minimum, +8 % on the median, inside the load noise (the same pair measured earlier: 7.70 s vs 7.69 s; front end `check` 0.87 vs 0.89 s; `mir --no-opt` 1.22 vs 1.27 s). Spans cost one `Span[]` per block and a pointer per instruction.

Rule 7 (array API): the loops of the lowering are the hot inner loops (`args`, `walk`, release loops, `BlockBuilder.finish`) or build several results in one pass, so they stay loops; the well-formedness predicates and contract helpers use `every` / `some` / `map` with pure arrow functions.

## Step 3c: `syntax/` (lexer, parser, AST predicates)

Rewritten: `compiler/syntax/lexer.or` (free functions threading `(file, src, start)` and returning `LexRes { tok, end }`) and
`parser.or` (about 90 functions `(toks, pos, ..) -> Result<{ node, pos }, Diagnostic>`, 18 result record types) into the classes
`Lexer` and `Parser`; the binary-operator precedence is a data table (`precedence.or`), the clause / annotation placement rules
are pure functions of their own (`rules.or`), and the tree has well-formedness predicates (`wellformed.or`). `ast.or` is
unchanged; the exported surface (`lex`, `parse`, `scanComments`, the AST and token types) is unchanged, additions only.
`compiler/fmt/` was not touched (it uses `parse` and `scanComments`).

| Old | New |
|---|---|
| `lex(file, src)`: one loop with a template brace-depth stack, `lexIdent` / `lexNumber` / `lexFloat` / `lexString` / `lexPunct` return `LexRes { tok, end }` | class `Lexer` (lexer.or): `src`, cursor `pos`, `toks`, `depth`, `done`, first error `err`; `step()` lexes one token, `run()` the stream; the per-kind lexers are private methods that `emit` or `fail` |
| every parse function takes `(toks, pos)` and returns `{ node, pos }` (`IdentRes`, `TypeRes`, `ExprRes`, ... 18 types) | class `Parser` (parser.or): `toks`, cursor `pos`, `ops`; methods return the node and move the cursor |
| `parseBin(toks, pos, level)`: one recursion level per precedence level (7 nested calls per operand), `binLevel` / `levelOfText` / `binOpOf` string chains | precedence climbing `parseBin(min)` over class `OpTable` (precedence.or): rows `{ text, level, op, rightAssoc }`, a `Map` index |
| `arrowStart` / `tryTypeArgs` re-parse from a position and drop the result | `arrowStart` probes on a copy of the parser (classes are values), `tryTypeArgs` restores the cursor on `None` |
| `clauseAllowed`, `checkPlacement`, annotation rules, target numbers 0..10 in the parser | rules.or, named targets `T_FUNCTION` .. `T_IMPORT`, `Result<void, Diagnostic>` |
| no statement about spans | wellformed.or: children of every node kind, `nestedIn`, shallow and deep predicates, `moduleWellFormed` |

Files (`orin fmt` layout; the old files reformatted the same way for comparison: lexer 600, parser 2,119, trivia 155 lines;
clauses are `@Requires` / `@Ensures` / `@Invariant` annotation lines, `grep -c '^ *@Requires('` etc.):

| file | role | lines | requires | ensures | invariant |
|---|---|---|---|---|---|
| `lexer.or` (was 528 lines, 1 clause) | class `Lexer`, `lex`, `skipTrivia`, `tokensWellFormed` | 775 | 8 | 17 | 6 |
| `parser.or` (was 1,906, 0) | class `Parser` (76 methods), `parse`, `isSyntaxCode` | 2,033 | 15 | 68 | 2 |
| `precedence.or` (new) | operator table, class `OpTable` | 111 | 1 | 5 | 2 |
| `rules.or` (new) | placement of clauses and annotations | 181 | 0 | 4 | 0 |
| `wellformed.or` (new) | span predicates over every node kind | 470 | 0 | 0 | 0 |
| `trivia.or` (was 148, 0) | `scanComments`, `commentsWellFormed` | 176 | 0 | 1 | 0 |
| `ast.or`, `module.or` | unchanged / exports | 214, 24 | 0 | 0 | 0 |
| total, before -> after | | 2,807 -> 3,984 | 1 -> 129 clauses (24 requires, 95 ensures, 10 invariants) | | |

Unit tests: `compiler/tests/syntax_test.or` (14 `@Test`, 575 lines), run by `tools/test_tooling.sh`.

Classes (3 new): `Lexer` (the cursor stays in the source, the last token ends at or before the cursor, template depths are
non-negative, a finished lexer is at the end or holds its first error, which is E0100 with a span inside the source), `Parser` (the token stream ends with KEof, the cursor is always on a token, so
it never passes the final KEof), `OpTable` (the rows form a precedence table: levels 0..`MAX_LEVEL`, loosest first, no gap,
one associativity per level; the spelling index is as large as the table, so no operator shadows another).

Contracts, with the bug each would catch:

* **progress** (the property that rules out an endless loop): every `parseX` that succeeds ensures `spansFrom(span,
  old(pos))`: it consumed at least one token, and the node's span starts at the first consumed token and ends at the last.
  This catches a production that returns without consuming (a `while (!isP(")"))` loop around it would spin), a node span
  taken from the wrong token (`lastSpan` off by one), and a span that misses its first or last token (a parenthesised
  expression not widened). The documented non-consuming methods state it exactly: `parseTypeParamsB` consumes nothing iff
  there is no `<`, `tryTypeArgs` leaves the cursor unchanged on `None`, `expectP` / `expectKw` move by exactly one or not
  at all. `Lexer.step` ensures that a step adds one token that ends at the new cursor, which is past the old one.
* **cursor in range**: the `Parser` invariant `pos < toks.length` with a KEof last (a production that skips past the end
  would read garbage through the old clamping `tokAt`); `matchingParen` ensures its result lies after the cursor and in the
  stream; `lastSpan` requires that something was consumed.
* **spans nest and are ordered**: every node the parser builds is shallow-well-formed (`exprShallowOk`, `stmtShallowOk`,
  `typeShallowOk`, `patShallowOk`, `blockShallowOk`, `itemShallowOk`, `memberShallowOk`: the children lie inside the node,
  in source order, without overlap; each node is checked once, so the cost is linear); `parse` ensures the deep property
  `moduleWellFormed` (items ordered, inside the source and the file). Catches: a binary node with the span of one operand,
  a block span that is only its `{`, children stored out of order, a span in another file or past the end of the source
  (every LSP range and diagnostic of the node would be wrong).
* **tokens**: `lex` / `Lexer.run` ensure `tokensWellFormed` (in the source and the file, ordered, non-overlapping, non-empty,
  exactly one KEof, at the end); a token one byte short, or a newline that is not skipped, is caught.
* **errors**: `lex` ensures E0100 with a span inside the source; `parse` ensures one of the parse-error codes (`isSyntaxCode`:
  E0100, E0200, E0201, E0408, E0440, E0441, E0442, E0447) and a span inside the source and the file (a diagnostic past the end
  cannot be rendered); `errAt` ensures E0200 / E0201 at the token; `checkPlacement` is `Ok` exactly when every clause is allowed,
  `checkAnnoPlacement` exactly when every annotation is allowed and no kind repeats.
* **operators**: `OpTable.level` ensures the level is that of a row with that spelling (or -1 exactly when no row has it);
  `parseBin(min)` ensures that the operator left at the cursor is looser than `min` (the climbing loop did not stop early).
* **comments**: `scanComments` ensures `commentsWellFormed` (ordered, non-empty, each holds exactly its source text): the
  formatter re-emits these texts, so an overlap would print a comment twice.

None fired on the compiler's own sources, on the conformance suites, on the unit tests, or on 3,207 parse inputs including
1,500 garbage files (below). To see that they can: 13 hand-made mutants (binary span = right operand, left-associative
operators grouped to the right, block span = `{`, `lastSpan` off by one, parentheses not widened, `?` skipping a token,
type-argument backtracking not undone, token span one byte short, newline not skipped, a duplicate operator row, `<` moved to
the level of `+`, the order check removed from `nestedIn`, a line comment keeping its trailing spaces) were run against
`syntax_test.or`: **13 / 13 killed**.

Error recovery: there is none. The parser stops at the first error (the language reports one syntax error per file;
`errors` and `next/errors` pin those diagnostics), so "recovery always advances" reduces to the progress property above, and
in the parser "diagnostics as a field" would only duplicate the `Err` that `?` propagates, so it stays the `Err` of the method (the lexer keeps its first error in a field for speed, below).
`parseTerminatesOnGarbage` runs 400 random token soups and every prefix of a 400-byte program through `parse` and checks that
each returns with a well-formed module or a parse error inside the source. A recovering parser (several syntax errors per
file) is a language-visible change: **NEEDS_DECISION**, not done here. (Decided and done afterwards: "Parser error recovery"
below.)

Precedence climbing replaces the level-per-function recursion: one call per operand instead of seven, the table is data
(`binaryOps()`), and associativity is a column. The tree is the same for left-associative operators (all of them; `?:` and
`==>` are right-associative and stay their own productions, documented in precedence.or). Errors are the same because tokens
are consumed in the same order.

Behaviour preservation (against the baseline compiler built before the step):

* **AST differential**: `compiler/tests/parse_main.or` (the canonical AST dump with spans, or the rendered first error)
  built from the old and the new tree, run over every `.or` file of the repository (1,707, after merging origin/main) and 1,500 garbage files (random
  token soups, truncations, deletions and duplications of real files): 3,207 inputs, **0 differences** (1,908 of them are
  parse errors: code, message and span identical). The same inputs through a contract-checked `parse_main`: no contract fired.
* `tools/differential.sh compilers`: 1,406 inputs x 3 modes (`compile`, `check`, `check --format=json`), **0 differences**;
* generated code: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`, `examples/` program and of `compiler/main.or` (390 inputs x 3) **byte-identical**;
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,666,960 bytes, after merging origin/main with Capabilities Stage B), conformance 141/141; all suites with `orin2`: 806 / 806;
* `tools/test_compiler_contracts.sh`: the contract-checked compiler self-compiles to output identical to `stage2.c`, 806 / 806 conformance tests, `test_verify_contracts` 809 checks, **no contract fired**;
* `python3 tools/test_fmt.py`: 1,651 passed; `tools/test_tooling.sh`: all unit test files pass (`syntax_test` 14 / 14); `tools/test_effects.py` 85 checks and `tools/test_osig.py` 95 checks pass;
* `orin check --strict-contracts compiler/main.or`: **0 warnings**. The base had 13 W0471 (public mutating methods without `@Ensures`) in `compiler/vc/gen.or` (`Gen.next`, `declare`, `assert`, `lemma`, `setExact`, `taint`, `noteApprox`, `noteStr`, `useAssumption`, `newLoop`, `loopAdd`, `addObl`) and `vc/vt.or` (`Tab.setCyclic`); they now state their effect (the counter grows by one so no SMT symbol is handed out twice, a push grows its list by one, a set-like add contains the element and grows by at most one, `noteApprox` keeps the first reason, `newLoop` / `addObl` return the new index). `test_verify_contracts.py` with the contract-checked compiler: 809 checks, 0 failed.

Performance. Wall time on the shared machine (load average 11-13 on 4 cores during the step) was too noisy to resolve a few
percent, so the comparison is also made in instructions (`valgrind --tool=callgrind`, deterministic), both compilers built
by the same baseline compiler:

| | base compiler | new compiler | change |
|---|---|---|---|
| instructions, `orin compile compiler/main.or` | 38,753 M | 38,558 M | -0.5 % |
| instructions, `orin check compiler/main.or` (front end) | 2,718 M | 2,521 M | -7.3 % |
| instructions, lex + parse of every `compiler/**/*.or` file once (benchmark driver) | 1,623 M | 1,365 M | -15.9 % |
| instructions, lex only, same files | 721 M | 668 M | -7.3 % (it was +14 % with Result-returning lexer methods, below) |
| peak RSS, self-compile | 157.8 MiB | 157.8 MiB | 0 |
| wall, self-compile, 9 interleaved runs at load ~1 (median / min) | 7.38 s / 7.06 s | 7.33 s / 6.74 s | -0.7 % / -4.6 % |

Final numbers: both compilers on the merged tree, the new one built by the bootstrap. Earlier, under load 11-13, wall
times moved by 10-15 % between runs of the same binary (`check`: 1.22 s vs 1.32 s in one session,
0.65 s vs 0.75 s median but 0.618 vs 0.626 min in another), so the instruction counts are the measurement. The parser is
cheaper (precedence climbing makes one call per operand instead of seven, and the `{ node, pos }` records are gone), and so is the
lexer since its methods return nothing (below). No slowdown.

Design notes and friction:

* **A mutating method that returns a value returns a pair.** Every `Parser` method that moves the cursor and returns a node
  allocates the `(self, result)` pair; the old code allocated the `{ node, pos }` record instead, so the count is the same.
  In the lexer that pair is per token and on top of the old costs: with `step(): Result<bool, _>` and Result-returning
  per-kind methods lexing took +14 % instructions against the base (`Ok(true)` also boxes the bool; `Ok()` of
  `Result<void, _>` is a shared nullary). A mutating method that returns `void` returns only `self`, so the lexer's methods
  return nothing: the end is the `done` field, the first error the `err` field (`fail(d)`; `finished()`, `error()`), and
  `run` turns it into the `Err`. Lexing is now -7 % against the base. This is "diagnostics as a field" where it pays; the
  parser keeps `Result` (its methods return nodes anyway, so the pair is there either way, and `?` is the clearer form).
* **Speculation on a copy.** `arrowStart` needs to try a return type without moving the cursor: `let probe = new
  Parser(this.toks); probe.pos = q + 2;` (the copy shares the token array). A class that is a value makes this cheap and safe.
* **Rule 8 (no program-wide counters)**: the lexer and the parser are per file; nothing is numbered across files (spans
  carry the file index the caller passes, `OpTable` is built per `Parser`). The only class-typed field, `Parser.ops`, is
  only read (`level`, `rowOf`), so the copy-on-call of a mutating method on a class field (seen in 3b) does not arise.
* **`from` is a keyword** (again): the contract helper's parameter is `first`.
* **Contract helpers as private methods.** `spansFrom` and the token tests are private methods used in the `@Ensures` of
  the same class; it works, and keeps the clauses short (`this.spansFrom(result.unwrap().span, old(this.pos))`).
* **Public parse methods for tests.** `parseExpr`, `parseType`, `parseStmt`, `parseBlock`, `parsePattern`, `parseItem` and
  `parseModule` are public so that the tests can drive single productions (and so that the class invariant is checked after
  each of them); the rest is private.
* Rule 7 (array API): the lexer's character loops, the parser's list loops and `nestedIn` / `tokensWellFormed` (index
  arithmetic, early exit) stay loops; the child lists of the predicates are built with `map` / `concat`, the rule checks use
  `find` / `every` / `some`.

### Parser error recovery

Approved by the project owner on 2026-10-14 (the NEEDS_DECISION of step 3c). `orin check`, `orin compile`, `--format=json`,
the LSP diagnostics and MCP `check` report every syntax error of a file, up to 20, instead of the first one only. Nothing
else changed: the first error is byte-identical to the one before (code, message, span), every valid program gives the
same tree and the same generated code, and `orin fmt` still refuses a file with a syntax error (it calls `parse`, which
stops at the first error as before).

```
tests/recovery/three_errors.or:3:15: error[E0200]: expected expression, found `;`
tests/recovery/three_errors.or:7:28: error[E0200]: expected identifier, found `:`
tests/recovery/three_errors.or:12:12: error[E0200]: expected expression, found `;`
```

**API.** `parse(file, src)` is unchanged. `parseRecovering(file, src): Result<Module, Diagnostic[]>` (parser.or) is the
recovering parse; the loader calls it and puts the further errors after the first in the `LoadOutcome` (`Loader.moreSyntaxErrors`),
so every consumer of the loader (CLI text and JSON, LSP, MCP, `orin test`) reports them without a change of its own. A lexical
error (E0100) ends the scan, so it stays the only error of its file. `Parser.enableRecovery()` switches a parser built by hand
to recovery; without it the `Parser` behaves as before.

**Recovery points.** The innermost of three loops catches the error, reports it and skips tokens:

* *block statement* (`recoverStmt`, in `parseBlock`): to after the next `;` at the statement's brace level; to the `}` that
  closes the block (not consumed); past the `}` that ends the body of an `if` / `while` / `for` / block statement, unless
  `else` follows; or to a token after the error that starts a statement (`let`, `const`, `if`, `while`, `for`, `return`,
  `break`, `continue`, `@`). Brace depth is counted from the first token of the failed statement, so a record literal or
  an arrow function body inside it does not end the block early.
* *class or interface member* (`recoverMember`): to after the next `;`, or past the `}` that closes a method body, at the
  member's brace level; to a `@` after the error; or to the `}` that closes the class body.
* *top-level declaration* (`recoverItem`, in `parseModule`): to the next `function`, `class`, `interface`, `type`, `import`,
  `export` or `@` at the declaration's brace level after the error.

A declaration keyword at the statement's or member's level means that a `}` is missing: the error is reported once, and the
parse unwinds (`Parser.unwinding`, every catcher propagates) to `parseModule`, which continues at that keyword. Running into the
end of the file inside a recovery stops the parse (no "expected `}`" after the real error).

**No cascades.** (1) *The checker never sees a recovered tree.* When the parse has errors, `parseRecovering` returns only the
diagnostics, the loader stops at that file (as it did at the first error before), and no checker runs on the program: only
the parse errors are reported. This is the safe rule of the decision; marking recovered nodes so that the checker could skip
errors that stem from them would have meant a flag on `Expr` / `Stmt` / `Item` (built by literal in ~150 places) and a rule in
every checker method, for the benefit of type errors in a file that does not parse. (2) *Inside the parser* an error is dropped
when it starts at or before the previous error or at the token a statement or member recovery resumed at or the token after it
(`Parser.floor`): a construct that fails at once after a resume point means the tokens are still out of step (a `}` missing
or doubled), and every following line would otherwise report "expected `(` or `:` in class member, found `.`" and the like.
Top-level resume points (a declaration keyword or `@`) are reliable and an annotation error starts at its `@`, so there the
window is not applied. Prefer one error fewer: `a b; c d;` reports one error (`d` is the second token after the resume
point), `let a = ; let b = ;` reports two. (3) *Cap*: at most `MAX_SYNTAX_ERRORS` = 20 per file; when a 21st error is found
the 20th gets the note "further syntax errors suppressed" and the parse stops.

**Termination.** In the style of 3c's progress property: `recoverStmt` and `recoverMember` ensure `result ==> this.pos > st ||
this.isP("}")` (the loop continues only when the cursor moved past the start of the failed construct, or it ends at the `}`),
`recoverItem` ensures `this.pos > st || this.atEnd()`. Every resume point is a token after the error, a `}` that ends the loop,
or the end of the file.

**Contracts** (28 new clauses in parser.or, 3 in loader.or): the `Parser` invariants (`errs.length <= MAX_SYNTAX_ERRORS`, no errors
and no unwinding without recovery, the last error is at or before `floor`), the progress clauses above, `report` adds at most one
error and adds exactly `d`, `stop` leaves the cursor at the end, `parseModule` with recovery always returns a module and has
stopped unwinding, `parseRecovering` ensures `syntaxErrorsOk` (1..20 errors, parse-error codes, spans in the source, strictly
ordered by start, the note only on the 20th) and `agreesWithParse` (errors exactly when `parse` fails, and the first one is
`sameDiag` to it: the "first error unchanged" rule is a contract that runs on every file the contract-checked compiler loads);
`Loader.run` ensures the further errors are renderable and empty on success.

Tests: `compiler/tests/recovery_test.or` (9 `@Test`, run by `tools/test_tooling.sh`: each recovery point, no cascades, the
cap and its note, the lexer, `Parser` without recovery unchanged, 400 garbage token soups and every prefix and every 3-byte
deletion of a program checked against `parse`), `tests/recovery/` with `tools/test_recovery.py` (8 programs with the exact
expected `check` output in `<name>.err`; also checks `compile`, `--format=json` and that `fmt --check` refuses the file), new
cases in `test_lsp.py`, `test_mcp.py` and `analysis_test.or`. Mutation check: 12 hand-made mutants of the recovery code
against `recovery_test.or` (no skipping in `recoverStmt`, no cascade floor, cap off by one, top-level resume at the error
token, `if` body not a statement end, no unwinding at a declaration keyword, one-token cascade window, first error dropped,
note on another error, a method body's `}` not consumed, recovery always on, `recoverStmt` ignoring `unwinding`): 11 killed;
the last is equivalent (the check right after `report` returns on `unwinding` as well, and the re-report is dropped by the
floor).

Results (against the baseline compiler built before the change):

* **first error**: `check` and `check --format=json` of 3,257 inputs (every `.or` file of the repository and 1,500 garbage
  files: random token soups, truncations, deletions and duplications of real files, generated as in 3c): 3,047 outputs
  identical, 210 report more errors; in all 210 the base reported one diagnostic and the new first diagnostic is
  byte-identical to it (JSON line and rendered text), every further one has a syntax code, starts after the previous one,
  and there are never more than 20 (histogram: 2 errors 144 files, 3: 27, 4: 12, 5: 7, 6: 4, 7: 3, 8: 5, 9: 2, 10: 3,
  11: 1, 12: 1, 20: 1, `tests/recovery/cap.or`). No crash, no trap. The same inputs through the contract-checked compiler:
  identical output, no contract fired (3,090 inputs: all but the 167 valid `compiler/` files, which take minutes each to
  type check under contracts on a loaded machine; the contract-checked self-compile below parses every one of them).
* **generated code**: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`,
  `examples/` program and of `compiler/main.or` (392 programs x 3) byte-identical;
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,833,375 bytes), conformance 141/141; all suites 812/812;
* `tools/test_compiler_contracts.sh`: the contract-checked compiler self-compiles to output identical to `stage2.c`,
  812/812 conformance tests, `test_verify_contracts` 809 checks, no contract fired;
* `orin check --strict-contracts compiler/main.or`: 0 warnings;
* `test_fmt.py` 1,661 passed; `orin fmt --stdout` of 3,243 files byte-identical between the two compilers (1,271 formatted,
  1,972 refused); `test_tooling.sh` passed (`recovery_test` 9/9, `test_recovery.py` 8/8); `test_lsp.py` 104 checks,
  `test_mcp.py` 191 checks, 0 failed.

Performance (callgrind instruction counts, both compilers built by the baseline compiler, both on the new tree):
`orin compile compiler/main.or` 38,780 M -> 38,792 M (+0.03 %), `orin check compiler/main.or` (front end) 2,575.0 M ->
2,587.2 M (+0.47 %). The parser's own copy-on-write traffic did not grow (the `Parser` copies in `orin_make_unique_slow`
went from 1.60 M to 1.46 M instructions); the rest is spread thinly. Wall time was not measurable (load average 17-19 on 4
cores: medians moved by more than 5 % between runs of the same binary).

Friction:

* **No exceptions, no catch.** Every error is a `Result` that `?` propagates; a recovery point is a loop that takes the
  `Err` apart (`isOk` / `unwrap` / `unwrapErr` instead of `?`), and "give up and resume at the top level" needs a flag in
  the parser (`unwinding`) that every catcher tests, because there is no way to unwind past several frames.
* **Parameters are immutable and classes are values**: the loop-clause part of a block statement had to become a method
  that returns its statements (`parseLoopClauses`) instead of pushing into the caller's array.
* **Cascade rules are heuristics.** The cap, "stop at the end of the file" and "the checker never sees a recovered tree" are
  rules; the two-token window after a resume point is a judgement (it drops `c d` in `a b; c d;`). It was tuned on the
  garbage corpus, where the out-of-step cases (a `}` deleted in the middle of a class) produced one error per following line
  before it.
* **Session tooling**: shell loops over compiler runs are refused in a worktree-isolated session (like compound `git`
  commands, see "Pitfalls found"); the corpus and comparison drivers were small Python scripts.

## Step 3e: the tooling modules (`analysis/`, `lsp/`, `mcp/`, `json/`, `fmt/`) and the capability gate

Rewritten to the contract and class standard: the state that the tooling threaded through records and free functions is now
five classes, the exported functions state what they guarantee, and `analysis` performs no I/O of its own (the capability
gate of Stage B). The exported surface is kept: the functional interfaces (`handle(fs, st, msg) -> { state, out }`,
`openFile(ws, ..) -> Workspace`, `newState`, `format`, `parseJson`, `stringifyJson`, ...) are thin wrappers over the classes,
so `mcp`, `testing`, `vc`, `main.or` and the tests needed only the renames below.

| Old | New |
|---|---|
| `type Workspace = { files: SourceFile[]; revision }` + free functions that copy it | class `Workspace` (workspace.or): the document store; `open` / `close` / `text` / `paths` / `sources()` |
| `type LspState` record, `handleRequest` / `reqX(fs, st, id, msg) -> LspStep` | class `LspServer` (lsp/handler.or): `handle` / `handleText` / `pump`; a request is answered by one private method that returns *the* reply |
| `type McpState` record, `toolCheck` rebuilds it with a spread literal | class `McpSession` (mcp/util.or): root, rights, `record` / `find` / `latest` of the `check` snapshots |
| `parseValue(s, i, depth) -> { v, pos }`, `parseString`, `parseNumber` threading the offset | class `JsonCursor` (json/parse.or): the read position over one text; `document()` |
| `emit(j, out: string[]) -> string[]` (json.or) | `write.or`: `stringifyJson` / `quoteJson` with `map` / `join`; `jsonEq`, `nesting` in json.or |
| `type Ctx = { src; cs }` + `seq(c, ..)`, `bracketed(c, ..)`, `findChar(c, ..)`, `gapsHave(c, ..)` | class `Layout` (fmt/layout.or): the source with its comment queue and the comment-placing operations; the printer calls `c.seq(..)` |
| `readFile` / `exists` in `analysis` (`readText`, `resolveModulePath`, `loadOsigIn`) | `Workspace.sources()` / `new Sources([])`: reads go through the loader's `Sources` |
| `analysis/osigcli.or`, `analysis/effectscli.or` (CLI, `writeFile`, `console.*`) | moved to `tools/` (the CLI layer, next to `orin fmt`); `analysis` exports no driver |
| linear `for` searches (`hasStr`, `hasName`, `indexIn`, `hasLabel`, `containsIdx`, `sameSet`, ...) | `includes` / `some` / `every` / `findIndex` / `filter` / `map` (rule 7) |

No `Printer` with an output buffer: the printer renders an element, measures it against the line width and renders it again
broken over lines when it does not fit (`ex` with `lim`), so its results are values; a write-only buffer would need a rollback
for every trial. The comment queue is the `Layout` class; its placement markers (`\x01 k \x02`) are what lets an enclosing
construct see which comments an element already placed.

Files (`orin fmt` output; most of these files had never been formatted, which accounts for most of the growth, e.g.
`mcp/apitable.or` 192 -> 848 lines with no change of content; clauses are `@Requires` / `@Ensures` / `@Invariant` lines):

| file | lines before -> after | requires | ensures | invariant |
|---|---|---|---|---|
| `analysis/analyze.or` | 188 -> 199 | 0 | 7 | 0 |
| `analysis/apisnap.or` | 262 -> 264 | 0 | 2 | 0 |
| `analysis/effectpolicy.or` | 226 -> 244 | 0 | 4 -> 7 | 0 |
| `analysis/modgraph.or` | 162 -> 186 | 0 | 4 | 0 |
| `analysis/osig.or` | 927 -> 1,195 | 1 | 6 | 0 |
| `analysis/osigdiff.or` | 726 -> 808 | 0 | 5 | 0 |
| `analysis/osigreport.or` | 602 -> 837 | 0 | 4 | 0 |
| `analysis/pos.or` | 65 -> 78 | 0 | 3 | 0 |
| `analysis/query.or` | 289 -> 407 | 8 | 19 | 0 |
| `analysis/symbols.or` | 364 -> 479 | 0 | 3 | 0 |
| `analysis/workspace.or` | 75 -> 137 | 0 | 10 | 3 |
| `analysis/{effects,effectsum,doccomments}.or` (Stage B, unchanged) | 1,536 -> 1,538 | 11 | 16 | 4 |
| `lsp/handler.or` | 670 -> 744 | 0 | 15 | 2 |
| `lsp/frame.or`, `uri.or`, `convert.or` | 243 -> 284 | 0 | 11 | 0 |
| `lsp/{server,stdio,format,module}.or` | 123 -> 123 | 0 | 0 | 0 |
| `mcp/util.or` | 195 -> 286 | 4 | 14 | 5 |
| `mcp/handler.or` | 101 -> 119 | 0 | 4 | 0 |
| `mcp/tools.or` | 1,130 -> 1,418 | 1 | 3 | 0 |
| `mcp/apitable.or` | 192 -> 848 | 0 | 2 | 0 |
| `json/parse.or` | 310 -> 412 | 2 | 13 | 1 |
| `json/json.or` + `write.or` (new) | 228 -> 308 | 0 | 4 | 0 |
| `fmt/printer.or` | 1,248 -> 1,502 | 0 | 6 | 0 |
| `fmt/layout.or` | 263 -> 330 | 2 | 4 | 1 |
| `fmt/format.or`, `text.or` | 119 -> 155 | 0 | 6 | 0 |
| `tools/osigcli.or`, `effectscli.or` (moved from `analysis`) | 242 -> 248 | 0 | 0 | 0 |
| **total** (with the module files) | **10,589 -> 13,264** | **35 -> 213 clauses** (29 requires, 168 ensures, 16 invariants) | | |

Classes: 1 -> 6 (`EffectTable` of Stage B, plus): `Workspace` (keys normalized and distinct, the revision only grows; `open`
ensures the text is there and the revision moved by one, `close` that the path is gone), `LspServer` (`shutdown` only after
`initialize`; every published path once), `McpSession` (root normalized, at most `MAX_SNAPS` snapshots, revisions increasing and
below the next one; `record` ensures that the revision it returns names a stored snapshot and that an unchanged project keeps its
revision), `JsonCursor` (the position never leaves the text; `value` consumes at least one byte on success), `Layout`
(comments sorted, not overlapping, inside the text: what the binary search `firstAtOrAfter` relies on). `Snap` is a record with
an invariant (`keys` and `lines` in step).

Contracts, each with the bug it catches:

* **JSON round trip**: `stringifyJson` ensures `nesting(j) <= MAX_DEPTH ==> parsesBackTo(result, j)` (structural `jsonEq`),
  `quoteJson` ensures its literal reads back. Catches a missing escape, a number the parser cannot read (it did: below), a
  field order change. `parseJson` / `JsonCursor.document` ensure a successful parse consumed the whole text and stays within
  `MAX_DEPTH`, and an error names an offset inside the text (`errorInRange`); `value` ensures progress (a parse that does not
  advance would loop) and `depth + nesting(result) <= MAX_DEPTH`; `utf8` requires a scalar value (a surrogate would make the
  output invalid UTF-8).
* **Positions**: `offsetToPos` ensures `isCharBoundary(text, off) ==> posToOffset(text, offsetToPos(text, off)) == off`;
  `posToOffset` ensures its result is a character boundary inside the text. Catches a unit-counting rule that drifts between
  the two directions (a hover or rename one character off after a non-ASCII character).
* **The reply rule** (LSP and MCP): `LspServer.handle` ensures `repliesTo(msg, result)`: a request gets exactly one response,
  carrying the id it was given (`jsonEq`, so string, number and object ids), everything else is a notification and a
  notification gets no response; nothing after `exit`. `handleText` ensures a text that is not JSON is answered once with id
  null. The private `request` ensures `answers(result, id)`, `notify` that it returns only notifications. MCP `handle` /
  `handleText` ensure the same rule. Catches a handler that answers twice, forgets to answer, or answers with another id
  (a client hangs or mismatches replies).
* **References point at existing definitions** (query.or): every query requires `defIdsDense(idx)` (`defs[i].id == i`, which
  the checker's `addDef` guarantees and the hit search relies on); `hitAt` ensures the hit is an occurrence of a definition
  that exists; `referencesOfDef` ensures every span is an occurrence of `def` (`isOccurrence`: its name or one of its refs),
  no span twice, the declaration first when asked for and absent otherwise; `definitionAt` ensures a definition's name;
  `implementationsOfDef` that every span is a definition's name; `renameEdits` that every edit has the new name and lies on an
  occurrence of the symbol at the cursor. Catches a reference list that mixes symbols (a rename that edits another symbol).
* **Formatter**: `format` ensures `sameComments(src, result)` (same multiset of comment texts) and idempotence
  (`format(result) == result`, a self-call, ADR-0031 A5); `printModule` ensures every comment of the file is placed
  (`allPlaced` of its marker), `Layout.seq` / `bracketed` / `block` ensure every comment of their range; `quote` ensures a
  one-line, valid UTF-8 literal. Catches a comment lost or doubled by a new layout rule, a non-canonical output.
* **Capability-relevant analysis**: `analyze` ensures every diagnostic names a file of the source map and a range inside its
  text (`diagsInRange`: the synthetic `main` of a library entry never leaks a position), `program` and `index` together;
  `readText` returns the buffer when there is one; `resolveModulePath` a normalized `.or` path, never for `std:`.
* **OSIG**: `buildOsig` ensures the hash and sorted, distinct node ids; `osigJson` ensures `parseOsig` reads it back with the same
  hash (a field written but not read would break every later `orin diff`); `sortOrder` (merge sort) a stable permutation;
  `cmpStr` a total order; `diffOsig` no differences for two snapshots of equal content; `diffJson` one JSON document whose
  `differences` is `hasDifferences`; `diffHtml` no `<script`.
* **MCP**: `McpSession` (above), `resolvePath` a normalized path inside the root, `applyEdits` requires disjoint edits inside
  the text and ensures the resulting length, `hashStr` stays in range, `shq` one quoted word, the API table has unique names.
* **Framing**: `frameMessage` ensures `unframe` reads back exactly the body (a `Content-Length` in characters instead of bytes),
  `unframe` that the rest is the tail of the buffer; `pathToUri` ensures `uriToPath` gives the path back (an unescaped `%`).

Mutation check: 16 hand-made mutants of the new code (a number that does not advance the cursor, `\` not escaped, 20-digit
numbers accepted, a reused revision, an unbounded snapshot list, an unnormalized buffer key, `close` by raw spelling,
continuation bytes counted as characters, `initialize` answered with id null, `shutdown` answered with a notification, `ping`
answered twice, references of other definitions included, a hit on the wrong definition, a trailing comment dropped, `%` not
escaped in URIs, `Content-Length` off by one) against `compiler/tests/tooling_test.or`: all 16 killed, 14 by a contract trap (with the values of the clause), 2 by an
assertion (continuation bytes, 20-digit numbers). Five survived the first run because the test never exercised the path
(closing a buffer by another spelling, a hit on a declaration that is not the first definition, a framed message, a path with a
valid `%XX`, a 20-digit number); the test now does, and the contracts of those paths kill them.

Defects found and fixed:

* **JSON: the serializer wrote numbers the parser rejected.** `parseJson` refused integers with more than 18 digits, but
  `stringifyJson` writes any `int` (`i64::MIN`, any value from 10^18 on): the round-trip contract failed on them. The
  parser now reads every `int` (19 digits checked against the bounds, accumulated on the side of the sign so that `i64::MIN`
  does not overflow) and rejects only values outside the i64 range; `json_test.or` was updated (`1234567890123456789` is now
  read, `9223372036854775808` and 20 digits are errors).
* **Effect policy diagnostics pointed into the wrong file.** E0474 (unknown effect name) and E0502 (a table of a missing
  module) are found after loading, but kept the file id 0 of the manifest parse, so they were rendered as a position in the
  program's first source file (`src/main.or:19:1` for a line of `orin.toml`), and the contract-checked compiler trapped on
  `render`'s `isRenderable` precondition. `Manifest` now carries its `source` (the loader sets it), the policy relocates the
  spans to the manifest's place in `policySourceMap(prog, sm)`, and `main.or` / `orin effects` render against that map; the
  location is now `orin.toml:24:12`. `effectPolicyDiags` ensures `allRenderable(policySourceMap(..), result)`;
  `tools/test_effects.py` checks the file name. (Found by running the effect suite with the contract-checked compiler.)

Not done: `lsp::shellRun` (the only `shell` call) stays: there is no `spawn(proc, executable, argv)` in the standard library
yet (ADR-0037 D5). The 13 strict-contract warnings W0471 of `compiler/vc/` (public mutating methods of `Gen` / `Tab` without
`@Ensures`) are older than this step and outside its modules.

Unit tests: `compiler/tests/tooling_test.or` (16 `@Test`: JSON round trip, equality, cursor, error offsets, nesting limit;
position round trip; workspace store and reads through `Sources`; index queries; the LSP and MCP reply rule on scripted
sessions and its predicate on hand-built replies; MCP revisions; formatter idempotence and comments; `Layout`), run by
`tools/test_tooling.sh`. `json_test.or`, `analysis_test.or`, `lsp_test.or` were adapted (`LspServer`, `revision()`, the number
rule); they also pass when built with `--check-contracts`.

Behaviour preservation (against the baseline compiler built from `origin/main` before the step):

* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,513,150 bytes), conformance 141/141;
* generated code: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`,
  `examples/` program and of `compiler/main.or` (426 inputs x 3), baseline compiler vs new compiler: **0 differences**;
* `tools/differential.sh compilers`: 1,412 inputs x 3 modes, **0 differences** (no conformance input has an `[effects]` table, so the
  relocated E0474 / E0502 do not show there; `tools/test_effects.py` checks them);
* conformance `--suite all` 812/812 (C), default suite with `--backend=llvm` 141/141;
* `tools/test_compiler_contracts.sh`: contract-checked self-compile byte-identical to `stage2.c`, 812/812 conformance tests,
  verifier contracts 809/809, **no contract fired**; `tools/test_lsp.py` (100 checks), `test_mcp.py` (188), `test_osig.py` (101),
  `test_effects.py` (89) also pass with the contract-checked compiler as the binary under test (that run found the E0474 defect);
* `tools/test_tooling.sh`, `tools/test_fmt.py` (13 goldens, 1,584 corpus files: idempotence, AST and comment preservation,
  61 JSON diagnostics; 1,658 passed), `test_lsp.py`, `test_mcp.py`, `test_osig.py`, `test_effects.py`: pass;
* `orin fmt --stdout` of the 1,609-file formatter corpus with the contract-checked compiler: output byte-identical to the
  baseline's, no contract fired (idempotence and comment contracts on every file);
* `orin check --strict-contracts compiler/main.or`: 13 warnings, the same 13 W0471 of `compiler/vc/` as on `origin/main`;
  none in the modules of this step (`LspServer.pump` got its `@Ensures`).

Selfcompile (callgrind instruction counts of `orin2 compile compiler/main.or -o /dev/null`; the machine was shared, so
instructions rather than wall time): baseline compiler on the old tree 38,236,442,981; new compiler on the new tree
38,419,783,870 (+0.48 %); baseline compiler on the new tree 38,419,717,402. The two compilers on the same tree differ by
66,468 instructions (+0.0002 %): the growth is the larger input (the formatted and annotated tooling sources), not a slower
compiler. Contracts are erased in the normal build; the tooling code does not run during a compile.

Friction:

* **A class cannot hand itself out.** `LspServer.pump` returns `Pumped { state: this, .. }` for the functional interface; the
  free functions copy the class into a `let`, call the mutating method and return the copy (`handle(fs, st, msg)`). The MCP
  tools still thread the session through `ToolOut.st` because only `check` changes it and the tool functions are free
  functions; a `&mut` parameter would remove both.
* **Grants in tests.** A closure cannot capture a grant (E0452), so a test that needs both the file-system and the process grant
  uses `useHost(host, (fs, proc, stdio, clock) => ..)` and a helper function instead of nesting `useFs` / `useProcess`.
* **No `lastIndexOf`, no `Option.map`, `every` without an index.** `errorOffset` splits the message, `findField` uses
  `findIndex`, `sortDesc`'s ordering predicate is a loop.
* **`reduce` takes the function first** (`xs.reduce(f, init)`), and an `int` literal does not meet a `usize` accumulator; the
  length sum of `unframe`'s contract is a loop.
* **The word "digits" in a shell command** made the worktree sandbox refuse it (it contains `git`); scripts were written to
  files instead.
* **`orin fmt` had never run on these modules**: the first formatting is most of the line growth (`apitable.or` alone 192 ->
  848); the clause counts are unaffected.
* **Contract cost of self-calls.** A clause that re-renders (`ex` ensuring the broken form equals `exBreak(..)`) doubles the work
  at every nesting level, exponential in the depth; it was dropped. `format`'s idempotence clause runs the formatter twice per
  call, acceptable because only the contract-checked build pays it.

## Step 3b: `verify/` (the ownership verifier), `mir/` well-formedness, `hir/`

Rewritten: `compiler/verify/` (the independent MIR ownership verifier, the trust anchor of memory safety: every compile is
gated by it, it has a Lean twin in `formal/` and the differential test `tools/diff_verifier_lean.py`). The transfer functions
threaded a `Cx` record through ~60 functions that each returned the updated copy; the fixpoint kept parallel `ins` / `queued`
/ `work` arrays in one function. New: `compiler/mir/wellformed.or` (the structural MIR predicates, shared by the lowering, the
verifier and the tests). `compiler/hir/` got contracts where it has real invariants. `compiler/lower/` only lost the predicates
that moved to `mir/` (and `lower` gained `@Ensures(isWellFormedProgram(result))`). `compiler/opt/` was not touched: it keeps
using `Cx`, `step`, `State.ls` and `blockInStates` exactly as before.

| Old | New |
|---|---|
| `type State = { ls; holes }` + free functions `joinState`, `stateEq`, `holeIn`, `holesEq` | class `State` (state.or): the lattice value stored per block: queries (`kind`, `srcOf`, `holeAny`, `holeHas`, `holeMay`), `join`, `equals`, `leq` (the lattice order), `borrowsFlat`; the hole queries are also free functions over a hole array (`holeAnyIn`, ...) |
| `type Cx = {..}` threaded through every rule: `c = readLocal(c, l); c = err(c, msg); return def(c, d, k, 0)`; `setLs`, `killBorrows`, `addHole`, ... over a `Cx` | class `Transfer` (rules.or): one run through a block; it owns the state arrays `ls` / `holes` and the issues; the rules and the state mutators (`set`, `killBorrows`, `addHole`, `removeHole`, `dropHolesOf`) are private methods that mutate `this`; public `run`, `step(ins)`, `term(t)`, `state()` carry the contracts. `Cx` / `step(cx, ins)` remain as the optimiser's interface (a wrapper) |
| `fixpoint(p, f)`: `ins`, `queued`, `work` as three local arrays | class `Fixpoint` (verify.or): the in-states and the worklist (`queued` flags, LIFO `work`), private `add` / `take`, public `run`, `isStable`, `pending` |
| `successors`, `dstOf`, `instrLocals`, ... duplicated in verify.or, wf.or and lower/wellformed.or | one copy in `mir/wellformed.or`: `dstOf`, `instrLocals`, `instrOperands`, `termLocals`, `successors`, `instrInRange`, `termInRange`, `spansAligned`, `paramsWellFormed`, `isWellFormedFunction`, `isWellFormedProgram`, plus the block predicates of 3a |
| index loops that ask a question about an array (`noHandles`, `opsOk`, `constsOk`, `casesOk`, `holeIn`, `holesEq`, owned-parameter scans, the void-local scan) | `some` / `every` / `find` / `filter` (rule 7); the per-instruction loops of the transfer functions (`killBorrows`, `callOwned`, the leak scan at `return`, `join`, `equals`) stay loops: they are the hot path, mutate, or exit early |
| vtable check inline in `verify` | `vtableMsg` |

Files (`orin fmt` output for the rewritten files; clauses counted with `grep -c '^ *@Requires'` etc.):

| file | role | lines before -> after | requires | ensures | invariant |
|---|---|---|---|---|---|
| `verify/state.or` | domain: `LState` (record invariants), `lsLeq`, `joinLs`, hole queries, `borrowsFlatIn`, class `State` | 145 -> 331 | 6 | 12 | 3 |
| `verify/rules.or` | class `Transfer`, `Cx` / `step`, `noRevival`, `issuesAt` | 656 -> 830 | 11 | 20 | 3 |
| `verify/verify.or` | class `Fixpoint`; `verify`, `blockInStates`, report placement | 211 -> 380 | 7 | 20 | 4 |
| `verify/wf.or` | structural checks, tied to the `mir/` predicates | 473 -> 564 | 3 | 9 | 0 |
| `verify/module.or` | exports | 4 -> 13 | 0 | 0 | 0 |
| `mir/wellformed.or` (new) | shared structural predicates | 0 -> 292 | 0 | 1 | 0 |
| `hir/hir.or` | integer kinds, `Function` | 264 -> 298 | 3 | 11 | 1 |
| `hir/index.or` | `CallSite` (after merging main's `param` / `fnArgs`) | 72 -> 89 | 0 | 0 | 4 |
| `lower/wellformed.or` | (predicates moved to `mir/`) | 241 -> 57 | 0 | 0 | 0 |
| `lower/lower.or` | `lower` | 36 -> 37 | 0 | 5 (+1) | 0 |
| total verify | | 1,489 -> 2,118 | 27 | 61 | 10 = **98 clauses (0 before)**; 101 after the merges below (28 / 63 / 10) |
| total hir + mir + lower | | | 3 | 13 (+2) | 5 = 21 new clauses |

Unit tests: `compiler/tests/verify_test.or` (23 `@Test`, 622 lines), run by `tools/test_tooling.sh`; `compiler/tests/verify_main.or`
gained 4 robustness cases (below).

Classes (3 new): `State` (every hole names a local of the function, so does every symbolic index), `Transfer` (one state
entry per local of the function; every hole names a local; the position is a block of the function and at most its
terminator), `Fixpoint` (one in-state slot and one queue flag per block; the entry block is always reached; the worklist is
never longer than the block list, and only block ids get in, by the `@Requires` of `add`). `LState` (a kind in range; a source
only for `Borrowed`) and `CallSite` (a known evidence level and edge kind, no callee when the target is unknown, a parameter index only for a call of
a function value) are records
with invariants; `Function` (HIR) has `paramCount <= locals.length`.

Contracts (highlights; the bug each would catch):

* **the join is a semilattice join**: `joinLs` ensures commutativity (`joinLs(a, b) == joinLs(b, a)`, a self-call in the
  contract), idempotence, that the result is an upper bound of both inputs in `lsLeq` (the order is stated independently of
  the join: equal; Unique/Imm below Owned; no-reference states below MaybeDead; everything but handles below MaybeLeak;
  MaybeOpen on top), and that a borrow survives a join only when both sides agree on its root. `State.join` ensures
  `this.leq(result) && o.leq(result)` (catches a join that loses a hole or a poisoning: the next block would be checked from a
  state that is too optimistic, i.e. unsound) and `equals` ensures `result ==> this.leq(o)`. The unit tests check
  associativity and that the join is the *least* upper bound over all 12x12x12 states (the worklist order then cannot matter).
* **only a defining instruction revives a local**: `Transfer.step` ensures `noRevival(old(this.st), this.st, dstOf(ins))`:
  a local that was dead or poisoned before an instruction is in exactly the same state after it, unless the instruction
  defines it. Catches a rule that "repairs" a released array by a push (a use-after-free that would then pass every later
  check), a demotion that fires on a dead local, a close that reopens.
* **borrows are flat**: `Transfer.run` requires and ensures `State.borrowsFlat()` (an alias's root is never itself an alias).
  `rootOf` and the single `killBorrows(x)` per release rely on it; a redefinition that forgot to kill the aliases of the
  redefined local makes a chain, and the alias would survive the release of its real owner.
* **every report names an existing position**: `Transfer.step` / `term` ensure that every new issue is at the current block
  and instruction and carries that instruction's span (`issuesAt`); `verifyFunction` ensures `issuePlaced` for every error and
  warning (an existing block and instruction, the terminator being `instrs.length`, or the function itself at 0/0 without a
  span); `verify` ensures `reportPlaced` (a function, a vtable or `<program>`).
* **the fixpoint is one**: `Fixpoint.run` ensures an empty worklist, one entry per local in every in-state, that the reached
  blocks are closed under successors, and `isStable()`: re-running every reached block and joining its out-state into each
  successor's in-state changes nothing. Catches a worklist that drops a block or does not re-queue a loop head whose in-state
  grew (the blocks after the loop would be checked from a stale state). `Fixpoint.add` / `take` state their effect on the
  queue (a block is queued at most once; `take` returns a valid id and unqueues it).
* **the verifier's well-formedness implies the shared predicate**: `wfInstr` ensures `instrInRange` (only locals, strings,
  functions, vtables that exist) and `handleDefOk` (only an opener defines a handle); `wfTerm` ensures `termInRange`;
  `wfFunction` ensures `paramsWellFormed`, an entry block, `spansAligned`; `wellFormed` / `verifyFunction` ensure
  `errors.length == 0 ==> isWellFormedFunction(p, f)` and `verify` ensures `errors.length == 0 ==> isWellFormedProgram(p)`.
  The verifier's check and the structural predicate of `mir/` are written independently; the contract keeps them from drifting
  apart (a wf rule deleted from the verifier shows as a trap). `lower` ensures `isWellFormedProgram(result)` with the same
  predicate.
* **preconditions of the rules**: `Transfer.step` requires `wfInstr(..) == ""` (the rules index without checks),
  `State.set` requires a kind in range and a borrow rooted at another existing local, `addHole` a hole naming existing locals,
  `blockInStates` (the optimiser's entry) a well-formed function.
* **hir**: `kindType` requires a kind number and ensures `intKindOf(kindType(k)) == k`; `kindHi` ensures that a narrow kind has
  exactly 2^bits values (`kindHi(k) - kindLo(k) + 1 == pow2(kindBits(k))`) and that the u64 maximum is the all-ones pattern;
  `kindLo` is negative exactly for signed kinds; `kindNarrow == (kindBits < 64)`; `kindName` requires a kind number (it
  indexes a table).

None fired on the compiler's own sources, the conformance suites or the unit tests. To see that they can: 12 hand-made
mutants of the new code (join keeps Unique, worklist forgets its flag, no re-queue of a grown in-state, redefinition or release
keeps aliases, a push revives a dead array, a symbolic hole key never aliases, errors one instruction late, an unchecked
`goto` target, `dup` does not demote, the join drops the second state's holes, `kindHi(i8) == 128`) were run against
`verify_test.or`: **12 / 12 killed**, 9 of them by a contract trap (the other three by assertions). The first run left one
survivor (the revived array), which is why `aPushOntoAReleasedArrayDoesNotReviveIt` exists.

### Defects found and fixed

**The verifier crashed (array index out of range) instead of reporting ill-formed MIR in four places.** All four are
fail-safe (a trap aborts the compile, nothing unsafe is accepted) and no MIR the compiler produces triggers them, but the trust
anchor must report, not crash, and the batch driver (`verify_text`) and `orin verify` died on such input. Found by the new
`@Requires(l < f.locals.length)` of `localClass` and the `spansAligned` part of the shared predicate:

1. `ICall` of a callee whose `paramCount` exceeds its locals: the argument-class loop read `g.locals[i]` of the callee
   before the callee itself was checked. Now `ICall: callee g has more parameters than locals` (and the callee's own
   `paramCount exceeds the number of locals`).
2. `IClosure` whose target has parameters but no locals: `g.locals[0]`. Now the existing message `IClosure: the lifted
   function must take the environment record as its first parameter`.
3. A vtable entry with parameters but no locals: same; now the existing `vtable entry g must take the boxed value ...`.
4. A block with fewer spans than instructions (possible only without contract checking: `MBlock`'s record invariant forbids
   it): reporting an error in it read `spans[i]`. `wfFunction` now rejects it with `a block has a different number of source
   spans and instructions`.

Each is a case of `verify_main.or` (`robustnessCases`, run without contracts, so case 4 can be built) and, for 1-3, of
`verify_test.or`; on the old verifier all four end in `trap: index out of bounds`. **Verdicts**: these inputs went from "crash"
to "reject"; no input that was accepted or rejected before changes (measured below). The Lean model needs no change: its
fragment has well-formed parameter tables and no spans (the differential test generates only well-formed programs).

### Behaviour preservation

All against the compiler built from `origin/main` (c37cf52, merged into the step at the end; the same gates were also run
before the merge against the 3a baseline, with the same results):

* **verifier verdicts and messages, byte for byte**: the `verify_text` driver built from the old and the new tree, fed the
  same 43,935 programs (every distinct function of the conformance programs' MIR and all its `mutate_mir` mutants) and
  the 4,000 `gen_mir_fragment` programs of the Lean differential test (with a synthetic span on every line): **output
  identical** (28,412 and 3,114 rejections, 4,445,071 and 808,781 bytes), so every accept / reject decision and every
  message is unchanged; the four robustness inputs above are the only ones that behave differently (a crash before);
* `tools/mutate_mir.py`: 41,315 mutants, 28,412 rejected, 12,354 warned, 549 benign, 0 survivors, 0 wrong-reason (the
  same as before); `tools/diff_verifier_lean.py` (12,000 programs): 4,592 both ACCEPT, 7,396 both REJECT, 12 divergences,
  all in the allow-listed class F6, the same numbers with the old driver; `verify_main.or`: all cases pass (4 new);
* generated code (`tools/differential.sh compilers`-style comparison of C, C with `--check-contracts` and LLVM IR of every `tests/run`,
  `tests/next/run`, `tests/contracts`, `examples/` program and `compiler/main.or`): **390 inputs x 3, 0 differences**;
  diagnostics (`tools/differential.sh compilers`): 1,406 inputs x 3 modes, 0 differences;
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,373,446 bytes), conformance 141/141; all suites with `orin2`: 806/806;
* `tools/test_compiler_contracts.sh`: the contract-checked compiler self-compiles to output identical to `stage2.c`, 806/806
  conformance tests, `test_verify_contracts` 809 checks: **no contract fired**;
* `orin check --strict-contracts compiler/main.or`: no warning in the files of this step; the 13 `W0471` of
  `compiler/vc/` (`Gen`, `Tab`) are on `origin/main` too and are not part of this step;
* `tools/test_tooling.sh` (including `verify_test.or` and `verify_main.or`): passes; `ci_local.sh` was not run (the
  coordinator replaced it by the gates above; GitHub CI covers the rest).

Selfcompile (`orin2 compile compiler/main.or -o /dev/null`, both compilers on the same merged tree, interleaved, the
machine shared with other workers at load 4-10 on 4 cores):

| | main compiler | new compiler |
|---|---|---|
| batch 1 (main first, 10 runs) | median 9.241 s, min 8.104 | median 9.508 s (+2.9 %), min 8.219 (+1.4 %) |
| batch 2 (new first, 10 runs) | median 8.673 s, min 7.413 | median 8.408 s (-3.1 %), min 7.242 (-2.3 %) |
| before the merge, 3a baseline vs final layout (5 runs) | median 7.938 s, min 7.185 | median 7.160 s, min 6.910 |

No regression beyond the noise; the copy count of the verifier is below the old code's (2.62 M vs 2.89 M
`orin_make_unique_slow` calls per self-compile, gprof). The verifier is about half of the self-compile; its hot spots are the
same as before (`killBorrows`, O(locals) per definition, about 23 %, and `State.join`, about 17 %): a reverse index from a
root to its aliases would remove most of the first, a change of algorithm left for later.

### Design notes and friction

* **A mutating method called on a class-typed field copies the object (performance finding).** The first version kept a
  `State` field in `Transfer` (`this.st.set(l, k, src)`, `this.st.killBorrows(x)`) and a `Worklist` field in `Fixpoint`
  (`this.work.add(s)`). The self-compile became **20 % slower** (median 11.20 s vs 9.34 s, minimum 10.21 vs 8.57, both
  compilers on the same tree): the verifier is about half of the self-compile, and gprof showed `orin_make_unique_slow`
  going from 2.9 M to 5.9 M calls, 2.7 M of them from `State.set` and 1.4 M from `Worklist.add` / `take`. A 30-line
  micro-benchmark confirms it: `this.inner.set(i, v)` copies the inner object *and its array* on every call (400,000 copies
  for 200,000 calls of a 1,000-element array), `this.a[i] = v` copies nothing. The generated code keeps the field's old
  value alive across the call, so the callee never sees a unique object. The fix keeps the hot state in the class that
  mutates it: `Transfer` owns `ls` / `holes` (`state()` packages them as a `State` at the boundaries) and `Fixpoint` owns
  its queue. Afterwards: 2.6 M copies, fewer than before the rewrite. The same pattern costs the lowering of step 3a
  copies too (`this.b.emit(..)`: 321,000 copies of the `BlockBuilder` per self-compile); a lowering of a mutating call on
  a field place via take / put (as `IArrayPush` on a field already does) would remove the trap for every class. That is a
  change to `lower/` and to the generated C, outside this step.
* **`Cx` stays for the optimiser.** `opt/calls.or` builds `Cx { prog, f, blk, ins, st, errs, warns }` and replays one
  instruction at a time; `step(cx, ins)` builds a `Transfer` from it, runs `Transfer.step` and returns its `state()`.
  `State` is a class with *public* `ls` / `holes` because the optimiser reads `s.ls[x].k`; the invariant is checked after
  `State`'s own methods only (public fields can be written around it, nothing does).
* **`old(this.ls)` of an array works** (`noRevival(old(this.ls), this.ls, ..)`): it is a snapshot, the copy-on-write copy is
  paid only by the contract-checked build.
* **Contracts on recursive data stay O(1) in invariants**: the class invariants are O(1) or O(holes); the O(locals) properties
  (`noRevival`, `borrowsFlat`, `killBorrows` leaving no alias) are `@Ensures` of the methods that change the state, and the
  O(function) ones (`isStable`, `reachClosed`, `isWellFormedFunction`) are on `Fixpoint.run` and `verify`, once per function.
* **`from` is still a keyword**: the parameter of `issuesAt` is `start`.
* **A predicate that is too strong for a quirk.** `holesEq` compares lengths and membership, so a hole set with a repeated
  entry (only a `take` of an already taken slot creates one, and that is an error already) can compare equal to a different
  set. The contracts say exactly what holds (`equals` ensures `this.leq(o)`, not set equality); behaviour is unchanged.
* **Shared predicates vs. an independent verifier.** The verifier must not trust the lowering; it does not: its own check
  (`wf.or`) stays, and the shared `mir/` predicate is only used in its *contracts* to state that the two agree.
* **A record invariant must cover what the producer emits, not what the comment says.** The comment on `CallSite.via` listed
  six kinds; the checker also emits `constructor` and `io:<op>`, and main (merged during the step) added `unresolved`. The
  first `isCallVia` would have trapped the contract-checked compiler on the first unresolved call (rule 6); the kinds were
  taken from the `addCall` sites, not from the comment.
* **Monitoring a background job**: `pgrep -f <script>` inside a monitor loop matches the monitor itself (the pitfall of step
  1 again); wait on the PID.

### Merges after the step: std:net, concurrency stage 0, the performance branch (MIR v1.10)

Two merges were done on top of the step, both into the new structure, with the same verdicts as the merged old verifier:

* **`origin/main` (d73f88a: std:net, concurrency stage 0).** Main had changed the record-threading verifier: net openers
  `BGrantNet` / `BGrantListen` / `BGrantConnect` / `BNetListen` / `BNetAccept` / `BNetConnect` and the closer `BNetClose` in
  `builtinStep`, `BTask(k)` dispatched by `taskOpOpensFrom` / `taskOpAdopts` (openers) and `taskOpMoves` (closer); in wf.or the net
  arms of `takesHandle` / `isOpenB`, `isAdoptB` and the adoption branch of `handleMsg`. Ported as arms of `Transfer.builtin`
  and the same arms in wf.or; `handleDefOk` (the contract "only an opener defines a handle") now also accepts an adoption,
  otherwise the contract-checked compiler would trap on std:task. Also: `grantTypeName` grew to eight names, which silently
  broke its `@Ensures((k < 6) == ..)` from this step (fixed to 8; it merged without a conflict). `verify_main` keeps every case
  set and sums them (`robustnessCases`, `spanCases`, ..., `netCases`, `taskGrantCases`).
* **The performance branch (MIR v1.10).** In/out receivers: `def` lets an inout function write parameter 0, an `ICall` of an
  inout callee re-defines its argument 0 as Owned, `TReturn` of an inout function requires an owned receiver in local 0 and
  consumes it, wf.or checks the call shape and that parameter 0 is owned; `IArrayExtend` has the rules of `IStrAppend`. All
  ported into `Transfer` / wf.or / `mir/wellformed.or` (`instrLocals`, `instrOperands`). One contract had to learn the new rule:
  an inout call defines a local that is not its destination, so `noRevival` now takes `defsOf(prog, ins)` (destination + in/out
  argument); with `dstOf` alone it would trap on an erroneous inout call. Its two verifier speed-ups:
  * *`def` skips `killBorrows` when the redefined local was Dead or a scalar* (the alias scan over all locals, the verifier's
    hottest loop): **still applies, ported.** The reason it is sound is now a stated precondition, `rootsLive` (no alias is
    rooted at a Dead or scalar local), required and ensured by `Transfer.run`.
  * *the join allocates nothing when nothing changes* (`joinChanged`): **still applies, ported** as `State.joinIfChanged`
    (`@Ensures(result.isNone() == this.join(o).equals(this))`); `Fixpoint.run` and `isStable` use it instead of `join` +
    `equals`.
  Neither is made unnecessary by the 3b restructuring: the copies that `Fixpoint` / `Transfer` remove (a mutating method called
  on a class-typed field) exist only in the class version and are a different cost; the perf branch's two speed-ups are about the
  algorithm and apply to both.

Gates on the doubly merged tree, against a baseline built from `origin/main` + the performance branch *without* step 3b
(`git merge-tree`, clean in `verify/`):

* verifier output byte for byte against the baseline's `verify_text` driver: **identical** on 49,521 programs of the
  `mutate_mir` corpus (now with the perf branch's two in/out mutation classes; 32,388 rejections) and the 4,000 Lean-fragment
  programs (3,114 rejections);
* `tools/mutate_mir.py`: 46,570 mutants, 32,388 rejected, 13,593 warned, 589 benign, **0 survivors**, 0 wrong-reason;
  `tools/diff_verifier_lean.py`: 4,592 both ACCEPT, 7,396 both REJECT, 12 divergences, all in the allow-listed class F6;
  `verify_main.or`: all cases pass (241: every set of main, the perf branch and this step, summed);
  `verify_test.or`: 26 `@Test` (3 new: an inout call's `defsOf`, `rootsLive` / `joinIfChanged`, `IArrayExtend`);
* generated code (C, C with `--check-contracts`, LLVM IR): 408 inputs x 3, **0 differences**; diagnostics
  (`tools/differential.sh compilers`): 1,432 inputs x 3, 0 differences;
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,890,058 bytes), conformance 141/141; all suites 832/832;
* `tools/test_compiler_contracts.sh`: contract-checked self-compile identical to `stage2.c`; suites 832/832 (one test,
  `std_http_basic`, hit the harness timeout at load 22 and passed on rerun: 1.7 s with contracts, 0.5 s without);
  `test_verify_contracts` 809 checks; **no contract fired**;
* `orin check --strict-contracts compiler/main.or`: **0 warnings** (the 13 `W0471` of `compiler/vc/` that main had are fixed:
  `@Ensures` on `Gen.next` / `declare` / `assert` / `lemma` / `setExact` / `taint` / `noteApprox` / `noteStr` /
  `useAssumption` / `newLoop` / `loopAdd` / `addObl` and `Tab.setCyclic`, each stating its effect; checked by
  `test_verify_contracts`);
* `tools/test_tooling.sh` and `tools/test_concurrency.sh` (`task_test` 98 checks, the stress and panic tests under the
  sanitizers): pass;
* self-compile instruction count (callgrind, `compile compiler/main.or`, both compilers on the final tree): baseline
  36,423,718,059, new **34,819,751,109 (-4.4 %)**; `killBorrows` 8.25 G -> 6.43 G (the `Transfer` method writes `this.ls` in
  place, the record version copied), the joins unchanged (`joinLs` 4.38 G in both, `join` 4.22 G, `joinIfChanged` 3.66 G).
  The verifier is still about 60 % of the self-compile: `killBorrows` with an index from a root to its aliases, and a join that
  stops at the first poisoned local, are the next algorithmic steps.

## Step 3d: `opt/` (the MIR optimiser), `cemit/` and `llvm/` (the code generators)

Rewritten: the optimiser `compiler/opt/` (nine files; every pass threaded parallel arrays through its block loop:
`out` / `sps`, `touched` / `rep`, `gone`, `hit`, the growing `locals`, and the inference kept its modes in the program it
was rewriting) and both code generators, `compiler/cemit/cemit.or` (676 lines) and `compiler/llvm/llvm.or` (1,163 lines),
which were one file each with a `Fx { prog, f, names }` record passed to every function. The exported surface is unchanged
(`optimize`, `pruneProgram`, `emitC`, `emitCSites`, `emitLlvm`; additions only). `compiler/mir/` was not touched; the
contracts use the shared structural predicates of step 3b in `mir/wellformed.or` (`isWellFormedFunction`,
`isWellFormedProgram`, `paramsWellFormed`, `spansAligned`, `blocksLocalsBelow`, `blockTargetsInRange`, `allReachable`,
`spansComplete`, `instrLocals`, `termLocals`): `fnWellFormed` / `progWellFormed` of the optimiser and `emittable` of the
emitters are those predicates. (The step was written on a base without 3b, against the same predicates in
`lower/wellformed.or`, and switched when origin/main was merged.)

The allocation-site census (`--stats-sites`, `cemit/sites.or`, merged from origin/main during the step) numbers the
`ORIN_SITE(n, ..)` marks across the whole program, the one program-wide counter of the C backend. Under rule 8 it moved
into the symbol step: `cSymbolsWith(prog, true)` fixes the first site id of every function (`CSymbols.firstSite`,
ensured by `sitesNumbered`: function i starts after all sites of functions 0 .. i-1, the numbering `siteTable` uses),
and `CFunctionEmitter.run` only reads it. The census output and the normal output are byte-identical to origin/main's
compiler (spot check below).

| Old | New |
|---|---|
| every block rewrite: `let out: Instr[] = []; let sps: Span[] = [];` pushed in step, `while (sps.length < out.length) sps.push(cs)` | class `BlockSink` (rewrite.or): `emit`, `emitAll`, `drop(n)`, `finish(term, span)`; spans in step by invariant |
| replacement plans as `touched: bool[]` + `rep: Instr[][]` (inplace.or, pairs.or) or `gone: bool[]` (calls.or), applied by a copy loop in each pass | class `RewritePlan`: `replace` / `remove` at most once per instruction, `apply(blk)`, `outLength()` |
| `locals.push(MLocal { name: "_", ty: MRef })` with the id taken from the length first | `Locals.fresh(ty)` of step 3a (lower/state.or), reused |
| parameter-mode fixpoint: three nested loops mutating `q.functions[fi].paramOwned[k]` of the program being built | class `ParamInference` (opt.or): sites, modes, pinned functions; `wants`, `run`, `stable`; the program is rebuilt once with the result |
| the edge blocks of the owned-parameter rewrite as `extra.push(..); nx = nb + extra.length - 1` (four copies) | class `EdgeBlocks` (params.or): `target(src, p, t, live)` |
| scalar replacement: `alias` / `counted` parallel arrays and the `while (alias[ai] != a) ai += 1; counted[ai] += 1` loop three times | class `RecordAliases` (pairs.or): `has`, `use`, `add`, `complete(cnt)` |
| `MFunction { name: f.name, paramCount: .., .. }` rebuilt at the end of every pass | `withBody(f, locals, blocks)` |
| C: `Fx { prog, f, names }` passed to 25 functions; `emitC` computed names and signatures inline | `CSymbols` (symbols.or, the program-wide table), `CFunctionEmitter` (function.or, one function); text.or (pure literal and name helpers); cemit.or (join) |
| LLVM: `Fx { prog, f, names, msgs }` passed to 29 functions; trap messages found with a linear `msgIndex` per trap | `LlvmSymbols` (symbols.or: function symbols, trap messages with a `Map` index, the runtime symbols the module declares), `LlvmFunctionEmitter` (function.or); runtime.or (prelude, declarations), text.or, llvm.or (join) |
| `c1` .. `c5` plus a 90-arm `match` that repeats the arity in the helper name | `runtimeCall(op)` (name and arity) and `callN` |
| index loops that answer a question about an array (`hasDup`, `hasConcat`, `usesFloat`, `entryHasPredecessor`, `termUsesAffecting`, `contains`, vtable lists, `successors`) | `some` / `every` / `includes` / `map` (rule 7); the per-instruction loops of the passes (`findRelease`, `findStore`, `readPath`, `usesAffecting`, the liveness fixpoint) stay loops: they are hot, exit early or index |

Files (`orin fmt` layout; the old files in the same layout for comparison: opt 2,710, cemit 717, llvm 1,264 lines; clauses
counted with `grep -c '^ *@Requires('` etc.):

| file | role | lines | requires | ensures | invariant |
|---|---|---|---|---|---|
| `opt/opt.or` (was 122) | driver, `ParamInference`, `inferModes`, `optimizeFunction` | 251 | 6 | 6 | 2 |
| `opt/rewrite.or` (new) | `BlockSink`, `RewritePlan`, `withBody`, `indices` | 181 | 6 | 10 | 3 |
| `opt/wellformed.or` (new) | pass predicates (`fnWellFormed`, `passKept`, `effects`, counts) | 267 | 0 | 0 | 0 |
| `opt/analysis.or` (was 274) | uses, defs, ancestors, counts, `tablesAgree` | 351 | 1 | 2 | 1 |
| `opt/calls.or` (was 294) | stage 2 (call-site dups), stage 3 (peephole) | 285 | 3 | 8 | 0 |
| `opt/params.or` (was 304) | owned-parameter sites, liveness, rewrite, `EdgeBlocks` | 395 | 4 | 11 | 3 |
| `opt/inplace.or` (was 504) | take/put of slots, `arrayextend` | 488 | 3 | 10 | 0 |
| `opt/chains.or` (was 336) | nested take/put chains | 327 | 2 | 4 | 0 |
| `opt/pairs.or` (was 627) | pair-return elimination, `RecordAliases` | 714 | 7 | 7 | 2 |
| `opt/prune.or` (was 122) | dead prelude functions | 149 | 1 | 2 | 0 |
| `cemit/cemit.or` (was 676) | `emitC`, `joinC`, `emittable` | 140 | 2 | 2 | 0 |
| `cemit/symbols.or` (new) | `CSymbols`, `signature`, `refsDeclared`, `namesDefined` | 262 | 3 | 4 | 2 |
| `cemit/function.or` (new) | `CFunctionEmitter`, operators, builtins | 535 | 7 | 3 | 2 |
| `cemit/text.or` (new) | types, literals, names, `refMask` | 244 | 1 | 6 | 0 |
| `llvm/llvm.or` (was 1,163) | `emitLlvm`, `joinLlvm` | 79 | 2 | 1 | 0 |
| `llvm/symbols.or` (new) | `LlvmSymbols`, `llvmRefsDeclared`, `globalsDefined` | 288 | 2 | 5 | 3 |
| `llvm/function.or` (new) | `LlvmFunctionEmitter` | 884 | 7 | 3 | 2 |
| `llvm/runtime.or` (new) | prelude, declarations, fixed messages | 234 | 0 | 0 | 0 |
| `llvm/text.or` (new) | types, attributes, globals | 134 | 0 | 1 | 0 |
| total, before -> after (with the three `module.or`) | | 4,431 (4,691 formatted) -> 6,248 | 0 -> 162 clauses (57 requires, 85 ensures, 20 invariants) | | |

Unit tests: `compiler/tests/opt_test.or` (17 `@Test`, 518 lines) and `compiler/tests/emit_test.or` (10 `@Test`, 333 lines),
run by `tools/test_tooling.sh`.

Classes (9 new): `BlockSink` (instructions and spans in step), `RewritePlan` (one replacement slot per instruction, the
change count never exceeds the block), `ParamInference` (one site row and one mode row per function; **no pinned function
has an owned parameter**), `EdgeBlocks` (every added block is `release p; goto t` with t an old block), `RecordAliases` (the
use counts are as many as the aliases, the record's own local first), `CSymbols` and `LlvmSymbols` (one symbol per
function, **the symbol index is as large as the symbol list, so no two functions share a symbol**; the trap-message index is
as large as the message list, the prelude's nine messages first), `CFunctionEmitter` and `LlvmFunctionEmitter` (the
function is one of the program and of the symbol table; its parameters are declared locals). The records `PLive`,
`PSites`, `Counts`, `Sra` got invariants (equal lengths; no sites collected for a parameter that cannot be owned; a plan
for every instruction).

### Contracts, and the bug each would catch

* **A pass keeps the program's behaviour visible in its shape** (`passKept`, on every pass): the result is well formed
  (locals declared, branch targets in range, spans in step), has the same name, parameters, parameter modes, in/out flag and
  result type, only appends locals, keeps every span and every block reachable when the input had them, and **makes the same
  calls and builtin calls in the same order** (`effects`, one key per `ICall` / `ICallIndirect` / `ICallVirtual` /
  `IBuiltin`; array concatenation excluded because `extendArrays` turns it into `arrayextend`). Catches a rewrite that drops,
  duplicates or reorders a call (mutant 2 below), a temporary that reuses an existing local id, a span lost on an inserted
  instruction. `fnWellFormed(p, f)` adds string, function and vtable indices; `optimize` requires and ensures
  `progWellFormed` and `sameFunctions` (same functions, names, parameter counts, `main`), and requires `allBorrowed` (what the
  lowering produces).
* **Instruction counts move only the way a pass claims**: `peephole` never increases the count and removes `dup`s and
  `release`s **in pairs** (`dup(f) + release(r) == dup(r) + release(f)`: a rewrite that drops a release and keeps its dup is
  a leak, the other way round a double free); `takePutChains` removes at least one instruction per rewrite
  (`instr(r) + (dup(f) - dup(r)) <= instr(f)`) and at least two getters; `takePutSlots` turns exactly one getter and one dup
  into make-unique and take per rewrite (`getter(r) + dup(f) == getter(f) + dup(r)`) and adds at most one instruction (the
  copy of a string literal); `extendArrays` replaces concatenations by `arrayextend` one for one (`concat + extend` is
  constant); `insertCallDups` only adds `dup` / `makeunique` (releases and blocks unchanged); `rewriteParam` only adds edge
  blocks (`onlyEdgeBlocksAdded`) and never removes a release.
* **The parameter-mode inference is a monotone fixpoint**: every round only flips borrowed -> owned (`modesGrew(old, new)`),
  `run` ensures `stable()` (another round would change nothing; catches a fixpoint that stops after one round, mutant 5), and
  the class invariant keeps every closure target and vtable entry borrowed (mutant 4). `scanSites` ensures that every
  recorded call site really passes the parameter at that position (`passesAt`), `paramLiveness` that the liveness equations
  hold (`livenessSolved`).
* **The analyses agree with each other**: `ancestors` ensures the alias relation is closed under the borrow edges
  (`ancestorsClosed`, mutant 11), and requires `tablesAgree`: the optimiser's use / definition tables (`instrUses`,
  `instrDef`, `termUses`) mention exactly the locals of the lowering's independent `instrLocals` / `termLocals`, so an
  instruction kind added to one table and not the other is a contract failure instead of a release moved over a use (mutant
  12; `analysisTablesAgreeOnEveryInstructionKind` checks every kind).
* **pairs**: `pairShape` ensures `sitesCoverReturns` (every `return` block has exactly one site and the site is the
  two-slot record with a reference first: a missed return would hand the record to a caller that reads it as the value);
  `convertCallee` requires it and ensures `convertedOk`; `planSra` ensures the plan touches only instructions after the call;
  `pairReturns` ensures `pairsKept` (only unpinned, non-`main` functions become in/out, every other signature is the same).
* **prune**: `prunedOk`: the result's function names are a subsequence of the input's that keeps every user function and
  `main` (a dropped user function would silently leave the verifier and the output; a reordering would renumber every
  `orin_fn_<i>_..` symbol).
* **Every emitted function name is unique**: the `CSymbols` / `LlvmSymbols` invariant `byName.size == names.length`;
  `fnSymbol(i, name)` ensures the `orin_fn_<i>_` prefix (two names that sanitize alike, `a.b` and `a_b`, still get two
  symbols; mutant 17), `sanitize` ensures an identifier of the same length.
* **The output refers only to declared symbols**: `emitCFunction` ensures `refsDeclared(text, syms)` (every `orin_fn_..`
  identifier outside string literals and comments is a function of the table, every `orin_s<k>` a string literal of the
  unit, every `orin_vt<k>` a vtable; mutants 18, 19); `emitLlvmFunction` ensures `llvmRefsDeclared` (every `@global` is a
  function, a trap message `@.m<k>`, a string, a vtable or a runtime function / prelude helper / intrinsic that the module
  declares or defines, found from the text of `declares()` and `prelude()`; mutants 20, 21, 22); `joinC` / `joinLlvm`
  ensure it for the whole unit, and also `namesDefined` / `globalsDefined`: every function, string literal, vtable and
  trap message the table numbers is defined in the unit (mutant 22: a join that leaves out the vtables). Together:
  **every string literal referenced is defined**, and so is every other symbol. `emittable` (required by `emitC` / `emitLlvm`) states the same on the
  MIR side.
* **Literals round-trip**: `cString` ensures `cStringValue(result) == s` and `llStr` ensures `llStrValue(result) == s`
  with decoders written independently of the encoders (a two-digit octal escape followed by a digit, an unescaped `?` that
  forms a trigraph, a hex digit in lower case are caught; mutants 14, 15); `commentSafe` ensures no `*/` survives (mutant 16).
* **Emitter preconditions** (what the verifier guarantees, stated where the emitter relies on it): a call of an in/out
  function has a local receiver (`inoutArgOk`: otherwise C gets `&orin_s0` and LLVM `ptr null`, which the callee writes
  through), every branch target is a block of the function (`targetsBelow`: an undefined label), a trap message has its
  global (`LlvmSymbols.message` requires `hasMessage`: the old `msgIndex` answered `msgs.length` for an unknown message, an
  undefined `@.m<n>`), the arity of a runtime call is covered by the arguments (`callN`).

To see that they can fail: 25 hand-made mutants of the new code (the ones named above, plus a
release search that ignores uses, the take/put to the wrong slot, a kept move after `arrayextend`, getters of a chain not
dropped, a pair callee not made in/out, pruning of user functions, a reference mask without the 64 limit, repeated trap
messages with a global each, and a counter threaded through the C functions) were run against `opt_test.or` /
`emit_test.or`: **25 / 25 killed**. The first run left two survivors, which is why
`anOwnedParameterIsReleasedOnTheEdgeWhereItDies` checks the `then` edge too and `analysisTablesAgreeOnEveryInstructionKind`
exists.

None of the contracts fired on the compiler's own sources, the conformance suites or the unit tests (below).

### Rule 8: per-function emission

Before: both emitters were already deterministic, but in one loop: the C emitter computed the symbol table and the
signatures inline and passed them in `Fx` to every function; the LLVM emitter numbered the trap messages in a separate pass
(`collectMsgs`) and looked each one up linearly. Nothing was threaded from one function to the next, but nothing said so
either, and the per-function step was not a function of its own.

Now each backend has three steps:

1. **`cSymbols(prog)` / `llvmSymbols(prog)`**: everything that is numbered across the program, in a fixed order: the
   function symbols `orin_fn_<i>_<name>` by function index; the C signatures; the trap-message globals `@.m<k>` (the nine
   fixed messages of the prelude, then every other `TTrap` message in function, block order, first occurrence wins, a `Map`
   index); the counts of string literals and vtables, whose numbers are those of the MIR (the lowering's string table,
   `MProgram.vtables`). The table is a class with invariants and is only read afterwards.
2. **`emitCFunction(syms, prog, i)` / `emitLlvmFunction(syms, prog, i)`**: the text of function i, a function of the table,
   the program (callee in/out flags) and i alone. Instruction temporaries in LLVM are named after their position
   (`%b<block>i<index>..`), block labels after the block index, C locals after the local index: no counter.
3. **`joinC` / `joinLlvm`**: header, globals, declarations, then the function texts in index order, then `main`.

`emitC` is `joinC(prog, syms, indices(n).map(i => emitCFunction(syms, prog, i)))`: the `map` is the place where ADR-0039
`.parallel()` goes. The unit tests `aCUnitIsTheJoinOfIndependentlyEmittedFunctions` and
`anLlvmModuleIsTheJoinOfIndependentlyEmittedFunctions` emit the functions last to first, put them in index order and compare
with the whole unit, and check that changing one function's body leaves the other functions' texts unchanged; mutant 24
(a counter threaded through the functions, as a comment) is killed by it.

The optimiser has the same split: the program-wide steps (closure targets, the parameter-mode fixpoint `ParamInference`,
and the pair shapes of stage 5) run first in function order; the per-function stage `optimizeFunction(q, p, i)` (stage 2
dups, owned-parameter rewrite, chains, slots, peephole) and the call rewrite of stage 5 read only those results and the
input program, and are `map`s over the function indices.

### Defects found and fixed

1. **A struct with more than 64 slots crashed the compiler.** The reference mask (`maskOf`, in both backends) kept the
   bit value at 2^63 from slot 63 on and added it for every further reference slot, so the second reference slot past
   slot 63 overflowed `usize`: `orin compile` of a record with 66 `string` fields ended in `trap: usize overflow` (a compiler
   crash, no diagnostic). The runtime only has 64 mask bits and `orin_struct_new` traps on more than 64 slots ("struct has
   more than 64 slots", a defined trap), so the mask now ignores slots from 64 on (`refMask`, shared by both backends; the
   mask of every struct with at most 64 slots is unchanged, so the output for every corpus program is byte-identical). Such
   a program now compiles and traps when the struct is built. Found by stating `refMask`'s contract against `maskAll(64)`;
   pinned by `referenceMasksOfLargeStructsDoNotOverflow` (mutant 13). A compile-time error for records and closures with
   more than 64 slots would be a language-visible change: **NEEDS_DECISION**, not done here.
2. **The LLVM backend could emit an undefined trap-message global**: `msgIndex` returned `msgs.length` for a message that
   `collectMsgs` had not collected, which `opt` rejects. No MIR reaches it today (both walk the same terminators), but the
   two lists could drift; `LlvmSymbols.message` now requires the message to be in the table and the table is a `Map`.
3. Not a defect of the output, a robustness gap: the C `builtinC` read `a[1]`, `a[2]` .. of a builtin's argument list without
   a check; `callN` now requires the arity (a builtin with too few operands would have trapped with an index error inside
   the emitter instead of a contract message naming the call).

### Behaviour preservation

All against the compiler bootstrapped from the base (this branch's merge of the performance branch and origin/main):

* **generated code**: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`,
  `examples/` and `bench/*/main.or` program (397 inputs x 3) **byte-identical**; `compiler/main.or` compiled by both
  compilers on the final tree: C (8,898,915 bytes), C with contracts (12,603,446) and LLVM IR (23,632,696) byte-identical;
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (8,898,915 bytes), conformance 141/141;
* all suites with `orin2` (C and LLVM backends): 816 / 816 with the C backend and 816 / 816 with the LLVM backend (`run_tests.py --suite all`);
* `tools/differential.sh` (build and run both, compare output): `--mode opt` 378 programs, 0 differences (4 skipped: the `--no-opt` side timed out on the loaded machine), `--mode llvm` 378 programs, 0 differences, `--mode builtins` 378 programs, 0 differences;
* `tools/test_compiler_contracts.sh`: **not completed locally** (the run was invalidated because the tree was edited during it; GitHub CI runs it). Checked earlier in the step: the contract-checked compiler self-compiles `compiler/main.or` to output identical to the normal compiler's (C and LLVM IR), and every unit test runs with contracts (`orin test`); **no contract fired**;
* `orin check --strict-contracts compiler/main.or`: no warning in the files of this step; the 13 `W0471` of `compiler/vc/` (`Gen`, `Tab`) are on the base too (step 3c fixes them);
* `tools/mutate_mir.py`: **not run locally** (left to GitHub CI); the verifier and the MIR are untouched by this step;
* `tools/test_tooling.sh` (with `opt_test` 17/17, `emit_test` 10/10): `opt_test` 17 / 17 and `emit_test` 10 / 10 run on their own; the full script was stopped (coordinator: CI is the gate) after the files before them had passed.
* `ci_local.sh` was not run (the coordinator replaced it by the gates above, and then by GitHub CI).
* The bootstrap, the byte-identity comparison, the suites and `differential` ran on the tree before the last two compiler
  changes of the step: the hot helpers of `opt/analysis.or` / `params.or` / `calls.or` returned to the loops of the base
  (performance only) and one `@Ensures` on `LlvmFunctionEmitter.run`. Those were checked with `orin check`, the formatter,
  `--strict-contracts` and `emit_test` (contracts on); the full gates on the final tree are GitHub CI's.

### Performance

Instruction counts (`valgrind --tool=callgrind`, deterministic; the machine was shared at load 8-20 on 4 cores, so wall
time is not a measurement), both compilers on the same final tree:

| | base compiler | new compiler | change |
|---|---|---|---|
| instructions, `orin compile compiler/main.or` | 36,443 M | 36,574 M | +0.36 % |
| of which `optimize` | 16,008 M | 16,089 M | +0.5 % |
| of which `emitC` | 768 M | 798 M | +3.9 % |
| of which the verifier | 15,869 M | 15,874 M | 0 |

The first measurement was +1.1 %: `some` / `includes` / `map` with a closure in the per-instruction and per-block helpers of
the inference (`blockUses`, `termUsesAffecting`, `contains`, `successors`, `ancestors` with an `Edge` record per edge) cost
170 M instructions in `scanSites` alone. Those helpers are back to loops (rule 7's exception for hot inner loops, with a
comment each); `borrowEdges` stays as the independent edge list of the `ancestorsClosed` contract. The rest of the
difference is the per-function `map` with its closure, the `BlockSink` / `RewritePlan` objects and the emitter class.

### Design notes and friction

* **The symbol table is a class that is only read.** `CSymbols` / `LlvmSymbols` are built by a free function and handed to
  every per-function emitter; the emitters never call a mutating method on them (3b's finding: a mutating method called on
  a class-typed field copies the object), and the emitters' own mutation is one `lines` array built in a local and stored
  once.
* **`Locals` from step 3a is reused** by four passes (`fresh(ty)` instead of `locals.push` after reading the length); the
  temporaries get the same ids as before.
* **No `export { x as y }`**: the two "refers only to declared symbols" predicates could not both be exported as
  `refsDeclared`; the LLVM one is `llvmRefsDeclared`.
* **`from` is still a keyword**: `EdgeBlocks.target(src, ..)`.
* **No index-carrying `map`, no `reverse`**: a per-function `map` is `indices(n).map(i => ..)` (`indices` exists in `opt`
  and in `cemit`; the LLVM backend imports the C one, together with `fnSymbol`, `refMask`, `emittable`, so the naming and
  the mask are stated once for both backends).
* **`charCodeAt` returns `int`**: the character-class helpers take `int`; mixing it with `usize` cursor arithmetic is E0400.
* **No `\u{..}` escapes** in string literals; the tests build bytes with `String.fromCharCode`.
* **A record invariant caught a test**: writing `blocks[0].instrs = [..]` without the spans trapped on `MBlock`'s
  `spans.length == instrs.length`; the test now replaces the whole block.
* **A replacement plan that may be written twice** (the old `rep[j] = ..` overwrote silently) is a `@Requires(!touched)`
  now; it never fires, which documents that the scalar-replacement plans of two calls in one block never overlap.
* **Long contract checks on large text**: `llvmRefsDeclared` on the whole 23 MB module of `compiler/main.or` is linear but
  makes the contract-checked LLVM self-compile about 2x slower than the C one; only the contract-checked build pays it.
* **The scratch directory was shared with other workers**: a baseline compiler at a generic path was overwritten by another
  worker during the step (detected by a checksum, all comparisons redone from a copy in a private directory).
* Rule 7 (array API): the predicates and the drivers use `map` / `some` / `every` / `filter` / `reduce` / `includes`; the
  per-instruction scans and the fixpoints stay loops.

## Step 1b: hardening `diag` and `loader` (more classes, more contracts)

Review finding after step 1: too few invariants and assertions, too few classes. Behaviour-preserving
(`tools/differential.sh compilers`: 1304 inputs x 3 modes, 0 differences; `stage2.c == stage3.c`; the
contract-checked compiler self-compiles to byte-identical C and passes all 713 conformance tests, no
contract fired; `ci_local.sh` green).

Contract clauses (`@Requires` + `@Ensures` + `@Invariant`, `grep -c`; lines without the generated
`embedded_*.or`):

| file | lines | clauses before -> after |
|---|---|---|
| diag/diag.or | 96 -> 211 | 11 -> 31 |
| loader/loader.or | 248 -> 338 | 5 -> 32 |
| loader/modules.or | 117 -> 164 | 0 -> 20 |
| loader/modgraph.or (new) | 0 -> 170 | 0 -> 10 |
| loader/path.or | 147 -> 186 | 6 -> 16 |
| loader/prelude.or | 43 -> 112 | 0 -> 5 |
| loader/program.or | 90 -> 187 | 0 -> 6 |
| loader/resolve.or | 123 -> 170 | 0 -> 23 |
| loader/sources.or | 31 -> 61 | 0 -> 10 |
| **total** | 905 -> 1621 | **22 -> 153** |

Classes: 2 -> 6. New: `Diagnostics` (collector, redundant counters tied to the list by invariants),
`ImportResolver` (was `resolveImport(src, ..., base)` + `privateModuleOf`), `SrcRoot` (module ids and
module existence under a src root, was `moduleOf(src, root, ..)` / `moduleExists` / `unknownModules`),
`ModuleGraph` (module edges + manifest rules + cycle check, was a record array and two methods of
`Loader`). `Sources` and `Loader` got stronger invariants (`Sources` tracks its keys in a list so that
"all keys normalized, no key lost to a duplicate" is checkable; `Loader` checks that `done` indexes
exactly the units, units are topological with unique normalized paths, open files are distinct and
not completed). Plain records stay records (`Span`, `Diagnostic`, `Unit`, `LoadedProgram`, ...): they
are built by literals in other modules, so their invariants are documentation plus the constructor
functions' contracts.

Properties now stated (each answers "which bug would this catch?"): diagnostic spans lie in the file
(`failedLoad`, `loadWithRoots`, `readManifest` require/ensure `allRenderable`); `render` output starts
with the path, names the right severity and contains every note; `lineCol` is 1-based and bounded by
the text; `normalizePath` results are normalized (no `..` in absolute results, never longer than the
input); `relativeTo` round-trips through `joinPath`; `isInside` of the root; resolved imports are
normalized `.or` paths or runtime modules, `std:fsraw` only from prelude code, errors are E0301 / E0302
at the import span; `Sources` overlay lookups return the first overlay value; the unit list is
topological, file ids are a permutation with the entry as file 0, paths and names are unique, prelude
units have the empty module id; the entry unit starts with one import per prelude root; every unit whose
path is in the overlay has the overlay text; the module graph is acyclic on success, checked by an
independent Kahn-style `isAcyclic` against `findModuleCycle` (an error exactly when the graph is cyclic);
prelude roots are well formed (virtual `$` paths, unique, entry is one of the files).

Tests: `compiler/tests/loader_classes_test.or` (19 `@Test`s) drives every new class and the predicates
on hand-built ill-formed values (a violated contract is a trap, so negative cases test the predicates).
Mutation check: storing an unnormalized key in `Sources`, or letting a duplicate overwrite the first file,
makes `sourcesOverlay` and `overlayTextReachesTheProgram` trap.

Selfcompile wall time (`orin2 compile compiler/main.or`, 12 interleaved runs after a warm-up, shared
machine): baseline compiler on the old tree median 4.90 s (4.47-5.69), new compiler on the new tree
median 4.90 s (4.39-5.68): no regression (contracts are erased in normal builds).

Friction found:

* Class invariants run only after non-private methods, and `Loader` has one (`run`), so its invariants
  are checked once per load, not per step; a failed `run` leaves `stack` non-empty, so "stack empty" can
  only be an `@Ensures` of the success path. Finer-grained checking would need more public methods.
* Record `@Invariant`s were not enforced in step 1, so `Diagnostic`, `Resolved`, `PreludeRoot` carry the property as
  documentation and as loop-based predicates (`allWellFormed`, `isWellFormedRoot`) repeated in
  `@Requires`. They are runtime-checked since ADR-0031 A3 (at literals, field writes and function results), which
  covers every module that builds `Diagnostic` by literal; the repeated `@Requires` can be dropped where wanted.
* Pure combinators in contracts would remove ~10 hand-written loops (`allRenderable`, `allNormalized`,
  `allDistinct`, `countWarnings`, `importersOf`, ...). Since ADR-0031 A4 `xs.every(p)` with a pure lambda is
  accepted; `allNormalized`, `allRenderable`, `allWellFormed`, `allWarnings`, `anyStrictCode`, `allUnbound` and
  `allUnitsWellFormed` were rewritten with `every` / `some` (the seed was refreshed for it). The counting and
  nested-loop helpers (`countWarnings`, `allDistinct`, `importersOf`) stay loops: there is no `count`, and the
  prelude has no pairwise combinator.
* Contracts cannot call I/O, so properties of `Sources.exists` / `read` against the disk are only
  expressible through a pure `overlay` accessor; `old(this.f.length)` works, but the checker rejects
  mixing `usize` with `? 1 : 0` (int) in a clause (split into two implications).
* A mutating method call inside `&&` / `||` operands of a test (`g.add(..).isOk() && g.add(..).isOk()`)
  is E0408; the unit tests need one statement per call.
* A contract that is too precise for a *propagating* private method fails in the first test that has a
  nested error (`importTarget` returns errors of the files it visits): state error properties only where
  the error is created.
* Still not statable: idempotence of `normalizePath`, and `isNormalized(p) == (normalizePath(p) == p)`:
  a self- or mutual call from a contract does not terminate under `--check-contracts` (tested instead).
