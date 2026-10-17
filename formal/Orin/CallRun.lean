import Orin.Call

/-!
# The call machine and its safety invariant

A configuration of the whole-program machine is a stack of suspended caller frames, the code of
the running function and its state (one shared heap).  A call pushes a frame (the caller's
locals, with the owned operands zeroed: they are moved into the callee), starts the callee on a
fresh frame holding the operands, and a return stores the callee's result local into the caller's
destination.  The callee's other locals are simply dropped (a leak, never a use after free).

`Good` is the ghost invariant: the running function's code is accepted (`Cont`) from an abstract
state related to the concrete state by `Inv`, where the anchors `ext` are the references the
suspended callers still hold; every suspended frame remembers its own accepted continuation
and the state it will resume in (`StkI`), together with the fact that nothing it reaches changed
since the call (`Frozen`).  `good_step` : a step of a good configuration is never `bad`, and
leads to a good configuration.
-/

namespace Orin
open Heap

/-- a suspended caller -/
structure Frame where
  k : Code
  L : List Val
  d : Nat
  ret : Nat
  retRef : Bool

structure Cfg2 where
  stk : List Frame
  code : Code
  st : St

def Res.liftS (stk : List Frame) : Res (Code × St) → Res Cfg2
  | .ok c => .ok ⟨stk, c.1, c.2⟩
  | .trap => .trap
  | .bad k => .bad k
  | .ill => .ill

def callStep (fns : List Fn) (c : Cfg2) (d f : Nat) (args : List Nat) (k : Code) : Res Cfg2 :=
  match fns[f]? with
  | none => .ill
  | some fn =>
    if args.length = fn.params.length ∧ d < c.st.locals.length ∧
        (∀ j ∈ args, j < c.st.locals.length) ∧ fn.params.length ≤ fn.n ∧
        (ownedArgs fn.params args).Nodup then
      .ok ⟨⟨k, clrL (ownedArgs fn.params args) c.st.locals, d, fn.ret, fn.retRef⟩ :: c.stk,
           fn.code, ⟨c.st.heap, calleeLocals (args.map c.st.get) fn.n, []⟩⟩
    else .ill

def retStep (c : Cfg2) : Option (Res Cfg2) :=
  match c.stk with
  | [] => none
  | fr :: rest =>
    if fr.d < fr.L.length ∧ fr.ret < c.st.locals.length then
      some (.ok ⟨rest, fr.k, ⟨c.st.heap, fr.L.set fr.d (c.st.get fr.ret), []⟩⟩)
    else some .ill

/-- One step of the program machine; `none` = halted (the entry function returned). -/
def cstep (fns : List Fn) (c : Cfg2) : Option (Res Cfg2) :=
  match c.st.pending with
  | [] =>
    match c.code with
    | .call d f args k => some (callStep fns c d f args k)
    | .nil => retStep c
    | _ => (mstep (c.code, c.st)).map (Res.liftS c.stk)
  | _ :: _ => (mstep (c.code, c.st)).map (Res.liftS c.stk)

inductive CReach (fns : List Fn) : Cfg2 → Cfg2 → Prop where
  | refl (c : Cfg2) : CReach fns c c
  | step (c c' d : Cfg2) : cstep fns c = some (.ok c') → CReach fns c' d → CReach fns c d

/-! ### inversion of the acceptance derivation -/

section inv
variable {sg : List Sig} {np : Nat} {E : AState → Prop} {a : AState}

theorem Cont.nil_inv (h : Cont sg np E a .nil) :
    ∃ b, E b ∧ ∀ (ext : List Val) (s : St), Inv ext a.ls s → Inv ext b.ls s := by
  generalize hc : Code.nil = code at h
  induction h with
  | nil hE => cases hc; exact ⟨_, hE, fun _ _ h => h⟩
  | op _ _ _ => cases hc
  | ite _ _ _ _ _ _ => cases hc
  | loop _ _ _ _ _ _ _ => cases hc
  | call _ _ _ => cases hc
  | weak hF _ ih =>
    obtain ⟨b, hb, hi⟩ := ih hc
    exact ⟨b, hb, fun ext s hI => hi ext s (hI.weaken hF)⟩

theorem Cont.call_inv {d f : Nat} {args : List Nat} {k : Code}
    (h : Cont sg np E a (.call d f args k)) :
    ∃ b a1, stepAC np sg b d f args = some a1 ∧ Cont sg np E a1 k ∧
      ∀ (ext : List Val) (s : St), Inv ext a.ls s → Inv ext b.ls s := by
  generalize hc : Code.call d f args k = code at h
  induction h with
  | nil _ => cases hc
  | op _ _ _ => cases hc
  | ite _ _ _ _ _ _ => cases hc
  | loop _ _ _ _ _ _ _ => cases hc
  | call hs hk _ => cases hc; exact ⟨_, _, hs, hk, fun _ _ h => h⟩
  | weak hF _ ih =>
    obtain ⟨b, a1, hs, hk, hi⟩ := ih hc
    exact ⟨b, a1, hs, hk, fun ext s hI => hi ext s (hI.weaken hF)⟩

end inv

theorem mem_zip_of_mem (j : Nat) : ∀ (args : List Nat) (ps : List PM), args.length = ps.length →
    j ∈ args → ∃ m, (j, m) ∈ args.zip ps
  | [], _, _, h => by simp at h
  | x :: xs, [], hl, _ => by simp at hl
  | x :: xs, p :: ps, hl, h => by
    rcases List.mem_cons.mp h with e | e
    · exact ⟨p, by simp [e]⟩
    · obtain ⟨m, hm⟩ := mem_zip_of_mem j xs ps (by simpa using hl) e
      exact ⟨m, by simp [hm]⟩

theorem args_lt {b : List AS} {ps : List PM} {args : List Nat} (hl : args.length = ps.length)
    (hargs : (args.zip ps).all (argOK b (ownedArgs ps args)) = true) :
    ∀ j ∈ args, j < b.length := by
  intro j hj
  obtain ⟨m, hm⟩ := mem_zip_of_mem j args ps hl hj
  have h1 := List.all_eq_true.mp hargs _ hm
  apply lt_of_gk_ne_dead
  cases m <;> simp [argOK] at h1
  · rw [h1]; simp
  · intro e; rw [e] at h1; simp [AS.isRef] at h1
  · intro e; rw [e] at h1; simp [AS.counted] at h1

theorem own_counted {b : List AS} {ps : List PM} {args : List Nat}
    (hargs : (args.zip ps).all (argOK b (ownedArgs ps args)) = true) :
    ∀ j ∈ ownedArgs ps args, (gk b j).counted = true := by
  intro j hj
  have h1 := List.all_eq_true.mp hargs _ (ownedArgs_mem hj)
  simpa [argOK] using h1

theorem stepAC_spec {np : Nat} {sg : List Sig} {b a1 : AState} {d f : Nat} {args : List Nat}
    (h : stepAC np sg b d f args = some a1) :
    ∃ sig, sg[f]? = some sig ∧ args.length = sig.params.length ∧ d < b.ls.length ∧
      (ownedArgs sig.params args).Nodup ∧
      (args.zip sig.params).all (argOK b.ls (ownedArgs sig.params args)) = true ∧
      a1.ls = defK (midK (ownedArgs sig.params args) b.ls) d (retK sig.retRef) := by
  unfold stepAC at h
  cases hc : stepCall sg np b.ls d f args with
  | none => rw [hc] at h; simp at h
  | some ls' =>
    rw [hc] at h
    simp only at h
    split at h
    · cases h
    · cases h
      unfold stepCall at hc
      cases hs : sg[f]? with
      | none => rw [hs] at hc; simp at hc
      | some sig =>
        rw [hs] at hc
        simp only at hc
        split at hc
        · rename_i hcond
          cases hc
          exact ⟨sig, rfl, hcond.1, hcond.2.1, hcond.2.2.2.1, hcond.2.2.2.2, by simp [retK]⟩
        · simp at hc

theorem fcheck_cont {sg : List Sig} {f : Fn} (h : fcheck sg f = true) :
    f.params.length ≤ f.n ∧
      Cont sg f.params.length (retPred f.ret f.retRef) f.entry f.code := by
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
      (retPred f.ret f.retRef) hc (Cont.nil hm.2)
    rwa [Code.app_nil] at h1

/-! ### the ghost invariant -/

/-- The suspended callers.  `StkI sg ext stk H`: `ext` = the anchors of the running function,
`H` = the current heap.  For the top frame `fr`: the running function was called from the state
`⟨H0, fr.L, []⟩` (related to `aMid` under the caller's own anchors `extB`), the caller's code
resumes with the accepted continuation `fr.k`, and nothing `ext` reaches changed since `H0`. -/
def StkI (sg : List Sig) : List Val → List Frame → Heap → Prop
  | _, [], _ => True
  | ext, fr :: rest, H =>
    ∃ (extB : List Val) (aMid : List AS) (a1 : AState) (np : Nat) (E : AState → Prop) (H0 : Heap),
      ext = projL aMid fr.L ++ extB ∧
      Inv extB aMid ⟨H0, fr.L, []⟩ ∧ (∀ i, gk aMid i ≠ .unique) ∧ fr.d < fr.L.length ∧
      a1.ls = defK aMid fr.d (retK fr.retRef) ∧
      Cont sg np E a1 fr.k ∧
      (∀ f' r', rest = f' :: r' → E = retPred f'.ret f'.retRef) ∧
      Frozen ext H0 H ∧ StkI sg extB rest H0

def Good (sg : List Sig) (stk : List Frame) (c : Code × St) : Prop :=
  ∃ (ext : List Val) (np : Nat) (E : AState → Prop) (a : AState),
    Cont sg np E a c.1 ∧ Inv ext a.ls c.2 ∧ StkI sg ext stk c.2.heap ∧
    (∀ fr rest, stk = fr :: rest → E = retPred fr.ret fr.retRef)

theorem StkI.step {sg : List Sig} {ext : List Val} {stk : List Frame} {H H' : Heap}
    (h : StkI sg ext stk H) (hF : Frozen ext H H') : StkI sg ext stk H' := by
  cases stk with
  | nil => trivial
  | cons fr rest =>
    obtain ⟨extB, aMid, a1, np, E, H0, he, hI, hnu, hd, ha, hk, hE, hFz, hrest⟩ := h
    exact ⟨extB, aMid, a1, np, E, H0, he, hI, hnu, hd, ha, hk, hE, hFz.trans hF, hrest⟩

/-- one step of accepted code never changes what the anchors reach (also draining steps) -/
theorem frozen_step {sg : List Sig} {np : Nat} {E : AState → Prop} {a : AState} {code : Code}
    {ext : List Val} (hC : Cont sg np E a code) {s : St} (hI : Inv ext a.ls s)
    {c' : Code × St} (h : mstep (code, s) = some (.ok c')) : Frozen ext s.heap c'.2.heap := by
  by_cases hp : s.pending = []
  · exact frozen_step_nopending hC s hI hp c' h
  · obtain ⟨hd, rest, hpe⟩ : ∃ hd rest, s.pending = hd :: rest := by
      cases h : s.pending with
      | nil => exact absurd h hp
      | cons hd rest => exact ⟨hd, rest, rfl⟩
    have h' : Res.liftC code (drain s) = .ok c' := by simpa [mstep, hpe] using h
    cases hd' : drain s with
    | ok s' =>
      rw [hd'] at h'
      simp only [Res.liftC, Res.ok.injEq] at h'
      subst h'
      exact drain_frozen hI hd'
    | bad _ => rw [hd'] at h'; simp [Res.liftC] at h'
    | trap => rw [hd'] at h'; simp [Res.liftC] at h'
    | ill => rw [hd'] at h'; simp [Res.liftC] at h'

end Orin
