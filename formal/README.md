# formal/: Lean model of the Orin ownership checker

Build and audit: `./check.sh` (builds, rejects `sorry`/`axiom`/..., prints `#print axioms` for the headline theorems).

## What `check_sound` and `prog_sound` cover (ADR-0053 M6)

* `Top.lean`, `check_sound`: one function, scalars, structs (fields, `makeUnique`, take/put), arrays with
  length and bounds-checked access (`SimArr.lean`, `arrayGet_oob`), structured `if` and `loop`
  (invariant by iterated join, `loopFix_spec`, `Cont.seq`). No `bad` step is reachable.
* `CallTop.lean`, `prog_sound`: a program of functions accepted by `pcheck` (every function passes `fcheck`
  against the signatures of all functions). Calls take scalar, borrowed and owned parameters and return a
  scalar or an owned reference (`Call.lean`, `CallRun.lean`, `CallStep.lean`). The proof is modular:
  the callee runs on a fresh frame whose anchors are the caller's counted locals (`inv_entry`); while it
  runs nothing the caller reaches changes (`Frozen`, `frozen_step`); on return the caller's relation
  is re-established (`inv_ret`); `good_step` is the invariant over the whole stack.
* `Hole.lean`, `Typed.lean`, `TypedOps.lean`, `TypedSound.lean`, `TypedTop.lean`: struct shapes.
  A field access out of range is `ill` in the machine (array out of range stays a `trap`). A fresh
  struct opens one hole per slot (`alloc`); every open hole's owner is `Unique` (`HU`). The type
  pass `tcode` plus `check` gives `check_sound_ill`: no reachable step is `ill` or `bad`. The
  invariant `TInv` (typed locals, typed objects with a ghost `hty`, null reference slots only in
  open holes) is carried by `sound_stepT` along the same `Cont` derivation as `sound_step`.
  The model is stricter than the verifier: a call needs an empty hole set, arrays hold scalars.
* `Examples.lean`, `CallExamples.lean`: accepted and rejected programs by kernel evaluation.

## Not covered (stated, not proved)

* The entry function of `prog_sound` takes scalar and borrowed parameters only.
* A call demotes every `Unique` local to `Owned` (stricter than `compiler/verify`); callee locals left
  over at return are leaked (never freed, so never a use after free).
* Closures, vtables, strings, floats; the text format of `Exec.lean` and `tools/gen_mir_fragment.py`
  still cover the call-free fragment (the differential test is unchanged).
* `ill` (null or type confusion) is excluded only by `check_sound_ill` for one function without calls;
  `prog_sound` (calls) still excludes only `bad`. Extending the type pass to calls needs signature
  types, a typed call frame and a typed `StkI`.
* The type pass `tcode` has no counterpart in `compiler/verify`; it takes the shape table and local
  types as given (no inference).
