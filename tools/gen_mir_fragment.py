#!/usr/bin/env python3
"""Deterministic generator of random structured MIR programs within the fragment of the Lean
ownership checker (docs/formal.md, "The fragment"): const / move / borrow / dup / release /
structNew / getField / setField / putField / takeField / makeUnique / if-else / return.

Each program is emitted in two textual forms:
  * the Lean form read by `formal/.lake/build/bin/orin_check` (formal/Orin/Exec.lean),
  * the `orin mir` form read by the verifier driver compiler/tests/verify_text.or.

The generator carries a *tracker* (a small abstract interpreter, a Python port of the rules) only to
bias sampling towards programs that are mostly valid, so that deep states are reached; a fraction
of steps (FAULT) ignores the tracker and picks a random, class-correct instruction. The tracker
decides nothing about acceptance: both verdicts come from the two real checkers.

Usage: tools/gen_mir_fragment.py --count N --seed S --lean FILE --mir FILE
"""
import argparse
import random

# ---------------------------------------------------------------- program model

# AST statements (tuples):
#   ('const', d, value)          ('move', d, s)      ('borrow', d, s)    ('dup', d, s)
#   ('release', x)               ('struct', d, [ys]) ('get', d, o, i)    ('set', x, i, v)
#   ('take', d, x, i)            ('put', x, i, s)    ('mu', x)           ('if', c, [then], [else])


class Prog:
    def __init__(self, name, cls, np, code):
        self.name = name
        self.cls = cls  # per local: 'r' reference, 'i' int, 'b' bool
        self.np = np  # the first np locals are parameters (never redefined)
        self.code = code

    @property
    def n(self):
        return len(self.cls)


def walk(code):
    """All statements, pre-order, including those inside branches."""
    for st in code:
        yield st
        if st[0] == "if":
            yield from walk(st[2])
            yield from walk(st[3])


# ---------------------------------------------------------------- Lean text

def lean_stmts(code, cls, out):
    for st in code:
        k = st[0]
        if k == "const":
            out.append("const %d" % st[1])
        elif k in ("move", "borrow", "dup"):
            out.append("%s %d %d" % (k, st[1], st[2]))
        elif k == "release":
            out.append("release %d" % st[1])
        elif k == "struct":
            out.append(" ".join(["structNew", str(st[1])] + [str(y) for y in st[2]]))
        elif k == "get":
            out.append("getField %d %d %d %s" % (st[1], st[2], st[3], "r" if cls[st[1]] == "r" else "s"))
        elif k == "set":
            out.append("setField %d %d %d" % (st[1], st[2], st[3]))
        elif k == "take":
            out.append("takeField %d %d %d" % (st[1], st[2], st[3]))
        elif k == "put":
            out.append("putField %d %d %d" % (st[1], st[2], st[3]))
        elif k == "mu":
            out.append("makeUnique %d" % st[1])
        elif k == "if":
            out.append("if %d" % st[1])
            lean_stmts(st[2], cls, out)
            out.append("else")
            lean_stmts(st[3], cls, out)
            out.append("end")
        else:
            raise ValueError(k)


def to_lean(p):
    out = ["prog %s %d %s" % (p.name, p.n, "".join("r" if c == "r" else "s" for c in p.cls[:p.np]) or "-")]
    lean_stmts(p.code, p.cls, out)
    out.append("endprog")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- MIR text (`orin mir` format)

def to_mir(p):
    blocks = []  # each: [instr lines, terminator line]

    def new():
        blocks.append([[], None])
        return len(blocks) - 1

    def emit(code, cur):
        for st in code:
            k = st[0]
            ins = blocks[cur][0]
            if k == "const":
                ins.append("l%d = copy %s" % (st[1], "true" if p.cls[st[1]] == "b" and st[2] else
                                              "false" if p.cls[st[1]] == "b" else str(st[2])))
            elif k in ("move", "borrow", "dup"):
                ins.append("l%d = %s l%d" % (st[1], k, st[2]))
            elif k == "release":
                ins.append("release l%d" % st[1])
            elif k == "struct":
                ins.append("l%d = struct tag0 {%s}" % (st[1], ", ".join("l%d" % y for y in st[2])))
            elif k == "get":
                ins.append("l%d = getfield l%d.%d" % (st[1], st[2], st[3]))
            elif k == "set":
                ins.append("setfield l%d.%d = l%d" % (st[1], st[2], st[3]))
            elif k == "take":
                ins.append("l%d = takefield l%d.%d" % (st[1], st[2], st[3]))
            elif k == "put":
                ins.append("putfield l%d.%d = l%d" % (st[1], st[2], st[3]))
            elif k == "mu":
                ins.append("makeunique l%d" % st[1])
            elif k == "if":
                bt, be, bj = new(), new(), new()
                blocks[cur][1] = "branch l%d ? b%d : b%d" % (st[1], bt, be)
                et = emit(st[2], bt)
                blocks[et][1] = "goto b%d" % bj
                ee = emit(st[3], be)
                blocks[ee][1] = "goto b%d" % bj
                cur = bj
            else:
                raise ValueError(k)
        return cur

    b0 = new()
    last = emit(p.code, b0)
    blocks[last][1] = "return"
    ty = {"r": "ref", "i": "int", "b": "bool"}
    out = ["main = fn0", "", "fn0 f (params %d) -> void" % p.np,
           "  locals: " + " ".join("l%d:%s" % (i, ty[c]) for i, c in enumerate(p.cls))]
    for bi, (ins, t) in enumerate(blocks):
        out.append("  b%d:" % bi)
        out += ["    " + x for x in ins]
        out.append("    " + t)
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- tracker (generation bias only)

DEAD, INIT, OWNED, UNIQUE, BORROWED, PARAM, POISON = "dead init owned unique borrowed param poison".split()


def counted(k):
    return k[0] in (OWNED, UNIQUE)


def is_root(k):
    return k[0] in (OWNED, UNIQUE, PARAM)


def is_ref(k):
    return k[0] in (OWNED, UNIQUE, PARAM, BORROWED)


class T:
    """Tracker state: kinds per local (kind, src) and open holes."""

    def __init__(self, ls, holes, cls):
        self.ls = ls
        self.holes = holes
        self.cls = cls

    def copy(self):
        return T(list(self.ls), set(self.holes), self.cls)

    def hole(self, x):
        return any(h[0] == x for h in self.holes)

    def kill_b(self, x):
        self.ls = [(DEAD, 0) if k == (BORROWED, x) else k for k in self.ls]

    def define(self, d, k):
        self.kill_b(d)
        self.ls[d] = k

    def demote(self, l):
        if self.ls[l][0] == UNIQUE:
            self.ls[l] = (OWNED, 0)

    def root(self, l):
        k = self.ls[l]
        return k[1] if k[0] == BORROWED else l

    def consume(self, v):
        k = self.ls[v][0]
        if k == INIT:
            return True
        if k in (OWNED, UNIQUE):
            self.define(v, (DEAD, 0))
            return True
        return False


def step(t, np, st):
    """Apply one non-`if` statement to tracker `t` in place; False = the statement is invalid."""
    k = st[0]
    n = len(t.ls)
    if k == "const":
        d = st[1]
        if d < np or t.hole(d):
            return False
        t.define(d, (INIT, 0))
        return True
    if k == "move":
        d, s = st[1], st[2]
        if d < np or d == s or not counted(t.ls[s]) or t.hole(d) or t.hole(s):
            return False
        ks = t.ls[s]
        t.define(s, (DEAD, 0))
        t.define(d, ks)
        return True
    if k == "borrow":
        d, s = st[1], st[2]
        if d < np or d == s or not is_ref(t.ls[s]) or t.root(s) == d or t.hole(d) or t.hole(s):
            return False
        r = t.root(s)
        t.demote(s)
        t.define(d, (BORROWED, r))
        return True
    if k == "dup":
        d, s = st[1], st[2]
        if d < np or not is_ref(t.ls[s]) or t.hole(d) or t.hole(s):
            return False
        t.demote(s)
        t.define(d, (OWNED, 0))
        return True
    if k == "release":
        x = st[1]
        if not counted(t.ls[x]) or t.hole(x):
            return False
        t.define(x, (DEAD, 0))
        return True
    if k == "struct":
        d, ys = st[1], st[2]
        if d < np or t.hole(d) or d in ys:
            return False
        for y in ys:
            if t.hole(y) or not t.consume(y):
                return False
        t.define(d, (UNIQUE, 0))
        return True
    if k == "get":
        d, o, i = st[1], st[2], st[3]
        if d < np or not is_ref(t.ls[o]) or t.hole(d) or (o, i) in t.holes:
            return False
        if t.cls[d] == "r":
            if t.root(o) == d:
                return False
            t.define(d, (BORROWED, t.root(o)))
        else:
            t.define(d, (INIT, 0))
        return True
    if k == "set":
        x, i, v = st[1], st[2], st[3]
        if x == v or t.ls[x][0] != UNIQUE or t.hole(v) or (x, i) in t.holes:
            return False
        if not t.consume(v):
            return False
        t.kill_b(x)
        return True
    if k == "take":
        d, x, i = st[1], st[2], st[3]
        if d < np or d == x or t.ls[x][0] != UNIQUE or t.hole(d) or (x, i) in t.holes:
            return False
        t.kill_b(x)
        t.holes.add((x, i))
        t.define(d, (OWNED, 0))
        return True
    if k == "put":
        x, i, s = st[1], st[2], st[3]
        if x == s or t.ls[x][0] != UNIQUE or t.hole(s) or (x, i) not in t.holes:
            return False
        if not t.consume(s):
            return False
        t.holes.discard((x, i))
        t.kill_b(x)
        return True
    if k == "mu":
        x = st[1]
        if not counted(t.ls[x]) or t.hole(x):
            return False
        t.kill_b(x)
        t.ls[x] = (UNIQUE, 0)
        return True
    raise ValueError(k)


def join(a, b):
    if a.holes != b.holes:
        return None
    out = []
    for x, y in zip(a.ls, b.ls):
        if x == y:
            out.append(x)
        elif counted(x) and counted(y):
            out.append((OWNED, 0))
        else:
            out.append((POISON, 0))
    out = [(BORROWED, k[1]) if k[0] == BORROWED and is_root(out[k[1]]) else (POISON, 0) if k[0] == BORROWED else k
           for k in out]
    return T(out, set(a.holes), a.cls)


# ---------------------------------------------------------------- sampling

FAULT = 0.10  # fraction of steps that ignore the tracker
WEIGHTS = [("const", 3), ("move", 5), ("borrow", 5), ("dup", 5), ("release", 6), ("struct", 8),
           ("get", 8), ("set", 6), ("take", 4), ("put", 4), ("mu", 3)]


def sample(rng, cls, np, tr, allow_self_operand):
    """One random class-correct statement."""
    n = len(cls)
    refs = [i for i, c in enumerate(cls) if c == "r"]
    scal = [i for i, c in enumerate(cls) if c != "r"]
    kind = rng.choices([w[0] for w in WEIGHTS], [w[1] for w in WEIGHTS])[0]
    r = lambda: rng.choice(refs)
    if kind == "const":
        d = rng.choice(scal)
        return ("const", d, rng.randint(0, 3))
    if kind == "move":
        return ("move", r(), r())
    if kind in ("borrow", "dup"):
        return (kind, r(), r())
    if kind == "release":
        return ("release", r())
    if kind == "struct":
        d = r()
        ys = []
        for _ in range(rng.choice([0, 1, 1, 2, 3])):
            y = rng.choice(range(n))
            if y == d and not allow_self_operand:
                continue
            ys.append(y)
        return ("struct", d, ys)
    if kind == "get":
        d = rng.choice(range(n))
        if cls[d] == "b":
            d = rng.choice([i for i in range(n) if cls[i] != "b"])
        return ("get", d, r(), rng.randint(0, 2))
    if kind == "set":
        return ("set", r(), rng.randint(0, 2), rng.choice(range(n)))
    if kind == "take":
        return ("take", r(), r(), rng.randint(0, 2))
    if kind == "put":
        if tr is not None and tr.holes and rng.random() < 0.8:
            x, i = rng.choice(sorted(tr.holes))
            return ("put", x, i, r())
        return ("put", r(), rng.randint(0, 2), r())
    return ("mu", r())


def sample_valid(rng, cls, np, tr, allow_self_operand):
    for _ in range(60):
        st = sample(rng, cls, np, tr, allow_self_operand)
        probe = tr.copy()
        if step(probe, np, st):
            return st
    return None


def gen_block(rng, cls, np, tr, depth, budget, allow_self_operand):
    """Generate statements, updating tracker `tr` in place."""
    code = []
    for _ in range(budget):
        if depth < 2 and rng.random() < 0.12:
            conds = [i for i, c in enumerate(cls) if c == "b"]
            c = rng.choice(conds)
            if tr.ls[c][0] != INIT and rng.random() < 0.9:
                st = ("const", c, rng.randint(0, 1))
                if step(tr, np, st):
                    code.append(st)
            ta, tb = tr.copy(), tr.copy()
            thn = gen_block(rng, cls, np, ta, depth + 1, rng.randint(0, 5), allow_self_operand)
            els = gen_block(rng, cls, np, tb, depth + 1, rng.randint(0, 5), allow_self_operand)
            code.append(("if", c, thn, els))
            j = join(ta, tb)
            if j is None:
                tr.ls = [(POISON, 0)] * len(tr.ls)
                tr.holes = set(ta.holes)
            else:
                tr.ls, tr.holes = j.ls, j.holes
            continue
        if rng.random() < FAULT:
            st = sample(rng, cls, np, tr, allow_self_operand)
            probe = tr.copy()
            if step(probe, np, st):
                tr.ls, tr.holes = probe.ls, probe.holes
            code.append(st)
        else:
            st = sample_valid(rng, cls, np, tr, allow_self_operand)
            if st is not None:
                step(tr, np, st)
                code.append(st)
    return code


def gen_prog(rng, idx, allow_self_operand=0.0):
    nref = rng.randint(3, 6)
    nint = rng.randint(1, 2)
    nbool = rng.randint(1, 2)
    # parameters: a random subset of locals, moved to the front
    cls = ["r"] * nref + ["i"] * nint + ["b"] * nbool
    rng.shuffle(cls)
    np = rng.choice([0, 0, 1, 1, 2, 3])
    ls = []
    for c in cls[:np]:
        ls.append((PARAM, 0) if c == "r" else (INIT, 0))
    ls += [(DEAD, 0)] * (len(cls) - np)
    tr = T(ls, set(), cls)
    code = gen_block(rng, cls, np, tr, 0, rng.randint(4, 22), allow_self_operand)
    # tail: usually close open holes and release what is still owned (leaks are only warnings)
    if rng.random() < 0.9:
        for (x, i) in sorted(tr.holes):
            cand = [l for l in range(len(cls)) if cls[l] == "r" and counted(tr.ls[l]) and l != x
                    and not tr.hole(l)]
            if cand:
                st = ("put", x, i, rng.choice(cand))
                if step(tr, np, st):
                    code.append(st)
        for l in range(len(cls)):
            if cls[l] == "r" and counted(tr.ls[l]) and not tr.hole(l) and rng.random() < 0.8:
                st = ("release", l)
                if step(tr, np, st):
                    code.append(st)
    return Prog("p%05d" % idx, cls, np, code)


def generate(count, seed, allow_self_operand=0.02):
    rng = random.Random(seed)
    return [gen_prog(rng, i, allow_self_operand) for i in range(count)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=20261013)
    ap.add_argument("--lean", required=True)
    ap.add_argument("--mir", required=True)
    a = ap.parse_args()
    progs = generate(a.count, a.seed)
    with open(a.lean, "w") as f:
        for p in progs:
            f.write(to_lean(p))
    with open(a.mir, "w") as f:
        for p in progs:
            f.write("=== %s\n%s" % (p.name, to_mir(p)))
    print("generated %d programs" % len(progs))


if __name__ == "__main__":
    main()
