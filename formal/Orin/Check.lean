import Orin.Mir

/-!
# The ownership checker (abstract interpretation of `docs/mir.md`)

`AS` is the per-local abstract state of the verifier (`compiler/verify/state.or`):
`dead | init | owned | unique | borrowed src | param | poison`
(`init` = initialised scalar, `poison` = the join of disagreeing states, i.e. `MaybeDead` /
`MaybeLeak`; `Imm` immortals are not modelled).  `stepL` is one transfer function per
instruction (`compiler/verify/rules.or`), `stepH` the hole-set discipline, `joinS` the join at
the end of an `if`/`else`, `chk` the checker and `check` the whole-program decision.

Differences from the Orin implementation are listed in `docs/formal.md` (section "Mechanised
ownership analysis"); the only ones that make this checker *stricter* are
`d ≠ rootOf(src)` for borrows (the verifier accepts the self-rooted result with a leak
warning) and that a join keeps `Borrowed(r)` only when `r` joins to a root state.
-/

namespace Orin

inductive AS where
  | dead
  | init
  | owned
  | unique
  | borrowed (src : Nat)
  | param
  | poison
  deriving DecidableEq, Repr

namespace AS

/-- the local holds one count of its own (released or consumed later) -/
def counted : AS → Bool
  | .owned => true
  | .unique => true
  | _ => false

/-- a kind that a borrow may be rooted at -/
def isRoot : AS → Bool
  | .owned => true
  | .unique => true
  | .param => true
  | _ => false

/-- a readable reference -/
def isRef : AS → Bool
  | .owned => true
  | .unique => true
  | .param => true
  | .borrowed _ => true
  | _ => false

/-- `k ≤ k'`: `k'` is a (sound) weakening of `k` (join order) -/
def le (k k' : AS) : Prop := k = k' ∨ k' = .poison ∨ (k = .unique ∧ k' = .owned)

end AS

structure AState where
  ls : List AS
  holes : List (Nat × Nat)

def gk (a : List AS) (i : Nat) : AS := a.getD i .dead

/-- invalidate every `Borrowed(x)` alias -/
def killB (x : Nat) (a : List AS) : List AS :=
  a.map (fun k => if k = .borrowed x then .dead else k)

/-- define local `d` with kind `k` (invalidating aliases of `d`) -/
def defK (a : List AS) (d : Nat) (k : AS) : List AS := (killB d a).set d k

/-- a counted local ceases to exist -/
def killK (a : List AS) (l : Nat) : List AS := defK a l .dead

/-- a `Unique` local that is aliased is no longer provably unique -/
def demote (a : List AS) (l : Nat) : List AS :=
  if gk a l = .unique then a.set l .owned else a

/-- the root a new borrow of `l` depends on -/
def rootOf (a : List AS) (l : Nat) : Nat :=
  match gk a l with
  | .borrowed r => r
  | _ => l

/-- Consume an operand: scalars are only read; counted locals die; everything else is an
error (`Param`, `Borrowed`, `Dead`, poisoned). -/
def consume (a : List AS) (v : Nat) : Option (List AS) :=
  if v < a.length then
    match gk a v with
    | .init => some a
    | .owned => some (killK a v)
    | .unique => some (killK a v)
    | _ => none
  else none

/-- Kind transfer function (one rule per instruction of `docs/mir.md`). `np` = number of
parameters (never redefined). -/
def stepL (np : Nat) (a : List AS) : MI → Option (List AS)
  | .const d _ =>
    if d < a.length ∧ np ≤ d then some (defK a d .init) else none
  | .move d s =>
    if d < a.length ∧ s < a.length ∧ np ≤ d ∧ d ≠ s ∧ (gk a s).counted then
      some (defK (killK a s) d (gk a s))
    else none
  | .borrow d s =>
    if d < a.length ∧ s < a.length ∧ np ≤ d ∧ d ≠ s ∧ (gk a s).isRef ∧ rootOf a s ≠ d then
      some (defK (demote a s) d (.borrowed (rootOf a s)))
    else none
  | .dup d s =>
    if d < a.length ∧ s < a.length ∧ np ≤ d ∧ (gk a s).isRef then
      some (defK (demote a s) d .owned)
    else none
  | .release x =>
    if x < a.length ∧ (gk a x).counted then some (killK a x) else none
  | .alloc d _ =>
    if d < a.length ∧ np ≤ d then some (defK a d .unique) else none
  | .getField d o _ r =>
    if d < a.length ∧ o < a.length ∧ np ≤ d ∧ (gk a o).isRef then
      if r then
        (if rootOf a o ≠ d then some (defK a d (.borrowed (rootOf a o))) else none)
      else some (defK a d .init)
    else none
  | .setField x _ v =>
    if x < a.length ∧ x ≠ v ∧ gk a x = .unique then (consume a v).map (killB x) else none
  | .takeField d x _ =>
    if d < a.length ∧ x < a.length ∧ np ≤ d ∧ d ≠ x ∧ gk a x = .unique then
      some (defK (killB x a) d .owned)
    else none
  | .putField x _ s =>
    if x < a.length ∧ x ≠ s ∧ gk a x = .unique then (consume a s).map (killB x) else none
  | .makeUnique x =>
    if x < a.length ∧ (gk a x).counted then some ((killB x a).set x .unique) else none

/-! ### hole sets -/

def hasHole (hs : List (Nat × Nat)) (x : Nat) : Bool := hs.any (fun p => p.1 == x)

/-- Hole discipline of `docs/mir.md` (take / put / no read or whole-object use of an object with
an open hole / no overwriting of a local that names a hole). -/
def stepH (hs : List (Nat × Nat)) : MI → Option (List (Nat × Nat))
  | .const d _ => if hasHole hs d then none else some hs
  | .move d s => if hasHole hs d || hasHole hs s then none else some hs
  | .borrow d s => if hasHole hs d || hasHole hs s then none else some hs
  | .dup d s => if hasHole hs d || hasHole hs s then none else some hs
  | .release x => if hasHole hs x then none else some hs
  | .alloc d _ => if hasHole hs d then none else some hs
  | .getField d o i _ => if hasHole hs d || decide ((o, i) ∈ hs) then none else some hs
  | .setField x i v => if hasHole hs v || decide ((x, i) ∈ hs) then none else some hs
  | .takeField d x i => if hasHole hs d || decide ((x, i) ∈ hs) then none else some ((x, i) :: hs)
  | .putField x i s =>
    if hasHole hs s || !decide ((x, i) ∈ hs) then none
    else some (hs.filter (fun p => p != (x, i)))
  | .makeUnique x => if hasHole hs x then none else some hs

def stepA (np : Nat) (a : AState) (i : MI) : Option AState :=
  match stepL np a.ls i with
  | none => none
  | some ls' => (stepH a.holes i).map (fun h' => ⟨ls', h'⟩)

/-! ### join -/

def jk (k1 k2 : AS) : AS :=
  if k1 = k2 then k1 else if k1.counted && k2.counted then .owned else .poison

/-- a `Borrowed(r)` survives a join only if `r` itself joins to a root kind -/
def postK (j : List AS) : AS → AS
  | .borrowed r => if (gk j r).isRoot then .borrowed r else .poison
  | k => k

/-- pointwise join of kinds -/
def joinL (a1 a2 : List AS) : List AS :=
  (List.zipWith jk a1 a2).map (postK (List.zipWith jk a1 a2))

def holesEq (h1 h2 : List (Nat × Nat)) : Bool :=
  h1.all (fun p => decide (p ∈ h2)) && h2.all (fun p => decide (p ∈ h1))

def joinS (a1 a2 : AState) : Option AState :=
  if a1.ls.length = a2.ls.length ∧ holesEq a1.holes a2.holes = true then
    some ⟨joinL a1.ls a2.ls, a1.holes⟩
  else none

/-! ### the checker -/

/-- Abstract execution of structured code; `none` = rejected. -/
def chk (np : Nat) : AState → Code → Option AState
  | a, .nil => some a
  | a, .op i k => (stepA np a i).bind (fun a1 => chk np a1 k)
  | a, .ite c t e k =>
    if c < a.ls.length ∧ gk a.ls c = .init then
      (chk np a t).bind fun at' =>
      (chk np a e).bind fun ae =>
      (joinS at' ae).bind fun aj =>
      chk np aj k
    else none

structure Prog where
  /-- number of locals -/
  n : Nat
  /-- parameter classes: `true` = reference (borrowed for the whole body), `false` = scalar -/
  params : List Bool
  code : Code

def Prog.entry (p : Prog) : AState :=
  ⟨p.params.map (fun r => if r then AS.param else AS.init) ++
     List.replicate (p.n - p.params.length) AS.dead, []⟩

/-- Whole-function check: the code is accepted and no hole is open at the end. -/
def check (p : Prog) : Bool :=
  p.params.length ≤ p.n &&
  match chk p.params.length p.entry p.code with
  | some af => af.holes.isEmpty
  | none => false

end Orin
