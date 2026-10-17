# wc

A command-line tool in the style of `wc`: lines, words and bytes of standard input. It is a project to copy: a package with
several modules, flags, exit codes and unit tests.

```sh
$ printf 'hello world\nsecond line\n' | wc
      2       4      24
$ printf 'a b c\n' | wc -w
      3
```

| Option | Meaning |
|---|---|
| `-l`, `--lines` | newline bytes |
| `-w`, `--words` | runs of non-white-space bytes |
| `-c`, `--bytes` | bytes (not characters) |
| `-h`, `--help` | usage, exit 0 |
| `-` | read standard input (the default, and the only input) |

Flags combine (`-lc`); with none selected all three are printed, always in the order lines, words, bytes.

**Exit status.** `0` success (also `--help`), `1` a valid command line the tool cannot carry out (a file operand: see below),
`2` bad usage (unknown option; the usage line goes to stderr).

## What it shows

| File | Role |
|---|---|
| `src/options.or` | argument parsing into a `Parsed` union (`Run`, `Help`, `UsageError`, `Unsupported`); pure |
| `src/count.or` | the counting state machine, fed one byte at a time; pure |
| `src/format.or` | output formatting; pure |
| `src/main.or` | the only module with authority: `std:process` for the arguments, `std:io` for stdin, `exit` for the status |
| `tests/*_test.or` | unit tests of parsing, counting and formatting |
| `testdata/NAME.{in,args,out,exit}` | fixtures: stdin, arguments, expected stdout, expected exit status (default 0) |

The program touches no files, so it needs no file-system grant. For the same reason it does not take file operands:
`wc notes.txt` exits with status 1 and says so. `readBytes(stdio, n)` in `std:io` is all-or-nothing at end of input, so stdin is read
one byte at a time to keep the exact byte count (about 16 MB/s here, which is enough for an example; a buffered reader is the next step).

## Build, run, test

From this directory, with `orin` installed ([docs/getting-started.md](../../../docs/getting-started.md), [docs/cli.md](../../../docs/cli.md)):

```sh
orin test                       # unit tests
orin run -- -lw < testdata/basic.in
orin build                      # build/dev/wc
```

In a source checkout use `./tools/orin` instead of `orin`.

## CI

`python3 tools/test_example_projects.py --orinc build/bootstrap/orin2` builds the project, runs the unit tests, and runs the program
on every `testdata/NAME.in` with the arguments of `NAME.args`, comparing stdout with `NAME.out` and the status with `NAME.exit`.
