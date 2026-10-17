import Orin.Mir

/-!
# The ownership checker (abstract interpretation of `docs/mir.md`)

`AS` is the per-local abstract state of the verifier (`compiler/verify/state.or`):
`dead | init | owned | unique | borrowed src | param | poison`
(`init` = initialised scalar, `poison` = the join of disagreeing states, i.e. `MaybeDead` /
`MaybeLeak`; `Imm` immortals are not modelled).  `stepL` is one transfer function per
instruction (`compiler/verify/rules.or`), `stepH` the hole-set discipline, `joinS` the join at
the end of an `if`/`else`, `chk` the checker and `check` the whole-program decision.

This is a transcription of the *rules* (`docs/mir.md` plus its implementation notes), not a
verification of the Orin source of the verifier.  Differences, all of which make this checker
stricter or are encoding choices, are listed in `docs/formal.md` (section "Mechanised ownership
analysis"): (1) a borrow/projection result may not be rooted at its own destination
(`rootOf src ≠ d`; the verifier accepts the self-rooted `Borrowed(d)` with a leak warning),
(2) a join keeps `Borrowed(r)` only when `r` joins to a root kind, (3) `IStructNew` is the macro
`alloc` + `setField`s, so an operand equal to the destination is rejected, (4) `setField`/`putField`
reject `v = x` (as `wf.or` does), (5) there are no leak warnings and `MaybeDead`/`MaybeLeak` are
one kind `poison`.
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

/-- `IGetField` / `IArrayGet` rule. -/
def stepGet (np : Nat) (a : List AS) (d o : Nat) (r : Bool) : Option (List AS) :=
  if d < a.length ∧ o < a.length ∧ np ≤ d ∧ (gk a o).isRef then
    if r then
      (if rootOf a o ≠ d then some (defK a d (.borrowed (rootOf a o))) else none)
    else some (defK a d .init)
  else none

/-- `ISetField` / `IPutField` / `IArraySet` rule. -/
def stepSet (a : List AS) (x v : Nat) : Option (List AS) :=
  if x < a.length ∧ x ≠ v ∧ gk a x = .unique then (consume a v).map (killB x) else none

/-- `IArrayNew` / `alloc` rule. -/
def stepAlloc (np : Nat) (a : List AS) (d : Nat) : Option (List AS) :=
  if d < a.length ∧ np ≤ d then some (defK a d .unique) else none

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
  | .alloc d _ => stepAlloc np a d
  | .getField d o _ r => stepGet np a d o r
  | .setField x _ v => stepSet a x v
  | .takeField d x _ =>
    if d < a.length ∧ x < a.length ∧ np ≤ d ∧ d ≠ x ∧ gk a x = .unique then
      some (defK (killB x a) d .owned)
    else none
  | .putField x _ s => stepSet a x s
  | .makeUnique x =>
    if x < a.length ∧ (gk a x).counted then some ((killB x a).set x .unique) else none
  | .arrayLen d x =>
    if d < a.length ∧ x < a.length ∧ np ≤ d ∧ (gk a x).isRef then some (defK a d .init) else none
  | .arrayGet d x i r => if i < a.length ∧ gk a i = .init then stepGet np a d x r else none
  | .arraySet x i v => if i < a.length ∧ gk a i = .init then stepSet a x v else none
  | .arrayNew d nl => if nl < a.length ∧ gk a nl = .init then stepAlloc np a d else none

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
  | .alloc d n => if hasHole hs d then none else some (hs ++ (List.range n).map (fun i => (d, i)))
  | .getField d o i _ => if hasHole hs d || decide ((o, i) ∈ hs) then none else some hs
  | .setField x i v => if hasHole hs v || decide ((x, i) ∈ hs) then none else some hs
  | .takeField d x i => if hasHole hs d || decide ((x, i) ∈ hs) then none else some ((x, i) :: hs)
  | .putField x i s =>
    if hasHole hs s || !decide ((x, i) ∈ hs) then none
    else some (hs.filter (fun p => p != (x, i)))
  | .makeUnique x => if hasHole hs x then none else some hs
  | .arrayLen d a => if hasHole hs d || hasHole hs a then none else some hs
  | .arrayGet d a _ _ => if hasHole hs d || hasHole hs a then none else some hs
  | .arraySet x _ v => if hasHole hs v || hasHole hs x then none else some hs
  | .arrayNew d _ => if hasHole hs d then none else some hs

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

/-! ### calls -/

/-- Signature of a callee as the caller sees it. -/
structure Sig where
  params : List PM
  retRef : Bool

/-- the operands in owned-parameter positions (consumed by the call) -/
def ownedArgs (ps : List PM) (args : List Nat) : List Nat :=
  (args.zip ps).filterMap (fun p => if p.2 = .owned then some p.1 else none)

/-- The caller's state while the callee runs: consumed operands and their aliases are dead, and no
local is `Unique` any more (the callee may hold, and drop, a reference to the object). -/
def midK (own : List Nat) (a : List AS) : List AS :=
  a.mapIdx fun i k =>
    if i ∈ own then .dead else
    match k with
    | .borrowed r => if r ∈ own then .dead else .borrowed r
    | .unique => .owned
    | k => k

/-- one operand against its parameter mode: a scalar parameter takes an initialised scalar, a
borrowed one any readable reference whose root is not consumed by the same call, an owned one a
counted local. -/
def argOK (a : List AS) (own : List Nat) : Nat × PM → Bool
  | (j, .scalar) => decide (gk a j = .init)
  | (j, .borrowed) => (gk a j).isRef && decide (rootOf a j ∉ own)
  | (j, .owned) => (gk a j).counted

def stepCall (sg : List Sig) (np : Nat) (a : List AS) (d f : Nat) (args : List Nat) :
    Option (List AS) :=
  match sg[f]? with
  | none => none
  | some sig =>
    if args.length = sig.params.length ∧ d < a.length ∧ np ≤ d ∧
        (ownedArgs sig.params args).Nodup ∧
        (args.zip sig.params).all (argOK a (ownedArgs sig.params args)) = true then
      some (defK (midK (ownedArgs sig.params args) a) d (if sig.retRef then .owned else .init))
    else none

def stepAC (np : Nat) (sg : List Sig) (a : AState) (d f : Nat) (args : List Nat) :
    Option AState :=
  match stepCall sg np a.ls d f args with
  | none => none
  | some ls' =>
    if a.holes.isEmpty then some ⟨ls', a.holes⟩ else none

/-- Loop invariant search: from the head state `b`, run the body, join the result into the head
state, and stop when the head state no longer changes (kinds only move up the join order, so a
bounded number of rounds suffices; running out of fuel rejects).  Returns the invariant. -/
def loopFix (body : AState → Option AState) (c : Nat) : Nat → AState → Option AState
  | 0, _ => none
  | fuel + 1, b =>
    if c < b.ls.length ∧ gk b.ls c = .init then
      (body b).bind fun b2 =>
      (joinS b b2).bind fun b' =>
      if b'.ls = b.ls then some b else loopFix body c fuel b'
    else none

def loopFuel (a : AState) : Nat := 2 * a.ls.length + 3

/-- Abstract execution of structured code; `none` = rejected. -/
def chk (np : Nat) (sg : List Sig) : AState → Code → Option AState
  | a, .nil => some a
  | a, .op i k => (stepA np a i).bind (fun a1 => chk np sg a1 k)
  | a, .ite c t e k =>
    if c < a.ls.length ∧ gk a.ls c = .init then
      (chk np sg a t).bind fun at' =>
      (chk np sg a e).bind fun ae =>
      (joinS at' ae).bind fun aj =>
      chk np sg aj k
    else none
  | a, .loop c t k =>
    (loopFix (fun b => chk np sg b t) c (loopFuel a) a).bind fun b => chk np sg b k
  | a, .call d f args k => (stepAC np sg a d f args).bind fun a1 => chk np sg a1 k

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
  match chk p.params.length [] p.entry p.code with
  | some af => af.holes.isEmpty
  | none => false

end Orin
