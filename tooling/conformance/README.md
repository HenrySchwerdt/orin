# conformance

The Orin conformance test runner: a port of `tools/run_tests.py` (ADR-0047 phase 5). It compiles every test of
`tests/` with the compiler under test, builds the output with a C compiler, runs it and checks the output, exit status,
diagnostic code, warnings and stderr named in the test header (`tests/README.md`).

```sh
tools/conformance.sh --orinc build/bootstrap/orin2 --suite all
tools/conformance.sh --suite next --filter ox -j 1 --backend llvm
tools/conformance.sh --unit-tests
```

Flags: `--orinc`, `--cc`, `--filter`, `-j/--jobs`, `--sanitize`, `--suite default|next|all`, `--backend c|llvm`,
`--assert-facts`, `--root`. Details, differences from the Python script and the parity check: `docs/testing.md`,
"Conformance runner".

Layout: `src/main.or` (flow, summary), `cli.or` (argparse-compatible options), `suite.or` (discovery, commands),
`exec.or` (`std:task` workers), `judge.or` (verdicts), `headers.or` and `text.or` (pure helpers); `tests/*_test.or` are
`@Test` unit tests. `tools/conformance.sh` builds it with the bootstrapped compiler into `build/conformance/`;
`tools/check_conformance_parity.py` compares it with `tools/run_tests.py`, the independent oracle.
