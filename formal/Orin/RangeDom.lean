import Orin.RangeNarrow

/-!
# Rule U1, the source "dominated-by-check" (T2)

`compiler/verify/unchecked.or` (`uncheckedJustified`) with `scan.or` accepts an unchecked access of
`a[key]` when a backward scan of the **same block**, over at most `WINDOW = 64` instructions, finds
an earlier access of the same array local and the same index (which passed the kind and bounds
check) before anything could have changed the object or the index.  This file transcribes the scan
(`verdict`, `Defs`, `KeyDefs`, `scan`) over the instruction model `RI` and proves it sound:

`dom_sound`: if the scan over the reversed prefix `pre` succeeds, then in every execution
`RunI pre s s'` the array local holds a live array and the index is a valid slot of it
(`InBounds`).  `t2_machine` carries this to the heap of the machine (`u1_machine`).

Assumptions, all of them facts the verifier establishes elsewhere:

* `opCls cls key ≠ .ref`: the index is a scalar (`wf.or`: `opIs(.., CUsize)`);
* `NoSelf`: an `IArraySet(x, i, v)` never stores the array into itself (`wf.or`, `valueOk`:
  `!isLocal(v, x)`);
* `Held a`: whenever the array local holds a reference at a point of the prefix, it is a *pinned*
  reference (the `ctd` ghost bit of `RangeSem.lean`: counted, or lent by the caller as a `Param`).  The
  contract `GenOK` keeps the object of a pinned reference alive and as long as it was across an
  instruction that does not mention the local.  `Held` is a hypothesis of `dom_sound` / `t2_sound`;
  `RangePin.lean` discharges it for an array parameter that the function only uses in kept positions
  (`t2_param`), `CallLink.lean` ties the bit to the ownership kinds (`pinA_of_inv`).
-/

namespace Orin
namespace Range

/-- the verdict of one instruction of the scan (`scan.or`: `PASS`, `SOURCE`, `STOP`) -/
inductive Vd where
  | pass
  | source
  | stop
  deriving DecidableEq

/-- `sameKey`: the same constant or the same local -/
def sameKey : Opd → Opd → Bool
  | .loc x, .loc y => decide (x = y)
  | .cusize x, .cusize y => decide (x = y)
  | _, _ => false

theorem sameKey_eq {k o : Opd} (h : sameKey k o = true) : o = k := by
  cases k <;> cases o <;> simp_all [sameKey]

/-- `access`: an access `x[o]` of the array: the source when it is our index (and defines neither
`a` nor the index local), no effect for another index -/
def access (d : Option Nat) (a : Nat) (key o : Opd) : Vd :=
  if sameKey key o then
    (match d with
     | some m => if m = a ∨ key = .loc m then .stop else .source
     | none => .source)
  else .pass

/-- everything else is harmless unless it mentions `a` -/
def other (ins : RI) (a : Nat) : Vd := if a ∈ ins.men then .stop else .pass

def verdict (ins : RI) (a : Nat) (key : Opd) : Vd :=
  match ins with
  | .get d x i => if x = a then access (some d) a key i else other ins a
  | .set x i _ => if x = a then access none a key i else other ins a
  | .makeUnique x => if x = a then .pass else other ins a
  | .forward _ _ o => if o = a then .pass else other ins a
  | _ => other ins a

/-- `defines`: the destination or the in/out receiver -/
def Defs (ins : RI) (l : Nat) : Bool := decide (ins.dst = some l) || decide (ins.recv = some l)

def KeyDefs (ins : RI) : Opd → Bool
  | .loc l => Defs ins l
  | _ => false

/-- the scan, nearest instruction first, with a budget of `n` instructions (`WINDOW`) -/
def scan (a : Nat) (key : Opd) : Nat → List RI → Bool
  | 0, _ => false
  | _ + 1, [] => false
  | n + 1, ins :: rest =>
    match verdict ins a key with
    | .source => true
    | .stop => false
    | .pass => if Defs ins a || KeyDefs ins key then false else scan a key n rest

/-- `WINDOW` of `scan.or` -/
def WINDOW : Nat := 64

/-- `uncheckedJustified`: the instructions of the block before the access, as `pre` -/
def domOk (a : Nat) (key : Opd) (pre : List RI) : Bool := scan a key WINDOW pre.reverse

/-! ### the hypotheses -/

/-- `wf.or`, `valueOk`: an element store never stores the array into itself -/
def NoSelf : RI → Prop
  | .set x _ v => v ≠ x
  | _ => True

/-- at this point, if `a` holds a reference, it is a pinned one (counted, or a lent parameter) -/
def Held (a : Nat) (s : CS) : Prop := ∀ l, s.get a = .ref l → s.ctd a = true

/-! ### facts about the states -/

theorem inb_same {cls : List Cls} {a : Nat} {key : Opd} {s s' : CS}
    (ha : s'.loc[a]? = s.loc[a]?) (hk : ∀ y, key = .loc y → s'.loc[y]? = s.loc[y]?)
    (hl : ∀ l n, s.len l = some n → s'.len l = some n) (h : InBounds cls s a key) :
    InBounds cls s' a key := by
  obtain ⟨l, n, iv, hg, hn, hi, h0, h1⟩ := h
  refine ⟨l, n, iv, (get_eq_of_loc ha).trans hg, hl l n hn, ?_, h0, h1⟩
  rw [← hi]
  exact evalOpd_congr (fun y hy => get_eq_of_loc (hk y hy))

theorem put_inb {cls : List Cls} {a d : Nat} {key : Opd} {s : CS} {w : Val} {c : Bool}
    (had : a ≠ d) (hkd : ∀ y, key = .loc y → y ≠ d) (h : InBounds cls s a key) :
    InBounds cls (s.put d w c) a key := by
  refine inb_same (s := s) ?_ ?_ (fun l n h => h) h
  · rw [put_loc]; simp [had]
  · intro y hy
    rw [put_loc]; simp [hkd y hy]

theorem loc_of_get_ref {s : CS} {a l : Nat} (h : s.get a = .ref l) : s.loc[a]? = some (.ref l) := by
  by_cases hlt : a < s.loc.length
  · have := loc_of_get hlt
    rw [this, h]
  · have : s.get a = .int 0 := by
      simp [CS.get, List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega : s.loc.length ≤ a)]
    rw [this] at h
    cases h

theorem set_ne_loc {l : List Val} {d x : Nat} {w : Val} (h : x ≠ d) : (l.set d w)[x]? = l[x]? := by
  simp [List.getElem?_set, Ne.symm h]

theorem defs_false {ins : RI} {key : Opd} {a : Nat} (hd : (Defs ins a || KeyDefs ins key) = false) :
    ins.dst ≠ some a ∧ ins.recv ≠ some a ∧
      ∀ y, key = .loc y → ins.dst ≠ some y ∧ ins.recv ≠ some y := by
  simp only [Bool.or_eq_false_iff] at hd
  obtain ⟨h1, h2⟩ := hd
  simp only [Defs, Bool.or_eq_false_iff, decide_eq_false_iff_not] at h1
  refine ⟨h1.1, h1.2, fun y hy => ?_⟩
  subst hy
  simpa [KeyDefs, Defs] using h2

theorem key_ne_of_ref {cls : List Cls} {key : Opd} (hk : opCls cls key ≠ .ref) {y : Nat}
    (hy : key = .loc y) (hr : clsOf cls y = .ref) : False := by
  subst hy
  exact hk hr

/-! ### the source -/

theorem verdict_source {ins : RI} {a : Nat} {key : Opd} (h : verdict ins a key = .source) :
    (∃ d, ins = .get d a key ∧ d ≠ a ∧ key ≠ .loc d) ∨ (∃ v, ins = .set a key v) := by
  cases ins with
  | get d x i =>
    simp only [verdict] at h
    by_cases hx : x = a
    · rw [if_pos hx] at h
      subst hx
      unfold access at h
      by_cases hs : sameKey key i = true
      · rw [if_pos hs] at h
        have := sameKey_eq hs
        subst this
        by_cases hd : d = x ∨ i = .loc d
        · simp [hd] at h
        · left
          refine ⟨d, rfl, fun e => hd (Or.inl e), fun e => hd (Or.inr e)⟩
      · rw [if_neg hs] at h; cases h
    · rw [if_neg hx] at h
      unfold other at h
      split at h <;> cases h
  | set x i v =>
    simp only [verdict] at h
    by_cases hx : x = a
    · rw [if_pos hx] at h
      subst hx
      unfold access at h
      by_cases hs : sameKey key i = true
      · have := sameKey_eq hs
        subst this
        right; exact ⟨v, rfl⟩
      · rw [if_neg hs] at h; cases h
    · rw [if_neg hx] at h
      unfold other at h
      split at h <;> cases h
  | makeUnique x =>
    simp only [verdict] at h
    split at h
    · cases h
    · unfold other at h; split at h <;> cases h
  | forward d s o =>
    simp only [verdict] at h
    split at h
    · cases h
    · unfold other at h; split at h <;> cases h
  | copy d o => simp only [verdict, other] at h; split at h <;> cases h
  | move d s => simp only [verdict, other] at h; split at h <;> cases h
  | arrayNew d n => simp only [verdict, other] at h; split at h <;> cases h
  | arrLen d x => simp only [verdict, other] at h; split at h <;> cases h
  | add d x y => simp only [verdict, other] at h; split at h <;> cases h
  | sub d x y => simp only [verdict, other] at h; split at h <;> cases h
  | cmp d op x y => simp only [verdict, other] at h; split at h <;> cases h
  | gen dst men kept recv => simp only [verdict, other] at h; split at h <;> cases h

theorem dst_ne {ins : RI} {d a : Nat} (h1 : ins.dst = some d) (h2 : ins.dst ≠ some a) : a ≠ d :=
  fun e => h2 (by rw [h1, e])

theorem source_inb {cls : List Cls} {a : Nat} {key : Opd} {ins : RI} {s s' : CS}
    (hk : opCls cls key ≠ .ref) (hn : NoSelf ins) (hv : verdict ins a key = .source)
    (hE : Exec cls ins s s') : InBounds cls s' a key := by
  rcases verdict_source hv with ⟨d, rfl, hda, hkd⟩ | ⟨v, rfl⟩
  · cases hE with
    | get _ _ hg hn' hev h0 h1 _ =>
      exact put_inb (Ne.symm hda) (fun y hy e => hkd (by rw [hy, e])) ⟨_, _, _, hg, hn', hev, h0, h1⟩
  · cases hE with
    | set hcls hg hn' hev h0 h1 hs =>
      have hb : InBounds cls s a key := ⟨_, _, _, hg, hn', hev, h0, h1⟩
      rcases hs with rfl | ⟨hv1, hv2, rfl⟩
      · exact hb
      · refine put_inb (fun e => hn e.symm) (fun y hy e => ?_) hb
        subst e
        exact key_ne_of_ref hk hy hv2

/-! ### a PASS instruction keeps the fact -/

theorem pass_move {d x a : Nat} {key : Opd} (hp : verdict (.move d x) a key = .pass) : a ≠ d ∧ a ≠ x := by
  simp only [verdict, other, RI.men] at hp
  constructor <;> intro e <;> subst e <;> simp at hp

theorem pass_set {x v a : Nat} {o : Opd} {key : Opd} (hp : verdict (.set x o v) a key = .pass)
    (hx : x ≠ a) : v ≠ a := by
  simp only [verdict, if_neg hx, other, RI.men] at hp
  intro e; subst e; simp at hp

theorem pass_inb {cls : List Cls} {a : Nat} {key : Opd} {ins : RI} {s s' : CS}
    (hk : opCls cls key ≠ .ref) (hn : NoSelf ins) (hp : verdict ins a key = .pass)
    (hd : (Defs ins a || KeyDefs ins key) = false) (hE : Exec cls ins s s')
    (hH : Held a s) (hI : InBounds cls s a key) : InBounds cls s' a key := by
  obtain ⟨hda, hra, hdy⟩ := defs_false hd
  cases ins with
  | copy d o =>
    cases hE with
    | copy _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | move d x =>
    cases hE with
    | move _ _ _ _ hcx =>
      exact put_inb (pass_move hp).2 (fun y hy e => key_ne_of_ref hk hy (e ▸ hcx))
        (put_inb (pass_move hp).1 (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI)
  | forward d x o =>
    cases hE with
    | forward _ _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | arrayNew d k =>
    cases hE with
    | arrayNew hd0 hcd hl =>
      rename_i l
      have had : a ≠ d := dst_ne rfl hda
      obtain ⟨l0, n0, iv, hg, hn0, hi, h0, h1⟩ := hI
      have hl0 : l0 ≠ l := by
        intro e; rw [e, hl] at hn0; cases hn0
      refine ⟨l0, n0, iv, ?_, ?_, ?_, h0, h1⟩
      · rw [get_eq_of_loc (set_ne_loc had)]
        exact hg
      · simp [hl0, hn0]
      · rw [← hi]
        exact evalOpd_congr (fun y hy => get_eq_of_loc (set_ne_loc (fun e => (hdy y hy).1 (by simp [RI.dst, e]))))
  | arrLen d x =>
    cases hE with
    | arrLen _ _ _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | add d x y =>
    cases hE with
    | add _ _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | sub d x y =>
    cases hE with
    | sub _ _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | cmp d op x y =>
    cases hE with
    | cmp _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | get d x i =>
    cases hE with
    | get _ _ _ _ _ _ _ _ =>
      exact put_inb (dst_ne rfl hda) (fun y hy e => (hdy y hy).1 (by simp [RI.dst, e])) hI
  | set x i v =>
    cases hE with
    | set hca hg hl hev h0 h1 hs =>
      rcases hs with rfl | ⟨hv1, hv2, rfl⟩
      · exact hI
      · have hva : v ≠ a := by
          by_cases hxa : x = a
          · subst hxa; exact hn
          · exact pass_set hp hxa
        exact put_inb (Ne.symm hva) (fun y hy e => by subst e; exact key_ne_of_ref hk hy hv2) hI
  | makeUnique x =>
    cases hE with
    | makeUnique hca hg hl hs =>
      rcases hs with rfl | ⟨m, hx0, hm, rfl⟩
      · exact hI
      · by_cases hxa : x = a
        · subst hxa
          obtain ⟨l0, n0, iv, hg0, hn0, hi, h0, h1⟩ := hI
          rw [hg] at hg0; cases hg0
          rw [hl] at hn0; cases hn0
          refine ⟨m, _, iv, ?_, by simp, ?_, h0, h1⟩
          · have : (s.loc.set x (Val.ref m))[x]? = some (.ref m) := by
              simp [List.getElem?_set, hx0]
            exact get_of_loc this
          · rw [← hi]
            refine evalOpd_congr (fun y hy => get_eq_of_loc (set_ne_loc (fun e => ?_)))
            subst e
            exact key_ne_of_ref hk hy hca
        · obtain ⟨l0, n0, iv, hg0, hn0, hi, h0, h1⟩ := hI
          have hl0 : l0 ≠ m := by
            intro e; subst e; rw [hm] at hn0; cases hn0
          refine ⟨l0, n0, iv, ?_, by simp [hl0, hn0], ?_, h0, h1⟩
          · rw [get_eq_of_loc (set_ne_loc (Ne.symm hxa))]
            exact hg0
          · rw [← hi]
            refine evalOpd_congr (fun y hy => get_eq_of_loc (set_ne_loc (fun e => ?_)))
            subst e
            exact key_ne_of_ref hk hy hca
  | gen dst men kept recv =>
    cases hE with
    | gen hw hG =>
      simp only [verdict, other, RI.men] at hp
      have ham : a ∉ dst.toList ++ men := by
        intro e; simp [e] at hp
      have hnca : ¬ Chg cls (.gen dst men kept recv) a := by
        intro hc
        rcases hc with h | h | ⟨h1, _⟩ | h
        · exact hda h
        · exact hra h
        · exact ham h1
        · cases h
      obtain ⟨l0, n0, iv, hg0, hn0, hi, h0, h1⟩ := hI
      have hlc := loc_of_get_ref hg0
      have hown := hG.own a l0 n0 hnca hlc (hH l0 hg0) hn0
      refine ⟨l0, n0, iv, ?_, hown.1, ?_, h0, h1⟩
      · rw [get_eq_of_loc (hG.same a hnca)]; exact hg0
      · rw [← hi]
        refine evalOpd_congr (fun y hy => get_eq_of_loc (hG.same y ?_))
        intro hc
        rcases hc with h | h | ⟨_, _, h3⟩ | h
        · exact (hdy y hy).1 h
        · exact (hdy y hy).2 h
        · exact key_ne_of_ref hk hy h3
        · cases h

/-! ### the scan -/

theorem runI_snoc {cls : List Cls} {i : RI} :
    ∀ {p : List RI} {s s2 : CS}, RunI cls (p ++ [i]) s s2 → ∃ s1, RunI cls p s s1 ∧ Exec cls i s1 s2 := by
  intro p
  induction p with
  | nil =>
    intro s s2 h
    cases h with
    | cons he hr =>
      cases hr
      exact ⟨s, RunI.nil, he⟩
  | cons j p ih =>
    intro s s2 h
    cases h with
    | cons he hr =>
      obtain ⟨s1, h1, h2⟩ := ih hr
      exact ⟨s1, RunI.cons he h1, h2⟩

/-- **T2, soundness of the backward scan.**  If the scan over the instructions before the access
(nearest first) accepts, the array local holds a live array with a valid slot at the index, in every
execution of the prefix. -/
theorem dom_sound {cls : List Cls} {a : Nat} {key : Opd} (hk : opCls cls key ≠ .ref) :
    ∀ (n : Nat) (l : List RI) {s s' : CS}, (∀ i ∈ l, NoSelf i) →
      (∀ p s1, p <+: l.reverse → RunI cls p s s1 → Held a s1) →
      RunI cls l.reverse s s' → scan a key n l = true → InBounds cls s' a key := by
  intro n l
  induction l generalizing n with
  | nil => intro s s' _ _ _ h; cases n <;> simp [scan] at h
  | cons ins rest ih =>
    intro s s' hn hH hr hs
    cases n with
    | zero => simp [scan] at hs
    | succ n =>
      rw [List.reverse_cons] at hr hH
      obtain ⟨s1, hr1, hE⟩ := runI_snoc hr
      have hH1 : Held a s1 := hH _ s1 (List.prefix_append _ _) hr1
      simp only [scan] at hs
      generalize hv : verdict ins a key = v at hs
      cases v with
      | source =>
        exact source_inb hk (hn ins List.mem_cons_self) hv hE
      | stop => simp at hs
      | pass =>
        simp only at hs
        by_cases hd : (Defs ins a || KeyDefs ins key) = true
        · simp [hd] at hs
        · have hd' : (Defs ins a || KeyDefs ins key) = false := by simpa using hd
          rw [if_neg (by simpa using hd)] at hs
          have hI := ih n (s := s) (s' := s1) (fun i hi => hn i (List.mem_cons_of_mem _ hi))
            (fun p s2 hp hr2 => hH p s2 (hp.trans (List.prefix_append _ _)) hr2) hr1 hs
          exact pass_inb hk (hn ins List.mem_cons_self) hv hd' hE hH1 hI

/-- the instructions before the access, as `pre`; the access is the next one -/
theorem t2_sound {cls : List Cls} {a : Nat} {key : Opd} (hk : opCls cls key ≠ .ref)
    {pre : List RI} {s s' : CS} (hn : ∀ i ∈ pre, NoSelf i)
    (hH : ∀ p s1, p <+: pre → RunI cls p s s1 → Held a s1)
    (hr : RunI cls pre s s') (hd : domOk a key pre = true) : InBounds cls s' a key := by
  unfold domOk at hd
  refine dom_sound (s := s) (s' := s') hk WINDOW pre.reverse ?_ ?_ ?_ hd
  · intro i hi; exact hn i (List.mem_reverse.mp hi)
  · rw [List.reverse_reverse]; exact hH
  · rw [List.reverse_reverse]; exact hr

/-- T2 for a block: the access is the instruction after `pre` in block `b`; the prefix runs from a
reachable block entry. -/
theorem t2_block {fn : Fn} {b : Nat} {s_in s_pre : CS} {a : Nat} {key : Opd}
    (hk : opCls fn.cls key ≠ .ref) {pre : List RI} (hn : ∀ i ∈ pre, NoSelf i)
    (hH : ∀ p s1, p <+: pre → RunI fn.cls p s_in s1 → Held a s1)
    (_hr : Reach fn b s_in) (hrun : RunI fn.cls pre s_in s_pre) (hd : domOk a key pre = true) :
    InBounds fn.cls s_pre a key :=
  t2_sound hk hn hH hrun hd

/-- the machine view: the unchecked access cannot trap (`arrayGet_oob` cannot fire) -/
theorem t2_machine {cls : List Cls} {a : Nat} {key : Opd} {st : St} {s : CS} (hr : Rel s st)
    (h : InBounds cls s a key) :
    ∃ l ob iv, st.get a = .ref l ∧ st.heap.objs l = some ob ∧ evalOpd cls s key = some iv ∧
      0 ≤ iv ∧ iv.toNat < ob.fields.length :=
  u1_machine hr h

/-! ### examples, as in the verifier's tests: a load justifies the next load of the same index -/

-- `x = a[i]; y = a[i]`: the second is justified
example : domOk 0 (.loc 1) [.get 2 0 (.loc 1)] = true := by decide
-- a store of another index in between does not matter
example : domOk 0 (.loc 1) [.get 2 0 (.loc 1), .set 0 (.cint 5) 3] = true := by decide
-- redefining the index in between does
example : domOk 0 (.loc 1) [.get 2 0 (.loc 1), .copy 1 (.cint 0)] = false := by decide
-- so does a call that mentions the array
example : domOk 0 (.loc 1) [.get 2 0 (.loc 1), .gen none [0] [] none] = false := by decide
-- `i = a[i]` justifies nothing
example : domOk 0 (.loc 1) [.get 1 0 (.loc 1)] = false := by decide

end Range
end Orin
