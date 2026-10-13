//! Lexer. Owned by the parser worker. Internal interface (used only by parser.rs).
//!
//! `>>` is never produced as a single token, so nested generics (`Result<A, B[]>`) need no
//! special handling. `>=` is lexed as one token.

use crate::diag::Diagnostic;
use crate::span::{FileId, Span};

#[derive(Clone, Debug, PartialEq)]
pub enum Tok {
    Ident(String),
    Int(i64),
    Str(String),
    /// Reserved word that may not be used (`class`, `new`, ...). Parser reports E0200.
    Reserved(String),
    /// `var` (parser reports E0201).
    Var,
    // keywords
    Const,
    Let,
    Function,
    Return,
    If,
    Else,
    While,
    For,
    Of,
    Break,
    Continue,
    Type,
    Import,
    Export,
    From,
    Match,
    True,
    False,
    // punctuation
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Semi,
    Colon,
    Dot,
    Ellipsis,
    Question,
    FatArrow,
    Eq,
    PlusEq,
    MinusEq,
    StarEq,
    SlashEq,
    PercentEq,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqEq,
    NotEq,
    Lt,
    Le,
    Gt,
    Ge,
    AndAnd,
    OrOr,
    Bang,
    Pipe,
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub tok: Tok,
    pub span: Span,
}

fn keyword(s: &str) -> Option<Tok> {
    Some(match s {
        "const" => Tok::Const,
        "let" => Tok::Let,
        "function" => Tok::Function,
        "return" => Tok::Return,
        "if" => Tok::If,
        "else" => Tok::Else,
        "while" => Tok::While,
        "for" => Tok::For,
        "of" => Tok::Of,
        "break" => Tok::Break,
        "continue" => Tok::Continue,
        "type" => Tok::Type,
        "import" => Tok::Import,
        "export" => Tok::Export,
        "from" => Tok::From,
        "match" => Tok::Match,
        "true" => Tok::True,
        "false" => Tok::False,
        "var" => Tok::Var,
        "class" | "interface" | "enum" | "new" | "this" | "null" | "undefined" | "async"
        | "await" => Tok::Reserved(s.to_string()),
        _ => return None,
    })
}

/// Human readable description of a token for error messages.
pub fn describe(t: &Tok) -> String {
    let s = match t {
        Tok::Ident(s) => return format!("identifier `{}`", s),
        Tok::Int(n) => return format!("integer `{}`", n),
        Tok::Str(_) => return "string literal".to_string(),
        Tok::Reserved(s) => return format!("reserved word `{}`", s),
        Tok::Eof => return "end of file".to_string(),
        Tok::Var => "var",
        Tok::Const => "const",
        Tok::Let => "let",
        Tok::Function => "function",
        Tok::Return => "return",
        Tok::If => "if",
        Tok::Else => "else",
        Tok::While => "while",
        Tok::For => "for",
        Tok::Of => "of",
        Tok::Break => "break",
        Tok::Continue => "continue",
        Tok::Type => "type",
        Tok::Import => "import",
        Tok::Export => "export",
        Tok::From => "from",
        Tok::Match => "match",
        Tok::True => "true",
        Tok::False => "false",
        Tok::LParen => "(",
        Tok::RParen => ")",
        Tok::LBrace => "{",
        Tok::RBrace => "}",
        Tok::LBracket => "[",
        Tok::RBracket => "]",
        Tok::Comma => ",",
        Tok::Semi => ";",
        Tok::Colon => ":",
        Tok::Dot => ".",
        Tok::Ellipsis => "...",
        Tok::Question => "?",
        Tok::FatArrow => "=>",
        Tok::Eq => "=",
        Tok::PlusEq => "+=",
        Tok::MinusEq => "-=",
        Tok::StarEq => "*=",
        Tok::SlashEq => "/=",
        Tok::PercentEq => "%=",
        Tok::Plus => "+",
        Tok::Minus => "-",
        Tok::Star => "*",
        Tok::Slash => "/",
        Tok::Percent => "%",
        Tok::EqEq => "==",
        Tok::NotEq => "!=",
        Tok::Lt => "<",
        Tok::Le => "<=",
        Tok::Gt => ">",
        Tok::Ge => ">=",
        Tok::AndAnd => "&&",
        Tok::OrOr => "||",
        Tok::Bang => "!",
        Tok::Pipe => "|",
    };
    format!("`{}`", s)
}

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}
fn is_ident_cont(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

pub fn lex(file: FileId, src: &str) -> Result<Vec<Token>, Diagnostic> {
    let b = src.as_bytes();
    let n = b.len();
    let mut i = 0usize;
    let mut out: Vec<Token> = Vec::new();
    let sp = |s: usize, e: usize| Span::new(file, s as u32, e as u32);
    let err = |s: usize, e: usize, m: String| Diagnostic::new("E0100", sp(s, e), m);

    while i < n {
        let c = b[i];
        if c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' {
            i += 1;
            continue;
        }
        if c == b'/' && i + 1 < n && b[i + 1] == b'/' {
            while i < n && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            let start = i;
            i += 2;
            loop {
                if i + 1 >= n {
                    return Err(err(start, start + 2, "unterminated block comment".into()));
                }
                if b[i] == b'*' && b[i + 1] == b'/' {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        let start = i;
        if is_ident_start(c) {
            while i < n && is_ident_cont(b[i]) {
                i += 1;
            }
            let word = &src[start..i];
            let tok = keyword(word).unwrap_or_else(|| Tok::Ident(word.to_string()));
            out.push(Token { tok, span: sp(start, i) });
            continue;
        }
        if c.is_ascii_digit() {
            let too_big = |e: usize| err(start, e, "integer literal does not fit in 64-bit signed integer".into());
            let value;
            if c == b'0' && i + 1 < n && (b[i + 1] == b'x' || b[i + 1] == b'X') {
                i += 2;
                let ds = i;
                while i < n && b[i].is_ascii_hexdigit() {
                    i += 1;
                }
                if i == ds {
                    return Err(err(start, i, "hexadecimal literal has no digits".into()));
                }
                value = i64::from_str_radix(&src[ds..i], 16).map_err(|_| too_big(i))?;
            } else {
                while i < n && b[i].is_ascii_digit() {
                    i += 1;
                }
                value = src[start..i].parse::<i64>().map_err(|_| too_big(i))?;
            }
            if i < n && is_ident_cont(b[i]) {
                let mut e = i;
                while e < n && is_ident_cont(b[e]) {
                    e += 1;
                }
                return Err(err(start, e, format!("invalid integer literal `{}`", &src[start..e])));
            }
            if i + 1 < n && b[i] == b'.' && b[i + 1].is_ascii_digit() {
                return Err(err(start, i + 1, "float literals are not supported in Orin-B".into()));
            }
            out.push(Token { tok: Tok::Int(value), span: sp(start, i) });
            continue;
        }
        if c == b'"' {
            i += 1;
            let mut bytes: Vec<u8> = Vec::new();
            loop {
                if i >= n || b[i] == b'\n' {
                    return Err(err(start, start + 1, "unterminated string literal".into()));
                }
                let ch = b[i];
                if ch == b'"' {
                    i += 1;
                    break;
                }
                if ch == b'\\' {
                    if i + 1 >= n {
                        return Err(err(start, start + 1, "unterminated string literal".into()));
                    }
                    match b[i + 1] {
                        b'n' => bytes.push(b'\n'),
                        b't' => bytes.push(b'\t'),
                        b'r' => bytes.push(b'\r'),
                        b'0' => bytes.push(0),
                        b'\\' => bytes.push(b'\\'),
                        b'"' => bytes.push(b'"'),
                        b'\'' => bytes.push(b'\''),
                        b'x' => {
                            let ok = i + 3 < n && b[i + 2].is_ascii_hexdigit() && b[i + 3].is_ascii_hexdigit();
                            if !ok {
                                return Err(err(i, i + 2, "invalid escape `\\x`: expected two hex digits".into()));
                            }
                            bytes.push(u8::from_str_radix(&src[i + 2..i + 4], 16).unwrap());
                            i += 2;
                        }
                        _ => {
                            let mut end = i + 2;
                            while end < n && !src.is_char_boundary(end) {
                                end += 1;
                            }
                            return Err(err(i, end, format!("invalid escape sequence `{}`", &src[i..end])));
                        }
                    }
                    i += 2;
                    continue;
                }
                bytes.push(ch);
                i += 1;
            }
            // Escapes that form valid UTF-8 round-trip; invalid byte sequences become U+FFFD
            // because ast::ExprKind::Str holds a Rust `String`.
            let s = match String::from_utf8(bytes) {
                Ok(s) => s,
                Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
            };
            out.push(Token { tok: Tok::Str(s), span: sp(start, i) });
            continue;
        }
        let next = if i + 1 < n { b[i + 1] } else { 0 };
        let (tok, len) = match c {
            b'(' => (Tok::LParen, 1),
            b')' => (Tok::RParen, 1),
            b'{' => (Tok::LBrace, 1),
            b'}' => (Tok::RBrace, 1),
            b'[' => (Tok::LBracket, 1),
            b']' => (Tok::RBracket, 1),
            b',' => (Tok::Comma, 1),
            b';' => (Tok::Semi, 1),
            b':' => (Tok::Colon, 1),
            b'.' => {
                if next == b'.' && i + 2 < n && b[i + 2] == b'.' {
                    (Tok::Ellipsis, 3)
                } else if next == b'.' {
                    return Err(err(i, i + 2, "unexpected `..`; did you mean `...`?".into()));
                } else {
                    (Tok::Dot, 1)
                }
            }
            b'?' => (Tok::Question, 1),
            b'=' => match next {
                b'>' => (Tok::FatArrow, 2),
                b'=' => (Tok::EqEq, 2),
                _ => (Tok::Eq, 1),
            },
            b'+' => if next == b'=' { (Tok::PlusEq, 2) } else { (Tok::Plus, 1) },
            b'-' => if next == b'=' { (Tok::MinusEq, 2) } else { (Tok::Minus, 1) },
            b'*' => if next == b'=' { (Tok::StarEq, 2) } else { (Tok::Star, 1) },
            b'/' => if next == b'=' { (Tok::SlashEq, 2) } else { (Tok::Slash, 1) },
            b'%' => if next == b'=' { (Tok::PercentEq, 2) } else { (Tok::Percent, 1) },
            b'!' => if next == b'=' { (Tok::NotEq, 2) } else { (Tok::Bang, 1) },
            b'<' => if next == b'=' { (Tok::Le, 2) } else { (Tok::Lt, 1) },
            b'>' => if next == b'=' { (Tok::Ge, 2) } else { (Tok::Gt, 1) },
            b'&' => {
                if next == b'&' {
                    (Tok::AndAnd, 2)
                } else {
                    return Err(err(i, i + 1, "unexpected character `&` (did you mean `&&`?)".into()));
                }
            }
            b'|' => if next == b'|' { (Tok::OrOr, 2) } else { (Tok::Pipe, 1) },
            _ => {
                let ch = src[i..].chars().next().unwrap();
                let msg = if ch == '\'' {
                    "unexpected character `'` (strings use double quotes)".to_string()
                } else {
                    format!("unexpected character `{}`", ch)
                };
                return Err(err(i, i + ch.len_utf8(), msg));
            }
        };
        i += len;
        out.push(Token { tok, span: sp(start, i) });
    }
    out.push(Token { tok: Tok::Eof, span: sp(n, n) });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Tok> {
        lex(FileId(0), s).unwrap().into_iter().map(|t| t.tok).collect()
    }
    fn lex_err(s: &str) -> Diagnostic {
        lex(FileId(0), s).unwrap_err()
    }

    #[test]
    fn basics() {
        assert_eq!(
            toks("const x = 0x7F; // c\n/* d */ y"),
            vec![
                Tok::Const,
                Tok::Ident("x".into()),
                Tok::Eq,
                Tok::Int(127),
                Tok::Semi,
                Tok::Ident("y".into()),
                Tok::Eof
            ]
        );
    }

    #[test]
    fn operators() {
        assert_eq!(
            toks("=> == != <= >= && || ... += -= *= /= %= | ? !"),
            vec![
                Tok::FatArrow,
                Tok::EqEq,
                Tok::NotEq,
                Tok::Le,
                Tok::Ge,
                Tok::AndAnd,
                Tok::OrOr,
                Tok::Ellipsis,
                Tok::PlusEq,
                Tok::MinusEq,
                Tok::StarEq,
                Tok::SlashEq,
                Tok::PercentEq,
                Tok::Pipe,
                Tok::Question,
                Tok::Bang,
                Tok::Eof
            ]
        );
    }

    #[test]
    fn no_shift_token() {
        assert_eq!(toks(">>"), vec![Tok::Gt, Tok::Gt, Tok::Eof]);
    }

    #[test]
    fn strings() {
        assert_eq!(toks(r#""a\n\t\"\\\x41\0""#)[0], Tok::Str("a\n\t\"\\A\0".into()));
        assert_eq!(toks("\"h\u{e9}\"")[0], Tok::Str("h\u{e9}".into()));
        assert_eq!(toks(r#""\xC3\xA9""#)[0], Tok::Str("\u{e9}".into()));
    }

    #[test]
    fn keywords_and_reserved() {
        assert_eq!(toks("var")[0], Tok::Var);
        assert_eq!(toks("class")[0], Tok::Reserved("class".into()));
        assert_eq!(toks("classy")[0], Tok::Ident("classy".into()));
        assert_eq!(toks("match")[0], Tok::Match);
    }

    #[test]
    fn errors() {
        assert_eq!(lex_err("@").code, "E0100");
        assert_eq!(lex_err("'a'").code, "E0100");
        assert_eq!(lex_err("\"abc").code, "E0100");
        assert_eq!(lex_err("\"abc\ndef\"").code, "E0100");
        assert_eq!(lex_err("/* x").code, "E0100");
        assert_eq!(lex_err(r#""\q""#).code, "E0100");
        assert_eq!(lex_err(r#""\xZ1""#).code, "E0100");
        assert_eq!(lex_err(r#""\x4""#).code, "E0100");
        assert_eq!(lex_err("9223372036854775808").code, "E0100");
        assert_eq!(lex_err("0x8000000000000000").code, "E0100");
        assert_eq!(lex_err("0x").code, "E0100");
        assert_eq!(lex_err("1_000").code, "E0100");
        assert_eq!(lex_err("1.5").code, "E0100");
        assert_eq!(lex_err("a & b").code, "E0100");
        assert_eq!(lex_err("..").code, "E0100");
        assert!(lex(FileId(0), "9223372036854775807").is_ok());
    }

    #[test]
    fn spans() {
        let t = lex(FileId(0), "ab  cd").unwrap();
        assert_eq!((t[1].span.start, t[1].span.end), (4, 6));
    }
}
