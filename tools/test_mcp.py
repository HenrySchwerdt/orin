#!/usr/bin/env python3
"""End-to-end test of `orin mcp` (spec 10): speaks real MCP (2025-06-18) over stdio.

Builds compiler/main.or with the self-hosted compiler (orin2, from tools/bootstrap.sh) into
build/mcp/orin, launches `orin mcp --root <tmp>` and checks: initialize, tools/list (schemas),
check on a valid and an invalid project, delta behaviour across an edit (and the full-snapshot
fallback for an unknown base), inspect (symbol, module, position, built-in API), rename (dry run,
validation, apply), and the permission refusals (path escape, build/test without --allow-exec).
A second server with --allow-exec checks build and test.

Usage: python3 tools/test_mcp.py [--orin2 build/bootstrap/orin2] [--orin PATH]   (--orin skips the build)
"""
import argparse
import json
import os
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


def build(orin2):
    out = os.path.join(ROOT, "build", "mcp")
    os.makedirs(out, exist_ok=True)
    c = os.path.join(out, "orin.c")
    exe = os.path.join(out, "orin")
    r = subprocess.run([orin2, "compile", "compiler/main.or", "-o", c], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit("orin2 failed to compile compiler/main.or:\n" + r.stderr.decode())
    r = subprocess.run(["cc", "-O1", "-w", "-I", "runtime/core", c, "runtime/core/orin_runtime.c", "runtime/platform/orin_platform.c", "-o", exe],
                       cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit("cc failed:\n" + r.stderr.decode())
    return exe


class Client:
    def __init__(self, exe, *args):
        self.p = subprocess.Popen([exe, "mcp"] + list(args), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.next_id = 1

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode())
        self.p.stdin.flush()

    def request(self, method, params=None):
        i = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": i, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("server closed: " + self.p.stderr.read().decode())
        r = json.loads(line.decode())
        check(r.get("id") == i, "response id matches for " + method)
        return r

    def call(self, name, args):
        """tools/call -> (is_error, parsed-json-or-text, raw text)."""
        r = self.request("tools/call", {"name": name, "arguments": args})
        res = r["result"]
        text = res["content"][0]["text"]
        try:
            val = json.loads(text)
        except ValueError:
            val = text
        return res["isError"], val, text

    def close(self):
        self.p.stdin.close()
        code = self.p.wait(timeout=10)
        check(code == 0, "server exits 0 at end of input (got %s)" % code)


MAIN = """import { double, Point } from "./lib";

function main(): void {
  const p = Point { x: 1, y: 2 };
  console.log(double(p.x).toString());
}
"""

LIB = """export type Point = { x: int; y: int; };

export function double(n: int): int {
  return n * 2;
}

export class Counter implements Gauge {
  n: int = 0;
  bump(): void {
    this.n = this.n + 1;
  }
  peek(): int {
    return this.n;
  }
}

export interface Gauge {
  peek(): int;
}
"""

GEN = """import { Gauge, Counter } from "./lib";

export class Cell<T extends Gauge> {
  items: T[] = [];
  add(x: T): void {
    this.items.push(x);
  }
  total(): int {
    let t = 0;
    for (const i of this.items) {
      t += i.peek();
    }
    return t;
  }
}

function main(): void {
  let c = new Cell<Counter>();
  c.add(new Counter());
  console.log(c.total().toString());
}
"""

BAD = """function f(): void {
  const a: int = "x";
}

function g(): void {
  const b: string = 1;
}

function main(): void {}
"""


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin2", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--orin")
    a = ap.parse_args()
    exe = a.orin or build(a.orin2)

    tmp = tempfile.mkdtemp(prefix="orin-mcp-")
    proj = os.path.join(tmp, "proj")
    os.makedirs(proj)
    write(os.path.join(proj, "main.or"), MAIN)
    write(os.path.join(proj, "lib.or"), LIB)
    write(os.path.join(proj, "bad.or"), BAD)
    write(os.path.join(proj, "gen.or"), GEN)
    outside = os.path.join(tmp, "outside.or")
    write(outside, "function main(): void {}\n")

    c = Client(exe, "--root", proj)

    # ---- initialize / tools/list ------------------------------------------------------------
    pre = c.request("tools/list")
    check("error" in pre and pre["error"]["code"] == -32002, "tools/list before initialize is refused")
    r = c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "test", "version": "0"}})
    res = r["result"]
    check(res["protocolVersion"] == "2025-06-18", "protocol version")
    check("tools" in res["capabilities"], "tools capability")
    check(res["serverInfo"]["name"] == "orin", "server name")
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    r = c.request("ping")
    check(r["result"] == {}, "ping")
    r = c.request("tools/list")
    tools = {t["name"]: t for t in r["result"]["tools"]}
    check(set(tools) == {"check", "inspect", "edit", "test", "build", "graph", "diff"}, "tool names: %s" % sorted(tools))
    for t in tools.values():
        sch = t["inputSchema"]
        check(sch["type"] == "object" and "properties" in sch and t["description"], "schema for " + t["name"])
    check(tools["check"]["inputSchema"]["required"] == ["entry"], "check requires entry")
    check("sinceRevision" in tools["check"]["inputSchema"]["properties"], "check has sinceRevision")
    r = c.request("tools/call", {"name": "nope", "arguments": {}})
    check(r["error"]["code"] == -32602, "unknown tool is a protocol error")
    r = c.request("resources/list")
    check(r["error"]["code"] == -32601, "unknown method")

    # ---- check ------------------------------------------------------------------------------
    err, v, raw = c.call("check", {"entry": "main.or"})
    check(not err and v["errors"] == 0 and "diags" not in v, "valid project: no errors (%s)" % raw)
    rev_ok = v["revision"]
    err, v, raw = c.call("check", {"entry": "main.or"})
    check(v["revision"] == rev_ok, "unchanged project keeps its revision")
    err, v, raw = c.call("check", {"entry": "bad.or"})
    check(not err and v["errors"] == 2, "invalid project: 2 errors (%s)" % raw)
    check(all(d.startswith("E0400 bad.or:") for d in v["diags"]), "compact diag format (%s)" % raw)
    check(v["diags"][0].startswith("E0400 bad.or:2:18 "), "diag position 1-based (%s)" % v["diags"][0])
    rev_bad = v["revision"]
    check(rev_bad != rev_ok, "different project, different revision")
    err, v, raw = c.call("check", {"entry": "bad.or", "format": "detailed"})
    d0 = v["diags"][0]
    check(set(d0) >= {"id", "code", "file", "line", "col", "endLine", "endCol", "message"}, "detailed fields")
    check(len(d0["id"]) == 8, "stable id")
    err, v, raw = c.call("check", {"entry": "main.or", "format": "compact"})
    check(v["errors"] == 0, "main still valid")

    # ---- analysis cache: repeated calls agree; a file that main.or imports changing on disk is never served stale ----------
    err, v1, raw1 = c.call("inspect", {"symbol": "double", "entry": "main.or"})
    err, v2, raw2 = c.call("inspect", {"symbol": "double", "entry": "main.or"})
    check(not err and raw1 == raw2, "repeated inspect gives the same answer (%s)" % raw2)
    write(os.path.join(proj, "lib.or"), LIB.replace("return n * 2;", "return \"two\";"))
    err, v, raw = c.call("check", {"entry": "main.or"})
    check(not err and v["errors"] >= 1, "imported file changed on disk: the next check sees its error (%s)" % raw)
    write(os.path.join(proj, "lib.or"), LIB.replace("export function double(n: int): int", "export function double(n: int, m: int): int"))
    err, v, raw = c.call("inspect", {"symbol": "double", "entry": "main.or"})
    check(not err and "m: int" in raw, "inspect after an imported file changed on disk sees the new signature (%s)" % raw)
    write(os.path.join(proj, "lib.or"), LIB)
    err, v, raw = c.call("check", {"entry": "main.or"})
    check(not err and v["errors"] == 0, "restored file: clean again (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "double", "entry": "main.or"})
    check(not err and raw == raw1, "restored file: inspect as before (%s)" % raw)

    # ---- delta across an edit ---------------------------------------------------------------
    write(os.path.join(proj, "bad.or"), BAD.replace('const a: int = "x";', 'const a: int = 1;'))
    err, v, raw = c.call("check", {"entry": "bad.or", "sinceRevision": rev_bad})
    check(v.get("base") == rev_bad and v["revision"] != rev_bad, "delta carries base and a new revision (%s)" % raw)
    check(len(v["resolved"]) == 1 and v["resolved"][0].startswith("E0400 bad.or:2:"), "one diagnostic resolved (%s)" % raw)
    check(v["added"] == [] and v["remaining"] == 1, "nothing added, one remaining (%s)" % raw)
    check("diags" not in v, "delta has no full list")
    rev_1 = v["revision"]
    # a new error appears, with a line shift: the old one keeps its identity
    write(os.path.join(proj, "bad.or"),
          "// shifted\nfunction f(): void {\n  const a: int = 1;\n}\n\nfunction g(): void {\n  const b: string = 1;\n}\n\nfunction main(): void {\n  const z: bool = 5;\n}\n")
    err, v, raw = c.call("check", {"entry": "bad.or", "sinceRevision": rev_1})
    check(len(v["added"]) == 1 and v["remaining"] == 1 and v["resolved"] == [], "added 1, remaining 1 across line shift (%s)" % raw)
    err, v, raw = c.call("check", {"entry": "bad.or", "sinceRevision": 9999})
    check(v["errors"] == 2 and "diags" in v and "note" in v, "unknown base revision falls back to full snapshot (%s)" % raw)
    err, v, raw = c.call("check", {"entry": "bad.or", "sinceRevision": rev_ok})
    check("diags" in v, "a revision of another entry is not a base")

    # parser error recovery: every syntax error of the file (three), no type error (the checker does not run)
    write(os.path.join(proj, "syn.or"),
          "function f(): int {\n  return true;\n}\n\nfunction g(): void {\n  let a = ;\n  h(1;\n}\n\nfunction k(: int): void {}\n\nfunction main(): void {}\n")
    err, v, raw = c.call("check", {"entry": "syn.or"})
    check(not err and v["errors"] == 3, "syntax errors: all 3 reported (%s)" % raw)
    check([d.split(" ")[:2] for d in v.get("diags", [])]
          == [["E0200", "syn.or:6:11"], ["E0200", "syn.or:7:6"], ["E0200", "syn.or:10:12"]],
          "syntax errors: codes and positions in order (%s)" % raw)
    os.remove(os.path.join(proj, "syn.or"))

    err, v, raw = c.call("check", {"entry": "missing.or"})
    check(err and "cannot read" in raw, "missing entry is a tool error")
    err, v, raw = c.call("check", {})
    check(err and "entry" in raw, "missing argument is a tool error")

    # ---- inspect ----------------------------------------------------------------------------
    err, v, raw = c.call("inspect", {"symbol": "double", "entry": "main.or"})
    check(not err and v["kind"] == "function" and v["sig"] == "function double(n: int): int", "inspect symbol (%s)" % raw)
    check(v["at"] == "lib.or:3:17" and v.get("exported") is True, "defining location (%s)" % raw)
    check("source" not in v, "no source by default")
    err, v, raw = c.call("inspect", {"symbol": "double", "entry": "main.or", "includeSource": True})
    check("return n * 2;" in v.get("source", ""), "includeSource returns the declaration")
    err, v, raw = c.call("inspect", {"symbol": "Counter.bump", "entry": "main.or"})
    check(not err and v["kind"] == "method" and v["mutates"] is True, "mutating method inferred (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Counter.peek", "entry": "main.or"})
    check(not err and v["mutates"] is False, "non-mutating method (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Gauge", "entry": "main.or"})
    check(not err and v["kind"] == "interface" and v["implementedBy"][0].startswith("Counter at lib.or:"),
          "interface lists its implementations (%s)" % raw)
    check("implemented by Counter" in v["sig"], "interface signature shows implementations (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Gauge.peek", "entry": "main.or"})
    check(not err and v["kind"] == "method" and v["in"] == "Gauge" and v["mutates"] is False,
          "interface method (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Counter", "entry": "main.or"})
    check(not err and v["kind"] == "class" and v["implements"] == ["Gauge"], "class lists the interfaces it implements (%s)" % raw)
    # generic classes (ADR-0026): the class is one symbol; its methods carry the inferred mutability
    err, v, raw = c.call("inspect", {"symbol": "Cell", "entry": "gen.or"})
    check(not err and v["kind"] == "class" and v["sig"].startswith("class Cell<T extends Gauge>"), "generic class signature (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Cell.add", "entry": "gen.or"})
    check(not err and v["kind"] == "method" and v["mutates"] is True and v["sig"] == "mut method add(x: T): void",
          "generic class: mutating method (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Cell.total", "entry": "gen.or"})
    check(not err and v["mutates"] is False, "generic class: non-mutating method (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Nope", "entry": "main.or"})
    check(err and "not found" in raw, "unknown symbol")
    err, v, raw = c.call("inspect", {"module": "lib.or", "entry": "main.or"})
    check(not err and v["module"] == "lib" and "function double(n: int): int" in v["exports"], "module exports (%s)" % raw)
    check(v["importedBy"] == ["main"] and v["imports"] == [], "module dependency edges (%s)" % raw)
    err, v, raw = c.call("inspect", {"module": "main.or"})
    check(v["imports"] == ["lib"], "module imports (%s)" % raw)
    err, v, raw = c.call("inspect", {"file": "main.or", "position": {"line": 5, "column": 15}})
    check(not err and v["name"] == "double", "inspect by position (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "Array.find"})
    check(not err and "Option<T>" in v["sig"] and "None" in v["fails"], "builtin Array.find (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "string.split"})
    check(not err and "traps" in v["fails"], "builtin string.split (%s)" % raw)
    err, v, raw = c.call("inspect", {})
    check(err, "inspect without target is an error")

    # ---- packages (orin.toml, spec 04): module inspect shows the rule; violations are diagnostics
    import shutil
    shutil.copytree(os.path.join(ROOT, "tests", "next", "packages", "shop"), os.path.join(proj, "shop"))
    err, v, raw = c.call("inspect", {"module": "shop/src/payments/module.or", "entry": "shop/src/main.or"})
    check(not err and v.get("allowedDependencies") == ["users", "database"] and v.get("moduleId") == "payments"
          and v.get("package") == "shop" and v.get("moduleImports") == ["database", "users"],
          "inspect module shows manifest rule (%s)" % raw)
    err, v, raw = c.call("check", {"entry": "shop/src/main.or"})
    check(not err and v.get("errors") == 0, "package checks clean (%s)" % raw)

    # ---- inspect: the inferred effect summary (ADR-0037 D2; the same analysis as `orin effects`) ------------
    shutil.copytree(os.path.join(ROOT, "tests", "osig", "effects", "app"), os.path.join(proj, "effapp"))
    err, v, raw = c.call("inspect", {"symbol": "loadConfig", "entry": "effapp/src/main.or"})
    ef = v.get("effects", {}) if not err else {}
    check(not err and ef.get("pure") is False and [(e["operation"], e["direction"], e["evidence"]) for e in ef.get("effects", [])]
          == [("Fs.ReadFile", "INPUT", "MUST")], "inspect symbol: a direct effect (%s)" % raw)
    check(not err and ef["effects"][0]["path"][-1]["function"] == "store::loadConfig"
          and ef["effects"][0]["path"][-1]["span"]["file"] == "src/store/store.or", "inspect symbol: the path ends at the primitive call")
    err, v, raw = c.call("inspect", {"symbol": "reload", "entry": "effapp/src/main.or"})
    ef = v.get("effects", {}) if not err else {}
    check(not err and [(e["operation"], e["evidence"], [h["function"] for h in e["path"]]) for e in ef.get("effects", [])]
          == [("Fs.ReadFile", "MAY", ["store::reload", "store::loadConfig"])], "inspect symbol: a transitive effect with its path (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "fact", "entry": "effapp/src/main.or"})
    check(not err and v.get("effects", {}).get("pure") is True and v["effects"]["effects"] == [], "inspect symbol: a pure function (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "runDynamic", "entry": "effapp/src/main.or"})
    check(not err and [e["operation"] for e in v.get("effects", {}).get("effects", [])] == ["Unknown.FunctionValue"]
          and v["effects"]["effects"][0]["evidence"] == "UNKNOWN", "inspect symbol: UNKNOWN is not pure (%s)" % raw)
    err, v, raw = c.call("inspect", {"symbol": "apply", "entry": "effapp/src/main.or"})
    check(not err and v.get("effects", {}).get("callbacks") == ["f"] and v["effects"]["pure"] is False,
          "inspect symbol: a function that calls its parameter names the callback (%s)" % raw)
    err, v, raw = c.call("inspect", {"module": "effapp/src/store/module.or", "entry": "effapp/src/main.or"})
    check(not err and sorted((e["operation"], e["evidence"]) for e in v.get("effects", [])) == [("Fs.ReadFile", "MUST"), ("Fs.WriteFile", "MUST")],
          "inspect module: the module's effects (%s)" % raw)
    write(os.path.join(proj, "shop", "src", "users", "user.or"),
          open(os.path.join(proj, "shop", "src", "users", "user.or")).read().replace(
              'import { hidden }', 'import { charge } from "../payments";\nimport { hidden }'))
    err, v, raw = c.call("check", {"entry": "shop/src/main.or"})
    check("E0501" in raw, "disallowed module dependency is reported by check (%s)" % raw)

    # ---- edit (rename) ----------------------------------------------------------------------
    before = open(os.path.join(proj, "lib.or")).read()
    err, v, raw = c.call("edit", {"kind": "rename", "file": "lib.or", "position": {"line": 3, "column": 20},
                                  "newName": "twice", "entry": "main.or"})
    check(not err and v["valid"] and not v["applied"], "dry run is valid, nothing applied (%s)" % raw)
    check(sorted(v["edits"]) == ["lib.or:3:17", "main.or:1:10", "main.or:5:15"], "edit list across files (%s)" % raw)
    check(open(os.path.join(proj, "lib.or")).read() == before, "dry run leaves the file untouched")
    err, v, raw = c.call("edit", {"kind": "rename", "file": "lib.or", "position": "3:20", "newName": "class",
                                  "entry": "main.or"})
    check(err and "reserved" in raw, "reserved word rejected (%s)" % raw)
    err, v, raw = c.call("edit", {"kind": "rename", "file": "lib.or", "position": {"line": 1, "column": 1},
                                  "newName": "x", "entry": "main.or"})
    check(err, "no symbol at position")
    err, v, raw = c.call("edit", {"kind": "extract", "file": "lib.or", "position": "3:20", "newName": "x"})
    check(err and "unsupported" in raw, "unsupported kind")
    err, v, raw = c.call("edit", {"kind": "rename", "file": "lib.or", "position": {"line": 3, "column": 20},
                                  "newName": "twice", "entry": "main.or", "apply": True})
    check(not err and v["applied"], "apply writes (%s)" % raw)
    check("twice" in open(os.path.join(proj, "lib.or")).read() and
          "twice(p.x)" in open(os.path.join(proj, "main.or")).read(), "files rewritten")
    err, v, raw = c.call("check", {"entry": "main.or"})
    check(v["errors"] == 0, "project still valid after rename (%s)" % raw)

    # ---- graph / diff (OSIG, docs/osig.md) -----------------------------------------------------
    import shutil
    for side in ("base", "head"):
        shutil.copytree(os.path.join(ROOT, "tests", "osig", "accept", side), os.path.join(proj, "osig", side))
    err, v, raw = c.call("graph", {"entry": "osig/head"})
    check(not err and v["schema"] == "osig/0.3" and v["package"] == "acme" and v["hash"].startswith("h62:")
          and v["nodes"] > 5 and v["edges"] > 5 and "snapshot" not in v, "graph summary (%s)" % raw)
    err, v2, raw = c.call("graph", {"entry": "osig/head", "full": True, "out": "osig/head.json"})
    check(not err and v2["hash"] == v["hash"] and json.loads(v2["snapshot"])["hash"] == v["hash"], "graph full is deterministic")
    check(os.path.exists(os.path.join(proj, "osig", "head.json")), "graph out written inside the root")
    err, d, raw = c.call("diff", {"base": "osig/base", "head": "osig/head"})
    check(not err and d["schema"] == "osig-diff/0.2" and d["differences"] is True, "diff json (%s)" % raw[:200])
    check([c_["id"] for c_ in d["changedSymbols"]] == ["acme:orders::checkout"] and d["changedSymbols"][0]["aspects"] == ["signature"],
          "diff: API signature change")
    check(len(d["possibleRenames"]) == 1 and d["possibleRenames"][0]["heuristic"] is True
          and d["possibleRenames"][0]["from"].endswith("applyDiscount"), "diff: rename is heuristic")
    check(any(f["edge"]["dst"] == "acme:audit::record" for f in d["newCallPaths"]), "diff: new call path")
    err, t, raw = c.call("diff", {"base": "osig/base", "head": "osig/head.json", "format": "text"})
    check(not err and "possible renames (HEURISTIC" in raw and "<- NEW" in raw, "diff text, head from a snapshot file")
    err, t, raw = c.call("diff", {"base": "osig/head", "head": "osig/head.json", "format": "text"})
    check(not err and "no differences" in raw, "diff of identical graphs reports nothing")
    err, t, raw = c.call("diff", {"base": "osig/base", "head": "osig/head", "format": "html", "out": "osig/r.html"})
    check(not err and t["written"] == "osig/r.html" and "<!doctype html>" in open(os.path.join(proj, "osig", "r.html")).read(),
          "diff html written")
    err, t, raw = c.call("graph", {"entry": "../outside.or"})
    check(err and "outside the authorized root" in raw, "graph outside root refused")
    err, t, raw = c.call("diff", {"base": "osig/base", "head": "../outside.or"})
    check(err and "outside the authorized root" in raw, "diff outside root refused")

    # ---- security ---------------------------------------------------------------------------
    err, v, raw = c.call("check", {"entry": "../outside.or"})
    check(err and "outside the authorized root" in raw, "relative escape refused (%s)" % raw)
    err, v, raw = c.call("check", {"entry": outside})
    check(err and "outside the authorized root" in raw, "absolute path outside root refused")
    err, v, raw = c.call("edit", {"kind": "rename", "file": "../outside.or", "position": "1:1", "newName": "x", "apply": True})
    check(err and "outside the authorized root" in raw, "edit outside root refused")
    err, v, raw = c.call("build", {"entry": "main.or", "out": "out.c"})
    check(err and "--allow-exec" in raw, "build refused without --allow-exec (%s)" % raw)
    check(not os.path.exists(os.path.join(proj, "out.c")), "refused build wrote nothing")
    err, v, raw = c.call("test", {"entry": "main.or"})
    check(err and "--allow-exec" in raw, "test refused without --allow-exec")
    err, v, raw = c.call("test", {"suite": "default"})
    check(err and "--allow-exec" in raw, "suite refused without --allow-exec")
    # a project importing a file outside the root
    write(os.path.join(proj, "esc.or"), 'import { main } from "../outside";\nfunction main(): void {}\n')
    err, v, raw = c.call("check", {"entry": "esc.or"})
    check(err and "outside the authorized root" in raw, "import escaping the root refused (%s)" % raw)
    # bad JSON, then the server must still answer
    c.p.stdin.write(b"{not json\n")
    c.p.stdin.flush()
    r = json.loads(c.p.stdout.readline().decode())
    check(r["error"]["code"] == -32700, "parse error reported")
    r = c.request("ping")
    check(r["result"] == {}, "server alive after parse error")
    c.close()

    # ---- exec-enabled server ----------------------------------------------------------------
    c = Client(exe, "--root", proj, "--allow-exec", "--repo", ROOT)
    c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    err, v, raw = c.call("build", {"entry": "bad.or", "out": "build/bad.c"})
    check(not err and v["ok"] is False and v["errors"] == 2, "build reports diagnostics (%s)" % raw)
    err, v, raw = c.call("build", {"entry": "main.or", "out": "build/main.c", "binary": "build/main"})
    check(not err and v["ok"] and v["binary"] == "build/main", "build to C and binary (%s)" % raw)
    run = subprocess.run([os.path.join(proj, "build", "main")], stdout=subprocess.PIPE)
    check(run.stdout == b"2\n", "built binary runs: %r" % run.stdout)
    err, v, raw = c.call("build", {"entry": "main.or", "out": "../escape.c"})
    check(err and "outside the authorized root" in raw, "build out outside root refused")
    write(os.path.join(proj, "t.or"), "// exit: 0\nfunction main(): void {\n  console.log(\"hi\");\n}\n")
    write(os.path.join(proj, "t.out"), "hi\n")
    err, v, raw = c.call("test", {"entry": "t.or"})
    check(not err and v["passed"] is True, "test entry passes (%s)" % raw)
    write(os.path.join(proj, "t.out"), "ho\n")
    err, v, raw = c.call("test", {"entry": "t.or"})
    check(not err and v["passed"] is False and "line 1" in v["why"], "test entry mismatch reported (%s)" % raw)
    # @Test functions (ADR-0024): per-test results, shared with `orin test`
    write(os.path.join(proj, "u.or"), 'import { assertEq } from "std:test";\n\n@Test\nfunction ok(): void {\n  assertEq(1 + 1, 2, "sum");\n}\n\n'
          '@Test\nfunction bad(): void {\n  assertEq(1 + 1, 3, "sum");\n}\n\nfunction main(): void {\n}\n')
    err, v, raw = c.call("test", {"entry": "u.or", "unit": True})
    check(not err and v["ok"] is False and v["total"] == 2 and v["passed"] == 1 and v["failed"] == 1
          and [t["status"] for t in v["tests"]] == ["pass", "fail"] and "expected 3, got 2" in v["tests"][1]["stderr"], "test unit=true runs @Test functions (%s)" % raw)
    err, v, raw = c.call("test", {"entry": "u.or", "unit": True, "filter": "ok"})
    check(not err and v["ok"] is True and v["total"] == 1 and v["filtered"] == 1, "test unit=true with filter (%s)" % raw)
    write(os.path.join(proj, "ue.or"), 'import { assertEq } from "std:test";\n\n@Test\nfunction broken(): void {\n  assertEq("a", 1, "x");\n}\n\nfunction main(): void {\n}\n')
    err, v, raw = c.call("test", {"entry": "ue.or", "unit": True})
    check(not err and v["ok"] is False and v["errors"] == 1 and "E0400" in v["diags"][0], "test unit=true reports compile errors (%s)" % raw)
    err, v, raw = c.call("test", {"entry": "esc.or", "unit": True})
    check(err and "outside the authorized root" in raw, "test unit=true refuses files outside the root (%s)" % raw)
    err, v, raw = c.call("build", {"entry": "u.or", "out": "build/u.c"})
    check(not err and v["ok"], "build erases @Test functions and does not run them (%s)" % raw)
    if os.path.exists(os.path.join(ROOT, "build", "bootstrap", "orin2")):
        err, v, raw = c.call("test", {"suite": "default", "filter": "hello"})
        check(not err and v["failed"] == 0 and v["passed"] >= 1, "suite with filter (%s)" % raw)
    c.close()

    print("%d checks, %d failures" % (checks, len(failures)))
    sys.exit(1 if failures else 0)


main()
