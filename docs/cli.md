# Working with the Orin CLI

The release launcher provides project discovery, native builds, test discovery, dependency management,
and terminal presentation. The compiler remains self-hosted. The launcher requires Bash 3.2 or later;
Git is needed only for Git dependencies. There is no Python or Node requirement for release users.

From a source checkout, use `./tools/orin` for the same interface. It builds the development compiler
when necessary and assembles a local installation under `build/dev-install`, without replacing an
installed Orin. You can add `build/dev-install/bin` to your PATH after the first invocation.

## Start and develop

```sh
orin init hello
cd hello
orin run
orin test
orin dev
```

`init` defaults to an application with a passing test. Use `--lib` for a library or `--template http`
for the shipped HTTP server example. `init` without a name uses the current directory. Existing
destination files are checked before writing and are never overwritten. An existing `.gitignore`
is preserved. No Git repository or editor settings are created implicitly.

Project commands find the nearest ancestor `orin.toml`; explicit files and directories remain valid.
`orin build` writes `build/dev/NAME`; `--release` writes `build/release/NAME`. `-o PATH` overrides the
destination. Content fingerprints cover the compiler, runtime, sources, dependencies (including
transitive dependencies), toolchain, backend, and profile. Repeating an unchanged build reuses its
executable. `orin clean` removes project build artifacts, leaving the dependency cache intact.

```sh
orin run -- --port 8080
orin check
orin fmt
orin fmt --check
orin test --filter greeting
orin test --watch
orin build --release
orin expand src/main.or           # print the generated companion modules (ADR-0046)
orin expand --input src/main.or   # print the std:meta Input of every processor run
orin build --backend=llvm
```

`run` reserves stdout for your program and forwards its exit status. Use `--` to separate program
arguments from tool options. `dev` watches source/dependency contents, rebuilds after changes, and
restarts after success. Failed rebuilds preserve a still-running previous process. Logs are retained;
Ctrl+C stops the process group and watcher. Watch mode currently polls rather than using OS watchers.

`test` discovers loaded `@Test` functions plus `tests/**/*_test.or`. It constructs a temporary
import-only entry in the project root and removes it after the run. Explicit file targets retain
file-based discovery. No matching tests fails; `--allow-empty` explicitly permits an empty suite.
A nonmatching explicit `--filter` still fails. Development and release builds retain the compiler's
ownership verifier; release does not weaken checking.

## LLVM backend and the pinned toolchain

```sh
orin toolchain install
orin toolchain status
orin build --backend=llvm
```

`--backend=llvm` compiles the generated LLVM IR with clang. `orin toolchain install` downloads the one LLVM version Orin is
tested with (`lib/orin/llvm.pin`), checks the archive's sha256 against the pin, and installs `clang`, `llc` and clang's resource
files (about 400 MB) into `~/.orin/toolchains/llvm-<version>` (`ORIN_HOME` relocates it). `--backend=llvm` uses it when present;
an explicit `CC` wins; without it a dev build uses the system `clang`.

`--release` (also for `run` and `test`) defaults to the LLVM backend; dev builds use the C backend. Without the pinned toolchain a
default release build uses the system `clang` if its major version is at least the pin's, and otherwise falls back to the C backend
with one note. `--backend=llvm` without the pinned toolchain falls back to C with the same note. `--backend=c` always selects the C
backend, and a `CC` that is not clang keeps a default release build on C. Both backends run the same MIR optimiser and compile at
`-O2`. `orin doctor` reports whether the pinned toolchain is installed.

## Workspaces

A directory with an `orin-workspace.toml` ([workspace.md](workspace.md)) groups several packages. At its root
`orin build|check|test|fmt` act on `default-members` (all members when unset); `--workspace` selects every member and
`-p <name>` one or more, in deterministic dependency order. `--locked` (implied when `CI` is set; `--unlocked` overrides)
fails with E0509 when `orin.lock` is missing or differs from the members. `build` and `check` stop at the first failing
member, `test` and `fmt` run all members and then exit 1; `--keep-going` and `--fail-fast` flip these. Inside a member
directory without flags, or with an explicit path, commands behave exactly like a standalone project.

```sh
orin workspace list --default
orin test --workspace --locked
orin fmt --check --workspace
orin build -p app --release
```

## Terminal output

Compiler failures include source excerpts, carets, and notes. Status and diagnostic colors follow
your terminal theme: green success, red failure, yellow warning, cyan emphasis. Redirected output
has no animation or color by default. Control characters in rich diagnostic content are escaped.

```sh
orin check --color=always
orin test --ascii
orin build --quiet
orin build --verbose
orin help init
orin explain E0400
orin doctor
```

`--color=auto|always|never` controls ANSI; auto respects `NO_COLOR` and `TERM=dumb`. `--quiet`
suppresses successful build status; tests retain their summary and failures. `--verbose` expands
test results and native compiler details. Human progress goes to stderr. Test reports go to stdout.

Machine commands retain existing JSON formats (`check`, `compile`, `verify`, `test`, `effects`,
`diff`). New `init`, `add`, `remove`, `fetch`, `update`, `build`, and `clean` results support
`--format=json` with `schemaVersion: 1`, `command`, `ok`, and a result or error field. `run` and
watch mode reject JSON because the application owns stdout. LSP and MCP bypass terminal formatting.
The standalone compiler retains compact diagnostics by default; use `--diagnostic-style=rich`
to request the terminal renderer directly.

The current renderer does not invent related locations or assertion values from strings. Structured
related labels, richer assertion diffs and animated progress remain
follow-ups to the design in [developer-experience-design.md](developer-experience-design.md).

## Dependencies

```sh
orin init shared --lib
# From another project:
orin add --path ../shared
orin add --git https://github.com/acme/orin-router --tag v0.2.0
orin add --git https://github.com/acme/orin-router --rev COMMIT
orin add --path ../testkit --dev
orin deps --tree
orin fetch --locked --offline
orin update router
orin remove router
```

The example Git URL is illustrative. Use a repository containing an Orin library with an
`orin.toml` and `src/module.or`. Registry lookup and publishing are not implemented.

```toml
[dependencies]
shared = { path = "../shared" }
router = { git = "https://github.com/acme/orin-router", tag = "v0.2.0" }
```

```typescript
import { greeting } from "shared";
```

Imports resolve to `src/module.or`; internal modules retain their existing privacy rules.
`--dev` declarations are accessible to files under `tests/`, not production sources. Manifest
editing preserves surrounding tables and comments. Failed resolution restores the root manifest
and lockfile; failed Git updates also restore the previous cached source. Resolved packages are cached under `.orin/packages/`.

`orin.lock` is a versioned, pipe-delimited text file. Git entries record immutable commits, including transitive entries such as `shared/base`; local
path entries are marked live. Commit the lockfile. `fetch` reuses matching locks, `update` deliberately
re-resolves a named package or all packages, `--locked` refuses required changes, and `--offline`
forbids Git downloads. Builds, tests, checks, and compilation validate the root lock against cached sources without network access. If another project updated a shared path dependency’s Git cache, the command fails rather than using a different commit; `orin fetch --locked` restores the pinned graph. Ordinary builds do not silently update dependencies. Development dependencies of consumed libraries are excluded from the graph.
Git's normal authentication mechanisms apply. Do not embed credentials in dependency URLs.

Each package resolves its own direct dependencies. Conflicting sources for the same declared
package name are rejected during fetch. Local paths are not reproducible snapshots. Resource
capabilities and effect policies retain their existing guarantees and limitations; dependencies
are source code, not a runtime sandbox.

## Command reference

`orin <command> [options]`. Global options may stand before or after the command: `--color=auto|always|never`, `--ascii`,
`--quiet`, `--verbose`, `--format=json` (only for the commands that list it), `--max-errors N` (diagnostics shown, compiler
commands), `--diagnostic-style=rich|compact`. `orin --help` lists the commands, `orin help <command>` or `orin <command> --help`
prints one usage line, `orin --version` the release.

Exit codes are the same everywhere unless a section says otherwise: `0` success, `1` the command ran and found a problem (a
diagnostic, a failing test, a changed API, a failed build), `2` wrong usage (unknown command or option, missing value). `run`
returns the status of your program. A path argument is an entry `.or` file or a package directory; commands that take an
optional path use the nearest `orin.toml` upward from the current directory when it is omitted.

### init

`orin init [name] [--lib | --template http]`. Creates `orin.toml`, `src/main.or` (or `src/module.or` with `--lib`),
`tests/main_test.or` and `README.md`. `--template console|http` selects the template (`http` cannot be combined with `--lib`).
Never overwrites; exits 1 when a file exists, 2 for a bad option or name.

### build

`orin build [path] [--release] [--backend=c|llvm] [--target=native|wasm64-orbit|wasm32-orbit] [-o path] [--format=json]`

| Flag | Meaning |
|---|---|
| `--release` | optimised profile, output in `build/release/`; defaults to the LLVM backend (see above) |
| `--backend=c\|llvm` | native code generator; dev builds default to `c` |
| `--target=` | `native` (default), `wasm64-orbit` or `wasm32-orbit`: a freestanding WebAssembly module for [Orbit](wasm.md), written to `build/<profile>/NAME.wasm`; needs the C backend; only `build` accepts it |
| `-o path` | output path instead of `build/<profile>/NAME` |
| `--format=json` | machine result (`schemaVersion`, `command`, `ok`, `artifact`) |

Environment: `CC` selects the C compiler, `ORIN_HOME` the toolchain directory. Exit 1 on a compile or native build failure.
```sh
orin build --release --backend=c
orin build --target=wasm32-orbit -o out/app.wasm
```

### run

`orin run [path] [--release] [--backend=c|llvm] [-o path] [-- program-arguments]`. Builds like `build`, then executes. Stdout and
stderr belong to the program, its exit status is returned, and `--format=json` and `--target=wasm*` are rejected (exit 2).

### dev

`orin dev [path] [-- program-arguments]`. Watches sources and dependencies, rebuilds with the dev profile and the C backend, and
restarts the program after a successful build. Runs until Ctrl+C (exit 130).

### check

`orin check [path] [--format=json] [--deps] [--strict-contracts] [--workspace] [-p name] [--locked]`. Type-checks and runs the
ownership and project-policy checks without generating code; annotation processors run (`--processor-timeout`,
`--processor-cache`, `--cc`, `--runtime` as for `expand`). `--deps` prints the module dependency graph (also as JSON),
`--strict-contracts` turns the contract warnings into errors. Exit 1 when there are errors.
```sh
orin check --format=json src/main.or
```

### test

`orin test [path] [--filter text] [--watch] [--allow-empty] [--format=json] [--timeout seconds] [--keep] [--no-contracts] [--out-dir dir] [--runtime dir] [--cc cmd]`.
Runs `@Test` functions and `tests/**/*_test.or` ([testing.md](testing.md)). `--filter` keeps tests whose name contains the text;
`--allow-empty` accepts an empty suite; `--watch` reruns on change (not with a workspace); `--keep` keeps the generated files;
`--no-contracts` builds without runtime contract checks. Exit 1 when a test fails or none matched.

### fmt

`orin fmt [paths...] [--check | --stdout]`. Formats files or directories (the whole project without arguments) in place.
`--check` only reports files that would change (exit 1), `--stdout` prints the result instead of writing.

### doctor, toolchain, clean

`orin doctor` checks the installation (version, layout, C compiler, PATH, pinned LLVM). `orin toolchain install [--force]` and
`orin toolchain status` manage the pinned LLVM. `orin clean` removes `build/` of the project. These take no other options.

### add, remove, deps, fetch, update

`orin add --path <dir> [--dev]`, `orin add --git <url> [--tag tag | --rev commit] [--name alias] [--dev]`, `orin remove <name>`,
`orin deps [--tree]`, `orin fetch [--locked] [--offline]`, `orin update [name] [--offline]`. All but `deps` accept `--format=json`.
`--locked` fails (E0509) when `orin.lock` would change; `--offline` forbids Git downloads. Semantics are under Dependencies above.

### workspace

`orin workspace list [--default] | lock | check [--root dir]`: member list in dependency order, writing `orin.lock`, and
validating the manifest and lock (E0509 on drift). See [workspace.md](workspace.md). `build`, `check`, `test` and `fmt`
accept `--workspace`, `-p|--package name`, `--locked|--unlocked`, `--keep-going` and `--fail-fast`.

### api

`orin api [path] [--check snapshot]`. Prints the public API snapshot of the package (text). With `--check FILE` it compares the
current API with a stored snapshot: prints `api unchanged` (exit 0), or lists the differences on stderr (exit 1); an unreadable
snapshot exits 2. Use it to guard a library against accidental breaking changes ([stability.md](stability.md)).
```sh
orin api > api.snapshot
orin api --check api.snapshot
```

### graph

`orin graph [path] [-o out.json]`. Writes the OSIG snapshot (symbols, types, calls; [osig.md](osig.md)) as JSON to stdout or to
the file. Exit 1 when the program does not check.

### diff

`orin diff --base <dir|file.or|snapshot.json> --head <dir|file.or|snapshot.json> [--format=text|json|html] [--link-base url] [-o out] [--exit-code]`.
Compares two programs or snapshots and reports the changes (default `text`). `--link-base` prefixes the links of the HTML report,
`-o` writes the report to a file. Exit 0 normally; with `--exit-code` exit 1 when there are differences. Exit 1 also when an
input cannot be loaded, 2 for bad usage.

### effects

`orin effects [path] [--format=text|json] [--summary] [--module id] [--function name] [--no-paths] [--tests] [--check-purity]`.
Transitive effect summaries (I/O, time, randomness, memory, network...) per function, module, package and `main`, with the
call chain that explains each ([capabilities.md](capabilities.md)). `--summary` stops at modules, `--module` and `--function`
filter, `--no-paths` drops the chains, `--tests` includes `@Test` functions. `--check-purity` cross-checks the result with the
purity analysis and exits 1 when a function marked pure has an effect.

### verify

`orin verify [path]` runs the MIR ownership verifier and exits 1 on errors. `orin verify --contracts [--format=json] [--z3 path] [--timeout-ms N] [--retry-ms N] [--rlimit N] [--strict]`
proves `@Requires`/`@Ensures`/`@Invariant` contracts with Z3 ([contracts.md](contracts.md)); `--strict` treats unproved
obligations as failures. `--no-opt`, `--no-fuse` and `--check-contracts` apply as for `compile`.

### mir

`orin mir [path]` prints the optimised MIR ([mir.md](mir.md)). Debug aid; the text is not a stable format
([stability.md](stability.md)). Accepts `--no-opt` and `--no-fuse`.

### expand

`orin expand [path] [--input] [--processor-timeout seconds] [--processor-cache dir] [--cc cmd] [--runtime dir]`. Runs the annotation
processors ([annotation-processors.md](annotation-processors.md)) and prints the generated companion modules (`m.gen`) through
the formatter; `--input` prints the `std:meta` input of every processor run instead. `--processor-timeout 0` means unlimited.

### compile

`orin compile <entry.or> -o <out.c> [--backend=c|llvm] [--target=native|wasm64-orbit|wasm32-orbit] [--format=json] [--no-verify] [--no-opt] [--no-fuse] [--fuse-report] [--c-builtins] [--rt-wrappers] [--check-contracts] [--strict-contracts] [--stats-sites] [--assert-facts] [--split n] [--timings file.json]`.
Low-level: writes C (or LLVM IR with `--backend=llvm`, `-o x.ll`) without invoking a C compiler. `orin build` is the normal way.
`--split n` writes n translation units (1 to 1024), `--timings` writes per-phase times (schema `orin-timings/0.1`); a wasm
`--target` needs the C backend and rejects `--stats-sites` and `--split`. The `--target` and `--timings` options need `compile`.

### lsp, mcp

`orin lsp` is the language server on stdio. `orin mcp [--root dir] [--allow-exec] [--repo dir]` is the MCP server ([mcp.md](mcp.md)).

### explain

`orin explain <code>` prints the explanation of a diagnostic code. The release package ships no documentation, so the explanations are
built into the launcher, which covers exactly 14 codes: E0200, E0201, E0300, E0301, E0400, E0401, E0402, E0403, E0404, E0405, E0406,
E0407, E0408 and E0410. For any other code it exits 2 and says which codes it covers and points to the full index of all codes,
[reference/10-diagnostics.md](reference/10-diagnostics.md)
(<https://github.com/orin-lang/orin-lang/blob/main/docs/reference/10-diagnostics.md>). Diagnostics themselves always carry the code and a message.
