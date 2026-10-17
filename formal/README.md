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
* `Examples.lean`, `CallExamples.lean`: accepted and rejected programs by kernel evaluation.

## Not covered (stated, not proved)

* Struct shapes (static field counts): a field access out of range is a `trap`, which is safe; the
  model does not use shapes to rule it out.
* The entry function of `prog_sound` takes scalar and borrowed parameters only.
* A call demotes every `Unique` local to `Owned` (stricter than `compiler/verify`); callee locals left
  over at return are leaked (never freed, so never a use after free).
* Closures, vtables, strings, floats; the text format of `Exec.lean` and `tools/gen_mir_fragment.py`
  still cover the call-free fragment (the differential test is unchanged).
* `ill` (null or type confusion) is not excluded.
