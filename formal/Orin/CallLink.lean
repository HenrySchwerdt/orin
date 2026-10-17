import Orin.CallGen
import Orin.CallTop
import Orin.RangeNarrow
import Orin.RangePin

/-!
# The ownership contract of the interval analysis, derived from the call machine

`Range.GenOK` (`RangeSem.lean`) is the contract of the instruction `gen` of the interval analysis:
what a call, a builtin or a field operation does to the frame of the caller.  This file derives it
for **calls** from the ownership model: at the return step of the call machine (`GoodW`,
`CallGen.lean`), the frame of the caller after the call stands in the relation `GenOK` to the
frame before the call, for the instruction `callRI` (the result local `d` is defined, the operands
are mentioned, the borrowed operands are kept).  `ret_genok` is the statement; `call_exec_gen` and
`reach_ret_genok` read it as a step of `Range.Exec` of every call that a reachable
configuration of an accepted program makes.

What the proof uses: the caller's counted locals stay anchors while the callee runs
(`Frozen`: the objects they reach keep their slots, hence the length of an array), the owned
operands are the only locals the call clears, the others keep their value.

What the ownership model does not give (explicit hypotheses): `hcls` (an owned operand is a
reference-class local) and `hres` (the result respects the class of the local it is stored in:
`usize` is never negative, a `bool` is 0 or 1).  Both are the type discipline of `wf.or`.
-/

namespace Orin
open Heap

/-- the operands in borrowed positions that the call does not define (`RI.gen`'s `kept`) -/
def callKept (d : Nat) (args : List Nat) (ps : List PM) : List Nat :=
  (args.zip ps).filterMap fun p => if p.2 = PM.borrowed ∧ p.1 ≠ d then some p.1 else none

/-- the instruction of the interval analysis that a call is: defines `d`, mentions the operands,
keeps the borrowed ones -/
def callRI (d : Nat) (args : List Nat) (ps : List PM) : Range.RI :=
  .gen (some d) args (callKept d args ps) none

theorem mem_callKept {d : Nat} {args : List Nat} {ps : List PM} {x : Nat}
    (h : x ∈ callKept d args ps) : (x, PM.borrowed) ∈ args.zip ps ∧ x ≠ d := by
  unfold callKept at h
  obtain ⟨⟨j, m⟩, hm, e⟩ := List.mem_filterMap.mp h
  simp only at e
  split at e
  · rename_i hc
    cases e
    obtain ⟨h1, h2⟩ := hc
    subst h1
    exact ⟨hm, h2⟩
  · cases e

theorem callRI_wf (d : Nat) (args : List Nat) (ps : List PM) : Range.GenWf (callRI d args ps) := by
  refine ⟨fun x hx hk => ?_, fun x hx => by cases hx⟩
  simp only [Option.some.injEq] at hx
  subst hx
  exact (mem_callKept hk).2 rfl

/-- an operand in a borrowed position is not moved by the same call -/
theorem borrowed_not_owned {b : List AS} {ps : List PM} {args : List Nat}
    (hargs : (args.zip ps).all (argOK b (ownedArgs ps args)) = true) {x : Nat}
    (hx : (x, PM.borrowed) ∈ args.zip ps) : x ∉ ownedArgs ps args := by
  intro ho
  have h1 := List.all_eq_true.mp hargs _ hx
  have hc := own_counted hargs x ho
  simp only [argOK, Bool.and_eq_true, decide_eq_true_eq] at h1
  apply h1.2
  have : rootOf b x = x := by
    unfold rootOf
    cases hk : gk b x with
    | borrowed r => rw [hk] at hc; simp [AS.counted] at hc
    | _ => rfl
  rw [this]; exact ho

theorem mem_args_of_owned {ps : List PM} {args : List Nat} {x : Nat}
    (h : x ∈ ownedArgs ps args) : x ∈ args :=
  (List.of_mem_zip (ownedArgs_mem h)).1

/-- the locals a call changes: the result and the owned operands -/
theorem chg_callRI {cls : List Range.Cls} {d : Nat} {args : List Nat} {ps : List PM}
    (hargs : ∀ x, (x, PM.borrowed) ∈ args.zip ps → x ∉ ownedArgs ps args)
    (hcls : ∀ x ∈ ownedArgs ps args, Range.clsOf cls x = .ref) {x : Nat}
    (h : ¬ Range.Chg cls (callRI d args ps) x) : x ≠ d ∧ x ∉ ownedArgs ps args := by
  constructor
  · intro e; subst e; exact h (Or.inl rfl)
  · intro ho
    apply h
    refine Or.inr (Or.inr (Or.inl ⟨?_, ?_, hcls x ho⟩))
    · simp only [callRI, Range.RI.men, Option.toList, List.singleton_append, List.mem_cons]
      exact Or.inr (mem_args_of_owned ho)
    · simp only [callRI, Range.RI.keeps, decide_eq_false_iff_not]
      intro hk
      exact hargs x (mem_callKept hk).1 ho

theorem VOk_of_ref {c : Range.Cls} (h : c = .ref) (w : Val) : Range.VOk c w := by
  cases w with
  | int n => exact Or.inl h
  | ref l => exact h

theorem pinned_midK (own : List Nat) (a : List AS) (i : Nat) :
    (gk (midK own a) i).pinned = (if i ∈ own then false else (gk a i).pinned) := by
  rw [gk_midK]
  by_cases h : i ∈ own
  · simp [h, AS.pinned]
  · simp only [h, if_false]
    cases hk : gk a i with
    | borrowed r => by_cases hr : r ∈ own <;> simp [hr, AS.pinned]
    | _ => simp [AS.pinned]

/-- The relation of a call's frame before and after: a frame model `s0` of the caller before the
call (its locals are the locals at the call, its array lengths are those of the heap at the call, a
ghost bit `ctd` implies that the ownership analysis pins the local: counted, or a lent parameter) and the frame `s1` after
the call (the caller's locals with the result stored, the lengths of the current heap, the pinned
locals the call did not change) stand in the relation `GenOK` for `callRI`. -/
def RetGenOK (site : Site) (fr : Frame) (st : St) : Prop :=
  ∀ (cls : List Range.Cls),
    (∀ x ∈ site.own, Range.clsOf cls x = .ref) →
    Range.VOk (Range.clsOf cls fr.d) (st.get fr.ret) →
    ∀ (s0 : Range.CS), s0.loc = site.L0 →
    (∀ l, s0.len l = Range.lensOf ⟨site.H0, site.L0, []⟩ l) →
    (∀ x, s0.ctd x = true → (gk site.b x).pinned = true) →
    ∃ s1 : Range.CS, s1.loc = fr.L.set fr.d (st.get fr.ret) ∧
      (∀ l, s1.len l = Range.lensOf st l) ∧
      (∀ x, s1.ctd x = true → (gk site.a1.ls x).pinned = true) ∧
      Range.GenOK cls (callRI fr.d site.args site.ps) s0 s1

/-- **The return step of a call is a `GenOK` step** (why a borrowed call may keep the array).
At the return of a call (code `.nil`, the call frame on top of the stack, nothing pending) the
frame of the caller stands in the relation `GenOK` to the frame before the call. -/
theorem ret_genok {sg : List Sig} {site : Site} {ss : List Site} {fr : Frame} {rest : List Frame}
    {st : St} (hG : GoodW sg (site :: ss) (fr :: rest) (.nil, st)) : RetGenOK site fr st := by
  intro cls hcls hres s0 hloc hlen hctd
  obtain ⟨ext, np, E, a, hC, hI, hS, hE⟩ := hG
  obtain ⟨he, hL, hIb, hlenA, hnd, hd, hargs, ha1, hk, hE1, hFz, hrest⟩ := hS
  have hbor : ∀ x, (x, PM.borrowed) ∈ site.args.zip site.ps → x ∉ ownedArgs site.ps site.args :=
    fun x hx => borrowed_not_owned hargs hx
  have hlb : site.b.length = site.L0.length := hIb.len
  have hdb : fr.d < site.b.length := by
    have : fr.d < fr.L.length := hd
    rw [hL, clrL_length] at this
    omega
  refine ⟨⟨fr.L.set fr.d (st.get fr.ret),
    fun x => s0.ctd x && decide (x ∉ site.own ∧ x ≠ fr.d), Range.lensOf st⟩, rfl, fun l => rfl, ?_, ?_⟩
  · intro x hx
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hx
    obtain ⟨hx0, hxo, hxd⟩ := hx
    have hc := hctd x hx0
    have hm : (gk site.mid x).pinned = true := by
      show (gk (midK site.own site.b) x).pinned = true
      rw [pinned_midK]; simp [hxo, hc]
    rw [ha1, gk_defK _ _ _ _ (by rw [Site.mid, length_midK]; exact hdb)]
    simp only [hxd, ite_false]
    by_cases hb : gk site.mid x = .borrowed fr.d
    · rw [hb] at hm; simp [AS.pinned] at hm
    · simp only [hb, ite_false]; exact hm
  · refine ⟨?_, ?_, ?_, ?_⟩
    · simp [hloc, hL, clrL_length]
    · intro x hx
      obtain ⟨hxd, hxo⟩ := chg_callRI (cls := cls) hbor hcls hx
      show (fr.L.set fr.d (st.get fr.ret))[x]? = s0.loc[x]?
      rw [List.getElem?_set_ne (Ne.symm hxd), hloc, hL, clrL_getElem?]
      simp [Site.own] at hxo ⊢
      simp [hxo]
    · intro x hx hChg
      have hVOk : Range.VOk (Range.clsOf cls x) ((fr.L.set fr.d (st.get fr.ret)).getD x (.int 0)) := by
        rcases hChg with h | h | ⟨_, _, hc⟩ | h
        · simp only [callRI, Range.RI.dst, Option.some.injEq] at h
          subst h
          have : (fr.L.set fr.d (st.get fr.ret)).getD fr.d (.int 0) = st.get fr.ret := by
            simp [List.getD_eq_getElem?_getD, List.getElem?_set_self (by exact hd)]
          rw [this]; exact hres
        · simp [callRI, Range.RI.recv] at h
        · exact VOk_of_ref hc _
        · simp [callRI] at h
      exact hVOk
    · intro x l n hx hxl hxc hxn
      obtain ⟨hxd, hxo⟩ := chg_callRI (cls := cls) hbor hcls hx
      have hxo : x ∉ site.own := hxo
      constructor
      · rw [hlen l] at hxn
        simp only [Range.lensOf, Option.map_eq_some_iff] at hxn
        obtain ⟨o, ho, hon⟩ := hxn
        have hc := hctd x hxc
        have hxlf : fr.L[x]? = some (.ref l) := by
          rw [hL, clrL_getElem?]; simp [hxo]; rw [hloc] at hxl; exact hxl
        have hanch : ∃ p, Val.ref p ∈ ext ∧ Desc site.H0 p (.ref l) := by
          by_cases hpar : gk site.b x = .param
          · obtain ⟨p, hp, hd⟩ := (hIb.cl x).prm hpar
            have hget : (⟨site.H0, site.L0, []⟩ : St).get x = .ref l := by
              rw [hloc] at hxl
              simp [St.get, List.getD_eq_getElem?_getD, hxl]
            rw [hget] at hd
            exact ⟨p, by rw [he]; exact List.mem_append_right _ hp, hd⟩
          · have hcn : (gk site.b x).counted = true := by
              cases hk : gk site.b x <;> simp_all [AS.pinned, AS.counted]
            have hm : (gk site.mid x).counted = true := by
              show (gk (midK site.own site.b) x).counted = true
              rw [counted_midK]; simp [hxo, hcn]
            refine ⟨l, ?_, Desc.self⟩
            rw [he]
            apply List.mem_append_left
            apply List.mem_iff_getElem?.mpr
            refine ⟨x, ?_⟩
            rw [projL_getElem?, hxlf]
            simp [pv, hm]
        obtain ⟨p, hmem, hdp⟩ := hanch
        obtain ⟨o', ho', hf⟩ := hFz p l o hmem hdp ho
        show Range.lensOf st l = some n
        have ho'' : st.heap.objs l = some o' := ho'
        simp [Range.lensOf, ho'', hf, hon]
      · show (s0.ctd x && decide (x ∉ site.own ∧ x ≠ fr.d)) = true
        simp [hxc, hxo, hxd]

/-- Read as a step of the interval analysis: the return of a call is an `Exec.gen` step. -/
theorem RetGenOK.exec {site : Site} {fr : Frame} {st : St} (h : RetGenOK site fr st)
    (cls : List Range.Cls) (hcls : ∀ x ∈ site.own, Range.clsOf cls x = .ref)
    (hres : Range.VOk (Range.clsOf cls fr.d) (st.get fr.ret))
    (s0 : Range.CS) (hloc : s0.loc = site.L0)
    (hlen : ∀ l, s0.len l = Range.lensOf ⟨site.H0, site.L0, []⟩ l)
    (hctd : ∀ x, s0.ctd x = true → (gk site.b x).pinned = true) :
    ∃ s1 : Range.CS, Range.Exec cls (callRI fr.d site.args site.ps) s0 s1 := by
  obtain ⟨s1, _, _, _, hg⟩ := h cls hcls hres s0 hloc hlen hctd
  exact ⟨s1, Range.Exec.gen (callRI_wf _ _ _) hg⟩

/-- **A pinned local with its ghost bit set holds a live object.**  The ghost bit of a frame model
`s` of the machine state `st` (`Range.Rel`) is only trusted on locals that the ownership kinds pin
(counted, or a lent parameter); such a local holds a reference to a live object (`Inv.live`), and the
frame model gives that object its number of slots. -/
theorem pinA_of_inv {ext : List Val} {a : List AS} {st : St} (hI : Inv ext a st) {s : Range.CS}
    (hr : Range.Rel s st) {x : Nat} (hx : (gk a x).pinned = true) (hc : s.ctd x = true) :
    Range.PinA x s := by
  have hroot : (gk a x).isRoot = true := by
    cases hk : gk a x <;> simp_all [AS.pinned, AS.isRoot]
  have hrefk : (gk a x).isRef = true := by
    cases hk : gk a x <;> simp_all [AS.pinned, AS.isRef]
  obtain ⟨l, hl⟩ := (hI.cl x).ref hrefk
  obtain ⟨o, ho⟩ : ∃ o, st.heap.objs l = some o := by
    have := hI.live hrefk
    rw [hl] at this
    exact this
  have hlt : x < st.locals.length := by
    have : gk a x ≠ .dead := by intro e; rw [e] at hx; simp [AS.pinned] at hx
    exact hI.len ▸ lt_of_gk_ne_dead this
  refine ⟨l, o.fields.length, ?_, hc, ?_⟩
  · rw [hr.1]
    have : st.locals[x]? = some (st.get x) := by
      simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hlt]
    rw [this, hl]
  · rw [hr.2 l]; simp [Range.lensOf, ho]

/-- **The entry pin of a borrowed parameter.**  In the entry frame of a callee (the machine state
`initFn`, the entry kinds) a parameter of mode `borrowed` is a `Param` local; with the ghost bit set it
satisfies `PinA`, the entry hypothesis of `Range.t2_param`. -/
theorem pin_entry_param {fn : Fn} {ext : List Val} {H : Heap} {vals : List Val}
    (hI : Inv ext fn.entry.ls (initFn fn H vals)) {s0 : Range.CS}
    (hr : Range.Rel s0 (initFn fn H vals)) {a : Nat} (ha : fn.params[a]? = some PM.borrowed)
    (hc : s0.ctd a = true) : Range.PinA a s0 := by
  refine pinA_of_inv hI hr ?_ hc
  have : gk fn.entry.ls a = .param := by
    show gk (entryLs fn.params fn.n) a = .param
    rw [gk_entryLs, ha]; rfl
  rw [this]; rfl

variable {fns : List Fn}

/-- **Every return of a call, in any depth of a run of an accepted program, is a `GenOK` step.**
(Same entry conditions as `prog_sound`.) -/
theorem prog_ret_genok (hp : pcheck fns = true) {f : Nat} {fn : Fn} (hf : fns[f]? = some fn)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c)
    {fr : Frame} {rest : List Frame} (hs : c.stk = fr :: rest) (hc : c.code = .nil) :
    ∃ (site : Site), RetGenOK site fr c.st := by
  have hfc : fcheck (fns.map Fn.sig) fn = true := by
    unfold pcheck at hp
    exact List.all_eq_true.mp hp fn (List.mem_of_getElem? hf)
  obtain ⟨hpn, hcontF⟩ := fcheck_cont hfc
  have hG : GoodW (fns.map Fn.sig) [] [] (fn.code, initFn fn H vals) :=
    ⟨ext, fn.params.length, retPred fn.ret fn.retRef, fn.entry, hcontF,
      entryFn_inv fn hpn ext H vals hlen hext hno href hsc, trivial, by intro fr rest h; cases h⟩
  obtain ⟨ss, hG'⟩ := goodW_reach hp (c := ⟨[], fn.code, initFn fn H vals⟩) hG hr
  obtain ⟨c0, c1, c2⟩ := c
  simp only at hs hc
  subst hc; subst hs
  cases ss with
  | nil =>
    obtain ⟨_, _, _, _, _, _, hS, _⟩ := hG'
    exact absurd hS (by simp [StkW])
  | cons site ss =>
    exact ⟨site, ret_genok hG'⟩

end Orin
