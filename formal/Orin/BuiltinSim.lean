import Orin.CallLink
import Orin.OpLen

/-!
# The machine's instructions as steps of the interval analysis

`Range.Exec` (`RangeSem.lean`) is the semantics of the instruction set `Range.RI` that the interval
analysis works on; the machine of `Mir.lean` has its own instructions `MI`.  This file ties the two
**per instruction**:

* `miRI i` is the instruction of the analysis that the machine instruction `i` is.  The instructions the
  analysis knows (`const` = `copy`, `move`, `alloc` = `arrayNew`, `makeUnique`, `arrayLen` = `arrLen`,
  `arrayGet` = `get`, `arraySet` = `set`) are mapped to themselves; every other one (`borrow`, `dup`,
  `release`, `getField`, `setField`, `putField`, `takeField`, a run-time sized `arrayNew`) is a `gen`
  whose descriptor (the defined local `dst`, the mentioned locals `men`, the kept array operands `kept`)
  is **fixed here per instruction** and not assumed.
* `frameOf a st` is the frame model of the machine state `st` under the ownership kinds `a`: the
  locals of `st`, the lengths of its heap (`Range.lensOf`), and the ghost bit `ctd` **defined** from the
  kinds (`pinOf`: a counted local or a lent parameter).  The bit is not supplied by the caller.
* `mop_exec`: if `mop st i = ok st'` and the kind transfer `stepL np a i = some a'` accepts the
  instruction, then `Range.Exec cls (miRI i) (frameOf a st) (frameOf a' st')`: the machine step is a step
  of the analysis's semantics, with the contract `GenOK` derived (not assumed) for the `gen` ones.

Hypotheses (all static facts about the class table and the instruction, none about the run):

* `KCls cls a`: the class table agrees with the kinds at the point (a local the ownership analysis
  calls a reference has class `ref`, an `init` local has a scalar class).  The class table is the
  analysis's, the kinds are the ownership analysis's; `wf.or` ties them in the verifier.
* `MiWf cls i`: `const` writes a legal value of the class of its local, `arrayLen` stores into a numeric
  local.
* `SRes`: a scalar read from the heap (`getField`/`arrayGet` of a scalar slot) respects the class of
  the local that receives it (a `usize` is not negative, a `bool` is 0 or 1).  The machine has neither
  integer classes nor array contents, so this one stays a hypothesis; everything else about the
  result class (a reference lands in a `ref` local, a length is not negative, a cleared local is 0)
  is derived.
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {st st' : St} {np : Nat}

/-! ### pinned kinds under the kind transfer functions -/

theorem pinned_defK_ne (a : List AS) (d : Nat) (k : AS) (hd : d < a.length) {y : Nat} (hy : y ≠ d) :
    (gk (defK a d k) y).pinned = (gk a y).pinned := by
  rw [gk_defK a d k y hd]
  simp only [hy, if_false]
  by_cases h : gk a y = .borrowed d
  · simp [h, AS.pinned]
  · simp [h]

theorem pinned_defK_self (a : List AS) (d : Nat) (k : AS) (hd : d < a.length) :
    (gk (defK a d k) d).pinned = k.pinned := by
  rw [gk_defK a d k d hd]; simp

theorem pinned_killB (x : Nat) (a : List AS) (y : Nat) :
    (gk (killB x a) y).pinned = (gk a y).pinned := by
  rw [gk_killB]
  by_cases h : gk a y = .borrowed x
  · simp [h, AS.pinned]
  · simp [h]

theorem pinned_demote (a : List AS) (l : Nat) (hl : l < a.length) (y : Nat) :
    (gk (demote a l) y).pinned = (gk a y).pinned := by
  rw [gk_demote a l y hl]
  by_cases h : y = l ∧ gk a l = .unique
  · obtain ⟨h1, h2⟩ := h
    subst h1
    simp [h2, AS.pinned]
  · simp [h]

theorem pinned_set_unique (a : List AS) (x : Nat) (hx : x < a.length) (hc : (gk a x).pinned = true)
    (y : Nat) : (gk (a.set x .unique) y).pinned = (gk a y).pinned := by
  rw [gk_set a x .unique y hx]
  by_cases h : y = x
  · subst h; rw [if_pos rfl]; exact hc.symm
  · simp [h]

/-! ### the class table against the kinds -/

/-- the class table agrees with the kinds -/
def KCls (cls : List Range.Cls) (a : List AS) : Prop :=
  ∀ x, ((gk a x).isRef = true → Range.clsOf cls x = .ref) ∧
    (gk a x = .init → Range.clsOf cls x ≠ .ref)

theorem KCls.ref {cls : List Range.Cls} {a : List AS} (h : KCls cls a) {x : Nat}
    (hr : (gk a x).isRef = true) : Range.clsOf cls x = .ref := (h x).1 hr

theorem KCls.init {cls : List Range.Cls} {a : List AS} (h : KCls cls a) {x : Nat}
    (hr : gk a x = .init) : Range.clsOf cls x ≠ .ref := (h x).2 hr

theorem KCls.counted {cls : List Range.Cls} {a : List AS} (h : KCls cls a) {x : Nat}
    (hr : (gk a x).counted = true) : Range.clsOf cls x = .ref :=
  h.ref (by cases hk : gk a x <;> simp_all [AS.counted, AS.isRef])

/-! ### the frame model of a machine state -/

/-- the ghost bit as a function of the kinds -/
def pinOf (a : List AS) (x : Nat) : Bool := (gk a x).pinned

/-- the frame model of the machine state `st` under the kinds `a` -/
def frameOf (a : List AS) (st : St) : Range.CS := ⟨st.locals, pinOf a, Range.lensOf st⟩

theorem frameOf_rel (a : List AS) (st : St) : Range.Rel (frameOf a st) st := ⟨rfl, fun _ => rfl⟩

theorem frameOf_loc (a : List AS) (st : St) : (frameOf a st).loc = st.locals := rfl
theorem frameOf_len (a : List AS) (st : St) : (frameOf a st).len = Range.lensOf st := rfl
theorem frameOf_ctd (a : List AS) (st : St) (x : Nat) : (frameOf a st).ctd x = (gk a x).pinned := rfl
theorem frameOf_get (a : List AS) (st : St) (x : Nat) : (frameOf a st).get x = st.get x := rfl

/-- two frames are equal when their three components are -/
theorem cs_ext {s s' : Range.CS} (h1 : s.loc = s'.loc) (h2 : ∀ x, s.ctd x = s'.ctd x)
    (h3 : ∀ l, s.len l = s'.len l) : s = s' := by
  cases s; cases s'
  simp only at h1
  subst h1
  have : (fun x => _) = _ := funext h2
  congr 1 <;> first | exact funext h2 | exact funext h3

/-! ### the descriptors -/

/-- the kept array operands of a `gen` that defines `d`: a defined local is never kept -/
def keepNe (d : Nat) (xs : List Nat) : List Nat := xs.filter (fun y => decide (y ≠ d))

theorem mem_keepNe {d : Nat} {xs : List Nat} {y : Nat} : y ∈ keepNe d xs ↔ y ∈ xs ∧ y ≠ d := by
  simp [keepNe]

/-- the instruction of the interval analysis that a machine instruction is -/
def miRI : MI → Range.RI
  | .const d n => .copy d (.cint n)
  | .move d s => .move d s
  | .borrow d s => .gen (some d) [s] (keepNe d [s]) none
  | .dup d s => .gen (some d) [s] (keepNe d [s]) none
  | .release x => .gen none [x] [] none
  | .alloc d n => .arrayNew d n
  | .getField d o _ _ => .gen (some d) [o] (keepNe d [o]) none
  | .setField x _ v => .gen none [x, v] [x] none
  | .takeField d x _ => .gen (some d) [x] (keepNe d [x]) none
  | .putField x _ y => .gen none [x, y] [x] none
  | .makeUnique x => .makeUnique x
  | .arrayLen d a => .arrLen d a
  | .arrayGet d a i _ => .get d a (.loc i)
  | .arraySet x i v => .set x (.loc i) v
  | .arrayNew d nl => .gen (some d) [nl] (keepNe d [nl]) none

theorem chg_gen {cls : List Range.Cls} {dst : Option Nat} {men kept : List Nat} {recv : Option Nat}
    {y : Nat} :
    Range.Chg cls (.gen dst men kept recv) y ↔
      dst = some y ∨ recv = some y ∨
        (y ∈ dst.toList ++ men ∧ y ∉ kept ∧ Range.clsOf cls y = .ref) := by
  simp [Range.Chg, Range.RI.dst, Range.RI.recv, Range.RI.men, Range.RI.keeps]

/-- the contract of a `gen` from what the machine does to the locals, the heap and the kinds -/
theorem genok_frame {cls : List Range.Cls} {ins : Range.RI}
    (hlen : st'.locals.length = st.locals.length)
    (hsame : ∀ x, ¬ Range.Chg cls ins x → st'.locals[x]? = st.locals[x]?)
    (hvok : ∀ x, x < st.locals.length → Range.Chg cls ins x →
      Range.VOk (Range.clsOf cls x) (st'.get x))
    (hL : ∀ l n, Range.lensOf st l = some n → Range.lensOf st' l = some n)
    (hpin : ∀ x, ¬ Range.Chg cls ins x → (gk a x).pinned = true → (gk a' x).pinned = true) :
    Range.GenOK cls ins (frameOf a st) (frameOf a' st') :=
  ⟨hlen, hsame, hvok, fun x l n hx _ hc hn => ⟨hL l n hn, hpin x hx hc⟩⟩

theorem VOk_ref {c : Range.Cls} (h : c = .ref) (w : Val) : Range.VOk c w := by
  cases w with
  | int n => exact Or.inl h
  | ref l => exact h

theorem VOk_int {c : Range.Cls} {n : Int} (h : c.okv n) : Range.VOk c (.int n) := Or.inr h

theorem lensOf_heap_eq {st st' : St} (h : st'.heap = st.heap) (l : Nat) :
    Range.lensOf st' l = Range.lensOf st l := by
  simp [Range.lensOf, h]

theorem locals_setL_length (st : St) (d : Nat) (w : Val) : (st.setL d w).locals.length = st.locals.length := by
  simp [St.setL]

theorem locals_setL_ne (st : St) {d x : Nat} (h : x ≠ d) (w : Val) :
    (st.setL d w).locals[x]? = st.locals[x]? := by
  simp [St.setL, List.getElem?_set, Ne.symm h]

theorem get_setL_self (st : St) {d : Nat} (hd : d < st.locals.length) (w : Val) :
    (st.setL d w).get d = w := by
  simp [St.get, St.setL, List.getD_eq_getElem?_getD, hd]

/-- a `gen` that defines `d`, mentions `z` and keeps it: only `d` is changed -/
theorem chg_dstOne {cls : List Range.Cls} {d z y : Nat} :
    Range.Chg cls (.gen (some d) [z] (keepNe d [z]) none) y ↔ y = d := by
  rw [chg_gen]
  constructor
  · rintro (h | h | ⟨h1, h2, _⟩)
    · exact (Option.some.inj h).symm
    · cases h
    · simp only [Option.toList, List.singleton_append, List.mem_cons, List.mem_singleton,
        mem_keepNe, List.not_mem_nil, or_false] at h1 h2
      by_cases hne : y = d
      · exact hne
      · rcases h1 with h1 | h1
        · exact absurd h1 hne
        · exact absurd ⟨h1, hne⟩ h2
  · intro h; exact Or.inl (by rw [h])

theorem refkind_class {cls : List Range.Cls} {b : List AS} (hK : KCls cls b) {d : Nat}
    (h : (gk b d).isRef = true) (w : Val) : Range.VOk (Range.clsOf cls d) w :=
  VOk_ref (hK.ref h) w

/-! ### `borrow`, `dup`, `release` -/

theorem sim_borrow {cls : List Range.Cls} {d x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.borrow d x) = some a') (hm : mop st (.borrow d x) = .ok st')
    (hK' : KCls cls a') :
    Range.GenOK cls (miRI (.borrow d x)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, hxa, _, hdx, hxr, _⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hdl : d < st.locals.length := hI.len ▸ hda
    have hxl : x < st.locals.length := hI.len ▸ hxa
    simp only [mop, opBorrow, hdl, hxl, and_self, ite_true, Res.ok.injEq] at hm
    subst hm
    have hdr : (gk (defK (demote a x) d (.borrowed (rootOf a x))) d).isRef = true := by
      rw [gk_defK _ _ _ _ (by rw [length_demote]; exact hda)]; simp [AS.isRef]
    refine genok_frame ?_ ?_ ?_ ?_ ?_
    · exact locals_setL_length _ _ _
    · intro y hy
      exact locals_setL_ne _ (fun e => hy (chg_dstOne.mpr e)) _
    · intro y _ hc
      rw [chg_dstOne.mp hc]
      exact refkind_class hK' hdr _
    · intro l n h; exact h
    · intro y hy hp
      have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
      rw [pinned_defK_ne _ _ _ (by rw [length_demote]; exact hda) hyd, pinned_demote _ _ hxa]
      exact hp
  · simp at hs

theorem sim_dup {cls : List Range.Cls} {d x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.dup d x) = some a') (hm : mop st (.dup d x) = .ok st')
    (hK' : KCls cls a') :
    Range.GenOK cls (miRI (.dup d x)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, hxa, _, hxr⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hdl : d < st.locals.length := hI.len ▸ hda
    have hxl : x < st.locals.length := hI.len ▸ hxa
    have hdr : (gk (defK (demote a x) d .owned) d).isRef = true := by
      rw [gk_defK _ _ _ _ (by rw [length_demote]; exact hda)]; simp [AS.isRef]
    simp only [mop, opCopy, hdl, hxl, and_self, ite_true] at hm
    split at hm
    · simp only [Res.ok.injEq] at hm
      subst hm
      refine genok_frame ?_ ?_ ?_ ?_ ?_
      · simp [St.setL]
      · intro y hy
        have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
        simp [St.setL, List.getElem?_set, Ne.symm hyd]
      · intro y _ hc
        rw [chg_dstOne.mp hc]
        exact refkind_class hK' hdr _
      · intro l n h
        simp only [Range.lensOf, Heap.bump, Option.map_map] at h ⊢
        cases ho : st.heap.objs l <;> simp_all
      · intro y hy hp
        have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
        rw [pinned_defK_ne _ _ _ (by rw [length_demote]; exact hda) hyd, pinned_demote _ _ hxa]
        exact hp
    · cases hm
  · simp at hs


theorem chg_release {cls : List Range.Cls} {x y : Nat} (hc : Range.clsOf cls x = .ref) :
    Range.Chg cls (.gen none [x] [] none) y ↔ y = x := by
  rw [chg_gen]
  simp only [Option.toList, List.nil_append, List.mem_singleton, List.not_mem_nil, not_false_eq_true,
    reduceCtorEq, false_or, true_and]
  constructor
  · rintro ⟨h1, _⟩; exact h1
  · intro h; subst h; exact ⟨rfl, hc⟩

theorem sim_release {cls : List Range.Cls} {x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.release x) = some a') (hm : mop st (.release x) = .ok st')
    (hK : KCls cls a) :
    Range.GenOK cls (miRI (.release x)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hxa, hxc⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hxl : x < st.locals.length := hI.len ▸ hxa
    simp only [mop, opRelease, hxl, ite_true, Res.ok.injEq] at hm
    subst hm
    have hcx : Range.clsOf cls x = .ref := hK.counted hxc
    refine genok_frame ?_ ?_ ?_ ?_ ?_
    · simp
    · intro y hy
      have hyx : y ≠ x := fun e => hy ((chg_release hcx).mpr e)
      simp [List.getElem?_set, Ne.symm hyx]
    · intro y _ hc
      rw [(chg_release hcx).mp hc]
      exact VOk_ref hcx _
    · intro l n h; exact h
    · intro y hy hp
      have hyx : y ≠ x := fun e => hy ((chg_release hcx).mpr e)
      unfold killK
      rw [pinned_defK_ne _ _ _ hxa hyx]
      exact hp
  · simp at hs


/-! ### `getField` -/

/-- what a successful `opGetFieldE` does -/
theorem getE_spec {oob : Res St} (hoob : ∀ s', oob ≠ .ok s') {d o i : Nat} {r : Bool}
    (h : opGetFieldE oob st d o i r = .ok st') :
    d < st.locals.length ∧ o < st.locals.length ∧
      ∃ l ob w, st.get o = .ref l ∧ st.heap.objs l = some ob ∧ ob.fields[i]? = some w ∧
        st' = st.setL d w ∧ (r = true → ∃ l, w = .ref l) ∧ (r = false → ∃ n, w = .int n) := by
  unfold opGetFieldE at h
  split at h
  · rename_i hc
    refine ⟨hc.1, hc.2, ?_⟩
    cases hg : st.get o with
    | int _ => simp [hg] at h
    | ref l =>
      simp only [hg] at h
      cases hob : st.heap.objs l with
      | none => simp [hob] at h
      | some ob =>
        simp only [hob] at h
        cases hf : ob.fields[i]? with
        | none => simp only [hf] at h; exact absurd h (hoob _)
        | some w =>
          simp only [hf] at h
          cases r <;> cases w <;> simp at h
          · exact ⟨l, ob, _, rfl, hob, hf, h.symm, by simp, fun _ => ⟨_, rfl⟩⟩
          · exact ⟨l, ob, _, rfl, hob, hf, h.symm, fun _ => ⟨_, rfl⟩, by simp⟩
  · cases h

/-- what `stepGet` does to the kinds: `d` is defined, nothing else loses its pin -/
theorem stepGet_kind {d o : Nat} {r : Bool} {a1 : List AS} (h : stepGet np a d o r = some a1) :
    d < a.length ∧ (gk a o).isRef = true ∧ (r = true → (gk a1 d).isRef = true) ∧
      (r = false → gk a1 d = .init) ∧ (gk a1 d).pinned = false ∧
      ∀ y, y ≠ d → (gk a1 y).pinned = (gk a y).pinned := by
  unfold stepGet at h
  split at h
  · rename_i hc
    obtain ⟨hda, _, _, hor⟩ := hc
    refine ⟨hda, hor, ?_, ?_, ?_, ?_⟩
    · intro hr
      subst hr
      simp only [ite_true] at h
      split at h
      · have h' := Option.some.inj h
        subst h'
        rw [gk_defK _ _ _ _ hda]; simp [AS.isRef]
      · cases h
    · intro hr
      subst hr
      simp only [Bool.false_eq_true, ite_false] at h
      have h' := Option.some.inj h
      subst h'
      exact defK_self _ _ _ hda
    · cases r with
      | true =>
        simp only [ite_true] at h
        split at h
        · have h' := Option.some.inj h
          subst h'
          rw [gk_defK _ _ _ _ hda]; simp [AS.pinned]
        · cases h
      | false =>
        simp only [Bool.false_eq_true, ite_false] at h
        have h' := Option.some.inj h
        subst h'
        rw [defK_self _ _ _ hda]; rfl
    · intro y hy
      cases r with
      | true =>
        simp only [ite_true] at h
        split at h
        · have h' := Option.some.inj h
          subst h'
          exact pinned_defK_ne _ _ _ hda hy
        · cases h
      | false =>
        simp only [Bool.false_eq_true, ite_false] at h
        have h' := Option.some.inj h
        subst h'
        exact pinned_defK_ne _ _ _ hda hy
  · cases h

theorem sim_getField {cls : List Range.Cls} {d o j : Nat} {r : Bool} (hI : Inv ext a st)
    (hs : stepL np a (.getField d o j r) = some a') (hm : mop st (.getField d o j r) = .ok st')
    (hK' : KCls cls a')
    (hres : ∀ n : Int, st'.get d = .int n → (Range.clsOf cls d).okv n) :
    Range.GenOK cls (miRI (.getField d o j r)) (frameOf a st) (frameOf a' st') := by
  obtain ⟨hdl, hol, l, ob, w, hgo, hob, hf, hst, hrw, hiw⟩ :=
    getE_spec (oob := .ill) (fun s' h => by cases h) (by simpa [mop, opGetField] using hm)
  subst hst
  obtain ⟨hda, _, hk1, hk2, _, hk3⟩ := stepGet_kind (by simpa [stepL] using hs)
  have hdw : (st.setL d w).get d = w := get_setL_self st hdl w
  have hvok : Range.VOk (Range.clsOf cls d) w := by
    cases r with
    | true => exact refkind_class hK' (hk1 rfl) _
    | false =>
      obtain ⟨n, hn⟩ := hiw rfl
      subst hn
      exact VOk_int (hres n hdw)
  refine genok_frame ?_ ?_ ?_ ?_ ?_
  · exact locals_setL_length _ _ _
  · intro y hy
    exact locals_setL_ne _ (fun e => hy (chg_dstOne.mpr e)) _
  · intro y _ hc
    rw [chg_dstOne.mp hc, hdw]
    exact hvok
  · intro l n h; exact h
  · intro y hy hp
    rw [hk3 y (fun e => hy (chg_dstOne.mpr e))]
    exact hp


/-! ### `setField`, `putField` -/

theorem setE_spec {oob : Res St} (hoob : ∀ s', oob ≠ .ok s') {x i v : Nat}
    (h : opSetFieldE oob st x i v = .ok st') :
    ∃ l ob old, x < st.locals.length ∧ v < st.locals.length ∧ st.get x = .ref l ∧
      st.heap.objs l = some ob ∧ ob.rc = 1 ∧ ob.fields[i]? = some old ∧
      st' = setSt st l ob i v old := by
  unfold opSetFieldE at h
  split at h
  · rename_i hc
    cases hg : st.get x with
    | int _ => simp [hg] at h
    | ref l =>
      simp only [hg] at h
      cases hob : st.heap.objs l with
      | none => simp [hob] at h
      | some ob =>
        simp only [hob] at h
        by_cases hrc : ob.rc ≠ 1
        · rw [if_pos hrc] at h; cases h
        · rw [if_neg hrc] at h
          cases hf : ob.fields[i]? with
          | none => simp only [hf] at h; exact absurd h (hoob _)
          | some old =>
            simp only [hf] at h
            have h' := Res.ok.inj h
            exact ⟨l, ob, old, hc.1, hc.2, rfl, hob, by omega, hf, h'.symm⟩
  · cases h

theorem lensOf_setSt (st : St) {l : Nat} {ob : Obj} (hob : st.heap.objs l = some ob) (i v : Nat)
    (old : Val) (k : Nat) : Range.lensOf (setSt st l ob i v old) k = Range.lensOf st k := by
  by_cases hk : k = l
  · subst hk
    simp [Range.lensOf, setSt, Heap.setObj_objs, hob, St.clr, clr_heap]
  · simp [Range.lensOf, setSt, Heap.setObj_objs, hk, clr_heap]

theorem chg_set {cls : List Range.Cls} {x v y : Nat} (hxv : x ≠ v) :
    Range.Chg cls (.gen none [x, v] [x] none) y ↔ y = v ∧ Range.clsOf cls v = .ref := by
  rw [chg_gen]
  simp only [Option.toList, List.nil_append, List.mem_cons, List.mem_singleton, List.not_mem_nil,
    or_false, reduceCtorEq, false_or]
  constructor
  · rintro ⟨h1, h2, h3⟩
    rcases h1 with h1 | h1
    · exact absurd h1 h2
    · subst h1; exact ⟨rfl, h3⟩
  · rintro ⟨h1, h2⟩
    subst h1
    exact ⟨Or.inr rfl, fun e => hxv e.symm, h2⟩

theorem sim_setPut {cls : List Range.Cls} {oob : Res St} (hoob : ∀ s', oob ≠ .ok s')
    {x i v : Nat} (hI : Inv ext a st)
    (hs : stepSet a x v = some a') (hm : opSetFieldE oob st x i v = .ok st') (hK : KCls cls a) :
    Range.GenOK cls (.gen none [x, v] [x] none) (frameOf a st) (frameOf a' st') := by
  obtain ⟨l, ob, old, hxl, hvl, hgx, hob, hrc, hf, hst⟩ := setE_spec hoob hm
  subst hst
  unfold stepSet at hs
  split at hs
  · rename_i hc
    obtain ⟨hxa, hxv, hu⟩ := hc
    obtain ⟨a1, h1, h2⟩ := Option.map_eq_some_iff.mp hs
    subst h2
    obtain ⟨hva, hcons⟩ := consume_spec h1
    have hclrL : ∀ y, ¬ (y = v ∧ Range.clsOf cls v = .ref) →
        (setSt st l ob i v old).locals[y]? = st.locals[y]? := by
      intro y hy
      rcases hcons with ⟨hk, _⟩ | ⟨hk, _⟩
      · obtain ⟨n, hn⟩ := (hI.cl v).ini hk
        simp [setSt, clr_int st v n hn]
      · have hcv := hK.counted hk
        have hyv : y ≠ v := fun e => hy ⟨e, hcv⟩
        obtain ⟨lv, hlv⟩ := (hI.cl v).ref (by cases h : gk a v <;> simp_all [AS.counted, AS.isRef])
        simp only [setSt, St.clr, hlv, St.setL, List.getElem?_set]
        simp [Ne.symm hyv]
    refine genok_frame ?_ ?_ ?_ ?_ ?_
    · simp only [setSt, St.clr]
      cases hg : st.get v <;> simp [St.setL]
    · intro y hy
      exact hclrL y (fun e => hy ((chg_set hxv).mpr e))
    · intro y _ hc
      obtain ⟨rfl, h2⟩ := (chg_set hxv).mp hc
      exact VOk_ref h2 _
    · intro l' n h
      rw [lensOf_setSt st hob]; exact h
    · intro y hy hp
      rw [pinned_killB]
      rcases hcons with ⟨_, h3⟩ | ⟨hk, h3⟩
      · rw [h3]; exact hp
      · have hyv : y ≠ v := fun e => hy ((chg_set hxv).mpr ⟨e, hK.counted hk⟩)
        rw [h3]; unfold killK
        rw [pinned_defK_ne _ _ _ hva hyv]; exact hp
  · simp at hs

theorem sim_setField {cls : List Range.Cls} {x j v : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.setField x j v) = some a') (hm : mop st (.setField x j v) = .ok st')
    (hK : KCls cls a) :
    Range.GenOK cls (miRI (.setField x j v)) (frameOf a st) (frameOf a' st') :=
  sim_setPut (oob := .ill) (fun _ h => by cases h) hI (by simpa [stepL] using hs)
    (by simpa [mop, opSetField] using hm) hK

theorem sim_putField {cls : List Range.Cls} {x j v : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.putField x j v) = some a') (hm : mop st (.putField x j v) = .ok st')
    (hK : KCls cls a) :
    Range.GenOK cls (miRI (.putField x j v)) (frameOf a st) (frameOf a' st') :=
  sim_setPut (oob := .ill) (fun _ h => by cases h) hI (by simpa [stepL] using hs)
    (by simpa [mop, opSetField] using hm) hK


/-! ### `takeField`, run-time sized `arrayNew` -/

theorem take_spec {d x i : Nat} (h : opTakeField st d x i = .ok st') :
    ∃ l ob m, d < st.locals.length ∧ x < st.locals.length ∧ st.get x = .ref l ∧
      st.heap.objs l = some ob ∧ ob.rc = 1 ∧ ob.fields[i]? = some (.ref m) ∧
      st' = takeSt st d l ob i (.ref m) := by
  unfold opTakeField at h
  split at h
  · rename_i hc
    cases hg : st.get x with
    | int _ => simp [hg] at h
    | ref l =>
      simp only [hg] at h
      cases hob : st.heap.objs l with
      | none => simp [hob] at h
      | some ob =>
        simp only [hob] at h
        by_cases hrc : ob.rc ≠ 1
        · rw [if_pos hrc] at h; cases h
        · rw [if_neg hrc] at h
          cases hf : ob.fields[i]? with
          | none => simp [hf] at h
          | some old =>
            simp only [hf] at h
            cases old with
            | int n => simp at h
            | ref m =>
              simp only at h
              have h' := Res.ok.inj h
              exact ⟨l, ob, m, hc.1, hc.2, rfl, hob, by omega, hf, h'.symm⟩
  · cases h

theorem lensOf_takeSt (st : St) {l : Nat} {ob : Obj} (hob : st.heap.objs l = some ob) (d i : Nat)
    (old : Val) (k : Nat) : Range.lensOf (takeSt st d l ob i old) k = Range.lensOf st k := by
  by_cases hk : k = l
  · subst hk
    simp [Range.lensOf, takeSt, Heap.setObj_objs, hob, St.setL]
  · simp [Range.lensOf, takeSt, Heap.setObj_objs, hk, St.setL]

theorem sim_takeField {cls : List Range.Cls} {d x j : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.takeField d x j) = some a') (hm : mop st (.takeField d x j) = .ok st')
    (hK' : KCls cls a') :
    Range.GenOK cls (miRI (.takeField d x j)) (frameOf a st) (frameOf a' st') := by
  obtain ⟨l, ob, m, hdl, hxl, hgx, hob, hrc, hf, hst⟩ := take_spec (by simpa [mop] using hm)
  subst hst
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, hxa, _, hdx, hu⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hkd : (gk (defK (killB x a) d .owned) d).isRef = true := by
      rw [gk_defK _ _ _ _ (by rw [killB_length]; exact hda)]; simp [AS.isRef]
    refine genok_frame ?_ ?_ ?_ ?_ ?_
    · simp [takeSt, St.setL]
    · intro y hy
      have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
      simp [takeSt, St.setL, List.getElem?_set, Ne.symm hyd]
    · intro y _ hc
      rw [chg_dstOne.mp hc]
      exact refkind_class hK' hkd _
    · intro l' n h; rw [lensOf_takeSt st hob]; exact h
    · intro y hy hp
      have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
      rw [pinned_defK_ne _ _ _ (by rw [killB_length]; exact hda) hyd, pinned_killB]
      exact hp
  · simp at hs

theorem sim_arrayNewDyn {cls : List Range.Cls} {d nl : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.arrayNew d nl) = some a') (hm : mop st (.arrayNew d nl) = .ok st')
    (hK' : KCls cls a') :
    Range.GenOK cls (miRI (.arrayNew d nl)) (frameOf a st) (frameOf a' st') := by
  simp only [mop, opArrayNew] at hm
  split at hm
  · rename_i hnl
    cases hg : st.get nl with
    | ref _ => simp [hg] at hm
    | int n =>
      simp only [hg] at hm
      by_cases h0 : 0 ≤ n
      · rw [if_pos h0] at hm
        simp only [opAllocN] at hm
        split at hm
        · rename_i hdl
          have hst := Res.ok.inj hm
          subst hst
          simp only [stepL] at hs
          split at hs
          · rename_i hc
            simp only [stepAlloc] at hs
            split at hs
            · rename_i hc2
              obtain ⟨hda, _⟩ := hc2
              have h' := Option.some.inj hs
              subst h'
              have hkd : (gk (defK a d .unique) d).isRef = true := by
                rw [gk_defK _ _ _ _ hda]; simp [AS.isRef]
              refine genok_frame ?_ ?_ ?_ ?_ ?_
              · simp
              · intro y hy
                have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
                simp [List.getElem?_set, Ne.symm hyd]
              · intro y _ hc
                rw [chg_dstOne.mp hc]
                exact refkind_class hK' hkd _
              · intro l' n' h
                obtain ⟨ob, hob, _⟩ := Option.map_eq_some_iff.mp h
                have hne : l' ≠ st.heap.next := by
                  have : l' < st.heap.next := hI.wf.lt_next hob
                  exact Nat.ne_of_lt this
                simp only [Range.lensOf, Heap.alloc] at h ⊢
                simpa [hne] using h
              · intro y hy hp
                have hyd : y ≠ d := fun e => hy (chg_dstOne.mpr e)
                rw [pinned_defK_ne _ _ _ hda hyd]; exact hp
            · cases hs
          · cases hs
        · cases hm
      · rw [if_neg h0] at hm
        split at hm <;> cases hm
  · cases hm


/-! ### the instructions the analysis knows: `const`, `move`, `alloc` -/

theorem pin_defK (a : List AS) (d : Nat) (k : AS) (hd : d < a.length) (c : Bool)
    (hk : k.pinned = c) (x : Nat) :
    (gk (defK a d k) x).pinned = if x = d then c else (gk a x).pinned := by
  by_cases hx : x = d
  · subst hx; rw [pinned_defK_self _ _ _ hd, if_pos rfl, hk]
  · rw [pinned_defK_ne _ _ _ hd hx, if_neg hx]

theorem frame_put {a a' : List AS} {st st' : St} {d : Nat} {w : Val} {c : Bool}
    (hloc : st'.locals = st.locals.set d w) (hheap : st'.heap = st.heap)
    (hctd : ∀ x, (gk a' x).pinned = if x = d then c else (gk a x).pinned) :
    frameOf a' st' = (frameOf a st).put d w c :=
  cs_ext hloc (fun x => by simp [frameOf, pinOf, Range.CS.put, hctd x])
    (fun l => lensOf_heap_eq hheap l)

theorem sim_const {cls : List Range.Cls} {d : Nat} {n : Int} (hI : Inv ext a st)
    (hs : stepL np a (.const d n) = some a') (hm : mop st (.const d n) = .ok st')
    (hK' : KCls cls a') (hok : (Range.clsOf cls d).okv n) :
    Range.Exec cls (miRI (.const d n)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, _⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hdl : d < st.locals.length := hI.len ▸ hda
    simp only [mop, opConst, hdl, ite_true, Res.ok.injEq] at hm
    subst hm
    have hcd : Range.clsOf cls d ≠ .ref := hK'.init (defK_self _ _ _ hda)
    have hE := Range.Exec.copy (cls := cls) (s := frameOf a st) (d := d) (o := .cint n) (v := n)
      hdl hcd rfl hok
    have hf := frame_put (a := a) (a' := defK a d .init) (st := st) (st' := st.setL d (.int n))
      (d := d) (w := .int n) (c := false) rfl rfl (pin_defK a d .init hda false rfl)
    rw [hf]
    exact hE
  · simp at hs

theorem sim_move {cls : List Range.Cls} {d x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.move d x) = some a') (hm : mop st (.move d x) = .ok st')
    (hK : KCls cls a) (hK' : KCls cls a') :
    Range.Exec cls (miRI (.move d x)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, hxa, _, hdx, hxc⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hdl : d < st.locals.length := hI.len ▸ hda
    have hxl : x < st.locals.length := hI.len ▸ hxa
    simp only [mop, opMove, hdl, hxl, and_self, ite_true, Res.ok.injEq] at hm
    subst hm
    have hcx : Range.clsOf cls x = .ref := hK.counted hxc
    have hkd : (gk (defK (killK a x) d (gk a x)) d).isRef = true := by
      rw [defK_self _ _ _ (by unfold killK; rw [length_defK]; exact hda)]
      cases hk : gk a x <;> simp_all [AS.counted, AS.isRef]
    have hcd : Range.clsOf cls d = .ref := hK'.ref hkd
    have hE := Range.Exec.move (cls := cls) (s := frameOf a st) (d := d) (x := x) hdl hxl hdx hcd hcx
    have hkl : (killK a x).length = a.length := by unfold killK; exact length_defK _ _ _
    have hfe : frameOf (defK (killK a x) d (gk a x)) { st with locals := (st.locals.set d (st.get x)).set x (.int 0) } =
        ((frameOf a st).put d ((frameOf a st).get x) ((frameOf a st).ctd x)).put x (.int 0) false := by
      refine cs_ext rfl (fun y => ?_) (fun l => rfl)
      simp only [frameOf, pinOf, Range.CS.put]
      by_cases hyx : y = x
      · subst hyx
        rw [pinned_defK_ne _ _ _ (by rw [hkl]; exact hda) (Ne.symm hdx)]
        unfold killK
        rw [pinned_defK_self _ _ _ hxa]
        simp [AS.pinned]
      · by_cases hyd : y = d
        · subst hyd
          rw [pinned_defK_self _ _ _ (by rw [hkl]; exact hda)]
          simp [hyx]
        · rw [pinned_defK_ne _ _ _ (by rw [hkl]; exact hda) hyd]
          unfold killK
          rw [pinned_defK_ne _ _ _ hxa hyx]
          simp [hyx, hyd]
    rw [hfe]
    exact hE
  · simp at hs


theorem sim_alloc {cls : List Range.Cls} {d n : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.alloc d n) = some a') (hm : mop st (.alloc d n) = .ok st')
    (hK' : KCls cls a') :
    Range.Exec cls (miRI (.alloc d n)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL, stepAlloc] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, _⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hdl : d < st.locals.length := hI.len ▸ hda
    simp only [mop, opAllocN, hdl, ite_true, Res.ok.injEq] at hm
    subst hm
    have hkd : (gk (defK a d .unique) d).isRef = true := by
      rw [defK_self _ _ _ hda]; rfl
    have hcd : Range.clsOf cls d = .ref := hK'.ref hkd
    have hnone : (frameOf a st).len st.heap.next = none := by
      have hb : st.heap.objs st.heap.next = none := hI.wf.bound _ (Nat.le_refl _)
      show Range.lensOf st st.heap.next = none
      simp [Range.lensOf, hb]
    have hE := Range.Exec.arrayNew (cls := cls) (s := frameOf a st) (d := d) (k := n)
      (l := st.heap.next) hdl hcd hnone
    have hfe : frameOf (defK a d .unique)
        { st with heap := (st.heap.alloc (List.replicate n (.int 0))).1,
                  locals := st.locals.set d (.ref st.heap.next) } =
        ⟨(frameOf a st).loc.set d (.ref st.heap.next),
         fun x => if x = d then true else (frameOf a st).ctd x,
         fun m => if m = st.heap.next then some n else (frameOf a st).len m⟩ := by
      refine cs_ext rfl (fun y => ?_) (fun m => ?_)
      · show (gk (defK a d .unique) y).pinned = _
        rw [pin_defK a d .unique hda true rfl]
        rfl
      · show Range.lensOf _ m = _
        by_cases hm : m = st.heap.next
        · subst hm; simp [Range.lensOf, Heap.alloc]
        · simp [Range.lensOf, Heap.alloc, hm, frameOf]
    rw [hfe]
    exact hE
  · simp at hs

/-! ### `makeUnique` -/

theorem mu_spec {x : Nat} (h : opMakeUnique st x = .ok st') :
    ∃ l ob, x < st.locals.length ∧ st.get x = .ref l ∧ st.heap.objs l = some ob ∧
      ((ob.rc = 1 ∧ st' = st) ∨ (ob.rc ≠ 1 ∧ st' = muSt st x l ob)) := by
  unfold opMakeUnique at h
  split at h
  · rename_i hxl
    cases hg : st.get x with
    | int _ => simp [hg] at h
    | ref l =>
      simp only [hg] at h
      cases hob : st.heap.objs l with
      | none => simp [hob] at h
      | some ob =>
        simp only [hob] at h
        by_cases hrc : ob.rc = 1
        · rw [if_pos hrc] at h
          exact ⟨l, ob, hxl, rfl, hob, Or.inl ⟨hrc, (Res.ok.inj h).symm⟩⟩
        · rw [if_neg hrc] at h
          by_cases hall : ob.fields.all st.heap.liveb = true
          · rw [if_pos hall] at h
            exact ⟨l, ob, hxl, rfl, hob, Or.inr ⟨hrc, (Res.ok.inj h).symm⟩⟩
          · rw [if_neg hall] at h; cases h
  · cases h

theorem lensOf_muSt (hI : Inv ext a st) {x l : Nat} {ob : Obj} (hob : st.heap.objs l = some ob)
    (k : Nat) :
    Range.lensOf (muSt st x l ob) k =
      if k = st.heap.next then some ob.fields.length else Range.lensOf st k := by
  have hlt : l < st.heap.next := hI.wf.lt_next hob
  have hpos : 0 < ob.rc := hI.wf.rcpos l ob hob
  by_cases hk : k = st.heap.next
  · subst hk
    simp [Range.lensOf, muSt, muHeap_new st.heap l ob.fields ob hob hlt hpos]
  · rw [if_neg hk]
    cases hs : st.heap.objs k with
    | none =>
      have : (muHeap st.heap l ob.fields).objs k = none := by
        cases hn : (muHeap st.heap l ob.fields).objs k with
        | none => rfl
        | some o' =>
          rcases muHeap_objs st.heap l ob.fields ob hob hlt hpos k o' hn with ⟨h1, _⟩ | ⟨_, oH, hoH, _⟩
          · exact absurd h1 hk
          · rw [hs] at hoH; cases hoH
      simp [Range.lensOf, muSt, this, hs]
    | some o' =>
      obtain ⟨o'', ho''⟩ := muHeap_live st.heap l ob.fields (.ref k) ⟨o', hs⟩
      rcases muHeap_objs st.heap l ob.fields ob hob hlt hpos k o'' ho'' with ⟨h1, _⟩ | ⟨_, oH, hoH, hf, _⟩
      · exact absurd h1 hk
      · rw [hs] at hoH
        cases hoH
        simp [Range.lensOf, muSt, ho'', hs, hf]

theorem pin_mu (a : List AS) (x : Nat) (hx : x < a.length) (y : Nat) :
    (gk ((killB x a).set x .unique) y).pinned = if y = x then true else (gk a y).pinned := by
  rw [gk_set _ _ _ _ (by rw [killB_length]; exact hx)]
  by_cases hy : y = x
  · simp [hy, AS.pinned]
  · simp [hy, pinned_killB]

theorem sim_makeUnique {cls : List Range.Cls} {x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.makeUnique x) = some a') (hm : mop st (.makeUnique x) = .ok st')
    (hK : KCls cls a) :
    Range.Exec cls (miRI (.makeUnique x)) (frameOf a st) (frameOf a' st') := by
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hxa, hcnt⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    obtain ⟨l, ob, hxl, hgx, hob, hcase⟩ := mu_spec (by simpa [mop] using hm)
    have hcx : Range.clsOf cls x = .ref := hK.counted hcnt
    have hpx : (gk a x).pinned = true := by
      cases hk : gk a x <;> simp_all [AS.counted, AS.pinned]
    have hlen : (frameOf a st).len l = some ob.fields.length := by simp [Range.lensOf, hob, frameOf]
    rcases hcase with ⟨hrc, rfl⟩ | ⟨hrc, rfl⟩
    · refine Range.Exec.makeUnique hcx hgx hlen (Or.inl ?_)
      refine cs_ext rfl (fun y => ?_) (fun m => rfl)
      show (gk ((killB x a).set x .unique) y).pinned = (gk a y).pinned
      rw [pin_mu a x hxa]
      by_cases hy : y = x
      · subst hy; simp [hpx]
      · simp [hy]
    · refine Range.Exec.makeUnique hcx hgx hlen (Or.inr ⟨st.heap.next, hxl, ?_, ?_⟩)
      · have hb : st.heap.objs st.heap.next = none := hI.wf.bound _ (Nat.le_refl _)
        show Range.lensOf st st.heap.next = none
        simp [Range.lensOf, hb]
      · refine cs_ext rfl (fun y => ?_) (fun m => ?_)
        · show (gk ((killB x a).set x .unique) y).pinned = _
          rw [pin_mu a x hxa]; rfl
        · show Range.lensOf (muSt st x l ob) m = _
          rw [lensOf_muSt hI hob]; rfl
  · simp at hs


/-! ### `arrayLen`, `arrayGet`, `arraySet` -/

theorem frame_put_len {a a' : List AS} {st st' : St} {d : Nat} {w : Val} {c : Bool}
    (hloc : st'.locals = st.locals.set d w) (hlen : ∀ l, Range.lensOf st' l = Range.lensOf st l)
    (hctd : ∀ x, (gk a' x).pinned = if x = d then c else (gk a x).pinned) :
    frameOf a' st' = (frameOf a st).put d w c :=
  cs_ext hloc (fun x => by simp [frameOf, pinOf, Range.CS.put, hctd x]) hlen

theorem len_spec {d x : Nat} (h : opArrayLen st d x = .ok st') :
    ∃ l ob, d < st.locals.length ∧ x < st.locals.length ∧ st.get x = .ref l ∧
      st.heap.objs l = some ob ∧ st' = st.setL d (.int ob.fields.length) := by
  unfold opArrayLen at h
  split at h
  · rename_i hc
    cases hg : st.get x with
    | int _ => simp [hg] at h
    | ref l =>
      simp only [hg] at h
      cases hob : st.heap.objs l with
      | none => simp [hob] at h
      | some ob =>
        simp only [hob] at h
        exact ⟨l, ob, hc.1, hc.2, rfl, hob, (Res.ok.inj h).symm⟩
  · cases h

theorem sim_arrayLen {cls : List Range.Cls} {d x : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.arrayLen d x) = some a') (hm : mop st (.arrayLen d x) = .ok st')
    (hK : KCls cls a) (hK' : KCls cls a')
    (hnum : Range.clsOf cls d = .int ∨ Range.clsOf cls d = .usize) :
    Range.Exec cls (miRI (.arrayLen d x)) (frameOf a st) (frameOf a' st') := by
  obtain ⟨l, ob, hdl, hxl, hgx, hob, hst⟩ := len_spec (by simpa [mop] using hm)
  subst hst
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hda, _, _, hxr⟩ := hc
    have h' := Option.some.inj hs
    subst h'
    have hcd : Range.clsOf cls d ≠ .ref := hK'.init (defK_self _ _ _ hda)
    have hcx : Range.clsOf cls x = .ref := hK.ref hxr
    have hokv : (Range.clsOf cls d).okv (ob.fields.length : Int) := by
      rcases hnum with h | h <;> rw [h] <;> simp [Range.Cls.okv]
    have hE := Range.Exec.arrLen (cls := cls) (s := frameOf a st) (d := d) (a := x) (l := l)
      (n := ob.fields.length) hdl hcd hcx hgx (by simp [Range.lensOf, hob, frameOf]) hokv
    have hf := frame_put (a := a) (a' := defK a d .init) (st := st)
      (st' := st.setL d (.int ob.fields.length)) (d := d) (w := .int ob.fields.length) (c := false)
      rfl rfl (pin_defK a d .init hda false rfl)
    rw [hf]
    exact hE
  · simp at hs

theorem arrayGet_spec {d x i : Nat} {r : Bool} (h : opArrayGet st d x i r = .ok st') :
    ∃ n : Int, i < st.locals.length ∧ st.get i = .int n ∧ 0 ≤ n ∧
      opGetFieldE .trap st d x n.toNat r = .ok st' := by
  unfold opArrayGet at h
  split at h
  · rename_i hil
    cases hg : st.get i with
    | ref _ => simp [hg] at h
    | int n =>
      simp only [hg] at h
      by_cases h0 : 0 ≤ n
      · rw [if_pos h0] at h
        exact ⟨n, hil, rfl, h0, h⟩
      · rw [if_neg h0] at h
        split at h
        · cases hg2 : st.get x with
          | int _ => simp [hg2] at h
          | ref l =>
            simp only [hg2] at h
            cases hob : st.heap.objs l <;> simp [hob] at h
        · cases h
  · cases h

theorem sim_arrayGet {cls : List Range.Cls} {d x i : Nat} {r : Bool} (hI : Inv ext a st)
    (hs : stepL np a (.arrayGet d x i r) = some a') (hm : mop st (.arrayGet d x i r) = .ok st')
    (hK : KCls cls a) (hK' : KCls cls a')
    (hres : ∀ n : Int, st'.get d = .int n → (Range.clsOf cls d).okv n) :
    Range.Exec cls (miRI (.arrayGet d x i r)) (frameOf a st) (frameOf a' st') := by
  obtain ⟨n, hil, hgi, h0, hg⟩ := arrayGet_spec (by simpa [mop] using hm)
  obtain ⟨hdl, hxl, l, ob, w, hgx, hob, hf, hst, hrw, hiw⟩ := getE_spec (oob := .trap)
    (fun s' h => by cases h) hg
  subst hst
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hia, hini⟩ := hc
    obtain ⟨hda, hxr, hk1, hk2, hk3, hk4⟩ := stepGet_kind hs
    have hcx : Range.clsOf cls x = .ref := hK.ref hxr
    have hci : Range.clsOf cls i ≠ .ref := hK.init hini
    have hdw : (st.setL d w).get d = w := get_setL_self st hdl w
    have hvok : Range.VOk (Range.clsOf cls d) w := by
      cases r with
      | true => exact refkind_class hK' (hk1 rfl) _
      | false =>
        obtain ⟨m, hm'⟩ := hiw rfl
        subst hm'
        exact VOk_int (hres m hdw)
    have hev : Range.evalOpd cls (frameOf a st) (.loc i) = some n := by
      simp [Range.evalOpd, hci, frameOf_get, hgi]
    have hlt : n < (ob.fields.length : Int) := by
      have := (List.getElem?_eq_some_iff.mp hf).1
      omega
    have hE := Range.Exec.get (cls := cls) (s := frameOf a st) (d := d) (a := x) (l := l)
      (n := ob.fields.length) (i := .loc i) (iv := n) (w := w) hdl hcx hgx
      (by simp [Range.lensOf, hob, frameOf]) hev h0 hlt hvok
    have hf2 := frame_put (a := a) (a' := a') (st := st) (st' := st.setL d w) (d := d) (w := w)
      (c := false) rfl rfl (fun y => by
        by_cases hy : y = d
        · subst hy; rw [if_pos rfl]; exact hk3
        · rw [if_neg hy]; exact hk4 y hy)
    rw [hf2]
    exact hE
  · simp at hs

theorem arraySet_spec {x i v : Nat} (h : opArraySet st x i v = .ok st') :
    ∃ n : Int, i < st.locals.length ∧ st.get i = .int n ∧ 0 ≤ n ∧
      opSetFieldE .trap st x n.toNat v = .ok st' := by
  unfold opArraySet at h
  split at h
  · rename_i hil
    cases hg : st.get i with
    | ref _ => simp [hg] at h
    | int n =>
      simp only [hg] at h
      by_cases h0 : 0 ≤ n
      · rw [if_pos h0] at h
        exact ⟨n, hil, rfl, h0, h⟩
      · rw [if_neg h0] at h
        split at h
        · cases hg2 : st.get x with
          | int _ => simp [hg2] at h
          | ref l =>
            simp only [hg2] at h
            cases hob : st.heap.objs l with
            | none => simp [hob] at h
            | some ob =>
              simp only [hob] at h
              split at h <;> cases h
        · cases h
  · cases h

theorem sim_arraySet {cls : List Range.Cls} {x i v : Nat} (hI : Inv ext a st)
    (hs : stepL np a (.arraySet x i v) = some a') (hm : mop st (.arraySet x i v) = .ok st')
    (hK : KCls cls a) :
    Range.Exec cls (miRI (.arraySet x i v)) (frameOf a st) (frameOf a' st') := by
  obtain ⟨n, hil, hgi, h0, hset⟩ := arraySet_spec (by simpa [mop] using hm)
  obtain ⟨l, ob, old, hxl, hvl, hgx, hob, hrc, hf, hst⟩ := setE_spec (oob := .trap)
    (fun s' h => by cases h) hset
  subst hst
  simp only [stepL] at hs
  split at hs
  · rename_i hc
    obtain ⟨hia, hini⟩ := hc
    unfold stepSet at hs
    split at hs
    · rename_i hc2
      obtain ⟨hxa, hxv, hu⟩ := hc2
      obtain ⟨a1, h1, h2⟩ := Option.map_eq_some_iff.mp hs
      subst h2
      obtain ⟨hva, hcons⟩ := consume_spec h1
      have hcx : Range.clsOf cls x = .ref := hK.ref (by simp [hu, AS.isRef])
      have hci : Range.clsOf cls i ≠ .ref := hK.init hini
      have hev : Range.evalOpd cls (frameOf a st) (.loc i) = some n := by
        simp [Range.evalOpd, hci, frameOf_get, hgi]
      have hlt : n < (ob.fields.length : Int) := by
        have := (List.getElem?_eq_some_iff.mp hf).1
        omega
      refine Range.Exec.set (cls := cls) (s := frameOf a st) (a := x) (l := l)
        (n := ob.fields.length) (i := .loc i) (iv := n) (v := v) hcx hgx
        (by simp [Range.lensOf, hob, frameOf]) hev h0 hlt ?_
      rcases hcons with ⟨hk, h3⟩ | ⟨hk, h3⟩
      · left
        obtain ⟨m, hm'⟩ := (hI.cl v).ini hk
        refine cs_ext ?_ (fun y => ?_) (fun l' => ?_)
        · show (st.clr v).locals = st.locals
          rw [clr_int st v m hm']
        · show (gk (killB x a1) y).pinned = (gk a y).pinned
          rw [pinned_killB, h3]
        · exact lensOf_setSt st hob _ _ _ _
      · right
        have hcv : Range.clsOf cls v = .ref := hK.counted hk
        obtain ⟨lv, hlv⟩ := (hI.cl v).ref (by cases h : gk a v <;> simp_all [AS.counted, AS.isRef])
        refine ⟨hvl, hcv, ?_⟩
        refine frame_put_len (a := a) (a' := killB x a1) (st := st) (d := v) (w := .int 0) (c := false)
          ?_ (fun l' => lensOf_setSt st hob _ _ _ _) (fun y => ?_)
        · simp only [setSt, St.clr, hlv, St.setL]
        · rw [pinned_killB, h3]
          unfold killK
          exact pin_defK a v .dead hva false rfl y
    · cases hs
  · simp at hs


/-! ### every instruction of the machine is a step of the analysis -/

/-- the static class condition of an instruction that the kinds do not give: a constant is a legal
value of the class of its local, a length goes into a numeric local -/
def MiWf (cls : List Range.Cls) : MI → Prop
  | .const d n => (Range.clsOf cls d).okv n
  | .arrayLen d _ => Range.clsOf cls d = .int ∨ Range.clsOf cls d = .usize
  | _ => True

/-- a scalar read from the heap respects the class of the local that receives it (the machine has
neither integer classes nor array contents: this is what stays a hypothesis) -/
def SRes (cls : List Range.Cls) (st' : St) : MI → Prop
  | .getField d _ _ _ => ∀ n : Int, st'.get d = .int n → (Range.clsOf cls d).okv n
  | .arrayGet d _ _ _ => ∀ n : Int, st'.get d = .int n → (Range.clsOf cls d).okv n
  | _ => True

theorem genwf_dstOne (d z : Nat) : Range.GenWf (.gen (some d) [z] (keepNe d [z]) none) :=
  ⟨fun x hx hk => by
    have := (mem_keepNe.mp hk).2
    rw [Option.some.inj hx] at this
    exact this rfl, fun x hx => by cases hx⟩

theorem genwf_none (men kept : List Nat) : Range.GenWf (.gen none men kept none) :=
  ⟨(fun x hx => by cases hx), (fun x hx => by cases hx)⟩

/-- **A successful step of the machine, accepted by the kind transfer function, is a step of the
semantics of the interval analysis** (`Range.Exec`) between the frame models of the two states: the
descriptor of the instruction (`miRI`: `dst`, `men`, `kept` for a `gen`) is fixed per instruction, the
ghost bit is the pin of the kinds, and the contract `GenOK` of the builtins is derived from the
machine. -/
theorem mop_exec {cls : List Range.Cls} {i : MI} (hI : Inv ext a st)
    (hs : stepL np a i = some a') (hm : mop st i = .ok st') (hK : KCls cls a) (hK' : KCls cls a')
    (hw : MiWf cls i) (hr : SRes cls st' i) :
    Range.Exec cls (miRI i) (frameOf a st) (frameOf a' st') := by
  cases i with
  | const d n => exact sim_const hI hs hm hK' hw
  | move d x => exact sim_move hI hs hm hK hK'
  | borrow d x => exact Range.Exec.gen (genwf_dstOne d x) (sim_borrow hI hs hm hK')
  | dup d x => exact Range.Exec.gen (genwf_dstOne d x) (sim_dup hI hs hm hK')
  | release x => exact Range.Exec.gen (genwf_none _ _) (sim_release hI hs hm hK)
  | alloc d n => exact sim_alloc hI hs hm hK'
  | getField d o j r => exact Range.Exec.gen (genwf_dstOne d o) (sim_getField hI hs hm hK' hr)
  | setField x j v => exact Range.Exec.gen (genwf_none _ _) (sim_setField hI hs hm hK)
  | takeField d x j => exact Range.Exec.gen (genwf_dstOne d x) (sim_takeField hI hs hm hK')
  | putField x j y => exact Range.Exec.gen (genwf_none _ _) (sim_putField hI hs hm hK)
  | makeUnique x => exact sim_makeUnique hI hs hm hK
  | arrayLen d x => exact sim_arrayLen hI hs hm hK hK' hw
  | arrayGet d x i r => exact sim_arrayGet hI hs hm hK hK' hr
  | arraySet x i v => exact sim_arraySet hI hs hm hK
  | arrayNew d nl => exact Range.Exec.gen (genwf_dstOne d nl) (sim_arrayNewDyn hI hs hm hK')


/-! ### calls: the frame models defined by the kinds, `hcls` and the reference part of `hres` derived -/

/-- the frame model of the caller after the return: its locals with the result stored, the lengths of
the current heap, the ghost bit from the kinds after the call -/
def callFrame (site : Site) (fr : Frame) (st : St) : Range.CS :=
  frameOf site.a1.ls ⟨st.heap, fr.L.set fr.d (st.get fr.ret), []⟩

/-- `GenOK` for the frame models defined by the kinds: only the class table against the kinds and the
class of a scalar result are hypotheses -/
def RetGenOKk (site : Site) (fr : Frame) (st : St) : Prop :=
  ∀ (cls : List Range.Cls), KCls cls site.b → KCls cls site.a1.ls →
    (∀ n : Int, fr.retRef = false → st.get fr.ret = .int n → (Range.clsOf cls fr.d).okv n) →
    Range.GenOK cls (callRI fr.d site.args site.ps)
      (frameOf site.b ⟨site.H0, site.L0, []⟩) (callFrame site fr st)

theorem genok_ctd {cls : List Range.Cls} {ins : Range.RI} {s s1 s1' : Range.CS}
    (h : Range.GenOK cls ins s s1) (hloc : s1'.loc = s1.loc) (hlen : s1'.len = s1.len)
    (hctd : ∀ x, s1.ctd x = true → s1'.ctd x = true) : Range.GenOK cls ins s s1' where
  size := by rw [hloc]; exact h.size
  same := fun x hx => by rw [hloc]; exact h.same x hx
  vok := fun x hx hc => by
    have := h.vok x hx hc
    simpa [Range.CS.get, hloc] using this
  own := fun x l n hx hl hc hn => by
    obtain ⟨h1, h2⟩ := h.own x l n hx hl hc hn
    exact ⟨by rw [hlen]; exact h1, hctd x h2⟩

/-- **`ret_genok` with the ghost bit defined by the kinds.**  The hypotheses `hcls` (an owned operand
is a reference-class local) and `hres` (the stored result respects the class of its local) of
`ret_genok` are derived: an owned operand is counted, so its class is `ref` (`KCls`); a returned
reference lands in a local that the kinds call a reference, hence of class `ref`; a returned scalar is
an integer (`Inv`), whose class condition (`usize` not negative, `bool` 0 or 1) is the one remaining
hypothesis `hresS`. -/
theorem ret_genok_k {sg : List Sig} {site : Site} {ss : List Site} {fr : Frame} {rest : List Frame}
    {st : St} (hG : GoodW sg (site :: ss) (fr :: rest) (.nil, st)) : RetGenOKk site fr st := by
  intro cls hKb hKa hresS
  have hG0 := hG
  obtain ⟨ext, np, E, a, hC, hI, hS, hE⟩ := hG0
  obtain ⟨he, hL, hIb, hlenA, hnd, hd, hargs, ha1, hk, hE1, hFz, hrest⟩ := hS
  have hcls : ∀ x ∈ site.own, Range.clsOf cls x = .ref :=
    fun x hx => hKb.counted (own_counted hargs x hx)
  have hlb : site.b.length = site.L0.length := hIb.len
  have hdb : fr.d < site.b.length := by
    have : fr.d < fr.L.length := hd
    rw [hL, clrL_length] at this
    omega
  have hkd : gk site.a1.ls fr.d = retK fr.retRef := by
    rw [ha1]
    exact defK_self _ _ _ (by rw [Site.mid, length_midK]; exact hdb)
  obtain ⟨b, hbE, hweak⟩ := Cont.nil_inv hC
  have hEr := hE fr rest rfl
  subst hEr
  have hIbb := hweak ext st hI
  have hres : Range.VOk (Range.clsOf cls fr.d) (st.get fr.ret) := by
    cases hrr : fr.retRef with
    | true =>
      rw [hrr] at hkd
      have hcd : Range.clsOf cls fr.d = .ref := hKa.ref (by rw [hkd]; rfl)
      exact VOk_ref hcd _
    | false =>
      have hini : gk b.ls fr.ret = .init := hbE.2.2 hrr
      obtain ⟨n, hn⟩ := (hIbb.cl fr.ret).ini hini
      rw [hn]
      exact VOk_int (hresS n hrr hn)
  obtain ⟨s1, hloc1, hlen1, hctd1, hG1⟩ :=
    ret_genok hG cls hcls hres (frameOf site.b ⟨site.H0, site.L0, []⟩) rfl (fun l => rfl)
      (fun x hx => hx)
  exact genok_ctd hG1 hloc1.symm (funext fun l => (hlen1 l).symm) (fun x hx => hctd1 x hx)

/-- every return of a call in a run of an accepted program, with the frame models defined by the
kinds (same entry conditions as `prog_ret_genok`) -/
theorem prog_ret_genok_k {fns : List Fn} (hp : pcheck fns = true) {f : Nat} {fn : Fn}
    (hf : fns[f]? = some fn)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c)
    {fr : Frame} {rest : List Frame} (hs : c.stk = fr :: rest) (hc : c.code = .nil) :
    ∃ (site : Site), RetGenOKk site fr c.st := by
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
    exact ⟨site, ret_genok_k hG'⟩


/-- the ghost bit of the frame model is the pin of the kinds, so `Held` for an array local is a fact
about the kinds -/
theorem held_of_kind (a : List AS) (st : St) {x : Nat} (h : (gk a x).pinned = true) :
    Range.Held x (frameOf a st) := fun _ _ => h

end Orin
