# 8. Concurrency surface

Normative for the language-visible part of concurrency as implemented (stage 0 plus Gate 1 C1 and C3). Sources: ADR-0017 (with its
addenda), ADR-0039 (`parallel()`), ADR-0048 (task errors), `docs/concurrency.md`, `docs/std.md` "Parallel pipelines",
`library/std/task.or`, `compiler/check/{tasks,parallel}.or`. Conventions: see [README](README.md).

There is no `async` / `await` (both are reserved words, chapter 1). A *task* is an operating-system thread with its own heap.
Tasks are created through `std:task` (`import { scope, spawn, channel } from "std:task"`).

Test locations. The `task_` and `par_` programs of `tests/next/run` are conformance tests. The programs of `tests/concurrency/`
(timed waits, panic chains, stress) are not run by the conformance runner; they run under `tools/test_concurrency.sh` (plain,
ThreadSanitizer, ASan + UBSan). `tests/std/` unit tests run under `orin test`. The central soundness claim (no object is
reachable from two tasks) is `TESTED_ONLY`; absence of deadlock, fairness and cancellation of running tasks (other than the
network waits of 8.6) are not guaranteed.

## 8.1 Tasks and scopes

**TSK-1. Structured scopes.** `scope(body: (s: Scope) => R): R` runs `body(s)`, then joins every task spawned in `s`, then
returns the result of `body`. `R` may be `void` (ADR-0040); `scopeDo` is a `@Deprecated` wrapper kept for one release. A task never outlives its scope.
Tests: tests/next/run/task_scope_exit_join.or, tests/next/run/task_spawn_join.or, tests/next/run/task_many.or.

**TSK-2. Spawn and join.** `s.spawn(f: () => T): TaskHandle<T>` is a generic method of `Scope` (ADR-0040); it starts `f` as a task, and
`T` may be `void`. `h.join()` waits and returns the result. The free functions `spawn(s, f)` and `spawnDo` are `@Deprecated`
wrappers kept for one release. `select` and the other generic operations that take several receivers remain free functions.
Tests: tests/next/run/task_spawn_join.or, tests/next/run/task_many.or, tests/next/run/generic_methods.or.

**TSK-3. Join once.** A second `join` of one handle, a `spawn` on a scope that has ended, and any use of a released channel
trap at run time.
Tests: tests/std/expect_trap/task_join_twice.or, tests/std/expect_trap/task_channel_use_after_release.or.

**TSK-4. Panics propagate.** A trap in a task ends that task only. `join` turns it into a trap of the joiner with message
`task panicked: <message>`. A panic in a task nobody joined is reported when its scope ends; no panic is lost. A panic in the
body of a scope does not stop tasks that are still running.
Tests: tests/next/run/task_panic_join.or, tests/next/run/task_panic_scope_exit.or, tests/std/expect_trap/task_panic_reaches_join.or,
tests/concurrency/panic_chain.or, tests/concurrency/panic_many.or.

**TSK-5. Transfer.** A value crossing a task boundary (captured variable of a task body, task result, channel message) is
moved if every counted reference in its graph is unique, otherwise deep-copied. Both are a value copy to the program; the
choice is observable only in performance and in the counters `movedCount()` / `copiedCount()`. All value types are sendable
(scalars, strings, arrays, records, unions, `Option`, `Result`, `Map`, class instances, interface values, closures, and the
handles `Sender`, `Receiver`, `TaskHandle`).
Tests: tests/next/run/task_send_values.or, tests/next/run/task_send_kinds.or, tests/concurrency/move_counts.or.

## 8.2 Resources and tasks

**TSK-6. No resource crosses a task boundary.** A task body that captures a resource handle (a grant, `Host`, a file) is
E0483; one that captures the `Scope` it is spawned in is E0481. A resource as a type argument (`channel<FsGrant>`) is E0450;
storing, returning or capturing a handle is E0451 / E0452 (chapter 5).
Tests: tests/next/errors/e0483_task_captures_grant.or, tests/next/errors/e0481_task_captures_scope.or,
tests/next/errors/e0450_channel_of_grant.or, tests/next/errors/e0452_grant_captured.or.

**TSK-7. Delegating a grant.** `scopeFs`, `scopeProcess`, `scopeStdio`, `scopeClock` (and their `...Do` forms) pass the grant to
their body as a second parameter; `spawnFs`, `spawnProcess`, `spawnStdio`, `spawnClock` derive a grant of the same family with
exactly the authority of the given one, move it into the task and revoke it when the body returns or traps. The spawner's own
grant is untouched.
Tests: tests/next/run/task_grant_move.or.

**TSK-8. Internal primitives.** The task primitives live in the internal module `std:fsraw`; user code cannot import it (E0301).
E0480 is raised only for the internal transfer primitives given a handle and cannot be provoked from ordinary code.
Tests: tests/next/errors/e0301_task_primitives_are_internal.or.

## 8.3 Channels

**TSK-9. Bounded channels.** `channel<T>(capacity)` returns `{ tx: Sender<T>, rx: Receiver<T> }`, a bounded FIFO with capacity
at least 1. A constant capacity of 0 is E0482; a non-constant 0 traps. Both ends are copyable and may be used by any number
of tasks. Order between different channels is not defined.
Tests: tests/next/errors/e0482_channel_zero.or, tests/std/expect_trap/task_capacity_zero.or, tests/next/run/task_channel_pingpong.or,
tests/next/run/task_pipeline.or, tests/concurrency/stress_messages.or.

**TSK-10. Send and receive.** `send(v): bool` blocks while the channel is full; `true` if handed over, `false` if the channel is
closed (the value is dropped). `recv(): Option<T>` blocks while empty; `None` once the channel is closed by the sender and
drained, or closed by `rx.close()` (which also drops buffered values and makes senders get `false`). `close()` ends a stream.
Both ends closed releases the channel; a later use traps.
Tests: tests/next/run/task_channel_pingpong.or, tests/next/run/task_pipeline.or, tests/std/task_test.or,
tests/std/expect_trap/task_channel_use_after_release.or.

## 8.4 Timed waits, select and sleep (Gate 1, C1)

Tests in this section are in `tests/concurrency` and run only under `tools/test_concurrency.sh`.

**TSK-11. Errors.** Timed operations return `Result<_, TaskError>` with `TaskError = { kind: TaskErrorKind }` and
`TaskErrorKind = Timeout | Closed | ClockUnavailable | InvalidDuration`. `taskErrorMessage(e)` renders it. A negative timeout
is `InvalidDuration`.
Tests: tests/concurrency/timed_waits.or.

**TSK-12. Deadlines.** `...Until(deadline)` forms take an absolute monotonic `Deadline` (from `std:time`) and need no grant;
`...Timeout(clock, timeout)` forms take a `ClockGrant` and a `Duration` from now. A timed call never returns before its
deadline, and a spurious wake-up does not stretch it. A value already available (buffered, or a finished task) is delivered even
when the deadline has passed.
Tests: tests/concurrency/timed_waits.or.

**TSK-13. Timed channel and join operations.** `recvUntil` / `recvTimeout` return `Err(Timeout)` while empty and `Err(Closed)`
once closed and drained; `sendUntil` / `sendTimeout` return `Err(Timeout)` while full and `Err(Closed)` when closed;
`joinUntil` / `joinTimeout` return `Err(Timeout)` if the task has not ended (the handle stays valid), otherwise exactly
`join()` (a panicked task still traps the joiner).
Tests: tests/concurrency/timed_waits.or, tests/concurrency/timed_join_panic.or.

**TSK-14. Select.** `select(rxs)`, `selectUntil(rxs, deadline)`, `selectTimeout(clock, rxs, timeout)` take an array of receivers
with one value type and return `Result<Selected<T>, TaskError>` with `Selected<T> = { index: usize; value: T }`. The first ready
receiver in array order wins; closed and drained receivers are skipped; `Err(Closed)` when all are.
Tests: tests/concurrency/timed_waits.or.

**TSK-15. Sleep.** `sleep(clock, timeout): Result<void, TaskError>` and `sleepUntil(deadline): void` block at least that long on
the monotonic clock; `sleepUntil` of a past deadline returns at once.
Tests: tests/concurrency/timed_waits.or.

## 8.4a Cancellation of network waits (Gate 1 C3, ADR-0017 Addendum D)

**TSK-15a. Scope tokens.** Every scope has a cancellation token. `s.token(): CancelToken` is a copyable value (a task body may capture
it; it cannot capture `Scope`, E0481). `token.cancel(): bool` and `s.cancel(): bool` set it and return `true` exactly once;
cancellation is permanent. `isCancelled()` (free function) and `token.isCancelled()` / `s.isCancelled()` report whether the calling
task's token, or the one named, or any enclosing scope's, is set. A task is bound to the token of the scope it was spawned in; a
scope opened inside a task has a child token, so an outer cancel reaches every depth and an inner cancel only its own tasks.
Tests: tests/concurrency/cancel_tokens.or, tests/concurrency/cancel_storm.or.

**TSK-15b. Stale tokens.** A token kept after its scope has ended is stale: `cancel()` returns `false`, `isCancelled()` returns `false`, and
it never affects another scope, whichever slot that scope reuses (the handle is generation-tagged).
Tests: tests/concurrency/cancel_tokens.or.

**TSK-15c. Network waits observe the token.** A task blocked in `accept`, `connect`, `recv` or `send` of `std:net` (including the readers
`StreamReader.readExact` / `readUntil` and the `...Until` forms) returns when its token is set, within milliseconds, with
`Err(NetError { kind: Cancelled })` (also for `recv` and the readers); every later network call of
that task fails the same way without touching the socket. Not interrupted: name resolution (`getaddrinfo`; documented limitation), waits on
channels, `join`, `select` and `sleep` (C2), and computation.
Tests: tests/net/interrupt.or (via tools/test_net.sh), tests/std/net_test.or, tests/concurrency/cancel_storm.or.

**TSK-15d. Operation-wide deadlines.** `recvUntil`, `sendUntil`, `sendAllUntil`, `StreamReader.readExactUntil`, `readDelimitedUntil`,
`withAcceptedUntil`, `acceptDetachedUntil`, `withConnectionUntil` and `useConnectionUntil` end at an absolute `Deadline` however many
reads or writes the operation takes; an operation that is ready at a deadline that has passed still completes once. `Timeout` is the kind
when the deadline passes.
Tests: tests/net/interrupt.or, tests/std/net_test.or.

## 8.5 Data-parallel helpers and `parallel()` (ADR-0039)

**TSK-16. `parallelMap`.** `parallelMap(xs, f, parts)` equals `xs.map(f)`, computed by `parts` tasks over contiguous chunks,
results in order.
Tests: tests/next/run/task_parallel_map.or.

**TSK-17. `parallel()` pipelines.** `xs.parallel()` returns a view with `map`, `filter` (views) and `reduce(f, init)`, `some`,
`every`, `find`, `findIndex`, `toArray`. No import is needed. The result equals the sequential chain: input is split into
chunks of 4,096 elements (independent of the processor count); `reduce` folds each chunk left to right and then folds `init`
with the chunk results in order; `some` / `every` / `find` / `findIndex` give the sequential answer. Inputs below 8,192
elements and every run with `ORIN_THREADS=1` run on the calling task. A trap in a closure traps the program with the closure's
own message (not wrapped in `task panicked:`).
Tests: tests/next/run/par_ops.or, tests/next/run/par_trap.or, tests/concurrency/par_pipelines.or, tests/concurrency/par_lent.or.

**TSK-18. E0484, closures must be pure.** Every function passed to a parallel operation is an arrow function or a named
function and is pure (no I/O, no impure call, no call of a function value); otherwise E0484, naming the effect.
Tests: tests/next/errors/e0484_parallel_impure.or, tests/next/errors/e0484_parallel_impure_callee.or,
tests/next/errors/e0484_parallel_function_value.or.

**TSK-19. E0485, reducer.** The reducer of a parallel `reduce` is a built-in associative operator: `+` (integers, floats,
strings), `*` (integers, floats), `&&`, `||`, min or max written as `a < b ? a : b` (and the other orders and comparisons) or
`Math.min` / `Math.max`, with the parameters in either order. Any other reducer, including a named user function, is E0485.
Tests: tests/next/errors/e0485_parallel_reducer.or, tests/next/errors/e0485_parallel_reducer_function.or.

**TSK-20. E0486, element type.** The input element type is a scalar (integers, floats, `bool`) or a record whose fields are all
scalars; otherwise E0486. Stages may produce any type.
Tests: tests/next/errors/e0486_parallel_element_type.or, tests/next/errors/e0486_parallel_nested_record.or.

**TSK-21. Reduce warnings.** W0480: a parallel float `reduce` (float arithmetic is not associative; the result is the same on
every machine and thread count but may differ from the sequential fold in the last bits). W0481: a parallel integer `reduce`
with signed `+` or with `*` (a partial result may overflow where the sequential fold does not). Unsigned `+` gives no warning.
Tests: tests/next/run/par_float_reduce.or, tests/next/run/par_ops.or.

## Gaps: rules without a test

- `scopeFs` / `spawnFs` variants other than the one in tests/next/run/task_grant_move.or (`scopeProcess`, `scopeStdio`,
  `scopeClock`, `spawnClock`, ...) have no test of their own.
- `spawnDo` and `scopeDo` have no test that pins the `TaskHandle<bool>` result.
- That a panic in the body of a scope leaves running tasks running, and the leak of a trapped task, are documented limits with no
  test.
- The ordering guarantee "FIFO per channel" with several senders is exercised only by stress programs that check counts
  (tests/concurrency/stress_messages.or), not order.
- `forkJoin`, `forkJoinUntil`, `parallelism()` as direct API (outside `parallel()`) have no conformance test; the cancellation
  of pieces after the first hit is covered only through `find` / `findIndex` in tests/next/run/par_ops.or.
- `ORIN_THREADS` handling (range 1..1,024, default = processors online) is exercised by `tools/test_parallel.sh`, not by a
  conformance test.
- W0481 is covered only as a side effect (`// warns: W0481 W0481` in tests/next/run/par_ops.or); no test isolates the
  unsigned-`+` no-warning case.
- E0482 for a non-constant zero capacity is a run-time trap; the trap test is tests/std/expect_trap/task_capacity_zero.or only.
- Absence of deadlock detection, the cancellation of channel waits and of a scope by a trapped task (Gate 1 C2) and a `timeout` arm
  for `select` are not implemented, so there is nothing to test.
