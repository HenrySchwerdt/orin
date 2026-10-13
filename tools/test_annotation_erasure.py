#!/usr/bin/env python3
"""@Test erasure test (ADR-0024): `@Test` functions must not change the generated code.

Usage: python3 tools/test_annotation_erasure.py [--orinc build/bootstrap/orin2]

For every program under tests/next/run whose name starts with `annotations_test_` the `@Test`
functions (the `@Test` line up to the closing `}` in column 0) are deleted, and both versions are
compiled with the default pipeline (C and LLVM IR). The outputs must be byte-identical: tests are
type-checked but nothing they use (generic instances, closures, string literals, records) may reach
the output. Same idea as tools/test_contract_erasure.py.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip_tests(text):
    out, skipping, removed = [], False, 0
    for line in text.split("\n"):
        if not skipping and line.strip() == "@Test":
            skipping, removed = True, removed + 1
            continue
        if skipping:
            if line == "}":
                skipping = False
            continue
        out.append(line)
    return "\n".join(out), removed


def compile_to(orinc, src, out, backend):
    r = subprocess.run([orinc, "compile", src, "-o", out, "--backend=" + backend], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    return r.returncode, r.stderr.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    args = ap.parse_args()
    orinc = args.orinc if os.path.isabs(args.orinc) else os.path.join(ROOT, args.orinc)
    base = os.path.join(ROOT, "tests", "next", "run")
    files = [os.path.join(base, f) for f in sorted(os.listdir(base))
             if f.startswith("annotations_test_") and f.endswith(".or")]
    failures = checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in files:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
            stripped, removed = strip_tests(text)
            name = os.path.basename(path)
            if removed == 0:
                print("FAIL %s: no @Test function found" % name)
                failures += 1
                continue
            # Same file name in two directories: names in the output derive from it.
            for d in ("with", "without"):
                os.makedirs(os.path.join(tmp, d), exist_ok=True)
            a_src, b_src = os.path.join(tmp, "with", name), os.path.join(tmp, "without", name)
            with open(a_src, "w", encoding="utf-8") as f:
                f.write(text)
            with open(b_src, "w", encoding="utf-8") as f:
                f.write(stripped)
            for backend, ext in (("c", ".c"), ("llvm", ".ll")):
                out_a, out_b = os.path.join(tmp, "a" + ext), os.path.join(tmp, "b" + ext)
                rc_a, err_a = compile_to(orinc, a_src, out_a, backend)
                rc_b, err_b = compile_to(orinc, b_src, out_b, backend)
                label = "%s [%s]" % (name, backend)
                if rc_a != 0 or rc_b != 0:
                    print("FAIL %s: compile failed\n  with tests: %s\n  without: %s" % (label, err_a.strip(), err_b.strip()))
                    failures += 1
                    continue
                with open(out_a, "rb") as fa, open(out_b, "rb") as fb:
                    same = fa.read() == fb.read()
                checked += 1
                if not same:
                    print("FAIL %s: generated code differs with and without @Test functions" % label)
                    failures += 1
    print("annotation erasure: %d comparisons, %d failed" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
