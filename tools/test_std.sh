#!/bin/sh
# Tests of the provable std modules (ADR-0030 §3): every tests/std/*_test.or is run with `orin test` twice,
#   1. with runtime contract checking (the default of `orin test`: every @Requires / @Ensures / @Invariant of
#      std:bytes, std:utf8, std:collections and std:http is a run-time trap),
#   2. with --no-contracts (the logic must be right without the contracts as well).
# Needs build/bootstrap/orin2 (tools/bootstrap.sh). Usage: tools/test_std.sh [-j N] [--mutate] [FILE...]
#   --mutate  also run the mutation check (tools/mutate_std.py): every deliberately broken implementation must fail
#   -j N      parallel cases (default: $ORIN_JOBS, else the CPU count); the output is in the same fixed order as with -j 1
#   FILE...   only these test files (tests/std/*_test.or or tests/std/expect_trap/*.or); default: all
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
export ORIN2

# one case (run by tools/parallel.py): --one FILE FLAG | --trap FILE
case "${1:-}" in
  --one)
    t=$2; flag=$3
    out=$($ORIN2 test "$t" $flag 2>&1) || { echo "$out" | grep -v '^PASS'; echo "[std] FAIL $t $flag"; exit 1; }
    echo "[std] $t ${flag:-(contracts checked)}: $(echo "$out" | tail -1)"
    exit 0 ;;
  --trap)
    # Tests that must FAIL (trap) in every build: guards that hold without contract checking.
    t=$2
    if $ORIN2 test "$t" --no-contracts >/dev/null 2>&1; then echo "[std] FAIL $t did not trap"; exit 1; fi
    echo "[std] $t: traps as expected"
    exit 0 ;;
esac

MUTATE=
JOBS=
FILES=
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=1 ;;
    -j) JOBS="-j $2"; shift ;;
    -j*) JOBS="-j ${1#-j}" ;;
    -*) echo "usage: $0 [-j N] [--mutate] [FILE...]" >&2; exit 2 ;;
    *) FILES="$FILES $1" ;;
  esac
  shift
done
python3 tools/gen_sorted_map.py --check   # SortedMap / SortedStringMap are generated from tools/sorted_map.tmpl
python3 tools/gen_http_tables.py --check  # the byte class tables of std:http are generated from the RFC character sets
[ -n "$FILES" ] || FILES="$(echo tests/std/*_test.or) $(echo tests/std/expect_trap/*.or)"
# one line per case; tools/parallel.py prints them in this order and stops at the first failure, like the sequential loop
for t in $FILES; do
  case "$t" in
    */expect_trap/*) echo "sh tools/test_std.sh --trap '$t'" ;;
    # the property tests are the slowest cases: start them first (`first:`, tools/parallel.py); the output order stays
    *_prop_test.or) echo "first: sh tools/test_std.sh --one '$t' ''"; echo "first: sh tools/test_std.sh --one '$t' --no-contracts" ;;
    *) echo "sh tools/test_std.sh --one '$t' ''"; echo "sh tools/test_std.sh --one '$t' --no-contracts" ;;
  esac
done | python3 tools/parallel.py $JOBS
if [ -n "$MUTATE" ]; then
  python3 tools/mutate_std.py --orinc "$ORIN2" $JOBS
fi
echo "[std] ok"
