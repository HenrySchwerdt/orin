//! Checker tests. ASTs are built by hand (the parser is developed concurrently).

use super::*;
use crate::ast as a;
use crate::ast::{AssignOp, BinaryOp};
use crate::hir as h;
use crate::loader::Unit;
use crate::span::FileId;
use std::path::PathBuf;

// ---- builders ------------------------------------------------------------------------------

fn sp() -> Span {
    Span::new(FileId(0), 0, 0)
}
fn id(n: &str) -> a::Ident {
    a::Ident { name: n.into(), span: sp() }
}
fn ex(kind: a::ExprKind) -> a::Expr {
    a::Expr { kind, span: sp() }
}
fn int(n: i64) -> a::Expr {
    ex(AK::Int(n))
}
fn st(s: &str) -> a::Expr {
    ex(AK::Str(s.into()))
}
fn bl(b: bool) -> a::Expr {
    ex(AK::Bool(b))
}
fn v(n: &str) -> a::Expr {
    ex(AK::Ident(id(n)))
}
fn call(n: &str, args: Vec<a::Expr>) -> a::Expr {
    ex(AK::Call { callee: Box::new(v(n)), args })
}
fn mcall(base: a::Expr, n: &str, args: Vec<a::Expr>) -> a::Expr {
    ex(AK::Call { callee: Box::new(mem(base, n)), args })
}
fn mem(base: a::Expr, n: &str) -> a::Expr {
    ex(AK::Member { base: Box::new(base), name: id(n) })
}
fn idx(base: a::Expr, i: a::Expr) -> a::Expr {
    ex(AK::Index { base: Box::new(base), index: Box::new(i) })
}
fn bin(op: BinaryOp, l: a::Expr, r: a::Expr) -> a::Expr {
    ex(AK::Binary { op, lhs: Box::new(l), rhs: Box::new(r) })
}
fn neg(e: a::Expr) -> a::Expr {
    ex(AK::Unary { op: UnaryOp::Neg, expr: Box::new(e) })
}
fn not(e: a::Expr) -> a::Expr {
    ex(AK::Unary { op: UnaryOp::Not, expr: Box::new(e) })
}
fn arr(es: Vec<a::Expr>) -> a::Expr {
    ex(AK::Array(es))
}
fn try_(e: a::Expr) -> a::Expr {
    ex(AK::Try(Box::new(e)))
}
fn rec(name: &str, spread: Option<a::Expr>, fields: Vec<(&str, a::Expr)>) -> a::Expr {
    ex(AK::Record {
        name: id(name),
        spread: spread.map(Box::new),
        fields: fields.into_iter().map(|(n, e)| a::FieldInit { name: id(n), value: e, span: sp() }).collect(),
    })
}
fn mat(scrut: a::Expr, arms: Vec<(a::Pattern, a::ArmBody)>) -> a::Expr {
    ex(AK::Match {
        scrutinee: Box::new(scrut),
        arms: arms.into_iter().map(|(pattern, body)| a::MatchArm { pattern, body, span: sp() }).collect(),
    })
}
fn pat(kind: PatternKind) -> a::Pattern {
    a::Pattern { kind, span: sp() }
}
fn pw() -> a::Pattern {
    pat(PatternKind::Wildcard)
}
fn pi(n: &str) -> a::Pattern {
    pat(PatternKind::Ident(id(n)))
}
fn pv(n: &str, subs: Vec<a::Pattern>) -> a::Pattern {
    pat(PatternKind::Variant { name: id(n), args: subs })
}
fn pint(n: i64) -> a::Pattern {
    pat(PatternKind::Int(n))
}
fn ae(e: a::Expr) -> a::ArmBody {
    a::ArmBody::Expr(e)
}
fn ab(stmts: Vec<a::Stmt>) -> a::ArmBody {
    a::ArmBody::Block(block(stmts))
}
fn block(stmts: Vec<a::Stmt>) -> a::Block {
    a::Block { stmts, span: sp() }
}
fn sk(kind: StmtKind) -> a::Stmt {
    a::Stmt { kind, span: sp() }
}
fn let_(n: &str, t: Option<a::TypeExpr>, init: a::Expr) -> a::Stmt {
    sk(StmtKind::Let { mutable: true, name: id(n), ty: t, init })
}
fn const_(n: &str, t: Option<a::TypeExpr>, init: a::Expr) -> a::Stmt {
    sk(StmtKind::Let { mutable: false, name: id(n), ty: t, init })
}
fn assign(target: a::Expr, op: AssignOp, value: a::Expr) -> a::Stmt {
    sk(StmtKind::Assign { target, op, value })
}
fn es(e: a::Expr) -> a::Stmt {
    sk(StmtKind::Expr(e))
}
fn ret(e: a::Expr) -> a::Stmt {
    sk(StmtKind::Return(Some(e)))
}
fn ret_void() -> a::Stmt {
    sk(StmtKind::Return(None))
}
fn if_(c: a::Expr, then: Vec<a::Stmt>, els: Option<Vec<a::Stmt>>) -> a::Stmt {
    sk(StmtKind::If { cond: c, then: block(then), els: els.map(|e| Box::new(sk(StmtKind::Block(block(e))))) })
}
fn while_(c: a::Expr, body: Vec<a::Stmt>) -> a::Stmt {
    sk(StmtKind::While { cond: c, body: block(body) })
}
fn forof(n: &str, it: a::Expr, body: Vec<a::Stmt>) -> a::Stmt {
    sk(StmtKind::ForOf { name: id(n), iter: it, body: block(body) })
}
fn brk() -> a::Stmt {
    sk(StmtKind::Break)
}
fn cont() -> a::Stmt {
    sk(StmtKind::Continue)
}
fn ty(n: &str) -> a::TypeExpr {
    a::TypeExpr { kind: TypeExprKind::Named { name: id(n), args: vec![] }, span: sp() }
}
fn tya(n: &str, args: Vec<a::TypeExpr>) -> a::TypeExpr {
    a::TypeExpr { kind: TypeExprKind::Named { name: id(n), args }, span: sp() }
}
fn tarr(t: a::TypeExpr) -> a::TypeExpr {
    a::TypeExpr { kind: TypeExprKind::Array(Box::new(t)), span: sp() }
}
fn func(n: &str, params: Vec<(&str, a::TypeExpr)>, ret: Option<a::TypeExpr>, body: Vec<a::Stmt>) -> Item {
    Item::Function(a::FunctionDecl {
        exported: false,
        name: id(n),
        type_params: vec![],
        params: params.into_iter().map(|(n, t)| a::Param { name: id(n), ty: t, span: sp() }).collect(),
        ret,
        body: block(body),
        span: sp(),
    })
}
fn main_fn(body: Vec<a::Stmt>) -> Item {
    func("main", vec![], None, body)
}
fn alias(n: &str, t: a::TypeExpr) -> Item {
    Item::Type(a::TypeDecl { exported: false, name: id(n), type_params: vec![], body: TypeDeclBody::Alias(t), span: sp() })
}
fn record(n: &str, fields: Vec<(&str, a::TypeExpr)>) -> Item {
    Item::Type(a::TypeDecl {
        exported: false,
        name: id(n),
        type_params: vec![],
        body: TypeDeclBody::Record(
            fields.into_iter().map(|(n, t)| a::FieldDecl { name: id(n), ty: t, span: sp() }).collect(),
        ),
        span: sp(),
    })
}
fn union(n: &str, vs: Vec<(&str, Vec<a::TypeExpr>)>) -> Item {
    Item::Type(a::TypeDecl {
        exported: false,
        name: id(n),
        type_params: vec![],
        body: TypeDeclBody::Union(
            vs.into_iter().map(|(n, p)| a::VariantDecl { name: id(n), payload: p, span: sp() }).collect(),
        ),
        span: sp(),
    })
}
fn konst(n: &str, t: Option<a::TypeExpr>, e: a::Expr) -> Item {
    Item::Const(a::ConstDecl { exported: false, name: id(n), ty: t, value: e, span: sp() })
}
fn export(mut item: Item) -> Item {
    match &mut item {
        Item::Function(f) => f.exported = true,
        Item::Type(t) => t.exported = true,
        Item::Const(c) => c.exported = true,
        _ => {}
    }
    item
}
fn import(names: &[&str], path: &str) -> Item {
    Item::Import(a::ImportDecl {
        names: names.iter().map(|n| id(n)).collect(),
        path: path.into(),
        path_span: sp(),
        span: sp(),
    })
}
fn reexport(names: &[&str], path: &str) -> Item {
    Item::ReExport(a::ReExportDecl {
        names: names.iter().map(|n| id(n)).collect(),
        path: path.into(),
        path_span: sp(),
        span: sp(),
    })
}
fn unit(name: &str, items: Vec<Item>, imports: Vec<ImportTarget>) -> Unit {
    Unit {
        file: FileId(0),
        path: PathBuf::from(format!("/{}.or", name)),
        name: name.into(),
        ast: a::Module { file: FileId(0), items },
        imports,
    }
}
fn run_units(units: Vec<Unit>) -> DResult<h::Program> {
    let entry = units.len() - 1;
    let prog = LoadedProgram { units, entry };
    check(&prog, &SourceMap::new())
}
fn run(items: Vec<Item>) -> DResult<h::Program> {
    run_units(vec![unit("main", items, vec![])])
}
fn ok(items: Vec<Item>) -> h::Program {
    match run(items) {
        Ok(p) => p,
        Err(d) => panic!("unexpected diagnostics: {:?}", d.iter().map(|d| (d.code, d.message.clone())).collect::<Vec<_>>()),
    }
}
/// Check a program consisting of `items` plus a `main` with `body`.
fn ok_main(mut items: Vec<Item>, body: Vec<a::Stmt>) -> h::Program {
    items.push(main_fn(body));
    ok(items)
}
fn codes(r: DResult<h::Program>) -> Vec<&'static str> {
    match r {
        Ok(_) => vec![],
        Err(d) => d.iter().map(|d| d.code).collect(),
    }
}
fn fails(items: Vec<Item>, code: &str) {
    let c = codes(run(items));
    assert_eq!(c.first().copied(), Some(code), "diagnostics: {:?}", c);
}
fn fails_main(mut items: Vec<Item>, body: Vec<a::Stmt>, code: &str) {
    items.push(main_fn(body));
    fails(items, code);
}
fn func_named<'p>(p: &'p h::Program, name: &str) -> &'p h::Function {
    p.functions.iter().find(|f| f.name == name).unwrap_or_else(|| panic!("no function {}", name))
}
fn main_of(p: &h::Program) -> &h::Function {
    &p.functions[p.main.0 as usize]
}
fn let_init(f: &h::Function, i: usize) -> &h::Expr {
    match &f.body.stmts[i] {
        h::Stmt::Let { init, .. } => init,
        _ => panic!("statement {} is not a let", i),
    }
}

// ---- positive tests ------------------------------------------------------------------------

#[test]
fn literal_adopts_expected_usize_and_defaults_to_int() {
    let p = ok_main(vec![], vec![const_("n", Some(ty("usize")), int(3)), const_("m", None, int(4))]);
    let f = main_of(&p);
    assert_eq!(let_init(f, 0).ty, Type::Usize);
    assert_eq!(let_init(f, 1).ty, Type::Int);
    assert_eq!(f.locals[0].ty, Type::Usize);
    assert!(!f.locals[0].mutable);
}

#[test]
fn binary_literal_adopts_other_operand_type() {
    let p = ok(vec![
        func("f", vec![("x", ty("usize"))], Some(ty("usize")), vec![ret(bin(BinaryOp::Add, v("x"), int(1)))]),
        func("g", vec![("x", ty("usize"))], Some(ty("usize")), vec![ret(bin(BinaryOp::Sub, int(10), v("x")))]),
        func("h", vec![("x", ty("usize"))], Some(ty("bool")), vec![ret(bin(BinaryOp::Lt, v("x"), int(2)))]),
        main_fn(vec![]),
    ]);
    for n in ["main.f", "main.g"] {
        match &func_named(&p, n).body.stmts[0] {
            h::Stmt::Return(Some(e)) => match &e.kind {
                h::ExprKind::Binary { lhs, rhs, .. } => {
                    assert_eq!(lhs.ty, Type::Usize);
                    assert_eq!(rhs.ty, Type::Usize);
                }
                _ => panic!(),
            },
            _ => panic!(),
        }
    }
}

#[test]
fn negative_literal_folds() {
    let p = ok_main(vec![], vec![const_("a", None, neg(int(5)))]);
    let e = let_init(main_of(&p), 0);
    assert!(matches!(e.kind, h::ExprKind::Int(-5)));
    assert_eq!(e.ty, Type::Int);
}

#[test]
fn option_result_variant_tags() {
    let opt = tya("Option", vec![ty("int")]);
    let res = tya("Result", vec![ty("int"), ty("string")]);
    let p = ok_main(
        vec![],
        vec![
            const_("a", Some(opt.clone()), call("Some", vec![int(1)])),
            const_("b", Some(opt.clone()), v("None")),
            const_("c", Some(res.clone()), call("Ok", vec![int(1)])),
            const_("d", Some(res.clone()), call("Err", vec![st("x")])),
            const_("e", None, call("Some", vec![int(1)])),
        ],
    );
    let f = main_of(&p);
    let tag = |i| match &let_init(f, i).kind {
        h::ExprKind::Variant { tag, .. } => *tag,
        _ => panic!(),
    };
    assert_eq!([tag(0), tag(1), tag(2), tag(3)], [0, 1, 0, 1]);
    assert_eq!(let_init(f, 0).ty, Type::Option(Box::new(Type::Int)));
    assert_eq!(let_init(f, 3).ty, Type::Result(Box::new(Type::Int), Box::new(Type::String)));
    assert_eq!(let_init(f, 4).ty, Type::Option(Box::new(Type::Int)));
}

#[test]
fn result_void_ok_has_empty_payload() {
    let res = tya("Result", vec![ty("void"), ty("string")]);
    let p = ok(vec![
        func("f", vec![], Some(res), vec![ret(call("Ok", vec![]))]),
        main_fn(vec![]),
    ]);
    match &func_named(&p, "main.f").body.stmts[0] {
        h::Stmt::Return(Some(e)) => match &e.kind {
            h::ExprKind::Variant { tag: 0, payload } => assert!(payload.is_empty()),
            _ => panic!(),
        },
        _ => panic!(),
    }
}

#[test]
fn user_union_tags_and_ids() {
    let p = ok_main(
        vec![
            union("Shape", vec![("Circle", vec![ty("int")]), ("Rect", vec![ty("int"), ty("int")]), ("Empty", vec![])]),
            record("P", vec![("x", ty("int"))]),
        ],
        vec![
            const_("a", None, call("Rect", vec![int(1), int(2)])),
            const_("b", None, v("Empty")),
        ],
    );
    assert_eq!(p.unions.len(), 1);
    assert_eq!(p.unions[0].name, "main.Shape");
    assert_eq!(p.unions[0].variants[1].payload, vec![Type::Int, Type::Int]);
    assert_eq!(p.records[0].name, "main.P");
    let f = main_of(&p);
    assert!(matches!(&let_init(f, 0).kind, h::ExprKind::Variant { tag: 1, payload } if payload.len() == 2));
    assert!(matches!(&let_init(f, 1).kind, h::ExprKind::Variant { tag: 2, .. }));
    assert_eq!(let_init(f, 1).ty, Type::Union(UnionId(0)));
}

#[test]
fn alias_expansion() {
    let p = ok(vec![
        alias("Name", ty("string")),
        alias("Names", tarr(ty("Name"))),
        func("f", vec![("xs", ty("Names"))], Some(ty("Name")), vec![ret(mcall(v("xs"), "join", vec![st(",")]))]),
        main_fn(vec![]),
    ]);
    let f = func_named(&p, "main.f");
    assert_eq!(f.locals[0].ty, Type::Array(Box::new(Type::String)));
    assert_eq!(f.ret, Type::String);
}

#[test]
fn alias_of_record_and_union_usable() {
    ok(vec![
        record("P", vec![("x", ty("int"))]),
        alias("Q", ty("P")),
        main_fn(vec![const_("p", Some(ty("Q")), rec("Q", None, vec![("x", int(1))]))]),
    ]);
}

#[test]
fn imports_across_units() {
    let lib = unit(
        "lib/util",
        vec![
            export(func("add", vec![("a", ty("int")), ("b", ty("int"))], Some(ty("int")), vec![ret(bin(BinaryOp::Add, v("a"), v("b")))])),
            export(union("Shape", vec![("Circle", vec![ty("int")]), ("Empty", vec![])])),
            export(record("P", vec![("x", ty("int"))])),
            func("hidden", vec![], None, vec![]),
        ],
        vec![],
    );
    let main = unit(
        "main",
        vec![
            import(&["add", "Shape", "P"], "./lib/util"),
            main_fn(vec![
                const_("n", None, call("add", vec![int(1), int(2)])),
                const_("s", None, call("Circle", vec![int(1)])),
                const_("e", None, v("Empty")),
                const_("p", None, rec("P", None, vec![("x", int(1))])),
            ]),
        ],
        vec![ImportTarget::Unit(0)],
    );
    let p = run_units(vec![lib, main]).unwrap();
    assert_eq!(p.functions[0].name, "lib/util.add");
    assert_eq!(p.functions[2].name, "main.main");
    let f = main_of(&p);
    assert!(matches!(&let_init(f, 0).kind, h::ExprKind::Call { func: FuncId(0), .. }));
    assert!(matches!(&let_init(f, 1).kind, h::ExprKind::Variant { tag: 0, .. }));
    assert_eq!(let_init(f, 3).ty, Type::Record(RecordId(0)));
    assert_eq!(p.records[0].name, "lib/util.P");
}

#[test]
fn import_of_private_name_is_e0300() {
    let lib = unit("lib", vec![func("hidden", vec![], None, vec![])], vec![]);
    let main = unit("main", vec![import(&["hidden"], "./lib"), main_fn(vec![])], vec![ImportTarget::Unit(0)]);
    assert_eq!(codes(run_units(vec![lib, main])), vec!["E0300"]);
}

#[test]
fn reexports_are_transitive() {
    let a_ = unit(
        "a",
        vec![export(func("f", vec![], Some(ty("int")), vec![ret(int(1))])), export(union("U", vec![("V", vec![])]))],
        vec![],
    );
    let b_ = unit("b", vec![reexport(&["f", "U"], "./a")], vec![ImportTarget::Unit(0)]);
    let c_ = unit("c", vec![reexport(&["f"], "./b")], vec![ImportTarget::Unit(1)]);
    let main = unit(
        "main",
        vec![
            import(&["f"], "./c"),
            import(&["U"], "./b"),
            main_fn(vec![const_("x", None, call("f", vec![])), const_("y", None, v("V"))]),
        ],
        vec![ImportTarget::Unit(2), ImportTarget::Unit(1)],
    );
    let p = run_units(vec![a_, b_, c_, main]).unwrap();
    assert!(matches!(&let_init(main_of(&p), 0).kind, h::ExprKind::Call { func: FuncId(0), .. }));
    assert_eq!(let_init(main_of(&p), 1).ty, Type::Union(UnionId(0)));
}

#[test]
fn reexport_of_missing_name_is_e0300() {
    let a_ = unit("a", vec![func("f", vec![], None, vec![])], vec![]);
    let b_ = unit("b", vec![reexport(&["f"], "./a")], vec![ImportTarget::Unit(0)]);
    let main = unit("main", vec![main_fn(vec![])], vec![]);
    assert_eq!(codes(run_units(vec![a_, b_, main])), vec!["E0300"]);
}

#[test]
fn std_imports_become_builtins() {
    let u = unit(
        "main",
        vec![
            import(&["readFile", "exists"], "std:fs"),
            import(&["args", "exit"], "std:process"),
            main_fn(vec![
                const_("r", None, call("readFile", vec![st("x")])),
                const_("e", None, call("exists", vec![st("x")])),
                const_("a", None, call("args", vec![])),
                es(call("exit", vec![int(0)])),
            ]),
        ],
        vec![ImportTarget::Std(StdModule::Fs), ImportTarget::Std(StdModule::Process)],
    );
    let p = run_units(vec![u]).unwrap();
    let f = main_of(&p);
    assert!(matches!(&let_init(f, 0).kind, h::ExprKind::Builtin { op: Builtin::FsReadFile, .. }));
    assert_eq!(let_init(f, 0).ty, Type::Result(Box::new(Type::String), Box::new(Type::String)));
    assert_eq!(let_init(f, 2).ty, Type::Array(Box::new(Type::String)));
    assert!(matches!(&f.body.stmts[3], h::Stmt::Expr(e) if matches!(e.kind, h::ExprKind::Builtin { op: Builtin::ProcessExit, .. })));
}

#[test]
fn unknown_std_name_is_e0300() {
    let u = unit("main", vec![import(&["nope"], "std:fs"), main_fn(vec![])], vec![ImportTarget::Std(StdModule::Fs)]);
    assert_eq!(codes(run_units(vec![u])), vec!["E0300"]);
}

#[test]
fn shadowing_creates_distinct_locals() {
    let p = ok_main(
        vec![],
        vec![
            const_("x", None, int(1)),
            sk(StmtKind::Block(block(vec![const_("x", None, st("s")), es(v("x"))]))),
            es(v("x")),
        ],
    );
    let f = main_of(&p);
    assert_eq!(f.locals.len(), 2);
    assert_eq!(f.locals[1].ty, Type::String);
    let inner = match &f.body.stmts[1] {
        h::Stmt::Block(b) => match &b.stmts[1] {
            h::Stmt::Expr(e) => match e.kind {
                h::ExprKind::Local(l) => l,
                _ => panic!(),
            },
            _ => panic!(),
        },
        _ => panic!(),
    };
    let outer = match &f.body.stmts[2] {
        h::Stmt::Expr(e) => match e.kind {
            h::ExprKind::Local(l) => l,
            _ => panic!(),
        },
        _ => panic!(),
    };
    assert_eq!(inner, LocalId(1));
    assert_eq!(outer, LocalId(0));
}

#[test]
fn params_are_first_locals_and_immutable() {
    let p = ok(vec![
        func("f", vec![("a", ty("int")), ("b", ty("string"))], Some(ty("int")), vec![const_("c", None, int(1)), ret(v("a"))]),
        main_fn(vec![]),
    ]);
    let f = func_named(&p, "main.f");
    assert_eq!(f.param_count, 2);
    assert_eq!(f.locals.len(), 3);
    assert!(!f.locals[0].mutable && !f.locals[1].mutable);
    assert_eq!(f.locals[2].name, "c");
}

#[test]
fn statement_match_on_option_lowering() {
    let p = ok_main(
        vec![],
        vec![
            const_("o", Some(tya("Option", vec![ty("int")])), call("Some", vec![int(1)])),
            es(mat(
                v("o"),
                vec![
                    (pv("Some", vec![pi("v")]), ae(mcall(v("v"), "toString", vec![]))),
                    (pi("None"), ab(vec![ret_void()])),
                ],
            )),
        ],
    );
    let f = main_of(&p);
    match &f.body.stmts[1] {
        h::Stmt::Expr(e) => {
            assert_eq!(e.ty, Type::Void);
            match &e.kind {
                h::ExprKind::Match { arms, .. } => {
                    assert_eq!(arms.len(), 2);
                    assert!(arms.iter().all(|a| a.value.is_none()));
                    assert!(matches!(&arms[0].pattern, h::Pattern::Variant { tag: 0, bindings } if bindings.len() == 1 && bindings[0].is_some()));
                    assert!(matches!(&arms[0].body.stmts[0], h::Stmt::Expr(_)));
                    assert!(matches!(&arms[1].pattern, h::Pattern::Variant { tag: 1, .. }));
                    assert!(matches!(&arms[1].body.stmts[0], h::Stmt::Return(None)));
                }
                _ => panic!(),
            }
        }
        _ => panic!(),
    }
    // binding local is immutable int
    assert_eq!(f.locals[1].ty, Type::Int);
    assert!(!f.locals[1].mutable);
}

fn shape() -> Item {
    union("Shape", vec![("Circle", vec![ty("int")]), ("Rect", vec![ty("int"), ty("int")]), ("Empty", vec![])])
}

#[test]
fn expression_match_on_union() {
    let p = ok(vec![
        shape(),
        func(
            "area",
            vec![("s", ty("Shape"))],
            Some(ty("int")),
            vec![ret(mat(
                v("s"),
                vec![
                    (pv("Circle", vec![pi("r")]), ae(bin(BinaryOp::Mul, v("r"), v("r")))),
                    (pv("Rect", vec![pi("w"), pw()]), ae(v("w"))),
                    (pi("Empty"), ae(int(0))),
                ],
            ))],
        ),
        main_fn(vec![]),
    ]);
    match &func_named(&p, "main.area").body.stmts[0] {
        h::Stmt::Return(Some(e)) => {
            assert_eq!(e.ty, Type::Int);
            match &e.kind {
                h::ExprKind::Match { arms, .. } => {
                    assert!(arms.iter().all(|a| a.value.is_some()));
                    assert!(matches!(&arms[1].pattern, h::Pattern::Variant { tag: 1, bindings } if bindings[0].is_some() && bindings[1].is_none()));
                }
                _ => panic!(),
            }
        }
        _ => panic!(),
    }
}

#[test]
fn expression_match_uses_expected_type_and_diverging_block_arm() {
    let p = ok(vec![
        shape(),
        func(
            "f",
            vec![("s", ty("Shape"))],
            Some(ty("usize")),
            vec![ret(mat(
                v("s"),
                vec![
                    (pv("Circle", vec![pw()]), ae(int(1))),
                    (pv("Rect", vec![pw(), pw()]), ab(vec![ret(int(2))])),
                    (pw(), ae(int(3))),
                ],
            ))],
        ),
        main_fn(vec![]),
    ]);
    match &func_named(&p, "main.f").body.stmts[0] {
        h::Stmt::Return(Some(e)) => {
            assert_eq!(e.ty, Type::Usize);
            if let h::ExprKind::Match { arms, .. } = &e.kind {
                assert!(arms[1].value.is_none());
                assert_eq!(arms[0].value.as_ref().unwrap().ty, Type::Usize);
            } else {
                panic!()
            }
        }
        _ => panic!(),
    }
}

#[test]
fn match_on_literals_with_wildcard() {
    let p = ok_main(
        vec![],
        vec![
            const_("n", None, int(3)),
            const_("r", None, mat(v("n"), vec![(pint(1), ae(st("a"))), (pint(-2), ae(st("b"))), (pw(), ae(st("c")))])),
            es(mat(st("x"), vec![(pat(PatternKind::Str("x".into())), ae(int(1))), (pw(), ae(int(2)))])),
            es(mat(bl(true), vec![(pat(PatternKind::Bool(true)), ae(int(1))), (pw(), ae(int(2)))])),
        ],
    );
    assert_eq!(let_init(main_of(&p), 1).ty, Type::String);
}

#[test]
fn mutation_through_places() {
    let p = ok_main(
        vec![record("P", vec![("x", ty("int")), ("xs", tarr(ty("int")))])],
        vec![
            let_("p", None, rec("P", None, vec![("x", int(1)), ("xs", arr(vec![]))])),
            assign(mem(v("p"), "x"), AssignOp::Add, int(2)),
            assign(idx(mem(v("p"), "xs"), int(0)), AssignOp::Assign, int(5)),
            es(mcall(mem(v("p"), "xs"), "push", vec![int(7)])),
            let_("ys", Some(tarr(ty("int"))), arr(vec![])),
            es(mcall(v("ys"), "push", vec![int(1)])),
            es(mcall(v("ys"), "pop", vec![])),
            let_("s", None, st("a")),
            assign(v("s"), AssignOp::Add, st("b")),
        ],
    );
    let f = main_of(&p);
    match &f.body.stmts[1] {
        h::Stmt::Assign { place, op, value } => {
            assert_eq!(*op, Some(h::BinOp::Add));
            assert_eq!(place.ty, Type::Int);
            assert_eq!(value.ty, Type::Int);
            assert!(matches!(place.path[0], h::PlaceElem::Field { index: 0, .. }));
        }
        _ => panic!(),
    }
    match &f.body.stmts[2] {
        h::Stmt::Assign { place, op: None, .. } => {
            assert_eq!(place.path.len(), 2);
            match &place.path[1] {
                h::PlaceElem::Index(i) => assert_eq!(i.ty, Type::Usize),
                _ => panic!(),
            }
        }
        _ => panic!(),
    }
    match &f.body.stmts[3] {
        h::Stmt::Expr(e) => assert!(matches!(&e.kind, h::ExprKind::MutMethod { op: MutBuiltin::ArrPush, .. })),
        _ => panic!(),
    }
    match &f.body.stmts[6] {
        h::Stmt::Expr(e) => {
            assert!(matches!(&e.kind, h::ExprKind::MutMethod { op: MutBuiltin::ArrPop, .. }));
            assert_eq!(e.ty, Type::Option(Box::new(Type::Int)));
        }
        _ => panic!(),
    }
    assert!(matches!(&f.body.stmts[8], h::Stmt::Assign { op: Some(h::BinOp::Add), .. }));
}

#[test]
fn record_literal_spread_and_field_access() {
    let p = ok_main(
        vec![record("P", vec![("x", ty("int")), ("y", ty("int"))])],
        vec![
            const_("p", None, rec("P", None, vec![("y", int(2)), ("x", int(1))])),
            const_("q", None, rec("P", Some(v("p")), vec![("y", int(3))])),
            const_("r", None, rec("P", Some(v("p")), vec![])),
            const_("z", None, mem(v("q"), "y")),
        ],
    );
    let f = main_of(&p);
    match &let_init(f, 0).kind {
        h::ExprKind::Record { fields, spread: None, .. } => {
            assert_eq!(fields[0].0, 1);
            assert_eq!(fields[1].0, 0);
        }
        _ => panic!(),
    }
    assert!(matches!(&let_init(f, 1).kind, h::ExprKind::Record { spread: Some(_), fields, .. } if fields.len() == 1));
    assert!(matches!(&let_init(f, 3).kind, h::ExprKind::Field { index: 1, .. }));
}

#[test]
fn top_level_consts_are_inlined() {
    let p = ok_main(
        vec![
            konst("MAX", Some(ty("usize")), int(10)),
            konst("NEG", None, neg(int(3))),
            konst("NAME", None, st("hi")),
            konst("ON", None, bl(true)),
        ],
        vec![
            const_("a", None, v("MAX")),
            const_("b", None, v("NEG")),
            const_("c", None, v("NAME")),
            const_("d", None, v("ON")),
        ],
    );
    let f = main_of(&p);
    assert!(matches!(let_init(f, 0).kind, h::ExprKind::Int(10)));
    assert_eq!(let_init(f, 0).ty, Type::Usize);
    assert!(matches!(let_init(f, 1).kind, h::ExprKind::Int(-3)));
    assert!(matches!(&let_init(f, 2).kind, h::ExprKind::Str(s) if s == "hi"));
    assert!(matches!(let_init(f, 3).kind, h::ExprKind::Bool(true)));
}

#[test]
fn builtin_members_and_methods() {
    let p = ok_main(
        vec![],
        vec![
            const_("s", None, st("a,b")),
            const_("n", None, mem(v("s"), "length")),
            const_("parts", None, mcall(v("s"), "split", vec![st(",")])),
            const_("k", None, mem(v("parts"), "length")),
            const_("j", None, mcall(v("parts"), "join", vec![st("-")])),
            const_("c", None, mcall(v("s"), "charCodeAt", vec![int(0)])),
            const_("i", None, mcall(v("s"), "indexOf", vec![st("b")])),
            const_("g", None, mcall(v("parts"), "get", vec![int(0)])),
            const_("t", None, mcall(int(5), "toUsize", vec![])),
            const_("u", None, mcall(v("t"), "toString", vec![])),
            const_("o", None, mcall(call("parseInt", vec![st("1")]), "unwrapOr", vec![int(0)])),
            es(mcall(v("s"), "includes", vec![st("a")])),
            es(call("parseInt", vec![v("s")])),
            const_("sl", None, mcall(v("parts"), "slice", vec![int(0), int(1)])),
            const_("cc", None, mcall(v("sl"), "concat", vec![v("parts")])),
            es(ex(AK::Call {
                callee: Box::new(mem(v("console"), "log")),
                args: vec![mcall(v("s"), "trim", vec![])],
            })),
            const_("fc", None, ex(AK::Call { callee: Box::new(mem(v("String"), "fromCharCode")), args: vec![int(65)] })),
        ],
    );
    let f = main_of(&p);
    assert_eq!(let_init(f, 1).ty, Type::Usize);
    assert!(matches!(&let_init(f, 1).kind, h::ExprKind::Builtin { op: Builtin::StrLength, args } if args.len() == 1));
    assert_eq!(let_init(f, 2).ty, Type::Array(Box::new(Type::String)));
    assert_eq!(let_init(f, 3).ty, Type::Usize);
    assert_eq!(let_init(f, 5).ty, Type::Int);
    assert_eq!(let_init(f, 6).ty, Type::Option(Box::new(Type::Usize)));
    assert_eq!(let_init(f, 7).ty, Type::Option(Box::new(Type::String)));
    assert_eq!(let_init(f, 8).ty, Type::Usize);
    assert_eq!(let_init(f, 10).ty, Type::Int);
    assert!(matches!(&f.body.stmts[15], h::Stmt::Expr(e) if matches!(e.kind, h::ExprKind::Builtin { op: Builtin::ConsoleLog, .. })));
    assert!(matches!(&let_init(f, 16).kind, h::ExprKind::Builtin { op: Builtin::StringFromCharCode, .. }));
    match &let_init(f, 5).kind {
        h::ExprKind::Builtin { args, .. } => assert_eq!(args[1].ty, Type::Usize),
        _ => panic!(),
    }
}

#[test]
fn try_operator_and_result_methods() {
    let res = |t: &str| tya("Result", vec![ty(t), ty("string")]);
    let p = ok(vec![
        func("a", vec![], Some(res("int")), vec![ret(call("Ok", vec![int(1)]))]),
        func(
            "b",
            vec![],
            Some(res("string")),
            vec![const_("x", None, try_(call("a", vec![]))), ret(call("Ok", vec![mcall(v("x"), "toString", vec![])]))],
        ),
        main_fn(vec![
            const_("r", None, call("b", vec![])),
            es(mcall(v("r"), "isOk", vec![])),
            es(mcall(v("r"), "unwrapErr", vec![])),
        ]),
    ]);
    let f = func_named(&p, "main.b");
    assert_eq!(let_init(f, 0).ty, Type::Int);
    assert!(matches!(let_init(f, 0).kind, h::ExprKind::Try(_)));
}

#[test]
fn control_flow_return_analysis() {
    ok(vec![
        func("a", vec![("c", ty("bool"))], Some(ty("int")), vec![if_(v("c"), vec![ret(int(1))], Some(vec![ret(int(2))]))]),
        func("b", vec![], Some(ty("int")), vec![while_(bl(true), vec![es(int(1))])]),
        func(
            "c",
            vec![("c", ty("bool"))],
            Some(ty("int")),
            vec![while_(bl(true), vec![if_(v("c"), vec![ret(int(1))], None)])],
        ),
        func(
            "d",
            vec![("o", tya("Option", vec![ty("int")]))],
            Some(ty("int")),
            vec![es(mat(
                v("o"),
                vec![(pv("Some", vec![pi("x")]), ab(vec![ret(v("x"))])), (pi("None"), ab(vec![ret(int(0))]))],
            ))],
        ),
        func(
            "e",
            vec![("c", ty("bool"))],
            Some(ty("int")),
            vec![sk(StmtKind::If {
                cond: v("c"),
                then: block(vec![ret(int(1))]),
                els: Some(Box::new(if_(v("c"), vec![ret(int(2))], Some(vec![ret(int(3))])))),
            })],
        ),
        main_fn(vec![]),
    ]);
}

#[test]
fn loops_for_of_break_continue() {
    let p = ok_main(
        vec![],
        vec![
            const_("xs", None, arr(vec![int(1), int(2)])),
            forof("x", v("xs"), vec![if_(bin(BinaryOp::Eq, v("x"), int(1)), vec![cont()], None), brk()]),
            while_(bl(false), vec![brk()]),
        ],
    );
    let f = main_of(&p);
    assert_eq!(f.locals[0].ty, Type::Array(Box::new(Type::Int)));
    assert_eq!(f.locals[1].ty, Type::Int);
    assert!(!f.locals[1].mutable);
}

#[test]
fn conditional_expression_and_array_inference() {
    let p = ok_main(
        vec![],
        vec![
            const_("x", Some(ty("usize")), ex(AK::Cond { cond: Box::new(bl(true)), then: Box::new(int(1)), els: Box::new(int(2)) })),
            const_("ys", None, arr(vec![int(1), int(2)])),
            const_("zs", Some(tarr(ty("usize"))), arr(vec![int(1), int(2)])),
            const_("n", Some(tarr(tarr(ty("int")))), arr(vec![arr(vec![]), arr(vec![int(1)])])),
        ],
    );
    let f = main_of(&p);
    assert_eq!(let_init(f, 0).ty, Type::Usize);
    assert_eq!(let_init(f, 1).ty, Type::Array(Box::new(Type::Int)));
    assert_eq!(let_init(f, 2).ty, Type::Array(Box::new(Type::Usize)));
}

#[test]
fn local_not_in_scope_in_own_initializer() {
    let p = ok_main(
        vec![],
        vec![
            const_("x", None, int(1)),
            sk(StmtKind::Block(block(vec![const_("x", None, bin(BinaryOp::Add, v("x"), int(1)))]))),
        ],
    );
    let f = main_of(&p);
    match &f.body.stmts[1] {
        h::Stmt::Block(b) => match &b.stmts[0] {
            h::Stmt::Let { local, init } => {
                assert_eq!(*local, LocalId(1));
                match &init.kind {
                    h::ExprKind::Binary { lhs, .. } => assert!(matches!(lhs.kind, h::ExprKind::Local(LocalId(0)))),
                    _ => panic!(),
                }
            }
            _ => panic!(),
        },
        _ => panic!(),
    }
}

#[test]
fn record_and_union_ids_are_deterministic_across_units() {
    let u0 = unit("z", vec![export(record("B", vec![])), export(record("A", vec![]))], vec![]);
    let u1 = unit("a", vec![record("C", vec![]), union("U", vec![("X", vec![])]), main_fn(vec![])], vec![]);
    let p = run_units(vec![u0, u1]).unwrap();
    let names: Vec<&str> = p.records.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, vec!["z.B", "z.A", "a.C"]);
    assert_eq!(p.unions[0].name, "a.U");
}

#[test]
fn recursive_types_allowed() {
    ok(vec![
        union("List", vec![("Nil", vec![]), ("Cons", vec![ty("int"), ty("List")])]),
        record("Node", vec![("next", tya("Option", vec![ty("Node")]))]),
        main_fn(vec![]),
    ]);
}

#[test]
fn same_name_in_two_units_is_fine() {
    let u0 = unit("lib", vec![export(func("f", vec![], None, vec![]))], vec![]);
    let u1 = unit("main", vec![func("f", vec![], None, vec![]), main_fn(vec![])], vec![]);
    run_units(vec![u0, u1]).unwrap();
}

#[test]
fn diagnostics_carry_spans() {
    let bad = a::Expr { kind: AK::Str("x".into()), span: Span::new(FileId(0), 7, 10) };
    let r = run(vec![main_fn(vec![const_("a", Some(ty("int")), bad)])]);
    let d = r.err().unwrap();
    assert_eq!(d[0].code, "E0400");
    assert_eq!(d[0].span, Span::new(FileId(0), 7, 10));
}

// ---- negative tests ------------------------------------------------------------------------

#[test]
fn e0300_unresolved_name() {
    fails_main(vec![], vec![es(v("nope"))], "E0300");
    fails_main(vec![], vec![es(call("nope", vec![]))], "E0300");
    fails_main(vec![], vec![const_("a", Some(ty("Nope")), int(1))], "E0300");
}

#[test]
fn e0304_duplicates() {
    fails(vec![func("f", vec![], None, vec![]), func("f", vec![], None, vec![]), main_fn(vec![])], "E0304");
    fails(vec![record("T", vec![]), alias("T", ty("int")), main_fn(vec![])], "E0304");
    fails(vec![func("V", vec![], None, vec![]), union("U", vec![("V", vec![])]), main_fn(vec![])], "E0304");
    fails(vec![union("U", vec![("V", vec![])]), union("W", vec![("V", vec![])]), main_fn(vec![])], "E0304");
    fails(vec![record("T", vec![("a", ty("int")), ("a", ty("int"))]), main_fn(vec![])], "E0304");
    fails(vec![alias("int", ty("string")), main_fn(vec![])], "E0304");
    fails(vec![func("f", vec![("a", ty("int")), ("a", ty("int"))], None, vec![]), main_fn(vec![])], "E0304");
    fails_main(vec![], vec![const_("x", None, int(1)), let_("x", None, int(2))], "E0304");
    fails_main(
        vec![union("U", vec![("A", vec![ty("int"), ty("int")])])],
        vec![es(mat(call("A", vec![int(1), int(2)]), vec![(pv("A", vec![pi("q"), pi("q")]), ae(int(1)))]))],
        "E0304",
    );
}

#[test]
fn e0304_import_conflicts_with_local() {
    let lib = unit("lib", vec![export(func("f", vec![], None, vec![]))], vec![]);
    let main = unit(
        "main",
        vec![import(&["f"], "./lib"), func("f", vec![], None, vec![]), main_fn(vec![])],
        vec![ImportTarget::Unit(0)],
    );
    assert_eq!(codes(run_units(vec![lib, main])), vec!["E0304"]);
}

#[test]
fn e0400_type_mismatches() {
    fails_main(vec![], vec![const_("a", Some(ty("int")), st("s"))], "E0400");
    fails_main(vec![], vec![const_("a", Some(ty("string")), int(1))], "E0400");
    fails_main(vec![], vec![const_("a", Some(ty("usize")), int(1)), const_("b", Some(ty("int")), v("a"))], "E0400");
    // int/usize mixing
    fails_main(
        vec![],
        vec![const_("a", Some(ty("usize")), int(1)), const_("b", Some(ty("int")), int(1)), es(bin(BinaryOp::Add, v("a"), v("b")))],
        "E0400",
    );
    fails_main(vec![], vec![const_("i", None, int(0)), const_("xs", None, arr(vec![int(1)])), es(idx(v("xs"), v("i")))], "E0400");
    fails_main(vec![], vec![const_("a", Some(ty("usize")), neg(int(1)))], "E0400");
    fails_main(vec![konst("N", Some(ty("usize")), neg(int(1)))], vec![], "E0400");
    fails(
        vec![func("f", vec![("a", ty("int"))], None, vec![]), main_fn(vec![es(call("f", vec![st("x")]))])],
        "E0400",
    );
    fails_main(vec![], vec![if_(int(1), vec![], None)], "E0400");
    fails_main(vec![], vec![while_(int(1), vec![])], "E0400");
    fails_main(vec![], vec![forof("x", int(1), vec![])], "E0400");
    fails_main(vec![], vec![es(idx(st("abc"), int(0)))], "E0400");
    fails_main(vec![alias("A", ty("int"))], vec![es(rec("A", None, vec![]))], "E0400");
    fails_main(
        vec![],
        vec![es(ex(AK::Cond { cond: Box::new(bl(true)), then: Box::new(int(1)), els: Box::new(st("a")) }))],
        "E0400",
    );
    fails(vec![func("f", vec![("a", ty("void"))], None, vec![]), main_fn(vec![])], "E0400");
    fails_main(vec![], vec![const_("a", Some(tya("Option", vec![])), int(1))], "E0400");
    // literal pattern of the wrong type
    fails_main(vec![], vec![es(mat(int(1), vec![(pat(PatternKind::Str("a".into())), ae(int(1))), (pw(), ae(int(2)))]))], "E0400");
}

#[test]
fn e0400_return_rules() {
    fails(vec![func("f", vec![], None, vec![ret(int(1))]), main_fn(vec![])], "E0400");
    fails(vec![func("f", vec![], Some(ty("int")), vec![ret_void()]), main_fn(vec![])], "E0400");
    fails(vec![func("f", vec![], Some(ty("int")), vec![ret(st("x"))]), main_fn(vec![])], "E0400");
}

#[test]
fn e0400_void_binding() {
    fails_main(vec![func("f", vec![], None, vec![])], vec![const_("a", None, call("f", vec![]))], "E0400");
    fails_main(vec![], vec![const_("a", Some(ty("void")), int(1))], "E0400");
}

#[test]
fn e0400_alias_cycle() {
    fails(vec![alias("A", ty("B")), alias("B", ty("A")), main_fn(vec![])], "E0400");
    fails(vec![alias("A", tarr(ty("A"))), main_fn(vec![])], "E0400");
}

#[test]
fn e0400_block_arm_must_diverge_in_expression_match() {
    fails(
        vec![
            shape(),
            func(
                "f",
                vec![("s", ty("Shape"))],
                Some(ty("int")),
                vec![ret(mat(v("s"), vec![(pv("Circle", vec![pw()]), ab(vec![es(int(1))])), (pw(), ae(int(0)))]))],
            ),
            main_fn(vec![]),
        ],
        "E0400",
    );
    fails(
        vec![
            shape(),
            func(
                "f",
                vec![("s", ty("Shape"))],
                Some(ty("int")),
                vec![ret(mat(v("s"), vec![(pv("Circle", vec![pw()]), ae(int(1))), (pw(), ae(st("x")))]))],
            ),
            main_fn(vec![]),
        ],
        "E0400",
    );
}

#[test]
fn e0401_immutable_assignment() {
    fails_main(vec![], vec![const_("a", None, int(1)), assign(v("a"), AssignOp::Assign, int(2))], "E0401");
    fails(
        vec![func("f", vec![("a", ty("int"))], None, vec![assign(v("a"), AssignOp::Assign, int(2))]), main_fn(vec![])],
        "E0401",
    );
    fails_main(
        vec![record("P", vec![("x", ty("int"))])],
        vec![const_("p", None, rec("P", None, vec![("x", int(1))])), assign(mem(v("p"), "x"), AssignOp::Assign, int(2))],
        "E0401",
    );
    fails_main(vec![], vec![assign(call("f", vec![]), AssignOp::Assign, int(2))], "E0401");
    fails_main(vec![], vec![assign(int(1), AssignOp::Assign, int(2))], "E0401");
    fails_main(
        vec![],
        vec![const_("xs", None, arr(vec![int(1)])), forof("x", v("xs"), vec![assign(v("x"), AssignOp::Assign, int(2))])],
        "E0401",
    );
    fails_main(vec![konst("N", None, int(1))], vec![assign(v("N"), AssignOp::Assign, int(2))], "E0401");
}

#[test]
fn e0401_push_requires_mutable_place() {
    fails_main(
        vec![],
        vec![const_("xs", Some(tarr(ty("int"))), arr(vec![])), es(mcall(v("xs"), "push", vec![int(1)]))],
        "E0401",
    );
    fails(
        vec![
            func("f", vec![], Some(tarr(ty("int"))), vec![ret(arr(vec![]))]),
            main_fn(vec![es(mcall(call("f", vec![]), "push", vec![int(1)]))]),
        ],
        "E0401",
    );
    fails(
        vec![func("f", vec![("xs", tarr(ty("int")))], None, vec![es(mcall(v("xs"), "pop", vec![]))]), main_fn(vec![])],
        "E0401",
    );
}

#[test]
fn e0402_match_errors() {
    fails_main(vec![shape()], vec![es(mat(v("Empty"), vec![(pi("Empty"), ae(int(1)))]))], "E0402");
    fails_main(
        vec![],
        vec![es(mat(call("parseInt", vec![st("1")]), vec![(pv("Some", vec![pw()]), ae(int(1)))]))],
        "E0402",
    );
    fails_main(vec![], vec![es(mat(int(1), vec![(pint(1), ae(int(1)))]))], "E0402");
    fails_main(
        vec![],
        vec![es(mat(bl(true), vec![(pat(PatternKind::Bool(true)), ae(int(1))), (pat(PatternKind::Bool(false)), ae(int(2)))]))],
        "E0402",
    );
    fails_main(
        vec![shape()],
        vec![es(mat(v("Empty"), vec![(pv("Rect", vec![pi("a")]), ae(int(1))), (pw(), ae(int(2)))]))],
        "E0402",
    );
    fails_main(
        vec![shape()],
        vec![es(mat(v("Empty"), vec![(pi("Circle"), ae(int(1))), (pw(), ae(int(2)))]))],
        "E0402",
    );
    fails_main(
        vec![record("P", vec![])],
        vec![es(mat(rec("P", None, vec![]), vec![(pw(), ae(int(1)))]))],
        "E0402",
    );
    fails_main(vec![], vec![es(mat(int(1), vec![(pv("Some", vec![pw()]), ae(int(1))), (pw(), ae(int(2)))]))], "E0402");
}

#[test]
fn e0403_missing_return() {
    fails(vec![func("f", vec![], Some(ty("int")), vec![]), main_fn(vec![])], "E0403");
    fails(
        vec![func("f", vec![("c", ty("bool"))], Some(ty("int")), vec![if_(v("c"), vec![ret(int(1))], None)]), main_fn(vec![])],
        "E0403",
    );
    fails(
        vec![
            func("f", vec![("c", ty("bool"))], Some(ty("int")), vec![if_(v("c"), vec![ret(int(1))], Some(vec![es(int(2))]))]),
            main_fn(vec![]),
        ],
        "E0403",
    );
    fails(vec![func("f", vec![], Some(ty("int")), vec![while_(bl(true), vec![brk()])]), main_fn(vec![])], "E0403");
    fails(
        vec![func("f", vec![("c", ty("bool"))], Some(ty("int")), vec![while_(v("c"), vec![ret(int(1))])]), main_fn(vec![])],
        "E0403",
    );
    fails(
        vec![
            func(
                "f",
                vec![("o", tya("Option", vec![ty("int")]))],
                Some(ty("int")),
                vec![es(mat(v("o"), vec![(pv("Some", vec![pw()]), ab(vec![ret(int(1))])), (pi("None"), ae(int(0)))]))],
            ),
            main_fn(vec![]),
        ],
        "E0403",
    );
}

#[test]
fn e0404_arity() {
    fails(vec![func("f", vec![("a", ty("int"))], None, vec![]), main_fn(vec![es(call("f", vec![]))])], "E0404");
    fails_main(vec![shape()], vec![es(call("Rect", vec![int(1)]))], "E0404");
    fails_main(vec![shape()], vec![es(v("Circle"))], "E0404");
    fails_main(vec![], vec![es(mcall(st("a"), "trim", vec![int(1)]))], "E0404");
    fails_main(vec![], vec![const_("a", Some(tya("Option", vec![ty("int")])), call("Some", vec![]))], "E0404");
    fails_main(
        vec![],
        vec![const_("a", Some(tya("Result", vec![ty("void"), ty("string")])), call("Ok", vec![int(1)]))],
        "E0404",
    );
}

#[test]
fn e0405_unknown_members() {
    fails_main(vec![], vec![es(mcall(st("a"), "nope", vec![]))], "E0405");
    fails_main(vec![], vec![es(mem(st("a"), "nope"))], "E0405");
    fails_main(
        vec![record("P", vec![("x", ty("int"))])],
        vec![const_("p", None, rec("P", None, vec![("x", int(1))])), es(mem(v("p"), "y"))],
        "E0405",
    );
    fails_main(
        vec![record("P", vec![("x", ty("int"))])],
        vec![let_("p", None, rec("P", None, vec![("x", int(1))])), assign(mem(v("p"), "y"), AssignOp::Assign, int(1))],
        "E0405",
    );
    fails_main(vec![], vec![es(ex(AK::Call { callee: Box::new(mem(v("console"), "warn")), args: vec![st("x")] }))], "E0405");
    fails_main(vec![shape()], vec![es(mat(v("Empty"), vec![(pi("Nope"), ae(int(1))), (pw(), ae(int(2)))]))], "E0405");
    fails_main(vec![], vec![es(mcall(arr(vec![int(1)]), "join", vec![st("")]))], "E0405");
    fails_main(vec![], vec![let_("s", None, st("a")), es(mcall(v("s"), "push", vec![st("b")]))], "E0405");
}

#[test]
fn e0406_invalid_try() {
    let res = tya("Result", vec![ty("int"), ty("string")]);
    fails(vec![func("f", vec![], Some(res.clone()), vec![es(try_(int(1)))]), main_fn(vec![])], "E0406");
    fails(
        vec![
            func("a", vec![], Some(res.clone()), vec![ret(call("Ok", vec![int(1)]))]),
            main_fn(vec![es(try_(call("a", vec![])))]),
        ],
        "E0406",
    );
    fails(
        vec![
            func("a", vec![], Some(res.clone()), vec![ret(call("Ok", vec![int(1)]))]),
            func("b", vec![], Some(tya("Result", vec![ty("int"), ty("int")])), vec![es(try_(call("a", vec![])))]),
            main_fn(vec![]),
        ],
        "E0406",
    );
}

#[test]
fn e0407_cannot_infer() {
    fails_main(vec![], vec![const_("a", None, arr(vec![]))], "E0407");
    fails_main(vec![], vec![const_("a", None, v("None"))], "E0407");
    fails_main(vec![], vec![const_("a", None, call("Ok", vec![int(1)]))], "E0407");
    fails_main(vec![], vec![const_("a", None, call("Err", vec![st("x")]))], "E0407");
}

#[test]
fn e0408_unsupported_generics() {
    let mut f = func("f", vec![], None, vec![]);
    if let Item::Function(d) = &mut f {
        d.type_params = vec![id("T")];
    }
    fails(vec![f, main_fn(vec![])], "E0408");
    let mut t = record("R", vec![]);
    if let Item::Type(d) = &mut t {
        d.type_params = vec![id("T")];
    }
    fails(vec![t, main_fn(vec![])], "E0408");
    fails(vec![record("R", vec![]), func("f", vec![("a", tya("R", vec![ty("int")]))], None, vec![]), main_fn(vec![])], "E0408");
    fails(vec![konst("N", None, bin(BinaryOp::Add, int(1), int(2))), main_fn(vec![])], "E0408");
}

#[test]
fn e0409_break_continue_outside_loop() {
    fails_main(vec![], vec![brk()], "E0409");
    fails_main(vec![], vec![cont()], "E0409");
    fails_main(vec![], vec![while_(bl(false), vec![]), brk()], "E0409");
}

#[test]
fn e0410_operator_operands() {
    fails_main(vec![], vec![es(bin(BinaryOp::Sub, st("a"), st("b")))], "E0410");
    fails_main(vec![], vec![es(bin(BinaryOp::Lt, st("a"), st("b")))], "E0410");
    fails_main(vec![], vec![es(bin(BinaryOp::Eq, arr(vec![int(1)]), arr(vec![int(1)])))], "E0410");
    fails_main(vec![], vec![es(bin(BinaryOp::And, int(1), int(2)))], "E0410");
    fails_main(vec![], vec![es(bin(BinaryOp::And, int(1), bl(true)))], "E0410");
    fails_main(vec![], vec![es(not(int(1)))], "E0410");
    fails_main(vec![], vec![es(neg(st("a")))], "E0410");
    fails_main(vec![], vec![const_("a", Some(ty("usize")), int(1)), es(neg(v("a")))], "E0410");
    fails_main(vec![], vec![let_("s", None, st("a")), assign(v("s"), AssignOp::Sub, st("b"))], "E0410");
    fails_main(vec![], vec![es(bin(BinaryOp::Add, int(1), st("a")))], "E0410");
}

#[test]
fn e0411_record_literal_fields() {
    let p = || record("P", vec![("x", ty("int")), ("y", ty("int"))]);
    fails_main(vec![p()], vec![es(rec("P", None, vec![("x", int(1))]))], "E0411");
    fails_main(vec![p()], vec![es(rec("P", None, vec![("x", int(1)), ("y", int(1)), ("z", int(1))]))], "E0411");
    fails_main(vec![p()], vec![es(rec("P", None, vec![("x", int(1)), ("x", int(1)), ("y", int(1))]))], "E0411");
    fails_main(vec![p(), record("Q", vec![])], vec![es(rec("P", Some(rec("Q", None, vec![])), vec![]))], "E0400");
}

#[test]
fn e0412_main() {
    fails(vec![func("f", vec![], None, vec![])], "E0412");
    fails(vec![func("main", vec![("a", ty("int"))], None, vec![])], "E0412");
    fails(vec![func("main", vec![], Some(ty("int")), vec![ret(int(0))])], "E0412");
    let lib = unit("lib", vec![export(main_fn(vec![]))], vec![]);
    let main = unit("main", vec![import(&["main"], "./lib")], vec![ImportTarget::Unit(0)]);
    assert_eq!(codes(run_units(vec![lib, main])), vec!["E0412"]);
}
