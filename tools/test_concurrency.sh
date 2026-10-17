#!/bin/sh
# Concurrency stage 0 (ADR-0017): the C parts and the Orin stress tests under the sanitizers.
#   1. runtime/core/tests/task_test.c (transfer by move / copy, task start / join / trap, monitors, grants moved into a task):
#      plain, ThreadSanitizer, and AddressSanitizer + UBSan;
#   2. every tests/concurrency/*.or (thousands of tasks, tens of thousands of messages), compiled by the self-hosted compiler
#      and run plain, under ThreadSanitizer and under ASan + UBSan; the output must equal the .out file and the plain run must
#      leave no live object at exit (ORIN_STATS=1: allocations and frees of all tasks cancel out). A program whose first line is
#      `// exit: N` is a panic test: it must end with status N and a `task panicked` message (no hang, race or crash on the way).
# The platform layer has its own ThreadSanitizer run (tools/verify_platform.sh). Needs the compiler (tools/bootstrap.sh).
#   tools/test_concurrency.sh [--quick]     --quick: only the plain and ThreadSanitizer builds of the Orin tests
# Honest limit: ThreadSanitizer finds the races that HAPPEN in these runs; a clean run is evidence, not a proof (the C
# parts are TESTED_ONLY until R3/R4, docs/concurrency.md "Assurance").
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
B=build/concurrency
mkdir -p "$B"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# ThreadSanitizer maps memory at fixed addresses; with a high ASLR entropy it can refuse to start ("unexpected memory mapping").
# When `setarch -R` (no ASLR) works here, always use it, so that a program's own non-zero exit status is never mistaken for that
# failure and the program is never run twice.
ARCH=$(uname -m)
TSAN_RUN=""
if command -v setarch >/dev/null 2>&1 && setarch "$ARCH" -R true >/dev/null 2>&1; then
  TSAN_RUN="setarch $ARCH -R"
fi
run_tsan() {
  TSAN_OPTIONS="halt_on_error=1 allocator_may_return_null=1" $TSAN_RUN "$@"
}

echo "[concurrency] runtime task tests"
# the object model (allocator, destroy, make_unique) is Orin code: the C test links the stub that defines its C names (tools/rt_stub.sh)
SRC="runtime/core/tests/task_test.c $(rt_src)"
STUB=$(ORIN2=$ORIN2 CC=$CC tools/rt_stub.sh $B/rt_stub.o -g -O1)
$CC -g -O1 -Wall -I runtime/core $SRC $STUB -lm -o $B/task_test
$B/task_test
STUB_TSAN=$(ORIN2=$ORIN2 CC=$CC tools/rt_stub.sh $B/rt_stub_tsan.o -g -O1 -fsanitize=thread)
$CC -g -O1 -fsanitize=thread -I runtime/core $SRC $STUB_TSAN -lm -o $B/task_test_tsan
run_tsan $B/task_test_tsan
STUB_ASAN=$(ORIN2=$ORIN2 CC=$CC tools/rt_stub.sh $B/rt_stub_asan.o -g -fsanitize=address,undefined -fno-sanitize-recover=undefined)
$CC -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -I runtime/core $SRC $STUB_ASAN -lm -o $B/task_test_asan
ASAN_OPTIONS=detect_leaks=0 $B/task_test_asan
# the same checks with the transfer operations of runtime/core/transfer.or (ADR-0052 Addendum B, R3e.2) in place of the C ones, through the
# test wrappers of the stub; the C task code and the lend still work on the same slot table
$CC -g -O1 -Wall -DORIN_TRANSFER_IN_ORIN -I runtime/core $SRC $STUB -lm -o $B/task_test_orin
$B/task_test_orin
$CC -g -O1 -fsanitize=thread -DORIN_TRANSFER_IN_ORIN -I runtime/core $SRC $STUB_TSAN -lm -o $B/task_test_orin_tsan
run_tsan $B/task_test_orin_tsan
$CC -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -DORIN_TRANSFER_IN_ORIN -I runtime/core $SRC $STUB_ASAN -lm -o $B/task_test_orin_asan
ASAN_OPTIONS=detect_leaks=0 $B/task_test_orin_asan

for t in tests/concurrency/*.or; do
  n=$(basename "$t" .or)
  echo "[concurrency] $n"
  $ORIN2 compile "$t" -o $B/$n.c
  RT="$(rt_src)"
  $CC -O1 -w -I runtime/core $B/$n.c $RT -lm -o $B/$n
  # a first line `// exit: N` says the program must end with status N (a panic test); default 0
  want=$(sed -n '1s|^// exit: *\([0-9][0-9]*\) *$|\1|p' "$t")
  want=${want:-0}
  expect_status() { # expect_status LABEL ARGS...: run, require exit status $want, keep stdout in $B/$n.actual
    label=$1; shift
    st=0
    "$@" > $B/$n.actual 2> $B/$n.stderr || st=$?
    [ "$st" = "$want" ] || { echo "[concurrency] FAIL $n ($label): exit status $st, wanted $want"; head -5 $B/$n.stderr; exit 1; }
  }
  expect_status plain timeout 120 $B/$n
  cmp "tests/concurrency/$n.out" $B/$n.actual || { echo "[concurrency] FAIL $n (plain): output differs"; diff "tests/concurrency/$n.out" $B/$n.actual | head; exit 1; }
  if [ "$want" = 0 ]; then
    # no leak on the normal path: allocations of every task and frees of every task (also across tasks) cancel out
    ORIN_STATS=1 timeout 120 $B/$n 2> $B/$n.stats > /dev/null
    grep -q '"live_objs_at_exit":0' $B/$n.stats || { echo "[concurrency] FAIL $n: objects still live at exit"; cat $B/$n.stats; exit 1; }
  else
    grep -q "trap: task panicked" $B/$n.stderr || { echo "[concurrency] FAIL $n: no task panic message on stderr"; cat $B/$n.stderr; exit 1; }
  fi
  $CC -g -O1 -w -fsanitize=thread -I runtime/core $B/$n.c $RT -lm -o $B/$n.tsan
  expect_status tsan run_tsan timeout 600 $B/$n.tsan
  cmp "tests/concurrency/$n.out" $B/$n.actual || { echo "[concurrency] FAIL $n (tsan): output differs"; exit 1; }
  if [ "$QUICK" = 0 ]; then
    $CC -g -O1 -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -I runtime/core $B/$n.c $RT -lm -o $B/$n.asan
    expect_status asan env ASAN_OPTIONS=detect_leaks=0 timeout 600 $B/$n.asan
    cmp "tests/concurrency/$n.out" $B/$n.actual || { echo "[concurrency] FAIL $n (asan): output differs"; exit 1; }
  fi
done
# parallel pipelines (ADR-0039): thread counts 1..8, fused / unfused, ThreadSanitizer and ASan
ORIN2=$ORIN2 CC=$CC tools/test_parallel.sh $( [ "$QUICK" = 1 ] && echo --quick )
echo "[concurrency] ok"
