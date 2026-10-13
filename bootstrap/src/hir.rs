//! Typed, fully resolved HIR for a whole program. Shared contract (v1) — owned by the lead
//! architect. Producer: checker.rs. Consumer: codegen.rs.
//!
//! Invariants guaranteed by the checker (codegen may rely on them):
//! - Every `Expr` carries its final `Type`; literals have their adopted type.
//! - All names are resolved: locals → `LocalId` (index into `Function::locals`), functions →
//!   `FuncId`, records → `RecordId`, unions → `UnionId`. Top-level consts are inlined as literals.
//! - Aliases are expanded; no `Type` refers to an alias.
//! - Places in `Assign`/`MutMethod` are rooted at a mutable (`let`) local.
//! - Matches are exhaustive (codegen still emits a trap for the impossible fall-through).
//! - Compound assignment keeps its operator (`Assign::op`); the place is evaluated once.
//! - A non-void function's body cannot fall off the end (codegen may still emit a trap there).

use crate::span::Span;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FuncId(pub u32);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RecordId(pub u32);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct UnionId(pub u32);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LocalId(pub u32);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Type {
    Int,
    Usize,
    Bool,
    String,
    Void,
    Array(Box<Type>),
    Option(Box<Type>),
    Result(Box<Type>, Box<Type>),
    Record(RecordId),
    Union(UnionId),
}

impl Type {
    /// Scalars are unboxed in generated code; everything else is a reference-counted heap object.
    pub fn is_scalar(&self) -> bool {
        matches!(self, Type::Int | Type::Usize | Type::Bool | Type::Void)
    }
}

pub struct Program {
    pub records: Vec<RecordDef>,
    pub unions: Vec<UnionDef>,
    pub functions: Vec<Function>,
    pub main: FuncId,
}

pub struct RecordDef {
    /// Qualified, unique, human-readable, e.g. "users/user.User". Deterministic.
    pub name: String,
    pub fields: Vec<(String, Type)>,
}

pub struct UnionDef {
    pub name: String,
    pub variants: Vec<VariantDef>,
}

pub struct VariantDef {
    pub name: String,
    pub payload: Vec<Type>,
}

pub struct Function {
    /// Qualified, unique, human-readable, e.g. "users/service.findUser". Deterministic.
    pub name: String,
    /// The first `param_count` locals are the parameters, in order.
    pub param_count: u32,
    pub locals: Vec<Local>,
    pub ret: Type,
    pub body: Block,
    pub span: Span,
}

pub struct Local {
    /// Source name (not unique; for debugging/C comments).
    pub name: String,
    pub ty: Type,
    pub mutable: bool,
}

pub struct Block {
    pub stmts: Vec<Stmt>,
}

pub enum Stmt {
    /// Declare and initialize a local (`const`/`let`). Scope: until the end of the enclosing block.
    Let { local: LocalId, init: Expr },
    /// `place op= value`; `op == None` is plain assignment. `op` is one of Add/Sub/Mul/Div/Rem.
    Assign { place: Place, op: Option<BinOp>, value: Expr },
    Expr(Expr),
    If { cond: Expr, then: Block, els: Option<Block> },
    While { cond: Expr, body: Block },
    /// Evaluates `iter` (an array) once, then binds `local` to each element in order.
    ForOf { local: LocalId, iter: Expr, body: Block },
    Break,
    Continue,
    Return(Option<Expr>),
    Block(Block),
}

pub struct Place {
    pub root: LocalId,
    pub path: Vec<PlaceElem>,
    /// Type of the whole place.
    pub ty: Type,
}

pub enum PlaceElem {
    /// Field index in the record's declaration order.
    Field { record: RecordId, index: u32 },
    /// Array element; index expression has type `usize`.
    Index(Expr),
}

pub struct Expr {
    pub kind: ExprKind,
    pub ty: Type,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnOp {
    Not,
    Neg,
}

/// Operand types are fixed by the checker: arithmetic on Int/Usize (Add also on String =
/// concatenation); Eq/Ne on Int/Usize/Bool/String; ordering on Int/Usize; And/Or on Bool
/// (short-circuit).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
}

pub enum ExprKind {
    Int(i64),
    Bool(bool),
    Str(String),
    Local(LocalId),
    Unary { op: UnOp, expr: Box<Expr> },
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
    Call { func: FuncId, args: Vec<Expr> },
    /// Non-mutating built-in function or method. Receiver (if any) is `args[0]`.
    Builtin { op: Builtin, args: Vec<Expr> },
    /// Mutating built-in method on a place (`xs.push(v)`, `xs.pop()`).
    MutMethod { op: MutBuiltin, place: Place, args: Vec<Expr> },
    /// `base.field`
    Field { base: Box<Expr>, record: RecordId, index: u32 },
    /// `base[index]` (array, trapping)
    Index { base: Box<Expr>, index: Box<Expr> },
    /// Record literal. `fields` lists explicitly given fields as (field index, value) in
    /// source order; missing fields come from `spread` (which is then `Some`).
    /// Evaluation order: spread first, then fields in source order.
    Record { record: RecordId, spread: Option<Box<Expr>>, fields: Vec<(u32, Expr)> },
    /// Construct a variant of the union/Option/Result given by `Expr::ty`.
    /// Tags: user unions = declaration order; Option: Some=0, None=1; Result: Ok=0, Err=1.
    /// `Ok()` for `Result<void, E>` has an empty payload.
    Variant { tag: u32, payload: Vec<Expr> },
    Array(Vec<Expr>),
    /// Postfix `?` on a `Result<T, E>`: yields T, or returns `Err(e)` from the function.
    Try(Box<Expr>),
    Cond { cond: Box<Expr>, then: Box<Expr>, els: Box<Expr> },
    Match { scrutinee: Box<Expr>, arms: Vec<MatchArm> },
}

pub struct MatchArm {
    pub pattern: Pattern,
    /// Statements executed first (for block arms).
    pub body: Block,
    /// Arm value for match expressions with non-void type. `None` when the match has type
    /// `Void` or when `body` diverges.
    pub value: Option<Expr>,
}

pub enum Pattern {
    Wildcard,
    /// Variant tag (see `ExprKind::Variant`), with one entry per payload element: `Some(local)`
    /// binds it, `None` ignores it (`_`).
    Variant { tag: u32, bindings: Vec<Option<LocalId>> },
    Int(i64),
    Str(String),
    Bool(bool),
}

/// Non-mutating built-ins. Signatures: see docs/bootstrap-subset.md §6. Receiver is args[0].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Builtin {
    ConsoleLog,
    ConsoleError,
    StringFromCharCode,
    ParseInt,
    FsReadFile,
    FsWriteFile,
    FsExists,
    ProcessArgs,
    ProcessExit,
    StrLength,
    StrCharCodeAt,
    StrCharAt,
    StrSubstring,
    StrIndexOf,
    StrIncludes,
    StrStartsWith,
    StrEndsWith,
    StrSplit,
    StrTrim,
    ArrLength,
    ArrGet,
    ArrSlice,
    ArrConcat,
    ArrJoin,
    IntToString,
    IntToUsize,
    UsizeToString,
    UsizeToInt,
    BoolToString,
    OptIsSome,
    OptIsNone,
    OptUnwrap,
    OptUnwrapOr,
    ResIsOk,
    ResIsErr,
    ResUnwrap,
    ResUnwrapErr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MutBuiltin {
    ArrPush,
    ArrPop,
}
