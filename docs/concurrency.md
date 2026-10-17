# Concurrency, stage 0: isolated tasks (ADR-0017)

Status: implemented (2026-10-14) as **stage 0** of ADR-0017, built so that it moves to Orin with R3 without redesign
(owner's condition: "only if it can then simply be moved to Orin"). Everything that can be Orin today is Orin; the C that
remains is split into L0 primitives that stay C forever and one small temporary interface that R3 replaces. Design basis:
[ADR-0017](decisions/0017-concurrency-design.md) and its addendum "Stage 0 as built"; related: ADR-0027 (grants are
resources; Q10), ADR-0030 (L0 is the only C), spec 19, ADR-0038 (per-task regions later).

Module: `std:task` (`library/std/task.or`, unstable; its pure bookkeeping classes are in `std:taskcore`). Stage 0 has no `async` / `await`.

The [proposed async/concurrency roadmap](roadmaps/async-concurrency.md) records the
current baseline, cleanup/cancellation/deadline prerequisites and scheduler/syntax
decision gates. It does not change stage-0 semantics or accepted ADR policy.

## The API

```ts
import { scope, spawn, channel } from "std:task";

const total = scope(s => {                    // structured: every task started inside has ended when scope returns
  const a = spawn(s, () => expensive(1));     // the closure captures by value; its captures MOVE (unique) or are COPIED
  const b = spawn(s, () => expensive(2));
  return a.join() + b.join();                 // join: the task's result; a panic in the task traps the joiner
});

const ch = channel<Msg>(16);                  // bounded, capacity >= 1
ch.tx.send(msg);                              // blocks while full; false if the channel is closed (nothing is lost silently)
match (ch.rx.recv()) { Some(m) => ..., None => ... }   // blocks while empty; None when closed and drained
ch.tx.close();  ch.rx.close();                // end of stream / cancellation; close both ends to release the channel
```

| Function | Meaning |
|---|---|
| `scope<R>(body: (s: Scope) => R): R`, `scopeDo(body)` | runs `body(s)`, then joins every task spawned in the scope, then returns. `scopeDo` is the `void` flavour (a generic result cannot be `void`; std:host has the same pairs) |
| `spawn<T>(s, f: () => T): TaskHandle<T>`, `spawnDo(s, f: () => void): TaskHandle<bool>` | starts `f` as a task (an operating-system thread with its own heap). `ADR-0017` sketched `s.spawn(..)`; generic methods do not exist (E0460, ADR-0026), so it is a function taking the scope |
| `TaskHandle<T>.join(): T` | waits for the task; its result. Panic: traps with `task panicked: <message>`. A second `join`, or a join after the scope ended, traps |
| `channel<T>(capacity): Channel<T>` with `Channel<T> = { tx: Sender<T>, rx: Receiver<T> }` | a bounded FIFO. Both ends are copyable values and can be used by any number of tasks (several senders, several receivers) |
| `Sender<T>.send(v): bool`, `.close()` | `send` blocks while the channel is full. `true`: handed over (moved if unique, copied otherwise). `false`: the channel is closed by either end and `v` is dropped |
| `Receiver<T>.recv(): Option<T>`, `.close()` | `recv` blocks while empty. `None` once closed by the sender **and** drained, or cancelled by `rx.close()`. `rx.close()` drops what is buffered and makes senders get `false` |
| `scopeFs(fs, (s, g) => ..)`, `scopeProcess`, `scopeStdio`, `scopeClock` (+ `...Do`), `spawnFs(s, g, fsg => ..)`, `spawnProcess`, `spawnStdio`, `spawnClock` | delegating a grant to a task, see "Grants" |
| `Receiver<T>.recvUntil(deadline): Result<T, TaskError>`, `.recvTimeout(clock, timeout)` | C1: `recv` with an absolute monotonic `Deadline` (std:time) or a `Duration` from now. `Err(Timeout)`, or `Err(Closed)` once closed and drained; a value already there is delivered even at an expired deadline |
| `Sender<T>.sendUntil(v, deadline): Result<void, TaskError>`, `.sendTimeout(clock, v, timeout)` | C1: `send` that gives up with `Err(Timeout)` while the channel stays full, `Err(Closed)` when closed (`v` is dropped on an error) |
| `TaskHandle<T>.joinUntil(deadline): Result<T, TaskError>`, `.joinTimeout(clock, timeout)` | C1: `Err(Timeout)` if the task has not ended; the handle stays valid. Otherwise exactly `join()` (a panicked task still traps the joiner) |
| `select<T>(rxs): Result<Selected<T>, TaskError>`, `selectUntil(rxs, deadline)`, `selectTimeout(clock, rxs, timeout)` | C1: the first ready receiver in array order wins; `Selected<T> = { index: usize; value: T }`. Closed and drained receivers are skipped; `Err(Closed)` when all are. One value type for all receivers (use a variant for different kinds). Free functions: generic methods do not exist (E0460) |
| `sleep(clock, timeout): Result<void, TaskError>`, `sleepUntil(deadline): void` | C1: blocks at least that long on the monotonic clock; never early |
| `TaskError = { kind: TaskErrorKind }`, `TaskErrorKind = Timeout \| Closed \| ClockUnavailable \| InvalidDuration`, `taskErrorMessage(e)` | ADR-0048 section 3.1; `Timeout` is outcome `Deadline` and `Closed` is outcome `Closed` of ADR-0017 Addendum B (`Cancelled` joins in C2) |
| `parallelMap(xs, f, parts): B[]` | `xs.map(f)` computed by `parts` tasks over contiguous chunks, results in order |
| `forkJoin(chunks, workers, body): R[]`, `forkJoinUntil(chunks, workers, body, hit): R[]`, `parallelism(): usize` | the work-stealing fork/join pool behind `parallel()` on arrays (ADR-0039), see "Fork/join pool and lending" |
| `movedCount()`, `copiedCount()` | how many values this task sent by move / by deep copy so far (`ORIN_STATS=1` prints the process totals too) |

## Semantics

**Isolated tasks.** Every heap object belongs to exactly one task. Reference counts stay non-atomic. Nothing mutable is
shared: values are immutable, closures capture snapshots (ADR-0011), and crossing a task boundary is a transfer.

**Transfer = move or deep copy.** A value that crosses a boundary (a captured variable of a task body, a task result, a
channel message) goes through `orin_rt_transfer_put`. If every counted reference in its graph has count 1 the graph is
**moved** (no copy: the receiver gets the very objects). Otherwise it is **deep-copied** (a fresh graph nobody else can reach).
Both are a value copy to the program, so the choice is unobservable except in performance and in the counters. A named local
that is still alive counts as an owner, so sending it copies; sending a fresh temporary or a function result moves it. That a
temporary is passed by move rests on the optimiser's owned-parameter inference (ADR-0010): without it the value is copied.
Last-use moves of named locals are the performance model's job (ADR-0038).

**What is sendable.** Everything that is a value: scalars, strings, arrays, records, unions, `Option`, `Result`, `Map`, class
instances, interface values and closures (their captures are values, ADR-0011), `Sender` / `Receiver` / `TaskHandle` (plain handles of
monitors, copyable by design). Not sendable, and not even representable as a captured or sent value: resource handles (`File`, grants,
`Host`). So the checker needs no "sendable" predicate of its own: E0450 / E0451 / E0452 already forbid a handle as a type argument, a
variable, a field, a result or a capture, and E0483 gives the task-specific message at `spawn`.

**Resources.** A resource handle (`File`, grant, `Host`) is not a value: it cannot be captured by a task body (E0483), stored,
returned or sent (E0450-E0452). Grants are delegated (`spawnFs` ... `spawnNet`), see below; an accepted `Stream` is moved into a task (`acceptDetached` / `spawnAccepted` of `std:net`, ADR-0017 Addendum C), a `Listener` stays in the task that bound it.

**Panics.** A trap on a task thread ends that task only (the runtime records the message, closes the task's grants and
files, releases monitors it held, folds its counters, and exits the thread). `join` turns it into a trap of the joiner with
the message `task panicked: <message>` (a panic that crossed two tasks reads `task panicked: task panicked: ...`). A panic
in a task nobody joined is reported when its scope ends, after all other tasks have ended: **no panic is lost**. Documented
limits: a task that traps does not unwind, so what it allocated is leaked (exit status and message are unaffected; the
leak shows in `live_objs_at_exit`), and a panic in the **body** of a scope (not in a task) is not unwound either: tasks
still running keep running until the process ends. `process.exit` in a task ends the whole process; it flushes stdout and the files open in the exiting task, not those open in other tasks (the exit hook can only see its own thread's file table). With per-task regions (ADR-0038) the leak of a trapped task disappears: the whole region is freed when the task ends.

**Scopes.** `scope` joins what is left when its body returns. The scope's task table lives in a monitor; joining an entry
claims it exactly once, so a task is never joined twice. `spawn` on a scope that has ended traps. A task body that captures
the `Scope` is E0481; a `Scope` that reaches a task some other way is caught by that run-time check.

**Channels.** Bounded only (capacity >= 1; `channel(0)` is E0482, a non-constant zero traps). One mutex per channel with two
condition queues (senders wait for room, receivers for a value; a send wakes one receiver, a receive one sender, a close
everybody). FIFO per channel. Order between different channels is not defined. The buffer holds transfer tokens, never values.
Both ends closed releases the channel: a later use traps (stale monitor handle), never touches freed memory.

**Grants (ADR-0027 Q10: the owned-parameter mode for handles, smallest sound form).** A task cannot capture a grant, and a
callback's grant parameter is *borrowed* from the function that derived it, so it cannot be moved out of that scope. The task
gets its own grant instead: `spawnFs(s, g, fsg => ...)` DERIVES a grant of the same family with exactly the authority of
`g` (same scope, same read-only flag, same spawn right; never more), MOVES it into the task, and the task wrapper adopts it,
passes it to the body as a parameter and revokes it when the body returns (the runtime also revokes it if the task
panics). The spawner's own grant is untouched. Because closures cannot capture grants, `scopeFs(fs, (s, g) => ..)` hands the
grant back to its body as a second parameter, the same shape as `withFileFs` of std:fs. Soundness: the derived handle is a
local of the spawning function that must be *moved exactly once on every path* (MIR verifier: `grantMove` is a closer), the adopted
handle a local of the task wrapper that must be revoked exactly once (`grantAdopt*` is an opener whose authority is a
one-shot token). Handles are per task: a grant handle used on another thread than the one that owns it traps. Not
provided: moving the *original* grant (it is borrowed from its scope function; that would need owned-handle parameters in
user code, which was not needed to move authority soundly), moving a `File` (it has a position; open it in the task from a
delegated grant).

## Where everything lives, and the porting table

| Layer | Contents | Language | Lines (code, no comments or blank lines) |
|---|---|---|---|
| `std:task` (L2) | scope table and task bookkeeping (`Ledger`, `drain`), join results, panic propagation, channel buffers (`Ring`), `Sender` / `Receiver`, grant delegation, `parallelMap` | **Orin**, `library/std/task.or`, and the pure state machines `Ring` and `Ledger` in `library/std/taskcore.or` | 508 (`task.or` 416 + `taskcore.or` 92), with 8 `@Invariant` and 26 `@Requires` / `@Ensures` |
| L0 platform | thread create / join / exit / id; monitors (mutex + 2 condition queues + integer words); the runtime lock; the lock of the stdout buffer | **C, forever** (`runtime/platform/orin_platform.{c,h}`) | +243 (platform total 700 of the 1,000 budget). Why a monitor has words: Orin values cannot be shared between tasks, so the state that tasks DO share (the task table of a scope, the buffer of a channel) needs minimal shared memory with the OS's mutual exclusion; integers behind a lock are the smallest such cell (an "atomic counter" with a lock, handle-checked), and they let every line of channel and scope logic stay Orin |
| runtime, temporary | transfer (`orin_rt_transfer_*`), task start / join / trap (`orin_rt_task_*`, `orin_rt_heap_exit`), forwarders that trap on a failed L0 call (`orin_mon_*`), grant clone / move / adopt (`orin_cap_*`) | **C, until R3** (`runtime/core/orin_runtime.c`, section "tasks and transfer") | 342 (transfer 130, tasks 80, `orin_mon_*` 35, trap forwarder 8, grants 70, rest 19), plus about 30 changed lines for per-task state |

Everything in the third row needs the object model (reference counts, struct / array / string layout, thread-local free
lists) and therefore cannot be Orin before R3. It is one interface, declared in one block of `runtime/core/orin_runtime.h`
("tasks"). Each function maps 1:1 onto a planned Orin core-dialect function (spec 19 R3; the core dialect has raw
addresses, load / store, `size_of` and header access, and calls L0 only through the closed list):

| C function (runtime, temporary) | What it does | Planned R3 Orin function (module `core/task`, `core = true`) |
|---|---|---|
| `orin_rt_transfer_put(box)` | detach the value of a one-field record: move if its graph is uniquely owned, deep copy otherwise; publish it in a slot; return a token | `core.transfer.put(box: Obj): usize` (uses `core.rc.isUnique`, `core.copy.deep`) |
| `orin_rt_transfer_take(tok)` / `orin_rt_transfer_drop(tok)` | claim the box of a token exactly once (stale token: trap); drop frees it | `core.transfer.take` / `core.transfer.drop` |
| `graph_unique(root)`, `copy_node`, `deep_copy` (static) | iterative uniqueness test and deep copy of the object graph | `core.rc.isUnique(root)`, `core.copy.deep(root)` (iterative, per object kind) |
| `tr_publish` / `tr_claim` (static, the slot table under the runtime lock) | in-flight values | `core.transfer` slot table (Orin array of slots + L0 `runtime_lock`) |
| `orin_rt_transfer_count(which)` | moves / copies counters of this task | `core.stats.transfer(which)` |
| `orin_rt_lend(box)`, `orin_rt_par_threads()` | lend the value of a two-slot record (ADR-0039 §4, below); the thread count of parallel pipelines | `core.lend.put`, `core.task.threads` |
| `orin_rt_task_spawn(tok)` | start a thread whose entry takes the closure out of the token, runs it and ends | `core.task.spawn(tok: usize): usize` (calls L0 `thread_create` with the Orin entry `core.task.main`; the entry calls the closure through an indirect call, which the core dialect has already) |
| `orin_rt_task_watch(m)` | C1: called by a task on its own thread (`spawn`): when the task ends, by return or by trap, the runtime sets word 1 of monitor `m` to 1 and notifies queue 0 under `m`'s lock, so that `joinUntil` can wait with a deadline instead of blocking in the thread join | `core.task.watch`; the end-of-task hook of `core.task.main` / `core.trap.endTask` calls L0 `monitor_lock / set / notify / unlock` |
| `orin_mon_wait_until(m, queue, deadline_ms)` | C1: forwarder for the timed monitor wait; returns 1 when the absolute `CLOCK_MONOTONIC` deadline passed, 0 when notified (or spuriously); traps on an invalid handle | `core.sync.waitUntil`, one line |
| `orin_rt_task_join(h)`, `orin_rt_task_message()` | wait; trapped? (the message of the last joined task) | `core.task.join`, `core.task.message` |
| trap hook in `orin_trap` (`task_active`, `task_trap`) | a trap on a task thread records the message, ends the task, never returns | `core.trap.endTask` (called by the Orin `core.trap`) |
| `orin_rt_heap_exit()` | end of a task heap: revoke its grants, close its files, free its free lists and work stack, fold its counters | `core.heap.retire()` |
| thread-local `g_live`, `orin_stats`, free lists, work stack, grant table, file table | the per-task heap state | fields of the Orin `core.heap.TaskHeap` record (R3 allocator), grant and file tables of `std:host` / `core.cap` |
| thread-local net buffer `netbuf()` (replaces `g_netbuf`; freed in `orin_rt_heap_exit`) | the bulk buffer between `u8[]` and L0 for `recv` / `send` / `resolve`, one per task | a field of `core.heap.TaskHeap` |
| `orin_rt_trap_str(msg)` | trap with an Orin string | `core.trap.fromString` |
| `orin_mon_*` (11 forwarders) | trap when an L0 monitor call fails | `core.sync.*`, one line each; the L0 functions they call are unchanged |
| `orin_cap_clone` / `orin_cap_move` / `orin_cap_adopt_*` (incl. `adopt_net`, `adopt_stream`, ADR-0017 Addendum C) | delegation of a grant, and the move of an accepted Stream (clone the record, detach it into a token, adopt it) | part of the `core.cap` module that replaces the C grant table |

L0 functions (stay C, handle-checked, contracts in `runtime/platform/orin_platform.h`): `orin_platform_thread_create / join / exit /
id`, `monitor_new / free / lock / unlock / wait / wait_until / notify / get / set / grow`, `runtime_lock / unlock`, and the pure `millis_split`. They do not move in R3.

The rest of the change in `runtime/` is mechanical and disappears with the C object model: `__thread` on `g_live`,
`orin_stats`, the free lists and the work stack of `orin_destroy`; the two tables of immortal singletons (`orin_nullary`,
one-character strings) are shared and published with a compare-and-swap (they are never written after creation).

## What the compiler does

| Where | Rule |
|---|---|
| checker (`compiler/check/tasks.or`) | **E0481** a task body (a closure literal passed to `spawn*`) captures a `Scope`. **E0482** `channel(0)`. **E0483** a task body captures a resource handle (the message points at `spawnFs` and friends; a Listener or Stream too). **E0487** (library code) a Listener moved or a Stream cloned |
| checker, existing rules that apply unchanged | E0450 (a resource as a type argument: `channel<FsGrant>`), E0451 / E0452 (a handle stored, returned, captured), E0301 (the task primitives live in the internal module `std:fsraw`; user code cannot import it), E0460 (generic methods) |
| checker, internal | the primitives are one builtin `BTask(k)` (`compiler/hir/taskops.or`: names, C functions, result kinds). `transitPut` and `lendPut` take any value but a handle (E0480), `transitTake` needs an expected type (E0407), `grantClone` / `grantMove` take any family grant (E0471 otherwise) |
| MIR verifier (v2.1, `compiler/verify`) | `grantClone` is an opener (authority: the parent handle), `grantMove` a closer that returns a token (a handle is moved exactly once on every path: never twice, never used or revoked afterwards, never left open at a return, never a parameter), `grantAdopt*` an opener whose argument is a token (it must not be a handle) and whose destination must be a bound handle that the function revokes exactly once. 14 cases in `compiler/tests/verify_main.or` |
| MIR, values | no instruction. A moved value is a value consumed by the record that carries it (`IStructNew` consumes it; the verifier kills every borrow of the consumed local), so "no value used after being moved into a task" is the existing ownership rule; the runtime moves only if the graph's counts say it is the only owner |
| lowering | one arm (`compiler/lower/ops.or`, `isFileOpen`, on the `Lowerer` of rewrite step 3a, MIR v2.0): the new openers define a handle local like `BGrant*`. Every other task primitive is an ordinary `IBuiltin` and takes its span from the HIR node; the 3a contracts (every instruction has a span, every block reachable) hold. Step 3a was merged before this branch finished, so no separate lowering path exists |
| OSIG | spawning is a `PERFORMS_IO` edge to the `Effect` node `~io:Task.Spawn` (`CONTROL`; `Task.SpawnFs` etc. name the delegated family), `Task.Join` is `CONTROL`, `Channel.Send` is `OUTPUT`, `Channel.Receive` is `INPUT`, `Channel.Open` is `CONTROL`. What a task body does is attributed to the enclosing function with `MAY` evidence like every closure. Edges between tasks are therefore the send / receive effects themselves (every sender and receiver of any channel meets at the same effect node); matching a send to its receivers per channel is a stage-1 analysis |

## Safety argument

**Statically checked (compile time).** Resource handles cannot be captured, stored, sent or returned (E0450-E0452), so
nothing non-copyable crosses a task boundary as a value; a task body cannot capture a `Scope` (E0481) or a handle (E0483); a
constant channel capacity of 0 is refused (E0482); the task primitives cannot be named by user code (E0301). The MIR
verifier re-checks, independently of the checker, that every handle is opened and closed or moved exactly once on every path
of the function that owns it, which is what makes the grant delegation sound. Values are immutable and closures capture
snapshots, so there is no shared mutable language-level value to race on.

**Checked at run time (always on).** Every L0 handle (thread, monitor) is validated on every call (generation, liveness;
a stale or forged handle is refused, never dereferenced) and monitor access needs the lock held by the caller (checked
against the caller's thread id). A transfer token is valid for exactly one take or drop; a grant token for exactly one
adopt, of the family it names. A grant handle used on another thread than its owner traps (per-task tables, the owner's id
is part of the handle). A second `join`, a spawn in a finished scope and a use of a released channel trap. A trap on a task
thread cannot leave a monitor locked (L0 releases the monitors the thread holds when it ends).

**`TESTED_ONLY` until R3 / R4 (stated honestly).** The central claim, *no object is reachable from two tasks*, rests on
C code: (1) allocation and reference counts are thread-local; (2) `orin_rt_transfer_put` moves only when every counted
reference in the graph is the only one, so the sender's heap holds no other counted reference, and the MIR ownership
verifier guarantees that no uncounted borrowed alias of the consumed local survives; otherwise it copies; (3) the only
state that crosses tasks is transfer slots, monitor words (integers, under a lock) and grant tokens, all behind handles
that are validated. The evidence is `runtime/core/tests/task_test.c`, `runtime/platform/tests/platform_test.c` and the stress tests,
run under ThreadSanitizer, AddressSanitizer + UBSan and plain, plus the conformance programs; not a proof. R3 moves (1)-(3)
into Orin core code (then MIR-verified for the ownership part) and R4 proves the transfer against the Lean model ("disjoint
heaps, send transfers ownership"). L0 thread and monitor primitives stay C: contracts written, `TESTED_ONLY` (CBMC cannot
model threads); a proof would need a concurrency-aware C verifier and an OS model.

What the argument does **not** claim: absence of deadlock (a program whose tasks all wait hangs; there is no detection), fairness,
bounded memory under a slow consumer beyond the channel capacity, cancellation, or that a trapped task frees what it
allocated.

## Tests

| Test | What it checks |
|---|---|
| `tests/next/run/task_*.or` (11) | spawn / join, 500 tasks, channel ping-pong, a producer / transformer / consumer pipeline, scope-exit join, a panic propagating at `join`, a panic found at scope exit, send of large values (copy and move, content intact), every kind of value (`Map`, interface value, closure), a grant moved into tasks (scope respected, 300 tasks each with their own grant), `parallelMap`. Run by every conformance mode: C, LLVM, `--no-opt`, `--c-builtins`, sanitizers |
| `tests/next/errors/e0481 e0482 e0483 e0450_channel_of_grant e0301_task_primitives_are_internal` | one negative test per checker rule |
| `tests/std/taskcore_test.or` (5 `@Test`), `tests/std/task_test.or` (7) and `tests/std/expect_trap/task_*.or` (4) | the invariants and contracts of `Ring` and `Ledger` (checked by `orin test`; all 35 contract obligations of `std:taskcore` are `VERIFIED` by `orin verify --contracts`), channel semantics in one task, the move / copy counters, joins in any order, `parallelMap` against `map`; traps that hold without contracts (join twice, a panic reaching the joiner, use of a released channel, capacity 0). `tools/mutation.sh std --module taskcore`: 16 mutants, 16 killed (14 by a contract) |
| `compiler/tests/verify_main.or` (14 cases) | the grant move rules of the MIR verifier |
| `tooling/clitests/src/osig.or` section 8 (`tools/clitests.sh osig`) | the task events of the OSIG |
| `tests/concurrency/timed_waits.or`, `timed_join_panic.or` | C1: timeouts fire and never early, values arriving before the deadline, buffered value at an expired deadline, `Closed`, full-channel `sendTimeout`, `select` (ready channel, tie, skipping closed channels, all closed, woken by a send and by closes, timeout), `sleep` lower bound, `joinTimeout` on a blocked task (then a later `join`), a trapped task ends a timed join. Plain, TSan, ASan |
| `runtime/core/tests/task_test.c` (98 checks) | transfer (move, copy, shared children, immortals, scalars, a 200,000-deep chain), 64 tasks, trap in a task, ping-pong, cross-heap frees, grants moved and per task, invalid handles |
| `runtime/platform/tests/platform_test.c` (+54 checks, 795 in all) | thread / monitor contracts, errors, mutual exclusion, condition queues, a thread dying with a lock held, concurrent stdout |
| `tests/concurrency/stress_tasks.or`, `stress_messages.or`, `panic_chain.or`, `panic_many.or`, `move_counts.or` | 3,000 live tasks, a tree of 255 scopes, 20,000 short tasks (23,254 tasks in all), 40,000 messages through one channel with 8 producers and 4 consumers, 20,000 ping-pong round trips, structured messages checked on arrival; a panic crossing three tasks and 300 simultaneous unjoined panics (exit status 101, no hang or crash under the sanitizers); no live object at exit (`ORIN_STATS`); what the default build moves and what it copies |
| `tools/test_concurrency.sh` | all C tests and the stress tests plain, under **ThreadSanitizer** and under **ASan + UBSan**; `tools/verify_platform.sh` also runs the platform tests under ThreadSanitizer. CI: `ci_local.sh` steps "concurrency (tsan, asan)" and "platform layer" |

## Measurements

Machine: 4 cores shared with other workers (load average 12-14 while measuring), gcc 13 `-O2`, Linux. Numbers are medians
unless stated; the wall-clock ones are noisy.

**Cost for programs that never start a task (the thread-local heap state).** The same generated C of eight benchmarks linked once
with the runtime of the commit before this work and once with the current one, counted in executed instructions with callgrind
(deterministic, immune to the load): `fib` 1.0000, `sieve` 1.0000, `nbody` 1.0000, `strings` 1.0138, `wordfreq` 1.0132, `mapfreq`
1.0159, `qsort_func` 1.0143, `bintrees` 1.0197 (the allocation-heavy ones pay for the free-list counters of the per-task cap). A first
version with the default TLS model cost up to +5% (an extra load per counter update in a position-independent executable);
the counters now use the `local-exec` model on ELF targets, which is valid because the runtime is always linked into one
executable. Wall-clock medians of 9 interleaved runs ranged 0.90-1.17 (noise under a load average of 12-14, no systematic
difference; `docs/benchmarks.md` has the method).

**Tasks (`bench/tasks/main.or`, `-O2`, load average about 12).** Spawn + join of a task: about 83 us (20,000 tasks in 1.66 s; 1.1 s of it
system time: thread creation and stack mapping). Channel ping-pong between two tasks over capacity-1 channels: about 3.7 us per
message (200,000 messages in 0.74 s). One producer, one consumer, capacity 64: about 1.5 us per message (1,000,000 in 1.46 s). Stress:
23,254 tasks and 40,000 + 40,000 messages in 2.1 s plain.

**Move versus copy (`build/mvbench` style, 1,000,000 ints and 100,000 strings).** Copying an `int[]` of 1,000,000 elements through a
channel costs about 3.5 ms, a `string[]` of 100,000 elements about 14 ms (one allocation per string); a moved value costs the
uniqueness walk only and was not measurable next to building the value (1.0 s vs 0.93 s for 200 builds of the array).

**Parallel speedup on 4 cores (`examples/parallel_map.or`, Collatz steps of 1..1,500,000, 4 tasks).** **Not demonstrated on this
machine.** Four cores were shared with other workers (load average 8-14), so the wall-clock ratio sequential / parallel measured
0.74-1.17 over 14 runs (median about 1.0) and the whole process received only about 55-65% of one core
(`time`: real 2.0 s, user 1.1 s). What the runs do show: the parallel and the sequential result are equal in every run, and
the CPU time of the parallel version is the same as the sequential one (user 1.21 s against 1.10 s: no copying or locking
overhead that would eat a speedup; the chunks are moved or copied once). The experiment has to be repeated on an idle machine
(`orin run examples/parallel_map.or 3000000 4`); no speedup number is claimed here.

## Fork/join pool and lending (ADR-0039, `parallel()` on arrays)

Added after stage 0, for parallel array pipelines (docs/std.md "Parallel pipelines"). Everything but one runtime mechanism
(lending) is Orin.

| Piece | Where | What |
|---|---|---|
| `forkJoin(chunks, workers, body)`, `forkJoinUntil(chunks, workers, body, hit)`, `parallelism()` | `std:task` (Orin) | a pool for ONE call: `workers` tasks (or the caller alone when `workers` <= 1) compute `body(k)` for the pieces `k`; results in piece order; `forkJoinUntil` cancels the pieces after the first hit and still runs every piece before it. A panic in a piece cancels what nobody started, joins every worker, then traps the caller with the piece's own message (no `task panicked:` prefix, so a parallel pipeline traps like the sequential chain) |
| work stealing | `Ranges` in `std:taskcore` (pure class, 3 invariants: equal lengths, cut <= chunks, every range inside 0..chunks and no piece in two ranges) | worker w owns pieces lo[w] .. hi[w]-1 and takes them from the front; an idle worker steals the back half of the largest range below the cut; one monitor holds the words |
| `lend` | runtime C (temporary, the transfer section): `orin_rt_lend` (`lendPut`) of a TWO-slot record | pins the graph of the value (each positive count becomes `PIN | owner << 32 | count`, which is negative, so inline retain / release skip it), records the pinned objects; `transitDrop` of the token restores them. A transfer by the owner SHARES pinned objects (the workers' closures reach the input that way, no copy); a transfer by any other task COPIES them (a worker's result never refers into the lent graph) |
| thread count | `orin_rt_par_threads()` (runtime, `parThreads`) over the new L0 `orin_platform_cpu_count()` | `ORIN_THREADS` (1..1,024) or the processors online |

**Soundness of lending (TESTED_ONLY, like the rest of the C transfer).** While a value is lent, nothing in its graph changes:
a retain / release of a pinned object is a no-op (no shared count is written, so no data race), `orin_make_unique` copies it
(count != 1), nothing in it is freed. The owner's obligation, kept by the only user (`library/collections/parallel.or` and the code the fusion
pass generates): between lend and end it only spawns the worker tasks and joins them, and a reference to a pinned object made in
the window is gone before the end (a reference that outlived it would be uncounted). Worker results come back through a transfer
by a non-owner, which copies pinned objects. Evidence: `runtime/core/tests/task_test.c` (`test_lend`: no copy, counts untouched and
restored, a record sent back is a copy, no live object), `tests/concurrency/par_pipelines.or` and `tools/test_parallel.sh`
(ORIN_THREADS 1..8, fused / `--no-fuse` / `--no-opt`, ThreadSanitizer at 2, 4, 8 threads, ASan + UBSan). `ORIN_STATS`: the peak
live counters no longer wrap to 2^64 - 1 for a task whose own frees exceed its allocations (a defect found here).

## Friction found while building it

* **Generic methods do not exist** (E0460), so `s.spawn(f)` of the ADR sketch is the function `spawn(s, f)`.
* **A generic result cannot be `void`**: every `scope` / `spawn` has a `Do` flavour, like `with*` / `use*` in std:fs.
* **Closures cannot capture a handle**, so a body running inside `useFs(host, fs => ...)` cannot reach `fs`: the `scopeFs`
  family passes the grant through as a second parameter. A body that needs two grants cannot have both (a `scopeHost`
  with the four root grants, like `useHost`, would fix it when a program needs it).
* **Closures cannot assign captured variables** (ADR-0011), so results come back through `join` or a channel, never through a
  `let`.
* **No last-use move of named locals**: the lowering releases a local at scope exit, so sending a named local copies. The
  fix belongs to the performance model (ADR-0038), not to this stage.
* **Contracts cannot read monitors** (impure), so the channel and the task table keep their state in pure classes
  (`Ring`, `Ledger`) that are loaded from the monitor, changed and stored inside the critical section: the invariants are
  real and testable without threads.
* **One condition variable per monitor was a thundering herd**; a monitor now has two queues and `notify_one`.
* The sandbox / CI cost of a full compiler build (7-8 minutes under load) dominated the loop; a one-stage `-O0` build
  of the compiler with the previous compiler (27 s) was used for iteration, the fixed point was checked separately.

## Gate 1, C0: cancellation and outcomes (ADR-0017 Addendum B)

C0 adds the semantics and the pure state machines only; nothing blocks differently yet. `std:taskcore` gains `CancelState` (a token's
first-cause-wins cancellation cause plus an absolute monotonic deadline that only moves earlier, with `observe`/`budget`),
`CancelScope` (a scope's counters; a trapping child cancels the scope), `TaskCell` (a result settled once and taken once), and
pure functions for the outcome lattice (`Completed < Closed < Cancelled < Deadline < Error`, `outcomeJoin`), checkpoint precedence
(`checkpointOutcome`) and deadline arithmetic (`deadlineMin`, saturating `deadlineAfterMillis`, `deadlineExpired`, `waitBudget`), all with
`@Requires`/`@Ensures`/`@Invariant` contracts and tests in `tests/std/taskcancel_test.or`. The L0 budget for what follows is
ADR-0054 (1,400 code lines).

Next: scope cancellation in `std:task`, wired to these machines (C2); C3 interruptible network waits.

## Gate 1, C1: timed and wakeable waits

L0 got `orin_platform_monitor_wait_until(h, cond, deadline_ms)` (0 = notified or spurious, `ORIN_PLATFORM_WAIT_TIMEOUT` = the absolute deadline passed,
`EINVAL` as `wait`) and the pure `orin_platform_millis_split`; the L0 code is now 1,036 of the 1,400 lines (ADR-0054, +37). A monitor's two
condition variables are created with `CLOCK_MONOTONIC` (`pthread_condattr_setclock`) on Linux, so `pthread_cond_timedwait` takes the same
instants as `monotonic_millis`; macOS has no `setclock`, so there the remaining time is computed from `monotonic_millis` and passed to
`pthread_cond_timedwait_relative_np` (not run in CI here). `millis_split` has a CBMC harness (`harness_millis_split`: exact timespec, no
overflow); the wait itself is TESTED_ONLY like the other thread primitives (CBMC cannot model threads): `platform_test.c` checks timeout, a
past deadline, a notification before the deadline and argument errors, plain, under ASan and under ThreadSanitizer.

How the std:task calls use it (all in Orin, `library/std/task.or`):

* **Deadlines are absolute.** A timed wait loop re-waits with the SAME instant after a spurious wake-up, so nothing stretches it; the relative forms
  read the clock once (`ClockGrant`, ADR-0027) and add with the saturating `deadlineAfterMillis` of std:taskcore. The `Until` forms need no
  grant: a `Deadline` can only come from a clock reading. After a timeout the condition is checked once more, so a value that arrives at the
  deadline is delivered (the precedence of `checkpointOutcome`: completing beats closed beats timing out).
* **`recvUntil` / `sendUntil`** wait on the channel's own condition queue with `wait_until`.
* **`joinUntil`**: `spawn` makes the result monitor two words; word 1 is set by the runtime when the task ends (`orin_rt_task_watch`, also on a
  trap), and `joinUntil` waits for it before the ordinary `join`, whose thread join then returns at once.
* **`select`**: channels gained a watcher list (monitor words 4 and 5, `CH_HDR` = 6). A select creates one private monitor whose word 0 is a
  ticket, registers it with every channel, and waits on it. Every `send` and every close bumps the ticket of each watcher (channel lock, then watcher lock);
  the selector reads the ticket, scans the receivers in order without holding its monitor, and sleeps only while the ticket is unchanged, so a
  send between the scan and the sleep is not lost. It is one timed wait, not a poll loop. Cost on the plain `send` path: one extra monitor read.
* **`sleep`** is a timed wait on a private monitor nobody notifies.

Not in C1: cancellation of waits by a token (C2 adds `Cancelled` to `TaskErrorKind` and the token word to the checkpoints), a `timeout(d)` arm kind
for `select`, receivers of different value types in one `select`.

## Not in stage 0 (and where it goes)

`async` / `await` (ADR-0017: only if blocking tasks prove insufficient); cancellation beyond `rx.close()` and cooperative
sibling cancellation at the scope boundary (C2; timeouts, `select` and `sleep` are C1, above); a M:N scheduler (a task is a thread: thousands fine,
hundreds of thousands not; the L1 scheduler of ADR-0017 is future work and std:task's `Ledger` / `Ring` logic is the part
that carries over); deadlock detection; `Shared<T>` for read-only sharing (post-1.0 option of ADR-0017); per-task regions
(ADR-0038); a real `std:net` server with one task per connection (std:net had not landed on `main`; the CPU-parallel example
`examples/parallel_map.or` stands in); native Windows threads (`docs/windows.md`: the L0 thread and monitor functions need a
Win32 backend).
