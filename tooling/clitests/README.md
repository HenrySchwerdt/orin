# clitests

The Orin CLI test harness: a port of `tools/test_osig.py` and `tools/test_fmt.py` (ADR-0047 phase 5). One package, two
subcommands, because both suites run the compiler as a child process and compare its output with files under `tests/`.

```sh
tools/clitests.sh osig [--orin PATH] [--update]
tools/clitests.sh fmt [--orin2 PATH] [--no-build] [--jobs N] [-v]
tools/clitests.sh --unit-tests
```

- `osig`: `orin graph` / `orin diff` of the compiler under test against `tests/osig/*.graph.json` and the structural
  expectations (determinism, evidence classes, acceptance, HTML, primitive I/O, task events, user annotations): 121 checks.
- `fmt`: builds `compiler/main.or` and `compiler/tests/parse_main.or` with `--orin2`, then checks `orin fmt` on the
  `tests/fmt` goldens and the corpus and `orin check --format=json` on `tests/errors`.

Output: `FAIL: <what>` (osig) or `FAIL <name>: <what>` (fmt) per failed check and the summary line of the Python scripts
(`N checks, M failures`; `pairs P, corpus C, json J: N passed, M failed`); exit status 0 all passed, 1 a check failed or the
run could not be completed, 2 usage. Details and the parity check: `docs/testing.md`, "CLI tests harness (Orin)".

Layout: `src/main.or` (flow, work directories, build), `cli.or` (argparse-compatible options), `ctx.or` (check log, captured
runs of the compiler), `osig.or` (the OSIG cases), `fmt.or` (jobs and verdicts of the formatter suite), `fmtlogic.or` (comment
multiset, AST spans, diagnostics: pure), `exec.or` (the process pool, shared design with `tooling/differential`), `jx.or`,
`text.or`, `strs.or` (helpers); `tests/*_test.or` are `@Test` unit tests of the pure helpers.
