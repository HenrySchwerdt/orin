#!/usr/bin/env python3
"""Render packaging/homebrew/orin.rb for a release.

  tools/render_homebrew.py --version 0.1.0-alpha.2 --sums SHA256SUMS [--template T] [-o out.rb]

Reads the combined SHA256SUMS of the release (lines "<sha256>  orin-<version>-<platform>.tar.gz"),
replaces @VERSION@ and one @SHA256_<PLATFORM>@ per platform. Fails (exit 1) when a platform has no
checksum, a checksum is malformed, the version is not a plain version, or a placeholder is left over.
"""
import argparse
import os
import re
import sys

PLATFORMS = ["linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64"]
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_sums(text, version):
    sums = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"SHA256SUMS line {n}: expected '<sha256>  <file>'")
        digest, fname = parts[0].lower(), parts[1].lstrip("*")
        if not SHA_RE.match(digest):
            raise ValueError(f"SHA256SUMS line {n}: '{parts[0]}' is not a sha256")
        for plat in PLATFORMS:
            if fname == f"orin-{version}-{plat}.tar.gz":
                if plat in sums and sums[plat] != digest:
                    raise ValueError(f"conflicting checksums for {fname}")
                sums[plat] = digest
    missing = [p for p in PLATFORMS if p not in sums]
    if missing:
        raise ValueError(f"no checksum for orin-{version}-<platform>.tar.gz: {', '.join(missing)}")
    return sums


def render(template, version, sums_text):
    if not VERSION_RE.match(version):
        raise ValueError(f"'{version}' is not a version like 0.1.0 or 0.1.0-alpha.2 (no leading v)")
    sums = parse_sums(sums_text, version)
    out = template.replace("@VERSION@", version)
    for plat, digest in sums.items():
        out = out.replace("@SHA256_" + plat.upper().replace("-", "_") + "@", digest)
    left = re.findall(r"@[A-Z0-9_]+@", out)
    if left:
        raise ValueError(f"placeholders left in the formula: {', '.join(sorted(set(left)))}")
    return out


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True, help="release version without the leading v")
    ap.add_argument("--sums", required=True, help="path of the release's SHA256SUMS")
    ap.add_argument("--template", default=os.path.join(here, "..", "packaging", "homebrew", "orin.rb"))
    ap.add_argument("-o", "--output", help="output file (default: stdout)")
    a = ap.parse_args(argv)
    try:
        with open(a.template, encoding="utf-8") as f:
            template = f.read()
        with open(a.sums, encoding="utf-8") as f:
            sums_text = f.read()
        result = render(template, a.version, sums_text)
    except (OSError, ValueError) as e:
        print(f"render_homebrew: {e}", file=sys.stderr)
        return 1
    if a.output:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(result)
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
