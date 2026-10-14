# Compiler rewrite process (ADR-0015)

How a module of `compiler/` is rewritten with the full language and contract clauses, as it was
actually done for the first two modules (`compiler/diag/`, `compiler/loader/`, the trial run). The
next modules (check, lower / opt / verify, backends, tooling) follow the same checklist.

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
4. **Fast unit tests** while rewriting: `orin test compiler/tests/<module>_test.or --runtime runtime`
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
python3 tools/diff_compilers.py $S/orin2_base build/bootstrap/orin2
```

`tools/diff_compilers.py` runs both compilers over every input of `tests/{errors,next/errors,parse_edge,run,next/run,
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
   inlining and fusion of pure `filter`/`map`/`reduce` chains into one loop (ADR-0038 §2). Until that optimisation
   has landed, keep hot inner loops of the compiler as loops. Measured before fusion: `filter → map → reduce` over
   5 M ints is about 4x slower than the loop. The self-compile time in the PR shows whether a change slowed the
   compiler down.

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
* **closures**: `registerLifted` ensures a new lifted function with `mode == 6` that points at its HIR,
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

* `tools/diff_compilers.py`: 1,396 inputs x 3 modes (`compile`, `check`, `check --format=json`), **0 differences**;
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

and through the batch driver (`verify_text`): `f:b0:i2: use of .. @0:78-89`. A function-level well-formedness error and MIR without spans keep the old text. Only a compiler bug triggers a verifier error, so no conformance input changes (`diff_compilers.py`: 0 differences).

Design notes and friction:

* **Classes are values.** `PlaceWalker` as a class over the builder was impossible (no shared mutable object), so the walk is a pure planner (temporaries as `base + k`) and the lowerer declares and emits its result. The same holds for `ownAll` / `args`, which are `Lowerer` methods because they emit.
* **One class, 1,300 lines.** A class cannot span files and `match` arms contain statements (mutual recursion), so expressions, statements and `match` stay in one class; everything that does not emit is outside (ops / place / values / wellformed).
* **Mutating methods that return a value.** Every `Lowerer` method that emits and returns (`expr`, `args`, `temp`, `dupOf`, `ownOp`, ...) is inferred mutating and returns `(self, result)` in the generated C: that pair is where the allocation is built (see the report of step 3a; lowering is about 5 % of the self-compile).
* **Statement style.** Mutating calls cannot stand in `&&` / `||` / `?:`; the lowerer is written in statements (`const v = this.expr(e);`); the call helpers use a `Callee` union instead of a lambda that builds the instruction.
* **Label numbers do not matter.** Labels are renumbered to block indices by `finish`, so labels are handed out on demand (`reserve(n)`); only the order of temporaries (local ids) shows in the generated code, and is unchanged.

Behaviour preservation (against the baseline compiler built before the step):

* `tools/diff_compilers.py`: 1,396 inputs x 3 modes, **0 differences** (diagnostics unchanged; the verifier message gains a location only for compiler bugs, so no input shows it);
* generated code: C, C with `--check-contracts` and LLVM IR of every `tests/run`, `tests/next/run`, `tests/contracts`, `examples/` program and of `compiler/main.or` (381 inputs x 3) **byte-identical** (spans never reach the emitters);
* `tools/bootstrap.sh`: `stage2.c == stage3.c` (6,617,344 bytes), conformance 141/141; `tools/test_compiler_contracts.sh`: contract-checked self-compile byte-identical to `stage2.c`, 804 / 804 conformance tests, **no contract fired**;
* `orin check --strict-contracts compiler/main.or`: 0 warnings;
* `tools/mutate_mir.py` (37,951 mutants: all rejected, warned or classified benign) and `tools/diff_verifier_lean.py` (6,000 programs with a synthetic span on every line, only the 4 allow-listed F6 divergences) pass;
* `tools/ci_local.sh` after merging origin/main: every step passed (sanitizer and LLVM suites, the four diff modes, formatter, tooling incl. `lower_test`, LSP, MCP, packages, OSIG, verify contracts, verify-all, erasure); the last step "provable std (tests+mutants)" hit the 4,000 s limit on the shared machine and was run as `tools/test_std.sh` (ok).

Selfcompile (`orin2 compile compiler/main.or -o /dev/null`, interleaved runs, both compilers on the same tree, the machine shared with two other workers): baseline compiler median 8.76 s (min 7.59), new compiler 9.49 s (min 7.83), +3 % on the minimum, +8 % on the median, inside the load noise (the same pair measured earlier: 7.70 s vs 7.69 s; front end `check` 0.87 vs 0.89 s; `mir --no-opt` 1.22 vs 1.27 s). Spans cost one `Span[]` per block and a pointer per instruction.

Rule 7 (array API): the loops of the lowering are the hot inner loops (`args`, `walk`, release loops, `BlockBuilder.finish`) or build several results in one pass, so they stay loops; the well-formedness predicates and contract helpers use `every` / `some` / `map` with pure arrow functions.

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
| total verify | | 1,489 -> 2,118 | 27 | 61 | 10 = **98 clauses (0 before)** |
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
* generated code (`tools/diff_compilers.py`-style comparison of C, C with `--check-contracts` and LLVM IR of every `tests/run`,
  `tests/next/run`, `tests/contracts`, `examples/` program and `compiler/main.or`): **390 inputs x 3, 0 differences**;
  diagnostics (`tools/diff_compilers.py`): 1,406 inputs x 3 modes, 0 differences;
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

## Step 1b: hardening `diag` and `loader` (more classes, more contracts)

Review finding after step 1: too few invariants and assertions, too few classes. Behaviour-preserving
(`tools/diff_compilers.py`: 1304 inputs x 3 modes, 0 differences; `stage2.c == stage3.c`; the
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
