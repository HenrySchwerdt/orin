#!/usr/bin/env python3
"""Mutation corpus for the MIR ownership verifier (compiler/verify).

Takes the MIR (`orin mir`, optimised, i.e. what the verifier sees in every compile) of the
conformance programs, injects ownership bugs into single functions and checks the verifier's
reaction through the batch driver compiler/tests/verify_text.or.

Per mutated function the program is verified with every *other* function replaced by a stub that
keeps its signature (so calls stay well-formed) and traps. The verifier is intraprocedural, so the
result for the mutated function is unchanged; the stubs only make a mutant cost ~1 ms.

Mutation classes (id: injected bug -> required reaction)
  drop-release        delete `release x`                          -> a leak WARNING (or an error)
  extra-release       duplicate `release x`                       -> ERROR
  use-after-release   read x right after `release x`              -> ERROR
  use-after-move      read s right after `d = move s`             -> ERROR
  use-after-consume   read y right after a struct consumed it     -> ERROR
  store-shared-dup    `t = dup x` before a store/take/put on x    -> ERROR (x no longer Unique)
  store-shared-alias  store through `t = borrow x` instead of x   -> ERROR (Borrowed is not Unique)
  drop-makeunique     delete `makeunique x` before a store on x  -> ERROR (x only Owned)
  release-borrowed    `release d` right after d = borrow/getfield -> ERROR
  release-param       `release p` for a borrowed parameter p      -> ERROR
  move-param          `t = move p` for a borrowed parameter p     -> ERROR
  drop-dup            delete `d = dup x`                          -> ERROR (d dead at its later use)
  extra-dup           `t = dup x` before `release x`, t unused    -> a leak WARNING (or an error)
  inout-drop-receiver delete `l0 = move ..` in an inout function  -> ERROR (l0 must hold the receiver at return)
  inout-release-receiver `release l0` before a return of an inout function -> ERROR (same)

A mutant that is accepted without a new warning is a SURVIVOR, a finding, unless it is one of the
explicitly classified BENIGN cases below (each has a precise, local reason). A mutant that is
rejected, but without the error message of the injected bug, is reported as WRONG-REASON (the
mutation did not test what it claims). Leaks are only warnings in the verifier (docs/mir.md), so
"drop a release" is required to warn, not to be rejected. The run fails on any survivor or
wrong-reason mutant that is not listed in KNOWN.

Usage: python3 tools/mutate_mir.py [--orinc build/bootstrap/orin2] [--limit N] [-v]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Known surviving mutants that are real verifier findings: {(class, function name): explanation}.
KNOWN = {}

# ---------------------------------------------------------------- MIR text model


class Func:
    def __init__(self, header, locals_, blocks):
        self.header = header          # "fn3 name (params 1, owned l0) -> ref"
        self.locals = locals_         # list of (name, type)
        self.blocks = blocks          # list of [label, [instr lines], terminator line]
        m = re.match(r"fn\d+ (.*) \(params (\d+)(?:, owned ([l0-9 ]+))?(, inout)?\) -> (\w+)$", header)
        self.name = m.group(1)
        self.nparams = int(m.group(2))
        self.owned = set(int(x[1:]) for x in (m.group(3) or "").split())
        self.inout = bool(m.group(4))     # v1.10: parameter 0 is handed back to the caller at every return

    def key(self):
        return self.name + "\n" + self.render(normalise=True)

    def render(self, normalise=False):
        h = self.header
        if normalise:
            h = re.sub(r"^fn\d+", "fnN", h)
        out = [h, "  locals: " + " ".join("%s:%s" % lt for lt in self.locals)]
        for label, ins, term in self.blocks:
            out.append("  %s:" % label)
            out += ["    " + x for x in ins]
            out.append("    " + term)
        text = "\n".join(out) + "\n"
        return re.sub(r"fn\d+\(", "fnN(", text) if normalise else text

    def stub(self):
        return "%s\n  locals: %s\n  b0:\n    trap \"stub\"\n" % (
            self.header, " ".join("%s:%s" % lt for lt in self.locals))

    def clone(self):
        return Func(self.header, list(self.locals), [[b[0], list(b[1]), b[2]] for b in self.blocks])

    def new_local(self, ty="ref"):
        self.locals.append(("l%d" % len(self.locals), ty))
        return len(self.locals) - 1

    def is_ref(self, i):
        return self.locals[i][1] == "ref"


def parse(text):
    """-> (prefix text up to and including `main = ..`, [Func])"""
    prefix, funcs = [], []
    cur = None
    seen_main = False
    for line in text.split("\n"):
        s = line.strip()
        if not seen_main:
            prefix.append(line)
            if s.startswith("main = fn"):
                seen_main = True
            continue
        if not s:
            continue
        if re.match(r"fn\d+ ", s) and " (params " in s:
            cur = Func(s, [], [])
            funcs.append(cur)
        elif s.startswith("locals:"):
            cur.locals = [tuple(w.split(":")) for w in s[7:].split()]
        elif re.fullmatch(r"b\d+:", s):
            cur.blocks.append([s[:-1], [], None])
        elif re.match(r"(goto |branch |switch |return|trap )", s):
            cur.blocks[-1][2] = s
        else:
            cur.blocks[-1][1].append(s)
    return "\n".join(prefix) + "\n", funcs


def toks(line):
    return [int(x) for x in re.findall(r"\bl(\d+)\b", line)]


def dest(line):
    m = re.match(r"l(\d+) = ", line)
    return int(m.group(1)) if m else None


def op(line):
    m = re.match(r"(?:l\d+ = )?(\S+)", line)
    return m.group(1)


STORES = ("setfield", "putfield", "arrayset", "arrayput")
TAKES = ("takefield", "arraytake")


def store_obj(line):
    """Local that must be Unique for a store/take/put instruction, else None."""
    w = op(line)
    t = toks(line)
    if w in STORES:
        return t[0]
    if w in TAKES:
        return t[1]
    return None


def replace_obj(line, old, new):
    """Replace the object operand of a store/take/put line (first occurrence after the dest)."""
    w = op(line)
    if w in STORES:
        return re.sub(r"\bl%d\b" % old, "l%d" % new, line, count=1)
    d = re.match(r"(l\d+ = \S+ )(.*)", line)
    return d.group(1) + re.sub(r"\bl%d\b" % old, "l%d" % new, d.group(2), count=1)


# ---------------------------------------------------------------- mutation sites

class Mut:
    def __init__(self, cls, f, loc, desc, benign, needle, expect):
        self.cls, self.f, self.desc, self.benign, self.needle, self.expect = cls, f, desc, benign, needle, expect
        self.bi, self.ii = loc


def defs_of(f, x):
    out = []
    for _, ins, _t in f.blocks:
        for line in ins:
            if dest(line) == x:
                out.append(line)
    return out


_RD = {}


def reach_defs(f):
    """In-state per block of the reaching-definitions analysis: {local: {(block, index) | 'param'}}."""
    key = id(f)
    if key in _RD:
        return _RD[key]
    ins = [None] * len(f.blocks)
    ins[0] = {p: {"param"} for p in range(f.nparams)}
    work = [0]
    while work:
        b = work.pop()
        cur = {k: set(v) for k, v in ins[b].items()}
        for i, line in enumerate(f.blocks[b][1]):
            d = dest(line)
            if d is not None:
                cur[d] = {(b, i)}
        for s2 in succs(f.blocks[b][2]):
            if ins[s2] is None:
                ins[s2] = {k: set(v) for k, v in cur.items()}
                work.append(s2)
            else:
                ch = False
                for k, v in cur.items():
                    old = ins[s2].setdefault(k, set())
                    if not v <= old:
                        old |= v
                        ch = True
                if ch:
                    work.append(s2)
    _RD.clear()
    _RD[key] = ins
    return ins


def defs_at(f, bi, ii, x):
    cur = None
    st = reach_defs(f)[bi]
    if st is None:
        return set()
    cur = set(st.get(x, set()))
    for i, line in enumerate(f.blocks[bi][1][:ii]):
        if dest(line) == x:
            cur = {(bi, i)}
    return cur


def imm_at(f, bi, ii, x, seen=None):
    """At (bi, ii) every reaching definition of x is an immortal (`copy str#..`, `nullary`, or a
    move of such a value): x holds no counted reference, so dropping its release is not a leak."""
    seen = seen or set()
    if (bi, ii, x) in seen:
        return True
    seen = seen | {(bi, ii, x)}
    ds = defs_at(f, bi, ii, x)
    if not ds or "param" in ds:
        return False
    for (b, i) in ds:
        line = f.blocks[b][1][i]
        if re.match(r"l\d+ = (copy str#|nullary )", line):
            continue
        m = re.match(r"l\d+ = move l(\d+)$", line)
        if m and imm_at(f, b, i, int(m.group(1)), seen):
            continue
        return False
    return True


def succs(term):
    return [int(x) for x in re.findall(r"\bb(\d+)\b", term)] if not term.startswith(("return", "trap")) else []


def reaches_return(f, bi):
    """Some path from block bi reaches a `return` (a leak is only reported at returns)."""
    seen, work = set(), [bi]
    while work:
        b = work.pop()
        if b in seen:
            continue
        seen.add(b)
        if f.blocks[b][2].startswith("return"):
            return True
        work += succs(f.blocks[b][2])
    return False


# Independent, deliberately conservative "definitely Unique" dataflow (not the verifier's rules):
# a local is Unique after struct/arraynew/closure/makeunique and after a move of a Unique local;
# every other mention that is not a plain read or an in-place store loses it; join = intersection.
KEEP_READS = ("getfield", "arrayget", "tag")


def uniq_transfer(f, U, line):
    w, d, t = op(line), dest(line), toks(line)
    U = set(U)
    keep = set()
    if w in ("call", "builtin", "callind") and (d is None or not f.is_ref(d)):
        # a call with no result or a scalar result cannot return an alias of its (borrowed) arguments
        keep = set(t) - ({d} if d is not None else set())
    if w in STORES:
        keep = {t[0]}
    elif w in TAKES:
        keep = {t[1]}
    elif w in KEEP_READS:
        keep = set(t[1:])
    elif w == "makeunique":
        keep = {t[0]}
    was = (t[1] in U) if w == "move" and len(t) > 1 else False
    U -= set(t) - keep
    if d is not None:
        U.discard(d)
    if w in ("struct", "arraynew", "closure") and d is not None:
        U.add(d)
    if w == "makeunique":
        U.add(t[0])
    if w == "move" and was:
        U.add(d)
    return U


def uniq_states(f):
    """In-state of every block (None = unreachable)."""
    ins = [None] * len(f.blocks)
    ins[0] = set()
    work = [0]
    while work:
        b = work.pop()
        U = ins[b]
        for line in f.blocks[b][1]:
            U = uniq_transfer(f, U, line)
        for s2 in succs(f.blocks[b][2]):
            new = set(U) if ins[s2] is None else ins[s2] & U
            if ins[s2] is None or new != ins[s2]:
                ins[s2] = new
                work.append(s2)
    return ins


def certainly_unique(f, bi, ii, x, cache={}):
    key = id(f)
    if key not in cache:
        cache.clear()
        cache[key] = uniq_states(f)
    U = cache[key][bi]
    if U is None:
        return False
    for line in f.blocks[bi][1][:ii]:
        U = uniq_transfer(f, U, line)
    return x in U


def ends_in_trap(f, bi):
    return not reaches_return(f, bi)


def mentions_after(f, bi, ii, x):
    """First mention of x after (bi, ii) in the same block: 'def', 'use' or None (then it may
    still be used in a successor block)."""
    for line in f.blocks[bi][1][ii + 1:]:
        if dest(line) == x:
            return "def"
        if x in toks(line):
            return "use"
    return None


def sites(f):
    out = []
    for bi, (label, ins, term) in enumerate(f.blocks):
        for ii, line in enumerate(ins):
            w = op(line)
            t = toks(line)
            d = dest(line)
            if w == "release":
                x = t[0]
                imm = imm_at(f, bi, ii, x)
                benign = "the value is an immortal (string literal / nullary) on every path reaching the release" if imm else \
                    ("no return is reachable from the release (the path ends in a defined trap; leaks are only reported at returns)"
                     if ends_in_trap(f, bi) else None)
                out.append(Mut("drop-release", f, (bi, ii), "delete `%s` (b%d i%d)" % (line, bi, ii), benign, None, "warn"))
                out.append(Mut("extra-release", f, (bi, ii), "duplicate `%s` (b%d i%d)" % (line, bi, ii), None, "is dead", "error"))
                out.append(Mut("use-after-release", f, (bi, ii), "read l%d after `%s` (b%d i%d)" % (x, line, bi, ii), None, "is dead", "error"))
                out.append(Mut("extra-dup", f, (bi, ii), "leak: dup l%d before `%s` (b%d i%d)" % (x, line, bi, ii),
                               "no return is reachable from the release (the path ends in a defined trap; leaks are only reported at returns)"
                               if ends_in_trap(f, bi) else None, None, "warn"))
            if w == "move" and d is not None:
                out.append(Mut("use-after-move", f, (bi, ii), "read l%d after `%s` (b%d i%d)" % (t[1], line, bi, ii), None, "is dead", "error"))
            if w == "struct":
                refs = [y for y in re.findall(r"\bl(\d+)\b", line[line.index("{"):]) if f.is_ref(int(y))]
                if refs:
                    out.append(Mut("use-after-consume", f, (bi, ii), "read l%s after `%s` (b%d i%d)" % (refs[0], line, bi, ii), None, "is dead", "error"))
            x = store_obj(line)
            if x is not None:
                out.append(Mut("store-shared-dup", f, (bi, ii), "dup l%d before `%s` (b%d i%d)" % (x, line, bi, ii), None, "to be Unique", "error"))
                out.append(Mut("store-shared-alias", f, (bi, ii), "borrow l%d, store through the alias in `%s` (b%d i%d)" % (x, line, bi, ii), None, "to be Unique", "error"))
            if w == "makeunique":
                x = t[0]
                later = None
                for k in range(ii + 1, len(ins)):
                    if dest(ins[k]) == x:
                        break
                    if store_obj(ins[k]) == x:
                        later = k
                        break
                if later is not None:
                    benign = ("redundant: l%d is definitely Unique here (independent dataflow in mutate_mir.py)" % x) if certainly_unique(f, bi, ii, x) else None
                    out.append(Mut("drop-makeunique", f, (bi, ii), "delete `%s` (b%d i%d) before `%s`" % (line, bi, ii, ins[later]), benign, "to be Unique", "error"))
            if (w == "borrow" or w == "getfield" or w == "arrayget") and d is not None and f.is_ref(d):
                out.append(Mut("release-borrowed", f, (bi, ii), "release l%d after `%s` (b%d i%d)" % (d, line, bi, ii), None, "of borrowed", "error"))
            if w == "dup" and d is not None:
                nxt = mentions_after(f, bi, ii, d)
                unused = not any(d in toks(l2) for b2, (_l, i2, tm) in enumerate(f.blocks)
                                 for k2, l2 in enumerate(i2 + [tm]) if not (b2 == bi and k2 == ii))
                benign = None
                if unused:
                    benign = "the dup's result l%d is never read or released (dead code)" % d
                elif nxt == "def":
                    benign = "l%d is overwritten before any use in the block" % d
                out.append(Mut("drop-dup", f, (bi, ii), "delete `%s` (b%d i%d)" % (line, bi, ii), benign, "dead", "error"))
    if f.inout:
        # v1.10: parameter 0 is handed back to the caller at every return
        for bi, (label, ins, term) in enumerate(f.blocks):
            for ii, line in enumerate(ins):
                if dest(line) == 0 and op(line) == "move":
                    out.append(Mut("inout-drop-receiver", f, (bi, ii), "delete `%s` (b%d i%d)" % (line, bi, ii), None,
                                   "must hold the updated receiver", "error"))
            if term.startswith("return"):
                out.append(Mut("inout-release-receiver", f, (bi, len(ins)), "release l0 before `%s` (b%d)" % (term, bi), None,
                               "must hold the updated receiver", "error"))
    for p in range(f.nparams):
        if f.is_ref(p) and p not in f.owned:
            out.append(Mut("release-param", f, (0, 0), "release borrowed parameter l%d at entry" % p, None, "of parameter", "error"))
            out.append(Mut("move-param", f, (0, 0), "move borrowed parameter l%d at entry" % p, None, "of parameter", "error"))
    return out


def apply(m):
    """The mutated copy of m.f, or None when the site is not applicable."""
    f = m.f.clone()
    b = f.blocks[m.bi]
    ins = b[1]
    ii = m.ii
    if m.cls in ("release-param", "move-param"):
        p = int(re.search(r"l(\d+)", m.desc).group(1))
        if m.cls == "release-param":
            ins.insert(0, "release l%d" % p)
        else:
            n = f.new_local()
            ins.insert(0, "l%d = move l%d" % (n, p))
        return f
    if m.cls == "inout-release-receiver":
        ins.append("release l0")
        return f
    line = ins[ii]
    t = toks(line)
    if m.cls == "inout-drop-receiver":
        del ins[ii]
    elif m.cls == "drop-release":
        del ins[ii]
    elif m.cls == "extra-release":
        ins.insert(ii + 1, line)
    elif m.cls == "use-after-release":
        n = f.new_local()
        ins.insert(ii + 1, "l%d = borrow l%d" % (n, t[0]))
    elif m.cls == "extra-dup":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, t[0]))
    elif m.cls == "use-after-move":
        n = f.new_local()
        ins.insert(ii + 1, "l%d = borrow l%d" % (n, t[1]))
    elif m.cls == "use-after-consume":
        refs = [int(y) for y in re.findall(r"\bl(\d+)\b", line[line.index("{"):]) if f.is_ref(int(y))]
        n = f.new_local()
        ins.insert(ii + 1, "l%d = borrow l%d" % (n, refs[0]))
    elif m.cls == "store-shared-dup":
        x = store_obj(line)
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, x))
    elif m.cls == "store-shared-alias":
        x = store_obj(line)
        n = f.new_local()
        ins[ii] = replace_obj(line, x, n)
        ins.insert(ii, "l%d = borrow l%d" % (n, x))
    elif m.cls == "drop-makeunique":
        del ins[ii]
    elif m.cls == "release-borrowed":
        ins.insert(ii + 1, "release l%d" % dest(line))
    elif m.cls == "drop-dup":
        del ins[ii]
    else:
        raise ValueError(m.cls)
    return f


# ---------------------------------------------------------------- driver plumbing

def build_driver(orinc, out_dir):
    c = os.path.join(out_dir, "verify_text.c")
    exe = os.path.join(out_dir, "verify_text")
    subprocess.run([orinc, "compile", "compiler/tests/verify_text.or", "-o", c], cwd=ROOT, check=True)
    subprocess.run(["cc", "-O1", "-w", "-I", "runtime", c, "runtime/orin_runtime.c",
                    "platform/orin_platform.c", "-lm", "-o", exe], cwd=ROOT, check=True)
    return exe


def corpus():
    out = []
    for suite in ("run", os.path.join("next", "run")):
        base = os.path.join(ROOT, "tests", suite)
        for e in sorted(os.listdir(base)):
            p = os.path.join(base, e)
            if os.path.isdir(p):
                if os.path.isfile(os.path.join(p, "main.or")):
                    out.append(os.path.join(p, "main.or"))
            elif e.endswith(".or"):
                out.append(p)
    return out


def mir_of(orinc, path):
    r = subprocess.run([orinc, "mir", os.path.relpath(path, ROOT)], cwd=ROOT, capture_output=True, text=True, timeout=600)
    return r.stdout if r.returncode == 0 else None


def program_text(prefix, funcs, target_idx, target):
    parts = [prefix, "\n"]
    for i, f in enumerate(funcs):
        parts.append(target.render() if i == target_idx else f.stub())
        parts.append("\n")
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join(ROOT, "build", "bootstrap", "orin2"))
    ap.add_argument("--verify-text", default=None)
    ap.add_argument("--limit", type=int, default=0, help="use only the first N programs (0 = all)")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    t0 = time.time()
    files = corpus()
    if a.limit:
        files = files[:a.limit]
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        mirs = list(pool.map(lambda f: mir_of(a.orinc, f), files))
    seen = {}
    nprog = 0
    for f, text in zip(files, mirs):
        if text is None:
            print("warning: no MIR for %s" % os.path.relpath(f, ROOT))
            continue
        nprog += 1
        prefix, funcs = parse(text)
        for i, fn in enumerate(funcs):
            k = fn.key()
            if k not in seen:
                seen[k] = (prefix, funcs, i)
    print("corpus: %d programs, %d distinct functions (%.1fs)" % (nprog, len(seen), time.time() - t0))

    entries = []   # (id, text)
    meta = {}
    for n, (k, (prefix, funcs, i)) in enumerate(sorted(seen.items())):
        fn = funcs[i]
        bid = "base%d" % n
        entries.append((bid, program_text(prefix, funcs, i, fn)))
        meta[bid] = ("base", fn, None)
        for mi, m in enumerate(sites(fn)):
            mf = apply(m)
            mid = "m%d_%d" % (n, mi)
            entries.append((mid, program_text(prefix, funcs, i, mf)))
            meta[mid] = ("mut", fn, m)

    with tempfile.TemporaryDirectory() as tmp:
        exe = a.verify_text or build_driver(a.orinc, tmp)
        path = os.path.join(tmp, "mutants.txt")
        with open(path, "w") as fh:
            for name, text in entries:
                fh.write("=== %s\n%s" % (name, text))
        r = subprocess.run([exe, path], capture_output=True, text=True, timeout=1800)
        if r.returncode != 0:
            sys.exit("verify_text failed: " + r.stderr[:500])
    res = {}
    for line in r.stdout.splitlines():
        p = line.split("\t")
        res[p[0]] = (p[1], int(p[2]), p[3:])
    if len(res) != len(entries):
        sys.exit("driver returned %d results for %d entries" % (len(res), len(entries)))

    # baselines: every distinct function must verify without errors
    base_warn = {}
    bad_base = 0
    for bid, (kind, fn, m) in meta.items():
        if kind == "base":
            verdict, cnt, _ = res[bid]
            if verdict != "ACCEPT":
                bad_base += 1
                print("BASELINE REJECTED: %s %s: %s" % (bid, fn.name, res[bid][2][:1]))
            base_warn[fn.key()] = cnt if verdict == "ACCEPT" else 0
    stats = {}
    survivors, wrong = [], []
    for mid, (kind, fn, m) in meta.items():
        if kind != "mut":
            continue
        s = stats.setdefault(m.cls, {"n": 0, "rejected": 0, "warned": 0, "benign": 0, "survived": 0, "wrong": 0})
        s["n"] += 1
        verdict, cnt, errs = res[mid]
        if verdict == "REJECT":
            if m.needle and not any(m.needle in e for e in errs):
                s["wrong"] += 1
                wrong.append((m, errs))
            else:
                s["rejected"] += 1
        elif m.expect == "warn" and cnt > base_warn[fn.key()]:
            s["warned"] += 1
        elif m.benign:
            s["benign"] += 1
        else:
            s["survived"] += 1
            survivors.append((m, cnt, base_warn[fn.key()]))
    print("%-20s %7s %9s %7s %7s %9s %6s" % ("class", "mutants", "rejected", "warned", "benign", "survivors", "wrong"))
    tot = {"n": 0, "rejected": 0, "warned": 0, "benign": 0, "survived": 0, "wrong": 0}
    for cls in sorted(stats):
        s = stats[cls]
        print("%-20s %7d %9d %7d %7d %9d %6d" % (cls, s["n"], s["rejected"], s["warned"], s["benign"], s["survived"], s["wrong"]))
        for k in tot:
            tot[k] += s[k]
    print("%-20s %7d %9d %7d %7d %9d %6d" % ("TOTAL", tot["n"], tot["rejected"], tot["warned"], tot["benign"], tot["survived"], tot["wrong"]))
    reasons = {}
    for mid, (kind, fn, m) in meta.items():
        if kind == "mut" and m.benign and res[mid][0] == "ACCEPT" and not (m.expect == "warn" and res[mid][1] > base_warn[fn.key()]):
            reasons[(m.cls, m.benign.split(":")[0].split(" (")[0])] = reasons.get((m.cls, m.benign.split(":")[0].split(" (")[0]), 0) + 1
    for (cls, why), c in sorted(reasons.items()):
        print("  benign %-18s %5d  %s" % (cls, c, why))
    fail = bad_base > 0
    new = 0
    for m, cnt, bw in survivors:
        if (m.cls, m.f.name) in KNOWN:
            print("KNOWN SURVIVOR %s in %s: %s (%s)" % (m.cls, m.f.name, m.desc, KNOWN[(m.cls, m.f.name)]))
        else:
            new += 1
            if new <= 40:
                print("SURVIVOR %s in %s: %s" % (m.cls, m.f.name, m.desc))
    for m, errs in wrong:
        if (m.cls, m.f.name) not in KNOWN:
            new += 1
            if new <= 40:
                print("WRONG-REASON %s in %s: %s\n    errors: %s" % (m.cls, m.f.name, m.desc, errs[:2]))
    print("time %.1fs" % (time.time() - t0))
    if fail or new:
        print("FAIL: %d surviving / wrong-reason mutant(s), %d rejected baselines" % (new, bad_base))
        return 1
    print("OK: every mutant was rejected%s or is classified benign" % ", warned" if tot["warned"] else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
