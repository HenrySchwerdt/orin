import Orin.Heap

/-!
# Orin memory IR: small-step machine

A tiny memory IR over numbered local variables (every local *owns* its value: the codegen
convention "locals own their value"). Instructions mirror the runtime calls emitted by the
code generators (`orin_dup`, `orin_retain`, `orin_release`, `orin_make_unique`, struct
get/set, struct allocation).

Outcomes of one step:
* `ok`   : the machine moved.
* `trap` : a *defined* safe failure (field index out of range = bounds trap).
* `bad`  : a memory-safety violation: access to a non-live location (`dead`), or an in-place
           store into an object whose count is not 1 (`shared`, a violation of the
           copy-on-write discipline).
* `ill`  : ill-formed IR (local index out of range, branching on a reference, loading from
           a scalar). A verifier is expected to rule this out; it is not a memory event.

Release is modelled with an explicit *pending* worklist: `release x` moves the local's owned
reference onto the worklist; `drain` steps pop one entry, decrement its object and, when the
count reaches 0, free it and push its fields (the recursive release). The machine drains the
worklist to empty before executing the next instruction.
-/

namespace Orin

inductive BadKind where
  | dead
  | shared
  deriving DecidableEq, Repr

inductive Res (α : Type) where
  | ok (a : α)
  | trap
  | bad (k : BadKind)
  | ill

inductive Instr where
  /-- `x := int n` (the previous contents of `x` are overwritten, a leak if it was a reference). -/
  | const (x : Nat) (n : Int)
  /-- `y := orin_dup(x)` -/
  | copy (y x : Nat)
  /-- `y := orin_dup(slot i of x)` (borrowed slot read, then retained) -/
  | load (y x i : Nat)
  /-- `slot i of x := orin_dup(y)`, releasing the old slot; requires `rc(x) = 1` -/
  | store (x i y : Nat)
  /-- `x := new object with fields (orin_dup y₁, …, orin_dup yₙ)` -/
  | alloc (x : Nat) (ys : List Nat)
  /-- `x := orin_make_unique(x)` -/
  | makeUnique (x : Nat)
  /-- bare `orin_retain(x)` (a temporary owner that is never released: leaks, never unsafe) -/
  | retain (x : Nat)
  /-- `orin_release(x)`; the local is dead afterwards -/
  | release (x : Nat)
  /-- branch on a scalar local: `0` runs `t`, anything else runs `e` -/
  | ite (c : Nat) (t e : List Instr)

/-- Machine state: heap, owned locals (a scalar `int 0` is the "dead local" marker),
and the pending-release worklist (each entry is an owned reference). -/
structure St where
  heap : Heap
  locals : List Val
  pending : List Val

structure Cfg where
  code : List Instr
  st : St

namespace St

def get (s : St) (x : Nat) : Val := s.locals.getD x (.int 0)

def setL (s : St) (x : Nat) (v : Val) : St := { s with locals := s.locals.set x v }

end St

open Heap in
def opConst (s : St) (x : Nat) (n : Int) : Res St :=
  if x < s.locals.length then .ok (s.setL x (.int n)) else .ill

open Heap in
def opCopy (s : St) (y x : Nat) : Res St :=
  if x < s.locals.length ∧ y < s.locals.length then
    let v := s.get x
    if s.heap.liveb v then .ok { s.setL y v with heap := s.heap.bump [v] } else .bad .dead
  else .ill

open Heap in
def opLoad (s : St) (y x i : Nat) : Res St :=
  if x < s.locals.length ∧ y < s.locals.length then
    match s.get x with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some o =>
        match o.fields[i]? with
        | none => .trap
        | some v =>
          if s.heap.liveb v then .ok { s.setL y v with heap := s.heap.bump [v] } else .bad .dead
  else .ill

open Heap in
def opStore (s : St) (x i y : Nat) : Res St :=
  if x < s.locals.length ∧ y < s.locals.length then
    match s.get x with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some o =>
        if o.rc ≠ 1 then .bad .shared else
        match o.fields[i]? with
        | none => .trap
        | some old =>
          let v := s.get y
          if s.heap.liveb v then
            .ok { s with
                  heap := (s.heap.setObj l { o with fields := o.fields.set i v }).bump [v],
                  pending := old :: s.pending }
          else .bad .dead
  else .ill

open Heap in
def opAlloc (s : St) (x : Nat) (ys : List Nat) : Res St :=
  if x < s.locals.length ∧ ∀ y ∈ ys, y < s.locals.length then
    let vs := ys.map s.get
    if vs.all s.heap.liveb then
      let r := (s.heap.bump vs).alloc vs
      .ok { s with heap := r.1, locals := s.locals.set x (.ref r.2) }
    else .bad .dead
  else .ill

open Heap in
def opMakeUnique (s : St) (x : Nat) : Res St :=
  if x < s.locals.length then
    match s.get x with
    | .int _ => .ill
    | .ref l =>
      match s.heap.objs l with
      | none => .bad .dead
      | some o =>
        if o.rc = 1 then .ok s else
        if o.fields.all s.heap.liveb then
          let r := (s.heap.bump o.fields).alloc o.fields
          .ok { s with heap := r.1.decRc l, locals := s.locals.set x (.ref r.2) }
        else .bad .dead
  else .ill

open Heap in
def opRetain (s : St) (x : Nat) : Res St :=
  if x < s.locals.length then
    let v := s.get x
    if s.heap.liveb v then .ok { s with heap := s.heap.bump [v] } else .bad .dead
  else .ill

def opRelease (s : St) (x : Nat) : Res St :=
  if x < s.locals.length then
    .ok { s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending }
  else .ill

open Heap in
/-- One step of the recursive release worklist. Requires a non-empty worklist. -/
def drain (s : St) : Res St :=
  match s.pending with
  | [] => .ill
  | .int _ :: rest => .ok { s with pending := rest }
  | .ref l :: rest =>
    match s.heap.objs l with
    | none => .bad .dead
    | some o =>
      if o.rc = 0 then .bad .dead
      else if o.rc = 1 then .ok { s with heap := s.heap.del l, pending := o.fields ++ rest }
      else .ok { s with heap := s.heap.decRc l, pending := rest }

/-- Re-attach the remaining code to the outcome of an instruction. -/
def Res.lift (rest : List Instr) : Res St → Res Cfg
  | .ok s' => .ok ⟨rest, s'⟩
  | .trap => .trap
  | .bad k => .bad k
  | .ill => .ill

/-- Execute one instruction (worklist assumed empty; see `step`). -/
def exec (i : Instr) (rest : List Instr) (s : St) : Res Cfg :=
  let mk := Res.lift rest
  match i with
  | .const x n => mk (opConst s x n)
  | .copy y x => mk (opCopy s y x)
  | .load y x j => mk (opLoad s y x j)
  | .store x j y => mk (opStore s x j y)
  | .alloc x ys => mk (opAlloc s x ys)
  | .makeUnique x => mk (opMakeUnique s x)
  | .retain x => mk (opRetain s x)
  | .release x => mk (opRelease s x)
  | .ite c t e =>
    if c < s.locals.length then
      match s.get c with
      | .int 0 => .ok ⟨t ++ rest, s⟩
      | .int _ => .ok ⟨e ++ rest, s⟩
      | .ref _ => .ill
    else .ill

/-- One deterministic machine step. `none` = halted (no code, empty worklist). A non-empty
worklist is always drained first. -/
def step (c : Cfg) : Option (Res Cfg) :=
  match c.st.pending with
  | _ :: _ =>
    some (Res.lift c.code (drain c.st))
  | [] =>
    match c.code with
    | [] => none
    | i :: rest => some (exec i rest c.st)

/-- Reachability by `ok` steps. -/
inductive Reach : Cfg → Cfg → Prop where
  | refl (c : Cfg) : Reach c c
  | step (c c' d : Cfg) : step c = some (.ok c') → Reach c' d → Reach c d

end Orin
