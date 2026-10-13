#!/usr/bin/env python3
"""Differential parser test: Stage 0 (orinb dump-ast) vs Stage 1 (build/parse1).

Usage: python3 tools/diff_parsers.py [--orinb PATH] [--no-build] [-v] [extra files/dirs...]

For every .or file under tests/ (except tests/next/, which uses syntax beyond Orin-B that
Stage 0 rejects), compiler/ and bootstrap/tests/parse/ (this includes the
hand-written edge cases in tests/parse_edge/) both parsers run. They agree when both succeed
with identical stdout, or both fail with the same error code (and the same line:col).
Exit status is non-zero on any mismatch.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Stage 1 accepts class syntax (ADR-0009: `class`, `new`, `this`), which Stage 0 rejects with E0200;
# these edge cases pin Stage 0's behaviour only.
CLASS_SYNTAX_SKIP = {"err0200_reserved_class.or", "err0200_reserved_new.or", "err0200_reserved_this.or",
                     # Stage 1 accepts interfaces (ADR-0019) and lexes a lone `&` (for the E0408 of `T extends A & B`)
                     "err0200_reserved_interface.or", "err0100_bad_char_amp.or", "err0100_bad_char_amp_end.or"}
# The array prelude (ADR-0011) is written with closures, syntax beyond Orin-B that Stage 0 rejects.
PRELUDE_SKIP = {os.path.join("tests", "fmt", "closures.in.or"), os.path.join("tests", "fmt", "closures.out.or"),
                # contract clauses (ADR-0012) are beyond Orin-B: Stage 0 rejects `@`
                os.path.join("tests", "fmt", "contracts.in.or"), os.path.join("tests", "fmt", "contracts.out.or"),
                os.path.join("tests", "fmt", "floats.in.or"), os.path.join("tests", "fmt", "floats.out.or"),
                # these pin Stage 0's rejection of arrow functions, which Stage 1 now accepts
                os.path.join("tests", "parse_edge", "err0200_binary_arrow_in_expr.or"),
                os.path.join("tests", "parse_edge", "err0200_fn_arrow_expr.or"),
                # interfaces (ADR-0019) are syntax beyond Orin-B
                os.path.join("tests", "fmt", "interfaces.in.or"), os.path.join("tests", "fmt", "interfaces.out.or"),
                # template literals and integer literals above i64 max (ADR-0022) are lexical errors (E0100) in Stage 0
                os.path.join("tests", "fmt", "templates.in.or"), os.path.join("tests", "fmt", "templates.out.or"),
                os.path.join("tests", "parse_edge", "ok_template_nested.or"),
                # built-in annotations (ADR-0024) are syntax beyond Orin-B
                os.path.join("tests", "fmt", "annotations.in.or"), os.path.join("tests", "fmt", "annotations.out.or")}
# Stage 1 accepts float literals (ADR-0018); these edge cases pin Stage 0's rejection only.
FLOAT_SKIP = {"err0100_bad_float.or", "err0100_bad_float_in_expr.or", "err0100_bad_float_second_line.or",
              "err0100_bad_int_exp.or",
              # Stage 1 accepts integer literals up to 2^64-1 (u64, ADR-0022); these two (2^63) pin Stage 0's rejection
              # (err0100_bad_int_overflow_u64*.or, above 2^64-1, are rejected by both)
              "err0100_bad_int_overflow.or", "err0100_bad_int_overflow_hex.or"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ERR = re.compile(r"^(?:.*?):(\d+):(\d+): error\[(E\d{4})\]")
TIMEOUT = 30


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return (-999, b"", b"timeout")
    return (p.returncode, p.stdout, p.stderr)


def error_of(stderr):
    for line in stderr.decode("utf-8", "replace").splitlines():
        m = ERR.match(line)
        if m:
            return (m.group(3), m.group(1) + ":" + m.group(2))
    return None


def compare(orinb, parse1, f):
    rc0, out0, err0 = run([orinb, "dump-ast", f])
    rc1, out1, err1 = run([parse1, f])
    if rc0 == 0 and rc1 == 0:
        if out0 == out1:
            return None
        a = out0.decode("utf-8", "replace").splitlines()
        b = out1.decode("utf-8", "replace").splitlines()
        d = list(difflib.unified_diff(a, b, "stage0", "stage1", lineterm="", n=1))
        return "outputs differ:\n" + "\n".join(d[:24])
    if rc0 == 1 and rc1 == 1:
        e0, e1 = error_of(err0), error_of(err1)
        if e0 is None or e1 is None:
            return "unparseable diagnostics: stage0=%r stage1=%r" % (err0[:200], err1[:200])
        if e0 != e1:
            return "error differs: stage0 %s at %s, stage1 %s at %s\n  s0: %s\n  s1: %s" % (
                e0[0], e0[1], e1[0], e1[1],
                err0.decode("utf-8", "replace").strip().splitlines()[0],
                err1.decode("utf-8", "replace").strip().splitlines()[0])
        return None
    return "status differs: stage0 exit %d (%s), stage1 exit %d (%s)" % (
        rc0, (err0 or out0)[:150].decode("utf-8", "replace").strip(),
        rc1, (err1 or out1)[:150].decode("utf-8", "replace").strip())


def collect(extra):
    files = []
    roots = [os.path.join(ROOT, d) for d in ("tests", "compiler", os.path.join("bootstrap", "tests", "parse"))]
    roots += extra
    for r in roots:
        if os.path.isfile(r):
            files.append(r)
            continue
        for dp, dn, fn in os.walk(r):
            # tests/next uses syntax beyond Orin-B (generics) that Stage 0 rejects with E0200.
            dn[:] = [d for d in dn if d not in ("target", "build", ".git")
                     and os.path.join(dp, d) not in (os.path.join(ROOT, "tests", "next"), os.path.join(ROOT, "tests", "contracts"), os.path.join(ROOT, "tests", "osig"))]
            for n in fn:
                if n.endswith(".or"):
                    files.append(os.path.join(dp, n))
    files = [f for f in files if os.path.basename(f) not in CLASS_SYNTAX_SKIP | FLOAT_SKIP
             and os.path.relpath(f, ROOT) not in PRELUDE_SKIP]
    return sorted(set(os.path.relpath(f, ROOT) if f.startswith(ROOT) else f for f in files))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinb", default=os.path.join("bootstrap", "target", "release", "orinb"))
    ap.add_argument("--parse1", help="use this prebuilt Stage 1 parser (implies --no-build)")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    orinb = a.orinb if os.path.isabs(a.orinb) else os.path.join(ROOT, a.orinb)
    parse1 = os.path.abspath(a.parse1) if a.parse1 else os.path.join(ROOT, "build", "parse1")
    if a.parse1:
        a.no_build = True
    if not a.no_build:
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        rc, out, err = run([orinb, "build", "compiler/tests/parse_main.or", "-o", "build/parse1"])
        if rc != 0:
            sys.stderr.write("failed to build Stage 1 parser:\n" + err.decode("utf-8", "replace"))
            return 2
    files = collect([os.path.abspath(x) for x in a.extra])
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        results = list(ex.map(lambda f: compare(orinb, parse1, f), files))
    bad = 0
    ok_err = 0
    for f, r in zip(files, results):
        if r:
            bad += 1
            print("MISMATCH %s\n  %s" % (f, r.replace("\n", "\n  ")))
        elif a.verbose:
            print("ok %s" % f)
    print("compared %d files, %d mismatches" % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
