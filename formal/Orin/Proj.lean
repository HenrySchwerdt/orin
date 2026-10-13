import Orin.Check
import Orin.WFx

/-!
# Simulation relation: projection of the abstract state onto the counted owners

`projL a ls` keeps exactly the locals that the abstract state `a` says are *counted*
(`Owned`/`Unique`) and replaces every other local (`Dead`, `Init`, `Borrowed`, `Param`,
poisoned) by the dead marker `int 0`.  `Pst ext a s` is the machine state seen as the old
model's `St`: counted locals, the pending worklist, and a fixed list `ext` of references held by
the *caller* (these account for the `Param` locals, which are borrowed for the whole call).  The
old invariant `WF` of `WF.lean` on this projected state is the RC-soundness half of the
simulation relation; `Inv` (below) adds the claims about `Init`, `Unique`, `Param` and `Borrowed`.
-/

namespace Orin
open Heap

/-! ### list helpers on abstract states -/

theorem killB_length (x : Nat) (a : List AS) : (killB x a).length = a.length := by
  simp [killB]

theorem gk_set (a : List AS) (j : Nat) (k : AS) (i : Nat) (hj : j < a.length) :
    gk (a.set j k) i = if i = j then k else gk a i := by
  by_cases h : i = j
  · subst h; simp [gk, hj]
  · simp [gk, List.getD_eq_getElem?_getD, List.getElem?_set, h, Ne.symm h]

theorem gk_killB (x : Nat) (a : List AS) (i : Nat) :
    gk (killB x a) i = if gk a i = .borrowed x then .dead else gk a i := by
  by_cases hi : i < a.length
  · simp [gk, killB, hi]
  · simp [gk, killB, hi, List.getD_eq_getElem?_getD]

theorem gk_defK (a : List AS) (d : Nat) (k : AS) (i : Nat) (hd : d < a.length) :
    gk (defK a d k) i = if i = d then k else if gk a i = .borrowed d then .dead else gk a i := by
  unfold defK
  rw [gk_set _ _ _ _ (by rw [killB_length]; exact hd), gk_killB]

theorem length_defK (a : List AS) (d : Nat) (k : AS) : (defK a d k).length = a.length := by
  simp [defK, killB]

theorem length_demote (a : List AS) (l : Nat) : (demote a l).length = a.length := by
  unfold demote; split <;> simp

theorem gk_demote (a : List AS) (l i : Nat) (hl : l < a.length) :
    gk (demote a l) i = if i = l ∧ gk a l = .unique then .owned else gk a i := by
  unfold demote
  by_cases h : gk a l = .unique
  · simp only [h, if_true]
    rw [gk_set _ _ _ _ hl]
    by_cases hi : i = l <;> simp [hi, h]
  · simp [h]

/-! ### projection -/

def pv (k : AS) (v : Val) : Val := if k.counted then v else .int 0

def projL (a : List AS) (ls : List Val) : List Val := ls.mapIdx (fun i v => pv (gk a i) v)

def Pst (ext : List Val) (a : List AS) (s : St) : St :=
  ⟨s.heap, projL a s.locals ++ ext, s.pending⟩

theorem projL_length (a : List AS) (ls : List Val) : (projL a ls).length = ls.length := by
  simp [projL]

theorem projL_getElem? (a : List AS) (ls : List Val) (i : Nat) :
    (projL a ls)[i]? = ls[i]?.map (pv (gk a i)) := by
  simp [projL, List.getElem?_mapIdx]

/-- `Desc H p w`: `w` is the root object `p` itself or lies in a slot of an object reachable from
`p` through slots (the possible values of a `Borrowed` alias rooted at a local holding `p`). -/
inductive Desc (H : Heap) (p : Nat) : Val → Prop
  | self : Desc H p (.ref p)
  | field {l : Nat} {o : Obj} {w : Val} :
      H.objs l = some o → w ∈ o.fields → Desc H p (.ref l) → Desc H p w

/-- Per-local claims of the abstract state about the concrete state. -/
structure ClAt (ext : List Val) (a : List AS) (s : St) (i : Nat) : Prop where
  /-- `Init` locals hold scalars -/
  ini : gk a i = .init → ∃ n, s.get i = .int n
  /-- `Unique` locals hold a reference to a count-1 object -/
  uniq : gk a i = .unique → ∃ l o, s.get i = .ref l ∧ s.heap.objs l = some o ∧ o.rc = 1
  /-- `Param` locals hold a reference owned by the caller -/
  prm : gk a i = .param → s.get i ∈ ext
  /-- `Borrowed r`: `r` is a root (counted or parameter) holding `ref p`, and the alias lies in
  the `Desc` chain of `p`; a root that is `Unique` is not aliased by its own whole object -/
  bor : ∀ r, gk a i = .borrowed r → (gk a r).isRoot = true ∧ ∃ p, s.get r = .ref p ∧
      Desc s.heap p (s.get i) ∧ (gk a r = .unique → s.get i ≠ .ref p)
  /-- every reference-kind local holds a reference -/
  ref : (gk a i).isRef = true → ∃ l, s.get i = .ref l

/-- The simulation relation between abstract state `a` and concrete state `s`
(`ext` = references held by the caller on behalf of the parameters). -/
structure Inv (ext : List Val) (a : List AS) (s : St) : Prop where
  len : a.length = s.locals.length
  wf : WF (Pst ext a s)
  cl : ∀ i, ClAt ext a s i

theorem Pst_get (ext : List Val) (a : List AS) (s : St) (i : Nat) (hi : i < s.locals.length) :
    (Pst ext a s).get i = pv (gk a i) (s.get i) := by
  have h1 : (projL a s.locals)[i]? = some (pv (gk a i) (s.get i)) := by
    rw [projL_getElem?]; simp [St.get, hi]
  have h2 : (projL a s.locals ++ ext)[i]? = some (pv (gk a i) (s.get i)) := by
    rw [List.getElem?_append_left (by rw [projL_length]; exact hi)]; exact h1
  simp [St.get, Pst, h2]

theorem Pst_get_counted {ext a s i} (hi : i < s.locals.length) (h : (gk a i).counted = true) :
    (Pst ext a s).get i = s.get i := by
  rw [Pst_get ext a s i hi]; simp [pv, h]

theorem Pst_locals_length (ext : List Val) (a : List AS) (s : St) :
    (Pst ext a s).locals.length = s.locals.length + ext.length := by
  simp [Pst, projL_length]

theorem mem_Pst_of_counted {ext a s i} (hi : i < s.locals.length) (h : (gk a i).counted = true) :
    s.get i ∈ (Pst ext a s).locals := by
  rw [← Pst_get_counted hi h]
  exact St.get_mem _ _ (by rw [Pst_locals_length]; omega)

theorem mem_Pst_of_ext {ext a s v} (h : v ∈ ext) : v ∈ (Pst ext a s).locals := by
  simp [Pst, h]

end Orin
