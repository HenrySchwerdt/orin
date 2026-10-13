#!/usr/bin/env python3
"""Orin conformance test runner (stdlib only).

Usage: python3 tools/run_tests.py --orinc <compiler> [--cc cc] [--filter substr]
                                  [--jobs N] [--sanitize] [--suite default|next|all]
                                  [--backend c|llvm]

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
HEADER_FLAGS = re.compile(r"^//\s*flags:\s*(.*?)\s*$")
HEADER_WARNS = re.compile(r"^//\s*warns:\s*(.*?)\s*$")
WARNING_CODE = re.compile(r"warning\[(W\d{4})\]")
HEADER_STDERR = re.compile(r"^//\s*stderr:\s*(.*?)\s*$")


def first_line(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.readline().strip()


def header_lines(path, limit=16):
    """The leading `//` comment lines of a test (its header block)."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for _ in range(limit):
            line = f.readline()
            if not line.startswith("//"):
                break
            out.append(line.strip())
    return out


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


def compile_orin(args, entry, c_out, flags=()):
    rel = os.path.relpath(entry, ROOT)
    extra = ["--backend=llvm"] if args.backend == "llvm" else []
    extra += list(flags)
    return run_cmd([args.orinc, "compile", rel, "-o", c_out] + extra, COMPILE_TIMEOUT)


def runtime_sources(backend):
    """C runtime sources to link; the LLVM backend also needs the out-of-line shim."""
    srcs = [os.path.join("runtime", "orin_runtime.c"), os.path.join("platform", "orin_platform.c")]
    if backend == "llvm":
        srcs.append(os.path.join("runtime", "orin_runtime_llvm.c"))
    return srcs


def run_test(args, label, test):
    # label is "run", "errors", "next/run" or "next/errors"
    name, entry, exp = test
    tag = "%s/%s" % (label, name)
    kind = label.split("/")[-1]
    safe = name.replace(os.sep, "_")
    outdir = os.path.join(BUILD, label)
    os.makedirs(os.path.join(ROOT, outdir), exist_ok=True)
    c_out = os.path.join(outdir, safe + (".ll" if args.backend == "llvm" else ".c"))
    exe = os.path.join(outdir, safe + ".exe")
    hdr = first_line(entry)
    hdrs = header_lines(entry)
    flags = []          # `// flags: --check-contracts` (any header line): extra compiler flags
    want_warns = None   # `// warns: W0450 W0452` (or `none`): the warning codes of the compile, as a sorted list
    want_stderr = []    # `// stderr: text` (any header line): stderr of the run must contain text
    for h in hdrs:
        m = HEADER_FLAGS.match(h)
        if m:
            flags += m.group(1).split()
        m = HEADER_STDERR.match(h)
        if m:
            want_stderr.append(m.group(1))
        m = HEADER_WARNS.match(h)
        if m:
            want_warns = [] if m.group(1) == "none" else sorted(m.group(1).split())

    if kind == "errors":
        m = HEADER_ERROR.match(hdr)
        if not m:
            return tag, False, "bad or missing '// error: E0xxx' header in first line"
        code = m.group(1)
        rc, _, err = compile_orin(args, entry, c_out, flags)
        if rc is None:
            return tag, False, "compiler timed out"
        if rc == 0:
            return tag, False, "expected compile failure with %s but compilation succeeded" % code
        if code not in err:
            return tag, False, "expected %s in stderr (exit %s); stderr head:\n%s" % (code, rc, head(err))
        return tag, True, ""

    # run tests
    want_exit = 0
    for h in hdrs:
        m = HEADER_EXIT.match(h)
        if m:
            want_exit = int(m.group(1))
    if exp is None or not os.path.isfile(exp):
        return tag, False, "missing expected output file"
    with open(exp, "r", encoding="utf-8", errors="replace") as f:
        want_out = f.read()

    rc, _, err = compile_orin(args, entry, c_out, flags)
    if rc is None:
        return tag, False, "compiler timed out"
    if rc != 0:
        return tag, False, "compile failed (exit %s); stderr head:\n%s" % (rc, head(err))
    if want_warns is not None:
        got_warns = sorted(WARNING_CODE.findall(err))
        if got_warns != want_warns:
            return tag, False, "warnings differ: expected %s, got %s; stderr head:\n%s" % (want_warns, got_warns, head(err))

    if args.backend == "llvm":
        cc = [args.cc if args.cc != "cc" else "clang", "-O2", "-w", "-I", "runtime"]
    else:
        cc = [args.cc, "-O1", "-w", "-I", "runtime"]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    cc += [c_out] + runtime_sources(args.backend) + ["-lm", "-o", exe]
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
    for w in want_stderr:
        if w not in err:
            problems.append("stderr does not contain %r" % w)
    if problems:
        if err.strip():
            problems.append("stderr head:\n" + head(err, 8))
        return tag, False, "\n".join(problems)
    return tag, True, ""


def main():
    ap = argparse.ArgumentParser(description="Orin conformance test runner")
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--filter", default="")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--sanitize", action="store_true")
    ap.add_argument("--suite", choices=["default", "next", "all"], default="default",
                    help="default: tests/run + tests/errors; next: tests/next/*; all: both")
    ap.add_argument("--backend", choices=["c", "llvm"], default="c",
                    help="c: emit C (default); llvm: emit LLVM IR and build with clang")
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
