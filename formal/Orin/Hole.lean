import Orin.SimArr

/-!
# Open holes and their owners (static side)

Every open hole `(x, i)` of an abstract state belongs to a local `x` that is `Unique` (the object
was allocated, or a slot was taken out of it, through `x` alone).  `HU a` states this; it is
preserved by every transfer function (`HU_stepA`) and by the join (`joinS_spec`).  `FleS a b` is
the weakening relation `Cont` uses: kinds weaken (`Fle`), the hole set is the same, and the owners
of open holes keep their kind.  The type-and-hole invariant of `Typed.lean` needs exactly this.
-/

namespace Orin

/-- same hole set -/
def HEq (h1 h2 : List (Nat × Nat)) : Prop := ∀ p, p ∈ h1 ↔ p ∈ h2

theorem HEq.refl (h : List (Nat × Nat)) : HEq h h := fun _ => Iff.rfl
theorem HEq.symm {h1 h2 : List (Nat × Nat)} (e : HEq h1 h2) : HEq h2 h1 := fun p => (e p).symm
theorem HEq.trans {h1 h2 h3 : List (Nat × Nat)} (e1 : HEq h1 h2) (e2 : HEq h2 h3) : HEq h1 h3 :=
  fun p => (e1 p).trans (e2 p)

/-- every open hole belongs to a `Unique` local -/
def HU (a : AState) : Prop := ∀ p ∈ a.holes, gk a.ls p.1 = .unique

/-- `b` weakens `a` without touching holes or their owners -/
def FleS (a b : AState) : Prop :=
  Fle a.ls b.ls ∧ HEq a.holes b.holes ∧ ∀ p ∈ a.holes, gk b.ls p.1 = gk a.ls p.1

theorem FleS.self_right {a b : AState} (h : FleS a b) : FleS b b :=
  ⟨⟨rfl, fun _ => Or.inl rfl, h.1.2.2⟩, HEq.refl _, fun _ _ => rfl⟩

theorem FleS.trans {a b c : AState} (h1 : FleS a b) (h2 : FleS b c) : FleS a c :=
  ⟨h1.1.trans h2.1, h1.2.1.trans h2.2.1, fun p hp => by
    rw [h2.2.2 p ((h1.2.1 p).mp hp), h1.2.2 p hp]⟩

theorem hasHole_iff (hs : List (Nat × Nat)) (x : Nat) : hasHole hs x = true ↔ ∃ i, (x, i) ∈ hs := by
  unfold hasHole
  rw [List.any_eq_true]
  constructor
  · rintro ⟨p, hp, hx⟩
    have : p.1 = x := by simpa using hx
    exact ⟨p.2, by rw [← this]; exact hp⟩
  · rintro ⟨i, hi⟩
    exact ⟨(x, i), hi, by simp⟩

theorem holesEq_spec {h1 h2 : List (Nat × Nat)} (h : holesEq h1 h2 = true) : HEq h1 h2 := by
  unfold holesEq at h
  simp only [Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at h
  intro p
  exact ⟨fun hp => h.1 p hp, fun hp => h.2 p hp⟩

theorem joinS_spec {a1 a2 aj : AState} (h : joinS a1 a2 = some aj) :
    aj = ⟨joinL a1.ls a2.ls, a1.holes⟩ ∧ a1.ls.length = a2.ls.length ∧ HEq a1.holes a2.holes := by
  unfold joinS at h
  split at h
  · rename_i hc
    exact ⟨(Option.some.inj h).symm, hc.1, holesEq_spec hc.2⟩
  · cases h

theorem gk_joinL_unique {a1 a2 : List AS} (hl : a1.length = a2.length) {x : Nat}
    (h1 : gk a1 x = .unique) (h2 : gk a2 x = .unique) : gk (joinL a1 a2) x = .unique := by
  rw [gk_joinL a1 a2 hl, h1, h2]
  simp [jk, postK]

/-- the join keeps holes and their owners, and is an upper bound of both sides -/
theorem joinS_fleS {a1 a2 aj : AState} (h : joinS a1 a2 = some aj) (hu1 : HU a1) (hu2 : HU a2) :
    FleS a1 aj ∧ FleS a2 aj ∧ HU aj := by
  obtain ⟨hj, hl, he⟩ := joinS_spec h
  subst hj
  refine ⟨⟨joinL_fle_left _ _ hl, HEq.refl _, fun p hp => ?_⟩,
    ⟨joinL_fle_right _ _ hl, he.symm, fun p hp => ?_⟩, fun p hp => ?_⟩
  · exact gk_joinL_unique hl (hu1 p hp) (hu2 p ((he p).mp hp)) |>.trans (hu1 p hp).symm
  · have hp1 : p ∈ a1.holes := (he p).mpr hp
    exact (gk_joinL_unique hl (hu1 p hp1) (hu2 p hp)).trans (hu2 p hp).symm
  · exact gk_joinL_unique hl (hu1 p hp) (hu2 p ((he p).mp hp))

/-! ### the transfer functions keep holes with `Unique` owners -/

theorem stepA_split {np : Nat} {a a1 : AState} {i : MI} (h : stepA np a i = some a1) :
    ∃ ls' h', stepL np a.ls i = some ls' ∧ stepH a.holes i = some h' ∧ a1 = ⟨ls', h'⟩ := by
  unfold stepA at h
  cases hs : stepL np a.ls i with
  | none => rw [hs] at h; simp at h
  | some ls' =>
    rw [hs] at h
    simp only [Option.map_eq_some_iff] at h
    obtain ⟨h', hh, rfl⟩ := h
    exact ⟨ls', h', rfl, hh, rfl⟩

/-- an untouched local keeps its kind through `defK` -/
theorem gk_defK_ne {a : List AS} {d x : Nat} {k : AS} (hd : d < a.length) (hx : x ≠ d)
    (hu : gk a x = .unique) : gk (defK a d k) x = .unique := by
  rw [gk_defK a d k x hd]; simp [hx, hu]

theorem gk_killB_ne {a : List AS} {y x : Nat} (hu : gk a x = .unique) :
    gk (killB y a) x = .unique := by
  rw [gk_killB]; simp [hu]

theorem gk_killK_ne {a : List AS} {l x : Nat} (hl : l < a.length) (hx : x ≠ l)
    (hu : gk a x = .unique) : gk (killK a l) x = .unique :=
  gk_defK_ne hl hx hu

theorem gk_demote_ne {a : List AS} {l x : Nat} (hl : l < a.length) (hx : x ≠ l)
    (hu : gk a x = .unique) : gk (demote a l) x = .unique := by
  rw [gk_demote a l x hl]; simp [hx, hu]

theorem hasHole_ne {hs : List (Nat × Nat)} {x d : Nat} (hx : ∃ i, (x, i) ∈ hs)
    (hd : hasHole hs d = false) : x ≠ d := by
  intro e
  subst e
  have := (hasHole_iff hs x).mpr hx
  rw [hd] at this; cases this

theorem stepSet_keep {a : List AS} {x v y : Nat} {a1 : List AS} (h : stepSet a x v = some a1)
    (hy : y ≠ v) (hu : gk a y = .unique) : gk a1 y = .unique := by
  unfold stepSet at h
  split at h
  · obtain ⟨a2, h2, rfl⟩ := Option.map_eq_some_iff.mp h
    obtain ⟨hv, hc⟩ := consume_spec h2
    rcases hc with ⟨_, rfl⟩ | ⟨_, rfl⟩
    · exact gk_killB_ne hu
    · exact gk_killB_ne (gk_killK_ne hv hy hu)
  · cases h

theorem stepGet_keep {np : Nat} {a : List AS} {d o y : Nat} {r : Bool} {a1 : List AS}
    (h : stepGet np a d o r = some a1) (hy : y ≠ d) (hu : gk a y = .unique) :
    gk a1 y = .unique := by
  unfold stepGet at h
  split at h
  · rename_i hc
    split at h
    · split at h
      · cases h; exact gk_defK_ne hc.1 hy hu
      · cases h
    · cases h; exact gk_defK_ne hc.1 hy hu
  · cases h

theorem HU_stepA {np : Nat} {a a1 : AState} {i : MI} (hu : HU a) (h : stepA np a i = some a1) :
    HU a1 := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  intro p hp
  simp only at hp ⊢
  have hpu := hu
  cases i with
  | const d n =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        exact gk_defK_ne hc.1 (hasHole_ne ⟨p.2, hp⟩ (by simpa using hnh)) (hu p hp)
    · cases hL
  | move d s =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        have hns : hasHole a.holes s = false := by
          cases hh : hasHole a.holes s <;> simp_all
        exact gk_defK_ne (by simpa [killK, defK, killB] using hc.1)
          (hasHole_ne ⟨p.2, hp⟩ hnd)
          (gk_killK_ne hc.2.1 (hasHole_ne ⟨p.2, hp⟩ hns) (hu p hp))
    · cases hL
  | borrow d s =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        have hns : hasHole a.holes s = false := by
          cases hh : hasHole a.holes s <;> simp_all
        exact gk_defK_ne (by rw [length_demote]; exact hc.1)
          (hasHole_ne ⟨p.2, hp⟩ hnd)
          (gk_demote_ne hc.2.1 (hasHole_ne ⟨p.2, hp⟩ hns) (hu p hp))
    · cases hL
  | dup d s =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        have hns : hasHole a.holes s = false := by
          cases hh : hasHole a.holes s <;> simp_all
        exact gk_defK_ne (by rw [length_demote]; exact hc.1)
          (hasHole_ne ⟨p.2, hp⟩ hnd)
          (gk_demote_ne hc.2.1 (hasHole_ne ⟨p.2, hp⟩ hns) (hu p hp))
    · cases hL
  | release x =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnx : hasHole a.holes x = false := by
          cases hh : hasHole a.holes x <;> simp_all
        exact gk_killK_ne hc.1 (hasHole_ne ⟨p.2, hp⟩ hnx) (hu p hp)
    · cases hL
  | alloc d n =>
    simp only [stepL, stepAlloc] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        rcases List.mem_append.mp hp with hp1 | hp2
        · exact gk_defK_ne hc.1 (hasHole_ne ⟨p.2, hp1⟩ hnd) (hu p hp1)
        · obtain ⟨j, _, hj⟩ := List.mem_map.mp hp2
          rw [← hj]
          exact defK_self a.ls d .unique hc.1
    · cases hL
  | getField d o j r =>
    simp only [stepL] at hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh; cases hH
      have hnd : hasHole a.holes d = false := by
        cases hh : hasHole a.holes d <;> simp_all
      exact stepGet_keep hL (hasHole_ne ⟨p.2, hp⟩ hnd) (hu p hp)
  | setField x j v =>
    simp only [stepL] at hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh; cases hH
      have hnv : hasHole a.holes v = false := by
        cases hh : hasHole a.holes v <;> simp_all
      exact stepSet_keep hL (hasHole_ne ⟨p.2, hp⟩ hnv) (hu p hp)
  | takeField d x j =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        rcases List.mem_cons.mp hp with e | hp1
        · rw [e]
          exact gk_defK_ne (by simpa [killB] using hc.1) (Ne.symm hc.2.2.2.1)
            (gk_killB_ne hc.2.2.2.2)
        · exact gk_defK_ne (by simpa [killB] using hc.1) (hasHole_ne ⟨p.2, hp1⟩ hnd)
            (gk_killB_ne (hu p hp1))
    · cases hL
  | putField x j sv =>
    simp only [stepL] at hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh; cases hH
      have hnv : hasHole a.holes sv = false := by
        cases hh : hasHole a.holes sv <;> simp_all
      have hp1 : p ∈ a.holes := (List.mem_filter.mp hp).1
      exact stepSet_keep hL (hasHole_ne ⟨p.2, hp1⟩ hnv) (hu p hp1)
  | makeUnique x =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnx : hasHole a.holes x = false := by
          cases hh : hasHole a.holes x <;> simp_all
        have hxl : x < a.ls.length := hc.1
        have hne := hasHole_ne ⟨p.2, hp⟩ hnx
        have : gk ((killB x a.ls).set x .unique) p.1 = .unique := by
          rw [show (killB x a.ls).set x .unique = defK a.ls x .unique from rfl]
          exact gk_defK_ne hxl hne (hu p hp)
        exact this
    · cases hL
  | arrayLen d x =>
    simp only [stepL] at hL
    split at hL
    · rename_i hc
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        exact gk_defK_ne hc.1 (hasHole_ne ⟨p.2, hp⟩ hnd) (hu p hp)
    · cases hL
  | arrayGet d x j r =>
    simp only [stepL] at hL
    split at hL
    · simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        exact stepGet_keep hL (hasHole_ne ⟨p.2, hp⟩ hnd) (hu p hp)
    · cases hL
  | arraySet x j v =>
    simp only [stepL] at hL
    split at hL
    · simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnv : hasHole a.holes v = false := by
          cases hh : hasHole a.holes v <;> simp_all
        exact stepSet_keep hL (hasHole_ne ⟨p.2, hp⟩ hnv) (hu p hp)
    · cases hL
  | arrayNew d nl =>
    simp only [stepL] at hL
    split at hL
    · simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh; cases hH
        have hnd : hasHole a.holes d = false := by
          cases hh : hasHole a.holes d <;> simp_all
        unfold stepAlloc at hL
        split at hL
        · rename_i hc2
          cases hL
          exact gk_defK_ne hc2.1 (hasHole_ne ⟨p.2, hp⟩ hnd) (hu p hp)
        · cases hL
    · cases hL

/-! ### acceptance keeps the invariant -/

theorem HU_stepAC {np : Nat} {sg : List Sig} {a a1 : AState} {d f : Nat} {args : List Nat}
    (hu : HU a) (h : stepAC np sg a d f args = some a1) : HU a1 := by
  unfold stepAC at h
  cases hc : stepCall sg np a.ls d f args with
  | none => rw [hc] at h; simp at h
  | some ls' =>
    rw [hc] at h
    simp only at h
    split at h
    · rename_i he
      cases h
      intro p hp
      have : a.holes = [] := List.isEmpty_iff.mp he
      simp only [this] at hp
      cases hp
    · cases h

/-- the loop invariant search keeps the owners of holes -/
theorem loopFix_spec_S (body : AState → Option AState) (c : Nat)
    (hbody : ∀ x y, HU x → body x = some y → HU y) :
    ∀ (fuel : Nat) (b bi : AState), HU b → loopFix body c fuel b = some bi →
      HU bi ∧ FleS b bi ∧ c < bi.ls.length ∧ gk bi.ls c = .init ∧
      ∃ b2, body bi = some b2 ∧ FleS b2 bi := by
  intro fuel
  induction fuel with
  | zero => intro b bi _ h; simp [loopFix] at h
  | succ n ih =>
    intro b bi hub h
    simp only [loopFix] at h
    split at h
    · rename_i hc
      cases hb : body b with
      | none => rw [hb] at h; simp at h
      | some b2 =>
        rw [hb] at h
        simp only [Option.bind_some] at h
        cases hj : joinS b b2 with
        | none => rw [hj] at h; simp at h
        | some b' =>
          rw [hj] at h
          simp only [Option.bind_some] at h
          have hub2 : HU b2 := hbody b b2 hub hb
          obtain ⟨hF1, hF2, hub'⟩ := joinS_fleS hj hub hub2
          by_cases hls : b'.ls = b.ls
          · rw [if_pos hls] at h
            have hbi : b = bi := Option.some.inj h
            subst hbi
            have hb'b : b' = b := by
              obtain ⟨hjb, _, _⟩ := joinS_spec hj
              rw [hjb] at hls ⊢
              simp only at hls
              rw [hls]
            rw [hb'b] at hF2 hF1
            exact ⟨hub, hF1, hc.1, hc.2, b2, hb, hF2⟩
          · rw [if_neg hls] at h
            obtain ⟨hubi, hF, hcb, hini, b3, hb3, hF3⟩ := ih b' bi hub' h
            exact ⟨hubi, hF1.trans hF, hcb, hini, b3, hb3, hF3⟩
    · simp at h

theorem HU_chk {np : Nat} {sg : List Sig} : ∀ (t : Code) (a at' : AState), HU a →
    chk np sg a t = some at' → HU at' := by
  intro t
  induction t with
  | nil =>
    intro a at' hu h
    simp only [chk, Option.some.injEq] at h
    subst h; exact hu
  | op i t1 ih =>
    intro a at' hu h
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact ih a1 at' (HU_stepA hu h1) h2
  | ite c t e k1 iht ihe ihk =>
    intro a at' hu h
    simp only [chk] at h
    split at h
    · simp only [Option.bind_eq_some_iff] at h
      obtain ⟨at1, ht, ae, he, aj, hj, hk1⟩ := h
      exact ihk aj at' (joinS_fleS hj (iht a at1 hu ht) (ihe a ae hu he)).2.2 hk1
    · simp at h
  | loop c t1 k1 iht ihk =>
    intro a at' hu h
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨b, hfix, hkb⟩ := h
    exact ihk b at' (loopFix_spec_S _ c (fun x y hx hy => iht x y hx hy) _ a b hu hfix).1 hkb
  | call d f args k1 ih =>
    intro a at' hu h
    simp only [chk, Option.bind_eq_some_iff] at h
    obtain ⟨a1, h1, h2⟩ := h
    exact ih a1 at' (HU_stepAC hu h1) h2

theorem HU_nil (ls : List AS) : HU ⟨ls, []⟩ := fun _ hp => by cases hp

end Orin
