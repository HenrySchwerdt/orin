# Orin 1.0 night shift — 2026-10-15 / 16

Owner: the coordinating Codex chat. The user authorized implementation chats, reviews, CI fixes,
and merging verified pull requests overnight. Morning checkpoint: 2026-10-16 07:30 Europe/Berlin.
This is a bounded work plan, not a promise to declare 1.0 complete overnight.
Library selection and acceptance follow [agent-stdlib-priorities.md](agent-stdlib-priorities.md):
precise errors, deterministic behavior, pure validation, explicit I/O, limits, and executable evidence.

## Operating rules

- At most two implementation chats concurrently, each in its own managed Git worktree.
- The coordinator owns integration and merges; workers submit PRs and do not merge.
- Preserve the language freeze, capability boundaries, value semantics, and verifier checks.
- New std APIs need documentation of errors, complexity, allocation, and meaningful tests.
- Validate C and LLVM behavior, bootstrap reproducibility when compiler glue changes, and relevant
  sanitizer/contract checks. Review exact PR heads; green CI is necessary but not sufficient.
- Do not create releases, change billing/authentication, bypass usage limits, or weaken checks.
- Respect existing Claude-owned performance branches; integrate their PRs rather than duplicate them.
- Check account usage before dispatch. At 75% of a five-hour window, stop dispatching; at 85%, ask
  workers to checkpoint and stop. Resume after the reset. No busy polling or automatic retry storms.
- The local Claude CLI currently reports loggedIn=false. Do not seek credentials or repeatedly call
  unauthenticated Claude. Continue consuming completed Claude PRs; use Codex sparingly as fallback.

## Current queue

| Track | Owner | Scope / acceptance |
| --- | --- | --- |
| CLI integration | Coordinator | Merge latest main, fix independent review findings, submit CLI PR, review CI and merge only after checks |
| Load forwarding, PR #82 | Claude / coordinator review | Review F1 soundness and mutant evidence; merge only after exact-head CI completes |
| `std:encoding` | Implementation chat A | Hex, Base64 and Base64URL over Bytes; strict decoding and structured errors; vectors, round trips, malformed input, linear-time benchmark |
| `std:url` | Implementation chat B | Percent encoding/decoding and query parsing/serialization; explicit UTF-8 and plus behavior; duplicate order preserved; vectors, malformed input, round trips and benchmark |
| Portable execution timeout | Next available worker | Reproduce the macOS MCP timeout failure, implement a tested bounded execution path without silently disabling deadlines |
| JSON completeness | Next std ticket | Design float/exponent JSON support with a compatibility plan before implementation |
| Release readiness | Coordinator | Reconcile actual shipped features with docs; prepare a 1.0 gap list with evidence and remaining decisions |

## Coordination state

Local worker IDs, worktree paths, heartbeat ID, and review notes are kept in
`build/overnight/state.json` (generated local state, not committed). The heartbeat reads that file
and this plan, fetches fresh PR state, and waits for meaningful changes rather than repeating work.
Workers own their module and tests; minimal resolver/MCP/embedding glue may overlap and is resolved
by the coordinator. No worker should edit another module or revert another contributor's work.

## Morning report

Report merged PRs and their validation, open PRs, measured performance with limits, blocked work,
usage-related pauses, and the remaining 1.0 gaps. Stop new dispatches at the checkpoint, save state,
and disable the night-shift heartbeat. Do not claim feature completeness or proof beyond evidence.
