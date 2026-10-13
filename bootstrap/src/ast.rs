//! Untyped syntax tree for one `.or` file. Shared contract (v1) — owned by the lead architect.
//! Producer: parser.rs. Consumers: loader.rs, checker.rs.
//! The parser accepts the Orin-B grammar (docs/bootstrap-subset.md) plus generic parameter
//! lists, which the checker rejects with E0408.

use crate::span::{FileId, Span};

#[derive(Clone, Debug, PartialEq)]
pub struct Ident {
    pub name: String,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Module {
    pub file: FileId,
    pub items: Vec<Item>,
}

#[derive(Clone, Debug)]
pub enum Item {
    Import(ImportDecl),
    ReExport(ReExportDecl),
    Function(FunctionDecl),
    Type(TypeDecl),
    Const(ConstDecl),
}

/// `import { a, b } from "path";`
#[derive(Clone, Debug)]
pub struct ImportDecl {
    pub names: Vec<Ident>,
    pub path: String,
    pub path_span: Span,
    pub span: Span,
}

/// `export { a, b } from "path";`
#[derive(Clone, Debug)]
pub struct ReExportDecl {
    pub names: Vec<Ident>,
    pub path: String,
    pub path_span: Span,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct FunctionDecl {
    pub exported: bool,
    pub name: Ident,
    pub type_params: Vec<Ident>,
    pub params: Vec<Param>,
    /// `None` means no annotation, which is `void`.
    pub ret: Option<TypeExpr>,
    pub body: Block,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Param {
    pub name: Ident,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct TypeDecl {
    pub exported: bool,
    pub name: Ident,
    pub type_params: Vec<Ident>,
    pub body: TypeDeclBody,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum TypeDeclBody {
    /// `type A = B;`
    Alias(TypeExpr),
    /// `type P = { x: int; y: int; };`
    Record(Vec<FieldDecl>),
    /// `type S = A(int) | B;`  (rule: any `|` or any `Name(...)` member → union)
    Union(Vec<VariantDecl>),
}

#[derive(Clone, Debug)]
pub struct FieldDecl {
    pub name: Ident,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct VariantDecl {
    pub name: Ident,
    pub payload: Vec<TypeExpr>,
    pub span: Span,
}

/// `export const N: int = 3;`
#[derive(Clone, Debug)]
pub struct ConstDecl {
    pub exported: bool,
    pub name: Ident,
    pub ty: Option<TypeExpr>,
    pub value: Expr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct TypeExpr {
    pub kind: TypeExprKind,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum TypeExprKind {
    /// `int`, `User`, `Option<int>`, `Result<T, E>`
    Named { name: Ident, args: Vec<TypeExpr> },
    /// `T[]`
    Array(Box<TypeExpr>),
}

#[derive(Clone, Debug)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Stmt {
    pub kind: StmtKind,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssignOp {
    Assign,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
}

#[derive(Clone, Debug)]
pub enum StmtKind {
    /// `const`/`let` declaration; `mutable` is true for `let`.
    Let { mutable: bool, name: Ident, ty: Option<TypeExpr>, init: Expr },
    /// `target op value;` — target is any expression syntactically; the checker validates places.
    Assign { target: Expr, op: AssignOp, value: Expr },
    Expr(Expr),
    Return(Option<Expr>),
    /// `els` is either `StmtKind::Block` or another `StmtKind::If`.
    If { cond: Expr, then: Block, els: Option<Box<Stmt>> },
    While { cond: Expr, body: Block },
    /// `for (const name of iter) body`
    ForOf { name: Ident, iter: Expr, body: Block },
    Break,
    Continue,
    Block(Block),
}

#[derive(Clone, Debug)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnaryOp {
    Not,
    Neg,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinaryOp {
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

#[derive(Clone, Debug)]
pub enum ExprKind {
    Int(i64),
    Str(String),
    Bool(bool),
    Ident(Ident),
    Unary { op: UnaryOp, expr: Box<Expr> },
    Binary { op: BinaryOp, lhs: Box<Expr>, rhs: Box<Expr> },
    Call { callee: Box<Expr>, args: Vec<Expr> },
    Member { base: Box<Expr>, name: Ident },
    Index { base: Box<Expr>, index: Box<Expr> },
    /// postfix `?`
    Try(Box<Expr>),
    Cond { cond: Box<Expr>, then: Box<Expr>, els: Box<Expr> },
    Array(Vec<Expr>),
    /// `Name { ...spread, f: e }`
    Record { name: Ident, spread: Option<Box<Expr>>, fields: Vec<FieldInit> },
    Match { scrutinee: Box<Expr>, arms: Vec<MatchArm> },
}

#[derive(Clone, Debug)]
pub struct FieldInit {
    pub name: Ident,
    pub value: Expr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: ArmBody,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum ArmBody {
    Expr(Expr),
    Block(Block),
}

#[derive(Clone, Debug)]
pub struct Pattern {
    pub kind: PatternKind,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum PatternKind {
    /// `_`
    Wildcard,
    /// Bare name: a nullary variant (checker decides; Orin-B has no top-level binding patterns).
    Ident(Ident),
    /// `Name(p, ...)`; sub-patterns must be `Ident` (binding) or `Wildcard` in Orin-B.
    Variant { name: Ident, args: Vec<Pattern> },
    Int(i64),
    Str(String),
    Bool(bool),
}
