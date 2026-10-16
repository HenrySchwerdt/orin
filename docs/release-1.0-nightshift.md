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

## Current queue — 03:30 Europe/Berlin checkpoint

| Track | Owner | Status / next acceptance |
| --- | --- | --- |
| PRs #82–#90 | Coordinator / independent reviewers | All merged; main CI green at this checkpoint |
| JSON completeness RFC #88 | Coordinator | Approved design; implementation remains split into reviewed slices |
| Exact numbers, PR #89 | Implementation chat A / coordinator | Merged, including checked stress-fixture correction; no legacy parser migration |
| Bounded JSON documents | Implementation chat A | Active: opt-in std:jsonvalue parser and compact writer, limits, exact tokens, duplicate/UTF-8 policies; no float conversion or decoders |
| Release readiness | Coordinator | Preserve evidence-based gates and 07:30 checkpoint; no release declaration |

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

## 23:30 coordination checkpoint

- PR #82 (forwarding, including the assertion-order correction) and PR #86 (portable bounded
  execution) are merged. GitHub records their merges at 23:00:50 and 23:30:54 Europe/Berlin,
  respectively, on 2026-10-15. Their earlier checkpoint statuses remain historical observations.
- PR #87's factual correction is approved, pending merge. Its audit keeps the dated source
  baseline and does not treat later integrations as evidence for that earlier tree.
- PR #88 (JSON completeness/compatibility design) is merged. This is a design, not numeric JSON
  implementation or a stable API freeze decision.
- PR #89 (numeric utilities) is under review; correction of its std CI failure has been requested.
- This R4 documentation pass reconciles capability/network status, platform evidence counts and
  published package availability. It does not change runtime code, API stability or proof scope.

## 03:30 coordination checkpoint (2026-10-16)

- PRs #82–#90 are merged and main CI is green, per coordinator confirmation.
- The five-hour usage guard reached 85%; workers checkpointed and stopped.
  The coordinator subsequently verified the usage reset to 0% and authorized resumption.
- A new isolated JSON-document worktree is active from current main. Its narrow
  slice is a bounded opt-in parser and compact writer using std:jsonnumber;
  legacy Json/public/internal parsers, float conversion and decoders stay outside scope.
- Maximum two writers, independent review and coordinator-only merging remain in
  force. Morning checkpoint remains 07:30 Europe/Berlin; incomplete work is reported honestly.

## 07:30 final checkpoint (2026-10-16)

- Night shift stopped; heartbeat orin-1-0-night-shift is PAUSED. Both workers were asked to checkpoint.
- Coordinator merged #82–#90 and #93–#97 after independent review and exact-head green CI.
- Latest observed main e2fb538 (including separately merged Claude #100) has green CI; the
  coordinator-reviewed integration through #97 at 21681d2 also passed.
- Open #91 requires an owner tradeoff decision; #98 is parked; new #101 needs review.
- Final usage observation: five-hour 93%, weekly 45%. No new dispatch. Local Claude auth remains absent.
- Detailed local handoff: build/overnight/morning-report.md; generated state: build/overnight/state.json.
- Stable scope, final candidate artifacts/platform validation and remaining std/proof gaps are
  recorded in the handoff and release-readiness audit. No 1.0 readiness or publication is claimed.
- This final plan checkpoint is local and uncommitted; no post-cutoff implementation or PR was started.
