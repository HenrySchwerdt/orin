import Orin.Sound
import Orin.Frozen

/-!
# Frozen along a step of a checked run

Companion of `sound_step` (`Sound.lean`): a step of accepted code never changes the slots of an
object reachable from the anchors `ext` (`Frozen`).  `step_inv` bundles it with the safety and
preservation facts so that the call/return reasoning can use one statement.
-/

namespace Orin
open Heap

variable {ext : List Val} {np : Nat} {sg : List Sig}

theorem mstep_ite_ok {s : St} {c : Nat} {t e k : Code} {c' : Code × St} (hp : s.pending = [])
    (h : mstep (.ite c t e k, s) = some (.ok c')) : c'.2 = s := by
  simp only [mstep, hp] at h
  split at h
  · split at h
    · cases h; rfl
    · cases h; rfl
    · cases h
  · cases h

theorem mstep_loop_ok {s : St} {c : Nat} {t k : Code} {c' : Code × St} (hp : s.pending = [])
    (h : mstep (.loop c t k, s) = some (.ok c')) : c'.2 = s := by
  simp only [mstep, hp] at h
  split at h
  · split at h
    · cases h; rfl
    · cases h; rfl
    · cases h
  · cases h

theorem frozen_step_nopending {E : AState → Prop} {a : AState} {code : Code}
    (hC : Cont sg np E a code) :
    ∀ s, Inv ext a.ls s → s.pending = [] → ∀ c', mstep (code, s) = some (.ok c') →
      Frozen ext s.heap c'.2.heap := by
  induction hC with
  | nil _ => intro s hI hp c' h; simp [mstep, hp] at h
  | @op E a a1 i k hstep hk ih =>
    intro s hI hp c' h
    have hL := stepA_ls hstep
    have h' : Res.liftC k (mop s i) = .ok c' := by simpa [mstep, hp, mexec] using h
    cases hm : mop s i with
    | ok s' =>
      rw [hm] at h'
      simp only [Res.liftC, Res.ok.injEq] at h'
      subst h'
      exact op_frozen hI hL hm
    | bad _ => rw [hm] at h'; simp [Res.liftC] at h'
    | trap => rw [hm] at h'; simp [Res.liftC] at h'
    | ill => rw [hm] at h'; simp [Res.liftC] at h'
  | @ite E a c t e k hc hinit hT hE ihT ihE =>
    intro s hI hp c' h
    rw [mstep_ite_ok hp h]; exact Frozen.refl _
  | @loop E a b c t k hF hcb hinit hBody hK ihBody ihK =>
    intro s hI hp c' h
    rw [mstep_loop_ok hp h]; exact Frozen.refl _
  | call _ _ _ => intro s hI hp c' h; simp [mstep, hp] at h
  | @weak E a b code hF hk ih =>
    intro s hI hp c' h
    exact ih s (hI.weaken hF) hp c' h

end Orin
