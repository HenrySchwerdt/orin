# Formal memory-safety model (Lean 4)

Status: first fragment, fully machine-checked, no `sorry`, no extra axioms.
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
fragment, or that `runtime/orin_runtime.c` implements the modelled operations. Those
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

| Model | Runtime (`runtime/orin_runtime.h`) |
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

`view H f v` (`View.lean`) is the depth-`f` structural unfolding of the value denoted by `v`:
scalars are themselves, a reference denotes the tuple of the views of its fields. Counts and
addresses are not observable. The statement is therefore the logical-snapshot semantics of
spec 06 (`const b = a; a.x = 1` leaves `b` unchanged), at the memory-IR level.

## What is proven vs assumed vs not modelled

Proven (for the modelled machine): the theorems above.

Assumed (stated as hypotheses or by construction, not established here):

* The program is a sequence of the modelled instructions with in-range local indices and
  scalar branch conditions (outcome `ill` is not analysed; a verifier must exclude it).
* `store` is only executed through a unique reference. Only the pattern `makeUnique x; store x ...`
  is proven safe. For arbitrary programs, `store` into a shared object yields `bad shared`; a
  program-level theorem that a verifier-accepted program never does so is **not** proven (it is
  the OIM verifier's job, spec 07 item 5).
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
2. A tiny verifier (typing judgment on the IR: ownership + uniqueness certificate) with a proof
   that accepted programs never produce `bad` or `ill`; progress theorem.
3. Exact accounting (`rc = owners`) for the leak-free fragment.
4. Arrays (slot count changes, push/pop), immortals.
5. Then the source core calculus and its lowering to this IR.
