# Formal memory-safety model (Lean 4)

Status: two fragments, fully machine-checked, no `sorry`, no extra axioms: the memory-IR
invariant (this file up to "Next steps") and the mechanised ownership analysis of MIR core with
its soundness theorem (last section).
Location: `formal/` (Lake project, Lean 4 core only, no Mathlib, toolchain pinned in
`formal/lean-toolchain`). Check with `formal/check.sh` (runs `lake build`, rejects
`sorry`/`admit`/`axiom`/`native_decide`/`unsafe`/`opaque`/`extern` in the sources, and audits
`#print axioms` for the headline theorems: only `propext`, `Quot.sound`, `Classical.choice`
appear). A clean build takes about 8 s.

This implements the first steps of the plan in `spec/07-formal-safety.md` for the **memory IR
layer** only: it models what the generated code does to reference counts, not the source
language and not the machine code.

## Where this sits in the spec 07 layering

| Layer (spec 07) | Status |
|---|---|
| Source core (typed calculus, progress/preservation) | Not started. |
| **Memory IR** (retain/release/make_unique/load/store discipline) | **This model**: invariant + preservation + no dead access + COW lemma, for the fragment below. |
| Native artifact (C codegen, C compiler, runtime, allocator) | Not modelled. TCB. |

Nothing here says that the compiler's code generator *emits* programs in the modelled
fragment, or that `runtime/core/orin_runtime.c` implements the modelled operations. Those
correspondences are unverified (see "Trusted computing base").

## What is modelled

Files in `formal/Orin/`:

| File | Content |
|---|---|
| `Heap.lean` | `Val` (scalar or `ref loc`), `Obj {rc, fields}`, `Heap` (partial map + allocation frontier), `bump` (retain a list of refs), `alloc`, `setObj`, `del`, `decRc`, and `refs H l` = number of references to `l` held in fields of live objects. |
| `Machine.lean` | State `St {heap, locals, pending}`, instruction set, one-step semantics `step`, reachability `Reach`. |
| `WF.lean` | Invariant `WF` and its preservation by every primitive operation (`wf_dupInto`, `wf_retain`, `wf_const`, `wf_release`, `wf_alloc`, `wf_store`, `wf_makeUnique`, `wf_drain`). |
| `Safety.lean` | Per-instruction preservation (`opX_wf`) and no-dead-access (`opX_not_dead`). |
| `Theorems.lean` | `step_wf`, `reach_wf`, `step_not_dead`, `run_safe`. |
| `View.lean` | `view`: the observable value of a reference; frame lemma `view_agree`. |
| `COW.lean` | Uniqueness facts, `makeUnique`/`store` COW lemmas. |
| `Final.lean` | `step_shared_only_store`, `makeUnique_store_run`, `wf_init`. |
| `Audit.lean` | `#print axioms` audit used by `check.sh`. |

### Runtime correspondence

| Model | Runtime (`runtime/core/orin_runtime.h`) |
|---|---|
| `Obj {rc, fields}` | `OrinObj` header + slots (string/array/struct kinds collapsed to "a list of slots"; `refmask`/`is_ref` are folded into `Val` being tagged scalar/ref) |
| `copy y x`, `load y x i` | `orin_dup(x)`; `orin_dup(slot i of x)` |
| `alloc x ys` | `orin_struct_new` + `orin_struct_copy_slot`/init with retained children |
| `retain x` | bare `orin_retain` (an owner that is never accounted: a leak) |
| `release x` + `drain` | `orin_release` -> `orin_destroy` releasing ref slots then freeing; modelled as an explicit worklist (`pending`), drained to empty before the next instruction |
| `makeUnique x` | `x = orin_make_unique(x)` (rc = 1: unchanged; else shallow copy with children retained, then drop one count of the old object) |
| `store x i y` | `*orin_struct_slot_ptr(x, i) = dup(y)` after `make_unique`, releasing the old slot |
| `trap` outcome | `orin_trap` (index out of range on load/store): a defined, safe failure |
| `bad` outcome | any access to a non-live location (`dead`), or an in-place `store` into an object with `rc != 1` (`shared`) |
| `ill` outcome | malformed IR (local index out of range, load from a scalar, branch on a reference); not a memory event, to be excluded by a verifier |
| `ite c t e` | branching on a scalar local |

Every local *owns* its value (the codegen convention "locals own their value"); the scalar
`int 0` marks a dead/moved-out local.

### The invariant `WF`

`WF s` (in `WF.lean`) states, for state `s`:

1. every live object has `rc > 0`;
2. **RC soundness**: for every live location `l`, `rc(l) >= owners(l)` where
   `owners(l)` = (number of owned locals equal to `ref l`) + (number of pending-release entries
   equal to `ref l`) + (number of fields of live heap objects equal to `ref l`);
3. locations `>= next` are not live (allocation frontier);
4. every local, every pending entry and every field of a live object is a scalar or a reference
   to a **live** location (no dangling reference).

**Deliberate deviation from "rc = number of owners".** We prove `>=`, not `=`. The real code
generator may leak (`docs/architecture.md`: early exits "may leak already-evaluated
temporaries - a leak, never a use-after-free"; "counts must never be too low; too high only
costs memory"). `>=` is exactly what use-after-free freedom needs and is preserved by leaking
transitions (`const` overwriting a reference, bare `retain`). Consequently **leak freedom is not
claimed** (consistent with spec 07: memory leak freedom is not implied by memory safety). An
exact-count (`=`) invariant for a leak-free fragment is future work.

## Theorems (all proven)

Operation-level preservation (`WF.lean`, `Safety.lean`):

* `wf_dupInto` - copy/load (`orin_dup` of a live value into a local) preserves `WF`.
* `wf_retain`, `wf_const`, `wf_release` - bare retain, scalar overwrite, move-to-worklist preserve `WF`.
* `wf_alloc` - allocation of a fresh object whose fields are retained live values preserves `WF`
  (the new location is fresh; no existing reference points to it).
* `wf_store` - in-place slot update (retain new value, push old value to the worklist) preserves `WF`.
* `wf_makeUnique` - the shared case of `makeUnique` (retain children, allocate copy, drop one
  count of the original, rebind local) preserves `WF`; the `rc = 1` case is the identity.
* `wf_drain` - one worklist step (decrement; at count 1 free the object and push its fields)
  preserves `WF`. This is the key "release never creates a reachable dangling pointer" lemma: when
  the freed object's count was 1, the invariant shows the popped entry was its only owner.
* `opConst_wf`, `opCopy_wf`, `opLoad_wf`, `opStore_wf`, `opAlloc_wf`, `opMakeUnique_wf`,
  `opRetain_wf`, `opRelease_wf` - the same, stated for the machine's instruction semantics.

Machine-level (`Theorems.lean`, `Final.lean`):

* `step_wf` / `reach_wf` - **preservation**: every `ok` step, hence every finite run, from a
  `WF` state ends in a `WF` state.
* `step_not_dead` / `run_safe` - **no use-after-free, no double free**: in a `WF` state, no step
  (instruction or worklist drain) ever produces `bad dead`; hence none along any run from a `WF`
  state. A second release of the same ownership unit would require the object to be already
  freed, which `WF` rules out.
* `step_shared_only_store` - the only other bad outcome, `bad shared`, can only arise from a
  `store` instruction.
* `wf_init` - the invariant is non-vacuous: the initial state is `WF`.

Uniqueness and value semantics (`COW.lean`, `Final.lean`):

* `opMakeUnique_unique` - after `makeUnique x`, `x` holds a reference to a live object with `rc = 1`.
* `store_after_makeUnique_safe` - a `store x i y` immediately after `makeUnique x` is neither
  `bad shared` nor `bad dead`.
* `makeUnique_store_run` - machine level: `makeUnique x; store x i y` on a `WF` state with empty
  worklist runs its first step to `ok` and its second step never to `bad`.
* `unique_facts` - if `x` owns an object with `rc = 1`, no other local, pending entry or heap field
  refers to it.
* `makeUnique_view` - `makeUnique` does not change the observed value of `x`.
* `store_frame` - a successful `store` through a count-1 local changes the observed value of **no
  other live value** (everything other than the reference held by `x`), and the object now holds
  the stored value in the slot.
* `makeUnique_store_cow` - **COW / value semantics**: after `makeUnique x; store x i y`, every
  other local `z` and every pending entry has exactly the same `view` (at every depth) as before.
  In particular an alias of the old object keeps observing the old contents.

Load forwarding (`Forward.lean`, ADR-0038 lever 2 T4, the facts behind verifier rule F1):
* `load_load` / `store_load` - a load of slot `i` of `x` after a load of the same slot into `y ≠ x`, or after a store of `y`
  into it, returns exactly the value of `y`.
* `store_frame_other_slot`, `store_frame_other_local` - a store into another slot of the same object, or through another local
  (which needs count 1, so it cannot be `x`'s object in a well-formed state), leaves every slot of `x` unchanged.
* `makeUnique_frame` - `makeUnique x` keeps every slot value of `x` (shallow copy).
Calls and array length are outside the model; F1 ends its scan at any call that receives the object. The verifier rules U2-U5 of MIR v2.7 (`unique-in` / `unique-out` across calls, ADR-0038 T5) are likewise outside the model: they need calls, which `Machine.lean` does not have. They are listed with the other rules not yet in the model (docs/tcb.md) and are not claimed as proved.

Unchecked array access (rule U1, MIR v2.6, ADR-0038 lever 2 T2) has **no lemma**: what it needs is "the kind and the length of the object a live
local holds are unchanged between two instructions unless the object is pushed to, popped, extended or the local redefined", and the model has no
arrays with a length (`Machine.lean`: `load`, `store`, `makeUnique` over fixed slot tuples) and no calls. It is listed with the other rules not
yet in the model (docs/tcb.md) and checked by the mutation corpus and `--assert-facts`, not claimed as proved.

The interval facts of U1 (T6, `compiler/verify/range.or`, docs/mir.md "Range facts") are outside the model for the same reason and for two more:
an interval abstract interpretation over `int` / `usize` locals (the model has no machine integers with traps, no widening, no branch refinement)
and the length of an array a borrowed call leaves alone. There is no lemma and nothing here is claimed as proved; the evidence is the code, the
mutation classes `range-*`, `compiler/tests/verify_main.or` and the run-time re-check of every unchecked access by `--assert-facts`.

`view H f v` (`View.lean`) is the depth-`f` structural unfolding of the value denoted by `v`:
scalars are themselves, a reference denotes the tuple of the views of its fields. Counts and
addresses are not observable. The statement is therefore the logical-snapshot semantics of
spec 06 (`const b = a; a.x = 1` leaves `b` unchanged), at the memory-IR level.

## What is proven vs assumed vs not modelled

Proven (for the modelled machine): the theorems above.

Assumed (stated as hypotheses or by construction, not established here):

* The program is a sequence of the modelled instructions with in-range local indices and
  scalar branch conditions (outcome `ill` is not analysed; a verifier must exclude it).
* `store` is only executed through a unique reference. In the *first* model only the pattern
  `makeUnique x; store x ...` is proven safe. For arbitrary programs, `store` into a shared object
  yields `bad shared`. The program-level theorem "a verifier-accepted program never does so" is now
  proven for a fragment of MIR, see "Mechanised ownership analysis" at the end of this file.
* Locations are never reused (`next` only grows). A real allocator reuses addresses; this is
  sound because `WF` says no reference to freed storage exists, but the model does not prove
  anything about the allocator.

Not modelled (all trusted computing base today):

* **Borrowed parameters** and calls. The codegen convention (params borrowed, returns owned)
  needs a call rule with a frame/borrow lemma: the caller's reference outlives the callee body.
  Here every local owns its value and there are no calls.
* Immortal objects (negative counts), string/array/struct kind distinctions, `refmask`,
  capacity/length of arrays, array bounds beyond the generic "slot index out of range => trap".
* Concurrency / atomics, task isolation; regions; graph handles (spec 06).
* Arithmetic traps and OOM (they are safe outcomes, not modelled).
* Counter overflow of `rc` (it is a `Nat`).
* Correctness of the code generator (it emits the modelled discipline), of the C compiler, of
  `orin_runtime.c` (it implements the modelled operations), of the allocator, and of the OS/FFI.
* Source-language typing: there is no progress or type-safety theorem; "well-typed implies the
  memory IR obeys the discipline" is the missing link between layers.
* Guaranteed termination of `drain` (finite acyclic heaps terminate; not stated, not needed for
  safety). Owning cycles are *allowed* by the model (e.g. a self-`store`); they leak, they are not
  unsafe, and `docs/architecture.md` argues they cannot arise from the source.

## Honest summary

The proven statement is: **in the modelled memory IR, if every owning reference is accounted for
by a count at least as large (and the state starts empty), then no instruction or release step
touches a freed or never-allocated location, release never leaves a dangling reference, and the
`make_unique` + in-place-store sequence neither violates uniqueness nor alters any value
observable through other references.** It is *not* a statement about the compiler or the native
artifact. Layer label: **memory IR, partial.**

## Next steps (suggested)

1. Calls and borrowed parameters (frame rule); function-return ownership transfer.
2. (done for a fragment, see the last section) A verifier (ownership + uniqueness analysis on the
   IR) with a proof that accepted programs never produce `bad`. Still open: `ill` (type/null
   confusion), progress theorem, calls, loops, arrays.
3. Exact accounting (`rc = owners`) for the leak-free fragment.
4. Arrays (slot count changes, push/pop), immortals.
5. Then the source core calculus and its lowering to this IR.

## Mechanised ownership analysis (MIR core): verifier-accepted code is memory-safe

Status: machine-checked (`formal/check.sh` passes; no `sorry`/`admit`/`axiom`; standard axioms
only), for a **structured fragment of MIR without calls, arrays or loops**. This closes part of the
open obligation "verifier-accepted MIR implies machine safety". It is a proof about a Lean
*transcription of the rules* in `docs/mir.md` (plus its implementation notes), **not** about the Orin
source in `compiler/verify/`: the correspondence Lean `check` <-> `rules.or`/`state.or`/`verify.or`
is manual and unverified (it is part of the trusted base, see "Findings" for the places where the
two differ).

### Headline theorem

`Orin.check_sound` (`formal/Orin/Top.lean`), in words: let `p` be a function accepted by the
checker `Orin.check`. Start the machine with the arguments in the first locals (reference arguments
are borrowed from the caller, see "Caller contract") and all other locals dead. Then **no reachable
machine step is `bad`**: no access to a freed or never-allocated object (so no use after free, no
double free, no use of an invalidated borrowed alias), and no in-place store (`setField`,
`putField`, `takeField`) into an object whose count is not 1 (so value semantics / COW is
respected). Corollaries `check_no_use_after_free` (`bad dead`) and `check_no_shared_store`
(`bad shared`). `ill` and `trap` outcomes are not excluded (see "What `ill` means").

### Theorems (all in the `Orin` namespace)

| Theorem | Plain-English statement |
|---|---|
| `check_sound` | accepted function + caller contract => no reachable step is `bad` (above) |
| `check_no_use_after_free`, `check_no_shared_store` | the two components of `bad` |
| `entry_inv` | the entry state satisfies the simulation relation under the caller contract |
| `check_cont` / `chk_cont` | the checker (`chk`, a function) yields a derivation `Cont` of acceptance, closed under weakening so it survives the join after an `if` |
| `sound_step`, `reach_inv`, `reach_safe` | from a configuration related to the abstract state, the next step is never `bad`; the successor is again related to some abstract state that still accepts the remaining code; hence along every run |
| `op_const`, `op_move`, `op_borrow`, `op_dup`, `op_release`, `op_alloc`, `op_getField`, `op_setField`, `op_putField`, `op_takeField`, `op_makeUnique` | per-instruction: if the abstract rule accepts the instruction in a related state, the concrete operation is never `bad` and any resulting state is related to the abstract successor |
| `drain_inv` | every step of the release worklist preserves the relation and is never `bad` (a freed object is never a `Borrowed` alias target, a `Unique` object, or a caller-anchored parameter) |
| `Inv.weaken`, `joinL_fle_left`, `joinL_fle_right` | the relation is monotone in the abstract state, and the join is an upper bound of both branches (soundness of the join rule) |
| `unique_excl` | a `Unique` local's object (count 1) is held by nothing else: no other counted local, parameter, borrowed alias, pending release, heap slot or caller reference |
| `wf_locals`, `wf_store_take`, `wf_alloc_take`, `wf_take` (`WFx.lean`) | the old invariant `WF` is preserved by count-*moving* operations (local -> slot, local -> fresh object, slot -> local, local -> local) |
| `ex*` / `bad*` examples (`Examples.lean`) | `decide`-checked: the checker accepts borrow/dup/release, COW update, take/put, `if` with agreeing branches; rejects double release, store into a duplicated (non-unique) object, borrowed alias used after its root is released, release/store through a parameter, `make_unique` or `move` on a borrowed alias, divergent join, open hole at return |

### Files

`Mir.lean` (instructions, concrete operations, step relation) -> `Check.lean` (abstract state, rules,
holes, join, `chk`/`check`) -> `Proj.lean` (projection + relation `Inv`) -> `Sim1-7.lean` (lemmas and the
per-instruction preservation proofs; `Sim7` = release worklist) -> `Weaken.lean` (weakening, join) ->
`Sound.lean` (acceptance derivations, single step, runs) -> `Top.lean` (entry state, headline
theorem) -> `Examples.lean`. `WFx.lean` adds count-moving preservation lemmas to the first model's `WF`.

### The fragment

Straight-line code with structured `if`/`else` and a continuation (`Code`), over the machine of
`Machine.lean` (same heap, `WF`, release worklist).

| MIR | Lean | Notes |
|---|---|---|
| `ICopy` of a scalar | `const` | scalar only; `OStr` immortals not modelled |
| `IMove` | `move` | |
| `IBorrow` | `borrow` | uncounted alias, no retain |
| `IDup` | `dup` | retain |
| `IRelease` | `release` | pushes the count on the worklist; freeing is `drain` |
| `IStructNew` | macro `Code.structNew` = `alloc d n` + `setField d i yᵢ` | operands consumed left to right; operand = destination rejected (see Findings) |
| `IGetField` | `getField d o i isRef` | no retain; `isRef` = static class of `d` (borrowed result vs scalar) |
| `ISetField` / `IPutField` | `setField` / `putField` | same concrete operation (store, release old slot); differ in the hole rule |
| `ITakeField` | `takeField` | slot becomes `int 0`, count moves to the destination |
| `IMakeUnique` | `makeUnique` | the old model's `opMakeUnique` |
| `TBranch`, join | `Code.ite` (condition = an `Init` scalar) | branches then continuation; the checker joins |
| `TReturn` | end of code | no hole may be open (error); leaks are not tracked (warnings only in the verifier) |
| parameters | initial kinds `Param` (reference) / `Init` (scalar) | borrowed for the whole body; never redefined |

Abstract state per local: `dead | init | owned | unique | borrowed src | param | poison` (`poison`
merges `MaybeDead`/`MaybeLeak`) plus the set of open holes `(local, slot)`. Rules are one transfer
function per instruction (`stepL`, kinds; `stepH`, holes), a semilattice join (`jk`/`joinL`) and
`chk`. All rules of `docs/mir.md` for the instructions above are covered, including: `Borrowed(x)`
invalidation on release/move/consume/redefinition and on every mutating op (`setField`, `putField`,
`takeField`, `makeUnique`); `Unique` demotion to `Owned` on `dup`/`borrow`; `Unique` required for
`setField`/`takeField`/`putField`; the hole discipline; borrow roots (`rootOf`, borrowed-of-borrowed
takes the root); the join rules (equal states stay, `Owned`/`Unique` join to `Owned`, everything else is
poisoned, `Borrowed` sources must agree).

**Not covered** (each is a gap in the claim "verifier-accepted MIR is safe"): `ICall`/`IBuiltin` and
the call/`Unique` demotion rule, the interprocedural caller side of the contract below; loops and
back edges (the worklist fixpoint of `verify.or` and its termination), `TSwitch`/`TGoto` as an
unstructured CFG (the model has only if/else; a switch is an `ite` chain); arrays (`IArray*`,
symbolic hole keys), strings (`IStrAppend`, `OStr`, the `Imm` kind, `INullary`), scalar ops
(`IUnary`/`IBinary`/`ITag`, they do not touch ownership), the `MaybeLeak`/`MaybeDead`
distinction and leak warnings, the well-formedness pass beyond index ranges and operand classes
(modelled as in-range checks and the kind classes), `TTrap`. Also not covered: the correspondence
of the model with `runtime/core/orin_runtime.c`, the code generator and the Orin implementation of the
verifier (manual transcription).

### The simulation relation `Inv ext a s` (`Proj.lean`)

Abstract state `a` (kinds) and concrete state `s` are related by:

* **RC soundness on the counted owners.** `projL a locals` keeps exactly the locals that `a`
  marks `Owned`/`Unique` (all others read as the dead marker), `Pst` adds the worklist and a fixed
  list `ext` of the caller's references. The first model's `WF` holds for this projected state:
  every live object has `rc >= (counted locals) + (worklist entries) + (heap slots) + (caller refs)`.
  So the proof reuses `wf_drain`, `wf_dupInto`, `wf_makeUnique`, ... of the first model.
* `Init` locals hold scalars; every reference-kind local holds a reference.
* `Unique x`: `x` holds a reference to a live object with count 1 (then `unique_excl`: nothing else
  refers to it).
* `Borrowed r` at `i`: `r` is a root (`Owned`/`Unique`/`Param`) holding `ref p`, and local `i`'s
  value is `p` itself or lies in a slot of an object reachable from `p` (`Desc`); if `r` is `Unique`
  the alias is not the root's own whole object. Hence a borrowed value stays live as long as no
  object on its chain is mutated or freed. Chains are never mutated by `setField`/`takeField`/
  `drain` because every chain object has an owner other than the unique local or the worklist entry
  involved (`desc_owned`, `hD_unique`).
* `Param`: the value is a caller-anchored reference, see below.

The release worklist is not part of the abstract state: `drain_inv` shows its steps preserve the
relation at any abstract state.

### Caller contract (entry condition)

`entry_inv`: the first `|params|` locals hold the arguments, other locals are dead, and there is a
list `ext` of references owned by the caller (`WF <H, ext, []>`, i.e. the heap counts them) such that every
reference argument is `ref l` with `l` below some `q` in `ext` (`Desc H q (ref l)`, in particular `l`
itself in `ext`); scalar parameters are scalars. This models "borrowed for the whole call": either an
owned caller local, or an uncounted alias of something below one (e.g. `f(x.field)`). It is an
*assumption*; there is no call rule, so it is not discharged for any real call site.

### What `ill` means (not excluded)

`ill` marks outcomes that are not memory events in the model but would be in C: a field read whose
slot class disagrees with the destination class (scalar into a reference local or vice versa), a
`takeField` of a scalar slot, and (via the hole discipline) a read of a slot that was emptied by
`takeField`. MIR has no field types (`docs/mir.md`: "Not checked: field/slot index bounds, tags"),
so **memory safety of the compiled program additionally rests on the well-typedness of the lowering
(HIR types)** for slot classes, and on the hole discipline for null slots. The theorem proves only
that these are the *only* ways for an accepted program to go wrong (together with `trap`, the
defined bounds trap): everything else is excluded by the ownership analysis alone.

### Findings (discrepancies and sharpened rules)

1. **Self-rooted borrow (verifier more permissive than the proof).** `IGetField(d, d, i)` with `d`
   `Owned`, and `IBorrow(d, s)` with `s` `Borrowed(d)`, make `rules.or` compute the root *before*
   redefining `d`, producing `Borrowed(src = d)` on `d` itself (with a leak warning for the old
   owned reference). Neither `docs/mir.md` nor `wf.or` excludes it (`wf.or` only requires distinct
   locals for `IBorrow`, not for `IGetField`). The old owner's count is leaked, which keeps the
   chain alive, so it is very likely benign (I could not construct an exploit), but it violates the
   documented invariant "`Borrowed(src)`: `src` is a local or `Param`" and falls outside what is
   proven: the Lean checker rejects it (`rootOf src ≠ d`). Either reject it in `rules.or`/`wf.or`
   (one comparison) or extend the invariant with a "leaked root" kind.
2. **The role of the hole rules is null-dereference, not use-after-free.** `docs/mir.md` says a
   hole "would leave a dangling slot". The runtime (`orinc_mir_struct_take`) writes `0` into the
   slot, and `orin_release`/`orin_destroy` are null-safe (`if (o && o->rc > 0)` / `DEC`). The theorem
   needs none of the hole rules for `bad`; they guard reads of the emptied slot (a null
   dereference), which the model reports as `ill`, which is not proven absent (see above). The
   document should say "null slot", and the "open hole at return" rule is a functional-correctness
   rule (the caller would observe a null field), not a use-after-free rule.
3. **The `Unique` demotion on `IBorrow`/`IDup` is necessary, not merely conservative.** Without it
   `x = Unique; b = borrow x; d = dup b; setField x ...` gives `bad shared` (count 2 on an object
   believed unique). The proof isolates why: the relation has the invariant that a `Unique` root has
   no whole-object `Borrowed` alias, and it holds only because `borrow` demotes the root. (Same
   statement as the table in `docs/mir.md`; the proof shows it cannot be dropped.) By contrast the
   invalidation of `Borrowed(x)` on `makeUnique` is not needed for safety (aliases of the old
   object's children remain valid in the copy), it is a harmless conservative choice.
4. **Join rule needs one more side condition, implied by an invariant.** `docs/mir.md`: "`Borrowed(src)`
   must have equal `src` on all paths". For the proof the join must also leave `src` a root kind
   (otherwise a borrowed alias would be rooted at a poisoned local). On reachable states this is
   automatic (a local that is `Param` on one path is `Param` on all, a borrowed alias's root is live
   on both), so the verifier is fine; the Lean `joinL` states it explicitly (`postK`).
5. **`ISetField`/`IPutField` with `v = x` is rejected by `wf.or` (`valueOk`) but not mentioned in
   `docs/mir.md`.** It is harmless for safety (the stored object becomes a self-cycle: a leak).
   The model keeps the restriction.
6. **`IStructNew` with an operand equal to its destination** (`d = Some(d)` style) is accepted by
   `rules.or` (operands are consumed, then `d` defined). The model expands `IStructNew` into
   `alloc d` + `setField d i y` and therefore rejects it. This is a restriction of the model, not a
   known unsoundness; to cover it, model `IStructNew` as one instruction.
7. **No call rule, hence the caller contract above is an assumption.** The `Param` rule is sound
   *given* the contract; nothing here checks that call sites establish it (a caller passing an
   alias of something it already invalidated, or a `Unique` it later mutates during the call).
   The documented call rule ("a `Unique` argument is demoted to `Owned` when the result is a
   reference") is exactly the part not mechanised.

### Reading and trusting this

To audit the claim read `Mir.lean` (concrete operations: do they model the runtime calls?),
`Check.lean` (do the rules match `docs/mir.md` / `rules.or`?), the statement of `check_sound`
and its contract in `Top.lean`; the rest is proof. A differential test of the Lean `check` against
`compiler/verify` on generated MIR (the structured fragment) would close most of the manual-
transcription gap.

### Executable checker and differential test (C4)

`formal/Orin/Exec.lean` makes `Orin.check` executable (`lake build orin_check`, binary
`formal/.lake/build/bin/orin_check`). It parses programs of the fragment above in a line-based text
format (`prog NAME N PARAMS`, one mnemonic per line, `if C` / `else` / `end`, `endprog`) and prints
`ACCEPT` or `REJECT <first rejected instruction>` per program. The verdict is `Orin.check` itself; the
parser and the reason report (`diag`, which reuses `stepA`/`joinS` and is cross-checked against
`check` at run time) are the only new code. No definition, theorem or proof was changed; the
escape-hatch scan and the axiom audit of `check.sh` cover `Exec.lean`.

`tools/gen_mir_fragment.py` generates random programs of exactly the fragment (deterministic seed;
a small tracker biases the sampling so that about 40 percent of programs are accepted, and 10 percent of the
steps ignore it) in two forms: the Lean text and the textual MIR printed by `orin mir`.
`compiler/tests/verify_text.or` is a batch driver that parses that MIR text and runs the real
`compiler/verify`. `tools/diff_verifier_lean.py` runs both on N programs plus two random prefixes of
each (so the position of the first fault is compared, not only its existence) and compares the
ACCEPT/REJECT verdicts. CI (`formal` job) runs it with 4000 base programs, 12000 checks in total, in about 10 seconds
(the compiler for the driver comes from the seed, `tools/bootstrap.sh --seed-only`).

What it showed (seed 20261013 plus a one-off run of 120000 programs with seed 7): the verdicts agree
on every program, with exactly one class of divergence, Finding 6 (`IStructNew` whose operand list
contains its destination): **the verifier accepts, the model rejects**. This is the dangerous
direction; it is allow-listed in the tool, and the allow-list entry only excuses a divergence if the
Lean verdict on a rewritten program (`release d`, then the struct without `d`, which has the same
abstract effect) equals the verifier's verdict. The rewrite shows that the *abstract* rule matches; the concrete memory
safety of this construct (the count of `d` moves into the new object's slot, `d` is overwritten)
is plausible but not covered by `check_sound`. No divergence in the other direction was found, and
nothing else was found in 120000 programs, including after the fix of Finding 1. Finding 5
(`setField`/`putField` with `v == x`) is not a divergence: `wf.or` and the model both reject it.
Sanity check of the test itself: removing the `Unique` demotion from the verifier's `IDup` rule is
detected (5 diverging programs among 2000).

Limits: the generator produces class-correct programs only (the model has no types); no calls,
loops, arrays, strings, `Imm`, owned parameters or `MaybeLeak`/`MaybeDead` distinction; the verifier's leak warnings
are not compared. The tracker used by the generator is a third transcription of the rules, used for
sampling only. A differential test samples; it does not prove that `compiler/verify` implements `check`.

Mutation corpus (`tools/mutate_mir.py`): see `docs/assurance.md`. It takes the optimised MIR of the conformance
programs, injects single ownership bugs (drop or duplicate a release, read after release / move /
consumption, store through a duplicated or borrowed reference, drop a `makeUnique` before a store,
release or move a borrowed parameter, release a borrowed projection, drop a `dup`) and requires the
verifier to reject (leak-class mutants: to warn). Mutants that are semantically benign at the site
(an immortal literal that is released, a leak on a path that only traps, a `makeUnique` of an
object that is already unique per an independent dataflow in the tool) are classified with a reason and
counted separately.

### Status of findings (lead, 2026-10-13)
- Finding 1 (self-rooted borrow) — **fixed** in `compiler/verify/rules.or` (`defBorrow` rejects a
  borrow whose root is its own destination) with two regression cases in
  `compiler/tests/verify_main.or`; the compiler and all test programs still verify (0 errors).
- Findings 2–7 — documentation/model notes; tracked, no code change yet.

### Resource handles (ADR-0025): outside the Lean model
`MHandle` locals and their open/close discipline (`docs/mir.md` v1.8, "Resource handles") are implemented in
`compiler/verify` but are **not** modelled in `formal/`: the Lean MIR has no handle type, no `BFileOpen` /
`BFileClose`. They do not interact with the RC rules (a handle is a scalar, never counted, never an owner), so
C1-C3 are unaffected, but the handle guarantee (assurance row C14) is `TESTED_ONLY`: 31 hand-built MIR cases and
the conformance suite. Extending `Check.lean` with a linear "open set" is a small, self-contained proof target.

## L0 platform layer (spec 19 R2)

`runtime/platform/orin_platform.{h,c}` is the closed list of primitives through which the runtime touches the OS and
libc (700 code lines, 1,100 lines including contracts and comments; the budget of 1,000 counts code lines, ADR-0030). Each function has an ACSL-style block (`requires`,
libc (budget: 1,000 code lines, contracts and comments excluded). Each function has an ACSL-style block (`requires`,
`ensures`, `assigns`; pseudo-locations `\stdout`, `\stdin`, `\fs`, `\process`). **No tool has checked these
blocks as ACSL** (Frama-C/WP was not tried); they are the written specification and the intended input for R4.

What is established today, by label (spec 07):

| Function group | Label | Evidence |
|---|---|---|
| `mem_copy/move/set/cmp` (inline wrappers over libc), `alloc/realloc/free` | bounded-verified against their contracts, *assuming CBMC's model of libc `memcpy`/`memmove`/`memset`/`memcmp`/`malloc`/`realloc`* | `harness_mem`, `harness_alloc` (arrays up to 6 bytes, allocation size up to 8; contents nondeterministic; success and failure of `malloc` both explored; frame conditions checked for `mem_move`) |
| `mem_find` | bounded-verified (plain C loops, no libc): first occurrence / NULL exactly as in the contract | `harness_mem_find`: haystack and needle up to 6 bytes, all contents |
| `fmt_u64`, `fmt_i64` | bounded-verified: 1..20 digits, no leading zeros, sign, digits read back to the value, no buffer overrun, no overflow (negation done without wrapping) | `harness_fmt_*`: all values with magnitude < 10^6; `harness_fmt_extremes`: `UINT64_MAX`, `INT64_MAX`, `INT64_MIN`, 0, -1. A full 64-bit nondeterministic run did not finish in 20 minutes (SAT blow-up of 64-bit division), so values >= 10^6 are covered by those concrete extremes, a 689-check test and the self-compile, not by the solver |
| `thread_create/join/exit/id`, `monitor_new/free/lock/unlock/wait/notify/get/set/grow`, `runtime_lock/unlock` (ADR-0017 stage 0), the stdout lock inside `write/write_line/flush` | **tested only** | contracts in the header; `platform_test.c` (54 checks): handle validation (stale, forged, joined twice, freed), the lock discipline (`get`/`set` need the lock, relock refused, unlock by a non-holder refused), mutual exclusion of 8 threads x 5,000 increments, two condition queues with `notify_one` / `notify_all`, a thread that ends holding a monitor, concurrent stdout; the same under **ThreadSanitizer** (`tools/verify_platform.sh`). CBMC cannot model threads and mutexes, so there is no bounded proof; a proof needs a concurrency-aware C verifier and an OS model |
| `init, arg_count, arg, getenv, at_exit, exit, abort, shell`, `write, write_line, flush, stdin_read, stdin_getc`, `file_read/write/exists`, `stream_open/read/getc/write/flush/error/close` (ADR-0025), `error_message` | **tested only** | `runtime/platform/tests/platform_test.c` (689 checks): error paths (missing file, directory, NUL in path, unwritable directory, `/dev/full`, short read, EOF stickiness, byte 0xff vs EOF), ordering of stdout/stderr, exit flushing, abort signal, shell statuses, `at_exit` order; also run under ASan+UBSan. CBMC cannot say anything useful about stdio/stat/system (stubs), so these wrap-the-OS functions are trusted |

Reproduce: `tools/verify_platform.sh` (tests, size budget, boundary check, CBMC when installed: `apt install cbmc`,
version 5.95.1 used; about 3 minutes; `REQUIRE_CBMC=1` makes a missing CBMC an error). The boundary between
the layers is machine-checked syntactically by `tools/check_platform_boundary.sh` (no direct libc call or
non-freestanding include in `runtime/`); that check is a grep-level guard, not a proof (e.g. inline assembly or a
function-pointer to libc would not be seen).

Limits, stated plainly: the bounds are small; CBMC checks the C as compiled for the host data model (LP64);
the platform functions may now be called from several threads (ADR-0017: the stdout buffer is locked, the thread / monitor tables have their own locks), which only the ThreadSanitizer runs examine; `error_message` returns `strerror`'s buffer; the contracts of the OS-facing
functions are not proved; and L1 proofs may only assume these contracts as axioms for the functions labelled
tested only.
