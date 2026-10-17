import Orin.Weaken

/-!
# Preservation: arrays with a length and bounds-checked access

An array is a heap object whose slots are its elements; its *length* is the number of slots
(`Obj.fields.length`).  `arrayGet` / `arraySet` / `arrayNew` are `getField` / `setField` / `alloc`
with a run-time index (the scalar local `i`) and length; the bounds check is the slot lookup:
an index outside `0 ≤ n < length` is a `trap` (a defined safe failure, never `bad`).  The abstract
rules are the same rules plus "the index local is an initialised scalar" (`gk a i = .init`), so the
lemmas reduce to `op_getField`, `op_setField`, `op_alloc`.  `arrayLen` reads the length into a
scalar.
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s : St} {np : Nat}

theorem stepGet_pre {d o : Nat} {r : Bool} {a1 : List AS} (h : stepGet np a d o r = some a1) :
    d < a.length ∧ o < a.length ∧ np ≤ d ∧ (gk a o).isRef = true := by
  unfold stepGet at h
  split at h
  · rename_i hc; exact hc
  · simp at h

theorem op_arrayLen {d x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.arrayLen d x) = some a') : OpSafe ext a' (opArrayLen s d x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, ho, _, hrefo⟩ := hc
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hol : x < s.locals.length := hI.len ▸ ho
    obtain ⟨lo, hlo⟩ := (hI.cl x).ref hrefo
    obtain ⟨obj, hobj⟩ : ∃ obj, s.heap.objs lo = some obj := by
      have := hI.live hrefo
      rw [hlo] at this
      exact this
    have hop : opArrayLen s d x = .ok (s.setL d (.int (obj.fields.length : Int))) := by
      simp [opArrayLen, hdl, hol, hlo, hobj]
    refine ⟨(fun k hh => by rw [hop] at hh; cases hh), fun s' hs => ?_⟩
    rw [hop] at hs
    cases hs
    have h' := Option.some.inj h
    subst h'
    have hs' : (s.setL d (.int (obj.fields.length : Int))).locals = s.locals.set d _ := rfl
    have hgd := get_self s _ d (.int (obj.fields.length : Int)) hdl hs'
    obtain ⟨hwf, hlen, hcl⟩ := def_uncounted hI hd .init rfl (.int (obj.fields.length : Int))
    refine ⟨hlen, hwf, fun i' => ?_⟩
    by_cases hi' : i' = d
    · subst hi'
      exact ClAt.of_init (defK_self a _ _ hd) ⟨_, hgd⟩
    · exact hcl i' hi'
  · simp at h

theorem op_arrayGet {d x i : Nat} {r : Bool} (hI : Inv ext a s)
    (h : stepL np a (.arrayGet d x i r) = some a') : OpSafe ext a' (opArrayGet s d x i r) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hi, hinit⟩ := hc
    have hil : i < s.locals.length := hI.len ▸ hi
    obtain ⟨n, hn⟩ := (hI.cl i).ini hinit
    by_cases h0 : 0 ≤ n
    · have hop : opArrayGet s d x i r = opGetFieldE .trap s d x n.toNat r := by
        simp [opArrayGet, hil, hn, h0]
      rw [hop]
      exact op_getFieldE .trap oob_trap_ok hI (np := np) (i := n.toNat) (by simpa [stepL] using h)
    · obtain ⟨hd, ho, _, hrefo⟩ := stepGet_pre h
      have hdl : d < s.locals.length := hI.len ▸ hd
      have hol : x < s.locals.length := hI.len ▸ ho
      obtain ⟨lo, hlo⟩ := (hI.cl x).ref hrefo
      obtain ⟨obj, hobj⟩ : ∃ obj, s.heap.objs lo = some obj := by
        have := hI.live hrefo
        rw [hlo] at this
        exact this
      have hop : opArrayGet s d x i r = .trap := by
        simp [opArrayGet, hil, hn, h0, hdl, hol, hlo, hobj]
      refine ⟨(fun k hh => by rw [hop] at hh; cases hh), fun s' hs => ?_⟩
      rw [hop] at hs; cases hs
  · simp at h

theorem op_arraySet {x i v : Nat} (hI : Inv ext a s)
    (h : stepL np a (.arraySet x i v) = some a') : OpSafe ext a' (opArraySet s x i v) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hi, hinit⟩ := hc
    have hil : i < s.locals.length := hI.len ▸ hi
    obtain ⟨n, hn⟩ := (hI.cl i).ini hinit
    by_cases h0 : 0 ≤ n
    · have hop : opArraySet s x i v = opSetFieldE .trap s x n.toNat v := by
        simp [opArraySet, hil, hn, h0]
      rw [hop]
      exact op_setFieldE .trap oob_trap_ok hI (np := np) (i := n.toNat) (by simpa [stepL] using h)
    · simp only [stepSet] at h
      split at h
      · rename_i hc2
        obtain ⟨hx, _, hu⟩ := hc2
        obtain ⟨a1, h1, _⟩ := Option.map_eq_some_iff.mp h
        obtain ⟨hv, _⟩ := consume_spec h1
        have hxl : x < s.locals.length := hI.len ▸ hx
        have hvl : v < s.locals.length := hI.len ▸ hv
        obtain ⟨l, o, hl, ho, hrc⟩ := (hI.cl x).uniq hu
        have hop : opArraySet s x i v = .trap := by
          simp [opArraySet, hil, hn, h0, hxl, hvl, hl, ho, hrc]
        refine ⟨(fun k hh => by rw [hop] at hh; cases hh), fun s' hs => ?_⟩
        rw [hop] at hs; cases hs
      · simp at h
  · simp at h

theorem op_arrayNew {d nl : Nat} (hI : Inv ext a s)
    (h : stepL np a (.arrayNew d nl) = some a') : OpSafe ext a' (opArrayNew s d nl) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hi, hinit⟩ := hc
    have hil : nl < s.locals.length := hI.len ▸ hi
    obtain ⟨n, hn⟩ := (hI.cl nl).ini hinit
    by_cases h0 : 0 ≤ n
    · have hop : opArrayNew s d nl = opAllocN s d n.toNat := by
        simp [opArrayNew, hil, hn, h0]
      rw [hop]
      exact op_alloc hI (np := np) (n := n.toNat) (by simpa [stepL] using h)
    · simp only [stepAlloc] at h
      split at h
      · rename_i hc2
        have hdl : d < s.locals.length := hI.len ▸ hc2.1
        have hop : opArrayNew s d nl = .trap := by
          simp [opArrayNew, hil, hn, h0, hdl]
        refine ⟨(fun k hh => by rw [hop] at hh; cases hh), fun s' hs => ?_⟩
        rw [hop] at hs; cases hs
      · simp at h
  · simp at h

end Orin

namespace Orin

/-- The bounds check: an index at or beyond the length of a live array is a `trap`. -/
theorem arrayGet_oob {s : St} {d a i l : Nat} {n : Int} {ob : Obj} {r : Bool}
    (hi : i < s.locals.length) (hd : d < s.locals.length) (ha : a < s.locals.length)
    (hn : s.get i = .int n) (hl : s.get a = .ref l) (ho : s.heap.objs l = some ob)
    (hb : n < 0 ∨ ob.fields.length ≤ n.toNat) : opArrayGet s d a i r = .trap := by
  by_cases h0 : 0 ≤ n
  · have hb' : ob.fields.length ≤ n.toNat := by omega
    have hnone : ob.fields[n.toNat]? = none := List.getElem?_eq_none hb'
    simp [opArrayGet, hi, hn, h0, opGetFieldE, hd, ha, hl, ho, hnone]
  · simp [opArrayGet, hi, hn, h0, hd, ha, hl, ho]

/-- An in-range index reads the element (reference element into a reference destination). -/
theorem arrayGet_inb {s : St} {d a i l m : Nat} {n : Int} {ob : Obj}
    (hi : i < s.locals.length) (hd : d < s.locals.length) (ha : a < s.locals.length)
    (hn : s.get i = .int n) (h0 : 0 ≤ n) (hl : s.get a = .ref l)
    (ho : s.heap.objs l = some ob) (hw : ob.fields[n.toNat]? = some (.ref m)) :
    opArrayGet s d a i true = .ok (s.setL d (.ref m)) := by
  simp [opArrayGet, hi, hn, h0, opGetFieldE, hd, ha, hl, ho, hw]

end Orin
