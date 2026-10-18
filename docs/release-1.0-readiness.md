# Orin 1.0 release-readiness audit

Read-only audit, 2026-10-15. Source baseline: **`dddfd54c495221f58a97b1a0d261aa206247fca0`**
(main after PRs [#83](https://github.com/orin-lang/orin-lang/pull/83),
[#84](https://github.com/orin-lang/orin-lang/pull/84) and
[#85](https://github.com/orin-lang/orin-lang/pull/85)). This is a dated gap assessment, not a release
approval or a new language decision. No broad suites were rerun for this audit. Links to repository
files describe that baseline; inspect it with `git show <baseline>:<path>` when main has moved. PR status also incorporates the coordinator's 22:30 Europe/Berlin checkpoint,
with both integration heads confirmed open through GitHub.

**Assessment: do not declare 1.0 ready from the evidence below.** The language freeze, a bootstrap
fixed point, a green earlier commit and an approved design each answer different questions. Close
the release gates on an exact candidate, or explicitly narrow its scope, before claiming stability.
“P0” here means a release gate; the P0 proof-debt labels in the assurance ledger and Priority 0
library roadmap are separate rankings, not an assertion that all that work must precede 1.0.

## Evidence available at the audit snapshot

| Evidence | What it establishes and what it does not |
|---|---|
| [CI run 38802558215](https://github.com/orin-lang/orin-lang/actions/runs/38802558215) on `dddfd54` | In progress when inspected. No completed green result for this baseline was observed. |
| [CI run 38798869812](https://github.com/orin-lang/orin-lang/actions/runs/38798869812) on `89d84d2` | Completed successfully. This predates the encoding merge; it does not certify the later tree. |
| Merged CLI, URL and encoding PRs above | Source implementations, tests and review evidence exist. Their inclusion in main does not put them into an older downloaded release. |
| [PR #82](https://github.com/orin-lang/orin-lang/pull/82), integration head `2734d9ba41c9f4556e5fc2d1b3aee3a996d2376f` | Open. Coordinator reports independent approval of the assertion fix (`9df7ebc`) and eight passing runtime cases; main integration freshly pushed, awaiting CI. Not part of this baseline. |
| [PR #86](https://github.com/orin-lang/orin-lang/pull/86), integration head `613b653cf3c4c41f5475404093f5f48ce96e94b5` | Open. Coordinator reports green CI and independent approval for worker head `48de511`, approval of the main integration, and fresh integration CI pending. Not fixed in this baseline. |
| [Latest published alpha, v0.1.0-alpha.2](https://github.com/orin-lang/orin-lang/releases/tag/v0.1.0-alpha.2) | Assets inspected: Linux x86-64 tarball, macOS arm64 tarball, `SHA256SUMS`. No Linux arm64 or Intel macOS asset was present. This is a pre-release, not a 1.0 artifact. |

Statuses above are historical observations. A release reviewer must inspect current exact heads;
an open PR or in-progress run is not a failed check, and an earlier success does not transfer to a merge.

## P0 release gates and reproducible acceptance

| Gate | Concrete gap at baseline | Acceptance on the release candidate |
|---|---|---|
| R1 — portable bounded execution | [MCP `testEntry`](../compiler/mcp/tools.or) shells out to `timeout 10`; [unit-test runner](../compiler/testing/runner.or) runs without a deadline if `timeout` is absent. A prior macOS run of `tools/protocol.sh mcp` passed 190/191 checks, failing with `timeout: command not found`. PR #86 addresses this. | Review and integrate a bounded implementation, then run `tools/protocol.sh mcp --orin build/bootstrap/orin2` and the portable-execution regression tests on macOS and Linux without GNU `timeout` on PATH. A hanging child must terminate within the specified bound; normal stdout/stderr and exit status must survive; missing deadline support must not silently run unbounded. |
| R2 — sound diagnostics for any included forwarding pass | Conditional on including PR #82. Its initial emitters overwrote the destination before evaluating fact-check operands. Valid MIR with `k = forward s, o[k]` falsely exited 70 when `k` changed. The correction is on the cited PR head, outside this baseline. | Independently review the integrated head. Run `python3 tools/test_forward_assert.py --orinc build/bootstrap/orin2`: both index directions must pass on C/LLVM, facts on/off, and the fixture must pass the independent verifier. Run `orin2 test compiler/tests/emit_test.or` and conformance with `--assert-facts` on both backends. Preserve rejection of unjustified forwards. Excluding the optional pass avoids making it a prerequisite. |
| R3 — explicit stable scope | [ADR-0016](decisions/0016-language-1.0-core-scope.md) separates language and I/O freezes. [std:fs](../library/std/fs.or), `std:time`, `std:net` and stage-0 tasks still advertise instability; [progress](progress.md) records an outstanding I/O freeze decision and remaining checker rewrite work. ADR-0016's core-complete definition includes the rewrite. | Record the owner's stable API/support boundary and reconcile it with ADR-0016: finish required items or explicitly revise/defer them. List every retained experimental API and compatibility exception. Do not infer a freeze from implemented grants or remove unstable labels without that decision. |
| R4 — accurate release claims | [README](../README.md) still groups enforced capabilities with planned features although grants and Stage B effects exist. [known limitations](known-limitations.md) calls network grants reserved; [TCB](tcb.md) says there is no network std API and repeats platform rows with different historical counts. [Install docs](install.md) say every release has four targets, unlike the published assets above. | Reconcile README, std overview, limitations, progress, TCB and install/support docs against exported APIs, tests and candidate artifacts. Distinguish implemented grants/effects from unimplemented lineage, approved designs from shipped features, and model proofs from implementation assurance. Replace historical counts with dated evidence or reproducible counts. Review links and run examples from the chosen package. |
| R5 — candidate and artifact evidence | Current main CI was incomplete at inspection. [Release workflow](../.github/workflows/release.yml) builds four targets and always publishes with `--prerelease`; normal PR CI covers a smaller platform matrix. No stable 1.0 package was inspected. | Require completed required checks for the exact integrated SHA. Perform an authorized **dry run**, with packages from that SHA, for each platform claimed as supported; verify checksums, clean install, `doctor`, CLI project/dependency journeys and uninstall. Resolve stable release metadata before any later publication. This audit does not authorize triggering or publishing a release. |

R1 is a reproduced user-facing defect; R2 protects an optional incoming feature. R3–R5 require
release-scope decisions and evidence, rather than assuming every planned feature is mandatory.

## Standard library: shipped surface and remaining work

The practical source map is [std overview](std.md), [loader registration](../compiler/loader/resolve.or),
[MCP API table](../compiler/mcp/apitable.or), and the exported module sources. The module table in
[spec 08](../spec/08-standard-library.md) is explicitly proposed; built-in arrays, strings and
`Map<K,V>` do not require imports with those proposed names.

| Area | Available at baseline | Gap and a concrete follow-up acceptance |
|---|---|---|
| Bytes, text, encoding, URL | `Bytes`, UTF-8 validation, collections, layout helpers, strict hex/Base64/Base64URL, percent components and ordered query pairs. See [encoding](std-encoding.md), [URL](std-url.md), and their `tests/std/` files. | Preserve error offsets, canonical decoding rules and duplicate order. Re-run known vectors and round trips on the final candidate, C/LLVM and contracts on/off. No full browser URL parser or streaming codec is implied. |
| JSON/configuration | [Json](../library/std/json.or) has `JNum(int)`, ordered object fields and accessors; fractional/exponent numbers are rejected, depth is capped at 200. [Number](../tests/next/run/std_json_numbers.or) and [duplicate/depth](../tests/next/run/std_json_depth_and_duplicates.or) tests document the boundary. | Design numeric compatibility before changing `JNum`; retain exact integers and specify range/non-finite/duplicate policy. Field-path decoder errors should be tested with missing, wrong-type and out-of-range fields. Typed `parse<T>` is not shipped. |
| Process execution | Built-in `std:process` has `args`/`exit`; `shell` is exported by `std:io` and takes a process grant supplied by [host](../library/std/host.or). | Fix R1 independently of a public argv-based subprocess API. A future API needs captured streams, bounded output, explicit stdin, status/signal and monotonic deadlines, tested against hangs and quoting-sensitive arguments. |
| Files and clocks | [fs](../library/std/fs.or) offers whole-file/streaming access and grant narrowing. [time](../library/std/time.or) supplies durations and UTC calendar helpers; the public clock is wall time. | Public directory metadata/iteration, rename, temporary/atomic writes, monotonic deadlines and sleep are not a general std surface here. Specify overwrite, symlink, ordering, durability and deadline behavior, then test failure paths and clock jumps. The network layer's clock helper is not a general clock API. |
| Web integrations | [http](../library/std/http.or) parses/serializes bounded HTTP/1.1 messages; [net](../library/std/net.or) offers blocking TCP with grants/timeouts. | No integrated HTTPS client/TLS certificate validation. OS DNS resolution is outside the TCP connect timeout bound ([platform contract](../runtime/platform/orin_platform.h)). A future client needs total deadlines, response limits, redirect/connection policy and invalid-certificate tests. |
| Application conveniences | Assertions, package CLI and std diagnostics are available. | No general public CLI-option schema/parser, structured logger, decimal module, CSV/TOML parser, OS-random/UUID module or database driver is registered. Follow [agent std priorities](agent-stdlib-priorities.md); accept each through a useful example, deterministic errors/laws and measured cost. The package manifest parser does not establish general TOML support. |

These follow-ups improve application coverage; their absence alone is not an agreed 1.0 blocker.
Benchmarks are workload evidence, not proof of asymptotic behavior, peak-memory bounds or portability.

## Compiler/runtime and assurance boundaries

- `i128`/`u128` remain E0431; integer bitwise/shift operators are deferred by ADR-0016.
  Narrow integer arrays still use 8-byte slots. Strings hold bytes; text validity is explicit.
- Generic methods on classes are implemented ([ADR-0040](decisions/0040-generic-methods-and-void-type-arguments.md)); an interface
  method may not be generic ([E0460](../tests/next/errors/e0460_interface_generic_method.or)). Generic interfaces,
  inheritance, default/rest arguments and registry publishing are not promised by this baseline.
- [Concurrency](concurrency.md) is stage 0: OS-thread tasks, explicit channel closure, no M:N scheduler,
  general cancellation/select or deadlock detection. Traps do not unwind task heaps; expression early
  exits may leak temporaries. Do not claim leak freedom or that a hung task is automatically cancelled.
- Grants/effects are implemented checks, not an OS sandbox. [Capability limits](capabilities.md) include
  ambient output, native/spawned code and file-authorization race boundaries. Lineage and signed
  `.orcert` attestations remain roadmap work.
- [Assurance ledger](assurance.md), [formal scope](formal.md) and [TCB](tcb.md) distinguish `MODEL_ONLY`
  memory/COW/checker theorems from tested implementation behavior. Source type soundness, lowering,
  optimizations, code generation, runtime refinement and full MIR shape safety are not end-to-end proved.
  Differential agreement does not bind the implementation to Lean; runtime shape checks are a backstop.
- [Contract verification](contracts.md#semantics-honest-limits) is partial correctness under listed
  assumptions. Unsupported constructs/abstraction can be UNKNOWN; Z3 and the VC generator remain
  trusted, without checked solver certificates. `@Decreases` is type-checked, not a termination proof.
  Completing every proof-debt item is a separate goal; accurately stating these limits is R4.

## Installation, tooling, platform and CI coverage

[Install](install.md) requires Bash 3.2+ for the release CLI and a C compiler for normal build/run/test;
Git is needed for Git dependencies, clang for LLVM and Z3 for SMT verification. The package is not
self-sufficient without these tools. Linux release builds target glibc; musl needs the documented
compatibility layer or source build. macOS packages are not notarized. Native Windows is not shipped;
[WSL2 instructions](windows.md) are a usage path, not evidence of a native Windows CI job.

| Configured evidence | Coverage and remaining limitation |
|---|---|
| [Main CI](../.github/workflows/ci.yml): Linux C/LLVM, sanitizer and differential jobs | All conformance suites, opt/builtins/fusion comparisons, runtime ASan/UBSan, contract dogfooding/erasure, ownership mutation, platform boundary/CBMC and concurrency stress/TSan. This is configured coverage, not a claim that the latest run completed. |
| Tooling, CLI and std jobs | LSP/MCP/OSIG/effects, formatter, CLI journeys, packages, installer, and std `@Test` with contracts on/off. `tools/test_std.sh` uses the C test runner; this is not an all-stdlib LLVM matrix. URL's separate `bench/url/check.py` runs its assertions through both backends. |
| Formal job | Pinned Lean toolchain, build, escape-hatch/axiom audit, and differential checker tests for the supported fragment. Does not cover every MIR feature or verify the C runtime. |
| [Change selector](../tools/ci_changes.py) | Docs-only PRs skip compiler/test jobs; main/scheduled/manual runs select everything. Mutation modules enumerate bytes/UTF-8/collections/HTTP/net/text/HTML/taskcore, not the new encoding/URL modules. Their vectors/laws exist; new mutation coverage remains follow-up work. |
| macOS CI versus release targets | Regular macOS job is arm64 with bootstrap, conformance, CLI, networking/platform and installation checks. Release workflow additionally targets Linux arm64 and Intel macOS; do not describe those as the same full assurance matrix. No native Windows job is configured. |

## Release reviewer handoff

1. Select and record the candidate SHA and API/platform scope. Resolve R1 and any included R2 work,
   then obtain independent review of the exact integrated changes.
2. Reconcile R3/R4 documents and inspect that SHA's CI job conclusions, including expected skips.
   Record commands, failures, sanitizer exclusions and platform details instead of inheriting counts.
3. Close R5 with candidate artifacts and clean-machine journeys. Keep publication a separate owner
   action; no tag, release, workflow dispatch or compatibility policy was changed by this audit.

Validation of this document is limited to source/workflow inspection, the linked GitHub observations,
relative-link checks and `git diff --check`. It is not fresh test, security, proof or release certification.
