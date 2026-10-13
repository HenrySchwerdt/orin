import Orin.Final

/-!
# Extra preservation lemmas for ownership-*transferring* operations

The lemmas of `WF.lean` cover operations that retain (`bump`) the value they copy.  MIR's
`move`/`structNew`/`setField`/`putField`/`takeField` instead *move* a count: from a local into
a heap slot or a fresh object (the count travels through the `pending` list in the proofs), or
from a heap slot into a local.  Same invariant `WF`, no reference count is touched.
-/

namespace Orin
open Heap

/-- Changing the locals to a list that has no more owners than before preserves `WF`. -/
theorem wf_locals (s : St) (hwf : WF s) (L : List Val)
    (hc : ∀ m, L.count (.ref m) ≤ s.locals.count (.ref m))
    (hl : ∀ v ∈ L, s.heap.LiveVal v) : WF { s with locals := L } := by
  constructor
  · exact hwf.rcpos
  · intro m o ho
    have h1 := hwf.sound m o ho
    have h2 := hc m
    simp only [St.owners] at *
    omega
  · exact hwf.bound
  · exact hl
  · exact hwf.pend
  · exact hwf.flds

/-- Move the count held in `c` (a prefix of the worklist) into slot `i` of a count-1 object. -/
theorem wf_store_take (s : St) (hwf : WF s) (l : Nat) (o : Obj) (ho : s.heap.objs l = some o)
    (i : Nat) (old : Val) (hold : o.fields[i]? = some old) (w : Val) (hw : s.heap.LiveVal w)
    (c rest : List Val) (hp : s.pending = c ++ rest)
    (hc : ∀ m, c.count (.ref m) = [w].count (.ref m)) :
    WF { s with heap := s.heap.setObj l { o with fields := o.fields.set i w },
                pending := old :: rest } := by
  have hl := hwf.lt_next ho
  have hH1 : ∀ m o1, (s.heap.setObj l { o with fields := o.fields.set i w }).objs m = some o1 →
      ∃ oH, s.heap.objs m = some oH ∧ o1.rc = oH.rc ∧
        (m = l → o1.fields = o.fields.set i w) ∧ (m ≠ l → o1.fields = oH.fields) := by
    intro m o1 h1
    rw [setObj_objs] at h1
    by_cases hm : m = l
    · subst hm
      simp at h1; subst h1
      exact ⟨o, ho, rfl, fun _ => rfl, fun h => absurd rfl h⟩
    · simp [hm] at h1
      exact ⟨o1, h1, rfl, fun h => absurd h hm, fun _ => rfl⟩
  have hrefs : ∀ m, (s.heap.setObj l { o with fields := o.fields.set i w }).refs m
      + o.fields.count (.ref m) = s.heap.refs m + (o.fields.set i w).count (.ref m) := by
    intro m
    have := refs_upd s.heap (s.heap.setObj l { o with fields := o.fields.set i w }) l m rfl hl
      (by intro k hk; simp [setObj_objs, hk])
    simpa [Heap.cnt, ho, setObj_objs] using this
  have hlive : ∀ v', s.heap.LiveVal v' →
      (s.heap.setObj l { o with fields := o.fields.set i w }).LiveVal v' := by
    intro v' h
    rw [setObj_live _ _ _ ⟨o, ho⟩]; exact h
  constructor
  · intro m o' ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o' ho'
    have := hwf.rcpos m oH hoH
    omega
  · intro m o' ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o' ho'
    have hs := hwf.sound m oH hoH
    have hc' := count_set o.fields i w old (.ref m) hold
    have hr := hrefs m
    have e1 : (old :: rest).count (.ref m)
        = rest.count (.ref m) + (if old = .ref m then 1 else 0) := by
      simp [List.count_cons]
    have e2 : s.pending.count (.ref m) = c.count (.ref m) + rest.count (.ref m) := by
      rw [hp, List.count_append]
    have e3 := hc m
    rw [count_single] at e3
    unfold St.owners at hs
    show s.locals.count (.ref m) + (old :: rest).count (.ref m)
        + (s.heap.setObj l { o with fields := o.fields.set i w }).refs m ≤ o'.rc
    omega
  · intro m hm
    rw [setObj_objs]
    have hm' : s.heap.next ≤ m := hm
    have : m ≠ l := by omega
    simp [this]; exact hwf.bound m hm'
  · intro v' hv'
    exact hlive v' (hwf.locs v' hv')
  · intro v' hv'
    rcases List.mem_cons.mp hv' with h | h
    · subst h; exact hlive _ (hwf.flds l o ho _ (List.mem_of_getElem? hold))
    · have : v' ∈ s.pending := by rw [hp]; exact List.mem_append_right _ h
      exact hlive v' (hwf.pend v' this)
  · intro m o' ho' v' hv'
    obtain ⟨oH, hoH, hrc, hf1, hf2⟩ := hH1 m o' ho'
    by_cases hm : m = l
    · have := hf1 hm
      subst hm
      have hoo : oH = o := by rw [ho] at hoH; exact (Option.some.inj hoH).symm
      subst hoo
      simp only [this] at hv'
      rcases List.mem_or_eq_of_mem_set hv' with h | h
      · exact hlive _ (hwf.flds m oH hoH _ h)
      · subst h; exact hlive _ hw
    · have := hf2 hm
      simp only [this] at hv'
      exact hlive _ (hwf.flds m oH hoH _ hv')

/-- Move the count held in `c` (a prefix of the worklist) into a fresh object (no retain). -/
theorem wf_alloc_take (s : St) (hwf : WF s) (x : Nat) (hx : x < s.locals.length)
    (vs : List Val) (hvs : ∀ v ∈ vs, s.heap.LiveVal v)
    (c rest : List Val) (hp : s.pending = c ++ rest)
    (hc : ∀ m, vs.count (.ref m) = c.count (.ref m)) :
    WF { s with heap := (s.heap.alloc vs).1,
                locals := s.locals.set x (.ref s.heap.next), pending := rest } := by
  have hw := s.get_spec x hx
  have hobj : ∀ k, (s.heap.alloc vs).1.objs k
      = if k = s.heap.next then some ⟨1, vs⟩ else s.heap.objs k := fun k => rfl
  have hrefs : ∀ l, (s.heap.alloc vs).1.refs l = s.heap.refs l + vs.count (.ref l) := by
    intro l; rw [refs_alloc]
  have hlive : ∀ v, s.heap.LiveVal v → (s.heap.alloc vs).1.LiveVal v := fun v hv =>
    alloc_live _ _ _ hv
  have hL0 := count_next_zero s.heap hwf.bound s.locals hwf.locs
  have hP0 := count_next_zero s.heap hwf.bound s.pending hwf.pend
  have hV0 := count_next_zero s.heap hwf.bound vs hvs
  have hF0 := hwf.fresh_refs
  have hrest0 : rest.count (.ref s.heap.next) = 0 := by
    have : s.pending.count (.ref s.heap.next) = c.count (.ref s.heap.next)
        + rest.count (.ref s.heap.next) := by rw [hp, List.count_append]
    omega
  constructor
  · intro m o' ho'
    rw [hobj] at ho'
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'; simp
    · simp [hm] at ho'
      exact hwf.rcpos m o' ho'
  · intro m o' ho'
    rw [hobj] at ho'
    have h2 := count_set s.locals x (.ref s.heap.next) (s.get x) (.ref m) hw
    have e2 : s.pending.count (.ref m) = c.count (.ref m) + rest.count (.ref m) := by
      rw [hp, List.count_append]
    have e3 := hc m
    simp only [St.owners, hrefs]
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'
      subst hm
      have hne : s.get x ≠ .ref s.heap.next := hwf.live_ne_next (hwf.locs _ (s.get_mem x hx))
      simp only [ite_true, if_neg hne] at h2
      simp only
      omega
    · simp [hm] at ho'
      have h1 := hwf.sound m o' ho'
      have hne : (Val.ref s.heap.next = Val.ref m) ↔ False := by simp [Ne.symm hm]
      simp only [hne, ite_false] at h2
      simp only [St.owners] at h1
      omega
  · intro m hm
    rw [hobj]
    have : m ≠ s.heap.next := by
      have : s.heap.next + 1 ≤ m := hm
      omega
    simp [this]
    exact hwf.bound m (by have : s.heap.next + 1 ≤ m := hm; omega)
  · intro v hv
    rcases List.mem_or_eq_of_mem_set hv with h | h
    · exact hlive v (hwf.locs v h)
    · subst h
      show ∃ o, (s.heap.alloc vs).1.objs s.heap.next = some o
      exact ⟨⟨1, vs⟩, by rw [hobj]; simp⟩
  · intro v hv
    have : v ∈ s.pending := by rw [hp]; exact List.mem_append_right _ hv
    exact hlive v (hwf.pend v this)
  · intro m o' ho' v hv
    rw [hobj] at ho'
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'
      exact hlive v (hvs v hv)
    · simp [hm] at ho'
      exact hlive v (hwf.flds m o' ho' v hv)

/-- Move the count in slot `i` of a count-1 object into local `d` (the slot becomes `int 0`). -/
theorem wf_take (s : St) (hwf : WF s) (d : Nat) (hd : d < s.locals.length)
    (l : Nat) (o : Obj) (ho : s.heap.objs l = some o)
    (i : Nat) (old : Val) (hold : o.fields[i]? = some old) :
    WF { s with heap := s.heap.setObj l { o with fields := o.fields.set i (.int 0) },
                locals := s.locals.set d old } := by
  have hw := s.get_spec d hd
  have hl := hwf.lt_next ho
  have hH1 : ∀ m o1, (s.heap.setObj l { o with fields := o.fields.set i (.int 0) }).objs m
      = some o1 →
      ∃ oH, s.heap.objs m = some oH ∧ o1.rc = oH.rc ∧
        (m = l → o1.fields = o.fields.set i (.int 0)) ∧ (m ≠ l → o1.fields = oH.fields) := by
    intro m o1 h1
    rw [setObj_objs] at h1
    by_cases hm : m = l
    · subst hm
      simp at h1; subst h1
      exact ⟨o, ho, rfl, fun _ => rfl, fun h => absurd rfl h⟩
    · simp [hm] at h1
      exact ⟨o1, h1, rfl, fun h => absurd h hm, fun _ => rfl⟩
  have hrefs : ∀ m, (s.heap.setObj l { o with fields := o.fields.set i (.int 0) }).refs m
      + o.fields.count (.ref m) = s.heap.refs m + (o.fields.set i (.int 0)).count (.ref m) := by
    intro m
    have := refs_upd s.heap (s.heap.setObj l { o with fields := o.fields.set i (.int 0) })
      l m rfl hl (by intro k hk; simp [setObj_objs, hk])
    simpa [Heap.cnt, ho, setObj_objs] using this
  have hlive : ∀ v', s.heap.LiveVal v' →
      (s.heap.setObj l { o with fields := o.fields.set i (.int 0) }).LiveVal v' := by
    intro v' h
    rw [setObj_live _ _ _ ⟨o, ho⟩]; exact h
  constructor
  · intro m o' ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o' ho'
    have := hwf.rcpos m oH hoH
    omega
  · intro m o' ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o' ho'
    have hs := hwf.sound m oH hoH
    have hc' := count_set o.fields i (.int 0) old (.ref m) hold
    have hr := hrefs m
    have h2 := count_set s.locals d old (s.get d) (.ref m) hw
    unfold St.owners at hs
    have hz : (Val.int 0 = Val.ref m) ↔ False := by simp
    simp only [hz, ite_false] at hc'
    show (s.locals.set d old).count (.ref m) + s.pending.count (.ref m)
        + (s.heap.setObj l { o with fields := o.fields.set i (.int 0) }).refs m ≤ o'.rc
    omega
  · intro m hm
    rw [setObj_objs]
    have hm' : s.heap.next ≤ m := hm
    have : m ≠ l := by omega
    simp [this]; exact hwf.bound m hm'
  · intro v' hv'
    rcases List.mem_or_eq_of_mem_set hv' with h | h
    · exact hlive v' (hwf.locs v' h)
    · subst h; exact hlive _ (hwf.flds l o ho _ (List.mem_of_getElem? hold))
  · intro v' hv'
    exact hlive v' (hwf.pend v' hv')
  · intro m o' ho' v' hv'
    obtain ⟨oH, hoH, hrc, hf1, hf2⟩ := hH1 m o' ho'
    by_cases hm : m = l
    · have := hf1 hm
      subst hm
      have hoo : oH = o := by rw [ho] at hoH; exact (Option.some.inj hoH).symm
      subst hoo
      simp only [this] at hv'
      rcases List.mem_or_eq_of_mem_set hv' with h | h
      · exact hlive _ (hwf.flds m oH hoH _ h)
      · subst h; trivial
    · have := hf2 hm
      simp only [this] at hv'
      exact hlive _ (hwf.flds m oH hoH _ hv')

end Orin
