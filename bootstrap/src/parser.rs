//! Parser: tokens → ast::Module. Owned by the parser worker.

use crate::ast;
use crate::diag::DResult;
use crate::span::FileId;

pub fn parse(file: FileId, src: &str) -> DResult<ast::Module> {
    let _ = (file, src, crate::lexer::placeholder);
    todo!("parser::parse")
}
