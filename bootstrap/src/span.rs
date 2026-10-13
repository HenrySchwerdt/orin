//! Source files and byte spans. Shared contract (v1) — owned by the lead architect.

use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FileId(pub u32);

/// Half-open byte range `[start, end)` within one file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Span {
    pub file: FileId,
    pub start: u32,
    pub end: u32,
}

impl Span {
    pub fn new(file: FileId, start: u32, end: u32) -> Span {
        Span { file, start, end }
    }
    /// Smallest span covering both (must be in the same file).
    pub fn to(self, other: Span) -> Span {
        Span { file: self.file, start: self.start.min(other.start), end: self.end.max(other.end) }
    }
}

pub struct SourceFile {
    pub path: PathBuf,
    pub text: String,
    line_starts: Vec<u32>,
}

#[derive(Default)]
pub struct SourceMap {
    files: Vec<SourceFile>,
}

impl SourceMap {
    pub fn new() -> SourceMap {
        SourceMap { files: Vec::new() }
    }
    pub fn add(&mut self, path: PathBuf, text: String) -> FileId {
        let mut line_starts = vec![0u32];
        for (i, b) in text.bytes().enumerate() {
            if b == b'\n' {
                line_starts.push(i as u32 + 1);
            }
        }
        self.files.push(SourceFile { path, text, line_starts });
        FileId(self.files.len() as u32 - 1)
    }
    pub fn file(&self, id: FileId) -> &SourceFile {
        &self.files[id.0 as usize]
    }
    pub fn len(&self) -> usize {
        self.files.len()
    }
    /// 1-based (line, column); column counts bytes.
    pub fn line_col(&self, file: FileId, offset: u32) -> (u32, u32) {
        let f = self.file(file);
        let line = match f.line_starts.binary_search(&offset) {
            Ok(i) => i,
            Err(i) => i - 1,
        };
        (line as u32 + 1, offset - f.line_starts[line] + 1)
    }
}
