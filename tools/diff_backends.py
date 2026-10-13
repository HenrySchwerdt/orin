#!/usr/bin/env python3
"""Differential test of the two Stage 1 backends: for every tests/run program, compile with the
MIR backend (default) and with `--legacy-codegen`, build and run both, compare stdout + exit code.

Usage: python3 tools/diff_backends.py [--orinc build/bootstrap/orin2] [--cc cc] [--filter s]
                                      [--sanitize]
"""
import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join("build", "diff")


def entries():
    base = os.path.join(ROOT, "tests", "run")
    out = []
    for e in sorted(os.listdir(base)):
        p = os.path.join(base, e)
        if os.path.isdir(p):
            if os.path.isfile(os.path.join(p, "main.or")):
                out.append((e, os.path.join(p, "main.or")))
        elif e.endswith(".or"):
            out.append((e[:-3], p))
    return out


def sh(cmd, timeout):
    try:
        r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return None, b"", b"timeout"


def build_and_run(args, name, entry, tag, extra):
    c = os.path.join(OUT, "%s.%s.c" % (name, tag))
    exe = os.path.join(OUT, "%s.%s.exe" % (name, tag))
    rc, _, err = sh([args.orinc, "compile", os.path.relpath(entry, ROOT), "-o", c] + extra, 120)
    if rc != 0:
        return ("compile-fail", err.decode("utf-8", "replace")[:300])
    cc = [args.cc, "-O1", "-w", "-I", "runtime"]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    rc, _, err = sh(cc + [c, os.path.join("runtime", "orin_runtime.c"), "-o", exe], 120)
    if rc != 0:
        return ("cc-fail", err.decode("utf-8", "replace")[:300])
    rc, out, _ = sh([os.path.join(ROOT, exe)], 10)
    return ("ok", (rc, out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--filter", default="")
    ap.add_argument("--sanitize", action="store_true")
    args = ap.parse_args()
    if not os.path.isabs(args.orinc):
        args.orinc = os.path.join(ROOT, args.orinc)
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    tests = [t for t in entries() if args.filter in t[0]]

    def work(t):
        name, entry = t
        a = build_and_run(args, name, entry, "new", [])
        b = build_and_run(args, name, entry, "old", ["--legacy-codegen"])
        return name, a, b

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(work, tests))
    diffs = 0
    for name, a, b in results:
        if a != b:
            diffs += 1
            print("DIFF %s\n   new: %s\n   old: %s" % (name, str(a)[:300], str(b)[:300]))
    print("%d programs compared, %d differences" % (len(results), diffs))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
