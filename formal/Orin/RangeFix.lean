import Orin.RangeCfg

/-!
# Interval analysis: the worklist iteration (rule R4)

`RangeFx.run` of `range.or`: a worklist of blocks; popping a block runs its instructions from its
in-state, and for every live edge joins the exit state into the target's in-state (`feed`: the first
time the target is reached its in-state is the exit state, afterwards `joinInto`, widened to a
threshold from the `wa`-th change of the block on); a changed target is queued.

`WReach` is every configuration the iteration can reach, for **any** order in which the queued
blocks are popped (the implementation pops the last one) and for **any** list of widening
thresholds and any widening delay.  `WInv` is the invariant (the entry block is covered by the
unknown state; every state has the shape of the function; a block that is not queued has all its
live edges covered by the in-states of the targets).  `fix_postfix`: a configuration with an empty
worklist is a post-fixpoint.  Termination is not modelled (a run that does not end produces no
result and justifies nothing: partial correctness).
-/

namespace Orin
namespace Range

structure WS where
  A : Tab
  hits : Nat → Nat
  work : List Nat

def setA (A : Tab) (s : Nat) (v : Option (List Iv)) : Tab := fun x => if x = s then v else A x

/-- `joinInto` reports a change: a lower bound moved down or an upper bound moved up -/
def joinMoved (A E : List Iv) : Bool :=
  (List.range A.length).any fun l => decide ((gi E l).lo < (gi A l).lo) || decide ((gi E l).hi > (gi A l).hi)

/-- the exit state `e` flows into block `s` -/
def feed (wa : Nat) (thr : List Int) (cls : List Cls) (W : WS) (s : Nat) (e : List Iv) : WS :=
  match W.A s with
  | none => ⟨setA W.A s (some e), W.hits, if s ∈ W.work then W.work else s :: W.work⟩
  | some a =>
    if joinMoved a e then
      ⟨setA W.A s (some (joinInto (decide (wa ≤ W.hits s)) thr cls a e)),
       fun x => if x = s then W.hits s + 1 else W.hits x,
       if s ∈ W.work then W.work else s :: W.work⟩
    else W

def edgeStep (wa : Nat) (thr : List Int) (cls : List Cls) (blk : Block) (a : List Iv) (W : WS)
    (k : Nat) : WS :=
  match blk.term.succs[k]?, outEdge cls blk a k with
  | some s, some e => feed wa thr cls W s e
  | _, _ => W

def procBlock (wa : Nat) (thr : List Int) (cls : List Cls) (blk : Block) (a : List Iv) (W0 : WS) : WS :=
  (List.range blk.term.succs.length).foldl (edgeStep wa thr cls blk a) W0

/-- one iteration: any queued block with an in-state is popped and processed -/
inductive WStep (fn : Fn) (wa : Nat) (thr : List Int) : WS → WS → Prop
  | pop {W : WS} {b : Nat} {a : List Iv} {blk : Block} :
      b ∈ W.work → W.A b = some a → fn.blocks[b]? = some blk →
      WStep fn wa thr W (procBlock wa thr fn.cls blk a ⟨W.A, W.hits, W.work.erase b⟩)

def initW (cls : List Cls) : WS := ⟨setA (fun _ => none) 0 (some (unknownIv cls)), fun _ => 0, [0]⟩

inductive WReach (fn : Fn) (wa : Nat) (thr : List Int) : WS → Prop
  | init : WReach fn wa thr (initW fn.cls)
  | step {W W' : WS} : WReach fn wa thr W → WStep fn wa thr W W' → WReach fn wa thr W'

structure WInv (fn : Fn) (W : WS) : Prop where
  entry : ∃ a0, W.A 0 = some a0 ∧ Cov fn.cls (unknownIv fn.cls) a0
  len : ∀ c a, W.A c = some a → a.length = fn.cls.length
  done : ∀ c a, W.A c = some a → c ∉ W.work → EdgesCov fn W.A c a

theorem winv_init (fn : Fn) : WInv fn (initW fn.cls) := by
  refine ⟨⟨unknownIv fn.cls, by simp [initW, setA], Cov.refl (length_unknownIv _)⟩, ?_, ?_⟩
  · intro c a h
    by_cases hc : c = 0
    · simp [initW, setA, hc] at h; subst h; exact length_unknownIv _
    · simp [initW, setA, hc] at h
  · intro c a h hn
    by_cases hc : c = 0
    · subst hc; simp [initW] at hn
    · simp [initW, setA, hc] at h

/-! ### one flow into a block -/

theorem not_moved {A E : List Iv} (h : joinMoved A E = false) {l : Nat} (hl : l < A.length) :
    Iv.le (gi E l) (gi A l) := by
  unfold joinMoved at h
  rw [List.any_eq_false] at h
  have := h l (List.mem_range.mpr hl)
  simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at this
  exact ⟨by omega, by omega⟩

structure FeedSpec (cls : List Cls) (W W' : WS) (s : Nat) (e : List Iv) : Prop where
  other : ∀ c, c ≠ s → W'.A c = W.A c
  new : ∃ a', W'.A s = some a' ∧ Cov cls e a' ∧ (∀ a, W.A s = some a → Cov cls a a')
  keep : ∀ c, c ∈ W.work → c ∈ W'.work
  chg : (∃ a, W.A s = some a ∧ W'.A s = some a) ∨ s ∈ W'.work
  only : ∀ c, c ∈ W'.work → c = s ∨ c ∈ W.work

theorem feed_spec {wa : Nat} {thr : List Int} {cls : List Cls} {W : WS} {s : Nat} {e : List Iv}
    (hl : ∀ c a, W.A c = some a → a.length = cls.length) (he : e.length = cls.length) :
    FeedSpec cls W (feed wa thr cls W s e) s e := by
  unfold feed
  cases hA : W.A s with
  | none =>
    dsimp only
    refine ⟨fun c hc => ?_, ⟨e, ?_, Cov.refl he, fun a h => by rw [hA] at h; cases h⟩, fun c hc => ?_,
      Or.inr ?_, fun c hc => ?_⟩
    · simp [setA, hc]
    · simp [setA]
    · split <;> simp [hc]
    · split <;> simp_all
    · split at hc
      · exact Or.inr hc
      · rcases List.mem_cons.mp hc with h | h
        · exact Or.inl h
        · exact Or.inr h
  | some a =>
    have ha := hl s a hA
    dsimp only
    by_cases hm : joinMoved a e = true
    · rw [if_pos hm]
      refine ⟨fun c hc => by simp [setA, hc], ⟨joinInto (decide (wa ≤ W.hits s)) thr cls a e, by simp [setA], ?_, fun a' h => ?_⟩, fun c hc => ?_,
        Or.inr ?_, fun c hc => ?_⟩
      · exact joinInto_cov_right ha
      · rw [hA] at h; cases h; exact joinInto_cov_left ha
      · split <;> simp [hc]
      · split <;> simp_all
      · split at hc
        · exact Or.inr hc
        · rcases List.mem_cons.mp hc with h | h
          · exact Or.inl h
          · exact Or.inr h
    · have hm' : joinMoved a e = false := by simpa using hm
      rw [if_neg hm]
      refine ⟨fun c _ => rfl, ⟨a, hA, ?_, fun a' h => ?_⟩, fun c hc => hc, Or.inl ⟨a, hA, hA⟩,
        fun c hc => Or.inr hc⟩
      · exact ⟨ha, fun l hl => ivCov_of_le (not_moved hm' (by omega))⟩
      · rw [hA] at h; cases h; exact Cov.refl ha

/-! ### the edges of one block -/

structure FoldInv (fn : Fn) (b : Nat) (a : List Iv) (blk : Block) (m : Nat) (W1 : WS) : Prop where
  entry : ∃ a0, W1.A 0 = some a0 ∧ Cov fn.cls (unknownIv fn.cls) a0
  len : ∀ c a', W1.A c = some a' → a'.length = fn.cls.length
  done : ∀ c a', c ≠ b → W1.A c = some a' → c ∉ W1.work → EdgesCov fn W1.A c a'
  self : b ∈ W1.work ∨ W1.A b = some a
  edges : ∀ k, k < m → ∀ b' e, blk.term.succs[k]? = some b' → outEdge fn.cls blk a k = some e →
    ∃ a'', W1.A b' = some a'' ∧ Cov fn.cls e a''

theorem edgesCov_mono {fn : Fn} {A1 A2 : Tab} {c : Nat} {a : List Iv}
    (hm : ∀ x a1, A1 x = some a1 → ∃ a2, A2 x = some a2 ∧ Cov fn.cls a1 a2)
    (h : EdgesCov fn A1 c a) : EdgesCov fn A2 c a := by
  intro blk k b' e hb hs ho
  obtain ⟨a1, h1, hc⟩ := h blk k b' e hb hs ho
  obtain ⟨a2, h2, hc2⟩ := hm b' a1 h1
  exact ⟨a2, h2, hc.trans hc2⟩

theorem foldInv_step {fn : Fn} {wa : Nat} {thr : List Int} {b : Nat} {a : List Iv} {blk : Block}
    {m : Nat} {W1 : WS} (ha : a.length = fn.cls.length) (h : FoldInv fn b a blk m W1) :
    FoldInv fn b a blk (m + 1) (edgeStep wa thr fn.cls blk a W1 m) := by
  unfold edgeStep
  cases hs : blk.term.succs[m]? with
  | none =>
    refine ⟨h.entry, h.len, h.done, h.self, fun k hk b' e hb ho => ?_⟩
    by_cases hkm : k = m
    · subst hkm; rw [hs] at hb; cases hb
    · exact h.edges k (by omega) b' e hb ho
  | some s =>
    cases ho : outEdge fn.cls blk a m with
    | none =>
      refine ⟨h.entry, h.len, h.done, h.self, fun k hk b' e hb ho' => ?_⟩
      by_cases hkm : k = m
      · subst hkm; rw [ho] at ho'; cases ho'
      · exact h.edges k (by omega) b' e hb ho'
    | some e =>
      dsimp only
      have he : e.length = fn.cls.length := by rw [outEdge_len ho]; exact ha
      have fs := feed_spec (wa := wa) (thr := thr) (s := s) h.len he
      have mono : ∀ x a1, W1.A x = some a1 →
          ∃ a2, (feed wa thr fn.cls W1 s e).A x = some a2 ∧ Cov fn.cls a1 a2 := by
        intro x a1 hx
        by_cases hxs : x = s
        · subst hxs
          obtain ⟨a', h1, _, h3⟩ := fs.new
          exact ⟨a', h1, h3 a1 hx⟩
        · exact ⟨a1, by rw [fs.other x hxs]; exact hx, Cov.refl (h.len x a1 hx)⟩
      refine ⟨?_, ?_, ?_, ?_, ?_⟩
      · obtain ⟨a0, h0, hc⟩ := h.entry
        obtain ⟨a2, h2, hc2⟩ := mono 0 a0 h0
        exact ⟨a2, h2, hc.trans hc2⟩
      · intro c a' hc
        by_cases hcs : c = s
        · subst hcs
          obtain ⟨a'', h1, h2, _⟩ := fs.new
          rw [h1] at hc; cases hc
          exact h2.1
        · rw [fs.other c hcs] at hc
          exact h.len c a' hc
      · intro c a' hcb hc hcw
        have hcw1 : c ∉ W1.work := fun hh => hcw (fs.keep c hh)
        have hc1 : W1.A c = some a' := by
          by_cases hcs : c = s
          · subst hcs
            rcases fs.chg with ⟨a1, h1, h2⟩ | hh
            · rw [h2] at hc; cases hc; exact h1
            · exact absurd hh hcw
          · rw [fs.other c hcs] at hc; exact hc
        exact edgesCov_mono mono (h.done c a' hcb hc1 hcw1)
      · rcases h.self with hh | hh
        · exact Or.inl (fs.keep b hh)
        · by_cases hbs : b = s
          · subst hbs
            rcases fs.chg with ⟨a1, h1, h2⟩ | h'
            · rw [hh] at h1; cases h1; exact Or.inr h2
            · exact Or.inl h'
          · exact Or.inr (by rw [fs.other b hbs]; exact hh)
      · intro k hk b' e' hb ho'
        by_cases hkm : k = m
        · subst hkm
          rw [hs] at hb
          cases hb
          rw [ho] at ho'
          cases ho'
          obtain ⟨a', h1, h2, _⟩ := fs.new
          exact ⟨a', h1, h2⟩
        · obtain ⟨a1, h1, hc⟩ := h.edges k (by omega) b' e' hb ho'
          obtain ⟨a2, h2, hc2⟩ := mono b' a1 h1
          exact ⟨a2, h2, hc.trans hc2⟩

theorem procBlock_inv {fn : Fn} {wa : Nat} {thr : List Int} {b : Nat} {a : List Iv} {blk : Block}
    {W0 : WS} (ha : a.length = fn.cls.length) (h0 : FoldInv fn b a blk 0 W0) :
    FoldInv fn b a blk blk.term.succs.length (procBlock wa thr fn.cls blk a W0) := by
  unfold procBlock
  suffices h : ∀ m, m ≤ blk.term.succs.length →
      FoldInv fn b a blk m ((List.range m).foldl (edgeStep wa thr fn.cls blk a) W0) from
    h _ (Nat.le_refl _)
  intro m
  induction m with
  | zero => intro _; exact h0
  | succ m ih =>
    intro hm
    rw [List.range_succ, List.foldl_append]
    exact foldInv_step ha (ih (by omega))

theorem winv_step {fn : Fn} {wa : Nat} {thr : List Int} {W W' : WS} (hI : WInv fn W)
    (hS : WStep fn wa thr W W') : WInv fn W' := by
  cases hS with
  | pop hbw hAb hblk =>
    rename_i b a blk
    have ha := hI.len b a hAb
    have h0 : FoldInv fn b a blk 0 ⟨W.A, W.hits, W.work.erase b⟩ := by
      refine ⟨hI.entry, hI.len, fun c a' hcb hc hcw => ?_, Or.inr hAb, fun k hk => by omega⟩
      apply hI.done c a' hc
      intro hh
      exact hcw ((List.mem_erase_of_ne hcb).mpr hh)
    have hf := procBlock_inv (wa := wa) (thr := thr) ha h0
    refine ⟨hf.entry, hf.len, fun c a' hc hcw => ?_⟩
    by_cases hcb : c = b
    · subst hcb
      rcases hf.self with hh | hh
      · exact absurd hh hcw
      · rw [hh] at hc; cases hc
        intro blk' k b' e hb' hs ho
        rw [hblk] at hb'; cases hb'
        have hk := (List.getElem?_eq_some_iff.mp hs).1
        exact hf.edges k hk b' e hs ho
    · exact hf.done c a' hcb hc hcw

theorem wreach_inv {fn : Fn} {wa : Nat} {thr : List Int} {W : WS} (h : WReach fn wa thr W) :
    WInv fn W := by
  induction h with
  | init => exact winv_init fn
  | step _ hs ih => exact winv_step ih hs

/-- a configuration of the iteration with an empty worklist is a post-fixpoint -/
theorem fix_postfix {fn : Fn} {wa : Nat} {thr : List Int} {W : WS} (h : WReach fn wa thr W)
    (hw : W.work = []) : PostFix fn W.A := by
  have hI := wreach_inv h
  refine ⟨hI.entry, fun b a hA => hI.done b a hA ?_⟩
  rw [hw]; exact List.not_mem_nil

/-- R4, the fixpoint: when the iteration ends, its table describes every reachable frame -/
theorem fix_sound {fn : Fn} {wa : Nat} {thr : List Int} {W : WS} (h : WReach fn wa thr W)
    (hw : W.work = []) : TabSound fn W.A :=
  postfix_sound (fix_postfix h hw)

end Range
end Orin
