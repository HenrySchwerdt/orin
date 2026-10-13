//! Codegen: typed HIR → GNU C source using runtime/orin_runtime.h. Owned by the codegen worker.

use crate::hir;

pub fn generate(prog: &hir::Program) -> String {
    let _ = prog;
    todo!("codegen::generate")
}
