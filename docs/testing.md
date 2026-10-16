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
that order). Parallel: `tools/conformance.sh` / `run_tests.py` (tests), `test_std.sh` (test files with and without contracts, expect-trap
tests), `test_tooling.sh` (unit test files and the resources / capabilities / net scripts; the guard for unwired unit
tests still runs), `tools/mutation.sh std` (mutants, each in its own directory; also `--shard I/N`) and `ox`, `test_verify_contracts.py`
(the files; each runs in its own working directory because the verifier writes its solver queries to
`build/contracts-vc/`), `test_compiler_contracts.sh` (the self-compile check and the suite run at the same time).
`run_tests.py` compiles the runtime once per run instead of once per test (same flags; keyed by the sources). `tools/parallel.py`
is the shared helper. `tools/protocol.sh lsp|mcp` is one protocol session each and `test_osig.py` / `test_effects.py`
take seconds, so they stay sequential; `--orin PATH` skips their compiler build.

**CI.** The `build` job caches `build/bootstrap/orin2` and `stage2.c` (`actions/cache`), keyed by the hash of
`compiler/`, `library/core/`, `library/collections/`, `library/std/`, `runtime/`, `bootstrap/seed/`, `tools/bootstrap.sh` and
`tools/embed_prelude.py`. A pull request with a hit skips the bootstrap (the conformance run it would do is covered by the
`sanitize` job: the same tests with the same compiler, under ASan + UBSan). An entry is only written after a full
bootstrap passed. A push to `main`, the nightly run and a manual run never read the cache: they always bootstrap from the
seed, so a cache cannot hide a broken fixed point on `main`. The http mutants run as three matrix jobs (`--shard`,
`tools/ci_changes.py`). The tooling job runs the LSP and MCP tests against `orin2` instead of building the same compiler
twice more.

## Conformance runner (Orin) and its Python oracle

The conformance suites (`tests/run`, `tests/errors`, `tests/next/*`; formats in `tests/README.md`) are run by
`tooling/conformance`, an Orin package (ADR-0047 phase 5). `tools/conformance.sh` builds it with the bootstrapped
compiler (never with the compiler under test) and runs it; the flags are those of the old script:

```bash
tools/conformance.sh --orinc build/bootstrap/orin2 --suite all            # default | next | all
tools/conformance.sh --suite next --filter ox -j 4 --backend llvm --sanitize --assert-facts --cc clang
tools/conformance.sh --unit-tests                                          # @Test tests of the runner itself
```

Same output, same exit status (0 pass, 1 failure or no match, 2 usage). `--root DIR` names the repository root (default: the
current directory; the Python script derives it from its location). Parallelism is `std:task`: one worker per `-j` slot
(default `$ORIN_JOBS`, else the CPU count, at most 128) takes tests from a channel and runs compile, C build and run through
`shellTimeout`, so each step has its own native deadline (compile and C build 120 s, run 10 s; a hung executable's process
group is killed). Workers return exit statuses; the main task reads the captured files and judges in test order, so the output
does not depend on `-j`.

Known differences from `tools/run_tests.py` (none changes a verdict on the repository): a signal-killed step is reported as
exit `-1` or `128+n`, not `-n`; a missing compiler is `sh`'s "not found" (exit 127) instead of "cannot execute"; stdout is
compared byte for byte (Python decodes with replacement and translates newlines of the expectation file); a `// warns:`
mismatch is reported without skipping the (then wasted) build step; the unified diff is an exact LCS diff, which equals
`difflib` on every case of the suites; `--root`, `--orinc` relative paths are relative to the root as before. The language has no
environment access, so `$ORIN_JOBS` and the CPU count come from one shell command.

**Why the Python script stays.** ADR-0047 section 3: the self-hosted compiler must not be its only judge. `tools/run_tests.py`
is the independent oracle (also still used by `orin mcp`). `tools/check_conformance_parity.py` runs
both over `--suite all` for the C and LLVM backends (`--sanitize` optionally), over a tree of deliberately broken tests (wrong
expected output, missing expectation, wrong exit status, compile failure, wrong or missing error code, wrong `// warns:` /
`// stderr:`, a hanging executable) and over the command line, and requires identical output and exit status. The CI job
`conformance-parity` runs it on every change, so the two cannot drift. All other CI jobs use the Orin runner.

## Mutation checks (Orin)

The mutation checks are `tooling/mutation`, an Orin package (ADR-0047 phase 5); `tools/mutation.sh` builds it with the
bootstrapped compiler (never with the compiler under test) and runs it. It replaces `tools/mutate_std.py` and
`tools/mutate_ox.py`; the flags, the mutants (same operators, same order, same count per module and shard), the result lines
and the exit status (0 all killed, 1 a mutant survived, 2 a broken mutant) are those of the scripts:

```bash
tools/mutation.sh std --orinc build/bootstrap/orin2 --module taskcore      # bytes|utf8|collections|http|net|text|html|taskcore
tools/mutation.sh std --module http --shard 2/3 -j 4                        # the CI matrix runs every module and shard
tools/mutation.sh ox --orinc build/dev/orin -j 2                            # the OX part of the compiler (33 mutants)
tools/mutation.sh --unit-tests                                              # @Test tests of the tool (mutant tables, shards, options)
```

`std` copies the std modules and the test files of the module to `build/mutate_std/<module>_<mutant>/`, rewrites the std
imports to relative ones, applies the mutation and runs `orin test` with and without `--no-contracts`; `net` rebuilds a copy of
the compiler per mutant (its module imports the internal `std:fsraw`). `ox` builds the compiler with each mutant of the OX
lexer, parser and checker and runs the OX conformance tests (`tests/next/{run,errors}/ox_*`) with it. Parallelism is
`std:task`: one worker per `-j` slot (default `$ORIN_JOBS`, else the CPU count) runs the shell steps of a mutant through
`shellTimeout` (900 s per run, 120 s for `http`, 120 s for the `net` tests), so a hung mutant is a failing test and its process
group is killed; the main task reads the outputs and judges in mutant order, so the lines do not depend on `-j`.

Differences from the scripts (none changes a result on the repository): the result lines of a run are printed when all its
mutants are done, not one by one; `--root DIR` names the repository root (default: the current directory); `$ORIN_JOBS`, the CPU
count and `$CC` come from one shell command; a signal-killed run is exit `-1` or `128+n`, not `-n`; `ox` judges with
`tools/conformance.sh` (the Orin runner) instead of `tools/run_tests.py`, in a private root per mutant (links to `tests/` and
`runtime/`), so the mutants may run in parallel without sharing `build/tests`; a failing copy or `tools/embed_prelude.py` of a `net`
mutant is a COMPILE ERROR (the script raised an exception). `tools/embed_prelude.py` (Python) is still what regenerates the
embedded library of a `net` mutant's compiler copy. `tools/mutate_mir.py` and `tools/contract_mutation.py` are separate tools
and unchanged.

## Differential harness (Orin)

The differential tests of compiler modes and of two compilers are `tooling/differential`, an Orin package (ADR-0047 phase 5; it
replaces `tools/diff_backends.py` and `tools/diff_compilers.py`). `tools/differential.sh` builds it with the bootstrapped compiler
(never with the compiler under test) and runs it; the flags, output and exit status are those of the old scripts:

```bash
tools/differential.sh --mode opt|llvm|builtins|fuse [--orinc COMPILER] [--cc CC] [--filter SUBSTR] [--sanitize] [--shard I/N] [--list]
tools/differential.sh compilers BASE_ORIN NEW_ORIN     # diagnostics of two compilers, byte for byte
tools/differential.sh --unit-tests                     # @Test tests of the harness itself
```

Each program of `tests/run` and `tests/next/run` (names of the latter start with `next_`) is compiled with the default pipeline and
with the alternative (`opt`: `--no-opt`; `llvm`: `--backend=llvm`, built with clang -O2 and the LLVM shim; `builtins`:
`--c-builtins`; `fuse`: `--no-fuse`), both are built and run, and exit status and stdout are compared (a failing compile or C
build is compared by its first 300 bytes of error output). A program for which exactly one side timed out is reported as `SKIP` and
is not a difference. `--shard I/N` runs every N-th program (after `--filter`) starting at the I-th, so the CI shards of the fuse run
together run every program once; `--list` prints the selected names. Exit status: 0 no difference, 1 differences, 2 usage.
`compilers` runs both compilers over every input of `tests/{errors,next/errors,parse_edge,run,next/run,contracts}`, every package
directory under `tests/` and `compiler/main.or` (`compile X -o /dev/null`, `check X`, `check --format=json X`) and compares exit
status, stdout and stderr. Execution is `std:task`: one worker per CPU (four for `compilers`) takes jobs from a channel and runs
the steps through `shellTimeout` (compile and C build 120 s, run 10 s, `compilers` 300 s); stdout is compared with `cmp` on the
captured files, so the output does not depend on the number of workers. `--root DIR` names the repository root (default: the
current directory). Differences from the Python scripts: a signal-killed step is exit `-1` or `128+n`, not `-n`; a program's
stdin is `/dev/null`; the byte slice of stderr in a `compilers` DIFF line is cut on a character boundary.

## Protocol harness (Orin)

The end-to-end tests of the language server and the MCP server are `tooling/protocol`, an Orin package (ADR-0047 phase 5; it
replaces `tools/test_lsp.py` and `tools/test_mcp.py`). `tools/protocol.sh` builds it with the bootstrapped compiler (never
with the compiler under test) and runs it; the flags, `FAIL: ...` lines, summary and exit status are those of the old scripts:

```bash
tools/protocol.sh lsp --orin build/bootstrap/orin2     # orin lsp over stdio: 104 checks
tools/protocol.sh mcp --orin build/bootstrap/orin2     # orin mcp over stdio: 191 checks
tools/protocol.sh lsp|mcp [--orin2 build/bootstrap/orin2]   # without --orin: builds compiler/main.or into build/protocol/<suite>/orin first
tools/protocol.sh --unit-tests                          # @Test tests of the pure helpers (framing, positions, JSON paths, options)
```

Every case of the Python scripts exists with the same requests, expected responses and `check` messages in the same order, so
the number of checks is the same (104 and 191) and a failing compiler fails the same checks. The language has no API for a child
process with pipes (`std:io` has `shell` and `shellTimeout`, which run a command to completion), so the harness starts the server
in the background through the shell with stdin on a named pipe and stdout on a file, writes each message with `cat` and polls the
file for complete frames (`Content-Length` frames for LSP, lines for MCP). Because a mutating method needs a `let` receiver, the
session state (request id, read offset, notifications, check log) lives in small files of a private temporary directory. Handling
of a server that dies: the run stops with the server's stderr and exit status 1 (the Python scripts end with a traceback).
Differences from the Python scripts: the "got ..." part of a `FAIL` line shows the JSON of the value, not the Python `repr`.

Parity was established by running both implementations against the same compiler (`orin2` of the same commit): both pass with
104 and 191 checks; and against a deliberately broken compiler (a copy of `compiler/` with the `implementationProvider`
capability removed, the effect summary text changed, `mutates` inverted and the "outside the authorized root" message changed):
both fail the same two LSP checks and the same eleven MCP checks.

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
