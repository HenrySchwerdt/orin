# ADR-0017: Concurrency design — isolated tasks, transfer by move or copy, no shared mutable memory

Status: accepted as design (2026-10-13); implementation after the 1.0 core freeze (ADR-0016). **Stage 0 implemented
(2026-10-14): see "Addendum A: stage 0 as built" at the end and docs/concurrency.md.**
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
revokes it. MIR v1.10 adds the verifier rules (`grantClone` opener, `grantMove` closer, `grantAdopt*` opener on a token): a handle
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
