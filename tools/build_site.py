#!/usr/bin/env python3
"""Build the documentation website (MkDocs + Material) from docs/ without modifying docs/.

Stages the selected pages into build/site-src (same relative layout as docs/), rewrites links to pages
that are not part of the site into GitHub blob URLs, appends a generated nav to a copy of
site/mkdocs.yml, and runs `mkdocs build --strict`. Output: build/site.

Usage: python3 tools/build_site.py [--stage-only]
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
STAGE = ROOT / "build" / "site-src"
BLOB = "https://github.com/orin-lang/orin-lang/blob/main/"
TREE = "https://github.com/orin-lang/orin-lang/tree/main/"
RAW = "https://raw.githubusercontent.com/orin-lang/orin-lang/main/"

TOP = ["getting-started.md", "install.md"]
TAIL = ["stability.md", "ts-developers.md", "cli.md", "std.md", "concurrency.md", "contracts.md", "website.md"]


def pages():
    out = list(TOP)
    out += ["tutorial/" + p.name for p in sorted((DOCS / "tutorial").glob("*.md"))]
    out += ["reference/" + p.name for p in sorted((DOCS / "reference").glob("*.md"))]
    out += TAIL
    return [p for p in out if (DOCS / p).exists()]


def title(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return line[2:].strip().replace('"', "'")
    return path.stem


LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
REFDEF = re.compile(r"^(\s*\[[^\]]+\]:\s*)(\S+)", re.M)
HTMLREF = re.compile(r'((?:href|src)=")([^"]+)(")')


def make_rewriter(rel, included, assets):
    src_dir = (DOCS / rel).parent

    def fix(target):
        if re.match(r"^([a-zA-Z][a-zA-Z0-9+.-]*:|#|/)", target):
            return target
        path, sep, frag = target.partition("#")
        if not path:
            return target
        res = (src_dir / path).resolve()
        try:
            repo_rel = res.relative_to(ROOT).as_posix()
        except ValueError:
            return target
        try:
            docs_rel = res.relative_to(DOCS).as_posix()
        except ValueError:
            docs_rel = None
        if docs_rel in included:
            return target
        if docs_rel and res.is_file() and res.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif", ".svg"):
            assets.add(docs_rel)
            return target
        if res.is_dir():
            return TREE + repo_rel.rstrip("/") + (sep + frag if frag else "")
        if res.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif", ".svg"):
            return RAW + repo_rel
        return BLOB + repo_rel + (sep + frag if frag else "")

    def convert(text):
        text = LINK.sub(lambda m: m.group(1) + fix(m.group(2)) + m.group(3), text)
        text = REFDEF.sub(lambda m: m.group(1) + fix(m.group(2)), text)
        return HTMLREF.sub(lambda m: m.group(1) + fix(m.group(2)) + m.group(3), text)

    return convert


def rewrite(text, convert):
    """Apply convert() to every line outside fenced code blocks."""
    res, fence = [], None
    for line in text.split("\n"):
        m = re.match(r"^\s*(```+|~~~+)", line)
        if m:
            if fence is None:
                fence = m.group(1)[0]
                # No Orin lexer: highlight orin/or fences with the TypeScript lexer.
                line = re.sub(r"^(\s*(?:```+|~~~+))(?:orin|or)\b", r"\1typescript", line)
            elif m.group(1)[0] == fence:
                fence = None
            res.append(line)
        elif fence:
            res.append(line)
        else:
            res.append(convert(line))
    return "\n".join(res)


def main():
    stage_only = "--stage-only" in sys.argv
    if STAGE.parent.exists():
        shutil.rmtree(STAGE, ignore_errors=True)
    STAGE.mkdir(parents=True)
    plist = pages()
    included = set(plist)
    assets = set()
    for rel in plist:
        dst = STAGE / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        text = (DOCS / rel).read_text(encoding="utf-8")
        dst.write_text(rewrite(text, make_rewriter(rel, included, assets)), encoding="utf-8")
    shutil.copy(ROOT / "site" / "index.md", STAGE / "index.md")
    for a in assets:
        (STAGE / a).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(DOCS / a, STAGE / a)

    def entry(rel):
        return f'{{ "{title(DOCS / rel)}": "{rel}" }}'

    nav = ['  - Home: index.md']
    for rel in TOP:
        if rel in included:
            nav.append("  - " + entry(rel))
    for sect, d in (("Tutorial", "tutorial/"), ("Reference", "reference/")):
        nav.append(f"  - {sect}:")
        for rel in plist:
            if rel.startswith(d):
                nav.append("    - " + entry(rel))
    nav.append("  - More:")
    for rel in TAIL:
        if rel in included:
            nav.append("    - " + entry(rel))
    cfg = (ROOT / "site" / "mkdocs.yml").read_text(encoding="utf-8")
    cfg_out = ROOT / "build" / "mkdocs.generated.yml"
    cfg_out.write_text(cfg + "\nnav:\n" + "\n".join(nav) + "\n", encoding="utf-8")
    print(f"staged {len(plist) + 1} pages into {STAGE.relative_to(ROOT)}")
    if stage_only:
        return 0
    return subprocess.call([sys.executable, "-m", "mkdocs", "build", "--strict", "-f", str(cfg_out)])


if __name__ == "__main__":
    sys.exit(main())
