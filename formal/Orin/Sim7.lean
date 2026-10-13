import Orin.Sim6

/-!
# Preservation under the release worklist (`drain`)
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s s' : St}

/-- Claims after a step that leaves the locals alone. -/
theorem cl_locals_same
    (hcl : ∀ i, ClAt ext a s i) (hloc : s'.locals = s.locals)
    (hU : ∀ i l o, ¬ False → gk a i = .unique → gk a i = .unique → s.get i = .ref l →
      s.heap.objs l = some o → o.rc = 1 → ∃ o', s'.heap.objs l = some o' ∧ o'.rc = 1)
    (hD : ∀ i r p, ¬ False → ¬ False → gk a i = .borrowed r → gk a i = .borrowed r →
      s.get r = .ref p → Desc s.heap p (s.get i) → Desc s'.heap p (s.get i))
    (hDp : ∀ i p, ¬ False → gk a i = .param → gk a i = .param → Val.ref p ∈ ext →
      Desc s.heap p (s.get i) → Desc s'.heap p (s.get i)) :
    ∀ i, ClAt ext a s' i := fun i =>
  cl_frame (T := fun _ => False) (a' := a) hcl (fun j _ => by simp [St.get, hloc])
    (fun j _ => Or.inl rfl) (fun j y _ hy => hy.elim) hU hD hDp i id

theorem drain_inv (hI : Inv ext a s) (hp : s.pending ≠ []) :
    (∀ k, drain s ≠ .bad k) ∧ ∀ s', drain s = .ok s' → Inv ext a s' := by
  obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, s.pending = hd :: rest := by
    cases h : s.pending with
    | nil => exact absurd h hp
    | cons hd rest => exact ⟨hd, rest, rfl⟩
  have hpP : (Pst ext a s).pending = hd :: rest := hpe
  cases hd with
  | int n =>
    have hdr : drain s = .ok { s with pending := rest } := by simp [drain, hpe]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hdr] at hh; cases hh
    rw [hdr] at hs
    cases hs
    refine ⟨hI.len, ?_, cl_locals_same hI.cl rfl (hU_same rfl) (hD_same rfl) (hDp_same rfl)⟩
    exact wf_drain_int (Pst ext a s) hI.wf n rest hpP
  | ref l =>
    obtain ⟨o, ho⟩ : ∃ o, s.heap.objs l = some o := by
      have := hI.wf.pend (.ref l) (by rw [hpP]; exact List.mem_cons_self)
      exact this
    have hpos : 0 < o.rc := hI.wf.rcpos l o ho
    have hmem : Val.ref l ∈ s.pending := by rw [hpe]; exact List.mem_cons_self
    -- an object with a unique owner is not the popped one
    have hU0 : ∀ i l' o', gk a i = .unique → s.get i = .ref l' → s.heap.objs l' = some o' →
        o'.rc = 1 → l' ≠ l := by
      intro i l' o' hu hl' ho' hrc' e
      subst e
      exact (unique_excl hI hu hl' ho' hrc').2.2.1 _ hmem rfl
    by_cases hrc : o.rc = 1
    · have hdr : drain s = .ok { s with heap := s.heap.del l, pending := o.fields ++ rest } := by
        simp [drain, hpe, ho, hrc]
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hdr] at hh; cases hh
      rw [hdr] at hs
      cases hs
      refine ⟨hI.len, ?_, cl_locals_same hI.cl rfl ?_ ?_ ?_⟩
      · exact wf_drain_free (Pst ext a s) hI.wf l rest o hpP ho hrc
      · intro i l' o' _ hu _ hl' ho' hrc'
        have hne := hU0 i l' o' hu hl' ho' hrc'
        exact ⟨o', by show (s.heap.del l).objs l' = _; rw [del_objs, if_neg hne]; exact ho', hrc'⟩
      · intro i r p _ _ hb _ hp hd
        obtain ⟨hroot, _⟩ := (hI.cl i).bor r hb
        refine desc_mono (fun k o' hk ho' => ?_) hd
        have hkl : k ≠ l := by
          intro e
          subst e
          have h1 := desc_owned hI hroot hp hk
          have h2 := hI.wf.sound k o ho
          have h3 : 1 ≤ s.pending.count (.ref k) := List.count_pos_iff.mpr hmem
          unfold St.owners at h2
          change (Pst ext a s).locals.count (.ref k) + s.pending.count (.ref k)
            + s.heap.refs k ≤ o.rc at h2
          omega
        exact ⟨o', by show (s.heap.del l).objs k = _; rw [del_objs, if_neg hkl]; exact ho', rfl⟩
      · intro i p _ _ _ hpe' hd
        refine desc_mono (fun k o' hk ho' => ?_) hd
        have hkl : k ≠ l := by
          intro e
          subst e
          have h1 := desc_owned_mem hI (mem_Pst_of_ext hpe') hk
          have h2 := hI.wf.sound k o ho
          have h3 : 1 ≤ s.pending.count (.ref k) := List.count_pos_iff.mpr hmem
          unfold St.owners at h2
          change (Pst ext a s).locals.count (.ref k) + s.pending.count (.ref k)
            + s.heap.refs k ≤ o.rc at h2
          omega
        exact ⟨o', by show (s.heap.del l).objs k = _; rw [del_objs, if_neg hkl]; exact ho', rfl⟩
    · have hdr : drain s = .ok { s with heap := s.heap.decRc l, pending := rest } := by
        simp [drain, hpe, ho, hrc]
        omega
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hdr] at hh; cases hh
      rw [hdr] at hs
      cases hs
      refine ⟨hI.len, ?_, cl_locals_same hI.cl rfl ?_ ?_ ?_⟩
      · exact wf_drain_dec (Pst ext a s) hI.wf l rest o hpP ho (by omega) hrc
      · intro i l' o' _ hu _ hl' ho' hrc'
        have hne := hU0 i l' o' hu hl' ho' hrc'
        exact ⟨o', by show (s.heap.decRc l).objs l' = _; rw [decRc_objs _ _ _ ho, if_neg hne]; exact ho', hrc'⟩
      · intro i r p _ _ hb _ hp hd
        refine desc_mono (fun k o' hk ho' => ?_) hd
        by_cases hkl : k = l
        · subst hkl
          have hf : o'.fields = o.fields := by
            rw [ho] at ho'; rw [Option.some.inj ho']
          exact ⟨{ o with rc := o.rc - 1 }, by
            show (s.heap.decRc k).objs k = _; rw [decRc_objs _ _ _ ho, if_pos rfl], hf.symm⟩
        · exact ⟨o', by show (s.heap.decRc l).objs k = _; rw [decRc_objs _ _ _ ho, if_neg hkl]; exact ho', rfl⟩
      · intro i p _ _ _ hpe' hd
        refine desc_mono (fun k o' hk ho' => ?_) hd
        by_cases hkl : k = l
        · subst hkl
          have hf : o'.fields = o.fields := by
            rw [ho] at ho'; rw [Option.some.inj ho']
          exact ⟨{ o with rc := o.rc - 1 }, by
            show (s.heap.decRc k).objs k = _; rw [decRc_objs _ _ _ ho, if_pos rfl], hf.symm⟩
        · exact ⟨o', by show (s.heap.decRc l).objs k = _; rw [decRc_objs _ _ _ ho, if_neg hkl]; exact ho', rfl⟩

end Orin
