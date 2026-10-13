import Orin.Sim3

/-!
# Preservation of the simulation relation: `const`, `release`, `move`, `borrow`, `dup`

Each lemma has the shape: if the abstract rule accepts the instruction (`stepL … = some a'`) in
a state related to `s`, then the concrete operation is never `bad`, and any state it produces is
related to `a'`.
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s : St} {np : Nat}

/-- Result shape of every per-instruction lemma. -/
def OpSafe (ext : List Val) (a' : List AS) (r : Res St) : Prop :=
  (∀ k, r ≠ .bad k) ∧ ∀ s', r = .ok s' → Inv ext a' s'

theorem op_const {d : Nat} {n : Int} (hI : Inv ext a s)
    (h : stepL np a (.const d n) = some a') : OpSafe ext a' (opConst s d n) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, _⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hop : opConst s d n = .ok (s.setL d (.int n)) := by simp [opConst, hdl]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    have hs' : (s.setL d (.int n)).locals = s.locals.set d (.int n) := rfl
    refine ⟨?_, ?_, ?_⟩
    · rw [length_defK]; simp [St.setL]; exact hI.len
    · rw [Pst_defK ext a a s _ d .init (.int n) hI.len (fun _ => rfl) hdl hs']
      have := wf_const (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega) 0
      simpa [St.setL, pv, AS.counted, Pst] using this
    · have hF := cl_frame (T := fun i => i = d) (a' := defK a d .init) (s' := s.setL d (.int n))
        hI.cl (fun i hi => get_other s _ d _ hdl hs' i hi)
        (defK_hk0 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
        (defK_hk1 a a d _ (hI.len ▸ hdl) (fun i => Or.inl rfl))
        (hU_same rfl) (hD_same rfl)
      intro i
      by_cases hi : i = d
      · subst hi
        exact ClAt.of_init (defK_self a _ _ (hI.len ▸ hdl)) ⟨n, get_self s _ _ _ hdl hs'⟩
      · exact hF i hi
  · simp at h

theorem op_release {x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.release x) = some a') : OpSafe ext a' (opRelease s x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hx, hcnt⟩ := hc
    have h' := Option.some.inj h
    subst h'
    unfold killK
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hop : opRelease s x =
        .ok { s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending } := by
      simp [opRelease, hxl]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    have hs' : ({ s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending } : St).locals
        = s.locals.set x (.int 0) := rfl
    have hP := Pst_defK ext a a s
      { s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending }
      x .dead (.int 0) hI.len (fun _ => rfl) hxl hs'
    refine ⟨?_, ?_, ?_⟩
    · simp [length_defK]; exact hI.len
    · rw [hP]
      have := wf_release (Pst ext a s) hI.wf x (by rw [Pst_locals_length]; omega)
      have e : (Pst ext a s).get x = s.get x := Pst_get_counted hxl hcnt
      rw [e] at this
      simpa [pv, AS.counted, Pst] using this
    · have hF := cl_frame (T := fun i => i = x) (a' := defK a x .dead)
        (s' := { s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending })
        hI.cl (fun i hi => get_other s _ x _ hxl hs' i hi)
        (defK_hk0 a a x .dead (hI.len ▸ hxl) (fun i => Or.inl rfl))
        (defK_hk1 a a x .dead (hI.len ▸ hxl) (fun i => Or.inl rfl))
        (hU_same rfl) (hD_same rfl)
      intro i
      by_cases hi : i = x
      · subst hi
        exact ClAt.of_dead (defK_self a _ _ (hI.len ▸ hxl))
      · exact hF i hi
  · simp at h

theorem count_move (L : List Val) (d x : Nat) (v : Val) (hdx : d ≠ x) (hd : d < L.length)
    (hv : L[x]? = some v) (m : Nat) :
    ((L.set x (.int 0)).set d v).count (.ref m) ≤ L.count (.ref m) := by
  have h1 := count_set L x (.int 0) v (.ref m) hv
  have hd' : (L.set x (.int 0))[d]? = L[d]? := by simp [List.getElem?_set, Ne.symm hdx]
  obtain ⟨w', hw'⟩ : ∃ w', L[d]? = some w' := ⟨L[d], by simp [hd]⟩
  have h2 := count_set (L.set x (.int 0)) d v w' (.ref m) (by rw [hd']; exact hw')
  have hz : (Val.int 0 = Val.ref m) ↔ False := by simp
  simp only [hz, ite_false] at h1
  split at h1 <;> split at h2 <;> omega

theorem op_move {d x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.move d x) = some a') : OpSafe ext a' (opMove s d x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, hx, _, hdx, hcnt⟩ := hc
    have h' := Option.some.inj h
    subst h'
    unfold killK
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hop : opMove s d x =
        .ok { s with locals := (s.locals.set d (s.get x)).set x (.int 0) } := by
      simp [opMove, hdl, hxl]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    have hcomm : (s.locals.set d (s.get x)).set x (.int 0) =
        (s.locals.set x (.int 0)).set d (s.get x) := List.set_comm _ _ hdx
    have hP1 := Pst_defK ext a a s { s with locals := s.locals.set x (.int 0) } x .dead (.int 0)
      hI.len (fun _ => rfl) hxl rfl
    have hlen1 : (defK a x .dead).length = ({ s with locals := s.locals.set x (.int 0) } : St).locals.length := by
      simp [length_defK]; exact hI.len
    have hP2 := Pst_defK ext (defK a x .dead) (defK a x .dead)
      { s with locals := s.locals.set x (.int 0) }
      { s with locals := (s.locals.set d (s.get x)).set x (.int 0) } d (gk a x) (s.get x)
      hlen1 (fun _ => rfl) (by simp; exact hdl) (by simp [hcomm])
    have hdA : d < (defK a x .dead).length := by rw [length_defK]; exact hd
    refine ⟨?_, ?_, ?_⟩
    · simp [length_defK]; exact hI.len
    · rw [hP2, hP1]
      have hxP : (Pst ext a s).locals[x]? = some (s.get x) := by
        rw [Pst_getElem?]; simp [hxl, pv, hcnt]
      have hwf := wf_locals (Pst ext a s) hI.wf
        (((Pst ext a s).locals.set x (.int 0)).set d (pv (gk a x) (s.get x)))
        (by
          intro m
          have hpv : pv (gk a x) (s.get x) = s.get x := by simp [pv, hcnt]
          rw [hpv]
          exact count_move _ d x _ hdx (by rw [Pst_locals_length]; omega) hxP m)
        (by
          intro v hv
          have hpv : pv (gk a x) (s.get x) = s.get x := by simp [pv, hcnt]
          rw [hpv] at hv
          rcases List.mem_or_eq_of_mem_set hv with h1 | h1
          · rcases List.mem_or_eq_of_mem_set h1 with h2 | h2
            · exact hI.wf.locs v h2
            · subst h2; trivial
          · subst h1; exact hI.wf.locs _ (mem_Pst_of_counted hxl hcnt))
      simpa [Pst, pv, hcnt] using hwf
    · have hxA : x < a.length := hx
      have hA : ∀ i, gk (defK (defK a x .dead) d (gk a x)) i =
          if i = d then gk a x
          else if gk (defK a x .dead) i = .borrowed d then .dead else gk (defK a x .dead) i :=
        fun i => gk_defK _ _ _ i hdA
      have hB : ∀ i, gk (defK a x .dead) i =
          if i = x then .dead else if gk a i = .borrowed x then .dead else gk a i :=
        fun i => gk_defK _ _ _ i hxA
      have hloc : ∀ i, ¬ (i = d ∨ i = x) →
          ({ s with locals := (s.locals.set d (s.get x)).set x (.int 0) } : St).get i = s.get i := by
        intro i hi
        have hi1 : i ≠ d := fun e => hi (Or.inl e)
        have hi2 : i ≠ x := fun e => hi (Or.inr e)
        simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, hi1, hi2,
          Ne.symm hi1, Ne.symm hi2]
      have hk0 : ∀ i, ¬ (i = d ∨ i = x) →
          (gk (defK (defK a x .dead) d (gk a x)) i = gk a i ∨
            (∃ y, (y = d ∨ y = x) ∧ gk a i = .borrowed y ∧
              gk (defK (defK a x .dead) d (gk a x)) i = .dead) ∨
            (gk a i = .unique ∧ gk (defK (defK a x .dead) d (gk a x)) i = .owned)) := by
        intro i hi
        have hi1 : i ≠ d := fun e => hi (Or.inl e)
        have hi2 : i ≠ x := fun e => hi (Or.inr e)
        rw [hA, hB]
        simp only [hi1, hi2, ite_false]
        by_cases hbx : gk a i = .borrowed x
        · right; left; exact ⟨x, Or.inr rfl, hbx, by simp [hbx]⟩
        · by_cases hbd : gk a i = .borrowed d
          · right; left; exact ⟨d, Or.inl rfl, hbd, by simp [hbx, hbd]⟩
          · left; simp [hbx, hbd]
      have hk1 : ∀ i y, ¬ (i = d ∨ i = x) → (y = d ∨ y = x) → gk a i = .borrowed y →
          gk (defK (defK a x .dead) d (gk a x)) i = .dead := by
        intro i y hi hy hb
        have hi1 : i ≠ d := fun e => hi (Or.inl e)
        have hi2 : i ≠ x := fun e => hi (Or.inr e)
        rw [hA, hB]
        simp only [hi1, hi2, ite_false]
        rcases hy with rfl | rfl
        · have : gk a i ≠ .borrowed x := by rw [hb]; intro h; injection h; exact hdx (by omega)
          simp [hb, this]
        · simp [hb]
      have hF := cl_frame (T := fun i => i = d ∨ i = x)
        (a' := defK (defK a x .dead) d (gk a x))
        (s' := { s with locals := (s.locals.set d (s.get x)).set x (.int 0) })
        hI.cl hloc hk0 hk1 (hU_same rfl) (hD_same rfl)
      intro i
      by_cases hi : i = d ∨ i = x
      · rcases hi with hi | hi
        · subst hi
          have hkd : gk (defK (defK a x .dead) i (gk a x)) i = gk a x := defK_self _ _ _ hdA
          have hgd : ({ s with locals := (s.locals.set i (s.get x)).set x (.int 0) } : St).get i
              = s.get x := by
            simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, Ne.symm hdx, hdl]
          cases hk : gk a x with
          | owned =>
            rw [hk] at hkd
            exact ClAt.of_owned hkd (by rw [hgd]; exact (hI.cl x).ref (by simp [hk, AS.isRef]))
          | unique =>
            rw [hk] at hkd
            obtain ⟨l, o, hl, ho, hrc⟩ := (hI.cl x).uniq hk
            exact ClAt.of_unique hkd ⟨l, o, by rw [hgd]; exact hl, ho, hrc⟩
          | _ => rw [hk] at hcnt; simp [AS.counted] at hcnt
        · subst hi
          have : gk (defK (defK a i .dead) d (gk a i)) i = .dead := by
            rw [hA, hB]; simp [Ne.symm hdx]
          exact ClAt.of_dead this
      · exact hF i hi
  · simp at h

theorem demote_kinds (a : List AS) (x : Nat) (hx : x < a.length) :
    (∀ i, gk (demote a x) i = gk a i ∨ (gk a i = .unique ∧ gk (demote a x) i = .owned)) ∧
    (∀ j, (gk (demote a x) j).counted = (gk a j).counted) ∧ (demote a x).length = a.length := by
  refine ⟨?_, ?_, length_demote a x⟩
  · intro i
    rw [gk_demote _ _ _ hx]
    by_cases h : i = x ∧ gk a x = .unique
    · right; simp [h.1, h.2]
    · left; simp [h]
  · intro j
    rw [gk_demote _ _ _ hx]
    by_cases h : j = x ∧ gk a x = .unique
    · rw [if_pos h, h.1, h.2]; simp [AS.counted]
    · rw [if_neg h]

theorem op_borrow {d x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.borrow d x) = some a') : OpSafe ext a' (opBorrow s d x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, hx, _, hdx, hrefx, hroot⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hop : opBorrow s d x = .ok (s.setL d (s.get x)) := by simp [opBorrow, hdl, hxl]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    obtain ⟨hdk0, hdk1, hdlen⟩ := demote_kinds a x hx
    have hs' : (s.setL d (s.get x)).locals = s.locals.set d (s.get x) := rfl
    have hd1 : d < (demote a x).length := by rw [hdlen]; exact hd
    have hP := Pst_defK ext a (demote a x) s (s.setL d (s.get x)) d (.borrowed (rootOf a x))
      (s.get x) (by rw [hdlen]; exact hI.len) hdk1 hdl hs'
    refine ⟨?_, ?_, ?_⟩
    · simp [length_defK, length_demote, St.setL]; exact hI.len
    · rw [hP]
      have := wf_const (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega) 0
      simpa [St.setL, pv, AS.counted, Pst] using this
    · have hF := cl_frame (T := fun i => i = d) (a' := defK (demote a x) d (.borrowed (rootOf a x)))
        (s' := s.setL d (s.get x))
        hI.cl (fun i hi => get_other s _ d _ hdl hs' i hi)
        (defK_hk0 a (demote a x) d _ hd1 hdk0)
        (defK_hk1 a (demote a x) d _ hd1 hdk0)
        (hU_same rfl) (hD_same rfl)
      intro i
      by_cases hi : i = d
      · subst hi
        have hkd := defK_self (demote a x) i (.borrowed (rootOf a x)) hd1
        have hgd : (s.setL i (s.get x)).get i = s.get x := get_self s _ _ _ hdl hs'
        have hgx : ∃ l, s.get x = .ref l := (hI.cl x).ref hrefx
        refine ClAt.of_borrowed hkd ?_ (by rw [hgd]; exact hgx)
        have hgo : ∀ r, r ≠ i → (s.setL i (s.get x)).get r = s.get r := fun r hr =>
          get_other s _ i _ hdl hs' r hr
        have hkr : ∀ k r, r ≠ i → gk (defK (demote a x) i k) r =
            if gk (demote a x) r = .borrowed i then .dead else gk (demote a x) r := by
          intro k r hr; rw [gk_defK _ _ _ _ hd1]; simp [hr]
        rw [hgd]
        cases hk : gk a x with
        | borrowed r0 =>
          have hrr : rootOf a x = r0 := by simp [rootOf, hk]
          rw [hrr] at hroot ⊢
          obtain ⟨hrt, p, hp, hdesc, hcl⟩ := (hI.cl x).bor r0 hk
          have hr0x : r0 ≠ x := by
            intro e; subst e; rw [hk] at hrt; simp [AS.isRoot] at hrt
          have hg1 : gk (demote a x) r0 = gk a r0 := by
            rw [gk_demote _ _ _ hx]; simp [hr0x]
          have hg2 : gk (defK (demote a x) i (.borrowed r0)) r0 = gk a r0 := by
            rw [hkr _ r0 hroot, hg1]
            have : gk a r0 ≠ .borrowed i := by
              intro e; rw [e] at hrt; simp [AS.isRoot] at hrt
            simp [this]
          refine ⟨by rw [hg2]; exact hrt, p, by rw [hgo r0 hroot]; exact hp, ?_, ?_⟩
          · exact hdesc
          · intro hu; exact hcl (by rw [← hg2]; exact hu)
        | owned | unique | param =>
          have hrr : rootOf a x = x := by simp [rootOf, hk]
          rw [hrr] at hroot ⊢
          obtain ⟨p, hp⟩ := hgx
          have hg2 : (gk (defK (demote a x) i (.borrowed x)) x).isRoot = true ∧
              gk (defK (demote a x) i (.borrowed x)) x ≠ .unique := by
            rw [hkr _ x (Ne.symm hdx)]
            rw [gk_demote _ _ _ hx]
            simp [hk, AS.isRoot]
          refine ⟨hg2.1, p, by rw [hgo x (Ne.symm hdx)]; exact hp, ?_, ?_⟩
          · rw [hp]; exact Desc.self
          · intro hu; exact absurd hu hg2.2
        | _ => rw [hk] at hrefx; simp [AS.isRef] at hrefx
      · exact hF i hi
  · simp at h

theorem op_dup {d x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.dup d x) = some a') : OpSafe ext a' (opCopy s d x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, hx, _, hrefx⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hlive : s.heap.liveb (s.get x) = true := (Heap.liveb_iff _ _).mpr (hI.live hrefx)
    have hop : opCopy s d x =
        .ok { s.setL d (s.get x) with heap := s.heap.bump [s.get x] } := by
      simp [opCopy, hdl, hxl, hlive]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    obtain ⟨hdk0, hdk1, hdlen⟩ := demote_kinds a x hx
    have hs' : ({ s.setL d (s.get x) with heap := s.heap.bump [s.get x] } : St).locals
        = s.locals.set d (s.get x) := rfl
    have hd1 : d < (demote a x).length := by rw [hdlen]; exact hd
    have hP := Pst_defK ext a (demote a x) s
      { s.setL d (s.get x) with heap := s.heap.bump [s.get x] } d .owned
      (s.get x) (by rw [hdlen]; exact hI.len) hdk1 hdl hs'
    obtain ⟨lx, hlx⟩ := (hI.cl x).ref hrefx
    refine ⟨?_, ?_, ?_⟩
    · simp [length_defK, length_demote, St.setL]; exact hI.len
    · rw [hP]
      have := wf_dupInto (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega) (s.get x)
        (hI.live hrefx)
      simpa [St.setL, pv, AS.counted, Pst] using this
    · have hF := cl_frame (T := fun i => i = d) (a' := defK (demote a x) d .owned)
        (s' := { s.setL d (s.get x) with heap := s.heap.bump [s.get x] })
        hI.cl (fun i hi => get_other s _ d _ hdl hs' i hi)
        (defK_hk0 a (demote a x) d _ hd1 hdk0)
        (defK_hk1 a (demote a x) d _ hd1 hdk0)
        (by
          intro i l o hiT hu hu' hl ho hrc
          have hix : i ≠ x := by
            intro e; subst e
            rw [gk_defK _ _ _ _ hd1, gk_demote _ _ _ hx] at hu'
            simp [hiT, hu] at hu'
          have hne : s.get x ≠ .ref l := (unique_excl hI hu hl ho hrc).2.1 x hrefx (Ne.symm hix)
          refine ⟨_, Heap.bump_objs_some s.heap [s.get x] l o ho, ?_⟩
          simp [count_single, hne, hrc])
        (hD_fields (fun k o ho => ⟨_, Heap.bump_objs_some s.heap [s.get x] k o ho, rfl⟩))
      intro i
      by_cases hi : i = d
      · subst hi
        have hkd := defK_self (demote a x) i .owned hd1
        have hgd : ({ s.setL i (s.get x) with heap := s.heap.bump [s.get x] } : St).get i
            = s.get x := get_self s _ _ _ hdl hs'
        exact ClAt.of_owned hkd ⟨lx, by rw [hgd]; exact hlx⟩
      · exact hF i hi
  · simp at h

end Orin
