#!/bin/sh
# Concurrency stage 0 (ADR-0017): the C parts and the Orin stress tests under the sanitizers.
#   1. runtime/tests/task_test.c (transfer by move / copy, task start / join / trap, monitors, grants moved into a task):
#      plain, ThreadSanitizer, and AddressSanitizer + UBSan;
#   2. every tests/concurrency/*.or (thousands of tasks, tens of thousands of messages), compiled by the self-hosted compiler
#      and run plain, under ThreadSanitizer and under ASan + UBSan; the output must equal the .out file.
# The platform layer has its own ThreadSanitizer run (tools/verify_platform.sh). Needs the compiler (tools/bootstrap.sh).
#   tools/test_concurrency.sh [--quick]     --quick: only the plain and ThreadSanitizer builds of the Orin tests
# Honest limit: ThreadSanitizer finds the races that HAPPEN in these runs; a clean run is evidence, not a proof (the C
# parts are TESTED_ONLY until R3/R4, docs/concurrency.md "Assurance").
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
B=build/concurrency
mkdir -p "$B"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# ThreadSanitizer maps memory at fixed addresses; with a high ASLR entropy it can refuse to start. Retry without ASLR.
run_tsan() {
  if TSAN_OPTIONS="halt_on_error=1 allocator_may_return_null=1" "$@"; then return 0; fi
  if command -v setarch >/dev/null 2>&1; then
    TSAN_OPTIONS="halt_on_error=1 allocator_may_return_null=1" setarch "$(uname -m)" -R "$@"
  else
    return 1
  fi
}

echo "[concurrency] runtime task tests"
SRC="runtime/tests/task_test.c runtime/orin_runtime.c platform/orin_platform.c"
$CC -g -O1 -Wall -I runtime $SRC -lm -o $B/task_test
$B/task_test
$CC -g -O1 -fsanitize=thread -I runtime $SRC -lm -o $B/task_test_tsan
run_tsan $B/task_test_tsan
$CC -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -I runtime $SRC -lm -o $B/task_test_asan
ASAN_OPTIONS=detect_leaks=0 $B/task_test_asan

for t in tests/concurrency/*.or; do
  n=$(basename "$t" .or)
  echo "[concurrency] $n"
  $ORIN2 compile "$t" -o $B/$n.c
  RT="runtime/orin_runtime.c platform/orin_platform.c"
  $CC -O1 -w -I runtime $B/$n.c $RT -lm -o $B/$n
  timeout 120 $B/$n > $B/$n.actual
  cmp "tests/concurrency/$n.out" $B/$n.actual || { echo "[concurrency] FAIL $n (plain): output differs"; diff "tests/concurrency/$n.out" $B/$n.actual | head; exit 1; }
  $CC -g -O1 -w -fsanitize=thread -I runtime $B/$n.c $RT -lm -o $B/$n.tsan
  run_tsan timeout 600 $B/$n.tsan > $B/$n.tsan.actual
  cmp "tests/concurrency/$n.out" $B/$n.tsan.actual || { echo "[concurrency] FAIL $n (tsan): output differs"; exit 1; }
  if [ "$QUICK" = 0 ]; then
    $CC -g -O1 -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -I runtime $B/$n.c $RT -lm -o $B/$n.asan
    ASAN_OPTIONS=detect_leaks=0 timeout 600 $B/$n.asan > $B/$n.asan.actual
    cmp "tests/concurrency/$n.out" $B/$n.asan.actual || { echo "[concurrency] FAIL $n (asan): output differs"; exit 1; }
  fi
done
echo "[concurrency] ok"
