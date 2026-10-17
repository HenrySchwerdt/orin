import Orin.RangeEdge

/-!
# Interval analysis: join, widening, narrowing hull (rule R4)

`Cov cls e a` says that the abstract state `a` covers `e`: whatever frame `e` describes, `a`
describes it (and a known array fact of `a` is a known fact of `e`).  It is the order of the
dataflow analysis, stated by the meaning of an interval (`Mem`) and the class of the local, so
that the lemmas hold without any invariant on the shape of the bounds.

* `joinInto_cov_right` / `joinInto_cov_left`: `joinInto` of `range.or` (the join of the exit state
  `E` into the in-state `A`, plain or widened to a threshold) covers both.  The widening to a
  threshold is sound for every list of thresholds (`widenHi_mem`, `widenLo_mem`).
* `hullAll_cov`: the plain hull of the exit states (the narrowing round) covers every one of them.
-/

namespace Orin
namespace Range

variable {cls : List Cls}

/-- the unknown value of a local of the class is at or above its floor -/
def FloorOk (c : Cls) (x : Int) : Prop := floorOf c ≤ NEG ∨ floorOf c ≤ x

theorem floorOk_of {c : Cls} {x : Int} (h : c.okv x) : FloorOk c x := by
  cases c with
  | int => simp only [FloorOk, floorOf]; unfold NEG; omega
  | usize => simp only [Cls.okv] at h; simp only [FloorOk, floorOf]; unfold NEG; omega
  | bool => simp only [FloorOk, floorOf]; unfold NEG; omega
  | ref => cases h

theorem floorOk_ref (x : Int) : FloorOk .ref x := by
  simp only [FloorOk, floorOf]; unfold NEG; omega

/-- coverage of one interval -/
def IvCov (c : Cls) (e a : Iv) : Prop :=
  (∀ x, FloorOk c x → Mem x e → Mem x a) ∧ (c = .ref → 0 ≤ a.lo → 0 ≤ e.lo)

/-- coverage of a state -/
def Cov (cls : List Cls) (e a : List Iv) : Prop :=
  a.length = cls.length ∧ ∀ l, l < cls.length → IvCov (clsOf cls l) (gi e l) (gi a l)

theorem Cov.refl {a : List Iv} (h : a.length = cls.length) : Cov cls a a :=
  ⟨h, fun _ _ => ⟨fun _ _ hm => hm, fun _ h0 => h0⟩⟩

theorem Cov.trans {a b c : List Iv} (h1 : Cov cls a b) (h2 : Cov cls b c) : Cov cls a c :=
  ⟨h2.1, fun l hl =>
    ⟨fun x hf hm => (h2.2 l hl).1 x hf ((h1.2 l hl).1 x hf hm),
     fun hr h0 => (h1.2 l hl).2 hr ((h2.2 l hl).2 hr h0)⟩⟩

/-- a covering state describes every frame the covered state describes -/
theorem soundS_cov {iv a : List Iv} {s : CS} (hS : SoundS cls iv s) (hc : Cov cls iv a) :
    SoundS cls a s := by
  refine ⟨by rw [hc.1], hS.lenloc, fun x hx hcx => ?_, fun x hk => ?_⟩
  · obtain ⟨n, hn, hok, hm⟩ := hS.scal x hx hcx
    exact ⟨n, hn, hok, (hc.2 x hx).1 n (floorOk_of hok) hm⟩
  · obtain ⟨hr, h0⟩ := hk
    have hx : x < cls.length := clsOf_ref_lt hr
    have hk' : known cls iv x := ⟨hr, (hc.2 x hx).2 hr h0⟩
    obtain ⟨l, n, h1, h2, h3, h4⟩ := hS.fact x hk'
    exact ⟨l, n, h1, h2, (hc.2 x hx).1 n (by rw [hr]; exact floorOk_ref _) h3, h4⟩

/-! ### widening to a threshold -/

theorem widenLo_cases (thr : List Int) (v fl : Int) : widenLo thr v fl = fl ∨ widenLo thr v fl ≤ v := by
  unfold widenLo
  suffices h : ∀ (l : List Int) (b : Int), (b = fl ∨ b ≤ v) →
      (l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b = fl ∨
       l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b ≤ v) from h thr fl (Or.inl rfl)
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; exact Or.inr h.1
    · exact hb

theorem widenHi_cases (thr : List Int) (v : Int) : widenHi thr v = BIG ∨ v ≤ widenHi thr v := by
  unfold widenHi
  suffices h : ∀ (l : List Int) (b : Int), (b = BIG ∨ v ≤ b) →
      (l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b = BIG ∨
       v ≤ l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b) from h thr BIG (Or.inl rfl)
  intro l
  induction l with
  | nil => intro b hb; exact hb
  | cons t l ih =>
    intro b hb
    simp only [List.foldl_cons]
    apply ih
    split
    · rename_i h; exact Or.inr h.1
    · exact hb

/-- widening a lower bound keeps it a lower bound of every value the old bound and the floor allow -/
theorem widenLo_mem (thr : List Int) {v fl x : Int} (hf : fl ≤ NEG ∨ fl ≤ x) (hv : v ≤ NEG ∨ v ≤ x) :
    widenLo thr v fl ≤ NEG ∨ widenLo thr v fl ≤ x := by
  unfold widenLo
  suffices h : ∀ (l : List Int) (b : Int), (b ≤ NEG ∨ b ≤ x) →
      (l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b ≤ NEG ∨
       l.foldl (fun best t => if t ≤ v ∧ t > best then t else best) b ≤ x) from h thr fl hf
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

theorem widenHi_mem (thr : List Int) {v x : Int} (hv : BIG ≤ v ∨ x ≤ v) :
    BIG ≤ widenHi thr v ∨ x ≤ widenHi thr v := by
  unfold widenHi
  suffices h : ∀ (l : List Int) (b : Int), (BIG ≤ b ∨ x ≤ b) →
      (BIG ≤ l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b ∨
       x ≤ l.foldl (fun best t => if t ≥ v ∧ t < best then t else best) b) from
    h thr BIG (Or.inl (Int.le_refl _))
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

/-! ### the join -/

/-- `joinInto` of one local: the lower bound that moved down, the upper bound that moved up
(widened to a threshold when `widen`) -/
def joinIv (widen : Bool) (thr : List Int) (c : Cls) (a e : Iv) : Iv :=
  ⟨if e.lo < a.lo then (if widen then widenLo thr e.lo (floorOf c) else e.lo) else a.lo,
   if e.hi > a.hi then (if widen then widenHi thr e.hi else e.hi) else a.hi⟩

/-- the join of the exit state `E` into the in-state `A` -/
def joinInto (widen : Bool) (thr : List Int) (cls : List Cls) (A E : List Iv) : List Iv :=
  A.mapIdx fun l a => joinIv widen thr (clsOf cls l) a (gi E l)

theorem joinIv_right (w : Bool) (thr : List Int) (c : Cls) (a e : Iv) :
    IvCov c e (joinIv w thr c a e) := by
  refine ⟨fun x hf hm => ?_, fun hr h0 => ?_⟩
  · obtain ⟨hl, hh⟩ := hm
    unfold joinIv Mem
    dsimp only
    refine ⟨?_, ?_⟩
    · split
      · split
        · exact widenLo_mem thr hf hl
        · exact hl
      · omega
    · split
      · split
        · exact widenHi_mem thr hh
        · exact hh
      · omega
  · unfold joinIv at h0
    dsimp only at h0
    split at h0
    · split at h0
      · rcases widenLo_cases thr e.lo (floorOf c) with h | h
        · subst hr; rw [h] at h0; simp only [floorOf] at h0; unfold NEG at h0; omega
        · omega
      · exact h0
    · omega

theorem joinIv_left (w : Bool) (thr : List Int) (c : Cls) (a e : Iv) :
    IvCov c a (joinIv w thr c a e) := by
  refine ⟨fun x hf hm => ?_, fun hr h0 => ?_⟩
  · obtain ⟨hl, hh⟩ := hm
    unfold joinIv Mem
    dsimp only
    refine ⟨?_, ?_⟩
    · split
      · split
        · rcases widenLo_cases thr e.lo (floorOf c) with h | h
          · rw [h]; exact hf
          · omega
        · omega
      · exact hl
    · split
      · split
        · rcases widenHi_cases thr e.hi with h | h
          · rw [h]; omega
          · omega
        · omega
      · exact hh
  · unfold joinIv at h0
    dsimp only at h0
    split at h0
    · split at h0
      · rcases widenLo_cases thr e.lo (floorOf c) with h | h
        · subst hr; rw [h] at h0; simp only [floorOf] at h0; unfold NEG at h0; omega
        · omega
      · omega
    · exact h0

theorem gi_joinInto {w : Bool} {thr : List Int} {A E : List Iv} {l : Nat} (hl : l < A.length) :
    gi (joinInto w thr cls A E) l = joinIv w thr (clsOf cls l) (gi A l) (gi E l) := by
  unfold gi joinInto
  rw [List.getElem?_mapIdx]
  simp [List.getElem?_eq_getElem hl]
  rfl

theorem length_joinInto (w : Bool) (thr : List Int) (cls : List Cls) (A E : List Iv) :
    (joinInto w thr cls A E).length = A.length := by
  simp [joinInto]

theorem joinInto_cov_right {w : Bool} {thr : List Int} {A E : List Iv} (hA : A.length = cls.length) :
    Cov cls E (joinInto w thr cls A E) :=
  ⟨by rw [length_joinInto, hA], fun l hl => by
    rw [gi_joinInto (by omega)]; exact joinIv_right _ _ _ _ _⟩

theorem joinInto_cov_left {w : Bool} {thr : List Int} {A E : List Iv} (hA : A.length = cls.length) :
    Cov cls A (joinInto w thr cls A E) :=
  ⟨by rw [length_joinInto, hA], fun l hl => by
    rw [gi_joinInto (by omega)]; exact joinIv_left _ _ _ _ _⟩

/-! ### the plain hull (narrowing) -/

theorem ivCov_of_le {c : Cls} {e a : Iv} (h : Iv.le e a) : IvCov c e a :=
  ⟨fun _ _ hm => Mem.mono hm h, fun _ h0 => Int.le_trans h0 h.1⟩

def hullStates (A E : List Iv) : List Iv := A.mapIdx fun l a => Iv.hull a (gi E l)

theorem gi_hullStates {A E : List Iv} {l : Nat} (hl : l < A.length) :
    gi (hullStates A E) l = Iv.hull (gi A l) (gi E l) := by
  unfold gi hullStates
  rw [List.getElem?_mapIdx]
  simp [List.getElem?_eq_getElem hl]
  rfl

theorem length_hullStates (A E : List Iv) : (hullStates A E).length = A.length := by
  simp [hullStates]

theorem hullStates_cov_left {A E : List Iv} (hA : A.length = cls.length) :
    Cov cls A (hullStates A E) :=
  ⟨by rw [length_hullStates, hA], fun l hl => by
    rw [gi_hullStates (by omega)]; exact ivCov_of_le (hull_left _ _)⟩

theorem hullStates_cov_right {A E : List Iv} (hA : A.length = cls.length) :
    Cov cls E (hullStates A E) :=
  ⟨by rw [length_hullStates, hA], fun l hl => by
    rw [gi_hullStates (by omega)]; exact ivCov_of_le (hull_right _ _)⟩

/-- the hull of a list of exit states, starting from the first one -/
def hullAll (c : List Iv) (cs : List (List Iv)) : List Iv := cs.foldl hullStates c

theorem hullAll_cov {c : List Iv} (hc : c.length = cls.length) (cs : List (List Iv)) :
    Cov cls c (hullAll c cs) ∧ ∀ e ∈ cs, Cov cls e (hullAll c cs) := by
  induction cs generalizing c with
  | nil => exact ⟨Cov.refl hc, fun e h => by cases h⟩
  | cons d ds ih =>
    have hc' : (hullStates c d).length = cls.length := by rw [length_hullStates]; exact hc
    obtain ⟨h1, h2⟩ := ih hc'
    refine ⟨(hullStates_cov_left hc).trans h1, fun e he => ?_⟩
    rcases List.mem_cons.mp he with rfl | he
    · exact (hullStates_cov_right hc).trans h1
    · exact h2 e he

end Range
end Orin
