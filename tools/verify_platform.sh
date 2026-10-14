#!/bin/sh
# L0 platform layer checks (spec 19 R2, docs/formal.md "L0 platform layer"):
#   1. executable contract tests (platform/tests/platform_test.c), plain, under ASan+UBSan and under ThreadSanitizer
#   2. size budget (<= 1,000 CODE lines in platform/*.c, platform/*.h: comments, contract blocks and blank lines do not
#      count, ADR-0030 / ADR-0017 stage 0) and the runtime boundary check
#   3. bounded model checking of the pure/memory primitives with CBMC (platform/tests/cbmc_harness.c);
#      skipped with a notice when `cbmc` is not installed (apt install cbmc);
#      REQUIRE_CBMC=1 turns the skip into a failure
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-cc}
B=build/platform
mkdir -p "$B"

echo "[platform] contract tests"
$CC -Wall -Wextra -O1 -g platform/tests/platform_test.c platform/orin_platform.c -o $B/platform_test
$B/platform_test < /dev/null
$CC -Wall -Wextra -g -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    platform/tests/platform_test.c platform/orin_platform.c -o $B/platform_test_asan
ASAN_OPTIONS=allocator_may_return_null=1 $B/platform_test_asan < /dev/null 2>/dev/null
# the thread and monitor primitives (ADR-0017) are tested only: ThreadSanitizer is the evidence that they are race free
echo "[platform] ThreadSanitizer"
$CC -Wall -Wextra -g -fsanitize=thread platform/tests/platform_test.c platform/orin_platform.c -o $B/platform_test_tsan
TSAN_OPTIONS=allocator_may_return_null=1 $B/platform_test_tsan < /dev/null

echo "[platform] size budget"
# Budget: <= 1,000 CODE lines (non-blank, comments and ACSL contracts excluded) in platform/*.c, platform/*.h.
# The budget limits trusted code, not its specification (ADR-0030 section 1).
code=$(python3 - platform/*.c platform/*.h <<'PY'
import re, sys
n = 0
for f in sys.argv[1:]:
    t = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), open(f).read(), flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    n += sum(1 for l in t.split('\n') if l.strip())
print(n)
PY
)
total=$(cat platform/*.c platform/*.h | wc -l)
echo "platform/*.c, platform/*.h: $code code lines (budget 1000; comments, contracts, blank lines excluded), $total lines in total"
[ "$code" -le 1000 ] || { echo "platform layer exceeds its size budget" >&2; exit 1; }

echo "[platform] boundary"
tools/check_platform_boundary.sh

if ! command -v cbmc >/dev/null 2>&1; then
  echo "[platform] cbmc not installed: bounded model checking SKIPPED"
  [ "${REQUIRE_CBMC:-0}" = 1 ] && exit 1
  exit 0
fi
echo "[platform] CBMC: $(cbmc --version)"
# unwind bound: 6-element arrays, 6-digit (nondet) / 20-digit (concrete) formatting loops, 7-character paths
for h in harness_mem_find:24 harness_fmt_u64:8 harness_fmt_i64:8 harness_fmt_extremes:24 harness_mem:16 harness_alloc:16 harness_policy_parse:14 harness_path_normalize:20 harness_path_within:12; do
  fn=${h%%:*}; un=${h##*:}
  printf '%s ... ' "$fn"
  if cbmc platform/tests/cbmc_harness.c platform/orin_platform.c --function "$fn" \
       --bounds-check --pointer-check --signed-overflow-check --unsigned-overflow-check \
       --conversion-check --unwind "$un" --unwinding-assertions >"$B/$fn.log" 2>&1; then
    echo "VERIFIED (bounded)"
  else
    echo "FAILED"; tail -30 "$B/$fn.log"; exit 1
  fi
done
# network primitives (ADR-0033): recv / send buffer bounds, narrowing never widens, refusal before any system call.
# The harness file includes platform/orin_platform.c itself (static scope functions) and stubs the system calls.
for h in harness_net_recv:4 harness_net_send:4 harness_net_narrow:6 harness_net_refuse:6; do
  fn=${h%%:*}; un=${h##*:}
  printf '%s ... ' "$fn"
  if cbmc platform/tests/cbmc_net_harness.c --function "$fn" \
       --bounds-check --pointer-check --signed-overflow-check --unsigned-overflow-check \
       --conversion-check --unwind "$un" --unwinding-assertions >"$B/$fn.log" 2>&1; then
    echo "VERIFIED (bounded)"
  else
    echo "FAILED"; tail -30 "$B/$fn.log"; exit 1
  fi
done
echo "[platform] ok"
