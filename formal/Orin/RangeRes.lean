import Orin.RangeXfer

/-!
# Interval analysis: the defined local (rule R2)

`res_dd`: an instruction that executes is never judged "always traps" (the dead flag of `arith`).
`res_ok`: the interval `resOf` computes for the local an instruction defines describes the value it
gets (scalars: `Mem`; references: a counted reference to an array whose length is in the interval).
One case of the proof per instruction of `compiler/verify/range.or`.
-/

namespace Orin
namespace Range

variable {cls : List Cls} {iv : List Iv} {s s' : CS}

theorem clsOf_ref_lt {x : Nat} (h : clsOf cls x = .ref) : x < cls.length := by
  refine Decidable.byContradiction fun hc => ?_
  unfold clsOf at h
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)] at h
  simp at h

theorem put_ctd_same (s : CS) (d : Nat) (w : Val) (c : Bool) : (s.put d w c).ctd d = c := by
  simp [CS.put]

theorem put_get_same (s : CS) {d : Nat} (hd : d < s.loc.length) (w : Val) (c : Bool) :
    (s.put d w c).get d = w := get_of_loc (put_loc_same s hd w c)

theorem vok_scalar {c : Cls} {w : Val} (h : VOk c w) (hc : c ≠ .ref) :
    ∃ n, w = .int n ∧ c.okv n := by
  cases w with
  | int n =>
    rcases h with h | h
    · exact absurd h hc
    · exact ⟨n, rfl, h⟩
  | ref l => exact absurd h hc

theorem mem_top (n : Int) : Mem n ⟨NEG, BIG⟩ := mem_unk n

theorem arith_dd (c : Cls) (sub : Bool) (x y : Opd) {vx vy : Int}
    (hmx : Mem vx ⟨opLo iv x, opHi iv x⟩) (hmy : Mem vy ⟨opLo iv y, opHi iv y⟩)
    (hok : sub = true → c.okv (vx - vy)) : (arith cls iv c sub x y).2.2 = false := by
  unfold arith
  split
  · cases sub
    · simp
    · have hm := r2_sub hmx hmy
      have hok' := hok rfl
      simp only [Bool.not_true, Bool.false_eq_true, if_false]
      split
      · rename_i hu
        rw [hu] at hok'
        simp only [Cls.okv] at hok'
        simp only [decide_eq_false_iff_not]
        intro hlt
        generalize subHi (opHi iv x) (opLo iv y) = rh at hm hlt
        unfold Mem at hm
        simp only at hm
        unfold BIG at hm
        omega
      · rfl
  · rfl

/-- `ResOK`: the defined local `d` of `ins` holds, in `s'`, a value described by `resOf` -/
def ResOK (cls : List Cls) (iv : List Iv) (ins : RI) (s' : CS) (d : Nat) : Prop :=
  (clsOf cls d ≠ .ref → ∃ n, s'.get d = .int n ∧ (clsOf cls d).okv n ∧
    Mem n ⟨(resOf cls iv ins).1, (resOf cls iv ins).2.1⟩) ∧
  (clsOf cls d = .ref → 0 ≤ (resOf cls iv ins).1 →
    ∃ l n, s'.loc[d]? = some (.ref l) ∧ s'.len l = some n ∧
      Mem (n : Int) ⟨(resOf cls iv ins).1, (resOf cls iv ins).2.1⟩ ∧ s'.ctd d = true)

/-- R2, the path that always traps is never taken -/
theorem res_dd (hS : SoundS cls iv s) (hE : Exec cls ins s s') : (resOf cls iv ins).2.2 = false := by
  cases hE with
  | sub hd hcd hx hy hok =>
    simp only [resOf]
    rw [if_pos hcd]
    exact arith_dd _ _ _ _ (mem_opd hS hx) (mem_opd hS hy) (fun _ => hok)
  | add hd hcd hx hy hok =>
    simp only [resOf]
    rw [if_pos hcd]
    exact arith_dd _ _ _ _ (mem_opd hS hx) (mem_opd hS hy) (fun h => by cases h)
  | _ => first | rfl | (simp only [resOf]; split <;> rfl)

theorem arith_add_mem (c : Cls) (x y : Opd) {vx vy : Int}
    (hmx : Mem vx ⟨opLo iv x, opHi iv x⟩) (hmy : Mem vy ⟨opLo iv y, opHi iv y⟩) :
    Mem (vx + vy) ⟨(arith cls iv c false x y).1, (arith cls iv c false x y).2.1⟩ := by
  unfold arith
  by_cases hc : opCls cls x = c ∧ opCls cls y = c
  · simp only [hc, and_self, if_true, Bool.not_false]
    exact r2_add hmx hmy
  · simp only [hc, if_false]
    exact mem_unk _

theorem arith_sub_mem (c : Cls) (x y : Opd) {vx vy : Int}
    (hmx : Mem vx ⟨opLo iv x, opHi iv x⟩) (hmy : Mem vy ⟨opLo iv y, opHi iv y⟩)
    (hok : c = .usize → 0 ≤ vx - vy) :
    Mem (vx - vy) ⟨(arith cls iv c true x y).1, (arith cls iv c true x y).2.1⟩ := by
  unfold arith
  by_cases hc : opCls cls x = c ∧ opCls cls y = c
  · have hm := r2_sub hmx hmy
    simp only [hc, and_self, if_true, Bool.not_true, Bool.false_eq_true, if_false]
    split
    · rename_i hu
      have h0 := hok hu
      generalize subLo (opLo iv x) (opHi iv y) = rl at hm ⊢
      generalize subHi (opHi iv x) (opLo iv y) = rh at hm ⊢
      unfold Mem at hm ⊢
      simp only at hm ⊢
      unfold NEG BIG at *
      split <;> omega
    · exact hm
  · simp only [hc, if_false]
    exact mem_unk _

theorem res_ok (hS : SoundS cls iv s) (hE : Exec cls ins s s') {d : Nat}
    (hd : ins.dst = some d) (hdl : d < cls.length) : ResOK cls iv ins s' d := by
  have hlen := hS.lenloc
  cases hE with
  | copy hd' hc he hok =>
    rename_i d0 o v
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    refine ⟨fun _ => ⟨v, put_get_same s hd' _ _, hok, mem_opd hS he⟩, fun h => absurd h hc⟩
  | move hd' hx hne hcd hcx =>
    rename_i d0 x
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    refine ⟨fun h => absurd hcd h, fun _ hlo => ?_⟩
    obtain ⟨l, n, hl, hn, hm, hc⟩ := hS.fact x ⟨hcx, hlo⟩
    refine ⟨l, n, ?_, hn, hm, ?_⟩
    · show ((s.put d0 (s.get x) (s.ctd x)).put x (.int 0) false).loc[d0]? = _
      rw [put_loc_ne _ hne, put_loc_same s hd', get_of_loc hl]
    · show ((s.put d0 (s.get x) (s.ctd x)).put x (.int 0) false).ctd d0 = true
      rw [put_ctd_ne _ hne, put_ctd_same]; exact hc
  | forward hd' hcd hcx hsx hok =>
    rename_i d0 x o v
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    exact ⟨fun _ => ⟨v, put_get_same s hd' _ _, hok, mem_loc hS hcx hsx⟩, fun h => absurd h hcd⟩
  | arrayNew hd' hcd hl =>
    rename_i d0 k l
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    refine ⟨fun h => absurd hcd h, fun _ _ => ⟨l, k, ?_, ?_, ?_, ?_⟩⟩
    · show (s.loc.set d0 (.ref l))[d0]? = _
      simp [hd']
    · show (if l = l then some k else s.len l) = some k
      simp
    · show Mem (k : Int) ⟨(k : Int), (k : Int)⟩
      exact ⟨Or.inr (Int.le_refl _), Or.inr (Int.le_refl _)⟩
    · show (if d0 = d0 then true else s.ctd d0) = true
      simp
  | arrLen hd' hcd hca hga hln hok =>
    rename_i d0 a l n
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    refine ⟨fun _ => ⟨n, put_get_same s hd' _ _, hok, ?_⟩, fun h => absurd h hcd⟩
    simp only [resOf]
    split
    · rename_i hk
      obtain ⟨l1, n1, hl1, hn1, hm1, _⟩ := hS.fact a hk
      have := get_of_loc hl1
      rw [hga] at this
      cases this
      rw [hln] at hn1
      cases hn1
      exact hm1
    · show Mem (n : Int) ⟨0, BIG⟩
      unfold Mem BIG NEG
      simp only
      omega
  | add hd' hcd hx hy hok =>
    rename_i d0 x y vx vy
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    have hcn : clsOf cls d0 ≠ .ref := by rcases hcd with h | h <;> rw [h] <;> intro e <;> cases e
    refine ⟨fun _ => ⟨vx + vy, put_get_same s hd' _ _, hok, ?_⟩, fun h => absurd h hcn⟩
    simp only [resOf]
    rw [if_pos hcd]
    exact arith_add_mem _ x y (mem_opd hS hx) (mem_opd hS hy)
  | sub hd' hcd hx hy hok =>
    rename_i d0 x y vx vy
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    have hcn : clsOf cls d0 ≠ .ref := by rcases hcd with h | h <;> rw [h] <;> intro e <;> cases e
    refine ⟨fun _ => ⟨vx - vy, put_get_same s hd' _ _, hok, ?_⟩, fun h => absurd h hcn⟩
    simp only [resOf]
    rw [if_pos hcd]
    exact arith_sub_mem _ x y (mem_opd hS hx) (mem_opd hS hy) (fun hu => by
      have hok' := hok
      rw [hu] at hok'
      exact hok')
  | cmp hd' hcd hx hy =>
    rename_i d0 op x y vx vy
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    have hcn : clsOf cls d0 ≠ .ref := by rw [hcd]; intro e; cases e
    refine ⟨fun _ => ⟨_, put_get_same s hd' _ _, ?_, mem_top _⟩, fun h => absurd h hcn⟩
    rw [hcd]
    show (if op.eval vx vy = true then (1 : Int) else 0) = 0 ∨ (if op.eval vx vy = true then (1 : Int) else 0) = 1
    split <;> simp
  | get hd' hca hga hln hi h0 hlt hw =>
    rename_i d0 a l n i iv0 w
    simp only [RI.dst, Option.some.injEq] at hd
    subst hd
    refine ⟨fun hc => ?_, fun _ hlo => ?_⟩
    · obtain ⟨n1, hn1, hok⟩ := vok_scalar hw hc
      exact ⟨n1, by rw [put_get_same s hd', hn1], hok, mem_top _⟩
    · exact absurd hlo (by simp only [resOf]; unfold NEG; omega)
  | gen hwf hok =>
    rename_i dst men kept recv
    have hd2 : dst = some d := hd
    subst hd2
    have hv := hok.vok d (by rw [hlen]; exact hdl) (Or.inl rfl)
    refine ⟨fun hc => ?_, fun _ hlo => ?_⟩
    · obtain ⟨n1, hn1, hok⟩ := vok_scalar hv hc
      exact ⟨n1, hn1, hok, mem_top _⟩
    · exact absurd hlo (by simp only [resOf]; unfold NEG; omega)
  | _ => simp [RI.dst] at hd

end Range
end Orin
