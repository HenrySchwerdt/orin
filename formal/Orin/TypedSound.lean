import Orin.TypedOps
import Orin.Sound

/-!
# The machine never gets `ill`: one function

`top_op` dispatches the per-instruction lemmas of `TypedOps.lean`; `top_drain` is the release
worklist; `sound_stepT` is the induction over the acceptance derivation `Cont` (the same shape as
`sound_step`) that carries the type invariant `TInv` and the hole-owner invariant `HU` along, so
that every reachable step is neither `bad` (ownership) nor `ill` (shape, type, null).
-/

namespace Orin
open Heap

variable {ext : List Val} {np : Nat} {sg : List Sig} {sh : Shapes} {tsg : List TSig} {Γ : List Ty} {hty : HTy}
  {a a1 : AState} {s : St}

/-- the ownership half of every instruction (the dispatch of `sound_step`) -/
theorem op_safe_all (i : MI) (hI : Inv ext a.ls s) {a1 : List AS}
    (hL : stepL np a.ls i = some a1) : OpSafe ext a1 (mop s i) := by
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

theorem top_op (i : MI) (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcheckI sh Γ i = true) (h : stepA np a i = some a1) :
    TOp sh Γ hty a1 s (mop s i) := by
  cases i with
  | const d n => exact top_const hI hT ht h
  | move d x => exact top_move hI hT ht h
  | borrow d x => exact top_borrow hI hT ht h
  | dup d x => exact top_dup hI hT ht h
  | release x => exact top_release hI hT ht h
  | alloc d n => exact top_alloc hI hT ht h
  | getField d o j r => exact top_getField hI hT hu ht h
  | setField x j v => exact top_setField hI hT hu ht h
  | takeField d x j => exact top_takeField hI hT hu ht h
  | putField x j y => exact top_putField hI hT hu ht h
  | makeUnique x => exact top_makeUnique hI hT hu ht h
  | arrayLen d x => exact top_arrayLen hI hT ht h
  | arrayGet d x j r => exact top_arrayGet hI hT ht h
  | arraySet x j v => exact top_arraySet hI hT ht h
  | arrayNew d nl => exact top_arrayNew hI hT ht h

/-- the release worklist keeps the type invariant and never produces `ill` -/
theorem top_drain (hT : TInv sh Γ hty a s) (hp : s.pending ≠ []) :
    drain s ≠ .ill ∧ ∀ s', drain s = .ok s' → TInv sh Γ hty a s' ∧ s.heap.next ≤ s'.heap.next := by
  obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, s.pending = hd :: rest := by
    cases h : s.pending with
    | nil => exact absurd h hp
    | cons hd rest => exact ⟨hd, rest, rfl⟩
  cases hd with
  | int n =>
    have hdr : drain s = .ok { s with pending := rest } := by simp [drain, hpe]
    refine ⟨(by rw [hdr]; intro e; cases e), fun s' hs => ?_⟩
    rw [hdr] at hs
    cases hs
    exact ⟨hT.same rfl rfl, Nat.le_refl _⟩
  | ref l =>
    cases hob : s.heap.objs l with
    | none =>
      have hdr : drain s = .bad .dead := by simp [drain, hpe, hob]
      refine ⟨(by rw [hdr]; intro e; cases e), fun s' hs => ?_⟩
      rw [hdr] at hs; cases hs
    | some o =>
      by_cases h0 : o.rc = 0
      · have hdr : drain s = .bad .dead := by simp [drain, hpe, hob, h0]
        refine ⟨(by rw [hdr]; intro e; cases e), fun s' hs => ?_⟩
        rw [hdr] at hs; cases hs
      · by_cases h1 : o.rc = 1
        · have hdr : drain s = .ok { s with heap := s.heap.del l, pending := o.fields ++ rest } := by
            simp [drain, hpe, hob, h0, h1]
          refine ⟨(by rw [hdr]; intro e; cases e), fun s' hs => ?_⟩
          rw [hdr] at hs
          cases hs
          refine ⟨hT.heap rfl ⟨rfl, fun k o' ho' => ⟨o', ?_, rfl⟩⟩, Nat.le_refl _⟩
          by_cases hk : k = l
          · simp [Heap.del, hk] at ho'
          · simpa [Heap.del, hk] using ho'
        · have hdr : drain s = .ok { s with heap := s.heap.decRc l, pending := rest } := by
            simp [drain, hpe, hob, h0, h1]
          refine ⟨(by rw [hdr]; intro e; cases e), fun s' hs => ?_⟩
          rw [hdr] at hs
          cases hs
          refine ⟨hT.heap rfl ⟨decRc_next s.heap l, fun k o' ho' => ?_⟩, by
            have := decRc_next s.heap l; show s.heap.next ≤ (s.heap.decRc l).next; omega⟩
          by_cases hk : k = l
          · subst hk
            rw [decRc_objs _ _ _ hob, if_pos rfl] at ho'
            cases ho'
            exact ⟨o, hob, rfl⟩
          · rw [decRc_objs _ _ _ hob, if_neg hk] at ho'
            exact ⟨o', ho', rfl⟩

/-! ### weakening -/

theorem AS.le_init {k k' : AS} (h : AS.le k k') (hk : k' = .init) : k = .init := by
  unfold AS.le at h
  rcases h with h | h | ⟨h1, h2⟩
  · rw [h, hk]
  · rw [hk] at h; cases h
  · rw [hk] at h2; cases h2

theorem TInv.weaken {a b : AState} (hT : TInv sh Γ hty a s) (hF : FleS a b) : TInv sh Γ hty b s :=
  ⟨hT.loc, hT.obj, fun l o t ts i ho ht hts hτ hf => by
    obtain ⟨x, hx, hg⟩ := hT.hole l o t ts i ho ht hts hτ hf
    exact ⟨x, (hF.2.1 _).mp hx, hg⟩,
   fun x hx => hT.kt x (AS.le_init (hF.1.2.1 x) hx)⟩

theorem HU.weaken {a b : AState} (hu : HU a) (hF : FleS a b) : HU b := by
  intro p hp
  have hp' : p ∈ a.holes := (hF.2.1 p).mpr hp
  rw [hF.2.2 p hp']
  exact hu p hp'

/-! ### one step -/

theorem sound_stepT_nopending {E : AState → Prop} {a : AState} {code : Code}
    (hC : Cont sg np E a code) :
    ∀ (s : St) (hty : HTy), Inv ext a.ls s → TInv sh Γ hty a s → HU a →
      tcode sh tsg Γ code = true → s.pending = [] →
      (mstep (code, s) = none ∨ (mstep (code, s) ≠ some .ill ∧
        ∀ c', mstep (code, s) = some (.ok c') → ∃ a' hty', HyExt hty hty' s.heap c'.2.heap ∧
          Cont sg np E a' c'.1 ∧ Inv ext a'.ls c'.2 ∧ TInv sh Γ hty' a' c'.2 ∧ HU a' ∧ tcode sh tsg Γ c'.1 = true)) := by
  induction hC with
  | nil _ =>
    intro s hty hI hT hu ht hp
    left
    simp [mstep, hp]
  | @op E a a1 i k hstep hk ih =>
    intro s hty hI hT hu ht hp
    right
    have hL := stepA_ls hstep
    simp only [tcode, Bool.and_eq_true] at ht
    have hsafe := op_safe_all (np := np) i hI hL
    have htop := top_op (np := np) i hI hT hu ht.1 hstep
    have hm : mstep (.op i k, s) = some (mexec i k s) := by simp [mstep, hp]
    rw [hm]
    refine ⟨?_, fun c' hc' => ?_⟩
    · intro hh
      have : mexec i k s = .ill := Option.some.inj hh
      unfold mexec at this
      cases hr : mop s i with
      | ok _ => rw [hr] at this; simp [Res.liftC] at this
      | trap => rw [hr] at this; simp [Res.liftC] at this
      | bad _ => rw [hr] at this; simp [Res.liftC] at this
      | ill => exact htop.1 hr
    · have hc'' : Res.liftC k (mop s i) = .ok c' := Option.some.inj hc'
      cases hr : mop s i with
      | ok s' =>
        rw [hr] at hc''
        simp only [Res.liftC, Res.ok.injEq] at hc''
        subst hc''
        obtain ⟨hty', hex, hT'⟩ := htop.2 s' hr
        exact ⟨a1, hty', hex, hk, hsafe.2 s' hr, hT', HU_stepA hu hstep, ht.2⟩
      | trap => rw [hr] at hc''; simp [Res.liftC] at hc''
      | bad _ => rw [hr] at hc''; simp [Res.liftC] at hc''
      | ill => rw [hr] at hc''; simp [Res.liftC] at hc''
  | @ite E a c t e k hc hinit hT_ hE ihT ihE =>
    intro s hty hI hT hu ht hp
    right
    simp only [tcode, Bool.and_eq_true] at ht
    have hcl : c < s.locals.length := hI.len ▸ hc
    obtain ⟨n, hn⟩ := (hI.cl c).ini hinit
    have htt : tcode sh tsg Γ (t.app k) = true := tcode_app t k ht.1.1.2 ht.2
    have hte : tcode sh tsg Γ (e.app k) = true := tcode_app e k ht.1.2 ht.2
    by_cases h0 : n = 0
    · subst h0
      have hm : mstep (.ite c t e k, s) = some (.ok (t.app k, s)) := by simp [mstep, hp, hcl, hn]
      rw [hm]
      refine ⟨(fun hh => by cases hh), fun c' hc' => ?_⟩
      cases hc'
      exact ⟨a, hty, HyExt.refl _ _, hT_, hI, hT, hu, htt⟩
    · have hm : mstep (.ite c t e k, s) = some (.ok (e.app k, s)) := by
        simp [mstep, hp, hcl, hn, h0]
      rw [hm]
      refine ⟨(fun hh => by cases hh), fun c' hc' => ?_⟩
      cases hc'
      exact ⟨a, hty, HyExt.refl _ _, hE, hI, hT, hu, hte⟩
  | @loop E a b c t k hF hcb hinit hBody hK ihBody ihK =>
    intro s hty hI hT hu ht hp
    right
    simp only [tcode, Bool.and_eq_true] at ht
    have hIb : Inv ext b.ls s := hI.weaken hF.1
    have hTb : TInv sh Γ hty b s := hT.weaken hF
    have hub : HU b := hu.weaken hF
    have hcl : c < s.locals.length := hIb.len ▸ hcb
    obtain ⟨n, hn⟩ := (hIb.cl c).ini hinit
    have hself : Cont sg np E b (.loop c t k) :=
      Cont.loop hF.self_right hcb hinit hBody hK
    by_cases h0 : n = 0
    · subst h0
      have hm : mstep (.loop c t k, s) = some (.ok (t.app (.loop c t k), s)) := by
        simp [mstep, hp, hcl, hn]
      rw [hm]
      refine ⟨(fun hh => by cases hh), fun c' hc' => ?_⟩
      cases hc'
      refine ⟨b, hty, HyExt.refl _ _, Cont.seq hBody _ (fun x hx => Cont.weak hx hself), hIb, hTb, hub, ?_⟩
      exact tcode_app t _ ht.1.2 (by simp [tcode, ht.1.1, ht.1.2, ht.2])
    · have hm : mstep (.loop c t k, s) = some (.ok (k, s)) := by
        simp [mstep, hp, hcl, hn, h0]
      rw [hm]
      refine ⟨(fun hh => by cases hh), fun c' hc' => ?_⟩
      cases hc'
      exact ⟨b, hty, HyExt.refl _ _, hK, hIb, hTb, hub, ht.2⟩
  | call _ _ _ =>
    intro s hty hI hT hu ht hp
    left
    simp [mstep, hp]
  | @weak E a b code hF hk ih =>
    intro s hty hI hT hu ht hp
    exact ih s hty (hI.weaken hF.1) (hT.weaken hF) (hu.weaken hF) ht hp


theorem sound_stepT {E : AState → Prop} {a : AState} {code : Code}
    (hC : Cont sg np E a code) (s : St) (hty : HTy) (hI : Inv ext a.ls s)
    (hT : TInv sh Γ hty a s) (hu : HU a) (ht : tcode sh tsg Γ code = true) :
    (mstep (code, s) = none ∨ (mstep (code, s) ≠ some .ill ∧
      ∀ c', mstep (code, s) = some (.ok c') → ∃ a' hty', HyExt hty hty' s.heap c'.2.heap ∧
        Cont sg np E a' c'.1 ∧ Inv ext a'.ls c'.2 ∧ TInv sh Γ hty' a' c'.2 ∧ HU a' ∧ tcode sh tsg Γ c'.1 = true)) := by
  by_cases hp : s.pending = []
  · exact sound_stepT_nopending hC s hty hI hT hu ht hp
  · right
    obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, s.pending = hd :: rest := by
      cases h : s.pending with
      | nil => exact absurd h hp
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    have hdr := drain_inv hI hp
    have hdt := top_drain hT hp
    have hm : mstep (code, s) = some (Res.liftC code (drain s)) := by simp [mstep, hpe]
    rw [hm]
    refine ⟨?_, fun c' hc' => ?_⟩
    · intro hh
      cases hd' : drain s with
      | ill => exact hdt.1 hd'
      | ok _ => rw [hd'] at hh; simp [Res.liftC] at hh
      | trap => rw [hd'] at hh; simp [Res.liftC] at hh
      | bad _ => rw [hd'] at hh; simp [Res.liftC] at hh
    · have hh := Option.some.inj hc'
      cases hd' : drain s with
      | ok s' =>
        rw [hd'] at hh
        simp only [Res.liftC, Res.ok.injEq] at hh
        subst hh
        exact ⟨a, hty, HyExt.keep (hdt.2 s' hd').2, hC, hdr.2 s' hd', (hdt.2 s' hd').1, hu, ht⟩
      | bad _ => rw [hd'] at hh; simp [Res.liftC] at hh
      | trap => rw [hd'] at hh; simp [Res.liftC] at hh
      | ill => rw [hd'] at hh; simp [Res.liftC] at hh

theorem reach_T {E : AState → Prop} {a : AState} {code : Code} {s : St} {hty : HTy}
    (hC : Cont sg np E a code) (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcode sh tsg Γ code = true) {c : Code × St} (hr : MReach (code, s) c) :
    mstep c ≠ some .ill ∧ ∀ k, mstep c ≠ some (.bad k) := by
  have key : ∀ (c0 c : Code × St), MReach c0 c → ∀ (a : AState) (hty : HTy),
      Cont sg np E a c0.1 → Inv ext a.ls c0.2 → TInv sh Γ hty a c0.2 → HU a →
      tcode sh tsg Γ c0.1 = true → mstep c ≠ some .ill ∧ ∀ k, mstep c ≠ some (.bad k) := by
    intro c0 c hr
    induction hr with
    | refl =>
      intro a hty hC hI hT hu ht
      refine ⟨?_, ?_⟩
      · rcases sound_stepT hC _ hty hI hT hu ht with hn | ⟨hi, _⟩
        · rw [hn]; intro h; cases h
        · exact hi
      · exact reach_safe hC hI (MReach.refl _)
    | step c1 c2 d h12 _ ih =>
      intro a hty hC hI hT hu ht
      rcases sound_stepT hC _ hty hI hT hu ht with hn | ⟨_, hok⟩
      · rw [hn] at h12; cases h12
      · have h12' : mstep c1 = some (.ok c2) := h12
        obtain ⟨a', hty', _, hC', hI', hT', hu', ht'⟩ := hok c2 h12'
        exact ih a' hty' hC' hI' hT' hu' ht'
  exact key _ _ hr a hty hC hI hT hu ht

end Orin
