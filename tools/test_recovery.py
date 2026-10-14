#!/usr/bin/env python3
"""Parser error recovery tests (docs/rewrite.md "Parser error recovery").

Usage: python3 tools/test_recovery.py --orinc <compiler> [--update]

Every `tests/recovery/<name>.or` (or `<name>/main.or`) is a program with several syntax errors; `<name>.err` holds the
exact stderr of `orin check` on it (run from the repository root). For each test:
  * `check` prints exactly `<name>.err` and exits 1;
  * `compile -o /dev/null` prints the same (the load fails before anything else runs);
  * `check --format=json` reports the same diagnostics: one JSON object per error, same codes, lines and columns, and
    the note on the last one when the cap of 20 was reached;
  * at most 20 errors;
  * `fmt --check` refuses the file with syntax errors (exit status != 0) and leaves it untouched.
`--update` rewrites the `.err` files from the compiler's output (review the diff).
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join("tests", "recovery")
DIAG = re.compile(r"^(\S+?):(\d+):(\d+): error\[(E\d{4})\]: ")


def run(cmd):
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", required=True)
    ap.add_argument("--update", action="store_true")
    a = ap.parse_args()
    orinc = os.path.abspath(a.orinc)
    failures = []
    names = sorted(n[:-3] if n.endswith(".or") else n for n in os.listdir(os.path.join(ROOT, TESTS))
                   if n.endswith(".or") or os.path.isdir(os.path.join(ROOT, TESTS, n)))
    for name in names:
        entry = os.path.join(TESTS, name + ".or")
        if not os.path.exists(os.path.join(ROOT, entry)):
            entry = os.path.join(TESTS, name, "main.or")
        want_path = os.path.join(ROOT, TESTS, name + ".err")
        rc, _, err = run([orinc, "check", entry])
        if a.update:
            with open(want_path, "w", encoding="utf-8") as f:
                f.write(err)
        want = open(want_path, encoding="utf-8").read() if os.path.exists(want_path) else None
        probs = []
        if rc != 1:
            probs.append("check: exit status %d" % rc)
        if err != want:
            probs.append("check: stderr differs from %s.err:\n%s" % (name, err))
        crc, _, cerr = run([orinc, "compile", entry, "-o", "/dev/null"])
        if crc != 1 or cerr != err:
            probs.append("compile: exit %d, stderr differs from check:\n%s" % (crc, cerr))
        texts = [m.groups() for m in (DIAG.match(l) for l in err.splitlines()) if m]
        if not 2 <= len(texts) <= 20 and name != "end_of_file":
            probs.append("expected 2..20 errors, got %d" % len(texts))
        jrc, out, _ = run([orinc, "check", "--format=json", entry])
        js = [json.loads(l) for l in out.splitlines() if l.strip()]
        if jrc != 1 or [(d["file"], str(d["line"]), str(d["col"]), d["code"]) for d in js] != texts:
            probs.append("json: not the diagnostics of the text output:\n%s" % out)
        if js and len(js) == 20 and js[-1]["notes"] != ["further syntax errors suppressed"]:
            probs.append("json: the 20th error lacks the note")
        for bad in sorted(set(t[0] for t in texts)):
            before = open(os.path.join(ROOT, bad), "rb").read()
            frc, _, _ = run([orinc, "fmt", "--check", bad])
            if frc == 0 or open(os.path.join(ROOT, bad), "rb").read() != before:
                probs.append("fmt --check accepted or changed %s, which has syntax errors" % bad)
        if probs:
            failures.append(name)
            print("FAIL %s\n  %s" % (name, "\n  ".join(probs)))
        else:
            print("ok   %s (%d errors)" % (name, len(texts)))
    print("recovery: %d passed, %d failed" % (len(names) - len(failures), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
