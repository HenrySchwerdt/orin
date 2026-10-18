# ADR-0053: Provability phase: type and record invariants, and a proof chain for memory safety

Status: proposed (2026-10-16). Planning only; no code and no change to the language surface in this ADR. Requested by the project
owner: once the language is finished, the next phase is provability. Builds on ADR-0012 (contract clauses), ADR-0020 (status vocabulary,
assurance levels), ADR-0030 (provable std, minimal trusted runtime), ADR-0031 (invariants), ADR-0032 (end-to-end assurance),
ADR-0035 (proof obligations, `VERIFIED` against `DYNAMICALLY_CHECKED`), ADR-0036 (verifier fragment), ADR-0038 (facts for check removal),
ADR-0041 (`@NoTrap`), ADR-0017 (tasks), ADR-0051 (explorer rule status) and ADR-0052 (R3: runtime/core in Orin, L0 stays C).

## Question

Two things are asked for. (1) Type and record invariants that are not only checked at run time but proved where the verifier can, with an
honest label for the rest. (2) A precise statement of what "memory safe" means for an Orin program, and an argument for it that says, per
layer, what is machine-checked, what is bounded-model-checked, what is tested and what is trusted.

Much of (1) is already decided (ADR-0031 A3/B8, ADR-0035, ADR-0036) and partly built. This ADR does not restate those decisions. It fixes
what is still missing, in which order, and how each step is gated in CI. For (2) the pieces exist but are not stitched together; the
stitching, and the honest accounting of the gaps, is the main content.

## Current state (main 6db750a)

### What exists

- **Contracts.** `@Requires`, `@Ensures`, `@Invariant`, `@Decreases`, `@Rule` (ADR-0012, `docs/contracts.md`). `--check-contracts` runs them
  (traps exit 101). `orin verify --contracts [--strict]` generates verification conditions and discharges them with z3
  (`compiler/vc/vc.or`, driver in `compiler/main.or`, quality warnings in `compiler/check/quality.or`; CI job `assurance`: `pip install
  z3-solver; python3 tools/test_verify_contracts.py --require-z3`). Fragment: integers of every width, arrays (length, bounds-obligated
  index, update), records and classes, `Option`/`Result`/unions, `Map` size and membership, strings by length, modular calls, class
  invariants per method with inferred frames, loop invariants, bounded `every`/`some`, `sum` (ADR-0036; table in `docs/contracts.md`).
  Not covered: floats, interfaces, closures as values, `?`, recursive types, I/O. `@Decreases` is parsed, not discharged.
- **Statuses.** `VERIFIED | REFUTED | UNKNOWN | ASSUMED | NEEDS_DECISION | NOT_APPLICABLE` plus `STALE`, `NOT_RUN` (ADR-0020 D1);
  `DYNAMICALLY_CHECKED` is a separate axis (ADR-0035 D1). Every `VERIFIED` lists its assumptions A-INT, A-DIV, A-PARTIAL, A-CALL, A-PURE,
  A-INV, A-FRAME, A-LOOP, A-STR, A-MAP (`docs/assurance.md`, `docs/contracts.md`).
- **Invariants today.** Class `@Invariant`: proved per method by z3 (`inv && requires ==> inv'` at every return of a public method that
  changes `this` and of every constructor, kind `invariant`, B8), checked at run time at the same points. Record `@Invariant`
  (ADR-0031 A3): checked at run time at record literals, writes through a place that passes through the record, and returns of a function
  returning the record (`docs/contracts.md` "Record invariants"). The verifier only **assumes** a record invariant for parameters and
  results (A-INV); it does not prove it at the literal or the write. Generic records reject `@Invariant` (E0408). A write to a public field of
  a class from outside the class can break an invariant that A-INV assumes (`docs/assurance.md`, known hole).
- **Lean (`formal/`, Lean 4 core, no Mathlib, `formal/check.sh`: no `sorry`, standard axioms only).** Memory-IR machine with reference counts:
  `run_safe` (no access to a dead location), COW (`makeUnique_store_cow`), the ownership checker on the structured MIR core with
  `check_sound` (`Sound.lean`, `Top.lean`), load-forwarding facts (`Forward.lean`). Outside the model: calls, loops, arrays and array length,
  closures, vtables, floats, string instructions, the `ill` class (null/type confusion, finding F-shape).
- **MIR verifier (`compiler/verify`, about 3,460 code lines).** Runs on every compile (ICE exit 70) and gates code generation:
  ownership/RC rules, handle rules (C14/C15), F1 load forwarding, U1 unchecked array access with fact sources T2 (dominating check) and T6
  (interval analysis, `compiler/verify/range.or`, rules R1-R5), `--assert-facts` re-checks omitted checks at run time (`docs/mir.md`,
  `docs/tcb.md`). The Orin implementation is bound to the Lean checker only by a differential test (`tools/diff_verifier_lean.py`, 12,000
  generated programs per CI run, CI job `formal`) and a mutation corpus (`tools/mutate_mir.py`, about 20,000 mutants, CI job `assurance`).
- **Runtime/platform (L0, C).** `runtime/platform/orin_platform.{c,h}`, at most 1,000 code lines (ADR-0030), contracts in the header,
  contract tests, ASan/UBSan/TSan runs and bounded CBMC harnesses `runtime/platform/tests/cbmc_harness.c` (memory, formatting, policy, paths)
  and `cbmc_net_harness.c` (socket bounds). `tools/verify_platform.sh`, CI job `assurance` with `REQUIRE_CBMC=1`; boundary check
  `tools/check_platform_boundary.sh`.
- **Runtime/core (L1, C today).** `runtime/core/orin_runtime.{c,h}`: RC, COW, `make_unique`, destroy, per-thread free lists and small-block
  cache, strings, arrays, task transfer (`orin_rt_*`). Tested only (ASan/UBSan, differential, `runtime/core/tests/runtime_test.c`,
  `task_test.c`). ADR-0052 moves all of it to Orin through the core dialect (`BCore`, R3a done, R3b partly done; R3c-R3f not started); L0
  stays C.
- **Concurrency (ADR-0017, `docs/concurrency.md`).** Isolated tasks: values are immutable, closures capture snapshots, no heap object is
  reachable from two tasks, a value crossing a task boundary is moved only if its whole graph is uniquely owned, else deep-copied; reference
  counts stay non-atomic. Static checks (E0450-E0452, E0481, E0483), MIR handle rules, validated L0 handles, ThreadSanitizer. The isolation
  claim itself rests on C (`orin_rt_transfer_put`) and is `TESTED_ONLY` (C17).
- **Escape hatches.** There is no FFI and no `unsafe` in safe Orin (ADR-0030 §1; `docs/tcb.md` "FFI (none exists yet)"). The core dialect is
  the only unchecked construct; it is legal only in `$rt/` modules (ADR-0052 Addendum A) and unreachable from user code or annotation
  expansion (E0301). `addrOf` is an escape for the optimiser (ADR-0052 Addendum A §2). The array facts of ADR-0038 (T1-T6) are the only places
  where an emitter drops a runtime check on the strength of a verified fact.
- **Explorer.** ADR-0051 distinguishes proved / checked at run time / open for a rule, but OSIG `0.3` does not carry the verifier outcome, so
  the rules page shows "Unknown" for every rule until `orin graph` writes the optional `assurance` field (needs `osig/0.4`).

### Inventory: proven, checked, trusted

"Proven" means machine-checked by a proof assistant or a solver for the stated model and assumptions. It does not mean the Orin
implementation is bound to the model. Levels follow `docs/assurance.md` (`MODEL_ONLY`, `TRANSLATION_VALIDATED`, `IMPLEMENTATION_VERIFIED`,
`TESTED_ONLY`).

| Item | Class | By what | Level / limit |
|---|---|---|---|
| RC machine never touches freed memory, COW preserves values (C1, C2) | proven | Lean kernel, `formal/Orin/Theorems.lean`, `COW.lean`; axiom audit in CI job `formal` | `MODEL_ONLY`; models RC, not `orin_runtime.c` |
| Ownership checker is sound for the structured MIR core (C3) | proven | Lean, `Sound.lean`, `Top.lean` | `MODEL_ONLY`; no calls, loops, arrays, closures, floats; `ill` not excluded |
| Facts behind load forwarding (`load_load`, `store_load`, frame lemmas) | proven | Lean, `formal/Orin/Forward.lean` | `MODEL_ONLY`; the F1 scan itself is not proved; protects behaviour, not safety |
| `compiler/verify` implements the Lean checker (C4) | checked | differential test (12,000 programs/run), mutation corpus (20,000 mutants), `verify_main.or` cases | `TESTED_ONLY`; structured fragment only |
| Every compiled program passes the ownership verifier (C5) | checked | gate on every compile, `tools/verify_all.py` | inherits C3/C4 |
| U1 unchecked array access (T2 dominating check, T6 intervals) | checked | rule code, ~110 range cases, `bce-*`/`range-*` mutation classes, `--assert-facts` | `TESTED_ONLY`; both sources are proved sound in the Lean model (M8, `MODEL_ONLY`): the interval source (`u1_sound`, `u1_machine`; the call contract `GenOK` derived from the call machine, `ret_genok`; termination, `fix_total`) and the dominated-by-check scan T2 (`dom_sound`, `t2_machine`, for a pinned array local, scalar index, no array stored into itself; a borrowed-only array parameter included, `t2_param`: the pin is derived from `Frozen`, provided the function only uses the parameter in kept positions); the builtin descriptors are bound per machine instruction and the ghost bit is defined from the kinds (`BuiltinSim.lean`, `mop_exec`), with the class of a scalar read and the class table against the kinds as stated hypotheses; the Orin code, the translation between the machine's structured code and the analysed blocks, and the emitters are not; the only fact an emitter trusts for memory safety |
| Contract `VERIFIED` results (C11) | proven under assumptions | z3 `unsat` on the VCs of `compiler/vc/vc.or` | VC encoder not proved (finding F-vc1 was a real unsoundness), no certificates; listed A-* assumptions |
| Contract `REFUTED` results (C16) | checked | z3 `sat` model on an abstraction-free path | `TESTED_ONLY` |
| Class invariants per method | proven under assumptions | VCs (kind `invariant`) plus run-time check | A-INV, A-FRAME; public-field-write hole |
| Record invariants | checked | `--check-contracts` at literals, writes, returns | `DYNAMICALLY_CHECKED`; not proved statically; erased without the flag |
| Loop invariants | proven under assumptions | VCs `loop-invariant`; no run-time check yet | A-LOOP; termination not proved (A-PARTIAL) |
| Shape/type safety of MIR (field index against arity, struct vs array) | checked | runtime bounds checks `orin_chk_slot` (always on) | `TESTED_ONLY`; the verifier does not check shapes (F-shape, P0) |
| Bounds checks and overflow | checked | run-time traps in both backends | defined traps; `ISetField`/`IArraySet` scalar stores skip the release test (leak, never use-after-free, T3) |
| Runtime/core RC, COW, free lists, small-block cache, strings, arrays | checked | ASan/UBSan, differential, `runtime_test.c` | `TESTED_ONLY`; ~3,200 lines C; the block size is recomputed from `cap`, so a wrong `cap` corrupts a list |
| Task isolation (C17), transfer in `orin_rt_transfer_*` | checked | TSan, ASan/UBSan, stress, MIR handle rules | `TESTED_ONLY`; 342 code lines C |
| L0 memory, formatting, policy, paths, socket bounds | checked (bounded proof) | CBMC harnesses, contract tests | bounded only; no Frama-C/WP; float conversion and clock have no harness |
| L0 threads and monitors | checked | contract tests, TSan | CBMC cannot model threads; no deadlock freedom |
| Capability rules (C14, C15) | checked | checker + MIR verifier + runtime handle validation | `TESTED_ONLY`; about authority, not memory |
| Lowering, optimiser (C6, C7) | checked | ~420 conformance programs, differential modes | `TESTED_ONLY`; memory safety of the output is re-checked by the verifier, behaviour is not |
| C and LLVM backends (C8) | trusted | backend differential tests, LLVM fixed point | no translation validation |
| Type checker (C9), parser | trusted | error and conformance suites | no soundness theorem |
| z3 | trusted | none | no proof objects (ADR-0032 §3) |
| Lean kernel, Lean toolchain | trusted | | standard |
| gcc/clang, LLVM, linker, libc, libm, OS kernel, hardware | trusted | | external |
| Seed C (`bootstrap/seed/orin-seed.c.gz`) | trusted | `stage2 == stage3`; one diverse double root, for `ec1ba3e` only | single root afterwards |

## Decision

### 1. Vocabulary: "bewiesen" and "geprüft" are fixed

The explorer and every report use two words for a rule and one for the rest. They map onto the existing statuses; no new status is introduced
(ADR-0020 D1, ADR-0035 D1).

| Shown | Meaning | Source |
|---|---|---|
| bewiesen (proved) | `VERIFIED`, with its assumption list and assurance level | `orin verify --contracts` |
| geprüft (checked) | `DYNAMICALLY_CHECKED`: an executable check exists in a `--check-contracts` build and the obligation is not `VERIFIED` | the compiler emits the check |
| offen (open) | `UNKNOWN`, `REFUTED`, `NOT_RUN`, `STALE` or erased and unchecked | none |

A clause is never shown as bewiesen because it is also checked at run time, and never as geprüft when it was only type-checked and erased.
The status must reach the explorer through OSIG: `orin graph` writes the `assurance` field of the `Contract` node (`proved`, `runtime`,
`open`, ADR-0051) in `osig/0.4`, taken from the same obligation results, not from a second analysis.

### 2. Type and record invariants

**Syntax: no new keywords.** The existing `@Invariant(e)` stays the one form (ADR-0012: closed set, not an annotation). Examples, all
accepted by the grammar today unless marked *new*:

```orin
@Invariant(this.cents >= 0)
@Invariant(this.currency.length == 3)
type Money = { cents: i64, currency: string }

class Account {
  @Invariant(this.balance >= 0 && this.balance == sumBy(this.entries, e => e.amount))
  ...
}

@Rule("RNG-1")                                   // names the obligation; `@Rule` is already allowed next to a clause
@Invariant(this.low <= this.high)
type Range = { low: i64, high: i64 }

@Invariant(this.items.length <= this.cap)        // generic record: new, lifts E0408 (M4)
type Buf<T> = { items: T[], cap: usize }
```

Additions, each a separate milestone, none changes expression syntax: (a) `@Invariant` on a generic record or class (`this` ranges over all
instantiations; the clause is checked once, abstractly, as for generic functions in ADR-0036 §3); (b) `@Rule("ID")` attaches a stable
name to an invariant so the explorer, diagnostics and `--strict` scopes can refer to it; (c) `@Invariant` on a variant payload type is
treated as an invariant of the payload record. Invariants on `enum` variants beyond that, and invariants over several values (relations
between two records), are not proposed: they stay `@Requires` / `@Ensures`.

**Semantics: when must an invariant hold.**

1. *Construction.* At every record literal (including spread: checked on the finished value) and at the end of every class constructor. A
   value that violates its invariant cannot be created.
2. *After every operation that can change it.* After a write through a place that passes through the record; at every return of a public
   method that changes `this`. Inside a method body (and any private method) the invariant may be broken; it is neither assumed on entry to
   a private method nor required before it returns (ADR-0031 B8). A call to another method of the same object in the middle of an update
   goes through a private method. Exception (Addendum A): a private method assumes them on entry when every call of it proves them
   (docs/contracts.md, "Invariants in private methods").
3. *At the module boundary.* Everything exported or public is observed only in states where the invariant holds. A public field of an
   invariant-bearing class is not an exception: a write to it from outside the class is an obligation at the write (the same as for records),
   or a compile error when it is not provable. This closes the A-INV hole (M3).
4. *Mutation, COW, aliasing.* Values are immutable up to copy-on-write; `make_unique` copies shallowly and the copy has the same content, so
   the invariant, a predicate over content, is preserved by COW by construction. An `inout` parameter or a mutating receiver is a write: the
   invariant is an obligation at the call's return, not in the middle. There is no observable aliasing in safe code (value semantics, ADR-0031
   B9), so a proved invariant cannot be broken through another name. The precise copy-in/copy-out rule for an `inout` argument that also
   appears elsewhere in the same call (`f(inout a, a)`) must be pinned by a test before M3 relies on it; the MIR verifier already forbids an
   in/out receiver that aliases another argument (`docs/tcb.md`).
5. *Quantified invariants.* `range(a, b).every(..)` (ADR-0036 §1) and `sumBy` are allowed; they cost an allocation per check in a
   `--check-contracts` build and nothing otherwise.

**Checking strategy.** Per obligation, in this order:

1. Generate the VC at each point of 1-3 (record literal, field write, return, constructor, public method end, external field write) with a
   stable obligation ID (ADR-0035 D1), kind `invariant` and `blame` as in ADR-0031 A2.
2. If z3 returns `unsat`: bewiesen, with assumptions. If `sat` on an abstraction-free path: `REFUTED` with a counterexample and the three
   options of ADR-0031 B8. Otherwise `UNKNOWN` with the reason.
3. For every obligation not bewiesen, a `--check-contracts` build keeps the run-time check (geprüft). A release build erases it
   (ADR-0035 D4); `--verify=strict` (ADR-0035) fails the build when an invariant in scope is `REFUTED` or `UNKNOWN`, unless the module
   policy allows run-time checking for that scope.
4. A proved invariant at a point keeps its run-time check in a `--check-contracts` build by default (belt and braces) and the check is
   counted, so a run-time violation of a proved invariant is reported as a verifier bug (exit 70), not as a user error.

**Diagnostics.** A violated invariant reports values (power-assert style), the record or class, the location of the literal, write or
return, blame ("the code that built the value" for literals and writes, "the callee" for methods) and an action (`FIX_CODE`,
`NEEDS_DECISION`), as in ADR-0031 A1-A3 and ADR-0029. New: each result carries its status word (bewiesen / geprüft / offen), the invariant's
`@Rule` id if any, and the assumption list. W0450/W0452 (vacuous or trivially true invariants) and W0470 (class with state and no
invariant) stay; an invariant that the verifier proves unsatisfiable is reported (as W0461 does for `@Requires`).

### 3. Memory safety of an Orin program

**The property.** A program compiled from safe Orin, accepted by the checker and the MIR verifier, run on a correct runtime, backend and
platform, satisfies:

- **S1 no use-after-free:** no access to an object after its reference count reached zero and it was freed.
- **S2 no double free:** an object is freed at most once.
- **S3 no out-of-bounds access:** every array, string and struct-slot access is within the object, or traps before the access.
- **S4 no invalid reinterpretation:** an access to a struct, array or string sees an object of that kind and shape (closes F-shape).
- **S5 no uninitialised read:** every local and slot is written before it is read.
- **S6 no data race:** no heap object is reachable from two tasks at the same time; the only state shared between tasks is behind validated L0
  handles and locks (ADR-0017 stage 0).
- **S7 in-place mutation is unobservable:** a store through a reference with `rc != 1` never happens (COW), so value semantics hold.

Defined traps (bounds, overflow, failed contract, OOM) are safe outcomes (spec 07). Out of scope for the safety claim: leaks (a separate
property **L1**: the verifier already warns on leaks; leak freedom is argued separately, because T3 shows that some paths leak by design
of the cost model), termination, deadlock, OOM, timing, and the behaviour of native code. S5 needs one check before it is claimed: whether the
checker's definite-assignment rule and the MIR well-formedness rules together exclude every read of an unwritten local or slot; if not, it
gets its own verifier rule (M2).

**The argument, in layers.** Each layer states what it must guarantee, how, and the level it reaches after this ADR.

| Layer | Guarantee it owes | How | Result |
|---|---|---|---|
| (a) Source and type system | no forged capability or handle (C14/C15), no FFI or `unsafe`, no core-dialect construct in user code (E0301), no shared mutable value (S6 statically) | checker rules, closed annotation mechanism, closed contract set | argued and tested; type soundness is not proved (C9); a Lean source core with progress/preservation is ADR-0032 §1 and stays off the critical path of this ADR |
| (b) MIR verifier as checked invariant | S1, S2, S7 from ownership/RC rules; S3 for unchecked accesses via U1 facts; S4 via a shape check; S5 via well-formedness | verifier on every compile; a verified MIR program is safe under the machine semantics | the **machine-checked core** of the argument: extend the Lean model to calls, loops, arrays with length, shapes, prove `check_sound` there, and bind the Orin verifier to it |
| (c) Backend translation | the C and LLVM output implement the MIR machine | emitters; every fact an emitter trusts is a verifier fact (U1, F1) and nothing else | **trusted** in this ADR; reduced by (i) keeping the list of facts an emitter may use closed and tested, (ii) `--assert-facts` as a run-time cross-check, (iii) a translation-validation prototype for one family (M10); full validation is ADR-0032 §2 |
| (d) runtime/core in Orin (after ADR-0052 R3d/R3e) | the L1 functions implement the machine operations (retain, release, make_unique, alloc, destroy, transfer) | the core dialect verified like user code (contracts on `load`/`store` within the object, layout invariant, free-list invariant), then refinement against the Lean machine (R4) | machine-checked **if** the verifier is extended to the core dialect (M9, M11); until R3d lands this layer is C and `TESTED_ONLY` |
| (e) runtime/platform C | L0 contracts: memory, formatting, policy, paths, socket bounds | CBMC harnesses, bounded; threads/monitors tested | **bounded proofs** for the pure and memory functions (completed in M7); threads/monitors remain tested; ACSL/Frama-C WP is optional and not scheduled |
| (f) residual TCB | | | z3 (for contracts, not for memory safety), Lean kernel, gcc/clang/LLVM, libc, OS, hardware, seed, L0 threads |

Which parts become what:

- **Machine-checked proofs (Lean):** the extended MIR machine and `check_sound` (b); the array-length facts and the soundness of the interval
  analysis rules R1-R5 against that model (b); the refinement of the L1 operations (d) in R4; later the VC encoding (soundness of the
  `VERIFIED` result) as in assurance P0.
- **Bounded proofs (CBMC):** L0 functions with a harness (e).
- **Solver proofs (z3):** contract and invariant obligations of user code and std, and the L1 functions' contracts once the core dialect is
  in the fragment (d). Not a replacement for Lean: z3 is trusted and produces no certificate.
- **Argued, not proved:** the backends (c), the type checker (a), L0 threads, the Lean model's fidelity to the real C machine (the model
  abstracts `refmask`, `is_ref`, `kind`).
- The honest statement after the last milestone: "a program accepted by the verifier is memory safe, assuming the backend emits the MIR
  semantics, the platform layer meets its contracts, and gcc/LLVM, libc, the OS and the hardware are correct". Until M6 that sentence is
  stronger than the evidence for calls, loops and arrays, and reports must not use it (the assurance ledger says `MODEL_ONLY`).

### 4. Milestones

Each milestone is one or a few small PRs, merges alone, and keeps stage2 == stage3 for both backends. A milestone that adds a verifier rule
or an emitter fact needs the owner's decision on TCB cost, as for T5/T6 in ADR-0038. "Gate" is the CI job (or a new step in it) that fails
if the milestone's claim is untrue.

| # | Content | Exit criteria | Gate | Depends on |
|---|---|---|---|---|
| M1 | Status plumbing: obligation IDs and statuses reach OSIG `0.4` (`assurance` on `Contract` nodes); explorer shows bewiesen / geprüft / offen | explorer test with the three states; "rules with a known status" above 0 on the compiler's own snapshot; old snapshots still read | `tooling` job (explorer tests), `tools/test_verify_contracts.py` | ADR-0051, ADR-0035 phase 1 |
| M2 | `docs/memory-safety.md`: S1-S7 and L1 as precise statements, each mapped to ledger claims and files; S5 and S4 gaps decided; a lint that every claim id cited exists in `docs/assurance.md` | doc merged; every property has an owner layer and an assurance level; the lint passes | new step in the `assurance` job running the lint | none |
| M3 | Record invariants proved: VCs at record literal, field write (nested too) and return; external write to a public field of an invariant-bearing class (closes the A-INV hole); `@Rule` on invariants | `tests/contracts/` positive, negative and `verify_soundness` cases; the compiler's own records (`Span`, `Diagnostic`, `Resolved`, `PreludeRoot`) report bewiesen or geprüft; no run-time check removed | `assurance` job (`test_verify_contracts.py --require-z3`) | independent; M1 for display |
| M4 | Generic records and classes: `@Invariant` on them (lifts E0408); variant payload invariants; `inout` aliasing rule pinned by tests | checked once abstractly; instantiation tests; `f(inout a, a)` behaviour fixed | `assurance` job, conformance | M3 |
| M5 | `--verify=strict` for invariants and loop invariants: scope and policy; `@Decreases` discharged for simple measures; loop invariants checked at run time | strict build fails on an open invariant in scope; std modules `bytes`, `utf8`, `collections` have every invariant in scope bewiesen or an explicit run-time waiver | `std` and `assurance` jobs | M3, ADR-0035 phase 1 |
| M6 | Lean model: calls (owned params, borrows), loops, arrays with length and bounds, struct shapes; `check_sound` for the extended machine; `ill` excluded; `Forward.lean` facts for arrays | `formal/check.sh` clean (no `sorry`, standard axioms); `tools/gen_mir_fragment.py` covers the new constructs; the allow-listed difference F6 closed | `formal` job | none |
| M6b | MIR shape/type check in `compiler/verify` (field index against arity, array op on arrays, call arguments against callee MIR types); only then may the compiler omit run-time shape checks, exactly where proved (owner policy, F-shape) | new `shape-*` mutation classes all rejected; differential test includes the shape rules; benchmark delta recorded | `assurance` job (`mutate_mir.py`), `formal` job | M6 |
| M7 | L0 harness completion: CBMC for float conversion and clock wrappers and every pure L0 function; handle validation (generation, liveness) as a model-checkable state machine (the logic, not the threads) | `verify_platform.sh` lists a harness per pure function; `REQUIRE_CBMC=1` stays on | `assurance` job | none |
| M8 | Interval analysis soundness: array length in the Lean model; R1-R5 and U1 proved against it, so the T2/T6 facts move from "code only" to `MODEL_ONLY` | one lemma per rule; the `range-*` mutation classes are still all rejected | `formal` job | M6 |
| M9 | Verifier extended to the core dialect: `load`/`store`/`memAlloc` with a heap model in the VC encoding; layout invariant (`rc@0`, `kind@8`, ..., ADR-0052 Addendum A §2 rule 3); contracts on the first L1 modules (R3b strings/arrays without allocation policy) | `orin verify --contracts runtime/core` reports bewiesen for the bounds of every L1 access in R3b; a deliberately wrong offset is REFUTED | new `runtime-core-verify` step in the `assurance` job | ADR-0052 R3a, R3b |
| M10 | Backend fact audit and a translation-validation prototype for one instruction family (U1: `IArrayGetU`/`IArraySetU`, the only place an emitter drops a check on a verified fact): the emitted C/LLVM pattern is checked against the MIR instruction by a small independent checker | checker accepts the emitter output on all conformance programs; a mutated emitter is rejected; the closed list of facts an emitter may use is a test | `backends` job | M8 |
| M11 | Allocator, RC, make_unique, destroy in Orin verified: free-list invariant, block size from `cap`, the `rc` protocol (immortal and lend-pinned bits), no double free by the destroy worklist | R3d contracts verified by the core-dialect verifier; ASan/UBSan runs unchanged; the `docs/tcb.md` row for `runtime/core` moves to the achieved level | `assurance` job, `runtime-core-verify` | ADR-0052 R3d, M9 |
| M12 | R4 refinement: the L1 operations (retain, release, make_unique, store, alloc) refine the Lean machine operations; task transfer ("disjoint heaps, send transfers ownership", C17) proved in Lean | refinement theorems with no new axiom; C1/C2 move from `MODEL_ONLY` to `IMPLEMENTATION_VERIFIED` for the covered operations; C17 moves from `TESTED_ONLY` | `formal` job | ADR-0052 R3d, R3e; M6, M11 |
| M13 | Assurance report: `orin build --assurance-report` states S1-S7 per program with the layer table, the assumption list and which layers are `MODEL_ONLY`, bounded or trusted; `.orcert` attestation (ADR-0032) once the layers above exist | report on the compiler and on std; a claim above the ledger's level is a test failure | `assurance` and `tooling` jobs | M1, M2; honest labels need M6-M12 |

Order: M1, M2, M3, M6 and M7 can start right after the language work lands and do not touch each other (M3 touches `compiler/vc`, M6 only
`formal/`, M7 only `runtime/platform/tests`). M4 and M5 follow M3. M6b and M8 follow M6. M9, M11 and M12 wait for ADR-0052 R3b, R3d and R3e.
M10 and M13 close the phase.

## Risks and non-goals

Risks:
- **The TCB grows.** Every verifier rule that lets an emitter drop a check (U1, the omission of shape checks in M6b) adds trusted code. The
  cost decisions of ADR-0038 (T5, T6) are still open; M6b and M8 do not start without the owner's call.
- **Lean model fidelity.** The model abstracts the runtime (`kind`, `refmask`, `is_ref` collapsed); R4 is only as good as that abstraction.
  M12 must state which fields are modelled and which are assumed.
- **VC encoder soundness.** F-vc1 was a real bug that proved everything. The invariant VCs of M3 add encoder code. Mitigations: the
  `verify_soundness` suite, mutation of the VC generator (`tools/contract_mutation.py`), and eventually the Lean model of the encoding (assurance
  P0). Until then the encoder is `TESTED_ONLY` and reports say so.
- **Proof effort against language change.** The model must be extended at the speed of MIR changes (v2.x). A MIR change without a model
  change is listed in the ledger as outside the model, as now.
- **Performance.** Run-time invariant checks (geprüft) cost time in `--check-contracts` builds only; keeping the shape checks until M6b costs
  about 23% self-compile (`docs/benchmarks.md`). The R3d hot path (ADR-0052) must stay inlinable; verification must not force non-inlined calls.
- **z3 incompleteness.** Many obligations will stay `UNKNOWN` (280 of 444 in `compiler/` after PR #40, ADR-0035). `--strict` is usable per
  scope; a global strict build is not a goal of this phase.
- **Concurrency.** CBMC cannot model threads. S6 for L0 threads and monitors stays tested; the isolation proof (M12) covers heaps, not
  deadlock or fairness.
- **Claim creep.** The ledger rules apply: a result without an assurance level is `TESTED_ONLY` at best; a change that weakens a claim needs
  human approval.

Non-goals:
- A verified compiler (CompCert style); per-program translation validation is the chosen direction (ADR-0032 §2), and only a prototype is
  planned here.
- Proving the type checker sound, a full source semantics in Lean, or proof certificates for z3 (ADR-0032 §1, §3; separate work).
- Leak freedom, termination of all programs, absence of deadlock, OOM-freedom, timing and side channels.
- Rewriting L0 in Orin (ADR-0052: stays C until the verifier covers the core dialect and a target needs it).
- Invariant syntax beyond the three additions in §2, and invariants relating several values.
- Proving native code or a future FFI; an FFI would be a declared unsafe boundary reported as `UNKNOWN` (ADR-0030).

## Consequences

- One vocabulary (bewiesen / geprüft / offen) from compiler to explorer, derived from the existing statuses; the explorer's "Unknown"
  placeholder (ADR-0051) goes away after M1.
- Record invariants move from "checked" to "proved where decidable" without new syntax; the known A-INV hole is closed.
- The memory-safety claim gets a stated property, a layer table and a ledger-linked accounting instead of a sentence. It also exposes which
  layers are still `MODEL_ONLY` or `TESTED_ONLY`; nothing in this ADR upgrades a ledger entry by itself.
- The Lean work (M6, M8, M12) is the long pole and the only way to move C1-C5 above `MODEL_ONLY`; the CBMC and z3 work (M3, M7, M9, M11) can
  run in parallel with it.
- ADR-0052's R3 gains a reason to keep the core dialect small and verifiable: M9 needs the verifier to model `load`/`store` and layout.

## Addendum A (2026-10-17): the compiler proves itself, with no `UNKNOWN`

### Question

The owner's requirement (2026-10-17): the compiler itself must be proven; `UNKNOWN` results are not acceptable. What does that mean
exactly, where do we stand, and how do we get to zero?

### Target

"The compiler is proven" means: `orin verify --contracts compiler/main.or` reports every obligation of every compiler function as
`VERIFIED`, with **0 `REFUTED` and 0 `UNKNOWN`**. Every `VERIFIED` result is relative to the assumptions it names (A-INT, A-CALL,
A-LOOP, A-STR, ... in `docs/assurance.md`) and to z3 and the VC generator as trusted components (`docs/tcb.md`). Reaching zero does not
by itself raise any ledger level; it removes the open obligations so that the remaining gap is exactly the named assumptions.

An obligation may leave the count only by being proved. Deleting a contract or weakening it to `true` to remove an `UNKNOWN` is not
allowed; a contract that is wrong is fixed and the fix is justified in the PR.

### Baseline (origin/main d0a17a9)

Full run over `compiler/` (25 modules, z3 4.8.12, per-module instrumented runs; data and method in the project report
`reports/compiler-verify-triage.md`):

| | count |
|---|---|
| obligations | 2469 |
| `VERIFIED` | 782 |
| `REFUTED` | 23 (none is a compiler bug: all are incomplete or non-inductive contracts) |
| `UNKNOWN` | 1664 |
| serial run time | 133 min (module `opt` alone 93 min) |

`UNKNOWN` by cause:

| Group | Count | Fix (verifier feature or contract work) | Owner code |
|---|---|---|---|
| U1 Callee result known only via its contract, or string contents | 360 | unfold small pure callees as definitions; add the missing `@Ensures` (`rtNames`, `isEofTok`, `isValidCode`, the `diag(code, ...)` precondition ×45) | `vc/expr.or`, `vc/gen.or`, compiler sources |
| U2 Name collisions (callee not unique 148, duplicate type name 116) | 264 | qualify function keys and type names by unit, resolved like the type checker | `vc/vc.or` (`buildProg`), `vc/expr.or`, `vc/vt.or` |
| U3 Recursive records and unions (`FnCtx` alone 150) | 259 | z3 recursive datatypes or an opaque sort with field accessors; `match` on them | `vc/expr.or`, `vc/stmt.or`, `vc/vt.or` |
| U4 Missing loop invariants (53 in `syntax/lexer.or`) | 235 | `@Invariant` on the loops; infer the "accumulator length = i" shape | compiler sources, `vc/stmt.or` |
| U5 z3 timeout (131 in `opt`) | 211 | per-goal fact slicing, incremental solving; split large functions | `vc/vc.or` |
| U6 `?` operator | 104 | encode early return on `Err` / `None` | `vc/stmt.or`, `vc/expr.or` |
| U7 Mutating method call inside an expression | 82 | hoist to a statement in the VC encoding (or in the source) | `vc/expr.or` |
| U8 Array and string methods (`pop`, `split`, `sort`, ...) | 41 | axioms for each method | `vc/expr.or` |
| U9 Unknown record or class (`Workspace`, `Scope`, ...) | 33 | mostly closed by U2 | |
| U10 Map size, string axioms, other constructs, rest | 75 | case by case | |

Run time: 91 % of the 133 min is z3 calls that hit the 4 s timeout; 45 % of z3 time is the bounded-search retry after a timeout
(`rawProve`), which produced 26 counterexamples and 8 proofs in 900 runs. Parsing and VC generation are 1 %.

### Decision

1. **Ratchet in CI.** A new step in the `assurance` job runs the verifier over the compiler and compares the counts per module with
   a checked-in baseline file. `VERIFIED` may only go up and `UNKNOWN` / `REFUTED` only down; a PR that lowers a number updates the
   baseline. Once a module reaches zero it is marked strict and any `UNKNOWN` there fails the build. The step lands after Z1 makes the
   run short enough for CI.
2. **Speed before breadth.** The run must be fast enough to iterate on and to gate in CI, so the first PRs cut time, not unknowns.
3. **Order of work** (each line is one or a few small PRs, merged alone):

| # | Content | Expected effect |
|---|---|---|
| Z0 | Fix the 23 `REFUTED` contracts (constructor `@Requires`, inductive invariants, forwarded preconditions) | `REFUTED` 23 → 0 |
| Z1 | Cap the post-timeout retry, configurable timeout (`--timeout-ms`), deterministic `rlimit`; per-module filter and timing output in `orin verify` | z3 time about −45 %; reproducible results |
| Z2 | U2: qualify names by unit | up to −264 `UNKNOWN` |
| Z3 | U6 `?` operator and U7 mutating calls in expressions | up to −186 |
| Z4 | U1: unfold small pure callees; missing `@Ensures` in compiler sources | up to −360 |
| Z5 | U3: recursive records and unions as datatypes | up to −259 |
| Z6 | U4: loop invariants in compiler sources plus the accumulator-shape inference | up to −235 |
| Z7 | U5: fact slicing and incremental solving; parallel functions; per-function result cache keyed by a content hash (sound only with the deterministic limit from Z1) | timeouts toward 0; repeat runs only re-prove changed functions |
| Z8 | U8-U10 tail; ratchet switched to strict for the whole compiler | `UNKNOWN` 0 |

Z0, Z1 and Z2 start at once and touch disjoint code (compiler sources, the solver call, name resolution in `compiler/vc`). Each verifier
feature in Z2-Z7 comes with positive, negative and soundness tests in `tests/contracts/` before it may turn an `UNKNOWN` into
`VERIFIED`; a feature that cannot be modelled soundly keeps `UNKNOWN` and is reported here instead.

### U5 result (Z7, 2026-10-17)

**What was tried.** Cone-of-influence slicing: before the full query, the goal was asked with only the assertions that share a
constant with it, directly or through other kept assertions. Only `unsat` of the slice was used; anything else fell back to the full
query, so the slice could not cause a wrong VERIFIED or REFUTED. It was measured with `--timeout-ms 2000`, one thread, instrumented
per-module runs, on a heavily loaded machine:

| module | statuses without → with slicing | status changes | first-query timeouts | z3 s | queries sliced / proved by the slice |
|---|---|---|---|---|---|
| verify | 103 VERIFIED / 179 UNKNOWN, unchanged | 0 | 113 → 111 | 554 → 554 | 31 / 3 |
| analysis | 124 VERIFIED / 133 UNKNOWN, unchanged | 0 | 184 → 184 | 985 → 1006 | 16 / 14 |
| opt (first 126 of 257 functions, 4 745 queries) | (compared per query) | 0 answers changed by slicing | 1 402 → 1 402 | 5 391 → 5 356 | 235 / 235, all also proved by the full query |

**Why slicing does not help.** The facts of a query are chained through the symbolic state (each value is defined from the one
before), so the cone of a goal is 90-100 % of the query. On about 200 timed-out queries saved by the baseline run (opt, verify,
analysis), the full-cone slice proved none. Slices limited to 1-3 hops from the goal only give a quick `sat`: a model of fewer facts,
which says nothing about the full query. Checking incrementally (the slice first, then the remaining facts in the same z3 process) still
timed out. So did z3 options (`smt.mbqi=false`, `smt.relevancy=0`, `smt.arith.solver=2`). Most of the timed-out queries also time out,
or are `sat`, with every quantified fact removed. Incremental push/pop per function was not built: parsing the largest query
costs about 0.1 s of CPU, while calls that time out are 91 % of the z3 time. Push/pop would also make an answer depend on the order of the
queries; today it depends on the query text only, which the deferred solver rounds rely on.

**What it means.** The U5 timeouts are goals that do not follow from the facts the verifier has, not queries that are too large: the
missing pieces are callee facts (U1, Z4), loop invariants (U4, Z6), and element or permutation invariants of the data (for
example "`order` is a permutation of `0..n`"). U5 is handled there, not by reducing the query. The time lever stays the solver budget
(Z1). The slicing code (`compiler/vc/slice.or`, `--slice`) was not merged; it is kept for reference in commit `c7d15f37` (branch
`claude/project-thread-niggkx-verify-slice-code`, PR #28).

### Consequences

- The compiler becomes the main test case for the verifier; every gap it shows is a gap for user programs too.
- New compiler code must arrive with contracts that verify, enforced by the ratchet.
- The verifier grows (U1, U3, U6-U8), so its own TCB entry grows; the differential test against the Lean checker and the mutation
  classes have to keep up.
