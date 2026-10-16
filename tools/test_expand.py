#!/usr/bin/env python3
"""End-to-end tests of companion modules and `orin expand` (ADR-0046 S4, docs/annotation-processors.md). Stdlib only.

Usage: python3 tools/test_expand.py [--orinc build/bootstrap/orin2] [--cc cc]

* Goldens: for every directory under tests/next/run that has an `expected.expand.txt`, `orin expand main.or` prints
  exactly that text (the review format), and `orin expand --input main.or` prints `expected.input.jsonl` (the std:meta
  `Input` of every processor run, one JSON document per line). The program itself is run by the conformance suite on both
  backends (the directory has an `expected.out`); `orin expand` is compared here.
* Codec: the std:meta decoder (library/std/metajson.or, compiled with the compiler under test) accepts every printed `Input`
  and every recorded `Output` of those directories, so the compiler side and std:meta agree on the encoding.
* Determinism: two runs print the same bytes.
* Unaffected programs: a program that does not import a `.gen` module compiles to the same C with and without recorded
  outputs next to its modules; a program without annotations is untouched by the pipeline.
* CLI: `orin expand` of a program without recorded outputs prints nothing and succeeds; a malformed recorded output is an
  error with exit status 1.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []
passed = 0


def run(args, timeout=240):
    r = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
        print("ok   " + name)
    else:
        failures.append(name)
        print("FAIL " + name + ("\n     " + detail.replace("\n", "\n     ") if detail else ""))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def first_diff(a, b):
    la, lb = a.split("\n"), b.split("\n")
    for i in range(max(len(la), len(lb))):
        x = la[i] if i < len(la) else "<end>"
        y = lb[i] if i < len(lb) else "<end>"
        if x != y:
            return "line %d:\n  expected: %s\n  actual:   %s" % (i + 1, x, y)
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    a = ap.parse_args()
    orin = a.orinc if os.path.isabs(a.orinc) else os.path.join(ROOT, a.orinc)
    out = os.path.join(ROOT, "build", "expand_test")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)

    # --- the codec checker, built once ----------------------------------------------------------------------
    codec_c = os.path.join(out, "codec_check.c")
    codec = os.path.join(out, "codec_check")
    rc, so, se = run([orin, "compile", "tests/expand/codec_check.or", "-o", codec_c])
    check("codec_check compiles", rc == 0, se)
    if rc == 0:
        rc, so, se = run([a.cc, "-O1", "-w", "-I", "runtime/core", codec_c, "runtime/core/orin_runtime.c",
                          "runtime/platform/orin_platform.c", "-lm", "-o", codec])
        check("codec_check builds", rc == 0, se)
    have_codec = os.path.exists(codec)

    dirs = sorted(d for d in glob.glob(os.path.join(ROOT, "tests", "next", "run", "*"))
                  if os.path.exists(os.path.join(d, "expected.expand.txt")))
    check("there are golden directories", len(dirs) >= 2, str(dirs))
    for d in dirs:
        name = os.path.basename(d)
        rel = os.path.relpath(d, ROOT)
        entry = os.path.join(rel, "main.or")

        # --- expand: the review text -----------------------------------------------------------------------
        rc, so, se = run([orin, "expand", entry])
        want = read(os.path.join(d, "expected.expand.txt"))
        check("expand %s: exit 0" % name, rc == 0, se)
        check("expand %s: golden" % name, so == want, first_diff(want, so))
        rc2, so2, se2 = run([orin, "expand", entry])
        check("expand %s: deterministic" % name, so2 == so)

        # --- expand --input: the snapshots -----------------------------------------------------------------
        gi = os.path.join(d, "expected.input.jsonl")
        if os.path.exists(gi):
            rc, so, se = run([orin, "expand", "--input", entry])
            check("expand --input %s: golden" % name, rc == 0 and so == read(gi), se + first_diff(read(gi), so))
            check("expand --input %s: one document per run, compact" % name,
                  all(l.startswith('{"format":"orin.meta.input","version":1,') for l in so.splitlines()) and so.endswith("\n"))
            if have_codec:
                rc, so3, se3 = run([codec, "input", gi])
                check("std:meta decodes the snapshots of %s" % name, rc == 0 and so3.count("ok") == len(so.splitlines()), so3 + se3)

        # --- the recorded outputs are valid std:meta Outputs ----------------------------------------------
        if have_codec:
            for rec in sorted(glob.glob(os.path.join(d, "*.gen.*.json"))):
                rc, so3, se3 = run([codec, "output", rec])
                check("std:meta decodes %s/%s" % (name, os.path.basename(rec)), rc == 0 and so3.strip() == "ok", so3 + se3)

    # --- unaffected programs: same C with and without recorded outputs -------------------------------------
    src = os.path.join(ROOT, "tests", "next", "run", "companion_basic")
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        for f in ("annos.or", "models.or"):
            shutil.copy(os.path.join(src, f), tmp)
        with open(os.path.join(tmp, "main.or"), "w") as f:
            f.write('import { makeUser } from "./models";\n\nfunction main(): void {\n  console.log(makeUser(1, "x").name);\n}\n')
        c1 = os.path.join(tmp, "plain.c")
        rc1, _, se1 = run([orin, "compile", os.path.join(tmp, "main.or"), "-o", c1])
        shutil.copy(os.path.join(src, "models.gen.Json.json"), tmp)
        c2 = os.path.join(tmp, "with_output.c")
        rc2, _, se2 = run([orin, "compile", os.path.join(tmp, "main.or"), "-o", c2])
        check("no .gen import: compiles with and without a recorded output", rc1 == 0 and rc2 == 0, se1 + se2)
        check("no .gen import: byte-identical C", rc1 == 0 and rc2 == 0 and read(c1) == read(c2))
        rc, so, se = run([orin, "compile", "--backend=llvm", os.path.join(tmp, "main.or"), "-o", os.path.join(tmp, "x.ll")])
        check("no .gen import: LLVM IR compiles", rc == 0, se)

        # --- expand of a program without runs / of a program that is not touched ---------------------------
        os.remove(os.path.join(tmp, "models.gen.Json.json"))
        rc, so, se = run([orin, "expand", os.path.join(tmp, "main.or")])
        check("expand without recorded outputs: prints nothing, exit 0", rc == 0 and so.strip() == "", so + se)

    # --- a companion import without any recorded output is an empty module -------------------------------------
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        for f in ("annos.or", "models.or"):
            shutil.copy(os.path.join(src, f), tmp)
        with open(os.path.join(tmp, "main.or"), "w") as f:
            f.write('import { nothing } from "./models.gen";\n\nfunction main(): void {\n}\n')
        rc, so, se = run([orin, "check", os.path.join(tmp, "main.or")])
        check("empty companion: importing a name from it is E0300", rc == 1 and "E0300" in se and "`nothing` is not exported by `./models.gen`" in se, se)
        with open(os.path.join(tmp, "main.or"), "w") as f:
            f.write('import {} from "./models.gen";\n\nfunction main(): void {\n  console.log("ok");\n}\n')
        rc, so, se = run([orin, "check", os.path.join(tmp, "main.or")])
        check("empty companion: importing nothing is fine", rc == 0, se)

    # --- malformed output: exit status 1 and the code -------------------------------------------------------------
    bad = os.path.join(ROOT, "tests", "next", "errors", "e0520_not_json", "main.or")
    rc, so, se = run([orin, "expand", bad])
    check("expand: malformed output is E0520, exit 1", rc == 1 and "E0520" in se, se)
    rc, so, se = run([orin, "expand", "--format=json", bad])
    check("expand: --format=json reports the diagnostic as JSON", rc == 1 and '"E0520"' in (so + se), so + se)

    # --- check and compile of the golden programs -----------------------------------------------------------------
    for d in dirs:
        name = os.path.basename(d)
        entry = os.path.join(os.path.relpath(d, ROOT), "main.or")
        rc, so, se = run([orin, "check", entry])
        check("check %s" % name, rc == 0, se)
        rc, so, se = run([orin, "mir", entry])
        check("mir %s (HIR -> MIR of the expanded program)" % name, rc == 0 and ".gen." in so, se)

    print("\n%d passed, %d failed" % (passed, len(failures)))
    if failures:
        print("failed: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
