# Memory safety: the properties S1-S7 and L1

_Created: 2026-10-16 · ADR-0053 section 3 and milestone M2. This file states the properties; the evidence and the
assurance levels are owned by [assurance.md](assurance.md) and [tcb.md](tcb.md). Update it in the same PR that changes the
evidence for a property. A level written here never exceeds the ledger's level for the claims it cites
(`tools/check_safety_claims.py` checks that every cited id exists and that every property has an owner layer and a level)._

## Scope and vocabulary

**Subject.** A program compiled from safe Orin, accepted by the checker and by the MIR verifier (`compiler/verify`), run on a
correct backend, runtime and platform. **Safe outcome.** Either the property holds, or the program stops with a *defined trap*
(bounds, overflow, failed contract, unwrap, OOM; spec 07, exit 101), or the compiler refuses the program (verifier error, ICE
exit 70). Anything else (a read or write of memory the program does not own) violates the property.

**Layers** (ADR-0053 section 3):
(a) source and type system · (b) MIR verifier as checked invariant · (c) backend translation (C, LLVM) ·
(d) runtime/core (C today, Orin after ADR-0052 R3d/R3e) · (e) runtime/platform C (L0) · (f) residual TCB (z3, Lean kernel,
gcc/clang/LLVM, libc, OS, hardware, seed).

**Levels** are the ledger's names exactly: `MODEL_ONLY`, `TRANSLATION_VALIDATED`, `IMPLEMENTATION_VERIFIED`, `TESTED_ONLY`
(docs/assurance.md). No property below reaches `IMPLEMENTATION_VERIFIED` or `TRANSLATION_VALIDATED`. Where a Lean theorem
covers part of a property, the line "Model" says so and says that it is `MODEL_ONLY`; the line "Assurance level" is the level of
the property for the real compiler and runtime. Until ADR-0053 M6 the sentence "a program accepted by the verifier is memory safe"
is stronger than the evidence for calls, loops and arrays and must not be used in reports.

Claim ids (C1, C2, ...) and finding ids (F-shape) are those of docs/assurance.md. docs/tcb.md has no ids; its rows are cited by
component name.

## S1 no use-after-free

- **Statement.** For every heap object (struct, array, string, closure, interface box) and every operation that reads or writes
  the object or its reference count (field/element access, `retain`, `release`, `make_unique`, string/array in-place primitives):
  the operation does not execute after the release that brought the count to 0 and `orin_destroy` freed the object, and the
  free-list reuse of its block does not make an old reference alias a new object.
- **Safe outcome.** None other than "holds": there is no defined trap for S1. A violation is refused at compile time (verifier
  error, "use of `x` which is dead").
- **Owner layer.** (b); (d) for the destroy order and free lists; (c) must not reorder or drop releases.
- **Claims.** C1 (RC machine never touches freed memory), C3 (checker soundness, structured core), C4 (verifier implements the
  checker), C5 (every compile is verified), C6 (optimisations re-checked by the verifier), C8 (backends emit the MIR semantics).
  tcb.md rows: MIR ownership verifier, Lean model, C backend / LLVM backend, Runtime object model.
- **Files.** `compiler/verify/rules.or` (`readLocal`, `needOwned`, `kill`, `IRelease`), `compiler/verify/state.or` (lattice),
  `formal/Orin/Theorems.lean` (`run_safe`), `formal/Orin/Top.lean` (`check_sound`), `runtime/core/orin_runtime.c`
  (`orin_destroy`, free lists), `tools/mutate_mir.py` (use-after-release, use-after-move, extra-release mutants),
  `tools/diff_verifier_lean.py`.
- **Model.** `run_safe` and `check_sound` prove it for the structured MIR core (`MODEL_ONLY`). Calls, loops, arrays, closures,
  vtables and floats are outside the model (C3).
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** `orin_runtime.c` is not bound to the model (C1); calls/loops/arrays not modelled (C3); ADR-0053 M6, M11, M12.

## S2 no double free

- **Statement.** Every heap object is passed to the allocator's free path at most once: a reference is released at most once, a
  moved or released local is not released again, `orin_destroy` pushes each child once per owning slot.
- **Safe outcome.** As S1 (refused at compile time: release of a `Dead`, `Param` or `Borrowed` local is an error).
- **Owner layer.** (b); (d) for `orin_destroy` and the per-thread free lists (the block size is recomputed from `cap` at every
  free, so a wrong `cap` corrupts a list: tcb.md "Runtime object model").
- **Claims.** C1, C3, C4, C5, C6, C8.
- **Files.** `compiler/verify/rules.or` (`IRelease`, `consume`, `kill`), `formal/Orin/Theorems.lean`, `tools/mutate_mir.py`
  (`extra-release`), `runtime/core/orin_runtime.c`, `runtime/core/tests/runtime_test.c` (ASan + UBSan, CI `assurance`).
- **Model.** As S1 (`MODEL_ONLY`).
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** As S1.

## S3 no out-of-bounds access

- **Statement.** Every struct-slot access has `index < nslots`, and every array element and string byte access has `index < len`
  of the object it reads, or the program traps before the access. An access emitted without the run-time check
  (`IArrayGetU`, `IArraySetU`, C helpers `orin_array_at_u` / `orin_array_slot_ptr_u`, LLVM `inbounds` GEP) is allowed only where
  rule U1 holds (dominated-by-check, T2, or interval fact, T6, `compiler/verify/range.or` rules R1-R5).
- **Safe outcome.** Bounds trap (exit 101) before the access; for an unchecked access, U1 is the only justification.
  `--assert-facts` re-runs the omitted checks (`orin_assert_array`, exit 70).
- **Owner layer.** (b) for U1 facts; (c) for emitting unchecked accesses only on U1 facts; (d) for the checked accesses
  (`orin_chk_slot`, array/string helpers); (e) for L0 memory functions.
- **Claims.** C3 (array length is outside the model), C4, C5, C8, C10 (L0 memory functions, CBMC bounded). tcb.md rows: MIR
  ownership verifier (rule U1, the only fact an emitter trusts for memory safety), C backend / LLVM backend, L0 platform layer.
- **Files.** `compiler/verify/unchecked.or` (`uncheckedJustified`, `accessFacts`), `compiler/verify/range.or`,
  `compiler/opt/bounds.or` (asks the verifier, not trusted), `compiler/backends/c/function.or`,
  `compiler/backends/llvm/function.or`, `runtime/core/orin_runtime.h` (`orin_chk_slot`), `runtime/platform/tests/cbmc_harness.c`,
  `tools/mutate_mir.py` (`bce-*`, `range-*`), `compiler/tests/verify_main.or`.
- **Model.** Field index out of range is a `trap` in the Lean machine (`formal/Orin/Machine.lean`). Array length and U1 have no
  lemma: U1 is not claimed as proved (tcb.md).
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** ADR-0053 M8 (array-length facts in Lean), M7 (CBMC for L0), M9 (bounds of core-dialect accesses).

## S4 no invalid reinterpretation

- **Statement.** An access to a struct, array or string sees an object of that kind and shape: `IGetField`/`ISetField`/
  `ITakeField`/`IPutField`/`ITag` operate on a struct whose arity bounds the slot index, array operations on an array, string
  operations on a string, and function results and call arguments agree with the callee's declared MIR types (the `ill` class of
  the Lean machine: null, wrong kind, wrong arity). Closes finding F-shape.
- **Safe outcome.** Shape trap (`orin_trap_shape`, "field access on a value of the wrong shape (compiler bug)", exit 101).
- **Owner layer.** (d) today (run-time backstop); (b) is the intended owner (a MIR shape/type check, ledger P0), with (a) and (c)
  preventing shape errors by construction.
- **Claims.** C3 (`ill` is not excluded), C5 (the verifier checks ownership, not shapes), C7 (lowering preserves semantics, the
  source of the F-shape bug), F-shape. tcb.md rows: HIR to MIR lowering, C backend / LLVM backend, Runtime object model.
- **Files.** `runtime/core/orin_runtime.h` (`orin_chk_slot`, `orin_trap_shape`, `orin_struct_get/set/slot_ptr`),
  `compiler/backends/llvm/function.or` (`@orinl_slot`), `tests/next/run/shape_confusion_try_in_mutating_method.or`,
  `runtime/core/tests/runtime_test.c`, `docs/benchmarks.md` (cost).
- **Model.** `ill` is explicitly not analysed by `check_sound` (docs/formal.md "What `ill` means").
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** See "S4 finding" below.

## S5 no uninitialised read

- **Statement.** Every local and every heap slot is written before it is read. Locals: no instruction or terminator reads a
  local that has not been defined on every path from the entry. Slots: a struct is created with all slots set by the same
  `IStructNew`, an array element below `len` has been stored by `IArrayNew`/`IArrayPush`/`IArraySet`, a slot taken by
  `ITakeField`/`IArrayTake` is not read until `IPutField`/`IArrayPut`.
- **Safe outcome.** Refused at compile time ("use of `x` which is dead (uninitialised, moved, released or invalidated)"). No
  run-time trap exists for an uninitialised local.
- **Owner layer.** (b) for locals and taken slots; (d) for fresh struct slots (zeroed at allocation); S3 for array elements
  beyond `len`.
- **Claims.** C3, C4, C5 (the dataflow rule is part of the verifier), C7 (lowering). tcb.md rows: MIR ownership verifier, HIR to
  MIR lowering.
- **Files.** `compiler/verify/verify.or` (`entryState`), `compiler/verify/rules.or` (`readLocal`, `def`), `compiler/verify/state.or`
  (`joinLs`), `compiler/syntax/parser.or` (`parseLet`), `formal/Orin/Check.lean`, `compiler/tests/verify_main.or`.
- **Model.** The Lean checker has the same states (`dead | init | ...`, `formal/Orin/Check.lean`), but the Lean machine treats a
  dead scalar as the value 0 and reading it is not a memory event (`formal/Orin/Machine.lean`), so S5 for scalars is not a
  theorem there (`MODEL_ONLY` for dead references only, as S1).
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** See "S5 finding" below.

## S6 no data race

- **Statement.** No heap object is reachable from two tasks at the same time. A value crossing a task boundary is moved only if
  its whole graph is uniquely owned, otherwise deep-copied (`orin_rt_transfer_put`); reference counts stay non-atomic; the only
  state shared between tasks is behind validated L0 handles and locks (ADR-0017 stage 0). A resource handle or grant is never
  captured by or sent to a task body except through the delegating `spawn*` forms.
- **Safe outcome.** Static rejection (E0450-E0452, E0481, E0483) or a run-time trap on a stale / forged handle. There is no trap
  for a violated transfer: the isolation claim rests on the runtime code.
- **Owner layer.** (a) for handle and capture rules; (d) for the transfer (temporary C, 342 code lines, replaced in R3);
  (e) for L0 threads and monitors (stay C after R3).
- **Claims.** C14, C15, C17. tcb.md rows: Task runtime, L0 threads and monitors, Capability grants.
- **Files.** `compiler/check/tasks.or`, `compiler/check/resources.or`, `compiler/verify/rules.or` (handle rules),
  `runtime/core/orin_runtime.c` (`orin_rt_transfer_put`), `runtime/core/tests/task_test.c`, `tools/test_concurrency.sh`,
  `tests/concurrency/`.
- **Model.** None: "disjoint heaps, send transfers ownership" is a Lean goal of ADR-0053 M12.
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** The C runtime is unverified; a ThreadSanitizer-clean run is evidence for the races that happened (C17); no model
  checking of threads (C10); L0 threads remain tested.

## S7 in-place mutation is unobservable

- **Statement.** A store, take, put, push, pop or in-place string append through a reference happens only when the object's
  reference count is 1 (otherwise the program first copies via `make_unique`), so a value observed through another reference
  never changes. The Lean machine reports the violation as `bad shared`.
- **Safe outcome.** Refused at compile time (the verifier requires state `Unique` for `ISetField`, `IArraySet`, `ITakeField`,
  `IPutField`; `Owned`/`Unique` for push/pop/append). No run-time trap.
- **Owner layer.** (b) for uniqueness tracking and demotion on aliasing; (d) for `orin_make_unique` / `orin_make_unique_slow`
  and the in-place string primitives (in place only for `rc == 1`).
- **Claims.** C2 (copy-on-write preserves value semantics), C1, C3, C4, C5, C6.
- **Files.** `compiler/verify/rules.or` (`needUnique`, `store`, `take`, `put`, `mutateOwned`, `demote`), `formal/Orin/COW.lean`
  (`makeUnique_store_cow`), `formal/Orin/Theorems.lean`, `runtime/core/orin_runtime.c` (`orin_make_unique_slow`),
  `tools/mutate_mir.py` (store through a shared reference).
- **Model.** `makeUnique_store_cow` (`MODEL_ONLY`).
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** As S1; string/array in-place primitives and uniqueness after calls are outside the model (C3, rule "calls and
  uniqueness" in docs/mir.md).

## L1 leaks (not part of safety)

- **Statement.** Every counted reference is eventually released, moved, consumed or returned. Not part of S1-S7: a leak is
  memory-safe. The verifier warns (never errors) on a local that may still own a reference at return; some paths leak by design
  of the cost model (ADR-0038 lever 2 T3: scalar stores without the release test leak, never use-after-free), and a trapped
  task leaks its heap.
- **Safe outcome.** A warning; leak freedom is not claimed.
- **Owner layer.** (b) warns; (d) cost-model leaks.
- **Claims.** C5, C17 (a trapped task leaks its heap).
- **Files.** `compiler/verify/rules.or` (`term`, "leak: ... may still own a reference at return"), `tools/alloc_census.py`.
- **Assurance level.** `TESTED_ONLY`.
- **Gap.** No leak-freedom argument; ADR-0053 section 3 leaves it separate.

## S5 finding (ADR-0053 M2 decision)

Question: do the checker's definite-assignment rule and the MIR well-formedness rules together exclude every read of an
unwritten local or slot?

**Answer: yes for locals, but the guarantee comes from the verifier's dataflow, not from the checker and not from
well-formedness. For slots it holds by construction of the instructions, with array elements resting on S3. No new verifier
rule is required to claim S5 at `TESTED_ONLY`; one evidence gap and one model gap remain (below).** Read-only investigation of
`compiler/` at the revision this file was merged from.

1. **Checker.** There is no definite-assignment analysis for locals in the checker. The source rule is syntactic: `const` and
   `let` require an initializer (`compiler/syntax/parser.or:1766`, `parseLet` calls `expectP("=")` and `parseExpr`; spec
   `spec/01-syntax-and-grammar.md:25`). The only definite-initialisation analyses are for class fields
   (`compiler/check/classes.or:86`, `:211`, "field(s) not definitely initialized by the constructor") and for `this` use in
   constructors (`compiler/check/ops.or:670`). So S5 does not rest on the checker beyond the parser rule; temporaries created by
   the lowering have no source-level guard.
2. **Well-formedness.** `compiler/verify/wf.or` checks index ranges and operand classes only (`opLocalOk`, `wfInstr` at
   `wf.or:559`, `wfTerm` at `:764`, `wfFunction` at `:800`); it says nothing about definedness.
3. **Verifier dataflow (the actual rule).** `entryState` (`compiler/verify/verify.or:72-90`) starts every non-parameter local
   `KDead` and parameters `KInit`/`KParam`/`KOwned`. Every definition goes through `def` (scalars become `KInit`, e.g.
   `rules.or:463`, `:502`, `:783`). Every read goes through `readLocal` (`rules.or:331-345`), which reports an error for `KDead`,
   `KMaybeDead` and `KMaybeLeak`; `readOp`/`readWhole`/`consume`/`needOwned` route to it, and the instruction rules call them for
   every operand (`rules.or:777-1010`: `ICopy`, `IUnary`, `IBinary`, `ITag`, `IForward`, `IArrayGet`, ...). Terminators read the
   branch/switch operand with `readOp` and the return value with `consume` (`rules.or:207-216`). The join of `Init` with `Dead`
   at a merge point is `MaybeDead` (`joinLs`, `state.or:174-192`; `lsLeq`, `state.or:148`), so a local written on only one path
   is rejected at its read, including across loop back edges. Unreached blocks are not analysed (`stateOrDead`,
   `state.or:386`), which is harmless: they never execute. Taken slots are tracked by the hole sets (`rules.or:611-632`;
   `readWhole` rejects whole-object use with an open hole; `IForward` rejects a read of a taken slot).
4. **Slots.** `IStructNew` takes one operand per slot, so no slot of a verified struct is unwritten; the runtime additionally
   zeroes fresh struct slots (`runtime/core/orin_runtime.c:546-553`). Array items are allocated uninitialised (`sb_alloc`,
   `orin_runtime.c:1189`) but `len` starts at 0 (`:1186`) and grows only through `IArrayNew` elements and `IArrayPush`, so
   reading an element below `len` reads a written one; an element at or above `len` is an S3 violation (bounds check or U1),
   not an S5 one.
5. **Defence in depth.** Both backends initialise non-parameter locals: C emits `= NULL` / `= 0` / `{{0}}`
   (`compiler/backends/c/function.or:688-694`), LLVM emits an `alloca` with an initialising store
   (`compiler/backends/llvm/function.or:1348-1380`). A missed read of an uninitialised reference therefore dereferences NULL
   (a crash), not stale stack memory. This is a mitigation, not a proof.

**What is not covered, as future work.**
- *Evidence:* `tools/mutate_mir.py` has no mutation class that reads a local before its first definition (its classes drop or
  duplicate releases and moves; the nearest are `use-after-release` and `drop-dup`). Add a class "delete the only definition of a
  local that is later read" (expected message "is dead") and a hand-built case for a definition on one branch only in
  `compiler/tests/verify_main.or`.
- *Model:* the Lean machine represents a dead scalar as `0` and a read of it is not `bad` (`formal/Orin/Machine.lean`), so
  `check_sound` does not state S5 for scalars. Precise missing statement: add an outcome `uninit` (read of a local never
  defined) to the machine and extend `check_sound` to exclude it, then rerun `tools/diff_verifier_lean.py`. This belongs to the
  ADR-0053 M6 model extension; no new verifier rule is needed.
- *Slots of arrays:* S5 for array elements reduces to S3; if the array-length fact of ADR-0053 M8 is proved, state it as an
  element-initialised invariant (`forall i < len, written`).

Consequence for the table above: S5 is `TESTED_ONLY`, owner layer (b), resting on C3, C4, C5.

## S4 finding (ADR-0053 M2 decision)

**The gap.** The ownership verifier checks RC and ownership, not value shapes (field index against struct arity, struct against
array against string): the `ill` class that C3 says is not excluded. Finding F-shape realised it: `?` inside a mutating class
method returning `Result` returned a bare `Result` struct where the caller expected the `{ receiver, result }` pair; the
caller's `orin_struct_get` read past the end of the struct, and the ownership-correct MIR passed the verifier (docs/assurance.md,
F-shape). docs/mir.md lists "field/slot index bounds, tags, `ITag`/`IGetField` on the right union, builtin signatures" as not
checked (docs/mir.md, "Instruction rules"). The wf rules only check operand classes (`wf.or`, `tyClass`: `MRef` is one class for
structs, arrays and strings), so `CRef` locals carry no shape.

**Current mitigation (run time, `TESTED_ONLY`).**
- C: `orin_chk_slot` (`runtime/core/orin_runtime.h:391-393`) traps with `orin_trap_shape` when `o->kind != ORIN_K_STRUCT ||
  i >= nslots`; it guards `orin_struct_get`, `orin_struct_set` and `orin_struct_slot_ptr` (`orin_runtime.h:401-410`) and the slot
  copies at `orin_runtime.c:625-626`. Array slot access and push check the kind in the same way.
- LLVM: the same check in the inline helper `@orinl_slot` (call emitted at `compiler/backends/llvm/function.or:54`, comment at
  `:52`).
- The checks are elided only for an initialising store into the result of `orin_struct_new` with the constant arity of the same
  instruction (`orin_struct_init`, `orin_runtime.h:396`), and the unchecked array forms are gated by U1, which does not give
  shapes either (it justifies bounds of arrays built by `arraynew` in the function).
- Tests: `tests/next/run/shape_confusion_try_in_mutating_method.or` (C, ASan, LLVM) and `runtime/core/tests/runtime_test.c`.
  Cost about +23% selfcompile (`docs/benchmarks.md`). Policy (ledger F-shape): the checks stay on until the verifier proves
  shapes, then they may be omitted exactly where shapes are proven.

**Missing verifier rule (future work, ledger P0 "MIR shape/type check").** For every `IGetField`/`ISetField`/`ITakeField`/
`IPutField`/`ITag` operand a known struct type whose arity bounds the field index (and a consistent `refmask` for the slot's
class), for every array operation an array type, for every call the argument and result types of the callee's declared MIR
types (`locals[].ty` is available). Needs a shape lattice in `compiler/verify` (the join of two different shapes is an error),
the matching `ill`-exclusion in `check_sound`, and a differential test in `tools/diff_verifier_lean.py` (ADR-0053 M6b). Until it
lands, S4 stays `TESTED_ONLY` with the runtime backstop, owner layer (d).
