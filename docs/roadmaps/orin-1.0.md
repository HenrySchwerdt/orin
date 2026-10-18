# Orin 1.0 roadmap

Status: **proposal; defaults taken 2026-10-16** (see [Defaults taken](#defaults-taken-on-2026-10-16)), 2026-10-16. Factual baseline: `origin/main` at `5029153`
(merge of PR #146). This document is a plan. It implements nothing and changes no accepted decision by itself.
Where it proposes to change an accepted ADR, the text says so and the change is listed in
[Decisions for the owner](#5-decisions-for-the-owner); the defaults below are being implemented, each with its own ADR or amendment.
Sizes are relative (S/M/L), not durations.
Statements marked _(inference)_ are the author's reading of the sources, not something a document states.

## Defaults taken on 2026-10-16

Henry said "mach die Sprache erstmal fertig" (finish the language first, then provability). Work therefore proceeds on the
recommendation of every open decision. Henry can still overturn each one; a reversal is a new ADR or amendment.

| D# | Default taken (the recommendation of section 5) |
|---|---|
| D1 | Option B: OS threads, cancellation, deadlines, `select`, sleep, concurrent sockets; later an M:N scheduler behind the same API; no `async`/`await` in 1.0 |
| D2 | Amend ADR-0016 once: add ADR-0034/0040, the D1 `std:task` surface and user annotations; relax the "core complete" clause per D5 |
| D3 | HTTP/1.1 client and server over `std:net` without TLS; TLS post-1.0 behind a reverse proxy |
| D4 | linux-x86_64, macos-arm64, linux-aarch64, macos-x86_64 with a dry run each; Windows via WSL2, native Windows post-1.0 |
| D5 | Amend: 1.0 requires a self-hosted, reproducible, behaviour-stable compiler, not the finished ADR-0015 rewrite |
| D6 | A short named experimental list; everything else frozen under ADR-0048 |
| D7 | Raise the L0 budget to 1,400 code lines by ADR, each addition with contracts and a CBMC harness (ADR-0054) |
| D8 | Do not gate 1.0 on R3f; gate on R3d/R3e being merged |
| D9 | Park T6 #98 and T5 #91 until after 1.0 |
| D10 | `v1.0.0-beta.1` at M4, `-rc.N` at M5, `--prerelease` tied to the tag suffix |
| D11 | Beta freezes syntax and std names; semantic fixes allowed |
| D12 | Static site generated from `docs/` and the language reference; hosting and tutorial authorship stay open |

Related plans this one consolidates and does not replace: [roadmap.md](../roadmap.md) (integrated
plan), [progress.md](../progress.md) (status), [release-1.0-readiness.md](../release-1.0-readiness.md)
(gates R1-R5), [async-concurrency.md](async-concurrency.md) (concurrency foundations).

## 1. What "1.0" means

Proposed definition of done. Every line needs the owner's confirmation (section 5).

| Promise | Content | Evidence required |
|---|---|---|
| Language stability | Syntax and semantics of the ADR-0016 core, plus the additive items accepted since (ADR-0034, ADR-0040, ADR-0046 user annotations, the concurrency surface chosen in D1). Changes after 1.0 are additive or go through a major version | Conformance suites `tests/run`, `tests/errors`, `tests/next` green on the release SHA, C and LLVM; `docs/ts-developers.md` examples are tests |
| Standard library stability | Every module not marked experimental follows [ADR-0048](../decisions/0048-std-api-conventions.md); the std I/O freeze of ADR-0016 is taken; removals go through `@Deprecated` for one release | API snapshot (`orin api`) committed per release; list of experimental modules published |
| Supported platforms | A named list, each with a CI job and a clean-install dry run on the release artifact (gate R5) | Per-platform dry run; see D4 |
| Release artifacts | Checksummed tarballs, `install.sh`, Homebrew tap, VS Code extension; a release that is not marked pre-release | Release workflow run on the candidate SHA |
| Documentation | Language reference, std reference generated from source (ADR-0048 section 8), install and tutorial pages, honest limits page | Link check, examples compile (gate R4) |
| Assurance statement | What is proved, tested, trusted ([tcb.md](../tcb.md), [assurance.md](../assurance.md)) stated without end-to-end claims | See section 3.7 |

Not promised by 1.0: end-to-end formal safety, a verified C runtime, ABI stability between versions,
a package registry, OS-level sandboxing ([known-limitations.md](../known-limitations.md),
[capabilities.md](../capabilities.md)).

## 2. Where we are

Evidence column points to the file that states it; "main" means `5029153`.

| Area | State | Evidence |
|---|---|---|
| Core language (generics, classes, closures, interfaces, integers, interpolation, resources, generic classes, `Map`, floats) | done; 128-bit integers, bit operators, generic methods, default/rest args, inheritance not available | [progress.md](../progress.md) matrix, [ADR-0016](../decisions/0016-language-1.0-core-scope.md), [known-limitations.md](../known-limitations.md) |
| Compiler pipeline, MIR verifier, C and LLVM backends | done; LLVM is the `--release` default (pinned LLVM 19.1.7); bootstrap and LLVM fixed points in CI | progress.md "Open work" item 4, [ADR-0038](../decisions/0038-performance-model.md) |
| Compiler rewrite (ADR-0015) | partial: `compiler/vc/` and some `check/` files remain | progress.md matrix row "Compiler rewrite", item 6 |
| Compiler cleanup and parallel build (ADR-0049) | steps 1-8 and 11 merged; step 9 helper (`mapOrdered`) and `orin test`/`orin fmt` in parallel merged; PR #148 (parallel z3) pending; split C units, per-function parallel phases, sharing decision open | `git log` (#144, #145), [ADR-0049](../decisions/0049-compiler-cleanup-and-parallel-compilation.md) |
| Repository layout (ADR-0047) | `library/`, `compiler/backends/`, `bootstrap/seed/`, `tooling/` exist; Python tools ported in phases 4-5 | `ls`, git log (#125, #143); ADR-0047 header still says "proposed" (see section 6) |
| Annotations (ADR-0046) | S1, S2, S3 merged (metadata only, `std:meta` unstable); S4-S6 not started | [ADR-0046](../decisions/0046-typed-annotation-processors.md) header |
| Std API unification (ADR-0048) | accepted, **not started**; migration waits on layout (done) | [ADR-0048](../decisions/0048-std-api-conventions.md) section 9 |
| Std surface | bytes, utf8, collections, http (pure), net (blocking TCP), encoding, url, JSON (legacy + exact `jsonvalue`/`jsondecode`), fs, path, time (wall + monotonic, no sleep), process/io (`shell`), html/ox, test, meta | [std.md](../std.md), [std-time-monotonic.md](../std-time-monotonic.md) |
| Concurrency | stage 0: OS-thread tasks, bounded channels, grant delegation, fork/join pool, `.parallel()`; no cancellation, select, timed waits, scheduler, async/await | [concurrency.md](../concurrency.md), [ADR-0017](../decisions/0017-concurrency-design.md) Addendum A |
| Runtime | R1, R2 done. R3 (ADR-0052): R3a+R3b in PR #141, R3d design addendum in progress, R3c/R3e/R3f not started. L0 is at **999 of 1,000** code lines | [ADR-0052](../decisions/0052-runtime-r3-and-the-c-endpoint.md); line count measured with the `tools/verify_platform.sh` method on main |
| Capabilities | Stage A and B done; C-D (adapters, lineage, strict policy) not started | progress.md matrix |
| Verification | contracts with z3, Lean models `MODEL_ONLY`; independent MIR verifier on every compile | [tcb.md](../tcb.md), [assurance.md](../assurance.md) |
| Tooling | fmt, LSP, MCP, OSIG, explorer, VS Code extension (not on Marketplace) | progress.md, [install.md](../install.md) |
| Incremental analysis | not started | progress.md matrix |
| Distribution | `v0.1.0-alpha.2` published for linux-x86_64 and macos-arm64 only; workflow builds four targets, always `--prerelease`; no Windows build; macOS not notarised; Homebrew tap and org move prepared (PR #149, #150) | [install.md](../install.md), `.github/workflows/release.yml`, [windows.md](../windows.md) |
| Release gates R1-R5 | R1, R2 fixed (PRs #82, #86 merged per [night-shift handoff](../release-1.0-nightshift.md)); R3 (stable scope), R4 (accurate claims), R5 (candidate evidence) open | [release-1.0-readiness.md](../release-1.0-readiness.md) |
| Performance | wave essentially done; T5 (#91) parked, T6 (#98) awaits an owner decision | progress.md "Open work" |

## 3. Gaps for 1.0

### 3.1 Language core

| Item | Today | Proposal |
|---|---|---|
| Generic methods and `void` type arguments ([ADR-0040](../decisions/0040-generic-methods-and-void-type-arguments.md)) | implemented: class methods may be generic and `void` is a type argument; E0460 remains only for a generic **interface** method (`compiler/syntax/parser.or`), which is the final rule. `s.spawn(f)` is a method of `Scope` and the `std:task` twins are `@Deprecated` wrappers | Done for 1.0. Removing the host/fs/net `with*`/`use*` twins (ADR-0048 row 8) is std work, not a language change |
| `Eq`/`Ord`/`Hash` constraints ([ADR-0034](../decisions/0034-eq-ord-hash-constraints.md)) | accepted; slice 1 (checker and lowering: `T extends Eq/Ord/Hash`, derived `==`/`<`/`compare`/`hash`, explicit `equals`/`compare`/`hash` on classes, generic `Map` keys) implemented; `Set<T>`, generic `SortedMap<K,V>`, `PriorityQueue<T extends Ord>` (std) and the tier-3 law proofs remain (ADR-0034 "Implementation status") | In 1.0 if the std is to be frozen with `Set<T>`; otherwise the frozen std contains `IntSet`/`StringSet` aliases forever (ADR-0048 section 5.2 prepares aliases). Size M-L |
| Struct with more than 64 slots | traps at run time (progress.md follow-ups, known-limitations) | Done: compile-time error E0305 (freeze C9, #47) |
| `i128`/`u128` | E0431, post-1.0 by owner decision (ADR-0016) | Stay post-1.0 |
| Bit operators | reserved, post-1.0 (ADR-0016) | Stay post-1.0; reservation text already protects the tokens |
| Value types (flat records, `Span` flattening) | measured and dropped for now (progress.md item 2: needs value types) | Post-1.0 unless the owner wants it; it is a representation change, not a surface change |
| `async`/`await` | reserved words in `compiler/syntax/lexer.or` `isReserved`; post-1.0 in ADR-0016 | See section 3.3 and D1 |
| Remaining ADR-0016 "core complete" clause | requires the compiler rewrite (ADR-0015) | Either finish `compiler/vc/` and the remaining `check/` files or amend the definition (D5) |
| Closures capture by value only, no mutation of captures | documented limitation | Keep; list in the stability page as semantics, not bug |

### 3.2 Standard library

| Item | Today | Needed for 1.0 |
|---|---|---|
| ADR-0048 unification (rename ~60 items, error shapes, `Duration` options, sentinel removal, `internal` submodules, one JSON module) | partly done (2026-10-18): rows 1, 2 and 7 are in (`compiler/mcp/apitable.or`, deprecated collection wrappers, one JSON module with `json/legacy`); rows 3 and 5 are partial (typed `NetError`/`TaskError`/`FsError`, `Duration`, `std:url`); row 6 is partial (`std:bytes/internal`, `std:collections/internal` exist; `taskcore`, `metacore`, `metajson` are not yet internal); row 8 is partial (`std:task` twins deprecated; `host`, `fs`, `net` `with*`/`use*` twins remain); row 4 has no evidence of completion; `Sender.send` still returns `bool` and `parallelMap` is not deprecated | Must land **before the freeze** because it renames user-visible names (ADR-0048 section 9). Finish the open rows in the ADR's order. Size L |
| std I/O freeze ([ADR-0016 amendment](../decisions/0016-language-1.0-core-scope.md), [ADR-0027](../decisions/0027-stage-a-root-capabilities.md) open questions) | `fs`, `host`, `process`, `io`, `time`, `net`, `task` unstable | Owner confirms signatures after ADR-0048; then remove "unstable" labels except the experimental list (D6) |
| `std:fs` completeness | whole-file and streaming; no directory metadata/iteration, rename, atomic write ([release-1.0-readiness.md](../release-1.0-readiness.md) "Files and clocks") | Add the minimum a CLI tool needs: `exists`/`listDir` as `Result` (ADR-0048 3.2), rename, remove, temp+atomic write. Size M |
| Time | wall and monotonic clock, `Duration`, deadline helpers; **no `sleep`** (`library/std/time.or` comment) | `sleep` needs a cancellable wait; delivered by the concurrency package (WP-C2), not as a blocking stub |
| Process | `shell(cmd)` and `shellTimeout`; no argv API, no captured streams | Argv-based spawn with captured bounded output and deadline (Windows semantics decision in [windows.md](../windows.md) applies). Size M |
| Network | blocking TCP with grants and deadlines; DNS synchronous; UDP not present | Concurrency package (3.3). TLS: D3 |
| HTTP | pure HTTP/1.1 message layer only; ADR-0016 lists HTTP post-1.0 | A client/server on top of `std:net` is an application of 3.3; whether it is 1.0 scope is D3 |
| JSON | exact numbers and bounded documents exist as opt-in modules; legacy `Json` rejects fractions | Consolidation into one `std:json` is ADR-0048 section 7.1; typed `parse<T>` comes from ADR-0046 S6 (`@Json`) |
| Misc library gaps | CLI options, logger, decimal, CSV/TOML, random/UUID, databases ([agent-stdlib-priorities.md](../agent-stdlib-priorities.md)) | Not 1.0 blockers per the readiness audit; ship what has a useful example and tests, list the rest as post-1.0 |
| Docs generated from source | `compiler/mcp/apitable.or` hand-written; `docs/std.md` claims every function documented | ADR-0048 section 8: generator and `orin doc --check` CI check (first row of the migration) |

### 3.3 Concurrency and async

The owner wants async and multithreading in 1.0. This section inventories what exists, states what 1.0
concurrency needs under any option, and then compares three options. It builds on
[async-concurrency.md](async-concurrency.md) (foundations before syntax) and does not contradict its
order: that document's steps 1-5 are the work packages below.

#### 3.3.1 What exists (main)

| Capability | Exists | Evidence |
|---|---|---|
| Tasks | `scope`/`spawn`/`join`, one OS thread per task, own heap, non-atomic RC, move-or-deep-copy transfer; `join` of a trapped task traps the joiner | [concurrency.md](../concurrency.md), `library/std/task.or`, ADR-0017 Addendum A |
| Channels | bounded FIFO, blocking `send`/`recv`, explicit `close`; no "all senders gone" | same |
| Grants into tasks | fs, process, stdio, clock delegated via one-shot tokens; **net not delegable** | concurrency.md "Grants"; async-concurrency.md |
| Data parallelism | `.parallel()` on arrays (ADR-0039): work-stealing fork/join pool for one call, ordered results, `ORIN_THREADS` | [ADR-0039](../decisions/0039-parallel-array-pipelines.md), `forkJoin`/`forkJoinUntil` |
| Network I/O | blocking TCP, per-call timeouts, whole-operation deadlines in helpers; DNS synchronous; Listener/Stream are scoped resource handles | [ADR-0033](../decisions/0033-l0-network-primitives.md), `library/std/net.or`, E0450-E0452 |
| Clocks | wall `nowMillis`; monotonic `monotonicNow` + `Deadline` helpers (landed after the async roadmap's baseline) | [std-time-monotonic.md](../std-time-monotonic.md) |
| Assurance | threads/monitors/transfer are `TESTED_ONLY` (TSan, ASan/UBSan, stress) | [tcb.md](../tcb.md), concurrency.md |
| Windows | no thread backend | [windows.md](../windows.md), concurrency.md "Not in stage 0" |

Missing: cancellation, timed waits, `select`, `sleep`, deadlock detection, nested-scope cleanup after a
trap (children can outlive a trapping parent; the trapped task's heap leaks), network handles in tasks,
any scheduler that parks a logical task, `async`/`await`.

#### 3.3.2 Needed under every option (the floor)

These are the async-concurrency.md steps. Without them no option delivers usable servers.

| WP | Content | Size | Touches | Notes |
|---|---|---|---|---|
| C0 | ADR amendment to ADR-0017: cancellation tree, outcomes (completed / closed / cancelled / deadline / error), exactly-once result and token ownership, cooperative checkpoints; plus pure state machines in `taskcore` | M | `docs/decisions`, `library/std/taskcore.or` | Pure Orin, provable fragment; can start now |
| C1 | Timed and wakeable waits: `recvTimeout`/`joinTimeout`/`select` over channels and a `sleep`, using one absolute monotonic deadline | M | `library/std/task.or`, L0 monitor wait | **L0 is at 999/1000 code lines.** A timed monitor wait needs a budget decision or an offsetting reduction (D7) |
| C2 | Trap-safe structured cleanup: live-scope registry, parent trap cancels and joins descendants, primary/secondary failure reporting | M-L | runtime task code (temporary C) | Prefer implementing in Orin as part of R3e rather than growing the 342-line C interface that R3e deletes (see M2/M3 ordering) |
| C3 | Interruptible network waits and operation-wide deadlines (accept/read/write/connect), wake source in readiness wait, generation-tagged handles; DNS limitation stated or resolver pool | M-L | `library/std/net.or`, L0 net wait | Same L0 budget issue |
| C4 | Network ownership for concurrent servers: either delegate a net grant and move an accepted `Stream` into a task, or an acceptor task that owns sockets and exchanges bounded value messages with workers | M | ADR amendment (resources, E0450-E0452, E0483), checker, verifier rules like `grantMove` | Needs a language-level resource rule; this is the one floor item that touches the checker and the MIR verifier |
| C5 | Server acceptance campaign (1, 64, 1,024 clients; slowloris, non-reading peers, cancellation storms; C/LLVM parity; TSan) and a concurrent `examples/http_server.or` | M | `tests/concurrency`, `tests/net`, `examples/` | **Done (2026-10-17):** `tools/test_server_campaign.sh` (1 / 64 / 1,024 clients, slowloris, non-reading peers, cancellation storms, graceful shutdown, C/LLVM parity, TSan, ASan+UBSan; CI `concurrency` job) against `examples/http_server.or`, now the concurrent server. Results: async-concurrency.md "Server acceptance campaign" |
| C6 | Windows thread/monitor backend, if Windows is supported (D4) | M-L | `runtime/platform`, L0 budget again | Only if Windows is in the 1.0 platform list |

Everything in C0-C5 keeps the existing model: isolated tasks, non-atomic RC, move-or-copy transfer, no
new syntax. No MIR instruction is added (ADR-0017 "Consequences for verification").

#### 3.3.3 Options for the owner

| | A: structured concurrency on OS threads | B: A plus an M:N scheduler (no new syntax) | C: A plus `async`/`await` syntax |
|---|---|---|---|
| User sees | `scope`/`spawn`/`join`, channels, `select`, timeouts, cancellation, concurrent sockets. One thread per task | Same API as A. Tasks are cheap (target: tens of thousands of parked connections on W workers); blocking-style calls park the logical task. No function colouring | Colour: `async function`, `await`, futures, plus A's primitives |
| Matches the owner's wish | multithreading yes; "async" only as concurrent, cancellable I/O | multithreading yes; async I/O capacity yes; keywords no | both literally |
| ADRs | amend ADR-0017 (C0, C4). ADR-0016 unchanged | A, plus an ADR for the scheduler (TLS inventory, task identity). Matches the **original text** of ADR-0017 ("M:N scheduler in L1"), which Addendum A deferred, so it completes an existing design | A, plus **revise ADR-0016** (async/await moves out of "post-1.0" and the freeze) and **ADR-0017** ("only if blocking tasks prove insufficient"). New ADR: colours, suspension lowering, resources across `await`, cancellation, contracts and effects |
| Work packages | C0-C5 (+C6) | C0-C5, then S1-S4 below | C0-C5, then Y1-Y6 below |
| Size on top of the floor | none | L | XL |
| Runtime / L0 / TCB | L0 grows by timed wait and readiness wait (budget ADR). Temporary C stays until R3e | L0 grows further: a context switch per architecture (x86-64, arm64) or a stackful-coroutine primitive, readiness backend (poll baseline, epoll/kqueue only if measured). Scheduler queues, timers, policy stay in Orin (L1/L2). Context switching is assembly or `ucontext` (the latter is not dependable on macOS arm64 _(inference, verify)_) | Same L0 as A. Large compiler-side TCB growth: a state-machine lowering pass between HIR and MIR whose output the verifier must still check |
| MIR / verifier | none | none if stackful (a parked task keeps its native stack). Stackless would need new MIR and verifier rules | New suspend/resume points; ownership rules across `await`; resource handles (E0450-E0452) across suspension; Lean MIR model extension. Largest verifier change in the project |
| Per-task non-atomic RC | unchanged: a task is a thread, one owner | Holds if the invariant "a logical task runs on exactly one worker at a time, transfers are published with synchronisation" is enforced. Today's thread-local heap state (counters, free lists, destruction stack, trap pointer, grants and files; async-concurrency.md "Scheduler ADR questions") must move into the task record or be saved and restored at every switch | Futures hold captured values; running a future on another worker needs the same transfer rule as a task. Every `await` point is a place RC state can be observed mid-flight |
| R3 interaction | R3e ports the transfer and task C interface 1:1. C2 should be written in Orin inside R3e, not in C first | The scheduler's heap-state surgery is exactly R3d/R3e (`core.heap.TaskHeap`, `core.task`). Doing B before R3e builds it twice; roadmap.md step 5 gives this as the reason for ordering concurrency after R3 | Same dependency as B, and the compiler lowering also needs R3a's core-dialect work to be settled in `compiler/check` and `compiler/lower` |
| Freeze risk | lowest: API is library only | low for the **API** (identical to A); the scheduler is an implementation change behind it and can be released in 1.x if late | highest: new keywords and a colour rule are permanent surface; async runtime semantics become part of the stability promise |
| Honest assurance claim | `TESTED_ONLY` for threads, monitors, cancellation protocol; pure state machines can be proved | scheduler policy partly provable (pure queues/timers); context switch and readiness `TESTED_ONLY` | as B, plus the lowering pass is unverified TCB unless translation validation (ADR-0032) covers it |

Work packages for B (after the floor and after R3e):

| WP | Content |
|---|---|
| S1 | ADR: logical task identity, TLS inventory, grant ownership by task not by thread, no yield while holding an OS-thread lock, cancellation cleanup. Size M |
| S2 | One-worker scheduler: runnable queue, park/resume, stackful contexts, guard pages and stack-size policy. Size L |
| S3 | Shared readiness backend and timers in Orin over minimal L0 (poll baseline; epoll/kqueue only with measurements); bounded queues and admission failure. Size L |
| S4 | Multi-worker with migration; benchmark against the 1:1 baseline on recorded hardware (thread count, memory, latency tails); the acceptance campaign at capacity. Size L |

Work packages for C (after the floor and after R3e):

| WP | Content |
|---|---|
| Y1 | ADR revising ADR-0016/0017: colours, `Future<T>`/task handle relation, cancellation, resource handles across `await`, effect inference (`Task.Await` as OSIG event), contracts across `await` |
| Y2 | Lexer/parser/formatter (reserved words already exist), checker colour rule and diagnostics (TS-habit diagnostics, [ts-diagnostics.md](../ts-diagnostics.md)) |
| Y3 | HIR to MIR lowering to state machines, MIR version bump, both backends |
| Y4 | Verifier rules and Lean model for suspension; mutation corpus |
| Y5 | LSP, MCP, OSIG (`osig/0.5`), explorer, docs, `ts-developers.md` |
| Y6 | A runtime executor (needs S1-S4 or a single-threaded executor) and the same acceptance campaign |

#### 3.3.4 Recommendation

**Option B as the 1.0 target, delivered in two gates, with the API frozen at gate 1.**

1. Gate 1 (required for 1.0): the floor C0-C5 (Option A). It gives threads, structured concurrency,
   cancellation, deadlines, `select`, `sleep`, and concurrent sockets, with no new syntax. This is
   the surface the stability promise covers.
2. Gate 2 (targeted for 1.0, may ship in 1.x without an API change): S1-S4. Because the API is the
   same blocking-style calls, the scheduler is an implementation upgrade. If it is not ready at the
   release candidate, 1.0 ships on OS threads with the documented limit on connection count, and the
   release notes say so.
3. `async`/`await` keywords: not in 1.0. They are additive later (the words are already reserved in
   `compiler/syntax/lexer.or`), and a scheduler under blocking-style calls removes the main reason
   for colours: capacity. This is the evidence rule of ADR-0017 and async-concurrency.md ("Decision
   gate: is async/await needed?").

Reasons:
- A is on every critical path, so nothing is lost by starting it now (C0 and the pure parts do not
  depend on R3).
- B gives the capability the owner most plausibly needs from "async" (many concurrent connections,
  timeouts, cancellation) without a permanent language change and without a new verifier TCB for
  suspension.
- C is the only option that changes the frozen language surface, and it needs the largest verifier
  and Lean change while the project is trying to freeze. Its cost is highest exactly where assurance
  is the product.
- B before R3e would be built twice; hence the milestone order in section 4.

If the owner wants the keywords in 1.0 regardless, Option C is feasible only after B's S2 (it needs an
executor) and moves the 1.0 date behind S1-S4 plus Y1-Y6. That is a decision to make knowingly (D1).

### 3.4 Runtime (ADR-0052)

| Step | Content | Status | Notes for the sequence |
|---|---|---|---|
| R3a | core dialect in the compiler | PR #141 | touches `compiler/syntax`, `check`, manifest `core = true`; coordinate with ADR-0049 and ADR-0046 S4 |
| R3b | strings, numbers, arrays without allocation policy, in Orin | PR #141 | `runtime/core` plus new `core` modules |
| R3c | capability, fs, file, net, process shells over L0 | not started | must precede concurrency WPs that change net/fs shells (C3, C4) or be coordinated with them |
| R3d | allocator, small-block cache, RC, `make_unique`, destroy | design addendum in progress | ADR-0052 starts it only after the ADR-0038 `runtime/core` work (packed arrays, in-place reuse) is merged; progress.md lists that work as not built, so the gate is open (section 6); hot-path benchmark gate |
| R3e | task transfer and per-task heap | not started | **owner of the concurrency/runtime seam**; C2 and S1 depend on it |
| R3f | delete the C object model and `orin_runtime_llvm.c` | not started | until then C and Orin copies coexist; see D8 on whether 1.0 needs R3f |

L0 stays C (ADR-0052 decision 2). With L0 at 999/1,000 code lines, items C1, C3, C6 and S2/S3 need an
explicit decision (D7): raise the budget by ADR, or remove code first (for example formatting helpers
that R3b makes redundant _(inference)_).

### 3.5 Compiler and tooling

| Item | Today | Proposal |
|---|---|---|
| ADR-0049 remainder | steps 1-8, 11 merged; #148 pending; rows 12-18 open | Rows 12 (split C units) and 14-16 are build-time wins, not 1.0 blockers. Row 17 (`check/expr.or` split) must happen in a quiet window; schedule it between feature waves |
| Checker/VC rewrite (ADR-0015) | `compiler/vc/` and some `check/` files remain | Either finish (L) or amend ADR-0016's definition (D5) |
| Incremental analysis | not started | Post-1.0. LSP analysis cache (ADR-0049 row 11) is merged and suffices for 1.0 |
| LSP/VS Code | works; not on Marketplace | Publish before 1.0 (M4). Marketplace publication is an owner action |
| Diagnostics and CLI polish (roadmap 2a: `orin explain`, `orin fix`, `orin new`) | partly | `orin explain` and stable error-code docs are part of "documentation"; `orin fix` post-1.0 |
| Agent ergonomics benchmark (roadmap section 1) | measurement planned "before the 1.0 release" | Run once on the beta; its findings may justify syntax changes, so it runs before the freeze, not after (M4) |
| T5 #91, T6 #98 (performance) | parked/awaiting decision | D9 |

### 3.6 Distribution

| Item | Today | Needed |
|---|---|---|
| Org move to `orin-lang/orin-lang` | PR #150 prepared | M0. All URLs in `install.sh`, docs, `dist/`, workflow, VS Code manifest follow |
| Homebrew tap `orin-lang/homebrew-orin` | PR #149 | M0 |
| Platforms | linux-x86_64, macos-arm64 published; linux-aarch64 and macos-x86_64 built by the workflow but absent from alpha.2; Windows only via WSL2 | D4 |
| Release workflow | **Done:** pre-release status follows the tag suffix (`-alpha`, `-beta`, `-rc`); 1.0.0 publishes a normal release (`release.yml`). Note: `0.1.0-beta.1` is a pre-freeze beta; 1.0.0-beta waits for M4 | Keep as is. S |
| Notarisation and signing | not notarised | Not required for 1.0; document the quarantine workaround (already in install.md). Owner may want it for the Homebrew cask path |
| Toolchain requirements | needs a C compiler; LLVM optional and not bundled; Z3 for verification | Document precisely; `orin doctor` already reports them. Bundling LLVM is post-1.0 |
| musl / static Linux | glibc only | Post-1.0 |

### 3.7 Verification and assurance claims

What 1.0 can say, using the vocabulary of [assurance.md](../assurance.md):

| Claim | Status at 1.0 | Wording |
|---|---|---|
| Memory safety of compiled programs | independent MIR ownership verifier on every compile; Lean model of the RC machine (`MODEL_ONLY`); runtime shape checks as backstop | "Checked per compile and modelled in Lean; not proved end to end" |
| Contracts | partial correctness under listed assumptions, z3 trusted, no certificates | state limits as in [contracts.md](../contracts.md) |
| Runtime | tested C object model (R3 not complete) or tested Orin core (after R3d/R3f); L0 CBMC-bounded | per [tcb.md](../tcb.md) |
| Concurrency | race freedom by construction (isolated tasks); implementation `TESTED_ONLY`; no deadlock freedom, no fairness claim | per ADR-0017 "Assurance (honest)" |
| Capabilities | enforced checks, not an OS sandbox | per [capabilities.md](../capabilities.md) |

Not claimed at 1.0 (already planned, post-1.0): `.orcert` attestations, translation validation (ADR-0032),
R4 refinement proofs, `@NoTrap` modes beyond Stage A, lineage.

### 3.8 Documentation

| Item | Today | Needed |
|---|---|---|
| Language reference | `spec/` is a design RFC ("pre-implementation specification (v0.1)", `spec/spec.md`); no normative, traceable reference exists (roadmap.md step 4 lists one) **Draft written (2026-10-17):** [docs/reference](../reference/README.md), 10 chapters, each rule cites its tests, gaps listed per chapter, `tools/check_reference.py` checks the citations; review and gap-closing remain. | Write a reference from the implemented language: grammar, types, semantics, errors, each rule traced to a test. Size L. Prerequisite for the freeze claim |
| Tutorial / website | **In progress:** tutorial in [docs/tutorial](../tutorial/README.md), plus [getting started](../getting-started.md); no website yet (`docs/ts-developers.md` says it is "not a tutorial") | Tutorial (getting started, a CLI tool, a service, tests, contracts) and a static site. Hosting under the new org is an owner decision |
| Std reference | hand-written `docs/std*.md` and `apitable.or` | Generated from source (ADR-0048 section 8) |
| Honest limits | [known-limitations.md](../known-limitations.md), [tcb.md](../tcb.md) have known staleness | Gate R4: reconcile README, std.md, limits, TCB, install |
| Stability policy page | **Done:** [docs/stability.md](../stability.md) | Keep in step with 3.9 and the std freeze |

### 3.9 Stability policy

Published as [docs/stability.md](../stability.md). Note: `0.1.0-beta.1` is a pre-freeze beta; the syntax/std freeze (M4) is
not complete, so `1.0.0-beta.1` (D10) is still reserved for M4.

Proposed (D6, D10):
- Semantic versioning from 1.0.0: patch = fixes, minor = additive, major = breaking.
- No editions at 1.0 _(proposal)_: ADR-0016's rule (changes only by ADR, additive) plus semver is enough
  until a breaking change is actually wanted.
- Deprecation: `@Deprecated` with a replacement named in the message (W0440), kept for at least one minor
  release (ADR-0048 section 9 uses "one release").
- Experimental modules are allowed and listed in one place; they carry `@Experimental`-style marking in
  docs and API snapshot. Candidates: `std:meta`, parts of `std:task` beyond the Gate 1 API, `std:net` UDP
  if added.
- `orin.toml` format and CLI flags: stable for documented keys; unknown keys are errors (ADR-0047).
- Compiler diagnostics codes are stable identifiers; message text is not.
- Runtime ABI and MIR are not stable between releases.

## 4. Milestones

Directory sets show where each milestone edits, to minimise merge conflicts. "Hot" areas that most
language PRs touch: `compiler/check/expr.or`, `compiler/main.or`, `compiler/loader/embedded_*.or`
(regenerated by every std change via `tools/embed_prelude.py`).

| M | Name | Owner thread / ADR | Directories | Entry | Exit |
|---|---|---|---|---|---|
| M0 | Org move and tap | PR #150, #149 | `.github/`, `install.sh`, `dist/`, README, docs links, `editors/vscode` | owner executes the move | URLs updated, installer works from the new location, tap formula tested on macOS arm64 |
| M1 | Std API unification + language prerequisites | "Compiler und std-APIs aufräumen" (ADR-0048, ADR-0049); ADR-0040/0034 as new small threads | `library/`, `docs/std-*.md`, `compiler/loader/embedded_*`, `compiler/mcp/apitable.or`; ADR-0040/0034 in `compiler/check`, `compiler/hir` | layout done (yes) | ADR-0048 rows 1-8 merged; ADR-0040 and ADR-0034 implemented or explicitly dropped from the freeze; `orin doc --check` in CI |
| M2 | Runtime R3 | "Runtime in Orin schreiben" (ADR-0052) | `runtime/core`, new `core` modules, `compiler/` for R3a only | R3a/b merged (#141) | R3a-R3e merged; R3f merged or deferred by D8; benchmark gate holds |
| M2b | Annotations S3-S6 | "Annotations als Sprachfeature" (ADR-0046) | `compiler/loader`, `compiler/check/userannos.or`, `library/std/meta*`, `std:json` (S6) | S1-S3 merged | S4-S6 merged, `@Json` example only |
| M3a | Concurrency floor (Gate 1) | new thread, ADR-0017 amendment | `library/std/task*.or`, `library/std/net.or`, `runtime/platform` (L0), `tests/concurrency`, `tests/net`, checker rules for C4 | C0 can start now; C1/C3 need D7 | C0-C5 merged; acceptance campaign green; API reviewed against ADR-0048 |
| M3b | Scheduler (Gate 2) | same thread, scheduler ADR | `runtime/core` (task parts, after R3e), `runtime/platform`, `library/std/task*.or` | M3a done, R3e merged | S1-S4 merged with measurements, or deferred to 1.x with a note |
| M4 | Freeze and beta | owner | docs, release workflow, VS Code | M1, M2 (to R3e at least), M3a, language items in 3.1 | std I/O freeze taken; reference and stability page published; `1.0.0-beta.1` available through Homebrew and `install.sh`; agent-ergonomics run done |
| M5 | RC and 1.0 | owner | none new | beta feedback closed; R3-R5 gates closed on the exact SHA | dry-run on every supported platform; `1.0.0-rc.N`, then `1.0.0` as a non-pre-release |

Parallelism and conflicts:

| Pair | Conflict | Rule |
|---|---|---|
| M1 and M2 | M1 rows regenerate `compiler/loader/embedded_*`; R3b/R3c add Orin modules under `runtime/core` and change shells that std calls | Land M1 rows 1-3 first (docs backfill, collection vocabulary, errors), then R3c |
| M1 (task.or renames, ADR-0048 3.4 `Sender.send -> Result`, private fields, `taskcore` internal) and M3a | both edit `library/std/task.or` | Write M3a WPs against the ADR-0048 names; do not start M3a code before ADR-0048 rows 4-6 touch `task.or`, or do it in the same PR series |
| M2 R3a and M2b S4 and ADR-0049 rows | all edit `compiler/check`, `compiler/loader` | One at a time on `check/expr.or`; ADR-0049 says R3a coordinates with its steps |
| M2 R3e and M3a C2 | task runtime seam | C2's live-scope registry is written in Orin inside R3e, not as new C |
| M3a C4 and M2b | both add checker/verifier rules | Different error-code ranges; distinct files (`check/tasks.or`, `check/resources.or` vs `check/userannos.or`) |
| M0 and everything | URL churn in docs | Do M0 first or in a quiet window; no other doc-wide edits meanwhile |
| M3a C0, C-pure parts and M2 | none (pure Orin, ADR) | Start now |

Critical path _(inference)_: ADR-0040/0034 (language) then ADR-0048 row 8 then M4; and R3a-R3e then
M3b then M4. M3a Gate 1 can finish before R3e if C2 is held back, but trap-safe cleanup cannot be
advertised without it.

## 5. Decisions for the owner

Each item: question, options, recommendation. None of these is taken by this document.

**D1. Concurrency scope in 1.0 (changes ADR-0016 and ADR-0017 if C).**
Options: A (OS threads + cancellation/deadlines/select/concurrent sockets), B (A plus M:N scheduler, same
API), C (A plus `async`/`await`, requires revising ADR-0016's post-1.0 list and ADR-0017's evidence rule).
Recommendation: B as target with the two gates of 3.3.4; the API freezes at Gate 1, the scheduler may slip
to 1.x. Reason: delivers capacity and cancellation, keeps the language surface closed, avoids building
the scheduler twice (after R3e). Choose C only if the keywords themselves are a product requirement.

**D2. Does the freeze (ADR-0016) get revised?**
Items: (a) add ADR-0034 and ADR-0040 to the 1.0 core (both accepted; ADR-0016's text still lists generic methods
as post-1.0), (b) `std:task` surface of D1, (c) user annotations (already amended 2026-10-16), (d) the
"core complete" clause requiring the compiler rewrite. Recommendation: amend ADR-0016 once, listing exactly
what is in, with (a) and (b) in and (d) relaxed per D5.

**D3. TLS / HTTPS client / HTTP in 1.0?**
Options: (i) none, `std:net` TCP and the pure `std:http` layer only; (ii) HTTP/1.1 client and server over
`std:net` without TLS; (iii) TLS client with certificate validation. Recommendation: (ii) with the
concurrency floor as the demonstration (`examples/http_server.or` is concurrent since C5), and document TLS as
post-1.0 behind a reverse proxy. TLS needs either a verified or well-audited implementation and is a large
TCB addition; the readiness audit does not require it.

**D4. Supported platform list at 1.0.**
Options: (i) linux-x86_64 + macos-arm64 only (what alpha.2 shipped); (ii) add linux-aarch64 and macos-x86_64
(already built by the workflow, but with a smaller CI matrix); (iii) add native Windows (needs thread backend
C6, L0 changes, path/shell semantics, `wmain`; [windows.md](../windows.md) lists the work). Recommendation:
(ii) with a dry-run per platform (gate R5), and Windows via WSL2 documented as supported usage, native
Windows post-1.0. Intel macOS and Linux arm64 only count as supported once a smoke test runs on each.

**D5. Compiler rewrite as a 1.0 condition.**
ADR-0016 defines "core complete" to include the rewrite. Options: finish `compiler/vc/` and remaining
`check/` files before 1.0, or amend the definition so 1.0 requires only that the compiler is
self-hosted, bootstraps reproducibly and is behaviour-stable. Recommendation: amend; the rewrite is an
internal quality goal with no user-visible contract, and the contract-standard dogfooding continues
after 1.0.

**D6. Stability promise scope: may std modules be marked experimental?**
Options: everything in the std is stable at 1.0; or a named experimental list. Recommendation: a named
list, kept short (`std:meta`, any `std:task` addition not covered by Gate 1 review, `std:html`/`std:ox`
provider details if the owner wants room). Everything else follows ADR-0048 and is frozen.

**D7. L0 size budget (999 of 1,000 code lines).**
Timed waits, interruptible network waits, a Windows backend and a scheduler's context switch/readiness
backend all land in L0. Options: raise the budget by ADR (ADR-0030 section 1 sets 1,000), pay for new code by
removing existing L0 code, or add a second platform file per target that is not counted against the Linux/macOS
budget. Recommendation: a budget ADR with a stated ceiling (for example 1,400) and a CBMC/contract
requirement for every addition, because C1 and C3 cannot be built without it. Decide before M3a starts.

**D8. Must R3f (delete the C object model) be complete before 1.0?**
Options: required; or required only for R3a-R3e with R3f following in 1.x. Recommendation: do not gate 1.0
on R3f, but gate on R3d/R3e being merged so the concurrency work is not built twice. The C object model
being present during 1.0 is a TCB statement ([tcb.md](../tcb.md)), not a user-visible one; the release
notes must say which runtime a build contains. If R3 slips, 1.0 may ship with the C runtime and Gate 1
only.

**D9. T6 #98 (range facts) and T5 #91.**
T6 gives nbody -53% but adds ~870 lines to a 2,476-line verifier and is a memory-safety fact source (rule U1).
Options: merge, park, drop. Recommendation: park until after 1.0 (it grows the verifier TCB during the
freeze with a measured gain on one benchmark); the same for T5. Revisit with the R4 plan.

**D10. Version naming.**
Options: `1.0.0-beta.N` / `1.0.0-rc.N` (semver pre-release), or continue `0.x`. Current tags are
`v0.1.0-alpha.N`. Recommendation: go directly to `v1.0.0-beta.1` at M4, `-rc.N` at M5, with
the release workflow's `--prerelease` tied to the tag suffix.

**D11. What the beta commits to.** Option: beta already freezes syntax and std names (breaking changes need a
new beta with a changelog), or beta stays open for renames. Recommendation: beta freezes syntax and std
names; semantic fixes allowed. That is what makes it a useful Homebrew channel.

**D12. Documentation hosting and tutorial authorship.** The website location under the new org and who writes the
tutorial are owner decisions; the roadmap only assumes a static site generated from `docs/` and the
language reference.

## 6. Contradictions and stale statements found while writing this

Listed so the owner can decide which doc to fix; none of them is changed here.

- [async-concurrency.md](async-concurrency.md) and progress.md "Next milestones" item 2 say the public monotonic clock
  is not landed; `library/std/time.or` and [std-time-monotonic.md](../std-time-monotonic.md) are on main.
- ADR-0047 is headed "Status: proposed" although its phases 3-5 are merged; it also names the tap under the
  old account.
- ADR-0017's original text specifies an M:N scheduler in L1; Addendum A deferred it. ADR-0016 says concurrency
  is "implemented after the core freeze but before 1.0 final", while the same ADR lists async/await post-1.0.
  Both are consistent with D1 option A/B, not with C.
- ADR-0016 lists HTTP as post-1.0, while `std:http` (pure layer) and `std:net` are shipped and documented as
  done in progress.md; the freeze text and the shipped surface disagree about HTTP.
- ADR-0052 makes R3d wait for the ADR-0038 work in `runtime/core` (packed arrays, in-place reuse), but
  progress.md lists those as not built (open work item 3). Either they are dropped from the R3d gate or they
  block R3d.
- ADR-0017 Addendum A records L0 at 700 of 1,000 code lines; after the net primitives (ADR-0033) the current
  count is 999, which no document states.
- The readiness audit (2026-10-15) counts R3-R5 open; R1 and R2 are closed in the night-shift handoff but the
  audit text is not updated.
- ADR-0048 section 5 and 6 depend on ADR-0034 and ADR-0040, which are accepted but not implemented; the
  roadmap treats this as a dependency, not an oversight.

## 7. Explicitly post-1.0

- `async`/`await` keywords (unless D1 chooses C), `Shared<T>` with atomic RC, per-task regions as a
  user-visible concept, distributed/actor features.
- `i128`/`u128`, bit operators and shifts, generic interfaces, default methods, inheritance (never planned),
  value types.
- Package registry and version resolution beyond path/Git dependencies.
- TLS, HTTP/2, UDP (if D3 chooses (ii)), databases, other items of
  [agent-stdlib-priorities.md](../agent-stdlib-priorities.md) without a landed slice.
- Native Windows (unless D4 chooses (iii)), musl static builds, notarised macOS binaries, `.deb`/`.rpm`.
- WebAssembly target ([roadmap.md](../roadmap.md) item 8), JS backend.
- Incremental analysis engine, `orin fix`.
- R4 refinement proofs, translation validation (ADR-0032), `.orcert` attestations, lineage, Capabilities
  Stages C-D, zero-C L0 (ADR-0052 "Zero C").
- Compiler-internal parallel phases beyond ADR-0049 row 11 unless they land early.
- Performance items T5/T6, `Span`/`Token` flattening, regions for tree-shaped workloads.
