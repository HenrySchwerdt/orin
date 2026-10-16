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
executable once per selected test as a separate process (through the shell with a native monotonic
deadline, default 10 s, `--timeout 0` = explicitly unlimited) and records the exit status, stdout and stderr. A test that
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

## Concurrent code (std:task)

A test may start tasks (`scope` / `spawn`); everything a test starts is joined before the test function can return, so a hung
task is a timeout of the test, not a leak into the next one. Assertions work inside a task body (a failed `assert*` ends the process
with status 101, like in the main task: the test fails). Check **results**, not timing: join the handle or receive from a channel, and
assert on the values (the tasks of `tests/std/task_test.or` do). A trap in a task (`unwrap` of `None`, a violated contract) is
reported at its `join` or at the end of the scope as `task panicked: <message>`. Do not assert on the order of output of two tasks.
`movedCount()` / `copiedCount()` of `std:task` count what this task sent by move or by deep copy; whether a fresh value is moved depends
on the build (optimiser, contract checking), so pin it only in the default build (`tests/concurrency/move_counts.or`).

## Fast local loop and parallel tests

This section is about the repository's own test tools (`tools/`), not `orin test`.

**Iterate with `tools/dev.sh`.** It builds `build/dev/orin` from the current tree with *one* self-compile of
`compiler/main.or` by the existing `build/bootstrap/orin2` (by the seed compiler `orin0` if there is no `orin2`), with
the C at `-O1`, and then runs a subset with that compiler. The build is skipped when no input changed (the compiler
sources, everything they embed, the runtime and the building compiler; `build/dev/stamp`). A stale embedded std is
regenerated (`tools/embed_prelude.py`).

```bash
tools/dev.sh                          # build build/dev/orin only
tools/dev.sh test                     # conformance, all suites (or: default | next | all)
tools/dev.sh test tests/run/arith_basic.or  # one conformance test (or any substring of `run/name`, `next/errors/name`, ...)
tools/dev.sh std http                 # the std tests of one module (or a file; no argument: all)
tools/dev.sh tooling                  # tooling unit tests, LSP, MCP, OSIG, effects
```

**Required before a PR.** `build/dev/orin` is a stage-1 compiler: it does not show that the compiler reproduces itself.
Before a pull request run `tools/bootstrap.sh` (seed -> orin0 -> orin1 -> orin2 -> stage3, the fixed point
`stage2.c == stage3.c`, conformance) and the suites your change touches with `build/bootstrap/orin2` (`tools/ci_local.sh`
runs the whole Linux CI). `bootstrap.sh` builds orin0 and orin1 at `-O1` (`STAGE01_CFLAGS`) and orin2 at `-O2`
(`CFLAGS`): orin0 and orin1 compile the compiler only once, so the C compile at `-O2` costs more than it saves. The fixed
point compares generated C, not binaries, so it is unchanged; `STAGE01_CFLAGS="-O2 -w"` gives the old all-`-O2` build.
`sh tools/llvm_fixpoint.sh` (after `bootstrap.sh`, needs clang) is the same check for the LLVM backend: the LLVM-built compiler
must emit the same C and the same `.ll` as `orin2` (ADR-0038 gate 2; the CI `llvm` job runs it; `--deep` adds a third stage).

**Parallel cases.** Every test tool runs its independent cases in parallel, as many as there are CPUs; `-j N` or
`ORIN_JOBS=N` overrides it (`-j 1` = sequential). The output does not depend on `-j`: results are printed in the fixed
order of the sequential run, and failures are reported as before (the shell scripts stop at the first failing case in
that order). Parallel: `run_tests.py` (tests), `test_std.sh` (test files with and without contracts, expect-trap
tests), `test_tooling.sh` (unit test files and the resources / capabilities / net scripts; the guard for unwired unit
tests still runs), `mutate_std.py` (mutants, each in its own directory; also `--shard I/N`), `test_verify_contracts.py`
(the files; each runs in its own working directory because the verifier writes its solver queries to
`build/contracts-vc/`), `test_compiler_contracts.sh` (the self-compile check and the suite run at the same time).
`run_tests.py` compiles the runtime once per run instead of once per test (same flags; keyed by the sources). `tools/parallel.py`
is the shared helper. `test_lsp.py` and `test_mcp.py` are one protocol session each and `test_osig.py` / `test_effects.py`
take seconds, so they stay sequential; `--orin PATH` skips their compiler build.

**CI.** The `build` job caches `build/bootstrap/orin2` and `stage2.c` (`actions/cache`), keyed by the hash of
`compiler/`, `std/`, `array/`, `stdlib/`, `runtime/`, `platform/`, `seed/`, `tools/bootstrap.sh` and
`tools/embed_prelude.py`. A pull request with a hit skips the bootstrap (the conformance run it would do is covered by the
`sanitize` job: the same tests with the same compiler, under ASan + UBSan). An entry is only written after a full
bootstrap passed. A push to `main`, the nightly run and a manual run never read the cache: they always bootstrap from the
seed, so a cache cannot hide a broken fixed point on `main`. The http mutants run as three matrix jobs (`--shard`,
`tools/ci_changes.py`). The tooling job runs the LSP and MCP tests against `orin2` instead of building the same compiler
twice more.

## Execution deadlines

CLI tests and MCP program/unit tests use native POSIX process groups and a
monotonic deadline on macOS and Linux; no external `timeout` utility is needed.
Timeouts have exit code **-2** and reason `timeout` in unit-test reports. Ordinary
exit 124 remains `exit 124`. MCP program tests return `passed:false`, `exit:-2`,
`why:"timeout after 10 seconds"`; an expected exit comment cannot turn a timeout
into a passing test. Explicit CLI `--timeout 0` retains unlimited execution.

Bounded calls kill the child's process group and reap the direct child on normal
exit as well as timeout, including background children that remain in the group.
Descendants that deliberately change process groups are outside this cleanup;
this is a deadline facility, not a sandbox. OS scheduling and uninterruptible
kernel operations may delay termination. Compiler/linker time and output sizes
are not bounded by this per-execution deadline. Details and test evidence:
[ADR-0045](decisions/0045-portable-bounded-execution.md),
`python3 tools/test_execution.py` (includes independent Python safety deadlines).

## Targeted std oracle and backend checks in CI

The ordinary `std` job already runs every `tests/std/*_test.or` with contracts on/off through
`orin test` (C backend). The general LLVM conformance job covers `tests/run` and `tests/next/run`,
not those std `@Test` files. Encoding/JSON-number/JSON-value/JSON-decoder Python oracles and URL backend assertions therefore
have a separate selected path in [CI](../.github/workflows/ci.yml):

| Selected module | Checks, with benchmarks disabled |
|---|---|
| encoding | `tools/check_encoding.py --orinc build/bootstrap/orin2 --skip-bench`: vectors/test bodies plus independent Python codecs, C/LLVM contracts on/off, C ASan/UBSan |
| jsonnumber | `tools/check_jsonnumber.py --orinc build/bootstrap/orin2 --skip-bench`: vectors/test bodies plus deterministic Decimal/grammar oracle, C/LLVM contracts on/off, C ASan/UBSan |
| jsonvalue | `tools/check_jsonvalue.py --orinc build/bootstrap/orin2 --skip-bench`: independent tree/token/writer vectors and std test groups, C/LLVM contracts on/off, C ASan/UBSan |
| jsondecode | `tools/check_jsondecode.py --orinc build/bootstrap/orin2 --skip-bench`: independent structural/path vectors and std test groups, C/LLVM contracts on/off, C ASan/UBSan |
| url | `bench/url/check.py --orin build/bootstrap/orin2 --skip-bench`: vectors, malformed-input offsets and byte/query round trips, C/LLVM contracts on/off |

[The selector](../tools/ci_changes.py) enables the affected module for its tests or runner, plus known dependents of
changed sources/shared harnesses. Shared compiler/runtime/platform/seed/prelude inputs, bytes, bootstrap/embedding scripts,
the std test driver/assertion module, selector and CI workflow select all five.
JSON-number source selects number/value/decoder; JSON-value source or its Python harness
selects value/decoder (the decoder runner reuses that harness). UTF-8 source selects
value/decoder/URL; the config example selects decoder. A regenerated
embedded stdlib also counts as a shared compiler input. The selection is a stable ordered set.
Docs/editor-only PRs select none; pushes to main and scheduled/manual runs select all five as a
safety net. Existing mutation selection is unchanged; this does not add mutation coverage for these modules.

Linux reuses the bootstrap artifact in the `std-backends` job. Selected checks also enable the existing
macOS job and run against its native bootstrap, without attempting to execute a Linux compiler there.
Both paths pin Python 3.12, check for clang from the runner image, and pass the compiler path explicitly.
Each runner command has its existing 180-second subprocess deadline; each workflow step independently
has an eight-minute deadline, and the Linux job has a 25-minute cap. Errors and failed vectors fail the job.
No benchmark is run or compared against a timing threshold. Empty encoding/JSON-number/JSON-value/JSON-decoder test discovery
fails instead of silently dropping their test bodies. The runner defaults still include local benchmarks.

These are targeted regression checks, not a new all-stdlib LLVM matrix or implementation proof.
`python3 tools/ci_changes.py --selftest` checks module/dependency selection, docs exclusions and main's
full-selection behavior; run it when changing selection rules.
