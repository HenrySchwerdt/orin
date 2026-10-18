# ADR-0056: Syntax and std freeze at 1.0.0-beta.1

Status: **Proposed (draft)**, 2026-10-17. Not yet accepted; nothing in this ADR is in force until the owner accepts it. It turns
decisions D10 ("`v1.0.0-beta.1` at M4") and D11 ("beta freezes syntax and std names; semantic fixes allowed") of the
[1.0 roadmap](../roadmaps/orin-1.0.md) (section 3.9, milestone M4) into a checkable contract. Related:
[ADR-0016](0016-language-1.0-core-scope.md) (two-stage freeze, amended here only by reference),
[ADR-0048](0048-std-api-conventions.md), [ADR-0040](0040-generic-methods-and-void-type-arguments.md),
[ADR-0034](0034-eq-ord-hash-constraints.md), [ADR-0046](0046-typed-annotation-processors.md),
[ADR-0017](0017-concurrency-design.md), [ADR-0047](0047-workspace-layout-tooling-and-distribution.md),
[stability policy](../stability.md), [language reference](../reference/README.md).

## Context

The stability page promises a frozen syntax and frozen std names from 1.0, and the roadmap moves that freeze forward to the first
beta so that the beta is a usable Homebrew channel. Nothing yet says what "frozen" covers, what may still change, or when the owner
may declare it. `0.1.0-beta.x` releases are pre-freeze by definition ([stability.md](../stability.md)); this ADR concerns only
`v1.0.0-beta.1`.

## 1. What is frozen at 1.0.0-beta.1

"Frozen" means: a program that compiles on `1.0.0-beta.1` keeps compiling with the same meaning on every later beta, rc and 1.x
release, except through the exceptions of section 2. Anything not listed here is not frozen.

### 1.1 Syntax

- **Grammar.** [docs/reference/02-grammar.md](../reference/02-grammar.md) (EBNF, operator table, the `?` disambiguation of
  [ADR-0003](0003-postfix-question-disambiguation.md)) is the frozen grammar, together with the lexical rules of
  [01-lexical.md](../reference/01-lexical.md) (literals, comments, punctuation including `&`, `...`, `==>`, `@`). The reference
  follows the implementation; from the freeze on, a change to `compiler/syntax/` and to chapters 1 and 2 must go together, and an
  accepted-grammar change needs an ADR (section 2).
- **Keywords** (never identifiers, E0200): `const let function return if else while for of break continue type import export from
  match true false`.
- **Reserved words** (lexed as keywords; stay reserved, so adding a meaning later is additive): `var` (E0201), `class`,
  `interface`, `new`, `this` (have meanings), `enum`, `null`, `undefined`, `async`, `await` (every use is E0200). `async` and
  `await` stay reserved and unused: concurrency is `std:task` (roadmap D1 option B, no function colours).
- **Contextual words** (identifiers outside their position): `extends implements public private static constructor ox as` and the
  target words of `@Annotation(...)`.
- **Reserved operators**: `& | ^ ~ << >>` on integers (bit operators, post-1.0 with the semantics fixed in ADR-0016), `&` in type
  position for multiple bounds, `i128`/`u128` (E0431). Their introduction is additive and does not need a major version.
- **Annotation syntax and the built-in annotations**: `@Test`, `@Deprecated`, `@Inline`, `@Sealed`, `@Processor`, `@Annotation`,
  contract clauses `@Requires @Ensures @Invariant @Decreases @Rule` (reference chapter 7). The shape of user annotation
  declarations is frozen; `std:meta`, the processor interface, is not (section 1.2).
- **OX markup syntax** (reference chapter 9) is frozen as syntax only if the owner removes OX from the experimental list
  (criterion C14); the default is that OX syntax and its providers are experimental, as in [stability.md](../stability.md).
- **Language semantics** are not frozen in the sense of "never changes" (section 2), but the *rules* of reference chapters 3 to 8
  are the stated behaviour that bug reports are measured against.

### 1.2 Standard library

Frozen means the module path, every exported name, its signature, its error type and variants, and its documented contracts. Source
of truth: the exports in `library/std/` plus the preludes `library/core`, `library/collections` (array/map/string methods,
`Option`, `Result`, `Map`, `parallel()`), as recorded in the API snapshots of section 3.

| Module | Files | At 1.0.0-beta.1 |
|---|---|---|
| `std:bytes`, `std:encoding`, `std:utf8`, `std:url`, `std:collections`, `std:graph`, `std:seq`, `std:text`, `std:path`, `std:http`, `std:test`, `std:math` | `bytes.or`, `encoding.or`, `utf8.or`, `url.or`, `collections.or`, `graph.or`, `seq.or`, `text.or`, `path.or`, `http.or`, `test.or`, `library/collections/math.or` | **Frozen** |
| `std:json`, `std:json/number`, `std:json/decode` | `json.or`, `json/number.or`, `json/decode.or` | **Frozen** |
| `std:json/legacy` | `json/legacy.or` | **Frozen but deprecated** (`@Deprecated`, W0440); removal only in a major version |
| `std:host`, `std:fs`, `std:process`, `std:io`, `std:time`, `std:net` | `host.or`, `fs.or`, `time.or`, `net.or`; `process` and `io` are loader built-ins over the C runtime | **Frozen if and only if criterion C5 (std I/O freeze) is met**; today all are labelled unstable. They are never left in between: either they pass C5 and are frozen, or they move to the experimental list and the beta says so |
| `std:task` | `task.or` | Frozen for the **Gate 1 API** only (roadmap 3.3.4: `scope`, `spawn`, `join`, channels, timed waits, `select`, `sleep`, cancellation, `spawnNet`). Additions beyond it are experimental |
| `std:meta` (with `std:metacore`, `std:metajson`) | `meta.or`, `metacore.or`, `metajson.or` | **Experimental** (ADR-0046 slice S3; not an API users should depend on yet) |
| `std:html`, `std:ox` | `html.or`, `ox.or` | **Experimental** (OX providers; stability.md) |
| Internal, never API | `std:taskcore`, `std:fsraw`, `std:clock`, `std:core`, `bytes_internal.or`, `collections_internal.or`, `<module>/internal` | Not frozen, not exported to users (ADR-0048 section 7.3). A user import warns; see C8 |

This table must equal the "Experimental and unstable" table of [stability.md](../stability.md) after the I/O freeze: three
experimental rows (`std:meta`, OX with `std:html`/`std:ox`, `std:task` beyond Gate 1). Any difference is a bug in one of the two.

The frozen std also covers: the `Deprecated` wrappers that ADR-0048 section 9 keeps for one release (they are frozen until their
announced removal in a major version), the prelude method names, and the `std:` loader path spelling.

### 1.3 Tool surface

- **Diagnostic codes** (`Exxxx`, `Wxxxx`): the set in [reference chapter 10](../reference/10-diagnostics.md) and its meanings. A code
  is never reused for a different meaning; message text is not frozen.
- **`orin.toml` and `orin-workspace.toml` keys**: the keys documented in reference chapter 6 (`[package]`, `[architecture]`,
  `[contracts]`, `[modules.*]`, `[annotations]`, `[effects]`, `[dependencies]`, workspace `members`/`default-members`). Unknown keys
  stay errors (E0503/E0504). `orin.lock` format version is part of the contract.
- **CLI**: the commands and flags of [docs/cli.md](../cli.md) and `orin help`: `init build run dev test fmt check clean expand
  add remove fetch update deps workspace toolchain doctor explain verify effects graph diff api mir compile lsp mcp version`, their
  documented flags, exit statuses, and the `--format=json` schemas (`schemaVersion: 1`) of the commands that have one. Not frozen:
  human-readable output, colour, progress, undocumented flags, `orin mir` and `orin compile` flags other than `--format=json`
  and `-o` (they expose the MIR and the generated code, which are not stable, [stability.md](../stability.md)). Criterion C12 lists
  the commands that must first be documented.
- **Not frozen in any release**: runtime ABI, MIR, generated C and LLVM IR, `build/` layout, the OSIG schema version number (it has
  its own versioning, [ADR-0023](0023-osig-schema-v0.1.md)).

## 2. After the freeze

### 2.1 Allowed in a beta, rc or minor release without a new ADR

- **Semantic fixes** where the implementation deviates from the reference or an ADR (D11); a wrong result, a missed trap or an
  unspecified order fixed to the documented one.
- **Soundness fixes**, even when a program that compiled stops compiling (a check that was too weak, E04xx on a verifier gap).
  Each is a changes fragment marked "may reject previously accepted programs" and carries a conformance test.
- **Additive std**: new modules, new exported names, new functions on existing types, new error *variants* only where the error
  type is documented as open (otherwise a new variant is additive for the producer and breaking for exhaustive `match`; such a
  change needs the ADR route).
- **New diagnostics** (new codes) and new warnings; a warning never changes the exit status. Rejecting more programs with a new
  *error* is a soundness fix only under the previous bullet.
- **New tooling**: new commands, new flags, new JSON fields (consumers must ignore unknown fields), LSP/MCP features.
- **Performance and implementation work**: optimiser, backends, scheduler (roadmap Gate 2), runtime R3, compile time, memory use,
  verifier strength (more contracts proved; never fewer for the same input without a changelog entry).
- **Reserved-token features** that were reserved for exactly this (bit operators, `i128`/`u128`) when their ADR is accepted.
- **Deprecation**: `@Deprecated` with a replacement, W0440; removal not before the next major version.
- **Documentation and experimental modules**: anything marked experimental in section 1.2.

### 2.2 Needs a new ADR (additive language change)

Any change to the accepted grammar or typing rules that accepts more programs: new syntax, new keywords taken from the reserved
list, new declaration forms, new generic features (generic interfaces, default methods), `async`/`await`, a changed meaning of an
existing std name that does not change a signature. Accepted by ADR, shipped in a minor release, reference chapter updated in
the same PR.

### 2.3 Needs a new ADR and a major version

Removing or renaming a frozen std name or module (after the deprecation period), changing a frozen signature or error type, changing
the meaning of existing valid syntax, un-reserving or repurposing a keyword, removing a CLI command or documented flag, changing a
documented `orin.toml` key, reusing a diagnostic code with a different meaning, moving a frozen module to experimental, removing a
platform from the supported list.

### 2.4 Between betas

A breaking change after `beta.1` and before `1.0.0` requires a new beta (`beta.2`), a changelog entry with the heading "Breaking",
and a line in this ADR's history. The rc stage (`-rc.N`) accepts only fixes (stability.md).

## 3. API snapshot mechanism (proposal, not implemented)

State today:

- `orin api [--check <snapshot>] <entry.or | package-dir>` exists (`compiler/main.or` `runApi`, `compiler/analysis/apisnap.or`,
  launcher `dist/orin-cli.sh`). It prints the public API of a **package** (header `orin-api 1`, one block per module, exported
  declarations with full signature lines, annotations, inferred mutability) and with `--check` prints a diff and exits 1 on a
  change. Golden: `tests/next/packages/shop.api.txt`, run by `tools/test_packages.sh` and the CI job "Packages".
- `orin api` is **not documented in [docs/cli.md](../cli.md)** (only in `docs/osig.md`, ADR-0024 and the usage string) and the
  roadmap's evidence column ("API snapshot (`orin api`) committed per release") has no committed snapshot yet.
- `orin api` type-checks the program with the **std prelude not loaded** (`docs/osig.md`). `library/std` is an embedded library
  root with no `orin.toml`, not a package, so `orin api` cannot be pointed at a std module today. This is the one thing the
  mechanism below needs that does not exist.

Proposal:

1. **Layout.** A top-level directory `api/` with one snapshot per frozen module, named by import path:
   `api/std/bytes.api.txt`, `api/std/json.api.txt`, `api/std/json/number.api.txt`, ..., plus `api/prelude/array.api.txt`,
   `map`, `core`, `collections`. Experimental modules are snapshotted under `api/experimental/std/` so changes are visible but are
   not a CI failure. Internal modules have no snapshot. A header line carries the language version the snapshot belongs to.
2. **Producer.** A new mode, `orin api --std <module>` (or equivalently `orin api std:<module>`), that loads one embedded std
   unit as the program and prints exactly the existing `orin-api 1` format. Until it exists the same output can be produced by
   a script in `tools/` that wraps a one-file entry importing nothing but the module. Implementing this is a separate PR
   (criterion C11); this ADR does not implement it.
3. **Consumer.** A CI step (next to the "Packages" job in `.github/workflows/ci.yml`, and in `tools/ci_local.sh`) runs
   `orin api --std <m> --check api/std/<m>.api.txt` for every frozen module and the same for the packaged examples. A mismatch fails
   CI with the diff. A missing snapshot for a module that is not on the experimental list and not internal also fails (the list
   comes from one file, `api/MODULES`, which is checked against `stability.md` by `tools/check_reference.py` or a sibling script).
4. **Changing the API.** After the freeze an intentional API change is a PR that edits the snapshot file. The `changes/` fragment
   must say whether it is additive (only added lines), or breaking (removed or changed lines); a script classifies the snapshot diff
   and fails an unclassified removal on a branch that is not a major version.
5. **Release evidence.** The release workflow attaches the `api/` tree (tarball) to the release, so each tag has its snapshot. The
   roadmap's "API snapshot committed per release" is then true by construction.
6. **Complement.** `orin diff` (OSIG based) stays the richer comparison tool; `orin api --check` stays the reviewed contract
   (`docs/osig.md`). Neither covers diagnostic codes: chapter 10 of the reference plus `tools/check_reference.py` (extended to
   compare against the codes the compiler emits) covers them (C10).

## 4. Entry criteria: when the freeze may be declared

The freeze is declared (and `1.0.0-beta.1` tagged) only when every row is closed. The tracker column names the file or PR that
holds the evidence; issue numbers are to be filled in when the issues are opened.

| # | Criterion | Tracker / evidence | State on this branch |
|---|---|---|---|
| C1 | ADR-0040 (generic methods, `void` type arguments) implemented and merged, E0460 removed from `compiler/check/classes.or`, reference chapters 2, 3, 8 lose their "pending" notes | ADR-0040; roadmap 3.1, M1; `docs/reference/README.md` "Pending features" | done (#40: generic methods implemented; E0460 is emitted only for generic methods on interfaces, TYP-20/20a, GRM-6) |
| C2 | ADR-0034 remainder decided: `Set<T>`, `SortedMap<K,V>`, `PriorityQueue<T extends Ord>` in the frozen std, or the `IntSet`/`StringSet` aliases explicitly accepted forever | ADR-0034 "Implementation status"; roadmap 3.1 | done (#40: ADR-0034 addendum freezes `Set<T extends Hash>`, `OrderedMap<K extends Ord,V>`, `MinHeap<T extends Ord>`, `SortedMap<V>`, `SortedStringMap<V>`, `PriorityQueue<T>` and the `IntSet`/`StringSet` classes as they are) |
| C3 | ADR-0048 migration rows 1-8 merged (docs backfill and `apitable` generator, collection vocabulary and verbs, error shape, sentinels, options records and `Duration`, internals to `internal` submodules, JSON consolidation, `Eq/Ord/Hash` and ADR-0040 twins) | ADR-0048 section 9; roadmap M1; `changes/2026-10-16-std-*.md`, `2026-10-16-std-url-adr0048.md` | partial: rows 2, 3, 5 (url), 7 merged for bytes, encoding, utf8, url, collections, graph, json; `fs`, `host`, `net`, `task`, `time` not migrated; rows 4, 6, 8 open |
| C4 | `std:fs` completeness for CLI tools (`exists`/`listDir` as `Result`, rename, remove, atomic write) and a decision on argv-based process spawn | roadmap 3.2; `docs/release-1.0-readiness.md` "Files and clocks" | open |
| C5 | **Std I/O freeze taken** by the owner: signatures of `std:host fs process io time net task` confirmed after ADR-0048; "unstable" labels removed from `docs/std.md` and sources except the experimental list | ADR-0016 amendment, ADR-0027 open questions; roadmap 3.2; D6 | open (this ADR recommends the decision in section 6) |
| C6 | Concurrency Gate 1 merged and its API reviewed against ADR-0048: C0-C5 (C2 trap-safe cleanup written in Orin inside R3e) | ADR-0017 Addenda B-D; roadmap M3a; `changes/2026-10-17-concurrency-c*.md`, `2026-10-17-net-interruptible-waits.md` | partial: C0, C1, C3, C4 have fragments; C2 and the C5 acceptance campaign not evidenced |
| C7 | Reference gaps closed: every item under "Gaps" in chapters 1-10 either has a test or is struck from the rules; `python3 tools/check_reference.py` green; "Known discrepancies" 1-10 resolved (guide fixed or compiler fixed), in particular items 4, 6, 7, 9 | `docs/reference/README.md`, `*/Gaps: rules without a test`; roadmap 3.8 | open (draft written 2026-10-17, review pending) |
| C8 | `internal` import warning enforced by the loader; no `taskcore`, `metacore`, `metajson` or `*_internal` name reachable as API without warning | ADR-0048 section 7.3 | done (#45: the loader warns W0493 when code outside std imports an internal module) |
| C9 | Language items of roadmap 3.1 closed: records/variants over 64 slots a compile-time error instead of a run-time trap; privacy leak of exported signatures decided (known discrepancy 6) | `docs/progress.md` follow-ups; `docs/known-limitations.md`; reference README item 6 | done (#47: E0305 for more than 64 slots, E0306 for exported signatures that name a private type) |
| C10 | Diagnostic-code inventory: chapter 10 lists every emitted code (check script compares against `compiler/`), no code without a test except those named in its Gaps section | `docs/reference/10-diagnostics.md`; `tools/check_reference.py` | done (`tools/check_reference.py` compares 95 emitted codes with chapter 10 and its Gaps, run by the CI `changes` job) |
| C11 | API snapshot mechanism implemented (section 3: `orin api` on std modules, `api/` tree, CI check) and snapshots committed for every frozen module | this ADR section 3; `tests/next/packages/shop.api.txt` as format reference | open (`orin api` exists for packages only) |
| C12 | CLI documentation complete: `orin api`, `graph`, `diff`, `effects`, `verify`, `mir`, `expand`, `explain` flags in `docs/cli.md`; `explain` covers every code or the page says it does not (today four codes) | `docs/cli.md`; `dist/orin-cli.sh` | done (docs/cli.md command reference; explain covers 14 codes, stated there; tools/test_cli.py) |
| C13 | Agent-ergonomics benchmark run on the beta candidate; its findings that justify syntax or name changes are made before the freeze, not after | roadmap 3.5 and M4 | open |
| C14 | Experimental list final: owner confirms `std:meta`, OX with `std:html`/`std:ox`, `std:task` beyond Gate 1 (or promotes OX to frozen); `docs/stability.md` and `docs/std.md` agree with section 1.2 | D6; `docs/stability.md` | done (#40: `std:meta`, `std:html`, `std:ox` experimental, `std:task` Gate 1 frozen; stability.md and std.md agree) |
| C15 | ADR-0016 amended once (D2): ADR-0034, ADR-0040, user annotations, `std:task` Gate 1 in the core; "core complete" clause relaxed per D5; HTTP line corrected | roadmap D2, D5; ADR-0016 | done (#40: ADR-0016 amendment of 2026-10-18) |
| C16 | Runtime/release prerequisites that make the beta installable: R3d/R3e merged or deferred by D8, platform dry runs for the D4 list, org move and tap (M0) | roadmap M0, M2, D4, D8; PR #149, #150 | not part of the language freeze; tracked by M0/M2/M5 |
| C17 | `docs/stability.md` and `docs/roadmaps/orin-1.0.md` updated to the final wording (section 7) | this ADR section 7 | open |

C1 to C3 and C5 change names or syntax and must precede the freeze. C6, C8, C9 and C13 can change names and must also precede
it. C16 does not change syntax or names but gates the beta release itself (roadmap M4 entry).

## 5. Open items that would break the freeze if left open

Collected from the roadmap and the "Gaps" and "Known discrepancies" sections of the reference. Only items that change syntax,
names, or accepted programs are listed.

| Item | Why it breaks the freeze | Source | Covered by |
|---|---|---|---|
| Generic methods (`s.spawn(f)`, one `withX` instead of `withX`/`useX`/`*Do` twins) | Adds syntax and removes about 25 std twin names (`*Do`, `use*`) after the freeze | ADR-0040; ADR-0048 section 6; reference README item 9, 03-types, 08-concurrency gaps | C1, C3 |
| `Set<T>`, `SortedMap<K,V>`, `PriorityQueue<T extends Ord>` vs `IntSet`/`StringSet`/`SortedMap<V>`/`PriorityQueue<T>` | The frozen names would carry the specialised variants forever | ADR-0034 "Implementation status"; ADR-0048 section 5.2; roadmap 3.1 | C2 |
| ADR-0048 renames not yet applied to `fs`, `host`, `net`, `task`, `time`; `parallelMap` deprecated; `Sender.send -> Result`; private fields; `taskcore` internal | Renames of user-visible names; wrappers cannot be added for the modules that are "unstable without wrappers" | ADR-0048 sections 6, 7, 9 | C3, C5, C6 |
| `std:fs` has no directory iteration, rename, atomic write; no argv process API; no `sleep` outside `std:task` | Missing names that a CLI tool needs; adding later is additive, but the *shape* (`Result`, grant first) must be frozen with the rest | roadmap 3.2 | C4, C5 |
| `std:task` beyond Gate 1; cancellation, `select`, timed waits, trap-safe scopes, generic-method forms | Public names of the concurrency surface; C2 (cleanup after a trap) changes observable semantics | roadmap 3.3; reference chapter 8 gaps ("cancellation of channel waits and of a scope by a trapped task", "`timeout` arm for `select`") | C6 |
| Records/variants limited to 64 slots, trap at run time | A valid-looking program traps; turning the trap into a compile error later rejects programs that "compiled" | `docs/known-limitations.md`; `docs/progress.md`; roadmap 3.1 | C9 |
| Privacy: a private type may appear in an exported signature and an importer reads its fields | Closing the hole rejects programs; keeping it makes the hole part of the contract | reference README item 6, 06-modules MOD-7 gap | C9 |
| Equality/`Map` key rules differ between `docs/bootstrap-subset.md`, ADR-0018 and the compiler | Which programs are valid must be one statement | reference README items 1, 2 | C7 |
| Diagnostics text mentions "Orin-B" (E0402, E0408); E0402 for nested patterns is only a message | Message text may change; the *code* for nested patterns must be settled (is it E0402 or a future feature?) | reference README item 7; 04-expressions gap EXP-16 | C7, C10 |
| Evaluation order of operands, arguments, assignment target vs right side is untested | Observable semantics; either pin or declare unspecified before it is relied on | 04-expressions gaps EXP-20, EXP-21 | C7 |
| Run-time checking of loop `@Invariant` and `@Decreases` does not exist (parsed, type-checked) | A user may assume checking; adding checking later makes programs trap | 07-annotations gaps; `docs/contracts.md` | C7 (state it as semantics, or implement) |
| Tier 3 `Eq/Ord/Hash` law proofs and `@Property` | Additive; listed so it is not mistaken for a blocker | reference TYP-36 | none (post-1.0) |
| Entry point: `main()` or `main(host: Host)` vs documented `function main(): void` | Documentation only; the accepted forms must be stated once | reference README item 10 | C7 |
| `std:json/legacy`, `bytesFromHex` and the other deprecated wrappers | They are frozen until removed in a major version | ADR-0048 section 9 | section 1.2 |
| OX syntax and `ox` provider import | New syntax that is permanent if OX is frozen | ADR-0043, ADR-0044; stability.md | C14 |
| `std:meta` status text: stability.md and std.md say "not yet called by the compiler", ADR-0046 header says S1-S6 implemented | `std:meta` is experimental so it does not block, but the `@Processor` *syntax* is frozen and the three documents must agree on what is implemented | ADR-0046; reference chapter 7; stability.md | C14 |

## 6. Decision

Taken by Claude on the owner's instruction "entscheide du das" (roadmap decisions stay overturnable by the owner; a reversal is a new
ADR). Each is the recommendation of the roadmap or the option that keeps the freeze smallest.

1. **What `1.0.0-beta.1` freezes:** syntax, keywords and reserved words, std module paths and exported names (frozen modules
   of section 1.2), diagnostic codes, documented `orin.toml` keys, documented CLI commands and flags. (D11.)
2. **Mechanism:** the reference grammar plus per-module `orin api` snapshots under `api/` with a CI check (section 3). Prefer a
   mechanical check over a promise.
3. **Std I/O freeze (C5): take it at M4**, after ADR-0048 has migrated `fs`, `host`, `net`, `task`, `time`. Freeze `host`, `fs`,
   `process`, `io`, `time`, `net` and the `std:task` Gate 1 API; keep everything beyond it experimental. If a module is not ready at
   the candidate (for example `process` without an argv API), it goes onto the experimental list rather than blocking the beta.
4. **Experimental list stays three rows** (`std:meta`, OX with `std:html`/`std:ox`, `std:task` beyond Gate 1), per D6. OX
   syntax is part of the frozen grammar only if the owner promotes OX; the default is that OX stays experimental.
5. **ADR-0040 is in the freeze** (D2a): the beta waits for it. ADR-0034's remaining std types are in the freeze; the
   `IntSet`/`StringSet` stay as frozen classes next to the generic types, not as separate designs (ADR-0034 addendum, #40).
6. **`async`/`await` stay reserved and unused** at 1.0 (D1 option B). Adding them later is an additive ADR.
7. **Entry-criteria gate:** the owner declares the freeze only after C1 to C15 are closed; C16 gates the release, not the
   freeze. The first line of the `1.0.0-beta.1` changes fragment links this ADR.
8. **Breaking changes after `beta.1`** need a new beta and a changelog heading "Breaking" (section 2.4).
9. **Records over 64 slots become a compile-time error and the privacy leak is closed before the freeze** (C9): both reject more
   programs, which is cheaper before the promise than after.

## Alternatives considered

- **Freeze at 1.0.0-rc.1 instead of beta.1.** A smaller promise before the agent-ergonomics findings and Homebrew users; but it
  makes the beta useless as a stable channel and moves the std rename pressure into the release candidate. Rejected by D11.
- **Freeze only the syntax at beta, the std at rc.** Cheaper for the std migration; but renames after the beta break every
  early user, and the std is where agents spend most of their tokens. Rejected.
- **Freeze everything, no experimental list.** Simplest to state; would freeze `std:meta` (ADR-0046 S3, not yet used by the
  compiler) and OX provider details. Rejected per D6.
- **Editions instead of a frozen beta.** Allows breaking later without a major version; roadmap 3.9 proposes none at 1.0 and the
  ADR-0016 rule (changes only by ADR, additive) plus semver suffices until a break is wanted.
- **API snapshot as one file for the whole std.** Smaller to review but one conflict point for every std PR; per-module files
  match the one-PR-per-row migration of ADR-0048.
- **Generated reference only, no committed snapshots.** Cannot detect an accidental change; the snapshot diff is the check.
- **Keep the I/O modules unstable through 1.0.** Avoids the decision; but ADR-0016 already promised an I/O freeze and
  `fs`/`net`/`time` are what most programs import first. Fallback only per decision 3.

## 7. Documents to change when this ADR is accepted

- [stability.md](../stability.md): the versioning table says the beta is "Not frozen yet" while D11 says `1.0.0-beta.1` freezes
  syntax and std names. Reword to "`0.1.0-beta.N`: not frozen; `1.0.0-beta.N`: syntax and std names frozen, semantic fixes
  allowed". The "Also unstable until the owner confirms the std I/O freeze" paragraph is removed with C5.
- [roadmaps/orin-1.0.md](../roadmaps/orin-1.0.md) M4 row: link this ADR as the definition of the freeze; section 3.9 likewise.
- [docs/cli.md](../cli.md): add the commands of C12.
- [docs/reference/README.md](../reference/README.md): add a "Frozen at 1.0.0-beta.1" note and the maintenance rule of section 1.1.
- ADR-0016: one amendment (C15), listed in the roadmap as D2.

## Consequences

- Beta users get a checkable promise: an unchanged `api/` tree and a green reference check mean the names did not move.
- The beta date depends on C1, C3 and C5, which are the longest items (ADR-0040 touches the checker's hot area; ADR-0048 rows
  4, 6, 8 and the I/O modules are not migrated). The roadmap's critical path (ADR-0040/0034, then ADR-0048 row 8, then M4) is
  unchanged.
- A mistake in a frozen name costs a deprecation period and a major version; the criteria are deliberately front-loaded.
- Everything not listed (runtime ABI, MIR, generated code, output formats) keeps its freedom to change.
