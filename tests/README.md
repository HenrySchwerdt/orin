# Orin conformance tests

Run everything with

```
python3 tools/run_tests.py --orinc build/bootstrap/orin2 [--cc cc] [--filter substr] [--jobs N] [--sanitize]
```

The tests are written against the language contract (`docs/bootstrap-subset.md`), not
against any one implementation, so the same suite is run against every compiler stage.
The runner is always invoked from anywhere; tests execute with the repository root as the
working directory (so `std:fs` tests use paths like `build/tests/tmp_<name>.txt`).

`--suite next` runs `tests/next/run` and `tests/next/errors` instead (same formats, language
beyond Orin-B such as generics; only the self-hosted compiler is expected to pass them);
`--suite all` runs both. The default is `tests/run` + `tests/errors`.

## Compiler interface

`<compiler> compile <entry.or> -o <out.c>` must exit 0 on success. On failure it exits
non-zero and prints diagnostics `path:line:col: error[CODE]: msg` on stderr. The generated C
is built with

```
cc -O1 -w -I runtime/core <out.c> runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -o <exe>
```

(`--sanitize` adds `-fsanitize=address,undefined -fno-omit-frame-pointer` and runs the
executable with `ASAN_OPTIONS=detect_leaks=0`). Build products live under `build/tests/`
(gitignored). Each executable has a 10 s timeout.

## `tests/run/` - programs that must compile and run

* Single file: `name.or` with expected stdout in `name.out`.
* Multi-file: directory `name/` with `main.or` (the entry) and `expected.out`, plus any other
  modules.
* Optional first line of the entry file: `// exit: N` expects exit status `N` (default 0).
  Traps exit with status 101; stdout produced before the trap must still match exactly.
* Stdout is compared byte for byte. stderr is ignored.

## `tests/errors/` - programs that must be rejected

* Single file: `name.or` whose first line is `// error: E0xxx`.
* Multi-file: directory `name/` with `main.or` (carrying the header) plus the other files.
* The compiler must exit non-zero and its stderr must contain the code (e.g. `E0302`).
  Message text and positions are not checked. Each test contains one intended error and
  otherwise valid code (including a `main`, except for E0412 tests).

## Runner output

A per-category and total `passed/failed` summary; for each failure the diff head (stdout
mismatch), exit status, or compiler/C stderr head. Exit status is non-zero if any test fails.

## Headers for `tests/next`

Beyond `// exit: N`, the leading `//` comment lines of a test may contain `// flags: --check-contracts`
(extra compiler flags, ADR-0012), `// stderr: text` (the run's stderr must contain `text`; for an error test the compiler's stderr, which pins the text of a message) and `// warns: W0450 W0452` (the warning codes of the compile, as a multiset, must be exactly these; `// warns: none` for no warning; ADR-0028).
`tests/contracts/` holds inputs for `tools/test_verify_contracts.py` (`orin verify --contracts`,
needs z3): expected results are given as `// expect: <function> <kind> <STATUS>` lines.

## Packages

`tests/next/run/package_modules/` and `tests/next/errors/e05*/` are multi-file tests whose
directory carries an `orin.toml` with `entry = "main.or"` (so the runner's `main.or` convention
works); the loader finds the manifest from the entry file. `tools/test_packages.sh` tests the
default layout (`tests/next/packages/shop`, entry `src/main.or`), package-directory arguments,
`orin check --deps` and `orin api [--check]`.

## Built-in annotations (ADR-0024)

`tests/next/run/annotations_*.or` and `tests/next/errors/e044*.or` are ordinary conformance cases.
`tests/next/orin_test/` holds the fixtures of `orin test` (passing, failing, trapping, hanging tests, a
package directory with tests in several modules); they are driven by `tools/test_annotations.py`, not by
`run_tests.py` (some of their tests fail on purpose). `tools/test_annotation_erasure.py` compiles
`annotations_test_*.or` with and without their `@Test` functions and requires identical C and LLVM IR.

## Concurrency (ADR-0017 stage 0)

`tests/next/run/task_*.or` and `tests/next/errors/e048*.or` (+ `e0450_channel_of_grant`, `e0301_task_primitives_are_internal`) are
ordinary conformance cases that run in every backend mode; they print only values that do not depend on timing or on the optimiser.
`tests/concurrency/` holds the stress tests (thousands of tasks, tens of thousands of messages) and `move_counts.or`, which pins
what the *default* build moves and copies; they are driven by `tools/test_concurrency.sh` (plain, ThreadSanitizer, ASan + UBSan,
no object live at exit), not by `run_tests.py`. `tests/std/task_test.or`, `taskcore_test.or` and `tests/std/expect_trap/task_*.or`
run with `tools/test_std.sh`; `tests/osig/tasks` is checked by `tools/test_osig.py`.
