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

## Current queue — 22:30 Europe/Berlin checkpoint

| Track | Owner | Status / next acceptance |
| --- | --- | --- |
| CLI integration, PR #83 | Coordinator | Merged after independent approval and green CI |
| `std:url`, PR #84 | Implementation chat B / coordinator | Merged after independent approval and green CI |
| `std:encoding`, PR #85 | Implementation chat A / coordinator | Merged; URL and encoding registration preserved together |
| Load forwarding, PR #82 | Claude / coordinator review | Assertion-order fix independently approved; main integration `2734d9b` freshly pushed, awaiting exact-head CI; not yet merged |
| Portable execution timeout, PR #86 | Implementation chat A / coordinator | Worker head `48de511` passed CI and independent review; main integration `613b653` approved, fresh CI pending; not yet merged |
| JSON completeness | Design chat / coordinator | Design active: float/exponent support and decoder helpers need a compatibility plan before implementation |
| Release readiness | Audit chat / coordinator | Audit active; [English evidence and gap document](release-1.0-readiness.md) separates release gates from follow-ups |

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

## 22:00 coordination checkpoint

- PR #83 (project CLI) merged after independent follow-up approval and green exact-head CI,
  including the 19 CLI regression cases.
- PR #84 (`std:url`) merged after independent review and green CI. PR #85 (`std:encoding`)
  also passed independent review and CI; integration preserves both modules in loader diagnostics
  and requires fresh CI after the merge with main.
- Two implementation chats are active: portable bounded MCP/CLI execution, and the PR #82
  C/LLVM assertion-order regression where an IForward destination aliases its index local.
- Five-hour usage reset was confirmed (1% at this checkpoint). Claude CLI remains unauthenticated;
  existing Claude PR #82 is being fixed in place without duplicate implementation or auth retries.

## 22:30 coordination checkpoint

- CLI #83, URL #84 and encoding #85 are merged. Completion here means mainline source;
  it does not mean the older published alpha packages contain these features.
- PR #82's C/LLVM assertion-order correction is independently approved. Integration head
  `2734d9b` includes main and is awaiting fresh CI. Eight runtime regression cases pass.
- PR #86 worker head `48de511` has green CI and independent approval. Main integration
  `613b653` is independently approved and awaits fresh CI. Both PRs remain open at this checkpoint.
- The coordinator reports that the integration bootstrap passed the stage2/stage3 fixed point.
  That is reproducibility evidence; exact integration-head CI and final merge review still apply.
- JSON compatibility design and the release-readiness audit are active. The coordinator's
  checkout is now on main. `build/overnight/state.json` remains the generated local coordination
  source; this documentation update does not modify it.
