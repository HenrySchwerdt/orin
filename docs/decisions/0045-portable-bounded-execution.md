# ADR-0045: portable bounded shell execution

Date: 2026-10-15. Status: proposed with implementation.

The compiler's MCP program runner requires GNU `timeout`; the CLI @Test runner
silently runs without a deadline when it is unavailable. Neither is suitable on
macOS. Preserve shell quoting, process grants and explicit `--timeout 0`, and
replace both bounded paths with one additive runtime primitive.

`std:io.shellTimeout(proc: ProcessGrant, cmd: string, seconds: int): int` runs
`/bin/sh -c cmd` with a strictly positive duration. It returns an ordinary exit
status 0..255, -2 for deadline expiration, and -1 for invalid duration, spawn,
signal termination or an OS error. Exit 124 is an ordinary exit, not a timeout.
The existing `shell` API and its unlimited semantics do not change.

L0 uses POSIX `posix_spawn` with a new process group, `CLOCK_MONOTONIC`, `waitid`
with WNOWAIT, a 10 ms polling sleep, SIGKILL for group cleanup, and `waitpid` to
reap the direct child. Keeping the leader unreaped until cleanup prevents its PID
being reused before group signaling. Cleanup also runs on normal shell exit and signals
background children that remain in the group. The process-grant
spawn/narrowing and denial checks run before L0. No new language syntax or change
to capability/verifier rules; the added builtin follows the existing shell path.

Limits: this is a POSIX execution deadline, not a sandbox or hard real-time
scheduler. Descendants that deliberately escape the process group are outside
cleanup. Orphan descendants are reaped by the OS, not by this caller. It cannot
recover from parent SIGKILL or bound OS scheduling/spawn/reaping latency; a child
stuck in an uninterruptible kernel call may delay cleanup. Capture/output budgets
and compiler/linker deadlines are separate work. No external `timeout`, Python,
or GNU utility is required by the native deadline path.

SIGCHLD must retain its default disposition without SA_NOCLDWAIT; unsupported
settings fail before spawning. No outside code may reap this call's direct child
or change SIGCHLD during the call. An unexpected ECHILD returns an OS error
without signaling a potentially reused PID.

## Seed transition

The old seed cannot import a builtin it predates. First commit support for the
new builtin and runtime, with compiler consumers unchanged. Bootstrap and refresh
the seed from that support commit (`tools/update_seed.sh`), preserving the full
old-seed log. Then commit the bounded compiler consumers and bootstrap again.
No intermediate implementation silently substitutes unlimited execution.

## Validation and current limits

Locally validated on Apple M4 arm64 / macOS with clang: native success/nonzero,
ordinary exit 124, signal termination, invalid durations, large duration,
monotonic hang deadlines, SIGTERM-ignoring/background children, EINTR, SIGCHLD
rejection and direct-child reaping. Plain and ASan/UBSan fixtures capture pipes,
so a surviving descendant retaining a descriptor prevents successful completion.
C/LLVM runtime status and process denial, wrong grant family, contract purity,
effect classification, CLI quoted paths/explicit unlimited mode, and MCP success,
expected nonzero and 10-second hang cases are covered in `tools/test_execution.py`.
CLI/MCP tests put failing `timeout`/`gtimeout` commands first on PATH, proving they
are not consulted. The focused checks are wired into Linux tooling CI and macOS CI.

Both old-seed support bootstrap and final-consumer bootstrap reached a fixed point
and passed all 141 default conformance tests. The broad MCP suite passed 191 checks;
annotation tests passed 44 checks without a timeout-utility skip. Existing runtime
ASan/UBSan, platform plain/ASan/UBSan/TSan and C/LLVM capability suites also passed.
The platform remains within its 1,000-line budget (980 code lines).

Linux execution is left to CI; no local Linux results are claimed. CBMC was not
installed locally, so its existing checks were skipped explicitly; no process
model proof or whole-descendant reaping proof is claimed. Sanitizer process tests
use leak detection disabled. This evidence is testing plus bootstrap consistency,
not a proof of termination or security containment.
