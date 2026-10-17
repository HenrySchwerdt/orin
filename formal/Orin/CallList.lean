import Orin.SoundFz

/-!
# List facts for calls: consuming the owned operands

`clrL own L` zeroes the locals at the indices `own` (the operands moved into owned parameters).
`midK` (`Check.lean`) is the caller's abstract state while the callee runs.  The facts here are
pure list/bookkeeping lemmas used by the call and return lemmas of `Call.lean`.
-/

namespace Orin
open Heap

def clrL : List Nat → List Val → List Val
  | [], L => L
  | i :: is, L => clrL is (L.set i (.int 0))

theorem clrL_length : ∀ (own : List Nat) (L : List Val), (clrL own L).length = L.length
  | [], L => rfl
  | i :: is, L => by simp [clrL, clrL_length is]

theorem clrL_getElem? : ∀ (own : List Nat) (L : List Val) (i : Nat),
    (clrL own L)[i]? = if i ∈ own then (L[i]?).map (fun _ => Val.int 0) else L[i]?
  | [], L, i => by simp [clrL]
  | j :: js, L, i => by
    simp only [clrL, clrL_getElem? js, List.getElem?_set, List.mem_cons]
    by_cases hij : i = j
    · subst hij
      by_cases hl : i < L.length
      · simp [hl]
      · simp [hl, List.getElem?_eq_none (by omega : L.length ≤ i)]
    · by_cases hm : i ∈ js
      · simp [hij, hm, Ne.symm hij]
      · simp [hij, hm, Ne.symm hij]

theorem clrL_get (own : List Nat) (L : List Val) (i : Nat) :
    (clrL own L).getD i (.int 0) = if i ∈ own then .int 0 else L.getD i (.int 0) := by
  simp only [List.getD_eq_getElem?_getD, clrL_getElem?]
  by_cases h : i ∈ own <;> simp [h] <;> cases L[i]? <;> simp

theorem getD_set_ne (L : List Val) (i j : Nat) (v : Val) (h : i ≠ j) :
    (L.set i v).getD j (.int 0) = L.getD j (.int 0) := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_set, h]

/-- counts: what `clrL` removes is exactly the multiset of the operands. -/
theorem clrL_count (m : Nat) : ∀ (own : List Nat) (X : List Val), own.Nodup →
    (∀ i ∈ own, i < X.length) →
    (clrL own X).count (.ref m) + (own.map (fun i => X.getD i (.int 0))).count (.ref m)
      = X.count (.ref m)
  | [], X, _, _ => by simp [clrL]
  | i :: is, X, hnd, hlt => by
    have hi : i ∉ is := (List.nodup_cons.mp hnd).1
    have hnd' : is.Nodup := (List.nodup_cons.mp hnd).2
    have hX : X[i]? = some (X.getD i (.int 0)) := by
      have := hlt i (List.mem_cons_self)
      simp [List.getD_eq_getElem?_getD, this]
    have ih := clrL_count m is (X.set i (.int 0)) hnd' (by
      intro j hj; simpa using hlt j (List.mem_cons_of_mem _ hj))
    have hmap : is.map (fun j => (X.set i (.int 0)).getD j (.int 0))
        = is.map (fun j => X.getD j (.int 0)) := by
      apply List.map_congr_left
      intro j hj
      exact getD_set_ne X i j _ (fun e => hi (e ▸ hj))
    rw [hmap] at ih
    have hs := count_set X i (.int 0) (X.getD i (.int 0)) (.ref m) hX
    simp only [clrL, List.map_cons, List.count_cons]
    by_cases hv : X.getD i (.int 0) = .ref m
    · simp [hv] at hs ih ⊢
      omega
    · simp [hv] at hs ih ⊢
      omega

end Orin
