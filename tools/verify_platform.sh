#!/bin/sh
# L0 platform layer checks (spec 19 R2, docs/formal.md "L0 platform layer"):
#   1. executable contract tests (runtime/platform/tests/platform_test.c), plain, under ASan+UBSan and under ThreadSanitizer
#   2. size budget (<= 1,400 CODE lines (ADR-0054) in runtime/platform/*.c, runtime/platform/*.h: comments, contract blocks and blank lines do not
#      count, ADR-0030 / ADR-0017 stage 0) and the runtime boundary check
#   3. bounded model checking of the pure/memory primitives with CBMC (runtime/platform/tests/cbmc_harness.c);
#      skipped with a notice when `cbmc` is not installed (apt install cbmc);
#      REQUIRE_CBMC=1 turns the skip into a failure
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-cc}
B=build/platform
mkdir -p "$B"

echo "[platform] contract tests"
$CC -Wall -Wextra -O1 -g runtime/platform/tests/platform_test.c runtime/platform/orin_platform.c -o $B/platform_test
$B/platform_test < /dev/null
$CC -Wall -Wextra -g -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    runtime/platform/tests/platform_test.c runtime/platform/orin_platform.c -o $B/platform_test_asan
ASAN_OPTIONS=allocator_may_return_null=1 $B/platform_test_asan < /dev/null 2>/dev/null
echo "[platform] directory fault injection"
$CC -Wall -Wextra -O1 -g runtime/platform/tests/dir_fault_test.c -o $B/dir_fault_test
$B/dir_fault_test
$CC -Wall -Wextra -g -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    runtime/platform/tests/dir_fault_test.c -o $B/dir_fault_test_asan
ASAN_OPTIONS=allocator_may_return_null=1 $B/dir_fault_test_asan
echo "[platform] runtime directory adapter faults"
for mode in plain asan; do
    flags="-O1 -g"
    [ "$mode" != asan ] || flags="-g -fsanitize=address,undefined -fno-sanitize-recover=undefined"
    $CC -Wall -Wextra $flags -Dorin_platform_dir_list=orin_platform_dir_list_real \
        -c runtime/platform/orin_platform.c -o $B/dir_adapter_platform_$mode.o
    stub=$(ORIN2=${ORIN2:-build/bootstrap/orin2} CC=$CC tools/rt_stub.sh $B/dir_adapter_stub_$mode.o $flags)   # the object model: tools/rt_stub.or
    $CC -Wall -Wextra $flags -I runtime/core runtime/core/tests/dir_fault_test.c runtime/core/orin_runtime.c \
        $B/dir_adapter_platform_$mode.o $stub -lm -o $B/dir_adapter_$mode
    $B/dir_adapter_$mode
done
# the thread and monitor primitives (ADR-0017) are tested only: ThreadSanitizer is the evidence that they are race free
echo "[platform] ThreadSanitizer"
$CC -Wall -Wextra -g -fsanitize=thread runtime/platform/tests/platform_test.c runtime/platform/orin_platform.c -o $B/platform_test_tsan
TSAN_OPTIONS=allocator_may_return_null=1 $B/platform_test_tsan < /dev/null

echo "[platform] size budget"
# Budget: <= 1,400 CODE lines (ADR-0054) (non-blank, comments and ACSL contracts excluded) in runtime/platform/*.c, runtime/platform/*.h.
# The budget limits trusted code, not its specification (ADR-0030 section 1).
code=$(python3 - runtime/platform/*.c runtime/platform/*.h <<'PY'
import re, sys
n = 0
for f in sys.argv[1:]:
    t = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), open(f).read(), flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    n += sum(1 for l in t.split('\n') if l.strip())
print(n)
PY
)
total=$(cat runtime/platform/*.c runtime/platform/*.h | wc -l)
echo "runtime/platform/*.c, runtime/platform/*.h: $code code lines (budget 1400; comments, contracts, blank lines excluded), $total lines in total"
[ "$code" -le 1400 ] || { echo "platform layer exceeds its size budget" >&2; exit 1; }

echo "[platform] boundary"
tools/check_platform_boundary.sh

if ! command -v cbmc >/dev/null 2>&1; then
  echo "[platform] cbmc not installed: bounded model checking SKIPPED"
  [ "${REQUIRE_CBMC:-0}" = 1 ] && exit 1
  exit 0
fi
echo "[platform] CBMC: $(cbmc --version)"
# unwind bound: 6-element arrays, 6-digit (nondet) / 20-digit (concrete) formatting loops, 7-character paths
for h in harness_mem_find:24 harness_fmt_u64:8 harness_fmt_i64:8 harness_fmt_extremes:24 harness_mem:16 harness_alloc:16 harness_policy_parse:14 harness_path_normalize:20 harness_path_within:12 harness_millis_split:2; do
  fn=${h%%:*}; un=${h##*:}
  printf '%s ... ' "$fn"
  if cbmc runtime/platform/tests/cbmc_harness.c runtime/platform/orin_platform.c --function "$fn" \
       --bounds-check --pointer-check --signed-overflow-check --unsigned-overflow-check \
       --conversion-check --unwind "$un" --unwinding-assertions >"$B/$fn.log" 2>&1; then
    echo "VERIFIED (bounded)"
  else
    echo "FAILED"; tail -30 "$B/$fn.log"; exit 1
  fi
done
# network primitives (ADR-0033): recv / send buffer bounds, narrowing never widens, refusal before any system call.
# The harness file includes runtime/platform/orin_platform.c itself (static scope functions) and stubs the system calls.
for h in harness_net_recv:4 harness_net_send:4 harness_net_narrow:6 harness_net_refuse:6; do
  fn=${h%%:*}; un=${h##*:}
  printf '%s ... ' "$fn"
  if cbmc runtime/platform/tests/cbmc_net_harness.c --function "$fn" \
       --bounds-check --pointer-check --signed-overflow-check --unsigned-overflow-check \
       --conversion-check --unwind "$un" --unwinding-assertions >"$B/$fn.log" 2>&1; then
    echo "VERIFIED (bounded)"
  else
    echo "FAILED"; tail -30 "$B/$fn.log"; exit 1
  fi
done
# the rest of the pure / model-checkable L0 surface (ADR-0053 M7): float text, clock wrappers, argv, ORIN_DENY loading,
# path_absolute, error_message and the handle validation (generation + liveness) of monitors and threads as bounded
# state machines. The harness file includes orin_platform.c and stubs clock_gettime / getenv / getcwd / snprintf /
# pthread_create / pthread_join: the table LOGIC is checked, not the interleavings (ThreadSanitizer above).
# The handle tables (65,536 / 262,144 / 65,536 wake records) are shrunk to 8 in a COPY of orin_platform.c under $B/l0 (the 2^18-entry tables
# exhaust the solver's memory); the validation arithmetic does not depend on the table size. The source itself is untouched.
mkdir -p "$B/l0"
sed -e 's/THR_MAX = 1 << 16, MON_MAX = 1 << 18/THR_MAX = 8, MON_MAX = 8/' -e 's/WAKE_MAX = 1 << 16/WAKE_MAX = 8/' runtime/platform/orin_platform.c >"$B/l0/orin_platform.c"
cp runtime/platform/orin_platform.h runtime/platform/orin_platform_pure.h "$B/l0/"
grep -q 'THR_MAX = 8, MON_MAX = 8' "$B/l0/orin_platform.c" && grep -q 'WAKE_MAX = 8' "$B/l0/orin_platform.c" || { echo "table-size line of orin_platform.c changed: adapt the sed above" >&2; exit 1; }
l0() { # harness:unwind extra-flags...
  fn=${1%%:*}; un=${1##*:}; shift
  printf '%s ... ' "$fn"
  if cbmc runtime/platform/tests/cbmc_l0_harness.c "-DL0_SRC=\"../../../$B/l0/orin_platform.c\"" --function "$fn" \
       --bounds-check --pointer-check --signed-overflow-check "$@" \
       --unwind "$un" --unwinding-assertions >"$B/$fn.log" 2>&1; then
    echo "VERIFIED (bounded)"
  else
    echo "FAILED"; tail -30 "$B/$fn.log"; exit 1
  fi
}
for h in harness_double_to_exp:34 harness_parse_double:8 harness_now_millis:4 harness_monotonic_millis:4 \
         harness_error_message:4 harness_args:4 harness_policy_load:10 harness_path_absolute:7; do
  l0 "$h" --unsigned-overflow-check --conversion-check
done
# handle validation: `(uint32_t)h - 1u` and `(uint64_t)h` deliberately wrap (h = 0 / a negative handle must give an index
# that is >= the high-water mark, so unsigned-wrap and sign-conversion checks are off for these; signed overflow stays on)
for h in harness_monitor_generation:4 harness_monitor_grow:6 harness_monitor_state_machine:7 harness_thread_handles:4 \
         harness_wake_generation:4 harness_wake_state_machine:7; do
  l0 "$h"
done
echo "[platform] ok"
