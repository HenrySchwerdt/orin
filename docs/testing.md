# Testing with `@Test` and `orin test`

Decision and rationale: [ADR-0024](decisions/0024-builtin-annotations.md). Example: `examples/testing.or`.

```typescript
import { assertEq } from "std:test";

function clamp(x: int, lo: int, hi: int): int { ... }

@Test
function clampKeepsValuesInRange(): void {
  assertEq(clamp(42, 0, 10), 10, "above");
}
```

```
orin test <file.or | package-dir> [--filter <substring>] [--format=json] [--timeout <seconds>]
          [--no-contracts] [--runtime <dir>] [--cc <cmd>] [--out-dir <dir>] [--keep]
```

## Writing tests

* A test is a top-level function `@Test function name(): void` — no parameters, not generic (E0443
  otherwise). The one exception: `@Test function name(host: Host): void` receives the `Host` (ADR-0027) so that a test
  can derive the grants it needs (`useFs(host, fs => ...)`); a test without it has no I/O authority. It may be `export`ed or private, in any module of the program.
* A test **fails by trapping**: a failed assertion of `std:test`, an index out of bounds, `unwrap` of
  `None`, a violated contract (tests run with runtime contract checking, ADR-0012; `--no-contracts`
  turns it off), a non-zero `exit`, a crash, or exceeding the timeout. Returning normally passes.
  `Result`-returning tests are not part of 1.0 (E0443 rejects them).
* `std:test` (import explicitly): `assert(cond, msg)`, `assertEq(actual, expected, msg)` for `int`,
  `assertEqUsize`, `assertEqString`, `assertEqBool`, `assertNear(actual, expected, tolerance, msg)` for
  floats, `fail(msg)`. A failure prints `trap: assertion failed: <msg>` / `trap: assertEq failed: <msg>:
  expected 3, got 2` on stderr and exits 101. One `assertEq*` per type: Orin has no generic equality.
* Tests are type-checked with the rest of the program — also by `orin check` and `orin compile` — so
  they cannot rot. Calling a test function or using it as a value is E0445.
* A test file needs no `main`; if the entry module has one, `orin test` does not run it.
* In `orin compile` / `mir` / `verify` the tests are **erased**: not emitted, nothing they use is
  emitted either; the generated code is byte-identical to the program without them
  (`tools/test_annotation_erasure.py`).

## Discovery

`orin test X` loads the program rooted at `X` exactly like `orin check X` (a `.or` file, or a package
directory whose entry is `src/main.or`) and finds the `@Test` functions of **every loaded user module**,
dependencies first, source order inside a module. A module nothing imports is not loaded, so its tests
are not found: point `orin test` at the test file itself (`orin test tests/shop_test.or`, which imports
the code it tests) or at an entry that imports it. Test ids are `<module>.<function>` where the module
is the path relative to the entry file's directory without `.or` (`mathx/add.testAdd`); the same
function name in two modules is fine. `--filter S` runs the tests whose id contains `S`.

## How tests run (isolation)

`orin test` builds **one** executable: the tests are renamed and exported, the entry module's `main` is
replaced by a dispatcher that runs the test whose index is `argv[1]`. The runner starts that
executable once per selected test as a separate process (through the shell, with `timeout(1)` when it
exists, default 10 s, `--timeout 0` = none) and records the exit status, stdout and stderr. A test that
traps, exits, crashes, hangs or corrupts state therefore cannot affect any other test. The build
directory is `/tmp/orin-test-N` (removed afterwards; `--out-dir DIR` builds in `DIR` and keeps it,
`--keep` keeps the temporary one).

The C runtime is found at `./runtime` (a checkout) or `--runtime <dir>`; the packaged `orin` launcher
passes its own and honours `$CC`. `--cc` takes a command with flags, e.g.
`--cc "cc -fsanitize=address,undefined"` (set `ASAN_OPTIONS=detect_leaks=0`).

## Output

Text (stdout; diagnostics and warnings go to stderr):

```
PASS mathx/add.testAdd
FAIL mathx/add.testAddFails (trap, exit 101) src/mathx/add.or:13:10
     stderr: trap: assertEq failed: mathx: this one fails: expected 3, got 2
PASS main.testAdd
4 passed, 1 failed
```

Failing tests show their captured stderr and stdout (truncated); passing tests' output is hidden. The
reason is `trap` (exit 101: assertion, bounds error, contract...), `timeout`, `crash` (signal, exit
>= 128) or `exit N`. The last line counts passed, failed and (with `--filter`) `N filtered out`;
`no tests found (annotate functions with @Test)` when there are none.

`--format=json` prints **one line**, key order fixed, no timings (so two runs of unchanged code print
identical bytes):

```json
{"ok":false,"total":5,"passed":4,"failed":1,"filtered":0,
 "tests":[{"id":"mathx/add.testAdd","unit":"mathx/add","name":"testAdd","file":"src/mathx/add.or","line":8,"col":10,"status":"pass","exitCode":0},
          {"id":"...","unit":"...","name":"...","file":"...","line":13,"col":10,"status":"fail","exitCode":101,
           "reason":"trap","stdout":"","stderr":"trap: assertEq failed: ..."}],
 "warnings":[{"code":"W0440","severity":"warning","file":"...","line":..,"col":..,"endLine":..,"endCol":..,"message":"...","notes":[]}]}
```

`file`/`line`/`col` locate the test's name (1-based). `reason`, `stdout`, `stderr` (each truncated to 2000
bytes) only exist for failed tests. Compile errors are printed as the one-JSON-object-per-line
diagnostics of `orin check --format=json` (exit 1); an internal failure (the C compiler failed) as
`{"ok":false,"error":"..."}`.

**Exit status:** 0 every selected test passed (or none exist), 1 a test failed / the program does not
compile / the C compiler failed, 2 usage error.

## MCP

`orin mcp --allow-exec`: the `test` tool with `{"entry":"tests/shop_test.or","unit":true,"filter":"cart"}`
returns the same JSON report (docs/mcp.md).

## `@Deprecated` and `@Inline` in short

* `@Deprecated("use other()")` on a function, method, class, type declaration, interface or interface
  method: every use from *another* declaration gives `warning[W0440]` (not inside the declaration itself,
  not inside another deprecated declaration, not in an import list). Warnings never fail a build; they go
  to stderr (`--format=json`: stdout objects with `"severity":"warning"`). The LSP publishes them with
  severity warning and the `Deprecated` tag, hover shows `@Deprecated(...)`, and `orin api --check`
  reports adding or removing the annotation as an API change.
* `@Inline` on a function or method: backend hint (`static inline` in C, `alwaysinline` in LLVM IR);
  behaviour is identical. An `@Inline` function that is part of a call cycle is E0444.
* Formatting: each annotation on its own line above the declaration, in the order written, followed by
  the contract clauses.

## Limitations (1.0 core)

No `Result`-returning tests, fixtures (`@Before`/`@After`), parameterised tests, parallel execution,
coverage, `--list`, or per-test timeouts; modules nothing imports are not discovered; the test
executable is always built with the C backend (`-O1`).
