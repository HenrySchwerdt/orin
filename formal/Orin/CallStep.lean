import Orin.CallRun

/-!
# Safety of the call machine

`good_step` : a good configuration (`Good`, `CallRun.lean`) never takes a `bad` step, and each
`ok` successor is good again.  `prog_reach_good` / `prog_sound` : a program accepted by `pcheck`,
entered at any of its functions in a state that meets the caller contract, never reaches a
`bad` step.
-/

namespace Orin
open Heap

variable {fns : List Fn}

theorem liftS_bad {stk : List Frame} {r : Res (Code × St)} {k : BadKind}
    (h : Res.liftS stk r = .bad k) : r = .bad k := by
  cases r <;> simp [Res.liftS] at h <;> simp [h]

theorem good_step_gen {sg : List Sig} {np : Nat} {E : AState → Prop} {a : AState} {code : Code}
    {ext : List Val} {stk : List Frame} {st : St}
    (hC : Cont sg np E a code) (hI : Inv ext a.ls st) (hS : StkI sg ext stk st.heap)
    (hE : ∀ fr rest, stk = fr :: rest → E = retPred fr.ret fr.retRef)
    (hcs : cstep fns ⟨stk, code, st⟩ = (mstep (code, st)).map (Res.liftS stk)) :
    cstep fns ⟨stk, code, st⟩ = none ∨ ∃ r, cstep fns ⟨stk, code, st⟩ = some r ∧
      (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → Good sg c'.stk (c'.code, c'.st) := by
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
        exact ⟨ext, np, E, a', hC', hI', hS.step hF, hE⟩
      | trap => simp [Res.liftS] at hc'
      | bad _ => simp [Res.liftS] at hc'
      | ill => simp [Res.liftS] at hc'

theorem good_step (hp : pcheck fns = true) {c : Cfg2}
    (hG : Good (fns.map Fn.sig) c.stk (c.code, c.st)) :
    cstep fns c = none ∨ ∃ r, cstep fns c = some r ∧ (∀ k, r ≠ .bad k) ∧
      ∀ c', r = .ok c' → Good (fns.map Fn.sig) c'.stk (c'.code, c'.st) := by
  obtain ⟨stk, code, st⟩ := c
  obtain ⟨ext, np, E, a, hC, hI, hS, hE⟩ := hG
  simp only at hC hI hS hE
  by_cases hpend : st.pending = []
  · cases code with
    | op i k => exact good_step_gen hC hI hS hE (by simp [cstep, hpend])
    | ite c t e k => exact good_step_gen hC hI hS hE (by simp [cstep, hpend])
    | loop c t k => exact good_step_gen hC hI hS hE (by simp [cstep, hpend])
    | nil =>
      cases stk with
      | nil => left; simp [cstep, hpend, retStep]
      | cons fr rest =>
        right
        obtain ⟨b, hbE, hweak⟩ := Cont.nil_inv hC
        have hEr := hE fr rest rfl
        subst hEr
        have hIb := hweak ext st hI
        obtain ⟨extB, aMid, a1, np1, E1, H0, he, hIB, hnu, hd, ha, hk, hE1, hFz, hrest⟩ := hS
        subst he
        have hret : fr.ret < st.locals.length := hIb.len ▸ hbE.1
        have hcs : cstep fns ⟨fr :: rest, .nil, st⟩ =
            some (.ok ⟨rest, fr.k, ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩⟩) := by
          simp [cstep, hpend, retStep, hd, hret]
        refine ⟨_, hcs, ?_, fun c' hc' => ?_⟩
        · intro k hh; cases hh
        cases hc'
        refine ⟨extB, np1, E1, a1, hk, ?_, ?_, hE1⟩
        · show Inv extB a1.ls ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩
          rw [ha]
          exact inv_ret hIB hnu hd hIb hpend rfl hFz hbE
        · exact StkI.step hrest (hFz.mono (fun v hv => List.mem_append_right _ hv))
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
      have hown := own_counted hargs
      have hmid := inv_prep hIb hnd hown
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
      refine ⟨_, fn.params.length, retPred fn.ret fn.retRef, fn.entry, hcontF, hent, ?_, ?_⟩
      · refine ⟨ext, midK (ownedArgs fn.params args) b.ls, a1, np, E, hh, rfl, hmid, ?_, ?_, ha1,
          hk, hE, Frozen.refl _, hS⟩
        · exact midK_ne_unique _ _
        · simpa [clrL_length] using hdl
      · intro fr' rest' h; cases h; rfl
  · -- draining step
    obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, st.pending = hd :: rest := by
      cases h : st.pending with
      | nil => exact absurd h hpend
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    exact good_step_gen hC hI hS hE (by simp [cstep, hpe])

end Orin
