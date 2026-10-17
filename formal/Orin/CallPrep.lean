import Orin.CallList

/-!
# The caller's state while the callee runs

`midK own a` : consumed operands (and the borrowed aliases rooted at them) are dead, `Unique`
locals are demoted to `Owned`.  `inv_prep` : the simulation relation survives this change of
abstract state when the consumed locals are zeroed (`clrL`): it only removes owners and makes
claims weaker.
-/

namespace Orin
open Heap

variable {ext : List Val} {a : List AS} {s : St}

theorem length_midK (own : List Nat) (a : List AS) : (midK own a).length = a.length := by
  simp [midK]

theorem gk_midK (own : List Nat) (a : List AS) (i : Nat) :
    gk (midK own a) i = if i ∈ own then .dead else
      (match gk a i with
       | .borrowed r => if r ∈ own then .dead else .borrowed r
       | .unique => .owned
       | k => k) := by
  by_cases hi : i < a.length
  · simp [gk, midK, List.getD_eq_getElem?_getD, hi]
    rfl
  · have h1 : (midK own a)[i]? = none := by
      simp [midK, List.getElem?_mapIdx, List.getElem?_eq_none (by omega : a.length ≤ i)]
    have h2 : a[i]? = none := List.getElem?_eq_none (by omega)
    simp [gk, List.getD_eq_getElem?_getD, h1, h2]

theorem midK_ne_unique (own : List Nat) (a : List AS) (i : Nat) :
    gk (midK own a) i ≠ .unique := by
  rw [gk_midK]
  by_cases h : i ∈ own
  · simp [h]
  · simp only [h, ite_false]
    cases hk : gk a i with
    | borrowed r => by_cases hr : r ∈ own <;> simp [hr]
    | _ => simp

theorem counted_midK (own : List Nat) (a : List AS) (i : Nat) :
    (gk (midK own a) i).counted = (if i ∈ own then false else (gk a i).counted) := by
  rw [gk_midK]
  by_cases h : i ∈ own
  · simp [h, AS.counted]
  · simp only [h, if_false]
    cases hk : gk a i with
    | borrowed r => by_cases hr : r ∈ own <;> simp [hr, AS.counted]
    | _ => simp [AS.counted]

theorem projL_midK (own : List Nat) (a : List AS) (L : List Val) :
    projL (midK own a) (clrL own L) = clrL own (projL a L) := by
  apply List.ext_getElem?
  intro i
  rw [projL_getElem?, clrL_getElem?, clrL_getElem?, projL_getElem?]
  by_cases h : i ∈ own
  · simp only [h, if_true]
    cases L[i]? <;> simp [gk_midK, h, pv, AS.counted]
  · simp only [h, if_false]
    have := counted_midK own a i
    simp only [h, if_false] at this
    cases L[i]? <;> simp [pv, this]

theorem ClAt.of_poison {a s i} (h : gk a i = .poison) : ClAt ext a s i := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intros <;> simp_all [AS.isRef]

theorem inv_prep (hI : Inv ext a s) {own : List Nat} (hnd : own.Nodup)
    (hown : ∀ i ∈ own, (gk a i).counted = true) :
    Inv ext (midK own a) { s with locals := clrL own s.locals } := by
  have hlen : ∀ i ∈ own, i < s.locals.length := by
    intro i hi
    have h1 := hown i hi
    have : gk a i ≠ .dead := by intro e; rw [e] at h1; simp [AS.counted] at h1
    exact hI.len ▸ lt_of_gk_ne_dead this
  refine ⟨by simp [length_midK, clrL_length, hI.len], ?_, fun i => ?_⟩
  · -- the owners only get fewer
    have hX : (projL a s.locals).length = s.locals.length := projL_length a s.locals
    have key := wf_locals (Pst ext a s) hI.wf
      (clrL own (projL a s.locals) ++ ext)
      (by
        intro m
        have h := clrL_count m own (projL a s.locals) hnd (by rw [hX]; exact hlen)
        simp only [Pst, List.count_append]
        omega)
      (by
        intro v hv
        rcases List.mem_append.mp hv with h | h
        · rw [List.mem_iff_getElem?] at h
          obtain ⟨i, hi⟩ := h
          rw [clrL_getElem?] at hi
          by_cases hio : i ∈ own
          · rw [if_pos hio] at hi
            cases hx : (projL a s.locals)[i]? with
            | none => rw [hx] at hi; simp at hi
            | some w => rw [hx] at hi; simp at hi; rw [← hi]; trivial
          · rw [if_neg hio] at hi
            exact hI.wf.locs v (by
              show v ∈ projL a s.locals ++ ext
              exact List.mem_append_left _ (List.mem_iff_getElem?.mpr ⟨i, hi⟩))
        · exact hI.wf.locs v (mem_Pst_of_ext h))
    have hp : Pst ext (midK own a) { s with locals := clrL own s.locals }
        = { Pst ext a s with locals := clrL own (projL a s.locals) ++ ext } := by
      simp [Pst, projL_midK]
    rw [hp]; exact key
  · have hcl := hI.cl i
    by_cases hio : i ∈ own
    · exact ClAt.of_dead (by rw [gk_midK]; simp [hio])
    · have hg := gk_midK own a i
      simp only [hio, if_false] at hg
      have hget : ∀ j, j ∉ own → ({ s with locals := clrL own s.locals } : St).get j = s.get j := by
        intro j hj
        show (clrL own s.locals).getD j (.int 0) = s.locals.getD j (.int 0)
        rw [clrL_get]; simp [hj]
      have hget' := hget i hio
      cases hk : gk a i with
      | dead => rw [hk] at hg; exact ClAt.of_dead hg
      | poison => rw [hk] at hg; exact ClAt.of_poison hg
      | init =>
        rw [hk] at hg
        obtain ⟨n, hn⟩ := hcl.ini hk
        exact ClAt.of_init hg ⟨n, by rw [hget']; exact hn⟩
      | owned =>
        rw [hk] at hg
        obtain ⟨l, hl⟩ := hcl.ref (by simp [hk, AS.isRef])
        exact ClAt.of_owned hg ⟨l, by rw [hget']; exact hl⟩
      | unique =>
        rw [hk] at hg
        obtain ⟨l, o, hl, _⟩ := hcl.uniq hk
        exact ClAt.of_owned hg ⟨l, by rw [hget']; exact hl⟩
      | param =>
        rw [hk] at hg
        obtain ⟨p, hp, hd⟩ := hcl.prm hk
        obtain ⟨l, hl⟩ := hcl.ref (by simp [hk, AS.isRef])
        refine ⟨?_, ?_, fun _ => ⟨p, hp, by simp only [hget']; exact hd⟩, ?_, fun _ => ⟨l, by rw [hget']; exact hl⟩⟩
        · intro e; rw [hg] at e; cases e
        · intro e; rw [hg] at e; cases e
        · intro r e; rw [hg] at e; cases e
      | borrowed r =>
        by_cases hr : r ∈ own
        · rw [hk] at hg; simp [hr] at hg; exact ClAt.of_dead hg
        · rw [hk] at hg; simp [hr] at hg
          obtain ⟨hroot, p, hp, hd, _⟩ := hcl.bor r hk
          obtain ⟨l, hl⟩ := hcl.ref (by simp [hk, AS.isRef])
          have hrg : (gk (midK own a) r).isRoot = true := by
            rw [gk_midK]
            simp only [hr, if_false]
            cases hkr : gk a r <;> simp_all [AS.isRoot]
          refine ClAt.of_borrowed hg ⟨hrg, p, ?_, ?_, ?_⟩ ⟨l, by rw [hget']; exact hl⟩
          · rw [hget r hr]; exact hp
          · simp only [hget']; exact hd
          · intro hu
            exact absurd hu (midK_ne_unique own a r)

end Orin
