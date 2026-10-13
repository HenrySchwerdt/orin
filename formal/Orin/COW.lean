import Orin.View
import Orin.Safety

/-!
# Uniqueness, makeUnique and the copy-on-write / value-semantics lemma

Main results:
* `opMakeUnique_unique`  : after `makeUnique x`, `x` holds a live object with count 1.
* `opStore_unique_ok`    : a store through a count-1 local is never `bad` (neither `shared` nor `dead`).
* `makeUnique_store_cow` : for `makeUnique x; store x i y`, every other local and every
  pending-release entry observes exactly the same value before and after (aliases keep
  observing the old value).
* `makeUnique_view`      : `makeUnique` does not change the value observed through `x`.
-/

namespace Orin
open Heap

/-- If a local owns the only count of its object, then nothing else refers to it:
no other local, no pending entry, no heap field. -/
theorem unique_facts {s : St} (hwf : WF s) {x l : Nat} {o : Obj} (hx : x < s.locals.length)
    (hxl : s.get x = .ref l) (ho : s.heap.objs l = some o) (hrc : o.rc = 1) :
    (∀ z w, z ≠ x → s.locals[z]? = some w → w ≠ .ref l) ∧
    (∀ v ∈ s.pending, v ≠ .ref l) ∧
    (∀ m o', s.heap.objs m = some o' → ∀ v ∈ o'.fields, v ≠ .ref l) := by
  have hs := hwf.sound l o ho
  unfold St.owners at hs
  have hw := s.get_spec x hx
  rw [hxl] at hw
  have hc := count_set s.locals x (.int 0) (.ref l) (.ref l) hw
  simp at hc
  have hL' : (s.locals.set x (.int 0)).count (.ref l) = 0 := by omega
  have hP : s.pending.count (.ref l) = 0 := by omega
  have hR : s.heap.refs l = 0 := by omega
  refine ⟨?_, ?_, ?_⟩
  · intro z w hz hzw hwl
    subst hwl
    have hmem : Val.ref l ∈ s.locals.set x (.int 0) := by
      have e : (s.locals.set x (.int 0))[z]? = some (.ref l) := by
        rw [List.getElem?_set_ne (Ne.symm hz)]; exact hzw
      exact List.mem_of_getElem? e
    have := List.count_pos_iff.mpr hmem
    omega
  · intro v hv hvl
    subst hvl
    have := List.count_pos_iff.mpr hv
    omega
  · intro m o' ho' v hv hvl
    subst hvl
    have h1 := Heap.cnt_le_refs s.heap m l (hwf.lt_next ho')
    have h2 : s.heap.cnt m l ≠ 0 := by
      unfold Heap.cnt; rw [ho']; simp only
      exact Nat.pos_iff_ne_zero.mp (List.count_pos_iff.mpr hv)
    omega

/-! ### store -/

/-- Everything `opStore` does when it succeeds. -/
theorem opStore_ok_spec {s s2 : St} (h : opStore s x i y = .ok s2) :
    ∃ l o old, x < s.locals.length ∧ y < s.locals.length ∧ s.get x = .ref l ∧
      s.heap.objs l = some o ∧ o.rc = 1 ∧ o.fields[i]? = some old ∧
      s.heap.LiveVal (s.get y) ∧
      s2 = { s with heap := (s.heap.setObj l { o with fields := o.fields.set i (s.get y) }).bump [s.get y],
                    pending := old :: s.pending } := by
  unfold opStore at h
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
        · rename_i hrc
          split at h
          · simp at h
          · rename_i old hold
            dsimp only at h
            split at h
            · rename_i hl
              simp at h
              refine ⟨l, o, old, hxy.1, hxy.2, hxl, ho, by simpa using hrc, hold,
                (liveb_iff _ _).mp hl, h.symm⟩
            · simp at h
  · simp at h

/-- A store through a local whose object has count 1 is never a memory-safety violation. -/
theorem opStore_unique_ok {s : St} (hwf : WF s) {x y i l : Nat} {o : Obj}
    (hx : x < s.locals.length) (hy : y < s.locals.length)
    (hxl : s.get x = .ref l) (ho : s.heap.objs l = some o) (hrc : o.rc = 1) :
    opStore s x i y ≠ .bad .shared ∧ opStore s x i y ≠ .bad .dead := by
  refine ⟨?_, opStore_not_dead hwf⟩
  intro h
  unfold opStore at h
  split at h
  · split at h
    · simp at h
    · rename_i l' hxl'
      rw [hxl] at hxl'; injection hxl' with e; subst e
      split at h
      · simp at h
      · rename_i o2 ho2
        rw [ho] at ho2; injection ho2 with e; subst e
        split at h
        · rename_i hne; exact absurd hrc hne
        · split at h
          · simp at h
          · dsimp only at h; split at h <;> simp at h
  · simp at h

/-- **Store frame / COW core.** A successful store through a count-1 local `x` changes the
observable value of nothing else: every live value other than the reference held by `x`
has the same view before and after. And the object now holds the stored value in slot `i`. -/
theorem store_frame {s s2 : St} (hwf : WF s) (h : opStore s x i y = .ok s2) :
    (∀ w, s.heap.LiveVal w → (∀ l, s.get x = .ref l → w ≠ .ref l) →
        ∀ f, view s2.heap f w = view s.heap f w) ∧
    s2.locals = s.locals ∧
    (∃ l o2, s.get x = .ref l ∧ s2.heap.objs l = some o2 ∧
        o2.fields.length = (s.heap.objs l).elim 0 (fun o => o.fields.length) ∧
        ∀ old, (s.heap.objs l).elim False (fun o => o.fields[i]? = some old) →
          o2.fields = (s.heap.objs l).elim [] (fun o => o.fields.set i (s.get y))) := by
  obtain ⟨l, o, old, hx, hy, hxl, ho, hrc, hold, hv, rfl⟩ := opStore_ok_spec h
  obtain ⟨_, _, hnoF⟩ := unique_facts hwf hx hxl ho hrc
  have hl := hwf.lt_next ho
  have hobj : ∀ m o1, (s.heap.setObj l { o with fields := o.fields.set i (s.get y) }).objs m = some o1 →
      m ≠ l → s.heap.objs m = some o1 := by
    intro m o1 h1 hm
    rw [setObj_objs] at h1; simpa [hm] using h1
  refine ⟨?_, rfl, ?_⟩
  · intro w hw hne f
    apply view_agree s.heap _ (fun m => m ≠ l ∧ ∃ o, s.heap.objs m = some o)
    · intro m hm; exact hm.2
    · intro m hm o1 ho1
      refine ⟨{ o1 with rc := o1.rc + [s.get y].count (.ref m) }, ?_, rfl⟩
      apply bump_objs_some
      rw [setObj_objs]; simp [hm.1, ho1]
    · intro m hm o1 ho1 v hv l' hl'
      subst hl'
      refine ⟨fun e => hnoF m o1 ho1 _ hv (by rw [e]), ?_⟩
      exact hwf.flds m o1 ho1 _ hv
    · intro l' hl'
      subst hl'
      exact ⟨fun e => hne l hxl (by rw [e]), hw⟩
  · refine ⟨l, ⟨o.rc + [s.get y].count (.ref l), o.fields.set i (s.get y)⟩, hxl, ?_, ?_, ?_⟩
    · exact bump_objs_some _ _ l ⟨o.rc, o.fields.set i (s.get y)⟩ (by rw [setObj_objs]; simp)
    · simp [ho]
    · intro old' _
      simp [ho]

/-! ### makeUnique -/

theorem opMakeUnique_spec {s s1 : St} (hwf : WF s) (h : opMakeUnique s x = .ok s1) :
    x < s.locals.length ∧ s1.locals.length = s.locals.length ∧
    (∀ z, z ≠ x → s1.locals[z]? = s.locals[z]?) ∧ s1.pending = s.pending ∧
    (∀ w, s.heap.LiveVal w → ∀ f, view s1.heap f w = view s.heap f w) ∧
    (∃ n o', s1.get x = .ref n ∧ s1.heap.objs n = some o' ∧ o'.rc = 1) ∧
    (∀ f, view s1.heap f (s1.get x) = view s.heap f (s.get x)) := by
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
        · rename_i hrc
          simp at h; subst h
          exact ⟨hx, rfl, fun _ _ => rfl, rfl, fun _ _ _ => rfl, ⟨l, o, hxl, ho, hrc⟩, fun _ => rfl⟩
        · rename_i hrc
          split at h
          · simp at h; subst h
            have hl := hwf.lt_next ho
            have hpos := hwf.rcpos l o ho
            have hfl := hwf.flds l o ho
            have hspec := muHeap_objs s.heap l o.fields o ho hl hpos
            have hviews : ∀ w, s.heap.LiveVal w → ∀ f,
                view (muHeap s.heap l o.fields) f w = view s.heap f w := by
              intro w hw f
              apply view_agree s.heap _ (fun m => ∃ o, s.heap.objs m = some o)
              · intro m hm; exact hm
              · intro m hm o1 ho1
                have hlv := muHeap_live s.heap l o.fields (.ref m) hm
                obtain ⟨o', ho'⟩ := hlv
                rcases hspec m o' ho' with ⟨hmn, _⟩ | ⟨_, oH, hoH, hf, _⟩
                · have := hwf.lt_next ho1; omega
                · rw [ho1] at hoH; cases hoH
                  exact ⟨o', ho', hf⟩
              · intro m hm o1 ho1 v hv l' hl'
                subst hl'
                exact hwf.flds m o1 ho1 _ hv
              · intro l' hl'; subst hl'; exact hw
            refine ⟨hx, by simp, ?_, rfl, hviews, ?_, ?_⟩
            · intro z hz
              show (s.locals.set x _)[z]? = _
              rw [List.getElem?_set_ne (Ne.symm hz)]
            · refine ⟨s.heap.next, ⟨1, o.fields⟩, ?_, muHeap_new s.heap l o.fields o ho hl hpos, rfl⟩
              show (s.locals.set x (.ref s.heap.next)).getD x (.int 0) = .ref s.heap.next
              simp [hx]
            · intro f
              have hg : (s.locals.set x (.ref s.heap.next)).getD x (.int 0) = .ref s.heap.next := by
                simp [hx]
              show view (muHeap s.heap l o.fields) f
                ((s.locals.set x (.ref s.heap.next)).getD x (.int 0)) = _
              rw [hg, hxl]
              cases f with
              | zero => simp [view]
              | succ f =>
                simp only [view, muHeap_new s.heap l o.fields o ho hl hpos, ho]
                congr 1
                apply List.map_congr_left
                intro v hv
                exact hviews v (hfl v hv) f
          · simp at h
  · simp at h

/-- After `makeUnique x`, the local `x` owns a live object whose count is 1. -/
theorem opMakeUnique_unique {s s1 : St} (hwf : WF s) (h : opMakeUnique s x = .ok s1) :
    ∃ n o', s1.get x = .ref n ∧ s1.heap.objs n = some o' ∧ o'.rc = 1 :=
  (opMakeUnique_spec hwf h).2.2.2.2.2.1

/-- `makeUnique` does not change the observable value of `x` (nor of anything else). -/
theorem makeUnique_view {s s1 : St} (hwf : WF s) (h : opMakeUnique s x = .ok s1) (f : Nat) :
    view s1.heap f (s1.get x) = view s.heap f (s.get x) :=
  (opMakeUnique_spec hwf h).2.2.2.2.2.2 f

/-- `store` immediately after `makeUnique` never reaches the bad state. -/
theorem store_after_makeUnique_safe {s s1 : St} (hwf : WF s) (h : opMakeUnique s x = .ok s1)
    (hy : y < s.locals.length) (i : Nat) :
    opStore s1 x i y ≠ .bad .shared ∧ opStore s1 x i y ≠ .bad .dead := by
  have hwf1 := opMakeUnique_wf hwf h
  obtain ⟨hx, hlen, _, _, _, ⟨n, o', hn, ho', hrc⟩, _⟩ := opMakeUnique_spec hwf h
  exact opStore_unique_ok hwf1 (by omega) (by omega) hn ho' hrc

/-- **Copy-on-write / value semantics.**
Run `makeUnique x; store x i y` from a well-formed state. Then every *other* local `z ≠ x`
and every pending-release entry observes exactly the same value afterwards as before, at every
depth. In particular an alias `z` of the old object keeps seeing the old contents. -/
theorem makeUnique_store_cow {s s1 s2 : St} (hwf : WF s)
    (h1 : opMakeUnique s x = .ok s1) (h2 : opStore s1 x i y = .ok s2) :
    (∀ z, z < s.locals.length → z ≠ x → ∀ f, view s2.heap f (s2.get z) = view s.heap f (s.get z)) ∧
    (∀ w ∈ s.pending, ∀ f, view s2.heap f w = view s.heap f w) := by
  have hwf1 := opMakeUnique_wf hwf h1
  obtain ⟨hx, hlen, hloc, hpend, hview, ⟨n, o', hn, ho', hrc⟩, _⟩ := opMakeUnique_spec hwf h1
  obtain ⟨hf1, hloc2, _⟩ := store_frame hwf1 h2
  have hx1 : x < s1.locals.length := by omega
  obtain ⟨hL, hPe, _⟩ := unique_facts hwf1 hx1 hn ho' hrc
  constructor
  · intro z hz hzx f
    have hg1 : s1.get z = s.get z := by
      simp [St.get, List.getD_eq_getElem?_getD, hloc z hzx]
    have hg2 : s2.get z = s1.get z := by simp [St.get, hloc2]
    rw [hg2, hg1]
    have hlive : s.heap.LiveVal (s.get z) := hwf.locs _ (s.get_mem z hz)
    have hzw : s1.locals[z]? = some (s1.get z) := s1.get_spec z (by omega)
    have hne : ∀ l, s1.get x = .ref l → s.get z ≠ .ref l := by
      intro l hl
      rw [hn] at hl; injection hl with e; subst e
      rw [← hg1]
      exact hL z _ hzx hzw
    have hlive1 : s1.heap.LiveVal (s.get z) := by
      rw [← hg1]; exact hwf1.locs _ (s1.get_mem z (by omega))
    have := hf1 (s.get z) hlive1 hne f
    rw [this]
    exact hview _ hlive f
  · intro w hw f
    have hlive : s.heap.LiveVal w := hwf.pend w hw
    have hne : ∀ l, s1.get x = .ref l → w ≠ .ref l := by
      intro l hl
      rw [hn] at hl; injection hl with e; subst e
      exact hPe w (by rw [hpend]; exact hw)
    have hlive1 : s1.heap.LiveVal w := by
      have := hwf1.pend w (by rw [hpend]; exact hw); exact this
    rw [hf1 w hlive1 hne f]
    exact hview _ hlive f

end Orin
