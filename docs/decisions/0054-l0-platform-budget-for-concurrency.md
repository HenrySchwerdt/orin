# ADR-0054: L0 platform budget for concurrency

Status: accepted (owner default 2026-10-16 per [roadmap](../roadmaps/orin-1.0.md) D7; Henry can still overturn it).
Amends [ADR-0030](0030-provable-std-and-minimal-trusted-runtime.md) section 1 (the 1,000-line L0 budget). Does not change
[ADR-0052](0052-runtime-r3-and-the-c-endpoint.md), which keeps L0 in C.

## Question

L0 (`runtime/platform/`) stands at 999 of 1,000 code lines (`tools/verify_platform.sh`). The concurrency floor of the 1.0
roadmap (D1 = option B) needs OS-level primitives that only L0 may hold: timed waits, interruptible network waits, and
later a second platform backend and a scheduler readiness backend. Without a budget decision, none of them can be built.

## Decision

1. **The ceiling is 1,400 code lines** (non-blank, comments and ACSL contract blocks excluded, counted exactly as
   `tools/verify_platform.sh` and `tools/count_code_lines.py` count today). The budget still limits trusted code, not its
   specification.
2. **Every addition ships with its specification and evidence in the same change:**
   - an ACSL-style contract in `runtime/platform/orin_platform.h` (requires/assigns/ensures, as existing L0 functions have);
   - a CBMC harness in `runtime/platform/tests/` (bounded, like `cbmc_harness.c` and `cbmc_net_harness.c`) for every
     function with data-dependent bounds; for pure OS-call wrappers a harness over the argument checks plus an executable
     contract test in `platform_test.c`;
   - thread/monitor additions also run under the existing TSAN job.
   Code without these does not count as allowed headroom: the check fails the change.
3. **No data structures in L0 and no new escape.** The ADR-0030 "no escape" rules stay: every outside-world function takes a
   capability handle and is callable only from `core = true` modules.
4. **Headroom is reserved, not free.** The 400 lines are allocated to the consumers below; a consumer that needs more than its
   estimate reopens this ADR. Unused headroom is not carried into other work.
5. `tools/verify_platform.sh` enforces 1,400. [tcb.md](../tcb.md), ADR-0030 and spec 19 keep their text; this ADR is the
   current figure, and tcb.md states it.

## Expected consumers

| Consumer | Need | Rough size |
|---|---|---|
| C1 timed monitor wait | monitor wait with an absolute monotonic deadline (`pthread_cond_timedwait` on `CLOCK_MONOTONIC` where available), spurious-wakeup-safe contract | 40-80 |
| C3 interruptible network wait | `poll`-based wait on a socket plus a wake handle, so cancellation and deadlines interrupt accept/connect/read/write | 100-150 |
| C6 Windows backend | thread/monitor/clock/socket counterpart, only if native Windows is a supported platform (D4 default: WSL2 only, so this is likely unused in 1.0) | 150-250 |
| Scheduler readiness backend | epoll/kqueue readiness plus context switch support for the later M:N scheduler behind the same API | 100-200 |

Estimates sum above 400 on purpose; C6 and the scheduler are conditional. If both land, one of them must offset by removal.

## Consequences

- TCB grows by at most 400 code lines, every one under contract and a harness.
- The check in `tools/verify_platform.sh` changes from 1,000 to 1,400; nothing else in the pipeline reads the figure.
- ADR-0052's "~1,000 code lines" row describes the state when written.
