#!/usr/bin/env python3
"""Contract erasure test (ADR-0012): contract clauses must not change the generated code.

Usage: python3 tools/test_contract_erasure.py [--orinc build/bootstrap/orin2]

For every program under tests/next/run whose name starts with `contracts_` (and the other files
listed in EXTRA) the clause lines (`@Requires(..)`, `@Ensures(..)`, `@Invariant(..)`,
`@Decreases(..)`, `@Rule(..)`, one per line) are deleted, and both versions are compiled with the
default pipeline (C and LLVM IR). The outputs must be byte-identical. Programs that carry a
`// flags:` header (runtime checking) are skipped: they intentionally generate checks.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLAUSE = re.compile(r"^\s*@(Requires|Ensures|Invariant|Decreases|Rule)\(.*\)\s*$")
EXTRA = []


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
    files = [os.path.join(base, f) for f in sorted(os.listdir(base)) if f.startswith("contracts_") and f.endswith(".or")]
    files += [os.path.join(ROOT, f) for f in EXTRA]
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in files:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
            if "// flags:" in text:
                continue
            lines = text.split("\n")
            kept = [l for l in lines if not CLAUSE.match(l)]
            if len(kept) == len(lines):
                print("FAIL %s: no contract clause found" % os.path.basename(path))
                failures += 1
                continue
            # Same file name in two directories: function names in the output derive from it.
            os.makedirs(os.path.join(tmp, "with"), exist_ok=True)
            os.makedirs(os.path.join(tmp, "without"), exist_ok=True)
            stripped = os.path.join(tmp, "without", os.path.basename(path))
            with open(stripped, "w", encoding="utf-8") as f:
                f.write("\n".join(kept))
            original = os.path.join(tmp, "with", os.path.basename(path))
            with open(original, "w", encoding="utf-8") as f:
                f.write(text)
            for backend, ext in (("c", ".c"), ("llvm", ".ll")):
                out_a = os.path.join(tmp, "a" + ext)
                out_b = os.path.join(tmp, "b" + ext)
                rc_a, err_a = compile_to(orinc, original, out_a, backend)
                rc_b, err_b = compile_to(orinc, stripped, out_b, backend)
                name = "%s [%s]" % (os.path.basename(path), backend)
                if rc_a != 0 or rc_b != 0:
                    print("FAIL %s: compile failed\n  with clauses: %s\n  stripped: %s" % (name, err_a.strip(), err_b.strip()))
                    failures += 1
                    continue
                with open(out_a, "rb") as fa, open(out_b, "rb") as fb:
                    same = fa.read() == fb.read()
                checked += 1
                if not same:
                    print("FAIL %s: generated code differs with and without contract clauses" % name)
                    failures += 1
    print("contract erasure: %d comparisons, %d failed" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
