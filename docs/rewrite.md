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

* Clauses must be **pure**; the purity analysis follows calls and rejects any function that calls a
  *function value*. Therefore a helper used in a contract must be written with loops, not with
  `filter` / `map` / `every` (`isWellFormed`, `importCount`, `isNormalized`, `segments`,
  `allRenderable`). The nice closure style is for the code, loops for the predicates.
* A function must not call itself from its own contract (`@Ensures(f(result) == result)`): with
  `--check-contracts` the recursive call goes through the wrapper and never terminates. State the
  property structurally instead (`isNormalized(result)`) and test idempotence in a unit test.
* Record `@Invariant`s are type-checked but **not enforced at run time** (docs/contracts.md); the same
  property is therefore also an `@Requires` / `@Ensures` of the functions that build the value
  (`span`, `spanTo`). Class `@Invariant`s are enforced after every non-private method.
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
   that is a mechanical change, because a class `@Invariant` is checked after every non-private method and a record
   `@Invariant` is not checked at run time at all. A class whose only job is to keep arrays in step (`Captures`,
   `TScope`) still earns its keep: the invariant is the point. Keep invariants O(1) or O(depth); a method that
   mutates may state the O(n) property in its `@Ensures` instead.
2. **Every exported or non-trivial function has `@Requires` / `@Ensures` that state a real property:** lookup after
   bind returns the bound value, `open` / `close` change the depth by one, an index found in a table is in range and
   points at what was asked for, an index map is as large as its array, a resolved type refers only to ids that exist,
   a parallel-array argument has equal lengths, `declare` does not shrink the tables. Trivial one-liners (`isInt`)
   need none.
3. **Well-formedness helpers**: a small exported predicate written with loops (no closures, no `map` / `filter`, no
   self-call) that is reused in `@Requires`, `@Ensures` and `@Invariant` (`marksOrdered`, `noRepeats`, `typeInRange`,
   `isWellFormedEnv`, `sigOk`, `bindsKept`), like `isWellFormed` of the loader. Remember: a clause cannot call a function
   value, so `instKey` / `typesId` are loops although the code around them could use `map`.
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
* Record `@Invariant`s are not enforced, so `Diagnostic`, `Resolved`, `PreludeRoot` carry the property as
  documentation and as loop-based predicates (`allWellFormed`, `isWellFormedRoot`) repeated in
  `@Requires`; runtime-checked record invariants (at literals and field assignments) would remove that
  duplication and would have covered every module that builds `Diagnostic` by literal.
* Pure combinators in contracts would remove ~10 hand-written loops (`allRenderable`, `allNormalized`,
  `allDistinct`, `countWarnings`, `importersOf`, ...): `xs.every(p)` is rejected as a call through a
  function value. A purity rule that accepts closures whose body is pure (or prelude `every` / `some` /
  `count` marked pure) would help most.
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
