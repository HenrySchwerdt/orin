//! Parser: tokens → ast::Module. Owned by the parser worker.
//!
//! Hand-written recursive descent; stops at the first error in a file.

use crate::ast::*;
use crate::diag::{DResult, Diagnostic};
use crate::lexer::{describe, lex, Tok, Token};
use crate::span::{FileId, Span};

type PResult<T> = Result<T, Diagnostic>;

pub fn parse(file: FileId, src: &str) -> DResult<Module> {
    let toks = lex(file, src).map_err(|d| vec![d])?;
    let mut p = Parser { file, toks, pos: 0 };
    p.module().map_err(|d| vec![d])
}

struct Parser {
    file: FileId,
    toks: Vec<Token>,
    pos: usize,
}

impl Parser {
    // ---- token helpers ----
    fn peek(&self) -> &Tok {
        &self.toks[self.pos].tok
    }
    fn peek_at(&self, n: usize) -> &Tok {
        let i = (self.pos + n).min(self.toks.len() - 1);
        &self.toks[i].tok
    }
    fn span(&self) -> Span {
        self.toks[self.pos].span
    }
    fn prev_end(&self) -> u32 {
        if self.pos == 0 {
            0
        } else {
            self.toks[self.pos - 1].span.end
        }
    }
    fn since(&self, start: u32) -> Span {
        Span::new(self.file, start, self.prev_end().max(start))
    }
    fn bump(&mut self) -> Token {
        let t = self.toks[self.pos].clone();
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
        t
    }
    fn at(&self, t: &Tok) -> bool {
        self.peek() == t
    }
    fn eat(&mut self, t: &Tok) -> bool {
        if self.at(t) {
            self.bump();
            true
        } else {
            false
        }
    }
    fn err_here(&self, msg: impl Into<String>) -> Diagnostic {
        Diagnostic::new("E0200", self.span(), msg)
    }
    /// `expected <what>, found <tok>`; handles `var` / reserved words specially.
    fn unexpected(&self, what: &str) -> Diagnostic {
        match self.peek() {
            Tok::Var => self.var_error(),
            Tok::Reserved(w) => self.err_here(format!(
                "expected {}, found reserved word `{}` (reserved words cannot be used here)",
                what, w
            )),
            t => self.err_here(format!("expected {}, found {}", what, describe(t))),
        }
    }
    fn var_error(&self) -> Diagnostic {
        Diagnostic::new("E0201", self.span(), "`var` is not allowed in Orin; use `const` or `let`")
    }
    fn expect(&mut self, t: &Tok, what: &str) -> PResult<Token> {
        if self.at(t) {
            Ok(self.bump())
        } else {
            Err(self.unexpected(what))
        }
    }
    fn ident(&mut self, what: &str) -> PResult<Ident> {
        match self.peek() {
            Tok::Ident(_) => {
                let t = self.bump();
                let Tok::Ident(name) = t.tok else { unreachable!() };
                Ok(Ident { name, span: t.span })
            }
            Tok::Reserved(w) => Err(self.err_here(format!(
                "`{}` is a reserved word and cannot be used as an identifier",
                w
            ))),
            _ => Err(self.unexpected(what)),
        }
    }

    // ---- module level ----
    fn module(&mut self) -> PResult<Module> {
        let mut items = Vec::new();
        while !self.at(&Tok::Eof) {
            items.push(self.item()?);
        }
        Ok(Module { file: self.file, items })
    }

    fn item(&mut self) -> PResult<Item> {
        let start = self.span().start;
        match self.peek() {
            Tok::Import => {
                self.bump();
                let (names, path, path_span) = self.import_tail("import")?;
                Ok(Item::Import(ImportDecl { names, path, path_span, span: self.since(start) }))
            }
            Tok::Export => {
                self.bump();
                match self.peek() {
                    Tok::LBrace => {
                        let (names, path, path_span) = self.import_tail("export")?;
                        Ok(Item::ReExport(ReExportDecl { names, path, path_span, span: self.since(start) }))
                    }
                    Tok::Function => Ok(Item::Function(self.function(true, start)?)),
                    Tok::Type => Ok(Item::Type(self.type_decl(true, start)?)),
                    Tok::Const => Ok(Item::Const(self.const_decl(true, start)?)),
                    _ => Err(self.unexpected("`function`, `type`, `const` or `{` after `export`")),
                }
            }
            Tok::Function => Ok(Item::Function(self.function(false, start)?)),
            Tok::Type => Ok(Item::Type(self.type_decl(false, start)?)),
            Tok::Const => Ok(Item::Const(self.const_decl(false, start)?)),
            Tok::Let => Err(self.err_here("top-level `let` is not allowed; use `const` with a literal initializer")),
            _ => Err(self.unexpected("a declaration (`import`, `export`, `function`, `type` or `const`)")),
        }
    }

    /// `{ a, b } from "path";`
    fn import_tail(&mut self, kw: &str) -> PResult<(Vec<Ident>, String, Span)> {
        self.expect(&Tok::LBrace, &format!("`{{` after `{}`", kw))?;
        let mut names = Vec::new();
        while !self.at(&Tok::RBrace) {
            names.push(self.ident("a name")?);
            if !self.eat(&Tok::Comma) {
                break;
            }
        }
        self.expect(&Tok::RBrace, "`}` or `,` in name list")?;
        self.expect(&Tok::From, "`from`")?;
        let t = self.toks[self.pos].clone();
        let Tok::Str(path) = t.tok else {
            return Err(self.unexpected("a module path string"));
        };
        self.bump();
        self.expect(&Tok::Semi, "`;` after module path")?;
        Ok((names, path, t.span))
    }

    fn type_params(&mut self) -> PResult<Vec<Ident>> {
        let mut v = Vec::new();
        if self.eat(&Tok::Lt) {
            loop {
                v.push(self.ident("a type parameter name")?);
                if !self.eat(&Tok::Comma) {
                    break;
                }
            }
            self.expect(&Tok::Gt, "`>` after type parameters")?;
        }
        Ok(v)
    }

    fn function(&mut self, exported: bool, start: u32) -> PResult<FunctionDecl> {
        self.expect(&Tok::Function, "`function`")?;
        let name = self.ident("a function name")?;
        let type_params = self.type_params()?;
        self.expect(&Tok::LParen, "`(` after function name")?;
        let mut params = Vec::new();
        while !self.at(&Tok::RParen) {
            let ps = self.span().start;
            let pname = self.ident("a parameter name")?;
            self.expect(&Tok::Colon, "`:` after parameter name")?;
            let ty = self.type_expr()?;
            params.push(Param { name: pname, ty, span: self.since(ps) });
            if !self.eat(&Tok::Comma) {
                break;
            }
        }
        self.expect(&Tok::RParen, "`)` or `,` in parameter list")?;
        let ret = if self.eat(&Tok::Colon) { Some(self.type_expr()?) } else { None };
        if !self.at(&Tok::LBrace) {
            return Err(self.unexpected("`{` to start the function body"));
        }
        let body = self.block()?;
        Ok(FunctionDecl { exported, name, type_params, params, ret, body, span: self.since(start) })
    }

    fn const_decl(&mut self, exported: bool, start: u32) -> PResult<ConstDecl> {
        self.expect(&Tok::Const, "`const`")?;
        let name = self.ident("a constant name")?;
        let ty = if self.eat(&Tok::Colon) { Some(self.type_expr()?) } else { None };
        self.expect(&Tok::Eq, "`=` (constants require an initializer)")?;
        let value = self.expr()?;
        self.expect(&Tok::Semi, "`;` after constant declaration")?;
        Ok(ConstDecl { exported, name, ty, value, span: self.since(start) })
    }

    fn type_decl(&mut self, exported: bool, start: u32) -> PResult<TypeDecl> {
        self.expect(&Tok::Type, "`type`")?;
        let name = self.ident("a type name")?;
        let type_params = self.type_params()?;
        self.expect(&Tok::Eq, "`=` in type declaration")?;
        let body = if self.at(&Tok::LBrace) {
            self.bump();
            let mut fields = Vec::new();
            while !self.at(&Tok::RBrace) {
                let fs = self.span().start;
                let fname = self.ident("a field name")?;
                self.expect(&Tok::Colon, "`:` after field name")?;
                let ty = self.type_expr()?;
                self.expect(&Tok::Semi, "`;` after field declaration")?;
                fields.push(FieldDecl { name: fname, ty, span: self.since(fs) });
            }
            self.expect(&Tok::RBrace, "`}`")?;
            TypeDeclBody::Record(fields)
        } else {
            let first_start = self.span().start;
            let is_variant_call = matches!(self.peek(), Tok::Ident(_)) && self.peek_at(1) == &Tok::LParen;
            let mut variants = Vec::new();
            let mut is_union = false;
            let mut alias: Option<TypeExpr> = None;
            if is_variant_call {
                is_union = true;
                variants.push(self.variant()?);
            } else {
                let ty = self.type_expr()?;
                if self.at(&Tok::Pipe) {
                    is_union = true;
                    match ty.kind {
                        TypeExprKind::Named { name, args } if args.is_empty() => {
                            variants.push(VariantDecl { name, payload: Vec::new(), span: ty.span });
                        }
                        _ => {
                            return Err(Diagnostic::new(
                                "E0200",
                                ty.span,
                                "union members must be `Name` or `Name(T, ...)`",
                            ))
                        }
                    }
                } else {
                    alias = Some(ty);
                }
            }
            let _ = first_start;
            if is_union {
                while self.eat(&Tok::Pipe) {
                    variants.push(self.variant()?);
                }
                TypeDeclBody::Union(variants)
            } else {
                TypeDeclBody::Alias(alias.unwrap())
            }
        };
        self.expect(&Tok::Semi, "`;` after type declaration")?;
        Ok(TypeDecl { exported, name, type_params, body, span: self.since(start) })
    }

    fn variant(&mut self) -> PResult<VariantDecl> {
        let vs = self.span().start;
        let name = self.ident("a variant name")?;
        let mut payload = Vec::new();
        if self.eat(&Tok::LParen) {
            loop {
                payload.push(self.type_expr()?);
                if !self.eat(&Tok::Comma) || self.at(&Tok::RParen) {
                    break;
                }
            }
            self.expect(&Tok::RParen, "`)` or `,` in variant payload")?;
        }
        Ok(VariantDecl { name, payload, span: self.since(vs) })
    }

    // ---- types ----
    fn type_expr(&mut self) -> PResult<TypeExpr> {
        let start = self.span().start;
        let name = self.ident("a type")?;
        let mut args = Vec::new();
        if self.eat(&Tok::Lt) {
            loop {
                args.push(self.type_expr()?);
                if !self.eat(&Tok::Comma) {
                    break;
                }
            }
            self.expect(&Tok::Gt, "`>` after type arguments")?;
        }
        let mut ty = TypeExpr { kind: TypeExprKind::Named { name, args }, span: self.since(start) };
        while self.at(&Tok::LBracket) && self.peek_at(1) == &Tok::RBracket {
            self.bump();
            self.bump();
            ty = TypeExpr { kind: TypeExprKind::Array(Box::new(ty)), span: self.since(start) };
        }
        Ok(ty)
    }

    // ---- statements ----
    fn block(&mut self) -> PResult<Block> {
        let start = self.span().start;
        self.expect(&Tok::LBrace, "`{`")?;
        let mut stmts = Vec::new();
        while !self.at(&Tok::RBrace) {
            if self.at(&Tok::Eof) {
                return Err(self.err_here("expected `}` to close block, found end of file"));
            }
            stmts.push(self.stmt()?);
        }
        self.bump();
        Ok(Block { stmts, span: self.since(start) })
    }

    fn paren_expr(&mut self, what: &str) -> PResult<Expr> {
        self.expect(&Tok::LParen, &format!("`(` after `{}`", what))?;
        let e = self.expr()?;
        self.expect(&Tok::RParen, "`)` after condition")?;
        Ok(e)
    }

    fn stmt(&mut self) -> PResult<Stmt> {
        let start = self.span().start;
        let kind = match self.peek() {
            Tok::Var => return Err(self.var_error()),
            Tok::Const | Tok::Let => {
                let mutable = self.at(&Tok::Let);
                self.bump();
                let name = self.ident("a variable name")?;
                let ty = if self.eat(&Tok::Colon) { Some(self.type_expr()?) } else { None };
                if !self.at(&Tok::Eq) {
                    return Err(self.unexpected("`=` (declarations require an initializer)"));
                }
                self.bump();
                let init = self.expr()?;
                self.expect(&Tok::Semi, "`;` after declaration")?;
                StmtKind::Let { mutable, name, ty, init }
            }
            Tok::Return => {
                self.bump();
                let v = if self.at(&Tok::Semi) { None } else { Some(self.expr()?) };
                self.expect(&Tok::Semi, "`;` after `return`")?;
                StmtKind::Return(v)
            }
            Tok::Break => {
                self.bump();
                self.expect(&Tok::Semi, "`;` after `break`")?;
                StmtKind::Break
            }
            Tok::Continue => {
                self.bump();
                self.expect(&Tok::Semi, "`;` after `continue`")?;
                StmtKind::Continue
            }
            Tok::If => return self.if_stmt(),
            Tok::While => {
                self.bump();
                let cond = self.paren_expr("while")?;
                let body = self.block_required("`{` after `while (...)`")?;
                StmtKind::While { cond, body }
            }
            Tok::For => {
                self.bump();
                self.expect(&Tok::LParen, "`(` after `for`")?;
                if self.at(&Tok::Var) {
                    return Err(self.var_error());
                }
                self.expect(&Tok::Const, "`const` in `for (const x of ...)`")?;
                let name = self.ident("a loop variable name")?;
                self.expect(&Tok::Of, "`of`")?;
                let iter = self.expr()?;
                self.expect(&Tok::RParen, "`)` after for-of header")?;
                let body = self.block_required("`{` after `for (...)`")?;
                StmtKind::ForOf { name, iter, body }
            }
            Tok::LBrace => StmtKind::Block(self.block()?),
            _ => {
                let e = self.expr()?;
                let op = match self.peek() {
                    Tok::Eq => Some(AssignOp::Assign),
                    Tok::PlusEq => Some(AssignOp::Add),
                    Tok::MinusEq => Some(AssignOp::Sub),
                    Tok::StarEq => Some(AssignOp::Mul),
                    Tok::SlashEq => Some(AssignOp::Div),
                    Tok::PercentEq => Some(AssignOp::Rem),
                    _ => None,
                };
                if let Some(op) = op {
                    self.bump();
                    let value = self.expr()?;
                    self.expect(&Tok::Semi, "`;` after assignment")?;
                    StmtKind::Assign { target: e, op, value }
                } else {
                    let is_match = matches!(e.kind, ExprKind::Match { .. });
                    if self.at(&Tok::Semi) {
                        self.bump();
                    } else if !is_match {
                        return Err(self.unexpected("`;` after expression"));
                    }
                    StmtKind::Expr(e)
                }
            }
        };
        Ok(Stmt { kind, span: self.since(start) })
    }

    fn block_required(&mut self, what: &str) -> PResult<Block> {
        if !self.at(&Tok::LBrace) {
            return Err(self.unexpected(what));
        }
        self.block()
    }

    fn if_stmt(&mut self) -> PResult<Stmt> {
        let start = self.span().start;
        self.expect(&Tok::If, "`if`")?;
        let cond = self.paren_expr("if")?;
        let then = self.block_required("`{` after `if (...)`")?;
        let els = if self.eat(&Tok::Else) {
            if self.at(&Tok::If) {
                Some(Box::new(self.if_stmt()?))
            } else {
                let bs = self.span().start;
                let b = self.block_required("`{` or `if` after `else`")?;
                Some(Box::new(Stmt { kind: StmtKind::Block(b), span: self.since(bs) }))
            }
        } else {
            None
        };
        Ok(Stmt { kind: StmtKind::If { cond, then, els }, span: self.since(start) })
    }

    // ---- expressions ----
    pub fn expr(&mut self) -> PResult<Expr> {
        let cond = self.binary(0)?;
        if self.at(&Tok::Question) {
            self.bump();
            let then = self.expr()?;
            self.expect(&Tok::Colon, "`:` in conditional expression")?;
            let els = self.expr()?;
            let span = cond.span.to(els.span);
            return Ok(Expr {
                kind: ExprKind::Cond { cond: Box::new(cond), then: Box::new(then), els: Box::new(els) },
                span,
            });
        }
        Ok(cond)
    }

    fn binop(&self, level: usize) -> Option<BinaryOp> {
        let t = self.peek();
        match level {
            0 => matches!(t, Tok::OrOr).then_some(BinaryOp::Or),
            1 => matches!(t, Tok::AndAnd).then_some(BinaryOp::And),
            2 => match t {
                Tok::EqEq => Some(BinaryOp::Eq),
                Tok::NotEq => Some(BinaryOp::Ne),
                _ => None,
            },
            3 => match t {
                Tok::Lt => Some(BinaryOp::Lt),
                Tok::Le => Some(BinaryOp::Le),
                Tok::Gt => Some(BinaryOp::Gt),
                Tok::Ge => Some(BinaryOp::Ge),
                _ => None,
            },
            4 => match t {
                Tok::Plus => Some(BinaryOp::Add),
                Tok::Minus => Some(BinaryOp::Sub),
                _ => None,
            },
            5 => match t {
                Tok::Star => Some(BinaryOp::Mul),
                Tok::Slash => Some(BinaryOp::Div),
                Tok::Percent => Some(BinaryOp::Rem),
                _ => None,
            },
            _ => None,
        }
    }

    fn binary(&mut self, level: usize) -> PResult<Expr> {
        if level > 5 {
            return self.unary();
        }
        let mut lhs = self.binary(level + 1)?;
        while let Some(op) = self.binop(level) {
            self.bump();
            let rhs = self.binary(level + 1)?;
            let span = lhs.span.to(rhs.span);
            lhs = Expr { kind: ExprKind::Binary { op, lhs: Box::new(lhs), rhs: Box::new(rhs) }, span };
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> PResult<Expr> {
        let op = match self.peek() {
            Tok::Bang => UnaryOp::Not,
            Tok::Minus => UnaryOp::Neg,
            _ => return self.postfix(),
        };
        let start = self.span().start;
        self.bump();
        let e = self.unary()?;
        Ok(Expr { kind: ExprKind::Unary { op, expr: Box::new(e) }, span: self.since(start) })
    }

    fn try_follows(&self) -> bool {
        // Called with the current token being `?`; look at the token after it (ADR-0003).
        matches!(
            self.peek_at(1),
            Tok::RParen
                | Tok::RBracket
                | Tok::RBrace
                | Tok::Comma
                | Tok::Semi
                | Tok::Dot
                | Tok::Question
                | Tok::Colon
                | Tok::Eof
        )
    }

    fn postfix(&mut self) -> PResult<Expr> {
        let mut e = self.primary()?;
        let start = e.span.start;
        loop {
            match self.peek() {
                Tok::LParen => {
                    self.bump();
                    let mut args = Vec::new();
                    while !self.at(&Tok::RParen) {
                        args.push(self.expr()?);
                        if !self.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    self.expect(&Tok::RParen, "`)` or `,` in argument list")?;
                    e = Expr { kind: ExprKind::Call { callee: Box::new(e), args }, span: self.since(start) };
                }
                Tok::Dot => {
                    self.bump();
                    let name = self.ident("a member name after `.`")?;
                    e = Expr { kind: ExprKind::Member { base: Box::new(e), name }, span: self.since(start) };
                }
                Tok::LBracket => {
                    self.bump();
                    let index = self.expr()?;
                    self.expect(&Tok::RBracket, "`]` after index")?;
                    e = Expr {
                        kind: ExprKind::Index { base: Box::new(e), index: Box::new(index) },
                        span: self.since(start),
                    };
                }
                Tok::Question if self.try_follows() => {
                    self.bump();
                    e = Expr { kind: ExprKind::Try(Box::new(e)), span: self.since(start) };
                }
                _ => break,
            }
        }
        Ok(e)
    }

    fn primary(&mut self) -> PResult<Expr> {
        let start = self.span().start;
        match self.peek().clone() {
            Tok::Int(n) => {
                self.bump();
                Ok(Expr { kind: ExprKind::Int(n), span: self.since(start) })
            }
            Tok::Str(s) => {
                self.bump();
                Ok(Expr { kind: ExprKind::Str(s), span: self.since(start) })
            }
            Tok::True | Tok::False => {
                let v = self.at(&Tok::True);
                self.bump();
                Ok(Expr { kind: ExprKind::Bool(v), span: self.since(start) })
            }
            Tok::Ident(_) => {
                let id = self.ident("an identifier")?;
                if self.at(&Tok::LBrace) {
                    return self.record_lit(id, start);
                }
                Ok(Expr { span: id.span, kind: ExprKind::Ident(id) })
            }
            Tok::LParen => {
                self.bump();
                let mut e = self.expr()?;
                self.expect(&Tok::RParen, "`)`")?;
                e.span = self.since(start);
                Ok(e)
            }
            Tok::LBracket => {
                self.bump();
                let mut items = Vec::new();
                while !self.at(&Tok::RBracket) {
                    items.push(self.expr()?);
                    if !self.eat(&Tok::Comma) {
                        break;
                    }
                }
                self.expect(&Tok::RBracket, "`]` or `,` in array literal")?;
                Ok(Expr { kind: ExprKind::Array(items), span: self.since(start) })
            }
            Tok::Match => self.match_expr(),
            _ => Err(self.unexpected("an expression")),
        }
    }

    fn record_lit(&mut self, name: Ident, start: u32) -> PResult<Expr> {
        self.expect(&Tok::LBrace, "`{`")?;
        let mut spread = None;
        if self.eat(&Tok::Ellipsis) {
            spread = Some(Box::new(self.expr()?));
            if !self.eat(&Tok::Comma) && !self.at(&Tok::RBrace) {
                return Err(self.unexpected("`,` or `}` after spread expression"));
            }
        }
        let mut fields = Vec::new();
        while !self.at(&Tok::RBrace) {
            if self.at(&Tok::Ellipsis) {
                return Err(self.err_here("spread `...` must come first in a record literal"));
            }
            let fs = self.span().start;
            let fname = self.ident("a field name")?;
            self.expect(&Tok::Colon, "`:` after field name")?;
            let value = self.expr()?;
            fields.push(FieldInit { name: fname, value, span: self.since(fs) });
            if !self.eat(&Tok::Comma) {
                break;
            }
        }
        self.expect(&Tok::RBrace, "`}` or `,` in record literal")?;
        Ok(Expr { kind: ExprKind::Record { name, spread, fields }, span: self.since(start) })
    }

    fn match_expr(&mut self) -> PResult<Expr> {
        let start = self.span().start;
        self.expect(&Tok::Match, "`match`")?;
        let scrutinee = self.paren_expr("match")?;
        self.expect(&Tok::LBrace, "`{` after `match (...)`")?;
        let mut arms = Vec::new();
        while !self.at(&Tok::RBrace) {
            let as_ = self.span().start;
            let pattern = self.pattern()?;
            self.expect(&Tok::FatArrow, "`=>` after pattern")?;
            let (body, is_block) = if self.at(&Tok::LBrace) {
                (ArmBody::Block(self.block()?), true)
            } else {
                (ArmBody::Expr(self.expr()?), false)
            };
            arms.push(MatchArm { pattern, body, span: self.since(as_) });
            if self.eat(&Tok::Comma) {
                continue;
            }
            if self.at(&Tok::RBrace) || is_block {
                continue;
            }
            return Err(self.unexpected("`,` or `}` after match arm"));
        }
        self.expect(&Tok::RBrace, "`}`")?;
        Ok(Expr { kind: ExprKind::Match { scrutinee: Box::new(scrutinee), arms }, span: self.since(start) })
    }

    fn pattern(&mut self) -> PResult<Pattern> {
        let start = self.span().start;
        let kind = match self.peek().clone() {
            Tok::Int(n) => {
                self.bump();
                PatternKind::Int(n)
            }
            Tok::Minus => {
                self.bump();
                match self.peek().clone() {
                    Tok::Int(n) => {
                        self.bump();
                        PatternKind::Int(-n)
                    }
                    _ => return Err(self.unexpected("an integer after `-` in pattern")),
                }
            }
            Tok::Str(s) => {
                self.bump();
                PatternKind::Str(s)
            }
            Tok::True => {
                self.bump();
                PatternKind::Bool(true)
            }
            Tok::False => {
                self.bump();
                PatternKind::Bool(false)
            }
            Tok::Ident(_) => {
                let id = self.ident("a pattern")?;
                if id.name == "_" {
                    PatternKind::Wildcard
                } else if self.eat(&Tok::LParen) {
                    let mut args = Vec::new();
                    while !self.at(&Tok::RParen) {
                        args.push(self.pattern()?);
                        if !self.eat(&Tok::Comma) {
                            break;
                        }
                    }
                    self.expect(&Tok::RParen, "`)` or `,` in pattern")?;
                    PatternKind::Variant { name: id, args }
                } else {
                    PatternKind::Ident(id)
                }
            }
            _ => return Err(self.unexpected("a pattern")),
        };
        Ok(Pattern { kind, span: self.since(start) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ok(src: &str) -> Module {
        match parse(FileId(0), src) {
            Ok(m) => m,
            Err(d) => panic!("parse failed: {:?}", d),
        }
    }
    fn parse_err(src: &str) -> Diagnostic {
        parse(FileId(0), src).unwrap_err().remove(0)
    }
    /// Parse an expression by wrapping it in `const _x = <e>;` at statement level.
    fn expr(src: &str) -> Expr {
        let m = parse_ok(&format!("function f() {{ const q = {}; }}", src));
        let Item::Function(f) = &m.items[0] else { panic!() };
        let StmtKind::Let { init, .. } = &f.body.stmts[0].kind else { panic!() };
        init.clone()
    }
    fn stmts(src: &str) -> Vec<Stmt> {
        let m = parse_ok(&format!("function f() {{ {} }}", src));
        let Item::Function(f) = &m.items[0] else { panic!() };
        f.body.stmts.clone()
    }
    /// S-expression rendering for precedence checks.
    fn sx(e: &Expr) -> String {
        match &e.kind {
            ExprKind::Int(n) => n.to_string(),
            ExprKind::Str(s) => format!("{:?}", s),
            ExprKind::Bool(b) => b.to_string(),
            ExprKind::Ident(i) => i.name.clone(),
            ExprKind::Unary { op, expr } => {
                format!("({} {})", if *op == UnaryOp::Not { "!" } else { "neg" }, sx(expr))
            }
            ExprKind::Binary { op, lhs, rhs } => {
                let o = match op {
                    BinaryOp::Add => "+",
                    BinaryOp::Sub => "-",
                    BinaryOp::Mul => "*",
                    BinaryOp::Div => "/",
                    BinaryOp::Rem => "%",
                    BinaryOp::Eq => "==",
                    BinaryOp::Ne => "!=",
                    BinaryOp::Lt => "<",
                    BinaryOp::Le => "<=",
                    BinaryOp::Gt => ">",
                    BinaryOp::Ge => ">=",
                    BinaryOp::And => "&&",
                    BinaryOp::Or => "||",
                };
                format!("({} {} {})", o, sx(lhs), sx(rhs))
            }
            ExprKind::Call { callee, args } => {
                let a: Vec<_> = args.iter().map(sx).collect();
                format!("(call {} [{}])", sx(callee), a.join(" "))
            }
            ExprKind::Member { base, name } => format!("(. {} {})", sx(base), name.name),
            ExprKind::Index { base, index } => format!("(idx {} {})", sx(base), sx(index)),
            ExprKind::Try(e) => format!("(try {})", sx(e)),
            ExprKind::Cond { cond, then, els } => format!("(? {} {} {})", sx(cond), sx(then), sx(els)),
            ExprKind::Array(v) => format!("[{}]", v.iter().map(sx).collect::<Vec<_>>().join(" ")),
            ExprKind::Record { name, spread, fields } => {
                let mut s = format!("(rec {}", name.name);
                if let Some(sp) = spread {
                    s += &format!(" ...{}", sx(sp));
                }
                for f in fields {
                    s += &format!(" {}:{}", f.name.name, sx(&f.value));
                }
                s + ")"
            }
            ExprKind::Match { scrutinee, arms } => format!("(match {} {})", sx(scrutinee), arms.len()),
        }
    }
    fn x(src: &str) -> String {
        sx(&expr(src))
    }

    #[test]
    fn literals() {
        assert_eq!(x("1"), "1");
        assert_eq!(x("0xFF"), "255");
        assert_eq!(x("\"hi\""), "\"hi\"");
        assert_eq!(x("true"), "true");
        assert_eq!(x("false"), "false");
        assert_eq!(x("[]"), "[]");
        assert_eq!(x("[1, 2, 3,]"), "[1 2 3]");
        assert_eq!(x("(1)"), "1");
        assert_eq!(x("-5"), "(neg 5)");
    }

    #[test]
    fn precedence() {
        assert_eq!(x("1 + 2 * 3"), "(+ 1 (* 2 3))");
        assert_eq!(x("1 * 2 + 3"), "(+ (* 1 2) 3)");
        assert_eq!(x("1 - 2 - 3"), "(- (- 1 2) 3)");
        assert_eq!(x("a / b % c"), "(% (/ a b) c)");
        assert_eq!(x("a + b < c"), "(< (+ a b) c)");
        assert_eq!(x("a < b == c < d"), "(== (< a b) (< c d))");
        assert_eq!(x("a == b && c != d"), "(&& (== a b) (!= c d))");
        assert_eq!(x("a || b && c"), "(|| a (&& b c))");
        assert_eq!(x("a && b || c"), "(|| (&& a b) c)");
        assert_eq!(x("a <= b >= c"), "(>= (<= a b) c)");
        assert_eq!(x("!a && b"), "(&& (! a) b)");
        assert_eq!(x("-a * b"), "(* (neg a) b)");
        assert_eq!(x("-a.b"), "(neg (. a b))");
        assert_eq!(x("!!a"), "(! (! a))");
        assert_eq!(x("(1 + 2) * 3"), "(* (+ 1 2) 3)");
        assert_eq!(x("a - -1"), "(- a (neg 1))");
    }

    #[test]
    fn postfix_forms() {
        assert_eq!(x("f(a, b,)"), "(call f [a b])");
        assert_eq!(x("f()"), "(call f [])");
        assert_eq!(x("a.b.c"), "(. (. a b) c)");
        assert_eq!(x("a.m(1).n"), "(. (call (. a m) [1]) n)");
        assert_eq!(x("a[0][1]"), "(idx (idx a 0) 1)");
        assert_eq!(x("xs[i + 1].f"), "(. (idx xs (+ i 1)) f)");
        assert_eq!(x("a.b(c)[d]"), "(idx (call (. a b) [c]) d)");
    }

    #[test]
    fn try_disambiguation() {
        assert_eq!(x("f()?"), "(try (call f []))");
        assert_eq!(x("g(a?, b)"), "(call g [(try a) b])");
        assert_eq!(x("c ? 1 : 2"), "(? c 1 2)");
        assert_eq!(x("a?.b"), "(. (try a) b)");
        assert_eq!(x("x ? y? : z"), "(? x (try y) z)");
        assert_eq!(x("[a?]"), "[(try a)]");
        assert_eq!(x("a??"), "(try (try a))");
        assert_eq!(x("a ? b : c ? d : e"), "(? a b (? c d e))");
        assert_eq!(x("a ? b ? c : d : e"), "(? a (? b c d) e)");
        assert_eq!(x("a == b ? 1 : 2"), "(? (== a b) 1 2)");
        assert_eq!(x("a || b ? -1 : 2"), "(? (|| a b) (neg 1) 2)");
        assert_eq!(x("c ? f(x)? : g()"), "(? c (try (call f [x])) (call g []))");
        assert_eq!(x("c ? [1] : [2]"), "(? c [1] [2])");
        assert_eq!(x("c ? (a)?.b : 0"), "(? c (. (try a) b) 0)");
        assert_eq!(x("c ? a : b"), "(? c a b)");
        assert_eq!(x("c ? !a : b"), "(? c (! a) b)");
        assert_eq!(x("c ? \"s\" : \"t\""), "(? c \"s\" \"t\")");
        assert_eq!(x("f(c ? 1 : 2)"), "(call f [(? c 1 2)])");
    }

    #[test]
    fn try_statement_and_return() {
        let s = stmts("f()?; return r?; const v = g()?;");
        assert!(matches!(&s[0].kind, StmtKind::Expr(e) if matches!(e.kind, ExprKind::Try(_))));
        assert!(matches!(&s[1].kind, StmtKind::Return(Some(e)) if matches!(e.kind, ExprKind::Try(_))));
        assert!(matches!(&s[2].kind, StmtKind::Let { init, .. } if matches!(init.kind, ExprKind::Try(_))));
    }

    #[test]
    fn try_before_binary_op_is_conditional_start() {
        // `a? + 1` is not supported (ADR-0003): `?` starts a conditional and parsing fails.
        let d = parse_err("function f() { const q = a? + 1; }");
        assert_eq!(d.code, "E0200");
    }

    #[test]
    fn record_literals() {
        assert_eq!(x("Point { x: 1, y: 2 }"), "(rec Point x:1 y:2)");
        assert_eq!(x("Point { x: 1, y: 2, }"), "(rec Point x:1 y:2)");
        assert_eq!(x("Point { ...p, y: 3 }"), "(rec Point ...p y:3)");
        assert_eq!(x("Point { ...p }"), "(rec Point ...p)");
        assert_eq!(x("Point { ...p, }"), "(rec Point ...p)");
        assert_eq!(x("E {}"), "(rec E)");
        assert_eq!(x("A { b: B { c: 1 } }"), "(rec A b:(rec B c:1))");
        assert_eq!(x("Point { x: f(1), y: a ? 1 : 2 }"), "(rec Point x:(call f [1]) y:(? a 1 2))");
        assert_eq!(parse_err("function f() { const q = P { x: 1, ...p }; }").code, "E0200");
    }

    #[test]
    fn blocks_are_not_records() {
        let s = stmts("{ x; } if (a) { b; } while (c) { d; } for (const i of xs) { }");
        assert!(matches!(s[0].kind, StmtKind::Block(_)));
        assert!(matches!(s[1].kind, StmtKind::If { .. }));
        assert!(matches!(s[2].kind, StmtKind::While { .. }));
        assert!(matches!(s[3].kind, StmtKind::ForOf { .. }));
        // `match (x) {` the `{` follows `)`.
        assert_eq!(x("match (x) { _ => 1 }"), "(match x 1)");
        // identifier scrutinee in parens followed by block
        assert_eq!(x("match (p) { A => 1, B => 2 }"), "(match p 2)");
    }

    #[test]
    fn match_arms() {
        let e = expr(
            "match (s) { Circle(r) => r * r, Rect(w, _) => { return 1; } Empty => 0, _ => { return 2; }, }",
        );
        let ExprKind::Match { arms, .. } = e.kind else { panic!() };
        assert_eq!(arms.len(), 4);
        assert!(matches!(&arms[0].pattern.kind, PatternKind::Variant { name, args } if name.name == "Circle" && args.len() == 1));
        assert!(matches!(&arms[0].body, ArmBody::Expr(_)));
        let PatternKind::Variant { args, .. } = &arms[1].pattern.kind else { panic!() };
        assert!(matches!(args[0].kind, PatternKind::Ident(_)));
        assert!(matches!(args[1].kind, PatternKind::Wildcard));
        assert!(matches!(&arms[1].body, ArmBody::Block(_)));
        assert!(matches!(&arms[2].pattern.kind, PatternKind::Ident(i) if i.name == "Empty"));
        assert!(matches!(arms[3].pattern.kind, PatternKind::Wildcard));
        assert!(matches!(&arms[3].body, ArmBody::Block(_)));
    }

    #[test]
    fn match_literal_patterns() {
        let e = expr("match (n) { 0 => 1, -3 => 2, 0x10 => 3, \"a\" => 4, true => 5, false => 6, _ => 7 }");
        let ExprKind::Match { arms, .. } = e.kind else { panic!() };
        let k: Vec<_> = arms.iter().map(|a| a.pattern.kind.clone()).collect();
        assert!(matches!(k[0], PatternKind::Int(0)));
        assert!(matches!(k[1], PatternKind::Int(-3)));
        assert!(matches!(k[2], PatternKind::Int(16)));
        assert!(matches!(&k[3], PatternKind::Str(s) if s == "a"));
        assert!(matches!(k[4], PatternKind::Bool(true)));
        assert!(matches!(k[5], PatternKind::Bool(false)));
        assert!(matches!(k[6], PatternKind::Wildcard));
    }

    #[test]
    fn match_statement_without_semicolon() {
        let s = stmts("match (o) { Some(v) => { f(v); }, None => { return; }, } g();");
        assert_eq!(s.len(), 2);
        assert!(matches!(&s[0].kind, StmtKind::Expr(e) if matches!(e.kind, ExprKind::Match { .. })));
        let s = stmts("match (o) { _ => 1 };");
        assert_eq!(s.len(), 1);
    }

    #[test]
    fn match_arm_missing_comma() {
        let d = parse_err("function f() { const q = match (x) { A => 1 B => 2 }; }");
        assert_eq!(d.code, "E0200");
    }

    #[test]
    fn statements() {
        let s = stmts(
            "const a = 1; let b: int = 2; let c: int[] = []; b = 3; b += 1; b -= 1; b *= 2; b /= 2; b %= 2; \
             xs[0].f = 1; return; break; continue;",
        );
        assert!(matches!(&s[0].kind, StmtKind::Let { mutable: false, ty: None, .. }));
        assert!(matches!(&s[1].kind, StmtKind::Let { mutable: true, ty: Some(_), .. }));
        let ops: Vec<_> = s[3..9]
            .iter()
            .map(|s| match &s.kind {
                StmtKind::Assign { op, .. } => *op,
                _ => panic!(),
            })
            .collect();
        assert_eq!(
            ops,
            vec![AssignOp::Assign, AssignOp::Add, AssignOp::Sub, AssignOp::Mul, AssignOp::Div, AssignOp::Rem]
        );
        assert!(matches!(&s[9].kind, StmtKind::Assign { target, .. } if matches!(target.kind, ExprKind::Member { .. })));
        assert!(matches!(s[10].kind, StmtKind::Return(None)));
        assert!(matches!(s[11].kind, StmtKind::Break));
        assert!(matches!(s[12].kind, StmtKind::Continue));
    }

    #[test]
    fn if_else_chain() {
        let s = stmts("if (a) { } else if (b) { } else { }");
        let StmtKind::If { els: Some(e1), .. } = &s[0].kind else { panic!() };
        let StmtKind::If { els: Some(e2), .. } = &e1.kind else { panic!() };
        assert!(matches!(e2.kind, StmtKind::Block(_)));
        let s = stmts("if (a) { return 1; }");
        assert!(matches!(&s[0].kind, StmtKind::If { els: None, .. }));
    }

    #[test]
    fn loops_and_nested_blocks() {
        let s = stmts("while (i < 3) { i += 1; { let z = 1; } } for (const x of xs.slice(0, 2)) { f(x); }");
        let StmtKind::While { body, .. } = &s[0].kind else { panic!() };
        assert!(matches!(body.stmts[1].kind, StmtKind::Block(_)));
        let StmtKind::ForOf { name, iter, .. } = &s[1].kind else { panic!() };
        assert_eq!(name.name, "x");
        assert!(matches!(iter.kind, ExprKind::Call { .. }));
    }

    #[test]
    fn missing_semicolon_message() {
        let d = parse_err("function f() { g() h(); }");
        assert_eq!(d.code, "E0200");
        assert!(d.message.contains("expected `;` after expression"), "{}", d.message);
        assert!(parse_err("function f() { const x = 1 }").message.contains("`;`"));
        assert!(parse_err("function f() { const x; }").message.contains("initializer"));
        assert!(parse_err("function f() { if (a) return 1; }").message.contains("`{`"));
    }

    #[test]
    fn unclosed_block_and_eof() {
        assert_eq!(parse_err("function f() { ").code, "E0200");
        assert_eq!(parse_err("function f(").code, "E0200");
        assert_eq!(parse_err("foo").code, "E0200");
        assert_eq!(parse_err("let x = 1;").code, "E0200");
    }

    #[test]
    fn var_is_e0201() {
        let d = parse_err("function f() { var x = 1; }");
        assert_eq!(d.code, "E0201");
        assert!(d.message.contains("const") && d.message.contains("let"));
        assert_eq!(parse_err("var x = 1;").code, "E0201");
        assert_eq!(parse_err("function f() { for (var i of xs) { } }").code, "E0201");
    }

    #[test]
    fn reserved_words_are_e0200() {
        assert_eq!(parse_err("function f() { const class = 1; }").code, "E0200");
        assert_eq!(parse_err("function f() { const x = this; }").code, "E0200");
        assert_eq!(parse_err("function new() { }").code, "E0200");
        assert_eq!(parse_err("function f() { return null; }").code, "E0200");
    }

    #[test]
    fn lexer_errors_surface() {
        assert_eq!(parse_err("function f() { const x = @; }").code, "E0100");
    }

    #[test]
    fn function_decls() {
        let m = parse_ok("export function f(x: int, s: string[],): Result<int, string> { return Ok(1); } function g() { }");
        let Item::Function(f) = &m.items[0] else { panic!() };
        assert!(f.exported);
        assert_eq!(f.params.len(), 2);
        assert!(matches!(&f.params[1].ty.kind, TypeExprKind::Array(_)));
        let Some(TypeExpr { kind: TypeExprKind::Named { name, args }, .. }) = &f.ret else { panic!() };
        assert_eq!(name.name, "Result");
        assert_eq!(args.len(), 2);
        let Item::Function(g) = &m.items[1] else { panic!() };
        assert!(!g.exported && g.ret.is_none() && g.params.is_empty());
    }

    #[test]
    fn generic_params_and_args() {
        let m = parse_ok("function id<T, U>(x: T): T { return x; } type Box<T> = { v: T; };");
        let Item::Function(f) = &m.items[0] else { panic!() };
        assert_eq!(f.type_params.len(), 2);
        let Item::Type(t) = &m.items[1] else { panic!() };
        assert_eq!(t.type_params.len(), 1);
        let m = parse_ok("type A = Result<Option<int>, string[]>[]; type B = Option<Option<int>>;");
        let Item::Type(t) = &m.items[0] else { panic!() };
        let TypeDeclBody::Alias(TypeExpr { kind: TypeExprKind::Array(inner), .. }) = &t.body else { panic!() };
        let TypeExprKind::Named { args, .. } = &inner.kind else { panic!() };
        assert_eq!(args.len(), 2);
        assert!(matches!(&args[1].kind, TypeExprKind::Array(_)));
        let m = parse_ok("function f(x: Result<int[], Option<string>>): void { }");
        assert_eq!(m.items.len(), 1);
    }

    #[test]
    fn type_decls() {
        let m = parse_ok(
            "export type P = { x: int; y: int; };\n\
             type E = { };\n\
             type S = Circle(int) | Rect(int, int) | Empty;\n\
             type T = A | B;\n\
             type One = Wrap(int);\n\
             type N = string;\n\
             type L = int[];\n\
             type O = Option<int>;\n\
             type G<T> = Some(T) | None;",
        );
        let Item::Type(p) = &m.items[0] else { panic!() };
        assert!(p.exported);
        assert!(matches!(&p.body, TypeDeclBody::Record(f) if f.len() == 2));
        let Item::Type(e) = &m.items[1] else { panic!() };
        assert!(matches!(&e.body, TypeDeclBody::Record(f) if f.is_empty()));
        let Item::Type(s) = &m.items[2] else { panic!() };
        let TypeDeclBody::Union(v) = &s.body else { panic!() };
        assert_eq!(v.len(), 3);
        assert_eq!(v[0].payload.len(), 1);
        assert_eq!(v[1].payload.len(), 2);
        assert_eq!(v[2].payload.len(), 0);
        assert_eq!(v[2].name.name, "Empty");
        let Item::Type(t) = &m.items[3] else { panic!() };
        assert!(matches!(&t.body, TypeDeclBody::Union(v) if v.len() == 2));
        let Item::Type(o) = &m.items[4] else { panic!() };
        assert!(matches!(&o.body, TypeDeclBody::Union(v) if v.len() == 1));
        for i in 5..8 {
            let Item::Type(a) = &m.items[i] else { panic!() };
            assert!(matches!(a.body, TypeDeclBody::Alias(_)), "item {}", i);
        }
        let Item::Type(g) = &m.items[8] else { panic!() };
        assert_eq!(g.type_params.len(), 1);
        assert!(matches!(g.body, TypeDeclBody::Union(_)));
    }

    #[test]
    fn leading_pipe_not_allowed() {
        assert_eq!(parse_err("type S = | A | B;").code, "E0200");
    }

    #[test]
    fn bad_union_member() {
        assert_eq!(parse_err("type S = int[] | B;").code, "E0200");
    }

    #[test]
    fn import_export_forms() {
        let m = parse_ok(
            "import { a, B } from \"./x\";\n\
             import { } from \"std:fs\";\n\
             export { f, Point, } from \"./other\";\n\
             export const MAX: int = 10;\n\
             const MIN = -1;\n\
             export type T = int;\n\
             export function g() { }",
        );
        let Item::Import(i) = &m.items[0] else { panic!() };
        assert_eq!(i.path, "./x");
        assert_eq!(i.names.len(), 2);
        assert_eq!(i.path_span.end - i.path_span.start, 5);
        let Item::Import(i2) = &m.items[1] else { panic!() };
        assert!(i2.names.is_empty());
        let Item::ReExport(r) = &m.items[2] else { panic!() };
        assert_eq!(r.names.len(), 2);
        assert_eq!(r.path, "./other");
        let Item::Const(c) = &m.items[3] else { panic!() };
        assert!(c.exported && c.ty.is_some());
        let Item::Const(c2) = &m.items[4] else { panic!() };
        assert!(!c2.exported && c2.ty.is_none());
        assert!(matches!(&m.items[5], Item::Type(t) if t.exported));
        assert!(matches!(&m.items[6], Item::Function(f) if f.exported));
        assert_eq!(parse_err("export let x = 1;").code, "E0200");
        assert_eq!(parse_err("import { a } from x;").code, "E0200");
        assert_eq!(parse_err("import { a } \"./x\";").code, "E0200");
    }

    #[test]
    fn spans_are_accurate() {
        let src = "function f(): int {\n  return 1 + 2;\n}";
        let m = parse_ok(src);
        let Item::Function(f) = &m.items[0] else { panic!() };
        assert_eq!((f.span.start as usize, f.span.end as usize), (0, src.len()));
        let st = &f.body.stmts[0];
        assert_eq!(&src[st.span.start as usize..st.span.end as usize], "return 1 + 2;");
        let StmtKind::Return(Some(e)) = &st.kind else { panic!() };
        assert_eq!(&src[e.span.start as usize..e.span.end as usize], "1 + 2");
        assert_eq!(&src[f.body.span.start as usize..f.body.span.end as usize], &src[18..]);
        let src2 = "const x = (a).b(c)?;";
        let m = parse_ok(&format!("function f() {{ {} }}", src2));
        let Item::Function(f) = &m.items[0] else { panic!() };
        let StmtKind::Let { init, .. } = &f.body.stmts[0].kind else { panic!() };
        let full = format!("function f() {{ {} }}", src2);
        assert_eq!(&full[init.span.start as usize..init.span.end as usize], "(a).b(c)?");
        let src3 = "type S = A(int) | B;";
        let m = parse_ok(src3);
        let Item::Type(t) = &m.items[0] else { panic!() };
        assert_eq!(&src3[t.span.start as usize..t.span.end as usize], src3);
        let TypeDeclBody::Union(v) = &t.body else { panic!() };
        assert_eq!(&src3[v[0].span.start as usize..v[0].span.end as usize], "A(int)");
    }

    #[test]
    fn sample_files_parse() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/parse");
        let mut n = 0;
        for e in std::fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            if p.extension().map_or(false, |x| x == "or") {
                let text = std::fs::read_to_string(&p).unwrap();
                let expect_err = p.file_name().unwrap().to_string_lossy().starts_with("bad_");
                let r = parse(FileId(0), &text);
                assert_eq!(r.is_err(), expect_err, "{}: {:?}", p.display(), r.err());
                n += 1;
            }
        }
        assert!(n >= 3);
    }
}
