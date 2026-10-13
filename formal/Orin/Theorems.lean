import Orin.Safety

namespace Orin

theorem lift_ok {rest : List Instr} {r : Res St} {c' : Cfg} (h : Res.lift rest r = .ok c') :
    ∃ s', r = .ok s' ∧ c' = ⟨rest, s'⟩ := by
  cases r <;> simp [Res.lift] at h
  rename_i s'
  exact ⟨s', rfl, h.symm⟩

theorem lift_bad {rest : List Instr} {r : Res St} {k : BadKind} (h : Res.lift rest r = .bad k) :
    r = .bad k := by
  cases r <;> simp [Res.lift] at h ⊢; exact h

theorem exec_wf {s : St} (hwf : WF s) (h : exec i rest s = .ok c') : WF c'.st := by
  unfold exec at h
  cases i with
  | const x n =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opConst_wf hwf h1
  | copy y x =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opCopy_wf hwf h1
  | load y x j =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opLoad_wf hwf h1
  | store x j y =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opStore_wf hwf h1
  | alloc x ys =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opAlloc_wf hwf h1
  | makeUnique x =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opMakeUnique_wf hwf h1
  | retain x =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opRetain_wf hwf h1
  | release x =>
    obtain ⟨s', h1, rfl⟩ := lift_ok h; exact opRelease_wf hwf h1
  | ite c t e =>
    simp only at h
    split at h
    · split at h <;> simp at h <;> (subst h; exact hwf)
    · simp at h

theorem step_wf {c c' : Cfg} (hwf : WF c.st) (h : step c = some (.ok c')) : WF c'.st := by
  unfold step at h
  split at h
  · simp at h
    obtain ⟨s', h1, rfl⟩ := lift_ok h
    exact wf_drain _ _ hwf h1
  · split at h
    · simp at h
    · simp at h; exact exec_wf hwf h

/-- Every `ok` step preserves the ownership-accounting invariant, so it holds along every run. -/
theorem reach_wf {c d : Cfg} (hwf : WF c.st) (hr : Reach c d) : WF d.st := by
  induction hr with
  | refl => exact hwf
  | step c c' d hs _ ih => exact ih (step_wf hwf hs)

theorem exec_not_dead {s : St} (hwf : WF s) : exec i rest s ≠ .bad .dead := by
  intro h
  unfold exec at h
  cases i with
  | const x n =>
    have := lift_bad h
    unfold opConst at this; split at this <;> simp at this
  | copy y x => exact opCopy_not_dead hwf (lift_bad h)
  | load y x j => exact opLoad_not_dead hwf (lift_bad h)
  | store x j y => exact opStore_not_dead hwf (lift_bad h)
  | alloc x ys => exact opAlloc_not_dead hwf (lift_bad h)
  | makeUnique x => exact opMakeUnique_not_dead hwf (lift_bad h)
  | retain x => exact opRetain_not_dead hwf (lift_bad h)
  | release x =>
    have := lift_bad h
    unfold opRelease at this; split at this <;> simp at this
  | ite c t e =>
    simp only at h
    split at h
    · split at h <;> simp at h
    · simp at h

/-- **No use-after-free / double free.** In a well-formed state no step ever accesses a
non-live location. -/
theorem step_not_dead {c : Cfg} (hwf : WF c.st) : step c ≠ some (.bad .dead) := by
  intro h
  unfold step at h
  split at h
  · simp at h
    exact drain_not_dead hwf (lift_bad h)
  · split at h
    · simp at h
    · simp at h; exact exec_not_dead hwf h

/-- Safety along entire runs. -/
theorem run_safe {c d : Cfg} (hwf : WF c.st) (hr : Reach c d) : step d ≠ some (.bad .dead) :=
  step_not_dead (reach_wf hwf hr)

end Orin
