#!/usr/bin/env python3
"""Lint docs/memory-safety.md against the assurance ledger (ADR-0053 M2).

Run: python3 tools/check_safety_claims.py [--selftest]
Fails when
- a claim id (C<n>) or finding id (F-<name>) cited in docs/memory-safety.md is not defined in docs/assurance.md;
- a property S1-S7 or L1 has no section, no owner layer (a)-(f), no claims line or no assurance level;
- a level is not one of the ledger's names, or is stronger than the ledger allows: IMPLEMENTATION_VERIFIED /
  TRANSLATION_VALIDATED only if every cited claim has that level, and any level must occur among the cited claims' levels.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROPS = ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "L1"]
LEVELS = ["MODEL_ONLY", "TRANSLATION_VALIDATED", "IMPLEMENTATION_VERIFIED", "TESTED_ONLY"]
STRONG = ("TRANSLATION_VALIDATED", "IMPLEMENTATION_VERIFIED")
ID_RE = re.compile(r"(?<![\w-])(C\d+|F-[a-z][a-z0-9]*)(?![\w-])")


def ledger(text):
    """id -> set of level names found in the row's 'Assurance today' cell (columns: ID | Claim | Assurance | ...)."""
    out = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 4 or not re.fullmatch(r"C\d+|F-[a-z][a-z0-9]*", cells[1]):
            continue
        # claims table: ID | claim | assurance | ...; findings table: Id | finding | mitigation | level | fix
        zone = cells[3] if cells[1].startswith("C") else cells[4]
        out.setdefault(cells[1], set()).update(l for l in LEVELS if l in zone)
    return out


def sections(text):
    """property id -> body of its '## <id> ...' section."""
    out = {}
    for m in re.finditer(r"^## (S[1-7]|L1) (?!finding).*?$(.*?)(?=^## |\Z)", text, re.S | re.M):
        out[m.group(1)] = m.group(2)
    return out


def field(body, name):
    m = re.search(r"^- \*\*" + name + r"\.\*\*(.*?)(?=^- \*\*|\Z)", body, re.S | re.M)
    return m.group(1).strip() if m else ""


def check(doc, ledger_text):
    errs = []
    led = ledger(ledger_text)
    for i in sorted(set(ID_RE.findall(doc))):
        if i not in led:
            errs.append("cited id %s is not defined in docs/assurance.md" % i)
    secs = sections(doc)
    for p in PROPS:
        if p not in secs:
            errs.append("%s: no section" % p)
            continue
        body = secs[p]
        layer = field(body, "Owner layer")
        if not re.search(r"\([a-f]\)", layer):
            errs.append("%s: no owner layer (a)-(f)" % p)
        claims = [i for i in ID_RE.findall(field(body, "Claims"))]
        if not claims:
            errs.append("%s: no claims cited" % p)
        lvl_text = field(body, "Assurance level")
        found = [l for l in LEVELS if l in lvl_text]
        if len(found) != 1:
            errs.append("%s: assurance level must be exactly one ledger level (found %s)" % (p, found or "none"))
            continue
        lvl = found[0]
        have = [led[c] for c in claims if c in led]
        if have and lvl not in set().union(*have):
            errs.append("%s: level %s occurs in none of the cited claims" % (p, lvl))
        if lvl in STRONG and any(lvl not in h for h in have):
            errs.append("%s: level %s is stronger than a cited claim in the ledger" % (p, lvl))
    return errs


def selftest():
    ledger_text = (
        "| C1 | a | `MODEL_ONLY` | e | g |\n| C2 | b | `TESTED_ONLY` | e | g |\n"
        "| Id | Finding | Mitigation | Level | Fix |\n| F-x | f | m | `TESTED_ONLY` | p |\n"
    )
    ok = ("## S1 t\n- **Owner layer.** (b)\n- **Claims.** C2, F-x\n- **Assurance level.** `TESTED_ONLY`\n")

    def doc(s1=ok):
        rest = "".join(ok.replace("S1", p, 1) for p in PROPS[1:])
        return s1 + rest

    assert check(doc(), ledger_text) == [], check(doc(), ledger_text)
    cases = [
        (ok.replace("C2", "C99"), "C99"),
        (ok.replace("(b)", "none"), "owner layer"),
        (ok.replace("`TESTED_ONLY`", "`IMPLEMENTATION_VERIFIED`"), "stronger"),
        (ok.replace("`TESTED_ONLY`", "`MODEL_ONLY`"), "none of the cited"),
        (ok.replace("`TESTED_ONLY`", "unknown"), "exactly one"),
        (ok.replace("C2, F-x", "none"), "no claims"),
    ]
    for bad, needle in cases:
        e = check(doc(bad), ledger_text)
        assert any(needle in x for x in e), (needle, e)
    assert any("no section" in x for x in check(ok, ledger_text))
    print("selftest ok")


def main():
    if "--selftest" in sys.argv[1:]:
        selftest()
        return
    doc = (ROOT / "docs/memory-safety.md").read_text()
    led = (ROOT / "docs/assurance.md").read_text()
    errs = check(doc, led)
    for e in errs:
        print("check_safety_claims: " + e)
    if errs:
        sys.exit(1)
    print("check_safety_claims: ok (%d properties, %d cited ids)" % (len(PROPS), len(set(ID_RE.findall(doc)))))


if __name__ == "__main__":
    main()
