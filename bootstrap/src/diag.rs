//! Diagnostics. Shared contract (v1). Codes are listed in docs/bootstrap-subset.md §9.

use crate::span::{SourceMap, Span};

#[derive(Clone, Debug)]
pub struct Diagnostic {
    /// e.g. "E0400"
    pub code: &'static str,
    pub message: String,
    pub span: Span,
    /// Optional extra lines ("note: ...").
    pub notes: Vec<String>,
}

impl Diagnostic {
    pub fn new(code: &'static str, span: Span, message: impl Into<String>) -> Diagnostic {
        Diagnostic { code, message: message.into(), span, notes: Vec::new() }
    }
    pub fn note(mut self, n: impl Into<String>) -> Diagnostic {
        self.notes.push(n.into());
        self
    }
    /// `path:line:col: error[CODE]: message`
    pub fn render(&self, sm: &SourceMap) -> String {
        let (line, col) = sm.line_col(self.span.file, self.span.start);
        let mut s = format!(
            "{}:{}:{}: error[{}]: {}",
            sm.file(self.span.file).path.display(),
            line,
            col,
            self.code,
            self.message
        );
        for n in &self.notes {
            s.push_str("\n  note: ");
            s.push_str(n);
        }
        s
    }
}

pub type DResult<T> = Result<T, Vec<Diagnostic>>;
