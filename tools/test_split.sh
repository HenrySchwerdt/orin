#!/bin/sh
# Tests of `orin compile ... --split N` (ADR-0049 P1, compiler/backends/c/split.or).
#
#   tools/test_split.sh [--orinc COMPILER] [--self] [--all]
#
# For tests/split/mixed.or (strings, vtables, @Inline, floats) and a sample of tests/run (all of them with --all) and each N
# in 1, 3, 8: `-o x.c --split N` must leave x.c byte-identical to the build without the flag, and the program built from
# the N + 1 split units (tools/cc_split.sh) must print what the single-file build prints.
# With --self the compiler itself is also built with --split 4 from compiler/main.or and the conformance suite runs with
# that compiler (build/split/orin).
set -eu
cd "$(dirname "$0")/.."
ORINC=build/bootstrap/orin2
SELF=
ALL=
while [ $# -gt 0 ]; do
  case "$1" in
    --orinc) ORINC=$2; shift ;;
    --self) SELF=1 ;;
    --all) ALL=1 ;;
    *) echo "usage: $0 [--orinc COMPILER] [--self] [--all]" >&2; exit 2 ;;
  esac
  shift
done
[ -x "$ORINC" ] || ORINC=build/dev/orin
T=build/split-test
rm -rf $T
mkdir -p $T
CFLAGS="-O1 -w"
fail=0
n=0
for f in tests/split/mixed.or $(ls tests/run/*.or | awk -v all="$ALL" 'all != "" || NR % 6 == 1'); do
  name=$(basename "$f" .or)
  if ! $ORINC compile "$f" -o $T/$name.c 2>/dev/null; then continue; fi
  cc $CFLAGS -I runtime/core $T/$name.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -o $T/$name.bin
  $T/$name.bin > $T/$name.want 2>&1 || true
  for k in 1 3 8; do
    $ORINC compile "$f" -o $T/$name.s$k.c --split $k
    cmp -s $T/$name.c $T/$name.s$k.c || { echo "FAIL $name --split $k: x.c differs from the build without --split"; fail=1; }
    tools/cc_split.sh $T/$name.s$k.c $T/$name.s$k.bin $CFLAGS -- -lm
    $T/$name.s$k.bin > $T/$name.got 2>&1 || true
    cmp -s $T/$name.want $T/$name.got || { echo "FAIL $name --split $k: output differs"; fail=1; }
    rm -f $T/$name.s$k.* $T/$name.got
    n=$((n + 1))
  done
  rm -f $T/$name.c $T/$name.bin $T/$name.want
done
if [ $fail != 0 ]; then echo "test_split: FAILED"; exit 1; fi
echo "test_split: $n split builds match the single-file builds"

if [ -n "$SELF" ]; then
  mkdir -p build/split
  $ORINC compile compiler/main.or -o build/split/orin.c --split 4
  cmp -s build/split/orin.c build/bootstrap/stage2.c || echo "note: build/split/orin.c differs from build/bootstrap/stage2.c (a changed tree)"
  tools/cc_split.sh build/split/orin.c build/split/orin -O1 -w -- -lm
  echo "test_split: conformance with the compiler built from 4 split units"
  ORIN_CONFORMANCE_BUILDER=$ORINC tools/conformance.sh --orinc build/split/orin
fi
