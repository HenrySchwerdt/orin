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
