import Orin

/-! Axiom audit: every headline theorem may depend only on Lean's standard axioms
(`propext`, `Classical.choice`, `Quot.sound`) and never on `sorryAx`. Run by `check.sh`. -/

#print axioms Orin.wf_dupInto
#print axioms Orin.wf_alloc
#print axioms Orin.wf_store
#print axioms Orin.wf_makeUnique
#print axioms Orin.wf_drain
#print axioms Orin.step_wf
#print axioms Orin.reach_wf
#print axioms Orin.step_not_dead
#print axioms Orin.run_safe
#print axioms Orin.step_shared_only_store
#print axioms Orin.opMakeUnique_unique
#print axioms Orin.store_after_makeUnique_safe
#print axioms Orin.makeUnique_view
#print axioms Orin.makeUnique_store_cow
#print axioms Orin.makeUnique_store_run
#print axioms Orin.wf_init
