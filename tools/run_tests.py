#!/usr/bin/env python3
"""Orin conformance test runner (stdlib only).

Usage: python3 tools/run_tests.py --orinc <compiler> [--cc cc] [--filter substr]
                                  [--jobs N] [--sanitize] [--suite default|next|all]

Suites: `default` = tests/run + tests/errors (the Orin-B contract, every compiler stage);
`next` = tests/next/run + tests/next/errors (language beyond Orin-B, self-hosted compiler only);
`all` = both.

See tests/README.md for the test formats.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join("build", "tests")
RUN_TIMEOUT = 10
COMPILE_TIMEOUT = 120

HEADER_EXIT = re.compile(r"^//\s*exit:\s*(-?\d+)\s*$")
HEADER_ERROR = re.compile(r"^//\s*error:\s*(E\d{4})\s*$")


def first_line(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.readline().strip()


def discover(kind, subdir=""):
    """Return list of (name, entry_path, expected_path_or_None)."""
    base = os.path.join(ROOT, "tests", subdir, kind)
    tests = []
    if not os.path.isdir(base):
        return tests
    for entry in sorted(os.listdir(base)):
        p = os.path.join(base, entry)
        if os.path.isdir(p):
            main = os.path.join(p, "main.or")
            if os.path.isfile(main):
                exp = os.path.join(p, "expected.out") if kind == "run" else None
                tests.append((entry, main, exp))
        elif entry.endswith(".or"):
            name = entry[:-3]
            exp = os.path.join(base, name + ".out") if kind == "run" else None
            tests.append((name, p, exp))
    return tests


def head(text, lines=15, chars=1500):
    out = "\n".join(text.splitlines()[:lines])
    return out[:chars]


def run_cmd(cmd, timeout, env=None, stdin_data=None):
    try:
        extra = {"input": stdin_data} if stdin_data is not None else {"stdin": subprocess.DEVNULL}
        r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=env, **extra)
        return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        return None, (e.stdout or b"").decode("utf-8", "replace"), (e.stderr or b"").decode("utf-8", "replace")
    except OSError as e:
        return -1, "", "cannot execute %s: %s" % (cmd[0], e)


def compile_orin(args, entry, c_out):
    rel = os.path.relpath(entry, ROOT)
    return run_cmd([args.orinc, "compile", rel, "-o", c_out], COMPILE_TIMEOUT)


def run_test(args, label, test):
    # label is "run", "errors", "next/run" or "next/errors"
    name, entry, exp = test
    tag = "%s/%s" % (label, name)
    kind = label.split("/")[-1]
    safe = name.replace(os.sep, "_")
    outdir = os.path.join(BUILD, label)
    os.makedirs(os.path.join(ROOT, outdir), exist_ok=True)
    c_out = os.path.join(outdir, safe + ".c")
    exe = os.path.join(outdir, safe + ".exe")
    hdr = first_line(entry)

    if kind == "errors":
        m = HEADER_ERROR.match(hdr)
        if not m:
            return tag, False, "bad or missing '// error: E0xxx' header in first line"
        code = m.group(1)
        rc, _, err = compile_orin(args, entry, c_out)
        if rc is None:
            return tag, False, "compiler timed out"
        if rc == 0:
            return tag, False, "expected compile failure with %s but compilation succeeded" % code
        if code not in err:
            return tag, False, "expected %s in stderr (exit %s); stderr head:\n%s" % (code, rc, head(err))
        return tag, True, ""

    # run tests
    want_exit = 0
    m = HEADER_EXIT.match(hdr)
    if m:
        want_exit = int(m.group(1))
    if exp is None or not os.path.isfile(exp):
        return tag, False, "missing expected output file"
    with open(exp, "r", encoding="utf-8", errors="replace") as f:
        want_out = f.read()

    rc, _, err = compile_orin(args, entry, c_out)
    if rc is None:
        return tag, False, "compiler timed out"
    if rc != 0:
        return tag, False, "compile failed (exit %s); stderr head:\n%s" % (rc, head(err))

    cc = [args.cc, "-O1", "-w", "-I", "runtime"]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    cc += [c_out, os.path.join("runtime", "orin_runtime.c"), "-o", exe]
    rc, _, err = run_cmd(cc, COMPILE_TIMEOUT)
    if rc != 0:
        return tag, False, "C compilation failed (exit %s); stderr head:\n%s" % (rc, head(err))

    env = dict(os.environ)
    if args.sanitize:
        env["ASAN_OPTIONS"] = "detect_leaks=0"
    # Optional stdin: `name.in` next to `name.or`, or `input.in` next to `main.or`.
    stdin_data = None
    in_path = os.path.join(os.path.dirname(entry), "input.in" if os.path.basename(entry) == "main.or" else name + ".in")
    if os.path.isfile(in_path):
        with open(in_path, "rb") as f:
            stdin_data = f.read()
    rc, out, err = run_cmd([os.path.join(ROOT, exe)], RUN_TIMEOUT, env=env, stdin_data=stdin_data)
    if rc is None:
        return tag, False, "executable timed out after %d s" % RUN_TIMEOUT
    problems = []
    if out != want_out:
        diff = difflib.unified_diff(want_out.splitlines(), out.splitlines(),
                                    "expected", "actual", lineterm="", n=1)
        problems.append("stdout differs:\n" + head("\n".join(diff), 20))
    if rc != want_exit:
        problems.append("exit status %s, expected %s" % (rc, want_exit))
    if problems:
        if err.strip():
            problems.append("stderr head:\n" + head(err, 8))
        return tag, False, "\n".join(problems)
    return tag, True, ""


def main():
    ap = argparse.ArgumentParser(description="Orin conformance test runner")
    ap.add_argument("--orinc", default=os.path.join("bootstrap", "target", "release", "orinb"))
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--filter", default="")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--sanitize", action="store_true")
    ap.add_argument("--suite", choices=["default", "next", "all"], default="default",
                    help="default: tests/run + tests/errors; next: tests/next/*; all: both")
    args = ap.parse_args()

    if not os.path.isabs(args.orinc) and os.sep in args.orinc:
        args.orinc = os.path.join(ROOT, args.orinc)
    os.makedirs(os.path.join(ROOT, BUILD), exist_ok=True)

    labels = []
    if args.suite in ("default", "all"):
        labels += [("run", ""), ("errors", "")]
    if args.suite in ("next", "all"):
        labels += [("next/run", "next"), ("next/errors", "next")]
    jobs = []
    for label, sub in labels:
        for t in discover(label.split("/")[-1], sub):
            if args.filter in "%s/%s" % (label, t[0]):
                jobs.append((label, t))
    if not jobs:
        print("no tests matched")
        return 1

    def work(job):
        try:
            return run_test(args, job[0], job[1])
        except Exception as e:  # runner bug or odd environment: report as failure
            return "%s/%s" % (job[0], job[1][0]), False, "runner exception: %r" % (e,)

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(work, jobs))

    failed = [r for r in results if not r[1]]
    for tag, ok, detail in failed:
        print("FAIL %s" % tag)
        for line in detail.splitlines():
            print("    " + line)
    for label, _ in labels:
        rs = [r for r in results if r[0].startswith(label + "/")]
        if rs:
            print("%-11s %d passed, %d failed" % (label, sum(1 for r in rs if r[1]), sum(1 for r in rs if not r[1])))
    print("TOTAL  %d passed, %d failed" % (len(results) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
