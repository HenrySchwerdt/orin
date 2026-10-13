#!/usr/bin/env python3
"""Tests for `orin fmt` and `orin check --format=json` (spec 18 §3). Stdlib only.

Usage: python3 tools/test_fmt.py [--orin2 build/bootstrap/orin2] [--no-build] [--jobs N] [-v]

Needs the self-hosted compiler from tools/bootstrap.sh. Builds the current compiler/main.or and
compiler/tests/parse_main.or with it (into build/fmt/), then checks:
  1. tests/fmt/*.in.or formats to *.out.or, and *.out.or is a fixed point;
  2. for every .or under tests/run, tests/next, tests/parse_edge, compiler/, bench/:
     idempotence fmt(fmt(x)) == fmt(x), AST preservation (parse_main dump without spans),
     comment preservation (same multiset of comment texts); files that do not parse must be
     reported by fmt and left untouched;
  3. `check --format=json` on tests/errors prints valid JSON lines with the documented keys.
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
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "fmt")
SPAN = re.compile(r"@\d+-\d+")
CORPUS_DIRS = ["tests/run", "tests/next", "tests/parse_edge", "compiler", "bench"]


def run(cmd, timeout=120):
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def build(orin2, src, name):
    c = os.path.join(OUT, name + ".c")
    exe = os.path.join(OUT, name)
    rc, _, err = run([orin2, "compile", src, "-o", c])
    if rc != 0:
        sys.exit("cannot compile %s:\n%s" % (src, err.decode()))
    rc, _, err = run(["cc", "-O1", "-w", "-I", "runtime", c, "runtime/orin_runtime.c", "-o", exe])
    if rc != 0:
        sys.exit("cc failed for %s:\n%s" % (src, err.decode()))
    return exe


def comments(text):
    """Multiset of comment texts (string-literal aware); line comments right-trimmed."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"' and text[i] != "\n":
                i += 2 if text[i] == "\\" else 1
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(text[i:j].rstrip())
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(text[i:j])
            i = j
        else:
            i += 1
    return collections.Counter(out)


class Runner:
    def __init__(self, fmt, parse, verbose):
        self.fmt, self.parse, self.verbose = fmt, parse, verbose
        self.failures = []
        self.passed = 0

    def fail(self, name, msg):
        self.failures.append((name, msg))
        print("FAIL %s: %s" % (name, msg))

    def ok(self, name):
        self.passed += 1
        if self.verbose:
            print("ok   " + name)

    def format_text(self, text):
        """Format text via a temp file; returns (rc, stdout, stderr)."""
        with tempfile.NamedTemporaryFile("wb", suffix=".or", dir=OUT, delete=False) as f:
            f.write(text)
            path = f.name
        try:
            return run([self.fmt, "fmt", "--stdout", path])
        finally:
            os.unlink(path)

    def ast(self, path):
        rc, out, _ = run([self.parse, path])
        return rc, SPAN.sub("", out.decode("utf-8", "replace"))

    def check_pair(self, inp):
        name = os.path.relpath(inp, ROOT)
        exp = inp[: -len(".in.or")] + ".out.or"
        rc, out, err = run([self.fmt, "fmt", "--stdout", inp])
        if rc != 0:
            return self.fail(name, "fmt failed: " + err.decode())
        want = open(exp, "rb").read()
        if out != want:
            import difflib
            d = "\n".join(difflib.unified_diff(want.decode().splitlines(), out.decode().splitlines(), "expected", "actual", lineterm=""))
            return self.fail(name, "output differs from %s\n%s" % (os.path.basename(exp), d))
        rc, out2, err = run([self.fmt, "fmt", "--stdout", exp])
        if rc != 0 or out2 != out:
            return self.fail(name, "expected output is not a fixed point")
        src = open(inp, "rb").read().decode()
        if comments(src) != comments(want.decode()):
            return self.fail(name, "comments changed")
        a = self.ast(inp)
        b = self.ast(exp)
        if a != b:
            return self.fail(name, "AST changed")
        self.ok(name)

    def check_corpus(self, path):
        name = os.path.relpath(path, ROOT)
        data = open(path, "rb").read()
        prc, ast0 = self.ast(path)
        rc, out, err = self.format_text(data)
        if prc != 0:
            # syntax error: must be reported, file untouched
            with tempfile.TemporaryDirectory(dir=OUT) as d:
                tmp = os.path.join(d, "x.or")
                open(tmp, "wb").write(data)
                rc, _, err = run([self.fmt, "fmt", tmp])
                if rc == 0 or b"error[E" not in err:
                    return self.fail(name, "syntax error not reported by fmt (rc=%d)" % rc)
                if open(tmp, "rb").read() != data:
                    return self.fail(name, "file with syntax error was modified")
            return self.ok(name + " (syntax error kept)")
        if rc != 0:
            return self.fail(name, "fmt failed: " + err.decode()[:300])
        out1 = out  # --stdout prints exactly the formatted file text
        rc2, out2, err2 = self.format_text(out1)
        if rc2 != 0:
            return self.fail(name, "formatted output does not parse: " + err2.decode()[:300])
        if out2 != out:
            return self.fail(name, "not idempotent")
        with tempfile.TemporaryDirectory(dir=OUT) as d:
            tmp = os.path.join(d, "x.or")
            open(tmp, "wb").write(out1)
            rc3, ast1 = self.ast(tmp)
        if rc3 != 0 or ast1 != ast0:
            return self.fail(name, "AST changed by formatting")
        if comments(data.decode("utf-8", "replace")) != comments(out1.decode("utf-8", "replace")):
            return self.fail(name, "comments not preserved")
        self.ok(name)

    def check_json(self, entry):
        name = os.path.relpath(entry, ROOT)
        rc, out, err = run([self.fmt, "check", "--format=json", entry])
        rc0, _, err0 = run([self.fmt, "check", entry])
        if rc != 1 or rc0 != 1:
            return self.fail(name, "expected exit 1 (json rc=%d, text rc=%d)" % (rc, rc0))
        lines = out.decode().splitlines()
        if not lines:
            return self.fail(name, "no JSON output")
        keys = ["code", "severity", "file", "line", "col", "endLine", "endCol", "message", "notes"]
        codes = []
        for ln in lines:
            try:
                o = json.loads(ln)
            except ValueError as e:
                return self.fail(name, "invalid JSON %r: %s" % (ln, e))
            if list(o.keys()) != keys:
                return self.fail(name, "keys differ: %s" % list(o.keys()))
            if not re.fullmatch(r"E\d{4}", o["code"]) or o["severity"] != "error":
                return self.fail(name, "bad code/severity")
            if not (o["line"] >= 1 and o["col"] >= 1 and (o["endLine"], o["endCol"]) >= (o["line"], o["col"])):
                return self.fail(name, "bad position: %s" % ln)
            if not isinstance(o["message"], str) or not isinstance(o["notes"], list):
                return self.fail(name, "bad message/notes")
            codes.append(o["code"])
        text_codes = re.findall(r"error\[(E\d{4})\]", err0.decode())
        if codes != text_codes:
            return self.fail(name, "codes %s differ from text mode %s" % (codes, text_codes))
        m = re.match(r"(.*?):(\d+):(\d+): error", err0.decode())
        o = json.loads(lines[0])
        if m and (o["file"], o["line"], o["col"]) != (m.group(1), int(m.group(2)), int(m.group(3))):
            return self.fail(name, "position differs from text mode")
        self.ok(name)


def corpus_files():
    files = []
    for d in CORPUS_DIRS:
        for p in glob.glob(os.path.join(ROOT, d, "**", "*.or"), recursive=True):
            files.append(p)
    return sorted(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin2", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if not os.path.exists(a.orin2):
        sys.exit("missing %s (run tools/bootstrap.sh)" % a.orin2)
    if a.no_build and os.path.exists(os.path.join(OUT, "orin")):
        fmt, parse = os.path.join(OUT, "orin"), os.path.join(OUT, "parse_main")
    else:
        fmt = build(a.orin2, "compiler/main.or", "orin")
        parse = build(a.orin2, "compiler/tests/parse_main.or", "parse_main")
    r = Runner(fmt, parse, a.v)
    pairs = sorted(glob.glob(os.path.join(ROOT, "tests", "fmt", "*.in.or")))
    files = corpus_files()
    errs = []
    for p in sorted(glob.glob(os.path.join(ROOT, "tests", "errors", "*"))):
        errs.append(os.path.join(p, "main.or") if os.path.isdir(p) else p)
    errs = [e for e in errs if os.path.exists(e)]
    # JSON only for errors that reach the checker/loader with a diagnostic (all of them do)
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        list(ex.map(r.check_pair, pairs))
        list(ex.map(r.check_corpus, files))
        list(ex.map(r.check_json, errs))
    print("pairs %d, corpus %d, json %d: %d passed, %d failed" % (len(pairs), len(files), len(errs), r.passed, len(r.failures)))
    sys.exit(1 if r.failures else 0)


if __name__ == "__main__":
    main()
