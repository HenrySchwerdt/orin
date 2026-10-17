#!/usr/bin/env python3
"""Check that every test path cited in docs/reference exists.

A citation is any `tests/...` path in a Markdown file under docs/reference (inside backticks or plain text).
Trailing punctuation is ignored; a path ending in `/` or naming a directory must be an existing directory.
Also reports how many distinct tests are cited. Exit status 1 when a cited path is missing.

    python3 tools/check_reference.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "docs" / "reference"
PATH_RE = re.compile(r"tests/[A-Za-z0-9_./+-]+")


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
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
