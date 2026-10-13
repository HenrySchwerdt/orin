import Orin.Proj

/-!
# Basic consequences of the simulation relation

Liveness of every readable reference (`Inv.live`), the exclusion property of `Unique` locals
(`unique_excl`: nothing else, not even a borrowed alias, holds the object), and the stability of
`Desc` chains under heap changes that keep the slots of chain objects.
-/

namespace Orin
open Heap

theorem lt_of_gk_ne_dead {a : List AS} {i : Nat} (h : gk a i ≠ .dead) : i < a.length := by
  by_cases hc : i < a.length
  · exact hc
  · exfalso
    apply h
    simp [gk, List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega : a.length ≤ i)]

theorem desc_live {H : Heap} {p : Nat} {w : Val}
    (hf : ∀ m o, H.objs m = some o → ∀ v ∈ o.fields, H.LiveVal v)
    (hp : H.LiveVal (.ref p)) (hd : Desc H p w) : H.LiveVal w := by
  cases hd with
  | self => exact hp
  | field ho hw _ => exact hf _ _ ho _ hw

theorem desc_cases {H : Heap} {p : Nat} {w : Val} (hd : Desc H p w) :
    w = .ref p ∨ ∃ m o, H.objs m = some o ∧ w ∈ o.fields ∧ Desc H p (.ref m) := by
  cases hd with
  | self => exact Or.inl rfl
  | field ho hw hd => exact Or.inr ⟨_, _, ho, hw, hd⟩

theorem desc_mono {H H' : Heap} {p : Nat} {w : Val}
    (hs : ∀ k o, Desc H p (.ref k) → H.objs k = some o →
      ∃ o', H'.objs k = some o' ∧ o'.fields = o.fields)
    (hd : Desc H p w) : Desc H' p w := by
  induction hd with
  | self => exact Desc.self
  | field ho hw hd ih =>
    obtain ⟨o', ho', hf⟩ := hs _ _ hd ho
    exact Desc.field ho' (by rw [hf]; exact hw) ih

theorem desc_trans {H : Heap} {p0 p : Nat} {w : Val} (h1 : Desc H p w) (h0 : Desc H p0 (.ref p)) :
    Desc H p0 w := by
  induction h1 with
  | self => exact h0
  | field ho hw _ ih => exact Desc.field ho hw ih

variable {ext : List Val} {a : List AS} {s : St}

theorem Inv.live_root (hI : Inv ext a s) {i : Nat} (hr : (gk a i).isRoot = true) :
    s.heap.LiveVal (s.get i) := by
  have hne : gk a i ≠ .dead := by intro h; rw [h] at hr; simp [AS.isRoot] at hr
  have hi : i < s.locals.length := hI.len ▸ lt_of_gk_ne_dead hne
  have hlocs := hI.wf.locs
  cases hk : gk a i with
  | owned => exact hlocs _ (mem_Pst_of_counted hi (by simp [hk, AS.counted]))
  | unique => exact hlocs _ (mem_Pst_of_counted hi (by simp [hk, AS.counted]))
  | param =>
    obtain ⟨p, hp, hd⟩ := (hI.cl i).prm hk
    exact desc_live (fun m o ho v hv => hI.wf.flds m o ho v hv) (hlocs _ (mem_Pst_of_ext hp)) hd
  | _ => rw [hk] at hr; simp [AS.isRoot] at hr

theorem Inv.live (hI : Inv ext a s) {i : Nat} (hr : (gk a i).isRef = true) :
    s.heap.LiveVal (s.get i) := by
  cases hk : gk a i with
  | borrowed r =>
    obtain ⟨hroot, p, hp, hd, _⟩ := (hI.cl i).bor r hk
    have h1 := hI.live_root hroot
    rw [hp] at h1
    exact desc_live (fun m o ho v hv => hI.wf.flds m o ho v hv) h1 hd
  | owned => exact hI.live_root (by simp [hk, AS.isRoot])
  | unique => exact hI.live_root (by simp [hk, AS.isRoot])
  | param => exact hI.live_root (by simp [hk, AS.isRoot])
  | _ => rw [hk] at hr; simp [AS.isRef] at hr

/-- A root local (counted, or a parameter anchored by the caller) holding `ref p`:
the value is `p0` itself or lies below `p0`, for some reference `p0` in the projected locals. -/
theorem Inv.root_anchor (hI : Inv ext a s) {r p : Nat} (hr : (gk a r).isRoot = true)
    (hp : s.get r = .ref p) :
    ∃ p0, Val.ref p0 ∈ (Pst ext a s).locals ∧ Desc s.heap p0 (.ref p) := by
  have hne : gk a r ≠ .dead := by intro h; rw [h] at hr; simp [AS.isRoot] at hr
  have hi : r < s.locals.length := hI.len ▸ lt_of_gk_ne_dead hne
  cases hk : gk a r with
  | owned =>
    refine ⟨p, ?_, Desc.self⟩
    have := mem_Pst_of_counted (ext := ext) hi (by simp [hk, AS.counted] : (gk a r).counted = true)
    rwa [hp] at this
  | unique =>
    refine ⟨p, ?_, Desc.self⟩
    have := mem_Pst_of_counted (ext := ext) hi (by simp [hk, AS.counted] : (gk a r).counted = true)
    rwa [hp] at this
  | param =>
    obtain ⟨p0, hp0, hd⟩ := (hI.cl r).prm hk
    exact ⟨p0, mem_Pst_of_ext hp0, by rw [hp] at hd; exact hd⟩
  | _ => rw [hk] at hr; simp [AS.isRoot] at hr

/-- Everything a `Unique` local excludes. -/
theorem unique_excl (hI : Inv ext a s) {i l : Nat} {o : Obj} (hu : gk a i = .unique)
    (hl : s.get i = .ref l) (ho : s.heap.objs l = some o) (hrc : o.rc = 1) :
    (∀ j, j ≠ i → (gk a j).isRoot = true → s.get j ≠ .ref l) ∧
    (∀ j, (gk a j).isRef = true → j ≠ i → s.get j ≠ .ref l) ∧
    (∀ v ∈ s.pending, v ≠ .ref l) ∧
    (∀ m o', s.heap.objs m = some o' → ∀ v ∈ o'.fields, v ≠ .ref l) ∧
    (∀ v ∈ ext, v ≠ .ref l) := by
  have hi : i < s.locals.length := hI.len ▸ lt_of_gk_ne_dead (by rw [hu]; simp)
  have huf := unique_facts (s := Pst ext a s) hI.wf (x := i) (l := l) (o := o)
    (by rw [Pst_locals_length]; omega) (by rw [Pst_get_counted hi (by simp [hu, AS.counted])]; exact hl)
    ho hrc
  obtain ⟨h1, h2, h3⟩ := huf
  have hext : ∀ v ∈ ext, v ≠ .ref l := by
    intro v hv hvl
    obtain ⟨z2, hz2, hz2e⟩ := List.getElem_of_mem hv
    have hpos : (Pst ext a s).locals[s.locals.length + z2]? = some v := by
      show (projL a s.locals ++ ext)[s.locals.length + z2]? = _
      rw [List.getElem?_append_right (by rw [projL_length]; omega), projL_length]
      simp [hz2, hz2e]
    exact h1 (s.locals.length + z2) v (by omega) hpos hvl
  have hroot : ∀ j, j ≠ i → (gk a j).isRoot = true → s.get j ≠ .ref l := by
    intro j hj hr hjl
    have hne : gk a j ≠ .dead := by intro h; rw [h] at hr; simp [AS.isRoot] at hr
    have hjl' : j < s.locals.length := hI.len ▸ lt_of_gk_ne_dead hne
    by_cases hc : (gk a j).counted = true
    · exact h1 j (s.get j) hj (by rw [← Pst_get_counted hjl' hc]; exact St.get_spec _ _ (by rw [Pst_locals_length]; omega)) hjl
    · -- parameter: anchored in the caller's references
      have hp : gk a j = .param := by
        cases hk : gk a j <;> simp_all [AS.isRoot, AS.counted]
      obtain ⟨p0, hp0, hd⟩ := (hI.cl j).prm hp
      rcases desc_cases hd with he | ⟨m, o', ho', hw, _⟩
      · rw [hjl] at he
        have : Val.ref p0 = Val.ref l := he.symm
        exact hext _ hp0 this
      · exact h3 m o' ho' _ hw hjl
  refine ⟨hroot, ?_, h2, h3, hext⟩
  intro j hr hj hjl
  cases hk : gk a j with
  | borrowed r =>
    obtain ⟨hrt, p, hp, hd, hcl⟩ := (hI.cl j).bor r hk
    rcases desc_cases hd with he | ⟨m, o', ho', hw, _⟩
    · rw [hjl] at he
      have hpl : p = l := by injection he with h; exact h.symm
      subst hpl
      have hri : r ≠ i := by
        intro hri; subst hri
        exact hcl hu (by rw [hjl])
      exact hroot r hri hrt hp
    · exact h3 m o' ho' _ hw hjl
  | owned => exact hroot j hj (by simp [hk, AS.isRoot]) hjl
  | unique => exact hroot j hj (by simp [hk, AS.isRoot]) hjl
  | param => exact hroot j hj (by simp [hk, AS.isRoot]) hjl
  | _ => rw [hk] at hr; simp [AS.isRef] at hr

/-- Every object `k` on a `Desc` chain below a reference `p` of the projected locals is owned by
something other than the worklist: by a projected local, or by a heap slot. -/
theorem desc_owned_mem (hI : Inv ext a s) {p k : Nat} (hmem : Val.ref p ∈ (Pst ext a s).locals)
    (hd : Desc s.heap p (.ref k)) :
    1 ≤ (Pst ext a s).locals.count (.ref k) + s.heap.refs k := by
  rcases desc_cases hd with he | ⟨m, o, ho, hw, _⟩
  · have hk : k = p := by injection he
    subst hk
    have := List.count_pos_iff.mpr hmem
    omega
  · have h1 := Heap.cnt_le_refs s.heap m k (hI.wf.lt_next ho)
    have h2 : s.heap.cnt m k ≠ 0 := by
      unfold Heap.cnt; rw [ho]; simp only
      exact Nat.pos_iff_ne_zero.mp (List.count_pos_iff.mpr hw)
    omega

theorem desc_owned (hI : Inv ext a s) {r p k : Nat} (hr : (gk a r).isRoot = true)
    (hp : s.get r = .ref p) (hd : Desc s.heap p (.ref k)) :
    1 ≤ (Pst ext a s).locals.count (.ref k) + s.heap.refs k := by
  obtain ⟨p0, hmem, hd0⟩ := hI.root_anchor hr hp
  exact desc_owned_mem hI hmem (desc_trans hd hd0)

end Orin
