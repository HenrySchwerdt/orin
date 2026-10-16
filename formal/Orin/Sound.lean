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

inductive Cont (np : Nat) : AState → Code → Prop
  | nil {a : AState} : Cont np a .nil
  | op {a a1 : AState} {i : MI} {k : Code} :
      stepA np a i = some a1 → Cont np a1 k → Cont np a (.op i k)
  | ite {a : AState} {c : Nat} {t e k : Code} :
      c < a.ls.length → gk a.ls c = .init → Cont np a (t.app k) → Cont np a (e.app k) →
      Cont np a (.ite c t e k)
  | weak {a b : AState} {code : Code} : Fle a.ls b.ls → Cont np b code → Cont np a code

theorem Code.app_nil : ∀ c : Code, c.app .nil = c
  | .nil => rfl
  | .op i c => by simp [Code.app, Code.app_nil c]
  | .ite c t e k => by simp [Code.app, Code.app_nil k]

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

/-! ### the checker yields a `Cont` derivation -/

theorem chk_cont : ∀ (t : Code) (a at' : AState) (k : Code),
    chk np a t = some at' → Cont np at' k → Cont np a (t.app k) := by
  intro t
  induction t with
  | nil =>
    intro a at' k h hk
    simp only [chk, Option.some.injEq] at h
    subst h
    exact hk
  | op i t1 ih =>
    intro a at' k h hk
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact Cont.op h1 (ih a1 at' k h2 hk)
  | ite c t e k1 iht ihe ihk =>
    intro a at' k h hk
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
        have hkc := ihk _ at' k hk1 hk
        have hl : at1.ls.length = ae.ls.length := hjc.1
        have hct : Cont np at1 (k1.app k) :=
          Cont.weak (a := at1) (b := ⟨joinL at1.ls ae.ls, at1.holes⟩)
            (joinL_fle_left _ _ hl) hkc
        have hce : Cont np ae (k1.app k) :=
          Cont.weak (a := ae) (b := ⟨joinL at1.ls ae.ls, at1.holes⟩)
            (joinL_fle_right _ _ hl) hkc
        exact Cont.ite hc.1 hc.2 (iht a at1 _ ht hct) (ihe a ae _ he hce)
      · simp at hjoin
    · simp at h

/-! ### one step -/

theorem opsafe_step {a1 : AState} {k : Code} {r : Res St} (hs : OpSafe ext a1.ls r)
    (hc : Cont np a1 k) :
    (∀ k', Res.liftC k r ≠ .bad k') ∧
    ∀ c', Res.liftC k r = .ok c' → ∃ a', Cont np a' c'.1 ∧ Inv ext a'.ls c'.2 := by
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

theorem sound_step_nopending {a : AState} {code : Code} (hC : Cont np a code) :
    ∀ s, Inv ext a.ls s → s.pending = [] →
      (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
        ∀ c', r = .ok c' → ∃ a', Cont np a' c'.1 ∧ Inv ext a'.ls c'.2) := by
  induction hC with
  | nil =>
    intro s hI hp
    left
    simp [mstep, hp]
  | @op a a1 i k hstep hk ih =>
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
  | @ite a c t e k hc hinit hT hE ihT ihE =>
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
  | @weak a b code hF hk ih =>
    intro s hI hp
    exact ih s (hI.weaken hF) hp

theorem sound_step {a : AState} {code : Code} (hC : Cont np a code) {s : St}
    (hI : Inv ext a.ls s) :
    (mstep (code, s) = none ∨ ∃ r, mstep (code, s) = some r ∧ (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → ∃ a', Cont np a' c'.1 ∧ Inv ext a'.ls c'.2) := by
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

theorem reach_inv {a : AState} {code : Code} {s : St} (hC : Cont np a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∃ a', Cont np a' c.1 ∧ Inv ext a'.ls c.2 := by
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

theorem reach_safe {a : AState} {code : Code} {s : St} (hC : Cont np a code)
    (hI : Inv ext a.ls s) {c : Code × St} (hr : MReach (code, s) c) :
    ∀ k, mstep c ≠ some (.bad k) := by
  obtain ⟨a', hC', hI'⟩ := reach_inv hC hI hr
  intro k hh
  rcases sound_step hC' hI' with hn | ⟨r, hr', hnb, _⟩
  · rw [hn] at hh; cases hh
  · rw [hr'] at hh
    exact hnb k (Option.some.inj hh)

end Orin
