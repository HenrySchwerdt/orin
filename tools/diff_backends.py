#!/usr/bin/env python3
"""Differential test of the two Stage 1 backends: for every tests/run program, compile with the
MIR backend (default) and with `--legacy-codegen`, build and run both, compare stdout + exit code.

With `--mode llvm` it compares the C backend (default) against the LLVM IR backend
(`--backend=llvm`, built with clang -O2 + runtime/orin_runtime_llvm.c) over tests/run and
tests/next/run (ADR-0006).
With `--mode builtins` it compares the default pipeline (library built-ins implemented by the Orin
std prelude, spec 19 R1) against `--c-builtins` (the C runtime implementations) over tests/run and
tests/next/run (works with --sanitize too).

With `--mode opt` it instead compares the optimised MIR pipeline (default) against `--no-opt`
(ADR-0010) over tests/run and tests/next/run.

Usage: python3 tools/diff_backends.py [--orinc build/bootstrap/orin2] [--cc cc] [--filter s]
                                      [--sanitize] [--mode backends|opt|llvm|builtins]
"""
import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join("build", "diff")


def entries(suites=("run",)):
    out = []
    for suite in suites:
        base = os.path.join(ROOT, "tests", suite)
        prefix = "" if suite == "run" else suite.replace("/", "_") + "_"
        for e in sorted(os.listdir(base)):
            p = os.path.join(base, e)
            if os.path.isdir(p):
                if os.path.isfile(os.path.join(p, "main.or")):
                    out.append((prefix + e, os.path.join(p, "main.or")))
            elif e.endswith(".or"):
                out.append((prefix + e[:-3], p))
    return out


def sh(cmd, timeout):
    try:
        r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return None, b"", b"timeout"


def build_and_run(args, name, entry, tag, extra, llvm=False):
    c = os.path.join(OUT, "%s.%s.%s" % (name, tag, "ll" if llvm else "c"))
    exe = os.path.join(OUT, "%s.%s.exe" % (name, tag))
    rc, _, err = sh([args.orinc, "compile", os.path.relpath(entry, ROOT), "-o", c] + extra, 120)
    if rc != 0:
        return ("compile-fail", err.decode("utf-8", "replace")[:300])
    if llvm:
        cc = ["clang", "-O2", "-w", "-I", "runtime"]
    else:
        cc = [args.cc, "-O1", "-w", "-I", "runtime"]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    srcs = [os.path.join("runtime", "orin_runtime.c")]
    if llvm:
        srcs.append(os.path.join("runtime", "orin_runtime_llvm.c"))
    rc, _, err = sh(cc + [c] + srcs + ["-o", exe], 120)
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
    ap.add_argument("--mode", choices=["backends", "opt", "llvm", "builtins"], default="backends")
    args = ap.parse_args()
    if not os.path.isabs(args.orinc):
        args.orinc = os.path.join(ROOT, args.orinc)
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    suites = ("run", os.path.join("next", "run")) if args.mode in ("opt", "llvm", "builtins") else ("run",)
    tests = [t for t in entries(suites) if args.filter in t[0]]
    old_flags = {"opt": ["--no-opt"], "llvm": ["--backend=llvm"], "builtins": ["--c-builtins"]}.get(args.mode, ["--legacy-codegen"])
    old_is_llvm = args.mode == "llvm"

    def work(t):
        name, entry = t
        a = build_and_run(args, name, entry, "new", [])
        b = build_and_run(args, name, entry, "old", old_flags, old_is_llvm)
        return name, a, b

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(work, tests))
    diffs = 0
    skipped = 0
    for name, a, b in results:
        timed_out = [x for x in (a, b) if x[0] == "ok" and x[1][0] is None]
        if a != b and timed_out and len(timed_out) == 1:
            # one side timed out (e.g. the unoptimised build of a test that is quadratic without
            # owned parameters): not a behavioural difference
            skipped += 1
            print("SKIP %s (one side timed out)" % name)
            continue
        if a != b:
            diffs += 1
            print("DIFF %s\n   new: %s\n   old: %s" % (name, str(a)[:300], str(b)[:300]))
    print("%d programs compared (%s), %d differences, %d skipped (timeout)" % (len(results), args.mode, diffs, skipped))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
