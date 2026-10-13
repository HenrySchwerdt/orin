#!/usr/bin/env python3
"""Behaviour-preservation check for the compiler rewrite (docs/rewrite.md): compare exit status,
stdout and stderr of two compilers (the baseline built before the rewrite, and the new one) over
every test input (`compile X -o /dev/null`, `check X`, `check --format=json X`). Diagnostics must
be byte-identical.  usage: tools/diff_compilers.py BASE_ORIN NEW_ORIN   (run from the repo root)"""
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
base, new = sys.argv[1], sys.argv[2]
inputs = []
for d in ("tests/errors", "tests/next/errors", "tests/parse_edge", "tests/run", "tests/next/run", "tests/contracts"):
    for e in sorted(os.listdir(d)):
        p = os.path.join(d, e)
        if e.endswith(".or") or (os.path.isdir(p) and os.path.exists(os.path.join(p, "main.or"))):
            inputs.append(p if e.endswith(".or") else os.path.join(p, "main.or"))
for dirpath, dirs, files in os.walk("tests"):
    if "orin.toml" in files:
        inputs.append(dirpath)
extra = ["compiler/main.or"]
inputs += extra

def run(c, args):
    r = subprocess.run([c] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    return (r.returncode, r.stdout, r.stderr)

def job(x):
    out = []
    for args in (["compile", x, "-o", "/dev/null"], ["check", x], ["check", "--format=json", x]):
        a, b = run(base, args), run(new, args)
        if a != b:
            out.append((x, args, a, b))
    return out

bad = 0
with ThreadPoolExecutor(4) as ex:
    for res in ex.map(job, inputs):
        for x, args, a, b in res:
            bad += 1
            print("DIFF", x, args, a[0], b[0])
            print("  base:", a[2][:300])
            print("  new :", b[2][:300])
print("compared %d inputs x 3 modes, %d differences" % (len(inputs), bad))
sys.exit(1 if bad else 0)
