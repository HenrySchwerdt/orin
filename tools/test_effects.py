#!/usr/bin/env python3
"""Effect inference tests (ADR-0037 D2, docs/capabilities.md): `orin effects`, the OSIG `MAY_PERFORM` edges, the effect
sections of `orin diff`, and the `[effects]` policy of orin.toml, all with the self-hosted compiler.

1. `orin effects tests/osig/effects/app` (text and JSON) equals its goldens; the summaries are what the package was written
   to show: direct and transitive effects, evidence, an interface (union over the implementations), recursion, a function
   value of unknown origin (UNKNOWN), a closure literal and the callback of the std scope function `useHost`;
   explanation paths; determinism (other directory, copy of the package, no absolute path); filters; purity agreement;
2. the OSIG carries the same summaries (`MAY_PERFORM`, schema osig/0.2): every primitive call site is in the summary and the
   summaries are closed under the CALLS edges, also for the demo package, the I/O program and the compiler itself;
3. `orin diff` reports new and removed effects per function and module, with the explaining path and the entry points that
   now reach a new effect; a snapshot of osig/0.1 is compared without effect findings;
4. the policy: `[effects]` / `[effects.<module>]` (E0473, E0474, E0502, E0503), also enforced by `compile`.

Usage: python3 tools/test_effects.py [--orin build/bootstrap/orin2] [--update]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []
checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)
        print("FAIL: " + what)


def run(orin, args, cwd=None):
    r = subprocess.run([orin] + args, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout.decode(), r.stderr.decode()


def golden(path, text, update, what):
    if update:
        with open(path, "w") as f:
            f.write(text)
    with open(path) as f:
        check(f.read() == text, "%s equals %s (run with --update after a deliberate change)" % (what, os.path.relpath(path, ROOT)))


def copy_package(src, dst):
    shutil.copytree(src, dst)
    return dst


def patch(path, old, new):
    with open(path) as f:
        t = f.read()
    assert old in t, (path, old)
    with open(path, "w") as f:
        f.write(t.replace(old, new, 1))


def ops(effects):
    return sorted("%s:%s" % (e["operation"], e["evidence"]) for e in effects)


def sweep(orin):
    """The purity agreement and the "every HIR function has a def" check over the whole conformance corpus."""
    import glob
    files = []
    for pat in ("tests/run/*.or", "tests/next/run/*.or", "tests/contracts/*.or", "examples/*.or"):
        files += sorted(glob.glob(os.path.join(ROOT, pat)))
    ok = skipped = 0
    for f in files:
        rc, out, err = run(orin, ["effects", f, "--check-purity"])
        if out.startswith("purity: consistent"):
            ok += 1
        elif "error[" in err:
            skipped += 1                # a program that is meant not to type-check
        else:
            check(False, "%s: %s%s" % (os.path.relpath(f, ROOT), out, err[:300]))
    print("sweep: %d programs consistent, %d do not type-check, %d failures" % (ok, skipped, len(failures)))
    sys.exit(1 if failures else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--update", action="store_true", help="rewrite the goldens")
    ap.add_argument("--sweep", action="store_true",
                    help="only: run `orin effects --check-purity` over every conformance program that type-checks (minutes)")
    a = ap.parse_args()
    orin = os.path.abspath(a.orin)
    if a.sweep:
        sweep(orin)
        return
    app = os.path.join(ROOT, "tests", "osig", "effects", "app")
    gdir = os.path.join(ROOT, "tests", "osig", "effects")
    rel = "tests/osig/effects/app"
    tmp = tempfile.mkdtemp(prefix="orin-effects-")

    # ---- 1. orin effects ------------------------------------------------------------------------------
    rc, txt, err = run(orin, ["effects", rel])
    check(rc == 0, "orin effects exits 0 (%s)" % err)
    golden(os.path.join(gdir, "app.effects.txt"), txt, a.update, "orin effects text")
    rc, js, err = run(orin, ["effects", rel, "--format=json"])
    check(rc == 0, "orin effects --format=json exits 0 (%s)" % err)
    golden(os.path.join(gdir, "app.effects.json"), js, a.update, "orin effects JSON")
    rc, g, err = run(orin, ["graph", rel])
    check(rc == 0, "graph exits 0 (%s)" % err)
    golden(os.path.join(gdir, "app.graph.json"), g, a.update, "graph of the effects package")
    j = json.loads(js)
    check(j["schema"] == "effects/0.1" and j["package"] == "app" and j["typed"] is True, "effects JSON header")
    mods = {m["module"]: m for m in j["modules"]}
    fns = {f["function"]: f for f in j["functions"]}
    check(sorted(mods) == ["(root)", "dynamic", "plugins", "report", "store", "util"], "one entry per module: %s" % sorted(mods))
    check(ops(mods["util"]["effects"]) == [], "recursion without effects: the module is pure")
    check(ops(mods["store"]["effects"]) == ["Fs.ReadFile:MUST", "Fs.WriteFile:MUST"], "store: direct file input and output")
    check(ops(mods["report"]["effects"]) == ["Console.Write:MUST"], "report: ambient console output is an OUTPUT effect")
    check(ops(mods["plugins"]["effects"]) == ["Console.Write:MUST"], "plugins: the union over the implementations of the interface")
    check(ops(mods["dynamic"]["effects"]) == ["Unknown.FunctionValue:UNKNOWN"],
          "dynamic: a function value of unknown origin is UNKNOWN, not pure")
    check(ops(j["package_effects"]) == ["Console.Write:MUST", "Fs.ReadFile:MUST", "Fs.WriteFile:MUST", "Host.Acquire:MUST",
                                         "Unknown.FunctionValue:UNKNOWN"], "package: the union of the modules")
    entry = {e["operation"]: e for e in j["entry"]["effects"]}
    check(j["entry"]["function"] == "(root)::main"
          and set(entry) == {"Console.Write", "Fs.ReadFile", "Fs.WriteFile", "Host.Acquire", "Unknown.FunctionValue"},
          "entry point summary: %s" % sorted(entry))
    check(entry["Host.Acquire"]["evidence"] == "MUST" and entry["Fs.ReadFile"]["evidence"] == "MAY"
          and entry["Fs.WriteFile"]["evidence"] == "MAY",
          "main: its own call is MUST, what the callback of useHost does is MAY")
    hop_names = [h["function"] for h in entry["Fs.ReadFile"]["path"]]
    check(hop_names == ["(root)::main", "store::loadConfig"], "explanation path of Fs.ReadFile: %s" % hop_names)
    last = entry["Fs.ReadFile"]["path"][-1]
    check(last["span"]["file"] == "src/store/store.or" and last["span"]["line"] == 5,
          "the path ends at the primitive call (%s)" % last["span"])
    check([h["function"] for h in entry["Unknown.FunctionValue"]["path"]] == ["(root)::main", "dynamic::runDynamic"],
          "explanation path of the UNKNOWN effect")
    emit = {e["operation"]: e for e in fns["plugins::emitAll"]["summary"]["effects"]}
    check([h["function"] for h in emit["Console.Write"]["path"]]
          == ["plugins::emitAll", "plugins::each", "plugins::Plugin.run", "plugins::Logger.run"],
          "interface call: the path goes through the implementation")
    check(emit["Console.Write"]["evidence"] == "MAY", "transitive effects are MAY")
    check("util::fact" not in fns and "dynamic::runLiteral" not in fns and "plugins::Quiet.run" not in fns,
          "pure functions are not listed (also a closure literal handed to a function that calls its parameter)")
    check(fns["dynamic::apply"]["summary"]["callbacks"] == ["f"] and fns["dynamic::apply"]["summary"]["effects"] == [],
          "a function that calls its parameter has no effect of its own and names the callback")
    check(ops(fns["store::reload"]["summary"]["effects"]) == ["Fs.ReadFile:MAY"], "transitive: reload reads through loadConfig")
    rc, t2, _ = run(orin, ["effects", rel, "--summary", "--no-paths"])
    check(rc == 0 and "function " not in t2 and "-> " not in t2 and "module store: 2 effects" in t2,
          "--summary --no-paths prints modules only")
    rc, t3, _ = run(orin, ["effects", rel, "--module", "store", "--function", "reload"])
    check(rc == 0 and "function store::reload" in t3 and "function store::saveConfig" not in t3 and "module report" not in t3,
          "--module / --function filter")
    other = os.path.join(tmp, "elsewhere")
    os.makedirs(other)
    rc, t4, _ = run(orin, ["effects", app], cwd=other)
    check(t4 == txt, "same text from another working directory (absolute package path)")
    cp = copy_package(app, os.path.join(tmp, "some", "deep", "app-copy"))
    rc, t5, _ = run(orin, ["effects", cp, "--format=json"], cwd=other)
    check(t5 == js, "same JSON from a copy of the package at another path")
    check(ROOT not in txt and ROOT not in js and "/tmp/" not in js, "no absolute path in the output")
    rc, out, err = run(orin, ["effects", rel, "--check-purity"])
    check(rc == 0 and "purity: consistent" in out, "the summaries agree with the purity analysis (%s%s)" % (out, err))
    rc, out, err = run(orin, ["effects"])
    check(rc == 2 and "usage" in err, "effects without a path is a usage error")
    bad = os.path.join(tmp, "bad.or")
    with open(bad, "w") as f:
        f.write("function main(): void { const x: int = true; }\n")
    rc, out, err = run(orin, ["effects", bad])
    check(rc == 1 and "E0400" in err and out == "", "a program that does not check has no summary: the diagnostics, exit 1")

    # ---- 2. the OSIG carries the same summaries -----------------------------------------------------------
    sg = json.loads(g)
    nodes = {n["id"]: n for n in sg["nodes"]}
    check(sg["schema"] == "osig/0.4", "snapshot schema is osig/0.4")
    mp = [e for e in sg["edges"] if e["kind"] == "MAY_PERFORM"]
    check(len(mp) > 5 and all(e["evidence"] in ("MUST", "MAY", "UNKNOWN") and "next" in e and e["src"] in nodes and e["dst"] in nodes
                              and (e["next"] == "" or e["next"] in nodes) for e in mp),
          "MAY_PERFORM edges: evidence, next, existing endpoints")
    summary = {}
    for e in mp:
        summary.setdefault(e["src"], set()).add((e["dst"], e["via"]))
    check(summary["app:(root)::main"] >= {("~io:Host.Acquire", "CONTROL"), ("~io:Fs.ReadFile", "INPUT"),
                                          ("~unknown", "Unknown.FunctionValue")}, "OSIG: the summary of main")
    check("app:util::fact" not in summary and "app:util::even" not in summary, "OSIG: pure functions have no MAY_PERFORM edge")
    be = [e for e in mp if e["src"] == "app:(root)::main" and e["dst"] == "~io:Fs.ReadFile"][0]
    check(be["next"] == "app:store::loadConfig" and be["evidence"] == "MAY", "OSIG: next names the callee the effect comes from")
    check(all(e["evidence"] == "UNKNOWN" for e in mp if e["dst"] == "~unknown") and
          all(e["evidence"] != "UNKNOWN" for e in mp if e["dst"] != "~unknown"), "OSIG: UNKNOWN exactly for the unknown effects")
    for what, target in (("effects package", rel), ("demo", "tests/osig/demo"), ("io", "tests/osig/io/main.or"),
                         ("compiler", "compiler/main.or")):
        rc, gg, err = run(orin, ["graph", target])
        sd = json.loads(gg)
        sm = {}
        for e in sd["edges"]:
            if e["kind"] == "MAY_PERFORM":
                sm.setdefault(e["src"], set()).add((e["dst"], e["via"]))
        bad_edges = [(e["src"], e["dst"]) for e in sd["edges"] if e["kind"] == "CALLS" and e["dst"] != "~unknown" and e["dst"] in sm
                     and not sm[e["dst"]] <= sm.get(e["src"], set())]
        check(rc == 0 and not bad_edges, "%s: summaries closed under calls (%s)" % (what, bad_edges[:3]))
        direct = {(e["src"], e["dst"], e["via"]) for e in sd["edges"] if e["kind"] == "PERFORMS_IO"}
        check(all((d_, v_) in sm.get(s_, set()) for (s_, d_, v_) in direct), "%s: every PERFORMS_IO edge is in the summary" % what)

    # The capability gate of the compiler's tooling (rewrite step 3e, docs/capabilities.md): `analysis` performs no effect
    # of its own; it reads files only through the loader's `Sources` (MAY, every chain ends in Sources.read / exists)
    # and writes nothing (the `orin graph` / `diff` / `effects` drivers and their output file live in `tools`).
    rc, out, err = run(orin, ["effects", "compiler/main.or", "--format=json", "--module", "analysis"])
    an = {m["module"]: m for m in json.loads(out)["modules"]}["analysis"]["effects"] if rc == 0 else []
    check(rc == 0 and an and all(e["operation"] in ("Fs.ReadFile", "Fs.Stat") and e["evidence"] == "MAY" for e in an),
          "compiler: analysis has no direct effect, only file reads it inherits (%s)" % [(e["operation"], e["evidence"]) for e in an])
    check(all(e["path"][-1]["function"] in ("loader::Sources.read", "loader::Sources.exists") for e in an),
          "compiler: every file access of analysis goes through loader::Sources (%s)" % [e["path"][-1]["function"] for e in an])

    # @Test functions are not part of what a build ships: erased unless --tests
    tp = copy_package(app, os.path.join(tmp, "withtests"))
    with open(os.path.join(tp, "src", "util", "util.or"), "a") as f:
        f.write("\n@Test\nfunction loud(): void {\n  console.log(\"test\");\n}\n")
    rc, out, err = run(orin, ["effects", tp, "--format=json"])
    jt = {m["module"]: m for m in json.loads(out)["modules"]}
    check(rc == 0 and jt["util"]["effects"] == [], "@Test functions are erased: the module stays pure (%s)" % err)
    rc, out, err = run(orin, ["effects", tp, "--format=json", "--tests"])
    jt = {m["module"]: m for m in json.loads(out)["modules"]}
    check(rc == 0 and ops(jt["util"]["effects"]) == ["Console.Write:MUST"], "--tests includes them (%s)" % err)

    # ---- 3. diff: new and removed effects ------------------------------------------------------------------
    base = copy_package(app, os.path.join(tmp, "effbase"))
    head = copy_package(app, os.path.join(tmp, "effhead"))
    patch(os.path.join(head, "src", "util", "util.or"), "return n <= 1 ? 1 : n * fact(n - 1);",
          "console.log(\"fact\");\n  return n <= 1 ? 1 : n * fact(n - 1);")
    patch(os.path.join(head, "src", "store", "store.or"), "  writeFile(fs, path, text);\n", "")
    rc, dt, err = run(orin, ["diff", "--base", base, "--head", head])
    check(rc == 0, "effect diff exits 0 (%s)" % err)
    check("effect changes (transitive primitive effects" in dt, "text: effect section")
    check("  module util:\n    + Console.Write OUTPUT" in dt, "text: the module util gained Console.Write")
    check("  module store:\n    - Fs.WriteFile OUTPUT" in dt, "text: the module store lost Fs.WriteFile")
    check("  + app:util::fact  Console.Write OUTPUT [MUST]" in dt, "text: the function that now performs it")
    check("  - app:store::saveConfig  Fs.WriteFile OUTPUT [MUST]  (in base)" in dt, "text: the function that no longer performs it")
    check("  - app:(root)::main  Fs.WriteFile OUTPUT [MAY]" in dt and "-> app:store::saveConfig" in dt,
          "text: removed effects are explained in the base graph")
    check("reached from entry point app:(root)::main" in dt, "text: the entry points that now reach the new effect")
    check("MAY_PERFORM" not in dt, "the summary edges are not listed as plain edges")
    rc, dj, err = run(orin, ["diff", "--base", base, "--head", head, "--format=json"])
    d = json.loads(dj)
    check(d["effectsComparable"] is True and d["summary"]["effectsAdded"] >= 1 and d["summary"]["effectsRemoved"] >= 2,
          "json: effect counts")
    ch = {(c["kind"], c["function"], c["operation"]): c for c in d["effectChanges"]}
    c = ch.get(("added", "app:util::fact", "Console.Write"))
    check(c is not None and c["evidence"] == "MUST" and c["module"] == "util" and c["direction"] == "OUTPUT"
          and [p["function"] for p in c["path"]] == ["app:util::fact"], "json: added effect with its path (%s)" % c)
    check(c is not None and any(p["steps"][0]["node"] == "app:(root)::main" for p in c["reach"]["entryPaths"]),
          "json: entry points that reach the new effect")
    c = ch.get(("removed", "app:(root)::main", "Fs.WriteFile"))
    check(c is not None and [p["function"] for p in c["path"]] == ["app:(root)::main", "app:store::saveConfig"],
          "json: removed effect, path in the base")
    mm = {m["module"]: m for m in d["moduleEffects"]}
    check(mm["util"]["added"] == ["Console.Write OUTPUT"] and mm["store"]["removed"] == ["Fs.WriteFile OUTPUT"], "json: per module")
    rc, out, err = run(orin, ["diff", "--base", base, "--head", head, "--exit-code"])
    check(rc == 1, "--exit-code: an effect change is a difference")
    rc, dh, err = run(orin, ["diff", "--base", base, "--head", head, "--format=html"])
    check("<h2>Effect changes</h2>" in dh and "Console.Write OUTPUT" in dh and "<script" not in dh, "html: effect section")
    same = copy_package(app, os.path.join(tmp, "effsame"))
    patch(os.path.join(same, "src", "store", "store.or"), "// Direct input", "// a comment\n\n// Direct input")
    rc, out, err = run(orin, ["diff", "--base", base, "--head", same, "--exit-code"])
    check(rc == 0 and "no differences" in out, "an unchanged effect summary reports nothing")
    old = os.path.join(ROOT, "tests", "osig", "demo.graph.osig-0.1.json")
    rc, out, err = run(orin, ["diff", "--base", old, "--head", "tests/osig/demo", "--format=json"])
    d1 = json.loads(out)
    check(rc == 0 and d1["effectsComparable"] is False and d1["effectChanges"] == [] and d1["differences"] is False,
          "an osig/0.1 snapshot is read; the effects are not compared (%s%s)" % (out[:100], err))

    # ---- 4. the [effects] policy of orin.toml ----------------------------------------------------------------
    n = [0]

    def variant(toml_extra):
        n[0] += 1
        d_ = copy_package(app, os.path.join(tmp, "pol%d" % n[0]))
        with open(os.path.join(d_, "orin.toml"), "a") as f:
            f.write("\n" + toml_extra)
        return d_

    rc, out, err = run(orin, ["check", app])
    check(rc == 0, "without [effects] there is no restriction (%s)" % err)
    permissive = '[effects]\nallowed = ["Console", "Fs", "Host", "Unknown"]\n'
    rc, out, err = run(orin, ["check", variant(permissive)])
    check(rc == 0, "package default that covers every effect: ok (%s)" % err)
    rc, out, err = run(orin, ["check", variant(permissive + '[effects.util]\nallowed = []\n')])
    check(rc == 0, "a pure module under an empty allowance: ok (%s)" % err)
    rc, out, err = run(orin, ["check", variant(permissive + '[effects.store]\nallowed = ["Fs.ReadFile"]\n')])
    check(rc == 1 and "error[E0473]" in err and "module `store` may perform `Fs.WriteFile` (OUTPUT, MUST)" in err
          and "[effects.store] allows only [Fs.ReadFile]" in err, "E0473: store may write a file it does not allow (%s)" % err)
    check("src/store/store.or:" in err and "store::saveConfig" in err and "performs Fs.WriteFile" in err,
          "E0473: points at the call and explains the path (%s)" % err)
    rc, out, err = run(orin, ["check", variant(permissive + '[effects.report]\nallowed = []\n')])
    check(rc == 1 and "module `report` may perform `Console.Write`" in err and "no effects" in err,
          "E0473: an empty allowance rejects the console output (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallowed = ["Fs"]\n')])
    check(rc == 1 and err.count("error[E0473]") >= 4 and "module `report`" in err and "module `plugins`" in err
          and "the package [effects]" in err, "E0473: the package default applies to every module without a table (%s)" % err)
    rc, out, err = run(orin, ["check", variant(permissive + '[effects.dynamic]\nallowed = ["Fs"]\n')])
    check(rc == 1 and "effect whose target is not known" in err and "call of a function value of unknown origin" in err,
          "E0473: an UNKNOWN effect exceeds an allowance without `Unknown` (%s)" % err)
    rc, out, err = run(orin, ["check", variant(permissive + '[effects.dynamic]\nallowed = ["Unknown"]\n')])
    check(rc == 0, "... and is accepted when `Unknown` is allowed (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallowed = ["*"]\n')])
    check(rc == 0, '"*" allows everything (%s)' % err)
    rc, out, err = run(orin, ["check", variant('[effects."."]\nallowed = ["Console.Write", "Host.Acquire", "Fs.ReadFile", "Unknown"]\n')])
    check(rc == 1 and "module `(root)` may perform `Fs.WriteFile`" in err and "(root)::main" in err and "store::saveConfig" in err,
          "E0473: effects are transitive across modules, with the path through the callee (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallowed = ["Fs.Delete"]\n')])
    check(rc == 1 and "error[E0474]" in err and "unknown effect `Fs.Delete`" in err, "E0474: unknown effect name (%s)" % err)
    # located in the manifest (it used to be rendered as a position in the first source file)
    check("orin.toml:" in err.split("error[E0474]")[0].splitlines()[-1], "E0474 points into orin.toml (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects.nothere]\nallowed = []\n')])
    check(rc == 1 and "error[E0502]" in err and "`nothere`" in err, "E0502: a table for a module that does not exist (%s)" % err)
    check("orin.toml:" in err.split("error[E0502]")[0].splitlines()[-1], "E0502 points into orin.toml (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallowed = "Fs"\n')])
    check(rc == 1 and "error[E0503]" in err, "E0503: allowed must be an array of strings (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallow = []\n')])
    check(rc == 1 and "error[E0503]" in err and "expected allowed" in err, "E0503: unknown key (%s)" % err)
    rc, out, err = run(orin, ["check", variant('[effects]\nallowed = []\n[effects]\nallowed = []\n')])
    check(rc == 1 and "duplicate table `[effects]`" in err, "a duplicate [effects] table is a TOML error (%s)" % err)
    pv = variant(permissive + '[effects.store]\nallowed = ["Fs.ReadFile"]\n')
    rc, out, err = run(orin, ["compile", os.path.join(pv, "src", "main.or"), "-o", os.path.join(tmp, "x.c")])
    check(rc == 1 and "error[E0473]" in err and not os.path.exists(os.path.join(tmp, "x.c")),
          "compile fails on a policy violation (%s)" % err)
    rc, out, err = run(orin, ["check", "--format=json", pv])
    check(rc == 1 and '"code":"E0473"' in out and "store::saveConfig" in out, "check --format=json reports E0473 with the path (%s)" % out[:200])
    rc, out, err = run(orin, ["effects", pv])
    check(rc == 1 and "error[E0473]" in err and "module store:" in out, "orin effects prints the policy violations (%s)" % err)

    # ---- 5. --target=wasm64-orbit: the Orbit capability manifest (analysis/orbit.or, E0523) -----------------------
    wdir = os.path.join(ROOT, "tests", "wasm_target")
    marker = "/* Orbit capability manifest (ADR-0055): describes requirements, never authorises */"

    def manifest_of(name):
        out_c = os.path.join(tmp, name + ".c")
        rc, out, err = run(orin, ["compile", os.path.join(wdir, name + ".or"), "-o", out_c, "--target=wasm64-orbit"])
        text = open(out_c).read() if os.path.exists(out_c) else ""
        return rc, err, text

    def expected_tail(requires):
        # the JSON, then its quotes escaped for the assembler (\") and again for the C string literal (\\\")
        items = ",".join('"%s"' % r for r in requires)
        asm = r'{"abi":1,"requires":[' + items + r'],"producer":"orin"}'
        asm = asm.replace('"', '\\"')
        c = r'.section .custom_section.orbit.manifest,"",@\n.ascii "' + asm + r'"\n.text\n'
        c = c.replace('\\', '\\\\').replace('"', '\\"').replace('\\\\n', '\\n')
        return marker + '\n__asm__("' + c + '");\n'
    want = {
        "hello": ["log/v1"],
        "clock": ["clock/v1", "log/v1"],
        "exit": ["log/v1"],
        # Task.* and Channel.* need no capability (the guest runs tasks itself, one at a time); the spawned closure is an
        # unresolved callback (Unknown.Callback), which adds clock/v1 like any function value
        "task": ["clock/v1", "log/v1"],
        "channel": ["clock/v1", "log/v1"],
        "closure": ["clock/v1", "log/v1"],  # an unresolved call (Unknown.*): conservative, not an error
    }
    for name, req in want.items():
        rc, err, text = manifest_of(name)
        check(rc == 0 and text.endswith(expected_tail(req)), "wasm64-orbit %s: manifest %s ends the C file (%s)" % (name, req, err + text[-300:]))
        check(text.count("orbit.manifest") == 1, "wasm64-orbit %s: exactly one manifest section" % name)
    # the literal shape from the specification, for one case
    rc, err, text = manifest_of("clock")
    check(text.endswith(marker + '\n__asm__(".section .custom_section.orbit.manifest,\\"\\",@\\n.ascii \\"{\\\\\\"abi\\\\\\":1,\\\\\\"requires\\\\\\":'
                        '[\\\\\\"clock/v1\\\\\\",\\\\\\"log/v1\\\\\\"],\\\\\\"producer\\\\\\":\\\\\\"orin\\\\\\"}\\"\\n.text\\n");\n'), "the manifest has the specified literal shape")
    rc, err, text = manifest_of("fs")
    check(rc == 1 and "error[E0523]" in err and "`main` needs Fs.ReadFile, which the wasm64-orbit target does not provide" in err
          and "fs.or:4:" in err and text == "", "wasm64-orbit: an Fs program is rejected with E0523 and evidence (%s)" % err)
    plain = os.path.join(tmp, "plain.c")
    rc, out, err = run(orin, ["compile", os.path.join(wdir, "clock.or"), "-o", plain])
    check(rc == 0 and "orbit.manifest" not in open(plain).read(), "without --target the C has no manifest (%s)" % err)
    native = os.path.join(tmp, "native.c")
    rc, out, err = run(orin, ["compile", os.path.join(wdir, "clock.or"), "-o", native, "--target=native"])
    check(rc == 0 and open(native).read() == open(plain).read(), "--target=native is byte-identical to no --target (%s)" % err)
    rc, out, err = run(orin, ["compile", os.path.join(wdir, "hello.or"), "-o", os.path.join(tmp, "l.ll"), "--target=wasm64-orbit", "--backend=llvm"])
    check(rc == 2 and "needs the C backend" in err, "usage error: wasm64-orbit with --backend=llvm (%s)" % err)
    rc, out, err = run(orin, ["compile", os.path.join(wdir, "hello.or"), "-o", os.path.join(tmp, "l.c"), "--target=wasm64-orbit", "--split", "2"])
    check(rc == 2 and "needs the C backend" in err, "usage error: wasm64-orbit with --split (%s)" % err)
    rc, out, err = run(orin, ["compile", os.path.join(wdir, "hello.or"), "-o", os.path.join(tmp, "l.c"), "--target=arm"])
    check(rc == 2 and "unknown target `arm`" in err, "usage error: unknown target (%s)" % err)

    shutil.rmtree(tmp, ignore_errors=True)
    print("%d checks, %d failures" % (checks, len(failures)))
    sys.exit(1 if failures else 0)


main()
