import Orin.Sim5

/-!
# Preservation: `setField` / `putField`, `takeField`, `makeUnique`
-/

namespace Orin
open Heap

variable {ext : List Val} {a a' : List AS} {s s' : St} {np : Nat}

theorem clr_locals (s : St) (v : Nat) (hv : v < s.locals.length) :
    ∃ cv, (s.clr v).locals = s.locals.set v cv := by
  unfold St.clr
  cases h : s.get v with
  | ref l => exact ⟨.int 0, rfl⟩
  | int n =>
    refine ⟨.int n, ?_⟩
    simp only
    apply List.ext_getElem?
    intro j
    by_cases hj : j = v
    · subst hj
      have : s.locals[j]? = some (.int n) := by
        have := s.get_spec j hv
        rw [h] at this; exact this
      have h2 : s.locals[j] = .int n := by simpa [hv] using this
      simp [List.getElem?_set, hv, h2]
    · simp [List.getElem?_set, hj, Ne.symm hj]

theorem clr_get_ne (s : St) (v i : Nat) (h : i ≠ v) : (s.clr v).get i = s.get i := by
  unfold St.clr
  cases hh : s.get v with
  | int n => rfl
  | ref l =>
    simp only
    simp [St.get, St.setL, List.getD_eq_getElem?_getD, List.getElem?_set, h, Ne.symm h]

theorem clr_get_self_int (s : St) (v : Nat) (n : Int) (h : s.get v = .int n) :
    (s.clr v).get v = .int n := by
  unfold St.clr; rw [h]; simpa using h

theorem projL_counted_congr (a b : List AS) (ls : List Val)
    (h : ∀ j, (gk a j).counted = (gk b j).counted) : projL a ls = projL b ls := by
  unfold projL
  apply List.ext_getElem?
  intro j
  simp [List.getElem?_mapIdx, pv, h j]

theorem counted_killB (x : Nat) (a : List AS) (j : Nat) :
    (gk (killB x a) j).counted = (gk a j).counted := by
  rw [gk_killB]
  by_cases h : gk a j = .borrowed x
  · simp [h, AS.counted]
  · simp [h]

/-- state after a successful `opSetField` -/
def setSt (s : St) (l : Nat) (ob : Obj) (i v : Nat) (old : Val) : St :=
  { s.clr v with heap := s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) },
                 pending := old :: s.pending }

theorem setObj_other (H : Heap) (l : Nat) (o : Obj) (k : Nat) (hk : k ≠ l) :
    (H.setObj l o).objs k = H.objs k := by
  rw [setObj_objs]; simp [hk]

theorem op_set_core {x i v : Nat} {a1 : List AS} (hI : Inv ext a s) (hx : x < a.length)
    (hxv : x ≠ v) (hu : gk a x = .unique) (hv : v < a.length)
    (hcons : (gk a v = .init ∧ a1 = a) ∨ ((gk a v).counted = true ∧ a1 = killK a v)) :
    OpSafe ext (killB x a1) (opSetField s x i v) := by
  have hxl : x < s.locals.length := hI.len ▸ hx
  have hvl : v < s.locals.length := hI.len ▸ hv
  obtain ⟨l, ob, hl, hob, hrc⟩ := (hI.cl x).uniq hu
  cases hold : ob.fields[i]? with
  | none =>
    have hop : opSetField s x i v = .trap := by
      simp [opSetField, hxl, hvl, hl, hob, hrc, hold]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    · rw [hop] at hs; cases hs
  | some old =>
    have hop : opSetField s x i v = .ok (setSt s l ob i v old) := by
      simp [opSetField, hxl, hvl, hl, hob, hrc, hold, setSt]
    refine ⟨?_, fun s' hs => ?_⟩
    · intro k hh; rw [hop] at hh; cases hh
    rw [hop] at hs
    cases hs
    obtain ⟨cv, hcv⟩ := clr_locals s v hvl
    have hs1 : (setSt s l ob i v old).locals = s.locals.set v cv := hcv
    have hlen1 : (setSt s l ob i v old).locals.length = s.locals.length := by rw [hs1]; simp
    have hlenA1 : a1.length = a.length := by
      rcases hcons with ⟨_, h1⟩ | ⟨_, h1⟩
      · rw [h1]
      · rw [h1]; simp [killK, length_defK]
    have hxget : (setSt s l ob i v old).get x = s.get x := clr_get_ne s v x hxv
    have hheap : (setSt s l ob i v old).heap =
        s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) } := rfl
    have hH : ∀ k, k ≠ l → (setSt s l ob i v old).heap.objs k = s.heap.objs k := by
      intro k hk; rw [hheap]; exact setObj_other _ _ _ _ hk
    have hPx : Pst ext (killB x a1) (setSt s l ob i v old) =
        { Pst ext a1 (setSt s l ob i v old) with heap := (setSt s l ob i v old).heap } := by
      unfold Pst
      rw [projL_counted_congr _ _ _ (counted_killB x a1)]
    have hwf : WF (Pst ext (killB x a1) (setSt s l ob i v old)) := by
      rw [hPx]
      have hoP : (Pst ext a s).heap.objs l = some ob := hob
      have holdP : ob.fields[i]? = some old := hold
      rcases hcons with ⟨hvi, h1⟩ | ⟨hvc, h1⟩
      · rw [h1]
        obtain ⟨n, hn⟩ := (hI.cl v).ini hvi
        have hcl : s.clr v = s := clr_int s v n hn
        have hPe : Pst ext a (setSt s l ob i v old) =
            { Pst ext a s with heap := (setSt s l ob i v old).heap,
                               pending := old :: s.pending } := by
          unfold Pst setSt
          rw [hcl]
        rw [hPe]
        have := wf_store_take (Pst ext a s) hI.wf l ob hoP i old holdP (s.get v)
          (by rw [hn]; trivial) [] s.pending rfl (by intro m; simp [hn, count_single])
        simpa [Pst, hheap, setSt, hcl] using this
      · rw [h1]
        have hPe := Pst_defK ext a a s (setSt s l ob i v old) v .dead cv hI.len
          (fun _ => rfl) hvl hs1
        have hPe' : Pst ext (killK a v) (setSt s l ob i v old) = _ := hPe
        rw [hPe']
        have hQ := wf_release (Pst ext a s) hI.wf v (by rw [Pst_locals_length]; omega)
        have hgv : (Pst ext a s).get v = s.get v := Pst_get_counted hvl hvc
        rw [hgv] at hQ
        have := wf_store_take _ hQ l ob hoP i old holdP (s.get v)
          (hI.wf.locs _ (mem_Pst_of_counted hvl hvc)) [s.get v] s.pending rfl (fun m => rfl)
        simpa [Pst, hheap, setSt, pv, AS.counted] using this
    have hkx : gk a1 x = .unique := by
      rcases hcons with ⟨_, h1⟩ | ⟨_, h1⟩
      · rw [h1]; exact hu
      · rw [h1]; unfold killK; rw [gk_defK _ _ _ _ hv]; simp [hxv, hu]
    have hkinds : (∀ j, ¬ (j = x ∨ j = v) →
          (gk (killB x a1) j = gk a j ∨
            (∃ y, (y = x ∨ y = v) ∧ gk a j = .borrowed y ∧ gk (killB x a1) j = .dead) ∨
            (gk a j = .unique ∧ gk (killB x a1) j = .owned))) ∧
        (∀ j y, ¬ (j = x ∨ j = v) → (y = x ∨ y = v) → gk a j = .borrowed y →
          gk (killB x a1) j = .dead) := by
      rcases hcons with ⟨hvi, h1⟩ | ⟨hvc, h1⟩
      · rw [h1]
        refine ⟨fun j hj => ?_, fun j y hj hy hb => ?_⟩
        · by_cases hb : gk a j = .borrowed x
          · right; left; exact ⟨x, Or.inl rfl, hb, by rw [gk_killB]; simp [hb]⟩
          · left; rw [gk_killB]; simp [hb]
        · rcases hy with rfl | rfl
          · rw [gk_killB]; simp [hb]
          · have := (hI.cl j).bor _ hb
            rw [hvi] at this
            simp [AS.isRoot] at this
      · rw [h1]
        refine ⟨fun j hj => ?_, fun j y hj hy hb => ?_⟩
        · have hj1 : j ≠ x := fun e => hj (Or.inl e)
          have hj2 : j ≠ v := fun e => hj (Or.inr e)
          have hin : gk (killK a v) j = if gk a j = .borrowed v then .dead else gk a j := by
            unfold killK; rw [gk_defK _ _ _ _ hv]; simp [hj2]
          by_cases hbv : gk a j = .borrowed v
          · right; left
            exact ⟨v, Or.inr rfl, hbv, by rw [gk_killB, hin]; simp [hbv]⟩
          · by_cases hbx : gk a j = .borrowed x
            · right; left
              exact ⟨x, Or.inl rfl, hbx, by rw [gk_killB, hin]; simp [hbv, hbx]⟩
            · left; rw [gk_killB, hin]; simp [hbv, hbx]
        · have hj2 : j ≠ v := fun e => hj (Or.inr e)
          have hin : gk (killK a v) j = if gk a j = .borrowed v then .dead else gk a j := by
            unfold killK; rw [gk_defK _ _ _ _ hv]; simp [hj2]
          rcases hy with rfl | rfl
          · have : gk a j ≠ .borrowed v := by rw [hb]; intro e; injection e; exact hxv (by omega)
            rw [gk_killB, hin]; simp [hb, this]
          · rw [gk_killB, hin]; simp [hb]
    have hF := cl_frame (T := fun j => j = x ∨ j = v) (a' := killB x a1)
      (s' := setSt s l ob i v old) hI.cl
      (fun j hj => clr_get_ne s v j (fun e => hj (Or.inr e)))
      hkinds.1 hkinds.2
      (hU_unique hI (T := fun j => j = x ∨ j = v) (Or.inl rfl) hu hl hob hrc hH)
      (hD_unique hI (T := fun j => j = x ∨ j = v) (Or.inl rfl) hu hl hob hrc hH)
    refine ⟨by rw [killB_length, hlenA1, hlen1]; exact hI.len, hwf, fun j => ?_⟩
    by_cases hj : j = x ∨ j = v
    · rcases hj with hj | hj
      · subst hj
        have hkx' : gk (killB j a1) j = .unique := by rw [gk_killB, hkx]; simp
        refine ClAt.of_unique hkx' ⟨l, { ob with fields := ob.fields.set i (s.get v) },
          by rw [hxget, hl], ?_, hrc⟩
        show (s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) }).objs l = _
        rw [setObj_objs]; simp
      · subst hj
        rcases hcons with ⟨hvi, h1⟩ | ⟨hvc, h1⟩
        · obtain ⟨n, hn⟩ := (hI.cl j).ini hvi
          have hk' : gk (killB x a1) j = .init := by rw [h1, gk_killB]; simp [hvi]
          exact ClAt.of_init hk' ⟨n, by
            have := clr_int s j n hn
            show (s.clr j).get j = _
            rw [this]; exact hn⟩
        · have hk' : gk (killB x a1) j = .dead := by
            rw [h1, gk_killB]; unfold killK; rw [defK_self _ _ _ hv]; simp
          exact ClAt.of_dead hk'
    · exact hF j hj

theorem consume_spec {a : List AS} {v : Nat} {a1 : List AS} (h : consume a v = some a1) :
    v < a.length ∧ ((gk a v = .init ∧ a1 = a) ∨ ((gk a v).counted = true ∧ a1 = killK a v)) := by
  unfold consume at h
  split at h
  · rename_i hv
    refine ⟨hv, ?_⟩
    cases hk : gk a v <;> rw [hk] at h <;> simp at h
    · left; exact ⟨rfl, h.symm⟩
    · right; exact ⟨rfl, h.symm⟩
    · right; exact ⟨rfl, h.symm⟩
  · simp at h

theorem op_setField {x i v : Nat} (hI : Inv ext a s)
    (h : stepL np a (.setField x i v) = some a') : OpSafe ext a' (opSetField s x i v) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hx, hxv, hu⟩ := hc
    obtain ⟨a1, h1, h2⟩ := Option.map_eq_some_iff.mp h
    subst h2
    obtain ⟨hv, hcons⟩ := consume_spec h1
    exact op_set_core hI hx hxv hu hv hcons
  · simp at h

theorem op_putField {x i v : Nat} (hI : Inv ext a s)
    (h : stepL np a (.putField x i v) = some a') : OpSafe ext a' (opSetField s x i v) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hx, hxv, hu⟩ := hc
    obtain ⟨a1, h1, h2⟩ := Option.map_eq_some_iff.mp h
    subst h2
    obtain ⟨hv, hcons⟩ := consume_spec h1
    exact op_set_core hI hx hxv hu hv hcons
  · simp at h

/-- state after a successful `opTakeField` -/
def takeSt (s : St) (d l : Nat) (ob : Obj) (i : Nat) (old : Val) : St :=
  { s.setL d old with heap := s.heap.setObj l { ob with fields := ob.fields.set i (.int 0) } }

theorem op_takeField {d x i : Nat} (hI : Inv ext a s)
    (h : stepL np a (.takeField d x i) = some a') : OpSafe ext a' (opTakeField s d x i) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hd, hx, _, hdx, hu⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hdl : d < s.locals.length := hI.len ▸ hd
    have hxl : x < s.locals.length := hI.len ▸ hx
    obtain ⟨l, ob, hl, hob, hrc⟩ := (hI.cl x).uniq hu
    cases hold : ob.fields[i]? with
    | none =>
      have hop : opTakeField s d x i = .trap := by
        simp [opTakeField, hdl, hxl, hl, hob, hrc, hold]
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hop] at hh; cases hh
      · rw [hop] at hs; cases hs
    | some old =>
      cases old with
      | int n =>
        have hop : opTakeField s d x i = .ill := by
          simp [opTakeField, hdl, hxl, hl, hob, hrc, hold]
        refine ⟨?_, fun s' hs => ?_⟩
        · intro k hh; rw [hop] at hh; cases hh
        · rw [hop] at hs; cases hs
      | ref lw =>
        have hop : opTakeField s d x i = .ok (takeSt s d l ob i (.ref lw)) := by
          simp [opTakeField, hdl, hxl, hl, hob, hrc, hold, takeSt]
        refine ⟨?_, fun s' hs => ?_⟩
        · intro k hh; rw [hop] at hh; cases hh
        rw [hop] at hs
        cases hs
        have hs1 : (takeSt s d l ob i (.ref lw)).locals = s.locals.set d (.ref lw) := rfl
        have hheap : (takeSt s d l ob i (.ref lw)).heap =
            s.heap.setObj l { ob with fields := ob.fields.set i (.int 0) } := rfl
        have hH : ∀ k, k ≠ l → (takeSt s d l ob i (.ref lw)).heap.objs k = s.heap.objs k := by
          intro k hk; rw [hheap]; exact setObj_other _ _ _ _ hk
        have hA1 : (killB x a).length = s.locals.length := by rw [killB_length]; exact hI.len
        have hkA : ∀ j, (gk (killB x a) j).counted = (gk a j).counted := counted_killB x a
        have hP := Pst_defK ext a (killB x a) s (takeSt s d l ob i (.ref lw)) d .owned (.ref lw)
          hA1 hkA hdl hs1
        have hoP : (Pst ext a s).heap.objs l = some ob := hob
        have holdP : ob.fields[i]? = some (.ref lw) := hold
        have hdA : d < (killB x a).length := by rw [killB_length]; exact hd
        have hxA : x < a.length := hx
        have hAk : ∀ j, gk (defK (killB x a) d .owned) j =
            if j = d then .owned
            else if gk (killB x a) j = .borrowed d then .dead else gk (killB x a) j :=
          fun j => gk_defK _ _ _ j hdA
        have hBk : ∀ j, gk (killB x a) j = if gk a j = .borrowed x then .dead else gk a j :=
          fun j => gk_killB x a j
        have hkinds : (∀ j, ¬ (j = d ∨ j = x) →
            (gk (defK (killB x a) d .owned) j = gk a j ∨
              (∃ y, (y = d ∨ y = x) ∧ gk a j = .borrowed y ∧
                gk (defK (killB x a) d .owned) j = .dead) ∨
              (gk a j = .unique ∧ gk (defK (killB x a) d .owned) j = .owned))) ∧
          (∀ j y, ¬ (j = d ∨ j = x) → (y = d ∨ y = x) → gk a j = .borrowed y →
            gk (defK (killB x a) d .owned) j = .dead) := by
          refine ⟨fun j hj => ?_, fun j y hj hy hb => ?_⟩
          · have hj1 : j ≠ d := fun e => hj (Or.inl e)
            rw [hAk, hBk]
            simp only [hj1, ite_false]
            by_cases hbx : gk a j = .borrowed x
            · right; left; exact ⟨x, Or.inr rfl, hbx, by simp [hbx]⟩
            · by_cases hbd : gk a j = .borrowed d
              · right; left; exact ⟨d, Or.inl rfl, hbd, by simp [hbx, hbd]⟩
              · left; simp [hbx, hbd]
          · have hj1 : j ≠ d := fun e => hj (Or.inl e)
            rw [hAk, hBk]
            simp only [hj1, ite_false]
            rcases hy with rfl | rfl
            · have : gk a j ≠ .borrowed x := by
                rw [hb]; intro e; injection e; exact hdx (by omega)
              simp [hb, this]
            · simp [hb]
        have hF := cl_frame (T := fun j => j = d ∨ j = x)
          (a' := defK (killB x a) d .owned) (s' := takeSt s d l ob i (.ref lw)) hI.cl
          (fun j hj => get_other s _ d _ hdl hs1 j (fun e => hj (Or.inl e)))
          hkinds.1 hkinds.2
          (hU_unique hI (T := fun j => j = d ∨ j = x) (Or.inr rfl) hu hl hob hrc hH)
          (hD_unique hI (T := fun j => j = d ∨ j = x) (Or.inr rfl) hu hl hob hrc hH)
        refine ⟨by simp [length_defK, killB_length, takeSt, St.setL]; exact hI.len, ?_, fun j => ?_⟩
        · rw [hP]
          have := wf_take (Pst ext a s) hI.wf d (by rw [Pst_locals_length]; omega) l ob hoP i
            (.ref lw) holdP
          simpa [Pst, hheap, takeSt, pv, AS.counted, St.setL] using this
        · by_cases hj : j = d ∨ j = x
          · rcases hj with hj | hj
            · subst hj
              have hkd : gk (defK (killB x a) j .owned) j = .owned := defK_self _ _ _ hdA
              exact ClAt.of_owned hkd ⟨lw, get_self s _ j _ hdl hs1⟩
            · subst hj
              have hxd : j ≠ d := fun e => hdx e.symm
              have hkx : gk (defK (killB j a) d .owned) j = .unique := by
                rw [hAk, hBk]; simp [hxd, hu]
              refine ClAt.of_unique hkx ⟨l, { ob with fields := ob.fields.set i (.int 0) },
                by rw [get_other s _ d _ hdl hs1 j hxd, hl], ?_, hrc⟩
              show (s.heap.setObj l { ob with fields := ob.fields.set i (.int 0) }).objs l = _
              rw [setObj_objs]; simp
          · exact hF j hj
  · simp at h

theorem counted_defK_unique (a : List AS) (x : Nat) (hx : x < a.length)
    (hc : (gk a x).counted = true) (j : Nat) :
    (gk (defK a x .unique) j).counted = (gk a j).counted := by
  by_cases hj : j = x
  · subst hj; rw [defK_self _ _ _ hx, hc]; rfl
  · exact counted_defK a x .unique hx j hj

/-- state after the shared case of `opMakeUnique` -/
def muSt (s : St) (x l : Nat) (ob : Obj) : St :=
  { s with heap := muHeap s.heap l ob.fields, locals := s.locals.set x (.ref s.heap.next) }

theorem op_makeUnique {x : Nat} (hI : Inv ext a s)
    (h : stepL np a (.makeUnique x) = some a') : OpSafe ext a' (opMakeUnique s x) := by
  simp only [stepL] at h
  split at h
  · rename_i hc
    obtain ⟨hx, hcnt⟩ := hc
    have h' := Option.some.inj h
    subst h'
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hxA : x < a.length := hx
    have hrefx : (gk a x).isRef = true := by
      cases hk : gk a x <;> rw [hk] at hcnt <;> simp_all [AS.counted, AS.isRef]
    obtain ⟨l, hl⟩ := (hI.cl x).ref hrefx
    obtain ⟨ob, hob⟩ : ∃ ob, s.heap.objs l = some ob := by
      have := hI.live hrefx
      rw [hl] at this
      exact this
    have hdef : (killB x a).set x .unique = defK a x .unique := rfl
    rw [hdef]
    by_cases hrc : ob.rc = 1
    · -- already unique: the identity
      have hop : opMakeUnique s x = .ok s := by
        simp [opMakeUnique, hxl, hl, hob, hrc]
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hop] at hh; cases hh
      rw [hop] at hs
      cases hs
      have hP : Pst ext (defK a x .unique) s = Pst ext a s := by
        unfold Pst
        rw [projL_counted_congr _ _ _ (counted_defK_unique a x hx hcnt)]
      refine ⟨by rw [length_defK]; exact hI.len, ?_, fun j => ?_⟩
      · rw [hP]; exact hI.wf
      · by_cases hj : j = x
        · subst hj
          exact ClAt.of_unique (defK_self a _ _ hx) ⟨l, ob, hl, hob, hrc⟩
        · exact cl_frame (T := fun j => j = x) (a' := defK a x .unique) (s' := s) hI.cl
            (fun _ _ => rfl)
            (defK_hk0 a a x _ hx (fun i => Or.inl rfl))
            (defK_hk1 a a x _ hx (fun i => Or.inl rfl))
            (hU_same rfl) (hD_same rfl) j hj
    · -- shared: copy
      have hfl : ob.fields.all s.heap.liveb = true := by
        rw [List.all_eq_true]
        intro v hv
        exact (Heap.liveb_iff _ _).mpr (hI.wf.flds l ob hob v hv)
      have hop : opMakeUnique s x = .ok (muSt s x l ob) := by
        simp [opMakeUnique, hxl, hl, hob, hrc, hfl, muSt, muHeap, Heap.alloc, Heap.bump]
      refine ⟨?_, fun s' hs => ?_⟩
      · intro k hh; rw [hop] at hh; cases hh
      rw [hop] at hs
      cases hs
      have hs1 : (muSt s x l ob).locals = s.locals.set x (.ref s.heap.next) := rfl
      have hheap : (muSt s x l ob).heap = muHeap s.heap l ob.fields := rfl
      have hP := Pst_defK ext a a s (muSt s x l ob) x .unique (.ref s.heap.next) hI.len
        (fun _ => rfl) hxl hs1
      have hxP : (Pst ext a s).get x = .ref l := by
        rw [Pst_get_counted hxl hcnt]; exact hl
      have hlt : l < s.heap.next := hI.wf.lt_next hob
      have hpos : 0 < ob.rc := hI.wf.rcpos l ob hob
      have hspec := muHeap_objs s.heap l ob.fields ob hob hlt hpos
      have hnew := muHeap_new s.heap l ob.fields ob hob hlt hpos
      have hold : ∀ k, s.heap.objs k ≠ none → (muHeap s.heap l ob.fields).objs k ≠ none := by
        intro k hk
        obtain ⟨o', ho'⟩ := Option.ne_none_iff_exists'.mp hk
        have := muHeap_live s.heap l ob.fields (.ref k) ⟨o', ho'⟩
        obtain ⟨o'', ho''⟩ := this
        rw [ho'']; simp
      have hex : ∀ k o', s.heap.objs k = some o' → k ≠ s.heap.next := by
        intro k o' ho' e
        have : k < s.heap.next := hI.wf.lt_next ho'
        omega
      have hkeep : ∀ k o', s.heap.objs k = some o' →
          ∃ o'', (muHeap s.heap l ob.fields).objs k = some o'' ∧ o''.fields = o'.fields ∧
            o''.rc + (if k = l then 1 else 0) = o'.rc + ob.fields.count (.ref k) := by
        intro k o' ho'
        obtain ⟨o'', ho''⟩ := Option.ne_none_iff_exists'.mp (hold k (by rw [ho']; simp))
        rcases hspec k o'' ho'' with ⟨hk, _⟩ | ⟨_, oH, hoH, hf, hr⟩
        · exact absurd hk (hex k o' ho')
        · rw [ho'] at hoH
          cases hoH
          exact ⟨o'', ho'', hf, hr⟩
      refine ⟨by rw [length_defK]; simp [muSt]; exact hI.len, ?_, fun j => ?_⟩
      · rw [hP]
        have := wf_makeUnique (Pst ext a s) hI.wf x (by rw [Pst_locals_length]; omega) l ob hxP
          hob hrc
        simpa [Pst, hheap, muSt, pv, AS.counted] using this
      · by_cases hj : j = x
        · subst hj
          have hkd := defK_self a _ .unique hx
          have hgd := get_self s _ j (.ref s.heap.next) hxl hs1
          exact ClAt.of_unique hkd ⟨s.heap.next, ⟨1, ob.fields⟩, hgd, by
            rw [hheap]; exact hnew, rfl⟩
        · exact cl_frame (T := fun j => j = x) (a' := defK a x .unique) (s' := muSt s x l ob)
            hI.cl (fun i hi => get_other s _ x _ hxl hs1 i hi)
            (defK_hk0 a a x _ hx (fun i => Or.inl rfl))
            (defK_hk1 a a x _ hx (fun i => Or.inl rfl))
            (by
              intro i l' o' hiT hui hui' hl' ho' hrc'
              have hne := (unique_excl hI hui hl' ho' hrc').2.1 x hrefx (fun e => hiT e.symm)
              have hll : l ≠ l' := fun e => hne (by rw [hl, e])
              obtain ⟨o'', ho'', _, hr⟩ := hkeep l' o' ho'
              have hc0 : ob.fields.count (.ref l') = 0 := by
                rw [List.count_eq_zero]
                intro hm
                exact (unique_excl hI hui hl' ho' hrc').2.2.2 l ob hob _ hm rfl
              refine ⟨o'', by rw [hheap]; exact ho'', ?_⟩
              simp [Ne.symm hll] at hr
              omega)
            (by
              intro i r p _ _ _ _ _ hd
              refine desc_mono (fun k o' _ ho' => ?_) hd
              obtain ⟨o'', ho'', hf, _⟩ := hkeep k o' ho'
              exact ⟨o'', by rw [hheap]; exact ho'', hf⟩) j hj
  · simp at h

end Orin
