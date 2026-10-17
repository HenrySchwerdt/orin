import Orin.RangeStepSound

/-!
# Interval analysis: branch refinement (rule R3) and the edge of a block

`capHi` / `raiseLo` / `less` / `atMost` / `same` / `refine` of `range.or` are sound: when the
recorded comparison has the truth value an execution takes, the refined state still describes the
concrete frame and is not dead.  `edgeIv` is `RStep.edge`: the exit state along edge `k` of the
terminator (`none` when no execution takes the edge); `edge_sound` is the lemma the fixpoint needs:
every edge a concrete execution takes is live and its exit state describes the frame.  `runA_sound`
chains `step_sound` through a block.
-/

namespace Orin
namespace Range

variable {cls : List Cls} {s s' : CS}

/-- the state is live and describes the frame -/
def Live (cls : List Cls) (rs : RS) (s : CS) : Prop := rs.dead = false ∧ SoundS cls rs.iv s

theorem soundS_set_scalar {iv : List Iv} {l : Nat} {x : Iv} (hS : SoundS cls iv s)
    (hc : clsOf cls l ≠ .ref) (hx : ∀ n, s.loc[l]? = some (.int n) → Mem n x) :
    SoundS cls (iv.set l x) s := by
  by_cases hl : l < iv.length
  · refine ⟨by simp [hS.leniv], hS.lenloc, fun y hy hcy => ?_, fun y hk => ?_⟩
    · by_cases hyl : y = l
      · subst hyl
        obtain ⟨n, hn, hok, _⟩ := hS.scal y hy hc
        exact ⟨n, hn, hok, by rw [gi_set_same hl]; exact hx n hn⟩
      · obtain ⟨n, hn, hok, hm⟩ := hS.scal y hy hcy
        exact ⟨n, hn, hok, by rw [gi_set_ne hyl]; exact hm⟩
    · obtain ⟨hcy, h0⟩ := hk
      have hyl : y ≠ l := fun e => hc (e ▸ hcy)
      rw [gi_set_ne hyl] at h0
      obtain ⟨l1, n, h1, h2, h3, h4⟩ := hS.fact y ⟨hcy, h0⟩
      exact ⟨l1, n, h1, h2, by rw [gi_set_ne hyl]; exact h3, h4⟩
  · rw [List.set_eq_of_length_le (by omega)]
    exact hS

theorem evalOpd_loc {l : Nat} {v : Int} (h : evalOpd cls s (.loc l) = some v) :
    clsOf cls l ≠ .ref ∧ s.get l = .int v := by
  simp only [evalOpd] at h
  split at h
  · cases h
  · rename_i hc
    split at h
    · rename_i n hn
      cases h
      exact ⟨hc, hn⟩
    · cases h

theorem capHi_sound {rs : RS} {o : Opd} {v w : Int} (hL : Live cls rs s)
    (hv : evalOpd cls s o = some v) (hle : v ≤ w) : Live cls (capHi rs o w) s := by
  obtain ⟨hd, hS⟩ := hL
  cases o with
  | cint n => exact ⟨hd, hS⟩
  | cusize n => exact ⟨hd, hS⟩
  | loc l =>
    obtain ⟨hc, hg⟩ := evalOpd_loc hv
    have hm := mem_loc hS hc hg
    unfold capHi
    dsimp only
    by_cases hlt : (if w < NEG then NEG else w) < (gi rs.iv l).hi
    · rw [if_pos hlt]
      refine ⟨?_, soundS_set_scalar hS hc ?_⟩
      · rw [hd]
        simp only [Bool.false_or, decide_eq_false_iff_not]
        obtain ⟨h1, h2⟩ := hm
        unfold NEG at *
        split <;> omega
      · intro n hn
        have hn' : n = v := by
          have := get_of_loc hn
          rw [hg] at this
          cases this; rfl
        subst hn'
        obtain ⟨h1, h2⟩ := hm
        refine ⟨h1, Or.inr ?_⟩
        dsimp only
        unfold NEG
        split <;> omega
    · rw [if_neg hlt]
      exact ⟨hd, hS⟩

theorem raiseLo_sound {rs : RS} {o : Opd} {v w : Int} (hL : Live cls rs s)
    (hv : evalOpd cls s o = some v) (hle : w ≤ v) : Live cls (raiseLo rs o w) s := by
  obtain ⟨hd, hS⟩ := hL
  cases o with
  | cint n => exact ⟨hd, hS⟩
  | cusize n => exact ⟨hd, hS⟩
  | loc l =>
    obtain ⟨hc, hg⟩ := evalOpd_loc hv
    have hm := mem_loc hS hc hg
    unfold raiseLo
    dsimp only
    by_cases hlt : (if w > BIG then BIG else w) > (gi rs.iv l).lo
    · rw [if_pos hlt]
      refine ⟨?_, soundS_set_scalar hS hc ?_⟩
      · rw [hd]
        simp only [Bool.false_or, decide_eq_false_iff_not]
        obtain ⟨h1, h2⟩ := hm
        unfold BIG at *
        split <;> omega
      · intro n hn
        have hn' : n = v := by
          have := get_of_loc hn
          rw [hg] at this
          cases this; rfl
        subst hn'
        obtain ⟨h1, h2⟩ := hm
        refine ⟨Or.inr ?_, h2⟩
        dsimp only
        unfold BIG
        split <;> omega
    · rw [if_neg hlt]
      exact ⟨hd, hS⟩

/-- an operand's value is in the interval the state gives it -/
theorem opd_bounds {rs : RS} {o : Opd} {v : Int} (hS : SoundS cls rs.iv s)
    (hv : evalOpd cls s o = some v) :
    (opLo rs.iv o > NEG → opLo rs.iv o ≤ v) ∧ (opHi rs.iv o < BIG → v ≤ opHi rs.iv o) := by
  have hm := mem_opd hS hv
  obtain ⟨h1, h2⟩ := hm
  simp only at h1 h2
  unfold NEG BIG at *
  omega

theorem less_sound {rs : RS} {a b : Opd} {va vb : Int} (hL : Live cls rs s)
    (ha : evalOpd cls s a = some va) (hb : evalOpd cls s b = some vb) (hlt : va < vb) :
    Live cls (less rs a b) s := by
  have hbd := opd_bounds (o := a) hL.2 ha
  have hbd2 := opd_bounds (o := b) hL.2 hb
  unfold less
  dsimp only
  have h1 : Live cls (if opHi rs.iv b < BIG then capHi rs a (opHi rs.iv b - 1) else rs) s := by
    split
    · rename_i hh
      exact capHi_sound hL ha (by have := hbd2.2 hh; omega)
    · exact hL
  split
  · rename_i hh
    exact raiseLo_sound h1 hb (by have := hbd.1 hh; omega)
  · exact h1

theorem atMost_sound {rs : RS} {a b : Opd} {va vb : Int} (hL : Live cls rs s)
    (ha : evalOpd cls s a = some va) (hb : evalOpd cls s b = some vb) (hle : va ≤ vb) :
    Live cls (atMost rs a b) s := by
  have hbd := opd_bounds (o := a) hL.2 ha
  have hbd2 := opd_bounds (o := b) hL.2 hb
  unfold atMost
  dsimp only
  have h1 : Live cls (if opHi rs.iv b < BIG then capHi rs a (opHi rs.iv b) else rs) s := by
    split
    · rename_i hh
      exact capHi_sound hL ha (by have := hbd2.2 hh; omega)
    · exact hL
  split
  · rename_i hh
    exact raiseLo_sound h1 hb (by have := hbd.1 hh; omega)
  · exact h1

theorem same_sound {rs : RS} {a b : Opd} {va vb : Int} (hL : Live cls rs s)
    (ha : evalOpd cls s a = some va) (hb : evalOpd cls s b = some vb) (he : va = vb) :
    Live cls (same rs a b) s :=
  atMost_sound (atMost_sound hL ha hb (by omega)) hb ha (by omega)

/-- R3: the recorded comparison has the truth value of the edge -/
theorem refine_sound {rs : RS} {n : Note} {vx vy : Int} {truth : Bool} (hL : Live cls rs s)
    (hx : evalOpd cls s n.x = some vx) (hy : evalOpd cls s n.y = some vy)
    (ht : truth = n.op.eval vx vy) : Live cls (refine rs n truth) s := by
  obtain ⟨c, op, x, y⟩ := n
  dsimp only at hx hy ht
  cases op <;> cases truth
  · -- lt, false
    have h : ¬ vx < vy := by simpa [Cmp.eval] using ht.symm
    exact atMost_sound hL hy hx (by omega)
  · have h : vx < vy := by simpa [Cmp.eval] using ht.symm
    exact less_sound hL hx hy h
  · have h : ¬ vx ≤ vy := by simpa [Cmp.eval] using ht.symm
    exact less_sound hL hy hx (by omega)
  · have h : vx ≤ vy := by simpa [Cmp.eval] using ht.symm
    exact atMost_sound hL hx hy h
  · have h : ¬ vx > vy := by simpa [Cmp.eval] using ht.symm
    exact atMost_sound hL hx hy (by omega)
  · have h : vx > vy := by simpa [Cmp.eval] using ht.symm
    exact less_sound hL hy hx h
  · have h : ¬ vx ≥ vy := by simpa [Cmp.eval] using ht.symm
    exact less_sound hL hx hy (by omega)
  · have h : vx ≥ vy := by simpa [Cmp.eval] using ht.symm
    exact atMost_sound hL hy hx h
  · exact hL
  · have h : vx = vy := by simpa [Cmp.eval] using ht.symm
    exact same_sound hL hx hy h
  · have h : ¬ vx ≠ vy := by simpa [Cmp.eval] using ht.symm
    exact same_sound hL hx hy (by omega)
  · exact hL

/-! ### lengths -/

theorem capHi_len (rs : RS) (o : Opd) (w : Int) : (capHi rs o w).iv.length = rs.iv.length := by
  unfold capHi
  cases o <;> simp only
  repeat' split
  all_goals first | rfl | simp

theorem raiseLo_len (rs : RS) (o : Opd) (w : Int) : (raiseLo rs o w).iv.length = rs.iv.length := by
  unfold raiseLo
  cases o <;> simp only
  repeat' split
  all_goals first | rfl | simp

theorem less_len (rs : RS) (a b : Opd) : (less rs a b).iv.length = rs.iv.length := by
  unfold less
  dsimp only
  split
  · rw [raiseLo_len]; split <;> simp [capHi_len]
  · split <;> simp [capHi_len]

theorem atMost_len (rs : RS) (a b : Opd) : (atMost rs a b).iv.length = rs.iv.length := by
  unfold atMost
  dsimp only
  split
  · rw [raiseLo_len]; split <;> simp [capHi_len]
  · split <;> simp [capHi_len]

theorem same_len (rs : RS) (a b : Opd) : (same rs a b).iv.length = rs.iv.length := by
  unfold same; rw [atMost_len, atMost_len]

theorem refine_len (rs : RS) (n : Note) (t : Bool) : (refine rs n t).iv.length = rs.iv.length := by
  unfold refine
  split <;> simp [less_len, atMost_len, same_len]

theorem step_len (cls : List Cls) (ins : RI) (rs : RS) : (step cls ins rs).iv.length = rs.iv.length := by
  unfold step
  split
  · rfl
  · generalize resOf cls rs.iv ins = r
    obtain ⟨rl, rh, dd⟩ := r
    dsimp only
    split
    · rfl
    · exact length_ivOut cls ins rs.iv rl rh

theorem runA_len (cls : List Cls) (is : List RI) (rs : RS) : (runA cls is rs).iv.length = rs.iv.length := by
  induction is generalizing rs with
  | nil => rfl
  | cons i is ih => simp only [runA]; rw [ih, step_len]

/-! ### blocks and edges -/

/-- terminators: return, jump, two-way branch on a bool local (edge 0: true), any other (switch ...) -/
inductive Term where
  | ret
  | jmp (t : Nat)
  | br (c : Nat) (t f : Nat)
  | other (ss : List Nat)

/-- the successors, in edge order (`succAt`) -/
def Term.succs : Term → List Nat
  | .ret => []
  | .jmp t => [t]
  | .br _ t f => [t, f]
  | .other ss => ss

/-- the state refined by the recorded comparison along edge `k` of a branch on the bool local `c` -/
def edgeRS (t : Term) (k : Nat) (rs : RS) : RS :=
  match t, rs.note with
  | .br c _ _, some n => if n.c = c then refine rs n (decide (k = 0)) else rs
  | _, _ => rs

/-- `RStep.edge`: the exit state along edge `k`, or `none` when no execution takes the edge -/
def edgeIv (t : Term) (k : Nat) (rs : RS) : Option (List Iv) :=
  if rs.dead then none else
  if (edgeRS t k rs).dead then none else some (edgeRS t k rs).iv

theorem edgeRS_len (t : Term) (k : Nat) (rs : RS) : (edgeRS t k rs).iv.length = rs.iv.length := by
  unfold edgeRS
  split
  · split
    · exact refine_len _ _ _
    · rfl
  · rfl

theorem edgeIv_len {t : Term} {k : Nat} {rs : RS} {e : List Iv} (h : edgeIv t k rs = some e) :
    e.length = rs.iv.length := by
  unfold edgeIv at h
  split at h
  · cases h
  · split at h
    · cases h
    · cases h
      exact edgeRS_len t k rs

/-- the concrete edge a frame takes at the end of a block -/
inductive Taken : Term → CS → Nat → Prop
  | jmp {t : Nat} {s : CS} : Taken (.jmp t) s 0
  | brT {c t f : Nat} {s : CS} {v : Int} : s.get c = .int v → v ≠ 0 → Taken (.br c t f) s 0
  | brF {c t f : Nat} {s : CS} : s.get c = .int 0 → Taken (.br c t f) s 1
  | other {ss : List Nat} {s : CS} {k : Nat} : k < ss.length → Taken (.other ss) s k

theorem edgeRS_live {rs : RS} {t : Term} {k : Nat} (hR : RunSound cls rs s) (hT : Taken t s k) :
    Live cls (edgeRS t k rs) s := by
  obtain ⟨hd, hS, hno⟩ := hR
  have base : Live cls rs s := ⟨hd, hS⟩
  cases hT with
  | jmp => exact base
  | other _ => exact base
  | brT hg hv =>
    rename_i c t f v
    unfold edgeRS
    cases hnote : rs.note with
    | none => exact base
    | some n =>
      dsimp only
      by_cases hc : n.c = c
      · rw [if_pos hc]
        rw [hnote] at hno
        obtain ⟨_, _, _, vx, vy, hx, hy, hcv⟩ := hno
        rw [hc, hg] at hcv
        have hv1 : (if n.op.eval vx vy = true then (1 : Int) else 0) = v := (Val.int.inj hcv).symm
        have htr : n.op.eval vx vy = true := by
          by_cases h : n.op.eval vx vy = true
          · exact h
          · rw [if_neg h] at hv1; exact absurd hv1.symm hv
        exact refine_sound base hx hy (by simp [htr])
      · rw [if_neg hc]; exact base
  | brF hg =>
    rename_i c t f
    unfold edgeRS
    cases hnote : rs.note with
    | none => exact base
    | some n =>
      dsimp only
      by_cases hc : n.c = c
      · rw [if_pos hc]
        rw [hnote] at hno
        obtain ⟨_, _, _, vx, vy, hx, hy, hcv⟩ := hno
        rw [hc, hg] at hcv
        have hv1 : (if n.op.eval vx vy = true then (1 : Int) else 0) = 0 := (Val.int.inj hcv).symm
        have htr : n.op.eval vx vy = false := by
          by_cases h : n.op.eval vx vy = true
          · rw [if_pos h] at hv1; cases hv1
          · simpa using h
        exact refine_sound base hx hy (by simp [htr])
      · rw [if_neg hc]; exact base

/-- R3 at the edge: every edge the execution takes is live, its exit state describes the frame -/
theorem edge_sound {rs : RS} {t : Term} {k : Nat} (hR : RunSound cls rs s) (hT : Taken t s k) :
    ∃ e, edgeIv t k rs = some e ∧ SoundS cls e s := by
  have hl := edgeRS_live hR hT
  refine ⟨(edgeRS t k rs).iv, ?_, hl.2⟩
  unfold edgeIv
  rw [hR.1, hl.1]
  rfl

/-! ### blocks -/

inductive RunI (cls : List Cls) : List RI → CS → CS → Prop
  | nil {s : CS} : RunI cls [] s s
  | cons {i : RI} {is : List RI} {s s1 s2 : CS} : Exec cls i s s1 → RunI cls is s1 s2 →
      RunI cls (i :: is) s s2

theorem runA_sound {rs : RS} {is : List RI} (hR : RunSound cls rs s) (hr : RunI cls is s s') :
    RunSound cls (runA cls is rs) s' := by
  induction hr generalizing rs with
  | nil => exact hR
  | cons hE _ ih => exact ih (step_sound hR hE)

end Range
end Orin
