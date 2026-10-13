#!/bin/sh
# Full bootstrap; checks stage2.c == stage3.c and runs the conformance suite with the self-built
# compiler. See docs/bootstrap.md and docs/decisions/0014-seed-bootstrap.md.
#
#   tools/bootstrap.sh               seed (bootstrap/seed/orin-seed.c.gz) -> orin0 -> orin1 -> orin2 -> stage3
#                                    (needs only a C compiler, python3, gzip, sha256sum/shasum)
#   tools/bootstrap.sh --from-stage0 Rust Stage 0 (needs cargo) -> orin1 -> orin2 -> stage3
set -eu
cd "$(dirname "$0")/.."
MODE=seed
case "${1:-}" in
  "") ;;
  --from-stage0) MODE=stage0 ;;
  *) echo "usage: $0 [--from-stage0]" >&2; exit 2 ;;
esac
CC=${CC:-cc}
CFLAGS=${CFLAGS:--O2 -w}
B=build/bootstrap
SEED_DIR=${ORIN_SEED_DIR:-bootstrap/seed}
mkdir -p "$B"
python3 tools/embed_prelude.py --check
cc_link() { $CC $CFLAGS -I runtime "$1" runtime/orin_runtime.c platform/orin_platform.c -o "$2"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

if [ "$MODE" = seed ]; then
  echo "[seed] decompress and verify $SEED_DIR/orin-seed.c.gz"
  gzip -dc "$SEED_DIR/orin-seed.c.gz" > $B/seed.c
  want=$(sed -n 's/^sha256: *//p' "$SEED_DIR/SEED_INFO" | head -n1)
  got=$(sha256 $B/seed.c)
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "[seed] FAIL: sha256 mismatch (SEED_INFO: ${want:-<missing>}, actual: $got)" >&2
    rm -f $B/seed.c
    exit 1
  fi
  echo "[seed] sha256 ok ($got)"
  echo "[stage0] cc seed -> orin0"
  cc_link $B/seed.c $B/orin0
  echo "[stage1] orin0 compiles compiler/main.or"
  $B/orin0 compile compiler/main.or -o $B/stage1.c && cc_link $B/stage1.c $B/orin1
else
  (cd bootstrap && cargo build --release -q)
  ORINB=bootstrap/target/release/orinb
  # Stage 0 does not know `std:io` (compiler/lsp/stdio.or), so stage 1 is built from a copy of the
  # compiler tree in which that one file is replaced by a stub (tools/stage0/lsp_stdio.or).
  echo "[stage1] orinb compiles compiler/main.or (stdio stub)"
  rm -rf $B/stage0-src && mkdir -p $B/stage0-src && cp -r compiler $B/stage0-src/compiler
  cp tools/stage0/lsp_stdio.or $B/stage0-src/compiler/lsp/stdio.or
  $ORINB compile $B/stage0-src/compiler/main.or -o $B/stage1.c && cc_link $B/stage1.c $B/orin1
fi
echo "[stage2] orin1 compiles compiler/main.or"
$B/orin1 compile compiler/main.or -o $B/stage2.c && cc_link $B/stage2.c $B/orin2
echo "[stage3] orin2 compiles compiler/main.or"
$B/orin2 compile compiler/main.or -o $B/stage3.c
if cmp -s $B/stage2.c $B/stage3.c; then
  echo "[compare] stage2.c == stage3.c ($(wc -c < $B/stage2.c) bytes)"
else
  echo "[compare] FAIL: stage2.c and stage3.c differ"; exit 1
fi
echo "[conformance] tests with orin2"
python3 tools/run_tests.py --orinc $B/orin2
