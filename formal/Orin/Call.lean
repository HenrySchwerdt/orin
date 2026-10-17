import Orin.CallEntry

/-!
# Calls: functions, the return lemma

`Fn` is a function of a multi-function program: parameter modes (`PM`), the number of locals, the
local holding the result, and the code.  `fcheck` checks one function stand-alone against the
signatures `sg` of all functions (a call is checked by `stepAC`, `Check.lean`).  `inv_ret` is the
return lemma: when the callee ends in a state related to the caller's anchors (`inv_entry`,
`CallEntry.lean`), and nothing the caller reaches changed (`Frozen`), the caller's simulation
relation holds again with the callee's result stored in the destination.
-/

namespace Orin
open Heap

/-- a function of a program -/
structure Fn where
  params : List PM
  retRef : Bool
  n : Nat
  ret : Nat
  code : Code

def Fn.sig (f : Fn) : Sig := ⟨f.params, f.retRef⟩

/-- the abstract entry state of a function -/
def Fn.entry (f : Fn) : AState := ⟨entryLs f.params f.n, []⟩

/-- the result local at the end of a function: a counted reference (ownership passes to the caller)
or an initialised scalar -/
def retPred (r : Nat) (rr : Bool) (x : AState) : Prop :=
  r < x.ls.length ∧ (rr = true → (gk x.ls r = .owned ∨ gk x.ls r = .unique)) ∧
    (rr = false → gk x.ls r = .init)

instance (r : Nat) (rr : Bool) (x : AState) : Decidable (retPred r rr x) := by
  unfold retPred; infer_instance

def retK (rr : Bool) : AS := if rr then .owned else .init

/-- stand-alone check of one function against the signatures `sg` -/
def fcheck (sg : List Sig) (f : Fn) : Bool :=
  decide (f.params.length ≤ f.n) &&
  match chk f.params.length sg f.entry f.code with
  | some af => af.holes.isEmpty && decide (retPred f.ret f.retRef af)
  | none => false

/-- a program of functions is accepted when every function is -/
def pcheck (fns : List Fn) : Bool := fns.all (fcheck (fns.map Fn.sig))

/-! ### the return lemma -/

theorem inv_ret {extB : List Val} {aMid : List AS} {L : List Val} {H0 H : Heap} {d : Nat}
    {rr : Bool}
    (hIB : Inv extB aMid ⟨H0, L, []⟩) (hnu : ∀ i, gk aMid i ≠ .unique) (hd : d < L.length)
    {af : List AS} {sF : St} {r : Nat}
    (hIF : Inv (projL aMid L ++ extB) af sF) (hp : sF.pending = []) (hH : sF.heap = H)
    (hFz : Frozen (projL aMid L ++ extB) H0 H)
    (hr : retPred r rr ⟨af, []⟩) :
    Inv extB (defK aMid d (retK rr)) ⟨H, L.set d (sF.get r), []⟩ := by
  obtain ⟨hrl, hrR, hrS⟩ := hr
  simp only at hrl hrR hrS
  have hIBlen : aMid.length = L.length := hIB.len
  have hdA : d < aMid.length := by omega
  have hrS' : r < sF.locals.length := hIF.len ▸ hrl
  have hs' : (⟨H, L.set d (sF.get r), []⟩ : St).locals = L.set d (sF.get r) := rfl
  have hP := Pst_defK extB aMid aMid ⟨H0, L, []⟩ ⟨H, L.set d (sF.get r), []⟩ d (retK rr)
    (sF.get r) hIB.len (fun _ => rfl) hd hs'
  -- the result is held by the callee's result local
  have hmem : rr = true → sF.get r ∈ projL af sF.locals := by
    intro h
    have hc : (gk af r).counted = true := by
      rcases hrR h with e | e <;> rw [e] <;> rfl
    have hg : sF.locals[r]? = some (sF.get r) := by
      simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hrS']
    refine List.mem_iff_getElem?.mpr ⟨r, ?_⟩
    rw [projL_getElem?, hg]
    simp [pv, hc]
  have hX : (Pst extB aMid ⟨H0, L, []⟩).locals = projL aMid L ++ extB := rfl
  have hdX : d < (projL aMid L ++ extB).length := by
    simp [projL_length]; omega
  have wfN : WF (Pst extB (defK aMid d (retK rr)) ⟨H, L.set d (sF.get r), []⟩) := by
    rw [hP]
    have key := wf_locals (Pst (projL aMid L ++ extB) af sF) hIF.wf
      ((projL aMid L ++ extB).set d (pv (retK rr) (sF.get r)))
      (by
        intro m
        obtain ⟨w, hw⟩ : ∃ w, (projL aMid L ++ extB)[d]? = some w :=
          ⟨_, List.getElem?_eq_getElem hdX⟩
        have hc := count_set (projL aMid L ++ extB) d (pv (retK rr) (sF.get r)) w (.ref m) hw
        simp only [Pst, List.count_append] at hc ⊢
        by_cases hu : pv (retK rr) (sF.get r) = .ref m
        · have hrt : rr = true := by
            cases rr
            · simp [retK, pv, AS.counted] at hu
            · rfl
          have h1 := hmem hrt
          have h2 : (projL af sF.locals).count (.ref m) ≥ 1 := by
            apply List.count_pos_iff.mpr
            have : pv (retK rr) (sF.get r) = sF.get r := by simp [hrt, retK, pv, AS.counted]
            rw [this] at hu
            rw [← hu]; exact h1
          simp only [hu, ite_true] at hc ⊢
          split at hc <;> omega
        · simp only [hu, ite_false] at hc
          split at hc <;> omega)
      (by
        intro v hv
        rcases List.mem_or_eq_of_mem_set hv with h | h
        · exact hIF.wf.locs v (by
            show v ∈ projL af sF.locals ++ (projL aMid L ++ extB)
            exact List.mem_append_right _ h)
        · subst h
          cases hrr : rr
          · simp [retK, pv, AS.counted, Heap.LiveVal]
          · have := hmem hrr
            exact hIF.wf.locs _ (by
              show _ ∈ projL af sF.locals ++ (projL aMid L ++ extB)
              exact List.mem_append_left _ this))
    obtain ⟨hh, ll, pp⟩ := sF
    simp only at hp hH
    subst hp; subst hH
    exact key
  refine ⟨by simp [length_defK]; omega, wfN, fun i => ?_⟩
  by_cases hi : i = d
  · subst hi
    have hg : (⟨H, L.set i (sF.get r), []⟩ : St).get i = sF.get r :=
      get_self ⟨H0, L, []⟩ _ i _ hd hs'
    cases rr
    · have hk' : gk (defK aMid i (retK false)) i = .init := defK_self aMid i (retK false) hdA
      obtain ⟨n, hn⟩ := (hIF.cl r).ini (hrS rfl)
      exact ClAt.of_init hk' ⟨n, by rw [hg]; exact hn⟩
    · have hk' : gk (defK aMid i (retK true)) i = .owned := defK_self aMid i (retK true) hdA
      have hrf : (gk af r).isRef = true := by
        rcases hrR rfl with e | e <;> rw [e] <;> rfl
      obtain ⟨l, hl⟩ := (hIF.cl r).ref hrf
      exact ClAt.of_owned hk' ⟨l, by rw [hg]; exact hl⟩
  · exact cl_frame (T := fun j => j = d) (a' := defK aMid d (retK rr))
      (s' := ⟨H, L.set d (sF.get r), []⟩) (s := ⟨H0, L, []⟩)
      hIB.cl (fun j hj => get_other ⟨H0, L, []⟩ _ d _ hd hs' j hj)
      (defK_hk0 aMid aMid d _ hdA (fun j => Or.inl rfl))
      (defK_hk1 aMid aMid d _ hdA (fun j => Or.inl rfl))
      (by intro j l o _ hu _ _ _ _; exact absurd hu (hnu j))
      (by
        intro j rr' p _ _ hb _ hget hdesc
        obtain ⟨hroot, _⟩ := (hIB.cl j).bor rr' hb
        obtain ⟨p0, hp0, hd0⟩ := hIB.root_anchor hroot hget
        exact Frozen.desc_in hFz hp0 hd0 hdesc)
      (by
        intro j p _ _ _ hp hdesc
        exact hFz.desc (List.mem_append_right _ hp) hdesc)
      i hi

end Orin
