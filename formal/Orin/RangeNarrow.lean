import Orin.RangeFix

/-!
# Interval analysis: narrowing and the unchecked access (rule U1)

`RangeFx.narrow` of `range.or`: one round, in block order, recomputes every in-state as the plain
hull of the exit states of its predecessors (those already recomputed in this round, and the old
in-states of the later blocks) and of the unknown state for the entry block; a block that no live
edge reaches becomes unreached.  `NarrowRel A N` is the equation the round satisfies;
`narrow_sound` proves by strong induction on the block index that the result still describes every
reachable frame, whatever the widening lost.

`accessOk` is rule U1: the state before an access is live, the array local is known and
`lo(i) >= 0` and `hi(i) < lo(length)`.  `accessOk_sound`: such an access is in bounds for the
array-length model.  `u1_sound` assembles the chain (table, block prefix, access), `range_accepted`
adds the iteration and the narrowing round, and `u1_machine` is the bridge to the heap of the
machine (`Obj.fields.length`).
-/

namespace Orin
namespace Range

variable {cls : List Cls}

/-! ### narrowing -/

/-- the exit states that flow into block `b` (and the unknown state, for the entry block) -/
def contribs (cls : List Cls) (blocks : List Block) (T : Tab) (b : Nat) : List (List Iv) :=
  (if b = 0 then [unknownIv cls] else []) ++
  (List.range blocks.length).flatMap fun p =>
    match T p, blocks[p]? with
    | some tp, some blk =>
      (List.range blk.term.succs.length).filterMap fun k =>
        if blk.term.succs[k]? = some b then outEdge cls blk tp k else none
    | _, _ => []

/-- the recomputed in-state of a reached block -/
def narrowAt (fn : Fn) (T : Tab) (b : Nat) : Option (List Iv) :=
  match T b with
  | none => none
  | some _ =>
    match contribs fn.cls fn.blocks T b with
    | [] => none
    | c :: cs => some (hullAll c cs)

/-- `N` is the result of the narrowing round on `A`: block `b` sees the new states of the earlier
blocks and the old states of the others -/
def NarrowRel (fn : Fn) (A N : Tab) : Prop :=
  ∀ b, N b = narrowAt fn (fun p => if p < b then N p else A p) b

theorem reach_inv {fn : Fn} {b : Nat} {s : CS} (h : Reach fn b s) :
    (b = 0 ∧ Entry fn.cls s) ∨
    ∃ p s0 blk k, Reach fn p s0 ∧ fn.blocks[p]? = some blk ∧ RunI fn.cls blk.instrs s0 s ∧
      Taken blk.term s k ∧ blk.term.succs[k]? = some b := by
  cases h with
  | entry he => exact Or.inl ⟨rfl, he⟩
  | step hr hb hrun hT hs => exact Or.inr ⟨_, _, _, _, hr, hb, hrun, hT, hs⟩

theorem length_hullAll (c : List Iv) (cs : List (List Iv)) : (hullAll c cs).length = c.length := by
  unfold hullAll
  induction cs generalizing c with
  | nil => rfl
  | cons d ds ih => simp only [List.foldl_cons]; rw [ih, length_hullStates]

theorem contribs_mem {fn : Fn} {T : Tab} {b p k : Nat} {tp : List Iv} {blk : Block} {e : List Iv}
    (hT : T p = some tp) (hb : fn.blocks[p]? = some blk) (hs : blk.term.succs[k]? = some b)
    (ho : outEdge fn.cls blk tp k = some e) : e ∈ contribs fn.cls fn.blocks T b := by
  unfold contribs
  apply List.mem_append_right
  rw [List.mem_flatMap]
  refine ⟨p, List.mem_range.mpr (List.getElem?_eq_some_iff.mp hb).1, ?_⟩
  rw [hT, hb]
  dsimp only
  rw [List.mem_filterMap]
  exact ⟨k, List.mem_range.mpr (List.getElem?_eq_some_iff.mp hs).1, by rw [if_pos hs]; exact ho⟩

theorem contribs_len {fn : Fn} {T : Tab} {b : Nat}
    (hT : ∀ p tp, T p = some tp → tp.length = fn.cls.length) :
    ∀ e ∈ contribs fn.cls fn.blocks T b, e.length = fn.cls.length := by
  intro e he
  unfold contribs at he
  rcases List.mem_append.mp he with h | h
  · split at h
    · simp at h; subst h; exact length_unknownIv _
    · cases h
  · rw [List.mem_flatMap] at h
    obtain ⟨p, _, h⟩ := h
    cases hTp : T p with
    | none => rw [hTp] at h; simp at h
    | some tp =>
      cases hbp : fn.blocks[p]? with
      | none => rw [hTp, hbp] at h; simp at h
      | some blk =>
        rw [hTp, hbp] at h
        dsimp only at h
        rw [List.mem_filterMap] at h
        obtain ⟨k, _, hk⟩ := h
        split at hk
        · rw [outEdge_len hk]; exact hT p tp hTp
        · cases hk

/-- narrowing keeps the table sound (and shaped) -/
theorem narrow_aux {fn : Fn} {A N : Tab} (hA : TabSound fn A)
    (hAl : ∀ b a, A b = some a → a.length = fn.cls.length) (hN : NarrowRel fn A N) :
    ∀ b, (∀ n, N b = some n → n.length = fn.cls.length) ∧
      (∀ s, Reach fn b s → ∃ n, N b = some n ∧ SoundS fn.cls n s) := by
  intro b
  induction b using Nat.strongRecOn with
  | _ b ih =>
    let T : Tab := fun p => if p < b then N p else A p
    have hTl : ∀ p tp, T p = some tp → tp.length = fn.cls.length := by
      intro p tp h
      by_cases hp : p < b
      · simp only [T, if_pos hp] at h
        exact (ih p hp).1 tp h
      · simp only [T, if_neg hp] at h
        exact hAl p tp h
    have hTs : ∀ p s0, Reach fn p s0 → ∃ tp, T p = some tp ∧ SoundS fn.cls tp s0 := by
      intro p s0 hr
      by_cases hp : p < b
      · simp only [T, if_pos hp]
        exact (ih p hp).2 s0 hr
      · simp only [T, if_neg hp]
        exact hA p s0 hr
    have hNb : N b = narrowAt fn T b := hN b
    have hcl := contribs_len (fn := fn) (T := T) (b := b) hTl
    refine ⟨fun n hn => ?_, fun s hr => ?_⟩
    · rw [hNb] at hn
      unfold narrowAt at hn
      cases hTb : T b with
      | none => rw [hTb] at hn; cases hn
      | some ta =>
        rw [hTb] at hn
        dsimp only at hn
        cases hc : contribs fn.cls fn.blocks T b with
        | nil => rw [hc] at hn; cases hn
        | cons c cs =>
          rw [hc] at hn
          cases hn
          rw [length_hullAll]
          exact hcl c (by rw [hc]; exact List.mem_cons_self)
    · obtain ⟨a, hAb, _⟩ := hA b s hr
      have hTb : T b = some a := by simp only [T, if_neg (Nat.lt_irrefl b)]; exact hAb
      -- a contribution that describes s
      have key : ∃ e, e ∈ contribs fn.cls fn.blocks T b ∧ SoundS fn.cls e s := by
        rcases reach_inv hr with ⟨hb0, he⟩ | ⟨p, s0, blk, k, hrp, hbp, hrun, hTk, hsk⟩
        · refine ⟨unknownIv fn.cls, ?_, soundS_unknown he⟩
          unfold contribs
          apply List.mem_append_left
          rw [if_pos hb0]
          exact List.mem_cons_self
        · obtain ⟨tp, hTp, hSp⟩ := hTs p s0 hrp
          have hout := blockOut_sound hSp hrun
          obtain ⟨e, he, hSe⟩ := edge_sound hout hTk
          exact ⟨e, contribs_mem hTp hbp hsk he, hSe⟩
      obtain ⟨e, hem, hSe⟩ := key
      rw [hNb]
      unfold narrowAt
      rw [hTb]
      dsimp only
      cases hc : contribs fn.cls fn.blocks T b with
      | nil => rw [hc] at hem; cases hem
      | cons c cs =>
        rw [hc] at hem
        have hcl' : c.length = fn.cls.length := hcl c (by rw [hc]; exact List.mem_cons_self)
        obtain ⟨h1, h2⟩ := hullAll_cov hcl' cs
        refine ⟨hullAll c cs, rfl, soundS_cov hSe ?_⟩
        rcases List.mem_cons.mp hem with rfl | hem'
        · exact h1
        · exact h2 e hem'

theorem narrow_sound {fn : Fn} {A N : Tab} (hA : TabSound fn A)
    (hAl : ∀ b a, A b = some a → a.length = fn.cls.length) (hN : NarrowRel fn A N) :
    TabSound fn N := fun b s hr => (narrow_aux hA hAl hN b).2 s hr

/-! ### rule U1 -/

/-- `RStep.inRange` -/
def inRange (cls : List Cls) (rs : RS) (a i : Opd) : Bool :=
  match a with
  | .loc l =>
    decide (known cls rs.iv l) && decide (opLo rs.iv i ≥ 0) && decide (opHi rs.iv i < BIG) &&
      decide (opHi rs.iv i < (gi rs.iv l).lo)
  | _ => false

/-- `RStep.accessOk`: the unchecked access is justified at this point -/
def accessOk (cls : List Cls) (rs : RS) (ins : RI) : Bool :=
  if rs.dead then false else
  match ins with
  | .get _ a i => inRange cls rs (.loc a) i
  | .set x i _ => inRange cls rs (.loc x) i
  | _ => false

/-- the access is in bounds: the array local holds a live array with `n` slots, the index is a
value in `[0, n)` -/
def InBounds (cls : List Cls) (s : CS) (a : Nat) (i : Opd) : Prop :=
  ∃ l n iv, s.get a = .ref l ∧ s.len l = some n ∧ evalOpd cls s i = some iv ∧ 0 ≤ iv ∧ iv < (n : Int)

/-- U1 for the array local `a` and the index operand `i` -/
theorem inRange_sound {rs : RS} {s : CS} {a : Nat} {i : Opd} (hS : SoundS cls rs.iv s)
    (hi : opCls cls i ≠ .ref) (h : inRange cls rs (.loc a) i = true) : InBounds cls s a i := by
  unfold inRange at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  obtain ⟨⟨⟨hk, hil⟩, hih⟩, hlt⟩ := h
  obtain ⟨l, n, hl, hn, hm, _⟩ := hS.fact a hk
  -- the index is evaluable
  have hev : ∃ iv, evalOpd cls s i = some iv := by
    cases i with
    | cint n => exact ⟨n, rfl⟩
    | cusize n =>
      by_cases hn : 0 ≤ n
      · exact ⟨n, by simp [evalOpd, hn]⟩
      · exfalso
        simp only [opHi] at hih
        have : ¬ (n ≥ 0 ∧ n < BIG) := fun h => hn h.1
        rw [if_neg this] at hih
        exact Int.lt_irrefl _ hih
    | loc x =>
      by_cases hx : x < cls.length
      · obtain ⟨m, hm', _, _⟩ := hS.scal x hx hi
        have hi' : clsOf cls x ≠ .ref := hi
        exact ⟨m, by simp only [evalOpd]; rw [if_neg hi', get_of_loc hm']⟩
      · exfalso
        simp only [opHi] at hih
        have hg : (gi rs.iv x).hi = BIG := by rw [gi_out (by rw [hS.leniv]; omega)]; rfl
        rw [hg] at hih
        exact Int.lt_irrefl _ hih
  obtain ⟨iv, hiv⟩ := hev
  have hbd := opd_bounds (rs := rs) hS hiv
  have hlo : 0 ≤ (gi rs.iv a).lo := hk.2
  obtain ⟨h1, _⟩ := hm
  refine ⟨l, n, iv, get_of_loc hl, hn, hiv, ?_, ?_⟩
  · have := hbd.1 (by unfold NEG; omega)
    omega
  · have := hbd.2 hih
    unfold NEG at h1
    omega

/-- an access the analysis accepts: for `get d a i` / `set a i v` the array and index -/
def AccessAt (cls : List Cls) (s : CS) : RI → Prop
  | .get _ a i => InBounds cls s a i
  | .set a i _ => InBounds cls s a i
  | _ => True

/-- the index operand of a well-formed access is a scalar (`wf.or`) -/
def IdxScalar (cls : List Cls) : RI → Prop
  | .get _ _ i => opCls cls i ≠ .ref
  | .set _ i _ => opCls cls i ≠ .ref
  | _ => True

theorem accessOk_in_bounds {rs : RS} {s : CS} {ins : RI} (hR : RunSound cls rs s)
    (hok : accessOk cls rs ins = true) (hw : IdxScalar cls ins) : AccessAt cls s ins := by
  obtain ⟨hd, hS, _⟩ := hR
  unfold accessOk at hok
  rw [hd] at hok
  simp only [Bool.false_eq_true, if_false] at hok
  cases ins with
  | get d a i => exact inRange_sound hS hw hok
  | set a i v => exact inRange_sound hS hw hok
  | _ => exact absurd hok (by simp)

/-- U1 along a block: the access is the instruction after the prefix `pre` of block `b`; if the
state at the block entry, run through `pre`, justifies it (`accessOk`), then in every execution
that reaches the access it is in bounds. -/
theorem u1_sound {fn : Fn} {N : Tab} (hN : TabSound fn N) {b : Nat} {blk : Block} {a : List Iv}
    {pre post : List RI} {ins : RI} {s_in s_pre : CS}
    (_hb : fn.blocks[b]? = some blk) (hNb : N b = some a) (_hins : blk.instrs = pre ++ ins :: post)
    (hok : accessOk fn.cls (runA fn.cls pre ⟨a, false, none⟩) ins = true)
    (hw : IdxScalar fn.cls ins) (hr : Reach fn b s_in) (hrun : RunI fn.cls pre s_in s_pre) :
    AccessAt fn.cls s_pre ins := by
  obtain ⟨a', hNb', hS⟩ := hN b s_in hr
  rw [hNb] at hNb'
  cases hNb'
  exact accessOk_in_bounds (blockOut_sound hS hrun) hok hw

/-- The whole analysis `rangeAccepted`: the worklist iteration ends (empty worklist), the narrowing
round runs, the access is justified by the resulting table. -/
theorem range_accepted {fn : Fn} {wa : Nat} {thr : List Int} {W : WS} {N : Tab}
    (hw : WReach fn wa thr W) (hwe : W.work = []) (hN : NarrowRel fn W.A N) : TabSound fn N :=
  narrow_sound (fix_sound hw hwe) (fun _ _ h => (wreach_inv hw).len _ _ h) hN

/-! ### the bridge to the heap of the machine -/

/-- the array-length model of a machine state: the number of slots of every live object
(`opArrayLen` returns `Obj.fields.length`) -/
def lensOf (st : St) (l : Nat) : Option Nat := (st.heap.objs l).map fun ob => ob.fields.length

/-- the frame model `CS` describes the machine state -/
def Rel (s : CS) (st : St) : Prop := s.loc = st.locals ∧ ∀ l, s.len l = lensOf st l

/-- An access in bounds for the model is in bounds for the machine: the object is live and the index
is a valid slot, so the bounds check of `opArrayGet` / `opArraySet` (`arrayGet_oob`) cannot fire. -/
theorem u1_machine {cls : List Cls} {s : CS} {st : St} {a : Nat} {i : Opd} (hr : Rel s st)
    (h : InBounds cls s a i) :
    ∃ l ob iv, st.get a = .ref l ∧ st.heap.objs l = some ob ∧ evalOpd cls s i = some iv ∧
      0 ≤ iv ∧ iv.toNat < ob.fields.length := by
  obtain ⟨l, n, iv, hl, hn, hi, h0, hlt⟩ := h
  have hlen := hr.2 l
  rw [hn] at hlen
  unfold lensOf at hlen
  cases hob : st.heap.objs l with
  | none => rw [hob] at hlen; cases hlen
  | some ob =>
    rw [hob] at hlen
    simp only [Option.map_some, Option.some.injEq] at hlen
    refine ⟨l, ob, iv, ?_, hob, hi, h0, by omega⟩
    have : s.get a = st.get a := by simp [CS.get, St.get, hr.1]
    rw [← this]; exact hl

/-! ### examples: the accepted and the rejected access -/

section Examples

/-- `a = [_, _, _]; i = 2; x = a[i]` -/
def exCls : List Cls := [.ref, .usize, .usize]
def exStart : RS := ⟨unknownIv exCls, false, none⟩

example : accessOk exCls (runA exCls [.arrayNew 0 3, .copy 1 (.cusize 2)] exStart)
    (.get 2 0 (.loc 1)) = true := by decide

/-- `i = 3` is one past the end -/
example : accessOk exCls (runA exCls [.arrayNew 0 3, .copy 1 (.cusize 3)] exStart)
    (.get 2 0 (.loc 1)) = false := by decide

/-- the array is a parameter: no length fact, nothing is accepted -/
example : accessOk exCls (runA exCls [.copy 1 (.cusize 0)] exStart)
    (.get 2 0 (.loc 1)) = false := by decide

/-- a push-like instruction that mentions the array and does not keep it destroys the fact -/
example : accessOk exCls
    (runA exCls [.arrayNew 0 3, .gen none [0] [] none, .copy 1 (.cusize 0)] exStart)
    (.get 2 0 (.loc 1)) = false := by decide

/-- a borrowed call keeps it -/
example : accessOk exCls
    (runA exCls [.arrayNew 0 3, .gen none [0] [0] none, .copy 1 (.cusize 0)] exStart)
    (.get 2 0 (.loc 1)) = true := by decide

/-- `if (i < 3) { a[i] }` for an unknown `usize` `i`: the refinement on the then-edge accepts, the
else-edge does not -/
def exCls2 : List Cls := [.ref, .usize, .usize, .bool]
def exB0 : Block := ⟨[.arrayNew 0 3, .cmp 3 .lt (.loc 1) (.cusize 3)], .br 3 1 2⟩

example : (outEdge exCls2 exB0 (unknownIv exCls2) 0).map
    (fun e => accessOk exCls2 ⟨e, false, none⟩ (.get 2 0 (.loc 1))) = some true := by decide

example : (outEdge exCls2 exB0 (unknownIv exCls2) 1).map
    (fun e => accessOk exCls2 ⟨e, false, none⟩ (.get 2 0 (.loc 1))) = some false := by decide

end Examples

end Range
end Orin
