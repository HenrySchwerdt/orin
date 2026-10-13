//! Codegen tests: hand-built HIR → C → cc → run.

use super::generate;
use crate::hir::*;
use crate::span::{FileId, Span};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

// ---------------------------------------------------------------- builders

fn sp() -> Span {
    Span::new(FileId(0), 0, 0)
}
fn mk(kind: ExprKind, ty: Type) -> Expr {
    Expr { kind, ty, span: sp() }
}
fn int(n: i64) -> Expr {
    mk(ExprKind::Int(n), Type::Int)
}
fn usz(n: i64) -> Expr {
    mk(ExprKind::Int(n), Type::Usize)
}
fn st(s: &str) -> Expr {
    mk(ExprKind::Str(s.to_string()), Type::String)
}
fn bl(b: bool) -> Expr {
    mk(ExprKind::Bool(b), Type::Bool)
}
fn loc(id: u32, ty: Type) -> Expr {
    mk(ExprKind::Local(LocalId(id)), ty)
}
fn bin(op: BinOp, l: Expr, r: Expr) -> Expr {
    let ty = match op {
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem => l.ty.clone(),
        _ => Type::Bool,
    };
    mk(ExprKind::Binary { op, lhs: Box::new(l), rhs: Box::new(r) }, ty)
}
fn bi(op: Builtin, args: Vec<Expr>, ty: Type) -> Expr {
    mk(ExprKind::Builtin { op, args }, ty)
}
fn call(f: u32, args: Vec<Expr>, ty: Type) -> Expr {
    mk(ExprKind::Call { func: FuncId(f), args }, ty)
}
fn fld(base: Expr, record: u32, index: u32, ty: Type) -> Expr {
    mk(ExprKind::Field { base: Box::new(base), record: RecordId(record), index }, ty)
}
fn idx(base: Expr, i: Expr, ty: Type) -> Expr {
    mk(ExprKind::Index { base: Box::new(base), index: Box::new(i) }, ty)
}
fn arr(xs: Vec<Expr>, elem: Type) -> Expr {
    mk(ExprKind::Array(xs), Type::Array(Box::new(elem)))
}
fn variant(tag: u32, payload: Vec<Expr>, ty: Type) -> Expr {
    mk(ExprKind::Variant { tag, payload }, ty)
}
fn some(e: Expr) -> Expr {
    let t = Type::Option(Box::new(e.ty.clone()));
    variant(0, vec![e], t)
}
fn ok(e: Expr, err: Type) -> Expr {
    let t = Type::Result(Box::new(e.ty.clone()), Box::new(err));
    variant(0, vec![e], t)
}
fn err(e: Expr, okt: Type) -> Expr {
    let t = Type::Result(Box::new(okt), Box::new(e.ty.clone()));
    variant(1, vec![e], t)
}
fn rec(record: u32, fields: Vec<(u32, Expr)>) -> Expr {
    mk(ExprKind::Record { record: RecordId(record), spread: None, fields }, Type::Record(RecordId(record)))
}
fn log(e: Expr) -> Stmt {
    Stmt::Expr(bi(Builtin::ConsoleLog, vec![e], Type::Void))
}
fn itos(e: Expr) -> Expr {
    bi(Builtin::IntToString, vec![e], Type::String)
}
fn utos(e: Expr) -> Expr {
    bi(Builtin::UsizeToString, vec![e], Type::String)
}
fn let_(id: u32, init: Expr) -> Stmt {
    Stmt::Let { local: LocalId(id), init }
}
fn ret(e: Expr) -> Stmt {
    Stmt::Return(Some(e))
}
fn place(root: u32, path: Vec<PlaceElem>, ty: Type) -> Place {
    Place { root: LocalId(root), path, ty }
}
fn assign(p: Place, op: Option<BinOp>, v: Expr) -> Stmt {
    Stmt::Assign { place: p, op, value: v }
}
fn blk(stmts: Vec<Stmt>) -> Block {
    Block { stmts }
}
fn field_el(record: u32, index: u32) -> PlaceElem {
    PlaceElem::Field { record: RecordId(record), index }
}
fn func(name: &str, params: &[(&str, Type)], locals: &[(&str, Type, bool)], ret: Type, body: Vec<Stmt>) -> Function {
    let mut ls: Vec<Local> =
        params.iter().map(|(n, t)| Local { name: n.to_string(), ty: t.clone(), mutable: false }).collect();
    ls.extend(locals.iter().map(|(n, t, m)| Local { name: n.to_string(), ty: t.clone(), mutable: *m }));
    Function { name: name.to_string(), param_count: params.len() as u32, locals: ls, ret, body: blk(body), span: sp() }
}
fn main_fn(locals: &[(&str, Type, bool)], body: Vec<Stmt>) -> Function {
    func("main", &[], locals, Type::Void, body)
}
fn prog(records: Vec<RecordDef>, unions: Vec<UnionDef>, functions: Vec<Function>) -> Program {
    let m = functions.iter().position(|f| f.name == "main").unwrap() as u32;
    Program { records, unions, functions, main: FuncId(m) }
}
fn rdef(name: &str, fields: Vec<(&str, Type)>) -> RecordDef {
    RecordDef { name: name.to_string(), fields: fields.into_iter().map(|(n, t)| (n.to_string(), t)).collect() }
}
fn s_arr() -> Type {
    Type::Array(Box::new(Type::String))
}
fn i_arr() -> Type {
    Type::Array(Box::new(Type::Int))
}

// ---------------------------------------------------------------- harness

struct Out {
    stdout: String,
    stderr: String,
    code: i32,
}

fn runtime_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../runtime")
}

fn work_dir() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let d = std::env::temp_dir().join(format!("orinb_cg_{}_{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Runtime compiled once per mode.
fn runtime_obj(asan: bool) -> &'static Path {
    static PLAIN: OnceLock<PathBuf> = OnceLock::new();
    static ASAN: OnceLock<PathBuf> = OnceLock::new();
    let cell = if asan { &ASAN } else { &PLAIN };
    cell.get_or_init(|| {
        let d = work_dir();
        let o = d.join("orin_runtime.o");
        // One object from a tiny unity file: runtime + L0 platform layer (platform/, spec 19 R2).
        let unity = d.join(if asan { "unity_asan.c" } else { "unity.c" });
        std::fs::write(
            &unity,
            format!(
                "#include \"{}\"\n#include \"{}\"\n",
                runtime_dir().join("orin_runtime.c").display(),
                runtime_dir().join("../platform/orin_platform.c").display()
            ),
        )
        .unwrap();
        let mut c = Command::new("cc");
        c.arg("-c").arg("-g").arg("-I").arg(runtime_dir()).arg(&unity).arg("-o").arg(&o);
        if asan {
            c.arg("-fsanitize=address,undefined");
        }
        assert!(c.status().unwrap().success(), "runtime compile failed");
        o
    })
}

fn run_args(p: &Program, asan: bool, args: &[&str]) -> Out {
    let c = generate(p);
    let d = work_dir();
    std::fs::write(d.join("t.c"), &c).unwrap();
    let mut cmd = Command::new("cc");
    cmd.args(["-std=gnu11", "-g", "-Wall", "-Wno-unused", "-Wno-unused-variable", "-Wno-unused-but-set-variable"])
        .arg("-I")
        .arg(runtime_dir())
        .arg(d.join("t.c"))
        .arg(runtime_obj(asan))
        .arg("-o")
        .arg(d.join("t"));
    if asan {
        cmd.arg("-fsanitize=address,undefined").arg("-fno-sanitize-recover=undefined");
    } else {
        cmd.arg("-O1");
    }
    let r = cmd.output().unwrap();
    assert!(r.status.success(), "cc failed:\n{}\n{}", String::from_utf8_lossy(&r.stderr), c);
    assert!(r.stderr.is_empty(), "cc warnings:\n{}\n{}", String::from_utf8_lossy(&r.stderr), c);
    let r = Command::new(d.join("t")).args(args).env("ASAN_OPTIONS", "detect_leaks=0").output().unwrap();
    Out {
        stdout: String::from_utf8_lossy(&r.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&r.stderr).into_owned(),
        code: r.status.code().unwrap_or(-1),
    }
}

fn run(p: &Program) -> Out {
    run_args(p, false, &[])
}

/// Run plain and under ASan+UBSan; both must agree and ASan must report nothing.
fn run_both(p: &Program) -> Out {
    let a = run(p);
    let b = run_args(p, true, &[]);
    assert_eq!(a.stdout, b.stdout, "asan stderr: {}", b.stderr);
    assert_eq!(a.code, b.code, "asan run differs: {}", b.stderr);
    assert!(!b.stderr.contains("Sanitizer") && !b.stderr.contains("runtime error"), "{}", b.stderr);
    a
}

// ---------------------------------------------------------------- tests

#[test]
fn arithmetic_and_precedence() {
    let e = bin(BinOp::Add, int(2), bin(BinOp::Mul, int(3), int(4)));
    let d = bin(BinOp::Rem, bin(BinOp::Div, int(-17), int(5)), int(7));
    let m = bin(BinOp::Rem, int(-17), int(5));
    let u = bin(BinOp::Sub, usz(10), usz(3));
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(&[], vec![log(itos(e)), log(itos(d)), log(itos(m)), log(utos(u)), log(itos(mk(
            ExprKind::Unary { op: UnOp::Neg, expr: Box::new(int(i64::MIN)) },
            Type::Int,
        )))])],
    );
    // last statement traps: -INT64_MIN
    let o = run(&p);
    assert_eq!(o.stdout, "14\n-3\n-2\n7\n");
    assert_eq!(o.code, 101);
    assert!(o.stderr.contains("trap: integer overflow"), "{}", o.stderr);
}

#[test]
fn overflow_and_div_traps() {
    for (e, msg) in [
        (bin(BinOp::Add, int(i64::MAX), int(1)), "integer overflow"),
        (bin(BinOp::Mul, int(i64::MAX), int(2)), "integer overflow"),
        (bin(BinOp::Div, int(1), int(0)), "division by zero"),
        (bin(BinOp::Rem, int(1), int(0)), "modulo by zero"),
        (bin(BinOp::Div, int(i64::MIN), int(-1)), "integer overflow"),
    ] {
        let p = prog(vec![], vec![], vec![main_fn(&[], vec![log(st("before")), log(itos(e))])]);
        let o = run(&p);
        assert_eq!(o.code, 101);
        assert_eq!(o.stdout, "before\n");
        assert!(o.stderr.contains(&format!("trap: {}", msg)), "{}", o.stderr);
    }
    let p = prog(vec![], vec![], vec![main_fn(&[], vec![log(utos(bin(BinOp::Sub, usz(1), usz(2))))])]);
    assert_eq!(run(&p).code, 101);
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(&[], vec![log(utos(bi(Builtin::IntToUsize, vec![int(-1)], Type::Usize)))])],
    );
    assert_eq!(run(&p).code, 101);
}

#[test]
fn string_builtins() {
    let s = |e: Expr| e;
    let hello = || st("  hello, world \u{1}ab\0é");
    let tr = bi(Builtin::StrTrim, vec![hello()], Type::String);
    let parts = bi(Builtin::StrSplit, vec![st("a,,b"), st(",")], s_arr());
    let joined = bi(Builtin::ArrJoin, vec![parts, st("|")], Type::String);
    let sub = bi(Builtin::StrSubstring, vec![st("hello"), usz(1), usz(3)], Type::String);
    let idx_of = bi(Builtin::StrIndexOf, vec![st("hello"), st("ll")], Type::Option(Box::new(Type::Usize)));
    let unwrapped = bi(Builtin::OptUnwrap, vec![idx_of], Type::Usize);
    let pi = bi(Builtin::ParseInt, vec![st("-12")], Type::Option(Box::new(Type::Int)));
    let pi_or = bi(Builtin::OptUnwrapOr, vec![pi, int(0)], Type::Int);
    let pb = bi(Builtin::ParseInt, vec![st("12x")], Type::Option(Box::new(Type::Int)));
    let pb_or = bi(Builtin::OptUnwrapOr, vec![pb, int(-1)], Type::Int);
    let fc = bi(Builtin::StringFromCharCode, vec![int(65)], Type::String);
    let cc = bi(Builtin::StrCharCodeAt, vec![st("A"), usz(0)], Type::Usize);
    let ca = bi(Builtin::StrCharAt, vec![st("xyz"), usz(2)], Type::String);
    let len = bi(Builtin::StrLength, vec![hello()], Type::Usize);
    let cat = bin(BinOp::Add, st("foo"), bin(BinOp::Add, st("\\x41"), st("B")));
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[],
            vec![
                log(tr),
                log(joined),
                log(sub),
                log(utos(unwrapped)),
                log(itos(pi_or)),
                log(itos(pb_or)),
                log(fc),
                log(utos(cc)),
                log(ca),
                log(utos(len)),
                log(cat),
                log(bi(Builtin::BoolToString, vec![bi(Builtin::StrStartsWith, vec![st("abc"), st("ab")], Type::Bool)], Type::String)),
                log(bi(Builtin::BoolToString, vec![bin(BinOp::Eq, st("a?"), st("a?"))], Type::String)),
                log(st("??/")),
            ],
        )],
    );
    let o = run_both(&p);
    let expect_len = "  hello, world \u{1}ab\0é".len();
    assert_eq!(
        o.stdout,
        format!("hello, world \u{1}ab\0é\na||b\nel\n2\n-12\n-1\nA\n65\nz\n{}\nfoo\\x41B\ntrue\ntrue\n??/\n", expect_len)
    );
}

#[test]
fn string_oob_traps() {
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(&[], vec![log(bi(Builtin::StrSubstring, vec![st("abc"), usz(2), usz(5)], Type::String))])],
    );
    let o = run(&p);
    assert_eq!(o.code, 101);
    assert!(o.stderr.contains("trap: substring"));
}

#[test]
fn arrays_push_pop_index() {
    // let xs: int[] = []; xs.push(1); xs.push(2); xs.push(3); pop; print len, xs[1]; xs[5] traps
    let xsp = || place(0, vec![], i_arr());
    let push = |n: i64| Stmt::Expr(mk(ExprKind::MutMethod { op: MutBuiltin::ArrPush, place: xsp(), args: vec![int(n)] }, Type::Void));
    let pop = mk(ExprKind::MutMethod { op: MutBuiltin::ArrPop, place: xsp(), args: vec![] }, Type::Option(Box::new(Type::Int)));
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[("xs", i_arr(), true)],
            vec![
                let_(0, arr(vec![], Type::Int)),
                push(1),
                push(2),
                push(3),
                log(itos(bi(Builtin::OptUnwrap, vec![pop], Type::Int))),
                log(utos(bi(Builtin::ArrLength, vec![loc(0, i_arr())], Type::Usize))),
                log(itos(idx(loc(0, i_arr()), usz(1), Type::Int))),
                log(bi(
                    Builtin::BoolToString,
                    vec![bi(Builtin::OptIsNone, vec![bi(Builtin::ArrGet, vec![loc(0, i_arr()), usz(9)], Type::Option(Box::new(Type::Int)))], Type::Bool)],
                    Type::String,
                )),
                log(itos(idx(loc(0, i_arr()), usz(5), Type::Int))),
            ],
        )],
    );
    let o = run_both(&p);
    assert_eq!(o.stdout, "3\n2\n2\ntrue\n");
    assert_eq!(o.code, 101);
    assert!(o.stderr.contains("trap: index out of bounds"));
}

fn point_prog(body: impl FnOnce() -> Vec<Stmt>) -> Program {
    // record 0: P { x: int; name: string }
    prog(
        vec![rdef("P", vec![("x", Type::Int), ("name", Type::String)])],
        vec![],
        vec![main_fn(&[("a", Type::Record(RecordId(0)), true), ("b", Type::Record(RecordId(0)), false)], body())],
    )
}

#[test]
fn record_value_semantics() {
    let pt = Type::Record(RecordId(0));
    let p = point_prog(|| {
        vec![
            let_(0, rec(0, vec![(0, int(5)), (1, bin(BinOp::Add, st("n"), st("1")))])),
            let_(1, loc(0, pt.clone())),
            assign(place(0, vec![field_el(0, 0)], Type::Int), None, int(1)),
            assign(place(0, vec![field_el(0, 1)], Type::String), Some(BinOp::Add), st("!")),
            assign(place(0, vec![field_el(0, 0)], Type::Int), Some(BinOp::Add), int(10)),
            log(itos(fld(loc(1, pt.clone()), 0, 0, Type::Int))),
            log(fld(loc(1, pt.clone()), 0, 1, Type::String)),
            log(itos(fld(loc(0, pt.clone()), 0, 0, Type::Int))),
            log(fld(loc(0, pt.clone()), 0, 1, Type::String)),
            // record update with spread
            let_(1, mk(ExprKind::Record { record: RecordId(0), spread: Some(Box::new(loc(0, pt.clone()))), fields: vec![(0, int(99))] }, pt.clone())),
            log(fld(loc(1, pt.clone()), 0, 1, Type::String)),
            log(itos(fld(loc(1, pt.clone()), 0, 0, Type::Int))),
        ]
    });
    // second `let_(1..)` redeclares the same local in the same block; fine for this test but
    // would leak the first value (acceptable); use a fresh program shape for ASan below.
    let o = run(&p);
    assert_eq!(o.stdout, "5\nn1\n11\nn1!\nn1!\n99\n");
}

#[test]
fn nested_place_assignment_cow() {
    // record 0: Inner { g: int; tags: string[] }, record 1: Outer { items: Inner[]; n: int }
    let inner = Type::Record(RecordId(0));
    let outer = Type::Record(RecordId(1));
    let inners = Type::Array(Box::new(inner.clone()));
    let mk_inner = |g: i64| rec(0, vec![(0, int(g)), (1, arr(vec![st("t")], Type::String))]);
    let p = prog(
        vec![
            rdef("Inner", vec![("g", Type::Int), ("tags", s_arr())]),
            rdef("Outer", vec![("items", inners.clone()), ("n", Type::Int)]),
        ],
        vec![],
        vec![main_fn(
            &[("a", outer.clone(), true), ("b", outer.clone(), false), ("i", Type::Usize, true)],
            vec![
                let_(0, rec(1, vec![(0, arr(vec![mk_inner(1), mk_inner(2)], inner.clone())), (1, int(0))])),
                let_(1, loc(0, outer.clone())),
                let_(2, usz(1)),
                // a.items[i].g = 42 ; a.items[0].tags[0] = "z"; a.items[i].g += 1 ; a.items[i].tags.push("u")
                assign(
                    place(0, vec![field_el(1, 0), PlaceElem::Index(loc(2, Type::Usize)), field_el(0, 0)], Type::Int),
                    None,
                    int(42),
                ),
                assign(
                    place(0, vec![field_el(1, 0), PlaceElem::Index(usz(0)), field_el(0, 1), PlaceElem::Index(usz(0))], Type::String),
                    None,
                    bin(BinOp::Add, st("z"), st("z")),
                ),
                assign(
                    place(0, vec![field_el(1, 0), PlaceElem::Index(loc(2, Type::Usize)), field_el(0, 0)], Type::Int),
                    Some(BinOp::Add),
                    int(1),
                ),
                Stmt::Expr(mk(
                    ExprKind::MutMethod {
                        op: MutBuiltin::ArrPush,
                        place: place(0, vec![field_el(1, 0), PlaceElem::Index(loc(2, Type::Usize)), field_el(0, 1)], s_arr()),
                        args: vec![st("u")],
                    },
                    Type::Void,
                )),
                log(itos(fld(idx(fld(loc(0, outer.clone()), 1, 0, inners.clone()), usz(1), inner.clone()), 0, 0, Type::Int))),
                log(itos(fld(idx(fld(loc(1, outer.clone()), 1, 0, inners.clone()), usz(1), inner.clone()), 0, 0, Type::Int))),
                log(idx(fld(idx(fld(loc(0, outer.clone()), 1, 0, inners.clone()), usz(0), inner.clone()), 0, 1, s_arr()), usz(0), Type::String)),
                log(idx(fld(idx(fld(loc(1, outer.clone()), 1, 0, inners.clone()), usz(0), inner.clone()), 0, 1, s_arr()), usz(0), Type::String)),
                log(utos(bi(
                    Builtin::ArrLength,
                    vec![fld(idx(fld(loc(0, outer.clone()), 1, 0, inners.clone()), usz(1), inner.clone()), 0, 1, s_arr())],
                    Type::Usize,
                ))),
                log(utos(bi(
                    Builtin::ArrLength,
                    vec![fld(idx(fld(loc(1, outer.clone()), 1, 0, inners.clone()), usz(1), inner.clone()), 0, 1, s_arr())],
                    Type::Usize,
                ))),
                // oob nested write traps
                assign(place(0, vec![field_el(1, 0), PlaceElem::Index(usz(7)), field_el(0, 0)], Type::Int), None, int(1)),
            ],
        )],
    );
    let o = run_both(&p);
    assert_eq!(o.stdout, "43\n2\nzz\nt\n2\n1\n");
    assert_eq!(o.code, 101);
}

fn shape_union() -> UnionDef {
    UnionDef {
        name: "Shape".into(),
        variants: vec![
            VariantDef { name: "Circle".into(), payload: vec![Type::Int] },
            VariantDef { name: "Rect".into(), payload: vec![Type::Int, Type::String] },
            VariantDef { name: "Empty".into(), payload: vec![] },
        ],
    }
}

#[test]
fn union_match() {
    let sh = Type::Union(UnionId(0));
    // area(s: Shape): string = match s { Circle(r) => (r*3).toString(), Rect(w, nm) => nm + w, Empty => "empty" }
    let m = mk(
        ExprKind::Match {
            scrutinee: Box::new(loc(0, sh.clone())),
            arms: vec![
                MatchArm {
                    pattern: Pattern::Variant { tag: 0, bindings: vec![Some(LocalId(1))] },
                    body: blk(vec![]),
                    value: Some(itos(bin(BinOp::Mul, loc(1, Type::Int), int(3)))),
                },
                MatchArm {
                    pattern: Pattern::Variant { tag: 1, bindings: vec![Some(LocalId(2)), Some(LocalId(3))] },
                    body: blk(vec![]),
                    value: Some(bin(BinOp::Add, loc(3, Type::String), itos(loc(2, Type::Int)))),
                },
                MatchArm { pattern: Pattern::Variant { tag: 2, bindings: vec![] }, body: blk(vec![]), value: Some(st("empty")) },
            ],
        },
        Type::String,
    );
    let f = func(
        "area",
        &[("s", sh.clone())],
        &[("r", Type::Int, false), ("w", Type::Int, false), ("nm", Type::String, false)],
        Type::String,
        vec![ret(m)],
    );
    let mkc = |n| variant(0, vec![int(n)], sh.clone());
    let p = prog(
        vec![],
        vec![shape_union()],
        vec![
            f,
            main_fn(
                &[],
                vec![
                    log(call(0, vec![mkc(7)], Type::String)),
                    log(call(0, vec![variant(1, vec![int(4), bin(BinOp::Add, st("w"), st("="))], sh.clone())], Type::String)),
                    log(call(0, vec![variant(2, vec![], sh.clone())], Type::String)),
                ],
            ),
        ],
    );
    assert_eq!(run_both(&p).stdout, "21\nw=4\nempty\n");
}

#[test]
fn match_literals_and_cond() {
    let mt = |scr: Expr, arms: Vec<(Pattern, Expr)>| {
        mk(
            ExprKind::Match {
                scrutinee: Box::new(scr),
                arms: arms.into_iter().map(|(p, v)| MatchArm { pattern: p, body: blk(vec![]), value: Some(v) }).collect(),
            },
            Type::String,
        )
    };
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[],
            vec![
                log(mt(int(2), vec![(Pattern::Int(1), st("one")), (Pattern::Int(2), st("two")), (Pattern::Wildcard, st("many"))])),
                log(mt(st("b"), vec![(Pattern::Str("a".into()), st("A")), (Pattern::Str("b".into()), st("B")), (Pattern::Wildcard, st("?"))])),
                log(mt(bl(false), vec![(Pattern::Bool(true), st("T")), (Pattern::Bool(false), st("F"))])),
                log(mk(
                    ExprKind::Cond { cond: Box::new(bin(BinOp::Lt, int(1), int(2))), then: Box::new(st("lt")), els: Box::new(st("ge")) },
                    Type::String,
                )),
            ],
        )],
    );
    assert_eq!(run_both(&p).stdout, "two\nB\nF\nlt\n");
}

#[test]
fn option_result_try() {
    let res_t = Type::Result(Box::new(Type::Int), Box::new(Type::String));
    // parse(s): Result<int,string> = match parseInt(s) { Some(v) => Ok(v), None => Err("bad:" + s) }
    let pi = bi(Builtin::ParseInt, vec![loc(0, Type::String)], Type::Option(Box::new(Type::Int)));
    let m = mk(
        ExprKind::Match {
            scrutinee: Box::new(pi),
            arms: vec![
                MatchArm {
                    pattern: Pattern::Variant { tag: 0, bindings: vec![Some(LocalId(1))] },
                    body: blk(vec![]),
                    value: Some(ok(loc(1, Type::Int), Type::String)),
                },
                MatchArm {
                    pattern: Pattern::Variant { tag: 1, bindings: vec![] },
                    body: blk(vec![]),
                    value: Some(err(bin(BinOp::Add, st("bad:"), loc(0, Type::String)), Type::Int)),
                },
            ],
        },
        res_t.clone(),
    );
    let parse = func("parse", &[("s", Type::String)], &[("v", Type::Int, false)], res_t.clone(), vec![ret(m)]);
    // sum(a, b): Result<int,string> { const x = parse(a)?; const y = parse(b)?; return Ok(x + y); }
    let sum = func(
        "sum",
        &[("a", Type::String), ("b", Type::String)],
        &[("x", Type::Int, false), ("y", Type::Int, false), ("tmp", Type::String, false)],
        res_t.clone(),
        vec![
            let_(4, bin(BinOp::Add, loc(0, Type::String), loc(1, Type::String))),
            let_(2, mk(ExprKind::Try(Box::new(call(0, vec![loc(0, Type::String)], res_t.clone()))), Type::Int)),
            let_(3, mk(ExprKind::Try(Box::new(call(0, vec![loc(1, Type::String)], res_t.clone()))), Type::Int)),
            ret(ok(bin(BinOp::Add, loc(2, Type::Int), loc(3, Type::Int)), Type::String)),
        ],
    );
    let show = |a: &str, b: &str| {
        let r = call(1, vec![st(a), st(b)], res_t.clone());
        mk(
            ExprKind::Match {
                scrutinee: Box::new(r),
                arms: vec![
                    MatchArm {
                        pattern: Pattern::Variant { tag: 0, bindings: vec![Some(LocalId(0))] },
                        body: blk(vec![]),
                        value: Some(bin(BinOp::Add, st("ok "), itos(loc(0, Type::Int)))),
                    },
                    MatchArm {
                        pattern: Pattern::Variant { tag: 1, bindings: vec![Some(LocalId(1))] },
                        body: blk(vec![]),
                        value: Some(bin(BinOp::Add, st("err "), loc(1, Type::String))),
                    },
                ],
            },
            Type::String,
        )
    };
    let p = prog(
        vec![],
        vec![],
        vec![
            parse,
            sum,
            main_fn(
                &[("v", Type::Int, false), ("e", Type::String, false)],
                vec![
                    log(show("20", "22")),
                    log(show("20", "zz")),
                    log(show("q", "1")),
                    log(bi(
                        Builtin::ResUnwrapErr,
                        vec![call(1, vec![st("1"), st("x")], res_t.clone())],
                        Type::String,
                    )),
                    log(itos(bi(Builtin::ResUnwrap, vec![call(1, vec![st("1"), st("x")], res_t.clone())], Type::Int))),
                ],
            ),
        ],
    );
    let o = run_both(&p);
    assert_eq!(o.stdout, "ok 42\nerr bad:zz\nerr bad:q\nbad:x\n");
    assert!(o.stderr.contains("trap: unwrap on Err"));
    assert_eq!(o.code, 101);
}

#[test]
fn for_of_break_continue() {
    // for (const s of ["a","b","c","d","e"]) { const t = s + s; if (s == "b") continue; if (s == "e") break; log(t) }
    let body = blk(vec![
        let_(2, bin(BinOp::Add, loc(1, Type::String), loc(1, Type::String))),
        Stmt::If { cond: bin(BinOp::Eq, loc(1, Type::String), st("b")), then: blk(vec![Stmt::Continue]), els: None },
        Stmt::If { cond: bin(BinOp::Eq, loc(1, Type::String), st("e")), then: blk(vec![Stmt::Break]), els: None },
        log(loc(2, Type::String)),
    ]);
    // while loop with counter, break/continue
    let wbody = blk(vec![
        assign(place(3, vec![], Type::Int), Some(BinOp::Add), int(1)),
        let_(4, itos(loc(3, Type::Int))),
        Stmt::If { cond: bin(BinOp::Eq, loc(3, Type::Int), int(2)), then: blk(vec![Stmt::Continue]), els: None },
        Stmt::If { cond: bin(BinOp::Gt, loc(3, Type::Int), int(4)), then: blk(vec![Stmt::Break]), els: None },
        log(loc(4, Type::String)),
    ]);
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[("xs", s_arr(), false), ("s", Type::String, false), ("t", Type::String, false), ("n", Type::Int, true), ("c", Type::String, false)],
            vec![
                let_(0, arr(vec![st("a"), st("b"), st("c"), st("d"), st("e")].into_iter().map(|e| bin(BinOp::Add, e, st(""))).collect(), Type::String)),
                Stmt::ForOf { local: LocalId(1), iter: loc(0, s_arr()), body },
                let_(3, int(0)),
                Stmt::While { cond: bl(true), body: wbody },
                log(st("done")),
            ],
        )],
    );
    assert_eq!(run_both(&p).stdout, "aa\ncc\ndd\n1\n3\n4\ndone\n");
}

#[test]
fn recursion_fib_and_early_return() {
    // fib(n)
    let fib = func(
        "fib",
        &[("n", Type::Int)],
        &[],
        Type::Int,
        vec![
            Stmt::If { cond: bin(BinOp::Lt, loc(0, Type::Int), int(2)), then: blk(vec![ret(loc(0, Type::Int))]), els: None },
            ret(bin(
                BinOp::Add,
                call(0, vec![bin(BinOp::Sub, loc(0, Type::Int), int(1))], Type::Int),
                call(0, vec![bin(BinOp::Sub, loc(0, Type::Int), int(2))], Type::Int),
            )),
        ],
    );
    // early(n): string { const a = "x" + n; const b = [a, a]; if (n > 0) { const c = a + a; return c; } return b.join(",") }
    let early = func(
        "early",
        &[("n", Type::Int)],
        &[("a", Type::String, false), ("b", s_arr(), false), ("c", Type::String, false)],
        Type::String,
        vec![
            let_(1, bin(BinOp::Add, st("x"), itos(loc(0, Type::Int)))),
            let_(2, arr(vec![loc(1, Type::String), loc(1, Type::String)], Type::String)),
            Stmt::If {
                cond: bin(BinOp::Gt, loc(0, Type::Int), int(0)),
                then: blk(vec![let_(3, bin(BinOp::Add, loc(1, Type::String), loc(1, Type::String))), ret(loc(3, Type::String))]),
                els: None,
            },
            ret(bi(Builtin::ArrJoin, vec![loc(2, s_arr()), st(",")], Type::String)),
        ],
    );
    let p = prog(
        vec![],
        vec![],
        vec![
            fib,
            early,
            main_fn(&[], vec![log(itos(call(0, vec![int(20)], Type::Int))), log(call(1, vec![int(1)], Type::String)), log(call(1, vec![int(0)], Type::String))]),
        ],
    );
    assert_eq!(run_both(&p).stdout, "6765\nx1x1\nx0,x0\n");
}

#[test]
fn string_append_loop() {
    // let s = ""; let i = 0; while (i < 20000) { s += "ab"; s = s + "c"; i += 1 } print length
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[("s", Type::String, true), ("i", Type::Int, true), ("keep", Type::String, false)],
            vec![
                let_(0, bin(BinOp::Add, st("p"), st(""))),
                let_(1, int(0)),
                Stmt::While {
                    cond: bin(BinOp::Lt, loc(1, Type::Int), int(20000)),
                    body: blk(vec![
                        assign(place(0, vec![], Type::String), Some(BinOp::Add), st("ab")),
                        assign(place(0, vec![], Type::String), None, bin(BinOp::Add, loc(0, Type::String), st("c"))),
                        assign(place(1, vec![], Type::Int), Some(BinOp::Add), int(1)),
                        Stmt::If {
                            cond: bin(BinOp::Eq, loc(1, Type::Int), int(10)),
                            then: blk(vec![let_(2, loc(0, Type::String))]),
                            els: None,
                        },
                    ]),
                },
                log(utos(bi(Builtin::StrLength, vec![loc(0, Type::String)], Type::Usize))),
                // self-append must not corrupt
                assign(place(0, vec![], Type::String), Some(BinOp::Add), loc(0, Type::String)),
                log(utos(bi(Builtin::StrLength, vec![loc(0, Type::String)], Type::Usize))),
            ],
        )],
    );
    assert_eq!(run_both(&p).stdout, "60001\n120002\n");
}

#[test]
fn exit_flushes_stdout() {
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[],
            vec![
                log(st("bye")),
                Stmt::Expr(bi(Builtin::ProcessExit, vec![int(3)], Type::Void)),
                log(st("unreachable")),
            ],
        )],
    );
    let o = run(&p);
    assert_eq!((o.stdout.as_str(), o.code), ("bye\n", 3));
}

#[test]
fn args_and_fs() {
    let res_s = Type::Result(Box::new(Type::String), Box::new(Type::String));
    let path = std::env::temp_dir().join(format!("orinb_cg_file_{}", std::process::id()));
    let ps = path.to_str().unwrap().to_string();
    let write = bi(Builtin::FsWriteFile, vec![st(&ps), st("data\n")], Type::Result(Box::new(Type::Void), Box::new(Type::String)));
    let read = bi(Builtin::FsReadFile, vec![st(&ps)], res_s.clone());
    let p = prog(
        vec![],
        vec![],
        vec![main_fn(
            &[],
            vec![
                log(utos(bi(Builtin::ArrLength, vec![bi(Builtin::ProcessArgs, vec![], s_arr())], Type::Usize))),
                log(idx(bi(Builtin::ProcessArgs, vec![], s_arr()), usz(0), Type::String)),
                Stmt::Expr(bi(Builtin::ResUnwrap, vec![write], Type::Void)),
                log(bi(Builtin::ResUnwrap, vec![read], Type::String)),
                log(bi(Builtin::BoolToString, vec![bi(Builtin::FsExists, vec![st(&ps)], Type::Bool)], Type::String)),
                log(bi(
                    Builtin::ResUnwrapErr,
                    vec![bi(Builtin::FsReadFile, vec![st("/no/such/file")], res_s.clone())],
                    Type::String,
                )),
            ],
        )],
    );
    let o = run_args(&p, false, &["first", "second"]);
    let _ = std::fs::remove_file(&path);
    assert!(o.stdout.starts_with("2\nfirst\ndata\n\ntrue\ncannot read '/no/such/file'"), "{}", o.stdout);
}

#[test]
fn asan_refcount_stress() {
    // Mixed ownership: arrays of records shared and mutated, for-of over a snapshot that is
    // mutated inside the loop, spread, matches with bindings, early return in loop.
    let item = Type::Record(RecordId(0));
    let items = Type::Array(Box::new(item.clone()));
    let mkitem = |n: i64, s: &str| rec(0, vec![(0, int(n)), (1, bin(BinOp::Add, st(s), itos(int(n))))]);
    // f(xs: Item[]): string { for (const it of xs) { if (it.n == 2) { return it.name + "!" } } return "none" }
    let f = func(
        "find",
        &[("xs", items.clone())],
        &[("it", item.clone(), false)],
        Type::String,
        vec![
            Stmt::ForOf {
                local: LocalId(1),
                iter: loc(0, items.clone()),
                body: blk(vec![Stmt::If {
                    cond: bin(BinOp::Eq, fld(loc(1, item.clone()), 0, 0, Type::Int), int(2)),
                    then: blk(vec![ret(bin(BinOp::Add, fld(loc(1, item.clone()), 0, 1, Type::String), st("!")))]),
                    els: None,
                }]),
            },
            ret(st("none")),
        ],
    );
    let ys = || place(0, vec![], items.clone());
    let push = |e: Expr| Stmt::Expr(mk(ExprKind::MutMethod { op: MutBuiltin::ArrPush, place: ys(), args: vec![e] }, Type::Void));
    let p = prog(
        vec![rdef("Item", vec![("n", Type::Int), ("name", Type::String)])],
        vec![],
        vec![
            f,
            main_fn(
                &[("xs", items.clone(), true), ("snap", items.clone(), false), ("it", item.clone(), false), ("cp", item.clone(), true)],
                vec![
                    let_(0, arr(vec![mkitem(1, "a"), mkitem(2, "b")], item.clone())),
                    let_(1, loc(0, items.clone())),
                    Stmt::ForOf {
                        local: LocalId(2),
                        iter: loc(0, items.clone()),
                        body: blk(vec![push(mkitem(9, "z")), assign(place(0, vec![PlaceElem::Index(usz(0)), field_el(0, 0)], Type::Int), Some(BinOp::Add), int(100))]),
                    },
                    log(call(0, vec![loc(0, items.clone())], Type::String)),
                    log(call(0, vec![loc(1, items.clone())], Type::String)),
                    log(utos(bi(Builtin::ArrLength, vec![loc(0, items.clone())], Type::Usize))),
                    log(itos(fld(idx(loc(0, items.clone()), usz(0), item.clone()), 0, 0, Type::Int))),
                    log(itos(fld(idx(loc(1, items.clone()), usz(0), item.clone()), 0, 0, Type::Int))),
                    let_(3, mk(ExprKind::Record { record: RecordId(0), spread: Some(Box::new(idx(loc(0, items.clone()), usz(2), item.clone()))), fields: vec![(0, int(7))] }, item.clone())),
                    assign(place(3, vec![field_el(0, 1)], Type::String), Some(BinOp::Add), st("+")),
                    log(fld(loc(3, item.clone()), 0, 1, Type::String)),
                    log(fld(idx(loc(0, items.clone()), usz(2), item.clone()), 0, 1, Type::String)),
                ],
            ),
        ],
    );
    let o = run_both(&p);
    assert_eq!(o.stdout, "b2!\nb2!\n4\n201\n1\nz9+\nz9\n");
}

#[test]
fn deterministic_output() {
    let mk_p = || prog(vec![], vec![], vec![main_fn(&[], vec![log(st("a")), log(st("b")), log(st("a"))])]);
    assert_eq!(generate(&mk_p()), generate(&mk_p()));
    let c = generate(&mk_p());
    assert!(c.contains("orin_fn_0_main"));
    assert_eq!(c.matches("ORIN_STRING_LIT").count(), 2);
}

#[test]
fn runtime_c_tests() {
    let d = work_dir();
    for asan in [false, true] {
        let exe = d.join(if asan { "rt_asan" } else { "rt" });
        let mut c = Command::new("cc");
        c.args(["-Wall", "-Wextra", "-g", "-I"]).arg(runtime_dir()).arg(runtime_dir().join("tests/runtime_test.c")).arg(runtime_dir().join("orin_runtime.c")).arg(runtime_dir().join("../platform/orin_platform.c")).arg("-o").arg(&exe);
        if asan {
            c.arg("-fsanitize=address,undefined");
        }
        let r = c.output().unwrap();
        assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
        let r = Command::new(&exe).env("ASAN_OPTIONS", "detect_leaks=0").output().unwrap();
        assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
        assert_eq!(String::from_utf8_lossy(&r.stdout), "ok\n");
    }
}
