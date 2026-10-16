/-!
# Orin memory IR: heap model

Values, heap objects, and the primitive heap operations of the Orin runtime
(`runtime/core/orin_runtime.h`): allocation, retain, decrement, free, shallow copy support.

Modelling choices (see `docs/formal.md`):
* A location is a `Nat`. Locations are never reused (`next` only grows), so a freed
  location stays dead forever. This is *stronger* than a real allocator (which reuses
  addresses); reuse is sound in the real system exactly because the invariant proved
  here says no reference to a freed object exists.
* Immortal objects (negative `rc`) are not modelled.
-/

namespace Orin

/-- A scalar or a reference to a heap location. -/
inductive Val where
  | int (n : Int)
  | ref (l : Nat)
  deriving DecidableEq, Repr

/-- A heap object: reference count and slots (the runtime's `OrinStruct`/`OrinArray`). -/
structure Obj where
  rc : Nat
  fields : List Val

/-- A heap: partial map from locations to objects (`none` = freed / never allocated),
plus the allocation frontier. -/
structure Heap where
  objs : Nat → Option Obj
  next : Nat

namespace Heap

/-- Value is a scalar or a reference to a live object. -/
def LiveVal (H : Heap) : Val → Prop
  | .int _ => True
  | .ref l => ∃ o, H.objs l = some o

def liveb (H : Heap) : Val → Bool
  | .int _ => true
  | .ref l => (H.objs l).isSome

theorem liveb_iff (H : Heap) (v : Val) : H.liveb v = true ↔ H.LiveVal v := by
  cases v with
  | int n => simp [liveb, LiveVal]
  | ref l =>
    simp only [liveb, LiveVal]
    cases h : H.objs l <;> simp

/-- Add `vs.count (ref k)` to the count of every object `k`: i.e. `retain` each reference
in `vs` (scalars are ignored). Retaining a dead location is not detected here; callers check
`liveb` first. -/
def bump (H : Heap) (vs : List Val) : Heap :=
  { H with objs := fun k => (H.objs k).map (fun o => { o with rc := o.rc + vs.count (.ref k) }) }

/-- Allocate a fresh object with count 1. Returns the new heap and the fresh location. -/
def alloc (H : Heap) (fs : List Val) : Heap × Nat :=
  ({ objs := fun k => if k = H.next then some ⟨1, fs⟩ else H.objs k, next := H.next + 1 }, H.next)

/-- Replace the object at `l`. -/
def setObj (H : Heap) (l : Nat) (o : Obj) : Heap :=
  { H with objs := fun k => if k = l then some o else H.objs k }

/-- Free the object at `l`. -/
def del (H : Heap) (l : Nat) : Heap :=
  { H with objs := fun k => if k = l then none else H.objs k }

/-- Decrement the count at `l` (no free). -/
def decRc (H : Heap) (l : Nat) : Heap :=
  match H.objs l with
  | some o => H.setObj l { o with rc := o.rc - 1 }
  | none => H

/-- Number of references to `l` held in fields of objects at `m`. -/
def cnt (H : Heap) (m l : Nat) : Nat :=
  match H.objs m with
  | some o => o.fields.count (.ref l)
  | none => 0

/-- Number of references to `l` held by fields of live heap objects. -/
def refs (H : Heap) (l : Nat) : Nat :=
  ((List.range H.next).map (fun m => H.cnt m l)).sum

/-! ### sums over `range` -/

theorem sum_range_upd (g g' : Nat → Nat) (m : Nat) (h : ∀ k, k ≠ m → g' k = g k) :
    ∀ n, m < n → ((List.range n).map g').sum + g m = ((List.range n).map g).sum + g' m := by
  intro n
  induction n with
  | zero => intro hm; omega
  | succ n ih =>
    intro hm
    rw [List.range_succ]
    simp only [List.map_append, List.sum_append, List.map_cons, List.map_nil, List.sum_cons,
      List.sum_nil]
    by_cases hmn : m = n
    · subst hmn
      have : (List.range m).map g' = (List.range m).map g := by
        apply List.map_congr_left
        intro k hk
        have := List.mem_range.mp hk
        exact h k (by omega)
      rw [this]; omega
    · have := ih (by omega)
      rw [h n (Ne.symm hmn)]; omega

theorem sum_range_snoc (g g' : Nat → Nat) (n : Nat) (h : ∀ k, k < n → g' k = g k) :
    ((List.range (n + 1)).map g').sum = ((List.range n).map g).sum + g' n := by
  rw [List.range_succ]
  simp only [List.map_append, List.sum_append, List.map_cons, List.map_nil, List.sum_cons,
    List.sum_nil]
  have : (List.range n).map g' = (List.range n).map g := by
    apply List.map_congr_left
    intro k hk
    exact h k (List.mem_range.mp hk)
  rw [this]; omega

theorem cnt_congr (H H' : Heap) (k l : Nat) (h : H'.objs k = H.objs k) : H'.cnt k l = H.cnt k l := by
  unfold cnt; rw [h]

theorem refs_upd (H H' : Heap) (m l : Nat) (hn : H'.next = H.next) (hm : m < H.next)
    (h : ∀ k, k ≠ m → H'.objs k = H.objs k) :
    H'.refs l + H.cnt m l = H.refs l + H'.cnt m l := by
  unfold refs
  rw [hn]
  exact sum_range_upd (fun k => H.cnt k l) (fun k => H'.cnt k l) m
    (fun k hk => cnt_congr H H' k l (h k hk)) H.next hm

theorem refs_same (H H' : Heap) (l : Nat) (hn : H'.next = H.next)
    (h : ∀ k, H'.cnt k l = H.cnt k l) : H'.refs l = H.refs l := by
  unfold refs
  rw [hn]
  congr 1
  apply List.map_congr_left
  intro k _
  exact h k

theorem refs_alloc (H : Heap) (fs : List Val) (l : Nat) :
    (H.alloc fs).1.refs l = H.refs l + fs.count (.ref l) := by
  unfold refs
  have hn : (H.alloc fs).1.next = H.next + 1 := rfl
  rw [hn]
  rw [sum_range_snoc (fun k => H.cnt k l) (fun k => (H.alloc fs).1.cnt k l)]
  · simp [cnt, alloc]
  · intro k hk
    unfold cnt alloc
    simp [show k ≠ H.next by omega]

/-! ### bump -/

theorem bump_next (H : Heap) (vs) : (H.bump vs).next = H.next := rfl

theorem bump_objs_none (H : Heap) (vs k) : (H.bump vs).objs k = none ↔ H.objs k = none := by
  simp [bump]

theorem bump_objs_some (H : Heap) (vs k o) (h : H.objs k = some o) :
    (H.bump vs).objs k = some { o with rc := o.rc + vs.count (.ref k) } := by
  simp [bump, h]

theorem bump_cnt (H : Heap) (vs m l) : (H.bump vs).cnt m l = H.cnt m l := by
  unfold cnt bump
  cases h : H.objs m <;> simp [h]

theorem bump_refs (H : Heap) (vs l) : (H.bump vs).refs l = H.refs l :=
  refs_same _ _ l rfl (fun k => bump_cnt H vs k l)

theorem bump_live (H : Heap) (vs v) : (H.bump vs).LiveVal v ↔ H.LiveVal v := by
  cases v with
  | int n => simp [LiveVal]
  | ref l =>
    simp only [LiveVal, bump]
    cases h : H.objs l <;> simp

end Heap
end Orin

namespace Orin.Heap

theorem bump_inv (H : Heap) (vs : List Val) (k : Nat) (o' : Obj) (h : (H.bump vs).objs k = some o') :
    ∃ o, H.objs k = some o ∧ o' = { o with rc := o.rc + vs.count (.ref k) } := by
  simp only [bump] at h
  cases ho : H.objs k with
  | none => simp [ho] at h
  | some o => simp [ho] at h; exact ⟨o, rfl, h.symm⟩

theorem setObj_objs (H : Heap) (l : Nat) (o : Obj) (k : Nat) :
    (H.setObj l o).objs k = if k = l then some o else H.objs k := rfl

theorem setObj_live (H : Heap) (l : Nat) (o2 : Obj) (hl : ∃ o, H.objs l = some o) (v : Val) :
    (H.setObj l o2).LiveVal v ↔ H.LiveVal v := by
  cases v with
  | int n => simp [LiveVal]
  | ref k =>
    simp only [LiveVal, setObj_objs]
    by_cases hk : k = l
    · subst hk; simp; exact hl
    · simp [hk]

theorem alloc_live (H : Heap) (fs : List Val) (v : Val) (hv : H.LiveVal v) :
    (H.alloc fs).1.LiveVal v := by
  cases v with
  | int n => trivial
  | ref k =>
    simp only [LiveVal, alloc] at *
    by_cases hk : k = H.next
    · simp [hk]
    · simp [hk]; exact hv

theorem nat_le_sum_of_mem (xs : List Nat) (a : Nat) (h : a ∈ xs) : a ≤ xs.sum := by
  induction xs with
  | nil => simp at h
  | cons x xs ih =>
    simp only [List.sum_cons]
    rcases List.mem_cons.mp h with rfl | h
    · omega
    · have := ih h; omega

theorem nat_sum_zero (xs : List Nat) (h : ∀ x ∈ xs, x = 0) : xs.sum = 0 := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.sum_cons]
    rw [h x (List.mem_cons_self), ih (fun y hy => h y (List.mem_cons_of_mem _ hy))]

theorem cnt_le_refs (H : Heap) (m l : Nat) (hm : m < H.next) : H.cnt m l ≤ H.refs l := by
  unfold refs
  exact nat_le_sum_of_mem _ _ (List.mem_map.mpr ⟨m, List.mem_range.mpr hm, rfl⟩)

theorem refs_zero (H : Heap) (l : Nat) (h : ∀ m, m < H.next → H.cnt m l = 0) : H.refs l = 0 := by
  unfold refs
  apply nat_sum_zero
  intro x hx
  obtain ⟨m, hm, rfl⟩ := List.mem_map.mp hx
  exact h m (List.mem_range.mp hm)

end Orin.Heap
