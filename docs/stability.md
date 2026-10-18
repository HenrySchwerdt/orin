# Stability policy

This page says what you can rely on from an Orin release. It makes section 3.9 of the
[1.0 roadmap](roadmaps/orin-1.0.md) concrete (decisions D6, D10, D11). Where a promise is for 1.0 and not
for today, it says so.

## Versioning

Versions follow [semantic versioning](https://semver.org/) with a pre-release suffix:

| Stage | Example | Meaning |
|---|---|---|
| alpha | `0.1.0-alpha.2` | Early, incomplete. Anything can change. |
| beta | `0.1.0-beta.1` | Feature-complete enough to try on real code. Not frozen yet (see below). |
| release candidate | `1.0.0-rc.1` | Frozen; only fixes until 1.0.0. |
| release | `1.0.0` | The stability promise below applies. |

Every `-alpha`, `-beta` and `-rc` release is published as a **GitHub pre-release** (the release workflow
decides from the tag suffix, [`.github/workflows/release.yml`](../.github/workflows/release.yml)). Only a tag
without a suffix, such as `v1.0.0`, becomes a normal release.

The first beta is `0.1.0-beta.1`, not `1.0.0-beta.1`, on purpose. The roadmap ties `1.0.0-beta` to the
syntax and std freeze (milestone M4), which is not complete (see
[ADR-0056](decisions/0056-syntax-and-std-freeze.md) for what is still open). `0.1.0-beta.1` is a
pre-freeze beta.

## What the 0.x releases promise

Not much, and we say so:

- **Breaking changes can happen between any two 0.x releases**, including in the language syntax, the std
  API and the `orin.toml` format. Each one is announced in the release notes (assembled from the
  `changes/` fragments); read them before upgrading.
- **Diagnostic codes** (`E0300`, `W0440`, ...) are stable identifiers. Their **message text** is not: do not
  match on it. `orin check --format=json` gives you the code.
- **Not stable at all, in any release before or after 1.0:** the runtime ABI, the MIR format
  ([mir.md](mir.md)), and the generated C or LLVM IR. Do not link against them or depend on their shape.
- Bug fixes are not breaking changes, even if a program that relied on the bug stops compiling. Soundness
  fixes (a check that was too weak) can reject programs that used to compile.
- Safety and verification claims are qualified by [known-limitations.md](known-limitations.md),
  [assurance.md](assurance.md) and [tcb.md](tcb.md). A beta does not strengthen them.

## What 1.0 will promise

- **Semantic versioning.** Patch releases fix bugs, minor releases are additive, only a major release may
  break compatibility. Changes to the language follow
  [ADR-0016](decisions/0016-language-1.0-core-scope.md): by ADR, and additive.
- **Frozen syntax and std names** (ADR-0016, [ADR-0048](decisions/0048-std-api-conventions.md)), except for
  the experimental list below. Semantic fixes are allowed.
- **Deprecation.** An API is first marked `@Deprecated` with its replacement named in the message (warning
  `W0440`) and stays for at least one minor release before removal in the next major.
- **`orin.toml`:** documented keys are stable; unknown keys are errors (ADR-0047).
- **CLI:** documented commands and flags are stable. Undocumented flags and human-readable output formats
  are not; use `--format=json` where it exists.
- **Diagnostic codes** stay stable; message text may be reworded.

## Experimental and unstable

Marked in the docs and expected to change even after 1.0 until promoted. The roadmap (D6) keeps this list
short and in one place; this is it.

| Feature | Where | State |
|---|---|---|
| `std:meta` (annotation-processor interface, ADR-0046 slice S3) | [std-meta.md](std-meta.md), [`library/std/meta.or`](../library/std/meta.or), `metacore.or`, `metajson.or` | Experimental. The compiler already uses it: `orin expand` and the `.gen` companion modules run processors written against it (ADR-0046 slices S4-S6), but names and shapes may still change until promoted. |
| OX markup (JSX-like syntax) and its providers `std:html`, `std:ox` | [ox.md](ox.md), [`library/std/ox.or`](../library/std/ox.or), [`library/std/html.or`](../library/std/html.or) | Experimental; provider details may change. |
| `std:task` beyond the Gate 1 API | [concurrency.md](concurrency.md), [`library/std/task.or`](../library/std/task.or) | Stage 0, unstable. Gate 1 review decides what is frozen; additions beyond it stay experimental. |

Also unstable until the owner confirms the std I/O freeze (ADR-0016 amendment, ADR-0027): `std:host`,
`std:fs`, `std:process`, `std:io`, `std:time`, `std:net` ([std.md](std.md), where each is labelled).
After that freeze only the three rows above remain on the list. A pre-1.0 beta does not freeze them.

## Where to look

- [Known limitations](known-limitations.md) and the [assurance ledger](assurance.md): what is and is not
  checked or proved.
- [Trusted computing base](tcb.md): what you have to trust.
- [ADR-0016](decisions/0016-language-1.0-core-scope.md): the 1.0 language scope.
- [Roadmap to 1.0](roadmaps/orin-1.0.md): milestones and open decisions.
- [ADR-0056](decisions/0056-syntax-and-std-freeze.md) (draft): what the syntax and std freeze at `1.0.0-beta.1` covers and its entry criteria.
- [Installing](install.md) and [getting started](getting-started.md).
