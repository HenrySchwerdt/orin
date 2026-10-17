#!/usr/bin/env python3
"""Write the run record of one CI run (schema orin-runs/0.1, ADR-0050 step "Processes with data").

A record holds the commit, the date, the per-phase compile times of a few builds (`orin compile --timings`: the compiler
compiling itself and representative programs) and the outcome of every suite the run knows, with the status vocabulary
of tooling/reports (passed, failed, unproven, timeout, regression, improvement, skipped, info). A history is just a
directory (or JSON array) of such records: the explorer's `--runs` reads it. There is no storage service; CI uploads the
one record of its commit as an artifact, and whoever wants a history collects records.

  tools/run_record.py --orinc build/bootstrap/orin2 --commit SHA [--date ISO] --out FILE
        [--build NAME=ENTRY[@llvm]]...      default: compiler=compiler/main.or, hello=examples/hello.or, shapes=examples/shapes.or
        [--suite NAME=STATUS[,passed=N][,failed=N][,total=N]]...
        STATUS is a status word or a GitHub step outcome (success -> passed, failure -> failed, cancelled -> timeout)
  tools/run_record.py --validate FILE...    exit 1 when a record does not follow the schema
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = "orin-runs/0.1"
STATUSES = ["passed", "failed", "unproven", "timeout", "regression", "improvement", "skipped", "info"]
OUTCOMES = {"success": "passed", "failure": "failed", "cancelled": "timeout"}
DEFAULT_BUILDS = ["compiler=compiler/main.or", "hello=examples/hello.or", "shapes=examples/shapes.or"]


def status_of(word):
    word = OUTCOMES.get(word, word)
    if word not in STATUSES:
        raise SystemExit("run_record: unknown status %r (one of %s, or success / failure / cancelled)" % (word, ", ".join(STATUSES)))
    return word


def parse_suite(spec):
    name, _, rest = spec.partition("=")
    if not name or not rest:
        raise SystemExit("run_record: --suite wants NAME=STATUS[,passed=N][,failed=N][,total=N]: " + spec)
    parts = rest.split(",")
    suite = {"name": name, "status": status_of(parts[0])}
    for p in parts[1:]:
        key, _, val = p.partition("=")
        if key not in ("passed", "failed", "total") or not val.isdigit():
            raise SystemExit("run_record: bad suite field %r in %s" % (p, spec))
        suite[key] = int(val)
    return suite


def measure(orinc, name, entry, backend):
    """Compile `entry` with --timings and return the build record."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out.c" if backend == "c" else "out.ll")
        timings = os.path.join(tmp, "t.json")
        cmd = [orinc, "compile", entry, "-o", out, "--timings", timings]
        if backend == "llvm":
            cmd.append("--backend=llvm")
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("run_record: %s failed (exit %d)\n%s%s" % (" ".join(cmd), r.returncode, r.stdout, r.stderr))
        with open(timings) as f:
            t = json.load(f)
    return {"name": name, "entry": entry, "backend": t["backend"], "total": t["total"], "phases": t["phases"]}


def validate(rec):
    """Problems of a record (empty: valid)."""
    bad = []
    if not isinstance(rec, dict) or not str(rec.get("schema", "")).startswith("orin-runs/"):
        return ["schema is not orin-runs/0.x"]
    for k in ("commit", "date"):
        if not isinstance(rec.get(k), str) or not rec[k]:
            bad.append(k + " missing")
    for b in rec.get("builds", []):
        if not isinstance(b.get("name"), str) or not isinstance(b.get("total"), int):
            bad.append("build without name or total")
        for p in b.get("phases", []):
            if not isinstance(p.get("name"), str) or not isinstance(p.get("ms"), int) or p["ms"] < 0:
                bad.append("bad phase in build %s" % b.get("name"))
    for s in rec.get("suites", []):
        if s.get("status") not in STATUSES:
            bad.append("suite %s: status %r is not in the vocabulary" % (s.get("name"), s.get("status")))
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--orinc", default="build/bootstrap/orin2")
    ap.add_argument("--commit")
    ap.add_argument("--date")
    ap.add_argument("--out")
    ap.add_argument("--build", action="append", default=[])
    ap.add_argument("--suite", action="append", default=[])
    ap.add_argument("--validate", nargs="+")
    a = ap.parse_args()
    if a.validate:
        failed = 0
        for p in a.validate:
            with open(p) as f:
                problems = validate(json.load(f))
            for pr in problems:
                print("%s: %s" % (p, pr), file=sys.stderr)
            failed += bool(problems)
        return 1 if failed else 0
    if not a.commit or not a.out:
        ap.error("--commit and --out are required")
    date = a.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    builds = []
    for spec in a.build or DEFAULT_BUILDS:
        name, _, entry = spec.partition("=")
        entry, _, backend = entry.partition("@")
        builds.append(measure(os.path.abspath(a.orinc), name, entry, backend or "c"))
    rec = {"schema": SCHEMA, "commit": a.commit, "date": date, "builds": builds, "suites": [parse_suite(s) for s in a.suite]}
    problems = validate(rec)
    if problems:
        raise SystemExit("run_record: " + "; ".join(problems))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(rec, f, indent=1)
        f.write("\n")
    print("run_record: wrote %s (%d builds, %d suites)" % (a.out, len(builds), len(rec["suites"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
