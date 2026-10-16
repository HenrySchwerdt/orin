#!/usr/bin/env python3
"""Thread-count equality for the parallel commands (ADR-0049 section 2): `orin test` and `orin fmt` give the same stdout,
stderr and exit status for every ORIN_THREADS. Stdlib only.

Usage: python3 tools/test_threads.py [--orin2 build/bootstrap/orin2] [--threads 1,2,4,8]
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TESTS = """import { assert, assertEqString } from "std:test";

%s
"""


def test_source():
    parts = []
    for i in range(24):
        if i % 7 == 3:
            parts.append('@Test\nfunction t%d(): void {\n  console.log("about to fail %d");\n  assert(false, "boom %d");\n}\n' % (i, i, i))
        else:
            parts.append('@Test\nfunction t%d(): void {\n  assertEqString("a" + "%d", "a%d", "t%d");\n}\n' % (i, i, i, i))
    return TESTS % "\n".join(parts)


def run(cmd, threads, cwd):
    env = dict(os.environ, ORIN_THREADS=str(threads))
    r = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    return r.returncode, r.stdout, r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin2", default=os.environ.get("ORIN2", "build/bootstrap/orin2"))
    ap.add_argument("--threads", default="1,2,4,8")
    a = ap.parse_args()
    orin = os.path.abspath(os.path.join(ROOT, a.orin2))
    threads = [int(t) for t in a.threads.split(",")]
    failures = []
    with tempfile.TemporaryDirectory(prefix="orin-threads-") as d:
        tf = os.path.join(d, "pkg_test.or")
        with open(tf, "w") as f:
            f.write(test_source())
        files = []
        for i in range(12):
            p = os.path.join(d, "f%02d.or" % i)
            body = "function  f%d( a:int ,b:int ):int{return a+b ;}\n" % i if i % 3 else "function f%d(a: int, b: int): int {\n  return a + b;\n}\n" % i
            with open(p, "w") as f:
                f.write(body)
            files.append(p)
        bad = os.path.join(d, "bad.or")
        with open(bad, "w") as f:
            f.write("function (\n")
        files.insert(5, bad)
        files.insert(8, os.path.join(d, "missing.or"))
        cases = [
            ("test", [orin, "test", tf, "--runtime", os.path.join(ROOT, "runtime/core")], 1),
            ("test --format=json", [orin, "test", tf, "--format=json", "--runtime", os.path.join(ROOT, "runtime/core")], 1),
            ("test --filter", [orin, "test", tf, "--filter", "t1", "--runtime", os.path.join(ROOT, "runtime/core")], 1),
            ("fmt --check", [orin, "fmt", "--check"] + files, 2),
            ("fmt --stdout", [orin, "fmt", "--stdout"] + files, 2),
        ]
        for name, cmd, want in cases:
            base = run(cmd, threads[0], d)
            if base[0] != want and not (name == "test --filter" and base[0] == 0):
                failures.append("%s: unexpected exit %d (wanted %d)\n%s" % (name, base[0], want, base[2].decode()))
            for t in threads[1:]:
                got = run(cmd, t, d)
                if got != base:
                    failures.append("%s: ORIN_THREADS=%d differs from ORIN_THREADS=%d (exit %d vs %d)" % (name, t, threads[0], got[0], base[0]))
            print("%-20s exit %d, %d bytes stdout, same for threads %s" % (name, base[0], len(base[1]), a.threads), flush=True)
        # fmt that writes leaves identical files for every thread count
        results = []
        for t in threads:
            sub = tempfile.mkdtemp(prefix="w%d-" % t, dir=d)
            cp = []
            for p in files:
                if os.path.exists(p):
                    q = os.path.join(sub, os.path.basename(p))
                    with open(p) as f, open(q, "w") as g:
                        g.write(f.read())
                    cp.append(q)
                else:
                    cp.append(os.path.join(sub, os.path.basename(p)))
            rc, out, err = run([orin, "fmt"] + cp, t, d)
            text = [open(q).read() if os.path.exists(q) else None for q in cp]
            results.append((rc, text, err.decode().replace(sub, "SUB")))
        if any(r != results[0] for r in results[1:]):
            failures.append("fmt (in place): results differ between thread counts")
        print("%-20s exit %d, same files for threads %s" % ("fmt (in place)", results[0][0], a.threads))
    for f in failures:
        print("FAIL " + f, file=sys.stderr)
    print("%d failed" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
