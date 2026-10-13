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
WARN = re.compile(r"^//\s*warn:\s*(\S+)\s+(W\d{4})\s*$")
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
        want_warn = collections.Counter()
        with open(path) as f:
            for line in f:
                m = EXPECT.match(line.strip())
                if m:
                    want[m.groups()] += 1
                m = WARN.match(line.strip())
                if m:
                    want_warn[m.groups()] += 1
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
        got_warn = collections.Counter((w["function"], w["code"]) for w in rep["warnings"])
        check(got_warn == want_warn, "%s: quality warnings differ\n  missing: %s\n  unexpected: %s" % (rel, dict(want_warn - got_warn), dict(got_warn - want_warn)))
        for w in rep["warnings"]:
            check(w["status"] == "VERIFIED" and w["action"] == "STRENGTHEN_SPEC" and w["line"] > 0 and w["message"] != "",
                  "%s: malformed warning %r" % (rel, w))
        # ADR-0029: every result has an action, REFUTED contracts of the function itself ask a question.
        for x in rep["results"]:
            if x["status"] == "VERIFIED":
                check(x["action"] is None, "%s: VERIFIED with action" % rel)
            elif x["status"] == "UNKNOWN":
                check(x["action"] == "STRENGTHEN_SPEC" and x["question"] is None, "%s: UNKNOWN action %r" % (rel, x["action"]))
            elif x["kind"] == "call-precondition":
                check(x["action"] == "FIX_CODE", "%s: call-precondition action %r" % (rel, x["action"]))
            else:
                check(x["action"] == "NEEDS_DECISION" and x["question"] and len(x["options"]) >= 2, "%s: REFUTED needs a question" % rel)
                for o in x["options"]:
                    check(set(o) == {"edit", "changes_spec", "widens_authority"}, "%s: option keys %r" % (rel, o))
                check(any(o["widens_authority"] for o in x["options"]) and any(not o["changes_spec"] for o in x["options"]),
                      "%s: options must include a code fix and a weakening" % rel)
                check(x["evidence"]["counterexample"] == x["counterexample"], "%s: evidence" % rel)
        s = rep["summary"]
        check(s["refuted"] == sum(1 for x in rep["results"] if x["status"] == "REFUTED"), "%s: summary" % rel)
        any_failed = any(x["status"] == "REFUTED" for x in rep["results"])
        any_unknown = any(x["status"] == "UNKNOWN" for x in rep["results"])
        check((r.returncode == 1) == any_failed, "%s: exit status %d" % (rel, r.returncode))
        strict = run(orinc, "--strict", "--format=json", rel)
        check((strict.returncode == 1) == (any_failed or any_unknown), "%s: --strict exit status %d" % (rel, strict.returncode))
        text = run(orinc, rel)
        check(b"verified" in text.stdout, "%s: text report" % rel)
        if any_failed:
            check(b"action: NEEDS_DECISION" in text.stdout and b"question:" in text.stdout, "%s: text action/question" % rel)
        if want_warn:
            check(b"warning[W046" in text.stdout, "%s: text quality warnings" % rel)
    # Rule ids are attached to the results.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_basic.or").stdout.decode())
    check(any(x["function"] == "discount" and x["rules"] == ["SHOP-001"] for x in rep["results"]), "rule ids in results")
    # A REFUTED @Ensures proposes the precondition that excludes the counterexample.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/quality_vc.or").stdout.decode())
    part = [x for x in rep["results"] if x["function"] == "partial"][0]
    check(part["candidates"] == ["@Requires(!(x == 1))"], "candidate precondition: %r" % part["candidates"])
    # Unavailable solver: UNKNOWN with a reason, not a crash.
    r = run(orinc, "--format=json", "--z3", "/nonexistent/z3", "tests/contracts/verify_basic.or")
    rep = json.loads(r.stdout.decode())
    check(all(x["status"] == "UNKNOWN" for x in rep["results"] if x["kind"] != "decreases"), "missing solver gives UNKNOWN")
    print("test_verify_contracts: %d checks, %d failed" % (checks, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
