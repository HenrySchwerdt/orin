import Orin.RangeDom

/-!
# T2 for a borrowed-only array parameter

`RangeDom.lean` proves the dominated-by-check source under the hypothesis `Held`: whenever the array
local holds a reference it is a *pinned* one (`ctd`).  The ghost bit `ctd` of the range frame (see
`RangeSem.lean`) means "the object behind this local cannot be freed or resized by an instruction
that does not mention the local": a counted reference (`Owned`/`Unique`) **or** a reference that the
caller lends for the whole call (a `Param` local, `Frozen` in `CallLink.lean` / `OpLen.lean`).
For a counted array the prose argument is `Held` itself; for a *borrowed-only parameter* it used to be
the prose argument of `docs/tcb.md`.  This file replaces it by a theorem:

* `PinA a s`: the local `a` holds a reference to a live object, with the pin bit set;
* `pinA_exec`: an instruction that does not mention `a`, or keeps it (a read, `arr.length`, a borrowed
  call operand), preserves `PinA a` (`exec_summ`, the `keep` clause: the object stays alive with the
  same number of slots, also across a `gen`);
* `reachP_pin`: if the function only uses `a` that way in every block (`KeptI`; for a `Param` local
  `compiler/verify` rejects every other use: it cannot be moved, consumed, redefined or mutated), `PinA a`
  holds in every frame in which an execution enters a block, if it holds at entry;
* `held_of_pin`: `PinA a` gives `Held a`;
* `t2_param`: `t2_sound` for such an array with the hypothesis `Held` **discharged**: the pin of the
  parameter at entry (the entry frame of the callee: `Param` kinds are pinned) is all that is assumed.
-/

namespace Orin
namespace Range

/-- `a` holds a reference to a live object and carries the pin bit -/
def PinA (a : Nat) (s : CS) : Prop :=
  ∃ l n, s.loc[a]? = some (.ref l) ∧ s.ctd a = true ∧ s.len l = some n

/-- the instruction leaves `a` alone: it does not mention it, or only in a kept (borrowed) position -/
def KeptI (a : Nat) (ins : RI) : Prop := a ∉ ins.men ∨ ins.keeps a = true

theorem pinA_exec {cls : List Cls} {a : Nat} {ins : RI} {s s' : CS} (hk : KeptI a ins)
    (hE : Exec cls ins s s') (h : PinA a s) : PinA a s' := by
  obtain ⟨l, n, hl, hc, hn⟩ := h
  obtain ⟨l', hl', hn', hc'⟩ := (exec_summ hE).keep a l n hk hl hc hn
  exact ⟨l', n, hl', hc', hn'⟩

theorem pinA_run {cls : List Cls} {a : Nat} {is : List RI} {s s' : CS}
    (hk : ∀ i ∈ is, KeptI a i) (hr : RunI cls is s s') (h : PinA a s) : PinA a s' := by
  induction hr with
  | nil => exact h
  | cons he _ ih =>
    exact ih (fun i hi => hk i (List.mem_cons_of_mem _ hi)) (pinA_exec (hk _ List.mem_cons_self) he h)

theorem held_of_pin {a : Nat} {s : CS} (h : PinA a s) : Held a s := by
  obtain ⟨l, n, hl, hc, _⟩ := h
  intro l' hl'
  exact hc

/-- the frames in which an execution enters block `b`, from entry frames that satisfy `E` (the
entry condition `Entry` plus whatever the caller promises, here the pin of the parameter) -/
inductive ReachP (fn : Fn) (E : CS → Prop) : Nat → CS → Prop
  | entry {s : CS} : Entry fn.cls s → E s → ReachP fn E 0 s
  | step {b b' k : Nat} {s s2 : CS} {blk : Block} :
      ReachP fn E b s → fn.blocks[b]? = some blk → RunI fn.cls blk.instrs s s2 →
      Taken blk.term s2 k → blk.term.succs[k]? = some b' → ReachP fn E b' s2

theorem ReachP.reach {fn : Fn} {E : CS → Prop} {b : Nat} {s : CS} (h : ReachP fn E b s) :
    Reach fn b s := by
  induction h with
  | entry he _ => exact Reach.entry he
  | step _ hb hrun hT hs ih => exact Reach.step ih hb hrun hT hs

/-- **The pin of a parameter survives the whole function.** -/
theorem reachP_pin {fn : Fn} {E : CS → Prop} {a : Nat}
    (hKept : ∀ blk ∈ fn.blocks, ∀ i ∈ blk.instrs, KeptI a i)
    (hE : ∀ s, Entry fn.cls s → E s → PinA a s) {b : Nat} {s : CS}
    (h : ReachP fn E b s) : PinA a s := by
  induction h with
  | entry he hE' => exact hE _ he hE'
  | step _ hb hrun _ _ ih =>
    exact pinA_run (fun i hi => hKept _ (List.mem_of_getElem? hb) i hi) hrun ih

/-- **T2 for a borrowed-only array parameter.**  The access is the instruction after `pre`, which is
a prefix of block `b`; the function uses the parameter `a` only as `KeptI` says; the entry frames have
the pin on `a` (the parameter is `Param` in the entry kinds).  No `Held` hypothesis. -/
theorem t2_param {fn : Fn} {E : CS → Prop} {b : Nat} {s_in s_pre : CS} {a : Nat} {key : Opd}
    (hk : opCls fn.cls key ≠ .ref) {blk : Block} (hb : fn.blocks[b]? = some blk)
    {pre : List RI} (hpre : pre <+: blk.instrs) (hn : ∀ i ∈ pre, NoSelf i)
    (hKept : ∀ blk ∈ fn.blocks, ∀ i ∈ blk.instrs, KeptI a i)
    (hE : ∀ s, Entry fn.cls s → E s → PinA a s)
    (hr : ReachP fn E b s_in) (hrun : RunI fn.cls pre s_in s_pre) (hd : domOk a key pre = true) :
    InBounds fn.cls s_pre a key := by
  have hpin := reachP_pin hKept hE hr
  refine t2_sound hk hn (fun p s1 hp hr1 => ?_) hrun hd
  have hkp : ∀ i ∈ p, KeptI a i := fun i hi =>
    hKept _ (List.mem_of_getElem? hb) i (hpre.subset (hp.subset hi))
  exact held_of_pin (pinA_run hkp hr1 hpin)

end Range
end Orin
