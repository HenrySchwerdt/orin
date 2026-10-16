# Local macOS package rehearsal — 2026-10-16

This is **partial R5 evidence**, not release approval. The tested implementation is
`8587609f6619f21ee8c5d2328179b9abd6a279f6`, the latest fetched main when this rehearsal began
(newer than the dispatch reference `f565bbf`). Later documentation commits do not change the tested
implementation SHA. No tag, GitHub release, workflow dispatch, upload or installed user tool was changed.

## Build and platform

- Host: macOS 26.2, arm64 (`Darwin 25.2.0`); package target `macos-arm64` only.
- Native toolchain: Apple clang 17.0.0 (`clang-1700.6.4.2`); system Bash 3.2.57.
- Local package version: `0.0.0-dryrun.8587609`; generated with the existing
  [package script](../tools/package.sh). This version is not published.
- Built the committed seed with `tools/bootstrap.sh --seed-only`, then compiled the current
  compiler through stage 1, stage 2 and stage 3. Stage 2/3 generated C matched exactly. The broad
  compiler conformance suite was deliberately **not** rerun. A fixed point is reproducibility,
  not a correctness proof.

The build followed the stage commands in [bootstrap.sh](../tools/bootstrap.sh), stopping before
its conformance step:

```sh
tools/bootstrap.sh --seed-only
build/bootstrap/orin0 compile compiler/main.or -o build/bootstrap/stage1.c
cc -O1 -w -I runtime build/bootstrap/stage1.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/bootstrap/orin1
build/bootstrap/orin1 compile compiler/main.or -o build/bootstrap/stage2.c
cc -O2 -w -I runtime build/bootstrap/stage2.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/bootstrap/orin2
build/bootstrap/orin2 compile compiler/main.or -o build/bootstrap/stage3.c
cmp build/bootstrap/stage2.c build/bootstrap/stage3.c
tools/package.sh 0.0.0-dryrun.8587609 macos-arm64
(cd build/dist && shasum -a 256 -c orin-0.0.0-dryrun.8587609-macos-arm64.tar.gz.sha256)
```

Observed SHA-256 values for this local build:

| Artifact | SHA-256 |
|---|---|
| Tarball | `bd2337bc5e5fb6ee3bf3a7becfdbab8a8ed62fd8a26349072032add7546ab590` |
| Packaged compiler / `build/bootstrap/orin2` | `9e74efd0cfbd05b51e35fbea056d8bdd464f0cab83fe7a157fa9211b1c235f0e` |
| Stage 2 and stage 3 C | `2c2a9ea222c178be549c0b342a5c5dccbfc7e387d4853672fa2f53ab38437af1` |

These identify the tested files. They are not a claim that tar/gzip output, native binaries or
separately rebuilt archives are bit-reproducible.

## Isolation and observed results

The [installer checks](../tools/test_install.sh) use temporary installation roots. An additional
installation used only `build/package-dryrun/{home,installed,bin,tmp}` inside the isolated worktree.
Every environment override was per child process (`env -i ... HOME=...`), never a global HOME/PATH
change. The CLI-test child used its isolated bin plus `/usr/bin:/bin:/usr/sbin:/sbin`, with Git
system configuration disabled and prompting disabled. No shell profile or user installation was edited.

The installed compiler, Bash helper, runtime C/headers, platform C/headers and HTTP example were
checked against the built package inputs by SHA-256. Runtime/platform/compiler files were copies,
not symlinks into the source checkout; only the installer's normal launch/current symlinks remained.

| Check | Result |
|---|---|
| Existing package smoke checks | Hello program ran; shipped `examples/testing.or` passed 2 tests using package runtime assets. |
| `tools/test_install.sh <tarball>` | **19 checks passed**: sidecar and combined checksums, tamper/missing-checksum refusal, symlink launch, `doctor`, reinstall, foreign-directory refusal, missing compiler/layout diagnostics, PATH guidance and idempotent uninstall. |
| Additional clean installation | Local sidecar checksum verified; correct version; `doctor` reported `All good.`; help and `help init` worked. |
| Existing release CLI journeys against that installation | **19/19 passed**, including app/library init, builds/cache, library test discovery, path/local-Git dependencies and lock rollback/offline behavior, diagnostics/JSON, HTTP template, release LLVM build and watch restart/cleanup. |
| Additional app/library/dependency journey | Initialized app and library; library check/test passed; app imported library greeting; locked offline fetch/tree inspection, C build/run/test and release LLVM build passed. App stdout was exactly `Hello from Orin!` plus newline. |
| Additional HTTP journey | Initialized from the installed HTTP example and checked identical bytes; check/build/test passed. `orin run -- 0 1 2000` bound an ephemeral loopback port, served one `/health` request with HTTP/1.1 200 and the three-byte body `ok\n`, then exited 0. |
| Stdin/stdout | A packaged build using `std:io.readLine` read `hello package\n` and emitted exactly `echo:hello package\n`. |
| Terminal diagnostics | Unresolved `missing()` returned exit 1 with E0300/source/caret; redirected plain output had no ESC. Forced color emitted ANSI sequences; JSON diagnostics parsed and had no ANSI. Text was captured; no GUI, WezTerm scripting or screenshot access was used. |
| Final uninstall | Additional install root and launch symlink removed; second uninstall succeeded as a no-op. |

For the CLI journeys, the source suite's synthetic setup was replaced by a small subclass whose
`setUpClass` allocated only a temporary project directory and selected the installed `bin/orin`.
Test bodies were unchanged. The default [CLI suite setup](../tools/test_cli.py) instead synthesizes
an install with source symlinks; running it unmodified would not establish packaged-asset coverage.
The local harness is retained with the evidence below. Its initial HTTP expectation omitted the
example's trailing newline; that harness assertion was corrected to the actual three-byte body,
and the remaining HTTP/terminal checks passed without changing product code or repeating the 19 CLI tests.

## Retained local artifacts and limits

Paths are relative to the isolated `orin-package-dryrun/orin` checkout; they are ignored build
outputs, **not published assets**:

- `build/dist/orin-0.0.0-dryrun.8587609-macos-arm64.tar.gz` and its `.sha256` sidecar.
- `build/dist/orin-0.0.0-dryrun.8587609-macos-arm64/`: package staging layout retained for inspection.
- `build/package-dryrun/summary.json`: implementation SHA, hashes, isolated environment paths and uninstall status.
- `build/package-dryrun/package.log`, `install-tests.log`, `isolated-install.log`, `cli-tests.log`, `uninstall.log`.
- `build/package-dryrun/commands.json`, `http-response.txt`, `http-server.log`, `terminal-demo.txt`.
- `build/package-dryrun/run.py`, `continue.py`, `journeys.log`, `remaining-journeys.log`: local harness and execution records.

The additional installed copy was intentionally removed. Source build/harness prerequisites included
Python 3, a C compiler, Git, gzip/tar and checksum tooling. Runtime journeys used the packaged compiler,
Bash helper and copied runtime/platform; Git was used for dependency tests and clang for LLVM builds.
This does not establish operation without those prerequisites or certify a clean OS image.

No packaging defect required a code change in the exercised journeys. Linux, Intel macOS, signing,
notarization, downloaded public artifacts, hostile archives and a complete security audit were not
covered. This local rehearsal does not replace exact-candidate CI, other supported-platform checks,
API freeze decisions or the remaining [R5 release gates](release-1.0-readiness.md).
