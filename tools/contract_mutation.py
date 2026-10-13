#!/usr/bin/env python3
"""Contract-strength (mutation) tool: do the contracts and tests of an Orin file catch a bug? (ADR-0028)

For a .or file with `@Test` functions and contract clauses, apply source-level mutations to the bodies
of its functions and methods (not to `@Test` functions, not to `main`):

  arith     `+` <-> `-`
  compare   `<` <-> `<=`, `>` <-> `>=`
  equal     `==` <-> `!=`
  logic     `&&` <-> `||`
  literal   integer literal n -> n+1 and n-1
  drop      delete a single-line assignment / call statement (replaced by `{}`)

and build + run every mutant with `orin test` (runtime contract checking is on, ADR-0024). A mutant is

  killed    a contract fired (`trap: contract violated`) or a test failed / trapped / timed out
  survived  everything passed: neither the contracts nor the tests notice the changed behaviour
  invalid   the mutant does not compile (a type error): excluded from the counts

The report is per function: killed / total (total = killed + survived), the survivors with line and
column, and how the killed ones died (contract vs test). Survivors are the finding: either the function
is under-specified, or the mutant is equivalent (e.g. `<` to `<=` where both values are never equal).
The tool cannot tell these apart; a survivor is a question, not proof of a bug.

Limits (honest): the mutations are textual (formatter-canonical code is assumed: comparison operators
have spaces, generics do not), one mutation per mutant; equivalent mutants are counted as survivors;
only the tests that `orin test` discovers from the entry are run; the whole directory of the file is
copied per mutant, so keep the file in a small directory.

Usage: python3 tools/contract_mutation.py FILE.or [--entry ENTRY.or] [--orinc build/bootstrap/orin2]
         [--max-mutants 40] [--jobs N] [--seed 1] [--timeout 5] [--format text|json] [--out report.json]
         [--min-kill-rate 0.0]
Exit status: 0, or 1 when the baseline fails or the kill rate is below --min-kill-rate (when given).
"""
import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYWORDS = {"if", "while", "for", "match", "switch", "return", "else", "function", "catch"}


# ------------------------------------------------------------------ source model

def mask(src):
    """`src` with comments and string / template literals blanked (newlines and offsets kept)."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c in "\"`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def match_close(m, i, open_c, close_c):
    """Index of the bracket closing the one at `i` in masked text `m`, or -1."""
    depth = 0
    for j in range(i, len(m)):
        if m[j] == open_c:
            depth += 1
        elif m[j] == close_c:
            depth -= 1
            if depth == 0:
                return j
    return -1


def body_after_params(m, name_end):
    """(open, close) of the `{ ... }` body of a declaration whose name ends at `name_end`, or None."""
    p = m.find("(", name_end)
    if p < 0:
        return None
    q = match_close(m, p, "(", ")")
    if q < 0:
        return None
    b = m.find("{", q)
    semi = m.find(";", q)
    if b < 0 or (0 <= semi < b):
        return None
    e = match_close(m, b, "{", "}")
    return (b, e) if e > b else None


def is_test(src, start):
    """True when the declaration at `start` is preceded by an `@Test` annotation line."""
    lines = src[:start].split("\n")[:-1]
    k = len(lines) - 1
    while k >= 0:
        s = lines[k].strip()
        if s == "" or s.startswith("//"):
            k -= 1
        elif s.startswith("@"):
            if s.startswith("@Test"):
                return True
            k -= 1
        else:
            break
    return False


def functions(src, m):
    """[(name, decl_start, body_open, body_close)] for functions and methods that are not tests / main."""
    found = []
    for mt in re.finditer(r"\bfunction\s+(\w+)", m):
        b = body_after_params(m, mt.end())
        if b:
            found.append((mt.group(1), mt.start(), b[0], b[1]))
    for cm in re.finditer(r"\bclass\s+(\w+)", m):
        ob = m.find("{", cm.end())
        if ob < 0:
            continue
        cb = match_close(m, ob, "{", "}")
        depth_at = {}
        d = 0
        for i in range(ob, cb + 1):
            if m[i] == "{":
                d += 1
            elif m[i] == "}":
                d -= 1
            depth_at[i] = d
        for mt in re.finditer(r"^[ \t]*(?:(?:private|static|public)\s+)*(\w+)\s*(?:<[^>(]*>)?\s*\(", m[ob:cb], re.M):
            pos = ob + mt.start()
            if depth_at.get(pos, 0) != 1 or mt.group(1) in KEYWORDS:
                continue
            b = body_after_params(m, ob + mt.start(1) + len(mt.group(1)))
            if b and b[1] <= cb:
                found.append((cm.group(1) + "." + mt.group(1), pos, b[0], b[1]))
    return [f for f in found if f[0] != "main" and not f[0].endswith(".constructor") and not is_test(src, f[1])]


# ------------------------------------------------------------------ mutation operators

SWAP = [("==", "!="), ("!=", "=="), ("&&", "||"), ("||", "&&"), ("<=", "<"), (">=", ">")]


def sites(m, lo, hi):
    """[(op, start, end, replacement)] mutation sites in masked text m[lo:hi]."""
    out = []
    body = m[lo:hi]
    for mt in re.finditer(r"==|!=|&&|\|\||<=|>=", body):
        a, b = mt.group(), None
        for x, y in SWAP:
            if x == a:
                b = y
        kind = "equal" if a in ("==", "!=") else ("logic" if a in ("&&", "||") else "compare")
        out.append((kind, lo + mt.start(), lo + mt.end(), b))
    for mt in re.finditer(r"(?<=\s)([<>])(?=\s)", body):
        out.append(("compare", lo + mt.start(1), lo + mt.end(1), mt.group(1) + "="))
    for mt in re.finditer(r"(?<=[\w)\]])\s+([+\-])\s+(?=[\w(])", body):
        out.append(("arith", lo + mt.start(1), lo + mt.end(1), "-" if mt.group(1) == "+" else "+"))
    for mt in re.finditer(r"(?<![\w.$])(\d+)(?![\w.])", body):
        n = int(mt.group(1))
        out.append(("literal", lo + mt.start(), lo + mt.end(), str(n + 1)))
        if n > 0:
            out.append(("literal", lo + mt.start(), lo + mt.end(), str(n - 1)))
    for mt in re.finditer(r"^([ \t]*)((?:this\.)?[\w.\[\]]+\s*(?:[-+*/%]?=)[^=].*;|[\w.]+\(.*\);)[ \t]*$", body, re.M):
        stmt = mt.group(2)
        if stmt.startswith(("let ", "const ", "return", "console.", "break", "continue")):
            continue
        out.append(("drop", lo + mt.start(2), lo + mt.end(2), "{}"))
    return out


def line_col(src, off):
    line = src.count("\n", 0, off) + 1
    return line, off - (src.rfind("\n", 0, off) + 1) + 1


def enumerate_mutants(src):
    m = mask(src)
    res = []
    for name, start, bo, bc in functions(src, m):
        line, _ = line_col(src, start)
        for kind, a, b, rep in sites(m, bo + 1, bc):
            if rep is None:
                continue
            ln, col = line_col(src, a)
            res.append({"function": name, "function_line": line, "op": kind, "start": a, "end": b, "replacement": rep,
                        "line": ln, "col": col, "original": src[a:b]})
    return res


def sample(mutants, limit, seed):
    """At most `limit` mutants, spread over the functions (round-robin), deterministic for a seed."""
    if len(mutants) <= limit:
        return mutants
    rnd = random.Random(seed)
    by_fn = {}
    for x in mutants:
        by_fn.setdefault(x["function"], []).append(x)
    for xs in by_fn.values():
        rnd.shuffle(xs)
    chosen = []
    names = sorted(by_fn)
    while len(chosen) < limit and any(by_fn.values()):
        for nme in names:
            if by_fn[nme] and len(chosen) < limit:
                chosen.append(by_fn[nme].pop())
    return sorted(chosen, key=lambda x: x["start"])


# ------------------------------------------------------------------ running

def run_tests(orinc, workdir, entry_rel, timeout):
    """(kind, detail): kind is 'pass', 'fail', 'contract', 'invalid' for one `orin test` run in `workdir`."""
    cmd = [orinc, "test", "--format=json", "--runtime", os.path.join(ROOT, "runtime"), "--timeout", str(timeout),
           "--out-dir", os.path.join(workdir, ".mut-out"), os.path.join(workdir, entry_rel)]
    try:
        r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=60 + 20 * timeout)
    except subprocess.TimeoutExpired:
        return "fail", "timeout"
    out = r.stdout.decode("utf-8", "replace").strip()
    try:
        rep = json.loads(out)
    except ValueError:
        return "invalid", (r.stderr.decode("utf-8", "replace") + out)[:300]
    if "tests" not in rep:
        return "invalid", out[:300]
    failed = [t for t in rep["tests"] if t["status"] == "fail"]
    if not failed:
        return "pass", ""
    if any("contract violated" in t.get("stderr", "") for t in failed):
        return "contract", failed[0]["id"]
    return "fail", failed[0]["id"]


def run_mutant(args, src, entry_rel, srcdir, rel, mu):
    tmp = tempfile.mkdtemp(prefix="orin-mut-")
    try:
        work = os.path.join(tmp, "w")
        shutil.copytree(srcdir, work, ignore=shutil.ignore_patterns(".git", "build", ".mut-out", "node_modules"))
        with open(os.path.join(work, rel), "w", encoding="utf-8") as f:
            f.write(src[:mu["start"]] + mu["replacement"] + src[mu["end"]:])
        kind, detail = run_tests(args.orinc, work, entry_rel, args.timeout)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return dict(mu, result=kind, detail=detail)


def summarize(results, path):
    per = {}
    for r in results:
        f = per.setdefault(r["function"], {"function": r["function"], "line": r["function_line"], "killed": 0,
                                           "survived": 0, "invalid": 0, "killed_by_contract": 0,
                                           "killed_by_test": 0, "survivors": []})
        if r["result"] == "invalid":
            f["invalid"] += 1
        elif r["result"] == "pass":
            f["survived"] += 1
            f["survivors"].append({"line": r["line"], "col": r["col"], "op": r["op"],
                                   "original": r["original"], "mutated": r["replacement"]})
        else:
            f["killed"] += 1
            f["killed_by_contract" if r["result"] == "contract" else "killed_by_test"] += 1
    fns = sorted(per.values(), key=lambda f: f["line"])
    for f in fns:
        f["total"] = f["killed"] + f["survived"]
    killed = sum(f["killed"] for f in fns)
    total = sum(f["total"] for f in fns)
    return {"file": path, "functions": fns, "killed": killed, "total": total, "survived": total - killed,
            "invalid": sum(f["invalid"] for f in fns), "kill_rate": (killed / total) if total else None}


def text_report(rep):
    lines = []
    for f in rep["functions"]:
        lines.append("%s (line %d): killed %d/%d (contract %d, test %d)%s" % (
            f["function"], f["line"], f["killed"], f["total"], f["killed_by_contract"], f["killed_by_test"],
            ", %d invalid" % f["invalid"] if f["invalid"] else ""))
        for s in f["survivors"]:
            lines.append("    survived %s:%d:%d  %s  `%s` -> `%s`" % (
                os.path.basename(rep["file"]), s["line"], s["col"], s["op"], s["original"], s["mutated"]))
    rate = "n/a" if rep["kill_rate"] is None else "%.0f%%" % (100 * rep["kill_rate"])
    lines.append("mutants: killed %d, survived %d, invalid %d; kill rate %s" % (
        rep["killed"], rep["survived"], rep["invalid"], rate))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="contract-strength (mutation) tool")
    ap.add_argument("file")
    ap.add_argument("--entry", help="file whose @Test functions are run (default: FILE)")
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--max-mutants", type=int, default=40)
    ap.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 2))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=5, help="seconds per test of a mutant")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    ap.add_argument("--out", help="also write the JSON report here")
    ap.add_argument("--min-kill-rate", type=float, default=None)
    args = ap.parse_args()
    if not os.path.isabs(args.orinc) and os.sep in args.orinc:
        args.orinc = os.path.join(ROOT, args.orinc)
    path = os.path.abspath(args.file)
    srcdir = os.path.dirname(path)
    rel = os.path.basename(path)
    entry_rel = os.path.relpath(os.path.abspath(args.entry), srcdir) if args.entry else rel
    with open(path, encoding="utf-8") as f:
        src = f.read()

    base_dir = tempfile.mkdtemp(prefix="orin-mut-base-")
    try:
        work = os.path.join(base_dir, "w")
        shutil.copytree(srcdir, work, ignore=shutil.ignore_patterns(".git", "build", ".mut-out", "node_modules"))
        kind, detail = run_tests(args.orinc, work, entry_rel, args.timeout)
    finally:
        shutil.rmtree(base_dir, ignore_errors=True)
    if kind != "pass":
        print("contract_mutation: the unmutated program does not pass its tests (%s: %s)" % (kind, detail), file=sys.stderr)
        return 1

    mutants = sample(enumerate_mutants(src), args.max_mutants, args.seed)
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(lambda mu: run_mutant(args, src, entry_rel, srcdir, rel, mu), mutants))
    rep = summarize(results, os.path.relpath(path, ROOT) if path.startswith(ROOT) else path)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(rep, f, indent=1)
    print(json.dumps(rep) if args.format == "json" else text_report(rep))
    if args.min_kill_rate is not None and (rep["kill_rate"] is None or rep["kill_rate"] < args.min_kill_rate):
        print("contract_mutation: kill rate below %.2f" % args.min_kill_rate, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
