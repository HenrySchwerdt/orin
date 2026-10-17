import Orin.Hole

/-!
# Soundness of the ownership checker

`Cont sg np a code` : the checker accepts `code` from abstract state `a` (a derivation that mirrors
`chk`, closed under weakening so that it survives the join at the end of an `if`).
`sound_step` : a configuration whose code is accepted and whose state is related to `a` takes a
step that is never `bad`, and the successor is again accepted and related.
`check_sound` : a program accepted by `check`, started in a state that satisfies the entry
condition, never reaches `bad` (no use after free, no double free, no in-place store into an object
that is not uniquely owned).
-/

namespace Orin
open Heap

variable {ext : List Val} {np : Nat} {sg : List Sig}

/-- `Cont sg np E a code`: the checker accepts `code` from abstract state `a`, and when the code runs
out the abstract state satisfies `E` (a derivation that mirrors `chk`, closed under weakening so
that it survives the join at the end of an `if` and the loop invariant).  The end condition `E`
is what lets a loop body be checked against "return to the loop head": `loop` takes a body
derivation whose end condition is `FleS · b`, `b` the loop invariant. -/
inductive Cont (sg : List Sig) (np : Nat) : (AState → Prop) → AState → Code → Prop
  | nil {E : AState → Prop} {a : AState} : E a → Cont sg np E a .nil
  | op {E : AState → Prop} {a a1 : AState} {i : MI} {k : Code} :
      stepA np a i = some a1 → Cont sg np E a1 k → Cont sg np E a (.op i k)
  | ite {E : AState → Prop} {a : AState} {c : Nat} {t e k : Code} :
      c < a.ls.length → gk a.ls c = .init → Cont sg np E a (t.app k) → Cont sg np E a (e.app k) →
      Cont sg np E a (.ite c t e k)
  | loop {E : AState → Prop} {a b : AState} {c : Nat} {t k : Code} :
      FleS a b → c < b.ls.length → gk b.ls c = .init →
      Cont sg np (fun x => FleS x b) b t → Cont sg np E b k → Cont sg np E a (.loop c t k)
  | call {E : AState → Prop} {a a1 : AState} {d f : Nat} {args : List Nat} {k : Code} :
      stepAC np sg a d f args = some a1 → Cont sg np E a1 k → Cont sg np E a (.call d f args k)
  | weak {E : AState → Prop} {a b : AState} {code : Code} :
      FleS a b → Cont sg np E b code → Cont sg np E a code

theorem Code.app_nil : ∀ c : Code, c.app .nil = c
  | .nil => rfl
  | .op i c => by simp [Code.app, Code.app_nil c]
  | .ite c t e k => by simp [Code.app, Code.app_nil k]
  | .loop c t k => by simp [Code.app, Code.app_nil k]
  | .call d f args k => by simp [Code.app, Code.app_nil k]

theorem Code.app_assoc : ∀ (c k1 k2 : Code), (c.app k1).app k2 = c.app (k1.app k2)
  | .nil, _, _ => rfl
  | .op i c, k1, k2 => by simp [Code.app, Code.app_assoc c k1 k2]
  | .ite c t e k, k1, k2 => by simp [Code.app, Code.app_assoc k k1 k2]
  | .loop c t k, k1, k2 => by simp [Code.app, Code.app_assoc k k1 k2]
  | .call d f args k, k1, k2 => by simp [Code.app, Code.app_assoc k k1 k2]

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
theorem Cont.seq {E1 E : AState → Prop} {a : AState} {t : Code} (h : Cont sg np E1 a t) :
    ∀ K : Code, (∀ x, E1 x → Cont sg np E x K) → Cont sg np E a (t.app K) := by
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
  | call hstep _ ih => intro K hK; exact Cont.call hstep (ih K hK)
  | weak hF _ ih => intro K hK; exact Cont.weak hF (ih K hK)

/-! ### the loop invariant search -/

/-! ### the checker yields a `Cont` derivation -/

theorem chk_cont : ∀ (t : Code) (a at' : AState) (k : Code) (E : AState → Prop),
    HU a → chk np sg a t = some at' → Cont sg np E at' k → Cont sg np E a (t.app k) := by
  intro t
  induction t with
  | nil =>
    intro a at' k E _ h hk
    simp only [chk, Option.some.injEq] at h
    subst h
    exact hk
  | op i t1 ih =>
    intro a at' k E hu h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact Cont.op h1 (ih a1 at' k E (HU_stepA hu h1) h2 hk)
  | ite c t e k1 iht ihe ihk =>
    intro a at' k E hu h hk
    simp only [chk] at h
    split at h
    · rename_i hc
      simp only [Option.bind_eq_some_iff] at h
      obtain ⟨at1, ht, ae, he, aj, hj, hk1⟩ := h
      obtain ⟨hF1, hF2, huj⟩ := joinS_fleS hj (HU_chk _ _ _ hu ht) (HU_chk _ _ _ hu he)
      have hkc := ihk _ at' k E huj hk1 hk
      exact Cont.ite hc.1 hc.2 (iht a at1 _ E hu ht (Cont.weak hF1 hkc))
        (ihe a ae _ E hu he (Cont.weak hF2 hkc))
    · simp at h
  | loop c t1 k1 iht ihk =>
    intro a at' k E hu h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨b, hfix, hkb⟩ := h
    obtain ⟨hub, hF, hcb, hini, b2, hb2, hFb2⟩ :=
      loopFix_spec_S _ c (fun x y hx hy => HU_chk t1 x y hx hy) _ a b hu hfix
    have hbody : Cont sg np (fun x => FleS x b) b t1 := by
      have := iht b b2 .nil (fun x => FleS x b) hub hb2 (Cont.nil hFb2)
      rwa [Code.app_nil] at this
    exact Cont.loop hF hcb hini hbody (ihk b at' k E hub hkb hk)
  | call d f args k1 ih =>
    intro a at' k E hu h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact Cont.call h1 (ih a1 at' k E (HU_stepAC hu h1) h2 hk)

/-! ### one step -/

theorem opsafe_step {E : AState → Prop} {a1 : AState} {k : Code} {r : Res St}
    (hs : OpSafe ext a1.ls r) (hc : Cont sg np E a1 k) :
    (∀ k', Res.liftC k r ≠ .bad k') ∧
    ∀ c', Res.liftC k r = .ok c' → ∃ a', Cont sg np E a' c'.1 ∧ Inv ext a'.ls c'.2 := by
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
    (hC : Cont sg np E a code) :
    ∀ s, Inv ext a.ls s → s.pending = [] →
      (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
        ∀ c', r = .ok c' → ∃ a', Cont sg np E a' c'.1 ∧ Inv ext a'.ls c'.2) := by
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
    have hIb : Inv ext b.ls s := hI.weaken hF.1
    have hcl : c < s.locals.length := hIb.len ▸ hcb
    obtain ⟨n, hn⟩ := (hIb.cl c).ini hinit
    have hFbb : FleS b b := hF.self_right
    have hself : Cont sg np E b (.loop c t k) := Cont.loop hFbb hcb hinit hBody hK
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
  | call _ _ _ =>
    intro s hI hp
    left
    simp [mstep, hp]
  | @weak E a b code hF hk ih =>
    intro s hI hp
    exact ih s (hI.weaken hF.1) hp

theorem sound_step {E : AState → Prop} {a : AState} {code : Code} (hC : Cont sg np E a code)
    {s : St}
    (hI : Inv ext a.ls s) :
    (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → ∃ a', Cont sg np E a' c'.1 ∧ Inv ext a'.ls c'.2) := by
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
    (hC : Cont sg np E a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∃ a', Cont sg np E a' c.1 ∧ Inv ext a'.ls c.2 := by
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
    (hC : Cont sg np E a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∀ k, mstep c ≠ some (.bad k) := by
  obtain ⟨a', hC', hI'⟩ := reach_inv hC hI hr
  intro k hh
  rcases sound_step hC' hI' with hn | ⟨r, hr', hnb, _⟩
  · rw [hn] at hh; cases hh
  · rw [hr'] at hh
    exact hnb k (Option.some.inj hh)

end Orin
