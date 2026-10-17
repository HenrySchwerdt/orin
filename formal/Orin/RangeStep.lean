import Orin.Range

/-!
# Interval analysis: the instructions, the abstract transfer (R2) and the refinement (R3)

A function is a list of blocks of the instructions below, each ending in a terminator
(`RangeCfg.lean`).  `RI` is the part of `Instr` of `compiler/mir/mir.or` that the analysis treats
specially: scalar copies (`ICopy`, `IForward`), `IMove`, `IArrayNew`, `arr.length`, `add`/`sub`,
comparisons, the array accesses and `IMakeUnique`.  Every other instruction is `gen`: a call, a
builtin, a field operation ...  described only by the locals it defines (`dst`, the in/out
receiver `recv`), mentions (`men`) and keeps (`kept`: the array operands in borrowed positions).

`step` is `RStep.step` of `range.or` (state: one interval per local, the dead flag, the recorded
comparison), `refine` is `RStep.refine`/`edge`.  The code of the implementation uses mutable
arrays; here the same updates are functions on lists.
-/

namespace Orin
namespace Range

/-- an operand: a local, an `int` constant or a `usize` constant -/
inductive Opd where
  | loc (l : Nat)
  | cint (n : Int)
  | cusize (n : Int)
  deriving DecidableEq

/-- the comparison operators the refinement understands -/
inductive Cmp where
  | lt | le | gt | ge | eq | ne
  deriving DecidableEq

def Cmp.eval : Cmp → Int → Int → Bool
  | .lt, x, y => decide (x < y)
  | .le, x, y => decide (x ≤ y)
  | .gt, x, y => decide (x > y)
  | .ge, x, y => decide (x ≥ y)
  | .eq, x, y => decide (x = y)
  | .ne, x, y => decide (x ≠ y)

/-- instructions -/
inductive RI where
  /-- `ICopy d o`: scalar copy -/
  | copy (d : Nat) (o : Opd)
  /-- `IMove d s`: reference move -/
  | move (d s : Nat)
  /-- `IForward d s o k`: `d = s`, a scalar copy that mentions the object `o` -/
  | forward (d s o : Nat)
  /-- `IArrayNew d [e1, ..., en]`: a fresh array with `n` elements -/
  | arrayNew (d n : Nat)
  /-- `d = arr.length(a)` -/
  | arrLen (d a : Nat)
  | add (d : Nat) (x y : Opd)
  | sub (d : Nat) (x y : Opd)
  /-- `IBinary` comparison into the bool local `d` -/
  | cmp (d : Nat) (op : Cmp) (x y : Opd)
  /-- `IArrayGet` / `IArrayGetU` -/
  | get (d a : Nat) (i : Opd)
  /-- `IArraySet` / `IArraySetU` (the stored value is the local `v`) -/
  | set (a : Nat) (i : Opd) (v : Nat)
  | makeUnique (a : Nat)
  /-- any other instruction: defined local, mentioned locals, array operands in borrowed positions
  that it does not define (`kept`), the in/out receiver it redefines -/
  | gen (dst : Option Nat) (men kept : List Nat) (recv : Option Nat)

def Opd.locs : Opd → List Nat
  | .loc l => [l]
  | _ => []

/-- `instrLocals`: the locals an instruction mentions -/
def RI.men : RI → List Nat
  | .copy d o => d :: o.locs
  | .move d s => [d, s]
  | .forward d s o => [d, s, o]
  | .arrayNew d _ => [d]
  | .arrLen d a => [d, a]
  | .add d x y => d :: (x.locs ++ y.locs)
  | .sub d x y => d :: (x.locs ++ y.locs)
  | .cmp d _ x y => d :: (x.locs ++ y.locs)
  | .get d a i => d :: a :: i.locs
  | .set a i v => a :: v :: i.locs
  | .makeUnique a => [a]
  | .gen dst men _ _ => dst.toList ++ men

/-- `dstOf` -/
def RI.dst : RI → Option Nat
  | .copy d _ => some d
  | .move d _ => some d
  | .forward d _ _ => some d
  | .arrayNew d _ => some d
  | .arrLen d _ => some d
  | .add d _ _ => some d
  | .sub d _ _ => some d
  | .cmp d _ _ _ => some d
  | .get d _ _ => some d
  | .set .. => none
  | .makeUnique _ => none
  | .gen dst _ _ _ => dst

/-- the in/out receiver that a call redefines -/
def RI.recv : RI → Option Nat
  | .gen _ _ _ r => r
  | _ => none

/-- `keeps ins a`: the instruction leaves the length and kind of the array held by `a` as it was
(`RStep.keeps`): a read, an element store, `makeunique`, a forward, the length itself, a borrowed call -/
def RI.keeps : RI → Nat → Bool
  | .get d a' i, a => decide (d ≠ a) && decide (a' = a) && decide (i ≠ .loc a)
  | .set x i v, a => decide (x = a) && decide (i ≠ .loc a) && decide (v ≠ a)
  | .makeUnique x, a => decide (x = a)
  | .forward d s o, a => decide (d ≠ a) && decide (s ≠ a) && decide (o = a)
  | .arrLen d a', a => decide (d ≠ a) && decide (a' = a)
  | .gen _ _ kept _, a => decide (a ∈ kept)
  | _, _ => false

/-! ### abstract state -/

/-- the comparison recorded for a following branch -/
structure Note where
  c : Nat
  op : Cmp
  x : Opd
  y : Opd

structure RS where
  iv : List Iv
  dead : Bool
  note : Option Note

/-- interval of local `l` (out-of-range locals are unknown; the verifier's functions are well formed) -/
def gi (iv : List Iv) (l : Nat) : Iv := (iv[l]?).getD Iv.unk

def clsOf (cls : List Cls) (l : Nat) : Cls := cls.getD l .int

/-- `known`: the local holds an array of known length (`lo >= 0`, only `arraynew` and `move` give it) -/
def known (cls : List Cls) (iv : List Iv) (a : Nat) : Prop :=
  clsOf cls a = .ref ∧ 0 ≤ (gi iv a).lo

instance (cls : List Cls) (iv : List Iv) (a : Nat) : Decidable (known cls iv a) := by
  unfold known; infer_instance

def opLo (iv : List Iv) : Opd → Int
  | .loc l => (gi iv l).lo
  | .cint n => if n > NEG ∧ n < BIG then n else NEG
  | .cusize n => if n ≥ 0 ∧ n < BIG then n else 0

def opHi (iv : List Iv) : Opd → Int
  | .loc l => (gi iv l).hi
  | .cint n => if n > NEG ∧ n < BIG then n else BIG
  | .cusize n => if n ≥ 0 ∧ n < BIG then n else BIG

def opCls (cls : List Cls) : Opd → Cls
  | .loc l => clsOf cls l
  | .cint _ => .int
  | .cusize _ => .usize

/-- the local becomes "unknown" (a usize is still never negative) -/
def forget (cls : List Cls) (iv : List Iv) (l : Nat) : List Iv :=
  iv.set l ⟨floorOf (clsOf cls l), BIG⟩

/-- `assign`: the interval `[lo, hi]` for the defined local, normalised -/
def assign (cls : List Cls) (iv : List Iv) (d : Nat) (lo hi : Int) : List Iv :=
  let l := if clsOf cls d = .usize ∧ lo < 0 then 0 else lo
  if l > hi then forget cls iv d else iv.set d ⟨l, hi⟩

/-- `d = x + y` / `d = x - y` of two operands of class `c`: the result interval and whether the path
always traps (an always-underflowing `usize` subtraction ends the path) -/
def arith (cls : List Cls) (iv : List Iv) (c : Cls) (sub : Bool) (x y : Opd) : Int × Int × Bool :=
  if opCls cls x = c ∧ opCls cls y = c then
    let xl := opLo iv x
    let xh := opHi iv x
    let yl := opLo iv y
    let yh := opHi iv y
    if !sub then (addLo xl yl, addHi xh yh, false)
    else
      let rl := subLo xl yh
      let rh := subHi xh yl
      if c = .usize then ((if rl < 0 then 0 else rl), rh, decide (rh < 0)) else (rl, rh, false)
  else (NEG, BIG, false)

/-- the interval of the value an instruction defines, and the dead flag -/
def resOf (cls : List Cls) (iv : List Iv) : RI → Int × Int × Bool
  | .copy _ o => (opLo iv o, opHi iv o, false)
  | .move _ s => ((gi iv s).lo, (gi iv s).hi, false)
  | .forward _ s _ => ((gi iv s).lo, (gi iv s).hi, false)
  | .arrayNew _ n => ((n : Int), (n : Int), false)
  | .arrLen _ a =>
    if known cls iv a then ((gi iv a).lo, (gi iv a).hi, false) else (0, BIG, false)
  | .add d x y =>
    if clsOf cls d = .int ∨ clsOf cls d = .usize then arith cls iv (clsOf cls d) false x y
    else (NEG, BIG, false)
  | .sub d x y =>
    if clsOf cls d = .int ∨ clsOf cls d = .usize then arith cls iv (clsOf cls d) true x y
    else (NEG, BIG, false)
  | _ => (NEG, BIG, false)

/-- every mentioned array fact that the instruction does not keep is destroyed -/
def destroy (cls : List Cls) (ins : RI) (iv : List Iv) : List Iv :=
  iv.mapIdx fun l x =>
    if decide (l ∈ ins.men) && decide (known cls iv l) && !ins.keeps l then Iv.unk else x

/-- a recorded comparison dies when one of its locals is defined -/
def disturb (note : Option Note) (l : Nat) : Option Note :=
  match note with
  | some n => if l = n.c ∨ n.x = .loc l ∨ n.y = .loc l then none else some n
  | none => none

/-- `noteCompare` -/
def noteCmp (cls : List Cls) (ins : RI) (note : Option Note) : Option Note :=
  match ins with
  | .cmp d op x y =>
    if clsOf cls d = .bool ∧ (opCls cls x = .int ∨ opCls cls x = .usize) ∧ opCls cls y = opCls cls x
    then some ⟨d, op, x, y⟩ else note
  | _ => note

/-- `RStep.step`: one instruction -/
def step (cls : List Cls) (ins : RI) (rs : RS) : RS :=
  if rs.dead then rs else
  match resOf cls rs.iv ins with
  | (rl, rh, dd) =>
    if dd then { rs with dead := true } else
    let iv1 := destroy cls ins rs.iv
    let iv2 := match ins.recv with | some x => forget cls iv1 x | none => iv1
    let n2 := match ins.recv with | some x => disturb rs.note x | none => rs.note
    let iv3 := match ins.dst with | some d => assign cls iv2 d rl rh | none => iv2
    let n3 := match ins.dst with | some d => disturb n2 d | none => n2
    { iv := iv3, dead := false, note := noteCmp cls ins n3 }

def runA (cls : List Cls) : List RI → RS → RS
  | [], rs => rs
  | i :: is, rs => runA cls is (step cls i rs)

/-! ### R3: branch refinement -/

/-- `hi(o) <= v` -/
def capHi (rs : RS) (o : Opd) (v : Int) : RS :=
  match o with
  | .loc l =>
    let w := if v < NEG then NEG else v
    if w < (gi rs.iv l).hi then
      { rs with iv := rs.iv.set l ⟨(gi rs.iv l).lo, w⟩, dead := rs.dead || decide ((gi rs.iv l).lo > w) }
    else rs
  | _ => rs

/-- `lo(o) >= v` -/
def raiseLo (rs : RS) (o : Opd) (v : Int) : RS :=
  match o with
  | .loc l =>
    let w := if v > BIG then BIG else v
    if w > (gi rs.iv l).lo then
      { rs with iv := rs.iv.set l ⟨w, (gi rs.iv l).hi⟩, dead := rs.dead || decide (w > (gi rs.iv l).hi) }
    else rs
  | _ => rs

/-- `a < b` -/
def less (rs : RS) (a b : Opd) : RS :=
  let bh := opHi rs.iv b
  let al := opLo rs.iv a
  let rs1 := if bh < BIG then capHi rs a (bh - 1) else rs
  if al > NEG then raiseLo rs1 b (al + 1) else rs1

/-- `a <= b` -/
def atMost (rs : RS) (a b : Opd) : RS :=
  let bh := opHi rs.iv b
  let al := opLo rs.iv a
  let rs1 := if bh < BIG then capHi rs a bh else rs
  if al > NEG then raiseLo rs1 b al else rs1

/-- `a == b` -/
def same (rs : RS) (a b : Opd) : RS := atMost (atMost rs a b) b a

/-- the recorded comparison holds (`truth`) or does not hold on the edge; operators as in the code -/
def refine (rs : RS) (n : Note) (truth : Bool) : RS :=
  match n.op, truth with
  | .lt, true => less rs n.x n.y
  | .lt, false => atMost rs n.y n.x
  | .le, true => atMost rs n.x n.y
  | .le, false => less rs n.y n.x
  | .gt, true => less rs n.y n.x
  | .gt, false => atMost rs n.x n.y
  | .ge, true => atMost rs n.y n.x
  | .ge, false => less rs n.x n.y
  | .eq, true => same rs n.x n.y
  | .eq, false => rs
  | .ne, true => rs
  | .ne, false => same rs n.x n.y

end Range
end Orin
