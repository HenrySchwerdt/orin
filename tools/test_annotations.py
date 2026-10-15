#!/usr/bin/env python3
"""End-to-end tests of the built-in annotations (ADR-0024, docs/testing.md). Stdlib only.

Usage: python3 tools/test_annotations.py [--orinc build/bootstrap/orin2]

Covers `orin test` (passing, failing, trapping, non-zero exit, timeout, filter, JSON, package
directory, compile errors, no tests), `@Deprecated` warnings (text and JSON) and the API snapshot, and
the `@Inline` hint in both backends. The conformance cases (run/errors) live in tests/next and the
@Test erasure check in tools/test_annotation_erasure.py.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join("tests", "next", "orin_test")
failures = []
passed = 0


def run(args, timeout=180, env=None):
    r = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
        print("ok   " + name)
    else:
        failures.append(name)
        print("FAIL " + name + ("\n     " + detail.replace("\n", "\n     ") if detail else ""))


def main():
    global passed
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    a = ap.parse_args()
    orin = a.orinc if os.path.isabs(a.orinc) else os.path.join(ROOT, a.orinc)
    t = lambda *x: run([orin, "test"] + list(x))

    # --- orin test: all pass --------------------------------------------------------------------------
    rc, out, err = t(os.path.join(FIX, "pass.or"))
    check("test: all pass -> exit 0", rc == 0, out + err)
    check("test: PASS lines and summary", "PASS pass.addsPairs" in out and "PASS pass.closuresAndArrays" in out
          and "3 passed, 0 failed" in out, out)
    check("test: the program's main does not run, passing output is hidden",
          "main must not run" not in out and "hidden for passing" not in out, out)

    # --- contracts are checked at run time in tests (ADR-0012) -----------------------------------------
    rc, out, err = t(os.path.join(FIX, "contracts.or"))
    check("test: a violated contract fails the test", rc == 1 and "PASS contracts.validCall" in out
          and "FAIL contracts.violatesPrecondition (trap" in out and "contract violated" in out and out.rstrip().endswith("1 passed, 1 failed"), out + err)
    rc, out, err = t("--no-contracts", os.path.join(FIX, "contracts.or"))
    check("test: --no-contracts builds without contract checks", rc == 0 and "2 passed, 0 failed" in out, out + err)

    # --- the test executable under ASan + UBSan (--cc takes flags) ------------------------------------
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
    san = "cc -fsanitize=address,undefined -fno-omit-frame-pointer"
    rc, out, err = run([orin, "test", "--cc", san, os.path.join(FIX, "pass.or")], env=env)
    check("test: sanitized build passes", rc == 0 and "3 passed, 0 failed" in out, out + err)
    rc, out, err = run([orin, "test", "--cc", san, "--filter", "addsMore", os.path.join(FIX, "pkg")], env=env)
    check("test: sanitized package build (nothing matches -> exit 0)", rc == 0 and "0 passed, 0 failed, 5 filtered out" in out, out + err)

    # --- mixed: failing, trapping, exiting, hanging; the others still run -----------------------------
    def mixed_tests():
        rc, out, err = t("--timeout", "2", os.path.join(FIX, "mixed.or"))
        check("test: failures -> exit 1", rc == 1, out + err)
        check("test: passing tests around failures still run",
              "PASS mixed.passes" in out and "PASS mixed.stillRunsAfterFailures" in out, out)
        check("test: failed assertion shows expected/got", re.search(r"FAIL mixed\.assertionFails \(trap, exit 101\).*\n\s+stderr: trap: assertEq failed: expected to fail: expected 5, got 4", out) is not None, out)
        check("test: bounds trap with captured stdout", "FAIL mixed.trapsOnBounds (trap" in out and "trap: index out of bounds" in out
              and "stdout: before the trap" in out, out)
        check("test: non-zero exit", "FAIL mixed.exitsNonZero (exit 3)" in out, out)
        check("test: explicit fail()", "FAIL mixed.explicitFail" in out and "reached a place that must not be reached" in out, out)
        check("test: timeout", "FAIL mixed.hangs (timeout" in out, out)
        check("test: summary", out.rstrip().endswith("2 passed, 5 failed"), out)

        # --- filter ---------------------------------------------------------------------------------------
        rc, out, err = t("--filter", "passes", os.path.join(FIX, "mixed.or"))
        check("test: --filter selects by substring of the id", rc == 0 and out.strip().splitlines() == ["PASS mixed.passes", "1 passed, 0 failed, 6 filtered out"], out + err)
        rc, out, err = t("--filter", "zzz", os.path.join(FIX, "mixed.or"))
        check("test: --filter matching nothing -> exit 0", rc == 0 and "0 passed, 0 failed, 7 filtered out" in out, out + err)

        # --- JSON -----------------------------------------------------------------------------------------
        jargs = ["--format=json", "--timeout", "1", "--filter", "mixed.", os.path.join(FIX, "mixed.or")]
        rc, out, err = t(*jargs)
        try:
            j = json.loads(out)
        except ValueError:
            j = None
        check("test: --format=json is one JSON object", j is not None and out.count("\n") == 1, out)
        if j:
            check("test: json summary fields", j["ok"] is False and j["total"] == 7 and j["passed"] == 2 and j["failed"] == 5 and j["filtered"] == 0, out)
            names = [x["name"] for x in j["tests"]]
            check("test: json tests in discovery order", names == ["passes", "assertionFails", "trapsOnBounds", "exitsNonZero", "explicitFail", "stillRunsAfterFailures", "hangs"], str(names))
            first = j["tests"][0]
            check("test: json passing test keys", list(first.keys()) == ["id", "unit", "name", "file", "line", "col", "status", "exitCode"]
                  and first["status"] == "pass" and first["id"] == "mixed.passes" and first["line"] == 11, str(first))
            bad = j["tests"][1]
            check("test: json failing test keys", list(bad.keys()) == ["id", "unit", "name", "file", "line", "col", "status", "exitCode", "reason", "stdout", "stderr"]
                  and bad["status"] == "fail" and bad["reason"] == "trap" and bad["exitCode"] == 101
                  and "expected 5, got 4" in bad["stderr"], str(bad))
            check("test: json has a warnings array", j["warnings"] == [], out)
        rc2, out2, _ = t(*jargs)
        check("test: json output is deterministic", out == out2)


    mixed_tests()

    # --- no tests, compile errors, usage --------------------------------------------------------------
    rc, out, err = t(os.path.join(FIX, "none.or"))
    check("test: no tests -> exit 0 and a note", rc == 0 and "no tests found" in out, out + err)
    rc, out, err = t("--format=json", os.path.join(FIX, "none.or"))
    check("test: no tests (json)", rc == 0 and json.loads(out)["total"] == 0, out + err)
    rc, out, err = t(os.path.join(FIX, "type_error.or"))
    check("test: a test that does not type-check -> exit 1 with the diagnostic", rc == 1 and "E0400" in err and "type_error.or:6" in err, out + err)
    rc, out, err = t("--format=json", os.path.join(FIX, "type_error.or"))
    check("test: compile errors as JSON diagnostics", rc == 1 and json.loads(out.splitlines()[0])["code"] == "E0400", out + err)
    rc, out, err = run([orin, "test"])
    check("test: usage error -> exit 2", rc == 2 and "usage: orin test" in err, err)
    rc, out, err = t("--bogus", "x.or")
    check("test: unknown option -> exit 2", rc == 2, err)
    rc, out, err = t("tests/next/orin_test/does_not_exist.or")
    check("test: missing file -> exit 1 (E0301)", rc == 1 and "E0301" in err, out + err)

    # --- package directory ----------------------------------------------------------------------------
    rc, out, err = t(os.path.join(FIX, "pkg"))
    lines = out.strip().splitlines()
    check("test: package directory, tests in several modules (same name twice)",
          rc == 1 and "PASS mathx/add.testAdd" in lines and "PASS strs/shout.testAdd" in lines and "PASS main.testAdd" in lines
          and "PASS main.testShout" in lines and any(l.startswith("FAIL mathx/add.testAddFails") for l in lines)
          and lines[-1] == "4 passed, 1 failed", out + err)

    # --- @Deprecated: warnings ------------------------------------------------------------------------
    rc, out, err = t(os.path.join(FIX, "deprecated_use.or"))
    check("test: deprecated use is a warning, not an error", rc == 0 and "warning[W0440]: `stale` is deprecated: use fresh" in err, out + err)
    rc, out, err = t("--format=json", os.path.join(FIX, "deprecated_use.or"))
    jw = json.loads(out)["warnings"] if rc == 0 else []
    check("test: warnings in the JSON report", len(jw) == 1 and jw[0]["code"] == "W0440" and jw[0]["severity"] == "warning", out + err)

    dep = os.path.join("tests", "next", "run", "annotations_deprecated.or")
    rc, out, err = run([orin, "check", dep])
    check("check: deprecated uses warn and exit 0", rc == 0 and err.count("warning[W0440]") == 6
          and "`Counter.incr` is deprecated: use bump" in err and "`Shape.circumference` is deprecated" in err, err)
    lines_w = [int(m) for m in re.findall(r"annotations_deprecated\.or:(\d+):", err)]
    check("check: no warning at declarations or inside other deprecated declarations (only main's body)", lines_w and min(lines_w) >= 66, str(lines_w))
    rc, out, err = run([orin, "check", "--format=json", dep])
    rows = [json.loads(l) for l in out.splitlines()]
    check("check --format=json: warnings have severity warning", rc == 0 and len(rows) == 6 and all(r["severity"] == "warning" and r["code"] == "W0440" for r in rows), out + err)
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "dep.c")
        rc, out, err = run([orin, "compile", dep, "-o", c])
        check("compile: warns and still produces code", rc == 0 and os.path.getsize(c) > 0 and "warning[W0440]" in err, err)

        # --- api snapshot --------------------------------------------------------------------------------
        src = "export function f(): int {\n  return 1;\n}\n\nexport class K {\n  n: int;\n  constructor() {\n    this.n = 0;\n  }\n  g(): int {\n    return 1;\n  }\n}\n\nfunction main(): void {\n}\n"
        before = os.path.join(tmp, "m.or")
        with open(before, "w") as fh:
            fh.write(src)
        rc, snap, err = run([orin, "api", before])
        with open(os.path.join(tmp, "snap.txt"), "w") as fh:
            fh.write(snap + "\n")
        with open(before, "w") as fh:
            fh.write(src.replace("export function f", "@Deprecated(\"use h\")\nexport function f").replace("  g():", "  @Deprecated(\"use k\")\n  g():")
                     .replace("export class K", "@Inline\n@Test\nexport function ignored(): void {\n}\n\nexport class K"))
        rc, out, err = run([orin, "api", "--check", os.path.join(tmp, "snap.txt"), before])
        check("api --check reports an added @Deprecated (exit 1)", rc == 1 and '+   @Deprecated("use h")' in err and '+     @Deprecated("use k")' in err, out + err)
        check("api: @Test / @Inline are not part of the API (an exported @Test function is not listed)", "@Inline" not in err and "@Test" not in err and "ignored" not in err, err)
        rc, out, err = run([orin, "api", before])
        check("api: snapshot lists the deprecation indented under its declaration", '  @Deprecated("use h")\n  function f(): int' in out, out)

    # --- @Inline reaches both backends ------------------------------------------------------------------
    inl = os.path.join("tests", "next", "run", "annotations_inline.or")
    with tempfile.TemporaryDirectory() as tmp:
        c, ll = os.path.join(tmp, "a.c"), os.path.join(tmp, "a.ll")
        run([orin, "compile", inl, "-o", c])
        run([orin, "compile", inl, "-o", ll, "--backend=llvm"])
        ctext, lltext = open(c).read(), open(ll).read()
        inline_c = re.findall(r"^static inline [^\n]*orin_fn_\d+_(\w+)\(", ctext, re.M)
        plain_c = [m for m in re.findall(r"^(?!static inline )\w[^\n(]*\borin_fn_\d+_(\w+)\([^\n]*;$", ctext, re.M)]
        check("C backend: @Inline functions are `static inline`", {"annotations_inline_square", "annotations_inline_pick", "annotations_inline_a1", "annotations_inline_a2"} <= set(inline_c)
              and any(x.endswith("Counter_incr") for x in inline_c), str(inline_c))
        check("C backend: other functions are not", "annotations_inline_viaValue" in plain_c and "annotations_inline_main" in plain_c
              and not any("viaValue" in x or x.endswith("_main") for x in inline_c), str(plain_c))
        inline_ll = re.findall(r"^define internal [^\n]*@orin_fn_\d+_(\w+)\([^\n]*\) alwaysinline nounwind", lltext, re.M)
        check("LLVM backend: @Inline functions are alwaysinline", {"annotations_inline_square", "annotations_inline_pick", "annotations_inline_a1", "annotations_inline_a2"} <= set(inline_ll)
              and not any("viaValue" in x or x.endswith("_main") for x in inline_ll), str(inline_ll))

    print("annotations: %d checks passed, %d failed" % (passed, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
