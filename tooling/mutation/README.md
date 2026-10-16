# mutation

The Orin mutation checks: a port of `tools/mutate_std.py` and `tools/mutate_ox.py` (ADR-0047 phase 5). A mutant is a
one-line, deliberately wrong change of the code under test; a check is only worth its tests when every mutant is killed.

```sh
tools/mutation.sh std --orinc build/bootstrap/orin2 --module taskcore         # the provable std modules
tools/mutation.sh std --module http --shard 2/3 -j 4                           # a CI shard
tools/mutation.sh std --list
tools/mutation.sh ox --orinc build/dev/orin -j 2                               # the OX part of the compiler
tools/mutation.sh --unit-tests
```

`std` flags: `--orinc`, `--module bytes|utf8|collections|http|net|text|html|taskcore` (default: every module except `net`),
`--list`, `--shard I/N`, `-j/--jobs`, `--root`. `ox` flags: `--orinc`, `--cc`, `--list`, `--only NAME[,NAME]`, `-j/--jobs`,
`--root`. Details, differences from the Python scripts and the parity check: `docs/testing.md`, "Mutation checks".

Layout: `src/main.or` (flow, environment), `cli.or` (argparse-compatible options), `mutants_std.or` and `mutants_ox.or`
(the mutant tables), `std_check.or` (std modules: selection, shards, mutant directories, judging), `net_check.or` (`std:net`:
the compiler is rebuilt per mutant), `ox_check.or` (compiler mutants), `exec.or` (`std:task` workers), `text.or` (pure
helpers); `tests/*_test.or` are `@Test` unit tests. `tools/mutation.sh` builds it with the bootstrapped compiler into
`build/mutation/`.
