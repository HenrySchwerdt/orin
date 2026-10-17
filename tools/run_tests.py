#!/usr/bin/env python3
"""Orin conformance test runner (stdlib only).

Usage: python3 tools/run_tests.py --orinc <compiler> [--cc cc] [--filter substr]
                                  [-j/--jobs N] [--sanitize] [--suite default|next|all]
                                  [--backend c|llvm] [--assert-facts] [--target native|wasm64-orbit]

Suites: `default` = tests/run + tests/errors (the Orin-B contract, every compiler stage);
`next` = tests/next/run + tests/next/errors (language beyond Orin-B, self-hosted compiler only);
`all` = both.

`--target wasm64-orbit` (ADR-0055) builds every test as a WebAssembly module (C backend, clang with the WebAssembly backend
as --cc, default clang) and runs it with tools/wasm_run.mjs under Node >= 24 ($NODE, default node). A test whose program
needs an effect the target does not provide fails to compile (that diagnostic) and is counted as SKIP, not as a failure.

See tests/README.md for the test formats.
"""
import argparse
import difflib
import hashlib
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parallel import add_jobs_arg, ordered_map  # noqa: E402
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join("build", "tests")
RUN_TIMEOUT = 10
WASM = "wasm64-orbit"
# `-D__thread=...`: the runtime keeps per-task state in __thread objects; one WebAssembly thread runs every task, so the L0 switches
# that state by copying one block. Putting every __thread object into the section orin_tls makes it one contiguous block with the
# linker symbols __start_orin_tls / __stop_orin_tls (ADR-0055; no atomics, no wasm-ld TLS, which is broken for non-shared memory).
WASM_TLS = '-D__thread=__attribute__((section("orin_tls")))'
WASM_CFLAGS = ["--target=wasm64-unknown-unknown", "-mbulk-memory", "-ffreestanding", "-nostdlib", WASM_TLS]
WASM_LINK = ["-Wl,--no-entry", "-Wl,--stack-first", "-Wl,-z,stack-size=1048576"]
WASM_LIMIT = "wasm64-orbit: "  # prefix of the line the WebAssembly L0 prints when it hits a limit of running tasks one at a time
WASM_UNAVAILABLE = "which the wasm64-orbit target does not provide"  # the compile error for such an effect
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
    extra += ["--assert-facts"] if args.assert_facts else []
    extra += ["--target=" + WASM] if args.target == WASM else []
    extra += list(flags)
    return run_cmd([args.orinc, "compile", rel, "-o", c_out] + extra, COMPILE_TIMEOUT)


def runtime_sources(backend, target="native"):
    """C runtime sources to link; the LLVM backend also needs the out-of-line shim."""
    if target == WASM:
        return rt_src("orbit")
    srcs = rt_src()
    if backend == "llvm":
        srcs.extend(rt_llvm())
    return srcs


def cc_base(args):
    """The C compiler command and flags a test executable is built with (without the inputs)."""
    if args.target == WASM:
        return [args.cc if args.cc != "cc" else "clang", "-O2", "-w", *WASM_CFLAGS, *rt_inc("orbit")]
    if args.backend == "llvm":
        cc = [args.cc if args.cc != "cc" else "clang", "-O2", "-w", *rt_inc()]
    else:
        cc = [args.cc, "-O1", "-w", *rt_inc()]
    if args.sanitize:
        cc += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    return cc


def runtime_objects(args):
    """Compiles the runtime sources once per run, with the flags of the test executables, instead of once per test.

    The objects are keyed by the compiler command and the contents of the runtime and platform sources and headers, so
    a stale object is never linked. Linking the same object into every test is what compiling the same source with the
    same flags into every test did, about a second of C compile per test less. Returns the object paths (relative to ROOT), or None if a compile failed (the tests
    then compile the sources themselves and report the error)."""
    cc = cc_base(args)
    h = hashlib.sha256(repr(cc).encode())
    h.update(run_cmd([cc[0], "--version"], 30)[1].encode())  # a C compiler upgrade rebuilds the objects
    for d in ("runtime/core", "runtime/platform", "runtime/platform/orbit", "runtime/platform/orbit/include"):
        for f in sorted(os.listdir(os.path.join(ROOT, d))):
            if f.endswith((".c", ".h")):
                h.update(f.encode())
                with open(os.path.join(ROOT, d, f), "rb") as fh:
                    h.update(fh.read())
    outdir = os.path.join(BUILD, "rt", h.hexdigest()[:16])
    os.makedirs(os.path.join(ROOT, outdir), exist_ok=True)
    objs = []
    for src in runtime_sources(args.backend, args.target):
        o = os.path.join(outdir, os.path.basename(src)[:-2] + ".o")
        if not os.path.isfile(os.path.join(ROOT, o)):
            tmp = "%s.%d.tmp.o" % (o, os.getpid())
            rc, _, _ = run_cmd(cc + ["-c", src, "-o", tmp], COMPILE_TIMEOUT)
            if rc != 0:
                return None
            os.replace(os.path.join(ROOT, tmp), os.path.join(ROOT, o))  # atomic: a concurrent run never sees half an object
        objs.append(o)
    return objs


def run_test(args, label, test):
    # label is "run", "errors", "next/run" or "next/errors"
    name, entry, exp = test
    tag = "%s/%s" % (label, name)
    kind = label.split("/")[-1]
    safe = name.replace(os.sep, "_")
    outdir = os.path.join(BUILD, label)
    os.makedirs(os.path.join(ROOT, outdir), exist_ok=True)
    c_out = os.path.join(outdir, safe + (".ll" if args.backend == "llvm" else ".c"))
    exe = os.path.join(outdir, safe + (".wasm" if args.target == WASM else ".exe"))
    hdr = first_line(entry)
    hdrs = header_lines(entry)
    flags = []          # `// flags: --check-contracts` (any header line): extra compiler flags
    want_warns = None   # `// warns: W0450 W0452` (or `none`): the warning codes of the compile, as a sorted list
    want_stderr = []    # `// stderr: text` (any header line): stderr of the run (of the compile, for an error test) must contain text
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
        for w in want_stderr:
            if w not in err:
                return tag, False, "compiler stderr does not contain %r; stderr head:\n%s" % (w, head(err))
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
    if rc != 0 and args.target == WASM and WASM_UNAVAILABLE in err:
        return tag, None, "needs an effect %s does not provide" % WASM
    if rc != 0:
        return tag, False, "compile failed (exit %s); stderr head:\n%s" % (rc, head(err))
    if want_warns is not None:
        got_warns = sorted(WARNING_CODE.findall(err))
        if got_warns != want_warns:
            return tag, False, "warnings differ: expected %s, got %s; stderr head:\n%s" % (want_warns, got_warns, head(err))

    link = WASM_LINK if args.target == WASM else ["-lm"]
    cc = cc_base(args) + [c_out] + (args.rt_objs or runtime_sources(args.backend, args.target)) + link + ["-o", exe]
    rc, _, err = run_cmd(cc, COMPILE_TIMEOUT)
    if rc != 0:
        return tag, False, "C compilation failed (exit %s); stderr head:\n%s" % (rc, head(err))

    env = dict(os.environ)
    if args.sanitize:
        env["ASAN_OPTIONS"] = "detect_leaks=0:allocator_may_return_null=1"
    # Optional stdin: `name.in` next to `name.or`, or `input.in` next to `main.or`.
    stdin_data = None
    in_path = os.path.join(os.path.dirname(entry), "input.in" if os.path.basename(entry) == "main.or" else name + ".in")
    if os.path.isfile(in_path):
        with open(in_path, "rb") as f:
            stdin_data = f.read()
    if args.target == WASM and stdin_data is not None:
        return tag, None, "reads stdin, which %s does not provide" % WASM
    run = [os.environ.get("NODE", "node"), os.path.join(ROOT, "tools", "wasm_run.mjs")] if args.target == WASM else []
    rc, out, err = run_cmd(run + [os.path.join(ROOT, exe)], RUN_TIMEOUT, env=env, stdin_data=stdin_data)
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
    if problems and args.target == WASM:
        # The L0 ends the module with a line `wasm64-orbit: <reason>` when the program needs something one WebAssembly thread
        # cannot do: two tasks running at once (a wait nobody queued can satisfy), a task that traps (no unwinding to its join).
        # A test that then differs from its expectation is SKIP with that reason; a test that still matches passes for real.
        for line in err.splitlines():
            if line.startswith(WASM_LIMIT):
                return tag, None, line[len(WASM_LIMIT):]
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
    add_jobs_arg(ap)
    ap.add_argument("--sanitize", action="store_true")
    ap.add_argument("--suite", choices=["default", "next", "all"], default="default",
                    help="default: tests/run + tests/errors; next: tests/next/*; all: both")
    ap.add_argument("--backend", choices=["c", "llvm"], default="c",
                    help="c: emit C (default); llvm: emit LLVM IR and build with clang")
    ap.add_argument("--target", choices=["native", WASM], default="native",
                    help="native (default) or wasm64-orbit: WebAssembly modules run with tools/wasm_run.mjs (ADR-0055)")
    ap.add_argument("--assert-facts", action="store_true",
                    help="compile with `--assert-facts`: every forwarded load is checked against its slot at run time (exit 70)")
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

    args.rt_objs = runtime_objects(args)
    results = list(ordered_map(work, jobs, args.jobs))

    failed = [r for r in results if r[1] is False]
    skipped = [r for r in results if r[1] is None]  # only with --target wasm64-orbit: the target lacks what the test needs
    for tag, ok, detail in skipped:
        print("SKIP %s: %s" % (tag, detail))
    for tag, ok, detail in failed:
        print("FAIL %s" % tag)
        for line in detail.splitlines():
            print("    " + line)
    for label, _ in labels:
        rs = [r for r in results if r[0].startswith(label + "/")]
        if rs:
            sk = sum(1 for r in rs if r[1] is None)
            print("%-11s %d passed, %d failed%s" % (label, sum(1 for r in rs if r[1]), sum(1 for r in rs if r[1] is False),
                                                  ", %d skipped" % sk if sk else ""))
    print("TOTAL  %d passed, %d failed%s" % (len(results) - len(failed) - len(skipped), len(failed),
                                            ", %d skipped" % len(skipped) if skipped else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
