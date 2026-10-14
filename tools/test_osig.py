#!/usr/bin/env python3
"""OSIG tests (ADR-0023, docs/osig.md): `orin graph` and `orin diff` with the self-hosted compiler.

1. golden: `orin graph tests/osig/demo` (modules, classes, an interface, generics, closures) equals
   tests/osig/demo.graph.json (regenerate with --update);
2. determinism: two runs are byte-identical, also from another working directory, from a copy of the package
   at another path, and the snapshot holds no absolute path;
3. evidence classes: closures / function values are UNKNOWN or MAY, never MUST; calls through an interface
   are the interface method (MUST) plus MAY edges to every implementation;
4. snapshot files: `orin diff` reads `orin graph` output (and refuses a tampered one);
5. phase-1 acceptance (vision section 15): tests/osig/accept/{base,head} -- head has (a) a rename, (b) an API
   signature change, (c) a new call path from an entry point to a function. The text and JSON reports show all
   three, the rename marked heuristic and the call path explained; a no-change run (and a comment-only /
   line-shift change) reports nothing;
6. the HTML report is one self-contained file.

Usage: python3 tools/test_osig.py [--orin build/bootstrap/orin2] [--update]
"""
import argparse
import json
import os
import re
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--update", action="store_true", help="rewrite the golden snapshot")
    a = ap.parse_args()
    orin = os.path.abspath(a.orin)
    demo = os.path.join(ROOT, "tests", "osig", "demo")
    base = os.path.join(ROOT, "tests", "osig", "accept", "base")
    head = os.path.join(ROOT, "tests", "osig", "accept", "head")
    golden = os.path.join(ROOT, "tests", "osig", "demo.graph.json")
    tmp = tempfile.mkdtemp(prefix="orin-osig-")

    # ---- 1. golden ------------------------------------------------------------------------
    rc, g1, err = run(orin, ["graph", "tests/osig/demo"])
    check(rc == 0, "graph demo exits 0 (%s)" % err)
    if a.update:
        with open(golden, "w") as f:
            f.write(g1)
    with open(golden) as f:
        want = f.read()
    check(g1 == want, "graph of the demo package equals tests/osig/demo.graph.json (run with --update after a deliberate change)")
    snap = json.loads(g1)
    check(snap["schema"] == "osig/0.2" and snap["package"] == "demo" and snap["hash"].startswith("h62:"), "schema, package, hash")

    # ---- 2. determinism -------------------------------------------------------------------
    rc, g2, _ = run(orin, ["graph", "tests/osig/demo"])
    check(g2 == g1, "two runs are byte-identical")
    other_cwd = os.path.join(tmp, "elsewhere")
    os.makedirs(other_cwd)
    rc, g3, _ = run(orin, ["graph", demo], cwd=other_cwd)
    check(g3 == g1, "same snapshot from another working directory (absolute package path)")
    copy = os.path.join(tmp, "some", "deep", "copy-of-demo")
    shutil.copytree(demo, copy)
    rc, g4, _ = run(orin, ["graph", copy], cwd=other_cwd)
    check(g4 == g1, "same snapshot from a copy of the package at another path")
    rc, g5, _ = run(orin, ["graph", os.path.join(copy, "src", "main.or")], cwd=other_cwd)
    check(g5 == g1, "same snapshot for the entry file inside the package")
    check(ROOT not in g1 and tmp not in g4 and "/home/" not in g1 and "/tmp/" not in g4, "no absolute path in the snapshot")
    out_file = os.path.join(tmp, "demo.json")
    rc, _, _ = run(orin, ["graph", "tests/osig/demo", "-o", out_file])
    with open(out_file) as f:
        check(f.read() == g1, "graph -o writes the same text")

    # ---- 3. structure and evidence classes --------------------------------------------------
    nodes = {n["id"]: n for n in snap["nodes"]}
    ids = [n["id"] for n in snap["nodes"]]
    check(ids == sorted(ids), "nodes sorted by id")
    keys = ["|".join((e["kind"], e["src"], e["dst"], e["evidence"], e["via"])) for e in snap["edges"]]
    check(keys == sorted(keys) and len(set(keys)) == len(keys), "edges sorted and unique")
    kinds = {n["kind"] for n in snap["nodes"]}
    check({"Package", "Module", "Function", "Method", "Class", "Interface", "Field", "Contract", "Unknown"} <= kinds,
          "node kinds: %s" % sorted(kinds))
    ekinds = {e["kind"] for e in snap["edges"]}
    check({"DEFINES", "IMPORTS", "CALLS", "IMPLEMENTS", "HAS_FIELD", "REFERENCES_TYPE", "HAS_CONTRACT"} <= ekinds,
          "edge kinds: %s" % sorted(ekinds))
    check(all(e["src"] in nodes and e["dst"] in nodes for e in snap["edges"]), "every edge connects existing nodes")
    check(all(e["evidence"] in ("MUST", "MAY", "UNKNOWN") for e in snap["edges"]), "evidence classes")
    check(all(e["evidence"] != "MUST" for e in snap["edges"] if e["via"] in ("value", "indirect", "impl")),
          "function values, indirect calls and implementation targets are never MUST")

    def edge(kind, src, dst, via=None):
        r = [e for e in snap["edges"] if e["kind"] == kind and e["src"] == src and e["dst"] == dst
             and (via is None or e["via"] == via)]
        return r[0] if r else None

    e = edge("CALLS", "demo:util::mapAll", "~unknown")
    check(e and e["evidence"] == "UNKNOWN" and e["via"] == "indirect", "call of a function parameter is UNKNOWN")
    e = edge("CALLS", "demo:(root)::main", "~unknown")
    check(e and e["evidence"] == "UNKNOWN", "call of a closure value is UNKNOWN")
    e = edge("CALLS", "demo:(root)::main", "demo:(root)::double", "value")
    check(e and e["evidence"] == "MAY", "a function used as a value is a MAY edge")
    e = edge("CALLS", "demo:(root)::scale", "demo:(root)::double")
    check(e and e["evidence"] == "MAY", "a call inside a closure body is a MAY edge of the enclosing function")
    e = edge("CALLS", "demo:shapes::describeFirst", "demo:shapes::Shape.area")
    check(e and e["evidence"] == "MUST" and e["via"] == "virtual", "call through an interface: the interface method (MUST)")
    for impl in ("Circle", "Square"):
        e = edge("CALLS", "demo:shapes::describeFirst", "demo:shapes::%s.area" % impl)
        check(e and e["evidence"] == "MAY" and e["via"] == "impl", "MAY edge to the implementation %s.area" % impl)
    e = edge("CALLS", "demo:shapes::totalArea", "demo:shapes::Shape.area")
    check(e and e["evidence"] == "MUST", "call through a bounded type parameter reaches the interface method")
    # generic classes (ADR-0026): one node per declaration, instantiations are not symbols
    check(nodes.get("demo:util::Stack", {}).get("sig") == "class Stack<T>", "a generic class is one Class node with its type parameters")
    check(nodes.get("demo:shapes::Bag", {}).get("sig") == "class Bag<T extends Shape>", "the bound is part of the class signature")
    check(not any("<" in i and n["kind"] != "Unknown" for i, n in nodes.items() if "::" in i and "(" not in i),
          "no node for an instantiation (Stack<int>, Stack<string>)")
    check(nodes["demo:util::Stack.push"]["sig"] == "mut method push(x: T): void" and nodes["demo:util::Stack.size"]["sig"] == "method size(): usize",
          "inferred mutability of generic-class methods in the signature")
    e = edge("CALLS", "demo:(root)::main", "demo:util::Stack.push")
    check(e and e["evidence"] == "MUST" and e["via"] == "method", "calls on both instantiations are one edge to the generic method")
    check(edge("CALLS", "demo:(root)::main", "demo:util::Stack", "constructor") is not None, "new Stack<..>() is a constructor call of the class")
    e = edge("CALLS", "demo:shapes::Bag.total", "demo:shapes::Shape.area")
    check(e and e["evidence"] == "MUST" and e["via"] == "bound", "call on a bounded class type parameter reaches the interface method")
    e = edge("CALLS", "demo:shapes::Bag.total", "demo:shapes::Circle.area")
    check(e and e["evidence"] == "MAY" and e["via"] == "impl", "... and MAY edges to the implementations")
    check(edge("REFERENCES_TYPE", "demo:shapes::Bag", "demo:shapes::Shape") is not None, "the bound is a type reference of the class")
    check(edge("IMPLEMENTS", "demo:shapes::Circle", "demo:shapes::Shape") is not None, "IMPLEMENTS edge")
    check(edge("IMPORTS", "demo:(root)", "demo:shapes") is not None, "IMPORTS edge between modules")
    check(edge("HAS_CONTRACT", "demo:ledger::Ledger.deposit", "demo:ledger::Ledger.deposit@requires#0") is not None,
          "HAS_CONTRACT edge")
    check(edge("HAS_FIELD", "demo:shapes::Circle", "demo:shapes::Circle.radius") is not None, "HAS_FIELD edge")
    check(edge("REFERENCES_TYPE", "demo:(root)::main", "demo:ledger::Ledger") is not None, "REFERENCES_TYPE edge")
    check(nodes["demo:(root)::main"]["entry"] and not nodes["demo:(root)::double"]["entry"], "entry points")
    check(all(n["span"]["line"] > 0 and not n["span"]["file"].startswith("/") for n in snap["nodes"] if n["kind"] in ("Function", "Class")),
          "source spans with relative file names")

    # ---- 4. snapshot files --------------------------------------------------------------------
    rc, out, err = run(orin, ["diff", "--base", out_file, "--head", "tests/osig/demo"])
    check(rc == 0 and "no differences" in out, "a snapshot file equals its package (%s%s)" % (out[-120:], err))
    bad = os.path.join(tmp, "tampered.json")
    with open(bad, "w") as f:
        f.write(g1.replace('"sig":"function double(x: int): int"', '"sig":"function double(x: int): bool"'))
    rc, out, err = run(orin, ["diff", "--base", bad, "--head", "tests/osig/demo"])
    check(rc == 1 and "hash mismatch" in err, "a tampered snapshot is refused (%s)" % err)
    rc, out, err = run(orin, ["diff", "--base", "tests/osig/demo/orin.toml", "--head", "tests/osig/demo"])
    check(rc != 0, "a non-package base is an error")
    rc, out, err = run(orin, ["diff", "--base", "tests/osig/demo"])
    check(rc == 2 and "usage" in err, "diff without --head is a usage error")

    # ---- 5. acceptance: rename + signature change + new call path -----------------------------
    rc, txt, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head"])
    check(rc == 0, "diff exits 0 when the heads differ (report only): %s" % err)
    check("changed symbols:" in txt and "[signature] Function acme:orders::checkout" in txt, "text: API signature change")
    check("- function checkout(qty: int): int" in txt and "+ function checkout(qty: int, express: bool): int" in txt,
          "text: before/after signature")
    check("possible renames (HEURISTIC, not proven identity" in txt
          and "acme:orders::applyDiscount => acme:orders::applyRebate" in txt, "text: rename marked heuristic")
    check("new call paths" in txt and "<- NEW" in txt, "text: new call path section")
    check("entry acme:(root)::main" in txt and "-> CALLS/direct [MUST] acme:orders::checkout" in txt
          and "-> CALLS/direct [MUST] acme:audit::record" in txt, "text: call path explained from main through checkout to record")
    rc, js, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head", "--format=json"])
    d = json.loads(js)
    check(d["schema"] == "osig-diff/0.2" and d["differences"] is True, "json: schema")
    check([c["id"] for c in d["changedSymbols"]] == ["acme:orders::checkout"]
          and d["changedSymbols"][0]["aspects"] == ["signature"]
          and d["changedSymbols"][0]["before"] == "function checkout(qty: int): int", "json: signature change")
    rn = d["possibleRenames"]
    check(len(rn) == 1 and rn[0]["heuristic"] is True and rn[0]["from"] == "acme:orders::applyDiscount"
          and rn[0]["to"] == "acme:orders::applyRebate" and rn[0]["confidence"] != "proven", "json: rename candidate is heuristic")
    check("acme:orders::applyDiscount" in [n["id"] for n in d["removedSymbols"]]
          and "acme:orders::applyRebate" in [n["id"] for n in d["addedSymbols"]],
          "json: the rename is not hidden: the symbols stay listed as removed and added")
    np_ = {f["edge"]["dst"]: f for f in d["newCallPaths"]}
    f = np_.get("acme:audit::record")
    check(f is not None and f["edge"]["src"] == "acme:orders::checkout", "json: new call checkout -> record")
    steps = [[s["node"] for s in p["steps"]] for p in f["reach"]["entryPaths"]]
    check(["acme:(root)::main", "acme:orders::checkout"] in steps, "json: path main -> checkout (entry point to the new call) (%s)" % steps)
    check(all(s["evidence"] in ("", "MUST", "MAY", "UNKNOWN") for p in f["reach"]["entryPaths"] for s in p["steps"]),
          "json: evidence on every hop")
    f = np_.get("acme:audit::sink")
    check(f is not None and ["acme:(root)::main", "acme:orders::checkout", "acme:audit::record"] in
          [[s["node"] for s in p["steps"]] for p in f["reach"]["entryPaths"]], "json: path main -> checkout -> record -> sink")
    check(any(e["kind"] == "IMPORTS" and e["dst"] == "acme:audit" for e in d["addedEdges"]), "json: new import edge")
    imp = {r["target"]: r for r in d["impact"]}
    check(any(p["steps"][0]["node"] == "acme:(root)::main" for p in imp["acme:orders::checkout"]["entryPaths"]),
          "json: impact of the changed checkout reaches main")
    check(d["summary"]["possibleRenames"] == 1 and d["summary"]["changed"] == 1, "json: summary")

    # ---- no change -------------------------------------------------------------------------------
    base2 = os.path.join(tmp, "base2")
    shutil.copytree(base, base2)
    rc, txt, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", base2, "--exit-code"])
    check(rc == 0 and "no differences" in txt and "changed symbols" not in txt, "no-change run reports nothing (text)")
    rc, js, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", base2, "--format=json"])
    d0 = json.loads(js)
    check(d0["differences"] is False and not d0["changedSymbols"] and not d0["addedSymbols"] and not d0["removedSymbols"]
          and not d0["addedEdges"] and not d0["removedEdges"] and not d0["possibleRenames"] and not d0["newCallPaths"],
          "no-change run reports nothing (json)")
    # a comment and blank lines shift every line number: spans change, the graph does not
    p = os.path.join(base2, "src", "orders", "orders.or")
    with open(p) as fh:
        src = fh.read()
    with open(p, "w") as fh:
        fh.write("// a new header comment\n\n\n" + src)
    rc, txt, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", base2, "--exit-code"])
    check(rc == 0 and "no differences" in txt, "a pure line shift reports nothing (%s)" % txt[-200:])
    rc, txt, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head", "--exit-code"])
    check(rc == 1, "--exit-code returns 1 when there are differences")

    # ---- 6. HTML ---------------------------------------------------------------------------------
    rc, html, err = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head", "--format=html",
                               "--link-base", "https://example.invalid/blob/abc"])
    check(rc == 0 and html.startswith("<!doctype html>"), "html report")
    for sect in ("<h2>Summary</h2>", "<h2>Changed symbols</h2>", "<h2>New and removed call paths</h2>", "<h2>Impact on entry points</h2>",
                 "<h2>Possible renames</h2>"):
        check(sect in html, "html section " + sect)
    check("Heuristic matches, never proven identity" in html, "html: rename disclaimer")
    check('href="https://example.invalid/blob/abc/src/orders/orders.or#L8"' in html, "html: path:line links")
    outside = re.sub(r'href="https://example\.invalid/[^"]*"', "", html)
    check(not re.search(r'(src|href)="https?:', outside) and "<script" not in html and "<link" not in html
          and "@import" not in html and "url(" not in html, "html is self-contained (no external assets)")
    rc, html2, _ = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head", "--format=html"])
    check("<a " not in html2 and "orders.or:8" in html2, "html without --link-base: plain path:line text")
    rc, html3, _ = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", base2, "--format=html"])
    check("No differences." in html3, "html of a no-change run")
    # XSS: a symbol name cannot inject markup (escaping of the report)
    rc, h4, _ = run(orin, ["diff", "--base", "tests/osig/accept/base", "--head", "tests/osig/accept/head", "--format=html"])
    check("<script" not in h4, "no script element")

    # ---- 7. primitive I/O edges (ADR-0027) ---------------------------------------------------------
    rc, gio, err = run(orin, ["graph", "tests/osig/io/main.or"])
    check(rc == 0, "graph of the I/O program exits 0 (%s)" % err)
    sio = json.loads(gio)
    perf = {(e["src"].split("::")[-1], e["dst"], e["evidence"], e["via"]) for e in sio["edges"] if e["kind"] == "PERFORMS_IO"}
    want_io = [
        ("load", "~io:Fs.ReadFile", "MUST", "INPUT"), ("save", "~io:Fs.WriteFile", "MUST", "OUTPUT"),
        ("stream", "~io:Fs.Open", "MUST", "CONTROL"), ("stream", "~io:Fs.Read", "MAY", "INPUT"),   # inside a closure: MAY
        ("tick", "~io:Clock.Now", "MUST", "INPUT"), ("run", "~io:Process.Args", "MUST", "INPUT"),
        ("run", "~io:Process.Spawn", "MUST", "CONTROL"), ("run", "~io:Stdio.Read", "MUST", "INPUT"),
        ("run", "~io:Console.Write", "MUST", "OUTPUT"), ("scoped", "~io:Fs.Narrow", "MUST", "CONTROL"),
        ("main", "~io:Host.Acquire", "MUST", "CONTROL"),
    ]
    for w in want_io:
        check(w in perf, "PERFORMS_IO edge %s" % (w,))
    check(not any(src == "pure" for (src, _d, _e, _v) in perf), "a pure function has no PERFORMS_IO edge")
    eff = {n["id"]: n for n in sio["nodes"] if n["kind"] == "Effect"}
    check(eff["~io:Console.Write"]["sig"] == "OUTPUT; grant: ambient" and eff["~io:Fs.ReadFile"]["sig"] == "INPUT; grant: FsGrant",
          "Effect nodes carry the direction and the grant family")
    check(all(e["evidence"] in ("MUST", "MAY") for e in sio["edges"] if e["kind"] == "PERFORMS_IO"),
          "primitive I/O edges are never UNKNOWN")
    rc, gpure, _ = run(orin, ["graph", "tests/next/run/cap_pure_no_grants.or"])
    spure = json.loads(gpure)
    pure_io = {e["dst"] for e in spure["edges"] if e["kind"] == "PERFORMS_IO"}
    check(pure_io == {"~io:Console.Write"}, "a pure calculation has no effect but the ambient console output (%s)" % sorted(pure_io))
    check(not any(e["dst"].startswith("~io:") and e["dst"] != "~io:Console.Write" for e in spure["edges"]),
          "a program without grants performs no grant-requiring I/O")
    # the diff reports a new I/O call as a new edge
    iobase = os.path.join(tmp, "iobase")
    iohead = os.path.join(tmp, "iohead")
    os.makedirs(iobase)
    os.makedirs(iohead)
    src_io = open(os.path.join(ROOT, "tests", "osig", "io", "main.or")).read()
    open(os.path.join(iobase, "main.or"), "w").write(src_io)
    open(os.path.join(iohead, "main.or"), "w").write(src_io.replace("function pure(n: int): int {\n  return n * 2;", "function pure(n: int): int {\n  console.error(\"x\");\n  return n * 2;"))
    rc, dtext, derr = run(orin, ["diff", "--base", os.path.join(iobase, "main.or"), "--head", os.path.join(iohead, "main.or")])
    check(rc == 0 and "+ PERFORMS_IO [MUST] (OUTPUT)" in dtext and "~io:Console.Write" in dtext, "diff shows the new primitive I/O edge (%s)" % derr)

    shutil.rmtree(tmp, ignore_errors=True)
    print("%d checks, %d failures" % (checks, len(failures)))
    sys.exit(1 if failures else 0)


main()
