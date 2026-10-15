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
related labels, richer assertion diffs, animated progress, and a complete `explain` catalog remain
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
forbids Git downloads. Ordinary builds use the cache and do not silently update dependencies.
Git's normal authentication mechanisms apply. Do not embed credentials in dependency URLs.

Each package resolves its own direct dependencies. Conflicting sources for the same declared
package name are rejected during fetch. Local paths are not reproducible snapshots. Resource
capabilities and effect policies retain their existing guarantees and limitations; dependencies
are source code, not a runtime sandbox.
