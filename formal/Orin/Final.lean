import Orin.Theorems
import Orin.COW

/-!
# Machine-level corollaries

* only `store` can produce the `shared` violation;
* a `makeUnique x; store x i y` sequence never reaches `bad`.
-/

namespace Orin
open Heap

theorem opMakeUnique_ok {s : St} (hwf : WF s) {x l : Nat} (hx : x < s.locals.length)
    (hxl : s.get x = .ref l) : ∃ s1, opMakeUnique s x = .ok s1 := by
  obtain ⟨o, ho⟩ := locs_ref hwf hx hxl
  unfold opMakeUnique
  rw [if_pos hx]
  rw [hxl]
  simp only [ho]
  by_cases hrc : o.rc = 1
  · simp [hrc]
  · simp only [hrc, if_false]
    have : o.fields.all s.heap.liveb = true := by
      simp only [List.all_eq_true]
      intro v hv
      exact (liveb_iff _ _).mpr (hwf.flds l o ho v hv)
    simp [this]

theorem exec_shared_only_store {i : Instr} {rest : List Instr} {s : St}
    (h : exec i rest s = .bad .shared) : ∃ x j y, i = .store x j y := by
  unfold exec at h
  cases i with
  | store x j y => exact ⟨x, j, y, rfl⟩
  | const x n =>
    have := lift_bad h
    unfold opConst at this; split at this <;> simp at this
  | copy y x =>
    have := lift_bad h
    unfold opCopy at this
    split at this
    · dsimp only at this; split at this <;> simp at this
    · simp at this
  | load y x j =>
    have := lift_bad h
    unfold opLoad at this
    split at this
    · split at this
      · simp at this
      · split at this
        · simp at this
        · split at this
          · simp at this
          · dsimp only at this; split at this <;> simp at this
    · simp at this
  | alloc x ys =>
    have := lift_bad h
    unfold opAlloc at this
    split at this
    · dsimp only at this; split at this <;> simp at this
    · simp at this
  | makeUnique x =>
    have := lift_bad h
    unfold opMakeUnique at this
    split at this
    · split at this
      · simp at this
      · split at this
        · simp at this
        · split at this
          · simp at this
          · split at this <;> simp at this
    · simp at this
  | retain x =>
    have := lift_bad h
    unfold opRetain at this
    split at this
    · dsimp only at this; split at this <;> simp at this
    · simp at this
  | release x =>
    have := lift_bad h
    unfold opRelease at this; split at this <;> simp at this
  | ite c t e =>
    simp only at h
    split at h
    · split at h <;> simp at h
    · simp at h

/-- The `shared` violation (in-place store into a non-unique object) can only come from a `store`
instruction that is about to execute; `release` draining and all other instructions never raise it. -/
theorem step_shared_only_store {c : Cfg} (h : step c = some (.bad .shared)) :
    ∃ x j y rest, c.code = .store x j y :: rest := by
  unfold step at h
  split at h
  · simp at h
    have := lift_bad h
    unfold drain at this
    split at this
    · simp at this
    · simp at this
    · split at this
      · simp at this
      · split at this
        · simp at this
        · split at this <;> simp at this
  · cases hc : c.code with
    | nil => simp [hc] at h
    | cons i rest =>
      simp only [hc] at h
      have h' : exec i rest c.st = .bad .shared := Option.some.inj h
      obtain ⟨x, j, y, rfl⟩ := exec_shared_only_store h'
      exact ⟨x, j, y, rest, rfl⟩

/-- **Value-semantics discipline at machine level.** From a well-formed state with an empty
release worklist, if `x` is a reference local and `y` a valid local, then
`makeUnique x; store x i y` executes its `makeUnique` and then its `store` step without ever
reaching `bad` (no dead access, no store into a shared object). -/
theorem makeUnique_store_run {c : Cfg} (hwf : WF c.st) (hp : c.st.pending = [])
    {x i y l : Nat} {rest : List Instr}
    (hcode : c.code = .makeUnique x :: .store x i y :: rest)
    (hx : x < c.st.locals.length) (hy : y < c.st.locals.length) (hxl : c.st.get x = .ref l) :
    ∃ c1, step c = some (.ok c1) ∧ c1.code = .store x i y :: rest ∧ c1.st.pending = [] ∧
      step c1 ≠ some (.bad .shared) ∧ step c1 ≠ some (.bad .dead) := by
  obtain ⟨s1, h1⟩ := opMakeUnique_ok hwf hx hxl
  have hpend : s1.pending = [] := by
    have := (opMakeUnique_spec hwf h1).2.2.2.1
    rw [this]; exact hp
  have hlen := (opMakeUnique_spec hwf h1).2.1
  obtain ⟨hns, hnd⟩ := store_after_makeUnique_safe hwf h1 hy i
  refine ⟨⟨.store x i y :: rest, s1⟩, ?_, rfl, hpend, ?_, ?_⟩
  · unfold step
    rw [hp]
    simp only [hcode, exec, Res.lift, h1]
  · intro h
    unfold step at h
    simp only [hpend] at h
    simp only [exec, Res.lift] at h
    have := lift_bad (Option.some.inj h)
    exact hns this
  · intro h
    unfold step at h
    simp only [hpend] at h
    simp only [exec, Res.lift] at h
    have := lift_bad (Option.some.inj h)
    exact hnd this

/-- Non-vacuity: the initial state (empty heap, `n` dead scalar locals, empty worklist) is
well-formed, so the invariant is inhabited and every theorem applies to real runs. -/
theorem wf_init (n : Nat) :
    WF { heap := { objs := fun _ => none, next := 0 }, locals := List.replicate n (.int 0),
         pending := [] } := by
  constructor
  · intro m o h; simp at h
  · intro m o h; simp at h
  · intro m _; rfl
  · intro v hv
    have := List.eq_of_mem_replicate hv
    subst this; trivial
  · intro v hv; simp at hv
  · intro m o h; simp at h

end Orin
