//! orinb — Orin Stage 0 bootstrap compiler. Temporary infrastructure (see docs/bootstrap.md).
//!
//! Pipeline: loader (lexer+parser per file, import resolution) → checker (AST → typed HIR)
//! → codegen (HIR → GNU C against runtime/orin_runtime.h).

#![allow(dead_code)]

mod ast;
mod astdump;
mod checker;
mod codegen;
mod diag;
mod hir;
mod lexer;
mod loader;
mod parser;
mod span;

use std::path::{Path, PathBuf};
use std::process::{exit, Command};

fn usage() -> ! {
    eprintln!(
        "usage:\n  orinb parse <file.or>                 dump AST\n  orinb check <entry.or>                type-check program\n  orinb compile <entry.or> -o <out.c>   emit C\n  orinb build <entry.or> -o <exe>       emit C and link with cc"
    );
    exit(2)
}

fn report(diags: &[diag::Diagnostic], sm: &span::SourceMap) -> ! {
    for d in diags {
        eprintln!("{}", d.render(sm));
    }
    exit(1)
}

fn runtime_dir() -> PathBuf {
    if let Ok(d) = std::env::var("ORIN_RUNTIME") {
        return PathBuf::from(d);
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../runtime")
}

fn front(entry: &Path, sm: &mut span::SourceMap) -> hir::Program {
    let loaded = match loader::load(entry, sm) {
        Ok(l) => l,
        Err(d) => report(&d, sm),
    };
    match checker::check(&loaded, sm) {
        Ok(p) => p,
        Err(d) => report(&d, sm),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        usage();
    }
    let cmd = args[1].as_str();
    let input = PathBuf::from(&args[2]);
    let out = if args.len() >= 5 && args[3] == "-o" { Some(PathBuf::from(&args[4])) } else { None };
    let mut sm = span::SourceMap::new();
    match cmd {
        "parse" => {
            let text = std::fs::read_to_string(&input).unwrap_or_else(|e| {
                eprintln!("error: cannot read {}: {}", input.display(), e);
                exit(1)
            });
            let fid = sm.add(input.clone(), text.clone());
            match parser::parse(fid, &text) {
                Ok(m) => println!("{:#?}", m.items),
                Err(d) => report(&d, &sm),
            }
        }
        "dump-ast" => {
            let text = std::fs::read_to_string(&input).unwrap_or_else(|e| {
                eprintln!("error: cannot read {}: {}", input.display(), e);
                exit(1)
            });
            let fid = sm.add(input.clone(), text.clone());
            match parser::parse(fid, &text) {
                Ok(m) => print!("{}", astdump::dump(&m)),
                Err(d) => report(&d, &sm),
            }
        }
        "check" => {
            front(&input, &mut sm);
        }
        "compile" | "build" => {
            let Some(out) = out else { usage() };
            let prog = front(&input, &mut sm);
            let c = codegen::generate(&prog);
            let c_path = if cmd == "compile" { out.clone() } else { out.with_extension("c") };
            if let Err(e) = std::fs::write(&c_path, c) {
                eprintln!("error: cannot write {}: {}", c_path.display(), e);
                exit(1);
            }
            if cmd == "build" {
                let rt = runtime_dir();
                let status = Command::new(std::env::var("CC").unwrap_or_else(|_| "cc".into()))
                    .arg("-O2")
                    .arg("-w")
                    .arg("-I")
                    .arg(&rt)
                    .arg(&c_path)
                    .arg(rt.join("orin_runtime.c"))
                    .arg("-o")
                    .arg(&out)
                    .status();
                match status {
                    Ok(s) if s.success() => {}
                    _ => {
                        eprintln!("error: C compilation failed");
                        exit(1)
                    }
                }
            }
        }
        _ => usage(),
    }
}
