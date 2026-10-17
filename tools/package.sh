#!/bin/sh
# Build a release package from an already bootstrapped tree (run tools/bootstrap.sh first).
#   tools/package.sh <version> <platform-tag>   e.g. tools/package.sh 0.1.0-alpha.1 linux-x86_64
set -eu
cd "$(dirname "$0")/.."
VER=$1; PLAT=$2
NAME="orin-$VER-$PLAT"
OUT=build/dist/$NAME
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/libexec" "$OUT/lib/orin/runtime" "$OUT/share/orin"
cp dist/orin "$OUT/bin/orin"
cp dist/orin-cli.sh "$OUT/bin/orin-cli.sh"
cp dist/llvm.pin "$OUT/lib/orin/llvm.pin"   # the pinned LLVM for orin toolchain install (ADR-0038 section 8)
cp build/bootstrap/orin2 "$OUT/libexec/orin"
cp runtime/core/*.h runtime/core/*.c "$OUT/lib/orin/runtime/"   # the release layout keeps lib/orin/{runtime,platform} (docs/architecture.md, Repository layout)
mkdir -p "$OUT/lib/orin/platform" && cp runtime/platform/*.h runtime/platform/*.c "$OUT/lib/orin/platform/"
cp -R runtime/platform/orbit "$OUT/lib/orin/platform/orbit" && rm -rf "$OUT/lib/orin/platform/orbit/tests" # ADR-0055: the wasm64-orbit L0
test -f "$OUT/lib/orin/platform/orin_platform.c" || { echo "package lacks platform/" >&2; exit 1; }
cp -r examples "$OUT/examples"
mkdir -p "$OUT/examples/osig" && cp -r tests/osig/accept/base tests/osig/accept/head "$OUT/examples/osig/"   # orin diff demo (README)
cp build/bootstrap/stage2.c "$OUT/share/orin/orin-seed.c"   # self-hosted compiler as C
cp README.md "$OUT/"
python3 tools/changelog.py --render -o "$OUT/CHANGELOG.md"   # with the unreleased fragments from changes/
mkdir -p "$OUT/docs/assets" && cp docs/assets/orin-logo-256.png "$OUT/docs/assets/"
[ -f LICENSE ] && cp LICENSE "$OUT/"
echo "$VER" > "$OUT/VERSION"
tar -C build/dist -czf "build/dist/$NAME.tar.gz" "$NAME"
# Checksum file next to the tarball: "<sha256>  <file name>" (sha256sum format; install.sh and SHA256SUMS use it).
if command -v sha256sum >/dev/null 2>&1; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
(cd build/dist && $SUM "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
# Smoke test the package.
"$OUT/bin/orin" run "$OUT/examples/hello.or"
"$OUT/bin/orin" test "$OUT/examples/testing.or"
echo "packaged build/dist/$NAME.tar.gz (+ .sha256)"
