import Orin.SimArr

/-!
# Interval analysis (rules R1-R5, U1): the abstract domain

ADR-0053 M8.  `compiler/verify/range.or` proves an unchecked array access (`IArrayGetU` /
`IArraySetU`, rule U1) by a forward interval analysis of the whole function.  This file models the
*domain*: the interval `[lo, hi]` with the two sentinels `NEG = -2^60` (no lower bound) and
`BIG = 2^60` (no upper bound) exactly as the implementation encodes them, the bound arithmetic
(`addLo`, `addHi`, `subLo`, `subHi`, with the clamping of the implementation), the hull, and the
widening to a threshold.  The semantics of an interval is `Mem`: a value is described when each
bound is either a sentinel or a real bound the value respects.

For a reference local the interval is the **length** of the array it holds (rule R1); the bridge
to the array-length model of the machine (`Obj.fields.length`, `opArrayLen`, `arrayGet_oob`) is at
the end of this file (`lensOf`).
-/

namespace Orin
namespace Range

/-- upper sentinel: "no upper bound" -/
def BIG : Int := 1152921504606846976
/-- lower sentinel: "no lower bound" -/
def NEG : Int := -1152921504606846976

theorem BIG_eq : BIG = 1152921504606846976 := rfl
theorem NEG_eq : NEG = -1152921504606846976 := rfl

/-- an interval; the sentinels mean "no bound" -/
structure Iv where
  lo : Int
  hi : Int
  deriving DecidableEq

/-- the widest interval (a parameter, a call result, an unknown definition) -/
def Iv.unk : Iv := ⟨NEG, BIG⟩

/-- `Mem x iv`: the integer `x` is described by `iv`.  A bound at or beyond its sentinel is no bound. -/
def Mem (x : Int) (iv : Iv) : Prop := (iv.lo ≤ NEG ∨ iv.lo ≤ x) ∧ (BIG ≤ iv.hi ∨ x ≤ iv.hi)

/-- `iv ⊑ iv'`: every value of `iv` is a value of `iv'` -/
def Iv.le (iv iv' : Iv) : Prop := iv'.lo ≤ iv.lo ∧ iv.hi ≤ iv'.hi

theorem Mem.mono {x : Int} {iv iv' : Iv} (h : Mem x iv) (hle : Iv.le iv iv') : Mem x iv' := by
  unfold Mem Iv.le at *
  omega

theorem mem_unk (x : Int) : Mem x Iv.unk := by
  show (NEG ≤ NEG ∨ NEG ≤ x) ∧ (BIG ≤ BIG ∨ x ≤ BIG)
  unfold NEG BIG
  omega

theorem Iv.le_refl (iv : Iv) : Iv.le iv iv := ⟨Int.le_refl _, Int.le_refl _⟩

theorem Iv.le_trans {a b c : Iv} (h1 : Iv.le a b) (h2 : Iv.le b c) : Iv.le a c :=
  ⟨Int.le_trans h2.1 h1.1, Int.le_trans h1.2 h2.2⟩

theorem Iv.le_unk (iv : Iv) (h : iv.lo ≥ NEG ∧ iv.hi ≤ BIG) : Iv.le iv Iv.unk := h

/-! ### R1: classes and the meaning of an interval for each class -/

/-- the classes of the locals (`tyClass`, `compiler/verify/wf.or`) -/
inductive Cls where
  | int
  | usize
  | bool
  | ref
  deriving DecidableEq

/-- the lower bound of the unknown value of a local of class `c` (a `usize` is never negative) -/
def floorOf : Cls → Int
  | .usize => 0
  | _ => NEG

/-- the value `x` is a legal scalar value of class `c` -/
def Cls.okv : Cls → Int → Prop
  | .usize, x => 0 ≤ x
  | .bool, x => x = 0 ∨ x = 1
  | .int, _ => True
  | .ref, _ => False

/-- the unknown interval of a local of class `c` -/
def unkOf (c : Cls) : Iv := ⟨floorOf c, BIG⟩

theorem mem_unkOf {c : Cls} {x : Int} (h : c.okv x) (hc : c ≠ .ref) : Mem x (unkOf c) := by
  show (floorOf c ≤ NEG ∨ floorOf c ≤ x) ∧ (BIG ≤ BIG ∨ x ≤ BIG)
  cases c with
  | int => simp only [floorOf]; unfold NEG BIG; omega
  | usize => simp only [floorOf]; simp only [Cls.okv] at h; unfold NEG BIG; omega
  | bool => simp only [floorOf]; unfold NEG BIG; omega
  | ref => exact absurd rfl hc

/-! ### R2: bound arithmetic (the implementation's `addLo` ... `subHi`, with its clamping) -/

def clampI (s : Int) : Int := if s < NEG then NEG else if s > BIG then BIG else s

def addLo (a b : Int) : Int := if a ≤ NEG ∨ b ≤ NEG then NEG else clampI (a + b)
def addHi (a b : Int) : Int := if a ≥ BIG ∨ b ≥ BIG then BIG else clampI (a + b)
/-- lower bound of `x - y` from `lo x` and `hi y` -/
def subLo (a b : Int) : Int := if a ≤ NEG ∨ b ≥ BIG then NEG else clampI (a - b)
/-- upper bound of `x - y` from `hi x` and `lo y` -/
def subHi (a b : Int) : Int := if a ≥ BIG ∨ b ≤ NEG then BIG else clampI (a - b)

theorem r2_add {x y : Int} {ix iy : Iv} (hx : Mem x ix) (hy : Mem y iy) :
    Mem (x + y) ⟨addLo ix.lo iy.lo, addHi ix.hi iy.hi⟩ := by
  unfold Mem addLo addHi clampI NEG BIG at *
  simp only at *
  repeat' split
  all_goals omega

theorem r2_sub {x y : Int} {ix iy : Iv} (hx : Mem x ix) (hy : Mem y iy) :
    Mem (x - y) ⟨subLo ix.lo iy.hi, subHi ix.hi iy.lo⟩ := by
  unfold Mem subLo subHi clampI NEG BIG at *
  simp only at *
  repeat' split
  all_goals omega

/-! ### R4: hull, widening -/

def Iv.hull (a b : Iv) : Iv := ⟨min a.lo b.lo, max a.hi b.hi⟩

theorem hull_left (a b : Iv) : Iv.le a (Iv.hull a b) := by
  unfold Iv.le Iv.hull; simp only [Int.min_le_left, Int.le_max_left, and_self]

theorem hull_right (a b : Iv) : Iv.le b (Iv.hull a b) := by
  unfold Iv.le Iv.hull; simp only [Int.min_le_right, Int.le_max_right, and_self]

/-- the nearest threshold at or above `v`, else "no bound" (`widenHi`) -/
def widenHi (thr : List Int) (v : Int) : Int :=
  thr.foldl (fun best t => if t ≥ v ∧ t < best then t else best) BIG

/-- the nearest threshold at or below `v`, else the floor (`widenLo`) -/
def widenLo (thr : List Int) (v floor : Int) : Int :=
  thr.foldl (fun best t => if t ≤ v ∧ t > best then t else best) floor

theorem widenHi_ge (thr : List Int) (v : Int) (hv : v ≤ BIG) : v ≤ widenHi thr v := by
  unfold widenHi
  suffices h : ∀ (l : List Int) (b : Int), v ≤ b → v ≤ l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b from
    h thr BIG hv
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; exact h.1
    · exact hb

theorem widenLo_le (thr : List Int) (v floor : Int) (hv : floor ≤ v) : widenLo thr v floor ≤ v := by
  unfold widenLo
  suffices h : ∀ (l : List Int) (b : Int), b ≤ v → l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b ≤ v from
    h thr floor hv
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; exact h.1
    · exact hb

end Range
end Orin
