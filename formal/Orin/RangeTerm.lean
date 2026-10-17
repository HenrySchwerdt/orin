import Orin.RangeNarrow

/-!
# Interval analysis: termination of the worklist (total correctness of `fix_sound`)

`RangeFx.run` of `range.or` pops blocks until the worklist is empty.  This file proves that every
run ends, **for every pop order**, every list of widening thresholds `thr` and every widening delay
`wa` (the implementation has `WIDEN_AFTER = 2` and the thresholds of `thresholds(f)`), on a closed
function (`Closed`: the successors are blocks of the function; `wf.or`) whose array literals are
smaller than `BIG = 2^60` (`ArrSmall`).

The argument is a lexicographic measure `(C0, C1, C2, C3)` that every step of `WStep` decreases:

* `C0` the number of blocks without an in-state (a first flow into a block lowers it),
* `C1` the number of changes the blocks may still have before they widen,
  `sum (wa - hits s)` (a change of a block that has not widened lowers it),
* `C2` the position of the in-states in the finite lattice of the thresholds: a bound that moves
  after the delay is widened to a threshold, so it moves strictly in the finite set
  `{floor} ∪ thr` (lower bounds) or `thr ∪ {BIG}` (upper bounds): `rankLo`, `rankHi`,
* `C3` the length of the worklist (a pop that changes nothing).

The proof needs one invariant of the transfer function, `Valid`: every lower bound is at or above
the floor of the class of its local and every upper bound is at most `BIG` (`valid_step`,
`valid_edge`).  Without it a widened lower bound could jump *up* to the floor.
-/

namespace Orin
namespace Range

variable {cls : List Cls}

/-! ### the invariant: bounds inside the lattice -/

/-- every lower bound is at or above the floor of the class, every upper bound is at most `BIG` -/
def Valid (cls : List Cls) (iv : List Iv) : Prop :=
  iv.length = cls.length ∧
    ∀ l, l < cls.length → floorOf (clsOf cls l) ≤ (gi iv l).lo ∧ (gi iv l).hi ≤ BIG

theorem floorOf_ge (c : Cls) : NEG ≤ floorOf c := by
  cases c <;> simp [floorOf, NEG]

theorem Valid.get {iv : List Iv} (h : Valid cls iv) (l : Nat) :
    NEG ≤ (gi iv l).lo ∧ (gi iv l).hi ≤ BIG := by
  by_cases hl : l < cls.length
  · obtain ⟨h1, h2⟩ := h.2 l hl
    exact ⟨Int.le_trans (floorOf_ge _) h1, h2⟩
  · rw [gi_out (by rw [h.1]; omega)]
    simp [Iv.unk, NEG, BIG]

theorem valid_set {iv : List Iv} (h : Valid cls iv) (d : Nat) (x : Iv)
    (hx : floorOf (clsOf cls d) ≤ x.lo ∧ x.hi ≤ BIG) : Valid cls (iv.set d x) := by
  refine ⟨by simp [h.1], fun l hl => ?_⟩
  by_cases hd : d < iv.length
  · by_cases hld : l = d
    · subst hld; rw [gi_set_same hd]; exact hx
    · rw [gi_set_ne hld]; exact h.2 l hl
  · rw [List.set_eq_of_length_le (by omega)]
    exact h.2 l hl

theorem valid_forget {iv : List Iv} (h : Valid cls iv) (x : Nat) : Valid cls (forget cls iv x) :=
  valid_set h x _ ⟨Int.le_refl _, Int.le_refl _⟩

theorem valid_assign {iv : List Iv} (h : Valid cls iv) (d : Nat) {lo hi : Int} (hlo : NEG ≤ lo)
    (hhi : hi ≤ BIG) : Valid cls (assign cls iv d lo hi) := by
  obtain ⟨l, hl, h1 | h1⟩ := assign_cases cls iv d lo hi
  · rw [h1.2]; exact valid_forget h d
  · rw [h1.2]
    refine valid_set h d _ ⟨?_, hhi⟩
    simp only
    rw [hl]
    split
    · rename_i hu
      rw [hu.1]; simp [floorOf]
    · rename_i hu
      have : floorOf (clsOf cls d) ≤ lo := by
        cases hc : clsOf cls d with
        | usize => simp only [floorOf]; by_cases hlt : lo < 0
                   · exact absurd ⟨hc, hlt⟩ hu
                   · omega
        | _ => simp only [floorOf]; exact hlo
      exact this

theorem valid_destroy {iv : List Iv} (h : Valid cls iv) (ins : RI) : Valid cls (destroy cls ins iv) := by
  refine ⟨by rw [length_destroy]; exact h.1, fun l hl => ?_⟩
  rw [gi_destroy]
  by_cases hb : (decide (l ∈ ins.men) && decide (known cls iv l) && !ins.keeps l) = true
  · rw [if_pos hb]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hb
    have hr : clsOf cls l = .ref := hb.1.2.1
    rw [hr]
    simp [floorOf, Iv.unk, NEG, BIG]
  · rw [if_neg hb]; exact h.2 l hl

/-! ### the bounds a step computes -/

theorem opLo_ge {iv : List Iv} (h : Valid cls iv) (o : Opd) : NEG ≤ opLo iv o := by
  cases o with
  | loc l => exact (h.get l).1
  | cint n => simp only [opLo]; split <;> omega
  | cusize n => simp only [opLo]; split <;> (unfold NEG; omega)

theorem opHi_le {iv : List Iv} (h : Valid cls iv) (o : Opd) : opHi iv o ≤ BIG := by
  cases o with
  | loc l => exact (h.get l).2
  | cint n => simp only [opHi]; split <;> omega
  | cusize n => simp only [opHi]; split <;> omega

theorem clampI_bounds (s : Int) : NEG ≤ clampI s ∧ clampI s ≤ BIG := by
  unfold clampI NEG BIG
  split <;> (try split) <;> omega

theorem addLo_ge (a b : Int) : NEG ≤ addLo a b := by
  unfold addLo; split
  · exact Int.le_refl _
  · exact (clampI_bounds _).1

theorem addHi_le (a b : Int) : addHi a b ≤ BIG := by
  unfold addHi; split
  · exact Int.le_refl _
  · exact (clampI_bounds _).2

theorem subLo_ge (a b : Int) : NEG ≤ subLo a b := by
  unfold subLo; split
  · exact Int.le_refl _
  · exact (clampI_bounds _).1

theorem subHi_le (a b : Int) : subHi a b ≤ BIG := by
  unfold subHi; split
  · exact Int.le_refl _
  · exact (clampI_bounds _).2

theorem arith_bounds {iv : List Iv} (_h : Valid cls iv) (c : Cls) (sub : Bool) (x y : Opd) :
    NEG ≤ (arith cls iv c sub x y).1 ∧ (arith cls iv c sub x y).2.1 ≤ BIG := by
  unfold arith
  split
  · split
    · exact ⟨addLo_ge _ _, addHi_le _ _⟩
    · dsimp only
      split
      · dsimp only
        refine ⟨?_, subHi_le _ _⟩
        split
        · unfold NEG; omega
        · exact subLo_ge _ _
      · exact ⟨subLo_ge _ _, subHi_le _ _⟩
  · simp [NEG, BIG]

/-- array literals are smaller than `BIG` (`wf.or`: the length of a literal is a `usize` small enough
to be allocated) -/
def ArrOk : RI → Prop
  | .arrayNew _ n => (n : Int) ≤ BIG
  | _ => True

theorem resOf_bounds {iv : List Iv} (h : Valid cls iv) {ins : RI} (ha : ArrOk ins) :
    NEG ≤ (resOf cls iv ins).1 ∧ (resOf cls iv ins).2.1 ≤ BIG := by
  cases ins with
  | copy d o => exact ⟨opLo_ge h o, opHi_le h o⟩
  | move d s => exact (h.get s)
  | forward d s o => exact (h.get s)
  | arrayNew d n =>
    simp only [resOf]
    refine ⟨?_, ha⟩
    unfold NEG; omega
  | arrLen d a =>
    simp only [resOf]
    split
    · exact h.get a
    · simp [NEG, BIG]
  | add d x y =>
    simp only [resOf]
    split
    · exact arith_bounds h _ false x y
    · simp [NEG, BIG]
  | sub d x y =>
    simp only [resOf]
    split
    · exact arith_bounds h _ true x y
    · simp [NEG, BIG]
  | cmp d op x y => simp [resOf, NEG, BIG]
  | get d a i => simp [resOf, NEG, BIG]
  | set a i v => simp [resOf, NEG, BIG]
  | makeUnique a => simp [resOf, NEG, BIG]
  | gen dst men kept recv => simp [resOf, NEG, BIG]

theorem valid_ivRecv {iv : List Iv} (h : Valid cls iv) (ins : RI) : Valid cls (ivRecv cls ins iv) := by
  unfold ivRecv
  have h1 := valid_destroy h ins
  cases ins.recv with
  | none => exact h1
  | some x => exact valid_forget h1 x

theorem valid_ivOut {iv : List Iv} (h : Valid cls iv) (ins : RI) {rl rh : Int} (hlo : NEG ≤ rl)
    (hhi : rh ≤ BIG) : Valid cls (ivOut cls ins iv rl rh) := by
  unfold ivOut
  have h1 := valid_ivRecv h ins
  cases ins.dst with
  | none => exact h1
  | some d => exact valid_assign h1 d hlo hhi

theorem valid_step {rs : RS} (h : Valid cls rs.iv) {ins : RI} (ha : ArrOk ins) :
    Valid cls (step cls ins rs).iv := by
  unfold step
  split
  · exact h
  · generalize hr : resOf cls rs.iv ins = r
    have hb := resOf_bounds h ha
    rw [hr] at hb
    obtain ⟨rl, rh, dd⟩ := r
    dsimp only at hb ⊢
    split
    · exact h
    · exact valid_ivOut h ins hb.1 hb.2

/-! ### refinement and edges keep the invariant -/

theorem Valid.all {iv : List Iv} (h : Valid cls iv) (l : Nat) :
    floorOf (clsOf cls l) ≤ (gi iv l).lo ∧ (gi iv l).hi ≤ BIG := by
  by_cases hl : l < cls.length
  · exact h.2 l hl
  · have hc : clsOf cls l = .int := by
      unfold clsOf; rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]; rfl
    rw [hc]
    exact ⟨(h.get l).1, (h.get l).2⟩

theorem valid_capHi {rs : RS} (h : Valid cls rs.iv) (o : Opd) (v : Int) :
    Valid cls (capHi rs o v).iv := by
  unfold capHi
  cases o with
  | loc l =>
    dsimp only
    by_cases hlt : (if v < NEG then NEG else v) < (gi rs.iv l).hi
    · rw [if_pos hlt]
      refine valid_set h l _ ⟨(h.all l).1, ?_⟩
      have := (h.all l).2
      show (if v < NEG then NEG else v) ≤ BIG
      omega
    · rw [if_neg hlt]; exact h
  | cint n => exact h
  | cusize n => exact h

theorem valid_raiseLo {rs : RS} (h : Valid cls rs.iv) (o : Opd) (v : Int) :
    Valid cls (raiseLo rs o v).iv := by
  unfold raiseLo
  cases o with
  | loc l =>
    dsimp only
    by_cases hlt : (if v > BIG then BIG else v) > (gi rs.iv l).lo
    · rw [if_pos hlt]
      refine valid_set h l _ ⟨?_, (h.all l).2⟩
      have := (h.all l).1
      show floorOf (clsOf cls l) ≤ (if v > BIG then BIG else v)
      omega
    · rw [if_neg hlt]; exact h
  | cint n => exact h
  | cusize n => exact h

theorem valid_ite_capHi {rs : RS} (h : Valid cls rs.iv) (c : Prop) [Decidable c] (a : Opd) (v : Int) :
    Valid cls (if c then capHi rs a v else rs).iv := by
  split
  · exact valid_capHi h _ _
  · exact h

theorem valid_less {rs : RS} (h : Valid cls rs.iv) (a b : Opd) : Valid cls (less rs a b).iv := by
  unfold less
  dsimp only
  split
  · exact valid_raiseLo (valid_ite_capHi h _ _ _) _ _
  · exact valid_ite_capHi h _ _ _

theorem valid_atMost {rs : RS} (h : Valid cls rs.iv) (a b : Opd) : Valid cls (atMost rs a b).iv := by
  unfold atMost
  dsimp only
  split
  · exact valid_raiseLo (valid_ite_capHi h _ _ _) _ _
  · exact valid_ite_capHi h _ _ _

theorem valid_same {rs : RS} (h : Valid cls rs.iv) (a b : Opd) : Valid cls (same rs a b).iv := by
  unfold same
  exact valid_atMost (valid_atMost h _ _) _ _

theorem valid_refine {rs : RS} (h : Valid cls rs.iv) (n : Note) (t : Bool) :
    Valid cls (refine rs n t).iv := by
  unfold refine
  split
  · exact valid_less h _ _
  · exact valid_atMost h _ _
  · exact valid_atMost h _ _
  · exact valid_less h _ _
  · exact valid_less h _ _
  · exact valid_atMost h _ _
  · exact valid_atMost h _ _
  · exact valid_less h _ _
  · exact valid_same h _ _
  · exact h
  · exact h
  · exact valid_same h _ _

theorem valid_edgeRS {rs : RS} (h : Valid cls rs.iv) (t : Term) (k : Nat) :
    Valid cls (edgeRS t k rs).iv := by
  unfold edgeRS
  split
  · split
    · exact valid_refine h _ _
    · exact h
  · exact h

theorem valid_edgeIv {rs : RS} (h : Valid cls rs.iv) {t : Term} {k : Nat} {e : List Iv}
    (he : edgeIv t k rs = some e) : Valid cls e := by
  unfold edgeIv at he
  split at he
  · cases he
  · split at he
    · cases he
    · cases he
      exact valid_edgeRS h t k

/-- every array literal of the block is small -/
def BlockOk (is : List RI) : Prop := ∀ ins ∈ is, ArrOk ins

theorem valid_runA {is : List RI} (hok : BlockOk is) {rs : RS} (h : Valid cls rs.iv) :
    Valid cls (runA cls is rs).iv := by
  induction is generalizing rs with
  | nil => exact h
  | cons i is ih =>
    simp only [runA]
    exact ih (fun ins hin => hok ins (List.mem_cons_of_mem _ hin)) (valid_step h (hok i List.mem_cons_self))

theorem valid_outEdge {blk : Block} (hok : BlockOk blk.instrs) {a e : List Iv} {k : Nat}
    (h : Valid cls a) (he : outEdge cls blk a k = some e) : Valid cls e :=
  valid_edgeIv (valid_runA hok (rs := ⟨a, false, none⟩) h) he

/-! ### widening moves a bound strictly inside a finite set -/

theorem widenHi_le_BIG (thr : List Int) (v : Int) : widenHi thr v ≤ BIG := by
  unfold widenHi
  suffices h : ∀ (l : List Int) (b : Int), b ≤ BIG →
      l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b ≤ BIG from h thr BIG (Int.le_refl _)
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; omega
    · exact hb

theorem floor_le_widenLo (thr : List Int) (v fl : Int) : fl ≤ widenLo thr v fl := by
  unfold widenLo
  suffices h : ∀ (l : List Int) (b : Int), fl ≤ b →
      fl ≤ l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b from h thr fl (Int.le_refl _)
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; omega
    · exact hb

theorem widenHi_mem_or (thr : List Int) (v : Int) : widenHi thr v = BIG ∨ widenHi thr v ∈ thr := by
  unfold widenHi
  suffices h : ∀ (l : List Int) (b : Int), (b = BIG ∨ b ∈ thr) → (∀ t ∈ l, t ∈ thr) →
      (l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b = BIG ∨
       l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b ∈ thr) from
    h thr BIG (Or.inl rfl) (fun _ ht => ht)
  intro l
  induction l with
  | nil => intro b hb _; exact hb
  | cons t l ih =>
    intro b hb hl
    simp only [List.foldl_cons]
    apply ih
    · split
      · exact Or.inr (hl t List.mem_cons_self)
      · exact hb
    · exact fun x hx => hl x (List.mem_cons_of_mem _ hx)

theorem widenLo_mem_or (thr : List Int) (v fl : Int) :
    widenLo thr v fl = fl ∨ widenLo thr v fl ∈ thr := by
  unfold widenLo
  suffices h : ∀ (l : List Int) (b : Int), (b = fl ∨ b ∈ thr) → (∀ t ∈ l, t ∈ thr) →
      (l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b = fl ∨
       l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b ∈ thr) from
    h thr fl (Or.inl rfl) (fun _ ht => ht)
  intro l
  induction l with
  | nil => intro b hb _; exact hb
  | cons t l ih =>
    intro b hb hl
    simp only [List.foldl_cons]
    apply ih
    · split
      · exact Or.inr (hl t List.mem_cons_self)
      · exact hb
    · exact fun x hx => hl x (List.mem_cons_of_mem _ hx)

theorem valid_joinInto {w : Bool} {thr : List Int} {A E : List Iv} (hA : Valid cls A) (hE : Valid cls E) :
    Valid cls (joinInto w thr cls A E) := by
  refine ⟨by rw [length_joinInto]; exact hA.1, fun l hl => ?_⟩
  rw [gi_joinInto (by rw [hA.1]; exact hl)]
  have h1 := hA.2 l hl
  have h2 := hE.2 l hl
  unfold joinIv
  dsimp only
  constructor
  · split
    · split
      · exact floor_le_widenLo _ _ _
      · exact h2.1
    · exact h1.1
  · split
    · split
      · exact widenHi_le_BIG _ _
      · exact h2.2
    · exact h1.2

/-! ### the ranks: positions in the finite lattice of thresholds -/

theorem countP_strict {α : Type} (l : List α) (p q : α → Bool) (h : ∀ x ∈ l, p x = true → q x = true)
    (x : α) (hx : x ∈ l) (hq : q x = true) (hp : p x = false) : l.countP p < l.countP q := by
  induction l with
  | nil => simp at hx
  | cons y ys ih =>
    have hmono : ys.countP p ≤ ys.countP q :=
      List.countP_mono_left (fun z hz => h z (List.mem_cons_of_mem _ hz))
    rw [List.countP_cons, List.countP_cons]
    rcases List.mem_cons.mp hx with rfl | hx'
    · simp [hp, hq]; omega
    · have := ih (fun z hz => h z (List.mem_cons_of_mem _ hz)) hx'
      have hy := h y List.mem_cons_self
      by_cases hpy : p y = true
      · have := hy hpy; simp [hpy, this]; omega
      · by_cases hqy : q y = true <;> simp [hpy, hqy] <;> omega

/-- the position of a lower bound: the thresholds (and the floor) below it -/
def rankLo (thr : List Int) (c : Cls) (v : Int) : Nat :=
  (floorOf c :: thr).countP (fun t => decide (t < v))

/-- the position of an upper bound: the thresholds (and `BIG`) above it -/
def rankHi (thr : List Int) (v : Int) : Nat :=
  (BIG :: thr).countP (fun t => decide (t > v))

theorem rankLo_lt (thr : List Int) (c : Cls) {v v' : Int} (hx : v' ∈ floorOf c :: thr) (h : v' < v) :
    rankLo thr c v' < rankLo thr c v := by
  unfold rankLo
  exact countP_strict _ _ _ (fun t _ ht => by simp only [decide_eq_true_eq] at ht ⊢; omega) v' hx
    (by simp [h]) (by simp)

theorem rankHi_lt (thr : List Int) {v v' : Int} (hx : v' ∈ BIG :: thr) (h : v < v') :
    rankHi thr v' < rankHi thr v := by
  unfold rankHi
  exact countP_strict _ _ _ (fun t _ ht => by simp only [decide_eq_true_eq] at ht ⊢; omega) v' hx
    (by simp [h]) (by simp)

def rankIv (thr : List Int) (c : Cls) (iv : Iv) : Nat := rankLo thr c iv.lo + rankHi thr iv.hi

def rankSt (thr : List Int) (cls : List Cls) (a : List Iv) : Nat :=
  ((List.range a.length).map fun l => rankIv thr (clsOf cls l) (gi a l)).sum

theorem rankIv_joinIv (thr : List Int) (c : Cls) (a e : Iv) (he : floorOf c ≤ e.lo ∧ e.hi ≤ BIG) :
    rankIv thr c (joinIv true thr c a e) ≤ rankIv thr c a ∧
      ((e.lo < a.lo ∨ e.hi > a.hi) → rankIv thr c (joinIv true thr c a e) < rankIv thr c a) := by
  unfold rankIv joinIv
  dsimp only
  simp only [ite_true]
  have hlo : e.lo < a.lo → rankLo thr c (widenLo thr e.lo (floorOf c)) < rankLo thr c a.lo := by
    intro h
    have hle : widenLo thr e.lo (floorOf c) ≤ e.lo := widenLo_le thr e.lo _ he.1
    exact rankLo_lt thr c (by
      rcases widenLo_mem_or thr e.lo (floorOf c) with h | h
      · rw [h]; exact List.mem_cons_self
      · exact List.mem_cons_of_mem _ h) (by omega)
  have hhi : e.hi > a.hi → rankHi thr (widenHi thr e.hi) < rankHi thr a.hi := by
    intro h
    have hge : e.hi ≤ widenHi thr e.hi := widenHi_ge thr e.hi he.2
    exact rankHi_lt thr (by
      rcases widenHi_mem_or thr e.hi with h | h
      · rw [h]; exact List.mem_cons_self
      · exact List.mem_cons_of_mem _ h) (by omega)
  by_cases h1 : e.lo < a.lo <;> by_cases h2 : e.hi > a.hi
  · rw [if_pos h1, if_pos h2]
    have := hlo h1; have := hhi h2
    refine ⟨by omega, fun _ => by omega⟩
  · rw [if_pos h1, if_neg h2]
    have := hlo h1
    refine ⟨by omega, fun _ => by omega⟩
  · rw [if_neg h1, if_pos h2]
    have := hhi h2
    refine ⟨by omega, fun _ => by omega⟩
  · rw [if_neg h1, if_neg h2]
    refine ⟨Nat.le_refl _, fun hm => ?_⟩
    omega

theorem sum_range_le (f g : Nat → Nat) (n : Nat) (h : ∀ l, l < n → f l ≤ g l) :
    ((List.range n).map f).sum ≤ ((List.range n).map g).sum := by
  induction n with
  | zero => simp
  | succ n ih =>
    rw [List.range_succ]
    simp only [List.map_append, List.sum_append, List.map_cons, List.map_nil, List.sum_cons, List.sum_nil]
    have := ih (fun l hl => h l (by omega))
    have := h n (by omega)
    omega

theorem sum_range_lt (f g : Nat → Nat) (n : Nat) (h : ∀ l, l < n → f l ≤ g l)
    (k : Nat) (hk : k < n) (hlt : f k < g k) :
    ((List.range n).map f).sum < ((List.range n).map g).sum := by
  induction n with
  | zero => omega
  | succ n ih =>
    rw [List.range_succ]
    simp only [List.map_append, List.sum_append, List.map_cons, List.map_nil, List.sum_cons, List.sum_nil]
    by_cases hkn : k = n
    · subst hkn
      have := sum_range_le f g k (fun l hl => h l (by omega))
      omega
    · have := ih (fun l hl => h l (by omega)) (by omega)
      have := h n (by omega)
      omega

/-! ### the measure -/

/-- lexicographic order on triples of numbers -/
def Lt3 (x y : Nat × Nat × Nat) : Prop :=
  x.1 < y.1 ∨ (x.1 = y.1 ∧ (x.2.1 < y.2.1 ∨ (x.2.1 = y.2.1 ∧ x.2.2 < y.2.2)))

theorem Lt3.trans {x y z : Nat × Nat × Nat} (h1 : Lt3 x y) (h2 : Lt3 y z) : Lt3 x z := by
  unfold Lt3 at *
  omega

theorem lt3_wf : WellFounded Lt3 := by
  have h : WellFounded (Prod.Lex (fun a b : Nat => a < b)
      (Prod.Lex (fun a b : Nat => a < b) (fun a b : Nat => a < b))) :=
    (Prod.lex Nat.lt_wfRel (Prod.lex Nat.lt_wfRel Nat.lt_wfRel)).wf
  refine Subrelation.wf (fun {x y} hxy => ?_) h
  obtain ⟨a, b, c⟩ := x
  obtain ⟨a', b', c'⟩ := y
  rcases hxy with h1 | ⟨h1, h2 | ⟨h2, h3⟩⟩
  · exact Prod.Lex.left _ _ h1
  · simp only at h1 h2
    subst h1
    exact Prod.Lex.right _ (Prod.Lex.left _ _ h2)
  · simp only at h1 h2 h3
    subst h1; subst h2
    exact Prod.Lex.right _ (Prod.Lex.right _ h3)

/-- the blocks without an in-state -/
def potC0 (n : Nat) (W : WS) : Nat :=
  ((List.range n).map fun s => if (W.A s).isNone then 1 else 0).sum

/-- the changes the blocks may still have before they widen -/
def potC1 (n wa : Nat) (W : WS) : Nat := ((List.range n).map fun s => wa - W.hits s).sum

/-- the positions of the in-states in the lattice of the thresholds -/
def potC2 (n : Nat) (thr : List Int) (cls : List Cls) (W : WS) : Nat :=
  ((List.range n).map fun s => match W.A s with | none => 0 | some a => rankSt thr cls a).sum

def mu (n wa : Nat) (thr : List Int) (cls : List Cls) (W : WS) : Nat × Nat × Nat :=
  (potC0 n W, potC1 n wa W, potC2 n thr cls W)

theorem upd_sum {g g' : Nat → Nat} {m n : Nat} (h : ∀ k, k ≠ m → g' k = g k) (hm : m < n) :
    ((List.range n).map g').sum + g m = ((List.range n).map g).sum + g' m :=
  Heap.sum_range_upd g g' m h n hm

theorem sum_congr {g g' : Nat → Nat} {n : Nat} (h : ∀ k, k < n → g' k = g k) :
    ((List.range n).map g').sum = ((List.range n).map g).sum := by
  congr 1
  apply List.map_congr_left
  intro k hk
  exact h k (List.mem_range.mp hk)

theorem potC0_lt {W W' : WS} {n s : Nat} (hs : s < n) (h0 : W.A s = none)
    (h1 : (W'.A s).isNone = false) (ho : ∀ k, k ≠ s → W'.A k = W.A k) :
    potC0 n W' < potC0 n W := by
  have := upd_sum (g := fun k => if (W.A k).isNone then 1 else 0)
    (g' := fun k => if (W'.A k).isNone then 1 else 0) (m := s) (n := n)
    (fun k hk => by simp only [ho k hk]) hs
  simp only [h0, h1, Option.isNone_none, ite_true, Bool.false_eq_true, ite_false] at this
  unfold potC0
  omega

theorem potC0_eq {W W' : WS} {n s : Nat} (h1 : (W'.A s).isNone = (W.A s).isNone)
    (ho : ∀ k, k ≠ s → W'.A k = W.A k) : potC0 n W' = potC0 n W := by
  unfold potC0
  apply sum_congr
  intro k _
  by_cases hk : k = s
  · subst hk; simp only [h1]
  · simp only [ho k hk]

theorem potC1_lt {W W' : WS} {n wa s : Nat} (hs : s < n) (h : W.hits s < wa)
    (hh : ∀ k, W'.hits k = if k = s then W.hits s + 1 else W.hits k) :
    potC1 n wa W' < potC1 n wa W := by
  have := upd_sum (g := fun k => wa - W.hits k) (g' := fun k => wa - W'.hits k) (m := s) (n := n)
    (fun k hk => by simp only [hh k, hk, if_false]) hs
  simp only [hh s, if_true] at this
  unfold potC1
  omega

theorem potC1_eq {W W' : WS} {n wa s : Nat} (h : wa ≤ W.hits s)
    (hh : ∀ k, W'.hits k = if k = s then W.hits s + 1 else W.hits k) :
    potC1 n wa W' = potC1 n wa W := by
  unfold potC1
  apply sum_congr
  intro k _
  by_cases hk : k = s
  · subst hk; simp only [hh k, if_true]; omega
  · simp only [hh k, hk, if_false]

theorem potC2_lt {W W' : WS} {n s : Nat} {thr : List Int} {cls : List Cls} (hs : s < n)
    {a a' : List Iv} (hA : W.A s = some a) (hA' : W'.A s = some a')
    (ho : ∀ k, k ≠ s → W'.A k = W.A k) (hr : rankSt thr cls a' < rankSt thr cls a) :
    potC2 n thr cls W' < potC2 n thr cls W := by
  have := upd_sum
    (g := fun k => match W.A k with | none => 0 | some a => rankSt thr cls a)
    (g' := fun k => match W'.A k with | none => 0 | some a => rankSt thr cls a) (m := s) (n := n)
    (fun k hk => by simp only [ho k hk]) hs
  simp only [hA, hA'] at this
  unfold potC2
  omega

/-- the invariant of the iteration that the measure needs -/
structure TInv (fn : Fn) (W : WS) : Prop where
  valid : ∀ c a, W.A c = some a → Valid fn.cls a
  work : ∀ c, c ∈ W.work → c < fn.blocks.length ∧ ∃ a, W.A c = some a

/-- the function is closed (the entry block exists, every successor is a block) and its array
literals are small -/
structure FnOk (fn : Fn) : Prop where
  entry : 0 < fn.blocks.length
  succ : ∀ (b : Nat) (blk : Block), fn.blocks[b]? = some blk → ∀ s ∈ blk.term.succs, s < fn.blocks.length
  arr : ∀ (b : Nat) (blk : Block), fn.blocks[b]? = some blk → BlockOk blk.instrs

theorem valid_unknownIv (cls : List Cls) : Valid cls (unknownIv cls) := by
  refine ⟨length_unknownIv cls, fun l hl => ?_⟩
  rw [gi_unknownIv hl]
  simp [unkOf, BIG]

theorem tinv_init (fn : Fn) (h : 0 < fn.blocks.length) : TInv fn (initW fn.cls) := by
  refine ⟨fun c a hc => ?_, fun c hc => ?_⟩
  · by_cases h0 : c = 0
    · subst h0
      simp [initW, setA] at hc
      subst hc
      exact valid_unknownIv _
    · simp [initW, setA, h0] at hc
  · simp [initW] at hc
    subst hc
    exact ⟨h, unknownIv fn.cls, by simp [initW, setA]⟩

/-- **One flow into a block.** It either changes nothing or lowers the measure; the invariant is kept. -/
theorem feed_dec {fn : Fn} {wa : Nat} {thr : List Int} {W : WS} {s : Nat} {e : List Iv}
    (hI : TInv fn W) (hs : s < fn.blocks.length) (he : Valid fn.cls e) :
    TInv fn (feed wa thr fn.cls W s e) ∧
      (feed wa thr fn.cls W s e = W ∨
        Lt3 (mu fn.blocks.length wa thr fn.cls (feed wa thr fn.cls W s e))
          (mu fn.blocks.length wa thr fn.cls W)) := by
  have fs := feed_spec (wa := wa) (thr := thr) (s := s) (fun c a h => (hI.valid c a h).1) he.1
  unfold feed
  cases hA : W.A s with
  | none =>
    dsimp only
    have hset : ∀ k, k ≠ s → setA W.A s (some e) k = W.A k := fun k hk => by simp [setA, hk]
    refine ⟨⟨fun c a hc => ?_, fun c hc => ?_⟩, Or.inr (Or.inl ?_)⟩
    · by_cases hcs : c = s
      · subst hcs
        simp only [setA, if_true] at hc
        cases hc; exact he
      · have hc2 : setA W.A s (some e) c = some a := hc
        rw [hset c hcs] at hc2; exact hI.valid c a hc2
    · have hc' : c ∈ (if s ∈ W.work then W.work else s :: W.work) := hc
      have hc'' : c = s ∨ c ∈ W.work := by
        split at hc'
        · exact Or.inr hc'
        · rcases List.mem_cons.mp hc' with h | h
          · exact Or.inl h
          · exact Or.inr h
      rcases hc'' with rfl | hcw
      · exact ⟨hs, e, by simp [setA]⟩
      · obtain ⟨hlt, a, ha⟩ := hI.work c hcw
        refine ⟨hlt, ?_⟩
        by_cases hcs : c = s
        · subst hcs; exact ⟨e, by simp [setA]⟩
        · exact ⟨a, by show setA W.A s (some e) c = some a; rw [hset c hcs]; exact ha⟩
    · exact potC0_lt (W := W) (W' := ⟨setA W.A s (some e), W.hits, _⟩) hs hA (by simp [setA]) hset
  | some a =>
    dsimp only
    by_cases hm : joinMoved a e = true
    · rw [if_pos hm]
      have hset : ∀ k, k ≠ s → setA W.A s (some (joinInto (decide (wa ≤ W.hits s)) thr fn.cls a e)) k
          = W.A k := fun k hk => by simp [setA, hk]
      have hjv : Valid fn.cls (joinInto (decide (wa ≤ W.hits s)) thr fn.cls a e) :=
        valid_joinInto (hI.valid s a hA) he
      have hhits : ∀ k, (fun x => if x = s then W.hits s + 1 else W.hits x) k
          = if k = s then W.hits s + 1 else W.hits k := fun k => rfl
      refine ⟨⟨fun c a' hc => ?_, fun c hc => ?_⟩, Or.inr ?_⟩
      · by_cases hcs : c = s
        · subst hcs
          simp only [setA, if_true] at hc
          cases hc; exact hjv
        · have hc2 : setA W.A s (some (joinInto (decide (wa ≤ W.hits s)) thr fn.cls a e)) c = some a' := hc
          rw [hset c hcs] at hc2; exact hI.valid c a' hc2
      · have hc' : c ∈ (if s ∈ W.work then W.work else s :: W.work) := hc
        have hc'' : c = s ∨ c ∈ W.work := by
          split at hc'
          · exact Or.inr hc'
          · rcases List.mem_cons.mp hc' with h | h
            · exact Or.inl h
            · exact Or.inr h
        rcases hc'' with rfl | hcw
        · exact ⟨hs, joinInto (decide (wa ≤ W.hits c)) thr fn.cls a e, by simp [setA]⟩
        · obtain ⟨hlt, a2, ha2⟩ := hI.work c hcw
          refine ⟨hlt, ?_⟩
          by_cases hcs : c = s
          · subst hcs; exact ⟨joinInto (decide (wa ≤ W.hits c)) thr fn.cls a e, by simp [setA]⟩
          · exact ⟨a2, by show setA W.A s (some (joinInto (decide (wa ≤ W.hits s)) thr fn.cls a e)) c = some a2; rw [hset c hcs]; exact ha2⟩
      · have hlen : a.length = fn.cls.length := (hI.valid s a hA).1
        by_cases hw : wa ≤ W.hits s
        · -- widened: a bound moves strictly inside the finite lattice
          have hr : rankSt thr fn.cls (joinInto true thr fn.cls a e) < rankSt thr fn.cls a := by
            unfold joinMoved at hm
            rw [List.any_eq_true] at hm
            obtain ⟨l, hl, hl2⟩ := hm
            have hl' : l < a.length := List.mem_range.mp hl
            unfold rankSt
            rw [length_joinInto]
            apply sum_range_lt _ _ a.length _ l hl'
            · rw [gi_joinInto hl']
              have := (rankIv_joinIv thr (clsOf fn.cls l) (gi a l) (gi e l) (he.2 l (by omega))).2
              simp only [Bool.or_eq_true, decide_eq_true_eq] at hl2
              exact this (by rcases hl2 with h | h; exact Or.inl h; exact Or.inr h)
            · intro l' hl''
              rw [gi_joinInto hl'']
              exact (rankIv_joinIv thr (clsOf fn.cls l') (gi a l') (gi e l') (he.2 l' (by omega))).1
          have hr' : rankSt thr fn.cls (joinInto (decide (wa ≤ W.hits s)) thr fn.cls a e) <
              rankSt thr fn.cls a := by
            simpa [hw] using hr
          show potC0 _ _ < potC0 _ _ ∨ (potC0 _ _ = potC0 _ _ ∧ (potC1 _ _ _ < potC1 _ _ _ ∨
            (potC1 _ _ _ = potC1 _ _ _ ∧ potC2 _ _ _ _ < potC2 _ _ _ _)))
          refine Or.inr ⟨?_, Or.inr ⟨?_, ?_⟩⟩
          · exact potC0_eq (by simp [setA, hA]) hset
          · exact potC1_eq hw hhits
          · exact potC2_lt hs hA (by simp [setA]) hset hr'
        · -- not yet widened: the block has one change fewer to go
          have hw' : W.hits s < wa := by omega
          exact Or.inr ⟨potC0_eq (by simp [setA, hA]) hset, Or.inl (potC1_lt hs hw' hhits)⟩
    · rw [if_neg hm]
      exact ⟨hI, Or.inl rfl⟩

/-! ### edges, blocks, the iteration -/

/-- the measure does not grow: unchanged, or lowered -/
def LeW (n wa : Nat) (thr : List Int) (cls : List Cls) (W1 W0 : WS) : Prop :=
  W1 = W0 ∨ Lt3 (mu n wa thr cls W1) (mu n wa thr cls W0)

theorem LeW.trans {n wa : Nat} {thr : List Int} {cls : List Cls} {W2 W1 W0 : WS}
    (h1 : LeW n wa thr cls W2 W1) (h2 : LeW n wa thr cls W1 W0) : LeW n wa thr cls W2 W0 := by
  rcases h1 with rfl | h1
  · exact h2
  · rcases h2 with rfl | h2
    · exact Or.inr h1
    · exact Or.inr (h1.trans h2)

theorem edgeStep_dec {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {b : Nat} {blk : Block}
    (hb : fn.blocks[b]? = some blk) {a : List Iv} (ha : Valid fn.cls a) {W : WS} (hI : TInv fn W)
    (k : Nat) :
    TInv fn (edgeStep wa thr fn.cls blk a W k) ∧
      LeW fn.blocks.length wa thr fn.cls (edgeStep wa thr fn.cls blk a W k) W := by
  unfold edgeStep
  cases hs : blk.term.succs[k]? with
  | none => exact ⟨hI, Or.inl rfl⟩
  | some s =>
    cases ho : outEdge fn.cls blk a k with
    | none => exact ⟨hI, Or.inl rfl⟩
    | some e =>
      dsimp only
      have hsl : s < fn.blocks.length := hF.succ b blk hb s (List.mem_of_getElem? hs)
      have hev : Valid fn.cls e := valid_outEdge (hF.arr b blk hb) ha ho
      exact feed_dec hI hsl hev

theorem procBlock_dec {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {b : Nat} {blk : Block}
    (hb : fn.blocks[b]? = some blk) {a : List Iv} (ha : Valid fn.cls a) {W0 : WS}
    (hI : TInv fn W0) :
    TInv fn (procBlock wa thr fn.cls blk a W0) ∧
      LeW fn.blocks.length wa thr fn.cls (procBlock wa thr fn.cls blk a W0) W0 := by
  unfold procBlock
  suffices h : ∀ m, TInv fn ((List.range m).foldl (edgeStep wa thr fn.cls blk a) W0) ∧
      LeW fn.blocks.length wa thr fn.cls ((List.range m).foldl (edgeStep wa thr fn.cls blk a) W0) W0 from
    h _
  intro m
  induction m with
  | zero => exact ⟨hI, Or.inl rfl⟩
  | succ m ih =>
    rw [List.range_succ, List.foldl_append]
    simp only [List.foldl_cons, List.foldl_nil]
    obtain ⟨h1, h2⟩ := ih
    obtain ⟨h3, h4⟩ := edgeStep_dec hF hb ha h1 m
    exact ⟨h3, h4.trans h2⟩

/-- the step relation of the worklist is lowered by the lexicographic measure on
(measure, length of the worklist) -/
def WLt (n wa : Nat) (thr : List Int) (cls : List Cls) (W' W : WS) : Prop :=
  Lt3 (mu n wa thr cls W') (mu n wa thr cls W) ∨
    (mu n wa thr cls W' = mu n wa thr cls W ∧ W'.work.length < W.work.length)

theorem wlt_wf (n wa : Nat) (thr : List Int) (cls : List Cls) : WellFounded (WLt n wa thr cls) := by
  have h : WellFounded (Prod.Lex Lt3 (fun a b : Nat => a < b)) :=
    (Prod.lex ⟨Lt3, lt3_wf⟩ Nat.lt_wfRel).wf
  have h2 := InvImage.wf (fun W : WS => (mu n wa thr cls W, W.work.length)) h
  refine Subrelation.wf (fun {W' W} hxy => ?_) h2
  rcases hxy with h1 | ⟨h1, h3⟩
  · exact Prod.Lex.left _ _ h1
  · show Prod.Lex Lt3 (fun a b : Nat => a < b) (mu n wa thr cls W', W'.work.length)
      (mu n wa thr cls W, W.work.length)
    rw [h1]
    exact Prod.Lex.right _ h3

theorem wstep_dec {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {W W' : WS}
    (hI : TInv fn W) (hS : WStep fn wa thr W W') :
    TInv fn W' ∧ WLt fn.blocks.length wa thr fn.cls W' W := by
  cases hS with
  | pop hbw hAb hblk =>
    rename_i b a blk
    have hI0 : TInv fn (⟨W.A, W.hits, W.work.erase b⟩ : WS) :=
      ⟨hI.valid, fun c hc => hI.work c (List.mem_of_mem_erase hc)⟩
    obtain ⟨h1, h2⟩ := procBlock_dec (wa := wa) (thr := thr) hF hblk (hI.valid b a hAb) hI0
    refine ⟨h1, ?_⟩
    rcases h2 with h2 | h2
    · right
      refine ⟨?_, ?_⟩
      · rw [h2]; rfl
      · rw [h2]
        show (W.work.erase b).length < W.work.length
        rw [List.length_erase_of_mem hbw]
        have : 0 < W.work.length := List.length_pos_of_mem hbw
        omega
    · left
      exact h2

theorem wreach_tinv {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {W : WS}
    (h : WReach fn wa thr W) : TInv fn W := by
  induction h with
  | init => exact tinv_init fn hF.entry
  | step _ hs ih => exact (wstep_dec hF ih hs).1

/-- the iteration never gets stuck: a queued block can be popped -/
theorem wstep_progress {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {W : WS}
    (hI : TInv fn W) (hw : W.work ≠ []) : ∃ W', WStep fn wa thr W W' := by
  cases hl : W.work with
  | nil => exact absurd hl hw
  | cons c cs =>
    obtain ⟨hc, a, ha⟩ := hI.work c (by rw [hl]; exact List.mem_cons_self)
    obtain ⟨blk, hblk⟩ : ∃ blk, fn.blocks[c]? = some blk :=
      ⟨fn.blocks[c], List.getElem?_eq_getElem hc⟩
    exact ⟨_, WStep.pop (by rw [hl]; exact List.mem_cons_self) ha hblk⟩

/-- **Termination.**  Every run of the worklist iteration ends, for every pop order, every list of
widening thresholds and every widening delay: the step relation is well-founded on the reachable
configurations. -/
theorem fix_acc {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {W : WS}
    (h : WReach fn wa thr W) : Acc (fun W' W0 => WStep fn wa thr W0 W') W := by
  have key : ∀ W : WS, TInv fn W → Acc (fun W' W0 => WStep fn wa thr W0 W') W := by
    intro W
    induction W using (wlt_wf fn.blocks.length wa thr fn.cls).induction with
    | _ W ih =>
      intro hI
      refine Acc.intro _ (fun W' hS => ?_)
      obtain ⟨hI', hlt⟩ := wstep_dec hF hI hS
      exact ih W' hlt hI'
  exact key W (wreach_tinv hF h)

/-- **Total correctness of the fixpoint.**  On a well-formed function the iteration reaches a
configuration with an empty worklist (whatever the pop order), and that configuration's table
describes every reachable frame. -/
theorem fix_total {fn : Fn} (hF : FnOk fn) (wa : Nat) (thr : List Int) :
    ∃ W, WReach fn wa thr W ∧ W.work = [] ∧ TabSound fn W.A := by
  have key : ∀ W : WS, WReach fn wa thr W → Acc (fun W' W0 => WStep fn wa thr W0 W') W →
      ∃ W2, WReach fn wa thr W2 ∧ W2.work = [] := by
    intro W hW hacc
    induction hacc with
    | intro W _ ih =>
      by_cases hw : W.work = []
      · exact ⟨W, hW, hw⟩
      · obtain ⟨W', hS⟩ := wstep_progress hF (wreach_tinv hF hW) hw
        exact ih W' hS (WReach.step hW hS)
  obtain ⟨W, hW, hw⟩ := key _ WReach.init (fix_acc hF WReach.init)
  exact ⟨W, hW, hw, fix_sound hW hw⟩

/-- **U1, total.**  On a well-formed function the worklist iteration ends, and every access that the
resulting table justifies (`accessOk`) is in bounds in every execution that reaches it. -/
theorem u1_total {fn : Fn} (hF : FnOk fn) (wa : Nat) (thr : List Int) :
    ∃ W, WReach fn wa thr W ∧ W.work = [] ∧
      ∀ (b : Nat) (blk : Block) (a : List Iv) (pre post : List RI) (ins : RI) (s_in s_pre : CS),
        fn.blocks[b]? = some blk → W.A b = some a → blk.instrs = pre ++ ins :: post →
        accessOk fn.cls (runA fn.cls pre ⟨a, false, none⟩) ins = true → IdxScalar fn.cls ins →
        Reach fn b s_in → RunI fn.cls pre s_in s_pre → AccessAt fn.cls s_pre ins := by
  obtain ⟨W, hW, hw, hT⟩ := fix_total hF wa thr
  exact ⟨W, hW, hw, fun b blk a pre post ins s_in s_pre hb hA hi hok hw' hr hrun =>
    u1_sound hT hb hA hi hok hw' hr hrun⟩

/-- every maximal run ends in an empty worklist: a configuration with a non-empty worklist always
has a successor, and there is no infinite run -/
theorem fix_every_run_ends {fn : Fn} (hF : FnOk fn) {wa : Nat} {thr : List Int} {W : WS}
    (h : WReach fn wa thr W) :
    Acc (fun W' W0 => WStep fn wa thr W0 W') W ∧ (W.work ≠ [] → ∃ W', WStep fn wa thr W W') :=
  ⟨fix_acc hF h, fun hw => wstep_progress hF (wreach_tinv hF h) hw⟩

end Range
end Orin
