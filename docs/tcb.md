# Trusted computing base (TCB) inventory

_Updated: 2026-10-15 · ADR-0020 (vision phase 0). Update this file whenever a component moves in
or out of trust._

Which claim rests on which evidence, and at which assurance level, is in
[assurance.md](assurance.md).

A guarantee Orin reports ("memory safe", "VERIFIED") holds only if every component it rests on is
correct. This table lists those components, how much each is trusted, and what evidence exists
today. "Trusted" means a bug there can silently break a guarantee.

## Memory safety of a compiled program

| Component | Trust | Evidence today | Gap |
|---|---|---|---|
| Lexer, parser | trusted for meaning (what was written) | conformance suites (the Stage 0 vs Stage 1 parser differential was retired with Stage 0) | no formal grammar proof |
| Type checker, HIR | trusted for type safety | ~420 conformance programs, error suite, fmt/LSP corpus | not verified |
| HIR → MIR lowering, optimiser (owned params, moves, prune) | **not trusted for ownership**: output is re-checked | independent MIR ownership verifier on every compile (ICE exit 70) | lowering bugs can still change *behaviour* (not safety) |
| MIR ownership verifier (`compiler/verify`; the in-place string instructions `IStrAppend`, `IStrPrepend`, `IStrAppendNum`, `IStrAppendSub` all require an Owned destination and share one rule, docs/mir.md v2.5) | trusted | Lean: soundness of the checker *transcription* for the structured MIR core (`formal/`, `check_sound`); targeted regression cases | the Orin implementation is not proved equal to the Lean transcription; MIR features outside the core (closures, vtables, floats) are checked by rules not yet in the model; rule F1 (load forwarding, MIR v2.4, `compiler/verify/forward.or`, 172 code lines plus 20 in `rules.or` / `wf.or`) is a block-local backward scan; the facts it relies on are proved in the Lean model (`formal/Orin/Forward.lean`: `load_load`, `store_load`, the store and `makeUnique` frame lemmas), the scan itself is not; it protects behaviour, not memory safety, and `orin2 compile --assert-facts` re-checks every forwarded load at run time; rule U1 (unchecked array access, MIR v2.6, `compiler/verify/unchecked.or`, 121 code lines plus about 25 in `rules.or` / `wf.or` / `verify.or`; the scan helpers it shares with F1 are in `scan.or`, 53 lines) protects **memory safety**: it is the only fact the verifier hands to the emitters for an access without the kind and bounds check. It has two fact sources: **dominated-by-check** (T2, a block-local backward scan) and **interval** (T6, `compiler/verify/range.or`, 811 code lines: a whole-function interval analysis with branch refinement, widening and one narrowing round, which accepts an access when the index is below the length of an array built by `arraynew` in the function; parameters and call results have no shape fact; docs/mir.md "Range facts", rules R1-R5). The verifier (`compiler/verify`) was 2476 code lines on main before ADR-0038 lever 2, 2591 with T2 and is 3461 with T6 (`tools/count_code_lines.py compiler/verify/*.or`): T6 adds 870, of which 811 are the new analysis. Array length is outside the Lean model, so U1 has no lemma and neither the scan nor the interval analysis is claimed as proved; U1 rests on the code, on the ownership argument behind borrows (a live local holds a reference, so no callee shrinks its object in place; an in/out receiver may not alias another argument) and on the mutation corpus (`bce-*` and `range-*` classes, positive controls included; the interval rules are in addition checked by about 110 cases in `compiler/tests/verify_main.or`); the optimiser pass `compiler/opt/bounds.or` only asks the same code and is not trusted; `--assert-facts` re-runs the omitted checks (`orin_assert_array`, exit 70) |
| Lean model (`run_safe`, `makeUnique_store_cow`) | trusted (Lean kernel) | machine-checked | models the RC machine, not the C runtime code |
| C backend (`cemit`), LLVM backend | trusted | backend differential tests (C vs LLVM vs builtins vs opt), LLVM fixed-point self-build | no translation validation; `ISetField` / `IArraySet` of a scalar operand store without the `is_ref` / `refmask` release test (the slot's kind is assumed to match the operand's static type; a violation leaks, never a use-after-free; ADR-0038 lever 2 T3); **memory safety of an unchecked array access rests on a verified fact** (ADR-0038 lever 2 T2): the C helpers `orin_array_at_u` / `orin_array_slot_ptr_u` (via `orin_mir_array_put_u`, `orin_mir_array_replace_u`) and the LLVM `inbounds` GEP of `IArrayGetU` / `IArraySetU` read and write `items[i]` with no kind check and no bounds check, trusting that rule U1 accepted the instruction. These are the only places where an emitter relies on a verified fact for memory safety; everything else an emitter does is either checked at run time or, like T3, fails only by leaking |
| Runtime object model (`runtime/core/orin_runtime.c`: RC, COW, arrays, strings; string appends `orin_str_append`, `orin_str_prepend` and, since MIR v2.5, `orin_str_append_int` / `_usize` / `_sub`: in place only for `rc == 1`; per-thread free lists for small objects, string objects and array buffers of at most 256 bytes: the block size is recomputed from `cap` at every free, so a wrong `cap` would corrupt a list) | trusted | ASan/UBSan runs of all suites, `ORIN_STATS` counters | not verified; R3 moves it into Orin, R4 refinement proof |
| L0 platform layer (`runtime/platform/`) | trusted, deliberately small (≤1000 code lines, comments/contract blocks/blank lines excluded, ADR-0030) | ACSL-style contracts; executable contract tests in `runtime/platform/tests/platform_test.c` (paths, policy, threads/monitors and network handle/scope behavior); bounded CBMC harnesses in `runtime/platform/tests/cbmc_harness.c` (memory, formatting, policy/path) and `runtime/platform/tests/cbmc_net_harness.c` (socket bounds/refusal checks); boundary checker | bounded, not full Frama-C proof; float text conversion and clock are thin libc wrappers without harnesses; threads/monitors are tested, not model-checked |
| Task runtime, temporary C (ADR-0017 stage 0; `runtime/core/orin_runtime.c` "tasks and transfer": `orin_rt_transfer_*`, `orin_rt_task_*`, `orin_rt_heap_exit`, per-task heap state, grant delegation) | trusted for **task isolation**: if `orin_rt_transfer_put` moved a graph that another reference still reaches, non-atomic reference counts would race | ThreadSanitizer, ASan + UBSan and stress runs (`tools/test_concurrency.sh`), `runtime/core/tests/task_test.c`, conformance programs in every backend mode; the MIR verifier's ownership rules for the consumed local | not verified; 342 code lines that R3 replaces with Orin core code (porting table: ADR-0017 Addendum A, docs/concurrency.md), refinement proof in R4 |
| L0 threads and monitors (`runtime/platform/orin_platform.c`, ADR-0017) | trusted; **stays C after R3** | contracts in the header, 54 tests incl. mutual exclusion, condition queues, a thread dying with a lock held, concurrent stdout; ThreadSanitizer; handle validation (generation, liveness, lock ownership) on every call | no model checking (CBMC cannot model threads); no proof of freedom from lock-order deadlock (std:task takes one monitor at a time) |
| Capability grants (ADR-0027): grant table and authorisation in `runtime/core/orin_runtime.c` (`orin_cap_*`, `fs_check`), `std:host` / `std:fs` scope functions, the checker rules for resource handles | trusted for **authority**, not for memory safety | checker + independent MIR verifier rules (C14/C15), runtime handle validation (traps), runtime and platform tests, CBMC for the pure path logic | a grant is only as strong as the C runtime that checks it; no proof that every privileged operation goes through a check (an audit of `orin_platform_*` callers is the evidence: the platform boundary check keeps the list closed); races and hard links are out of scope; native code can bypass |
| C compiler, linker, libc, libm, OS kernel | trusted (external) | — | outside Orin's control; reproducible builds limit exposure |

Platform test totals and code-line counts change with the source. `tools/verify_platform.sh` prints
both for the checked revision and enforces the size budget; `REQUIRE_CBMC=1` makes missing CBMC a
failure rather than a skipped bounded check. Record its revision/output when citing counts instead
of combining historical totals. This inventory update does not report a fresh platform test run.

## The compiler binary itself (bootstrap)

| Component | Trust | Evidence |
|---|---|---|
| Seed C (`bootstrap/seed/orin-seed.c.gz`) | trusted; single root | the seed from source commit `ec1ba3e` was cross-checked by the diverse double root (Rust Stage 0 root and seed root gave a byte-identical `stage2.c`; reproducible from branch `archive/stage0-final`, docs/bootstrap.md). Later seeds are not cross-checked by an independent root: they rest on that clean starting point, the reviewed source diff and the fixed point |
| Rust Stage 0 (branch `archive/stage0-final`) | retired; no longer part of the build | its evidence is historical (valid for `ec1ba3e` only); the Rust toolchain is not in the TCB of the current build |
| Fixed point | — | `stage2.c == stage3.c`; LLVM-built compiler reproduces `stage3.c` |

## Contract verification (ADR-0012 phase 2, in progress)

| Component | Trust | Notes |
|---|---|---|
| Contract checker / VC generator | trusted | to be tested against known `REFUTED` cases |
| SMT solver (Z3) | trusted | results are `VERIFIED` only with listed assumptions; no proof certificates yet |
| Runtime contract checks (`--check-contracts`) | trusted like the backend | traps exit 101 |

## Not covered by any guarantee today
FFI (none exists yet), remote-service availability/behavior and TLS security, database access (no std API yet),
timing/side channels, business-rule completeness, deployment configuration, ambient output (`console.*`, `exit`),
the authority of a spawned shell command, and OS-level isolation (a hostile native binary can ignore every grant).
`std:net` already provides grant-checked blocking TCP and `std:http` provides pure HTTP/1.1 message handling;
neither establishes these external properties or a verified networking stack. See [std](std.md) and
[capability limits](capabilities.md). These remain explicit trust/assumption boundaries (ADR-0020).
