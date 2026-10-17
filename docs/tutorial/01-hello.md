# 1. Hello, world

This chapter runs a first program and shows the three ways to turn it into something that runs: `orin run`, `orin build`
and `orin init`.

## The program

<!-- file: examples/tutorial/01-hello.or -->
```ts
function main(): void {
  console.log("Hello from Orin!");
}
```

`main` is the entry point. `console.log` writes a line to standard output. Statements end with `;`, blocks use braces, and
every type is written explicitly where it matters (`: void` says that `main` returns nothing). If you know TypeScript this
reads like TypeScript, and that is deliberate.

Save it as `hello.or` (or use `examples/tutorial/01-hello.or`) and run it:

```sh
orin run hello.or
```

`orin run` compiles the program to a native executable and starts it. The progress messages go to standard error; the
standard output is only the program's:

<!-- file: examples/tutorial/01-hello.out -->
```text
Hello from Orin!
```

To keep the executable instead of running it, build it:

```sh
orin build hello.or -o hello
./hello
```

`orin build` without `-o` writes `build/dev/NAME`. `orin build --release` writes an optimised executable to
`build/release/NAME`. Repeating an unchanged build reuses the previous result.

Two more commands you will use all the time:

```sh
orin check hello.or      # type-check only, fast
orin fmt hello.or        # format the file in place (--check only reports)
```

## A project

A single file is fine for a short program. For anything larger, make a project:

```sh
orin init hello
cd hello
orin run
orin test
```

`orin init` creates `orin.toml` (the package manifest), `src/main.or` (the program above) and `tests/main_test.or` (a passing
test). Inside a project, `orin run`, `orin build` and `orin test` find the nearest `orin.toml` themselves. Chapter 9 builds a
project with several modules. The full list of commands is in the [CLI guide](../cli.md).

## What to remember

- A program is a set of top-level declarations; `main` runs first.
- Compile errors show the source line and a code such as `E0400`; `orin explain E0400` describes it.
- Everything in this tutorial is checked by the compiler on `main`; where a feature is not there yet, the tutorial does
  not use it.

Reference: [lexical structure](../reference/01-lexical.md), [grammar](../reference/02-grammar.md).

Next: [2. Values, types and functions](02-values.md).
