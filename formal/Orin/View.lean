import Orin.WF

/-!
# Observable value of a reference (`view`) and heap-frame lemmas

`view H f v` is the finite unfolding (depth `f`) of the *value* denoted by `v` in heap `H`:
scalars are themselves, a reference denotes the tuple of the views of its fields. Reference
counts and addresses are *not* observable: only the structure and scalars are. This is the
"logical snapshot" semantics of spec 06 (`const b = a; a.x = 1` leaves `b` unchanged).
`cut` marks depth exhaustion, `dangling` a reference to a non-live location.
-/

namespace Orin
open Heap

inductive Tree where
  | scalar (n : Int)
  | node (cs : List Tree)
  | cut
  | dangling

def view (H : Heap) : Nat → Val → Tree
  | _, .int n => .scalar n
  | 0, .ref _ => .cut
  | f + 1, .ref l =>
    match H.objs l with
    | none => .dangling
    | some o => .node (o.fields.map (view H f))

/-- If `P` is a set of locations that are live in `H`, closed under "field of", and whose
objects have the same fields in `H'`, then `H` and `H'` agree on the view of every value that
only points into `P`. -/
theorem view_agree (H H' : Heap) (P : Nat → Prop)
    (hlive : ∀ m, P m → ∃ o, H.objs m = some o)
    (hfields : ∀ m, P m → ∀ o, H.objs m = some o → ∃ o', H'.objs m = some o' ∧ o'.fields = o.fields)
    (hclosed : ∀ m, P m → ∀ o, H.objs m = some o → ∀ v ∈ o.fields, ∀ l, v = .ref l → P l) :
    ∀ f v, (∀ l, v = .ref l → P l) → view H' f v = view H f v := by
  intro f
  induction f with
  | zero =>
    intro v hv
    cases v <;> simp [view]
  | succ f ih =>
    intro v hv
    cases v with
    | int n => simp [view]
    | ref l =>
      have hl := hv l rfl
      obtain ⟨o, ho⟩ := hlive l hl
      obtain ⟨o', ho', hf⟩ := hfields l hl o ho
      simp only [view, ho, ho', hf]
      congr 1
      apply List.map_congr_left
      intro v' hv'
      exact ih v' (hclosed l hl o ho v' hv')

end Orin
