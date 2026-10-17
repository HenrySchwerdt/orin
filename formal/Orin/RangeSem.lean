import Orin.RangeStep

/-!
# Interval analysis: concrete semantics and the soundness invariant

The concrete state `CS` is a MIR frame (`Val` locals, as in `Heap.lean`) plus the **array-length
model**: `len l = some n` says that location `l` holds a live array with `n` slots (the machine's
`Obj.fields.length`; the bridge is `lensOf` in `RangeCfg.lean`).  Array contents are not tracked:
the analysis never looks at an element.  `ctd x` is a ghost bit: the local `x` holds a *counted*
reference (`Owned`/`Unique` in the ownership analysis); `arraynew` gives it, `move` hands it over.

`Exec cls ins s s'` is the semantics of one instruction.  Integers are mathematical; every value
written to a local respects the local's class (`Cls.okv`: a `usize` is never negative; this is the
type discipline `wf.or` enforces, and the overflow, underflow and bounds traps stop the execution,
so a step that traps simply has no successor).  Instructions are only executable when they are
well-formed (`Exec` carries the class conditions of `wf.or`: `IMove` between references, `ICopy`
of scalars, ...).

The instruction `gen` stands for everything else (calls, builtins, field operations).  Its only
assumption is the **ownership contract** `GenOK`, the formal form of "why a borrowed call may keep
it" (`docs/mir.md`, R2): a local that the instruction neither mentions nor defines keeps its value,
and a *counted* reference keeps its object (alive, with the same number of slots) unless the
instruction mentions the local and does not keep it: nobody else can change or free an object that
a local holds a count of.  For calls this is **derived** from the ownership model
(`CallLink.lean`: `ret_genok`, from `Frozen`/`frozen_step`; for the machine's builtins `OpLen.lean`);
this file states it as the interface of `gen`.
-/

namespace Orin
namespace Range

structure CS where
  loc : List Val
  ctd : Nat → Bool
  len : Nat → Option Nat

def CS.get (s : CS) (x : Nat) : Val := s.loc.getD x (.int 0)

def CS.put (s : CS) (d : Nat) (w : Val) (c : Bool) : CS :=
  { s with loc := s.loc.set d w, ctd := fun x => if x = d then c else s.ctd x }

/-- the scalar value of an operand (a reference local has none) -/
def evalOpd (cls : List Cls) (s : CS) : Opd → Option Int
  | .loc l => if clsOf cls l = .ref then none else
      (match s.get l with | .int n => some n | .ref _ => none)
  | .cint n => some n
  | .cusize n => if 0 ≤ n then some n else none

/-- a value is legal for a local of class `c` (a reference local holds any value) -/
def VOk (c : Cls) : Val → Prop
  | .int n => c = .ref ∨ c.okv n
  | .ref _ => c = .ref

/-- the locals an instruction may change -/
def Chg (cls : List Cls) (ins : RI) (x : Nat) : Prop :=
  ins.dst = some x ∨ ins.recv = some x ∨
    (x ∈ ins.men ∧ ins.keeps x = false ∧ clsOf cls x = .ref) ∨ ins = .makeUnique x

/-- well-formedness of a `gen`: the defined locals are mentioned and not kept -/
def GenWf : RI → Prop
  | .gen dst men kept recv =>
    (∀ x, dst = some x → x ∉ kept) ∧ (∀ x, recv = some x → x ∉ kept ∧ x ∈ men)
  | _ => True

/-- The ownership contract of an unknown instruction. -/
structure GenOK (cls : List Cls) (ins : RI) (s s' : CS) : Prop where
  size : s'.loc.length = s.loc.length
  same : ∀ x, ¬ Chg cls ins x → s'.loc[x]? = s.loc[x]?
  vok : ∀ x, x < s.loc.length → Chg cls ins x → VOk (clsOf cls x) (s'.get x)
  own : ∀ x l n, ¬ Chg cls ins x → s.loc[x]? = some (.ref l) → s.ctd x = true →
    s.len l = some n → s'.len l = some n ∧ s'.ctd x = true

inductive Exec (cls : List Cls) : RI → CS → CS → Prop
  | copy {s : CS} {d : Nat} {o : Opd} {v : Int} :
      d < s.loc.length → clsOf cls d ≠ .ref → evalOpd cls s o = some v → (clsOf cls d).okv v →
      Exec cls (.copy d o) s (s.put d (.int v) false)
  | move {s : CS} {d x : Nat} :
      d < s.loc.length → x < s.loc.length → d ≠ x → clsOf cls d = .ref → clsOf cls x = .ref →
      Exec cls (.move d x) s ((s.put d (s.get x) (s.ctd x)).put x (.int 0) false)
  | forward {s : CS} {d x o : Nat} {v : Int} :
      d < s.loc.length → clsOf cls d ≠ .ref → clsOf cls x ≠ .ref → s.get x = .int v →
      (clsOf cls d).okv v → Exec cls (.forward d x o) s (s.put d (.int v) false)
  | arrayNew {s : CS} {d k l : Nat} :
      d < s.loc.length → clsOf cls d = .ref → s.len l = none →
      Exec cls (.arrayNew d k) s
        ⟨s.loc.set d (.ref l), fun x => if x = d then true else s.ctd x,
         fun m => if m = l then some k else s.len m⟩
  | arrLen {s : CS} {d a l n : Nat} :
      d < s.loc.length → clsOf cls d ≠ .ref → clsOf cls a = .ref → s.get a = .ref l →
      s.len l = some n → (clsOf cls d).okv (n : Int) →
      Exec cls (.arrLen d a) s (s.put d (.int (n : Int)) false)
  | add {s : CS} {d : Nat} {x y : Opd} {vx vy : Int} :
      d < s.loc.length → (clsOf cls d = .int ∨ clsOf cls d = .usize) →
      evalOpd cls s x = some vx → evalOpd cls s y = some vy → (clsOf cls d).okv (vx + vy) →
      Exec cls (.add d x y) s (s.put d (.int (vx + vy)) false)
  | sub {s : CS} {d : Nat} {x y : Opd} {vx vy : Int} :
      d < s.loc.length → (clsOf cls d = .int ∨ clsOf cls d = .usize) →
      evalOpd cls s x = some vx → evalOpd cls s y = some vy → (clsOf cls d).okv (vx - vy) →
      Exec cls (.sub d x y) s (s.put d (.int (vx - vy)) false)
  | cmp {s : CS} {d : Nat} {op : Cmp} {x y : Opd} {vx vy : Int} :
      d < s.loc.length → clsOf cls d = .bool → evalOpd cls s x = some vx →
      evalOpd cls s y = some vy →
      Exec cls (.cmp d op x y) s (s.put d (.int (if op.eval vx vy then 1 else 0)) false)
  | get {s : CS} {d a l n : Nat} {i : Opd} {iv : Int} {w : Val} :
      d < s.loc.length → clsOf cls a = .ref → s.get a = .ref l → s.len l = some n →
      evalOpd cls s i = some iv → 0 ≤ iv → iv < (n : Int) → VOk (clsOf cls d) w →
      Exec cls (.get d a i) s (s.put d w false)
  | set {s s' : CS} {a l n : Nat} {i : Opd} {iv : Int} {v : Nat} :
      clsOf cls a = .ref → s.get a = .ref l → s.len l = some n →
      evalOpd cls s i = some iv → 0 ≤ iv → iv < (n : Int) →
      (s' = s ∨ (v < s.loc.length ∧ clsOf cls v = .ref ∧ s' = s.put v (.int 0) false)) →
      Exec cls (.set a i v) s s'
  | makeUnique {s s' : CS} {a l n : Nat} :
      clsOf cls a = .ref → s.get a = .ref l → s.len l = some n →
      (s' = s ∨ ∃ m, a < s.loc.length ∧ s.len m = none ∧
        s' = ⟨s.loc.set a (.ref m), fun x => if x = a then true else s.ctd x,
              fun k => if k = m then some n else s.len k⟩) →
      Exec cls (.makeUnique a) s s'
  | gen {s s' : CS} {dst : Option Nat} {men kept : List Nat} {recv : Option Nat} :
      GenWf (.gen dst men kept recv) → GenOK cls (.gen dst men kept recv) s s' →
      Exec cls (.gen dst men kept recv) s s'

/-! ### the invariant: what an abstract state says about a concrete state -/

structure SoundS (cls : List Cls) (iv : List Iv) (s : CS) : Prop where
  leniv : iv.length = cls.length
  lenloc : s.loc.length = cls.length
  /-- R1: a scalar local holds a value of its class inside its interval -/
  scal : ∀ x, x < cls.length → clsOf cls x ≠ .ref →
    ∃ n, s.loc[x]? = some (.int n) ∧ (clsOf cls x).okv n ∧ Mem n (gi iv x)
  /-- R1: `lo >= 0` on a reference local means a counted reference to a live array whose number
  of slots is in the interval -/
  fact : ∀ x, known cls iv x →
    ∃ l n, s.loc[x]? = some (.ref l) ∧ s.len l = some n ∧ Mem (n : Int) (gi iv x) ∧ s.ctd x = true

/-- the recorded comparison is true of the current values -/
def NoteOk (cls : List Cls) (s : CS) : Option Note → Prop
  | none => True
  | some n =>
    (opCls cls n.x = .int ∨ opCls cls n.x = .usize) ∧ opCls cls n.y = opCls cls n.x ∧
    clsOf cls n.c = .bool ∧
    ∃ vx vy, evalOpd cls s n.x = some vx ∧ evalOpd cls s n.y = some vy ∧
      s.get n.c = .int (if n.op.eval vx vy then 1 else 0)

/-- the invariant of a point of a block: reachable (not dead), described by the intervals, the
recorded comparison is true -/
def RunSound (cls : List Cls) (rs : RS) (s : CS) : Prop :=
  rs.dead = false ∧ SoundS cls rs.iv s ∧ NoteOk cls s rs.note

/-! ### small facts -/

theorem get_of_loc {s : CS} {x : Nat} {w : Val} (h : s.loc[x]? = some w) : s.get x = w := by
  simp [CS.get, List.getD_eq_getElem?_getD, h]

theorem get_eq_of_loc {s s' : CS} {x : Nat} (h : s'.loc[x]? = s.loc[x]?) : s'.get x = s.get x := by
  simp [CS.get, List.getD_eq_getElem?_getD, h]

theorem put_loc (s : CS) (d : Nat) (w : Val) (c : Bool) (x : Nat) :
    (s.put d w c).loc[x]? = if x = d ∧ d < s.loc.length then some w else s.loc[x]? := by
  simp only [CS.put, List.getElem?_set]
  by_cases h : d = x
  · subst h; by_cases hd : d < s.loc.length <;> simp [hd]
  · simp [h, Ne.symm h]

theorem put_loc_same (s : CS) {d : Nat} (hd : d < s.loc.length) (w : Val) (c : Bool) :
    (s.put d w c).loc[d]? = some w := by
  rw [put_loc]; simp [hd]

theorem put_loc_ne (s : CS) {d x : Nat} (hx : x ≠ d) (w : Val) (c : Bool) :
    (s.put d w c).loc[x]? = s.loc[x]? := by
  rw [put_loc]; simp [hx]

theorem put_len (s : CS) (d : Nat) (w : Val) (c : Bool) : (s.put d w c).len = s.len := rfl

theorem put_ctd_ne (s : CS) {d x : Nat} (hx : x ≠ d) (w : Val) (c : Bool) :
    (s.put d w c).ctd x = s.ctd x := by
  simp [CS.put, hx]

theorem put_length (s : CS) (d : Nat) (w : Val) (c : Bool) :
    (s.put d w c).loc.length = s.loc.length := by
  simp [CS.put]

theorem gi_set_same {iv : List Iv} {d : Nat} (hd : d < iv.length) (x : Iv) :
    gi (iv.set d x) d = x := by
  simp [gi, hd]

theorem gi_set_ne {iv : List Iv} {d y : Nat} (hy : y ≠ d) (x : Iv) :
    gi (iv.set d x) y = gi iv y := by
  simp [gi, List.getElem?_set, hy, Ne.symm hy]

theorem gi_out {iv : List Iv} {x : Nat} (h : iv.length ≤ x) : gi iv x = Iv.unk := by
  simp [gi, List.getElem?_eq_none h]

end Range
end Orin
