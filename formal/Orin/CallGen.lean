import Orin.CallStep

/-!
# Call sites: the stack invariant with explicit witnesses

`StkI` (`CallRun.lean`) hides the data of a suspended call in existentials (the caller's abstract
kinds, the heap at the call).  This file states the same invariant with the call-site data as a
`Site` record that is pushed by the call step and popped by the return step, never changed in
between (`goodW_step`).  `GoodW` implies `Good` (`GoodW.good`).  It is the basis of
`CallLink.lean`, which derives the ownership contract `GenOK` of the interval analysis
(`RangeSem.lean`) from the return step.
-/

namespace Orin
open Heap

/-- Ghost record of one suspended call: the caller's anchors `extB`, its abstract kinds `b` just
before the call, the operands `args` with the callee's parameter modes `ps`, the caller's locals
`L0` and the heap `H0` at the call, and the accepted continuation (`np`, `E`, `a1`). -/
structure Site where
  extB : List Val
  b : List AS
  args : List Nat
  ps : List PM
  L0 : List Val
  H0 : Heap
  np : Nat
  E : AState → Prop
  a1 : AState

/-- the operands moved into owned parameters -/
def Site.own (s : Site) : List Nat := ownedArgs s.ps s.args

/-- the caller's kinds while the callee runs -/
def Site.mid (s : Site) : List AS := midK s.own s.b

def StkW (sg : List Sig) : List Val → List Frame → List Site → Heap → Prop
  | _, [], _, _ => True
  | _, _ :: _, [], _ => False
  | ext, fr :: rest, s :: ss, H =>
    ext = projL s.mid fr.L ++ s.extB ∧
    fr.L = clrL s.own s.L0 ∧
    Inv s.extB s.b ⟨s.H0, s.L0, []⟩ ∧
    s.args.length = s.ps.length ∧ s.own.Nodup ∧ fr.d < fr.L.length ∧
    (s.args.zip s.ps).all (argOK s.b s.own) = true ∧
    s.a1.ls = defK s.mid fr.d (retK fr.retRef) ∧
    Cont sg s.np s.E s.a1 fr.k ∧
    (∀ f' r', rest = f' :: r' → s.E = retPred f'.ret f'.retRef) ∧
    Frozen ext s.H0 H ∧
    StkW sg s.extB rest ss s.H0

theorem StkW.step {sg : List Sig} {ext : List Val} {stk : List Frame} {ss : List Site}
    {H H' : Heap} (h : StkW sg ext stk ss H) (hF : Frozen ext H H') : StkW sg ext stk ss H' := by
  cases stk with
  | nil => trivial
  | cons fr rest =>
    cases ss with
    | nil => exact absurd h (by simp [StkW])
    | cons s ss =>
      obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, hFz, hrest⟩ := h
      exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, hFz.trans hF, hrest⟩

/-- the explicit stack invariant implies `StkI` -/
theorem StkW.toStkI {sg : List Sig} :
    ∀ (stk : List Frame) {ext : List Val} {ss : List Site} {H : Heap},
      StkW sg ext stk ss H → StkI sg ext stk H
  | [], _, _, _, _ => trivial
  | fr :: rest, ext, ss, H, h => by
    cases ss with
    | nil => exact absurd h (by simp [StkW])
    | cons s ss =>
      obtain ⟨he, hL, hIb, hlen, hnd, hd, hargs, ha1, hk, hE, hFz, hrest⟩ := h
      have hmid := inv_prep hIb hnd (own_counted hargs)
      refine ⟨s.extB, s.mid, s.a1, s.np, s.E, s.H0, he, ?_, midK_ne_unique _ _, hd, ha1, hk, hE, hFz,
        StkW.toStkI rest hrest⟩
      rw [hL]
      exact hmid

/-- the call-machine invariant with explicit call sites -/
def GoodW (sg : List Sig) (ss : List Site) (stk : List Frame) (c : Code × St) : Prop :=
  ∃ (ext : List Val) (np : Nat) (E : AState → Prop) (a : AState),
    Cont sg np E a c.1 ∧ Inv ext a.ls c.2 ∧ StkW sg ext stk ss c.2.heap ∧
    (∀ fr rest, stk = fr :: rest → E = retPred fr.ret fr.retRef)

theorem GoodW.good {sg : List Sig} {ss : List Site} {stk : List Frame} {c : Code × St}
    (h : GoodW sg ss stk c) : Good sg stk c := by
  obtain ⟨ext, np, E, a, hC, hI, hS, hE⟩ := h
  exact ⟨ext, np, E, a, hC, hI, hS.toStkI stk, hE⟩

variable {fns : List Fn}

/-- how the ghost call-site list changes in one step -/
def SiteShape (c c' : Cfg2) (ss ss' : List Site) : Prop :=
  (c'.stk = c.stk ∧ ss' = ss) ∨
  (∃ (d f : Nat) (args : List Nat) (k : Code) (fn : Fn) (b : List AS) (s : Site),
    c.code = .call d f args k ∧ ss' = s :: ss ∧ s.b = b ∧ s.args = args ∧ s.ps = fn.params ∧
    s.L0 = c.st.locals ∧ s.H0 = c.st.heap ∧ c'.stk.length = c.stk.length + 1) ∨
  (∃ (fr : Frame) (rest : List Frame) (s : Site), c.stk = fr :: rest ∧ c'.stk = rest ∧ ss = s :: ss')

theorem goodW_step_gen {sg : List Sig} {np : Nat} {E : AState → Prop} {a : AState} {code : Code}
    {ext : List Val} {stk : List Frame} {ss : List Site} {st : St}
    (hC : Cont sg np E a code) (hI : Inv ext a.ls st) (hS : StkW sg ext stk ss st.heap)
    (hE : ∀ fr rest, stk = fr :: rest → E = retPred fr.ret fr.retRef)
    (hcs : cstep fns ⟨stk, code, st⟩ = (mstep (code, st)).map (Res.liftS stk)) :
    cstep fns ⟨stk, code, st⟩ = none ∨ ∃ r, cstep fns ⟨stk, code, st⟩ = some r ∧
      (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → c'.stk = stk ∧ GoodW sg ss c'.stk (c'.code, c'.st) := by
  rcases sound_step (ext := ext) hC hI with hn | ⟨r, hr, hnb, hok⟩
  · left; rw [hcs, hn]; rfl
  · right
    refine ⟨Res.liftS stk r, by rw [hcs, hr]; rfl, ?_, ?_⟩
    · intro k hh
      exact hnb k (liftS_bad hh)
    · intro c' hc'
      cases r with
      | ok c =>
        simp only [Res.liftS, Res.ok.injEq] at hc'
        subst hc'
        obtain ⟨a', hC', hI'⟩ := hok c rfl
        have hF := frozen_step hC hI (c' := c) hr
        exact ⟨rfl, ext, np, E, a', hC', hI', hS.step hF, hE⟩
      | trap => simp [Res.liftS] at hc'
      | bad _ => simp [Res.liftS] at hc'
      | ill => simp [Res.liftS] at hc'

theorem goodW_step (hp : pcheck fns = true) {c : Cfg2} {ss : List Site}
    (hG : GoodW (fns.map Fn.sig) ss c.stk (c.code, c.st)) :
    cstep fns c = none ∨ ∃ r, cstep fns c = some r ∧ (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → ∃ ss', GoodW (fns.map Fn.sig) ss' c'.stk (c'.code, c'.st) ∧
        SiteShape c c' ss ss' := by
  obtain ⟨stk, code, st⟩ := c
  obtain ⟨ext, np, E, a, hC, hI, hS, hE⟩ := hG
  simp only at hC hI hS hE
  have gen : ∀ (hcs : cstep fns ⟨stk, code, st⟩ = (mstep (code, st)).map (Res.liftS stk)),
      cstep fns ⟨stk, code, st⟩ = none ∨ ∃ r, cstep fns ⟨stk, code, st⟩ = some r ∧
        (∀ k, r ≠ .bad k) ∧ ∀ c', r = .ok c' → ∃ ss', GoodW (fns.map Fn.sig) ss' c'.stk (c'.code, c'.st) ∧
          SiteShape ⟨stk, code, st⟩ c' ss ss' := by
    intro hcs
    rcases goodW_step_gen (fns := fns) hC hI hS hE hcs with h | ⟨r, hr, hnb, hok⟩
    · exact Or.inl h
    · refine Or.inr ⟨r, hr, hnb, fun c' hc' => ?_⟩
      obtain ⟨h1, h2⟩ := hok c' hc'
      exact ⟨ss, h2, Or.inl ⟨h1, rfl⟩⟩
  by_cases hpend : st.pending = []
  · cases code with
    | op i k => exact gen (by simp [cstep, hpend])
    | ite c t e k => exact gen (by simp [cstep, hpend])
    | loop c t k => exact gen (by simp [cstep, hpend])
    | nil =>
      cases stk with
      | nil => left; simp [cstep, hpend, retStep]
      | cons fr rest =>
        right
        cases ss with
        | nil => exact absurd hS (by simp [StkW])
        | cons s ss0 =>
        obtain ⟨b, hbE, hweak⟩ := Cont.nil_inv hC
        have hEr := hE fr rest rfl
        subst hEr
        have hIb := hweak ext st hI
        obtain ⟨he, hL, hIB0, hlen, hnd, hd, hargs, ha, hk, hE1, hFz, hrest⟩ := hS
        have hIB := inv_prep hIB0 hnd (own_counted hargs)
        rw [← hL] at hIB
        have hret : fr.ret < st.locals.length := hIb.len ▸ hbE.1
        have hcs : cstep fns ⟨fr :: rest, .nil, st⟩ =
            some (.ok ⟨rest, fr.k, ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩⟩) := by
          simp [cstep, hpend, retStep, hd, hret]
        refine ⟨_, hcs, ?_, fun c' hc' => ?_⟩
        · intro k hh; cases hh
        cases hc'
        refine ⟨ss0, ⟨s.extB, s.np, s.E, s.a1, hk, ?_, ?_, hE1⟩, Or.inr (Or.inr ⟨fr, rest, s, rfl, rfl, rfl⟩)⟩
        · show Inv s.extB s.a1.ls ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩
          rw [ha]
          have he' : ext = projL s.mid fr.L ++ s.extB := he
          rw [he'] at hIb hFz
          exact inv_ret hIB (midK_ne_unique _ _) hd hIb hpend rfl hFz hbE
        · exact StkW.step hrest (hFz.mono (fun v hv => by rw [he]; exact List.mem_append_right _ hv))
    | call d f args k =>
      right
      obtain ⟨b, a1, hstep, hk, hweak⟩ := Cont.call_inv hC
      have hIb := hweak ext st hI
      obtain ⟨sig, hsig, hlen, hdb, hnd, hargs, ha1⟩ := stepAC_spec hstep
      obtain ⟨fn, hf, hsigfn⟩ : ∃ fn, fns[f]? = some fn ∧ sig = fn.sig := by
        simp only [List.getElem?_map] at hsig
        cases h : fns[f]? with
        | none => rw [h] at hsig; simp at hsig
        | some fn => rw [h] at hsig; exact ⟨fn, rfl, (Option.some.inj hsig).symm⟩
      subst hsigfn
      have hfc : fcheck (fns.map Fn.sig) fn = true := by
        unfold pcheck at hp
        exact List.all_eq_true.mp hp fn (List.mem_of_getElem? hf)
      obtain ⟨hpn, hcontF⟩ := fcheck_cont hfc
      have hdl : d < st.locals.length := hIb.len ▸ hdb
      have hlt : ∀ j ∈ args, j < st.locals.length :=
        fun j hj => hIb.len ▸ args_lt hlen hargs j hj
      have hent := inv_entry hIb hpend hlen hpn hnd hargs
      obtain ⟨hh, ll, pp⟩ := st
      simp only at hpend
      subst hpend
      have hcs : cstep fns ⟨stk, .call d f args k, ⟨hh, ll, []⟩⟩ =
          some (.ok ⟨⟨k, clrL (ownedArgs fn.params args) ll, d, fn.ret, fn.retRef⟩ :: stk,
            fn.code, ⟨hh, calleeLocals (args.map (St.get ⟨hh, ll, []⟩)) fn.n, []⟩⟩) := by
        simp [cstep, callStep, hf]
        exact ⟨hlen, hdl, hlt, hpn, hnd⟩
      refine ⟨_, hcs, ?_, fun c' hc' => ?_⟩
      · intro k hh; cases hh
      cases hc'
      refine ⟨⟨ext, b.ls, args, fn.params, ll, hh, np, E, a1⟩ :: ss, ⟨_, fn.params.length, retPred fn.ret fn.retRef, fn.entry, hcontF, hent, ?_, ?_⟩, ?_⟩
      · refine ⟨rfl, rfl, hIb, hlen, hnd, by simpa [clrL_length] using hdl, hargs, ha1, hk, hE, Frozen.refl _, hS⟩
      · intro fr' rest' h; cases h; rfl
      · exact Or.inr (Or.inl ⟨d, f, args, k, fn, b.ls, _, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩)
  · obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, st.pending = hd :: rest := by
      cases h : st.pending with
      | nil => exact absurd h hpend
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    exact gen (by simp [cstep, hpe])

theorem goodW_reach (hp : pcheck fns = true) {c d : Cfg2} {ss : List Site}
    (hG : GoodW (fns.map Fn.sig) ss c.stk (c.code, c.st)) (hr : CReach fns c d) :
    ∃ ss', GoodW (fns.map Fn.sig) ss' d.stk (d.code, d.st) := by
  induction hr generalizing ss with
  | refl => exact ⟨ss, hG⟩
  | step c c' d h _ ih =>
    rcases goodW_step hp hG with hn | ⟨r, hr, _, hok⟩
    · rw [hn] at h; cases h
    · rw [hr] at h
      cases h
      obtain ⟨ss', hG', _⟩ := hok _ rfl
      exact ih hG'

end Orin
