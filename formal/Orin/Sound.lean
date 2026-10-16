import Orin.SimArr

/-!
# Soundness of the ownership checker

`Cont np a code` : the checker accepts `code` from abstract state `a` (a derivation that mirrors
`chk`, closed under weakening so that it survives the join at the end of an `if`).
`sound_step` : a configuration whose code is accepted and whose state is related to `a` takes a
step that is never `bad`, and the successor is again accepted and related.
`check_sound` : a program accepted by `check`, started in a state that satisfies the entry
condition, never reaches `bad` (no use after free, no double free, no in-place store into an object
that is not uniquely owned).
-/

namespace Orin
open Heap

variable {ext : List Val} {np : Nat}

/-- `Cont np E a code`: the checker accepts `code` from abstract state `a`, and when the code runs
out the abstract state satisfies `E` (a derivation that mirrors `chk`, closed under weakening so
that it survives the join at the end of an `if` and the loop invariant).  The end condition `E`
is what lets a loop body be checked against "return to the loop head": `loop` takes a body
derivation whose end condition is `Fle · b`, `b` the loop invariant. -/
inductive Cont (np : Nat) : (AState → Prop) → AState → Code → Prop
  | nil {E : AState → Prop} {a : AState} : E a → Cont np E a .nil
  | op {E : AState → Prop} {a a1 : AState} {i : MI} {k : Code} :
      stepA np a i = some a1 → Cont np E a1 k → Cont np E a (.op i k)
  | ite {E : AState → Prop} {a : AState} {c : Nat} {t e k : Code} :
      c < a.ls.length → gk a.ls c = .init → Cont np E a (t.app k) → Cont np E a (e.app k) →
      Cont np E a (.ite c t e k)
  | loop {E : AState → Prop} {a b : AState} {c : Nat} {t k : Code} :
      Fle a.ls b.ls → c < b.ls.length → gk b.ls c = .init →
      Cont np (fun x => Fle x.ls b.ls) b t → Cont np E b k → Cont np E a (.loop c t k)
  | weak {E : AState → Prop} {a b : AState} {code : Code} :
      Fle a.ls b.ls → Cont np E b code → Cont np E a code

theorem Code.app_nil : ∀ c : Code, c.app .nil = c
  | .nil => rfl
  | .op i c => by simp [Code.app, Code.app_nil c]
  | .ite c t e k => by simp [Code.app, Code.app_nil k]
  | .loop c t k => by simp [Code.app, Code.app_nil k]

theorem Code.app_assoc : ∀ (c k1 k2 : Code), (c.app k1).app k2 = c.app (k1.app k2)
  | .nil, _, _ => rfl
  | .op i c, k1, k2 => by simp [Code.app, Code.app_assoc c k1 k2]
  | .ite c t e k, k1, k2 => by simp [Code.app, Code.app_assoc k k1 k2]
  | .loop c t k, k1, k2 => by simp [Code.app, Code.app_assoc k k1 k2]

theorem stepA_ls {a a1 : AState} {i : MI} (h : stepA np a i = some a1) :
    stepL np a.ls i = some a1.ls := by
  unfold stepA at h
  cases hs : stepL np a.ls i with
  | none => rw [hs] at h; simp at h
  | some ls' =>
    rw [hs] at h
    simp only [Option.map_eq_some_iff] at h
    obtain ⟨h', _, rfl⟩ := h
    rfl

/-- Sequencing: code accepted with end condition `E1` can be followed by any continuation that
is accepted from every state satisfying `E1`. -/
theorem Cont.seq {E1 E : AState → Prop} {a : AState} {t : Code} (h : Cont np E1 a t) :
    ∀ K : Code, (∀ x, E1 x → Cont np E x K) → Cont np E a (t.app K) := by
  induction h with
  | nil hE => intro K hK; exact hK _ hE
  | op hstep _ ih => intro K hK; exact Cont.op hstep (ih K hK)
  | @ite E1 a c t e k hc hi _ _ iht ihe =>
    intro K hK
    refine Cont.ite hc hi ?_ ?_
    · have := iht K hK
      rwa [Code.app_assoc] at this
    · have := ihe K hK
      rwa [Code.app_assoc] at this
  | loop hF hcb hini hbody _ _ ihk =>
    intro K hK
    exact Cont.loop hF hcb hini hbody (ihk K hK)
  | weak hF _ ih => intro K hK; exact Cont.weak hF (ih K hK)

/-! ### the loop invariant search -/

theorem loopFix_spec (body : AState → Option AState) (c : Nat) :
    ∀ (fuel : Nat) (b bi : AState), loopFix body c fuel b = some bi →
      Fle b.ls bi.ls ∧ c < bi.ls.length ∧ gk bi.ls c = .init ∧
      ∃ b2, body bi = some b2 ∧ Fle b2.ls bi.ls := by
  intro fuel
  induction fuel with
  | zero => intro b bi h; simp [loopFix] at h
  | succ n ih =>
    intro b bi h
    simp only [loopFix] at h
    split at h
    · rename_i hc
      cases hb : body b with
      | none => rw [hb] at h; simp at h
      | some b2 =>
        rw [hb] at h
        simp only [Option.bind_some] at h
        cases hj : joinS b b2 with
        | none => rw [hj] at h; simp at h
        | some b' =>
          rw [hj] at h
          simp only [Option.bind_some] at h
          have hjc := hj
          unfold joinS at hjc
          split at hjc
          · rename_i hcond
            have hb' : b' = ⟨joinL b.ls b2.ls, b.holes⟩ := (Option.some.inj hjc).symm
            have hlen : b.ls.length = b2.ls.length := hcond.1
            have hF1 : Fle b.ls b'.ls := by rw [hb']; exact joinL_fle_left _ _ hlen
            by_cases hls : b'.ls = b.ls
            · rw [if_pos hls] at h
              have hbi : b = bi := Option.some.inj h
              subst hbi
              have hF2 : Fle b2.ls b'.ls := by rw [hb']; exact joinL_fle_right _ _ hlen
              rw [hls] at hF2 hF1
              exact ⟨hF1, hc.1, hc.2, b2, hb, hF2⟩
            · rw [if_neg hls] at h
              obtain ⟨hF, hcb, hini, b3, hb3, hF3⟩ := ih b' bi h
              exact ⟨hF1.trans hF, hcb, hini, b3, hb3, hF3⟩
          · simp at hjc
    · simp at h

/-! ### the checker yields a `Cont` derivation -/

theorem chk_cont : ∀ (t : Code) (a at' : AState) (k : Code) (E : AState → Prop),
    chk np a t = some at' → Cont np E at' k → Cont np E a (t.app k) := by
  intro t
  induction t with
  | nil =>
    intro a at' k E h hk
    simp only [chk, Option.some.injEq] at h
    subst h
    exact hk
  | op i t1 ih =>
    intro a at' k E h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact Cont.op h1 (ih a1 at' k E h2 hk)
  | ite c t e k1 iht ihe ihk =>
    intro a at' k E h hk
    simp only [chk] at h
    split at h
    · rename_i hc
      simp only [Option.bind_eq_some_iff] at h
      obtain ⟨at1, ht, ae, he, aj, hj, hk1⟩ := h
      have hjoin := hj
      unfold joinS at hjoin
      split at hjoin
      · rename_i hjc
        have haj : aj = ⟨joinL at1.ls ae.ls, at1.holes⟩ := (Option.some.inj hjoin).symm
        subst haj
        have hkc := ihk _ at' k E hk1 hk
        have hl : at1.ls.length = ae.ls.length := hjc.1
        have hct : Cont np E at1 (k1.app k) :=
          Cont.weak (a := at1) (b := ⟨joinL at1.ls ae.ls, at1.holes⟩)
            (joinL_fle_left _ _ hl) hkc
        have hce : Cont np E ae (k1.app k) :=
          Cont.weak (a := ae) (b := ⟨joinL at1.ls ae.ls, at1.holes⟩)
            (joinL_fle_right _ _ hl) hkc
        exact Cont.ite hc.1 hc.2 (iht a at1 _ E ht hct) (ihe a ae _ E he hce)
      · simp at hjoin
    · simp at h
  | loop c t1 k1 iht ihk =>
    intro a at' k E h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨b, hfix, hkb⟩ := h
    obtain ⟨hF, hcb, hini, b2, hb2, hFb2⟩ := loopFix_spec _ _ _ _ _ hfix
    have hbody : Cont np (fun x => Fle x.ls b.ls) b t1 := by
      have := iht b b2 .nil (fun x => Fle x.ls b.ls) hb2 (Cont.nil hFb2)
      rwa [Code.app_nil] at this
    exact Cont.loop hF hcb hini hbody (ihk b at' k E hkb hk)

/-! ### one step -/

theorem opsafe_step {E : AState → Prop} {a1 : AState} {k : Code} {r : Res St}
    (hs : OpSafe ext a1.ls r) (hc : Cont np E a1 k) :
    (∀ k', Res.liftC k r ≠ .bad k') ∧
    ∀ c', Res.liftC k r = .ok c' → ∃ a', Cont np E a' c'.1 ∧ Inv ext a'.ls c'.2 := by
  refine ⟨?_, ?_⟩
  · intro k' hh
    cases r with
    | bad kk => exact hs.1 kk rfl
    | ok _ => simp [Res.liftC] at hh
    | trap => simp [Res.liftC] at hh
    | ill => simp [Res.liftC] at hh
  · intro c' hh
    cases r with
    | ok s' =>
      simp only [Res.liftC, Res.ok.injEq] at hh
      subst hh
      exact ⟨a1, hc, hs.2 s' rfl⟩
    | bad _ => simp [Res.liftC] at hh
    | trap => simp [Res.liftC] at hh
    | ill => simp [Res.liftC] at hh

theorem sound_step_nopending {E : AState → Prop} {a : AState} {code : Code}
    (hC : Cont np E a code) :
    ∀ s, Inv ext a.ls s → s.pending = [] →
      (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
        ∀ c', r = .ok c' → ∃ a', Cont np E a' c'.1 ∧ Inv ext a'.ls c'.2) := by
  induction hC with
  | nil _ =>
    intro s hI hp
    left
    simp [mstep, hp]
  | @op E a a1 i k hstep hk ih =>
    intro s hI hp
    right
    have hL := stepA_ls hstep
    refine ⟨mexec i k s, by simp [mstep, hp], ?_⟩
    have key : OpSafe ext a1.ls (mop s i) := by
      cases i with
      | const d n => exact op_const hI hL
      | move d x => exact op_move hI hL
      | borrow d x => exact op_borrow hI hL
      | dup d x => exact op_dup hI hL
      | release x => exact op_release hI hL
      | alloc d n => exact op_alloc hI hL
      | getField d o j r => exact op_getField hI hL
      | setField x j v => exact op_setField hI hL
      | takeField d x j => exact op_takeField hI hL
      | putField x j y => exact op_putField hI hL
      | makeUnique x => exact op_makeUnique hI hL
      | arrayLen d x => exact op_arrayLen hI hL
      | arrayGet d x i r => exact op_arrayGet hI hL
      | arraySet x i v => exact op_arraySet hI hL
      | arrayNew d nl => exact op_arrayNew hI hL
    exact opsafe_step (r := mop s i) key hk
  | @ite E a c t e k hc hinit hT hE ihT ihE =>
    intro s hI hp
    right
    have hcl : c < s.locals.length := hI.len ▸ hc
    obtain ⟨n, hn⟩ := (hI.cl c).ini hinit
    by_cases h0 : n = 0
    · subst h0
      refine ⟨.ok (t.app k, s), by simp [mstep, hp, hcl, hn], ?_, ?_⟩
      · intro k' hh; cases hh
      · intro c' hh
        cases hh
        exact ⟨a, hT, hI⟩
    · refine ⟨.ok (e.app k, s), by simp [mstep, hp, hcl, hn, h0], ?_, ?_⟩
      · intro k' hh; cases hh
      · intro c' hh
        cases hh
        exact ⟨a, hE, hI⟩
  | @loop E a b c t k hF hcb hinit hBody hK ihBody ihK =>
    intro s hI hp
    right
    have hIb : Inv ext b.ls s := hI.weaken hF
    have hcl : c < s.locals.length := hIb.len ▸ hcb
    obtain ⟨n, hn⟩ := (hIb.cl c).ini hinit
    have hFbb : Fle b.ls b.ls := ⟨rfl, fun i => Or.inl rfl, hF.2.2⟩
    have hself : Cont np E b (.loop c t k) := Cont.loop hFbb hcb hinit hBody hK
    by_cases h0 : n = 0
    · subst h0
      refine ⟨.ok (t.app (.loop c t k), s), by simp [mstep, hp, hcl, hn], ?_, ?_⟩
      · intro k' hh; cases hh
      · intro c' hh
        cases hh
        exact ⟨b, Cont.seq hBody _ (fun x hx => Cont.weak hx hself), hIb⟩
    · refine ⟨.ok (k, s), by simp [mstep, hp, hcl, hn, h0], ?_, ?_⟩
      · intro k' hh; cases hh
      · intro c' hh
        cases hh
        exact ⟨b, hK, hIb⟩
  | @weak E a b code hF hk ih =>
    intro s hI hp
    exact ih s (hI.weaken hF) hp

theorem sound_step {E : AState → Prop} {a : AState} {code : Code} (hC : Cont np E a code)
    {s : St}
    (hI : Inv ext a.ls s) :
    (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → ∃ a', Cont np E a' c'.1 ∧ Inv ext a'.ls c'.2) := by
  by_cases hp : s.pending = []
  · exact sound_step_nopending hC s hI hp
  · right
    obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, s.pending = hd :: rest := by
      cases h : s.pending with
      | nil => exact absurd h hp
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    have hdr := drain_inv hI hp
    refine ⟨Res.liftC code (drain s), by simp [mstep, hpe], ?_, ?_⟩
    · intro k hh
      cases hd' : drain s with
      | bad kk => exact hdr.1 kk hd'
      | ok _ => rw [hd'] at hh; simp [Res.liftC] at hh
      | trap => rw [hd'] at hh; simp [Res.liftC] at hh
      | ill => rw [hd'] at hh; simp [Res.liftC] at hh
    · intro c' hh
      cases hd' : drain s with
      | ok s' =>
        rw [hd'] at hh
        simp only [Res.liftC, Res.ok.injEq] at hh
        subst hh
        exact ⟨a, hC, hdr.2 s' hd'⟩
      | bad _ => rw [hd'] at hh; simp [Res.liftC] at hh
      | trap => rw [hd'] at hh; simp [Res.liftC] at hh
      | ill => rw [hd'] at hh; simp [Res.liftC] at hh

/-! ### runs -/

theorem reach_inv {E : AState → Prop} {a : AState} {code : Code} {s : St}
    (hC : Cont np E a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∃ a', Cont np E a' c.1 ∧ Inv ext a'.ls c.2 := by
  generalize hc0 : (code, s) = c0 at hr
  induction hr generalizing code s a with
  | refl => cases hc0; exact ⟨a, hC, hI⟩
  | step c1 c2 d h12 _ ih =>
    cases hc0
    rcases sound_step hC hI with hn | ⟨r, hr, _, hok⟩
    · rw [hn] at h12; cases h12
    · rw [hr] at h12
      cases h12
      obtain ⟨a', hC', hI'⟩ := hok c2 rfl
      exact ih hC' hI' rfl

theorem reach_safe {E : AState → Prop} {a : AState} {code : Code} {s : St}
    (hC : Cont np E a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∀ k, mstep c ≠ some (.bad k) := by
  obtain ⟨a', hC', hI'⟩ := reach_inv hC hI hr
  intro k hh
  rcases sound_step hC' hI' with hn | ⟨r, hr', hnb, _⟩
  · rw [hn] at hh; cases hh
  · rw [hr'] at hh
    exact hnb k (Option.some.inj hh)

end Orin
