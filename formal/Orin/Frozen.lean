import Orin.SimArr

/-!
# Frozen: a run does not change what the caller's references reach

`Frozen ext H H'`: every object reachable (through slots) from a reference in `ext` is still live
and has the same slots in `H'` as in `H` (its reference count may differ).  The simulation
relation `Inv ext a s` already keeps the caller's anchors `ext` out of reach of every in-place
update and free; this file extracts that fact as one statement per instruction, so that a call
can be summarised: while a callee runs, everything its caller reaches is frozen.
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s s' : St} {np : Nat}

def Frozen (ext : List Val) (H H' : Heap) : Prop :=
  ∀ p k o, Val.ref p ∈ ext → Desc H p (.ref k) → H.objs k = some o →
    ∃ o', H'.objs k = some o' ∧ o'.fields = o.fields

theorem Frozen.refl (H : Heap) : Frozen ext H H := fun _ _ o _ _ ho => ⟨o, ho, rfl⟩

theorem Frozen.trans {H1 H2 H3 : Heap} (h12 : Frozen ext H1 H2) (h23 : Frozen ext H2 H3) :
    Frozen ext H1 H3 := by
  intro p k o hp hd ho
  obtain ⟨o2, ho2, hf2⟩ := h12 p k o hp hd ho
  have hd2 : Desc H2 p (.ref k) := desc_mono (fun k' o' hk' ho' => h12 p k' o' hp hk' ho') hd
  obtain ⟨o3, ho3, hf3⟩ := h23 p k o2 hp hd2 ho2
  exact ⟨o3, ho3, hf3.trans hf2⟩

theorem Frozen.mono {ext ext' : List Val} {H H' : Heap} (hs : ∀ v ∈ ext, v ∈ ext')
    (h : Frozen ext' H H') : Frozen ext H H' :=
  fun p k o hp => h p k o (hs _ hp)

theorem Frozen.desc {H H' : Heap} {p : Nat} {w : Val} (h : Frozen ext H H')
    (hp : Val.ref p ∈ ext) (hd : Desc H p w) : Desc H' p w :=
  desc_mono (fun k o hk ho => h p k o hp hk ho) hd

/-- A chain that starts below an anchor is stable too. -/
theorem Frozen.desc_in {H H' : Heap} {p q : Nat} {w : Val} (h : Frozen ext H H')
    (hp : Val.ref p ∈ ext) (hq : Desc H p (.ref q)) (hd : Desc H q w) : Desc H' q w :=
  desc_mono (fun k o hk ho => h p k o hp (desc_trans hk hq) ho) hd

/-- Heap changes that keep every live object's slots. -/
theorem frozen_fields {H H' : Heap}
    (hH : ∀ k o, H.objs k = some o → ∃ o', H'.objs k = some o' ∧ o'.fields = o.fields) :
    Frozen ext H H' :=
  fun _ k o _ _ ho => hH k o ho

/-- Heap changes confined to the object of a `Unique` local: that object is out of reach of
every anchor. -/
theorem frozen_unique (hI : Inv ext a s) {x l : Nat} {o : Obj} {H' : Heap}
    (hu : gk a x = .unique) (hl : s.get x = .ref l) (ho : s.heap.objs l = some o)
    (hrc : o.rc = 1) (hH : ∀ k, k ≠ l → H'.objs k = s.heap.objs k) : Frozen ext s.heap H' := by
  intro p k o' hp hk ho'
  have hex := unique_excl hI hu hl ho hrc
  have hkl : k ≠ l := by
    intro e
    subst e
    rcases desc_cases hk with he | ⟨m, o'', ho'', hw, _⟩
    · have hpk : p = k := by injection he with h; exact h.symm
      subst hpk
      exact hex.2.2.2.2 _ hp rfl
    · exact hex.2.2.2.1 m o'' ho'' _ hw rfl
  exact ⟨o', by rw [hH k hkl]; exact ho', rfl⟩


/-! ### one lemma per concrete operation -/

theorem frozen_heap_eq {H H' : Heap} (h : H' = H) : Frozen ext H H' := by
  subst h; exact Frozen.refl _

/-- split every `if`/`match` of a hypothesis `h : op … = .ok s'` and finish each branch. -/
macro "res_cases" h:ident : tactic =>
  `(tactic| repeat' (first | split at $h:ident | (cases $h:ident; rfl) | cases $h:ident))

theorem opConst_heap (h : opConst s d n = .ok s') : s'.heap = s.heap := by
  unfold opConst at h; res_cases h

theorem opMove_heap (h : opMove s d x = .ok s') : s'.heap = s.heap := by
  unfold opMove at h; res_cases h

theorem opBorrow_heap (h : opBorrow s d x = .ok s') : s'.heap = s.heap := by
  unfold opBorrow at h; res_cases h

theorem opRelease_heap (h : opRelease s x = .ok s') : s'.heap = s.heap := by
  unfold opRelease at h; res_cases h

theorem opGetFieldE_heap (oob : Res St) (hoob : ∀ s', oob ≠ .ok s')
    (h : opGetFieldE oob s d o i r = .ok s') : s'.heap = s.heap := by
  unfold opGetFieldE at h
  repeat' (first | split at h | (cases h; rfl) | exact absurd h (hoob _) | cases h)

theorem opGetField_heap (h : opGetField s d o i r = .ok s') : s'.heap = s.heap :=
  opGetFieldE_heap .ill (fun _ hh => by cases hh) h

theorem opArrayLen_heap (h : opArrayLen s d x = .ok s') : s'.heap = s.heap := by
  unfold opArrayLen at h; res_cases h

theorem opCopy_frozen (h : opCopy s d x = .ok s') : Frozen ext s.heap s'.heap := by
  unfold opCopy at h
  split at h
  · dsimp only at h
    by_cases hl : s.heap.liveb (s.get x) = true
    · rw [if_pos hl] at h
      cases h
      apply frozen_fields
      intro k o ho
      exact ⟨_, Heap.bump_objs_some _ _ _ _ ho, rfl⟩
    · rw [if_neg hl] at h; cases h
  · cases h

theorem opAllocN_frozen (hI : Inv ext a s) (h : opAllocN s d n = .ok s') :
    Frozen ext s.heap s'.heap := by
  unfold opAllocN at h
  split at h
  · cases h
    apply frozen_fields
    intro k o ho
    have hk : k ≠ s.heap.next := by
      intro e; subst e
      have := hI.wf.bound _ (Nat.le_refl _)
      simp [Pst] at this
      rw [this] at ho; cases ho
    exact ⟨o, by simp [Heap.alloc, hk, ho], rfl⟩
  · cases h


theorem opSetFieldE_frozen (hI : Inv ext a s) {x i v : Nat} (hu : gk a x = .unique)
    (oob : Res St) (hoob : ∀ s', oob ≠ .ok s')
    (h : opSetFieldE oob s x i v = .ok s') : Frozen ext s.heap s'.heap := by
  obtain ⟨l, o, hl, ho, hrc⟩ := (hI.cl x).uniq hu
  unfold opSetFieldE at h
  split at h
  · simp only [hl, ho, hrc, ne_eq, not_true_eq_false, ite_false] at h
    cases hf : o.fields[i]? with
    | none => simp only [hf] at h; exact absurd h (hoob _)
    | some old =>
      simp only [hf] at h
      cases h
      exact frozen_unique hI hu hl ho hrc (fun k hk => by simp [Heap.setObj_objs, hk])
  · cases h

theorem opSetField_frozen (hI : Inv ext a s) {x i v : Nat} (hu : gk a x = .unique)
    (h : opSetField s x i v = .ok s') : Frozen ext s.heap s'.heap :=
  opSetFieldE_frozen hI hu .ill (fun _ hh => by cases hh) h

theorem opTakeField_frozen (hI : Inv ext a s) {d x i : Nat} (hu : gk a x = .unique)
    (h : opTakeField s d x i = .ok s') : Frozen ext s.heap s'.heap := by
  obtain ⟨l, o, hl, ho, hrc⟩ := (hI.cl x).uniq hu
  unfold opTakeField at h
  split at h
  · simp only [hl, ho, hrc, ne_eq, not_true_eq_false, ite_false] at h
    cases hf : o.fields[i]? with
    | none => simp [hf] at h
    | some old =>
      simp only [hf] at h
      cases old with
      | int n => simp at h
      | ref m =>
        simp only at h
        cases h
        exact frozen_unique hI hu hl ho hrc (fun k hk => by simp [Heap.setObj_objs, hk])
  · cases h

theorem mu_heap_fields (H : Heap) (vs fs : List Val) (l k : Nat) (o' : Obj)
    (hk : H.objs k = some o') (hkn : k ≠ H.next) :
    ∃ o'', (((H.bump vs).alloc fs).1.decRc l).objs k = some o'' ∧ o''.fields = o'.fields := by
  have hA : ((H.bump vs).alloc fs).1.objs k = some { o' with rc := o'.rc + vs.count (.ref k) } := by
    simp [Heap.alloc, Heap.bump, hkn, hk]
  unfold Heap.decRc
  cases hl : ((H.bump vs).alloc fs).1.objs l with
  | none => exact ⟨_, hA, rfl⟩
  | some o2 =>
    simp only [hl]
    by_cases hkl : k = l
    · subst hkl
      rw [hA] at hl
      cases hl
      exact ⟨{ o' with rc := o'.rc + vs.count (.ref k) - 1 }, by simp [Heap.setObj_objs], rfl⟩
    · exact ⟨{ o' with rc := o'.rc + vs.count (.ref k) }, by simp [Heap.setObj_objs, hkl, hA], rfl⟩

theorem opMakeUnique_frozen (hI : Inv ext a s) (h : opMakeUnique s x = .ok s') :
    Frozen ext s.heap s'.heap := by
  unfold opMakeUnique at h
  split at h
  · split at h
    · cases h
    · rename_i l hl
      split at h
      · cases h
      · rename_i o ho
        by_cases hrc : o.rc = 1
        · rw [if_pos hrc] at h; cases h; exact Frozen.refl _
        · rw [if_neg hrc] at h
          by_cases hall : o.fields.all s.heap.liveb = true
          · rw [if_pos hall] at h
            dsimp only at h
            cases h
            apply frozen_fields
            intro k o' hk
            have hk' : k ≠ s.heap.next := by
              intro e; subst e
              have := hI.wf.bound _ (Nat.le_refl _)
              simp [Pst] at this
              rw [this] at hk; cases hk
            exact mu_heap_fields s.heap o.fields o.fields l k o' hk hk'
          · rw [if_neg hall] at h; cases h
  · cases h


theorem drain_frozen (hI : Inv ext a s) (h : drain s = .ok s') : Frozen ext s.heap s'.heap := by
  unfold drain at h
  split at h
  · cases h
  · rename_i rest
    cases h; exact Frozen.refl _
  · rename_i l rest hpe
    split at h
    · cases h
    · rename_i o ho
      have hmem : Val.ref l ∈ s.pending := by rw [hpe]; exact List.mem_cons_self
      split at h
      · cases h
      · by_cases hrc : o.rc = 1
        · rw [if_pos hrc] at h
          cases h
          intro p k o' hp hk ho'
          have hkl : k ≠ l := by
            intro e
            subst e
            have h1 := desc_owned_mem hI (mem_Pst_of_ext hp) hk
            have h2 := hI.wf.sound k o ho
            have h3 : 1 ≤ s.pending.count (.ref k) := List.count_pos_iff.mpr hmem
            unfold St.owners at h2
            change (Pst ext a s).locals.count (.ref k) + s.pending.count (.ref k)
              + s.heap.refs k ≤ o.rc at h2
            omega
          exact ⟨o', by show (s.heap.del l).objs k = _; rw [del_objs, if_neg hkl]; exact ho', rfl⟩
        · rw [if_neg hrc] at h
          cases h
          apply frozen_fields
          intro k o' hk
          by_cases hkl : k = l
          · subst hkl
            have hf : o'.fields = o.fields := by
              rw [ho] at hk; rw [Option.some.inj hk]
            exact ⟨{ o with rc := o.rc - 1 }, by
              show (s.heap.decRc k).objs k = _; rw [decRc_objs _ _ _ ho, if_pos rfl], hf.symm⟩
          · exact ⟨o', by show (s.heap.decRc l).objs k = _; rw [decRc_objs _ _ _ ho, if_neg hkl]; exact hk, rfl⟩

theorem stepSet_unique {a : List AS} {x v : Nat} {a1 : List AS} (h : stepSet a x v = some a1) :
    gk a x = .unique := by
  unfold stepSet at h
  split at h
  · rename_i hc; exact hc.2.2
  · cases h

theorem opArrayGet_heap (h : opArrayGet s d o i r = .ok s') : s'.heap = s.heap := by
  unfold opArrayGet at h
  split at h
  · split at h
    · cases h
    · rename_i n hn
      by_cases h0 : 0 ≤ n
      · rw [if_pos h0] at h; exact opGetFieldE_heap .trap (fun _ hh => by cases hh) h
      · rw [if_neg h0] at h
        res_cases h
  · cases h

/-- Every concrete operation leaves everything reachable from the anchors alone. -/
theorem op_frozen (hI : Inv ext a s) {i : MI} {a1 : List AS} (hL : stepL np a i = some a1)
    (h : mop s i = .ok s') : Frozen ext s.heap s'.heap := by
  cases i with
  | const d n => exact frozen_heap_eq (opConst_heap h)
  | move d x => exact frozen_heap_eq (opMove_heap h)
  | borrow d x => exact frozen_heap_eq (opBorrow_heap h)
  | dup d x => exact opCopy_frozen h
  | release x => exact frozen_heap_eq (opRelease_heap h)
  | alloc d n => exact opAllocN_frozen hI h
  | getField d o j r => exact frozen_heap_eq (opGetField_heap h)
  | setField x j v => exact opSetField_frozen hI (stepSet_unique hL) h
  | putField x j v => exact opSetField_frozen hI (stepSet_unique hL) h
  | takeField d x j =>
    have hu : gk a x = .unique := by
      simp only [stepL] at hL
      split at hL
      · rename_i hc; exact hc.2.2.2.2
      · cases hL
    exact opTakeField_frozen hI hu h
  | makeUnique x => exact opMakeUnique_frozen hI h
  | arrayLen d x => exact frozen_heap_eq (opArrayLen_heap h)
  | arrayGet d x i r => exact frozen_heap_eq (opArrayGet_heap h)
  | arraySet x i v =>
    have hu : gk a x = .unique := by
      simp only [stepL] at hL
      split at hL
      · exact stepSet_unique hL
      · cases hL
    simp only [mop] at h
    unfold opArraySet at h
    split at h
    · split at h
      · cases h
      · rename_i n hn
        by_cases h0 : 0 ≤ n
        · rw [if_pos h0] at h; exact opSetFieldE_frozen hI hu .trap (fun _ hh => by cases hh) h
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
        · rw [if_pos h0] at h; exact opAllocN_frozen hI h
        · rw [if_neg h0] at h; res_cases h
    · cases h

end Orin
