#!/usr/bin/env python3
"""Mutation check for the OX part of the compiler (ADR-0043).

Each mutant is a small, deliberately wrong change of the OX lexer, parser or checker (compiler/syntax/lexer.or,
parser.or, compiler/check/ox.or, expr.or, stmt.or): a missing escape, a URL attribute that is no longer sanitised,
an event handler that accepts a computed value, a sealed `Html` that can be built, broken whitespace rules, ... The
compiler sources are copied to build/mutate_ox/<mutant>/, the mutation is applied, the mutated compiler is built (one
self-compile by --orinc, then cc -O1) and the OX conformance tests (`tests/next/{run,errors}/ox_*`) are run with it.
A mutant is killed when a test fails (or the mutated compiler does not build). Every mutant must be killed.

Usage: python3 tools/mutate_ox.py [--orinc build/dev/orin] [--list] [--only NAME[,NAME]] [-j N]
A mutant costs one compiler build (about a minute), so -j 2 on a 4-CPU machine.
Exit status 1 if any mutant survives.
"""
import argparse
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parallel import add_jobs_arg, ordered_map  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "mutate_ox")

# (name, file under compiler/, old text (must occur exactly once), new text)
MUTANTS = [
    # ---- compile-time escaping (check/ox.or)
    ("static-escape-drops-apostrophe", "check/ox.or", 'c == 39 ? "&#39;" : ""', 'c == 39 ? "\'" : ""'),
    ("static-escape-ampersand", "check/ox.or", 'c == 38 ? "&amp;"', 'c == 38 ? "&"'),
    ("static-escape-less-than", "check/ox.or", 'c == 60 ? "&lt;"', 'c == 60 ? "<"'),
    # ---- HTML rules (check/ox.or)
    ("href-not-a-url-attribute", "check/ox.or", '    "href" => true,\n', ''),
    ("event-handlers-accept-values", "check/ox.or", "  return name.length > 2\n", "  return name.length > 200\n"),
    ("br-not-void", "check/ox.or", '    "br" => true,\n', ''),
    ("script-not-raw-text", "check/ox.or", 'return name == "script" || name == "style";', 'return name == "style";'),
    ("html-not-sealed", "check/ox.or", "  if (!sealed || unit < env.units.length", "  if (true || unit < env.units.length"),
    ("pending-text-dropped", "check/ox.or", "  if (o.pending.length > 0) {\n    ps.push(mk(XStr(o.pending), TyString, span));\n  }\n  ps.push(e);",
     "  ps.push(e);"),
    # ---- the checker (check/expr.or, check/stmt.or)
    ("dynamic-child-not-escaped", "check/expr.or",
     "      return Ok(oxOutDyn(o, mk(XCall(lib.esc, [v]), TyString, x.span), x.span));",
     "      return Ok(oxOutDyn(o, v, x.span));"),
    ("url-attribute-not-sanitised", "check/expr.or", "isUrlAttr(name) ? lib.escUrl : lib.esc", "lib.esc"),
    ("dynamic-attribute-not-escaped", "check/expr.or",
     "          piece = mk(XCall(isUrlAttr(name) ? lib.escUrl : lib.esc, [v]), TyString, x.span);",
     "          piece = v;"),
    ("static-attribute-not-escaped", "check/expr.or",
     "      JVStr(v) => {\n        return Ok(oxOutStatic(o, \" \" + name + \"=\\\"\" + htmlEscapeStatic(v) + \"\\\"\"));",
     "      JVStr(v) => {\n        return Ok(oxOutStatic(o, \" \" + name + \"=\\\"\" + v + \"\\\"\"));"),
    ("static-text-not-escaped", "check/expr.or", "o = oxOutStatic(o, raw ? t : htmlEscapeStatic(t));",
     "o = oxOutStatic(o, t);"),
    ("bool-attribute-inverted", "check/expr.or", "mk(XCond(v, on, off), TyString, x.span)", "mk(XCond(v, off, on), TyString, x.span)"),
    ("children-param-ignored", "check/expr.or", "        kidsUsed = true;\n", ""),
    ("closing-tag-of-void-written", "check/expr.or",
     "      return Ok(o);\n    }\n    o = this.oxChildren(lib, el.children, isRawTextElement(tag.name), o)?;",
     "      return Ok(oxOutStatic(o, \"</\" + tag.name + \">\"));\n    }\n    o = this.oxChildren(lib, el.children, isRawTextElement(tag.name), o)?;"),
    ("field-assignment-not-sealed", "check/stmt.or",
     "          if (sealed.isSome()) {\n            return Err(sealed.unwrap());\n          }\n", ""),
    # ---- lexer and parser (syntax/)
    ("text-lines-not-trimmed", "syntax/lexer.or", "  if (!first) {\n", "  if (false) {\n"),
    ("entities-not-decoded", "syntax/lexer.or", '  if (!s.includes("&")) {\n    return s;', '  if (true) {\n    return s;'),
    ("no-ox-after-return", "syntax/lexer.or", 'KKeyword => t.text == "return",', "KKeyword => false,"),
    ("ox-after-identifier", "syntax/lexer.or", 'KPunct => t.text != ")" && t.text != "]" && t.text != "}",',
     'KPunct => t.text != ")" && t.text != "]" && t.text != "}",\n      KIdent => true,'),
    ("closing-tag-name-unchecked", "syntax/parser.or", "      if (!this.isIdentText(0, want)) {", "      if (!this.isIdentAt(0)) {"),
]


def sh(cmd, cwd=ROOT, timeout=900):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)


def run_mutant(args, m):
    name, rel, old, new = m
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "compiler"), os.path.join(d, "compiler"))
    path = os.path.join(d, "compiler", rel)
    src = open(path).read()
    if src.count(old) != 1:
        return name, "ERROR", "the old text occurs %d times in %s" % (src.count(old), rel)
    open(path, "w").write(src.replace(old, new))
    orin_c = os.path.join(d, "orin.c")
    exe = os.path.join(d, "orin")
    r = sh([args.orinc, "compile", os.path.join(d, "compiler", "main.or"), "-o", orin_c])
    if r.returncode != 0:
        return name, "killed", "the mutated compiler does not compile"
    r = sh([args.cc, "-O1", "-w", "-I", "runtime", orin_c, "runtime/orin_runtime.c", "platform/orin_platform.c",
            "-lm", "-lpthread", "-o", exe])
    if r.returncode != 0:
        return name, "ERROR", "cc failed: " + r.stdout.decode("utf-8", "replace")[-400:]
    r = sh([sys.executable, "tools/run_tests.py", "--orinc", exe, "--suite", "next", "--filter", "ox", "--jobs", "1"])
    if r.returncode != 0:
        fails = [l for l in r.stdout.decode("utf-8", "replace").splitlines() if l.startswith("FAIL")]
        return name, "killed", ", ".join(f[5:] for f in fails[:3])
    return name, "SURVIVED", ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--orinc", default=os.path.join(ROOT, "build", "dev", "orin"))
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", default="")
    add_jobs_arg(ap)
    args = ap.parse_args()
    ms = MUTANTS
    if args.only:
        keep = set(args.only.split(","))
        ms = [m for m in MUTANTS if m[0] in keep]
    if args.list:
        for m in ms:
            print("%-36s %s" % (m[0], m[1]))
        return 0
    if not os.path.exists(args.orinc):
        sys.exit("no compiler %s (tools/dev.sh build)" % args.orinc)
    os.makedirs(OUT, exist_ok=True)
    survived = 0
    killed = 0
    for name, status, detail in ordered_map(lambda m: run_mutant(args, m), ms, args.jobs):
        print("[mutate_ox] %-36s %s %s" % (name, status, detail), flush=True)
        if status == "killed":
            killed += 1
        else:
            survived += 1
    print("[mutate_ox] %d mutants, %d killed, %d not killed" % (len(ms), killed, survived))
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
