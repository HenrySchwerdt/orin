import Orin.Sim2

/-!
# Projection under definitions, and the simple transfer functions
-/

namespace Orin
open Heap

variable {ext : List Val} {a a0 a' : List AS} {s s' : St}

theorem counted_defK (a0 : List AS) (d : Nat) (k : AS) (hd : d < a0.length) (j : Nat) (hj : j ≠ d) :
    (gk (defK a0 d k) j).counted = (gk a0 j).counted := by
  rw [gk_defK _ _ _ _ hd]
  by_cases h : gk a0 j = .borrowed d
  · simp [hj, h, AS.counted]
  · simp [hj, h]

/-- Defining local `d` changes the projection only at `d`. -/
theorem Pst_defK (ext : List Val) (a a0 : List AS) (s s' : St) (d : Nat) (k : AS) (v : Val)
    (ha0len : a0.length = s.locals.length)
    (ha0 : ∀ j, (gk a0 j).counted = (gk a j).counted) (hd : d < s.locals.length)
    (hs' : s'.locals = s.locals.set d v) :
    Pst ext (defK a0 d k) s' =
      { Pst ext a s with heap := s'.heap, locals := (Pst ext a s).locals.set d (pv k v),
                         pending := s'.pending } := by
  have hd0 : d < a0.length := by omega
  have hlen' : s'.locals.length = s.locals.length := by rw [hs']; simp
  have hg : ∀ j, s'.get j = if j = d then v else s.get j := by
    intro j
    by_cases hjd : j = d
    · subst hjd; simp [St.get, hs', hd]
    · simp [St.get, hs', List.getD_eq_getElem?_getD, List.getElem?_set, hjd, Ne.symm hjd]
  unfold Pst
  congr 1
  apply List.ext_getElem?
  intro j
  rw [projSt_getElem?, List.getElem?_set, projSt_getElem?, hlen']
  have hdl : d < (projL a s.locals ++ ext).length := by
    simp [projL_length]; omega
  by_cases hj : j < s.locals.length
  · simp only [hj, ite_true]
    by_cases hjd : d = j
    · subst hjd
      simp [hdl, gk_defK _ _ _ _ hd0, hg, projL_length]
      omega
    · have hjd' : j ≠ d := fun h => hjd h.symm
      have hc : (gk (defK a0 d k) j).counted = (gk a j).counted := by
        rw [counted_defK a0 d k hd0 j hjd', ha0]
      simp only [hjd, ite_false, projSt_getElem?, hj, ite_true, hg, hjd']
      simp only [pv, hc]
  · have hjd : d ≠ j := by omega
    simp [hj, hjd]

/-! ### kind facts for `defK` with the frame lemma -/

theorem defK_hk0 (a a0 : List AS) (d : Nat) (k : AS) (hd : d < a0.length)
    (h0 : ∀ i, gk a0 i = gk a i ∨ (gk a i = .unique ∧ gk a0 i = .owned)) :
    ∀ i, ¬ (i = d) → (gk (defK a0 d k) i = gk a i ∨
      (∃ x, x = d ∧ gk a i = .borrowed x ∧ gk (defK a0 d k) i = .dead) ∨
      (gk a i = .unique ∧ gk (defK a0 d k) i = .owned)) := by
  intro i hi
  rw [gk_defK _ _ _ _ hd]
  simp only [hi, ite_false]
  rcases h0 i with e | ⟨e1, e2⟩
  · by_cases hb : gk a0 i = .borrowed d
    · right; left; exact ⟨d, rfl, by rw [← e]; exact hb, by simp [hb]⟩
    · left
      have hb' : ¬ gk a i = .borrowed d := by rw [← e]; exact hb
      simp [hb', e]
  · right; right
    refine ⟨e1, ?_⟩
    simp [e2]

theorem defK_hk1 (a a0 : List AS) (d : Nat) (k : AS) (hd : d < a0.length)
    (h0 : ∀ i, gk a0 i = gk a i ∨ (gk a i = .unique ∧ gk a0 i = .owned)) :
    ∀ i x, ¬ (i = d) → x = d → gk a i = .borrowed x → gk (defK a0 d k) i = .dead := by
  intro i x hi hx hb
  subst hx
  rw [gk_defK _ _ _ _ hd]
  simp only [hi, ite_false]
  rcases h0 i with e | ⟨e1, e2⟩
  · simp [e, hb]
  · rw [hb] at e1; cases e1

theorem defK_self (a0 : List AS) (d : Nat) (k : AS) (hd : d < a0.length) :
    gk (defK a0 d k) d = k := by
  rw [gk_defK _ _ _ _ hd]; simp

theorem get_other (s s' : St) (d : Nat) (v : Val) (hd : d < s.locals.length)
    (hs' : s'.locals = s.locals.set d v) (i : Nat) (hi : ¬ (i = d)) : s'.get i = s.get i := by
  simp [St.get, hs', List.getD_eq_getElem?_getD, List.getElem?_set, hi, Ne.symm hi]

theorem get_self (s s' : St) (d : Nat) (v : Val) (hd : d < s.locals.length)
    (hs' : s'.locals = s.locals.set d v) : s'.get d = v := by
  simp [St.get, hs', hd]

theorem ClAt.of_dead {a s i} (h : gk a i = .dead) : ClAt ext a s i := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intros <;> simp_all [AS.isRef]

theorem ClAt.of_init {a s i} (h : gk a i = .init) (hv : ∃ n, s.get i = .int n) :
    ClAt ext a s i := by
  refine ⟨fun _ => hv, ?_, ?_, ?_, ?_⟩ <;> intros <;> simp_all [AS.isRef]

theorem ClAt.of_owned {a s i} (h : gk a i = .owned) (hv : ∃ l, s.get i = .ref l) :
    ClAt ext a s i := by
  refine ⟨?_, ?_, ?_, ?_, fun _ => hv⟩ <;> intros <;> simp_all [AS.isRef]

theorem ClAt.of_unique {a s i} (h : gk a i = .unique)
    (hv : ∃ l o, s.get i = .ref l ∧ s.heap.objs l = some o ∧ o.rc = 1) :
    ClAt ext a s i := by
  refine ⟨?_, fun _ => hv, ?_, ?_, fun _ => ?_⟩
  · intro e; simp_all
  · intro e; simp_all
  · intro r e; simp_all
  · obtain ⟨l, _, hl, _⟩ := hv; exact ⟨l, hl⟩

theorem ClAt.of_borrowed {a s i r} (h : gk a i = .borrowed r)
    (hb : (gk a r).isRoot = true ∧ ∃ p, s.get r = .ref p ∧ Desc s.heap p (s.get i) ∧
      (gk a r = .unique → s.get i ≠ .ref p))
    (hv : ∃ l, s.get i = .ref l) : ClAt ext a s i := by
  refine ⟨?_, ?_, ?_, ?_, fun _ => hv⟩
  · intro e; simp_all
  · intro e; simp_all
  · intro e; simp_all
  · intro r' e
    rw [h] at e
    cases e
    exact hb

end Orin
