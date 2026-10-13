#!/usr/bin/env python3
"""End-to-end test of `orin lsp` (spec 18 P2): speaks real LSP JSON-RPC over stdio.

Builds the current tree's compiler/main.or with the self-hosted compiler (orin2, from
tools/bootstrap.sh) into build/lsp/orin, launches `orin lsp` as a subprocess and checks:
initialize capabilities, diagnostics (valid file, syntax error E0200, type error E0400),
a two-module project in a temp dir (definition, hover, references, rename across files),
formatting, completion (locals, declarations, keywords) and shutdown/exit (exit code 0).

Usage: python3 tools/test_lsp.py [--orin2 build/bootstrap/orin2] [--orin PATH]   (--orin skips the build)
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import queue

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
    out = os.path.join(ROOT, "build", "lsp")
    os.makedirs(out, exist_ok=True)
    c = os.path.join(out, "orin.c")
    exe = os.path.join(out, "orin")
    r = subprocess.run([orin2, "compile", "compiler/main.or", "-o", c], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit("orin2 failed to compile compiler/main.or:\n" + r.stderr.decode())
    r = subprocess.run(["cc", "-O1", "-w", "-I", "runtime", c, "runtime/orin_runtime.c", "-o", exe],
                       cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit("cc failed:\n" + r.stderr.decode())
    return exe


class Client:
    def __init__(self, exe):
        self.p = subprocess.Popen([exe, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
        self.next_id = 1
        self.q = queue.Queue()
        self.notes = []
        t = threading.Thread(target=self._reader, daemon=True)
        t.start()

    def _read_msg(self):
        length = None
        while True:
            line = self.p.stdout.readline()
            if not line:
                return None
            line = line.decode().rstrip("\r\n")
            if line == "":
                break
            if line.lower().startswith("content-length:"):
                length = int(line.split(":")[1])
        body = self.p.stdout.read(length)
        return json.loads(body.decode("utf-8"))

    def _reader(self):
        while True:
            m = self._read_msg()
            if m is None:
                self.q.put(None)
                return
            self.q.put(m)

    def send(self, msg):
        body = json.dumps(msg).encode("utf-8")
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.p.stdin.flush()

    def request(self, method, params):
        i = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        while True:
            m = self.q.get(timeout=60)
            if m is None:
                raise RuntimeError("server closed stdout while waiting for " + method)
            if m.get("id") == i and "method" not in m:
                return m
            self.notes.append(m)

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def diagnostics_for(self, uri, timeout=60):
        """Latest publishDiagnostics for uri among queued notifications (waits for one)."""
        got = None
        for m in [n for n in self.notes if n.get("method") == "textDocument/publishDiagnostics"
                  and n["params"]["uri"] == uri]:
            got = m
        self.notes = [n for n in self.notes if not (n.get("method") == "textDocument/publishDiagnostics"
                                                    and n["params"]["uri"] == uri)]
        return got["params"]["diagnostics"] if got else None

    def drain(self, seconds=0.5):
        try:
            while True:
                m = self.q.get(timeout=seconds)
                if m is None:
                    return
                self.notes.append(m)
        except queue.Empty:
            pass


def uri_of(path):
    return "file://" + path


def pos_of(text, needle, occurrence=0, delta=0):
    idx = -1
    for _ in range(occurrence + 1):
        idx = text.index(needle, idx + 1)
    idx += delta
    line = text.count("\n", 0, idx)
    col = idx - (text.rfind("\n", 0, idx) + 1)
    return {"line": line, "character": col}


def open_doc(c, path, text, version=1):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": uri_of(path), "languageId": "orin",
                                                       "version": version, "text": text}})


def change_doc(c, path, text, version):
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri_of(path), "version": version},
                                        "contentChanges": [{"text": text}]})


def sync(c, uri):
    """A round trip guaranteeing earlier notifications were processed; returns diagnostics for uri."""
    c.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})
    c.drain(0.3)
    return c.diagnostics_for(uri)


def td(path, pos):
    return {"textDocument": {"uri": uri_of(path)}, "position": pos}


def run(exe):
    c = Client(exe)
    tmp = tempfile.mkdtemp(prefix="orin_lsp_")

    # ---- initialize ------------------------------------------------------------------------
    r = c.request("initialize", {"processId": None, "rootUri": uri_of(tmp), "capabilities": {}})
    caps = r["result"]["capabilities"]
    for k in ["textDocumentSync", "documentSymbolProvider", "completionProvider", "documentFormattingProvider",
              "definitionProvider", "hoverProvider", "referencesProvider", "renameProvider"]:
        check(k in caps, "initialize: capability %s advertised" % k)
    check(r["result"]["serverInfo"]["name"] == "orin", "initialize: serverInfo.name")
    c.notify("initialized", {})

    # ---- diagnostics: valid, syntax error, type error ---------------------------------------
    solo = os.path.join(tmp, "solo.or")
    good = "function add(a: int, b: int): int {\n  return a + b;\n}\n\nfunction main(): void {\n  console.log(add(1, 2).toString());\n}\n"
    open_doc(c, solo, good)
    d = sync(c, uri_of(solo))
    check(d == [], "valid file: empty diagnostics (got %r)" % (d,))

    bad_syntax = good.replace("return a + b;", "return a + ;")
    change_doc(c, solo, bad_syntax, 2)
    d = sync(c, uri_of(solo))
    check(d is not None and len(d) >= 1 and d[0]["code"] == "E0200", "syntax error: E0200 (got %r)" % (d,))
    if d:
        want = pos_of(bad_syntax, ";", 0)
        check(d[0]["range"]["start"]["line"] == want["line"] == 1, "syntax error: reported on line 2 (%r)" % (d[0]["range"],))
        check(d[0]["range"]["start"]["character"] == want["character"], "syntax error: column of the `;` (%r vs %r)" % (d[0]["range"], want))

    bad_type = good.replace("return a + b;", "return true;")
    change_doc(c, solo, bad_type, 3)
    d = sync(c, uri_of(solo))
    check(d is not None and len(d) >= 1 and d[0]["code"] == "E0400", "type error: E0400 (got %r)" % (d,))
    if d:
        check(d[0]["range"]["start"]["line"] == 1, "type error: on line 2 (%r)" % (d[0]["range"],))

    change_doc(c, solo, good, 4)
    d = sync(c, uri_of(solo))
    check(d == [], "fixed file: diagnostics cleared (got %r)" % (d,))

    # ---- formatting ---------------------------------------------------------------------------
    ugly = "function   add(a:int,b:int):int{return a+b;}\nfunction main():void{console.log(add(1,2).toString());}\n"
    change_doc(c, solo, ugly, 5)
    r = c.request("textDocument/formatting", {"textDocument": {"uri": uri_of(solo)},
                                              "options": {"tabSize": 2, "insertSpaces": True}})
    edits = r.get("result")
    check(isinstance(edits, list) and len(edits) == 1, "formatting: one edit (got %r)" % (r,))
    if edits:
        check(edits[0]["newText"].startswith("function add(a: int, b: int): int {"), "formatting: canonical text (%r)" % edits[0]["newText"][:60])
    change_doc(c, solo, good, 6)

    # ---- completion --------------------------------------------------------------------------
    comp_text = "function helper(): int {\n  return 1;\n}\n\nfunction main(): void {\n  const total = helper();\n  const other = 2;\n  console.log(total.toString());\n}\n"
    comp = os.path.join(tmp, "comp.or")
    open_doc(c, comp, comp_text)
    r = c.request("textDocument/completion", td(comp, pos_of(comp_text, "console", 0)))
    labels = [i["label"] for i in r["result"]["items"]]
    check("total" in labels and "other" in labels, "completion: locals (%r)" % labels[:12])
    check("helper" in labels and "main" in labels, "completion: declarations")
    check("function" in labels and "return" in labels and "while" in labels, "completion: keywords")

    # ---- cross-module project --------------------------------------------------------------
    lib = os.path.join(tmp, "lib.or")
    main = os.path.join(tmp, "main.or")
    lib_text = ("export type Point = { x: int; y: int; };\n\n"
                "export function dist(p: Point): int {\n  return p.x + p.y;\n}\n")
    main_text = ('import { dist, Point } from "./lib";\n\n'
                 "function main(): void {\n"
                 "  const p = Point { x: 1, y: 2 };\n"
                 "  const d = dist(p);\n"
                 "  console.log(d.toString());\n"
                 "}\n")
    with open(lib, "w") as f:
        f.write(lib_text)
    open_doc(c, main, main_text)
    d = sync(c, uri_of(main))
    check(d == [], "project: main.or has no diagnostics (got %r)" % (d,))

    call = pos_of(main_text, "dist(p)", 0, 1)
    r = c.request("textDocument/definition", td(main, call))
    loc = r.get("result")
    check(isinstance(loc, dict) and loc["uri"] == uri_of(lib), "definition: jumps into lib.or (got %r)" % (loc,))
    if isinstance(loc, dict):
        want = pos_of(lib_text, "dist", 0)
        check(loc["range"]["start"] == want, "definition: at the declaration name (%r vs %r)" % (loc["range"]["start"], want))

    r = c.request("textDocument/hover", td(main, call))
    hv = (r.get("result") or {}).get("contents", {}).get("value", "")
    check("function dist(p: Point): int" in hv, "hover: function signature (got %r)" % (hv,))

    r = c.request("textDocument/hover", td(main, pos_of(main_text, "d.toString", 0)))
    hv = (r.get("result") or {}).get("contents", {}).get("value", "")
    check("int" in hv, "hover: local type (got %r)" % (hv,))

    r = c.request("textDocument/references", {**td(main, call), "context": {"includeDeclaration": True}})
    locs = r.get("result") or []
    uris = sorted(set(l["uri"] for l in locs))
    check(uri_of(lib) in uris and uri_of(main) in uris, "references: across both files (got %r)" % (locs,))
    # declaration in lib + the import name + the call in main
    check(len(locs) >= 3, "references: declaration, import name and call (got %d)" % len(locs))

    # field references: p.x in lib and the literal field name `x` in main
    r = c.request("textDocument/references", {**td(main, pos_of(main_text, "x: 1", 0)),
                                              "context": {"includeDeclaration": True}})
    locs = r.get("result") or []
    check(len(locs) >= 3 and uri_of(lib) in set(l["uri"] for l in locs),
          "references: record field (declaration, p.x read, literal) (got %d)" % len(locs))

    r = c.request("textDocument/prepareRename", td(main, call))
    check(r.get("result") is not None and r["result"].get("placeholder") == "dist", "prepareRename: placeholder dist (got %r)" % (r.get("result"),))

    r = c.request("textDocument/rename", {**td(main, call), "newName": "distance"})
    changes = (r.get("result") or {}).get("changes", {})
    check(uri_of(lib) in changes and uri_of(main) in changes, "rename: edits in both files (got %r)" % (list(changes),))
    check(all(e["newText"] == "distance" for es in changes.values() for e in es), "rename: new text")
    check(len(changes.get(uri_of(main), [])) == 2 and len(changes.get(uri_of(lib), [])) == 1,
          "rename: 2 edits in main (import + call), 1 in lib (%r)" % ({k: len(v) for k, v in changes.items()},))

    r = c.request("textDocument/rename", {**td(main, call), "newName": "while"})
    check("error" in r, "rename: reserved word rejected")

    # rename a record field: all of lib's reads and main's literal change
    r = c.request("textDocument/rename", {**td(main, pos_of(main_text, "x: 1", 0)), "newName": "px"})
    changes = (r.get("result") or {}).get("changes", {})
    check(len(changes.get(uri_of(lib), [])) == 2 and len(changes.get(uri_of(main), [])) == 1,
          "rename field: decl + p.x in lib, literal in main (%r)" % ({k: len(v) for k, v in changes.items()},))

    # references/rename requested from lib.or see main.or's uses (main.or is open and imports lib)
    r = c.request("textDocument/references", {**td(lib, pos_of(lib_text, "dist", 0)), "context": {"includeDeclaration": True}})
    locs = r.get("result") or []
    check(uri_of(main) in set(l["uri"] for l in locs) and len(locs) >= 3,
          "references from the library file include its importer (got %d)" % len(locs))

    # a type error in lib shows up as a diagnostic on lib.or when main is the entry
    lib_bad = lib_text.replace("p.x + p.y", "p.x + true")
    open_doc(c, lib, lib_bad)
    d = sync(c, uri_of(lib))
    check(d is not None and any(x["code"].startswith("E04") for x in d), "project: type error in lib reported on lib.or (got %r)" % (d,))

    # rename is refused while the program has errors (the index is partial then)
    r = c.request("textDocument/rename", {**td(main, call), "newName": "distance"})
    check("error" in r, "rename: refused while the workspace has errors")
    open_doc(c, lib, lib_text, 3)

    # ---- richer language constructs in one file ----------------------------------------------
    rich = os.path.join(tmp, "rich.or")
    rich_text = (
        "type Shape = Circle(int) | Rect(int, int) | Empty;\n"
        "type Pos = { x: int; y: int; };\n"
        "type Sprite = { pos: Pos; hp: int; };\n\n"
        "function area(s: Shape): int {\n"
        "  return match (s) {\n"
        "    Circle(r) => r * r,\n"
        "    Rect(w, h) => w * h,\n"
        "    Empty => 0\n"
        "  };\n"
        "}\n\n"
        "function main(): void {\n"
        "  let sp = Sprite { pos: Pos { x: 1, y: 2 }, hp: 3 };\n"
        "  sp.pos.x = 5;\n"
        "  sp.hp += 1;\n"
        "  const shapes = [Circle(2), Rect(2, 3), Empty];\n"
        "  let total = 0;\n"
        "  for (const s of shapes) {\n"
        "    total += area(s);\n"
        "  }\n"
        '  console.log((total + sp.pos.x).toString());\n'
        "}\n")
    open_doc(c, rich, rich_text)
    d = sync(c, uri_of(rich))
    check(d == [], "rich: no diagnostics (got %r)" % (d,))

    def refs(needle, occ=0, delta=0, decl=True):
        r = c.request("textDocument/references", {**td(rich, pos_of(rich_text, needle, occ, delta)),
                                                  "context": {"includeDeclaration": decl}})
        return r.get("result") or []

    check(len(refs("Circle", 0)) == 3, "rich: variant Circle (decl, construction, pattern) -> %d" % len(refs("Circle", 0)))
    check(len(refs("Empty", 0)) == 3, "rich: variant Empty (decl, pattern, construction) -> %d" % len(refs("Empty", 0)))
    check(len(refs("x: int", 0)) == 4, "rich: field Pos.x (decl, literal, assignment, read) -> %d" % len(refs("x: int", 0)))
    check(len(refs("hp", 0)) == 3, "rich: field Sprite.hp (decl, literal, compound assignment) -> %d" % len(refs("hp", 0)))
    check(len(refs("total", 0)) == 3, "rich: local total (decl, +=, read) -> %d" % len(refs("total", 0)))
    check(len(refs("s of", 0)) == 2, "rich: for-of variable (decl, use) -> %d" % len(refs("s of", 0)))
    check(len(refs("Shape", 0)) == 2, "rich: type Shape (decl, parameter type) -> %d" % len(refs("Shape", 0)))
    check(len(refs("area", 0)) == 2, "rich: function area (decl, call) -> %d" % len(refs("area", 0)))

    def hover(needle, occ=0, delta=0):
        r = c.request("textDocument/hover", td(rich, pos_of(rich_text, needle, occ, delta)))
        return (r.get("result") or {}).get("contents", {}).get("value", "")

    check("const r: int" in hover("r) =>", 0), "rich: hover pattern binding (%r)" % hover("r) =>", 0))
    check("let sp: Sprite" in hover("sp = Sprite", 0), "rich: hover let (%r)" % hover("sp = Sprite", 0))
    check("Circle(int)" in hover("Circle(2)", 0), "rich: hover variant (%r)" % hover("Circle(2)", 0))
    check("y: int" in hover("y: 2", 0), "rich: hover field (%r)" % hover("y: 2", 0))
    check("Pos" in hover("pos.x)", 0, 1) or "int" in hover("pos.x)", 0, 1), "rich: hover member (%r)" % hover("pos.x)", 0, 1))

    # ---- classes across files (ADR-0009): definition, hover, references, rename ----------------
    clib = os.path.join(tmp, "clib.or")
    cmain = os.path.join(tmp, "cmain.or")
    clib_text = ("export class Counter {\n  constructor(public value: int) {}\n"
                 "  increment(): void {\n    this.value += 1;\n  }\n"
                 "  get(): int {\n    return this.value;\n  }\n}\n")
    cmain_text = ('import { Counter } from "./clib";\n\n'
                  "function main(): void {\n"
                  "  let c = new Counter(0);\n"
                  "  c.increment();\n"
                  "  console.log(c.get().toString());\n"
                  "  console.log(c.value.toString());\n"
                  "}\n")
    with open(clib, "w") as f:
        f.write(clib_text)
    open_doc(c, cmain, cmain_text)
    d = sync(c, uri_of(cmain))
    check(d == [], "classes: cmain.or has no diagnostics (got %r)" % (d,))
    inc = pos_of(cmain_text, "increment", 0, 1)
    r = c.request("textDocument/definition", td(cmain, inc))
    loc = r.get("result")
    check(isinstance(loc, dict) and loc["uri"] == uri_of(clib) and loc["range"]["start"] == pos_of(clib_text, "increment", 0),
          "classes: definition of a method call jumps to the method in clib.or (got %r)" % (loc,))
    r = c.request("textDocument/definition", td(cmain, pos_of(cmain_text, "Counter(0)", 0, 1)))
    loc = r.get("result")
    check(isinstance(loc, dict) and loc["uri"] == uri_of(clib) and loc["range"]["start"] == pos_of(clib_text, "Counter", 0),
          "classes: definition of `new Counter` jumps to the class (got %r)" % (loc,))
    r = c.request("textDocument/hover", td(cmain, inc))
    hv = (r.get("result") or {}).get("contents", {}).get("value", "")
    check("mut method increment()" in hv, "classes: hover shows the inferred mutability (got %r)" % (hv,))
    r = c.request("textDocument/hover", td(cmain, pos_of(cmain_text, "get()", 0, 1)))
    hv = (r.get("result") or {}).get("contents", {}).get("value", "")
    check("method get(): int" in hv and "mut" not in hv, "classes: non-mutating method hover (got %r)" % (hv,))
    r = c.request("textDocument/references", {**td(cmain, inc), "context": {"includeDeclaration": True}})
    locs = r.get("result") or []
    check(len(locs) == 2 and uri_of(clib) in set(l["uri"] for l in locs), "classes: method references (decl + call) (got %d)" % len(locs))
    r = c.request("textDocument/references", {**td(cmain, pos_of(cmain_text, "value", 0)), "context": {"includeDeclaration": True}})
    locs = r.get("result") or []
    check(len(locs) >= 4, "classes: field references (decl, this.value x2, c.value) (got %d)" % len(locs))
    r = c.request("textDocument/rename", {**td(cmain, inc), "newName": "bump"})
    changes = (r.get("result") or {}).get("changes", {})
    check(len(changes.get(uri_of(clib), [])) == 1 and len(changes.get(uri_of(cmain), [])) == 1,
          "classes: rename method in both files (%r)" % ({k: len(v) for k, v in changes.items()},))
    r = c.request("textDocument/rename", {**td(cmain, pos_of(cmain_text, "Counter(0)", 0)), "newName": "Tally"})
    changes = (r.get("result") or {}).get("changes", {})
    check(len(changes.get(uri_of(clib), [])) == 1 and len(changes.get(uri_of(cmain), [])) == 2,
          "classes: rename class (decl in clib; import + new in cmain) (%r)" % ({k: len(v) for k, v in changes.items()},))

    # ---- shutdown / exit --------------------------------------------------------------------
    r = c.request("shutdown", None)
    check(r.get("result", 0) is None and "error" not in r, "shutdown: null result")
    c.notify("exit", None)
    try:
        rc = c.p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        c.p.kill()
        rc = None
    check(rc == 0, "exit code 0 after shutdown+exit (got %r)" % (rc,))
    err = c.p.stderr.read().decode()
    check(err.strip() == "", "no stderr output (got %r)" % (err[:200],))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orin2", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--orin", default=None, help="use this orin binary instead of building one")
    a = ap.parse_args()
    exe = a.orin
    if exe is None:
        orin2 = a.orin2 if os.path.isabs(a.orin2) else os.path.join(ROOT, a.orin2)
        if not os.path.exists(orin2):
            sys.exit("missing %s (run tools/bootstrap.sh)" % orin2)
        exe = build(orin2)
    run(exe)
    print("test_lsp: %d checks, %d failed" % (checks, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
