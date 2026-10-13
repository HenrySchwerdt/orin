#!/usr/bin/env python3
"""Mutation check for the provable std modules (ADR-0030 §3, ADR-0028).

Each mutant is a one-line, deliberately wrong change of stdlib/{bytes,utf8,collections}.or. The module and its
test file are copied to build/mutate_std/, the std imports are rewritten to relative ones, the mutation is applied and
`orin test` is run twice: with runtime contract checking (the default) and with `--no-contracts`. A mutant is
killed when a test fails. It is "killed by a contract" when a failing test's stderr says `contract violated`.

Usage: python3 tools/mutate_std.py [--orinc build/bootstrap/orin2] [--module bytes|utf8|collections] [--list]
Exit status 1 if any mutant survives (is not killed with contracts on).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "mutate_std")

# (module, name, old text (must occur exactly once), new text[, expect-trap test in tests/std/expect_trap/])
# An expect-trap test must FAIL (trap) on the real code; a mutant that makes it pass is killed.
MUTANTS = [
    # ---- std:bytes
    ("bytes", "slice-offset-ignored", "return new Bytes(this.data, this.start + lo, hi - lo);", "return new Bytes(this.data, this.start, hi - lo);"),
    ("bytes", "slice-length-off-by-one", "return new Bytes(this.data, this.start + lo, hi - lo);", "return new Bytes(this.data, this.start + lo, hi - lo + 1);"),
    ("bytes", "concat-drops-last-byte", "while (j < other.length()) {\n      out.push(other.at(j));", "while (j + 1 < other.length()) {\n      out.push(other.at(j));"),
    ("bytes", "equals-ignores-last-byte", "    let i: usize = 0;\n    while (i < this.len) {\n      if (this.data[this.start + i] != other.at(i)) {", "    let i: usize = 0;\n    while (i + 1 < this.len) {\n      if (this.data[this.start + i] != other.at(i)) {"),
    ("bytes", "u16be-wrong-byte-order", "return Ok((a * 256 + b).toU16());", "return Ok((b * 256 + a).toU16());"),
    ("bytes", "u8-advances-two", "    const v = this.src.at(this.pos);\n    this.pos += 1;", "    const v = this.src.at(this.pos);\n    this.pos += 2;"),
    ("bytes", "read-past-end-u16", "    if (this.src.length() - this.pos < 2) {\n      return Err(this.shortRead(2));\n    }\n    const a = this.src.at(this.pos).toInt();\n    const b = this.src.at(this.pos + 1).toInt();\n    this.pos += 2;\n    return Ok((a * 256 + b).toU16());", "    if (this.src.length() - this.pos < 1) {\n      return Err(this.shortRead(2));\n    }\n    const a = this.src.at(this.pos).toInt();\n    const b = this.src.at(this.pos + 1).toInt();\n    this.pos += 2;\n    return Ok((a * 256 + b).toU16());"),
    ("bytes", "readExact-does-not-advance", "    const out = this.src.slice(this.pos, this.pos + n);\n    this.pos += n;", "    const out = this.src.slice(this.pos, this.pos + n);"),
    ("bytes", "failed-read-moves-cursor", "      return Err(this.shortRead(4));\n    }\n    const a = this.src.at(this.pos).toInt();\n    const b = this.src.at(this.pos + 1).toInt();\n    const c = this.src.at(this.pos + 2).toInt();\n    const d = this.src.at(this.pos + 3).toInt();\n    this.pos += 4;\n    return Ok((((a * 256", "      this.pos = this.src.length();\n      return Err(this.shortRead(4));\n    }\n    const a = this.src.at(this.pos).toInt();\n    const b = this.src.at(this.pos + 1).toInt();\n    const c = this.src.at(this.pos + 2).toInt();\n    const d = this.src.at(this.pos + 3).toInt();\n    this.pos += 4;\n    return Ok((((a * 256"),
    ("bytes", "u32le-high-byte-first", "    this.data.push((n % 256).toU8());\n    this.data.push(((n / 256) % 256).toU8());\n    this.data.push(((n / 65536) % 256).toU8());\n    this.data.push((n / 16777216).toU8());", "    this.data.push((n / 16777216).toU8());\n    this.data.push(((n / 256) % 256).toU8());\n    this.data.push(((n / 65536) % 256).toU8());\n    this.data.push((n % 256).toU8());"),
    ("bytes", "builder-drops-string-tail", "    while (i < s.length) {\n      this.data.push(s.charCodeAt(i).toU8());\n      i += 1;\n    }\n    this.grew();\n  }\n\n  // clear()", "    while (i + 1 < s.length) {\n      this.data.push(s.charCodeAt(i).toU8());\n      i += 1;\n    }\n    this.grew();\n  }\n\n  // clear()"),
    ("bytes", "reserve-forgets-extra", "this.capacity = this.data.length + extra;", "this.capacity = this.data.length;"),
    # ---- std:utf8
    ("utf8", "accepts-overlong-E0", "    if (c == 224) {\n      lo2 = 160;\n    }", "    if (c == 224) {\n      lo2 = 128;\n    }"),
    ("utf8", "accepts-overlong-F0", "    if (c == 240) {\n      lo2 = 144;\n    }", "    if (c == 240) {\n      lo2 = 128;\n    }"),
    ("utf8", "accepts-surrogates", "    if (c == 237) {\n      hi2 = 159;\n    }", "    if (c == 237) {\n      hi2 = 191;\n    }"),
    ("utf8", "accepts-above-10FFFF", "    if (c == 244) {\n      hi2 = 143;\n    }", "    if (c == 244) {\n      hi2 = 191;\n    }"),
    ("utf8", "accepts-C0-C1", "  if (c < 194) {\n    return badSeq(1, Overlong);\n  }", "  if (c < 192) {\n    return badSeq(1, Overlong);\n  }"),
    ("utf8", "accepts-F5-and-up", "  if (c >= 245) {", "  if (c >= 248) {"),
    ("utf8", "error-position-off-by-one", "return Err(Utf8Error { position: i, length: q.len, kind: q.kind.unwrap() });", "return Err(Utf8Error { position: i + 1, length: q.len, kind: q.kind.unwrap() });"),
    ("utf8", "isScalarValue-allows-surrogates", "(cp >= 57344 && cp <= 1114111)", "(cp >= 55296 && cp <= 1114111)"),
    ("utf8", "encode-2byte-lead-wrong", "return Some(String.fromCharCode(192 + cp / 64) + String.fromCharCode(128 + cp % 64));", "return Some(String.fromCharCode(128 + cp / 64) + String.fromCharCode(128 + cp % 64));"),
    ("utf8", "encode-4byte-middle-wrong", "String.fromCharCode(128 + (cp / 4096) % 64)\n    + String.fromCharCode(128 + (cp / 64) % 64) + String.fromCharCode(128 + cp % 64));\n}", "String.fromCharCode(128 + (cp / 4096) % 32)\n    + String.fromCharCode(128 + (cp / 64) % 64) + String.fromCharCode(128 + cp % 64));\n}"),
    ("utf8", "utf8Len-boundary", "  if (cp < 2048) {\n    return 2;\n  }", "  if (cp < 2047) {\n    return 2;\n  }"),
    ("utf8", "cursor-advances-one-byte", "this.pos += utf8Len(c.unwrap()).toUsize();", "this.pos += 1;"),
    ("utf8", "boundary-test-inverted", "    return !isCont(this.text.charCodeAt(i));\n  }\n\n  // codePointAt", "    return isCont(this.text.charCodeAt(i));\n  }\n\n  // codePointAt"),
    ("utf8", "constructor-skips-validation", "    this.text = checked(text);", "    this.text = text;", "utf8_ctor_rejects_invalid"),
    ("utf8", "count-counts-continuation-bytes", "    if (!isCont(s.charCodeAt(i))) {\n      n += 1;\n    }", "    if (isCont(s.charCodeAt(i))) {\n      n += 1;\n    }"),
    # ---- std:collections
    ("collections", "intset-add-always-true", "    if (this.items.has(x)) {\n      return false;\n    }\n    this.items.set(x, true);\n    return true;\n  }\n\n  // remove(x): delete x; true when it was a member (the size shrinks by 1). Expected O(1).\n  @Ensures(!this.has(x))\n  @Ensures(result == old(this.has(x)))\n  @Ensures(result ==> this.size() == old(this.size()) - 1)\n  @Ensures(!result ==> this.size() == old(this.size()))\n  remove(x: int)", "    this.items.set(x, true);\n    return true;\n  }\n\n  // remove(x): delete x; true when it was a member (the size shrinks by 1). Expected O(1).\n  @Ensures(!this.has(x))\n  @Ensures(result == old(this.has(x)))\n  @Ensures(result ==> this.size() == old(this.size()) - 1)\n  @Ensures(!result ==> this.size() == old(this.size()))\n  remove(x: int)"),
    ("collections", "intset-remove-forgets-delete", "    this.items.delete(x);\n    return true;\n  }\n\n  // clear(): remove all members. O(1).\n  @Ensures(this.size() == 0)\n  clear(): void {\n    this.items = new Map<int, bool>();", "    return true;\n  }\n\n  // clear(): remove all members. O(1).\n  @Ensures(this.size() == 0)\n  clear(): void {\n    this.items = new Map<int, bool>();"),
    ("collections", "intset-union-drops-other", "    const ys = other.toArray();\n    let j: usize = 0;\n    while (j < ys.length) {\n      out.add(ys[j]);\n      j += 1;\n    }\n    return out;\n  }\n\n  // intersection(other): the members of both. O(n).\n  @Ensures(result.isSubsetOf(this) && result.isSubsetOf(other))\n  @Ensures(result.size() <= this.size() && result.size() <= other.size())\n  intersection(other: IntSet)", "    return out;\n  }\n\n  // intersection(other): the members of both. O(n).\n  @Ensures(result.isSubsetOf(this) && result.isSubsetOf(other))\n  @Ensures(result.size() <= this.size() && result.size() <= other.size())\n  intersection(other: IntSet)"),
    ("collections", "deque-pushFront-head-off-by-one", "this.head = (this.head + cap - 1) % cap;", "this.head = (this.head + cap) % cap;"),
    ("collections", "deque-popFront-keeps-slot", "    const none: Option<T> = None;\n    this.buf[this.head] = none;\n    this.head = (this.head + 1) % this.buf.length;", "    this.head = (this.head + 1) % this.buf.length;"),
    ("collections", "deque-grow-no-copy-wrap", "nb.push(this.buf[(this.head + i) % cap]);", "nb.push(this.buf[i]);"),
    ("collections", "deque-popBack-wrong-slot", "const at = (this.head + this.len - 1) % this.buf.length;", "const at = (this.head + this.len) % this.buf.length;"),
    ("collections", "compareStrings-prefix-order", "  if (a.length < b.length) {\n    return -1;\n  }\n  if (a.length > b.length) {\n    return 1;\n  }\n  return 0;", "  if (a.length < b.length) {\n    return 1;\n  }\n  if (a.length > b.length) {\n    return -1;\n  }\n  return 0;"),
    # ---- std:utf8, table-driven validator
    ("utf8", "dfa-ascii-run-accepts-0x80", "while (i < n && s.charCodeAt(i) < 128) {", "while (i < n && s.charCodeAt(i) < 129) {"),
    ("utf8", "dfa-error-position-is-end", "      if (st != 0) {\n        return start;", "      if (st != 0) {\n        return i;"),
    ("utf8", "dfa-table-rejects-ED", "\\x00\\x0c\\x18\\x24\\x3c\\x60", "\\x00\\x0c\\x18\\x24\\x0c\\x60"),
    ("utf8", "dfa-stops-after-accept-missing", "        if (st <= 12) {\n          break;", "        if (st < 12) {\n          break;"),
    # ---- std:collections, B-tree (first occurrence = the int-keyed SortedMap)
    ("collections", "btree-put-never-splits-children", "      if (this.nodes[this.nodes[x].kids[i]].keys.length == maxKeys) {", "      if (this.nodes[this.nodes[x].kids[i]].keys.length > maxKeys) {"),
    ("collections", "btree-split-wrong-median", "const med = yk[t - 1];", "const med = yk[t];"),
    ("collections", "btree-root-never-splits", "if (this.nodes[this.root].keys.length == maxKeys) {", "if (this.nodes[this.root].keys.length > maxKeys) {"),
    ("collections", "btree-borrow-from-minimal-sibling", "if (ci < len && this.nodes[this.nodes[x].kids[ci + 1]].keys.length >= t) {", "if (ci < len && this.nodes[this.nodes[x].kids[ci + 1]].keys.length >= t - 1) {"),
    ("collections", "btree-merge-leaks-node", "    this.removeKid(x, i + 1);\n    this.release(z);", "    this.removeKid(x, i + 1);"),
    ("collections", "btree-root-not-shrunk", "    if (x == this.root && this.nodes[x].keys.length == 0) {\n      this.root = y;\n      this.release(x);\n    }", "    if (x == this.root && this.nodes[x].keys.length == 0) {\n      this.release(x);\n    }"),
    ("collections", "btree-remove-forgets-count", "          this.removeKey(x, i);\n          this.count -= 1;", "          this.removeKey(x, i);"),
    ("collections", "btree-remove-predecessor-key-kept", "          this.nodes[x].keys[i] = this.nodes[w].keys[last];\n          this.nodes[x].vals[i] = this.nodes[w].vals[last];\n          target = this.nodes[w].keys[last];", "          this.nodes[x].keys[i] = this.nodes[w].keys[last];\n          this.nodes[x].vals[i] = this.nodes[w].vals[last];"),
    ("collections", "btree-lowerBound-inclusive", "    if ((keys[mid] < k)) {\n      lo = mid + 1;", "    if ((keys[mid] <= k)) {\n      lo = mid + 1;"),
    ("collections", "btree-insertKey-values-not-shifted", "      this.nodes[id].vals[j] = this.nodes[id].vals[j - 1];\n      j -= 1;\n    }\n    this.nodes[id].keys[pos] = k;", "      j -= 1;\n    }\n    this.nodes[id].keys[pos] = k;"),
    ("collections", "btree-floor-takes-wrong-slot", "best = Some(this.nodes[x].keys[i - 1]);", "best = Some(this.nodes[x].keys[0]);"),
    ("collections", "btree-height-overcounts", "    id = nodes[id].kids[0];\n    h += 1;", "    id = nodes[id].kids[0];\n    h += 2;"),
    ("collections", "btree-mergeChildren-drops-kids", "    let b: usize = 0;\n    while (b < this.nodes[z].kids.length) {", "    let b: usize = 0;\n    while (b + 1 < this.nodes[z].kids.length) {"),
    ("collections", "btree-str-compare-reversed", "if ((compareStrings(keys[mid], k) < 0)) {", "if ((compareStrings(keys[mid], k) > 0)) {"),
    # ---- std:collections, 4-ary heap
    ("collections", "pq-push-no-sift", "      this.vals[i] = this.vals[par];\n      i = par;\n    }", "      this.vals[i] = this.vals[par];\n      break;\n    }"),
    ("collections", "pq-pop-stops-sifting-early", "        if (!leavesBefore(this.prios[m], this.seqs[m], lp, ls)) {\n          break;\n        }", "        if (true) {\n          break;\n        }"),
    ("collections", "pq-pop-ignores-fourth-child", "const end = c + 4 < n ? c + 4 : n;", "const end = c + 3 < n ? c + 3 : n;"),
    ("collections", "pq-ties-lifo", "return p1 < p2 || (p1 == p2 && s1 < s2);", "return p1 < p2 || (p1 == p2 && s1 > s2);"),
    ("collections", "pq-pop-returns-last", "const top = PQEntry<T> { priority: this.prios[0], value: this.vals[0] };", "const top = PQEntry<T> { priority: this.prios[this.prios.length - 1], value: this.vals[this.vals.length - 1] };"),
    ("collections", "pq-push-wrong-parent", "      const par = (i - 1) / 4;\n      if (!leavesBefore(priority", "      const par = (i - 1) / 2;\n      if (!leavesBefore(priority"),
    ("collections", "pq-sift-drops-value", "      this.seqs[i] = this.seqs[par];\n      this.vals[i] = this.vals[par];\n      i = par;", "      this.seqs[i] = this.seqs[par];\n      i = par;"),
]

# further test files of a module that also run against every mutant
EXTRA_TESTS = {"utf8": ["utf8_dfa_test"], "collections": ["sorted_btree_test"]}


def run(orinc, test_file, extra):
    cmd = [orinc, "test", test_file] + extra
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    return r.returncode, r.stdout.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default="build/bootstrap/orin2")
    ap.add_argument("--module", default="")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for m in MUTANTS:
            print(m[0], m[1])
        return 0
    orinc = os.path.join(ROOT, a.orinc)
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    mods = ["bytes", "utf8", "collections"]
    rewrite = {"std:" + m: "./" + m for m in mods}
    survivors = 0
    rows = []
    for mutant in MUTANTS:
        mod, name, old, new = mutant[:4]
        extra = mutant[4] if len(mutant) > 4 else ""
        if a.module and a.module != mod:
            continue
        src = open(os.path.join(ROOT, "stdlib", mod + ".or"), encoding="utf-8").read()
        if src.count(old) < 1:
            print("BAD MUTANT %s/%s: pattern not found" % (mod, name))
            return 2
        d = os.path.join(OUT, mod + "_" + name)
        os.makedirs(d)
        for m in mods:
            s = open(os.path.join(ROOT, "stdlib", m + ".or"), encoding="utf-8").read()
            if m == mod:
                s = s.replace(old, new, 1)
            for k, v in rewrite.items():
                s = s.replace('"%s"' % k, '"%s"' % v)
            open(os.path.join(d, m + ".or"), "w", encoding="utf-8").write(s)
        tfiles = [mod + "_test"] + EXTRA_TESTS.get(mod, [])
        spec = open(os.path.join(ROOT, "tests", "std", "spec_sorted.or"), encoding="utf-8").read()
        for k, v in rewrite.items():
            spec = spec.replace('"%s"' % k, '"%s"' % v)
        open(os.path.join(d, "spec_sorted.or"), "w", encoding="utf-8").write(spec)
        fails1 = fails2 = viol = 0
        out1 = ""
        code1 = 0
        for tn in tfiles:
            t = open(os.path.join(ROOT, "tests", "std", tn + ".or"), encoding="utf-8").read()
            for k, v in rewrite.items():
                t = t.replace('"%s"' % k, '"%s"' % v)
            tf = os.path.join(d, tn + ".or")
            open(tf, "w", encoding="utf-8").write(t)
            rel = os.path.relpath(tf, ROOT)
            c1, o1 = run(orinc, rel, [])
            c2, o2 = run(orinc, rel, ["--no-contracts"])
            fails1 += len(re.findall(r"^FAIL ", o1, re.M))
            fails2 += len(re.findall(r"^FAIL ", o2, re.M))
            viol += len(re.findall(r"contract violated", o1))
            out1 += o1
            if c1 == 1 and "error[" in o1:
                code1 = 1
        compile_err = code1 == 1 and fails1 == 0
        if compile_err:
            print("COMPILE ERROR in mutant %s/%s:\n%s" % (mod, name, out1[:600]))
            return 2
        status = "killed by contract" if viol else ("killed by tests" if fails1 else "SURVIVED")
        if status == "SURVIVED" and extra:
            xt = open(os.path.join(ROOT, "tests", "std", "expect_trap", extra + ".or"), encoding="utf-8").read()
            for k, v in rewrite.items():
                xt = xt.replace('"%s"' % k, '"%s"' % v)
            xf = os.path.join(d, extra + ".or")
            open(xf, "w", encoding="utf-8").write(xt)
            xcode, xout = run(orinc, os.path.relpath(xf, ROOT), ["--no-contracts"])
            if xcode == 0:
                status = "killed by tests"
                fails1 = 1
        if status == "SURVIVED":
            survivors += 1
        rows.append((mod, name, status, fails1, viol, fails2))
        print("%-12s %-36s %-20s tests failing: %2d (contract traps %2d); without contracts: %2d" % (mod, name, status, fails1, viol, fails2), flush=True)
    by = {}
    for mod, name, status, f1, v, f2 in rows:
        b = by.setdefault(mod, [0, 0, 0, 0])
        b[0] += 1
        if status != "SURVIVED":
            b[1] += 1
        if v:
            b[2] += 1
        if f2:
            b[3] += 1
    for mod, (n, killed, contract, tests_only) in by.items():
        print("%s: %d mutants, %d killed (%d with a contract violation), %d killed without contracts" % (mod, n, killed, contract, tests_only))
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
