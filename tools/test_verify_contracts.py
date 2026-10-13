#!/usr/bin/env python3
"""Tests for `orin verify --contracts` (ADR-0012 phase 2; needs the z3 solver on PATH).

Usage: python3 tools/test_verify_contracts.py [--orinc build/bootstrap/orin2] [--require-z3]

Every tests/contracts/*.or lists its expected results in `// expect: <function> <kind> <STATUS>`
header lines; the test runs `verify --contracts --format=json` and compares the multiset of
(function, kind, status). It also checks the JSON shape (counterexample for REFUTED, reason for
UNKNOWN), the exit status (1 iff a clause REFUTED; `--strict`: also UNKNOWN) and that the
human-readable output works. Without z3 the test is skipped unless --require-z3 is given.
"""
import argparse
import collections
import glob
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPECT = re.compile(r"^//\s*expect:\s*(\S+)\s+(\S+)\s+(VERIFIED|REFUTED|UNKNOWN)\s*$")

checks = 0
failures = []


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)
        print("FAIL " + what)


def run(orinc, *args):
    return subprocess.run([orinc, "verify", "--contracts"] + list(args), cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=600)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--require-z3", action="store_true")
    args = ap.parse_args()
    if shutil.which("z3") is None:
        if args.require_z3:
            print("z3 not found")
            return 1
        print("test_verify_contracts: z3 not found, skipped")
        return 0
    orinc = args.orinc if os.path.isabs(args.orinc) else os.path.join(ROOT, args.orinc)
    for path in sorted(glob.glob(os.path.join(ROOT, "tests", "contracts", "*.or"))):
        rel = os.path.relpath(path, ROOT)
        want = collections.Counter()
        with open(path) as f:
            for line in f:
                m = EXPECT.match(line.strip())
                if m:
                    want[m.groups()] += 1
        r = run(orinc, "--format=json", rel)
        try:
            rep = json.loads(r.stdout.decode())
        except ValueError:
            check(False, "%s: output is not JSON: %r %r" % (rel, r.stdout[:200], r.stderr[:200]))
            continue
        got = collections.Counter((x["function"], x["kind"], x["status"]) for x in rep["results"])
        check(got == want, "%s: results differ\n  missing: %s\n  unexpected: %s" % (rel, dict(want - got), dict(got - want)))
        for x in rep["results"]:
            if x["status"] == "REFUTED":
                check(len(x["counterexample"]) > 0, "%s: REFUTED %s has no counterexample" % (rel, x["function"]))
            if x["status"] == "UNKNOWN":
                check(x["reason"] != "", "%s: UNKNOWN %s has no reason" % (rel, x["function"]))
            check(x["line"] > 0 and x["file"].endswith(".or"), "%s: result without position" % rel)
        s = rep["summary"]
        check(s["refuted"] == sum(1 for x in rep["results"] if x["status"] == "REFUTED"), "%s: summary" % rel)
        any_failed = any(x["status"] == "REFUTED" for x in rep["results"])
        any_unknown = any(x["status"] == "UNKNOWN" for x in rep["results"])
        check((r.returncode == 1) == any_failed, "%s: exit status %d" % (rel, r.returncode))
        strict = run(orinc, "--strict", "--format=json", rel)
        check((strict.returncode == 1) == (any_failed or any_unknown), "%s: --strict exit status %d" % (rel, strict.returncode))
        text = run(orinc, rel)
        check(b"verified" in text.stdout, "%s: text report" % rel)
    # Rule ids are attached to the results.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_basic.or").stdout.decode())
    check(any(x["function"] == "discount" and x["rules"] == ["SHOP-001"] for x in rep["results"]), "rule ids in results")
    # Unavailable solver: UNKNOWN with a reason, not a crash.
    r = run(orinc, "--format=json", "--z3", "/nonexistent/z3", "tests/contracts/verify_basic.or")
    rep = json.loads(r.stdout.decode())
    check(all(x["status"] == "UNKNOWN" for x in rep["results"] if x["kind"] != "decreases"), "missing solver gives UNKNOWN")
    print("test_verify_contracts: %d checks, %d failed" % (checks, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
