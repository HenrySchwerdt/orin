#!/bin/sh
# Full bootstrap: Stage 0 (Rust) -> orin1 -> orin2 -> stage3.c; checks stage2.c == stage3.c
# and runs the conformance suite with the self-built compiler. See docs/bootstrap.md.
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-cc}
CFLAGS=${CFLAGS:--O2 -w}
B=build/bootstrap
mkdir -p "$B"
python3 tools/embed_prelude.py --check
(cd bootstrap && cargo build --release -q)
ORINB=bootstrap/target/release/orinb
cc_link() { $CC $CFLAGS -I runtime "$1" runtime/orin_runtime.c -o "$2"; }

# Stage 0 does not know `std:io` (compiler/lsp/stdio.or), so stage 1 is built from a copy of the
# compiler tree in which that one file is replaced by a stub (tools/stage0/lsp_stdio.or).
echo "[stage1] orinb compiles compiler/main.or (stdio stub)"
rm -rf $B/stage0-src && mkdir -p $B/stage0-src && cp -r compiler $B/stage0-src/compiler
cp tools/stage0/lsp_stdio.or $B/stage0-src/compiler/lsp/stdio.or
$ORINB compile $B/stage0-src/compiler/main.or -o $B/stage1.c && cc_link $B/stage1.c $B/orin1
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
