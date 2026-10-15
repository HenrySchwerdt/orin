import Orin.COW

/-!
# Load forwarding (ADR-0038 lever 2, T4; MIR v2.4 `IForward`, verifier rule F1)

`d = forward s, o[k]` replaces a second load of slot `k` of `o` by a copy of `s`. Rule F1 accepts it when, going back in
the same block, the first instruction that touches the slot is a load of it into `s` or a store of `s` into it, and nothing
in between redefines `s` or `o` or writes the slot. These lemmas are the model-level facts that argument rests on:

* `load_slot` / `store_slot`        : after `load y x i` the local `y` holds slot `i` of `x`; after `store x i y` slot `i`
                                      of `x` holds the value of `y`.
* `load_frame`                      : a load into `y ≠ x` leaves every slot of `x` as it was.
* `store_frame_other_slot`          : a store into another slot of the same object leaves slot `i` as it was.
* `store_frame_other_local`         : a store through another local `w ≠ x` leaves every slot of `x` as it was (the store
                                      needs count 1 on `w`'s object, so `x` cannot refer to it).
* `makeUnique_frame`                : `makeUnique x` keeps every slot value of `x` (a shallow copy).
* `load_load` / `store_load`        : the two sources of F1: a second load of the same slot returns what the first load,
                                      or the store, put in the source local.

The model has no calls and no arrays with a length (`Machine.lean`); calls stay "rules not yet in the model" (docs/tcb.md),
and F1 step 1 ends its scan at any call that receives `o`.
-/

namespace Orin
open Heap

/-- The value in slot `i` of the object held by local `x` (`none` for a scalar, a dead object or a missing slot). -/
def St.slot (s : St) (x i : Nat) : Option Val :=
  match s.get x with
  | .ref l => (s.heap.objs l).bind (fun o => o.fields[i]?)
  | .int _ => none

theorem setL_get_same (s : St) (y : Nat) (v : Val) (hy : y < s.locals.length) : (s.setL y v).get y = v := by
  simp [St.setL, St.get, hy]

theorem setL_get_other (s : St) (y x : Nat) (v : Val) (h : y ≠ x) : (s.setL y v).get x = s.get x := by
  simp [St.setL, St.get, List.getD_eq_getElem?_getD, List.getElem?_set_ne h]

/-- `bump` changes counts only, never a slot. -/
theorem bump_bind (H : Heap) (vs : List Val) (l i : Nat) :
    ((H.bump vs).objs l).bind (fun o => o.fields[i]?) = (H.objs l).bind (fun o => o.fields[i]?) := by
  simp only [Heap.bump]
  cases H.objs l <;> rfl

/-- Everything a successful load does. -/
theorem opLoad_ok_spec {s s1 : St} (h : opLoad s y x i = .ok s1) :
    ∃ l o v, y < s.locals.length ∧ s.get x = .ref l ∧ s.heap.objs l = some o ∧ o.fields[i]? = some v ∧
      s1 = { s.setL y v with heap := s.heap.bump [v] } := by
  unfold opLoad at h
  split at h
  · rename_i hxy
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · simp at h
      · rename_i o ho
        split at h
        · simp at h
        · rename_i v hv
          split at h
          · simp at h
            exact ⟨l, o, v, hxy.2, hxl, ho, hv, h.symm⟩
          · simp at h
  · simp at h

/-- After `load y x i`, `y` holds slot `i` of `x`. -/
theorem load_slot {s s1 : St} (h : opLoad s y x i = .ok s1) : s.slot x i = some (s1.get y) := by
  obtain ⟨l, o, v, hy, hxl, ho, hv, rfl⟩ := opLoad_ok_spec h
  have hg : ({ s.setL y v with heap := s.heap.bump [v] } : St).get y = v := setL_get_same s y v hy
  rw [hg]
  simp [St.slot, hxl, ho, hv]

/-- A load into another local changes no slot of `x`. -/
theorem load_frame {s s1 : St} (h : opLoad s y x i = .ok s1) (hyx : y ≠ x) (j : Nat) :
    s1.slot x j = s.slot x j := by
  obtain ⟨l, o, v, hy, hxl, ho, hv, rfl⟩ := opLoad_ok_spec h
  have hg : ({ s.setL y v with heap := s.heap.bump [v] } : St).get x = s.get x := setL_get_other s y x v hyx
  simp only [St.slot, hg, hxl]
  exact bump_bind s.heap [v] l j

/-- After `store x i y`, slot `i` of `x` holds the value of `y`. -/
theorem store_slot {s s1 : St} (h : opStore s x i y = .ok s1) : s1.slot x i = some (s1.get y) := by
  obtain ⟨l, o, old, _, _, hxl, ho, _, hold, _, rfl⟩ := opStore_ok_spec h
  have hi : i < o.fields.length := by
    rcases Nat.lt_or_ge i o.fields.length with hi | hi
    · exact hi
    · rw [List.getElem?_eq_none hi] at hold; cases hold
  simp only [St.slot, St.get] at hxl ⊢
  rw [hxl]
  simp [bump_bind, Heap.setObj, hi]

/-- A store into another slot of the same object leaves slot `i` as it was. -/
theorem store_frame_other_slot {s s1 : St} (h : opStore s x j y = .ok s1) (hji : j ≠ i) :
    s1.slot x i = s.slot x i := by
  obtain ⟨l, o, old, _, _, hxl, ho, _, _, _, rfl⟩ := opStore_ok_spec h
  simp only [St.slot, St.get] at hxl ⊢
  rw [hxl]
  simp [bump_bind, Heap.setObj, ho, List.getElem?_set_ne hji]

/-- A store through another local `w ≠ x` leaves every slot of `x` as it was: the store needs count 1 on `w`'s object,
so in a well-formed state no other local refers to that object. -/
theorem store_frame_other_local {s s1 : St} (hwf : WF s) (h : opStore s w j y = .ok s1)
    (hx : x < s.locals.length) (hwx : w ≠ x) (i : Nat) : s1.slot x i = s.slot x i := by
  obtain ⟨lw, o, old, hw, _, hwl, ho, hrc, _, _, rfl⟩ := opStore_ok_spec h
  obtain ⟨hnoL, _, _⟩ := unique_facts hwf hw hwl ho hrc
  have hxs := s.get_spec x hx
  have hne : s.get x ≠ .ref lw := hnoL x (s.get x) (Ne.symm hwx) hxs
  show (match s.get x with
        | .ref l => (((s.heap.setObj lw { o with fields := o.fields.set j (s.get y) }).bump [s.get y]).objs l).bind
            (fun o => o.fields[i]?)
        | .int _ => none) = s.slot x i
  unfold St.slot
  cases hg : s.get x with
  | int n => rfl
  | ref l =>
    have hl : l ≠ lw := fun e => hne (by rw [hg, e])
    dsimp only
    rw [bump_bind]
    simp [Heap.setObj, hl]

/-- `makeUnique x` keeps every slot value of `x`: either nothing happens (count 1) or `x` gets a shallow copy. -/
theorem makeUnique_frame {s s1 : St} (hwf : WF s) (h : opMakeUnique s x = .ok s1) (i : Nat) :
    s1.slot x i = s.slot x i := by
  unfold opMakeUnique at h
  split at h
  · rename_i hx
    split at h
    · simp at h
    · rename_i l hxl
      split at h
      · simp at h
      · rename_i o ho
        split at h
        · simp at h; subst h; rfl
        · split at h
          · simp at h; subst h
            have hl := hwf.lt_next ho
            have hpos := hwf.rcpos l o ho
            have hnew := muHeap_new s.heap l o.fields o ho hl hpos
            have hg : (s.locals.set x (.ref s.heap.next)).getD x (.int 0) = .ref s.heap.next := by simp [hx]
            show (match (s.locals.set x (.ref s.heap.next)).getD x (.int 0) with
                  | .ref l' => ((muHeap s.heap l o.fields).objs l').bind (fun o => o.fields[i]?)
                  | .int _ => none) = s.slot x i
            rw [hg]
            dsimp only
            rw [hnew]
            simp [St.slot, hxl, ho]
          · simp at h
  · simp at h

/-- **F1, source = load.** `load y x i; …; load z x i` with `y ≠ x` and nothing in between: the second load returns
what the first one put in `y`. -/
theorem load_load {s s1 s2 : St} (h1 : opLoad s y x i = .ok s1) (hyx : y ≠ x) (h2 : opLoad s1 z x i = .ok s2) :
    s2.get z = s1.get y := by
  have a := load_slot h2
  rw [load_frame h1 hyx, load_slot h1] at a
  injection a with e
  exact e.symm

/-- **F1, source = store.** `store x i y; load z x i`: the load returns the stored value of `y`. -/
theorem store_load {s s1 s2 : St} (h1 : opStore s x i y = .ok s1) (h2 : opLoad s1 z x i = .ok s2) :
    s2.get z = s1.get y := by
  have a := load_slot h2
  rw [store_slot h1] at a
  injection a with e
  exact e.symm

end Orin
