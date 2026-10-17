import Orin.RangeRes

/-!
# Interval analysis: one step of the abstract transfer is sound (rule R2, fact destruction)

`step_sound`: if the abstract state describes the concrete frame (`RunSound`) and the instruction
executes (`Exec`), the abstract state after `step` is not dead and describes the new frame.  The
pieces: the intervals of the locals the instruction does not define are untouched, except that the
array facts the instruction mentions and does not keep are destroyed (`destroy`; this is why a
counted reference that is kept survives, `Summ.keep`); the defined local is described by `ResOK`;
the recorded comparison survives only if none of its locals is defined (`disturb`), and a new one is
recorded by `noteCmp`.
-/

namespace Orin
namespace Range

variable {cls : List Cls} {iv : List Iv} {s s' : CS} {ins : RI}

/-! ### the list operations -/

theorem length_forget (cls : List Cls) (iv : List Iv) (x : Nat) : (forget cls iv x).length = iv.length := by
  simp [forget]

theorem assign_cases (cls : List Cls) (iv : List Iv) (d : Nat) (lo hi : Int) :
    ∃ l, l = (if clsOf cls d = .usize ∧ lo < 0 then 0 else lo) ∧
      ((l > hi ∧ assign cls iv d lo hi = forget cls iv d) ∨
       (¬ l > hi ∧ assign cls iv d lo hi = iv.set d ⟨l, hi⟩)) := by
  unfold assign
  refine ⟨_, rfl, ?_⟩
  dsimp only
  by_cases h : (if clsOf cls d = Cls.usize ∧ lo < 0 then 0 else lo) > hi
  · exact Or.inl ⟨h, if_pos h⟩
  · exact Or.inr ⟨h, if_neg h⟩

theorem length_assign (cls : List Cls) (iv : List Iv) (d : Nat) (lo hi : Int) :
    (assign cls iv d lo hi).length = iv.length := by
  obtain ⟨l, _, h | h⟩ := assign_cases cls iv d lo hi
  · rw [h.2]; exact length_forget _ _ _
  · rw [h.2]; simp

theorem length_destroy (cls : List Cls) (ins : RI) (iv : List Iv) :
    (destroy cls ins iv).length = iv.length := by
  simp [destroy]

theorem gi_forget_ne {x y : Nat} (h : y ≠ x) : gi (forget cls iv x) y = gi iv y := by
  unfold forget; exact gi_set_ne h _

theorem gi_assign_ne {d y : Nat} {lo hi : Int} (h : y ≠ d) :
    gi (assign cls iv d lo hi) y = gi iv y := by
  obtain ⟨l, _, h1 | h1⟩ := assign_cases cls iv d lo hi
  · rw [h1.2]; exact gi_forget_ne h
  · rw [h1.2]; exact gi_set_ne h _

theorem gi_forget_same {x : Nat} (hx : x < iv.length) :
    gi (forget cls iv x) x = ⟨floorOf (clsOf cls x), BIG⟩ := by
  unfold forget; exact gi_set_same hx _

/-- the value of a scalar local is described by the assigned interval -/
theorem assign_scalar {d : Nat} {lo hi n : Int} (hd : d < iv.length) (hc : clsOf cls d ≠ .ref)
    (hok : (clsOf cls d).okv n) (hm : Mem n ⟨lo, hi⟩) :
    Mem n (gi (assign cls iv d lo hi) d) := by
  obtain ⟨l, hl, h1 | h1⟩ := assign_cases cls iv d lo hi
  · rw [h1.2, gi_forget_same hd]
    exact mem_unkOf hok hc
  · rw [h1.2, gi_set_same hd]
    unfold Mem at hm ⊢
    simp only at hm ⊢
    rw [hl]
    split
    · rename_i hu
      rw [hu.1] at hok
      simp only [Cls.okv] at hok
      unfold NEG at *
      omega
    · exact hm

theorem forget_unknown {x : Nat} (hx : x < iv.length) (hc : clsOf cls x = .ref) :
    ¬ 0 ≤ (gi (forget cls iv x) x).lo := by
  rw [gi_forget_same hx]
  simp only [hc, floorOf]
  unfold NEG
  omega

/-- a reference local gets a known interval only if the result interval was known, and then exactly it -/
theorem assign_ref {d : Nat} {lo hi : Int} (hd : d < iv.length) (hc : clsOf cls d = .ref)
    (h0 : 0 ≤ (gi (assign cls iv d lo hi) d).lo) :
    0 ≤ lo ∧ gi (assign cls iv d lo hi) d = ⟨lo, hi⟩ := by
  obtain ⟨l, hl, h1 | h1⟩ := assign_cases cls iv d lo hi
  · rw [h1.2] at h0
    exact absurd h0 (forget_unknown hd hc)
  · rw [h1.2, gi_set_same hd] at h0 ⊢
    have hl' : l = lo := by
      rw [hl]
      have : ¬ (clsOf cls d = .usize ∧ lo < 0) := by rw [hc]; intro h; cases h.1
      simp [this]
    subst hl'
    exact ⟨h0, rfl⟩

theorem gi_destroy (cls : List Cls) (ins : RI) (iv : List Iv) (y : Nat) :
    gi (destroy cls ins iv) y =
      if (decide (y ∈ ins.men) && decide (known cls iv y) && !ins.keeps y) = true then Iv.unk
      else gi iv y := by
  unfold gi destroy
  rw [List.getElem?_mapIdx]
  cases h : iv[y]? with
  | none => simp
  | some x => simp

theorem destroy_other {y : Nat} (hc : clsOf cls y ≠ .ref) :
    gi (destroy cls ins iv) y = gi iv y := by
  rw [gi_destroy]
  have : ¬ known cls iv y := fun h => hc h.1
  simp [this]

theorem destroy_keep {y : Nat} (hc : clsOf cls y = .ref) (h0 : 0 ≤ (gi (destroy cls ins iv) y).lo) :
    gi (destroy cls ins iv) y = gi iv y ∧ (y ∉ ins.men ∨ ins.keeps y = true) := by
  rw [gi_destroy] at h0 ⊢
  by_cases hb : (decide (y ∈ ins.men) && decide (known cls iv y) && !ins.keeps y) = true
  · rw [if_pos hb] at h0
    exact absurd h0 (by show ¬ (0 ≤ NEG); unfold NEG; omega)
  · rw [if_neg hb] at h0 ⊢
    refine ⟨rfl, ?_⟩
    have hk : known cls iv y := ⟨hc, h0⟩
    by_cases hm : y ∈ ins.men
    · right
      revert hb
      cases hkp : ins.keeps y <;> simp [hm, hk]
    · left; exact hm

/-! ### unchanged locals -/

theorem not_chg (hE : Exec cls ins s s') {l : Nat} (hc : clsOf cls l ≠ .ref)
    (hd : ins.dst ≠ some l) (hr : ins.recv ≠ some l) : ¬ Chg cls ins l := by
  intro h
  rcases h with h | h | h | h
  · exact hd h
  · exact hr h
  · exact hc h.2.2
  · subst h
    cases hE with
    | makeUnique hca => exact hc hca

theorem unchanged (hE : Exec cls ins s s') {l : Nat} (hc : clsOf cls l ≠ .ref)
    (hd : ins.dst ≠ some l) (hr : ins.recv ≠ some l) : s'.get l = s.get l :=
  get_eq_of_loc ((exec_summ hE).same l (not_chg hE hc hd hr))

theorem evalOpd_congr {o : Opd} (h : ∀ l, o = .loc l → s'.get l = s.get l) :
    evalOpd cls s' o = evalOpd cls s o := by
  cases o with
  | loc l => simp only [evalOpd]; rw [h l rfl]
  | cint n => rfl
  | cusize n => rfl

theorem loc_of_get {s : CS} {y : Nat} (h : y < s.loc.length) : s.loc[y]? = some (s.get y) := by
  simp [CS.get, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]

/-! ### the recorded comparison -/

theorem disturb_some {note : Option Note} {l : Nat} {n : Note} (h : disturb note l = some n) :
    note = some n ∧ ¬ (l = n.c ∨ n.x = .loc l ∨ n.y = .loc l) := by
  cases note with
  | none => simp [disturb] at h
  | some m =>
    simp only [disturb] at h
    split at h
    · cases h
    · rename_i hn
      cases h
      exact ⟨rfl, hn⟩

/-- the recorded comparison that survives the definitions of the instruction -/
theorem note_surv {note : Option Note} {n : Note}
    (h : (match ins.dst with
      | some d => disturb (match ins.recv with | some x => disturb note x | none => note) d
      | none => match ins.recv with | some x => disturb note x | none => note) = some n) :
    note = some n ∧ ∀ l, (l = n.c ∨ n.x = .loc l ∨ n.y = .loc l) →
      ins.dst ≠ some l ∧ ins.recv ≠ some l := by
  cases hd : ins.dst with
  | none =>
    cases hr : ins.recv with
    | none =>
      rw [hd, hr] at h
      exact ⟨h, fun l _ => ⟨by simp, by simp⟩⟩
    | some x =>
      rw [hd, hr] at h
      obtain ⟨h1, h2⟩ := disturb_some h
      refine ⟨h1, fun l hl => ⟨by simp, ?_⟩⟩
      intro e
      cases e
      exact h2 hl
  | some d =>
    rw [hd] at h
    obtain ⟨h1, h2⟩ := disturb_some h
    cases hr : ins.recv with
    | none =>
      rw [hr] at h1
      refine ⟨h1, fun l hl => ⟨?_, by simp⟩⟩
      intro e
      cases e
      exact h2 hl
    | some x =>
      rw [hr] at h1
      obtain ⟨h3, h4⟩ := disturb_some h1
      refine ⟨h3, fun l hl => ⟨?_, ?_⟩⟩
      · intro e; cases e; exact h2 hl
      · intro e; cases e; exact h4 hl

theorem noteOk_keep {n : Note} (hno : NoteOk cls s (some n))
    (hf : ∀ l, (l = n.c ∨ n.x = .loc l ∨ n.y = .loc l) →
      ins.dst ≠ some l ∧ ins.recv ≠ some l)
    (hE : Exec cls ins s s') : NoteOk cls s' (some n) := by
  obtain ⟨h1, h2, h3, vx, vy, hx, hy, hc⟩ := hno
  have hcl : ∀ l, (n.x = .loc l ∨ n.y = .loc l) → clsOf cls l ≠ .ref := by
    intro l hl
    rcases hl with hl | hl
    · have : opCls cls n.x = clsOf cls l := by rw [hl]; rfl
      rw [← this]; rcases h1 with h | h <;> rw [h] <;> intro e <;> cases e
    · have : opCls cls n.y = clsOf cls l := by rw [hl]; rfl
      rw [← this, h2]; rcases h1 with h | h <;> rw [h] <;> intro e <;> cases e
  have hu : ∀ l, (n.x = .loc l ∨ n.y = .loc l) → s'.get l = s.get l := fun l hl =>
    unchanged hE (hcl l hl) (hf l (Or.inr hl)).1 (hf l (Or.inr hl)).2
  have hcc : s'.get n.c = s.get n.c :=
    unchanged hE (by rw [h3]; intro e; cases e) (hf n.c (Or.inl rfl)).1 (hf n.c (Or.inl rfl)).2
  refine ⟨h1, h2, h3, vx, vy, ?_, ?_, ?_⟩
  · rw [evalOpd_congr (fun l e => hu l (Or.inl e))]; exact hx
  · rw [evalOpd_congr (fun l e => hu l (Or.inr e))]; exact hy
  · rw [hcc]; exact hc

theorem noteOk_of {n3 : Option Note} (hn : ∀ n, n3 = some n → NoteOk cls s' (some n)) :
    NoteOk cls s' n3 := by
  cases n3 with
  | none => trivial
  | some n => exact hn n rfl

theorem noteCmp_ok {n3 : Option Note} (hE : Exec cls ins s s')
    (hn : ∀ n, n3 = some n → NoteOk cls s' (some n)) : NoteOk cls s' (noteCmp cls ins n3) := by
  cases hE with
  | cmp hd hcd hx hy =>
    rename_i d op x y vx vy
    simp only [noteCmp]
    by_cases hc : clsOf cls d = Cls.bool ∧ (opCls cls x = Cls.int ∨ opCls cls x = Cls.usize) ∧
        opCls cls y = opCls cls x
    · rw [if_pos hc]
      obtain ⟨hcb, hxc, hyc⟩ := hc
      have hu : ∀ o : Opd, (opCls cls o = .int ∨ opCls cls o = .usize) →
          evalOpd cls (s.put d (.int (if op.eval vx vy then 1 else 0)) false) o = evalOpd cls s o := by
        intro o ho
        apply evalOpd_congr
        intro l hl
        subst hl
        have hne : l ≠ d := by
          intro e; subst e
          have : opCls cls (.loc l) = clsOf cls l := rfl
          rw [this, hcb] at ho; rcases ho with h | h <;> cases h
        have : (s.put d (.int (if op.eval vx vy then 1 else 0)) false).loc[l]? = s.loc[l]? := put_loc_ne _ hne _ _
        exact get_eq_of_loc this
      refine ⟨hxc, hyc, hcb, vx, vy, ?_, ?_, ?_⟩
      · rw [hu x hxc]; exact hx
      · rw [hu y (by rw [hyc]; exact hxc)]; exact hy
      · exact put_get_same s hd _ _
    · rw [if_neg hc]; exact noteOk_of hn
  | _ => exact noteOk_of hn

/-! ### assembly -/

/-- the intervals after `step` (for a live result `(rl, rh)`) -/
def ivRecv (cls : List Cls) (ins : RI) (iv : List Iv) : List Iv :=
  match ins.recv with
  | some x => forget cls (destroy cls ins iv) x
  | none => destroy cls ins iv

def ivOut (cls : List Cls) (ins : RI) (iv : List Iv) (rl rh : Int) : List Iv :=
  match ins.dst with
  | some d => assign cls (ivRecv cls ins iv) d rl rh
  | none => ivRecv cls ins iv

theorem length_ivOut (cls : List Cls) (ins : RI) (iv : List Iv) (rl rh : Int) :
    (ivOut cls ins iv rl rh).length = iv.length := by
  unfold ivOut
  have h2 : (ivRecv cls ins iv).length = iv.length := by
    unfold ivRecv
    cases ins.recv <;> simp [length_forget, length_destroy]
  cases ins.dst with
  | none => exact h2
  | some d =>
    dsimp only
    rw [length_assign]
    exact h2

theorem gi_ivOut_nd {y : Nat} {rl rh : Int} (hd : ins.dst ≠ some y) (hr : ins.recv ≠ some y) :
    gi (ivOut cls ins iv rl rh) y = gi (destroy cls ins iv) y := by
  unfold ivOut
  have h2 : gi (ivRecv cls ins iv) y = gi (destroy cls ins iv) y := by
    unfold ivRecv
    cases h : ins.recv with
    | none => rfl
    | some x =>
      dsimp only
      exact gi_forget_ne (fun e => hr (by rw [h, e]))
  cases h : ins.dst with
  | none => exact h2
  | some d =>
    dsimp only
    rw [gi_assign_ne (fun e => hd (by rw [h, e])), h2]

theorem gi_ivOut_recv {y : Nat} {rl rh : Int} (hd : ins.dst ≠ some y) (hr : ins.recv = some y)
    (hy : y < iv.length) : gi (ivOut cls ins iv rl rh) y = ⟨floorOf (clsOf cls y), BIG⟩ := by
  unfold ivOut
  have h2 : gi (ivRecv cls ins iv) y = ⟨floorOf (clsOf cls y), BIG⟩ := by
    unfold ivRecv
    rw [hr]
    exact gi_forget_same (by rw [length_destroy]; exact hy)
  cases h : ins.dst with
  | none => exact h2
  | some d =>
    dsimp only
    rw [gi_assign_ne (fun e => hd (by rw [h, e])), h2]

theorem gi_ivOut_dst {y : Nat} {rl rh : Int} (hd : ins.dst = some y) :
    ∃ iv2 : List Iv, iv2.length = iv.length ∧
      gi (ivOut cls ins iv rl rh) y = gi (assign cls iv2 y rl rh) y := by
  unfold ivOut
  rw [hd]
  dsimp only
  refine ⟨ivRecv cls ins iv, ?_, rfl⟩
  unfold ivRecv
  cases ins.recv <;> simp [length_forget, length_destroy]

theorem soundS_step {rl rh : Int} (hS : SoundS cls iv s) (hE : Exec cls ins s s')
    (hr : resOf cls iv ins = (rl, rh, false)) : SoundS cls (ivOut cls ins iv rl rh) s' := by
  have sm := exec_summ hE
  have hlen : s'.loc.length = cls.length := by rw [sm.size]; exact hS.lenloc
  refine ⟨by rw [length_ivOut]; exact hS.leniv, hlen, fun y hy hc => ?_, fun y hk => ?_⟩
  · have hyiv : y < iv.length := by rw [hS.leniv]; exact hy
    have hys : y < s'.loc.length := by rw [hlen]; exact hy
    by_cases hdy : ins.dst = some y
    · obtain ⟨iv2, hl2, hg⟩ := gi_ivOut_dst (rl := rl) (rh := rh) (cls := cls) (iv := iv) hdy
      have ro := res_ok hS hE hdy hy
      unfold ResOK at ro
      rw [hr] at ro
      obtain ⟨n, hn, hok, hm⟩ := ro.1 hc
      refine ⟨n, by rw [loc_of_get hys, hn], hok, ?_⟩
      rw [hg]
      exact assign_scalar (by rw [hl2]; exact hyiv) hc hok hm
    · by_cases hry : ins.recv = some y
      · have hv := sm.vok y (by rw [hS.lenloc]; exact hy) (Or.inr hry)
        obtain ⟨n, hn, hok⟩ := vok_scalar hv hc
        refine ⟨n, by rw [loc_of_get hys, hn], hok, ?_⟩
        rw [gi_ivOut_recv hdy hry hyiv]
        exact mem_unkOf hok hc
      · obtain ⟨n, hl, hok, hm⟩ := hS.scal y hy hc
        refine ⟨n, ?_, hok, ?_⟩
        · rw [sm.same y (not_chg hE hc hdy hry)]; exact hl
        · rw [gi_ivOut_nd hdy hry, destroy_other hc]; exact hm
  · obtain ⟨hc, h0⟩ := hk
    have hy : y < cls.length := clsOf_ref_lt hc
    have hyiv : y < iv.length := by rw [hS.leniv]; exact hy
    by_cases hdy : ins.dst = some y
    · obtain ⟨iv2, hl2, hg⟩ := gi_ivOut_dst (rl := rl) (rh := rh) (cls := cls) (iv := iv) hdy
      rw [hg] at h0
      obtain ⟨hrl, hgi⟩ := assign_ref (by rw [hl2]; exact hyiv) hc h0
      have ro := res_ok hS hE hdy hy
      unfold ResOK at ro
      rw [hr] at ro
      obtain ⟨l, n, hl, hn, hm, hct⟩ := ro.2 hc hrl
      refine ⟨l, n, hl, hn, ?_, hct⟩
      rw [hg, hgi]; exact hm
    · by_cases hry : ins.recv = some y
      · rw [gi_ivOut_recv hdy hry hyiv] at h0
        simp only [hc, floorOf] at h0
        unfold NEG at h0
        omega
      · rw [gi_ivOut_nd hdy hry] at h0 ⊢
        obtain ⟨hgeq, hkeep⟩ := destroy_keep hc h0
        obtain ⟨l, n, hl, hn, hm, hct⟩ := hS.fact y ⟨hc, by rw [← hgeq]; exact h0⟩
        obtain ⟨l', hl', hn', hct'⟩ := (exec_summ hE).keep y l n hkeep hl hct hn
        exact ⟨l', n, hl', hn', by rw [hgeq]; exact hm, hct'⟩

theorem step_sound {rs : RS} (hR : RunSound cls rs s) (hE : Exec cls ins s s') :
    RunSound cls (step cls ins rs) s' := by
  obtain ⟨hdead, hS, hno⟩ := hR
  have hdd := res_dd hS hE
  unfold step
  rw [hdead]
  simp only [Bool.false_eq_true, if_false]
  generalize hr : resOf cls rs.iv ins = r at hdd
  obtain ⟨rl, rh, dd⟩ := r
  simp only at hdd
  subst hdd
  simp only [Bool.false_eq_true, if_false]
  refine ⟨rfl, soundS_step hS hE hr, ?_⟩
  exact noteCmp_ok hE (fun n hn => by
    obtain ⟨h1, h2⟩ := note_surv hn
    rw [h1] at hno
    exact noteOk_keep hno h2 hE)

end Range
end Orin
