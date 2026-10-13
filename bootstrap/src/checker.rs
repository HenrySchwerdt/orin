//! Checker: name resolution + type checking, AST → typed HIR. Owned by the checker worker.

use crate::diag::DResult;
use crate::hir;
use crate::loader::LoadedProgram;
use crate::span::SourceMap;

pub fn check(prog: &LoadedProgram, sm: &SourceMap) -> DResult<hir::Program> {
    let _ = (prog, sm);
    todo!("checker::check")
}
