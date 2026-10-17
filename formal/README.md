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
* `TypedCall.lean`: typed calls. `tcode` accepts `call d f args k` against typed signatures
  (`TSig`: parameter types, result type); `tpcheck` is `pcheck` plus the type pass on every function
  against the signatures derived from the per-function local types, plus three static facts tying
  parameter modes to types. `prog_sound_ill`: no reachable step of the whole call stack, at any depth,
  is `ill` or `bad`. The proof reuses the `Frozen`/`good_step` structure of `Call*.lean`: `GoodT` is
  `Good` plus the type invariant of the running frame and `StkIT`, a typed copy of the stack invariant
  (every suspended caller keeps its local types, its locals stay typed w.r.t. the current ghost typing,
  which only grows: `HyExt`).
* `Examples.lean`, `CallExamples.lean`: accepted and rejected programs by kernel evaluation.

## Not covered (stated, not proved)

* The entry function of `prog_sound` takes scalar and borrowed parameters only.
* A call demotes every `Unique` local to `Owned` (stricter than `compiler/verify`); callee locals left
  over at return are leaked (never freed, so never a use after free).
* Closures, vtables, strings, floats; the text format of `Exec.lean` and `tools/gen_mir_fragment.py`
  still cover the call-free fragment (the differential test is unchanged).
* `ill` (null or type confusion) is excluded by `check_sound_ill` (one function, no calls) and by
  `prog_sound_ill` (calls); the typed-entry hypotheses are as for `check_sound_ill`, the entry function
  takes scalar and borrowed parameters only, and a call needs an empty hole set.
* The type pass `tcode` has no counterpart in `compiler/verify`; it takes the shape table and local
  types as given (no inference).

## Interval analysis (ADR-0053 M8): rules R1-R5 and U1 of `compiler/verify/range.or`

Model only, but a transcription of the algorithm, not of its effect: `Range*.lean` define the
interval domain (sentinels `NEG`/`BIG` as "no bound"), the abstract transfer `step`, the refinement
`refine`, the worklist `feed`/`procBlock`, `joinInto` with widening to a threshold, the narrowing
round `narrowAt` and the access test `accessOk`, and prove them sound against an **array-length
model** `len : Nat -> Option Nat` (the machine's `Obj.fields.length`; `lensOf`, `Rel`, `u1_machine`).
Array contents are not tracked. A ghost bit `ctd x` says that the local holds a counted reference.

| File | Content |
|---|---|
| `Range.lean` | R1: `Iv`, `Mem` (the meaning of an interval), classes; R2 bound arithmetic `r2_add`, `r2_sub` (with the clamping); hull, `widenHi`, `widenLo` |
| `RangeStep.lean` | the instruction subset `RI`, `step`, `destroy`, `assign`, `arith`, `capHi`, `raiseLo`, `less`, `atMost`, `same`, `refine` |
| `RangeSem.lean` | the frame `CS`, `Exec` (one instruction), `SoundS` (what a state says), `GenOK` (the contract of calls) |
| `RangeXfer.lean` | `exec_summ`: what every instruction does to the frame (untouched locals, kept counted arrays) |
| `RangeRes.lean` | R2: `res_ok` (the defined local is in the computed interval), `res_dd` (a feasible execution is never judged dead) |
| `RangeStepSound.lean` | `step_sound`: one step preserves `RunSound` (intervals, fact destruction, recorded comparison) |
| `RangeEdge.lean` | R3: `refine_sound`, `edge_sound` (every edge an execution takes is live); `Term`, `Taken`, `RunI`, `runA_sound` |
| `RangeJoin.lean` | R4: `Cov` (the order), `joinInto_cov_right/left`, `widenLo_mem`, `widenHi_mem` (sound for every threshold list), `hullAll_cov`, `soundS_cov` |
| `RangeCfg.lean` | `Fn`, `Reach`, `PostFix`, `postfix_sound` |
| `RangeFix.lean` | the worklist: `WReach`, `WInv`, `feed_spec`, `fix_sound` (when the iteration ends, for **every** pop order, threshold list and widening delay) |
| `RangeNarrow.lean` | `NarrowRel`, `narrow_sound` (strong induction on the block index), `accessOk`, `inRange_sound` (U1), `u1_sound`, `range_accepted`, `u1_machine`, kernel-evaluated examples |

Headline statement: `range_accepted` + `u1_sound`: for a function whose worklist iteration ended
and whose narrowing round ran, an instruction that `accessOk` accepts at its program point
(`accessOk fn.cls (runA fn.cls pre (state of the block)) ins`) is in bounds in every execution that
reaches it: the array local holds a live array with `n` slots and the index is a value in `[0, n)`
(`InBounds`); `u1_machine` turns that into `iv.toNat < ob.fields.length` for the machine state, so
the bounds check of `opArrayGet` (`arrayGet_oob`) cannot fire.

### Abstractions (every one stated)

* **Instruction set.** `RI` has copy, move, forward, `arraynew`, `arr.length`, add, sub, comparison,
  get, set, `makeUnique` and `gen`. `gen` stands for every other instruction (calls, builtins, field
  operations): it is described by the local it defines (`dst`), the locals it mentions (`men`), the array
  operands it keeps (borrowed positions, `kept`) and the in/out receiver it redefines (`recv`).
* **The contract of `gen` (assumed).** `GenOK`: an unmentioned local keeps its value; a counted
  reference keeps its object, alive and with the same number of slots, unless the instruction mentions
  the local and does not keep it. This is what `Frozen`/`frozen_step` (ownership model) establish for
  borrowed arguments, but it is **not derived from the ownership model here**; it is the one bridge
  between the two Lean developments that is stated, not proved. `exec_summ` shows the other
  instructions meet it.
* **Integers** are mathematical; overflow, underflow and bounds traps stop the execution, so a trap has
  no successor. A `usize` is never negative (`Cls.okv`; `wf.or`). Every written value respects the class
  of its local.
* **Entry.** The entry frame has legal scalar values; references are arbitrary (no fact).
* **Branch.** A two-way branch on a bool local; edge 0 is taken when the local is nonzero. Other
  terminators are `other ss`, any listed successor.
* **Worklist.** The pop order is any (the implementation pops the last); `thr` and the widening delay
  `wa` are parameters (the implementation derives them from the function). Termination is not modelled
  (partial correctness: a run that does not end yields no table and justifies nothing). `joinMoved` is
  the implementation's `changed` flag.
* **Narrowing** is stated by its defining equation (`NarrowRel`): block `b` sees the new states of the
  earlier blocks and the old states of the others.
* **Well-formedness the proofs take from `wf.or`**: the index operand of an access is a scalar
  (`IdxScalar`); an instruction is executable only when its operand classes are right (`Exec` carries
  the class conditions).
* **Not modelled.** The dominated-by-check source of U1 (T2, `unchecked.or`), array contents, the
  cost guard `MAX_CELLS` (refusing is sound), the equality of the Orin code with this transcription
  (C4 level), and the emitters.
