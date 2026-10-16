# Workspace manifest (`orin-workspace.toml`) — specification

Status: parser, pure resolution and lockfile implemented and unit-tested (`compiler/tests/workspace_test.or`).
The CLI adapter is staged but not exported or dispatched until the seed refresh; workspace-aware build/check/test/fmt
and upwards root discovery remain pending. No files move.

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

- One lockfile at the workspace root, written by the planned `orin workspace lock`, never by a build.
- It holds one `[member.<name>]` table per member, in build order, with `path`, `version` and `dependencies` (the
  member names it depends on). `lockText` in `compiler/package/resolve.or` is the canonical text.
- A build whose resolution differs from the lock (a member added, removed, moved, re-versioned or with changed member
  dependencies) fails with E0509 at the differing table; `--locked` is the default in CI. External dependencies join the
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

Planned: `orin build|check|test|fmt` in a workspace act on `default-members` (all members when absent); `-p <name>` selects one
package, `--workspace` all. `orin workspace list` prints the members in build order. Standalone projects are unchanged.

## 7. Fixtures

`tests/workspace/` holds one directory per case. `ok/<case>/` must resolve; its `expected.txt` lists the members in build
order. `fail/<case>/` must be rejected; its `expected.txt` holds the expected code and the line of the span, as
`E0505 3`. `compiler/tests/workspace_fixtures.or` executes every fixture, including stale locks, in the tooling CI
suite. `compiler/package/wscli_smoke.or` compiles and checks usage of the staged CLI adapter before dispatch is wired.
