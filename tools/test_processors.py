#!/usr/bin/env python3
"""End-to-end tests of annotation processors (ADR-0046 S5, docs/annotation-processors.md). Stdlib only.

Usage: python3 tools/test_processors.py [--orinc build/bootstrap/orin2] [--cc cc] [--clang clang]

* A working processor: `tests/next/run/processor_describe` (an `@Describe` annotation whose processor generates a function
  that returns a string) is compiled, built and run on the C backend and, when clang is available, on the LLVM backend.
* Rules: an impure processor and every kind of wrong signature or placement are E0448; the checker needs no `.gen` import.
* Limits: a trapping processor, a timeout (`--processor-timeout`), an output above 16 MiB and more than 10,000 generated
  declarations are E0520 with the processor, the module and the captured stderr.
* Cache: the first build builds the helper and runs it, the second build reuses the output without running anything, a third
  build with another input reuses the helper (`--verbose` reports it, and the helper file is not touched).
* `orin check` without a C compiler: W0490 and the companion stays empty; with a warm cache the compiler is not needed.
* The recorded-output sidecar (S4 test hook) wins over a processor.
* Examples (S6): `examples/json-codec` (`@Json` codecs) and `examples/routes` (`@Route` table) expand to a golden and print
  the same output on C and LLVM; `tests/processors/json_bad` has the processor diagnostics for unsupported field types.
* Trust: a processor of a dependency runs only when `[annotations] processors` lists the dependency or its module.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []
passed = 0


def run(args, timeout=300, cwd=None):
    r = subprocess.run(args, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    ap.add_argument("--clang", default=os.environ.get("CLANG", "clang"))
    a = ap.parse_args()
    orin = a.orinc if os.path.isabs(a.orinc) else os.path.join(ROOT, a.orinc)
    out = os.path.join(ROOT, "build", "processor_test")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    cache = os.path.join(out, "cache")
    P = os.path.join(ROOT, "tests", "processors")
    describe = os.path.join(ROOT, "tests", "next", "run", "processor_describe")
    rt = ["runtime/core/orin_runtime.c", "runtime/platform/orin_platform.c"]

    def compile_(entry, outfile, *extra, cache_dir=None):
        return run([orin, "compile", entry, "-o", outfile, "--processor-cache", cache_dir or cache] + list(extra))

    # --- a working processor, C backend ------------------------------------------------------------------------
    want = read(os.path.join(describe, "expected.out"))
    c_file = os.path.join(out, "describe.c")
    rc, so, se = compile_(os.path.relpath(os.path.join(describe, "main.or"), ROOT), c_file, "--verbose")
    check("describe: compiles", rc == 0, se)
    check("describe: the helper is built and run", "built the helper of `describeProc`" in se and "running `describeProc` for module `./models`" in se, se)
    exe = os.path.join(out, "describe")
    rc, so, se2 = run([a.cc, "-O1", "-w", "-I", "runtime/core", c_file] + rt + ["-lm", "-o", exe])
    check("describe: C build", rc == 0, se2)
    rc, so, se2 = run([exe])
    check("describe: runs (C)", rc == 0 and so == want, so + se2)

    # --- the LLVM backend ------------------------------------------------------------------------------------
    if shutil.which(a.clang):
        ll_file = os.path.join(out, "describe.ll")
        rc, so, se = compile_(os.path.relpath(os.path.join(describe, "main.or"), ROOT), ll_file, "--backend=llvm")
        check("describe: compiles (llvm)", rc == 0, se)
        lexe = os.path.join(out, "describe_llvm")
        rc, so, se2 = run([a.clang, "-O2", "-w", "-I", "runtime/core", ll_file] + rt + ["runtime/core/orin_runtime_llvm.c", "-lm", "-o", lexe])
        check("describe: LLVM build", rc == 0, se2)
        rc, so, se2 = run([lexe])
        check("describe: runs (LLVM)", rc == 0 and so == want, so + se2)
    else:
        print("skip describe on LLVM: no clang")

    # --- cache ---------------------------------------------------------------------------------------------
    work = os.path.join(out, "work")
    shutil.copytree(describe, work)
    ccache = os.path.join(out, "cache2")
    helpers = lambda: glob.glob(os.path.join(ccache, "*", "helper"))
    entry = os.path.relpath(os.path.join(work, "main.or"), ROOT)
    rc, so, se = compile_(entry, os.path.join(out, "c1.c"), "--verbose", cache_dir=ccache)
    check("cache: first build builds the helper", rc == 0 and "built the helper" in se and len(helpers()) == 1, se)
    h = helpers()[0]
    m1 = os.stat(h).st_mtime_ns
    time.sleep(0.05)
    rc, so, se = compile_(entry, os.path.join(out, "c2.c"), "--verbose", cache_dir=ccache)
    check("cache: second build reuses the output, runs nothing", rc == 0 and "reused the output of `describeProc`" in se
          and "running" not in se and "built" not in se, se)
    check("cache: the helper is untouched", os.stat(h).st_mtime_ns == m1)
    check("cache: same C with and without the cache", read(os.path.join(out, "c1.c")) == read(os.path.join(out, "c2.c")))
    with open(os.path.join(work, "models.or"), "a") as f:
        f.write("\n@Describe(\"another\")\nexport type Extra = { id: int; };\n")
    rc, so, se = compile_(entry, os.path.join(out, "c3.c"), "--verbose", cache_dir=ccache)
    check("cache: another input reuses the helper and runs it", rc == 0 and "reused the helper of `describeProc`" in se
          and "running `describeProc`" in se and "built the helper" not in se, se)
    check("cache: the helper is still untouched", os.stat(h).st_mtime_ns == m1)
    with open(os.path.join(work, "describe.or"), "a") as f:
        f.write("\nfunction unusedHelper(): int {\n  return 1;\n}\n")
    rc, so, se = compile_(entry, os.path.join(out, "c4.c"), "--verbose", cache_dir=ccache)
    check("cache: a changed processor module builds a new helper", rc == 0 and "built the helper" in se and len(helpers()) == 2, se)

    # --- orin check without a C compiler -------------------------------------------------------------------
    cold = os.path.join(out, "cold")
    rc, so, se = run([orin, "check", entry, "--processor-cache", cold, "--cc", "/nonexistent/cc"])
    check("check: no C compiler is W0490 and the companion stays empty", rc == 1 and "warning[W0490]: processors not run: no C compiler" in se
          and "error[E0300]" in se, se)
    rc, so, se = run([orin, "check", entry, "--processor-cache", ccache, "--cc", "/nonexistent/cc"])
    check("check: a warm cache needs no C compiler", rc == 0 and se == "", se)
    rc, so, se = run([orin, "compile", entry, "-o", os.path.join(out, "c5.c"), "--processor-cache", cold, "--cc", "/nonexistent/cc"])
    check("compile: no C compiler is E0520", rc == 1 and "error[E0520]: processor `describeProc`" in se and "the C compiler failed" in se, se)

    # --- the recorded output wins --------------------------------------------------------------------------
    side = os.path.join(out, "side")
    shutil.copytree(describe, side)
    recorded = read(glob.glob(os.path.join(ccache, "*", "out-*.json"))[0])
    with open(os.path.join(side, "models.gen.Describe.json"), "w") as f:
        f.write(recorded.replace("User - a person with a name", "RECORDED"))
    sexe = os.path.join(out, "side_exe")
    rc, so, se = compile_(os.path.relpath(os.path.join(side, "main.or"), ROOT), os.path.join(out, "side.c"), "--verbose")
    check("sidecar: compiles", rc == 0, se)
    check("sidecar: no processor is run", "running" not in se and "built" not in se, se)
    run([a.cc, "-O1", "-w", "-I", "runtime/core", os.path.join(out, "side.c")] + rt + ["-lm", "-o", sexe])
    rc, so, se = run([sexe])
    check("sidecar: its output is used", so.startswith("RECORDED\n"), so)

    # --- E0448: rules --------------------------------------------------------------------------------------
    rc, so, se = run([orin, "check", "tests/processors/impure/main.or", "--processor-cache", cache])
    check("impure: E0448", rc == 1 and "error[E0448]: the processor `noisyProc` is not pure: `anno.noisyProc` -> `anno.shout` performs I/O (console.log)" in se, se)
    rc, so, se = run([orin, "check", "tests/processors/bad_signature/main.or", "--processor-cache", cache])
    for frag in (
        "invalid processor `notExportedProc`: a processor must be exported",
        "invalid processor `wrongParamProc`: a processor takes exactly one parameter of type `Input` imported from \"std:meta\"",
        "invalid processor `genericProc`: a processor cannot be generic",
        "annotation `Twice` already has the processor `twiceProc`; there is one processor per annotation",
        "invalid processor `otherProc`: the annotation `Other` is declared in another module",
        "invalid processor `missingProc`: `Missing` is not an annotation that is declared or imported here",
        "`@Processor` applies to an exported top-level function only",
        "invalid processor `noArgProc`: `@Processor` takes exactly one argument",
    ):
        check("bad signature: " + frag[:60], rc == 1 and ("error[E0448]: " + frag) in se, se)

    # --- E0520: a processor that fails ---------------------------------------------------------------------
    rc, so, se = compile_("tests/processors/trap/main.or", os.path.join(out, "t.c"))
    check("trap: E0520 with processor, module and stderr", rc == 1
          and "error[E0520]: processor `boomProc` (`@Boom` on `Thing`, module `./models`) failed: trapped (exit status 101)" in se
          and "note: stderr: trap: index out of bounds" in se, se)
    t0 = time.time()
    rc, so, se = compile_("tests/processors/timeout/main.or", os.path.join(out, "t.c"), "--processor-timeout", "2")
    check("timeout: E0520", rc == 1 and "error[E0520]: processor `slowProc` (`@Slow` on `Thing`, module `./models`) failed: timed out after 2 s" in se, se)
    check("timeout: the run was stopped", time.time() - t0 < 60)
    rc, so, se = compile_("tests/processors/too_big/main.or", os.path.join(out, "t.c"))
    check("output limit: E0520", rc == 1 and "failed: produced more than 16777216 bytes of output" in se, se)
    rc, so, se = compile_("tests/processors/too_many/main.or", os.path.join(out, "t.c"))
    check("declaration limit: E0520", rc == 1 and "exceeds the limit of 10000 generated declarations per program" in se, se)
    rc, so, se = compile_("tests/processors/trap/main.or", os.path.join(out, "t.c"), "--processor-timeout", "x")
    check("bad --processor-timeout is a usage error", rc == 2 and "--processor-timeout needs a number" in se, se)
    check("failed runs are not cached", not [f for f in glob.glob(os.path.join(cache, "*", "out-*.json"))
                                              if "boom" in read(f)])

    # --- trust policy --------------------------------------------------------------------------------------
    rc, so, se = run([orin, "compile", "tests/processors/dep_untrusted", "-o", os.path.join(out, "d.c"), "--processor-cache", cache])
    check("dependency processor without the list: W0492 and no companion", rc == 1
          and "warning[W0492]: the processor `describeProc` of `@Describe` was not run: it comes from the dependency `lib` and is not listed in `[annotations] processors`" in se
          and "error[E0300]: `describeThing` is not exported by `./models.gen`" in se, se)
    for d in ("dep_trusted", "dep_trusted_module"):
        dc = os.path.join(out, d + ".c")
        rc, so, se = run([orin, "compile", "tests/processors/" + d, "-o", dc, "--processor-cache", cache])
        check("dependency processor listed (%s): compiles" % d, rc == 0 and "W0492" not in se, se)
        dexe = os.path.join(out, d)
        run([a.cc, "-O1", "-w", "-I", "runtime/core", dc] + rt + ["-lm", "-o", dexe])
        rc, so, se = run([dexe])
        check("dependency processor listed (%s): runs" % d, rc == 0 and so == "generated for Thing\n", so + se)

    # --- example packages: @Json codecs and a route table (ADR-0046 S6; examples/, not std) -------------------
    for label, d in (("json-codec", "examples/json-codec/app"), ("routes", "examples/routes")):
        full = os.path.join(ROOT, d)
        rc, so, se = run([orin, "expand", d, "--processor-cache", cache])
        check(label + ": orin expand matches the golden", rc == 0 and so == read(os.path.join(full, "expected.expand.txt")), se + so[:400])
        want = read(os.path.join(full, "expected.out"))
        cf = os.path.join(out, label + ".c")
        rc, so, se = run([orin, "compile", d, "-o", cf, "--processor-cache", cache])
        check(label + ": compiles (C)", rc == 0, se)
        cexe = os.path.join(out, label + "_c")
        rc, so, se = run([a.cc, "-O1", "-w", "-I", "runtime/core", cf] + rt + ["-lm", "-o", cexe])
        rc, so, se2 = run([cexe])
        check(label + ": runs (C) with the expected output", rc == 0 and so == want, so + se2)
        if shutil.which(a.clang):
            lf = os.path.join(out, label + ".ll")
            rc, so, se = run([orin, "compile", d, "-o", lf, "--backend=llvm", "--processor-cache", cache])
            check(label + ": compiles (llvm)", rc == 0, se)
            lexe = os.path.join(out, label + "_llvm")
            run([a.clang, "-O2", "-w", "-I", "runtime/core", lf] + rt + ["runtime/core/orin_runtime_llvm.c", "-lm", "-o", lexe])
            rc, so, se2 = run([lexe])
            check(label + ": runs (LLVM), same output as C", rc == 0 and so == want, so + se2)
    rc, so, se = run([orin, "check", "tests/processors/json_bad", "--processor-cache", cache])
    for frag in (
        "models.or:10:3: error[E0522]: @Json cannot encode field `ratio` of `Shape`: `float` is not supported: std:json has integers only",
        "models.or:11:3: error[E0522]: @Json cannot encode field `color` of `Shape`: the type `Color` is not supported",
        "models.or:12:3: error[E0522]: @Json cannot encode field `inner` of `Shape`: the record `Plain` needs @Json for its codecs",
        "models.or:13:3: error[E0522]: @Json cannot encode field `maybe` of `Shape`: Option<Option<...>> is not supported",
        "error[E0522]: @Json: the JSON key \"id\" is used twice in `Shape`",
    ):
        check("json-codec: diagnostic " + frag[frag.index("E0522"):][:60], rc == 1 and frag in se, se)

    print("\n%d passed, %d failed" % (passed, len(failures)))
    if failures:
        print("failed: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
