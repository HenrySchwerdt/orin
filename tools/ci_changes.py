#!/usr/bin/env python3
"""Decide which CI jobs a change needs (.github/workflows/ci.yml, `changes` job).

The decision is by *kind* of change, not only by path, because the compiler compiles the std and the
std is embedded in the compiler:

  docs only (docs/**, *.md outside stdlib/)      -> no build, no test jobs
  editors/vscode/**                              -> the vscode job
  stdlib/<m>.or, tests/std/<m>*                  -> build + all test jobs, std mutants of <m> only
  compiler/, runtime/, platform/, seed/, tools/  -> build + all test jobs (+ macOS); std mutants only
                                                    for modules whose source or tests changed
  tools/mutate_std.py, tests/std/spec_sorted.or,
  tests/std/expect_trap/**, the workflow itself  -> all std mutants

A push to main, a scheduled run and a manual run select everything (the safety net for this filter).

Prints `key=value` lines for $GITHUB_OUTPUT (`mutant_jobs`: the std-mutants matrix, the slow modules split into shards). `--selftest` checks the rules on examples.
Usage: python3 tools/ci_changes.py [--base SHA] [--all] [--selftest]
"""
import json
import subprocess
import sys

MODULES = ["bytes", "utf8", "collections", "http", "net", "text", "taskcore"]
# modules whose mutants are split over several CI jobs (tools/mutate_std.py --shard I/N): the http mutants run the slow
# property tests, about 15 minutes on one runner
SHARDS = {"http": 3}
ALL_MUTANTS = ["tools/mutate_std.py", "tests/std/spec_sorted.or", ".github/workflows/ci.yml"]
MACOS = ("compiler/", "runtime/", "platform/", "seed/", "tools/", ".github/")


def is_doc(f):
    if f.startswith("stdlib/"):
        return False
    return f.startswith("docs/") or f.endswith(".md") or f in ("LICENSE", "NOTICE", ".gitignore")


def decide(files, everything=False):
    if everything:
        return {"code": True, "macos": True, "vscode": True, "mutants": list(MODULES)}
    code = any(not is_doc(f) and not f.startswith("editors/") for f in files)
    vscode = any(f.startswith("editors/vscode/") for f in files)
    macos = any(f.startswith(MACOS) for f in files)
    if any(f in ALL_MUTANTS or f.startswith("tests/std/expect_trap/") for f in files):
        mutants = list(MODULES)
    else:
        mutants = [m for m in MODULES
                   if any(f == "stdlib/%s.or" % m or f.startswith("tests/std/%s" % m) for f in files)]
    return {"code": code, "macos": macos, "vscode": vscode, "mutants": mutants}


def mutant_jobs(mutants):
    """The std-mutants matrix: one {module, shard} entry per job; the shards of a module together run all its mutants."""
    return [{"module": m, "shard": "%d/%d" % (i, SHARDS.get(m, 1))} for m in mutants for i in range(1, SHARDS.get(m, 1) + 1)]


def selftest():
    cases = [
        (["docs/roadmap.md"], {"code": False, "macos": False, "vscode": False, "mutants": []}),
        (["README.md", "docs/decisions/0040-x.md"], {"code": False, "macos": False, "vscode": False, "mutants": []}),
        (["stdlib/text.or", "tests/std/text_test.or"], {"code": True, "macos": False, "vscode": False, "mutants": ["text"]}),
        (["stdlib/README.md"], {"code": True, "macos": False, "vscode": False, "mutants": []}),
        (["compiler/lower/ops.or"], {"code": True, "macos": True, "vscode": False, "mutants": []}),
        (["tests/std/http_prop_test.or"], {"code": True, "macos": False, "vscode": False, "mutants": ["http"]}),
        (["tools/mutate_std.py"], {"code": True, "macos": True, "vscode": False, "mutants": list(MODULES)}),
        (["editors/vscode/package.json"], {"code": False, "macos": False, "vscode": True, "mutants": []}),
        (["platform/orin_platform.c", "stdlib/net.or"], {"code": True, "macos": True, "vscode": False, "mutants": ["net"]}),
    ]
    bad = 0
    for files, want in cases:
        got = decide(files)
        if got != want:
            print("FAIL %s: got %s, want %s" % (files, got, want))
            bad += 1
    jobs = mutant_jobs(["bytes", "http"])
    if jobs != [{"module": "bytes", "shard": "1/1"}, {"module": "http", "shard": "1/3"}, {"module": "http", "shard": "2/3"},
                {"module": "http", "shard": "3/3"}] or mutant_jobs([]) != []:
        print("FAIL mutant_jobs: %s" % jobs)
        bad += 1
    full = decide([], everything=True)
    if not (full["code"] and full["macos"] and full["vscode"] and full["mutants"] == MODULES):
        print("FAIL everything")
        bad += 1
    print("ci_changes selftest: %d cases, %d failed" % (len(cases) + 2, bad))
    return 1 if bad else 0


def main():
    args = sys.argv[1:]
    if "--selftest" in args:
        return selftest()
    everything = "--all" in args
    files = []
    if not everything:
        base = args[args.index("--base") + 1] if "--base" in args else ""
        if not base:
            everything = True
        else:
            out = subprocess.run(["git", "diff", "--name-only", base + "...HEAD"], stdout=subprocess.PIPE,
                                 check=True).stdout.decode()
            files = [l for l in out.splitlines() if l]
    d = decide(files, everything)
    sys.stderr.write("changed files: %d; decision: %s\n" % (len(files), json.dumps(d)))
    print("code=%s" % str(d["code"]).lower())
    print("macos=%s" % str(d["macos"]).lower())
    print("vscode=%s" % str(d["vscode"]).lower())
    print("mutants=%s" % json.dumps(d["mutants"]))
    print("mutant_jobs=%s" % json.dumps(mutant_jobs(d["mutants"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
