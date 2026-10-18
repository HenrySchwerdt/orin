#!/usr/bin/env python3
"""Tests for `orin verify --contracts` (ADR-0012 phase 2, ADR-0031 B/C, ADR-0036; needs the z3 solver on PATH).

Usage: python3 tools/test_verify_contracts.py [--orinc build/bootstrap/orin2] [--require-z3] [-j N]

Every tests/contracts/*.or lists its expected results in `// expect: <function> <kind> <STATUS>`
header lines; the test runs `verify --contracts --format=json` and compares the multiset of
(function, kind, status). It also checks the JSON shape (counterexample for REFUTED, reason for
UNKNOWN), the exit status (1 iff a clause REFUTED; `--strict`: also UNKNOWN) and that the
human-readable output works. Without z3 the test is skipped unless --require-z3 is given.

The files cover one construct each, with VERIFIED, REFUTED (with counterexample) and UNKNOWN (with reason) cases:
verify_basic (int / bool, modular calls), verify_int_widths (exact ranges), verify_arrays (sequences, bounds),
verify_data (records, Option, Result, unions, Map, strings), verify_methods (axioms for `sort`, `find`, `findIndex`, `reduce`, `split`, `indexOf`: compiler/vc/methods.or), verify_classes (invariants per method, constructors,
frames, modular method calls), verify_loops (inferred bounds, user invariants, havoc, unrolling), verify_quantifiers
(every / some / range, sorted, no duplicates, conservation, totals), verify_generics, verify_forof (`for .. of` invariants with `loopIndex`), verify_try (`?` as an early return and
mutating calls inside expressions, hoisted in evaluation order), verify_rectypes (recursive records, classes and unions: accessors, built values, variant tags; wrong claims are UNKNOWN), verify_soundness (places where a
careless encoding gives a wrong status), quality_vc (W046x), names/ (two units declaring the same function and type names:
each call and type is resolved in the scope of its own unit). Run with the contract-checked compiler in CI
(tools/test_compiler_contracts.sh), so the verifier's own contracts are exercised too.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parallel import add_jobs_arg, ordered_map  # noqa: E402

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


def run(orinc, *args, case, env=None):
    """`orin verify --contracts ARGS` with the working directory build/verify_contracts/CASE: the verifier writes its
    solver queries to build/contracts-vc/ under the working directory, so cases running at the same time need their own.
    Paths in ARGS are relative to ROOT."""
    cwd = os.path.join(ROOT, "build", "verify_contracts", case)
    os.makedirs(cwd, exist_ok=True)
    args = [os.path.join(ROOT, a) if a.endswith(".or") else a for a in args]
    return subprocess.run([orinc, "verify", "--contracts"] + args, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=600, env=dict(os.environ, **env) if env else None)


def check_file(orinc, path):
    """The checks of one tests/contracts file, as a list of (condition, description)."""
    out = []
    check = lambda cond, what: out.append((bool(cond), what))  # noqa: E731
    rel = os.path.relpath(path, ROOT)
    case = os.path.basename(path)[:-3]
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
    r = run(orinc, "--format=json", rel, case=case)
    try:
        rep = json.loads(r.stdout.decode())
    except ValueError:
        check(False, "%s: output is not JSON: %r %r" % (rel, r.stdout[:200], r.stderr[:200]))
        return out
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
            # a violated contract can be weakened (the spec side); an index or unwrap that can fail has no clause to weaken
            weak = x["kind"] in ("ensures", "invariant")
            check(any(not o["changes_spec"] for o in x["options"]) and (not weak or any(o["widens_authority"] for o in x["options"])),
                  "%s: options must include a code fix%s" % (rel, " and a weakening" if weak else ""))
            check(x["evidence"]["counterexample"] == x["counterexample"], "%s: evidence" % rel)
    s = rep["summary"]
    check(s["refuted"] == sum(1 for x in rep["results"] if x["status"] == "REFUTED"), "%s: summary" % rel)
    any_failed = any(x["status"] == "REFUTED" for x in rep["results"])
    any_unknown = any(x["status"] == "UNKNOWN" for x in rep["results"])
    check((r.returncode == 1) == any_failed, "%s: exit status %d" % (rel, r.returncode))
    strict = run(orinc, "--strict", "--format=json", rel, case=case)
    check((strict.returncode == 1) == (any_failed or any_unknown), "%s: --strict exit status %d" % (rel, strict.returncode))
    text = run(orinc, rel, case=case)
    check(b"verified" in text.stdout, "%s: text report" % rel)
    if any_failed:
        check(b"action: NEEDS_DECISION" in text.stdout and b"question:" in text.stdout, "%s: text action/question" % rel)
    if want_warn:
        check(b"warning[W046" in text.stdout, "%s: text quality warnings" % rel)
    return out


def check_extras(orinc):
    """Rule ids, candidate preconditions and a missing solver."""
    out = []
    check = lambda cond, what: out.append((bool(cond), what))  # noqa: E731
    # The methods of compiler/vc/methods.or are modelled: no result gives up with "is not supported" (ADR-0053 Addendum A, U8).
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_methods.or", case="_extras").stdout.decode())
    check(len(rep["results"]) > 0 and not any("is not supported" in x["reason"] for x in rep["results"]),
          "verify_methods: a method is reported as not supported")
    # Rule ids are attached to the results.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_basic.or", case="_extras").stdout.decode())
    check(any(x["function"] == "discount" and x["rules"] == ["SHOP-001"] for x in rep["results"]), "rule ids in results")
    # A REFUTED @Ensures proposes the precondition that excludes the counterexample.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/quality_vc.or", case="_extras").stdout.decode())
    part = [x for x in rep["results"] if x["function"] == "partial"][0]
    check(part["candidates"] == ["@Requires(!(x == 1))"], "candidate precondition: %r" % part["candidates"])
    # `?` is an early return: a claim that is wrong on that path is never VERIFIED, whatever the expect lines say.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_try.or", case="_extras").stdout.decode())
    wrong = {"pass_on_wrong", "pass_err_wrong", "chain_wrong", "in_return_wrong", "in_condition_wrong", "shortcut", "branch_arm",
             "Cursor.run2Ok", "Cursor.run2Moves", "Cursor.minusWrongOrder", "Cursor.readBeforeWrong", "Cursor.armEffectWrong", "drain_two_wrong", "Gauge.bad"}
    seen = [x for x in rep["results"] if x["function"] in wrong and (x["kind"] == "ensures" or x["function"] == "Gauge.bad")]
    check({x["function"] for x in seen} == wrong, "verify_try: wrong claims not all reported: %r" % sorted(wrong - {x["function"] for x in seen}))
    check(all(x["status"] != "VERIFIED" for x in seen), "verify_try: a wrong claim is VERIFIED: %r" % [x["function"] for x in seen if x["status"] == "VERIFIED"])
    # `for .. of` invariants (`loopIndex`): a wrong claim is never VERIFIED, and a wrong invariant is not VERIFIED on both obligations.
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_forof.or", case="_extras").stdout.decode())
    wrong = {"is_sorted_wrong", "wrong_entry", "wrong_step", "wrong_claim", "wrong_exit", "wrong_elem", "with_break", "pos_wrong"}
    seen = [x for x in rep["results"] if x["function"] in wrong and x["kind"] == "ensures"]
    check({x["function"] for x in seen} == wrong, "verify_forof: wrong claims not all reported: %r" % sorted(wrong - {x["function"] for x in seen}))
    check(all(x["status"] != "VERIFIED" for x in seen), "verify_forof: a wrong claim is VERIFIED: %r" % [x["function"] for x in seen if x["status"] == "VERIFIED"])
    for f in ("wrong_entry", "wrong_step", "wrong_exit", "wrong_elem"):
        inv = [x for x in rep["results"] if x["function"] == f and x["kind"] == "loop-invariant"]
        check(any(x["status"] != "VERIFIED" for x in inv), "verify_forof: the wrong invariant of %s is VERIFIED" % f)
    # Recursive types: a wrong claim is never VERIFIED (and, as a model of the solver need not be a finite value, never REFUTED).
    rep = json.loads(run(orinc, "--format=json", "tests/contracts/verify_rectypes.or", case="_extras").stdout.decode())
    wrong = {"rootValueWrong", "setValueWrong", "setValueWrongFrame", "makeLeafWrong", "sameValue", "aliasFree", "mutualWrong", "depthWrong",
             "negIsLitWrong", "litRoundTripWrong", "unconstrained", "fnArityWrong", "Scope.setParentWrong", "useScopeWrong"}
    seen = [x for x in rep["results"] if x["function"] in wrong and x["kind"] == "ensures"]
    check({x["function"] for x in seen} == wrong, "verify_rectypes: wrong claims not all reported: %r" % sorted(wrong - {x["function"] for x in seen}))
    check(all(x["status"] == "UNKNOWN" for x in seen), "verify_rectypes: a wrong claim is not UNKNOWN: %r" % [x["function"] for x in seen if x["status"] != "UNKNOWN"])
    # Unavailable solver: UNKNOWN with a reason, not a crash.
    r = run(orinc, "--format=json", "--z3", "/nonexistent/z3", "tests/contracts/verify_basic.or", case="_extras")
    rep = json.loads(r.stdout.decode())
    check(all(x["status"] == "UNKNOWN" for x in rep["results"] if x["kind"] != "decreases"), "missing solver gives UNKNOWN")
    # Solver budget flags: accepted, same statuses as the defaults; a bad value is a usage error.
    base = json.loads(run(orinc, "--format=json", "tests/contracts/verify_basic.or", case="_extras").stdout.decode())
    want = [(x["function"], x["kind"], x["line"], x["status"]) for x in base["results"]]
    for flags in (["--timeout-ms", "3000", "--retry-ms", "0"], ["--timeout-ms", "3000", "--rlimit", "5000000"]):
        r = run(orinc, "--format=json", *flags, "tests/contracts/verify_basic.or", case="_extras")
        got = [(x["function"], x["kind"], x["line"], x["status"]) for x in json.loads(r.stdout.decode())["results"]]
        check(got == want, "solver budget flags %s keep the statuses" % flags)
    for bad in (["--timeout-ms", "0"], ["--timeout-ms", "x"], ["--retry-ms"], ["--rlimit", "-1"]):
        r = run(orinc, *bad, "tests/contracts/verify_basic.or", case="_extras")
        check(r.returncode == 2 and b"error: " + bad[0].encode() in r.stderr, "bad %s is a usage error" % bad)
    out += check_cache(orinc)
    return out


def check_cache(orinc):
    """The persistent answer cache (`--cache-dir`, `--cache-unknown`), `--solver-stats` and the thread count (docs/contracts.md, performance)."""
    out = []
    check = lambda cond, what: out.append((bool(cond), what))  # noqa: E731
    src = "tests/contracts/verify_data.or"  # sat (with models) and unsat answers

    def key(r):
        return sorted((x["function"], x["kind"], x["line"], x["clause"], x["status"], x["reason"], tuple(x["counterexample"])) for x in json.loads(r.stdout.decode())["results"])

    def stat(r):
        m = re.search(rb"solver: (\d+) queries solved \((\d+) from the cache, (\d+) by the solver\)", r.stderr)
        return tuple(int(v) for v in m.groups()) if m else None

    work = os.path.join(ROOT, "build", "verify_contracts", "_cache")
    shutil.rmtree(work, ignore_errors=True)
    cache = os.path.join(work, "answers")
    plain = run(orinc, "--format=json", src, case="_cache")
    # a cold cache solves everything and stores it; a warm one answers every query and changes nothing, on one thread and on four
    cold = run(orinc, "--format=json", "--solver-stats", "--cache-dir", cache, src, case="_cache", env={"ORIN_THREADS": "4"})
    check(key(cold) == key(plain), "cache: a cold cache changes a result")
    n, hits, ran = stat(cold) or (0, -1, -1)
    check(n > 0 and hits == 0 and ran == n, "cache: cold run statistics %r" % (stat(cold),))
    check(len(os.listdir(cache)) > 0 and not any(f.startswith(".tmp") for f in os.listdir(cache)), "cache: entries stored")
    for threads in ("1", "4"):
        warm = run(orinc, "--format=json", "--solver-stats", "--cache-dir", cache, src, case="_cache", env={"ORIN_THREADS": threads})
        check(key(warm) == key(plain), "cache: a warm cache (ORIN_THREADS=%s) changes a result (counterexamples included)" % threads)
        w = stat(warm) or (0, 0, -1)
        check(w[0] > 0 and w[2] == 0 and w[1] == w[0], "cache: warm run (ORIN_THREADS=%s) statistics %r" % (threads, stat(warm)))
    # the limits are part of the key
    other = run(orinc, "--format=json", "--solver-stats", "--cache-dir", cache, "--timeout-ms", "3999", src, case="_cache")
    check(key(other) == key(plain) and (stat(other) or (0, 1, 0))[1] == 0, "cache: another time limit must not hit")
    # a solver that only says `unknown`: not stored without --cache-unknown (it depends on the machine), stored with it
    fake = os.path.join(work, "fake_z3.sh")
    os.makedirs(work, exist_ok=True)
    with open(fake, "w") as f:
        f.write('#!/bin/sh\ncase "$1" in --version) echo "Z3 fake 1.0"; exit 0;; esac\ncat > /dev/null\necho unknown\n')
    os.chmod(fake, 0o755)
    ucache = os.path.join(work, "unknown")
    for _ in (1, 2):
        r = run(orinc, "--format=json", "--solver-stats", "--z3", fake, "--cache-dir", ucache, src, case="_cache")
        check(all(x["status"] == "UNKNOWN" for x in json.loads(r.stdout.decode())["results"] if x["kind"] != "decreases") and (stat(r) or (0, 1, 0))[1] == 0,
              "cache: unknown answers are not stored by default")
    run(orinc, "--format=json", "--z3", fake, "--cache-dir", ucache, "--cache-unknown", src, case="_cache")
    r = run(orinc, "--format=json", "--solver-stats", "--z3", fake, "--cache-dir", ucache, "--cache-unknown", src, case="_cache")
    s = stat(r) or (0, 0, 1)
    check(s[0] > 0 and s[2] == 0, "cache: --cache-unknown stores unknown answers %r" % (s,))
    # another solver version is another key
    with open(fake, "w") as f:
        f.write('#!/bin/sh\ncase "$1" in --version) echo "Z3 fake 2.0"; exit 0;; esac\ncat > /dev/null\necho unknown\n')
    r = run(orinc, "--format=json", "--solver-stats", "--z3", fake, "--cache-dir", ucache, "--cache-unknown", src, case="_cache")
    check((stat(r) or (0, 1, 0))[1] == 0, "cache: another solver version must not hit")
    # a missing solver stays UNKNOWN with a cache directory, and nothing is stored for it
    gone = os.path.join(work, "gone")
    r = run(orinc, "--format=json", "--z3", "/nonexistent/z3", "--cache-dir", gone, "--cache-unknown", src, case="_cache")
    check(all(x["status"] == "UNKNOWN" for x in json.loads(r.stdout.decode())["results"] if x["kind"] != "decreases") and not os.path.isdir(gone),
          "cache: a missing solver gives UNKNOWN and stores nothing")
    r = run(orinc, "--cache-dir", case="_cache")
    check(r.returncode == 2 and b"--cache-dir" in r.stderr, "cache: --cache-dir without a directory is a usage error")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--require-z3", action="store_true")
    add_jobs_arg(ap)
    args = ap.parse_args()
    if shutil.which("z3") is None:
        if args.require_z3:
            print("z3 not found")
            return 1
        print("test_verify_contracts: z3 not found, skipped")
        return 0
    orinc = args.orinc if os.path.isabs(args.orinc) else os.path.join(ROOT, args.orinc)
    paths = sorted(glob.glob(os.path.join(ROOT, "tests", "contracts", "*.or")))
    # multi-unit fixtures: the entry file lists the expected results of every unit it loads
    paths += [os.path.join(ROOT, "tests", "contracts", "names", "main.or")]
    # every file is an independent set of `orin verify` runs; the checks are reported in file order whatever -j
    cases = [lambda p=p: check_file(orinc, p) for p in paths] + [lambda: check_extras(orinc)]
    for results in ordered_map(lambda case: case(), cases, args.jobs):
        for cond, what in results:
            check(cond, what)
    print("test_verify_contracts: %d checks, %d failed" % (checks, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
