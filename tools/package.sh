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
cp build/bootstrap/orin2 "$OUT/libexec/orin"
cp runtime/*.h runtime/*.c "$OUT/lib/orin/runtime/"
mkdir -p "$OUT/lib/orin/platform" && cp platform/*.h platform/*.c "$OUT/lib/orin/platform/"
test -f "$OUT/lib/orin/platform/orin_platform.c" || { echo "package lacks platform/" >&2; exit 1; }
cp -r examples "$OUT/examples"
cp build/bootstrap/stage2.c "$OUT/share/orin/orin-seed.c"   # self-hosted compiler as C
cp README.md CHANGELOG.md "$OUT/"
mkdir -p "$OUT/docs/assets" && cp docs/assets/orin-logo-256.png "$OUT/docs/assets/"
[ -f LICENSE ] && cp LICENSE "$OUT/"
echo "$VER" > "$OUT/VERSION"
tar -C build/dist -czf "build/dist/$NAME.tar.gz" "$NAME"
# Smoke test the package.
"$OUT/bin/orin" run "$OUT/examples/hello.or"
echo "packaged build/dist/$NAME.tar.gz"
