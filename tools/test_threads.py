#!/usr/bin/env python3
"""Thread-count equality for the parallel commands (ADR-0049 section 2): `orin test` and `orin fmt` give the same stdout,
stderr and exit status for every ORIN_THREADS; so do the parallel compiler phases (row 14, the verifier): the C output of
`orin compile compiler/main.or`, the verifier messages of the hand-built cases (compiler/tests/verify_main.or) and of the
mutants of tools/mutate_mir.py, and `orin verify` over test programs. Stdlib only.

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


def optimiser_cases(orin, threads, failures):
    """Row 15a: the optimiser's per-function steps run on the task pool; the optimised MIR and the C and LLVM output
    must not depend on ORIN_THREADS."""
    base = os.path.join(ROOT, "tests", "run")
    progs = []
    for e in sorted(os.listdir(base)):
        p = os.path.join(base, e)
        if os.path.isdir(p) and os.path.isfile(os.path.join(p, "main.or")):
            progs.append(os.path.relpath(os.path.join(p, "main.or"), ROOT))
        elif e.endswith(".or"):
            progs.append(os.path.relpath(p, ROOT))
    progs = progs[:40] + ["compiler/main.or"]
    n0 = len(failures)
    with tempfile.TemporaryDirectory(prefix="orin-threads-o-") as d:
        for rel in progs:
            for what, cmd in (("mir", [orin, "mir", rel]),
                              ("c", [orin, "compile", rel, "-o", os.path.join(d, "o-%d.c")]),
                              ("llvm", [orin, "compile", rel, "--backend=llvm", "-o", os.path.join(d, "o-%d.ll")])):
                if what != "mir" and rel != "compiler/main.or" and rel != progs[0]:
                    continue
                outs = []
                for t in threads:
                    c = [x % t if "%d" in x else x for x in cmd]
                    rc, out, err = run(c, t, ROOT)
                    if what != "mir" and rc == 0:
                        with open(c[-1], "rb") as f:
                            out = f.read()
                    outs.append((rc, out, err))
                if any(o != outs[0] for o in outs[1:]):
                    failures.append("optimiser %s %s: output differs between thread counts" % (what, rel))
    print("%-24s %d programs (mir), main.or (c, llvm), %d differences" % ("optimiser", len(progs), len(failures) - n0), flush=True)
def same(name, cmd, threads, cwd, failures, filt=None, want=None):
    """Run cmd for every thread count; the (filtered) exit status, stdout and stderr must be equal."""
    outs = []
    for t in threads:
        rc, out, err = run(cmd, t, cwd)
        outs.append((rc, filt(out) if filt else out, filt(err) if filt else err))
    if want is not None and outs[0][0] not in want:
        failures.append("%s: unexpected exit %d\n%s" % (name, outs[0][0], outs[0][2].decode(errors="replace")[:800]))
    for t, o in zip(threads[1:], outs[1:]):
        if o != outs[0]:
            failures.append("%s: ORIN_THREADS=%d differs from ORIN_THREADS=%d (exit %d vs %d)" % (name, t, threads[0], o[0], outs[0][0]))
    if not name.startswith("verify "):
        print("%-24s exit %d, %d bytes stdout, same for threads %s" % (name, outs[0][0], len(outs[0][1]), ",".join(map(str, threads))), flush=True)
    return outs[0]


def build_driver(orin, src, out):
    c = out + ".c"
    subprocess.run([orin, "compile", os.path.join(ROOT, src), "-o", c], cwd=ROOT, check=True, timeout=600)
    subprocess.run(["cc", "-O1", "-w", "-I", "runtime/core", c, "runtime/core/orin_runtime.c",
                    "runtime/platform/orin_platform.c", "-lm", "-o", out], cwd=ROOT, check=True, timeout=600)
    return out


def verifier_cases(orin, threads, mutant_programs, failures):
    """Row 14: the verifier's function loop runs on the task pool; its messages must not depend on ORIN_THREADS."""
    with tempfile.TemporaryDirectory(prefix="orin-threads-v-") as d:
        # (i) the whole compiler's C output (the verify phase runs over its ~4000 functions)
        outs = []
        for t in threads:
            c = os.path.join(d, "main-%d.c" % t)
            run([orin, "compile", "compiler/main.or", "-o", c], t, ROOT)
            with open(c, "rb") as f:
                outs.append(f.read())
        if any(o != outs[0] for o in outs[1:]):
            failures.append("compile compiler/main.or: the generated C differs between thread counts")
        print("%-24s %d bytes of C, %s" % ("C output", len(outs[0]), "identical" if all(o == outs[0] for o in outs) else "DIFFERENT"), flush=True)
        # (ii) verifier messages: hand-built broken MIR, and the mutation corpus
        vm = build_driver(orin, "compiler/tests/verify_main.or", os.path.join(d, "verify_main"))
        same("verify_main cases", [vm], threads, ROOT, failures, want=(0,))
        vt = build_driver(orin, "compiler/tests/verify_text.or", os.path.join(d, "verify_text"))
        mir = subprocess.run([orin, "mir", "compiler/main.or"], cwd=ROOT, stdout=subprocess.PIPE, check=True, timeout=600).stdout
        mf = os.path.join(d, "compiler.mir")
        with open(mf, "wb") as f:
            f.write(mir)
        same("verify_text compiler MIR", [vt, mf], threads, ROOT, failures, want=(0, 1))

        def untimed(b):
            return b"\n".join(l for l in b.split(b"\n") if not l.startswith((b"corpus:", b"time ")))
        same("mutate_mir", [sys.executable, os.path.join(ROOT, "tools/mutate_mir.py"), "--orinc", orin, "--verify-text", vt,
                            "--limit", str(mutant_programs)], threads, ROOT, failures, filt=untimed, want=(0,))
        # (iii) `orin verify` over test programs
        corpus = []
        base = os.path.join(ROOT, "tests", "run")
        for e in sorted(os.listdir(base)):
            p = os.path.join(base, e)
            if os.path.isdir(p) and os.path.isfile(os.path.join(p, "main.or")):
                corpus.append(os.path.relpath(os.path.join(p, "main.or"), ROOT))
            elif e.endswith(".or"):
                corpus.append(os.path.relpath(p, ROOT))
        corpus = corpus[:40] + ["compiler/main.or"]
        n0 = len(failures)
        for rel in corpus:
            same("verify " + rel, [orin, "verify", rel], threads, ROOT, failures)
        print("%-24s %d programs, %d differences" % ("orin verify", len(corpus), len(failures) - n0), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin2", default=os.environ.get("ORIN2", "build/bootstrap/orin2"))
    ap.add_argument("--threads", default="1,2,4,8")
    ap.add_argument("--no-optimiser", action="store_true", help="skip the optimiser cases")
    ap.add_argument("--no-verifier", action="store_true", help="skip the (slower) verifier cases")
    ap.add_argument("--mutant-programs", type=int, default=24, help="corpus programs mutated by the verifier case")
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
    if not a.no_optimiser:
        optimiser_cases(orin, threads, failures)
    if not a.no_verifier:
        verifier_cases(orin, threads, a.mutant_programs, failures)
    for f in failures:
        print("FAIL " + f, file=sys.stderr)
    print("%d failed" % len(failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
