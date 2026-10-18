#!/bin/sh
# Full bootstrap; checks stage2.c == stage3.c and runs the conformance suite with the self-built
# compiler. See docs/bootstrap.md and docs/decisions/0014-seed-bootstrap.md.
#
#   tools/bootstrap.sh               seed (bootstrap/seed/orin-seed.c.gz) -> orin0 -> orin1 -> orin2 -> stage3
#                                    (needs only a C compiler, python3, gzip, sha256sum/shasum)
#   tools/bootstrap.sh --seed-only   only seed -> build/bootstrap/orin0 (a few seconds; enough to compile
#                                    test drivers such as compiler/tests/verify_text.or)
#
# C flags: orin2, the compiler the tests and the tools use, is built with $CFLAGS (default -O2 -w). orin0 and orin1
# only ever compile compiler/main.or once each, so they are built with $STAGE01_CFLAGS (default -O1 -w): the
# C compile of the 8 MB stage C at -O2 costs much more than the slower orin0/orin1 run (docs/testing.md has the numbers).
# The fixed point is unaffected: it compares the generated C (stage2.c == stage3.c), not binaries, and the C a compiler
# generates does not depend on the C flags it was built with. STAGE01_CFLAGS="-O2 -w" restores the old all--O2 build;
# a CFLAGS set by the caller also applies to orin0 and orin1 unless STAGE01_CFLAGS is set.
#
# Split C (ADR-0049 P1): orin1 and orin2 know `compile --split N` (the seed does not, so stage 1 stays one C file). The stage 2
# build of orin2, the long -O2 compile, is split into $SPLIT units that cc compiles in parallel (tools/cc_split.sh).
# SPLIT defaults to the CPU count; SPLIT=0 builds the single file as before. The split run also writes the single-file
# C (-o), byte-identical to a run without the flag, and that file is what the fixed point compares.
set -eu
cd "$(dirname "$0")/.."
SEED_ONLY=
case "${1:-}" in
  "") ;;
  --seed-only) SEED_ONLY=1 ;;
  *) echo "usage: $0 [--seed-only]" >&2; exit 2 ;;
esac
CC=${CC:-cc}
STAGE01_CFLAGS=${STAGE01_CFLAGS:-${CFLAGS:--O1 -w}}
CFLAGS=${CFLAGS:--O2 -w}
B=build/bootstrap
SPLIT=${SPLIT:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 0)}
SEED_DIR=${ORIN_SEED_DIR:-bootstrap/seed}
mkdir -p "$B"
python3 tools/embed_prelude.py --check
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
# cc_link FLAGS WORLD C OUT. WORLD legacy (stage 0 and 1) links the frozen runtime snapshot bootstrap/seed/runtime/: the seed and
# stage1.c come from compilers with the pre-R3d logic and the live runtime may lose definitions they reference (ADR-0052
# Addendum A section 4); WORLD core (stage 2 on) links runtime/core/.
cc_link() { flags=$1; world=$2; shift 2; $CC $flags $(rt_inc "$world") "$1" $(rt_src "$world") -o "$2"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
T0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - T0 )) s"; }

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
echo "[stage0] cc $STAGE01_CFLAGS seed -> orin0"
cc_link "$STAGE01_CFLAGS" legacy $B/seed.c $B/orin0
if [ -n "$SEED_ONLY" ]; then echo "[seed-only] built $B/orin0"; exit 0; fi
echo "[stage1] orin0 compiles compiler/main.or --c-builtins (the C runtime path the frozen snapshot implements); cc $STAGE01_CFLAGS -> orin1 ($(elapsed))"
# Two commands, not `a && b`: under `set -e` a failure on the left of `&&` does not stop the script, and a stale orin1
# from an earlier run would then be used for stage 2.
$B/orin0 compile --c-builtins compiler/main.or -o $B/stage1.c
cc_link "$STAGE01_CFLAGS" legacy $B/stage1.c $B/orin1
if [ "$SPLIT" -gt 1 ]; then
  echo "[stage2] orin1 compiles compiler/main.or (--split $SPLIT); cc $CFLAGS in parallel -> orin2 ($(elapsed))"
  $B/orin1 compile compiler/main.or -o $B/stage2.c --split "$SPLIT"
  echo "[stage2] compiled ($(elapsed))"
  CC=$CC JOBS=$SPLIT tools/cc_split.sh $B/stage2.c $B/orin2 $CFLAGS
  rm -f $B/stage2.h $B/stage2.data.c $B/stage2.[0-9]*.c
else
  echo "[stage2] orin1 compiles compiler/main.or; cc $CFLAGS -> orin2 ($(elapsed))"
  $B/orin1 compile compiler/main.or -o $B/stage2.c
  cc_link "$CFLAGS" core $B/stage2.c $B/orin2
fi
echo "[stage3] orin2 compiles compiler/main.or ($(elapsed))"
$B/orin2 compile compiler/main.or -o $B/stage3.c
if cmp -s $B/stage2.c $B/stage3.c; then
  echo "[compare] stage2.c == stage3.c ($(wc -c < $B/stage2.c) bytes; $(elapsed))"
else
  echo "[compare] FAIL: stage2.c and stage3.c differ"; exit 1
fi
echo "[conformance] tests with orin2"
ORIN_CONFORMANCE_BUILDER=$B/orin2 tools/conformance.sh --orinc $B/orin2
