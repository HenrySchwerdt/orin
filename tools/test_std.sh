#!/bin/sh
# Tests of the provable std modules (ADR-0030 §3): every tests/std/*_test.or is run with `orin test` twice,
#   1. with runtime contract checking (the default of `orin test`: every @Requires / @Ensures / @Invariant of
#      std:bytes, std:utf8 and std:collections is a run-time trap),
#   2. with --no-contracts (the logic must be right without the contracts as well).
# Needs build/bootstrap/orin2 (tools/bootstrap.sh). Usage: tools/test_std.sh [--mutate]
#   --mutate  also run the mutation check (tools/mutate_std.py): every deliberately broken implementation must fail
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
python3 tools/gen_sorted_map.py --check   # SortedMap / SortedStringMap are generated from tools/sorted_map.tmpl
for t in tests/std/*_test.or; do
  for flag in "" "--no-contracts"; do
    out=$($ORIN2 test "$t" $flag 2>&1) || { echo "$out" | grep -v '^PASS'; echo "[std] FAIL $t $flag"; exit 1; }
    echo "[std] $t ${flag:-(contracts checked)}: $(echo "$out" | tail -1)"
  done
done
# Tests that must FAIL (trap) in every build: guards that hold without contract checking.
for t in tests/std/expect_trap/*.or; do
  if $ORIN2 test "$t" --no-contracts >/dev/null 2>&1; then echo "[std] FAIL $t did not trap"; exit 1; fi
  echo "[std] $t: traps as expected"
done
if [ "${1:-}" = "--mutate" ]; then
  python3 tools/mutate_std.py --orinc "$ORIN2"
fi
echo "[std] ok"
