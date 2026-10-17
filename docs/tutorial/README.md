# The Orin tutorial

A step-by-step introduction to Orin for someone who has just installed it (`brew install orin-lang/orin/orin`, or one of the
other routes in [install.md](../install.md)). Each chapter is short, builds on the one before, and has a complete program
you can run. You should know one other language; if that language is TypeScript, read
[Orin for TypeScript developers](../ts-developers.md) alongside this tutorial, because Orin looks like TypeScript and
behaves differently in the places that matter.

Check that the tools work:

```sh
orin --version
orin doctor
```

## Chapters

1. [Hello, world](01-hello.md): `orin run`, `orin build`, `orin init`.
2. [Values, types and functions](02-values.md): `const` and `let`, numbers, `bool`, `string`, functions, closures.
3. [Records, unions, Option and Result](03-data.md): records, tagged unions, `match`, absence and errors as values, `?`.
4. [Classes, interfaces and generics](04-classes.md): classes, mutation, interfaces, generic types and functions, bounds.
5. [Collections and strings](05-collections.md): arrays, `Map`, string methods.
6. [A command-line tool](06-cli.md): `main(host: Host)`, program arguments, reading and writing files with grants.
7. [Testing](07-testing.md): `@Test`, `std:test`, `orin test`.
8. [Contracts](08-contracts.md): `@Requires`, `@Ensures`, `orin verify` (needs z3).
9. [A project with packages](09-project.md): `orin.toml`, modules, a path dependency, tests in a project.
10. [Concurrency](10-concurrency.md): `std:task`, tasks, channels, parallel pipelines.

## How to use it

- Every program in the tutorial is a real file under [`examples/tutorial/`](../../examples/tutorial/). Run it from the
  root of the repository (`orin run examples/tutorial/02-values.or`) or copy it anywhere.
- The expected output sits next to each program in a `.out` file, and the chapters show it.
- `tools/test_tutorial.sh` builds and runs every program and checks that every code block in these chapters is
  byte-identical to its file, so the tutorial cannot drift from the compiler. (The compiler it uses is
  `build/bootstrap/orin2`; `tools/bootstrap.sh` builds it.)
- The tutorial describes what the compiler does today. Some library modules it uses (`std:fs`, `std:process`, `std:task`,
  `std:host`) are marked unstable in [std.md](../std.md) and may change before they are frozen; the language chapters are
  covered by the [language reference](../reference/README.md).

## Where to go next

[Language reference](../reference/README.md) (normative, one chapter per area), [standard library overview](../std.md),
[CLI guide](../cli.md), [contracts](../contracts.md), [concurrency](../concurrency.md), [testing](../testing.md).

Start with [chapter 1](01-hello.md).
