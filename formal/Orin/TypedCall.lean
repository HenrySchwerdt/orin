import Orin.TypedTop
import Orin.CallExamples
import Orin.CallTop

/-!
# Typed calls: no `ill` in a program with calls

`tcode` (`Typed.lean`) accepts `call d f args k` against the typed signature `tsg[f]` (parameter
types, result type).  A *typed program* is a list of functions `fns` together with one local-type
list `Γ` per function (`gs`): `tpcheck` is `pcheck` (ownership) plus, for every function, the type
pass on its body against the signatures `tsigs fns gs` derived from the `Γ` lists, and three
static facts that tie modes to types (a scalar parameter is an `int`, a function that returns a
scalar has an `int` result local, the result local is typed).

The proof reuses the structure of `CallStep.lean`: `GoodT` is `Good` plus the type invariant `TInv`
of the running frame and a typed copy of the stack invariant, `StkIT`: every suspended caller
remembers its local types `Γc`, that its locals are still typed w.r.t. the *current* ghost typing
and heap (the typing only grows, `HyExt`), the type pass on its continuation, and that the
result type of the callee is the type of the destination.  A call needs an empty hole set, so a
callee starts with no null reference slot in the heap (`hnull`), and a function returns with no open
hole (`retPredH`), so the caller resumes with none either.
-/

namespace Orin
open Heap

/-! ### acceptance derivation: weakening-closed predicates -/

section inv
variable {sg : List Sig} {np : Nat} {E : AState → Prop} {a : AState}

/-- a predicate closed under the weakening order `FleS` holds at the end state as well -/
theorem Cont.nil_invP (h : Cont sg np E a .nil) :
    ∃ b, E b ∧ ∀ P : AState → Prop, (∀ x y, FleS x y → P x → P y) → P a → P b := by
  generalize hc : Code.nil = code at h
  induction h with
  | nil hE => cases hc; exact ⟨_, hE, fun _ _ h => h⟩
  | op _ _ _ => cases hc
  | ite _ _ _ _ _ _ => cases hc
  | loop _ _ _ _ _ _ _ => cases hc
  | call _ _ _ => cases hc
  | weak hF _ ih =>
    obtain ⟨b, hb, hi⟩ := ih hc
    exact ⟨b, hb, fun P hm hP => hi P hm (hm _ _ hF hP)⟩

theorem Cont.call_invP {d f : Nat} {args : List Nat} {k : Code}
    (h : Cont sg np E a (.call d f args k)) :
    ∃ b a1, stepAC np sg b d f args = some a1 ∧ Cont sg np E a1 k ∧
      ∀ P : AState → Prop, (∀ x y, FleS x y → P x → P y) → P a → P b := by
  generalize hc : Code.call d f args k = code at h
  induction h with
  | nil _ => cases hc
  | op _ _ _ => cases hc
  | ite _ _ _ _ _ _ => cases hc
  | loop _ _ _ _ _ _ _ => cases hc
  | call hs hk _ => cases hc; exact ⟨_, _, hs, hk, fun _ _ h => h⟩
  | weak hF _ ih =>
    obtain ⟨b, a1, hs, hk, hi⟩ := ih hc
    exact ⟨b, a1, hs, hk, fun P hm hP => hi P hm (hm _ _ hF hP)⟩

end inv

/-- end condition of a function: the result local is ready and no hole is open -/
def retPredH (r : Nat) (rr : Bool) (x : AState) : Prop := retPred r rr x ∧ x.holes = []

theorem fcheck_contH {sg : List Sig} {f : Fn} (h : fcheck sg f = true) :
    f.params.length ≤ f.n ∧
      Cont sg f.params.length (retPredH f.ret f.retRef) f.entry f.code := by
  unfold fcheck at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  obtain ⟨hn, hm⟩ := h
  refine ⟨hn, ?_⟩
  cases hc : chk f.params.length sg f.entry f.code with
  | none => rw [hc] at hm; simp at hm
  | some af =>
    rw [hc] at hm
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hm
    have h1 := chk_cont (np := f.params.length) (sg := sg) f.code f.entry af .nil
      (retPredH f.ret f.retRef) (HU_nil _) hc (Cont.nil ⟨hm.2, List.isEmpty_iff.mp hm.1⟩)
    rwa [Code.app_nil] at h1

theorem stepAC_holes {np : Nat} {sg : List Sig} {b a1 : AState} {d f : Nat} {args : List Nat}
    (h : stepAC np sg b d f args = some a1) : b.holes = [] ∧ a1.holes = [] := by
  unfold stepAC at h
  cases hc : stepCall sg np b.ls d f args with
  | none => rw [hc] at h; simp at h
  | some ls' =>
    rw [hc] at h
    simp only at h
    split at h
    · rename_i he
      cases h
      exact ⟨List.isEmpty_iff.mp he, List.isEmpty_iff.mp he⟩
    · cases h

/-! ### typed programs -/

/-- the typed signature of a function from its local types -/
def tsigOf (fn : Fn) (Γ : List Ty) : TSig := ⟨Γ.take fn.params.length, (Γ[fn.ret]?).getD .int⟩

def tsigs (fns : List Fn) (gs : List (List Ty)) : List TSig := List.zipWith tsigOf fns gs

/-- one function against its local types `Γ` and the typed signatures `tsg` of all functions -/
def tfcheck (sh : Shapes) (tsg : List TSig) (fn : Fn) (Γ : List Ty) : Bool :=
  tcode sh tsg Γ fn.code &&
  (List.range fn.params.length).all (fun (i : Nat) =>
    match fn.params[i]? with
    | some .scalar => decide (Γ[i]? = some .int)
    | _ => true) &&
  (fn.retRef || decide (Γ[fn.ret]? = some .int)) &&
  (Γ[fn.ret]?).isSome

/-- a typed program: ownership check (`pcheck`) and the type pass for every function -/
def tpcheck (sh : Shapes) (fns : List Fn) (gs : List (List Ty)) : Bool :=
  pcheck fns && decide (gs.length = fns.length) &&
    (List.zipWith (tfcheck sh (tsigs fns gs)) fns gs).all id

theorem tfcheck_spec {sh : Shapes} {tsg : List TSig} {fn : Fn} {Γ : List Ty}
    (h : tfcheck sh tsg fn Γ = true) :
    tcode sh tsg Γ fn.code = true ∧
    (∀ i : Nat, fn.params[i]? = some PM.scalar → Γ[i]? = some Ty.int) ∧
    (fn.retRef = false → Γ[fn.ret]? = some Ty.int) ∧ (Γ[fn.ret]?).isSome = true := by
  unfold tfcheck at h
  simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, List.all_eq_true] at h
  obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := h
  refine ⟨h1, fun i hi => ?_, fun hr => ?_, h4⟩
  · have hlt : i < fn.params.length := (List.getElem?_eq_some_iff.mp hi).1
    have := h2 i (List.mem_range.mpr hlt)
    rw [hi] at this
    simpa using this
  · rcases h3 with h3 | h3
    · rw [hr] at h3; cases h3
    · exact h3

theorem tsigs_get {fns : List Fn} {gs : List (List Ty)} {f : Nat} {ts : TSig}
    (h : (tsigs fns gs)[f]? = some ts) :
    ∃ fn Γ, fns[f]? = some fn ∧ gs[f]? = some Γ ∧ ts = tsigOf fn Γ := by
  unfold tsigs at h
  rw [List.getElem?_zipWith] at h
  cases h1 : fns[f]? with
  | none => rw [h1] at h; simp at h
  | some fn =>
    cases h2 : gs[f]? with
    | none => rw [h1, h2] at h; simp at h
    | some Γ =>
      rw [h1, h2] at h
      exact ⟨fn, Γ, rfl, rfl, (Option.some.inj h).symm⟩

theorem tpcheck_fn {sh : Shapes} {fns : List Fn} {gs : List (List Ty)} {f : Nat} {fn : Fn}
    {Γ : List Ty} (h : tpcheck sh fns gs = true) (hf : fns[f]? = some fn) (hg : gs[f]? = some Γ) :
    pcheck fns = true ∧ tfcheck sh (tsigs fns gs) fn Γ = true := by
  unfold tpcheck at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  refine ⟨h.1.1, ?_⟩
  have hm : tfcheck sh (tsigs fns gs) fn Γ ∈
      List.zipWith (tfcheck sh (tsigs fns gs)) fns gs := by
    refine List.mem_iff_getElem?.mpr ⟨f, ?_⟩
    rw [List.getElem?_zipWith, hf, hg]
  exact List.all_eq_true.mp h.2 _ hm

/-! ### the type invariant at function entry -/

theorem getD_calleeLocals_ge (vals : List Val) (n j : Nat) (h : vals.length ≤ j) :
    (calleeLocals vals n).getD j (.int 0) = .int 0 := by
  simp only [calleeLocals, List.getD_eq_getElem?_getD]
  rw [List.getElem?_append_right h, List.getElem?_replicate]
  split <;> simp

theorem entryFn_tinv (fn : Fn) (sh : Shapes) (Γ : List Ty) (hty : HTy) (H : Heap)
    (vals : List Val) (hlen : vals.length = fn.params.length)
    (hkt : ∀ i : Nat, fn.params[i]? = some PM.scalar → Γ[i]? = some Ty.int)
    (hvals : ∀ x τ, Γ[x]? = some τ → x < fn.params.length →
      VT hty H τ (vals.getD x (Val.int 0)))
    (hobj : ∀ l o, H.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty H τ o.fields)
    (hnull : ∀ l o t ts (i : Nat), H.objs l = some o → hty l = some (.st t) → sh[t]? = some ts →
      (∃ τ', ts[i]? = some τ' ∧ τ' ≠ Ty.int) → o.fields[i]? ≠ some (Val.int 0)) :
    TInv sh Γ hty fn.entry (initFn fn H vals) := by
  refine ⟨fun x τ hx => ?_, hobj, fun l o t ts i ho ht hts hτ hf => ?_, fun x hx => ?_⟩
  · by_cases hxp : x < fn.params.length
    · have := hvals x τ hx hxp
      have hg : (initFn fn H vals).get x = vals.getD x (Val.int 0) :=
        getD_calleeLocals vals fn.n x (by omega)
      rw [hg]; exact this
    · have hg : (initFn fn H vals).get x = Val.int 0 :=
        getD_calleeLocals_ge vals fn.n x (by omega)
      rw [hg]
      exact VT_zero _ _ _
  · exact absurd hf (hnull l o t ts i ho ht hts hτ)
  · have hk : gk fn.entry.ls x = match fn.params[x]? with | some m => modeK m | none => .dead :=
      gk_entryLs fn.params fn.n x
    cases hpx : fn.params[x]? with
    | none => rw [hpx] at hk; rw [hk] at hx; cases hx
    | some m =>
      rw [hpx] at hk
      rw [hk] at hx
      cases m with
      | scalar => exact hkt x hpx
      | borrowed => cases hx
      | owned => cases hx

/-! ### the typed stack invariant -/

/-- `StkIT sg tsg sh ext Γ stk H hty Hc`: `StkI` (ownership, anchored at `H`) together with the
typing facts about every suspended caller, w.r.t. the current ghost typing `hty` and heap `Hc`;
`Γ` = the local types of the running function. -/
def StkIT (sg : List Sig) (tsg : List TSig) (sh : Shapes) :
    List Val → List Ty → List Frame → Heap → HTy → Heap → Prop
  | _, _, [], _, _, _ => True
  | ext, Γ, fr :: rest, H, hty, Hc =>
    ∃ (extB : List Val) (aMid : List AS) (a1 : AState) (np : Nat) (E : AState → Prop)
      (H0 : Heap) (Γc : List Ty),
      ext = projL aMid fr.L ++ extB ∧
      Inv extB aMid ⟨H0, fr.L, []⟩ ∧ (∀ i, gk aMid i ≠ .unique) ∧ fr.d < fr.L.length ∧
      a1.ls = defK aMid fr.d (retK fr.retRef) ∧ a1.holes = [] ∧
      Cont sg np E a1 fr.k ∧
      (∀ f' r', rest = f' :: r' → E = retPredH f'.ret f'.retRef) ∧
      Frozen ext H0 H ∧
      tcode sh tsg Γc fr.k = true ∧ KT Γc a1.ls ∧
      (∀ x τ, Γc[x]? = some τ → VT hty Hc τ (fr.L.getD x (.int 0))) ∧
      Γ[fr.ret]? = Γc[fr.d]? ∧ (Γc[fr.d]?).isSome = true ∧
      StkIT sg tsg sh extB Γc rest H0 hty Hc

/-- the typing only grows -/
theorem StkIT.ty {sg : List Sig} {tsg : List TSig} {sh : Shapes} :
    ∀ (stk : List Frame) {ext : List Val} {Γ : List Ty} {H : Heap} {hty hty' : HTy}
      {Hc Hc' : Heap}, StkIT sg tsg sh ext Γ stk H hty Hc → HyExt hty hty' Hc Hc' →
      StkIT sg tsg sh ext Γ stk H hty' Hc'
  | [], _, _, _, _, _, _, _, _, _ => trivial
  | fr :: rest, ext, Γ, H, hty, hty', Hc, Hc', h, hx => by
    obtain ⟨extB, aMid, a1, np, E, H0, Γc, he, hI, hnu, hd, ha, hah, hk, hE, hFz, htk, hKT, hLT,
      hΓr, hΓs, hrest⟩ := h
    exact ⟨extB, aMid, a1, np, E, H0, Γc, he, hI, hnu, hd, ha, hah, hk, hE, hFz, htk, hKT,
      fun x τ hx' => VT_mono hx (hLT x τ hx'), hΓr, hΓs, StkIT.ty rest hrest hx⟩

/-- nothing the anchors reach changed -/
theorem StkIT.frz {sg : List Sig} {tsg : List TSig} {sh : Shapes} {ext : List Val}
    {Γ : List Ty} {stk : List Frame} {H H' : Heap} {hty : HTy} {Hc : Heap}
    (h : StkIT sg tsg sh ext Γ stk H hty Hc) (hF : Frozen ext H H') :
    StkIT sg tsg sh ext Γ stk H' hty Hc := by
  cases stk with
  | nil => trivial
  | cons fr rest =>
    obtain ⟨extB, aMid, a1, np, E, H0, Γc, he, hI, hnu, hd, ha, hah, hk, hE, hFz, htk, hKT, hLT,
      hΓr, hΓs, hrest⟩ := h
    exact ⟨extB, aMid, a1, np, E, H0, Γc, he, hI, hnu, hd, ha, hah, hk, hE, hFz.trans hF, htk,
      hKT, hLT, hΓr, hΓs, hrest⟩

/-- The typed ghost invariant of a configuration. -/
def GoodT (sg : List Sig) (tsg : List TSig) (sh : Shapes) (stk : List Frame) (c : Code × St) :
    Prop :=
  ∃ (ext : List Val) (np : Nat) (E : AState → Prop) (a : AState) (Γ : List Ty) (hty : HTy),
    Cont sg np E a c.1 ∧ Inv ext a.ls c.2 ∧ TInv sh Γ hty a c.2 ∧ HU a ∧
    tcode sh tsg Γ c.1 = true ∧ StkIT sg tsg sh ext Γ stk c.2.heap hty c.2.heap ∧
    (∀ fr rest, stk = fr :: rest → E = retPredH fr.ret fr.retRef)


/-! ### lemmas for the return and the call -/

theorem liftS_ill {stk : List Frame} {r : Res (Code × St)} (h : Res.liftS stk r = .ill) :
    r = .ill := by
  cases r with
  | ill => rfl
  | ok c => simp [Res.liftS] at h
  | trap => simp [Res.liftS] at h
  | bad _ => simp [Res.liftS] at h

/-- the caller resumes with its locals typed, the result in its destination -/
theorem tinv_ret {sh : Shapes} {Γ Γc : List Ty} {hty : HTy} {a1 b : AState} {st : St}
    {L : List Val} {d r : Nat}
    (hTb : TInv sh Γ hty b st) (hbh : b.holes = []) (hkt : KT Γc a1.ls)
    (hLT : ∀ x τ, Γc[x]? = some τ → VT hty st.heap τ (L.getD x (.int 0)))
    (hd : d < L.length) (hr : Γ[r]? = Γc[d]?) :
    TInv sh Γc hty a1 ⟨st.heap, L.set d (st.get r), []⟩ := by
  refine ⟨fun x τ hx => ?_, hTb.obj, fun l o t ts i ho ht hts hτ hf => ?_, hkt⟩
  · show VT hty st.heap τ ((L.set d (st.get r)).getD x (.int 0))
    by_cases hxd : x = d
    · subst hxd
      have : (L.set x (st.get r)).getD x (.int 0) = st.get r := by
        simp [List.getD_eq_getElem?_getD, hd]
      rw [this]
      exact hTb.loc r τ (by rw [hr]; exact hx)
    · rw [getD_set_ne L d x _ (Ne.symm hxd)]
      exact hLT x τ hx
  · obtain ⟨x, hx, _⟩ := hTb.hole l o t ts i ho ht hts hτ hf
    rw [hbh] at hx; cases hx

theorem KT_midK {Γ : List Ty} {own : List Nat} {a : List AS} (hk : KT Γ a) :
    KT Γ (midK own a) := by
  intro x hx
  rw [gk_midK] at hx
  by_cases hm : x ∈ own
  · simp [hm] at hx
  · simp only [hm, if_false] at hx
    have h' : gk a x = .init := by
      cases hg : gk a x with
      | borrowed r => by_cases hr : r ∈ own <;> simp [hg, hr] at hx
      | _ => simp [hg] at hx ⊢
    exact hk x h'

theorem call_arg_ty {Γ Γf : List Ty} {n : Nat} {args : List Nat} (hlen : args.length = n)
    (hArgs : args.map (fun j => Γ[j]?) = (Γf.take n).map some) {x : Nat} (hx : x < n) :
    ∃ j, args[x]? = some j ∧ Γ[j]? = Γf[x]? := by
  have hxa : x < args.length := by omega
  refine ⟨args[x], List.getElem?_eq_getElem hxa, ?_⟩
  have h1 := congrArg (fun l => l[x]?) hArgs
  simp [List.getElem?_map, List.getElem?_take, hx, hxa] at h1
  cases h2 : Γf[x]? with
  | none => rw [h2] at h1; simp at h1
  | some τ => rw [h2] at h1; exact Option.some.inj h1

/-! ### one step -/

variable {fns : List Fn} {gs : List (List Ty)} {sh : Shapes}

theorem good_step_genT {sg : List Sig} {tsg : List TSig} {np : Nat} {E : AState → Prop}
    {a : AState} {code : Code} {ext : List Val} {stk : List Frame} {st : St} {Γ : List Ty}
    {hty : HTy}
    (hC : Cont sg np E a code) (hI : Inv ext a.ls st) (hT : TInv sh Γ hty a st) (hu : HU a)
    (ht : tcode sh tsg Γ code = true) (hS : StkIT sg tsg sh ext Γ stk st.heap hty st.heap)
    (hE : ∀ fr rest, stk = fr :: rest → E = retPredH fr.ret fr.retRef)
    (hcs : cstep fns ⟨stk, code, st⟩ = (mstep (code, st)).map (Res.liftS stk)) :
    cstep fns ⟨stk, code, st⟩ = none ∨ ∃ r, cstep fns ⟨stk, code, st⟩ = some r ∧
      (∀ k, r ≠ .bad k) ∧ r ≠ .ill ∧
      ∀ c', r = .ok c' → GoodT sg tsg sh c'.stk (c'.code, c'.st) := by
  rcases sound_step (ext := ext) hC hI with hn | ⟨r, hr, hnb, _⟩
  · left; rw [hcs, hn]; rfl
  · rcases sound_stepT (ext := ext) hC st hty hI hT hu ht with hn | ⟨hnill, hok⟩
    · rw [hr] at hn; cases hn
    · right
      refine ⟨Res.liftS stk r, by rw [hcs, hr]; rfl, ?_, ?_, ?_⟩
      · intro k hh; exact hnb k (liftS_bad hh)
      · intro hh; exact hnill (by rw [hr, liftS_ill hh])
      · intro c' hc'
        cases r with
        | ok c =>
          simp only [Res.liftS, Res.ok.injEq] at hc'
          subst hc'
          obtain ⟨a', hty', hex, hC', hI', hT', hu', ht'⟩ := hok c hr
          have hF := frozen_step hC hI (c' := c) hr
          exact ⟨ext, np, E, a', Γ, hty', hC', hI', hT', hu', ht',
            StkIT.ty stk (hS.frz hF) hex, hE⟩
        | trap => simp [Res.liftS] at hc'
        | bad _ => simp [Res.liftS] at hc'
        | ill => simp [Res.liftS] at hc'

theorem good_stepT (htp : tpcheck sh fns gs = true) {c : Cfg2}
    (hG : GoodT (fns.map Fn.sig) (tsigs fns gs) sh c.stk (c.code, c.st)) :
    cstep fns c = none ∨ ∃ r, cstep fns c = some r ∧ (∀ k, r ≠ .bad k) ∧ r ≠ .ill ∧
      ∀ c', r = .ok c' → GoodT (fns.map Fn.sig) (tsigs fns gs) sh c'.stk (c'.code, c'.st) := by
  have hp : pcheck fns = true := by
    unfold tpcheck at htp
    simp only [Bool.and_eq_true, decide_eq_true_eq] at htp
    exact htp.1.1
  obtain ⟨stk, code, st⟩ := c
  obtain ⟨ext, np, E, a, Γ, hty, hC, hI, hT, hu, ht, hS, hE⟩ := hG
  simp only at hC hI hT ht hS hE
  by_cases hpend : st.pending = []
  · cases code with
    | op i k => exact good_step_genT hC hI hT hu ht hS hE (by simp [cstep, hpend])
    | ite c t e k => exact good_step_genT hC hI hT hu ht hS hE (by simp [cstep, hpend])
    | loop c t k => exact good_step_genT hC hI hT hu ht hS hE (by simp [cstep, hpend])
    | nil =>
      cases stk with
      | nil => left; simp [cstep, hpend, retStep]
      | cons fr rest =>
        right
        obtain ⟨⟨bls, bh⟩, hbE, hP⟩ := Cont.nil_invP hC
        have hEr := hE fr rest rfl
        subst hEr
        obtain ⟨hb1, hb2⟩ := hbE
        simp only at hb2
        subst hb2
        obtain ⟨hIb, hTb⟩ := hP (fun x => Inv ext x.ls st ∧ TInv sh Γ hty x st)
          (fun x y hF h => ⟨h.1.weaken hF.1, h.2.weaken hF⟩) ⟨hI, hT⟩
        obtain ⟨extB, aMid, a1, np1, E1, H0, Γc, he, hIB, hnu, hd, ha, hah, hk, hE1, hFz, htk,
          hKT, hLT, hΓr, hΓs, hrest⟩ := hS
        subst he
        have hret : fr.ret < st.locals.length := hIb.len ▸ hb1.1
        have hcs : cstep fns ⟨fr :: rest, .nil, st⟩ =
            some (.ok ⟨rest, fr.k, ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩⟩) := by
          simp [cstep, hpend, retStep, hd, hret]
        refine ⟨_, hcs, ?_, ?_, fun c' hc' => ?_⟩
        · intro k hh; cases hh
        · intro hh; cases hh
        cases hc'
        refine ⟨extB, np1, E1, a1, Γc, hty, hk, ?_, ?_, ?_, htk, ?_, hE1⟩
        · show Inv extB a1.ls ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩
          rw [ha]
          exact inv_ret hIB hnu hd hIb hpend rfl hFz hb1
        · exact tinv_ret hTb rfl hKT hLT hd hΓr
        · intro p hp; rw [hah] at hp; cases hp
        · exact hrest.frz (hFz.mono (fun v hv => List.mem_append_right _ hv))
    | call d f args k =>
      right
      obtain ⟨b, a1, hstep, hk, hP⟩ := Cont.call_invP hC
      obtain ⟨hIb, hTb⟩ := hP (fun x => Inv ext x.ls st ∧ TInv sh Γ hty x st)
        (fun x y hF h => ⟨h.1.weaken hF.1, h.2.weaken hF⟩) ⟨hI, hT⟩
      obtain ⟨hbh, hah1⟩ := stepAC_holes hstep
      obtain ⟨sig, hsig, hlen, hdb, hnd, hargs, ha1⟩ := stepAC_spec hstep
      obtain ⟨fn, hf, hsigfn⟩ : ∃ fn, fns[f]? = some fn ∧ sig = fn.sig := by
        simp only [List.getElem?_map] at hsig
        cases h : fns[f]? with
        | none => rw [h] at hsig; simp at hsig
        | some fn => rw [h] at hsig; exact ⟨fn, rfl, (Option.some.inj hsig).symm⟩
      subst hsigfn
      -- the type pass at the call
      simp only [tcode] at ht
      obtain ⟨ts, hts, htc⟩ : ∃ ts, (tsigs fns gs)[f]? = some ts ∧
          (decide (args.map (fun j => Γ[j]?) = ts.ptys.map some ∧ Γ[d]? = some ts.rty) &&
            tcode sh (tsigs fns gs) Γ k) = true := by
        cases h : (tsigs fns gs)[f]? with
        | none => rw [h] at ht; simp at ht
        | some ts => rw [h] at ht; exact ⟨ts, rfl, ht⟩
      simp only [Bool.and_eq_true, decide_eq_true_eq] at htc
      obtain ⟨⟨hArgs, hdΓ⟩, htk⟩ := htc
      obtain ⟨fn', Γf, hf', hg, hts'⟩ := tsigs_get hts
      rw [hf] at hf'
      cases hf'
      obtain ⟨_, hfT⟩ := tpcheck_fn htp hf hg
      obtain ⟨htF, hscal, hretI, hretS⟩ := tfcheck_spec hfT
      have hfc : fcheck (fns.map Fn.sig) fn = true := by
        unfold pcheck at hp
        exact List.all_eq_true.mp hp fn (List.mem_of_getElem? hf)
      obtain ⟨hpn, hcontF⟩ := fcheck_contH hfc
      have hdl : d < st.locals.length := hIb.len ▸ hdb
      have hlt : ∀ j ∈ args, j < st.locals.length :=
        fun j hj => hIb.len ▸ args_lt hlen hargs j hj
      have hown := own_counted hargs
      have hmid := inv_prep hIb hnd hown
      have hent := inv_entry hIb hpend hlen hpn hnd hargs
      -- typed pieces
      have hTent : TInv sh Γf hty fn.entry (initFn fn st.heap (args.map st.get)) := by
        refine entryFn_tinv fn sh Γf hty st.heap _ (by simp [hlen, Fn.sig]) hscal ?_ hTb.obj ?_
        · intro x τ hx hxp
          have hArgs' : args.map (fun j => Γ[j]?) = (Γf.take fn.params.length).map some := by
            rw [hArgs, hts']; rfl
          obtain ⟨j, hj, hjτ⟩ := call_arg_ty hlen hArgs' hxp
          have hgj : (args.map st.get).getD x (.int 0) = st.get j := by
            simp [List.getD_eq_getElem?_getD, List.getElem?_map, hj]
          rw [hgj]
          exact hTb.loc j τ (by rw [hjτ]; exact hx)
        · intro l o t tss i ho ht' hts'' hτ hfz
          obtain ⟨x, hx, _⟩ := hTb.hole l o t tss i ho ht' hts'' hτ hfz
          rw [hbh] at hx; cases hx
      obtain ⟨rty, hrty⟩ : ∃ rty, Γf[fn.ret]? = some rty := by
        cases h : Γf[fn.ret]? with
        | none => rw [h] at hretS; simp at hretS
        | some r => exact ⟨r, rfl⟩
      have hrtyE : ts.rty = rty := by rw [hts']; simp [tsigOf, hrty]
      have hΓr : Γf[fn.ret]? = Γ[d]? := by rw [hdΓ, hrtyE, hrty]
      have hKT : KT Γ a1.ls := by
        rw [ha1]
        refine KT_defK (by rw [length_midK]; exact hdb) (KT_midK hTb.kt) (fun e => ?_)
        cases hrr : fn.retRef with
        | false =>
          have := hretI hrr
          rw [hrty] at this
          rw [hdΓ, hrtyE]
          exact congrArg some (Option.some.inj this)
        | true => simp [retK, Fn.sig, hrr] at e
      have hLT : ∀ x τ, Γ[x]? = some τ →
          VT hty st.heap τ ((clrL (ownedArgs fn.params args) st.locals).getD x (.int 0)) := by
        intro x τ hx
        rw [clrL_get]
        by_cases hm : x ∈ ownedArgs fn.params args
        · rw [if_pos hm]; exact VT_zero _ _ _
        · rw [if_neg hm]; exact hTb.loc x τ hx
      obtain ⟨hh, ll, pp⟩ := st
      simp only at hpend
      subst hpend
      have hcs : cstep fns ⟨stk, .call d f args k, ⟨hh, ll, []⟩⟩ =
          some (.ok ⟨⟨k, clrL (ownedArgs fn.params args) ll, d, fn.ret, fn.retRef⟩ :: stk,
            fn.code, ⟨hh, calleeLocals (args.map (St.get ⟨hh, ll, []⟩)) fn.n, []⟩⟩) := by
        simp [cstep, callStep, hf]
        exact ⟨hlen, hdl, hlt, hpn, hnd⟩
      refine ⟨_, hcs, ?_, ?_, fun c' hc' => ?_⟩
      · intro k hh'; cases hh'
      · intro hh'; cases hh'
      cases hc'
      refine ⟨_, fn.params.length, retPredH fn.ret fn.retRef, fn.entry, Γf, hty, hcontF, hent,
        hTent, HU_nil _, htF, ?_, ?_⟩
      · refine ⟨ext, midK (ownedArgs fn.params args) b.ls, a1, np, E, hh, Γ, rfl, hmid, ?_, ?_,
          ha1, hah1, hk, hE, Frozen.refl _, htk, hKT, hLT, hΓr, ?_, hS⟩
        · exact midK_ne_unique _ _
        · simpa [clrL_length] using hdl
        · rw [hdΓ]; rfl
      · intro fr' rest' h; cases h; rfl
  · -- draining step
    obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, st.pending = hd :: rest := by
      cases h : st.pending with
      | nil => exact absurd h hpend
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    exact good_step_genT hC hI hT hu ht hS hE (by simp [cstep, hpe])


theorem goodT_reach (htp : tpcheck sh fns gs = true) {c d : Cfg2}
    (hG : GoodT (fns.map Fn.sig) (tsigs fns gs) sh c.stk (c.code, c.st)) (hr : CReach fns c d) :
    GoodT (fns.map Fn.sig) (tsigs fns gs) sh d.stk (d.code, d.st) := by
  induction hr with
  | refl => exact hG
  | step c c' d h _ ih =>
    rcases good_stepT htp hG with hn | ⟨r, hr, _, _, hok⟩
    · rw [hn] at h; cases h
    · rw [hr] at h
      cases h
      exact ih (hok _ rfl)

/-- **Headline theorem for typed programs.**  A program accepted by `tpcheck` (ownership check and
type pass, calls against the callees' typed signatures), entered at any function in a typed state
that meets the caller contract, never takes a `bad` step and never takes an `ill` step (no
out-of-range field access, no field or array operation on a value of the wrong kind, no null
dereference), in any depth of calls and returns. -/
theorem prog_sound_ill (htp : tpcheck sh fns gs = true) {f : Nat} {fn : Fn} {Γ : List Ty}
    (hf : fns[f]? = some fn) (hg : gs[f]? = some Γ) (hty : HTy)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    (hvals : ∀ x τ, Γ[x]? = some τ → x < fn.params.length →
      VT hty H τ (vals.getD x (Val.int 0)))
    (hobj : ∀ l o, H.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty H τ o.fields)
    (hnull : ∀ l o t ts (i : Nat), H.objs l = some o → hty l = some (.st t) → sh[t]? = some ts →
      (∃ τ', ts[i]? = some τ' ∧ τ' ≠ Ty.int) → o.fields[i]? ≠ some (Val.int 0))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c) :
    (∀ k, cstep fns c ≠ some (.bad k)) ∧ cstep fns c ≠ some .ill := by
  obtain ⟨hp, hfT⟩ := tpcheck_fn htp hf hg
  have hfc : fcheck (fns.map Fn.sig) fn = true := by
    unfold pcheck at hp
    exact List.all_eq_true.mp hp fn (List.mem_of_getElem? hf)
  obtain ⟨hpn, hcontF⟩ := fcheck_contH hfc
  obtain ⟨htF, hscal, _, _⟩ := tfcheck_spec hfT
  have hG : GoodT (fns.map Fn.sig) (tsigs fns gs) sh [] (fn.code, initFn fn H vals) :=
    ⟨ext, fn.params.length, retPredH fn.ret fn.retRef, fn.entry, Γ, hty, hcontF,
      entryFn_inv fn hpn ext H vals hlen hext hno href hsc,
      entryFn_tinv fn sh Γ hty H vals hlen hscal hvals hobj hnull, HU_nil _, htF, trivial,
      by intro fr rest h; cases h⟩
  have hG' := goodT_reach htp (c := ⟨[], fn.code, initFn fn H vals⟩) hG hr
  refine ⟨fun k hh => ?_, fun hh => ?_⟩
  · rcases good_stepT htp hG' with hn | ⟨r, hr', hnb, _, _⟩
    · rw [hn] at hh; cases hh
    · rw [hr'] at hh
      exact hnb k (Option.some.inj hh)
  · rcases good_stepT htp hG' with hn | ⟨r, hr', _, hni, _⟩
    · rw [hn] at hh; cases hh
    · rw [hr'] at hh
      exact hni (Option.some.inj hh)


/-! ### examples: the typed call rule is neither vacuous nor trivially permissive -/

private def exFns : List Fn := [fMain, fId, fLen, fTwo]
private def exGs : List (List Ty) :=
  [[.arr, .int, .int, .int], [.arr], [.arr, .int], [.arr, .arr, .int]]

example : tpcheck [] exFns exGs = true := by decide
/-- the destination of `len` is typed as an array -/
example : tpcheck [] exFns
    [[.arr, .int, .arr, .int], [.arr], [.arr, .int], [.arr, .arr, .int]] = false := by decide
/-- an `int` local passed for an array parameter -/
example : tpcheck [] exFns
    [[.int, .int, .int, .int], [.arr], [.arr, .int], [.arr, .arr, .int]] = false := by decide
/-- a function that returns a scalar must have an `int` result local -/
example : tpcheck [] exFns
    [[.arr, .int, .int, .int], [.arr], [.arr, .arr], [.arr, .arr, .int]] = false := by decide
/-- one local-type list per function -/
example : tpcheck [] exFns [[.arr, .int, .int, .int]] = false := by decide

end Orin
