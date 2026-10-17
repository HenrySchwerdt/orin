import Orin.CallStep

/-!
# Builtins and field operations never change the length of an array

The interval analysis (`Range*.lean`) describes an instruction it does not know (`gen`: a builtin, a
field operation) by the locals it defines and the locals it mentions.  Besides the contract of a
*call* (`CallLink.lean`) it needs: nothing changes the number of slots of an object that a counted
local still holds.  In the machine of `Machine.lean`/`Mir.lean` this holds for a stronger reason:

* `mop_len`: no instruction of `MI` frees an object or changes its number of slots (stores replace
  a slot, `makeUnique` copies into a new object, `alloc` writes a fresh location);
* `drain_len`: a release step frees an object only when the count is 1 and the object is on the
  pending list; a counted local that holds the object is a second owner, which `WF` excludes.

So the length of the array behind a counted local survives every step of the machine
(`mstep_len`); only the local itself can go (released, moved, overwritten), which the abstract
`Chg` of the analysis accounts for.
-/

namespace Orin
open Heap

variable {s s' : St}

/-- no object is freed and no object changes its number of slots -/
def LenKeep (H H' : Heap) : Prop :=
  ∀ k o, H.objs k = some o → ∃ o', H'.objs k = some o' ∧ o'.fields.length = o.fields.length

theorem LenKeep.refl (H : Heap) : LenKeep H H := fun _ o ho => ⟨o, ho, rfl⟩

theorem lenKeep_of_heap_eq {H H' : Heap} (h : H' = H) : LenKeep H H' := by
  subst h; exact LenKeep.refl _

theorem lenKeep_of_fields {H H' : Heap}
    (h : ∀ k o, H.objs k = some o → ∃ o', H'.objs k = some o' ∧ o'.fields = o.fields) :
    LenKeep H H' := by
  intro k o ho
  obtain ⟨o', h1, h2⟩ := h k o ho
  exact ⟨o', h1, by rw [h2]⟩

theorem opCopy_len (h : opCopy s d x = .ok s') : LenKeep s.heap s'.heap := by
  unfold opCopy at h
  split at h
  · dsimp only at h
    by_cases hl : s.heap.liveb (s.get x) = true
    · rw [if_pos hl] at h
      cases h
      apply lenKeep_of_fields
      intro k o ho
      exact ⟨_, Heap.bump_objs_some _ _ _ _ ho, rfl⟩
    · rw [if_neg hl] at h; cases h
  · cases h

theorem opAllocN_len (hb : ∀ m, s.heap.next ≤ m → s.heap.objs m = none)
    (h : opAllocN s d n = .ok s') : LenKeep s.heap s'.heap := by
  unfold opAllocN at h
  split at h
  · cases h
    apply lenKeep_of_fields
    intro k o ho
    have hk : k ≠ s.heap.next := by
      intro e; subst e
      rw [hb _ (Nat.le_refl _)] at ho; cases ho
    exact ⟨o, by simp [Heap.alloc, hk, ho], rfl⟩
  · cases h

theorem clr_heap (s : St) (y : Nat) : (s.clr y).heap = s.heap := by
  unfold St.clr
  split <;> rfl

/-- storing a slot keeps the number of slots -/
theorem setObj_set_len (H : Heap) (l i : Nat) (ob : Obj) (w : Val) (hl : H.objs l = some ob) :
    LenKeep H (H.setObj l { ob with fields := ob.fields.set i w }) := by
  intro k o ho
  by_cases hk : k = l
  · subst hk
    rw [hl] at ho
    cases ho
    exact ⟨{ ob with fields := ob.fields.set i w }, by simp [Heap.setObj_objs], by simp⟩
  · exact ⟨o, by simp [Heap.setObj_objs, hk, ho], rfl⟩

theorem opSetFieldE_len (oob : Res St) (hoob : ∀ s', oob ≠ .ok s')
    (h : opSetFieldE oob s x i v = .ok s') : LenKeep s.heap s'.heap := by
  unfold opSetFieldE at h
  split at h
  · cases hg : s.get x with
    | int _ => simp [hg] at h
    | ref l =>
      cases hob : s.heap.objs l with
      | none => simp [hg, hob] at h
      | some ob =>
        simp only [hg, hob] at h
        by_cases hrc : ob.rc ≠ 1
        · rw [if_pos hrc] at h; cases h
        · rw [if_neg hrc] at h
          cases hf : ob.fields[i]? with
          | none => simp only [hf] at h; exact absurd h (hoob _)
          | some old =>
            simp only [hf] at h
            cases h
            show LenKeep s.heap (s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) })
            exact setObj_set_len _ _ _ _ _ hob
  · cases h

theorem opTakeField_len (h : opTakeField s d x i = .ok s') : LenKeep s.heap s'.heap := by
  unfold opTakeField at h
  split at h
  · split at h
    · cases h
    · rename_i l
      split at h
      · cases h
      · rename_i ob hob
        by_cases hrc : ob.rc ≠ 1
        · rw [if_pos hrc] at h; cases h
        · rw [if_neg hrc] at h
          cases hf : ob.fields[i]? with
          | none => simp [hf] at h
          | some old =>
            simp only [hf] at h
            cases old with
            | int n => simp at h
            | ref m =>
              simp only at h
              cases h
              exact setObj_set_len _ _ _ _ _ hob
  · cases h

theorem opMakeUnique_len (hb : ∀ m, s.heap.next ≤ m → s.heap.objs m = none)
    (h : opMakeUnique s x = .ok s') : LenKeep s.heap s'.heap := by
  unfold opMakeUnique at h
  split at h
  · split at h
    · cases h
    · rename_i l hl
      split at h
      · cases h
      · rename_i o ho
        by_cases hrc : o.rc = 1
        · rw [if_pos hrc] at h; cases h; exact LenKeep.refl _
        · rw [if_neg hrc] at h
          by_cases hall : o.fields.all s.heap.liveb = true
          · rw [if_pos hall] at h
            dsimp only at h
            cases h
            apply lenKeep_of_fields
            intro k o' hk
            have hk' : k ≠ s.heap.next := by
              intro e; subst e
              rw [hb _ (Nat.le_refl _)] at hk; cases hk
            exact mu_heap_fields s.heap o.fields o.fields l k o' hk hk'
          · rw [if_neg hall] at h; cases h
  · cases h

theorem opArrayGet_len (h : opArrayGet s d a i r = .ok s') : LenKeep s.heap s'.heap :=
  lenKeep_of_heap_eq (opArrayGet_heap h)

/-- **No instruction of the machine frees an object or changes its number of slots.** -/
theorem mop_len (hb : ∀ m, s.heap.next ≤ m → s.heap.objs m = none) {i : MI}
    (h : mop s i = .ok s') : LenKeep s.heap s'.heap := by
  cases i with
  | const d n => exact lenKeep_of_heap_eq (opConst_heap h)
  | move d x => exact lenKeep_of_heap_eq (opMove_heap h)
  | borrow d x => exact lenKeep_of_heap_eq (opBorrow_heap h)
  | dup d x => exact opCopy_len h
  | release x => exact lenKeep_of_heap_eq (opRelease_heap h)
  | alloc d n => exact opAllocN_len hb h
  | getField d o j r => exact lenKeep_of_heap_eq (opGetField_heap h)
  | setField x j v => exact opSetFieldE_len .ill (fun _ hh => by cases hh) h
  | putField x j v => exact opSetFieldE_len .ill (fun _ hh => by cases hh) h
  | takeField d x j => exact opTakeField_len h
  | makeUnique x => exact opMakeUnique_len hb h
  | arrayLen d x => exact lenKeep_of_heap_eq (opArrayLen_heap h)
  | arrayGet d x j r => exact opArrayGet_len h
  | arraySet x j v =>
    simp only [mop] at h
    unfold opArraySet at h
    split at h
    · split at h
      · cases h
      · rename_i n hn
        by_cases h0 : 0 ≤ n
        · rw [if_pos h0] at h; exact opSetFieldE_len .trap (fun _ hh => by cases hh) h
        · rw [if_neg h0] at h; res_cases h
    · cases h
  | arrayNew d nl =>
    simp only [mop] at h
    unfold opArrayNew at h
    split at h
    · split at h
      · cases h
      · rename_i n hn
        by_cases h0 : 0 ≤ n
        · rw [if_pos h0] at h; exact opAllocN_len hb h
        · rw [if_neg h0] at h; res_cases h
    · cases h

/-- **A release step keeps the object of every counted local** (and its number of slots): the object
is freed only when its count is 1 and it is on the pending list, but a counted local that holds
it is a second owner. -/
theorem drain_len {ext : List Val} {a : List AS} (hI : Inv ext a s) (h : drain s = .ok s')
    {y l : Nat} (hy : (gk a y).counted = true) (hyl : s.get y = .ref l) {o : Obj}
    (ho : s.heap.objs l = some o) :
    ∃ o', s'.heap.objs l = some o' ∧ o'.fields.length = o.fields.length := by
  have hyi : y < s.locals.length := by
    have : gk a y ≠ .dead := by intro e; rw [e] at hy; simp [AS.counted] at hy
    exact hI.len ▸ lt_of_gk_ne_dead this
  have hmem : Val.ref l ∈ (Pst ext a s).locals := by
    have := mem_Pst_of_counted (ext := ext) hyi hy
    rwa [hyl] at this
  unfold drain at h
  split at h
  · cases h
  · rename_i rest
    cases h; exact ⟨o, ho, rfl⟩
  · rename_i l' rest hpe
    split at h
    · cases h
    · rename_i o2 ho2
      split at h
      · cases h
      · by_cases hrc : o2.rc = 1
        · rw [if_pos hrc] at h
          cases h
          have hll : l ≠ l' := by
            intro e
            subst e
            have h2 := hI.wf.sound l o ho
            have hp : Val.ref l ∈ s.pending := by rw [hpe]; exact List.mem_cons_self
            have h3 : 1 ≤ s.pending.count (.ref l) := List.count_pos_iff.mpr hp
            have h4 : 1 ≤ (Pst ext a s).locals.count (.ref l) := List.count_pos_iff.mpr hmem
            unfold St.owners at h2
            change (Pst ext a s).locals.count (.ref l) + s.pending.count (.ref l)
              + s.heap.refs l ≤ o.rc at h2
            rw [ho2] at ho
            cases ho
            omega
          exact ⟨o, by show (s.heap.del l').objs l = _; rw [del_objs, if_neg hll]; exact ho, rfl⟩
        · rw [if_neg hrc] at h
          cases h
          by_cases hll : l = l'
          · subst hll
            have e : o = o2 := by rw [ho2] at ho; exact (Option.some.inj ho).symm
            subst e
            exact ⟨{ o with rc := o.rc - 1 }, by
              show (s.heap.decRc l).objs l = _; rw [decRc_objs _ _ _ ho2, if_pos rfl], rfl⟩
          · exact ⟨o, by show (s.heap.decRc l').objs l = _; rw [decRc_objs _ _ _ ho2, if_neg hll]; exact ho, rfl⟩

/-- **No step of the machine changes the length of the array behind a counted local.**  (The
local itself may be released, moved or overwritten by the step; the array is not freed and keeps its
number of slots.) -/
theorem mstep_len {ext : List Val} {a : List AS} (hI : Inv ext a s) {code : Code} {c' : Code × St}
    (h : mstep (code, s) = some (.ok c')) {y l : Nat} (hy : (gk a y).counted = true)
    (hyl : s.get y = .ref l) {o : Obj} (ho : s.heap.objs l = some o) :
    ∃ o', c'.2.heap.objs l = some o' ∧ o'.fields.length = o.fields.length := by
  have hb : ∀ m, s.heap.next ≤ m → s.heap.objs m = none := hI.wf.bound
  unfold mstep at h
  simp only at h
  cases hp : s.pending with
  | cons hd rest =>
    rw [hp] at h
    simp only [Option.some.injEq] at h
    cases hd' : drain s with
    | ok s2 =>
      rw [hd'] at h
      simp only [Res.liftC, Res.ok.injEq] at h
      subst h
      exact drain_len hI hd' hy hyl ho
    | bad _ => rw [hd'] at h; simp [Res.liftC] at h
    | trap => rw [hd'] at h; simp [Res.liftC] at h
    | ill => rw [hd'] at h; simp [Res.liftC] at h
  | nil =>
    rw [hp] at h
    cases code with
    | nil => simp at h
    | call d f args k => simp at h
    | op i k =>
      simp only [Option.some.injEq, mexec] at h
      cases hm : mop s i with
      | ok s2 =>
        rw [hm] at h
        simp only [Res.liftC, Res.ok.injEq] at h
        subst h
        obtain ⟨o', h1, h2⟩ := mop_len hb hm _ _ ho
        exact ⟨o', h1, h2⟩
      | bad _ => rw [hm] at h; simp [Res.liftC] at h
      | trap => rw [hm] at h; simp [Res.liftC] at h
      | ill => rw [hm] at h; simp [Res.liftC] at h
    | ite cnd t e k =>
      simp only at h
      split at h
      · split at h
        · simp only [Option.some.injEq, Res.ok.injEq] at h; subst h; exact ⟨o, ho, rfl⟩
        · simp only [Option.some.injEq, Res.ok.injEq] at h; subst h; exact ⟨o, ho, rfl⟩
        · simp at h
      · simp at h
    | loop cnd t k =>
      simp only at h
      split at h
      · split at h
        · simp only [Option.some.injEq, Res.ok.injEq] at h; subst h; exact ⟨o, ho, rfl⟩
        · simp only [Option.some.injEq, Res.ok.injEq] at h; subst h; exact ⟨o, ho, rfl⟩
        · simp at h
      · simp at h

end Orin
