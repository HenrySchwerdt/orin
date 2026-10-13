#!/usr/bin/env python3
"""Run `orin verify` (MIR ownership verifier, on the optimised MIR; pass --no-opt to skip the
optimiser) on every tests/run and tests/next/run program and optionally on extra entries (e.g.
compiler/main.or). Reports error and warning totals.

Usage: python3 tools/verify_all.py [--orinc build/bootstrap/orin2] [-v] [extra.or ...]
"""
import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def entries():
    out = []
    for suite in ("run", os.path.join("next", "run")):
        base = os.path.join(ROOT, "tests", suite)
        for e in sorted(os.listdir(base)):
            p = os.path.join(base, e)
            if os.path.isdir(p):
                if os.path.isfile(os.path.join(p, "main.or")):
                    out.append(os.path.join(p, "main.or"))
            elif e.endswith(".or"):
                out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--no-opt", action="store_true")
    ap.add_argument("extra", nargs="*")
    args = ap.parse_args()
    orinc = os.path.join(ROOT, args.orinc) if not os.path.isabs(args.orinc) else args.orinc
    files = entries() + [os.path.join(ROOT, x) for x in args.extra]

    def work(f):
        r = subprocess.run([orinc, "verify"] + (["--no-opt"] if args.no_opt else []) + [os.path.relpath(f, ROOT)], cwd=ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
        return f, r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(work, files))
    te = tw = 0
    bad = 0
    for f, rc, out, err in results:
        m = re.search(r"verify: (\d+) errors, (\d+) warnings", out)
        if not m:
            print("FAIL %s: no verify summary (rc=%s) %s" % (os.path.relpath(f, ROOT), rc, err[:300]))
            bad += 1
            continue
        e, w = int(m.group(1)), int(m.group(2))
        te += e
        tw += w
        if e or args.v and w:
            print("%s: %d errors, %d warnings" % (os.path.relpath(f, ROOT), e, w))
            for line in out.splitlines():
                if line.startswith("error:") or (args.v and line.startswith("warning:")):
                    print("   " + line)
        if e:
            bad += 1
    print("TOTAL %d programs: %d errors, %d warnings, %d failing" % (len(results), te, tw, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
