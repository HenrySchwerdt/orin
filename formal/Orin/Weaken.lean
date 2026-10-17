import Orin.Sim7

/-!
# Weakening of abstract states and the join

`Fle a b` : `b` is a weakening of `a` (the order of the join semilattice, plus the side condition
that `Borrowed` aliases of `b` are rooted at root kinds).  The relation `Inv` is monotone
(`Inv.weaken`), and the join of the checker is an upper bound of both arguments (`joinL_fle_left`,
`joinL_fle_right`).
-/

namespace Orin
open Heap

variable {ext : List Val} {a b : List AS} {s : St}

def Fle (a b : List AS) : Prop :=
  a.length = b.length ∧ (∀ i, AS.le (gk a i) (gk b i)) ∧
  (∀ i r, gk b i = .borrowed r → (gk b r).isRoot = true)

/-! ### counting under zeroing -/

theorem count_mapIdx_le (x : Val) (hx : x ≠ .int 0) :
    ∀ (ls : List Val) (f g : Nat → Val → Val), (∀ i v, f i v = g i v ∨ f i v = .int 0) →
      (ls.mapIdx f).count x ≤ (ls.mapIdx g).count x := by
  intro ls
  induction ls with
  | nil => intro f g _; simp
  | cons v ls ih =>
    intro f g h
    rw [List.mapIdx_cons, List.mapIdx_cons, List.count_cons, List.count_cons]
    have := ih (fun i => f (i + 1)) (fun i => g (i + 1)) (fun i v => h (i + 1) v)
    rcases h 0 v with e | e
    · rw [e]; omega
    · rw [e]
      have h0 : ¬ ((Val.int 0 == x) = true) := by rw [beq_iff_eq]; exact Ne.symm hx
      rw [if_neg h0]
      split <;> omega

theorem mem_mapIdx_zero :
    ∀ (ls : List Val) (f g : Nat → Val → Val), (∀ i v, f i v = g i v ∨ f i v = .int 0) →
      ∀ y ∈ ls.mapIdx f, y ∈ ls.mapIdx g ∨ y = .int 0 := by
  intro ls
  induction ls with
  | nil => intro f g _ y hy; simp at hy
  | cons v ls ih =>
    intro f g h y hy
    rw [List.mapIdx_cons] at hy ⊢
    rcases List.mem_cons.mp hy with e | e
    · rcases h 0 v with e2 | e2
      · left; rw [e, e2]; exact List.mem_cons_self
      · right; rw [e, e2]
    · rcases ih (fun i => f (i + 1)) (fun i => g (i + 1)) (fun i v => h (i + 1) v) y e with e2 | e2
      · left; exact List.mem_cons_of_mem _ e2
      · right; exact e2

theorem le_pv (hle : ∀ i, AS.le (gk a i) (gk b i)) (i : Nat) (v : Val) :
    pv (gk b i) v = pv (gk a i) v ∨ pv (gk b i) v = .int 0 := by
  rcases hle i with e | e | ⟨e1, e2⟩
  · left; rw [e]
  · right; rw [e]; simp [pv, AS.counted]
  · left; rw [e1, e2]; simp [pv, AS.counted]

theorem Inv.weaken (hI : Inv ext a s) (hF : Fle a b) : Inv ext b s := by
  obtain ⟨hlen, hle, hroot⟩ := hF
  refine ⟨hlen ▸ hI.len, ?_, fun i => ?_⟩
  · have := wf_locals (Pst ext a s) hI.wf (projL b s.locals ++ ext)
      (by
        intro m
        rw [List.count_append]
        have h1 := count_mapIdx_le (.ref m) (by simp) s.locals
          (fun i v => pv (gk b i) v) (fun i v => pv (gk a i) v) (le_pv hle)
        simp only [Pst, projL, List.count_append]
        exact Nat.add_le_add_right h1 _)
      (by
        intro v hv
        simp only [Pst, List.mem_append] at hv ⊢
        rcases hv with hv | hv
        · rcases mem_mapIdx_zero s.locals (fun i v => pv (gk b i) v) (fun i v => pv (gk a i) v)
            (le_pv hle) v hv with h2 | h2
          · exact hI.wf.locs v (by simp only [Pst, List.mem_append]; exact Or.inl h2)
          · subst h2; trivial
        · exact hI.wf.locs v (by simp only [Pst, List.mem_append]; exact Or.inr hv))
    simpa [Pst] using this
  · have hc := hI.cl i
    have hle' := hle i
    refine ⟨?_, ?_, ?_, ?_, ?_⟩
    · intro h
      rcases hle' with e | e | ⟨e1, e2⟩
      · exact hc.ini (by rw [e]; exact h)
      · rw [e] at h; cases h
      · rw [e2] at h; cases h
    · intro h
      rcases hle' with e | e | ⟨e1, e2⟩
      · exact hc.uniq (by rw [e]; exact h)
      · rw [e] at h; cases h
      · rw [e2] at h; cases h
    · intro h
      rcases hle' with e | e | ⟨e1, e2⟩
      · exact hc.prm (by rw [e]; exact h)
      · rw [e] at h; cases h
      · rw [e2] at h; cases h
    · intro r h
      rcases hle' with e | e | ⟨e1, e2⟩
      · have ha : gk a i = .borrowed r := by rw [e]; exact h
        obtain ⟨_, p, hp, hd, hcl⟩ := hc.bor r ha
        refine ⟨hroot i r h, p, hp, hd, fun hu => ?_⟩
        apply hcl
        rcases hle r with e3 | e3 | ⟨e4, e5⟩
        · rw [e3]; exact hu
        · rw [e3] at hu; cases hu
        · rw [e5] at hu; cases hu
      · rw [e] at h; cases h
      · rw [e2] at h; cases h
    · intro h
      rcases hle' with e | e | ⟨e1, e2⟩
      · exact hc.ref (by rw [e]; exact h)
      · rw [e] at h; simp [AS.isRef] at h
      · exact hc.ref (by rw [e1]; rfl)

/-! ### the join -/

theorem gk_zipWith_jk (a1 a2 : List AS) (h : a1.length = a2.length) (i : Nat) :
    gk (List.zipWith jk a1 a2) i = jk (gk a1 i) (gk a2 i) := by
  by_cases hi : i < a1.length
  · have hi2 : i < a2.length := h ▸ hi
    simp [gk, List.getD_eq_getElem?_getD, List.getElem?_zipWith, hi, hi2]
  · have hi2 : ¬ i < a2.length := h ▸ hi
    simp [gk, List.getD_eq_getElem?_getD, List.getElem?_zipWith,
      List.getElem?_eq_none (by omega : a1.length ≤ i),
      List.getElem?_eq_none (by omega : a2.length ≤ i), jk]

theorem gk_map_postK (j : List AS) (i : Nat) :
    gk (j.map (postK j)) i = postK j (gk j i) := by
  by_cases hi : i < j.length
  · simp [gk, hi]
  · simp [gk, hi, List.getD_eq_getElem?_getD, postK]

theorem gk_joinL (a1 a2 : List AS) (h : a1.length = a2.length) (i : Nat) :
    gk (joinL a1 a2) i = postK (List.zipWith jk a1 a2) (jk (gk a1 i) (gk a2 i)) := by
  unfold joinL
  rw [gk_map_postK, gk_zipWith_jk _ _ h]

theorem postK_cases (j : List AS) (k : AS) : postK j k = k ∨ postK j k = .poison := by
  cases k <;> simp [postK] <;> split <;> simp

theorem postK_nb (j : List AS) (k : AS) (h : ∀ r, k ≠ .borrowed r) : postK j k = k := by
  cases k <;> simp [postK]
  rename_i r
  exact absurd rfl (h r)

theorem jk_comm (k1 k2 : AS) : jk k1 k2 = jk k2 k1 := by
  unfold jk
  by_cases h : k1 = k2
  · subst h; simp
  · have h' : ¬ k2 = k1 := fun e => h e.symm
    simp [h, h', Bool.and_comm]

theorem le_post_jk (j : List AS) (k1 k2 : AS) : AS.le k1 (postK j (jk k1 k2)) := by
  unfold jk
  by_cases h : k1 = k2
  · simp only [h, ite_true]
    rcases postK_cases j k2 with e | e
    · left; rw [e]
    · right; left; exact e
  · by_cases hc : k1.counted && k2.counted
    · simp only [h, hc, ite_true, ite_false]
      rw [postK_nb j .owned (by intro r; simp)]
      have h1 : k1.counted = true := by simpa using (Bool.and_eq_true_iff.mp hc).1
      cases k1 <;> simp [AS.counted] at h1 <;> simp [AS.le]
    · simp only [h, hc, ite_false, Bool.false_eq_true]
      rw [postK_nb j .poison (by intro r; simp)]
      right; left; rfl

theorem postK_borrowed (j : List AS) (k : AS) (r : Nat) (h : postK j k = .borrowed r) :
    k = .borrowed r ∧ (gk j r).isRoot = true := by
  cases k <;> simp [postK] at h
  rename_i r'
  split at h
  · rename_i hr
    injection h with h; subst h
    exact ⟨rfl, hr⟩
  · cases h

theorem joinL_borrowed_root (a1 a2 : List AS) (h : a1.length = a2.length) :
    ∀ i r, gk (joinL a1 a2) i = .borrowed r → (gk (joinL a1 a2) r).isRoot = true := by
  intro i r hb
  rw [gk_joinL _ _ h] at hb
  obtain ⟨_, hroot⟩ := postK_borrowed _ _ _ hb
  rw [gk_zipWith_jk _ _ h] at hroot
  rw [gk_joinL _ _ h, postK_nb _ _ ?_]
  · exact hroot
  · intro r' e
    rw [e] at hroot; simp [AS.isRoot] at hroot

theorem AS.le_trans {k1 k2 k3 : AS} (h1 : AS.le k1 k2) (h2 : AS.le k2 k3) : AS.le k1 k3 := by
  unfold AS.le at *
  rcases h1 with h1 | h1 | ⟨h1, h1'⟩ <;> rcases h2 with h2 | h2 | ⟨h2, h2'⟩ <;>
    first
    | (subst_vars; simp_all; done)
    | (exfalso; simp_all; done)
    | simp_all

theorem Fle.trans {a b c : List AS} (h1 : Fle a b) (h2 : Fle b c) : Fle a c :=
  ⟨h1.1.trans h2.1, fun i => AS.le_trans (h1.2.1 i) (h2.2.1 i), h2.2.2⟩

theorem joinL_fle_left (a1 a2 : List AS) (h : a1.length = a2.length) :
    Fle a1 (joinL a1 a2) := by
  have hlen : (joinL a1 a2).length = a1.length := by simp [joinL]; omega
  refine ⟨hlen.symm, fun i => ?_, joinL_borrowed_root a1 a2 h⟩
  rw [gk_joinL _ _ h]; exact le_post_jk _ _ _

theorem joinL_fle_right (a1 a2 : List AS) (h : a1.length = a2.length) :
    Fle a2 (joinL a1 a2) := by
  have hlen : (joinL a1 a2).length = a2.length := by simp [joinL]; omega
  refine ⟨hlen.symm, fun i => ?_, joinL_borrowed_root a1 a2 h⟩
  rw [gk_joinL _ _ h, jk_comm]; exact le_post_jk _ _ _

end Orin
