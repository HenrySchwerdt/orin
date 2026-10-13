//! Canonical AST dump for differential parser testing. Must match compiler/tests/astdump.or
//! byte for byte (format documented there).

use crate::ast::*;

pub fn dump(m: &Module) -> String {
    let lines: Vec<String> = m.items.iter().map(item).collect();
    let mut s = lines.join("\n");
    s.push('\n');
    s
}

fn quote(s: &str) -> String {
    let mut o = String::from("\"");
    for &c in s.as_bytes() {
        match c {
            b'"' => o.push_str("\\\""),
            b'\\' => o.push_str("\\\\"),
            b'\n' => o.push_str("\\n"),
            b'\t' => o.push_str("\\t"),
            b'\r' => o.push_str("\\r"),
            c if c < 32 || c > 126 => o.push_str(&format!("\\x{:02x}", c)),
            c => o.push(c as char),
        }
    }
    o.push('"');
    o
}

fn sp(s: crate::span::Span) -> String {
    format!("@{}-{}", s.start, s.end)
}

fn exp(b: bool) -> &'static str {
    if b {
        "export"
    } else {
        "local"
    }
}

fn names(ids: &[Ident]) -> String {
    ids.iter().map(|i| format!(" {}", i.name)).collect()
}

fn tail(xs: &[String]) -> String {
    xs.iter().map(|x| format!(" {}", x)).collect()
}

fn item(it: &Item) -> String {
    match it {
        Item::Import(d) => format!("(import {}{})", quote(&d.path), names(&d.names)),
        Item::ReExport(d) => format!("(reexport {}{})", quote(&d.path), names(&d.names)),
        Item::Function(f) => {
            let ps: Vec<String> = f.params.iter().map(|p| format!("(param {} {})", p.name.name, ty(&p.ty))).collect();
            format!(
                "(fn {} {} (tparams{}) (params{}) {} {})",
                exp(f.exported),
                f.name.name,
                names(&f.type_params),
                tail(&ps),
                opt_ty(&f.ret),
                block(&f.body, "")
            )
        }
        Item::Type(t) => format!(
            "(type {} {} (tparams{}) {})",
            exp(t.exported),
            t.name.name,
            names(&t.type_params),
            type_body(&t.body)
        ),
        Item::Const(c) => format!("(const {} {} {} {})", exp(c.exported), c.name.name, opt_ty(&c.ty), expr(&c.value, "")),
    }
}

fn type_body(b: &TypeDeclBody) -> String {
    match b {
        TypeDeclBody::Alias(t) => format!("(dalias {})", ty(t)),
        TypeDeclBody::Record(fs) => {
            let p: Vec<String> = fs.iter().map(|f| format!("(field {} {})", f.name.name, ty(&f.ty))).collect();
            format!("(drecord{})", tail(&p))
        }
        TypeDeclBody::Union(vs) => {
            let p: Vec<String> = vs
                .iter()
                .map(|v| {
                    let t: Vec<String> = v.payload.iter().map(ty).collect();
                    format!("(variant {}{})", v.name.name, tail(&t))
                })
                .collect();
            format!("(dunion{})", tail(&p))
        }
    }
}

fn ty(t: &TypeExpr) -> String {
    match &t.kind {
        TypeExprKind::Named { name, args } => {
            if args.is_empty() {
                name.name.clone()
            } else {
                let a: Vec<String> = args.iter().map(ty).collect();
                format!("(app {} {})", name.name, a.join(" "))
            }
        }
        TypeExprKind::Array(e) => format!("(array {})", ty(e)),
    }
}

fn opt_ty(o: &Option<TypeExpr>) -> String {
    match o {
        Some(t) => ty(t),
        None => "-".to_string(),
    }
}

fn block(b: &Block, ind: &str) -> String {
    let ind2 = format!("{}  ", ind);
    let mut s = String::from("(block");
    for st in &b.stmts {
        s.push('\n');
        s.push_str(&ind2);
        s.push_str(&stmt(st, &ind2));
    }
    s.push(')');
    s
}

fn stmt(s: &Stmt, ind: &str) -> String {
    let p = sp(s.span);
    match &s.kind {
        StmtKind::Let { mutable, name, ty: t, init } => format!(
            "(let{} {} {} {} {})",
            p,
            if *mutable { "let" } else { "const" },
            name.name,
            opt_ty(t),
            expr(init, ind)
        ),
        StmtKind::Assign { target, op, value } => {
            let o = match op {
                AssignOp::Assign => "=",
                AssignOp::Add => "+=",
                AssignOp::Sub => "-=",
                AssignOp::Mul => "*=",
                AssignOp::Div => "/=",
                AssignOp::Rem => "%=",
            };
            format!("(assign{} {} {} {})", p, o, expr(target, ind), expr(value, ind))
        }
        StmtKind::Expr(e) => format!("(expr{} {})", p, expr(e, ind)),
        StmtKind::Return(Some(e)) => format!("(return{} {})", p, expr(e, ind)),
        StmtKind::Return(None) => format!("(return{})", p),
        StmtKind::If { cond, then, els } => {
            let e = match els {
                Some(s) => stmt(s, ind),
                None => "-".to_string(),
            };
            format!("(if{} {} {} {})", p, expr(cond, ind), block(then, ind), e)
        }
        StmtKind::While { cond, body } => format!("(while{} {} {})", p, expr(cond, ind), block(body, ind)),
        StmtKind::ForOf { name, iter, body } => {
            format!("(for{} {} {} {})", p, name.name, expr(iter, ind), block(body, ind))
        }
        StmtKind::Break => format!("(break{})", p),
        StmtKind::Continue => format!("(continue{})", p),
        StmtKind::Block(b) => format!("(sblock{} {})", p, block(b, ind)),
    }
}

fn exprs(xs: &[Expr], ind: &str) -> String {
    xs.iter().map(|x| format!(" {}", expr(x, ind))).collect()
}

fn expr(e: &Expr, ind: &str) -> String {
    let p = sp(e.span);
    match &e.kind {
        ExprKind::Int(v) => format!("(int{} {})", p, v),
        ExprKind::Str(s) => format!("(str{} {})", p, quote(s)),
        ExprKind::Bool(b) => format!("(bool{} {})", p, b),
        ExprKind::Ident(i) => format!("(ident{} {})", p, i.name),
        ExprKind::Unary { op, expr: x } => {
            format!("(unary{} {} {})", p, if *op == UnaryOp::Not { "!" } else { "-" }, expr(x, ind))
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
            format!("(binary{} {} {} {})", p, o, expr(lhs, ind), expr(rhs, ind))
        }
        ExprKind::Call { callee, args } => format!("(call{} {}{})", p, expr(callee, ind), exprs(args, ind)),
        ExprKind::Member { base, name } => format!("(member{} {} {})", p, expr(base, ind), name.name),
        ExprKind::Index { base, index } => format!("(index{} {} {})", p, expr(base, ind), expr(index, ind)),
        ExprKind::Try(x) => format!("(try{} {})", p, expr(x, ind)),
        ExprKind::Cond { cond, then, els } => {
            format!("(cond{} {} {} {})", p, expr(cond, ind), expr(then, ind), expr(els, ind))
        }
        ExprKind::Array(xs) => format!("(arr{}{})", p, exprs(xs, ind)),
        ExprKind::Record { name, spread, fields } => {
            let sp_s = match spread {
                Some(s) => expr(s, ind),
                None => "-".to_string(),
            };
            let f: Vec<String> =
                fields.iter().map(|f| format!("(field {} {})", f.name.name, expr(&f.value, ind))).collect();
            format!("(record{} {} {}{})", p, name.name, sp_s, tail(&f))
        }
        ExprKind::Match { scrutinee, arms } => {
            let ind2 = format!("{}  ", ind);
            let mut s = format!("(match{} {}", p, expr(scrutinee, ind));
            for a in arms {
                let body = match &a.body {
                    ArmBody::Expr(e) => expr(e, &ind2),
                    ArmBody::Block(b) => block(b, &ind2),
                };
                s.push('\n');
                s.push_str(&ind2);
                s.push_str(&format!("(arm {} {})", pat(&a.pattern), body));
            }
            s.push(')');
            s
        }
    }
}

fn pat(p: &Pattern) -> String {
    match &p.kind {
        PatternKind::Wildcard => "_".to_string(),
        PatternKind::Ident(i) => format!("(pident {})", i.name),
        PatternKind::Variant { name, args } => {
            let a: Vec<String> = args.iter().map(pat).collect();
            format!("(pvariant {}{})", name.name, tail(&a))
        }
        PatternKind::Int(v) => format!("(pint {})", v),
        PatternKind::Str(s) => format!("(pstr {})", quote(s)),
        PatternKind::Bool(b) => format!("(pbool {})", b),
    }
}
