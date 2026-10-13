# Orin conformance tests

Run everything with

```
python3 tools/run_tests.py --orinc bootstrap/target/release/orinb [--cc cc] [--filter substr] [--jobs N] [--sanitize]
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
cc -O1 -w -I runtime <out.c> runtime/orin_runtime.c -o <exe>
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
