import Orin.Sim1

/-!
# Frame lemma and the simple transfer functions (`const`, `borrow`, `dup`, `move`, `release`)
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s s' : St}

/-! ### access lemmas -/

theorem get_setL (s : St) (d : Nat) (v : Val) (i : Nat) (hd : d < s.locals.length) :
    (s.setL d v).get i = if i = d then v else s.get i := by
  by_cases h : i = d
  · subst h; simp [St.get, St.setL, hd]
  · simp [St.get, St.setL, List.getD_eq_getElem?_getD, List.getElem?_set, h, Ne.symm h]

theorem get_locals_set (s : St) (d : Nat) (v : Val) (i : Nat) (hd : d < s.locals.length) :
    ({ s with locals := s.locals.set d v } : St).get i = if i = d then v else s.get i :=
  get_setL s d v i hd

theorem clr_ref (s : St) (y i l : Nat) (hy : y < s.locals.length) (h : s.get y = .ref l) :
    (s.clr y).get i = if i = y then .int 0 else s.get i := by
  unfold St.clr
  rw [h]
  simp only
  exact get_setL _ _ _ _ hy

theorem clr_int (s : St) (y : Nat) (n : Int) (h : s.get y = .int n) : s.clr y = s := by
  unfold St.clr
  rw [h]

theorem projExt_getElem? (ext : List Val) (a : List AS) (ls : List Val) (j : Nat) :
    (projL a ls ++ ext)[j]? =
      if j < ls.length then some (pv (gk a j) (ls.getD j (.int 0))) else ext[j - ls.length]? := by
  by_cases hj : j < ls.length
  · simp only [hj, if_true]
    rw [List.getElem?_append_left (by rw [projL_length]; exact hj), projL_getElem?]
    simp [hj]
  · simp only [hj, if_false]
    rw [List.getElem?_append_right (by rw [projL_length]; omega), projL_length]

theorem projSt_getElem? (ext : List Val) (a : List AS) (s : St) (j : Nat) :
    (projL a s.locals ++ ext)[j]? =
      if j < s.locals.length then some (pv (gk a j) (s.get j)) else ext[j - s.locals.length]? :=
  projExt_getElem? ext a s.locals j

theorem Pst_getElem? (ext : List Val) (a : List AS) (s : St) (j : Nat) :
    (Pst ext a s).locals[j]? =
      if j < s.locals.length then some (pv (gk a j) (s.get j)) else ext[j - s.locals.length]? := by
  unfold Pst
  rw [projExt_getElem?]
  simp [St.get]

/-! ### the frame lemma -/

/-- Claims survive for every local outside the "touched" set `T`, given that the heap keeps
count-1 objects held by untouched `Unique` locals and the slots of the `Desc` chains of untouched
`Borrowed` locals.  Kinds of untouched locals may only be invalidated (`Borrowed x`, `x ∈ T`,
becomes `Dead`) or demoted (`Unique` becomes `Owned`). -/
theorem cl_frame (T : Nat → Prop)
    (hcl : ∀ i, ClAt ext a s i)
    (hloc : ∀ i, ¬T i → s'.get i = s.get i)
    (hk0 : ∀ i, ¬T i → gk a' i = gk a i ∨ (∃ x, T x ∧ gk a i = .borrowed x ∧ gk a' i = .dead) ∨
      (gk a i = .unique ∧ gk a' i = .owned))
    (hk1 : ∀ i x, ¬T i → T x → gk a i = .borrowed x → gk a' i = .dead)
    (hU : ∀ i l o, ¬T i → gk a i = .unique → gk a' i = .unique → s.get i = .ref l →
      s.heap.objs l = some o → o.rc = 1 → ∃ o', s'.heap.objs l = some o' ∧ o'.rc = 1)
    (hD : ∀ i r p, ¬T i → ¬T r → gk a i = .borrowed r → gk a' i = .borrowed r →
      s.get r = .ref p → Desc s.heap p (s.get i) → Desc s'.heap p (s.get i)) :
    ∀ i, ¬T i → ClAt ext a' s' i := by
  intro i hi
  have hkk := hk0 i hi
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro h
    rcases hkk with e | ⟨x, _, _, e⟩ | ⟨_, e⟩
    · rw [e] at h
      obtain ⟨n, hn⟩ := (hcl i).ini h
      exact ⟨n, by rw [hloc i hi]; exact hn⟩
    · rw [e] at h; cases h
    · rw [e] at h; cases h
  · intro h
    rcases hkk with e | ⟨x, _, _, e⟩ | ⟨_, e⟩
    · have h2 := h
      rw [e] at h
      obtain ⟨l, o, hl, ho, hrc⟩ := (hcl i).uniq h
      obtain ⟨o', ho', hrc'⟩ := hU i l o hi h h2 hl ho hrc
      exact ⟨l, o', by rw [hloc i hi]; exact hl, ho', hrc'⟩
    · rw [e] at h; cases h
    · rw [e] at h; cases h
  · intro h
    rcases hkk with e | ⟨x, _, _, e⟩ | ⟨_, e⟩
    · rw [e] at h
      have := (hcl i).prm h
      rw [hloc i hi]; exact this
    · rw [e] at h; cases h
    · rw [e] at h; cases h
  · intro r h
    rcases hkk with e | ⟨x, _, _, e⟩ | ⟨_, e⟩
    · have h0 := h
      rw [e] at h
      have hr : ¬T r := by
        intro hT
        have := hk1 i r hi hT h
        rw [h0] at this; cases this
      obtain ⟨hroot, p, hp, hd, hcl2⟩ := (hcl i).bor r h
      have hr' := hk0 r hr
      have hgr : (gk a' r).isRoot = true ∧ (gk a' r = .unique → gk a r = .unique) := by
        rcases hr' with e2 | ⟨x, _, e2, e3⟩ | ⟨e2, e3⟩
        · rw [e2]; exact ⟨hroot, id⟩
        · rw [e2] at hroot; simp [AS.isRoot] at hroot
        · rw [e3]; exact ⟨by simp [AS.isRoot], fun h => by cases h⟩
      refine ⟨hgr.1, p, by rw [hloc r hr]; exact hp, ?_, ?_⟩
      · rw [hloc i hi]; exact hD i r p hi hr h h0 hp hd
      · intro hu; rw [hloc i hi]; exact hcl2 (hgr.2 hu)
    · rw [e] at h; cases h
    · rw [e] at h; cases h
  · intro h
    rcases hkk with e | ⟨x, _, _, e⟩ | ⟨e1, e⟩
    · rw [e] at h
      obtain ⟨l, hl⟩ := (hcl i).ref h
      exact ⟨l, by rw [hloc i hi]; exact hl⟩
    · rw [e] at h; simp [AS.isRef] at h
    · obtain ⟨l, hl⟩ := (hcl i).ref (by rw [e1]; rfl)
      exact ⟨l, by rw [hloc i hi]; exact hl⟩

/-- Heap unchanged. -/
theorem hU_same {T : Nat → Prop} (hH : s'.heap = s.heap) :
    ∀ i l o, ¬T i → gk a i = .unique → gk a' i = .unique → s.get i = .ref l →
      s.heap.objs l = some o → o.rc = 1 → ∃ o', s'.heap.objs l = some o' ∧ o'.rc = 1 := by
  intro i l o _ _ _ _ ho hrc
  exact ⟨o, by rw [hH]; exact ho, hrc⟩

theorem hD_same {T : Nat → Prop} (hH : s'.heap = s.heap) :
    ∀ i r p, ¬T i → ¬T r → gk a i = .borrowed r → gk a' i = .borrowed r → s.get r = .ref p →
      Desc s.heap p (s.get i) → Desc s'.heap p (s.get i) := by
  intro i r p _ _ _ _ _ hd
  rw [hH]; exact hd

/-- Heap changes that keep every object's slots (e.g. reference-count updates). -/
theorem hD_fields {T : Nat → Prop}
    (hH : ∀ k o, s.heap.objs k = some o → ∃ o', s'.heap.objs k = some o' ∧ o'.fields = o.fields) :
    ∀ i r p, ¬T i → ¬T r → gk a i = .borrowed r → gk a' i = .borrowed r → s.get r = .ref p →
      Desc s.heap p (s.get i) → Desc s'.heap p (s.get i) := by
  intro i r p _ _ _ _ _ hd
  exact desc_mono (fun k o _ ho => hH k o ho) hd

end Orin
