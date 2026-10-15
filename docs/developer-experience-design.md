# Orin CLI and terminal experience

Status: proposal for review, 2026-10-15. This document describes intended behavior, not shipped features.
All command names, help, diagnostics, templates, and terminal messages are in English.

## Product direction

Make the first successful run obvious, the daily loop fast, and failures easy to act on.
One executable, predictable defaults, consistent output across commands. The terminal should feel
polished without consuming space that belongs to source code and program output.

The current implementation splits native build/run/doctor into `dist/orin` and other commands into
`compiler/main.or`. Package manifests exist, but external dependency resolution and package imports
do not. Test discovery follows loaded modules. These are implementation gaps this proposal addresses.

## First five minutes

```sh
orin init hello
cd hello
orin run
orin test
```

```text
✓ Created hello

  hello/
    orin.toml
    src/main.or
    tests/main_test.or
    .gitignore
    README.md

Next steps
  cd hello
  orin run
```

`orin init` initializes the current directory; `orin init NAME` creates a directory.
The default is a console application. `--lib` creates `src/module.or` and a small exported function;
`--template http` creates a working HTTP example using the supported standard library.
Templates include a meaningful passing test. Initialization needs no network or questions.
Validate names and all destination conflicts before writing. Preserve existing files, including an
existing `.gitignore`; report conflicting paths and leave the directory unchanged on validation failure.
Do not initialize Git or editor configuration implicitly.

## Command API

| Command | Default behavior |
| --- | --- |
| `orin` / `orin --help` | Short grouped help with a getting-started example; exit successfully |
| `orin help COMMAND` / `orin COMMAND --help` | Same command-specific help |
| `orin init [NAME]` | Create an application; `--lib` or `--template http` selects another starter |
| `orin run [PATH] -- [ARGS]` | Build and run; omitted path selects the current project |
| `orin dev [PATH]` | Watch, rebuild, and restart after successful builds |
| `orin build [PATH]` | Build a development executable |
| `orin build --release` | Build an optimized executable |
| `orin check [PATH]` | Check types, ownership, and project policies |
| `orin test [PATH]` | Discover and run project tests |
| `orin test --filter TEXT` | Run matching tests; no matches is an error |
| `orin test --watch` | Repeat tests after relevant changes |
| `orin fmt [PATH...]` | Format project sources or explicit paths |
| `orin fmt --check` | Report formatting differences without modifying files |
| `orin clean` | Remove this project's generated build artifacts |
| `orin doctor` | Diagnose installation and toolchain problems |
| `orin explain CODE` | Explain a known diagnostic and show valid examples |

Keep `compile` (emit C/LLVM), `mir`, `verify`, `effects`, `graph`, `diff`, `api`, `lsp`, and `mcp`
available. Group advanced commands separately in help; preserve existing explicit-path invocations.
Do not silently alter verification guarantees between development and release profiles.

Project commands search upward for `orin.toml`, stopping at the filesystem root. An explicit path
overrides discovery. Paths in output are relative to the invocation directory when practical.
Build outputs are project-relative: `build/dev/NAME` and `build/release/NAME` (platform suffix as needed).
`-o PATH` overrides the executable destination. Builds reuse unchanged artifacts using source,
dependency, compiler, runtime, backend, profile, and relevant flag fingerprints.

Project tests include loaded `@Test` functions and `tests/**/*_test.or`, even when the application
does not import those files. Deduplicate test identities. Explicit file targets retain file-scoped
discovery. A new project always contains a discoverable test; zero discovered tests is reported
clearly. `--allow-empty` explicitly permits zero tests in CI.

## Terminal design system

Use the user's terminal background and normal foreground. Use standard ANSI semantic colors so
terminal themes remain effective; never require a dark background or force an RGB palette.

| Role | Color/style | Marker |
| --- | --- | --- |
| Success | Green | `✓` |
| Error | Red; bold heading | `✗` in status rows; `error` in diagnostics |
| Warning | Yellow; bold heading | `!` or `warning` |
| Active operation | Cyan | Spinner while active; fixed marker afterward |
| Next action | Cyan command or `help:` label | `→` where useful |
| Paths and timing | Normal or dim, depending on emphasis | No required marker |
| Skipped result | Dim | `–` |
| Names and headings | Bold | No extra decoration |

Use one blank line between logical sections, two spaces for subordinate content, and a shared
source gutter. Never encode status only in color. Success should be quieter than failure.
No startup banner, large logo, decorative boxes, or full-screen interface for normal commands.
No artificial delay: show a spinner only when an operation lasts beyond approximately 150 ms.
Never display invented progress percentages or intermediate success states.

Global presentation options: `--color=auto|always|never`, `--quiet`, `--verbose`.
`auto` checks the destination stream's TTY capability and respects `NO_COLOR` and `TERM=dumb`.
Explicit `--color` wins over environment defaults. Animation requires an interactive capable stream,
even with `--color=always`. Fall back to `OK`, `FAIL`, `WARN`, `SKIP`, and ASCII gutters when needed;
provide `--ascii` for explicit control. Narrow terminals stack status details instead of truncating meaning.

## Reference views

Examples below specify layout and copy; the semantic roles above supply color.
Names, locations, and timings in examples are illustrative.

### Build and run

```text
Building hello v0.1.0

✓ Built in 284 ms
  build/dev/hello
```

For an unchanged build: `✓ Up to date · 12 ms`.
`run` emits build status to stderr, then `→ Running hello`, then leaves stdout to the application.
Forward program arguments exactly after `--`; propagate its exit code and handle signals correctly.
`--quiet` suppresses successful tool status, never application output or errors.

### Test results

```text
Testing hello

✓ tests/users_test.or                   4 passed
✗ tests/payments_test.or                2 passed · 1 failed
– tests/network_test.or                2 skipped

FAIL payments.rejectsNegativeAmount

  tests/payments_test.or:28:3

  27 │ const result = transfer(-10);
  28 │ assertEq(result.balance, 100);
     │ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

  Expected  100
  Received   90

1 failed · 6 passed · 2 skipped          342 ms
```

One final row per file by default, deterministic ordering, failures expanded below. Verbose mode
shows each test. Quiet mode shows failures and the final result. Include captured output for failed
tests; make successful captured output available in verbose mode. Preserve signal/trap/timeout
distinctions. String assertions should show a compact diff when actual and expected are available.
Do not fabricate assertion locations or values when the runtime only provides an opaque message.
Skipped tests and structured assertion values require runner support; until implemented, omit those
fields rather than infer them. Parallel activity must not interleave source snippets or test reports.

### Type error

```text
error[E0400]: Argument type mismatch

  src/payments.or:24:10

  23 │ const amount = "42";
  24 │ transfer(amount);
     │          ^^^^^^ expected int, found string

  note: Parameter `amount` of `transfer` has type int.

Check failed · 1 error
```

Do not suggest automatic parsing here: choosing how to handle invalid input is a program decision.
Offer specific help only when the compiler has enough evidence to justify it.

### Syntax error

```text
error[E0200]: Expected `;` after declaration

  src/main.or:3:25

   3 │ const greeting = "Hello"
     │                         ^ insert `;` here

  help: End the declaration with a semicolon.

Check failed · 1 error
```

Insertion markers are zero-width positions. EOF errors must show the final source line, including
empty-file and missing-final-newline cases. Parser recovery should preserve independent errors
while avoiding repeated reports caused by the same missing token.

### Related source locations

```text
error[E0452]: A grant cannot be captured by a closure

  src/server.or:18:31

  18 │ const handler = () => readFile(fs, path);
     │                               ^^ captured here

  src/server.or:12:13

  12 │ useFs(host, fs => {
     │             ^^ grant introduced here

  help: Pass the grant as an explicit parameter.
```

Primary and related labels must come from structured diagnostic data. Existing string notes remain
readable while producers migrate. Never recover location semantics by scraping note strings.

### Warnings

```text
warning[W0440]: `oldHelper` is deprecated

  src/main.or:8:3

   8 │ oldHelper();
     │ ^^^^^^^^^ use `newHelper` instead

✓ Check passed · 1 warning
```

Warnings do not become errors merely because of presentation. Existing strict policies retain
their defined behavior. Preserve diagnostic codes and stable machine-facing meanings.

### Toolchain and internal failures

```text
error: C compiler `clang` was not found

  Orin needs a C compiler to build native applications.

  help: Install the Xcode Command Line Tools:
        xcode-select --install

  Run `orin doctor` to check your installation.
```

Choose installation advice from the detected platform. If a backend subprocess fails, include its
exit status and a short relevant output excerpt; retain complete output in an accessible build log
and print its location. `--verbose` shows the command and full output, with secrets redacted.

Internal compiler failures begin `internal error: Orin could not compile this program` and state
that this is a compiler failure. Include the compiler version and failing phase, and a path to a
local diagnostic report. Do not blame user code, upload source, or automatically publish reports.

### Watch mode

```text
Watching hello

✓ Built in 284 ms
→ Running hello · pid 18420

Watching src/ and orin.toml · Ctrl+C to stop
```

Append each subsequent build result without clearing program logs. Debounce changes and ignore
generated output. Rebuild into a separate artifact while the old process runs. After success, stop
the old process gracefully, with a bounded shutdown timeout, before starting the replacement.
On failure show diagnostics followed by `Previous process is still running` only if it actually is.
After a prior process exit, keep watching and report its exit status. Ctrl+C stops the child process
tree, releases watches, and exits without a stack trace. Deduplicate unchanged diagnostics between
watch iterations, but always show the latest success/failure state.

## Diagnostic rendering contract

1. Headline: severity, existing code when available, and a specific plain-English problem.
2. Location: clickable `path:line:column`; source excerpt; smallest meaningful highlighted span.
3. Related locations only when needed to explain the error.
4. Optional `note:` for explanation and `help:` for a supported next action.
5. One command summary with error/warning counts; no duplicate generic failure message.

Use two source-context lines at most by default, expanding where the diagnostic needs it. For
multiline spans, show both ends with an omission marker rather than dumping a large body.
Keep line-number gutter widths consistent within an excerpt. Long lines may be clipped around the
highlight with visible omission markers; preserve the original location and never clip away the
offending span. Tabs and Unicode need display-width-aware carets. Keep source byte offsets,
machine position conventions, and terminal display columns distinct; LSP positions follow its
negotiated encoding. Escape terminal control characters in source, paths, and messages.

Default limit: 10 errors, followed by `N more errors; use --max-errors N to show more` when the total
is known. If production stops early, say `Stopped after 10 errors` instead. Keep ordering stable.
Suppress only demonstrable cascades; do not hide independent errors. Missing source data falls
back to a concise message and available location, never a renderer crash.

## Dependencies and package API

```sh
orin add --path ../shared
orin add --git https://github.com/acme/orin-router --tag v0.2.0
orin add --git https://github.com/acme/orin-router --rev COMMIT
orin add --path ../testkit --dev
orin remove router
orin deps
orin deps --tree
orin update router
orin fetch
```

```text
Adding router

✓ Resolved router v0.2.0
✓ Downloaded
✓ Updated orin.toml and orin.lock

+ router v0.2.0
```

`orin add router` and `orin add router@0.2` are reserved for a later registry implementation.
Bundled standard-library imports require no `add`. Dependency names resolve to package public APIs:

```typescript
import { Router } from "router";
import { User } from "shared";
```

```toml
[package]
name = "hello"
version = "0.1.0"

[dependencies]
shared = { path = "../shared" }
router = { git = "https://github.com/acme/orin-router", tag = "v0.2.0" }

[dev-dependencies]
testkit = { path = "../testkit" }
```

Libraries expose `src/module.or` by default; explicit application entry configuration remains
backward compatible. Relative imports and `std:` imports retain their meaning. Dev dependencies
are visible only to test entry points, not production modules. Modules inside dependencies keep
their public/private boundaries.

`orin.lock` records immutable Git commits and resolved graph data; path dependencies remain live
and are explicitly marked local. Ordinary builds reuse locked resolutions; `add` and `update`
change resolution deliberately. `--locked` refuses required lockfile changes; `--offline` forbids
network access. A missing lock may be generated unless `--locked` is set. Download progress may
use percentages only with a known total. Failed resolution leaves the manifest and lock unchanged;
writing both requires rollback/recovery on partial failure. Preserve unrelated manifest comments.
Initially reject multiple versions of one package with an explanation of both dependency paths.
Registry policy, multiple-version type identity, and package publishing need a separate design.

## Output, automation, and compatibility

Human diagnostics and progress go to stderr. stdout is reserved for requested artifacts, reports,
or application output. Existing machine-readable commands retain their stdout contracts.
New project/dependency commands support `--format=json` with a versioned command-result schema;
machine output contains no ANSI, spinners, or prose. Preserve existing diagnostic JSON and LSP/MCP
schemas unless a separately versioned migration is designed. Color is a renderer option, not data.
`run --format=json` is intentionally unsupported initially because application stdout owns the stream.

Exit codes: 0 success, 1 check/build/test/resolution failure, 2 invalid usage, 130 user interruption.
`run` propagates application exit status after a successful build. Existing commands whose exit
contracts differ need explicit compatibility review, particularly formatting and semantic diffs.

CI and redirected streams get append-only output. Progress rows become final lines; no cursor
movement or timing-dependent transcript changes. Timings are omitted from deterministic snapshots.
Unknown commands and flags show a short error plus relevant help; suggestions require a close match.
Color and verbosity never change compilation, checks, test selection, or exit status.

## Implementation sequence and acceptance

1. Shared presentation options, status output, source renderer, and command-specific help. Apply to
   existing compiler/check/test output before adding more independent formatting code.
2. Unified command dispatch, project discovery, `init`, project-wide formatting and test discovery,
   consistent build profiles and artifacts. Keep compiler services reusable by CLI, LSP, and MCP.
3. Correct build cache, `dev`, test watch, process lifecycle, and editor onboarding.
4. Public package imports, path dependencies, then Git resolution and lockfile operations.

Before implementing, review these reference views: initialization, successful/cached build, type
error, syntax/EOF error, related spans, warning, mixed test results, toolchain failure, and watch
recovery. Validate each in ANSI color, plain output, narrow width, and ASCII mode. Diagnostic
fixtures cover tabs, Unicode, multiline spans, CRLF, missing source, and embedded control characters.
Machine-output checks ensure valid unchanged JSON and zero escape codes. Existing compiler
conformance, bootstrap, LSP, and MCP checks remain applicable to implementation changes.

Open implementation choices: the exact structured-label extension to `Diagnostic`; the runtime
assertion protocol; shutdown timeout; dependency public-entry configuration; and minimum supported
terminal capabilities. They must not be filled with UI guesses or reported as shipped behavior.
