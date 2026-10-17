import Orin.Hole

/-!
# Shapes: struct types with an arity, array types, and the type pass

The machine of `Mir.lean` keeps objects as slot lists.  Their *shapes* are static: a struct type
`st t` has the arity and slot types `sh[t]`, an array (`arr`) has scalar elements.  Every local has
one fixed type `Γ[x]` (MIR locals are typed).  The type pass `tcode` is a second, flow-insensitive
checker on top of the ownership check:

* a field access `getField d o i` / `setField x i v` / `takeField d x i` / `putField x i s` names a
  struct local `o` with `i < arity`, and the slot type is the type of the other operand;
* a reference class flag (`isRef`) agrees with the slot type;
* array operations (`arrayLen`, `arrayGet`, `arraySet`, `arrayNew`) name array locals, the index
  and length locals are scalars, and array elements are scalars.

`TInv` is the dynamic invariant the type pass is sound for (`TypedSound.lean`): locals hold values
of their type, every live object has a type (a ghost `hty`) and slots of the slot types, and every
reference slot that is `null` (`int 0`) belongs to an open hole of an owner.
-/

namespace Orin

/-- static types: scalar, struct (index into the shape table), array of scalars -/
inductive Ty where
  | int
  | st (t : Nat)
  | arr
  deriving DecidableEq, Repr

/-- The typed signature of a function as its callers see it: parameter types and result type. -/
structure TSig where
  ptys : List Ty
  rty : Ty

/-- slot types of every struct type -/
abbrev Shapes := List (List Ty)

/-- ghost typing of heap locations -/
abbrev HTy := Nat → Option Ty

/-! ### the type pass -/

/-- type of local `x` -/
def tyAt (Γ : List Ty) (x : Nat) : Option Ty := Γ[x]?

/-- one instruction against the local types `Γ` and the struct shapes `sh` -/
def tcheckI (sh : Shapes) (Γ : List Ty) : MI → Bool
  | .const d _ => decide (Γ[d]? = some .int)
  | .move d s => decide (Γ[d]? = Γ[s]? ∧ (Γ[d]?).isSome)
  | .borrow d s => decide (Γ[d]? = Γ[s]? ∧ (Γ[d]?).isSome)
  | .dup d s => decide (Γ[d]? = Γ[s]? ∧ (Γ[d]?).isSome)
  | .release x => decide ((Γ[x]?).isSome)
  | .alloc d n =>
    match Γ[d]? with
    | some (.st t) => decide ((sh[t]?).map List.length = some n)
    | _ => false
  | .getField d o i r =>
    match Γ[o]? with
    | some (.st t) =>
      match sh[t]? with
      | some fs => decide (fs[i]? = Γ[d]? ∧ (Γ[d]?).isSome ∧ r = decide (Γ[d]? ≠ some .int))
      | none => false
    | _ => false
  | .setField x i v =>
    match Γ[x]? with
    | some (.st t) =>
      match sh[t]? with
      | some fs => decide (fs[i]? = Γ[v]? ∧ (Γ[v]?).isSome)
      | none => false
    | _ => false
  | .takeField d x i =>
    match Γ[x]? with
    | some (.st t) =>
      match sh[t]? with
      | some fs => decide (fs[i]? = Γ[d]? ∧ (Γ[d]?).isSome ∧ Γ[d]? ≠ some .int)
      | none => false
    | _ => false
  | .putField x i s =>
    match Γ[x]? with
    | some (.st t) =>
      match sh[t]? with
      | some fs => decide (fs[i]? = Γ[s]? ∧ (Γ[s]?).isSome)
      | none => false
    | _ => false
  | .makeUnique x => decide ((Γ[x]?).isSome)
  | .arrayLen d a => decide (Γ[a]? = some .arr ∧ Γ[d]? = some .int)
  | .arrayGet d a i r => decide (Γ[a]? = some .arr ∧ Γ[i]? = some .int ∧ Γ[d]? = some .int ∧ r = false)
  | .arraySet x i v => decide (Γ[x]? = some .arr ∧ Γ[i]? = some .int ∧ Γ[v]? = some .int)
  | .arrayNew d nl => decide (Γ[d]? = some .arr ∧ Γ[nl]? = some .int)

/-- The type pass on structured code against the typed signatures `tsg` of the program's functions:
a `call d f args k` needs `tsg[f]`, the operands typed as the parameters, and the destination
typed as the result. -/
def tcode (sh : Shapes) (tsg : List TSig) (Γ : List Ty) : Code → Bool
  | .nil => true
  | .op i k => tcheckI sh Γ i && tcode sh tsg Γ k
  | .ite c t e k =>
    decide (Γ[c]? = some .int) && tcode sh tsg Γ t && tcode sh tsg Γ e && tcode sh tsg Γ k
  | .loop c t k => decide (Γ[c]? = some .int) && tcode sh tsg Γ t && tcode sh tsg Γ k
  | .call d f args k =>
    match tsg[f]? with
    | none => false
    | some ts =>
      decide (args.map (fun j => Γ[j]?) = ts.ptys.map some ∧ Γ[d]? = some ts.rty) &&
        tcode sh tsg Γ k

theorem tcode_app {sh : Shapes} {tsg : List TSig} {Γ : List Ty} : ∀ (t k : Code),
    tcode sh tsg Γ t = true → tcode sh tsg Γ k = true → tcode sh tsg Γ (t.app k) = true
  | .nil, k, _, h => by simpa [Code.app] using h
  | .op i t, k, ht, hk => by
    simp only [tcode, Bool.and_eq_true] at ht
    simp only [Code.app, tcode, Bool.and_eq_true]
    exact ⟨ht.1, tcode_app t k ht.2 hk⟩
  | .ite c t e k', k, ht, hk => by
    simp only [tcode, Bool.and_eq_true] at ht
    simp only [Code.app, tcode, Bool.and_eq_true]
    exact ⟨⟨⟨ht.1.1.1, ht.1.1.2⟩, ht.1.2⟩, tcode_app k' k ht.2 hk⟩
  | .loop c t k', k, ht, hk => by
    simp only [tcode, Bool.and_eq_true] at ht
    simp only [Code.app, tcode, Bool.and_eq_true]
    exact ⟨⟨ht.1.1, ht.1.2⟩, tcode_app k' k ht.2 hk⟩
  | .call d f args k', k, ht, hk => by
    simp only [tcode] at ht
    simp only [Code.app, tcode]
    cases hs : tsg[f]? with
    | none => rw [hs] at ht; simp at ht
    | some ts =>
      rw [hs] at ht
      simp only [Bool.and_eq_true] at ht
      simp only [Bool.and_eq_true]
      exact ⟨ht.1, tcode_app k' k ht.2 hk⟩

/-! ### values, slots, objects -/

/-- `v` has type `τ` w.r.t. the ghost heap typing: a scalar for `int`; for a reference type the
null value `int 0` (a dead local, an emptied slot) or a reference to a location of that type -/
def VT (hty : HTy) (H : Heap) (τ : Ty) (v : Val) : Prop :=
  match τ with
  | .int => ∃ n, v = .int n
  | _ => v = .int 0 ∨ ∃ l, v = .ref l ∧ hty l = some τ ∧ l < H.next

/-- slot values against slot types -/
def AllT (hty : HTy) (H : Heap) : List Ty → List Val → Prop
  | [], [] => True
  | τ :: ts, v :: vs => VT hty H τ v ∧ AllT hty H ts vs
  | _, _ => False

/-- the slots of an object of type `τ` -/
def FOK (sh : Shapes) (hty : HTy) (H : Heap) (τ : Ty) (fs : List Val) : Prop :=
  match τ with
  | .int => False
  | .arr => ∀ v ∈ fs, ∃ n, v = .int n
  | .st t => ∃ ts, sh[t]? = some ts ∧ AllT hty H ts fs

/-- The dynamic type invariant. -/
structure TInv (sh : Shapes) (Γ : List Ty) (hty : HTy) (a : AState) (s : St) : Prop where
  loc : ∀ x τ, Γ[x]? = some τ → VT hty s.heap τ (s.get x)
  obj : ∀ l o, s.heap.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty s.heap τ o.fields
  hole : ∀ l o t ts i, s.heap.objs l = some o → hty l = some (.st t) → sh[t]? = some ts →
      (∃ τ', ts[i]? = some τ' ∧ τ' ≠ .int) → o.fields[i]? = some (.int 0) →
      ∃ x, (x, i) ∈ a.holes ∧ s.get x = .ref l
  kt : ∀ x, gk a.ls x = .init → Γ[x]? = some .int

/-! ### monotonicity -/

/-- the ghost typing and the heap only grew -/
def HyExt (hty hty' : HTy) (H H' : Heap) : Prop :=
  (∀ l, l < H.next → hty' l = hty l) ∧ H.next ≤ H'.next

theorem HyExt.refl (hty : HTy) (H : Heap) : HyExt hty hty H H := ⟨fun _ _ => rfl, Nat.le_refl _⟩

theorem HyExt.keep {hty : HTy} {H H' : Heap} (h : H.next ≤ H'.next) : HyExt hty hty H H' :=
  ⟨fun _ _ => rfl, h⟩

theorem HyExt.trans {hty hty' hty'' : HTy} {H H' H'' : Heap} (h1 : HyExt hty hty' H H')
    (h2 : HyExt hty' hty'' H' H'') : HyExt hty hty'' H H'' :=
  ⟨fun l hl => by rw [h2.1 l (by have := h1.2; omega), h1.1 l hl], Nat.le_trans h1.2 h2.2⟩

theorem VT_mono {hty hty' : HTy} {H H' : Heap} (he : HyExt hty hty' H H') {τ : Ty} {v : Val}
    (h : VT hty H τ v) : VT hty' H' τ v := by
  cases τ with
  | int => exact h
  | st t =>
    rcases h with h | ⟨l, hv, ht, hl⟩
    · exact Or.inl h
    · exact Or.inr ⟨l, hv, by rw [he.1 l hl]; exact ht, by have := he.2; omega⟩
  | arr =>
    rcases h with h | ⟨l, hv, ht, hl⟩
    · exact Or.inl h
    · exact Or.inr ⟨l, hv, by rw [he.1 l hl]; exact ht, by have := he.2; omega⟩

theorem AllT_mono {hty hty' : HTy} {H H' : Heap} (he : HyExt hty hty' H H') :
    ∀ {ts : List Ty} {vs : List Val}, AllT hty H ts vs → AllT hty' H' ts vs
  | [], [], _ => trivial
  | [], _ :: _, h => h
  | _ :: _, [], h => h
  | _ :: _, _ :: _, h => ⟨VT_mono he h.1, AllT_mono he h.2⟩

theorem FOK_mono {sh : Shapes} {hty hty' : HTy} {H H' : Heap} (he : HyExt hty hty' H H')
    {τ : Ty} {fs : List Val} (h : FOK sh hty H τ fs) : FOK sh hty' H' τ fs := by
  cases τ with
  | int => exact h
  | arr => exact h
  | st t =>
    obtain ⟨ts, hts, hA⟩ := h
    exact ⟨ts, hts, AllT_mono he hA⟩

theorem VT_ref_cases {hty : HTy} {H : Heap} {τ : Ty} {v : Val} (hne : τ ≠ .int)
    (h : VT hty H τ v) : v = .int 0 ∨ ∃ l, v = .ref l ∧ hty l = some τ ∧ l < H.next := by
  cases τ with
  | int => exact absurd rfl hne
  | st t => exact h
  | arr => exact h

theorem VT_ref {hty : HTy} {H : Heap} {τ : Ty} {l : Nat} (hne : τ ≠ .int)
    (h1 : hty l = some τ) (h2 : l < H.next) : VT hty H τ (.ref l) := by
  cases τ with
  | int => exact absurd rfl hne
  | st t => exact Or.inr ⟨l, rfl, h1, h2⟩
  | arr => exact Or.inr ⟨l, rfl, h1, h2⟩

theorem VT_zero (hty : HTy) (H : Heap) (τ : Ty) : VT hty H τ (.int 0) := by
  cases τ with
  | int => exact ⟨0, rfl⟩
  | st t => exact Or.inl rfl
  | arr => exact Or.inl rfl

theorem AllT_length : ∀ {hty : HTy} {H : Heap} {ts : List Ty} {vs : List Val},
    AllT hty H ts vs → vs.length = ts.length
  | _, _, [], [], _ => rfl
  | _, _, [], _ :: _, h => h.elim
  | _, _, _ :: _, [], h => h.elim
  | _, _, _ :: _, _ :: _, h => by
    simp only [List.length_cons]; rw [AllT_length h.2]

theorem AllT_get : ∀ {hty : HTy} {H : Heap} {ts : List Ty} {vs : List Val},
    AllT hty H ts vs → ∀ {i : Nat} {τ : Ty}, ts[i]? = some τ →
      ∃ w, vs[i]? = some w ∧ VT hty H τ w
  | _, _, [], [], _, i, τ, h => by simp at h
  | _, _, [], _ :: _, h, _, _, _ => h.elim
  | _, _, _ :: _, [], h, _, _, _ => h.elim
  | _, _, _ :: ts, v :: vs, h, i, τ, hi => by
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
      subst hi
      exact ⟨v, rfl, h.1⟩
    | succ j =>
      simp only [List.getElem?_cons_succ] at hi ⊢
      exact AllT_get h.2 hi

theorem AllT_set : ∀ {hty : HTy} {H : Heap} {ts : List Ty} {vs : List Val},
    AllT hty H ts vs → ∀ {i : Nat} {τ : Ty} {w : Val}, ts[i]? = some τ → VT hty H τ w →
      AllT hty H ts (vs.set i w)
  | _, _, [], [], _, i, τ, w, h, _ => by simp at h
  | _, _, [], _ :: _, h, _, _, _, _, _ => h.elim
  | _, _, _ :: _, [], h, _, _, _, _, _ => h.elim
  | _, _, _ :: ts, v :: vs, h, i, τ, w, hi, hw => by
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
      subst hi
      exact ⟨hw, h.2⟩
    | succ j =>
      simp only [List.getElem?_cons_succ] at hi
      exact ⟨h.1, AllT_set h.2 hi hw⟩

theorem AllT_replicate (hty : HTy) (H : Heap) :
    ∀ ts : List Ty, AllT hty H ts (List.replicate ts.length (.int 0))
  | [] => trivial
  | τ :: ts => by
    simp only [List.length_cons, List.replicate_succ]
    exact ⟨VT_zero _ _ _, AllT_replicate hty H ts⟩

/-! ### transfer lemmas for `TInv` -/

/-- kinds versus types: an initialised local is a scalar -/
def KT (Γ : List Ty) (ls : List AS) : Prop := ∀ x, gk ls x = .init → Γ[x]? = some .int

theorem KT_defK {Γ : List Ty} {a : List AS} {d : Nat} {k : AS} (hd : d < a.length)
    (hk : KT Γ a) (hd2 : k = .init → Γ[d]? = some .int) : KT Γ (defK a d k) := by
  intro x hx
  rw [gk_defK a d k x hd] at hx
  by_cases hxd : x = d
  · subst hxd
    simp only [ite_true] at hx
    rw [← hx] at hd2
    exact hd2 rfl
  · simp only [hxd, if_false] at hx
    by_cases hb : gk a x = .borrowed d
    · simp [hb] at hx
    · simp only [hb, if_false] at hx
      exact hk x hx

theorem KT_killB {Γ : List Ty} {a : List AS} (y : Nat) (hk : KT Γ a) : KT Γ (killB y a) := by
  intro x hx
  rw [gk_killB] at hx
  by_cases hb : gk a x = .borrowed y
  · simp [hb] at hx
  · simp only [hb, if_false] at hx; exact hk x hx

theorem KT_demote {Γ : List Ty} {a : List AS} {l : Nat} (hl : l < a.length) (hk : KT Γ a) :
    KT Γ (demote a l) := by
  intro x hx
  rw [gk_demote a l x hl] at hx
  by_cases hc : x = l ∧ gk a l = .unique
  · simp [hc] at hx
  · simp only [hc, if_false] at hx; exact hk x hx

theorem KT_killK {Γ : List Ty} {a : List AS} {l : Nat} (hl : l < a.length) (hk : KT Γ a) :
    KT Γ (killK a l) :=
  KT_defK hl hk (fun h => by cases h)

/-- changing the abstract state: holes only grow (as a set), kinds satisfy `KT` -/
theorem TInv.abs {sh : Shapes} {Γ : List Ty} {hty : HTy} {a a1 : AState} {s : St}
    (hT : TInv sh Γ hty a s) (hh : ∀ p ∈ a.holes, p ∈ a1.holes) (hk : KT Γ a1.ls) :
    TInv sh Γ hty a1 s :=
  ⟨hT.loc, hT.obj, fun l o t ts i ho ht hts hτ hf => by
    obtain ⟨x, hx, hg⟩ := hT.hole l o t ts i ho ht hts hτ hf
    exact ⟨x, hh _ hx, hg⟩, hk⟩

theorem tget_setL (s : St) (d x : Nat) (w : Val) :
    (s.setL d w).get x = if x = d ∧ d < s.locals.length then w else s.get x := by
  by_cases h : x = d ∧ d < s.locals.length
  · obtain ⟨rfl, hd⟩ := h
    simp [St.get, St.setL, List.getD_eq_getElem?_getD, hd]
  · rw [if_neg h]
    by_cases hx : x = d
    · subst hx
      have : ¬ x < s.locals.length := fun hh => h ⟨rfl, hh⟩
      simp [St.get, St.setL, List.getD_eq_getElem?_getD, List.getElem?_set, this,
        List.getElem?_eq_none (by omega : s.locals.length ≤ x)]
    · simp [St.get, St.setL, List.getD_eq_getElem?_getD, List.getElem?_set, hx, Ne.symm hx]

/-- overwrite one local with a value of its type -/
theorem TInv.setL {sh : Shapes} {Γ : List Ty} {hty : HTy} {a : AState} {s : St}
    (hT : TInv sh Γ hty a s) {d : Nat} {τ : Ty} {w : Val} (hτ : Γ[d]? = some τ)
    (hw : VT hty s.heap τ w) (hh : hasHole a.holes d = false) :
    TInv sh Γ hty a (s.setL d w) := by
  refine ⟨fun x τ' hx => ?_, hT.obj, fun l o t ts i ho ht hts hτ' hf => ?_, hT.kt⟩
  · rw [tget_setL]
    by_cases hc : x = d ∧ d < s.locals.length
    · rw [if_pos hc]
      obtain ⟨rfl, _⟩ := hc
      rw [hτ] at hx
      cases hx
      exact hw
    · rw [if_neg hc]; exact hT.loc x τ' hx
  · obtain ⟨x, hx, hg⟩ := hT.hole l o t ts i ho ht hts hτ' hf
    refine ⟨x, hx, ?_⟩
    rw [tget_setL]
    have hxd : x ≠ d := by
      intro e; subst e
      have := (hasHole_iff a.holes x).mpr ⟨i, hx⟩
      rw [hh] at this; cases this
    rw [if_neg (fun hc => hxd hc.1)]
    exact hg

/-- the heap lost nothing but counts: same size, objects keep their slots -/
def FSub (H H' : Heap) : Prop :=
  H'.next = H.next ∧ ∀ l o', H'.objs l = some o' → ∃ o, H.objs l = some o ∧ o'.fields = o.fields

theorem TInv.heap {sh : Shapes} {Γ : List Ty} {hty : HTy} {a : AState} {s s' : St}
    (hT : TInv sh Γ hty a s) (hl : s'.locals = s.locals) (hf : FSub s.heap s'.heap) :
    TInv sh Γ hty a s' := by
  have hext : HyExt hty hty s.heap s'.heap := ⟨fun _ _ => rfl, by rw [hf.1]; exact Nat.le_refl _⟩
  have hg : ∀ x, s'.get x = s.get x := by intro x; simp [St.get, hl]
  refine ⟨fun x τ hx => ?_, fun l o' ho' => ?_, fun l o' t ts i ho' ht hts hτ hfi => ?_, hT.kt⟩
  · rw [hg]; exact VT_mono hext (hT.loc x τ hx)
  · obtain ⟨o, ho, hfs⟩ := hf.2 l o' ho'
    obtain ⟨τ, hτ, hok⟩ := hT.obj l o ho
    exact ⟨τ, hτ, by rw [hfs]; exact FOK_mono hext hok⟩
  · obtain ⟨o, ho, hfs⟩ := hf.2 l o' ho'
    obtain ⟨x, hx, hgx⟩ := hT.hole l o t ts i ho ht hts hτ (by rw [← hfs]; exact hfi)
    exact ⟨x, hx, by rw [hg]; exact hgx⟩

/-- the release worklist is not part of the invariant -/
theorem TInv.same {sh : Shapes} {Γ : List Ty} {hty : HTy} {a : AState} {s s' : St}
    (hT : TInv sh Γ hty a s) (hl : s'.locals = s.locals) (hh : s'.heap = s.heap) :
    TInv sh Γ hty a s' :=
  hT.heap hl ⟨by rw [hh], fun l o' ho' => ⟨o', by rw [← hh]; exact ho', rfl⟩⟩

/-- ghost typing extended by one fresh location -/
def extHty (hty : HTy) (n : Nat) (τ : Ty) : HTy := fun l => if l = n then some τ else hty l

/-- `loc` and `obj` parts of the invariant -/
structure TLO (sh : Shapes) (Γ : List Ty) (hty : HTy) (s : St) : Prop where
  loc : ∀ x τ, Γ[x]? = some τ → VT hty s.heap τ (s.get x)
  obj : ∀ l o, s.heap.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty s.heap τ o.fields

theorem TInv.tlo {sh : Shapes} {Γ : List Ty} {hty : HTy} {a : AState} {s : St}
    (hT : TInv sh Γ hty a s) : TLO sh Γ hty s := ⟨hT.loc, hT.obj⟩

/-- A fresh object `fs0` of type `τ0` at the old frontier, stored into local `d` (of type `τ0`);
everything else keeps its slots. -/
theorem TLO.grow {sh : Shapes} {Γ : List Ty} {hty : HTy} {s : St} (hT : TLO sh Γ hty s)
    {H' : Heap} {d : Nat} {τ0 : Ty} {fs0 : List Val}
    (hn : H'.next = s.heap.next + 1) (hnew : ∃ o0, H'.objs s.heap.next = some o0 ∧ o0.fields = fs0)
    (hold : ∀ k o', k ≠ s.heap.next → H'.objs k = some o' →
      ∃ o, s.heap.objs k = some o ∧ o'.fields = o.fields)
    (hτ : Γ[d]? = some τ0) (hne : τ0 ≠ .int) (hfok : FOK sh hty s.heap τ0 fs0) :
    TLO sh Γ (extHty hty s.heap.next τ0) ⟨H', s.locals.set d (.ref s.heap.next), s.pending⟩ := by
  have hext : HyExt hty (extHty hty s.heap.next τ0) s.heap H' :=
    ⟨fun l hl => by simp [extHty, Nat.ne_of_lt hl], by rw [hn]; omega⟩
  refine ⟨fun x τ hx => ?_, fun l o ho => ?_⟩
  · by_cases hxd : x = d ∧ d < s.locals.length
    · obtain ⟨rfl, hd⟩ := hxd
      have hget : (⟨H', s.locals.set x (.ref s.heap.next), s.pending⟩ : St).get x = .ref s.heap.next := by
        simp [St.get, List.getD_eq_getElem?_getD, hd]
      rw [hget]
      have e : τ0 = τ := by rw [hτ] at hx; exact Option.some.inj hx
      subst e
      cases τ0 with
      | int => exact absurd rfl hne
      | st t => exact Or.inr ⟨_, rfl, by simp [extHty], by rw [hn]; omega⟩
      | arr => exact Or.inr ⟨_, rfl, by simp [extHty], by rw [hn]; omega⟩
    · have hget : (⟨H', s.locals.set d (.ref s.heap.next), s.pending⟩ : St).get x = s.get x := by
        by_cases hxd' : x = d
        · subst hxd'
          have : ¬ x < s.locals.length := fun hh => hxd ⟨rfl, hh⟩
          simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, this,
            List.getElem?_eq_none (by omega : s.locals.length ≤ x)]
        · simp [St.get, List.getD_eq_getElem?_getD, List.getElem?_set, hxd', Ne.symm hxd']
      rw [hget]
      exact VT_mono hext (hT.loc x τ hx)
  · by_cases hl : l = s.heap.next
    · subst hl
      obtain ⟨o0, ho0, hf0⟩ := hnew
      rw [ho0] at ho
      cases ho
      refine ⟨τ0, by simp [extHty], ?_⟩
      rw [hf0]
      exact FOK_mono hext hfok
    · obtain ⟨o', ho', hf'⟩ := hold l o hl ho
      obtain ⟨τ, hτl, hok⟩ := hT.obj l o' ho'
      refine ⟨τ, by simp [extHty, hl, hτl], ?_⟩
      rw [hf']
      exact FOK_mono hext hok

/-- the object at `l` is replaced by one with the same type and new slots -/
theorem TLO.upd {sh : Shapes} {Γ : List Ty} {hty : HTy} {s s' : St} (hT : TLO sh Γ hty s)
    {l : Nat} {τl : Ty} {nf : List Val}
    (hty_l : hty l = some τl)
    (hn : s'.heap.next = s.heap.next) (hloc : s'.locals = s.locals)
    (hnew : ∃ o0, s'.heap.objs l = some o0 ∧ o0.fields = nf)
    (hold : ∀ k o', k ≠ l → s'.heap.objs k = some o' →
      ∃ o, s.heap.objs k = some o ∧ o'.fields = o.fields)
    (hfok : FOK sh hty s.heap τl nf) : TLO sh Γ hty s' := by
  have hext : HyExt hty hty s.heap s'.heap := ⟨fun _ _ => rfl, by rw [hn]; exact Nat.le_refl _⟩
  have hg : ∀ x, s'.get x = s.get x := by intro x; simp [St.get, hloc]
  refine ⟨fun x τ hx => ?_, fun k o ho => ?_⟩
  · rw [hg]; exact VT_mono hext (hT.loc x τ hx)
  · by_cases hk : k = l
    · subst hk
      obtain ⟨o0, ho0, hf0⟩ := hnew
      rw [ho0] at ho
      cases ho
      exact ⟨τl, hty_l, by rw [hf0]; exact FOK_mono hext hfok⟩
    · obtain ⟨o', ho', hf'⟩ := hold k o hk ho
      obtain ⟨τ, hτl, hok⟩ := hT.obj k o' ho'
      exact ⟨τ, hτl, by rw [hf']; exact FOK_mono hext hok⟩

end Orin
