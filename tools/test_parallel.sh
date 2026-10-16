#!/bin/sh
# Parallel pipelines (ADR-0039 §5): differential tests of `parallel()` against the thread count and the fusion pass.
#   Every tests/next/run/par_*.or that exits 0 (and tests/concurrency/par_*.or) is compiled three ways -- fused (the default),
#   `--no-fuse` (the parallel prelude's own functions) and `--no-opt` -- and every build runs with ORIN_THREADS = 1 .. 8
#   (1: everything on the calling task) and with the default (the processors online). Every run must print the .out file;
#   the plain fused build must leave no live object at exit (ORIN_STATS=1). Then the fused build runs under ThreadSanitizer
#   (ORIN_THREADS = 2, 4, 8) and AddressSanitizer + UBSan (ORIN_THREADS = 4). Called by tools/test_concurrency.sh.
#   tools/test_parallel.sh [--quick]     --quick: threads 1, 2, 4 only and no ASan build
# Honest limit: a sanitizer finds the races and memory errors that HAPPEN in these runs; thread counts above the number of
# processors still interleave, but a clean run is evidence, not a proof.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
B=build/parallel
mkdir -p "$B"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
THREADS="1 2 3 4 5 6 7 8"
[ "$QUICK" = 1 ] && THREADS="1 2 4"
ARCH=$(uname -m)
TSAN_RUN=""
if command -v setarch >/dev/null 2>&1 && setarch "$ARCH" -R true >/dev/null 2>&1; then
  TSAN_RUN="setarch $ARCH -R"
fi
RT="runtime/core/orin_runtime.c runtime/platform/orin_platform.c"
count=0
for t in tests/next/run/par_*.or tests/concurrency/par_*.or; do
  [ -f "$t" ] || continue
  head -1 "$t" | grep -q '^// exit:' && continue
  n=$(basename "$t" .or)
  out=${t%.or}.out
  echo "[parallel] $n"
  for mode in fused nofuse noopt; do
    case $mode in
      fused) flags="" ;;
      nofuse) flags="--no-fuse" ;;
      noopt) flags="--no-opt" ;;
    esac
    $ORIN2 compile "$t" -o $B/$n.$mode.c $flags 2> $B/$n.$mode.warn
    $CC -O1 -w -I runtime/core $B/$n.$mode.c $RT -lm -lpthread -o $B/$n.$mode
    for th in default $THREADS; do
      if [ "$th" = default ]; then
        timeout 300 $B/$n.$mode > $B/$n.actual
      else
        ORIN_THREADS=$th timeout 300 $B/$n.$mode > $B/$n.actual
      fi
      cmp -s "$out" $B/$n.actual || { echo "[parallel] FAIL $n ($mode, threads $th): output differs"; diff "$out" $B/$n.actual | head; exit 1; }
      count=$((count + 1))
    done
  done
  ORIN_STATS=1 ORIN_THREADS=4 timeout 300 $B/$n.fused 2> $B/$n.stats > /dev/null
  grep -q '"live_objs_at_exit":0' $B/$n.stats || { echo "[parallel] FAIL $n: objects still live at exit"; cat $B/$n.stats; exit 1; }
  $CC -g -O1 -w -fsanitize=thread -I runtime/core $B/$n.fused.c $RT -lm -lpthread -o $B/$n.tsan
  for th in 2 4 8; do
    ORIN_THREADS=$th TSAN_OPTIONS="halt_on_error=1 allocator_may_return_null=1" $TSAN_RUN timeout 900 $B/$n.tsan > $B/$n.actual
    cmp -s "$out" $B/$n.actual || { echo "[parallel] FAIL $n (tsan, threads $th): output differs"; exit 1; }
  done
  if [ "$QUICK" = 0 ]; then
    $CC -g -O1 -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -I runtime/core \
      $B/$n.fused.c $RT -lm -lpthread -o $B/$n.asan
    ORIN_THREADS=4 ASAN_OPTIONS=detect_leaks=0 timeout 900 $B/$n.asan > $B/$n.actual
    cmp -s "$out" $B/$n.actual || { echo "[parallel] FAIL $n (asan): output differs"; exit 1; }
  fi
done
echo "[parallel] ok ($count runs compared)"
