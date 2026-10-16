# differential

The Orin differential harness: a port of `tools/diff_backends.py` and `tools/diff_compilers.py` (ADR-0047 phase 5). For every
program of `tests/run` and `tests/next/run` it compiles with the default pipeline and with an alternative, builds and runs both
and compares stdout and exit status; `compilers` compares the diagnostics of two compilers byte for byte.

```sh
tools/differential.sh --mode opt            # optimised MIR vs --no-opt
tools/differential.sh --mode llvm           # C backend vs --backend=llvm (needs clang)
tools/differential.sh --mode builtins       # Orin std prelude vs --c-builtins
tools/differential.sh --mode fuse --shard 1/3
tools/differential.sh compilers build/old/orin2 build/bootstrap/orin2
tools/differential.sh --unit-tests
```

Flags: `--mode` (required), `--orinc`, `--cc`, `--filter`, `--sanitize`, `--shard I/N`, `--list`, `--root`. Details:
`docs/testing.md`, "Differential harness (Orin)".

Layout: `src/main.or` (flow, summary), `cli.or` (argparse-compatible options, shards), `suite.or` (discovery, commands, verdicts),
`compilers.or` (the `compilers` command), `exec.or` (`std:task` workers), `text.or` (pure helpers); `tests/*_test.or` are `@Test`
unit tests. `tools/differential.sh` builds it with the bootstrapped compiler into `build/differential/`.
