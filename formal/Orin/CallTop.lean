import Orin.CallStep

/-!
# Headline theorem for programs with calls

`prog_sound` : let `fns` be accepted by `pcheck` (every function passes the stand-alone check of
`fcheck`, calls are checked against the callees' signatures).  Enter any function whose parameters
are scalars or borrowed references, in a state that meets the caller contract (the same contract
as `check_sound`).  Then no reachable configuration of the call machine takes a `bad` step: no use
after free, no double free, no in-place store into an object that is not uniquely owned.  This
includes everything that happens inside callees, in any depth.
-/

namespace Orin
open Heap

variable {fns : List Fn}

theorem good_reach (hp : pcheck fns = true) {c d : Cfg2}
    (hG : Good (fns.map Fn.sig) c.stk (c.code, c.st)) (hr : CReach fns c d) :
    Good (fns.map Fn.sig) d.stk (d.code, d.st) := by
  induction hr with
  | refl => exact hG
  | step c c' d h _ ih =>
    rcases good_step hp hG with hn | ⟨r, hr, _, hok⟩
    · rw [hn] at h; cases h
    · rw [hr] at h
      cases h
      exact ih (hok _ rfl)

theorem good_safe (hp : pcheck fns = true) {c : Cfg2}
    (hG : Good (fns.map Fn.sig) c.stk (c.code, c.st)) : ∀ k, cstep fns c ≠ some (.bad k) := by
  intro k hh
  rcases good_step hp hG with hn | ⟨r, hr, hnb, _⟩
  · rw [hn] at hh; cases hh
  · rw [hr] at hh
    exact hnb k (Option.some.inj hh)

/-- Initial state of an entry function: the operands in the first locals, other locals zero. -/
def initFn (fn : Fn) (H : Heap) (vals : List Val) : St :=
  ⟨H, calleeLocals vals fn.n, []⟩

theorem entryFn_inv (fn : Fn) (hn : fn.params.length ≤ fn.n) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = fn.params.length) (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n)) :
    Inv ext fn.entry.ls (initFn fn H vals) := by
  have hlenE : fn.entry.ls.length = fn.n := by
    simp [Fn.entry, entryLs]; omega
  have hlenS : (initFn fn H vals).locals.length = fn.n :=
    calleeLocals_length _ _ (by omega)
  have hget : ∀ i, i < fn.params.length → (initFn fn H vals).get i = vals.getD i (.int 0) := by
    intro i hi
    exact getD_calleeLocals vals fn.n i (by omega)
  have hunc : ∀ j, (gk fn.entry.ls j).counted = false := by
    intro j
    show (gk (entryLs fn.params fn.n) j).counted = false
    rw [gk_entryLs]
    have := hno j
    cases hj : fn.params[j]? with
    | none => rfl
    | some m =>
      rw [hj] at this
      cases m <;> simp_all [modeK, AS.counted]
  refine ⟨by rw [hlenE, hlenS], ?_, fun i => ?_⟩
  · have hz : ∀ y ∈ projL fn.entry.ls (initFn fn H vals).locals, y = .int 0 := by
      intro y hy
      simp only [projL] at hy
      obtain ⟨j, hj, hjy⟩ := List.mem_iff_getElem.mp hy
      rw [List.getElem_mapIdx] at hjy
      rw [← hjy]
      simp [pv, hunc j]
    have := wf_locals ⟨H, ext, []⟩ hext (projL fn.entry.ls (initFn fn H vals).locals ++ ext)
      (by
        intro m
        have h0 : (projL fn.entry.ls (initFn fn H vals).locals).count (.ref m) = 0 := by
          rw [List.count_eq_zero]
          intro hm
          have := hz _ hm
          cases this
        rw [List.count_append, h0]; simp)
      (by
        intro v hv
        rcases List.mem_append.mp hv with h | h
        · rw [hz v h]; trivial
        · exact hext.locs v h)
    simpa [Pst, initFn] using this
  · have hk : gk fn.entry.ls i = match fn.params[i]? with | some m => modeK m | none => .dead :=
      gk_entryLs fn.params fn.n i
    cases hpi : fn.params[i]? with
    | none => rw [hpi] at hk; exact ClAt.of_dead hk
    | some m =>
      have hi : i < fn.params.length := by
        by_cases hc : i < fn.params.length
        · exact hc
        · rw [List.getElem?_eq_none (by omega)] at hpi; cases hpi
      cases m with
      | owned => exact absurd hpi (hno i)
      | scalar =>
        rw [hpi] at hk
        obtain ⟨n, hvn⟩ := hsc i hpi
        refine ClAt.of_init hk ⟨n, ?_⟩
        rw [hget i hi]; simp [List.getD_eq_getElem?_getD, hvn]
      | borrowed =>
        rw [hpi] at hk
        obtain ⟨l, q, hvl, hmem, hdesc⟩ := href i hpi
        have hg : (initFn fn H vals).get i = .ref l := by
          rw [hget i hi]; simp [List.getD_eq_getElem?_getD, hvl]
        have hk' : gk fn.entry.ls i = .param := hk
        refine ⟨?_, ?_, ?_, ?_, ?_⟩
        · intro e; simp [hk'] at e
        · intro e; simp [hk'] at e
        · intro _; exact ⟨q, hmem, by rw [hg]; exact hdesc⟩
        · intro r e; simp [hk'] at e
        · intro _; exact ⟨l, hg⟩

/-- **Headline theorem for programs.**  Every function of a `pcheck`-accepted program is safe to
enter (scalar and borrowed parameters), and the whole run, calls and returns included, never
takes a `bad` step. -/
theorem prog_sound (hp : pcheck fns = true) {f : Nat} {fn : Fn} (hf : fns[f]? = some fn)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c) :
    ∀ k, cstep fns c ≠ some (.bad k) := by
  have hfc : fcheck (fns.map Fn.sig) fn = true := by
    unfold pcheck at hp
    exact List.all_eq_true.mp hp fn (List.mem_of_getElem? hf)
  obtain ⟨hpn, hcontF⟩ := fcheck_cont hfc
  have hG : Good (fns.map Fn.sig) [] (fn.code, initFn fn H vals) :=
    ⟨ext, fn.params.length, retPred fn.ret fn.retRef, fn.entry, hcontF,
      entryFn_inv fn hpn ext H vals hlen hext hno href hsc, trivial, by intro fr rest h; cases h⟩
  exact good_safe hp (good_reach hp (c := ⟨[], fn.code, initFn fn H vals⟩) hG hr)

theorem prog_no_use_after_free (hp : pcheck fns = true) {f : Nat} {fn : Fn}
    (hf : fns[f]? = some fn)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c) :
    cstep fns c ≠ some (.bad .dead) :=
  prog_sound hp hf ext H vals hlen hext hno href hsc hr .dead

theorem prog_no_shared_store (hp : pcheck fns = true) {f : Nat} {fn : Fn}
    (hf : fns[f]? = some fn)
    (ext : List Val) (H : Heap) (vals : List Val) (hlen : vals.length = fn.params.length)
    (hext : WF ⟨H, ext, []⟩)
    (hno : ∀ i : Nat, fn.params[i]? ≠ some PM.owned)
    (href : ∀ i : Nat, fn.params[i]? = some PM.borrowed →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, fn.params[i]? = some PM.scalar → ∃ n, vals[i]? = some (Val.int n))
    {c : Cfg2} (hr : CReach fns ⟨[], fn.code, initFn fn H vals⟩ c) :
    cstep fns c ≠ some (.bad .shared) :=
  prog_sound hp hf ext H vals hlen hext hno href hsc hr .shared

end Orin
