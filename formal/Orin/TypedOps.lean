import Orin.Typed

/-!
# The type invariant along the straight-line instructions

For every instruction accepted by the ownership rules (`stepA`) and the type pass (`tcheckI`), in
a state related by `Inv` (ownership) and `TInv` (types): the concrete operation is not `ill`, and a
successful result again satisfies `TInv`.
-/

namespace Orin
open Heap

variable {ext : List Val} {np : Nat} {sh : Shapes} {Γ : List Ty} {hty : HTy} {a a1 : AState}
  {s : St}

/-- result shape of every per-instruction lemma -/
def TOp (sh : Shapes) (Γ : List Ty) (hty : HTy) (a1 : AState) (s : St) (r : Res St) : Prop :=
  r ≠ .ill ∧ ∀ s', r = .ok s' → ∃ hty', HyExt hty hty' s.heap s'.heap ∧ TInv sh Γ hty' a1 s'

theorem TOp.ok {r : Res St} {s0 : St} (hop : r = .ok s0)
    (h : ∃ hty', HyExt hty hty' s.heap s0.heap ∧ TInv sh Γ hty' a1 s0) : TOp sh Γ hty a1 s r := by
  subst hop
  refine ⟨(fun e => by cases e), fun s' hs => ?_⟩
  cases hs
  exact h

theorem TOp.trap {r : Res St} (hop : r = .trap) : TOp sh Γ hty a1 s r := by
  subst hop
  exact ⟨(fun e => by cases e), (fun s' hs => by cases hs)⟩

theorem TOp.bad {r : Res St} {k : BadKind} (hop : r = .bad k) : TOp sh Γ hty a1 s r := by
  subst hop
  exact ⟨(fun e => by cases e), (fun s' hs => by cases hs)⟩

theorem noHole2 {hs : List (Nat × Nat)} {d s : Nat} (h : ¬ (hasHole hs d || hasHole hs s) = true) :
    hasHole hs d = false ∧ hasHole hs s = false := by
  simp_all

theorem noHole1 {hs : List (Nat × Nat)} {d : Nat} (h : ¬ hasHole hs d = true) :
    hasHole hs d = false := by
  simpa using h

theorem top_const {d : Nat} {n : Int} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.const d n) = true) (h : stepA np a (.const d n) = some a1) :
    TOp sh Γ hty a1 s (opConst s d n) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hΓ : Γ[d]? = some .int := by simpa [tcheckI] using ht
      have hdl : d < s.locals.length := hI.len ▸ hc.1
      have hop : opConst s d n = .ok (s.setL d (.int n)) := by simp [opConst, hdl]
      refine TOp.ok hop ?_
      exact ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓ ⟨n, rfl⟩ (noHole1 hnh)).abs (fun p hp => hp)
        (KT_defK hc.1 hT.kt (fun _ => hΓ))⟩
  · cases hL

theorem top_move {d x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.move d x) = true) (h : stepA np a (.move d x) = some a1) :
    TOp sh Γ hty a1 s (opMove s d x) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      obtain ⟨hnd, hnx⟩ := noHole2 hnh
      have hΓ : Γ[d]? = Γ[x]? ∧ (Γ[d]?).isSome := by simpa [tcheckI] using ht
      obtain ⟨τ, hτ⟩ : ∃ τ, Γ[d]? = some τ := by
        cases hh : Γ[d]? with
        | none => rw [hh] at hΓ; simp at hΓ
        | some τ => exact ⟨τ, rfl⟩
      have hτx : Γ[x]? = some τ := by rw [← hΓ.1]; exact hτ
      have hdl : d < s.locals.length := hI.len ▸ hc.1
      have hxl : x < s.locals.length := hI.len ▸ hc.2.1
      have hop : opMove s d x = .ok ((s.setL d (s.get x)).setL x (.int 0)) := by
        simp [opMove, hdl, hxl, St.setL]
      refine TOp.ok hop ?_
      refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), ?_⟩
      have h1 := hT.setL hτ (hT.loc x τ hτx) hnd
      have h2 := h1.setL hτx (VT_zero _ _ _) hnx
      refine h2.abs (fun p hp => hp) ?_
      refine KT_defK (by simpa [killK, defK, killB] using hc.1) ?_ (fun e => ?_)
      · exact KT_killK hc.2.1 hT.kt
      · have : (gk a.ls x).counted = true := hc.2.2.2.2
        rw [e] at this
        simp [AS.counted] at this
  · cases hL

theorem some_of_isSome {α : Type} {o : Option α} (h : o.isSome = true) : ∃ x, o = some x := by
  cases o with
  | none => simp at h
  | some x => exact ⟨x, rfl⟩

theorem tchk_copy {d x : Nat} (hΓ : Γ[d]? = Γ[x]? ∧ (Γ[d]?).isSome = true) :
    ∃ τ, Γ[d]? = some τ ∧ Γ[x]? = some τ := by
  obtain ⟨τ, hτ⟩ := some_of_isSome hΓ.2
  exact ⟨τ, hτ, hΓ.1 ▸ hτ⟩

theorem top_borrow {d x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.borrow d x) = true) (h : stepA np a (.borrow d x) = some a1) :
    TOp sh Γ hty a1 s (opBorrow s d x) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      obtain ⟨hnd, hnx⟩ := noHole2 hnh
      obtain ⟨τ, hτ, hτx⟩ := tchk_copy (by simpa [tcheckI] using ht)
      have hdl : d < s.locals.length := hI.len ▸ hc.1
      have hxl : x < s.locals.length := hI.len ▸ hc.2.1
      have hop : opBorrow s d x = .ok (s.setL d (s.get x)) := by simp [opBorrow, hdl, hxl]
      refine TOp.ok hop ?_
      refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hτ (hT.loc x τ hτx) hnd).abs (fun p hp => hp) ?_⟩
      exact KT_defK (by rw [length_demote]; exact hc.1) (KT_demote hc.2.1 hT.kt) (fun e => by cases e)
  · cases hL

theorem top_dup {d x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.dup d x) = true) (h : stepA np a (.dup d x) = some a1) :
    TOp sh Γ hty a1 s (opCopy s d x) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      obtain ⟨hnd, hnx⟩ := noHole2 hnh
      obtain ⟨τ, hτ, hτx⟩ := tchk_copy (by simpa [tcheckI] using ht)
      have hdl : d < s.locals.length := hI.len ▸ hc.1
      have hxl : x < s.locals.length := hI.len ▸ hc.2.1
      by_cases hl : s.heap.liveb (s.get x) = true
      · have hop : opCopy s d x = .ok { s.setL d (s.get x) with heap := s.heap.bump [s.get x] } := by
          simp [opCopy, hdl, hxl, hl]
        refine TOp.ok hop ?_
        refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), ?_⟩
        have h1 := hT.setL hτ (hT.loc x τ hτx) hnd
        have h2 : TInv sh Γ hty a { s.setL d (s.get x) with heap := s.heap.bump [s.get x] } := by
          refine h1.heap rfl ⟨rfl, fun l o' ho' => ?_⟩
          obtain ⟨o, ho, rfl⟩ := Heap.bump_inv _ _ _ _ ho'
          exact ⟨o, ho, rfl⟩
        refine h2.abs (fun p hp => hp) ?_
        exact KT_defK (by rw [length_demote]; exact hc.1) (KT_demote hc.2.1 hT.kt) (fun e => by cases e)
      · have hop : opCopy s d x = .bad .dead := by simp [opCopy, hdl, hxl, hl]
        exact TOp.bad hop
  · cases hL

theorem top_release {x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.release x) = true) (h : stepA np a (.release x) = some a1) :
    TOp sh Γ hty a1 s (opRelease s x) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hxG : x < Γ.length := by simpa [tcheckI] using ht
      obtain ⟨τ, hτ⟩ : ∃ τ, Γ[x]? = some τ := ⟨Γ[x], List.getElem?_eq_getElem hxG⟩
      have hxl : x < s.locals.length := hI.len ▸ hc.1
      have hop : opRelease s x = .ok { s.setL x (.int 0) with pending := s.get x :: s.pending } := by
        simp [opRelease, hxl, St.setL]
      refine TOp.ok hop ?_
      refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), ?_⟩
      have h1 := hT.setL hτ (VT_zero _ _ _) (noHole1 hnh)
      have h2 := TInv.abs (a1 := ⟨killK a.ls x, a.holes⟩) h1 (fun p hp => hp) (KT_killK hc.1 hT.kt)
      exact h2.same rfl rfl
  · cases hL

/-! ### objects behind typed locals -/

/-- a readable struct local points to a live struct object with the declared slots -/
theorem loc_obj (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) {o t lo : Nat}
    (hr : (gk a.ls o).isRef = true) (hΓ : Γ[o]? = some (.st t)) (hg : s.get o = .ref lo) :
    ∃ ob ts, s.heap.objs lo = some ob ∧ hty lo = some (.st t) ∧ sh[t]? = some ts ∧
      AllT hty s.heap ts ob.fields := by
  have hlive := hI.live hr
  rw [hg] at hlive
  obtain ⟨ob, hob⟩ := hlive
  have hv := hT.loc o (.st t) hΓ
  rw [hg] at hv
  simp only [VT] at hv
  rcases hv with hv | ⟨l, hl, hty', _⟩
  · cases hv
  · have hll : l = lo := by injection hl with h; exact h.symm
    subst hll
    obtain ⟨τ, hτ, hok⟩ := hT.obj l ob hob
    rw [hty'] at hτ
    cases hτ
    obtain ⟨ts, hts, hA⟩ := hok
    exact ⟨ob, ts, hob, hty', hts, hA⟩

/-- a readable array local points to a live array object of scalars -/
theorem loc_arr (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) {o lo : Nat}
    (hr : (gk a.ls o).isRef = true) (hΓ : Γ[o]? = some .arr) (hg : s.get o = .ref lo) :
    ∃ ob, s.heap.objs lo = some ob ∧ hty lo = some .arr ∧ ∀ v ∈ ob.fields, ∃ n, v = .int n := by
  have hlive := hI.live hr
  rw [hg] at hlive
  obtain ⟨ob, hob⟩ := hlive
  have hv := hT.loc o .arr hΓ
  rw [hg] at hv
  simp only [VT] at hv
  rcases hv with hv | ⟨l, hl, hty', _⟩
  · cases hv
  · have hll : l = lo := by injection hl with h; exact h.symm
    subst hll
    obtain ⟨τ, hτ, hok⟩ := hT.obj l ob hob
    rw [hty'] at hτ
    cases hτ
    exact ⟨ob, hob, hty', hok⟩

/-- A slot of reference type that is not an open hole is not null: the owner of the hole would be
`Unique`, and nothing else (in particular not the reader) can hold that object. -/
theorem slot_nonnull (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    {o t lo i : Nat} {ob : Obj} {ts : List Ty} {τ' : Ty}
    (hr : (gk a.ls o).isRef = true) (hg : s.get o = .ref lo)
    (hob : s.heap.objs lo = some ob) (hty' : hty lo = some (.st t)) (hts : sh[t]? = some ts)
    (hi : ts[i]? = some τ') (hne : τ' ≠ .int) (hnh : (o, i) ∉ a.holes) :
    ob.fields[i]? ≠ some (.int 0) := by
  intro h0
  obtain ⟨y, hy, hgy⟩ := hT.hole lo ob t ts i hob hty' hts ⟨τ', hi, hne⟩ h0
  have huy : gk a.ls y = .unique := hu (y, i) hy
  obtain ⟨l', o', hl', ho', hrc⟩ := (hI.cl y).uniq huy
  rw [hgy] at hl'
  have hl'' : lo = l' := by injection hl'
  subst hl''
  rw [hob] at ho'
  have hoo : ob = o' := Option.some.inj ho'
  subst hoo
  have hex := (unique_excl hI huy hgy hob hrc).2.1 o hr
  by_cases hoy : o = y
  · subst hoy; exact hnh hy
  · exact hex hoy hg

/-- unpack the type pass for a field access -/
theorem tchk_get {d o i : Nat} {r : Bool}
    (ht : tcheckI sh Γ (.getField d o i r) = true) :
    ∃ t ts τ', Γ[o]? = some (.st t) ∧ sh[t]? = some ts ∧ ts[i]? = some τ' ∧ Γ[d]? = some τ' ∧
      r = decide (τ' ≠ .int) := by
  simp only [tcheckI] at ht
  cases ho : Γ[o]? with
  | none => rw [ho] at ht; simp at ht
  | some τo =>
    rw [ho] at ht
    cases τo with
    | st t =>
      simp only at ht
      cases hs : sh[t]? with
      | none => rw [hs] at ht; simp at ht
      | some ts =>
        rw [hs] at ht
        simp only [decide_eq_true_eq] at ht
        obtain ⟨h1, h2, h3⟩ := ht
        obtain ⟨τ', hτ'⟩ := some_of_isSome h2
        refine ⟨t, ts, τ', rfl, hs, by rw [h1]; exact hτ', hτ', ?_⟩
        rw [hτ'] at h3
        simpa using h3
    | int => simp at ht
    | arr => simp at ht

theorem top_getField {d o i : Nat} {r : Bool} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (hu : HU a) (ht : tcheckI sh Γ (.getField d o i r) = true)
    (h : stepA np a (.getField d o i r) = some a1) :
    TOp sh Γ hty a1 s (opGetField s d o i r) := by
  obtain ⟨t, ts, τ', hΓo, hts, hi, hΓd, hr⟩ := tchk_get ht
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepH] at hH
  split at hH
  · cases hH
  · rename_i hnh
    cases hH
    have hnd : hasHole a.holes d = false := by
      cases hh : hasHole a.holes d <;> simp_all
    have hnoi : (o, i) ∉ a.holes := by
      intro hm; apply hnh; simp [hm]
    have hL' := hL
    simp only [stepL] at hL'
    unfold stepGet at hL'
    split at hL'
    · rename_i hc
      obtain ⟨hd, ho, _, hrefo⟩ := hc
      have hdl : d < s.locals.length := hI.len ▸ hd
      have hol : o < s.locals.length := hI.len ▸ ho
      obtain ⟨lo, hlo⟩ := (hI.cl o).ref hrefo
      obtain ⟨ob, ts', hob, hlty, hts', hA⟩ := loc_obj hI hT hrefo hΓo hlo
      rw [hts] at hts'
      cases hts'
      obtain ⟨w, hw, hvw⟩ := AllT_get hA hi
      by_cases hint : τ' = .int
      · subst hint
        simp at hr
        subst hr
        simp only [VT] at hvw
        obtain ⟨n, rfl⟩ := hvw
        have hop : opGetField s d o i false = .ok (s.setL d (.int n)) := by
          simp [opGetField, opGetFieldE, hdl, hol, hlo, hob, hw]
        refine TOp.ok hop ?_
        rw [if_neg Bool.false_ne_true] at hL'
        cases hL'
        refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓd ⟨n, rfl⟩ hnd).abs (fun p hp => hp) ?_⟩
        exact KT_defK hd hT.kt (fun _ => hΓd)
      · simp [hint] at hr
        subst hr
        have hnn := slot_nonnull hI hT hu hrefo hlo hob hlty hts hi hint hnoi
        have hvw' := hvw
        cases τ' with
        | int => exact absurd rfl hint
        | st t' =>
          simp only [VT] at hvw'
          rcases hvw' with e | ⟨m, hm, hm1, hm2⟩
          · exact absurd (by rw [hw, e]) hnn
          · subst hm
            have hop : opGetField s d o i true = .ok (s.setL d (.ref m)) := by
              simp [opGetField, opGetFieldE, hdl, hol, hlo, hob, hw]
            refine TOp.ok hop ?_
            simp only [ite_true] at hL'
            split at hL'
            · cases hL'
              refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓd (by simp only [VT]; exact Or.inr ⟨m, rfl, hm1, hm2⟩) hnd).abs
                (fun p hp => hp) ?_⟩
              exact KT_defK hd hT.kt (fun e => by cases e)
            · cases hL'
        | arr =>
          simp only [VT] at hvw'
          rcases hvw' with e | ⟨m, hm, hm1, hm2⟩
          · exact absurd (by rw [hw, e]) hnn
          · subst hm
            have hop : opGetField s d o i true = .ok (s.setL d (.ref m)) := by
              simp [opGetField, opGetFieldE, hdl, hol, hlo, hob, hw]
            refine TOp.ok hop ?_
            simp only [ite_true] at hL'
            split at hL'
            · cases hL'
              refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓd (by simp only [VT]; exact Or.inr ⟨m, rfl, hm1, hm2⟩) hnd).abs
                (fun p hp => hp) ?_⟩
              exact KT_defK hd hT.kt (fun e => by cases e)
            · cases hL'
    · cases hL'

/-! ### fresh objects -/

theorem alloc_grow_facts (H : Heap) (fs : List Val) :
    (H.alloc fs).1.next = H.next + 1 ∧
    (∃ o0, (H.alloc fs).1.objs H.next = some o0 ∧ o0.fields = fs) ∧
    (∀ k o', k ≠ H.next → (H.alloc fs).1.objs k = some o' →
      ∃ o, H.objs k = some o ∧ o'.fields = o.fields) := by
  refine ⟨rfl, ⟨⟨1, fs⟩, by simp [Heap.alloc], rfl⟩, fun k o' hk ho' => ⟨o', ?_, rfl⟩⟩
  rw [← alloc_objs_old H fs k hk]; exact ho'

theorem tchk_alloc {d n : Nat} (ht : tcheckI sh Γ (.alloc d n) = true) :
    ∃ t ts, Γ[d]? = some (.st t) ∧ sh[t]? = some ts ∧ ts.length = n := by
  simp only [tcheckI] at ht
  cases hd : Γ[d]? with
  | none => rw [hd] at ht; simp at ht
  | some τ =>
    rw [hd] at ht
    cases τ with
    | st t =>
      simp only [decide_eq_true_eq] at ht
      cases hs : sh[t]? with
      | none => rw [hs] at ht; simp at ht
      | some ts =>
        rw [hs] at ht
        exact ⟨t, ts, rfl, hs, by simpa using ht⟩
    | int => simp at ht
    | arr => simp at ht

theorem top_alloc {d n : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.alloc d n) = true) (h : stepA np a (.alloc d n) = some a1) :
    TOp sh Γ hty a1 s (opAllocN s d n) := by
  obtain ⟨t, ts, hΓ, hts, hlen⟩ := tchk_alloc ht
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL, stepAlloc] at hL
  split at hL
  · rename_i hc
    cases hL
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hnd := noHole1 hnh
      have hdl : d < s.locals.length := hI.len ▸ hc.1
      have hop : opAllocN s d n = .ok (allocSt s d n) := by simp [opAllocN, allocSt, hdl]
      refine TOp.ok hop ?_
      unfold allocSt
      obtain ⟨hn, hnew, hold⟩ := alloc_grow_facts s.heap (List.replicate n (.int 0))
      have hfok : FOK sh hty s.heap (.st t) (List.replicate n (.int 0)) :=
        ⟨ts, hts, by rw [← hlen]; exact AllT_replicate hty s.heap ts⟩
      have hG := hT.tlo.grow (d := d) hn hnew hold hΓ (by intro e; cases e) hfok
      refine ⟨extHty hty s.heap.next (.st t), ⟨fun l hl => by simp [extHty, Nat.ne_of_lt hl], by rw [hn]; omega⟩, hG.loc, hG.obj, ?_, ?_⟩
      · intro l o t' ts' i ho ht' hts' hτ hf
        by_cases hl : l = s.heap.next
        · subst hl
          obtain ⟨o0, ho0, hf0⟩ := hnew
          rw [ho0] at ho
          cases ho
          simp [extHty] at ht'
          subst ht'
          rw [hts] at hts'
          cases hts'
          obtain ⟨τ', hi, _⟩ := hτ
          have hi' : i < ts.length := (List.getElem?_eq_some_iff.mp hi).1
          refine ⟨d, ?_, ?_⟩
          · apply List.mem_append_right
            apply List.mem_map.mpr
            exact ⟨i, List.mem_range.mpr (by omega), rfl⟩
          · simp [St.get, List.getD_eq_getElem?_getD, hdl]
        · obtain ⟨o', ho', hf'⟩ := hold l o hl ho
          have ht2 : hty l = some (.st t') := by simpa [extHty, hl] using ht'
          obtain ⟨x, hx, hg⟩ := hT.hole l o' t' ts' i ho' ht2 hts' hτ (by rw [← hf']; exact hf)
          have hxd : x ≠ d := by
            intro e; subst e
            have := (hasHole_iff a.holes x).mpr ⟨i, hx⟩
            rw [hnd] at this; cases this
          refine ⟨x, List.mem_append_left _ hx, ?_⟩
          simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, hxd, Ne.symm hxd] at hg ⊢
          exact hg
      · exact KT_defK hc.1 hT.kt (fun e => by cases e)
  · cases hL

theorem top_arrayNew {d nl : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.arrayNew d nl) = true) (h : stepA np a (.arrayNew d nl) = some a1) :
    TOp sh Γ hty a1 s (opArrayNew s d nl) := by
  have hΓ : Γ[d]? = some .arr ∧ Γ[nl]? = some .int := by simpa [tcheckI] using ht
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    obtain ⟨hnl, hinit⟩ := hc
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hnd := noHole1 hnh
      simp only [stepAlloc] at hL
      split at hL
      · rename_i hc2
        cases hL
        have hdl : d < s.locals.length := hI.len ▸ hc2.1
        have hnll : nl < s.locals.length := hI.len ▸ hnl
        obtain ⟨n, hn⟩ := (hI.cl nl).ini hinit
        by_cases h0 : 0 ≤ n
        · have hop : opArrayNew s d nl = opAllocN s d n.toNat := by
            simp [opArrayNew, hnll, hn, h0]
          rw [hop]
          have hop2 : opAllocN s d n.toNat = .ok (allocSt s d n.toNat) := by
            simp [opAllocN, allocSt, hdl]
          refine TOp.ok hop2 ?_
          unfold allocSt
          obtain ⟨hn', hnew, hold⟩ := alloc_grow_facts s.heap (List.replicate n.toNat (.int 0))
          have hfok : FOK sh hty s.heap .arr (List.replicate n.toNat (.int 0)) := by
            intro v hv
            have := List.eq_of_mem_replicate hv
            exact ⟨0, this⟩
          have hG := hT.tlo.grow (d := d) hn' hnew hold hΓ.1 (by intro e; cases e) hfok
          refine ⟨extHty hty s.heap.next .arr, ⟨fun l hl => by simp [extHty, Nat.ne_of_lt hl], by rw [hn']; omega⟩, hG.loc, hG.obj, ?_, ?_⟩
          · intro l o t' ts' i ho ht' hts' hτ hf
            by_cases hl : l = s.heap.next
            · subst hl
              simp [extHty] at ht'
            · obtain ⟨o', ho', hf'⟩ := hold l o hl ho
              have ht2 : hty l = some (.st t') := by simpa [extHty, hl] using ht'
              obtain ⟨x, hx, hg⟩ := hT.hole l o' t' ts' i ho' ht2 hts' hτ (by rw [← hf']; exact hf)
              have hxd : x ≠ d := by
                intro e; subst e
                have := (hasHole_iff a.holes x).mpr ⟨i, hx⟩
                rw [hnd] at this; cases this
              refine ⟨x, hx, ?_⟩
              simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, hxd, Ne.symm hxd] at hg ⊢
              exact hg
          · exact KT_defK hc2.1 hT.kt (fun e => by cases e)
        · have hop : opArrayNew s d nl = .trap := by simp [opArrayNew, hnll, hn, h0, hdl]
          exact TOp.trap hop
      · cases hL
  · cases hL

/-! ### arrays -/

theorem top_arrayLen {d x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.arrayLen d x) = true) (h : stepA np a (.arrayLen d x) = some a1) :
    TOp sh Γ hty a1 s (opArrayLen s d x) := by
  have hΓ : Γ[x]? = some .arr ∧ Γ[d]? = some .int := by simpa [tcheckI] using ht
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    obtain ⟨hd, hx, _, hrefx⟩ := hc
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      obtain ⟨hnd, hnx⟩ := noHole2 hnh
      have hdl : d < s.locals.length := hI.len ▸ hd
      have hxl : x < s.locals.length := hI.len ▸ hx
      obtain ⟨lo, hlo⟩ := (hI.cl x).ref hrefx
      cases hob : s.heap.objs lo with
      | none =>
        have hop : opArrayLen s d x = .bad .dead := by simp [opArrayLen, hdl, hxl, hlo, hob]
        exact TOp.bad hop
      | some ob =>
        have hop : opArrayLen s d x = .ok (s.setL d (.int (ob.fields.length : Int))) := by
          simp [opArrayLen, hdl, hxl, hlo, hob]
        refine TOp.ok hop ?_
        exact ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓ.2 ⟨_, rfl⟩ hnd).abs (fun p hp => hp)
          (KT_defK hd hT.kt (fun _ => hΓ.2))⟩
  · cases hL

theorem top_arrayGet {d x i : Nat} {r : Bool} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.arrayGet d x i r) = true) (h : stepA np a (.arrayGet d x i r) = some a1) :
    TOp sh Γ hty a1 s (opArrayGet s d x i r) := by
  have hΓ : Γ[x]? = some .arr ∧ Γ[i]? = some .int ∧ Γ[d]? = some .int ∧ r = false := by
    simpa [tcheckI] using ht
  obtain ⟨hΓx, hΓi, hΓd, hr⟩ := hΓ
  subst hr
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    obtain ⟨hi, hinit⟩ := hc
    unfold stepGet at hL
    split at hL
    · rename_i hc2
      obtain ⟨hd, hx, _, hrefx⟩ := hc2
      rw [if_neg Bool.false_ne_true] at hL
      cases hL
      simp only [stepH] at hH
      split at hH
      · cases hH
      · rename_i hnh
        cases hH
        obtain ⟨hnd, hnx⟩ := noHole2 hnh
        have hdl : d < s.locals.length := hI.len ▸ hd
        have hxl : x < s.locals.length := hI.len ▸ hx
        have hil : i < s.locals.length := hI.len ▸ hi
        obtain ⟨n, hn⟩ := (hI.cl i).ini hinit
        obtain ⟨lo, hlo⟩ := (hI.cl x).ref hrefx
        have hkt : KT Γ (defK a.ls d .init) := KT_defK hd hT.kt (fun _ => hΓd)
        cases hob : s.heap.objs lo with
        | none =>
          by_cases h0 : 0 ≤ n
          · have hop : opArrayGet s d x i false = .bad .dead := by
              simp [opArrayGet, hil, hn, h0, opGetFieldE, hdl, hxl, hlo, hob]
            exact TOp.bad hop
          · have hop : opArrayGet s d x i false = .bad .dead := by
              simp [opArrayGet, hil, hn, h0, hdl, hxl, hlo, hob]
            exact TOp.bad hop
        | some ob =>
          obtain ⟨ob', hob', hty', hints⟩ := loc_arr hI hT hrefx hΓx hlo
          rw [hob] at hob'
          cases hob'
          by_cases h0 : 0 ≤ n
          · cases hw : ob.fields[n.toNat]? with
            | none =>
              have hop : opArrayGet s d x i false = .trap := by
                simp [opArrayGet, hil, hn, h0, opGetFieldE, hdl, hxl, hlo, hob, hw]
              exact TOp.trap hop
            | some w =>
              obtain ⟨m, rfl⟩ := hints w (List.mem_of_getElem? hw)
              have hop : opArrayGet s d x i false = .ok (s.setL d (.int m)) := by
                simp [opArrayGet, hil, hn, h0, opGetFieldE, hdl, hxl, hlo, hob, hw]
              refine TOp.ok hop ?_
              exact ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), (hT.setL hΓd ⟨m, rfl⟩ hnd).abs (fun p hp => hp) hkt⟩
          · have hop : opArrayGet s d x i false = .trap := by
              simp [opArrayGet, hil, hn, h0, hdl, hxl, hlo, hob]
            exact TOp.trap hop
    · cases hL
  · cases hL

/-! ### stores -/

/-- nothing but the owner reaches the object behind an open hole -/
theorem hole_owner_unique (hI : Inv ext a.ls s) (hu : HU a) {y i l j : Nat}
    (hy : (y, i) ∈ a.holes) (hgy : s.get y = .ref l) (hj : (gk a.ls j).isRef = true)
    (hgj : s.get j = .ref l) : j = y := by
  have huy : gk a.ls y = .unique := hu (y, i) hy
  obtain ⟨l', o', hl', ho', hrc⟩ := (hI.cl y).uniq huy
  rw [hgy] at hl'
  have hl'' : l = l' := by injection hl'
  subst hl''
  by_cases hne : j = y
  · exact hne
  · exact absurd hgj ((unique_excl hI huy hgy ho' hrc).2.1 j hj hne)

theorem TInv.clr {sh : Shapes} {Γ : List Ty} {hty : HTy} {a : AState} {s : St}
    (hT : TInv sh Γ hty a s) {v : Nat} {τ : Ty} (hτ : Γ[v]? = some τ)
    (hh : hasHole a.holes v = false) : TInv sh Γ hty a (s.clr v) := by
  unfold St.clr
  cases hg : s.get v with
  | int n => exact hT
  | ref l => exact hT.setL hτ (VT_zero _ _ _) hh

theorem tchk_store {x i v : Nat} (ht : tcheckI sh Γ (.setField x i v) = true) :
    ∃ t ts τ', Γ[x]? = some (.st t) ∧ sh[t]? = some ts ∧ ts[i]? = some τ' ∧ Γ[v]? = some τ' := by
  simp only [tcheckI] at ht
  cases hx : Γ[x]? with
  | none => rw [hx] at ht; simp at ht
  | some τ =>
    rw [hx] at ht
    cases τ with
    | st t =>
      simp only at ht
      cases hs : sh[t]? with
      | none => rw [hs] at ht; simp at ht
      | some ts =>
        rw [hs] at ht
        simp only [decide_eq_true_eq] at ht
        obtain ⟨h1, h2⟩ := ht
        obtain ⟨τ', hτ'⟩ := some_of_isSome h2
        exact ⟨t, ts, τ', rfl, hs, by rw [h1]; exact hτ', hτ'⟩
    | int => simp at ht
    | arr => simp at ht

theorem tchk_store_put {x i v : Nat} (ht : tcheckI sh Γ (.putField x i v) = true) :
    ∃ t ts τ', Γ[x]? = some (.st t) ∧ sh[t]? = some ts ∧ ts[i]? = some τ' ∧ Γ[v]? = some τ' :=
  tchk_store (i := i) (by simpa [tcheckI] using ht)

/-- shared core of `setField` / `putField`: the concrete store -/
theorem store_core {x i v : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (hset : stepSet a.ls x v = some a1.ls) (hnv : hasHole a.holes v = false)
    (hkeep : ∀ p ∈ a.holes, p ≠ (x, i) → p ∈ a1.holes)
    (hsh : ∃ t ts τ', Γ[x]? = some (.st t) ∧ sh[t]? = some ts ∧ ts[i]? = some τ' ∧
      Γ[v]? = some τ') (hkt : KT Γ a1.ls) :
    TOp sh Γ hty a1 s (opSetField s x i v) := by
  obtain ⟨t, ts, τ', hΓx, hts, hi, hΓv⟩ := hsh
  have hset' := hset
  unfold stepSet at hset'
  split at hset'
  · rename_i hc
    obtain ⟨hx, hxv, hux⟩ := hc
    obtain ⟨a2', h2, h2e⟩ := Option.map_eq_some_iff.mp hset'
    obtain ⟨hvA, hcons⟩ := consume_spec h2
    have hxl : x < s.locals.length := hI.len ▸ hx
    have hvl : v < s.locals.length := hI.len ▸ hvA
    obtain ⟨l, ob, hl, hob, hrc⟩ := (hI.cl x).uniq hux
    have hrefx : (gk a.ls x).isRef = true := by rw [hux]; rfl
    obtain ⟨ob', ts', hob', hlty, hts', hA⟩ := loc_obj hI hT hrefx hΓx hl
    rw [hob] at hob'
    cases hob'
    rw [hts] at hts'
    cases hts'
    obtain ⟨old, hold, hvold⟩ := AllT_get hA hi
    have hop : opSetField s x i v = .ok (setSt s l ob i v old) := by
      simp [opSetField, opSetFieldE, hxl, hvl, hl, hob, hrc, hold, setSt]
    refine TOp.ok hop ?_
    -- the stored value
    have hvv := hT.loc v τ' hΓv
    have h0 := hT.clr hΓv hnv
    -- `v` is not null if the slot type is a reference type
    have hnn : τ' ≠ .int → s.get v ≠ .int 0 := by
      intro hne he
      rcases hcons with ⟨hini, _⟩ | ⟨hcnt, _⟩
      · have := hT.kt v hini
        rw [hΓv] at this
        exact hne (Option.some.inj this)
      · have hrefv : (gk a.ls v).isRef = true := by
          cases hk : gk a.ls v <;> rw [hk] at hcnt <;> simp_all [AS.counted, AS.isRef]
        obtain ⟨lv, hlv⟩ := (hI.cl v).ref hrefv
        rw [hlv] at he; cases he
    have hheap : (setSt s l ob i v old).heap =
        s.heap.setObj l { ob with fields := ob.fields.set i (s.get v) } := rfl
    have hat : (setSt s l ob i v old).heap.objs l = some { ob with fields := ob.fields.set i (s.get v) } := by
      rw [hheap, Heap.setObj_objs]; simp
    have hother : ∀ k, k ≠ l → (setSt s l ob i v old).heap.objs k = s.heap.objs k := by
      intro k hk; rw [hheap, Heap.setObj_objs]; simp [hk]
    have hclr : (s.clr v).heap = s.heap := by
      unfold St.clr; cases s.get v <;> rfl
    have hlo : TLO sh Γ hty (setSt s l ob i v old) := by
      refine (h0.tlo).upd (l := l) (τl := .st t) (nf := ob.fields.set i (s.get v))
        hlty (by rw [hclr]; rfl) rfl ⟨_, hat, rfl⟩ ?_ ⟨ts, hts, by rw [hclr]; exact AllT_set hA hi hvv⟩
      intro k o' hk ho'
      refine ⟨o', ?_, rfl⟩
      rw [hother k hk] at ho'
      rw [hclr]; exact ho'
    refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), hlo.loc, hlo.obj, ?_, hkt⟩
    intro l' o' t' ts'' i' ho' ht' hts'' hτ hf
    have hgv : ∀ x', (x', i') ∈ a.holes → x' ≠ v := by
      intro x' hx' e; subst e
      have := (hasHole_iff a.holes x').mpr ⟨i', hx'⟩
      rw [hnv] at this; cases this
    have hgetc : ∀ x', x' ≠ v → (setSt s l ob i v old).get x' = s.get x' := by
      intro x' hx'
      exact clr_get_ne s v x' hx'
    by_cases hll : l' = l
    · subst hll
      rw [hat] at ho'
      cases ho'
      have ht2 : t' = t := by
        rw [hlty] at ht'; injection ht' with h; injection h with h; exact h.symm
      subst ht2
      rw [hts] at hts''
      cases hts''
      by_cases hii : i' = i
      · subst hii
        exfalso
        obtain ⟨τ'', hτ'', hne⟩ := hτ
        rw [hi] at hτ''
        cases hτ''
        have hlen : i' < ob.fields.length := by
          rw [AllT_length hA]; exact (List.getElem?_eq_some_iff.mp hi).1
        simp [List.getElem?_set, hlen] at hf
        exact hnn hne hf
      · have hii' : ¬ i = i' := fun e => hii e.symm
        simp [List.getElem?_set, hii'] at hf
        obtain ⟨x', hx', hgx'⟩ := hT.hole l' ob t' ts i' hob hlty hts hτ hf
        refine ⟨x', hkeep _ hx' (fun e => hii (by injection e)), ?_⟩
        rw [hgetc x' (hgv x' hx')]; exact hgx'
    · rw [hother l' hll] at ho'
      obtain ⟨x', hx', hgx'⟩ := hT.hole l' o' t' ts'' i' ho' ht' hts'' hτ hf
      have hne : (x', i') ≠ (x, i) := by
        intro e
        have hx'x : x' = x := by injection e
        subst hx'x
        rw [hl] at hgx'
        injection hgx' with h
        exact hll h.symm
      refine ⟨x', hkeep _ hx' hne, ?_⟩
      rw [hgetc x' (hgv x' hx')]; exact hgx'
  · simp at hset'

theorem KT_stepSet {a : List AS} {x v : Nat} {a1 : List AS} (hk : KT Γ a)
    (h : stepSet a x v = some a1) : KT Γ a1 := by
  unfold stepSet at h
  split at h
  · obtain ⟨a2, h2, rfl⟩ := Option.map_eq_some_iff.mp h
    obtain ⟨hv, hc⟩ := consume_spec h2
    apply KT_killB
    rcases hc with ⟨_, rfl⟩ | ⟨_, rfl⟩
    · exact hk
    · exact KT_killK hv hk
  · cases h

theorem top_setField {x i v : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcheckI sh Γ (.setField x i v) = true) (h : stepA np a (.setField x i v) = some a1) :
    TOp sh Γ hty a1 s (opSetField s x i v) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  simp only [stepH] at hH
  split at hH
  · cases hH
  · rename_i hnh
    cases hH
    have hnv : hasHole a.holes v = false := by
      cases hh : hasHole a.holes v <;> simp_all
    exact store_core hI hT hu hL hnv (fun p hp _ => hp) (tchk_store ht) (KT_stepSet hT.kt hL)

theorem top_putField {x i v : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcheckI sh Γ (.putField x i v) = true) (h : stepA np a (.putField x i v) = some a1) :
    TOp sh Γ hty a1 s (opSetField s x i v) := by
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  simp only [stepH] at hH
  split at hH
  · cases hH
  · rename_i hnh
    cases hH
    have hnv : hasHole a.holes v = false := by
      cases hh : hasHole a.holes v <;> simp_all
    exact store_core hI hT hu hL hnv
      (fun p hp hne => List.mem_filter.mpr ⟨hp, by simp [hne]⟩) (tchk_store_put ht)
      (KT_stepSet hT.kt hL)

theorem top_arraySet {x i v : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s)
    (ht : tcheckI sh Γ (.arraySet x i v) = true) (h : stepA np a (.arraySet x i v) = some a1) :
    TOp sh Γ hty a1 s (opArraySet s x i v) := by
  have hΓ : Γ[x]? = some .arr ∧ Γ[i]? = some .int ∧ Γ[v]? = some .int := by
    simpa [tcheckI] using ht
  obtain ⟨hΓx, hΓi, hΓv⟩ := hΓ
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    obtain ⟨hi, hinit⟩ := hc
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hset := hL
      unfold stepSet at hL
      split at hL
      · rename_i hc2
        obtain ⟨hx, hxv, hux⟩ := hc2
        obtain ⟨a2', h2, h2e⟩ := Option.map_eq_some_iff.mp hL
        obtain ⟨hvA, hcons⟩ := consume_spec h2
        have hil : i < s.locals.length := hI.len ▸ hi
        have hxl : x < s.locals.length := hI.len ▸ hx
        have hvl : v < s.locals.length := hI.len ▸ hvA
        obtain ⟨n, hn⟩ := (hI.cl i).ini hinit
        obtain ⟨l, ob, hl, hob, hrc⟩ := (hI.cl x).uniq hux
        have hrefx : (gk a.ls x).isRef = true := by rw [hux]; rfl
        by_cases h0 : 0 ≤ n
        · have hop0 : opArraySet s x i v = opSetFieldE .trap s x n.toNat v := by
            simp [opArraySet, hil, hn, h0]
          rw [hop0]
          cases hold : ob.fields[n.toNat]? with
          | none =>
            have hop : opSetFieldE .trap s x n.toNat v = .trap := by
              simp [opSetFieldE, hxl, hvl, hl, hob, hrc, hold]
            exact TOp.trap hop
          | some old =>
            have hop : opSetFieldE .trap s x n.toNat v = .ok (setSt s l ob n.toNat v old) := by
              simp [opSetFieldE, hxl, hvl, hl, hob, hrc, hold, setSt]
            refine TOp.ok hop ?_
            obtain ⟨ob', hob', hlty, hints⟩ := loc_arr hI hT hrefx hΓx hl
            rw [hob] at hob'
            cases hob'
            have hvv := hT.loc v .int hΓv
            obtain ⟨m, hm⟩ := hvv
            have hclr : s.clr v = s := clr_int s v m hm
            have hheap : (setSt s l ob n.toNat v old).heap =
                s.heap.setObj l { ob with fields := ob.fields.set n.toNat (s.get v) } := by
              simp [setSt, hclr]
            have hat : (setSt s l ob n.toNat v old).heap.objs l =
                some { ob with fields := ob.fields.set n.toNat (s.get v) } := by
              rw [hheap, Heap.setObj_objs]; simp
            have hother : ∀ k, k ≠ l → (setSt s l ob n.toNat v old).heap.objs k = s.heap.objs k := by
              intro k hk; rw [hheap, Heap.setObj_objs]; simp [hk]
            have hlo : TLO sh Γ hty (setSt s l ob n.toNat v old) := by
              refine hT.tlo.upd (l := l) (τl := .arr) (nf := ob.fields.set n.toNat (s.get v))
                hlty (by rw [hheap]; rfl) (by simp [setSt, hclr]) ⟨_, hat, rfl⟩ ?_ ?_
              · intro k o' hk ho'
                exact ⟨o', by rw [hother k hk] at ho'; exact ho', rfl⟩
              · intro w hw
                rcases List.mem_or_eq_of_mem_set hw with h1 | h1
                · exact hints w h1
                · exact ⟨m, by rw [h1, hm]⟩
            refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), hlo.loc, hlo.obj, ?_, KT_stepSet hT.kt hset⟩
            intro l' o' t' ts'' i' ho' ht' hts'' hτ hf
            have hll : l' ≠ l := by
              intro e; subst e; rw [hlty] at ht'; cases ht'
            rw [hother l' hll] at ho'
            obtain ⟨x', hx', hgx'⟩ := hT.hole l' o' t' ts'' i' ho' ht' hts'' hτ hf
            refine ⟨x', hx', ?_⟩
            have : (setSt s l ob n.toNat v old).get x' = s.get x' := by
              show (s.clr v).get x' = s.get x'
              rw [hclr]
            rw [this]; exact hgx'
        · have hop0 : opArraySet s x i v = .trap := by
            simp [opArraySet, hil, hn, h0, hxl, hvl, hl, hob, hrc]
          exact TOp.trap hop0
      · cases hL
  · cases hL

theorem tchk_take {d x i : Nat} (ht : tcheckI sh Γ (.takeField d x i) = true) :
    ∃ t ts τ', Γ[x]? = some (.st t) ∧ sh[t]? = some ts ∧ ts[i]? = some τ' ∧ Γ[d]? = some τ' ∧
      τ' ≠ .int := by
  simp only [tcheckI] at ht
  cases hx : Γ[x]? with
  | none => rw [hx] at ht; simp at ht
  | some τ =>
    rw [hx] at ht
    cases τ with
    | st t =>
      simp only at ht
      cases hs : sh[t]? with
      | none => rw [hs] at ht; simp at ht
      | some ts =>
        rw [hs] at ht
        simp only [decide_eq_true_eq] at ht
        obtain ⟨h1, h2, h3⟩ := ht
        obtain ⟨τ', hτ'⟩ := some_of_isSome h2
        rw [hτ'] at h3
        exact ⟨t, ts, τ', rfl, hs, by rw [h1]; exact hτ', hτ', by simpa using h3⟩
    | int => simp at ht
    | arr => simp at ht

theorem top_takeField {d x i : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcheckI sh Γ (.takeField d x i) = true) (h : stepA np a (.takeField d x i) = some a1) :
    TOp sh Γ hty a1 s (opTakeField s d x i) := by
  obtain ⟨t, ts, τ', hΓx, hts, hi, hΓd, hne⟩ := tchk_take ht
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    obtain ⟨hd, hx, _, hdx, hux⟩ := hc
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hnd : hasHole a.holes d = false := by
        cases hh : hasHole a.holes d <;> simp_all
      have hnoi : (x, i) ∉ a.holes := by
        intro hm; apply hnh; simp [hm]
      have hdl : d < s.locals.length := hI.len ▸ hd
      have hxl : x < s.locals.length := hI.len ▸ hx
      obtain ⟨l, ob, hl, hob, hrc⟩ := (hI.cl x).uniq hux
      have hrefx : (gk a.ls x).isRef = true := by rw [hux]; rfl
      obtain ⟨ob', ts', hob', hlty, hts', hA⟩ := loc_obj hI hT hrefx hΓx hl
      rw [hob] at hob'
      cases hob'
      rw [hts] at hts'
      cases hts'
      obtain ⟨old, hold, hvold⟩ := AllT_get hA hi
      have hnn := slot_nonnull hI hT hu hrefx hl hob hlty hts hi hne hnoi
      rw [hold] at hnn
      rcases VT_ref_cases hne hvold with h0 | ⟨lw, hlw, hlw1, hlw2⟩
      · exact absurd (by rw [h0]) hnn
      · subst hlw
        have hop : opTakeField s d x i = .ok (takeSt s d l ob i (.ref lw)) := by
          simp [opTakeField, hdl, hxl, hl, hob, hrc, hold, takeSt]
        refine TOp.ok hop ?_
        have h0 := hT.setL hΓd (VT_ref hne hlw1 hlw2) hnd
        have hheap : (takeSt s d l ob i (.ref lw)).heap =
            s.heap.setObj l { ob with fields := ob.fields.set i (.int 0) } := rfl
        have hat : (takeSt s d l ob i (.ref lw)).heap.objs l =
            some { ob with fields := ob.fields.set i (.int 0) } := by
          rw [hheap, Heap.setObj_objs]; simp
        have hother : ∀ k, k ≠ l → (takeSt s d l ob i (.ref lw)).heap.objs k = s.heap.objs k := by
          intro k hk; rw [hheap, Heap.setObj_objs]; simp [hk]
        have hlo : TLO sh Γ hty (takeSt s d l ob i (.ref lw)) := by
          refine h0.tlo.upd (l := l) (τl := .st t) (nf := ob.fields.set i (.int 0))
            hlty rfl rfl ⟨_, hat, rfl⟩ ?_ ⟨ts, hts, AllT_set hA hi (VT_zero _ _ _)⟩
          intro k o' hk ho'
          exact ⟨o', by rw [hother k hk] at ho'; exact ho', rfl⟩
        refine ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), hlo.loc, hlo.obj, ?_, ?_⟩
        · intro l' o' t' ts'' i' ho' ht' hts'' hτ hf
          have hgetc : ∀ x', x' ≠ d → (takeSt s d l ob i (.ref lw)).get x' = s.get x' := by
            intro x' hx'
            exact get_other s _ d _ hdl rfl x' hx'
          have hgd : ∀ x', (x', i') ∈ a.holes → x' ≠ d := by
            intro x' hx' e; subst e
            have := (hasHole_iff a.holes x').mpr ⟨i', hx'⟩
            rw [hnd] at this; cases this
          by_cases hll : l' = l
          · subst hll
            rw [hat] at ho'
            cases ho'
            have ht2 : t' = t := by
              rw [hlty] at ht'; injection ht' with h; injection h with h; exact h.symm
            subst ht2
            rw [hts] at hts''
            cases hts''
            by_cases hii : i' = i
            · subst hii
              refine ⟨x, List.mem_cons_self, ?_⟩
              rw [hgetc x (Ne.symm hdx)]; exact hl
            · have hii' : ¬ i = i' := fun e => hii e.symm
              simp [List.getElem?_set, hii'] at hf
              obtain ⟨x', hx', hgx'⟩ := hT.hole l' ob t' ts i' hob hlty hts hτ hf
              refine ⟨x', List.mem_cons_of_mem _ hx', ?_⟩
              rw [hgetc x' (hgd x' hx')]; exact hgx'
          · rw [hother l' hll] at ho'
            obtain ⟨x', hx', hgx'⟩ := hT.hole l' o' t' ts'' i' ho' ht' hts'' hτ hf
            refine ⟨x', List.mem_cons_of_mem _ hx', ?_⟩
            rw [hgetc x' (hgd x' hx')]; exact hgx'
        · exact KT_defK (by rw [killB_length]; exact hd) (KT_killB x hT.kt) (fun e => by cases e)
  · cases hL

theorem top_makeUnique {x : Nat} (hI : Inv ext a.ls s) (hT : TInv sh Γ hty a s) (hu : HU a)
    (ht : tcheckI sh Γ (.makeUnique x) = true) (h : stepA np a (.makeUnique x) = some a1) :
    TOp sh Γ hty a1 s (opMakeUnique s x) := by
  have hxG : x < Γ.length := by simpa [tcheckI] using ht
  obtain ⟨τ0, hτ0⟩ : ∃ τ, Γ[x]? = some τ := ⟨Γ[x], List.getElem?_eq_getElem hxG⟩
  obtain ⟨ls', h', hL, hH, rfl⟩ := stepA_split h
  simp only [stepL] at hL
  split at hL
  · rename_i hc
    cases hL
    obtain ⟨hx, hcnt⟩ := hc
    simp only [stepH] at hH
    split at hH
    · cases hH
    · rename_i hnh
      cases hH
      have hnx := noHole1 hnh
      have hxl : x < s.locals.length := hI.len ▸ hx
      have hrefx : (gk a.ls x).isRef = true := by
        cases hk : gk a.ls x <;> rw [hk] at hcnt <;> simp_all [AS.counted, AS.isRef]
      obtain ⟨l, hl⟩ := (hI.cl x).ref hrefx
      obtain ⟨ob, hob⟩ : ∃ ob, s.heap.objs l = some ob := by
        have := hI.live hrefx
        rw [hl] at this
        exact this
      have hdef : (killB x a.ls).set x .unique = defK a.ls x .unique := rfl
      rw [hdef]
      have hkt : KT Γ (defK a.ls x .unique) := KT_defK hx hT.kt (fun e => by cases e)
      by_cases hrc : ob.rc = 1
      · have hop : opMakeUnique s x = .ok s := by simp [opMakeUnique, hxl, hl, hob, hrc]
        refine TOp.ok hop ?_
        exact ⟨hty, HyExt.keep (by first | exact Nat.le_refl _ | simp), hT.abs (fun p hp => hp) hkt⟩
      · have hfl : ob.fields.all s.heap.liveb = true := by
          rw [List.all_eq_true]
          intro v hv
          exact (Heap.liveb_iff _ _).mpr (hI.wf.flds l ob hob v hv)
        have hop : opMakeUnique s x = .ok (muSt s x l ob) := by
          simp [opMakeUnique, hxl, hl, hob, hrc, hfl, muSt, muHeap, Heap.alloc, Heap.bump]
        refine TOp.ok hop ?_
        have hlt : l < s.heap.next := hI.wf.lt_next hob
        have hpos : 0 < ob.rc := hI.wf.rcpos l ob hob
        have hnext := muHeap_next s.heap l ob.fields
        have hnew := muHeap_new s.heap l ob.fields ob hob hlt hpos
        have hspec := muHeap_objs s.heap l ob.fields ob hob hlt hpos
        -- the type of `x`
        have hvx := hT.loc x τ0 hτ0
        rw [hl] at hvx
        have hne : τ0 ≠ .int := by
          intro e; subst e; obtain ⟨n, hn⟩ := hvx; cases hn
        obtain ⟨hty_l, hlt'⟩ : hty l = some τ0 ∧ l < s.heap.next := by
          rcases VT_ref_cases hne hvx with e | ⟨l2, e, e1, e2⟩
          · cases e
          · have : l = l2 := by injection e
            subst this; exact ⟨e1, e2⟩
        obtain ⟨τl, hτl, hok⟩ := hT.obj l ob hob
        rw [hty_l] at hτl
        cases hτl
        have hG := hT.tlo.grow (H' := muHeap s.heap l ob.fields) (d := x) (τ0 := τ0) (fs0 := ob.fields)
          hnext ⟨⟨1, ob.fields⟩, hnew, rfl⟩
          (fun k o' hk ho' => by
            rcases hspec k o' ho' with ⟨hk1, _⟩ | ⟨_, oH, hoH, hf, _⟩
            · exact absurd hk1 hk
            · exact ⟨oH, hoH, hf⟩) hτ0 hne hok
        unfold muSt
        refine ⟨extHty hty s.heap.next τ0, ⟨fun l hl => by simp [extHty, Nat.ne_of_lt hl], by rw [hnext]; omega⟩, hG.loc, hG.obj, ?_, hkt⟩
        intro l' o' t' ts'' i ho' ht' hts'' hτ hf
        by_cases hll : l' = s.heap.next
        · subst hll
          rw [hnew] at ho'
          cases ho'
          have ht3 : τ0 = .st t' := by
            simp [extHty] at ht'; exact ht'
          rw [ht3] at hty_l
          obtain ⟨y, hy, hgy⟩ := hT.hole l ob t' ts'' i hob hty_l hts'' hτ hf
          have := hole_owner_unique hI hu hy hgy hrefx hl
          subst this
          have := (hasHole_iff a.holes x).mpr ⟨i, hy⟩
          rw [hnx] at this; cases this
        · rcases hspec l' o' ho' with ⟨hk1, _⟩ | ⟨_, oH, hoH, hf2, _⟩
          · exact absurd hk1 hll
          · have ht2 : hty l' = some (.st t') := by simpa [extHty, hll] using ht'
            obtain ⟨x', hx', hgx'⟩ := hT.hole l' oH t' ts'' i hoH ht2 hts'' hτ (by rw [← hf2]; exact hf)
            have hxx : x' ≠ x := by
              intro e; subst e
              have := (hasHole_iff a.holes x').mpr ⟨i, hx'⟩
              rw [hnx] at this; cases this
            refine ⟨x', hx', ?_⟩
            simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, hxx, Ne.symm hxx] at hgx' ⊢
            exact hgx'
  · cases hL

end Orin
