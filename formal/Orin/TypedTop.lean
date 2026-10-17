import Orin.TypedSound
import Orin.Top

/-!
# Headline theorem, second half: checked and type-checked code never reaches `ill`

`check_sound_ill` strengthens `check_sound` (`Top.lean`): a function accepted by the ownership
checker `check` and by the type pass `tcode` (struct shapes: arity, field index, slot types; array
operations only on arrays) never takes a `bad` step and never takes an `ill` step, i.e. no
out-of-range field access, no field access or array operation on a value of the wrong kind, no
null dereference.

Entry hypotheses (what the caller of the function guarantees): the locals `Γ` type the arguments
(`hvals`), scalar parameters are `int`, the heap `H` is typed by the ghost typing `hty` with
non-null reference slots (`hnull`).  Calls are not covered here (`tcode` rejects `call`).
-/

namespace Orin
open Heap

theorem entry_tinv (p : Prog) (sh : Shapes) (Γ : List Ty) (hty : HTy) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length)
    (hkt : ∀ i : Nat, p.params[i]? = some false → Γ[i]? = some Ty.int)
    (hvals : ∀ x τ, Γ[x]? = some τ → x < p.params.length → VT hty H τ (vals.getD x (Val.int 0)))
    (hobj : ∀ l o, H.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty H τ o.fields)
    (hnull : ∀ l o t ts (i : Nat), H.objs l = some o → hty l = some (.st t) → sh[t]? = some ts →
      (∃ τ', ts[i]? = some τ' ∧ τ' ≠ Ty.int) → o.fields[i]? ≠ some (Val.int 0)) :
    TInv sh Γ hty p.entry (initSt p H vals) := by
  refine ⟨fun x τ hx => ?_, hobj, fun l o t ts i ho ht hts hτ hf => ?_, fun x hx => ?_⟩
  · by_cases hxp : x < p.params.length
    · have := hvals x τ hx hxp
      have hg : (initSt p H vals).get x = vals.getD x (Val.int 0) := by
        simp [St.get, initSt, List.getD_eq_getElem?_getD,
          List.getElem?_append_left (by omega : x < vals.length)]
      rw [hg]; exact this
    · have hg : (initSt p H vals).get x = Val.int 0 := by
        simp only [St.get, initSt, List.getD_eq_getElem?_getD]
        by_cases hx2 : x < vals.length + (p.n - p.params.length)
        · rw [List.getElem?_append_right (by omega), List.getElem?_replicate]
          split <;> simp
        · rw [List.getElem?_eq_none (by simp; omega)]; rfl
      rw [hg]
      cases τ with
      | int => exact ⟨0, rfl⟩
      | st t => exact Or.inl rfl
      | arr => exact Or.inl rfl
  · exact absurd hf (hnull l o t ts i ho ht hts hτ)
  · rw [gk_entry] at hx
    cases hpx : p.params[x]? with
    | none => rw [hpx] at hx; cases hx
    | some b =>
      cases b with
      | true => rw [hpx] at hx; cases hx
      | false => exact hkt x hpx

/-- **Headline theorem (shapes).** A function accepted by `check` and by the type pass `tcode`
never takes an `ill` step (no out-of-range field/array-kind/null fault) and never takes a `bad`
step, from any typed entry state satisfying the caller contract of `check_sound`. -/
theorem check_sound_ill (p : Prog) (hp : check p = true) (sh : Shapes) (Γ : List Ty)
    (ht : tcode sh Γ p.code = true) (hty : HTy) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length) (hext : WF ⟨H, ext, []⟩)
    (href : ∀ i : Nat, p.params[i]? = some true →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, p.params[i]? = some false → ∃ n, vals[i]? = some (Val.int n))
    (hkt : ∀ i : Nat, p.params[i]? = some false → Γ[i]? = some Ty.int)
    (hvals : ∀ x τ, Γ[x]? = some τ → x < p.params.length → VT hty H τ (vals.getD x (Val.int 0)))
    (hobj : ∀ l o, H.objs l = some o → ∃ τ, hty l = some τ ∧ FOK sh hty H τ o.fields)
    (hnull : ∀ l o t ts (i : Nat), H.objs l = some o → hty l = some (.st t) → sh[t]? = some ts →
      (∃ τ', ts[i]? = some τ' ∧ τ' ≠ Ty.int) → o.fields[i]? ≠ some (Val.int 0))
    {c : Code × St} (hr : MReach (p.code, initSt p H vals) c) :
    mstep c ≠ some .ill ∧ ∀ k, mstep c ≠ some (.bad k) := by
  obtain ⟨hn, hC⟩ := check_cont hp
  exact reach_T hC (entry_inv p hn ext H vals hlen hext href hsc)
    (entry_tinv p sh Γ hty H vals hlen hkt hvals hobj hnull) (HU_nil _) ht hr

/-! ### examples: the type pass is neither vacuous nor trivially permissive -/

/-- one struct type with two scalar slots; local 0 is that struct, local 1 an int -/
private def exSh : Shapes := [[Ty.int, Ty.int]]
private def exG : List Ty := [Ty.st 0, Ty.int]

example : tcode exSh exG (.op (.getField 1 0 1 false) .nil) = true := by decide
/-- index out of the arity -/
example : tcode exSh exG (.op (.getField 1 0 2 false) .nil) = false := by decide
/-- field access on a scalar local -/
example : tcode exSh exG (.op (.getField 0 1 0 false) .nil) = false := by decide
/-- array operation on a struct local -/
example : tcode exSh exG (.op (.arrayLen 1 0) .nil) = false := by decide
/-- wrong arity at allocation -/
example : tcode exSh exG (.op (.alloc 0 3) .nil) = false := by decide
example : tcode exSh exG (.op (.alloc 0 2) .nil) = true := by decide

end Orin
