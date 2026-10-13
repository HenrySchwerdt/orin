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

-- ownership checker soundness (Mir, Check, Proj, Sim1-7, Weaken, Sound, Top)
#print axioms Orin.op_const
#print axioms Orin.op_move
#print axioms Orin.op_borrow
#print axioms Orin.op_dup
#print axioms Orin.op_release
#print axioms Orin.op_alloc
#print axioms Orin.op_getField
#print axioms Orin.op_setField
#print axioms Orin.op_putField
#print axioms Orin.op_takeField
#print axioms Orin.op_makeUnique
#print axioms Orin.drain_inv
#print axioms Orin.Inv.weaken
#print axioms Orin.joinL_fle_left
#print axioms Orin.joinL_fle_right
#print axioms Orin.unique_excl
#print axioms Orin.chk_cont
#print axioms Orin.sound_step
#print axioms Orin.reach_inv
#print axioms Orin.reach_safe
#print axioms Orin.entry_inv
#print axioms Orin.check_sound
#print axioms Orin.check_no_use_after_free
#print axioms Orin.check_no_shared_store
