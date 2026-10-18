#!/usr/bin/env python3
"""Check that every test path cited in docs/reference exists.

A citation is any `tests/...`, `compiler/tests/...` or `tools/test_...` path in a Markdown file under docs/reference
(inside backticks or plain text).
Trailing punctuation is ignored; a path ending in `/` or naming a directory must be an existing directory.
Also reports how many distinct tests are cited.

Diagnostic inventory (ADR-0056 C10): every code written as a string literal `"E0xxx"` / `"W0xxx"` on a non-comment line of
`compiler/` (not `compiler/tests`) must have a row in docs/reference/10-diagnostics.md; a documented code the compiler no
longer mentions fails unless its row says "reserved" or "retired"; an emitted code with no test must be listed as
`- CODE: ...` under the chapter's "Gaps" heading. A test is a `// error: CODE` / `// warns: CODE` header or a line
starting with the code in a file under tests/ (expected.txt), or a mention of the code in tools/test_*.

Exit status 1 when a cited path is missing or the inventory disagrees.

    python3 tools/check_reference.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "docs" / "reference"
CODE_RE = re.compile(r"\b[EW]0[0-9]{3}\b")
LIT_RE = re.compile(r'"([EW]0[0-9]{3})"')
HEADER_RE = re.compile(r"^\s*//\s*(?:error|warns?):(.*)")
DIAG_DOC = REF / "10-diagnostics.md"
PATH_RE = re.compile(r"(?<![A-Za-z0-9_/.])(?:tests/|compiler/tests/|tools/test_)[A-Za-z0-9_./+-]*")


def read(f: Path) -> str:
    try:
        return f.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return ""


def emitted_codes() -> set:
    out = set()
    for f in (ROOT / "compiler").rglob("*.or"):
        rel = f.relative_to(ROOT).parts
        if rel[1] in ("tests", "testing"):
            continue
        for line in read(f).splitlines():
            if line.lstrip().startswith("//"):
                continue
            out.update(LIT_RE.findall(line))
    return out


def tested_codes() -> set:
    out = set()
    for f in (ROOT / "tests").rglob("*"):
        if not f.is_file():
            continue
        for line in read(f).splitlines():
            m = HEADER_RE.match(line)
            if m:
                out.update(CODE_RE.findall(m.group(1)))
            elif f.name.startswith("expected") and CODE_RE.match(line):
                out.add(CODE_RE.match(line).group(0))
    for f in (ROOT / "tools").glob("test_*"):
        out.update(CODE_RE.findall(read(f)))
    return out


def check_inventory() -> int:
    emitted = emitted_codes()
    rows, gaps, in_gaps = {}, set(), False
    for line in read(DIAG_DOC).splitlines():
        if line.startswith("## "):
            in_gaps = line.startswith("## Gaps")
        m = re.match(r"\| ([EW]0[0-9]{3}) \|", line)
        if m:
            rows[m.group(1)] = line
        elif in_gaps:
            g = re.match(r"- ([EW]0[0-9]{3}):", line)
            if g:
                gaps.add(g.group(1))
    tested = tested_codes()
    problems = []
    for c in sorted(emitted - set(rows)):
        problems.append(f"UNDOCUMENTED {c}  (emitted by compiler/, no row in {DIAG_DOC.name})")
    for c in sorted(set(rows) - emitted):
        if not re.search(r"reserved|retired", rows[c], re.I):
            problems.append(f"STALE {c}  (documented, no longer emitted; mark the row reserved/retired or remove it)")
    untested = sorted(c for c in emitted if c not in tested)
    for c in untested:
        if c not in gaps:
            problems.append(f"UNTESTED {c}  (no test expects it; add a test or list it under Gaps in {DIAG_DOC.name})")
    for c in sorted(gaps & tested):
        problems.append(f"GAP-HAS-TEST {c}  (listed under Gaps but a test expects it)")
    for p in problems:
        print(p, file=sys.stderr)
    print(f"check_reference: diagnostics: {len(emitted)} emitted, {len(rows)} documented, {len(untested)} without a test, "
          f"{len(problems)} problems")
    return 1 if problems else 0


def main() -> int:
    files = sorted(REF.glob("*.md"))
    if not files:
        print("check_reference: no Markdown files under docs/reference", file=sys.stderr)
        return 1
    cited = {}
    for f in files:
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for m in PATH_RE.finditer(line):
                p = m.group(0).rstrip(".,;:)")
                cited.setdefault(p, []).append(f"{f.name}:{n}")
    missing = [(p, w) for p, w in sorted(cited.items()) if not (ROOT / p).exists()]
    for p, w in missing:
        print(f"MISSING {p}  (cited at {', '.join(w[:3])})", file=sys.stderr)
    print(f"check_reference: {len(files)} files, {len(cited)} distinct test paths cited, {len(missing)} missing")
    bad = check_inventory()
    return 1 if missing or bad else 0


if __name__ == "__main__":
    sys.exit(main())
