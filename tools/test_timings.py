#!/usr/bin/env python3
"""`orin compile --timings FILE` (schema orin-timings/0.1) and tools/run_record.py (orin-runs/0.1).

  * the generated C and LLVM IR are byte-identical with and without the flag;
  * the timings document has the schema, the phases in pipeline order, non-negative whole milliseconds and a total that is their sum;
  * the flag needs the compile command (exit 2 otherwise) and a file argument; without it the clock is never read
    (ORIN_DENY=clock still compiles);
  * run_record.py writes a valid record from real timings, maps CI outcomes to the orin-reports status words and refuses unknown ones.

Usage: python3 tools/test_timings.py [--orinc build/bootstrap/orin2]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHASES = ["load", "check", "hir", "mir", "optimise", "verify", "emit"]


def run(cmd, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default="build/bootstrap/orin2")
    orinc = os.path.abspath(ap.parse_args().orinc)
    fails = []

    def check(ok, what):
        print(("ok   " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    with tempfile.TemporaryDirectory() as tmp:
        for backend, ext in (("c", "c"), ("llvm", "ll")):
            flag = ["--backend=" + backend]
            a, b, t = (os.path.join(tmp, n) for n in ("a." + ext, "b." + ext, "t-%s.json" % backend))
            r1 = run([orinc, "compile", "examples/shapes.or", "-o", a] + flag)
            r2 = run([orinc, "compile", "examples/shapes.or", "-o", b, "--timings", t] + flag)
            check(r1.returncode == 0 and r2.returncode == 0, "%s: compile with and without --timings succeeds" % backend)
            check(open(a, "rb").read() == open(b, "rb").read(), "%s: the output is byte-identical with and without --timings" % backend)
            check(r1.stdout == r2.stdout and r1.stderr == r2.stderr, "%s: stdout and stderr are unchanged" % backend)
            doc = json.load(open(t))
            check(doc.get("schema") == "orin-timings/0.1" and doc.get("backend") == backend and doc.get("entry") == "examples/shapes.or"
                  and doc.get("clock") == "monotonic-ms", "%s: schema, backend, entry and clock" % backend)
            names = [p["name"] for p in doc["phases"]]
            check(names == PHASES, "%s: phases in pipeline order: %s" % (backend, names))
            check(all(isinstance(p["ms"], int) and p["ms"] >= 0 for p in doc["phases"]) and doc["total"] == sum(p["ms"] for p in doc["phases"]),
                  "%s: whole non-negative milliseconds, total is their sum" % backend)

        # --no-opt / --no-verify keep the phase list (the skipped phase reads 0)
        t = os.path.join(tmp, "t-noopt.json")
        r = run([orinc, "compile", "examples/shapes.or", "-o", os.path.join(tmp, "n.c"), "--no-opt", "--no-verify", "--timings", t])
        doc = json.load(open(t)) if r.returncode == 0 else {"phases": []}
        check([p["name"] for p in doc["phases"]] == PHASES, "--no-opt --no-verify: the same phases are reported")

        r = run([orinc, "check", "examples/shapes.or", "--timings", os.path.join(tmp, "x.json")])
        check(r.returncode == 2 and "--timings needs the compile command" in r.stderr and not os.path.exists(os.path.join(tmp, "x.json")),
              "--timings with another command: exit 2, nothing written")
        r = run([orinc, "compile", "examples/shapes.or", "-o", os.path.join(tmp, "y.c"), "--timings"])
        check(r.returncode != 0, "--timings without a file is a usage error")
        env = dict(os.environ, ORIN_DENY="clock")
        r = run([orinc, "compile", "examples/hello.or", "-o", os.path.join(tmp, "h.c")], env=env)
        check(r.returncode == 0, "without --timings the clock is never read (ORIN_DENY=clock compiles)")

        # run_record.py
        rec = os.path.join(tmp, "rec.json")
        r = run([sys.executable, "tools/run_record.py", "--orinc", orinc, "--commit", "abc1234", "--date", "2026-10-16T00:00:00Z", "--out", rec,
                 "--build", "hello=examples/hello.or", "--build", "shapes=examples/shapes.or@llvm",
                 "--suite", "unit=success,passed=5,total=5", "--suite", "mutation=cancelled", "--suite", "proofs=unproven,passed=3,total=4"])
        check(r.returncode == 0, "run_record.py writes a record" + ("" if r.returncode == 0 else ": " + r.stdout + r.stderr))
        if r.returncode == 0:
            doc = json.load(open(rec))
            check(doc["schema"] == "orin-runs/0.1" and doc["commit"] == "abc1234" and [b["name"] for b in doc["builds"]] == ["hello", "shapes"]
                  and doc["builds"][1]["backend"] == "llvm" and [p["name"] for p in doc["builds"][0]["phases"]] == PHASES, "record: schema, commit, builds, phases")
            check([s["status"] for s in doc["suites"]] == ["passed", "timeout", "unproven"], "record: CI outcomes map to the orin-reports vocabulary")
            check(run([sys.executable, "tools/run_record.py", "--validate", rec]).returncode == 0, "record validates")
        r = run([sys.executable, "tools/run_record.py", "--orinc", orinc, "--commit", "c", "--out", os.path.join(tmp, "z.json"),
                 "--build", "hello=examples/hello.or", "--suite", "s=great"])
        check(r.returncode != 0 and "unknown status" in r.stderr, "run_record.py refuses a status outside the vocabulary")
        bad = os.path.join(tmp, "bad.json")
        json.dump({"schema": "orin-runs/0.1", "commit": "c", "date": "d", "suites": [{"name": "s", "status": "ok"}]}, open(bad, "w"))
        check(run([sys.executable, "tools/run_record.py", "--validate", bad]).returncode == 1, "--validate rejects a record with a bad status")
        fixtures = sorted(os.path.join("tooling/explorer/testdata/runs", f) for f in os.listdir(os.path.join(ROOT, "tooling/explorer/testdata/runs")))
        check(run([sys.executable, "tools/run_record.py", "--validate"] + fixtures).returncode == 0, "the explorer's fixture history validates (%d records)" % len(fixtures))

    if fails:
        print("test_timings: %d FAILED" % len(fails))
        return 1
    print("test_timings: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
