import Orin.RangeJoin

/-!
# Interval analysis: the control-flow graph, reachability, post-fixpoints

A function is a list of blocks, each a list of instructions and a terminator
(`MFunction.blocks`).  `Reach fn b s` is the set of frames in which an execution can enter block
`b`: the entry frame (a frame whose scalar locals hold legal values of their class; references are
arbitrary), or the frame at the end of a predecessor block along an edge it takes (`Taken`).  The
instructions are the `Exec` semantics of `RangeSem.lean`; an instruction that traps has no
successor, so an execution that traps stops (it reaches no further block).

`PostFix fn A` is what the dataflow analysis must establish: the entry block is covered by the
unknown state and, for every block with an in-state, every live edge's exit state is covered by the
in-state of its target.  `postfix_sound`: a post-fixpoint describes every reachable frame.  The
worklist iteration computes one (`RangeFix.lean`), the narrowing round keeps the property
(`RangeNarrow.lean`).
-/

namespace Orin
namespace Range

structure Block where
  instrs : List RI
  term : Term

structure Fn where
  cls : List Cls
  blocks : List Block

/-- the entry frame: scalars hold legal values of their class -/
def Entry (cls : List Cls) (s : CS) : Prop :=
  s.loc.length = cls.length ∧
    ∀ x, x < cls.length → clsOf cls x ≠ .ref → ∃ n, s.loc[x]? = some (.int n) ∧ (clsOf cls x).okv n

inductive Reach (fn : Fn) : Nat → CS → Prop
  | entry {s : CS} : Entry fn.cls s → Reach fn 0 s
  | step {b b' k : Nat} {s s2 : CS} {blk : Block} :
      Reach fn b s → fn.blocks[b]? = some blk → RunI fn.cls blk.instrs s s2 →
      Taken blk.term s2 k → blk.term.succs[k]? = some b' → Reach fn b' s2

/-- the unknown state of a function (every local at its widest interval) -/
def unknownIv (cls : List Cls) : List Iv := cls.map unkOf

theorem length_unknownIv (cls : List Cls) : (unknownIv cls).length = cls.length := by
  simp [unknownIv]

theorem gi_unknownIv {cls : List Cls} {x : Nat} (hx : x < cls.length) :
    gi (unknownIv cls) x = unkOf (clsOf cls x) := by
  unfold gi unknownIv clsOf
  simp [List.getElem?_map, List.getElem?_eq_getElem hx, List.getD_eq_getElem?_getD]

theorem soundS_unknown {cls : List Cls} {s : CS} (h : Entry cls s) : SoundS cls (unknownIv cls) s := by
  refine ⟨length_unknownIv cls, h.1, fun x hx hc => ?_, fun x hk => ?_⟩
  · obtain ⟨n, hn, hok⟩ := h.2 x hx hc
    exact ⟨n, hn, hok, by rw [gi_unknownIv hx]; exact mem_unkOf hok hc⟩
  · obtain ⟨hr, h0⟩ := hk
    have hx : x < cls.length := clsOf_ref_lt hr
    rw [gi_unknownIv hx] at h0
    simp only [unkOf, hr, floorOf] at h0
    unfold NEG at h0
    omega

/-- the exit state of block `blk` along edge `k`, from the in-state `a` -/
def outEdge (cls : List Cls) (blk : Block) (a : List Iv) (k : Nat) : Option (List Iv) :=
  edgeIv blk.term k (runA cls blk.instrs ⟨a, false, none⟩)

theorem outEdge_len {cls : List Cls} {blk : Block} {a e : List Iv} {k : Nat}
    (h : outEdge cls blk a k = some e) : e.length = a.length := by
  have := edgeIv_len h
  rw [runA_len] at this
  exact this

/-- the in-states of the blocks (`none`: no execution reaches the block) -/
abbrev Tab := Nat → Option (List Iv)

/-- the table describes every reachable frame -/
def TabSound (fn : Fn) (A : Tab) : Prop :=
  ∀ b s, Reach fn b s → ∃ a, A b = some a ∧ SoundS fn.cls a s

/-- the coverage of every live edge by the in-state of its target -/
def EdgesCov (fn : Fn) (A : Tab) (b : Nat) (a : List Iv) : Prop :=
  ∀ blk k b' e, fn.blocks[b]? = some blk → blk.term.succs[k]? = some b' →
    outEdge fn.cls blk a k = some e → ∃ a', A b' = some a' ∧ Cov fn.cls e a'

/-- what the dataflow analysis establishes -/
structure PostFix (fn : Fn) (A : Tab) : Prop where
  entry : ∃ a0, A 0 = some a0 ∧ Cov fn.cls (unknownIv fn.cls) a0
  edges : ∀ b a, A b = some a → EdgesCov fn A b a

theorem blockOut_sound {cls : List Cls} {a : List Iv} {s s2 : CS} {is : List RI}
    (hS : SoundS cls a s) (hr : RunI cls is s s2) :
    RunSound cls (runA cls is ⟨a, false, none⟩) s2 :=
  runA_sound ⟨rfl, hS, trivial⟩ hr

theorem postfix_sound {fn : Fn} {A : Tab} (hp : PostFix fn A) : TabSound fn A := by
  intro b s hr
  induction hr with
  | entry he =>
    obtain ⟨a0, h0, hc⟩ := hp.entry
    exact ⟨a0, h0, soundS_cov (soundS_unknown he) hc⟩
  | step hr hb hrun hT hs ih =>
    rename_i b b' k s s2 blk
    obtain ⟨a, hA, hS⟩ := ih
    have hout := blockOut_sound hS hrun
    obtain ⟨e, he, hSe⟩ := edge_sound hout hT
    obtain ⟨a', hA', hc⟩ := hp.edges b a hA blk k b' e hb hs he
    exact ⟨a', hA', soundS_cov hSe hc⟩

end Range
end Orin
