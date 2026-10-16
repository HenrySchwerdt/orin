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

Independent C/LLVM oracle checks select encoding/jsonnumber/jsonvalue/jsondecode/url for their source, tests or runners;
shared compiler/runtime/prelude inputs select all five. Selected checks also enable macOS.
No timing benchmarks run in CI.

A push to main, a scheduled run and a manual run select everything (the safety net for this filter).

Prints `key=value` lines for $GITHUB_OUTPUT (`mutant_jobs`: the std-mutants matrix, the slow modules split into shards). `--selftest` checks the rules on examples.
Usage: python3 tools/ci_changes.py [--base SHA] [--all] [--selftest]
"""
import json
import subprocess
import sys

MODULES = ["bytes", "utf8", "collections", "http", "net", "text", "html", "taskcore"]
# modules whose mutants are split over several CI jobs (tools/mutate_std.py --shard I/N): the http mutants run the slow
# property tests, about 15 minutes on one runner
SHARDS = {"http": 3}
# std modules that only declare types for another module's tests (stdlib/ox.or: the OX provider types std:html uses)
DEPENDENTS = {"stdlib/ox.or": "html"}
ALL_MUTANTS = ["tools/mutate_std.py", "tests/std/spec_sorted.or", ".github/workflows/ci.yml"]
MACOS = ("compiler/", "runtime/", "platform/", "seed/", "tools/", ".github/")


def is_doc(f):
    if f.startswith("stdlib/"):
        return False
    return f.startswith("docs/") or f.endswith(".md") or f in ("LICENSE", "NOTICE", ".gitignore")


# Independent oracle/backend runners are intentionally separate from the C-only std @Test job.
STD_BACKEND_CHECKS = ["encoding", "jsonnumber", "jsonvalue", "jsondecode", "url"]
# Transitive source dependencies and Python harness reuse; output follows STD_BACKEND_CHECKS order.
BACKEND_DEPENDENTS = {
    "stdlib/jsonnumber.or": ["jsonvalue", "jsondecode"],
    "stdlib/jsonvalue.or": ["jsondecode"],
    "stdlib/utf8.or": ["jsonvalue", "jsondecode", "url"],
    "tools/check_jsonvalue.py": ["jsondecode"],
    "examples/json_config.or": ["jsondecode"],
}


def std_backend_checks(files):
    files = [f for f in files if not is_doc(f)]
    shared = ("compiler/", "runtime/", "platform/", "seed/", "std/", "array/")
    if any(f.startswith(shared) or f in (
            "stdlib/bytes.or", "stdlib/test.or", "tools/bootstrap.sh", "tools/embed_prelude.py", "tools/ci_changes.py",
            "tools/test_std.sh", ".github/workflows/ci.yml") for f in files):
        return list(STD_BACKEND_CHECKS)
    selected = []
    for module in STD_BACKEND_CHECKS:
        runner = "bench/url/check.py" if module == "url" else f"tools/check_{module}.py"
        if any(f == f"stdlib/{module}.or" or f.startswith(f"tests/std/{module}")
               or f == runner or module in BACKEND_DEPENDENTS.get(f, []) for f in files):
            selected.append(module)
    return selected


def decide(files, everything=False):
    if everything:
        return {"code": True, "macos": True, "vscode": True, "mutants": list(MODULES),
                "std_backend_checks": list(STD_BACKEND_CHECKS)}
    code = any(not is_doc(f) and not f.startswith("editors/") for f in files)
    vscode = any(f.startswith("editors/vscode/") for f in files)
    checks = std_backend_checks(files)
    macos = any(f.startswith(MACOS) for f in files) or bool(checks)
    if any(f in ALL_MUTANTS or f.startswith("tests/std/expect_trap/") for f in files):
        mutants = list(MODULES)
    else:
        mutants = [m for m in MODULES
                   if any(f == "stdlib/%s.or" % m or f.startswith("tests/std/%s" % m) or DEPENDENTS.get(f) == m
                          for f in files)]
    return {"code": code, "macos": macos, "vscode": vscode, "mutants": mutants,
            "std_backend_checks": checks}


def mutant_jobs(mutants):
    """The std-mutants matrix: one {module, shard} entry per job; the shards of a module together run all its mutants."""
    return [{"module": m, "shard": "%d/%d" % (i, SHARDS.get(m, 1))} for m in mutants for i in range(1, SHARDS.get(m, 1) + 1)]


def selftest():
    cases = [
        (["docs/roadmap.md"], {"code": False, "macos": False, "vscode": False, "mutants": []}),
        (["README.md", "docs/decisions/0040-x.md"], {"code": False, "macos": False, "vscode": False, "mutants": []}),
        (["stdlib/text.or", "tests/std/text_test.or"], {"code": True, "macos": False, "vscode": False, "mutants": ["text"]}),
        (["stdlib/ox.or"], {"code": True, "macos": False, "vscode": False, "mutants": ["html"]}),
        (["stdlib/README.md"], {"code": True, "macos": False, "vscode": False, "mutants": []}),
        (["compiler/lower/ops.or"], {"code": True, "macos": True, "vscode": False, "mutants": []}),
        (["tests/std/http_prop_test.or"], {"code": True, "macos": False, "vscode": False, "mutants": ["http"]}),
        (["tools/mutate_std.py"], {"code": True, "macos": True, "vscode": False, "mutants": list(MODULES)}),
        (["editors/vscode/package.json"], {"code": False, "macos": False, "vscode": True, "mutants": []}),
        (["platform/orin_platform.c", "stdlib/net.or"], {"code": True, "macos": True, "vscode": False, "mutants": ["net"]}),
    ]
    all_backend_checks = ["encoding", "jsonnumber", "jsonvalue", "jsondecode", "url"]
    for files, want in cases:
        want["std_backend_checks"] = (all_backend_checks if any(
            f.startswith(("compiler/", "runtime/", "platform/")) for f in files) else [])
    for module, runner in [("encoding", "tools/check_encoding.py"),
                           ("jsonnumber", "tools/check_jsonnumber.py"),
                           ("url", "bench/url/check.py")]:
        for file in [f"stdlib/{module}.or", f"tests/std/{module}_test.or", runner]:
            cases.append(([file], {"code": True, "macos": True, "vscode": False,
                                   "mutants": [], "std_backend_checks": (["jsonnumber", "jsonvalue", "jsondecode"]
                                       if file == "stdlib/jsonnumber.or" else [module])}))
    for file in ["stdlib/bytes.or", "compiler/loader/embedded_stdlib.or", "std/string.or",
                 "array/core.or", "seed/SEED_INFO", "tools/bootstrap.sh", "tools/embed_prelude.py",
                 "tools/ci_changes.py", ".github/workflows/ci.yml"]:
        mutants = ["bytes"] if file == "stdlib/bytes.or" else (list(MODULES) if file == ".github/workflows/ci.yml" else [])
        cases.append(([file], {"code": True, "macos": True, "vscode": False,
                               "mutants": mutants, "std_backend_checks": all_backend_checks}))
    cases.append((["stdlib/utf8.or"], {"code": True, "macos": True, "vscode": False,
                                       "mutants": ["utf8"], "std_backend_checks": ["jsonvalue", "jsondecode", "url"]}))
    cases.append((["docs/std-encoding.md", "bench/url/README.md"], {
        "code": False, "macos": False, "vscode": False, "mutants": [], "std_backend_checks": []}))
    cases.append((["stdlib/encoding.or", "tests/std/url_test.or", "tools/check_encoding.py"], {
        "code": True, "macos": True, "vscode": False, "mutants": [],
        "std_backend_checks": ["encoding", "url"]}))
    cases.append((["stdlib/json.or"], {"code": True, "macos": False, "vscode": False,
                                       "mutants": [], "std_backend_checks": []}))
    dependencies = [
        ("stdlib/jsonnumber.or", ["jsonnumber", "jsonvalue", "jsondecode"]),
        ("stdlib/jsonvalue.or", ["jsonvalue", "jsondecode"]),
        ("tools/check_jsonvalue.py", ["jsonvalue", "jsondecode"]),
        ("stdlib/jsondecode.or", ["jsondecode"]),
        ("tools/check_jsondecode.py", ["jsondecode"]),
        ("tests/std/jsonvalue_test.or", ["jsonvalue"]),
        ("tests/std/jsondecode_test.or", ["jsondecode"]),
        ("examples/json_config.or", ["jsondecode"]),
        ("stdlib/test.or", all_backend_checks),
    ]
    for file, checks in dependencies:
        cases.append(([file], {"code": True, "macos": True, "vscode": False,
                               "mutants": [], "std_backend_checks": checks}))
    cases.append((["docs/std-jsonvalue.md", "docs/std-jsondecode.md"], {
        "code": False, "macos": False, "vscode": False, "mutants": [], "std_backend_checks": []}))
    cases.append((["stdlib/jsondecode.or", "stdlib/jsonnumber.or", "tools/check_jsonvalue.py"], {
        "code": True, "macos": True, "vscode": False, "mutants": [],
        "std_backend_checks": ["jsonnumber", "jsonvalue", "jsondecode"]}))
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
    if not (full["code"] and full["macos"] and full["vscode"] and full["mutants"] == MODULES
            and full["std_backend_checks"] == STD_BACKEND_CHECKS):
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
    print("std_backend_checks=%s" % json.dumps(d["std_backend_checks"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
