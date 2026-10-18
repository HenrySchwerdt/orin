#!/usr/bin/env python3
"""Allocation census (docs/perf/alloc-census.md, ADR-0038): where the heap allocations and RC operations come from.

Every workload is compiled in the opt-in census mode (`orin2 compile --stats-sites`: a site mark before every MIR
instruction, see runtime/core/orin_runtime.h "Allocation-site census") and linked with a runtime built with -DORIN_SITE_STATS;
ORIN_STATS=sites then writes, per MIR site, the objects allocated there (by runtime kind), their bytes, growths and
frees, the retains / releases / COW copies executed there and those suffered by the objects allocated there, and the
joint (executing site, allocating site) RC counts. Counts are deterministic; nothing here measures time.

  alloc_census.py run      [--orinc build/bootstrap/orin2] [--out build/census] [--only a,b] [--no-http] [--no-selfcompile]
      builds and runs the workloads: every bench/<name>/main.or, examples/http_server.or under a scripted loopback load
      (Python client, the same kind of traffic as tools/net_checks.py), and the self-compile (`orin2 compile
      compiler/main.or`); raw reports land in <out>/<workload>.sites and <out>/<workload>.summary.json
  alloc_census.py report   [--out build/census] [--md docs/perf/alloc-census.md] [--json build/census/census.json]
      reads the raw reports, attributes every site to an object kind and to the ADR-0038 transformation that would
      remove it (classes a-g, rules and reviewed overrides in CLASSIFY below), and writes the Markdown report
  alloc_census.py identity BASE_ORIN NEW_ORIN [--out build/census/identity] [--compiler-src BASE_TREE/compiler/main.or]
      the gate for normal builds: generated C and LLVM IR of BASE and NEW must be byte-identical on the corpus
      (tests/run, tests/next/run, bench, examples, compiler/main.or -- pass the base tree's copy when the compiler changed)
  alloc_census.py top [--only w1,w2] [--by alloc|rc|of] [-n 25] [--callers 3]
      the raw top sites of each workload (allocations, RC executed there, RC received by its objects), with callers
  alloc_census.py review [-n 30]
      the top sites with their kind and class, and the top borrow candidates (to review RULES)
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CC = os.environ.get("CC", "cc")
CFLAGS = ["-O1", "-w"]  # counts do not depend on the C optimisation level; -O1 keeps the 30 MB self-compile C quick to build
FIELDS = ["n_str", "n_arr_val", "n_arr_ref", "n_struct", "bytes", "grows", "grow_bytes", "frees", "of_retains", "of_releases",
          "of_cow", "at_retains", "at_releases", "at_cow", "at_cow_inplace", "arr_val_freed", "arr_val_small", "arr_val_elems",
          "last_tag", "last_nslots", "last_refmask"]
NAME_FIELDS = ["fn", "func", "pos", "file", "start", "end", "mir", "target"]


def sh(cmd, **kw):
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    if r.returncode != 0:
        sys.stderr.write("command failed: %s\n%s\n" % (" ".join(cmd), r.stderr.decode(errors="replace")[-2000:]))
        raise SystemExit(1)
    return r


# ---------------------------------------------------------------- run

def build_runtime(out):
    objs = []
    for src in rt_src():
        o = os.path.join(out, os.path.basename(src)[:-2] + ".sites.o")
        sh([CC] + CFLAGS + ["-DORIN_SITE_STATS", *rt_inc(), "-c", src, "-o", o])
        objs.append(o)
    return objs


def build(orinc, src, out, name, rt):
    c = os.path.join(out, name + ".c")
    exe = os.path.join(out, name)
    sh([orinc, "compile", "--stats-sites", src, "-o", c], timeout=1800)
    sh([CC] + CFLAGS + [*rt_inc(), c] + rt + ["-lm", "-lpthread", "-o", exe], timeout=1800)
    save_mir(orinc, src, out, name)
    return exe


def save_mir(orinc, src, out, name):
    """The optimised MIR of the workload (the report's borrow analysis reads it; sites are matched by function and position)."""
    r = sh([orinc, "mir", src], timeout=1800)
    open(os.path.join(out, name + ".mir"), "wb").write(r.stdout)


def summary_of(stderr):
    for line in stderr.decode(errors="replace").splitlines():
        if line.startswith('{"orin_stats":'):
            return json.loads(line)["orin_stats"]
    raise SystemExit("no ORIN_STATS summary in the output")


def run_exe(exe, args, out, name, timeout=3600):
    env = dict(os.environ, ORIN_STATS="sites", ORIN_SITES_OUT=os.path.join(out, name + ".sites"))
    r = subprocess.run([exe] + args, cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
    if r.returncode != 0:
        raise SystemExit("%s exited with %d: %s" % (name, r.returncode, r.stderr.decode(errors="replace")[-1000:]))
    return summary_of(r.stderr)


def http_load(port, conns, per_conn, body):
    """`conns` keep-alive connections, each `per_conn` requests answered one at a time (GET /health, POST /echo with
    `body`, GET of an unknown path, alternating); the last request of a connection asks for `Connection: close`."""
    answered = 0
    for c in range(conns):
        s = socket.create_connection(("127.0.0.1", port), timeout=20)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        buf = b""
        for i in range(per_conn):
            last = i == per_conn - 1
            conn = "close" if last else "keep-alive"
            k = (c + i) % 3
            if k == 0:
                req = b"GET /health HTTP/1.1\r\nHost: localhost\r\nUser-Agent: census\r\nAccept: */*\r\nConnection: " + conn.encode() + b"\r\n\r\n"
            elif k == 1:
                req = (b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: " + str(len(body)).encode()
                       + b"\r\nConnection: " + conn.encode() + b"\r\n\r\n" + body)
            else:
                req = b"GET /missing/page?q=1 HTTP/1.1\r\nHost: localhost\r\nConnection: " + conn.encode() + b"\r\n\r\n"
            s.sendall(req)
            while b"\r\n\r\n" not in buf:
                d = s.recv(65536)
                if not d:
                    raise SystemExit("http: connection closed early")
                buf += d
            head, rest = buf.split(b"\r\n\r\n", 1)
            m = re.search(rb"(?i)content-length:\s*(\d+)", head)
            n = int(m.group(1)) if m else 0
            while len(rest) < n:
                d = s.recv(65536)
                if not d:
                    raise SystemExit("http: short body")
                rest += d
            buf = rest[n:]
            answered += 1
        s.close()
    return answered


def run_http(orinc, out, rt, conns=40, per_conn=50):
    exe = build(orinc, "examples/http_server.or", out, "http_server", rt)
    env = dict(os.environ, ORIN_STATS="sites", ORIN_SITES_OUT=os.path.join(out, "http_server.sites"))
    err = open(os.path.join(out, "http_server.err"), "wb+")
    # port 0 (a free port), serve `conns` connections then exit, 5 s request deadline, quiet
    p = subprocess.Popen([exe, "0", str(conns), "5000", "0"], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=err)
    try:
        port = None
        for _ in range(300):
            err.seek(0)
            m = re.search(rb"listening on 127\.0\.0\.1:(\d+)", err.read())
            if m:
                port = int(m.group(1))
                break
            time.sleep(0.1)
        if port is None:
            raise SystemExit("http_server did not start")
        body = (b"census payload " * 40)[:600]
        answered = http_load(port, conns, per_conn, body)
        p.wait(timeout=120)
    finally:
        if p.poll() is None:
            p.kill()  # our own child, by PID
            p.wait()
    err.seek(0)
    s = summary_of(err.read())
    s["_requests"] = answered
    return s


def cmd_run(a):
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    rt = build_runtime(out)
    only = set(a.only.split(",")) if a.only else None
    names = sorted(d for d in os.listdir(os.path.join(ROOT, "bench")) if os.path.exists(os.path.join(ROOT, "bench", d, "main.or")))
    for n in names:
        if only and n not in only:
            continue
        exe = build(a.orinc, os.path.join("bench", n, "main.or"), out, n, rt)
        s = run_exe(exe, [], out, n)
        json.dump(s, open(os.path.join(out, n + ".summary.json"), "w"), indent=1)
        print("%-14s allocs %12d  retains %12d  releases %12d  cow %10d" % (n, s["alloc_total"], s["retains"], s["releases"], s["cow_copies"]))
    if not a.no_http and (not only or "http_server" in only):
        s = run_http(a.orinc, out, rt)
        json.dump(s, open(os.path.join(out, "http_server.summary.json"), "w"), indent=1)
        print("%-14s allocs %12d  retains %12d  releases %12d  cow %10d  (%d requests)" % (
            "http_server", s["alloc_total"], s["retains"], s["releases"], s["cow_copies"], s["_requests"]))
    if not a.no_selfcompile and (not only or "selfcompile" in only):
        exe = build(a.orinc, "compiler/main.or", out, "selfcompile", rt)
        s = run_exe(exe, ["compile", "compiler/main.or", "-o", os.path.join(out, "selfcompile.out.c")], out, "selfcompile")
        json.dump(s, open(os.path.join(out, "selfcompile.summary.json"), "w"), indent=1)
        print("%-14s allocs %12d  retains %12d  releases %12d  cow %10d" % ("selfcompile", s["alloc_total"], s["retains"], s["releases"], s["cow_copies"]))


# ---------------------------------------------------------------- identity gate

def corpus(compiler_src="compiler/main.or"):
    xs = []
    for d in ("tests/run", "tests/next/run"):
        for e in sorted(os.listdir(os.path.join(ROOT, d))):
            p = os.path.join(d, e)
            if e.endswith(".or"):
                xs.append(p)
            elif os.path.isdir(os.path.join(ROOT, p)) and os.path.exists(os.path.join(ROOT, p, "main.or")):
                xs.append(os.path.join(p, "main.or"))
    for e in sorted(os.listdir(os.path.join(ROOT, "bench"))):
        if os.path.exists(os.path.join(ROOT, "bench", e, "main.or")):
            xs.append(os.path.join("bench", e, "main.or"))
    for e in sorted(os.listdir(os.path.join(ROOT, "examples"))):
        if e.endswith(".or"):
            xs.append(os.path.join("examples", e))
    xs.append(compiler_src)  # the compiler itself as a program (pass the BASE tree's copy when the compiler sources differ)
    return xs


def cmd_identity(a):
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    xs = corpus(a.compiler_src)

    def one(job):
        i, x = job
        res = []
        for ext, extra in ((".c", []), (".ll", ["--backend=llvm"])):
            outs = []
            for tag, c in (("base", a.base), ("new", a.new)):
                f = os.path.join(out, "%d.%s%s" % (i, tag, ext))
                if os.path.exists(f):
                    os.remove(f)
                r = subprocess.run([c, "compile"] + extra + [x, "-o", f], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800)
                data = open(f, "rb").read() if os.path.exists(f) else b""
                outs.append((r.returncode, r.stdout, r.stderr, data))
                if os.path.exists(f):
                    os.remove(f)
            res.append((x, ext, outs[0] == outs[1], outs[0][0], len(outs[0][3])))
        return res

    same = diff = produced = 0
    with ThreadPoolExecutor(a.jobs) as ex:
        for res in ex.map(one, list(enumerate(xs))):
            for x, ext, eq, rc, n in res:
                if eq:
                    same += 1
                    produced += 1 if (rc == 0 and n > 0) else 0
                else:
                    diff += 1
                    print("DIFF %s (%s)" % (x, ext))
    print("identity: %d programs x {C, LLVM}: %d identical (%d with output, the rest fail identically), %d different"
          % (len(xs), same, produced, diff))
    sys.exit(1 if diff else 0)


# ---------------------------------------------------------------- loading the raw reports

def src_path(p):
    if p.startswith("$stdlib/"):
        return os.path.join(ROOT, "library", "std", p[len("$stdlib/"):])
    if p.startswith("$std/"):
        return os.path.join(ROOT, "library", "core", p[len("$std/"):])
    if p.startswith("$array/"):
        return os.path.join(ROOT, "library", "collections", p[len("$array/"):])
    return os.path.join(ROOT, p)


_SRC = {}


def source(p):
    if p not in _SRC:
        try:
            _SRC[p] = open(src_path(p), "rb").read()  # spans are byte offsets
        except OSError:
            _SRC[p] = None
    return _SRC[p]


def line_col(p, off):
    t = source(p)
    if t is None:
        return 0, 0
    line = t.count(b"\n", 0, off) + 1
    col = off - (t.rfind(b"\n", 0, off) + 1) + 1
    return line, col


def span_text(p, a, b, limit=70):
    t = source(p)
    if t is None or a == b:
        return ""
    s = " ".join(t[a:b].decode("utf-8", errors="replace").split())
    return s if len(s) <= limit else s[:limit - 3] + "..."


def load(out, name):
    sites, pairs, calls = {}, [], []
    for line in open(os.path.join(out, name + ".sites"), encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if f[0] == "site":
            d = dict(zip(FIELDS, map(int, f[2:2 + len(FIELDS)])))
            d.update(zip(NAME_FIELDS, f[2 + len(FIELDS):]))
            d["id"] = int(f[1])
            d["start"], d["end"] = int(d.get("start") or 0), int(d.get("end") or 0)
            d["allocs"] = d["n_str"] + d["n_arr_val"] + d["n_arr_ref"] + d["n_struct"]
            sites[d["id"]] = d
        elif f[0] == "pair":
            pairs.append(tuple(map(int, f[1:6])))
        elif f[0] == "call":
            calls.append(tuple(map(int, f[1:5])))
    summ = json.load(open(os.path.join(out, name + ".summary.json")))
    return sites, pairs, calls, summ


def load_names(out, name):
    """Every site's description, by id, from the table in the generated C (the report only prints sites that did something)."""
    names = []
    inside = False
    for line in open(os.path.join(out, name + ".c"), encoding="utf-8", errors="replace"):
        if line.startswith("const char *const orin_site_names[] = {"):
            inside = True
            continue
        if inside:
            if line.startswith("};"):
                break
            s = line.strip()[1:-2]  # "...",
            s = re.sub(r'\\(.)', lambda m: {"t": "\t", "\\": "\\", '"': '"', "?": "?"}[m.group(1)], s)
            d = dict(zip(NAME_FIELDS, s.split("\t")))
            d["start"], d["end"] = int(d.get("start") or 0), int(d.get("end") or 0)
            names.append(d)
    return names


def workloads(out):
    return sorted(f[:-len(".summary.json")] for f in os.listdir(out) if f.endswith(".summary.json"))


def cmd_top(a):
    out = os.path.abspath(a.out)
    for w in (a.only.split(",") if a.only else workloads(out)):
        sites, pairs, calls, summ = load(out, w)
        names = load_names(out, w)
        callers = {}
        for s, c, n, b in calls:
            callers.setdefault(s, []).append((n, c))
        print("== %s: allocs %d retains %d releases %d cow %d" % (w, summ["alloc_total"], summ["retains"], summ["releases"], summ["cow_copies"]))
        key = {"alloc": lambda s: s["allocs"], "rc": lambda s: s["at_retains"] + s["at_releases"],
               "of": lambda s: s["of_retains"] + s["of_releases"]}[a.by]
        for s in sorted(sites.values(), key=key, reverse=True)[:a.n]:
            if key(s) == 0:
                break
            ln, col = line_col(s["file"], s["start"])
            print("%10d  str%d av%d ar%d st%d(t%d/n%d) by%d  of_rc %d/%d  at_rc %d/%d cow %d  | %s %s %s:%d:%d | %s | %s | %s" % (
                key(s), s["n_str"], s["n_arr_val"], s["n_arr_ref"], s["n_struct"], s["last_tag"], s["last_nslots"], s["bytes"],
                s["of_retains"], s["of_releases"], s["at_retains"], s["at_releases"], s["at_cow"], s["func"], s["pos"], s["file"], ln, col,
                s["mir"][:60], s["target"], span_text(s["file"], s["start"], s["end"])))
            if a.callers:
                for n, c in sorted(callers.get(s["id"], []), reverse=True)[:a.callers]:
                    d = names[c]
                    cl, cc = line_col(d["file"], d["start"])
                    print("            <- %10d from %s %s:%d | %s" % (n, d["func"], d["file"], cl, span_text(d["file"], d["start"], d["end"], 60)))


# ---------------------------------------------------------------- MIR: borrow candidates (class d)
#
# A retain is a class-(d) candidate when the value it creates is only READ until it is released: every use of the local
# (following `move` chains) is a release, a read (getfield, arrayget, tag, comparison, builtin argument, borrow, a
# borrowed call argument), or an argument for an OWNED parameter that the callee itself only reads (decided the same way,
# interprocedurally, least fixpoint: recursion counts as "not read-only"). Anything that stores, returns, captures,
# mutates (makeunique, takefield, strappend / arrayextend target) or hands the value to an in/out receiver makes it a
# real ownership transfer. Syntactic and flow-insensitive; a local with more than one definition is never a candidate.

LOC = re.compile(r"\bl(\d+)\b")
FN_HDR = re.compile(r"^fn(\d+) (.*) \(params (\d+)(.*)\) -> \S+$")
RETAINING = re.compile(r"^l(\d+) = (dup |builtin (opt\.unwrap|opt\.unwrapOr|res\.unwrap|res\.unwrapErr)\()")


def parse_mir(path):
    funcs, byname, cur = [], {}, None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        m = FN_HDR.match(line)
        if m:
            owned = set(int(x) for x in re.findall(r"l(\d+)", m.group(4).split("owned")[1])) if "owned" in m.group(4) else set()
            cur = {"idx": int(m.group(1)), "name": m.group(2), "nparams": int(m.group(3)), "owned": owned,
                   "inout": "inout" in m.group(4), "blocks": []}
            funcs.append(cur)
            byname[cur["name"]] = cur
            continue
        if cur is None:
            continue
        s = line.strip()
        if re.match(r"^b\d+:$", s):
            cur["blocks"].append([])
        elif line.startswith("    ") and cur["blocks"] is not None and cur["blocks"]:
            cur["blocks"][-1].append(re.sub(r" @\d+:\d+-\d+$", "", s))
    for f in funcs:
        defs, uses = {}, {}
        for b, blk in enumerate(f["blocks"]):
            for k, ins in enumerate(blk):
                m = re.match(r"^l(\d+) = ", ins)
                d = int(m.group(1)) if m else None
                if d is not None:
                    defs.setdefault(d, []).append((b, k))
                body = ins[m.end():] if m else ins
                for x in set(int(t) for t in LOC.findall(body)):
                    uses.setdefault(x, []).append((b, k, ins))
        f["defs"], f["uses"] = defs, uses
    return {"funcs": funcs, "byname": byname, "byidx": {f["idx"]: f for f in funcs}}


class Borrow:
    def __init__(self, mir):
        self.mir = mir
        self.ro_param = {}  # (fn idx, param) -> bool

    def callee_reads_only(self, fidx, i):
        key = (fidx, i)
        if key in self.ro_param:
            return self.ro_param[key]
        self.ro_param[key] = False  # recursion: not read-only (least fixpoint)
        f = self.mir["byidx"].get(fidx)
        ok = f is not None and not (f["inout"] and i == 0) and self.read_only(f, i, set())
        self.ro_param[key] = ok
        return ok

    def read_only(self, f, x, seen):
        """All uses of local x in f (following moves) only read it or release it."""
        if x in seen:
            return True
        seen.add(x)
        for b, k, ins in f["uses"].get(x, []):
            lx = "l%d" % x
            if ins == "release " + lx:
                continue
            m = re.match(r"^l(\d+) = move l(\d+)$", ins)
            if m and int(m.group(2)) == x:
                y = int(m.group(1))
                if len(f["defs"].get(y, [])) != 1 or not self.read_only(f, y, seen):
                    return False
                continue
            if re.match(r"^l\d+ = (borrow|getfield|arrayget|tag|dup|eq|ne|lt|le|gt|ge|add|sub|mul|div|rem|and|or|not|neg) ", ins):
                # a read of x (as the object, the index or an operand); `dup` makes a separate value
                continue
            m = re.match(r"^(?:l\d+ = )?builtin ([\w.]+)\((.*)\)$", ins)
            if m:
                continue  # builtins borrow their arguments (runtime convention)
            m = re.match(r"^(?:l\d+ = )?call fn(\d+)\((.*)\)$", ins)
            if m:
                g = self.mir["byidx"].get(int(m.group(1)))
                args = [a.strip() for a in m.group(2).split(",")] if m.group(2) else []
                for i, a in enumerate(args):
                    if a != lx:
                        continue
                    if g is None:
                        return False
                    if i in g["owned"] and not self.callee_reads_only(g["idx"], i):
                        return False
                continue
            m = re.match(r"^(?:l\d+ = )?(callind|callvirt) (\S+?)[(#]", ins)
            if m:
                continue  # indirect calls borrow their arguments (closure / vtable convention)
            if re.match(r"^branch |^switch ", ins):
                continue
            return False  # stored, returned, captured, mutated, appended to, ...
        return True

    def candidate(self, f, b, k):
        """Is instruction (b, k) of f a retain whose value is only read before its release?"""
        ins = f["blocks"][b][k]
        m = RETAINING.match(ins)
        if not m:
            return False
        d = int(m.group(1))
        return len(f["defs"].get(d, [])) == 1 and self.read_only(f, d, set())


# ---------------------------------------------------------------- classification

CLASSES = [
    ("a", "unboxing", "Option, Result, pairs and small records kept in registers / inline instead of a heap object"),
    ("b", "packed arrays", "u8[] and other narrow scalar arrays in 1-4 byte elements instead of 8-byte slots (bytes only)"),
    ("c", "escape / stack / scalar replacement", "the object does not outlive the function (or the call it is passed to)"),
    ("d", "borrow", "a retain / release pair around a read-only use (borrow inference)"),
    ("e", "reuse in place", "the memory of a unique object that dies right there is reused for the new one"),
    ("f", "region or freeze", "scope-bound graphs freed in one step / immutable long-lived graphs without per-object RC"),
    ("g", "algorithmic or library", "a different algorithm or std function: the object is not needed at all"),
    ("-", "inherent", "the value is real long-lived or shared data; stays on the RC heap"),
    ("?", "unsure", "not decided (see the note)"),
]
CLS_NAME = {c: n for c, n, _ in CLASSES}
OBJ_RC = set("acfg")  # classes that remove the object, and with it every RC operation on it

OPTION_BUILTINS = {"arr.get", "str.indexOf", "parseInt", "parseIntK", "parseFloat", "file.close", "file.readLine", "file.read",
                   "io.readLine", "int.chk"}
RESULT_BUILTINS = {"fs.readFile", "fs.writeFile", "net.recv", "net.send", "net.resolve"}

# Reviewed decisions (docs/perf/alloc-census.md): (function regex, MIR regex, class, kind or None, note). The first match wins;
# sites without a rule get the default of their kind (DEFAULT_CLASS) and are marked "default" in the tables. Every note says
# why; "?" means the census could not decide it.
RULES = [
    # ---- self-compile: the ownership verifier (compiler/verify)
    (r"^verify/rules\.Transfer\.set$", r"makeunique l6$", "g", "COW copy of the ls array (int[], ~290 entries)",
     "ONE per block run (427k, 977 MB): `Fixpoint.outOf(b, ins[b].unwrap())` builds `new Transfer(.., st, ..)`, whose constructor "
     "does `this.ls = st.ls`, so the array has two owners (the table entry `ins[b]`, which must survive for later joins, and "
     "the Transfer) and the first `this.ls[l] = ..` copies it. Remove: a per-Fixpoint scratch ls buffer that outOf fills "
     "(element copy, no malloc / free / COW; take-put it into the Transfer) and from which a fresh array is cut only when "
     "the out-state is stored (first visit of a successor); or pack ls as i32[] (b) to halve the bytes"),
    (r"^verify/rules\.Transfer\.set$", r"makeunique l4$", "d", "COW copy of the Transfer record (8 fields)",
     "`this.callOwned(dst, args, this.prog.functions[fi].paramOwned)` in Transfer.instr: the argument is borrowed from "
     "`this.prog`, so opt/calls.insertCallDups dups the whole receiver (`dup l2` / call / `release l2`) and the first write "
     "inside the callee copies the record and retains its 6 reference fields; the ls array then has a third owner and "
     "is copied once more. Dup the argument (a retain of the paramOwned array) instead of the receiver, or hoist it "
     "into a `const po` before the call"),
    (r"^verify/rules\.Transfer\.killBorrows$", r"makeunique", "g", "COW copy of the ls array", "as Transfer.set: first write to the shared in-state"),
    (r"^verify/rules\.Transfer\.constructor$", r"struct", "c", "class object Transfer (8 fields)",
     "one per block run (outOf / runBlock), dead when `.state()` / errs are read: keep one Transfer in the Fixpoint and "
     "reset it per block (e), or scalar-replace it after inlining outOf; a class with reference fields is not unboxed"),
    (r"^verify/state\.State\.constructor$", r"struct", "c", "class object State {ls, holes} (2 refs)",
     "54% are `Transfer.state()` results that outOf returns and joinIfChanged only reads (scalar replacement / pass ls and "
     "holes); 46% are `join` results stored into `ins[s]` (class e). Not unboxed: a class with two reference fields"),
    (r"^verify/state\.State\.join$", r"arraynew val", "e", "array<int> (joined ls)",
     "built by pushing `joinLs` per local; it replaces `ins[s]`, whose old state dies at the store: join into prev.ls in "
     "place (the table owns it uniquely once `Some(prev)` is not kept alive by the match)"),
    (r"^verify/state\.State\.joinIfChanged$", r"struct", "e", "Option<State> (ref payload)",
     "`Some(this.join(o))` returned to Fixpoint.run and matched at once: a `joinInto(o): bool` that joins in place returns "
     "no Option at all. Unboxing rejects it today: the payload is a reference"),
    (r"^verify/verify\.Fixpoint\.run$", r"struct tag0 \{l\d+\}", "g", "Option<State> stored in the table",
     "`ins[s] = Some(out)` / `Some(nw)`: the Option is stored in the array `ins` (unboxing rejects heap slots); keep a "
     "State[] and a `reached: bool[]` so the table holds no Option"),
    (r"^verify/verify\.Fixpoint\.outOf$|^verify/verify\.runBlock$", r"arraynew ref \[\]", "c", "array<ref> (empty)",
     "`errs: []` / `warns: []` of a Transfer whose issues are discarded (`this.none` shared in outOf)"),
    (r"^verify/verify\.fixpoint$|^verify/verify\.Fixpoint\.take$", r"arraypop", "a", None, "`work.pop()` Option, unwrapped at once"),
    (r"^verify/rules\.Transfer\.(instr|put|term)$", r"struct tag0 \{l\d+\}", "g", "variant OLocal(s) (1 scalar)",
     "a temporary Operand built only to call `readOp` / `consume` on a local; not unboxed because the Operand web also "
     "contains operands stored in Instr nodes (heap slots): call `readLocal(s)` / `consumeLocal(s)` directly"),
    (r"^verify/rules\.Transfer\.call$", r"arraynew val \[\]", "c", "array<usize> (empty)",
     "per-call scratch list of argument roots, consumed in the same function"),
    (r"^verify/verify\.entryState$", r"arraynew ref", "-", "array<ref>", "the entry state of a function: real data"),
    # ---- self-compile: optimiser analyses (compiler/opt)
    (r"^opt/analysis\.successors$", r"arraynew val", "c", "array<usize> (0-2 elements)",
     "successor list `[b]` / `[a, b]` / `[]` iterated once by the caller; bounded (<= 2) and does not escape the caller's loop"),
    (r"^mir/wellformed\.successors$", r"arraynew val|task\.arrayWithCapacity|arr\.concat", "g", "array<usize> (0-2 elements)",
     "the same function as opt/analysis.successors (a duplicate): iterated once by Fixpoint.run / verifyFunction; offer "
     "`succAt(t, k)` / a visitor and share one implementation (a TSwitch builds `cases.map(..).concat([d])`)"),
    (r"^opt/calls\.insertCallDups$", r"arraynew ref|struct tag0 \{l\d+, l\d+, l\d+, l\d+, l\d+, l\d+, l\d+\}", "c",
     "record Cx (7 fields) + its empty errs / warns",
     "a verifier context built per call site only to run `step` once and read `.st`: scalar replacement after inlining"),
    (r"^verify/rules\.holeKey$", r"struct", "a", "record HoleEntryKey {sym, idx} (2 scalars)", "as slotKey"),
    (r"^cemit/text\.commentSafe$", r"strappend", "g", "string (one char)",
     "`out += name.charAt(i)`: a one-character string per character of every local name (census-mode comments `/* name */`); "
     "append the character code / copy runs with substring, or skip the comment when no `*/` occurs"),
    (r"^lower/lowerer\.Lowerer\.args$", r"struct tag0 \{l\d+, l\d+, l\d+, l\d+\}", "a", "record Args (4 fields)",
     "returned and destructured by the caller"),
    (r"^(lower/lowerer\.Lowerer\.emit|syntax/parser\.Parser\.expectP|check/fnctx\.FnCtx\.restorePre)$", r"makeunique", "?",
     "COW copy of the receiver record",
     "a method copies its receiver (`this`) on its first write: a second owner exists at the call; whether it is dead there "
     "((e) / take-put of opt/inplace.or) is not visible in the census"),
    (r"^opt/analysis\.(lo|los|instrUses|termUses)$", r"arraynew val|arr\.concat", "g", "array<usize> (0-1 elements)",
     "`instrUses` returns a fresh `usize[]` per operand / instruction (`lo(o)` = `[l]` or `[]`) only to be iterated: a visitor "
     "or an out-parameter array removes it; (c) would need inlining first"),
    (r"^opt/analysis\.ancestors$", r"arraynew val \[\]", "g", "array<usize>", "per-call worklists; reuse one buffer per function"),
    (r"^opt/analysis\.ancestors$", r"arraypush", "e", "COW copy of array<usize> (element of anc: usize[][])",
     "`anc[d].push(o)`: the inner array is an element of `anc` and so has a second owner while it is pushed to: every push "
     "copies it (quadratic in the list length). Take the element out of `anc`, push, put it back (opt/inplace.or take / put "
     "for array elements), or build the lists in a flat array with offsets"),
    (r"^opt/analysis\.ancestors$", r"arraynew ref \[\]", "g", "array<ref> (anc table)", "per-call table; reuse one buffer per function"),
    (r"^opt/rewrite\.empties$", r"arraynew ref", "g", "array<Instr[]> (empty)",
     "`RewritePlan(n)` makes n empty replacement lists for a block of n instructions although only the touched ones get "
     "one: keep the replacements sparse (a list of (index, instrs)) or share one immortal empty array"),
    (r"^opt/rewrite\.falses$", r"arraynew val", "g", "array<bool>", "the `hit` flags of every plan, even when nothing is touched: allocate at the first touch"),
    (r"^opt/rewrite\.RewritePlan\.constructor$", r"struct", "c", "class object RewritePlan (3 fields)",
     "built, filled and applied by one pass per block; with sparse replacements it is a local of the pass"),
    (r"^opt/rewrite\.BlockSink\.constructor$", r"struct", "c", "class object BlockSink (2 refs)", "a per-block builder that finish() turns into an MBlock"),
    (r"^opt/rewrite\.BlockSink\.constructor$", r"arraynew ref", "-", "array<Instr> / array<Span>", "become the instrs / spans of the new block: data"),
    (r"^opt/rewrite\.BlockSink\.finish$", r"struct", "-", "record MBlock {instrs, spans, term, termSpan}", "the rewritten block: data"),
    (r"^opt/unbox\.Unboxing\.scanInstr$", r"arraynew val", "g", "array<usize> (0-2 locals)",
     "`okUses` / `[s]`: the locals an instruction may use without poisoning them, per instruction; test each use inline "
     "against the instruction's allowed operands, no list"),
    (r"^opt/params\.liveAfter$", r"arraynew val", "g", "array<bool> (per-instruction liveness)",
     "one `bool[]` per (block, parameter), grown by push and read once; fill a reused buffer"),
    (r"^opt/params\.|^opt/chains\.|^opt/pairs\.|^opt/inplace\.|^opt/borrow\.|^opt/calls\.|^opt/prune\.", r"arraynew|task\.arrayWithCapacity|arr\.map", "g",
     "array (pass scratch list)", "scratch list of a pass (instruction lists, slot lists, ancestors): reuse a buffer or iterate without it"),
    (r"^opt/analysis\.edgeSrc$", r"struct", "a", None, "Option<usize> returned and matched at once"),
    (r"^opt/inplace\.takePutSlots$", r"arraynew ref", "c", "array<ref> (empty)", "per-function scratch list, usually stays empty"),
    # ---- self-compile: front end
    (r"^diag/diag\.(span|spanTo)$", r"struct", "a", "record Span {file, start, end} (3 scalars)",
     "3 scalars stored in every token / AST node. Remains boxed because the unboxing pass rejects a value stored in a slot of a "
     "boxed object (Token, Ident, Expr, Stmt, ...): it needs flattening of scalar-only records into their container (a layout "
     "change); cf. (a) for values that stay in registers"),
    (r"^syntax/lexer\.Lexer\.emit$", r"struct", "-", "record Token {kind, text, span, ...}",
     "the token stream is real data (lives until parsing ends); a region per compiler phase ((f)) would batch-free it"),
    (r"^syntax/lexer\.skipTrivia$", r"struct", "a", None, "`Ok(i)`: Result<usize, Diag> matched by the caller. Remains boxed because the Err variant carries a Diag reference "
     "(slots must be scalar in every variant); returning the position and leaving the error in `this.err` (g) removes it"),
    (r"^syntax/lexer\.Lexer\.punct$", r"str\.substring", "g", "string (punctuation token text)",
     "`src.substring(start, start + len)` per punctuation token: the text is one of a fixed set, use the literal"),
    (r"^syntax/lexer\.Lexer\.ident$", r"str\.substring", "-", "string (identifier text)", "the token's text: data"),
    (r"^syntax/parser\.Parser\.parseIdent$", r"struct tag0 \{l\d+, l\d+\}", "-", "record Ident {name, span}", "AST data"),
    (r"^syntax/parser\.Parser\.parseIdent$", r"struct tag0 \{l\d+\}", "a", None, "`Ok(Ident)` matched by the caller"),
    (r"^check/ops\.mk$", r"struct", "-", "record HExpr {kind, ty, span}", "typed AST: real data"),
    (r"^cemit/function\.lname$|^cemit/function\.CFunctionEmitter\.run$", r"strprepend l\d+, str#\d+$", "g", "string (\"l\" + n, \"B\" + n, \" \" + ..)",
     "`\"l\" + u(i)`: prepend allocates a new string (the number string from usizeToString is the second allocation per name); "
     "memoise `lname(i)` / `\"B\" + b` in a table (the same names are rebuilt for every operand), and append the pieces of a "
     "line to one builder instead of concatenating each"),
    (r"^cemit/function\.CFunctionEmitter\.run$", r"strappend|strprepend", "g", "string (one C line)", "per-line strings joined at the end; one builder"),
    (r"^cemit/(text|function|symbols|cemit)\.", r"strappend|strprepend|str\.substring", "g", "string",
     "C text assembled by concatenation (`ORIN_REF(${code})`, `name + \"(\"`, escapes): append into one line builder"),
    (r"^check/env\.originKey$", r"strappend", "g", "string (`${kind}:${id}`)",
     "a string key built per lookup of an instance: key the table by (kind, id) as an int (kind * 2^32 + id)"),
    (r"^lower/builder\.BlockBuilder\.emit$", r"makeunique|arraypush", "e", "COW copy of BlockBuilder and its cur / curSpans arrays",
     "`Lowerer.emit` calls `this.b.emit(i, this.sp)` as `dup this.b; call; setfield this.b`: the builder has two owners during "
     "the call, so EVERY emitted instruction copies the builder and both arrays (quadratic in the block length). The field's "
     "old value dies at the setfield: the take / put rewrite of opt/inplace.or (fix 1 of docs/benchmarks.md) does not fire "
     "here, apparently because a second field of `this` (`this.sp`) is an argument"),
    (r"^lower/state\.Locals\.fresh$", r"arraypush", "?", "COW copy of array<ref>", "`this.ls.push` copies the locals table: `table()` hands out `this.ls`, so the table has a second owner when a temporary is created later; whether that owner is still alive is not visible in the census"),
    # ---- self-compile: front end and lowering, by shape (reviewed per module; the remaining small sites follow these)
    (r"^lower/(values\.v\w+|lowerer\.Lowerer\.(localRef|projected))$", r"struct", "a", "record V {op, k, root, stable} / its Operand",
     "the value descriptor returned by `expr` and destructured by the caller at once. Remains boxed because it holds a "
     "reference (the Operand variant), which the unboxing pass does not accept; needs unboxing with reference slots (the "
     "copies then retain the payload instead of the box)"),
    (r"^(check/(stmt|expr|types)|lower/(lowerer|ops))\.", r"struct tag0 \{l\d+, l\d+\}|struct tag0 \{l\d+\}", "a",
     "returned pair (StmtRes / BlockRes / TyOut / Pair / HBlock)",
     "a result record built to return two values and destructured by the caller at once; reference fields (HStmt / HBlock / Env) "
     "keep it boxed today: needs unboxing with reference slots (or a multi-value return)", r"^(StmtRes|BlockRes|TyOut|Pair|HBlock)\b"),
    (r"^(syntax/parser|check/\w+|lower/\w+)\.", r"struct", "a", None,
     "Option / Result returned and matched at once by the caller. Remains boxed because its payload is a reference (Expr, "
     "HExpr, Ident, Type) and the Err variant carries a Diag: the unboxing pass takes scalar slots only; needs unboxing "
     "with reference slots", r"^(Some|Ok)\("),
    (r"^syntax/lexer\.", r"str\.substring|strappend|arraynew ref", "g", "string / list (string literal pieces)",
     "`src.substring(run, i)` pieces of a string literal collected in a list and joined: build the value in one buffer"),
    (r"^check/fnctx\.Scope\.bind$", r"struct", "-", "record Shadowed / Bind", "scope log entry and binding: stored in the scope's map / log"),
    (r"^check/fnctx\.Scope\.close$", r"arraypop", "a", None, "`this.log.pop()` Option, unwrapped at once"),
    (r"^(check/(fnctx|expr|env|stmt|types|pattern)|lower/(state|builder|lowerer)|opt/(opt|params)|verify/rules|\$array/map)\.", r"makeunique|arraypush", "e",
     "COW copy of the receiver / of its arrays",
     "a mutating method on a class-typed FIELD (`this.vis.set(..)`, `this.log.push(..)`, `this.locals.push(..)`, "
     "`this.vars.push(..)`): `dup field; call; setfield` leaves two owners during the call, so the first write copies the "
     "object and its arrays (also Map.set: keys, vals, live). The old value dies at the setfield: the take / put rewrite "
     "of opt/inplace.or should fire (see BlockBuilder.emit)"),
    (r"^(syntax/parser|check/\w+|lower/\w+|fuse/fuse|loader/\w+|mir/\w+|opt/\w+)\.", r"struct tag[1-9]\d*", "-", "variant node (AST / HIR / MIR)",
     "node of the tree or IR the pass produces (EIdent, XLocal, ECall, TGoto, ...): lives until the phase ends; a region per "
     "phase ((f)) would batch-free it", r"^(?!(Some|Ok|Err)\()"),
    (r"^(syntax/parser|check/\w+|lower/\w+|fuse/fuse|loader/\w+|mir/\w+|opt/\w+)\.", r"struct tag0", "-", "record (AST / HIR / MIR data)",
     "record of the tree or IR the pass produces (Stmt, Block, MBlock, MFunction, ...) or of a table: lives until the phase ends "
     "((f) per phase)", r"^(?!(Some|Ok|Err)\()"),
    (r"^(syntax/parser|check/\w+|lower/\w+|fuse/fuse|loader/\w+|mir/\w+)\.", r"arraynew ref \[\]|arraynew val \[\]|arraynew ref \[[^\]]+\]", "-",
     "list (children of a node / a table)",
     "built by push and then stored in the node it belongs to: real data (the empty header is paid once per list; a shared "
     "immortal empty array (f) would save it only for lists that stay empty)"),
    (r"^(check/\w+|lower/\w+|syntax/parser|\$array/array|\$std/strings|mir/\w+)\.", r"task\.arrayWithCapacity|arr\.map|arr\.slice|arr\.concat", "g",
     "array (map / slice result)", "intermediate array of a `map` / `slice` consumed once: fuse it into its consumer"),
    (r"^(\$array/array\.map|\$array/map\.(mapNew|buildTab)|verify/verify\.(initialIns|entryQueued|entryState|Fixpoint\.constructor)|opt/(unbox|rewrite)\.\w+)", r"arraynew|task\.arrayWithCapacity", "-",
     "array (result of a map / table storage / per-function setup)", "the result array of a `map`, the storage of a Map, or per-function tables: data"),
    (r"^(cemit/function|fuse/fuse|loader/path|check/\w+|lower/\w+|syntax/parser)\.", r"arraynew|task\.arrayWithCapacity|arr\.map|arr\.slice", "g",
     "array (temporary)", "short-lived argument / part list consumed once (`args.map(opC)`, `a.slice(0, n)`): join / emit directly"),
    (r"^(\$array/map|\$std/strings|verify/\w+|syntax/\w+|opt/\w+|loader/\w+|fuse/\w+|cemit/\w+)\.", r"struct tag0", "-", "record / class object (table, row, report)", "data or per-function pass state"),
    (r"^(fuse/fuse|loader/path)\.", r"strappend|strprepend|str\.substring", "g", "string", "name / path built by concatenation: build once at the use"),
    (r"^(check/\w+|lower/\w+|syntax/parser)\.", r"strappend|strprepend|str\.substring", "g", "string",
     "message / name built by concatenation: build once at the use, or key by an id"),
    (r"^(check/\w+|lower/\w+|syntax/parser)\.", r"struct", "-", "class object / record (table, scope, context)", "long-lived pass state"),
    # ---- sortedmap (B-tree arena) and the parallel stream pool
    (r"^\$stdlib/collections\.SortedMap\.release", r"arraynew|struct", "g", "IntNode {[], [], []} (a freed arena slot)",
     "`release` stores a fresh empty node (a record and three empty arrays) into the slot only to mark it free: the free list "
     "already records that; leave the old arrays in place (dropped at reuse) or truncate them"),
    (r"^\$stdlib/collections\.SortedMap\.alloc", r"struct", "-", "record IntNode {keys, vals, kids}", "the B-tree node: data"),
    (r"^\$stdlib/collections\.SortedMap\.splitChild", r"arr\.slice", "e", "array<int> (node half)",
     "the two halves of a split node are copied out with `slice`; the left half could stay in the old node's arrays "
     "(truncate in place, the old arrays are unique), only the right half is new", r"slice\(0,"),
    (r"^\$stdlib/collections\.SortedMap\.splitChild", r"arr\.slice|arraynew", "-", "array<int> (new right half)", "the new node's keys / vals: data"),
    (r"^\$stdlib/taskcore\.Ranges\.constructor$", r"struct", "c", "class object Ranges (4 fields)",
     "loaded from the pool's monitor words by `loadRanges`, advanced and stored back inside one critical section: scalar-"
     "replace it (as Ring / Ledger)"),
    (r"^\$stdlib/task\.loadRanges$", r"arraynew", "g", "array<usize> (lo / hi of the workers)",
     "two arrays rebuilt from the monitor words at every chunk grab: read the one worker's words directly"),
    (r"^\$stdlib/task\.poolWork", r"struct", "g", "record Done<R> {k, r}",
     "one record per processed chunk pushed into `out` and later ordered by `inOrder`: write the result into slot k of a "
     "preallocated result array instead"),
    (r"^main\.run\$par0$", r"struct", "a", "record (1 field) of the fused stage",
     "a one-field record per element in the fused filter / map / reduce body; scalar payload but it crosses the closure "
     "boundary (pinned), so unboxing rejects it"),
    (r"^\$std/strings\.strSplit$", r"arraynew", "-", "array<string> (the parts)", "the result"),
    (r"^\$stdlib/http\.fieldsText$", r"strappend", "g", "string (header line)", "as the part list above: append to one builder"),
    (r"^verify/(rules\.Transfer\.removeHole|verify\.(wellFormed|verifyFunction))$", r"arraynew|arr\.filter", "g", "array (filter result / empty issue list)",
     "`holes.filter(..)` copies the hole list to drop one entry (remove in place); the empty `errors` / `warnings` lists of a "
     "report that is usually clean could share one immortal empty array (f)"),
    (r"^http_server\.(route|text)$", r"struct|strappend", "-", "record Answer / body text", "the response being built: data"),
    # ---- std prelude and library
    (r"^\$std/numbers\.usizeToString$", r"strappend", "-", "string (decimal digits)",
     "the result (one allocation per call: the first append copies the immortal \"\" into a buffer of capacity 9, the other "
     "digits are appended in place). The cost is the per-digit loop, not allocations; the second string of `\"w\" + "
     "n.toString()` is counted at the concatenation, class (e)"),
    (r"^\$std/numbers\.strParseInt$", r"struct", "a", None, "`Some(acc)`: Option<int> matched by the caller"),
    (r"^\$std/strings\.strSplit$", r"str\.substring", "-", "string (split part)", "the parts are the result"),
    (r"^\$std/strings\.strJoin$", r"strappend", "-", "string (joined result)", "the result"),
    (r"^\$array/map\.mapGet", r"struct", "a", None, "`Map.get` returns Option<V>; unwrapped / matched at once"),
    (r"^\$array/map\.mapEntries", r"struct", "a", "record entry {key, value}", "entries built for iteration"),
    (r"^\$stdlib/http\.sliceString$", r"bytes\.toString", "-", "string (header name / value / token)",
     "the header names and values of the parsed request are its result; one allocation each since bytesToString"),
    (r"^\$stdlib/bytes\.Bytes\.constructor$", r"struct", "a", "class object Bytes {data, start, len} (view)",
     "a 3-field view created by `Bytes.slice` per chunk / line and dropped after the parse step: unbox the view (pass "
     "data/start/len) -- (c) where it does not leave the caller"),
    (r"^\$stdlib/bytes\.Bytes\.toArray$", r"arr\.slice", "g", "array<u8>",
     "`chunk.slice(w, we).toArray()` copies the bytes into a fresh u8[] only to scan them: index the view directly"),
    (r"^\$stdlib/http\.MessageParser\.feed$", r"arraynew val \[\]", "c", "array<u8> (empty)",
     "`let xs: u8[] = []` per feed call, replaced or dropped before return"),
    (r"^\$stdlib/http\.MessageParser\.feed$", r"struct tag1", "a", "variant Done(z, used)", "ParseResult returned and matched at once"),
    (r"^\$stdlib/http\.(Request|Response)Parser\.feed$", r"struct tag0 \{l\d+, l\d+\}", "a", "pair (in/out result rebuilt)",
     "`this.core.feed(chunk)` is an in/out call; opt/pairs.or rebuilds the {receiver, result} record at the call site because "
     "the result is matched through a borrow: scalar-replace it"),
    (r"^\$stdlib/http\.(Request|Response)Parser\.feed$", r"struct tag1", "a", "variant Done(request, used)",
     "ParseResult returned and matched at once by the caller"),
    (r"^\$stdlib/http\.MessageParser\.reset$", r"arraynew ref", "e", "array<ref> (empty)",
     "`this.hnames = []` etc. per message: the old (unique) arrays die right there -- truncate / reuse them"),
    (r"^\$stdlib/http\.Headers\.constructor$", r"struct", "-", "class object Headers", "part of the parsed request"),
    (r"^\$stdlib/http\.Headers\.get$", r"struct", "a", None, "`Some(this.values[i])`: Option<string> unwrapped by the caller"),
    (r"^\$stdlib/http\.(Request|Response|Status)\.constructor$", r"struct", "-", "class object", "the parsed message: real data"),
    (r"^\$stdlib/http\.(parseContentLength|methodFromToken|headersFromLists|makeResponse)$", r"struct", "a", None,
     "Option / Result returned and matched at once"),
    (r"^\$stdlib/http\.MessageParser\.doValue$", r"strappend l\d+, l\d+$", "g", "string (header value pieces)",
     "`this.acc + sliceString(..)` / `tok` concatenations when a value spans chunks; append into the accumulator in place"),
    (r"^\$stdlib/http\.MessageParser\.(doName|doMethod|doTarget)$", r"strappend", "g", "string", "as doValue"),
    (r"^\$stdlib/http\.MessageParser\.bodyBytes$", r"arraynew val", "-", "array<u8>", "the body is the result"),
    (r"^\$stdlib/bytes\.empty$", r"arraynew val", "g", "array<u8> (empty)",
     "`new Bytes([], 0, 0)` for every `empty()` (a fresh empty array and a view): callers that only need \"no body\" "
     "(bodyBytes, serveConnection) can skip it; one shared empty value needs (f) freeze"),
    (r"^\$stdlib/bytes\.ByteBuilder\.appendString$", r"string\.toBytes", "g", "array<u8> (temporary)",
     "`this.data.concat(stringToBytes(s))` makes a temporary u8[] per appended string: append the string's bytes directly "
     "(one runtime call, no temporary)"),
    (r"^\$stdlib/bytes\.ByteBuilder\.constructor$", r"", "-", None, "the response buffer"),
    (r"^\$stdlib/bytes\.fromString$", r"string\.toBytes", "-", "array<u8>", "the bytes are the result"),
    (r"^\$stdlib/http\.fieldsText$", r"arraynew ref", "g", "array<string> (parts)",
     "header lines collected into a string[] and then joined: append to one string / the ByteBuilder directly"),
    (r"^\$stdlib/http\.emptyHeaders$", r"arraynew ref", "a", "array<ref> (empty)", "shared immortal empty arrays"),
    (r"^\$stdlib/net\.recv$", r"net\.recv", "-", "Result<u8[], int> + array<u8>", "the received bytes are real data"),
    (r"^\$stdlib/net\.recv$", r"struct", "a", "variant Ok(bytes)", "Result<Bytes, NetError> matched at once"),
    (r"^\$stdlib/net\.sendFrom$", r"", "a", None, "Result<usize, int> matched at once"),
    (r"^\$stdlib/collections\.(PriorityQueue|SortedMap)\.", r"arraypop", "a", None, "`pop().unwrap()`: the Option dies at once"),
    (r"^\$stdlib/collections\.PriorityQueue\.pop", r"struct tag0 \{l\d+, l\d+\}", "a", "record Entry {priority, value}",
     "returned in Some(..) and destructured by the caller"),
    (r"^\$stdlib/collections\.", r"struct tag0 \{l\d+\}", "a", None, "Option returned and matched at once"),
    (r"^\$stdlib/collections\.SortedMap\.popFirst", r"struct tag0 \{l\d+, l\d+\}", "a", "record SortedEntry / pair",
     "returned in Some(..) and destructured by the caller"),
    (r"^\$stdlib/task\.putBox", r"struct", "g", "record Box<T> (1 field)",
     "a message is boxed in a one-field record, and the runtime moves it into a second box (its own row): two allocations per "
     "send; transfer a scalar payload without boxing (runtime API change)"),
    (r"^\$stdlib/task\.putBox", r"task\.transitPut", "g", "record (the runtime's transfer box)",
     "orin_rt_transfer_put re-boxes the sender's box for the receiving task (see the Box<T> row)"),
    (r"^\$stdlib/http\.MessageParser\.constructor$|^main\.(Reader|Q)\.constructor$", r"struct", "-", "class object (the parser / reader)",
     "long-lived object; its RC traffic is the dup / release around each method call (class d)"),
    (r"^lower/state\.Locals\.fresh$", r"struct", "-", "record MLocal {name, ty}", "the MIR declaration table: data"),
    (r"^\$stdlib/task\.Receiver\.recv", r"struct", "a", None, "`Some(v)` returned by recv and matched"),
    (r"^\$stdlib/taskcore\.Ring\.constructor$", r"struct", "c", "class object Ring (5 scalars)",
     "loaded from the channel monitor's words, changed and stored back inside one function: scalar-replace it"),
    (r"^\$stdlib/taskcore\.Ledger\.constructor$", r"struct", "c", "class object Ledger (3 fields)", "as Ring"),
    (r"^\$stdlib/task\.spawn", r"closure", "-", "closure", "the task body crosses to another thread"),
    (r"^\$stdlib/task\.spawn", r"struct tag0 \{l\d+, l\d+\}", "a", "pair (in/out result rebuilt)", "`lg.add()` result pair"),
    (r"^\$stdlib/task\.TaskHandle\.constructor", r"struct", "-", "class object TaskHandle", "returned to the caller"),
    # ---- benchmark programs
    (r"^main\.make$", r"struct", "f", "variant Node(Tree, Tree)",
     "the tree is built, checked and dropped per iteration: a region per iteration (bump allocate, free in one step); "
     "the long-lived tree is (f) freeze"),
    (r"^main\.qs$", r"arr\.concat", "e", "array<int>",
     "`qs(lo).concat(eq).concat(qs(hi))`: the left operand is a fresh unique array each time -- extend it in place"),
    (r"^main\.qs$", r"arraynew val", "-", "array<int>", "the partitions of the functional quicksort (inherent to the algorithm)"),
    (r"^main\.sortInts$", r"arraypop", "a", None, "`stack.pop()` Option unwrapped at once"),
    (r"^main\.main$", r"arraynew val \[l1(, l1)?\]", "c", "array<int> (1-2 elements)",
     "`a = a.concat([i])`: the literal argument is consumed by arrayextend at once (bounded, does not escape)"),
    (r"^main\.(main|build)$", r"strappend l\d+, l\d+$", "e", "string (\"w\" / \"item\" + n.toString())",
     "literal + number: the number string is fresh, unique and dies right there; prepend the literal into it instead of "
     "allocating a second string", r'^"[^"]*" \+ .*toString\(\)$'),
    (r"^main\.(main|build)$", r"strappend", "-", "string", "output lines"),
    (r"^main\.main$", r"str\.substring", "g", "string (temporary)", "`p.substring(4, ..)` only to parse it: parse from an offset"),
    (r"^main\.main$", r"struct tag0 \{l\d+, 1\}", "-", "record Entry {word, count}", "table entries: real data"),
    (r"^main\.main$", r"struct tag0 \{l\d+, l\d+\}", "a", "pair (in/out result rebuilt)",
     "the {receiver, result} record of an in/out call rebuilt at the call site: scalar-replace it"),
    (r"^http_server\.serveConnection$", r"struct tag0 \{l\d+, l\d+\}", "a", "pair (in/out result rebuilt)", "as above"),
    (r"^http_server\.", r"struct tag0 \{l\d+\}", "a", None, "Option matched at once"),
    (r"^http_server\.respond$", r"arraynew ref", "c", "array<string> (2 elements)", "header name / value lists passed on and dropped"),
    (r"^main\.spawnJoin\$closure0$", r"closure", "-", "closure", "the task body crosses to another thread"),
]

# Scalar arrays known to be u8[] (class b): the byte APIs of the std and the built-ins that make byte arrays.
U8_FUNCS = r"^\$stdlib/(bytes|http|net|utf8)\."
U8_MIR = r"string\.toBytes|net\.recv|arraypush l\d+, (true|false)$"  # the last: a bool[] (pushes of bool literals)

DEFAULT_CLASS = {"Option": "a", "Result": "a", "pair (in/out result rebuilt)": "a", "closure": "c", "interface box": "c"}


def mir_instr(mir, func, pos):
    f = mir["byname"].get(func) if mir else None
    m = re.match(r"b(\d+)\.(\d+)", pos or "")
    if not f or not m:
        return None, None, None
    b, k = int(m.group(1)), int(m.group(2))
    if b >= len(f["blocks"]) or k >= len(f["blocks"][b]):
        return f, b, None
    return f, b, k


def kind_of(s, mir):
    """The object kind a site allocates, from the runtime kind, the MIR instruction and the source text."""
    text = span_text(s["file"], s["start"], s["end"], limit=400)
    ins = s["mir"]
    rk = "string" if s["n_str"] else "array<ref>" if s["n_arr_ref"] else "array<scalar>" if s["n_arr_val"] else "record"
    if s["at_cow"] and s["allocs"] <= s["at_cow"] * 1.01 and re.search(r"makeunique|arraypush|arraypop", ins):
        return "COW copy of " + (rk if rk != "record" else "record(%d)" % s["last_nslots"])
    m = re.search(r"builtin ([\w.]+)\(", ins)
    if m and s["n_struct"]:
        if m.group(1) in OPTION_BUILTINS:
            return "Option"
        if m.group(1) in RESULT_BUILTINS:
            return "Result"
    if s["n_str"] or s["n_arr_val"] or s["n_arr_ref"]:
        return rk
    if "= closure " in ins:
        return "closure"
    if "= iface " in ins:
        return "interface box"
    if "= arraypop " in ins:
        return "Option"
    if re.match(r"^(Some)\(", text) or s["func"].startswith("$array/map.mapGet"):
        return "Option"
    if re.match(r"^(Ok|Err)\(", text) or (text.endswith("?") and s["last_tag"] == 1):
        return "Result"
    f, b, k = mir_instr(mir, s["func"], s["pos"])
    if f is not None and k and s["last_nslots"] == 2:
        prev = f["blocks"][b][k - 1]
        cm = re.match(r"^l(\d+) = call fn(\d+)\(", prev)
        sm = re.match(r"^l\d+ = struct tag0 \{l\d+, l(\d+)\}$", ins)
        if cm and sm and cm.group(1) == sm.group(1):
            g = mir["byidx"].get(int(cm.group(2)))
            if g and g["inout"]:
                return "pair (in/out result rebuilt)"
    m = re.match(r"^([A-Z]\w*)\s*(<[^{]*>)?\s*\{", text)
    if m:
        return "record %s (%d fields)" % (m.group(1), s["last_nslots"])
    m = re.match(r"^new ([A-Z]\w*)", text)
    if m or ".constructor" in s["func"]:
        name = m.group(1) if m else s["func"].split(".")[-2]
        return "class object %s (%d fields)" % (name, s["last_nslots"])
    m = re.match(r"^([A-Z]\w*)\(", text)
    if m:
        return "variant %s (%d fields)" % (m.group(1), s["last_nslots"])
    return "record (%d fields)" % s["last_nslots"]


def classify(s, mir):
    kind = kind_of(s, mir)
    text = span_text(s["file"], s["start"], s["end"], limit=400)
    for rule in RULES:
        fre, mre, cls, k2, note = rule[:5]
        # an optional 6th element: a regex the source text of the site must match
        if re.search(fre, s["func"]) and re.search(mre, s["mir"]) and (len(rule) < 6 or re.search(rule[5], text)):
            return (k2 or kind), cls, note, True
    return kind, DEFAULT_CLASS.get(kind, "?"), "", False


def site_key(s):
    return (s["func"], s["pos"], s["mir"])


def analyse(out, orinc=None):
    """Everything the report needs, per workload and aggregated."""
    data = {}
    for w in workloads(out):
        sites, pairs, calls, summ = load(out, w)
        mpath = os.path.join(out, w + ".mir")
        if not os.path.exists(mpath) and orinc:
            src = WORKLOAD_SRC.get(w, os.path.join("bench", w, "main.or"))
            save_mir(orinc, src, out, w)
        mir = parse_mir(mpath) if os.path.exists(mpath) else None
        names = load_names(out, w)
        bor = Borrow(mir) if mir else None
        cls_of, info = {}, {}
        for i, s in sites.items():
            kind, cls, note, reviewed = classify(s, mir)
            cls_of[i] = cls
            info[i] = (kind, cls, note, reviewed)
        dcand = set()
        if bor:
            for i, d in enumerate(names):
                if i == 0:
                    continue
                f, b, k = mir_instr(mir, d["func"], d["pos"])
                if f is not None and k is not None and RETAINING.match(f["blocks"][b][k]) and bor.candidate(f, b, k):
                    dcand.add(i)
        per = {c: {"allocs": 0, "bytes": 0, "rc": 0, "cow": 0, "bbytes": 0} for c, _, _ in CLASSES}
        packed = []  # (site, u8 typed?, buffer bytes) of scalar arrays whose freed instances all held values < 256
        for i, s in sites.items():
            c = cls_of[i]
            per[c]["allocs"] += s["allocs"]
            per[c]["bytes"] += s["bytes"] + s["grow_bytes"]
            per[c]["cow"] += s["at_cow"]
            if s["n_arr_val"] and s["arr_val_freed"] and s["arr_val_small"] == s["arr_val_freed"]:
                buf = max(0, s["bytes"] - 48 * s["allocs"]) + s["grow_bytes"]
                u8 = bool(re.search(U8_FUNCS, s["func"]) or re.search(U8_MIR, s["mir"]))
                packed.append((i, u8, buf))
                # (b) is a layout change: it removes bytes, never the allocation; counted only for arrays that stay (a site
                # whose allocation another class removes takes its bytes with it)
                if u8 and c in "-?f":
                    per["b"]["bbytes"] += buf * 7 // 8
        rc_total = summ["retains"] + summ["releases"]
        # Every RC operation is credited to at most one class (data: the joint (executing site, allocating site) counts):
        #  - f, g: the object is not created / not counted per object any more: all its operations go;
        #  - a, c on an object WITHOUT reference fields (strings, scalar arrays, scalar records): all its operations go;
        #  - a, c on an object WITH reference fields: copying the unboxed value retains its fields instead, so only the
        #    release that freed the box goes (credited once per freed object, below); its other operations are treated
        #    like those of any other object:
        #  - a retain at a borrow candidate (MIR analysis above) goes together with its release: 2 per retain, class d;
        #  - everything else stays ("rest").
        def no_refs(i):
            s = sites.get(i)
            if s is None:
                return False
            return s["n_arr_ref"] == 0 and (s["n_struct"] == 0 or s["last_refmask"] == 0)

        rc_cred = {c: 0 for c, _, _ in CLASSES}
        rc_site = {}  # site -> RC credited to its class (for the top tables)
        for at, of, ret, rel, cow in pairs:
            co = cls_of.get(of, "?")
            if co in "fg" or (co in "ac" and no_refs(of)):
                rc_cred[co] += ret + rel
                rc_site[of] = rc_site.get(of, 0) + ret + rel
            elif at in dcand:
                rc_cred["d"] += 2 * ret
                rc_site[at] = rc_site.get(at, 0) + 2 * ret
        for i, s in sites.items():
            if cls_of[i] in "ac" and not no_refs(i):
                n = min(s["frees"], s["of_releases"])
                rc_cred[cls_of[i]] += n
                rc_site[i] = rc_site.get(i, 0) + n
        credited = sum(rc_cred.values())
        for c in per:
            per[c]["rc"] = rc_cred[c]
        per["rest"] = {"allocs": 0, "bytes": 0, "cow": 0, "bbytes": 0, "rc": max(0, rc_total - credited)}
        data[w] = {"sites": sites, "summ": summ, "info": info, "per": per, "dcand": dcand, "rc_total": rc_total,
                   "rc_site": rc_site, "names": names, "calls": calls, "packed": packed,
                   "census_allocs": sum(s["allocs"] for s in sites.values())}
    return data


WORKLOAD_SRC = {"http_server": "examples/http_server.or", "selfcompile": "compiler/main.or"}


def cmd_review(a):
    """Top sites of each workload with their kind and class (to review the RULES)."""
    data = analyse(os.path.abspath(a.out), a.orinc)
    for w, d in data.items():
        print("== %s  allocs %d  rc %d  d-candidates %d" % (w, d["summ"]["alloc_total"], d["rc_total"], len(d["dcand"])))
        for s in sorted(d["sites"].values(), key=lambda s: s["allocs"], reverse=True)[:a.n]:
            if s["allocs"] == 0:
                break
            kind, cls, note, rev = d["info"][s["id"]]
            ln, _ = line_col(s["file"], s["start"])
            print("  %10d %s%s %-34s %s %s:%d | %s" % (s["allocs"], cls, "" if rev else "*", kind[:34], s["func"], s["file"], ln,
                                                     span_text(s["file"], s["start"], s["end"], 50)))
        dsum = sorted(((d["rc_site"].get(i, 0), i) for i in d["dcand"]), reverse=True)[:a.n // 2]
        for n, i in dsum:
            if n == 0:
                break
            nm = d["names"][i]
            ln, _ = line_col(nm["file"], nm["start"])
            print("  d %10d %s %s:%d | %s | %s" % (n, nm["func"], nm["file"], ln, nm["mir"], span_text(nm["file"], nm["start"], nm["end"], 50)))


# ---------------------------------------------------------------- report

def fmt(n):
    return "{:,}".format(int(n))


def pct(n, d):
    return "%.1f%%" % (100.0 * n / d) if d else "-"


def mb(n):
    return "%.1f MB" % (n / 1e6) if n >= 1e5 else "%.0f kB" % (n / 1e3) if n >= 1e3 else "%d B" % n


def wlist(ws):
    """The workloads of a site, most allocations first: at most three, then "+N more"."""
    ws = sorted(ws, key=lambda x: x[1], reverse=True)
    names = [w for w, n in ws if n] or [w for w, _ in ws]
    return ", ".join(names[:3]) + (" +%d more" % (len(names) - 3) if len(names) > 3 else "")


def loc_of(s):
    ln, _ = line_col(s["file"], s["start"])
    f = s["file"].lstrip("$")
    return "%s:%d" % (f, ln) if ln else f


ORDER = ["selfcompile", "http_server", "http_parse", "tasks", "bintrees", "sortedmap", "pqueue", "mapfreq", "wordfreq", "strings",
         "qsort_func", "qsort_inplace", "appends", "mutres", "bytesstr", "sieve", "nbody", "fib"]


def build_report(data):
    ws = [w for w in ORDER if w in data] + sorted(w for w in data if w not in ORDER)
    L = []
    T = lambda *cells: L.append("| " + " | ".join(str(c) for c in cells) + " |")
    allocs_all = sum(data[w]["summ"]["alloc_total"] for w in ws)
    rc_all = sum(data[w]["rc_total"] for w in ws)
    bytes_all = sum(sum(s["bytes"] + s["grow_bytes"] for s in data[w]["sites"].values()) for w in ws)

    # ---- per workload totals
    L.append("## Workloads\n")
    L.append("Totals of one run each (`ORIN_STATS=sites`; the summary counters of the same run). *bytes*: object plus initial buffer "
             "plus buffer growth, in the layout of a normal build. The census column checks that the per-site allocations add up "
             "to the runtime's own total.\n")
    T("workload", "allocations", "bytes", "retains", "releases", "COW copies", "census = total")
    T(*["---"] + ["---:"] * 6)
    for w in ws:
        d = data[w]
        sm = d["summ"]
        b = sum(s["bytes"] + s["grow_bytes"] for s in d["sites"].values())
        name = w + (" (%s requests)" % fmt(sm["_requests"]) if "_requests" in sm else "")
        T(name, fmt(sm["alloc_total"]), mb(b), fmt(sm["retains"]), fmt(sm["releases"]), fmt(sm["cow_copies"]),
          "yes" if d["census_allocs"] == sm["alloc_total"] else "NO (%s)" % fmt(d["census_allocs"]))
    T("**all**", "**%s**" % fmt(allocs_all), "**%s**" % mb(bytes_all), "**%s**" % fmt(sum(data[w]["summ"]["retains"] for w in ws)),
      "**%s**" % fmt(sum(data[w]["summ"]["releases"] for w in ws)), "**%s**" % fmt(sum(data[w]["summ"]["cow_copies"] for w in ws)), "")
    L.append("")

    # ---- per class aggregate
    tot = {c: {"allocs": 0, "rc": 0, "bbytes": 0, "bytes": 0} for c, _, _ in CLASSES + [("rest", "", "")]}
    shares_a = {c: [] for c in tot}
    shares_r = {c: [] for c in tot}
    for w in ws:
        d = data[w]
        A, R = d["summ"]["alloc_total"], d["rc_total"]
        for c in tot:
            p = d["per"][c]
            tot[c]["allocs"] += p["allocs"]
            tot[c]["rc"] += p["rc"]
            tot[c]["bbytes"] += p["bbytes"]
            tot[c]["bytes"] += p["bytes"]
            if A >= 10000:
                shares_a[c].append(p["allocs"] / A)
            if R >= 10000:
                shares_r[c].append(p["rc"] / R)
    mean = lambda xs: sum(xs) / len(xs) if xs else 0.0
    L.append("## Ranking by transformation (ADR-0038)\n")
    L.append("Each allocation site is attributed to the one transformation that would remove it (classes below; reviewed decisions "
             "in `RULES` of tools/alloc_census.py, kind defaults otherwise). *Allocations*: objects that would no longer be "
             "heap-allocated. *RC ops*: retains + releases that would disappear (crediting rules in the method section; each "
             "operation is credited to at most one class). *Raw* sums all workloads, so the self-compile (97% of all RC "
             "operations) and bintrees (44% of all allocations) dominate it; *mean* weighs every workload equally (workloads with "
             "at least 10,000 allocations, resp. RC operations).\n")
    T("class", "transformation", "allocations removed (raw)", "share", "mean share per workload", "RC ops removed (raw)", "share",
      "mean share per workload", "bytes not allocated")
    T(*["---", "---"] + ["---:"] * 7)
    for c, n, _ in CLASSES:
        t = tot[c]
        removed_bytes = t["bbytes"] if c == "b" else t["bytes"] if c in "aceg" else 0
        T("(%s)" % c if c not in "-?" else c, n, fmt(t["allocs"]), pct(t["allocs"], allocs_all), "%.1f%%" % (100 * mean(shares_a[c])),
          fmt(t["rc"]), pct(t["rc"], rc_all), "%.1f%%" % (100 * mean(shares_r[c])),
          "%s (%s)" % (mb(removed_bytes), pct(removed_bytes, bytes_all)) if c not in "-?" else "")
    t = tot["rest"]
    T("", "RC operations not removed by any class", "", "", "", fmt(t["rc"]), pct(t["rc"], rc_all), "%.1f%%" % (100 * mean(shares_r["rest"])), "")
    L.append("")
    L.append("*Bytes not allocated*: the bytes of the objects a class removes; for (b) the 7/8 of the buffers of `u8[]` arrays "
             "that stay allocated; (f) keeps the bytes (a region still holds them) and removes the per-object frees and RC.\n")
    L.append("Per workload (share of the workload's allocations / of its RC operations; `-` where the workload has fewer than "
             "1,000 of them):\n")
    T("workload", *["(%s)" % c if c not in "-?" else c for c, _, _ in CLASSES])
    T(*["---"] + ["---:"] * len(CLASSES))
    for w in ws:
        d = data[w]
        A, R = d["summ"]["alloc_total"], d["rc_total"]
        if A < 1000 and R < 1000:
            continue
        T(w, *["%s / %s" % (pct(d["per"][c]["allocs"], A) if A >= 1000 else "-", pct(d["per"][c]["rc"], R) if R >= 1000 else "-")
               for c, _, _ in CLASSES])
    L.append("")

    # ---- by object kind
    def category(kind, func):
        if func.startswith("$array/map.") and not kind.startswith(("Option", "Result")):
            return "map (internal arrays and entries)"
        for pre, cat in (("Option", "Option"), ("Result", "Result"), ("pair", "pair (in/out result rebuilt)"),
                         ("closure", "closure"), ("interface", "interface box"), ("COW copy", "COW copy"),
                         ("string", "string"), ("array<ref>", "array (reference elements)"), ("record (the runtime", "task transfer box (runtime)"),
                         ("record", "record / variant"), ("variant", "record / variant"), ("class object", "class object")):
            if kind.startswith(pre):
                return cat
        if kind.startswith("array"):
            return "array (scalar elements)"
        return "record / variant"
    kinds = {}
    for w in ws:
        d = data[w]
        for i, s in d["sites"].items():
            if not s["allocs"]:
                continue
            k = category(d["info"][i][0], s["func"])
            e = kinds.setdefault(k, {"allocs": 0, "bytes": 0, "rc": 0, "ws": {}})
            e["allocs"] += s["allocs"]
            e["bytes"] += s["bytes"] + s["grow_bytes"]
            e["rc"] += s["of_retains"] + s["of_releases"]
            e["ws"][w] = e["ws"].get(w, 0) + s["allocs"]
    L.append("## Allocations by object kind\n")
    T("kind", "allocations", "share", "bytes", "RC on these objects", "mostly in")
    T("---", "---:", "---:", "---:", "---:", "---")
    for k, e in sorted(kinds.items(), key=lambda kv: kv[1]["allocs"], reverse=True):
        T(k, fmt(e["allocs"]), pct(e["allocs"], allocs_all), mb(e["bytes"]), fmt(e["rc"]), wlist(list(e["ws"].items())))
    L.append("")

    # ---- packed arrays
    L.append("## Packed arrays (b)\n")
    L.append("Scalar arrays every freed instance of which held only values below 256. *u8[]*: the array is a `u8[]` by type "
             "(the byte APIs of the std); the others are `int[]` / `usize[]` whose values happened to be small: packing them "
             "needs a proved range (ADR-0038 §3). *Bytes*: buffer bytes allocated there (8 per element today).\n")
    T("workload", "site", "u8[] / bool[] by type", "arrays", "buffer bytes", "saved by 1-byte elements", "class of the allocation")
    T("---", "---", "---", "---:", "---:", "---:", "---")
    rows = []
    for w in ws:
        d = data[w]
        for i, u8, buf in d["packed"]:
            rows.append((buf, w, d["sites"][i], u8, d["info"][i]))
    for buf, w, s, u8, info in sorted(rows, key=lambda r: r[0], reverse=True)[:12]:
        T(w, "`%s` %s `%s`" % (s["func"].lstrip("$"), loc_of(s), s["mir"]), "yes" if u8 else "no (range proof)", fmt(s["n_arr_val"]), mb(buf),
          mb(buf * 7 // 8), ("(%s)" % info[1] if info[1] not in "-?" else info[1]))
    L.append("")

    # ---- top sites overall
    agg = {}
    for w in ws:
        d = data[w]
        for i, s in d["sites"].items():
            if s["allocs"] == 0:
                continue
            k = site_key(s)
            e = agg.setdefault(k, {"s": s, "allocs": 0, "bytes": 0, "objrc": 0, "cred": 0, "ws": [], "info": d["info"][i]})
            e["allocs"] += s["allocs"]
            e["bytes"] += s["bytes"] + s["grow_bytes"]
            e["objrc"] += s["of_retains"] + s["of_releases"]
            e["cred"] += d["rc_site"].get(i, 0)
            e["ws"].append((w, s["allocs"]))
    top = sorted(agg.values(), key=lambda e: e["allocs"], reverse=True)
    L.append("## Top 20 allocation sites (all workloads)\n")
    L.append("Sites are MIR instructions (`function` + block.instruction); the same std function compiled into several workloads "
             "is one row. *RC on its objects*: retains + releases the objects allocated there received anywhere. A `*` after the "
             "class marks a kind default rather than a reviewed decision.\n")
    T("#", "site", "kind", "allocations", "bytes", "RC on its objects", "class", "workloads", "why")
    T("---:", "---", "---", "---:", "---:", "---:", "---", "---", "---")
    for n, e in enumerate(top[:20], 1):
        s = e["s"]
        kind, cls, note, rev = e["info"]
        T(n, "`%s` %s" % (s["func"].lstrip("$"), loc_of(s)), kind, fmt(e["allocs"]), mb(e["bytes"]), fmt(e["objrc"]),
          "(%s)%s" % (cls, "" if rev else "*") if cls not in "-?" else cls + ("" if rev else "*"), wlist(e["ws"]),
          note.replace("|", "\\|"))
    L.append("")

    # ---- top sites per workload
    L.append("## Top 5 allocation sites per workload\n")
    T("workload", "site", "kind", "allocations", "share", "class")
    T("---", "---", "---", "---:", "---:", "---")
    for w in ws:
        d = data[w]
        A = d["summ"]["alloc_total"]
        if A < 1000:
            continue
        for s in sorted(d["sites"].values(), key=lambda s: s["allocs"], reverse=True)[:5]:
            kind, cls, note, rev = d["info"][s["id"]]
            T(w, "`%s` %s" % (s["func"].lstrip("$"), loc_of(s)), kind, fmt(s["allocs"]), pct(s["allocs"], A),
              ("(%s)" % cls if cls not in "-?" else cls) + ("" if rev else "*"))
    L.append("")

    # ---- RC: borrow candidates and the objects with most RC
    L.append("## Top RC sites\n")
    L.append("Retains at borrow candidates (class d: the retained value is only read before its release, MIR analysis), and the "
             "allocation sites whose objects receive the most RC operations.\n")
    T("workload", "retain site", "MIR", "RC ops removed (2 x retains)")
    T("---", "---", "---", "---:")
    rows = []
    for w in ws:
        d = data[w]
        for i in d["dcand"]:
            n = d["rc_site"].get(i, 0)
            if n:
                rows.append((n, w, d["names"][i]))
    for n, w, nm in sorted(rows, key=lambda r: r[0], reverse=True)[:15]:
        T(w, "`%s` %s" % (nm["func"].lstrip("$"), loc_of(nm)), "`%s`" % nm["mir"], fmt(n))
    L.append("")
    T("workload", "allocation site", "kind", "objects", "retains + releases on them", "per object", "class")
    T("---", "---", "---", "---:", "---:", "---:", "---")
    rows = []
    for w in ws:
        d = data[w]
        for s in d["sites"].values():
            if s["allocs"]:
                rows.append((s["of_retains"] + s["of_releases"], w, s, d["info"][s["id"]]))
    for n, w, s, info in sorted(rows, key=lambda r: r[0], reverse=True)[:12]:
        T(w, "`%s` %s" % (s["func"].lstrip("$"), loc_of(s)), info[0], fmt(s["allocs"]), fmt(n), "%.1f" % (n / s["allocs"]),
          ("(%s)" % info[1] if info[1] not in "-?" else info[1]))
    L.append("")

    # ---- COW
    L.append("## COW copies\n")
    T("workload", "site", "copies", "allocations there", "class")
    T("---", "---", "---:", "---:", "---")
    rows = []
    for w in ws:
        d = data[w]
        for s in d["sites"].values():
            if s["at_cow"]:
                rows.append((s["at_cow"], w, s, d["info"][s["id"]]))
    for n, w, s, info in sorted(rows, key=lambda r: r[0], reverse=True)[:10]:
        T(w, "`%s` %s `%s`" % (s["func"].lstrip("$"), loc_of(s), s["mir"]), fmt(n), fmt(s["allocs"]),
          ("(%s)" % info[1] if info[1] not in "-?" else info[1]))
    L.append("")
    return "\n".join(L), {"allocs_all": allocs_all, "rc_all": rc_all, "tot": tot, "top": top, "ws": ws,
                          "shares_a": {c: mean(v) for c, v in shares_a.items()}, "shares_r": {c: mean(v) for c, v in shares_r.items()}}


def cmd_report(a):
    out = os.path.abspath(a.out)
    data = analyse(out, a.orinc)
    body, agg = build_report(data)
    # The hand-written parts of the report stay; only the part between the markers is regenerated.
    begin, end = "<!-- generated by tools/alloc_census.py report: begin -->\n", "<!-- generated: end -->\n"
    path = os.path.join(ROOT, a.md)
    old = open(path).read() if os.path.exists(path) else "# Allocation census\n\n" + begin + end
    if begin not in old or end not in old:
        raise SystemExit("%s has no generated-section markers" % a.md)
    text = old[:old.index(begin) + len(begin)] + "\n" + body + "\n" + old[old.index(end):]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)
    js = {w: {"summary": data[w]["summ"], "per_class": data[w]["per"]} for w in data}
    js["_all"] = {"allocations": agg["allocs_all"], "rc": agg["rc_all"], "per_class": agg["tot"],
                  "mean_share_allocs": agg["shares_a"], "mean_share_rc": agg["shares_r"],
                  "top": [{"func": e["s"]["func"], "pos": e["s"]["pos"], "loc": loc_of(e["s"]), "kind": e["info"][0], "class": e["info"][1],
                           "allocs": e["allocs"], "bytes": e["bytes"], "workloads": dict(e["ws"])} for e in agg["top"][:50]]}
    os.makedirs(os.path.dirname(os.path.join(ROOT, a.json)), exist_ok=True)
    json.dump(js, open(os.path.join(ROOT, a.json), "w"), indent=1)
    print("wrote %s and %s" % (a.md, a.json))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run")
    r.add_argument("--orinc", default="build/bootstrap/orin2")
    r.add_argument("--out", default="build/census")
    r.add_argument("--only", default="")
    r.add_argument("--no-http", action="store_true")
    r.add_argument("--no-selfcompile", action="store_true")
    i = sp.add_parser("identity")
    i.add_argument("base")
    i.add_argument("new")
    i.add_argument("--out", default="build/census/identity")
    i.add_argument("--jobs", type=int, default=3)
    i.add_argument("--compiler-src", default="compiler/main.or")
    t = sp.add_parser("top")
    t.add_argument("--out", default="build/census")
    t.add_argument("--only", default="")
    t.add_argument("--by", default="alloc", choices=["alloc", "rc", "of"])
    t.add_argument("-n", type=int, default=25)
    t.add_argument("--callers", type=int, default=0)
    v = sp.add_parser("review")
    v.add_argument("--out", default="build/census")
    v.add_argument("--orinc", default="build/bootstrap/orin2")
    v.add_argument("-n", type=int, default=30)
    p = sp.add_parser("report")
    p.add_argument("--out", default="build/census")
    p.add_argument("--md", default="docs/perf/alloc-census.md")
    p.add_argument("--json", default="build/census/census.json")
    p.add_argument("--orinc", default="build/bootstrap/orin2")
    a = ap.parse_args()
    {"run": cmd_run, "identity": cmd_identity, "report": cmd_report, "top": cmd_top, "review": cmd_review}[a.cmd](a)


if __name__ == "__main__":
    main()
