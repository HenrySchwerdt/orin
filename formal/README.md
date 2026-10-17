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
Array contents are not tracked. A ghost bit `ctd x` says that the local holds a *pinned* reference: counted, or lent by the caller for
the whole call (a `Param` local, `AS.pinned`).

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
| `RangeDom.lean` | T2 dominated-by-check: the scan of `unchecked.or`/`scan.or` (`verdict`, `scan`, `domOk`), `source_inb`, `pass_inb`, `dom_sound`, `t2_sound`, `t2_block`, `t2_machine` |
| `RangeTerm.lean` | termination: `Valid` (bounds stay in the lattice, `valid_step`, `valid_outEdge`), the measure (blocks without state, changes before widening, position of the bounds among the thresholds, length of the worklist), `feed_dec`, `wstep_dec`, `fix_acc`, `fix_total` (the iteration reaches an empty worklist, whatever the pop order, and the table is sound), `fix_every_run_ends`, `u1_total` |
| `CallGen.lean` | `Site`, `StkW`, `GoodW`: the call-machine invariant with explicit call-site data; `goodW_step`, `goodW_reach` |
| `CallLink.lean` | `callRI`, `RetGenOK`, `ret_genok`, `RetGenOK.exec`, `prog_ret_genok`: the contract `GenOK` of a call derived from the ownership model |
| `OpLen.lean` | `mop_len`, `drain_len`, `mstep_len`: no builtin and no release step changes the length of an array behind a counted local; `mstep_len_param`, `mstep_len_pinned`: the same for a `Param` local (`Frozen`) |
| `RangePin.lean` | T2 for a borrowed-only array parameter: `PinA`, `KeptI`, `pinA_exec`, `reachP_pin`, `held_of_pin`, `t2_param` |

Headline statement: `range_accepted` + `u1_sound`: for a function whose worklist iteration ended
and whose narrowing round ran, an instruction that `accessOk` accepts at its program point
(`accessOk fn.cls (runA fn.cls pre (state of the block)) ins`) is in bounds in every execution that
reaches it: the array local holds a live array with `n` slots and the index is a value in `[0, n)`
(`InBounds`); `u1_machine` turns that into `iv.toNat < ob.fields.length` for the machine state, so
the bounds check of `opArrayGet` (`arrayGet_oob`) cannot fire.

Termination (`fix_total`, `u1_total`): on a function that meets `FnOk`, **every** run of the worklist
iteration ends (`fix_acc`: the step relation is well-founded on the reachable configurations; a
configuration with a queued block always has a successor), for every pop order, threshold list `thr`
and delay `wa` (so for `WIDEN_AFTER = 2` and the thresholds of `thresholds(f)` of `range.or`, whatever
they are). The measure is the lexicographic tuple (blocks without in-state, changes the blocks may
still have before they widen, position of the bounds in the finite set of thresholds, length of the
worklist). The invariant `Valid` (a lower bound is never below the floor of its class, an upper bound
never above `BIG`; `valid_step`, `valid_edgeIv`) is what makes a widened bound move strictly, and
needs `ArrOk` for `arrayNew`. The narrowing round (a finite pass) is not part of the theorem: it is
given by `NarrowRel`.

### Abstractions (every one stated)

* **Instruction set.** `RI` has copy, move, forward, `arraynew`, `arr.length`, add, sub, comparison,
  get, set, `makeUnique` and `gen`. `gen` stands for every other instruction (calls, builtins, field
  operations): it is described by the local it defines (`dst`), the locals it mentions (`men`), the array
  operands it keeps (borrowed positions, `kept`) and the in/out receiver it redefines (`recv`).
* **The contract of `gen` (derived for calls, builtins at the machine level).** `GenOK`: an unmentioned
  local keeps its value; a counted reference keeps its object, alive and with the same number of slots,
  unless the instruction mentions the local and does not keep it. It is **no longer an assumption of
  the range proof for calls**: `CallLink.lean` proves it from the call machine. `CallGen.lean` states
  the stack invariant with the call-site data explicit (`Site`: the caller's kinds, operands, locals and
  heap at the call; `GoodW`, preserved by every step, `goodW_step`, implies `Good`). `ret_genok`: at the
  return of a call the caller's frame stands in the relation `GenOK` to the frame before the call, for
  the instruction `callRI d args ps` (defines the result local, mentions the operands, keeps the
  borrowed ones); `RetGenOK.exec` reads it as an `Exec.gen` step and `prog_ret_genok` states it for
  every return in a run of a `pcheck`-accepted program. The proof uses what `Frozen` gives (the
  caller's counted locals are anchors of the callee's frame, the objects they reach keep their slots)
  and that only the owned operands and the result local are cleared or written. For builtins and field
  operations `OpLen.lean` proves the facts the contract rests on, for the machine's own instructions:
  `mop_len` (no instruction frees an object or changes its number of slots), `drain_len` (a release step
  never frees the object of a counted local), `mstep_len` (no step changes the length of an array behind
  a counted local). Remaining, stated: (a) the descriptor of a builtin (`dst`, `men`, `kept`) is not tied
  per instruction to the machine's `MI` (only the length/liveness facts are); (b) the type discipline of
  the result: `RetGenOK` takes `hcls` (an owned operand is a reference-class local) and `hres` (the
  stored result respects the class of its local: a `usize` is never negative, a `bool` is 0 or 1);
  the ownership model has no integer classes, so this stays an explicit hypothesis, as the class
  conditions of `Exec`; (c) the ghost bit `ctd` is related to the ownership kinds only through the
  hypothesis `ctd x -> pinned (kinds at the call) x` (`AS.pinned`: counted, or a `Param` local), i.e. the caller of the bridge supplies the
  simulation between the range frame and the ownership analysis.
* **Integers** are mathematical; overflow, underflow and bounds traps stop the execution, so a trap has
  no successor. A `usize` is never negative (`Cls.okv`; `wf.or`). Every written value respects the class
  of its local.
* **Entry.** The entry frame has legal scalar values; references are arbitrary (no fact).
* **Branch.** A two-way branch on a bool local; edge 0 is taken when the local is nonzero. Other
  terminators are `other ss`, any listed successor.
* **Worklist.** The pop order is any (the implementation pops the last); `thr` and the widening delay
  `wa` are parameters (the implementation derives them from the function). **Termination is proved**
  (`RangeTerm.lean`, below) for every pop order, every threshold list and every delay, so `fix_sound`
  is total correctness on a well-formed function. `joinMoved` is the implementation's `changed` flag.
  The termination theorem needs the shape of the function (`FnOk`: the entry block exists, every
  successor is a block, every array literal is below `BIG`): the first two are what `wf.or` checks,
  the third is a bound the model needs because `arrayNew d n` takes any `Nat`.
* **Narrowing** is stated by its defining equation (`NarrowRel`): block `b` sees the new states of the
  earlier blocks and the old states of the others.
* **Well-formedness the proofs take from `wf.or`**: the index operand of an access is a scalar
  (`IdxScalar`); an instruction is executable only when its operand classes are right (`Exec` carries
  the class conditions).
* **T2, dominated-by-check** (`RangeDom.lean`). `verdict`, `Defs`, `KeyDefs`, `scan`, `WINDOW`, `domOk`
  transcribe `unchecked.or` / `scan.or` over `RI`. `dom_sound` / `t2_sound`: if the backward scan over
  the instructions of the block before the access accepts, then in every execution of that prefix the
  array local holds a live array and the index is a valid slot (`InBounds`); `t2_machine` carries this
  to the machine heap (`u1_machine`), `t2_block` states it for a reachable block entry. The proof is
  an induction over the reversed prefix: the source (`source_inb`) establishes the fact, every PASS
  instruction keeps it (`pass_inb`, by cases over `Exec`; the `gen` case uses the `own` clause of
  `GenOK`). Assumptions, each named in the theorem: the index is a scalar (`wf.or`), an element store
  never stores the array into itself (`NoSelf`, `wf.or`'s `valueOk`), and **`Held`**: whenever the
  array local holds a reference it is a pinned one (the `ctd` bit: counted, or a parameter lent by the
  caller). For a counted array it stays a hypothesis of
  `dom_sound` / `t2_sound`. **For a borrowed-only array parameter it is proved** (`RangePin.lean`):
  `pinA_exec` (an instruction that does not mention the local, or keeps it, preserves the pin and the
  length, across a `gen` too, `GenOK.own`), `reachP_pin` (in every block entry reachable from a pinned
  entry frame), `held_of_pin`, `t2_param` (= `t2_sound` without `Held`). Its hypotheses: the function uses
  the parameter only in kept positions (`KeptI`; `compiler/verify` rejects every other use of a `Param`
  local: it cannot be moved, consumed, redefined or mutated; the statement is about the `RI` function, the
  equality with the verifier's check is C4) and the entry frames carry the pin. The machine side:
  `CallLink.lean` (`RetGenOK`, `ret_genok`) and `OpLen.lean` (`mstep_len_param`, `mstep_len_pinned`)
  derive the `own` clause of `GenOK` for a `Param` local from `Frozen` (the caller's anchors keep their
  objects and slots), `pinA_of_inv` and `pin_entry_param` give the pin of a lent parameter from the
  ownership invariant (`Inv`).
* **Not modelled.** Array contents, the cost guard `MAX_CELLS` (refusing is sound), the equality of the
  Orin code with this transcription (C4 level), and the emitters.
