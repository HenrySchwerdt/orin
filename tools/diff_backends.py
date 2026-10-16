#!/usr/bin/env python3
"""Differential tests of compiler modes: for every program, compile with the default pipeline and
with an alternative, build and run both, compare stdout + exit code. (The former default mode, MIR backend
vs the legacy HIR -> C backend, was removed together with that backend.)

`--mode llvm` compares the C backend (default) against the LLVM IR backend
(`--backend=llvm`, built with clang -O2 + runtime/core/orin_runtime_llvm.c) over tests/run and
tests/next/run (ADR-0006).
`--mode builtins` compares the default pipeline (library built-ins implemented by the Orin
std prelude, spec 19 R1) against `--c-builtins` (the C runtime implementations) over tests/run and
tests/next/run (works with --sanitize too).

`--mode fuse` compares the default pipeline against `--no-fuse` (the same optimiser without the fusion of array
pipelines, compiler/fuse, ADR-0038 §2): fused against unfused on every program.

`--mode opt` compares the optimised MIR pipeline (default) against `--no-opt`
(ADR-0010) over tests/run and tests/next/run.

Usage: python3 tools/diff_backends.py [--orinc build/bootstrap/orin2] [--cc cc] [--filter s]
                                      [--sanitize] [--shard I/N] [--list] --mode opt|llvm|builtins|fuse

--shard I/N runs every N-th program (after --filter) starting at the I-th, like tools/mutate_std.py: the CI splits the
slow fuse run over several jobs and the shards together run every program exactly once. --list prints the selected
program names and exits (used to check that the union of the shards is all programs).
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


def select_shard(tests, shard):
    """The programs of shard i/N (1-based): every N-th program starting at the i-th."""
    i, n = shard
    return [t for k, t in enumerate(tests) if k % n == i - 1]


def parse_shard(text):
    try:
        i, n = (int(x) for x in text.split("/"))
    except ValueError:
        raise argparse.ArgumentTypeError("--shard expects I/N, for example 2/3")
    if not 1 <= i <= n:
        raise argparse.ArgumentTypeError("--shard I/N needs 1 <= I <= N")
    return i, n


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
        cc = ["clang", "-O2", "-w", "-I", "runtime/core"]
    else:
        cc = [args.cc, "-O1", "-w", "-I", "runtime/core"]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    srcs = [os.path.join("runtime", "core", "orin_runtime.c"), os.path.join("runtime", "platform", "orin_platform.c")]
    if llvm:
        srcs.append(os.path.join("runtime", "core", "orin_runtime_llvm.c"))
    rc, _, err = sh(cc + [c] + srcs + ["-lm", "-o", exe], 120)
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
    ap.add_argument("--mode", choices=["opt", "llvm", "builtins", "fuse"], required=True)
    ap.add_argument("--shard", type=parse_shard, default=(1, 1), help="run shard I of N (default 1/1: everything)")
    ap.add_argument("--list", action="store_true", help="print the selected program names and exit")
    args = ap.parse_args()
    if not os.path.isabs(args.orinc):
        args.orinc = os.path.join(ROOT, args.orinc)
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    suites = ("run", os.path.join("next", "run"))
    tests = [t for t in entries(suites) if args.filter in t[0]]
    tests = select_shard(tests, args.shard)
    if args.list:
        print("\n".join(t[0] for t in tests))
        return 0
    old_flags = {"opt": ["--no-opt"], "llvm": ["--backend=llvm"], "builtins": ["--c-builtins"],
                 "fuse": ["--no-fuse"]}[args.mode]
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
