import Orin.Machine

/-!
# Ownership-accounting invariant `WF` and its preservation by every primitive operation

`WF s` is the *RC-soundness* invariant: for every live object, its count is positive and
**at least** the number of owning references to it (owned locals + pending-release entries +
fields of live heap objects); no owning reference points at a freed or never-allocated
location. We prove `≥` rather than `=` on purpose: the real code generator is allowed to leak
("too high only costs memory", docs/architecture.md), and `≥` is exactly what no-use-after-free
needs. Leak-freedom (`=`) is *not* claimed.
-/

/-- case-split every `if` in context/goal, then arithmetic. -/
macro "splits" : tactic => `(tactic| (repeat' split at *) <;> omega)

namespace Orin
open Heap

def St.owners (s : St) (l : Nat) : Nat :=
  s.locals.count (.ref l) + s.pending.count (.ref l) + s.heap.refs l

structure WF (s : St) : Prop where
  rcpos : ∀ m o, s.heap.objs m = some o → 0 < o.rc
  sound : ∀ m o, s.heap.objs m = some o → s.owners m ≤ o.rc
  bound : ∀ m, s.heap.next ≤ m → s.heap.objs m = none
  locs : ∀ v ∈ s.locals, s.heap.LiveVal v
  pend : ∀ v ∈ s.pending, s.heap.LiveVal v
  flds : ∀ m o, s.heap.objs m = some o → ∀ v ∈ o.fields, s.heap.LiveVal v

/-! ### list helpers -/

theorem count_single (v a : Val) : [v].count a = if v = a then 1 else 0 := by
  simp [List.count_cons]

theorem count_set (xs : List Val) (i : Nat) (v w a : Val) (h : xs[i]? = some w) :
    (xs.set i v).count a + (if w = a then 1 else 0) = xs.count a + (if v = a then 1 else 0) := by
  induction xs generalizing i with
  | nil => simp at h
  | cons x xs ih =>
    cases i with
    | zero =>
      simp at h; subst h
      simp [List.count_cons]
      split <;> split <;> omega
    | succ i =>
      simp at h
      have := ih i h
      simp [List.count_cons]
      split <;> omega

theorem St.get_spec (s : St) (x : Nat) (h : x < s.locals.length) :
    s.locals[x]? = some (s.get x) := by
  simp [St.get, h]

theorem St.get_mem (s : St) (x : Nat) (h : x < s.locals.length) : s.get x ∈ s.locals := by
  have := s.get_spec x h
  exact List.mem_of_getElem? this

theorem count_next_zero (H : Heap) (hb : ∀ m, H.next ≤ m → H.objs m = none) (xs : List Val)
    (h : ∀ v ∈ xs, H.LiveVal v) : xs.count (.ref H.next) = 0 := by
  rw [List.count_eq_zero]
  intro hm
  obtain ⟨o, ho⟩ := h _ hm
  simp [hb H.next (Nat.le_refl _)] at ho

namespace WF

theorem lt_next {s : St} (hwf : WF s) {m : Nat} {o : Obj} (h : s.heap.objs m = some o) :
    m < s.heap.next := by
  by_cases hc : m < s.heap.next
  · exact hc
  · have := hwf.bound m (by omega)
    simp [this] at h

theorem live_ne_next {s : St} (hwf : WF s) {v : Val} (hv : s.heap.LiveVal v) :
    v ≠ .ref s.heap.next := by
  rintro rfl
  obtain ⟨o, ho⟩ := hv
  have := hwf.lt_next ho
  omega

theorem fresh_refs {s : St} (hwf : WF s) : s.heap.refs s.heap.next = 0 := by
  apply Heap.refs_zero
  intro m hm
  unfold Heap.cnt
  cases ho : s.heap.objs m with
  | none => rfl
  | some o =>
    simp only
    rw [List.count_eq_zero]
    intro hmem
    exact hwf.live_ne_next (hwf.flds m o ho _ hmem) rfl

end WF

/-! ### copy / load : duplicate a live value into a local -/

theorem wf_dupInto (s : St) (hwf : WF s) (y : Nat) (hy : y < s.locals.length) (v : Val)
    (hv : s.heap.LiveVal v) :
    WF { s.setL y v with heap := s.heap.bump [v] } := by
  have hw := s.get_spec y hy
  constructor
  · intro m o' ho'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    have := hwf.rcpos m o ho
    simp; omega
  · intro m o' ho'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    have h1 := hwf.sound m o ho
    have h2 := count_set s.locals y v (s.get y) (.ref m) hw
    rw [count_single] at *
    simp only [St.owners, St.setL, bump_refs] at *
    splits
  · intro m hm
    have := hwf.bound m hm
    exact (bump_objs_none _ _ _).mpr this
  · intro v' hv'
    simp only [St.setL, bump_live] at *
    rcases List.mem_or_eq_of_mem_set hv' with h | h
    · exact hwf.locs v' h
    · subst h; exact hv
  · intro v' hv'
    simp only [St.setL, bump_live] at *
    exact hwf.pend v' hv'
  · intro m o' ho' v' hv'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    simp only [St.setL, bump_live] at *
    exact hwf.flds m o ho v' hv'

theorem wf_retain (s : St) (hwf : WF s) (v : Val) :
    WF { s with heap := s.heap.bump [v] } := by
  constructor
  · intro m o' ho'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    have := hwf.rcpos m o ho
    simp; omega
  · intro m o' ho'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    have h1 := hwf.sound m o ho
    simp only [St.owners, bump_refs] at *
    omega
  · intro m hm
    exact (bump_objs_none _ _ _).mpr (hwf.bound m hm)
  · intro v' hv'
    simp only [bump_live] at *
    exact hwf.locs v' hv'
  · intro v' hv'
    simp only [bump_live] at *
    exact hwf.pend v' hv'
  · intro m o' ho' v' hv'
    obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
    simp only [bump_live] at *
    exact hwf.flds m o ho v' hv'

theorem wf_const (s : St) (hwf : WF s) (x : Nat) (hx : x < s.locals.length) (n : Int) :
    WF (s.setL x (.int n)) := by
  have hw := s.get_spec x hx
  constructor
  · exact hwf.rcpos
  · intro m o ho
    have h1 := hwf.sound m o ho
    have h2 := count_set s.locals x (.int n) (s.get x) (.ref m) hw
    simp only [St.owners, St.setL] at *
    simp at h2
    splits
  · exact hwf.bound
  · intro v hv
    rcases List.mem_or_eq_of_mem_set hv with h | h
    · exact hwf.locs v h
    · subst h; trivial
  · exact hwf.pend
  · exact hwf.flds

theorem wf_release (s : St) (hwf : WF s) (x : Nat) (hx : x < s.locals.length) :
    WF { s with locals := s.locals.set x (.int 0), pending := s.get x :: s.pending } := by
  have hw := s.get_spec x hx
  constructor
  · exact hwf.rcpos
  · intro m o ho
    have h1 := hwf.sound m o ho
    have h2 := count_set s.locals x (.int 0) (s.get x) (.ref m) hw
    simp only [St.owners, List.count_cons, beq_iff_eq] at *
    have h3 : (Val.int 0 = Val.ref m) ↔ False := by simp
    simp only [h3, ite_false] at h2
    by_cases e : s.get x = Val.ref m
    · simp only [e, ite_true] at h2 ⊢; omega
    · simp only [e, ite_false] at h2 ⊢; omega
  · exact hwf.bound
  · intro v hv
    rcases List.mem_or_eq_of_mem_set hv with h | h
    · exact hwf.locs v h
    · subst h; trivial
  · intro v hv
    rcases List.mem_cons.mp hv with h | h
    · subst h; exact hwf.locs _ (s.get_mem x hx)
    · exact hwf.pend v h
  · exact hwf.flds


/-! ### alloc -/

theorem wf_alloc (s : St) (hwf : WF s) (x : Nat) (hx : x < s.locals.length) (vs : List Val)
    (hvs : ∀ v ∈ vs, s.heap.LiveVal v) :
    WF { s with heap := ((s.heap.bump vs).alloc vs).1,
                locals := s.locals.set x (.ref s.heap.next) } := by
  have hw := s.get_spec x hx
  have hobj : ∀ k, ((s.heap.bump vs).alloc vs).1.objs k
      = if k = s.heap.next then some ⟨1, vs⟩ else (s.heap.bump vs).objs k := fun k => rfl
  have hrefs : ∀ l, ((s.heap.bump vs).alloc vs).1.refs l = s.heap.refs l + vs.count (.ref l) := by
    intro l; rw [refs_alloc, bump_refs]
  have hlive : ∀ v, s.heap.LiveVal v →
      ((s.heap.bump vs).alloc vs).1.LiveVal v := fun v hv =>
    alloc_live _ _ _ ((bump_live _ _ _).mpr hv)
  have hL0 := count_next_zero s.heap hwf.bound s.locals hwf.locs
  have hP0 := count_next_zero s.heap hwf.bound s.pending hwf.pend
  have hV0 := count_next_zero s.heap hwf.bound vs hvs
  have hF0 := hwf.fresh_refs
  constructor
  · intro m o' ho'
    rw [hobj] at ho'
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'; simp
    · simp [hm] at ho'
      obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
      have := hwf.rcpos m o ho
      simp; omega
  · intro m o' ho'
    rw [hobj] at ho'
    have h2 := count_set s.locals x (.ref s.heap.next) (s.get x) (.ref m) hw
    simp only [St.owners, hrefs]
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'
      subst hm
      have hne : s.get x ≠ .ref s.heap.next := hwf.live_ne_next (hwf.locs _ (s.get_mem x hx))
      simp only [ite_true, if_neg hne] at h2
      simp only
      omega
    · simp [hm] at ho'
      obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
      have h1 := hwf.sound m o ho
      have hne : (Val.ref s.heap.next = Val.ref m) ↔ False := by simp [Ne.symm hm]
      simp only [hne, ite_false] at h2
      simp only [St.owners] at h1
      simp only
      omega
  · intro m hm
    rw [hobj]
    have : m ≠ s.heap.next := by
      have : s.heap.next + 1 ≤ m := hm
      omega
    simp [this]
    exact (bump_objs_none _ _ _).mpr (hwf.bound m (by have : s.heap.next + 1 ≤ m := hm; omega))
  · intro v hv
    rcases List.mem_or_eq_of_mem_set hv with h | h
    · exact hlive v (hwf.locs v h)
    · subst h
      show ∃ o, ((s.heap.bump vs).alloc vs).1.objs s.heap.next = some o
      exact ⟨⟨1, vs⟩, by rw [hobj]; simp⟩
  · intro v hv
    exact hlive v (hwf.pend v hv)
  · intro m o' ho' v hv
    rw [hobj] at ho'
    by_cases hm : m = s.heap.next
    · simp [hm] at ho'; subst ho'
      exact hlive v (hvs v hv)
    · simp [hm] at ho'
      obtain ⟨o, ho, rfl⟩ := bump_inv _ _ _ _ ho'
      exact hlive v (hwf.flds m o ho v hv)


/-! ### store -/

theorem wf_store (s : St) (hwf : WF s) (l : Nat) (o : Obj) (ho : s.heap.objs l = some o)
    (i : Nat) (old : Val) (hold : o.fields[i]? = some old) (v : Val) (hv : s.heap.LiveVal v) :
    WF { s with heap := (s.heap.setObj l { o with fields := o.fields.set i v }).bump [v],
                pending := old :: s.pending } := by
  have hl := hwf.lt_next ho
  have hH1 : ∀ m o1, (s.heap.setObj l { o with fields := o.fields.set i v }).objs m = some o1 →
      ∃ oH, s.heap.objs m = some oH ∧ o1.rc = oH.rc ∧
        (m = l → o1.fields = o.fields.set i v) ∧ (m ≠ l → o1.fields = oH.fields) := by
    intro m o1 h1
    rw [setObj_objs] at h1
    by_cases hm : m = l
    · subst hm
      simp at h1; subst h1
      exact ⟨o, ho, rfl, fun _ => rfl, fun h => absurd rfl h⟩
    · simp [hm] at h1
      exact ⟨o1, h1, rfl, fun h => absurd h hm, fun _ => rfl⟩
  have hrefs : ∀ m, (s.heap.setObj l { o with fields := o.fields.set i v }).refs m
      + o.fields.count (.ref m) = s.heap.refs m + (o.fields.set i v).count (.ref m) := by
    intro m
    have := refs_upd s.heap (s.heap.setObj l { o with fields := o.fields.set i v }) l m rfl hl
      (by intro k hk; simp [setObj_objs, hk])
    simpa [Heap.cnt, ho, setObj_objs] using this
  have hlive : ∀ v', s.heap.LiveVal v' →
      ((s.heap.setObj l { o with fields := o.fields.set i v }).bump [v]).LiveVal v' := by
    intro v' h
    rw [bump_live, setObj_live _ _ _ ⟨o, ho⟩]; exact h
  constructor
  · intro m o' ho'
    obtain ⟨o1, h1, rfl⟩ := bump_inv _ _ _ _ ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o1 h1
    have := hwf.rcpos m oH hoH
    simp; omega
  · intro m o' ho'
    obtain ⟨o1, h1, rfl⟩ := bump_inv _ _ _ _ ho'
    obtain ⟨oH, hoH, hrc, _, _⟩ := hH1 m o1 h1
    have hs := hwf.sound m oH hoH
    have hc := count_set o.fields i v old (.ref m) hold
    have hr := hrefs m
    have e1 : (old :: s.pending).count (.ref m)
        = s.pending.count (.ref m) + (if old = .ref m then 1 else 0) := by
      simp [List.count_cons]
    show s.locals.count (.ref m) + (old :: s.pending).count (.ref m)
        + ((s.heap.setObj l { o with fields := o.fields.set i v }).bump [v]).refs m
        ≤ o1.rc + [v].count (.ref m)
    rw [bump_refs, e1, count_single, hrc]
    unfold St.owners at hs
    omega
  · intro m hm
    exact (bump_objs_none _ _ _).mpr (by
      rw [setObj_objs]
      have hm' : s.heap.next ≤ m := hm
      have : m ≠ l := by omega
      simp [this]; exact hwf.bound m hm')
  · intro v' hv'
    exact hlive v' (hwf.locs v' hv')
  · intro v' hv'
    rcases List.mem_cons.mp hv' with h | h
    · subst h; exact hlive _ (hwf.flds l o ho _ (List.mem_of_getElem? hold))
    · exact hlive v' (hwf.pend v' h)
  · intro m o' ho' v' hv'
    obtain ⟨o1, h1, rfl⟩ := bump_inv _ _ _ _ ho'
    obtain ⟨oH, hoH, hrc, hf1, hf2⟩ := hH1 m o1 h1
    by_cases hm : m = l
    · have := hf1 hm
      subst hm
      have hoo : oH = o := by rw [ho] at hoH; exact (Option.some.inj hoH).symm
      subst hoo
      simp only [this] at hv'
      rcases List.mem_or_eq_of_mem_set hv' with h | h
      · exact hlive _ (hwf.flds m oH hoH _ h)
      · subst h; exact hlive _ hv
    · have := hf2 hm
      simp only [this] at hv'
      exact hlive _ (hwf.flds m oH hoH _ hv')


/-! ### makeUnique (shared case) -/

/-- Heap after `orin_make_unique` on a shared object `l` whose fields are `fs`:
retain children, allocate the shallow copy, drop one count of `l`. -/
def muHeap (H : Heap) (l : Nat) (fs : List Val) : Heap :=
  (((H.bump fs).alloc fs).1).decRc l

theorem muHeap_next (H : Heap) (l fs) : (muHeap H l fs).next = H.next + 1 := by
  unfold muHeap Heap.decRc
  cases h : ((H.bump fs).alloc fs).1.objs l <;> simp [Heap.setObj, Heap.alloc, h, Heap.bump]

theorem muHeap_objs (H : Heap) (l : Nat) (fs : List Val) (o : Obj) (ho : H.objs l = some o)
    (hl : l < H.next) (hpos : 0 < o.rc) (k : Nat) (o' : Obj) (h : (muHeap H l fs).objs k = some o') :
    (k = H.next ∧ o' = ⟨1, fs⟩) ∨
    (k ≠ H.next ∧ ∃ oH, H.objs k = some oH ∧ o'.fields = oH.fields ∧
      o'.rc + (if k = l then 1 else 0) = oH.rc + fs.count (.ref k)) := by
  have hobj : ((H.bump fs).alloc fs).1.objs l = some ⟨o.rc + fs.count (.ref l), o.fields⟩ := by
    show (if l = H.next then _ else (H.bump fs).objs l) = _
    rw [if_neg (by omega)]
    exact bump_objs_some _ _ _ _ ho
  have hm : muHeap H l fs = ((H.bump fs).alloc fs).1.setObj l
      ⟨o.rc + fs.count (.ref l) - 1, o.fields⟩ := by
    unfold muHeap Heap.decRc; rw [hobj]
  rw [hm, setObj_objs] at h
  by_cases hk : k = l
  · subst hk
    simp at h; subst h
    right
    refine ⟨by omega, o, ho, rfl, ?_⟩
    simp; omega
  · simp [hk] at h
    change (if k = H.next then _ else (H.bump fs).objs k) = _ at h
    by_cases hn : k = H.next
    · rw [if_pos hn] at h; left; exact ⟨hn, (Option.some.inj h).symm⟩
    · rw [if_neg hn] at h
      obtain ⟨oH, hoH, rfl⟩ := bump_inv _ _ _ _ h
      right
      exact ⟨hn, oH, hoH, rfl, by simp [hk]⟩


theorem muHeap_new (H : Heap) (l : Nat) (fs : List Val) (o : Obj) (ho : H.objs l = some o)
    (hl : l < H.next) (hpos : 0 < o.rc) : (muHeap H l fs).objs H.next = some ⟨1, fs⟩ := by
  have hobj : ((H.bump fs).alloc fs).1.objs l = some ⟨o.rc + fs.count (.ref l), o.fields⟩ := by
    show (if l = H.next then _ else (H.bump fs).objs l) = _
    rw [if_neg (by omega)]
    exact bump_objs_some _ _ _ _ ho
  unfold muHeap Heap.decRc
  rw [hobj]
  simp only []
  rw [setObj_objs, if_neg (by omega : ¬ H.next = l)]
  simp [Heap.alloc, Heap.bump]

theorem decRc_next (H : Heap) (l : Nat) : (H.decRc l).next = H.next := by
  unfold Heap.decRc; cases H.objs l <;> rfl

theorem decRc_cnt (H : Heap) (l k m : Nat) : (H.decRc l).cnt k m = H.cnt k m := by
  unfold Heap.decRc
  cases hl : H.objs l with
  | none => rfl
  | some o =>
    simp only [Heap.cnt, setObj_objs]
    by_cases hk : k = l
    · subst hk; simp [hl]
    · simp [hk]

theorem decRc_refs (H : Heap) (l m : Nat) : (H.decRc l).refs m = H.refs m :=
  refs_same _ _ m (decRc_next H l) (fun k => decRc_cnt H l k m)

theorem decRc_live (H : Heap) (l : Nat) (v : Val) : (H.decRc l).LiveVal v ↔ H.LiveVal v := by
  unfold Heap.decRc
  cases hl : H.objs l with
  | none => exact Iff.rfl
  | some o => exact setObj_live _ _ _ ⟨o, hl⟩ v

theorem muHeap_refs (H : Heap) (l : Nat) (fs : List Val) (m : Nat) :
    (muHeap H l fs).refs m = H.refs m + fs.count (.ref m) := by
  unfold muHeap
  rw [decRc_refs, refs_alloc, bump_refs]

theorem muHeap_live (H : Heap) (l : Nat) (fs : List Val) (v : Val) (hv : H.LiveVal v) :
    (muHeap H l fs).LiveVal v := by
  unfold muHeap
  exact (decRc_live _ _ _).mpr (alloc_live _ _ _ ((bump_live _ _ _).mpr hv))

theorem wf_makeUnique (s : St) (hwf : WF s) (x : Nat) (hx : x < s.locals.length) (l : Nat) (o : Obj)
    (hxl : s.get x = .ref l) (ho : s.heap.objs l = some o) (hrc : o.rc ≠ 1) :
    WF { s with heap := muHeap s.heap l o.fields,
                locals := s.locals.set x (.ref s.heap.next) } := by
  have hw := s.get_spec x hx
  rw [hxl] at hw
  have hl := hwf.lt_next ho
  have hpos := hwf.rcpos l o ho
  have hfl := hwf.flds l o ho
  have hspec := muHeap_objs s.heap l o.fields o ho hl hpos
  have hL0 := count_next_zero s.heap hwf.bound s.locals hwf.locs
  have hP0 := count_next_zero s.heap hwf.bound s.pending hwf.pend
  have hV0 := count_next_zero s.heap hwf.bound o.fields hfl
  have hF0 := hwf.fresh_refs
  have hlive := muHeap_live s.heap l o.fields
  have hrefs := muHeap_refs s.heap l o.fields
  have hnext := muHeap_next s.heap l o.fields
  constructor
  · intro m o' ho'
    rcases hspec m o' ho' with ⟨_, rfl⟩ | ⟨hm, oH, hoH, _, hr⟩
    · simp
    · have := hwf.rcpos m oH hoH
      by_cases hml : m = l
      · subst hml
        rw [ho] at hoH; cases hoH
        simp at hr; omega
      · simp [hml] at hr; omega
  · intro m o' ho'
    show (s.locals.set x (.ref s.heap.next)).count (.ref m) + s.pending.count (.ref m)
        + (muHeap s.heap l o.fields).refs m ≤ o'.rc
    rw [hrefs]
    have h2 := count_set s.locals x (.ref s.heap.next) (.ref l) (.ref m) hw
    rcases hspec m o' ho' with ⟨hm, rfl⟩ | ⟨hm, oH, hoH, _, hr⟩
    · subst hm
      have hne : (Val.ref l = Val.ref s.heap.next) ↔ False := by simp; omega
      simp only [hne, ite_false, ite_true] at h2
      simp only
      omega
    · have hs := hwf.sound m oH hoH
      unfold St.owners at hs
      have hne : (Val.ref s.heap.next = Val.ref m) ↔ False := by simp [Ne.symm hm]
      simp only [hne, ite_false] at h2
      by_cases hml : m = l
      · subst hml
        simp at hr h2
        omega
      · have : (Val.ref l = Val.ref m) ↔ False := by simp [Ne.symm hml]
        simp only [this, ite_false] at h2
        simp [hml] at hr
        omega
  · intro m hm
    have hm' : s.heap.next + 1 ≤ m := by rw [← hnext]; exact hm
    by_cases h : (muHeap s.heap l o.fields).objs m = none
    · exact h
    · obtain ⟨o', ho'⟩ := Option.ne_none_iff_exists'.mp h
      rcases hspec m o' ho' with ⟨hm2, _⟩ | ⟨_, oH, hoH, _⟩
      · omega
      · have := hwf.lt_next hoH; omega
  · intro v hv
    rcases List.mem_or_eq_of_mem_set hv with h | h
    · exact hlive v (hwf.locs v h)
    · subst h
      exact ⟨⟨1, o.fields⟩, muHeap_new s.heap l o.fields o ho hl hpos⟩
  · intro v hv
    exact hlive v (hwf.pend v hv)
  · intro m o' ho' v hv
    rcases hspec m o' ho' with ⟨_, rfl⟩ | ⟨hm, oH, hoH, hf, _⟩
    · exact hlive v (hfl v hv)
    · rw [hf] at hv; exact hlive v (hwf.flds m oH hoH v hv)


/-! ### drain -/

theorem del_objs (H : Heap) (l k : Nat) : (H.del l).objs k = if k = l then none else H.objs k := rfl

theorem del_live (H : Heap) (l : Nat) (v : Val) (hv : H.LiveVal v) (hne : v ≠ .ref l) :
    (H.del l).LiveVal v := by
  cases v with
  | int n => trivial
  | ref k =>
    have : k ≠ l := fun h => hne (by rw [h])
    obtain ⟨o, ho⟩ := hv
    exact ⟨o, by rw [del_objs, if_neg this]; exact ho⟩

theorem decRc_objs (H : Heap) (l : Nat) (o : Obj) (ho : H.objs l = some o) (k : Nat) :
    (H.decRc l).objs k = if k = l then some { o with rc := o.rc - 1 } else H.objs k := by
  unfold Heap.decRc; rw [ho]; rfl

theorem wf_drain_int (s : St) (hwf : WF s) (n : Int) (rest : List Val)
    (hp : s.pending = .int n :: rest) : WF { s with pending := rest } := by
  have h1 : ∀ m, s.pending.count (.ref m) = rest.count (.ref m) := by
    intro m; rw [hp]; simp [List.count_cons]
  constructor
  · exact hwf.rcpos
  · intro m o ho
    have := hwf.sound m o ho
    simp only [St.owners, h1] at *
    exact this
  · exact hwf.bound
  · exact hwf.locs
  · intro v hv; exact hwf.pend v (by rw [hp]; exact List.mem_cons_of_mem _ hv)
  · exact hwf.flds

theorem wf_drain_dec (s : St) (hwf : WF s) (l : Nat) (rest : List Val) (o : Obj)
    (hp : s.pending = .ref l :: rest) (ho : s.heap.objs l = some o) (h1 : o.rc ≠ 0) (h2 : o.rc ≠ 1) :
    WF { s with heap := s.heap.decRc l, pending := rest } := by
  have hpc : ∀ m, s.pending.count (.ref m) = rest.count (.ref m) + (if m = l then 1 else 0) := by
    intro m; rw [hp]; simp [List.count_cons]
    by_cases h : m = l
    · subst h; simp
    · simp [h, Ne.symm h]
  have hobj := decRc_objs s.heap l o ho
  constructor
  · intro m o' ho'
    rw [hobj] at ho'
    by_cases hm : m = l
    · simp [hm] at ho'; subst ho'; simp; omega
    · simp [hm] at ho'; exact hwf.rcpos m o' ho'
  · intro m o' ho'
    show s.locals.count (.ref m) + rest.count (.ref m) + (s.heap.decRc l).refs m ≤ o'.rc
    rw [decRc_refs]
    rw [hobj] at ho'
    by_cases hm : m = l
    · subst hm
      simp at ho'; subst ho'
      have := hwf.sound m o ho
      have := hpc m
      unfold St.owners at *
      simp at *
      omega
    · simp [hm] at ho'
      have := hwf.sound m o' ho'
      have := hpc m
      unfold St.owners at *
      simp [hm] at *
      omega
  · intro m hm
    have hm' : s.heap.next ≤ m := by
      have e := decRc_next s.heap l
      have hm2 : (s.heap.decRc l).next ≤ m := hm
      omega
    rw [hobj]
    have hl := hwf.lt_next ho
    have : m ≠ l := by omega
    simp [this]
    exact hwf.bound m hm'
  · intro v hv; exact (decRc_live _ _ _).mpr (hwf.locs v hv)
  · intro v hv; exact (decRc_live _ _ _).mpr (hwf.pend v (by rw [hp]; exact List.mem_cons_of_mem _ hv))
  · intro m o' ho' v hv
    rw [hobj] at ho'
    by_cases hm : m = l
    · simp [hm] at ho'; subst ho'; subst hm
      exact (decRc_live _ _ _).mpr (hwf.flds m o ho v hv)
    · simp [hm] at ho'
      exact (decRc_live _ _ _).mpr (hwf.flds m o' ho' v hv)

theorem wf_drain_free (s : St) (hwf : WF s) (l : Nat) (rest : List Val) (o : Obj)
    (hp : s.pending = .ref l :: rest) (ho : s.heap.objs l = some o) (h1 : o.rc = 1) :
    WF { s with heap := s.heap.del l, pending := o.fields ++ rest } := by
  have hl := hwf.lt_next ho
  have hpc : ∀ m, s.pending.count (.ref m) = rest.count (.ref m) + (if m = l then 1 else 0) := by
    intro m; rw [hp]; simp [List.count_cons]
    by_cases h : m = l
    · subst h; simp
    · simp [h, Ne.symm h]
  -- the freed object has no other owner
  have hs := hwf.sound l o ho
  have hpl := hpc l
  unfold St.owners at hs
  simp at hpl
  have hL : s.locals.count (.ref l) = 0 := by omega
  have hR : rest.count (.ref l) = 0 := by omega
  have hH : s.heap.refs l = 0 := by omega
  have hnoL : ∀ v ∈ s.locals, v ≠ .ref l := fun v hv e => by
    subst e; have := List.count_pos_iff.mpr hv; omega
  have hnoR : ∀ v ∈ rest, v ≠ .ref l := fun v hv e => by
    subst e; have := List.count_pos_iff.mpr hv; omega
  have hnoF : ∀ m o', s.heap.objs m = some o' → ∀ v ∈ o'.fields, v ≠ .ref l := by
    intro m o' ho' v hv e
    subst e
    have := Heap.cnt_le_refs s.heap m l (hwf.lt_next ho')
    have h2 : s.heap.cnt m l ≠ 0 := by
      unfold Heap.cnt; rw [ho']; simp only
      exact Nat.pos_iff_ne_zero.mp (List.count_pos_iff.mpr hv)
    omega
  have hrefs : ∀ m, (s.heap.del l).refs m + o.fields.count (.ref m) = s.heap.refs m := by
    intro m
    have := refs_upd s.heap (s.heap.del l) l m rfl hl (by intro k hk; simp [del_objs, hk])
    simpa [Heap.cnt, ho, del_objs] using this
  constructor
  · intro m o' ho'
    rw [del_objs] at ho'
    by_cases hm : m = l
    · simp [hm] at ho'
    · simp [hm] at ho'; exact hwf.rcpos m o' ho'
  · intro m o' ho'
    rw [del_objs] at ho'
    by_cases hm : m = l
    · simp [hm] at ho'
    · simp [hm] at ho'
      have := hwf.sound m o' ho'
      have := hpc m
      have := hrefs m
      show s.locals.count (.ref m) + (o.fields ++ rest).count (.ref m) + (s.heap.del l).refs m ≤ o'.rc
      rw [List.count_append]
      unfold St.owners at *
      simp [hm] at *
      omega
  · intro m hm
    rw [del_objs]
    by_cases h : m = l
    · simp [h]
    · simp [h]; exact hwf.bound m hm
  · intro v hv; exact del_live _ _ _ (hwf.locs v hv) (hnoL v hv)
  · intro v hv
    rcases List.mem_append.mp hv with h | h
    · exact del_live _ _ _ (hwf.flds l o ho v h) (hnoF l o ho v h)
    · have h' : v ∈ s.pending := by rw [hp]; exact List.mem_cons_of_mem _ h
      exact del_live _ _ _ (hwf.pend v h') (hnoR v h)
  · intro m o' ho' v hv
    rw [del_objs] at ho'
    by_cases hm : m = l
    · simp [hm] at ho'
    · simp [hm] at ho'
      exact del_live _ _ _ (hwf.flds m o' ho' v hv) (hnoF m o' ho' v hv)

theorem wf_drain (s s' : St) (hwf : WF s) (h : drain s = .ok s') : WF s' := by
  unfold drain at h
  split at h
  · simp at h
  · rename_i n rest hp
    simp at h; subst h
    exact wf_drain_int s hwf n rest hp
  · rename_i l rest hp
    split at h
    · simp at h
    · rename_i o ho
      split at h
      · simp at h
      · rename_i hr0
        split at h
        · rename_i hr1
          simp at h; subst h
          exact wf_drain_free s hwf l rest o hp ho hr1
        · rename_i hr1
          simp at h; subst h
          exact wf_drain_dec s hwf l rest o hp ho hr0 hr1

end Orin
