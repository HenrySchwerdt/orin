# Async and concurrency: foundations before syntax

Status: proposed implementation roadmap, 2026-10-16. Factual baseline:
`origin/main` at `8ec3679`. This document changes no accepted runtime behavior,
public API, language freeze, or delivery date. Milestone names below are work
packages, not implemented APIs. The separate public clock work is active but
is not present in this baseline; integrate its reviewed result rather than
implementing a competing clock surface.

Orin already runs concurrent tasks. It does not yet offer a general lightweight
task scheduler with nonblocking waits. The next useful release is dependable
cleanup, cancellation and deadlines using ordinary library calls. `async` /
`await` is a later decision based on evidence, not a prerequisite for those
features. [ADR-0017](../decisions/0017-concurrency-design.md) allows syntax only
if blocking tasks prove insufficient; [ADR-0016](../decisions/0016-language-1.0-core-scope.md)
places async/await post-1.0 and requires ADR approval for syntax/semantic changes.

## Current behavior and evidence to preserve

| Area | Implemented at the baseline | Gap relevant to this roadmap |
|---|---|---|
| Isolated tasks | `scope`, `spawn`, `join` in [std:task](../../stdlib/task.or); one OS thread per task; move/deep-copy transfer, non-atomic per-task RC | No general cancellation, timed join, or task scheduler that parks logical tasks |
| Channels | Bounded FIFO, blocking send/recv, explicit sender/receiver close; receiver close discards buffered tokens and wakes waiters | Close affects the shared channel; it is not per-operation or per-task cancellation. No timed waits or `select` |
| Traps | Task trap records failure, closes its grants/files, folds counters and exits its thread; join traps the joiner | No stack unwind or live-scope registry; nested children can survive their owner's trap. Live heap objects can leak. Releasing held monitor locks does not prove protected state consistent |
| Parallel arrays | ADR-0039 fork/join workers, chunk stealing, scoped immutable lending, ordered results; pool stops unstarted chunks after failure/early hit | This is a bounded computation pool for one call, not a general I/O scheduler or general sibling cancellation |
| TCP | [std:net](../../stdlib/net.or) resources with per-call timeouts and whole-operation deadlines in sendAll/read helpers | Sockets use nonblocking mode internally, but each `poll` blocks the caller's OS thread. DNS is synchronous and outside connect timeout; no cancellation wakeup |
| Clock | Public `std:time.nowMillis(ClockGrant)` is wall-clock time; Duration helpers exist. Live network handles expose monotonic time | General public monotonic/sleep/deadline work is separate and not landed here; wall time cannot implement elapsed deadlines |
| Network ownership | Listener/Stream are scoped resource handles in the owning thread's grant table | They cannot be captured, returned, stored in values or sent. Task grant delegation covers fs/process/stdio/clock, not net. An accepted stream cannot currently be handed to a task |

Source anchors: runtime `task_trap`, `task_main`, `orin_rt_heap_exit`,
`orin_rt_task_join` in [orin_runtime.c](../../runtime/orin_runtime.c);
`orin_platform_thread_exit`, `orin_platform_monitor_wait`, `net_wait`,
`orin_platform_tcp_connect` in [orin_platform.c](../../platform/orin_platform.c).
The source calls `pthread_join` / `pthread_cond_wait`; `net_wait` polls one fd.
Internal socket nonblocking mode alone does not provide nonblocking task waits.
Existing timeout documentation is not evidence of a total DNS/connect bound:
[ADR-0033's honest limits](../decisions/0033-l0-network-primitives.md) explicitly
exclude DNS; multiple address attempts and EINTR retry budgets also need audit.

Existing [concurrency documentation](../concurrency.md) and
[concurrency checks](../../tools/test_concurrency.sh) supply regression tests,
stress runs and sanitizer evidence. They do not establish fairness, deadlock
freedom, safe recovery, or a supported maximum connection count. Historical
"thousands fine" wording is not a capacity guarantee for a server.

## Delivery order and review gates

### 1. Define cancellation and task termination; implement the small state machines

Deliver a reviewed ADR amendment plus pure Orin state machines in the existing
`taskcore` style. Preserve current `join(): T` trap propagation by default.
Specify task identity, live-scope registration, terminal outcomes, cancellation
request versus acknowledgement, and exactly-once claims of joins/results/tokens.
Use a bounded cancellation tree: parent requests cancellation of descendants;
acknowledgement means execution and cleanup actually finished, not just a flag.
Cancellation is cooperative. CPU loops need explicit checkpoints initially;
forced thread killing or silently adding compiler safepoints is outside this slice.

Candidate outcomes for new fallible wait helpers must distinguish completed,
closed/drained, cancelled, deadline expired and operational error. Exact names
and signatures need API review. Do not encode cancellation as ordinary channel
EOF or a task trap, and do not turn existing traps into successful values.
Document whether a cancelled send committed: a transferred message is delivered
once or retained/dropped under a specified rule, never ambiguously retried.

Acceptance: enumerate state transitions and competing terminal events; model
spawn versus scope close, completion versus cancellation, join claim versus
timeout, and repeated cancellation. Deterministic tests assert one terminal
result, one owner of every transfer token and no authority widening. This can
land without exposing recovery or claiming that all waits are interruptible.

### 2. Make channel/join waits interruptible, then close the task-scope cleanup gap

First add minimal L0 wakeable/timed wait mechanics; keep cancellation policy,
channel buffers and scope bookkeeping in Orin under
[ADR-0030](../decisions/0030-provable-std-and-minimal-trusted-runtime.md).
Register a waiter atomically with checking completion/cancellation, then park;
a racing notification must not be lost. Recheck predicates after spurious wakes.
Use one absolute monotonic deadline through every retry. Review clock-grant
requirements and deadline provenance with the public clock API; a cancellation
token grants no I/O authority. A timed-out join must
not consume the sole join right or free a result another waiter still owns.
Never free a monitor while a waiter or cancellation callback can still reach it.

Then register each live scope with its owning task and make trap/normal scope
exit stop admission, request cancellation, wake blocked descendants, and join
them before releasing scope state. Define deterministic primary-failure and
secondary-failure reporting, including a trap in cleanup. Exercise the same
path when a join propagates a child trap into a parent with other live children.
A task cannot wait for itself or reclaim memory still used by descendants.

Keep these implementation pieces separate for review, but advertise trap-safe
structured cleanup only after their combined tests pass. Channel close remains
its existing shared-endpoint operation; cancelling one receive must not close
an unrelated user's channel. A cleanup hook cannot safely resume an arbitrary
monitor critical section after a trap: quarantine/abandon damaged state, or
fail the containing process when consistency cannot be established.

Acceptance: parent task traps with nested children blocked on empty/full
channels and joins; scope body traps before returning; cancel before/while/after
wait registration; close/drain races; multiple waiters; duplicate join; pending
result/message disposal. Assert all cooperative descendants finish, callbacks
are deregistered, and thread/monitor/transfer registries return to baseline.
A deliberately non-cooperating CPU child must demonstrate the documented limit:
no finite cancellation/cleanup guarantee. An external process watchdog can
bound the test; it is not a substitute for cleanup semantics.

### 3. Interrupt network waits and enforce operation-wide deadlines

Start with numeric loopback TCP accept/read/write/connect; add a wake source to
readiness waits so cancellation does not wait for the full network timeout.
Keep partial read/write results and stream ownership explicit. Cancel removes
its wait registration before resource closure; generation-tagged handles prevent
a late wake from acting on a reused fd. A cancel request must not close some
other task's unrelated descriptor. Retry EINTR, EAGAIN, partial writes and
multiple addresses against the same remaining budget, without wall-clock time.

DNS is a separate bounded work item: a bounded resolver pool with admission
limits may let a caller stop waiting, but cannot promise to stop a blocking OS
resolver. Track abandoned-but-running lookups, cap them, and reclaim late results.
Document that limitation or choose a reviewed cancellable resolver before
claiming end-to-end DNS cancellation. Apply the same blocking-adapter rule to
filesystem/process operations; moving them onto workers does not make the OS
operation itself cancellable. The existing `shellTimeout` is a command deadline,
not task cancellation or general captured process execution.

Server concurrency also needs an explicit capability/resource ADR amendment.
Choose reviewed network-grant delegation and accepted-stream ownership transfer,
or an acceptor that owns sockets and exchanges bounded value messages with
workers. Do not smuggle descriptors in integers or weaken E0450–E0452. The
acceptor design can offload pure CPU parsing today, but cannot claim parallel
network service until multiplexing/ownership is implemented.

Acceptance: stalled accept/read/write/connect, slowloris input, non-reading peer,
partial progress, disconnect/reset, expired/zero deadline, cancellation during
readiness registration, fd reuse, and cancelled DNS saturation. Assert partial
byte accounting, one close, bounded buffers/queued requests, and no deadline
extension by progress or retry. Test denied/narrowed grants and stale handles.

### 4. Establish reclaimable fault domains before public recovery

[ADR-0041 stage D](../decisions/0041-proof-guided-error-handling.md) explicitly
requires nested-scope cancellation and joining before isolated recovery.
Stages 1–3 remove blocking/child-lifetime obstacles; they do not by themselves
reclaim the trapped task's live object graph. Complete the R3/R4 and
[ADR-0038](../decisions/0038-performance-model.md) reclamation route, or review
another bounded task-heap reclamation mechanism with the same ownership proof
obligations. Do not free objects still in transfer slots, result buffers,
channels, lent graphs or descendants. Keep the successful supervisor's state
separate from the abandoned task's state.

Acceptance: repeated nested task faults with resources, pending tokens and
parallel lends; all reclaimed accounting returns to baseline after quiescence,
not merely suppressed leak reports. Test malformed input returning Result.Err
separately from modeled traps. Public containment requires an approved closed
recoverable-trap set; corruption, arbitrary native faults and unbounded OOM
cannot be relabeled as safe recoverable task failures. Partial external writes
remain visible and require application transactions/idempotency. Recovery is
not required merely because a function uses a capability.

### 5. Build a bounded scheduler and shared readiness backend behind the task API

After lifecycle/wait contracts stabilize, prototype an opt-in bounded worker
scheduler using existing call syntax. Start with one worker and explicit park /
resume points; add multiple workers only after task-state isolation holds.
A continuation mechanism (stackful contexts or compiler-lowered state machines)
is a separate design choice: library syntax does not make suspension free.
Do not substitute the CPU fork/join pool for a scheduler that can park an I/O task.

Implement a portable batched readiness baseline and benchmark it first. Add
platform-specific readiness backends only where measurements justify them;
keep OS wait/wake/context primitives in L0 and scheduler queues/timers/policy
in Orin. Bound live tasks, runnable queue, wait registrations, timer storage,
blocking-adapter queue and per-connection buffers; define admission failure and
backpressure instead of growing workers or queues without limit. A saturated
blocking pool must not prevent cancellation or cleanup from making progress.

Acceptance: with W configured workers and many parked connections, scheduler
thread count remains within W plus explicitly bounded adapters/control threads.
Run a one-worker regression where a parked task cannot stall ready peers.
Exercise lost/duplicate readiness, spurious wakes, timer churn, cancellation,
nested scopes and shutdown at capacity. Prove only supported pure state-machine
properties; runtime/OS tests remain TESTED_ONLY. Publish memory, queue and thread
high-water marks, throughput and latency distributions against the 1:1 baseline
on recorded hardware/OS/builds. No speedup or connection-capacity claim precedes
those measurements.

## Suggested implementation PR boundaries

Each row must build independently and keep unimplemented behavior unavailable.
The rows refine the milestones above, rather than authorize implementation.

| Slice | Main implementation area | Merge gate |
|---|---|---|
| Cancellation/termination model | ADR-0017 amendment and pure `stdlib/taskcore.or` machines | Terminal-event and ownership transition tests |
| Channel waits | Minimal L0 timed/wake primitives and `stdlib/task.or` | No lost wake or token leak under cancel/close/deadline races |
| Completion waits | Runtime completion publication plus Orin join bookkeeping | Timeout leaves a valid join obligation; exactly one final claimant |
| Nested-scope termination | Runtime live-scope registration and Orin cancellation/drain | Trapping parent joins cooperative descendants before state release |
| TCP wait interruption | L0 readiness/wake and `stdlib/net.or` adapters | Numeric loopback cancellation and total-deadline tests; DNS limitation explicit |
| Concurrent server ownership | Separate resource/grant ADR and bounded example | No forbidden capture or authority widening; admission/cleanup campaign |
| Reclamation | R3/R4 object model or approved alternative | Repeated faults restore accounting including transfers/lends |
| Scheduler experiment | Explicit task state, bounded queues/timers, readiness backend | One-worker progress, worker-bound and fairness evidence before multi-worker migration |

## Scheduler ADR questions that must be resolved before migration

| Current assumption | Required decision/evidence |
|---|---|
| Heap counters, freelists, destruction stack, task/trap pointer, joined-message buffer, grants/files and profiling state are TLS | Inventory every TLS field. Store logical-task state explicitly or save/restore it completely at switches; classify truly worker-local scratch buffers. A pinned task still shares its worker with other logical tasks |
| Grant identity/monitor owner use OS thread identity | Define unforgeable logical task identity and handle ownership without broadening authority. Worker migration cannot make a foreign task's grant valid |
| Non-atomic RC is safe inside an isolated task | Never execute the same task concurrently on two workers; publish transfers with synchronization; preserve deep-copy/move isolation |
| Monitors are pthread mutexes/condition variables | No yield while holding an OS-thread-owned lock; park/unpark must preserve atomic predicate registration and exactly-once wakeup |
| Resources are borrowed scope parameters and cannot escape | Define suspension across open resource scopes, continuation lifetime and cancellation cleanup; preserve checker/MIR ownership guarantees. A Future/resource container needs its own language decision |
| ADR-0039 lends immutable graphs until workers finish | Cancellation must join every borrower before unpinning/reclaiming. General task migration must not silently reuse CPU-only lending assumptions |
| Trap ends its OS thread | Logical task termination must clean up that task only, retain a healthy worker and abandon invalid state safely; otherwise keep faulting work process-isolated |

## Server acceptance campaign

Extend the existing runtime, std, concurrency and network harnesses; use barriers
and injected event orderings rather than sleeps for race tests. Keep an external
watchdog for hangs. Record seed, task/request counts, channel/buffer/admission
limits, worker count, timeout units, compiler revision, backend and host details.

- Run bounded batches at 1, 64 and 1,024 simulated clients, plus an explicit
  over-limit batch. These are proposed fixtures, not supported-capacity claims.
  Include idle, slow-writing, non-reading and abruptly disconnecting clients,
  plus healthy clients competing with them. Repeated connect/cancel/close cycles
  must return descriptors, tasks, monitors, tokens and heap accounting to baseline.
- Test backpressure at capacity 1 and a larger fixed capacity; enforce total
  queued bytes and pending sends, not just channel element count. A message-size
  bound is necessary because channel capacity alone does not bound memory.
- Give a continuously ready task competition from hot producers. Define and
  test FIFO/round-robin scheduling progress in a bounded number of dispatches
  for cooperative tasks; distinguish it from unprovable OS latency or fairness
  for arbitrary CPU loops. Report latency tails without inventing time guarantees.
- Inject parent/child traps during admission, parse, receive, send and shutdown;
  verify nested cleanup, primary failure reporting and healthy-peer progress.
  Reconcile partial response bytes; cancellation does not undo a response sent.
- Test deadline expiry and cancellation at every waiter registration/removal
  boundary; assert one outcome and no wake after destruction. Repeat with
  contracts on/off, C/LLVM parity, Linux/macOS loopback, ASan/UBSan and TSan
  where supported. Report unsupported sanitizer environments as such.

These are future acceptance requirements, not tests run for this design PR.

## Decision gate: is async/await needed?

Ship the reviewed library/runtime foundations first: cooperative cancellation,
interruptible waits, monotonic deadlines, bounded server admission, cleanup,
and eventually an opt-in scheduler can all precede new source syntax. General
server ownership and recovery still require the ADR gates described above.

Compare the same server/client/cancellation workloads using the improved task
API and a small async/await design prototype. Record suspension safety, resource
lifetime diagnostics, call-chain complexity, stack/continuation memory, latency,
throughput and debugging/tooling costs. Distinguish two findings: OS-thread
blocking can be insufficient at scale, while blocking-style *source syntax*
can still work with a scheduler. The former does not establish the latter.

Recommendation: retain ordinary task calls unless a concrete failure of that
model remains after the scheduler experiment. If explicit suspension coloring
or futures materially solve that failure, propose a new ADR covering function
colors, suspension lowering, resource lifetimes, cancellation, contracts/effects,
formatter/LSP/MCP/OSIG, C/LLVM parity and bootstrap migration. Reserved words do
not authorize implementation. Any decision to prioritize async/await before
this evidence, change join/trap defaults, add automatic cancellation safepoints,
or relax resource ownership is a **proposed policy change requiring owner
review**. This roadmap neither grants it nor announces an API freeze or date.
