#!/usr/bin/env python3
"""Mutation check for the OX part of the compiler (ADR-0043, ADR-0044).

Each mutant is a small, deliberately wrong change of the OX lexer, parser or checker (compiler/syntax/lexer.or,
parser.or, compiler/check/ox.or, expr.or, stmt.or): a provider rule that is ignored (static encoding, attribute rules,
void and raw-text elements, presence attributes), a value that is not encoded, a sealed record that can be built,
attributes evaluated out of source order, broken whitespace rules, ... The
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
    # ---- provider rules and the buffer (check/ox.or)
    ("static-encoding-ignored", "check/ox.or", "      if (e.code == c) {", "      if (e.code == c + 1000) {"),
    ("rule-prefix-ignored", "check/ox.or", " || r.prefix.length > 0 && n.startsWith(r.prefix)", ""),
    ("rule-names-case-sensitive", "check/ox.or", "  const n = asciiLower(name);\n  for (const r of p.rules) {",
     "  const n = name;\n  for (const r of p.rules) {"),
    ("void-tags-ignored", "check/ox.or", "  return listed(p.voidTags, tag);", "  return false;"),
    ("raw-text-tags-ignored", "check/ox.or", "  return listed(p.rawTextTags, tag);", "  return false;"),
    ("sealed-ignored", "check/ox.or", "  if (!env.sealed.some(x => x == qname)) {", "  if (true) {"),
    ("pending-text-dropped", "check/ox.or", "  if (o.pending.length > 0) {\n    ps.push(mk(XStr(o.pending), TyString, span));\n  }\n  ps.push(e);",
     "  ps.push(e);"),
    # ---- the checker (check/expr.or, check/stmt.or)
    ("dynamic-child-not-encoded", "check/expr.or",
     "      return Ok(oxOutDyn(o, mk(XCall(p.text, [v]), TyString, span), span));",
     "      return Ok(oxOutDyn(o, v, span));"),
    ("rule-convert-ignored", "check/expr.or", "              conv = f;", "              conv = p.attr;"),
    ("dynamic-attribute-not-encoded", "check/expr.or", "          piece = mk(XCall(conv, [v]), TyString, x.span);",
     "          piece = v;"),
    ("static-attribute-not-encoded", "check/expr.or",
     "      JVStr(v) => {\n        return Ok(oxOutStatic(o, \" \" + name + \"=\\\"\" + oxEncodeStatic(p, v) + \"\\\"\"));",
     "      JVStr(v) => {\n        return Ok(oxOutStatic(o, \" \" + name + \"=\\\"\" + v + \"\\\"\"));"),
    ("static-text-not-encoded", "check/expr.or", "o = oxOutStatic(o, raw ? t : oxEncodeStatic(p, t));",
     "o = oxOutStatic(o, t);"),
    ("bool-attribute-inverted", "check/expr.or", "mk(XCond(v, on, off), TyString, x.span)", "mk(XCond(v, off, on), TyString, x.span)"),
    ("void-end-ignored", "check/expr.or", "      return Ok(oxOutStatic(o, p.voidEnd));", "      return Ok(oxOutStatic(o, \">\"));"),
    ("presence-not-checked", "check/expr.or", "  private oxPresent(p: OxProvider, name: string, span: Span, o: OxOut): Result<OxOut, Diagnostic> {\n    if (!p.presence) {",
     "  private oxPresent(p: OxProvider, name: string, span: Span, o: OxOut): Result<OxOut, Diagnostic> {\n    if (false) {"),
    ("source-order-ignored", "check/expr.or", "          if (pi <= last) {\n            ordered = true;\n          }\n          last = pi;\n        },",
     "          last = pi;\n        },"),
    ("option-param-required", "check/expr.or", 'if (pn != "children" && !sig.opt[i]) {', 'if (pn != "children") {'),
    ("single-child-wrapped-in-fragment", "check/expr.or", "      if (items.length == 1 && !items[0].splice) {", "      if (false) {"),
    ("spread-later-attribute-lost", "check/expr.or", "          args[pi] = Some(x);\n", "          if (args[pi].isNone()) {\n            args[pi] = Some(x);\n          }\n"),
    ("field-assignment-not-sealed", "check/stmt.or",
     "          if (sealed.isSome()) {\n            return Err(sealed.unwrap());\n          }\n", ""),
    # ---- lexer and parser (syntax/)
    ("text-lines-not-trimmed", "syntax/lexer.or", "  if (!first) {\n", "  if (false) {\n"),
    ("entities-not-decoded", "syntax/lexer.or", '  if (!s.includes("&")) {\n    return s;', '  if (true) {\n    return s;'),
    ("no-ox-after-return", "syntax/lexer.or", 'KKeyword => t.text == "return",', "KKeyword => false,"),
    ("ox-after-identifier", "syntax/lexer.or", 'KPunct => t.text != ")" && t.text != "]" && t.text != "}",',
     'KPunct => t.text != ")" && t.text != "]" && t.text != "}",\n      KIdent => true,'),
    ("closing-tag-name-unchecked", "syntax/parser.or", "        if (!this.isIdentText(0, path[k])) {", "        if (!this.isIdentAt(0)) {"),
    # ---- member tags (ADR-0044 §4.5)
    ("member-receiver-dropped", "syntax/parser.or", "        recv = Some(r);", "        recv = None;"),
    ("member-lowercase-accepted", "syntax/parser.or", "        if (id.name.charCodeAt(0) < 65 || id.name.charCodeAt(0) > 90) {",
     "        if (false) {"),
    ("member-receiver-param-counted", "check/expr.or", "ps.slice(1, ps.length)", "ps"),
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
