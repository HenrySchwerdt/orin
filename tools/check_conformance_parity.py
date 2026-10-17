#!/usr/bin/env python3
"""Parity check between the two conformance runners (ADR-0047 section 3 and phase 5).

tools/run_tests.py (Python) is the independent oracle; tooling/conformance (Orin) is the runner CI uses. The
self-hosted toolchain must not be the only judge of itself, and the two runners must not drift apart, so this script runs
both and compares them:

  1. The real suites (--suite all) with each backend: both runners must print byte-identical output (the FAIL
     blocks, the per-suite lines and the TOTAL line) and exit with the same status.
  2. A fixture tree with deliberately broken tests (wrong expected output, missing expectation, wrong exit status,
     compile failure, wrong or missing error code, wrong `// warns:` / `// stderr:` expectation, an executable that
     hangs, ...): both runners must fail exactly the broken tests, with identical output, and pass the good ones.
  3. The command line: --filter, -j 1, no match, a usage error, an invalid ORIN_JOBS.

Usage: python3 tools/check_conformance_parity.py [--orinc build/bootstrap/orin2] [--runner build/conformance/orin-conformance]
                                                 [--backends c,llvm] [--sanitize] [--skip-real] [--skip-fixtures]
Needs the Orin runner built (tools/conformance.sh --build) and, for --backends llvm, clang.
Python is used on purpose: this is the independent oracle comparison (docs/testing.md, "Conformance runner").
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ------------------------------------------------------------------------------------------------ fixtures

HELLO = 'function main(): void {\n  console.log("hello");\n}\n'
EXIT3 = '// exit: 3\nimport { exit } from "std:process";\nfunction main(): void {\n  console.log("bye");\n  exit(3);\n}\n'
HANG = 'function main(): void {\n  let i: int = 0;\n  while (true) {\n    i = (i + 1) % 1000;\n  }\n}\n'
MULTI = 'function main(): void {\n  let i: int = 0;\n  while (i < 12) {\n    console.log("line " + i.toString());\n    i += 1;\n  }\n}\n'
MULTI_OUT = "".join("line %d\n" % i for i in range(12))
MULTI_WRONG = "".join(("line %d\n" % i) if i not in (3, 4, 9) else ("LINE %d\n" % i) for i in range(12)) + "extra\n"
TRAP = '// exit: 101\n// stderr: trap\nfunction main(): void {\n  console.log("start");\n  const z = 0;\n  console.log((10 % z).toString());\n}\n'
SYNTAX = "function main(): void {\n  const x = 1 @ 2;\n}\n"

# (relative path, content) of the files that are copied from the repository, so that the good tests are real ones:
# stdin, a directory test, `// warns:`, `// flags:`, `// stderr:` on a run test and on an error test, an error test.
COPIED = [
    "tests/next/run/io_stdin_lines.or", "tests/next/run/io_stdin_lines.in", "tests/next/run/io_stdin_lines.out",
    "tests/next/run/contract_quality_ensures.or", "tests/next/run/contract_quality_ensures.out",
    "tests/next/run/contracts_report_values.or", "tests/next/run/contracts_report_values.out",
    "tests/errors/e0100_bad_char.or",
    "tests/next/errors/e0416_closure_in_contract.or",
]
COPIED_DIRS = ["tests/next/run/ox_widgets", "tests/next/run/generic_reexport"]


def fixtures(with_hang):
    """Returns (files, broken): the files of the fixture tests and the tags that must fail."""
    f = {}
    broken = set()

    def add(path, text):
        f[path] = text

    # good tests
    add("tests/run/g_hello.or", HELLO)
    add("tests/run/g_hello.out", "hello\n")
    add("tests/run/g_exit3.or", EXIT3)
    add("tests/run/g_exit3.out", "bye\n")
    add("tests/run/g_trap.or", TRAP)
    add("tests/run/g_trap.out", "start\n")
    add("tests/run/g_dir/main.or", HELLO)
    add("tests/run/g_dir/expected.out", "hello\n")
    add("tests/run/g_multi.or", MULTI)
    add("tests/run/g_multi.out", MULTI_OUT)
    add("tests/errors/g_syntax.or", "// error: E0100\n" + SYNTAX)
    add("tests/errors/g_stderr.or", "// error: E0100\n// stderr: E0100\n" + SYNTAX)
    # broken tests: every one of these must fail
    def bad(tag, files):
        broken.add(tag)
        f.update(files)
    bad("run/b_wrong_out", {"tests/run/b_wrong_out.or": HELLO, "tests/run/b_wrong_out.out": "goodbye\n"})
    bad("run/b_multiline_diff", {"tests/run/b_multiline_diff.or": MULTI, "tests/run/b_multiline_diff.out": MULTI_WRONG})
    bad("run/b_missing_exp", {"tests/run/b_missing_exp.or": HELLO})
    bad("run/b_dir_missing_exp", {"tests/run/b_dir_missing_exp/main.or": HELLO})
    bad("run/b_exit_header", {"tests/run/b_exit_header.or": "// exit: 5\n" + HELLO, "tests/run/b_exit_header.out": "hello\n"})
    bad("run/b_exit_nonzero", {"tests/run/b_exit_nonzero.or": EXIT3.replace("// exit: 3\n", ""), "tests/run/b_exit_nonzero.out": "bye\n"})
    bad("run/b_compile_fail", {"tests/run/b_compile_fail.or": SYNTAX, "tests/run/b_compile_fail.out": ""})
    bad("run/b_warns", {"tests/run/b_warns.or": "// warns: W0450\n" + HELLO, "tests/run/b_warns.out": "hello\n"})
    bad("run/b_warns_none", {"tests/run/b_warns_none.or": "// warns: none\n" + open(os.path.join(ROOT, "tests/next/run/contract_quality_ensures.or")).read().split("\n", 1)[1],
                             "tests/run/b_warns_none.out": open(os.path.join(ROOT, "tests/next/run/contract_quality_ensures.out")).read()})
    bad("run/b_stderr", {"tests/run/b_stderr.or": "// stderr: no such text\n" + HELLO, "tests/run/b_stderr.out": "hello\n"})
    bad("run/b_stdin", {"tests/run/b_stdin.or": open(os.path.join(ROOT, "tests/next/run/io_stdin_lines.or")).read(),
                        "tests/run/b_stdin.out": "wrong\n"})  # no b_stdin.in: the program reads an empty stdin
    bad("errors/b_no_header", {"tests/errors/b_no_header.or": SYNTAX})
    bad("errors/b_bad_header", {"tests/errors/b_bad_header.or": "// error: E12\n" + SYNTAX})
    bad("errors/b_wrong_code", {"tests/errors/b_wrong_code.or": "// error: E0200\n" + SYNTAX})
    bad("errors/b_compiles", {"tests/errors/b_compiles.or": "// error: E0100\n" + HELLO})
    bad("errors/b_stderr", {"tests/errors/b_stderr.or": "// error: E0100\n// stderr: no such text\n" + SYNTAX})
    bad("next/errors/b_wrong_code", {"tests/next/errors/b_wrong_code.or": "// error: E0416\n" + SYNTAX})
    if with_hang:
        bad("next/run/b_timeout", {"tests/next/run/b_timeout.or": HANG, "tests/next/run/b_timeout.out": ""})
    return f, broken


def build_tree(dest, with_hang):
    files, broken = fixtures(with_hang)
    os.makedirs(os.path.join(dest, "tools"))
    for name in ("run_tests.py", "parallel.py", "runtime_files.py", "runtime-sources.txt"):
        shutil.copy(os.path.join(ROOT, "tools", name), os.path.join(dest, "tools", name))
    for d in ("runtime",):
        os.symlink(os.path.join(ROOT, d), os.path.join(dest, d))
    for rel in COPIED:
        os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), os.path.join(dest, rel))
    for rel in COPIED_DIRS:
        shutil.copytree(os.path.join(ROOT, rel), os.path.join(dest, rel))
    for rel, text in files.items():
        p = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)
    return broken


# ------------------------------------------------------------------------------------------------ running

def run(cmd, env=None, cwd=None, timeout=1800):
    t0 = time.time()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.time() - t0


class Checker:
    def __init__(self):
        self.failures = []
        self.checks = 0

    def check(self, ok, what, detail=""):
        self.checks += 1
        if ok:
            print("  ok    %s" % what)
        else:
            print("  FAIL  %s" % what)
            for line in detail.splitlines()[:40]:
                print("        " + line)
            self.failures.append(what)


def compare(ck, name, py, orin):
    ck.check(py[0] == orin[0], "%s: same exit status (python %d, orin %d)" % (name, py[0], orin[0]))
    detail = "--- python stdout\n%s\n--- orin stdout\n%s\n--- python stderr\n%s\n--- orin stderr\n%s" % (py[1][-3000:], orin[1][-3000:], py[2][-800:], orin[2][-800:])
    ck.check(py[1] == orin[1], "%s: byte-identical stdout" % name, detail)


def failing_tags(out):
    return sorted(l[5:].strip() for l in out.splitlines() if l.startswith("FAIL "))


def real_suites(args, ck):
    print("== real suites: python oracle vs Orin runner ==")
    for backend in args.backends:
        for sanitize in ([False, True] if args.sanitize else [False]):
            extra = ["--backend", backend] + (["--sanitize"] if sanitize else [])
            name = "--suite all %s" % " ".join(extra)
            base = ["--orinc", args.orinc, "--suite", "all"] + extra
            py = run([sys.executable, os.path.join(ROOT, "tools", "run_tests.py")] + base, cwd=ROOT)
            orin = run([args.runner, "--root", ROOT] + base, cwd=ROOT)
            print("  %-46s python %6.1f s   orin %6.1f s" % (name, py[3], orin[3]))
            last = [l for l in py[1].splitlines() if l.startswith("TOTAL")]
            print("  python: %s" % (last[-1] if last else "<no TOTAL line>"))
            last = [l for l in orin[1].splitlines() if l.startswith("TOTAL")]
            print("  orin  : %s" % (last[-1] if last else "<no TOTAL line>"))
            compare(ck, name, py, orin)
            ck.check(py[0] == 0 and orin[0] == 0, "%s: both runners pass the repository" % name)


def fixture_run(args, ck, backend, with_hang, extra=(), label=None):
    label = label or "fixtures (backend %s%s)" % (backend, ", " + " ".join(extra) if extra else "")
    t_py = tempfile.mkdtemp(prefix="orin-parity-py-")
    t_or = tempfile.mkdtemp(prefix="orin-parity-or-")
    try:
        shutil.rmtree(t_py)
        shutil.rmtree(t_or)
        broken = build_tree(t_py, with_hang)
        build_tree(t_or, with_hang)
        flags = ["--orinc", os.path.abspath(args.orinc), "--suite", "all", "--backend", backend] + list(extra)
        res = {}

        def go(key, cmd):
            res[key] = run(cmd, cwd=ROOT)
        th = [threading.Thread(target=go, args=("py", [sys.executable, os.path.join(t_py, "tools", "run_tests.py")] + flags)),
              threading.Thread(target=go, args=("or", [args.runner, "--root", t_or] + flags))]
        for t in th:
            t.start()
        for t in th:
            t.join()
        py, orin = res["py"], res["or"]
        # the paths in messages are relative to the root, so the two outputs are comparable as they are
        compare(ck, label, py, orin)
        for who, r in (("python", py), ("orin", orin)):
            got = failing_tags(r[1])
            ck.check(got == sorted(broken), "%s: %s fails exactly the %d broken tests" % (label, who, len(broken)),
                     "missing failures: %s\nunexpected failures: %s" % (sorted(set(broken) - set(got)), sorted(set(got) - set(broken))))
            ck.check(r[0] == 1, "%s: %s exits with status 1" % (label, who))
        return py, orin
    finally:
        shutil.rmtree(t_py, ignore_errors=True)
        shutil.rmtree(t_or, ignore_errors=True)


def cli_checks(args, ck):
    print("== command line ==")
    t_py = tempfile.mkdtemp(prefix="orin-parity-py-")
    t_or = tempfile.mkdtemp(prefix="orin-parity-or-")
    try:
        shutil.rmtree(t_py)
        shutil.rmtree(t_or)
        build_tree(t_py, False)
        build_tree(t_or, False)
        base = ["--orinc", os.path.abspath(args.orinc)]
        py_cmd = [sys.executable, os.path.join(t_py, "tools", "run_tests.py")] + base
        or_cmd = [args.runner, "--root", t_or] + base
        cases = [
            ("--filter g_hello", ["--suite", "all", "--filter", "g_hello"]),
            ("--filter with no match (exit 1, 'no tests matched')", ["--suite", "all", "--filter", "no-such-test"]),
            ("-j 1", ["--suite", "default", "--filter", "run/g_", "-j", "1"]),
            ("-j4 --filter run/g_", ["--suite", "default", "--filter", "run/g_", "-j4"]),
            ("--suite next", ["--suite", "next", "--filter", "g_"]),
            ("--assert-facts", ["--suite", "default", "--filter", "run/g_", "--assert-facts"]),
            ("--sanitize", ["--suite", "default", "--filter", "run/g_hello", "--sanitize"]),
            ("--filter=run/g_exit3 (inline value)", ["--filter=run/g_exit3"]),
            ("a compiler that does not exist", ["--filter", "run/g_hello", "--orinc", "/no/such/compiler"]),
        ]
        for name, extra in cases:
            py = run(py_cmd + extra, cwd=ROOT)
            orin = run(or_cmd + extra, cwd=ROOT)
            if name.startswith("a compiler"):
                # the messages of a missing compiler differ (Python: 'cannot execute', sh: 'not found'); the verdict must not
                ck.check(py[0] == orin[0] == 1 and failing_tags(py[1]) == failing_tags(orin[1]) != [],
                         "%s: both runners fail the tests with exit 1" % name)
            else:
                compare(ck, name, py, orin)
        # usage errors: status 2 on stderr, nothing on stdout
        for name, extra in (("unknown option", ["--bogus"]), ("bad --suite", ["--suite", "x"]), ("bad --backend", ["--backend", "x"]),
                            ("-j needs a number", ["-j", "many"]), ("--filter needs a value", ["--filter"]), ("positional argument", ["stray"])):
            py = run(py_cmd + extra, cwd=ROOT)
            orin = run(or_cmd + extra, cwd=ROOT)
            ck.check(py[0] == 2 and orin[0] == 2 and py[1] == "" and orin[1] == "", "usage error (%s): exit 2, empty stdout (python %d, orin %d)" % (name, py[0], orin[0]))
        # $ORIN_JOBS
        env = dict(os.environ, ORIN_JOBS="many")
        py = run(py_cmd + ["--filter", "run/g_hello"], env=env, cwd=ROOT)
        orin = run(or_cmd + ["--filter", "run/g_hello"], env=env, cwd=ROOT)
        ck.check(py[0] == 1 and orin[0] == 1 and py[2].strip() == orin[2].strip(), "ORIN_JOBS=many: exit 1 and the same message (%r)" % orin[2].strip())
        env = dict(os.environ, ORIN_JOBS="2")
        py = run(py_cmd + ["--filter", "run/g_"], env=env, cwd=ROOT)
        orin = run(or_cmd + ["--filter", "run/g_"], env=env, cwd=ROOT)
        compare(ck, "ORIN_JOBS=2", py, orin)
    finally:
        shutil.rmtree(t_py, ignore_errors=True)
        shutil.rmtree(t_or, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--orinc", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--runner", default=os.path.join(ROOT, "build", "conformance", "orin-conformance"))
    ap.add_argument("--backends", default="c,llvm", help="comma separated: c, llvm")
    ap.add_argument("--sanitize", action="store_true", help="also compare the real suites under ASan + UBSan")
    ap.add_argument("--skip-real", action="store_true")
    ap.add_argument("--skip-fixtures", action="store_true")
    args = ap.parse_args()
    args.backends = [b for b in args.backends.split(",") if b]
    if "llvm" in args.backends and shutil.which("clang") is None:
        print("clang not found: skipping the llvm backend")
        args.backends.remove("llvm")
    if not os.path.isfile(args.runner):
        sys.exit("runner %s not found: build it with tools/conformance.sh --build" % args.runner)
    ck = Checker()
    if not args.skip_real:
        real_suites(args, ck)
    if not args.skip_fixtures:
        print("== fixtures with deliberately broken tests ==")
        for i, backend in enumerate(args.backends):
            fixture_run(args, ck, backend, with_hang=(i == 0))
        if args.sanitize:
            fixture_run(args, ck, "c", with_hang=False, extra=["--sanitize"])
        fixture_run(args, ck, "c", with_hang=False, extra=["--assert-facts", "-j", "1"])
        cli_checks(args, ck)
    print("== %d checks, %d failed ==" % (ck.checks, len(ck.failures)))
    for f in ck.failures:
        print("  FAILED: " + f)
    return 1 if ck.failures else 0


if __name__ == "__main__":
    sys.exit(main())
