#!/usr/bin/env python3
"""API snapshots of the standard library (ADR-0056 section 3, criterion C11).

Regenerates the `orin-api 1` snapshot of every public std module and compares it with api/std/<module>.api.txt.
`orin api` needs a program with `main`, so for each module this script writes a throw-away entry file that re-exports every
exported name of the module (read from library/ source, comments stripped) and has an empty `main`, runs `orin api` on it,
and rewrites the header so the snapshot names the module (`module std:bytes`) instead of `(root)`.

    python3 tools/check_api_snapshots.py [--orin build/bootstrap/orin2]          # check (CI): exit 1 on a difference
    python3 tools/check_api_snapshots.py --update                                # rewrite api/std/*.api.txt
    python3 tools/check_api_snapshots.py --list                                  # the modules and their stability

The module list is api/MODULES (`<module> <frozen|experimental|builtin>`); the script also checks it against the public std
modules the loader knows (compiler/loader/resolve.or), so a new std module without a snapshot fails the check.
See docs/api-snapshots.md.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "api"
MODULES = API / "MODULES"
INTERNAL = {"std:taskcore", "std:metacore", "std:metajson", "std:fsraw", "std:clock", "std:core", "std:coreprobe"}
BUILTIN = {"std:process"}  # loader built-ins over the C runtime: no source, `orin api` cannot see their exports
DECL = re.compile(r"^\s*export\s+(?:function|class|type|const|enum|interface|record|union)\s+([A-Za-z_][A-Za-z0-9_]*)")


def loader_modules() -> list[str]:
    """Public std modules known to the loader (isStdlibModule arms in resolve.or, plus std:math and the built-ins)."""
    text = (ROOT / "compiler/loader/resolve.or").read_text(encoding="utf-8")
    body = text.split("function isStdlibModule", 1)[1].split("}", 1)[0]
    mods = set(re.findall(r'"(std:[a-z0-9/]+)"\s*=>\s*true', body))
    mods |= {"std:math"} | BUILTIN
    return sorted(m for m in mods if m not in INTERNAL and not m.endswith("/internal"))


def source_of(mod: str) -> Path:
    name = mod[len("std:"):]
    return ROOT / ("library/collections/math.or" if name == "math" else f"library/std/{name}.or")


def exported_names(path: Path) -> list[tuple[str, str]]:
    """(name, origin) for every exported name; origin is "" for an own declaration, else the module of a re-export."""
    lines = [re.sub(r"//.*", "", l) for l in path.read_text(encoding="utf-8").splitlines()]
    names: list[tuple[str, str]] = []
    i = 0
    while i < len(lines):
        l = lines[i]
        m = DECL.match(l)
        if m:
            names.append((m.group(1), ""))
        elif re.match(r"^\s*export\s*\{", l):
            buf = l
            while "}" not in buf and i + 1 < len(lines):
                i += 1
                buf += " " + lines[i]
            inner = buf.split("{", 1)[1].split("}", 1)[0]
            src = re.search(r'from\s*"([^"]+)"', buf.split("}", 1)[1])
            names += [(n.strip(), src.group(1) if src else "") for n in inner.split(",") if n.strip()]
        i += 1
    seen: list[tuple[str, str]] = []
    for n in names:
        if n[0] not in [x[0] for x in seen]:
            seen.append(n)
    return seen


def snapshot(orin: str, mod: str) -> str:
    exported = exported_names(source_of(mod))
    if not exported:
        raise SystemExit(f"error: {mod}: no exported names found in {source_of(mod)}")
    # Names re-exported from a loader built-in (std:fsraw, std:clock, ...) have no source unit, so `orin api` cannot print their
    # signatures; they are listed by name at the end (`builtin <name> from <module>`) so that adding or removing one still shows.
    builtin_names = [(n, o) for n, o in exported if o in INTERNAL]
    names = [n for n, o in exported if o not in INTERNAL]
    with tempfile.TemporaryDirectory() as d:
        entry = Path(d) / "api_entry.or"
        entry.write_text(f'export {{ {", ".join(names)} }} from "{mod}";\nfunction main(): void {{}}\n', encoding="utf-8")
        p = subprocess.run([orin, "api", str(entry)], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"error: orin api failed for {mod}:\n{p.stdout}{p.stderr}")
    out = p.stdout.splitlines()
    if len(out) < 2 or out[0] != "orin-api 1" or out[1] != "module (root)":
        raise SystemExit(f"error: {mod}: unexpected `orin api` output:\n{p.stdout}")
    out[1] = f"module {mod}"
    text = "\n".join(out)
    for n in names:  # `orin api` drops a name it cannot resolve without an error: make that fail here
        if not re.search(r"^ {2}(?:\w+ )?(?:function|class|type|const|enum|interface) " + re.escape(n) + r"\b|^ {4}" + re.escape(n) + r": ", text, re.M):
            raise SystemExit(f"error: {mod}: exported name `{n}` is missing from the `orin api` output (extend tools/check_api_snapshots.py)")
    out += [f"  builtin {n} from {o}" for n, o in builtin_names]
    return "\n".join(out) + "\n"


def read_modules() -> dict[str, str]:
    mods: dict[str, str] = {}
    for l in MODULES.read_text(encoding="utf-8").splitlines():
        l = l.split("#", 1)[0].strip()
        if l:
            m, kind = l.split()
            if kind not in ("frozen", "experimental", "builtin"):
                raise SystemExit(f"error: api/MODULES: bad stability {kind!r} for {m}")
            mods[m] = kind
    return mods


def snap_path(mod: str) -> Path:
    return API / "std" / (mod[len("std:"):] + ".api.txt")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--orin", default=os.environ.get("ORIN", str(ROOT / "build/bootstrap/orin2")))
    ap.add_argument("--update", action="store_true", help="rewrite api/std/*.api.txt")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    mods = read_modules()
    if a.list:
        for m, k in mods.items():
            print(m, k)
        return 0
    bad = 0
    known = loader_modules()
    for m in known:
        if m not in mods:
            print(f"FAIL {m}: public std module missing from api/MODULES", file=sys.stderr)
            bad += 1
    for m in mods:
        if m not in known:
            print(f"FAIL {m}: listed in api/MODULES but not a public std module of the loader", file=sys.stderr)
            bad += 1
    if bad:
        return 1
    changed = 0
    for m, kind in mods.items():
        if kind == "builtin":
            continue
        cur = snapshot(a.orin, m)
        path = snap_path(m)
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old == cur:
            continue
        if a.update:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(cur, encoding="utf-8")
            print(f"updated {path.relative_to(ROOT)}")
            continue
        changed += 1
        note = " (experimental: allowed, update the snapshot and say so in the changes/ note)" if kind == "experimental" else ""
        print(f"FAIL {m}: public API differs from {path.relative_to(ROOT)}{note}", file=sys.stderr)
        diff = difflib.unified_diff((old or "").splitlines(), cur.splitlines(), "snapshot", "current", lineterm="", n=1)
        for l in diff:
            print("  " + l, file=sys.stderr)
    if a.update:
        return 0
    n = sum(1 for k in mods.values() if k != "builtin")
    if changed:
        print(f"check_api_snapshots: {changed} of {n} modules changed; run `python3 tools/check_api_snapshots.py --update` "
              "if intended (docs/api-snapshots.md)", file=sys.stderr)
        return 1
    print(f"check_api_snapshots: {n} std modules match api/std/ ({len(mods) - n} built-in without snapshot)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
