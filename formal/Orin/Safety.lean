import Orin.WF

/-!
# Preservation and memory-safety (no dead access) for every instruction
-/

namespace Orin
open Heap

theorem live_of_liveb {H : Heap} {v : Val} (h : H.liveb v = false) (hv : H.LiveVal v) : False := by
  have := (liveb_iff H v).mpr hv
  rw [h] at this; exact Bool.false_ne_true this

theorem locs_ref {s : St} (hwf : WF s) {x l : Nat} (hx : x < s.locals.length)
    (hxl : s.get x = .ref l) : ∃ o, s.heap.objs l = some o := by
  have h := hwf.locs _ (s.get_mem x hx)
  rw [hxl] at h
  exact h

section ops
variable {s s' : St}

theorem opConst_wf (hwf : WF s) (h : opConst s x n = .ok s') : WF s' := by
  unfold opConst at h
  split at h
  · rename_i hx
    simp at h; subst h
    exact wf_const s hwf x hx n
  · simp at h

theorem opCopy_wf (hwf : WF s) (h : opCopy s y x = .ok s') : WF s' := by
  unfold opCopy at h
  split at h
  · rename_i hxy
    try dsimp only at h
    split at h
    · rename_i hl
      simp at h; subst h
      exact wf_dupInto s hwf y hxy.2 _ ((liveb_iff _ _).mp hl)
    · simp at h
  · simp at h

theorem opCopy_not_dead (hwf : WF s) : opCopy s y x ≠ .bad .dead := by
  intro h
  unfold opCopy at h
  split at h
  · rename_i hxy
    try dsimp only at h
    split at h
    · simp at h
    · rename_i hl
      simp at hl
      exact live_of_liveb (by simpa using hl) (hwf.locs _ (s.get_mem x hxy.1))
  · simp at h

theorem opRetain_wf (hwf : WF s) (h : opRetain s x = .ok s') : WF s' := by
  unfold opRetain at h
  split at h
  · dsimp only at h
    split at h
    · simp at h; subst h; exact wf_retain s hwf _
    · simp at h
  · simp at h

theorem opRetain_not_dead (hwf : WF s) : opRetain s x ≠ .bad .dead := by
  intro h
  unfold opRetain at h
  split at h
  · rename_i hx
    try dsimp only at h
    split at h
    · simp at h
    · rename_i hl
      exact live_of_liveb (by simpa using hl) (hwf.locs _ (s.get_mem x hx))
  · simp at h

theorem opRelease_wf (hwf : WF s) (h : opRelease s x = .ok s') : WF s' := by
  unfold opRelease at h
  split at h
  · rename_i hx
    simp at h; subst h; exact wf_release s hwf x hx
  · simp at h

theorem opAlloc_wf (hwf : WF s) (h : opAlloc s x ys = .ok s') : WF s' := by
  unfold opAlloc at h
  split at h
  · rename_i hxy
    try dsimp only at h
    split at h
    · rename_i hl
      simp at h; subst h
      apply wf_alloc s hwf x hxy.1
      intro v hv
      obtain ⟨y, hy, rfl⟩ := List.mem_map.mp hv
      exact hwf.locs _ (s.get_mem y (hxy.2 y hy))
    · simp at h
  · simp at h

theorem opAlloc_not_dead (hwf : WF s) : opAlloc s x ys ≠ .bad .dead := by
  intro h
  unfold opAlloc at h
  split at h
  · rename_i hxy
    try dsimp only at h
    split at h
    · simp at h
    · rename_i hl
      apply hl
      simp only [List.all_eq_true, List.mem_map]
      rintro v ⟨y, hy, rfl⟩
      exact (liveb_iff _ _).mpr (hwf.locs _ (s.get_mem y (hxy.2 y hy)))
  · simp at h


theorem opLoad_wf (hwf : WF s) (h : opLoad s y x i = .ok s') : WF s' := by
  unfold opLoad at h
  split at h
  · rename_i hxy
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · simp at h
      · rename_i o ho
        split at h
        · simp at h
        · rename_i v hv
          dsimp only at h
          split at h
          · rename_i hl
            simp at h; subst h
            exact wf_dupInto s hwf y hxy.2 v
              (hwf.flds l o ho v (List.mem_of_getElem? hv))
          · simp at h
  · simp at h

theorem opLoad_not_dead (hwf : WF s) : opLoad s y x i ≠ .bad .dead := by
  intro h
  unfold opLoad at h
  split at h
  · rename_i hxy
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · rename_i hn
        obtain ⟨o, ho⟩ := locs_ref hwf hxy.1 hxl
        simp [hn] at ho
      · rename_i o ho
        split at h
        · simp at h
        · rename_i v hv
          dsimp only at h
          split at h
          · simp at h
          · rename_i hl
            exact live_of_liveb (by simpa using hl) (hwf.flds l o ho v (List.mem_of_getElem? hv))
  · simp at h

theorem opStore_wf (hwf : WF s) (h : opStore s x i y = .ok s') : WF s' := by
  unfold opStore at h
  split at h
  · rename_i hxy
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · simp at h
      · rename_i o ho
        split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i old hold
            dsimp only at h
            split at h
            · rename_i hl
              simp at h; subst h
              exact wf_store s hwf l o ho i old hold _ ((liveb_iff _ _).mp hl)
            · simp at h
  · simp at h

theorem opStore_not_dead (hwf : WF s) : opStore s x i y ≠ .bad .dead := by
  intro h
  unfold opStore at h
  split at h
  · rename_i hxy
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · rename_i hn
        obtain ⟨o, ho⟩ := locs_ref hwf hxy.1 hxl
        simp [hn] at ho
      · rename_i o ho
        split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i old hold
            dsimp only at h
            split at h
            · simp at h
            · rename_i hl
              exact live_of_liveb (by simpa using hl) (hwf.locs _ (s.get_mem y hxy.2))
  · simp at h

theorem opMakeUnique_wf (hwf : WF s) (h : opMakeUnique s x = .ok s') : WF s' := by
  unfold opMakeUnique at h
  split at h
  · rename_i hx
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · simp at h
      · rename_i o ho
        split at h
        · simp at h; subst h; exact hwf
        · rename_i hrc
          split at h
          · simp at h; subst h
            exact wf_makeUnique s hwf x hx l o hxl ho hrc
          · simp at h
  · simp at h

theorem opMakeUnique_not_dead (hwf : WF s) : opMakeUnique s x ≠ .bad .dead := by
  intro h
  unfold opMakeUnique at h
  split at h
  · rename_i hx
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · rename_i hn
        obtain ⟨o, ho⟩ := locs_ref hwf hx hxl
        simp [hn] at ho
      · rename_i o ho
        split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i hl
            apply hl
            simp only [List.all_eq_true]
            intro v hv
            exact (liveb_iff _ _).mpr (hwf.flds l o ho v hv)
  · simp at h

theorem drain_not_dead (hwf : WF s) : drain s ≠ .bad .dead := by
  intro h
  unfold drain at h
  split at h
  · simp at h
  · simp at h
  · rename_i l rest hp
    split at h
    · rename_i hn
      obtain ⟨o, ho⟩ := hwf.pend _ (by rw [hp]; exact List.mem_cons_self)
      simp [hn] at ho
    · rename_i o ho
      split at h
      · rename_i hr0
        have := hwf.rcpos l o ho
        omega
      · split at h <;> simp at h

end ops
end Orin
