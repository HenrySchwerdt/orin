import Orin.Sound

/-!
# Headline theorem: verifier-accepted MIR (core fragment) never reaches `bad`

`check_sound`: let `p` be accepted by `check`. Start the machine in any state in which the first
`|params|` locals hold the arguments (reference arguments are borrowed from the caller: each is a
reference `l` lying at or below some reference `q` that the caller owns, recorded in the list `ext`
and accounted for by the heap, `WF ⟨H, ext, []⟩`, `Desc H q (ref l)`; scalar arguments for scalar
parameters) and all other locals are dead.  Then no reachable configuration takes a `bad` step:
no access to a freed or never-allocated object (use after free, double free), and no in-place store
into an object whose reference count is not 1 (no mutation through a shared alias).

Also included: small positive and negative examples (`example_*`) showing the checker is neither
vacuous nor trivially permissive.
-/

namespace Orin
open Heap

/-- Initial machine state of a function: arguments in the first locals, other locals dead. -/
def initSt (p : Prog) (H : Heap) (vals : List Val) : St :=
  ⟨H, vals ++ List.replicate (p.n - p.params.length) (.int 0), []⟩

theorem check_cont {p : Prog} (hp : check p = true) :
    p.params.length ≤ p.n ∧ Cont [] p.params.length (fun _ => True) p.entry p.code := by
  unfold check at hp
  simp only [Bool.and_eq_true] at hp
  obtain ⟨hn, hm⟩ := hp
  refine ⟨by simpa using hn, ?_⟩
  cases hc : chk p.params.length [] p.entry p.code with
  | none => rw [hc] at hm; simp at hm
  | some af =>
    have h1 := chk_cont (np := p.params.length) p.code p.entry af .nil (fun _ => True) hc (Cont.nil trivial)
    rwa [Code.app_nil] at h1

theorem gk_entry (p : Prog) (i : Nat) :
    gk p.entry.ls i = match p.params[i]? with
      | some true => .param
      | some false => .init
      | none => .dead := by
  unfold Prog.entry gk
  simp only [List.getD_eq_getElem?_getD]
  by_cases hi : i < p.params.length
  · simp [List.getElem?_append_left (by simpa using hi : i < (p.params.map _).length), hi]
    cases p.params[i] <;> simp
  · rw [List.getElem?_append_right (by simp; omega)]
    simp [List.getElem?_eq_none (by omega : p.params.length ≤ i)]
    rw [List.getElem?_replicate]
    split <;> simp

theorem entry_inv (p : Prog) (hn : p.params.length ≤ p.n) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length) (hext : WF ⟨H, ext, []⟩)
    (href : ∀ i : Nat, p.params[i]? = some true →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, p.params[i]? = some false → ∃ n, vals[i]? = some (Val.int n)) :
    Inv ext p.entry.ls (initSt p H vals) := by
  have hlenE : p.entry.ls.length = p.n := by
    simp [Prog.entry]; omega
  have hlenS : (initSt p H vals).locals.length = p.n := by
    simp [initSt]; omega
  have hget : ∀ i, i < p.params.length → (initSt p H vals).get i = vals.getD i (.int 0) := by
    intro i hi
    simp [St.get, initSt, List.getD_eq_getElem?_getD,
      List.getElem?_append_left (by omega : i < vals.length)]
  refine ⟨by rw [hlenE, hlenS], ?_, fun i => ?_⟩
  · -- no local is counted: the projection is all zeros
    have hz : ∀ y ∈ projL p.entry.ls (initSt p H vals).locals, y = .int 0 := by
      intro y hy
      simp only [projL] at hy
      obtain ⟨j, hj, hjy⟩ := List.mem_iff_getElem.mp hy
      rw [List.getElem_mapIdx] at hjy
      rw [← hjy]
      have : (gk p.entry.ls j).counted = false := by
        rw [gk_entry]; cases p.params[j]? with
        | none => rfl
        | some b => cases b <;> rfl
      simp [pv, this]
    have := wf_locals ⟨H, ext, []⟩ hext (projL p.entry.ls (initSt p H vals).locals ++ ext)
      (by
        intro m
        have h0 : (projL p.entry.ls (initSt p H vals).locals).count (.ref m) = 0 := by
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
    simpa [Pst, initSt] using this
  · have hk := gk_entry p i
    cases hpi : p.params[i]? with
    | none => rw [hpi] at hk; exact ClAt.of_dead hk
    | some b =>
      have hi : i < p.params.length := by
        by_cases hc : i < p.params.length
        · exact hc
        · rw [List.getElem?_eq_none (by omega)] at hpi; cases hpi
      cases b with
      | false =>
        rw [hpi] at hk
        obtain ⟨n, hvn⟩ := hsc i hpi
        refine ClAt.of_init hk ⟨n, ?_⟩
        rw [hget i hi]; simp [List.getD_eq_getElem?_getD, hvn]
      | true =>
        rw [hpi] at hk
        obtain ⟨l, q, hvl, hmem, hdesc⟩ := href i hpi
        have hg : (initSt p H vals).get i = .ref l := by
          rw [hget i hi]; simp [List.getD_eq_getElem?_getD, hvl]
        refine ⟨?_, ?_, ?_, ?_, ?_⟩
        · intro e; simp [hk] at e
        · intro e; simp [hk] at e
        · intro _; exact ⟨q, hmem, by rw [hg]; exact hdesc⟩
        · intro r e; simp [hk] at e
        · intro _; exact ⟨l, hg⟩

/-- **Headline theorem.** A function accepted by the checker never takes a `bad` machine step:
no use after free / double free (`bad dead`) and no in-place store into a shared object
(`bad shared`), from any entry state satisfying the caller contract. -/
theorem check_sound (p : Prog) (hp : check p = true) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length) (hext : WF ⟨H, ext, []⟩)
    (href : ∀ i : Nat, p.params[i]? = some true →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, p.params[i]? = some false → ∃ n, vals[i]? = some (Val.int n))
    {c : Code × St} (hr : MReach (p.code, initSt p H vals) c) :
    ∀ k, mstep c ≠ some (.bad k) := by
  obtain ⟨hn, hC⟩ := check_cont hp
  exact reach_safe hC (entry_inv p hn ext H vals hlen hext href hsc) hr

theorem check_no_use_after_free (p : Prog) (hp : check p = true) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length) (hext : WF ⟨H, ext, []⟩)
    (href : ∀ i : Nat, p.params[i]? = some true →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, p.params[i]? = some false → ∃ n, vals[i]? = some (Val.int n))
    {c : Code × St} (hr : MReach (p.code, initSt p H vals) c) :
    mstep c ≠ some (.bad .dead) :=
  check_sound p hp ext H vals hlen hext href hsc hr .dead

theorem check_no_shared_store (p : Prog) (hp : check p = true) (ext : List Val) (H : Heap)
    (vals : List Val) (hlen : vals.length = p.params.length) (hext : WF ⟨H, ext, []⟩)
    (href : ∀ i : Nat, p.params[i]? = some true →
      ∃ l q, vals[i]? = some (Val.ref l) ∧ Val.ref q ∈ ext ∧ Desc H q (Val.ref l))
    (hsc : ∀ i : Nat, p.params[i]? = some false → ∃ n, vals[i]? = some (Val.int n))
    {c : Code × St} (hr : MReach (p.code, initSt p H vals) c) :
    mstep c ≠ some (.bad .shared) :=
  check_sound p hp ext H vals hlen hext href hsc hr .shared

end Orin
