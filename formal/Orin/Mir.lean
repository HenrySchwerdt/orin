import Orin.Final

/-!
# MIR ownership core: instructions and concrete semantics

A structured fragment of MIR (`compiler/mir/mir.or`, `docs/mir.md`) over the machine of
`Machine.lean`.  Differences from the first model:

* a local is **not** assumed to own its value.  `borrow` copies a reference *without* a count
  (`IBorrow`), `getField` yields an uncounted alias of a slot (`IGetField`).  Whether a local
  owns anything is exactly what the abstract state of `Check.lean` claims and what the
  simulation relation of `Sound.lean` proves;
* ownership-*transferring* operations (`move`, `structNew`, `setField`, `putField`,
  `takeField`) move a count without touching the reference count;
* control flow is structured: `Code` is straight-line code with `ite` (if/else with a
  continuation) and `loop` (while).  Calls are not modelled in this file.

The concrete machine knows nothing about ownership states; `bad` is still only "access to a
non-live location or in-place store into an object whose count is not 1".
-/

namespace Orin

/-- Parameter modes (`MFunction.paramOwned`, `docs/mir.md`): a scalar, a reference borrowed from the
caller for the whole call, or an owned reference (one count handed over by the caller). -/
inductive PM where
  | scalar
  | borrowed
  | owned
  deriving DecidableEq, Repr

/-- Straight-line MIR core instructions (`ite` lives in `Code`). -/
inductive MI where
  /-- `ICopy` of a scalar constant -/
  | const (d : Nat) (n : Int)
  /-- `IMove d s` -/
  | move (d s : Nat)
  /-- `IBorrow d s` (uncounted alias) -/
  | borrow (d s : Nat)
  /-- `IDup d s` (retain) -/
  | dup (d s : Nat)
  /-- `IRelease x` -/
  | release (x : Nat)
  /-- allocation of a fresh count-1 object with `n` scalar-zero slots; `d` becomes `Unique`.
  `IStructNew d slots` is the macro `Code.structNew`: `alloc d |slots|` followed by one
  `setField d i yᵢ` per operand (operands consumed left to right). -/
  | alloc (d n : Nat)
  /-- `IGetField d o i`; `isRef` is the static class of `d` (reference: borrowed result;
  scalar: plain value) -/
  | getField (d o i : Nat) (isRef : Bool)
  /-- `ISetField x i v`: store `v` (consumed), release the old slot value -/
  | setField (x i v : Nat)
  /-- `ITakeField d x i`: move the slot value out, leaving a hole -/
  | takeField (d x i : Nat)
  /-- `IPutField x i s`: fill a hole with `s` (consumed) -/
  | putField (x i s : Nat)
  /-- `IMakeUnique x` -/
  | makeUnique (x : Nat)
  /-- `IArrayLen d a`: `d` receives the length of the array (the number of slots) -/
  | arrayLen (d a : Nat)
  /-- `IArrayGet d a i`: bounds-checked element read; the index is the scalar local `i`
  (`getField` with a run-time index; out of range = `trap`) -/
  | arrayGet (d a i : Nat) (isRef : Bool)
  /-- `IArraySet x i v`: bounds-checked in-place element store (`setField` with a run-time index) -/
  | arraySet (x i v : Nat)
  /-- `IArrayNew d nl`: fresh count-1 array of `n` zero elements, `n` the scalar local `nl`
  (a negative length traps) -/
  | arrayNew (d nl : Nat)

/-- Structured code: straight line, with if/else and a continuation after the join. -/
inductive Code where
  | nil : Code
  | op (i : MI) (k : Code) : Code
  | ite (c : Nat) (t e k : Code) : Code
  /-- `while`: test the scalar local `c`; `0` runs the body `t` and tests again, anything else
  leaves the loop and continues with `k`.  (The condition is recomputed at the end of the body;
  a MIR header block that computes it is duplicated in front of the loop.) -/
  | loop (c : Nat) (t k : Code) : Code
  /-- `ICall d f args`: call function `f` of the program with the operands `args`; the result
  goes to the local `d`.  The machine step of a call is `cstep` (`Call.lean`); the single-frame
  `mstep` treats a call as a stop. -/
  | call (d f : Nat) (args : List Nat) (k : Code) : Code

namespace Code

def app : Code → Code → Code
  | .nil, k => k
  | .op i c, k => .op i (app c k)
  | .ite c t e k', k => .ite c t e (app k' k)
  | .loop c t k', k => .loop c t (app k' k)
  | .call d f args k', k => .call d f args (app k' k)

/-- operands stored into slots `i, i+1, …` of the fresh object `d` -/
def storeAll (d : Nat) : Nat → List Nat → Code → Code
  | _, [], k => k
  | i, y :: ys, k => .op (.setField d i y) (storeAll d (i + 1) ys k)

/-- `IStructNew d ys`: allocate, then move each operand into its slot. -/
def structNew (d : Nat) (ys : List Nat) (k : Code) : Code :=
  .op (.alloc d ys.length) (storeAll d 0 ys k)

end Code

/-! ### concrete operations -/

namespace St

/-- Clear a local whose value is a reference (its count moved elsewhere); scalars are kept. -/
def clr (s : St) (y : Nat) : St :=
  match s.get y with
  | .ref _ => s.setL y (.int 0)
  | .int _ => s

end St

def opMove (s : St) (d x : Nat) : Res St :=
  if d < s.locals.length ∧ x < s.locals.length then
    .ok { s with locals := (s.locals.set d (s.get x)).set x (.int 0) }
  else .ill

def opBorrow (s : St) (d x : Nat) : Res St :=
  if d < s.locals.length ∧ x < s.locals.length then .ok (s.setL d (s.get x)) else .ill

open Heap in
def opAllocN (s : St) (d n : Nat) : Res St :=
  if d < s.locals.length then
    .ok { s with heap := (s.heap.alloc (List.replicate n (.int 0))).1,
                 locals := s.locals.set d (.ref s.heap.next) }
  else .ill

/-- `IGetField`: no retain.  The class of the destination must match the slot: a scalar
destination must receive a scalar, a reference destination a reference (`ill` otherwise: type
confusion, or a read of an emptied/`hole` slot, which the hole discipline of the verifier is
meant to exclude). -/
def opGetField (s : St) (d o i : Nat) (isRef : Bool) : Res St :=
  if d < s.locals.length ∧ o < s.locals.length then
    match s.get o with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some ob =>
        match ob.fields[i]? with
        | none => .trap
        | some w =>
          match isRef, w with
          | false, .ref _ => .ill
          | true, .int _ => .ill
          | _, _ => .ok (s.setL d w)
  else .ill

/-- `ISetField`/`IPutField`: in-place update of a count-1 object; the stored value is
*moved* (no retain); the old slot value is released. -/
def opSetField (s : St) (x i v : Nat) : Res St :=
  if x < s.locals.length ∧ v < s.locals.length then
    match s.get x with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some ob =>
        if ob.rc ≠ 1 then .bad .shared else
        match ob.fields[i]? with
        | none => .trap
        | some old =>
          .ok { s.clr v with
                heap := s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) },
                pending := old :: s.pending }
  else .ill

/-- `ITakeField`: the (reference) slot is emptied (`int 0`), its value moves into `d`. -/
def opTakeField (s : St) (d x i : Nat) : Res St :=
  if d < s.locals.length ∧ x < s.locals.length then
    match s.get x with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some ob =>
        if ob.rc ≠ 1 then .bad .shared else
        match ob.fields[i]? with
        | none => .trap
        | some old =>
          match old with
          | .int _ => .ill
          | .ref _ =>
            .ok { s.setL d old with
                  heap := s.heap.setObj l { ob with fields := ob.fields.set i (.int 0) } }
  else .ill

/-- Array access with a run-time index: a negative index is a `trap` and never a `bad`; the
array itself is inspected first (a dead array is `bad dead`, a scalar is `ill`), then the bounds
check fires. -/
def opArrayGet (s : St) (d a i : Nat) (isRef : Bool) : Res St :=
  if i < s.locals.length then
    match s.get i with
    | .ref _ => .ill
    | .int n =>
      if 0 ≤ n then opGetField s d a n.toNat isRef
      else if d < s.locals.length ∧ a < s.locals.length then
        match s.get a with
        | .int _ => .ill
        | .ref l =>
          match s.heap.objs l with
          | none => .bad .dead
          | some _ => .trap
      else .ill
  else .ill

def opArraySet (s : St) (x i v : Nat) : Res St :=
  if i < s.locals.length then
    match s.get i with
    | .ref _ => .ill
    | .int n =>
      if 0 ≤ n then opSetField s x n.toNat v
      else if x < s.locals.length ∧ v < s.locals.length then
        match s.get x with
        | .int _ => .ill
        | .ref l =>
          match s.heap.objs l with
          | none => .bad .dead
          | some ob => if ob.rc ≠ 1 then .bad .shared else .trap
      else .ill
  else .ill

def opArrayLen (s : St) (d a : Nat) : Res St :=
  if d < s.locals.length ∧ a < s.locals.length then
    match s.get a with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some ob => .ok (s.setL d (.int ob.fields.length))
  else .ill

def opArrayNew (s : St) (d nl : Nat) : Res St :=
  if nl < s.locals.length then
    match s.get nl with
    | .ref _ => .ill
    | .int n =>
      if 0 ≤ n then opAllocN s d n.toNat
      else if d < s.locals.length then .trap else .ill
  else .ill

def Res.liftC (rest : Code) : Res St → Res (Code × St)
  | .ok s' => .ok (rest, s')
  | .trap => .trap
  | .bad k => .bad k
  | .ill => .ill

/-- The concrete operation of one instruction. -/
def mop (s : St) : MI → Res St
  | .const x n => opConst s x n
  | .move d x => opMove s d x
  | .borrow d x => opBorrow s d x
  | .dup d x => opCopy s d x
  | .release x => opRelease s x
  | .alloc d n => opAllocN s d n
  | .getField d o j r => opGetField s d o j r
  | .setField x j v => opSetField s x j v
  | .takeField d x j => opTakeField s d x j
  | .putField x j y => opSetField s x j y
  | .makeUnique x => opMakeUnique s x
  | .arrayLen d a => opArrayLen s d a
  | .arrayGet d a i r => opArrayGet s d a i r
  | .arraySet x i v => opArraySet s x i v
  | .arrayNew d nl => opArrayNew s d nl

def mexec (i : MI) (rest : Code) (s : St) : Res (Code × St) :=
  Res.liftC rest (mop s i)

/-- One deterministic step; the release worklist is drained first. `none` = halted. -/
def mstep (c : Code × St) : Option (Res (Code × St)) :=
  match c.2.pending with
  | _ :: _ => some (Res.liftC c.1 (drain c.2))
  | [] =>
    match c.1 with
    | .nil => none
    | .op i k => some (mexec i k c.2)
    | .ite cnd t e k =>
      if cnd < c.2.locals.length then
        match c.2.get cnd with
        | .int 0 => some (.ok (t.app k, c.2))
        | .int _ => some (.ok (e.app k, c.2))
        | .ref _ => some .ill
      else some .ill
    | .call .. => none
    | .loop cnd t k =>
      if cnd < c.2.locals.length then
        match c.2.get cnd with
        | .int 0 => some (.ok (t.app (.loop cnd t k), c.2))
        | .int _ => some (.ok (k, c.2))
        | .ref _ => some .ill
      else some .ill

inductive MReach : Code × St → Code × St → Prop where
  | refl (c : Code × St) : MReach c c
  | step (c c' d : Code × St) : mstep c = some (.ok c') → MReach c' d → MReach c d

end Orin
