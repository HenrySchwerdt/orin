# ADR-0017: Concurrency design — isolated tasks, transfer by move or copy, no shared mutable memory

Status: accepted as design (2026-10-13); implementation after the 1.0 core freeze (ADR-0016). **Stage 0 implemented
(2026-10-14): see "Addendum A: stage 0 as built" at the end and docs/concurrency.md. Gate 1 floor C0-C5 implemented; the server acceptance campaign (C5, 2026-10-17) passes: results in docs/roadmaps/async-concurrency.md "Server acceptance campaign".**
Resolves spec-12 OPEN #5 at the design level. Spec references: 06 (concurrency), 07 (race freedom).

## Model
- **Tasks are isolated.** Every heap object belongs to exactly one task. Reference counts stay
  **non-atomic** — single-task code pays nothing for concurrency, and the memory-safety proofs
  remain per-task.
- **Crossing a task boundary is a `send`:** the value is either **moved** (the runtime checks that
  the value graph is uniquely owned — all reachable counts are 1 — and transfers it without
  copying) or **deep-copied** otherwise. Semantically both are a value copy (spec 03), so the
  choice is unobservable except in performance; `ORIN_STATS` reports moves vs copies.
- **No shared mutable memory exists**, hence no data races by construction (spec 07 "race on
  unsynchronized shared mutable memory" is excluded structurally, not by a checker).
- **Resources** (ADR-0016) can be moved into a task but never shared or copied.

## API (no new syntax; no async/await colouring)
```ts
import { scope, channel } from "std:task";

const results = scope(s => {                 // structured: all tasks finish before scope returns
  const a = s.spawn(() => expensive(1));     // closure captures by value (ADR-0011)
  const b = s.spawn(() => expensive(2));
  return [a.join()?, b.join()?];             // join(): Result<T, TaskError> (trap in task -> Err)
});

const (tx, rx) = channel<Msg>();             // illustrative; final shape: a record { send, receive }
tx.send(msg);                                // send = move-or-copy transfer
match (rx.receive()) { Some(m) => ..., None => ... }   // None when all senders are gone
```
- `scope` guarantees no task outlives it (structured concurrency); a trapping task yields
  `Err(TaskError)` at `join`, siblings are cancelled at the scope boundary (cooperative).
- Blocking operations (I/O, `join`, `receive`) block only the calling task; the runtime uses an
  M:N scheduler in L1 (Orin) over L0 thread/futex primitives (spec 19).
- `parallelMap(xs, f)` (spec 08) is a library function on top of `scope`.

## Consequences for verification
- The Lean memory model stays per-task; a separate small model proves that `send` (move of a
  uniquely owned graph, or deep copy) preserves per-task well-formedness and never creates
  cross-task aliases.
- MIR gains no concurrency instructions; `send`/`spawn` are runtime calls whose ownership effect
  is "consume the argument" (verifier rule like an owned parameter).

## Post-1.0 options (not decided)

Implementation sequencing and evidence gates are proposed in the
[async/concurrency roadmap](../roadmaps/async-concurrency.md); that proposal does
not amend this ADR or approve new syntax.

`Shared<T>` for deeply immutable values with atomic RC (opt-in, explicit type) for large
read-only data; async/await syntax if blocking tasks prove insufficient.

## Addendum A: stage 0 as built (2026-10-14)

Requested by the project owner with one condition: "only if it can then simply be moved to Orin" (R3). Stage 0 keeps the model
above (isolated tasks, move-or-copy, non-atomic RC, structured scopes, bounded channels) and changes three details.
Full description, safety argument, tests and measurements: [docs/concurrency.md](../concurrency.md).

**API as built** (`std:task`, Orin, `stdlib/task.or`): `scope` / `scopeDo`, `spawn(s, f)` / `spawnDo`, `TaskHandle<T>.join(): T`,
`channel<T>(capacity)` giving `{ tx: Sender<T>, rx: Receiver<T> }` with `send(v): bool`, `recv(): Option<T>`, `close()`,
`parallelMap`, the grant delegation family `scopeFs` / `spawnFs` (and process, stdio, clock), `movedCount` / `copiedCount`.

**Deviations from the sketch, with reasons**
1. `spawn` is a function, not a method (`s.spawn(f)`): generic methods do not exist (E0460).
2. `join(): T`, not `Result<T, TaskError>`: a panic in a task is a **trap of the joining task** (message `task panicked:
   <message>`), at `join` or, for a task nobody joined, when the scope ends. The language has no exceptions and a trap is
   not a value (ADR-0024); nothing is lost silently. Sibling cancellation at the scope boundary is not implemented.
3. Channel ends are plain copyable values (resource handles cannot be returned, E0450), so "all senders gone" cannot be
   observed (no destructors): the sender or the receiver closes explicitly; closing both releases the channel. Bounded
   only; `recv` returns `None` after close **and** drain; `send` returns `false` on a closed channel.
4. A **1:1 thread per task** instead of the M:N scheduler: blocking operations block a thread, any blocking pattern works,
   thousands of tasks are fine. The bookkeeping (task table, channel buffers) is Orin and carries over to a scheduler.

**Layering (the porting rule).** Orin: scheduler bookkeeping, channels, join results, scopes, `parallelMap`, grant delegation
(`stdlib/task.or` and the pure `stdlib/taskcore.or`, 508 code lines). L0, C forever: thread create / join / exit / id and **monitors** (a mutex, two condition
queues and an array of integer words that only the lock holder can read or write; handle-checked) in `platform/` (+243 code
lines, L0 total 700 of 1,000). Runtime C, temporary: ONE interface that needs the object model (`orin_rt_transfer_*`,
`orin_rt_task_*`, `orin_rt_heap_exit`, the per-task heap state), 342 code lines, deleted by R3. The monitors are the only state tasks
share, and they hold integers (transfer tokens), never values; this is what keeps channels and scopes in Orin even though
Orin values cannot be shared.

**Porting table: C function (runtime, temporary) to the planned R3 Orin function (module `core/task`, `core = true`)**

| C function | Planned R3 Orin function |
|---|---|
| `orin_rt_transfer_put(box)` | `core.transfer.put(box): usize` (move if `core.rc.isUnique`, else `core.copy.deep`) |
| `orin_rt_transfer_take(tok)`, `orin_rt_transfer_drop(tok)` | `core.transfer.take`, `core.transfer.drop` |
| `graph_unique`, `copy_node` / `deep_copy` (static) | `core.rc.isUnique(root)`, `core.copy.deep(root)` |
| `tr_publish`, `tr_claim` (slot table under the runtime lock) | `core.transfer` slot table (Orin array, L0 `runtime_lock`) |
| `orin_rt_transfer_count(which)` | `core.stats.transfer(which)` |
| `orin_rt_task_spawn(tok)` | `core.task.spawn(tok)` (L0 `thread_create` with the Orin entry `core.task.main`) |
| `orin_rt_task_join(h)`, `orin_rt_task_message()` | `core.task.join`, `core.task.message` |
| `task_active` / `task_trap` hook in `orin_trap` | `core.trap.endTask` |
| `orin_rt_heap_exit()` | `core.heap.retire()` |
| thread-local `g_live`, `orin_stats`, free lists, work stack, grant and file tables | fields of `core.heap.TaskHeap` (R3 allocator) and of `core.cap` |
| `orin_rt_trap_str(msg)` | `core.trap.fromString` |
| `orin_mon_*` forwarders | `core.sync.*` (one line each) |
| `orin_cap_clone` / `orin_cap_move` / `orin_cap_adopt_*` | part of `core.cap` (replaces the C grant table) |

L0 (`orin_platform_thread_*`, `orin_platform_monitor_*`, `orin_platform_runtime_lock`) does not move.

**Grants (ADR-0027 Q10).** Resolved in the smallest sound form: no owned-parameter syntax or mode for user code. `spawnFs(s, g,
fsg => ..)` derives a fresh grant of the same authority, moves it into the task through a one-shot token and the task owns and
revokes it. MIR v2.1 adds the verifier rules (`grantClone` opener, `grantMove` closer, `grantAdopt*` opener on a token): a handle
is moved exactly once on every path. The original grant is not moved (it is borrowed from its scope function); moving a `File` is
not provided.

**Checker rules** (new, free range): E0481 task body captures a `Scope`; E0482 `channel(0)`; E0483 task body captures a resource
handle. The existing E0450-E0452 already make everything non-copyable unrepresentable as a captured or sent value, so every
other value is sendable.

**MIR / OSIG.** No concurrency instruction (as decided): the primitives are one builtin `BTask(k)`. OSIG: spawn is a `CONTROL`
`PERFORMS_IO` event (`~io:Task.Spawn`, `Task.SpawnFs` ... name a delegated family), `Channel.Send` is `OUTPUT`, `Channel.Receive`
is `INPUT`, `Task.Join` is `CONTROL`.

**Assurance (honest).** The C parts are `TESTED_ONLY`: ThreadSanitizer, AddressSanitizer / UBSan and stress tests, no proof;
L0 threads and monitors stay `TESTED_ONLY` after R3 (a proof needs a concurrency-aware C verifier and an OS model), the transfer
and per-task heap move to Orin in R3 and get the refinement proof in R4. Not claimed: freedom from deadlock, fairness,
cancellation, that a trapped task frees its heap.

**Bootstrap.** The runtime ABI only gained functions and thread-local qualifiers; generated code of the previous seed links
against the new runtime unchanged, so no seed bridge was needed (the compiler source uses no feature newer than the seed).

## Addendum B: structured cancellation and outcomes (Gate 1, C0) (2026-10-16)

Status: accepted per [roadmap](../roadmaps/orin-1.0.md) default D1 = option B (owner default 2026-10-16; Henry can still
overturn it). This addendum fixes the semantics; C0 implements only the pure state machines (`std:taskcore`: `CancelState`,
`CancelScope`, `TaskCell` and the functions around them); blocking behaviour lands in C1-C3 (**C1 implemented**: timed monitor wait in L0, `recvUntil`/`recvTimeout`, `sendUntil`/`sendTimeout`,
`joinUntil`/`joinTimeout`, `select`/`selectUntil`/`selectTimeout`, `sleep`/`sleepUntil`; see docs/concurrency.md "Gate 1, C1"; **C3 implemented**: scope tokens, interruptible network waits, Addendum D). Related: ADR-0054 (the L0 budget that
C1/C3 need), ADR-0048 (naming), [async-concurrency roadmap](../roadmaps/async-concurrency.md).

**No new syntax.** No `async`/`await`, no new keywords or operators, no new checker rules. Cancellation, deadlines, `select` and
`sleep` are library functions of `std:task`; the API stays blocking on OS threads and a later M:N scheduler sits behind it unchanged.

**1. Cancellation tree.** Every scope owns a cancellation token; a task's token is a child of its scope's token, a nested scope's
token a child of the enclosing task's token. Cancellation flows only downward: cancelling a token cancels all descendants, never
an ancestor. A token holds one *cause*, set once and never replaced (first cause wins): `Cancelled` (explicit `cancel()`, an
ancestor, or a trapped sibling) or `Deadline`. When a task traps, its scope is cancelled with cause `Cancelled`: the siblings stop
at their next checkpoint, the scope waits for all of them (structured: no task outlives its scope) and then traps, as stage 0 already does
for a panic. This supersedes the stage-0 note "sibling cancellation is not implemented".

**2. Task outcomes.** Every task ends with exactly one outcome, ordered by severity:
`Completed < Closed < Cancelled < Deadline < Error`.

| Outcome | Meaning |
|---|---|
| `Completed` | the body returned |
| `Closed` | a blocking call stopped because the channel end it waited on was closed and drained |
| `Cancelled` | it stopped at a checkpoint because its token's cause is `Cancelled` |
| `Deadline` | it stopped at a checkpoint because its token's cause is `Deadline` |
| `Error` | it trapped |

A scope's outcome over its children is the most severe one (a join-semilattice: commutative, associative, idempotent).
At a checkpoint the precedence is: the operation can complete (`Completed`), else closed (`Closed`), else the cause, else keep waiting;
so a value already in a channel is never dropped by a cancellation that arrives at the same time.

**3. Exactly-once result and token ownership.** A task's result slot is settled once (`settle`) and taken once (`take`); a second
`join` of the same handle still traps (ADR-0017 Addendum A). The transfer token of the result (a move-or-copy token, ADR-0017) is
owned by the slot until `take`, then by the joiner; a result that is never taken is released by the scope at its exit. A cancelled task
that already produced a value still reports `Completed` with that value; cancellation never turns a produced result into `Cancelled`.

**4. Cooperative checkpoints.** Cancellation is observed, never injected. A task observes its token at: `recv`, `send`,
`join`, `sleep`, `select`, the net waits (`accept`, `connect`, `read`, `write`; C3), `yield`, and an explicit `checkIn()`/`isCancelled()`
call that long computations may place themselves. Pure computation without those calls is not interrupted. After a checkpoint
reports cancellation, the call returns its cancelled variant (`None`/`Err(Cancelled)`, per the API chosen in C1 under ADR-0048) and
the task is expected to return; cleanup code runs normally (resources are released by their scopes, ADR-0016).

**5. Absolute monotonic deadlines.** A deadline is an absolute `MonotonicInstant` (`std:time`, millisecond resolution, process-local),
never a duration, so retries and nested waits cannot stretch it. A token's deadline can only move earlier (`min` with the parent's;
none is the loosest), a timed wait computes `waitBudget(deadline, now)` once per wakeup, and an expired deadline (`now >= at`) sets the
cause `Deadline` unless a cause is already set (a parent cancelled first wins). Additions saturate at the largest i64 instead of
overflowing. The wait itself is the C1 timed monitor wait on `CLOCK_MONOTONIC`.

**6. `select` and `sleep` (sketch, implemented in C1).**

```ts
import { scope, spawn, channel, select, sleep, withDeadline } from "std:task";

scope(s => {
  withDeadline(s, deadlineAfter(now, seconds(5)));   // narrows the scope token's deadline
  match (select([rx1.arm(), rx2.arm(), timeout(d)])) {  // first ready arm; ties resolve in list order
    Recv(0, v) => ..., Recv(1, v) => ..., TimedOut => ..., Cancelled => ..., Closed(i) => ...,
  }
  sleep(milliseconds(10));                           // a checkpoint that waits; wakes early on cancellation
});
```

Shapes (names subject to the ADR-0048 review in C1): `recvTimeout(rx, d)`, `joinTimeout(h, d)`, `sleep(d)`,
`select(arms)`, `cancel(scope)`, `isCancelled()`. All are ordinary functions over `Result`/`Option`/variants; none needs syntax.
A `select` of several arms is one monitor wait on a shared wake word, not a poll loop.

**7. What is not changed.** Isolation, move-or-copy transfer, non-atomic RC, bounded channels and 1:1 threads in stage 0 stay.
A trap inside a task still never unwinds the process; it becomes the `Error` outcome of that task.

## Addendum C: network ownership for concurrent servers (C4) (2026-10-17)

Status: accepted per [roadmap](../roadmaps/orin-1.0.md) default D1 (owner default 2026-10-16). Implements work package C4 and the
concurrent server example of C5. Related: ADR-0033 (net primitives), ADR-0048 (naming), ADR-0025.

**Problem.** `Listener` and `Stream` are resource handles in the owning thread's grant table. They cannot be captured, returned, stored
or sent (E0450-E0452, E0483), task delegation covered fs / process / stdio / clock but not net, and the bulk buffer between byte arrays
and L0 (`g_netbuf`) was one global. A server could serve one connection at a time.

**Decision: delegate and move, no new value kind.** A socket stays a handle. It crosses a task boundary through the machinery that
already moves grants (`grantClone` / `grantMove` / `grantAdopt*`, a one-shot token), now with two more kinds:

1. **NetGrant delegation.** `spawnNet(scope, net, body)` clones the grant (same listen address, connect pattern and ports, same
   `ORIN_DENY` policy), moves the clone into the task and hands it to `body(g)`; the task revokes it when it ends, also on a trap.
   `scopeNet` / `scopeNetDo` carry the grant into a scope. Authority is never widened: the clone is a copy of the parent's record.
2. **Stream move.** `grantMove(stream)` ends the handle in the parent (its slot leaves the parent's grant table; the MIR verifier treats
   it as a closer, so no use, close or second move afterwards, and it must happen on every path or the stream is "not closed") and
   returns a token; `grantAdoptStream(token)` in the child defines a fresh `Stream` handle in the child's table, which the child must
   close exactly once. The socket descriptor travels with the token. A token can be adopted once; a second adoption traps ("invalid
   grant token"), a forged one too.
3. **std:net on top (ADR-0048 naming).** `acceptDetached(ln, timeoutMs): Result<Accepted, NetError>` accepts and moves; `Accepted` is
   a plain value `{ token, peer }` that can travel in a `channel<Accepted>`; `serveAccepted(a, body)` / `serveAcceptedDo` adopt, run and
   close; `dropAccepted(a)` closes unserved; `spawnAccepted(scope, ln, timeoutMs, body)` / `spawnAcceptedDo` accept and start a task.
   A bounded pool of N workers receiving `Accepted` from a bounded channel gives a server with at most N connections in service.
4. **Per-task net buffer.** `g_netbuf` is replaced by a thread-local buffer allocated on first use and freed in `orin_rt_heap_exit`;
   concurrent tasks never share it.

**What stays forbidden.** A task body cannot capture a `Listener`, a `Stream` or any grant (E0483, text extended). A `Listener`
never leaves the task that bound it (the accepting task accepts and moves the `Stream`). A `Stream` is moved, never duplicated.

**Checker and verifier rules.**

| Code | Rule |
|---|---|
| E0487 | (library code, the primitives of `std:fsraw`) `grantMove` of a `Listener`, or `grantClone` of a `Stream`, is rejected; `grantClone` / `grantMove` also accept a `NetGrant`, `grantMove` also a `Stream` |
| E0471 | now lists net among the families a grant primitive accepts (the Host is still rejected) |
| E0483 | text extended to Listener and Stream captures |
| MIR verifier | no new code: `grantMove` of a Stream is a closer (double move, use after move, move on one branch only, moving a Stream parameter are the existing "not open" / "dead" / "closed" / "parameter" errors), `grantAdoptStream` / `grantAdoptNet` are openers of a token (a handle argument is rejected). `compiler/tests/verify_main.or` pins the cases |

E0475 and E0476 belong to the parallel ADR-0034 work and are not used; E0487 is the next free code after E0486.

**Runtime.** `orin_cap_clone` accepts `GK_NET` (copying the scope record), `orin_cap_move` accepts a stream and traps for the Host or
a Listener, `orin_cap_adopt_net` / `orin_cap_adopt_stream` are new, the net buffer is thread-local. All are listed in the porting
table of [concurrency.md](../concurrency.md); `runtime/platform` is unchanged.

**Example and tests.** `examples/http_server.or` (the concurrent server; bounded workers, request-size limits, per-connection deadlines),
`tools/test_net.sh` section 6 (Python clients: held connections, 408 at the deadline, queueing behind a full pool, many clients; an
Orin client with 64 and 256 `spawnNet` tasks; the same server under ThreadSanitizer when available), `tests/next/run/net_task_move.or`,
error tests for E0483 and E0450, library-level E0487 tests in `tests/net/libcheck`.

## Addendum D: interruptible network waits, operation-wide deadlines and wake sources (C3) (2026-10-17)

Status: accepted per [roadmap](../roadmaps/orin-1.0.md) default D1 (owner default 2026-10-16). Implements work package C3 on top of C4
(Addendum C, sockets live in tasks) and C1 (absolute deadlines). Related: ADR-0054 (the L0 budget it spends), ADR-0048 (naming),
Addendum B sections 4 and 5 (cooperative checkpoints, absolute deadlines).

**Problem.** A task blocked in `accept`, `connect`, `recv` or `send` could only be ended by the timeout of that one call (at most one hour).
Nothing could stop it from outside, so a server could neither shut down promptly nor cancel the tasks of a scope whose sibling failed.
A deadline applied to one wait, not to an exchange of many small reads and writes, and `connect` gave every address of a name the full
timeout. Names were resolved by a blocking `getaddrinfo`.

**Decision.**

1. **A wake source in the readiness wait of L0** (`runtime/platform`). A *wake source* is a cancellation token: a record with a flag and a
   descriptor (an `eventfd` on Linux, a pipe elsewhere) that is made the first time a wait polls it. A thread *binds* one source
   (`orin_platform_wake_bind`); the four waits (`accept`, `connect`, `recv`, `send`) poll the socket **and** the descriptors of the bound
   source and its ancestors in one `poll(2)`. Setting the flag (`orin_platform_wake_signal`) writes the descriptor, so a blocked wait returns at
   once with the new code `ORIN_PLATFORM_NET_CANCELLED` (1004); the flag and the descriptor are updated under one lock, so a signal cannot fall
   between the check and the poll. A set source is permanent; it is checked **before** the socket is touched, so a cancelled task never starts
   new network work and a pending connection or the bytes in the kernel buffer stay where they are. Cancellation wins over a socket that is ready
   at the same instant (nothing is lost: the data is still in the kernel). The platform signatures did not change: the binding is thread-local,
   so the runtime and the frozen snapshot (`bootstrap/seed/runtime`) are untouched.
2. **Tokens form a tree.** A source opened while another is bound is its child (`orin_platform_wake_open` also binds it);
   `orin_platform_wake_close` unbinds it and rebinds the parent. A wait observes the whole chain, so cancelling an outer scope reaches a task of
   an inner scope, and cancelling an inner scope reaches only its own tasks (Addendum B section 1: cancellation flows downward). The depth is
   limited to 33 levels (`ORIN_PLATFORM_WAKE_DEPTH` = 32); a scope opened deeper has no token of its own and its tasks inherit the nearest
   ancestor's (`Scope.token()` / `Scope.cancel()` of such a scope trap with a message).
3. **Generation-tagged handles.** A token is named by `generation << 32 | (index + 1)`. Closing a source bumps the generation of its slot, so
   a handle kept after its scope ended is *stale*: `signal` returns 0 and changes nothing, `check` returns 2, `close` returns `EINVAL`, and a
   later scope that reuses the slot cannot be cancelled or observed through it (over 200 rounds in `tests/concurrency/cancel_tokens.or`,
   exhaustively over short operation sequences in `harness_wake_state_machine`). The other handles of the network path already were
   generation-tagged (grant table: `GRANT_TAG | task | generation | slot`; a stale, forged or wrong-kind socket handle traps), and
   `runtime_test.c` now also pins the case where the slot of a closed stream is reused by the next one.
4. **`std:task` owns the tokens.** `scope` (`begin` / `finish`) opens a token and stores it in header word 4 of the task table; `finish` closes it
   after every task has ended. `spawn` binds the scope's token in the new task (a thread starts unbound). `Scope.token(): CancelToken`
   is a copyable value a task may capture (a task cannot capture the `Scope`, E0481); `CancelToken.cancel(): bool` is true when this call set it;
   `Scope.cancel()`, `Scope.isCancelled()`, `CancelToken.isCancelled()` and the free `isCancelled()` (the calling task's own chain) complete the
   API. These are ordinary functions: no syntax, no checker rule, no MIR instruction.
5. **`std:net` surface (ADR-0048).** `NetErrorKind` gains `Cancelled` (bare word describing the cause, rule 3.1.4; L0 code 1004; `Timeout` stays
   the kind of a deadline). `recv` and the readers report it as `Err(e)` (ADR-0048: `recv` and `readExact` return `Result`, the end of the stream is `Err(Closed)`). Every operation has an absolute form on a `Deadline`
   of std:time, the naming of C1: `recvUntil`, `sendUntil`, `sendAllUntil`, `StreamReader.readExactUntil`, `StreamReader.readDelimitedUntil`,
   `withAcceptedUntil`, `acceptDetachedUntil`, `withConnectionUntil`, `useConnectionUntil`; the relative forms are unchanged and implemented on them.
   The loops of the reading and writing forms check the clock before every system call, so one deadline spans any number of small reads and
   writes (a peer that sends a byte every `timeout - 1` ms cannot stretch it) and is not cut at the one-hour limit of a single wait. In L0, the
   timeout of `connect` now bounds *all addresses of the name together*. `withListenerNet` and `withConnectionBeside` are the value-returning
   twins of `useListenerNet` / `useConnectionBeside` (a closure cannot modify what it captured, so a body that both listens and connects needs them).
6. **What is not interrupted, stated.** (a) *Name resolution.* `getaddrinfo` is blocking and the C library offers no way to abandon it, so the lookup
   of `resolve` and the lookup `connect` makes for a name is bounded by no timeout and no deadline and is not interrupted by a cancellation; a task
   already cancelled does not start one, and a task cancelled during it fails at its next network call. A resolver pool (a helper thread per
   lookup, abandoned when the waiter is cancelled) was **not** built: it needs a second thread table in L0 and leaves an unbounded number of
   lookups running after their waiter gave up, which is a resource leak with a cost larger than the 100 lines the rest of C3 needs. The documented
   workaround is to connect to address literals, or to resolve in a task of its own that the caller waits for with `joinUntil`. (b) *Waits on
   channels* (`recv`, `send`, `join`, `select`, `sleep`) do not observe the token yet; they end by their channel or deadline. Making them
   checkpoints (and a trapped task cancelling its scope) is C2. (c) *Pure computation* is not interrupted; `isCancelled()` is the cooperative check.
7. **L0 budget (ADR-0054).** 1,036 to 1,163 code lines (+127 of the 364 left), each function with an ACSL contract in `orin_platform.h`, a CBMC state
   machine (`harness_wake_state_machine`, `harness_wake_generation` in `cbmc_l0_harness.c`) for the table logic, executable contract tests with real
   sockets and threads in `platform_test.c` (plain, ASan + UBSan, ThreadSanitizer). The descriptor and `poll` parts are tested, not model checked.
8. **No new runtime or snapshot symbol.** The wake functions are platform functions that generated code calls directly (task operations 31-36 of
   `compiler/hir/taskops.or`; the C backend declares them in its preamble, the LLVM backend in `declare`s). `runtime/core` only gained a test; the
   frozen snapshot needs nothing, and `tools/check_seed_runtime.sh` is unaffected.

**Tests.** `runtime/platform/tests/platform_test.c` (handles, stale handles, depth, thread binding, cancel-first on every wait, wake from another
thread within a bound, no descriptor leak), `runtime/core/tests/runtime_test.c` (stale handle after slot reuse, code 1004 through `orin_net_accept`),
`tests/std/net_test.or` (absolute deadlines, a cancelled scope), `tests/concurrency/cancel_tokens.or` and `cancel_storm.or` (stale tokens, nesting,
depth beyond 32; 288 + 24 + 16 blocked tasks cancelled by concurrent cancellers, plain, ThreadSanitizer, ASan + UBSan), `tests/net/interrupt.or`
through `tools/test_net.sh` (accept, recv, send and a hanging connect woken within a bound; a cancelled scope fails at once; nested scopes; one
deadline over many small reads, a non-reading peer and a hanging connect; plain and ThreadSanitizer).
