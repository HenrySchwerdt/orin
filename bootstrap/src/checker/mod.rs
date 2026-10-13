//! Checker: name resolution + type checking, AST → typed HIR. Owned by the checker worker.
//!
//! Phases (each phase stops the pipeline if it produced diagnostics):
//! 1. `collect`  — per unit (in topological order): register declarations, process imports and
//!    re-exports, assign dense `RecordId` / `UnionId` / `FuncId` (unit order, then declaration order).
//! 2. `resolve_decls` — resolve alias targets (cycle check), record fields, variant payloads,
//!    function signatures and top-level const values.
//! 3. bodies — bidirectional checking of every function body (one diagnostic per function body).
//!
//! Design decisions (see also the final report of the checker worker):
//! - Each unit has two namespaces: *types* (records, unions, aliases) and *values* (functions,
//!   consts, union variants). Duplicates inside one namespace are E0304; a type and a value may
//!   share a name (e.g. `type Foo = Foo(int) | Bar`). Declaring a type named like a built-in
//!   type (`int`, `Option`, ...) is E0304.
//! - Alias cycles (`type A = B; type B = A;`) are reported as E0400.
//! - Variants of an exported union are themselves exported names.
//! - Function parameters live in an outer scope; the body block is a nested scope, so a body
//!   local may shadow a parameter.
//! - Literal patterns of the wrong type are E0400; variant patterns against a non-variant
//!   scrutinee, wrong pattern arity and non-exhaustive matches are E0402.
//! - User declarations shadow the built-in constructors `Some`/`None`/`Ok`/`Err` and `parseInt`.

use std::cell::RefCell;
use std::collections::BTreeMap;

use crate::ast::{self, ArmBody, AssignOp, BinaryOp, Item, PatternKind, StmtKind, TypeDeclBody, TypeExprKind, UnaryOp};
use crate::ast::ExprKind as AK;
use crate::diag::{DResult, Diagnostic};
use crate::hir::{self, Builtin, FuncId, LocalId, MutBuiltin, RecordId, Type, UnionId};
use crate::loader::{ImportTarget, LoadedProgram, StdModule};
use crate::span::{SourceMap, Span};

#[cfg(test)]
mod tests;

type R<T> = Result<T, Diagnostic>;

fn err<T>(code: &'static str, span: Span, msg: impl Into<String>) -> R<T> {
    Err(Diagnostic::new(code, span, msg))
}

// ---------------------------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TypeEnt {
    Record(RecordId),
    Union(UnionId),
    Alias(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ValEnt {
    Func(FuncId),
    Const(usize),
    Variant { union: UnionId, tag: u32 },
    Std(Builtin),
}

#[derive(Clone, Default)]
struct Names {
    types: BTreeMap<String, TypeEnt>,
    vals: BTreeMap<String, ValEnt>,
}

#[derive(Default)]
struct UnitInfo {
    /// Everything visible inside the unit (own declarations + imports).
    scope: Names,
    /// What importers may see (exported declarations + re-exports).
    exports: Names,
}

struct AliasInfo<'a> {
    unit: usize,
    target: &'a ast::TypeExpr,
}

#[derive(Clone)]
enum AliasState {
    Todo,
    Busy,
    Done(Type),
    Failed(Diagnostic),
}

struct RecordSrc<'a> {
    unit: usize,
    fields: &'a [ast::FieldDecl],
}

struct UnionSrc<'a> {
    unit: usize,
    variants: &'a [ast::VariantDecl],
}

struct FuncInfo<'a> {
    unit: usize,
    decl: &'a ast::FunctionDecl,
    params: Vec<Type>,
    ret: Type,
}

#[derive(Clone, Debug)]
enum ConstLit {
    Int(i64),
    Str(String),
    Bool(bool),
}

struct ConstInfo<'a> {
    unit: usize,
    decl: &'a ast::ConstDecl,
    val: Option<(Type, ConstLit)>,
}

fn add_type(names: &mut Names, name: &str, ent: TypeEnt, span: Span) -> R<()> {
    match names.types.get(name) {
        Some(old) if *old == ent => Ok(()),
        Some(_) => err("E0304", span, format!("duplicate definition of type `{}`", name)),
        None => {
            names.types.insert(name.to_string(), ent);
            Ok(())
        }
    }
}

fn add_val(names: &mut Names, name: &str, ent: ValEnt, span: Span) -> R<()> {
    match names.vals.get(name) {
        Some(old) if *old == ent => Ok(()),
        Some(_) => err("E0304", span, format!("duplicate definition of `{}`", name)),
        None => {
            names.vals.insert(name.to_string(), ent);
            Ok(())
        }
    }
}

fn is_builtin_type_name(n: &str) -> bool {
    matches!(n, "int" | "usize" | "bool" | "string" | "void" | "Option" | "Result")
}

fn mk(kind: hir::ExprKind, ty: Type, span: Span) -> hir::Expr {
    hir::Expr { kind, ty, span }
}

struct Checker<'a> {
    prog: &'a LoadedProgram,
    units: Vec<UnitInfo>,
    aliases: Vec<AliasInfo<'a>>,
    alias_state: RefCell<Vec<AliasState>>,
    records: Vec<hir::RecordDef>,
    record_src: Vec<RecordSrc<'a>>,
    unions: Vec<hir::UnionDef>,
    union_src: Vec<UnionSrc<'a>>,
    funcs: Vec<FuncInfo<'a>>,
    hir_funcs: Vec<hir::Function>,
    consts: Vec<ConstInfo<'a>>,
    diags: Vec<Diagnostic>,
}

pub fn check(prog: &LoadedProgram, _sm: &SourceMap) -> DResult<hir::Program> {
    let mut ck = Checker::new(prog);
    ck.collect();
    if !ck.diags.is_empty() {
        return Err(ck.finish_diags());
    }
    ck.resolve_decls();
    ck.check_main();
    if !ck.diags.is_empty() {
        return Err(ck.finish_diags());
    }
    ck.check_bodies();
    if !ck.diags.is_empty() {
        return Err(ck.finish_diags());
    }
    let main = ck.main_id();
    Ok(hir::Program { records: ck.records, unions: ck.unions, functions: ck.hir_funcs, main })
}

impl<'a> Checker<'a> {
    fn new(prog: &'a LoadedProgram) -> Checker<'a> {
        Checker {
            prog,
            units: Vec::new(),
            aliases: Vec::new(),
            alias_state: RefCell::new(Vec::new()),
            records: Vec::new(),
            record_src: Vec::new(),
            unions: Vec::new(),
            union_src: Vec::new(),
            funcs: Vec::new(),
            hir_funcs: Vec::new(),
            consts: Vec::new(),
            diags: Vec::new(),
        }
    }

    fn finish_diags(&mut self) -> Vec<Diagnostic> {
        let mut out: Vec<Diagnostic> = Vec::new();
        for d in self.diags.drain(..) {
            if !out.iter().any(|o| o.code == d.code && o.span == d.span && o.message == d.message) {
                out.push(d);
            }
        }
        out
    }

    fn push_err(&mut self, r: R<()>) {
        if let Err(d) = r {
            self.diags.push(d);
        }
    }

    fn show(&self, t: &Type) -> String {
        match t {
            Type::Int => "int".into(),
            Type::Usize => "usize".into(),
            Type::Bool => "bool".into(),
            Type::String => "string".into(),
            Type::Void => "void".into(),
            Type::Array(e) => format!("{}[]", self.show(e)),
            Type::Option(e) => format!("Option<{}>", self.show(e)),
            Type::Result(a, b) => format!("Result<{}, {}>", self.show(a), self.show(b)),
            Type::Record(r) => self.records[r.0 as usize].name.clone(),
            Type::Union(u) => self.unions[u.0 as usize].name.clone(),
        }
    }

    // -----------------------------------------------------------------------------------------
    // Phase 1: collection, imports
    // -----------------------------------------------------------------------------------------

    fn export_lookup(&self, target: ImportTarget, name: &str) -> (Option<TypeEnt>, Option<ValEnt>) {
        match target {
            ImportTarget::Unit(j) => match self.units.get(j) {
                Some(u) => (u.exports.types.get(name).copied(), u.exports.vals.get(name).copied()),
                None => (None, None),
            },
            ImportTarget::Std(m) => {
                let b = match (m, name) {
                    (StdModule::Fs, "readFile") => Some(Builtin::FsReadFile),
                    (StdModule::Fs, "writeFile") => Some(Builtin::FsWriteFile),
                    (StdModule::Fs, "exists") => Some(Builtin::FsExists),
                    (StdModule::Process, "args") => Some(Builtin::ProcessArgs),
                    (StdModule::Process, "exit") => Some(Builtin::ProcessExit),
                    _ => None,
                };
                (None, b.map(ValEnt::Std))
            }
        }
    }

    fn collect(&mut self) {
        let prog = self.prog;
        for (ui, unit) in prog.units.iter().enumerate() {
            let mut scope = Names::default();
            let mut exports = Names::default();
            for item in &unit.ast.items {
                match item {
                    Item::Function(f) => {
                        if let Some(g) = f.type_params.first() {
                            self.diags.push(Diagnostic::new(
                                "E0408",
                                g.span,
                                "generic functions are not supported in Orin-B",
                            ));
                        }
                        let id = FuncId(self.funcs.len() as u32);
                        self.funcs.push(FuncInfo { unit: ui, decl: f, params: Vec::new(), ret: Type::Void });
                        let r = add_val(&mut scope, &f.name.name, ValEnt::Func(id), f.name.span);
                        self.push_err(r);
                        if f.exported {
                            let r = add_val(&mut exports, &f.name.name, ValEnt::Func(id), f.name.span);
                            self.push_err(r);
                        }
                    }
                    Item::Const(c) => {
                        let id = self.consts.len();
                        self.consts.push(ConstInfo { unit: ui, decl: c, val: None });
                        let r = add_val(&mut scope, &c.name.name, ValEnt::Const(id), c.name.span);
                        self.push_err(r);
                        if c.exported {
                            let r = add_val(&mut exports, &c.name.name, ValEnt::Const(id), c.name.span);
                            self.push_err(r);
                        }
                    }
                    Item::Type(t) => {
                        if let Some(g) = t.type_params.first() {
                            self.diags.push(Diagnostic::new(
                                "E0408",
                                g.span,
                                "generic types are not supported in Orin-B",
                            ));
                        }
                        if is_builtin_type_name(&t.name.name) {
                            self.diags.push(Diagnostic::new(
                                "E0304",
                                t.name.span,
                                format!("`{}` is a built-in type name", t.name.name),
                            ));
                            continue;
                        }
                        let qname = format!("{}.{}", unit.name, t.name.name);
                        let ent = match &t.body {
                            TypeDeclBody::Alias(te) => {
                                let id = self.aliases.len();
                                self.aliases.push(AliasInfo { unit: ui, target: te });
                                self.alias_state.borrow_mut().push(AliasState::Todo);
                                TypeEnt::Alias(id)
                            }
                            TypeDeclBody::Record(fields) => {
                                let id = RecordId(self.records.len() as u32);
                                self.records.push(hir::RecordDef { name: qname, fields: Vec::new() });
                                self.record_src.push(RecordSrc { unit: ui, fields });
                                TypeEnt::Record(id)
                            }
                            TypeDeclBody::Union(vs) => {
                                let id = UnionId(self.unions.len() as u32);
                                self.unions.push(hir::UnionDef {
                                    name: qname,
                                    variants: vs
                                        .iter()
                                        .map(|v| hir::VariantDef { name: v.name.name.clone(), payload: Vec::new() })
                                        .collect(),
                                });
                                self.union_src.push(UnionSrc { unit: ui, variants: vs });
                                for (tag, v) in vs.iter().enumerate() {
                                    let ent = ValEnt::Variant { union: id, tag: tag as u32 };
                                    let r = add_val(&mut scope, &v.name.name, ent, v.name.span);
                                    self.push_err(r);
                                    if t.exported {
                                        let r = add_val(&mut exports, &v.name.name, ent, v.name.span);
                                        self.push_err(r);
                                    }
                                }
                                TypeEnt::Union(id)
                            }
                        };
                        let r = add_type(&mut scope, &t.name.name, ent, t.name.span);
                        self.push_err(r);
                        if t.exported {
                            let r = add_type(&mut exports, &t.name.name, ent, t.name.span);
                            self.push_err(r);
                        }
                    }
                    Item::Import(_) | Item::ReExport(_) => {}
                }
            }
            // Imports and re-exports.
            let mut imp = 0usize;
            for item in &unit.ast.items {
                let (names, path, is_reexport) = match item {
                    Item::Import(d) => (&d.names, &d.path, false),
                    Item::ReExport(d) => (&d.names, &d.path, true),
                    _ => continue,
                };
                let target = match unit.imports.get(imp) {
                    Some(t) => *t,
                    None => {
                        self.diags.push(Diagnostic::new(
                            "E0300",
                            names.first().map(|n| n.span).unwrap_or(Span::new(unit.file, 0, 0)),
                            format!("module `{}` was not resolved by the loader", path),
                        ));
                        imp += 1;
                        continue;
                    }
                };
                imp += 1;
                for n in names {
                    let (t, v) = self.export_lookup(target, &n.name);
                    if t.is_none() && v.is_none() {
                        self.diags.push(Diagnostic::new(
                            "E0300",
                            n.span,
                            format!("`{}` is not exported by `{}`", n.name, path),
                        ));
                        continue;
                    }
                    let dest = if is_reexport { &mut exports } else { &mut scope };
                    let mut results: Vec<R<()>> = Vec::new();
                    if let Some(t) = t {
                        results.push(add_type(dest, &n.name, t, n.span));
                    }
                    if let Some(v) = v {
                        results.push(add_val(dest, &n.name, v, n.span));
                    }
                    if let Some(TypeEnt::Union(u)) = t {
                        for (tag, v) in self.unions[u.0 as usize].variants.iter().enumerate() {
                            results.push(add_val(dest, &v.name, ValEnt::Variant { union: u, tag: tag as u32 }, n.span));
                        }
                    }
                    for r in results {
                        self.push_err(r);
                    }
                }
            }
            self.units.push(UnitInfo { scope, exports });
        }
    }

    // -----------------------------------------------------------------------------------------
    // Phase 2: declarations
    // -----------------------------------------------------------------------------------------

    fn alias_type(&self, idx: usize) -> R<Type> {
        let st = self.alias_state.borrow()[idx].clone();
        match st {
            AliasState::Done(t) => Ok(t),
            AliasState::Failed(d) => Err(d),
            AliasState::Busy => {
                let target = self.aliases[idx].target;
                err("E0400", target.span, "type alias is defined in terms of itself")
            }
            AliasState::Todo => {
                self.alias_state.borrow_mut()[idx] = AliasState::Busy;
                let info = &self.aliases[idx];
                let r = self.resolve_type(info.unit, info.target, false);
                self.alias_state.borrow_mut()[idx] = match &r {
                    Ok(t) => AliasState::Done(t.clone()),
                    Err(d) => AliasState::Failed(d.clone()),
                };
                r
            }
        }
    }

    fn resolve_type_name(&self, unit: usize, name: &ast::Ident) -> R<Type> {
        match self.units[unit].scope.types.get(&name.name) {
            Some(TypeEnt::Record(r)) => Ok(Type::Record(*r)),
            Some(TypeEnt::Union(u)) => Ok(Type::Union(*u)),
            Some(TypeEnt::Alias(i)) => self.alias_type(*i),
            None => err("E0300", name.span, format!("unknown type `{}`", name.name)),
        }
    }

    fn resolve_type(&self, unit: usize, te: &ast::TypeExpr, void_ok: bool) -> R<Type> {
        match &te.kind {
            TypeExprKind::Array(inner) => {
                let t = self.resolve_type(unit, inner, false)?;
                Ok(Type::Array(Box::new(t)))
            }
            TypeExprKind::Named { name, args } => {
                let n = name.name.as_str();
                let b = match n {
                    "int" => Some(Type::Int),
                    "usize" => Some(Type::Usize),
                    "bool" => Some(Type::Bool),
                    "string" => Some(Type::String),
                    "void" => Some(Type::Void),
                    _ => None,
                };
                if let Some(b) = b {
                    if !args.is_empty() {
                        return err("E0400", te.span, format!("type `{}` takes no type arguments", n));
                    }
                    if b == Type::Void && !void_ok {
                        return err(
                            "E0400",
                            te.span,
                            "`void` is only allowed as a return type or as `T` in `Result<T, E>`",
                        );
                    }
                    return Ok(b);
                }
                match n {
                    "Option" => {
                        if args.len() != 1 {
                            return err("E0400", te.span, "`Option` takes exactly one type argument");
                        }
                        Ok(Type::Option(Box::new(self.resolve_type(unit, &args[0], false)?)))
                    }
                    "Result" => {
                        if args.len() != 2 {
                            return err("E0400", te.span, "`Result` takes exactly two type arguments");
                        }
                        let t = self.resolve_type(unit, &args[0], true)?;
                        let e = self.resolve_type(unit, &args[1], false)?;
                        Ok(Type::Result(Box::new(t), Box::new(e)))
                    }
                    _ => {
                        if !args.is_empty() {
                            return err("E0408", te.span, "generic types are not supported in Orin-B");
                        }
                        self.resolve_type_name(unit, name)
                    }
                }
            }
        }
    }

    fn resolve_decls(&mut self) {
        // Aliases first (also detects cycles among unused aliases).
        for i in 0..self.aliases.len() {
            if let Err(d) = self.alias_type(i) {
                self.diags.push(d);
            }
        }
        // Record fields.
        for i in 0..self.records.len() {
            let unit = self.record_src[i].unit;
            let fields: &'a [ast::FieldDecl] = self.record_src[i].fields;
            let mut out: Vec<(String, Type)> = Vec::new();
            for f in fields {
                if out.iter().any(|(n, _)| *n == f.name.name) {
                    self.diags.push(Diagnostic::new("E0304", f.name.span, format!("duplicate field `{}`", f.name.name)));
                    continue;
                }
                match self.resolve_type(unit, &f.ty, false) {
                    Ok(t) => out.push((f.name.name.clone(), t)),
                    Err(d) => self.diags.push(d),
                }
            }
            self.records[i].fields = out;
        }
        // Union payloads.
        for i in 0..self.unions.len() {
            let unit = self.union_src[i].unit;
            let vs: &'a [ast::VariantDecl] = self.union_src[i].variants;
            for (vi, v) in vs.iter().enumerate() {
                let mut payload = Vec::new();
                for te in &v.payload {
                    match self.resolve_type(unit, te, false) {
                        Ok(t) => payload.push(t),
                        Err(d) => self.diags.push(d),
                    }
                }
                self.unions[i].variants[vi].payload = payload;
            }
        }
        // Consts.
        for i in 0..self.consts.len() {
            let r = self.resolve_const(i);
            match r {
                Ok(v) => self.consts[i].val = Some(v),
                Err(d) => self.diags.push(d),
            }
        }
        // Function signatures.
        for i in 0..self.funcs.len() {
            let unit = self.funcs[i].unit;
            let decl: &'a ast::FunctionDecl = self.funcs[i].decl;
            let mut params = Vec::new();
            let mut locals = Vec::new();
            for p in &decl.params {
                if locals.iter().any(|l: &hir::Local| l.name == p.name.name) {
                    self.diags.push(Diagnostic::new("E0304", p.name.span, format!("duplicate parameter `{}`", p.name.name)));
                }
                match self.resolve_type(unit, &p.ty, false) {
                    Ok(t) => {
                        locals.push(hir::Local { name: p.name.name.clone(), ty: t.clone(), mutable: false });
                        params.push(t);
                    }
                    Err(d) => self.diags.push(d),
                }
            }
            let ret = match &decl.ret {
                None => Type::Void,
                Some(te) => match self.resolve_type(unit, te, true) {
                    Ok(t) => t,
                    Err(d) => {
                        self.diags.push(d);
                        Type::Void
                    }
                },
            };
            self.funcs[i].params = params.clone();
            self.funcs[i].ret = ret.clone();
            let qname = format!("{}.{}", self.prog.units[unit].name, decl.name.name);
            self.hir_funcs.push(hir::Function {
                name: qname,
                param_count: locals.len() as u32,
                locals,
                ret,
                body: hir::Block { stmts: Vec::new() },
                span: decl.span,
            });
        }
    }

    fn resolve_const(&self, i: usize) -> R<(Type, ConstLit)> {
        let c = &self.consts[i];
        let (lit, lit_ty, neg) = match &c.decl.value.kind {
            AK::Int(n) => (ConstLit::Int(*n), Type::Int, false),
            AK::Unary { op: UnaryOp::Neg, expr } => match &expr.kind {
                AK::Int(n) => match n.checked_neg() {
                    Some(m) => (ConstLit::Int(m), Type::Int, true),
                    None => return err("E0400", c.decl.value.span, "integer literal out of range"),
                },
                _ => return err("E0408", c.decl.value.span, "top-level const initializer must be a literal"),
            },
            AK::Str(s) => (ConstLit::Str(s.clone()), Type::String, false),
            AK::Bool(b) => (ConstLit::Bool(*b), Type::Bool, false),
            _ => return err("E0408", c.decl.value.span, "top-level const initializer must be a literal"),
        };
        let ty = match &c.decl.ty {
            None => lit_ty.clone(),
            Some(te) => self.resolve_type(c.unit, te, false)?,
        };
        let ok = match (&lit_ty, &ty) {
            (Type::Int, Type::Int) => true,
            (Type::Int, Type::Usize) => {
                if neg {
                    return err("E0400", c.decl.value.span, "negative integer literal cannot have type `usize`");
                }
                true
            }
            (a, b) => a == b,
        };
        if !ok {
            return err(
                "E0400",
                c.decl.value.span,
                format!("expected `{}`, found `{}`", self.show(&ty), self.show(&lit_ty)),
            );
        }
        Ok((ty, lit))
    }

    fn check_main(&mut self) {
        let entry = self.prog.entry;
        let unit = &self.prog.units[entry];
        let found = self.funcs.iter().position(|f| f.unit == entry && f.decl.name.name == "main");
        match found {
            None => self.diags.push(Diagnostic::new(
                "E0412",
                Span::new(unit.file, 0, 0),
                "entry file must define `function main(): void`",
            )),
            Some(i) => {
                let f = &self.funcs[i];
                if !f.decl.params.is_empty() || f.ret != Type::Void {
                    self.diags.push(Diagnostic::new(
                        "E0412",
                        f.decl.name.span,
                        "`main` must be declared as `function main(): void` with no parameters",
                    ));
                }
            }
        }
    }

    fn main_id(&self) -> FuncId {
        let entry = self.prog.entry;
        let i = self.funcs.iter().position(|f| f.unit == entry && f.decl.name.name == "main").unwrap_or(0);
        FuncId(i as u32)
    }

    fn variants_of(&self, t: &Type) -> Option<Vec<(String, Vec<Type>)>> {
        match t {
            Type::Union(u) => Some(
                self.unions[u.0 as usize].variants.iter().map(|v| (v.name.clone(), v.payload.clone())).collect(),
            ),
            Type::Option(x) => Some(vec![("Some".into(), vec![(**x).clone()]), ("None".into(), vec![])]),
            Type::Result(a, b) => {
                let ok = if **a == Type::Void { vec![] } else { vec![(**a).clone()] };
                Some(vec![("Ok".into(), ok), ("Err".into(), vec![(**b).clone()])])
            }
            _ => None,
        }
    }

    // -----------------------------------------------------------------------------------------
    // Phase 3: bodies
    // -----------------------------------------------------------------------------------------

    fn check_bodies(&mut self) {
        for i in 0..self.funcs.len() {
            let res = {
                let mut cx = FnCx::new(self, i);
                cx.run()
            };
            match res {
                Ok((locals, body)) => {
                    self.hir_funcs[i].locals = locals;
                    self.hir_funcs[i].body = body;
                }
                Err(d) => self.diags.push(d),
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Function body checking
// ---------------------------------------------------------------------------------------------

struct PlaceInfo {
    place: hir::Place,
    mutable: bool,
    root_name: String,
}

struct FnCx<'c, 'a> {
    ck: &'c Checker<'a>,
    fi: usize,
    unit: usize,
    ret: Type,
    locals: Vec<hir::Local>,
    scopes: Vec<Vec<(String, LocalId)>>,
    /// One flag per enclosing loop: has a `break` targeting it been seen?
    loops: Vec<bool>,
}

/// Syntactic "untyped integer expression": adopts the type demanded by context.
fn untyped_int(e: &ast::Expr) -> bool {
    match &e.kind {
        AK::Int(_) => true,
        AK::Unary { op: UnaryOp::Neg, expr } => untyped_int(expr),
        AK::Binary { op, lhs, rhs } => {
            matches!(op, BinaryOp::Add | BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Rem)
                && untyped_int(lhs)
                && untyped_int(rhs)
        }
        _ => false,
    }
}

fn is_intish(t: &Type) -> bool {
    matches!(t, Type::Int | Type::Usize)
}

impl<'c, 'a> FnCx<'c, 'a> {
    fn new(ck: &'c Checker<'a>, fi: usize) -> FnCx<'c, 'a> {
        let info = &ck.funcs[fi];
        let locals = ck.hir_funcs[fi].locals.clone_locals();
        let mut scope = Vec::new();
        for (i, l) in locals.iter().enumerate() {
            scope.push((l.name.clone(), LocalId(i as u32)));
        }
        FnCx { ck, fi, unit: info.unit, ret: info.ret.clone(), locals, scopes: vec![scope], loops: Vec::new() }
    }

    fn run(&mut self) -> R<(Vec<hir::Local>, hir::Block)> {
        let decl = self.ck.funcs[self.fi].decl;
        let (body, div) = self.block(&decl.body)?;
        if self.ret != Type::Void && !div {
            return err(
                "E0403",
                decl.name.span,
                format!("function `{}` does not return a value on every path", decl.name.name),
            );
        }
        Ok((std::mem::take(&mut self.locals), body))
    }

    fn show(&self, t: &Type) -> String {
        self.ck.show(t)
    }

    fn mismatch<T>(&self, span: Span, expected: &Type, found: &Type) -> R<T> {
        err("E0400", span, format!("expected `{}`, found `{}`", self.show(expected), self.show(found)))
    }

    // ---- scopes & locals -------------------------------------------------------------------

    fn push_scope(&mut self) {
        self.scopes.push(Vec::new());
    }
    fn pop_scope(&mut self) {
        self.scopes.pop();
    }

    fn lookup_local(&self, name: &str) -> Option<LocalId> {
        for s in self.scopes.iter().rev() {
            for (n, id) in s.iter().rev() {
                if n == name {
                    return Some(*id);
                }
            }
        }
        None
    }

    fn new_local(&mut self, name: &str, ty: Type, mutable: bool) -> LocalId {
        self.locals.push(hir::Local { name: name.to_string(), ty, mutable });
        LocalId(self.locals.len() as u32 - 1)
    }

    fn declare(&mut self, name: &ast::Ident, id: LocalId) -> R<()> {
        let scope = self.scopes.last_mut().unwrap();
        if scope.iter().any(|(n, _)| *n == name.name) {
            return err("E0304", name.span, format!("`{}` is already declared in this block", name.name));
        }
        scope.push((name.name.clone(), id));
        Ok(())
    }

    fn local_ty(&self, id: LocalId) -> Type {
        self.locals[id.0 as usize].ty.clone()
    }

    fn global(&self, name: &str) -> Option<ValEnt> {
        self.ck.units[self.unit].scope.vals.get(name).copied()
    }

    // ---- statements ------------------------------------------------------------------------

    /// Returns the block and whether it diverges (last statement returns/diverges).
    fn block(&mut self, b: &ast::Block) -> R<(hir::Block, bool)> {
        self.push_scope();
        let mut stmts = Vec::new();
        let mut div = false;
        for s in &b.stmts {
            let (hs, d) = self.stmt(s)?;
            stmts.push(hs);
            div = d;
        }
        self.pop_scope();
        Ok((hir::Block { stmts }, div))
    }

    fn stmt(&mut self, s: &ast::Stmt) -> R<(hir::Stmt, bool)> {
        match &s.kind {
            StmtKind::Let { mutable, name, ty, init } => {
                let (e, lty) = match ty {
                    Some(te) => {
                        let t = self.ck.resolve_type(self.unit, te, false)?;
                        (self.expect(init, &t)?, t)
                    }
                    None => {
                        let e = self.expr(init, None)?;
                        let t = e.ty.clone();
                        (e, t)
                    }
                };
                if lty == Type::Void {
                    return err("E0400", init.span, "cannot bind a `void` value to a variable");
                }
                if self.scopes.last().unwrap().iter().any(|(n, _)| *n == name.name) {
                    return err("E0304", name.span, format!("`{}` is already declared in this block", name.name));
                }
                let id = self.new_local(&name.name, lty, *mutable);
                self.declare(name, id)?;
                Ok((hir::Stmt::Let { local: id, init: e }, false))
            }
            StmtKind::Assign { target, op, value } => {
                let pi = self.place(target)?;
                if !pi.mutable {
                    return err(
                        "E0401",
                        target.span,
                        format!("cannot assign to `{}`: it is not declared with `let`", pi.root_name),
                    );
                }
                let pty = pi.place.ty.clone();
                let hop = match op {
                    AssignOp::Assign => None,
                    AssignOp::Add => Some(hir::BinOp::Add),
                    AssignOp::Sub => Some(hir::BinOp::Sub),
                    AssignOp::Mul => Some(hir::BinOp::Mul),
                    AssignOp::Div => Some(hir::BinOp::Div),
                    AssignOp::Rem => Some(hir::BinOp::Rem),
                };
                if let Some(o) = hop {
                    let ok = is_intish(&pty) || (o == hir::BinOp::Add && pty == Type::String);
                    if !ok {
                        return err(
                            "E0410",
                            target.span,
                            format!("compound assignment is not defined for type `{}`", self.show(&pty)),
                        );
                    }
                }
                let v = self.expect(value, &pty)?;
                Ok((hir::Stmt::Assign { place: pi.place, op: hop, value: v }, false))
            }
            StmtKind::Expr(e) => {
                if let AK::Match { scrutinee, arms } = &e.kind {
                    let (me, div) = self.match_expr(e.span, scrutinee, arms, None, true)?;
                    return Ok((hir::Stmt::Expr(me), div));
                }
                let he = self.expr(e, None)?;
                Ok((hir::Stmt::Expr(he), false))
            }
            StmtKind::Return(v) => {
                match v {
                    None => {
                        if self.ret != Type::Void {
                            return err(
                                "E0400",
                                s.span,
                                format!("`return;` in a function returning `{}`", self.show(&self.ret)),
                            );
                        }
                        Ok((hir::Stmt::Return(None), true))
                    }
                    Some(e) => {
                        if self.ret == Type::Void {
                            return err("E0400", e.span, "cannot return a value from a function returning `void`");
                        }
                        let ret = self.ret.clone();
                        let he = self.expect(e, &ret)?;
                        Ok((hir::Stmt::Return(Some(he)), true))
                    }
                }
            }
            StmtKind::If { cond, then, els } => {
                let c = self.expect(cond, &Type::Bool)?;
                let (tb, td) = self.block(then)?;
                let (eb, ed) = match els {
                    None => (None, false),
                    Some(es) => match &es.kind {
                        StmtKind::Block(b) => {
                            let (hb, d) = self.block(b)?;
                            (Some(hb), d)
                        }
                        _ => {
                            let (st, d) = self.stmt(es)?;
                            (Some(hir::Block { stmts: vec![st] }), d)
                        }
                    },
                };
                let div = td && els.is_some() && ed;
                Ok((hir::Stmt::If { cond: c, then: tb, els: eb }, div))
            }
            StmtKind::While { cond, body } => {
                let c = self.expect(cond, &Type::Bool)?;
                self.loops.push(false);
                let (b, _) = self.block(body)?;
                let broke = self.loops.pop().unwrap();
                let div = matches!(c.kind, hir::ExprKind::Bool(true)) && !broke;
                Ok((hir::Stmt::While { cond: c, body: b }, div))
            }
            StmtKind::ForOf { name, iter, body } => {
                let it = self.expr(iter, None)?;
                let elem = match &it.ty {
                    Type::Array(t) => (**t).clone(),
                    other => {
                        return err(
                            "E0400",
                            iter.span,
                            format!("`for ... of` requires an array, found `{}`", self.show(other)),
                        )
                    }
                };
                self.push_scope();
                let id = self.new_local(&name.name, elem, false);
                self.declare(name, id)?;
                self.loops.push(false);
                let (b, _) = self.block(body)?;
                self.loops.pop();
                self.pop_scope();
                Ok((hir::Stmt::ForOf { local: id, iter: it, body: b }, false))
            }
            StmtKind::Break => {
                match self.loops.last_mut() {
                    Some(f) => *f = true,
                    None => return err("E0409", s.span, "`break` outside of a loop"),
                }
                Ok((hir::Stmt::Break, true))
            }
            StmtKind::Continue => {
                if self.loops.is_empty() {
                    return err("E0409", s.span, "`continue` outside of a loop");
                }
                Ok((hir::Stmt::Continue, true))
            }
            StmtKind::Block(b) => {
                let (hb, d) = self.block(b)?;
                Ok((hir::Stmt::Block(hb), d))
            }
        }
    }

    // ---- places ----------------------------------------------------------------------------

    fn place(&mut self, e: &ast::Expr) -> R<PlaceInfo> {
        match &e.kind {
            AK::Ident(id) => {
                if let Some(l) = self.lookup_local(&id.name) {
                    let loc = &self.locals[l.0 as usize];
                    return Ok(PlaceInfo {
                        place: hir::Place { root: l, path: Vec::new(), ty: loc.ty.clone() },
                        mutable: loc.mutable,
                        root_name: id.name.clone(),
                    });
                }
                if self.global(&id.name).is_some() {
                    return err("E0401", e.span, format!("cannot assign to `{}`", id.name));
                }
                err("E0300", id.span, format!("unresolved name `{}`", id.name))
            }
            AK::Member { base, name } => {
                let mut p = self.place(base)?;
                match p.place.ty.clone() {
                    Type::Record(r) => {
                        let def = &self.ck.records[r.0 as usize];
                        match def.fields.iter().position(|(n, _)| *n == name.name) {
                            Some(i) => {
                                p.place.path.push(hir::PlaceElem::Field { record: r, index: i as u32 });
                                p.place.ty = def.fields[i].1.clone();
                                Ok(p)
                            }
                            None => err("E0405", name.span, format!("no field `{}` on type `{}`", name.name, def.name)),
                        }
                    }
                    Type::String | Type::Array(_) if name.name == "length" => {
                        err("E0401", e.span, "`length` is read-only")
                    }
                    other => err(
                        "E0405",
                        name.span,
                        format!("no field `{}` on type `{}`", name.name, self.show(&other)),
                    ),
                }
            }
            AK::Index { base, index } => {
                let mut p = self.place(base)?;
                match p.place.ty.clone() {
                    Type::Array(t) => {
                        let idx = self.expect(index, &Type::Usize)?;
                        p.place.path.push(hir::PlaceElem::Index(idx));
                        p.place.ty = *t;
                        Ok(p)
                    }
                    other => err("E0400", e.span, format!("cannot index into type `{}`", self.show(&other))),
                }
            }
            _ => err("E0401", e.span, "expression is not an assignable place"),
        }
    }

    // ---- expressions -----------------------------------------------------------------------

    fn expect(&mut self, e: &ast::Expr, ty: &Type) -> R<hir::Expr> {
        let r = self.expr(e, Some(ty))?;
        if r.ty != *ty {
            return self.mismatch(e.span, ty, &r.ty);
        }
        Ok(r)
    }

    fn int_lit(&self, n: i64, exp: Option<&Type>, span: Span) -> hir::Expr {
        let ty = if exp == Some(&Type::Usize) { Type::Usize } else { Type::Int };
        mk(hir::ExprKind::Int(n), ty, span)
    }

    fn expr(&mut self, e: &ast::Expr, exp: Option<&Type>) -> R<hir::Expr> {
        let span = e.span;
        match &e.kind {
            AK::Int(n) => Ok(self.int_lit(*n, exp, span)),
            AK::Str(s) => Ok(mk(hir::ExprKind::Str(s.clone()), Type::String, span)),
            AK::Bool(b) => Ok(mk(hir::ExprKind::Bool(*b), Type::Bool, span)),
            AK::Ident(id) => self.ident(id, exp, span),
            AK::Unary { op, expr } => self.unary(span, *op, expr, exp),
            AK::Binary { op, lhs, rhs } => self.binary(span, *op, lhs, rhs, exp),
            AK::Call { callee, args } => self.call(span, callee, args, exp),
            AK::Member { base, name } => {
                let b = self.expr(base, None)?;
                match (&b.ty, name.name.as_str()) {
                    (Type::String, "length") => {
                        Ok(mk(hir::ExprKind::Builtin { op: Builtin::StrLength, args: vec![b] }, Type::Usize, span))
                    }
                    (Type::Array(_), "length") => {
                        Ok(mk(hir::ExprKind::Builtin { op: Builtin::ArrLength, args: vec![b] }, Type::Usize, span))
                    }
                    (Type::Record(r), n) => {
                        let def = &self.ck.records[r.0 as usize];
                        match def.fields.iter().position(|(f, _)| f == n) {
                            Some(i) => {
                                let fty = def.fields[i].1.clone();
                                let rid = *r;
                                Ok(mk(
                                    hir::ExprKind::Field { base: Box::new(b), record: rid, index: i as u32 },
                                    fty,
                                    span,
                                ))
                            }
                            None => err("E0405", name.span, format!("no field `{}` on type `{}`", n, def.name)),
                        }
                    }
                    (t, n) => {
                        err("E0405", name.span, format!("no field `{}` on type `{}`", n, self.show(t)))
                    }
                }
            }
            AK::Index { base, index } => {
                let b = self.expr(base, None)?;
                match b.ty.clone() {
                    Type::Array(t) => {
                        let i = self.expect(index, &Type::Usize)?;
                        Ok(mk(hir::ExprKind::Index { base: Box::new(b), index: Box::new(i) }, *t, span))
                    }
                    other => err("E0400", span, format!("cannot index into type `{}`", self.show(&other))),
                }
            }
            AK::Try(inner) => {
                let o = self.expr(inner, None)?;
                let (t, et) = match &o.ty {
                    Type::Result(t, et) => ((**t).clone(), (**et).clone()),
                    other => {
                        return err(
                            "E0406",
                            span,
                            format!("`?` requires a `Result`, found `{}`", self.show(other)),
                        )
                    }
                };
                match &self.ret {
                    Type::Result(_, e2) if **e2 == et => {}
                    Type::Result(_, e2) => {
                        return err(
                            "E0406",
                            span,
                            format!(
                                "error type `{}` does not match the function's error type `{}`",
                                self.show(&et),
                                self.show(e2)
                            ),
                        )
                    }
                    other => {
                        return err(
                            "E0406",
                            span,
                            format!("`?` used in a function returning `{}`, not a `Result`", self.show(other)),
                        )
                    }
                }
                Ok(mk(hir::ExprKind::Try(Box::new(o)), t, span))
            }
            AK::Cond { cond, then, els } => {
                let c = self.expect(cond, &Type::Bool)?;
                let (t, f);
                if untyped_int(then) && !untyped_int(els) {
                    f = self.expr(els, exp)?;
                    let h = if is_intish(&f.ty) { Some(f.ty.clone()) } else { None };
                    t = self.expr(then, h.as_ref())?;
                } else {
                    t = self.expr(then, exp)?;
                    let h = if untyped_int(els) && is_intish(&t.ty) { Some(t.ty.clone()) } else { exp.cloned() };
                    f = self.expr(els, h.as_ref())?;
                }
                if t.ty != f.ty {
                    return err(
                        "E0400",
                        els.span,
                        format!(
                            "branches of conditional have different types `{}` and `{}`",
                            self.show(&t.ty),
                            self.show(&f.ty)
                        ),
                    );
                }
                let ty = t.ty.clone();
                Ok(mk(hir::ExprKind::Cond { cond: Box::new(c), then: Box::new(t), els: Box::new(f) }, ty, span))
            }
            AK::Array(elems) => self.array(span, elems, exp),
            AK::Record { name, spread, fields } => self.record(span, name, spread.as_deref(), fields),
            AK::Match { scrutinee, arms } => self.match_expr(span, scrutinee, arms, exp, false).map(|(e, _)| e),
        }
    }

    fn ident(&mut self, id: &ast::Ident, exp: Option<&Type>, span: Span) -> R<hir::Expr> {
        if let Some(l) = self.lookup_local(&id.name) {
            return Ok(mk(hir::ExprKind::Local(l), self.local_ty(l), span));
        }
        match self.global(&id.name) {
            Some(ValEnt::Const(i)) => {
                let (ty, lit) = self.ck.consts[i].val.clone().unwrap();
                let kind = match lit {
                    ConstLit::Int(n) => hir::ExprKind::Int(n),
                    ConstLit::Str(s) => hir::ExprKind::Str(s),
                    ConstLit::Bool(b) => hir::ExprKind::Bool(b),
                };
                Ok(mk(kind, ty, span))
            }
            Some(ValEnt::Variant { union, tag }) => {
                let def = &self.ck.unions[union.0 as usize].variants[tag as usize];
                if !def.payload.is_empty() {
                    return err(
                        "E0404",
                        span,
                        format!("variant `{}` expects {} argument(s)", def.name, def.payload.len()),
                    );
                }
                Ok(mk(hir::ExprKind::Variant { tag, payload: Vec::new() }, Type::Union(union), span))
            }
            Some(ValEnt::Func(_)) | Some(ValEnt::Std(_)) => {
                err("E0400", span, format!("function `{}` cannot be used as a value", id.name))
            }
            None => match id.name.as_str() {
                "None" => match exp {
                    Some(Type::Option(t)) => Ok(mk(
                        hir::ExprKind::Variant { tag: 1, payload: Vec::new() },
                        Type::Option(t.clone()),
                        span,
                    )),
                    Some(other) => err("E0400", span, format!("expected `{}`, found an `Option`", self.show(other))),
                    None => err("E0407", span, "cannot infer the type of `None`; add a type annotation"),
                },
                "Some" | "Ok" | "Err" => {
                    err("E0404", span, format!("`{}` must be called with arguments", id.name))
                }
                _ => err("E0300", id.span, format!("unresolved name `{}`", id.name)),
            },
        }
    }

    fn unary(&mut self, span: Span, op: UnaryOp, inner: &ast::Expr, exp: Option<&Type>) -> R<hir::Expr> {
        match op {
            UnaryOp::Neg => {
                if let AK::Int(n) = &inner.kind {
                    if exp == Some(&Type::Usize) {
                        return err("E0400", span, "negative integer literal cannot have type `usize`");
                    }
                    return match n.checked_neg() {
                        Some(m) => Ok(mk(hir::ExprKind::Int(m), Type::Int, span)),
                        None => err("E0400", span, "integer literal out of range"),
                    };
                }
                let o = self.expr(inner, None)?;
                if o.ty != Type::Int {
                    return err("E0410", span, format!("cannot negate a value of type `{}`", self.show(&o.ty)));
                }
                Ok(mk(hir::ExprKind::Unary { op: hir::UnOp::Neg, expr: Box::new(o) }, Type::Int, span))
            }
            UnaryOp::Not => {
                let o = self.expr(inner, None)?;
                if o.ty != Type::Bool {
                    return err("E0410", span, format!("`!` requires `bool`, found `{}`", self.show(&o.ty)));
                }
                Ok(mk(hir::ExprKind::Unary { op: hir::UnOp::Not, expr: Box::new(o) }, Type::Bool, span))
            }
        }
    }

    fn binary(
        &mut self,
        span: Span,
        op: BinaryOp,
        lhs: &ast::Expr,
        rhs: &ast::Expr,
        exp: Option<&Type>,
    ) -> R<hir::Expr> {
        let hop = match op {
            BinaryOp::Add => hir::BinOp::Add,
            BinaryOp::Sub => hir::BinOp::Sub,
            BinaryOp::Mul => hir::BinOp::Mul,
            BinaryOp::Div => hir::BinOp::Div,
            BinaryOp::Rem => hir::BinOp::Rem,
            BinaryOp::Eq => hir::BinOp::Eq,
            BinaryOp::Ne => hir::BinOp::Ne,
            BinaryOp::Lt => hir::BinOp::Lt,
            BinaryOp::Le => hir::BinOp::Le,
            BinaryOp::Gt => hir::BinOp::Gt,
            BinaryOp::Ge => hir::BinOp::Ge,
            BinaryOp::And => hir::BinOp::And,
            BinaryOp::Or => hir::BinOp::Or,
        };
        if matches!(op, BinaryOp::And | BinaryOp::Or) {
            let l = self.expr(lhs, None)?;
            let r = self.expr(rhs, None)?;
            if l.ty != Type::Bool || r.ty != Type::Bool {
                return err(
                    "E0410",
                    span,
                    format!(
                        "`&&`/`||` require `bool` operands, found `{}` and `{}`",
                        self.show(&l.ty),
                        self.show(&r.ty)
                    ),
                );
            }
            return Ok(mk(
                hir::ExprKind::Binary { op: hop, lhs: Box::new(l), rhs: Box::new(r) },
                Type::Bool,
                span,
            ));
        }
        let arith = matches!(op, BinaryOp::Add | BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Rem);
        let hint = if arith { exp.filter(|t| is_intish(t)) } else { None };
        let (l, r);
        if untyped_int(lhs) && !untyped_int(rhs) {
            r = self.expr(rhs, hint)?;
            let h = if is_intish(&r.ty) { Some(r.ty.clone()) } else { None };
            l = self.expr(lhs, h.as_ref())?;
        } else {
            l = self.expr(lhs, hint)?;
            let h = if untyped_int(rhs) && is_intish(&l.ty) { Some(l.ty.clone()) } else { None };
            r = self.expr(rhs, h.as_ref())?;
        }
        if l.ty != r.ty && is_intish(&l.ty) && is_intish(&r.ty) {
            return err(
                "E0400",
                span,
                format!("cannot mix `{}` and `{}`; convert explicitly", self.show(&l.ty), self.show(&r.ty)),
            );
        }
        if l.ty != r.ty {
            return err(
                "E0410",
                span,
                format!("operands have different types `{}` and `{}`", self.show(&l.ty), self.show(&r.ty)),
            );
        }
        let ok = match op {
            BinaryOp::Add => is_intish(&l.ty) || l.ty == Type::String,
            BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Rem => is_intish(&l.ty),
            BinaryOp::Eq | BinaryOp::Ne => is_intish(&l.ty) || l.ty == Type::Bool || l.ty == Type::String,
            _ => is_intish(&l.ty),
        };
        if !ok {
            return err("E0410", span, format!("operator is not defined for type `{}`", self.show(&l.ty)));
        }
        let ty = if arith { l.ty.clone() } else { Type::Bool };
        Ok(mk(hir::ExprKind::Binary { op: hop, lhs: Box::new(l), rhs: Box::new(r) }, ty, span))
    }

    fn array(&mut self, span: Span, elems: &[ast::Expr], exp: Option<&Type>) -> R<hir::Expr> {
        let mut pre: Vec<Option<hir::Expr>> = elems.iter().map(|_| None).collect();
        let elem_ty = match exp {
            Some(Type::Array(t)) => (**t).clone(),
            _ => {
                if elems.is_empty() {
                    return err("E0407", span, "cannot infer the element type of `[]`; add a type annotation");
                }
                match elems.iter().position(|e| !untyped_int(e)) {
                    Some(k) => {
                        let he = self.expr(&elems[k], None)?;
                        let t = he.ty.clone();
                        pre[k] = Some(he);
                        t
                    }
                    None => Type::Int,
                }
            }
        };
        if elem_ty == Type::Void {
            return err("E0400", span, "array elements cannot be `void`");
        }
        let mut out = Vec::new();
        for (i, e) in elems.iter().enumerate() {
            match pre[i].take() {
                Some(he) => out.push(he),
                None => out.push(self.expect(e, &elem_ty)?),
            }
        }
        Ok(mk(hir::ExprKind::Array(out), Type::Array(Box::new(elem_ty)), span))
    }

    fn record(
        &mut self,
        span: Span,
        name: &ast::Ident,
        spread: Option<&ast::Expr>,
        fields: &[ast::FieldInit],
    ) -> R<hir::Expr> {
        let rid = match self.ck.resolve_type_name(self.unit, name)? {
            Type::Record(r) => r,
            other => {
                return err(
                    "E0400",
                    name.span,
                    format!("`{}` is not a record type (it is `{}`)", name.name, self.show(&other)),
                )
            }
        };
        let def = &self.ck.records[rid.0 as usize];
        let sp = match spread {
            Some(s) => Some(Box::new(self.expect(s, &Type::Record(rid))?)),
            None => None,
        };
        let mut seen = vec![false; def.fields.len()];
        let mut out = Vec::new();
        for f in fields {
            let idx = match def.fields.iter().position(|(n, _)| *n == f.name.name) {
                Some(i) => i,
                None => {
                    return err(
                        "E0411",
                        f.name.span,
                        format!("record `{}` has no field `{}`", def.name, f.name.name),
                    )
                }
            };
            if seen[idx] {
                return err("E0411", f.name.span, format!("field `{}` given more than once", f.name.name));
            }
            seen[idx] = true;
            let fty = def.fields[idx].1.clone();
            let v = self.expect(&f.value, &fty)?;
            out.push((idx as u32, v));
        }
        if sp.is_none() {
            let missing: Vec<&str> =
                def.fields.iter().zip(&seen).filter(|(_, s)| !**s).map(|((n, _), _)| n.as_str()).collect();
            if !missing.is_empty() {
                return err("E0411", span, format!("missing field(s) in record literal: {}", missing.join(", ")));
            }
        }
        Ok(mk(hir::ExprKind::Record { record: rid, spread: sp, fields: out }, Type::Record(rid), span))
    }

    // ---- calls -----------------------------------------------------------------------------

    fn args_expect(&mut self, span: Span, what: &str, args: &[ast::Expr], params: &[Type]) -> R<Vec<hir::Expr>> {
        if args.len() != params.len() {
            return err(
                "E0404",
                span,
                format!("{} expects {} argument(s), found {}", what, params.len(), args.len()),
            );
        }
        let mut out = Vec::new();
        for (a, p) in args.iter().zip(params) {
            out.push(self.expect(a, p)?);
        }
        Ok(out)
    }

    fn builtin_sig(b: Builtin) -> (Vec<Type>, Type) {
        match b {
            Builtin::ParseInt => (vec![Type::String], Type::Option(Box::new(Type::Int))),
            Builtin::FsReadFile => {
                (vec![Type::String], Type::Result(Box::new(Type::String), Box::new(Type::String)))
            }
            Builtin::FsWriteFile => (
                vec![Type::String, Type::String],
                Type::Result(Box::new(Type::Void), Box::new(Type::String)),
            ),
            Builtin::FsExists => (vec![Type::String], Type::Bool),
            Builtin::ProcessArgs => (vec![], Type::Array(Box::new(Type::String))),
            Builtin::ProcessExit => (vec![Type::Int], Type::Void),
            Builtin::ConsoleLog | Builtin::ConsoleError => (vec![Type::String], Type::Void),
            Builtin::StringFromCharCode => (vec![Type::Int], Type::String),
            _ => (vec![], Type::Void),
        }
    }

    fn call(&mut self, span: Span, callee: &ast::Expr, args: &[ast::Expr], exp: Option<&Type>) -> R<hir::Expr> {
        match &callee.kind {
            AK::Ident(id) => {
                if self.lookup_local(&id.name).is_some() {
                    return err("E0400", callee.span, format!("`{}` is not a function", id.name));
                }
                match self.global(&id.name) {
                    Some(ValEnt::Func(fid)) => {
                        let (params, ret) = {
                            let f = &self.ck.funcs[fid.0 as usize];
                            (f.params.clone(), f.ret.clone())
                        };
                        let a = self.args_expect(span, &format!("function `{}`", id.name), args, &params)?;
                        Ok(mk(hir::ExprKind::Call { func: fid, args: a }, ret, span))
                    }
                    Some(ValEnt::Variant { union, tag }) => {
                        let (vname, payload) = {
                            let v = &self.ck.unions[union.0 as usize].variants[tag as usize];
                            (v.name.clone(), v.payload.clone())
                        };
                        let a = self.args_expect(span, &format!("variant `{}`", vname), args, &payload)?;
                        Ok(mk(hir::ExprKind::Variant { tag, payload: a }, Type::Union(union), span))
                    }
                    Some(ValEnt::Std(b)) => {
                        let (params, ret) = Self::builtin_sig(b);
                        let a = self.args_expect(span, &format!("function `{}`", id.name), args, &params)?;
                        Ok(mk(hir::ExprKind::Builtin { op: b, args: a }, ret, span))
                    }
                    Some(ValEnt::Const(_)) => err("E0400", callee.span, format!("`{}` is not a function", id.name)),
                    None => match id.name.as_str() {
                        "parseInt" => {
                            let (params, ret) = Self::builtin_sig(Builtin::ParseInt);
                            let a = self.args_expect(span, "function `parseInt`", args, &params)?;
                            Ok(mk(hir::ExprKind::Builtin { op: Builtin::ParseInt, args: a }, ret, span))
                        }
                        "Some" | "Ok" | "Err" => self.builtin_ctor(span, &id.name, args, exp),
                        _ => err("E0300", id.span, format!("unresolved name `{}`", id.name)),
                    },
                }
            }
            AK::Member { base, name } => {
                if let AK::Ident(bid) = &base.kind {
                    let special = (bid.name == "console" || bid.name == "String")
                        && self.lookup_local(&bid.name).is_none()
                        && self.global(&bid.name).is_none();
                    if special {
                        let b = match (bid.name.as_str(), name.name.as_str()) {
                            ("console", "log") => Builtin::ConsoleLog,
                            ("console", "error") => Builtin::ConsoleError,
                            ("String", "fromCharCode") => Builtin::StringFromCharCode,
                            _ => {
                                return err(
                                    "E0405",
                                    name.span,
                                    format!("`{}` has no member `{}`", bid.name, name.name),
                                )
                            }
                        };
                        let (params, ret) = Self::builtin_sig(b);
                        let a = self.args_expect(span, &format!("`{}.{}`", bid.name, name.name), args, &params)?;
                        return Ok(mk(hir::ExprKind::Builtin { op: b, args: a }, ret, span));
                    }
                }
                self.method_call(span, base, name, args)
            }
            _ => err("E0400", callee.span, "expression is not callable"),
        }
    }

    fn builtin_ctor(&mut self, span: Span, name: &str, args: &[ast::Expr], exp: Option<&Type>) -> R<hir::Expr> {
        match name {
            "Some" => {
                if args.len() != 1 {
                    return err("E0404", span, format!("`Some` expects 1 argument, found {}", args.len()));
                }
                let p = match exp {
                    Some(Type::Option(t)) => self.expect(&args[0], t)?,
                    _ => self.expr(&args[0], None)?,
                };
                if p.ty == Type::Void {
                    return err("E0400", args[0].span, "`Option<void>` is not allowed");
                }
                let ty = Type::Option(Box::new(p.ty.clone()));
                Ok(mk(hir::ExprKind::Variant { tag: 0, payload: vec![p] }, ty, span))
            }
            "Ok" => {
                let (t, e) = match exp {
                    Some(Type::Result(t, e)) => ((**t).clone(), (**e).clone()),
                    Some(other) => {
                        return err("E0400", span, format!("expected `{}`, found a `Result`", self.show(other)))
                    }
                    None => {
                        // Ok(x) can infer T but not E.
                        for a in args {
                            self.expr(a, None)?;
                        }
                        return err("E0407", span, "cannot infer the error type of `Ok(..)`; add a type annotation");
                    }
                };
                let want = if t == Type::Void { 0 } else { 1 };
                if args.len() != want {
                    return err("E0404", span, format!("`Ok` expects {} argument(s), found {}", want, args.len()));
                }
                let payload = if want == 1 { vec![self.expect(&args[0], &t)?] } else { vec![] };
                Ok(mk(hir::ExprKind::Variant { tag: 0, payload }, Type::Result(Box::new(t), Box::new(e)), span))
            }
            _ => {
                let (t, e) = match exp {
                    Some(Type::Result(t, e)) => ((**t).clone(), (**e).clone()),
                    Some(other) => {
                        return err("E0400", span, format!("expected `{}`, found a `Result`", self.show(other)))
                    }
                    None => {
                        for a in args {
                            self.expr(a, None)?;
                        }
                        return err("E0407", span, "cannot infer the success type of `Err(..)`; add a type annotation");
                    }
                };
                if args.len() != 1 {
                    return err("E0404", span, format!("`Err` expects 1 argument, found {}", args.len()));
                }
                let p = self.expect(&args[0], &e)?;
                Ok(mk(
                    hir::ExprKind::Variant { tag: 1, payload: vec![p] },
                    Type::Result(Box::new(t), Box::new(e)),
                    span,
                ))
            }
        }
    }

    fn method_sig(recv: &Type, name: &str) -> Option<(Builtin, Vec<Type>, Type)> {
        use Type::*;
        let opt = |t: Type| Option(Box::new(t));
        Some(match (recv, name) {
            (String, "charCodeAt") => (Builtin::StrCharCodeAt, vec![Usize], Int),
            (String, "charAt") => (Builtin::StrCharAt, vec![Usize], String),
            (String, "substring") => (Builtin::StrSubstring, vec![Usize, Usize], String),
            (String, "indexOf") => (Builtin::StrIndexOf, vec![String], opt(Usize)),
            (String, "includes") => (Builtin::StrIncludes, vec![String], Bool),
            (String, "startsWith") => (Builtin::StrStartsWith, vec![String], Bool),
            (String, "endsWith") => (Builtin::StrEndsWith, vec![String], Bool),
            (String, "split") => (Builtin::StrSplit, vec![String], Array(Box::new(String))),
            (String, "trim") => (Builtin::StrTrim, vec![], String),
            (Array(t), "get") => (Builtin::ArrGet, vec![Usize], opt((**t).clone())),
            (Array(t), "slice") => (Builtin::ArrSlice, vec![Usize, Usize], Array(t.clone())),
            (Array(t), "concat") => (Builtin::ArrConcat, vec![Array(t.clone())], Array(t.clone())),
            (Array(t), "join") if **t == String => (Builtin::ArrJoin, vec![String], String),
            (Int, "toString") => (Builtin::IntToString, vec![], String),
            (Int, "toUsize") => (Builtin::IntToUsize, vec![], Usize),
            (Usize, "toString") => (Builtin::UsizeToString, vec![], String),
            (Usize, "toInt") => (Builtin::UsizeToInt, vec![], Int),
            (Bool, "toString") => (Builtin::BoolToString, vec![], String),
            (Option(_), "isSome") => (Builtin::OptIsSome, vec![], Bool),
            (Option(_), "isNone") => (Builtin::OptIsNone, vec![], Bool),
            (Option(t), "unwrap") => (Builtin::OptUnwrap, vec![], (**t).clone()),
            (Option(t), "unwrapOr") => (Builtin::OptUnwrapOr, vec![(**t).clone()], (**t).clone()),
            (Result(..), "isOk") => (Builtin::ResIsOk, vec![], Bool),
            (Result(..), "isErr") => (Builtin::ResIsErr, vec![], Bool),
            (Result(t, _), "unwrap") => (Builtin::ResUnwrap, vec![], (**t).clone()),
            (Result(_, e), "unwrapErr") => (Builtin::ResUnwrapErr, vec![], (**e).clone()),
            _ => return None,
        })
    }

    fn method_call(&mut self, span: Span, base: &ast::Expr, name: &ast::Ident, args: &[ast::Expr]) -> R<hir::Expr> {
        let n = name.name.as_str();
        if n == "push" || n == "pop" {
            let place_shaped = match &base.kind {
                AK::Ident(id) => self.lookup_local(&id.name).is_some(),
                AK::Member { .. } | AK::Index { .. } => true,
                _ => false,
            };
            if place_shaped {
                let pi = self.place(base)?;
                if let Type::Array(t) = pi.place.ty.clone() {
                    if !pi.mutable {
                        return err(
                            "E0401",
                            base.span,
                            format!("cannot call `{}` on `{}`: it is not declared with `let`", n, pi.root_name),
                        );
                    }
                    let (op, params, ret) = if n == "push" {
                        (MutBuiltin::ArrPush, vec![(*t).clone()], Type::Void)
                    } else {
                        (MutBuiltin::ArrPop, vec![], Type::Option(t.clone()))
                    };
                    let a = self.args_expect(span, &format!("method `{}`", n), args, &params)?;
                    return Ok(mk(hir::ExprKind::MutMethod { op, place: pi.place, args: a }, ret, span));
                }
                return err(
                    "E0405",
                    name.span,
                    format!("no method `{}` on type `{}`", n, self.show(&pi.place.ty)),
                );
            }
            let b = self.expr(base, None)?;
            if matches!(b.ty, Type::Array(_)) {
                return err("E0401", base.span, format!("receiver of `{}` must be a mutable place", n));
            }
            return err("E0405", name.span, format!("no method `{}` on type `{}`", n, self.show(&b.ty)));
        }
        let b = self.expr(base, None)?;
        let (op, params, ret) = match Self::method_sig(&b.ty, n) {
            Some(s) => s,
            None => {
                return err("E0405", name.span, format!("no method `{}` on type `{}`", n, self.show(&b.ty)));
            }
        };
        let mut a = vec![b];
        a.extend(self.args_expect(span, &format!("method `{}`", n), args, &params)?);
        Ok(mk(hir::ExprKind::Builtin { op, args: a }, ret, span))
    }

    // ---- match -----------------------------------------------------------------------------

    /// Returns the match expression and (statement position only) whether every arm diverges.
    fn match_expr(
        &mut self,
        span: Span,
        scrut: &ast::Expr,
        arms: &[ast::MatchArm],
        exp: Option<&Type>,
        stmt_pos: bool,
    ) -> R<(hir::Expr, bool)> {
        let s = self.expr(scrut, None)?;
        let sty = s.ty.clone();
        let variants = self.ck.variants_of(&sty);
        let lit_scrut = matches!(sty, Type::Int | Type::Usize | Type::String | Type::Bool);
        if variants.is_none() && !lit_scrut {
            return err("E0402", scrut.span, format!("cannot match on a value of type `{}`", self.show(&sty)));
        }
        let mut covered = vec![false; variants.as_ref().map(|v| v.len()).unwrap_or(0)];
        let mut wild = false;
        let mut target: Option<Type> = if stmt_pos { Some(Type::Void) } else { exp.cloned() };
        let mut harms = Vec::new();
        let mut all_div = true;
        for arm in arms {
            self.push_scope();
            let pat = self.pattern(&arm.pattern, &sty, variants.as_deref(), &mut covered, &mut wild)?;
            let (body, value, div);
            match &arm.body {
                ArmBody::Expr(e) => {
                    if stmt_pos {
                        let (he, d) = if let AK::Match { scrutinee, arms: inner } = &e.kind {
                            self.match_expr(e.span, scrutinee, inner, None, true)?
                        } else {
                            (self.expr(e, None)?, false)
                        };
                        body = hir::Block { stmts: vec![hir::Stmt::Expr(he)] };
                        value = None;
                        div = d;
                    } else {
                        let he = match &target {
                            Some(t) => {
                                let t = t.clone();
                                self.expect(e, &t)?
                            }
                            None => {
                                let he = self.expr(e, None)?;
                                target = Some(he.ty.clone());
                                he
                            }
                        };
                        body = hir::Block { stmts: Vec::new() };
                        value = Some(he);
                        div = false;
                    }
                }
                ArmBody::Block(b) => {
                    let (hb, d) = self.block(b)?;
                    if !stmt_pos && !d {
                        return err(
                            "E0400",
                            b.span,
                            "block arm of a match used as an expression must end in `return`, `break` or `continue`",
                        )
                        .map_err(|dg: Diagnostic| {
                            dg.note("a block arm has no value; use an expression arm to produce a value")
                        });
                    }
                    body = hb;
                    value = None;
                    div = d;
                }
            }
            all_div &= div;
            self.pop_scope();
            harms.push(hir::MatchArm { pattern: pat, body, value });
        }
        if !wild {
            match &variants {
                Some(vs) => {
                    let missing: Vec<&str> =
                        vs.iter().zip(&covered).filter(|(_, c)| !**c).map(|((n, _), _)| n.as_str()).collect();
                    if !missing.is_empty() {
                        return err(
                            "E0402",
                            span,
                            format!("non-exhaustive match: missing {}", missing.join(", ")),
                        );
                    }
                }
                None => {
                    return err("E0402", span, "match on a scalar value requires a `_` arm");
                }
            }
        }
        let ty = match target {
            Some(t) => t,
            None => return err("E0407", span, "cannot infer the type of a match whose arms all diverge"),
        };
        let all_div = stmt_pos && !arms.is_empty() && all_div;
        Ok((mk(hir::ExprKind::Match { scrutinee: Box::new(s), arms: harms }, ty, span), all_div))
    }

    fn pattern(
        &mut self,
        p: &ast::Pattern,
        sty: &Type,
        variants: Option<&[(String, Vec<Type>)]>,
        covered: &mut [bool],
        wild: &mut bool,
    ) -> R<hir::Pattern> {
        match &p.kind {
            PatternKind::Wildcard => {
                *wild = true;
                Ok(hir::Pattern::Wildcard)
            }
            PatternKind::Ident(id) => {
                let Some(vs) = variants else {
                    return err("E0402", p.span, "variant pattern used on a scalar scrutinee");
                };
                let Some(idx) = vs.iter().position(|(n, _)| *n == id.name) else {
                    return err(
                        "E0405",
                        id.span,
                        format!("`{}` is not a variant of `{}`", id.name, self.show(sty)),
                    );
                };
                if !vs[idx].1.is_empty() {
                    return err(
                        "E0402",
                        p.span,
                        format!("variant `{}` has {} field(s); pattern binds none", id.name, vs[idx].1.len()),
                    );
                }
                covered[idx] = true;
                Ok(hir::Pattern::Variant { tag: idx as u32, bindings: Vec::new() })
            }
            PatternKind::Variant { name, args } => {
                let Some(vs) = variants else {
                    return err("E0402", p.span, "variant pattern used on a scalar scrutinee");
                };
                let Some(idx) = vs.iter().position(|(n, _)| *n == name.name) else {
                    return err(
                        "E0405",
                        name.span,
                        format!("`{}` is not a variant of `{}`", name.name, self.show(sty)),
                    );
                };
                let payload = &vs[idx].1;
                if payload.len() != args.len() {
                    return err(
                        "E0402",
                        p.span,
                        format!(
                            "variant `{}` has {} field(s), pattern has {}",
                            name.name,
                            payload.len(),
                            args.len()
                        ),
                    );
                }
                covered[idx] = true;
                let mut bindings = Vec::new();
                for (sub, ty) in args.iter().zip(payload) {
                    match &sub.kind {
                        PatternKind::Wildcard => bindings.push(None),
                        PatternKind::Ident(b) => {
                            let id = self.new_local(&b.name, ty.clone(), false);
                            self.declare(b, id)?;
                            bindings.push(Some(id));
                        }
                        _ => {
                            return err(
                                "E0402",
                                sub.span,
                                "sub-patterns must be a binding name or `_` in Orin-B",
                            )
                        }
                    }
                }
                Ok(hir::Pattern::Variant { tag: idx as u32, bindings })
            }
            PatternKind::Int(n) => match sty {
                Type::Int => Ok(hir::Pattern::Int(*n)),
                Type::Usize if *n >= 0 => Ok(hir::Pattern::Int(*n)),
                Type::Usize => err("E0400", p.span, "negative integer literal cannot have type `usize`"),
                _ if variants.is_some() => err("E0402", p.span, "literal pattern on a variant scrutinee"),
                other => self.mismatch(p.span, other, &Type::Int),
            },
            PatternKind::Str(s) => match sty {
                Type::String => Ok(hir::Pattern::Str(s.clone())),
                _ if variants.is_some() => err("E0402", p.span, "literal pattern on a variant scrutinee"),
                other => self.mismatch(p.span, other, &Type::String),
            },
            PatternKind::Bool(b) => match sty {
                Type::Bool => Ok(hir::Pattern::Bool(*b)),
                _ if variants.is_some() => err("E0402", p.span, "literal pattern on a variant scrutinee"),
                other => self.mismatch(p.span, other, &Type::Bool),
            },
        }
    }
}

/// `hir::Local` is not `Clone`; small helper for copying parameter locals into a `FnCx`.
trait CloneLocals {
    fn clone_locals(&self) -> Vec<hir::Local>;
}

impl CloneLocals for Vec<hir::Local> {
    fn clone_locals(&self) -> Vec<hir::Local> {
        self.iter().map(|l| hir::Local { name: l.name.clone(), ty: l.ty.clone(), mutable: l.mutable }).collect()
    }
}
