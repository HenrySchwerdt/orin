import Orin.RangeSem

/-!
# Interval analysis: soundness of the transfer functions (rule R2) and the fact destruction

`Summ` is what every instruction does to the frame: the locals it does not change keep their
value; a counted array that the instruction does not mention (or keeps) is still a counted
reference to an array of the same length afterwards.  `exec_summ` proves it for each instruction
(for `gen` it is the ownership contract `GenOK`).  `ResOK` says the interval `resOf` computed for
the defined local describes the new value.  `step_sound` assembles them: one step of the abstract
transfer `step` preserves `RunSound`.
-/

namespace Orin
namespace Range

variable {cls : List Cls} {iv : List Iv} {s s' : CS}

theorem mem_loc (hS : SoundS cls iv s) {x : Nat} {v : Int} (hc : clsOf cls x ≠ .ref)
    (hv : s.get x = .int v) : Mem v (gi iv x) := by
  by_cases hx : x < cls.length
  · obtain ⟨n, hn, _, hm⟩ := hS.scal x hx hc
    have := get_of_loc hn
    rw [hv] at this
    cases this
    exact hm
  · rw [gi_out (by rw [hS.leniv]; omega)]
    exact mem_unk v

/-- R2 for operands: a constant or a local describes its value by `opLo`/`opHi` -/
theorem mem_opd (hS : SoundS cls iv s) {o : Opd} {v : Int} (h : evalOpd cls s o = some v) :
    Mem v ⟨opLo iv o, opHi iv o⟩ := by
  cases o with
  | loc l =>
    simp only [evalOpd] at h
    split at h
    · cases h
    · rename_i hc
      split at h
      · rename_i n hn
        cases h
        exact mem_loc hS hc hn
      · cases h
  | cint n =>
    simp only [evalOpd, Option.some.injEq] at h
    subst h
    unfold Mem opLo opHi NEG BIG
    simp only
    split <;> omega
  | cusize n =>
    simp only [evalOpd] at h
    split at h
    · rename_i h0
      simp only [Option.some.injEq] at h
      subst h
      unfold Mem opLo opHi NEG BIG
      simp only
      split <;> omega
    · cases h

/-! ### the frame summary -/

structure Summ (cls : List Cls) (ins : RI) (s s' : CS) : Prop where
  size : s'.loc.length = s.loc.length
  same : ∀ x, ¬ Chg cls ins x → s'.loc[x]? = s.loc[x]?
  vok : ∀ x, x < s.loc.length → (ins.dst = some x ∨ ins.recv = some x) →
    VOk (clsOf cls x) (s'.get x)
  keep : ∀ x l n, (x ∉ ins.men ∨ ins.keeps x = true) → s.loc[x]? = some (.ref l) →
    s.ctd x = true → s.len l = some n →
    ∃ l', s'.loc[x]? = some (.ref l') ∧ s'.len l' = some n ∧ s'.ctd x = true

/-- an instruction that only redefines `d` (with a value of the right class) and nothing else -/
theorem summ_put {ins : RI} {d : Nat} {w : Val} {c : Bool} (s : CS)
    (hdst : ins.dst = some d) (hrecv : ins.recv = none) (hmen : d ∈ ins.men)
    (hkeeps : ∀ x, ins.keeps x = true → x ≠ d) (hd : d < s.loc.length)
    (hw : VOk (clsOf cls d) w) :
    Summ cls ins s (s.put d w c) := by
  refine ⟨put_length _ _ _ _, fun x hx => ?_, fun x hx hxd => ?_, fun x l n hx hl hc hn => ?_⟩
  · have : x ≠ d := fun e => hx (Or.inl (e ▸ hdst))
    rw [put_loc_ne _ this]
  · rcases hxd with h | h
    · have : x = d := (Option.some.inj (hdst.symm.trans h)).symm
      subst this
      rw [get_of_loc (put_loc_same s hd w c)]; exact hw
    · rw [hrecv] at h; cases h
  · have hxd : x ≠ d := by
      rcases hx with h | h
      · intro e; exact h (e ▸ hmen)
      · exact hkeeps x h
    exact ⟨l, by rw [put_loc_ne _ hxd]; exact hl, hn, by rw [put_ctd_ne _ hxd]; exact hc⟩

theorem exec_summ {ins : RI} (hE : Exec cls ins s s') : Summ cls ins s s' := by
  cases hE with
  | copy hd hc he hok =>
    rename_i d o v
    exact summ_put s rfl rfl (by simp [RI.men]) (by intro x hx; simp [RI.keeps] at hx) hd
      (show VOk (clsOf cls d) (.int v) from Or.inr hok)
  | move hd hx hne hcd hcx =>
    rename_i d x
    refine ⟨by simp [put_length], fun y hy => ?_, fun y hy hyd => ?_, fun y l n hy hl hc hn => ?_⟩
    · have h1 : y ≠ d := fun e => hy (Or.inl (by simp [RI.dst, e]))
      have h2 : y ≠ x := fun e =>
        hy (Or.inr (Or.inr (Or.inl ⟨by simp [RI.men, e], by simp [RI.keeps], by rw [e]; exact hcx⟩)))
      rw [put_loc_ne _ h2, put_loc_ne _ h1]
    · rcases hyd with h | h
      · have : y = d := (Option.some.inj h).symm
        subst this
        rw [get_of_loc (by rw [put_loc_ne _ hne, put_loc_same s hd])]
        cases s.get x with
        | int n => exact Or.inl hcd
        | ref l => exact hcd
      · simp [RI.recv] at h
    · have h1 : y ≠ d := by
        rcases hy with h | h
        · intro e; exact h (by simp [RI.men, e])
        · simp [RI.keeps] at h
      have h2 : y ≠ x := by
        rcases hy with h | h
        · intro e; exact h (by simp [RI.men, e])
        · simp [RI.keeps] at h
      refine ⟨l, by rw [put_loc_ne _ h2, put_loc_ne _ h1]; exact hl, hn, ?_⟩
      rw [put_ctd_ne _ h2, put_ctd_ne _ h1]; exact hc
  | forward hd hcd hcx hsx hok =>
    rename_i d x o v
    exact summ_put s rfl rfl (by simp [RI.men]) (by
      intro y hy
      simp only [RI.keeps, Bool.and_eq_true, decide_eq_true_eq] at hy
      exact fun e => hy.1.1 e.symm) hd (show VOk (clsOf cls d) (.int v) from Or.inr hok)
  | arrayNew hd hcd hl =>
    rename_i d k l
    refine ⟨by simp, fun y hy => ?_, fun y hy hyd => ?_, fun y l1 n hy hl1 hc hn => ?_⟩
    · have h1 : y ≠ d := fun e => hy (Or.inl (by simp [RI.dst, e]))
      show (s.loc.set d (.ref l))[y]? = s.loc[y]?
      simp [List.getElem?_set, Ne.symm h1]
    · rcases hyd with h | h
      · have : y = d := (Option.some.inj h).symm
        subst this
        rw [get_of_loc (show (s.loc.set y (Val.ref l))[y]? = some (Val.ref l) by simp [hd])]
        exact hcd
      · simp [RI.recv] at h
    · have h1 : y ≠ d := by
        rcases hy with h | h
        · intro e; exact h (by simp [RI.men, e])
        · simp [RI.keeps] at h
      refine ⟨l1, ?_, ?_, ?_⟩
      · show (s.loc.set d (.ref l))[y]? = some (.ref l1)
        simp [List.getElem?_set, Ne.symm h1, hl1]
      · show (if l1 = l then some k else s.len l1) = some n
        have : l1 ≠ l := by intro e; rw [e, hl] at hn; cases hn
        simp [this, hn]
      · show (if y = d then true else s.ctd y) = true
        simp [h1, hc]
  | arrLen hd hcd hca hga hln hok =>
    rename_i d a l n
    exact summ_put s rfl rfl (by simp [RI.men]) (by
      intro y hy
      simp only [RI.keeps, Bool.and_eq_true, decide_eq_true_eq] at hy
      exact fun e => hy.1 e.symm) hd (show VOk (clsOf cls d) (.int (n : Int)) from Or.inr hok)
  | add hd hcd hx hy hok =>
    rename_i d x y vx vy
    exact summ_put s rfl rfl (by simp [RI.men]) (by intro z hz; simp [RI.keeps] at hz) hd
      (show VOk (clsOf cls d) (.int (vx + vy)) from Or.inr hok)
  | sub hd hcd hx hy hok =>
    rename_i d x y vx vy
    exact summ_put s rfl rfl (by simp [RI.men]) (by intro z hz; simp [RI.keeps] at hz) hd
      (show VOk (clsOf cls d) (.int (vx - vy)) from Or.inr hok)
  | cmp hd hcd hx hy =>
    rename_i d op x y vx vy
    refine summ_put s rfl rfl (by simp [RI.men]) (by intro z hz; simp [RI.keeps] at hz) hd ?_
    show VOk (clsOf cls d) (.int _)
    right
    rw [hcd]
    show (if op.eval vx vy = true then (1 : Int) else 0) = 0 ∨ (if op.eval vx vy = true then (1 : Int) else 0) = 1
    split <;> simp
  | get hd hca hga hln hi h0 hlt hw =>
    rename_i d a l n i iv w
    exact summ_put s rfl rfl (by simp [RI.men]) (by
      intro y hy
      simp only [RI.keeps, Bool.and_eq_true, decide_eq_true_eq] at hy
      exact fun e => hy.1.1 e.symm) hd hw
  | set hca hga hln hi h0 hlt hs =>
    rename_i a l n i iv v
    have key : ∀ (hv : v < s.loc.length) (hcv : clsOf cls v = .ref),
        Summ cls (.set a i v) s (s.put v (.int 0) false) := by
      intro hv hcv
      have hne : ∀ x, (x ∉ (RI.set a i v).men ∨ (RI.set a i v).keeps x = true) → x ≠ v := by
        intro x hx e
        subst e
        have hm : x ∈ (RI.set a i x).men := by simp [RI.men]
        have hk : (RI.set a i x).keeps x = false := by simp [RI.keeps]
        rcases hx with h | h
        · exact h hm
        · rw [hk] at h; cases h
      refine ⟨put_length _ _ _ _, fun x hx => ?_, fun x hx hxd => ?_, fun x l1 n1 hx hl hc hn => ?_⟩
      · have : x ≠ v := by
          intro e
          subst e
          exact hx (Or.inr (Or.inr (Or.inl ⟨by simp [RI.men], by simp [RI.keeps], hcv⟩)))
        rw [put_loc_ne _ this]
      · rcases hxd with h | h <;> simp [RI.dst, RI.recv] at h
      · have := hne x hx
        exact ⟨l1, by rw [put_loc_ne _ this]; exact hl, hn, by rw [put_ctd_ne _ this]; exact hc⟩
    rcases hs with rfl | ⟨hv, hcv, rfl⟩
    · exact ⟨rfl, fun _ _ => rfl, fun x _ hxd => by
        rcases hxd with h | h <;> simp [RI.dst, RI.recv] at h,
        fun x l1 n1 _ hl hc hn => ⟨l1, hl, hn, hc⟩⟩
    · exact key hv hcv
  | makeUnique hca hga hln hs =>
    rename_i a l n
    rcases hs with rfl | ⟨m, ha, hm, rfl⟩
    · exact ⟨rfl, fun _ _ => rfl, fun x _ hxd => by
        rcases hxd with h | h <;> simp [RI.dst, RI.recv] at h,
        fun x l1 n1 _ hl hc hn => ⟨l1, hl, hn, hc⟩⟩
    · refine ⟨by simp, fun x hx => ?_, fun x _ hxd => ?_, fun x l1 n1 hx hl hc hn => ?_⟩
      · have : x ≠ a := fun e => hx (Or.inr (Or.inr (Or.inr (by rw [e]))))
        show (s.loc.set a (.ref m))[x]? = s.loc[x]?
        simp [List.getElem?_set, Ne.symm this]
      · rcases hxd with h | h <;> simp [RI.dst, RI.recv] at h
      · by_cases hxa : x = a
        · subst hxa
          have hl' : l1 = l := by
            have := get_of_loc hl
            rw [hga] at this
            cases this; rfl
          subst hl'
          have : n1 = n := by rw [hn] at hln; exact Option.some.inj hln
          subst this
          refine ⟨m, ?_, ?_, ?_⟩
          · show (s.loc.set x (.ref m))[x]? = some (.ref m)
            simp [ha]
          · show (if m = m then some n1 else s.len m) = some n1
            simp
          · show (if x = x then true else s.ctd x) = true
            simp
        · refine ⟨l1, ?_, ?_, ?_⟩
          · show (s.loc.set a (.ref m))[x]? = some (.ref l1)
            simp [List.getElem?_set, Ne.symm hxa, hl]
          · show (if l1 = m then some n else s.len l1) = some n1
            have : l1 ≠ m := by intro e; rw [e, hm] at hn; cases hn
            simp [this, hn]
          · show (if x = a then true else s.ctd x) = true
            simp [hxa, hc]
  | gen hwf hok =>
    rename_i dst men kept recv
    have hwf' : (∀ x, dst = some x → x ∉ kept) ∧ (∀ x, recv = some x → x ∉ kept ∧ x ∈ men) := hwf
    refine ⟨hok.size, hok.same, fun x hx hxd => hok.vok x hx ?_, fun x l1 n1 hx hl hc hn => ?_⟩
    · rcases hxd with h | h
      · exact Or.inl h
      · exact Or.inr (Or.inl h)
    · have hnc : ¬ Chg cls (.gen dst men kept recv) x := by
        intro hch
        rcases hch with h | h | h | h
        · have h1 := hwf'.1 x h
          rcases hx with h2 | h2
          · exact h2 (by simp only [RI.men, List.mem_append, Option.mem_toList]; exact Or.inl h)
          · simp [RI.keeps] at h2; exact h1 h2
        · have h1 := hwf'.2 x h
          rcases hx with h2 | h2
          · exact h2 (by simp [RI.men, h1.2])
          · simp [RI.keeps] at h2; exact h1.1 h2
        · obtain ⟨h3, h4, _⟩ := h
          rcases hx with h2 | h2
          · exact h2 h3
          · rw [h2] at h4; cases h4
        · cases h
      obtain ⟨a1, a2⟩ := hok.own x l1 n1 hnc hl hc hn
      exact ⟨l1, by rw [hok.same x hnc]; exact hl, a1, a2⟩

end Range
end Orin
