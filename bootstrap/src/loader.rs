//! Module loader: reads files, parses them, resolves imports, enforces module boundaries and
//! acyclicity. Interface: shared contract (v1); implementation owned by the parser worker.

use crate::ast;
use crate::diag::DResult;
use crate::span::{FileId, SourceMap};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StdModule {
    /// "std:fs"
    Fs,
    /// "std:process"
    Process,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImportTarget {
    /// Index into `LoadedProgram::units`.
    Unit(usize),
    Std(StdModule),
}

pub struct Unit {
    pub file: FileId,
    /// Canonicalized absolute path.
    pub path: PathBuf,
    /// Path relative to the entry file's directory, `/`-separated, without `.or`
    /// (e.g. "main", "users/module"). Deterministic; used for qualified names.
    pub name: String,
    pub ast: ast::Module,
    /// One entry per `Item::Import` / `Item::ReExport`, in item order.
    pub imports: Vec<ImportTarget>,
}

pub struct LoadedProgram {
    /// Topologically sorted: every unit appears after all units it imports. Deterministic.
    pub units: Vec<Unit>,
    /// Index of the entry unit.
    pub entry: usize,
}

pub fn load(entry: &Path, sm: &mut SourceMap) -> DResult<LoadedProgram> {
    let _ = (entry, sm);
    todo!("loader::load")
}
