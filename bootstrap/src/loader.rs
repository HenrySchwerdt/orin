//! Module loader: reads files, parses them, resolves imports, enforces module boundaries and
//! acyclicity. Interface: shared contract (v1); implementation owned by the parser worker.

use crate::ast;
use crate::diag::{DResult, Diagnostic};
use crate::parser;
use crate::span::{FileId, SourceMap, Span};
use std::collections::HashMap;
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
    let canon = match std::fs::canonicalize(entry) {
        Ok(c) if c.is_file() => c,
        other => {
            let why = match other {
                Ok(_) => "not a regular file".to_string(),
                Err(e) => e.to_string(),
            };
            let fid = sm.add(entry.to_path_buf(), String::new());
            return Err(vec![Diagnostic::new(
                "E0301",
                Span::new(fid, 0, 0),
                format!("cannot read `{}`: {}", entry.display(), why),
            )]);
        }
    };
    let base = canon.parent().map(Path::to_path_buf).unwrap_or_default();
    let mut ld = Loader { sm, base, state: HashMap::new(), stack: Vec::new(), units: Vec::new() };
    let entry_idx = ld.load_file(&canon, Some(entry.to_path_buf()))?;
    Ok(LoadedProgram { units: ld.units, entry: entry_idx })
}

enum State {
    InProgress,
    Done(usize),
}

struct Loader<'a> {
    sm: &'a mut SourceMap,
    base: PathBuf,
    state: HashMap<PathBuf, State>,
    /// Canonical paths of files currently being loaded (DFS stack).
    stack: Vec<PathBuf>,
    units: Vec<Unit>,
}

/// `/`-separated path of `p` relative to `base`, without a trailing `.or`.
/// Files outside `base` get leading `../` components.
fn rel_name(base: &Path, p: &Path) -> String {
    let b: Vec<_> = base.components().collect();
    let c: Vec<_> = p.components().collect();
    let mut common = 0;
    while common < b.len() && common < c.len() && b[common] == c[common] {
        common += 1;
    }
    let mut parts: Vec<String> = Vec::new();
    for _ in common..b.len() {
        parts.push("..".to_string());
    }
    for comp in &c[common..] {
        parts.push(comp.as_os_str().to_string_lossy().into_owned());
    }
    let mut s = parts.join("/");
    if let Some(stripped) = s.strip_suffix(".or") {
        s = stripped.to_string();
    }
    s
}

impl<'a> Loader<'a> {
    fn load_file(&mut self, path: &Path, display: Option<PathBuf>) -> DResult<usize> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                let fid = self.sm.add(path.to_path_buf(), String::new());
                return Err(vec![Diagnostic::new(
                    "E0301",
                    Span::new(fid, 0, 0),
                    format!("cannot read `{}`: {}", path.display(), e),
                )]);
            }
        };
        let fid = self.sm.add(display.unwrap_or_else(|| path.to_path_buf()), text.clone());
        let module = parser::parse(fid, &text)?;
        self.state.insert(path.to_path_buf(), State::InProgress);
        self.stack.push(path.to_path_buf());
        let dir = path.parent().map(Path::to_path_buf).unwrap_or_default();

        let mut imports = Vec::new();
        for item in &module.items {
            let (p, pspan) = match item {
                ast::Item::Import(i) => (&i.path, i.path_span),
                ast::Item::ReExport(r) => (&r.path, r.path_span),
                _ => continue,
            };
            imports.push(self.resolve_import(path, &dir, p, pspan)?);
        }

        self.stack.pop();
        let idx = self.units.len();
        self.units.push(Unit {
            file: fid,
            path: path.to_path_buf(),
            name: rel_name(&self.base, path),
            ast: module,
            imports,
        });
        self.state.insert(path.to_path_buf(), State::Done(idx));
        Ok(idx)
    }

    fn resolve_import(&mut self, importer: &Path, dir: &Path, p: &str, span: Span) -> DResult<ImportTarget> {
        let e301 = |m: String| vec![Diagnostic::new("E0301", span, m)];
        if let Some(name) = p.strip_prefix("std:") {
            return match name {
                "fs" => Ok(ImportTarget::Std(StdModule::Fs)),
                "process" => Ok(ImportTarget::Std(StdModule::Process)),
                _ => Err(e301(format!("unknown standard module `{}` (available: std:fs, std:process)", p))),
            };
        }
        let c1 = dir.join(format!("{}.or", p));
        let c2 = dir.join(p).join("module.or");
        let found = if c1.is_file() {
            c1
        } else if c2.is_file() {
            c2
        } else {
            return Err(e301(format!(
                "cannot find module `{}` (tried `{}` and `{}`)",
                p,
                c1.display(),
                c2.display()
            )));
        };
        let target = std::fs::canonicalize(&found)
            .map_err(|e| e301(format!("cannot resolve module `{}`: {}", p, e)))?;

        // Module boundary rule (E0302).
        for d in target.ancestors().skip(1) {
            if !d.join("module.or").is_file() {
                continue;
            }
            if target == d.join("module.or") {
                continue;
            }
            if !importer.starts_with(d) {
                return Err(vec![Diagnostic::new(
                    "E0302",
                    span,
                    format!(
                        "cannot import private file `{}` of module `{}`; import the module itself",
                        rel_name(&self.base, &target),
                        rel_name(&self.base, d)
                    ),
                )]);
            }
        }

        match self.state.get(&target) {
            Some(State::Done(i)) => Ok(ImportTarget::Unit(*i)),
            Some(State::InProgress) => {
                let start = self.stack.iter().position(|s| *s == target).unwrap_or(0);
                let mut names: Vec<String> =
                    self.stack[start..].iter().map(|s| rel_name(&self.base, s)).collect();
                names.push(rel_name(&self.base, &target));
                Err(vec![Diagnostic::new(
                    "E0303",
                    span,
                    format!("import cycle: {}", names.join(" -> ")),
                )])
            }
            None => Ok(ImportTarget::Unit(self.load_file(&target, None)?)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct Tmp(PathBuf);
    impl Tmp {
        fn new() -> Tmp {
            let n = COUNTER.fetch_add(1, Ordering::SeqCst);
            let d = std::env::temp_dir().join(format!("orinb-loader-{}-{}", std::process::id(), n));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Tmp(std::fs::canonicalize(&d).unwrap())
        }
        fn write(&self, rel: &str, text: &str) -> PathBuf {
            let p = self.0.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, text).unwrap();
            p
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn load_path(p: &Path) -> (Result<LoadedProgram, Vec<Diagnostic>>, SourceMap) {
        let mut sm = SourceMap::new();
        let r = load(p, &mut sm);
        (r, sm)
    }
    fn names(p: &LoadedProgram) -> Vec<&str> {
        p.units.iter().map(|u| u.name.as_str()).collect()
    }
    fn err_code(r: Result<LoadedProgram, Vec<Diagnostic>>) -> (&'static str, String) {
        let d = r.err().expect("expected error").remove(0);
        (d.code, d.message)
    }

    #[test]
    fn single_file() {
        let t = Tmp::new();
        let m = t.write("main.or", "function main(): void { }");
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(p.units.len(), 1);
        assert_eq!(p.entry, 0);
        assert_eq!(p.units[0].name, "main");
    }

    #[test]
    fn resolves_file_before_dir_module() {
        let t = Tmp::new();
        let m = t.write(
            "main.or",
            "import { a } from \"./x\";\nimport { b } from \"./y\";\nfunction main(): void { }",
        );
        t.write("x.or", "export function a() { }");
        t.write("x/module.or", "export function a() { }");
        t.write("y/module.or", "export function b() { }");
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(names(&p), vec!["x", "y/module", "main"]);
        assert_eq!(p.units[2].imports, vec![ImportTarget::Unit(0), ImportTarget::Unit(1)]);
    }

    #[test]
    fn std_imports() {
        let t = Tmp::new();
        let m = t.write(
            "main.or",
            "import { readFile } from \"std:fs\";\nimport { args } from \"std:process\";\nexport { x } from \"std:fs\";",
        );
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(
            p.units[0].imports,
            vec![
                ImportTarget::Std(StdModule::Fs),
                ImportTarget::Std(StdModule::Process),
                ImportTarget::Std(StdModule::Fs)
            ]
        );
        let t = Tmp::new();
        let m = t.write("main.or", "import { x } from \"std:net\";");
        let (code, msg) = err_code(load_path(&m).0);
        assert_eq!(code, "E0301");
        assert!(msg.contains("std:net"));
    }

    #[test]
    fn missing_module_e0301_points_at_path() {
        let t = Tmp::new();
        let src = "import { a } from \"./nope\";";
        let m = t.write("main.or", src);
        let (r, sm) = load_path(&m);
        let d = r.err().unwrap().remove(0);
        assert_eq!(d.code, "E0301");
        assert_eq!(&sm.file(d.span.file).text[d.span.start as usize..d.span.end as usize], "\"./nope\"");
    }

    #[test]
    fn missing_entry_e0301() {
        let t = Tmp::new();
        let (r, sm) = load_path(&t.0.join("absent.or"));
        let d = r.err().unwrap().remove(0);
        assert_eq!(d.code, "E0301");
        assert!(sm.len() >= 1);
        let _ = d.render(&sm);
    }

    #[test]
    fn parse_error_in_import_propagates() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { a } from \"./bad\";");
        t.write("bad.or", "var x = 1;");
        let (r, sm) = load_path(&m);
        let d = r.err().unwrap().remove(0);
        assert_eq!(d.code, "E0201");
        assert!(sm.file(d.span.file).path.ends_with("bad.or"));
    }

    #[test]
    fn private_file_import_e0302() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { h } from \"./users/internal\";");
        t.write("users/module.or", "export { h } from \"./internal\";");
        t.write("users/internal.or", "export function h() { }");
        let (code, msg) = err_code(load_path(&m).0);
        assert_eq!(code, "E0302");
        assert!(msg.contains("users/internal") && msg.contains("import the module itself"), "{}", msg);
    }

    #[test]
    fn nested_private_module_file_e0302() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { h } from \"./a/b\";");
        t.write("a/module.or", "");
        t.write("a/b/module.or", "");
        let (code, _) = err_code(load_path(&m).0);
        assert_eq!(code, "E0302");
    }

    #[test]
    fn import_inside_module_allowed_and_module_itself_allowed() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { h } from \"./users\";");
        t.write("users/module.or", "export { h } from \"./internal\";");
        t.write("users/internal.or", "import { z } from \"./deep/more\";\nexport function h() { }");
        t.write("users/deep/more.or", "export function z() { }");
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(names(&p), vec!["users/deep/more", "users/internal", "users/module", "main"]);
    }

    #[test]
    fn module_importing_parent_dir_file_allowed() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { h } from \"./users\";");
        t.write("users/module.or", "import { u } from \"../util\";");
        t.write("util.or", "export function u() { }");
        let (r, _) = load_path(&m);
        assert_eq!(names(&r.unwrap()), vec!["util", "users/module", "main"]);
    }

    #[test]
    fn cycle_e0303() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { a } from \"./a\";");
        t.write("a.or", "import { b } from \"./b\";");
        let bsrc = "import { a } from \"./a\";";
        t.write("b.or", bsrc);
        let (r, sm) = load_path(&m);
        let d = r.err().unwrap().remove(0);
        assert_eq!(d.code, "E0303");
        assert!(d.message.contains("a -> b -> a"), "{}", d.message);
        assert!(sm.file(d.span.file).path.ends_with("b.or"));
    }

    #[test]
    fn self_import_cycle() {
        let t = Tmp::new();
        let m = t.write("main.or", "import { a } from \"./main\";");
        let (code, _) = err_code(load_path(&m).0);
        assert_eq!(code, "E0303");
    }

    #[test]
    fn diamond_topological_order_and_dedup() {
        let t = Tmp::new();
        let m = t.write(
            "main.or",
            "import { a } from \"./a\";\nimport { b } from \"./b\";\nimport { c } from \"./sub/../c\";",
        );
        t.write("a.or", "import { c } from \"./c\";");
        t.write("b.or", "import { c } from \"./sub/../c\";\nimport { a } from \"./a\";");
        t.write("c.or", "");
        std::fs::create_dir_all(t.0.join("sub")).unwrap();
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(names(&p), vec!["c", "a", "b", "main"]);
        assert_eq!(p.entry, 3);
        assert_eq!(p.units[2].imports, vec![ImportTarget::Unit(0), ImportTarget::Unit(1)]);
        assert_eq!(
            p.units[3].imports,
            vec![ImportTarget::Unit(1), ImportTarget::Unit(2), ImportTarget::Unit(0)]
        );
    }

    #[test]
    fn imports_cover_reexports_in_item_order() {
        let t = Tmp::new();
        let m = t.write(
            "main.or",
            "function f() { }\nexport { x } from \"./b\";\nimport { y } from \"./a\";",
        );
        t.write("a.or", "");
        t.write("b.or", "");
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(names(&p), vec!["b", "a", "main"]);
        assert_eq!(p.units[2].imports, vec![ImportTarget::Unit(0), ImportTarget::Unit(1)]);
    }

    #[test]
    fn outside_entry_dir_names_are_unique() {
        let t = Tmp::new();
        let m = t.write("app/main.or", "import { x } from \"../lib/x\";\nimport { y } from \"../lib2/x\";");
        t.write("lib/x.or", "");
        t.write("lib2/x.or", "");
        let (r, _) = load_path(&m);
        let p = r.unwrap();
        assert_eq!(names(&p), vec!["../lib/x", "../lib2/x", "main"]);
    }
}
