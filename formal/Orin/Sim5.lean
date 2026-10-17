import Orin.Sim4

/-!
# Preservation: `alloc`, `getField`; heap changes confined to a `Unique` object
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s s' : St} {np : Nat}

/-- A heap that only changes the object `l` of a `Unique` local `x ∈ T` keeps every other
`Unique` local's count-1 object. -/
theorem hU_unique {T : Nat → Prop} (hI : Inv ext a s) {x l : Nat} {o : Obj} (hTx : T x)
    (hu : gk a x = .unique) (hl : s.get x = .ref l) (ho : s.heap.objs l = some o)
    (hrc : o.rc = 1) (hH : ∀ k, k ≠ l → s'.heap.objs k = s.heap.objs k) :
    ∀ i l' o', ¬T i → gk a i = .unique → gk a' i = .unique → s.get i = .ref l' →
      s.heap.objs l' = some o' → o'.rc = 1 →
      ∃ o'', s'.heap.objs l' = some o'' ∧ o''.rc = 1 := by
  intro i l' o' hiT hui _ hl' ho' hrc'
  have hix : i ≠ x := fun e => hiT (e ▸ hTx)
  have hne : s.get i ≠ .ref l :=
    (unique_excl hI hu hl ho hrc).2.1 i (by simp [hui, AS.isRef]) hix
  have : l' ≠ l := fun e => hne (by rw [hl', e])
  exact ⟨o', by rw [hH l' this]; exact ho', hrc'⟩

/-- … and keeps the slots of every `Desc` chain of an untouched `Borrowed` local. -/
theorem hD_unique {T : Nat → Prop} (hI : Inv ext a s) {x l : Nat} {o : Obj} (hTx : T x)
    (hu : gk a x = .unique) (hl : s.get x = .ref l) (ho : s.heap.objs l = some o)
    (hrc : o.rc = 1) (hH : ∀ k, k ≠ l → s'.heap.objs k = s.heap.objs k) :
    ∀ i r p, ¬T i → ¬T r → gk a i = .borrowed r → gk a' i = .borrowed r → s.get r = .ref p →
      Desc s.heap p (s.get i) → Desc s'.heap p (s.get i) := by
  intro i r p _ hrT hbi _ hp hd
  have hrx : r ≠ x := fun e => hrT (e ▸ hTx)
  obtain ⟨hroot, _⟩ := (hI.cl i).bor r hbi
  have hex := unique_excl hI hu hl ho hrc
  refine desc_mono (fun k o' hk ho' => ?_) hd
  have hkl : k ≠ l := by
    intro e
    subst e
    rcases desc_cases hk with he | ⟨m, o'', ho'', hw, _⟩
    · have hpk : p = k := by injection he with h; exact h.symm
      subst hpk
      exact hex.1 r hrx hroot hp
    · exact hex.2.2.2.1 m o'' ho'' _ hw rfl
  exact ⟨o', by rw [hH k hkl]; exact ho', rfl⟩

/-- ... and likewise for the caller-anchored parameters. -/
theorem hDp_unique {T : Nat → Prop} (hI : Inv ext a s) {x l : Nat} {o : Obj} (hTx : T x)
    (hu : gk a x = .unique) (hl : s.get x = .ref l) (ho : s.heap.objs l = some o)
    (hrc : o.rc = 1) (hH : ∀ k, k ≠ l → s'.heap.objs k = s.heap.objs k) :
    ∀ i p, ¬T i → gk a i = .param → gk a' i = .param → Val.ref p ∈ ext →
      Desc s.heap p (s.get i) → Desc s'.heap p (s.get i) := by
  intro i p _ _ _ hp hd
  have hex := unique_excl hI hu hl ho hrc
  refine desc_mono (fun k o' hk ho' => ?_) hd
  have hkl : k ≠ l := by
    intro e
    subst e
    rcases desc_cases hk with he | ⟨m, o'', ho'', hw, _⟩
    · have hpk : p = k := by injection he with h; exact h.symm
      subst hpk
      exact hex.2.2.2.2 _ hp rfl
    · exact hex.2.2.2.1 m o'' ho'' _ hw rfl
  exact ⟨o', by rw [hH k hkl]; exact ho', rfl⟩

theorem alloc_objs_old (H : Heap) (fs : List Val) (k : Nat) (hk : k ≠ H.next) :
    (H.alloc fs).1.objs k = H.objs k := by
  show (if k = H.next then _ else H.objs k) = _
  rw [if_neg hk]

/-- the state after `opAllocN` -/
def allocSt (s : St) (d n : Nat) : St :=
  { s with heap := (s.heap.alloc (List.replicate n (.int 0))).1,
           locals := s.locals.set d (.ref s.heap.next) }

theorem op_alloc {d n : Nat} (hI : Inv ext a s)
    (h : stepL np a (.alloc d n) = some a') : OpSafe ext a' (opAllocN s d n) := by
  simp only [stepL, stepAlloc] at h
  split at h
  · rename_i hc
    obtain ⟨hd, _⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hop : opAllocN s d n = .ok (allocSt s d n) := by
      simp [opAllocN, allocSt, hdl]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    have hs' : (allocSt s d n).locals = s.locals.set d (.ref s.heap.next) := rfl
    have hP := Pst_defK ext a a s (allocSt s d n)
      d .unique (.ref s.heap.next) hI.len (fun _ => rfl) hdl hs'
    have hobj : ∀ k, (s.heap.alloc (List.replicate n (.int 0))).1.objs k =
        if k = s.heap.next then some ⟨1, List.replicate n (.int 0)⟩ else s.heap.objs k :=
      fun k => rfl
    have hold : ∀ k o, s.heap.objs k = some o → k ≠ s.heap.next := by
      intro k o ho e
      have : k < s.heap.next := hI.wf.lt_next ho
      omega
    refine ⟨?_, ?_, ?_⟩
    · simp [length_defK, allocSt]; exact hI.len
    · rw [hP]
      have := wf_alloc_take (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega)
        (List.replicate n (.int 0))
        (by intro v hv; have := List.eq_of_mem_replicate hv; subst this; trivial)
        [] (Pst ext a s).pending rfl
        (by intro m; simp [List.count_replicate])
      simpa [pv, AS.counted, Pst, allocSt] using this
    · have hF := cl_frame (T := fun i => i = d) (a' := defK a d .unique)
        (s' := allocSt s d n)
        hI.cl (fun i hi => get_other s _ d _ hdl hs' i hi)
        (defK_hk0 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
        (defK_hk1 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
        (by
          intro i l o hiT hu hu' hl ho hrc
          exact ⟨o, by
            show (s.heap.alloc _).1.objs l = _
            rw [alloc_objs_old _ _ _ (hold l o ho)]; exact ho, hrc⟩)
        (by
          intro i r p _ _ _ _ _ hd
          refine desc_mono (fun k o' _ ho' => ?_) hd
          exact ⟨o', by
            show (s.heap.alloc _).1.objs k = _
            rw [alloc_objs_old _ _ _ (hold k o' ho')]; exact ho', rfl⟩)
        (by
          intro i p _ _ _ _ hd
          refine desc_mono (fun k o' _ ho' => ?_) hd
          exact ⟨o', by
            show (s.heap.alloc _).1.objs k = _
            rw [alloc_objs_old _ _ _ (hold k o' ho')]; exact ho', rfl⟩)
      intro i
      by_cases hi : i = d
      · subst hi
        have hkd := defK_self a i .unique (hI.len ▸ hdl)
        have hgd := get_self s _ i (.ref s.heap.next) hdl hs'
        exact ClAt.of_unique hkd ⟨s.heap.next, ⟨1, List.replicate n (.int 0)⟩, hgd, by
          show (s.heap.alloc _).1.objs _ = _
          rw [hobj]; simp, rfl⟩
      · exact hF i hi
  · simp at h

/-- Defining `d` with an uncounted kind: everything but the claim for `d` itself. -/
theorem def_uncounted {d : Nat} (hI : Inv ext a s) (hd : d < a.length) (k : AS)
    (hk : k.counted = false) (w : Val) :
    WF (Pst ext (defK a d k) (s.setL d w)) ∧
    (defK a d k).length = (s.setL d w).locals.length ∧
    ∀ i, i ≠ d → ClAt ext (defK a d k) (s.setL d w) i := by
  have hdl : d < s.locals.length := hI.len ▸ hd
  have hs' : (s.setL d w).locals = s.locals.set d w := rfl
  refine ⟨?_, ?_, ?_⟩
  · rw [Pst_defK ext a a s _ d k w hI.len (fun _ => rfl) hdl hs']
    have := wf_const (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega) 0
    simpa [St.setL, pv, hk, Pst] using this
  · simp [length_defK, St.setL]; exact hI.len
  · intro i hi
    exact cl_frame (T := fun i => i = d) (a' := defK a d k) (s' := s.setL d w)
      hI.cl (fun i hi => get_other s _ d _ hdl hs' i hi)
      (defK_hk0 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
      (defK_hk1 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
      (hU_same rfl) (hD_same rfl) (hDp_same rfl) i hi

theorem op_getField {d o i : Nat} {r : Bool} (hI : Inv ext a s)
    (h : stepL np a (.getField d o i r) = some a') : OpSafe ext a' (opGetField s d o i r) := by
  simp only [stepL, stepGet] at h
  split at h
  · rename_i hc
    obtain ⟨hd, ho, _, hrefo⟩ := hc
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hol : o < s.locals.length := hI.len ▸ ho
    obtain ⟨lo, hlo⟩ := (hI.cl o).ref hrefo
    obtain ⟨obj, hobj⟩ : ∃ obj, s.heap.objs lo = some obj := by
      have := hI.live hrefo
      rw [hlo] at this
      exact this
    have hcase : (∃ w, obj.fields[i]? = some w) ∨ obj.fields[i]? = none := by
      cases hh : obj.fields[i]? with
      | none => exact Or.inr rfl
      | some w => exact Or.inl ⟨w, rfl⟩
    rcases hcase with ⟨w, hw⟩ | hnone
    · have hwmem : w ∈ obj.fields := List.mem_of_getElem? hw
      by_cases hok : (r = false ∧ (∃ l, w = .ref l)) ∨ (r = true ∧ (∃ n, w = .int n))
      · have hop : opGetField s d o i r = .ill := by
          rcases hok with ⟨hr, l, hl⟩ | ⟨hr, n, hn⟩
          · subst hr; subst hl; simp [opGetField, hdl, hol, hlo, hobj, hw]
          · subst hr; subst hn; simp [opGetField, hdl, hol, hlo, hobj, hw]
        refine ⟨?_, fun s' hs => ?_⟩
        · intro k hh; rw [hop] at hh; cases hh
        · rw [hop] at hs; cases hs
      · have hop : opGetField s d o i r = .ok (s.setL d w) := by
          cases r <;> cases w <;> simp_all [opGetField, hdl, hol, hlo, hobj, hw]
        refine ⟨?_, fun s' hs => ?_⟩
        · intro k hh; rw [hop] at hh; cases hh
        rw [hop] at hs
        cases hs
        have hs' : (s.setL d w).locals = s.locals.set d w := rfl
        have hgd : (s.setL d w).get d = w := get_self s _ d w hdl hs'
        cases r with
        | false =>
          have h' := Option.some.inj h
          subst h'
          have hw0 : ∃ n, w = .int n := by
            cases w with
            | int n => exact ⟨n, rfl⟩
            | ref l => exact absurd (Or.inl ⟨rfl, l, rfl⟩) hok
          obtain ⟨n, hn⟩ := hw0
          obtain ⟨hwf, hlen, hcl⟩ := def_uncounted hI hd .init rfl w
          refine ⟨hlen, hwf, fun i' => ?_⟩
          by_cases hi' : i' = d
          · subst hi'
            exact ClAt.of_init (defK_self a _ _ hd) ⟨n, by rw [hgd, hn]⟩
          · exact hcl i' hi'
        | true =>
          have hw0 : ∃ lw, w = .ref lw := by
            cases w with
            | int n => exact absurd (Or.inr ⟨rfl, n, rfl⟩) hok
            | ref l => exact ⟨l, rfl⟩
          obtain ⟨lw, hlw⟩ := hw0
          simp only [ite_true] at h
          split at h
          · rename_i hroot
            have h' := Option.some.inj h
            subst h'
            obtain ⟨hwf, hlen, hcl⟩ := def_uncounted hI hd (.borrowed (rootOf a o)) rfl w
            refine ⟨hlen, hwf, fun i' => ?_⟩
            by_cases hi' : i' = d
            · subst hi'
              have hkd := defK_self a i' (.borrowed (rootOf a o)) hd
              have hgo : ∀ r', r' ≠ i' → (s.setL i' w).get r' = s.get r' := fun r' hr' =>
                get_other s _ i' _ hdl hs' r' hr'
              have hkr : ∀ k' r', r' ≠ i' → gk (defK a i' k') r' =
                  if gk a r' = .borrowed i' then .dead else gk a r' := by
                intro k' r' hr'; rw [gk_defK _ _ _ _ hd]; simp [hr']
              refine ClAt.of_borrowed hkd ?_ ⟨lw, by rw [hgd, hlw]⟩
              rw [hgd]
              cases hk : gk a o with
              | borrowed r0 =>
                have hrr : rootOf a o = r0 := by simp [rootOf, hk]
                rw [hrr] at hroot ⊢
                obtain ⟨hrt, p, hp, hdesc, hcl2⟩ := (hI.cl o).bor r0 hk
                have hg2 : gk (defK a i' (.borrowed r0)) r0 = gk a r0 := by
                  rw [hkr _ r0 hroot]
                  have : gk a r0 ≠ .borrowed i' := by
                    intro e; rw [e] at hrt; simp [AS.isRoot] at hrt
                  simp [this]
                refine ⟨by rw [hg2]; exact hrt, p, by rw [hgo r0 hroot]; exact hp, ?_, ?_⟩
                · rw [hlo] at hdesc
                  exact Desc.field hobj hwmem hdesc
                · intro hu hweq
                  rw [hg2] at hu
                  obtain ⟨l', o', hl', ho', hrc'⟩ := (hI.cl r0).uniq hu
                  rw [hp] at hl'
                  have hpl : p = l' := by injection hl'
                  subst hpl
                  exact (unique_excl hI hu hp ho' hrc').2.2.2.1 lo obj hobj w hwmem hweq
              | owned | unique | param =>
                have hrr : rootOf a o = o := by simp [rootOf, hk]
                rw [hrr] at hroot ⊢
                have hoi : o ≠ i' := hroot
                have hg2 : gk (defK a i' (.borrowed o)) o = gk a o := by
                  rw [hkr _ o hoi, hk]; simp
                refine ⟨by rw [hg2, hk]; simp [AS.isRoot], lo, by rw [hgo o hoi]; exact hlo, ?_, ?_⟩
                · have hself : Desc s.heap lo (.ref lo) := Desc.self
                  exact Desc.field hobj hwmem hself
                · intro hu hweq
                  rw [hg2] at hu
                  obtain ⟨l', o', hl', ho', hrc'⟩ := (hI.cl o).uniq hu
                  rw [hlo] at hl'
                  have hpl : lo = l' := by injection hl'
                  subst hpl
                  exact (unique_excl hI hu hlo ho' hrc').2.2.2.1 lo obj hobj w hwmem hweq
              | _ => rw [hk] at hrefo; simp [AS.isRef] at hrefo
            · exact hcl i' hi'
          · simp at h
    · have hop : opGetField s d o i r = .trap := by
        simp [opGetField, hdl, hol, hlo, hobj, hnone]
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hop] at hh; cases hh
      · rw [hop] at hs; cases hs
  · simp at h

end Orin
