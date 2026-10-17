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
  redundant-makeunique-census  a `makeunique x` left after the optimiser on a certainly-Unique x -> SURVIVOR (T1 missed it)
  dup-before-store-after-drop  `t = dup x` before a store on a certainly-Unique x with no `makeunique x` earlier in
                      its block (what T1 leaves after deleting the check) -> ERROR
  release-borrowed    `release d` right after d = borrow/getfield -> ERROR
  release-param       `release p` for a borrowed parameter p      -> ERROR
  move-param          `t = move p` for a borrowed parameter p     -> ERROR
  drop-dup            delete `d = dup x`                          -> ERROR (d dead at its later use)
  extra-dup           `t = dup x` before `release x`, t unused    -> a leak WARNING (or an error)
  inout-drop-receiver delete `l0 = move ..` in an inout function  -> ERROR (l0 must hold the receiver at return)
  inout-release-receiver `release l0` before a return of an inout function -> ERROR (same)
  string appends (`strappend`, `strprepend`, `strappendi` / `strappendu`, `strappendsub`, docs/mir.md v2.5; every one in the corpus):
  append-after-release  `release x` right before `strappend* x, ..`               -> ERROR (x is dead)
  append-borrowed       `t = borrow x`, then `strappend* t, ..`                    -> ERROR (a borrowed string is not mutated in place)
  append-kills-borrow   `t = borrow x` before `strappend* x, ..`, read t after it -> ERROR (the append invalidated the borrow)
  load forwarding (rule F1, docs/mir.md v2.4; applied to every `d = forward s, o[key]` of the optimised corpus):
  fwd-across-write    write the same slot of o between the source and the forward      -> ERROR unjustified forward
  fwd-other-slot-ok   write a DIFFERENT slot of o there (positive control)             -> ACCEPTED (rejection is a finding)
  fwd-after-redef-obj redefine o between them                                          -> ERROR unjustified forward
  fwd-after-redef-src redefine the forwarded local s between them                      -> ERROR unjustified forward
  fwd-across-push     `arraypush o` between them (array objects)                       -> ERROR unjustified forward
  fwd-wrong-slot      forward from the load of another slot (key differs)              -> ERROR unjustified forward
  fwd-across-block    split the block between the source and the forward               -> ERROR unjustified forward
  unchecked array access (rule U1, docs/mir.md v2.6; applied to every `arraygetu` / `arraysetu` of the optimised corpus):
  bce-no-fact         make a checked access unchecked that has no earlier access of (a, i) in its block -> ERROR without a dominating check
  bce-across-push     `arraypush a` between the checked access and the unchecked one         -> ERROR without a dominating check
  bce-after-redef     redefine the array local there (`t = dup a; a = move t`)               -> ERROR without a dominating check
  bce-after-redef-index redefine the index local there                                       -> ERROR without a dominating check
  bce-other-index     access an index that no earlier access of the block names              -> ERROR without a dominating check
  bce-across-block    split the block between the checked access and the unchecked one       -> ERROR without a dominating check
  bce-makeunique-ok   `makeunique a` there (positive control)                                -> ACCEPTED (rejection is a finding)
  bce-other-index-ok  read another index of a there (positive control)                       -> ACCEPTED (rejection is a finding)
  The bce-* classes are applied to the unchecked accesses that only the dominating-access fact justifies, and bce-no-fact to every
  checked access left after the optimiser (so none of them is justified by an interval); `verify_text --facts` tells the kinds apart.
  unchecked struct slots (rule U6, docs/mir.md v2.8; applied to every `getfieldu` / `setfieldu` of the optimised corpus):
  field-no-fact       make a checked field access unchecked that has no earlier access of its struct local in its block -> ERROR without a dominating check
  field-after-redef   redefine the struct local before the unchecked access (`t = dup o; o = move t`)  -> ERROR without a dominating check
  field-across-block  split the block between the checked access and the unchecked one               -> ERROR without a dominating check
  field-higher-slot   access a slot above every slot the block accessed before                       -> ERROR without a dominating check
  shape-drop          delete a `shapecheck o.K` that justifies the unchecked accesses after it                     -> ERROR without a dominating check
  shape-too-small     check one slot fewer (`shapecheck o.K-1`) when an unchecked access of slot K relies on it   -> ERROR without a dominating check
  field-makeunique-ok `makeunique o` there (positive control)                                        -> ACCEPTED (rejection is a finding)
  range facts (rule U1, interval fact, docs/mir.md v2.6; applied to every unchecked access that ONLY the interval analysis justifies):
  range-widen-off-by-one    the loop bound one too large (`lt i, N` -> `le i, N`, `le i, N-1` -> `le i, N`) -> ERROR without a dominating check
  range-after-push          `arraypush a` before the access                                  -> ERROR
  range-after-pop           `arraypop a` before the access                                   -> ERROR
  range-across-dup          `t = dup a` before the access                                    -> ERROR (the array is mentioned by a dup)
  range-after-redef-array   redefine the array local there (`t = dup a; a = move t`)         -> ERROR
  range-after-inout-call    `a` is the receiver of an in/out call before the access           -> ERROR
  range-param-array         the array is not built here (`a = call ..` instead of arraynew) -> ERROR (no shape fact, like a parameter)
  range-after-redef-index   the index local gets an unknown value there                      -> ERROR
  range-index-add-large     `i = add i, 1000000u` before the access                          -> ERROR (the add transfer is not ignored)
  range-no-branch-refinement the compares of the index counter are replaced by `copy true`    -> ERROR (the guard is what bounds the index)
  range-move-roundtrip-ok   `t = move a; a = move t` (positive control: a move carries the fact)  -> ACCEPTED
  range-borrowed-call-ok    a call that gets the array in a borrowed position (positive control)    -> ACCEPTED
  range-copy-index-ok       the index read through a copy (positive control)                        -> ACCEPTED
  range-addsub-ok           the index read through `(i + 1) - 1` (positive control)                 -> ACCEPTED

  unique receivers and results (rules U2-U5, docs/mir.md v2.7; the callee's header seen by the mutated caller is edited as well):
  uniq-flag-flip-in   `unique-in` set on the callee of a call whose receiver is not Unique -> ERROR to be Unique (U4)
  uniq-flag-flip-out  `unique-out` set on a function that returns a value that is not Unique -> ERROR (rule U3)
  uniq-in-shared-caller `t = dup x` before a call of a unique-in function              -> ERROR to be Unique (U4)
  uniq-out-then-dup   `t = dup x` after a call of a unique-out function, a store through x follows -> ERROR to be Unique (U5)

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
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Fact kind of every unchecked access of a baseline function: {(function key, block, instruction): kind}, filled by the
# `verify_text --facts` pass before the mutants are generated (kind: dominated-by-check, interval, both or none).
FACTS = {}

# Known surviving mutants that are real verifier findings: {(class, function name): explanation}.
KNOWN = {}

# ---------------------------------------------------------------- MIR text model


class Func:
    def __init__(self, header, locals_, blocks):
        self.header = header          # "fn3 name (params 1, owned l0) -> ref"
        self.locals = locals_         # list of (name, type)
        self.blocks = blocks          # list of [label, [instr lines], terminator line]
        m = re.match(r"fn\d+ (.*) \(params (\d+)(?:, owned ([l0-9 ]+))?(, inout)?(, unique-in)?(, unique-out)?\) -> (\w+)$", header)
        self.name = m.group(1)
        self.nparams = int(m.group(2))
        self.owned = set(int(x[1:]) for x in (m.group(3) or "").split())
        self.inout = bool(m.group(4))     # v1.10: parameter 0 is handed back to the caller at every return
        self.extra = []                   # stub functions a mutant adds after the program's own (their index is len(funcs) + k)
        self._key = None
        self.uin = bool(m.group(5))       # v2.7: the receiver is Unique on entry (rule U2)
        self.uout = bool(m.group(6))      # v2.7: the value handed back is Unique (rules U3, U5)
        self.ret = m.group(7)
        self.peers = None                 # the functions of the program (set after parsing): the callees' flags

    def key(self):
        if self._key is None:
            self._key = self.name + "\n" + self.render(normalise=True)
        return self._key

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
        c = Func(self.header, list(self.locals), [[b[0], list(b[1]), b[2]] for b in self.blocks])
        c.extra = list(self.extra)
        c.peers = self.peers
        return c

    def with_flag(self, flag):
        """A copy whose header also carries `unique-in` / `unique-out`."""
        c = self.clone()
        if flag == "unique-in":
            h = re.sub(r"(, unique-out)?\) -> ", lambda m: ", unique-in" + (m.group(1) or "") + ") -> ", self.header, count=1)
        else:
            h = self.header.replace(") -> ", ", unique-out) -> ", 1)
        d = Func(h, c.locals, c.blocks)
        d.peers = self.peers
        d.extra = list(self.extra)
        return d

    def new_local(self, ty="ref"):
        self.locals.append(("l%d" % len(self.locals), ty))
        return len(self.locals) - 1

    def is_ref(self, i):
        return self.locals[i][1] == "ref"


SPAN_RE = re.compile(r" @\d+:\d+-\d+$")


def parse(text):
    """-> (prefix text up to and including `main = ..`, [Func])

    The source positions the lowering records (` @file:start-end` after an instruction or terminator,
    docs/mir.md v2.0) are dropped: the mutations are about ownership, and a mutant has no source position."""
    prefix, funcs = [], []
    cur = None
    seen_main = False
    for line in text.split("\n"):
        s = SPAN_RE.sub("", line.strip())
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


APPENDS = ("strappend", "strprepend", "strappendi", "strappendu", "strappendsub")
STORES = ("setfield", "setfieldu", "putfield", "arrayset", "arraysetu", "arrayput")
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


def replace_obj_first(line, old, new):
    """Replace the first local of an instruction that has no destination (`strappend l3, l4`)."""
    return re.sub(r"\bl%d\b" % old, "l%d" % new, line, count=1)


def replace_obj(line, old, new):
    """Replace the object operand of a store/take/put line (first occurrence after the dest)."""
    w = op(line)
    if w in STORES:
        return re.sub(r"\bl%d\b" % old, "l%d" % new, line, count=1)
    d = re.match(r"(l\d+ = \S+ )(.*)", line)
    return d.group(1) + re.sub(r"\bl%d\b" % old, "l%d" % new, d.group(2), count=1)


# ---------------------------------------------------------------- mutation sites

class Mut:
    def __init__(self, cls, f, loc, desc, benign, needle, expect, peer=None, flag=None):
        self.cls, self.f, self.desc, self.benign, self.needle, self.expect = cls, f, desc, benign, needle, expect
        self.bi, self.ii = loc
        self.peer = peer    # (function index, flag): the stub of that function gets the flag in the mutant program
        self.flag = flag    # the flag the mutated function itself gets


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
KEEP_READS = ("getfield", "getfieldu", "arrayget", "arraygetu", "tag", "forward")


CALL_RE = re.compile(r"(?:l\d+ = )?call fn(\d+)\((.*)\)$")


def call_parts(f, line):
    """(callee Func, [argument locals or None for a constant]) of a `call` line, else (None, [])."""
    m = CALL_RE.match(line)
    if not m or not f.peers:
        return None, []
    args = [int(a.strip()[1:]) if re.fullmatch(r"l\d+", a.strip()) else None for a in m.group(2).split(",") if a.strip()]
    return f.peers[int(m.group(1))], args


def uniq_transfer(f, U, line):
    w, d, t = op(line), dest(line), toks(line)
    U = set(U)
    keep = set()
    callee, cargs = call_parts(f, line) if w == "call" else (None, [])
    if w in ("call", "builtin", "callind") and (d is None or not f.is_ref(d)):
        # a call with no result or a scalar result cannot return an alias of its (borrowed) arguments
        keep = set(t) - ({d} if d is not None else set())
        if callee is not None and callee.inout:
            # an in/out callee can keep a counted reference to a borrowed argument in the receiver it hands back
            keep = set()
    if w in STORES:
        keep = {t[0]}
    elif w in TAKES:
        keep = {t[1]}
    elif w == "shapecheck":
        keep = {t[0]}
    elif w in KEEP_READS:
        keep = set(t[1:])
    elif w == "makeunique":
        keep = {t[0]}
    was = (t[1] in U) if w == "move" and len(t) > 1 else False
    U -= set(t) - keep
    if d is not None:
        U.discard(d)
    if w in ("struct", "arraynew", "closure", "iface") and d is not None:
        U.add(d)
    if w == "makeunique":
        U.add(t[0])
    if w == "move" and was:
        U.add(d)
    if callee is not None and callee.uout:
        # rule U5: the result of a unique-out function / the receiver an in/out unique-out function hands back
        if callee.inout:
            if cargs and cargs[0] is not None:
                U.add(cargs[0])
        elif d is not None:
            U.add(d)
    return U


def uniq_states(f):
    """In-state of every block (None = unreachable)."""
    ins = [None] * len(f.blocks)
    ins[0] = {0} if f.uin else set()   # rule U2
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


def uniq_at(f, bi, ii):
    """The certainly-Unique locals just before instruction ii of block bi (uncached)."""
    U = uniq_states(f)[bi]
    if U is None:
        return set()
    for line in f.blocks[bi][1][:ii]:
        U = uniq_transfer(f, U, line)
    return U


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
                if certainly_unique(f, bi, ii, x) and not any(op(l2) == "makeunique" and toks(l2)[0] == x for l2 in ins[:ii]):
                    out.append(Mut("dup-before-store-after-drop", f, (bi, ii), "dup l%d before `%s` (b%d i%d), Unique without a makeunique in the block" % (x, line, bi, ii), None, "to be Unique", "error"))
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
                    # ADR-0038 addendum T1: the optimiser deletes every `makeunique` of a local the verifier proves
                    # Unique, so one that is certainly Unique by the independent dataflow is a census finding (the
                    # mutant is accepted, so it is a SURVIVOR); no BENIGN classification remains for this class.
                    cls = "redundant-makeunique-census" if certainly_unique(f, bi, ii, x) else "drop-makeunique"
                    out.append(Mut(cls, f, (bi, ii), "delete `%s` (b%d i%d) before `%s`" % (line, bi, ii, ins[later]), None, "to be Unique", "error"))
            if (w == "borrow" or w in ("getfield", "getfieldu") or w == "arrayget") and d is not None and f.is_ref(d):
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
            if w in APPENDS:
                x = t[0]
                out.append(Mut("append-after-release", f, (bi, ii), "release l%d before `%s` (b%d i%d)" % (x, line, bi, ii), None, "is dead", "error"))
                out.append(Mut("append-borrowed", f, (bi, ii), "append through a borrow of l%d in `%s` (b%d i%d)" % (x, line, bi, ii), None, None, "error"))
                out.append(Mut("append-kills-borrow", f, (bi, ii), "read a borrow of l%d taken before `%s` (b%d i%d)" % (x, line, bi, ii), None, "is dead", "error"))
            if w == "forward":
                out += forward_sites(f, bi, ii, line)
            if w in ("arraygetu", "arraysetu"):
                kind = FACTS.get((f.key(), bi, ii), "dominated-by-check")
                if kind == "dominated-by-check":
                    out += unchecked_sites(f, bi, ii, line)
                elif kind == "interval":
                    out += range_sites(f, bi, ii, line)
            if w in ("arrayget", "arrayset"):
                out += nofact_sites(f, bi, ii, line)
            if w in ("getfieldu", "setfieldu"):
                out += field_sites(f, bi, ii, line)
            if w == "shapecheck":
                out += shape_sites(f, bi, ii, line)
            if w in ("getfield", "setfield"):
                out += field_nofact_sites(f, bi, ii, line)
            if w == "call":
                out += unique_call_sites(f, bi, ii, line)
    out += unique_out_sites(f)
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


FWD_RE = re.compile(r"l(\d+) = forward l(\d+), l(\d+)\[([^\]]+)\]$")
ZERO = {"int": "0", "usize": "0u", "bool": "false", "float": "f0.0"}


def fwd_parts(line):
    """(d, s, o, key text) of a `forward` line."""
    d, s_, o, key = FWD_RE.match(line).groups()
    return int(d), int(s_), int(o), key


def fwd_kind(ins, ii, o, key):
    """'field' or 'array' (the form of the nearest earlier access to slot (o, key), looking through forwards), else None."""
    for j in range(ii - 1, -1, -1):
        line = ins[j]
        m = re.match(r"(?:l\d+ = getfieldu?|setfieldu?) l%d\.%s\b" % (o, re.escape(key[:-1])), line)
        if m and key.endswith("u"):
            return "field"
        if re.match(r"(?:l\d+ = arrayget|arrayset)u? l%d\[%s\]" % (o, re.escape(key)), line):
            return "array"
        if re.match(r"l\d+ = forward l\d+, l%d\[%s\]$" % (o, re.escape(key)), line):
            continue
    return None


def no_ref_alias_of(f, o):
    """No reference local is projected or borrowed from o: a store through o kills such borrows, which would reject a
    positive control for a reason that has nothing to do with forwarding."""
    pat = re.compile(r"l(\d+) = (?:getfieldu?|borrow) l%d\b|l(\d+) = arraygetu? l%d\[" % (o, o))
    for _, ins, _t in f.blocks:
        for line in ins:
            m = pat.match(line)
            if m and f.is_ref(int(m.group(1) or m.group(2))):
                return False
    return True


def slot_span(f, o):
    """(largest constant slot / index that any instruction of f uses on local o, or -1; True if some access uses a local index)."""
    top, symbolic = -1, False
    for _, ins, _t in f.blocks:
        for line in ins:
            for m in re.finditer(r"\bl%d(?:\.|\[)(l)?(\d+)u?" % o, line):
                if m.group(1):
                    symbolic = True
                else:
                    top = max(top, int(m.group(2)))
            if re.search(r"\bl%d\[l\d+\]" % o, line):
                symbolic = True
    return top, symbolic


def forward_sites(f, bi, ii, line):
    d, s_, o, key = fwd_parts(line)
    ins = f.blocks[bi][1]
    kind = fwd_kind(ins, ii, o, key)
    if kind is None:
        return []
    where = "(b%d i%d)" % (bi, ii)
    need = "unjustified forward"
    out = [
        Mut("fwd-across-write", f, (bi, ii), "write the same slot of l%d before `%s` %s" % (o, line, where), None, need, "error"),
        Mut("fwd-after-redef-obj", f, (bi, ii), "redefine l%d before `%s` %s" % (o, line, where), None, need, "error"),
        Mut("fwd-after-redef-src", f, (bi, ii), "redefine l%d before `%s` %s" % (s_, line, where), None, need, "error"),
        Mut("fwd-wrong-slot", f, (bi, ii), "forward from another slot: `%s` %s" % (line, where), None, need, "error"),
        Mut("fwd-across-block", f, (bi, ii), "split the block before `%s` %s" % (line, where), None, need, "error"),
    ]
    if kind == "array":
        out.append(Mut("fwd-across-push", f, (bi, ii), "arraypush l%d before `%s` %s" % (o, line, where), None, need, "error"))
    const = key.endswith("u") and key[:-1].isdigit()
    if const and not slot_span(f, o)[1] and certainly_unique(f, bi, ii, o) and no_ref_alias_of(f, o):
        out.append(Mut("fwd-other-slot-ok", f, (bi, ii), "write another slot of l%d before `%s` %s" % (o, line, where),
                       "positive control: a write to a different slot must not end the forwarding", None, "accept"))
    return out


UGET_RE = re.compile(r"l(\d+) = arraygetu l(\d+)\[([^\]]+)\]$")
USET_RE = re.compile(r"arraysetu l(\d+)\[([^\]]+)\] = (.+)$")
GET_RE = re.compile(r"l(\d+) = arrayget l(\d+)\[([^\]]+)\]$")
SET_RE = re.compile(r"arrayset l(\d+)\[([^\]]+)\] = (.+)$")


def acc_parts(line):
    """(array local, key text, value operand text or None, destination local or None) of an array access line (any form)."""
    for rx, kind in ((UGET_RE, "get"), (GET_RE, "get")):
        m = rx.match(line)
        if m:
            return int(m.group(2)), m.group(3), None, int(m.group(1))
    for rx in (USET_RE, SET_RE):
        m = rx.match(line)
        if m:
            return int(m.group(1)), m.group(2), m.group(3), None
    return None


def scalar_ty(f, a, key, val, d):
    """The scalar type of the element the access moves (int, usize, bool, float), or None for a reference / unknown."""
    if d is not None:
        return f.locals[d][1] if f.locals[d][1] in ZERO else None
    if re.fullmatch(r"l\d+", val):
        t = f.locals[int(val[1:])][1]
        return t if t in ZERO else None
    if re.fullmatch(r"-?\d+", val):
        return "int"
    if re.fullmatch(r"\d+u", val):
        return "usize"
    if val in ("true", "false"):
        return "bool"
    return None


def touches(line, a):
    """The array local a occurs in an array access, a push/pop/extend, a call or anything else: any mention."""
    return a in toks(line)


def earlier_access(ins, ii, a, key):
    """Some earlier line of the block is an access of a[key] (any form), or a forward from it."""
    pat = re.compile(r"(?:l\d+ = arrayget|arrayset)u? l%d\[%s\]" % (a, re.escape(key)))
    return any(pat.match(l) for l in ins[:ii])


def nofact_sites(f, bi, ii, line):
    """A checked access with no earlier access of the same array and index in its block (so no dominating check): making it
    unchecked is the bce-no-fact mutant. An access with an earlier one is skipped (it may be justified)."""
    p = acc_parts(line)
    if p is None:
        return []
    a, key, val, d = p
    ins = f.blocks[bi][1]
    fw = re.compile(r"l\d+ = forward l\d+, l%d\[%s\]$" % (a, re.escape(key)))
    if earlier_access(ins, ii, a, key) or any(fw.match(l) for l in ins[:ii]):
        return []
    return [Mut("bce-no-fact", f, (bi, ii), "make `%s` unchecked, with no earlier access of l%d[%s] in the block (b%d i%d)" % (line, a, key, bi, ii),
                None, "without a dominating check", "error")]


def unchecked_sites(f, bi, ii, line):
    a, key, val, d = acc_parts(line)
    ins = f.blocks[bi][1]
    where = "(b%d i%d)" % (bi, ii)
    need = "without a dominating check"
    out = [
        Mut("bce-after-redef", f, (bi, ii), "redefine l%d before `%s` %s" % (a, line, where), None, need, "error"),
        Mut("bce-across-block", f, (bi, ii), "split the block before `%s` %s" % (line, where), None, need, "error"),
    ]
    ty = scalar_ty(f, a, key, val, d)
    if ty is not None:
        out.append(Mut("bce-across-push", f, (bi, ii), "arraypush l%d before `%s` %s" % (a, line, where), None, need, "error"))
    # an index that no earlier access of the block names
    if re.fullmatch(r"\d+u", key):
        k2 = int(key[:-1]) + 1
    else:
        k2 = 7919
    while earlier_access(ins, ii, a, "%du" % k2):
        k2 += 1
    out.append(Mut("bce-other-index", f, (bi, ii), "access l%d[%du] instead of l%d[%s] in `%s` %s" % (a, k2, a, key, line, where), None, need, "error"))
    if re.fullmatch(r"l\d+", key):
        out.append(Mut("bce-after-redef-index", f, (bi, ii), "redefine the index %s before `%s` %s" % (key, line, where), None, need, "error"))
    # positive controls: makeunique of the array, and an access of another index, change neither kind nor length
    if ty is not None and no_ref_alias_of(f, a):
        if a >= f.nparams and certainly_unique(f, bi, ii, a):
            out.append(Mut("bce-makeunique-ok", f, (bi, ii), "makeunique l%d before `%s` %s" % (a, line, where),
                           "positive control: makeunique keeps kind and length", None, "accept"))
        out.append(Mut("bce-other-index-ok", f, (bi, ii), "read l%d[%du] before `%s` %s" % (a, k2, line, where),
                       "positive control: an access of another index changes no length", None, "accept"))
    return out


def apply_bounds(m, f):
    b = f.blocks[m.bi]
    ins = b[1]
    ii = m.ii
    line = ins[ii]
    a, key, val, d = acc_parts(line)
    if m.cls == "bce-no-fact":
        ins[ii] = line.replace("arrayget ", "arraygetu ", 1) if val is None else line.replace("arrayset ", "arraysetu ", 1)
    elif m.cls == "bce-across-push":
        ty = scalar_ty(f, a, key, val, d)
        w = f.new_local(ty)
        ins.insert(ii, "l%d = copy %s" % (w, ZERO[ty]))
        ins.insert(ii + 1, "arraypush l%d, l%d" % (a, w))
    elif m.cls == "bce-after-redef":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, a))
        ins.insert(ii + 1, "l%d = move l%d" % (a, n))
    elif m.cls == "bce-across-block":
        rest = ins[ii:]
        del ins[ii:]
        label = "b%d" % len(f.blocks)
        ins_term = b[2]
        b[2] = "goto %s" % label
        f.blocks.append([label, rest, ins_term])
    elif m.cls == "bce-other-index":
        k2 = re.search(r"\[(\d+)u\] instead", m.desc).group(1) + "u"
        ins[ii] = line.replace("[%s]" % key, "[%s]" % k2, 1)
    elif m.cls == "bce-after-redef-index":
        ins.insert(ii, "%s = copy 0u" % key)
    elif m.cls == "bce-makeunique-ok":
        ins.insert(ii, "makeunique l%d" % a)
    elif m.cls == "bce-other-index-ok":
        k2 = re.search(r"\[(\d+)u\] before", m.desc).group(1) + "u"
        w = f.new_local(scalar_ty(f, a, key, val, d))
        ins.insert(ii, "l%d = arrayget l%d[%s]" % (w, a, k2))
    else:
        raise ValueError(m.cls)
    return f


# ---------------------------------------------------------------- unchecked struct slots (rule U6)

FGET_RE = re.compile(r"l(\d+) = getfieldu? l(\d+)\.(\d+)$")
FSET_RE = re.compile(r"setfieldu? l(\d+)\.(\d+) = (.+)$")


def field_parts(line):
    """(struct local, slot, destination local or None) of a getfield / setfield line (either form)."""
    m = FGET_RE.match(line)
    if m:
        return int(m.group(2)), int(m.group(3)), int(m.group(1))
    m = FSET_RE.match(line)
    if m:
        return int(m.group(1)), int(m.group(2)), None
    return None


def field_slots_before(ins, ii, o):
    """The slots of local o that earlier instructions of the block access (any form)."""
    pat = re.compile(r"(?:l\d+ = (?:getfieldu?|takefield) l%d\.(\d+)$|(?:setfieldu?|putfield) l%d\.(\d+) = |shapecheck l%d\.(\d+)$)" % (o, o, o))
    new = re.compile(r"l%d = struct tag\d+ \{(.*)\}$" % o)
    out = []
    for l in ins[:ii]:
        m = pat.match(l)
        if m:
            out.append(int(m.group(1) or m.group(2) or m.group(3)))
        m = new.match(l)
        if m:
            n = len([x for x in m.group(1).split(", ") if x.strip()])
            if n > 0:
                out.append(n - 1)
    return out


def field_nofact_sites(f, bi, ii, line):
    """A checked field access with no earlier access of the same struct local in its block: making it unchecked is the
    field-no-fact mutant (the optimiser leaves exactly these checked, or those whose sources are too far or too low)."""
    p = field_parts(line)
    if p is None or not f.is_ref(p[0]):
        return []
    o, k, d = p
    ins = f.blocks[bi][1]
    if field_slots_before(ins, ii, o):
        return []
    return [Mut("field-no-fact", f, (bi, ii), "make `%s` unchecked, with no earlier access of l%d in the block (b%d i%d)" % (line, o, bi, ii),
                None, "without a dominating check", "error")]


def field_sites(f, bi, ii, line):
    o, k, d = field_parts(line)
    ins = f.blocks[bi][1]
    where = "(b%d i%d)" % (bi, ii)
    need = "without a dominating check"
    out = [
        Mut("field-after-redef", f, (bi, ii), "redefine l%d before `%s` %s" % (o, line, where), None, need, "error"),
        Mut("field-across-block", f, (bi, ii), "split the block before `%s` %s" % (line, where), None, need, "error"),
    ]
    # a slot above every slot of o that the block has accessed so far: no earlier check covers it
    top = max(field_slots_before(ins, ii, o) + [k])
    out.append(Mut("field-higher-slot", f, (bi, ii), "access slot %d of l%d instead of %d in `%s` %s" % (top + 1, o, k, line, where), None, need, "error"))
    if no_ref_alias_of(f, o) and o >= f.nparams and certainly_unique(f, bi, ii, o):
        out.append(Mut("field-makeunique-ok", f, (bi, ii), "makeunique l%d before `%s` %s" % (o, line, where),
                       "positive control: makeunique keeps kind and slot count", None, "accept"))
    return out


def apply_shape(m, f):
    ins = f.blocks[m.bi][1]
    line = ins[m.ii]
    o, k = (int(x) for x in SHAPE_RE.match(line).groups())
    if m.cls == "shape-drop":
        del ins[m.ii]
    elif m.cls == "shape-too-small":
        ins[m.ii] = "shapecheck l%d.%d" % (o, k - 1)
    else:
        raise ValueError(m.cls)
    return f


SHAPE_RE = re.compile(r"shapecheck l(\d+)\.(\d+)$")


def shape_sites(f, bi, ii, line):
    """A shape check that is the first mention of its struct local in the block (so it alone justifies the unchecked accesses after it):
    dropping it, or checking one slot fewer, must leave an unchecked access unjustified."""
    o, k = (int(x) for x in SHAPE_RE.match(line).groups())
    ins = f.blocks[bi][1]
    if any(o in toks(l) and op(l) != "makeunique" for l in ins[:ii]):
        return []
    if any(dest(l) == o for l in ins[ii + 1:]):
        return []
    if any(re.match(r"(?:l\d+ = )?(?:getfield|takefield|shapecheck|setfield|putfield) l%d\b" % o, l) for l in ins[ii + 1:]):
        return []
    where = "(b%d i%d)" % (bi, ii)
    need = "without a dominating check"
    out = [Mut("shape-drop", f, (bi, ii), "delete `%s` %s" % (line, where), None, need, "error")]
    top = max([int(x) for l in ins[ii + 1:] for x in re.findall(r"(?:getfieldu|setfieldu) l%d\.(\d+)" % o, l)] + [-1])
    if k >= 1 and top == k:
        out.append(Mut("shape-too-small", f, (bi, ii), "check %d slots fewer: `shapecheck l%d.%d` %s" % (1, o, k - 1, where), None, need, "error"))
    return out


def apply_fields(m, f):
    b = f.blocks[m.bi]
    ins = b[1]
    ii = m.ii
    line = ins[ii]
    o, k, d = field_parts(line)
    if m.cls == "field-no-fact":
        ins[ii] = line.replace("getfield ", "getfieldu ", 1) if d is not None else line.replace("setfield ", "setfieldu ", 1)
    elif m.cls == "field-after-redef":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, o))
        ins.insert(ii + 1, "l%d = move l%d" % (o, n))
    elif m.cls == "field-across-block":
        rest = ins[ii:]
        del ins[ii:]
        label = "b%d" % len(f.blocks)
        ins_term = b[2]
        b[2] = "goto %s" % label
        f.blocks.append([label, rest, ins_term])
    elif m.cls == "field-higher-slot":
        k2 = int(re.search(r"access slot (\d+) of", m.desc).group(1))
        ins[ii] = line.replace(".%d" % k, ".%d" % k2, 1)
    elif m.cls == "field-makeunique-ok":
        ins.insert(ii, "makeunique l%d" % o)
    else:
        raise ValueError(m.cls)
    return f


# ---------------------------------------------------------------- range facts (rule U1, interval fact)

ARRAYNEW_RE = re.compile(r"l\d+ = arraynew \w+ \[(.*)\]$")
CMP_RE = re.compile(r"l(\d+) = (lt|le|gt|ge|eq|ne) (\S+), (\S+)$")
BRANCH_RE = re.compile(r"branch l(\d+) \? b\d+ : b\d+$")


def arr_len(f, a, depth=0):
    """The element count of array local a when every definition of it in f is an `arraynew` of the same count (looking
    through moves), else None (a parameter, a call result, a field ...)."""
    if depth > 4 or a < f.nparams:
        return None
    lens = set()
    for _, ins, _t in f.blocks:
        for line in ins:
            if dest(line) != a:
                continue
            m = ARRAYNEW_RE.match(line)
            if m:
                body = m.group(1).strip()
                lens.add(0 if not body else body.count(",") + 1)
                continue
            m = re.match(r"l\d+ = move l(\d+)$", line)
            if m:
                n = arr_len(f, int(m.group(1)), depth + 1)
                if n is None:
                    return None
                lens.add(n)
                continue
            return None
    return lens.pop() if len(lens) == 1 else None


def bound_is_len(f, x, n, a):
    """The operand text x is the length n of array a: the constant `n`u, or a local all of whose definitions are `copy nu` or
    `arr.length(a')` of an array of that length."""
    if re.fullmatch(r"\d+u", x):
        return int(x[:-1]) == n
    if not re.fullmatch(r"l\d+", x):
        return False
    xl = int(x[1:])
    found = False
    for _, ins, _t in f.blocks:
        for line in ins:
            if dest(line) != xl:
                continue
            m = re.match(r"l\d+ = copy (\d+)u$", line)
            if m and int(m.group(1)) == n:
                found = True
                continue
            m = re.match(r"l\d+ = builtin arr\.length\(l(\d+)\)$", line)
            if m and arr_len(f, int(m.group(1))) == n:
                found = True
                continue
            return False
    return found


def has_store(f, a):
    """Some instruction of f stores into, takes from or puts into the array local a (it must stay Unique for that)."""
    for _, ins, _t in f.blocks:
        for line in ins:
            if store_obj(line) == a:
                return True
    return False


def branch_cmps(f, k):
    """[(block, instruction)] of the compares with local k as an operand whose result is the condition of the branch ending its block."""
    out = []
    for bi, (_l, ins, term) in enumerate(f.blocks):
        bm = BRANCH_RE.match(term)
        if not bm:
            continue
        for ii, line in enumerate(ins):
            m = CMP_RE.match(line)
            if m and m.group(1) == bm.group(1) and ("l%d" % k) in (m.group(3), m.group(4)):
                out.append((bi, ii))
    return out


def is_counter(f, k):
    """The local k is stepped by an `add` of itself somewhere in f (a loop counter)."""
    pat = re.compile(r"l%d = add l%d, " % (k, k))
    return any(pat.match(line) for _, ins, _t in f.blocks for line in ins)


def off_by_one(f, line, k, n, a):
    """The compare line with its bound made one too large, or None when it is not a compare of the counter k against the length n."""
    m = CMP_RE.match(line)
    if not m:
        return None
    c, op, x, y = m.group(1), m.group(2), m.group(3), m.group(4)
    kk = "l%d" % k
    if op == "lt" and x == kk and bound_is_len(f, y, n, a):
        return "l%s = le %s, %s" % (c, x, y)
    if op == "le" and x == kk and re.fullmatch(r"\d+u", y) and int(y[:-1]) + 1 == n:
        return "l%s = le %s, %du" % (c, x, n)
    if op == "gt" and y == kk and bound_is_len(f, x, n, a):
        return "l%s = ge %s, %s" % (c, x, y)
    if op == "ge" and y == kk and re.fullmatch(r"\d+u", x) and int(x[:-1]) + 1 == n:
        return "l%s = ge %du, %s" % (c, n, y)
    return None


def array_defs(f, a, depth=0):
    """[(block, instruction)] of the `arraynew` lines that build array local a (through moves); [] when a has another kind of definition."""
    if depth > 4 or a < f.nparams:
        return []
    out = []
    for bi, (_l, ins, _t) in enumerate(f.blocks):
        for ii, line in enumerate(ins):
            if dest(line) != a:
                continue
            if ARRAYNEW_RE.match(line):
                out.append((bi, ii))
                continue
            m = re.match(r"l\d+ = move l(\d+)$", line)
            if not m:
                return []
            sub = array_defs(f, int(m.group(1)), depth + 1)
            if not sub:
                return []
            out += sub
    return out


def guards_block(f, cbi, cii, bi):
    """The compare at (cbi, cii) is the condition of the branch ending its block and every path from the entry to block bi takes
    its true edge (bi is dominated by the true successor), so loosening it changes what the access in bi can be proved from."""
    bm = BRANCH_RE.match(f.blocks[cbi][2])
    cm = CMP_RE.match(f.blocks[cbi][1][cii])
    if not bm or not cm or cm.group(1) != bm.group(1):
        return False
    t = succs(f.blocks[cbi][2])[0]
    if bi == t:
        return True
    seen, work = set(), [0]
    while work:
        b = work.pop()
        if b in seen or b == t:
            continue
        seen.add(b)
        work += succs(f.blocks[b][2])
    return bi not in seen


def range_sites(f, bi, ii, line):
    """Mutants of an unchecked access that only the interval analysis justifies."""
    a, key, val, d = acc_parts(line)
    where = "(b%d i%d)" % (bi, ii)
    need = "without a dominating check"
    out = []

    def mut(cls, loc, desc, expect="error", benign=None, arg=None):
        m = Mut(cls, f, loc, "%s `%s` %s" % (desc, line, where), benign, need if expect == "error" else None, expect)
        m.arg = arg
        out.append(m)

    ty = scalar_ty(f, a, key, val, d)
    n = arr_len(f, a)
    if ty is not None:
        mut("range-after-push", (bi, ii), "arraypush l%d before" % a)
    mut("range-after-pop", (bi, ii), "arraypop l%d before" % a)
    mut("range-across-dup", (bi, ii), "dup l%d before" % a)
    mut("range-after-redef-array", (bi, ii), "redefine l%d before" % a)
    if d is not None and not has_store(f, a):
        mut("range-after-inout-call", (bi, ii), "in/out call on l%d before" % a)
    defs = array_defs(f, a)
    if defs and n is not None:
        mut("range-param-array", defs[0], "build l%d by a call instead of arraynew, for" % a, arg=defs)
    if re.fullmatch(r"l\d+", key):
        k = int(key[1:])
        mut("range-after-redef-index", (bi, ii), "give the index %s an unknown value before" % key)
        mut("range-index-add-large", (bi, ii), "add 1000000u to the index %s before" % key)
        if is_counter(f, k):
            cm = branch_cmps(f, k)
            if cm:
                mut("range-no-branch-refinement", cm[0], "replace the compares of the counter %s, guarding" % key, arg=cm)
        if n is not None:
            seen = set()
            for cbi, (_l, ins, _t) in enumerate(f.blocks):
                for cii, cl in enumerate(ins):
                    nl = off_by_one(f, cl, k, n, a)
                    if nl is not None and (cbi, cii) not in seen and guards_block(f, cbi, cii, bi):
                        seen.add((cbi, cii))
                        mut("range-widen-off-by-one", (cbi, cii), "loosen the bound `%s` of the guard of" % cl, arg=nl)
        if ty is not None and True:
            mut("range-copy-index-ok", (bi, ii), "read the index %s through a copy, in" % key, "accept",
                "positive control: a copy keeps the interval")
            mut("range-addsub-ok", (bi, ii), "read the index %s through (i + 1) - 1, in" % key, "accept",
                "positive control: add and sub of constants transfer the interval")
    if a >= f.nparams and no_ref_alias_of(f, a):
        mut("range-move-roundtrip-ok", (bi, ii), "move l%d away and back before" % a, "accept",
            "positive control: a move carries the length fact")
        if d is not None and not has_store(f, a):
            mut("range-borrowed-call-ok", (bi, ii), "call a function that borrows l%d before" % a, "accept",
                "positive control: a borrowed argument cannot change the length")
    return out


def stub_func(f, k, header_tail, locals_):
    """A stub function appended to the program: index len(funcs) + k (`header_tail`: everything after its name)."""
    return (header_tail, locals_, k)


def apply_range(m, f):
    b = f.blocks[m.bi]
    ins = b[1]
    ii = m.ii
    cls = m.cls
    if cls == "range-widen-off-by-one":
        ins[ii] = m.arg
        return f
    if cls == "range-no-branch-refinement":
        for cbi, cii in m.arg:
            c = dest(f.blocks[cbi][1][cii])
            f.blocks[cbi][1][cii] = "l%d = copy true" % c
        return f
    if cls == "range-param-array":
        f.extra.append(("__mk", "(params 0) -> ref", [("l0", "ref")]))
        for dbi, dii in m.arg:
            dl = f.blocks[dbi][1]
            dd = dest(dl[dii])
            dl[dii] = "l%d = call fnEXTRA0()" % dd
            dl.insert(dii + 1, "makeunique l%d" % dd)
        return f
    line = ins[ii]
    a, key, val, d = acc_parts(line)
    if cls == "range-after-push":
        ty = scalar_ty(f, a, key, val, d)
        w = f.new_local(ty)
        ins.insert(ii, "l%d = copy %s" % (w, ZERO[ty]))
        ins.insert(ii + 1, "arraypush l%d, l%d" % (a, w))
    elif cls == "range-after-pop":
        n = f.new_local()
        ins.insert(ii, "l%d = arraypop l%d" % (n, a))
    elif cls == "range-across-dup":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, a))
    elif cls == "range-after-redef-array":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, a))
        ins.insert(ii + 1, "l%d = move l%d" % (a, n))
    elif cls == "range-after-inout-call":
        f.extra.append(("__io", "(params 1, owned l0, inout) -> int", [("l0", "ref")]))
        n = f.new_local("int")
        ins.insert(ii, "l%d = call fnEXTRA0(l%d)" % (n, a))
    elif cls == "range-after-redef-index":
        s_ = f.new_local("ref")
        ins.insert(ii, "l%d = copy str#0" % s_)
        ins.insert(ii + 1, "%s = builtin str.length(l%d)" % (key, s_))
    elif cls == "range-index-add-large":
        ins.insert(ii, "%s = add %s, 1000000u" % (key, key))
    elif cls == "range-move-roundtrip-ok":
        n = f.new_local()
        ins.insert(ii, "l%d = move l%d" % (n, a))
        ins.insert(ii + 1, "l%d = move l%d" % (a, n))
    elif cls == "range-borrowed-call-ok":
        f.extra.append(("__borrow", "(params 1) -> void", [("l0", "ref")]))
        ins.insert(ii, "call fnEXTRA0(l%d)" % a)
    elif cls == "range-copy-index-ok":
        n = f.new_local("usize")
        ins.insert(ii, "l%d = copy %s" % (n, key))
        ins[ii + 1] = line.replace("[%s]" % key, "[l%d]" % n, 1)
    elif cls == "range-addsub-ok":
        n = f.new_local("usize")
        n2 = f.new_local("usize")
        ins.insert(ii, "l%d = add %s, 1u" % (n, key))
        ins.insert(ii + 1, "l%d = sub l%d, 1u" % (n2, n))
        ins[ii + 2] = line.replace("[%s]" % key, "[l%d]" % n2, 1)
    else:
        raise ValueError(cls)
    return f


def unique_call_sites(f, bi, ii, line):
    """v2.7, rules U4 / U5: the mutants at a call of an in/out or unique-out function."""
    g, args = call_parts(f, line)
    if g is None:
        return []
    n = int(CALL_RE.match(line).group(1))
    ins = f.blocks[bi][1]
    where = "(b%d i%d)" % (bi, ii)
    out = []
    x = args[0] if g.inout and args and args[0] is not None else None
    if x is not None and not g.uin:
        if g is f:
            # a self-recursive call: the flipped flag also makes the receiver Unique on entry (rule U2), so judge the call
            # with the mutated entry state
            f.uin = True
            ok = x in uniq_at(f, bi, ii)
            f.uin = False
        else:
            ok = certainly_unique(f, bi, ii, x)
        benign = "the receiver is certainly Unique at the call, so the flag would be justified here" if ok else None
        out.append(Mut("uniq-flag-flip-in", f, (bi, ii), "`unique-in` on fn%d for `%s` %s" % (n, line, where), benign,
                       "to be Unique", "error", peer=(n, "unique-in")))
    if x is not None and g.uin:
        out.append(Mut("uniq-in-shared-caller", f, (bi, ii), "dup l%d before `%s` %s" % (x, line, where), None, "to be Unique", "error"))
    if g.uout:
        target = x if g.inout else dest(line)
        if target is not None and f.is_ref(target):
            later = None
            cur = target
            for k in range(ii + 1, len(ins)):
                l2 = ins[k]
                if cur not in toks(l2):
                    continue
                if store_obj(l2) == cur:
                    later = k
                elif op(l2) in KEEP_READS and dest(l2) != cur and cur in toks(l2)[1:]:
                    continue
                elif op(l2) == "move" and toks(l2)[1] == cur and dest(l2) != cur:
                    cur = dest(l2)   # the dup'd object is moved on: it stays shared, and a store through the copy fails the same way
                    continue
                break
            if later is not None:
                out.append(Mut("uniq-out-then-dup", f, (bi, ii), "dup l%d after `%s`, before `%s` %s" % (target, line, ins[later], where),
                               None, "to be Unique", "error"))
    return out


def unique_out_sites(f):
    """v2.7, rule U3: `unique-out` on a function whose returns are not all Unique."""
    if f.uout or not (f.inout or f.ret == "ref"):
        return []
    states = uniq_states(f)
    all_unique, any_return = True, False
    for b, (label, ins, term) in enumerate(f.blocks):
        if not term.startswith("return") or states[b] is None:
            continue
        any_return = True
        U = states[b]
        for line in ins:
            U = uniq_transfer(f, U, line)
        m = re.match(r"return l(\d+)$", term)
        target = 0 if f.inout else (int(m.group(1)) if m else None)
        if target is None or target not in U:
            all_unique = False
    benign = None
    if not any_return:
        benign = "no return is reachable"
    elif all_unique:
        benign = "every return hands back a Unique value by the independent dataflow"
    return [Mut("uniq-flag-flip-out", f, (0, 0), "`unique-out` on %s" % f.name, benign, "(rule U3)", "error", flag="unique-out")]


def apply_forward(m, f):
    b = f.blocks[m.bi]
    ins = b[1]
    ii = m.ii
    d, s_, o, key = fwd_parts(ins[ii])
    kind = fwd_kind(ins, ii, o, key)
    if m.cls == "fwd-across-write":
        # a store of s itself would be a source of the claim, so the write stores another value
        w = f.new_local(f.locals[s_][1])
        ins.insert(ii, "l%d = copy %s" % (w, ZERO[f.locals[s_][1]]))
        ins.insert(ii + 1, "setfield l%d.%s = l%d" % (o, key[:-1], w) if kind == "field" else "arrayset l%d[%s] = l%d" % (o, key, w))
    elif m.cls == "fwd-other-slot-ok":
        # a slot no instruction of the function reads or writes, so no other forward depends on it
        k2 = slot_span(f, o)[0] + 1
        ins.insert(ii, "setfield l%d.%d = l%d" % (o, k2, s_) if kind == "field" else "arrayset l%d[%du] = l%d" % (o, k2, s_))
    elif m.cls == "fwd-after-redef-obj":
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, o))
        ins.insert(ii + 1, "l%d = move l%d" % (o, n))
    elif m.cls == "fwd-after-redef-src":
        ins.insert(ii, "l%d = copy %s" % (s_, ZERO[f.locals[s_][1]]))
    elif m.cls == "fwd-across-push":
        ins.insert(ii, "arraypush l%d, l%d" % (o, s_))
    elif m.cls == "fwd-wrong-slot":
        k2 = "%du" % (int(key[:-1]) + 1) if key.endswith("u") else "0u"
        ins[ii] = "l%d = forward l%d, l%d[%s]" % (d, s_, o, k2)
    elif m.cls == "fwd-across-block":
        rest = ins[ii:]
        del ins[ii:]
        label = "b%d" % len(f.blocks)
        ins_term = b[2]
        b[2] = "goto %s" % label
        f.blocks.append([label, rest, ins_term])
    else:
        raise ValueError(m.cls)
    return f


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
    if m.cls.startswith("range-"):
        return apply_range(m, f)
    if m.cls == "uniq-flag-flip-out":
        return f.with_flag("unique-out")
    if m.cls == "uniq-flag-flip-in":
        return f
    if m.cls in ("uniq-in-shared-caller", "uniq-out-then-dup"):
        line = ins[ii]
        g, args = call_parts(f, line)
        x = args[0] if g.inout else dest(line)
        n = f.new_local()
        ins.insert(ii if m.cls == "uniq-in-shared-caller" else ii + 1, "l%d = dup l%d" % (n, x))
        return f
    line = ins[ii]
    t = toks(line)
    if m.cls.startswith("fwd-"):
        return apply_forward(m, f)
    if m.cls.startswith("bce-"):
        return apply_bounds(m, f)
    if m.cls.startswith("field-"):
        return apply_fields(m, f)
    if m.cls.startswith("shape-"):
        return apply_shape(m, f)
    if m.cls.startswith("range-"):
        return apply_range(m, f)
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
    elif m.cls in ("store-shared-dup", "dup-before-store-after-drop"):
        x = store_obj(line)
        n = f.new_local()
        ins.insert(ii, "l%d = dup l%d" % (n, x))
    elif m.cls == "store-shared-alias":
        x = store_obj(line)
        n = f.new_local()
        ins[ii] = replace_obj(line, x, n)
        ins.insert(ii, "l%d = borrow l%d" % (n, x))
    elif m.cls in ("drop-makeunique", "redundant-makeunique-census"):
        del ins[ii]
    elif m.cls == "append-after-release":
        ins.insert(ii, "release l%d" % t[0])
    elif m.cls == "append-borrowed":
        n = f.new_local()
        ins[ii] = replace_obj_first(line, t[0], n)
        ins.insert(ii, "l%d = borrow l%d" % (n, t[0]))
    elif m.cls == "append-kills-borrow":
        n = f.new_local()
        ins.insert(ii, "l%d = borrow l%d" % (n, t[0]))
        n2 = f.new_local()
        ins.insert(ii + 2, "l%d = borrow l%d" % (n2, n))
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
    subprocess.run(["cc", "-O1", "-w", *rt_inc(), c, *rt_src(), "-lm", "-o", exe], cwd=ROOT, check=True)
    return exe


BATCH_BYTES = 48 << 20   # a driver run holds ~4.5x its input file in RSS: peak memory is bounded by this, not by the corpus


def run_driver(exe, items, tmp, tag, extra=()):
    """Run the batch driver over `items` ((name, text) pairs, a lazy iterable) in batches of about BATCH_BYTES, a few at a time,
    and return the stdout lines of all batches. The corpus is >3 GB of program text; verify_text reads a file into one string and
    splits it into lines, so a single run over all of it needs >14 GB."""
    jobs = max(1, min(int(os.environ.get("ORIN_JOBS") or os.cpu_count() or 4), 4))
    lines = []

    def one(path):
        r = subprocess.run([exe, path, *extra], capture_output=True, text=True, errors="replace", timeout=1800)
        os.remove(path)
        if r.returncode != 0:
            sys.exit("verify_text failed: " + r.stderr[:500])
        return r.stdout.splitlines()

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        pending, buf, size, n = [], [], 0, 0
        for name, text in items:
            buf.append("=== %s\n%s" % (name, text))
            size += len(text)
            if size >= BATCH_BYTES:
                path = os.path.join(tmp, "%s%d.txt" % (tag, n))
                with open(path, "w", errors="surrogateescape") as fh:
                    fh.writelines(buf)
                buf, size, n = [], 0, n + 1
                pending.append(pool.submit(one, path))
                while len(pending) > jobs:   # bound the files and processes in flight
                    lines.extend(pending.pop(0).result())
        if buf:
            path = os.path.join(tmp, "%s%d.txt" % (tag, n))
            with open(path, "w", errors="surrogateescape") as fh:
                fh.writelines(buf)
            pending.append(pool.submit(one, path))
        for f in pending:
            lines.extend(f.result())
    return lines


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
    # MIR string constants are raw bytes (e.g. folded String.fromCharCode(0x80)); keep them byte-exact.
    r = subprocess.run([orinc, "mir", os.path.relpath(path, ROOT)], cwd=ROOT, capture_output=True, text=True,
                       errors="surrogateescape", timeout=600)
    return r.stdout if r.returncode == 0 else None


def program_text(prefix, funcs, target_idx, target):
    parts = [prefix, "\n"]
    for i, f in enumerate(funcs):
        parts.append(target.render() if i == target_idx else f.stub())
        parts.append("\n")
    for k, (name, tail, locs) in enumerate(target.extra):
        hdr = "fn%d %s %s" % (len(funcs) + k, name, tail)
        parts.append(Func(hdr, locs, [["b0", [], 'trap "stub"']]).render().replace("fnEXTRA0", "fn%d" % len(funcs)))
        parts.append("\n")
    return "".join(parts).replace("fnEXTRA0", "fn%d" % len(funcs))


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
    with ThreadPoolExecutor(max_workers=int(os.environ.get("ORIN_JOBS") or os.cpu_count() or 4)) as pool:
        mirs = list(pool.map(lambda f: mir_of(a.orinc, f), files))
    seen = {}
    nprog = 0
    for f, text in zip(files, mirs):
        if text is None:
            print("warning: no MIR for %s" % os.path.relpath(f, ROOT))
            continue
        nprog += 1
        prefix, funcs = parse(text)
        for fn in funcs:
            fn.peers = funcs
        for i, fn in enumerate(funcs):
            k = fn.key()
            if k not in seen:
                seen[k] = (prefix, funcs, i)
    print("corpus: %d programs, %d distinct functions (%.1fs)" % (nprog, len(seen), time.time() - t0))

    tmpdir = tempfile.TemporaryDirectory()
    tmp = tmpdir.name
    exe = a.verify_text or build_driver(a.orinc, tmp)

    # the fact (dominated-by-check / interval / both) behind every unchecked access of every baseline function
    facts_out = run_driver(exe, (("base%d" % n, program_text(prefix, funcs, i, funcs[i]))
                                 for n, (k, (prefix, funcs, i)) in enumerate(sorted(seen.items()))), tmp, "facts", ("--facts",))
    keys = sorted(seen.items())
    for line in facts_out:
        p = line.split("\t")
        n = int(p[0][4:])
        ti = keys[n][1][2]
        for tok in p[2:]:
            m = re.fullmatch(r"f(\d+):b(\d+):i(\d+):(.*)", tok)
            if m and int(m.group(1)) == ti:
                FACTS[(keys[n][0], int(m.group(2)), int(m.group(3)))] = m.group(4)
    kinds = {}
    for v in FACTS.values():
        kinds[v] = kinds.get(v, 0) + 1
    print("unchecked accesses by fact: %s" % ", ".join("%s %d" % kv for kv in sorted(kinds.items())))

    meta = {}

    def entries():   # lazy: the texts are >3 GB in all and are never held together
        for n, (k, (prefix, funcs, i)) in enumerate(sorted(seen.items())):
            fn = funcs[i]
            bid = "base%d" % n
            meta[bid] = ("base", fn, None)
            yield bid, program_text(prefix, funcs, i, fn)
            for mi, m in enumerate(sites(fn)):
                mf = apply(m)
                mid = "m%d_%d" % (n, mi)
                meta[mid] = ("mut", fn, m)
                fs = funcs
                if m.peer:
                    fs = list(funcs)
                    fs[m.peer[0]] = funcs[m.peer[0]].with_flag(m.peer[1])
                    if m.peer[0] == i:
                        # a self-recursive call: the target is rendered in full, not as a stub, so it carries the flag itself
                        mf = mf.with_flag(m.peer[1])
                yield mid, program_text(prefix, fs, i, mf)

    out_lines = run_driver(exe, entries(), tmp, "mutants")
    tmpdir.cleanup()
    res = {}
    for line in out_lines:
        p = line.split("\t")
        res[p[0]] = (p[1], int(p[2]), p[3:])
    if len(res) != len(meta):
        sys.exit("driver returned %d results for %d entries" % (len(res), len(meta)))

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
        if m.expect == "accept" and verdict == "REJECT":
            # a positive control that the verifier rejects: the rule is too strict (or the mutation invalid)
            s["wrong"] += 1
            wrong.append((m, errs))
        elif verdict == "REJECT":
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
