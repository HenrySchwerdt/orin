# Workspace manifest (`orin-workspace.toml`) — specification

Status: parser, pure resolution, lockfile, inspection CLI and workspace-wide `build|check|test|fmt` implemented and tested.
`orin workspace list|lock|check` discovers the nearest workspace, including from member source directories.
The shared external-dependency lock design remains pending.

## 1. File and discovery

- A workspace root is a directory containing `orin-workspace.toml`. The toolchain finds it by walking up from the current
  directory, as it finds `orin.toml` today, and stops at the first one found. Nested workspaces are rejected (E0507).
- Without a workspace file, every command behaves exactly as today on a single `orin.toml` project.
- The file is TOML in the subset `compiler/package/toml.or` already accepts. The same strictness as `orin.toml` applies:
  unknown tables and keys are errors, never ignored.

## 2. Tables and keys

```toml
[workspace]
members = ["compiler", "runtime", "library/*", "tooling/*"]   # required, non-empty
exclude = ["tooling/vscode"]                                   # optional
default-members = ["compiler"]                                 # optional, subset of members

[workspace.tools.vscode]          # a non-Orin tool: no orin.toml
path = "tooling/vscode"
type = "npm"                      # closed set: "npm"
```

| key | type | rule |
|---|---|---|
| `workspace.members` | array of path patterns | required, at least one entry |
| `workspace.exclude` | array of path patterns | optional; every entry must match at least one member candidate |
| `workspace.default-members` | array of paths | optional; each must be a resolved member |
| `workspace.tools.<name>.path` | path | required; a directory with the tool's native manifest, outside every member |
| `workspace.tools.<name>.type` | string | required; `"npm"` (needs `package.json`) |

**Path patterns.** Relative to the workspace root, `/` separated. A pattern is a literal path or ends with a single `*` segment
(`library/*`: every direct subdirectory). No other wildcards, no `..` segments, no absolute paths, no trailing `/`,
no backslashes. Resolution is lexicographic, so the member order is deterministic.

## 3. Members and packages

- Every resolved member directory must contain an `orin.toml` with a `[package]` table; its `name` is the member's
  package name. A `*` pattern only matches directories that contain an `orin.toml`; a literal member without one is an
  error.
- Package names are unique in the workspace.
- A dependency on another member uses `path = "../x"` in the member's `orin.toml`. It must resolve to a member directory;
  a path dependency to a non-member directory inside the workspace is an error (it would build code the workspace does
  not check).
- The member dependency graph must be acyclic. Build, check and test run in a topological order; ties are broken by
  package name, so the order is the same on every machine.

## 4. Lockfile (`orin.lock`)

- One lockfile at the workspace root, written by `orin workspace lock`, never by a build.
- It holds one `[member.<name>]` table per member, in build order, with `path`, `version` and `dependencies` (the
  member names it depends on). `lockText` in `compiler/package/resolve.or` is the canonical text.
- A build whose resolution differs from the lock (a member added, removed, moved, re-versioned or with changed member
  dependencies) fails with E0509 at the differing table when run with `--locked` (see section 6); `--locked` is the default
  when the `CI` environment variable is set to anything but empty, `0` or `false`. External dependencies join the
  lock when the package manager resolves them.

## 5. Diagnostics

All workspace errors carry the source span of the offending key or array element in `orin-workspace.toml` (or in the
member's `orin.toml` for dependency errors) and are never downgraded to warnings.

| code | meaning |
|---|---|
| E0504 | invalid workspace manifest: syntax, unknown table or key, wrong value type, missing `members`, empty `members` |
| E0505 | invalid member path: absolute, `..`, backslash, trailing `/`, unsupported wildcard, outside the root, or a literal member without `orin.toml` |
| E0506 | duplicate: two members with the same package name, or a path listed twice |
| E0507 | ambiguous or overlapping layout: a member inside another member, a tool inside a member, an `exclude` that matches nothing, a `default-members` entry that is not a member, a nested workspace |
| E0508 | dependency error: a path dependency to a non-member, a dependency cycle (the message lists the cycle) |
| E0509 | stale lockfile: member paths, versions or member dependencies differ from `orin.lock` (span in `orin.lock`); no manifest/content hashes yet |

## 6. Commands (phase 2)

Available: `orin workspace list|lock|check [--root <directory>]`.
`list` prints `name  relative-directory` in dependency order, escaping terminal control bytes. `lock` writes the member snapshot; `check` validates it
without changing files. The release driver searches physical ancestors, continuing past member `orin.toml` files.
Direct compiler invocation probes up to 256 ancestors; a missing workspace reports an error and suggests `--root`.
An explicit `--root` names the workspace directory itself and bypasses discovery. Paths containing spaces are supported.
JSON output is not supported for these commands; requesting it is a usage error. Existing terminal color, ASCII and
quiet/verbose options are accepted; list output remains data even in quiet mode.

`lock` refuses to replace a standalone pipe-format project lock or an unrecognized file. The member-only TOML lock
cannot yet record external dependency resolutions. Existing project dependency commands retain their current meaning;
`orin update` still updates Git dependencies. Read/write and directory enumeration errors must abort before lock mutation.

### Workspace-wide `build`, `check`, `test`, `fmt`

```sh
orin build                     # at the workspace root: the default-members (all members if the key is absent)
orin build --workspace         # every member, dependency order, ties by package name
orin test -p app -p lib        # only these members, still in dependency order
orin fmt --check --workspace
orin check --workspace --locked
```

| flag | meaning |
|---|---|
| `--workspace` | all members |
| `-p <name>`, `--package <name>`, `--package=<name>` | one member (repeatable); an unknown name is a usage error (exit 2) listing the members; cannot be combined with `--workspace` |
| `--locked` / `--unlocked` | require / do not require a current `orin.lock` (E0509 on drift or when it is missing); `--locked` is implied when `CI` is set, `--unlocked` overrides |
| `--keep-going` / `--fail-fast` | continue after / stop at the first failing member (defaults below) |

Mode selection. Workspace mode starts when `--workspace`, `-p` or `--package` is present (from the root or from inside any
member), or when the command has no path argument and the current directory is itself a workspace root. Everything else
(a member directory without flags, an explicit path, no workspace file at all) is the unchanged single-project command,
byte for byte; the workspace-only flags `--locked`, `--unlocked`, `--keep-going` and `--fail-fast` are then rejected as unknown
options exactly as before. Workspace flags with no workspace file are an error (exit 1), never a silent single-project run.

Execution. The compiler validates the whole workspace first (manifest, member graph, `--locked` lock) and prints every
error with its span before any member runs, so a cycle, missing member or stale lock stops the command with exit 1 and no
member output. Each selected member then runs the ordinary single-project command in its own directory, announced as
`→ build app (2/3)` (`>` with `--ascii`) on stderr. The member's own flags, output and exit status are unchanged. Arguments after the
workspace flags are passed to every member (`--release`, `--backend`, `--filter`, `--check`...). An explicit path argument,
`--format=json` and `test --watch` are usage errors (exit 2) in workspace mode; run those inside one member.

Failure rule.
- `build` and `check` stop at the first failing member (a later member may depend on it) and exit with that member's status.
  The message says how many members were not run. `--keep-going` runs the rest, then exits 1 naming every failed member.
- `test` and `fmt` run every member, then exit 1 naming the failed members. `--fail-fast` stops at the first failure.
- Exit statuses: 0 all selected members succeeded; 1 a member or the workspace validation failed; 2 usage error.

Per-command notes.
- `build`: a member whose entry file defines no `function main(` is a library; it is type-checked (`check`) instead of
  producing an executable, and the driver says so.
- `test`: members without tests are not an error (`--allow-empty` is implied). With `--filter`, members matching nothing are
  skipped, and the command fails only if the filter matches in no member. Use `-p <name>` to require tests of one member.
- `fmt`: `orin fmt --check --workspace` reports every unformatted member; `orin fmt --workspace` rewrites them.
- Path dependencies between members still need each member's project `orin.lock` (`orin fetch` in that member); the
  workspace `orin.lock` only records the member snapshot.

`orin workspace list --default` prints only the `default-members` (all members if absent), still in build order.

## 7. Fixtures

`tests/workspace/` holds one directory per case. `ok/<case>/` must resolve; its `expected.txt` lists the members in build
order. `fail/<case>/` must be rejected; its `expected.txt` holds the expected code and the line of the span, as
`E0505 3`. `compiler/tests/workspace_fixtures.or` executes every fixture, including stale locks, in the tooling CI
suite. `tests/workspace_cli/ok/` is a runnable three-member workspace (`app` depends on `lib`, plus `tool`) that
`tools/test_cli.py` copies and mutates for the workspace-wide command journeys: member selection, `--locked`, cycle, missing member, stale lock, the failure rules and `fmt --check`. `compiler/package/wscli_smoke.or` checks adapter usage; `tools/test_cli.py` exercises all 30 fixtures through the packaged
CLI, discovery, diagnostics, stale locks and overwrite protection.
