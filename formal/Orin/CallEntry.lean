import Orin.CallPrep

/-!
# Entering a callee

The callee runs on a fresh frame whose first locals are the operands (borrowed operands stay owned
by the caller, owned operands move) and whose anchors are the references the caller still holds
(`projL (midK own a) (clrL own L)`) together with the caller's own anchors.  `inv_entry` : the
simulation relation holds for the callee's entry state.
-/

namespace Orin
open Heap

variable {ext : List Val} {a : List AS} {s : St}

def modeK : PM → AS
  | .scalar => .init
  | .borrowed => .param
  | .owned => .owned

/-- the callee's initial abstract kinds -/
def entryLs (ps : List PM) (n : Nat) : List AS :=
  ps.map modeK ++ List.replicate (n - ps.length) .dead

/-- the callee's initial locals: the operand values, then dead zeros -/
def calleeLocals (vals : List Val) (n : Nat) : List Val :=
  vals ++ List.replicate (n - vals.length) (.int 0)

theorem gk_entryLs (ps : List PM) (n j : Nat) :
    gk (entryLs ps n) j = match ps[j]? with | some m => modeK m | none => .dead := by
  by_cases hj : j < ps.length
  · simp [gk, entryLs, List.getD_eq_getElem?_getD, List.getElem?_append_left (by simpa using hj : j < (ps.map modeK).length), hj]
  · simp only [gk, entryLs, List.getD_eq_getElem?_getD]
    rw [List.getElem?_append_right (by simp; omega)]
    simp [List.getElem?_eq_none (by omega : ps.length ≤ j), List.getElem?_replicate]
    split <;> simp

theorem getD_calleeLocals (vals : List Val) (n j : Nat) (hj : j < vals.length) :
    (calleeLocals vals n).getD j (.int 0) = vals.getD j (.int 0) := by
  simp [calleeLocals, List.getD_eq_getElem?_getD, List.getElem?_append_left hj]

theorem calleeLocals_length (vals : List Val) (n : Nat) (h : vals.length ≤ n) :
    (calleeLocals vals n).length = n := by
  simp [calleeLocals]; omega


theorem getD_mem (xs : List Val) (i : Nat) (h : i < xs.length) : xs.getD i (.int 0) ∈ xs := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]

theorem projL_cons (k : AS) (ks : List AS) (v : Val) (vs : List Val) :
    projL (k :: ks) (v :: vs) = pv k v :: projL ks vs := by
  simp [projL, List.mapIdx_cons, gk]

theorem projL_dead (T : List AS) (U : List Val) (hT : ∀ i, gk T i = .dead) :
    ∀ x ∈ projL T U, x = .int 0 := by
  intro x hx
  obtain ⟨i, hi⟩ := List.mem_iff_getElem?.mp hx
  rw [projL_getElem?] at hi
  cases hu : U[i]? with
  | none => rw [hu] at hi; simp at hi
  | some w =>
    rw [hu] at hi
    simp [pv, hT, AS.counted] at hi
    exact hi.symm

theorem ownedArgs_mem {ps : List PM} {args : List Nat} {j : Nat}
    (h : j ∈ ownedArgs ps args) : (j, PM.owned) ∈ args.zip ps := by
  unfold ownedArgs at h
  obtain ⟨⟨j', m⟩, hm, e⟩ := List.mem_filterMap.mp h
  simp only at e
  split at e
  · rename_i hmo
    cases e
    rw [hmo] at hm; exact hm
  · cases e

theorem entry_count (m : Nat) (s : St) : ∀ (ps : List PM) (args : List Nat) (T : List AS) (U : List Val),
    args.length = ps.length → (∀ i, gk T i = .dead) → (∀ v ∈ U, v = .int 0) →
    (projL (ps.map modeK ++ T) (args.map s.get ++ U)).count (.ref m)
      = ((ownedArgs ps args).map s.get).count (.ref m)
  | [], [], T, U, _, hT, hU => by
    simp only [List.map_nil, List.nil_append, ownedArgs, List.zip_nil_left, List.filterMap_nil,
      List.count_nil]
    rw [List.count_eq_zero]
    intro hmem
    have := projL_dead T U hT _ hmem
    cases this
  | [], _ :: _, _, _, h, _, _ => by simp at h
  | _ :: _, [], _, _, h, _, _ => by simp at h
  | p :: ps, j :: args, T, U, h, hT, hU => by
    have ih := entry_count m s ps args T U (by simpa using h) hT hU
    simp only [List.map_cons, List.cons_append, projL_cons]
    unfold ownedArgs
    simp only [List.zip_cons_cons, List.filterMap_cons]
    cases p
    · simpa [modeK, pv, AS.counted, List.count_cons, ownedArgs] using ih
    · simpa [modeK, pv, AS.counted, List.count_cons, ownedArgs] using ih
    · simp [modeK, pv, AS.counted, List.count_cons, ownedArgs] at ih ⊢
      omega


theorem mem_extF {own : List Nat} {jj p : Nat} (hI : Inv ext a s) (hjj : jj ∉ own)
    (hc : (gk a jj).counted = true) (hl : s.get jj = .ref p) :
    Val.ref p ∈ projL (midK own a) (clrL own s.locals) ++ ext := by
  have hne : gk a jj ≠ .dead := by intro e; rw [e] at hc; simp [AS.counted] at hc
  have hlt : jj < s.locals.length := hI.len ▸ lt_of_gk_ne_dead hne
  apply List.mem_append_left
  rw [List.mem_iff_getElem?]
  refine ⟨jj, ?_⟩
  rw [projL_getElem?, clrL_getElem?]
  have hsp := s.get_spec jj hlt
  have := counted_midK own a jj
  simp only [hjj, ite_false] at this
  simp [hjj, hsp, pv, this, hc, hl]


theorem get_calleeLocals (s : St) (args : List Nat) (n j : Nat) (hj : j < args.length) :
    ({ heap := s.heap, locals := calleeLocals (args.map s.get) n, pending := [] } : St).get j
      = s.get (args[j]) := by
  have h1 : j < (args.map s.get).length := by simpa using hj
  show (calleeLocals (args.map s.get) n).getD j (.int 0) = s.get args[j]
  rw [getD_calleeLocals _ _ _ h1]
  simp [List.getD_eq_getElem?_getD, hj]

theorem inv_entry (hI : Inv ext a s) (hp : s.pending = [])
    {ps : List PM} {args : List Nat} {n : Nat}
    (hl : args.length = ps.length) (hn : ps.length ≤ n)
    (hnd : (ownedArgs ps args).Nodup)
    (hargs : (args.zip ps).all (argOK a (ownedArgs ps args)) = true) :
    Inv (projL (midK (ownedArgs ps args) a) (clrL (ownedArgs ps args) s.locals) ++ ext)
      (entryLs ps n) ⟨s.heap, calleeLocals (args.map s.get) n, []⟩ := by
  generalize hown_def : ownedArgs ps args = own at *
  have hownC : ∀ j ∈ own, (gk a j).counted = true := by
    intro j hj
    rw [← hown_def] at hj
    have h1 := List.all_eq_true.mp hargs _ (ownedArgs_mem hj)
    simpa [argOK] using h1
  have hownlt : ∀ j ∈ own, j < s.locals.length := by
    intro j hj
    have h1 := hownC j hj
    have : gk a j ≠ .dead := by intro e; rw [e] at h1; simp [AS.counted] at h1
    exact hI.len ▸ lt_of_gk_ne_dead this
  have hX : (projL a s.locals).length = s.locals.length := projL_length a s.locals
  have hXget : ∀ j ∈ own, (projL a s.locals).getD j (.int 0) = s.get j := by
    intro j hj
    have hlt := hownlt j hj
    simp [List.getD_eq_getElem?_getD, projL_getElem?, hlt, St.get, pv, hownC j hj,
      List.getElem?_eq_getElem hlt]
  have hcalle : ({ heap := s.heap, locals := calleeLocals (args.map s.get) n, pending := [] } : St).locals.length = n :=
    calleeLocals_length _ _ (by simpa [hl] using hn)
  have hZ : ∀ m, (projL (entryLs ps n) (calleeLocals (args.map s.get) n)).count (.ref m)
      = (own.map s.get).count (.ref m) := by
    intro m
    have := entry_count m s ps args (List.replicate (n - ps.length) .dead)
      (List.replicate (n - args.length) (.int 0)) hl
      (by intro i; simp [gk, List.getD_eq_getElem?_getD, List.getElem?_replicate]; split <;> simp)
      (by intro v hv; simp at hv; exact hv.2)
    simp only [entryLs, calleeLocals, List.length_map]
    rw [this, hown_def]
  refine ⟨?_, ?_, fun j => ?_⟩
  · simp [entryLs, hcalle]; omega
  · -- the owners: the operands moved, nothing duplicated
    have hpend : Pst ext a s = ⟨s.heap, projL a s.locals ++ ext, []⟩ := by simp [Pst, hp]
    have hw := hI.wf
    rw [hpend] at hw
    have key := wf_locals _ hw
      (projL (entryLs ps n) (calleeLocals (args.map s.get) n) ++ (clrL own (projL a s.locals) ++ ext))
      (by
        intro m
        have h := clrL_count m own (projL a s.locals) hnd (by rw [hX]; exact hownlt)
        have hm : (own.map (fun i => (projL a s.locals).getD i (.int 0))) = own.map s.get :=
          List.map_congr_left hXget
        rw [hm] at h
        simp only [List.count_append]
        rw [hZ m]
        omega)
      (by
        intro v hv
        have hlive := hw.locs
        rcases List.mem_append.mp hv with h | h
        · cases v with
          | int n => trivial
          | ref m =>
            have hc : 0 < (projL (entryLs ps n) (calleeLocals (args.map s.get) n)).count (.ref m) :=
              List.count_pos_iff.mpr h
            rw [hZ m] at hc
            obtain ⟨j, hj, hjm⟩ := List.mem_map.mp (List.count_pos_iff.mp hc)
            apply hlive
            show Val.ref m ∈ projL a s.locals ++ ext
            apply List.mem_append_left
            rw [← hjm, ← hXget j hj]
            exact getD_mem _ _ (by rw [hX]; exact hownlt j hj)
        · rcases List.mem_append.mp h with h | h
          · rw [List.mem_iff_getElem?] at h
            obtain ⟨i, hi⟩ := h
            rw [clrL_getElem?] at hi
            by_cases hio : i ∈ own
            · rw [if_pos hio] at hi
              cases hx : (projL a s.locals)[i]? with
              | none => rw [hx] at hi; simp at hi
              | some w => rw [hx] at hi; simp at hi; rw [← hi]; trivial
            · rw [if_neg hio] at hi
              exact hlive v (List.mem_append_left _ (List.mem_iff_getElem?.mpr ⟨i, hi⟩))
          · exact hlive v (List.mem_append_right _ h))
    have hp2 : Pst (projL (midK own a) (clrL own s.locals) ++ ext) (entryLs ps n)
        ⟨s.heap, calleeLocals (args.map s.get) n, []⟩
        = { (⟨s.heap, projL a s.locals ++ ext, []⟩ : St) with
            locals := projL (entryLs ps n) (calleeLocals (args.map s.get) n) ++
              (clrL own (projL a s.locals) ++ ext) } := by
      simp [Pst, projL_midK, List.append_assoc]
    rw [hp2]; exact key
  · -- the claims about each callee local
    by_cases hj : j < ps.length
    · have hja : j < args.length := hl ▸ hj
      have hget := get_calleeLocals s args n j hja
      have hmem : (args[j], ps[j]) ∈ args.zip ps := by
        have h1 : j < (args.zip ps).length := by simp [List.length_zip]; omega
        have h2 := List.getElem_mem h1
        simpa [List.getElem_zip] using h2
      have hok : argOK a own (args[j], ps[j]) = true := List.all_eq_true.mp hargs _ hmem
      have hk : gk (entryLs ps n) j = modeK ps[j] := by
        rw [gk_entryLs]; simp [List.getElem?_eq_getElem hj]
      have hjj := hI.cl args[j]
      generalize ps[j] = pm at hok hk
      generalize args[j] = jj at hok hget hjj
      cases pm with
      | scalar =>
        have hg : gk a jj = .init := by simpa [argOK] using hok
        obtain ⟨n0, hn0⟩ := hjj.ini hg
        exact ClAt.of_init (by rw [hk]; rfl) ⟨n0, by rw [hget]; exact hn0⟩
      | owned =>
        have hc : (gk a jj).counted = true := by simpa [argOK] using hok
        have hr : (gk a jj).isRef = true := by
          cases hh : gk a jj <;> simp_all [AS.counted, AS.isRef]
        obtain ⟨l, hl'⟩ := hjj.ref hr
        exact ClAt.of_owned (by rw [hk]; rfl) ⟨l, by rw [hget]; exact hl'⟩
      | borrowed =>
        have hok' : (gk a jj).isRef = true ∧ rootOf a jj ∉ own := by
          simpa [argOK] using hok
        obtain ⟨hr, hroot⟩ := hok'
        obtain ⟨l, hl'⟩ := hjj.ref hr
        have hkp : gk (entryLs ps n) j = .param := by rw [hk]; rfl
        refine ⟨?_, ?_, ?_, ?_, fun _ => ⟨l, by rw [hget]; exact hl'⟩⟩
        · intro e; rw [hkp] at e; cases e
        · intro e; rw [hkp] at e; cases e
        · intro _
          rw [hget]
          cases hgk : gk a jj with
          | owned =>
            have hjo : jj ∉ own := by simpa [rootOf, hgk] using hroot
            exact ⟨l, mem_extF hI hjo (by simp [hgk, AS.counted]) hl', by rw [hl']; exact Desc.self⟩
          | unique =>
            have hjo : jj ∉ own := by simpa [rootOf, hgk] using hroot
            exact ⟨l, mem_extF hI hjo (by simp [hgk, AS.counted]) hl', by rw [hl']; exact Desc.self⟩
          | param =>
            obtain ⟨p, hp, hd⟩ := hjj.prm hgk
            exact ⟨p, List.mem_append_right _ hp, hd⟩
          | borrowed r =>
            have hro : r ∉ own := by simpa [rootOf, hgk] using hroot
            obtain ⟨hrr, p0, hp0, hd0, _⟩ := hjj.bor r hgk
            cases hgr : gk a r with
            | owned =>
              exact ⟨p0, mem_extF hI hro (by simp [hgr, AS.counted]) hp0, hd0⟩
            | unique =>
              exact ⟨p0, mem_extF hI hro (by simp [hgr, AS.counted]) hp0, hd0⟩
            | param =>
              obtain ⟨p1, hp1, hd1⟩ := (hI.cl r).prm hgr
              rw [hp0] at hd1
              exact ⟨p1, List.mem_append_right _ hp1, desc_trans hd0 hd1⟩
            | _ => rw [hgr] at hrr; simp [AS.isRoot] at hrr
          | _ => rw [hgk] at hr; simp [AS.isRef] at hr
        · intro r e; rw [hkp] at e; cases e
    · have : gk (entryLs ps n) j = .dead := by
        rw [gk_entryLs]; simp [List.getElem?_eq_none (by omega : ps.length ≤ j)]
      exact ClAt.of_dead this

end Orin
